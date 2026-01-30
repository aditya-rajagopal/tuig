const std = @import("std");
const Allocator = std.mem.Allocator;

const stdx = @import("stdx");
const assert = stdx.inlineAssert;

const t = @import("types.zig");

const Cell = @import("root.zig").Cell;
const Scissor = @import("Scissor.zig");

pub const FrameBuffer = @This();

cells: []Cell,
width: u16,
height: u16,
grapheme_buffer: t.GraphemeBuffer,

pub fn init(
    cells: []Cell,
    width: u16,
    height: u16,
    grapheme_buffer_size: t.GraphemeBuffer.Size,
) error{ OutOfMemory, ReserveFailed, BufferTooLarge }!FrameBuffer {
    assert(@as(usize, width) * @as(usize, height) == cells.len);
    assert(grapheme_buffer_size.initial <= grapheme_buffer_size.max);

    var buffer: FrameBuffer = undefined;
    buffer.width = width;
    buffer.height = height;
    buffer.cells = cells;
    buffer.grapheme_buffer = try t.GraphemeBuffer.initCapacity(grapheme_buffer_size.max, grapheme_buffer_size.initial);
    return buffer;
}

pub fn deinit(self: *FrameBuffer) void {
    self.grapheme_buffer.deinit();
}

pub fn clear(self: *FrameBuffer) void {
    const num_cells = @as(usize, self.width) * @as(usize, self.height);
    @memset(self.cells[0..num_cells], .empty);
    self.grapheme_buffer.reset();
}

pub fn scissor(self: *FrameBuffer) Scissor {
    return Scissor{
        .x_global = 0,
        .y_global = 0,
        .width_global = self.width,
        .height_global = self.height,
        .buffer = self,
    };
}

pub inline fn set(self: *FrameBuffer, x: u16, y: u16, cell: Cell) void {
    assert(x < self.width);
    assert(y < self.height);
    assert(self.width * self.height == self.cells.len);
    const index: usize = @as(usize, y) * @as(usize, self.width) + @as(usize, x);
    self.cells[index] = cell;
}

pub inline fn get(self: FrameBuffer, x: u16, y: u16) Cell {
    assert(x < self.width);
    assert(y < self.height);
    assert(self.width * self.height == self.cells.len);
    const index: usize = @as(usize, y) * @as(usize, self.width) + @as(usize, x);
    return self.cells[index];
}

pub inline fn renderCell(frame_buffer: *const FrameBuffer, cell: Cell, writer: *std.Io.Writer) error{WriteFailed}!void {
    switch (cell.tag) {
        .codepoint => {
            @branchHint(.likely);
            var bytes: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cell.data.codepoint, &bytes) catch blk: {
                @branchHint(.cold);
                bytes = [_]u8{ 0xEF, 0xBF, 0xBD, 0x00 }; // U+FFFD
                break :blk 3;
            };
            try writer.writeAll(bytes[0..len]);
        },
        .grapheme => {
            const id: t.GraphemeBuffer.GraphemeIndex = @truncate(@as(u64, @bitCast(cell)));
            const bytes = frame_buffer.grapheme_buffer.get(id) orelse blk: {
                @branchHint(.cold);
                break :blk &[_]u8{ 0xEF, 0xBF, 0xBD }; // U+FFFD
            };
            try writer.writeAll(bytes);
        },
    }
}

pub fn fullRedraw(self: *const FrameBuffer, writer: *std.Io.Writer) error{WriteFailed}!void {
    assert(self.width * self.height == self.cells.len);
    for (0..self.height) |row| {
        try writer.print("\x1b[{d};{d}H", .{ row + 1, 1 });
        for (self.cells[row * self.width ..][0..self.width]) |cell| {
            switch (cell.width) {
                .wide_end => continue,
                else => try self.renderCell(cell, writer),
            }
        }
    }
}

pub inline fn isDiff(self: *const FrameBuffer, back_bufer: *const FrameBuffer, row: usize, col: usize) bool {
    assert(self.width == back_bufer.width);
    assert(self.height == back_bufer.height);
    const old_cell = back_bufer.cells[row * self.width + col];
    const new_cell = self.cells[row * self.width + col];
    if (!new_cell.eql(old_cell)) {
        return true;
    } else if (old_cell.tag == .grapheme) {
        @branchHint(.unlikely);
        const old_id: t.GraphemeBuffer.GraphemeIndex = @truncate(@as(u64, @bitCast(old_cell)));
        const new_id: t.GraphemeBuffer.GraphemeIndex = @truncate(@as(u64, @bitCast(new_cell)));
        const old_grapheme = back_bufer.grapheme_buffer.get(old_id) orelse return true;
        const new_grapheme = self.grapheme_buffer.get(new_id) orelse return false;
        return !std.mem.eql(u8, old_grapheme, new_grapheme);
    } else {
        return false;
    }
}

/// Compares an entire row between two buffers using byte-level comparison.
/// This is faster than cell-by-cell comparison and allows skipping unchanged rows entirely.
/// @NOTE When cells are byte-equal but contain graphemes, the actual grapheme buffer content
/// may differ. We must fall back to cell-by-cell comparison for rows containing graphemes.
fn rowsEqual(self: *const FrameBuffer, other: *const FrameBuffer, row: usize) bool {
    const width: usize = self.width;
    const start = row * width;
    const end = start + width;

    // Fast byte comparison
    if (!std.mem.eql(
        u8,
        std.mem.sliceAsBytes(self.cells[start..end]),
        std.mem.sliceAsBytes(other.cells[start..end]),
    )) {
        return false;
    }

    // Rows are byte-equal, but if any cell contains a grapheme, we must do
    // cell-by-cell comparison because grapheme buffers may have different content
    // for the same grapheme ID.
    // @NOTE it seems it is faster to look at all cells and count graphemes than to have an if statement in the loop
    var num_graphemes: usize = 0;
    for (self.cells[start..end]) |cell| {
        num_graphemes += @intFromEnum(cell.tag);
    }
    if (num_graphemes > 0) return false;

    return true;
}

pub fn diffRedraw(self: *const FrameBuffer, back_buffer: *const FrameBuffer, writer: *std.Io.Writer) error{WriteFailed}!void {
    assert(back_buffer.width == self.width);
    assert(back_buffer.height == self.height);
    assert(self.width * self.height == self.cells.len);
    assert(back_buffer.width * back_buffer.height == back_buffer.cells.len);

    const height: usize = back_buffer.height;
    const width: usize = back_buffer.width;

    for (0..height) |row| {
        // Fast path: skip entirely unchanged rows
        if (self.rowsEqual(back_buffer, row)) continue;

        const row_start: usize = row * width;
        const row_end: usize = row_start + width;
        var col: usize = 0;
        while (col < width) {
            var start: usize = row_start + col;
            while (start < row_end and !self.isDiff(back_buffer, row, start - row_start)) {
                if (back_buffer.cells[start].width == .wide_start) {
                    assert(start < row_end - 1);
                    start += 2;
                } else {
                    start += 1;
                }
            }
            var end: usize = start;

            while (end < row_end and self.isDiff(back_buffer, row, end - row_start)) {
                if (back_buffer.cells[end].width == .wide_start or self.cells[end].width == .wide_start) {
                    assert(end < row_end - 1);
                    end += 2;
                } else {
                    end += 1;
                }
            }
            if (start >= row_end) break;
            try writer.print("\x1b[{d};{d}H", .{ row + 1, start - row_start + 1 });
            for (self.cells[start..end]) |cell| {
                switch (cell.width) {
                    .wide_end => continue,
                    else => try self.renderCell(cell, writer),
                }
            }
            col = end - row_start;
        }
    }
}

fn printSequence(sequence: []const u8) void {
    for (sequence) |byte| {
        if (byte == '\x1b') std.debug.print("\\x1b", .{}) else std.debug.print("{c}", .{byte});
    }
}

fn expectEqualSequences(expected: []const u8, actual: []const u8) !void {
    const print = std.debug.print;
    if (std.mem.findDiff(u8, actual, expected)) |_| {
        print("\n====== expected this output: =========\n", .{});
        printSequence(expected);
        print("\n======== instead found this: =========\n", .{});
        printSequence(actual);
        print("\n======================================\n", .{});
        return error.TestExpectedEqual;
    }
}

test "fullRedraw - multi-byte UTF-8" {
    const cells = try std.testing.allocator.alloc(Cell, 4);
    defer std.testing.allocator.free(cells);
    var front = try FrameBuffer.init(cells, 4, 1, .tiny);
    defer front.deinit();

    front.set(0, 0, .{ .data = .{ .codepoint = 'A' } });
    front.set(1, 0, .{ .data = .{ .codepoint = 0x00E9 } });
    front.set(2, 0, .{ .data = .{ .codepoint = 0x4E2D } });
    front.set(3, 0, .{ .data = .{ .codepoint = 0x1D11E } });

    var output_buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    try front.fullRedraw(&writer);
    const output = writer.buffered();

    const expected = "\x1b[1;1HA\xC3\xA9\xE4\xB8\xAD\xF0\x9D\x84\x9E";
    try expectEqualSequences(expected, output);
}

test "fullRedraw wide characters" {
    const cells = try std.testing.allocator.alloc(Cell, 6);
    defer std.testing.allocator.free(cells);
    var front = try FrameBuffer.init(cells, 6, 1, .tiny);
    defer front.deinit();

    front.set(0, 0, .{ .data = .{ .codepoint = 'A' } });
    // 中 (U+4E2D)
    front.set(1, 0, .{ .data = .{ .codepoint = 0x4E2D }, .width = .wide_start });
    front.set(2, 0, .{ .data = .{ .codepoint = ' ' }, .width = .wide_end });
    front.set(3, 0, .{ .data = .{ .codepoint = 'B' } });
    //  国 (U+56FD)
    front.set(4, 0, .{ .data = .{ .codepoint = 0x56FD }, .width = .wide_start });
    front.set(5, 0, .{ .data = .{ .codepoint = ' ' }, .width = .wide_end });

    var output_buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    try front.fullRedraw(&writer);
    const output = writer.buffered();

    const expected = "\x1b[1;1HA\xE4\xB8\xADB\xE5\x9B\xBD";
    try expectEqualSequences(expected, output);
}

test "fullRedraw graphemes - wide and graphemes" {
    const cells = try std.testing.allocator.alloc(Cell, 8);
    defer std.testing.allocator.free(cells);
    var front = try FrameBuffer.init(cells, 4, 2, .tiny);
    defer front.deinit();

    front.clear();

    front.set(0, 0, .{ .data = .{ .codepoint = 'A' } });
    // 👍 (U+1F44D)
    const thumbs_up = "\xF0\x9F\x91\x8D";
    front.set(1, 0, .{ .data = .{ .codepoint = '👍' }, .tag = .codepoint, .width = .wide_start });
    front.set(2, 0, .{ .width = .wide_end });
    const e_acute_combining = "e\xCC\x81";
    const id = try front.grapheme_buffer.put(e_acute_combining);
    front.set(3, 0, Cell.initGrapheme(id, .narrow));
    // 👨‍👩‍👧 (family emoji) - ZWJ sequence
    const family = "\xF0\x9F\x91\xA8\xE2\x80\x8D\xF0\x9F\x91\xA9\xE2\x80\x8D\xF0\x9F\x91\xA7";
    const id_1 = try front.grapheme_buffer.put(family);
    front.set(1, 1, Cell.initGrapheme(id_1, .wide_start));
    front.set(2, 1, .wide_end);

    var output_buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    try front.fullRedraw(&writer);
    const output = writer.buffered();

    const expected = "\x1b[1;1HA" ++ thumbs_up ++ e_acute_combining ++ "\x1b[2;1H " ++ family ++ " ";
    try expectEqualSequences(expected, output);
}

test "fullRedraw error handling - invalid codepoint" {
    const cells = try std.testing.allocator.alloc(Cell, 3);
    defer std.testing.allocator.free(cells);
    var front = try FrameBuffer.init(cells, 3, 1, .tiny);
    defer front.deinit();

    front.set(0, 0, .{ .data = .{ .codepoint = 'A' } });
    // Invalid codepoint (surrogate range U+D800-U+DFFF)
    front.set(1, 0, .{ .data = .{ .codepoint = 0xD800 } });
    front.set(2, 0, .{ .data = .{ .codepoint = 'B' } });

    var output_buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    try front.fullRedraw(&writer);
    const output = writer.buffered();

    // Invalid codepoints should render as U+FFFD (\xEF\xBF\xBD)
    const expected = "\x1b[1;1HA\xEF\xBF\xBDB";
    try expectEqualSequences(expected, output);
}

test "fullRedraw error handling - missing grapheme" {
    const cells = try std.testing.allocator.alloc(Cell, 3);
    defer std.testing.allocator.free(cells);
    var front = try FrameBuffer.init(cells, 3, 1, .tiny);
    defer front.deinit();

    front.set(0, 0, .{ .data = .{ .codepoint = 'A' } });
    // Mark cell as grapheme but don't put any grapheme data
    front.set(1, 0, .{ .tag = .grapheme });
    front.set(2, 0, .{ .data = .{ .codepoint = 'B' } });

    var output_buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    try front.fullRedraw(&writer);
    const output = writer.buffered();

    // Missing grapheme should render as U+FFFD (\xEF\xBF\xBD)
    const expected = "\x1b[1;1HA\xEF\xBF\xBDB";
    try expectEqualSequences(expected, output);
}

test "diffRedraw no changes" {
    const front_cells = try std.testing.allocator.alloc(Cell, 10);
    defer std.testing.allocator.free(front_cells);
    var front = try FrameBuffer.init(front_cells, 5, 2, .tiny);
    defer front.deinit();
    const back_cells = try std.testing.allocator.alloc(Cell, 10);
    defer std.testing.allocator.free(back_cells);
    var back = try FrameBuffer.init(back_cells, 5, 2, .tiny);
    defer back.deinit();

    front.clear();
    back.clear();

    // Both buffers have same content (spaces)
    var output_buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    try front.diffRedraw(&back, &writer);
    const output = writer.buffered();

    // No changes: diffRedraw still outputs cursor positions at end of each row
    // For width=5, cursor goes to column 6 (width + 1)
    const expected = "";
    try expectEqualSequences(expected, output);
}

test "diffRedraw all changed" {
    const front_cells = try std.testing.allocator.alloc(Cell, 10);
    defer std.testing.allocator.free(front_cells);
    var front = try FrameBuffer.init(front_cells, 5, 2, .tiny);
    defer front.deinit();
    const back_cells = try std.testing.allocator.alloc(Cell, 10);
    defer std.testing.allocator.free(back_cells);
    var back = try FrameBuffer.init(back_cells, 5, 2, .tiny);
    defer back.deinit();

    back.clear();

    // Back buffer has spaces, front buffer has all 'X'
    for (0..5) |x| {
        for (0..2) |y| {
            front.set(@intCast(x), @intCast(y), .{ .data = .{ .codepoint = 'X' } });
        }
    }

    var output_buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    try front.diffRedraw(&back, &writer);
    const output = writer.buffered();

    const expected = "\x1b[1;1HXXXXX\x1b[2;1HXXXXX";
    try expectEqualSequences(expected, output);
}

test "diffRedraw multiple disjoint segments in one row" {
    const front_cells = try std.testing.allocator.alloc(Cell, 10);
    defer std.testing.allocator.free(front_cells);
    var front = try FrameBuffer.init(front_cells, 10, 1, .tiny);
    defer front.deinit();
    const back_cells = try std.testing.allocator.alloc(Cell, 10);
    defer std.testing.allocator.free(back_cells);
    var back = try FrameBuffer.init(back_cells, 10, 1, .tiny);
    defer back.deinit();

    front.clear();
    back.clear();

    front.set(2, 0, .{ .data = .{ .codepoint = 'A' } });
    front.set(3, 0, .{ .data = .{ .codepoint = 'B' } });
    front.set(7, 0, .{ .data = .{ .codepoint = 'C' } });
    front.set(8, 0, .{ .data = .{ .codepoint = 'D' } });

    var output_buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    try front.diffRedraw(&back, &writer);
    const output = writer.buffered();

    const expected = "\x1b[1;3HAB\x1b[1;8HCD";
    try expectEqualSequences(expected, output);
}

test "diffRedraw changes in multiple rows" {
    const front_cells = try std.testing.allocator.alloc(Cell, 15);
    defer std.testing.allocator.free(front_cells);
    var front = try FrameBuffer.init(front_cells, 5, 3, .tiny);
    defer front.deinit();
    const back_cells = try std.testing.allocator.alloc(Cell, 15);
    defer std.testing.allocator.free(back_cells);
    var back = try FrameBuffer.init(back_cells, 5, 3, .tiny);
    defer back.deinit();

    front.clear();
    back.clear();

    // Change one cell in each row
    front.set(1, 0, .{ .data = .{ .codepoint = 'A' } });
    front.set(2, 1, .{ .data = .{ .codepoint = 'B' } });
    front.set(3, 2, .{ .data = .{ .codepoint = 'C' } });

    var output_buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    try front.diffRedraw(&back, &writer);
    const output = writer.buffered();

    // Each row has a change plus an end-of-row cursor position
    const expected = "\x1b[1;2HA\x1b[2;3HB\x1b[3;4HC";
    try expectEqualSequences(expected, output);
}

test "diffRedraw grapheme same in both buffers" {
    const front_cells = try std.testing.allocator.alloc(Cell, 3);
    defer std.testing.allocator.free(front_cells);
    var front = try FrameBuffer.init(front_cells, 3, 1, .tiny);
    defer front.deinit();
    const back_cells = try std.testing.allocator.alloc(Cell, 3);
    defer std.testing.allocator.free(back_cells);
    var back = try FrameBuffer.init(back_cells, 3, 1, .tiny);
    defer back.deinit();

    front.clear();
    back.clear();

    const emoji = "\xF0\x9F\x91\xA8\xE2\x80\x8D\xF0\x9F\x91\xA9\xE2\x80\x8D\xF0\x9F\x91\xA7"; // 👨‍👩‍👧
    const id = try front.grapheme_buffer.put(emoji);
    front.set(1, 0, Cell.initGrapheme(id, .wide_start));
    front.set(2, 0, .wide_end);
    const back_id = try back.grapheme_buffer.put(emoji);
    back.set(1, 0, Cell.initGrapheme(back_id, .wide_start));
    back.set(2, 0, .wide_end);

    var output_buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    try front.diffRedraw(&back, &writer);
    const output = writer.buffered();

    const expected = "";
    try expectEqualSequences(expected, output);
}

test "diffRedraw grapheme changed" {
    const front_cells = try std.testing.allocator.alloc(Cell, 3);
    defer std.testing.allocator.free(front_cells);
    var front = try FrameBuffer.init(front_cells, 3, 1, .tiny);
    defer front.deinit();
    const back_cells = try std.testing.allocator.alloc(Cell, 3);
    defer std.testing.allocator.free(back_cells);
    var back = try FrameBuffer.init(back_cells, 3, 1, .tiny);
    defer back.deinit();

    front.clear();
    back.clear();

    // Not technically a grapheme but whose gonna stop me
    const emoji1 = "\xF0\x9F\x91\x8D"; // 👍
    const emoji2 = "\xF0\x9F\x91\x8E"; // 👎
    const id_1 = try front.grapheme_buffer.put(emoji1);
    const id_2 = try back.grapheme_buffer.put(emoji2);
    front.set(1, 0, Cell.initGrapheme(id_1, .wide_start));
    front.set(2, 0, .wide_end);
    back.set(1, 0, Cell.initGrapheme(id_2, .wide_start));
    back.set(2, 0, .wide_end);

    var output_buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    try front.diffRedraw(&back, &writer);
    const output = writer.buffered();

    const expected = "\x1b[1;2H" ++ emoji1;
    try expectEqualSequences(expected, output);
}

test "diffRedraw grapheme vs codepoint" {
    const front_cells = try std.testing.allocator.alloc(Cell, 3);
    defer std.testing.allocator.free(front_cells);
    var front = try FrameBuffer.init(front_cells, 3, 1, .tiny);
    defer front.deinit();
    const back_cells = try std.testing.allocator.alloc(Cell, 3);
    defer std.testing.allocator.free(back_cells);
    var back = try FrameBuffer.init(back_cells, 3, 1, .tiny);
    defer back.deinit();

    front.clear();
    back.clear();

    const emoji = "\xF0\x9F\x91\x8D"; // 👍
    const id = try back.grapheme_buffer.put(emoji);
    back.set(1, 0, Cell.initGrapheme(id, .wide_start));
    back.set(2, 0, .wide_end);
    front.set(1, 0, .{ .data = .{ .codepoint = 'X' } });

    var output_buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    try front.diffRedraw(&back, &writer);
    const output = writer.buffered();

    const expected = "\x1b[1;2HX ";
    try expectEqualSequences(expected, output);
}

// test "renderCell basic codepoint" {
//     const cells = try std.testing.allocator.alloc(Cell, 4);
//     defer std.testing.allocator.free(cells);
//     var front = try FrameBuffer.init(cells, 4, 1, .tiny);
//     defer front.deinit();
//
//     front.set(0, 0, .{ .data = .{ .codepoint = 'A' } });
//     front.set(1, 0, .{ .data = .{ .codepoint = 0x4E2D }, .width = .wide_start }); // 中
//     front.set(2, 0, .{ .width = .wide_end });
//     front.set(3, 0, .{ .data = .{ .codepoint = 'B' } });
//
//     var output_buffer: [256]u8 = undefined;
//     var writer = std.Io.Writer.fixed(&output_buffer);
//
//     const advance0 = try front.renderCell(0, 0, &writer);
//     try std.testing.expectEqual(@as(u3, 1), advance0);
//
//     const advance1 = try front.renderCell(0, 1, &writer);
//     try std.testing.expectEqual(@as(u3, 2), advance1);
//
//     const advace_wide_end = try front.renderCell(0, 2, &writer);
//     try std.testing.expectEqual(@as(u3, 1), advace_wide_end);
//
//     const advance2 = try front.renderCell(0, 3, &writer);
//     try std.testing.expectEqual(@as(u3, 1), advance2);
//
//     const output = writer.buffered();
//     try expectEqualSequences("A\xE4\xB8\xADB", output);
// }
