const std = @import("std");
const GraphemeIterator = @import("GraphemeIterator.zig");
const UTF8Decoder = @import("UTF8Decoder.zig");

pub fn main(init: std.process.Init) !void {
    const flag = try init.minimal.args.toSlice(init.arena.allocator());
    var buffer: [4096]u8 align(std.atomic.cache_line) = undefined;
    const file = try std.Io.Dir.cwd().openFile(init.io, "utf8_test.txt", .{});
    defer file.close(init.io);
    const stat = try file.stat(init.io);
    const memory = try init.arena.allocator().alignedAlloc(u8, .fromByteUnits(std.heap.page_size_min), stat.size);
    var file_reader = file.reader(init.io, &buffer);
    var r = &file_reader.interface;
    try r.readSliceAll(memory);

    if (flag[1][0] == '0') {
        for (memory) |*elem| {
            std.mem.doNotOptimizeAway(elem);
        }
    } else if (flag[1][0] == '1') {
        var iter: GraphemeIterator = try GraphemeIterator.init(memory);
        var codepoint_buffer: [16]u21 = undefined;
        while (try iter.next(&codepoint_buffer)) |result| {
            std.mem.doNotOptimizeAway(&result);
        }
    } else if (flag[1][0] == '2') {
        var decoder: UTF8Decoder = .start;
        for (memory) |c| {
            const codepoint, _ = decoder.decode(c);
            if (codepoint) |*cp| {
                std.mem.doNotOptimizeAway(cp);
            }
        }
    } else if (flag[1][0] == '3') {
        var uni = try std.unicode.Utf8View.init(memory);
        var iter = uni.iterator();
        while (iter.nextCodepoint()) |cp| {
            std.mem.doNotOptimizeAway(&cp);
        }
    }
}
