const std = @import("std");

const tuig = @import("tuig");
const Context = tuig.renderer.Context;
const Style = tuig.renderer.Style;
const Scissor = tuig.renderer.Scissor;
const drawBox = tuig.ui.drawBox;
const DrawBoxConfig = tuig.ui.DrawBoxConfig;
const layout = tuig.layout;
const Constraint = layout.Constraint;

const app = @import("app.zig");

const Widgets = @This();

header_style: Style.Id = .default,
footer_style: Style.Id = .default,
footer_bold_style: Style.Id = .default,
screen_background_style: Style.Id = .default,
box_position_x: u16 = 0,
box_position_y: u16 = 0,
box_move_start: ?tuig.renderer.Position = null,

pub fn init(self: *Widgets, style_sheet: *Style.Sheet) void {
    self.header_style = style_sheet.putBounded(.{
        .bg = .{ .rgb = .fromHex(0xcccccc) },
        .fg = .{ .rgb = .fromHex(0x000000) },
        .flags = .{},
    });
    self.footer_style = style_sheet.putBounded(.{
        .bg = .{ .rgb = .fromHex(0xcccccc) },
        .fg = .{ .rgb = .fromHex(0x000000) },
        .flags = .{},
    });
    self.footer_bold_style = style_sheet.putBounded(.{
        .bg = .{ .rgb = .fromHex(0xcccccc) },
        .fg = .{ .rgb = .fromHex(0x000000) },
        .flags = .{
            .bold = true,
        },
    });
    self.screen_background_style = style_sheet.putBounded(.{
        .bg = .{ .rgb = .fromHex(0x242022) },
        .flags = .{ .dim = true },
    });
    self.box_position_x = 2;
    self.box_position_y = 2;
}

pub fn deinit(self: *Widgets) void {
    _ = self; // autofix
}

pub fn reset(self: *Widgets, memory_pool: *app.MemoryPool, ctx: *const Context) error{Failed}!void {
    _ = self; // autofix
    _ = memory_pool; // autofix
    _ = ctx; // autofix
}

pub fn updateAndRender(self: *Widgets, ctx: *const Context) bool {
    if (ctx.isKeyPressed(.Q)) return true;

    const root = ctx.scissor;
    if (root.width_global == 0 or root.height_global == 0) return false;

    const root_rect = root.toRect();
    const root_constraints = [_]Constraint{ Constraint.fixed(1), Constraint.flex(1), Constraint.fixed(1) };
    var root_panes: [3]layout.Rect = undefined;
    _ = root_rect.split(&root_constraints, .{}, &root_panes) catch unreachable;

    if (root_panes[0].height > 0 and root_panes[0].width > 0) {
        const header = root.initChildRect(root_panes[0]);
        self.drawHeader(ctx, header);
    }

    if (root_panes[1].height > 0 and root_panes[1].width > 0) {
        const screen = root.initChildRect(root_panes[1]);
        self.drawScreen(ctx, screen);
    }

    if (root_panes[2].height > 0 and root_panes[2].width > 0) {
        const footer = root.initChildRect(root_panes[2]);
        self.drawFooter(ctx, footer);
    }

    return false;
}

fn drawScreen(self: *Widgets, ctx: *const Context, scr: Scissor) void {
    scr.fillNarrow(.{ .style = self.screen_background_style });

    const screen_rect = scr.toRect();
    const screen_constraints = [_]Constraint{ Constraint.fixed(24), Constraint.fixed(1), Constraint.flex(1) };
    var screen_panes: [3]layout.Rect = undefined;
    _ = screen_rect.split(&screen_constraints, .{ .axis = .horizontal }, &screen_panes) catch unreachable;

    if (screen_panes[0].width > 0 and screen_panes[0].height > 0) {
        const sidebar = scr.initChildRect(screen_panes[0]);
        _ = sidebar.printAssumeNoGrapheme("Sidebar", 0, 0, .default);
    }

    if (screen_panes[1].width > 0 and screen_panes[1].height > 0) {
        const vbar = scr.initChildRect(screen_panes[1]);
        vbar.fillNarrow(.{ .data = .{ .codepoint = '│' }, .style = self.screen_background_style });
    }

    if (screen_panes[2].width > 0 and screen_panes[2].height > 0) {
        const content = scr.initChildRect(screen_panes[2]);
        self.drawMovingBox(ctx, content);
    }
}

fn drawMovingBox(self: *Widgets, ctx: *const Context, scissor: Scissor) void {
    const max_x: i17 = @max(0, @as(i17, @intCast(scissor.width_global)) - 30);
    const max_y: i17 = @max(0, @as(i17, @intCast(scissor.height_global)) - 15);
    const max_x_u16: u16 = @intCast(max_x);
    const max_y_u16: u16 = @intCast(max_y);
    if (self.box_position_x > max_x_u16) self.box_position_x = max_x_u16;
    if (self.box_position_y > max_y_u16) self.box_position_y = max_y_u16;

    if (self.box_move_start) |start| {
        if (ctx.mouse_down.left) {
            // +1 to account for border
            const mouse_relative_x = @as(i17, ctx.mouse_x) - @as(i17, self.box_position_x + 1) - scissor.x_global;
            const mouse_relative_y = @as(i17, ctx.mouse_y) - @as(i17, self.box_position_y + 1) - scissor.y_global;
            const moved_x = mouse_relative_x - start.x;
            const moved_y = mouse_relative_y - start.y;
            self.box_position_x = @intCast(std.math.clamp(@as(i17, self.box_position_x) + moved_x, 0, max_x));
            self.box_position_y = @intCast(std.math.clamp(@as(i17, self.box_position_y) + moved_y, 0, max_y));
        } else {
            self.box_move_start = null;
        }
    }
    const config = DrawBoxConfig{
        .border = .thick,
    };
    const box = drawBox(scissor, self.box_position_x, self.box_position_y, 30, 15, &config);
    if (ctx.isHovered(box)) |pos| {
        if (ctx.mouse_pressed.left) {
            self.box_move_start = pos;
        }
    }
    box.fillNarrow(.{ .style = self.header_style });
}

fn drawHeader(self: *Widgets, ctx: *const Context, scissor: Scissor) void {
    scissor.fillNarrow(.{ .style = self.header_style });
    var buf: [128]u8 = undefined;
    const mouse = std.fmt.bufPrint(&buf, "Mouse: [{d}, {d}],  Box: [{d}, {d}]", .{
        ctx.mouse_x,
        ctx.mouse_y,
        self.box_position_x,
        self.box_position_y,
    }) catch unreachable;
    _ = scissor.printAssumeNoGrapheme(mouse, 0, 0, .{ .style = self.header_style });
}

fn drawFooter(self: *Widgets, ctx: *const Context, scissor: Scissor) void {
    _ = ctx;
    scissor.fillNarrow(.{ .style = self.footer_style });
    const result = scissor.printAssumeNoGrapheme("[Q]", 0, 0, .{ .style = self.footer_bold_style });
    _ = scissor.printAssumeNoGrapheme("uit", result.final_x, 0, .{ .style = self.footer_style });
}
