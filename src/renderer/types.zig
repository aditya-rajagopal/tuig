const std = @import("std");

pub const Position = struct {
    x: u16,
    y: u16,
};

pub const MouseState = packed struct {
    left: bool = false,
    right: bool = false,
    middle: bool = false,
};

const stdx = @import("stdx");
const assert = stdx.inlineAssert;

const Cell = @import("root.zig").Cell;
pub const CellBuffer = stdx.GrowingBuffer(Cell);
pub const GraphemeMapAllocator = stdx.FixedGrowingBufferAllocator;

pub const GraphemeMap = std.AutoHashMapUnmanaged(Position, GraphemeID);

pub const GraphemeID = enum(u64) { _ };

pub const GraphemeBuffer = struct {
    const Self = @This();

    end_index: usize = 0,
    generation: u4 = 0,
    buffer: Buffer,

    pub const Buffer = stdx.GrowingBuffer(u8);

    const GraphemeIndex = packed struct(u64) {
        index: u32,
        length: u28,
        generation: u4,
    };

    pub fn init(max_size_bytes: usize) !Self {
        return .{
            .buffer = try Buffer.init(max_size_bytes),
            .end_index = 0,
            .generation = 0,
        };
    }

    pub fn initCapacity(max_size_bytes: usize, initial_size_bytes: usize) error{ OutOfMemory, ReserveFailed }!Self {
        return .{
            .buffer = try Buffer.initCapacity(max_size_bytes, initial_size_bytes),
            .end_index = 0,
            .generation = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.buffer.deinit();
    }

    pub fn ensureTotalCapacity(self: *Self, total_bytes: usize) !void {
        try self.buffer.grow(total_bytes);
    }

    pub fn ensureUnusedCapacity(self: *Self, total_bytes: usize) !void {
        try self.buffer.grow(self.end_index + total_bytes);
    }

    pub fn put(self: *Self, bytes: []const u8) error{OutOfMemory}!GraphemeID {
        assert(bytes.len <= std.math.maxInt(u28));
        defer self.end_index += bytes.len;
        const start = self.end_index;
        const end = self.end_index + bytes.len;
        if (end > self.buffer.reserved_pages.len) {
            self.buffer.grow(end) catch return error.OutOfMemory;
        }
        @memcpy(self.buffer.reserved_pages[start..end], bytes);
        const index: GraphemeIndex = .{
            .index = @intCast(start),
            .length = @intCast(bytes.len),
            .generation = self.generation,
        };
        return @enumFromInt(@as(u64, @bitCast(index)));
    }

    pub fn get(self: *Self, id: GraphemeID) []const u8 {
        const index: GraphemeIndex = @bitCast(@intFromEnum(id));
        assert(index.index + index.length <= self.end_index);
        assert(index.generation == self.generation);
        return self.buffer.reserved_pages[index.index..][0..index.length];
    }

    pub fn reset(self: *Self) void {
        self.end_index = 0;
        self.generation +%= 1;
    }
};
