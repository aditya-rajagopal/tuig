const std = @import("std");
const assert = std.debug.assert;
const renderer = @import("renderer");
const rng = @import("rng.zig");
const style_mix = @import("style_mix.zig");
const text_mix = @import("text_mix.zig");

const buffer_alignment = std.mem.Alignment.fromByteUnits(std.heap.page_size_min);

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

    const bullet = text_mix.Glyph{ .bytes = "\u{2022}", .width = 1 };
    const status_glyphs = [_]text_mix.Glyph{
        .{ .bytes = "\u{2705}", .width = 2 },
        .{ .bytes = "\u{26A0}\u{FE0F}", .width = 2 },
        .{ .bytes = "\u{274C}", .width = 2 },
        .{ .bytes = "\u{23F3}", .width = 2 },
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
        .{ .bytes = "\u{2581}", .width = 1 },
        .{ .bytes = "\u{2582}", .width = 1 },
        .{ .bytes = "\u{2583}", .width = 1 },
        .{ .bytes = "\u{2584}", .width = 1 },
        .{ .bytes = "\u{2585}", .width = 1 },
        .{ .bytes = "\u{2586}", .width = 1 },
        .{ .bytes = "\u{2587}", .width = 1 },
        .{ .bytes = "\u{2588}", .width = 1 },
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

pub fn datasetTypical(scissor: renderer.Scissor, ctx: *PrimitiveContext) renderer.Scissor.PrintError!void {
    if (scissor.width_global == 0 or scissor.height_global == 0) return;

    scissor.clear();

    const width = scissor.width_global;
    const height = scissor.height_global;

    const header_height: u16 = if (height >= 4) 3 else if (height >= 2) 2 else 1;

    var footer_height: u16 = 0;
    if (height > header_height) {
        const remaining = height - header_height;
        footer_height = if (remaining >= 3 and height >= 10) 3 else 1;
        if (footer_height > remaining) footer_height = remaining;
    }

    if (header_height > 0) {
        const header_scissor = scissor.initChild(0, 0, width, header_height);
        try renderMenuBar(header_scissor, ctx);
    }

    const content_height = height - header_height - footer_height;
    if (content_height > 0) {
        const content_scissor = scissor.initChild(0, @intCast(header_height), width, content_height);
        try renderTypicalContent(content_scissor, ctx);
    }

    if (footer_height > 0) {
        const footer_scissor = scissor.initChild(0, @intCast(height - footer_height), width, footer_height);
        try renderStatusBar(footer_scissor, ctx);
    }
}

fn renderMenuBar(scissor: renderer.Scissor, ctx: *PrimitiveContext) renderer.Scissor.PrintError!void {
    if (scissor.width_global == 0 or scissor.height_global == 0) return;

    const menu_text = "File  Edit  View  Search  Help";

    if (scissor.height_global >= 2 and scissor.width_global >= 4) {
        const inner = try panel(scissor, ctx, "Menu");
        if (inner.width_global > 2 and inner.height_global > 0) {
            const style_id = ctx.styleFor(1, 0);
            _ = try inner.print(ctx.codepoint_buffer, menu_text, 1, 0, .{
                .wrap = false,
                .tab_width = 4,
                .style = style_id,
            });
        }
        return;
    }

    const style_id = ctx.styleFor(0, 0);
    _ = try scissor.print(ctx.codepoint_buffer, menu_text, 0, 0, .{
        .wrap = false,
        .tab_width = 4,
        .style = style_id,
    });
}

fn renderStatusBar(scissor: renderer.Scissor, ctx: *PrimitiveContext) renderer.Scissor.PrintError!void {
    if (scissor.width_global == 0 or scissor.height_global == 0) return;

    const status_text = "STATUS: OK  |  Workers 12  |  Queue 24  |  Uptime 99.9%";

    if (scissor.height_global >= 2 and scissor.width_global >= 4) {
        const inner = try panel(scissor, ctx, "Status");
        if (inner.width_global > 2 and inner.height_global > 0) {
            const style_id = ctx.styleFor(1, 0);
            _ = try inner.print(ctx.codepoint_buffer, status_text, 1, 0, .{
                .wrap = false,
                .tab_width = 4,
                .style = style_id,
            });
        }
        return;
    }

    const style_id = ctx.styleFor(0, 0);
    _ = try scissor.print(ctx.codepoint_buffer, status_text, 0, 0, .{
        .wrap = false,
        .tab_width = 4,
        .style = style_id,
    });
}

fn renderTypicalContent(scissor: renderer.Scissor, ctx: *PrimitiveContext) renderer.Scissor.PrintError!void {
    const width = scissor.width_global;
    const height = scissor.height_global;
    if (width < 4 or height < 3) return;

    const gap: u16 = if (width >= 100) 2 else 1;

    if (width >= 80 and height >= 8) {
        const width_u32 = @as(u32, width);
        const left_target = (width_u32 * 2) / 10;
        const right_target = (width_u32 * 2) / 10;
        var left_width: u16 = @intCast(left_target);
        if (left_width < 14) left_width = 14;
        var right_width: u16 = @intCast(right_target);
        if (right_width < 14) right_width = 14;
        const total_needed = @as(u32, left_width) + @as(u32, right_width) + @as(u32, gap) * 2 + 20;
        if (total_needed <= width) {
            const center_width: u16 = @intCast(width - left_width - right_width - gap * 2);
            const left_scissor = scissor.initChild(0, 0, left_width, height);
            const center_scissor = scissor.initChild(@intCast(left_width + gap), 0, center_width, height);
            const right_scissor = scissor.initChild(@intCast(left_width + gap + center_width + gap), 0, right_width, height);
            try renderSidebar(left_scissor, ctx);
            try renderMainColumn(center_scissor, ctx);
            try renderMetricsColumn(right_scissor, ctx);
            return;
        }
    }

    if (width >= 50 and height >= 6) {
        const width_u32 = @as(u32, width);
        var left_width: u16 = @intCast((width_u32 * 3) / 10);
        if (left_width < 14) left_width = 14;
        const total_needed = @as(u32, left_width) + @as(u32, gap) + 20;
        if (total_needed <= width) {
            const center_width: u16 = @intCast(width - left_width - gap);
            const left_scissor = scissor.initChild(0, 0, left_width, height);
            const center_scissor = scissor.initChild(@intCast(left_width + gap), 0, center_width, height);
            try renderSidebar(left_scissor, ctx);
            try renderMainColumn(center_scissor, ctx);
            return;
        }
    }

    try renderMainColumn(scissor, ctx);
}

fn renderSidebar(scissor: renderer.Scissor, ctx: *PrimitiveContext) renderer.Scissor.PrintError!void {
    const width = scissor.width_global;
    const height = scissor.height_global;
    if (width < 4 or height < 3) return;

    if (height < 6) {
        const inner = try panel(scissor, ctx, "Navigation");
        if (inner.width_global >= 4 and inner.height_global >= 2) {
            try list(inner, ctx, inner.height_global);
        }
        return;
    }

    const gap_y: u16 = if (height >= 16) 1 else 0;
    const available = height - gap_y;
    const top_height: u16 = @intCast((@as(u32, available) * 3) / 5);
    const bottom_height = available - top_height;

    const top_scissor = scissor.initChild(0, 0, width, top_height);
    const nav_inner = try panel(top_scissor, ctx, "Navigation");
    if (nav_inner.width_global >= 4 and nav_inner.height_global >= 2) {
        const items = @min(nav_inner.height_global, @as(u16, 12));
        try list(nav_inner, ctx, items);
    }

    if (bottom_height > 0) {
        const bottom_scissor = scissor.initChild(0, @intCast(top_height + gap_y), width, bottom_height);
        const queue_inner = try panel(bottom_scissor, ctx, "Queue");
        if (queue_inner.width_global >= 4 and queue_inner.height_global >= 2) {
            try textBlock(queue_inner, ctx);
        }
    }
}

fn renderMainColumn(scissor: renderer.Scissor, ctx: *PrimitiveContext) renderer.Scissor.PrintError!void {
    const width = scissor.width_global;
    const height = scissor.height_global;
    if (width < 4 or height < 3) return;

    if (height < 6) {
        const inner = try panel(scissor, ctx, "Content");
        if (inner.width_global >= 4 and inner.height_global >= 2) {
            try textBlock(inner, ctx);
        }
        return;
    }

    const gap_y: u16 = if (height >= 18) 1 else 0;
    const available = height - gap_y;
    var top_height: u16 = @intCast((@as(u32, available) * 3) / 5);
    if (top_height >= available) top_height = available;
    const bottom_height = available - top_height;

    const top_scissor = scissor.initChild(0, 0, width, top_height);
    const jobs_inner = try panel(top_scissor, ctx, "Jobs");
    if (jobs_inner.width_global >= 6 and jobs_inner.height_global >= 4) {
        try table(jobs_inner, ctx, 4, 8);
    } else if (jobs_inner.width_global >= 4 and jobs_inner.height_global >= 2) {
        try textBlock(jobs_inner, ctx);
    }

    if (bottom_height > 0) {
        const bottom_scissor = scissor.initChild(0, @intCast(top_height + gap_y), width, bottom_height);
        const logs_inner = try panel(bottom_scissor, ctx, "Logs");
        if (logs_inner.width_global >= 4 and logs_inner.height_global >= 2) {
            if (logs_inner.height_global > 2) {
                const text_height = logs_inner.height_global - 1;
                const text_scissor = logs_inner.initChild(0, 0, logs_inner.width_global, text_height);
                try textBlock(text_scissor, ctx);
                const spark_scissor = logs_inner.initChild(0, @intCast(text_height), logs_inner.width_global, 1);
                try sparkline(spark_scissor, ctx);
            } else {
                try textBlock(logs_inner, ctx);
            }
        }
    }
}

fn renderMetricsColumn(scissor: renderer.Scissor, ctx: *PrimitiveContext) renderer.Scissor.PrintError!void {
    const width = scissor.width_global;
    const height = scissor.height_global;
    if (width < 4 or height < 3) return;

    if (height < 6) {
        const inner = try panel(scissor, ctx, "Metrics");
        if (inner.width_global >= 4 and inner.height_global >= 2) {
            try sparkline(inner, ctx);
        }
        return;
    }

    const gap_y: u16 = if (height >= 14) 1 else 0;
    const available = height - gap_y;
    const top_height: u16 = @intCast((@as(u32, available) + 1) / 2);
    const bottom_height = available - top_height;

    const top_scissor = scissor.initChild(0, 0, width, top_height);
    const metrics_inner = try panel(top_scissor, ctx, "Metrics");
    if (metrics_inner.width_global >= 4 and metrics_inner.height_global >= 2) {
        if (metrics_inner.height_global > 2) {
            const text_height = metrics_inner.height_global - 1;
            const text_scissor = metrics_inner.initChild(0, 0, metrics_inner.width_global, text_height);
            try textBlock(text_scissor, ctx);
            const spark_scissor = metrics_inner.initChild(0, @intCast(text_height), metrics_inner.width_global, 1);
            try sparkline(spark_scissor, ctx);
        } else {
            try sparkline(metrics_inner, ctx);
        }
    }

    if (bottom_height > 0) {
        const bottom_scissor = scissor.initChild(0, @intCast(top_height + gap_y), width, bottom_height);
        const events_inner = try panel(bottom_scissor, ctx, "Events");
        if (events_inner.width_global >= 4 and events_inner.height_global >= 2) {
            if (events_inner.width_global >= 14 and events_inner.height_global >= 3) {
                const gap: u16 = 1;
                var list_width: u16 = @intCast((@as(u32, events_inner.width_global) * 2) / 3);
                if (list_width < 6) list_width = 6;
                if (list_width + gap < events_inner.width_global) {
                    const list_scissor = events_inner.initChild(0, 0, list_width, events_inner.height_global);
                    const items = @min(list_scissor.height_global, @as(u16, 8));
                    try list(list_scissor, ctx, items);

                    const heatmap_width = events_inner.width_global - list_width - gap;
                    const heatmap_scissor = events_inner.initChild(@intCast(list_width + gap), 0, heatmap_width, events_inner.height_global);
                    const heatmap_pattern = ".:+*#";
                    const heatmap_skip_mod: u8 = 5;
                    const heatmap_skip_val: u8 = 2;
                    const fill_width = heatmap_scissor.width_global;
                    const fill_height = heatmap_scissor.height_global;
                    if (fill_width > 0 and fill_height > 0 and heatmap_pattern.len > 0) {
                        var heatmap_y: u16 = 0;
                        while (heatmap_y < fill_height) : (heatmap_y += 1) {
                            var heatmap_x: u16 = 0;
                            while (heatmap_x < fill_width) : (heatmap_x += 1) {
                                const sum = @as(u32, heatmap_x) + @as(u32, heatmap_y);
                                if (heatmap_skip_mod != 0 and @as(u8, @intCast(sum % heatmap_skip_mod)) == heatmap_skip_val) continue;
                                const idx: usize = @intCast(sum % @as(u32, @intCast(heatmap_pattern.len)));
                                const style_id = ctx.styleFor(heatmap_x, heatmap_y);
                                setAsciiCell(heatmap_scissor, heatmap_x, heatmap_y, heatmap_pattern[idx], style_id);
                            }
                        }
                    }
                    return;
                }
            }
            const items = @min(events_inner.height_global, @as(u16, 8));
            try list(events_inner, ctx, items);
        }
    }
}

pub fn datasetUnicodeStress(scissor: renderer.Scissor, ctx: *PrimitiveContext) renderer.Scissor.PrintError!void {
    if (scissor.width_global == 0 or scissor.height_global == 0) return;

    scissor.clear();

    const width = scissor.width_global;
    const height = scissor.height_global;

    const header_height: u16 = if (height >= 3) 2 else if (height >= 2) 1 else 0;

    if (header_height > 0) {
        const header_scissor = scissor.initChild(0, 0, width, header_height);
        try renderUnicodeHeader(header_scissor, ctx);
    }

    const content_height = height - header_height;
    if (content_height > 0) {
        const content_scissor = scissor.initChild(0, @intCast(header_height), width, content_height);
        try renderUnicodeContent(content_scissor, ctx);
    }
}

pub fn datasetDynamic(scissor: renderer.Scissor, ctx: *PrimitiveContext) renderer.Scissor.PrintError!void {
    if (scissor.width_global == 0 or scissor.height_global == 0) return;

    scissor.clear();

    const width = scissor.width_global;
    const height = scissor.height_global;

    const header_height: u16 = if (height >= 3) 2 else if (height >= 2) 1 else 0;
    const footer_height: u16 = if (height >= 6) 1 else 0;

    if (header_height > 0) {
        const header_scissor = scissor.initChild(0, 0, width, header_height);
        const inner = try panel(header_scissor, ctx, "Live");
        if (inner.width_global > 2 and inner.height_global > 0) {
            const style_id = ctx.styleFor(1, 0);
            _ = try inner.print(ctx.codepoint_buffer, "Dynamic Unicode", 1, 0, .{
                .wrap = false,
                .tab_width = 4,
                .style = style_id,
            });
        }
    }

    const content_height = height - header_height - footer_height;
    if (content_height > 0) {
        const content_scissor = scissor.initChild(0, @intCast(header_height), width, content_height);
        try renderDynamicContent(content_scissor, ctx);
    }

    if (footer_height > 0) {
        const footer_scissor = scissor.initChild(0, @intCast(height - footer_height), width, footer_height);
        const style_id = ctx.styleFor(0, 0);
        _ = try footer_scissor.print(ctx.codepoint_buffer, "Signals: OK | Stream: Active", 0, 0, .{
            .wrap = false,
            .tab_width = 4,
            .style = style_id,
        });
    }
}

fn renderUnicodeHeader(scissor: renderer.Scissor, ctx: *PrimitiveContext) renderer.Scissor.PrintError!void {
    if (scissor.width_global == 0 or scissor.height_global == 0) return;

    const title = "Unicode Stress Dataset";

    if (scissor.height_global >= 2 and scissor.width_global >= 4) {
        const inner = try panel(scissor, ctx, "Unicode");
        if (inner.width_global > 2 and inner.height_global > 0) {
            const style_id = ctx.styleFor(1, 0);
            _ = try inner.print(ctx.codepoint_buffer, title, 1, 0, .{
                .wrap = false,
                .tab_width = 4,
                .style = style_id,
            });
        }
        return;
    }

    const style_id = ctx.styleFor(0, 0);
    _ = try scissor.print(ctx.codepoint_buffer, title, 0, 0, .{
        .wrap = false,
        .tab_width = 4,
        .style = style_id,
    });
}

fn renderUnicodeContent(scissor: renderer.Scissor, ctx: *PrimitiveContext) renderer.Scissor.PrintError!void {
    const width = scissor.width_global;
    const height = scissor.height_global;
    if (width == 0 or height == 0) return;

    if (width >= 70 and height >= 8) {
        const gap: u16 = if (width >= 120) 2 else 1;
        var left_width: u16 = @intCast((@as(u32, width) * 3) / 5);
        if (left_width < 16) left_width = 16;
        if (left_width + gap >= width) {
            try textBlock(scissor, ctx);
            return;
        }
        const right_width: u16 = width - left_width - gap;
        const left_scissor = scissor.initChild(0, 0, left_width, height);
        const right_scissor = scissor.initChild(@intCast(left_width + gap), 0, right_width, height);
        try renderUnicodeColumn(left_scissor, ctx, true);
        try renderUnicodeColumn(right_scissor, ctx, false);
        return;
    }

    if (width >= 40 and height >= 6) {
        const stack_width = scissor.width_global;
        const stack_height = scissor.height_global;
        if (stack_width < 4 or stack_height < 3) return;

        const gap_y: u16 = if (stack_height >= 12) 1 else 0;
        const available = stack_height - gap_y;
        if (available == 0) return;

        const top_height: u16 = @intCast((@as(u32, available) * 2) / 3);
        const bottom_height = available - top_height;

        const top_scissor = scissor.initChild(0, 0, stack_width, top_height);
        const top_inner = try panel(top_scissor, ctx, "Stream");
        if (top_inner.width_global >= 4 and top_inner.height_global >= 2) {
            try textBlock(top_inner, ctx);
        }

        if (bottom_height > 0) {
            const bottom_scissor = scissor.initChild(0, @intCast(top_height + gap_y), stack_width, bottom_height);
            const bottom_inner = try panel(bottom_scissor, ctx, "Updates");
            if (bottom_inner.width_global >= 4 and bottom_inner.height_global >= 2) {
                if (bottom_inner.height_global > 2) {
                    const text_height = bottom_inner.height_global - 1;
                    const text_scissor = bottom_inner.initChild(0, 0, bottom_inner.width_global, text_height);
                    try textBlock(text_scissor, ctx);
                    const spark_scissor = bottom_inner.initChild(0, @intCast(text_height), bottom_inner.width_global, 1);
                    try sparkline(spark_scissor, ctx);
                } else {
                    try textBlock(bottom_inner, ctx);
                }
            }
        }
        return;
    }

    try textBlock(scissor, ctx);
}

fn renderUnicodeColumn(scissor: renderer.Scissor, ctx: *PrimitiveContext, with_list: bool) renderer.Scissor.PrintError!void {
    const width = scissor.width_global;
    const height = scissor.height_global;
    if (width < 4 or height < 3) return;

    const gap_y: u16 = if (height >= 16) 1 else 0;
    const available = height - gap_y;
    if (available == 0) return;

    var top_height: u16 = @intCast((@as(u32, available) * 3) / 5);
    if (top_height == 0) top_height = available;
    const bottom_height = available - top_height;

    const top_scissor = scissor.initChild(0, 0, width, top_height);
    const top_title = if (with_list) "Feed" else "Messages";
    const top_inner = try panel(top_scissor, ctx, top_title);
    if (top_inner.width_global >= 4 and top_inner.height_global >= 2) {
        try textBlock(top_inner, ctx);
    }

    if (bottom_height > 0) {
        const bottom_scissor = scissor.initChild(0, @intCast(top_height + gap_y), width, bottom_height);
        const bottom_title = if (with_list) "Queue" else "Metrics";
        const bottom_inner = try panel(bottom_scissor, ctx, bottom_title);
        if (bottom_inner.width_global >= 4 and bottom_inner.height_global >= 2) {
            if (with_list) {
                const items = @min(bottom_inner.height_global, @as(u16, 12));
                try list(bottom_inner, ctx, items);
            } else {
                if (bottom_inner.height_global > 2) {
                    const text_height = bottom_inner.height_global - 1;
                    const text_scissor = bottom_inner.initChild(0, 0, bottom_inner.width_global, text_height);
                    try textBlock(text_scissor, ctx);
                    const spark_scissor = bottom_inner.initChild(0, @intCast(text_height), bottom_inner.width_global, 1);
                    try sparkline(spark_scissor, ctx);
                } else {
                    try textBlock(bottom_inner, ctx);
                }
            }
        }
    }
}

fn renderDynamicContent(scissor: renderer.Scissor, ctx: *PrimitiveContext) renderer.Scissor.PrintError!void {
    const width = scissor.width_global;
    const height = scissor.height_global;
    if (width < 4 or height < 3) return;

    const gap: u16 = if (width >= 90) 2 else 1;

    if (width >= 60 and height >= 8 and width > gap + 16) {
        var main_width: u16 = @intCast((@as(u32, width) * 2) / 3);
        if (main_width < 20) main_width = 20;
        if (main_width + gap < width) {
            const side_width: u16 = width - main_width - gap;
            if (side_width >= 12) {
                const main_scissor = scissor.initChild(0, 0, main_width, height);
                const side_scissor = scissor.initChild(@intCast(main_width + gap), 0, side_width, height);

                const main_inner = try panel(main_scissor, ctx, "Animation");
                if (main_inner.width_global >= 4 and main_inner.height_global >= 2) {
                    try textBlock(main_inner, ctx);
                }

                const sidebar_width = side_scissor.width_global;
                const sidebar_height = side_scissor.height_global;
                if (sidebar_width >= 4 and sidebar_height >= 3) {
                    const sidebar_gap_y: u16 = if (sidebar_height >= 12) 1 else 0;
                    const sidebar_available = sidebar_height - sidebar_gap_y;
                    if (sidebar_available > 0) {
                        const sidebar_top_height: u16 = @intCast((@as(u32, sidebar_available) * 3) / 5);
                        const sidebar_bottom_height = sidebar_available - sidebar_top_height;

                        const top_scissor = side_scissor.initChild(0, 0, sidebar_width, sidebar_top_height);
                        const top_inner = try panel(top_scissor, ctx, "Events");
                        if (top_inner.width_global >= 4 and top_inner.height_global >= 2) {
                            const items = @min(top_inner.height_global, @as(u16, 10));
                            try list(top_inner, ctx, items);
                        }

                        if (sidebar_bottom_height > 0) {
                            const bottom_scissor = side_scissor.initChild(0, @intCast(sidebar_top_height + sidebar_gap_y), sidebar_width, sidebar_bottom_height);
                            const bottom_inner = try panel(bottom_scissor, ctx, "Pulse");
                            if (bottom_inner.width_global >= 4 and bottom_inner.height_global >= 2) {
                                if (bottom_inner.height_global > 2) {
                                    const text_height = bottom_inner.height_global - 1;
                                    const text_scissor = bottom_inner.initChild(0, 0, bottom_inner.width_global, text_height);
                                    try textBlock(text_scissor, ctx);
                                    const spark_scissor = bottom_inner.initChild(0, @intCast(text_height), bottom_inner.width_global, 1);
                                    try sparkline(spark_scissor, ctx);
                                } else {
                                    try sparkline(bottom_inner, ctx);
                                }
                            }
                        }
                    }
                }
                return;
            }
        }
    }

    const inner = try panel(scissor, ctx, "Animation");
    if (inner.width_global >= 4 and inner.height_global >= 2) {
        try textBlock(inner, ctx);
    }
}

fn setAsciiCell(scissor: renderer.Scissor, x: u16, y: u16, byte: u8, style_id: renderer.Style.Id) void {
    const cell = renderer.Cell{
        .data = .{ .codepoint = @as(u21, byte) },
        .tag = .codepoint,
        .width = .narrow,
        .style = style_id,
    };
    scissor.set(x, y, cell);
}

const Rendered = struct {
    fb: renderer.FrameBuffer,
    cells: []align(std.heap.page_size_min) renderer.Cell,

    fn deinit(self: *Rendered, allocator: std.mem.Allocator) void {
        self.fb.deinit();
        allocator.free(self.cells);
    }
};

fn renderDatasetOnce(
    allocator: std.mem.Allocator,
    dataset_fn: *const fn (renderer.Scissor, *PrimitiveContext) renderer.Scissor.PrintError!void,
    width: u16,
    height: u16,
    seed: u64,
    mix_text: text_mix.TextMix,
    mix_style: style_mix.StyleMix,
) !Rendered {
    const cell_count = @as(usize, width) * @as(usize, height);
    const cells = try allocator.alignedAlloc(renderer.Cell, buffer_alignment, cell_count);
    var fb = try renderer.FrameBuffer.init(cells, width, height, .default);
    fb.clear();

    const palette_len = style_mix.paletteLen(mix_style);
    var style_sheet = try renderer.Style.Sheet.initCapacity(allocator, palette_len);
    defer style_sheet.deinit(allocator);

    const style_ids = try allocator.alignedAlloc(renderer.Style.Id, buffer_alignment, palette_len);
    defer allocator.free(style_ids);
    const style_slice = style_mix.fillStyleIds(&style_sheet, allocator, mix_style, style_ids);

    var prng = rng.init(seed);
    const random = prng.random();
    var style_sequence = style_mix.StyleSequence.init(mix_style, random, palette_len);
    var codepoint_buffer: [256]u21 = undefined;

    var ctx = PrimitiveContext{
        .random = random,
        .text_mix = mix_text,
        .style_sequence = &style_sequence,
        .style_ids = style_slice,
        .codepoint_buffer = codepoint_buffer[0..],
    };

    const scissor = fb.scissor();
    try dataset_fn(scissor, &ctx);

    return .{ .fb = fb, .cells = cells };
}

fn assertDatasetDeterministic(
    dataset_fn: *const fn (renderer.Scissor, *PrimitiveContext) renderer.Scissor.PrintError!void,
    mix_text: text_mix.TextMix,
    mix_style: style_mix.StyleMix,
    width: u16,
    height: u16,
    seed: u64,
) !void {
    const allocator = std.testing.allocator;
    var first = try renderDatasetOnce(allocator, dataset_fn, width, height, seed, mix_text, mix_style);
    defer first.deinit(allocator);
    var second = try renderDatasetOnce(allocator, dataset_fn, width, height, seed, mix_text, mix_style);
    defer second.deinit(allocator);
    const testing = std.testing;
    try testing.expectEqual(first.fb.width, second.fb.width);
    try testing.expectEqual(first.fb.height, second.fb.height);
    try testing.expect(std.mem.eql(renderer.Cell, first.fb.cells, second.fb.cells));

    const end_a = first.fb.grapheme_buffer.end_index;
    const end_b = second.fb.grapheme_buffer.end_index;
    try testing.expectEqual(end_a, end_b);
    const slice_a = first.fb.grapheme_buffer.buffer.reserved_pages[0..end_a];
    const slice_b = second.fb.grapheme_buffer.buffer.reserved_pages[0..end_b];
    try testing.expect(std.mem.eql(u8, slice_a, slice_b));
}

test "datasets deterministic with same seed" {
    const width: u16 = 80;
    const height: u16 = 24;
    const seed: u64 = 0xC0FFEE;

    try assertDatasetDeterministic(datasetTypical, .common, .themed, width, height, seed);
    try assertDatasetDeterministic(datasetUnicodeStress, .grapheme_stress, .themed, width, height, seed);
    try assertDatasetDeterministic(datasetDynamic, .grapheme_stress, .churn, width, height, seed);
}
