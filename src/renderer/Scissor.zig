const std = @import("std");

const stdx = @import("stdx");
const assert = stdx.inlineAssert;

const FrameBuffer = @import("FrameBuffer.zig");
const Cell = @import("root.zig").Cell;
const Style = @import("root.zig").Style;
const GraphemeIterator = @import("unicode").GraphemeIterator;
const Context = @import("Context.zig");
const t = @import("types.zig");
const Position = t.Position;
const UTF8Decoder = @import("unicode").UTF8Decoder;
const getProperty = @import("unicode").getProperty;

const BoundsGlobal = struct {
    left: i32,
    top: i32,
    right: i32,
    bottom: i32,

    inline fn intersect(self: BoundsGlobal, other: BoundsGlobal) ?BoundsGlobal {
        const left = @max(self.left, other.left);
        const top = @max(self.top, other.top);
        const right = @min(self.right, other.right);
        const bottom = @min(self.bottom, other.bottom);
        if (right <= left or bottom <= top) return null;
        return .{ .left = left, .top = top, .right = right, .bottom = bottom };
    }
};

pub const Scissor = @This();

x_global: i17,
y_global: i17,
width_global: u16,
height_global: u16,

x_clip: u16,
y_clip: u16,
width_clip: u16,
height_clip: u16,

buffer: *FrameBuffer,

// initChild creates a child scissor in global space, then clips it to the
// parent's *visible* bounds (parent clip), not just parent logical bounds.
//
// Steps:
// 1) child logical rect:
//      child_pos = parent_pos + (x_offset, y_offset)
//      child_size = (width, height)
// 2) visible rect = intersect(child_logical, parent_clip)
// 3) store visible rect as child-local clip offsets/sizes:
//      x_clip = visible.left - child.left
//      y_clip = visible.top  - child.top
//      width_clip  = visible.right  - visible.left
//      height_clip = visible.bottom - visible.top
//
// If intersection is empty, clip size is 0x0 (child exists logically but
// has no visible pixels/cells).
//
// Example:
// parent logical = [5,15)x[3,9), parent clip = [7,11)x[4,7)
// child logical (offset 1,1 size 8x4) = [6,14)x[4,8)
// intersection = [7,11)x[4,7)
// child clip = (x=1, y=0, w=4, h=3)
pub fn initChild(self: Scissor, x_offset: i17, y_offset: i17, width: u16, height: u16) Scissor {
    self.assertInvariants();

    var child = Scissor{
        .x_global = std.math.add(i17, self.x_global, x_offset) catch unreachable,
        .y_global = std.math.add(i17, self.y_global, y_offset) catch unreachable,
        .width_global = width,
        .height_global = height,
        .x_clip = 0,
        .y_clip = 0,
        .width_clip = 0,
        .height_clip = 0,
        .buffer = self.buffer,
    };

    const child_logical = child.logicalBoundsGlobal();
    const parent_clip = self.clipBoundsGlobal();
    child.setClipFromVisibleBounds(child_logical.intersect(parent_clip));

    child.assertInvariants();
    return child;
}

pub fn inner(self: Scissor) Scissor {
    self.assertInvariants();
    if (self.width_global < 2 or self.height_global < 2) {
        @branchHint(.unlikely);
        return self.initChild(0, 0, 0, 0);
    }
    return self.initChild(1, 1, self.width_global - 2, self.height_global - 2);
}

/// Intersects only the visible clip regions of two scissors.
///
/// The returned scissor preserves `self` logical bounds (`x_global`, `y_global`,
/// `width_global`, `height_global`) and only narrows the clip fields.
pub fn intersect(self: Scissor, other: Scissor) Scissor {
    assert(self.buffer == other.buffer);
    self.assertInvariants();
    other.assertInvariants();

    const self_clip = self.clipBoundsGlobal();
    const other_clip = other.clipBoundsGlobal();

    var clipped = self;
    clipped.setClipFromVisibleBounds(self_clip.intersect(other_clip));

    clipped.assertInvariants();
    return clipped;
}

/// Get cell at `x,y` in scissor's visible region.
///
/// This is slow due to extensive checks for out-of-bounds.
pub fn get(self: Scissor, x: u16, y: u16) ?Cell {
    self.assertInvariants();
    if (x >= self.width_global or y >= self.height_global) return null;
    const visible = clampedVisibleBoundsGlobal(self) orelse return null;

    const global_x: i32 = @as(i32, self.x_global) + @as(i32, x);
    const global_y: i32 = @as(i32, self.y_global) + @as(i32, y);
    if (global_x < visible.left or global_x >= visible.right or global_y < visible.top or global_y >= visible.bottom) return null;

    return self.buffer.get(@intCast(global_x), @intCast(global_y));
}

pub const SetError = error{
    OutOfBoundsLogical,
    OutOfBoundsVisible,
    InvalidWideEnd,
    WideStartWouldClip,
};

/// Set cell at `x,y` in scissor's visible region.
///
/// This is slow due to extensive checks for out-of-bounds.
pub fn set(self: Scissor, x: u16, y: u16, cell: Cell) SetError!void {
    self.assertInvariants();
    if (x >= self.width_global or y >= self.height_global) return error.OutOfBoundsLogical;
    const visible = clampedVisibleBoundsGlobal(self) orelse return error.OutOfBoundsVisible;

    const global_x: i32 = @as(i32, self.x_global) + @as(i32, x);
    const global_y: i32 = @as(i32, self.y_global) + @as(i32, y);
    if (global_x < visible.left or global_x >= visible.right or global_y < visible.top or global_y >= visible.bottom) {
        return error.OutOfBoundsVisible;
    }

    if (cell.width == .wide_end) return error.InvalidWideEnd;

    const buffer_x: u16 = @intCast(global_x);
    const buffer_y: u16 = @intCast(global_y);

    if (cell.width == .wide_start) {
        const second_x = global_x + 1;
        if (second_x >= visible.right) return error.WideStartWouldClip;

        const second_buffer_x: u16 = @intCast(second_x);
        self.clearWidePairAt(buffer_x, buffer_y);
        self.clearWidePairAt(second_buffer_x, buffer_y);

        self.buffer.set(buffer_x, buffer_y, cell);
        self.buffer.set(second_buffer_x, buffer_y, .initWideEnd(cell.style));
        return;
    }

    self.clearWidePairAt(buffer_x, buffer_y);
    self.buffer.set(buffer_x, buffer_y, cell);
}

// @TODO maybe add setAssumeBounds and getAssumeBounds for faster access

pub fn globalToVisibleLocal(self: Scissor, x_global: u16, y_global: u16) ?Position {
    self.assertInvariants();
    const visible = clampedVisibleBoundsGlobal(self) orelse return null;
    const x_global_i32: i32 = x_global;
    const y_global_i32: i32 = y_global;
    if (x_global_i32 < visible.left or x_global_i32 >= visible.right or y_global_i32 < visible.top or y_global_i32 >= visible.bottom) {
        return null;
    }

    return .{
        .x = @intCast(x_global_i32 - visible.left),
        .y = @intCast(y_global_i32 - visible.top),
    };
}

pub fn globalToLogicalLocal(self: Scissor, x_global: u16, y_global: u16) ?Position {
    self.assertInvariants();
    if (!self.containsVisible(x_global, y_global)) return null;
    const x_global_i32: i32 = x_global;
    const y_global_i32: i32 = y_global;
    return .{
        .x = @intCast(x_global_i32 - @as(i32, self.x_global)),
        .y = @intCast(y_global_i32 - @as(i32, self.y_global)),
    };
}

pub fn containsLogical(self: Scissor, x: u16, y: u16) bool {
    self.assertInvariants();
    const bounds = self.logicalBoundsGlobal();
    const x_global: i32 = x;
    const y_global: i32 = y;
    return x_global >= bounds.left and y_global >= bounds.top and x_global < bounds.right and y_global < bounds.bottom;
}

pub fn containsVisible(self: Scissor, x: u16, y: u16) bool {
    self.assertInvariants();
    const visible = clampedVisibleBoundsGlobal(self) orelse return false;

    const x_global: i32 = x;
    const y_global: i32 = y;
    return x_global >= visible.left and y_global >= visible.top and x_global < visible.right and y_global < visible.bottom;
}

pub fn fillRowNarrow(self: Scissor, row: u16, cell: Cell) void {
    assert(cell.width == .narrow);
    self.assertInvariants();
    if (row >= self.height_global) return;

    const clip = self.clipBoundsGlobal();
    const x_start_int: i32 = @max(clip.left, 0);
    const x_end_int: i32 = @min(clip.right, @as(i32, self.buffer.width));
    if (x_end_int <= x_start_int) return;

    const y_int: i32 = @as(i32, self.y_global) + @as(i32, row);
    if (y_int < clip.top or y_int >= clip.bottom) return;
    if (y_int < 0 or y_int >= @as(i32, self.buffer.height)) return;

    const x_start: usize = @intCast(x_start_int);
    const x_end: usize = @intCast(x_end_int);
    const y: usize = @intCast(y_int);
    const buffer_width: usize = self.buffer.width;

    const start: usize = y * buffer_width + x_start;
    const end: usize = y * buffer_width + x_end;
    @memset(self.buffer.cells[start..end], cell);
}

pub fn fillColumnNarrow(self: Scissor, column: u16, cell: Cell) void {
    assert(cell.width == .narrow);
    self.assertInvariants();
    if (column >= self.width_global) return;
    const clip = self.clipBoundsGlobal();
    const y_start_int: i32 = @max(clip.top, 0);
    const y_end_int: i32 = @min(clip.bottom, @as(i32, self.buffer.height));
    if (y_end_int <= y_start_int) return;

    const x_int: i32 = @as(i32, self.x_global) + @as(i32, column);
    if (x_int < clip.left or x_int >= clip.right) return;
    if (x_int < 0 or x_int >= @as(i32, self.buffer.width)) return;

    const y_start: usize = @intCast(y_start_int);
    const y_end: usize = @intCast(y_end_int);
    const x: u16 = @intCast(x_int);

    for (y_start..y_end) |row| {
        @call(.always_inline, FrameBuffer.set, .{ self.buffer, x, @as(u16, @intCast(row)), cell });
    }
}

pub fn fillRectangleNarrow(self: Scissor, x_offset: u16, y_offset: u16, width: u16, height: u16, cell: Cell) void {
    assert(cell.width == .narrow);
    self.assertInvariants();
    if (x_offset >= self.width_global or y_offset >= self.height_global) return;
    if (width == 0 or height == 0) return;

    const clip = self.clipBoundsGlobal();
    const clip_left: i32 = @max(clip.left, 0);
    const clip_top: i32 = @max(clip.top, 0);
    const clip_right: i32 = @min(clip.right, @as(i32, self.buffer.width));
    const clip_bottom: i32 = @min(clip.bottom, @as(i32, self.buffer.height));
    if (clip_right <= clip_left or clip_bottom <= clip_top) return;

    const rect_left: i32 = @as(i32, self.x_global) + @as(i32, x_offset);
    const rect_top: i32 = @as(i32, self.y_global) + @as(i32, y_offset);
    const rect_right: i32 = rect_left + @as(i32, width);
    const rect_bottom: i32 = rect_top + @as(i32, height);

    const start_x_int: i32 = @max(rect_left, clip_left);
    const end_x_int: i32 = @min(rect_right, clip_right);
    const start_y_int: i32 = @max(rect_top, clip_top);
    const end_y_int: i32 = @min(rect_bottom, clip_bottom);
    if (end_x_int <= start_x_int or end_y_int <= start_y_int) return;

    const start_x: usize = @intCast(start_x_int);
    const end_x: usize = @intCast(end_x_int);
    const start_y: usize = @intCast(start_y_int);
    const end_y: usize = @intCast(end_y_int);
    const buffer_width: usize = self.buffer.width;

    if (start_x == 0 and end_x == buffer_width) {
        const start = start_y * buffer_width;
        const end = end_y * buffer_width;
        @memset(self.buffer.cells[start..end], cell);
    } else {
        for (start_y..end_y) |row| {
            const start = row * buffer_width;
            @memset(self.buffer.cells[start + start_x .. start + end_x], cell);
        }
    }
}

pub fn fillNarrow(self: Scissor, cell: Cell) void {
    self.fillRectangleNarrow(0, 0, self.width_global, self.height_global, cell);
}

pub fn clear(self: Scissor) void {
    self.fillNarrow(.empty);
}

/// Statistics returned after rendering text.
pub const PrintResult = struct {
    /// Total UTF-8 bytes processed from input
    bytes_consumed: usize,
    /// Number of lines used (including wraps and newlines)
    /// Minimum 1 if any content rendered, 0 if nothing rendered
    lines_used: u16,
    /// Final cursor X position relative to scissor
    final_x: u16,
    /// Final cursor Y position relative to scissor
    final_y: u16,
    /// Number of grapheme clusters actually rendered to buffer
    graphemes_rendered: usize,
};

/// Configuration options for print behavior.
pub const PrintOptions = struct {
    /// Enable text wrapping at scissor's right edge
    /// When false: text truncates at right edge
    wrap: bool = false,
    /// Number of spaces per tab character
    /// Tab stop: advance to next multiple of tab_width
    tab_width: u8 = 4,
    /// Style for text
    style: Style.Id = .default,

    pub const default: PrintOptions = .{
        .wrap = false,
        .tab_width = 4,
        .style = .default,
    };
};

pub const PrintError = error{OutOfMemory};

pub fn print(
    self: Scissor,
    codepoint_buffer: []u21,
    text: []const u8,
    x: u16,
    y: u16,
    options: PrintOptions,
) PrintError!PrintResult {
    self.assertInvariants();
    var result = PrintResult{
        .bytes_consumed = 0,
        .lines_used = 0,
        .final_x = x,
        .final_y = y,
        .graphemes_rendered = 0,
    };

    const bound = clampedVisibleBoundsGlobal(self) orelse return result;

    var cursor_x: u16 = x;
    var cursor_y: u16 = y;

    var iter = GraphemeIterator.init(text); // Empty input, return zeros

    while (iter.next(codepoint_buffer)) |grapheme_result| : (cursor_x += grapheme_result.width) {
        result.bytes_consumed += grapheme_result.bytes.len;
        if (cursor_x >= self.width_global) {
            if (options.wrap) {
                // Wrap to next line before rendering the wide char
                cursor_x = 0;
                cursor_y += 1;
                result.lines_used += 1;
            } else {
                // No wrap: stop rendering
                break;
            }
        }

        const codepoint = grapheme_result.grapheme[0];

        switch (codepoint) {
            '\n' => {
                cursor_x = 0;
                cursor_y += 1;
                result.lines_used += 1;
                continue;
            },
            '\r' => {
                if (grapheme_result.grapheme.len == 2 and grapheme_result.grapheme[1] == '\n') {
                    cursor_x = 0;
                    cursor_y += 1;
                    result.lines_used += 1;
                    continue;
                } else {
                    // Ignore \r (carriage return)
                    continue;
                }
            },
            '\t' => {
                var spaces_to_tab: u8 = if (options.tab_width == 0)
                    continue
                else
                    options.tab_width - @as(u8, @intCast(@mod(cursor_x, options.tab_width)));

                const y_global: i32 = @as(i32, self.y_global) + @as(i32, cursor_y);

                if (y_global >= bound.bottom) {
                    break;
                }
                const remaining_columns = self.width_global - cursor_x;
                spaces_to_tab = @min(remaining_columns, spaces_to_tab);

                for (0..spaces_to_tab) |_| {
                    const x_global: i32 = @as(i32, self.x_global) + @as(i32, cursor_x);

                    if (x_global >= bound.left and x_global < bound.right and
                        y_global >= bound.top and y_global < bound.bottom)
                    {
                        self.buffer.set(@intCast(x_global), @intCast(y_global), .empty);
                        result.graphemes_rendered += 1;
                    }
                    cursor_x += 1;
                }
                continue;
            },
            else => {
                @branchHint(.likely);
            },
        }

        if (grapheme_result.width == 0) {
            continue;
        } else if (grapheme_result.width == 2 and self.width_global - cursor_x == 1) {
            @branchHint(.unlikely);
            if (options.wrap) {
                cursor_x = 0;
                cursor_y += 1;
                result.lines_used += 1;
            } else {
                // ignore the wide character.
                continue;
            }
        }

        const x_global: i32 = @as(i32, self.x_global) + @as(i32, cursor_x);
        const y_global: i32 = @as(i32, self.y_global) + @as(i32, cursor_y);

        if (x_global < bound.left or x_global >= bound.right or y_global < bound.top) {
            @branchHint(.unlikely);
            continue;
        }
        if (grapheme_result.width == 2 and x_global + 1 >= bound.right) {
            @branchHint(.unlikely);
            continue;
        }
        if (y_global >= bound.bottom) {
            @branchHint(.unlikely);
            break;
        }

        const cell: Cell = if (grapheme_result.grapheme.len > 1) blk: {
            @branchHint(.unlikely);
            const id = try self.buffer.grapheme_buffer.put(grapheme_result.bytes);
            break :blk Cell.initGrapheme(id, if (grapheme_result.width == 2) .wide_start else .narrow, options.style);
        } else .{
            .data = .{ .codepoint = codepoint },
            .tag = .codepoint,
            .width = if (grapheme_result.width == 2) .wide_start else .narrow,
            .style = options.style,
        };

        self.buffer.set(@intCast(x_global), @intCast(y_global), cell);

        if (grapheme_result.width == 2) {
            const second_x: i32 = x_global + 1;
            assert(second_x < bound.right);
            self.buffer.set(@intCast(second_x), @intCast(y_global), .initWideEnd(options.style));
        }

        result.graphemes_rendered += 1;
    }

    // Finalize result
    if (cursor_x >= self.width_global) {
        cursor_x = 0;
        cursor_y += 1;
    }
    result.final_x = cursor_x;
    result.final_y = cursor_y;
    // lines_used tracks wraps during the loop; add 1 for the initial line if we rendered anything
    if (result.graphemes_rendered > 0) {
        result.lines_used += 1;
        const y_global: i32 = @as(i32, self.y_global) + @as(i32, cursor_y);
        if (y_global >= bound.bottom) {
            result.lines_used -= 1;
        }
    }

    return result;
}

/// IMPORTANT: Caller guarantees text contains only single-codepoint characters.
/// Multi-codepoint graphemes (combining marks, emoji sequences, ZWJ) will render
/// incorrectly - use `Scissor.print()` for arbitrary Unicode text.
///
/// This is usually about 2x faster than `Scissor.print()` for simple text.
pub fn printAssumeNoGrapheme(
    self: Scissor,
    text: []const u8,
    x: u16,
    y: u16,
    options: PrintOptions,
) PrintResult {
    self.assertInvariants();
    var result = PrintResult{
        .bytes_consumed = 0,
        .lines_used = 0,
        .final_x = x,
        .final_y = y,
        .graphemes_rendered = 0,
    };

    const bound = clampedVisibleBoundsGlobal(self) orelse return result;

    var cursor_x: u16 = x;
    var cursor_y: u16 = y;

    var utf8: UTF8Decoder = .start;
    var i: usize = 0;

    while (i < text.len) {
        const codepoint_opt, const consumed = utf8.decode(text[i]);

        // Handle invalid UTF-8
        const codepoint = if (!consumed) blk: {
            @branchHint(.unlikely);
            assert(codepoint_opt != null and codepoint_opt.? == 0xFFFD);
            // Don't increment bytes_consumed here - the byte wasn't consumed.
            // The replacement character is for the incomplete sequence, and
            // this byte will be re-processed as the start of a new sequence.
            break :blk @as(u21, 0xFFFD);
        } else blk: {
            i += 1;
            result.bytes_consumed += 1;
            if (codepoint_opt) |cp| {
                break :blk cp;
            } else {
                continue;
            }
        };

        if (cursor_x >= self.width_global) {
            if (options.wrap) {
                // Wrap to next line before rendering the wide char
                cursor_x = 0;
                cursor_y += 1;
                result.lines_used += 1;
            } else {
                // No wrap: stop rendering
                break;
            }
        }

        switch (codepoint) {
            '\n' => {
                cursor_x = 0;
                cursor_y += 1;
                result.lines_used += 1;
                continue;
            },
            '\t' => {
                var spaces_to_tab: u8 = if (options.tab_width == 0)
                    continue
                else
                    options.tab_width - @as(u8, @intCast(@mod(cursor_x, options.tab_width)));

                const y_global: i32 = @as(i32, self.y_global) + @as(i32, cursor_y);

                if (y_global >= bound.bottom) {
                    break;
                }
                const remaining_columns = self.width_global - cursor_x;
                spaces_to_tab = @min(remaining_columns, spaces_to_tab);

                for (0..spaces_to_tab) |_| {
                    const x_global: i32 = @as(i32, self.x_global) + @as(i32, cursor_x);

                    if (x_global >= bound.left and x_global < bound.right and
                        y_global >= bound.top and y_global < bound.bottom)
                    {
                        self.buffer.set(@intCast(x_global), @intCast(y_global), .empty);
                        result.graphemes_rendered += 1;
                    }
                    cursor_x += 1;
                }
                continue;
            },
            0x00...0x08, // Except \t
            0x0B...0x0C,
            0x0E...0x1F, // C0 except LF (0x0A)
            0x0D, // CR
            0x7F, // DEL
            0x80...0x9F, // C1
            => {
                continue;
            },
            else => {
                @branchHint(.likely);
            },
        }

        // Most commanly you will have ascii text that is 1 cell wide.
        const width = if (codepoint <= 0x7F) 1 else getProperty(codepoint).width;

        if (width == 0) {
            continue;
        } else if (width == 2 and self.width_global - cursor_x == 1) {
            @branchHint(.unlikely);
            if (options.wrap) {
                cursor_x = 0;
                cursor_y += 1;
                result.lines_used += 1;
            } else {
                // ignore the wide character.
                cursor_x += width;
                continue;
            }
        }

        const x_global: i32 = @as(i32, self.x_global) + @as(i32, cursor_x);
        const y_global: i32 = @as(i32, self.y_global) + @as(i32, cursor_y);

        if (x_global < bound.left or x_global >= bound.right or y_global < bound.top) {
            @branchHint(.unlikely);
            cursor_x += width;
            continue;
        }
        if (width == 2 and x_global + 1 >= bound.right) {
            @branchHint(.unlikely);
            cursor_x += width;
            continue;
        }
        if (y_global >= bound.bottom) {
            @branchHint(.unlikely);
            break;
        }

        const cell = Cell{
            .data = .{ .codepoint = codepoint },
            .tag = .codepoint,
            .width = if (width == 2) .wide_start else .narrow,
            .style = options.style,
        };

        self.buffer.set(@intCast(x_global), @intCast(y_global), cell);

        if (width == 2) {
            const second_x: i32 = x_global + 1;
            assert(second_x < bound.right);
            self.buffer.set(@intCast(second_x), @intCast(y_global), .initWideEnd(options.style));
        }

        result.graphemes_rendered += 1;
        cursor_x += width;
    }

    // Finalize result
    if (cursor_x >= self.width_global) {
        cursor_x = 0;
        cursor_y += 1;
    }
    result.final_x = cursor_x;
    result.final_y = cursor_y;
    result.bytes_consumed = i;
    // lines_used tracks wraps during the loop; add 1 for the initial line if we rendered anything
    if (result.graphemes_rendered > 0) {
        result.lines_used += 1;
        const y_global: i32 = @as(i32, self.y_global) + @as(i32, cursor_y);
        if (y_global >= bound.bottom) {
            result.lines_used -= 1;
        }
    }

    return result;
}

inline fn clampedVisibleBoundsGlobal(self: Scissor) ?BoundsGlobal {
    const clip = self.clipBoundsGlobal();
    const left: i32 = @max(clip.left, 0);
    const top: i32 = @max(clip.top, 0);
    const right: i32 = @min(clip.right, @as(i32, self.buffer.width));
    const bottom: i32 = @min(clip.bottom, @as(i32, self.buffer.height));
    if (right <= left or bottom <= top) return null;
    return .{
        .left = left,
        .top = top,
        .right = right,
        .bottom = bottom,
    };
}

inline fn clearWidePairAt(self: Scissor, x: u16, y: u16) void {
    const existing = self.buffer.get(x, y);
    switch (existing.width) {
        .narrow => {},
        .wide_start => {
            self.buffer.set(x, y, .empty);
            const next_x, const overflow = @addWithOverflow(x, @as(u16, 1));
            if (overflow == 0 and next_x < self.buffer.width) {
                const next_cell = self.buffer.get(next_x, y);
                if (next_cell.width == .wide_end) {
                    self.buffer.set(next_x, y, .empty);
                }
            }
        },
        .wide_end => {
            self.buffer.set(x, y, .empty);
            if (x > 0) {
                const prev_x = x - 1;
                const prev_cell = self.buffer.get(prev_x, y);
                if (prev_cell.width == .wide_start) {
                    self.buffer.set(prev_x, y, .empty);
                }
            }
        },
    }
}

inline fn assertInvariants(self: Scissor) void {
    assert(self.x_clip <= self.width_global);
    assert(self.y_clip <= self.height_global);
    assert(self.width_clip <= self.width_global - self.x_clip);
    assert(self.height_clip <= self.height_global - self.y_clip);
}

inline fn logicalBoundsGlobal(self: Scissor) BoundsGlobal {
    return .{
        .left = self.x_global,
        .top = self.y_global,
        .right = @as(i32, self.x_global) + self.width_global,
        .bottom = @as(i32, self.y_global) + self.height_global,
    };
}

inline fn clipBoundsGlobal(self: Scissor) BoundsGlobal {
    return .{
        .left = @as(i32, self.x_global) + self.x_clip,
        .top = @as(i32, self.y_global) + self.y_clip,
        .right = @as(i32, self.x_global) + self.x_clip + self.width_clip,
        .bottom = @as(i32, self.y_global) + self.y_clip + self.height_clip,
    };
}

inline fn setClipFromVisibleBounds(self: *Scissor, visible: ?BoundsGlobal) void {
    self.x_clip = 0;
    self.y_clip = 0;
    self.width_clip = 0;
    self.height_clip = 0;

    const bounds = visible orelse return;
    const logical = self.logicalBoundsGlobal();
    self.x_clip = @intCast(bounds.left - logical.left);
    self.y_clip = @intCast(bounds.top - logical.top);
    self.width_clip = @intCast(bounds.right - bounds.left);
    self.height_clip = @intCast(bounds.bottom - bounds.top);
}

const testing = std.testing;

const TestContext = struct {
    buffer: FrameBuffer,
    cells: []Cell,

    var test_codepoint_buffer: [64]u21 = undefined;

    fn init(width: u16, height: u16) !TestContext {
        const cells = try testing.allocator.alloc(Cell, @as(usize, width) * @as(usize, height));
        var buffer = try FrameBuffer.init(cells, width, height, .tiny);
        buffer.clear();
        return .{ .buffer = buffer, .cells = cells };
    }

    fn deinit(self: *TestContext) void {
        self.buffer.deinit();
        testing.allocator.free(self.cells);
    }

    fn scissor(self: *TestContext) Scissor {
        return self.buffer.scissor();
    }

    fn expectCodepointAt(self: *TestContext, x: u16, y: u16, expected_cp: u21) !void {
        const cell = self.buffer.get(x, y);
        try testing.expectEqual(expected_cp, cell.data.codepoint);
    }

    fn expectCellWidth(self: *TestContext, x: u16, y: u16, expected_width: Cell.Width) !void {
        const cell = self.buffer.get(x, y);
        try testing.expectEqual(expected_width, cell.width);
    }

    fn expectCellTag(self: *TestContext, x: u16, y: u16, expected_tag: Cell.Tag) !void {
        const cell = self.buffer.get(x, y);
        try testing.expectEqual(expected_tag, cell.tag);
    }

    fn getGraphemeAt(self: *TestContext, x: u16, y: u16) ?[]const u8 {
        const cell = self.buffer.get(x, y);
        if (cell.tag != .grapheme) return null;
        const id: t.GraphemeBuffer.GraphemeIndex = @truncate(@as(u64, @bitCast(cell)));
        return self.buffer.grapheme_buffer.get(id);
    }
};

test "Scissor.initChild" {
    const cells = try testing.allocator.alloc(Cell, 200);
    defer testing.allocator.free(cells);
    var fb = try FrameBuffer.init(cells, 20, 10, .tiny);
    defer fb.deinit();

    const ScissorTestCase = struct {
        parent: Scissor,
        init: struct { x: i17, y: i17, width: u16, height: u16 },
        expected: Scissor,
    };

    const test_cases: []const ScissorTestCase = &.{
        // creates correct child region
        .{
            .parent = Scissor{
                .x_global = 5,
                .y_global = 3,
                .width_global = 15,
                .height_global = 7,
                .x_clip = 0,
                .y_clip = 0,
                .width_clip = 15,
                .height_clip = 7,
                .buffer = &fb,
            },
            .init = .{ .x = 2, .y = 1, .width = 10, .height = 4 },
            .expected = .{
                .x_global = 7,
                .y_global = 4,
                .width_global = 10,
                .height_global = 4,
                .x_clip = 0,
                .y_clip = 0,
                .width_clip = 10,
                .height_clip = 4,
                .buffer = &fb,
            },
        },
        //clips to parent visible bounds
        .{
            .parent = Scissor{
                .x_global = 5,
                .y_global = 3,
                .width_global = 10,
                .height_global = 6,
                .x_clip = 2,
                .y_clip = 1,
                .width_clip = 4,
                .height_clip = 3,
                .buffer = &fb,
            },
            .init = .{ .x = 1, .y = 1, .width = 8, .height = 4 },
            .expected = Scissor{
                .x_global = 6,
                .y_global = 4,
                .width_global = 8,
                .height_global = 4,
                .x_clip = 1,
                .y_clip = 0,
                .width_clip = 4,
                .height_clip = 3,
                .buffer = &fb,
            },
        },
        // handles partially off-screen top-left
        .{
            .parent = fb.scissor(),
            .init = .{ .x = -5, .y = -3, .width = 10, .height = 8 },
            .expected = Scissor{
                .x_global = -5,
                .y_global = -3,
                .width_global = 10,
                .height_global = 8,
                .x_clip = 5,
                .y_clip = 3,
                .width_clip = 5,
                .height_clip = 5,
                .buffer = &fb,
            },
        },
        .{
            .parent = fb.scissor(),
            .init = .{ .x = -100, .y = -100, .width = 50, .height = 50 },
            .expected = Scissor{
                .x_global = -100,
                .y_global = -100,
                .width_global = 50,
                .height_global = 50,
                .x_clip = 0,
                .y_clip = 0,
                .width_clip = 0,
                .height_clip = 0,
                .buffer = &fb,
            },
        },
    };

    for (test_cases) |case| {
        const child = case.parent.initChild(case.init.x, case.init.y, case.init.width, case.init.height);
        try testing.expectEqual(case.expected, child);
    }
}

test "Scissor.intersect clips only visible region" {
    const cells = try testing.allocator.alloc(Cell, 200);
    defer testing.allocator.free(cells);
    var fb = try FrameBuffer.init(cells, 20, 10, .tiny);
    defer fb.deinit();

    const lhs = Scissor{
        .x_global = 2,
        .y_global = 2,
        .width_global = 10,
        .height_global = 6,
        .x_clip = 1,
        .y_clip = 1,
        .width_clip = 6,
        .height_clip = 4,
        .buffer = &fb,
    };
    const rhs = Scissor{
        .x_global = 5,
        .y_global = 1,
        .width_global = 8,
        .height_global = 6,
        .x_clip = 0,
        .y_clip = 2,
        .width_clip = 5,
        .height_clip = 3,
        .buffer = &fb,
    };

    const clipped = lhs.intersect(rhs);

    try testing.expectEqual(Scissor{
        .x_global = 2,
        .y_global = 2,
        .width_global = 10,
        .height_global = 6,
        .x_clip = 3,
        .y_clip = 1,
        .width_clip = 4,
        .height_clip = 3,
        .buffer = &fb,
    }, clipped);

    const disjoint = Scissor{
        .x_global = 0,
        .y_global = 0,
        .width_global = 2,
        .height_global = 2,
        .x_clip = 0,
        .y_clip = 0,
        .width_clip = 2,
        .height_clip = 2,
        .buffer = &fb,
    };
    const empty_clip = lhs.intersect(disjoint);
    try testing.expectEqual(Scissor{
        .x_global = 2,
        .y_global = 2,
        .width_global = 10,
        .height_global = 6,
        .x_clip = 0,
        .y_clip = 0,
        .width_clip = 0,
        .height_clip = 0,
        .buffer = &fb,
    }, empty_clip);
}

test "Scissor.fillRectangle clips to buffer bounds" {
    const cells = try testing.allocator.alloc(Cell, 50);
    defer testing.allocator.free(cells);
    var fb = try FrameBuffer.init(cells, 10, 5, .tiny);
    defer fb.deinit();

    fb.clear();

    const scissor = Scissor{
        .x_global = 0,
        .y_global = 0,
        .width_global = 10,
        .height_global = 5,
        .x_clip = 0,
        .y_clip = 0,
        .width_clip = 10,
        .height_clip = 5,
        .buffer = &fb,
    };

    scissor.fillRectangleNarrow(8, 3, 5, 5, Cell{ .data = .{ .codepoint = '+' } });

    for (0..5) |y| {
        for (0..10) |x| {
            const expected: u21 = if (x >= 8 and y >= 3) '+' else ' ';
            try std.testing.expectEqual(expected, fb.cells[y * 10 + x].data.codepoint);
        }
    }
}

test "print basic ASCII" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "Hello", 0, 0, .default);

    try testing.expectEqual(@as(usize, 5), result.bytes_consumed);
    try testing.expectEqual(@as(u16, 1), result.lines_used);
    try testing.expectEqual(@as(u16, 5), result.final_x);
    try testing.expectEqual(@as(u16, 0), result.final_y);
    try testing.expectEqual(@as(usize, 5), result.graphemes_rendered);
    try tc.expectCodepointAt(0, 0, 'H');
    try tc.expectCodepointAt(1, 0, 'e');
    try tc.expectCodepointAt(2, 0, 'l');
    try tc.expectCodepointAt(3, 0, 'l');
    try tc.expectCodepointAt(4, 0, 'o');
    try tc.expectCellWidth(0, 0, .narrow);
    try tc.expectCellWidth(4, 0, .narrow);

    // Also verify printAssumeNoGrapheme
    tc.buffer.clear();
    const result2 = printAssumeNoGrapheme(tc.scissor(), "Hello", 0, 0, .default);
    try testing.expectEqual(@as(usize, 5), result2.bytes_consumed);
    try testing.expectEqual(@as(u16, 1), result2.lines_used);
    try testing.expectEqual(@as(u16, 5), result2.final_x);
    try testing.expectEqual(@as(u16, 0), result2.final_y);
    try testing.expectEqual(@as(usize, 5), result2.graphemes_rendered);
    try tc.expectCodepointAt(0, 0, 'H');
    try tc.expectCodepointAt(4, 0, 'o');
    try tc.expectCellWidth(0, 0, .narrow);
    try tc.expectCellWidth(4, 0, .narrow);
}

test "print ASCII with offset" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "Hi", 3, 2, .default);

    try testing.expectEqual(@as(usize, 2), result.bytes_consumed);
    try testing.expectEqual(@as(u16, 5), result.final_x);
    try testing.expectEqual(@as(u16, 2), result.final_y);

    // Cells at offset should be set
    try tc.expectCodepointAt(3, 2, 'H');
    try tc.expectCodepointAt(4, 2, 'i');

    // Original cells should still be space
    try tc.expectCodepointAt(0, 0, ' ');
    try tc.expectCodepointAt(2, 2, ' ');

    // Also verify printAssumeNoGrapheme
    tc.buffer.clear();
    const result2 = printAssumeNoGrapheme(tc.scissor(), "Hi", 3, 2, .default);
    try testing.expectEqual(@as(usize, 2), result2.bytes_consumed);
    try testing.expectEqual(@as(u16, 5), result2.final_x);
    try testing.expectEqual(@as(u16, 2), result2.final_y);
    try tc.expectCodepointAt(3, 2, 'H');
    try tc.expectCodepointAt(4, 2, 'i');
    try tc.expectCodepointAt(0, 0, ' ');
    try tc.expectCodepointAt(2, 2, ' ');
}

test "print ASCII truncates at right edge" {
    var tc = try TestContext.init(5, 5);
    defer tc.deinit();

    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "Hello World", 0, 0, .default);

    // Should only render "Hello" (5 chars)
    try testing.expectEqual(@as(usize, 5), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 1), result.lines_used);

    try tc.expectCodepointAt(0, 0, 'H');
    try tc.expectCodepointAt(1, 0, 'e');
    try tc.expectCodepointAt(2, 0, 'l');
    try tc.expectCodepointAt(3, 0, 'l');
    try tc.expectCodepointAt(4, 0, 'o');

    // Also verify printAssumeNoGrapheme
    tc.buffer.clear();
    const result2 = printAssumeNoGrapheme(tc.scissor(), "Hello World", 0, 0, .default);
    try testing.expectEqual(@as(usize, 5), result2.graphemes_rendered);
    try testing.expectEqual(@as(u16, 1), result2.lines_used);
    try tc.expectCodepointAt(0, 0, 'H');
    try tc.expectCodepointAt(4, 0, 'o');
}

test "print empty string" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "", 0, 0, .default);

    try testing.expectEqual(@as(usize, 0), result.bytes_consumed);
    try testing.expectEqual(@as(u16, 0), result.lines_used);
    try testing.expectEqual(@as(usize, 0), result.graphemes_rendered);
}

test "print outside buffer returns early" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    // Start below the buffer
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "Hello", 0, 10, .default);

    try testing.expectEqual(@as(usize, 0), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 0), result.lines_used);

    // Also verify printAssumeNoGrapheme
    const result2 = printAssumeNoGrapheme(tc.scissor(), "Hello", 0, 10, .default);
    try testing.expectEqual(@as(usize, 0), result2.graphemes_rendered);
    try testing.expectEqual(@as(u16, 0), result2.lines_used);
}

test "print starting past right edge" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "Hello", 15, 0, .default);

    try testing.expectEqual(@as(usize, 0), result.graphemes_rendered);
}

test "print wraps at scissor edge" {
    var tc = try TestContext.init(5, 3);
    defer tc.deinit();

    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "ABCDEFGHIJ", 0, 0, .{ .wrap = true, .tab_width = 4 });

    // Row 0: A B C D E
    // Row 1: F G H I J
    try testing.expectEqual(@as(usize, 10), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 2), result.lines_used);
    try testing.expectEqual(@as(u16, 0), result.final_x);
    try testing.expectEqual(@as(u16, 2), result.final_y);

    // Row 0
    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCodepointAt(1, 0, 'B');
    try tc.expectCodepointAt(2, 0, 'C');
    try tc.expectCodepointAt(3, 0, 'D');
    try tc.expectCodepointAt(4, 0, 'E');

    // Row 1
    try tc.expectCodepointAt(0, 1, 'F');
    try tc.expectCodepointAt(1, 1, 'G');
    try tc.expectCodepointAt(2, 1, 'H');
    try tc.expectCodepointAt(3, 1, 'I');
    try tc.expectCodepointAt(4, 1, 'J');

    // Also verify printAssumeNoGrapheme
    tc.buffer.clear();
    const result2 = printAssumeNoGrapheme(tc.scissor(), "ABCDEFGHIJ", 0, 0, .{ .wrap = true, .tab_width = 4 });
    try testing.expectEqual(@as(usize, 10), result2.graphemes_rendered);
    try testing.expectEqual(@as(u16, 2), result2.lines_used);
    try testing.expectEqual(@as(u16, 0), result2.final_x);
    try testing.expectEqual(@as(u16, 2), result2.final_y);
    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCodepointAt(4, 0, 'E');
    try tc.expectCodepointAt(0, 1, 'F');
    try tc.expectCodepointAt(4, 1, 'J');
}

test "print stops at bottom with wrap" {
    var tc = try TestContext.init(5, 2);
    defer tc.deinit();

    // 15 chars but only 2 rows available (10 cells max)
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "ABCDEFGHIJKLMNO", 0, 0, .{ .wrap = true, .tab_width = 4 });

    // Should only render 10 chars (2 lines of 5)
    try testing.expectEqual(@as(usize, 10), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 2), result.lines_used);

    // Row 0
    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCodepointAt(4, 0, 'E');

    // Row 1
    try tc.expectCodepointAt(0, 1, 'F');
    try tc.expectCodepointAt(4, 1, 'J');

    // Also verify printAssumeNoGrapheme
    tc.buffer.clear();
    const result2 = printAssumeNoGrapheme(tc.scissor(), "ABCDEFGHIJKLMNO", 0, 0, .{ .wrap = true, .tab_width = 4 });
    try testing.expectEqual(@as(usize, 10), result2.graphemes_rendered);
    try testing.expectEqual(@as(u16, 2), result2.lines_used);
    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCodepointAt(4, 0, 'E');
    try tc.expectCodepointAt(0, 1, 'F');
    try tc.expectCodepointAt(4, 1, 'J');
}

test "print wrap disabled truncates" {
    var tc = try TestContext.init(5, 3);
    defer tc.deinit();

    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "Hello World", 0, 0, .{ .wrap = false, .tab_width = 4 });

    // Should only render "Hello" (5 chars)
    try testing.expectEqual(@as(usize, 5), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 1), result.lines_used);

    try tc.expectCodepointAt(0, 0, 'H');
    try tc.expectCodepointAt(4, 0, 'o');

    // Row 1 should still be empty
    try tc.expectCodepointAt(0, 1, ' ');

    // Also verify printAssumeNoGrapheme
    tc.buffer.clear();
    const result2 = printAssumeNoGrapheme(tc.scissor(), "Hello World", 0, 0, .{ .wrap = false, .tab_width = 4 });
    try testing.expectEqual(@as(usize, 5), result2.graphemes_rendered);
    try testing.expectEqual(@as(u16, 1), result2.lines_used);
    try tc.expectCodepointAt(0, 0, 'H');
    try tc.expectCodepointAt(4, 0, 'o');
    try tc.expectCodepointAt(0, 1, ' ');
}

test "print wrap with offset" {
    var tc = try TestContext.init(5, 3);
    defer tc.deinit();

    // Start at x=3, so first line has 2 chars, then wrap
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "ABCDEFG", 3, 0, .{ .wrap = true, .tab_width = 4 });

    // Row 0: _ _ _ A B
    // Row 1: C D E F G
    try testing.expectEqual(@as(usize, 7), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 2), result.lines_used);
    try testing.expectEqual(@as(u16, 0), result.final_x);
    try testing.expectEqual(@as(u16, 2), result.final_y);

    // Row 0
    try tc.expectCodepointAt(3, 0, 'A');
    try tc.expectCodepointAt(4, 0, 'B');

    // Row 1
    try tc.expectCodepointAt(0, 1, 'C');
    try tc.expectCodepointAt(4, 1, 'G');

    // Also verify printAssumeNoGrapheme
    tc.buffer.clear();
    const result2 = printAssumeNoGrapheme(tc.scissor(), "ABCDEFG", 3, 0, .{ .wrap = true, .tab_width = 4 });
    try testing.expectEqual(@as(usize, 7), result2.graphemes_rendered);
    try testing.expectEqual(@as(u16, 2), result2.lines_used);
    try testing.expectEqual(@as(u16, 0), result2.final_x);
    try testing.expectEqual(@as(u16, 2), result2.final_y);
    try tc.expectCodepointAt(3, 0, 'A');
    try tc.expectCodepointAt(4, 0, 'B');
    try tc.expectCodepointAt(0, 1, 'C');
    try tc.expectCodepointAt(4, 1, 'G');
}

test "print multiple wraps" {
    var tc = try TestContext.init(3, 5);
    defer tc.deinit();

    // 9 chars, 3 chars per row, should use 3 rows
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "ABCDEFGHI", 0, 0, .{ .wrap = true, .tab_width = 4 });

    try testing.expectEqual(@as(usize, 9), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 3), result.lines_used);
    try testing.expectEqual(@as(u16, 0), result.final_x);
    try testing.expectEqual(@as(u16, 3), result.final_y);

    // Row 0: A B C
    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCodepointAt(2, 0, 'C');

    // Row 1: D E F
    try tc.expectCodepointAt(0, 1, 'D');
    try tc.expectCodepointAt(2, 1, 'F');

    // Row 2: G H I
    try tc.expectCodepointAt(0, 2, 'G');
    try tc.expectCodepointAt(2, 2, 'I');

    // Also verify printAssumeNoGrapheme
    tc.buffer.clear();
    const result2 = printAssumeNoGrapheme(tc.scissor(), "ABCDEFGHI", 0, 0, .{ .wrap = true, .tab_width = 4 });
    try testing.expectEqual(@as(usize, 9), result2.graphemes_rendered);
    try testing.expectEqual(@as(u16, 3), result2.lines_used);
    try testing.expectEqual(@as(u16, 0), result2.final_x);
    try testing.expectEqual(@as(u16, 3), result2.final_y);
    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCodepointAt(2, 0, 'C');
    try tc.expectCodepointAt(0, 1, 'D');
    try tc.expectCodepointAt(2, 1, 'F');
    try tc.expectCodepointAt(0, 2, 'G');
    try tc.expectCodepointAt(2, 2, 'I');
}

test "print handles newlines" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "AB\nCD", 0, 0, .default);

    // Row 0: A B, Row 1: C D
    try testing.expectEqual(@as(usize, 5), result.bytes_consumed); // "AB\nCD" = 5 bytes
    try testing.expectEqual(@as(u16, 2), result.lines_used);
    try testing.expectEqual(@as(usize, 4), result.graphemes_rendered); // A, B, C, D (newline not rendered)
    try testing.expectEqual(@as(u16, 2), result.final_x);
    try testing.expectEqual(@as(u16, 1), result.final_y);

    // Row 0
    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCodepointAt(1, 0, 'B');

    // Row 1
    try tc.expectCodepointAt(0, 1, 'C');
    try tc.expectCodepointAt(1, 1, 'D');

    // Also verify printAssumeNoGrapheme
    tc.buffer.clear();
    const result2 = printAssumeNoGrapheme(tc.scissor(), "AB\nCD", 0, 0, .default);
    try testing.expectEqual(@as(usize, 5), result2.bytes_consumed);
    try testing.expectEqual(@as(u16, 2), result2.lines_used);
    try testing.expectEqual(@as(usize, 4), result2.graphemes_rendered);
    try testing.expectEqual(@as(u16, 2), result2.final_x);
    try testing.expectEqual(@as(u16, 1), result2.final_y);
    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCodepointAt(1, 0, 'B');
    try tc.expectCodepointAt(0, 1, 'C');
    try tc.expectCodepointAt(1, 1, 'D');
}

test "print multiple consecutive newlines" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "A\n\n\nB", 0, 0, .default);

    // A on row 0, B on row 3
    try testing.expectEqual(@as(usize, 5), result.bytes_consumed);
    try testing.expectEqual(@as(u16, 4), result.lines_used); // 4 lines: 0, 1, 2, 3
    try testing.expectEqual(@as(usize, 2), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 1), result.final_x);
    try testing.expectEqual(@as(u16, 3), result.final_y);

    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCodepointAt(0, 3, 'B');

    // Rows 1 and 2 should be empty
    try tc.expectCodepointAt(0, 1, ' ');
    try tc.expectCodepointAt(0, 2, ' ');

    // Also verify printAssumeNoGrapheme
    tc.buffer.clear();
    const result2 = printAssumeNoGrapheme(tc.scissor(), "A\n\n\nB", 0, 0, .default);
    try testing.expectEqual(@as(usize, 5), result2.bytes_consumed);
    try testing.expectEqual(@as(u16, 4), result2.lines_used);
    try testing.expectEqual(@as(usize, 2), result2.graphemes_rendered);
    try testing.expectEqual(@as(u16, 1), result2.final_x);
    try testing.expectEqual(@as(u16, 3), result2.final_y);
    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCodepointAt(0, 3, 'B');
    try tc.expectCodepointAt(0, 1, ' ');
    try tc.expectCodepointAt(0, 2, ' ');
}

test "print newline at end" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "Hello\n", 0, 0, .default);

    try testing.expectEqual(@as(usize, 6), result.bytes_consumed);
    try testing.expectEqual(@as(u16, 2), result.lines_used);
    try testing.expectEqual(@as(usize, 5), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 0), result.final_x);
    try testing.expectEqual(@as(u16, 1), result.final_y);

    try tc.expectCodepointAt(0, 0, 'H');
    try tc.expectCodepointAt(4, 0, 'o');
}

test "print carriage return" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    // "AB\rCD" - \r is ignored if it does not have a following \n
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "AB\rCD", 0, 0, .default);

    try testing.expectEqual(@as(usize, 5), result.bytes_consumed);
    try testing.expectEqual(@as(u16, 1), result.lines_used); // Still on line 0
    try testing.expectEqual(@as(usize, 4), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 4), result.final_x);
    try testing.expectEqual(@as(u16, 0), result.final_y);

    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCodepointAt(1, 0, 'B');
    try tc.expectCodepointAt(2, 0, 'C');
    try tc.expectCodepointAt(3, 0, 'D');
}

test "print CRLF" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    // \r\n comes as a single grapheme cluster
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "AB\r\nCD", 0, 0, .default);

    // Same behavior as \n
    try testing.expectEqual(@as(usize, 6), result.bytes_consumed); // "AB\r\nCD" = 6 bytes
    try testing.expectEqual(@as(u16, 2), result.lines_used);
    try testing.expectEqual(@as(usize, 4), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 2), result.final_x);
    try testing.expectEqual(@as(u16, 1), result.final_y);

    // Row 0
    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCodepointAt(1, 0, 'B');

    // Row 1
    try tc.expectCodepointAt(0, 1, 'C');
    try tc.expectCodepointAt(1, 1, 'D');
}

test "print newline stops at bottom" {
    var tc = try TestContext.init(10, 2);
    defer tc.deinit();

    // Only 2 rows, but text has 3 lines
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "A\nB\nC", 0, 0, .default);

    // Should render A and B, stop before C
    try testing.expectEqual(@as(u16, 2), result.lines_used);
    try testing.expectEqual(@as(usize, 2), result.graphemes_rendered);

    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCodepointAt(0, 1, 'B');

    // Also verify printAssumeNoGrapheme
    tc.buffer.clear();
    const result2 = printAssumeNoGrapheme(tc.scissor(), "A\nB\nC", 0, 0, .default);
    try testing.expectEqual(@as(u16, 2), result2.lines_used);
    try testing.expectEqual(@as(usize, 2), result2.graphemes_rendered);
    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCodepointAt(0, 1, 'B');
}

test "print newline with offset" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    // Start at x=3, newline should reset to x=0
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "AB\nCD", 3, 1, .default);

    try testing.expectEqual(@as(u16, 2), result.lines_used);
    try testing.expectEqual(@as(u16, 2), result.final_x);
    try testing.expectEqual(@as(u16, 2), result.final_y);

    // Row 1: _ _ _ A B
    try tc.expectCodepointAt(3, 1, 'A');
    try tc.expectCodepointAt(4, 1, 'B');

    // Row 2: C D (newline resets to column 0)
    try tc.expectCodepointAt(0, 2, 'C');
    try tc.expectCodepointAt(1, 2, 'D');
}

test "print expands tabs" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    // "A\tB" with tab_width=4
    // A at 0, tab expands to spaces at 1,2,3, B at 4
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "A\tB", 0, 0, .{ .wrap = false, .tab_width = 4 });

    try testing.expectEqual(@as(usize, 3), result.bytes_consumed); // A + \t + B
    try testing.expectEqual(@as(u16, 1), result.lines_used);
    try testing.expectEqual(@as(usize, 5), result.graphemes_rendered); // A + 3 spaces + B
    try testing.expectEqual(@as(u16, 5), result.final_x);
    try testing.expectEqual(@as(u16, 0), result.final_y);

    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCodepointAt(1, 0, ' '); // Tab space
    try tc.expectCodepointAt(2, 0, ' '); // Tab space
    try tc.expectCodepointAt(3, 0, ' '); // Tab space
    try tc.expectCodepointAt(4, 0, 'B');

    // Also verify printAssumeNoGrapheme
    tc.buffer.clear();
    const result2 = printAssumeNoGrapheme(tc.scissor(), "A\tB", 0, 0, .{ .wrap = false, .tab_width = 4 });
    try testing.expectEqual(@as(usize, 3), result2.bytes_consumed);
    try testing.expectEqual(@as(u16, 1), result2.lines_used);
    try testing.expectEqual(@as(usize, 5), result2.graphemes_rendered);
    try testing.expectEqual(@as(u16, 5), result2.final_x);
    try testing.expectEqual(@as(u16, 0), result2.final_y);
    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCodepointAt(1, 0, ' ');
    try tc.expectCodepointAt(3, 0, ' ');
    try tc.expectCodepointAt(4, 0, 'B');
}

test "print tab at tab stop" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    // Start at column 4 (already at tab stop), tab should advance 4 spaces to column 8
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "\tX", 4, 0, .{ .wrap = false, .tab_width = 4 });

    try testing.expectEqual(@as(usize, 5), result.graphemes_rendered); // 4 spaces + X
    try testing.expectEqual(@as(u16, 9), result.final_x);

    try tc.expectCodepointAt(4, 0, ' '); // Tab space
    try tc.expectCodepointAt(5, 0, ' '); // Tab space
    try tc.expectCodepointAt(6, 0, ' '); // Tab space
    try tc.expectCodepointAt(7, 0, ' '); // Tab space
    try tc.expectCodepointAt(8, 0, 'X');

    // Also verify printAssumeNoGrapheme
    tc.buffer.clear();
    const result2 = printAssumeNoGrapheme(tc.scissor(), "\tX", 4, 0, .{ .wrap = false, .tab_width = 4 });
    try testing.expectEqual(@as(usize, 5), result2.graphemes_rendered);
    try testing.expectEqual(@as(u16, 9), result2.final_x);
    try tc.expectCodepointAt(4, 0, ' ');
    try tc.expectCodepointAt(7, 0, ' ');
    try tc.expectCodepointAt(8, 0, 'X');
}

test "print tab wraps" {
    var tc = try TestContext.init(5, 3);
    defer tc.deinit();

    // Start at x=3, tab_width=4, so need 1 space to reach tab stop at 4
    // But we're in a 5-wide buffer, so we can fit 2 more spaces before wrapping
    // Tab expands: cursor at 3, need 1 space (to get to 4)
    // Position 3: space, cursor now at 4
    // That's all for the tab (cursor_x % 4 == 3, so 4-3=1 space)
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "\tX", 3, 0, .{ .wrap = true, .tab_width = 4 });

    try testing.expectEqual(@as(usize, 2), result.graphemes_rendered); // 1 space + X
    try testing.expectEqual(@as(u16, 0), result.final_x);
    try testing.expectEqual(@as(u16, 1), result.final_y);

    try tc.expectCodepointAt(3, 0, ' '); // Tab space
    try tc.expectCodepointAt(4, 0, 'X');
}

test "print tab wraps mid-tab" {
    var tc = try TestContext.init(5, 3);
    defer tc.deinit();

    // Start at x=4 in 5-wide buffer, tab_width=4
    // cursor at 4, 4 % 4 = 0, so need 4 spaces to reach next tab stop. But only 1 space remaining. Move cursor to end
    // Position 4: space, cursor now at 5 (past right edge, wrap)
    // Then X at position 3 row 1
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "\tX", 4, 0, .{ .wrap = true, .tab_width = 4 });

    try testing.expectEqual(@as(usize, 2), result.graphemes_rendered); // 4 spaces + X
    try testing.expectEqual(@as(u16, 2), result.lines_used);
    try testing.expectEqual(@as(u16, 1), result.final_x);
    try testing.expectEqual(@as(u16, 1), result.final_y);

    try tc.expectCodepointAt(4, 0, ' '); // First tab space
    try tc.expectCodepointAt(0, 1, 'X'); // Tab space after wrap
}

test "print custom tab width" {
    var tc = try TestContext.init(20, 5);
    defer tc.deinit();

    // "A\tB" with tab_width=8
    // A at 0, tab expands to 7 spaces (1,2,3,4,5,6,7), B at 8
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "A\tB", 0, 0, .{ .wrap = false, .tab_width = 8 });

    try testing.expectEqual(@as(usize, 9), result.graphemes_rendered); // A + 7 spaces + B
    try testing.expectEqual(@as(u16, 9), result.final_x);

    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCodepointAt(7, 0, ' '); // Last tab space
    try tc.expectCodepointAt(8, 0, 'B');

    // Also verify printAssumeNoGrapheme
    tc.buffer.clear();
    const result2 = printAssumeNoGrapheme(tc.scissor(), "A\tB", 0, 0, .{ .wrap = false, .tab_width = 8 });
    try testing.expectEqual(@as(usize, 9), result2.graphemes_rendered);
    try testing.expectEqual(@as(u16, 9), result2.final_x);
    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCodepointAt(7, 0, ' ');
    try tc.expectCodepointAt(8, 0, 'B');
}

test "print tab truncates without wrap" {
    var tc = try TestContext.init(5, 3);
    defer tc.deinit();

    // Start at x=3 in 5-wide buffer, tab_width=4, no wrap
    // Tab needs 1 space (to get to 4), then we're at edge
    // X would be at 4, but then we're still within bounds
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "\tXY", 3, 0, .{ .wrap = false, .tab_width = 4 });

    // Space at 3, X at 4, Y truncated
    try testing.expectEqual(@as(usize, 2), result.graphemes_rendered); // 1 space + X
    try testing.expectEqual(@as(u16, 0), result.final_x);
    try testing.expectEqual(@as(u16, 1), result.final_y);

    try tc.expectCodepointAt(3, 0, ' ');
    try tc.expectCodepointAt(4, 0, 'X');
    try tc.expectCodepointAt(0, 1, ' ');
}

test "print multiple tabs" {
    var tc = try TestContext.init(20, 5);
    defer tc.deinit();

    // "A\t\tB" with tab_width=4
    // A at 0, first tab to 4, second tab to 8, B at 8
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "A\t\tB", 0, 0, .{ .wrap = false, .tab_width = 4 });

    // A + 3 spaces + 4 spaces + B = 9 graphemes
    try testing.expectEqual(@as(usize, 9), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 9), result.final_x);

    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCodepointAt(4, 0, ' '); // Start of second tab
    try tc.expectCodepointAt(8, 0, 'B');

    // Also verify printAssumeNoGrapheme
    tc.buffer.clear();
    const result2 = printAssumeNoGrapheme(tc.scissor(), "A\t\tB", 0, 0, .{ .wrap = false, .tab_width = 4 });
    try testing.expectEqual(@as(usize, 9), result2.graphemes_rendered);
    try testing.expectEqual(@as(u16, 9), result2.final_x);
    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCodepointAt(4, 0, ' ');
    try tc.expectCodepointAt(8, 0, 'B');
}

test "print UTF-8 narrow" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    // "café" - 'é' is 2 bytes (C3 A9), width=1
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "café", 0, 0, .default);

    // 4 graphemes: c, a, f, é
    try testing.expectEqual(@as(usize, 5), result.bytes_consumed); // 3 ASCII + 2-byte é
    try testing.expectEqual(@as(usize, 4), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 4), result.final_x);

    try tc.expectCodepointAt(0, 0, 'c');
    try tc.expectCodepointAt(1, 0, 'a');
    try tc.expectCodepointAt(2, 0, 'f');
    try tc.expectCodepointAt(3, 0, 0xE9); // é = U+00E9

    // All should be narrow width and codepoint tag (single codepoint each)
    try tc.expectCellWidth(3, 0, .narrow);
    try tc.expectCellTag(3, 0, .codepoint);

    // Also verify printAssumeNoGrapheme
    tc.buffer.clear();
    const result2 = printAssumeNoGrapheme(tc.scissor(), "café", 0, 0, .default);
    try testing.expectEqual(@as(usize, 5), result2.bytes_consumed);
    try testing.expectEqual(@as(usize, 4), result2.graphemes_rendered);
    try testing.expectEqual(@as(u16, 4), result2.final_x);
    try tc.expectCodepointAt(0, 0, 'c');
    try tc.expectCodepointAt(3, 0, 0xE9);
    try tc.expectCellWidth(3, 0, .narrow);
    try tc.expectCellTag(3, 0, .codepoint);
}

test "print Euro sign" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    // "€" is 3 bytes (E2 82 AC), width=1
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "€", 0, 0, .default);

    try testing.expectEqual(@as(usize, 3), result.bytes_consumed);
    try testing.expectEqual(@as(usize, 1), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 1), result.final_x);

    try tc.expectCodepointAt(0, 0, 0x20AC); // € = U+20AC
    try tc.expectCellWidth(0, 0, .narrow);
    try tc.expectCellTag(0, 0, .codepoint);
}

test "print combining marks" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    // "e\xCC\x81" = e + combining acute accent (U+0301) = 1 grapheme cluster
    // This should be stored as a grapheme (tag = .grapheme)
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "e\xCC\x81", 0, 0, .default);

    try testing.expectEqual(@as(usize, 3), result.bytes_consumed); // 1 + 2 bytes
    try testing.expectEqual(@as(usize, 1), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 1), result.final_x);

    try tc.expectCellWidth(0, 0, .narrow);
    try tc.expectCellTag(0, 0, .grapheme);

    // Grapheme buffer should contain the full UTF-8 bytes
    const grapheme = tc.getGraphemeAt(0, 0);
    try testing.expect(grapheme != null);
    try testing.expectEqualStrings("e\xCC\x81", grapheme.?);
}

test "print multiple combining marks" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    // "a\xCC\x81\xCC\x82" = a + combining acute + combining circumflex
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "a\xCC\x81\xCC\x82", 0, 0, .default);

    try testing.expectEqual(@as(usize, 5), result.bytes_consumed); // 1 + 2 + 2 bytes
    try testing.expectEqual(@as(usize, 1), result.graphemes_rendered);

    try tc.expectCellTag(0, 0, .grapheme);

    const grapheme = tc.getGraphemeAt(0, 0);
    try testing.expect(grapheme != null);
    try testing.expectEqualStrings("a\xCC\x81\xCC\x82", grapheme.?);
}

test "print mixed ASCII and UTF-8" {
    var tc = try TestContext.init(20, 5);
    defer tc.deinit();

    // "Hello café!"
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "Hello café!", 0, 0, .default);

    try testing.expectEqual(@as(usize, 12), result.bytes_consumed); // 11 chars, é is 2 bytes
    try testing.expectEqual(@as(usize, 11), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 11), result.final_x);

    try tc.expectCodepointAt(0, 0, 'H');
    try tc.expectCodepointAt(5, 0, ' ');
    try tc.expectCodepointAt(6, 0, 'c');
    try tc.expectCodepointAt(7, 0, 'a');
    try tc.expectCodepointAt(8, 0, 'f');
    try tc.expectCodepointAt(9, 0, 0xE9); // é
    try tc.expectCodepointAt(10, 0, '!');
}

test "print combining with wrap" {
    var tc = try TestContext.init(5, 3);
    defer tc.deinit();

    // "ABCD" + combining mark + "F" - should wrap properly
    // Graphemes: A, B, C, D, e+combining, F = 6 graphemes
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "ABCDe\xCC\x81F", 0, 0, .{ .wrap = true, .tab_width = 4 });

    // Row 0: A B C D e+combining
    // Row 1: F
    try testing.expectEqual(@as(usize, 6), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 2), result.lines_used);

    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCellTag(4, 0, .grapheme);
    try tc.expectCodepointAt(0, 1, 'F');
}

test "print UTF-8 truncates at edge" {
    var tc = try TestContext.init(3, 3);
    defer tc.deinit();

    // "ABéC" in 3-wide buffer - should truncate after é
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "ABéC", 0, 0, .default);

    // Only A, B, é should render
    try testing.expectEqual(@as(usize, 3), result.graphemes_rendered);

    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCodepointAt(1, 0, 'B');
    try tc.expectCodepointAt(2, 0, 0xE9);
}

test "print CJK characters" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    // "中文" - two CJK characters, each 2 cells wide
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "中文", 0, 0, .default);

    // 2 graphemes, 4 cells
    try testing.expectEqual(@as(usize, 6), result.bytes_consumed); // Each CJK char is 3 bytes
    try testing.expectEqual(@as(usize, 2), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 4), result.final_x);

    // First character: 中 (U+4E2D)
    try tc.expectCodepointAt(0, 0, 0x4E2D);
    try tc.expectCellWidth(0, 0, .wide_start);
    try tc.expectCodepointAt(1, 0, ' ');
    try tc.expectCellWidth(1, 0, .wide_end);

    // Second character: 文 (U+6587)
    try tc.expectCodepointAt(2, 0, 0x6587);
    try tc.expectCellWidth(2, 0, .wide_start);
    try tc.expectCodepointAt(3, 0, ' ');
    try tc.expectCellWidth(3, 0, .wide_end);

    // Also verify printAssumeNoGrapheme
    tc.buffer.clear();
    const result2 = printAssumeNoGrapheme(tc.scissor(), "中文", 0, 0, .default);
    try testing.expectEqual(@as(usize, 6), result2.bytes_consumed);
    try testing.expectEqual(@as(usize, 2), result2.graphemes_rendered);
    try testing.expectEqual(@as(u16, 4), result2.final_x);
    try tc.expectCodepointAt(0, 0, 0x4E2D);
    try tc.expectCellWidth(0, 0, .wide_start);
    try tc.expectCellWidth(1, 0, .wide_end);
    try tc.expectCodepointAt(2, 0, 0x6587);
    try tc.expectCellWidth(2, 0, .wide_start);
    try tc.expectCellWidth(3, 0, .wide_end);
}

test "print emoji" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    // "😀" - emoji, 2 cells wide
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "😀", 0, 0, .default);

    try testing.expectEqual(@as(usize, 4), result.bytes_consumed); // 4-byte emoji
    try testing.expectEqual(@as(usize, 1), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 2), result.final_x);

    // Emoji: 😀 (U+1F600)
    try tc.expectCodepointAt(0, 0, 0x1F600);
    try tc.expectCellWidth(0, 0, .wide_start);
    try tc.expectCodepointAt(1, 0, ' ');
    try tc.expectCellWidth(1, 0, .wide_end);

    // Also verify printAssumeNoGrapheme
    tc.buffer.clear();
    const result2 = printAssumeNoGrapheme(tc.scissor(), "😀", 0, 0, .default);
    try testing.expectEqual(@as(usize, 4), result2.bytes_consumed);
    try testing.expectEqual(@as(usize, 1), result2.graphemes_rendered);
    try testing.expectEqual(@as(u16, 2), result2.final_x);
    try tc.expectCodepointAt(0, 0, 0x1F600);
    try tc.expectCellWidth(0, 0, .wide_start);
    try tc.expectCellWidth(1, 0, .wide_end);
}

test "print wide at boundary wraps" {
    var tc = try TestContext.init(3, 3);
    defer tc.deinit();

    // "AB中" in 3-wide buffer with wrap
    // A at (0,0), B at (1,0), 中 only has 1 cell remaining, wraps to (0,1)-(1,1)
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "AB中", 0, 0, .{ .wrap = true, .tab_width = 4 });

    try testing.expectEqual(@as(usize, 3), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 2), result.lines_used);
    try testing.expectEqual(@as(u16, 2), result.final_x);
    try testing.expectEqual(@as(u16, 1), result.final_y);

    // Row 0: A B _
    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCellWidth(0, 0, .narrow);
    try tc.expectCodepointAt(1, 0, 'B');
    try tc.expectCellWidth(1, 0, .narrow);

    // Row 1: 中 (wide_start + wide_end)
    try tc.expectCodepointAt(0, 1, 0x4E2D);
    try tc.expectCellWidth(0, 1, .wide_start);
    try tc.expectCodepointAt(1, 1, ' ');
    try tc.expectCellWidth(1, 1, .wide_end);
}

test "print wide at boundary no wrap" {
    var tc = try TestContext.init(3, 3);
    defer tc.deinit();

    // "AB中" in 3-wide buffer without wrap
    // A at 0, B at 1, cursor at 2
    // 中 needs 2 cells but only 1 remains (position 2) so it will not be rendered
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "AB中", 0, 0, .{ .wrap = false, .tab_width = 4 });

    try testing.expectEqual(@as(usize, 2), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 0), result.final_x);
    try testing.expectEqual(@as(u16, 1), result.final_y);

    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCellWidth(0, 0, .narrow);

    try tc.expectCodepointAt(1, 0, 'B');
    try tc.expectCellWidth(1, 0, .narrow);

    // Empty cell at position 2
    try tc.expectCodepointAt(2, 0, ' ');
    try tc.expectCellWidth(2, 0, .narrow);

    // Also verify printAssumeNoGrapheme
    tc.buffer.clear();
    const result2 = printAssumeNoGrapheme(tc.scissor(), "AB中", 0, 0, .{ .wrap = false, .tab_width = 4 });
    try testing.expectEqual(@as(usize, 2), result2.graphemes_rendered);
    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCodepointAt(1, 0, 'B');
    try tc.expectCodepointAt(2, 0, ' ');
}

test "print wide exactly fits" {
    var tc = try TestContext.init(4, 3);
    defer tc.deinit();

    // "AB中" in 4-wide buffer - 中 should exactly fit at positions 2-3
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "AB中", 0, 0, .default);

    try testing.expectEqual(@as(usize, 3), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 0), result.final_x);
    try testing.expectEqual(@as(u16, 1), result.final_y);

    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCodepointAt(1, 0, 'B');
    try tc.expectCodepointAt(2, 0, 0x4E2D);
    try tc.expectCellWidth(2, 0, .wide_start);
    try tc.expectCodepointAt(3, 0, ' ');
    try tc.expectCellWidth(3, 0, .wide_end);

    // Also verify printAssumeNoGrapheme
    tc.buffer.clear();
    const result2 = printAssumeNoGrapheme(tc.scissor(), "AB中", 0, 0, .default);
    try testing.expectEqual(@as(usize, 3), result2.graphemes_rendered);
    try testing.expectEqual(@as(u16, 0), result2.final_x);
    try testing.expectEqual(@as(u16, 1), result2.final_y);
    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCodepointAt(1, 0, 'B');
    try tc.expectCodepointAt(2, 0, 0x4E2D);
    try tc.expectCellWidth(2, 0, .wide_start);
    try tc.expectCellWidth(3, 0, .wide_end);
}

test "print multiple wide characters wrap" {
    var tc = try TestContext.init(4, 3);
    defer tc.deinit();

    // "中文字" - 3 wide chars in 4-wide buffer with wrap
    // Row 0: 中文 (4 cells)
    // Row 1: 字 (2 cells)
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "中文字", 0, 0, .{ .wrap = true, .tab_width = 4 });

    try testing.expectEqual(@as(usize, 3), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 2), result.lines_used);
    try testing.expectEqual(@as(u16, 2), result.final_x);
    try testing.expectEqual(@as(u16, 1), result.final_y);

    // Row 0
    try tc.expectCodepointAt(0, 0, 0x4E2D); // 中
    try tc.expectCellWidth(0, 0, .wide_start);
    try tc.expectCodepointAt(2, 0, 0x6587); // 文
    try tc.expectCellWidth(2, 0, .wide_start);

    // Row 1
    try tc.expectCodepointAt(0, 1, 0x5B57); // 字
    try tc.expectCellWidth(0, 1, .wide_start);
}

test "print mixed narrow and wide" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    // "Hello中文!" - mixed content
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "Hello中文!", 0, 0, .default);

    // 5 narrow + 2 wide + 1 narrow = 8 graphemes, 10 cells
    try testing.expectEqual(@as(usize, 8), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 0), result.final_x);
    try testing.expectEqual(@as(u16, 1), result.final_y);

    try tc.expectCodepointAt(0, 0, 'H');
    try tc.expectCellWidth(0, 0, .narrow);
    try tc.expectCodepointAt(5, 0, 0x4E2D); // 中
    try tc.expectCellWidth(5, 0, .wide_start);
    try tc.expectCodepointAt(7, 0, 0x6587); // 文
    try tc.expectCellWidth(7, 0, .wide_start);
    try tc.expectCodepointAt(9, 0, '!');
    try tc.expectCellWidth(9, 0, .narrow);
}

test "print ZWJ family sequence" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    // 👨‍👩‍👧‍👦 = family (man + ZWJ + woman + ZWJ + girl + ZWJ + boy)
    // 7 codepoints, width=2
    const family = "\xF0\x9F\x91\xA8\xE2\x80\x8D\xF0\x9F\x91\xA9\xE2\x80\x8D\xF0\x9F\x91\xA7\xE2\x80\x8D\xF0\x9F\x91\xA6";
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, family, 0, 0, .default);

    try testing.expectEqual(@as(usize, 25), result.bytes_consumed);
    try testing.expectEqual(@as(usize, 1), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 2), result.final_x);

    // First cell: base emoji with grapheme tag
    try tc.expectCellWidth(0, 0, .wide_start);
    try tc.expectCellTag(0, 0, .grapheme);

    // Second cell: wide_end
    try tc.expectCellWidth(1, 0, .wide_end);

    // Grapheme buffer should contain full sequence
    const grapheme = tc.getGraphemeAt(0, 0);
    try testing.expect(grapheme != null);
    try testing.expectEqualStrings(family, grapheme.?);
}

test "print variation selector emoji" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    // ❤️ = heart + VS16 (width becomes 2 with emoji presentation)
    const heart = "\xE2\x9D\xA4\xEF\xB8\x8F";
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, heart, 0, 0, .default);

    try testing.expectEqual(@as(usize, 6), result.bytes_consumed);
    try testing.expectEqual(@as(usize, 1), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 2), result.final_x);

    // First cell: heart with grapheme tag (multi-codepoint due to VS16)
    try tc.expectCellWidth(0, 0, .wide_start);
    try tc.expectCellTag(0, 0, .grapheme);

    // Second cell: wide_end
    try tc.expectCellWidth(1, 0, .wide_end);

    // Grapheme buffer should contain heart + VS16
    const grapheme = tc.getGraphemeAt(0, 0);
    try testing.expect(grapheme != null);
    try testing.expectEqualStrings(heart, grapheme.?);
}

test "print text heart without variation selector" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    // ❤ = heart without VS16 (text presentation, width=1)
    const heart = "\xE2\x9D\xA4";
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, heart, 0, 0, .default);

    try testing.expectEqual(@as(usize, 3), result.bytes_consumed);
    try testing.expectEqual(@as(usize, 1), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 1), result.final_x);

    // Single codepoint, narrow width, codepoint tag
    try tc.expectCodepointAt(0, 0, 0x2764); // ❤ U+2764
    try tc.expectCellWidth(0, 0, .narrow);
    try tc.expectCellTag(0, 0, .codepoint);
}

test "print multiple complex emoji in sequence" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    // 🇺🇸🇬🇧 = US flag + UK flag (2 graphemes, 4 cells)
    const flags = "\xF0\x9F\x87\xBA\xF0\x9F\x87\xB8\xF0\x9F\x87\xAC\xF0\x9F\x87\xA7";
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, flags, 0, 0, .default);

    try testing.expectEqual(@as(usize, 16), result.bytes_consumed);
    try testing.expectEqual(@as(usize, 2), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 4), result.final_x);

    // First flag: 🇺🇸
    try tc.expectCellWidth(0, 0, .wide_start);
    try tc.expectCellTag(0, 0, .grapheme);
    try tc.expectCellWidth(1, 0, .wide_end);

    // Second flag: 🇬🇧
    try tc.expectCellWidth(2, 0, .wide_start);
    try tc.expectCellTag(2, 0, .grapheme);
    try tc.expectCellWidth(3, 0, .wide_end);
}

test "print complex emoji at boundary wraps" {
    var tc = try TestContext.init(3, 3);
    defer tc.deinit();

    // "A" + 👨🏽 (skin tone emoji) in 3-wide buffer with wrap
    // A at (0,0), emoji only has 2 cells remaining but needs 2, should fit
    // Wait, A at 0, cursor at 1, emoji needs 2 cells, we have 2 (1,2), should fit
    const text = "A\xF0\x9F\x91\xA8\xF0\x9F\x8F\xBD";
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, text, 0, 0, .{ .wrap = true, .tab_width = 4 });

    try testing.expectEqual(@as(usize, 2), result.graphemes_rendered); // A + emoji
    try testing.expectEqual(@as(u16, 0), result.final_x);
    try testing.expectEqual(@as(u16, 1), result.final_y);

    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCellWidth(0, 0, .narrow);
    try tc.expectCellWidth(1, 0, .wide_start);
    try tc.expectCellWidth(2, 0, .wide_end);
}

test "print complex emoji at boundary with only 1 cell wraps" {
    var tc = try TestContext.init(3, 3);
    defer tc.deinit();

    // "AB" + 👨🏽 in 3-wide buffer - only 1 cell left, should wrap
    const text = "AB\xF0\x9F\x91\xA8\xF0\x9F\x8F\xBD";
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, text, 0, 0, .{ .wrap = true, .tab_width = 4 });

    try testing.expectEqual(@as(usize, 3), result.graphemes_rendered); // A, B, emoji
    try testing.expectEqual(@as(u16, 2), result.lines_used);
    try testing.expectEqual(@as(u16, 2), result.final_x);
    try testing.expectEqual(@as(u16, 1), result.final_y);

    // Row 0: A B _
    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCodepointAt(1, 0, 'B');

    // Row 1: emoji
    try tc.expectCellWidth(0, 1, .wide_start);
    try tc.expectCellTag(0, 1, .grapheme);
    try tc.expectCellWidth(1, 1, .wide_end);
}

test "print mixed text and complex graphemes" {
    var tc = try TestContext.init(20, 5);
    defer tc.deinit();

    // "Hello 👨‍👩‍👧 世界!"
    const text = "Hello \xF0\x9F\x91\xA8\xE2\x80\x8D\xF0\x9F\x91\xA9\xE2\x80\x8D\xF0\x9F\x91\xA7 \xE4\xB8\x96\xE7\x95\x8C!";
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, text, 0, 0, .default);

    // "Hello " (6) + family emoji (1, 2 cells) + " " (1) + "世界" (2, 4 cells) + "!" (1) = 11 graphemes
    // Cells: 6 + 2 + 1 + 4 + 1 = 14 cells
    try testing.expectEqual(@as(usize, 11), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 14), result.final_x);

    try tc.expectCodepointAt(0, 0, 'H');
    try tc.expectCodepointAt(5, 0, ' ');
    try tc.expectCellTag(6, 0, .grapheme);
    try tc.expectCellWidth(6, 0, .wide_start);
    try tc.expectCodepointAt(8, 0, ' ');
    try tc.expectCodepointAt(9, 0, 0x4E16); // 世
    try tc.expectCellWidth(9, 0, .wide_start);
    try tc.expectCodepointAt(13, 0, '!');
}

test "print mixed content with all features" {
    var tc = try TestContext.init(20, 5);
    defer tc.deinit();

    // "Hello 世界!\n\tTab 😀"
    const text = "Hello \xE4\xB8\x96\xE7\x95\x8C!\n\tTab \xF0\x9F\x98\x80";
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, text, 0, 0, .{ .wrap = true, .tab_width = 4 });

    // Line 0: "Hello 世界!" = 6 + 4 + 1 = 11 cells, 8 graphemes
    // Line 1: "    Tab 😀" = 4 (tab) + 4 + 2 = 10 cells
    try testing.expectEqual(@as(u16, 2), result.lines_used);

    // Verify line 0 content
    try tc.expectCodepointAt(0, 0, 'H');
    try tc.expectCodepointAt(6, 0, 0x4E16); // 世
    try tc.expectCellWidth(6, 0, .wide_start);
    try tc.expectCodepointAt(10, 0, '!');

    // Verify line 1 content (after newline and tab)
    try tc.expectCodepointAt(0, 1, ' '); // Tab expanded to spaces
    try tc.expectCodepointAt(4, 1, 'T');
}

test "print invalid UTF-8 produces replacement characters" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    // Invalid UTF-8 bytes are rendered as replacement characters (U+FFFD)
    // This is WTF-8 semantics - graceful degradation instead of errors
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "\xFF\xFE", 0, 0, .default);

    // Each invalid byte becomes a replacement character
    try testing.expectEqual(@as(usize, 2), result.bytes_consumed);
    try testing.expectEqual(@as(usize, 2), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 2), result.final_x);

    // Both cells should contain U+FFFD (replacement character)
    try tc.expectCodepointAt(0, 0, 0xFFFD);
    try tc.expectCodepointAt(1, 0, 0xFFFD);
}

test "print very long line" {
    var tc = try TestContext.init(80, 24);
    defer tc.deinit();

    // Create 1000 character string
    var long_text: [1000]u8 = undefined;
    for (&long_text, 0..) |*c, i| {
        c.* = @intCast('A' + @as(u8, @intCast(i % 26)));
    }

    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, &long_text, 0, 0, .{ .wrap = true, .tab_width = 4 });

    // 1000 chars / 80 cols = 12 full lines + 40 chars on line 13
    try testing.expectEqual(@as(usize, 1000), result.bytes_consumed);
    try testing.expectEqual(@as(usize, 1000), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 13), result.lines_used);
    try testing.expectEqual(@as(u16, 40), result.final_x);
    try testing.expectEqual(@as(u16, 12), result.final_y);

    // Verify first and last positions
    // Index i maps to 'A' + (i % 26)
    try tc.expectCodepointAt(0, 0, 'A'); // index 0
    try tc.expectCodepointAt(79, 0, 'A' + (79 % 26)); // index 79 % 26 = 1 -> 'B'
    try tc.expectCodepointAt(0, 1, 'A' + (80 % 26)); // index 80 % 26 = 2 -> 'C'
}

test "print exact boundary - fills line exactly" {
    var tc = try TestContext.init(5, 2);
    defer tc.deinit();

    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "ABCDE", 0, 0, .{ .wrap = true, .tab_width = 4 });

    try testing.expectEqual(@as(usize, 5), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 1), result.lines_used);
    try testing.expectEqual(@as(u16, 0), result.final_x);
    try testing.expectEqual(@as(u16, 1), result.final_y);
}

test "print exact boundary - wide char fills last two cells" {
    var tc = try TestContext.init(4, 2);
    defer tc.deinit();

    // "AB中" - AB takes 2 cells, 中 takes 2 cells = exactly 4
    const result = try print(tc.scissor(), &TestContext.test_codepoint_buffer, "AB\xE4\xB8\xAD", 0, 0, .{ .wrap = true, .tab_width = 4 });

    try testing.expectEqual(@as(usize, 3), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 1), result.lines_used);
    try testing.expectEqual(@as(u16, 0), result.final_x);
    try testing.expectEqual(@as(u16, 1), result.final_y);

    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCodepointAt(1, 0, 'B');
    try tc.expectCodepointAt(2, 0, 0x4E2D); // 中
    try tc.expectCellWidth(2, 0, .wide_start);
    try tc.expectCellWidth(3, 0, .wide_end);
}

test "printAssumeNoGrapheme CRLF not combined" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    // \r ignored, \n acts as newline
    const result = printAssumeNoGrapheme(tc.scissor(), "AB\r\nCD", 0, 0, .default);

    // Row 0: A B, Row 1: C D
    try testing.expectEqual(@as(usize, 6), result.bytes_consumed); // "AB\r\nCD" = 6 bytes
    try testing.expectEqual(@as(u16, 2), result.lines_used);
    try testing.expectEqual(@as(usize, 4), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 2), result.final_x);
    try testing.expectEqual(@as(u16, 1), result.final_y);

    // Row 0
    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCodepointAt(1, 0, 'B');

    // Row 1
    try tc.expectCodepointAt(0, 1, 'C');
    try tc.expectCodepointAt(1, 1, 'D');
}

test "printAssumeNoGrapheme tab_width zero" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    // tab_width = 0 should be ignored
    const result = printAssumeNoGrapheme(tc.scissor(), "A\tB", 0, 0, .{ .wrap = false, .tab_width = 0 });

    try testing.expectEqual(@as(usize, 2), result.graphemes_rendered); // A + 1 space + B
    try testing.expectEqual(@as(u16, 2), result.final_x);

    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCodepointAt(1, 0, 'B');
}

test "printAssumeNoGrapheme skips zero-width" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    // Combining acute accent alone (not attached to base) - has width=0
    // "\xCC\x81" is combining acute accent (U+0301)
    // "A\xCC\x81B" = A + combining mark + B
    // printAssumeNoGrapheme should render A, skip combining mark, render B
    const result = printAssumeNoGrapheme(tc.scissor(), "A\xCC\x81B", 0, 0, .default);

    // A and B rendered, combining mark skipped (width=0)
    try testing.expectEqual(@as(usize, 4), result.bytes_consumed); // 1 + 2 + 1 bytes
    try testing.expectEqual(@as(usize, 2), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 2), result.final_x);

    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCodepointAt(1, 0, 'B');
}

test "printAssumeNoGrapheme zero-width joiner ignored" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    // ZWJ (U+200D) has width=0
    // "A\xE2\x80\x8DB" = A + ZWJ + B
    const result = printAssumeNoGrapheme(tc.scissor(), "A\xE2\x80\x8DB", 0, 0, .default);

    // A and B rendered, ZWJ skipped
    try testing.expectEqual(@as(usize, 5), result.bytes_consumed); // 1 + 3 + 1 bytes
    try testing.expectEqual(@as(usize, 2), result.graphemes_rendered);

    try tc.expectCodepointAt(0, 0, 'A');
    try tc.expectCodepointAt(1, 0, 'B');
}

test "printAssumeNoGrapheme invalid UTF-8 replacement char" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    // Invalid UTF-8 bytes are rendered as replacement characters (U+FFFD)
    const result = printAssumeNoGrapheme(tc.scissor(), "\xFF\xFE", 0, 0, .default);

    // Each invalid byte becomes a replacement character
    try testing.expectEqual(@as(usize, 2), result.bytes_consumed);
    try testing.expectEqual(@as(usize, 2), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 2), result.final_x);

    // Both cells should contain U+FFFD (replacement character)
    try tc.expectCodepointAt(0, 0, 0xFFFD);
    try tc.expectCodepointAt(1, 0, 0xFFFD);
}

test "printAssumeNoGrapheme invalid mid-sequence" {
    var tc = try TestContext.init(10, 5);
    defer tc.deinit();

    // Start valid UTF-8 sequence, interrupt with invalid byte
    // "\xC3\xFF" - starts 2-byte sequence, invalid continuation
    const result = printAssumeNoGrapheme(tc.scissor(), "\xC3\xFF", 0, 0, .default);

    // Should produce 2 replacement characters
    try testing.expectEqual(@as(usize, 2), result.bytes_consumed);
    try testing.expectEqual(@as(usize, 2), result.graphemes_rendered);

    try tc.expectCodepointAt(0, 0, 0xFFFD);
    try tc.expectCodepointAt(1, 0, 0xFFFD);
}

test "Scissor.fillRectangle fills partial region" {
    const cells = try testing.allocator.alloc(Cell, 50);
    defer testing.allocator.free(cells);
    var fb = try FrameBuffer.init(cells, 10, 5, .tiny);
    defer fb.deinit();

    fb.clear();

    const scissor = Scissor{
        .x_global = 0,
        .y_global = 0,
        .width_global = 10,
        .height_global = 5,
        .x_clip = 0,
        .y_clip = 0,
        .width_clip = 10,
        .height_clip = 5,
        .buffer = &fb,
    };

    scissor.fillRectangleNarrow(2, 1, 3, 2, Cell{ .data = .{ .codepoint = '*' } });

    // Check rectangle at (2,1) with size 3x2
    for (0..5) |y| {
        for (0..10) |x| {
            const expected: u21 = if (x >= 2 and x < 5 and y >= 1 and y < 3) '*' else ' ';
            try std.testing.expectEqual(expected, fb.cells[y * 10 + x].data.codepoint);
        }
    }
}

test "print wide char clipped by framebuffer" {
    var tc = try TestContext.init(5, 2);
    defer tc.deinit();
    // Logical scissor extends past framebuffer right edge.
    // Framebuffer: x = 0..4
    // Scissor:     x = 4..6 (only x=4 is visible)
    const scissor = Scissor{
        .x_global = 4,
        .y_global = 0,
        .width_global = 3,
        .height_global = 2,
        .x_clip = 0,
        .y_clip = 0,
        .width_clip = 3,
        .height_clip = 2,
        .buffer = &tc.buffer,
    };
    const result = try print(
        scissor,
        &TestContext.test_codepoint_buffer,
        "中",
        0,
        0,
        .{ .wrap = true, .tab_width = 4 },
    );
    // Input consumed, but glyph is skipped because second cell is clipped.
    try testing.expectEqual(@as(usize, 3), result.bytes_consumed);
    try testing.expectEqual(@as(usize, 0), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 0), result.lines_used);
    try testing.expectEqual(@as(u16, 2), result.final_x);
    try testing.expectEqual(@as(u16, 0), result.final_y);
    // Visible edge cell remains untouched.
    try tc.expectCodepointAt(4, 0, ' ');

    const resultNoGrapheme = printAssumeNoGrapheme(
        scissor,
        "中",
        0,
        0,
        .{ .wrap = true, .tab_width = 4 },
    );
    try testing.expectEqual(@as(usize, 3), resultNoGrapheme.bytes_consumed);
    try testing.expectEqual(@as(usize, 0), resultNoGrapheme.graphemes_rendered);
    try testing.expectEqual(@as(u16, 0), resultNoGrapheme.lines_used);
    try testing.expectEqual(@as(u16, 2), resultNoGrapheme.final_x);
    try testing.expectEqual(@as(u16, 0), resultNoGrapheme.final_y);
    try tc.expectCodepointAt(4, 0, ' ');
}

test "Scissor.set and get clip to visible bounds" {
    var tc = try TestContext.init(6, 4);
    defer tc.deinit();

    const scissor = Scissor{
        .x_global = 0,
        .y_global = 0,
        .width_global = 6,
        .height_global = 4,
        .x_clip = 2,
        .y_clip = 1,
        .width_clip = 2,
        .height_clip = 2,
        .buffer = &tc.buffer,
    };

    try testing.expectError(error.OutOfBoundsVisible, scissor.set(1, 1, Cell{ .data = .{ .codepoint = 'A' } }));
    try scissor.set(2, 1, Cell{ .data = .{ .codepoint = 'B' } });
    try scissor.set(3, 2, Cell{ .data = .{ .codepoint = 'C' } });

    try tc.expectCodepointAt(1, 1, ' ');
    try tc.expectCodepointAt(2, 1, 'B');
    try tc.expectCodepointAt(3, 2, 'C');

    try testing.expect(scissor.get(1, 1) == null);
    const visible = scissor.get(2, 1);
    try testing.expect(visible != null);
    try testing.expectEqual(@as(u21, 'B'), visible.?.data.codepoint);
}

test "Scissor.set enforces wide-cell behavior" {
    var tc = try TestContext.init(6, 2);
    defer tc.deinit();

    const full = tc.scissor();
    try testing.expectError(error.OutOfBoundsLogical, full.set(99, 0, .empty));
    try testing.expectError(error.InvalidWideEnd, full.set(0, 0, .wide_end));

    const clipped = Scissor{
        .x_global = 0,
        .y_global = 0,
        .width_global = 6,
        .height_global = 2,
        .x_clip = 1,
        .y_clip = 0,
        .width_clip = 2,
        .height_clip = 2,
        .buffer = &tc.buffer,
    };

    try testing.expectError(error.OutOfBoundsVisible, clipped.set(0, 0, Cell{ .data = .{ .codepoint = 'X' } }));
    try testing.expectError(error.WideStartWouldClip, clipped.set(2, 0, Cell{ .data = .{ .codepoint = 0x4E2D }, .width = .wide_start }));

    try clipped.set(1, 0, Cell{ .data = .{ .codepoint = 0x4E2D }, .width = .wide_start });
    try tc.expectCellWidth(1, 0, .wide_start);
    try tc.expectCellWidth(2, 0, .wide_end);

    try clipped.set(2, 0, Cell{ .data = .{ .codepoint = 'Q' } });
    try tc.expectCodepointAt(1, 0, ' ');
    try tc.expectCellWidth(1, 0, .narrow);
    try tc.expectCodepointAt(2, 0, 'Q');
    try tc.expectCellWidth(2, 0, .narrow);
}

test "print handlse negative-offset scissor" {
    var tc = try TestContext.init(6, 4);
    defer tc.deinit();

    const scissor = Scissor{
        .x_global = -2,
        .y_global = -1,
        .width_global = 6,
        .height_global = 3,
        .x_clip = 0,
        .y_clip = 0,
        .width_clip = 6,
        .height_clip = 3,
        .buffer = &tc.buffer,
    };

    const result = try print(scissor, &TestContext.test_codepoint_buffer, "ABCDE", 0, 1, .default);
    try testing.expectEqual(@as(usize, 3), result.graphemes_rendered);
    try tc.expectCodepointAt(0, 0, 'C');
    try tc.expectCodepointAt(1, 0, 'D');
    try tc.expectCodepointAt(2, 0, 'E');

    tc.buffer.clear();
    const result_no_grapheme = printAssumeNoGrapheme(scissor, "ABCDE", 0, 1, .default);
    try testing.expectEqual(@as(usize, 3), result_no_grapheme.graphemes_rendered);
    try tc.expectCodepointAt(0, 0, 'C');
    try tc.expectCodepointAt(1, 0, 'D');
    try tc.expectCodepointAt(2, 0, 'E');
}

test "Scissor.containsLogical and containsVisible diverge with clipping" {
    var tc = try TestContext.init(8, 4);
    defer tc.deinit();

    const scissor = Scissor{
        .x_global = 1,
        .y_global = 1,
        .width_global = 5,
        .height_global = 3,
        .x_clip = 2,
        .y_clip = 1,
        .width_clip = 2,
        .height_clip = 1,
        .buffer = &tc.buffer,
    };

    try testing.expect(scissor.containsLogical(2, 2));
    try testing.expect(!scissor.containsVisible(2, 2));

    try testing.expect(scissor.containsLogical(3, 2));
    try testing.expect(scissor.containsVisible(3, 2));
}

test "Scissor fill row/column/rectangle clip to visible bounds" {
    var tc = try TestContext.init(6, 4);
    defer tc.deinit();

    const scissor = Scissor{
        .x_global = 0,
        .y_global = 0,
        .width_global = 6,
        .height_global = 4,
        .x_clip = 1,
        .y_clip = 1,
        .width_clip = 3,
        .height_clip = 2,
        .buffer = &tc.buffer,
    };

    scissor.fillRowNarrow(1, Cell{ .data = .{ .codepoint = 'R' } });
    try tc.expectCodepointAt(0, 1, ' ');
    try tc.expectCodepointAt(1, 1, 'R');
    try tc.expectCodepointAt(3, 1, 'R');
    try tc.expectCodepointAt(4, 1, ' ');

    scissor.fillColumnNarrow(2, Cell{ .data = .{ .codepoint = 'C' } });
    try tc.expectCodepointAt(2, 0, ' ');
    try tc.expectCodepointAt(2, 1, 'C');
    try tc.expectCodepointAt(2, 2, 'C');
    try tc.expectCodepointAt(2, 3, ' ');

    scissor.fillRectangleNarrow(0, 0, 6, 4, Cell{ .data = .{ .codepoint = 'F' } });
    for (0..4) |y| {
        for (0..6) |x| {
            const expected: u21 = if (x >= 1 and x < 4 and y >= 1 and y < 3) 'F' else ' ';
            try testing.expectEqual(expected, tc.buffer.get(@intCast(x), @intCast(y)).data.codepoint);
        }
    }
}

test "Scissor.fill and clear clip to visible bounds" {
    var tc = try TestContext.init(6, 4);
    defer tc.deinit();

    tc.scissor().fillNarrow(Cell{ .data = .{ .codepoint = '#' } });

    const scissor = Scissor{
        .x_global = 0,
        .y_global = 0,
        .width_global = 6,
        .height_global = 4,
        .x_clip = 1,
        .y_clip = 1,
        .width_clip = 3,
        .height_clip = 2,
        .buffer = &tc.buffer,
    };

    scissor.fillNarrow(Cell{ .data = .{ .codepoint = 'X' } });
    for (0..4) |y| {
        for (0..6) |x| {
            const expected: u21 = if (x >= 1 and x < 4 and y >= 1 and y < 3) 'X' else '#';
            try testing.expectEqual(expected, tc.buffer.get(@intCast(x), @intCast(y)).data.codepoint);
        }
    }

    scissor.clear();
    for (0..4) |y| {
        for (0..6) |x| {
            const expected: u21 = if (x >= 1 and x < 4 and y >= 1 and y < 3) ' ' else '#';
            try testing.expectEqual(expected, tc.buffer.get(@intCast(x), @intCast(y)).data.codepoint);
        }
    }
}

test "print methods clip rendering to visible bounds" {
    var tc = try TestContext.init(8, 2);
    defer tc.deinit();

    const scissor = Scissor{
        .x_global = 0,
        .y_global = 0,
        .width_global = 6,
        .height_global = 2,
        .x_clip = 2,
        .y_clip = 0,
        .width_clip = 2,
        .height_clip = 2,
        .buffer = &tc.buffer,
    };

    const result = try print(scissor, &TestContext.test_codepoint_buffer, "ABCDE", 0, 0, .default);
    try testing.expectEqual(@as(usize, 5), result.bytes_consumed);
    try testing.expectEqual(@as(usize, 2), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 1), result.lines_used);
    try testing.expectEqual(@as(u16, 5), result.final_x);
    try testing.expectEqual(@as(u16, 0), result.final_y);
    try tc.expectCodepointAt(1, 0, ' ');
    try tc.expectCodepointAt(2, 0, 'C');
    try tc.expectCodepointAt(3, 0, 'D');
    try tc.expectCodepointAt(4, 0, ' ');

    tc.buffer.clear();
    const result_no_grapheme = printAssumeNoGrapheme(scissor, "ABCDE", 0, 0, .default);
    try testing.expectEqual(@as(usize, 5), result_no_grapheme.bytes_consumed);
    try testing.expectEqual(@as(usize, 2), result_no_grapheme.graphemes_rendered);
    try testing.expectEqual(@as(u16, 1), result_no_grapheme.lines_used);
    try testing.expectEqual(@as(u16, 5), result_no_grapheme.final_x);
    try testing.expectEqual(@as(u16, 0), result_no_grapheme.final_y);
    try tc.expectCodepointAt(1, 0, ' ');
    try tc.expectCodepointAt(2, 0, 'C');
    try tc.expectCodepointAt(3, 0, 'D');
    try tc.expectCodepointAt(4, 0, ' ');
}

test "print methods skip wide glyph crossing visible clip edge" {
    var tc = try TestContext.init(6, 2);
    defer tc.deinit();

    const scissor = Scissor{
        .x_global = 0,
        .y_global = 0,
        .width_global = 6,
        .height_global = 2,
        .x_clip = 1,
        .y_clip = 0,
        .width_clip = 2,
        .height_clip = 2,
        .buffer = &tc.buffer,
    };

    const result = try print(scissor, &TestContext.test_codepoint_buffer, "中", 2, 0, .default);
    try testing.expectEqual(@as(usize, 3), result.bytes_consumed);
    try testing.expectEqual(@as(usize, 0), result.graphemes_rendered);
    try testing.expectEqual(@as(u16, 0), result.lines_used);
    try testing.expectEqual(@as(u16, 4), result.final_x);
    try testing.expectEqual(@as(u16, 0), result.final_y);
    try tc.expectCodepointAt(2, 0, ' ');

    const result_no_grapheme = printAssumeNoGrapheme(scissor, "中", 2, 0, .default);
    try testing.expectEqual(@as(usize, 3), result_no_grapheme.bytes_consumed);
    try testing.expectEqual(@as(usize, 0), result_no_grapheme.graphemes_rendered);
    try testing.expectEqual(@as(u16, 0), result_no_grapheme.lines_used);
    try testing.expectEqual(@as(u16, 4), result_no_grapheme.final_x);
    try testing.expectEqual(@as(u16, 0), result_no_grapheme.final_y);
    try tc.expectCodepointAt(2, 0, ' ');
}
