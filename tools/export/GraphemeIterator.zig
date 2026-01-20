//! Grapheme cluster breaking

const std = @import("std");
const assert = std.debug.assert;

const t = @import("types.zig");
const GraphemeBoundryClass = t.GraphemeBoundryClass;
const Property = t.Property;

const graphemeBreak = @import("grapheme_break.zig").graphemeBreak;
const graphemeBreakClass = @import("grapheme_break.zig").graphemeBreakClass;
const getProperty = @import("properties.zig").getProperty;
const UTF8Decoder = @import("UTF8Decoder.zig");

const GraphemeIterator = @This();

text: []const u8,
i: usize,
cursor: Codepoint,

const Codepoint = packed struct(u32) {
    codepoint: u21 = 0,
    prop: t.Property = .{},
    bytes: u3 = 0,
    _: u2 = 0,
};

pub const empty: GraphemeIterator = .{ .text = &.{}, .i = 0, .cursor = .{} };

pub fn init(text: []const u8) error{ InvalidUtf8String, EmptyString }!GraphemeIterator {
    var iter: GraphemeIterator = .empty;
    iter.text = text;
    iter.i = 0;
    iter.cursor = .{};
    iter.cursor.codepoint, iter.cursor.bytes = (nextCodepoint(text) catch return error.InvalidUtf8String) orelse return error.EmptyString;
    iter.cursor.prop = getProperty(iter.cursor.codepoint);
    // NOTE(adi): The first codepoint should always be a break
    return iter;
}

pub inline fn nextCodepoint(text: []const u8) error{Utf8InvalidStartByte}!?struct { u21, u3 } {
    if (text.len == 0) {
        return null;
    }
    if (text[0] <= 0x7F) {
        @branchHint(.likely);
        return .{ text[0], 1 };
    }
    var decoder: UTF8Decoder = .start;

    const len: u3 = switch (text[0]) {
        0b0000_0000...0b0111_1111 => unreachable,
        0b1100_0000...0b1101_1111 => 2,
        0b1110_0000...0b1110_1111 => 3,
        0b1111_0000...0b1111_0111 => 4,
        else => return error.Utf8InvalidStartByte,
    };
    if (text.len < len) {
        @branchHint(.unlikely);
        return .{ 0xFFFD, @intCast(text.len) };
    }

    for (0..len) |i| {
        const codepoint, const consumed = decoder.decode(text[i]);
        if (!consumed) {
            @branchHint(.cold);
            assert(codepoint != null and codepoint.? == 0xFFFD);
            return .{ 0xFFFD, @intCast(i) };
        }
        if (codepoint) |cp| {
            assert(i == len - 1);
            return .{ cp, len };
        }
    } else {
        @branchHint(.cold);
        return .{ 0xFFFD, len };
    }
}

pub const Result = struct {
    width: u16,
    grapheme: []u21,
    bytes: []const u8,
};

pub fn next(self: *GraphemeIterator, codepoint_buffer: []u21) error{Utf8InvalidStartByte}!?Result {
    if (self.i == self.text.len) return null;

    var is_break = false;
    var width: u16 = 0;
    var consumed: usize = 0;
    var prev: GraphemeBoundryClass = .invalid;
    var state: t.GraphemeBreakState = .{};
    var i: usize = 0;
    defer self.i += consumed;

    assert(i < codepoint_buffer.len);
    codepoint_buffer[i] = self.cursor.codepoint;
    i += 1;
    prev = self.cursor.prop.grapheme_boundary_class;
    if (self.cursor.codepoint == 0xFE0F) {
        // Variation emoji selector
        width = 2;
    } else if (self.cursor.codepoint == 0xFE0E) {
        // Variation text selector
        width = 1;
    } else {
        width = @min(2, width + self.cursor.prop.width);
    }
    consumed += self.cursor.bytes;
    self.cursor.codepoint, self.cursor.bytes = (nextCodepoint(self.text[self.i + consumed ..]) catch {
        @branchHint(.unlikely);
        return error.Utf8InvalidStartByte;
    }) orelse {
        @branchHint(.unlikely);
        return .{ .width = width, .grapheme = codepoint_buffer[0..i], .bytes = self.text[self.i..][0..consumed] };
    };
    self.cursor.prop = getProperty(self.cursor.codepoint);
    is_break = @call(.always_inline, graphemeBreakClass, .{ prev, self.cursor.prop.grapheme_boundary_class, &state });

    if (!is_break) {
        while (!is_break) {
            assert(i < codepoint_buffer.len);
            codepoint_buffer[i] = self.cursor.codepoint;
            i += 1;
            prev = self.cursor.prop.grapheme_boundary_class;
            if (self.cursor.codepoint == 0xFE0F) {
                // Variation emoji selector
                width = 2;
            } else if (self.cursor.codepoint == 0xFE0E) {
                // Variation text selector
                width = 1;
            } else {
                width = @min(2, width + self.cursor.prop.width);
            }
            consumed += self.cursor.bytes;
            self.cursor.codepoint, self.cursor.bytes = (nextCodepoint(self.text[self.i + consumed ..]) catch {
                @branchHint(.unlikely);
                return error.Utf8InvalidStartByte;
            }) orelse {
                @branchHint(.unlikely);
                return .{ .width = width, .grapheme = codepoint_buffer[0..i], .bytes = self.text[self.i..][0..consumed] };
            };
            self.cursor.prop = getProperty(self.cursor.codepoint);
            is_break = @call(.always_inline, graphemeBreakClass, .{ prev, self.cursor.prop.grapheme_boundary_class, &state });
        }
    } else {
        @branchHint(.likely);
    }
    return .{ .width = width, .grapheme = codepoint_buffer[0..i], .bytes = self.text[self.i..][0..consumed] };
}

const TestCase = struct {
    input: []const u8,
    expected_byte_len: usize,
    expected_cell_width: usize,
    expected_codepoint_count: usize,
};

const testPrint = struct {
    fn print(sequence: []const u8) void {
        var buffer: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);

        writer.writeAll("Sequence '") catch unreachable;
        for (sequence) |c| {
            if (c == '\x1b') writer.writeAll("\\x1b") catch unreachable else writer.writeByte(c) catch unreachable;
        }
        writer.writeAll("' failed:") catch unreachable;
        std.log.err("{s}", .{writer.buffered()});
    }
}.print;

fn testGraphemeIterator(comptime test_cases: []const TestCase) error{TestExpectedEqual}!void {
    var error_out: ?error{TestExpectedEqual} = null;

    inline for (test_cases) |test_case| {
        var error_this_test: bool = false;
        var iter = GraphemeIterator.init(test_case.input) catch return error.TestExpectedEqual;
        var codepoint_buffer: [test_case.expected_codepoint_count]u21 = undefined;
        const result = (iter.next(&codepoint_buffer) catch return error.TestExpectedEqual) orelse return error.TestExpectedEqual;

        const byte_len = iter.i;
        const cell_width = result.width;

        if (byte_len != test_case.expected_byte_len) {
            if (!error_this_test) testPrint(test_case.input);
            std.log.err("Failed byte_len: expected {d}, found {d}", .{ test_case.expected_byte_len, byte_len });
            error_out = error.TestExpectedEqual;
            error_this_test = true;
        }

        if (cell_width != test_case.expected_cell_width) {
            if (!error_this_test) testPrint(test_case.input);
            std.log.err("Failed cell_width: expected {d}, found {d}", .{ test_case.expected_cell_width, cell_width });
            error_out = error.TestExpectedEqual;
            error_this_test = true;
        }
        if (result.grapheme.len != test_case.expected_codepoint_count) {
            if (!error_this_test) testPrint(test_case.input);
            std.log.err("Failed codepoint count: expected {d}, found {d}", .{ test_case.expected_codepoint_count, result.grapheme.len });
            error_out = error.TestExpectedEqual;
            error_this_test = true;
        }
        if (error_this_test) std.log.err("---------------------------------------", .{});
    }
}

test "GraphemeIterator basic ASCII" {
    const test_cases = [_]TestCase{
        .{ .input = "A", .expected_byte_len = 1, .expected_cell_width = 1, .expected_codepoint_count = 1 },
        .{ .input = "Hello", .expected_byte_len = 1, .expected_cell_width = 1, .expected_codepoint_count = 1 },
        .{ .input = " ", .expected_byte_len = 1, .expected_cell_width = 1, .expected_codepoint_count = 1 },
        .{ .input = "123", .expected_byte_len = 1, .expected_cell_width = 1, .expected_codepoint_count = 1 },
    };

    try testGraphemeIterator(&test_cases);
}

test "GraphemeIterator multi-byte Unicode" {
    const test_cases = [_]TestCase{
        // Two-byte (é = U+00E9)
        .{ .input = "\xC3\xA9", .expected_byte_len = 2, .expected_cell_width = 1, .expected_codepoint_count = 1 },
        // Three-byte (中 = U+4E2D)
        .{ .input = "\xE4\xB8\xAD", .expected_byte_len = 3, .expected_cell_width = 2, .expected_codepoint_count = 1 },
        // Four-byte emoji (😀 = U+1F600)
        .{ .input = "\xF0\x9F\x98\x80", .expected_byte_len = 4, .expected_cell_width = 2, .expected_codepoint_count = 1 },
        // Euro symbol (€ = U+20AC)
        .{ .input = "\xE2\x82\xAC", .expected_byte_len = 3, .expected_cell_width = 1, .expected_codepoint_count = 1 },
    };

    try testGraphemeIterator(&test_cases);
}

test "GraphemeIterator combining marks" {
    const test_cases = [_]TestCase{
        // e + combining acute accent = é (2 codepoints, 1 grapheme)
        .{ .input = "e\xCC\x81", .expected_byte_len = 3, .expected_cell_width = 1, .expected_codepoint_count = 2 },
        // e + combining acute + combining grave (3 codepoints)
        .{ .input = "e\xCC\x81\xCC\x80", .expected_byte_len = 5, .expected_cell_width = 1, .expected_codepoint_count = 3 },
        // a + combining circumflex + combining tilde (3 codepoints)
        .{ .input = "a\xCC\x82\xCC\x83", .expected_byte_len = 5, .expected_cell_width = 1, .expected_codepoint_count = 3 },
    };

    try testGraphemeIterator(&test_cases);
}

test "GraphemeIterator mixed scripts" {
    const test_cases = [_]TestCase{
        .{ .input = "Hello", .expected_byte_len = 1, .expected_cell_width = 1, .expected_codepoint_count = 1 },
        .{ .input = "世界", .expected_byte_len = 3, .expected_cell_width = 2, .expected_codepoint_count = 1 },
        .{ .input = "Hello 世界", .expected_byte_len = 1, .expected_cell_width = 1, .expected_codepoint_count = 1 },
    };

    try testGraphemeIterator(&test_cases);
}

test "GraphemeIterator emoji modifiers" {
    const test_cases = [_]TestCase{
        // 👨🏽 = man + fitzpatrick type-4
        .{
            .input = "\xF0\x9F\x91\xA8\xF0\x9F\x8F\xBD",
            .expected_byte_len = 8,
            .expected_cell_width = 2,
            .expected_codepoint_count = 2,
        },
    };

    try testGraphemeIterator(&test_cases);
}

test "GraphemeIterator multiple iterations" {
    const text: []const u8 = "Hello世界";
    const expected_sequence = [_][]const u8{ "H", "e", "l", "l", "o", "世", "界" };
    const expected_codepoints = [_][]const u21{ &.{'H'}, &.{'e'}, &.{'l'}, &.{'l'}, &.{'o'}, &.{0x4E16}, &.{0x754C} };
    var iter = try GraphemeIterator.init(text);
    var iterations: usize = 0;
    var codepoint_buffer: [text.len]u21 = undefined;

    while (try iter.next(&codepoint_buffer)) |result| {
        try std.testing.expectEqualStrings(expected_sequence[iterations], result.bytes);
        try std.testing.expectEqualSlices(u21, expected_codepoints[iterations], result.grapheme);
        iterations += 1;
    }

    // Should iterate 7 times: H,e,l,l,o,世,界
    try std.testing.expectEqual(@as(usize, 7), iterations);
}

test "GraphemeIterator ZWJ sequences and variation selectors" {
    const test_cases = [_]TestCase{
        // 👨‍👩 = 3 codepoints (2 emojis + ZWJ)
        .{
            .input = "\xF0\x9F\x91\xA8\xE2\x80\x8D\xF0\x9F\x91\xA9",
            .expected_byte_len = 11,
            .expected_cell_width = 2,
            .expected_codepoint_count = 3,
        },
        // 👨‍👩‍👧‍👦 = 7 codepoints (4 emojis + 3 ZWJs)
        .{
            .input = "\xF0\x9F\x91\xA8\xE2\x80\x8D\xF0\x9F\x91\xA9\xE2\x80\x8D\xF0\x9F\x91\xA7\xE2\x80\x8D\xF0\x9F\x91\xA6",
            .expected_byte_len = 25,
            .expected_cell_width = 2,
            .expected_codepoint_count = 7,
        },
        .{
            .input = "❤",
            .expected_byte_len = 3,
            .expected_cell_width = 1,
            .expected_codepoint_count = 1,
        },
        // ❤️ = 2 codepoints with variation selector
        .{
            .input = "❤️",
            .expected_byte_len = 6,
            .expected_cell_width = 2,
            .expected_codepoint_count = 2,
        },
        .{
            .input = "💙",
            .expected_byte_len = 4,
            .expected_cell_width = 2,
            .expected_codepoint_count = 1,
        },
    };

    try testGraphemeIterator(&test_cases);
}

test "GraphemeIterator regional indicators (emoji flags)" {
    const test_cases = [_]TestCase{
        // 🇺🇸 = 2 regional indicators
        .{
            .input = "\xF0\x9F\x87\xBA\xF0\x9F\x87\xB8",
            .expected_byte_len = 8,
            .expected_cell_width = 2,
            .expected_codepoint_count = 2,
        },
    };

    try testGraphemeIterator(&test_cases);
}
