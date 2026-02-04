const std = @import("std");
const stdx = @import("stdx");
const parseArgs = stdx.parseArgs;

const common = @import("common.zig");
const Render = @import("commands/render.zig");
const Print = @import("commands/print.zig");
const Inspect = @import("commands/inspect.zig");

const terminal_mod = @import("terminal");
const Terminal = terminal_mod.Terminal;

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    if (Terminal.global_tty) |tty| {
        tty.deinit();
    }

    std.debug.defaultPanic(msg, ret_addr);
}

const CLIArgs = union(enum) {
    render_full: Render,
    render_diff: Render,
    print_no_grapheme: Print,
    print: Print,
    inspect: Inspect,

    pub const help =
        \\TUIG benchmark
        \\
        \\Usage:
        \\  zig build benchmark -- <command> [options]
        \\
        \\Commands:
        \\  render_full        Render and emit a full frame each iteration.
        \\  render_diff        Render, diff with previous, emit only changed cells.
        \\  print              Print full frame with grapheme-aware path.
        \\  print_no_grapheme  Print full frame assuming no grapheme clusters.
        \\  inspect            Launch the interactive inspector.
        \\
        \\Options:
        \\  -h, --help
        \\      Prints this help message.
    ;
};

pub fn main(init: std.process.Init) !void {
    var threaded = std.Io.Threaded.init_single_threaded;
    const io = threaded.ioBasic();

    var args_iter = try init.minimal.args.iterateAllocator(init.arena.allocator());
    defer args_iter.deinit();
    const cli = parseArgs(io, init.arena.allocator(), &args_iter, CLIArgs);

    const ctx = common.CommandContext{ .io = io, .allocator = init.arena.allocator() };

    switch (cli) {
        .render_full => |cmd| try cmd.execute(ctx, .full_redraw),
        .render_diff => |cmd| try cmd.execute(ctx, .diff_redraw),
        .print => |cmd| try cmd.execute(ctx, .print),
        .print_no_grapheme => |cmd| try cmd.execute(ctx, .print_assume_no_grapheme),
        .inspect => |cmd| try cmd.execute(ctx),
    }
}

test "benchmarks module tests" {
    _ = @import("common.zig");
    _ = @import("patterns.zig");
    _ = @import("ui.zig");
}
