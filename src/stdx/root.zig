const std = @import("std");

pub const parseArgs = @import("flags.zig").parseArgs;

const memory_pool = @import("memory_pool.zig");
pub const BufferPool = memory_pool.BufferPool;
pub const BufferPoolExtra = memory_pool.BufferPoolExtra;
pub const BufferPoolOptions = memory_pool.Options;

const growing_buffer = @import("growing_buffer.zig");
pub const GrowingBuffer = growing_buffer.GrowingBuffer;
pub const FixedGrowingBufferAllocator = growing_buffer.FixedGrowingBufferAllocator;
pub const GrowingRingBuffer = growing_buffer.GrowingRingBuffer;

const builtin = @import("builtin");
//https://github.com/ghostty-org/ghostty/blob/26e243a9194f8653e0b44cf00b600629fcee8f46/src/quirks.zig
pub const inlineAssert = switch (builtin.mode) {
    .Debug => std.debug.assert,
    .ReleaseFast, .ReleaseSafe, .ReleaseSmall => struct {
        inline fn assert(cond: bool) void {
            if (!cond) unreachable;
        }
    }.assert,
};

pub fn KB(kb: f32) usize {
    return @intFromFloat(kb * 1024);
}

pub fn MB(mb: f32) usize {
    return @intFromFloat(mb * 1024 * 1024);
}

pub fn GB(gb: f32) usize {
    return @intFromFloat(gb * 1024 * 1024 * 1024);
}

pub fn cut(comptime T: type, haystack: []const T, needle: []const T) ?struct { []const T, []const T } {
    const index = std.mem.find(T, haystack, needle) orelse return null;
    return .{ haystack[0..index], haystack[index + needle.len ..] };
}

pub fn cutScalar(comptime T: type, haystack: []const T, needle: T) ?struct { []const T, []const T } {
    const index = std.mem.findScalar(T, haystack, needle) orelse return null;
    return .{ haystack[0..index], haystack[index + 1 ..] };
}
