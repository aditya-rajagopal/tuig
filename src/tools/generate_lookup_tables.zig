const std = @import("std");
const assert = std.debug.assert;

const helpers = @import("helpers.zig");
const t = @import("types.zig");
const u = @import("unicode_info.zig");
const UnicodeInfo = u.UnicodeInfo;
const MAX_CODEPOINT = u.MAX_CODEPOINT;
const Data = u.Data;
const parser = @import("parser.zig");

pub fn main(init: std.process.Init.Minimal) !void {
    var start = std.time.Timer.start() catch unreachable;
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{ .environ = init.environ });
    const io = threaded.io();

    const info = try UnicodeInfo.init(std.heap.page_allocator);
    const times = try parser.parseUCDFiles(io, info);

    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    try stdout.interface.print("Total Time to parse UCD files: {d}ms\n", .{@as(f32, @floatFromInt(start.read())) / std.time.ns_per_ms});
    try stdout.interface.print("    GeneralCategory: {d}ms\n", .{@as(f32, @floatFromInt(times.general_category)) / std.time.ns_per_ms});
    try stdout.interface.print("    DerivedCoreProperties: {d}ms\n", .{@as(f32, @floatFromInt(times.derived_core_properties)) / std.time.ns_per_ms});
    try stdout.interface.print("    GraphemeBreakProperty: {d}ms\n", .{@as(f32, @floatFromInt(times.grapheme_break)) / std.time.ns_per_ms});
    try stdout.interface.print("    EastAsianWidth: {d}ms\n", .{@as(f32, @floatFromInt(times.east_asian_width)) / std.time.ns_per_ms});
    try stdout.interface.print("    Emoji: {d}ms\n", .{@as(f32, @floatFromInt(times.emoji)) / std.time.ns_per_ms});
    try stdout.interface.flush();

    _ = try generatePropertyLookupTable(io, std.heap.page_allocator, &stdout.interface, info);
    try stdout.interface.flush();
}

// Reference:
// https://github.com/jacobsandlund/uucode/blob/ad6f8813b9163bfc93626ebbc0f1023e11c51de7/src/x/config_x/wcwidth.zig
pub fn getWidth(
    cp: u21,
    data: UnicodeInfo.Data,
) u2 {
    var width: u2 = 0;
    if (data.general_category == .Cc or // Other, Control
        data.general_category == .Cs or // Other, Surrogate
        data.general_category == .Zl or // Separator, Line
        data.general_category == .Zp) // Separator, Paragraph
    {
        width = 0;
    } else if (cp == 0x00AD0) { // Soft Hyphen
        width = 1;
    } else if (data.derived_core_properties.Default_Ignorable_Code_Point) {
        width = 0;
    } else if (cp == 0x2E3A) { // Two-Em Dash
        width = 2;
    } else if (cp == 0x2E3B) { // Three-Em Dash
        // NOTE: Treating it as 2 space since in terminals you cant render more than 2 spaces
        width = 2;
    } else if (data.east_asian_width == .W or data.east_asian_width == .F) {
        width = 2;
    } else if (data.grapheme_break == .Regional_Indicator) {
        width = 2;
    } else {
        width = 1;
    }

    const wcwidth_standalone = if (cp == 0x20E3) 2 else width;
    const wcwidth_zero_in_grapheme =
        if (width == 0 or
        data.emoji.Emoji_Modifier or
        data.derived_core_properties.Default_Ignorable_Code_Point or
        data.general_category == .Me or // Mark, Enclosing
        data.general_category == .Mn or // Mark, Non-Spacing
        data.grapheme_break == .V or
        data.grapheme_break == .T or
        data.grapheme_break == .Prepend)
            true
        else
            false;

    if (wcwidth_zero_in_grapheme and !data.emoji.Emoji_Modifier_Base) {
        return 0;
    } else {
        return wcwidth_standalone;
    }
}

// Reference:
// https://github.com/ghostty-org/ghostty/blob/2fd3efd6cdf0629f57572af58dff0ae9115ce919/src/unicode/props.zig#L50
pub const GraphemeBoundryClass = enum(u4) {
    // We will not need these as we can premeturely discard them
    // CR,
    // LF,
    // Control,
    invalid,
    prepend,
    extend,
    regional_indicator,
    spacing_mark,
    L,
    V,
    T,
    LV,
    LVT,
    zwj,
    extended_pictographic,
    extended_pictographic_base, // \p{ExtendedPictographic} & \p{Emoji_Modifier_Base}
    emoji_modifier, // \p{Emoji_Modifier}
    // Prepend,

    pub fn getFromProperties(
        cp: u21,
        emoji: t.Emoji,
        props: t.DerivedCoreProperties,
        grapheme_break: t.GraphemeBreakProperty,
    ) GraphemeBoundryClass {
        if (emoji.Emoji_Modifier) {
            assert(grapheme_break == .Extend);
            assert(!emoji.Extended_Pictographic and emoji.Emoji_Component);
            return .emoji_modifier;
        } else if (emoji.Emoji_Modifier_Base) {
            assert(grapheme_break == .Other);
            assert(emoji.Extended_Pictographic);
            return .extended_pictographic_base;
        } else if (emoji.Extended_Pictographic) {
            assert(grapheme_break == .Other);
            return .extended_pictographic;
        } else {
            switch (props.InCB) {
                .None => {
                    switch (grapheme_break) {
                        .Extend => {
                            if (cp == 0x200C) return .extend else {
                                std.log.err("Invalid grapheme break 0x{x} with `Extend` GraphemeBreakProperty and None InCB", .{cp});
                                unreachable;
                            }
                        },
                        .CR, .LF, .Control, .Other => return .invalid,
                        .Prepend => return .prepend,
                        .Regional_Indicator => return .regional_indicator,
                        .SpacingMark => return .spacing_mark,
                        .L => return .L,
                        .V => return .V,
                        .T => return .T,
                        .LV => return .LV,
                        .LVT => return .LVT,
                        .ZWJ => return .zwj,
                    }
                },
                .Extend => {
                    if (cp == 0x200D) {
                        assert(grapheme_break == .ZWJ);
                        return .zwj;
                    } else {
                        assert(grapheme_break == .Extend);
                        return .extend;
                    }
                },
                .Consonant => {
                    assert(grapheme_break == .Other);
                    return .invalid;
                },
                .Linker => {
                    assert(grapheme_break == .Extend);
                    return .extend;
                },
            }
        }
        unreachable;
    }

    pub fn isExtendedPictographic(self: GraphemeBoundryClass) bool {
        switch (self) {
            .extended_pictographic, .extended_pictographic_base => return true,
            else => return false,
        }
    }
};

pub const Property = packed struct {
    width: u2 = 0,
    grapheme_boundary_class: GraphemeBoundryClass = .invalid,

    pub const invalid = Property{ .width = 1, .grapheme_boundary_class = .invalid };

    pub fn get(
        cp: u21,
        data: UnicodeInfo.Data,
    ) Property {
        assert(cp <= MAX_CODEPOINT);
        return .{
            .width = getWidth(cp, data),
            .grapheme_boundary_class = .getFromProperties(cp, data.emoji, data.derived_core_properties, data.grapheme_break),
        };
    }

    pub fn format(self: Property, writer: *std.Io.Writer) !void {
        try writer.print(
            \\ .{{ .width = {d}, .grapheme_boundary_class = .{s} }}
        , .{ self.width, @tagName(self.grapheme_boundary_class) });
    }
};

pub fn generatePropertyLookupTable(
    io: std.Io,
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    info: UnicodeInfo,
) !u64 {
    _ = io;
    var start = std.time.Timer.start() catch unreachable;

    var stage1: std.ArrayList(u16) = .empty;
    var stage2: std.ArrayList(u16) = .empty;
    var stage3: std.ArrayList(Property) = .empty;
    defer {
        stage1.deinit(allocator);
        stage2.deinit(allocator);
        stage3.deinit(allocator);
    }

    const block_size = 256;
    const Block = [block_size]u16;

    var block: Block = undefined;
    var index_block: u16 = 0;

    var block_map = std.HashMap(Block, u16, struct {
        pub fn hash(_: @This(), b: Block) u64 {
            var hasher = std.hash.Wyhash.init(0);
            for (b) |id| {
                @call(.always_inline, std.hash.Wyhash.update, .{ &hasher, std.mem.asBytes(&id) });
            }
            return hasher.final();
        }
        pub fn eql(_: @This(), a: Block, b: Block) bool {
            return std.mem.eql(u16, &a, &b);
        }
    }, std.hash_map.default_max_load_percentage).init(allocator);

    for (0..std.math.maxInt(u21)) |cp| {
        const element: Property = if (cp >= MAX_CODEPOINT) .invalid else .get(@truncate(cp), info.get(@truncate(cp)));

        const index_stage3 = std.mem.findScalar(Property, stage3.items, element) orelse blk: {
            const i = stage3.items.len;
            try stage3.append(allocator, element);
            break :blk i;
        };
        block[index_block] = std.math.cast(u16, index_stage3) orelse return error.Stage3Overflow;
        index_block += 1;

        // If we are in the last cp we need to commit the block
        if (index_block < block_size and cp != std.math.maxInt(u21)) continue;
        // clear out the remaining
        if (index_block < block_size) @memset(block[index_block..block_size], 0);

        const gop = try block_map.getOrPut(block);
        if (!gop.found_existing) {
            gop.value_ptr.* = std.math.cast(u16, stage2.items.len) orelse return error.Stage2Overflow;
            try stage2.appendSlice(allocator, block[0..index_block]);
        }

        try stage1.append(allocator, gop.value_ptr.*);
        index_block = 0;
    }

    std.debug.assert(stage1.items.len <= std.math.maxInt(u16));
    std.debug.assert(stage2.items.len <= std.math.maxInt(u16));
    std.debug.assert(stage3.items.len <= std.math.maxInt(u16));

    try writer.writeAll(
        \\pub const Property = packed struct {
        \\    width: u2 = 0,
        \\    grapheme_boundary_class: GraphemeBoundryClass = .invalid,
        \\};
        \\
        \\pub const GraphemeBoundryClass = enum(u4) {
        \\    // We will not need these as we can premeturely discard them
        \\    // CR,
        \\    // LF,
        \\    // Control,
        \\    invalid,
        \\    prepend,
        \\    extend,
        \\    regional_indicator,
        \\    spacing_mark,
        \\    L,
        \\    V,
        \\    T,
        \\    LV,
        \\    LVT,
        \\    zwj,
        \\    extended_pictographic,
        \\    extended_pictographic_base, // \\p{ExtendedPictographic} & \\p{Emoji_Modifier_Base}
        \\    emoji_modifier, // \\p{Emoji_Modifier}
        \\
        \\    pub fn isExtendedPictographic(self: GraphemeBoundryClass) bool {
        \\        switch (self) {
        \\            .extended_pictographic, .extended_pictographic_base => return true,
        \\            else => return false,
        \\        }
        \\    }
        \\};
        \\
    );

    try writer.print(
        \\pub const PropertyTable = struct {{
        \\    pub const stage1: [{d}]u16 = .{{
        \\        
    , .{stage1.items.len});

    for (stage1.items[0 .. stage1.items.len - 1], 0..) |item, i| {
        try writer.print("{d},", .{item});
        if (i % 16 == 15) try writer.writeAll("\n        ");
    }
    try writer.print("{d}\n    }},\n", .{stage1.items[stage1.items.len - 1]});

    try writer.print(
        \\    pub const stage2: [{d}]u16 = .{{
        \\        
    , .{stage2.items.len});

    for (stage2.items[0 .. stage2.items.len - 1], 0..) |item, i| {
        try writer.print("{d},", .{item});
        if (i % 16 == 15) try writer.writeAll("\n        ");
    }
    try writer.print("{d}\n    }},\n", .{stage2.items[stage2.items.len - 1]});

    try writer.print(
        \\    pub const stage3: [{d}]Property = .{{
        \\
    , .{stage3.items.len});

    for (stage3.items) |item| {
        try writer.print("        {f}\n", .{item});
    }

    try writer.writeAll("};\n\n");
    try writer.flush();

    return start.read();
}

pub fn generateGraphemeBreakLookupTable(io: std.Io) !u64 {
    _ = io;
    var start = std.time.Timer.start() catch unreachable;

    return start.read();
}
