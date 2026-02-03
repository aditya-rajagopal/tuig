const std = @import("std");
const renderer = @import("renderer");
const rng = @import("rng.zig");
const text_mix = @import("text_mix.zig");

const bench_catalog = @import("bench_catalog.zig");

pub const PrintMode = enum {
    print,
    print_assume_no_grapheme,
};

pub fn buildPrintText(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    mix: text_mix.TextMix,
    seed: u64,
    target_cells: u32,
) !void {
    out.clearRetainingCapacity();

    var prng = rng.init(seed ^ 0x9e3779b97f4a7c15);
    const random = prng.random();
    var cell_count: u32 = 0;
    var word_index: u32 = 0;

    while (cell_count < target_cells) {
        const word_len = random.intRangeLessThan(u8, 3, 9);
        var i: u8 = 0;
        while (i < word_len) : (i += 1) {
            const glyph = text_mix.pickGlyph(random, mix);
            try out.appendSlice(allocator, glyph.bytes);
            cell_count += @as(u32, glyph.width);
        }

        word_index += 1;
        if (word_index % 25 == 0) {
            const long_len = random.intRangeLessThan(u8, 10, 18);
            var j: u8 = 0;
            try out.append(allocator, '\n');
            while (j < long_len) : (j += 1) {
                const glyph = text_mix.pickGlyph(random, mix);
                try out.appendSlice(allocator, glyph.bytes);
                cell_count += @as(u32, glyph.width);
            }
            try out.append(allocator, '\n');
        } else if (word_index % 12 == 0) {
            try out.append(allocator, '\n');
        } else if (word_index % 7 == 0) {
            try out.append(allocator, '\t');
        } else {
            try out.append(allocator, ' ');
        }
    }
}

pub fn printDatasetScissor(base: renderer.Scissor, dataset: bench_catalog.PrintDatasetSpec) renderer.Scissor {
    const base_w: i17 = @intCast(base.width_global);
    const base_h: i17 = @intCast(base.height_global);
    const width: i17 = @intCast(dataset.width);
    const height: i17 = @intCast(dataset.height);

    const offset: bench_catalog.PrintDatasetOffset = switch (dataset.origin) {
        .centered => .{ .x = @divTrunc(base_w - width, 2), .y = @divTrunc(base_h - height, 2) },
        .offset => |value| value,
    };

    return base.initChild(offset.x, offset.y, dataset.width, dataset.height);
}

pub fn renderPrintDataset(
    base: renderer.Scissor,
    dataset: bench_catalog.PrintDatasetSpec,
    mode: PrintMode,
    codepoint_buffer: []u21,
    text: []const u8,
    style_id: renderer.Style.Id,
) !renderer.Scissor.PrintResult {
    const scissor = printDatasetScissor(base, dataset);
    return switch (mode) {
        .print => try scissor.print(
            codepoint_buffer,
            text,
            0,
            0,
            .{ .wrap = true, .tab_width = 4, .style = style_id },
        ),
        .print_assume_no_grapheme => scissor.printAssumeNoGrapheme(
            text,
            0,
            0,
            .{ .wrap = true, .tab_width = 4, .style = style_id },
        ),
    };
}
