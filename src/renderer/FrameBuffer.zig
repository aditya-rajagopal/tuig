const std = @import("std");
const Allocator = std.mem.Allocator;

const stdx = @import("stdx");
const assert = stdx.inlineAssert;

const t = @import("types.zig");

const Cell = @import("root.zig").Cell;
const Scissor = @import("Scissor.zig");

pub const Options = struct {
    max_cells: usize,
    grapheme_buffer: Size,
    grapheme_map_backing_memory: Size,
    grapheme_map_initial_size: usize,

    pub const Size = struct {
        max: usize,
        initial: usize,
    };

    pub const default_screen = Options{
        .max_cells = 512 * 512, // 2MB cache
        .grapheme_buffer = .{ .max = stdx.MB(2), .initial = stdx.KB(16) },
        .grapheme_map_backing_memory = .{ .max = stdx.MB(2), .initial = stdx.KB(16) },
        .grapheme_map_initial_size = 1024,
    };

    pub const small_buffer = Options{
        .max_cells = 128 * 128, // 128kb buffer
        .grapheme_buffer = .{ .max = stdx.KB(16), .initial = stdx.KB(4) },
        .grapheme_map_backing_memory = .{ .max = stdx.KB(16), .initial = stdx.KB(4) },
        .grapheme_map_initial_size = 256,
    };

    pub const tiny_buffer = Options{
        .max_cells = 64 * 64, // 32kb buffer
        .grapheme_buffer = .{ .max = stdx.KB(8), .initial = stdx.KB(4) },
        .grapheme_map_backing_memory = .{ .max = stdx.KB(16), .initial = stdx.KB(4) },
        .grapheme_map_initial_size = 256,
    };
};

pub const FrameBuffer = @This();
cells: t.CellBuffer,
width: u16,
height: u16,
grapheme_buffer: t.GraphemeBuffer,
grapheme_map: t.GraphemeMap,
grapheme_map_allocator: t.GraphemeMapAllocator,

pub fn init(
    width: u16,
    height: u16,
    options: Options,
) error{ OutOfMemory, ReserveFailed }!FrameBuffer {
    assert(@as(usize, width) * @as(usize, height) <= options.max_cells);
    assert(options.grapheme_buffer.initial <= options.grapheme_buffer.max);
    assert(options.grapheme_map_backing_memory.initial <= options.grapheme_map_backing_memory.max);

    var buffer: FrameBuffer = undefined;
    buffer.width = width;
    buffer.height = height;
    buffer.cells = try t.CellBuffer.initCapacity(options.max_cells, width * height);
    buffer.grapheme_buffer = try t.GraphemeBuffer.initCapacity(options.grapheme_buffer.max, options.grapheme_buffer.initial);
    buffer.grapheme_map_allocator = try t.GraphemeMapAllocator.initCapacity(
        options.grapheme_map_backing_memory.max,
        options.grapheme_map_backing_memory.initial,
    );
    buffer.grapheme_map = .empty;
    try buffer.grapheme_map.ensureTotalCapacity(buffer.grapheme_map_allocator.allocator(), @intCast(options.grapheme_map_initial_size));
    return buffer;
}

pub fn deinit(self: *FrameBuffer) void {
    self.cells.deinit();
    self.grapheme_buffer.deinit();
    self.grapheme_map_allocator.deinit();
}

pub fn clear(self: *FrameBuffer) void {
    const num_cells = @as(usize, self.width) * @as(usize, self.height);
    @memset(self.cells.reserved_pages[0..num_cells], .empty);
    self.grapheme_buffer.reset();
    self.grapheme_map.clearRetainingCapacity();
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

pub fn putGrapheme(self: *FrameBuffer, x: u16, y: u16, grapheme: []const u8) error{OutOfMemory}!void {
    const pos = t.Position{ .x = x, .y = y };
    const id = try self.grapheme_buffer.put(grapheme);
    try self.grapheme_map.put(self.grapheme_map_allocator.allocator(), pos, id);
}

pub inline fn set(self: *FrameBuffer, x: u16, y: u16, cell: Cell) void {
    assert(x < self.width);
    assert(y < self.height);
    const index: usize = @as(usize, y) * @as(usize, self.width) + @as(usize, x);
    self.cells.reserved_pages[index] = cell;
}

pub inline fn get(self: FrameBuffer, x: u16, y: u16) Cell {
    assert(x < self.width);
    assert(y < self.height);
    const index: usize = @as(usize, y) * @as(usize, self.width) + @as(usize, x);
    return self.cells.reserved_pages[index];
}

pub fn getGrapheme(self: *const FrameBuffer, x: u16, y: u16) ?[]const u8 {
    const pos = t.Position{ .x = x, .y = y };
    const grapheme_id = self.grapheme_map.get(pos) orelse return null;
    return self.grapheme_buffer.get(grapheme_id);
}

pub inline fn renderCell(frame_buffer: *const FrameBuffer, row: usize, col: usize, writer: *std.Io.Writer) error{WriteFailed}!u3 {
    const cell = frame_buffer.cells.reserved_pages[row * frame_buffer.width + col];
    var result: u3 = 1;
    switch (cell.width) {
        .wide_start => {
            result = 2;
        },
        .wide_end => return result,
        else => {},
    }
    switch (cell.tag) {
        .codepoint => {
            var bytes: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cell.codepoint, &bytes) catch {
                @branchHint(.cold);
                try writer.writeAll("\xEF\xBF\xBD"); // U+FFFD
                return result;
            };
            try writer.writeAll(bytes[0..len]);
        },
        .grapheme => {
            const bytes = frame_buffer.getGrapheme(@intCast(col), @intCast(row)) orelse {
                @branchHint(.cold);
                // This should never happen?
                try writer.writeAll("\xEF\xBF\xBD"); // U+FFFD
                return result;
            };
            try writer.writeAll(bytes);
        },
    }
    return result;
}

pub fn fullRedraw(self: *const FrameBuffer, writer: *std.Io.Writer) error{WriteFailed}!void {
    for (0..self.height) |row| {
        try writer.print("\x1b[{d};{d}H", .{ row + 1, 1 });
        var col: u16 = 0;
        while (col < self.width) {
            col += try self.renderCell(row, col, writer);
        }
    }
}

pub inline fn isDiff(self: *const FrameBuffer, back_bufer: *const FrameBuffer, row: usize, col: usize) bool {
    assert(self.width == back_bufer.width);
    assert(self.height == back_bufer.height);
    const old_cell = back_bufer.cells.reserved_pages[row * self.width + col];
    const new_cell = self.cells.reserved_pages[row * self.width + col];
    if (!new_cell.eql(old_cell)) {
        return true;
    } else if (old_cell.tag == .grapheme) {
        const old_grapheme = back_bufer.getGrapheme(@intCast(col), @intCast(row)) orelse return true;
        const new_grapheme = self.getGrapheme(@intCast(col), @intCast(row)) orelse return false;
        return !std.mem.eql(u8, old_grapheme, new_grapheme);
    } else {
        return false;
    }
}

pub fn diffRedraw(self: *const FrameBuffer, back_buffer: *const FrameBuffer, writer: *std.Io.Writer) error{WriteFailed}!void {
    assert(back_buffer.width == self.width);
    assert(back_buffer.height == self.height);

    const height: usize = back_buffer.height;
    const width: usize = back_buffer.width;

    for (0..height) |row| {
        const row_start: usize = row * width;
        const row_end: usize = row_start + width;
        var col: usize = 0;
        while (col < width) {
            var start: usize = row_start + col;
            while (start < row_end and !self.isDiff(back_buffer, row, start - row_start)) {
                if (back_buffer.cells.reserved_pages[start].width == .wide_start) {
                    assert(start < row_end - 1);
                    start += 2;
                } else {
                    start += 1;
                }
            }
            var end: usize = start;

            while (end < row_end and self.isDiff(back_buffer, row, end - row_start)) {
                if (back_buffer.cells.reserved_pages[start].width == .wide_start or self.cells.reserved_pages[start].width == .wide_start) {
                    assert(end < row_end - 1);
                    end += 2;
                } else {
                    end += 1;
                }
            }
            if (start >= row_end) break;
            try writer.print("\x1b[{d};{d}H", .{ row + 1, start - row_start + 1 });
            while (start < end) {
                start += try self.renderCell(row, start - row_start, writer);
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
    var front = try FrameBuffer.init(4, 1, Options.tiny_buffer);
    defer front.deinit();

    front.set(0, 0, .{ .codepoint = 'A' });
    front.set(1, 0, .{ .codepoint = 0x00E9 });
    front.set(2, 0, .{ .codepoint = 0x4E2D });
    front.set(3, 0, .{ .codepoint = 0x1D11E });

    var output_buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    try front.fullRedraw(&writer);
    const output = writer.buffered();

    const expected = "\x1b[1;1HA\xC3\xA9\xE4\xB8\xAD\xF0\x9D\x84\x9E";
    try expectEqualSequences(expected, output);
}

test "fullRedraw wide characters" {
    var front = try FrameBuffer.init(6, 1, Options.tiny_buffer);
    defer front.deinit();

    front.set(0, 0, .{ .codepoint = 'A' });
    // 中 (U+4E2D)
    front.set(1, 0, .{ .codepoint = 0x4E2D, .width = .wide_start });
    front.set(2, 0, .{ .codepoint = ' ', .width = .wide_end });
    front.set(3, 0, .{ .codepoint = 'B' });
    //  国 (U+56FD)
    front.set(4, 0, .{ .codepoint = 0x56FD, .width = .wide_start });
    front.set(5, 0, .{ .codepoint = ' ', .width = .wide_end });

    var output_buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    try front.fullRedraw(&writer);
    const output = writer.buffered();

    const expected = "\x1b[1;1HA\xE4\xB8\xADB\xE5\x9B\xBD";
    try expectEqualSequences(expected, output);
}

test "fullRedraw graphemes - wide and graphemes" {
    var front = try FrameBuffer.init(4, 2, Options.tiny_buffer);
    defer front.deinit();

    front.clear();

    front.set(0, 0, .{ .codepoint = 'A' });
    // 👍 (U+1F44D)
    const thumbs_up = "\xF0\x9F\x91\x8D";
    front.set(1, 0, .{ .codepoint = '👍', .tag = .codepoint, .width = .wide_start });
    front.set(2, 0, .{ .width = .wide_end });
    const e_acute_combining = "e\xCC\x81";
    front.set(3, 0, .{ .codepoint = 'e', .tag = .grapheme, .width = .narrow });
    try front.putGrapheme(3, 0, e_acute_combining);
    // 👨‍👩‍👧 (family emoji) - ZWJ sequence
    const family = "\xF0\x9F\x91\xA8\xE2\x80\x8D\xF0\x9F\x91\xA9\xE2\x80\x8D\xF0\x9F\x91\xA7";
    front.set(1, 1, .{ .codepoint = '👨', .tag = .grapheme, .width = .wide_start });
    front.set(2, 1, .{ .codepoint = ' ', .tag = .codepoint, .width = .wide_end });
    try front.putGrapheme(1, 1, family);

    var output_buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    try front.fullRedraw(&writer);
    const output = writer.buffered();

    const expected = "\x1b[1;1HA" ++ thumbs_up ++ e_acute_combining ++ "\x1b[2;1H " ++ family ++ " ";
    try expectEqualSequences(expected, output);
}

test "fullRedraw error handling - invalid codepoint" {
    var front = try FrameBuffer.init(3, 1, Options.tiny_buffer);
    defer front.deinit();

    front.set(0, 0, .{ .codepoint = 'A' });
    // Invalid codepoint (surrogate range U+D800-U+DFFF)
    front.set(1, 0, .{ .codepoint = 0xD800 });
    front.set(2, 0, .{ .codepoint = 'B' });

    var output_buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    try front.fullRedraw(&writer);
    const output = writer.buffered();

    // Invalid codepoints should render as U+FFFD (\xEF\xBF\xBD)
    const expected = "\x1b[1;1HA\xEF\xBF\xBDB";
    try expectEqualSequences(expected, output);
}

test "fullRedraw error handling - missing grapheme" {
    var front = try FrameBuffer.init(3, 1, Options.tiny_buffer);
    defer front.deinit();

    front.set(0, 0, .{ .codepoint = 'A' });
    // Mark cell as grapheme but don't put any grapheme data
    front.set(1, 0, .{ .tag = .grapheme });
    front.set(2, 0, .{ .codepoint = 'B' });

    var output_buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    try front.fullRedraw(&writer);
    const output = writer.buffered();

    // Missing grapheme should render as U+FFFD (\xEF\xBF\xBD)
    const expected = "\x1b[1;1HA\xEF\xBF\xBDB";
    try expectEqualSequences(expected, output);
}

test "diffRedraw no changes" {
    var front = try FrameBuffer.init(5, 2, Options.tiny_buffer);
    defer front.deinit();
    var back = try FrameBuffer.init(5, 2, Options.tiny_buffer);
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
    var front = try FrameBuffer.init(5, 2, Options.tiny_buffer);
    defer front.deinit();
    var back = try FrameBuffer.init(5, 2, Options.tiny_buffer);
    defer back.deinit();

    back.clear();

    // Back buffer has spaces, front buffer has all 'X'
    for (0..5) |x| {
        for (0..2) |y| {
            front.set(@intCast(x), @intCast(y), .{ .codepoint = 'X' });
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
    var front = try FrameBuffer.init(10, 1, Options.tiny_buffer);
    defer front.deinit();
    var back = try FrameBuffer.init(10, 1, Options.tiny_buffer);
    defer back.deinit();

    front.clear();
    back.clear();

    front.set(2, 0, .{ .codepoint = 'A' });
    front.set(3, 0, .{ .codepoint = 'B' });
    front.set(7, 0, .{ .codepoint = 'C' });
    front.set(8, 0, .{ .codepoint = 'D' });

    var output_buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    try front.diffRedraw(&back, &writer);
    const output = writer.buffered();

    const expected = "\x1b[1;3HAB\x1b[1;8HCD";
    try expectEqualSequences(expected, output);
}

test "diffRedraw changes in multiple rows" {
    var front = try FrameBuffer.init(5, 3, Options.tiny_buffer);
    defer front.deinit();
    var back = try FrameBuffer.init(5, 3, Options.tiny_buffer);
    defer back.deinit();

    front.clear();
    back.clear();

    // Change one cell in each row
    front.set(1, 0, .{ .codepoint = 'A' });
    front.set(2, 1, .{ .codepoint = 'B' });
    front.set(3, 2, .{ .codepoint = 'C' });

    var output_buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    try front.diffRedraw(&back, &writer);
    const output = writer.buffered();

    // Each row has a change plus an end-of-row cursor position
    const expected = "\x1b[1;2HA\x1b[2;3HB\x1b[3;4HC";
    try expectEqualSequences(expected, output);
}

test "diffRedraw grapheme same in both buffers" {
    var front = try FrameBuffer.init(3, 1, Options.tiny_buffer);
    defer front.deinit();
    var back = try FrameBuffer.init(3, 1, Options.tiny_buffer);
    defer back.deinit();

    front.clear();
    back.clear();

    const emoji = "\xF0\x9F\x91\xA8\xE2\x80\x8D\xF0\x9F\x91\xA9\xE2\x80\x8D\xF0\x9F\x91\xA7"; // 👨‍👩‍👧

    front.set(1, 0, .{ .tag = .grapheme, .width = .wide_start });
    front.set(2, 0, .{ .width = .wide_end });
    try front.putGrapheme(1, 0, emoji);
    back.set(1, 0, .{ .tag = .grapheme, .width = .wide_start });
    back.set(2, 0, .{ .width = .wide_end });
    try back.putGrapheme(1, 0, emoji);

    var output_buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    try front.diffRedraw(&back, &writer);
    const output = writer.buffered();

    const expected = "";
    try expectEqualSequences(expected, output);
}

test "diffRedraw grapheme changed" {
    var front = try FrameBuffer.init(3, 1, Options.tiny_buffer);
    defer front.deinit();
    var back = try FrameBuffer.init(3, 1, Options.tiny_buffer);
    defer back.deinit();

    front.clear();
    back.clear();

    // Not technically a grapheme but whose gonna stop me
    const emoji1 = "\xF0\x9F\x91\x8D"; // 👍
    const emoji2 = "\xF0\x9F\x91\x8E"; // 👎

    front.set(1, 0, .{ .tag = .grapheme, .width = .wide_start });
    front.set(2, 0, .{ .width = .wide_end });
    try front.putGrapheme(1, 0, emoji2);
    back.set(1, 0, .{ .tag = .grapheme, .width = .wide_start });
    back.set(2, 0, .{ .width = .wide_end });
    try back.putGrapheme(1, 0, emoji1);

    var output_buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    try front.diffRedraw(&back, &writer);
    const output = writer.buffered();

    const expected = "\x1b[1;2H" ++ emoji2;
    try expectEqualSequences(expected, output);
}

test "diffRedraw grapheme vs codepoint" {
    var front = try FrameBuffer.init(3, 1, Options.tiny_buffer);
    defer front.deinit();
    var back = try FrameBuffer.init(3, 1, Options.tiny_buffer);
    defer back.deinit();

    front.clear();
    back.clear();

    const emoji = "\xF0\x9F\x91\x8D"; // 👍
    back.set(1, 0, .{ .tag = .grapheme, .width = .wide_start });
    back.set(2, 0, .{ .width = .wide_end });
    try front.putGrapheme(1, 0, emoji);
    front.set(1, 0, .{ .codepoint = 'X' });

    var output_buffer: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    try front.diffRedraw(&back, &writer);
    const output = writer.buffered();

    const expected = "\x1b[1;2HX ";
    try expectEqualSequences(expected, output);
}

test "renderCell basic codepoint" {
    var front = try FrameBuffer.init(4, 1, Options.tiny_buffer);
    defer front.deinit();

    front.set(0, 0, .{ .codepoint = 'A' });
    front.set(1, 0, .{ .codepoint = 0x4E2D, .width = .wide_start }); // 中
    front.set(2, 0, .{ .width = .wide_end });
    front.set(3, 0, .{ .codepoint = 'B' });

    var output_buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_buffer);

    const advance0 = try front.renderCell(0, 0, &writer);
    try std.testing.expectEqual(@as(u3, 1), advance0);

    const advance1 = try front.renderCell(0, 1, &writer);
    try std.testing.expectEqual(@as(u3, 2), advance1);

    const advace_wide_end = try front.renderCell(0, 2, &writer);
    try std.testing.expectEqual(@as(u3, 1), advace_wide_end);

    const advance2 = try front.renderCell(0, 3, &writer);
    try std.testing.expectEqual(@as(u3, 1), advance2);

    const output = writer.buffered();
    try expectEqualSequences("A\xE4\xB8\xADB", output);
}
