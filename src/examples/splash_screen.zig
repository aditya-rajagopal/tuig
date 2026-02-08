const std = @import("std");
const assert = std.debug.assert;

const tuig = @import("tuig");
const r = tuig.renderer;
const Context = r.Context;
const Cell = r.Cell;
const Style = r.Style;
const StyleReference = r.Style.Sheet.Reference;
const layout = tuig.layout;
const Constraint = layout.Constraint;

const app = @import("app.zig");

const SplashScreen = @This();

const splash_text =
    \\████████╗██╗   ██╗██╗ ██████╗ 
    \\╚══██╔══╝██║   ██║██║██╔════╝ 
    \\   ██║   ██║   ██║██║██║  ███╗
    \\   ██║   ██║   ██║██║██║   ██║
    \\   ██║   ╚██████╔╝██║╚██████╔╝
    \\   ╚═╝    ╚═════╝ ╚═╝ ╚═════╝ 
    \\
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
    break :blk count + 1;
};
const codepoint_height = codepoint_count / codepoint_width;

const splash_text_width: u16 = @intCast(codepoint_width);
const splash_height: u16 = @intCast(codepoint_height);
const splash_area_width: u16 = splash_text_width + 1;
const splash_top_padding: u16 = 1;
const splash_options_gap: u16 = 2;
const options_width_padding: u16 = 2;

const AnimationMode = enum { start, move_to_top, done };

splash_progress: u16 = 0,
splash_animation_mode: AnimationMode = .start,
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
    const options_metrics = computeOptionsSizes(options);

    if (ctx.isKeyPressed(.Q)) return .quit;
    if (ctx.key_pressed.len > 0) {
        if (self.splash_animation_mode == .start) {
            self.splash_animation_mode = .done;
            self.splash_progress = 0;
        }
    }

    const requirements = spaceRequirements(self.splash_animation_mode, options_metrics.box_width, options_metrics.height);
    if (ctx.scissor.width_global < requirements.width or ctx.scissor.height_global < requirements.height) {
        renderResizeHint(ctx.scissor, requirements.width, requirements.height);
        return .noop;
    }

    const root_rect = ctx.scissor.toRect();
    const centered_splash_rect = root_rect.centeredChild(splash_area_width, splash_height);
    const area = loop: switch (self.splash_animation_mode) {
        .start => blk: {
            if (self.splash_progress < splash_text_width) {
                self.splash_progress += 1;
            } else {
                self.splash_animation_mode = .move_to_top;
                self.splash_progress = centered_splash_rect.y;
                continue :loop .move_to_top;
            }

            var reveal_scr = ctx.scissor.initChildRect(centered_splash_rect);
            reveal_scr.width_clip = self.splash_progress;
            break :blk reveal_scr;
        },
        .move_to_top => blk: {
            if (self.splash_progress > splash_top_padding) {
                self.splash_progress -= 1;
            } else if (self.splash_progress < splash_top_padding) {
                self.splash_progress += 1;
            } else {
                self.splash_animation_mode = .done;
            }

            var moving_rect = centered_splash_rect;
            moving_rect.y = self.splash_progress;
            break :blk ctx.scissor.initChildRect(moving_rect);
        },
        .done => blk: {
            const done_layout = computeDoneLayout(root_rect, options_metrics.box_width, options_metrics.height);
            if (self.renderOptions(ctx, options, options_metrics, done_layout)) |selection| {
                return .{ .selection = selection };
            }
            break :blk ctx.scissor.initChildRect(done_layout.splash_rect);
        },
    };

    _ = area.printAssumeNoGrapheme(
        splash_text,
        0,
        0,
        .{ .wrap = true, .tab_width = 4, .style = self.splash_colour },
    );

    return .noop;
}

fn renderOptions(
    self: *SplashScreen,
    ctx: *const Context,
    options: []const []const u8,
    options_sizes: OptionsSizes,
    done_layout: DoneLayout,
) ?u16 {
    if (options_sizes.height == 0) return null;

    if (self.selection >= options_sizes.height) self.selection = 0;
    for (ctx.key_pressed) |key| {
        switch (key.code) {
            .j, .down => {
                if (self.selection == options_sizes.height - 1) self.selection = 0 else self.selection += 1;
            },
            .k, .up => {
                if (self.selection == 0) self.selection = options_sizes.height - 1 else self.selection -= 1;
            },
            .enter => return self.selection,
            else => {},
        }
    }

    const options_rect = done_layout.options_rect orelse return null;
    const options_scissor = ctx.scissor.initChildRect(options_rect);

    var selection_style: Style.Id = self.selection_hover;
    if (ctx.isHovered(options_scissor)) |local_pos| {
        self.selection = local_pos.y;
        if (ctx.mouse_down.left or ctx.mouse_pressed.left) {
            selection_style = self.selection_pressed;
        } else if (ctx.mouse_released.left) {
            return self.selection;
        }
    }
    for (options, 0..) |option, i| {
        assert(option.len <= options_sizes.text_width);
        var style: Style.Id = .default;
        if (i == self.selection) {
            style = selection_style;
        }
        const option_start_x = (options_sizes.text_width - option.len) / 2;
        _ = options_scissor.printAssumeNoGrapheme(option, @intCast(option_start_x), @intCast(i), .{
            .wrap = false,
            .tab_width = 4,
            .style = style,
        });
    }

    return null;
}

const OptionsSizes = struct {
    text_width: u16,
    box_width: u16,
    height: u16,
};

fn computeOptionsSizes(options: []const []const u8) OptionsSizes {
    var text_width: usize = 0;
    for (options) |option| {
        text_width = @max(text_width, option.len);
    }

    const text_width_u16: u16 = @intCast(text_width);
    return .{
        .text_width = text_width_u16,
        .box_width = text_width_u16 + options_width_padding,
        .height = @intCast(options.len),
    };
}

const Requirements = struct {
    width: u16,
    height: u16,
};

fn spaceRequirements(mode: AnimationMode, options_box_width: u16, options_height: u16) Requirements {
    var width = splash_area_width;
    var height: u16 = switch (mode) {
        .start => splash_top_padding + splash_height,
        .move_to_top, .done => splash_top_padding + splash_height,
    };

    if (mode == .done and options_height > 0) {
        width = @max(width, options_box_width);
        height += splash_options_gap + options_height;
    }

    return .{ .width = width, .height = height };
}

const DoneLayout = struct {
    splash_rect: layout.Rect,
    options_rect: ?layout.Rect,
};

fn computeDoneLayout(root_rect: layout.Rect, options_box_width: u16, options_height: u16) DoneLayout {
    if (options_height > 0) {
        const constraints = [_]Constraint{
            Constraint.fixed(splash_top_padding),
            Constraint.fixed(splash_height).withCross(splash_area_width, .center),
            Constraint.fixed(splash_options_gap),
            Constraint.fixed(options_height).withCross(options_box_width, .center),
            Constraint.flex(1),
        };
        var panes: [layout.max_children]layout.Rect = undefined;
        _ = root_rect.split(&constraints, .{}, panes[0..constraints.len]) catch unreachable;
        return .{ .splash_rect = panes[1], .options_rect = panes[3] };
    }

    const constraints = [_]Constraint{
        Constraint.fixed(splash_top_padding),
        Constraint.fixed(splash_height).withCross(splash_area_width, .center),
        Constraint.flex(1),
    };
    var panes: [layout.max_children]layout.Rect = undefined;
    _ = root_rect.split(&constraints, .{}, panes[0..constraints.len]) catch unreachable;
    return .{ .splash_rect = panes[1], .options_rect = null };
}

fn renderResizeHint(scissor: r.Scissor, min_width: u16, min_height: u16) void {
    var buf: [128]u8 = undefined;
    const str = std.fmt.bufPrint(&buf, "Resize to atleast {d}x{d}[Now: {d}x{d}]", .{
        min_width,
        min_height,
        scissor.width_global,
        scissor.height_global,
    }) catch unreachable;

    const area = scissor.centeredChild(@intCast(str.len), 1);
    _ = area.printAssumeNoGrapheme(str, 0, 0, .{ .wrap = false, .tab_width = 4 });
}
