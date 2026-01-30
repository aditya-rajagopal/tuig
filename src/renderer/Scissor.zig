const std = @import("std");

const stdx = @import("stdx");
const assert = stdx.inlineAssert;

const FrameBuffer = @import("FrameBuffer.zig");
const Cell = @import("root.zig").Cell;
const GraphemeIterator = @import("unicode").GraphemeIterator;
const Context = @import("Context.zig");
const t = @import("types.zig");
const Position = t.Position;
const UTF8Decoder = @import("unicode").UTF8Decoder;
const getProperty = @import("unicode").getProperty;

pub const Scissor = @This();

x_global: i17,
y_global: i17,
width_global: u16,
height_global: u16,
buffer: *FrameBuffer,

pub fn initChild(self: Scissor, x_offset: i17, y_offset: i17, width: u16, height: u16) Scissor {
    return Scissor{
        .x_global = self.x_global + x_offset,
        .y_global = self.y_global + y_offset,
        .width_global = width,
        .height_global = height,
        .buffer = self.buffer,
    };
}

pub fn inner(self: Scissor) Scissor {
    assert(self.width_global > 2);
    assert(self.height_global > 2);
    return Scissor{
        .x_global = self.x_global + 1,
        .y_global = self.y_global + 1,
        .width_global = self.width_global - 2,
        .height_global = self.height_global - 2,
        .buffer = self.buffer,
    };
}

pub fn get(self: Scissor, x: u16, y: u16) ?Cell {
    if (x >= self.width_global or y >= self.height_global) return null;
    const global_x: i17 = self.x_global + x;
    const global_y: i17 = self.y_global + y;
    if (global_x < 0 or global_y < 0) return null;
    if (global_x >= self.buffer.width or global_y >= self.buffer.height) return null;

    return self.buffer.get(@intCast(global_x), @intCast(global_y));
}

pub fn set(self: Scissor, x: u16, y: u16, cell: Cell) void {
    if (x >= self.width_global or y >= self.height_global) return;
    const global_x: i17 = self.x_global + x;
    const global_y: i17 = self.y_global + y;
    if (global_x < 0 or global_y < 0) return;
    if (global_x >= self.buffer.width or global_y >= self.buffer.height) return;

    self.buffer.set(@intCast(global_x), @intCast(global_y), cell);
}

pub fn contains(self: Scissor, x: u16, y: u16) bool {
    return x >= self.x_global and y >= self.y_global and x < self.x_global + self.width_global and y < self.y_global + self.height_global;
}

pub fn fillRow(self: Scissor, row: u16, cell: Cell) void {
    if (row >= self.height_global) return;

    const x_start_int = self.x_global;
    const x_end_int = x_start_int + self.width_global;
    const y_int = self.y_global + row;

    if (y_int >= self.buffer.height or y_int < 0) return;
    if (x_end_int < 0 or x_start_int >= self.buffer.width) return;

    const x_start: usize = @intCast(std.math.clamp(x_start_int, 0, self.buffer.width - 1));
    const x_end: usize = @intCast(std.math.clamp(x_end_int, 0, self.buffer.width));
    const y: usize = @intCast(y_int);

    const start: usize = y * self.buffer.width + x_start;
    const end: usize = y * self.buffer.width + x_end;
    @memset(self.buffer.cells.reserved_pages[start..end], cell);
}

pub fn fillColumn(self: Scissor, column: u16, cell: Cell) void {
    if (column >= self.width_global) return;
    const x_int = self.x_global + column;
    const y_start_int = self.y_global;
    const y_end_int = self.y_global + self.height_global;
    if (x_int >= self.buffer.width or x_int < 0) return;
    if (y_end_int < 0 or y_start_int >= self.buffer.height) return;

    const y_start: usize = @intCast(std.math.clamp(y_start_int, 0, self.buffer.height - 1));
    const y_end: usize = @intCast(std.math.clamp(y_end_int, 0, self.buffer.height));
    const x: usize = @intCast(x_int);

    for (y_start..y_end) |row| {
        @call(.always_inline, FrameBuffer.set, .{ self.buffer, @as(u16, @intCast(x)), @as(u16, @intCast(row)), cell.codepoint });
    }
}

pub fn fillRectangle(self: Scissor, x_offset: u16, y_offset: u16, width: u16, height: u16, cell: Cell) void {
    if (x_offset >= self.width_global or y_offset >= self.height_global) return;
    if (width == 0 or height == 0) return;

    const start_x_int: i17 = self.x_global + x_offset;
    const end_x_int: i17 = start_x_int + width;
    const start_y_int: i17 = self.y_global + y_offset;
    const end_y_int: i17 = start_y_int + height;

    if (start_x_int >= self.buffer.width) return;
    if (start_y_int >= self.buffer.height) return;
    if (end_x_int < 0) return;
    if (end_y_int < 0) return;

    const start_x: usize = @intCast(std.math.clamp(start_x_int, 0, self.buffer.width - 1));
    const end_x: usize = @intCast(std.math.clamp(end_x_int, 0, self.buffer.width));
    const start_y: usize = @intCast(std.math.clamp(start_y_int, 0, self.buffer.height - 1));
    const end_y: usize = @intCast(std.math.clamp(end_y_int, 0, self.buffer.height));

    if (start_x_int == 0 and end_x_int == self.buffer.width) {
        const start = start_y * self.buffer.width;
        const end = end_y * self.buffer.width;
        @memset(self.buffer.cells[start..end], cell);
    } else {
        for (start_y..end_y) |row| {
            const start = row * self.buffer.width;
            @memset(self.buffer.cells[start..][start_x..end_x], cell);
        }
    }
}

pub fn fill(self: Scissor, cell: Cell) void {
    self.fillRectangle(0, 0, self.width_global, self.height_global, cell);
}

pub fn clear(self: Scissor) void {
    self.fill(.empty);
}

/// Statistics returned after rendering text.
pub const PrintResult = struct {
    /// Total UTF-8 bytes processed from input
    bytes_consumed: usize,
    /// Number of lines used (including wraps and newlines)
    /// Minimum 1 if any content rendered, 0 if nothing rendered
    lines_used: u16,
    /// Final cursor X position relative to scissor (may be >= width if ended at edge)
    final_x: u16,
    /// Final cursor Y position relative to scissor
    final_y: u16,
    /// Number of grapheme clusters actually rendered to buffer
    graphemes_rendered: usize,
};

/// Configuration options for print behavior.
pub const PrintOptions = struct {
    /// Enable text wrapping at scissor's right edge
    /// When false: text truncates at right edge
    wrap: bool,
    /// Number of spaces per tab character
    /// Tab stop: advance to next multiple of tab_width
    tab_width: u8,

    pub const default: PrintOptions = .{
        .wrap = false,
        .tab_width = 4,
    };
};

pub const PrintError = error{OutOfMemory};

pub fn print(
    self: Scissor,
    codepoint_buffer: []u21,
    text: []const u8,
    x: u16,
    y: u16,
    options: PrintOptions,
) PrintError!PrintResult {
    var result = PrintResult{
        .bytes_consumed = 0,
        .lines_used = 0,
        .final_x = x,
        .final_y = y,
        .graphemes_rendered = 0,
    };

    const left_bound: i17 = @max(self.x_global, 0);
    const right_bound: i17 = @min(self.x_global + self.width_global, @as(i17, self.buffer.width));
    const top_bound: i17 = @max(self.y_global, 0);
    const bottom_bound: i17 = @min(self.y_global + self.height_global, @as(i17, self.buffer.height));
    if (right_bound <= left_bound or bottom_bound <= top_bound or right_bound <= 0 or bottom_bound <= 0) {
        // Scissor is outside of buffer bounds
        return result;
    }

    var cursor_x: u16 = x;
    var cursor_y: u16 = y;

    var iter = GraphemeIterator.init(text) catch return result; // Empty input, return zeros

    while (iter.next(codepoint_buffer)) |grapheme_result| : (cursor_x += grapheme_result.width) {
        result.bytes_consumed += grapheme_result.bytes.len;
        if (cursor_x >= self.width_global) {
            if (options.wrap) {
                // Wrap to next line before rendering the wide char
                cursor_x = 0;
                cursor_y += 1;
                result.lines_used += 1;
            } else {
                // No wrap: stop rendering
                break;
            }
        }

        const codepoint = grapheme_result.grapheme[0];

        switch (codepoint) {
            '\n' => {
                cursor_x = 0;
                cursor_y += 1;
                result.lines_used += 1;
                continue;
            },
            '\r' => {
                if (grapheme_result.grapheme.len == 2 and grapheme_result.grapheme[1] == '\n') {
                    cursor_x = 0;
                    cursor_y += 1;
                    result.lines_used += 1;
                    continue;
                } else {
                    // Ignore \r (carriage return)
                    continue;
                }
            },
            '\t' => {
                var spaces_to_tab: u8 = if (options.tab_width == 0)
                    continue
                else
                    options.tab_width - @as(u8, @intCast(@mod(cursor_x, options.tab_width)));

                const y_global: i17 = self.y_global + cursor_y;

                if (y_global >= bottom_bound) {
                    break;
                }
                const remaining_columns = self.width_global - cursor_x;
                spaces_to_tab = @min(remaining_columns, spaces_to_tab);

                for (0..spaces_to_tab) |_| {
                    const x_global: i17 = self.x_global + @as(i17, cursor_x);

                    if (x_global >= left_bound and x_global < right_bound and
                        y_global >= top_bound and y_global < bottom_bound)
                    {
                        self.buffer.set(@intCast(x_global), @intCast(y_global), .empty);
                        result.graphemes_rendered += 1;
                    }
                    cursor_x += 1;
                }
                continue;
            },
            else => {
                @branchHint(.likely);
            },
        }

        if (grapheme_result.width == 0) {
            continue;
        } else if (grapheme_result.width == 2 and self.width_global - cursor_x == 1) {
            @branchHint(.unlikely);
            if (options.wrap) {
                cursor_x = 0;
                cursor_y += 1;
                result.lines_used += 1;
            } else {
                // ignore the wide character.
                continue;
            }
        }

        const x_global: i17 = self.x_global + cursor_x;
        const y_global: i17 = self.y_global + cursor_y;

        if (x_global < left_bound or x_global >= right_bound or y_global < top_bound) {
            @branchHint(.unlikely);
            continue;
        }
        if (y_global >= bottom_bound) {
            @branchHint(.unlikely);
            break;
        }

        const cell: Cell = if (grapheme_result.grapheme.len > 1) blk: {
            @branchHint(.unlikely);
            const id = try self.buffer.grapheme_buffer.put(grapheme_result.bytes);
            break :blk Cell.initGrapheme(id, if (grapheme_result.width == 2) .wide_start else .narrow);
        } else .{
            .data = .{ .codepoint = codepoint },
            .tag = .codepoint,
            .width = if (grapheme_result.width == 2) .wide_start else .narrow,
        };

        self.buffer.set(@intCast(x_global), @intCast(y_global), cell);

        if (grapheme_result.width == 2) {
            const second_x: i17 = x_global + 1;
            assert(second_x < right_bound);
            self.buffer.set(@intCast(second_x), @intCast(y_global), .wide_end);
        }

        result.graphemes_rendered += 1;
    }

    // Finalize result
    if (cursor_x >= self.width_global) {
        cursor_x = 0;
        cursor_y += 1;
    }
    result.final_x = cursor_x;
    result.final_y = cursor_y;
    // lines_used tracks wraps during the loop; add 1 for the initial line if we rendered anything
    if (result.graphemes_rendered > 0) {
        result.lines_used += 1;
        const y_global: i17 = self.y_global + cursor_y;
        if (y_global >= bottom_bound) {
            result.lines_used -= 1;
        }
    }

    return result;
}

/// IMPORTANT: Caller guarantees text contains only single-codepoint characters.
/// Multi-codepoint graphemes (combining marks, emoji sequences, ZWJ) will render
/// incorrectly - use `Scissor.print()` for arbitrary Unicode text.
///
/// This is usually about 2x faster than `Scissor.print()` for simple text.
pub fn printAssumeNoGrapheme(
    self: Scissor,
    text: []const u8,
    x: u16,
    y: u16,
    options: PrintOptions,
) PrintResult {
    var result = PrintResult{
        .bytes_consumed = 0,
        .lines_used = 0,
        .final_x = x,
        .final_y = y,
        .graphemes_rendered = 0,
    };

    const left_bound: i17 = @max(self.x_global, 0);
    const right_bound: i17 = @min(self.x_global + self.width_global, @as(i17, self.buffer.width));
    const top_bound: i17 = @max(self.y_global, 0);
    const bottom_bound: i17 = @min(self.y_global + self.height_global, @as(i17, self.buffer.height));
    if (right_bound <= left_bound or bottom_bound <= top_bound or right_bound <= 0 or bottom_bound <= 0) {
        // Scissor is outside of buffer bounds
        return result;
    }

    var cursor_x: u16 = x;
    var cursor_y: u16 = y;

    var utf8: UTF8Decoder = .start;
    var i: usize = 0;

    while (i < text.len) {
        const codepoint_opt, const consumed = utf8.decode(text[i]);

        // Handle invalid UTF-8
        const codepoint = if (!consumed) blk: {
            @branchHint(.unlikely);
            assert(codepoint_opt != null and codepoint_opt.? == 0xFFFD);
            // Don't increment bytes_consumed here - the byte wasn't consumed.
            // The replacement character is for the incomplete sequence, and
            // this byte will be re-processed as the start of a new sequence.
            break :blk @as(u21, 0xFFFD);
        } else blk: {
            i += 1;
            result.bytes_consumed += 1;
            if (codepoint_opt) |cp| {
                break :blk cp;
            } else {
                continue;
            }
        };

        if (cursor_x >= self.width_global) {
            if (options.wrap) {
                // Wrap to next line before rendering the wide char
                cursor_x = 0;
                cursor_y += 1;
                result.lines_used += 1;
            } else {
                // No wrap: stop rendering
                break;
            }
        }

        switch (codepoint) {
            '\n' => {
                cursor_x = 0;
                cursor_y += 1;
                result.lines_used += 1;
                continue;
            },
            '\t' => {
                var spaces_to_tab: u8 = if (options.tab_width == 0)
                    continue
                else
                    options.tab_width - @as(u8, @intCast(@mod(cursor_x, options.tab_width)));

                const y_global: i17 = self.y_global + cursor_y;

                if (y_global >= bottom_bound) {
                    break;
                }
                const remaining_columns = self.width_global - cursor_x;
                spaces_to_tab = @min(remaining_columns, spaces_to_tab);

                for (0..spaces_to_tab) |_| {
                    const x_global: i17 = self.x_global + @as(i17, cursor_x);

                    if (x_global >= left_bound and x_global < right_bound and
                        y_global >= top_bound and y_global < bottom_bound)
                    {
                        self.buffer.set(@intCast(x_global), @intCast(y_global), .empty);
                        result.graphemes_rendered += 1;
                    }
                    cursor_x += 1;
                }
                continue;
            },
            0x00...0x08, // Except \t
            0x0B...0x0C,
            0x0E...0x1F, // C0 except LF (0x0A)
            0x0D, // CR
            0x7F, // DEL
            0x80...0x9F, // C1
            => {
                continue;
            },
            else => {
                @branchHint(.likely);
            },
        }

        // Most commanly you will have ascii text that is 1 cell wide.
        const width = if (codepoint <= 0x7F) 1 else getProperty(codepoint).width;

        if (width == 0) {
            continue;
        } else if (width == 2 and self.width_global - cursor_x == 1) {
            @branchHint(.unlikely);
            if (options.wrap) {
                cursor_x = 0;
                cursor_y += 1;
                result.lines_used += 1;
            } else {
                // ignore the wide character.
                cursor_x += width;
                continue;
            }
        }

        const x_global: i17 = self.x_global + cursor_x;
        const y_global: i17 = self.y_global + cursor_y;

        if (x_global < left_bound or x_global >= right_bound or y_global < top_bound) {
            @branchHint(.unlikely);
            cursor_x += width;
            continue;
        }
        if (y_global >= bottom_bound) {
            @branchHint(.unlikely);
            break;
        }

        const cell = Cell{
            .data = .{ .codepoint = codepoint },
            .tag = .codepoint,
            .width = if (width == 2) .wide_start else .narrow,
        };

        self.buffer.set(@intCast(x_global), @intCast(y_global), cell);

        if (width == 2) {
            const second_x: i17 = x_global + 1;
            assert(second_x < right_bound);
            self.buffer.set(@intCast(second_x), @intCast(y_global), .wide_end);
        }

        result.graphemes_rendered += 1;
        cursor_x += width;
    }

    // Finalize result
    if (cursor_x >= self.width_global) {
        cursor_x = 0;
        cursor_y += 1;
    }
    result.final_x = cursor_x;
    result.final_y = cursor_y;
    result.bytes_consumed = i;
    // lines_used tracks wraps during the loop; add 1 for the initial line if we rendered anything
    if (result.graphemes_rendered > 0) {
        result.lines_used += 1;
        const y_global: i17 = self.y_global + cursor_y;
        if (y_global >= bottom_bound) {
            result.lines_used -= 1;
        }
    }

    return result;
}

const testing = std.testing;

const TestContext = struct {
    buffer: FrameBuffer,
    cells: []Cell,

    var test_codepoint_buffer: [64]u21 = undefined;

    fn init(width: u16, height: u16) !TestContext {
        const cells = try testing.allocator.alloc(Cell, @as(usize, width) * @as(usize, height));
        var buffer = try FrameBuffer.init(cells, width, height, .tiny);
        buffer.clear();
        return .{ .buffer = buffer, .cells = cells };
    }

    fn deinit(self: *TestContext) void {
        self.buffer.deinit();
        testing.allocator.free(self.cells);
    }

    fn scissor(self: *TestContext) Scissor {
        return self.buffer.scissor();
    }

    fn expectCodepointAt(self: *TestContext, x: u16, y: u16, expected_cp: u21) !void {
        const cell = self.buffer.get(x, y);
        try testing.expectEqual(expected_cp, cell.data.codepoint);
    }

    fn expectCellWidth(self: *TestContext, x: u16, y: u16, expected_width: Cell.Width) !void {
        const cell = self.buffer.get(x, y);
        try testing.expectEqual(expected_width, cell.width);
    }

    fn expectCellTag(self: *TestContext, x: u16, y: u16, expected_tag: Cell.Tag) !void {
        const cell = self.buffer.get(x, y);
        try testing.expectEqual(expected_tag, cell.tag);
    }

    fn getGraphemeAt(self: *TestContext, x: u16, y: u16) ?[]const u8 {
        const cell = self.buffer.get(x, y);
        if (cell.tag != .grapheme) return null;
        const id: t.GraphemeBuffer.GraphemeIndex = @truncate(@as(u64, @bitCast(cell)));
        return self.buffer.grapheme_buffer.get(id);
    }
};

test "Scissor.initChild creates correct child region" {
    const cells = try testing.allocator.alloc(Cell, 200);
    defer testing.allocator.free(cells);
    var fb = try FrameBuffer.init(cells, 20, 10, .tiny);
    defer fb.deinit();

    const parent = Scissor{
        .x_global = 5,
        .y_global = 3,
        .width_global = 15,
        .height_global = 7,
        .buffer = &fb,
    };

    const child = parent.initChild(2, 1, 10, 4);

    try std.testing.expectEqual(@as(i17, 7), child.x_global);
    try std.testing.expectEqual(@as(i17, 4), child.y_global);
    try std.testing.expectEqual(@as(u16, 10), child.width_global);
    try std.testing.expectEqual(@as(u16, 4), child.height_global);
    try std.testing.expect(child.buffer == &fb);
}

test "Scissor.fillRectangle clips to buffer bounds" {
    const cells = try testing.allocator.alloc(Cell, 50);
    defer testing.allocator.free(cells);
    var fb = try FrameBuffer.init(cells, 10, 5, .tiny);
    defer fb.deinit();

    fb.clear();

    const scissor = Scissor{
        .x_global = 0,
        .y_global = 0,
        .width_global = 10,
        .height_global = 5,
        .buffer = &fb,
    };

    // Rectangle extends beyond buffer
    scissor.fillRectangle(8, 3, 5, 5, Cell{ .data = .{ .codepoint = '+' } });

    // Should only fill positions within buffer: x=8-9, y=3-4
    for (0..5) |y| {
        for (0..10) |x| {
            const expected: u21 = if (x >= 8 and y >= 3) '+' else ' ';
            try std.testing.expectEqual(expected, fb.cells[y * 10 + x].data.codepoint);
        }
    }
}

test "print basic ASCII" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "Hello", 0, 0, .default);

    try testing.expectEqual(@as(usize, 5), result.bytes_consumed);
    try testing.expectEqual(@as(u16, 1), result.lines_used);
    try testing.expectEqual(@as(u16, 5), result.final_x);
    try testing.expectEqual(@as(u16, 0), result.final_y);
    try testing.expectEqual(@as(usize, 5), result.graphemes_rendered);

    try tc.expectCodepointAt(0, 0, 'H');
    try tc.expectCodepointAt(1, 0, 'e');
    try tc.expectCodepointAt(2, 0, 'l');
    try tc.expectCodepointAt(3, 0, 'l');
    try tc.expectCodepointAt(4, 0, 'o');

    // All should be narrow width
    try tc.expectCellWidth(0, 0, .narrow);
    try tc.expectCellWidth(4, 0, .narrow);
}

test "print ASCII with offset" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "Hi", 3, 2, .default);

    try testing.expectEqual(@as(usize, 2), result.bytes_consumed);
    try testing.expectEqual(@as(u16, 5), result.final_x);
    try testing.expectEqual(@as(u16, 2), result.final_y);

    // Cells at offset should be set
    try tc.expectCodepointAt(3, 2, 'H');
    try tc.expectCodepointAt(4, 2, 'i');

    // Original cells should still be space
    try tc.expectCodepointAt(0, 0, ' ');
    try tc.expectCodepointAt(2, 2, ' ');
}

test "print ASCII truncates at right edge" {
    var tc = try TestContext.init(5, 5);
    defer tc.deinit();

    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "Hello World", 0, 0, .default);

    // Should only render "Hello" (5 chars)
    try testing.expectEqual(@as(usize, 5), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 1), result.lines_used);

    try tc.expectCodepointAt(0, 0, 'H');
    try tc.expectCodepointAt(1, 0, 'e');
    try tc.expectCodepointAt(2, 0, 'l');
    try tc.expectCodepointAt(3, 0, 'l');
    try tc.expectCodepointAt(4, 0, 'o');
}

test "print empty string" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "", 0, 0, .default);

    try testing.expectEqual(@as(usize, 0), result.bytes_consumed);
    try testing.expectEqual(@as(u16, 0), result.lines_used);
    try testing.expectEqual(@as(usize, 0), result.graphemes_rendered);
}

test "print outside buffer returns early" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    // Start below the buffer
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "Hello", 0, 10, .default);

    try testing.expectEqual(@as(usize, 0), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 0), result.lines_used);
}

test "print starting past right edge" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "Hello", 15, 0, .default);

    try testing.expectEqual(@as(usize, 0), result.graphemes_rendered);
}

test "print wraps at scissor edge" {
    var tc = try TestContext.init(5, 3);
    defer tc.deinit();

    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "ABCDEFGHIJ", 0, 0, .{ .wrap = true, .tab_width = 4 });

    // Row 0: A B C D E
    // Row 1: F G H I J
    try testing.expectEqual(@as(usize, 10), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 2), result.lines_used);
    try testing.expectEqual(@as(u16, 0), result.final_x);
    try testing.expectEqual(@as(u16, 2), result.final_y);

    // Row 0
    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCodepointAt(1, 0, 'B');
    try tc.expectCodepointAt(2, 0, 'C');
    try tc.expectCodepointAt(3, 0, 'D');
    try tc.expectCodepointAt(4, 0, 'E');

    // Row 1
    try tc.expectCodepointAt(0, 1, 'F');
    try tc.expectCodepointAt(1, 1, 'G');
    try tc.expectCodepointAt(2, 1, 'H');
    try tc.expectCodepointAt(3, 1, 'I');
    try tc.expectCodepointAt(4, 1, 'J');
}

test "print stops at bottom with wrap" {
    var tc = try TestContext.init(5, 2);
    defer tc.deinit();

    // 15 chars but only 2 rows available (10 cells max)
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "ABCDEFGHIJKLMNO", 0, 0, .{ .wrap = true, .tab_width = 4 });

    // Should only render 10 chars (2 lines of 5)
    try testing.expectEqual(@as(usize, 10), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 2), result.lines_used);

    // Row 0
    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCodepointAt(4, 0, 'E');

    // Row 1
    try tc.expectCodepointAt(0, 1, 'F');
    try tc.expectCodepointAt(4, 1, 'J');
}

test "print wrap disabled truncates" {
    var tc = try TestContext.init(5, 3);
    defer tc.deinit();

    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "Hello World", 0, 0, .{ .wrap = false, .tab_width = 4 });

    // Should only render "Hello" (5 chars)
    try testing.expectEqual(@as(usize, 5), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 1), result.lines_used);

    try tc.expectCodepointAt(0, 0, 'H');
    try tc.expectCodepointAt(4, 0, 'o');

    // Row 1 should still be empty
    try tc.expectCodepointAt(0, 1, ' ');
}

test "print wrap with offset" {
    var tc = try TestContext.init(5, 3);
    defer tc.deinit();

    // Start at x=3, so first line has 2 chars, then wrap
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "ABCDEFG", 3, 0, .{ .wrap = true, .tab_width = 4 });

    // Row 0: _ _ _ A B
    // Row 1: C D E F G
    try testing.expectEqual(@as(usize, 7), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 2), result.lines_used);
    try testing.expectEqual(@as(u16, 0), result.final_x);
    try testing.expectEqual(@as(u16, 2), result.final_y);

    // Row 0
    try tc.expectCodepointAt(3, 0, 'A');
    try tc.expectCodepointAt(4, 0, 'B');

    // Row 1
    try tc.expectCodepointAt(0, 1, 'C');
    try tc.expectCodepointAt(4, 1, 'G');
}

test "print multiple wraps" {
    var tc = try TestContext.init(3, 5);
    defer tc.deinit();

    // 9 chars, 3 chars per row, should use 3 rows
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "ABCDEFGHI", 0, 0, .{ .wrap = true, .tab_width = 4 });

    try testing.expectEqual(@as(usize, 9), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 3), result.lines_used);
    try testing.expectEqual(@as(u16, 0), result.final_x);
    try testing.expectEqual(@as(u16, 3), result.final_y);

    // Row 0: A B C
    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCodepointAt(2, 0, 'C');

    // Row 1: D E F
    try tc.expectCodepointAt(0, 1, 'D');
    try tc.expectCodepointAt(2, 1, 'F');

    // Row 2: G H I
    try tc.expectCodepointAt(0, 2, 'G');
    try tc.expectCodepointAt(2, 2, 'I');
}

test "print handles newlines" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "AB\nCD", 0, 0, .default);

    // Row 0: A B, Row 1: C D
    try testing.expectEqual(@as(usize, 5), result.bytes_consumed); // "AB\nCD" = 5 bytes
    try testing.expectEqual(@as(u16, 2), result.lines_used);
    try testing.expectEqual(@as(usize, 4), result.graphemes_rendered); // A, B, C, D (newline not rendered)
    try testing.expectEqual(@as(u16, 2), result.final_x);
    try testing.expectEqual(@as(u16, 1), result.final_y);

    // Row 0
    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCodepointAt(1, 0, 'B');

    // Row 1
    try tc.expectCodepointAt(0, 1, 'C');
    try tc.expectCodepointAt(1, 1, 'D');
}

test "print multiple consecutive newlines" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "A\n\n\nB", 0, 0, .default);

    // A on row 0, B on row 3
    try testing.expectEqual(@as(usize, 5), result.bytes_consumed);
    try testing.expectEqual(@as(u16, 4), result.lines_used); // 4 lines: 0, 1, 2, 3
    try testing.expectEqual(@as(usize, 2), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 1), result.final_x);
    try testing.expectEqual(@as(u16, 3), result.final_y);

    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCodepointAt(0, 3, 'B');

    // Rows 1 and 2 should be empty
    try tc.expectCodepointAt(0, 1, ' ');
    try tc.expectCodepointAt(0, 2, ' ');
}

test "print newline at end" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "Hello\n", 0, 0, .default);

    try testing.expectEqual(@as(usize, 6), result.bytes_consumed);
    try testing.expectEqual(@as(u16, 2), result.lines_used);
    try testing.expectEqual(@as(usize, 5), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 0), result.final_x);
    try testing.expectEqual(@as(u16, 1), result.final_y);

    try tc.expectCodepointAt(0, 0, 'H');
    try tc.expectCodepointAt(4, 0, 'o');
}

test "print carriage return" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    // "AB\rCD" - \r is ignored if it does not have a following \n
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "AB\rCD", 0, 0, .default);

    try testing.expectEqual(@as(usize, 5), result.bytes_consumed);
    try testing.expectEqual(@as(u16, 1), result.lines_used); // Still on line 0
    try testing.expectEqual(@as(usize, 4), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 4), result.final_x);
    try testing.expectEqual(@as(u16, 0), result.final_y);

    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCodepointAt(1, 0, 'B');
    try tc.expectCodepointAt(2, 0, 'C');
    try tc.expectCodepointAt(3, 0, 'D');
}

test "print CRLF" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    // \r\n comes as a single grapheme cluster
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "AB\r\nCD", 0, 0, .default);

    // Same behavior as \n
    try testing.expectEqual(@as(usize, 6), result.bytes_consumed); // "AB\r\nCD" = 6 bytes
    try testing.expectEqual(@as(u16, 2), result.lines_used);
    try testing.expectEqual(@as(usize, 4), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 2), result.final_x);
    try testing.expectEqual(@as(u16, 1), result.final_y);

    // Row 0
    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCodepointAt(1, 0, 'B');

    // Row 1
    try tc.expectCodepointAt(0, 1, 'C');
    try tc.expectCodepointAt(1, 1, 'D');
}

test "print newline stops at bottom" {
    var tc = try TestContext.init(10, 2);
    defer tc.deinit();

    // Only 2 rows, but text has 3 lines
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "A\nB\nC", 0, 0, .default);

    // Should render A and B, stop before C
    try testing.expectEqual(@as(u16, 2), result.lines_used);
    try testing.expectEqual(@as(usize, 2), result.graphemes_rendered);

    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCodepointAt(0, 1, 'B');
}

test "print newline with offset" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    // Start at x=3, newline should reset to x=0
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "AB\nCD", 3, 1, .default);

    try testing.expectEqual(@as(u16, 2), result.lines_used);
    try testing.expectEqual(@as(u16, 2), result.final_x);
    try testing.expectEqual(@as(u16, 2), result.final_y);

    // Row 1: _ _ _ A B
    try tc.expectCodepointAt(3, 1, 'A');
    try tc.expectCodepointAt(4, 1, 'B');

    // Row 2: C D (newline resets to column 0)
    try tc.expectCodepointAt(0, 2, 'C');
    try tc.expectCodepointAt(1, 2, 'D');
}

test "print expands tabs" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    // "A\tB" with tab_width=4
    // A at 0, tab expands to spaces at 1,2,3, B at 4
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "A\tB", 0, 0, .{ .wrap = false, .tab_width = 4 });

    try testing.expectEqual(@as(usize, 3), result.bytes_consumed); // A + \t + B
    try testing.expectEqual(@as(u16, 1), result.lines_used);
    try testing.expectEqual(@as(usize, 5), result.graphemes_rendered); // A + 3 spaces + B
    try testing.expectEqual(@as(u16, 5), result.final_x);
    try testing.expectEqual(@as(u16, 0), result.final_y);

    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCodepointAt(1, 0, ' '); // Tab space
    try tc.expectCodepointAt(2, 0, ' '); // Tab space
    try tc.expectCodepointAt(3, 0, ' '); // Tab space
    try tc.expectCodepointAt(4, 0, 'B');
}

test "print tab at tab stop" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    // Start at column 4 (already at tab stop), tab should advance 4 spaces to column 8
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "\tX", 4, 0, .{ .wrap = false, .tab_width = 4 });

    try testing.expectEqual(@as(usize, 5), result.graphemes_rendered); // 4 spaces + X
    try testing.expectEqual(@as(u16, 9), result.final_x);

    try tc.expectCodepointAt(4, 0, ' '); // Tab space
    try tc.expectCodepointAt(5, 0, ' '); // Tab space
    try tc.expectCodepointAt(6, 0, ' '); // Tab space
    try tc.expectCodepointAt(7, 0, ' '); // Tab space
    try tc.expectCodepointAt(8, 0, 'X');
}

test "print tab wraps" {
    var tc = try TestContext.init(5, 3);
    defer tc.deinit();

    // Start at x=3, tab_width=4, so need 1 space to reach tab stop at 4
    // But we're in a 5-wide buffer, so we can fit 2 more spaces before wrapping
    // Tab expands: cursor at 3, need 1 space (to get to 4)
    // Position 3: space, cursor now at 4
    // That's all for the tab (cursor_x % 4 == 3, so 4-3=1 space)
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "\tX", 3, 0, .{ .wrap = true, .tab_width = 4 });

    try testing.expectEqual(@as(usize, 2), result.graphemes_rendered); // 1 space + X
    try testing.expectEqual(@as(u16, 0), result.final_x);
    try testing.expectEqual(@as(u16, 1), result.final_y);

    try tc.expectCodepointAt(3, 0, ' '); // Tab space
    try tc.expectCodepointAt(4, 0, 'X');
}

test "print tab wraps mid-tab" {
    var tc = try TestContext.init(5, 3);
    defer tc.deinit();

    // Start at x=4 in 5-wide buffer, tab_width=4
    // cursor at 4, 4 % 4 = 0, so need 4 spaces to reach next tab stop. But only 1 space remaining. Move cursor to end
    // Position 4: space, cursor now at 5 (past right edge, wrap)
    // Then X at position 3 row 1
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "\tX", 4, 0, .{ .wrap = true, .tab_width = 4 });

    try testing.expectEqual(@as(usize, 2), result.graphemes_rendered); // 4 spaces + X
    try testing.expectEqual(@as(u16, 2), result.lines_used);
    try testing.expectEqual(@as(u16, 1), result.final_x);
    try testing.expectEqual(@as(u16, 1), result.final_y);

    try tc.expectCodepointAt(4, 0, ' '); // First tab space
    try tc.expectCodepointAt(0, 1, 'X'); // Tab space after wrap
}

test "print custom tab width" {
    var tc = try TestContext.init(20, 5);
    defer tc.deinit();

    // "A\tB" with tab_width=8
    // A at 0, tab expands to 7 spaces (1,2,3,4,5,6,7), B at 8
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "A\tB", 0, 0, .{ .wrap = false, .tab_width = 8 });

    try testing.expectEqual(@as(usize, 9), result.graphemes_rendered); // A + 7 spaces + B
    try testing.expectEqual(@as(u16, 9), result.final_x);

    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCodepointAt(7, 0, ' '); // Last tab space
    try tc.expectCodepointAt(8, 0, 'B');
}

test "print tab truncates without wrap" {
    var tc = try TestContext.init(5, 3);
    defer tc.deinit();

    // Start at x=3 in 5-wide buffer, tab_width=4, no wrap
    // Tab needs 1 space (to get to 4), then we're at edge
    // X would be at 4, but then we're still within bounds
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "\tXY", 3, 0, .{ .wrap = false, .tab_width = 4 });

    // Space at 3, X at 4, Y truncated
    try testing.expectEqual(@as(usize, 2), result.graphemes_rendered); // 1 space + X
    try testing.expectEqual(@as(u16, 0), result.final_x);
    try testing.expectEqual(@as(u16, 1), result.final_y);

    try tc.expectCodepointAt(3, 0, ' ');
    try tc.expectCodepointAt(4, 0, 'X');
    try tc.expectCodepointAt(0, 1, ' ');
}

test "print multiple tabs" {
    var tc = try TestContext.init(20, 5);
    defer tc.deinit();

    // "A\t\tB" with tab_width=4
    // A at 0, first tab to 4, second tab to 8, B at 8
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "A\t\tB", 0, 0, .{ .wrap = false, .tab_width = 4 });

    // A + 3 spaces + 4 spaces + B = 9 graphemes
    try testing.expectEqual(@as(usize, 9), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 9), result.final_x);

    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCodepointAt(4, 0, ' '); // Start of second tab
    try tc.expectCodepointAt(8, 0, 'B');
}

test "print UTF-8 narrow" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    // "café" - 'é' is 2 bytes (C3 A9), width=1
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "café", 0, 0, .default);

    // 4 graphemes: c, a, f, é
    try testing.expectEqual(@as(usize, 5), result.bytes_consumed); // 3 ASCII + 2-byte é
    try testing.expectEqual(@as(usize, 4), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 4), result.final_x);

    try tc.expectCodepointAt(0, 0, 'c');
    try tc.expectCodepointAt(1, 0, 'a');
    try tc.expectCodepointAt(2, 0, 'f');
    try tc.expectCodepointAt(3, 0, 0xE9); // é = U+00E9

    // All should be narrow width and codepoint tag (single codepoint each)
    try tc.expectCellWidth(3, 0, .narrow);
    try tc.expectCellTag(3, 0, .codepoint);
}

test "print Euro sign" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    // "€" is 3 bytes (E2 82 AC), width=1
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "€", 0, 0, .default);

    try testing.expectEqual(@as(usize, 3), result.bytes_consumed);
    try testing.expectEqual(@as(usize, 1), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 1), result.final_x);

    try tc.expectCodepointAt(0, 0, 0x20AC); // € = U+20AC
    try tc.expectCellWidth(0, 0, .narrow);
    try tc.expectCellTag(0, 0, .codepoint);
}

test "print combining marks" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    // "e\xCC\x81" = e + combining acute accent (U+0301) = 1 grapheme cluster
    // This should be stored as a grapheme (tag = .grapheme)
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "e\xCC\x81", 0, 0, .default);

    try testing.expectEqual(@as(usize, 3), result.bytes_consumed); // 1 + 2 bytes
    try testing.expectEqual(@as(usize, 1), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 1), result.final_x);

    try tc.expectCellWidth(0, 0, .narrow);
    try tc.expectCellTag(0, 0, .grapheme);

    // Grapheme buffer should contain the full UTF-8 bytes
    const grapheme = tc.getGraphemeAt(0, 0);
    try testing.expect(grapheme != null);
    try testing.expectEqualStrings("e\xCC\x81", grapheme.?);
}

test "print multiple combining marks" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    // "a\xCC\x81\xCC\x82" = a + combining acute + combining circumflex
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "a\xCC\x81\xCC\x82", 0, 0, .default);

    try testing.expectEqual(@as(usize, 5), result.bytes_consumed); // 1 + 2 + 2 bytes
    try testing.expectEqual(@as(usize, 1), result.graphemes_rendered);

    try tc.expectCellTag(0, 0, .grapheme);

    const grapheme = tc.getGraphemeAt(0, 0);
    try testing.expect(grapheme != null);
    try testing.expectEqualStrings("a\xCC\x81\xCC\x82", grapheme.?);
}

test "print mixed ASCII and UTF-8" {
    var tc = try TestContext.init(20, 5);
    defer tc.deinit();

    // "Hello café!"
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "Hello café!", 0, 0, .default);

    try testing.expectEqual(@as(usize, 12), result.bytes_consumed); // 11 chars, é is 2 bytes
    try testing.expectEqual(@as(usize, 11), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 11), result.final_x);

    try tc.expectCodepointAt(0, 0, 'H');
    try tc.expectCodepointAt(5, 0, ' ');
    try tc.expectCodepointAt(6, 0, 'c');
    try tc.expectCodepointAt(7, 0, 'a');
    try tc.expectCodepointAt(8, 0, 'f');
    try tc.expectCodepointAt(9, 0, 0xE9); // é
    try tc.expectCodepointAt(10, 0, '!');
}

test "print combining with wrap" {
    var tc = try TestContext.init(5, 3);
    defer tc.deinit();

    // "ABCD" + combining mark + "F" - should wrap properly
    // Graphemes: A, B, C, D, e+combining, F = 6 graphemes
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "ABCDe\xCC\x81F", 0, 0, .{ .wrap = true, .tab_width = 4 });

    // Row 0: A B C D e+combining
    // Row 1: F
    try testing.expectEqual(@as(usize, 6), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 2), result.lines_used);

    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCellTag(4, 0, .grapheme);
    try tc.expectCodepointAt(0, 1, 'F');
}

test "print UTF-8 truncates at edge" {
    var tc = try TestContext.init(3, 3);
    defer tc.deinit();

    // "ABéC" in 3-wide buffer - should truncate after é
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "ABéC", 0, 0, .default);

    // Only A, B, é should render
    try testing.expectEqual(@as(usize, 3), result.graphemes_rendered);

    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCodepointAt(1, 0, 'B');
    try tc.expectCodepointAt(2, 0, 0xE9);
}

test "print CJK characters" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    // "中文" - two CJK characters, each 2 cells wide
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "中文", 0, 0, .default);

    // 2 graphemes, 4 cells
    try testing.expectEqual(@as(usize, 6), result.bytes_consumed); // Each CJK char is 3 bytes
    try testing.expectEqual(@as(usize, 2), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 4), result.final_x);

    // First character: 中 (U+4E2D)
    try tc.expectCodepointAt(0, 0, 0x4E2D);
    try tc.expectCellWidth(0, 0, .wide_start);
    try tc.expectCodepointAt(1, 0, ' ');
    try tc.expectCellWidth(1, 0, .wide_end);

    // Second character: 文 (U+6587)
    try tc.expectCodepointAt(2, 0, 0x6587);
    try tc.expectCellWidth(2, 0, .wide_start);
    try tc.expectCodepointAt(3, 0, ' ');
    try tc.expectCellWidth(3, 0, .wide_end);
}

test "print emoji" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    // "😀" - emoji, 2 cells wide
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "😀", 0, 0, .default);

    try testing.expectEqual(@as(usize, 4), result.bytes_consumed); // 4-byte emoji
    try testing.expectEqual(@as(usize, 1), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 2), result.final_x);

    // Emoji: 😀 (U+1F600)
    try tc.expectCodepointAt(0, 0, 0x1F600);
    try tc.expectCellWidth(0, 0, .wide_start);
    try tc.expectCodepointAt(1, 0, ' ');
    try tc.expectCellWidth(1, 0, .wide_end);
}

test "print wide at boundary wraps" {
    var tc = try TestContext.init(3, 3);
    defer tc.deinit();

    // "AB中" in 3-wide buffer with wrap
    // A at (0,0), B at (1,0), 中 only has 1 cell remaining, wraps to (0,1)-(1,1)
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "AB中", 0, 0, .{ .wrap = true, .tab_width = 4 });

    try testing.expectEqual(@as(usize, 3), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 2), result.lines_used);
    try testing.expectEqual(@as(u16, 2), result.final_x);
    try testing.expectEqual(@as(u16, 1), result.final_y);

    // Row 0: A B _
    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCellWidth(0, 0, .narrow);
    try tc.expectCodepointAt(1, 0, 'B');
    try tc.expectCellWidth(1, 0, .narrow);

    // Row 1: 中 (wide_start + wide_end)
    try tc.expectCodepointAt(0, 1, 0x4E2D);
    try tc.expectCellWidth(0, 1, .wide_start);
    try tc.expectCodepointAt(1, 1, ' ');
    try tc.expectCellWidth(1, 1, .wide_end);
}

test "print wide at boundary no wrap" {
    var tc = try TestContext.init(3, 3);
    defer tc.deinit();

    // "AB中" in 3-wide buffer without wrap
    // A at 0, B at 1, cursor at 2
    // 中 needs 2 cells but only 1 remains (position 2) so it will not be rendered
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "AB中", 0, 0, .{ .wrap = false, .tab_width = 4 });

    try testing.expectEqual(@as(usize, 2), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 0), result.final_x);
    try testing.expectEqual(@as(u16, 1), result.final_y);

    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCellWidth(0, 0, .narrow);

    try tc.expectCodepointAt(1, 0, 'B');
    try tc.expectCellWidth(1, 0, .narrow);

    // Empty cell at position 2
    try tc.expectCodepointAt(2, 0, ' ');
    try tc.expectCellWidth(2, 0, .narrow);
}

test "print wide exactly fits" {
    var tc = try TestContext.init(4, 3);
    defer tc.deinit();

    // "AB中" in 4-wide buffer - 中 should exactly fit at positions 2-3
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "AB中", 0, 0, .default);

    try testing.expectEqual(@as(usize, 3), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 0), result.final_x);
    try testing.expectEqual(@as(u16, 1), result.final_y);

    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCodepointAt(1, 0, 'B');
    try tc.expectCodepointAt(2, 0, 0x4E2D);
    try tc.expectCellWidth(2, 0, .wide_start);
    try tc.expectCodepointAt(3, 0, ' ');
    try tc.expectCellWidth(3, 0, .wide_end);
}

test "print multiple wide characters wrap" {
    var tc = try TestContext.init(4, 3);
    defer tc.deinit();

    // "中文字" - 3 wide chars in 4-wide buffer with wrap
    // Row 0: 中文 (4 cells)
    // Row 1: 字 (2 cells)
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "中文字", 0, 0, .{ .wrap = true, .tab_width = 4 });

    try testing.expectEqual(@as(usize, 3), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 2), result.lines_used);
    try testing.expectEqual(@as(u16, 2), result.final_x);
    try testing.expectEqual(@as(u16, 1), result.final_y);

    // Row 0
    try tc.expectCodepointAt(0, 0, 0x4E2D); // 中
    try tc.expectCellWidth(0, 0, .wide_start);
    try tc.expectCodepointAt(2, 0, 0x6587); // 文
    try tc.expectCellWidth(2, 0, .wide_start);

    // Row 1
    try tc.expectCodepointAt(0, 1, 0x5B57); // 字
    try tc.expectCellWidth(0, 1, .wide_start);
}

test "print mixed narrow and wide" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    // "Hello中文!" - mixed content
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "Hello中文!", 0, 0, .default);

    // 5 narrow + 2 wide + 1 narrow = 8 graphemes, 10 cells
    try testing.expectEqual(@as(usize, 8), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 0), result.final_x);
    try testing.expectEqual(@as(u16, 1), result.final_y);

    try tc.expectCodepointAt(0, 0, 'H');
    try tc.expectCellWidth(0, 0, .narrow);
    try tc.expectCodepointAt(5, 0, 0x4E2D); // 中
    try tc.expectCellWidth(5, 0, .wide_start);
    try tc.expectCodepointAt(7, 0, 0x6587); // 文
    try tc.expectCellWidth(7, 0, .wide_start);
    try tc.expectCodepointAt(9, 0, '!');
    try tc.expectCellWidth(9, 0, .narrow);
}

test "print skin tone emoji" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    // 👨🏽 = man + fitzpatrick type-4 (2 codepoints, width=2)
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "\xF0\x9F\x91\xA8\xF0\x9F\x8F\xBD", 0, 0, .default);

    try testing.expectEqual(@as(usize, 8), result.bytes_consumed);
    try testing.expectEqual(@as(usize, 1), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 2), result.final_x);

    // First cell: base emoji with grapheme tag (multi-codepoint)
    try tc.expectCellWidth(0, 0, .wide_start);
    try tc.expectCellTag(0, 0, .grapheme);

    // Second cell: wide_end
    try tc.expectCellWidth(1, 0, .wide_end);

    // Grapheme buffer should contain the full UTF-8 bytes
    const grapheme = tc.getGraphemeAt(0, 0);
    try testing.expect(grapheme != null);
    try testing.expectEqualStrings("\xF0\x9F\x91\xA8\xF0\x9F\x8F\xBD", grapheme.?);
}

test "print ZWJ family sequence" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    // 👨‍👩‍👧‍👦 = family (man + ZWJ + woman + ZWJ + girl + ZWJ + boy)
    // 7 codepoints, width=2
    const family = "\xF0\x9F\x91\xA8\xE2\x80\x8D\xF0\x9F\x91\xA9\xE2\x80\x8D\xF0\x9F\x91\xA7\xE2\x80\x8D\xF0\x9F\x91\xA6";
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, family, 0, 0, .default);

    try testing.expectEqual(@as(usize, 25), result.bytes_consumed);
    try testing.expectEqual(@as(usize, 1), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 2), result.final_x);

    // First cell: base emoji with grapheme tag
    try tc.expectCellWidth(0, 0, .wide_start);
    try tc.expectCellTag(0, 0, .grapheme);

    // Second cell: wide_end
    try tc.expectCellWidth(1, 0, .wide_end);

    // Grapheme buffer should contain full sequence
    const grapheme = tc.getGraphemeAt(0, 0);
    try testing.expect(grapheme != null);
    try testing.expectEqualStrings(family, grapheme.?);
}

test "print flag emoji" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    // 🇺🇸 = US flag (2 regional indicators, width=2)
    const flag = "\xF0\x9F\x87\xBA\xF0\x9F\x87\xB8";
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, flag, 0, 0, .default);

    try testing.expectEqual(@as(usize, 8), result.bytes_consumed);
    try testing.expectEqual(@as(usize, 1), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 2), result.final_x);

    // First cell: first regional indicator with grapheme tag
    try tc.expectCellWidth(0, 0, .wide_start);
    try tc.expectCellTag(0, 0, .grapheme);

    // Second cell: wide_end
    try tc.expectCellWidth(1, 0, .wide_end);

    // Grapheme buffer should contain full flag
    const grapheme = tc.getGraphemeAt(0, 0);
    try testing.expect(grapheme != null);
    try testing.expectEqualStrings(flag, grapheme.?);
}

test "print variation selector emoji" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    // ❤️ = heart + VS16 (width becomes 2 with emoji presentation)
    const heart = "\xE2\x9D\xA4\xEF\xB8\x8F";
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, heart, 0, 0, .default);

    try testing.expectEqual(@as(usize, 6), result.bytes_consumed);
    try testing.expectEqual(@as(usize, 1), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 2), result.final_x);

    // First cell: heart with grapheme tag (multi-codepoint due to VS16)
    try tc.expectCellWidth(0, 0, .wide_start);
    try tc.expectCellTag(0, 0, .grapheme);

    // Second cell: wide_end
    try tc.expectCellWidth(1, 0, .wide_end);

    // Grapheme buffer should contain heart + VS16
    const grapheme = tc.getGraphemeAt(0, 0);
    try testing.expect(grapheme != null);
    try testing.expectEqualStrings(heart, grapheme.?);
}

test "print text heart without variation selector" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    // ❤ = heart without VS16 (text presentation, width=1)
    const heart = "\xE2\x9D\xA4";
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, heart, 0, 0, .default);

    try testing.expectEqual(@as(usize, 3), result.bytes_consumed);
    try testing.expectEqual(@as(usize, 1), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 1), result.final_x);

    // Single codepoint, narrow width, codepoint tag
    try tc.expectCodepointAt(0, 0, 0x2764); // ❤ U+2764
    try tc.expectCellWidth(0, 0, .narrow);
    try tc.expectCellTag(0, 0, .codepoint);
}

test "print keycap sequence" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    // 1️⃣ = 1 + VS16 + combining enclosing keycap (3 codepoints, width=2)
    const keycap = "1\xEF\xB8\x8F\xE2\x83\xA3";
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, keycap, 0, 0, .default);

    try testing.expectEqual(@as(usize, 7), result.bytes_consumed);
    try testing.expectEqual(@as(usize, 1), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 2), result.final_x);

    // First cell: '1' with grapheme tag
    try tc.expectCellWidth(0, 0, .wide_start);
    try tc.expectCellTag(0, 0, .grapheme);

    // Second cell: wide_end
    try tc.expectCellWidth(1, 0, .wide_end);

    // Grapheme buffer should contain full keycap sequence
    const grapheme = tc.getGraphemeAt(0, 0);
    try testing.expect(grapheme != null);
    try testing.expectEqualStrings(keycap, grapheme.?);
}

test "print ZWJ profession emoji" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    // 👨‍💻 = man + ZWJ + laptop (3 codepoints, width=2)
    const technologist = "\xF0\x9F\x91\xA8\xE2\x80\x8D\xF0\x9F\x92\xBB";
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, technologist, 0, 0, .default);

    try testing.expectEqual(@as(usize, 11), result.bytes_consumed);
    try testing.expectEqual(@as(usize, 1), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 2), result.final_x);

    try tc.expectCellWidth(0, 0, .wide_start);
    try tc.expectCellTag(0, 0, .grapheme);
    try tc.expectCellWidth(1, 0, .wide_end);

    const grapheme = tc.getGraphemeAt(0, 0);
    try testing.expect(grapheme != null);
    try testing.expectEqualStrings(technologist, grapheme.?);
}

test "print subdivision flag" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    // 🏴󠁧󠁢󠁥󠁮󠁧󠁿 = England flag (black flag + tag sequence)
    const england = "\xF0\x9F\x8F\xB4\xF3\xA0\x81\xA7\xF3\xA0\x81\xA2\xF3\xA0\x81\xA5\xF3\xA0\x81\xAE\xF3\xA0\x81\xA7\xF3\xA0\x81\xBF";
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, england, 0, 0, .default);

    try testing.expectEqual(@as(usize, 28), result.bytes_consumed);
    try testing.expectEqual(@as(usize, 1), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 2), result.final_x);

    try tc.expectCellWidth(0, 0, .wide_start);
    try tc.expectCellTag(0, 0, .grapheme);
    try tc.expectCellWidth(1, 0, .wide_end);

    const grapheme = tc.getGraphemeAt(0, 0);
    try testing.expect(grapheme != null);
    try testing.expectEqualStrings(england, grapheme.?);
}

test "print complex emoji with skin tone and profession" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    // 👨🏽‍⚕️ = man + skin tone + ZWJ + medical symbol + VS16 (5 codepoints)
    const doctor = "\xF0\x9F\x91\xA8\xF0\x9F\x8F\xBD\xE2\x80\x8D\xE2\x9A\x95\xEF\xB8\x8F";
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, doctor, 0, 0, .default);

    try testing.expectEqual(@as(usize, 17), result.bytes_consumed);
    try testing.expectEqual(@as(usize, 1), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 2), result.final_x);

    try tc.expectCellWidth(0, 0, .wide_start);
    try tc.expectCellTag(0, 0, .grapheme);
    try tc.expectCellWidth(1, 0, .wide_end);

    const grapheme = tc.getGraphemeAt(0, 0);
    try testing.expect(grapheme != null);
    try testing.expectEqualStrings(doctor, grapheme.?);
}

test "print multiple complex emoji in sequence" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    // 🇺🇸🇬🇧 = US flag + UK flag (2 graphemes, 4 cells)
    const flags = "\xF0\x9F\x87\xBA\xF0\x9F\x87\xB8\xF0\x9F\x87\xAC\xF0\x9F\x87\xA7";
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, flags, 0, 0, .default);

    try testing.expectEqual(@as(usize, 16), result.bytes_consumed);
    try testing.expectEqual(@as(usize, 2), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 4), result.final_x);

    // First flag: 🇺🇸
    try tc.expectCellWidth(0, 0, .wide_start);
    try tc.expectCellTag(0, 0, .grapheme);
    try tc.expectCellWidth(1, 0, .wide_end);

    // Second flag: 🇬🇧
    try tc.expectCellWidth(2, 0, .wide_start);
    try tc.expectCellTag(2, 0, .grapheme);
    try tc.expectCellWidth(3, 0, .wide_end);
}

test "print complex emoji at boundary wraps" {
    var tc = try TestContext.init(3, 3);
    defer tc.deinit();

    // "A" + 👨🏽 (skin tone emoji) in 3-wide buffer with wrap
    // A at (0,0), emoji only has 2 cells remaining but needs 2, should fit
    // Wait, A at 0, cursor at 1, emoji needs 2 cells, we have 2 (1,2), should fit
    const text = "A\xF0\x9F\x91\xA8\xF0\x9F\x8F\xBD";
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, text, 0, 0, .{ .wrap = true, .tab_width = 4 });

    try testing.expectEqual(@as(usize, 2), result.graphemes_rendered); // A + emoji
    try testing.expectEqual(@as(u16, 0), result.final_x);
    try testing.expectEqual(@as(u16, 1), result.final_y);

    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCellWidth(0, 0, .narrow);
    try tc.expectCellWidth(1, 0, .wide_start);
    try tc.expectCellWidth(2, 0, .wide_end);
}

test "print complex emoji at boundary with only 1 cell wraps" {
    var tc = try TestContext.init(3, 3);
    defer tc.deinit();

    // "AB" + 👨🏽 in 3-wide buffer - only 1 cell left, should wrap
    const text = "AB\xF0\x9F\x91\xA8\xF0\x9F\x8F\xBD";
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, text, 0, 0, .{ .wrap = true, .tab_width = 4 });

    try testing.expectEqual(@as(usize, 3), result.graphemes_rendered); // A, B, emoji
    try testing.expectEqual(@as(u16, 2), result.lines_used);
    try testing.expectEqual(@as(u16, 2), result.final_x);
    try testing.expectEqual(@as(u16, 1), result.final_y);

    // Row 0: A B _
    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCodepointAt(1, 0, 'B');

    // Row 1: emoji
    try tc.expectCellWidth(0, 1, .wide_start);
    try tc.expectCellTag(0, 1, .grapheme);
    try tc.expectCellWidth(1, 1, .wide_end);
}

test "print mixed text and complex graphemes" {
    var tc = try TestContext.init(20, 5);
    defer tc.deinit();

    // "Hello 👨‍👩‍👧 世界!"
    const text = "Hello \xF0\x9F\x91\xA8\xE2\x80\x8D\xF0\x9F\x91\xA9\xE2\x80\x8D\xF0\x9F\x91\xA7 \xE4\xB8\x96\xE7\x95\x8C!";
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, text, 0, 0, .default);

    // "Hello " (6) + family emoji (1, 2 cells) + " " (1) + "世界" (2, 4 cells) + "!" (1) = 11 graphemes
    // Cells: 6 + 2 + 1 + 4 + 1 = 14 cells
    try testing.expectEqual(@as(usize, 11), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 14), result.final_x);

    try tc.expectCodepointAt(0, 0, 'H');
    try tc.expectCodepointAt(5, 0, ' ');
    try tc.expectCellTag(6, 0, .grapheme);
    try tc.expectCellWidth(6, 0, .wide_start);
    try tc.expectCodepointAt(8, 0, ' ');
    try tc.expectCodepointAt(9, 0, 0x4E16); // 世
    try tc.expectCellWidth(9, 0, .wide_start);
    try tc.expectCodepointAt(13, 0, '!');
}

test "print mixed content with all features" {
    var tc = try TestContext.init(20, 5);
    defer tc.deinit();

    // "Hello 世界!\n\tTab 😀"
    const text = "Hello \xE4\xB8\x96\xE7\x95\x8C!\n\tTab \xF0\x9F\x98\x80";
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, text, 0, 0, .{ .wrap = true, .tab_width = 4 });

    // Line 0: "Hello 世界!" = 6 + 4 + 1 = 11 cells, 8 graphemes
    // Line 1: "    Tab 😀" = 4 (tab) + 4 + 2 = 10 cells
    try testing.expectEqual(@as(u16, 2), result.lines_used);

    // Verify line 0 content
    try tc.expectCodepointAt(0, 0, 'H');
    try tc.expectCodepointAt(6, 0, 0x4E16); // 世
    try tc.expectCellWidth(6, 0, .wide_start);
    try tc.expectCodepointAt(10, 0, '!');

    // Verify line 1 content (after newline and tab)
    try tc.expectCodepointAt(0, 1, ' '); // Tab expanded to spaces
    try tc.expectCodepointAt(4, 1, 'T');
}

test "print invalid UTF-8 produces replacement characters" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    // Invalid UTF-8 bytes are rendered as replacement characters (U+FFFD)
    // This is WTF-8 semantics - graceful degradation instead of errors
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "\xFF\xFE", 0, 0, .default);

    // Each invalid byte becomes a replacement character
    try testing.expectEqual(@as(usize, 2), result.bytes_consumed);
    try testing.expectEqual(@as(usize, 2), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 2), result.final_x);

    // Both cells should contain U+FFFD (replacement character)
    try tc.expectCodepointAt(0, 0, 0xFFFD);
    try tc.expectCodepointAt(1, 0, 0xFFFD);
}

test "print very long line" {
    var tc = try TestContext.init(80, 24);
    defer tc.deinit();

    // Create 1000 character string
    var long_text: [1000]u8 = undefined;
    for (&long_text, 0..) |*c, i| {
        c.* = @intCast('A' + @as(u8, @intCast(i % 26)));
    }

    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, &long_text, 0, 0, .{ .wrap = true, .tab_width = 4 });

    // 1000 chars / 80 cols = 12 full lines + 40 chars on line 13
    try testing.expectEqual(@as(usize, 1000), result.bytes_consumed);
    try testing.expectEqual(@as(usize, 1000), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 13), result.lines_used);
    try testing.expectEqual(@as(u16, 40), result.final_x);
    try testing.expectEqual(@as(u16, 12), result.final_y);

    // Verify first and last positions
    // Index i maps to 'A' + (i % 26)
    try tc.expectCodepointAt(0, 0, 'A'); // index 0
    try tc.expectCodepointAt(79, 0, 'A' + (79 % 26)); // index 79 % 26 = 1 -> 'B'
    try tc.expectCodepointAt(0, 1, 'A' + (80 % 26)); // index 80 % 26 = 2 -> 'C'
}

test "print exact boundary - fills line exactly" {
    var tc = try TestContext.init(5, 2);
    defer tc.deinit();

    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "ABCDE", 0, 0, .{ .wrap = true, .tab_width = 4 });

    try testing.expectEqual(@as(usize, 5), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 1), result.lines_used);
    try testing.expectEqual(@as(u16, 0), result.final_x);
    try testing.expectEqual(@as(u16, 1), result.final_y);
}

test "print exact boundary - wide char fills last two cells" {
    var tc = try TestContext.init(4, 2);
    defer tc.deinit();

    // "AB中" - AB takes 2 cells, 中 takes 2 cells = exactly 4
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "AB\xE4\xB8\xAD", 0, 0, .{ .wrap = true, .tab_width = 4 });

    try testing.expectEqual(@as(usize, 3), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 1), result.lines_used);
    try testing.expectEqual(@as(u16, 0), result.final_x);
    try testing.expectEqual(@as(u16, 1), result.final_y);

    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCodepointAt(1, 0, 'B');
    try tc.expectCodepointAt(2, 0, 0x4E2D); // 中
    try tc.expectCellWidth(2, 0, .wide_start);
    try tc.expectCellWidth(3, 0, .wide_end);
}

test "printAssumeNoGrapheme basic ASCII" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    const result = printAssumeNoGrapheme(tc.scissor(), "Hello", 0, 0, .default);

    try testing.expectEqual(@as(usize, 5), result.bytes_consumed);
    try testing.expectEqual(@as(u16, 1), result.lines_used);
    try testing.expectEqual(@as(u16, 5), result.final_x);
    try testing.expectEqual(@as(u16, 0), result.final_y);
    try testing.expectEqual(@as(usize, 5), result.graphemes_rendered);

    try tc.expectCodepointAt(0, 0, 'H');
    try tc.expectCodepointAt(1, 0, 'e');
    try tc.expectCodepointAt(2, 0, 'l');
    try tc.expectCodepointAt(3, 0, 'l');
    try tc.expectCodepointAt(4, 0, 'o');

    // All should be narrow width
    try tc.expectCellWidth(0, 0, .narrow);
    try tc.expectCellWidth(4, 0, .narrow);
}

test "printAssumeNoGrapheme ASCII with offset" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    const result = printAssumeNoGrapheme(tc.scissor(), "Hi", 3, 2, .default);

    try testing.expectEqual(@as(usize, 2), result.bytes_consumed);
    try testing.expectEqual(@as(u16, 5), result.final_x);
    try testing.expectEqual(@as(u16, 2), result.final_y);

    // Cells at offset should be set
    try tc.expectCodepointAt(3, 2, 'H');
    try tc.expectCodepointAt(4, 2, 'i');

    // Original cells should still be space
    try tc.expectCodepointAt(0, 0, ' ');
    try tc.expectCodepointAt(2, 2, ' ');
}

test "printAssumeNoGrapheme ASCII truncates at right edge" {
    var tc = try TestContext.init(5, 5);
    defer tc.deinit();

    const result = printAssumeNoGrapheme(tc.scissor(), "Hello World", 0, 0, .default);

    // Should only render "Hello" (5 chars)
    try testing.expectEqual(@as(usize, 5), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 1), result.lines_used);

    try tc.expectCodepointAt(0, 0, 'H');
    try tc.expectCodepointAt(1, 0, 'e');
    try tc.expectCodepointAt(2, 0, 'l');
    try tc.expectCodepointAt(3, 0, 'l');
    try tc.expectCodepointAt(4, 0, 'o');
}

test "printAssumeNoGrapheme outside buffer returns early" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    // Start below the buffer
    const result = printAssumeNoGrapheme(tc.scissor(), "Hello", 0, 10, .default);

    try testing.expectEqual(@as(usize, 0), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 0), result.lines_used);
}

test "printAssumeNoGrapheme wraps at scissor edge" {
    var tc = try TestContext.init(5, 3);
    defer tc.deinit();

    const result = printAssumeNoGrapheme(tc.scissor(), "ABCDEFGHIJ", 0, 0, .{ .wrap = true, .tab_width = 4 });

    // Row 0: A B C D E
    // Row 1: F G H I J
    try testing.expectEqual(@as(usize, 10), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 2), result.lines_used);
    try testing.expectEqual(@as(u16, 0), result.final_x);
    try testing.expectEqual(@as(u16, 2), result.final_y);

    // Row 0
    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCodepointAt(4, 0, 'E');

    // Row 1
    try tc.expectCodepointAt(0, 1, 'F');
    try tc.expectCodepointAt(4, 1, 'J');
}

test "printAssumeNoGrapheme stops at bottom with wrap" {
    var tc = try TestContext.init(5, 2);
    defer tc.deinit();

    // 15 chars but only 2 rows available (10 cells max)
    const result = printAssumeNoGrapheme(tc.scissor(), "ABCDEFGHIJKLMNO", 0, 0, .{ .wrap = true, .tab_width = 4 });

    // Should only render 10 chars (2 lines of 5)
    try testing.expectEqual(@as(usize, 10), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 2), result.lines_used);

    // Row 0
    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCodepointAt(4, 0, 'E');

    // Row 1
    try tc.expectCodepointAt(0, 1, 'F');
    try tc.expectCodepointAt(4, 1, 'J');
}

test "printAssumeNoGrapheme wrap disabled truncates" {
    var tc = try TestContext.init(5, 3);
    defer tc.deinit();

    const result = printAssumeNoGrapheme(tc.scissor(), "Hello World", 0, 0, .{ .wrap = false, .tab_width = 4 });

    // Should only render "Hello" (5 chars)
    try testing.expectEqual(@as(usize, 5), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 1), result.lines_used);

    try tc.expectCodepointAt(0, 0, 'H');
    try tc.expectCodepointAt(4, 0, 'o');

    // Row 1 should still be empty
    try tc.expectCodepointAt(0, 1, ' ');
}

test "printAssumeNoGrapheme wrap with offset" {
    var tc = try TestContext.init(5, 3);
    defer tc.deinit();

    // Start at x=3, so first line has 2 chars, then wrap
    const result = printAssumeNoGrapheme(tc.scissor(), "ABCDEFG", 3, 0, .{ .wrap = true, .tab_width = 4 });

    // Row 0: _ _ _ A B
    // Row 1: C D E F G
    try testing.expectEqual(@as(usize, 7), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 2), result.lines_used);
    try testing.expectEqual(@as(u16, 0), result.final_x);
    try testing.expectEqual(@as(u16, 2), result.final_y);

    // Row 0
    try tc.expectCodepointAt(3, 0, 'A');
    try tc.expectCodepointAt(4, 0, 'B');

    // Row 1
    try tc.expectCodepointAt(0, 1, 'C');
    try tc.expectCodepointAt(4, 1, 'G');
}

test "printAssumeNoGrapheme multiple wraps" {
    var tc = try TestContext.init(3, 5);
    defer tc.deinit();

    // 9 chars, 3 chars per row, should use 3 rows
    const result = printAssumeNoGrapheme(tc.scissor(), "ABCDEFGHI", 0, 0, .{ .wrap = true, .tab_width = 4 });

    try testing.expectEqual(@as(usize, 9), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 3), result.lines_used);
    try testing.expectEqual(@as(u16, 0), result.final_x);
    try testing.expectEqual(@as(u16, 3), result.final_y);

    // Row 0: A B C
    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCodepointAt(2, 0, 'C');

    // Row 1: D E F
    try tc.expectCodepointAt(0, 1, 'D');
    try tc.expectCodepointAt(2, 1, 'F');

    // Row 2: G H I
    try tc.expectCodepointAt(0, 2, 'G');
    try tc.expectCodepointAt(2, 2, 'I');
}

test "printAssumeNoGrapheme handles newlines" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    const result = printAssumeNoGrapheme(tc.scissor(), "AB\nCD", 0, 0, .default);

    // Row 0: A B, Row 1: C D
    try testing.expectEqual(@as(usize, 5), result.bytes_consumed); // "AB\nCD" = 5 bytes
    try testing.expectEqual(@as(u16, 2), result.lines_used);
    try testing.expectEqual(@as(usize, 4), result.graphemes_rendered); // A, B, C, D (newline not rendered)
    try testing.expectEqual(@as(u16, 2), result.final_x);
    try testing.expectEqual(@as(u16, 1), result.final_y);

    // Row 0
    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCodepointAt(1, 0, 'B');

    // Row 1
    try tc.expectCodepointAt(0, 1, 'C');
    try tc.expectCodepointAt(1, 1, 'D');
}

test "printAssumeNoGrapheme multiple consecutive newlines" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    const result = printAssumeNoGrapheme(tc.scissor(), "A\n\n\nB", 0, 0, .default);

    // A on row 0, B on row 3
    try testing.expectEqual(@as(usize, 5), result.bytes_consumed);
    try testing.expectEqual(@as(u16, 4), result.lines_used); // 4 lines: 0, 1, 2, 3
    try testing.expectEqual(@as(usize, 2), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 1), result.final_x);
    try testing.expectEqual(@as(u16, 3), result.final_y);

    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCodepointAt(0, 3, 'B');

    // Rows 1 and 2 should be empty
    try tc.expectCodepointAt(0, 1, ' ');
    try tc.expectCodepointAt(0, 2, ' ');
}

test "printAssumeNoGrapheme CRLF not combined" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    // \r ignored, \n acts as newline
    const result = printAssumeNoGrapheme(tc.scissor(), "AB\r\nCD", 0, 0, .default);

    // Row 0: A B, Row 1: C D
    try testing.expectEqual(@as(usize, 6), result.bytes_consumed); // "AB\r\nCD" = 6 bytes
    try testing.expectEqual(@as(u16, 2), result.lines_used);
    try testing.expectEqual(@as(usize, 4), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 2), result.final_x);
    try testing.expectEqual(@as(u16, 1), result.final_y);

    // Row 0
    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCodepointAt(1, 0, 'B');

    // Row 1
    try tc.expectCodepointAt(0, 1, 'C');
    try tc.expectCodepointAt(1, 1, 'D');
}

test "printAssumeNoGrapheme newline stops at bottom" {
    var tc = try TestContext.init(10, 2);
    defer tc.deinit();

    // Only 2 rows, but text has 3 lines
    const result = printAssumeNoGrapheme(tc.scissor(), "A\nB\nC", 0, 0, .default);

    // Should render A and B, stop before C
    try testing.expectEqual(@as(u16, 2), result.lines_used);
    try testing.expectEqual(@as(usize, 2), result.graphemes_rendered);

    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCodepointAt(0, 1, 'B');
}

test "printAssumeNoGrapheme expands tabs" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    // "A\tB" with tab_width=4
    // A at 0, tab expands to spaces at 1,2,3, B at 4
    const result = printAssumeNoGrapheme(tc.scissor(), "A\tB", 0, 0, .{ .wrap = false, .tab_width = 4 });

    try testing.expectEqual(@as(usize, 3), result.bytes_consumed); // A + \t + B
    try testing.expectEqual(@as(u16, 1), result.lines_used);
    try testing.expectEqual(@as(usize, 5), result.graphemes_rendered); // A + 3 spaces + B
    try testing.expectEqual(@as(u16, 5), result.final_x);
    try testing.expectEqual(@as(u16, 0), result.final_y);

    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCodepointAt(1, 0, ' '); // Tab space
    try tc.expectCodepointAt(2, 0, ' '); // Tab space
    try tc.expectCodepointAt(3, 0, ' '); // Tab space
    try tc.expectCodepointAt(4, 0, 'B');
}

test "printAssumeNoGrapheme tab at tab stop" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    // Start at column 4 (already at tab stop), tab should advance 4 spaces to column 8
    const result = printAssumeNoGrapheme(tc.scissor(), "\tX", 4, 0, .{ .wrap = false, .tab_width = 4 });

    try testing.expectEqual(@as(usize, 5), result.graphemes_rendered); // 4 spaces + X
    try testing.expectEqual(@as(u16, 9), result.final_x);

    try tc.expectCodepointAt(4, 0, ' '); // Tab space
    try tc.expectCodepointAt(5, 0, ' '); // Tab space
    try tc.expectCodepointAt(6, 0, ' '); // Tab space
    try tc.expectCodepointAt(7, 0, ' '); // Tab space
    try tc.expectCodepointAt(8, 0, 'X');
}

test "printAssumeNoGrapheme custom tab width" {
    var tc = try TestContext.init(20, 5);
    defer tc.deinit();

    // "A\tB" with tab_width=8
    // A at 0, tab expands to 7 spaces (1,2,3,4,5,6,7), B at 8
    const result = printAssumeNoGrapheme(tc.scissor(), "A\tB", 0, 0, .{ .wrap = false, .tab_width = 8 });

    try testing.expectEqual(@as(usize, 9), result.graphemes_rendered); // A + 7 spaces + B
    try testing.expectEqual(@as(u16, 9), result.final_x);

    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCodepointAt(7, 0, ' '); // Last tab space
    try tc.expectCodepointAt(8, 0, 'B');
}

test "printAssumeNoGrapheme multiple tabs" {
    var tc = try TestContext.init(20, 5);
    defer tc.deinit();

    // "A\t\tB" with tab_width=4
    // A at 0, first tab to 4, second tab to 8, B at 8
    const result = printAssumeNoGrapheme(tc.scissor(), "A\t\tB", 0, 0, .{ .wrap = false, .tab_width = 4 });

    // A + 3 spaces + 4 spaces + B = 9 graphemes
    try testing.expectEqual(@as(usize, 9), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 9), result.final_x);

    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCodepointAt(4, 0, ' '); // Start of second tab
    try tc.expectCodepointAt(8, 0, 'B');
}

test "printAssumeNoGrapheme tab_width zero" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    // tab_width = 0 should be ignored
    const result = printAssumeNoGrapheme(tc.scissor(), "A\tB", 0, 0, .{ .wrap = false, .tab_width = 0 });

    try testing.expectEqual(@as(usize, 2), result.graphemes_rendered); // A + 1 space + B
    try testing.expectEqual(@as(u16, 2), result.final_x);

    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCodepointAt(1, 0, 'B');
}

test "printAssumeNoGrapheme UTF-8 narrow" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    // "café" - 'é' is 2 bytes, width=1
    const result = printAssumeNoGrapheme(tc.scissor(), "café", 0, 0, .default);

    // 4 graphemes: c, a, f, é
    try testing.expectEqual(@as(usize, 5), result.bytes_consumed); // 3 ASCII + 2-byte é
    try testing.expectEqual(@as(usize, 4), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 4), result.final_x);

    try tc.expectCodepointAt(0, 0, 'c');
    try tc.expectCodepointAt(1, 0, 'a');
    try tc.expectCodepointAt(2, 0, 'f');
    try tc.expectCodepointAt(3, 0, 0xE9); // é = U+00E9

    try tc.expectCellWidth(3, 0, .narrow);
    try tc.expectCellTag(3, 0, .codepoint);
}

test "printAssumeNoGrapheme CJK" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    // "中文" - two CJK characters, each 2 cells wide
    const result = printAssumeNoGrapheme(tc.scissor(), "中文", 0, 0, .default);

    // 2 graphemes, 4 cells
    try testing.expectEqual(@as(usize, 6), result.bytes_consumed); // Each CJK char is 3 bytes
    try testing.expectEqual(@as(usize, 2), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 4), result.final_x);

    // First character: 中 (U+4E2D)
    try tc.expectCodepointAt(0, 0, 0x4E2D);
    try tc.expectCellWidth(0, 0, .wide_start);
    try tc.expectCodepointAt(1, 0, ' ');
    try tc.expectCellWidth(1, 0, .wide_end);

    // Second character: 文 (U+6587)
    try tc.expectCodepointAt(2, 0, 0x6587);
    try tc.expectCellWidth(2, 0, .wide_start);
    try tc.expectCodepointAt(3, 0, ' ');
    try tc.expectCellWidth(3, 0, .wide_end);
}

test "printAssumeNoGrapheme emoji" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    // "😀" - emoji, 2 cells wide
    const result = printAssumeNoGrapheme(tc.scissor(), "😀", 0, 0, .default);

    try testing.expectEqual(@as(usize, 4), result.bytes_consumed); // 4-byte emoji
    try testing.expectEqual(@as(usize, 1), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 2), result.final_x);

    // Emoji: 😀 (U+1F600)
    try tc.expectCodepointAt(0, 0, 0x1F600);
    try tc.expectCellWidth(0, 0, .wide_start);
    try tc.expectCodepointAt(1, 0, ' ');
    try tc.expectCellWidth(1, 0, .wide_end);
}

test "printAssumeNoGrapheme wide at boundary no wrap skips" {
    var tc = try TestContext.init(3, 3);
    defer tc.deinit();

    // "AB中" in 3-wide buffer without wrap
    // A at 0, B at 1, cursor at 2
    // 中 needs 2 cells but only 1 remains (position 2) so it will be skipped
    const result = printAssumeNoGrapheme(tc.scissor(), "AB中", 0, 0, .{ .wrap = false, .tab_width = 4 });

    try testing.expectEqual(@as(usize, 2), result.graphemes_rendered);

    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCellWidth(0, 0, .narrow);

    try tc.expectCodepointAt(1, 0, 'B');
    try tc.expectCellWidth(1, 0, .narrow);

    // Cell at position 2 should still be empty (space)
    try tc.expectCodepointAt(2, 0, ' ');
}

test "printAssumeNoGrapheme wide exactly fits" {
    var tc = try TestContext.init(4, 3);
    defer tc.deinit();

    // "AB中" in 4-wide buffer - 中 should exactly fit at positions 2-3
    const result = printAssumeNoGrapheme(tc.scissor(), "AB中", 0, 0, .default);

    try testing.expectEqual(@as(usize, 3), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 0), result.final_x);
    try testing.expectEqual(@as(u16, 1), result.final_y);

    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCodepointAt(1, 0, 'B');
    try tc.expectCodepointAt(2, 0, 0x4E2D);
    try tc.expectCellWidth(2, 0, .wide_start);
    try tc.expectCodepointAt(3, 0, ' ');
    try tc.expectCellWidth(3, 0, .wide_end);
}

test "printAssumeNoGrapheme skips zero-width" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    // Combining acute accent alone (not attached to base) - has width=0
    // "\xCC\x81" is combining acute accent (U+0301)
    // "A\xCC\x81B" = A + combining mark + B
    // printAssumeNoGrapheme should render A, skip combining mark, render B
    const result = printAssumeNoGrapheme(tc.scissor(), "A\xCC\x81B", 0, 0, .default);

    // A and B rendered, combining mark skipped (width=0)
    try testing.expectEqual(@as(usize, 4), result.bytes_consumed); // 1 + 2 + 1 bytes
    try testing.expectEqual(@as(usize, 2), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 2), result.final_x);

    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCodepointAt(1, 0, 'B');
}

test "printAssumeNoGrapheme zero-width joiner ignored" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    // ZWJ (U+200D) has width=0
    // "A\xE2\x80\x8DB" = A + ZWJ + B
    const result = printAssumeNoGrapheme(tc.scissor(), "A\xE2\x80\x8DB", 0, 0, .default);

    // A and B rendered, ZWJ skipped
    try testing.expectEqual(@as(usize, 5), result.bytes_consumed); // 1 + 3 + 1 bytes
    try testing.expectEqual(@as(usize, 2), result.graphemes_rendered);

    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCodepointAt(1, 0, 'B');
}

test "printAssumeNoGrapheme invalid UTF-8 replacement char" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    // Invalid UTF-8 bytes are rendered as replacement characters (U+FFFD)
    const result = printAssumeNoGrapheme(tc.scissor(), "\xFF\xFE", 0, 0, .default);

    // Each invalid byte becomes a replacement character
    try testing.expectEqual(@as(usize, 2), result.bytes_consumed);
    try testing.expectEqual(@as(usize, 2), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 2), result.final_x);

    // Both cells should contain U+FFFD (replacement character)
    try tc.expectCodepointAt(0, 0, 0xFFFD);
    try tc.expectCodepointAt(1, 0, 0xFFFD);
}

test "printAssumeNoGrapheme invalid mid-sequence" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    // Start valid UTF-8 sequence, interrupt with invalid byte
    // "\xC3\xFF" - starts 2-byte sequence, invalid continuation
    const result = printAssumeNoGrapheme(tc.scissor(), "\xC3\xFF", 0, 0, .default);

    // Should produce 2 replacement characters
    try testing.expectEqual(@as(usize, 2), result.bytes_consumed);
    try testing.expectEqual(@as(usize, 2), result.graphemes_rendered);

    try tc.expectCodepointAt(0, 0, 0xFFFD);
    try tc.expectCodepointAt(1, 0, 0xFFFD);
}

test "Scissor.fillRectangle fills partial region" {
    const cells = try testing.allocator.alloc(Cell, 50);
    defer testing.allocator.free(cells);
    var fb = try FrameBuffer.init(cells, 10, 5, .tiny);
    defer fb.deinit();

    fb.clear();

    const scissor = Scissor{
        .x_global = 0,
        .y_global = 0,
        .width_global = 10,
        .height_global = 5,
        .buffer = &fb,
    };

    scissor.fillRectangle(2, 1, 3, 2, Cell{ .data = .{ .codepoint = '*' } });

    // Check rectangle at (2,1) with size 3x2
    for (0..5) |y| {
        for (0..10) |x| {
            const expected: u21 = if (x >= 2 and x < 5 and y >= 1 and y < 3) '*' else ' ';
            try std.testing.expectEqual(expected, fb.cells[y * 10 + x].data.codepoint);
        }
    }
}
