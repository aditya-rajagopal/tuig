const std = @import("std");

const renderer = @import("renderer");
const terminal_mod = @import("terminal");

const dataset_setup = @import("dataset_setup.zig");
const bench_catalog = @import("bench_catalog.zig");
const print_helpers = @import("print_helpers.zig");
const style_mix = @import("style_mix.zig");
const text_mix = @import("text_mix.zig");
const types = @import("types.zig");

const buffer_alignment = std.mem.Alignment.fromByteUnits(std.heap.page_size_min);
pub const BenchMode = types.BenchMode;

pub const InspectConfig = struct {
    bench_mode: BenchMode,
    dataset_name: []const u8,
    text_mix: text_mix.TextMix,
    style_mix: style_mix.StyleMix,
    seed: u64,
};

const InspectMode = enum { form, view };

const Buffer = types.Buffer;

const InspectFrames = struct {
    style_sheet: renderer.Style.Sheet,
    frames: [2]Buffer,
    frame_count: u8,

    fn deinit(self: *InspectFrames, allocator: std.mem.Allocator) void {
        self.frames[0].deinit(allocator);
        self.frames[1].deinit(allocator);
        self.style_sheet.deinit(allocator);
    }
};

const InspectState = struct {
    mode: InspectMode,
    bench_mode: BenchMode,
    print_mode: bool,
    field_index: u8,
    dataset_index: usize,
    text_mix_index: usize,
    style_mix_index: usize,
    seed: u64,
    frame_index: u8,
    show_help: bool,
    frames: ?InspectFrames,
    release_frames: bool,
};

pub fn runInspect(config: InspectConfig) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var write_buffer: [4096]u8 align(4096) = undefined;
    var term_config: terminal_mod.TerminalConfig = .tui_default;
    term_config.cursor_visable = false;
    var terminal: terminal_mod.Terminal = undefined;
    try terminal.init(term_config, &write_buffer);
    defer terminal.deinit();

    var renderer_state: renderer.Renderer = undefined;
    try renderer_state.init(&terminal, .default_screen);

    var style_buffer: [64]renderer.Style = undefined;
    var generation_buffer: [64]u8 = undefined;
    var ui_style_sheet = renderer.Style.Sheet.initBuffer(style_buffer[0..], generation_buffer[0..]);

    var state = initInspectState(config);
    defer if (state.frames) |*frames| frames.deinit(allocator);

    var quit = false;
    while (!quit) {
        const events = try terminal.pollEvents(15);
        const ctx = try renderer_state.beginFrame(events);
        var rendered_sheet: *renderer.Style.Sheet = &ui_style_sheet;
        var needs_end_frame = true;
        errdefer if (needs_end_frame) renderer_state.endFrame(true, &ui_style_sheet);

        switch (state.mode) {
            .form => {
                renderInspectForm(&ctx, &state);
                quit = try handleInspectFormInput(&ctx, &state, allocator);
            },
            .view => {
                if (state.frames) |*frames| {
                    rendered_sheet = &frames.style_sheet;
                }
                try renderInspectView(&ctx, &state);
                quit = handleInspectViewInput(&ctx, &state);
            },
        }

        renderer_state.endFrame(true, rendered_sheet);
        needs_end_frame = false;

        if (state.release_frames) {
            if (state.frames) |*frames| {
                frames.deinit(allocator);
                state.frames = null;
            }
            state.release_frames = false;
        }
    }
}

fn initInspectState(config: InspectConfig) InspectState {
    const mode = config.bench_mode;
    const print_mode = switch (mode) {
        .print, .print_assume_no_grapheme => true,
        else => false,
    };
    const dataset_index = if (print_mode) 0 else findRenderDatasetIndex(config.dataset_name);
    return .{
        .mode = .form,
        .bench_mode = mode,
        .print_mode = print_mode,
        .field_index = 0,
        .dataset_index = dataset_index,
        .text_mix_index = findTextMixIndex(config.text_mix),
        .style_mix_index = findStyleMixIndex(config.style_mix),
        .seed = config.seed,
        .frame_index = 0,
        .show_help = true,
        .frames = null,
        .release_frames = false,
    };
}

fn handleInspectFormInput(ctx: *const renderer.Context, state: *InspectState, allocator: std.mem.Allocator) !bool {
    if (ctx.isKeyPressedThisFrame(.escape)) return true;
    if (ctx.isKeyPressedThisFrame(.enter)) {
        if (state.frames) |*frames| {
            frames.deinit(allocator);
            state.frames = null;
        }
        const cols = ctx.scissor.width_global;
        const rows = ctx.scissor.height_global;
        const text_mix_item = bench_catalog.all_text_mixes[state.text_mix_index];
        const style_mix_item = bench_catalog.all_style_mixes[state.style_mix_index];
        if (state.print_mode) {
            const dataset = bench_catalog.print_datasets[state.dataset_index];
            const palette_len = style_mix.paletteLen(style_mix_item);
            var style_sheet = try renderer.Style.Sheet.initCapacity(allocator, palette_len);
            const style_ids = try allocator.alignedAlloc(renderer.Style.Id, buffer_alignment, palette_len);
            defer allocator.free(style_ids);
            const style_slice = style_mix.fillStyleIds(&style_sheet, allocator, style_mix_item, style_ids);

            var frame0 = try Buffer.init(allocator, cols, rows);
            var frame1 = try Buffer.init(allocator, cols, rows);

            var text_buffer: std.ArrayList(u8) = .empty;
            defer text_buffer.deinit(allocator);
            const target_glyph_cells = @as(u32, dataset.width) * @as(u32, dataset.height) * 2;
            try print_helpers.buildPrintText(allocator, &text_buffer, text_mix_item, state.seed, target_glyph_cells);

            const style_id = if (style_slice.len > 0) style_slice[0] else .default;
            var codepoint_buffer: [256]u21 = undefined;
            const print_mode: print_helpers.PrintMode = switch (state.bench_mode) {
                .print => .print,
                .print_assume_no_grapheme => .print_assume_no_grapheme,
                else => unreachable,
            };
            const frame_count: u8 = 2;

            frame0.fb.clear();
            _ = try print_helpers.renderPrintDataset(frame0.fb.scissor(), dataset, print_mode, codepoint_buffer[0..], text_buffer.items, style_id);
            if (frame_count > 1) {
                frame1.fb.clear();
                _ = try print_helpers.renderPrintDataset(frame1.fb.scissor(), dataset, print_mode, codepoint_buffer[0..], text_buffer.items, style_id);
            }

            state.frames = .{
                .style_sheet = style_sheet,
                .frames = .{ frame0, frame1 },
                .frame_count = frame_count,
            };
        } else {
            const dataset = bench_catalog.render_datasets[state.dataset_index];
            var base = try Buffer.init(allocator, cols, rows);
            defer base.deinit(allocator);

            var assets = try dataset_setup.buildDatasetAssets(
                allocator,
                dataset,
                text_mix_item,
                style_mix_item,
                state.seed,
                &base.fb,
            );
            defer {
                assets.pattern_state.deinit(allocator);
                allocator.free(assets.style_ids);
            }

            const style_sheet = assets.style_sheet;
            const frame_count: u8 = 2;

            var frame0 = try Buffer.init(allocator, cols, rows);
            var frame1 = try Buffer.init(allocator, cols, rows);
            try assets.pattern_state.renderFrame(&frame0.fb, 0);
            if (frame_count > 1) {
                try assets.pattern_state.renderFrame(&frame1.fb, 1);
            }

            state.frames = .{
                .style_sheet = style_sheet,
                .frames = .{ frame0, frame1 },
                .frame_count = frame_count,
            };
        }
        state.mode = .view;
        state.frame_index = 0;
        return false;
    }

    if (ctx.isKeyPressedThisFrame(.up)) {
        state.field_index = if (state.field_index == 0) 3 else state.field_index - 1;
    } else if (ctx.isKeyPressedThisFrame(.down)) {
        state.field_index = if (state.field_index == 3) 0 else state.field_index + 1;
    } else if (ctx.isKeyPressedThisFrame(.left)) {
        adjustInspectField(state, false);
    } else if (ctx.isKeyPressedThisFrame(.right)) {
        adjustInspectField(state, true);
    }

    return false;
}

fn handleInspectViewInput(ctx: *const renderer.Context, state: *InspectState) bool {
    if (ctx.resize != null) {
        state.mode = .form;
        state.release_frames = true;
        return false;
    }
    if (ctx.isKeyPressedThisFrame(.escape)) {
        state.mode = .form;
        state.release_frames = true;
        return false;
    }
    if (ctx.isKeyPressedThisFrame(.Q)) return true;
    if (ctx.isKeyPressedThisFrame(.H)) state.show_help = !state.show_help;

    if (ctx.isKeyPressedThisFrame(.left)) {
        state.frame_index = 0;
    } else if (ctx.isKeyPressedThisFrame(.right)) {
        if (state.frames) |frames| {
            if (frames.frame_count > 1) state.frame_index = 1;
        }
    }

    return false;
}

fn adjustInspectField(state: *InspectState, forward: bool) void {
    switch (state.field_index) {
        0 => state.dataset_index = rotateIndex(
            state.dataset_index,
            if (state.print_mode) bench_catalog.print_datasets.len else bench_catalog.render_datasets.len,
            forward,
        ),
        1 => state.text_mix_index = rotateIndex(state.text_mix_index, bench_catalog.all_text_mixes.len, forward),
        2 => state.style_mix_index = rotateIndex(state.style_mix_index, bench_catalog.all_style_mixes.len, forward),
        3 => {
            if (forward) {
                if (state.seed != std.math.maxInt(u64)) state.seed += 1;
            } else {
                if (state.seed > 0) state.seed -= 1;
            }
        },
        else => {},
    }
}

fn rotateIndex(current: usize, len: usize, forward: bool) usize {
    if (len == 0) return 0;
    if (forward) return (current + 1) % len;
    return if (current == 0) len - 1 else current - 1;
}

fn findRenderDatasetIndex(name: []const u8) usize {
    for (bench_catalog.render_datasets, 0..) |dataset, idx| {
        if (std.mem.eql(u8, dataset.name, name)) return idx;
    }
    return 0;
}

fn findTextMixIndex(mix: text_mix.TextMix) usize {
    for (bench_catalog.all_text_mixes, 0..) |item, idx| {
        if (item == mix) return idx;
    }
    return 0;
}

fn findStyleMixIndex(mix: style_mix.StyleMix) usize {
    for (bench_catalog.all_style_mixes, 0..) |item, idx| {
        if (item == mix) return idx;
    }
    return 0;
}

fn renderInspectForm(ctx: *const renderer.Context, state: *InspectState) void {
    const scissor = ctx.scissor;
    scissor.clear();

    _ = scissor.printAssumeNoGrapheme("Benchmark Inspector", 0, 0, .{ .wrap = false, .tab_width = 4 });
    var mode_buf: [64]u8 = undefined;
    const mode_line = std.fmt.bufPrint(&mode_buf, "Mode: {s}", .{@tagName(state.bench_mode)}) catch "";
    _ = scissor.printAssumeNoGrapheme(mode_line, 0, 1, .{ .wrap = false, .tab_width = 4 });

    var line_buf: [256]u8 = undefined;
    const dataset_name = if (state.print_mode)
        bench_catalog.print_datasets[state.dataset_index].name
    else
        bench_catalog.render_datasets[state.dataset_index].name;
    const text_mix_name = @tagName(bench_catalog.all_text_mixes[state.text_mix_index]);
    const style_mix_name = @tagName(bench_catalog.all_style_mixes[state.style_mix_index]);

    var y: u16 = 3;
    const dataset_line = std.fmt.bufPrint(&line_buf, "{s} Dataset: {s}", .{ fieldPrefix(state, 0), dataset_name }) catch "";
    _ = scissor.printAssumeNoGrapheme(dataset_line, 0, y, .{ .wrap = false, .tab_width = 4 });
    y += 1;
    const text_line = std.fmt.bufPrint(&line_buf, "{s} Text mix: {s}", .{ fieldPrefix(state, 1), text_mix_name }) catch "";
    _ = scissor.printAssumeNoGrapheme(text_line, 0, y, .{ .wrap = false, .tab_width = 4 });
    y += 1;
    const style_line = std.fmt.bufPrint(&line_buf, "{s} Style mix: {s}", .{ fieldPrefix(state, 2), style_mix_name }) catch "";
    _ = scissor.printAssumeNoGrapheme(style_line, 0, y, .{ .wrap = false, .tab_width = 4 });
    y += 1;
    const seed_line = std.fmt.bufPrint(&line_buf, "{s} Seed: {d}", .{ fieldPrefix(state, 3), state.seed }) catch "";
    _ = scissor.printAssumeNoGrapheme(seed_line, 0, y, .{ .wrap = false, .tab_width = 4 });
    y += 1;

    var size_buf: [64]u8 = undefined;
    const size_line = std.fmt.bufPrint(&size_buf, "Size: {d}x{d} (terminal)", .{ scissor.width_global, scissor.height_global }) catch "";
    _ = scissor.printAssumeNoGrapheme(size_line, 0, y + 1, .{ .wrap = false, .tab_width = 4 });

    const help_line = "Up/Down: field  Left/Right: change  Enter: view  Esc: quit";
    if (scissor.height_global > 1) {
        const help_y = scissor.height_global - 1;
        _ = scissor.printAssumeNoGrapheme(help_line, 0, help_y, .{ .wrap = false, .tab_width = 4 });
    }
}

fn fieldPrefix(state: *InspectState, index: u8) []const u8 {
    return if (state.field_index == index) ">" else " ";
}

fn renderInspectView(ctx: *const renderer.Context, state: *InspectState) !void {
    const scissor = ctx.scissor;
    scissor.clear();

    if (state.frames) |frames| {
        const frame_index: u8 = if (state.frame_index > 0 and frames.frame_count > 1) 1 else 0;
        const src = &frames.frames[frame_index].fb;
        const blit_width: u16 = @min(scissor.width_global, src.width);
        const blit_height: u16 = @min(scissor.height_global, src.height);
        var y: u16 = 0;
        while (y < blit_height) : (y += 1) {
            var x: u16 = 0;
            while (x < blit_width) : (x += 1) {
                const cell = src.get(x, y);
                scissor.set(x, y, cell);
            }
        }
        const src_end = src.grapheme_buffer.end_index;
        try scissor.buffer.grapheme_buffer.ensureTotalCapacity(src_end);
        scissor.buffer.grapheme_buffer.end_index = src_end;
        scissor.buffer.grapheme_buffer.generation = src.grapheme_buffer.generation;
        if (src_end > 0) {
            @memcpy(
                scissor.buffer.grapheme_buffer.buffer.reserved_pages[0..src_end],
                src.grapheme_buffer.buffer.reserved_pages[0..src_end],
            );
        }

        if (state.show_help and scissor.height_global > 0) {
            const bar = scissor.initChild(0, @intCast(scissor.height_global - 1), scissor.width_global, 1);
            const row: u16 = 0;
            if (row < bar.height_global) {
                const bar_width = bar.width_global;
                var x: u16 = 0;
                while (x < bar_width) : (x += 1) {
                    bar.set(x, row, renderer.Cell.empty);
                }
            }
            var info_buf: [160]u8 = undefined;
            const info = std.fmt.bufPrint(
                &info_buf,
                "Frame {d}/{d}  Left/Right: swap  Esc: back  Q: quit  H: toggle help",
                .{ frame_index + 1, frames.frame_count },
            ) catch "";
            _ = bar.printAssumeNoGrapheme(info, 0, 0, .{ .wrap = false, .tab_width = 4 });
        }
        return;
    }

    _ = scissor.printAssumeNoGrapheme("No frames generated", 0, 0, .{ .wrap = false, .tab_width = 4 });
}
