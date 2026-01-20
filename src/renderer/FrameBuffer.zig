const std = @import("std");
const Allocator = std.mem.Allocator;

const stdx = @import("stdx");
const assert = stdx.inlineAssert;

const Cell = @import("Cell.zig");
const Scissor = @import("Scissor.zig");

const FrameBuffer = @This();

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
    assert(y * self.width + x < self.cells.len);
    self.cells[y * self.width + x] = cell;
}

pub fn get(self: FrameBuffer, x: u16, y: u16) Cell {
    assert(x < self.width);
    assert(y < self.height);
    assert(y * self.width + x < self.cells.len);
    return self.cells[y * self.width + x];
}

pub fn clear(self: *FrameBuffer) void {
    @memset(self.cells, .empty);
}
