const std = @import("std");

const stdx = @import("stdx");
const assert = stdx.inlineAssert;
const FixedGrowingBufferAllocator = stdx.FixedGrowingBufferAllocator;
const seq = @import("terminal").sequences;

const t = @import("types.zig");
const GraphemeIndex = t.GraphemeBuffer.GraphemeIndex;

pub const CellSize = u64;
pub const Cell = packed struct(CellSize) {
    data: Data = .{ .codepoint = ' ' },
    grapheme_id_extension: u4 = 0,
    _padding2: u7 = 0,
    tag: Tag = .codepoint,
    width: Width = .narrow,
    _padding1: u5 = 0,
    style: Style.Id = .default,

    pub const Width = enum(u2) {
        narrow = 0,
        wide_start = 1,
        wide_end = 2,
    };

    pub const Tag = enum(u1) {
        codepoint = 0,
        grapheme = 1,
    };

    pub const Data = packed union {
        codepoint: u21,
        grapheme_id: u21,
    };

    pub const empty = Cell{ .data = .{ .codepoint = ' ' }, .tag = .codepoint, .width = .narrow, .style = .default };
    pub const zero = Cell{ .data = .{ .codepoint = 0 }, .tag = .codepoint, .width = .narrow, .style = .default };

    pub const wide_end = Cell{ .data = .{ .codepoint = ' ' }, .tag = .codepoint, .width = .wide_end, .style = .default };

    pub inline fn initWideEnd(style: Style.Id) Cell {
        return Cell{ .data = .{ .codepoint = ' ' }, .tag = .codepoint, .width = .wide_end, .style = style };
    }

    pub inline fn initGrapheme(id: GraphemeIndex, width: Width, style: Style.Id) Cell {
        var cell: Cell = .zero;
        cell = @bitCast(@as(CellSize, @bitCast(cell)) | @as(u64, id));
        cell.width = width;
        cell.tag = .grapheme;
        cell.style = style;
        return cell;
    }

    pub fn eql(self: Cell, other: Cell) bool {
        // NOTE(adi): Ordered in the order of fields most likely to be different
        return @as(u21, @bitCast(self.data)) == @as(u21, @bitCast(other.data)) and
            self.style == other.style and
            self.width == other.width and
            self.tag == other.tag and
            self.grapheme_id_extension == other.grapheme_id_extension;
    }
};

pub const Style = struct {
    fg: Color = .none,
    bg: Color = .none,
    underline: Color = .none,
    flags: Flags = .{},

    pub const default = Style{
        .fg = .none,
        .bg = .none,
        .underline = .none,
        .flags = .{},
    };

    pub const Id = enum(u24) { default = 0, error_style = 1, _ };

    pub const RGB = packed struct(u24) {
        b: u8,
        g: u8,
        r: u8,

        pub inline fn fromHex(rrggbb: u24) RGB {
            return @bitCast(rrggbb);
        }
    };

    pub const Color = union(enum(u8)) {
        none,
        ansi: Indexed,
        rgb: RGB,

        pub inline fn eql(self: Color, other: Color) bool {
            return switch (self) {
                .none => return other == .none,
                .ansi => |ansi| return switch (other) {
                    .ansi => return ansi == other.ansi,
                    else => return false,
                },
                .rgb => |rgb| return switch (other) {
                    .rgb => return @as(u24, @bitCast(rgb)) == @as(u24, @bitCast(other.rgb)),
                    else => return false,
                },
            };
        }
    };

    pub const Indexed = enum(u8) {
        black = 0,
        red = 1,
        green = 2,
        yellow = 3,
        blue = 4,
        magenta = 5,
        cyan = 6,
        white = 7,
        bright_black = 8,
        bright_red = 9,
        bright_green = 10,
        bright_yellow = 11,
        bright_blue = 12,
        bright_magenta = 13,
        bright_cyan = 14,
        bright_white = 15,
        _,

        pub inline fn fromRGB(r: u3, g: u3, b: u3) Indexed {
            assert(r < 6 and g < 6 and b < 6);
            const index: u8 = 16 + @as(u8, r) * 36 + @as(u8, g) * 6 + @as(u8, b);
            return @enumFromInt(index);
        }

        pub inline fn grayscale(level: u5) Indexed {
            assert(level < 24);
            const index: u8 = 232 + @as(u8, level);
            return @enumFromInt(index);
        }
    };

    pub const Flags = packed struct(u10) {
        bold: bool = false,
        dim: bool = false,
        italic: bool = false,
        reverse: bool = false,
        strikethrough: bool = false,
        blink: bool = false,
        invisible: bool = false,
        underline: Underline = .none,
    };

    pub const Underline = enum(u3) {
        none = 0,
        single = 1,
        double = 2,
        curly = 3,
        dotted = 4,
        dashed = 5,
    };

    pub fn write(new: Id, current: Id, style_sheet: *const Style.Sheet, writer: *std.Io.Writer) error{WriteFailed}!void {
        const current_style: Style = style_sheet.acquire(current);
        const new_style: Style = style_sheet.acquire(new);

        if (!current_style.fg.eql(new_style.fg)) {
            switch (new_style.fg) {
                .none => try writer.writeAll(seq.sgr.foreground_color_reset),
                .ansi => |ansi_index| {
                    const index = @intFromEnum(ansi_index);
                    switch (index) {
                        0...7 => try seq.sgr.foregroundStandard(writer, @intCast(index)),
                        8...15 => try seq.sgr.foregroundBrightStandard(writer, @intCast(index - 8)),
                        else => try seq.sgr.foregroundIndexed(writer, @intCast(index)),
                    }
                },
                .rgb => |rgb| try seq.sgr.foregroundRgb(writer, rgb.r, rgb.g, rgb.b),
            }
        }

        if (!current_style.bg.eql(new_style.bg)) {
            switch (new_style.bg) {
                .none => try writer.writeAll(seq.sgr.background_color_reset),
                .ansi => |ansi_index| {
                    const index = @intFromEnum(ansi_index);
                    switch (index) {
                        0...7 => try seq.sgr.backgroundStandard(writer, @intCast(index)),
                        8...15 => try seq.sgr.backgroundBrightStandard(writer, @intCast(index - 8)),
                        else => try seq.sgr.backgroundIndexed(writer, @intCast(index)),
                    }
                },
                .rgb => |rgb| try seq.sgr.backgroundRgb(writer, rgb.r, rgb.g, rgb.b),
            }
        }

        if (!current_style.underline.eql(new_style.underline)) {
            switch (new_style.underline) {
                .none => try writer.writeAll(seq.sgr.underline_color_reset),
                // @NOTE there is no equivalent for the 4bit color index standard as it was introduced much later
                .ansi => |ansi_index| try seq.sgr.underlineColorIndexed(writer, @intFromEnum(ansi_index)),
                .rgb => |rgb| try seq.sgr.underlineColorRgb(writer, rgb.r, rgb.g, rgb.b),
            }
        }

        const flags_old = current_style.flags;
        const flags_new = new_style.flags;

        // @TODO GILA(mixed_horn_efq) Can we reduce the output size by chaining these x1b[1;2;4m instead of individual writes

        if (flags_old.bold != flags_new.bold or flags_old.dim != flags_new.dim) {
            if (!flags_new.bold and !flags_new.dim) {
                try writer.writeAll(seq.sgr.bold_dim_disable);
            } else {
                const turn_off = (flags_old.bold and !flags_new.bold) or (flags_old.dim and !flags_new.dim);
                if (turn_off) try writer.writeAll(seq.sgr.bold_dim_disable);
                if (flags_new.bold) try writer.writeAll(seq.sgr.bold_enable);
                if (flags_new.dim) try writer.writeAll(seq.sgr.dim_enable);
            }
        }

        if (flags_old.italic != flags_new.italic) {
            try writer.writeAll(if (flags_new.italic) seq.sgr.italic_enable else seq.sgr.italic_disable);
        }

        if (flags_old.blink != flags_new.blink) {
            try writer.writeAll(if (flags_new.blink) seq.sgr.blink_enable else seq.sgr.blink_disable);
        }

        if (flags_old.reverse != flags_new.reverse) {
            try writer.writeAll(if (flags_new.reverse) seq.sgr.reverse_enable else seq.sgr.reverse_disable);
        }

        if (flags_old.invisible != flags_new.invisible) {
            try writer.writeAll(if (flags_new.invisible) seq.sgr.invisible_enable else seq.sgr.invisible_disable);
        }

        if (flags_old.strikethrough != flags_new.strikethrough) {
            try writer.writeAll(if (flags_new.strikethrough) seq.sgr.strikethrough_enable else seq.sgr.strikethrough_disable);
        }

        if (flags_old.underline != flags_new.underline) {
            try writer.writeAll(switch (flags_new.underline) {
                .none => seq.sgr.underline_style_reset,
                .single => seq.sgr.underline_style_single,
                .double => seq.sgr.underline_style_double,
                .curly => seq.sgr.underline_style_curly,
                .dotted => seq.sgr.underline_style_dotted,
                .dashed => seq.sgr.underline_style_dashed,
            });
        }
    }

    pub const Sheet = struct {
        styles: std.ArrayList(Style),
        generation: std.ArrayList(u8),

        const StyleInt = u16;

        const InnerData = packed struct(u24) {
            position: StyleInt,
            generation: u8,
        };

        pub const max_style_count = 4096;

        pub fn initCapacity(allocator: std.mem.Allocator, capacity: usize) !Sheet {
            assert(capacity <= max_style_count);
            var sheet: Sheet = .empty;
            sheet.styles = try std.ArrayList(Style).initCapacity(allocator, capacity + 2);
            sheet.generation = try std.ArrayList(u8).initCapacity(allocator, capacity + 2);
            sheet.styles.appendAssumeCapacity(.{ .fg = .none, .bg = .none, .underline = .none, .flags = .{} });
            sheet.generation.appendAssumeCapacity(0);
            sheet.styles.appendAssumeCapacity(.{
                .fg = .{ .rgb = .{ .r = 255, .g = 255, .b = 255 } },
                .bg = .{ .rgb = .{ .r = 255, .g = 0, .b = 255 } },
                .underline = .none,
                .flags = .{},
            });
            sheet.generation.appendAssumeCapacity(0);
            return sheet;
        }

        pub const empty = Sheet{
            .styles = .empty,
            .generation = .empty,
        };

        pub fn initBuffer(style_buffer: []Style, generator_buffer: []u8) Sheet {
            assert(style_buffer.len == generator_buffer.len);
            assert(style_buffer.len > 2);
            var sheet: Sheet = .empty;
            sheet.styles = std.ArrayList(Style).initBuffer(style_buffer);
            sheet.generation = std.ArrayList(u8).initBuffer(generator_buffer);
            sheet.styles.appendAssumeCapacity(.{ .fg = .none, .bg = .none, .underline = .none });
            sheet.generation.appendAssumeCapacity(0);
            sheet.styles.appendAssumeCapacity(.{
                .fg = .{ .rgb = .{ .r = 255, .g = 255, .b = 255 } },
                .bg = .{ .rgb = .{ .r = 255, .g = 0, .b = 255 } },
                .underline = .none,
            });
            sheet.generation.appendAssumeCapacity(0);
            assert(sheet.styles.items.len == 2);
            return sheet;
        }

        pub fn deinit(self: *Sheet, allocator: std.mem.Allocator) void {
            self.styles.deinit(allocator);
            self.generation.deinit(allocator);
        }

        pub fn putAssumeCapacity(self: *Sheet, style: Style) Id {
            assert(self.styles.items.len < std.math.maxInt(StyleInt));
            assert(self.styles.items.len == self.generation.items.len);
            const index: StyleInt = @intCast(self.styles.items.len);
            self.styles.appendAssumeCapacity(style);
            self.generation.appendAssumeCapacity(0);
            return @enumFromInt(index);
        }

        pub fn putBounded(self: *Sheet, style: Style) Id {
            assert(self.styles.items.len == self.generation.items.len);
            assert(self.styles.items.len < std.math.maxInt(StyleInt));
            const index: StyleInt = @intCast(self.styles.items.len);
            self.styles.appendBounded(style) catch return .error_style;
            self.generation.appendBounded(0) catch return .error_style;
            return @enumFromInt(index);
        }

        pub fn put(self: *Sheet, allocator: std.mem.Allocator, style: Style) Id {
            assert(self.styles.items.len == self.generation.items.len);
            assert(self.styles.items.len < std.math.maxInt(StyleInt));
            const index: StyleInt = @intCast(self.styles.items.len);
            self.styles.append(allocator, style) catch return .error_style;
            self.generation.append(allocator, 0) catch return .error_style;
            return @enumFromInt(index);
        }

        pub const StyleUpdate = struct {
            fg: ?Color = null,
            bg: ?Color = null,
            underline: ?Color = null,
            flags: ?Flags = null,
        };

        pub fn update(self: *Sheet, id: Id, style: StyleUpdate) error{OutOfBounds}!Id {
            var data: InnerData = @bitCast(@intFromEnum(id));
            if (data.position >= self.styles.items.len) return error.OutOfBounds;
            if (data.position < 2) return error.OutOfBounds;
            if (style.fg) |fg| self.styles.items[data.position].fg = fg;
            if (style.bg) |bg| self.styles.items[data.position].bg = bg;
            if (style.underline) |underline| self.styles.items[data.position].underline = underline;
            if (style.flags) |flags| self.styles.items[data.position].flags = flags;
            self.generation.items[data.position] += 1;
            data.generation = self.generation.items[data.position];
            return @enumFromInt(@as(u24, @bitCast(data)));
        }

        pub fn replace(self: *Sheet, id: Id, style: Style) error{OutOfBounds}!Id {
            var data: InnerData = @bitCast(@intFromEnum(id));
            if (data.position >= self.styles.items.len) return error.OutOfBounds;
            if (data.position < 2) return error.OutOfBounds;
            self.styles.items[data.position] = style;
            self.generation.items[data.position] += 1;
            data.generation = self.generation.items[data.position];
            return @enumFromInt(@as(u24, @bitCast(data)));
        }

        inline fn acquire(self: *const Sheet, index: Id) Style {
            const inner_data: InnerData = @bitCast(@intFromEnum(index));
            if (inner_data.position < self.styles.items.len and inner_data.generation == self.generation.items[inner_data.position]) {
                return self.styles.items[inner_data.position];
            } else {
                return self.styles.items[1];
            }
        }
    };
};

