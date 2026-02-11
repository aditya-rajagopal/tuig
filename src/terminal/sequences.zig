const std = @import("std");

const stdx = @import("stdx");
const assert = stdx.inlineAssert;

/// Control Sequence Introducer prefix.
pub const CSI = "\x1b[";
/// Operating System Command prefix.
pub const OSC = "\x1b]";
/// Device Control String prefix.
pub const DCS = "\x1bP";
/// String Terminator sequence.
pub const ST = "\x1b\\";
/// BEL control character (`0x07`).
pub const BEL = "\x07";

/// Supported DEC private modes (`CSI ? Ps h/l`).
pub const PrivateMode = enum(u16) {
    /// Enable and disable cursor visibility
    cursor_visible = 25,
    /// Enable normal mouse tracking (press, release, and modifiers)
    mouse_normal_tracking = 1000,
    /// Enable mouse cell-motion tracking while button is down
    mouse_cell_motion = 1002,
    /// Enable full mouse motion tracking
    mouse_all_motion = 1003,
    /// Enable SGR mouse protocol
    mouse_sgr = 1006,
    /// Enable pixel-precision mouse mode
    mouse_pixel = 1016,
    /// Enter/leave alternate screen buffer
    alternate_screen = 1049,
    /// Enable bracketed paste mode
    bracketed_paste = 2004,
    // TODO: X10 press-only tracking (mode 9)
    // TODO: Highlight tracking (mode 1001)
    // TODO: UTF-8 mouse encoding (mode 1005, deprecated)
    // TODO: CSI-based synchronized update (mode 2026)
};

const csi_private_set = "\x1b[?{d}h";
const csi_private_reset = "\x1b[?{d}l";

/// Emit `CSI ? Ps h` for a known private mode.
pub inline fn csiPrivateSet(writer: *std.Io.Writer, mode: PrivateMode) error{WriteFailed}!void {
    try writer.print(csi_private_set, .{@intFromEnum(mode)});
}

/// Emit `CSI ? Ps l` for a known private mode.
pub inline fn csiPrivateReset(writer: *std.Io.Writer, mode: PrivateMode) error{WriteFailed}!void {
    try writer.print(csi_private_reset, .{@intFromEnum(mode)});
}

/// Screen-wide controls.
pub const screen = struct {
    /// Erase the full screen (ED 2).
    pub const clear = "\x1b[2J";
    /// Move cursor to home.
    pub const home = "\x1b[H";
    /// Erase full screen and move cursor home.
    pub const clear_and_home = "\x1b[2J\x1b[H";
    /// Erase from cursor to end of screen (ED 0).
    pub const erase_below = "\x1b[0J";
    /// Erase from beginning of screen to cursor (ED 1).
    pub const erase_above = "\x1b[1J";
    /// Erase from cursor to end of line (EL 0).
    pub const erase_line_right = "\x1b[0K";
    /// Erase from beginning of line to cursor (EL 1).
    pub const erase_line_left = "\x1b[1K";
    /// Erase entire current line (EL 2).
    pub const erase_line = "\x1b[2K";
};

/// Cursor controls.
pub const cursor = struct {
    /// Save cursor position into terminal stack
    pub const save = "\x1b[s";
    /// Restore cursor position from terminal stack
    pub const restore = "\x1b[u";

    pub inline fn visible(writer: *std.Io.Writer) error{WriteFailed}!void {
        try csiPrivateSet(writer, .cursor_visible);
    }

    pub inline fn hidden(writer: *std.Io.Writer) error{WriteFailed}!void {
        try csiPrivateReset(writer, .cursor_visible);
    }

    /// Move cursor to 1-based row, col — matches VT100 CUP convention.
    pub inline fn to(writer: *std.Io.Writer, row_1_based: u16, col_1_based: u16) error{WriteFailed}!void {
        try writer.print("\x1b[{d};{d}H", .{ row_1_based, col_1_based });
    }

    /// Move cursor to 0-based x (column), y (row) — application coordinates.
    pub inline fn toZero(writer: *std.Io.Writer, x: u16, y: u16) error{WriteFailed}!void {
        try to(writer, y + 1, x + 1);
    }

    /// Move cursor up by `count` lines
    pub inline fn up(writer: *std.Io.Writer, count: u16) error{WriteFailed}!void {
        if (count == 0) return;
        try writer.print("\x1b[{d}A", .{count});
    }

    /// Move cursor down by `count` lines
    pub inline fn down(writer: *std.Io.Writer, count: u16) error{WriteFailed}!void {
        if (count == 0) return;
        try writer.print("\x1b[{d}B", .{count});
    }

    /// Move cursor right by `count` cells
    pub inline fn right(writer: *std.Io.Writer, count: u16) error{WriteFailed}!void {
        if (count == 0) return;
        try writer.print("\x1b[{d}C", .{count});
    }

    /// Move cursor left by `count` cells
    pub inline fn left(writer: *std.Io.Writer, count: u16) error{WriteFailed}!void {
        if (count == 0) return;
        try writer.print("\x1b[{d}D", .{count});
    }

    /// Cursor shape constants (DECSCUSR — `CSI Ps SP q`).
    pub const shape = struct {
        /// Reset to terminal default cursor shape.
        pub const default = "\x1b[0 q";
        /// Blinking block cursor.
        pub const blinking_block = "\x1b[1 q";
        /// Steady block cursor.
        pub const steady_block = "\x1b[2 q";
        /// Blinking underline cursor.
        pub const blinking_underline = "\x1b[3 q";
        /// Steady underline cursor.
        pub const steady_underline = "\x1b[4 q";
        /// Blinking bar (vertical line) cursor.
        pub const blinking_bar = "\x1b[5 q";
        /// Steady bar (vertical line) cursor.
        pub const steady_bar = "\x1b[6 q";
    };

    /// Move cursor by signed deltas (`dx`, `dy`).
    pub inline fn move(writer: *std.Io.Writer, dx: i16, dy: i16) error{WriteFailed}!void {
        if (dx > 0) {
            try right(writer, @intCast(dx));
        } else if (dx < 0) {
            try left(writer, @intCast(-dx));
        }

        if (dy > 0) {
            try down(writer, @intCast(dy));
        } else if (dy < 0) {
            try up(writer, @intCast(-dy));
        }
    }
};

/// Mouse protocol controls.
pub const mouse = struct {
    /// Mouse reporting detail level.
    pub const TrackingLevel = enum {
        /// Normal tracking: report presses, releases, and modifiers.
        presses_only,
        /// Report movement while a button is held.
        cell_motion,
        /// Report all movement.
        all_motion,

        /// Map tracking level to its private mode number.
        pub inline fn toPrivateMode(self: TrackingLevel) PrivateMode {
            return switch (self) {
                .presses_only => .mouse_normal_tracking,
                .cell_motion => .mouse_cell_motion,
                .all_motion => .mouse_all_motion,
            };
        }

        /// Enable this tracking level.
        pub inline fn enable(self: TrackingLevel, writer: *std.Io.Writer) error{WriteFailed}!void {
            try csiPrivateSet(writer, self.toPrivateMode());
        }

        /// Disable this tracking level.
        pub inline fn disable(self: TrackingLevel, writer: *std.Io.Writer) error{WriteFailed}!void {
            try csiPrivateReset(writer, self.toPrivateMode());
        }
    };

    /// Enable SGR mouse encoding (`?1006h`).
    pub inline fn enableSgr(writer: *std.Io.Writer) error{WriteFailed}!void {
        try csiPrivateSet(writer, .mouse_sgr);
    }

    /// Disable SGR mouse encoding (`?1006l`).
    pub inline fn disableSgr(writer: *std.Io.Writer) error{WriteFailed}!void {
        try csiPrivateReset(writer, .mouse_sgr);
    }

    /// Set pointer shape via OSC 22.
    pub inline fn pointerShapeSet(writer: *std.Io.Writer, shape: []const u8) error{WriteFailed}!void {
        try writer.writeAll("\x1b]22;");
        try writer.writeAll(shape);
        try writer.writeAll("\x1b\\");
    }

    /// Push one or more comma-separated pointer shapes onto the OSC 22 stack.
    pub inline fn pointerShapePush(writer: *std.Io.Writer, shape_names_csv: []const u8) error{WriteFailed}!void {
        try writer.writeAll("\x1b]22;>");
        try writer.writeAll(shape_names_csv);
        try writer.writeAll("\x1b\\");
    }

    /// Pop one pointer shape from the OSC 22 pointer-shape stack.
    pub inline fn pointerShapePop(writer: *std.Io.Writer) error{WriteFailed}!void {
        try writer.writeAll("\x1b]22;<\x1b\\");
    }

    /// Reset pointer shape to terminal default by setting OSC 22 to an empty value.
    pub inline fn pointerShapeReset(writer: *std.Io.Writer) error{WriteFailed}!void {
        try writer.writeAll("\x1b]22;\x1b\\");
    }
};

/// Kitty keyboard protocol controls.
pub const kitty = struct {
    /// Bit flags for kitty keyboard protocol push (`CSI > {flags} u`).
    pub const Flags = packed struct(u8) {
        /// Report disambiguated escape codes.
        disambiguate_escape_codes: bool = false,
        /// Report press/repeat/release event types.
        report_event_types: bool = false,
        /// Include alternate key codes.
        report_alternate_keys: bool = false,
        /// Report all keys as escape codes.
        report_all_keys_as_escape_codes: bool = false,
        /// Include associated text where available.
        report_associated_text: bool = false,
        /// Reserved bits, must stay zero.
        padding: u3 = 0,
    };

    /// Push kitty keyboard flags (`CSI > {flags} u`).
    pub inline fn pushKeyboardFlags(writer: *std.Io.Writer, flags: Flags) error{WriteFailed}!void {
        assert(flags.padding == 0);
        try writer.print("\x1b[>{d}u", .{@as(u8, @bitCast(flags))});
    }

    /// Pop previously pushed kitty keyboard flags (`CSI < u`).
    pub inline fn popKeyboardFlags(writer: *std.Io.Writer) error{WriteFailed}!void {
        try writer.writeAll("\x1b[<u");
    }
};

/// Synchronized update control strings (kitty/xterm extension).
pub const sync_update = struct {
    /// Begin synchronized update block.
    pub const begin = "\x1bP=1s" ++ ST;
    /// End synchronized update block.
    pub const end = "\x1bP=2s" ++ ST;
};

/// Query/request sequences.
pub const query = struct {
    /// Request cursor position report through stdin
    pub const cursor_position = "\x1b[6n";
    /// Request primary device attributes (`CSI c`).
    pub const primary_device_attributes = "\x1b[c";
    /// Request secondary device attributes (`CSI > c`).
    pub const secondary_device_attributes = "\x1b[>c";
    /// Query pixel mouse mode (`CSI ? 1016 $ p`).
    pub const pixel_mouse_mods = "\x1b[?1016$p";
    /// Query kitty keyboard support (`CSI ? u`).
    pub const kitty_keyboard_support = "\x1b[?u";

    /// Query current OSC 22 pointer shape (`__current__`).
    pub const mouse_pointer_shape_current = "\x1b]22;?__current__\x1b\\";
    /// Query terminal default OSC 22 pointer shape (`__default__`).
    pub const mouse_pointer_shape_default = "\x1b]22;?__default__\x1b\\";
    /// Query OSC 22 pointer shape used while pointer is grabbed (`__grabbed__`).
    pub const mouse_pointer_shape_grabbed = "\x1b]22;?__grabbed__\x1b\\";

    /// Query support for one or more pointer shape names (comma-separated).
    pub inline fn mousePointerShapeSupport(writer: *std.Io.Writer, shape_names_csv: []const u8) error{WriteFailed}!void {
        try writer.writeAll("\x1b]22;?");
        try writer.writeAll(shape_names_csv);
        try writer.writeAll("\x1b\\");
    }

    /// Query current state/support for DEC private mode `Ps` (`CSI ? Ps $ p`).
    pub inline fn DECRQM(writer: *std.Io.Writer, mode: PrivateMode) error{WriteFailed}!void {
        try writer.print("\x1b[?{d}$p", .{@intFromEnum(mode)});
    }
};

/// SGR style sequences.
pub const sgr = struct {
    /// Reset all SGR style attributes.
    pub const reset_all = "\x1b[m";
    /// Reset foreground color.
    pub const foreground_color_reset = "\x1b[39m";
    /// Reset background color.
    pub const background_color_reset = "\x1b[49m";
    /// Reset underline color.
    pub const underline_color_reset = "\x1b[59m";

    /// Disable underline style.
    pub const underline_style_reset = "\x1b[24m";
    /// Single underline style.
    pub const underline_style_single = "\x1b[4m";
    /// Double underline style.
    pub const underline_style_double = "\x1b[4:2m";
    /// Curly underline style.
    pub const underline_style_curly = "\x1b[4:3m";
    /// Dotted underline style.
    pub const underline_style_dotted = "\x1b[4:4m";
    /// Dashed underline style.
    pub const underline_style_dashed = "\x1b[4:5m";

    /// Enable bold.
    pub const bold_enable = "\x1b[1m";
    /// Enable dim.
    pub const dim_enable = "\x1b[2m";
    /// Disable bold and dim.
    pub const bold_dim_disable = "\x1b[22m";

    /// Enable italic.
    pub const italic_enable = "\x1b[3m";
    /// Disable italic.
    pub const italic_disable = "\x1b[23m";

    /// Enable blink.
    pub const blink_enable = "\x1b[5m";
    /// Disable blink.
    pub const blink_disable = "\x1b[25m";

    /// Enable reverse video.
    pub const reverse_enable = "\x1b[7m";
    /// Disable reverse video.
    pub const reverse_disable = "\x1b[27m";

    /// Enable invisible text.
    pub const invisible_enable = "\x1b[8m";
    /// Disable invisible text.
    pub const invisible_disable = "\x1b[28m";

    /// Enable strikethrough.
    pub const strikethrough_enable = "\x1b[9m";
    /// Disable strikethrough.
    pub const strikethrough_disable = "\x1b[29m";

    /// Set 4-bit standard foreground color index `0..7`.
    pub inline fn foregroundStandard(writer: *std.Io.Writer, index: u8) error{WriteFailed}!void {
        assert(index < 8);
        try writer.print("\x1b[3{d}m", .{index});
    }

    /// Set 4-bit bright foreground color index `0..7`.
    pub inline fn foregroundBrightStandard(writer: *std.Io.Writer, index: u8) error{WriteFailed}!void {
        assert(index < 8);
        try writer.print("\x1b[9{d}m", .{index});
    }

    /// Set 8-bit indexed foreground color `0..255`.
    pub inline fn foregroundIndexed(writer: *std.Io.Writer, index: u8) error{WriteFailed}!void {
        try writer.print("\x1b[38:5:{d}m", .{index});
    }

    /// Set 24-bit RGB foreground color.
    pub inline fn foregroundRgb(writer: *std.Io.Writer, r: u8, g: u8, b: u8) error{WriteFailed}!void {
        try writer.print("\x1b[38:2:{d}:{d}:{d}m", .{ r, g, b });
    }

    /// Set 4-bit standard background color index `0..7`.
    pub inline fn backgroundStandard(writer: *std.Io.Writer, index: u8) error{WriteFailed}!void {
        assert(index < 8);
        try writer.print("\x1b[4{d}m", .{index});
    }

    /// Set 4-bit bright background color index `0..7`.
    pub inline fn backgroundBrightStandard(writer: *std.Io.Writer, index: u8) error{WriteFailed}!void {
        assert(index < 8);
        try writer.print("\x1b[10{d}m", .{index});
    }

    /// Set 8-bit indexed background color `0..255`.
    pub inline fn backgroundIndexed(writer: *std.Io.Writer, index: u8) error{WriteFailed}!void {
        try writer.print("\x1b[48:5:{d}m", .{index});
    }

    /// Set 24-bit RGB background color.
    pub inline fn backgroundRgb(writer: *std.Io.Writer, r: u8, g: u8, b: u8) error{WriteFailed}!void {
        try writer.print("\x1b[48:2:{d}:{d}:{d}m", .{ r, g, b });
    }

    /// Set 8-bit indexed underline color `0..255`.
    pub inline fn underlineColorIndexed(writer: *std.Io.Writer, index: u8) error{WriteFailed}!void {
        try writer.print("\x1b[58:5:{d}m", .{index});
    }

    /// Set 24-bit RGB underline color.
    pub inline fn underlineColorRgb(writer: *std.Io.Writer, r: u8, g: u8, b: u8) error{WriteFailed}!void {
        try writer.print("\x1b[58:2:{d}:{d}:{d}m", .{ r, g, b });
    }
};

/// Hyperlink controls (OSC 8).
pub const hyperlinks = struct {
    /// Clear current hyperlink.
    pub const clear = "\x1b]8;;\x1b\\";

    /// Set hyperlink with params and URI.
    pub inline fn set(writer: *std.Io.Writer, params: []const u8, uri: []const u8) error{WriteFailed}!void {
        try writer.writeAll("\x1b]8;");
        try writer.writeAll(params);
        try writer.writeByte(';');
        try writer.writeAll(uri);
        try writer.writeAll("\x1b\\");
    }
};

/// Clipboard controls (OSC 52).
pub const clipboard = struct {
    /// Request clipboard content.
    pub const request = "\x1b]52;c;?\x1b\\";

    /// Copy to clipboard using base64 payload.
    pub inline fn copy(writer: *std.Io.Writer, base64_payload: []const u8) error{WriteFailed}!void {
        try writer.writeAll("\x1b]52;c;");
        try writer.writeAll(base64_payload);
        try writer.writeAll("\x1b\\");
    }
};

pub const bracketed_paste = struct {
    pub const start = "\x1b[200~";
    pub const end = "\x1b[201~";
};

/// Terminal default color controls (OSC 4/10/11/12/104/110/111/112).
pub const colors = struct {
    /// Reset all dynamic color palette slots (OSC 104).
    pub const palette_reset = "\x1b]104\x1b\\";
    /// Query default foreground color (OSC 10).
    pub const foreground_query = "\x1b]10;?\x1b\\";
    /// Reset default foreground color (OSC 110).
    pub const foreground_reset = "\x1b]110\x1b\\";
    /// Query default background color (OSC 11).
    pub const background_query = "\x1b]11;?\x1b\\";
    /// Reset default background color (OSC 111).
    pub const background_reset = "\x1b]111\x1b\\";
    /// Query cursor color (OSC 12).
    pub const cursor_color_query = "\x1b]12;?\x1b\\";
    /// Reset cursor color (OSC 112).
    pub const cursor_color_reset = "\x1b]112\x1b\\";

    /// Query one dynamic color palette slot by index (OSC 4).
    pub inline fn paletteQuery(writer: *std.Io.Writer, color_index: u8) error{WriteFailed}!void {
        try writer.print("\x1b]4;{d};?\x1b\\", .{color_index});
    }

    /// Set default foreground color from 8-bit RGB (OSC 10).
    pub inline fn foregroundSet(writer: *std.Io.Writer, r: u8, g: u8, b: u8) error{WriteFailed}!void {
        try writer.print("\x1b]10;rgb:{x:0>2}{x:0>2}/{x:0>2}{x:0>2}/{x:0>2}{x:0>2}\x1b\\", .{ r, r, g, g, b, b });
    }

    /// Set default background color from 8-bit RGB (OSC 11).
    pub inline fn backgroundSet(writer: *std.Io.Writer, r: u8, g: u8, b: u8) error{WriteFailed}!void {
        try writer.print("\x1b]11;rgb:{x:0>2}{x:0>2}/{x:0>2}{x:0>2}/{x:0>2}{x:0>2}\x1b\\", .{ r, r, g, g, b, b });
    }

    /// Set cursor color from 8-bit RGB (OSC 12).
    pub inline fn cursorColorSet(writer: *std.Io.Writer, r: u8, g: u8, b: u8) error{WriteFailed}!void {
        try writer.print("\x1b]12;rgb:{x:0>2}{x:0>2}/{x:0>2}{x:0>2}/{x:0>2}{x:0>2}\x1b\\", .{ r, r, g, g, b, b });
    }
};

/// Desktop notification controls (OSC 9/777).
pub const notifications = struct {
    /// Send desktop notification (OSC 9).
    pub inline fn send(writer: *std.Io.Writer, message: []const u8) error{WriteFailed}!void {
        try writer.writeAll("\x1b]9;");
        try writer.writeAll(message);
        try writer.writeAll("\x1b\\");
    }

    /// Send extended desktop notification with title and body (OSC 777).
    pub inline fn sendExtended(writer: *std.Io.Writer, title: []const u8, body: []const u8) error{WriteFailed}!void {
        try writer.writeAll("\x1b]777;notify;");
        try writer.writeAll(title);
        try writer.writeByte(';');
        try writer.writeAll(body);
        try writer.writeAll("\x1b\\");
    }
};

/// Window/session controls (OSC 2/7).
pub const window = struct {
    /// Set window title (OSC 2).
    pub inline fn setTitle(writer: *std.Io.Writer, title: []const u8) error{WriteFailed}!void {
        try writer.writeAll("\x1b]2;");
        try writer.writeAll(title);
        try writer.writeAll("\x1b\\");
    }

    /// Set current working directory URI (OSC 7).
    pub inline fn setWorkingDirectory(writer: *std.Io.Writer, file_uri: []const u8) error{WriteFailed}!void {
        try writer.writeAll("\x1b]7;");
        try writer.writeAll(file_uri);
        try writer.writeAll("\x1b\\");
    }
};
