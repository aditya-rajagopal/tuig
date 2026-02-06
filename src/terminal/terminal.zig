const std = @import("std");
const assert = std.debug.assert;

const e = @import("event.zig");
const Event = e.Event;
const seq = @import("sequences.zig");

pub const KittyConfig = seq.kitty.Flags;

pub const MouseOptions = struct {
    /// Enable SGR(Select Graphic Rendition) mouse tracking mode.
    /// Extension to traditional x10 mouse protocol that allows more infomration about which specific button is released,
    /// and allows terminal sizes more than 222.
    /// It is **RECOMMENDED** to enable this unless the target terminal does not support the xterm standard
    sgr: bool = true,
    /// The level of reporting mouse events
    level: Level,

    pub const default: MouseOptions = .{
        .sgr = true,
        .level = .all_motion,
    };

    pub const Level = seq.mouse.TrackingLevel;
};

pub const TerminalConfig = struct {
    raw: bool = false,
    alt_screen: bool = false,
    mouse: ?MouseOptions = null,
    kitty_keyboard_flags: ?KittyConfig = null,
    cursor_visible: bool = true,

    pub const tui_default = TerminalConfig{
        .raw = true,
        .alt_screen = true,
        .mouse = .default,
        .kitty_keyboard_flags = .{ .disambiguate_escape_codes = true, .report_all_keys_as_escape_codes = true, .report_event_types = true },
        .cursor_visible = true,
    };
    pub const raw_terminal = TerminalConfig{ .raw = true };
    pub const default_terminal = TerminalConfig{};
};

pub const Terminal = struct {
    fd: std.Io.File.Handle,
    stdin: std.Io.File.Handle,
    original_state: std.posix.termios,
    writer: std.Io.File.Writer,
    size: Size,
    // @TODO GILA(dependent_thorn_fh0) Make this a resizable buffer
    event_queue: [32]Event = undefined,
    config: TerminalConfig,

    pub const Size = struct { width: u16, height: u16 };

    pub var global_tty: ?*Terminal = null;

    pub fn getWriter(self: *Terminal) *std.Io.Writer {
        return &self.writer.interface;
    }

    pub fn init(terminal: *Terminal, config: TerminalConfig, write_buffer: []u8) error{Failed}!void {
        var threaded = std.Io.Threaded.init_single_threaded;
        const io = threaded.ioBasic();
        const file = std.Io.Dir.openFileAbsolute(io, "/dev/tty", .{ .mode = .read_write }) catch return error.Failed;
        errdefer file.close(io);
        terminal.fd = file.handle; //std.posix.open("/dev/tty", .{ .ACCMODE = .RDWR }, 0) catch return error.Failed;
        terminal.stdin = std.Io.File.stdin().handle;
        terminal.original_state = std.posix.tcgetattr(terminal.fd) catch return error.Failed;
        terminal.writer = std.Io.File.Writer.initStreaming(std.Io.File{ .handle = terminal.fd }, io, write_buffer);
        terminal.size = terminal.getSize();
        @memset(&terminal.event_queue, .none);

        terminal.config.raw = false;
        if (config.raw) terminal.makeRaw() catch return error.Failed;
        errdefer terminal.unmakeRaw();

        terminal.config.alt_screen = false;
        if (config.alt_screen) terminal.setAlternateScreen() catch return error.Failed;
        errdefer terminal.unsetAlternateScreen();

        terminal.config.mouse = null;
        if (config.mouse) |mouse_config| terminal.enableMouse(mouse_config) catch return error.Failed;
        errdefer terminal.disableMouse();

        terminal.config.kitty_keyboard_flags = null;
        if (config.kitty_keyboard_flags) |kitty_config| terminal.pushKittyKeyboardFlags(kitty_config) catch return error.Failed;
        errdefer terminal.popKittyKeyboardFlags() catch {};

        terminal.setCursorVisible(config.cursor_visible) catch return error.Failed;

        global_tty = terminal;
    }

    pub fn deinit(self: *Terminal) void {
        // IMPORTANT(adi): This order is important as we need to disable keyboard flag before leaving alternate screen
        if (self.config.kitty_keyboard_flags) |_| self.popKittyKeyboardFlags() catch {};
        if (self.config.mouse) |_| self.disableMouse();
        if (self.config.alt_screen) self.unsetAlternateScreen();
        if (self.config.raw) self.unmakeRaw();
        if (!self.config.cursor_visible) self.setCursorVisible(true) catch {};
        global_tty = null;

        var threaded = std.Io.Threaded.init_single_threaded;
        const io = threaded.ioBasic();
        (std.Io.File{ .handle = self.fd }).close(io);
    }

    pub fn write(self: *Terminal, bytes: []const u8) error{WriteFailed}!void {
        self.writer.interface.writeAll(bytes) catch return error.WriteFailed;
    }

    pub fn print(self: *Terminal, comptime fmt: []const u8, args: anytype) error{WriteFailed}!void {
        self.writer.interface.print(fmt, args) catch return error.WriteFailed;
    }

    pub fn flush(self: *Terminal) error{WriteFailed}!void {
        self.writer.interface.flush() catch return error.WriteFailed;
    }

    pub fn setCursorVisible(self: *Terminal, visible: bool) error{WriteFailed}!void {
        const writer = self.getWriter();
        if (visible) {
            seq.cursor.visible(writer) catch return error.WriteFailed;
            self.config.cursor_visible = true;
        } else {
            seq.cursor.hidden(writer) catch return error.WriteFailed;
            self.config.cursor_visible = false;
        }
        try self.flush();
    }

    pub fn getSize(self: *const Terminal) Size {
        // @TODO windows uses GetConsoleScreenBufferInfo
        var size: std.posix.winsize = undefined;
        const r = std.posix.system.ioctl(self.fd, std.posix.T.IOCGWINSZ, @intFromPtr(&size));
        if (r != 0) {
            return .{ .width = 80, .height = 24 };
        }
        if (size.col == 0 or size.row == 0) {
            return .{ .width = 80, .height = 24 };
        }
        return .{ .width = size.col, .height = size.row };
    }

    // @TODO GILA(enchanted_ogre_80w) make this only submit the query and get the response back from the event queue
    // pub fn getCursorPosition(self: *const Terminal) struct { x: u16, y: u16 } {
    //     var buf: [32]u8 = undefined;
    //     const n = std.posix.write(self.fd, "\x1b[6n") catch return .{ .x = 0, .y = 0 };
    //     if (n != 4) return .{ .x = 0, .y = 0 };
    //     const n2 = std.posix.read(self.fd, &buf) catch return .{ .x = 0, .y = 0 };
    //     if (n2 < 6) return .{ .x = 0, .y = 0 };
    //     assert(buf[0] == '\x1b');
    //     assert(buf[1] == '[');
    //     const seperator = std.mem.findScalar(u8, buf[0..n2], ';') orelse return .{ .x = 0, .y = 0 };
    //     return .{
    //         .x = (std.fmt.parseInt(u16, buf[seperator + 1 .. n2 - 1], 10) catch return .{ .x = 0, .y = 0 }) - 1,
    //         .y = (std.fmt.parseInt(u16, buf[2..seperator], 10) catch return .{ .x = 0, .y = 0 }) - 1,
    //     };
    // }

    pub fn makeRaw(self: *Terminal) error{Failed}!void {
        if (self.config.raw) return;
        var raw = self.original_state;
        raw.iflag.IGNBRK = false;
        raw.iflag.BRKINT = false;
        raw.iflag.PARMRK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.INLCR = false;
        raw.iflag.IGNCR = false;
        raw.iflag.ICRNL = false;
        raw.iflag.IXON = false;

        raw.oflag.OPOST = false;

        raw.lflag.ECHO = false;
        raw.lflag.ECHONL = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;

        raw.cflag.CSIZE = .CS8;
        raw.cflag.PARENB = false;

        raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        std.posix.tcsetattr(self.fd, .FLUSH, raw) catch {
            return error.Failed;
        };
        self.config.raw = true;
    }

    pub fn unmakeRaw(self: *Terminal) void {
        if (!self.config.raw) return;
        std.posix.tcsetattr(self.fd, .FLUSH, self.original_state) catch {};
        self.config.raw = false;
    }

    pub fn setAlternateScreen(self: *Terminal) error{WriteFailed}!void {
        if (self.config.alt_screen) return;
        const writer = self.getWriter();
        seq.csiPrivateSet(writer, .alternate_screen) catch return error.WriteFailed;
        writer.writeAll(seq.screen.clear_and_home) catch return error.WriteFailed;
        try self.flush();
        self.config.alt_screen = true;
    }

    pub fn unsetAlternateScreen(self: *Terminal) void {
        if (!self.config.alt_screen) return;
        seq.csiPrivateReset(self.getWriter(), .alternate_screen) catch {};
        self.flush() catch {};
        self.config.alt_screen = false;
    }

    pub fn enableMouse(self: *Terminal, options: MouseOptions) error{WriteFailed}!void {
        const writer = self.getWriter();
        options.level.enable(writer) catch return error.WriteFailed;
        errdefer options.level.disable(writer) catch {};
        if (options.sgr) {
            seq.mouse.enableSgr(writer) catch return error.WriteFailed;
        }
        try self.flush();
        self.config.mouse = options;
    }

    pub fn disableMouse(self: *Terminal) void {
        if (self.config.mouse) |options| {
            const writer = self.getWriter();
            options.level.disable(writer) catch {};
            if (options.sgr) {
                seq.mouse.disableSgr(writer) catch {};
            }
            self.flush() catch {};
            self.config.mouse = null;
        }
    }

    pub fn pushKittyKeyboardFlags(self: *Terminal, config: KittyConfig) error{WriteFailed}!void {
        if (self.config.kitty_keyboard_flags) |_| return;
        seq.kitty.pushKeyboardFlags(self.getWriter(), config) catch return error.WriteFailed;
        try self.flush();
        self.config.kitty_keyboard_flags = config;
    }

    pub fn popKittyKeyboardFlags(self: *Terminal) error{WriteFailed}!void {
        if (self.config.kitty_keyboard_flags) |_| {
            seq.kitty.popKeyboardFlags(self.getWriter()) catch return error.WriteFailed;
            try self.flush();
            self.config.kitty_keyboard_flags = null;
        }
    }

    // @TODO This should drain the event queue in multithreaded mode when that is implemented
    pub fn pollEvents(self: *Terminal, timeout_ms: i32) error{PollFailed}![]Event {
        var events = std.ArrayList(Event).initBuffer(&self.event_queue);

        const size = self.getSize();
        if (size.width != self.size.width or size.height != self.size.height) {
            events.appendAssumeCapacity(.{ .resize = .{
                .old_width = self.size.width,
                .old_height = self.size.height,
                .width = size.width,
                .height = size.height,
            } });
            self.size = size;
        }

        // @TODO Should we try to look for closed pipes?
        var fds = [_]std.posix.pollfd{
            .{
                // FIXME: In macos you cant poll dev/tty. It needs select
                .fd = self.stdin,
                .events = std.posix.POLL.IN,
                .revents = 0,
            },
        };
        var poll_result = std.posix.poll(&fds, timeout_ms) catch return error.PollFailed;

        if (poll_result == 0) {
            return events.items;
        }
        if (fds[0].revents & std.posix.POLL.IN == 0) {
            return events.items;
        }

        // @TODO GILA(frosty_gale_9rz) This buffer is fixed which means if we get a large stdin we will block. We could use a ring buffer
        //       or we could keep shifting the buffer discarding old data. But for now if write_head == buf.len we will break
        //       and discard the data we read so far and next time we will start readign from incomplete data.
        var buf: [4096]u8 align(std.atomic.cache_line) = undefined;
        var write_head: usize = 0;
        reading_stdin: while (true) {
            // @TODO GILA(frosty_gale_9rz) we need to check here if write_head == buf.len
            const n = std.posix.read(self.fd, buf[write_head..]) catch return error.PollFailed;
            if (n == 0) {
                break :reading_stdin;
            }

            var data: []const u8 = buf[0 .. write_head + n];
            while (data.len > 0) {
                var consumed_bytes: usize = 0;
                const event = e.parseEvent(data, &consumed_bytes);
                if (consumed_bytes == 0) {
                    for (0..data.len) |i| {
                        buf[i] = data[i];
                    }
                    write_head = data.len;
                    break;
                }
                write_head = 0;
                data = data[consumed_bytes..];

                // @TODO GILA(dependent_thorn_fh0)  This basically stops if event queue is full. Try somethign else
                if (event != .none) events.appendBounded(event) catch break :reading_stdin;

                // @NOTE We are done if we have consumed all the bytes in the buffer and the data in the buffer does not
                //       fill the entire buffer i.e there should not be any leftover byts to read from stdin
                if (data.len == 0 and n != (buf.len - write_head)) break :reading_stdin;
            }

            // FIXME: In macos you cant poll dev/tty. It needs select
            poll_result = std.posix.poll(&fds, 0) catch return error.PollFailed;

            if (poll_result == 0) {
                break :reading_stdin;
            }
            if (fds[0].revents & std.posix.POLL.IN == 0) {
                break :reading_stdin;
            }
        }

        return events.items;
    }

    // @TODO move this to capability detection
    // pub fn kittyKeyboardAvailable(self: *Terminal, timeout_ms: i32) bool {
    //     self.write("\x1b[?u") catch {};
    //     self.write("\x1b[c") catch {};
    //     self.flush() catch {};
    //
    //     var fds = [_]std.posix.pollfd{
    //         .{
    //             .fd = self.stdin,
    //             .events = std.posix.POLL.IN,
    //             .revents = 0,
    //         },
    //     };
    //
    //     const poll_result = std.posix.poll(&fds, timeout_ms) catch return false;
    //     if (poll_result == 0) return false;
    //     var buf: [32]u8 = undefined;
    //     const n = std.posix.read(self.stdin, &buf) catch return false;
    //     if (n != 5) return false;
    //     if (!std.mem.eql(u8, buf[0..3], "\x1b[?")) return false;
    //     if (buf[4] != 'u') return false;
    //     return true;
    // }
};

