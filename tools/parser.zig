const std = @import("std");
const t = @import("unicode_types.zig");
const helpers = @import("helpers.zig");
const cut = helpers.cut;
const cutScalar = helpers.cutScalar;
const u = @import("unicode_info.zig");
const UnicodeInfo = u.UnicodeInfo;

const timers = struct {
    east_asian_width: u64,
    grapheme_break: u64,
    emoji: u64,
    emoji_vs: u64,
    derived_core_properties: u64,
    general_category: u64,
};

pub fn parseUCDFiles(io: std.Io, info: UnicodeInfo) !timers {
    var eaw = io.async(parseEastAsianWidth, .{ io, info.east_asian_width });
    defer _ = eaw.cancel(io) catch {};
    var gbp = io.async(parseGraphemeBreakProperty, .{ io, info.grapheme_break });
    defer _ = gbp.cancel(io) catch {};
    var e = io.async(parseEmoji, .{ io, info.emoji });
    defer _ = e.cancel(io) catch {};
    var dcp = io.async(parseDerivedCoreProperties, .{ io, info.derived_core_properties });
    defer _ = dcp.cancel(io) catch {};
    var gc = io.async(parseGeneralCategory, .{ io, info.general_category });
    defer _ = gc.cancel(io) catch {};
    var evs = io.async(parseEmojiVS, .{ io, info.emoji_vs });
    defer _ = evs.cancel(io) catch {};

    const time_dcp_ns = try dcp.await(io);
    const time_gbp_ns = try gbp.await(io);
    const time_eaw_ns = try eaw.await(io);
    const time_e_ns = try e.await(io);
    const time_gc_ns = try gc.await(io);
    const time_evs_ns = try evs.await(io);
    return timers{
        .east_asian_width = time_eaw_ns,
        .grapheme_break = time_gbp_ns,
        .emoji = time_e_ns,
        .derived_core_properties = time_dcp_ns,
        .general_category = time_gc_ns,
        .emoji_vs = time_evs_ns,
    };
}

pub fn parseEmojiVS(io: std.Io, data: []bool) !u64 {
    var timer = std.time.Timer.start() catch unreachable;
    var file = try std.Io.Dir.cwd().openFile(io, "UCD/emoji/emoji-variation-sequences.txt", .{});
    defer file.close(io);
    var file_buffer: [4096]u8 align(std.atomic.cache_line) = undefined;
    var file_reader = file.reader(io, &file_buffer);
    const reader = &file_reader.interface;
    @memset(data, false);
    while (true) : (_ = try reader.discardDelimiterInclusive('\n')) {
        const first_byte = reader.peekByte() catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        if (first_byte == '\n') continue;
        if (first_byte == '#') continue;
        // Format is U+<codepoint> <variation selector> ; <text style/emoji style>
        // As far as I can see every unicode has both variation selectors enabled.
        // So we just need to mark every codepoint visited.
        const codepoint = try reader.takeDelimiterExclusive(' ');
        const cp = try std.fmt.parseInt(u21, codepoint, 16);
        data[cp] = true;
    }
    return timer.read();
}

pub fn parseGeneralCategory(io: std.Io, data: []t.GeneralCategory) !u64 {
    var timer = std.time.Timer.start() catch unreachable;
    var file = try std.Io.Dir.cwd().openFile(io, "UCD/extracted/DerivedGeneralCategory.txt", .{});
    defer file.close(io);
    var file_buffer: [4096]u8 align(std.atomic.cache_line) = undefined;
    var file_reader = file.reader(io, &file_buffer);
    const reader = &file_reader.interface;
    @memset(data, .Cn);
    while (true) : (_ = try reader.discardDelimiterInclusive('\n')) {
        const first_byte = reader.peekByte() catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        if (first_byte == '\n') continue;
        if (first_byte == '#') continue;
        const line = try reader.takeDelimiterExclusive('#');
        var range, var property = if (cutScalar(u8, line, ';')) |result| result else return error.InvalidLine;
        range = std.mem.trim(u8, range, " \t");
        property = std.mem.trim(u8, property, " \t");
        const start, const end = if (cut(u8, range, "..")) |result| result else .{ range, range };
        const start_codepoint = try std.fmt.parseInt(u21, start, 16);
        const end_codepoint = try std.fmt.parseInt(u21, end, 16);
        const property_value = std.meta.stringToEnum(t.GeneralCategory, property) orelse return error.InvalidProperty;
        @memset(data[start_codepoint .. end_codepoint + 1], property_value);
    }
    return timer.read();
}

pub fn parseDerivedCoreProperties(io: std.Io, data: []t.DerivedCoreProperties) !u64 {
    var timer = std.time.Timer.start() catch unreachable;
    var file = try std.Io.Dir.cwd().openFile(io, "UCD/DerivedCoreProperties.txt", .{});
    defer file.close(io);
    var file_buffer: [4096]u8 align(std.atomic.cache_line) = undefined;
    var file_reader = file.reader(io, &file_buffer);
    const reader = &file_reader.interface;
    @memset(data, .{});
    while (true) : (_ = try reader.discardDelimiterInclusive('\n')) {
        const first_byte = reader.peekByte() catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        if (first_byte == '\n') continue;
        if (first_byte == '#') continue;
        const line = try reader.takeDelimiterExclusive('#');

        var range, var property = if (cutScalar(u8, line, ';')) |result| result else return error.InvalidLine;

        property, var value = if (cutScalar(u8, property, ';')) |result| result else .{ property, "" };

        property = std.mem.trim(u8, property, " \t");
        value = std.mem.trim(u8, value, " \t");
        range = std.mem.trim(u8, range, " \t");

        const start, const end = if (cut(u8, range, "..")) |result| result else .{ range, range };
        const start_codepoint = try std.fmt.parseInt(u21, start, 16);
        const end_codepoint = try std.fmt.parseInt(u21, end, 16);

        const property_value = std.meta.stringToEnum(t.DerivedCorePropertiesMask, property) orelse {
            std.log.err("Invalid property: {s}", .{property});
            return error.InvalidProperty;
        };
        switch (property_value) {
            .InCB => {
                for (start_codepoint..end_codepoint + 1) |codepoint| {
                    data[codepoint].InCB = std.meta.stringToEnum(t.IndicConjunctBreakValue, value) orelse {
                        std.log.err("Invalid value: {s}", .{value});
                        return error.InvalidValue;
                    };
                }
            },
            inline else => |p| {
                for (start_codepoint..end_codepoint + 1) |codepoint| {
                    @field(data[codepoint], @tagName(p)) = true;
                }
            },
        }
    }
    return timer.read();
}

pub fn parseEmoji(io: std.Io, data: []t.Emoji) !u64 {
    var timer = std.time.Timer.start() catch unreachable;
    var file = try std.Io.Dir.cwd().openFile(io, "UCD/emoji/emoji-data.txt", .{});
    defer file.close(io);
    var file_buffer: [4096]u8 align(std.atomic.cache_line) = undefined;
    var file_reader = file.reader(io, &file_buffer);
    const reader = &file_reader.interface;
    @memset(data, .{});
    while (true) : (_ = try reader.discardDelimiterInclusive('\n')) {
        const first_byte = reader.peekByte() catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        if (first_byte == '\n') continue;
        if (first_byte == '#') continue;
        const line = try reader.takeDelimiterExclusive('#');
        var range, var property = if (cutScalar(u8, line, ';')) |result| result else return error.InvalidLine;
        range = std.mem.trim(u8, range, " \t");
        property = std.mem.trim(u8, property, " \t");
        const start, const end = if (cut(u8, range, "..")) |result| result else .{ range, range };
        const start_codepoint = try std.fmt.parseInt(u21, start, 16);
        const end_codepoint = try std.fmt.parseInt(u21, end, 16);
        const property_value = std.meta.stringToEnum(t.EmojiMask, property) orelse return error.InvalidProperty;
        for (start_codepoint..end_codepoint + 1) |codepoint| {
            data[codepoint] = @bitCast(@as(t.EmojiBacking, @bitCast(data[codepoint])) | @intFromEnum(property_value));
        }
    }
    return timer.read();
}

pub fn parseGraphemeBreakProperty(io: std.Io, data: []t.GraphemeBreakProperty) !u64 {
    var timer = std.time.Timer.start() catch unreachable;
    var file = try std.Io.Dir.cwd().openFile(io, "UCD/auxiliary/GraphemeBreakProperty.txt", .{});
    defer file.close(io);
    var file_buffer: [4096]u8 align(std.atomic.cache_line) = undefined;
    var file_reader = file.reader(io, &file_buffer);
    const reader = &file_reader.interface;
    @memset(data, t.GraphemeBreakProperty.Other);
    while (true) : (_ = try reader.discardDelimiterInclusive('\n')) {
        const first_byte = reader.peekByte() catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        if (first_byte == '\n') continue;
        if (first_byte == '#') continue;
        const line = try reader.takeDelimiterExclusive('#');
        var range, var property = if (cutScalar(u8, line, ';')) |result| result else return error.InvalidLine;
        range = std.mem.trim(u8, range, " \t");
        property = std.mem.trim(u8, property, " \t");
        const start, const end = if (cut(u8, range, "..")) |result| result else .{ range, range };
        const start_codepoint = try std.fmt.parseInt(u21, start, 16);
        const end_codepoint = try std.fmt.parseInt(u21, end, 16);
        const property_value = std.meta.stringToEnum(t.GraphemeBreakProperty, property) orelse return error.InvalidProperty;
        @memset(data[start_codepoint .. end_codepoint + 1], property_value);
    }
    return timer.read();
}

pub fn parseEastAsianWidth(io: std.Io, data: []t.EastAsianWidth) !u64 {
    var timer = std.time.Timer.start() catch unreachable;
    var file = try std.Io.Dir.cwd().openFile(io, "UCD/extracted/DerivedEastAsianWidth.txt", .{});
    defer file.close(io);
    var file_buffer: [4096]u8 align(std.atomic.cache_line) = undefined;
    var file_reader = file.reader(io, &file_buffer);
    const reader = &file_reader.interface;
    @memset(data, t.EastAsianWidth.N);
    while (true) : (_ = try reader.discardDelimiterInclusive('\n')) {
        const first_byte = reader.peekByte() catch |err| switch (err) {
            error.EndOfStream => break,
            else => |e| return e,
        };
        if (first_byte == '\n') continue;
        if (first_byte == '#') {
            const missing = "# @missing:";
            const text = reader.peek(missing.len) catch |err| switch (err) {
                error.EndOfStream => break,
                else => |e| return e,
            };

            if (std.mem.eql(u8, text, missing)) {
                reader.toss(missing.len);
                const line = try reader.takeDelimiterExclusive('\n');
                var range, var property = if (cutScalar(u8, line, ';')) |result| result else return error.InvalidMissingLine;
                range = std.mem.trim(u8, range, " \t");
                property = std.mem.trim(u8, property, " \t");
                if (std.mem.eql(u8, property, "Neutral")) {
                    continue;
                } else if (!std.mem.eql(u8, property, "Wide")) {
                    return error.InvalidProperty;
                }
                const start, const end = if (cut(u8, range, "..")) |result| result else .{ range, range };
                const start_codepoint = try std.fmt.parseInt(u21, start, 16);
                const end_codepoint = try std.fmt.parseInt(u21, end, 16);
                @memset(data[start_codepoint .. end_codepoint + 1], .W);
            }
            continue;
        }
        const line = try reader.takeDelimiterExclusive('#');
        var range, var property = if (cutScalar(u8, line, ';')) |result| result else return error.InvalidLine;

        range = std.mem.trim(u8, range, " \t");
        property = std.mem.trim(u8, property, " \t");
        const start, const end = if (cut(u8, range, "..")) |result| result else .{ range, range };
        const start_codepoint = try std.fmt.parseInt(u21, start, 16);
        const end_codepoint = try std.fmt.parseInt(u21, end, 16);
        const property_value = std.meta.stringToEnum(t.EastAsianWidth, property) orelse return error.InvalidProperty;
        @memset(data[start_codepoint .. end_codepoint + 1], property_value);
    }
    return timer.read();
}
