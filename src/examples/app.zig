const std = @import("std");
const Allocator = std.mem.Allocator;

const stdx = @import("stdx");
const assert = stdx.inlineAssert;
const tg = @import("tuig");
const r = tg.renderer;
const Scissor = r.Scissor;
const Context = r.Context;
const Style = r.Style;

const SplashScreen = @import("splash_screen.zig");
const Snake = @import("snake.zig");
const Tetris = @import("tetris.zig");
const Widgets = @import("widgets.zig");

const Application = @This();

pub const MemoryPool = stdx.BufferPoolExtra(.{
    .block_size = 1 * 1024 * 1024,
    .size_limit = 5,
    .metrics = true,
});

mode: Modes,
current_scene: Scenes = .splash_screen,
splash_screen: SplashScreen = undefined,
snake: Snake = undefined,
tetris: Tetris = undefined,
widgets: Widgets = undefined,
memory: MemoryPool = undefined,
toggle_metrics: bool = false,
timer: std.time.Timer = undefined,
style_sheet: *Style.Sheet,

const Modes = union(enum) {
    render_scene: Scenes,
    transition_to: Scenes,
};

const Scenes = enum(u8) {
    splash_screen = 0,
    snake = 1,
    tetris = 2,
    widgets = 3,
};

pub fn init(style_sheet: *Style.Sheet) !Application {
    var application: Application = undefined;
    application.mode = .{ .render_scene = .splash_screen };
    application.splash_screen.init(style_sheet);
    application.snake.init();
    application.tetris.init(style_sheet);
    application.widgets.init(style_sheet);
    application.memory = try MemoryPool.init();
    application.timer = std.time.Timer.start() catch unreachable;
    application.toggle_metrics = false;
    application.style_sheet = style_sheet;
    return application;
}

pub const options: []const []const u8 = &.{
    "Snake",
    "Tetris",
    "Widgets",
};

pub fn updateAndRender(self: *Application, ctx: *const Context) bool {
    const frame_time = self.timer.lap();
    const time_ms = @as(f32, @floatFromInt(frame_time)) / (1000.0 * 1000.0);
    var fps_buffer: [128]u8 = undefined;
    const fps = std.fmt.bufPrint(&fps_buffer, "Time: {d}ms, FPS: {d}", .{ time_ms, 1000.0 / time_ms }) catch unreachable;
    const area = ctx.scissor.initChild(0, ctx.scissor.height_global - 1, @intCast(fps.len), 1);
    _ = area.printAssumeNoGrapheme(fps, 0, 0, .{ .wrap = false, .tab_width = 4 });
    loop: switch (self.mode) {
        .render_scene => |scene| switch (scene) {
            .splash_screen => {
                if (ctx.isKeyPressed(.@"`")) {
                    self.toggle_metrics = !self.toggle_metrics;
                }
                if (self.toggle_metrics) {
                    const metrics_scissr = ctx.scissor.initChild(0, 0, 25, 5);
                    _ = metrics_scissr.printAssumeNoGrapheme("Memory Pool Metrics", 0, 0, .default);
                    var buf: [256]u8 = undefined;
                    const metrics = self.memory.metrics;
                    const acquires_total = std.fmt.bufPrint(&buf, "Acquires Total: {d}", .{metrics.acquires_total}) catch unreachable;
                    _ = metrics_scissr.printAssumeNoGrapheme(acquires_total, 0, 1, .default);
                    const releases_total = std.fmt.bufPrint(&buf, "Releases Total: {d}", .{metrics.releases_total}) catch unreachable;
                    _ = metrics_scissr.printAssumeNoGrapheme(releases_total, 0, 2, .default);
                    const acquires_current = std.fmt.bufPrint(&buf, "Acquires Current: {d}", .{metrics.acquires_current}) catch unreachable;
                    _ = metrics_scissr.printAssumeNoGrapheme(acquires_current, 0, 3, .default);
                    const acquires_max_concurrent = std.fmt.bufPrint(&buf, "Max Concurrent: {d}", .{metrics.acquires_max_concurrent}) catch unreachable;
                    _ = metrics_scissr.printAssumeNoGrapheme(acquires_max_concurrent, 0, 4, .default);
                }
                switch (self.splash_screen.updateAndRender(ctx, options)) {
                    .quit => return true,
                    .selection => |to| {
                        continue :loop .{ .transition_to = @enumFromInt(to + 1) };
                    },
                    .noop => return false,
                }
            },
            .snake => {
                switch (self.snake.updateAndRender(ctx)) {
                    .quit => return true,
                    .noop => return false,
                    .back => continue :loop .{ .transition_to = .splash_screen },
                }
            },
            .widgets => {
                if (!self.widgets.updateAndRender(ctx)) {
                    return false;
                } else {
                    continue :loop .{ .transition_to = .splash_screen };
                }
            },
            .tetris => {
                switch (self.tetris.updateAndRender(ctx)) {
                    .quit => return true,
                    .noop => return false,
                    .back => continue :loop .{ .transition_to = .splash_screen },
                }
            },
        },
        .transition_to => |scene| {
            assert(self.mode == .render_scene);
            switch (self.mode.render_scene) {
                inline else => |s| @field(self, @tagName(s)).deinit(),
            }
            self.mode = .{ .render_scene = scene };
            const result = switch (scene) {
                inline else => |s| @field(self, @tagName(s)).reset(&self.memory, ctx),
            };
            if (result == error.Failed) return true;
            return false;
        },
    }
}
