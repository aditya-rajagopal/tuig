const std = @import("std");
const Allocator = std.mem.Allocator;

const stdx = @import("stdx");
const assert = stdx.inlineAssert;
const tg = @import("tuig");
const r = tg.renderer;
const Scissor = r.Scissor;
const Context = r.Context;

const SplashScreen = @import("splash_screen.zig");
const List = @import("list.zig");
const Snake = @import("snake.zig");

const Application = @This();

pub const MemoryPool = stdx.BufferPoolExtra(.{ .block_size = 1 * 1024 * 1024, .size_limit = 5, .metrics = true });

mode: Modes,
current_scene: Scenes = .splash_screen,
splash_screen: SplashScreen = undefined,
snake: Snake = undefined,
list: List = undefined,
memory: MemoryPool = undefined,
toggle_metrics: bool = false,

const Modes = union(enum) {
    render_scene: Scenes,
    transition_to: Scenes,
};

const Scenes = enum(u8) {
    splash_screen = 0,
    snake = 1,
    list = 2,
};

pub fn init(window_height: u16) !Application {
    var application: Application = undefined;
    application.mode = .{ .render_scene = .splash_screen };
    application.list.init(window_height);
    application.splash_screen.init();
    application.snake.init();
    application.memory = try MemoryPool.init();
    return application;
}

pub const options: []const []const u8 = &.{
    "Snake Game",
    "Ascii Lists",
};

pub fn updateAndRender(self: *Application, ctx: Context) bool {
    loop: switch (self.mode) {
        .render_scene => |scene| switch (scene) {
            .splash_screen => {
                if (ctx.isKeyPressed(.@"`")) {
                    self.toggle_metrics = !self.toggle_metrics;
                }
                if (self.toggle_metrics) {
                    const metrics_scissr = ctx.scissor.initChild(0, 0, 25, 5);
                    _ = metrics_scissr.renderLineDelimiter(0, 0, "Memory Pool Metrics", null, false);
                    var buf: [256]u8 = undefined;
                    const metrics = self.memory.metrics;
                    const acquires_total = std.fmt.bufPrint(&buf, "Acquires Total: {d}", .{metrics.acquires_total}) catch unreachable;
                    _ = metrics_scissr.renderLineDelimiter(0, 1, acquires_total, null, false);
                    const releases_total = std.fmt.bufPrint(&buf, "Releases Total: {d}", .{metrics.releases_total}) catch unreachable;
                    _ = metrics_scissr.renderLineDelimiter(0, 2, releases_total, null, false);
                    const acquires_current = std.fmt.bufPrint(&buf, "Acquires Current: {d}", .{metrics.acquires_current}) catch unreachable;
                    _ = metrics_scissr.renderLineDelimiter(0, 3, acquires_current, null, false);
                    const acquires_max_concurrent = std.fmt.bufPrint(&buf, "Max Concurrent: {d}", .{metrics.acquires_max_concurrent}) catch unreachable;
                    _ = metrics_scissr.renderLineDelimiter(0, 4, acquires_max_concurrent, null, false);
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
            .list => {
                switch (self.list.updateAndRender(ctx)) {
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
                inline else => |s| @field(self, @tagName(s)).reset(&self.memory),
            };
            if (result == error.Failed) return true;
            return false;
        },
    }
}
