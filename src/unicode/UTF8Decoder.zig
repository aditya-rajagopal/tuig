//! UTF-8 decoding using DFA. This is great for streaming decoding.
//! If you have a slice in memory, it seems std.unicode.Utf8View is a better choice. especially if you dont want to validate
//! the input
//!
//! This is based on:
//! http://bjoern.hoehrmann.de/utf-8/decoder/dfa/ (MIT license)
//! https://github.com/ghostty-org/ghostty/blob/2fd3efd6cdf0629f57572af58dff0ae9115ce919/src/terminal/UTF8Decoder.zig (MIT license)

pub const UTF8Decoder = @This();

pub const State = enum(u8) {
    accept = 0,
    reject = 12,
    _,
};

const character_classes = [_]u4{
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 0x10
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 0x20
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 0x30
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 0x40
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 0x50
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 0x60
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 0x70
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 0x80
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, // 0x90
    9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, // 0xA0
    7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, // 0xB0
    7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, // 0xC0
    8, 8, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, // 0xD0
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, // 0xE0
    10, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 4, 3, 3, // 0xF0
    11, 6, 6, 6, 5, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, // 0x100
};

const transitions = [_]u8{
    0,  12, 24, 36, 60, 96, 84, 12, 12, 12, 48, 72,
    12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12,
    12, 0,  12, 12, 12, 12, 12, 0,  12, 0,  12, 12,
    12, 24, 12, 12, 12, 12, 12, 24, 12, 24, 12, 12,
    12, 12, 12, 12, 12, 12, 12, 24, 12, 12, 12, 12,
    12, 24, 12, 12, 12, 12, 12, 12, 12, 24, 12, 12,
    12, 12, 12, 12, 12, 12, 12, 36, 12, 36, 12, 12,
    12, 36, 12, 12, 12, 12, 12, 36, 12, 36, 12, 12,
    12, 36, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12,
};

codepoint: u21,
state: State,

pub const start: UTF8Decoder = .{ .codepoint = 0, .state = .accept };

pub inline fn decode(self: *UTF8Decoder, byte: u8) struct { ?u21, bool } {
    const class = character_classes[byte];

    const initial_state = self.state;

    self.codepoint = if (initial_state != .accept)
        @as(u21, @intCast(byte & 0x3F)) | (self.codepoint << 6)
    else
        byte & (@as(u21, 0xFF) >> class);

    self.state = @enumFromInt(transitions[@intFromEnum(initial_state) + class]);

    switch (self.state) {
        .accept => {
            defer self.codepoint = 0;
            return .{ self.codepoint, true }; // We are done decoding.
        },
        .reject => {
            // NOTE(adi): We encountered an error and we return `REPLACEMENT CHARACTER`(0xFFFD)
            // if this is part of a new sequence of bytes we consume it and return the replacement (initial_state == .accept).
            // If we are in the middle of a sequence we return the replacement and restart the decode from this codepoint treating it as the first byte
            // http://bjoern.hoehrmann.de/utf-8/decoder/dfa/ (Error Recovery section)
            self.codepoint = 0;
            self.state = .accept;
            return .{ 0xFFFD, initial_state == .accept };
        },
        else => return .{ null, true }, // We are still consuming bytes and are not yet done.
    }
}

const std = @import("std");

test "UTF8Decoder ASCII" {
    var d: UTF8Decoder = .start;
    const test_case = "All your codebase are belong to us";
    var decoded_string: [test_case.len]u8 = undefined;
    for (test_case, 0..) |byte, i| {
        const codepoint, const consumed = d.decode(byte);
        try std.testing.expect(consumed);
        try std.testing.expect(codepoint != null);
        decoded_string[i] = @intCast(codepoint.?);
    }
    try std.testing.expectEqualStrings(test_case, &decoded_string);
}

test "UTF8Decoder Single Codepoint" {
    const TestCase = struct {
        input: []const u8,
        expected: u21,

        fn decodeCodepoint(s: []const u8) !u21 {
            var d: UTF8Decoder = .start;

            for (s) |byte| {
                const codepoint, const consumed = d.decode(byte);
                try std.testing.expect(consumed);
                if (codepoint) |cp| return cp;
            }
            unreachable;
        }
    };
    const test_cases = [_]TestCase{
        .{ .input = "é", .expected = 0x00E9 }, // é (U+00E9) = 0xC3 0xA9
        .{ .input = "ñ", .expected = 0x00F1 }, // ñ (U+00F1) = 0xC3 0xB1
        .{ .input = "中", .expected = 0x4E2D }, // 中 (U+4E2D) = 0xE4 0xB8 0xAD
        .{ .input = "€", .expected = 0x20AC }, // € (U+20AC) = 0xE2 0x82 0xAC
        .{ .input = "😀", .expected = 0x1F600 }, // 😀 (U+1F600) = 0xF0 0x9F 0x98 0x80
        .{ .input = "𐍈", .expected = 0x10348 }, // 𐍈 (U+10348) = 0xF0 0x90 0x8D 0x88
    };

    for (test_cases) |test_case| {
        try std.testing.expectEqual(test_case.expected, try TestCase.decodeCodepoint(test_case.input));
    }
}

test "UTF8Decoder mixed string" {
    var d: UTF8Decoder = .start;

    // "Héllo 世界!" - mix of ASCII, 2-byte, and 3-byte sequences
    const input = "H\xC3\xA9llo \xE4\xB8\x96\xE7\x95\x8C!";
    const expected = [_]u21{ 'H', 0x00E9, 'l', 'l', 'o', ' ', 0x4E16, 0x754C, '!' };

    var result: [expected.len]u21 = undefined;
    var result_idx: usize = 0;

    for (input) |byte| {
        const codepoint, const consumed = d.decode(byte);
        try std.testing.expect(consumed);
        if (codepoint) |cp| {
            result[result_idx] = cp;
            result_idx += 1;
        }
    }

    try std.testing.expectEqual(expected.len, result_idx);
    try std.testing.expectEqualSlices(u21, &expected, &result);
}

test "UTF8Decoder invalid leading byte" {
    var d: UTF8Decoder = .start;

    // Starting with a continuation byte (0x80-0xBF) is invalid
    const codepoint, const consumed = d.decode(0x80);
    try std.testing.expect(consumed);
    try std.testing.expectEqual(@as(u21, 0xFFFD), codepoint.?); // replacement character

    // Next valid byte should be decoded
    const cp2, const c2 = d.decode('A');
    try std.testing.expect(c2);
    try std.testing.expectEqual(@as(u21, 'A'), cp2.?);
}

test "UTF8Decoder truncated sequence" {
    var d: UTF8Decoder = .start;
    const input = "\xC3A"; // Start a 2-byte sequence but follow with ASCII
    const expected = [2]u21{ 0xFFFD, 'A' };
    var output: [2]u21 = undefined;

    var index_output: usize = 0;
    var index_input: usize = 0;

    while (index_input < input.len) {
        const codepoint, const consumed = d.decode(input[index_input]);
        if (consumed) index_input += 1;
        if (codepoint) |cp| {
            output[index_output] = cp;
            index_output += 1;
        }
    }
    try std.testing.expectEqual(2, index_output);
    try std.testing.expectEqualSlices(u21, &expected, &output);
}

test "UTF8Decoder invalid continuation" {
    var d: UTF8Decoder = .start;
    const input = "\xE4\xB8\xFF"; // Start a 3-byte sequence but last byte is invalid
    const expected = [2]u21{ 0xFFFD, 0xFFFD };
    var output: [3]u21 = undefined;

    var index_output: usize = 0;
    var index_input: usize = 0;

    while (index_input < input.len) {
        const codepoint, const consumed = d.decode(input[index_input]);
        if (consumed) index_input += 1;
        if (codepoint) |cp| {
            output[index_output] = cp;
            index_output += 1;
        }
    }
    try std.testing.expectEqual(2, index_output);
    try std.testing.expectEqualSlices(u21, &expected, output[0..index_output]);
}
