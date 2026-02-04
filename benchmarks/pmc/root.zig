const builtin = @import("builtin");

const macos = @import("macos.zig");

pub const Pmc = if (builtin.os.tag == .macos) macos.Pmc else NoPmc;

pub const Result = struct {
    cycles: ?u64,
    instructions: ?u64,
    cache_misses: ?u64,
    cache_references: ?u64,
    branches: ?u64,
    branch_misses: ?u64,

    pub const empty = Result{
        .cycles = null,
        .instructions = null,
        .cache_misses = null,
        .cache_references = null,
        .branches = null,
        .branch_misses = null,
    };

    pub fn subtract(self: Result, other: Result) Result {
        var result = self;

        if (other.cycles) |other_cycles| {
            if (self.cycles) |self_cycles| {
                result.cycles = self_cycles -% other_cycles;
            }
        }
        if (other.instructions) |other_instructions| {
            if (self.instructions) |self_instructions| {
                result.instructions = self_instructions -% other_instructions;
            }
        }
        if (other.cache_misses) |other_cache_misses| {
            if (self.cache_misses) |self_cache_misses| {
                result.cache_misses = self_cache_misses -% other_cache_misses;
            }
        }
        if (other.cache_references) |other_cache_references| {
            if (self.cache_references) |self_cache_references| {
                result.cache_references = self_cache_references -% other_cache_references;
            }
        }
        if (other.branches) |other_branches| {
            if (self.branches) |self_branches| {
                result.branches = self_branches -% other_branches;
            }
        }
        if (other.branch_misses) |other_branch_misses| {
            if (self.branch_misses) |self_branch_misses| {
                result.branch_misses = self_branch_misses -% other_branch_misses;
            }
        }
        return result;
    }
};

const NoPmc = struct {
    enabled: bool,

    pub fn init(enable: bool) NoPmc {
        return .{ .enabled = enable };
    }

    pub fn deinit(self: *NoPmc) void {
        _ = self;
    }

    pub fn start(self: *NoPmc) bool {
        _ = self;
        return false;
    }

    pub fn reset(self: *NoPmc) error{Failed}!void {
        _ = self;
    }

    pub fn read(self: *NoPmc) error{Failed}!Result {
        _ = self;
        return .empty;
    }

    pub fn lap(self: *NoPmc) error{Failed}!Result {
        return self.read();
    }
};
