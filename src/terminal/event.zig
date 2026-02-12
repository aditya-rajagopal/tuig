const std = @import("std");

const seq = @import("sequences.zig");

/// Parsed terminal events emitted by `terminal.Terminal.pollEvents`.
///
/// Events carrying slices borrow terminal-owned buffers. In particular,
/// `paste_data` and `osc_pointer_shape.value` are valid only until the next
/// `pollEvents` call on the same terminal instance.
pub const Event = union(enum(u8)) {
    /// A key press event.
    key_pressed: KeyEvent,
    /// A key release event when reported by the terminal protocol.
    key_released: KeyEvent,
    /// A key repeat event when reported by the terminal protocol.
    key_repeat: KeyEvent,
    /// Terminal size change.
    resize: ResizeEvent,
    /// DEC private mode report (`DECRPM`).
    decrpm: DECRPMEvent,
    /// Kitty keyboard protocol support or current flag report.
    kitty_keyboard_query: KittyKeyboardQueryEvent,
    /// Primary device attributes response (`DA1`).
    primary_device_attributes: PrimaryDeviceAttributesEvent,
    /// Secondary device attributes response (`DA2`).
    secondary_device_attributes: SecondaryDeviceAttributesEvent,
    /// OSC 4 palette color report.
    osc_palette_color: OSCPaletteColorEvent,
    /// OSC dynamic color report.
    osc_dynamic_color: OSCDynamicColorEvent,
    /// OSC pointer-shape report.
    ///
    /// The `value` slice borrows parser input memory and is valid only until
    /// the next `terminal.Terminal.pollEvents` call on the same terminal instance.
    /// Copy the data if you need to retain it beyond the next `pollEvents` call.
    osc_pointer_shape: OSCPointerShapeEvent,
    /// Mouse move without any pressed buttons.
    mouse_move: MouseEvent,
    /// Mouse move with left button pressed.
    mouse_drag_left: MouseEvent,
    /// Mouse move with middle button pressed.
    mouse_drag_middle: MouseEvent,
    /// Mouse move with right button pressed.
    mouse_drag_right: MouseEvent,
    /// Mouse wheel scroll up.
    mouse_scroll_up: MouseEvent,
    /// Mouse wheel scroll down.
    mouse_scroll_down: MouseEvent,
    /// Left mouse button press.
    mouse_left_pressed: MouseEvent,
    /// Middle mouse button press.
    mouse_middle_pressed: MouseEvent,
    /// Right mouse button press.
    mouse_right_pressed: MouseEvent,
    /// Left mouse button release.
    mouse_left_released: MouseEvent,
    /// Middle mouse button release.
    mouse_middle_released: MouseEvent,
    /// Right mouse button release.
    mouse_right_released: MouseEvent,
    /// Generic mouse release when button identity is not reported.
    mouse_released: MouseEvent,
    /// Start marker for bracketed paste (`CSI 200~`).
    paste_start,
    /// A chunk of bracketed paste payload between `paste_start` and `paste_end`.
    ///
    /// This slice borrows terminal read-buffer memory and is valid only until
    /// the next `pollEvents` call on the same terminal instance.
    ///
    /// If you need to retain the data beyond the next `pollEvents` call you
    /// must copy it.
    paste_data: []const u8,
    /// End marker for bracketed paste (`CSI 201~`).
    paste_end,
    /// Parsed input was recognized syntactically but not mapped to a supported event.
    unrecognized,

    pub fn format(self: Event, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .key_pressed => |key| try writer.print("key_pressed:{f}", .{key}),
            .key_released => |key| try writer.print("key_released:{f}", .{key}),
            .key_repeat => |key| try writer.print("key_repeat:{f}", .{key}),
            .resize => |resize| try writer.print("resize:{f}", .{resize}),
            .decrpm => |response| try writer.print("decrpm:?{d}={s}", .{ response.mode, @tagName(response.status) }),
            .kitty_keyboard_query => |response| {
                if (response.unknown_flags == 0) {
                    try writer.print("kitty_keyboard_query:{d}", .{response.raw_flags});
                } else {
                    try writer.print("kitty_keyboard_query:{d}(unknown:{d})", .{ response.raw_flags, response.unknown_flags });
                }
            },
            .primary_device_attributes => |response| {
                if (response.unknown_extensions) {
                    try writer.print("da1:{d}(unknown)", .{response.class_code});
                } else {
                    try writer.print("da1:{d}", .{response.class_code});
                }
            },
            .secondary_device_attributes => |response| try writer.print("da2:{d};{d};{d}", .{ response.identification_code, response.firmware_version, response.keyboard_option_raw }),
            .osc_palette_color => |response| try writer.print("osc4:{d}=rgb:{x:0>2}/{x:0>2}/{x:0>2}", .{ response.index, response.color.r, response.color.g, response.color.b }),
            .osc_dynamic_color => |response| try writer.print("osc{d}:rgb:{x:0>2}/{x:0>2}/{x:0>2}", .{ response.slot, response.color.r, response.color.g, response.color.b }),
            .osc_pointer_shape => |response| try writer.print("osc22:{s}({s}b)", .{ @tagName(response.kind), response.value }),
            .mouse_move => |info| try writer.print("{f}mouse_move@[{d}x{d}]", .{ info.mods, info.x, info.y }),
            .mouse_drag_left => |info| try writer.print("{f}mouse_drag+left_button@[{d}x{d}]", .{ info.mods, info.x, info.y }),
            .mouse_drag_middle => |info| try writer.print("{f}mouse_drag+middle_button@[{d}x{d}]", .{ info.mods, info.x, info.y }),
            .mouse_drag_right => |info| try writer.print("{f}mouse_drag+right_button@[{d}x{d}]", .{ info.mods, info.x, info.y }),
            .mouse_scroll_up => |info| try writer.print("{f}mouse_scroll_up@[{d}x{d}]", .{ info.mods, info.x, info.y }),
            .mouse_scroll_down => |info| try writer.print("{f}mouse_scroll_down@[{d}x{d}]", .{ info.mods, info.x, info.y }),
            .mouse_left_pressed => |info| try writer.print("{f}mouse_left_button_pressed@[{d}x{d}]", .{ info.mods, info.x, info.y }),
            .mouse_middle_pressed => |info| try writer.print("{f}mouse_middle_button_pressed@[{d}x{d}]", .{ info.mods, info.x, info.y }),
            .mouse_right_pressed => |info| try writer.print("{f}mouse_right_button_pressed@[{d}x{d}]", .{ info.mods, info.x, info.y }),
            .mouse_left_released => |info| try writer.print("{f}mouse_left_button_released@[{d}x{d}]", .{ info.mods, info.x, info.y }),
            .mouse_middle_released => |info| try writer.print("{f}mouse_middle_button_released@[{d}x{d}]", .{ info.mods, info.x, info.y }),
            .mouse_right_released => |info| try writer.print("{f}mouse_right_button_released@[{d}x{d}]", .{ info.mods, info.x, info.y }),
            .mouse_released => |info| try writer.print("{f}mouse_released@[{d}x{d}]", .{ info.mods, info.x, info.y }),
            .unrecognized => try writer.writeAll("unrecognized"),
        }
    }
};

pub const RGBColor = struct {
    r: u8,
    g: u8,
    b: u8,
};

pub const DECRPMStatus = enum(u8) {
    not_recognized = 0,
    set = 1,
    reset = 2,
    permanently_set = 3,
    permanently_reset = 4,
};

pub const DECRPMEvent = struct {
    mode: u16,
    status: DECRPMStatus,
};

pub const KittyKeyboardQueryEvent = struct {
    raw_flags: u16,
    known_flags: seq.kitty.Flags,
    unknown_flags: u16,
};

pub const DA1Extensions = packed struct {
    sixel: bool = false,
    selective_erase: bool = false,
    windowing: bool = false,
    horizontal_scrolling: bool = false,
    ansi_color: bool = false,
    ascii_emulation: bool = false,
    clipboard: bool = false,
};

pub const PrimaryDeviceAttributesEvent = struct {
    class_code: u16,
    extensions: DA1Extensions,
    unknown_extensions: bool,
};

pub const DA2KeyboardOption = enum(u2) {
    standard,
    pc,
    unknown,
};

pub const SecondaryDeviceAttributesEvent = struct {
    identification_code: u16,
    firmware_version: u16,
    keyboard_option: DA2KeyboardOption,
    keyboard_option_raw: u16,
    extra_parameters: bool,
};

pub const OSCPaletteColorEvent = struct {
    index: u8,
    color: RGBColor,
};

pub const OSCDynamicColorEvent = struct {
    slot: u8,
    color: RGBColor,
};

pub const OSCClipboardSelection = enum {
    clipboard,
    primary,
    select,
    cut0,
    cut1,
    cut2,
    cut3,
    cut4,
    cut5,
    cut6,
    cut7,
};

pub const OSCClipboardSelectionMask = packed struct(u16) {
    reserved_0: bool = false,
    clipboard: bool = false,
    primary: bool = false,
    select: bool = false,
    cut0: bool = false,
    cut1: bool = false,
    cut2: bool = false,
    cut3: bool = false,
    cut4: bool = false,
    cut5: bool = false,
    cut6: bool = false,
    cut7: bool = false,
    reserved: u4 = 0,

    pub const empty: OSCClipboardSelectionMask = .{};

    pub fn set(self: *OSCClipboardSelectionMask, selection: OSCClipboardSelection) void {
        switch (selection) {
            .clipboard => self.clipboard = true,
            .primary => self.primary = true,
            .select => self.select = true,
            .cut0 => self.cut0 = true,
            .cut1 => self.cut1 = true,
            .cut2 => self.cut2 = true,
            .cut3 => self.cut3 = true,
            .cut4 => self.cut4 = true,
            .cut5 => self.cut5 = true,
            .cut6 => self.cut6 = true,
            .cut7 => self.cut7 = true,
        }
    }

    pub fn format(self: OSCClipboardSelectionMask, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("raw={d}", .{@as(u16, @bitCast(self))});

        const has_any = self.clipboard or self.primary or self.select or self.cut0 or self.cut1 or self.cut2 or self.cut3 or self.cut4 or self.cut5 or self.cut6 or self.cut7;
        if (!has_any) {
            try writer.writeAll("(none)");
            return;
        }

        try writer.writeByte('(');
        var first = true;
        if (self.clipboard) {
            if (!first) try writer.writeByte(',');
            try writer.writeAll("clipboard");
            first = false;
        }
        if (self.primary) {
            if (!first) try writer.writeByte(',');
            try writer.writeAll("primary");
            first = false;
        }
        if (self.select) {
            if (!first) try writer.writeByte(',');
            try writer.writeAll("select");
            first = false;
        }
        if (self.cut0) {
            if (!first) try writer.writeByte(',');
            try writer.writeAll("cut0");
            first = false;
        }
        if (self.cut1) {
            if (!first) try writer.writeByte(',');
            try writer.writeAll("cut1");
            first = false;
        }
        if (self.cut2) {
            if (!first) try writer.writeByte(',');
            try writer.writeAll("cut2");
            first = false;
        }
        if (self.cut3) {
            if (!first) try writer.writeByte(',');
            try writer.writeAll("cut3");
            first = false;
        }
        if (self.cut4) {
            if (!first) try writer.writeByte(',');
            try writer.writeAll("cut4");
            first = false;
        }
        if (self.cut5) {
            if (!first) try writer.writeByte(',');
            try writer.writeAll("cut5");
            first = false;
        }
        if (self.cut6) {
            if (!first) try writer.writeByte(',');
            try writer.writeAll("cut6");
            first = false;
        }
        if (self.cut7) {
            if (!first) try writer.writeByte(',');
            try writer.writeAll("cut7");
        }
        try writer.writeByte(')');
    }
};

pub const OSCPointerShapeEvent = struct {
    kind: Kind,
    /// Reported pointer-shape value payload.
    ///
    /// This slice borrows parser input memory and is valid only until the next
    /// `terminal.Terminal.pollEvents` call on the same terminal instance.
    value: []const u8,

    pub const Kind = enum(u2) {
        shape_name,
        support_bitmap,
        empty,
    };
};

pub const ResizeEvent = struct {
    old_width: u16,
    old_height: u16,
    width: u16,
    height: u16,

    pub fn format(self: ResizeEvent, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("[{d}x{d}] -> [{d}x{d}]", .{ self.old_width, self.old_height, self.width, self.height });
    }
};

pub const MouseEvent = struct {
    mods: Mods,
    x: u16,
    y: u16,
};

pub const Mods = packed struct(u8) {
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
    super: bool = false,
    hyper: bool = false,
    meta: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,

    pub fn format(self: Mods, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (self.shift) try writer.writeAll("shift+");
        if (self.ctrl) try writer.writeAll("ctrl+");
        if (self.alt) try writer.writeAll("alt+");
        if (self.meta) try writer.writeAll("meta+");
        if (self.super) try writer.writeAll("super+");
        if (self.hyper) try writer.writeAll("hyper+");
        if (self.caps_lock) try writer.writeAll("caps_lock+");
        if (self.num_lock) try writer.writeAll("num_lock+");
    }
};

pub const KeyEvent = struct {
    code: Code,
    physical_key: PhysicalKey,
    mods: Mods,

    pub fn format(self: KeyEvent, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("{f}", .{self.mods});
        switch (self.code) {
            _ => |value| {
                const c: u21 = @intFromEnum(value);
                switch (c) {
                    32...126 => |code| {
                        try writer.writeByte(@truncate(code));
                    },
                    else => |code| try writer.print("{d}", .{code}),
                }
            },
            else => |code| try writer.print("{s}", .{@tagName(code)}),
        }
    }

    pub const PhysicalKey = enum(u8) {
        unknown = 0,
        backspace = 0x08,
        tab = 0x09,
        clear = 0x0c,
        enter = 0x0d,
        shift = 0x10,
        ctrl = 0x11,
        menu = 0x12,
        pause = 0x13,
        caps_lock = 0x14,
        kana_hangul = 0x15,
        ime_on = 0x16,
        junja = 0x17,
        final = 0x18,
        hanja_kanji = 0x19,
        ime_off = 0x1a,
        escape = 0x1b,
        convert = 0x1c,
        nonconvert = 0x1d,
        accept = 0x1e,
        mode_change = 0x1f,
        space = 0x20,
        page_up = 0x21,
        page_down = 0x22,
        end = 0x23,
        home = 0x24,
        left = 0x25,
        up = 0x26,
        right = 0x27,
        down = 0x28,
        select = 0x29,
        print = 0x2a,
        execute = 0x2b,
        print_screen = 0x2c,
        insert = 0x2d,
        delete = 0x2e,
        help = 0x2f,
        @"0" = 0x30,
        @"1" = 0x31,
        @"2" = 0x32,
        @"3" = 0x33,
        @"4" = 0x34,
        @"5" = 0x35,
        @"6" = 0x36,
        @"7" = 0x37,
        @"8" = 0x38,
        @"9" = 0x39,
        A = 0x41,
        B = 0x42,
        C = 0x43,
        D = 0x44,
        E = 0x45,
        F = 0x46,
        G = 0x47,
        H = 0x48,
        I = 0x49,
        J = 0x4a,
        K = 0x4b,
        L = 0x4c,
        M = 0x4d,
        N = 0x4e,
        O = 0x4f,
        P = 0x50,
        Q = 0x51,
        R = 0x52,
        S = 0x53,
        T = 0x54,
        U = 0x55,
        V = 0x56,
        W = 0x57,
        X = 0x58,
        Y = 0x59,
        Z = 0x5a,
        left_super = 0x5b,
        right_super = 0x5c,
        application = 0x5d,
        sleep = 0x5e,
        kp_0 = 0x60,
        kp_1 = 0x61,
        kp_2 = 0x62,
        kp_3 = 0x63,
        kp_4 = 0x64,
        kp_5 = 0x65,
        kp_6 = 0x66,
        kp_7 = 0x67,
        kp_8 = 0x68,
        kp_9 = 0x69,
        kp_multiply = 0x6a,
        kp_add = 0x6b,
        kp_separator = 0x6c,
        kp_subtract = 0x6d,
        kp_decimal = 0x6e,
        kp_divide = 0x6f,
        f1 = 0x70,
        f2 = 0x71,
        f3 = 0x72,
        f4 = 0x73,
        f5 = 0x74,
        f6 = 0x75,
        f7 = 0x76,
        f8 = 0x77,
        f9 = 0x78,
        f10 = 0x79,
        f11 = 0x7a,
        f12 = 0x7b,
        f13 = 0x7c,
        f14 = 0x7d,
        f15 = 0x7e,
        f16 = 0x7f,
        f17 = 0x80,
        f18 = 0x81,
        f19 = 0x82,
        f20 = 0x83,
        f21 = 0x84,
        f22 = 0x85,
        f23 = 0x86,
        f24 = 0x87,
        num_lock = 0x90,
        scroll_lock = 0x91,
        left_shift = 0xa0,
        right_shift = 0xa1,
        left_control = 0xa2,
        right_control = 0xa3,
        left_alt = 0xa4,
        right_alt = 0xa5,
        // browser_back = 0xa6,
        // browser_forward = 0xa7,
        // browser_refresh = 0xa8,
        // browser_stop = 0xa9,
        // browser_search = 0xaa,
        // browser_favorites = 0xab,
        // browser_home = 0xac,
        volume_mute = 0xad,
        volume_down = 0xae,
        volume_up = 0xaf,
        media_next = 0xb0,
        media_prev = 0xb1,
        media_stop = 0xb2,
        media_play_pause = 0xb3,
        // launch_mail = 0xb4,
        // launch_media = 0xb5,
        // launch_app1 = 0xb6,
        // launch_app2 = 0xb7,
        @";" = 0xba,
        @"=" = 0xbb,
        @"," = 0xbc,
        @"-" = 0xbd,
        @"." = 0xbe,
        @"/" = 0xbf,
        @"`" = 0xc0,
        @"[" = 0xdb,
        @"\\" = 0xdc,
        @"]" = 0xdd,
        @"'" = 0xde,
    };

    pub const Code = enum(u21) {
        unknown = std.math.maxInt(u21),
        tab = 0x09,
        enter = 0x0d,
        backspace = 0x7f,
        escape = 0x1b,
        space = 0x20,
        @"!" = 0x21,
        @"\"" = 0x22,
        @"#" = 0x23,
        @"$" = 0x24,
        @"%" = 0x25,
        @"&" = 0x26,
        @"'" = 0x27,
        @"(" = 0x28,
        @")" = 0x29,
        @"*" = 0x2a,
        @"+" = 0x2b,
        @"," = 0x2c,
        @"-" = 0x2d,
        @"." = 0x2e,
        @"/" = 0x2f,
        @"0" = 0x30,
        @"1" = 0x31,
        @"2" = 0x32,
        @"3" = 0x33,
        @"4" = 0x34,
        @"5" = 0x35,
        @"6" = 0x36,
        @"7" = 0x37,
        @"8" = 0x38,
        @"9" = 0x39,
        @":" = 0x3a,
        @";" = 0x3b,
        @"<" = 0x3c,
        @"=" = 0x3d,
        @">" = 0x3e,
        @"?" = 0x3f,
        @"@" = 0x40,
        A = 0x41,
        B = 0x42,
        C = 0x43,
        D = 0x44,
        E = 0x45,
        F = 0x46,
        G = 0x47,
        H = 0x48,
        I = 0x49,
        J = 0x4a,
        K = 0x4b,
        L = 0x4c,
        M = 0x4d,
        N = 0x4e,
        O = 0x4f,
        P = 0x50,
        Q = 0x51,
        R = 0x52,
        S = 0x53,
        T = 0x54,
        U = 0x55,
        V = 0x56,
        W = 0x57,
        X = 0x58,
        Y = 0x59,
        Z = 0x5a,
        @"[" = 0x5b,
        @"\\" = 0x5c,
        @"]" = 0x5d,
        @"^" = 0x5e,
        underscore = 0x5f,
        @"`" = 0x60,
        a = 0x61,
        b = 0x62,
        c = 0x63,
        d = 0x64,
        e = 0x65,
        f = 0x66,
        g = 0x67,
        h = 0x68,
        i = 0x69,
        j = 0x6A,
        k = 0x6B,
        l = 0x6C,
        m = 0x6D,
        n = 0x6E,
        o = 0x6F,
        p = 0x70,
        q = 0x71,
        r = 0x72,
        s = 0x73,
        t = 0x74,
        u = 0x75,
        v = 0x76,
        w = 0x77,
        x = 0x78,
        y = 0x79,
        z = 0x7A,
        @"{" = 0x7b,
        @"|" = 0x7c,
        @"}" = 0x7d,
        @"~" = 0x7e,
        insert = 0xe004,
        delete = 0xe003,
        left = 0xe006,
        right = 0xe007,
        up = 0xe008,
        down = 0xe009,
        page_up = 0xe00a,
        page_down = 0xe00b,
        home = 0xe00c,
        end = 0xe00d,
        caps_lock = 0xe00e,
        scroll_lock = 0xe00f,
        num_lock = 0xe010,
        print_screen = 0xe011,
        pause = 0xe012,
        menu = 0xe013,
        f1 = 0xe014,
        f2 = 0xe015,
        f3 = 0xe016,
        f4 = 0xe017,
        f5 = 0xe018,
        f6 = 0xe019,
        f7 = 0xe01a,
        f8 = 0xe01b,
        f9 = 0xe01c,
        f10 = 0xe01d,
        f11 = 0xe01e,
        f12 = 0xe01f,
        f13 = 0xe020,
        f14 = 0xe021,
        f15 = 0xe022,
        f16 = 0xe023,
        f17 = 0xe024,
        f18 = 0xe025,
        f19 = 0xe026,
        f20 = 0xe027,
        f21 = 0xe028,
        f22 = 0xe029,
        f23 = 0xe02a,
        f24 = 0xe02b,
        f25 = 0xe02c,
        f26 = 0xe02d,
        f27 = 0xe02e,
        f28 = 0xe02f,
        f29 = 0xe030,
        f30 = 0xe031,
        f31 = 0xe032,
        f32 = 0xe033,
        f33 = 0xe034,
        f34 = 0xe035,
        f35 = 0xe036,
        kp_0 = 0xe037,
        kp_1 = 0xe038,
        kp_2 = 0xe039,
        kp_3 = 0xe03a,
        kp_4 = 0xe03b,
        kp_5 = 0xe03c,
        kp_6 = 0xe03d,
        kp_7 = 0xe03e,
        kp_8 = 0xe03f,
        kp_9 = 0xe040,
        kp_decimal = 0xe041,
        kp_divide = 0xe042,
        kp_multiply = 0xe043,
        kp_subtract = 0xe044,
        kp_add = 0xe045,
        kp_enter = 0xe046,
        kp_equal = 0xe047,
        kp_separator = 0xe048,
        kp_left = 0xe049,
        kp_right = 0xe04a,
        kp_up = 0xe04b,
        kp_down = 0xe04c,
        kp_page_up = 0xe04d,
        kp_page_down = 0xe04e,
        kp_home = 0xe04f,
        kp_end = 0xe050,
        kp_insert = 0xe051,
        kp_delete = 0xe052,
        kp_begin = 0xe053,
        media_play = 0xe054,
        media_pause = 0xe055,
        media_play_pause = 0xe056,
        media_reverse = 0xe057,
        media_stop = 0xe058,
        media_fast_forward = 0xe059,
        media_rewind = 0xe05a,
        media_track_next = 0xe05b,
        media_track_previous = 0xe05c,
        media_record = 0xe05d,
        lower_volume = 0xe05e,
        raise_volume = 0xe05f,
        mute = 0xe060,
        left_shift = 0xe061,
        left_control = 0xe062,
        left_alt = 0xe063,
        left_super = 0xe064,
        left_hyper = 0xe065,
        left_meta = 0xe066,
        right_shift = 0xe067,
        right_control = 0xe068,
        right_alt = 0xe069,
        right_super = 0xe06a,
        right_hyper = 0xe06b,
        right_meta = 0xe06c,
        iso_level3_shift = 0xe06d,
        iso_level5_shift = 0xe06e,
        _,

        pub fn mapUsLayout(c: Code) struct { physical_key: PhysicalKey, shift: bool } {
            return switch (c) {
                .@"@" => .{ .physical_key = .@"2", .shift = true },
                .@"#" => .{ .physical_key = .@"3", .shift = true },
                .@"$" => .{ .physical_key = .@"4", .shift = true },
                .@"%" => .{ .physical_key = .@"5", .shift = true },
                .@"^" => .{ .physical_key = .@"6", .shift = true },
                .@"&" => .{ .physical_key = .@"7", .shift = true },
                .@"*" => .{ .physical_key = .@"8", .shift = true },
                .@"(" => .{ .physical_key = .@"9", .shift = true },
                .@")" => .{ .physical_key = .@"0", .shift = true },
                .underscore => .{ .physical_key = .@"-", .shift = true },
                .@"+" => .{ .physical_key = .@"=", .shift = true },
                .@"{" => .{ .physical_key = .@"[", .shift = true },
                .@"}" => .{ .physical_key = .@"]", .shift = true },
                .@"|" => .{ .physical_key = .@"\\", .shift = true },
                .@":" => .{ .physical_key = .@";", .shift = true },
                .@"\"" => .{ .physical_key = .@"'", .shift = true },
                .@"<" => .{ .physical_key = .@",", .shift = true },
                .@">" => .{ .physical_key = .@".", .shift = true },
                .@"?" => .{ .physical_key = .@"/", .shift = true },
                .@"~" => .{ .physical_key = .@"`", .shift = true },
                .A => .{ .physical_key = .A, .shift = true },
                .B => .{ .physical_key = .B, .shift = true },
                .C => .{ .physical_key = .C, .shift = true },
                .D => .{ .physical_key = .D, .shift = true },
                .E => .{ .physical_key = .E, .shift = true },
                .F => .{ .physical_key = .F, .shift = true },
                .G => .{ .physical_key = .G, .shift = true },
                .H => .{ .physical_key = .H, .shift = true },
                .I => .{ .physical_key = .I, .shift = true },
                .J => .{ .physical_key = .J, .shift = true },
                .K => .{ .physical_key = .K, .shift = true },
                .L => .{ .physical_key = .L, .shift = true },
                .M => .{ .physical_key = .M, .shift = true },
                .N => .{ .physical_key = .N, .shift = true },
                .O => .{ .physical_key = .O, .shift = true },
                .P => .{ .physical_key = .P, .shift = true },
                .Q => .{ .physical_key = .Q, .shift = true },
                .R => .{ .physical_key = .R, .shift = true },
                .S => .{ .physical_key = .S, .shift = true },
                .T => .{ .physical_key = .T, .shift = true },
                .U => .{ .physical_key = .U, .shift = true },
                .V => .{ .physical_key = .V, .shift = true },
                .W => .{ .physical_key = .W, .shift = true },
                .X => .{ .physical_key = .X, .shift = true },
                .Y => .{ .physical_key = .Y, .shift = true },
                .Z => .{ .physical_key = .Z, .shift = true },
                .enter => .{ .physical_key = .enter, .shift = false },
                .tab => .{ .physical_key = .tab, .shift = false },
                .backspace => .{ .physical_key = .backspace, .shift = false },
                .escape => .{ .physical_key = .escape, .shift = false },
                .space => .{ .physical_key = .space, .shift = false },
                .kp_0 => .{ .physical_key = .kp_0, .shift = false },
                .kp_1 => .{ .physical_key = .kp_1, .shift = false },
                .kp_2 => .{ .physical_key = .kp_2, .shift = false },
                .kp_3 => .{ .physical_key = .kp_3, .shift = false },
                .kp_4 => .{ .physical_key = .kp_4, .shift = false },
                .kp_5 => .{ .physical_key = .kp_5, .shift = false },
                .kp_6 => .{ .physical_key = .kp_6, .shift = false },
                .kp_7 => .{ .physical_key = .kp_7, .shift = false },
                .kp_8 => .{ .physical_key = .kp_8, .shift = false },
                .kp_9 => .{ .physical_key = .kp_9, .shift = false },
                .kp_multiply => .{ .physical_key = .kp_multiply, .shift = false },
                .kp_add => .{ .physical_key = .kp_add, .shift = false },
                .kp_separator => .{ .physical_key = .kp_separator, .shift = false },
                .kp_subtract => .{ .physical_key = .kp_subtract, .shift = false },
                .kp_decimal => .{ .physical_key = .kp_decimal, .shift = false },
                .kp_divide => .{ .physical_key = .kp_divide, .shift = false },
                .f1 => .{ .physical_key = .f1, .shift = false },
                .f2 => .{ .physical_key = .f2, .shift = false },
                .f3 => .{ .physical_key = .f3, .shift = false },
                .f4 => .{ .physical_key = .f4, .shift = false },
                .f5 => .{ .physical_key = .f5, .shift = false },
                .f6 => .{ .physical_key = .f6, .shift = false },
                .f7 => .{ .physical_key = .f7, .shift = false },
                .f8 => .{ .physical_key = .f8, .shift = false },
                .f9 => .{ .physical_key = .f9, .shift = false },
                .f10 => .{ .physical_key = .f10, .shift = false },
                .f11 => .{ .physical_key = .f11, .shift = false },
                .f12 => .{ .physical_key = .f12, .shift = false },
                .f13 => .{ .physical_key = .f13, .shift = false },
                .f14 => .{ .physical_key = .f14, .shift = false },
                .f15 => .{ .physical_key = .f15, .shift = false },
                .f16 => .{ .physical_key = .f16, .shift = false },
                .f17 => .{ .physical_key = .f17, .shift = false },
                .f18 => .{ .physical_key = .f18, .shift = false },
                .f19 => .{ .physical_key = .f19, .shift = false },
                .f20 => .{ .physical_key = .f20, .shift = false },
                .f21 => .{ .physical_key = .f21, .shift = false },
                .f22 => .{ .physical_key = .f22, .shift = false },
                .f23 => .{ .physical_key = .f23, .shift = false },
                .f24 => .{ .physical_key = .f24, .shift = false },
                .num_lock => .{ .physical_key = .num_lock, .shift = false },
                .scroll_lock => .{ .physical_key = .scroll_lock, .shift = false },
                .left_shift => .{ .physical_key = .left_shift, .shift = false },
                .right_shift => .{ .physical_key = .right_shift, .shift = false },
                .left_control => .{ .physical_key = .left_control, .shift = false },
                .right_control => .{ .physical_key = .right_control, .shift = false },
                .left_alt => .{ .physical_key = .left_alt, .shift = false },
                .right_alt => .{ .physical_key = .right_alt, .shift = false },
                .mute => .{ .physical_key = .volume_mute, .shift = false },
                .lower_volume => .{ .physical_key = .volume_down, .shift = false },
                .raise_volume => .{ .physical_key = .volume_up, .shift = false },
                .media_track_next => .{ .physical_key = .media_next, .shift = false },
                .media_track_previous => .{ .physical_key = .media_prev, .shift = false },
                .media_stop => .{ .physical_key = .media_stop, .shift = false },
                .media_play_pause => .{ .physical_key = .media_play_pause, .shift = false },
                .kp_begin => .{ .physical_key = .clear, .shift = false },
                .kp_enter => .{ .physical_key = .enter, .shift = false },
                .a => .{ .physical_key = .A, .shift = false },
                .b => .{ .physical_key = .B, .shift = false },
                .c => .{ .physical_key = .C, .shift = false },
                .d => .{ .physical_key = .D, .shift = false },
                .e => .{ .physical_key = .E, .shift = false },
                .f => .{ .physical_key = .F, .shift = false },
                .g => .{ .physical_key = .G, .shift = false },
                .h => .{ .physical_key = .H, .shift = false },
                .i => .{ .physical_key = .I, .shift = false },
                .j => .{ .physical_key = .J, .shift = false },
                .k => .{ .physical_key = .K, .shift = false },
                .l => .{ .physical_key = .L, .shift = false },
                .m => .{ .physical_key = .M, .shift = false },
                .n => .{ .physical_key = .N, .shift = false },
                .o => .{ .physical_key = .O, .shift = false },
                .p => .{ .physical_key = .P, .shift = false },
                .q => .{ .physical_key = .Q, .shift = false },
                .r => .{ .physical_key = .R, .shift = false },
                .s => .{ .physical_key = .S, .shift = false },
                .t => .{ .physical_key = .T, .shift = false },
                .u => .{ .physical_key = .U, .shift = false },
                .v => .{ .physical_key = .V, .shift = false },
                .w => .{ .physical_key = .W, .shift = false },
                .x => .{ .physical_key = .X, .shift = false },
                .y => .{ .physical_key = .Y, .shift = false },
                .z => .{ .physical_key = .Z, .shift = false },
                .left_super => .{ .physical_key = .left_super, .shift = false },
                .right_super => .{ .physical_key = .right_super, .shift = false },

                .@"!" => .{ .physical_key = .@"1", .shift = true },
                .@"'" => .{ .physical_key = .@"'", .shift = false },
                .@"," => .{ .physical_key = .@",", .shift = false },
                .@"-" => .{ .physical_key = .@"-", .shift = false },
                .@"." => .{ .physical_key = .@".", .shift = false },
                .@"/" => .{ .physical_key = .@"/", .shift = false },
                .@"0" => .{ .physical_key = .@"0", .shift = false },
                .@"1" => .{ .physical_key = .@"1", .shift = false },
                .@"2" => .{ .physical_key = .@"2", .shift = false },
                .@"3" => .{ .physical_key = .@"3", .shift = false },
                .@"4" => .{ .physical_key = .@"4", .shift = false },
                .@"5" => .{ .physical_key = .@"5", .shift = false },
                .@"6" => .{ .physical_key = .@"6", .shift = false },
                .@"7" => .{ .physical_key = .@"7", .shift = false },
                .@"8" => .{ .physical_key = .@"8", .shift = false },
                .@"9" => .{ .physical_key = .@"9", .shift = false },
                .@";" => .{ .physical_key = .@";", .shift = false },
                .@"=" => .{ .physical_key = .@"=", .shift = false },
                .@"[" => .{ .physical_key = .@"[", .shift = false },
                .@"\\" => .{ .physical_key = .@"\\", .shift = false },
                .@"]" => .{ .physical_key = .@"]", .shift = false },
                .@"`" => .{ .physical_key = .@"`", .shift = false },
                .insert => .{ .physical_key = .insert, .shift = false },
                .delete => .{ .physical_key = .delete, .shift = false },
                .left => .{ .physical_key = .left, .shift = false },
                .right => .{ .physical_key = .right, .shift = false },
                .up => .{ .physical_key = .up, .shift = false },
                .down => .{ .physical_key = .down, .shift = false },
                .page_up => .{ .physical_key = .page_up, .shift = false },
                .page_down => .{ .physical_key = .page_down, .shift = false },
                .home => .{ .physical_key = .home, .shift = false },
                .end => .{ .physical_key = .end, .shift = false },
                .caps_lock => .{ .physical_key = .caps_lock, .shift = false },
                .print_screen => .{ .physical_key = .print_screen, .shift = false },
                .pause => .{ .physical_key = .pause, .shift = false },
                .menu => .{ .physical_key = .menu, .shift = false },
                .kp_equal => .{ .physical_key = .@"=", .shift = false },
                .kp_left => .{ .physical_key = .left, .shift = false },
                .kp_right => .{ .physical_key = .right, .shift = false },
                .kp_up => .{ .physical_key = .up, .shift = false },
                .kp_down => .{ .physical_key = .down, .shift = false },
                .kp_page_up => .{ .physical_key = .page_up, .shift = false },
                .kp_page_down => .{ .physical_key = .page_down, .shift = false },
                .kp_home => .{ .physical_key = .home, .shift = false },
                .kp_end => .{ .physical_key = .end, .shift = false },
                .kp_insert => .{ .physical_key = .insert, .shift = false },
                .kp_delete => .{ .physical_key = .delete, .shift = false },
                .media_play => .{ .physical_key = .media_play_pause, .shift = false },
                .media_pause => .{ .physical_key = .media_play_pause, .shift = false },
                .media_reverse => .{ .physical_key = .media_prev, .shift = false },
                .media_fast_forward => .{ .physical_key = .media_next, .shift = false },
                .media_rewind => .{ .physical_key = .media_prev, .shift = false },
                .left_meta => .{ .physical_key = .left_alt, .shift = false },
                .right_meta => .{ .physical_key = .right_alt, .shift = false },
                else => .{ .physical_key = .unknown, .shift = false },
                _ => .{ .physical_key = .unknown, .shift = false },
            };
        }
    };
};
