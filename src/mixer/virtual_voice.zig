//! TASK-006 Control-only capacity policy. No platform settings are inferred from
//! an ID. This typed sub-artifact is separately admitted, not bank acceptance.
const std = @import("std");
const schema = @import("sme-bank").schema;
pub const max_real = 64;
pub const max_virtual = 256;
pub const max_logical = max_real + max_virtual;
pub const amplitude_one: u32 = 1 << 24;
pub const Error = error{ InvalidVoiceProfile, ProfileMismatch, CapacityOverflow, VoiceBudgetExceeded, InvalidArgument, InvalidState };
pub const State = enum(u8) { real, virtual, releasing, stolen };
pub const Protection = enum(u8) { optional, stinger, dialogue, base };
pub const Reason = enum(u16) { none, below_threshold, real_capacity, virtual_capacity, required_minimum, stinger_capacity, group_capacity, resident_budget, stream_budget, held, late_prepare, stale_ticket, unrealizable };
pub const VoiceCapacityProfile = struct {
    version: u32 = 1,
    id: u64 = 1,
    platform_id: u64 = 1,
    platform_hash: [32]u8,
    sample_rate: u32 = 48_000,
    max_real_voices: u16 = 64,
    max_virtual_voices: u16 = 256,
    max_groups: u16 = 64,
    max_stingers: u16 = 8,
    /// Whole active runtime resident payload, including reserved emergency PCM.
    resident_budget_bytes: u64 = 64 * 1024 * 1024,
    /// Entire attached Service reservation, including old/new rings and jobs.
    stream_budget_bytes: u64 = 192 * 1024 * 1024,
    /// This is the per-segment storage threshold, not resident_budget_bytes.
    segment_resident_limit_bytes: u64 = 16 * 1024 * 1024,
    /// Integer linear-amplitude Q8.24. A rational one-pole step over accepted
    /// Control frame intervals; tau 50 ms, clamped to tau for long intervals.
    audibility_window_frames: u32 = 2400,
    virtualize_threshold_q24: u32 = 16_777,
    realize_threshold_q24: u32 = 66_790,
    hysteresis_q24: u32 = 50_013,
    minimum_hold_frames: u32 = 4800,
    realize_lead_frames: u32 = 2048,
    release_frames: u32 = 32,
    /// Fixed policy array payload only; host Control/Render storage is separate.
    allocation_budget_bytes: u64 = 1024 * 1024,
    pub fn validate(self: VoiceCapacityProfile) Error!void {
        if (self.version != 1 or self.id == 0 or self.platform_id == 0 or zero(self.platform_hash) or self.sample_rate != 48_000 or self.max_real_voices == 0 or self.max_real_voices > max_real or self.max_virtual_voices > max_virtual or self.max_groups == 0 or self.max_groups > 64 or self.max_stingers > self.max_real_voices or self.resident_budget_bytes == 0 or self.resident_budget_bytes > 1024 * 1024 * 1024 or self.stream_budget_bytes == 0 or self.stream_budget_bytes > 256 * 1024 * 1024 or self.segment_resident_limit_bytes == 0 or self.segment_resident_limit_bytes > self.resident_budget_bytes or self.audibility_window_frames == 0 or self.audibility_window_frames > self.sample_rate * 10 or self.realize_threshold_q24 > amplitude_one or self.realize_threshold_q24 <= self.virtualize_threshold_q24 or self.hysteresis_q24 != self.realize_threshold_q24 - self.virtualize_threshold_q24 or self.minimum_hold_frames < self.audibility_window_frames or self.minimum_hold_frames > self.sample_rate * 60 or self.realize_lead_frames == 0 or self.realize_lead_frames > self.sample_rate * 10 or self.release_frames == 0 or self.release_frames > self.minimum_hold_frames or self.allocation_budget_bytes == 0 or self.allocation_budget_bytes > 16 * 1024 * 1024) return error.InvalidVoiceProfile;
        if (try self.policyBytes() > self.allocation_budget_bytes) return error.InvalidVoiceProfile;
    }
    pub fn policyBytes(self: VoiceCapacityProfile) Error!usize {
        _ = self;
        const count: usize = max_logical;
        return std.math.mul(usize, count, @sizeOf(Candidate) + @sizeOf(Decision) + @sizeOf(usize)) catch error.CapacityOverflow;
    }
    pub fn hash(self: VoiceCapacityProfile) [32]u8 {
        var h = std.crypto.hash.sha2.Sha256.init(.{});
        h.update("BUGU-VOICE-CAPACITY-V1");
        inline for (@typeInfo(VoiceCapacityProfile).@"struct".fields) |field| {
            const value = @field(self, field.name);
            if (@TypeOf(value) == [32]u8) h.update(&value) else hashInt(&h, value);
        }
        return h.finalResult();
    }
};
pub const Admission = struct { platform: schema.Platform, voice: VoiceCapacityProfile, hash: [32]u8 };
pub fn platformHash(platform: schema.Platform) [32]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update("BUGU-VOICE-PLATFORM-BINDING-V1");
    hashInt(&h, platform.key.id);
    hashInt(&h, platform.key.name);
    inline for (@typeInfo(schema.Platform).@"struct".fields) |field| {
        if (comptime !std.mem.eql(u8, field.name, "key") and !std.mem.eql(u8, field.name, "profile_hash")) hashInt(&h, @field(platform, field.name));
    }
    return h.finalResult();
}
pub fn admitWithPlatform(actual: schema.Platform, voice: ?VoiceCapacityProfile) Error!Admission {
    const p = voice orelse return error.ProfileMismatch;
    try p.validate();
    if (actual.key.id == 0 or actual.key.id != p.platform_id or !std.mem.eql(u8, &p.platform_hash, &platformHash(actual)) or !std.mem.eql(u8, &actual.profile_hash, &p.platform_hash)) return error.ProfileMismatch;
    if (actual.resident_limit_bytes != p.segment_resident_limit_bytes or actual.resident_limit_bytes > schema.Limits.resident_bytes or actual.max_bank_bytes == 0 or actual.max_bank_bytes > schema.Limits.bank_bytes or actual.max_blob_bytes == 0 or actual.max_blob_bytes > actual.max_bank_bytes or actual.max_blob_bytes > schema.Limits.blob_bytes or actual.max_chunk_bytes == 0 or actual.max_chunk_bytes > actual.max_blob_bytes or actual.max_chunk_bytes > schema.Limits.chunk_bytes or actual.max_table_records == 0 or actual.max_table_records > schema.Limits.records or actual.max_grid_entries == 0 or actual.max_grid_entries > 16_777_216 or actual.max_tempo_spans == 0 or actual.max_tempo_spans > schema.Limits.records or actual.max_logic_instructions == 0 or actual.max_logic_instructions > schema.Limits.logic_instructions or actual.max_logic_stack == 0 or actual.max_logic_stack > schema.Limits.logic_stack or actual.max_planner_phases == 0 or actual.max_planner_phases > schema.Limits.planner_phases or actual.max_planner_candidates == 0 or actual.max_planner_candidates > schema.Limits.planner_candidates) return error.InvalidVoiceProfile;
    _ = std.math.mul(usize, actual.max_grid_entries, 32) catch return error.CapacityOverflow;
    return .{ .platform = actual, .voice = p, .hash = p.hash() };
}
pub fn releasePlatform() schema.Platform {
    var p: schema.Platform = .{ .key = .{ .id = 1 } };
    p.profile_hash = platformHash(p);
    return p;
}
pub fn releaseProfile() VoiceCapacityProfile {
    return .{ .platform_hash = releasePlatform().profile_hash };
}
fn zero(hash: [32]u8) bool {
    for (hash) |b| if (b != 0) return false;
    return true;
}
fn hashInt(h: anytype, v: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, v, .little);
    h.update(&bytes);
}

pub const Authored = struct { layer_id: u64 = 0, protection: Protection = .optional, priority: u16 = 0, drop_rank: u16 = 0 };
pub const Audibility = struct {
    value_q24: u32 = 0,
    frame: u64 = 0,
    initialized: bool = false,
    /// Gain inputs are finite linear amplitude in [0,4]; envelope in [0,1].
    /// Authored priority is deliberately a separate earlier ranking dimension.
    pub fn sample(self: *Audibility, profile: VoiceCapacityProfile, frame: u64, layer_gain: f32, group_gain: f32, bus_gain: f32, envelope: f32) Error!u32 {
        try profile.validate();
        inline for (.{ layer_gain, group_gain, bus_gain, envelope }) |v| if (!std.math.isFinite(v) or v < 0 or v > 4) return error.InvalidArgument;
        if (envelope > 1 or (self.initialized and frame < self.frame)) return error.InvalidArgument;
        const value: f64 = @as(f64, layer_gain) * group_gain * bus_gain * envelope * amplitude_one;
        const target: u32 = @intFromFloat(@min(value, std.math.maxInt(u32)));
        if (!self.initialized) {
            self.value_q24 = target;
            self.initialized = true;
        } else {
            const delta = @min(frame - self.frame, profile.audibility_window_frames);
            self.value_q24 = @intCast((@as(u64, self.value_q24) * (profile.audibility_window_frames - delta) + @as(u64, target) * delta) / profile.audibility_window_frames);
        }
        self.frame = frame;
        return self.value_q24;
    }
};
pub const Candidate = struct { authored: Authored, instance_id: u64 = 0, state: State, audibility_q24: u32, last_change_frame: u64 = 0, required: bool = false };
pub const Decision = struct { layer_id: u64, instance_id: u64 = 0, from: State, to: State, reason: Reason, required: u32 = 0, available: u32 = 0 };
pub const Plan = struct { decisions: [max_logical]Decision = undefined, count: usize = 0, real: u16 = 0, virtual: u16 = 0, failure: ?Decision = null };
/// Retention order: protection DESC, authored priority DESC, audibility DESC,
/// drop_rank ASC (large rank drops first), stable layer ID ASC.
pub fn stronger(_: void, a: Candidate, b: Candidate) bool {
    if (a.authored.protection != b.authored.protection) return @intFromEnum(a.authored.protection) > @intFromEnum(b.authored.protection);
    if (a.authored.priority != b.authored.priority) return a.authored.priority > b.authored.priority;
    if (a.audibility_q24 != b.audibility_q24) return a.audibility_q24 > b.audibility_q24;
    if (a.authored.drop_rank != b.authored.drop_rank) return a.authored.drop_rank < b.authored.drop_rank;
    if (a.authored.layer_id != b.authored.layer_id) return a.authored.layer_id < b.authored.layer_id;
    return a.instance_id < b.instance_id;
}
pub fn plan(profile: VoiceCapacityProfile, frame: u64, candidates: []const Candidate, occupied_other_real: u16) Error!Plan {
    try profile.validate();
    if (candidates.len > max_logical or occupied_other_real > profile.max_real_voices) return error.VoiceBudgetExceeded;
    var ordered: [max_logical]Candidate = undefined;
    @memcpy(ordered[0..candidates.len], candidates);
    for (candidates, 0..) |v, i| {
        if (v.state == .stolen and (v.required or v.authored.protection != .optional)) return error.InvalidState;
        if (v.authored.layer_id == 0 or v.last_change_frame > frame or v.audibility_q24 > 64 * amplitude_one) return error.InvalidArgument;
        for (candidates[0..i]) |prior| if (prior.authored.layer_id == v.authored.layer_id and prior.instance_id == v.instance_id) return error.InvalidArgument;
    }
    std.mem.sort(Candidate, ordered[0..candidates.len], {}, stronger);
    var result: Plan = .{};
    var stingers: u16 = 0;
    // Protected and already-releasing/held-real layers cannot be stolen.
    var reserved: u16 = occupied_other_real;
    for (ordered[0..candidates.len]) |v| if (v.state != .stolen and (v.required or v.authored.protection != .optional or v.state == .releasing or (v.state == .real and frame - v.last_change_frame < profile.minimum_hold_frames))) {
        reserved += 1;
        if (v.authored.protection == .stinger) stingers += 1;
    };
    if (reserved > profile.max_real_voices or stingers > profile.max_stingers) {
        result.failure = .{ .layer_id = 0, .from = .real, .to = .real, .reason = if (stingers > profile.max_stingers) .stinger_capacity else .required_minimum, .required = if (stingers > profile.max_stingers) stingers else reserved, .available = if (stingers > profile.max_stingers) profile.max_stingers else profile.max_real_voices };
        return result;
    }
    result.real = reserved - occupied_other_real;
    for (ordered[0..candidates.len]) |v| {
        if (v.state == .stolen) continue;
        const held = frame - v.last_change_frame < profile.minimum_hold_frames;
        var d: Decision = .{ .layer_id = v.authored.layer_id, .instance_id = v.instance_id, .from = v.state, .to = v.state, .reason = .none };
        const mandatory = v.required or v.authored.protection != .optional or v.state == .releasing or (v.state == .real and held);
        if (mandatory) {
            d.to = if (v.state == .releasing) .releasing else .real;
            d.reason = if (held) .held else .none;
        } else {
            const threshold = if (v.state == .real) profile.virtualize_threshold_q24 else profile.realize_threshold_q24;
            if ((!held or v.state == .real) and v.audibility_q24 >= threshold and occupied_other_real + result.real < profile.max_real_voices) {
                d.to = .real;
                result.real += 1;
            } else {
                d.to = .virtual;
                d.reason = if (held) .held else if (v.audibility_q24 < threshold) .below_threshold else .real_capacity;
            }
        }
        if (d.to == .virtual) {
            if (result.virtual == profile.max_virtual_voices) {
                d.to = .stolen;
                d.reason = .virtual_capacity;
                d.required = result.virtual + 1;
                d.available = profile.max_virtual_voices;
            } else result.virtual += 1;
        }
        result.decisions[result.count] = d;
        result.count += 1;
    }
    return result;
}

pub const Coordinate = struct { cursor: u64, loop_epoch: u64 };
pub const Loop = struct { start: u64, end: u64 };
pub fn predict(cursor: u64, loop_epoch: u64, frames: u64, loop: ?Loop, delta: u64) Error!Coordinate {
    if (cursor >= frames) return error.InvalidArgument;
    if (loop) |l| {
        if (l.start >= l.end or l.end > frames or cursor >= l.end) return error.InvalidArgument;
        const tail = l.end - cursor;
        if (delta < tail) return .{ .cursor = cursor + delta, .loop_epoch = loop_epoch };
        const remaining = delta - tail;
        const epochs = std.math.add(u64, remaining / (l.end - l.start), 1) catch return error.CapacityOverflow;
        return .{ .cursor = l.start + remaining % (l.end - l.start), .loop_epoch = std.math.add(u64, loop_epoch, epochs) catch return error.CapacityOverflow };
    }
    const next = std.math.add(u64, cursor, delta) catch return error.CapacityOverflow;
    if (next >= frames) return error.InvalidState;
    return .{ .cursor = next, .loop_epoch = loop_epoch };
}
pub const Ticket = struct { generation: u64, group: u64, layer: u64, mutation_epoch: u64, transport_epoch: u64, loop_epoch: u64, cursor: u64, realize_frame: u64 };
