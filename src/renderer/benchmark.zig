// TODO get PMCs
const std = @import("std");
const Allocator = std.mem.Allocator;

const FrameBuffer = @import("renderer").FrameBuffer;
const Scissor = @import("renderer").Scissor;
const PrintOptions = Scissor.PrintOptions;
const Cell = @import("renderer").Cell;

const BenchmarkMode = enum(u8) {
    /// Mode 1: Full print with wrapping enabled
    full_wrap = 0,
    /// Mode 2: Full print without wrapping (truncation)
    full_nowrap = 1,
    /// Mode 3: Fixed scissor (full buffer) for comparison
    fixed_scissor = 2,
};

const Function = enum(u8) {
    print = 0,
    assume_no_grapheme = 1,
};

/// Benchmark configuration
const Config = struct {
    iterations: usize = 10000,
    seed: u64 = 0,
    mode: BenchmarkMode = .full_wrap,
    buffer_width: u16 = 256,
    buffer_height: u16 = 128,
    chunk_size: usize = 4096,
    print: bool = false,
    function: Function = .print,
};

/// Statistics collected during benchmark
const Stats = struct {
    total_bytes: usize = 0,
    total_graphemes: usize = 0,
    total_iterations: usize = 0,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    // Parse command-line arguments
    var config = Config{};
    const args = try init.minimal.args.toSlice(allocator);

    if (args.len > 1) {
        const mode_val = std.fmt.parseInt(u8, args[1], 10) catch 1;
        config.mode = switch (mode_val) {
            0 => .full_wrap,
            1 => .full_nowrap,
            2 => .fixed_scissor,
            else => .full_wrap,
        };
    }
    if (args.len > 2) {
        config.iterations = std.fmt.parseInt(usize, args[2], 10) catch 10000;
    }

    if (args.len > 3) {
        config.print = true;
    }

    if (args.len > 4) {
        const function = std.fmt.parseInt(u8, args[4], 10) catch 0;
        config.function = switch (function) {
            0 => .print,
            1 => .assume_no_grapheme,
            else => .print,
        };
    }

    var buffer: [4096]u8 align(std.atomic.cache_line) = undefined;
    const file = std.Io.Dir.cwd().openFile(init.io, "utf8_test.txt", .{}) catch |err| {
        std.debug.print("Error reading utf8_test.txt: {}\n", .{err});
        std.debug.print("Make sure utf8_test.txt exists in the current directory.\n", .{});
        return;
    };
    defer file.close(init.io);

    const stat = try file.stat(init.io);
    const text = try allocator.alignedAlloc(u8, .fromByteUnits(std.heap.page_size_min), stat.size);
    var file_reader = file.reader(init.io, &buffer);
    var r = &file_reader.interface;
    try r.readSliceAll(text);

    if (config.print) {
        std.debug.print("\n", .{});
        std.debug.print("Print Benchmark Results\n", .{});
        std.debug.print("=======================\n", .{});
        std.debug.print("Mode: {s}\n", .{@tagName(config.mode)});
        std.debug.print("Iterations: {d}\n", .{config.iterations});
        std.debug.print("Buffer size: {d}x{d}\n", .{ config.buffer_width, config.buffer_height });
        std.debug.print("Text file size: {d} bytes ({d:.2} MB)\n", .{ text.len, @as(f64, @floatFromInt(text.len)) / (1024.0 * 1024.0) });
        std.debug.print("Chunk size: {d} bytes\n", .{config.chunk_size});
        std.debug.print("\n", .{});
    }

    // Run benchmark
    const result = try runBenchmark(text, config);

    if (config.print) {
        // Report results
        const total_secs = @as(f64, @floatFromInt(result.elapsed_ns)) / 1_000_000_000.0;
        const iterations_per_sec = @as(f64, @floatFromInt(result.stats.total_iterations)) / total_secs;
        const bytes_per_sec = @as(f64, @floatFromInt(result.stats.total_bytes)) / total_secs;
        const graphemes_per_sec = @as(f64, @floatFromInt(result.stats.total_graphemes)) / total_secs;
        const avg_time_us = (@as(f64, @floatFromInt(result.elapsed_ns)) / 1000.0) / @as(f64, @floatFromInt(result.stats.total_iterations));

        std.debug.print("Total time: {d:.3}s\n", .{total_secs});
        std.debug.print("\n", .{});
        std.debug.print("Performance:\n", .{});
        std.debug.print("  - {d:.0} iterations/sec\n", .{iterations_per_sec});
        std.debug.print("  - {d:.1} MB/sec throughput\n", .{bytes_per_sec / (1024.0 * 1024.0)});
        std.debug.print("  - {d:.1}M graphemes/sec\n", .{graphemes_per_sec / 1_000_000.0});
        std.debug.print("\n", .{});
        std.debug.print("Statistics per iteration:\n", .{});
        std.debug.print("  - Avg bytes: {d:.0}\n", .{@as(f64, @floatFromInt(result.stats.total_bytes)) / @as(f64, @floatFromInt(result.stats.total_iterations))});
        std.debug.print("  - Avg graphemes: {d:.0}\n", .{@as(f64, @floatFromInt(result.stats.total_graphemes)) / @as(f64, @floatFromInt(result.stats.total_iterations))});
        std.debug.print("  - Avg time: {d:.1}us\n", .{avg_time_us});
        std.debug.print("\n", .{});
    }
}

const BenchmarkResult = struct {
    elapsed_ns: u64,
    stats: Stats,
};

fn runBenchmark(text: []const u8, config: Config) !BenchmarkResult {
    var rng = std.Random.DefaultPrng.init(config.seed);
    const random = rng.random();

    const cells = try std.heap.page_allocator.alignedAlloc(Cell, .fromByteUnits(std.heap.page_size_min), config.buffer_width * config.buffer_height);
    var frame_buffer = try FrameBuffer.init(
        cells,
        config.buffer_width,
        config.buffer_height,
        .{ .max = 1024 * 1024, .initial = 64 * 1024 },
    );
    defer frame_buffer.deinit();

    const num_chunks = (text.len + config.chunk_size - 1) / config.chunk_size;

    var stats = Stats{};

    for (0..10) |_| {
        frame_buffer.clear();
        const chunk_idx = random.intRangeLessThan(usize, 0, num_chunks);
        const chunk_start = chunk_idx * config.chunk_size;
        const chunk_end = @min(chunk_start + config.chunk_size, text.len);
        const chunk = text[chunk_start..chunk_end];

        const scissor = frame_buffer.scissor();
        var codepoint_buffer: [64]u21 = undefined;
        _ = scissor.print(&codepoint_buffer, chunk, 0, 0, .{ .wrap = config.mode == .full_wrap, .tab_width = 4 }) catch {};
    }

    var elapsed_ns: u64 = 0;

    for (0..config.iterations) |_| {
        const chunk_idx = random.intRangeLessThan(usize, 0, num_chunks);
        const chunk_start = chunk_idx * config.chunk_size;
        const chunk_end = @min(chunk_start + config.chunk_size, text.len);
        const chunk = text[chunk_start..chunk_end];

        stats.total_bytes += chunk.len;
        stats.total_iterations += 1;

        frame_buffer.clear();

        const scissor: Scissor = switch (config.mode) {
            .fixed_scissor => frame_buffer.scissor(),
            .full_wrap, .full_nowrap => blk: {
                // Random scissor within buffer
                const max_x_offset = config.buffer_width / 2;
                const max_y_offset = config.buffer_height / 2;

                const x_offset = random.intRangeLessThan(u16, 0, max_x_offset);
                const y_offset = random.intRangeLessThan(u16, 0, max_y_offset);

                const min_width: u16 = 10;
                const min_height: u16 = 5;
                const max_width = config.buffer_width - x_offset;
                const max_height = config.buffer_height - y_offset;

                const width = if (max_width > min_width)
                    random.intRangeAtMost(u16, min_width, max_width)
                else
                    max_width;

                const height = if (max_height > min_height)
                    random.intRangeAtMost(u16, min_height, max_height)
                else
                    max_height;

                break :blk frame_buffer.scissor().initChild(x_offset, y_offset, width, height);
            },
        };

        const start_x = if (scissor.width_global > 1)
            random.intRangeLessThan(u16, 0, scissor.width_global - 1)
        else
            0;

        const start_y = if (scissor.height_global > 1)
            random.intRangeLessThan(u16, 0, scissor.height_global - 1)
        else
            0;

        const options: PrintOptions = .{
            .wrap = config.mode == .full_wrap,
            .tab_width = 4,
        };

        var codepoint_buffer: [64]u21 = undefined;
        var timer = try std.time.Timer.start();
        const result = if (config.function == .print)
            scissor.print(&codepoint_buffer, chunk, start_x, start_y, options) catch unreachable
        else
            scissor.printAssumeNoGrapheme(chunk, start_x, start_y, options);

        elapsed_ns += timer.read();

        stats.total_graphemes += result.graphemes_rendered;
    }

    return BenchmarkResult{
        .elapsed_ns = elapsed_ns,
        .stats = stats,
    };
}
