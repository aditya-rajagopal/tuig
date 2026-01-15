//! Data structures for the unicode properties.

const std = @import("std");

pub const max_codepoint = 0x10FFFF;
pub const zero_width_joiner = 0x200D;
pub const zero_width_non_joiner = 0x200C;

pub const GraphemeBreakState = packed struct(u2) {
    extended_pictographic: bool = false,
    regional_indicator: bool = false,
};

pub const GraphemeBreakTestResult = packed struct {
    is_break: bool,
    state: GraphemeBreakState,
};

pub const GraphemeBreakCombination = packed struct(u10) {
    state: GraphemeBreakState,
    gbc1: GraphemeBoundryClass,
    gbc2: GraphemeBoundryClass,

    pub fn asUsize(self: @This()) usize {
        return @intCast(@as(u10, @bitCast(self)));
    }
};

pub const Property = packed struct {
    width: u2 = 0,
    grapheme_boundary_class: GraphemeBoundryClass = .invalid,

    pub const invalid = Property{ .width = 1, .grapheme_boundary_class = .invalid };

    pub fn format(self: Property, writer: *std.Io.Writer) !void {
        try writer.print(
            \\ .{{ .width = {d}, .grapheme_boundary_class = .{s} }}
        , .{ self.width, @tagName(self.grapheme_boundary_class) });
    }
};

// Reference:
// https://github.com/ghostty-org/ghostty/blob/2fd3efd6cdf0629f57572af58dff0ae9115ce919/src/unicode/props.zig#L50
pub const GraphemeBoundryClass = enum(u4) {
    // We will not need these as we can premeturely discard them
    // CR,
    // LF,
    // Control,
    invalid,
    prepend,
    extend,
    regional_indicator,
    spacing_mark,
    L,
    V,
    T,
    LV,
    LVT,
    zwj,
    extended_pictographic,
    extended_pictographic_base, // \p{ExtendedPictographic} & \p{Emoji_Modifier_Base}
    emoji_modifier, // \p{Emoji_Modifier}

    pub fn isExtendedPictographic(self: GraphemeBoundryClass) bool {
        switch (self) {
            .extended_pictographic, .extended_pictographic_base => return true,
            else => return false,
        }
    }
};
