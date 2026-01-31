// Renderer2 Performance Benchmark
//
// This benchmark measures the performance of Renderer2's different rendering paths:
// - Full redraw (used on first frame, resize, etc.)
// - Incremental diff (used for updates)
//
// Usage:
//   zig build bench-renderer
//   ./zig-out/bin/renderer_benchmark [mode] [iterations]
//
// Modes:
//   0 - Full redraw, ASCII content (default)
//   1 - Full redraw, mixed content (ASCII + wide chars + graphemes)
//   2 - Diff with 10% changes (random distribution)
//   3 - Diff with 1% changes (random distribution)
//   4 - Diff with no changes
//   5 - Run all benchmarks
//   6 - Diff with rectangle change (20x10 dialog)
//   7 - Diff with single row change (status bar)
//   8 - Diff with cursor movement (2 cells)
//   9 - Run all realistic benchmarks
//   10 - Diff with multiple rectangles (5 regions of varying sizes)
//
// For hyperfine testing:
//   hyperfine './zig-out/bin/renderer_benchmark 0 10000' \
//             './zig-out/bin/renderer_benchmark 2 10000' \
//             './zig-out/bin/renderer_benchmark 4 10000'

const std = @import("std");
const renderer = @import("renderer");
const FrameBuffer = renderer.FrameBuffer;
const Cell = renderer.Cell;

const Config = struct {
    width: u16 = 200,
    height: u16 = 60,
    iterations: usize = 10000,
    mode: Mode = .full_ascii,
    quiet: bool = false,

    const Mode = enum(u8) {
        full_ascii = 0,
        full_mixed = 1,
        diff_10_percent = 2,
        diff_1_percent = 3,
        diff_no_changes = 4,
        all = 5,
        // Realistic scenarios
        diff_rectangle = 6,
        diff_single_row = 7,
        diff_cursor = 8,
        all_realistic = 9,
        diff_multi_rect = 10,
    };
};

const BenchmarkResult = struct {
    name: []const u8,
    iterations: usize,
    total_ns: u64,
    output_bytes: usize,

    fn avgNs(self: BenchmarkResult) u64 {
        return self.total_ns / self.iterations;
    }

    fn avgUs(self: BenchmarkResult) f64 {
        return @as(f64, @floatFromInt(self.avgNs())) / 1000.0;
    }

    fn framesPerSec(self: BenchmarkResult) f64 {
        return 1_000_000_000.0 / @as(f64, @floatFromInt(self.avgNs()));
    }

    fn print(self: BenchmarkResult) void {
        std.debug.print("{s}:\n", .{self.name});
        std.debug.print("  Iterations: {d}\n", .{self.iterations});
        std.debug.print("  Avg time: {d:.2}us\n", .{self.avgUs()});
        std.debug.print("  Throughput: {d:.0} frames/sec\n", .{self.framesPerSec()});
        std.debug.print("  Output size: {d} bytes\n", .{self.output_bytes});
        std.debug.print("\n", .{});
    }
};

fn setupAsciiBuffer(buffer: *FrameBuffer) void {
    const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    const total_cells = @as(usize, buffer.width) * @as(usize, buffer.height);
    for (0..total_cells) |i| {
        buffer.cells[i] = Cell{
            .data = .{ .codepoint = chars[i % chars.len] },
            .tag = .codepoint,
            .width = .narrow,
        };
    }
}

fn setupMixedContentBuffer(buffer: *FrameBuffer) !void {
    const width: usize = buffer.width;
    const height: usize = buffer.height;

    for (0..height) |row| {
        var col: usize = 0;
        while (col < width) {
            const idx = row * width + col;
            const pattern = (row + col) % 10;

            if (pattern < 6) {
                // ASCII character (60%)
                buffer.cells[idx] = Cell{
                    .data = .{ .codepoint = @intCast('A' + (col % 26)) },
                    .tag = .codepoint,
                    .width = .narrow,
                };
                col += 1;
            } else if (pattern < 9 and col + 1 < width) {
                // Wide character (30%)
                const wide_chars = [_]u21{ '日', '本', '語', '中', '文' };
                buffer.cells[idx] = Cell{
                    .data = .{ .codepoint = wide_chars[col % wide_chars.len] },
                    .tag = .codepoint,
                    .width = .wide_start,
                };
                buffer.cells[idx + 1] = Cell{
                    .data = .{ .codepoint = 0 },
                    .tag = .codepoint,
                    .width = .wide_end,
                };
                col += 2;
            } else {
                // Grapheme cluster (10%)
                const grapheme = "e\u{0301}";
                const id = try buffer.grapheme_buffer.put(grapheme);
                buffer.cells[idx] = Cell{
                    .data = .{ .grapheme_id = @truncate(id) },
                    .grapheme_id_extension = @truncate(id >> 21),
                    .tag = .grapheme,
                    .width = .narrow,
                };
                col += 1;
            }
        }
    }
}

fn applyRandomChanges(render_buffer: *FrameBuffer, back_buffer: *FrameBuffer, change_percent: u8, seed: u64) void {
    const total_cells = @as(usize, render_buffer.width) * @as(usize, render_buffer.height);
    @memcpy(
        render_buffer.cells[0..total_cells],
        back_buffer.cells[0..total_cells],
    );

    if (change_percent == 0) return;

    var rng = std.Random.DefaultPrng.init(seed);
    const random = rng.random();

    const changes_to_make = (total_cells * change_percent) / 100;
    for (0..changes_to_make) |_| {
        const idx = random.intRangeLessThan(usize, 0, total_cells);
        render_buffer.cells[idx] = Cell{
            .data = .{ .codepoint = @intCast('0' + rng.random().intRangeLessThan(u8, 0, 10)) },
            .tag = .codepoint,
            .width = .narrow,
        };
    }
}

/// Applies a rectangle change (simulates a dialog/panel appearing)
fn applyRectangleChange(render_buffer: *FrameBuffer, back_buffer: *FrameBuffer, x: u16, y: u16, w: u16, h: u16) void {
    const total_cells = @as(usize, render_buffer.width) * @as(usize, render_buffer.height);
    @memcpy(
        render_buffer.cells[0..total_cells],
        back_buffer.cells[0..total_cells],
    );

    const width: usize = render_buffer.width;
    const max_y = @min(y + h, render_buffer.height);
    const max_x = @min(x + w, render_buffer.width);

    for (y..max_y) |row| {
        for (x..max_x) |col| {
            const idx = row * width + col;
            render_buffer.cells[idx] = Cell{
                .data = .{ .codepoint = 'X' },
                .tag = .codepoint,
                .width = .narrow,
            };
        }
    }
}

/// Applies a single row change (simulates status bar update)
fn applySingleRowChange(render_buffer: *FrameBuffer, back_buffer: *FrameBuffer, row: u16) void {
    const total_cells = @as(usize, render_buffer.width) * @as(usize, render_buffer.height);
    @memcpy(
        render_buffer.cells[0..total_cells],
        back_buffer.cells[0..total_cells],
    );

    const width: usize = render_buffer.width;
    const row_start = @as(usize, row) * width;

    for (0..width) |col| {
        render_buffer.cells[row_start + col] = Cell{
            .data = .{ .codepoint = '>' },
            .tag = .codepoint,
            .width = .narrow,
        };
    }
}

/// Applies cursor movement (simulates cursor moving from one cell to another)
fn applyCursorChange(render_buffer: *FrameBuffer, back_buffer: *FrameBuffer, old_x: u16, old_y: u16, new_x: u16, new_y: u16) void {
    const total_cells = @as(usize, render_buffer.width) * @as(usize, render_buffer.height);
    @memcpy(
        render_buffer.cells[0..total_cells],
        back_buffer.cells[0..total_cells],
    );

    const width: usize = render_buffer.width;

    // Clear old cursor position
    const old_idx = @as(usize, old_y) * width + @as(usize, old_x);
    render_buffer.cells[old_idx] = Cell{
        .data = .{ .codepoint = ' ' },
        .tag = .codepoint,
        .width = .narrow,
    };

    // Set new cursor position
    const new_idx = @as(usize, new_y) * width + @as(usize, new_x);
    render_buffer.cells[new_idx] = Cell{
        .data = .{ .codepoint = '|' },
        .tag = .codepoint,
        .width = .narrow,
    };
}

/// Applies multiple rectangle changes of varying sizes (simulates multiple panels/windows)
fn applyMultiRectChanges(render_buffer: *FrameBuffer, back_buffer: *FrameBuffer) void {
    const total_cells = @as(usize, render_buffer.width) * @as(usize, render_buffer.height);
    @memcpy(
        render_buffer.cells[0..total_cells],
        back_buffer.cells[0..total_cells],
    );

    const width: usize = render_buffer.width;
    const buf_width = render_buffer.width;
    const buf_height = render_buffer.height;

    // Define multiple rectangles of varying sizes scattered across the screen
    const Rect = struct { x: u16, y: u16, w: u16, h: u16, char: u21 };
    const rects = [_]Rect{
        // Top-left: small notification (8x3)
        .{ .x = 2, .y = 1, .w = 8, .h = 3, .char = '!' },
        // Top-right: menu dropdown (15x8)
        .{ .x = buf_width - 18, .y = 2, .w = 15, .h = 8, .char = 'M' },
        // Center: main dialog (30x15)
        .{ .x = buf_width / 2 - 15, .y = buf_height / 2 - 7, .w = 30, .h = 15, .char = 'D' },
        // Bottom-left: status panel (25x4)
        .{ .x = 5, .y = buf_height - 6, .w = 25, .h = 4, .char = 'S' },
        // Bottom-right: mini-map or info panel (12x10)
        .{ .x = buf_width - 15, .y = buf_height - 12, .w = 12, .h = 10, .char = 'I' },
    };

    for (rects) |rect| {
        const max_y = @min(rect.y + rect.h, buf_height);
        const max_x = @min(rect.x + rect.w, buf_width);

        for (rect.y..max_y) |row| {
            for (rect.x..max_x) |col| {
                const idx = row * width + col;
                render_buffer.cells[idx] = Cell{
                    .data = .{ .codepoint = rect.char },
                    .tag = .codepoint,
                    .width = .narrow,
                };
            }
        }
    }
}

fn benchFullRedrawAscii(config: Config) !BenchmarkResult {
    const cells = try std.heap.page_allocator.alignedAlloc(Cell, .fromByteUnits(std.heap.page_size_min), config.width * config.height);
    defer std.heap.page_allocator.free(cells);
    var buffer = try FrameBuffer.init(
        cells,
        config.width,
        config.height,
        .{ .max = 64 * 1024, .initial = 4 * 1024 },
    );
    defer buffer.deinit();

    const render_buffer = &buffer;

    setupAsciiBuffer(render_buffer);

    var buf: [4096]u8 align(std.atomic.cache_line) = undefined;
    var writer = std.Io.Writer.Discarding.init(&buf);
    var style_sheet: renderer.Style.Sheet = .empty;

    // Warmup
    for (0..100) |_| {
        writer.count = 0;
        render_buffer.fullRedraw(&style_sheet, &writer.writer) catch {};
    }

    // Benchmark
    var timer = try std.time.Timer.start();
    for (0..config.iterations) |_| {
        writer.count = 0;
        render_buffer.fullRedraw(&style_sheet, &writer.writer) catch {};
    }
    const elapsed = timer.read();

    return .{
        .name = "Full redraw (ASCII 80x24)",
        .iterations = config.iterations,
        .total_ns = elapsed,
        .output_bytes = writer.count,
    };
}

fn benchFullRedrawMixed(config: Config) !BenchmarkResult {
    const cells = try std.heap.page_allocator.alignedAlloc(Cell, .fromByteUnits(std.heap.page_size_min), config.width * config.height);
    defer std.heap.page_allocator.free(cells);
    var buffer = try FrameBuffer.init(
        cells,
        config.width,
        config.height,
        .{ .max = 64 * 1024, .initial = 4 * 1024 },
    );
    defer buffer.deinit();

    const render_buffer = &buffer;

    try setupMixedContentBuffer(render_buffer);

    var buf: [4096]u8 align(std.atomic.cache_line) = undefined;
    var writer = std.Io.Writer.Discarding.init(&buf);
    var style_sheet: renderer.Style.Sheet = .empty;

    // Warmup
    for (0..100) |_| {
        writer.count = 0;
        render_buffer.fullRedraw(&style_sheet, &writer.writer) catch {};
    }

    // Benchmark
    var timer = try std.time.Timer.start();
    for (0..config.iterations) |_| {
        writer.count = 0;
        render_buffer.fullRedraw(&style_sheet, &writer.writer) catch {};
    }
    const elapsed = timer.read();

    return .{
        .name = "Full redraw (Mixed 80x24)",
        .iterations = config.iterations,
        .total_ns = elapsed,
        .output_bytes = writer.count,
    };
}

fn benchDiff(config: Config, change_percent: u8) !BenchmarkResult {
    var buffers: [2]FrameBuffer = undefined;
    const cells0 = try std.heap.page_allocator.alignedAlloc(Cell, .fromByteUnits(std.heap.page_size_min), config.width * config.height);
    defer std.heap.page_allocator.free(cells0);
    buffers[0] = try FrameBuffer.init(
        cells0,
        config.width,
        config.height,
        .{ .max = 64 * 1024, .initial = 4 * 1024 },
    );

    defer buffers[0].deinit();
    const cells1 = try std.heap.page_allocator.alignedAlloc(Cell, .fromByteUnits(std.heap.page_size_min), config.width * config.height);
    defer std.heap.page_allocator.free(cells1);
    buffers[1] = try FrameBuffer.init(
        cells1,
        config.width,
        config.height,
        .{ .max = 64 * 1024, .initial = 4 * 1024 },
    );
    defer buffers[1].deinit();

    const render_buffer = &buffers[0];
    const back_buffer = &buffers[1];

    setupAsciiBuffer(back_buffer);

    // Pre-apply changes for warmup and final output measurement
    applyRandomChanges(render_buffer, back_buffer, change_percent, 0);

    var buf: [4096]u8 align(std.atomic.cache_line) = undefined;
    var writer = std.Io.Writer.Discarding.init(&buf);
    var style_sheet: renderer.Style.Sheet = .empty;

    // Warmup
    for (0..100) |_| {
        writer.count = 0;
        render_buffer.diffRedraw(back_buffer, &style_sheet, &writer.writer) catch {};
    }

    // Benchmark - measure only the diff rendering, not the change application
    var timer = try std.time.Timer.start();
    for (0..config.iterations) |_| {
        writer.count = 0;
        render_buffer.diffRedraw(back_buffer, &style_sheet, &writer.writer) catch {};
    }
    const elapsed = timer.read();

    const name = switch (change_percent) {
        0 => "Diff (0% changes)",
        1 => "Diff (1% changes)",
        10 => "Diff (10% changes)",
        else => "Diff (custom %)",
    };

    return .{
        .name = name,
        .iterations = config.iterations,
        .total_ns = elapsed,
        .output_bytes = writer.count,
    };
}

/// Benchmark for rectangle change (simulates dialog/panel appearing)
fn benchDiffRectangle(config: Config) !BenchmarkResult {
    var buffers: [2]FrameBuffer = undefined;
    const cells0 = try std.heap.page_allocator.alignedAlloc(Cell, .fromByteUnits(std.heap.page_size_min), config.width * config.height);
    defer std.heap.page_allocator.free(cells0);
    buffers[0] = try FrameBuffer.init(
        cells0,
        config.width,
        config.height,
        .{ .max = 64 * 1024, .initial = 4 * 1024 },
    );
    defer buffers[0].deinit();

    const cells1 = try std.heap.page_allocator.alignedAlloc(Cell, .fromByteUnits(std.heap.page_size_min), config.width * config.height);
    defer std.heap.page_allocator.free(cells1);
    buffers[1] = try FrameBuffer.init(
        cells1,
        config.width,
        config.height,
        .{ .max = 64 * 1024, .initial = 4 * 1024 },
    );
    defer buffers[1].deinit();

    const render_buffer = &buffers[0];
    const back_buffer = &buffers[1];

    setupAsciiBuffer(back_buffer);

    // 20x10 rectangle centered in the buffer (simulates a dialog)
    const rect_x = config.width / 2 - 10;
    const rect_y = config.height / 2 - 5;
    applyRectangleChange(render_buffer, back_buffer, rect_x, rect_y, 20, 10);

    var buf: [4096]u8 align(std.atomic.cache_line) = undefined;
    var writer = std.Io.Writer.Discarding.init(&buf);
    var style_sheet: renderer.Style.Sheet = .empty;

    // Warmup
    for (0..100) |_| {
        writer.count = 0;
        render_buffer.diffRedraw(back_buffer, &style_sheet, &writer.writer) catch {};
    }

    // Benchmark
    var timer = try std.time.Timer.start();
    for (0..config.iterations) |_| {
        writer.count = 0;
        render_buffer.diffRedraw(back_buffer, &style_sheet, &writer.writer) catch {};
    }
    const elapsed = timer.read();

    return .{
        .name = "Diff (20x10 rectangle)",
        .iterations = config.iterations,
        .total_ns = elapsed,
        .output_bytes = writer.count,
    };
}

/// Benchmark for single row change (simulates status bar update)
fn benchDiffSingleRow(config: Config) !BenchmarkResult {
    var buffers: [2]FrameBuffer = undefined;
    const cells0 = try std.heap.page_allocator.alignedAlloc(Cell, .fromByteUnits(std.heap.page_size_min), config.width * config.height);
    defer std.heap.page_allocator.free(cells0);
    buffers[0] = try FrameBuffer.init(
        cells0,
        config.width,
        config.height,
        .{ .max = 64 * 1024, .initial = 4 * 1024 },
    );
    defer buffers[0].deinit();

    const cells1 = try std.heap.page_allocator.alignedAlloc(Cell, .fromByteUnits(std.heap.page_size_min), config.width * config.height);
    defer std.heap.page_allocator.free(cells1);
    buffers[1] = try FrameBuffer.init(
        cells1,
        config.width,
        config.height,
        .{ .max = 64 * 1024, .initial = 4 * 1024 },
    );
    defer buffers[1].deinit();

    const render_buffer = &buffers[0];
    const back_buffer = &buffers[1];

    setupAsciiBuffer(back_buffer);

    // Change the last row (typical status bar location)
    applySingleRowChange(render_buffer, back_buffer, config.height - 1);

    var buf: [4096]u8 align(std.atomic.cache_line) = undefined;
    var writer = std.Io.Writer.Discarding.init(&buf);
    var style_sheet: renderer.Style.Sheet = .empty;

    // Warmup
    for (0..100) |_| {
        writer.count = 0;
        render_buffer.diffRedraw(back_buffer, &style_sheet, &writer.writer) catch {};
    }

    // Benchmark
    var timer = try std.time.Timer.start();
    for (0..config.iterations) |_| {
        writer.count = 0;
        render_buffer.diffRedraw(back_buffer, &style_sheet, &writer.writer) catch {};
    }
    const elapsed = timer.read();

    return .{
        .name = "Diff (single row)",
        .iterations = config.iterations,
        .total_ns = elapsed,
        .output_bytes = writer.count,
    };
}

/// Benchmark for cursor movement (2 cells change)
fn benchDiffCursor(config: Config) !BenchmarkResult {
    var buffers: [2]FrameBuffer = undefined;
    const cells0 = try std.heap.page_allocator.alignedAlloc(Cell, .fromByteUnits(std.heap.page_size_min), config.width * config.height);
    defer std.heap.page_allocator.free(cells0);
    buffers[0] = try FrameBuffer.init(
        cells0,
        config.width,
        config.height,
        .{ .max = 64 * 1024, .initial = 4 * 1024 },
    );
    defer buffers[0].deinit();

    const cells1 = try std.heap.page_allocator.alignedAlloc(Cell, .fromByteUnits(std.heap.page_size_min), config.width * config.height);
    defer std.heap.page_allocator.free(cells1);
    buffers[1] = try FrameBuffer.init(
        cells1,
        config.width,
        config.height,
        .{ .max = 64 * 1024, .initial = 4 * 1024 },
    );
    defer buffers[1].deinit();

    const render_buffer = &buffers[0];
    const back_buffer = &buffers[1];

    setupAsciiBuffer(back_buffer);

    // Cursor moves from (10,10) to (11,10) - same row
    applyCursorChange(render_buffer, back_buffer, 10, 10, 11, 10);

    var buf: [4096]u8 align(std.atomic.cache_line) = undefined;
    var writer = std.Io.Writer.Discarding.init(&buf);
    var style_sheet: renderer.Style.Sheet = .empty;

    // Warmup
    for (0..100) |_| {
        writer.count = 0;
        render_buffer.diffRedraw(back_buffer, &style_sheet, &writer.writer) catch {};
    }

    // Benchmark
    var timer = try std.time.Timer.start();
    for (0..config.iterations) |_| {
        writer.count = 0;
        render_buffer.diffRedraw(back_buffer, &style_sheet, &writer.writer) catch {};
    }
    const elapsed = timer.read();

    return .{
        .name = "Diff (cursor move)",
        .iterations = config.iterations,
        .total_ns = elapsed,
        .output_bytes = writer.count,
    };
}

/// Benchmark for multiple rectangle changes (simulates multiple panels/windows updating)
fn benchDiffMultiRect(config: Config) !BenchmarkResult {
    var buffers: [2]FrameBuffer = undefined;
    const cells0 = try std.heap.page_allocator.alignedAlloc(Cell, .fromByteUnits(std.heap.page_size_min), config.width * config.height);
    defer std.heap.page_allocator.free(cells0);
    buffers[0] = try FrameBuffer.init(
        cells0,
        config.width,
        config.height,
        .{ .max = 64 * 1024, .initial = 4 * 1024 },
    );
    defer buffers[0].deinit();

    const cells1 = try std.heap.page_allocator.alignedAlloc(Cell, .fromByteUnits(std.heap.page_size_min), config.width * config.height);
    defer std.heap.page_allocator.free(cells1);
    buffers[1] = try FrameBuffer.init(
        cells1,
        config.width,
        config.height,
        .{ .max = 64 * 1024, .initial = 4 * 1024 },
    );
    defer buffers[1].deinit();

    const render_buffer = &buffers[0];
    const back_buffer = &buffers[1];

    setupAsciiBuffer(back_buffer);

    // Apply 5 rectangles of varying sizes
    applyMultiRectChanges(render_buffer, back_buffer);

    var buf: [4096]u8 align(std.atomic.cache_line) = undefined;
    var writer = std.Io.Writer.Discarding.init(&buf);
    var style_sheet: renderer.Style.Sheet = .empty;

    // Warmup
    for (0..100) |_| {
        writer.count = 0;
        render_buffer.diffRedraw(back_buffer, &style_sheet, &writer.writer) catch {};
    }

    // Benchmark
    var timer = try std.time.Timer.start();
    for (0..config.iterations) |_| {
        writer.count = 0;
        render_buffer.diffRedraw(back_buffer, &style_sheet, &writer.writer) catch {};
    }
    const elapsed = timer.read();

    return .{
        .name = "Diff (5 rectangles)",
        .iterations = config.iterations,
        .total_ns = elapsed,
        .output_bytes = writer.count,
    };
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();

    var config = Config{};
    const args = try init.minimal.args.toSlice(allocator);

    if (args.len > 1) {
        const mode_val = std.fmt.parseInt(u8, args[1], 10) catch 0;
        config.mode = @enumFromInt(@min(mode_val, 10));
    }
    if (args.len > 2) {
        config.iterations = std.fmt.parseInt(usize, args[2], 10) catch 10000;
    }
    if (args.len > 3) {
        config.quiet = true;
    }

    if (!config.quiet) {
        std.debug.print("\nRenderer2 Benchmark\n", .{});
        std.debug.print("===================\n", .{});
        std.debug.print("Buffer size: {d}x{d}\n", .{ config.width, config.height });
        std.debug.print("Iterations: {d}\n\n", .{config.iterations});
    }

    switch (config.mode) {
        .full_ascii => {
            const result = try benchFullRedrawAscii(config);
            if (!config.quiet) result.print();
        },
        .full_mixed => {
            const result = try benchFullRedrawMixed(config);
            if (!config.quiet) result.print();
        },
        .diff_10_percent => {
            const result = try benchDiff(config, 10);
            if (!config.quiet) result.print();
        },
        .diff_1_percent => {
            const result = try benchDiff(config, 1);
            if (!config.quiet) result.print();
        },
        .diff_no_changes => {
            const result = try benchDiff(config, 0);
            if (!config.quiet) result.print();
        },
        .all => {
            const results = [_]BenchmarkResult{
                try benchFullRedrawAscii(config),
                try benchFullRedrawMixed(config),
                try benchDiff(config, 10),
                try benchDiff(config, 1),
                try benchDiff(config, 0),
            };

            for (results) |result| {
                result.print();
            }

            // Summary comparison
            std.debug.print("Summary\n", .{});
            std.debug.print("-------\n", .{});
            const full_ascii = results[0].avgUs();
            const diff_0 = results[4].avgUs();
            const diff_1 = results[3].avgUs();

            std.debug.print("Full redraw vs Diff (0%): {d:.1}x speedup\n", .{full_ascii / diff_0});
            std.debug.print("Full redraw vs Diff (1%): {d:.1}x speedup\n", .{full_ascii / diff_1});
        },
        .diff_rectangle => {
            const result = try benchDiffRectangle(config);
            if (!config.quiet) result.print();
        },
        .diff_single_row => {
            const result = try benchDiffSingleRow(config);
            if (!config.quiet) result.print();
        },
        .diff_cursor => {
            const result = try benchDiffCursor(config);
            if (!config.quiet) result.print();
        },
        .all_realistic => {
            const results = [_]BenchmarkResult{
                try benchFullRedrawAscii(config),
                try benchDiff(config, 0),
                try benchDiffRectangle(config),
                try benchDiffSingleRow(config),
                try benchDiffCursor(config),
                try benchDiffMultiRect(config),
            };

            for (results) |result| {
                result.print();
            }

            // Summary comparison
            std.debug.print("Summary (Realistic Scenarios)\n", .{});
            std.debug.print("-----------------------------\n", .{});
            const full_ascii = results[0].avgUs();
            const diff_0 = results[1].avgUs();
            const diff_rect = results[2].avgUs();
            const diff_row = results[3].avgUs();
            const diff_cursor = results[4].avgUs();
            const diff_multi = results[5].avgUs();

            std.debug.print("Full redraw vs Diff (0%): {d:.1}x speedup\n", .{full_ascii / diff_0});
            std.debug.print("Full redraw vs Diff (rectangle): {d:.1}x speedup\n", .{full_ascii / diff_rect});
            std.debug.print("Full redraw vs Diff (single row): {d:.1}x speedup\n", .{full_ascii / diff_row});
            std.debug.print("Full redraw vs Diff (cursor): {d:.1}x speedup\n", .{full_ascii / diff_cursor});
            std.debug.print("Full redraw vs Diff (5 rectangles): {d:.1}x speedup\n", .{full_ascii / diff_multi});
        },
        .diff_multi_rect => {
            const result = try benchDiffMultiRect(config);
            if (!config.quiet) result.print();
        },
    }
}
