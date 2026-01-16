const std = @import("std");
const assert = std.debug.assert;

const tuig = @import("tuig");
const Renderer = tuig.Renderer;
const Context = Renderer.Context;

const List = @This();

screen_position: usize = 0,
display_window_start: usize = 0,
display_window_end: usize = 0,
lines: usize = 0,
list: []const []const u8 = &.{},

const text: []const u8 = @embedFile("test_ascii.txt");

pub fn reset(self: *List, window_height: u16) void {
    self.list = comptime blk: {
        @setEvalBranchQuota(10000);
        var result: []const []const u8 = &.{};
        var iter = std.mem.splitScalar(u8, text, '\n');
        while (iter.next()) |line| {
            result = result ++ &[_][]const u8{line};
        }
        break :blk result;
    };
    self.lines = window_height - 1;
    self.display_window_start = 0;
    self.display_window_end = std.math.clamp(self.list.len, 0, self.lines);
}

const TaskListResult = enum { quit, noop, back };

pub fn updateAndRender(self: *List, ctx: Context) TaskListResult {
    var direction: i8 = 0;
    {
        if (ctx.isKeyPressed(.q)) return .quit;

        if (ctx.key_pressed) |key| {
            switch (key.code) {
                .escape => return .back,
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
                if (self.list.len < lines_before) {
                    const lines_empty_before = lines_before - self.list.len;
                    const lines_reduced = lines_before - self.lines;
                    if (lines_empty_before > lines_reduced) {} else {
                        self.display_window_end -= (lines_reduced - lines_empty_before);
                    }
                } else {
                    if (self.screen_position >= self.lines) {
                        self.display_window_end -= lines_before - 1 - self.screen_position;
                        self.display_window_start = self.display_window_end - self.lines;
                        self.screen_position = self.lines - 1;
                    } else {
                        self.display_window_end -= (lines_before - self.lines);
                    }
                }
            } else {
                if (self.list.len <= self.lines) {
                    self.display_window_start = 0;
                    self.display_window_end = self.list.len;
                } else {
                    const tasks_remaining = self.list.len - self.display_window_end;
                    const lines_added = self.lines - lines_before;
                    if (tasks_remaining < lines_added) {
                        self.display_window_end += tasks_remaining;
                        self.display_window_start -= lines_added - tasks_remaining;
                        self.screen_position += lines_added - tasks_remaining;
                    } else {
                        self.display_window_end += lines_added;
                    }
                }
            }
        }
    }

    {
        if (direction == -1) {
            if (self.screen_position == 0) {
                if (self.display_window_start == 0) {
                    if (self.list.len > self.lines) {
                        self.display_window_end = self.list.len;
                        self.display_window_start = self.list.len - self.lines;
                        self.screen_position = self.lines - 1;
                    } else {
                        self.screen_position = self.list.len;
                    }
                } else {
                    self.display_window_start -= 1;
                    self.display_window_end -= 1;
                }
            } else {
                self.screen_position -= 1;
            }
        }

        if (direction == 1) {
            if (self.screen_position == self.lines - 1) {
                if (self.display_window_end == self.list.len) {
                    self.display_window_end = self.lines;
                    self.display_window_start = 0;
                    self.screen_position = 0;
                } else {
                    self.display_window_start += 1;
                    self.display_window_end += 1;
                }
            } else if (self.screen_position == self.list.len) {
                self.screen_position = 0;
            } else {
                self.screen_position += 1;
            }
        }

        const search_str = "Search: ";
        _ = ctx.scissor.renderLineDelimiter(0, 0, search_str, null, false);
        for (self.list[self.display_window_start..self.display_window_end], 0..) |task, index| {
            var buf: [1024]u8 = undefined;
            const str = std.fmt.bufPrint(&buf, "{s}{s}", .{ if (self.screen_position == index) ">" else " ", task }) catch unreachable;
            const len = ctx.scissor.renderLineDelimiter(0, @intCast(index + 1), str, null, false);
            assert(len == str.len);
        }
    }
    return .noop;
}
