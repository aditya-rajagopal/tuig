const std = @import("std");

const bench_catalog = @import("bench_catalog.zig");
const patterns = @import("patterns.zig");
const renderer = @import("renderer");
const rng = @import("rng.zig");
const style_mix = @import("style_mix.zig");
const text_mix = @import("text_mix.zig");
const ui = @import("ui.zig");

const buffer_alignment = std.mem.Alignment.fromByteUnits(std.heap.page_size_min);

pub const DatasetAssets = struct {
    style_sheet: renderer.Style.Sheet,
    style_ids: []align(std.heap.page_size_min) renderer.Style.Id,
    pattern_state: patterns.PatternState,

    pub fn deinit(self: *DatasetAssets, allocator: std.mem.Allocator) void {
        self.pattern_state.deinit(allocator);
        self.style_sheet.deinit(allocator);
        allocator.free(self.style_ids);
    }
};

pub fn buildDatasetAssets(
    allocator: std.mem.Allocator,
    dataset: bench_catalog.DatasetSpec,
    text_mix_item: text_mix.TextMix,
    style_mix_item: style_mix.StyleMix,
    seed: u64,
    base_fb: *renderer.FrameBuffer,
) !DatasetAssets {
    const palette_len = style_mix.paletteLen(style_mix_item);
    var style_sheet = try renderer.Style.Sheet.initCapacity(allocator, palette_len);
    const style_ids = try allocator.alignedAlloc(renderer.Style.Id, buffer_alignment, palette_len);
    const style_slice = style_mix.fillStyleIds(&style_sheet, allocator, style_mix_item, style_ids);

    var prng = rng.init(seed);
    const random = prng.random();
    var style_sequence = style_mix.StyleSequence.init(style_mix_item, random, palette_len);
    var codepoint_buffer: [256]u21 = undefined;
    var ctx = ui.PrimitiveContext{
        .random = random,
        .text_mix = text_mix_item,
        .style_sequence = &style_sequence,
        .style_ids = style_slice,
        .codepoint_buffer = codepoint_buffer[0..],
    };

    try dataset.render(base_fb.scissor(), &ctx);

    const pattern_state = try patterns.PatternState.init(allocator, dataset.pattern, base_fb, seed, style_slice);

    return .{
        .style_sheet = style_sheet,
        .style_ids = style_ids,
        .pattern_state = pattern_state,
    };
}
