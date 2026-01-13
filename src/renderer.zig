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

    pub fn renderTextDelimiter(
        self: *FrameBuffer,
        x: u16,
        y: u16,
        text: []const u8,
        num_codepoints: ?u16,
        delimiter: ?u21,
    ) usize {
        assert(x < self.width);
        assert(y < self.height);
        // @PERF this is probably slow
        const utf8 = std.unicode.Utf8View.init(text) catch return 0;
        var iter = utf8.iterator();
        var codepoints_written: u16 = 0;
        const limit = if (num_codepoints) |n| @min(n, self.width - x) else self.width - x;
        while (iter.nextCodepoint()) |codepoint| {
            // @INCOMPLETE text wrapping
            if (codepoints_written >= limit) {
                if (delimiter) |d| {
                    if (codepoint == d) break else continue;
                } else break;
            }
            self.set(codepoints_written + x, y, codepoint);
            codepoints_written += 1;
        }
        return iter.i;
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

pub fn beginFrame(self: *Renderer, events: []const e.Event) void {
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
}

pub fn endFrame(self: *Renderer) void {
    if (self.redraw) {
        log.info("redrawing", .{});
        for (0..self.terminal.size.height) |row| {
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
            const row_start: u32 = @intCast(row * self.terminal.size.width);
            const row_end: u32 = row_start + self.terminal.size.width;
            var col: u16 = 0;
            while (col < self.render_buffer.width) {
                var start: u32 = row_start + col;
                while (start < row_end and !self.back_buffer.cells[start].eql(self.render_buffer.cells[start])) : (start += 1) {}
                var end: u32 = start;
                while (end < row_end and self.back_buffer.cells[end].eql(self.render_buffer.cells[end])) : (end += 1) {}
                self.terminal.setCursorPosition(@truncate(start - row_start), @truncate(row)) catch {};
                const unicode_row = self.render_buffer.cells[start..end];
                for (unicode_row) |cell| {
                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(cell.codepoint, &buf) catch continue;
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
