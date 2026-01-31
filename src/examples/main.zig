const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.tui);

const tg = @import("tuig");
const Terminal = tg.terminal.Terminal;
const TerminalConfig = tg.terminal.TerminalConfig;
const Renderer = tg.renderer.Renderer;

const Application = @import("app.zig");

var global_app: ?*Application = null;
pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    if (Terminal.global_tty) |tty| {
        tty.deinit();
    }

    std.debug.defaultPanic(msg, ret_addr);
}

pub fn main(_: std.process.Init.Minimal) void {
    var write_buffer: [4096]u8 align(4096) = undefined;
    var config: TerminalConfig = .tui_default;
    config.cursor_visable = false;
    var terminal: Terminal = undefined;
    terminal.init(config, &write_buffer) catch |err| {
        log.err("Failed to initialize terminal: {s}", .{@errorName(err)});
        return;
    };
    defer terminal.deinit();

    var style_buffer: [1024]tg.renderer.Style.FullStyle = undefined;
    var generation_buffer: [1024]u8 = undefined;
    var style_sheet = tg.renderer.Style.Sheet.initBuffer(style_buffer[0..], generation_buffer[0..]);

    var renderer: Renderer = undefined;
    renderer.init(&terminal, .default_screen) catch {
        log.err("Failed to initialize renderer", .{});
        return;
    };

    var quit = false;
    var app = Application.init(&style_sheet) catch {
        log.err("Failed to initialize application", .{});
        return;
    };
    global_app = &app;
    while (!quit) {
        const events = terminal.pollEvents(15) catch {
            log.err("Failed to poll events", .{});
            return;
        };

        const ctx = renderer.beginFrame(events) catch {
            log.err("Failed to begin frame", .{});
            return;
        };
        defer renderer.endFrame(true, &style_sheet);

        quit = app.updateAndRender(&ctx);
    }
}
