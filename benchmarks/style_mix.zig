const std = @import("std");
const assert = std.debug.assert;
const rng = @import("rng.zig");
const renderer = @import("renderer");

pub const Style = renderer.Style;

pub const StyleMix = enum {
    flat,
    themed,
    churn,
};

const themed_palette = [_]Style{
    .{ .fg = .{ .ansi = .bright_cyan }, .bg = .{ .ansi = .black }, .underline = .none, .flags = .{ .bold = true } },
    .{ .fg = .{ .ansi = .bright_yellow }, .bg = .{ .ansi = .bright_black }, .underline = .none, .flags = .{ .dim = true } },
    .{ .fg = .{ .ansi = .bright_green }, .bg = .{ .ansi = .black }, .underline = .{ .ansi = .bright_magenta }, .flags = .{ .underline = .single } },
    .{ .fg = .{ .ansi = .bright_magenta }, .bg = .{ .ansi = .black }, .underline = .none, .flags = .{ .italic = true } },
    .{ .fg = .{ .ansi = .bright_blue }, .bg = .{ .ansi = .bright_black }, .underline = .none, .flags = .{ .dim = true, .italic = true } },
    .{ .fg = .{ .ansi = .white }, .bg = .{ .ansi = .blue }, .underline = .{ .ansi = .bright_cyan }, .flags = .{ .bold = true, .underline = .single } },
    .{ .fg = .{ .ansi = .black }, .bg = .{ .ansi = .bright_yellow }, .underline = .none, .flags = .{ .bold = true } },
    .{ .fg = .{ .rgb = .{ .r = 236, .g = 94, .b = 142 } }, .bg = .{ .rgb = .{ .r = 24, .g = 24, .b = 32 } }, .underline = .{ .rgb = .{ .r = 255, .g = 128, .b = 64 } }, .flags = .{ .underline = .curly } },
    .{ .fg = .{ .rgb = .{ .r = 80, .g = 200, .b = 180 } }, .bg = .{ .rgb = .{ .r = 10, .g = 36, .b = 44 } }, .underline = .{ .ansi = .bright_yellow }, .flags = .{ .underline = .dotted } },
    .{ .fg = .{ .ansi = .bright_white }, .bg = .{ .rgb = .{ .r = 36, .g = 16, .b = 24 } }, .underline = .none, .flags = .{ .bold = true, .strikethrough = true } },
    .{ .fg = .{ .ansi = .bright_red }, .bg = .{ .ansi = .bright_black }, .underline = .{ .ansi = .bright_red }, .flags = .{ .underline = .double } },
};

const churn_core_palette = [_]Style{
    Style.default,
    .{ .fg = .{ .ansi = .bright_cyan }, .bg = .{ .ansi = .black }, .underline = .none, .flags = .{ .dim = true } },
    .{ .fg = .{ .ansi = .bright_yellow }, .bg = .{ .ansi = .blue }, .underline = .none, .flags = .{ .italic = true, .bold = true } },
    .{ .fg = .{ .ansi = .bright_green }, .bg = .{ .ansi = .bright_black }, .underline = .{ .ansi = .bright_green }, .flags = .{ .underline = .single } },
    .{ .fg = .{ .ansi = .bright_magenta }, .bg = .{ .ansi = .bright_yellow }, .underline = .none, .flags = .{ .reverse = true } },
    .{ .fg = .{ .ansi = .bright_blue }, .bg = .{ .ansi = .bright_red }, .underline = .none, .flags = .{ .strikethrough = true } },
    .{ .fg = .{ .ansi = .bright_red }, .bg = .{ .ansi = .bright_black }, .underline = .none, .flags = .{ .blink = true } },
    .{ .fg = .{ .ansi = .cyan }, .bg = .{ .ansi = .bright_black }, .underline = .none, .flags = .{ .reverse = true, .bold = true } },
    .{ .fg = .{ .ansi = .yellow }, .bg = .{ .ansi = .blue }, .underline = .none, .flags = .{ .bold = true, .dim = true } },
    .{ .fg = .{ .ansi = .green }, .bg = .{ .ansi = .bright_black }, .underline = .{ .ansi = .bright_magenta }, .flags = .{ .underline = .double } },
    .{ .fg = .{ .ansi = .magenta }, .bg = .{ .ansi = .bright_yellow }, .underline = .{ .rgb = .{ .r = 200, .g = 120, .b = 255 } }, .flags = .{ .underline = .dotted } },
    .{ .fg = .{ .rgb = .{ .r = 200, .g = 80, .b = 80 } }, .bg = .{ .rgb = .{ .r = 18, .g = 10, .b = 14 } }, .underline = .{ .rgb = .{ .r = 80, .g = 200, .b = 120 } }, .flags = .{ .underline = .dotted } },
    .{ .fg = .{ .rgb = .{ .r = 140, .g = 180, .b = 255 } }, .bg = .{ .rgb = .{ .r = 28, .g = 20, .b = 44 } }, .underline = .{ .rgb = .{ .r = 255, .g = 200, .b = 120 } }, .flags = .{ .underline = .dashed, .italic = true } },
    .{ .fg = .{ .ansi = .bright_white }, .bg = .{ .ansi = .black }, .underline = .none, .flags = .{ .invisible = true } },
    .{ .fg = .{ .rgb = .{ .r = 240, .g = 200, .b = 120 } }, .bg = .{ .ansi = .bright_blue }, .underline = .{ .ansi = .bright_white }, .flags = .{ .reverse = true, .bold = true, .underline = .single } },
};

const sweep_palette = [_]Style{
    .{ .fg = .{ .ansi = .red }, .bg = .{ .ansi = .black }, .underline = .none, .flags = .{} },
    .{ .fg = .{ .ansi = .yellow }, .bg = .{ .ansi = .black }, .underline = .none, .flags = .{} },
    .{ .fg = .{ .ansi = .green }, .bg = .{ .ansi = .black }, .underline = .none, .flags = .{} },
    .{ .fg = .{ .ansi = .cyan }, .bg = .{ .ansi = .black }, .underline = .none, .flags = .{} },
    .{ .fg = .{ .ansi = .blue }, .bg = .{ .ansi = .black }, .underline = .none, .flags = .{} },
    .{ .fg = .{ .ansi = .magenta }, .bg = .{ .ansi = .black }, .underline = .none, .flags = .{} },
    .{ .fg = .{ .ansi = .bright_red }, .bg = .{ .ansi = .bright_black }, .underline = .{ .ansi = .bright_red }, .flags = .{ .underline = .single } },
    .{ .fg = .{ .ansi = .bright_yellow }, .bg = .{ .ansi = .bright_black }, .underline = .{ .ansi = .bright_yellow }, .flags = .{ .underline = .double } },
    .{ .fg = .{ .ansi = .bright_green }, .bg = .{ .ansi = .bright_black }, .underline = .{ .rgb = .{ .r = 100, .g = 220, .b = 120 } }, .flags = .{ .underline = .dotted } },
    .{ .fg = .{ .ansi = .bright_cyan }, .bg = .{ .ansi = .bright_black }, .underline = .{ .rgb = .{ .r = 80, .g = 200, .b = 200 } }, .flags = .{ .underline = .dashed } },
    .{ .fg = .{ .rgb = .{ .r = 255, .g = 180, .b = 60 } }, .bg = .{ .rgb = .{ .r = 28, .g = 18, .b = 10 } }, .underline = .{ .rgb = .{ .r = 120, .g = 200, .b = 255 } }, .flags = .{ .underline = .dotted, .italic = true } },
    .{ .fg = .{ .rgb = .{ .r = 160, .g = 220, .b = 255 } }, .bg = .{ .rgb = .{ .r = 12, .g = 24, .b = 40 } }, .underline = .none, .flags = .{ .bold = true, .italic = true } },
    .{ .fg = .{ .rgb = .{ .r = 220, .g = 120, .b = 200 } }, .bg = .{ .rgb = .{ .r = 24, .g = 12, .b = 32 } }, .underline = .{ .ansi = .bright_magenta }, .flags = .{ .underline = .curly } },
    .{ .fg = .{ .rgb = .{ .r = 180, .g = 240, .b = 120 } }, .bg = .{ .rgb = .{ .r = 12, .g = 30, .b = 16 } }, .underline = .{ .ansi = .bright_green }, .flags = .{ .underline = .single } },
};

const inverted_palette = [_]Style{
    .{ .fg = .{ .ansi = .white }, .bg = .{ .ansi = .black }, .underline = .none, .flags = .{} },
    .{ .fg = .{ .ansi = .bright_white }, .bg = .{ .ansi = .blue }, .underline = .{ .ansi = .bright_cyan }, .flags = .{ .underline = .single } },
    .{ .fg = .{ .ansi = .bright_cyan }, .bg = .{ .rgb = .{ .r = 10, .g = 30, .b = 50 } }, .underline = .none, .flags = .{ .italic = true } },
    .{ .fg = .{ .rgb = .{ .r = 255, .g = 180, .b = 60 } }, .bg = .{ .rgb = .{ .r = 30, .g = 20, .b = 10 } }, .underline = .{ .rgb = .{ .r = 120, .g = 200, .b = 255 } }, .flags = .{ .underline = .double } },
    .{ .fg = .{ .ansi = .bright_yellow }, .bg = .{ .ansi = .bright_black }, .underline = .none, .flags = .{ .bold = true, .strikethrough = true } },
    .{ .fg = .{ .rgb = .{ .r = 140, .g = 200, .b = 120 } }, .bg = .{ .rgb = .{ .r = 12, .g = 28, .b = 16 } }, .underline = .{ .ansi = .bright_green }, .flags = .{ .underline = .dotted } },
    .{ .fg = .{ .ansi = .white }, .bg = .{ .ansi = .black }, .underline = .none, .flags = .{ .reverse = true, .bold = true } },
    .{ .fg = .{ .ansi = .bright_white }, .bg = .{ .ansi = .blue }, .underline = .{ .ansi = .bright_cyan }, .flags = .{ .reverse = true, .bold = true, .underline = .single } },
    .{ .fg = .{ .ansi = .bright_cyan }, .bg = .{ .rgb = .{ .r = 10, .g = 30, .b = 50 } }, .underline = .none, .flags = .{ .reverse = true, .bold = true, .italic = true } },
    .{ .fg = .{ .rgb = .{ .r = 255, .g = 180, .b = 60 } }, .bg = .{ .rgb = .{ .r = 30, .g = 20, .b = 10 } }, .underline = .{ .rgb = .{ .r = 120, .g = 200, .b = 255 } }, .flags = .{ .reverse = true, .bold = true, .underline = .double } },
    .{ .fg = .{ .ansi = .bright_yellow }, .bg = .{ .ansi = .bright_black }, .underline = .none, .flags = .{ .reverse = true, .bold = true, .strikethrough = true } },
    .{ .fg = .{ .rgb = .{ .r = 140, .g = 200, .b = 120 } }, .bg = .{ .rgb = .{ .r = 12, .g = 28, .b = 16 } }, .underline = .{ .ansi = .bright_green }, .flags = .{ .reverse = true, .bold = true, .underline = .dotted } },
};

const churn_palette = churn_core_palette ++ sweep_palette ++ inverted_palette;
const churn_sweep_start: usize = churn_core_palette.len;
const churn_inverted_start: usize = churn_sweep_start + sweep_palette.len;
const churn_sweep_len: usize = sweep_palette.len;
const churn_inverted_len: usize = inverted_palette.len;

pub fn paletteFor(mix: StyleMix) []const Style {
    return switch (mix) {
        .flat => &.{Style.default},
        .themed => &themed_palette,
        .churn => &churn_palette,
    };
}

pub fn paletteLen(mix: StyleMix) usize {
    return paletteFor(mix).len;
}

pub fn fillStyleIds(style_sheet: *Style.Sheet, allocator: std.mem.Allocator, mix: StyleMix, out: []Style.Id) []Style.Id {
    const palette = paletteFor(mix);
    assert(out.len >= palette.len);
    for (palette, 0..) |style, idx| {
        out[idx] = style_sheet.put(allocator, style);
    }
    return out[0..palette.len];
}

pub const StyleSequence = struct {
    mix: StyleMix,
    random: std.Random,
    palette_len: usize,
    current_index: usize,
    run_remaining: u16,
    sweep_offset: u16,
    burst_remaining: u16,
    burst_index: usize,
    use_sweep: bool,

    pub fn init(mix: StyleMix, random: std.Random, palette_len: usize) StyleSequence {
        assert(palette_len > 0);
        const offset = if (palette_len > 1)
            rng.rangeU16(random, 0, @as(u16, @intCast(palette_len)))
        else
            0;
        return .{
            .mix = mix,
            .random = random,
            .palette_len = palette_len,
            .current_index = 0,
            .run_remaining = 0,
            .sweep_offset = offset,
            .burst_remaining = 0,
            .burst_index = 0,
            .use_sweep = false,
        };
    }

    pub fn nextIndex(self: *StyleSequence, x: u16, y: u16) usize {
        return switch (self.mix) {
            .flat => 0,
            .themed => self.nextRunIndex(self.palette_len, 12, 48),
            .churn => self.nextChurnIndex(x, y),
        };
    }

    fn nextRunIndex(self: *StyleSequence, palette_len: usize, min_run: u16, max_exclusive: u16) usize {
        if (self.run_remaining == 0) {
            self.current_index = self.random.intRangeLessThan(usize, 0, palette_len);
            self.run_remaining = rng.rangeU16(self.random, min_run, max_exclusive);
        }
        self.run_remaining -= 1;
        return self.current_index;
    }

    fn nextChurnIndex(self: *StyleSequence, x: u16, y: u16) usize {
        if (self.burst_remaining > 0) {
            self.burst_remaining -= 1;
            return self.burst_index;
        }

        if (churn_inverted_len > 0 and self.random.intRangeLessThan(u16, 0, 100) < 7) {
            self.burst_remaining = rng.rangeU16(self.random, 2, 7);
            const offset = self.random.intRangeLessThan(usize, 0, churn_inverted_len);
            self.burst_index = churn_inverted_start + offset;
            return self.burst_index;
        }

        if (self.run_remaining == 0) {
            const roll = self.random.intRangeLessThan(u16, 0, 100);
            if (roll < 55) {
                self.current_index = self.random.intRangeLessThan(usize, 0, self.palette_len);
                self.run_remaining = rng.rangeU16(self.random, 1, 4);
                self.use_sweep = false;
            } else if (roll < 85) {
                self.current_index = self.random.intRangeLessThan(usize, 0, self.palette_len);
                self.run_remaining = rng.rangeU16(self.random, 4, 12);
                self.use_sweep = false;
            } else {
                self.run_remaining = rng.rangeU16(self.random, 8, 32);
                self.use_sweep = true;
                self.sweep_offset +%= 1;
            }
        }

        self.run_remaining -= 1;
        if (self.use_sweep and churn_sweep_len > 0) {
            const sum = @as(usize, x) + @as(usize, y) + @as(usize, self.sweep_offset);
            return churn_sweep_start + (sum % churn_sweep_len);
        }

        return self.current_index;
    }
};
