const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.tui);

const tg = @import("tuig");
const Terminal = tg.Terminal;
const TerminalConfig = tg.TerminalConfig;
const Renderer = tg.Renderer;

const Application = @import("app.zig");

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
    config.cursor_visable = false;
    var terminal = Terminal.init(io, config, &write_buffer) catch |err| {
        log.err("Failed to initialize terminal: {s}", .{@errorName(err)});
        return;
    };
    defer terminal.deinit();
    global_tty = &terminal;

    var renderer: Renderer = undefined;
    renderer.init(&terminal, std.heap.page_allocator, 1 * 1024 * 1024) catch {
        log.err("Failed to initialize renderer", .{});
        return;
    };

    var quit = false;
    var app = Application.init(terminal.size.height);
    while (!quit) {
        const events = terminal.pollEvents(16) catch {
            log.err("Failed to poll events", .{});
            return;
        };

        const ctx = renderer.beginFrame(events);
        defer renderer.endFrame();

        quit = app.updateAndRender(ctx);
    }
}
