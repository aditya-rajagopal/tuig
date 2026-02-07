const std = @import("std");
const renderer = @import("renderer");
const rng = @import("rng.zig");
const text_mix = @import("text_mix.zig");
const testing = std.testing;

const bench_catalog = @import("bench_catalog.zig");

pub const PrintMode = enum {
    print,
    print_assume_no_grapheme,
};

fn resolveOffset(base: renderer.Scissor, dataset: bench_catalog.PrintDatasetSpec) bench_catalog.PrintDatasetOffset {
    const base_w: i17 = @intCast(base.width_global);
    const base_h: i17 = @intCast(base.height_global);
    const width: i17 = @intCast(dataset.width);
    const height: i17 = @intCast(dataset.height);

    return switch (dataset.origin) {
        .centered => .{ .x = @divTrunc(base_w - width, 2), .y = @divTrunc(base_h - height, 2) },
        .offset => |value| value,
    };
}

pub fn buildPrintText(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    mix: text_mix.TextMix,
    seed: u64,
    target_glyph_cells: u32,
) !void {
    out.clearRetainingCapacity();

    var prng = rng.init(seed ^ 0x9e3779b97f4a7c15);
    const random = prng.random();
    var cell_count: u32 = 0;
    var word_index: u32 = 0;

    while (cell_count < target_glyph_cells) {
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

pub fn renderPrintDataset(
    base: renderer.Scissor,
    dataset: bench_catalog.PrintDatasetSpec,
    mode: PrintMode,
    codepoint_buffer: []u21,
    text: []const u8,
    style_id: renderer.Style.Id,
) !renderer.Scissor.PrintResult {
    const offset = resolveOffset(base, dataset);

    const scissor = base.initChild(offset.x, offset.y, dataset.width, dataset.height);
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

test "renderPrintDataset preserves offscreen dataset logical and visible regions" {
    const fb_width: u16 = 20;
    const fb_height: u16 = 10;
    const cells = try testing.allocator.alloc(renderer.Cell, @as(usize, fb_width) * @as(usize, fb_height));
    defer testing.allocator.free(cells);

    var frame_buffer = try renderer.FrameBuffer.init(cells, fb_width, fb_height, .tiny);
    defer frame_buffer.deinit();

    const base = frame_buffer.scissor();
    const dataset = bench_catalog.print_datasets[2]; // scissor_out_of_bounds
    const offset = resolveOffset(base, dataset);
    const scissor = base.initChild(offset.x, offset.y, dataset.width, dataset.height);

    try testing.expectEqual(@as(i17, -5), scissor.x_global);
    try testing.expectEqual(@as(i17, -2), scissor.y_global);
    try testing.expectEqual(@as(u16, 40), scissor.width_global);
    try testing.expectEqual(@as(u16, 12), scissor.height_global);
    try testing.expectEqual(@as(u16, 5), scissor.x_clip);
    try testing.expectEqual(@as(u16, 2), scissor.y_clip);
    try testing.expectEqual(@as(u16, 20), scissor.width_clip);
    try testing.expectEqual(@as(u16, 10), scissor.height_clip);

    var text: [120]u8 = undefined;
    @memset(text[0..], 'A');
    var codepoint_buffer: [256]u21 = undefined;

    frame_buffer.clear();
    const result_print = try renderPrintDataset(base, dataset, .print, codepoint_buffer[0..], text[0..], .default);
    try testing.expectEqual(@as(usize, text.len), result_print.bytes_consumed);
    try testing.expectEqual(@as(usize, 20), result_print.graphemes_rendered);
    try testing.expectEqual(@as(u21, 'A'), frame_buffer.get(0, 0).data.codepoint);
    try testing.expectEqual(@as(u21, 'A'), frame_buffer.get(19, 0).data.codepoint);
    try testing.expectEqual(@as(u21, ' '), frame_buffer.get(0, 1).data.codepoint);

    frame_buffer.clear();
    const result_no_grapheme = try renderPrintDataset(base, dataset, .print_assume_no_grapheme, codepoint_buffer[0..], text[0..], .default);
    try testing.expectEqual(@as(usize, text.len), result_no_grapheme.bytes_consumed);
    try testing.expectEqual(@as(usize, 20), result_no_grapheme.graphemes_rendered);
    try testing.expectEqual(@as(u21, 'A'), frame_buffer.get(0, 0).data.codepoint);
    try testing.expectEqual(@as(u21, 'A'), frame_buffer.get(19, 0).data.codepoint);
    try testing.expectEqual(@as(u21, ' '), frame_buffer.get(0, 1).data.codepoint);
}
