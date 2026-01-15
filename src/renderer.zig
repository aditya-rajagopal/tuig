const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const log = std.log.scoped(.tui);
const e = @import("event.zig");
const Terminal = @import("terminal.zig").Terminal;

pub const Context = struct {
    frame_arena: *std.heap.ArenaAllocator = undefined,
    events: []const e.Event = undefined,
    scissor: Scissor = undefined,
    key_pressed: ?e.KeyEvent = null,
    resize: ?e.ResizeEvent = null,
    mouse_scroll: i8 = 0,

    pub fn isKeyPressed(self: Context, code: e.KeyEvent.Code) bool {
        if (self.key_pressed) |key| {
            return key.code == code;
        } else {
            return false;
        }
    }
};

test "Print size" {
    std.debug.print("sizeof(Context.Mouse): {d}\n", .{@sizeOf(Context.Mouse)});
    std.debug.print("Alignof(Context.Mouse): {d}\n", .{@alignOf(Context.Mouse)});
    std.debug.print("sizeof(Context): {d}\n", .{@sizeOf(Context)});
    std.debug.print("Alignof(Context): {d}\n", .{@alignOf(Context)});
}

pub const Cell = struct {
    codepoint: u21,

    pub fn eql(self: Cell, other: Cell) bool {
        return self.codepoint == other.codepoint;
    }
};

pub const Scissor = struct {
    global_x: i17,
    global_y: i17,
    width: u16,
    height: u16,
    buffer: *FrameBuffer,

    pub fn initChild(self: Scissor, offset_x: i17, offset_y: i17, width: u16, height: u16) Scissor {
        assert(offset_x + width <= self.width);
        assert(offset_y + height <= self.height);
        return Scissor{
            .global_x = self.global_x + offset_x,
            .global_y = self.global_y + offset_y,
            .width = width,
            .height = height,
            .buffer = self.buffer,
        };
    }

    pub fn fillRectangle(self: Scissor, offset_x: u16, offset_y: u16, width: u16, height: u16, cell: Cell) void {
        if (offset_x >= self.width or offset_y >= self.height) return;
        if (width == 0 or height == 0) return;

        const start_x_int: i17 = self.global_x + offset_x;
        const end_x_int: i17 = start_x_int + width;
        const start_y_int: i17 = self.global_y + offset_y;
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
        self.fillRectangle(0, 0, self.width, self.height, cell);
    }

    pub fn renderLineDelimiter(
        self: Scissor,
        offset_x: u16,
        offset_y: u16,
        text: []const u8,
        delimiter: ?u21,
        consume_till_delimiter: bool,
    ) usize {
        if (offset_x >= self.width) return 0;
        if (offset_y >= self.height) return 0;

        var cursor_x: i17 = self.global_x + offset_x;
        const cursor_y_int: i17 = self.global_y + offset_y;

        if (cursor_x >= self.buffer.width) return 0;
        if (cursor_y_int < 0 or cursor_y_int >= self.buffer.height) return 0;
        const cursor_y: u16 = @intCast(cursor_y_int);

        const limit_x: i17 = @min(self.global_x + self.width, self.buffer.width);
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

                self.buffer.set(@intCast(cursor_x), cursor_y, codepoint);
            }
        } else {
            while (iter.nextCodepoint()) |codepoint| : (cursor_x += 1) {
                if (cursor_x < 0) continue;
                if (cursor_x == limit_x) break;

                self.buffer.set(@intCast(cursor_x), cursor_y, codepoint);
            }
        }
        return iter.i;
    }

    pub fn clear(self: Scissor) void {
        self.fill(Cell{ .codepoint = ' ' });
    }

    /// Copy cells from a source FrameBuffer to this scissor at the given offset.
    ///
    /// Useful for compositing temporary render buffers into the main buffer.
    /// Handles clipping at scissor and buffer boundaries.
    pub fn blitFrom(self: Scissor, source: *const FrameBuffer, offset_x: u16, offset_y: u16) void {
        if (offset_x >= self.width or offset_y >= self.height) return;
        if (source.width == 0 or source.height == 0) return;

        const dest_x_start: i17 = self.global_x + @as(i17, offset_x);
        const dest_y_start: i17 = self.global_y + @as(i17, offset_y);

        // Early exit if completely outside buffer
        if (dest_x_start >= self.buffer.width) return;
        if (dest_y_start >= self.buffer.height) return;

        // Calculate clipped region
        const copy_width: u16 = @min(source.width, self.width - offset_x);
        const copy_height: u16 = @min(source.height, self.height - offset_y);

        // Calculate source start offset (for negative dest coordinates)
        var src_x_start: u16 = 0;
        var src_y_start: u16 = 0;
        var actual_dest_x: u16 = undefined;
        var actual_dest_y: u16 = undefined;

        if (dest_x_start < 0) {
            src_x_start = @intCast(-dest_x_start);
            actual_dest_x = 0;
        } else {
            actual_dest_x = @intCast(dest_x_start);
        }

        if (dest_y_start < 0) {
            src_y_start = @intCast(-dest_y_start);
            actual_dest_y = 0;
        } else {
            actual_dest_y = @intCast(dest_y_start);
        }

        // Calculate actual copy dimensions after clipping
        const actual_copy_width = copy_width -| src_x_start;
        const actual_copy_height = copy_height -| src_y_start;

        if (actual_copy_width == 0 or actual_copy_height == 0) return;

        // Clip to destination buffer bounds
        const final_width = @min(actual_copy_width, self.buffer.width - actual_dest_x);
        const final_height = @min(actual_copy_height, self.buffer.height - actual_dest_y);

        // Copy row by row
        for (0..final_height) |row| {
            const src_row = src_y_start + @as(u16, @intCast(row));
            const dest_row = actual_dest_y + @as(u16, @intCast(row));

            if (src_row >= source.height or dest_row >= self.buffer.height) break;

            const src_start = @as(usize, src_row) * source.width + src_x_start;
            const dest_start = @as(usize, dest_row) * self.buffer.width + actual_dest_x;

            const src_end = src_start + final_width;
            const dest_end = dest_start + final_width;

            if (src_end <= source.cells.len and dest_end <= self.buffer.cells.len) {
                @memcpy(self.buffer.cells[dest_start..dest_end], source.cells[src_start..src_end]);
            }
        }
    }
};

pub const FrameBuffer = struct {
    cells: []Cell,
    width: u16,
    height: u16,
    capacity: usize,

    pub fn init(allocator: Allocator, width: u16, height: u16, max_capacity: ?usize) error{OutOfMemory}!FrameBuffer {
        if (max_capacity) |max| {
            assert(max >= width * height);
        }
        var buffer: FrameBuffer = undefined;
        const capacity = max_capacity orelse width * height;
        // @FIXME look at allignemnt
        buffer.cells = try allocator.alloc(Cell, capacity);
        buffer.width = width;
        buffer.height = height;
        buffer.capacity = capacity;
        buffer.cells.len = width * height;
        return buffer;
    }

    pub fn deinit(self: *FrameBuffer, allocator: Allocator) void {
        // Restore original allocation size before freeing
        self.cells.len = self.capacity;
        allocator.free(self.cells);
    }

    pub fn set(self: *FrameBuffer, x: u16, y: u16, codepoint: u21) void {
        assert(x < self.width);
        assert(y < self.height);
        assert(y * self.width + x < self.cells.len);
        self.cells[y * self.width + x] = Cell{ .codepoint = codepoint };
    }

    pub fn clear(self: *FrameBuffer) void {
        @memset(self.cells, Cell{ .codepoint = ' ' });
    }
};

pub const Renderer = @This();

buffers: [2]FrameBuffer,
render_buffer: *FrameBuffer,
back_buffer: *FrameBuffer,
terminal: *Terminal,
redraw: bool = true,
arena: std.heap.ArenaAllocator,

// @HACK this is temporary
pub const max_cells = 640 * 480;

pub fn init(self: *Renderer, terminal: *Terminal, allocator: Allocator, arena_preheat: ?usize) error{OutOfMemory}!void {
    self.buffers[0] = try FrameBuffer.init(allocator, terminal.size.width, terminal.size.height, max_cells);
    self.buffers[1] = try FrameBuffer.init(allocator, terminal.size.width, terminal.size.height, max_cells);
    self.render_buffer = &self.buffers[0];
    self.back_buffer = &self.buffers[1];
    self.render_buffer.clear();
    self.back_buffer.clear();
    self.redraw = true;
    self.terminal = terminal;
    self.arena = std.heap.ArenaAllocator.init(allocator);
    if (arena_preheat) |n| {
        _ = try self.arena.allocator().alloc(u8, n);
        _ = self.arena.reset(.retain_capacity);
    }

    terminal.clearScreen() catch {};
}

pub fn deinit(self: *Renderer, allocator: Allocator) void {
    self.terminal.clearScreen() catch {};
    self.buffers[0].deinit(allocator);
    self.buffers[1].deinit(allocator);
}

pub fn beginFrame(self: *Renderer, events: []const e.Event) Context {
    var ctx: Context = .{
        .frame_arena = &self.arena,
        .events = events,
    };
    for (events) |event| {
        switch (event) {
            .key_pressed, .key_repeat => |key| {
                ctx.key_pressed = key;
            },
            .mouse_scroll_up => {
                ctx.mouse_scroll += 1;
            },
            .mouse_scroll_down => {
                ctx.mouse_scroll -= 1;
            },
            .resize => |resize| {
                ctx.resize = resize;
                const new_cells = resize.width * resize.height;
                if (new_cells > max_cells) {
                    log.err("Resized to too large a size", .{});
                    return;
                }
                self.buffers[0].cells.len = new_cells;
                self.buffers[1].cells.len = new_cells;
                self.buffers[0].width = resize.width;
                self.buffers[0].height = resize.height;
                self.buffers[1].width = resize.width;
                self.buffers[1].height = resize.height;
                self.redraw = true;
                self.terminal.clearScreen() catch {};
            },
            else => {},
        }
    }
    self.render_buffer.clear();
    ctx.scissor = Scissor{
        .global_x = 0,
        .global_y = 0,
        .width = self.terminal.size.width,
        .height = self.terminal.size.height,
        .buffer = self.render_buffer,
    };
    return ctx;
}

pub fn endFrame(self: *Renderer) void {
    if (self.redraw) {
        for (0..self.render_buffer.height) |row| {
            self.terminal.setCursorPosition(0, @truncate(row)) catch {};
            const unicode_row = self.render_buffer.cells[row * self.render_buffer.width ..][0..self.render_buffer.width];
            for (unicode_row) |cell| {
                var buf: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cell.codepoint, &buf) catch continue;
                self.terminal.write(buf[0..len]) catch {};
            }
        }
        self.redraw = false;
    } else {
        @branchHint(.likely);
        for (0..self.render_buffer.height) |row| {
            const row_start: u32 = @intCast(row * self.render_buffer.width);
            const row_end: u32 = row_start + self.render_buffer.width;
            var col: u16 = 0;
            while (col < self.render_buffer.width) {
                var start: u32 = row_start + col;
                while (start < row_end and self.back_buffer.cells[start].eql(self.render_buffer.cells[start])) : (start += 1) {}
                var end: u32 = start;
                while (end < row_end and !self.back_buffer.cells[end].eql(self.render_buffer.cells[end])) : (end += 1) {}
                self.terminal.setCursorPosition(@truncate(start - row_start), @truncate(row)) catch {};
                const unicode_row = self.render_buffer.cells[start..end];
                for (unicode_row) |cell| {
                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(cell.codepoint, &buf) catch unreachable;
                    self.terminal.write(buf[0..len]) catch {};
                }
                col = @intCast(end - row_start);
            }
        }
    }
    self.terminal.flush() catch {};
    self.swapBuffers();
    _ = self.arena.reset(.retain_capacity);
}

pub fn swapBuffers(self: *Renderer) void {
    std.mem.swap(*FrameBuffer, &self.back_buffer, &self.render_buffer);
}

// =============================================================================
// Tests
// =============================================================================

test "Cell.eql returns true for matching codepoints" {
    const a = Cell{ .codepoint = 'A' };
    const b = Cell{ .codepoint = 'A' };
    const c = Cell{ .codepoint = 'B' };

    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
}

test "Cell.eql works with unicode codepoints" {
    const emoji1 = Cell{ .codepoint = '🎉' };
    const emoji2 = Cell{ .codepoint = '🎉' };
    const emoji3 = Cell{ .codepoint = '🚀' };

    try std.testing.expect(emoji1.eql(emoji2));
    try std.testing.expect(!emoji1.eql(emoji3));
}

test "FrameBuffer.init allocates correct size" {
    const allocator = std.testing.allocator;
    var fb = try FrameBuffer.init(allocator, 10, 5, null);
    defer fb.deinit(allocator);

    try std.testing.expectEqual(@as(u16, 10), fb.width);
    try std.testing.expectEqual(@as(u16, 5), fb.height);
    try std.testing.expectEqual(@as(usize, 50), fb.cells.len);
}

test "FrameBuffer.init with max_capacity allocates extra space" {
    const allocator = std.testing.allocator;
    var fb = try FrameBuffer.init(allocator, 10, 5, 100);
    defer fb.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 100), fb.capacity);
    try std.testing.expectEqual(@as(usize, 50), fb.cells.len);
}

test "FrameBuffer.set writes cell at correct position" {
    const allocator = std.testing.allocator;
    var fb = try FrameBuffer.init(allocator, 10, 5, null);
    defer fb.deinit(allocator);

    fb.set(3, 2, 'X');

    // Position (3, 2) = index 2 * 10 + 3 = 23
    try std.testing.expectEqual(@as(u21, 'X'), fb.cells[23].codepoint);
}

test "FrameBuffer.clear fills with spaces" {
    const allocator = std.testing.allocator;
    var fb = try FrameBuffer.init(allocator, 5, 3, null);
    defer fb.deinit(allocator);

    // Set some cells first
    fb.set(0, 0, 'A');
    fb.set(2, 1, 'B');
    fb.set(4, 2, 'C');

    fb.clear();

    for (fb.cells) |cell| {
        try std.testing.expectEqual(@as(u21, ' '), cell.codepoint);
    }
}

test "Scissor.initChild creates correct child region" {
    const allocator = std.testing.allocator;
    var fb = try FrameBuffer.init(allocator, 20, 10, null);
    defer fb.deinit(allocator);

    const parent = Scissor{
        .global_x = 5,
        .global_y = 3,
        .width = 15,
        .height = 7,
        .buffer = &fb,
    };

    const child = parent.initChild(2, 1, 10, 4);

    try std.testing.expectEqual(@as(i17, 7), child.global_x);
    try std.testing.expectEqual(@as(i17, 4), child.global_y);
    try std.testing.expectEqual(@as(u16, 10), child.width);
    try std.testing.expectEqual(@as(u16, 4), child.height);
    try std.testing.expect(child.buffer == &fb);
}

test "Scissor.fill fills entire scissor region" {
    const allocator = std.testing.allocator;
    var fb = try FrameBuffer.init(allocator, 10, 5, null);
    defer fb.deinit(allocator);

    fb.clear();

    const scissor = Scissor{
        .global_x = 2,
        .global_y = 1,
        .width = 4,
        .height = 2,
        .buffer = &fb,
    };

    scissor.fill(Cell{ .codepoint = '#' });

    // Check that only the scissor region was filled
    // Row 1: positions 2-5 should be '#'
    // Row 2: positions 2-5 should be '#'
    for (0..5) |y| {
        for (0..10) |x| {
            const expected: u21 = if (x >= 2 and x < 6 and y >= 1 and y < 3) '#' else ' ';
            try std.testing.expectEqual(expected, fb.cells[y * 10 + x].codepoint);
        }
    }
}

test "Scissor.clear fills with spaces" {
    const allocator = std.testing.allocator;
    var fb = try FrameBuffer.init(allocator, 10, 5, null);
    defer fb.deinit(allocator);

    // Fill buffer with non-space chars
    @memset(fb.cells, Cell{ .codepoint = 'X' });

    const scissor = Scissor{
        .global_x = 1,
        .global_y = 1,
        .width = 3,
        .height = 2,
        .buffer = &fb,
    };

    scissor.clear();

    // Check scissor region is spaces, rest is X
    for (0..5) |y| {
        for (0..10) |x| {
            const expected: u21 = if (x >= 1 and x < 4 and y >= 1 and y < 3) ' ' else 'X';
            try std.testing.expectEqual(expected, fb.cells[y * 10 + x].codepoint);
        }
    }
}

test "Scissor.fillRectangle fills partial region" {
    const allocator = std.testing.allocator;
    var fb = try FrameBuffer.init(allocator, 10, 5, null);
    defer fb.deinit(allocator);

    fb.clear();

    const scissor = Scissor{
        .global_x = 0,
        .global_y = 0,
        .width = 10,
        .height = 5,
        .buffer = &fb,
    };

    scissor.fillRectangle(2, 1, 3, 2, Cell{ .codepoint = '*' });

    // Check rectangle at (2,1) with size 3x2
    for (0..5) |y| {
        for (0..10) |x| {
            const expected: u21 = if (x >= 2 and x < 5 and y >= 1 and y < 3) '*' else ' ';
            try std.testing.expectEqual(expected, fb.cells[y * 10 + x].codepoint);
        }
    }
}

test "Scissor.fillRectangle clips to buffer bounds" {
    const allocator = std.testing.allocator;
    var fb = try FrameBuffer.init(allocator, 10, 5, null);
    defer fb.deinit(allocator);

    fb.clear();

    const scissor = Scissor{
        .global_x = 0,
        .global_y = 0,
        .width = 10,
        .height = 5,
        .buffer = &fb,
    };

    // Rectangle extends beyond buffer
    scissor.fillRectangle(8, 3, 5, 5, Cell{ .codepoint = '+' });

    // Should only fill positions within buffer: x=8-9, y=3-4
    for (0..5) |y| {
        for (0..10) |x| {
            const expected: u21 = if (x >= 8 and y >= 3) '+' else ' ';
            try std.testing.expectEqual(expected, fb.cells[y * 10 + x].codepoint);
        }
    }
}

test "Scissor.fillRectangle returns early for zero dimensions" {
    const allocator = std.testing.allocator;
    var fb = try FrameBuffer.init(allocator, 10, 5, null);
    defer fb.deinit(allocator);

    fb.clear();

    const scissor = Scissor{
        .global_x = 0,
        .global_y = 0,
        .width = 10,
        .height = 5,
        .buffer = &fb,
    };

    // Zero width
    scissor.fillRectangle(0, 0, 0, 5, Cell{ .codepoint = 'X' });
    // Zero height
    scissor.fillRectangle(0, 0, 5, 0, Cell{ .codepoint = 'X' });

    // Nothing should change
    for (fb.cells) |cell| {
        try std.testing.expectEqual(@as(u21, ' '), cell.codepoint);
    }
}

test "Scissor.renderLineDelimiter renders text" {
    const allocator = std.testing.allocator;
    var fb = try FrameBuffer.init(allocator, 20, 5, null);
    defer fb.deinit(allocator);

    fb.clear();

    const scissor = Scissor{
        .global_x = 0,
        .global_y = 0,
        .width = 20,
        .height = 5,
        .buffer = &fb,
    };

    const consumed = scissor.renderLineDelimiter(2, 1, "Hello", null, false);

    try std.testing.expectEqual(@as(usize, 5), consumed);

    // Check "Hello" at position (2, 1)
    try std.testing.expectEqual(@as(u21, 'H'), fb.cells[1 * 20 + 2].codepoint);
    try std.testing.expectEqual(@as(u21, 'e'), fb.cells[1 * 20 + 3].codepoint);
    try std.testing.expectEqual(@as(u21, 'l'), fb.cells[1 * 20 + 4].codepoint);
    try std.testing.expectEqual(@as(u21, 'l'), fb.cells[1 * 20 + 5].codepoint);
    try std.testing.expectEqual(@as(u21, 'o'), fb.cells[1 * 20 + 6].codepoint);
}

test "Scissor.renderLineDelimiter stops at delimiter" {
    const allocator = std.testing.allocator;
    var fb = try FrameBuffer.init(allocator, 20, 5, null);
    defer fb.deinit(allocator);

    fb.clear();

    const scissor = Scissor{
        .global_x = 0,
        .global_y = 0,
        .width = 20,
        .height = 5,
        .buffer = &fb,
    };

    const consumed = scissor.renderLineDelimiter(0, 0, "foo\nbar", '\n', false);

    try std.testing.expectEqual(@as(usize, 4), consumed); // "foo\n"

    try std.testing.expectEqual(@as(u21, 'f'), fb.cells[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'o'), fb.cells[1].codepoint);
    try std.testing.expectEqual(@as(u21, 'o'), fb.cells[2].codepoint);
    try std.testing.expectEqual(@as(u21, ' '), fb.cells[3].codepoint); // Not overwritten
}

test "Scissor.renderLineDelimiter clips to scissor width" {
    const allocator = std.testing.allocator;
    var fb = try FrameBuffer.init(allocator, 20, 5, null);
    defer fb.deinit(allocator);

    fb.clear();

    const scissor = Scissor{
        .global_x = 0,
        .global_y = 0,
        .width = 5,
        .height = 5,
        .buffer = &fb,
    };

    _ = scissor.renderLineDelimiter(0, 0, "Hello World", null, false);

    // Only "Hello" should be rendered (5 chars)
    try std.testing.expectEqual(@as(u21, 'H'), fb.cells[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'e'), fb.cells[1].codepoint);
    try std.testing.expectEqual(@as(u21, 'l'), fb.cells[2].codepoint);
    try std.testing.expectEqual(@as(u21, 'l'), fb.cells[3].codepoint);
    try std.testing.expectEqual(@as(u21, 'o'), fb.cells[4].codepoint);
    try std.testing.expectEqual(@as(u21, ' '), fb.cells[5].codepoint); // Beyond scissor
}

test "Scissor.renderLineDelimiter returns 0 for out of bounds" {
    const allocator = std.testing.allocator;
    var fb = try FrameBuffer.init(allocator, 10, 5, null);
    defer fb.deinit(allocator);

    const scissor = Scissor{
        .global_x = 0,
        .global_y = 0,
        .width = 10,
        .height = 5,
        .buffer = &fb,
    };

    // offset_x beyond width
    try std.testing.expectEqual(@as(usize, 0), scissor.renderLineDelimiter(15, 0, "test", null, false));
    // offset_y beyond height
    try std.testing.expectEqual(@as(usize, 0), scissor.renderLineDelimiter(0, 10, "test", null, false));
}

test "Scissor.renderLineDelimiter handles unicode" {
    const allocator = std.testing.allocator;
    var fb = try FrameBuffer.init(allocator, 20, 5, null);
    defer fb.deinit(allocator);

    fb.clear();

    const scissor = Scissor{
        .global_x = 0,
        .global_y = 0,
        .width = 20,
        .height = 5,
        .buffer = &fb,
    };

    _ = scissor.renderLineDelimiter(0, 0, "日本語", null, false);

    try std.testing.expectEqual(@as(u21, '日'), fb.cells[0].codepoint);
    try std.testing.expectEqual(@as(u21, '本'), fb.cells[1].codepoint);
    try std.testing.expectEqual(@as(u21, '語'), fb.cells[2].codepoint);
}

test "Scissor.blitFrom copies source buffer" {
    const allocator = std.testing.allocator;
    var dest_fb = try FrameBuffer.init(allocator, 10, 5, null);
    defer dest_fb.deinit(allocator);
    var src_fb = try FrameBuffer.init(allocator, 3, 2, null);
    defer src_fb.deinit(allocator);

    dest_fb.clear();

    // Fill source with pattern
    src_fb.set(0, 0, 'A');
    src_fb.set(1, 0, 'B');
    src_fb.set(2, 0, 'C');
    src_fb.set(0, 1, 'D');
    src_fb.set(1, 1, 'E');
    src_fb.set(2, 1, 'F');

    const scissor = Scissor{
        .global_x = 0,
        .global_y = 0,
        .width = 10,
        .height = 5,
        .buffer = &dest_fb,
    };

    scissor.blitFrom(&src_fb, 2, 1);

    // Check source was copied to (2, 1)
    try std.testing.expectEqual(@as(u21, 'A'), dest_fb.cells[1 * 10 + 2].codepoint);
    try std.testing.expectEqual(@as(u21, 'B'), dest_fb.cells[1 * 10 + 3].codepoint);
    try std.testing.expectEqual(@as(u21, 'C'), dest_fb.cells[1 * 10 + 4].codepoint);
    try std.testing.expectEqual(@as(u21, 'D'), dest_fb.cells[2 * 10 + 2].codepoint);
    try std.testing.expectEqual(@as(u21, 'E'), dest_fb.cells[2 * 10 + 3].codepoint);
    try std.testing.expectEqual(@as(u21, 'F'), dest_fb.cells[2 * 10 + 4].codepoint);

    // Check rest is still spaces
    try std.testing.expectEqual(@as(u21, ' '), dest_fb.cells[0].codepoint);
    try std.testing.expectEqual(@as(u21, ' '), dest_fb.cells[1 * 10 + 0].codepoint);
}

test "Scissor.blitFrom clips at destination bounds" {
    const allocator = std.testing.allocator;
    var dest_fb = try FrameBuffer.init(allocator, 5, 3, null);
    defer dest_fb.deinit(allocator);
    var src_fb = try FrameBuffer.init(allocator, 4, 4, null);
    defer src_fb.deinit(allocator);

    dest_fb.clear();

    // Fill source
    for (0..4) |y| {
        for (0..4) |x| {
            src_fb.set(@intCast(x), @intCast(y), 'X');
        }
    }

    const scissor = Scissor{
        .global_x = 0,
        .global_y = 0,
        .width = 5,
        .height = 3,
        .buffer = &dest_fb,
    };

    // Blit at position (3, 1) - will clip to destination bounds
    scissor.blitFrom(&src_fb, 3, 1);

    // Only positions (3,1), (4,1), (3,2), (4,2) should be filled
    try std.testing.expectEqual(@as(u21, ' '), dest_fb.cells[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'X'), dest_fb.cells[1 * 5 + 3].codepoint);
    try std.testing.expectEqual(@as(u21, 'X'), dest_fb.cells[1 * 5 + 4].codepoint);
    try std.testing.expectEqual(@as(u21, 'X'), dest_fb.cells[2 * 5 + 3].codepoint);
    try std.testing.expectEqual(@as(u21, 'X'), dest_fb.cells[2 * 5 + 4].codepoint);
}

test "Scissor.blitFrom returns early for out of bounds offset" {
    const allocator = std.testing.allocator;
    var dest_fb = try FrameBuffer.init(allocator, 5, 3, null);
    defer dest_fb.deinit(allocator);
    var src_fb = try FrameBuffer.init(allocator, 2, 2, null);
    defer src_fb.deinit(allocator);

    dest_fb.clear();
    @memset(src_fb.cells, Cell{ .codepoint = 'X' });

    const scissor = Scissor{
        .global_x = 0,
        .global_y = 0,
        .width = 5,
        .height = 3,
        .buffer = &dest_fb,
    };

    // Offset beyond scissor bounds
    scissor.blitFrom(&src_fb, 10, 0);
    scissor.blitFrom(&src_fb, 0, 10);

    // Nothing should change
    for (dest_fb.cells) |cell| {
        try std.testing.expectEqual(@as(u21, ' '), cell.codepoint);
    }
}

test "Scissor.blitFrom handles empty source" {
    const allocator = std.testing.allocator;
    var dest_fb = try FrameBuffer.init(allocator, 5, 3, null);
    defer dest_fb.deinit(allocator);
    var src_fb = try FrameBuffer.init(allocator, 0, 0, null);
    defer src_fb.deinit(allocator);

    @memset(dest_fb.cells, Cell{ .codepoint = 'Y' });

    const scissor = Scissor{
        .global_x = 0,
        .global_y = 0,
        .width = 5,
        .height = 3,
        .buffer = &dest_fb,
    };

    scissor.blitFrom(&src_fb, 0, 0);

    // Nothing should change
    for (dest_fb.cells) |cell| {
        try std.testing.expectEqual(@as(u21, 'Y'), cell.codepoint);
    }
}

test "Scissor with negative global coordinates handles fillRectangle" {
    const allocator = std.testing.allocator;
    var fb = try FrameBuffer.init(allocator, 10, 5, null);
    defer fb.deinit(allocator);

    fb.clear();

    // Scissor with negative global position (partially off-screen)
    const scissor = Scissor{
        .global_x = -2,
        .global_y = -1,
        .width = 6,
        .height = 4,
        .buffer = &fb,
    };

    scissor.fillRectangle(0, 0, 6, 4, Cell{ .codepoint = '#' });

    // Only visible portion should be filled
    // global_x + offset_x = -2 + 0 = -2, clips to 0
    // global_y + offset_y = -1 + 0 = -1, clips to 0
    // end_x = -2 + 6 = 4
    // end_y = -1 + 4 = 3
    for (0..5) |y| {
        for (0..10) |x| {
            const expected: u21 = if (x < 4 and y < 3) '#' else ' ';
            try std.testing.expectEqual(expected, fb.cells[y * 10 + x].codepoint);
        }
    }
}

test "Scissor.fillRectangle uses optimized memset for full-width rows" {
    const allocator = std.testing.allocator;
    var fb = try FrameBuffer.init(allocator, 10, 5, null);
    defer fb.deinit(allocator);

    fb.clear();

    // Scissor covering full width
    const scissor = Scissor{
        .global_x = 0,
        .global_y = 0,
        .width = 10,
        .height = 5,
        .buffer = &fb,
    };

    // Fill full width - should use optimized path
    scissor.fillRectangle(0, 1, 10, 2, Cell{ .codepoint = '=' });

    // Check rows 1 and 2 are filled
    for (0..5) |y| {
        for (0..10) |x| {
            const expected: u21 = if (y >= 1 and y < 3) '=' else ' ';
            try std.testing.expectEqual(expected, fb.cells[y * 10 + x].codepoint);
        }
    }
}
