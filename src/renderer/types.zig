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

pub const GraphemeBuffer = struct {
    const Self = @This();

    end_index: usize = 0,
    generation: u4 = 0,
    buffer: Buffer,

    pub const Buffer = stdx.GrowingBuffer(u8);

    pub const Size = struct {
        max: usize,
        initial: usize,

        pub const default = Size{
            .max = stdx.MB(1),
            .initial = stdx.KB(4),
        };

        pub const small = Size{
            .max = stdx.KB(16),
            .initial = stdx.KB(4),
        };

        pub const tiny = Size{
            .max = stdx.KB(8),
            .initial = stdx.KB(4),
        };
    };

    pub const GraphemeIndex = u25;

    pub fn init(max_size_bytes: usize) error{ OutOfMemory, ReserveFailed, BufferTooLarge }!Self {
        if (max_size_bytes > std.math.maxInt(u25)) {
            return error.BufferTooLarge;
        }
        return .{
            .buffer = try Buffer.init(max_size_bytes),
            .end_index = 0,
            .generation = 0,
        };
    }

    pub fn initCapacity(max_size_bytes: usize, initial_size_bytes: usize) error{ OutOfMemory, ReserveFailed, BufferTooLarge }!Self {
        if (max_size_bytes > std.math.maxInt(u25)) {
            return error.BufferTooLarge;
        }
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

    pub fn put(self: *Self, bytes: []const u8) error{OutOfMemory}!GraphemeIndex {
        assert(bytes.len <= std.math.maxInt(u32));
        // TODO: Should this be aligned to 4 bytes?
        defer self.end_index += bytes.len + 4;
        const start = self.end_index + 4;
        const end = self.end_index + bytes.len + 4;
        if (end > self.buffer.reserved_pages.len) {
            self.buffer.ensureTotalCapacity(end) catch return error.OutOfMemory;
        }
        @memcpy(self.buffer.reserved_pages[self.end_index..start], std.mem.asBytes(&bytes.len)[0..4]);
        @memcpy(self.buffer.reserved_pages[start..end], bytes);
        return @intCast(self.end_index);
    }

    pub fn get(self: *const Self, id: GraphemeIndex) ?[]const u8 {
        if (id + 4 > self.end_index) return null;
        const length: u32 = @bitCast(self.buffer.reserved_pages[id..][0..4].*);
        if (id + length + 4 > self.end_index) return null;
        return self.buffer.reserved_pages[id + 4 ..][0..length];
    }

    pub fn reset(self: *Self) void {
        self.end_index = 0;
        self.generation +%= 1;
    }
};
