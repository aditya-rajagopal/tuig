const std = @import("std");
const rng = @import("rng.zig");

pub const Glyph = struct {
    bytes: []const u8,
    width: u2,
};

pub const TextMix = enum {
    common,
    grapheme_stress,
};

const ascii_chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
const ascii_symbols = "!@#$%^&*()-_=+[]{};:,.?/";

const cjk_glyphs = [_]Glyph{
    .{ .bytes = "中", .width = 2 },
    .{ .bytes = "文", .width = 2 },
    .{ .bytes = "語", .width = 2 },
    .{ .bytes = "漢", .width = 2 },
    .{ .bytes = "字", .width = 2 },
    .{ .bytes = "界", .width = 2 },
    .{ .bytes = "東", .width = 2 },
    .{ .bytes = "西", .width = 2 },
    .{ .bytes = "南", .width = 2 },
    .{ .bytes = "北", .width = 2 },
    .{ .bytes = "新", .width = 2 },
    .{ .bytes = "化", .width = 2 },
};

const emoji_glyphs = [_]Glyph{
    .{ .bytes = "😀", .width = 2 },
    .{ .bytes = "🚀", .width = 2 },
    .{ .bytes = "✨", .width = 2 },
    .{ .bytes = "🔥", .width = 2 },
    .{ .bytes = "✅", .width = 2 },
    .{ .bytes = "⚠️", .width = 2 },
    .{ .bytes = "📦", .width = 2 },
    .{ .bytes = "🎯", .width = 2 },
};

const emoji_zwj_glyphs = [_]Glyph{
    .{ .bytes = "👩‍💻", .width = 2 },
    .{ .bytes = "👨‍👩‍👧‍👦", .width = 2 },
    .{ .bytes = "🧑‍🚀", .width = 2 },
    .{ .bytes = "👩‍🎨", .width = 2 },
    .{ .bytes = "🏳️‍🌈", .width = 2 },
};

const combining_glyphs = [_]Glyph{
    .{ .bytes = "e\xCC\x81", .width = 1 },
    .{ .bytes = "a\xCC\x81\xCC\x80", .width = 1 },
    .{ .bytes = "n\xCC\x83", .width = 1 },
    .{ .bytes = "o\xCC\x88", .width = 1 },
    .{ .bytes = "u\xCC\x88", .width = 1 },
};

const box_glyphs = [_]Glyph{
    .{ .bytes = "─", .width = 1 },
    .{ .bytes = "│", .width = 1 },
    .{ .bytes = "┌", .width = 1 },
    .{ .bytes = "┐", .width = 1 },
    .{ .bytes = "└", .width = 1 },
    .{ .bytes = "┘", .width = 1 },
    .{ .bytes = "┼", .width = 1 },
    .{ .bytes = "├", .width = 1 },
    .{ .bytes = "┤", .width = 1 },
    .{ .bytes = "┬", .width = 1 },
    .{ .bytes = "┴", .width = 1 },
};

const block_glyphs = [_]Glyph{
    .{ .bytes = "█", .width = 1 },
    .{ .bytes = "▓", .width = 1 },
    .{ .bytes = "▒", .width = 1 },
    .{ .bytes = "░", .width = 1 },
    .{ .bytes = "▀", .width = 1 },
    .{ .bytes = "▄", .width = 1 },
};

pub fn pickGlyph(random: std.Random, mix: TextMix) Glyph {
    return switch (mix) {
        .common => {
            const idx = weightedIndex(random, &.{ 70, 20, 10 });
            return switch (idx) {
                0 => pickAsciiCommon(random),
                1 => pickOtherUnicode(random),
                else => pickWide(random),
            };
        },
        .grapheme_stress => {
            const idx = weightedIndex(random, &.{ 50, 20, 20, 10 });
            return switch (idx) {
                0 => pickAsciiCommon(random),
                1 => pickOtherUnicode(random),
                2 => pickEmojiZwj(random),
                else => pickCombining(random),
            };
        },
    };
}

pub fn pickGlyphFitting(random: std.Random, mix: TextMix, max_width: u2) Glyph {
    const glyph = pickGlyph(random, mix);
    if (glyph.width <= max_width) return glyph;
    return pickAscii(random);
}

pub fn pickAscii(random: std.Random) Glyph {
    const idx = rng.index(random, ascii_chars.len);
    return .{ .bytes = ascii_chars[idx .. idx + 1], .width = 1 };
}

fn pickAsciiCommon(random: std.Random) Glyph {
    const idx = weightedIndex(random, &.{ 85, 15 });
    return if (idx == 0) pickAscii(random) else pickAsciiSymbol(random);
}

fn pickAsciiSymbol(random: std.Random) Glyph {
    const idx = rng.index(random, ascii_symbols.len);
    return .{ .bytes = ascii_symbols[idx .. idx + 1], .width = 1 };
}

fn pickCjk(random: std.Random) Glyph {
    return pickFromList(random, &cjk_glyphs);
}

fn pickEmoji(random: std.Random) Glyph {
    return pickFromList(random, &emoji_glyphs);
}

fn pickEmojiZwj(random: std.Random) Glyph {
    return pickFromList(random, &emoji_zwj_glyphs);
}

fn pickCombining(random: std.Random) Glyph {
    return pickFromList(random, &combining_glyphs);
}

fn pickOtherUnicode(random: std.Random) Glyph {
    const idx = weightedIndex(random, &.{ 40, 30, 30 });
    return switch (idx) {
        0 => pickBoxBlock(random),
        1 => pickCjk(random),
        else => pickEmoji(random),
    };
}

fn pickWide(random: std.Random) Glyph {
    const idx = weightedIndex(random, &.{ 60, 40 });
    return if (idx == 0) pickCjk(random) else pickEmoji(random);
}

fn pickBoxBlock(random: std.Random) Glyph {
    const total = box_glyphs.len + block_glyphs.len;
    const idx = rng.index(random, total);
    if (idx < box_glyphs.len) return box_glyphs[idx];
    return block_glyphs[idx - box_glyphs.len];
}

fn pickFromList(random: std.Random, list: []const Glyph) Glyph {
    return list[rng.index(random, list.len)];
}

fn weightedIndex(random: std.Random, weights: []const u32) usize {
    const table = rng.WeightedTable.init(weights);
    return table.pick(random);
}
