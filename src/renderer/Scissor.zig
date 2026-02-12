const std = @import("std");

const stdx = @import("stdx");
const assert = stdx.inlineAssert;
const layout = @import("layout");
const LayoutRect = layout.Rect;

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

    const child_x = std.math.add(i17, self.x_global, x_offset) catch unreachable;
    const child_y = std.math.add(i17, self.y_global, y_offset) catch unreachable;

    var child = Scissor{
        .x_global = child_x,
        .y_global = child_y,
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

pub inline fn toRect(self: Scissor) LayoutRect {
    self.assertInvariants();
    return .{
        .x = 0,
        .y = 0,
        .width = self.width_global,
        .height = self.height_global,
    };
}

pub inline fn initChildRect(self: Scissor, rect: LayoutRect) Scissor {
    self.assertInvariants();
    return self.initChild(@intCast(rect.x), @intCast(rect.y), rect.width, rect.height);
}

pub inline fn centeredChild(self: Scissor, width: u16, height: u16) Scissor {
    self.assertInvariants();
    return self.initChildRect(self.toRect().centeredChild(width, height));
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
    clearWideBoundaryAtRow(self, y, x_start, x_end);
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
        clearWidePairAt(self, x, @intCast(row));
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
            clearWideBoundaryAtRow(self, row, start_x, end_x);
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

inline fn clearWideBoundaryAtRow(self: Scissor, row: usize, start_x: usize, end_x: usize) void {
    assert(end_x > start_x);
    assert(end_x <= self.buffer.width);

    const y: u16 = @intCast(row);
    const left_x: u16 = @intCast(start_x);
    clearWidePairAt(self, left_x, y);

    if (end_x - start_x > 1) {
        const right_x: u16 = @intCast(end_x - 1);
        clearWidePairAt(self, right_x, y);
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

const ExpectedCell = struct {
    x: u16,
    y: u16,
    codepoint: u21,
    width: ?Cell.Width = null,
    tag: ?Cell.Tag = null,
};

const PrintResultExpectation = struct {
    bytes_consumed: ?usize = null,
    lines_used: ?u16 = null,
    final_x: ?u16 = null,
    final_y: ?u16 = null,
    graphemes_rendered: ?usize = null,
};

const ExpectedGrapheme = struct {
    x: u16,
    y: u16,
    bytes: []const u8,
};

const PrintParityCase = struct {
    width: u16,
    height: u16,
    text: []const u8,
    x: u16 = 0,
    y: u16 = 0,
    options: PrintOptions = .default,
    expected_print: PrintResultExpectation = .{},
    expected_no_grapheme: ?PrintResultExpectation = null,
    expected_cells: []const ExpectedCell,
};

const PrintOnlyCase = struct {
    width: u16,
    height: u16,
    text: []const u8,
    x: u16 = 0,
    y: u16 = 0,
    options: PrintOptions = .default,
    expected_print: PrintResultExpectation = .{},
    expected_cells: []const ExpectedCell,
    expected_graphemes: []const ExpectedGrapheme = &[_]ExpectedGrapheme{},
};

const PrintNoGraphemeCase = struct {
    width: u16,
    height: u16,
    text: []const u8,
    x: u16 = 0,
    y: u16 = 0,
    options: PrintOptions = .default,
    expected_result: PrintResultExpectation = .{},
    expected_cells: []const ExpectedCell,
};

fn expectPrintResult(result: PrintResult, expected: PrintResultExpectation) !void {
    if (expected.bytes_consumed) |bytes_consumed| {
        try testing.expectEqual(bytes_consumed, result.bytes_consumed);
    }
    if (expected.lines_used) |lines_used| {
        try testing.expectEqual(lines_used, result.lines_used);
    }
    if (expected.final_x) |final_x| {
        try testing.expectEqual(final_x, result.final_x);
    }
    if (expected.final_y) |final_y| {
        try testing.expectEqual(final_y, result.final_y);
    }
    if (expected.graphemes_rendered) |graphemes_rendered| {
        try testing.expectEqual(graphemes_rendered, result.graphemes_rendered);
    }
}

fn expectCells(tc: *TestContext, expected_cells: []const ExpectedCell) !void {
    for (expected_cells) |expected| {
        const is_grapheme = expected.tag != null and expected.tag.? == .grapheme;
        if (!is_grapheme) {
            try tc.expectCodepointAt(expected.x, expected.y, expected.codepoint);
        }
        if (expected.width) |width| {
            try tc.expectCellWidth(expected.x, expected.y, width);
        }
        if (expected.tag) |tag| {
            try tc.expectCellTag(expected.x, expected.y, tag);
        }
    }
}

fn runPrintParityCase(tc: *TestContext, case: PrintParityCase) !void {
    const result = try print(
        tc.scissor(),
        &TestContext.test_codepoint_buffer,
        case.text,
        case.x,
        case.y,
        case.options,
    );
    try expectPrintResult(result, case.expected_print);
    try expectCells(tc, case.expected_cells);

    tc.buffer.clear();
    const result_no_grapheme = printAssumeNoGrapheme(tc.scissor(), case.text, case.x, case.y, case.options);
    const expected_no_grapheme = case.expected_no_grapheme orelse case.expected_print;
    try expectPrintResult(result_no_grapheme, expected_no_grapheme);
    try expectCells(tc, case.expected_cells);
}

fn runPrintCase(tc: *TestContext, case: PrintOnlyCase) !void {
    const result = try print(
        tc.scissor(),
        &TestContext.test_codepoint_buffer,
        case.text,
        case.x,
        case.y,
        case.options,
    );
    try expectPrintResult(result, case.expected_print);
    try expectCells(tc, case.expected_cells);
    for (case.expected_graphemes) |expected_grapheme| {
        const grapheme = tc.getGraphemeAt(expected_grapheme.x, expected_grapheme.y);
        try testing.expect(grapheme != null);
        try testing.expectEqualStrings(expected_grapheme.bytes, grapheme.?);
    }
}

fn runPrintNoGraphemeCase(tc: *TestContext, case: PrintNoGraphemeCase) !void {
    const result = printAssumeNoGrapheme(tc.scissor(), case.text, case.x, case.y, case.options);
    try expectPrintResult(result, case.expected_result);
    try expectCells(tc, case.expected_cells);
}

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

test "print parity ASCII and wrapping table cases" {
    const cases = [_]PrintParityCase{
        .{
            .width = 10,
            .height = 5,
            .text = "Hello",
            .expected_print = .{
                .bytes_consumed = 5,
                .lines_used = 1,
                .final_x = 5,
                .final_y = 0,
                .graphemes_rendered = 5,
            },
            .expected_cells = &[_]ExpectedCell{
                .{ .x = 0, .y = 0, .codepoint = 'H', .width = .narrow },
                .{ .x = 1, .y = 0, .codepoint = 'e' },
                .{ .x = 2, .y = 0, .codepoint = 'l' },
                .{ .x = 3, .y = 0, .codepoint = 'l' },
                .{ .x = 4, .y = 0, .codepoint = 'o', .width = .narrow },
            },
        },
        .{
            .width = 10,
            .height = 5,
            .text = "Hi",
            .x = 3,
            .y = 2,
            .expected_print = .{ .bytes_consumed = 2, .final_x = 5, .final_y = 2, .graphemes_rendered = 2 },
            .expected_cells = &[_]ExpectedCell{
                .{ .x = 3, .y = 2, .codepoint = 'H' },
                .{ .x = 4, .y = 2, .codepoint = 'i' },
                .{ .x = 0, .y = 0, .codepoint = ' ' },
                .{ .x = 2, .y = 2, .codepoint = ' ' },
            },
        },
        .{
            .width = 5,
            .height = 5,
            .text = "Hello World",
            .expected_print = .{ .lines_used = 1, .graphemes_rendered = 5 },
            .expected_cells = &[_]ExpectedCell{
                .{ .x = 0, .y = 0, .codepoint = 'H' },
                .{ .x = 1, .y = 0, .codepoint = 'e' },
                .{ .x = 2, .y = 0, .codepoint = 'l' },
                .{ .x = 3, .y = 0, .codepoint = 'l' },
                .{ .x = 4, .y = 0, .codepoint = 'o' },
            },
        },
        .{
            .width = 10,
            .height = 5,
            .text = "",
            .expected_print = .{ .bytes_consumed = 0, .lines_used = 0, .graphemes_rendered = 0 },
            .expected_cells = &[_]ExpectedCell{},
        },
        .{
            .width = 10,
            .height = 5,
            .text = "Hello",
            .y = 10,
            .expected_print = .{ .lines_used = 0, .graphemes_rendered = 0 },
            .expected_cells = &[_]ExpectedCell{},
        },
        .{
            .width = 10,
            .height = 5,
            .text = "Hello",
            .x = 15,
            .expected_print = .{ .graphemes_rendered = 0 },
            .expected_cells = &[_]ExpectedCell{},
        },
        .{
            .width = 5,
            .height = 3,
            .text = "ABCDEFGHIJ",
            .options = .{ .wrap = true, .tab_width = 4 },
            .expected_print = .{ .lines_used = 2, .final_x = 0, .final_y = 2, .graphemes_rendered = 10 },
            .expected_cells = &[_]ExpectedCell{
                .{ .x = 0, .y = 0, .codepoint = 'A' },
                .{ .x = 4, .y = 0, .codepoint = 'E' },
                .{ .x = 0, .y = 1, .codepoint = 'F' },
                .{ .x = 4, .y = 1, .codepoint = 'J' },
            },
        },
        .{
            .width = 5,
            .height = 2,
            .text = "ABCDEFGHIJKLMNO",
            .options = .{ .wrap = true, .tab_width = 4 },
            .expected_print = .{ .lines_used = 2, .graphemes_rendered = 10 },
            .expected_cells = &[_]ExpectedCell{
                .{ .x = 0, .y = 0, .codepoint = 'A' },
                .{ .x = 4, .y = 0, .codepoint = 'E' },
                .{ .x = 0, .y = 1, .codepoint = 'F' },
                .{ .x = 4, .y = 1, .codepoint = 'J' },
            },
        },
        .{
            .width = 5,
            .height = 3,
            .text = "Hello World",
            .options = .{ .wrap = false, .tab_width = 4 },
            .expected_print = .{ .lines_used = 1, .graphemes_rendered = 5 },
            .expected_cells = &[_]ExpectedCell{
                .{ .x = 0, .y = 0, .codepoint = 'H' },
                .{ .x = 4, .y = 0, .codepoint = 'o' },
                .{ .x = 0, .y = 1, .codepoint = ' ' },
            },
        },
        .{
            .width = 5,
            .height = 3,
            .text = "ABCDEFG",
            .x = 3,
            .options = .{ .wrap = true, .tab_width = 4 },
            .expected_print = .{ .lines_used = 2, .final_x = 0, .final_y = 2, .graphemes_rendered = 7 },
            .expected_cells = &[_]ExpectedCell{
                .{ .x = 3, .y = 0, .codepoint = 'A' },
                .{ .x = 4, .y = 0, .codepoint = 'B' },
                .{ .x = 0, .y = 1, .codepoint = 'C' },
                .{ .x = 4, .y = 1, .codepoint = 'G' },
            },
        },
        .{
            .width = 3,
            .height = 5,
            .text = "ABCDEFGHI",
            .options = .{ .wrap = true, .tab_width = 4 },
            .expected_print = .{ .lines_used = 3, .final_x = 0, .final_y = 3, .graphemes_rendered = 9 },
            .expected_cells = &[_]ExpectedCell{
                .{ .x = 0, .y = 0, .codepoint = 'A' },
                .{ .x = 2, .y = 0, .codepoint = 'C' },
                .{ .x = 0, .y = 1, .codepoint = 'D' },
                .{ .x = 2, .y = 1, .codepoint = 'F' },
                .{ .x = 0, .y = 2, .codepoint = 'G' },
                .{ .x = 2, .y = 2, .codepoint = 'I' },
            },
        },
        .{
            .width = 10,
            .height = 5,
            .text = "AB\nCD",
            .expected_print = .{
                .bytes_consumed = 5,
                .lines_used = 2,
                .final_x = 2,
                .final_y = 1,
                .graphemes_rendered = 4,
            },
            .expected_cells = &[_]ExpectedCell{
                .{ .x = 0, .y = 0, .codepoint = 'A' },
                .{ .x = 1, .y = 0, .codepoint = 'B' },
                .{ .x = 0, .y = 1, .codepoint = 'C' },
                .{ .x = 1, .y = 1, .codepoint = 'D' },
            },
        },
        .{
            .width = 10,
            .height = 5,
            .text = "A\n\n\nB",
            .expected_print = .{
                .bytes_consumed = 5,
                .lines_used = 4,
                .final_x = 1,
                .final_y = 3,
                .graphemes_rendered = 2,
            },
            .expected_cells = &[_]ExpectedCell{
                .{ .x = 0, .y = 0, .codepoint = 'A' },
                .{ .x = 0, .y = 1, .codepoint = ' ' },
                .{ .x = 0, .y = 2, .codepoint = ' ' },
                .{ .x = 0, .y = 3, .codepoint = 'B' },
            },
        },
    };

    for (cases) |case| {
        var tc = try TestContext.init(case.width, case.height);
        defer tc.deinit();
        try runPrintParityCase(&tc, case);
    }
}

test "print newline and carriage table cases" {
    const cases = [_]PrintOnlyCase{
        .{
            .width = 10,
            .height = 5,
            .text = "Hello\n",
            .expected_print = .{
                .bytes_consumed = 6,
                .lines_used = 2,
                .final_x = 0,
                .final_y = 1,
                .graphemes_rendered = 5,
            },
            .expected_cells = &[_]ExpectedCell{
                .{ .x = 0, .y = 0, .codepoint = 'H' },
                .{ .x = 4, .y = 0, .codepoint = 'o' },
            },
        },
        .{
            .width = 10,
            .height = 5,
            .text = "AB\rCD",
            .expected_print = .{
                .bytes_consumed = 5,
                .lines_used = 1,
                .final_x = 4,
                .final_y = 0,
                .graphemes_rendered = 4,
            },
            .expected_cells = &[_]ExpectedCell{
                .{ .x = 0, .y = 0, .codepoint = 'A' },
                .{ .x = 1, .y = 0, .codepoint = 'B' },
                .{ .x = 2, .y = 0, .codepoint = 'C' },
                .{ .x = 3, .y = 0, .codepoint = 'D' },
            },
        },
        .{
            .width = 10,
            .height = 5,
            .text = "AB\r\nCD",
            .expected_print = .{
                .bytes_consumed = 6,
                .lines_used = 2,
                .final_x = 2,
                .final_y = 1,
                .graphemes_rendered = 4,
            },
            .expected_cells = &[_]ExpectedCell{
                .{ .x = 0, .y = 0, .codepoint = 'A' },
                .{ .x = 1, .y = 0, .codepoint = 'B' },
                .{ .x = 0, .y = 1, .codepoint = 'C' },
                .{ .x = 1, .y = 1, .codepoint = 'D' },
            },
        },
        .{
            .width = 10,
            .height = 5,
            .text = "AB\nCD",
            .x = 3,
            .y = 1,
            .expected_print = .{
                .lines_used = 2,
                .final_x = 2,
                .final_y = 2,
            },
            .expected_cells = &[_]ExpectedCell{
                .{ .x = 3, .y = 1, .codepoint = 'A' },
                .{ .x = 4, .y = 1, .codepoint = 'B' },
                .{ .x = 0, .y = 2, .codepoint = 'C' },
                .{ .x = 1, .y = 2, .codepoint = 'D' },
            },
        },
    };

    for (cases) |case| {
        var tc = try TestContext.init(case.width, case.height);
        defer tc.deinit();
        try runPrintCase(&tc, case);
    }
}

test "print parity tab behavior table cases" {
    const cases = [_]PrintParityCase{
        .{
            .width = 10,
            .height = 5,
            .text = "A\tB",
            .options = .{ .wrap = false, .tab_width = 4 },
            .expected_print = .{
                .bytes_consumed = 3,
                .lines_used = 1,
                .final_x = 5,
                .final_y = 0,
                .graphemes_rendered = 5,
            },
            .expected_cells = &[_]ExpectedCell{
                .{ .x = 0, .y = 0, .codepoint = 'A' },
                .{ .x = 1, .y = 0, .codepoint = ' ' },
                .{ .x = 2, .y = 0, .codepoint = ' ' },
                .{ .x = 3, .y = 0, .codepoint = ' ' },
                .{ .x = 4, .y = 0, .codepoint = 'B' },
            },
        },
        .{
            .width = 10,
            .height = 5,
            .text = "\tX",
            .x = 4,
            .options = .{ .wrap = false, .tab_width = 4 },
            .expected_print = .{ .final_x = 9, .graphemes_rendered = 5 },
            .expected_cells = &[_]ExpectedCell{
                .{ .x = 4, .y = 0, .codepoint = ' ' },
                .{ .x = 5, .y = 0, .codepoint = ' ' },
                .{ .x = 6, .y = 0, .codepoint = ' ' },
                .{ .x = 7, .y = 0, .codepoint = ' ' },
                .{ .x = 8, .y = 0, .codepoint = 'X' },
            },
        },
        .{
            .width = 5,
            .height = 3,
            .text = "\tX",
            .x = 3,
            .options = .{ .wrap = true, .tab_width = 4 },
            .expected_print = .{ .final_x = 0, .final_y = 1, .graphemes_rendered = 2 },
            .expected_cells = &[_]ExpectedCell{
                .{ .x = 3, .y = 0, .codepoint = ' ' },
                .{ .x = 4, .y = 0, .codepoint = 'X' },
            },
        },
        .{
            .width = 5,
            .height = 3,
            .text = "\tX",
            .x = 4,
            .options = .{ .wrap = true, .tab_width = 4 },
            .expected_print = .{ .lines_used = 2, .final_x = 1, .final_y = 1, .graphemes_rendered = 2 },
            .expected_cells = &[_]ExpectedCell{
                .{ .x = 4, .y = 0, .codepoint = ' ' },
                .{ .x = 0, .y = 1, .codepoint = 'X' },
            },
        },
        .{
            .width = 20,
            .height = 5,
            .text = "A\tB",
            .options = .{ .wrap = false, .tab_width = 8 },
            .expected_print = .{ .final_x = 9, .graphemes_rendered = 9 },
            .expected_cells = &[_]ExpectedCell{
                .{ .x = 0, .y = 0, .codepoint = 'A' },
                .{ .x = 7, .y = 0, .codepoint = ' ' },
                .{ .x = 8, .y = 0, .codepoint = 'B' },
            },
        },
        .{
            .width = 5,
            .height = 3,
            .text = "\tXY",
            .x = 3,
            .options = .{ .wrap = false, .tab_width = 4 },
            .expected_print = .{ .final_x = 0, .final_y = 1, .graphemes_rendered = 2 },
            .expected_cells = &[_]ExpectedCell{
                .{ .x = 3, .y = 0, .codepoint = ' ' },
                .{ .x = 4, .y = 0, .codepoint = 'X' },
                .{ .x = 0, .y = 1, .codepoint = ' ' },
            },
        },
        .{
            .width = 20,
            .height = 5,
            .text = "A\t\tB",
            .options = .{ .wrap = false, .tab_width = 4 },
            .expected_print = .{ .final_x = 9, .graphemes_rendered = 9 },
            .expected_cells = &[_]ExpectedCell{
                .{ .x = 0, .y = 0, .codepoint = 'A' },
                .{ .x = 4, .y = 0, .codepoint = ' ' },
                .{ .x = 8, .y = 0, .codepoint = 'B' },
            },
        },
    };

    for (cases) |case| {
        var tc = try TestContext.init(case.width, case.height);
        defer tc.deinit();
        try runPrintParityCase(&tc, case);
    }
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

test "print parity unicode and wide table cases" {
    const cases = [_]PrintParityCase{
        .{
            .width = 10,
            .height = 5,
            .text = "café",
            .expected_print = .{
                .bytes_consumed = 5,
                .graphemes_rendered = 4,
                .final_x = 4,
            },
            .expected_cells = &[_]ExpectedCell{
                .{ .x = 0, .y = 0, .codepoint = 'c' },
                .{ .x = 1, .y = 0, .codepoint = 'a' },
                .{ .x = 2, .y = 0, .codepoint = 'f' },
                .{ .x = 3, .y = 0, .codepoint = 0xE9, .width = .narrow, .tag = .codepoint },
            },
        },
        .{
            .width = 10,
            .height = 5,
            .text = "中文",
            .expected_print = .{
                .bytes_consumed = 6,
                .graphemes_rendered = 2,
                .final_x = 4,
            },
            .expected_cells = &[_]ExpectedCell{
                .{ .x = 0, .y = 0, .codepoint = 0x4E2D, .width = .wide_start },
                .{ .x = 1, .y = 0, .codepoint = ' ', .width = .wide_end },
                .{ .x = 2, .y = 0, .codepoint = 0x6587, .width = .wide_start },
                .{ .x = 3, .y = 0, .codepoint = ' ', .width = .wide_end },
            },
        },
        .{
            .width = 10,
            .height = 5,
            .text = "😀",
            .expected_print = .{
                .bytes_consumed = 4,
                .graphemes_rendered = 1,
                .final_x = 2,
            },
            .expected_cells = &[_]ExpectedCell{
                .{ .x = 0, .y = 0, .codepoint = 0x1F600, .width = .wide_start },
                .{ .x = 1, .y = 0, .codepoint = ' ', .width = .wide_end },
            },
        },
        .{
            .width = 3,
            .height = 3,
            .text = "AB中",
            .options = .{ .wrap = false, .tab_width = 4 },
            .expected_print = .{
                .graphemes_rendered = 2,
                .final_x = 0,
                .final_y = 1,
            },
            .expected_cells = &[_]ExpectedCell{
                .{ .x = 0, .y = 0, .codepoint = 'A', .width = .narrow },
                .{ .x = 1, .y = 0, .codepoint = 'B', .width = .narrow },
                .{ .x = 2, .y = 0, .codepoint = ' ', .width = .narrow },
            },
        },
        .{
            .width = 4,
            .height = 3,
            .text = "AB中",
            .expected_print = .{
                .graphemes_rendered = 3,
                .final_x = 0,
                .final_y = 1,
            },
            .expected_cells = &[_]ExpectedCell{
                .{ .x = 0, .y = 0, .codepoint = 'A' },
                .{ .x = 1, .y = 0, .codepoint = 'B' },
                .{ .x = 2, .y = 0, .codepoint = 0x4E2D, .width = .wide_start },
                .{ .x = 3, .y = 0, .codepoint = ' ', .width = .wide_end },
            },
        },
        .{
            .width = 10,
            .height = 2,
            .text = "A\nB\nC",
            .expected_print = .{ .lines_used = 2, .graphemes_rendered = 2 },
            .expected_cells = &[_]ExpectedCell{
                .{ .x = 0, .y = 0, .codepoint = 'A' },
                .{ .x = 0, .y = 1, .codepoint = 'B' },
            },
        },
    };

    for (cases) |case| {
        var tc = try TestContext.init(case.width, case.height);
        defer tc.deinit();
        try runPrintParityCase(&tc, case);
    }
}

test "print advanced unicode and boundary table cases" {
    const family = "\xF0\x9F\x91\xA8\xE2\x80\x8D\xF0\x9F\x91\xA9\xE2\x80\x8D\xF0\x9F\x91\xA7\xE2\x80\x8D\xF0\x9F\x91\xA6";
    const family_short = "\xF0\x9F\x91\xA8\xE2\x80\x8D\xF0\x9F\x91\xA9\xE2\x80\x8D\xF0\x9F\x91\xA7";
    const heart_emoji = "\xE2\x9D\xA4\xEF\xB8\x8F";
    const heart_text = "\xE2\x9D\xA4";
    const flag_us = "\xF0\x9F\x87\xBA\xF0\x9F\x87\xB8";
    const flag_uk = "\xF0\x9F\x87\xAC\xF0\x9F\x87\xA7";
    const flags = flag_us ++ flag_uk;
    const man_tone = "\xF0\x9F\x91\xA8\xF0\x9F\x8F\xBD";

    const cases = [_]PrintOnlyCase{
        .{
            .width = 10,
            .height = 5,
            .text = "e\xCC\x81",
            .expected_print = .{ .bytes_consumed = 3, .graphemes_rendered = 1, .final_x = 1 },
            .expected_cells = &[_]ExpectedCell{
                .{ .x = 0, .y = 0, .codepoint = 'e', .width = .narrow, .tag = .grapheme },
            },
            .expected_graphemes = &[_]ExpectedGrapheme{
                .{ .x = 0, .y = 0, .bytes = "e\xCC\x81" },
            },
        },
        .{
            .width = 10,
            .height = 5,
            .text = "a\xCC\x81\xCC\x82",
            .expected_print = .{ .bytes_consumed = 5, .graphemes_rendered = 1 },
            .expected_cells = &[_]ExpectedCell{
                .{ .x = 0, .y = 0, .codepoint = 'a', .tag = .grapheme },
            },
            .expected_graphemes = &[_]ExpectedGrapheme{
                .{ .x = 0, .y = 0, .bytes = "a\xCC\x81\xCC\x82" },
            },
        },
        .{
            .width = 20,
            .height = 5,
            .text = "Hello café!",
            .expected_print = .{ .bytes_consumed = 12, .graphemes_rendered = 11, .final_x = 11 },
            .expected_cells = &[_]ExpectedCell{
                .{ .x = 0, .y = 0, .codepoint = 'H' },
                .{ .x = 5, .y = 0, .codepoint = ' ' },
                .{ .x = 6, .y = 0, .codepoint = 'c' },
                .{ .x = 7, .y = 0, .codepoint = 'a' },
                .{ .x = 8, .y = 0, .codepoint = 'f' },
                .{ .x = 9, .y = 0, .codepoint = 0xE9 },
                .{ .x = 10, .y = 0, .codepoint = '!' },
            },
        },
        .{
            .width = 5,
            .height = 3,
            .text = "ABCDe\xCC\x81F",
            .options = .{ .wrap = true, .tab_width = 4 },
            .expected_print = .{ .graphemes_rendered = 6, .lines_used = 2 },
            .expected_cells = &[_]ExpectedCell{
                .{ .x = 0, .y = 0, .codepoint = 'A' },
                .{ .x = 4, .y = 0, .codepoint = 'e', .tag = .grapheme },
                .{ .x = 0, .y = 1, .codepoint = 'F' },
            },
        },
        .{
            .width = 3,
            .height = 3,
            .text = "ABéC",
            .expected_print = .{ .graphemes_rendered = 3 },
            .expected_cells = &[_]ExpectedCell{
                .{ .x = 0, .y = 0, .codepoint = 'A' },
                .{ .x = 1, .y = 0, .codepoint = 'B' },
                .{ .x = 2, .y = 0, .codepoint = 0xE9 },
            },
        },
        .{
            .width = 3,
            .height = 3,
            .text = "AB中",
            .options = .{ .wrap = true, .tab_width = 4 },
            .expected_print = .{ .graphemes_rendered = 3, .lines_used = 2, .final_x = 2, .final_y = 1 },
            .expected_cells = &[_]ExpectedCell{
                .{ .x = 0, .y = 0, .codepoint = 'A', .width = .narrow },
                .{ .x = 1, .y = 0, .codepoint = 'B', .width = .narrow },
                .{ .x = 0, .y = 1, .codepoint = 0x4E2D, .width = .wide_start },
                .{ .x = 1, .y = 1, .codepoint = ' ', .width = .wide_end },
            },
        },
        .{
            .width = 4,
            .height = 3,
            .text = "中文字",
            .options = .{ .wrap = true, .tab_width = 4 },
            .expected_print = .{ .graphemes_rendered = 3, .lines_used = 2, .final_x = 2, .final_y = 1 },
            .expected_cells = &[_]ExpectedCell{
                .{ .x = 0, .y = 0, .codepoint = 0x4E2D, .width = .wide_start },
                .{ .x = 2, .y = 0, .codepoint = 0x6587, .width = .wide_start },
                .{ .x = 0, .y = 1, .codepoint = 0x5B57, .width = .wide_start },
            },
        },
        .{
            .width = 10,
            .height = 5,
            .text = "Hello中文!",
            .expected_print = .{ .graphemes_rendered = 8, .final_x = 0, .final_y = 1 },
            .expected_cells = &[_]ExpectedCell{
                .{ .x = 0, .y = 0, .codepoint = 'H', .width = .narrow },
                .{ .x = 5, .y = 0, .codepoint = 0x4E2D, .width = .wide_start },
                .{ .x = 7, .y = 0, .codepoint = 0x6587, .width = .wide_start },
                .{ .x = 9, .y = 0, .codepoint = '!', .width = .narrow },
            },
        },
        .{
            .width = 10,
            .height = 5,
            .text = family,
            .expected_print = .{ .bytes_consumed = 25, .graphemes_rendered = 1, .final_x = 2 },
            .expected_cells = &[_]ExpectedCell{
                .{ .x = 0, .y = 0, .codepoint = 0, .width = .wide_start, .tag = .grapheme },
                .{ .x = 1, .y = 0, .codepoint = ' ', .width = .wide_end },
            },
            .expected_graphemes = &[_]ExpectedGrapheme{
                .{ .x = 0, .y = 0, .bytes = family },
            },
        },
        .{
            .width = 10,
            .height = 5,
            .text = heart_emoji,
            .expected_print = .{ .bytes_consumed = 6, .graphemes_rendered = 1, .final_x = 2 },
            .expected_cells = &[_]ExpectedCell{
                .{ .x = 0, .y = 0, .codepoint = 0, .width = .wide_start, .tag = .grapheme },
                .{ .x = 1, .y = 0, .codepoint = ' ', .width = .wide_end },
            },
            .expected_graphemes = &[_]ExpectedGrapheme{
                .{ .x = 0, .y = 0, .bytes = heart_emoji },
            },
        },
        .{
            .width = 10,
            .height = 5,
            .text = heart_text,
            .expected_print = .{ .bytes_consumed = 3, .graphemes_rendered = 1, .final_x = 1 },
            .expected_cells = &[_]ExpectedCell{
                .{ .x = 0, .y = 0, .codepoint = 0x2764, .width = .narrow, .tag = .codepoint },
            },
        },
        .{
            .width = 10,
            .height = 5,
            .text = flags,
            .expected_print = .{ .bytes_consumed = 16, .graphemes_rendered = 2, .final_x = 4 },
            .expected_cells = &[_]ExpectedCell{
                .{ .x = 0, .y = 0, .codepoint = 0, .width = .wide_start, .tag = .grapheme },
                .{ .x = 1, .y = 0, .codepoint = ' ', .width = .wide_end },
                .{ .x = 2, .y = 0, .codepoint = 0, .width = .wide_start, .tag = .grapheme },
                .{ .x = 3, .y = 0, .codepoint = ' ', .width = .wide_end },
            },
            .expected_graphemes = &[_]ExpectedGrapheme{
                .{ .x = 0, .y = 0, .bytes = flag_us },
                .{ .x = 2, .y = 0, .bytes = flag_uk },
            },
        },
        .{
            .width = 3,
            .height = 3,
            .text = "A" ++ man_tone,
            .options = .{ .wrap = true, .tab_width = 4 },
            .expected_print = .{ .graphemes_rendered = 2, .final_x = 0, .final_y = 1 },
            .expected_cells = &[_]ExpectedCell{
                .{ .x = 0, .y = 0, .codepoint = 'A', .width = .narrow },
                .{ .x = 1, .y = 0, .codepoint = 0, .width = .wide_start, .tag = .grapheme },
                .{ .x = 2, .y = 0, .codepoint = ' ', .width = .wide_end },
            },
        },
        .{
            .width = 3,
            .height = 3,
            .text = "AB" ++ man_tone,
            .options = .{ .wrap = true, .tab_width = 4 },
            .expected_print = .{ .graphemes_rendered = 3, .lines_used = 2, .final_x = 2, .final_y = 1 },
            .expected_cells = &[_]ExpectedCell{
                .{ .x = 0, .y = 0, .codepoint = 'A' },
                .{ .x = 1, .y = 0, .codepoint = 'B' },
                .{ .x = 0, .y = 1, .codepoint = 0, .width = .wide_start, .tag = .grapheme },
                .{ .x = 1, .y = 1, .codepoint = ' ', .width = .wide_end },
            },
        },
        .{
            .width = 20,
            .height = 5,
            .text = "Hello " ++ family_short ++ " 世界!",
            .expected_print = .{ .graphemes_rendered = 11, .final_x = 14 },
            .expected_cells = &[_]ExpectedCell{
                .{ .x = 0, .y = 0, .codepoint = 'H' },
                .{ .x = 5, .y = 0, .codepoint = ' ' },
                .{ .x = 6, .y = 0, .codepoint = 0, .width = .wide_start, .tag = .grapheme },
                .{ .x = 8, .y = 0, .codepoint = ' ' },
                .{ .x = 9, .y = 0, .codepoint = 0x4E16, .width = .wide_start },
                .{ .x = 13, .y = 0, .codepoint = '!' },
            },
            .expected_graphemes = &[_]ExpectedGrapheme{
                .{ .x = 6, .y = 0, .bytes = family_short },
            },
        },
        .{
            .width = 20,
            .height = 5,
            .text = "Hello \xE4\xB8\x96\xE7\x95\x8C!\n\tTab \xF0\x9F\x98\x80",
            .options = .{ .wrap = true, .tab_width = 4 },
            .expected_print = .{ .lines_used = 2 },
            .expected_cells = &[_]ExpectedCell{
                .{ .x = 0, .y = 0, .codepoint = 'H' },
                .{ .x = 6, .y = 0, .codepoint = 0x4E16, .width = .wide_start },
                .{ .x = 10, .y = 0, .codepoint = '!' },
                .{ .x = 0, .y = 1, .codepoint = ' ' },
                .{ .x = 4, .y = 1, .codepoint = 'T' },
            },
        },
        .{
            .width = 10,
            .height = 5,
            .text = "\xFF\xFE",
            .expected_print = .{ .bytes_consumed = 2, .graphemes_rendered = 2, .final_x = 2 },
            .expected_cells = &[_]ExpectedCell{
                .{ .x = 0, .y = 0, .codepoint = 0xFFFD },
                .{ .x = 1, .y = 0, .codepoint = 0xFFFD },
            },
        },
        .{
            .width = 5,
            .height = 2,
            .text = "ABCDE",
            .options = .{ .wrap = true, .tab_width = 4 },
            .expected_print = .{ .graphemes_rendered = 5, .lines_used = 1, .final_x = 0, .final_y = 1 },
            .expected_cells = &[_]ExpectedCell{
                .{ .x = 0, .y = 0, .codepoint = 'A' },
                .{ .x = 4, .y = 0, .codepoint = 'E' },
            },
        },
        .{
            .width = 4,
            .height = 2,
            .text = "AB\xE4\xB8\xAD",
            .options = .{ .wrap = true, .tab_width = 4 },
            .expected_print = .{ .graphemes_rendered = 3, .lines_used = 1, .final_x = 0, .final_y = 1 },
            .expected_cells = &[_]ExpectedCell{
                .{ .x = 0, .y = 0, .codepoint = 'A' },
                .{ .x = 1, .y = 0, .codepoint = 'B' },
                .{ .x = 2, .y = 0, .codepoint = 0x4E2D, .width = .wide_start },
                .{ .x = 3, .y = 0, .codepoint = ' ', .width = .wide_end },
            },
        },
    };

    for (cases) |case| {
        var tc = try TestContext.init(case.width, case.height);
        defer tc.deinit();
        try runPrintCase(&tc, case);
    }
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

test "printAssumeNoGrapheme table cases" {
    const cases = [_]PrintNoGraphemeCase{
        .{
            .width = 10,
            .height = 5,
            .text = "AB\r\nCD",
            .expected_result = .{
                .bytes_consumed = 6,
                .lines_used = 2,
                .graphemes_rendered = 4,
                .final_x = 2,
                .final_y = 1,
            },
            .expected_cells = &[_]ExpectedCell{
                .{ .x = 0, .y = 0, .codepoint = 'A' },
                .{ .x = 1, .y = 0, .codepoint = 'B' },
                .{ .x = 0, .y = 1, .codepoint = 'C' },
                .{ .x = 1, .y = 1, .codepoint = 'D' },
            },
        },
        .{
            .width = 10,
            .height = 5,
            .text = "A\tB",
            .options = .{ .wrap = false, .tab_width = 0 },
            .expected_result = .{
                .graphemes_rendered = 2,
                .final_x = 2,
            },
            .expected_cells = &[_]ExpectedCell{
                .{ .x = 0, .y = 0, .codepoint = 'A' },
                .{ .x = 1, .y = 0, .codepoint = 'B' },
            },
        },
        .{
            .width = 10,
            .height = 5,
            .text = "A\xCC\x81B",
            .expected_result = .{
                .bytes_consumed = 4,
                .graphemes_rendered = 2,
                .final_x = 2,
            },
            .expected_cells = &[_]ExpectedCell{
                .{ .x = 0, .y = 0, .codepoint = 'A' },
                .{ .x = 1, .y = 0, .codepoint = 'B' },
            },
        },
        .{
            .width = 10,
            .height = 5,
            .text = "A\xE2\x80\x8DB",
            .expected_result = .{
                .bytes_consumed = 5,
                .graphemes_rendered = 2,
            },
            .expected_cells = &[_]ExpectedCell{
                .{ .x = 0, .y = 0, .codepoint = 'A' },
                .{ .x = 1, .y = 0, .codepoint = 'B' },
            },
        },
        .{
            .width = 10,
            .height = 5,
            .text = "\xFF\xFE",
            .expected_result = .{
                .bytes_consumed = 2,
                .graphemes_rendered = 2,
                .final_x = 2,
            },
            .expected_cells = &[_]ExpectedCell{
                .{ .x = 0, .y = 0, .codepoint = 0xFFFD },
                .{ .x = 1, .y = 0, .codepoint = 0xFFFD },
            },
        },
        .{
            .width = 10,
            .height = 5,
            .text = "\xC3\xFF",
            .expected_result = .{
                .bytes_consumed = 2,
                .graphemes_rendered = 2,
            },
            .expected_cells = &[_]ExpectedCell{
                .{ .x = 0, .y = 0, .codepoint = 0xFFFD },
                .{ .x = 1, .y = 0, .codepoint = 0xFFFD },
            },
        },
    };

    for (cases) |case| {
        var tc = try TestContext.init(case.width, case.height);
        defer tc.deinit();
        try runPrintNoGraphemeCase(&tc, case);
    }
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

test "Scissor.fillRowNarrow repairs wide pairs at clip boundaries" {
    var tc = try TestContext.init(6, 2);
    defer tc.deinit();

    const full = tc.scissor();
    try full.set(1, 0, Cell{ .data = .{ .codepoint = 0x4E2D }, .width = .wide_start });
    try full.set(3, 0, Cell{ .data = .{ .codepoint = 0x6587 }, .width = .wide_start });

    const clipped = Scissor{
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

    clipped.fillRowNarrow(0, Cell{ .data = .{ .codepoint = 'R' } });

    try tc.expectCodepointAt(1, 0, ' ');
    try tc.expectCodepointAt(2, 0, 'R');
    try tc.expectCodepointAt(3, 0, 'R');
    try tc.expectCodepointAt(4, 0, ' ');
    try tc.expectCellWidth(1, 0, .narrow);
    try tc.expectCellWidth(4, 0, .narrow);
}

test "Scissor.fillColumnNarrow repairs wide pairs at clip boundaries" {
    var tc = try TestContext.init(6, 2);
    defer tc.deinit();

    const full = tc.scissor();
    try full.set(1, 0, Cell{ .data = .{ .codepoint = 0x4E2D }, .width = .wide_start });
    try full.set(2, 1, Cell{ .data = .{ .codepoint = 0x6587 }, .width = .wide_start });

    const clipped = Scissor{
        .x_global = 0,
        .y_global = 0,
        .width_global = 6,
        .height_global = 2,
        .x_clip = 2,
        .y_clip = 0,
        .width_clip = 1,
        .height_clip = 2,
        .buffer = &tc.buffer,
    };

    clipped.fillColumnNarrow(2, Cell{ .data = .{ .codepoint = 'C' } });

    try tc.expectCodepointAt(1, 0, ' ');
    try tc.expectCodepointAt(2, 0, 'C');
    try tc.expectCodepointAt(2, 1, 'C');
    try tc.expectCodepointAt(3, 1, ' ');
    try tc.expectCellWidth(1, 0, .narrow);
    try tc.expectCellWidth(3, 1, .narrow);
}

test "Scissor.fillRectangleNarrow repairs wide pairs at horizontal boundaries" {
    var tc = try TestContext.init(6, 3);
    defer tc.deinit();

    const full = tc.scissor();
    try full.set(1, 0, Cell{ .data = .{ .codepoint = 0x4E2D }, .width = .wide_start });
    try full.set(3, 0, Cell{ .data = .{ .codepoint = 0x6587 }, .width = .wide_start });
    try full.set(1, 1, Cell{ .data = .{ .codepoint = 0x4E2D }, .width = .wide_start });
    try full.set(3, 1, Cell{ .data = .{ .codepoint = 0x6587 }, .width = .wide_start });

    full.fillRectangleNarrow(2, 0, 2, 2, Cell{ .data = .{ .codepoint = 'F' } });

    for (0..2) |row| {
        try tc.expectCodepointAt(1, @intCast(row), ' ');
        try tc.expectCodepointAt(2, @intCast(row), 'F');
        try tc.expectCodepointAt(3, @intCast(row), 'F');
        try tc.expectCodepointAt(4, @intCast(row), ' ');
        try tc.expectCellWidth(1, @intCast(row), .narrow);
        try tc.expectCellWidth(4, @intCast(row), .narrow);
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
