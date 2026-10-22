//! Typed-only authoring handoff and mandatory source-bound recomputation.
//! No parser, media callback or runtime dependency.
const std = @import("std");
const bank = @import("sme-bank");
const s = bank.schema;
pub const defaults = @import("sme-acoustic-policy-compiler");
const adapter = bank.music_policy_adapter;
pub const Error = s.BankError || std.mem.Allocator.Error;
pub const Stinger = struct { key: s.Named, segment: u32, cue: u32, overrides: defaults.StingerOverride = .{} };
pub const Input = struct { parameter: u32, kind: s.AcousticInputKind, overrides: defaults.AcousticOverride = .{} };
pub const Profile = struct { key: s.Named, inputs: []const Input };
pub const Duck = struct { key: s.Named, bus: u32, reduction_db: f32, priority: i16, authored_order: u32, attack_frames: u32, hold_frames: u32, release_frames: u32 };
pub const Source = struct {
    version: u16 = 1,
    sample_rate: u32,
    platform: defaults.Overrides = .{},
    max_stingers: ?u16 = null,
    stingers: []const Stinger = &.{},
    profiles: []const Profile = &.{},
    ducks: []const Duck = &.{},
};
/// Allocator must be the SourceAST arena. Input slices are deeply copied.
pub fn clone(allocator: std.mem.Allocator, source: Source) Error!Source {
    try bound(source);
    var result = source;
    result.stingers = try allocator.dupe(Stinger, source.stingers);
    const profiles = try allocator.dupe(Profile, source.profiles);
    for (profiles) |*profile| profile.inputs = try allocator.dupe(Input, profile.inputs);
    result.profiles = profiles;
    result.ducks = try allocator.dupe(Duck, source.ducks);
    return result;
}
fn bound(source: Source) Error!void {
    if (source.version != 1) return error.InvalidRecord;
    if (source.sample_rate != s.sample_rate) return error.InvalidSampleRate;
    if (source.stingers.len > 512 or source.profiles.len > 128 or source.ducks.len > 64) return error.ResourceLimitExceeded;
    for (source.profiles) |profile| if (profile.inputs.len == 0 or profile.inputs.len > 3) return error.InvalidRecord;
}
fn origins(comptime count: usize, input: [count]defaults.Origin) [count]s.PolicyOrigin {
    var out: [count]s.PolicyOrigin = undefined;
    for (input, &out) |value, *slot| slot.* = @enumFromInt(@intFromEnum(value));
    return out;
}
/// The same five resolved records form the owned numeric compiler report.
/// This type does not own memory itself; clone/free specify the report lifetime.
pub const Report = struct {
    policy_configs: []const s.PolicyConfig = &.{},
    stinger_policies: []const s.StingerPolicy = &.{},
    acoustic_policy_profiles: []const s.AcousticPolicyProfile = &.{},
    acoustic_policy_inputs: []const s.AcousticPolicyInput = &.{},
    automation_duck_presets: []const s.AutomationDuckPreset = &.{},
    pub fn copy(allocator: std.mem.Allocator, tables: s.Tables) std.mem.Allocator.Error!Report {
        var result: Report = .{};
        errdefer result.deinit(allocator);
        inline for (adapter.fields) |field| @field(result, field) = try allocator.dupe(std.meta.Child(@FieldType(s.Tables, field)), @field(tables, field));
        return result;
    }
    pub fn deinit(self: *Report, allocator: std.mem.Allocator) void {
        inline for (adapter.fields) |field| allocator.free(@field(self, field));
        self.* = .{};
    }
    pub fn apply(self: Report, tables: *s.Tables) void {
        inline for (adapter.fields) |field| @field(tables, field) = @field(self, field);
    }
};
/// Allocations belong to the caller's arena. All fields are deterministically
/// resolved from typed authoring, using the qualified release resolver.
pub fn resolve(allocator: std.mem.Allocator, source: Source, metadata: s.Metadata, base: s.Tables) Error!Report {
    try bound(source);
    if (!s.policyEnabled(metadata)) return error.InvalidCapabilityDeclaration;
    const global = defaults.selectMaxStingers(source.platform.max_stingers, source.max_stingers);
    const configs = try allocator.alloc(s.PolicyConfig, 1);
    configs[0] = .{ .platform = metadata.profile, .sample_rate_hz = source.sample_rate, .max_stingers = global.value, .origin = @enumFromInt(@intFromEnum(global.origin)) };
    const ducks = try allocator.alloc(s.AutomationDuckPreset, source.ducks.len);
    for (source.ducks, ducks) |authored, *row| row.* = .{ .key = authored.key, .bus = authored.bus, .reduction_db = authored.reduction_db, .priority = authored.priority, .authored_order = authored.authored_order, .attack_frames = authored.attack_frames, .hold_frames = authored.hold_frames, .release_frames = authored.release_frames };
    const stingers = try allocator.alloc(s.StingerPolicy, source.stingers.len);
    for (source.stingers, stingers) |authored, *row| {
        const result = defaults.compileStinger(source.sample_rate, global.value, source.platform.stinger, authored.overrides) catch return error.InvalidRecord;
        const policy = result.value;
        var duck: u32 = s.none;
        if (policy.duck_preset) |id| {
            for (ducks, 0..) |preset, i| if (preset.key.id == id) {
                duck = @intCast(i);
                break;
            };
            if (duck == s.none) return error.InvalidReference;
        }
        row.* = .{ .key = authored.key, .segment = authored.segment, .cue = authored.cue, .version = policy.version, .max_polyphony = policy.max_polyphony, .repeat_frames = policy.repeat_frames, .deadline_frames = policy.deadline_frames, .sync = @enumFromInt(@intFromEnum(policy.sync)), .conflict = @enumFromInt(@intFromEnum(policy.conflict)), .priority = policy.priority, .protected = @intFromBool(policy.protected), .duck_preset = duck, .provenance = origins(9, result.provenance) };
    }
    const profiles = try allocator.alloc(s.AcousticPolicyProfile, source.profiles.len);
    var total: usize = 0;
    for (source.profiles) |profile| total += profile.inputs.len;
    const inputs = try allocator.alloc(s.AcousticPolicyInput, total);
    var next: usize = 0;
    for (source.profiles, profiles, 0..) |authored, *profile, index| {
        profile.* = .{ .key = authored.key, .inputs = .{ .first = @intCast(next), .count = @intCast(authored.inputs.len) } };
        for (authored.inputs) |input| {
            const report = defaults.compileAcoustic(source.sample_rate, source.platform.inputs[@intFromEnum(input.kind)], input.overrides) catch return error.InvalidRecord;
            const p = report.value;
            inputs[next] = .{ .profile = @intCast(index), .parameter = input.parameter, .input = input.kind, .version = p.version, .minimum_q16 = p.minimum_q16, .maximum_q16 = p.maximum_q16, .neutral_q16 = p.neutral_q16, .attack_frames = p.attack_frames, .release_frames = p.release_frames, .rate_per_second_q16 = p.rate_per_second_q16, .quantize_intervals = p.quantize_intervals, .stale_frames = p.stale_frames, .missing = @enumFromInt(@intFromEnum(p.missing)), .provenance = origins(10, report.provenance) };
            next += 1;
        }
    }
    const result: Report = .{ .policy_configs = configs, .stinger_policies = stingers, .acoustic_policy_profiles = profiles, .acoustic_policy_inputs = inputs, .automation_duck_presets = ducks };
    var tables = base;
    result.apply(&tables);
    try adapter.validate(metadata, tables);
    return result;
}
/// No generated input rows are accepted as authority, even from typed ASTs.
pub fn validateHandoff(metadata: s.Metadata, tables: s.Tables, source: ?Source) Error!void {
    inline for (adapter.fields) |field| if (@field(tables, field).len != 0) return error.InvalidSource;
    if (s.policyEnabled(metadata) != (source != null)) return error.InvalidSource;
    if (source) |value| try bound(value);
}
fn sameReference(comptime field: []const u8, index: u32, before: s.Tables, after: s.Tables) Error!void {
    const a = @field(before, field);
    const b = @field(after, field);
    if (index >= a.len or index >= b.len or !std.meta.eql(a[index].key, b[index].key)) return error.InvalidReference;
}
pub fn validateProduced(allocator: std.mem.Allocator, source: ?Source, metadata: s.Metadata, authored: s.Tables, ir: s.ValidatedIR) Error!void {
    try validateHandoff(metadata, authored, source);
    if (source) |value| {
        if (!std.meta.eql(metadata, ir.metadata)) return error.InvalidSource;
        try sameReference("platforms", metadata.profile, authored, ir.tables);
        for (value.stingers) |row| {
            try sameReference("segments", row.segment, authored, ir.tables);
            try sameReference("cues", row.cue, authored, ir.tables);
        }
        for (value.profiles) |row| for (row.inputs) |input| try sameReference("parameters", input.parameter, authored, ir.tables);
        for (value.ducks) |row| try sameReference("buses", row.bus, authored, ir.tables);
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const expected = try resolve(arena.allocator(), value, metadata, ir.tables);
        inline for (adapter.fields) |field| {
            const actual = @field(ir.tables, field);
            const wanted = @field(expected, field);
            if (actual.len != wanted.len) return error.InvalidRecord;
            for (actual, wanted) |a, b| if (!std.meta.eql(a, b)) return error.InvalidRecord;
        }
    } else {
        if (s.policyEnabled(ir.metadata)) return error.InvalidSource;
        try adapter.validate(ir.metadata, ir.tables);
    }
}
