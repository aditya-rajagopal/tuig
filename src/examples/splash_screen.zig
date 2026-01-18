const std = @import("std");
const assert = std.debug.assert;

const tuig = @import("tuig");
const r = tuig.renderer;
const Context = r.Context;

const SplashScreen = @This();

const splash_text =
    \\████████╗██╗   ██╗██╗ ██████╗ 
    \\╚══██╔══╝██║   ██║██║██╔════╝ 
    \\   ██║   ██║   ██║██║██║  ███╗
    \\   ██║   ██║   ██║██║██║   ██║
    \\   ██║   ╚██████╔╝██║╚██████╔╝
    \\   ╚═╝    ╚═════╝ ╚═╝ ╚═════╝ 
;

const codepoint_count = blk: {
    @setEvalBranchQuota(10000);
    break :blk std.unicode.utf8CountCodepoints(splash_text) catch @compileError("Invalid splash text");
};
const codepoint_width = blk: {
    @setEvalBranchQuota(10000);
    var iter = std.unicode.Utf8View.initComptime(splash_text).iterator();
    var count: usize = 0;
    while (iter.nextCodepoint()) |codepoint| {
        if (codepoint == '\n') break;
        count += 1;
    }
    break :blk count;
};
const codepoint_height = codepoint_count / codepoint_width;

splash_progress: u16 = 0,
splash_animation_mode: enum { start, move_to_top, done } = .start,
options_width: ?usize = null,
selection: u16 = 0,

pub const SplashScreenResult = union(enum) {
    selection: u16,
    quit,
    noop,
};

pub fn reset(self: *SplashScreen) void {
    self.splash_animation_mode = .start;
    self.splash_progress = 0;
    self.options_width = null;
}

pub fn updateAndRender(self: *SplashScreen, ctx: Context, options: []const []const u8) SplashScreenResult {
    if (self.options_width == null) {
        self.options_width = 0;
        for (options) |option| {
            self.options_width = @max(self.options_width.?, option.len);
        }
    }
    if (ctx.isKeyPressed(.q)) return .quit;
    if (ctx.key_pressed) |key| {
        switch (key.code) {
            else => {
                if (self.splash_animation_mode == .start) {
                    self.splash_animation_mode = .done;
                    self.splash_progress = 0;
                }
            },
        }
    }
    const width = ctx.scissor.width;
    const height = ctx.scissor.height;
    const start_x = width / 2 - codepoint_width / 2;
    const start_y = height / 2 - codepoint_height / 2;

    const area = loop: switch (self.splash_animation_mode) {
        .start => blk: {
            if (self.splash_progress <= codepoint_width) {
                self.splash_progress += 1;
            } else {
                self.splash_animation_mode = .move_to_top;
                self.splash_progress = @intCast(start_y);
                continue :loop .move_to_top;
            }
            break :blk ctx.scissor.initChild(@intCast(start_x), @intCast(start_y), self.splash_progress, codepoint_height);
        },
        .move_to_top, .done => blk: {
            if (self.splash_progress > 1) {
                self.splash_progress -= 1;
            } else {
                self.splash_animation_mode = .done;
            }
            break :blk ctx.scissor.initChild(@intCast(start_x), @intCast(self.splash_progress), codepoint_width + 1, codepoint_height);
        },
    };
    var start: usize = 0;
    // @FIXME this needs to have a sub-scissor
    for (0..codepoint_height) |row| {
        start += area.renderLineDelimiter(
            0,
            @intCast(row),
            splash_text[start..],
            '\n',
            true,
        );
    }

    if (self.splash_animation_mode == .done) {
        if (ctx.key_pressed) |key| {
            switch (key.code) {
                .j, .down => {
                    if (self.selection == options.len - 1) self.selection = 0 else self.selection += 1;
                },
                .k, .up => {
                    if (self.selection == 0) self.selection = @intCast(options.len - 1) else self.selection -= 1;
                },
                .enter => return .{ .selection = self.selection },
                else => {},
            }
        }
        assert(self.options_width != null);
        const options_x = (ctx.scissor.width - self.options_width.?) / 2 + 1;

        const options_scissor = ctx.scissor.initChild(
            @intCast(options_x - 1),
            codepoint_height + 3,
            @intCast(self.options_width.? + 2),
            @intCast(options.len),
        );
        var selection: [2]u21 = .{ '[', ']' };
        if (ctx.isHovered(options_scissor)) |local_pos| {
            self.selection = local_pos.y;
            if (ctx.mouse_down.left or ctx.mouse_pressed.left) {
                selection = .{ '<', '>' };
            } else if (ctx.mouse_released.left) {
                return .{ .selection = self.selection };
            }
        }
        for (options, 0..) |option, i| {
            assert(option.len <= self.options_width.?);
            if (i == self.selection) {
                _ = options_scissor.set(0, @intCast(i), selection[0]);
                _ = options_scissor.set(@intCast(self.options_width.? + 1), @intCast(i), selection[1]);
            }
            const option_start_x = (self.options_width.? + 2 - option.len) / 2;
            _ = options_scissor.renderLineDelimiter(@intCast(option_start_x), @intCast(i), option, null, false);
        }
    }
    return .noop;
}
