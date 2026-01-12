const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.tui);

const t = @import("terminal.zig");
const Terminal = t.Terminal;
const TerminalConfig = t.TerminalConfig;
const e = @import("event.zig");
const Code = e.KeyEvent.Code;

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
    var renderer = Renderer.init(&terminal, std.heap.page_allocator);

    while (!quit) {
        const events = terminal.pollEvents(16) catch {
            log.err("Failed to poll events", .{});
            return;
        };

        renderer.beginFrame(events);
        defer renderer.endFrame();

        quit = app.updateAndRender(events, renderer.render_buffer, &terminal);
    }
}

const Application = struct {
    screen_position: usize = 0,
    task_start: usize = 0,
    task_end: usize = 0,
    lines: usize = 0,
    result: TestCase = undefined,
    mode: Mode = .spashscreen,
    splash_progress: u32 = 0,

    const Mode = enum { spashscreen, tasklist };
    const Result = enum { success, quit, scene_change };

    const TestCase = struct {
        tasks: []const []const u8,
    };

    pub fn init(terminal: *Terminal) Application {
        var ctx = Application{
            .lines = terminal.size.height - 1,
        };
        const text: []const u8 = @embedFile("test.txt");
        ctx.result = comptime blk: {
            @setEvalBranchQuota(10000);
            var result: []const []const u8 = &.{};
            var iter = std.mem.splitScalar(u8, text, '\n');
            while (iter.next()) |line| {
                result = result ++ &[_][]const u8{line};
            }
            const tasks = result;
            break :blk TestCase{ .tasks = tasks };
        };
        ctx.task_end = std.math.clamp(ctx.result.tasks.len, 0, ctx.lines);
        return ctx;
    }

    fn updateAndRender(self: *Application, events: []const e.Event, render_buffer: []u8, terminal: *Terminal) bool {
        const result: Result = .scene_change;
        loop: switch (result) {
            .scene_change => switch (self.mode) {
                .spashscreen => continue :loop self.spashscreen(events, render_buffer, terminal),
                .tasklist => continue :loop self.taskList(events, render_buffer, terminal),
            },
            .quit => return true,
            .success => return false,
        }
    }

    // const splash_text =
    //     \\████████╗██╗   ██╗██╗ ██████╗
    //     \\╚══██╔══╝██║   ██║██║██╔════╝
    //     \\   ██║   ██║   ██║██║██║  ███╗
    //     \\   ██║   ██║   ██║██║██║   ██║
    //     \\   ██║   ╚██████╔╝██║╚██████╔╝
    //     \\   ╚═╝    ╚═════╝ ╚═╝ ╚═════╝
    // ;
    const splash_text =
        \\_________         _________ _______ 
        \\\__   __/|\     /|\__   __/(  ____ \
        \\   ) (   | )   ( |   ) (   | (    \/
        \\   | |   | |   | |   | |   | |      
        \\   | |   | |   | |   | |   | | ____ 
        \\   | |   | |   | |   | |   | | \_  )
        \\   | |   | (___) |___) (___| (___) |
        \\   )_(   (_______)\_______/(_______)
    ;

    const splash_width = std.mem.findScalar(u8, splash_text, '\n').?;
    const splash_height = splash_text.len / (splash_width + 1) + 1;

    fn spashscreen(self: *Application, events: []const e.Event, render_buffer: []u8, terminal: *Terminal) Result {
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
            const width = terminal.size.width;
            const height = terminal.size.height;
            const start_x = width / 2 - splash_width / 2;
            const start_y = height / 2 - splash_height / 2;
            for (0..splash_height) |row| {
                const start = (row + start_y) * width + start_x;
                @memcpy(
                    render_buffer[start..][0..self.splash_progress],
                    splash_text[row * (splash_width + 1) ..][0..self.splash_progress],
                );
            }
            if (self.splash_progress < splash_width) {
                self.splash_progress += 1;
            }
        }
        return .success;
    }

    fn taskList(self: *Application, events: []const e.Event, render_buffer: []u8, terminal: *Terminal) Result {
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
            @memcpy(render_buffer[0..search_str.len], search_str);
            for (self.result.tasks[self.task_start..self.task_end], 0..) |task, index| {
                var buf: [128]u8 = undefined;
                const str = std.fmt.bufPrint(&buf, "{s}{s}", .{ if (self.screen_position == index) ">" else " ", task }) catch unreachable;
                const dest = render_buffer[(index + 1) * terminal.size.width ..][0..str.len];
                @memcpy(dest, str);
            }
        }
        return .success;
    }
};

const Renderer = struct {
    screen_buffer: []u8,
    screen_buffer_capacity: usize,
    render_buffer: []u8,
    render_buffer_capacity: usize,
    terminal: *Terminal,
    redraw: bool = true,

    pub const max_cells = 640 * 480;
    pub fn init(terminal: *Terminal, allocator: Allocator) Renderer {
        var renderer: Renderer = undefined;
        const sbuffer = allocator.alignedAlloc(u8, .fromByteUnits(128), max_cells) catch unreachable;
        const rbuffer = allocator.alignedAlloc(u8, .fromByteUnits(128), max_cells) catch unreachable;

        renderer.screen_buffer = sbuffer[0 .. terminal.size.width * terminal.size.height];
        renderer.render_buffer = rbuffer[0 .. terminal.size.width * terminal.size.height];
        renderer.redraw = true;
        renderer.terminal = terminal;
        renderer.screen_buffer_capacity = max_cells;
        renderer.render_buffer_capacity = max_cells;

        terminal.clearScreen() catch {};
        return renderer;
    }

    pub fn deinit(self: *Renderer, allocator: Allocator) void {
        self.terminal.clearScreen() catch {};
        allocator.free(self.screen_buffer);
        allocator.free(self.render_buffer);
    }

    pub fn beginFrame(self: *Renderer, events: []const e.Event) void {
        for (events) |event| {
            switch (event) {
                .resize => |resize| {
                    const new_cells = resize.width * resize.height;
                    if (new_cells > max_cells) {
                        log.err("Resized to too large a size", .{});
                        return;
                    }
                    self.screen_buffer.len = new_cells;
                    self.render_buffer.len = new_cells;
                    self.redraw = true;
                    self.terminal.clearScreen() catch {};
                },
                else => {},
            }
        }
        @memset(self.render_buffer, ' ');
    }

    pub fn endFrame(self: *Renderer) void {
        if (self.redraw) {
            for (0..self.terminal.size.height) |row| {
                self.terminal.setCursorPosition(0, @truncate(row)) catch {};
                self.terminal.write(self.render_buffer[row * self.terminal.size.width ..][0..self.terminal.size.width]) catch {};
                @memcpy(
                    self.screen_buffer[row * self.terminal.size.width ..][0..self.terminal.size.width],
                    self.render_buffer[row * self.terminal.size.width ..][0..self.terminal.size.width],
                );
            }
            self.redraw = false;
        } else {
            @branchHint(.likely);
            for (0..self.terminal.size.height) |row| {
                const row_start: u32 = @intCast(row * self.terminal.size.width);
                const row_end: u32 = row_start + self.terminal.size.width;
                var col: u16 = 0;
                while (col < self.terminal.size.width) {
                    var start: u32 = row_start + col;
                    while (start < row_end and self.screen_buffer[start] == self.render_buffer[start]) : (start += 1) {}
                    var end: u32 = start;
                    while (end < row_end and self.screen_buffer[end] != self.render_buffer[end]) : (end += 1) {}
                    self.terminal.setCursorPosition(@truncate(start - row_start), @truncate(row)) catch {};
                    self.terminal.write(self.render_buffer[start..end]) catch {};
                    @memcpy(self.screen_buffer[start..end], self.render_buffer[start..end]);
                    col = @intCast(end - row_start);
                }
            }
        }
        self.terminal.flush() catch {};
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
