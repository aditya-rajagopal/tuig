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

    const header = ctx.scissor.initChild(0, 0, ctx.scissor.width_global, 1);
    const screen = ctx.scissor.initChild(0, 1, ctx.scissor.width_global, ctx.scissor.height_global - 3);
    const footer = ctx.scissor.initChild(0, ctx.scissor.height_global - 2, ctx.scissor.width_global, 1);

    self.drawHeader(ctx, header);
    self.drawScreen(ctx, screen);
    self.drawFooter(ctx, footer);

    return false;
}

fn drawScreen(self: *Widgets, ctx: *const Context, scr: Scissor) void {
    scr.fill(.{ .style = self.screen_background_style });
    const sidebar = scr.initChild(0, 0, 30, scr.height_global);
    const content = scr.initChild(30, 0, scr.width_global - 30, scr.height_global);
    _ = sidebar.printAssumeNoGrapheme("Sidebar", 0, 0, .default);
    self.drawMovingBox(ctx, content);
}

fn drawMovingBox(self: *Widgets, ctx: *const Context, scissor: Scissor) void {
    if (self.box_move_start) |start| {
        if (ctx.mouse_down.left) {
            // +1 to account for border
            const mouse_relative_x = @as(i17, ctx.mouse_x) - @as(i17, self.box_position_x + 1) - scissor.x_global;
            const mouse_relative_y = @as(i17, ctx.mouse_y) - @as(i17, self.box_position_y + 1) - scissor.y_global;
            const moved_x = mouse_relative_x - start.x;
            const moved_y = mouse_relative_y - start.y;
            self.box_position_x = @intCast(std.math.clamp(@as(i17, self.box_position_x) + moved_x, 0, scissor.width_global - 30));
            self.box_position_y = @intCast(std.math.clamp(@as(i17, self.box_position_y) + moved_y, 0, scissor.height_global - 15));
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
    box.fill(.{ .style = self.header_style });
}

fn drawHeader(self: *Widgets, ctx: *const Context, scissor: Scissor) void {
    scissor.fill(.{ .style = self.header_style });
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
    scissor.fill(.{ .style = self.footer_style });
    const result = scissor.printAssumeNoGrapheme("[Q]", 0, 0, .{ .style = self.footer_bold_style });
    _ = scissor.printAssumeNoGrapheme("uit", result.final_x, 0, .{ .style = self.footer_style });
}
