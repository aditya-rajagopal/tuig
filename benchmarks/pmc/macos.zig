//! https://github.com/D-Berg/crap/blob/main/src/xnu.zig

const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.bench_pmc);

pub const max_events: usize = 4;
pub const max_counters: usize = 32;
pub const MaxEvents: usize = max_events;

const KPC_CLASS_FIXED_MASK: u32 = 1 << 0;
const KPC_CLASS_CONFIGURABLE_MASK: u32 = 1 << 1;

const kpc_config_t = u64;
const kpep_db = opaque {};
const kpep_config = opaque {};
const kpep_event = opaque {};

pub const EventResult = struct {
    name: ?[]const u8,
    value: ?u64,
};

pub const Result = struct {
    cycles: ?u64,
    instructions: ?u64,
    events: [max_events]EventResult,
};

const max_selection: usize = max_events + 2;

const EventSelection = struct {
    event_ptrs: [max_selection]*kpep_event,
    cycles_index: ?usize,
    instructions_index: ?usize,
    event_index_for_slot: [max_events]?usize,
    event_count: usize,
};

pub const Pmc = struct {
    enabled: bool,
    active: bool,
    kperf: ?std.DynLib,
    kperfdata: ?std.DynLib,
    fns: ?Functions,
    classes: u32,
    counter_count: u32,
    cycles_counter: ?usize,
    instructions_counter: ?usize,
    kpc_reg_count: usize,
    kpc_regs: [max_counters]kpc_config_t,
    event_counters: [max_events]?usize,
    event_names: [max_events]?[]const u8,
    counters_start: [max_counters]u64,
    use_force_all: bool,

    pub fn init(enable: bool) !Pmc {
        var state = Pmc{
            .enabled = enable,
            .active = false,
            .kperf = null,
            .kperfdata = null,
            .fns = null,
            .classes = 0,
            .counter_count = 0,
            .cycles_counter = null,
            .instructions_counter = null,
            .kpc_reg_count = 0,
            .kpc_regs = [_]kpc_config_t{0} ** max_counters,
            .event_counters = .{ null, null, null, null },
            .event_names = .{ null, null, null, null },
            .counters_start = [_]u64{0} ** max_counters,
            .use_force_all = false,
        };

        if (!enable) return state;

        var kperf = openFirst(&kperf_paths) orelse {
            log.warn("PMC disabled: kperf not found", .{});
            return error.MissingKperf;
        };

        const kperf_fns = resolveKperf(&kperf) orelse {
            log.warn("PMC disabled: missing kperf symbols", .{});
            kperf.close();
            return error.MissingSymbols;
        };

        state.kperf = kperf;
        state.fns = Functions{ .kperf = kperf_fns, .kpep = null };

        var kperfdata = openFirst(&kperfdata_paths) orelse {
            log.warn("PMC configurable events unavailable: kperfdata not found", .{});
            return error.MissingKperfdata;
        };

        const kpep_fns = resolveKpep(&kperfdata) orelse {
            log.warn("PMC configurable events unavailable: missing kpep symbols", .{});
            kperfdata.close();
            return error.MissingSymbols;
        };

        state.kperfdata = kperfdata;
        state.fns = Functions{ .kperf = kperf_fns, .kpep = kpep_fns };
        return state;
    }

    pub fn deinit(self: *Pmc) void {
        if (self.kperfdata) |*lib| {
            lib.close();
            self.kperfdata = null;
        }
        if (self.kperf) |*lib| {
            lib.close();
            self.kperf = null;
        }
    }

    pub fn start(self: *Pmc, event_names: [max_events][]const u8) bool {
        self.active = false;
        if (!self.enabled) return false;

        const fns = self.fns orelse return false;
        _ = self.kperf orelse return false;

        self.resetEvents();
        self.classes = 0;
        self.use_force_all = false;

        var configured = false;
        if (fns.kpep) |kpep| {
            configured = self.configureWithKpep(kpep, fns.kperf, event_names);
        }

        if (!configured) {
            self.classes = KPC_CLASS_FIXED_MASK;
            self.counter_count = fns.kperf.kpc_get_counter_count(self.classes);
            if (self.counter_count < 2 or self.counter_count > max_counters) {
                log.warn("PMC disabled: invalid counter count", .{});
                return false;
            }
            self.cycles_counter = 0;
            self.instructions_counter = 1;
        }

        if (self.use_force_all) {
            if (fns.kperf.kpc_force_all_ctrs_set(1) != 0) {
                log.warn("PMC disabled: permission denied", .{});
                return false;
            }
        }

        if (self.kpc_reg_count > 0) {
            if (fns.kperf.kpc_set_config(self.classes, &self.kpc_regs[0]) != 0) {
                log.warn("PMC disabled: config unavailable", .{});
                return false;
            }
        }

        if (fns.kperf.kpc_set_counting(self.classes) != 0) {
            log.warn("PMC disabled: counting unavailable", .{});
            return false;
        }
        if (fns.kperf.kpc_set_thread_counting(self.classes) != 0) {
            log.warn("PMC disabled: thread counting unavailable", .{});
            return false;
        }

        if (fns.kperf.kpc_get_thread_counters(0, self.counter_count, &self.counters_start[0]) != 0) {
            log.warn("PMC disabled: failed to read counters", .{});
            return false;
        }

        self.active = true;
        return true;
    }

    pub fn stop(self: *Pmc) error{Failed}!Result {
        var result = Result{
            .cycles = null,
            .instructions = null,
            .events = .{
                .{ .name = null, .value = null },
                .{ .name = null, .value = null },
                .{ .name = null, .value = null },
                .{ .name = null, .value = null },
            },
        };

        if (!self.active) return result;
        const fns = self.fns orelse return result;

        var counters_end = [_]u64{0} ** max_counters;
        if (fns.kperf.kpc_get_thread_counters(0, self.counter_count, &counters_end[0]) != 0) {
            log.warn("PMC disabled: failed to read counters", .{});
            try self.stopCounting(fns.kperf);
            return result;
        }

        if (self.cycles_counter) |counter_idx| {
            if (counter_idx < self.counter_count) {
                result.cycles = counters_end[counter_idx] - self.counters_start[counter_idx];
            }
        }
        if (self.instructions_counter) |counter_idx| {
            if (counter_idx < self.counter_count) {
                result.instructions = counters_end[counter_idx] - self.counters_start[counter_idx];
            }
        }

        for (self.event_counters, 0..) |counter_idx_opt, i| {
            if (counter_idx_opt) |counter_idx| {
                if (counter_idx < self.counter_count) {
                    const diff = counters_end[counter_idx] - self.counters_start[counter_idx];
                    result.events[i] = .{ .name = self.event_names[i], .value = diff };
                }
            }
        }

        try self.stopCounting(fns.kperf);
        return result;
    }

    pub fn snapshot(self: *Pmc) error{Failed}!Result {
        var result = Result{
            .cycles = null,
            .instructions = null,
            .events = .{
                .{ .name = null, .value = null },
                .{ .name = null, .value = null },
                .{ .name = null, .value = null },
                .{ .name = null, .value = null },
            },
        };

        if (!self.active) return result;
        const fns = self.fns orelse return result;

        var counters_end = [_]u64{0} ** max_counters;
        if (fns.kperf.kpc_get_thread_counters(0, self.counter_count, &counters_end[0]) != 0) {
            log.warn("PMC disabled: failed to read counters", .{});
            try self.stopCounting(fns.kperf);
            return result;
        }

        if (self.cycles_counter) |counter_idx| {
            if (counter_idx < self.counter_count) {
                result.cycles = counters_end[counter_idx] - self.counters_start[counter_idx];
            }
        }
        if (self.instructions_counter) |counter_idx| {
            if (counter_idx < self.counter_count) {
                result.instructions = counters_end[counter_idx] - self.counters_start[counter_idx];
            }
        }

        for (self.event_counters, 0..) |counter_idx_opt, i| {
            if (counter_idx_opt) |counter_idx| {
                if (counter_idx < self.counter_count) {
                    const diff = counters_end[counter_idx] - self.counters_start[counter_idx];
                    result.events[i] = .{ .name = self.event_names[i], .value = diff };
                }
            }
        }

        self.counters_start = counters_end;
        return result;
    }

    pub fn resetStart(self: *Pmc) error{Failed}!bool {
        if (!self.active) return false;
        const fns = self.fns orelse return false;

        if (fns.kperf.kpc_get_thread_counters(0, self.counter_count, &self.counters_start[0]) != 0) {
            log.warn("PMC disabled: failed to read counters", .{});
            try self.stopCounting(fns.kperf);
            return false;
        }
        return true;
    }

    fn resetEvents(self: *Pmc) void {
        self.cycles_counter = null;
        self.instructions_counter = null;
        self.kpc_reg_count = 0;
        self.kpc_regs = [_]kpc_config_t{0} ** max_counters;
        for (0..max_events) |i| {
            self.event_counters[i] = null;
            self.event_names[i] = null;
        }
    }

    fn configureWithKpep(
        self: *Pmc,
        kpep: KpepFns,
        kperf: KperfFns,
        requested: [max_events][]const u8,
    ) bool {
        var db: ?*kpep_db = null;
        if (kpep.kpep_db_create(null, &db) != 0) return false;
        assert(db != null);
        defer kpep.kpep_db_free(db);

        var cfg: ?*kpep_config = null;
        if (kpep.kpep_config_create(db, &cfg) != 0) return false;
        assert(cfg != null);
        defer kpep.kpep_config_free(cfg);

        if (kpep.kpep_config_force_counters(cfg) != 0) return false;

        var selection = selectEvents(kpep, db.?, requested);
        if (selection.event_count == 0) return false;

        for (selection.event_ptrs[0..selection.event_count]) |*event_ptr| {
            if (kpep.kpep_config_add_event(cfg, event_ptr, 0, null) != 0) return false;
        }

        var classes: u32 = 0;
        var reg_count: usize = 0;
        if (kpep.kpep_config_kpc_classes(cfg, &classes) != 0) return false;
        if (kpep.kpep_config_kpc_count(cfg, &reg_count) != 0) return false;
        if (reg_count == 0 or reg_count > max_counters) return false;

        var counter_map: [max_counters]usize = undefined;
        if (kpep.kpep_config_kpc_map(cfg, &counter_map[0], @sizeOf(@TypeOf(counter_map))) != 0) {
            return false;
        }

        if (kpep.kpep_config_kpc(cfg, &self.kpc_regs[0], @sizeOf(@TypeOf(self.kpc_regs))) != 0) {
            return false;
        }
        self.kpc_reg_count = reg_count;

        self.use_force_all = (classes & KPC_CLASS_CONFIGURABLE_MASK) != 0;
        self.classes = classes;
        self.counter_count = kperf.kpc_get_counter_count(self.classes);
        if (self.counter_count == 0 or self.counter_count > max_counters) return false;

        if (selection.cycles_index) |event_index| {
            if (event_index < counter_map.len) {
                self.cycles_counter = counter_map[event_index];
            }
        }
        if (selection.instructions_index) |event_index| {
            if (event_index < counter_map.len) {
                self.instructions_counter = counter_map[event_index];
            }
        }
        for (selection.event_index_for_slot, 0..) |event_index_opt, slot| {
            if (event_index_opt) |event_index| {
                if (event_index < counter_map.len) {
                    self.event_counters[slot] = counter_map[event_index];
                    self.event_names[slot] = requested[slot];
                }
            }
        }
        return true;
    }

    fn selectEvents(kpep: KpepFns, db: *kpep_db, requested: [max_events][]const u8) EventSelection {
        var selection = EventSelection{
            .event_ptrs = undefined,
            .cycles_index = null,
            .instructions_index = null,
            .event_index_for_slot = .{ null, null, null, null },
            .event_count = 0,
        };

        selection.cycles_index = addEventByCandidates(kpep, db, cycle_candidates[0..], &selection);
        selection.instructions_index = addEventByCandidates(kpep, db, instruction_candidates[0..], &selection);

        for (requested, 0..) |name, slot| {
            const candidates = candidatesForName(name);
            if (candidates.len == 0) continue;
            if (addEventByCandidates(kpep, db, candidates, &selection)) |event_index| {
                selection.event_index_for_slot[slot] = event_index;
            }
        }

        return selection;
    }

    fn addEventByCandidates(
        kpep: KpepFns,
        db: *kpep_db,
        candidates: []const [:0]const u8,
        selection: *EventSelection,
    ) ?usize {
        var event_ptr: ?*kpep_event = null;
        for (candidates) |candidate| {
            if (kpep.kpep_db_event(db, candidate, &event_ptr) == 0) break;
        }
        if (event_ptr) |event| {
            assert(selection.event_count < max_selection);
            const index = selection.event_count;
            selection.event_ptrs[selection.event_count] = event;
            selection.event_count += 1;
            return index;
        }
        return null;
    }

    fn stopCounting(self: *Pmc, kperf: KperfFns) error{Failed}!void {
        if (kperf.kpc_set_counting(0) != 0) return error.Failed;
        if (kperf.kpc_set_thread_counting(0) != 0) return error.Failed;
        if (self.use_force_all) {
            if (kperf.kpc_force_all_ctrs_set(0) != 0) return error.Failed;
        }
        self.active = false;
    }
};

const Functions = struct {
    kperf: KperfFns,
    kpep: ?KpepFns,
};

const KperfFns = struct {
    kpc_get_counter_count: FnKpcGetCounterCount,
    kpc_set_counting: FnKpcSetCounting,
    kpc_set_thread_counting: FnKpcSetThreadCounting,
    kpc_get_thread_counters: FnKpcGetThreadCounters,
    kpc_force_all_ctrs_set: FnKpcForceAllCtrsSet,
    kpc_set_config: FnKpcSetConfig,
};

const KpepFns = struct {
    kpep_db_create: FnKpepDbCreate,
    kpep_db_free: FnKpepDbFree,
    kpep_db_event: FnKpepDbEvent,
    kpep_config_create: FnKpepConfigCreate,
    kpep_config_free: FnKpepConfigFree,
    kpep_config_force_counters: FnKpepConfigForceCounters,
    kpep_config_add_event: FnKpepConfigAddEvent,
    kpep_config_kpc_classes: FnKpepConfigKpcClasses,
    kpep_config_kpc_count: FnKpepConfigKpcCount,
    kpep_config_kpc_map: FnKpepConfigKpcMap,
    kpep_config_kpc: FnKpepConfigKpc,
};

const FnKpcGetCounterCount = *const fn (u32) callconv(.c) u32;
const FnKpcSetCounting = *const fn (u32) callconv(.c) i32;
const FnKpcSetThreadCounting = *const fn (u32) callconv(.c) i32;
const FnKpcGetThreadCounters = *const fn (u32, u32, *u64) callconv(.c) i32;
const FnKpcForceAllCtrsSet = *const fn (i32) callconv(.c) i32;
const FnKpcSetConfig = *const fn (u32, *kpc_config_t) callconv(.c) i32;

const FnKpepDbCreate = *const fn (?[*:0]const u8, *?*kpep_db) callconv(.c) i32;
const FnKpepDbFree = *const fn (?*kpep_db) callconv(.c) void;
const FnKpepDbEvent = *const fn (?*kpep_db, [*:0]const u8, *?*kpep_event) callconv(.c) i32;
const FnKpepConfigCreate = *const fn (?*kpep_db, *?*kpep_config) callconv(.c) i32;
const FnKpepConfigFree = *const fn (?*kpep_config) callconv(.c) void;
const FnKpepConfigForceCounters = *const fn (?*kpep_config) callconv(.c) i32;
const FnKpepConfigAddEvent = *const fn (?*kpep_config, **kpep_event, u32, ?*u32) callconv(.c) i32;
const FnKpepConfigKpcClasses = *const fn (?*kpep_config, *u32) callconv(.c) i32;
const FnKpepConfigKpcCount = *const fn (?*kpep_config, *usize) callconv(.c) i32;
const FnKpepConfigKpcMap = *const fn (?*kpep_config, *usize, usize) callconv(.c) i32;
const FnKpepConfigKpc = *const fn (?*kpep_config, *kpc_config_t, usize) callconv(.c) i32;

const kperf_paths = [_][]const u8{
    "/System/Library/PrivateFrameworks/kperf.framework/Versions/A/kperf",
    "/System/Library/PrivateFrameworks/kperf.framework/kperf",
    "/System/Library/PrivateFrameworks/kperf.framework/Versions/Current/kperf",
};

const kperfdata_paths = [_][]const u8{
    "/System/Library/PrivateFrameworks/kperfdata.framework/Versions/A/kperfdata",
    "/System/Library/PrivateFrameworks/kperfdata.framework/kperfdata",
    "/System/Library/PrivateFrameworks/kperfdata.framework/Versions/Current/kperfdata",
};

fn openFirst(paths: []const []const u8) ?std.DynLib {
    for (paths) |path| {
        if (std.DynLib.open(path)) |lib| {
            return lib;
        } else |_| {}
    }
    return null;
}

fn resolveKperf(lib: *std.DynLib) ?KperfFns {
    const kpc_get_counter_count = lib.lookup(FnKpcGetCounterCount, "kpc_get_counter_count") orelse return null;
    const kpc_set_counting = lib.lookup(FnKpcSetCounting, "kpc_set_counting") orelse return null;
    const kpc_set_thread_counting = lib.lookup(FnKpcSetThreadCounting, "kpc_set_thread_counting") orelse return null;
    const kpc_get_thread_counters =
        lib.lookup(FnKpcGetThreadCounters, "kpc_get_thread_counters") orelse return null;
    const kpc_force_all_ctrs_set =
        lib.lookup(FnKpcForceAllCtrsSet, "kpc_force_all_ctrs_set") orelse return null;
    const kpc_set_config = lib.lookup(FnKpcSetConfig, "kpc_set_config") orelse return null;

    return .{
        .kpc_get_counter_count = kpc_get_counter_count,
        .kpc_set_counting = kpc_set_counting,
        .kpc_set_thread_counting = kpc_set_thread_counting,
        .kpc_get_thread_counters = kpc_get_thread_counters,
        .kpc_force_all_ctrs_set = kpc_force_all_ctrs_set,
        .kpc_set_config = kpc_set_config,
    };
}

fn resolveKpep(lib: *std.DynLib) ?KpepFns {
    const kpep_db_create = lib.lookup(FnKpepDbCreate, "kpep_db_create") orelse return null;
    const kpep_db_free = lib.lookup(FnKpepDbFree, "kpep_db_free") orelse return null;
    const kpep_db_event = lib.lookup(FnKpepDbEvent, "kpep_db_event") orelse return null;
    const kpep_config_create = lib.lookup(FnKpepConfigCreate, "kpep_config_create") orelse return null;
    const kpep_config_free = lib.lookup(FnKpepConfigFree, "kpep_config_free") orelse return null;
    const kpep_config_force_counters =
        lib.lookup(FnKpepConfigForceCounters, "kpep_config_force_counters") orelse return null;
    const kpep_config_add_event = lib.lookup(FnKpepConfigAddEvent, "kpep_config_add_event") orelse return null;
    const kpep_config_kpc_classes =
        lib.lookup(FnKpepConfigKpcClasses, "kpep_config_kpc_classes") orelse return null;
    const kpep_config_kpc_count = lib.lookup(FnKpepConfigKpcCount, "kpep_config_kpc_count") orelse return null;
    const kpep_config_kpc_map = lib.lookup(FnKpepConfigKpcMap, "kpep_config_kpc_map") orelse return null;
    const kpep_config_kpc = lib.lookup(FnKpepConfigKpc, "kpep_config_kpc") orelse return null;

    return .{
        .kpep_db_create = kpep_db_create,
        .kpep_db_free = kpep_db_free,
        .kpep_db_event = kpep_db_event,
        .kpep_config_create = kpep_config_create,
        .kpep_config_free = kpep_config_free,
        .kpep_config_force_counters = kpep_config_force_counters,
        .kpep_config_add_event = kpep_config_add_event,
        .kpep_config_kpc_classes = kpep_config_kpc_classes,
        .kpep_config_kpc_count = kpep_config_kpc_count,
        .kpep_config_kpc_map = kpep_config_kpc_map,
        .kpep_config_kpc = kpep_config_kpc,
    };
}

fn candidatesForName(name: []const u8) []const [:0]const u8 {
    assert(name.len > 0);
    assert(name.len < 64);

    if (std.mem.eql(u8, name, "cache-misses")) {
        return &.{
            "L1D_CACHE_MISS_LD_NONSPEC",
            "MEM_LOAD_RETIRED.LLC_MISS",
        };
    }
    if (std.mem.eql(u8, name, "cache-references")) {
        return &.{
            "MEM_LOAD_RETIRED.LLC",
            "L1D_CACHE_LD",
        };
    }
    if (std.mem.eql(u8, name, "branches")) {
        return &.{
            "INST_BRANCH",
            "BR_INST_RETIRED.ALL_BRANCHES",
            "INST_RETIRED.ANY",
        };
    }
    if (std.mem.eql(u8, name, "branch-misses")) {
        return &.{
            "BRANCH_MISPRED_NONSPEC",
            "BRANCH_MISPREDICT",
            "BR_MISP_RETIRED.ALL_BRANCHES",
            "BR_INST_RETIRED.MISPRED",
        };
    }
    return &.{};
}

const cycle_candidates = [_][:0]const u8{
    "FIXED_CYCLES",
    "CPU_CLK_UNHALTED.THREAD",
    "CPU_CLK_UNHALTED.CORE",
};

const instruction_candidates = [_][:0]const u8{
    "FIXED_INSTRUCTIONS",
    "INST_RETIRED.ANY",
};
