const std = @import("std");

const stdx = @import("stdx");
const assert = stdx.inlineAssert;
const cutScalar = stdx.cutScalar;
const unicode = @import("unicode");

const e = @import("event.zig");
const Event = e.Event;
const KeyEvent = e.KeyEvent;
const MouseEvent = e.MouseEvent;
const Mods = e.Mods;
const DECRPMStatus = e.DECRPMStatus;
const DECRPMEvent = e.DECRPMEvent;
const KittyKeyboardQueryEvent = e.KittyKeyboardQueryEvent;
const DA1Extensions = e.DA1Extensions;
const PrimaryDeviceAttributesEvent = e.PrimaryDeviceAttributesEvent;
const DA2KeyboardOption = e.DA2KeyboardOption;
const SecondaryDeviceAttributesEvent = e.SecondaryDeviceAttributesEvent;
const OSCPaletteColorEvent = e.OSCPaletteColorEvent;
const OSCDynamicColorEvent = e.OSCDynamicColorEvent;
const OSCClipboardSelection = e.OSCClipboardSelection;
const OSCClipboardSelectionMask = e.OSCClipboardSelectionMask;
const OSCPointerShapeEvent = e.OSCPointerShapeEvent;
const RGBColor = e.RGBColor;
const seq = @import("sequences.zig");

pub const csi_len_max_default: usize = 129;
pub const osc_len_max_default: usize = 8193;

/// Result of parsing exactly one event from ground state.
///
/// Contract:
/// - `parseEvent` is called at ground state only.
/// - `consumed_bytes` is set to 0 only when `.need_more_input` is returned.
/// - All other results consume at least one byte.
pub const ParseResult = union(enum) {
    event: Event,
    osc52_start: OSCStartEvent,
    skip_till_st,
    csi_overflow,
    osc_overflow,
    need_more_input,
    ignored,
};

pub const OSCStartEvent = struct {
    selection_mask: OSCClipboardSelectionMask,
};

inline fn skipTillST(consumed_bytes: *usize, consumed: usize) ParseResult {
    consumed_bytes.* = consumed;
    return .skip_till_st;
}

/// Parse one event from a terminal byte stream assuming ground state.
///
/// The parser recognizes 7-bit (`ESC`-prefixed) and 8-bit C1 introducers.
/// Under this contract, C1 bytes are interpreted as control-sequence starts,
/// not UTF-8 payload bytes.
pub fn parseEvent(data: []const u8, consumed_bytes: *usize) ParseResult {
    consumed_bytes.* = 0;
    if (data.len == 0) return .need_more_input;

    switch (data[0]) {
        '\x1b' => {
            if (data.len == 1) {
                return parseAscii(data, consumed_bytes);
            }

            switch (data[1]) {
                'O' => return parseSS3(data, consumed_bytes),
                '[' => return parseCSI(data, consumed_bytes),
                ']' => return parseOSC(data, consumed_bytes),
                // Probably best to consume these so we
                // dont get a spam of key presses if they ever comes our way.
                // Especially if we want to build pseudo terminals.
                'P' => return skipTillST(consumed_bytes, 2),
                '^' => return skipTillST(consumed_bytes, 2),
                'X' => return skipTillST(consumed_bytes, 2),
                '_' => return skipTillST(consumed_bytes, 2),
                else => {
                    // @TODO GILA(robust_blade_k7m) Define one explicit ESC ambiguity policy:
                    // prefer parsing control sequences first and only synthesize Alt-modified
                    // key events when disambiguation is explicit (for example kitty protocol).
                    var utf8_consumed_bytes: usize = 0;
                    var key_event = parseAscii(data[1..], &utf8_consumed_bytes);
                    if (key_event == .need_more_input) {
                        consumed_bytes.* = 0;
                        return .need_more_input;
                    }
                    assert(key_event == .event);
                    key_event.event.key_pressed.mods.alt = true;
                    consumed_bytes.* = 1 + utf8_consumed_bytes;
                    return key_event;
                },
            }
        },
        // @NOTE This is mostly just there because it is remotely possible that some terminal is running in 8bit mode
        //       for who knows what reason. Putting it here cause it does not hurt. These characters are not valid starts
        //       of sequences as we always enter parseEvent assuming ground state.
        0x9d => return parseOSC(data, consumed_bytes), // ESC ]
        0x9b => return parseCSI(data, consumed_bytes), // ESC [
        0x8f => return parseSS3(data, consumed_bytes), // ESC O
        0x90 => return skipTillST(consumed_bytes, 1), // ESC P
        0x9e => return skipTillST(consumed_bytes, 1), // ESC ^
        0x98 => return skipTillST(consumed_bytes, 1), // ESC X
        0x9f => return skipTillST(consumed_bytes, 1), // ESC _
        else => {
            // @TODO GILA(anguished_claw_dzt) If \x1b is a lone byte we cant tell if it is an incomplete sequence or a part of
            // a continuation
            // @TODO GILA(gleeful_beam_g5f) If we get \x1b[ we cant tell if it is incomplete or alt + [
            return parseAscii(data, consumed_bytes);
        },
    }
}

fn parseAscii(data: []const u8, consumed_bytes: *usize) ParseResult {
    if (data.len == 0) return .need_more_input;
    consumed_bytes.* = 1;

    switch (data[0]) {
        0x00 => return .{ .event = .{ .key_pressed = .{ .code = @enumFromInt('@'), .mods = .{ .ctrl = true }, .physical_key = .@"2" } } },
        0x1b => return .{ .event = .{ .key_pressed = .{ .code = .escape, .mods = .{}, .physical_key = .escape } } },
        0x0D => return .{ .event = .{ .key_pressed = .{ .code = .enter, .mods = .{}, .physical_key = .enter } } },
        0x0A => return .{ .event = .{ .key_pressed = .{ .code = @enumFromInt('j'), .mods = .{ .ctrl = true }, .physical_key = .J } } },
        0x09 => return .{ .event = .{ .key_pressed = .{ .code = .tab, .mods = .{}, .physical_key = .tab } } },
        0x7F => return .{ .event = .{ .key_pressed = .{ .code = .backspace, .mods = .{}, .physical_key = .backspace } } },
        1...8, 11, 12, 14...26, 0x1C...0x1F => |ctrl| {
            const code: KeyEvent.Code = @enumFromInt(if (ctrl <= 0x1A) ctrl + 'a' - 1 else ctrl + 0x18);
            const mapped_key = code.mapUsLayout();
            return .{ .event = .{ .key_pressed = .{ .code = code, .mods = .{ .ctrl = true, .shift = mapped_key.shift }, .physical_key = mapped_key.physical_key } } };
        },
        0x80...0xFF => {
            @branchHint(.unlikely);
        },
        else => {
            const code: KeyEvent.Code = @enumFromInt(data[0]);
            const mapped_key = code.mapUsLayout();
            return .{ .event = .{ .key_pressed = .{ .code = code, .mods = .{ .shift = mapped_key.shift }, .physical_key = mapped_key.physical_key } } };
        },
    }

    consumed_bytes.* = 0;
    var decoder: unicode.UTF8Decoder = .start;
    var index: usize = 0;
    var codepoint_opt: ?u21 = null;

    while (index < data.len) {
        const decoded_codepoint, const did_consume = decoder.decode(data[index]);
        if (did_consume) index += 1;
        if (decoded_codepoint) |codepoint| {
            codepoint_opt = codepoint;
            break;
        }
    }

    const codepoint = codepoint_opt orelse return .need_more_input;
    consumed_bytes.* = index;

    // @TODO GILA(twin_radar_74b)
    const code: KeyEvent.Code = @enumFromInt(codepoint);
    const mapped_key = code.mapUsLayout();
    return .{ .event = .{ .key_pressed = .{ .code = code, .mods = .{ .shift = mapped_key.shift }, .physical_key = mapped_key.physical_key } } };
}

fn ss3IntroducerLen(data: []const u8) usize {
    assert(data.len > 0);
    switch (data[0]) {
        0x1b => {
            @branchHint(.likely);
            assert(data.len >= 2);
            assert(data[1] == 'O');
            return 2;
        },
        0x8f => return 1,
        else => unreachable,
    }
}

fn parseSS3(data: []const u8, consumed_bytes: *usize) ParseResult {
    const introducer_len: usize = ss3IntroducerLen(data);
    if (data.len < introducer_len + 1) return .need_more_input;

    const event: Event = switch (data[introducer_len]) {
        // TODO GILA(angelic_kamodo_zx1) deal with multiple escape sequences
        '\x1b' => {
            consumed_bytes.* = introducer_len;
            return .ignored;
        },
        'A' => .{ .key_pressed = .{ .code = .up, .physical_key = .up, .mods = .{} } },
        'B' => .{ .key_pressed = .{ .code = .down, .physical_key = .down, .mods = .{} } },
        'C' => .{ .key_pressed = .{ .code = .right, .physical_key = .right, .mods = .{} } },
        'D' => .{ .key_pressed = .{ .code = .left, .physical_key = .left, .mods = .{} } },
        'E' => .{ .key_pressed = .{ .code = .kp_begin, .physical_key = .clear, .mods = .{} } },
        'F' => .{ .key_pressed = .{ .code = .end, .physical_key = .end, .mods = .{} } },
        'H' => .{ .key_pressed = .{ .code = .home, .physical_key = .home, .mods = .{} } },
        'P' => .{ .key_pressed = .{ .code = .f1, .physical_key = .f1, .mods = .{} } },
        'Q' => .{ .key_pressed = .{ .code = .f2, .physical_key = .f2, .mods = .{} } },
        'R' => .{ .key_pressed = .{ .code = .f3, .physical_key = .f3, .mods = .{} } },
        'S' => .{ .key_pressed = .{ .code = .f4, .physical_key = .f4, .mods = .{} } },
        else => {
            consumed_bytes.* = introducer_len + 1;
            return .ignored;
        },
    };
    consumed_bytes.* = introducer_len + 1;
    return .{ .event = event };
}

const ScanResult = union(enum) {
    complete: usize,
    incomplete,
    malformed: usize,
    too_long: usize,
};

inline fn isCSIParameterByte(byte: u8) bool {
    return byte >= 0x30 and byte <= 0x3F;
}

inline fn isCSIIntermediateByte(byte: u8) bool {
    return byte >= 0x20 and byte <= 0x2F;
}

inline fn isCSIFinalByte(byte: u8) bool {
    return byte >= 0x40 and byte <= 0x7E;
}

const CSIScanOptions = struct {
    csi_len_max: usize = csi_len_max_default,
};

fn csiIntroducerLen(data: []const u8) usize {
    assert(data.len > 0);
    switch (data[0]) {
        0x1b => {
            @branchHint(.likely);
            assert(data.len >= 2);
            assert(data[1] == '[');
            return 2;
        },
        0x9b => return 1,
        else => unreachable,
    }
}

/// Scan CSI using ECMA-48 rules.
/// https://ecma-international.org/wp-content/uploads/ECMA-48_5th_edition_june_1991.pdf
/// CSI P ... P I ... I F
/// P: parameter bytes (0x30..0x3F)
/// I: intermediate bytes (0x20..0x2F)
/// F: final byte (0x40..0x7E)
/// Everythign else is invalid.
fn scanCSI(data: []const u8, options: CSIScanOptions) ScanResult {
    const introducer_len = csiIntroducerLen(data);
    if (data.len <= introducer_len) return .incomplete;

    // Guard against overflow if someone passes absurd max.
    const capped_max = @min(options.csi_len_max, std.math.maxInt(usize) - introducer_len);
    const limit = @min(data.len, introducer_len + capped_max);

    var i: usize = introducer_len;
    // CSI <P ... P> I ... I F
    while (i < limit and isCSIParameterByte(data[i])) : (i += 1) {}
    // CSI P ... P <I ... I> F
    while (i < limit and isCSIIntermediateByte(data[i])) : (i += 1) {}

    if (i < limit) {
        if (isCSIFinalByte(data[i])) {
            return .{ .complete = i + 1 };
        } else {
            // @NOTE encountered a byte after intermedaite that is not a valid
            // ECMA-48 final byte. This is not a valid CSI sequence.
            // We leave the final byte to try to reparse.
            return .{ .malformed = i };
        }
    } else {
        if (limit < data.len) return .{ .too_long = limit };
        return .incomplete;
    }
}

fn parseCSI(data: []const u8, consumed_bytes: *usize) ParseResult {
    const introducer_len = csiIntroducerLen(data);
    if (data.len <= introducer_len) return .need_more_input;

    const result = scanCSI(data, .{});
    switch (result) {
        .complete => |n| {
            assert(n > introducer_len);
            consumed_bytes.* = n;
            const csi = data[0..n];
            const payload_with_final = csi[introducer_len..];
            assert(payload_with_final.len > 0);
            const final = payload_with_final[payload_with_final.len - 1];
            const payload = payload_with_final[0 .. payload_with_final.len - 1];

            return switch (final) {
                'M', 'm' => parseMouse(final, payload, data, csi.len, consumed_bytes),
                'A', 'B', 'C', 'D', 'E', 'F', 'H', 'P', 'Q', 'S' => parseLegacyCursorKeys(final, payload),
                '~' => parseLegacyTildeSequences(payload),
                'c' => parseDeviceAttributes(payload),
                'n' => .ignored, // @TODO GILA(odd_flux_g9x)
                't' => .ignored, // @TODO GILA(wry_ray_32j)
                'y' => parseDECRPM(payload),
                'q' => .ignored, // @TODO GILA(rough_fang_bxy)
                'u' => parseKitty(payload),
                else => .ignored,
            };
        },
        .incomplete => return .need_more_input,
        .malformed => |n| {
            consumed_bytes.* = n;
            return .ignored;
        },
        .too_long => |n| {
            consumed_bytes.* = n;
            return .csi_overflow;
        },
    }
    unreachable;
}

fn parseKitty(payload: []const u8) ParseResult {
    if (payload.len == 0) return .ignored;
    if (payload[0] == '?') return parseKittyKeyboardQuery(payload);
    return parseKittyKeyboardProtocol(payload);
}

const KeyEventType = enum(u8) {
    pressed = 1,
    repeat = 2,
    released = 3,
};

fn parseKittyKeyboardProtocol(payload: []const u8) ParseResult {
    // @NOTE https://sw.kovidgoyal.net/kitty/keyboard-protocol/#an-overview
    //     CSI unicode-key-code:alternate-key-codes ; modifiers:event-type ; text-as-codepoints u
    // Only the unicode-key-code field is mandatory, everything else is optional.
    if (payload.len == 0) return .ignored;

    const first, const remaining = if (cutScalar(u8, payload, ';')) |result| result else .{ payload, &.{} };
    const key_code, const alt_key_code = if (cutScalar(u8, first, ':')) |result| result else .{ first, &.{} };

    var key_event: KeyEvent = undefined;

    const code = parseValue(u21, key_code, null) orelse return .ignored;
    key_event.code = @enumFromInt(code);
    key_event.physical_key = key_event.code.mapUsLayout().physical_key;
    key_event.mods = .{};

    // @TODO GILA(fluffy_tail_yw4)
    _ = alt_key_code;
    if (remaining.len == 0) return .{ .event = .{ .key_pressed = key_event } };

    const modifier_event_type, const text_as_codepoint = if (cutScalar(u8, remaining, ';')) |result| result else .{ remaining, &.{} };
    const modifier_string, const event_type = if (cutScalar(u8, modifier_event_type, ':')) |result| result else .{ modifier_event_type, &.{} };

    const mod_value = parseValue(u9, modifier_string, 1) orelse return .ignored;
    if (mod_value == 0 or mod_value > 256) return .ignored; // @NOTE Malformed
    key_event.mods = @bitCast(@as(u8, @intCast(mod_value - 1)));

    const event = parseValue(u8, event_type, 1) orelse return .ignored;
    const key_state: KeyEventType = std.enums.fromInt(KeyEventType, event) orelse return .ignored;

    // @TODO GILA(fluffy_tail_yw4)
    _ = text_as_codepoint;

    return switch (key_state) {
        .pressed => .{ .event = .{ .key_pressed = key_event } },
        .repeat => .{ .event = .{ .key_repeat = key_event } },
        .released => .{ .event = .{ .key_released = key_event } },
    };
}

fn parseKittyKeyboardQuery(payload: []const u8) ParseResult {
    if (payload.len < 1 or payload[0] != '?') return .ignored;
    const body = payload[1..];

    const flags_string, _ = if (cutScalar(u8, body, ';')) |result| result else .{ body, &.{} };
    const raw_flags = parseValue(u16, flags_string, 0) orelse return .ignored;
    const known_flags_mask: u16 = 0b1_1111;
    const known_flags: seq.kitty.Flags = .{
        .disambiguate_escape_codes = (raw_flags & 0b00001) != 0,
        .report_event_types = (raw_flags & 0b00010) != 0,
        .report_alternate_keys = (raw_flags & 0b00100) != 0,
        .report_all_keys_as_escape_codes = (raw_flags & 0b01000) != 0,
        .report_associated_text = (raw_flags & 0b10000) != 0,
        .padding = 0,
    };
    return .{ .event = .{ .kitty_keyboard_query = .{
        .raw_flags = raw_flags,
        .known_flags = known_flags,
        .unknown_flags = raw_flags & ~known_flags_mask,
    } } };
}

fn parseDECRPM(payload: []const u8) ParseResult {
    if (payload.len < 4) return .ignored;
    if (payload[payload.len - 1] != '$') return .ignored;

    const body = payload[0 .. payload.len - 1];
    if (body[0] != '?') return .ignored;

    const mode_string, const status_string = cutScalar(u8, body[1..], ';') orelse return .ignored;
    const mode = parseValue(u16, mode_string, null) orelse return .ignored;
    const status_value = parseValue(u8, status_string, null) orelse return .ignored;
    const status = std.enums.fromInt(DECRPMStatus, status_value) orelse return .ignored;
    return .{ .event = .{ .decrpm = .{ .mode = mode, .status = status } } };
}

fn parseDeviceAttributes(payload: []const u8) ParseResult {
    if (payload.len == 0) return .ignored;

    const body = payload[1..];
    return switch (payload[0]) {
        '?' => parsePrimaryDeviceAttributes(body),
        '>' => parseSecondaryDeviceAttributes(body),
        else => .ignored,
    };
}

fn parsePrimaryDeviceAttributes(body: []const u8) ParseResult {
    if (body.len == 0) return .ignored;

    const class_code_string, var remaining = if (cutScalar(u8, body, ';')) |result| result else .{ body, &.{} };
    const class_code = parseValue(u16, class_code_string, null) orelse return .ignored;

    var extensions: DA1Extensions = .{};
    var unknown_extensions = false;
    while (remaining.len > 0) {
        const extension_string, remaining = if (cutScalar(u8, remaining, ';')) |result| result else .{ remaining, &.{} };
        const extension = parseValue(u16, extension_string, null) orelse return .ignored;
        switch (extension) {
            4 => extensions.sixel = true,
            6 => extensions.selective_erase = true,
            18 => extensions.windowing = true,
            21 => extensions.horizontal_scrolling = true,
            22 => extensions.ansi_color = true,
            46 => extensions.ascii_emulation = true,
            52 => extensions.clipboard = true,
            else => unknown_extensions = true,
        }
    }

    return .{ .event = .{ .primary_device_attributes = .{
        .class_code = class_code,
        .extensions = extensions,
        .unknown_extensions = unknown_extensions,
    } } };
}

fn parseSecondaryDeviceAttributes(body: []const u8) ParseResult {
    const identification_code_string, const remaining_after_identification = cutScalar(u8, body, ';') orelse return .ignored;
    const firmware_version_string, const remaining_after_firmware = cutScalar(u8, remaining_after_identification, ';') orelse return .ignored;
    const keyboard_option_string, var remaining = if (cutScalar(u8, remaining_after_firmware, ';')) |result| result else .{ remaining_after_firmware, &.{} };

    const identification_code = parseValue(u16, identification_code_string, null) orelse return .ignored;
    const firmware_version = parseValue(u16, firmware_version_string, null) orelse return .ignored;
    const keyboard_option_raw = parseValue(u16, keyboard_option_string, null) orelse return .ignored;

    var extra_parameters = false;
    while (remaining.len > 0) {
        const extra_parameter_string, const next = if (cutScalar(u8, remaining, ';')) |result| result else .{ remaining, &.{} };
        _ = parseValue(u16, extra_parameter_string, null) orelse return .ignored;
        extra_parameters = true;
        remaining = next;
    }

    const keyboard_option: DA2KeyboardOption = switch (keyboard_option_raw) {
        0 => .standard,
        1 => .pc,
        else => .unknown,
    };

    return .{ .event = .{ .secondary_device_attributes = .{
        .identification_code = identification_code,
        .firmware_version = firmware_version,
        .keyboard_option = keyboard_option,
        .keyboard_option_raw = keyboard_option_raw,
        .extra_parameters = extra_parameters,
    } } };
}

fn parseLegacyCursorKeys(final: u8, payload: []const u8) ParseResult {
    // @NOTE There are two types of events that end in these letters https://sw.kovidgoyal.net/kitty/keyboard-protocol/#legacy-key-event-encoding
    //     CSI {A,B,C,D,E,F,H,P,Q,S} (legacy)
    //     CSI 1; modifier:type {A,B,C,D,E,F,H,P,Q,S}
    //
    //     CSI R was supported as F3 in the original version but was dropped as it conflicts with cursor position reporting
    //     @TODO Should we support CSI R as F3 or should we just ignore it?

    var key_event: KeyEvent = undefined;
    key_event.code, key_event.physical_key = switch (final) {
        'A' => .{ KeyEvent.Code.up, KeyEvent.PhysicalKey.up },
        'B' => .{ KeyEvent.Code.down, KeyEvent.PhysicalKey.down },
        'C' => .{ KeyEvent.Code.right, KeyEvent.PhysicalKey.right },
        'D' => .{ KeyEvent.Code.left, KeyEvent.PhysicalKey.left },
        'E' => .{ KeyEvent.Code.kp_begin, KeyEvent.PhysicalKey.clear },
        'F' => .{ KeyEvent.Code.end, KeyEvent.PhysicalKey.end },
        'H' => .{ KeyEvent.Code.home, KeyEvent.PhysicalKey.home },
        'P' => .{ KeyEvent.Code.f1, KeyEvent.PhysicalKey.f1 },
        'Q' => .{ KeyEvent.Code.f2, KeyEvent.PhysicalKey.f2 },
        'S' => .{ KeyEvent.Code.f4, KeyEvent.PhysicalKey.f4 },
        else => unreachable,
    };
    key_event.mods = .{};
    if (payload.len == 0) return .{ .event = .{ .key_pressed = key_event } };

    const left, const right = cutScalar(u8, payload, ';') orelse return .ignored;
    if (left.len != 1 or (left.len == 1 and left[0] != '1')) return .ignored;

    const modifier, const event_type = if (cutScalar(u8, right, ':')) |result| result else .{ right, &.{} };
    const mod_value = parseValue(u9, modifier, 1) orelse return .ignored;
    if (mod_value == 0 or mod_value > 256) return .ignored; // @NOTE Malformed
    key_event.mods = @bitCast(@as(u8, @intCast(mod_value - 1)));

    const event = parseValue(u8, event_type, 1) orelse return .ignored;
    const key_state: KeyEventType = std.enums.fromInt(KeyEventType, event) orelse return .ignored;
    return switch (key_state) {
        .pressed => .{ .event = .{ .key_pressed = key_event } },
        .repeat => .{ .event = .{ .key_repeat = key_event } },
        .released => .{ .event = .{ .key_released = key_event } },
    };
}

fn parseLegacyTildeSequences(payload: []const u8) ParseResult {
    // @NOTE There are three types of events that end in ~
    //     CSI number ~
    //     CSI number; modifier:type ~
    //     CSI number; modifier:type; text_as_codepoint ~
    // see: https://sw.kovidgoyal.net/kitty/keyboard-protocol/#an-overview
    const string_number, const remaining = if (cutScalar(u8, payload, ';')) |result| result else .{ payload, &.{} };
    const number = parseValue(u16, string_number, null) orelse return .ignored;

    var key_event: KeyEvent = undefined;
    key_event.code, key_event.physical_key = switch (number) {
        2 => .{ KeyEvent.Code.insert, KeyEvent.PhysicalKey.insert },
        3 => .{ KeyEvent.Code.delete, KeyEvent.PhysicalKey.delete },
        5 => .{ KeyEvent.Code.page_up, KeyEvent.PhysicalKey.page_up },
        6 => .{ KeyEvent.Code.page_down, KeyEvent.PhysicalKey.page_down },
        7 => .{ KeyEvent.Code.home, KeyEvent.PhysicalKey.home },
        8 => .{ KeyEvent.Code.end, KeyEvent.PhysicalKey.end },
        11 => .{ KeyEvent.Code.f1, KeyEvent.PhysicalKey.f1 },
        12 => .{ KeyEvent.Code.f2, KeyEvent.PhysicalKey.f2 },
        13 => .{ KeyEvent.Code.f3, KeyEvent.PhysicalKey.f3 },
        14 => .{ KeyEvent.Code.f4, KeyEvent.PhysicalKey.f4 },
        15 => .{ KeyEvent.Code.f5, KeyEvent.PhysicalKey.f5 },
        17 => .{ KeyEvent.Code.f6, KeyEvent.PhysicalKey.f6 },
        18 => .{ KeyEvent.Code.f7, KeyEvent.PhysicalKey.f7 },
        19 => .{ KeyEvent.Code.f8, KeyEvent.PhysicalKey.f8 },
        20 => .{ KeyEvent.Code.f9, KeyEvent.PhysicalKey.f9 },
        21 => .{ KeyEvent.Code.f10, KeyEvent.PhysicalKey.f10 },
        23 => .{ KeyEvent.Code.f11, KeyEvent.PhysicalKey.f11 },
        24 => .{ KeyEvent.Code.f12, KeyEvent.PhysicalKey.f12 },
        29 => .{ KeyEvent.Code.menu, KeyEvent.PhysicalKey.menu },
        57427 => .{ KeyEvent.Code.kp_begin, KeyEvent.PhysicalKey.clear },
        200 => return .{ .event = .paste_start },
        201 => return .{ .event = .paste_end },
        else => return .ignored,
    };
    key_event.mods = .{};
    if (remaining.len == 0) return .{ .event = .{ .key_pressed = key_event } };

    const modifier_event_type, const text_as_codepoint = if (cutScalar(u8, remaining, ';')) |result|
        result
    else
        .{ remaining, &.{} };

    const modifier_string, const event_type = if (cutScalar(u8, modifier_event_type, ':')) |result|
        result
    else
        .{ modifier_event_type, &.{} };

    const mod_value = parseValue(u9, modifier_string, 1) orelse return .ignored;
    if (mod_value == 0 or mod_value > 256) return .ignored; // @NOTE Malformed
    key_event.mods = @bitCast(@as(u8, @intCast(mod_value - 1)));

    const event = parseValue(u8, event_type, 1) orelse return .ignored;
    const key_state: KeyEventType = std.enums.fromInt(KeyEventType, event) orelse return .ignored;

    // @TODO GILA(fluffy_tail_yw4)
    _ = text_as_codepoint;
    return switch (key_state) {
        .pressed => .{ .event = .{ .key_pressed = key_event } },
        .repeat => .{ .event = .{ .key_repeat = key_event } },
        .released => .{ .event = .{ .key_released = key_event } },
    };
}

fn parseMouse(final: u8, payload: []const u8, data: []const u8, csi_len: usize, consumed_bytes: *usize) ParseResult {
    assert(final == 'M' or final == 'm');

    var sgr: bool = false;
    const number, const x, const y = if (payload.len == 0 and final == 'M') blk: {
        // @NOTE SGR off
        if (data.len < csi_len + 3) {
            consumed_bytes.* = 0;
            return .need_more_input;
        }
        if (data[csi_len] < 32 or data[csi_len + 1] < 32 or data[csi_len + 2] < 32) {
            return .ignored;
        }
        consumed_bytes.* = csi_len + 3;
        const number: u16 = data[csi_len] - 32;
        const x: u16 = data[csi_len + 1] - 32;
        const y: u16 = data[csi_len + 2] - 32;
        // Ignore SGR events with coordinates (0,0) this is malformed
        if (x == 0 or y == 0) return .ignored;
        break :blk .{ number, x, y };
    } else if (payload.len >= 1 and payload[0] == '<') blk: {
        // @NOTE SGR on
        sgr = true;
        assert(consumed_bytes.* == csi_len);
        const mouse_event_type, const coordinates = cutScalar(u8, payload[1..], ';') orelse return .ignored;
        const string_x, const string_y = cutScalar(u8, coordinates, ';') orelse return .ignored;
        const x = parseValue(u16, string_x, null) orelse return .ignored;
        const y = parseValue(u16, string_y, null) orelse return .ignored;
        const number = parseValue(u16, mouse_event_type, null) orelse return .ignored;
        if (x == 0 or y == 0) return .ignored;
        break :blk .{ number, x, y };
    } else return .ignored;

    const Button = enum(u8) {
        left = 0,
        middle = 1,
        right = 2,
        move_or_release = 3,
    };
    const shift_bit = 4;
    const alt_bit = 8;
    const ctrl_bit = 16;
    const move_mask = 32;
    const mouse_scroll_mask = 64;

    if (number > 255) return .ignored;

    const has_extended_button = (number & 128) != 0;
    if (has_extended_button) {
        // Buttons 8-11 share this bit. They are currently unsupported and must
        // not alias to left/middle/right events.
        return .ignored;
    }

    const button: Button = @enumFromInt(number & 0b11);
    const ctrl: bool = (number & ctrl_bit) != 0;
    const alt: bool = (number & alt_bit) != 0;
    const shift: bool = (number & shift_bit) != 0;
    const mouse_scroll = (number & mouse_scroll_mask) == mouse_scroll_mask;
    const mouse_move = (number & move_mask) == move_mask;

    if (mouse_move and mouse_scroll) return .ignored;

    // Buttons 6-7 are encoded using the wheel bit with low bits 2-3.
    // They are currently unsupported and must not be reinterpreted.
    if (mouse_scroll and (button == .right or button == .move_or_release)) return .ignored;

    // Wheel releases are not defined in XTerm/SGR reporting.
    if (mouse_scroll and final == 'm') return .ignored;

    const info: MouseEvent = .{
        .mods = .{ .ctrl = ctrl, .alt = alt, .shift = shift },
        .x = x,
        .y = y,
    };

    if (mouse_scroll) switch (button) {
        .left => return .{ .event = .{ .mouse_scroll_up = info } },
        .middle => return .{ .event = .{ .mouse_scroll_down = info } },
        else => return .ignored,
    } else if (mouse_move) switch (button) {
        .left => return .{ .event = .{ .mouse_drag_left = info } },
        .middle => return .{ .event = .{ .mouse_drag_middle = info } },
        .right => return .{ .event = .{ .mouse_drag_right = info } },
        .move_or_release => if (sgr) return .{ .event = .{ .mouse_move = info } } else return .ignored,
    } else switch (button) {
        .left => {
            if (final == 'm')
                return .{ .event = .{ .mouse_left_released = info } }
            else
                return .{ .event = .{ .mouse_left_pressed = info } };
        },
        .middle => {
            if (final == 'm')
                return .{ .event = .{ .mouse_middle_released = info } }
            else
                return .{ .event = .{ .mouse_middle_pressed = info } };
        },
        .right => {
            if (final == 'm')
                return .{ .event = .{ .mouse_right_released = info } }
            else
                return .{ .event = .{ .mouse_right_pressed = info } };
        },
        .move_or_release => if (!sgr) return .{ .event = .{ .mouse_released = info } } else return .ignored,
    }
    unreachable;
}

const OSC52Header = struct {
    payload_start: usize,
    selection_mask: OSCClipboardSelectionMask,
};

const OSCScanResult = union(enum) {
    complete: struct { payload_len: usize, terminator_len: usize },
    osc_start: OSC52Header,
    incomplete,
    malformed: usize,
    too_long: usize,
};

const OSCScanOptions = struct {
    osc_len_max: usize = osc_len_max_default,
};

fn oscIntroducerLen(data: []const u8) usize {
    assert(data.len > 0);
    switch (data[0]) {
        0x1b => {
            assert(data.len >= 2);
            assert(data[1] == ']');
            return 2;
        },
        0x9d => return 1,
        else => unreachable,
    }
}

fn tooLongConsumed(data: []const u8, introducer_len: usize, limit: usize) usize {
    assert(limit <= data.len);
    const bounded_limit = @min(limit, data.len);
    if (bounded_limit > introducer_len and data[bounded_limit - 1] == '\x1b') {
        return bounded_limit - 1;
    }
    return bounded_limit;
}

fn scanOSC(data: []const u8, options: OSCScanOptions) OSCScanResult {
    const introducer_len = oscIntroducerLen(data);
    if (data.len <= introducer_len) return .incomplete;

    const capped_max = @min(options.osc_len_max, std.math.maxInt(usize) - introducer_len);
    const limit = @min(data.len, introducer_len + capped_max);

    // Fast path for OSC 52 clipboard stream header.
    if (data[introducer_len] == '5') {
        @branchHint(.unlikely);
        if (data.len <= introducer_len + 1) return .incomplete;
        if (data[introducer_len + 1] == '2') {
            if (data.len <= introducer_len + 2) return .incomplete;
            if (data[introducer_len + 2] == ';') {
                const selection_start = introducer_len + 3;
                const selection_end = std.mem.indexOfScalarPos(u8, data[0..limit], selection_start, ';') orelse {
                    if (limit < data.len) return .{ .too_long = tooLongConsumed(data, introducer_len, limit) };
                    return .incomplete;
                };
                const selection = data[selection_start..selection_end];
                if (parseOSC52SelectionMask(selection)) |selection_mask| {
                    return .{ .osc_start = .{
                        .payload_start = selection_end + 1,
                        .selection_mask = selection_mask,
                    } };
                }
            }
        }
    }

    var i: usize = introducer_len;
    while (i < limit) : (i += 1) {
        switch (data[i]) {
            0x07 => return .{ .complete = .{ .payload_len = i, .terminator_len = 1 } },
            '\x1b' => {
                if (i + 1 >= data.len) return .incomplete;
                if (data[i + 1] == '\\') return .{ .complete = .{ .payload_len = i, .terminator_len = 2 } };
                // Preserve potential next control sequence start at ESC.
                return .{ .malformed = i };
            },
            else => {},
        }
    }

    if (limit < data.len) {
        return .{ .too_long = tooLongConsumed(data, introducer_len, limit) };
    }

    return .incomplete;
}

fn parseOSC(data: []const u8, consumed_bytes: *usize) ParseResult {
    const introducer_len = oscIntroducerLen(data);
    if (data.len <= introducer_len) return .need_more_input;

    const result = scanOSC(data, .{});
    switch (result) {
        .complete => |res| {
            consumed_bytes.* = res.payload_len + res.terminator_len;
            return parseOSCEvent(data[introducer_len..res.payload_len]);
        },
        .osc_start => |header| {
            consumed_bytes.* = header.payload_start;
            return .{ .osc52_start = .{ .selection_mask = header.selection_mask } };
        },
        .incomplete => return .need_more_input,
        .malformed => |n| {
            consumed_bytes.* = n;
            return .ignored;
        },
        .too_long => |n| {
            consumed_bytes.* = n;
            return .osc_overflow;
        },
    }
}

fn parseOSCEvent(body: []const u8) ParseResult {
    if (body.len == 0) return .ignored;

    const code_string, const payload = if (cutScalar(u8, body, ';')) |result| result else .{ body, &.{} };
    const code = parseValue(u16, code_string, null) orelse return .ignored;
    return switch (code) {
        4 => parseOSCPaletteColor(payload),
        10...19 => parseOSCDynamicColor(@intCast(code), payload),
        22 => parseOSCPointerShape(payload),
        else => .ignored,
    };
}

fn parseOSCPaletteColor(payload: []const u8) ParseResult {
    const index_string, const spec_all = cutScalar(u8, payload, ';') orelse return .ignored;
    const index = parseValue(u8, index_string, null) orelse return .ignored;
    const spec, _ = if (cutScalar(u8, spec_all, ';')) |result| result else .{ spec_all, &.{} };
    const color = parseColorSpec(spec) orelse return .ignored;
    return .{ .event = .{ .osc_palette_color = .{ .index = index, .color = color } } };
}

fn parseOSCDynamicColor(slot: u8, payload: []const u8) ParseResult {
    if (payload.len == 0) return .ignored;
    const spec, _ = if (cutScalar(u8, payload, ';')) |result| result else .{ payload, &.{} };
    const color = parseColorSpec(spec) orelse return .ignored;
    return .{ .event = .{ .osc_dynamic_color = .{ .slot = slot, .color = color } } };
}

fn parseOSC52SelectionMask(selection: []const u8) ?OSCClipboardSelectionMask {
    var mask: OSCClipboardSelectionMask = .empty;
    if (selection.len == 0) {
        mask.set(.select);
        mask.set(.cut0);
        return mask;
    }

    for (selection) |c| {
        const target: OSCClipboardSelection = switch (c) {
            'c' => .clipboard,
            'p' => .primary,
            's' => .select,
            '0' => .cut0,
            '1' => .cut1,
            '2' => .cut2,
            '3' => .cut3,
            '4' => .cut4,
            '5' => .cut5,
            '6' => .cut6,
            '7' => .cut7,
            else => return null,
        };
        mask.set(target);
    }
    return mask;
}

fn parseOSCPointerShape(payload: []const u8) ParseResult {
    return .{ .event = .{ .osc_pointer_shape = .{
        .kind = if (payload.len == 0)
            .empty
        else if (isBinaryCsv(payload))
            .support_bitmap
        else
            .shape_name,
        .value = payload,
    } } };
}

fn isBinaryCsv(payload: []const u8) bool {
    var has_comma = false;
    for (payload) |c| {
        switch (c) {
            ',' => has_comma = true,
            '0', '1' => {},
            else => return false,
        }
    }
    return has_comma;
}

fn parseColorSpec(spec: []const u8) ?RGBColor {
    if (spec.len == 0) return null;
    if (std.mem.startsWith(u8, spec, "rgb:")) {
        const components = spec[4..];
        const red_string, const remaining_after_red = cutScalar(u8, components, '/') orelse return null;
        const green_string, const blue_string = cutScalar(u8, remaining_after_red, '/') orelse return null;
        if (cutScalar(u8, blue_string, '/')) |_| return null;
        return .{
            .r = parseColorComponent(red_string) orelse return null,
            .g = parseColorComponent(green_string) orelse return null,
            .b = parseColorComponent(blue_string) orelse return null,
        };
    }

    if (spec[0] == '#') return parseHexHashColor(spec);
    return null;
}

fn parseHexHashColor(spec: []const u8) ?RGBColor {
    if (spec.len < 2) return null;
    const hex = spec[1..];
    if (hex.len != 3 and hex.len != 6 and hex.len != 9 and hex.len != 12) return null;

    const channel_width = hex.len / 3;
    return .{
        .r = parseColorComponent(hex[0..channel_width]) orelse return null,
        .g = parseColorComponent(hex[channel_width .. channel_width * 2]) orelse return null,
        .b = parseColorComponent(hex[channel_width * 2 .. channel_width * 3]) orelse return null,
    };
}

fn parseColorComponent(component: []const u8) ?u8 {
    if (component.len == 0 or component.len > 4) return null;
    const value = std.fmt.parseInt(u16, component, 16) catch return null;
    const shift: u5 = @intCast(component.len * 4);
    const max_value: u32 = (@as(u32, 1) << shift) - 1;
    const scaled: u32 = (@as(u32, value) * 255 + max_value / 2) / max_value;
    return @intCast(scaled);
}

fn parseValue(comptime T: type, data: []const u8, default_value: ?T) ?T {
    if (data.len == 0) return default_value;
    return std.fmt.parseInt(T, data, 10) catch return null;
}

const testPrint = struct {
    fn print(sequence: []const u8) void {
        var buffer: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);

        writer.writeAll("Sequence '") catch unreachable;
        for (sequence) |c| {
            if (c == '\x1b') writer.writeAll("\\x1b") catch unreachable else writer.writeByte(c) catch unreachable;
        }
        writer.writeAll("' failed:") catch unreachable;
        std.log.err("{s}", .{writer.buffered()});
    }
}.print;

const TestCase = struct {
    sequence: []const u8,
    expected: ParseResult,
    expected_consumed_bytes: ?usize = null,
};

fn testTerminalSequences(comptime test_cases: []const TestCase) error{TestExpectedEqual}!void {
    var error_out: ?error{TestExpectedEqual} = null;

    inline for (test_cases) |test_case| {
        var error_this_test: bool = false;
        var consumed_bytes: usize = test_case.sequence.len;
        const parsed = parseEvent(test_case.sequence, &consumed_bytes);
        const expected_consumed_bytes = if (test_case.expected_consumed_bytes) |expected_consumed_bytes| expected_consumed_bytes else test_case.sequence.len;
        if (consumed_bytes != expected_consumed_bytes) {
            testPrint(test_case.sequence);
            std.log.err("\tFailed to consume all bytes in sequence: expected {d}, consumed {d}", .{ expected_consumed_bytes, consumed_bytes });
            error_this_test = true;
            error_out = error.TestExpectedEqual;
        }

        const ParseTag = std.meta.Tag(ParseResult);
        const expected_parse_tag = @as(ParseTag, test_case.expected);
        const actual_parse_tag = @as(ParseTag, parsed);

        if (actual_parse_tag == expected_parse_tag) {
            switch (comptime test_case.expected) {
                .event => |expected_event| {
                    const event = parsed.event;
                    const Tag = std.meta.Tag(Event);
                    const expected_tag = @as(Tag, expected_event);
                    const actual_tag = @as(Tag, event);

                    if (actual_tag == expected_tag) {
                        switch (comptime expected_event) {
                            .key_pressed, .key_released, .key_repeat => |expected| {
                                const actual: KeyEvent = @field(event, @tagName(expected_tag));
                                if (actual.code != expected.code) {
                                    if (!error_this_test) testPrint(test_case.sequence);
                                    std.log.err("\tExpected code {any}, found {any}", .{ expected.code, actual.code });
                                    error_out = error.TestExpectedEqual;
                                    error_this_test = true;
                                }
                                if (actual.physical_key != expected.physical_key) {
                                    if (!error_this_test) testPrint(test_case.sequence);
                                    std.log.err("\tExpected physical_key {any}, found {any}", .{ expected.physical_key, actual.physical_key });
                                    error_out = error.TestExpectedEqual;
                                    error_this_test = true;
                                }
                                if (actual.mods != expected.mods) {
                                    if (!error_this_test) testPrint(test_case.sequence);
                                    std.log.err("\tExpected mods {any}, found {any}", .{ expected.mods, actual.mods });
                                    error_out = error.TestExpectedEqual;
                                    error_this_test = true;
                                }
                                if (error_this_test) std.log.err("---------------------------------------", .{});
                            },
                            .mouse_left_pressed,
                            .mouse_middle_pressed,
                            .mouse_right_pressed,
                            .mouse_left_released,
                            .mouse_middle_released,
                            .mouse_right_released,
                            .mouse_released,
                            .mouse_scroll_down,
                            .mouse_scroll_up,
                            .mouse_drag_left,
                            .mouse_drag_middle,
                            .mouse_drag_right,
                            .mouse_move,
                            => |expected| {
                                const actual: MouseEvent = @field(event, @tagName(expected_tag));
                                if (actual.mods != expected.mods) {
                                    if (!error_this_test) testPrint(test_case.sequence);
                                    std.log.err("\tExpected mods {any}, found {any}", .{ expected.mods, actual.mods });
                                    error_out = error.TestExpectedEqual;
                                    error_this_test = true;
                                }
                                if (actual.x != expected.x) {
                                    if (!error_this_test) testPrint(test_case.sequence);
                                    std.log.err("\tExpected x {any}, found {any}", .{ expected.x, actual.x });
                                    error_out = error.TestExpectedEqual;
                                    error_this_test = true;
                                }
                                if (actual.y != expected.y) {
                                    if (!error_this_test) testPrint(test_case.sequence);
                                    std.log.err("\tExpected y {any}, found {any}", .{ expected.y, actual.y });
                                    error_out = error.TestExpectedEqual;
                                    error_this_test = true;
                                }
                            },
                            .decrpm => |expected| {
                                const actual: DECRPMEvent = @field(event, @tagName(expected_tag));
                                if (actual.mode != expected.mode) {
                                    if (!error_this_test) testPrint(test_case.sequence);
                                    std.log.err("\tExpected mode {any}, found {any}", .{ expected.mode, actual.mode });
                                    error_out = error.TestExpectedEqual;
                                    error_this_test = true;
                                }
                                if (actual.status != expected.status) {
                                    if (!error_this_test) testPrint(test_case.sequence);
                                    std.log.err("\tExpected status {any}, found {any}", .{ expected.status, actual.status });
                                    error_out = error.TestExpectedEqual;
                                    error_this_test = true;
                                }
                            },
                            .kitty_keyboard_query => |expected| {
                                const actual: KittyKeyboardQueryEvent = @field(event, @tagName(expected_tag));
                                if (actual.raw_flags != expected.raw_flags) {
                                    if (!error_this_test) testPrint(test_case.sequence);
                                    std.log.err("\tExpected raw_flags {any}, found {any}", .{ expected.raw_flags, actual.raw_flags });
                                    error_out = error.TestExpectedEqual;
                                    error_this_test = true;
                                }
                                if (actual.known_flags != expected.known_flags) {
                                    if (!error_this_test) testPrint(test_case.sequence);
                                    std.log.err("\tExpected known_flags {any}, found {any}", .{ expected.known_flags, actual.known_flags });
                                    error_out = error.TestExpectedEqual;
                                    error_this_test = true;
                                }
                                if (actual.unknown_flags != expected.unknown_flags) {
                                    if (!error_this_test) testPrint(test_case.sequence);
                                    std.log.err("\tExpected unknown_flags {any}, found {any}", .{ expected.unknown_flags, actual.unknown_flags });
                                    error_out = error.TestExpectedEqual;
                                    error_this_test = true;
                                }
                            },
                            .primary_device_attributes => |expected| {
                                const actual: PrimaryDeviceAttributesEvent = @field(event, @tagName(expected_tag));
                                if (actual.class_code != expected.class_code) {
                                    if (!error_this_test) testPrint(test_case.sequence);
                                    std.log.err("\tExpected class_code {any}, found {any}", .{ expected.class_code, actual.class_code });
                                    error_out = error.TestExpectedEqual;
                                    error_this_test = true;
                                }
                                if (actual.extensions != expected.extensions) {
                                    if (!error_this_test) testPrint(test_case.sequence);
                                    std.log.err("\tExpected extensions {any}, found {any}", .{ expected.extensions, actual.extensions });
                                    error_out = error.TestExpectedEqual;
                                    error_this_test = true;
                                }
                                if (actual.unknown_extensions != expected.unknown_extensions) {
                                    if (!error_this_test) testPrint(test_case.sequence);
                                    std.log.err("\tExpected unknown_extensions {any}, found {any}", .{ expected.unknown_extensions, actual.unknown_extensions });
                                    error_out = error.TestExpectedEqual;
                                    error_this_test = true;
                                }
                            },
                            .secondary_device_attributes => |expected| {
                                const actual: SecondaryDeviceAttributesEvent = @field(event, @tagName(expected_tag));
                                if (actual.identification_code != expected.identification_code) {
                                    if (!error_this_test) testPrint(test_case.sequence);
                                    std.log.err("\tExpected identification_code {any}, found {any}", .{ expected.identification_code, actual.identification_code });
                                    error_out = error.TestExpectedEqual;
                                    error_this_test = true;
                                }
                                if (actual.firmware_version != expected.firmware_version) {
                                    if (!error_this_test) testPrint(test_case.sequence);
                                    std.log.err("\tExpected firmware_version {any}, found {any}", .{ expected.firmware_version, actual.firmware_version });
                                    error_out = error.TestExpectedEqual;
                                    error_this_test = true;
                                }
                                if (actual.keyboard_option != expected.keyboard_option) {
                                    if (!error_this_test) testPrint(test_case.sequence);
                                    std.log.err("\tExpected keyboard_option {any}, found {any}", .{ expected.keyboard_option, actual.keyboard_option });
                                    error_out = error.TestExpectedEqual;
                                    error_this_test = true;
                                }
                                if (actual.keyboard_option_raw != expected.keyboard_option_raw) {
                                    if (!error_this_test) testPrint(test_case.sequence);
                                    std.log.err("\tExpected keyboard_option_raw {any}, found {any}", .{ expected.keyboard_option_raw, actual.keyboard_option_raw });
                                    error_out = error.TestExpectedEqual;
                                    error_this_test = true;
                                }
                                if (actual.extra_parameters != expected.extra_parameters) {
                                    if (!error_this_test) testPrint(test_case.sequence);
                                    std.log.err("\tExpected extra_parameters {any}, found {any}", .{ expected.extra_parameters, actual.extra_parameters });
                                    error_out = error.TestExpectedEqual;
                                    error_this_test = true;
                                }
                            },
                            .osc_palette_color => |expected| {
                                const actual: OSCPaletteColorEvent = @field(event, @tagName(expected_tag));
                                if (actual.index != expected.index or actual.color.r != expected.color.r or actual.color.g != expected.color.g or actual.color.b != expected.color.b) {
                                    if (!error_this_test) testPrint(test_case.sequence);
                                    std.log.err("\tExpected osc_palette_color {any}, found {any}", .{ expected, actual });
                                    error_out = error.TestExpectedEqual;
                                    error_this_test = true;
                                }
                            },
                            .osc_dynamic_color => |expected| {
                                const actual: OSCDynamicColorEvent = @field(event, @tagName(expected_tag));
                                if (actual.slot != expected.slot or actual.color.r != expected.color.r or actual.color.g != expected.color.g or actual.color.b != expected.color.b) {
                                    if (!error_this_test) testPrint(test_case.sequence);
                                    std.log.err("\tExpected osc_dynamic_color {any}, found {any}", .{ expected, actual });
                                    error_out = error.TestExpectedEqual;
                                    error_this_test = true;
                                }
                            },
                            .osc_pointer_shape => |expected| {
                                const actual: OSCPointerShapeEvent = @field(event, @tagName(expected_tag));
                                if (actual.kind != expected.kind or actual.value != expected.value) {
                                    if (!error_this_test) testPrint(test_case.sequence);
                                    std.log.err("\tExpected osc_pointer_shape {any}, found {any}", .{ expected, actual });
                                    error_out = error.TestExpectedEqual;
                                    error_this_test = true;
                                }
                            },
                            else => {},
                        }
                    } else {
                        if (!error_this_test) testPrint(test_case.sequence);
                        std.log.err("\tExpected event tag {any}, found {any}", .{ expected_tag, actual_tag });
                        error_out = error.TestExpectedEqual;
                        error_this_test = true;
                    }
                },
                .osc52_start => |expected| {
                    const actual = parsed.osc52_start;
                    if (actual.selection_mask != expected.selection_mask) {
                        if (!error_this_test) testPrint(test_case.sequence);
                        std.log.err("\tExpected osc_start {any}, found {any}", .{ expected, actual });
                        error_out = error.TestExpectedEqual;
                        error_this_test = true;
                    }
                },
                else => {},
            }
        } else {
            if (!error_this_test) testPrint(test_case.sequence);
            std.log.err("\tExpected parser result {any}, found {any}", .{ expected_parse_tag, actual_parse_tag });
            error_out = error.TestExpectedEqual;
            error_this_test = true;
        }
    }

    if (error_out) |err| return err;
}

test "keyboard events" {
    const test_cases = [_]TestCase{
        .{ .sequence = "a", .expected = .{ .event = .{ .key_pressed = .{ .code = .a, .physical_key = .A, .mods = .{} } } } },
        .{ .sequence = "A", .expected = .{ .event = .{ .key_pressed = .{ .code = .A, .physical_key = .A, .mods = .{ .shift = true } } } } },
        .{ .sequence = ";", .expected = .{ .event = .{ .key_pressed = .{ .code = .@";", .physical_key = .@";", .mods = .{} } } } },
        .{ .sequence = ":", .expected = .{ .event = .{ .key_pressed = .{ .code = .@":", .physical_key = .@";", .mods = .{ .shift = true } } } } },
        .{ .sequence = "\x1b", .expected = .{ .event = .{ .key_pressed = .{ .code = .escape, .physical_key = .escape, .mods = .{} } } } },
        .{ .sequence = "\x02", .expected = .{ .event = .{ .key_pressed = .{ .code = .b, .physical_key = .B, .mods = .{ .ctrl = true } } } } },
        .{ .sequence = "\x1d", .expected = .{ .event = .{ .key_pressed = .{ .code = .@"5", .physical_key = .@"5", .mods = .{ .ctrl = true } } } } },
        .{ .sequence = "\x1ba", .expected = .{ .event = .{ .key_pressed = .{ .code = .a, .physical_key = .A, .mods = .{ .alt = true } } } } },
        .{ .sequence = "\x1b\x1d", .expected = .{ .event = .{ .key_pressed = .{ .code = .@"5", .physical_key = .@"5", .mods = .{ .alt = true, .ctrl = true } } } } },
        .{ .sequence = "\x1bA", .expected = .{ .event = .{ .key_pressed = .{ .code = .A, .physical_key = .A, .mods = .{ .alt = true, .shift = true } } } } },
        .{ .sequence = "\x1b[97;1:1u", .expected = .{ .event = .{ .key_pressed = .{ .code = .a, .physical_key = .A, .mods = .{} } } } },
        .{ .sequence = "\x1b[97;1:2u", .expected = .{ .event = .{ .key_repeat = .{ .code = .a, .physical_key = .A, .mods = .{} } } } },
        .{ .sequence = "\x1b[97;1:3u", .expected = .{ .event = .{ .key_released = .{ .code = .a, .physical_key = .A, .mods = .{} } } } },
        .{ .sequence = "\x1b[97:65;1u", .expected = .{ .event = .{ .key_pressed = .{ .code = .a, .physical_key = .A, .mods = .{} } } } },
        .{ .sequence = "\x1b[97;1;65u", .expected = .{ .event = .{ .key_pressed = .{ .code = .a, .physical_key = .A, .mods = .{} } } } },
        .{ .sequence = "\x1b[97:65:97;1:1;65:66u", .expected = .{ .event = .{ .key_pressed = .{ .code = .a, .physical_key = .A, .mods = .{} } } } },
        .{ .sequence = "\x1b[97;65u", .expected = .{ .event = .{ .key_pressed = .{ .code = .a, .physical_key = .A, .mods = .{ .caps_lock = true } } } } },
        .{ .sequence = "\x1b[97;129u", .expected = .{ .event = .{ .key_pressed = .{ .code = .a, .physical_key = .A, .mods = .{ .num_lock = true } } } } },
        .{ .sequence = "\x1b[97;193u", .expected = .{ .event = .{ .key_pressed = .{ .code = .a, .physical_key = .A, .mods = .{ .caps_lock = true, .num_lock = true } } } } },
        .{ .sequence = "\x1b[A", .expected = .{ .event = .{ .key_pressed = .{ .code = .up, .physical_key = .up, .mods = .{} } } } },
        .{ .sequence = "\x1b[1;5B", .expected = .{ .event = .{ .key_pressed = .{ .code = .down, .physical_key = .down, .mods = .{ .ctrl = true } } } } },
        .{ .sequence = "\x1b[1;2:3C", .expected = .{ .event = .{ .key_released = .{ .code = .right, .physical_key = .right, .mods = .{ .shift = true } } } } },
        .{ .sequence = "\x1b[5~", .expected = .{ .event = .{ .key_pressed = .{ .code = .page_up, .physical_key = .page_up, .mods = .{} } } } },
        .{ .sequence = "\x1b[3;5~", .expected = .{ .event = .{ .key_pressed = .{ .code = .delete, .physical_key = .delete, .mods = .{ .ctrl = true } } } } },
        .{ .sequence = "\x1b[24;2:3~", .expected = .{ .event = .{ .key_released = .{ .code = .f12, .physical_key = .f12, .mods = .{ .shift = true } } } } },
        .{ .sequence = "\x1bOA", .expected = .{ .event = .{ .key_pressed = .{ .code = .up, .physical_key = .up, .mods = .{} } } } },
        .{ .sequence = "\x1bOP", .expected = .{ .event = .{ .key_pressed = .{ .code = .f1, .physical_key = .f1, .mods = .{} } } } },
        .{ .sequence = "\x8fA", .expected = .{ .event = .{ .key_pressed = .{ .code = .up, .physical_key = .up, .mods = .{} } } } },
        .{ .sequence = "\x9bA", .expected = .{ .event = .{ .key_pressed = .{ .code = .up, .physical_key = .up, .mods = .{} } } } },
        .{ .sequence = "\x9b97;1:1u", .expected = .{ .event = .{ .key_pressed = .{ .code = .a, .physical_key = .A, .mods = .{} } } } },
        .{ .sequence = "\x1b[97;17u", .expected = .{ .event = .{ .key_pressed = .{ .code = .a, .physical_key = .A, .mods = .{ .hyper = true } } } } },
        .{ .sequence = "\x1b[97;33u", .expected = .{ .event = .{ .key_pressed = .{ .code = .a, .physical_key = .A, .mods = .{ .meta = true } } } } },
        .{ .sequence = "\x1b[13u", .expected = .{ .event = .{ .key_pressed = .{ .code = .enter, .physical_key = .enter, .mods = .{} } } } },
        .{ .sequence = "\x1b[13;2u", .expected = .{ .event = .{ .key_pressed = .{ .code = .enter, .physical_key = .enter, .mods = .{ .shift = true } } } } },
        .{ .sequence = "\x1b[27u", .expected = .{ .event = .{ .key_pressed = .{ .code = .escape, .physical_key = .escape, .mods = .{} } } } },
        .{ .sequence = "\xC3\xA9", .expected = .{ .event = .{ .key_pressed = .{ .code = @enumFromInt(0x00E9), .physical_key = .unknown, .mods = .{} } } } },
        .{ .sequence = "\xF0\x9F\x98\x80", .expected = .{ .event = .{ .key_pressed = .{ .code = @enumFromInt(0x1F600), .physical_key = .unknown, .mods = .{} } } } },
        .{ .sequence = "\x1b\xC3\xA9", .expected = .{ .event = .{ .key_pressed = .{ .code = @enumFromInt(0x00E9), .physical_key = .unknown, .mods = .{ .alt = true } } } } },
        .{ .sequence = "\xC3A", .expected = .{ .event = .{ .key_pressed = .{ .code = @enumFromInt(0xFFFD), .physical_key = .unknown, .mods = .{} } } }, .expected_consumed_bytes = 1 },
        // Negative tests
        .{ .sequence = "\x1b[", .expected = .need_more_input, .expected_consumed_bytes = 0 },
        .{ .sequence = "\x1b[97:65:97;1:", .expected = .need_more_input, .expected_consumed_bytes = 0 },
        .{ .sequence = "\x1bO", .expected = .need_more_input, .expected_consumed_bytes = 0 },
        .{ .sequence = "\xC3", .expected = .need_more_input, .expected_consumed_bytes = 0 },
        .{ .sequence = "\xE2\x82", .expected = .need_more_input, .expected_consumed_bytes = 0 },
        .{ .sequence = "\x1b\xC3", .expected = .need_more_input, .expected_consumed_bytes = 0 },
        .{ .sequence = "\x1bOZ", .expected = .ignored },
        .{ .sequence = "\x1b[1;1X", .expected = .ignored },
        .{ .sequence = "\x1b[999~", .expected = .ignored },
        // Modifier encoding is 1 + bitmask; 0 and > 256 are invalid
        .{ .sequence = "\x1b[97;282u", .expected = .ignored },
        .{ .sequence = "\x1b[97;0:1u", .expected = .ignored },
        .{ .sequence = "\x1b[97;0:2u", .expected = .ignored },
        .{ .sequence = "\x1b[1;257A", .expected = .ignored },
        .{ .sequence = "\x1b[3;0~", .expected = .ignored },
    };

    try testTerminalSequences(&test_cases);
}

test "mouse events" {
    const test_cases = [_]TestCase{
        // SGR off tests positive
        .{ .sequence = "\x1b[M\x20\x25\x25", .expected = .{ .event = .{ .mouse_left_pressed = .{ .mods = .{}, .x = 5, .y = 5 } } } },
        .{ .sequence = "\x9bM\x20\x25\x25", .expected = .{ .event = .{ .mouse_left_pressed = .{ .mods = .{}, .x = 5, .y = 5 } } } },
        .{ .sequence = "\x1b[M\x27\x30\x30", .expected = .{ .event = .{ .mouse_released = .{ .mods = .{ .shift = true }, .x = 16, .y = 16 } } } },
        .{ .sequence = "\x1b[M\x6c\x30\x30", .expected = .{ .event = .{ .mouse_scroll_up = .{ .mods = .{ .shift = true, .alt = true }, .x = 16, .y = 16 } } } },
        .{ .sequence = "\x1b[M\x55\x42\x32", .expected = .{ .event = .{ .mouse_drag_middle = .{ .mods = .{ .shift = true, .ctrl = true }, .x = 34, .y = 18 } } } },
        // SGR on tests
        .{ .sequence = "\x1b[<0;10;20M", .expected = .{ .event = .{ .mouse_left_pressed = .{ .mods = .{}, .x = 10, .y = 20 } } } },
        .{ .sequence = "\x9b<0;10;20M", .expected = .{ .event = .{ .mouse_left_pressed = .{ .mods = .{}, .x = 10, .y = 20 } } } },
        .{ .sequence = "\x1b[<0;10;20m", .expected = .{ .event = .{ .mouse_left_released = .{ .mods = .{}, .x = 10, .y = 20 } } } },
        .{ .sequence = "\x1b[<16;10;20M", .expected = .{ .event = .{ .mouse_left_pressed = .{ .mods = .{ .ctrl = true }, .x = 10, .y = 20 } } } },
        .{ .sequence = "\x1b[<4;10;20M", .expected = .{ .event = .{ .mouse_left_pressed = .{ .mods = .{ .shift = true }, .x = 10, .y = 20 } } } },
        .{ .sequence = "\x1b[<8;10;20M", .expected = .{ .event = .{ .mouse_left_pressed = .{ .mods = .{ .alt = true }, .x = 10, .y = 20 } } } },
        .{ .sequence = "\x1b[<28;10;20M", .expected = .{ .event = .{ .mouse_left_pressed = .{ .mods = .{ .shift = true, .ctrl = true, .alt = true }, .x = 10, .y = 20 } } } },
        .{ .sequence = "\x1b[<35;10;20M", .expected = .{ .event = .{ .mouse_move = .{ .mods = .{}, .x = 10, .y = 20 } } } },
        .{ .sequence = "\x1b[<47;10;20M", .expected = .{ .event = .{ .mouse_move = .{ .mods = .{ .shift = true, .alt = true }, .x = 10, .y = 20 } } } },
        .{ .sequence = "\x1b[<32;10;20M", .expected = .{ .event = .{ .mouse_drag_left = .{ .mods = .{}, .x = 10, .y = 20 } } } },
        .{ .sequence = "\x1b[<48;10;20M", .expected = .{ .event = .{ .mouse_drag_left = .{ .mods = .{ .ctrl = true }, .x = 10, .y = 20 } } } },
        .{ .sequence = "\x1b[<33;10;20M", .expected = .{ .event = .{ .mouse_drag_middle = .{ .mods = .{}, .x = 10, .y = 20 } } } },
        .{ .sequence = "\x1b[<34;10;20M", .expected = .{ .event = .{ .mouse_drag_right = .{ .mods = .{}, .x = 10, .y = 20 } } } },
        .{ .sequence = "\x1b[<64;5;5M", .expected = .{ .event = .{ .mouse_scroll_up = .{ .mods = .{}, .x = 5, .y = 5 } } } },
        .{ .sequence = "\x1b[<80;5;5M", .expected = .{ .event = .{ .mouse_scroll_up = .{ .mods = .{ .ctrl = true }, .x = 5, .y = 5 } } } },
        .{ .sequence = "\x1b[<65;5;5M", .expected = .{ .event = .{ .mouse_scroll_down = .{ .mods = .{}, .x = 5, .y = 5 } } } },
        .{ .sequence = "\x1b[<85;5;5M", .expected = .{ .event = .{ .mouse_scroll_down = .{ .mods = .{ .shift = true, .ctrl = true }, .x = 5, .y = 5 } } } },
        .{ .sequence = "\x1b[<0;305;1024M", .expected = .{ .event = .{ .mouse_left_pressed = .{ .mods = .{}, .x = 305, .y = 1024 } } } },
        // Negative tests
        .{ .sequence = "\x1b[M", .expected = .need_more_input, .expected_consumed_bytes = 0 },
        .{ .sequence = "\x1b[<0;10M", .expected = .ignored },
        .{ .sequence = "\x1b[<0;10;20", .expected = .need_more_input, .expected_consumed_bytes = 0 },
        .{ .sequence = "\x1b[<M", .expected = .ignored },
        .{ .sequence = "\x1b[M\x57\x42\x32", .expected = .ignored }, // Mouse is set to button 3(release) and movement. This is not valid in X10 mode
        .{ .sequence = "\x1b[M\x82\x42\x32", .expected = .ignored }, // Mouse has move and scroll modifiers set this is invalid
        .{ .sequence = "\x1b[M\x1b[A", .expected = .ignored, .expected_consumed_bytes = 3 }, // Malformed X10 packet should consume only CSI bytes
        .{ .sequence = "\x1b[<64;5;5m", .expected = .ignored },
        .{ .sequence = "\x1b[<66;10;20M", .expected = .ignored },
        .{ .sequence = "\x1b[<67;10;20M", .expected = .ignored },
        .{ .sequence = "\x1b[<128;10;20M", .expected = .ignored },
        .{ .sequence = "\x1b[<129;10;20M", .expected = .ignored },
        .{ .sequence = "\x1b[<256;10;20M", .expected = .ignored },
    };

    try testTerminalSequences(&test_cases);
}

test "terminal capability response events" {
    const test_cases = [_]TestCase{
        .{ .sequence = "\x1b[?u", .expected = .{ .event = .{ .kitty_keyboard_query = .{ .raw_flags = 0, .known_flags = .{}, .unknown_flags = 0 } } } },
        .{ .sequence = "\x9b?u", .expected = .{ .event = .{ .kitty_keyboard_query = .{ .raw_flags = 0, .known_flags = .{}, .unknown_flags = 0 } } } },
        .{ .sequence = "\x1b[?5u", .expected = .{ .event = .{ .kitty_keyboard_query = .{ .raw_flags = 5, .known_flags = .{ .disambiguate_escape_codes = true, .report_alternate_keys = true }, .unknown_flags = 0 } } } },
        .{ .sequence = "\x1b[?7;1u", .expected = .{ .event = .{ .kitty_keyboard_query = .{ .raw_flags = 7, .known_flags = .{ .disambiguate_escape_codes = true, .report_event_types = true, .report_alternate_keys = true }, .unknown_flags = 0 } } } },
        .{ .sequence = "\x1b[?255u", .expected = .{ .event = .{ .kitty_keyboard_query = .{ .raw_flags = 255, .known_flags = .{ .disambiguate_escape_codes = true, .report_event_types = true, .report_alternate_keys = true, .report_all_keys_as_escape_codes = true, .report_associated_text = true }, .unknown_flags = 224 } } } },
        .{ .sequence = "\x1b[?1006;0$y", .expected = .{ .event = .{ .decrpm = .{ .mode = 1006, .status = .not_recognized } } } },
        .{ .sequence = "\x1b[?1006;1$y", .expected = .{ .event = .{ .decrpm = .{ .mode = 1006, .status = .set } } } },
        .{ .sequence = "\x1b[?1016;4$y", .expected = .{ .event = .{ .decrpm = .{ .mode = 1016, .status = .permanently_reset } } } },
        .{ .sequence = "\x1b[?64;4;6;18;21;22;46;52c", .expected = .{ .event = .{ .primary_device_attributes = .{ .class_code = 64, .extensions = .{ .sixel = true, .selective_erase = true, .windowing = true, .horizontal_scrolling = true, .ansi_color = true, .ascii_emulation = true, .clipboard = true }, .unknown_extensions = false } } } },
        .{ .sequence = "\x1b[?64;99c", .expected = .{ .event = .{ .primary_device_attributes = .{ .class_code = 64, .extensions = .{}, .unknown_extensions = true } } } },
        .{ .sequence = "\x1b[>61;20;1c", .expected = .{ .event = .{ .secondary_device_attributes = .{ .identification_code = 61, .firmware_version = 20, .keyboard_option = .pc, .keyboard_option_raw = 1, .extra_parameters = false } } } },
        .{ .sequence = "\x1b[>61;20;9;5c", .expected = .{ .event = .{ .secondary_device_attributes = .{ .identification_code = 61, .firmware_version = 20, .keyboard_option = .unknown, .keyboard_option_raw = 9, .extra_parameters = true } } } },
        // Negative tests
        .{ .sequence = "\x1b[?;1$y", .expected = .ignored },
        .{ .sequence = "\x1b[?1006;$y", .expected = .ignored },
        .{ .sequence = "\x1b[?1006;9$y", .expected = .ignored },
        .{ .sequence = "\x1b[?999999999999999999999u", .expected = .ignored },
        .{ .sequence = "\x1b[?64;;1c", .expected = .ignored },
        .{ .sequence = "\x1b[=1;2c", .expected = .ignored },
        .{ .sequence = "\x1b[>61;20c", .expected = .ignored },
    };

    try testTerminalSequences(&test_cases);
}

test "osc response events" {
    const test_cases = [_]TestCase{
        .{ .sequence = "\x1b]4;7;rgb:ff/00/80\x1b\\", .expected = .{ .event = .{ .osc_palette_color = .{ .index = 7, .color = .{ .r = 0xff, .g = 0x00, .b = 0x80 } } } } },
        .{ .sequence = "\x1b]10;#112233\x07", .expected = .{ .event = .{ .osc_dynamic_color = .{ .slot = 10, .color = .{ .r = 0x11, .g = 0x22, .b = 0x33 } } } } },
        .{ .sequence = "\x1b]52;c;Zm9v\x1b\\", .expected = .{ .osc52_start = .{ .selection_mask = .{ .clipboard = true } } }, .expected_consumed_bytes = 7 },
        .{ .sequence = "\x1b]52;;?\x1b\\", .expected = .{ .osc52_start = .{ .selection_mask = .{ .select = true, .cut0 = true } } }, .expected_consumed_bytes = 6 },
        .{ .sequence = "\x1b]52;c;\x1b\\", .expected = .{ .osc52_start = .{ .selection_mask = .{ .clipboard = true } } }, .expected_consumed_bytes = 7 },
        // .{ .sequence = "\x1b]22;1,0,1\x1b\\", .expected = .{ .event = .{ .osc_pointer_shape = .{ .kind = .support_bitmap, .value = 5 } } } },
        // .{ .sequence = "\x1b]22;crosshair\x1b\\", .expected = .{ .event = .{ .osc_pointer_shape = .{ .kind = .shape_name, .value = 9 } } } },
        // Unknown OSC is consumed and ignored.
        .{ .sequence = "\x1b]999;foo\x1b\\", .expected = .ignored },
        // Incomplete OSC should request more input.
        .{ .sequence = "\x9d11;rgb:00/ff/00\x9c", .expected = .need_more_input, .expected_consumed_bytes = 0 },
        .{ .sequence = "\x1b]52;", .expected = .need_more_input, .expected_consumed_bytes = 0 },
        .{ .sequence = "\x1b]52;c", .expected = .need_more_input, .expected_consumed_bytes = 0 },
        .{ .sequence = "\x1b]10;#112233", .expected = .need_more_input, .expected_consumed_bytes = 0 },
        .{ .sequence = "\x1b]10;#112233\x1b", .expected = .need_more_input, .expected_consumed_bytes = 0 },
    };

    try testTerminalSequences(&test_cases);
}

test "parseEvent marks ST-terminated control strings for discard" {
    const cases = [_]struct {
        sequence: []const u8,
        expected_consumed: usize,
    }{
        .{ .sequence = "\x1bPabc", .expected_consumed = 2 },
        .{ .sequence = "\x1b^abc", .expected_consumed = 2 },
        .{ .sequence = "\x1bXabc", .expected_consumed = 2 },
        .{ .sequence = "\x1b_abc", .expected_consumed = 2 },
        .{ .sequence = "\x90abc", .expected_consumed = 1 },
        .{ .sequence = "\x9eabc", .expected_consumed = 1 },
        .{ .sequence = "\x98abc", .expected_consumed = 1 },
        .{ .sequence = "\x9fabc", .expected_consumed = 1 },
    };

    inline for (cases) |tc| {
        var consumed: usize = 0;
        const parsed = parseEvent(tc.sequence, &consumed);
        try std.testing.expectEqual(
            @as(std.meta.Tag(ParseResult), .skip_till_st),
            @as(std.meta.Tag(ParseResult), parsed),
        );
        try std.testing.expectEqual(tc.expected_consumed, consumed);
    }
}

const OSCScanTestCase = struct {
    sequence: []const u8,
    options: OSCScanOptions = .{},
    expected: OSCScanResult,
};

fn expectOSCScanResult(actual: OSCScanResult, expected: OSCScanResult) !void {
    const Tag = std.meta.Tag(OSCScanResult);
    try std.testing.expectEqual(@as(Tag, expected), @as(Tag, actual));
    switch (expected) {
        .complete => |n| try std.testing.expectEqual(n, actual.complete),
        .osc_start => |expected_header| {
            try std.testing.expectEqual(expected_header.payload_start, actual.osc_start.payload_start);
            try std.testing.expectEqual(expected_header.selection_mask, actual.osc_start.selection_mask);
        },
        .malformed => |n| try std.testing.expectEqual(n, actual.malformed),
        .too_long => |n| try std.testing.expectEqual(n, actual.too_long),
        .incomplete => {},
    }
}

fn testScanOSC(comptime cases: []const OSCScanTestCase) !void {
    inline for (cases) |tc| {
        const actual = scanOSC(tc.sequence, tc.options);
        try expectOSCScanResult(actual, tc.expected);
    }
}

const ScanTestCase = struct {
    sequence: []const u8,
    options: CSIScanOptions = .{},
    expected: ScanResult,
};

fn expectScanResult(actual: ScanResult, expected: ScanResult) !void {
    const Tag = std.meta.Tag(ScanResult);
    try std.testing.expectEqual(@as(Tag, expected), @as(Tag, actual));
    switch (expected) {
        .complete => |n| try std.testing.expectEqual(n, actual.complete),
        .malformed => |n| try std.testing.expectEqual(n, actual.malformed),
        .too_long => |n| try std.testing.expectEqual(n, actual.too_long),
        .incomplete => {},
    }
}

fn testScanCSI(comptime cases: []const ScanTestCase) !void {
    inline for (cases) |tc| {
        const actual = scanCSI(tc.sequence, tc.options);
        try expectScanResult(actual, tc.expected);
    }
}

test "tooLongConsumed handles boundary inputs" {
    try std.testing.expectEqual(@as(usize, 0), tooLongConsumed(&.{}, 0, 0));
    try std.testing.expectEqual(@as(usize, 2), tooLongConsumed("\x1b]", 2, 2));
    try std.testing.expectEqual(@as(usize, 4), tooLongConsumed("\x1b]AB\x1b", 2, 5));
}

test "scanCSI ECMA-48 grammar and bounds" {
    const cases = [_]ScanTestCase{
        // Complete
        .{ .sequence = "\x1b[A", .expected = .{ .complete = 3 } },
        .{ .sequence = "\x1b[?25h", .expected = .{ .complete = 6 } },
        .{ .sequence = "\x1b[[", .expected = .{ .complete = 3 } }, // '[' is a valid final byte class
        // Incomplete (must be len > 2 because scanCSI asserts that)
        .{ .sequence = "\x1b[1", .expected = .incomplete },
        .{ .sequence = "\x1b[?25", .expected = .incomplete },
        // Malformed: parameter byte after intermediate byte
        .{ .sequence = "\x1b[ 0", .expected = .{ .malformed = 3 } },
        // Malformed: invalid byte immediately after CSI introducer
        .{ .sequence = "\x1b[\x10", .expected = .{ .malformed = 2 } },
        // Malformed: preserve potential next ESC sequence start
        // "\x1b[12" malformed at index 4 where next ESC begins.
        .{ .sequence = "\x1b[12\x1b[A", .expected = .{ .malformed = 4 } },
        // Too long using a small cap
        .{
            .sequence = "\x1b[12345A",
            .options = .{ .csi_len_max = 4 },
            .expected = .{ .too_long = 6 },
        },
    };
    try testScanCSI(&cases);
}

test "scanOSC framing and bounds" {
    const cases = [_]OSCScanTestCase{
        .{ .sequence = "\x1b]52;c;Zm9v\x1b\\", .expected = .{ .osc_start = .{ .payload_start = 7, .selection_mask = .{ .clipboard = true } } } },
        .{ .sequence = "\x1b]10;#112233\x1b\\", .expected = .{ .complete = .{ .payload_len = 12, .terminator_len = 2 } } },
        .{ .sequence = "\x1b]10;#112233\x07", .expected = .{ .complete = .{ .payload_len = 12, .terminator_len = 1 } } },
        .{ .sequence = "\x9d10;#112233\x9c", .expected = .incomplete },
        .{ .sequence = "\x1b]10;#112233\x1b[A", .expected = .{ .malformed = 12 } },
        .{ .sequence = "\x1b]10;#112233", .expected = .incomplete },
        .{ .sequence = "\x1b]10;#112233\x1b", .expected = .incomplete },
        .{
            .sequence = "\x1b]52;cAAAAAAAA",
            .options = .{ .osc_len_max = 4 },
            .expected = .{ .too_long = 6 },
        },
        .{
            .sequence = "\x1b]10;#112233\x1b\\",
            .options = .{ .osc_len_max = 8 },
            .expected = .{ .too_long = 10 },
        },
    };
    try testScanOSC(&cases);
}

test "parseEvent malformed OSC does not eat next event start" {
    const sequence = "\x1b]10;#112233\x1b[A";
    // First parse: malformed OSC prefix only.
    var consumed_first: usize = 0;
    const first = parseEvent(sequence, &consumed_first);
    try std.testing.expectEqual(
        @as(std.meta.Tag(ParseResult), .ignored),
        @as(std.meta.Tag(ParseResult), first),
    );
    try std.testing.expectEqual(@as(usize, 12), consumed_first);

    // Second parse: remaining bytes should still start with ESC [ A.
    const remaining = sequence[consumed_first..];
    var consumed_second: usize = 0;
    const second = parseEvent(remaining, &consumed_second);
    try std.testing.expectEqual(@as(usize, 3), consumed_second);
    switch (second) {
        .event => |ev| switch (ev) {
            .key_pressed => |key| {
                try std.testing.expectEqual(KeyEvent.Code.up, key.code);
                try std.testing.expectEqual(KeyEvent.PhysicalKey.up, key.physical_key);
                try std.testing.expectEqual(Mods{}, key.mods);
            },
            else => try std.testing.expect(false),
        },
        else => try std.testing.expect(false),
    }
}
