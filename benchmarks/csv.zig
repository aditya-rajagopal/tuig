const std = @import("std");
const assert = std.debug.assert;

pub const Row = struct {
    timestamp_ns: u64,
    mode: []const u8,
    e2e: bool,
    dataset: ?[]const u8,
    text_mix: ?[]const u8,
    style_mix: ?[]const u8,
    cols: ?u32,
    rows: ?u32,
    frames_total: u64,
    warmup_frames: u64,
    seed: u64,
    time_min_ns: u64,
    time_median_ns: u64,
    time_p95_ns: u64,
    time_max_ns: u64,
    time_mean_ns: u64,
    cpu_time_ns: ?u64,
    cpu_user_ns: ?u64,
    cpu_sys_ns: ?u64,
    page_faults_minor: ?u64,
    page_faults_major: ?u64,
    max_rss_bytes: ?u64,
    bytes_total: ?u64,
    bytes_mean: ?f64,
    dirty_ratio_mean: ?f64,
    style_runs_mean: ?f64,
    pmc_cycles_min: ?u64,
    pmc_cycles_median: ?u64,
    pmc_cycles_p95: ?u64,
    pmc_cycles_max: ?u64,
    pmc_cycles_mean: ?u64,
    pmc_instructions_min: ?u64,
    pmc_instructions_median: ?u64,
    pmc_instructions_p95: ?u64,
    pmc_instructions_max: ?u64,
    pmc_instructions_mean: ?u64,
    pmc_cache_misses_min: ?u64,
    pmc_cache_misses_median: ?u64,
    pmc_cache_misses_p95: ?u64,
    pmc_cache_misses_max: ?u64,
    pmc_cache_misses_mean: ?u64,
    pmc_cache_references_min: ?u64,
    pmc_cache_references_median: ?u64,
    pmc_cache_references_p95: ?u64,
    pmc_cache_references_max: ?u64,
    pmc_cache_references_mean: ?u64,
    pmc_branches_min: ?u64,
    pmc_branches_median: ?u64,
    pmc_branches_p95: ?u64,
    pmc_branches_max: ?u64,
    pmc_branches_mean: ?u64,
    pmc_branch_misses_min: ?u64,
    pmc_branch_misses_median: ?u64,
    pmc_branch_misses_p95: ?u64,
    pmc_branch_misses_max: ?u64,
    pmc_branch_misses_mean: ?u64,
};

pub fn writeHeader(writer: *std.Io.Writer) !void {
    assert(@intFromPtr(writer) != 0);
    assert(@sizeOf(@TypeOf(writer.*)) > 0);
    try writer.writeAll(
        "timestamp,mode,e2e,dataset,text_mix,style_mix," ++
            "cols,rows,frames_total,warmup_frames,seed," ++
            "time_min_ns,time_median_ns,time_p95_ns,time_max_ns,time_mean_ns," ++
            "cpu_time_ns,cpu_user_ns,cpu_sys_ns,page_faults_minor,page_faults_major,max_rss_bytes," ++
            "bytes_total,bytes_mean,dirty_ratio_mean,style_runs_mean," ++
            "pmc_cycles_min,pmc_cycles_median,pmc_cycles_p95,pmc_cycles_max,pmc_cycles_mean," ++
            "pmc_instructions_min,pmc_instructions_median,pmc_instructions_p95,pmc_instructions_max,pmc_instructions_mean," ++
            "pmc_cache_misses_min,pmc_cache_misses_median,pmc_cache_misses_p95,pmc_cache_misses_max,pmc_cache_misses_mean," ++
            "pmc_cache_references_min,pmc_cache_references_median,pmc_cache_references_p95,pmc_cache_references_max,pmc_cache_references_mean," ++
            "pmc_branches_min,pmc_branches_median,pmc_branches_p95,pmc_branches_max,pmc_branches_mean," ++
            "pmc_branch_misses_min,pmc_branch_misses_median,pmc_branch_misses_p95,pmc_branch_misses_max,pmc_branch_misses_mean\n",
    );
}

pub fn writeRow(writer: *std.Io.Writer, row: Row) !void {
    assert(@intFromPtr(writer) != 0);
    assert(row.mode.len > 0);

    var csv = CsvWriter.init(writer);
    try csv.writeU64(row.timestamp_ns);
    try csv.writeStr(row.mode);
    try csv.writeBool(row.e2e);
    try csv.writeOptionalStr(row.dataset);
    try csv.writeOptionalStr(row.text_mix);
    try csv.writeOptionalStr(row.style_mix);
    try csv.writeOptionalU32(row.cols);
    try csv.writeOptionalU32(row.rows);
    try csv.writeU64(row.frames_total);
    try csv.writeU64(row.warmup_frames);
    try csv.writeU64(row.seed);
    try csv.writeU64(row.time_min_ns);
    try csv.writeU64(row.time_median_ns);
    try csv.writeU64(row.time_p95_ns);
    try csv.writeU64(row.time_max_ns);
    try csv.writeU64(row.time_mean_ns);
    try csv.writeOptionalU64(row.cpu_time_ns);
    try csv.writeOptionalU64(row.cpu_user_ns);
    try csv.writeOptionalU64(row.cpu_sys_ns);
    try csv.writeOptionalU64(row.page_faults_minor);
    try csv.writeOptionalU64(row.page_faults_major);
    try csv.writeOptionalU64(row.max_rss_bytes);
    try csv.writeOptionalU64(row.bytes_total);
    try csv.writeOptionalF64(row.bytes_mean);
    try csv.writeOptionalF64(row.dirty_ratio_mean);
    try csv.writeOptionalF64(row.style_runs_mean);
    try csv.writeOptionalU64(row.pmc_cycles_min);
    try csv.writeOptionalU64(row.pmc_cycles_median);
    try csv.writeOptionalU64(row.pmc_cycles_p95);
    try csv.writeOptionalU64(row.pmc_cycles_max);
    try csv.writeOptionalU64(row.pmc_cycles_mean);
    try csv.writeOptionalU64(row.pmc_instructions_min);
    try csv.writeOptionalU64(row.pmc_instructions_median);
    try csv.writeOptionalU64(row.pmc_instructions_p95);
    try csv.writeOptionalU64(row.pmc_instructions_max);
    try csv.writeOptionalU64(row.pmc_instructions_mean);
    try csv.writeOptionalU64(row.pmc_cache_misses_min);
    try csv.writeOptionalU64(row.pmc_cache_misses_median);
    try csv.writeOptionalU64(row.pmc_cache_misses_p95);
    try csv.writeOptionalU64(row.pmc_cache_misses_max);
    try csv.writeOptionalU64(row.pmc_cache_misses_mean);
    try csv.writeOptionalU64(row.pmc_cache_references_min);
    try csv.writeOptionalU64(row.pmc_cache_references_median);
    try csv.writeOptionalU64(row.pmc_cache_references_p95);
    try csv.writeOptionalU64(row.pmc_cache_references_max);
    try csv.writeOptionalU64(row.pmc_cache_references_mean);
    try csv.writeOptionalU64(row.pmc_branches_min);
    try csv.writeOptionalU64(row.pmc_branches_median);
    try csv.writeOptionalU64(row.pmc_branches_p95);
    try csv.writeOptionalU64(row.pmc_branches_max);
    try csv.writeOptionalU64(row.pmc_branches_mean);
    try csv.writeOptionalU64(row.pmc_branch_misses_min);
    try csv.writeOptionalU64(row.pmc_branch_misses_median);
    try csv.writeOptionalU64(row.pmc_branch_misses_p95);
    try csv.writeOptionalU64(row.pmc_branch_misses_max);
    try csv.writeOptionalU64(row.pmc_branch_misses_mean);
    try writer.writeAll("\n");
}

const CsvWriter = struct {
    writer: *std.Io.Writer,
    needs_comma: bool,

    fn init(writer: *std.Io.Writer) CsvWriter {
        assert(@intFromPtr(writer) != 0);
        assert(@sizeOf(@TypeOf(writer.*)) > 0);
        return .{ .writer = writer, .needs_comma = false };
    }

    fn writeSeparator(self: *CsvWriter) !void {
        assert(@intFromPtr(self) != 0);
        assert(@intFromPtr(self.writer) != 0);
        if (self.needs_comma) {
            try self.writer.writeAll(",");
        } else {
            self.needs_comma = true;
        }
    }

    fn writeNA(self: *CsvWriter) !void {
        assert(@intFromPtr(self) != 0);
        assert(@intFromPtr(self.writer) != 0);
        try self.writeSeparator();
        try self.writer.writeAll("NA");
    }

    fn writeU64(self: *CsvWriter, value: u64) !void {
        assert(@intFromPtr(self) != 0);
        assert(@intFromPtr(self.writer) != 0);
        try self.writeSeparator();
        try self.writer.print("{d}", .{value});
    }

    fn writeBool(self: *CsvWriter, value: bool) !void {
        assert(@intFromPtr(self) != 0);
        assert(@intFromPtr(self.writer) != 0);
        try self.writeSeparator();
        try self.writer.writeAll(if (value) "1" else "0");
    }

    fn writeOptionalU64(self: *CsvWriter, value: ?u64) !void {
        assert(@intFromPtr(self) != 0);
        assert(@intFromPtr(self.writer) != 0);
        if (value) |val| {
            try self.writeU64(val);
        } else {
            try self.writeNA();
        }
    }

    fn writeOptionalU32(self: *CsvWriter, value: ?u32) !void {
        assert(@intFromPtr(self) != 0);
        assert(@intFromPtr(self.writer) != 0);
        if (value) |val| {
            try self.writeU64(@as(u64, val));
        } else {
            try self.writeNA();
        }
    }

    fn writeF64(self: *CsvWriter, value: f64) !void {
        assert(@intFromPtr(self) != 0);
        assert(@intFromPtr(self.writer) != 0);
        try self.writeSeparator();
        try self.writer.print("{d:.6}", .{value});
    }

    fn writeOptionalF64(self: *CsvWriter, value: ?f64) !void {
        assert(@intFromPtr(self) != 0);
        assert(@intFromPtr(self.writer) != 0);
        if (value) |val| {
            try self.writeF64(val);
        } else {
            try self.writeNA();
        }
    }

    fn writeOptionalStr(self: *CsvWriter, value: ?[]const u8) !void {
        assert(@intFromPtr(self) != 0);
        assert(@intFromPtr(self.writer) != 0);
        if (value) |val| {
            try self.writeStr(val);
        } else {
            try self.writeNA();
        }
    }

    fn writeStr(self: *CsvWriter, value: []const u8) !void {
        assert(@intFromPtr(self) != 0);
        assert(@intFromPtr(self.writer) != 0);
        try self.writeSeparator();

        var needs_quotes = false;
        for (value) |byte| {
            if (byte == ',' or byte == '"' or byte == '\n' or byte == '\r') {
                needs_quotes = true;
                break;
            }
        }

        if (!needs_quotes) {
            try self.writer.writeAll(value);
            return;
        }

        try self.writer.writeAll("\"");
        for (value) |byte| {
            if (byte == '"') {
                try self.writer.writeAll("\"\"");
            } else {
                try self.writer.writeAll(&[_]u8{byte});
            }
        }
        try self.writer.writeAll("\"");
    }
};
