const renderer = @import("renderer");
const patterns = @import("patterns.zig");
const style_mix = @import("style_mix.zig");
const text_mix = @import("text_mix.zig");
const ui = @import("ui.zig");

pub const DatasetSpec = struct {
    name: []const u8,
    render: *const fn (renderer.Scissor, *ui.PrimitiveContext) renderer.Scissor.PrintError!void,
    pattern: patterns.Pattern,
};

pub const PrintDatasetOffset = struct { x: i17, y: i17 };

pub const PrintDatasetOrigin = union(enum) {
    centered,
    offset: PrintDatasetOffset,
};

pub const PrintDatasetSpec = struct {
    name: []const u8,
    width: u16,
    height: u16,
    origin: PrintDatasetOrigin,
};

pub const dataset_typical_panel_swap = DatasetSpec{
    .name = "typical_app_panel_swap",
    .render = ui.datasetTypical,
    .pattern = .panel_swap,
};
pub const dataset_typical_cursor_moves = DatasetSpec{
    .name = "typical_app_cursor_moves",
    .render = ui.datasetTypical,
    .pattern = .cursor_move,
};
pub const dataset_unicode_width_churn = DatasetSpec{
    .name = "unicode_stress_width_churn",
    .render = ui.datasetUnicodeStress,
    .pattern = .unicode_width_churn,
};
pub const dataset_unicode_style_flicker = DatasetSpec{
    .name = "unicode_stress_style_flicker",
    .render = ui.datasetUnicodeStress,
    .pattern = .style_flicker,
};
pub const dataset_unicode_dynamic_rect = DatasetSpec{
    .name = "unicode_dynamic_rect_churn",
    .render = ui.datasetDynamic,
    .pattern = .rect_churn,
};

pub const render_datasets = [_]DatasetSpec{
    dataset_typical_panel_swap,
    dataset_typical_cursor_moves,
    dataset_unicode_width_churn,
    dataset_unicode_style_flicker,
    dataset_unicode_dynamic_rect,
};

pub const print_datasets = [_]PrintDatasetSpec{
    .{ .name = "scissor_small", .width = 20, .height = 6, .origin = .centered },
    .{ .name = "scissor_large", .width = 40, .height = 12, .origin = .centered },
    .{ .name = "scissor_out_of_bounds", .width = 40, .height = 12, .origin = .{ .offset = .{ .x = -5, .y = -2 } } },
};

pub const all_text_mixes = [_]text_mix.TextMix{
    .common,
    .grapheme_stress,
};

pub const all_style_mixes = [_]style_mix.StyleMix{
    .flat,
    .themed,
    .churn,
};
