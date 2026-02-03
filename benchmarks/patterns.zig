const std = @import("std");
const assert = std.debug.assert;

const renderer = @import("renderer");
const rng = @import("rng.zig");

const buffer_alignment = std.mem.Alignment.fromByteUnits(std.heap.page_size_min);

pub const Pattern = enum {
    cursor_move,
    panel_swap,
    style_flicker,
    unicode_width_churn,
    rect_churn,
};

pub const PatternState = struct {
    pattern: Pattern,
    base: renderer.FrameBuffer,
    cursor_positions: ?[]renderer.Position,
    panel_rect: Rect,
    churn_rect: Rect,
    rect_churn_rect: Rect,
    style_ids: []const renderer.Style.Id,
    seed: u64,

    pub fn init(
        allocator: std.mem.Allocator,
        pattern: Pattern,
        source: *const renderer.FrameBuffer,
        seed: u64,
        style_ids: []const renderer.Style.Id,
    ) !PatternState {
        const cell_count = @as(usize, source.width) * @as(usize, source.height);
        const base_cells = try allocator.alignedAlloc(renderer.Cell, buffer_alignment, cell_count);
        var base = try renderer.FrameBuffer.init(base_cells, source.width, source.height, .default);
        try base.grapheme_buffer.ensureTotalCapacity(source.grapheme_buffer.end_index);
        copyFrame(&base, source);

        var cursor_positions: ?[]renderer.Position = null;
        if (pattern == .cursor_move) {
            const width = base.width;
            const height = base.height;
            if (width == 0 or height == 0) {
                cursor_positions = try allocator.alignedAlloc(renderer.Position, buffer_alignment, 0);
            } else {
                var count: usize = 0;
                var y: u16 = 0;
                while (y < height) : (y += 1) {
                    var x: u16 = 0;
                    while (x < width) : (x += 1) {
                        const cell = base.get(x, y);
                        if (cell.width == .narrow) count += 1;
                    }
                }

                if (count == 0) {
                    const fallback = try allocator.alignedAlloc(renderer.Position, buffer_alignment, 1);
                    fallback[0] = .{ .x = 0, .y = 0 };
                    cursor_positions = fallback;
                } else {
                    const positions = try allocator.alignedAlloc(renderer.Position, buffer_alignment, count);
                    var idx: usize = 0;
                    y = 0;
                    while (y < height) : (y += 1) {
                        var x: u16 = 0;
                        while (x < width) : (x += 1) {
                            const cell = base.get(x, y);
                            if (cell.width == .narrow) {
                                positions[idx] = .{ .x = x, .y = y };
                                idx += 1;
                            }
                        }
                    }
                    cursor_positions = positions;
                }
            }
        }

        const panel_rect = if (pattern == .panel_swap) blk: {
            const width = base.width;
            const height = base.height;
            if (width == 0 or height == 0) break :blk Rect.zero;
            const min_w: u16 = 12;
            const min_h: u16 = 5;
            const target_w: u16 = if (width < min_w) width else @max(min_w, width / 3);
            const target_h: u16 = if (height < min_h) height else @max(min_h, height / 3);
            break :blk placeRect(width, height, target_w, target_h, seed);
        } else Rect.zero;

        const churn_rect = if (pattern == .unicode_width_churn)
            computeChurnRect(base.width, base.height, seed ^ 0x9e3779b97f4a7c15)
        else
            Rect.zero;

        const rect_churn_rect = if (pattern == .rect_churn)
            computeChurnRect(base.width, base.height, seed ^ 0x3c79ac492ba7b653)
        else
            Rect.zero;

        return .{
            .pattern = pattern,
            .base = base,
            .cursor_positions = cursor_positions,
            .panel_rect = panel_rect,
            .churn_rect = churn_rect,
            .rect_churn_rect = rect_churn_rect,
            .style_ids = style_ids,
            .seed = seed,
        };
    }

    pub fn deinit(self: *PatternState, allocator: std.mem.Allocator) void {
        if (self.cursor_positions) |positions| {
            allocator.free(positions);
        }
        self.base.deinit();
        allocator.free(self.base.cells);
    }

    pub fn renderFrame(self: *PatternState, dest: *renderer.FrameBuffer, frame_index: u64) !void {
        assert(dest.width == self.base.width);
        assert(dest.height == self.base.height);

        try dest.grapheme_buffer.ensureTotalCapacity(self.base.grapheme_buffer.end_index);
        copyFrame(dest, &self.base);

        switch (self.pattern) {
            .cursor_move => applyCursorMove(dest, self.cursor_positions, frame_index),
            .panel_swap => applyPanelSwap(dest, self.panel_rect, frame_index),
            .style_flicker => applyStyleFlicker(dest, self.style_ids, frame_index),
            .unicode_width_churn => applyUnicodeWidthChurn(dest, self.churn_rect, self.seed, frame_index),
            .rect_churn => applyRectChurn(dest, self.rect_churn_rect, self.style_ids, self.seed, frame_index),
        }
    }
};

const Rect = struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,

    const zero = Rect{ .x = 0, .y = 0, .width = 0, .height = 0 };
};

fn computeChurnRect(width: u16, height: u16, seed: u64) Rect {
    if (width == 0 or height == 0) return Rect.zero;
    const min_w: u16 = 8;
    const min_h: u16 = 4;
    const target_w: u16 = if (width < min_w) width else @max(min_w, width / 2);
    const target_h: u16 = if (height < min_h) height else @max(min_h, height / 2);
    return placeRect(width, height, target_w, target_h, seed);
}

fn placeRect(width: u16, height: u16, rect_w: u16, rect_h: u16, seed: u64) Rect {
    if (width == 0 or height == 0) return Rect.zero;
    if (rect_w == 0 or rect_h == 0) return Rect.zero;

    const w32: u32 = width;
    const h32: u32 = height;
    const rw32: u32 = @min(w32, @as(u32, rect_w));
    const rh32: u32 = @min(h32, @as(u32, rect_h));

    const max_x = w32 - rw32;
    const max_y = h32 - rh32;

    var prng = rng.init(seed);
    const random = prng.random();

    const x: u32 = if (max_x == 0) 0 else random.intRangeLessThan(u32, 0, max_x + 1);
    const y: u32 = if (max_y == 0) 0 else random.intRangeLessThan(u32, 0, max_y + 1);

    return .{
        .x = @intCast(x),
        .y = @intCast(y),
        .width = @intCast(rw32),
        .height = @intCast(rh32),
    };
}

fn computeFrameRect(width: u16, height: u16, rect_w: u16, rect_h: u16, seed: u64, frame_index: u64) Rect {
    if (width == 0 or height == 0) return Rect.zero;
    if (rect_w == 0 or rect_h == 0) return Rect.zero;
    const mix_seed = seed ^ (frame_index *% 0x9e3779b97f4a7c15);
    return placeRect(width, height, rect_w, rect_h, mix_seed);
}

fn copyFrame(dest: *renderer.FrameBuffer, src: *const renderer.FrameBuffer) void {
    assert(dest.width == src.width);
    assert(dest.height == src.height);
    @memcpy(dest.cells, src.cells);

    const src_end = src.grapheme_buffer.end_index;
    dest.grapheme_buffer.end_index = src_end;
    dest.grapheme_buffer.generation = src.grapheme_buffer.generation;
    if (src_end > 0) {
        @memcpy(
            dest.grapheme_buffer.buffer.reserved_pages[0..src_end],
            src.grapheme_buffer.buffer.reserved_pages[0..src_end],
        );
    }
}

fn applyCursorMove(dest: *renderer.FrameBuffer, positions_opt: ?[]renderer.Position, frame_index: u64) void {
    const positions = positions_opt orelse return;
    if (positions.len == 0) return;
    const idx: usize = @intCast(frame_index % positions.len);
    const pos = positions[idx];
    const style_id = dest.get(pos.x, pos.y).style;
    setAsciiCell(dest, pos.x, pos.y, '@', style_id);
}

fn applyPanelSwap(dest: *renderer.FrameBuffer, rect: Rect, frame_index: u64) void {
    if (rect.width == 0 or rect.height == 0) return;
    const variant: u8 = @intCast(frame_index % 2);
    renderPanelVariant(dest, rect, variant);
}

fn applyStyleFlicker(dest: *renderer.FrameBuffer, style_ids: []const renderer.Style.Id, frame_index: u64) void {
    if (style_ids.len == 0) return;
    const width = dest.width;
    const height = dest.height;
    if (width == 0 or height == 0) return;

    const offset: usize = @intCast(frame_index % style_ids.len);
    const row_len: usize = @as(usize, width);
    var y: u16 = 0;
    while (y < height) : (y += 1) {
        const row_start: usize = @as(usize, y) * row_len;
        var x: u16 = 0;
        while (x < width) : (x += 1) {
            const idx: usize = (@as(usize, x) + @as(usize, y) + offset) % style_ids.len;
            dest.cells[row_start + @as(usize, x)].style = style_ids[idx];
        }
    }
}

fn clearWideEndNeighbor(buffer: *renderer.FrameBuffer, x: u16, y: u16) void {
    const next_x: u16 = x + 1;
    if (next_x >= buffer.width) return;
    const neighbor = buffer.get(next_x, y);
    if (neighbor.width != .wide_end) return;
    setAsciiCell(buffer, next_x, y, ' ', neighbor.style);
}

fn applyUnicodeWidthChurn(dest: *renderer.FrameBuffer, rect: Rect, seed: u64, frame_index: u64) void {
    if (rect.width < 2 or rect.height == 0) return;

    const width = dest.width;
    const height = dest.height;
    if (width == 0 or height == 0) return;

    const frame_rect = computeFrameRect(width, height, rect.width, rect.height, seed, frame_index);
    if (frame_rect.width < 2 or frame_rect.height == 0) return;

    const x_end_u32: u32 = @min(@as(u32, frame_rect.x) + frame_rect.width, @as(u32, width));
    const y_end_u32: u32 = @min(@as(u32, frame_rect.y) + frame_rect.height, @as(u32, height));
    const x_end: u16 = @intCast(x_end_u32);
    const y_end: u16 = @intCast(y_end_u32);

    if (x_end <= frame_rect.x or y_end <= frame_rect.y) return;

    const wide_ratio: u16 = if ((frame_index & 1) == 0) 20 else 70;
    const update_chance: u16 = 35;
    const mix_seed = seed ^ (frame_index *% 0x9e3779b97f4a7c15) ^ (@as(u64, frame_rect.x) << 32) ^ @as(u64, frame_rect.y);
    var prng = rng.init(mix_seed);
    const random = prng.random();

    var y: u16 = frame_rect.y;
    while (y < y_end) : (y += 1) {
        var x: u16 = frame_rect.x;
        while (x < x_end) {
            if (random.intRangeLessThan(u16, 0, 100) >= update_chance) {
                x += 1;
                continue;
            }

            const existing = dest.get(x, y);
            const style_id = existing.style;
            const pick_wide = random.intRangeLessThan(u16, 0, 100) < wide_ratio;
            if (pick_wide and x + 1 < x_end) {
                const idx = random.intRangeLessThan(usize, 0, rect_wide_glyphs.len);
                setWideCell(dest, x, y, rect_wide_glyphs[idx], style_id);
                setWideEnd(dest, x + 1, y, style_id);
                x += 2;
                continue;
            }

            const idx = random.intRangeLessThan(usize, 0, rect_narrow_glyphs.len);
            if (existing.width == .wide_start) {
                clearWideEndNeighbor(dest, x, y);
            }
            setCodepointCell(dest, x, y, rect_narrow_glyphs[idx], style_id);
            x += 1;
        }
    }
}

const rect_narrow_glyphs = [_]u21{
    0x03B1, // α
    0x03B2, // β
    0x03B3, // γ
    0x03B4, // δ
    0x2605, // ★
    0x25C6, // ◆
    0x2500, // ─
    0x2502, // │
    0x2591, // ░
    0x2592, // ▒
    0x2593, // ▓
    'a',
    'b',
    'c',
    '1',
    '2',
    '3',
};

const rect_wide_glyphs = [_]u21{
    0x4E2D, // 中
    0x6587, // 文
    0x5B57, // 字
    0x1F525, // 🔥
    0x1F680, // 🚀
    0x1F4A5, // 💥
    0x1F9E8, // 🧨
    0x2728, // ✨
};

fn applyRectChurn(
    dest: *renderer.FrameBuffer,
    rect: Rect,
    style_ids: []const renderer.Style.Id,
    seed: u64,
    frame_index: u64,
) void {
    if (rect.width == 0 or rect.height == 0) return;
    if (dest.width == 0 or dest.height == 0) return;

    const frame_rect = computeFrameRect(dest.width, dest.height, rect.width, rect.height, seed ^ 0x3c79ac492ba7b653, frame_index);
    if (frame_rect.width == 0 or frame_rect.height == 0) return;

    const x_end_u32: u32 = @min(@as(u32, frame_rect.x) + frame_rect.width, @as(u32, dest.width));
    const y_end_u32: u32 = @min(@as(u32, frame_rect.y) + frame_rect.height, @as(u32, dest.height));
    const x_end: u16 = @intCast(x_end_u32);
    const y_end: u16 = @intCast(y_end_u32);
    if (x_end <= frame_rect.x or y_end <= frame_rect.y) return;

    const mix_seed = seed ^ (frame_index *% 0x9e3779b97f4a7c15);
    var prng = rng.init(mix_seed);
    const random = prng.random();

    const area: u32 = @as(u32, frame_rect.width) * @as(u32, frame_rect.height);
    const rect_count: u16 = if (area < 80) 2 else 4;
    var rect_index: u16 = 0;
    while (rect_index < rect_count) : (rect_index += 1) {
        const max_w: u16 = @max(@as(u16, 4), frame_rect.width / 2);
        const max_h: u16 = @max(@as(u16, 3), frame_rect.height / 2);
        const w = if (frame_rect.width <= 4) frame_rect.width else random.intRangeLessThan(u16, 4, max_w + 1);
        const h = if (frame_rect.height <= 3) frame_rect.height else random.intRangeLessThan(u16, 3, max_h + 1);
        const max_x: u16 = frame_rect.width - w;
        const max_y: u16 = frame_rect.height - h;
        const x0 = frame_rect.x + if (max_x == 0) 0 else random.intRangeLessThan(u16, 0, max_x + 1);
        const y0 = frame_rect.y + if (max_y == 0) 0 else random.intRangeLessThan(u16, 0, max_y + 1);
        const x1 = @min(@as(u16, x0 + w), x_end);
        const y1 = @min(@as(u16, y0 + h), y_end);

        var y: u16 = y0;
        while (y < y1) : (y += 1) {
            var x: u16 = x0;
            while (x < x1) {
                const style_id = if (style_ids.len == 0)
                    renderer.Style.Id.default
                else
                    style_ids[random.intRangeLessThan(usize, 0, style_ids.len)];
                const pick_wide = random.intRangeLessThan(u16, 0, 100) < 40;
                if (pick_wide and x + 1 < x1) {
                    const idx = random.intRangeLessThan(usize, 0, rect_wide_glyphs.len);
                    setWideCell(dest, x, y, rect_wide_glyphs[idx], style_id);
                    setWideEnd(dest, x + 1, y, style_id);
                    x += 2;
                } else {
                    const existing = dest.get(x, y);
                    const idx = random.intRangeLessThan(usize, 0, rect_narrow_glyphs.len);
                    if (existing.width == .wide_start) {
                        clearWideEndNeighbor(dest, x, y);
                    }
                    setCodepointCell(dest, x, y, rect_narrow_glyphs[idx], style_id);
                    x += 1;
                }
            }
        }
    }
}

fn renderPanelVariant(buffer: *renderer.FrameBuffer, rect: Rect, variant: u8) void {
    if (rect.width == 0 or rect.height == 0) return;
    const fill_char: u8 = if (variant == 0) '.' else '=';
    const title: []const u8 = if (variant == 0) "PANEL A" else "PANEL B";

    var y: u16 = 0;
    while (y < rect.height) : (y += 1) {
        var x: u16 = 0;
        while (x < rect.width) : (x += 1) {
            const gx = rect.x + x;
            const gy = rect.y + y;
            const style_id = buffer.get(gx, gy).style;
            setAsciiCell(buffer, gx, gy, fill_char, style_id);
        }
    }

    if (rect.width < 2 or rect.height < 2) return;

    const left = rect.x;
    const right = rect.x + rect.width - 1;
    const top = rect.y;
    const bottom = rect.y + rect.height - 1;

    if (left < right or bottom != top) {
        var x: u16 = left;
        while (x < right) : (x += 1) {
            const style_id = buffer.get(x, top).style;
            setAsciiCell(buffer, x, top, '-', style_id);
            if (bottom != top) {
                const style_id_bottom = buffer.get(x, bottom).style;
                setAsciiCell(buffer, x, bottom, '-', style_id_bottom);
            }
        }
        const style_id_right_top = buffer.get(right, top).style;
        setAsciiCell(buffer, right, top, '-', style_id_right_top);
        if (bottom != top) {
            const style_id_right_bottom = buffer.get(right, bottom).style;
            setAsciiCell(buffer, right, bottom, '-', style_id_right_bottom);
        }
    }

    if (top < bottom or right != left) {
        var y2: u16 = top;
        while (y2 < bottom) : (y2 += 1) {
            const style_id = buffer.get(left, y2).style;
            setAsciiCell(buffer, left, y2, '|', style_id);
            if (right != left) {
                const style_id_right = buffer.get(right, y2).style;
                setAsciiCell(buffer, right, y2, '|', style_id_right);
            }
        }
        const style_id_left_bottom = buffer.get(left, bottom).style;
        setAsciiCell(buffer, left, bottom, '|', style_id_left_bottom);
        if (right != left) {
            const style_id_right_bottom = buffer.get(right, bottom).style;
            setAsciiCell(buffer, right, bottom, '|', style_id_right_bottom);
        }
    }

    const corner_style = buffer.get(left, top).style;
    setAsciiCell(buffer, left, top, '+', corner_style);
    if (right != left) {
        setAsciiCell(buffer, right, top, '+', buffer.get(right, top).style);
    }
    if (bottom != top) {
        setAsciiCell(buffer, left, bottom, '+', buffer.get(left, bottom).style);
        if (right != left) {
            setAsciiCell(buffer, right, bottom, '+', buffer.get(right, bottom).style);
        }
    }

    if (rect.width > 4) {
        var i: usize = 0;
        const max_len: usize = @min(title.len, @as(usize, rect.width - 4));
        while (i < max_len) : (i += 1) {
            const gx = rect.x + 2 + @as(u16, @intCast(i));
            const style_id = buffer.get(gx, rect.y).style;
            setAsciiCell(buffer, gx, rect.y, title[i], style_id);
        }
    }
}

fn setAsciiCell(buffer: *renderer.FrameBuffer, x: u16, y: u16, byte: u8, style_id: renderer.Style.Id) void {
    const cell = renderer.Cell{
        .data = .{ .codepoint = @as(u21, byte) },
        .tag = .codepoint,
        .width = .narrow,
        .style = style_id,
    };
    buffer.set(x, y, cell);
}

fn setCodepointCell(buffer: *renderer.FrameBuffer, x: u16, y: u16, codepoint: u21, style_id: renderer.Style.Id) void {
    const cell = renderer.Cell{
        .data = .{ .codepoint = codepoint },
        .tag = .codepoint,
        .width = .narrow,
        .style = style_id,
    };
    buffer.set(x, y, cell);
}

fn setWideCell(buffer: *renderer.FrameBuffer, x: u16, y: u16, codepoint: u21, style_id: renderer.Style.Id) void {
    const cell = renderer.Cell{
        .data = .{ .codepoint = codepoint },
        .tag = .codepoint,
        .width = .wide_start,
        .style = style_id,
    };
    buffer.set(x, y, cell);
}

fn setWideEnd(buffer: *renderer.FrameBuffer, x: u16, y: u16, style_id: renderer.Style.Id) void {
    buffer.set(x, y, renderer.Cell.initWideEnd(style_id));
}
