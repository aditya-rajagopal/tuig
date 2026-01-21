const std = @import("std");

const stdx = @import("stdx");
const assert = stdx.inlineAssert;

const FrameBuffer = @import("FrameBuffer.zig");
const Cell = @import("root.zig").Cell;

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
        @memset(self.buffer.cells.reserved_pages[start..end], cell);
    } else {
        for (start_y..end_y) |row| {
            const start = row * self.buffer.width;
            @memset(self.buffer.cells.reserved_pages[start..][start_x..end_x], cell);
        }
    }
}

pub fn fill(self: Scissor, cell: Cell) void {
    self.fillRectangle(0, 0, self.width_global, self.height_global, cell);
}

pub fn renderLineDelimiter(
    self: Scissor,
    x_offset: u16,
    y_offset: u16,
    text: []const u8,
    delimiter: ?u21,
    consume_till_delimiter: bool,
) usize {
    if (x_offset >= self.width_global) return 0;
    if (y_offset >= self.height_global) return 0;

    var cursor_x: i17 = self.x_global + x_offset;
    const cursor_y_int: i17 = self.y_global + y_offset;

    if (cursor_x >= self.buffer.width) return 0;
    if (cursor_y_int < 0 or cursor_y_int >= self.buffer.height) return 0;
    const cursor_y: u16 = @intCast(cursor_y_int);

    const limit_x: i17 = @min(self.x_global + self.width_global, self.buffer.width);
    if (limit_x < 0) return 0;

    const utf8 = std.unicode.Utf8View.init(text) catch return 0;
    var iter = utf8.iterator();

    if (delimiter) |d| {
        while (iter.nextCodepoint()) |codepoint| : (cursor_x += 1) {
            if (codepoint == d) break;
            if (cursor_x >= limit_x) {
                if (consume_till_delimiter) continue else break;
            }
            if (cursor_x < 0) continue;

            self.buffer.set(@intCast(cursor_x), cursor_y, Cell{ .codepoint = codepoint });
        }
    } else {
        while (iter.nextCodepoint()) |codepoint| : (cursor_x += 1) {
            if (cursor_x < 0) continue;
            if (cursor_x == limit_x) break;

            self.buffer.set(@intCast(cursor_x), cursor_y, Cell{ .codepoint = codepoint });
        }
    }
    return iter.i;
}

pub fn clear(self: Scissor) void {
    self.fill(.empty);
}
