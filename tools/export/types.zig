//! Data structures for the unicode properties.

const std = @import("std");

pub const max_codepoint = 0x10FFFF;
pub const zero_width_joiner = 0x200D;
pub const zero_width_non_joiner = 0x200C;

pub const GraphemeBreakState = enum(u3) {
    default,
    regional_indicator,
    extended_pictographic,
    InCB_consonant,
    InCB_linker,
};

pub const GraphemeBreakTestResult = packed struct {
    is_break: bool,
    state: GraphemeBreakState,
};

pub const GraphemeBreakCombination = packed struct(u13) {
    state: GraphemeBreakState,
    gbc1: GraphemeBoundaryClass,
    gbc2: GraphemeBoundaryClass,

    pub fn asUsize(self: @This()) usize {
        const classes = std.meta.fields(GraphemeBoundaryClass).len;
        return @intFromEnum(self.state) * classes * classes + @intFromEnum(self.gbc1) * classes + @intFromEnum(self.gbc2);
    }
};

pub const Property = packed struct(u8) {
    width: u2 = 0,
    grapheme_boundary_class: GraphemeBoundaryClass = .invalid,
    is_emoji_vs: bool = false,

    pub const invalid = Property{ .width = 1, .grapheme_boundary_class = .invalid, .is_emoji_vs = false };

    pub fn format(self: Property, writer: *std.Io.Writer) !void {
        try writer.print(
            \\ .{{ .width = {d}, .grapheme_boundary_class = .{s}, .is_emoji_vs = {any} }}
        , .{ self.width, @tagName(self.grapheme_boundary_class), self.is_emoji_vs });
    }
};

// Reference: LICENSE(MIT)
// https://github.com/jacobsandlund/uucode/blob/ad6f8813b9163bfc93626ebbc0f1023e11c51de7/src/x/types_x/grapheme.zig
pub const GraphemeBoundaryClass = enum(u5) {
    // We will not need these as we can premeturely discard them
    // CR,
    // LF,
    // Control,
    invalid,
    prepend,
    regional_indicator,
    spacing_mark,
    L,
    V,
    T,
    LV,
    LVT,
    zwj,
    zwnj,
    extended_pictographic,
    emoji_modifier_base,
    emoji_modifier,
    InCB_extend,
    InCB_linker,
    InCB_consonant,

    /// Check if the break class is a valid class to continue an extended pictograph
    pub fn isValidExtendedPictographic(self: GraphemeBoundaryClass) bool {
        return switch (self) {
            .zwj,
            .extended_pictographic,
            .emoji_modifier,
            .emoji_modifier_base,
            .zwnj,
            .InCB_extend,
            .InCB_linker,
            => return true,
            else => return false,
        };
    }

    pub fn isValidIndic(self: GraphemeBoundaryClass) bool {
        return switch (self) {
            .zwj, // This is the same as indic_conjunct_break_extend
            .InCB_extend,
            .InCB_linker,
            .InCB_consonant,
            => return true,
            else => return false,
        };
    }

    /// Check if this class can extend an indic sequence
    pub fn isIndicExtend(self: GraphemeBoundaryClass) bool {
        return switch (self) {
            .zwj,
            .InCB_extend,
            => return true,
            else => return false,
        };
    }

    pub fn isExtendedPictographic(self: GraphemeBoundaryClass) bool {
        return switch (self) {
            .extended_pictographic, .emoji_modifier_base => return true,
            else => return false,
        };
    }

    pub fn isExtention(self: GraphemeBoundaryClass) bool {
        return switch (self) {
            .zwnj, .InCB_extend, .InCB_linker => return true,
            else => return false,
        };
    }
};
