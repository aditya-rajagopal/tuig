const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const log = std.log.scoped(.tui);
const e = @import("event.zig");
const Terminal = @import("terminal.zig").Terminal;

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

        const start_x: usize = std.math.clamp(start_x_int, 0, self.buffer.width - 1);
        const end_x: usize = std.math.clamp(end_x_int, 0, self.buffer.width);
        const start_y: usize = std.math.clamp(start_y_int, 0, self.buffer.height - 1);
        const end_y: usize = std.math.clamp(end_y_int, 0, self.buffer.height);

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

pub const max_cells = 640 * 480;
pub fn init(self: *Renderer, terminal: *Terminal, allocator: Allocator) error{OutOfMemory}!void {
    self.buffers[0] = try FrameBuffer.init(allocator, terminal.size.width, terminal.size.height, max_cells);
    self.buffers[1] = try FrameBuffer.init(allocator, terminal.size.width, terminal.size.height, max_cells);
    self.render_buffer = &self.buffers[0];
    self.back_buffer = &self.buffers[1];
    self.render_buffer.clear();
    self.back_buffer.clear();
    self.redraw = true;
    self.terminal = terminal;

    terminal.clearScreen() catch {};
}

pub fn deinit(self: *Renderer, allocator: Allocator) void {
    self.terminal.clearScreen() catch {};
    self.buffers[0].deinit(allocator);
    self.buffers[1].deinit(allocator);
}

pub fn beginFrame(self: *Renderer, events: []const e.Event) Scissor {
    for (events) |event| {
        switch (event) {
            .resize => |resize| {
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
    return Scissor{
        .global_x = 0,
        .global_y = 0,
        .width = self.terminal.size.width,
        .height = self.terminal.size.height,
        .buffer = self.render_buffer,
    };
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
}

pub fn swapBuffers(self: *Renderer) void {
    std.mem.swap(*FrameBuffer, &self.back_buffer, &self.render_buffer);
}
