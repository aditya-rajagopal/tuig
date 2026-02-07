const std = @import("std");

const tuig = @import("tuig");
const Context = tuig.renderer.Context;
const Style = tuig.renderer.Style;
const Scissor = tuig.renderer.Scissor;
const drawBox = tuig.ui.drawBox;
const DrawBoxConfig = tuig.ui.DrawBoxConfig;

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

    const header = root.initChild(0, 0, root.width_global, 1);
    self.drawHeader(ctx, header);

    const footer_height: u16 = if (root.height_global >= 3) 1 else 0;
    const screen_height = root.height_global - 1 - footer_height;
    if (screen_height > 0) {
        const screen = root.initChild(0, 1, root.width_global, screen_height);
        self.drawScreen(ctx, screen);
    }

    if (footer_height > 0) {
        const footer = root.initChild(0, @intCast(root.height_global - footer_height), root.width_global, footer_height);
        self.drawFooter(ctx, footer);
    }

    return false;
}

fn drawScreen(self: *Widgets, ctx: *const Context, scr: Scissor) void {
    scr.fillNarrow(.{ .style = self.screen_background_style });

    const sidebar_width: u16 = @min(scr.width_global, 24);
    if (sidebar_width > 0) {
        const sidebar = scr.initChild(0, 0, sidebar_width, scr.height_global);
        _ = sidebar.printAssumeNoGrapheme("Sidebar", 0, 0, .default);
    }

    const has_separator = scr.width_global > sidebar_width;
    if (has_separator) {
        const vbar = scr.initChild(@intCast(sidebar_width), 0, 1, scr.height_global);
        vbar.fillNarrow(.{ .data = .{ .codepoint = '│' }, .style = self.screen_background_style });
    }

    const content_x: u16 = sidebar_width + @as(u16, @intFromBool(has_separator));
    if (content_x < scr.width_global) {
        const content = scr.initChild(@intCast(content_x), 0, scr.width_global - content_x, scr.height_global);
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
