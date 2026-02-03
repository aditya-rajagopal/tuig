const std = @import("std");
const renderer = @import("renderer");
const primitives = @import("primitives.zig");
const rng = @import("rng.zig");
const style_mix = @import("style_mix.zig");
const text_mix = @import("text_mix.zig");

pub fn datasetTypical(scissor: renderer.Scissor, ctx: *primitives.PrimitiveContext) renderer.Scissor.PrintError!void {
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

fn renderMenuBar(scissor: renderer.Scissor, ctx: *primitives.PrimitiveContext) renderer.Scissor.PrintError!void {
    if (scissor.width_global == 0 or scissor.height_global == 0) return;

    const menu_text = "File  Edit  View  Search  Help";

    if (scissor.height_global >= 2 and scissor.width_global >= 4) {
        const inner = try primitives.panel(scissor, ctx, "Menu");
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

fn renderStatusBar(scissor: renderer.Scissor, ctx: *primitives.PrimitiveContext) renderer.Scissor.PrintError!void {
    if (scissor.width_global == 0 or scissor.height_global == 0) return;

    const status_text = "STATUS: OK  |  Workers 12  |  Queue 24  |  Uptime 99.9%";

    if (scissor.height_global >= 2 and scissor.width_global >= 4) {
        const inner = try primitives.panel(scissor, ctx, "Status");
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

fn renderTypicalContent(scissor: renderer.Scissor, ctx: *primitives.PrimitiveContext) renderer.Scissor.PrintError!void {
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

fn renderSidebar(scissor: renderer.Scissor, ctx: *primitives.PrimitiveContext) renderer.Scissor.PrintError!void {
    const width = scissor.width_global;
    const height = scissor.height_global;
    if (width < 4 or height < 3) return;

    if (height < 6) {
        const inner = try primitives.panel(scissor, ctx, "Navigation");
        if (inner.width_global >= 4 and inner.height_global >= 2) {
            try primitives.list(inner, ctx, inner.height_global);
        }
        return;
    }

    const gap_y: u16 = if (height >= 16) 1 else 0;
    const available = height - gap_y;
    const top_height: u16 = @intCast((@as(u32, available) * 3) / 5);
    const bottom_height = available - top_height;

    const top_scissor = scissor.initChild(0, 0, width, top_height);
    const nav_inner = try primitives.panel(top_scissor, ctx, "Navigation");
    if (nav_inner.width_global >= 4 and nav_inner.height_global >= 2) {
        const items = @min(nav_inner.height_global, @as(u16, 12));
        try primitives.list(nav_inner, ctx, items);
    }

    if (bottom_height > 0) {
        const bottom_scissor = scissor.initChild(0, @intCast(top_height + gap_y), width, bottom_height);
        const queue_inner = try primitives.panel(bottom_scissor, ctx, "Queue");
        if (queue_inner.width_global >= 4 and queue_inner.height_global >= 2) {
            try primitives.textBlock(queue_inner, ctx);
        }
    }
}

fn renderMainColumn(scissor: renderer.Scissor, ctx: *primitives.PrimitiveContext) renderer.Scissor.PrintError!void {
    const width = scissor.width_global;
    const height = scissor.height_global;
    if (width < 4 or height < 3) return;

    if (height < 6) {
        const inner = try primitives.panel(scissor, ctx, "Content");
        if (inner.width_global >= 4 and inner.height_global >= 2) {
            try primitives.textBlock(inner, ctx);
        }
        return;
    }

    const gap_y: u16 = if (height >= 18) 1 else 0;
    const available = height - gap_y;
    var top_height: u16 = @intCast((@as(u32, available) * 3) / 5);
    if (top_height >= available) top_height = available;
    const bottom_height = available - top_height;

    const top_scissor = scissor.initChild(0, 0, width, top_height);
    const jobs_inner = try primitives.panel(top_scissor, ctx, "Jobs");
    if (jobs_inner.width_global >= 6 and jobs_inner.height_global >= 4) {
        try primitives.table(jobs_inner, ctx, 4, 8);
    } else if (jobs_inner.width_global >= 4 and jobs_inner.height_global >= 2) {
        try primitives.textBlock(jobs_inner, ctx);
    }

    if (bottom_height > 0) {
        const bottom_scissor = scissor.initChild(0, @intCast(top_height + gap_y), width, bottom_height);
        const logs_inner = try primitives.panel(bottom_scissor, ctx, "Logs");
        if (logs_inner.width_global >= 4 and logs_inner.height_global >= 2) {
            if (logs_inner.height_global > 2) {
                const text_height = logs_inner.height_global - 1;
                const text_scissor = logs_inner.initChild(0, 0, logs_inner.width_global, text_height);
                try primitives.textBlock(text_scissor, ctx);
                const spark_scissor = logs_inner.initChild(0, @intCast(text_height), logs_inner.width_global, 1);
                try primitives.sparkline(spark_scissor, ctx);
            } else {
                try primitives.textBlock(logs_inner, ctx);
            }
        }
    }
}

fn renderMetricsColumn(scissor: renderer.Scissor, ctx: *primitives.PrimitiveContext) renderer.Scissor.PrintError!void {
    const width = scissor.width_global;
    const height = scissor.height_global;
    if (width < 4 or height < 3) return;

    if (height < 6) {
        const inner = try primitives.panel(scissor, ctx, "Metrics");
        if (inner.width_global >= 4 and inner.height_global >= 2) {
            try primitives.sparkline(inner, ctx);
        }
        return;
    }

    const gap_y: u16 = if (height >= 14) 1 else 0;
    const available = height - gap_y;
    const top_height: u16 = @intCast((@as(u32, available) + 1) / 2);
    const bottom_height = available - top_height;

    const top_scissor = scissor.initChild(0, 0, width, top_height);
    const metrics_inner = try primitives.panel(top_scissor, ctx, "Metrics");
    if (metrics_inner.width_global >= 4 and metrics_inner.height_global >= 2) {
        if (metrics_inner.height_global > 2) {
            const text_height = metrics_inner.height_global - 1;
            const text_scissor = metrics_inner.initChild(0, 0, metrics_inner.width_global, text_height);
            try primitives.textBlock(text_scissor, ctx);
            const spark_scissor = metrics_inner.initChild(0, @intCast(text_height), metrics_inner.width_global, 1);
            try primitives.sparkline(spark_scissor, ctx);
        } else {
            try primitives.sparkline(metrics_inner, ctx);
        }
    }

    if (bottom_height > 0) {
        const bottom_scissor = scissor.initChild(0, @intCast(top_height + gap_y), width, bottom_height);
        const events_inner = try primitives.panel(bottom_scissor, ctx, "Events");
        if (events_inner.width_global >= 4 and events_inner.height_global >= 2) {
            if (events_inner.width_global >= 14 and events_inner.height_global >= 3) {
                const gap: u16 = 1;
                var list_width: u16 = @intCast((@as(u32, events_inner.width_global) * 2) / 3);
                if (list_width < 6) list_width = 6;
                if (list_width + gap < events_inner.width_global) {
                    const list_scissor = events_inner.initChild(0, 0, list_width, events_inner.height_global);
                    const items = @min(list_scissor.height_global, @as(u16, 8));
                    try primitives.list(list_scissor, ctx, items);

                    const heatmap_width = events_inner.width_global - list_width - gap;
                    const heatmap_scissor = events_inner.initChild(@intCast(list_width + gap), 0, heatmap_width, events_inner.height_global);
                    fillStyleField(heatmap_scissor, ctx, ".:+*#", 5, 2);
                    return;
                }
            }
            const items = @min(events_inner.height_global, @as(u16, 8));
            try primitives.list(events_inner, ctx, items);
        }
    }
}

pub fn datasetUnicodeStress(scissor: renderer.Scissor, ctx: *primitives.PrimitiveContext) renderer.Scissor.PrintError!void {
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

pub fn datasetDynamic(scissor: renderer.Scissor, ctx: *primitives.PrimitiveContext) renderer.Scissor.PrintError!void {
    if (scissor.width_global == 0 or scissor.height_global == 0) return;

    scissor.clear();

    const width = scissor.width_global;
    const height = scissor.height_global;

    const header_height: u16 = if (height >= 3) 2 else if (height >= 2) 1 else 0;
    const footer_height: u16 = if (height >= 6) 1 else 0;

    if (header_height > 0) {
        const header_scissor = scissor.initChild(0, 0, width, header_height);
        const inner = try primitives.panel(header_scissor, ctx, "Live");
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

fn renderUnicodeHeader(scissor: renderer.Scissor, ctx: *primitives.PrimitiveContext) renderer.Scissor.PrintError!void {
    if (scissor.width_global == 0 or scissor.height_global == 0) return;

    const title = "Unicode Stress Dataset";

    if (scissor.height_global >= 2 and scissor.width_global >= 4) {
        const inner = try primitives.panel(scissor, ctx, "Unicode");
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

fn renderUnicodeContent(scissor: renderer.Scissor, ctx: *primitives.PrimitiveContext) renderer.Scissor.PrintError!void {
    const width = scissor.width_global;
    const height = scissor.height_global;
    if (width == 0 or height == 0) return;

    if (width >= 70 and height >= 8) {
        const gap: u16 = if (width >= 120) 2 else 1;
        var left_width: u16 = @intCast((@as(u32, width) * 3) / 5);
        if (left_width < 16) left_width = 16;
        if (left_width + gap >= width) {
            try primitives.textBlock(scissor, ctx);
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
        try renderUnicodeStack(scissor, ctx);
        return;
    }

    try primitives.textBlock(scissor, ctx);
}

fn renderUnicodeColumn(scissor: renderer.Scissor, ctx: *primitives.PrimitiveContext, with_list: bool) renderer.Scissor.PrintError!void {
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
    const top_inner = try primitives.panel(top_scissor, ctx, top_title);
    if (top_inner.width_global >= 4 and top_inner.height_global >= 2) {
        try primitives.textBlock(top_inner, ctx);
    }

    if (bottom_height > 0) {
        const bottom_scissor = scissor.initChild(0, @intCast(top_height + gap_y), width, bottom_height);
        const bottom_title = if (with_list) "Queue" else "Metrics";
        const bottom_inner = try primitives.panel(bottom_scissor, ctx, bottom_title);
        if (bottom_inner.width_global >= 4 and bottom_inner.height_global >= 2) {
            if (with_list) {
                const items = @min(bottom_inner.height_global, @as(u16, 12));
                try primitives.list(bottom_inner, ctx, items);
            } else {
                if (bottom_inner.height_global > 2) {
                    const text_height = bottom_inner.height_global - 1;
                    const text_scissor = bottom_inner.initChild(0, 0, bottom_inner.width_global, text_height);
                    try primitives.textBlock(text_scissor, ctx);
                    const spark_scissor = bottom_inner.initChild(0, @intCast(text_height), bottom_inner.width_global, 1);
                    try primitives.sparkline(spark_scissor, ctx);
                } else {
                    try primitives.textBlock(bottom_inner, ctx);
                }
            }
        }
    }
}

fn renderUnicodeStack(scissor: renderer.Scissor, ctx: *primitives.PrimitiveContext) renderer.Scissor.PrintError!void {
    const width = scissor.width_global;
    const height = scissor.height_global;
    if (width < 4 or height < 3) return;

    const gap_y: u16 = if (height >= 12) 1 else 0;
    const available = height - gap_y;
    if (available == 0) return;

    const top_height: u16 = @intCast((@as(u32, available) * 2) / 3);
    const bottom_height = available - top_height;

    const top_scissor = scissor.initChild(0, 0, width, top_height);
    const top_inner = try primitives.panel(top_scissor, ctx, "Stream");
    if (top_inner.width_global >= 4 and top_inner.height_global >= 2) {
        try primitives.textBlock(top_inner, ctx);
    }

    if (bottom_height > 0) {
        const bottom_scissor = scissor.initChild(0, @intCast(top_height + gap_y), width, bottom_height);
        const bottom_inner = try primitives.panel(bottom_scissor, ctx, "Updates");
        if (bottom_inner.width_global >= 4 and bottom_inner.height_global >= 2) {
            if (bottom_inner.height_global > 2) {
                const text_height = bottom_inner.height_global - 1;
                const text_scissor = bottom_inner.initChild(0, 0, bottom_inner.width_global, text_height);
                try primitives.textBlock(text_scissor, ctx);
                const spark_scissor = bottom_inner.initChild(0, @intCast(text_height), bottom_inner.width_global, 1);
                try primitives.sparkline(spark_scissor, ctx);
            } else {
                try primitives.textBlock(bottom_inner, ctx);
            }
        }
    }
}

fn renderDynamicContent(scissor: renderer.Scissor, ctx: *primitives.PrimitiveContext) renderer.Scissor.PrintError!void {
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

                const main_inner = try primitives.panel(main_scissor, ctx, "Animation");
                if (main_inner.width_global >= 4 and main_inner.height_global >= 2) {
                    try primitives.textBlock(main_inner, ctx);
                }

                try renderDynamicSidebar(side_scissor, ctx);
                return;
            }
        }
    }

    const inner = try primitives.panel(scissor, ctx, "Animation");
    if (inner.width_global >= 4 and inner.height_global >= 2) {
        try primitives.textBlock(inner, ctx);
    }
}

fn renderDynamicSidebar(scissor: renderer.Scissor, ctx: *primitives.PrimitiveContext) renderer.Scissor.PrintError!void {
    const width = scissor.width_global;
    const height = scissor.height_global;
    if (width < 4 or height < 3) return;

    const gap_y: u16 = if (height >= 12) 1 else 0;
    const available = height - gap_y;
    if (available == 0) return;

    const top_height: u16 = @intCast((@as(u32, available) * 3) / 5);
    const bottom_height = available - top_height;

    const top_scissor = scissor.initChild(0, 0, width, top_height);
    const top_inner = try primitives.panel(top_scissor, ctx, "Events");
    if (top_inner.width_global >= 4 and top_inner.height_global >= 2) {
        const items = @min(top_inner.height_global, @as(u16, 10));
        try primitives.list(top_inner, ctx, items);
    }

    if (bottom_height > 0) {
        const bottom_scissor = scissor.initChild(0, @intCast(top_height + gap_y), width, bottom_height);
        const bottom_inner = try primitives.panel(bottom_scissor, ctx, "Pulse");
        if (bottom_inner.width_global >= 4 and bottom_inner.height_global >= 2) {
            if (bottom_inner.height_global > 2) {
                const text_height = bottom_inner.height_global - 1;
                const text_scissor = bottom_inner.initChild(0, 0, bottom_inner.width_global, text_height);
                try primitives.textBlock(text_scissor, ctx);
                const spark_scissor = bottom_inner.initChild(0, @intCast(text_height), bottom_inner.width_global, 1);
                try primitives.sparkline(spark_scissor, ctx);
            } else {
                try primitives.sparkline(bottom_inner, ctx);
            }
        }
    }
}

fn fillStyleField(scissor: renderer.Scissor, ctx: *primitives.PrimitiveContext, pattern: []const u8, skip_mod: u8, skip_val: u8) void {
    const width = scissor.width_global;
    const height = scissor.height_global;
    if (width == 0 or height == 0) return;
    if (pattern.len == 0) return;

    var y: u16 = 0;
    while (y < height) : (y += 1) {
        var x: u16 = 0;
        while (x < width) : (x += 1) {
            const sum = @as(u32, x) + @as(u32, y);
            if (skip_mod != 0 and @as(u8, @intCast(sum % skip_mod)) == skip_val) continue;
            const idx: usize = @intCast(sum % @as(u32, @intCast(pattern.len)));
            const style_id = ctx.styleFor(x, y);
            setAsciiCell(scissor, x, y, pattern[idx], style_id);
        }
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

    fn deinit(self: *Rendered, allocator: std.mem.Allocator) void {
        self.fb.deinit();
        allocator.free(self.fb.cells);
    }
};

fn renderDatasetOnce(
    allocator: std.mem.Allocator,
    dataset_fn: *const fn (renderer.Scissor, *primitives.PrimitiveContext) renderer.Scissor.PrintError!void,
    width: u16,
    height: u16,
    seed: u64,
    mix_text: text_mix.TextMix,
    mix_style: style_mix.StyleMix,
) !Rendered {
    const cell_count = @as(usize, width) * @as(usize, height);
    const cells = try allocator.alloc(renderer.Cell, cell_count);
    var fb = try renderer.FrameBuffer.init(cells, width, height, .default);
    fb.clear();

    const palette_len = style_mix.paletteLen(mix_style);
    var style_sheet = try renderer.Style.Sheet.initCapacity(allocator, palette_len);
    defer style_sheet.deinit(allocator);

    const style_ids = try allocator.alloc(renderer.Style.Id, palette_len);
    defer allocator.free(style_ids);
    const style_slice = style_mix.fillStyleIds(&style_sheet, allocator, mix_style, style_ids);

    var prng = rng.init(seed);
    const random = prng.random();
    var style_sequence = style_mix.StyleSequence.init(mix_style, random, palette_len);
    var codepoint_buffer: [256]u21 = undefined;

    var ctx = primitives.PrimitiveContext{
        .random = random,
        .text_mix = mix_text,
        .style_sequence = &style_sequence,
        .style_ids = style_slice,
        .codepoint_buffer = codepoint_buffer[0..],
    };

    const scissor = fb.scissor();
    try dataset_fn(scissor, &ctx);

    return .{ .fb = fb };
}

fn expectSameRender(a: Rendered, b: Rendered) !void {
    const testing = std.testing;
    try testing.expectEqual(a.fb.width, b.fb.width);
    try testing.expectEqual(a.fb.height, b.fb.height);
    try testing.expect(std.mem.eql(renderer.Cell, a.fb.cells, b.fb.cells));

    const end_a = a.fb.grapheme_buffer.end_index;
    const end_b = b.fb.grapheme_buffer.end_index;
    try testing.expectEqual(end_a, end_b);
    const slice_a = a.fb.grapheme_buffer.buffer.reserved_pages[0..end_a];
    const slice_b = b.fb.grapheme_buffer.buffer.reserved_pages[0..end_b];
    try testing.expect(std.mem.eql(u8, slice_a, slice_b));
}

fn assertDatasetDeterministic(
    dataset_fn: *const fn (renderer.Scissor, *primitives.PrimitiveContext) renderer.Scissor.PrintError!void,
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
    try expectSameRender(first, second);
}

test "datasets deterministic with same seed" {
    const width: u16 = 80;
    const height: u16 = 24;
    const seed: u64 = 0xC0FFEE;

    try assertDatasetDeterministic(datasetTypical, .common, .themed, width, height, seed);
    try assertDatasetDeterministic(datasetUnicodeStress, .grapheme_stress, .themed, width, height, seed);
    try assertDatasetDeterministic(datasetDynamic, .grapheme_stress, .churn, width, height, seed);
}
