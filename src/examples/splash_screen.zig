const std = @import("std");
const assert = std.debug.assert;

const tuig = @import("tuig");
const r = tuig.renderer;
const Context = r.Context;
const Cell = r.Cell;
const Style = r.Style;
const StyleReference = r.Style.Sheet.Reference;

const app = @import("app.zig");

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
splash_colour: Style.Id,
selection_hover: Style.Id,
selection_pressed: Style.Id,

pub const SplashScreenResult = union(enum) {
    selection: u16,
    quit,
    noop,
};

pub fn init(self: *SplashScreen, style_sheet: *Style.Sheet) void {
    self.splash_animation_mode = .start;
    self.splash_progress = 0;
    self.options_width = null;
    self.selection = 0;
    self.splash_colour = style_sheet.putBounded(.{ .fg = .{ .rgb = .{ .r = 0, .g = 255, .b = 0 } } });
    self.selection_hover = style_sheet.putBounded(.{ .bg = .{ .rgb = .{ .r = 128, .g = 128, .b = 128 } } });
    self.selection_pressed = style_sheet.putBounded(.{ .bg = .{ .rgb = .{ .r = 64, .g = 64, .b = 64 } } });
}

pub fn deinit(self: *SplashScreen) void {
    _ = self;
}

pub fn reset(self: *SplashScreen, memory_pool: *app.MemoryPool, ctx: *const Context) error{Failed}!void {
    _ = ctx;
    _ = memory_pool;
    self.splash_animation_mode = .done;
    self.splash_progress = 0;
}

pub fn updateAndRender(self: *SplashScreen, ctx: *const Context, options: []const []const u8) SplashScreenResult {
    if (self.options_width == null) {
        self.options_width = 0;
        for (options) |option| {
            self.options_width = @max(self.options_width.?, option.len);
        }
    }
    if (ctx.isKeyPressed(.Q)) return .quit;
    if (ctx.key_pressed.len > 0) {
        if (self.splash_animation_mode == .start) {
            self.splash_animation_mode = .done;
            self.splash_progress = 0;
        }
    }
    const width_i17: i17 = @intCast(ctx.scissor.width_global);
    const height_i17: i17 = @intCast(ctx.scissor.height_global);
    const splash_width_i17: i17 = @intCast(codepoint_width);
    const splash_height_i17: i17 = @intCast(codepoint_height);
    const start_x: i17 = @divFloor(width_i17 - splash_width_i17, 2);
    const start_y: i17 = @divFloor(height_i17 - splash_height_i17, 2);

    const area = loop: switch (self.splash_animation_mode) {
        .start => blk: {
            if (self.splash_progress <= codepoint_width) {
                self.splash_progress += 1;
            } else {
                self.splash_animation_mode = .move_to_top;
                self.splash_progress = if (start_y > 1) @intCast(start_y) else 1;
                continue :loop .move_to_top;
            }
            break :blk ctx.scissor.initChild(start_x, start_y, self.splash_progress, codepoint_height);
        },
        .move_to_top, .done => blk: {
            if (self.splash_progress > 1) {
                self.splash_progress -= 1;
            } else {
                self.splash_animation_mode = .done;
            }
            break :blk ctx.scissor.initChild(start_x, @intCast(self.splash_progress), codepoint_width + 1, codepoint_height);
        },
    };
    var text_iter = std.mem.splitScalar(u8, splash_text, '\n');
    var row: u16 = 0;
    while (text_iter.next()) |line| {
        _ = area.printAssumeNoGrapheme(
            line,
            0,
            row,
            .{ .wrap = false, .tab_width = 4, .style = self.splash_colour },
        );
        row += 1;
    }

    if (self.splash_animation_mode == .done) {
        for (ctx.key_pressed) |key| {
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
        const options_text_width: i17 = @intCast(self.options_width.?);
        const options_x: i17 = @divFloor(width_i17 - options_text_width, 2);
        const options_width: u16 = @intCast(self.options_width.? + 2);
        const options_height: u16 = @intCast(options.len);
        const options_y: i17 = @intCast(codepoint_height + 3);

        const options_scissor = ctx.scissor.initChild(
            options_x,
            options_y,
            options_width,
            options_height,
        );

        var selection_style: Style.Id = self.selection_hover;
        if (ctx.isHovered(options_scissor)) |local_pos| {
            self.selection = local_pos.y;
            if (ctx.mouse_down.left or ctx.mouse_pressed.left) {
                selection_style = self.selection_pressed;
            } else if (ctx.mouse_released.left) {
                return .{ .selection = self.selection };
            }
        }
        for (options, 0..) |option, i| {
            assert(option.len <= self.options_width.?);
            var style: Style.Id = .default;
            if (i == self.selection) {
                style = selection_style;
            }
            const option_start_x = (self.options_width.? - option.len) / 2;
            _ = options_scissor.printAssumeNoGrapheme(option, @intCast(option_start_x), @intCast(i), .{
                .wrap = false,
                .tab_width = 4,
                .style = style,
            });
        }
    }
    return .noop;
}
