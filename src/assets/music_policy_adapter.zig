//! TASK015 control-owned policy consumer. No scheduler, trace, or runtime owner.
const std = @import("std");
const s = @import("music_schema.zig");
pub const types = @import("sme-policy-types");
const sidechain = @import("sme-sidechain");
pub const fields = .{ "policy_configs", "stinger_policies", "acoustic_policy_profiles", "acoustic_policy_inputs", "automation_duck_presets" };
pub fn stingerPolicy(row: s.StingerPolicy, tables: s.Tables) s.BankError!types.stinger.Policy {
    if (row.protected > 1) return error.InvalidRecord;
    if (row.duck_preset != s.none and row.duck_preset >= tables.automation_duck_presets.len) return error.InvalidReference;
    return .{ .version = row.version, .max_polyphony = row.max_polyphony, .repeat_frames = row.repeat_frames, .deadline_frames = row.deadline_frames, .sync = @enumFromInt(@intFromEnum(row.sync)), .conflict = @enumFromInt(@intFromEnum(row.conflict)), .priority = row.priority, .protected = row.protected == 1, .duck_preset = if (row.duck_preset == s.none) null else tables.automation_duck_presets[row.duck_preset].key.id };
}
pub fn acousticPolicy(row: s.AcousticPolicyInput) types.acoustic.Policy {
    return .{ .version = row.version, .minimum_q16 = row.minimum_q16, .maximum_q16 = row.maximum_q16, .neutral_q16 = row.neutral_q16, .attack_frames = row.attack_frames, .release_frames = row.release_frames, .rate_per_second_q16 = row.rate_per_second_q16, .quantize_intervals = row.quantize_intervals, .stale_frames = row.stale_frames, .missing = @enumFromInt(@intFromEnum(row.missing)) };
}
/// The caller supplies its actually allocated duck request ID. This constructs a
/// value only, and never submits begin_duck or creates a request identity.
pub fn duckTarget(row: s.AutomationDuckPreset, request_id: u32) s.BankError!sidechain.DuckAutomationTarget {
    if (request_id == 0 or row.version != 1) return error.InvalidRecord;
    const target: sidechain.DuckAutomationTarget = .{ .id = request_id, .reduction_db = row.reduction_db, .priority = row.priority, .authored_order = row.authored_order, .attack_frames = row.attack_frames, .hold_frames = row.hold_frames, .release_frames = row.release_frames };
    target.validate() catch return error.InvalidRecord;
    return target;
}
pub fn validate(metadata: s.Metadata, t: s.Tables) s.BankError!void {
    if (metadata.optional_capabilities & s.bit(.music_policy_v1) != 0) return error.InvalidCapabilityDeclaration;
    if (!s.policyEnabled(metadata)) {
        inline for (fields) |field| if (@field(t, field).len != 0) return error.InvalidCapabilityDeclaration;
        return;
    }
    inline for (fields) |field| if (@field(t, field).len > s.countLimit(@field(s.Table, field))) return error.ResourceLimitExceeded;
    if (t.policy_configs.len != 1) return error.MissingRequiredTable;
    if (metadata.generation == 0) return error.InvalidGeneration;
    inline for (.{ "stinger_policies", "acoustic_policy_profiles", "automation_duck_presets" }) |field| {
        const rows = @field(t, field);
        for (rows, 0..) |row, i| {
            if (row.key.id == 0) return error.InvalidRecord;
            for (rows[0..i]) |prior| if (row.key.id == prior.key.id) return error.IdCollision;
        }
    }
    const config = t.policy_configs[0];
    if (config.version != 1) return error.InvalidRecord;
    if (config.sample_rate_hz != s.sample_rate) return error.InvalidSampleRate;
    if (config.platform != metadata.profile or config.platform >= t.platforms.len) return error.InvalidReference;
    if (config.max_stingers == 0 or config.max_stingers > types.stinger.hard_max_stingers) return error.InvalidRecord;
    for (t.stinger_policies) |row| {
        if (row.segment >= t.segments.len or row.cue >= t.cues.len) return error.InvalidReference;
        if (t.cues[row.cue].segment != row.segment or t.cues[row.cue].kind != .stinger) return error.InvalidReference;
        if (row.provenance[0] != .release) return error.InvalidRecord;
        const policy = try stingerPolicy(row, t);
        policy.validate(config.max_stingers) catch return error.InvalidRecord;
    }
    var next: u64 = 0;
    for (t.acoustic_policy_profiles, 0..) |profile, index| {
        if (profile.version != 1 or profile.inputs.count == 0 or profile.inputs.count > 3) return error.InvalidRecord;
        if (profile.inputs.first != next or next + profile.inputs.count > t.acoustic_policy_inputs.len) return error.InvalidReference;
        var seen: u8 = 0;
        const rows = t.acoustic_policy_inputs[profile.inputs.first..][0..profile.inputs.count];
        for (rows, 0..) |row, i| {
            if (row.profile != index or row.parameter >= t.parameters.len) return error.InvalidReference;
            const parameter = t.parameters[row.parameter];
            if (parameter.key.id == 0 or parameter.minimum != 0 or parameter.maximum != 1) return error.InvalidRecord;
            const bit = @as(u8, 1) << @intCast(@intFromEnum(row.input));
            if (seen & bit != 0 or row.provenance[0] != .release) return error.InvalidRecord;
            for (rows[0..i]) |prior| if (prior.parameter == row.parameter) return error.InvalidReference;
            seen |= bit;
            acousticPolicy(row).validate() catch return error.InvalidRecord;
        }
        next += profile.inputs.count;
    }
    if (next != t.acoustic_policy_inputs.len) return error.InvalidReference;
    for (t.automation_duck_presets) |row| {
        if (row.bus >= t.buses.len) return error.InvalidReference;
        // Validation requires a nonzero placeholder only; no runtime ID is stored.
        _ = try duckTarget(row, 1);
    }
}
pub const Stinger = struct { id: u64, segment: u32, cue: u32, policy: types.stinger.Policy };
pub const Acoustic = struct { profile_id: u64, parameter_id: u64, input: types.acoustic.Input, policy: types.acoustic.Policy };
/// Numeric values are owned independently of the bank. Init/deinit are control-
/// only; future runtime integration must separately budget and admit real work.
pub const Owned = struct {
    allocator: std.mem.Allocator,
    generation: u64,
    sample_rate: u32,
    max_stingers: u16,
    stingers: []Stinger,
    acoustics: []Acoustic,
    ducks: []s.AutomationDuckPreset,
    pub fn init(allocator: std.mem.Allocator, metadata: s.Metadata, tables: s.Tables, active_context_sample_rate: u32) !Owned {
        try validate(metadata, tables);
        if (!s.policyEnabled(metadata)) return error.UnsupportedCapability;
        const config = tables.policy_configs[0];
        if (active_context_sample_rate != config.sample_rate_hz) return error.InvalidSampleRate;
        const stingers = try allocator.alloc(Stinger, tables.stinger_policies.len);
        errdefer allocator.free(stingers);
        const acoustics = try allocator.alloc(Acoustic, tables.acoustic_policy_inputs.len);
        errdefer allocator.free(acoustics);
        const ducks = try allocator.dupe(s.AutomationDuckPreset, tables.automation_duck_presets);
        errdefer allocator.free(ducks);
        for (tables.stinger_policies, stingers) |row, *entry| entry.* = .{ .id = row.key.id, .segment = row.segment, .cue = row.cue, .policy = try stingerPolicy(row, tables) };
        for (tables.acoustic_policy_inputs, acoustics) |row, *entry| entry.* = .{ .profile_id = tables.acoustic_policy_profiles[row.profile].key.id, .parameter_id = tables.parameters[row.parameter].key.id, .input = @enumFromInt(@intFromEnum(row.input)), .policy = acousticPolicy(row) };
        return .{ .allocator = allocator, .generation = metadata.generation, .sample_rate = config.sample_rate_hz, .max_stingers = config.max_stingers, .stingers = stingers, .acoustics = acoustics, .ducks = ducks };
    }
    pub fn deinit(self: *Owned) void {
        self.allocator.free(self.stingers);
        self.allocator.free(self.acoustics);
        self.allocator.free(self.ducks);
        self.* = undefined;
    }
};
