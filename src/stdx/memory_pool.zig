//! WIP
const std = @import("std");
const builtin = @import("builtin");
const Alignment = std.mem.Alignment;

//https://github.com/ghostty-org/ghostty/blob/26e243a9194f8653e0b44cf00b600629fcee8f46/src/quirks.zig
pub const assert = switch (builtin.mode) {
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

pub const Options = struct {
    block_size: usize = MB(4),
    size_limit: usize = 1024,
    metrics: bool = switch (builtin.mode) {
        .Debug => true,
        else => false,
    },
};

pub fn BufferPool(block_size: usize) type {
    return BufferPoolExtra(.{ .block_size = block_size });
}

pub fn BufferPoolExtra(comptime options: Options) type {
    const block_size = options.block_size;
    const alignment_bytes = std.heap.page_size_min;
    if (comptime block_size % alignment_bytes != 0) {
        const msg = std.fmt.comptimePrint("block_size must be a multiple of page_size_min: {} but is {}", .{ alignment_bytes, block_size });
        @compileError(msg);
    }

    return struct {
        const Pool = @This();

        pub const memory_block_size = block_size;
        pub const MemoryBlock = [block_size]u8;
        const MemoryBlockPtr = *align(alignment_bytes) MemoryBlock;

        reserved_pages: []align(std.heap.page_size_min) u8,
        free_list: std.SinglyLinkedList,
        metrics: if (options.metrics) Metrics else void,

        pub const reserved_virtual_memory_bytes = (block_size + std.heap.page_size_min) * max_pool_size;

        pub const Metrics = struct {
            acquires_total: usize = 0,
            releases_total: usize = 0,
            acquires_current: usize = 0,
            acquires_max_concurrent: usize = 0,
        };
        pub const max_pool_size = options.size_limit;

        pub const empty = Pool{
            .reserved_pages = &.{},
            .free_list = .{},
            .metrics = if (options.metrics) .{} else void{},
        };

        pub fn init() error{ReserveFailed}!Pool {
            var pool: Pool = .empty;
            try pool.reserve();
            return pool;
        }

        pub fn initCapacity(pool_size: usize) error{ OutOfMemory, ReserveFailed }!Pool {
            var pool: Pool = try .init();
            errdefer pool.deinit();
            try pool.addCapacity(pool_size);
            return pool;
        }

        pub fn deinit(self: *Pool) void {
            self.reserved_pages.len = reserved_virtual_memory_bytes;
            switch (builtin.os.tag) {
                .windows => VirtualFree(@ptrCast(self.reserved_pages.ptr), 0, .{ .RELEASE = true }),
                else => std.posix.munmap(self.reserved_pages),
            }
        }

        /// Pre-allocates `num` items and adds them to the memory pool.
        /// This allows at least `num` active allocations before an
        /// `OutOfMemory` error might happen when calling `create()`.
        pub fn addCapacity(self: *Pool, num_blocks: usize) error{OutOfMemory}!void {
            if (self.reserved_pages.len + required_pages(num_blocks) > reserved_virtual_memory_bytes) {
                return error.OutOfMemory;
            }
            var i: usize = 0;
            while (i < num_blocks) : (i += 1) {
                const memory = self.commitNewBlock() catch return error.OutOfMemory;
                self.free_list.prepend(@ptrCast(memory));
            }
        }

        /// Creates a new item and adds it to the memory pool.
        /// `allocator` may be `undefined` if pool is not `growable`.
        pub fn acquireChunk(self: *Pool) error{OutOfMemory}!*align(alignment_bytes) MemoryBlock {
            const block: *align(alignment_bytes) MemoryBlock = if (self.free_list.popFirst()) |node|
                @ptrCast(@alignCast(node))
            else
                @ptrCast(self.commitNewBlock() catch return error.OutOfMemory);

            if (options.metrics) {
                self.metrics.acquires_total += 1;
                self.metrics.acquires_current += 1;
                self.metrics.acquires_max_concurrent = @max(self.metrics.acquires_max_concurrent, self.metrics.acquires_current);
            }
            block.* = undefined;
            return block;
        }

        /// Returns a previously created buffer to the buffer pool.
        /// Only pass items to `ptr` that were previously created with `create()` of the same memory pool!
        /// There is no way to check if this was in the memory pool before.
        pub fn returnChunk(self: *Pool, block: *align(alignment_bytes) MemoryBlock) void {
            if (options.metrics) {
                self.metrics.releases_total += 1;
                self.metrics.acquires_current -= 1;
            }
            block.* = undefined;
            self.free_list.prepend(@ptrCast(block));
        }

        fn reserve(self: *Pool) !void {
            switch (builtin.os.tag) {
                .windows => {
                    const ptr = VirtualAlloc(
                        null,
                        reserved_virtual_memory_bytes,
                        .{ .RESERVE = true },
                        .{ .READWRITE = true },
                    ) orelse return error.ReserveFailed;
                    self.reserved_pages = @as([*]align(alignment_bytes) u8, @ptrCast(@alignCast(ptr)))[0..reserved_virtual_memory_bytes];
                    self.reserved_pages.len = 0;
                },
                else => {
                    self.reserved_pages = std.posix.mmap(
                        null,
                        reserved_virtual_memory_bytes,
                        .{}, // PROT.NONE
                        .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
                        -1,
                        0,
                    ) catch return error.ReserveFailed;
                    self.reserved_pages.len = 0;
                },
            }
        }

        fn commitNewBlock(self: *Pool) error{OutOfMemory}!MemoryBlockPtr {
            const start_offset = self.reserved_pages.len;
            self.reserved_pages.len += block_size + std.heap.page_size_min;

            switch (builtin.os.tag) {
                .windows => {
                    const ptr = VirtualAlloc(
                        @ptrCast(@alignCast(self.reserved_pages[start_offset..][0..block_size])),
                        block_size,
                        .{ .RESERVE = true, .COMMIT = true },
                        .{ .READWRITE = true },
                    ) orelse return error.OutOfMemory;
                    const memory: []align(std.heap.page_size_min) u8 = @ptrCast(@alignCast(ptr));
                    return memory[0..block_size];
                },
                else => {
                    const memory: []align(std.heap.page_size_min) u8 = @alignCast(self.reserved_pages[start_offset..][0..block_size]);
                    std.process.protectMemory(memory, .{ .read = true, .write = true }) catch return error.OutOfMemory;
                    return memory[0..block_size];
                },
            }
        }

        inline fn required_pages(num_blocks: usize) usize {
            return num_blocks * (block_size + std.heap.page_size_min);
        }

        pub const ArenaAllocator = struct {
            const Self = @This();
            buffer_list: std.SinglyLinkedList,
            pool: *Pool,

            pub const largest_allocation_bytes = block_size - @sizeOf(usize) - @sizeOf(std.SinglyLinkedList.Node);
            pub const BufferNode = struct {
                node: std.SinglyLinkedList.Node = .{},
                end_index: usize = 0,
                data: [largest_allocation_bytes]u8,
            };
            comptime {
                assert(@sizeOf(BufferNode) == block_size);
            }
            const BufferNodePtr = *align(alignment_bytes) BufferNode;

            pub fn init(memory_pool: *Pool) Self {
                return .{
                    .buffer_list = .{},
                    .pool = memory_pool,
                };
            }

            pub fn deinit(self: *Self) void {
                var it = self.buffer_list.first;
                while (it) |node| {
                    const next_it = node.next;
                    const buf_node: BufferNodePtr = @alignCast(@fieldParentPtr("node", node));
                    const alloc_buf = @as([*]align(alignment_bytes) u8, @ptrCast(buf_node))[0..block_size];
                    // Return the memory block to the memory pool
                    self.pool.returnChunk(alloc_buf);
                    it = next_it;
                }
            }

            // Resets the arena to a single block of memory.
            pub fn reset(self: *Self) void {
                var it = self.buffer_list.first;
                while (it) |node| {
                    if (node.next) |next_it| {
                        const buf_node: BufferNodePtr = @alignCast(@fieldParentPtr("node", node));
                        const alloc_buf = @as([*]align(alignment_bytes) u8, @ptrCast(buf_node))[0..block_size];
                        // Return the memory block to the memory pool
                        self.pool.returnChunk(alloc_buf);
                        it = next_it;
                    } else {
                        const buf_node: BufferNodePtr = @alignCast(@fieldParentPtr("node", node));
                        buf_node.end_index = 0;
                        break;
                    }
                }
                self.buffer_list.first = it;
            }

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

            fn createNode(self: *Self) ?*BufferNode {
                const chunk = self.pool.acquireChunk() catch return null;
                const node: BufferNodePtr = @ptrCast(chunk);
                self.buffer_list.prepend(&node.node);
                node.end_index = 0;
                return node;
            }

            fn alloc(ctx: *anyopaque, n: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
                const self: *Self = @ptrCast(@alignCast(ctx));
                _ = ra;
                return self.allocInternal(n, alignment) orelse return null;
            }

            fn allocInternal(self: *Self, n: usize, alignment: std.mem.Alignment) ?[*]u8 {
                if (n > largest_allocation_bytes) {
                    return null;
                }
                const align_bytes = alignment.toByteUnits();
                var node_current: *BufferNode = if (self.buffer_list.first) |first_node|
                    @fieldParentPtr("node", first_node)
                else
                    (self.createNode() orelse return null);

                // Since we only get fixed sized allocations from the nodes we try once to
                // allocate from the current node. If that failes we create a new node and try again.
                // Since we boot out if the requested allocation is larger than the usable memory before we
                // get here the allocation should not fail.
                inline for (0..2) |i| {
                    const buffer_current = node_current.data[0..largest_allocation_bytes];
                    const address_current = @intFromPtr(buffer_current.ptr) + node_current.end_index;
                    const address_aligned = (address_current + align_bytes - 1) & ~(align_bytes - 1);
                    const adjusted_index = node_current.end_index + (address_aligned - address_current);
                    const new_end_index = adjusted_index + n;

                    if (comptime i == 0) {
                        if (new_end_index <= largest_allocation_bytes) {
                            @branchHint(.likely);
                            const result = buffer_current[adjusted_index..new_end_index];
                            node_current.end_index = new_end_index;
                            return result.ptr;
                        } else if (comptime i == 0) {
                            // FIXME: This greedily creates a new node and the old one is left even if it had space left.
                            node_current = self.createNode() orelse return null;
                        }
                    } else {
                        // NOTE(adi): we are guaranteed to have space here.
                        assert(new_end_index <= largest_allocation_bytes);
                        const result = buffer_current[adjusted_index..new_end_index];
                        node_current.end_index = new_end_index;
                        return result.ptr;
                    }
                }
            }

            fn resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
                const self: *Self = @ptrCast(@alignCast(ctx));
                _ = alignment;
                _ = ret_addr;
                return self.resizeInternal(buf, new_len);
            }

            fn resizeInternal(self: *Self, buf: []u8, new_len: usize) bool {
                const cur_node = self.buffer_list.first orelse return false;
                const cur_buf_node: *BufferNode = @fieldParentPtr("node", cur_node);
                const cur_buf: []u8 = cur_buf_node.data[0..largest_allocation_bytes];

                // NOTE(adi): If this allocation is in a later node this will also fail.
                if (@intFromPtr(cur_buf.ptr) + cur_buf_node.end_index != @intFromPtr(buf.ptr) + buf.len) {
                    // It's not the most recent allocation, so it cannot be expanded,
                    // but it's fine if they want to make it smaller.
                    return new_len <= buf.len;
                }

                if (buf.len >= new_len) {
                    cur_buf_node.end_index -= buf.len - new_len;
                    return true;
                } else if (largest_allocation_bytes - cur_buf_node.end_index >= new_len - buf.len) {
                    cur_buf_node.end_index += new_len - buf.len;
                    return true;
                } else {
                    return false;
                }
            }

            fn remap(
                context: *anyopaque,
                memory: []u8,
                alignment: std.mem.Alignment,
                new_len: usize,
                return_address: usize,
            ) ?[*]u8 {
                return if (resize(context, memory, alignment, new_len, return_address)) memory.ptr else null;
            }

            fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
                _ = alignment;
                _ = ret_addr;

                const self: *Self = @ptrCast(@alignCast(ctx));
                self.freeInternal(buf);
            }

            fn freeInternal(self: *Self, buf: []u8) void {
                const cur_node = self.buffer_list.first orelse return;
                const cur_buf_node: *BufferNode = @fieldParentPtr("node", cur_node);
                const cur_buf = cur_buf_node.data[0..largest_allocation_bytes];

                if (@intFromPtr(cur_buf.ptr) + cur_buf_node.end_index == @intFromPtr(buf.ptr) + buf.len) {
                    cur_buf_node.end_index -= buf.len;
                }
            }
        };
    };
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

test "PoolArenaAllocator" {
    const Pool = BufferPoolExtra(.{});
    const Arena = Pool.ArenaAllocator;
    var pool = try Pool.initCapacity(0);
    defer pool.deinit();
    var alloc = Arena.init(&pool);
    defer alloc.deinit();
    var arena = std.mem.validationWrap(alloc);
    const a = arena.allocator();

    try std.heap.testAllocator(a);
    try std.heap.testAllocatorAligned(a);
    try std.heap.testAllocatorLargeAlignment(a);
    try std.heap.testAllocatorAlignedShrink(a);
}

test "reuse memory on realloc" {
    const Pool = BufferPoolExtra(.{});
    const Arena = Pool.ArenaAllocator;
    var pool = try Pool.initCapacity(1);
    // check if we re-use the memory
    {
        var arena = Arena.init(&pool);
        const a = arena.allocator();
        defer arena.deinit();

        const slice0 = try a.alloc(u8, 5);
        try std.testing.expect(slice0.len == 5);
        const slice1 = try a.realloc(slice0, 10);
        try std.testing.expect(slice1.ptr == slice0.ptr);
        try std.testing.expect(slice1.len == 10);
    }
    // check that we don't re-use the memory if it's not the most recent block
    {
        var arena = Arena.init(&pool);
        defer arena.deinit();
        const a = arena.allocator();

        var slice0 = try a.alloc(u8, 2);
        slice0[0] = 1;
        slice0[1] = 2;
        const slice1 = try a.alloc(u8, 2);
        const slice2 = try a.realloc(slice0, 4);
        try std.testing.expect(slice0.ptr != slice2.ptr);
        try std.testing.expect(slice1.ptr != slice2.ptr);
        try std.testing.expect(slice2[0] == 1);
        try std.testing.expect(slice2[1] == 2);
    }
}

test "arena" {
    const Pool = BufferPoolExtra(.{});
    const Arena = Pool.ArenaAllocator;
    var pool = try Pool.initCapacity(0);
    var arena = Arena.init(&pool);
    defer arena.deinit();
    var rng_src = std.Random.DefaultPrng.init(std.testing.random_seed);
    const random = rng_src.random();
    var rounds: usize = 25;
    while (rounds > 0) {
        rounds -= 1;
        arena.reset();
        const size = random.intRangeAtMost(usize, 0, 5 * Pool.memory_block_size);
        var alloced_bytes: usize = 0;
        while (alloced_bytes < size) {
            const alloc_size = random.intRangeAtMost(usize, 1, Pool.memory_block_size);
            _ = try arena.pushArray(u8, alloc_size);
            alloced_bytes += alloc_size;
        }
    }
}

test "pool out of memory" {
    const Pool = BufferPoolExtra(.{ .block_size = std.heap.page_size_min, .size_limit = 2, .metrics = true });
    var pool = try Pool.init();
    defer pool.deinit();

    // Acquire 2 blocks successfully
    const block1 = try pool.acquireChunk();
    defer pool.returnChunk(block1);
    try std.testing.expectEqual(@as(usize, 1), pool.metrics.acquires_current);

    const block2 = try pool.acquireChunk();
    defer pool.returnChunk(block2);
    try std.testing.expectEqual(@as(usize, 2), pool.metrics.acquires_current);
    try std.testing.expectEqual(@as(usize, 2), pool.metrics.acquires_total);

    // 3rd acquire should return OutOfMemory
    const result = pool.acquireChunk();
    try std.testing.expectError(error.OutOfMemory, result);

    // Metrics should still show 2 acquires
    try std.testing.expectEqual(@as(usize, 2), pool.metrics.acquires_current);
    try std.testing.expectEqual(@as(usize, 2), pool.metrics.acquires_total);
}

test "arena single allocation too large" {
    const Pool = BufferPoolExtra(.{ .block_size = std.heap.page_size_min, .size_limit = 2, .metrics = true });
    var pool = try Pool.init();
    defer pool.deinit();
    var arena = Pool.ArenaAllocator.init(&pool);
    defer arena.deinit();

    // Attempt allocation larger than usable_memory
    const too_large = Pool.ArenaAllocator.largest_allocation_bytes + 1;
    const result = arena.pushArray(u8, too_large);
    try std.testing.expectError(error.OutOfMemory, result);
}

test "arena reset returns blocks" {
    const Pool = BufferPoolExtra(.{ .block_size = std.heap.page_size_min, .size_limit = 3, .metrics = true });
    var pool = try Pool.init();
    defer pool.deinit();
    var arena = Pool.ArenaAllocator.init(&pool);
    defer arena.deinit();

    const alloc_size = Pool.ArenaAllocator.largest_allocation_bytes;
    _ = try arena.pushArray(u8, alloc_size);
    _ = try arena.pushArray(u8, alloc_size);
    _ = try arena.pushArray(u8, alloc_size);

    try std.testing.expectEqual(@as(usize, 3), pool.metrics.acquires_current);

    arena.reset();

    try std.testing.expectEqual(@as(usize, 1), pool.metrics.acquires_current);

    const acquires_before = pool.metrics.acquires_total;
    _ = try arena.pushArray(u8, 100);
    try std.testing.expectEqual(acquires_before, pool.metrics.acquires_total);
}

test "arena deinit returns all blocks" {
    const Pool = BufferPoolExtra(.{ .block_size = std.heap.page_size_min, .size_limit = 5, .metrics = true });
    var pool = try Pool.init();
    defer pool.deinit();

    {
        var arena = Pool.ArenaAllocator.init(&pool);

        // Allocate across multiple blocks
        const alloc_size = Pool.ArenaAllocator.largest_allocation_bytes;
        _ = try arena.pushArray(u8, alloc_size);
        _ = try arena.pushArray(u8, alloc_size);
        _ = try arena.pushArray(u8, alloc_size);

        try std.testing.expectEqual(@as(usize, 3), pool.metrics.acquires_current);

        // Deinit arena
        arena.deinit();
    }

    // Verify all blocks returned to pool
    try std.testing.expectEqual(@as(usize, 0), pool.metrics.acquires_current);
    try std.testing.expectEqual(@as(usize, 3), pool.metrics.releases_total);
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
