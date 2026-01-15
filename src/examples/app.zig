const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const tg = @import("tuig");
const Renderer = tg.Renderer;
const Scissor = Renderer.Scissor;
const Context = Renderer.Context;

const Application = @This();
screen_position: usize = 0,
task_start: usize = 0,
task_end: usize = 0,
lines: usize = 0,
result: TestCase = undefined,
mode: Mode = .spashscreen,
splash_progress: u16 = 0,
splash_animation_mode: enum { start, move_to_top, done } = .start,

const Mode = enum { spashscreen, tasklist };
const Result = enum { success, quit, scene_change };

const TestCase = struct {
    tasks: []const []const u8,
};

pub fn init(window_height: u16) Application {
    var application = Application{
        .lines = window_height - 1,
    };
    const text: []const u8 = @embedFile("test_unicode.txt");
    application.result = comptime blk: {
        @setEvalBranchQuota(10000);
        var result: []const []const u8 = &.{};
        var iter = std.mem.splitScalar(u8, text, '\n');
        while (iter.next()) |line| {
            result = result ++ &[_][]const u8{line};
        }
        const tasks = result;
        break :blk TestCase{ .tasks = tasks };
    };
    application.task_end = std.math.clamp(application.result.tasks.len, 0, application.lines);
    application.splash_progress = 0;
    application.splash_animation_mode = .start;
    return application;
}

pub fn updateAndRender(self: *Application, ctx: Context) bool {
    const result: Result = .scene_change;
    loop: switch (result) {
        .scene_change => switch (self.mode) {
            .spashscreen => continue :loop self.spashScreen(ctx),
            .tasklist => continue :loop self.taskList(ctx),
        },
        .quit => return true,
        .success => return false,
    }
}

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
const codepoint_height = codepoint_count / (codepoint_width + 1);

fn spashScreen(self: *Application, ctx: Context) Result {
    if (ctx.isKeyPressed(.q)) return .quit;

    if (ctx.key_pressed) |key| {
        switch (key.code) {
            else => {
                if (self.splash_animation_mode == .start) {
                    self.splash_animation_mode = .done;
                    self.splash_progress = 0;
                } else {
                    self.mode = .tasklist;
                    return .scene_change;
                }
            },
        }
    }
    const width = ctx.scissor.width;
    const height = ctx.scissor.height;
    const start_x = width / 2 - codepoint_width / 2;

    const area = loop: switch (self.splash_animation_mode) {
        .start => blk: {
            const start_y = height / 2 - codepoint_height / 2;
            if (self.splash_progress < codepoint_width) {
                self.splash_progress += 1;
            } else {
                self.splash_animation_mode = .move_to_top;
                self.splash_progress = @intCast(start_y);
                continue :loop .move_to_top;
            }
            break :blk ctx.scissor.initChild(@intCast(start_x), @intCast(start_y), self.splash_progress, codepoint_height);
        },
        .move_to_top, .done => blk: {
            if (self.splash_progress > 0) {
                self.splash_progress -= 1;
            } else {
                self.splash_animation_mode = .done;
            }
            break :blk ctx.scissor.initChild(@intCast(start_x), @intCast(self.splash_progress), codepoint_width, codepoint_height);
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
    return .success;
}

fn taskList(self: *Application, ctx: Context) Result {
    var direction: i8 = 0;
    {
        if (ctx.isKeyPressed(.q)) return .quit;

        if (ctx.key_pressed) |key| {
            switch (key.code) {
                .j, .down => direction = 1,
                .k, .up => direction = -1,
                else => {},
            }
        }
        direction += ctx.mouse_scroll;

        if (ctx.resize) |resize| {
            const lines_before = self.lines;
            self.lines = resize.height - 1;
            if (lines_before > self.lines) {
                if (self.result.tasks.len < lines_before) {
                    const lines_empty_before = lines_before - self.result.tasks.len;
                    const lines_reduced = lines_before - self.lines;
                    if (lines_empty_before > lines_reduced) {} else {
                        self.task_end -= (lines_reduced - lines_empty_before);
                    }
                } else {
                    if (self.screen_position >= self.lines) {
                        self.task_end -= lines_before - 1 - self.screen_position;
                        self.task_start = self.task_end - self.lines;
                        self.screen_position = self.lines - 1;
                    } else {
                        self.task_end -= (lines_before - self.lines);
                    }
                }
            } else {
                if (self.result.tasks.len <= self.lines) {
                    self.task_start = 0;
                    self.task_end = self.result.tasks.len;
                } else {
                    const tasks_remaining = self.result.tasks.len - self.task_end;
                    const lines_added = self.lines - lines_before;
                    if (tasks_remaining < lines_added) {
                        self.task_end += tasks_remaining;
                        self.task_start -= lines_added - tasks_remaining;
                        self.screen_position += lines_added - tasks_remaining;
                    } else {
                        self.task_end += lines_added;
                    }
                }
            }
        }
    }

    {
        if (direction == -1) {
            if (self.screen_position == 0) {
                if (self.task_start == 0) {
                    if (self.result.tasks.len > self.lines) {
                        self.task_end = self.result.tasks.len;
                        self.task_start = self.result.tasks.len - self.lines;
                        self.screen_position = self.lines - 1;
                    } else {
                        self.screen_position = self.result.tasks.len;
                    }
                } else {
                    self.task_start -= 1;
                    self.task_end -= 1;
                }
            } else {
                self.screen_position -= 1;
            }
        }

        if (direction == 1) {
            if (self.screen_position == self.lines - 1) {
                if (self.task_end == self.result.tasks.len) {
                    self.task_end = self.lines;
                    self.task_start = 0;
                    self.screen_position = 0;
                } else {
                    self.task_start += 1;
                    self.task_end += 1;
                }
            } else if (self.screen_position == self.result.tasks.len) {
                self.screen_position = 0;
            } else {
                self.screen_position += 1;
            }
        }

        const search_str = "Search: ";
        _ = ctx.scissor.renderLineDelimiter(0, 0, search_str, null, false);
        for (self.result.tasks[self.task_start..self.task_end], 0..) |task, index| {
            var buf: [1024]u8 = undefined;
            const str = std.fmt.bufPrint(&buf, "{s}{s}", .{ if (self.screen_position == index) ">" else " ", task }) catch unreachable;
            const len = ctx.scissor.renderLineDelimiter(0, @intCast(index + 1), str, null, false);
            assert(len == str.len);
        }
    }
    return .success;
}
