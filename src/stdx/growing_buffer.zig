//! WIP
const std = @import("std");
const Alignment = std.mem.Alignment;

const builtin = @import("builtin");
//https://github.com/ghostty-org/ghostty/blob/26e243a9194f8653e0b44cf00b600629fcee8f46/src/quirks.zig
pub const assert = switch (builtin.mode) {
    .Debug => std.debug.assert,
    .ReleaseFast, .ReleaseSafe, .ReleaseSmall => struct {
        inline fn assert(cond: bool) void {
            if (!cond) unreachable;
        }
    }.assert,
};

pub fn GrowingBuffer(comptime E: type) type {
    const page_size = std.heap.page_size_min;
    const alignment_bytes = std.heap.page_size_min;

    if (!std.math.isPowerOfTwo(page_size)) {
        const msg = std.fmt.comptimePrint("GrowingBuffer requires power-of-two page_size_min, got {}", .{page_size});
        @compileError(msg);
    }

    if (alignment_bytes % @alignOf(E) != 0) {
        const msg = std.fmt.comptimePrint("Alignment of type {s} does not evenly divide page_size_min: {} has alignment {}", .{ @typeName(E), page_size, @alignOf(E) });
        @compileError(msg);
    }
    if (page_size % @sizeOf(E) != 0) {
        const msg = std.fmt.comptimePrint("Type {s} does not evenly divide page_size_min: {} has size {}", .{ @typeName(E), page_size, @sizeOf(E) });
        @compileError(msg);
    }

    return struct {
        const Buffer = @This();

        reserved_pages: []align(std.heap.page_size_min) E,
        max_elements_count: usize,

        pub const empty = Buffer{
            .reserved_pages = &.{},
            .max_elements_count = 0,
        };

        pub fn init(max_elements: usize) error{ReserveFailed}!Buffer {
            const max_size_bytes = std.math.mul(usize, max_elements, @sizeOf(E)) catch return error.ReserveFailed;
            const actual_bytes = roundUpToPage(max_size_bytes) orelse return error.ReserveFailed;
            const actual_max_elements = @divExact(actual_bytes, @sizeOf(E));

            var buffer: Buffer = .{
                .reserved_pages = &.{},
                .max_elements_count = actual_max_elements,
            };
            if (actual_bytes == 0) return buffer;
            try buffer.reserve(actual_bytes);
            return buffer;
        }

        pub fn initCapacity(max_elements: usize, initial_capacity_elements: usize) error{ OutOfMemory, ReserveFailed }!Buffer {
            var buffer: Buffer = try .init(max_elements);
            errdefer buffer.deinit();
            try buffer.ensureTotalCapacity(initial_capacity_elements);
            return buffer;
        }

        pub fn deinit(self: *Buffer) void {
            if (self.max_elements_count == 0) {
                self.* = .empty;
                return;
            }
            self.reserved_pages.len = self.max_elements_count;
            const bytes: []align(alignment_bytes) u8 = std.mem.sliceAsBytes(self.reserved_pages);
            switch (builtin.os.tag) {
                .windows => {
                    const released = VirtualFree(@ptrCast(bytes.ptr), 0, .{ .RELEASE = true });
                    assert(released != 0);
                },
                else => std.posix.munmap(bytes),
            }
            self.* = .empty;
        }

        fn reserve(self: *Buffer, total_bytes: usize) error{ReserveFailed}!void {
            assert(total_bytes > 0);
            assert(self.max_elements_count > 0);
            switch (builtin.os.tag) {
                .windows => {
                    const ptr = VirtualAlloc(
                        null,
                        total_bytes,
                        .{ .RESERVE = true },
                        .{ .READWRITE = true },
                    ) orelse return error.ReserveFailed;
                    self.reserved_pages = @as([*]align(alignment_bytes) E, @ptrCast(@alignCast(ptr)))[0..self.max_elements_count];
                    self.reserved_pages.len = 0;
                },
                else => {
                    const bytes = std.posix.mmap(
                        null,
                        total_bytes,
                        .{}, // PROT.NONE
                        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
                        -1,
                        0,
                    ) catch return error.ReserveFailed;
                    self.reserved_pages = @as([*]align(alignment_bytes) E, @ptrCast(@alignCast(bytes)))[0..self.max_elements_count];
                    self.reserved_pages.len = 0;
                },
            }
        }

        pub fn ensureTotalCapacity(self: *Buffer, capacity: usize) error{OutOfMemory}!void {
            if (capacity <= self.reserved_pages.len) return;
            if (capacity > self.max_elements_count) {
                return error.OutOfMemory;
            }
            const increment = capacity - self.reserved_pages.len;
            try self.commitNewPages(increment);
        }

        fn commitNewPages(self: *Buffer, num_elements: usize) error{OutOfMemory}!void {
            assert(self.reserved_pages.len + num_elements <= self.max_elements_count);
            assert(num_elements > 0);

            const num_bytes = num_elements * @sizeOf(E);
            const num_bytes_to_commit = roundUpToPage(num_bytes) orelse unreachable;
            assert(num_bytes_to_commit > 0);

            const start_offset = self.reserved_pages.len * @sizeOf(E);
            const new_len = self.reserved_pages.len + @divExact(num_bytes_to_commit, @sizeOf(E));
            assert(new_len >= self.reserved_pages.len);
            assert(new_len <= self.max_elements_count);

            const full_reserved: []align(alignment_bytes) E = self.reserved_pages.ptr[0..self.max_elements_count];
            const bytes: []align(alignment_bytes) u8 = std.mem.sliceAsBytes(full_reserved);
            const memory: []align(alignment_bytes) u8 = @alignCast(bytes[start_offset .. start_offset + num_bytes_to_commit]);

            switch (builtin.os.tag) {
                .windows => {
                    const ptr = VirtualAlloc(
                        @ptrCast(memory.ptr),
                        memory.len,
                        .{ .COMMIT = true },
                        .{ .READWRITE = true },
                    ) orelse return error.OutOfMemory;
                    assert(@intFromPtr(ptr) == @intFromPtr(memory.ptr));
                },
                else => {
                    std.process.protectMemory(memory, .{ .read = true, .write = true }) catch return error.OutOfMemory;
                },
            }

            self.reserved_pages.len = new_len;
        }

        inline fn roundUpToPage(bytes: usize) ?usize {
            if (bytes == 0) return 0;
            const mask = page_size - 1;
            const with_mask = std.math.add(usize, bytes, mask) catch return null;
            return with_mask & ~mask;
        }
    };
}

pub const FixedGrowingBufferAllocator = struct {
    const Self = @This();
    end_index: usize,
    buffer: Buffer,

    pub const Buffer = GrowingBuffer(u8);

    pub const empty = Self{
        .buffer = .empty,
        .end_index = 0,
    };

    pub fn init(max_capacity: usize) error{ReserveFailed}!Self {
        return .{
            .buffer = try Buffer.init(max_capacity),
            .end_index = 0,
        };
    }

    pub fn initCapacity(max_capacity: usize, initial_size_bytes: usize) error{ OutOfMemory, ReserveFailed }!Self {
        return .{
            .buffer = try Buffer.initCapacity(max_capacity, initial_size_bytes),
            .end_index = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.buffer.deinit();
    }

    /// Using this at the same time as the interface returned by `threadSafeAllocator` is not thread safe.
    pub fn allocator(self: *Self) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    pub fn pushAligned(
        self: *Self,
        comptime T: type,
        comptime alignment: Alignment,
    ) !*align(alignment.toByteUnits()) T {
        const size = @sizeOf(T);
        const new_ptr = self.allocInternal(size, alignment) orelse return error.OutOfMemory;
        @memset(new_ptr[0..size], undefined);
        const ptr: *align(alignment.toByteUnits()) T = @ptrCast(@alignCast(new_ptr));
        return ptr;
    }

    pub fn push(self: *Self, comptime T: type) !*T {
        const size = @sizeOf(T);
        const new_ptr = self.allocInternal(size, .of(T)) orelse return error.OutOfMemory;
        @memset(new_ptr[0..size], undefined);
        const ptr: *T = @ptrCast(@alignCast(new_ptr));
        return ptr;
    }

    pub fn pushArray(self: *Self, comptime T: type, length: usize) ![]T {
        const size = std.math.mul(usize, @sizeOf(T), length) catch return error.OutOfMemory;
        const new_ptr = self.allocInternal(size, .of(T)) orelse return error.OutOfMemory;
        @memset(new_ptr[0..size], undefined);
        const ptr: [*]T = @ptrCast(@alignCast(new_ptr));
        return ptr[0..length];
    }

    pub fn pushPages(self: *Self, num_pages: usize) ![]u8 {
        const alignment = std.heap.pageSize();
        const size = num_pages * alignment;
        const ptr: [*]u8 = self.allocInternal(size, .fromByteUnits(alignment)) orelse return error.OutOfMemory;
        return ptr[0..size];
    }

    pub fn pushArrayAligned(
        self: *Self,
        comptime T: type,
        comptime alignment: Alignment,
        length: usize,
    ) ![]align(alignment.toByteUnits()) T {
        const size = std.math.mul(usize, @sizeOf(T), length) catch return error.OutOfMemory;
        const new_ptr = self.allocInternal(size, alignment) orelse return error.OutOfMemory;
        @memset(new_ptr[0..size], undefined);
        const ptr: [*]align(alignment.toByteUnits()) T = @ptrCast(@alignCast(new_ptr));
        return ptr[0..length];
    }

    pub fn pushString(self: *Self, str: []const u8) ![]u8 {
        const size = str.len;
        const ptr: [*]u8 = @ptrCast(self.allocInternal(size, .of(u8)) orelse return error.OutOfMemory);
        @memcpy(ptr[0..size], str);
        return ptr[0..size];
    }

    pub fn dupe(self: *Self, comptime T: type, m: []const T) ![]T {
        const bytes = std.mem.sliceAsBytes(m);
        const new_buf: [*]align(@alignOf(T)) u8 = @ptrCast(@alignCast(self.allocInternal(bytes.len, .of(T)) orelse return error.OutOfMemory));
        @memcpy(new_buf[0..bytes.len], bytes);
        return std.mem.bytesAsSlice(T, new_buf[0..bytes.len]);
    }

    pub fn pop(self: *Self, comptime T: type, ptr: *T) void {
        const buf = std.mem.asBytes(ptr);
        self.rawFree(buf);
    }

    pub fn popArray(self: *Self, comptime T: type, buf: []T) void {
        const buf_bytes = std.mem.sliceAsBytes(buf);
        self.rawFree(buf_bytes);
    }

    /// Provides a lock free thread safe `Allocator` interface to the underlying `FixedBufferAllocator`
    ///
    /// Using this at the same time as the interface returned by `allocator` is not thread safe.
    pub fn threadSafeAllocator(self: *Self) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = threadSafeAlloc,
                .resize = std.mem.Allocator.noResize,
                .remap = std.mem.Allocator.noRemap,
                .free = std.mem.Allocator.noFree,
            },
        };
    }

    pub fn ownsPtr(self: *Self, ptr: [*]u8) bool {
        return sliceContainsPtr(self.buffer.reserved_pages, ptr);
    }

    pub fn ownsSlice(self: *Self, slice: []u8) bool {
        return sliceContainsSlice(self.buffer.reserved_pages, slice);
    }

    /// This has false negatives when the last allocation had an
    /// adjusted_index. In such case we won't be able to determine what the
    /// last allocation was because the alignForward operation done in alloc is
    /// not reversible.
    pub fn isLastAllocation(self: *Self, buf: []u8) bool {
        return buf.ptr + buf.len == self.buffer.reserved_pages.ptr + self.end_index;
    }

    pub fn alloc(ctx: *anyopaque, n: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        _ = ra;
        return self.allocInternal(n, alignment);
    }

    fn allocInternal(self: *Self, n: usize, alignment: std.mem.Alignment) ?[*]u8 {
        const ptr_align = alignment.toByteUnits();
        const adjust_off = std.mem.alignPointerOffset(self.buffer.reserved_pages.ptr + self.end_index, ptr_align) orelse return null;
        const adjusted_index = self.end_index + adjust_off;
        const new_end_index = adjusted_index + n;
        if (new_end_index > self.buffer.reserved_pages.len) {
            self.buffer.ensureTotalCapacity(new_end_index) catch return null;
        }
        self.end_index = new_end_index;
        return self.buffer.reserved_pages.ptr + adjusted_index;
    }

    pub fn resize(
        ctx: *anyopaque,
        buf: []u8,
        alignment: std.mem.Alignment,
        new_size: usize,
        return_address: usize,
    ) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        _ = alignment;
        _ = return_address;
        assert(@inComptime() or self.ownsSlice(buf));

        if (!self.isLastAllocation(buf)) {
            if (new_size > buf.len) return false;
            return true;
        }

        if (new_size <= buf.len) {
            const sub = buf.len - new_size;
            self.end_index -= sub;
            return true;
        }

        const add = new_size - buf.len;
        const new_end_index = std.math.add(usize, self.end_index, add) catch return false;
        if (new_end_index > self.buffer.reserved_pages.len) {
            self.buffer.ensureTotalCapacity(new_end_index) catch return false;
        }
        self.end_index = new_end_index;
        return true;
    }

    pub fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        return if (resize(context, memory, alignment, new_len, return_address)) memory.ptr else null;
    }

    pub fn free(
        ctx: *anyopaque,
        buf: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        _ = alignment;
        _ = return_address;
        self.rawFree(buf);
    }

    fn rawFree(self: *Self, buf: []u8) void {
        assert(@inComptime() or self.ownsSlice(buf));

        if (self.isLastAllocation(buf)) {
            self.end_index -= buf.len;
        }
    }

    fn threadSafeAlloc(ctx: *anyopaque, n: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        _ = ra;
        const ptr_align = alignment.toByteUnits();
        var end_index = @atomicLoad(usize, &self.end_index, .seq_cst);
        while (true) {
            const adjust_off = std.mem.alignPointerOffset(self.buffer.reserved_pages.ptr + end_index, ptr_align) orelse return null;
            const adjusted_index = end_index + adjust_off;
            const new_end_index = adjusted_index + n;
            if (new_end_index > self.buffer.reserved_pages.len) {
                self.buffer.ensureTotalCapacity(new_end_index) catch return null;
            }
            end_index = @cmpxchgWeak(usize, &self.end_index, end_index, new_end_index, .seq_cst, .seq_cst) orelse
                return self.buffer.reserved_pages[adjusted_index..new_end_index].ptr;
        }
    }

    pub fn reset(self: *Self) void {
        self.end_index = 0;
    }

    fn sliceContainsPtr(container: []u8, ptr: [*]u8) bool {
        return @intFromPtr(ptr) >= @intFromPtr(container.ptr) and
            @intFromPtr(ptr) < (@intFromPtr(container.ptr) + container.len);
    }

    fn sliceContainsSlice(container: []u8, slice: []u8) bool {
        return @intFromPtr(slice.ptr) >= @intFromPtr(container.ptr) and
            (@intFromPtr(slice.ptr) + slice.len) <= (@intFromPtr(container.ptr) + container.len);
    }
};

pub const GrowingRingBuffer = struct {
    buffer: Backing,
    start: usize,
    len: usize,

    pub const empty: GrowingRingBuffer = .{
        .buffer = .empty,
        .start = 0,
        .len = 0,
    };

    pub const Backing = GrowingBuffer(u8);

    pub const ReadableSlices = struct {
        first: []const u8,
        second: []const u8,
    };

    pub const WritableSlices = struct {
        first: []u8,
        second: []u8,
    };

    pub fn init(max_capacity: usize) error{ReserveFailed}!GrowingRingBuffer {
        return .{
            .buffer = try Backing.init(max_capacity),
            .start = 0,
            .len = 0,
        };
    }

    pub fn initCapacity(max_capacity: usize, initial_capacity: usize) error{ OutOfMemory, ReserveFailed }!GrowingRingBuffer {
        return .{
            .buffer = try Backing.initCapacity(max_capacity, initial_capacity),
            .start = 0,
            .len = 0,
        };
    }

    pub fn deinit(self: *GrowingRingBuffer) void {
        self.buffer.deinit();
        self.* = .empty;
    }

    pub fn capacity(self: *const GrowingRingBuffer) usize {
        return self.buffer.reserved_pages.len;
    }

    pub fn maxCapacity(self: *const GrowingRingBuffer) usize {
        return self.buffer.max_elements_count;
    }

    pub fn readableSlices(self: *const GrowingRingBuffer) ReadableSlices {
        const cap = self.capacity();
        if (self.len == 0 or cap == 0) {
            return .{ .first = &.{}, .second = &.{} };
        }

        assert(self.start < cap);
        const tail = cap - self.start;
        if (self.len <= tail) {
            return .{
                .first = self.buffer.reserved_pages[self.start .. self.start + self.len],
                .second = &.{},
            };
        }

        return .{
            .first = self.buffer.reserved_pages[self.start..cap],
            .second = self.buffer.reserved_pages[0 .. self.len - tail],
        };
    }

    pub fn ensureWritable(self: *GrowingRingBuffer, min_writable: usize) error{OutOfMemory}!void {
        const cap = self.capacity();
        const free_now = cap - self.len;
        if (free_now >= min_writable) return;

        const needed_total = std.math.add(usize, self.len, min_writable) catch return error.OutOfMemory;
        if (needed_total > self.maxCapacity()) return error.OutOfMemory;

        var target = needed_total;
        if (cap > 0) {
            const growth = std.math.add(usize, cap, cap / 2) catch self.maxCapacity();
            if (growth > target) target = growth;
        }
        target = @min(target, self.maxCapacity());

        const is_wrapped = cap > 0 and self.len > cap - self.start;

        try self.buffer.ensureTotalCapacity(target);
        const new_cap = self.capacity();
        assert(new_cap >= needed_total);

        if (!is_wrapped or new_cap == cap) return;

        const first_len = cap - self.start;
        const second_len = self.len - first_len;
        const grown_by = new_cap - cap;

        if (second_len <= grown_by) {
            std.mem.copyForwards(
                u8,
                self.buffer.reserved_pages[cap .. cap + second_len],
                self.buffer.reserved_pages[0..second_len],
            );
            return;
        }

        const new_start = new_cap - first_len;
        std.mem.copyBackwards(
            u8,
            self.buffer.reserved_pages[new_start .. new_start + first_len],
            self.buffer.reserved_pages[self.start..cap],
        );
        self.start = new_start;
    }

    pub fn writableSlices(self: *GrowingRingBuffer) WritableSlices {
        const cap = self.capacity();
        if (cap == 0) return .{ .first = &.{}, .second = &.{} };

        const free = cap - self.len;
        if (free == 0) return .{ .first = &.{}, .second = &.{} };

        const write_start = self.writeStart();
        const first_len = @min(free, cap - write_start);
        const second_len = free - first_len;

        return .{
            .first = self.buffer.reserved_pages[write_start .. write_start + first_len],
            .second = self.buffer.reserved_pages[0..second_len],
        };
    }

    pub fn consume(self: *GrowingRingBuffer, count: usize) void {
        assert(count <= self.len);
        if (count == self.len) {
            self.len = 0;
            self.start = 0;
            return;
        }

        const cap = self.capacity();
        const remaining_to_end = cap - self.start;
        self.start = if (count >= remaining_to_end)
            count - remaining_to_end
        else
            self.start + count;
        self.len -= count;
    }

    pub fn dropOldest(self: *GrowingRingBuffer, count: usize) usize {
        const dropped = @min(count, self.len);
        self.consume(dropped);
        return dropped;
    }

    pub fn linearizeReadable(self: *GrowingRingBuffer) []const u8 {
        if (self.len == 0) return &.{};

        const slices = self.readableSlices();
        if (slices.second.len == 0) return slices.first;

        const cap = self.capacity();
        std.mem.rotate(u8, self.buffer.reserved_pages[0..cap], self.start);
        self.start = 0;
        return self.buffer.reserved_pages[0..self.len];
    }

    pub fn write(self: *GrowingRingBuffer, bytes: []const u8) error{OutOfMemory}!usize {
        if (bytes.len == 0) return 0;
        try self.ensureWritable(bytes.len);

        const writable = self.writableSlices();
        const first_len = @min(writable.first.len, bytes.len);
        std.mem.copyForwards(u8, writable.first[0..first_len], bytes[0..first_len]);

        const remaining = bytes.len - first_len;
        if (remaining > 0) {
            std.mem.copyForwards(u8, writable.second[0..remaining], bytes[first_len..]);
        }

        self.len += bytes.len;
        return bytes.len;
    }

    pub fn didWrite(self: *GrowingRingBuffer, count: usize) void {
        if (count == 0) return;
        const cap = self.capacity();
        assert(count <= cap - self.len);
        self.len += count;
    }

    fn writeStart(self: *const GrowingRingBuffer) usize {
        const cap = self.capacity();
        if (cap == 0) return 0;
        const remaining_to_end = cap - self.start;
        return if (self.len >= remaining_to_end)
            self.len - remaining_to_end
        else
            self.start + self.len;
    }
};

test "GrowingRingBuffer wraps readable slices" {
    var rb = try GrowingRingBuffer.initCapacity(std.heap.page_size_min * 2, std.heap.page_size_min);
    defer rb.deinit();

    const cap = rb.capacity();
    const prefix = try std.testing.allocator.alloc(u8, cap - 2);
    defer std.testing.allocator.free(prefix);
    @memset(prefix, 'a');

    _ = try rb.write(prefix);
    rb.consume(cap - 4);
    _ = try rb.write("012345");

    const slices = rb.readableSlices();
    try std.testing.expect(slices.second.len > 0);

    const linear = rb.linearizeReadable();
    try std.testing.expectEqualStrings("aa012345", linear);
}

test "GrowingRingBuffer dropOldest clamps" {
    var rb = try GrowingRingBuffer.initCapacity(64, 8);
    defer rb.deinit();

    _ = try rb.write("abcdef");
    const dropped = rb.dropOldest(10);
    try std.testing.expectEqual(@as(usize, 6), dropped);
    try std.testing.expectEqual(@as(usize, 0), rb.len);
}

test "GrowingRingBuffer property: random operations preserve model" {
    const seed = std.testing.random_seed ^ 0x2af9d8a7;
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    const max_capacity = std.heap.page_size_min * 2;
    var rb = try GrowingRingBuffer.initCapacity(max_capacity, std.heap.page_size_min);
    defer rb.deinit();

    var model: std.ArrayList(u8) = .empty;
    defer model.deinit(std.testing.allocator);

    var scratch: [96]u8 = undefined;

    const Operation = enum(u8) {
        write_random,
        consume,
        drop_oldest,
        ensure_writable,
        linearize,
        linearize_if_wrapped,
    };

    var iteration: usize = 0;
    while (iteration < 6000) : (iteration += 1) {
        const op: Operation = @enumFromInt(random.uintLessThan(u8, 6));
        switch (op) {
            .write_random => {
                const n = random.intRangeAtMost(usize, 0, scratch.len);
                random.bytes(scratch[0..n]);
                const expected_oom = model.items.len + n > rb.maxCapacity();
                const write_result = rb.write(scratch[0..n]);
                if (expected_oom) {
                    if (write_result) |_| {
                        std.debug.print("ring write expected oom seed={d} iteration={d} n={d}\n", .{ seed, iteration, n });
                        return error.TestUnexpectedResult;
                    } else |err| {
                        if (err != error.OutOfMemory) return err;
                    }
                } else {
                    _ = try write_result;
                    try model.appendSlice(std.testing.allocator, scratch[0..n]);
                }
            },
            .consume => {
                const n = random.intRangeAtMost(usize, 0, model.items.len + 32);
                const consume_count = @min(n, model.items.len);
                rb.consume(consume_count);
                if (consume_count > 0 and consume_count < model.items.len) {
                    std.mem.copyForwards(u8, model.items[0 .. model.items.len - consume_count], model.items[consume_count..]);
                }
                model.items.len -= consume_count;
            },
            .drop_oldest => {
                const n = random.intRangeAtMost(usize, 0, model.items.len + 32);
                const expected = @min(n, model.items.len);
                const dropped = rb.dropOldest(n);
                if (dropped != expected) {
                    std.debug.print("ring drop mismatch seed={d} iteration={d} expected={d} got={d}\n", .{ seed, iteration, expected, dropped });
                    return error.TestUnexpectedResult;
                }
                if (expected > 0 and expected < model.items.len) {
                    std.mem.copyForwards(u8, model.items[0 .. model.items.len - expected], model.items[expected..]);
                }
                model.items.len -= expected;
            },
            .ensure_writable => {
                const min_writable = random.intRangeAtMost(usize, 0, 128);
                const expected_oom = model.items.len + min_writable > rb.maxCapacity();
                const ensure = rb.ensureWritable(min_writable);
                if (expected_oom) {
                    if (ensure) {
                        std.debug.print("ring ensure expected oom seed={d} iteration={d} need={d}\n", .{ seed, iteration, min_writable });
                        return error.TestUnexpectedResult;
                    } else |err| {
                        if (err != error.OutOfMemory) return err;
                    }
                } else {
                    try ensure;
                }
            },
            .linearize => {
                _ = rb.linearizeReadable();
            },
            .linearize_if_wrapped => {
                const slices = rb.readableSlices();
                if (slices.second.len > 0) {
                    _ = rb.linearizeReadable();
                }
            },
        }

        if (rb.len != model.items.len) {
            std.debug.print("ring len mismatch seed={d} iteration={d} ring={d} model={d}\n", .{ seed, iteration, rb.len, model.items.len });
            return error.TestUnexpectedResult;
        }
        if (rb.len > rb.capacity() or rb.capacity() > rb.maxCapacity()) {
            std.debug.print("ring bounds violation seed={d} iteration={d} len={d} cap={d} max={d}\n", .{ seed, iteration, rb.len, rb.capacity(), rb.maxCapacity() });
            return error.TestUnexpectedResult;
        }

        const linear = rb.linearizeReadable();
        if (!std.mem.eql(u8, linear, model.items)) {
            std.debug.print("ring content mismatch seed={d} iteration={d}\n", .{ seed, iteration });
            return error.TestUnexpectedResult;
        }
    }
}

pub const PROTECTION = packed struct(u32) {
    NOACCESS: bool = false,
    READONLY: bool = false,
    READWRITE: bool = false,
    WRITECOPY: bool = false,

    EXECUTE: bool = false,
    EXECUTE_READ: bool = false,
    EXECUTE_READWRITE: bool = false,
    EXECUTE_WRITECOPY: bool = false,

    GUARD: bool = false,
    NOCACHE: bool = false,
    WRITECOMBINE: bool = false,

    GRAPHICS_NOACCESS: bool = false,
    GRAPHICS_READONLY: bool = false,
    GRAPHICS_READWRITE: bool = false,
    GRAPHICS_EXECUTE: bool = false,
    GRAPHICS_EXECUTE_READ: bool = false,
    GRAPHICS_EXECUTE_READWRITE: bool = false,
    GRAPHICS_COHERENT: bool = false,
    GRAPHICS_NOCACHE: bool = false,

    Reserved19: u12 = 0,

    REVERT_TO_FILE_MAP: bool = false,
};

const ULONG = std.os.windows.ULONG;
const ULONG64 = std.os.windows.ULONG64;
const SIZE_T = std.os.windows.SIZE_T;
const HANDLE = std.os.windows.HANDLE;
const PVOID = std.os.windows.PVOID;

pub const MEM = struct {
    pub const ALLOCATE = packed struct(ULONG) {
        Reserved0: u12 = 0,
        COMMIT: bool = false,
        RESERVE: bool = false,
        REPLACE_PLACEHOLDER: bool = false,
        Reserved15: u3 = 0,
        RESERVE_PLACEHOLDER: bool = false,
        RESET: bool = false,
        TOP_DOWN: bool = false,
        WRITE_WATCH: bool = false,
        PHYSICAL: bool = false,
        Reserved23: u1 = 0,
        RESET_UNDO: bool = false,
        Reserved25: u4 = 0,
        LARGE_PAGES: bool = false,
        Reserved30: u1 = 0,
        @"4MB_PAGES": bool = false,

        pub const @"64K_PAGES": ALLOCATE = .{
            .LARGE_PAGES = true,
            .PHYSICAL = true,
        };
    };

    pub const FREE = packed struct(ULONG) {
        COALESCE_PLACEHOLDERS: bool = false,
        PRESERVE_PLACEHOLDER: bool = false,
        Reserved2: u12 = 0,
        DECOMMIT: bool = false,
        RELEASE: bool = false,
        FREE: bool = false,
        Reserved17: u15 = 0,
    };

    pub const MAP = packed struct(ULONG) {
        Reserved0: u13 = 0,
        RESERVE: bool = false,
        REPLACE_PLACEHOLDER: bool = false,
        Reserved15: u14 = 0,
        LARGE_PAGES: bool = false,
        Reserved30: u2 = 0,
    };

    pub const UNMAP = packed struct(ULONG) {
        WITH_TRANSIENT_BOOST: bool = false,
        PRESERVE_PLACEHOLDER: bool = false,
        Reserved2: u30 = 0,
    };

    pub const EXTENDED_PARAMETER = extern struct {
        s: packed struct(ULONG64) {
            Type: TYPE,
            Reserved: u56,
        },
        u: extern union {
            ULong64: ULONG64,
            Pointer: PVOID,
            Size: SIZE_T,
            Handle: HANDLE,
            ULong: ULONG,
        },

        pub const TYPE = enum(u8) {
            InvalidType = 0,
            AddressRequirements,
            NumaNode,
            PartitionHandle,
            UserPhysicalHandle,
            AttributeFlags,
            ImageMachine,
            _,

            pub const Max: @typeInfo(@This()).@"enum".tag_type = @typeInfo(@This()).@"enum".fields.len;
        };
    };
};

pub extern "kernel32" fn VirtualAlloc(lpAddress: ?*anyopaque, dwSize: usize, flAllocationType: MEM.ALLOCATE, flProtect: PROTECTION) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn VirtualFree(lpAddress: ?*anyopaque, dwSize: usize, dwFreeType: MEM.FREE) callconv(.winapi) c_int;

test FixedGrowingBufferAllocator {
    const fba = try FixedGrowingBufferAllocator.init(64 * std.heap.page_size_min);
    var fixed_buffer_allocator = std.mem.validationWrap(fba);
    const a = fixed_buffer_allocator.allocator();

    try std.heap.testAllocator(a);
    try std.heap.testAllocatorAligned(a);
    try std.heap.testAllocatorLargeAlignment(a);
    try std.heap.testAllocatorAlignedShrink(a);
}

test "GrowingBuffer init/deinit" {
    const GB = GrowingBuffer(u64);
    var gb = try GB.init(100);
    defer gb.deinit();

    try std.testing.expect(gb.reserved_pages.len == 0);
}

test "GrowingBuffer initCapacity" {
    const GB = GrowingBuffer(u64);
    const initial_bytes = 64;
    var gb = try GB.initCapacity(100, initial_bytes);
    defer gb.deinit();

    try std.testing.expectEqual(std.heap.page_size_min / @sizeOf(u64), gb.reserved_pages.len);
}

test "GrowingBuffer ensureTotalCapacity within max" {
    const GB = GrowingBuffer(u64);
    var gb = try GB.init(100);
    defer gb.deinit();

    try gb.ensureTotalCapacity(50);
    try std.testing.expectEqual(std.heap.page_size_min / @sizeOf(u64), gb.reserved_pages.len);
    try gb.ensureTotalCapacity(100);
    try std.testing.expectEqual(std.heap.page_size_min / @sizeOf(u64), gb.reserved_pages.len);
}

test "GrowingBuffer ensureTotalCapacity beyond max" {
    const GB = GrowingBuffer(u64);
    var gb = try GB.init(100);
    defer gb.deinit();

    try std.testing.expectError(error.OutOfMemory, gb.ensureTotalCapacity(gb.max_elements_count + 1));
}

test "GrowingBuffer page boundary crossing" {
    const GB = GrowingBuffer(u8);
    var gb = try GB.init(std.heap.page_size_min * 3);
    defer gb.deinit();

    const first_page = std.heap.page_size_min - 1;
    try gb.ensureTotalCapacity(first_page);
    try std.testing.expectEqual(std.heap.page_size_min, gb.reserved_pages.len);

    try gb.ensureTotalCapacity(std.heap.page_size_min + 1);
    try std.testing.expectEqual(std.heap.page_size_min * 2, gb.reserved_pages.len);
}

// This software is available under two licenses -- choose whichever you
// prefer.
//
// ----------------------------------------------------------------------
// License 1 -- MIT No Attribution (MIT-0)
//
// Copyright (c) 2025 Aditya Rajagopal
//
// Permission is hereby granted, free of charge, to any person obtaining
// a copy of this software and associated documentation files (the
// "Software"), to deal in the Software without restriction, including
// without limitation the rights to use, copy, modify, merge, publish,
// distribute, sublicense, and/or sell copies of the Software, and to
// permit persons to whom the Software is furnished to do so.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
// IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
// CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
// TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
// SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
//
// ----------------------------------------------------------------------
// License 2 -- Unlicense <https://unlicense.org>
//
// This is free and unencumbered software released into the public
// domain.
//
// Anyone is free to copy, modify, publish, use, compile, sell, or
// distribute this software, either in source code form or as a compiled
// binary, for any purpose, commercial or non-commercial, and by any
// means.
//
// In jurisdictions that recognize copyright laws, the author or authors
// of this software dedicate any and all copyright interest in the
// software to the public domain. We make this dedication for the benefit
// of the public at large and to the detriment of our heirs and
// successors. We intend this dedication to be an overt act of
// relinquishment in perpetuity of all present and future rights to this
// software under copyright law.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
// IN NO EVENT SHALL THE AUTHORS BE LIABLE FOR ANY CLAIM, DAMAGES OR
// OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
// ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
// OTHER DEALINGS IN THE SOFTWARE.
