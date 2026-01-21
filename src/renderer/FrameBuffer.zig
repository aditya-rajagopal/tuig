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
