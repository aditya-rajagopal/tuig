const std = @import("std");
const Allocator = std.mem.Allocator;

const stdx = @import("stdx");
const assert = stdx.inlineAssert;

const t = @import("types.zig");

const seq = @import("terminal").sequences;

const Cell = @import("root.zig").Cell;
const Style = @import("root.zig").Style;
const CellSize = @import("root.zig").CellSize;
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
        .x_clip = 0,
        .y_clip = 0,
        .width_clip = self.width,
        .height_clip = self.height,
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
            const c = cell.data.codepoint;
            if (c < 0x80) {
                return writer.writeByte(@as(u8, @truncate(c)));
            }
            if (c < 0x800) {
                _ = try writer.writeAll(&[_]u8{
                    @as(u8, @intCast(0b11000000 | (c >> 6))),
                    @as(u8, @intCast(0b10000000 | (c & 0b111111))),
                });
                return;
            }
            if (c < 0x10000) {
                switch (c) {
                    0xD800...0xDFFF => {
                        @branchHint(.cold);
                        return writer.writeAll(&[_]u8{ 0xEF, 0xBF, 0xBD });
                    },
                    else => {
                        _ = try writer.writeAll(&[_]u8{
                            @as(u8, @intCast(0b11100000 | (c >> 12))),
                            @as(u8, @intCast(0b10000000 | ((c >> 6) & 0b111111))),
                            @as(u8, @intCast(0b10000000 | (c & 0b111111))),
                        });
                        return;
                    },
                }
            }
            if (c < 0x110000) {
                _ = try writer.writeAll(&[_]u8{
                    @as(u8, @intCast(0b11110000 | (c >> 18))),
                    @as(u8, @intCast(0b10000000 | ((c >> 12) & 0b111111))),
                    @as(u8, @intCast(0b10000000 | ((c >> 6) & 0b111111))),
                    @as(u8, @intCast(0b10000000 | (c & 0b111111))),
                });
                return;
            } else {
                @branchHint(.cold);
                return writer.writeAll(&[_]u8{ 0xEF, 0xBF, 0xBD });
            }
        },
        .grapheme => {
            const id: t.GraphemeBuffer.GraphemeIndex = @truncate(@as(CellSize, @bitCast(cell)));
            const bytes = frame_buffer.grapheme_buffer.get(id) orelse blk: {
                @branchHint(.cold);
                break :blk &[_]u8{ 0xEF, 0xBF, 0xBD }; // U+FFFD
            };
            try writer.writeAll(bytes);
        },
    }
}

pub fn fullRedraw(self: *const FrameBuffer, style_sheet: *const Style.Sheet, writer: *std.Io.Writer) error{WriteFailed}!void {
    assert(self.width * self.height == self.cells.len);
    var current_style: Style.Id = .default;
    for (0..self.height) |row| {
        try seq.cursor.to(writer, @intCast(row + 1), 1);
        for (self.cells[row * self.width ..][0..self.width]) |cell| {
            if (cell.width == .wide_end) continue;
            if (cell.style != current_style) {
                try Style.write(cell.style, current_style, style_sheet, writer);
                current_style = cell.style;
            }
            try self.renderCell(cell, writer);
        }
    }
}

pub inline fn isDiff(self: *const FrameBuffer, back_buffer: *const FrameBuffer, row: usize, col: usize) bool {
    assert(self.width == back_buffer.width);
    assert(self.height == back_buffer.height);
    const old_cell = back_buffer.cells[row * self.width + col];
    const new_cell = self.cells[row * self.width + col];
    if (!new_cell.eql(old_cell)) {
        return true;
    } else if (old_cell.tag == .grapheme) {
        const old_id: t.GraphemeBuffer.GraphemeIndex = @truncate(@as(CellSize, @bitCast(old_cell)));
        const new_id: t.GraphemeBuffer.GraphemeIndex = @truncate(@as(CellSize, @bitCast(new_cell)));
        const old_grapheme = back_buffer.grapheme_buffer.get(old_id) orelse return true;
        const new_grapheme = self.grapheme_buffer.get(new_id) orelse return true;
        return !std.mem.eql(u8, old_grapheme, new_grapheme);
    } else {
        return false;
    }
}

pub fn diffRedraw(self: *const FrameBuffer, back_buffer: *const FrameBuffer, style_sheet: *const Style.Sheet, writer: *std.Io.Writer) error{WriteFailed}!void {
    assert(back_buffer.width == self.width);
    assert(back_buffer.height == self.height);
    assert(self.width * self.height == self.cells.len);
    assert(back_buffer.width * back_buffer.height == back_buffer.cells.len);

    const height: usize = back_buffer.height;
    const width: usize = back_buffer.width;

    var current_style: Style.Id = .default;

    for (0..height) |row| {
        const row_start: usize = row * width;
        const row_end: usize = row_start + width;
        var col: usize = 0;
        // Fast path: skip entirely unchanged rows
        for (self.cells[row_start..row_end], back_buffer.cells[row_start..row_end], 0..) |self_cell, other_cell, i| {
            if (@as(u64, @bitCast(self_cell)) != @as(u64, @bitCast(other_cell)) or self_cell.tag == .grapheme) {
                col = i;
                break;
            }
        } else {
            continue;
        }

        while (col < width) {
            var start: usize = col;
            while (start < width and !self.isDiff(back_buffer, row, start)) {
                if (back_buffer.cells[row_start + start].width == .wide_start) {
                    assert(start < width - 1);
                    start += 2;
                } else {
                    start += 1;
                }
            }
            if (start >= width) break;

            var end: usize = start;

            while (end < width and self.isDiff(back_buffer, row, end)) {
                if (back_buffer.cells[row_start + end].width == .wide_start or self.cells[row_start + end].width == .wide_start) {
                    assert(end < width - 1);
                    end += 2;
                } else {
                    end += 1;
                }
            }
            try seq.cursor.to(writer, @intCast(row + 1), @intCast(start + 1));
            for (self.cells[row_start..][start..end]) |cell| {
                if (cell.width == .wide_end) continue;
                if (current_style != cell.style) {
                    try Style.write(cell.style, current_style, style_sheet, writer);
                    current_style = cell.style;
                }
                try self.renderCell(cell, writer);
            }
            col = end;
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

    var style_buffer: [4]Style = undefined;
    var generator_buffer: [4]u8 = undefined;
    const style_sheet = Style.Sheet.initBuffer(&style_buffer, &generator_buffer);

    try front.fullRedraw(&style_sheet, &writer);
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

    var style_buffer: [4]Style = undefined;
    var generator_buffer: [4]u8 = undefined;
    const style_sheet = Style.Sheet.initBuffer(&style_buffer, &generator_buffer);

    try front.fullRedraw(&style_sheet, &writer);
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
    front.set(3, 0, Cell.initGrapheme(id, .narrow, .default));
    // 👨‍👩‍👧 (family emoji) - ZWJ sequence
    const family = "\xF0\x9F\x91\xA8\xE2\x80\x8D\xF0\x9F\x91\xA9\xE2\x80\x8D\xF0\x9F\x91\xA7";
    const id_1 = try front.grapheme_buffer.put(family);
    front.set(1, 1, Cell.initGrapheme(id_1, .wide_start, .default));
    front.set(2, 1, .wide_end);

    var output_buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    var style_buffer: [4]Style = undefined;
    var generator_buffer: [4]u8 = undefined;
    const style_sheet = Style.Sheet.initBuffer(&style_buffer, &generator_buffer);

    try front.fullRedraw(&style_sheet, &writer);
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

    var style_buffer: [4]Style = undefined;
    var generator_buffer: [4]u8 = undefined;
    const style_sheet = Style.Sheet.initBuffer(&style_buffer, &generator_buffer);

    try front.fullRedraw(&style_sheet, &writer);
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

    var style_buffer: [4]Style = undefined;
    var generator_buffer: [4]u8 = undefined;
    const style_sheet = Style.Sheet.initBuffer(&style_buffer, &generator_buffer);

    try front.fullRedraw(&style_sheet, &writer);
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

    var style_buffer: [4]Style = undefined;
    var generator_buffer: [4]u8 = undefined;
    const style_sheet = Style.Sheet.initBuffer(&style_buffer, &generator_buffer);

    try front.diffRedraw(&back, &style_sheet, &writer);
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

    var style_buffer: [4]Style = undefined;
    var generator_buffer: [4]u8 = undefined;
    const style_sheet = Style.Sheet.initBuffer(&style_buffer, &generator_buffer);

    try front.diffRedraw(&back, &style_sheet, &writer);
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

    var style_buffer: [4]Style = undefined;
    var generator_buffer: [4]u8 = undefined;
    const style_sheet = Style.Sheet.initBuffer(&style_buffer, &generator_buffer);

    try front.diffRedraw(&back, &style_sheet, &writer);
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

    var style_buffer: [4]Style = undefined;
    var generator_buffer: [4]u8 = undefined;
    const style_sheet = Style.Sheet.initBuffer(&style_buffer, &generator_buffer);

    try front.diffRedraw(&back, &style_sheet, &writer);
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
    front.set(1, 0, Cell.initGrapheme(id, .wide_start, .default));
    front.set(2, 0, .wide_end);
    const back_id = try back.grapheme_buffer.put(emoji);
    back.set(1, 0, Cell.initGrapheme(back_id, .wide_start, .default));
    back.set(2, 0, .wide_end);

    var output_buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    var style_buffer: [4]Style = undefined;
    var generator_buffer: [4]u8 = undefined;
    const style_sheet = Style.Sheet.initBuffer(&style_buffer, &generator_buffer);

    try front.diffRedraw(&back, &style_sheet, &writer);
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
    front.set(1, 0, Cell.initGrapheme(id_1, .wide_start, .default));
    front.set(2, 0, .wide_end);
    back.set(1, 0, Cell.initGrapheme(id_2, .wide_start, .default));
    back.set(2, 0, .wide_end);

    var output_buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    var style_buffer: [4]Style = undefined;
    var generator_buffer: [4]u8 = undefined;
    const style_sheet = Style.Sheet.initBuffer(&style_buffer, &generator_buffer);

    try front.diffRedraw(&back, &style_sheet, &writer);
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
    back.set(1, 0, Cell.initGrapheme(id, .wide_start, .default));
    back.set(2, 0, .wide_end);
    front.set(1, 0, .{ .data = .{ .codepoint = 'X' } });

    var output_buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    var style_buffer: [4]Style = undefined;
    var generator_buffer: [4]u8 = undefined;
    const style_sheet = Style.Sheet.initBuffer(&style_buffer, &generator_buffer);

    try front.diffRedraw(&back, &style_sheet, &writer);
    const output = writer.buffered();

    const expected = "\x1b[1;2HX ";
    try expectEqualSequences(expected, output);
}

test "fullRedraw and diffRedraw with ANSI colors" {
    const cells = try std.testing.allocator.alloc(Cell, 4);
    defer std.testing.allocator.free(cells);
    var front = try FrameBuffer.init(cells, 4, 1, .tiny);
    defer front.deinit();

    var style_buffer: [8]Style = undefined;
    var generator_buffer: [8]u8 = undefined;
    var style_sheet = Style.Sheet.initBuffer(&style_buffer, &generator_buffer);

    const style_a = style_sheet.putBounded(.{
        .fg = .{ .ansi = .red },
        .bg = .{ .ansi = .black },
        .underline = .{ .ansi = .black },
    });
    const style_b = style_sheet.putBounded(.{
        .fg = .{ .ansi = .black },
        .bg = .{ .ansi = .bright_blue },
        .underline = .{ .ansi = .black },
    });
    const style_c = style_sheet.putBounded(.{
        .fg = .{ .ansi = @enumFromInt(200) },
        .bg = .{ .ansi = .bright_blue },
        .underline = .{ .ansi = .red },
    });

    front.set(0, 0, .{ .data = .{ .codepoint = 'A' }, .style = style_a });
    front.set(1, 0, .{ .data = .{ .codepoint = 'B' }, .style = style_b });
    front.set(2, 0, .{ .data = .{ .codepoint = 'C' }, .style = style_c });
    front.set(3, 0, .{ .data = .{ .codepoint = 'D' } });

    var output_buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    try front.fullRedraw(&style_sheet, &writer);
    const output = writer.buffered();

    // Expected:
    // - Cursor to row 0, col 0
    // - Red fg (31), black bg (40), black underline color
    // - 'A'
    // - Black fg (30), bright blue bg (104)
    // - 'B'
    // - Indexed fg 200, black bg (40)
    // - 'C'
    // - Default style (fg reset, bg reset, underline reset)
    // - 'D'
    const expected = "\x1b[1;1H" ++
        "\x1b[31m\x1b[40m\x1b[58:5:0m" ++ "A" ++
        "\x1b[30m\x1b[104m" ++ "B" ++
        "\x1b[38:5:200m\x1b[58:5:1m" ++ "C" ++
        "\x1b[39m\x1b[49m\x1b[59m" ++ "D";
    try expectEqualSequences(expected, output);

    const back_cells = try std.testing.allocator.alloc(Cell, 4);
    defer std.testing.allocator.free(back_cells);
    var back = try FrameBuffer.init(back_cells, 4, 1, .tiny);
    defer back.deinit();
    @memcpy(back.cells, front.cells);

    const style_b_green = style_sheet.putBounded(.{
        .fg = .{ .ansi = .black },
        .bg = .{ .ansi = .green },
        .underline = .{ .ansi = .black },
    });
    front.set(1, 0, .{ .data = .{ .codepoint = 'B' }, .style = style_b_green });

    var writer2 = std.Io.Writer.fixed(&output_buffer);
    try front.diffRedraw(&back, &style_sheet, &writer2);
    const diff_output = writer2.buffered();

    // Expected:
    //   - move cursor to column 1, row 0
    //   - Change style to black fg (30), green bg (42), black underline color
    //   - 'B'
    const expected_diff = "\x1b[1;2H" ++ "\x1b[30m\x1b[42m\x1b[58:5:0m" ++ "B";
    try expectEqualSequences(expected_diff, diff_output);
}

test "fullRedraw and diffRedraw with RGB colors" {
    const cells = try std.testing.allocator.alloc(Cell, 3);
    defer std.testing.allocator.free(cells);
    var front = try FrameBuffer.init(cells, 3, 1, .tiny);
    defer front.deinit();

    var style_buffer: [8]Style = undefined;
    var generator_buffer: [8]u8 = undefined;
    var style_sheet = Style.Sheet.initBuffer(&style_buffer, &generator_buffer);

    const style_a = style_sheet.putBounded(.{
        .fg = .{ .rgb = .{ .r = 255, .g = 128, .b = 0 } },
    });
    const style_b = style_sheet.putBounded(.{
        .fg = .{ .rgb = .{ .r = 255, .g = 128, .b = 0 } },
        .bg = .{ .rgb = .{ .r = 0, .g = 64, .b = 128 } },
    });

    front.set(0, 0, .{ .data = .{ .codepoint = 'A' }, .style = style_a });
    front.set(1, 0, .{ .data = .{ .codepoint = 'B' }, .style = style_b });
    front.set(2, 0, .{ .data = .{ .codepoint = 'C' } });

    var output_buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    try front.fullRedraw(&style_sheet, &writer);
    const output = writer.buffered();

    // Expected:
    //   - Cursor to row 0, col 0
    //   - RGB fg (255, 128, 0) - orange
    //   - 'A'
    //   - RGB bg (0, 64, 128) - dark blue
    //   - 'B'
    //   - Default style (fg reset, bg reset)
    //   - 'C'
    const expected = "\x1b[1;1H" ++
        "\x1b[38:2:255:128:0m" ++ "A" ++
        "\x1b[48:2:0:64:128m" ++ "B" ++
        "\x1b[39m\x1b[49m" ++ "C";
    try expectEqualSequences(expected, output);

    const back_cells = try std.testing.allocator.alloc(Cell, 3);
    defer std.testing.allocator.free(back_cells);
    var back = try FrameBuffer.init(back_cells, 3, 1, .tiny);
    defer back.deinit();
    @memcpy(back.cells, front.cells);

    const style_a_new = style_sheet.putBounded(.{
        .fg = .{ .rgb = .{ .r = 128, .g = 255, .b = 64 } },
    });
    front.set(0, 0, .{ .data = .{ .codepoint = 'A' }, .style = style_a_new });

    var writer2 = std.Io.Writer.fixed(&output_buffer);
    try front.diffRedraw(&back, &style_sheet, &writer2);
    const diff_output = writer2.buffered();

    const expected_diff = "\x1b[1;1H" ++ "\x1b[38:2:128:255:64m" ++ "A";
    try expectEqualSequences(expected_diff, diff_output);
}

test "fullRedraw and diffRedraw with text attributes" {
    const cells = try std.testing.allocator.alloc(Cell, 9);
    defer std.testing.allocator.free(cells);
    var front = try FrameBuffer.init(cells, 3, 3, .tiny);
    defer front.deinit();

    var style_buffer: [16]Style = undefined;
    var generator_buffer: [16]u8 = undefined;
    var style_sheet = Style.Sheet.initBuffer(&style_buffer, &generator_buffer);

    const style_bold = style_sheet.putBounded(.{ .flags = .{ .bold = true } });
    const style_italic = style_sheet.putBounded(.{ .flags = .{ .italic = true } });
    const style_underline = style_sheet.putBounded(.{ .flags = .{ .underline = .single } });
    const style_dim = style_sheet.putBounded(.{ .flags = .{ .dim = true } });
    const style_reverse = style_sheet.putBounded(.{ .flags = .{ .reverse = true } });
    const style_strikethrough = style_sheet.putBounded(.{ .flags = .{ .strikethrough = true } });
    const style_blink = style_sheet.putBounded(.{ .flags = .{ .blink = true } });
    const style_invisible = style_sheet.putBounded(.{ .flags = .{ .invisible = true } });
    const style_curly = style_sheet.putBounded(.{ .flags = .{ .underline = .curly } });

    front.set(0, 0, .{ .data = .{ .codepoint = 'A' }, .style = style_bold });
    front.set(1, 0, .{ .data = .{ .codepoint = 'B' }, .style = style_italic });
    front.set(2, 0, .{ .data = .{ .codepoint = 'C' }, .style = style_underline });
    front.set(0, 1, .{ .data = .{ .codepoint = 'D' }, .style = style_dim });
    front.set(1, 1, .{ .data = .{ .codepoint = 'E' }, .style = style_reverse });
    front.set(2, 1, .{ .data = .{ .codepoint = 'F' }, .style = style_strikethrough });
    front.set(0, 2, .{ .data = .{ .codepoint = 'G' }, .style = style_blink });
    front.set(1, 2, .{ .data = .{ .codepoint = 'H' }, .style = style_invisible });
    front.set(2, 2, .{ .data = .{ .codepoint = 'I' }, .style = style_curly });

    var output_buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    try front.fullRedraw(&style_sheet, &writer);
    const output = writer.buffered();

    // Row 0:
    // A: default colors + bold enable
    // B: bold disable + italic enable
    // C: italic disable + underline single
    // Row 1:
    // D: dim enable + underline reset (order: bold/dim before underline)
    // E: dim disable + reverse enable
    // F: reverse disable + strikethrough enable
    // Row 2:
    // G: blink enable + strikethrough disable (order: blink before strikethrough)
    // H: blink disable + invisible enable
    // I: invisible disable + underline curly
    const expected = "\x1b[1;1H" ++
        "\x1b[1m" ++ "A" ++
        "\x1b[22m\x1b[3m" ++ "B" ++
        "\x1b[23m\x1b[4m" ++ "C" ++
        "\x1b[2;1H" ++
        "\x1b[2m\x1b[24m" ++ "D" ++
        "\x1b[22m\x1b[7m" ++ "E" ++
        "\x1b[27m\x1b[9m" ++ "F" ++
        "\x1b[3;1H" ++
        "\x1b[5m\x1b[29m" ++ "G" ++
        "\x1b[25m\x1b[8m" ++ "H" ++
        "\x1b[28m\x1b[4:3m" ++ "I";
    try expectEqualSequences(expected, output);
}

test "fullRedraw and diffRedraw bold/dim interaction" {
    const cells = try std.testing.allocator.alloc(Cell, 4);
    defer std.testing.allocator.free(cells);
    var front = try FrameBuffer.init(cells, 4, 1, .tiny);
    defer front.deinit();

    var style_buffer: [8]Style = undefined;
    var generator_buffer: [8]u8 = undefined;
    var style_sheet = Style.Sheet.initBuffer(&style_buffer, &generator_buffer);

    const style_bold = style_sheet.putBounded(.{ .flags = .{ .bold = true } });
    const style_bold_dim = style_sheet.putBounded(.{ .flags = .{ .bold = true, .dim = true } });
    const style_dim = style_sheet.putBounded(.{ .flags = .{ .dim = true } });

    // Cell 0: bold
    front.set(0, 0, .{ .data = .{ .codepoint = 'A' }, .style = style_bold });
    // Cell 1: bold + dim
    front.set(1, 0, .{ .data = .{ .codepoint = 'B' }, .style = style_bold_dim });
    // Cell 2: dim only (bold off)
    front.set(2, 0, .{ .data = .{ .codepoint = 'C' }, .style = style_dim });
    // Cell 3: default (both off)
    front.set(3, 0, .{ .data = .{ .codepoint = 'D' } });

    var output_buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    try front.fullRedraw(&style_sheet, &writer);
    const output = writer.buffered();

    // A: default → bold: enable bold
    // B: bold → bold+dim: re-emit bold (since dim changed), add dim
    // C: bold+dim → dim: disable both (22), re-enable dim (2)
    // D: dim → default: disable bold/dim (22)
    const expected = "\x1b[1;1H" ++
        "\x1b[1m" ++ "A" ++
        "\x1b[1m\x1b[2m" ++ "B" ++
        "\x1b[22m\x1b[2m" ++ "C" ++
        "\x1b[22m" ++ "D";
    try expectEqualSequences(expected, output);
}

test "diffRedraw style change only" {
    const front_cells = try std.testing.allocator.alloc(Cell, 4);
    defer std.testing.allocator.free(front_cells);
    var front = try FrameBuffer.init(front_cells, 4, 1, .tiny);
    defer front.deinit();
    const back_cells = try std.testing.allocator.alloc(Cell, 4);
    defer std.testing.allocator.free(back_cells);
    var back = try FrameBuffer.init(back_cells, 4, 1, .tiny);
    defer back.deinit();

    var style_buffer: [4]Style = undefined;
    var generator_buffer: [4]u8 = undefined;
    var style_sheet = Style.Sheet.initBuffer(&style_buffer, &generator_buffer);

    const red_style_id = style_sheet.putBounded(.{
        .fg = .{ .ansi = .red },
        .bg = .{ .ansi = .black },
        .underline = .{ .ansi = .black },
    });

    for (0..4) |i| {
        back.set(@intCast(i), 0, .{ .data = .{ .codepoint = 'A' } });
    }

    for (0..4) |i| {
        front.set(@intCast(i), 0, .{
            .data = .{ .codepoint = 'A' },
            .style = red_style_id,
        });
    }

    var output_buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    try front.diffRedraw(&back, &style_sheet, &writer);
    const output = writer.buffered();

    const expected = "\x1b[1;1H" ++ "\x1b[31m\x1b[40m\x1b[58:5:0m" ++ "AAAA";
    try expectEqualSequences(expected, output);
}

test "fullRedraw and diffRedraw with stylesheet update" {
    const front_cells = try std.testing.allocator.alloc(Cell, 4);
    defer std.testing.allocator.free(front_cells);
    var front = try FrameBuffer.init(front_cells, 4, 1, .tiny);
    defer front.deinit();
    const back_cells = try std.testing.allocator.alloc(Cell, 4);
    defer std.testing.allocator.free(back_cells);
    var back = try FrameBuffer.init(back_cells, 4, 1, .tiny);
    defer back.deinit();
    front.clear();
    back.clear();

    var style_buffer: [8]Style = undefined;
    var generator_buffer: [8]u8 = undefined;
    var style_sheet = Style.Sheet.initBuffer(&style_buffer, &generator_buffer);

    // Add custom style: cyan RGB fg, magenta RGB bg
    var id = style_sheet.putAssumeCapacity(.{
        .fg = .{ .rgb = .{ .r = 0, .g = 255, .b = 255 } },
        .bg = .{ .rgb = .{ .r = 255, .g = 0, .b = 255 } },
        .underline = .none,
    });

    { // First frame
        front.set(0, 0, .{
            .data = .{ .codepoint = 'A' },
            .style = id,
        });
        // Cell 1: default
        front.set(1, 0, .{ .data = .{ .codepoint = 'B' } });

        var output_buffer: [4096]u8 = undefined;
        var writer = std.Io.Writer.fixed(&output_buffer);

        try front.fullRedraw(&style_sheet, &writer);
        const output = writer.buffered();

        // Custom style: RGB fg cyan, RGB bg magenta, underline reset
        const expected = "\x1b[1;1H" ++
            "\x1b[38:2:0:255:255m\x1b[48:2:255:0:255m" ++ "A" ++
            "\x1b[39m\x1b[49m" ++ "B" ++ "  ";
        try expectEqualSequences(expected, output);
    }

    // Swap buffers
    @memcpy(back.cells, front.cells);
    // Something causes style to change
    try id.update(&style_sheet, .{
        .bg = .{ .rgb = .{ .r = 255, .g = 255, .b = 255 } },
        .flags = .{ .bold = true },
    });

    { // Same reference. Simulating usage in an update loop
        front.set(0, 0, .{
            .data = .{ .codepoint = 'A' },
            .style = id,
        });
        // Cell 1: default
        front.set(1, 0, .{ .data = .{ .codepoint = 'B' } });

        var output_buffer: [4096]u8 = undefined;
        var writer = std.Io.Writer.fixed(&output_buffer);
        try front.diffRedraw(&back, &style_sheet, &writer);
        const diff_output = writer.buffered();

        // Expected:
        //     - Cursor to row 0, col 0
        //     - Foreground color 0 255 255
        //     - Background color changed to 255,255,255
        //     - Bold flag changed to true
        //     - 'A'
        const diff_expected = "\x1b[1;1H" ++
            "\x1b[38:2:0:255:255m\x1b[48:2:255:255:255m\x1b[1m" ++ "A";
        try expectEqualSequences(diff_expected, diff_output);
    }
}
