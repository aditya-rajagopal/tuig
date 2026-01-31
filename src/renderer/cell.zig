const std = @import("std");

const stdx = @import("stdx");
const assert = stdx.inlineAssert;
const FixedGrowingBufferAllocator = stdx.FixedGrowingBufferAllocator;

const t = @import("types.zig");
const GraphemeIndex = t.GraphemeBuffer.GraphemeIndex;

pub const CellSize = u64;
pub const Cell = packed struct(CellSize) {
    data: Data = .{ .codepoint = ' ' },
    grapheme_id_extension: u4 = 0,
    tag: Tag = .codepoint,
    width: Width = .narrow,
    style: Style = .default,

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

    pub inline fn initWideEnd(style: Style) Cell {
        return Cell{ .data = .{ .codepoint = ' ' }, .tag = .codepoint, .width = .wide_end, .style = style };
    }

    pub inline fn initGrapheme(id: GraphemeIndex, width: Width, style: Style) Cell {
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
            self.width == other.width and
            self.tag == other.tag and
            self.grapheme_id_extension == other.grapheme_id_extension and
            self.style.eql(other.style);
    }
};

pub const Style = packed struct(u36) {
    // @TODO GILA(far_naga_9ka) Decide if we need different tags of styles
    tag: Tag,
    flags: Flags,
    data: Data,

    pub const default = Style{
        .tag = .id,
        .data = .{ .id = .default },
        .flags = .{},
    };

    pub const Data = packed union {
        id: Sheet.Index,
        ansi: AnsiStyle,
        fg_rgb: RGB,
        bg_rgb: RGB,
    };

    pub const RGB = packed struct(u24) {
        r: u8,
        g: u8,
        b: u8,
    };

    pub const FullStyle = struct {
        fg: Color = .none,
        bg: Color = .none,
        underline: Color = .none,

        pub const Color = union(enum(u8)) {
            none,
            ansi: u8,
            rgb: RGB,
        };
    };

    pub const AnsiStyle = packed struct(u24) {
        fg: Ansi,
        bg: Ansi,
        underline: Ansi,
    };

    pub const Ansi = enum(u8) {
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

        pub inline fn fromRGB(r: u3, g: u3, b: u3) Ansi {
            assert(r < 6 and g < 6 and b < 6);
            const index: u8 = 16 + @as(u8, r) * 36 + @as(u8, g) * 6 + @as(u8, b);
            return @enumFromInt(index);
        }

        pub inline fn grayscale(level: u5) Ansi {
            assert(level < 24);
            const index: u8 = 232 + @as(u8, level);
            return @enumFromInt(index);
        }
    };

    pub const Tag = enum(u2) {
        id = 0,
        ansi = 1,
        fg_rgb = 2,
        bg_rgb = 3,
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

    pub fn eql(self: Style, other: Style) bool {
        return @as(u36, @bitCast(self)) == @as(u36, @bitCast(other));
    }

    pub fn write(self: Style, old_style: Style, style_sheet: *const Style.Sheet, writer: *std.Io.Writer) error{WriteFailed}!void {
        switch (self.tag) {
            .id => try style_sheet.write(self.data.id, writer),
            .ansi => {
                const style = self.data.ansi;
                switch (@intFromEnum(style.fg)) {
                    0...7 => |fg| try writer.print(ColorFormat.foreground_standard, .{fg}),
                    8...15 => |fg| try writer.print(ColorFormat.foreground_bright_standard, .{fg - 8}),
                    else => |fg| try writer.print(ColorFormat.foreground_indexed, .{fg}),
                }
                switch (@intFromEnum(style.bg)) {
                    0...7 => |bg| try writer.print(ColorFormat.background_standard, .{bg}),
                    8...15 => |bg| try writer.print(ColorFormat.background_bright_standard, .{bg - 8}),
                    else => |bg| try writer.print(ColorFormat.background_indexed, .{bg}),
                }
                try writer.print(ColorFormat.underline_color_indexed, .{@intFromEnum(style.underline)});
            },
            .fg_rgb => {
                const rgb = self.data.fg_rgb;
                try writer.print(ColorFormat.foreground_rgb, .{ rgb.r, rgb.g, rgb.b });
            },
            .bg_rgb => {
                const rgb = self.data.bg_rgb;
                try writer.print(ColorFormat.background_rgb, .{ rgb.r, rgb.g, rgb.b });
            },
        }
        const flags_old = old_style.flags;
        const flags_new = self.flags;

        // @TODO Can we reduce the output size by chaining these x1b[1;2;4m instead of individual writes

        if (flags_old.bold != flags_new.bold or flags_old.dim != flags_new.dim) {
            if (!flags_new.bold and !flags_new.dim) {
                try writer.writeAll(ColorFormat.bold_dim_disable);
            } else {
                const turn_off = (flags_old.bold and !flags_new.bold) or (flags_old.dim and !flags_new.dim);
                if (turn_off) try writer.writeAll(ColorFormat.bold_dim_disable);
                if (flags_new.bold) try writer.writeAll(ColorFormat.bold_enable);
                if (flags_new.dim) try writer.writeAll(ColorFormat.dim_enable);
            }
        }

        if (flags_old.italic != flags_new.italic) {
            try writer.writeAll(if (flags_new.italic) ColorFormat.italic_enable else ColorFormat.italic_disable);
        }

        if (flags_old.blink != flags_new.blink) {
            try writer.writeAll(if (flags_new.blink) ColorFormat.blink_enable else ColorFormat.blink_disable);
        }

        if (flags_old.reverse != flags_new.reverse) {
            try writer.writeAll(if (flags_new.reverse) ColorFormat.reverse_enable else ColorFormat.reverse_disable);
        }

        if (flags_old.invisible != flags_new.invisible) {
            try writer.writeAll(if (flags_new.invisible) ColorFormat.invisible_enable else ColorFormat.invisible_disable);
        }

        if (flags_old.strikethrough != flags_new.strikethrough) {
            try writer.writeAll(if (flags_new.strikethrough) ColorFormat.strikethrough_enable else ColorFormat.strikethrough_disable);
        }

        if (@intFromEnum(flags_old.underline) != @intFromEnum(flags_new.underline)) {
            try writer.writeAll(switch (flags_new.underline) {
                .none => ColorFormat.underline_style_reset,
                .single => ColorFormat.underline_style_single,
                .double => ColorFormat.underline_style_double,
                .curly => ColorFormat.underline_style_curly,
                .dotted => ColorFormat.underline_style_dotted,
                .dashed => ColorFormat.underline_style_dashed,
            });
        }
    }

    pub const Sheet = struct {
        styles: std.ArrayList(Style.FullStyle),
        generation: std.ArrayList(u8),

        const StyleInt = u16;
        pub const Reference = enum(StyleInt) { default = 0, missing = 1, _ };
        pub const Index = enum(u24) { default = 0, missing = 1, _ };
        const InnerData = packed struct(u24) {
            index: StyleInt,
            generation: u8,
        };

        pub const max_style_count = 4096;

        pub fn initCapacity(allocator: std.mem.Allocator, capacity: usize) !Sheet {
            assert(capacity <= max_style_count);
            var sheet: Sheet = .{};
            sheet.styles = try std.ArrayList(Style.FullStyle).initCapacity(allocator, capacity + 2);
            sheet.generation = try std.ArrayList(u8).initCapacity(allocator, capacity + 2);
            sheet.styles.appendAssumeCapacity(.{ .fg = .none, .bg = .none, .underline = .none });
            sheet.generation.appendAssumeCapacity(0);
            sheet.styles.appendAssumeCapacity(.{
                .fg = .{ .rgb = .{ .r = 255, .g = 255, .b = 255 } },
                .bg = .{ .rgb = .{ .r = 255, .g = 0, .b = 255 } },
                .underline = .none,
            });
            sheet.generation.appendAssumeCapacity(0);
            return sheet;
        }

        pub const empty = Sheet{
            .styles = .empty,
            .generation = .empty,
        };

        pub fn initBuffer(style_buffer: []Style.FullStyle, generator_buffer: []u8) Sheet {
            assert(style_buffer.len == generator_buffer.len);
            assert(style_buffer.len > 2);
            var sheet: Sheet = .empty;
            sheet.styles = std.ArrayList(Style.FullStyle).initBuffer(style_buffer);
            sheet.generation = std.ArrayList(u8).initBuffer(generator_buffer);
            sheet.styles.appendAssumeCapacity(.{ .fg = .none, .bg = .none, .underline = .none });
            sheet.generation.appendAssumeCapacity(0);
            sheet.styles.appendAssumeCapacity(.{
                .fg = .{ .rgb = .{ .r = 255, .g = 255, .b = 255 } },
                .bg = .{ .rgb = .{ .r = 255, .g = 0, .b = 255 } },
                .underline = .none,
            });
            sheet.generation.appendAssumeCapacity(0);
            return sheet;
        }

        pub fn deinit(self: Sheet, allocator: std.mem.Allocator) void {
            self.styles.deinit(allocator);
            self.generation.deinit(allocator);
        }

        pub fn putAssumeCapacity(self: *Sheet, style: Style.FullStyle) Reference {
            assert(self.styles.items.len < std.math.maxInt(StyleInt));
            assert(self.styles.items.len == self.generation.items.len);
            const index: StyleInt = @intCast(self.styles.items.len);
            self.styles.appendAssumeCapacity(style);
            self.generation.appendAssumeCapacity(0);
            return @enumFromInt(index);
        }

        pub fn putBounded(self: *Sheet, style: Style.FullStyle) error{OutOfMemory}!Reference {
            assert(self.styles.items.len == self.generation.items.len);
            assert(self.styles.items.len < std.math.maxInt(StyleInt));
            const index: StyleInt = @intCast(self.styles.items.len);
            try self.styles.appendBounded(style);
            try self.generation.appendBounded(0);
            return @enumFromInt(index);
        }

        pub fn put(self: *Sheet, allocator: std.mem.Allocator, style: Style.FullStyle) error{OutOfMemory}!Reference {
            assert(self.styles.items.len == self.generation.items.len);
            assert(self.styles.items.len < std.math.maxInt(StyleInt));
            const index: StyleInt = @intCast(self.styles.items.len);
            try self.styles.append(allocator, style);
            try self.generation.append(allocator, 0);
            return @enumFromInt(index);
        }

        pub fn get(self: Sheet, index: Reference) Index {
            const position: StyleInt = @intFromEnum(index);
            if (position >= self.styles.items.len) return .missing;
            const data: InnerData = .{
                .index = position,
                .generation = self.generation.items[position],
            };
            return @enumFromInt(@as(u24, @bitCast(data)));
        }

        pub fn update(self: *Sheet, index: Reference, style: Style.FullStyle) error{OutOfBounds}!void {
            const position: StyleInt = @intFromEnum(index);
            if (position >= self.styles.items.len) return error.OutOfBounds;
            if (position < 2) return error.OutOfBounds;
            self.styles.items[position] = style;
            self.generation.items[position] += 1;
        }

        pub fn write(self: Sheet, index: Index, writer: *std.Io.Writer) error{WriteFailed}!void {
            const inner_data: InnerData = @bitCast(@intFromEnum(index));
            if (inner_data.index >= self.styles.items.len) return error.WriteFailed;

            const style = self.styles.items[inner_data.index];
            switch (style.fg) {
                .none => try writer.writeAll(ColorFormat.foreground_reset),
                .ansi => |ansi_index| switch (ansi_index) {
                    0...7 => try writer.print(ColorFormat.foreground_standard, .{ansi_index}),
                    8...15 => try writer.print(ColorFormat.foreground_bright_standard, .{ansi_index - 8}),
                    else => try writer.print(ColorFormat.foreground_indexed, .{ansi_index}),
                },
                .rgb => |rgb| try writer.print(ColorFormat.foreground_rgb, .{ rgb.r, rgb.g, rgb.b }),
            }
            switch (style.bg) {
                .none => try writer.writeAll(ColorFormat.background_reset),
                .ansi => |ansi_index| switch (ansi_index) {
                    0...7 => try writer.print(ColorFormat.background_standard, .{ansi_index}),
                    8...15 => try writer.print(ColorFormat.background_bright_standard, .{ansi_index - 8}),
                    else => try writer.print(ColorFormat.background_indexed, .{ansi_index}),
                },
                .rgb => |rgb| try writer.print(ColorFormat.background_rgb, .{ rgb.r, rgb.g, rgb.b }),
            }
            switch (style.underline) {
                .none => try writer.writeAll(ColorFormat.underline_color_reset),
                // @NOTE there is no equivalent for the 4bit color index standard as it was introduced much later
                .ansi => |ansi_index| try writer.print(ColorFormat.underline_color_indexed, .{ansi_index}),
                .rgb => |rgb| try writer.print(ColorFormat.underline_color_rgb, .{ rgb.r, rgb.g, rgb.b }),
            }
        }
    };
};

pub const ColorFormat = struct {
    pub const reset_all = "\x1b[m";

    pub const foreground_reset = "\x1b[39m";
    pub const foreground_standard = "\x1b[3{d}m";
    pub const foreground_bright_standard = "\x1b[9{d}m";
    pub const foreground_indexed = "\x1b[38:5:{d}m";
    pub const foreground_rgb = "\x1b[38:2:{d}:{d}:{d}m";

    pub const background_reset = "\x1b[49m";
    pub const background_standard = "\x1b[4{d}m";
    pub const background_bright_standard = "\x1b[10{d}m";
    pub const background_indexed = "\x1b[48:5:{d}m";
    pub const background_rgb = "\x1b[48:2:{d}:{d}:{d}m";

    pub const underline_color_reset = "\x1b[59m";
    pub const underline_color_indexed = "\x1b[58:5:{d}m";
    pub const underline_color_rgb = "\x1b[58:2:{d}:{d}:{d}m";
    pub const underline_style_reset = "\x1b[24m";
    pub const underline_style_single = "\x1b[4m";
    pub const underline_style_double = "\x1b[4:2m";
    pub const underline_style_curly = "\x1b[4:3m";
    pub const underline_style_dotted = "\x1b[4:4m";
    pub const underline_style_dashed = "\x1b[4:5m";

    pub const bold_enable = "\x1b[1m";
    pub const dim_enable = "\x1b[2m";
    pub const bold_dim_disable = "\x1b[22m";

    pub const italic_enable = "\x1b[3m";
    pub const italic_disable = "\x1b[23m";

    pub const blink_enable = "\x1b[5m";
    pub const blink_disable = "\x1b[25m";

    pub const reverse_enable = "\x1b[7m";
    pub const reverse_disable = "\x1b[27m";

    pub const invisible_enable = "\x1b[8m";
    pub const invisible_disable = "\x1b[28m";

    pub const strikethrough_enable = "\x1b[9m";
    pub const strikethrough_disable = "\x1b[29m";
};
