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
};

pub const empty: GraphemeIterator = .{ .text = &.{}, .i = 0, .cursor = .{} };

pub fn init(text: []const u8) error{EmptyString}!GraphemeIterator {
    var iter: GraphemeIterator = .empty;
    iter.text = text;
    iter.i = 0;
    iter.cursor = .{};
    iter.cursor.codepoint, iter.cursor.bytes = nextCodepoint(text, 0) orelse return error.EmptyString;
    iter.cursor.prop = getProperty(iter.cursor.codepoint);
    // NOTE(adi): The first codepoint should always be a break
    return iter;
}

pub fn nextCodepoint(data: []const u8, offset: usize) ?struct { u21, u3 } {
    if (offset >= data.len) return null;
    const text = data[offset..];
    if (text[0] <= 0x7F) {
        @branchHint(.likely);
        return .{ text[0], 1 };
    }

    var decoder: UTF8Decoder = .start;

    for (0..@min(4, text.len)) |i| {
        const codepoint, const consumed = decoder.decode(text[i]);
        if (!consumed) {
            @branchHint(.cold);
            assert(codepoint != null and codepoint.? == 0xFFFD);
            return .{ 0xFFFD, @intCast(i + 1) };
        }
        if (codepoint) |cp| {
            return .{ cp, @intCast(i + 1) };
        }
    } else {
        @branchHint(.cold);
        return .{ 0xFFFD, @min(4, text.len) };
    }
}

inline fn isControlOrCRLF(cp: u21) bool {
    return switch (cp) {
        0x00...0x09,
        0x0B...0x0C,
        0x0E...0x1F, // C0 except LF (0x0A) and CR (0x0D)
        0x0A, // LF
        0x0D, // CR
        0x7F, // DEL
        0x80...0x9F, // C1
        => true,
        else => false,
    };
}

pub const Result = struct {
    width: u16,
    grapheme: []u21,
    bytes: []const u8,
};

pub fn next(self: *GraphemeIterator, codepoint_buffer: []u21) ?Result {
    if (self.i == self.text.len) return null;

    // NOTE(adi): Always take the first codepoint available
    assert(codepoint_buffer.len > 0);
    codepoint_buffer[0] = self.cursor.codepoint;
    var consumed: usize = self.cursor.bytes;
    defer self.i += consumed;
    var width: u16 = self.cursor.prop.width;
    var i: usize = 1;

    if (isControlOrCRLF(self.cursor.codepoint)) {
        @branchHint(.unlikely);
        self.cursor.codepoint, self.cursor.bytes = @call(.always_inline, nextCodepoint, .{ self.text, self.i + consumed }) orelse .{ 0, 0 };
        if (self.cursor.codepoint != 0) {
            self.cursor.prop = getProperty(self.cursor.codepoint);
        }

        if (codepoint_buffer[0] == '\r') {
            if (self.cursor.codepoint == '\n') {
                codepoint_buffer[i] = self.cursor.codepoint;
                consumed += self.cursor.bytes;
                i = 2;
                self.cursor.codepoint, self.cursor.bytes = @call(.always_inline, nextCodepoint, .{ self.text, self.i + consumed }) orelse .{ 0, 0 };
                if (self.cursor.codepoint != 0) {
                    self.cursor.prop = getProperty(self.cursor.codepoint);
                }
            }
        }

        return .{ .width = 0, .grapheme = codepoint_buffer[0..i], .bytes = self.text[self.i..][0..consumed] };
    }

    var state: t.GraphemeBreakState = .default;
    var prev = self.cursor;

    while (true) {
        self.cursor.codepoint, self.cursor.bytes = @call(.always_inline, nextCodepoint, .{ self.text, self.i + consumed }) orelse {
            @branchHint(.unlikely);
            return .{ .width = width, .grapheme = codepoint_buffer[0..i], .bytes = self.text[self.i..][0..consumed] };
        };
        self.cursor.prop = getProperty(self.cursor.codepoint);

        if (isControlOrCRLF(self.cursor.codepoint)) {
            @branchHint(.unlikely);
            break;
        }

        if (graphemeBreakClass(prev.prop.grapheme_boundary_class, self.cursor.prop.grapheme_boundary_class, &state)) {
            @branchHint(.likely);
            break;
        }

        if (self.cursor.codepoint == 0xFE0F) {
            // Variation emoji selector
            if (prev.prop.is_emoji_vs) {
                width = 2;
            } else {
                // NOTE(adi): Consume the bytes but ignore the codepoint
                consumed += self.cursor.bytes;
                continue;
            }
        } else if (self.cursor.codepoint == 0xFE0E) {
            // Variation text selector
            if (prev.prop.is_emoji_vs) {
                width = 1;
            } else {
                // NOTE(adi): Consume the bytes but ignore the codepoint
                consumed += self.cursor.bytes;
                continue;
            }
        } else {
            @branchHint(.likely);
            width = @min(2, width + self.cursor.prop.width);
        }

        prev = self.cursor;
        assert(i < codepoint_buffer.len);
        codepoint_buffer[i] = self.cursor.codepoint;
        i += 1;
        consumed += self.cursor.bytes;
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
        const result = iter.next(&codepoint_buffer) orelse return error.TestExpectedEqual;

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

    while (iter.next(&codepoint_buffer)) |result| {
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
        .{
            .input = "❤",
            .expected_byte_len = 3,
            .expected_cell_width = 1,
            .expected_codepoint_count = 1,
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

test "GraphemeIterator variation selector edge cases" {
    const test_cases = [_]TestCase{
        // VS16 on non-emoji character should be ignored (A + VS16 = 2 codepoints, width 1)
        .{
            .input = "A\xEF\xB8\x8F", // A + U+FE0F
            .expected_byte_len = 4,
            .expected_cell_width = 1,
            .expected_codepoint_count = 1,
        },
        // VS15 on non-emoji character should be ignored
        .{
            .input = "A\xEF\xB8\x8E", // A + U+FE0E
            .expected_byte_len = 4,
            .expected_cell_width = 1,
            .expected_codepoint_count = 1,
        },
        // ❤ (U+2764) alone - text presentation default, width 1
        .{
            .input = "\xE2\x9D\xA4",
            .expected_byte_len = 3,
            .expected_cell_width = 1,
            .expected_codepoint_count = 1,
        },
        // ❤ + VS16 - emoji presentation, width 2
        .{
            .input = "\xE2\x9D\xA4\xEF\xB8\x8F", // ❤️
            .expected_byte_len = 6,
            .expected_cell_width = 2,
            .expected_codepoint_count = 2,
        },
        // ❤ + VS15 - explicitly text presentation, width 1
        .{
            .input = "\xE2\x9D\xA4\xEF\xB8\x8E",
            .expected_byte_len = 6,
            .expected_cell_width = 1,
            .expected_codepoint_count = 2,
        },
        // 😀 (U+1F600) alone - emoji presentation default, width 2
        .{
            .input = "\xF0\x9F\x98\x80",
            .expected_byte_len = 4,
            .expected_cell_width = 2,
            .expected_codepoint_count = 1,
        },
        // 😀 + VS15 - most terminals ignore VS15 on default emoji, width 2
        .{
            .input = "\xF0\x9F\x98\x80\xEF\xB8\x8E",
            .expected_byte_len = 7,
            .expected_cell_width = 2,
            .expected_codepoint_count = 1,
        },
        // 😀 + VS16 - redundant but valid, width 2
        .{
            .input = "\xF0\x9F\x98\x80\xEF\xB8\x8F",
            .expected_byte_len = 7,
            .expected_cell_width = 2,
            .expected_codepoint_count = 1,
        },
        // ↔ (U+2194) - has emoji variation but default text, width 1
        .{
            .input = "\xE2\x86\x94",
            .expected_byte_len = 3,
            .expected_cell_width = 1,
            .expected_codepoint_count = 1,
        },
        // ↔ + VS16 - emoji presentation, width 2
        .{
            .input = "\xE2\x86\x94\xEF\xB8\x8F",
            .expected_byte_len = 6,
            .expected_cell_width = 2,
            .expected_codepoint_count = 2,
        },
        // ☀ (U+2600) - sun, text default
        .{
            .input = "\xE2\x98\x80",
            .expected_byte_len = 3,
            .expected_cell_width = 1,
            .expected_codepoint_count = 1,
        },
        // ☀️ - sun with VS16
        .{
            .input = "\xE2\x98\x80\xEF\xB8\x8F",
            .expected_byte_len = 6,
            .expected_cell_width = 2,
            .expected_codepoint_count = 2,
        },
    };

    try testGraphemeIterator(&test_cases);
}

test "GraphemeIterator keycap sequences" {
    const test_cases = [_]TestCase{
        // 1️⃣ = 1 + VS16 + U+20E3 (combining enclosing keycap)
        .{
            .input = "1\xEF\xB8\x8F\xE2\x83\xA3",
            .expected_byte_len = 7,
            .expected_cell_width = 2,
            .expected_codepoint_count = 3,
        },
        // #️⃣ = # + VS16 + U+20E3
        .{
            .input = "#\xEF\xB8\x8F\xE2\x83\xA3",
            .expected_byte_len = 7,
            .expected_cell_width = 2,
            .expected_codepoint_count = 3,
        },
        // *️⃣ = * + VS16 + U+20E3
        .{
            .input = "*\xEF\xB8\x8F\xE2\x83\xA3",
            .expected_byte_len = 7,
            .expected_cell_width = 2,
            .expected_codepoint_count = 3,
        },
        // 0️⃣ through 9️⃣
        .{
            .input = "0\xEF\xB8\x8F\xE2\x83\xA3",
            .expected_byte_len = 7,
            .expected_cell_width = 2,
            .expected_codepoint_count = 3,
        },
        // Keycap without VS16 (less common but valid): 1 + U+20E3
        .{
            .input = "1\xE2\x83\xA3",
            .expected_byte_len = 4,
            .expected_cell_width = 1, // text presentation without VS16
            .expected_codepoint_count = 2,
        },
    };

    try testGraphemeIterator(&test_cases);
}

test "GraphemeIterator tag sequences" {
    const test_cases = [_]TestCase{
        // 🏴󠁧󠁢󠁥󠁮󠁧󠁿 England flag = U+1F3F4 + regional tags + U+E007F (cancel tag)
        // U+1F3F4 (black flag) + gbeng + cancel
        .{
            .input = "\xF0\x9F\x8F\xB4\xF3\xA0\x81\xA7\xF3\xA0\x81\xA2\xF3\xA0\x81\xA5\xF3\xA0\x81\xAE\xF3\xA0\x81\xA7\xF3\xA0\x81\xBF",
            .expected_byte_len = 28,
            .expected_cell_width = 2,
            .expected_codepoint_count = 7, // flag + 5 tags + cancel
        },
        // 🏴󠁧󠁢󠁳󠁣󠁴󠁿 Scotland flag
        .{
            .input = "\xF0\x9F\x8F\xB4\xF3\xA0\x81\xA7\xF3\xA0\x81\xA2\xF3\xA0\x81\xB3\xF3\xA0\x81\xA3\xF3\xA0\x81\xB4\xF3\xA0\x81\xBF",
            .expected_byte_len = 28,
            .expected_cell_width = 2,
            .expected_codepoint_count = 7,
        },
        // 🏴󠁧󠁢󠁷󠁬󠁳󠁿 Wales flag
        .{
            .input = "\xF0\x9F\x8F\xB4\xF3\xA0\x81\xA7\xF3\xA0\x81\xA2\xF3\xA0\x81\xB7\xF3\xA0\x81\xAC\xF3\xA0\x81\xB3\xF3\xA0\x81\xBF",
            .expected_byte_len = 28,
            .expected_cell_width = 2,
            .expected_codepoint_count = 7,
        },
    };

    try testGraphemeIterator(&test_cases);
}

test "GraphemeIterator complex ZWJ sequences" {
    const test_cases = [_]TestCase{
        // 👨‍💻 man technologist = man + ZWJ + laptop
        .{
            .input = "\xF0\x9F\x91\xA8\xE2\x80\x8D\xF0\x9F\x92\xBB",
            .expected_byte_len = 11,
            .expected_cell_width = 2,
            .expected_codepoint_count = 3,
        },
        // 👩‍❤️‍👨 couple with heart = woman + ZWJ + heart + VS16 + ZWJ + man
        .{
            .input = "\xF0\x9F\x91\xA9\xE2\x80\x8D\xE2\x9D\xA4\xEF\xB8\x8F\xE2\x80\x8D\xF0\x9F\x91\xA8",
            .expected_byte_len = 20,
            .expected_cell_width = 2,
            .expected_codepoint_count = 6,
        },
        // 👨‍👩‍👧‍👦 family = 4 people + 3 ZWJs (already tested, keeping for completeness)
        .{
            .input = "\xF0\x9F\x91\xA8\xE2\x80\x8D\xF0\x9F\x91\xA9\xE2\x80\x8D\xF0\x9F\x91\xA7\xE2\x80\x8D\xF0\x9F\x91\xA6",
            .expected_byte_len = 25,
            .expected_cell_width = 2,
            .expected_codepoint_count = 7,
        },
        // 🧑‍🤝‍🧑 people holding hands (gender neutral)
        .{
            .input = "\xF0\x9F\xA7\x91\xE2\x80\x8D\xF0\x9F\xA4\x9D\xE2\x80\x8D\xF0\x9F\xA7\x91",
            .expected_byte_len = 18,
            .expected_cell_width = 2,
            .expected_codepoint_count = 5,
        },
        // 🏳️‍🌈 rainbow flag = white flag + VS16 + ZWJ + rainbow
        .{
            .input = "\xF0\x9F\x8F\xB3\xEF\xB8\x8F\xE2\x80\x8D\xF0\x9F\x8C\x88",
            .expected_byte_len = 14,
            .expected_cell_width = 2,
            .expected_codepoint_count = 4,
        },
        // 🏳️‍⚧️ transgender flag = white flag + VS16 + ZWJ + trans symbol + VS16
        // 4 + 3 + 3 + 3 + 3 = 16 bytes
        .{
            .input = "\xF0\x9F\x8F\xB3\xEF\xB8\x8F\xE2\x80\x8D\xE2\x9A\xA7\xEF\xB8\x8F",
            .expected_byte_len = 16,
            .expected_cell_width = 2,
            .expected_codepoint_count = 5,
        },
        // 👁️‍🗨️ eye in speech bubble
        .{
            .input = "\xF0\x9F\x91\x81\xEF\xB8\x8F\xE2\x80\x8D\xF0\x9F\x97\xA8\xEF\xB8\x8F",
            .expected_byte_len = 17,
            .expected_cell_width = 2,
            .expected_codepoint_count = 5,
        },
    };

    try testGraphemeIterator(&test_cases);
}

test "GraphemeIterator skin tone combinations" {
    const test_cases = [_]TestCase{
        // All 5 Fitzpatrick skin tones with waving hand
        // 👋🏻 light
        .{
            .input = "\xF0\x9F\x91\x8B\xF0\x9F\x8F\xBB",
            .expected_byte_len = 8,
            .expected_cell_width = 2,
            .expected_codepoint_count = 2,
        },
        // 👋🏼 medium-light
        .{
            .input = "\xF0\x9F\x91\x8B\xF0\x9F\x8F\xBC",
            .expected_byte_len = 8,
            .expected_cell_width = 2,
            .expected_codepoint_count = 2,
        },
        // 👋🏽 medium
        .{
            .input = "\xF0\x9F\x91\x8B\xF0\x9F\x8F\xBD",
            .expected_byte_len = 8,
            .expected_cell_width = 2,
            .expected_codepoint_count = 2,
        },
        // 👋🏾 medium-dark
        .{
            .input = "\xF0\x9F\x91\x8B\xF0\x9F\x8F\xBE",
            .expected_byte_len = 8,
            .expected_cell_width = 2,
            .expected_codepoint_count = 2,
        },
        // 👋🏿 dark
        .{
            .input = "\xF0\x9F\x91\x8B\xF0\x9F\x8F\xBF",
            .expected_byte_len = 8,
            .expected_cell_width = 2,
            .expected_codepoint_count = 2,
        },
        // 🤝🏻 handshake with skin tone (single modifier)
        .{
            .input = "\xF0\x9F\xA4\x9D\xF0\x9F\x8F\xBB",
            .expected_byte_len = 8,
            .expected_cell_width = 2,
            .expected_codepoint_count = 2,
        },
    };

    try testGraphemeIterator(&test_cases);
}

test "GraphemeIterator regional indicator edge cases" {
    // Test iteration to verify pairs break correctly
    const text = "\xF0\x9F\x87\xBA\xF0\x9F\x87\xB8\xF0\x9F\x87\xAC\xF0\x9F\x87\xA7"; // 🇺🇸🇬🇧
    var iter = GraphemeIterator.init(text) catch unreachable;
    var codepoint_buffer: [4]u21 = undefined;
    var count: usize = 0;

    while (iter.next(&codepoint_buffer)) |result| {
        // Each flag should be width 2, 2 codepoints
        try std.testing.expectEqual(@as(u16, 2), result.width);
        try std.testing.expectEqual(@as(usize, 2), result.grapheme.len);
        count += 1;
    }
    // Should be exactly 2 flags
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "GraphemeIterator odd regional indicators" {
    // 3 regional indicators: first two form a flag, third is standalone
    // 🇺🇸 + 🇦 (lone A) - but actually RI + RI + RI should be: pair + single
    const text = "\xF0\x9F\x87\xBA\xF0\x9F\x87\xB8\xF0\x9F\x87\xA6"; // US flag + lone RI
    var iter = GraphemeIterator.init(text) catch unreachable;
    var codepoint_buffer: [4]u21 = undefined;

    // First: US flag (2 RIs)
    const first = (iter.next(&codepoint_buffer)).?;
    try std.testing.expectEqual(@as(usize, 2), first.grapheme.len);

    // Second: lone regional indicator
    const second = (iter.next(&codepoint_buffer)).?;
    try std.testing.expectEqual(@as(usize, 1), second.grapheme.len);
}

test "GraphemeIterator combining mark edge cases" {
    const test_cases = [_]TestCase{
        // Multiple combining marks (heavily accented e)
        // e + acute + grave + circumflex + tilde
        .{
            .input = "e\xCC\x81\xCC\x80\xCC\x82\xCC\x83",
            .expected_byte_len = 9,
            .expected_cell_width = 1,
            .expected_codepoint_count = 5,
        },
        // Combining mark on wide character (Chinese + combining)
        // 中 + combining acute
        .{
            .input = "\xE4\xB8\xAD\xCC\x81",
            .expected_byte_len = 5,
            .expected_cell_width = 2, // Base width preserved
            .expected_codepoint_count = 2,
        },
        // Korean jamo combinations (Hangul)
        // ᄀ (U+1100) + ᅡ (U+1161) = 가-like cluster
        .{
            .input = "\xE1\x84\x80\xE1\x85\xA1",
            .expected_byte_len = 6,
            .expected_cell_width = 2,
            .expected_codepoint_count = 2,
        },
        // Devanagari with virama (for Indic conjuncts)
        // क (ka) + ् (virama) + ष (ssa) = क्ष (kssa)
        .{
            .input = "\xE0\xA4\x95\xE0\xA5\x8D\xE0\xA4\xB7",
            .expected_byte_len = 9,
            .expected_cell_width = 2, // Conjunct is single grapheme
            .expected_codepoint_count = 3,
        },
    };

    try testGraphemeIterator(&test_cases);
}

test "GraphemeIterator ZWNJ extends graphemes" {
    // Zero-width non-joiner (U+200C) is in the Extend class per UAX #29
    // a + ZWNJ combines into one grapheme, then b is separate
    const text = "a\xE2\x80\x8Cb"; // a + ZWNJ + b
    var iter = GraphemeIterator.init(text) catch unreachable;
    var codepoint_buffer: [4]u21 = undefined;

    // First grapheme: 'a' + ZWNJ (2 codepoints)
    const first = (iter.next(&codepoint_buffer)).?;
    try std.testing.expectEqual(@as(usize, 2), first.grapheme.len);
    try std.testing.expectEqual(@as(u21, 'a'), first.grapheme[0]);
    try std.testing.expectEqual(@as(u21, 0x200C), first.grapheme[1]);

    // Second: 'b' alone
    const second = (iter.next(&codepoint_buffer)).?;
    try std.testing.expectEqual(@as(usize, 1), second.grapheme.len);
    try std.testing.expectEqual(@as(u21, 'b'), second.grapheme[0]);
}

test "GraphemeIterator width edge cases" {
    const test_cases = [_]TestCase{
        // Fullwidth Latin A (U+FF21)
        .{
            .input = "\xEF\xBC\xA1",
            .expected_byte_len = 3,
            .expected_cell_width = 2,
            .expected_codepoint_count = 1,
        },
        // Halfwidth Katakana (U+FF66, wo)
        .{
            .input = "\xEF\xBD\xA6",
            .expected_byte_len = 3,
            .expected_cell_width = 1,
            .expected_codepoint_count = 1,
        },
        // CJK Unified Ideograph (U+4E00, one)
        .{
            .input = "\xE4\xB8\x80",
            .expected_byte_len = 3,
            .expected_cell_width = 2,
            .expected_codepoint_count = 1,
        },
        // Japanese Hiragana (U+3042, a)
        .{
            .input = "\xE3\x81\x82",
            .expected_byte_len = 3,
            .expected_cell_width = 2,
            .expected_codepoint_count = 1,
        },
        // Japanese Katakana (U+30A2, a)
        .{
            .input = "\xE3\x82\xA2",
            .expected_byte_len = 3,
            .expected_cell_width = 2,
            .expected_codepoint_count = 1,
        },
        // Hangul syllable (U+AC00, ga)
        .{
            .input = "\xEA\xB0\x80",
            .expected_byte_len = 3,
            .expected_cell_width = 2,
            .expected_codepoint_count = 1,
        },
        // Thai (ambiguous width, typically 1)
        // ก (U+0E01)
        .{
            .input = "\xE0\xB8\x81",
            .expected_byte_len = 3,
            .expected_cell_width = 1,
            .expected_codepoint_count = 1,
        },
        // Arabic (RTL, width 1)
        // ا (U+0627, alef)
        .{
            .input = "\xD8\xA7",
            .expected_byte_len = 2,
            .expected_cell_width = 1,
            .expected_codepoint_count = 1,
        },
    };

    try testGraphemeIterator(&test_cases);
}

test "GraphemeIterator control characters" {
    const test_cases = [_]TestCase{
        // Tab
        .{
            .input = "\t",
            .expected_byte_len = 1,
            .expected_cell_width = 0,
            .expected_codepoint_count = 1,
        },
        // Escape
        .{
            .input = "\x1B",
            .expected_byte_len = 1,
            .expected_cell_width = 0,
            .expected_codepoint_count = 1,
        },
        // DEL (U+007F)
        .{
            .input = "\x7F",
            .expected_byte_len = 1,
            .expected_cell_width = 0,
            .expected_codepoint_count = 1,
        },
        // C1 control (U+0085, NEL)
        .{
            .input = "\xC2\x85",
            .expected_byte_len = 2,
            .expected_cell_width = 0,
            .expected_codepoint_count = 1,
        },
    };

    try testGraphemeIterator(&test_cases);
}

test "GraphemeIterator soft hyphen" {
    // Soft hyphen (U+00AD)
    const text = "\xC2\xAD";
    var iter = GraphemeIterator.init(text) catch unreachable;
    var codepoint_buffer: [4]u21 = undefined;

    const result = (iter.next(&codepoint_buffer)).?;
    try std.testing.expectEqual(@as(usize, 2), result.bytes.len);
    try std.testing.expectEqual(@as(usize, 1), result.grapheme.len);
    try std.testing.expectEqual(@as(u21, 0x00AD), result.grapheme[0]);
    try std.testing.expectEqual(@as(u16, 0), result.width);
}

test "GraphemeIterator emoji presentation defaults" {
    const test_cases = [_]TestCase{
        // © (copyright) - text default
        .{
            .input = "\xC2\xA9",
            .expected_byte_len = 2,
            .expected_cell_width = 1,
            .expected_codepoint_count = 1,
        },
        // ©️ (copyright with VS16) - emoji presentation
        .{
            .input = "\xC2\xA9\xEF\xB8\x8F",
            .expected_byte_len = 5,
            .expected_cell_width = 2,
            .expected_codepoint_count = 2,
        },
        // ® (registered) - text default
        .{
            .input = "\xC2\xAE",
            .expected_byte_len = 2,
            .expected_cell_width = 1,
            .expected_codepoint_count = 1,
        },
        // ™ (trademark) - text default
        .{
            .input = "\xE2\x84\xA2",
            .expected_byte_len = 3,
            .expected_cell_width = 1,
            .expected_codepoint_count = 1,
        },
        // ⚠ (warning) - text default
        .{
            .input = "\xE2\x9A\xA0",
            .expected_byte_len = 3,
            .expected_cell_width = 1,
            .expected_codepoint_count = 1,
        },
        // ⚠️ (warning with VS16) - emoji presentation
        .{
            .input = "\xE2\x9A\xA0\xEF\xB8\x8F",
            .expected_byte_len = 6,
            .expected_cell_width = 2,
            .expected_codepoint_count = 2,
        },
        // ✅ (check mark) - emoji default, width 2
        .{
            .input = "\xE2\x9C\x85",
            .expected_byte_len = 3,
            .expected_cell_width = 2,
            .expected_codepoint_count = 1,
        },
        // ✓ (check mark U+2713) - text presentation, width 1
        .{
            .input = "\xE2\x9C\x93",
            .expected_byte_len = 3,
            .expected_cell_width = 1,
            .expected_codepoint_count = 1,
        },
    };

    try testGraphemeIterator(&test_cases);
}

test "GraphemeIterator hair style modifiers" {
    const test_cases = [_]TestCase{
        // 🧑‍🦰 = person + ZWJ + red hair (3 codepoints)
        .{
            .input = "\xF0\x9F\xA7\x91\xE2\x80\x8D\xF0\x9F\xA6\xB0",
            .expected_byte_len = 11,
            .expected_cell_width = 2,
            .expected_codepoint_count = 3,
        },
        // 🧑‍🦱 = person + ZWJ + curly hair
        .{
            .input = "\xF0\x9F\xA7\x91\xE2\x80\x8D\xF0\x9F\xA6\xB1",
            .expected_byte_len = 11,
            .expected_cell_width = 2,
            .expected_codepoint_count = 3,
        },
        // 🧑‍🦳 = person + ZWJ + white hair
        .{
            .input = "\xF0\x9F\xA7\x91\xE2\x80\x8D\xF0\x9F\xA6\xB3",
            .expected_byte_len = 11,
            .expected_cell_width = 2,
            .expected_codepoint_count = 3,
        },
        // 🧑‍🦲 = person + ZWJ + bald
        .{
            .input = "\xF0\x9F\xA7\x91\xE2\x80\x8D\xF0\x9F\xA6\xB2",
            .expected_byte_len = 11,
            .expected_cell_width = 2,
            .expected_codepoint_count = 3,
        },
        // 👩🏽‍🦰 = woman + skin tone + ZWJ + red hair (4 codepoints)
        .{
            .input = "\xF0\x9F\x91\xA9\xF0\x9F\x8F\xBD\xE2\x80\x8D\xF0\x9F\xA6\xB0",
            .expected_byte_len = 15,
            .expected_cell_width = 2,
            .expected_codepoint_count = 4,
        },
    };
    try testGraphemeIterator(&test_cases);
}

test "GraphemeIterator profession with skin tone" {
    const test_cases = [_]TestCase{
        // 👨🏽‍⚕️ = man + skin tone + ZWJ + medical symbol + VS16 (5 codepoints)
        .{
            .input = "\xF0\x9F\x91\xA8\xF0\x9F\x8F\xBD\xE2\x80\x8D\xE2\x9A\x95\xEF\xB8\x8F",
            .expected_byte_len = 17,
            .expected_cell_width = 2,
            .expected_codepoint_count = 5,
        },
        // 👩🏻‍🔬 = woman + light skin + ZWJ + microscope (4 codepoints)
        .{
            .input = "\xF0\x9F\x91\xA9\xF0\x9F\x8F\xBB\xE2\x80\x8D\xF0\x9F\x94\xAC",
            .expected_byte_len = 15,
            .expected_cell_width = 2,
            .expected_codepoint_count = 4,
        },
        // 👨🏿‍🚀 = man + dark skin + ZWJ + rocket (4 codepoints)
        .{
            .input = "\xF0\x9F\x91\xA8\xF0\x9F\x8F\xBF\xE2\x80\x8D\xF0\x9F\x9A\x80",
            .expected_byte_len = 15,
            .expected_cell_width = 2,
            .expected_codepoint_count = 4,
        },
    };
    try testGraphemeIterator(&test_cases);
}

test "GraphemeIterator skin tone on non-modifier-base" {
    // A + 🏻 (light skin tone) should be 2 separate graphemes
    const text = "A\xF0\x9F\x8F\xBB";
    var iter = GraphemeIterator.init(text) catch unreachable;
    var codepoint_buffer: [4]u21 = undefined;

    // First grapheme: 'A'
    const first = (iter.next(&codepoint_buffer)).?;
    try std.testing.expectEqual(@as(usize, 1), first.grapheme.len);
    try std.testing.expectEqual(@as(u21, 'A'), first.grapheme[0]);

    // Second grapheme: skin tone modifier alone (displays as colored square)
    const second = (iter.next(&codepoint_buffer)).?;
    try std.testing.expectEqual(@as(usize, 1), second.grapheme.len);
    try std.testing.expectEqual(@as(u21, 0x1F3FB), second.grapheme[0]);
}

test "GraphemeIterator multi-person mixed skin tones" {
    const test_cases = [_]TestCase{
        // 🧑🏻‍🤝‍🧑🏿 = person light + ZWJ + handshake + ZWJ + person dark
        .{
            .input = "\xF0\x9F\xA7\x91\xF0\x9F\x8F\xBB\xE2\x80\x8D\xF0\x9F\xA4\x9D\xE2\x80\x8D\xF0\x9F\xA7\x91\xF0\x9F\x8F\xBF",
            .expected_byte_len = 26,
            .expected_cell_width = 2,
            .expected_codepoint_count = 7,
        },
    };
    try testGraphemeIterator(&test_cases);
}

test "GraphemeIterator empty string" {
    const result = GraphemeIterator.init("");
    try std.testing.expectError(error.EmptyString, result);
}

test "GraphemeIterator prepend characters" {
    // U+0600 (Arabic Number Sign) is a prepend character
    // prepend + base should form one grapheme
    const text = "\xD8\x80a"; // U+0600 + 'a'
    var iter = GraphemeIterator.init(text) catch unreachable;
    var codepoint_buffer: [4]u21 = undefined;

    const first = (iter.next(&codepoint_buffer)).?;
    // Prepend + base = one grapheme with 2 codepoints
    try std.testing.expectEqual(@as(usize, 2), first.grapheme.len);
}

test "GraphemeIterator Tamil conjunct" {
    // Tamil conjuncts: க்ஷ = க (ka) + ் (virama) + ஷ (ssa)
    // Unlike Devanagari, Tamil may not have InCB properties in all implementations,
    // so the virama+consonant may not form a single grapheme cluster.
    // Test actual behavior: first grapheme is க் (ka + virama)
    const test_cases = [_]TestCase{
        // க் = க (ka) + ் (virama) - first part of conjunct
        .{
            .input = "\xE0\xAE\x95\xE0\xAF\x8D\xE0\xAE\xB7",
            .expected_byte_len = 6, // Only consumes first 2 codepoints
            .expected_cell_width = 1,
            .expected_codepoint_count = 2,
        },
    };
    try testGraphemeIterator(&test_cases);
}
