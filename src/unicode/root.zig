//! Unicode module

const types = @import("types.zig");
pub const max_codepoint = types.max_codepoint;
pub const zero_width_joiner = types.zero_width_joiner;
pub const zero_width_non_joiner = types.zero_width_non_joiner;
pub const GraphemeBreakState = types.GraphemeBreakState;
pub const GraphemeBreakTestResult = types.GraphemeBreakTestResult;
pub const GraphemeBreakCombination = types.GraphemeBreakCombination;
pub const Property = types.Property;
pub const GraphemeBoundaryClass = types.GraphemeBoundaryClass;

pub const getProperty = @import("properties.zig").getProperty;
pub const graphemeBreak = @import("grapheme_break.zig").graphemeBreak;

pub const UTF8Decoder = @import("UTF8Decoder.zig");
pub const GraphemeIterator = @import("GraphemeIterator.zig");

const std = @import("std");
test {
    _ = std.testing.refAllDecls(@This());
}
