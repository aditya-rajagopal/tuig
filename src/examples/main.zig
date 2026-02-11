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
    config.cursor_visible = false;
    var terminal: Terminal = undefined;
    terminal.init(config, &write_buffer) catch |err| {
        log.err("Failed to initialize terminal: {s}", .{@errorName(err)});
        return;
    };
    defer terminal.deinit();

    var style_buffer: [1024]tg.renderer.Style = undefined;
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
    var paste_buffer: [4096]u8 = undefined;
    var paste_buffer_len: usize = 0;
    var num_chunks: usize = 0;
    while (!quit) {
        const events = terminal.pollEvents(14) catch {
            log.err("Failed to poll events", .{});
            return;
        };

        const ctx = renderer.beginFrame(events) catch {
            log.err("Failed to begin frame", .{});
            return;
        };
        defer renderer.endFrame(false, &style_sheet);

        // var capability_buffer: [1024]u8 = undefined;
        // const str = std.fmt.bufPrint(&capability_buffer, "Capability State: {any}", .{terminal.capability_state_initial}) catch unreachable;
        // _ = ctx.scissor.printAssumeNoGrapheme(str, 0, ctx.scissor.height_global - 10, .{ .wrap = true });

        for (events) |event| {
            if (event == .paste_start) {
                paste_buffer_len = 0;
                num_chunks = 0;
            }
            if (event == .paste_data) {
                const len = @min(event.paste_data.len, paste_buffer.len - paste_buffer_len);
                @memcpy(paste_buffer[paste_buffer_len .. paste_buffer_len + len], event.paste_data[0..len]);
                paste_buffer_len += len;
                num_chunks += 1;
            }
            if (event == .paste_end) {
                paste_buffer[paste_buffer_len] = 0;
                paste_buffer_len += 1;
            }
        }
        var buffer: [128]u8 = undefined;
        const nchunks = std.fmt.bufPrint(&buffer, "Pasted {d} chunks", .{num_chunks}) catch unreachable;
        _ = ctx.scissor.printAssumeNoGrapheme(nchunks, 0, ctx.scissor.height_global - 11, .{ .wrap = true });

        _ = ctx.scissor.printAssumeNoGrapheme(paste_buffer[0..paste_buffer_len], 0, ctx.scissor.height_global - 10, .{ .wrap = true });

        quit = app.updateAndRender(&ctx);
    }
}
