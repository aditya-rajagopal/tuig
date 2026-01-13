const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.tui);

const t = @import("terminal.zig");
const Terminal = t.Terminal;
const TerminalConfig = t.TerminalConfig;
const e = @import("event.zig");
const Code = e.KeyEvent.Code;
const Renderer = @import("renderer.zig");

var global_tty: ?*Terminal = null;
pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    if (global_tty) |tty| {
        tty.deinit();
    }
    std.debug.defaultPanic(msg, ret_addr);
}

pub fn main(_: std.process.Init.Minimal) void {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.ioBasic();

    var write_buffer: [4096]u8 align(4096) = undefined;
    var config: TerminalConfig = .tui_default;
    config.mouse.?.sgr = false;
    var terminal = Terminal.init(io, config, &write_buffer) catch |err| {
        log.err("Failed to initialize terminal: {s}", .{@errorName(err)});
        return;
    };
    defer terminal.deinit();
    global_tty = &terminal;

    terminal.setCursorVisible(false) catch {};
    defer terminal.setCursorVisible(true) catch {};

    var quit = false;
    var app = Application.init(&terminal);
    var renderer: Renderer = undefined;
    renderer.init(&terminal, std.heap.page_allocator) catch {
        log.err("Failed to initialize renderer", .{});
        return;
    };

    while (!quit) {
        const events = terminal.pollEvents(16) catch {
            log.err("Failed to poll events", .{});
            return;
        };

        renderer.beginFrame(events);
        defer renderer.endFrame();

        quit = app.updateAndRender(events, &renderer);
    }
}

const Application = struct {
    screen_position: usize = 0,
    task_start: usize = 0,
    task_end: usize = 0,
    lines: usize = 0,
    result: TestCase = undefined,
    mode: Mode = .spashscreen,
    splash_progress: u16 = 0,

    const Mode = enum { spashscreen, tasklist };
    const Result = enum { success, quit, scene_change };

    const TestCase = struct {
        tasks: []const []const u8,
    };

    pub fn init(terminal: *Terminal) Application {
        var application = Application{
            .lines = terminal.size.height - 1,
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
        return application;
    }

    fn updateAndRender(self: *Application, events: []const e.Event, renderer: *Renderer) bool {
        const result: Result = .scene_change;
        loop: switch (result) {
            .scene_change => switch (self.mode) {
                .spashscreen => continue :loop self.spashScreen(events, renderer),
                .tasklist => continue :loop self.taskList(events, renderer),
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

    fn spashScreen(self: *Application, events: []const e.Event, renderer: *Renderer) Result {
        for (events) |event| {
            switch (event) {
                .key_pressed, .key_repeat => |key| {
                    switch (key.physical_key) {
                        .q => return .quit,
                        else => {
                            self.mode = .tasklist;
                            return .scene_change;
                        },
                    }
                },
                else => {},
            }
        }
        {
            const width = renderer.render_buffer.width;
            const height = renderer.render_buffer.height;
            const start_x = width / 2 - codepoint_width / 2;
            const start_y = height / 2 - codepoint_height / 2;
            var start: usize = 0;
            for (0..codepoint_height) |row| {
                start += renderer.render_buffer.renderTextDelimiter(
                    @intCast(start_x),
                    @intCast(start_y + row),
                    splash_text[start..],
                    self.splash_progress,
                    '\n',
                );
            }
            if (self.splash_progress < codepoint_width) {
                self.splash_progress += 1;
            }
        }
        return .success;
    }

    fn taskList(self: *Application, events: []const e.Event, renderer: *Renderer) Result {
        var direction: i8 = 0;
        {
            for (events) |event| {
                switch (event) {
                    .key_pressed, .key_repeat => |key| {
                        switch (key.physical_key) {
                            .q => return .quit,
                            .j, .down => direction = 1,
                            .k, .up => direction = -1,
                            else => {},
                        }
                    },
                    .mouse_scroll_up => {
                        direction = 1;
                    },
                    .mouse_scroll_down => {
                        direction = -1;
                    },
                    .resize => |resize| {
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
                    },
                    else => {},
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
            _ = renderer.render_buffer.renderTextDelimiter(0, 0, search_str, null, null);
            for (self.result.tasks[self.task_start..self.task_end], 0..) |task, index| {
                var buf: [256]u8 = undefined;
                const str = std.fmt.bufPrint(&buf, "{s}{s}", .{ if (self.screen_position == index) ">" else " ", task }) catch unreachable;
                _ = renderer.render_buffer.renderTextDelimiter(0, @truncate(index + 1), str, null, null);
            }
        }
        return .success;
    }
};

fn queryMode(terminal: *Terminal) void {
    terminal.write("\x1b[?1016$p") catch {};
    terminal.flush() catch {};

    var buf: [32]u8 = undefined;
    var fds = [_]std.posix.pollfd{
        .{
            .fd = terminal.stdin,
            .events = std.posix.POLL.IN,
            .revents = 0,
        },
    };
    const poll_result = std.posix.poll(&fds, 100) catch return;

    if (poll_result == 0) return;

    if (fds[0].revents & std.posix.POLL.IN == 0) return;

    const n = std.posix.read(terminal.fd, &buf) catch return;
    terminal.write("Respose: ") catch {};
    for (buf[0..n]) |c| {
        if (c == '\x1b') terminal.write("\\x1b") catch {} else terminal.print("{c}", .{c}) catch {};
    }
    terminal.write("\r\n") catch {};
    terminal.flush() catch {};
}
