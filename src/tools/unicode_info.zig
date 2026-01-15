const std = @import("std");
const assert = std.debug.assert;
const t = @import("unicode_types.zig");
const max_codepoint = @import("export/types.zig").max_codepoint;

pub const UnicodeInfo = @This();
emoji: []t.Emoji,
east_asian_width: []t.EastAsianWidth,
grapheme_break: []t.GraphemeBreakProperty,
derived_core_properties: []t.DerivedCoreProperties,
general_category: []t.GeneralCategory,

pub const Data = struct {
    emoji: t.Emoji,
    east_asian_width: t.EastAsianWidth,
    grapheme_break: t.GraphemeBreakProperty,
    derived_core_properties: t.DerivedCoreProperties,
    general_category: t.GeneralCategory,
};

pub fn get(self: UnicodeInfo, cp: u21) Data {
    assert(cp <= max_codepoint);
    return .{
        .emoji = self.emoji[cp],
        .east_asian_width = self.east_asian_width[cp],
        .grapheme_break = self.grapheme_break[cp],
        .derived_core_properties = self.derived_core_properties[cp],
        .general_category = self.general_category[cp],
    };
}

pub fn init(allocator: std.mem.Allocator) !UnicodeInfo {
    const east_asian_width: []t.EastAsianWidth = try std.heap.page_allocator.alloc(t.EastAsianWidth, max_codepoint + 1);
    errdefer allocator.free(east_asian_width);
    const grapheme_break: []t.GraphemeBreakProperty = try std.heap.page_allocator.alloc(t.GraphemeBreakProperty, max_codepoint + 1);
    errdefer allocator.free(grapheme_break);
    const emoji: []t.Emoji = try std.heap.page_allocator.alloc(t.Emoji, max_codepoint + 1);
    errdefer allocator.free(emoji);
    const derived_core_properties: []t.DerivedCoreProperties = try std.heap.page_allocator.alloc(t.DerivedCoreProperties, max_codepoint + 1);
    errdefer allocator.free(derived_core_properties);
    const general_category: []t.GeneralCategory = try std.heap.page_allocator.alloc(t.GeneralCategory, max_codepoint + 1);
    errdefer allocator.free(general_category);
    return UnicodeInfo{
        .emoji = emoji,
        .east_asian_width = east_asian_width,
        .grapheme_break = grapheme_break,
        .derived_core_properties = derived_core_properties,
        .general_category = general_category,
    };
}
