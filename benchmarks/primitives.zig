const std = @import("std");
const assert = std.debug.assert;
const renderer = @import("renderer");
const text_mix = @import("text_mix.zig");
const style_mix = @import("style_mix.zig");

pub const PrimitiveContext = struct {
    random: std.Random,
    text_mix: text_mix.TextMix,
    style_sequence: *style_mix.StyleSequence,
    style_ids: []const renderer.Style.Id,
    codepoint_buffer: []u21,

    pub fn styleFor(self: *PrimitiveContext, x: u16, y: u16) renderer.Style.Id {
        const idx = self.style_sequence.nextIndex(x, y);
        if (idx < self.style_ids.len) return self.style_ids[idx];
        return .default;
    }
};

pub fn textBlock(scissor: renderer.Scissor, ctx: *PrimitiveContext) renderer.Scissor.PrintError!void {
    if (scissor.width_global == 0 or scissor.height_global == 0) return;

    var x: u16 = 0;
    var y: u16 = 0;
    while (y < scissor.height_global) {
        const word_len = ctx.random.intRangeLessThan(u16, 3, 10);
        var remaining_chars: u16 = word_len;
        while (remaining_chars > 0) {
            if (x >= scissor.width_global) {
                x = 0;
                y += 1;
                if (y >= scissor.height_global) return;
            }

            const remaining_cols = scissor.width_global - x;
            const max_width: u2 = if (remaining_cols >= 2) 2 else 1;
            const glyph = text_mix.pickGlyphFitting(ctx.random, ctx.text_mix, max_width);
            const style_id = ctx.styleFor(x, y);
            try putGlyph(scissor, ctx.codepoint_buffer, glyph, x, y, style_id);
            x += @as(u16, glyph.width);
            remaining_chars -= 1;
        }

        if (x < scissor.width_global) {
            const style_id = ctx.styleFor(x, y);
            try putGlyph(scissor, ctx.codepoint_buffer, .{ .bytes = " ", .width = 1 }, x, y, style_id);
            x += 1;
        } else {
            x = 0;
            y += 1;
        }
    }
}

pub fn table(scissor: renderer.Scissor, ctx: *PrimitiveContext, columns: u8, rows: u8) renderer.Scissor.PrintError!void {
    if (scissor.width_global < 3 or scissor.height_global < 2) return;

    const col_count: usize = if (columns == 0) 1 else columns;
    const separators: u16 = @intCast(col_count - 1);
    if (scissor.width_global <= separators) return;
    const col_width: u16 = (scissor.width_global - separators) / @as(u16, @intCast(col_count));
    if (col_width == 0) return;

    try drawTableRow(scissor, ctx, 0, col_count, col_width, true);
    if (scissor.height_global > 1) {
        drawHorizontalLine(scissor, ctx, 1, col_count, col_width);
    }

    var row_index: u16 = 0;
    const max_rows: u16 = @min(@as(u16, @intCast(rows)), scissor.height_global - 2);
    while (row_index < max_rows) : (row_index += 1) {
        const y = row_index + 2;
        try drawTableRow(scissor, ctx, y, col_count, col_width, false);
    }
}

pub fn list(scissor: renderer.Scissor, ctx: *PrimitiveContext, items: u16) renderer.Scissor.PrintError!void {
    if (scissor.width_global == 0 or scissor.height_global == 0) return;

    const bullet = text_mix.Glyph{ .bytes = "•", .width = 1 };
    const status_glyphs = [_]text_mix.Glyph{
        .{ .bytes = "✅", .width = 2 },
        .{ .bytes = "⚠️", .width = 2 },
        .{ .bytes = "❌", .width = 2 },
        .{ .bytes = "⏳", .width = 2 },
    };

    var row: u16 = 0;
    const max_rows = @min(items, scissor.height_global);
    while (row < max_rows) : (row += 1) {
        var x: u16 = 0;
        const style_id = ctx.styleFor(x, row);
        try putGlyph(scissor, ctx.codepoint_buffer, bullet, x, row, style_id);
        x += 1;
        if (x >= scissor.width_global) continue;

        const status = status_glyphs[ctx.random.intRangeLessThan(usize, 0, status_glyphs.len)];
        if (x + @as(u16, status.width) > scissor.width_global) continue;
        try putGlyph(scissor, ctx.codepoint_buffer, status, x, row, ctx.styleFor(x, row));
        x += @as(u16, status.width);
        if (x < scissor.width_global) {
            try putGlyph(scissor, ctx.codepoint_buffer, .{ .bytes = " ", .width = 1 }, x, row, ctx.styleFor(x, row));
            x += 1;
        }

        try fillLineWithText(scissor, ctx, x, row, scissor.width_global - x);
    }
}

pub fn panel(scissor: renderer.Scissor, ctx: *PrimitiveContext, title: []const u8) renderer.Scissor.PrintError!renderer.Scissor {
    if (scissor.width_global < 2 or scissor.height_global < 2) return scissor;

    const border_style = ctx.styleFor(0, 0);
    drawBox(scissor, border_style);
    if (title.len > 0 and scissor.width_global > 4) {
        const title_style = ctx.styleFor(2, 0);
        _ = try scissor.print(ctx.codepoint_buffer, title, 2, 0, .{ .wrap = false, .tab_width = 4, .style = title_style });
    }
    if (scissor.width_global <= 2 or scissor.height_global <= 2) return scissor;
    return scissor.inner();
}

pub fn sparkline(scissor: renderer.Scissor, ctx: *PrimitiveContext) renderer.Scissor.PrintError!void {
    if (scissor.width_global == 0 or scissor.height_global == 0) return;

    const levels = [_]text_mix.Glyph{
        .{ .bytes = "▁", .width = 1 },
        .{ .bytes = "▂", .width = 1 },
        .{ .bytes = "▃", .width = 1 },
        .{ .bytes = "▄", .width = 1 },
        .{ .bytes = "▅", .width = 1 },
        .{ .bytes = "▆", .width = 1 },
        .{ .bytes = "▇", .width = 1 },
        .{ .bytes = "█", .width = 1 },
    };

    const row: u16 = scissor.height_global - 1;
    var x: u16 = 0;
    while (x < scissor.width_global) : (x += 1) {
        const level = ctx.random.intRangeLessThan(usize, 0, levels.len);
        const style_id = ctx.styleFor(x, row);
        try putGlyph(scissor, ctx.codepoint_buffer, levels[level], x, row, style_id);
    }
}

fn putGlyph(
    scissor: renderer.Scissor,
    codepoint_buffer: []u21,
    glyph: text_mix.Glyph,
    x: u16,
    y: u16,
    style_id: renderer.Style.Id,
) renderer.Scissor.PrintError!void {
    _ = try scissor.print(codepoint_buffer, glyph.bytes, x, y, .{ .wrap = false, .tab_width = 4, .style = style_id });
}

fn drawBox(scissor: renderer.Scissor, style_id: renderer.Style.Id) void {
    assert(scissor.width_global >= 2);
    assert(scissor.height_global >= 2);

    const top_left: u21 = 0x250C;
    const top_right: u21 = 0x2510;
    const bottom_left: u21 = 0x2514;
    const bottom_right: u21 = 0x2518;
    const horizontal: u21 = 0x2500;
    const vertical: u21 = 0x2502;

    setCodepoint(scissor, 0, 0, top_left, style_id);
    setCodepoint(scissor, scissor.width_global - 1, 0, top_right, style_id);
    setCodepoint(scissor, 0, scissor.height_global - 1, bottom_left, style_id);
    setCodepoint(scissor, scissor.width_global - 1, scissor.height_global - 1, bottom_right, style_id);

    if (scissor.width_global > 2) {
        var x: u16 = 1;
        while (x < scissor.width_global - 1) : (x += 1) {
            setCodepoint(scissor, x, 0, horizontal, style_id);
            setCodepoint(scissor, x, scissor.height_global - 1, horizontal, style_id);
        }
    }

    if (scissor.height_global > 2) {
        var y: u16 = 1;
        while (y < scissor.height_global - 1) : (y += 1) {
            setCodepoint(scissor, 0, y, vertical, style_id);
            setCodepoint(scissor, scissor.width_global - 1, y, vertical, style_id);
        }
    }
}

fn setCodepoint(scissor: renderer.Scissor, x: u16, y: u16, codepoint: u21, style_id: renderer.Style.Id) void {
    const cell = renderer.Cell{
        .data = .{ .codepoint = codepoint },
        .tag = .codepoint,
        .width = .narrow,
        .style = style_id,
    };
    scissor.set(x, y, cell);
}

fn drawTableRow(
    scissor: renderer.Scissor,
    ctx: *PrimitiveContext,
    y: u16,
    col_count: usize,
    col_width: u16,
    header: bool,
) renderer.Scissor.PrintError!void {
    var col: usize = 0;
    var x: u16 = 0;
    while (col < col_count) : (col += 1) {
        const cell_width = if (x + col_width <= scissor.width_global)
            col_width
        else
            scissor.width_global - x;
        if (cell_width == 0) break;

        if (header) {
            const title = if (col == 0) "ID" else if (col == 1) "Name" else "Value";
            const style_id = ctx.styleFor(x, y);
            _ = try scissor.print(ctx.codepoint_buffer, title, x, y, .{ .wrap = false, .tab_width = 4, .style = style_id });
        } else {
            try fillLineWithText(scissor, ctx, x, y, cell_width);
        }

        x += cell_width;
        if (col + 1 < col_count and x < scissor.width_global) {
            const style_id = ctx.styleFor(x, y);
            setCodepoint(scissor, x, y, '|', style_id);
            x += 1;
        }
    }
}

fn drawHorizontalLine(scissor: renderer.Scissor, ctx: *PrimitiveContext, y: u16, col_count: usize, col_width: u16) void {
    var x: u16 = 0;
    var col: usize = 0;
    while (col < col_count and x < scissor.width_global) : (col += 1) {
        var i: u16 = 0;
        while (i < col_width and x < scissor.width_global) : (i += 1) {
            const style_id = ctx.styleFor(x, y);
            setCodepoint(scissor, x, y, '-', style_id);
            x += 1;
        }
        if (col + 1 < col_count and x < scissor.width_global) {
            const style_id = ctx.styleFor(x, y);
            setCodepoint(scissor, x, y, '+', style_id);
            x += 1;
        }
    }
}

fn fillLineWithText(
    scissor: renderer.Scissor,
    ctx: *PrimitiveContext,
    start_x: u16,
    y: u16,
    width: u16,
) renderer.Scissor.PrintError!void {
    if (width == 0) return;

    var x = start_x;
    const end_x = start_x + width;
    while (x < end_x) {
        const remaining_cols = end_x - x;
        const max_width: u2 = if (remaining_cols >= 2) 2 else 1;
        const glyph = text_mix.pickGlyphFitting(ctx.random, ctx.text_mix, max_width);
        if (glyph.width > max_width) break;
        const style_id = ctx.styleFor(x, y);
        try putGlyph(scissor, ctx.codepoint_buffer, glyph, x, y, style_id);
        x += @as(u16, glyph.width);
    }
}
