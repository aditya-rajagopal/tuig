const std = @import("std");
const Allocator = std.mem.Allocator;

const log = std.log.scoped(.tui);

const term = @import("terminal");
const Terminal = term.Terminal;
const Event = term.Event;
const KeyEvent = term.KeyEvent;
const MouseEvent = term.MouseEvent;

const t = @import("types.zig");
const MouseState = t.MouseState;
const Context = @import("Context.zig");
const FrameBuffer = @import("FrameBuffer.zig");
const Scissor = @import("Scissor.zig");
const Cell = @import("Cell.zig");

const Renderer = @This();

buffers: [2]FrameBuffer,
render_buffer: *FrameBuffer,
back_buffer: *FrameBuffer,
terminal: *Terminal,
redraw: bool = true,
arena: std.heap.ArenaAllocator,
mouse_x: u16 = 0,
mouse_y: u16 = 0,
current_mouse_down: MouseState = .{},
previous_mouse_down: MouseState = .{},

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
    self.current_mouse_down = .{};
    self.previous_mouse_down = .{};

    terminal.clearScreen() catch {};
}

pub fn deinit(self: *Renderer, allocator: Allocator) void {
    self.terminal.clearScreen() catch {};
    self.buffers[0].deinit(allocator);
    self.buffers[1].deinit(allocator);
}

pub fn beginFrame(self: *Renderer, events: []const Event) Context {
    var ctx: Context = .{
        .frame_arena = &self.arena,
        .events = events,
    };
    for (events) |event| {
        switch (event) {
            .key_pressed, .key_repeat => |key| {
                ctx.key_pressed = key;
            },
            .mouse_scroll_up => |info| {
                self.mouse_x = info.x - 1;
                self.mouse_y = info.y - 1;
                ctx.mouse_scroll += 1;
            },
            .mouse_scroll_down => |info| {
                self.mouse_x = info.x - 1;
                self.mouse_y = info.y - 1;
                ctx.mouse_scroll -= 1;
            },
            .mouse_move => |info| {
                self.mouse_x = info.x - 1;
                self.mouse_y = info.y - 1;
            },
            .mouse_left_pressed,
            .mouse_left_released,
            .mouse_right_pressed,
            .mouse_right_released,
            .mouse_drag_left,
            .mouse_drag_middle,
            .mouse_drag_right,
            .mouse_middle_pressed,
            .mouse_middle_released,
            .mouse_released,
            => |info| {
                self.mouse_x = info.x - 1;
                self.mouse_y = info.y - 1;
                switch (event) {
                    .mouse_left_pressed => self.current_mouse_down.left = true,
                    .mouse_left_released => self.current_mouse_down.left = false,
                    .mouse_right_pressed => self.current_mouse_down.right = true,
                    .mouse_right_released => self.current_mouse_down.right = false,
                    .mouse_middle_pressed => self.current_mouse_down.middle = true,
                    .mouse_middle_released => self.current_mouse_down.middle = false,
                    .mouse_drag_left => self.current_mouse_down.left = true,
                    .mouse_drag_middle => self.current_mouse_down.middle = true,
                    .mouse_drag_right => self.current_mouse_down.right = true,
                    .mouse_released => {
                        self.current_mouse_down.left = false;
                        self.current_mouse_down.right = false;
                        self.current_mouse_down.middle = false;
                    },
                    else => unreachable,
                }
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
    ctx.mouse_x = self.mouse_x;
    ctx.mouse_y = self.mouse_y;

    ctx.mouse_down.left = self.current_mouse_down.left and self.previous_mouse_down.left;
    ctx.mouse_down.right = self.current_mouse_down.right and self.previous_mouse_down.right;
    ctx.mouse_down.middle = self.current_mouse_down.middle and self.previous_mouse_down.middle;
    ctx.mouse_pressed.left = self.current_mouse_down.left and !self.previous_mouse_down.left;
    ctx.mouse_pressed.right = self.current_mouse_down.right and !self.previous_mouse_down.right;
    ctx.mouse_pressed.middle = self.current_mouse_down.middle and !self.previous_mouse_down.middle;
    ctx.mouse_released.left = !self.current_mouse_down.left and self.previous_mouse_down.left;
    ctx.mouse_released.right = !self.current_mouse_down.right and self.previous_mouse_down.right;
    ctx.mouse_released.middle = !self.current_mouse_down.middle and self.previous_mouse_down.middle;

    ctx.scissor = self.render_buffer.scissor();
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
    self.previous_mouse_down = self.current_mouse_down;
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

    fb.set(3, 2, Cell{ .codepoint = 'X' });

    // Position (3, 2) = index 2 * 10 + 3 = 23
    try std.testing.expectEqual(@as(u21, 'X'), fb.cells[23].codepoint);
}

test "FrameBuffer.clear fills with spaces" {
    const allocator = std.testing.allocator;
    var fb = try FrameBuffer.init(allocator, 5, 3, null);
    defer fb.deinit(allocator);

    // Set some cells first
    fb.set(0, 0, Cell{ .codepoint = 'A' });
    fb.set(2, 1, Cell{ .codepoint = 'B' });
    fb.set(4, 2, Cell{ .codepoint = 'C' });

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

test "Scissor.fill fills entire scissor region" {
    const allocator = std.testing.allocator;
    var fb = try FrameBuffer.init(allocator, 10, 5, null);
    defer fb.deinit(allocator);

    fb.clear();

    const scissor = Scissor{
        .x_global = 2,
        .y_global = 1,
        .width_global = 4,
        .height_global = 2,
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
        .x_global = 1,
        .y_global = 1,
        .width_global = 3,
        .height_global = 2,
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
        .x_global = 0,
        .y_global = 0,
        .width_global = 10,
        .height_global = 5,
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
        .x_global = 0,
        .y_global = 0,
        .width_global = 10,
        .height_global = 5,
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
        .x_global = 0,
        .y_global = 0,
        .width_global = 10,
        .height_global = 5,
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
        .x_global = 0,
        .y_global = 0,
        .width_global = 20,
        .height_global = 5,
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
        .x_global = 0,
        .y_global = 0,
        .width_global = 20,
        .height_global = 5,
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
        .x_global = 0,
        .y_global = 0,
        .width_global = 5,
        .height_global = 5,
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
        .x_global = 0,
        .y_global = 0,
        .width_global = 10,
        .height_global = 5,
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
        .x_global = 0,
        .y_global = 0,
        .width_global = 20,
        .height_global = 5,
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
    src_fb.set(0, 0, Cell{ .codepoint = 'A' });
    src_fb.set(1, 0, Cell{ .codepoint = 'B' });
    src_fb.set(2, 0, Cell{ .codepoint = 'C' });
    src_fb.set(0, 1, Cell{ .codepoint = 'D' });
    src_fb.set(1, 1, Cell{ .codepoint = 'E' });
    src_fb.set(2, 1, Cell{ .codepoint = 'F' });

    const scissor = Scissor{
        .x_global = 0,
        .y_global = 0,
        .width_global = 10,
        .height_global = 5,
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
            src_fb.set(@intCast(x), @intCast(y), Cell{ .codepoint = 'X' });
        }
    }

    const scissor = Scissor{
        .x_global = 0,
        .y_global = 0,
        .width_global = 5,
        .height_global = 3,
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
        .x_global = 0,
        .y_global = 0,
        .width_global = 5,
        .height_global = 3,
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
        .x_global = 0,
        .y_global = 0,
        .width_global = 5,
        .height_global = 3,
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
        .x_global = -2,
        .y_global = -1,
        .width_global = 6,
        .height_global = 4,
        .buffer = &fb,
    };

    scissor.fillRectangle(0, 0, 6, 4, Cell{ .codepoint = '#' });

    // Only visible portion should be filled
    // x_global + offset_x = -2 + 0 = -2, clips to 0
    // y_global + offset_y = -1 + 0 = -1, clips to 0
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
        .x_global = 0,
        .y_global = 0,
        .width_global = 10,
        .height_global = 5,
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
