const std = @import("std");
const builtin = @import("builtin");

const stdx = @import("stdx");
const assert = stdx.inlineAssert;

const e = @import("event.zig");
const p = @import("parser.zig");
const Event = e.Event;
const seq = @import("sequences.zig");

const is_darwin = switch (builtin.os.tag) {
    .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => true,
    else => false,
};

extern "c" fn pselect(
    nfds: c_int,
    readfds: ?*FDSet,
    writefds: ?*FDSet,
    exceptfds: ?*FDSet,
    timeout: ?*const std.posix.timespec,
    sigmask: ?*const std.c.sigset_t,
) c_int;

const FDSet = extern struct {
    fds_bits: [32]i32,

    const fd_setsize: i32 = 1024;
    const nfd_bits: usize = @bitSizeOf(i32);

    pub const empty: FDSet = .{ .fds_bits = @splat(0) };

    fn setFd(set_out: *FDSet, fd: std.posix.fd_t) void {
        const index: usize = @intCast(fd);
        const word_index = index / nfd_bits;
        const bit_index = index % nfd_bits;
        const bit_mask: u32 = @as(u32, 1) << @intCast(bit_index);
        set_out.fds_bits[word_index] |= @as(i32, @bitCast(bit_mask));
    }

    fn isFdSet(set_in: *const FDSet, fd: std.posix.fd_t) bool {
        const index: usize = @intCast(fd);
        const word_index = index / nfd_bits;
        const bit_index = index % nfd_bits;
        const bit_mask: u32 = @as(u32, 1) << @intCast(bit_index);
        const word_bits: u32 = @bitCast(set_in.fds_bits[word_index]);
        return (word_bits & bit_mask) != 0;
    }
};

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

pub const CapabilityMode = enum {
    /// Only enable features that are the terminal responds to as being supported.
    strict,
    /// If the terminal does not respond to a feature query try to enable it anyway.
    /// NOTE: If the terminal does respond with not supported it will not be enabled.
    optimistic,
};

pub const TerminalConfig = struct {
    raw: bool = false,
    alt_screen: bool = false,
    bracketed_paste: bool = false,
    mouse: ?MouseOptions = null,
    kitty_keyboard_flags: ?KittyConfig = null,
    cursor_visible: bool = true,
    capability_mode: CapabilityMode = .strict,
    capability_probe_timeout_ms: i32 = 120,
    capability_fence_grace_ms: i32 = 15,
    read_buffer_initial_bytes: usize = std.heap.page_size_min,
    read_buffer_max_bytes: usize = std.heap.page_size_min * 16,
    read_overflow_policy: ReadOverflowPolicy = .drop_oldest,

    pub const tui_default = TerminalConfig{
        .raw = true,
        .alt_screen = true,
        .bracketed_paste = true,
        .mouse = .default,
        .kitty_keyboard_flags = .{ .disambiguate_escape_codes = true, .report_all_keys_as_escape_codes = true, .report_event_types = true },
        .cursor_visible = true,
        .capability_mode = .strict,
        .capability_probe_timeout_ms = 120,
        .capability_fence_grace_ms = 15,
    };
    pub const raw_terminal = TerminalConfig{ .raw = true };
    pub const default_terminal = TerminalConfig{};
};

const CapabilityState = struct {
    kitty_keyboard_reply_received: bool = false,
    kitty_keyboard_reply: ?e.KittyKeyboardQueryEvent = null,
    mouse_sgr_decrpm_status: ?e.DECRPMStatus = null,
    bracketed_paste_decrpm_status: ?e.DECRPMStatus = null,
    da1: ?e.PrimaryDeviceAttributesEvent = null,
    da2: ?e.SecondaryDeviceAttributesEvent = null,
};

pub const ReadOverflowPolicy = enum {
    drop_oldest,
};

const WaitReadableError = if (is_darwin)
    error{
        PselectInputFdOutOfRange,
        PselectWaitSyscallFailed,
        PselectInvalidFd,
        PselectInvalidArguments,
        PselectUnexpectedResult,
    }
else
    error{
        PollWaitSyscallFailed,
        PollWaitInvalidFd,
        PollWaitErrorEvent,
    };

pub const PollError = error{
    InputClosed,
    ReadInputFailed,
} || WaitReadableError;

pub const InitError = PollError || error{
    InvalidReadBufferInitialBytes,
    InvalidReadBufferMaxBytes,
    ReadBufferInitialExceedsMax,
    ReadBufferMaxTooSmallForBracketedPaste,
    OpenOutputTtyFailed,
    OpenInputTtyFailed,
    GetInputFdFlagsFailed,
    SetInputFdFlagsFailed,
    InitReadBufferFailed,
    ReadTerminalAttributesFailed,
    RawModeEnableFailed,
    SetAlternateScreenFailed,
    CapabilityQueryWriteFailed,
    EnableMouseFailed,
    EnableBracketedPasteFailed,
    PushKittyKeyboardFlagsFailed,
    SetCursorVisibilityFailed,
};

// @TODO we probably want to add a timeout when reading \x1b to make sure we actually have escape key press and not
//       the start of a control sequence. Except if kitty disambiguate_escape_codes is set to true.
pub const Terminal = struct {
    const ParseMode = enum {
        ground,
        bracketed_paste,
        skip_till_st_discard,
        csi_overflow_discard,
        osc_overflow_discard,
    };

    output_fd: std.Io.File.Handle,
    input_fd: std.Io.File.Handle,
    original_state: std.posix.termios,
    writer: std.Io.File.Writer,
    size: Size,
    read_buffer: stdx.GrowingRingBuffer,
    dropped_input_bytes: u64 = 0,
    // @TODO GILA(dependent_thorn_fh0) Make this a resizable buffer
    event_queue: [32]Event = undefined,
    config: TerminalConfig,
    capability_state_initial: CapabilityState = .{},
    parse_mode: ParseMode = .ground,

    pub const Size = struct { width: u16, height: u16 };

    pub var global_tty: ?*Terminal = null;

    pub fn getWriter(self: *Terminal) *std.Io.Writer {
        return &self.writer.interface;
    }

    inline fn enterParseMode(self: *Terminal, mode: ParseMode) void {
        self.parse_mode = mode;
    }

    pub fn init(terminal: *Terminal, config: TerminalConfig, write_buffer: []u8) InitError!void {
        if (config.read_buffer_initial_bytes == 0) return error.InvalidReadBufferInitialBytes;
        if (config.read_buffer_max_bytes == 0) return error.InvalidReadBufferMaxBytes;
        if (config.read_buffer_initial_bytes > config.read_buffer_max_bytes) return error.ReadBufferInitialExceedsMax;
        if (config.bracketed_paste and config.read_buffer_max_bytes < seq.bracketed_paste.end.len) {
            return error.ReadBufferMaxTooSmallForBracketedPaste;
        }

        var threaded = std.Io.Threaded.init_single_threaded;
        const io = threaded.ioBasic();

        const output_file = std.Io.Dir.openFileAbsolute(io, "/dev/tty", .{ .mode = .read_write, .allow_ctty = false }) catch return error.OpenOutputTtyFailed;
        errdefer output_file.close(io);
        terminal.output_fd = output_file.handle;

        const input_file = std.Io.Dir.openFileAbsolute(io, "/dev/tty", .{ .mode = .read_only, .allow_ctty = false }) catch return error.OpenInputTtyFailed;
        errdefer input_file.close(io);
        terminal.input_fd = input_file.handle;

        if (comptime is_darwin) {
            if (terminal.input_fd >= FDSet.fd_setsize) {
                return error.PselectInputFdOutOfRange;
            }
        }

        try terminal.setInputNonBlocking();

        terminal.read_buffer = stdx.GrowingRingBuffer.initCapacity(config.read_buffer_max_bytes, config.read_buffer_initial_bytes) catch return error.InitReadBufferFailed;
        errdefer terminal.read_buffer.deinit();
        terminal.dropped_input_bytes = 0;

        terminal.original_state = std.posix.tcgetattr(terminal.output_fd) catch return error.ReadTerminalAttributesFailed;
        terminal.writer = std.Io.File.Writer.initStreaming(std.Io.File{ .handle = terminal.output_fd }, io, write_buffer);
        terminal.size = terminal.getSize();
        @memset(&terminal.event_queue, .unrecognized);
        terminal.capability_state_initial = .{};
        terminal.config.read_buffer_initial_bytes = config.read_buffer_initial_bytes;
        terminal.config.read_buffer_max_bytes = config.read_buffer_max_bytes;
        terminal.config.read_overflow_policy = config.read_overflow_policy;
        terminal.config.capability_mode = config.capability_mode;

        terminal.config.raw = false;
        if (config.raw) terminal.makeRaw() catch return error.RawModeEnableFailed;
        errdefer terminal.unmakeRaw();

        terminal.config.alt_screen = false;
        if (config.alt_screen) terminal.setAlternateScreen() catch return error.SetAlternateScreenFailed;
        errdefer terminal.unsetAlternateScreen();

        terminal.sendCapabilityQueries() catch return error.CapabilityQueryWriteFailed;
        terminal.config.capability_probe_timeout_ms = config.capability_probe_timeout_ms;
        terminal.config.capability_fence_grace_ms = config.capability_fence_grace_ms;
        try terminal.waitForCapabilityResponses();

        terminal.config.mouse = null;
        if (config.mouse) |mouse_config| terminal.enableMouse(mouse_config) catch return error.EnableMouseFailed;
        errdefer terminal.disableMouse();

        terminal.config.kitty_keyboard_flags = null;
        if (config.kitty_keyboard_flags) |kitty_config| terminal.pushKittyKeyboardFlags(kitty_config) catch return error.PushKittyKeyboardFlagsFailed;
        errdefer terminal.popKittyKeyboardFlags() catch {};

        terminal.config.bracketed_paste = false;
        if (config.bracketed_paste) terminal.enableBracketedPaste() catch return error.EnableBracketedPasteFailed;
        errdefer terminal.disableBracketedPaste();

        terminal.setCursorVisible(config.cursor_visible) catch return error.SetCursorVisibilityFailed;

        terminal.enterParseMode(.ground);

        global_tty = terminal;
    }

    pub fn deinit(self: *Terminal) void {
        // IMPORTANT(adi): This order is important as we need to disable keyboard flag before leaving alternate screen
        if (self.config.kitty_keyboard_flags) |_| self.popKittyKeyboardFlags() catch {};
        if (self.config.bracketed_paste) self.disableBracketedPaste();
        if (self.config.mouse) |_| self.disableMouse();
        if (self.config.alt_screen) self.unsetAlternateScreen();
        if (self.config.raw) self.unmakeRaw();
        if (!self.config.cursor_visible) self.setCursorVisible(true) catch {};
        global_tty = null;

        self.read_buffer.deinit();

        var threaded = std.Io.Threaded.init_single_threaded;
        const io = threaded.ioBasic();
        (std.Io.File{ .handle = self.input_fd }).close(io);
        (std.Io.File{ .handle = self.output_fd }).close(io);
    }

    fn setInputNonBlocking(self: *Terminal) error{ GetInputFdFlagsFailed, SetInputFdFlagsFailed }!void {
        var flags = std.posix.fcntl(self.input_fd, std.posix.F.GETFL, 0) catch return error.GetInputFdFlagsFailed;
        flags |= @as(usize, 1 << @bitOffsetOf(std.posix.O, "NONBLOCK"));
        _ = std.posix.fcntl(self.input_fd, std.posix.F.SETFL, flags) catch return error.SetInputFdFlagsFailed;
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
        const r = std.posix.system.ioctl(self.output_fd, std.posix.T.IOCGWINSZ, @intFromPtr(&size));
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
        std.posix.tcsetattr(self.output_fd, .FLUSH, raw) catch {
            return error.Failed;
        };
        self.config.raw = true;
    }

    pub fn unmakeRaw(self: *Terminal) void {
        if (!self.config.raw) return;
        std.posix.tcsetattr(self.output_fd, .FLUSH, self.original_state) catch {};
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
        if (self.config.mouse) |_| return;
        const writer = self.getWriter();
        errdefer self.config.mouse = null;
        options.level.enable(writer) catch return error.WriteFailed;
        self.config.mouse = .{ .sgr = false, .level = options.level };
        errdefer options.level.disable(writer) catch {};
        if (options.sgr) {
            if (self.capability_state_initial.mouse_sgr_decrpm_status) |status| {
                switch (status) {
                    .set, .permanently_set => self.config.mouse.?.sgr = true,
                    .reset => {
                        seq.mouse.enableSgr(writer) catch return error.WriteFailed;
                        self.config.mouse.?.sgr = true;
                    },
                    else => {},
                }
            } else if (self.config.capability_mode == .optimistic) {
                seq.mouse.enableSgr(writer) catch return error.WriteFailed;
                self.config.mouse.?.sgr = true;
            }
        }
        try self.flush();
    }

    pub fn disableMouse(self: *Terminal) void {
        if (self.config.mouse) |options| {
            const writer = self.getWriter();
            options.level.disable(writer) catch {};
            if (options.sgr) {
                if (self.config.capability_mode == .optimistic) {
                    seq.mouse.disableSgr(writer) catch {};
                } else if (self.capability_state_initial.mouse_sgr_decrpm_status) |status| {
                    switch (status) {
                        .reset => seq.mouse.disableSgr(writer) catch {},
                        else => {},
                    }
                }
            }
            self.flush() catch {};
            self.config.mouse = null;
        }
    }

    pub fn enableBracketedPaste(self: *Terminal) error{WriteFailed}!void {
        if (self.config.bracketed_paste) return;
        const writer = self.getWriter();
        errdefer self.config.bracketed_paste = false;
        if (self.capability_state_initial.bracketed_paste_decrpm_status) |status| {
            switch (status) {
                .set, .permanently_set => self.config.bracketed_paste = true,
                .reset => {
                    try seq.csiPrivateSet(writer, .bracketed_paste);
                    self.config.bracketed_paste = true;
                },
                else => {},
            }
        } else if (self.config.capability_mode == .optimistic) {
            try seq.csiPrivateSet(writer, .bracketed_paste);
            self.config.bracketed_paste = true;
        }
        try self.flush();
    }

    pub fn disableBracketedPaste(self: *Terminal) void {
        if (self.config.bracketed_paste) {
            if (self.capability_state_initial.bracketed_paste_decrpm_status) |status| {
                switch (status) {
                    .reset => seq.csiPrivateReset(self.getWriter(), .bracketed_paste) catch {},
                    else => {},
                }
            } else if (self.config.capability_mode == .optimistic) {
                seq.csiPrivateReset(self.getWriter(), .bracketed_paste) catch {};
            }
            self.flush() catch {};
            self.config.bracketed_paste = false;
        }
    }

    pub fn pushKittyKeyboardFlags(self: *Terminal, config: KittyConfig) error{WriteFailed}!void {
        if (self.config.kitty_keyboard_flags) |_| return;
        if (self.config.capability_mode == .optimistic or self.capability_state_initial.kitty_keyboard_reply_received) {
            seq.kitty.pushKeyboardFlags(self.getWriter(), config) catch return error.WriteFailed;
            try self.flush();
            self.config.kitty_keyboard_flags = config;
        }
    }

    pub fn popKittyKeyboardFlags(self: *Terminal) error{WriteFailed}!void {
        if (self.config.kitty_keyboard_flags) |_| {
            seq.kitty.popKeyboardFlags(self.getWriter()) catch return error.WriteFailed;
            try self.flush();
            self.config.kitty_keyboard_flags = null;
        }
    }

    const waitReadable = if (is_darwin) waitReadablePselect else waitReadablePoll;

    fn waitReadablePoll(self: *Terminal, timeout_ms: i32) PollError!bool {
        var fds = [_]std.posix.pollfd{
            .{
                .fd = self.input_fd,
                .events = std.posix.POLL.IN,
                .revents = 0,
            },
        };

        const poll_result = std.posix.poll(&fds, timeout_ms) catch return error.PollWaitSyscallFailed;
        if (poll_result == 0) return false;

        const revents = fds[0].revents;
        if ((revents & std.posix.POLL.NVAL) != 0) return error.PollWaitInvalidFd;
        if ((revents & std.posix.POLL.ERR) != 0) return error.PollWaitErrorEvent;
        if ((revents & std.posix.POLL.HUP) != 0 and (revents & std.posix.POLL.IN) == 0) return error.InputClosed;
        return (revents & std.posix.POLL.IN) != 0;
    }

    fn waitReadablePselect(self: *Terminal, timeout_ms: i32) PollError!bool {
        if (self.input_fd < 0) return error.PselectInvalidFd;
        if (self.input_fd >= FDSet.fd_setsize) return error.PselectInputFdOutOfRange;

        const nfds: c_int = @intCast(self.input_fd + 1);
        const has_timeout = timeout_ms >= 0;
        const timeout_total_ms: u64 = @intCast(@max(timeout_ms, 0));
        var timer: std.time.Timer = undefined;
        if (has_timeout) timer = std.time.Timer.start() catch unreachable;
        var attempted_wait = false;

        while (true) {
            var readfds: FDSet = .empty;
            readfds.setFd(self.input_fd);

            var timeout_spec: std.posix.timespec = undefined;
            const timeout_ptr: ?*const std.posix.timespec = if (!has_timeout) null else blk: {
                if (timeout_total_ms == 0) {
                    if (attempted_wait) return false;
                    timeout_spec = .{ .sec = 0, .nsec = 0 };
                    break :blk &timeout_spec;
                }

                const elapsed_ms = timer.read() / std.time.ns_per_ms;
                if (elapsed_ms >= timeout_total_ms) return false;

                const remaining_ms = timeout_total_ms - elapsed_ms;
                timeout_spec = .{
                    .sec = @intCast(remaining_ms / 1000),
                    .nsec = @intCast((remaining_ms % 1000) * std.time.ns_per_ms),
                };
                break :blk &timeout_spec;
            };

            attempted_wait = true;
            const rc = pselect(nfds, &readfds, null, null, timeout_ptr, null);
            switch (std.posix.errno(rc)) {
                .SUCCESS => {
                    if (rc == 0) return false;
                    if (!readfds.isFdSet(self.input_fd)) return error.PselectUnexpectedResult;
                    return true;
                },
                .INTR => continue,
                .BADF => return error.PselectInvalidFd,
                .INVAL => return error.PselectInvalidArguments,
                else => return error.PselectWaitSyscallFailed,
            }
        }
    }

    // @TODO This should drain the event queue in multithreaded mode when that is implemented
    /// Polls for terminal input and returns parsed events.
    ///
    /// `timeout_ms` follows poll semantics: negative blocks indefinitely,
    /// zero is non-blocking, and positive waits up to that many milliseconds (precision is not guaranteed).
    /// If exact frame timeout is required request less than yu think and then busy loop for the rest.
    ///
    /// The returned slice is backed by `Terminal.event_queue` and is valid until
    /// the next call to `pollEvents` on the same terminal instance.
    ///
    /// `Event.paste_data` and `Event.osc_pointer_shape.value` borrow parser
    /// buffer memory and are also valid only until the next `pollEvents` call.
    /// Copy those slices if the data must outlive this call.
    pub fn pollEvents(self: *Terminal, timeout_ms: i32) PollError![]Event {
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

        try self.parseInput(timeout_ms, &events);
        return events.items;
    }

    const ParseBufferedState = enum {
        drained,
        need_more_input,
        queue_full,
        stream_exported_dont_invalidate_buffer,
    };

    inline fn pendingParseState(emitted_stream_data: bool) ParseBufferedState {
        return if (emitted_stream_data)
            .stream_exported_dont_invalidate_buffer
        else
            .need_more_input;
    }

    fn parseBufferedEvents(self: *Terminal, events: *std.ArrayList(Event)) ParseBufferedState {
        if (self.read_buffer.len == 0) return .drained;

        var emitted_stream_data = false;
        var data = self.read_buffer.linearizeReadable();
        var consumed_total: usize = 0;
        defer if (consumed_total > 0) self.read_buffer.consume(consumed_total);
        while (data.len > 0) {
            switch (self.parse_mode) {
                .skip_till_st_discard, .csi_overflow_discard, .osc_overflow_discard => |mode| {
                    const result = switch (mode) {
                        .skip_till_st_discard => scanSkipTillSTDiscard(data),
                        .csi_overflow_discard => scanCSIOverflowDiscard(data),
                        .osc_overflow_discard => scanOSCOverflowDiscard(data),
                        else => unreachable,
                    };
                    switch (result) {
                        .terminated, .resync => |n| {
                            consumed_total += n;
                            self.enterParseMode(.ground);
                            data = data[n..];
                        },
                        .need_more => |n| {
                            consumed_total += n;
                            return pendingParseState(emitted_stream_data);
                        },
                    }
                },
                .bracketed_paste => {
                    const end = std.mem.find(u8, data, seq.bracketed_paste.end);
                    if (end) |position| {
                        if (position > 0) {
                            events.appendBounded(.{ .paste_data = data[0..position] }) catch return .queue_full;
                            emitted_stream_data = true;
                            consumed_total += position;
                        }
                        events.appendBounded(.paste_end) catch return .queue_full;
                        self.enterParseMode(.ground);
                        consumed_total += seq.bracketed_paste.end.len;
                        data = data[position + seq.bracketed_paste.end.len ..];
                        continue;
                    }

                    const overlap = bracketedPasteEndOverlap(data);
                    assert(overlap <= data.len);
                    const payload_len = data.len - overlap;
                    if (payload_len > 0) {
                        events.appendBounded(.{ .paste_data = data[0..payload_len] }) catch return .queue_full;
                        emitted_stream_data = true;
                        consumed_total += payload_len;
                    }

                    return pendingParseState(emitted_stream_data);
                },
                .ground => {
                    var consumed_bytes: usize = 0;
                    const parsed = p.parseEvent(data, &consumed_bytes);

                    // @NOTE(adi): Paste end is emiited by this function and if we encounter it from the parseEvent it must be
                    //             a stray end and should be ignored.
                    switch (parsed) {
                        .need_more_input => {
                            assert(consumed_bytes == 0);
                            return pendingParseState(emitted_stream_data);
                        },
                        .ignored => {
                            assert(consumed_bytes > 0);
                        },
                        .skip_till_st => {
                            assert(consumed_bytes > 0);
                            self.enterParseMode(.skip_till_st_discard);
                        },
                        .osc_overflow, .osc52_start => {
                            // NOTE(adi): OSC52 is highly unlikley to be emitted when using this as a terminal application
                            //            almost all terminals I know will disregard OSC52 requests from apps due to the
                            //            security implications. But the parser is designed to be able to handle it in case
                            //            we want to use it for a PTY.
                            assert(consumed_bytes > 0);
                            self.enterParseMode(.osc_overflow_discard);
                        },
                        .csi_overflow => {
                            assert(consumed_bytes > 0);
                            self.enterParseMode(.csi_overflow_discard);
                        },
                        .event => |ev| {
                            assert(consumed_bytes > 0);
                            if (ev == .paste_end) {
                                // Ignore unmatched paste end.
                            } else {
                                events.appendBounded(ev) catch return .queue_full;
                            }
                            if (ev == .paste_start) {
                                self.enterParseMode(.bracketed_paste);
                            } else if (ev == .osc_pointer_shape) {
                                emitted_stream_data = true;
                            }
                        },
                    }

                    consumed_total += consumed_bytes;
                    data = data[consumed_bytes..];
                },
            }
        }

        return if (emitted_stream_data)
            .stream_exported_dont_invalidate_buffer
        else
            .drained;
    }

    fn bracketedPasteEndOverlap(data: []const u8) usize {
        // @NOTE(adi): Keep a suffix that could be the prefix of "\x1b[201~" so split end markers
        //             across reads are not emitted as paste payload bytes.
        assert(seq.bracketed_paste.end.len > 0);
        const max_overlap = @min(data.len, seq.bracketed_paste.end.len - 1);
        var overlap = max_overlap;
        while (overlap > 0) : (overlap -= 1) {
            if (std.mem.eql(u8, data[data.len - overlap ..], seq.bracketed_paste.end[0..overlap])) {
                return overlap;
            }
        }
        return 0;
    }

    const OverflowDiscardResult = union(enum) {
        terminated: usize,
        resync: usize,
        need_more: usize,
    };

    fn scanCSIOverflowDiscard(data: []const u8) OverflowDiscardResult {
        for (data, 0..) |byte, i| {
            switch (byte) {
                0x1b => return .{ .resync = i },
                0x40...0x7E => return .{ .terminated = i + 1 },
                else => {},
            }
        }
        return .{ .need_more = data.len };
    }

    fn scanSkipTillSTDiscard(data: []const u8) OverflowDiscardResult {
        for (data, 0..) |byte, i| {
            if (byte == 0x1b) {
                if (i + 1 >= data.len) return .{ .need_more = i };
                if (data[i + 1] == '\\') return .{ .terminated = i + 2 };
                return .{ .resync = i };
            }
        }
        return .{ .need_more = data.len };
    }

    fn scanOSCOverflowDiscard(data: []const u8) OverflowDiscardResult {
        for (data, 0..) |byte, i| {
            switch (byte) {
                0x07 => return .{ .terminated = i + 1 },
                0x1b => {
                    if (i + 1 >= data.len) return .{ .need_more = i };
                    if (data[i + 1] == '\\') return .{ .terminated = i + 2 };
                    return .{ .resync = i };
                },
                else => {},
            }
        }
        return .{ .need_more = data.len };
    }

    fn ensureReadBufferWritable(self: *Terminal) void {
        if (self.read_buffer.len < self.read_buffer.capacity()) return;

        if (self.read_buffer.ensureWritable(1)) {
            @branchHint(.likely);
            return;
        } else |_| {}

        switch (self.config.read_overflow_policy) {
            .drop_oldest => {
                // @TODO What is a good value for this?
                const drop_count = 1;
                const dropped = self.read_buffer.dropOldest(drop_count);
                self.dropped_input_bytes +|= dropped;
            },
        }
    }

    fn readIntoReadBuffer(self: *Terminal) PollError!usize {
        self.ensureReadBufferWritable();

        const writable = self.read_buffer.writableSlices();
        var iovecs: [2]std.posix.iovec = undefined;
        var iovecs_len: usize = 0;
        if (writable.first.len > 0) {
            iovecs[iovecs_len] = .{ .base = writable.first.ptr, .len = writable.first.len };
            iovecs_len += 1;
        }
        if (writable.second.len > 0) {
            iovecs[iovecs_len] = .{ .base = writable.second.ptr, .len = writable.second.len };
            iovecs_len += 1;
        }
        assert(iovecs_len > 0);

        while (true) {
            const rc = std.posix.system.readv(self.input_fd, iovecs[0..iovecs_len].ptr, @intCast(iovecs_len));
            switch (std.posix.errno(rc)) {
                .SUCCESS => {
                    if (rc == 0) return error.InputClosed;
                    const bytes_read: usize = @intCast(rc);
                    self.read_buffer.didWrite(bytes_read);
                    return bytes_read;
                },
                .INVAL => unreachable,
                .FAULT => unreachable,
                .INTR => continue,
                .AGAIN => return 0,
                else => return error.ReadInputFailed,
            }
        }
    }

    fn parseInput(self: *Terminal, timeout_ms: i32, events: *std.ArrayList(Event)) PollError!void {
        const state = self.parseBufferedEvents(events);
        switch (state) {
            .queue_full, .stream_exported_dont_invalidate_buffer => return,
            .drained, .need_more_input => {},
        }

        if (!(try self.waitReadable(timeout_ms))) return;

        while (true) {
            const bytes_read = try self.readIntoReadBuffer();
            if (bytes_read == 0) return;
            switch (self.parseBufferedEvents(events)) {
                .queue_full, .stream_exported_dont_invalidate_buffer => return,
                .drained, .need_more_input => {},
            }
        }
    }

    fn sendCapabilityQueries(self: *Terminal) error{WriteFailed}!void {
        const writer = self.getWriter();

        try writer.writeAll(seq.query.kitty_keyboard_support);
        try seq.query.DECRQM(writer, .mouse_sgr);
        try seq.query.DECRQM(writer, .bracketed_paste);
        try writer.writeAll(seq.query.secondary_device_attributes);
        // @NOTE We write the primary device attributes query last so that when we receive it we know that most
        //       of the other queries have been received. In rare cases it might be possible that the responses
        //       to the queries are received out of order but I dont know yet if that is possible.
        try writer.writeAll(seq.query.primary_device_attributes);
        try self.flush();
    }

    fn waitForCapabilityResponses(self: *Terminal) PollError!void {
        var events = std.ArrayList(Event).initBuffer(&self.event_queue);

        const timeout_ms = self.config.capability_probe_timeout_ms;
        const fence_grace_ms = self.config.capability_fence_grace_ms;
        const timeout_ms_clamped = @max(timeout_ms, 0);
        const fence_grace_ms_clamped = @max(fence_grace_ms, 0);
        var timeout: u64 = @intCast(timeout_ms_clamped);
        var timer = std.time.Timer.start() catch unreachable;
        while (self.hasPendingCapabilityQueries()) {
            const elapsed_ms = timer.read() / std.time.ns_per_ms;
            if (elapsed_ms >= timeout) break;

            const remaining_ms = timeout - elapsed_ms;

            try self.parseInput(@intCast(remaining_ms), &events);
            const fence_seen = self.consumeCapabilityEvents(&events);
            if (fence_seen) {
                timeout = fence_grace_ms_clamped;
                timer.reset();
            }
        }
    }

    fn hasPendingCapabilityQueries(self: *const Terminal) bool {
        if (!self.capability_state_initial.kitty_keyboard_reply_received) return true;
        if (self.capability_state_initial.mouse_sgr_decrpm_status == null) return true;
        if (self.capability_state_initial.bracketed_paste_decrpm_status == null) return true;
        if (self.capability_state_initial.da1 == null or self.capability_state_initial.da2 == null) return true;
        return false;
    }

    fn consumeCapabilityEvents(self: *Terminal, events: *std.ArrayList(Event)) bool {
        var fence_seen = false;
        for (events.items) |event| {
            switch (event) {
                .kitty_keyboard_query => |reply| {
                    self.capability_state_initial.kitty_keyboard_reply_received = true;
                    self.capability_state_initial.kitty_keyboard_reply = reply;
                },
                .decrpm => |reply| {
                    if (reply.mode == @intFromEnum(seq.PrivateMode.mouse_sgr)) {
                        self.capability_state_initial.mouse_sgr_decrpm_status = reply.status;
                    } else if (reply.mode == @intFromEnum(seq.PrivateMode.bracketed_paste)) {
                        self.capability_state_initial.bracketed_paste_decrpm_status = reply.status;
                    }
                },
                .primary_device_attributes => |reply| {
                    fence_seen = true;
                    self.capability_state_initial.da1 = reply;
                },
                .secondary_device_attributes => |reply| self.capability_state_initial.da2 = reply,
                else => {},
            }
        }
        events.shrinkRetainingCapacity(0);
        return fence_seen;
    }
};

fn initTestTerminal(initial: usize, max: usize) !Terminal {
    var terminal: Terminal = undefined;
    terminal.read_buffer = try stdx.GrowingRingBuffer.initCapacity(max, initial);
    terminal.dropped_input_bytes = 0;
    terminal.config = .default_terminal;
    terminal.capability_state_initial = .{};
    terminal.parse_mode = .ground;
    terminal.config.read_buffer_initial_bytes = initial;
    terminal.config.read_buffer_max_bytes = max;
    terminal.config.read_overflow_policy = .drop_oldest;
    return terminal;
}

test "parseBufferedEvents preserves incomplete bytes" {
    var terminal = try initTestTerminal(std.heap.page_size_min, std.heap.page_size_min * 2);
    defer terminal.read_buffer.deinit();

    _ = try terminal.read_buffer.write("\x1b[");

    var queue_storage: [4]Event = undefined;
    var events = std.ArrayList(Event).initBuffer(&queue_storage);

    const state = terminal.parseBufferedEvents(&events);
    try std.testing.expectEqual(Terminal.ParseBufferedState.need_more_input, state);
    try std.testing.expectEqual(@as(usize, 0), events.items.len);
    try std.testing.expectEqualStrings("\x1b[", terminal.read_buffer.linearizeReadable());
}

test "parseBufferedEvents keeps pending bytes when queue is full" {
    var terminal = try initTestTerminal(std.heap.page_size_min, std.heap.page_size_min * 2);
    defer terminal.read_buffer.deinit();

    _ = try terminal.read_buffer.write("ab");

    var queue_storage: [1]Event = undefined;
    var events = std.ArrayList(Event).initBuffer(&queue_storage);

    const state = terminal.parseBufferedEvents(&events);
    try std.testing.expectEqual(Terminal.ParseBufferedState.queue_full, state);
    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expect(@as(std.meta.Tag(Event), events.items[0]) == .key_pressed);
    try std.testing.expectEqual(e.KeyEvent.Code.a, events.items[0].key_pressed.code);
    try std.testing.expectEqualStrings("b", terminal.read_buffer.linearizeReadable());
}

test "parseBufferedEvents does not consume paste payload on queue_full" {
    var terminal = try initTestTerminal(std.heap.page_size_min, std.heap.page_size_min * 2);
    defer terminal.read_buffer.deinit();

    _ = try terminal.read_buffer.write("\x1b[200~x\x1b[201~");

    var queue_storage_small: [1]Event = undefined;
    var small_events = std.ArrayList(Event).initBuffer(&queue_storage_small);

    const first_state = terminal.parseBufferedEvents(&small_events);
    try std.testing.expectEqual(Terminal.ParseBufferedState.queue_full, first_state);
    try std.testing.expectEqual(@as(usize, 1), small_events.items.len);
    try std.testing.expect(@as(std.meta.Tag(Event), small_events.items[0]) == .paste_start);
    try std.testing.expectEqual(Terminal.ParseMode.bracketed_paste, terminal.parse_mode);
    try std.testing.expectEqualStrings("x\x1b[201~", terminal.read_buffer.linearizeReadable());

    var queue_storage_large: [4]Event = undefined;
    var large_events = std.ArrayList(Event).initBuffer(&queue_storage_large);

    const second_state = terminal.parseBufferedEvents(&large_events);
    try std.testing.expectEqual(
        Terminal.ParseBufferedState.stream_exported_dont_invalidate_buffer,
        second_state,
    );
    try std.testing.expectEqual(@as(usize, 2), large_events.items.len);
    try std.testing.expect(@as(std.meta.Tag(Event), large_events.items[0]) == .paste_data);
    try std.testing.expectEqualStrings("x", large_events.items[0].paste_data);
    try std.testing.expect(@as(std.meta.Tag(Event), large_events.items[1]) == .paste_end);
    try std.testing.expectEqual(Terminal.ParseMode.ground, terminal.parse_mode);
    try std.testing.expectEqual(@as(usize, 0), terminal.read_buffer.len);
}

test "parseBufferedEvents ignores stray paste_end and keeps balanced paste events" {
    var terminal = try initTestTerminal(std.heap.page_size_min, std.heap.page_size_min * 2);
    defer terminal.read_buffer.deinit();

    _ = try terminal.read_buffer.write("\x1b[201~\x1b[200~hello\x1b[201~z");

    var queue_storage: [8]Event = undefined;
    var events = std.ArrayList(Event).initBuffer(&queue_storage);

    const state = terminal.parseBufferedEvents(&events);
    try std.testing.expectEqual(Terminal.ParseBufferedState.stream_exported_dont_invalidate_buffer, state);
    try std.testing.expectEqual(@as(usize, 4), events.items.len);
    try std.testing.expect(@as(std.meta.Tag(Event), events.items[0]) == .paste_start);
    try std.testing.expect(@as(std.meta.Tag(Event), events.items[1]) == .paste_data);
    try std.testing.expectEqualStrings("hello", events.items[1].paste_data);
    try std.testing.expect(@as(std.meta.Tag(Event), events.items[2]) == .paste_end);
    try std.testing.expect(@as(std.meta.Tag(Event), events.items[3]) == .key_pressed);
    try std.testing.expectEqual(@as(e.KeyEvent.Code, @enumFromInt('z')), events.items[3].key_pressed.code);
    try std.testing.expectEqual(Terminal.ParseMode.ground, terminal.parse_mode);
}

test "parseBufferedEvents discards OSC52 payload and preserves stream sync" {
    var terminal = try initTestTerminal(std.heap.page_size_min, std.heap.page_size_min * 2);
    defer terminal.read_buffer.deinit();

    _ = try terminal.read_buffer.write("\x1b]52;c;Zm9v\x1b\\z");

    var queue_storage: [8]Event = undefined;
    var events = std.ArrayList(Event).initBuffer(&queue_storage);

    const state = terminal.parseBufferedEvents(&events);
    try std.testing.expectEqual(Terminal.ParseBufferedState.drained, state);
    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expect(@as(std.meta.Tag(Event), events.items[0]) == .key_pressed);
    try std.testing.expectEqual(@as(e.KeyEvent.Code, @enumFromInt('z')), events.items[0].key_pressed.code);
    try std.testing.expectEqual(Terminal.ParseMode.ground, terminal.parse_mode);
}

test "parseBufferedEvents keeps trailing ESC during OSC52 discard" {
    var terminal = try initTestTerminal(std.heap.page_size_min, std.heap.page_size_min * 2);
    defer terminal.read_buffer.deinit();

    const payload_len = 1024;
    const total_len = 7 + payload_len + 1;
    var sequence = try std.testing.allocator.alloc(u8, total_len);
    defer std.testing.allocator.free(sequence);

    sequence[0] = 0x1b;
    sequence[1] = ']';
    sequence[2] = '5';
    sequence[3] = '2';
    sequence[4] = ';';
    sequence[5] = 'c';
    sequence[6] = ';';
    @memset(sequence[7 .. 7 + payload_len], 'A');
    sequence[7 + payload_len] = 0x1b;

    _ = try terminal.read_buffer.write(sequence);

    var queue_storage: [8]Event = undefined;
    var events = std.ArrayList(Event).initBuffer(&queue_storage);

    const first_state = terminal.parseBufferedEvents(&events);
    try std.testing.expectEqual(Terminal.ParseBufferedState.need_more_input, first_state);
    try std.testing.expectEqual(@as(usize, 0), events.items.len);
    try std.testing.expectEqual(@as(usize, 1), terminal.read_buffer.len);
    try std.testing.expectEqual(Terminal.ParseMode.osc_overflow_discard, terminal.parse_mode);

    _ = try terminal.read_buffer.write("\\z");
    events.clearRetainingCapacity();

    const second_state = terminal.parseBufferedEvents(&events);
    try std.testing.expectEqual(Terminal.ParseBufferedState.drained, second_state);
    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expect(@as(std.meta.Tag(Event), events.items[0]) == .key_pressed);
    try std.testing.expectEqual(@as(e.KeyEvent.Code, @enumFromInt('z')), events.items[0].key_pressed.code);
    try std.testing.expectEqual(@as(usize, 0), terminal.read_buffer.len);
    try std.testing.expectEqual(Terminal.ParseMode.ground, terminal.parse_mode);
}

test "parseBufferedEvents discards overlong non-52 OSC and preserves stream sync" {
    var terminal = try initTestTerminal(std.heap.page_size_min, std.heap.page_size_min * 2);
    defer terminal.read_buffer.deinit();

    const payload_len = p.osc_len_max_default + 64;
    const total_len = 5 + payload_len + 2 + 1;
    var sequence = try std.testing.allocator.alloc(u8, total_len);
    defer std.testing.allocator.free(sequence);

    sequence[0] = 0x1b;
    sequence[1] = ']';
    sequence[2] = '4';
    sequence[3] = ';';
    sequence[4] = ';';
    @memset(sequence[5 .. 5 + payload_len], 'A');
    sequence[5 + payload_len] = 0x1b;
    sequence[5 + payload_len + 1] = '\\';
    sequence[5 + payload_len + 2] = 'z';

    _ = try terminal.read_buffer.write(sequence);

    var queue_storage: [8]Event = undefined;
    var events = std.ArrayList(Event).initBuffer(&queue_storage);

    const state = terminal.parseBufferedEvents(&events);
    try std.testing.expectEqual(Terminal.ParseBufferedState.drained, state);
    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expect(@as(std.meta.Tag(Event), events.items[0]) == .key_pressed);
    try std.testing.expectEqual(@as(e.KeyEvent.Code, @enumFromInt('z')), events.items[0].key_pressed.code);
    try std.testing.expectEqual(@as(usize, 0), terminal.read_buffer.len);
    try std.testing.expectEqual(Terminal.ParseMode.ground, terminal.parse_mode);
}

test "parseBufferedEvents resyncs malformed overlong OSC at new control sequence" {
    var terminal = try initTestTerminal(std.heap.page_size_min, std.heap.page_size_min * 2);
    defer terminal.read_buffer.deinit();

    const payload_len = p.osc_len_max_default + 64;
    const total_len = 5 + payload_len + 3;
    var sequence = try std.testing.allocator.alloc(u8, total_len);
    defer std.testing.allocator.free(sequence);

    sequence[0] = 0x1b;
    sequence[1] = ']';
    sequence[2] = '4';
    sequence[3] = ';';
    sequence[4] = ';';
    @memset(sequence[5 .. 5 + payload_len], 'A');
    sequence[5 + payload_len] = 0x1b;
    sequence[5 + payload_len + 1] = '[';
    sequence[5 + payload_len + 2] = 'A';

    _ = try terminal.read_buffer.write(sequence);

    var queue_storage: [8]Event = undefined;
    var events = std.ArrayList(Event).initBuffer(&queue_storage);

    const state = terminal.parseBufferedEvents(&events);
    try std.testing.expectEqual(Terminal.ParseBufferedState.drained, state);
    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expect(@as(std.meta.Tag(Event), events.items[0]) == .key_pressed);
    try std.testing.expectEqual(e.KeyEvent.Code.up, events.items[0].key_pressed.code);
    try std.testing.expectEqual(@as(usize, 0), terminal.read_buffer.len);
    try std.testing.expectEqual(Terminal.ParseMode.ground, terminal.parse_mode);
}

test "parseBufferedEvents keeps trailing ESC during OSC overflow discard" {
    var terminal = try initTestTerminal(std.heap.page_size_min, std.heap.page_size_min * 2);
    defer terminal.read_buffer.deinit();

    const payload_len = p.osc_len_max_default + 64;
    const total_len = 5 + payload_len + 1;
    var first_chunk = try std.testing.allocator.alloc(u8, total_len);
    defer std.testing.allocator.free(first_chunk);

    first_chunk[0] = 0x1b;
    first_chunk[1] = ']';
    first_chunk[2] = '4';
    first_chunk[3] = ';';
    first_chunk[4] = ';';
    @memset(first_chunk[5 .. 5 + payload_len], 'A');
    first_chunk[5 + payload_len] = 0x1b;

    _ = try terminal.read_buffer.write(first_chunk);

    var queue_storage: [8]Event = undefined;
    var events = std.ArrayList(Event).initBuffer(&queue_storage);

    const first_state = terminal.parseBufferedEvents(&events);
    try std.testing.expectEqual(Terminal.ParseBufferedState.need_more_input, first_state);
    try std.testing.expectEqual(@as(usize, 0), events.items.len);
    try std.testing.expectEqual(@as(usize, 1), terminal.read_buffer.len);
    try std.testing.expectEqual(Terminal.ParseMode.osc_overflow_discard, terminal.parse_mode);

    _ = try terminal.read_buffer.write("[A");
    events.clearRetainingCapacity();

    const second_state = terminal.parseBufferedEvents(&events);
    try std.testing.expectEqual(Terminal.ParseBufferedState.drained, second_state);
    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expect(@as(std.meta.Tag(Event), events.items[0]) == .key_pressed);
    try std.testing.expectEqual(e.KeyEvent.Code.up, events.items[0].key_pressed.code);
    try std.testing.expectEqual(@as(usize, 0), terminal.read_buffer.len);
    try std.testing.expectEqual(Terminal.ParseMode.ground, terminal.parse_mode);
}

test "parseBufferedEvents discards ESC P payload until ST" {
    var terminal = try initTestTerminal(std.heap.page_size_min, std.heap.page_size_min * 2);
    defer terminal.read_buffer.deinit();

    _ = try terminal.read_buffer.write("\x1bPignored\x1b\\z");

    var queue_storage: [8]Event = undefined;
    var events = std.ArrayList(Event).initBuffer(&queue_storage);

    const state = terminal.parseBufferedEvents(&events);
    try std.testing.expectEqual(Terminal.ParseBufferedState.drained, state);
    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expect(@as(std.meta.Tag(Event), events.items[0]) == .key_pressed);
    try std.testing.expectEqual(@as(e.KeyEvent.Code, @enumFromInt('z')), events.items[0].key_pressed.code);
    try std.testing.expectEqual(@as(usize, 0), terminal.read_buffer.len);
    try std.testing.expectEqual(Terminal.ParseMode.ground, terminal.parse_mode);
}

test "parseBufferedEvents resyncs malformed ESC P payload at next control sequence" {
    var terminal = try initTestTerminal(std.heap.page_size_min, std.heap.page_size_min * 2);
    defer terminal.read_buffer.deinit();

    _ = try terminal.read_buffer.write("\x1bPignored\x1b[A");

    var queue_storage: [8]Event = undefined;
    var events = std.ArrayList(Event).initBuffer(&queue_storage);

    const state = terminal.parseBufferedEvents(&events);
    try std.testing.expectEqual(Terminal.ParseBufferedState.drained, state);
    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expect(@as(std.meta.Tag(Event), events.items[0]) == .key_pressed);
    try std.testing.expectEqual(e.KeyEvent.Code.up, events.items[0].key_pressed.code);
    try std.testing.expectEqual(@as(usize, 0), terminal.read_buffer.len);
    try std.testing.expectEqual(Terminal.ParseMode.ground, terminal.parse_mode);
}

test "parseBufferedEvents keeps trailing ESC during skip-till-ST discard" {
    var terminal = try initTestTerminal(std.heap.page_size_min, std.heap.page_size_min * 2);
    defer terminal.read_buffer.deinit();

    _ = try terminal.read_buffer.write("\x1bPignored\x1b");

    var queue_storage: [8]Event = undefined;
    var events = std.ArrayList(Event).initBuffer(&queue_storage);

    const first_state = terminal.parseBufferedEvents(&events);
    try std.testing.expectEqual(Terminal.ParseBufferedState.need_more_input, first_state);
    try std.testing.expectEqual(@as(usize, 0), events.items.len);
    try std.testing.expectEqual(@as(usize, 1), terminal.read_buffer.len);
    try std.testing.expectEqual(Terminal.ParseMode.skip_till_st_discard, terminal.parse_mode);

    _ = try terminal.read_buffer.write("\\z");
    events.clearRetainingCapacity();

    const second_state = terminal.parseBufferedEvents(&events);
    try std.testing.expectEqual(Terminal.ParseBufferedState.drained, second_state);
    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expect(@as(std.meta.Tag(Event), events.items[0]) == .key_pressed);
    try std.testing.expectEqual(@as(e.KeyEvent.Code, @enumFromInt('z')), events.items[0].key_pressed.code);
    try std.testing.expectEqual(@as(usize, 0), terminal.read_buffer.len);
    try std.testing.expectEqual(Terminal.ParseMode.ground, terminal.parse_mode);
}

test "parseBufferedEvents discards overlong CSI and preserves stream sync" {
    var terminal = try initTestTerminal(std.heap.page_size_min, std.heap.page_size_min * 2);
    defer terminal.read_buffer.deinit();

    const payload_len = p.csi_len_max_default + 64;
    const total_len = 2 + payload_len + 1 + 1;
    var sequence = try std.testing.allocator.alloc(u8, total_len);
    defer std.testing.allocator.free(sequence);

    sequence[0] = 0x1b;
    sequence[1] = '[';
    @memset(sequence[2 .. 2 + payload_len], ';');
    sequence[2 + payload_len] = 'm';
    sequence[2 + payload_len + 1] = 'z';

    _ = try terminal.read_buffer.write(sequence);

    var queue_storage: [8]Event = undefined;
    var events = std.ArrayList(Event).initBuffer(&queue_storage);

    const state = terminal.parseBufferedEvents(&events);
    try std.testing.expectEqual(Terminal.ParseBufferedState.drained, state);
    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expect(@as(std.meta.Tag(Event), events.items[0]) == .key_pressed);
    try std.testing.expectEqual(@as(e.KeyEvent.Code, @enumFromInt('z')), events.items[0].key_pressed.code);
    try std.testing.expectEqual(@as(usize, 0), terminal.read_buffer.len);
    try std.testing.expectEqual(Terminal.ParseMode.ground, terminal.parse_mode);
}

test "parseBufferedEvents resyncs malformed overlong CSI at new control sequence" {
    var terminal = try initTestTerminal(std.heap.page_size_min, std.heap.page_size_min * 2);
    defer terminal.read_buffer.deinit();

    const payload_len = p.csi_len_max_default + 64;
    const total_len = 2 + payload_len + 3;
    var sequence = try std.testing.allocator.alloc(u8, total_len);
    defer std.testing.allocator.free(sequence);

    sequence[0] = 0x1b;
    sequence[1] = '[';
    @memset(sequence[2 .. 2 + payload_len], ';');
    sequence[2 + payload_len] = 0x1b;
    sequence[2 + payload_len + 1] = '[';
    sequence[2 + payload_len + 2] = 'A';

    _ = try terminal.read_buffer.write(sequence);

    var queue_storage: [8]Event = undefined;
    var events = std.ArrayList(Event).initBuffer(&queue_storage);

    const state = terminal.parseBufferedEvents(&events);
    try std.testing.expectEqual(Terminal.ParseBufferedState.drained, state);
    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expect(@as(std.meta.Tag(Event), events.items[0]) == .key_pressed);
    try std.testing.expectEqual(e.KeyEvent.Code.up, events.items[0].key_pressed.code);
    try std.testing.expectEqual(@as(usize, 0), terminal.read_buffer.len);
    try std.testing.expectEqual(Terminal.ParseMode.ground, terminal.parse_mode);
}

test "ensureReadBufferWritable grows before dropping" {
    var terminal = try initTestTerminal(std.heap.page_size_min, std.heap.page_size_min * 2);
    defer terminal.read_buffer.deinit();

    const old_cap = terminal.read_buffer.capacity();
    var chunk: [256]u8 = undefined;
    @memset(&chunk, 'x');
    while (terminal.read_buffer.len < old_cap) {
        const remaining = old_cap - terminal.read_buffer.len;
        _ = try terminal.read_buffer.write(chunk[0..@min(chunk.len, remaining)]);
    }

    terminal.ensureReadBufferWritable();

    try std.testing.expect(terminal.read_buffer.capacity() > old_cap);
    try std.testing.expectEqual(@as(u64, 0), terminal.dropped_input_bytes);
    try std.testing.expectEqual(old_cap, terminal.read_buffer.len);
}
