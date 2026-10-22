//! Pure bounded TASK-016 retention preflight over caller-owned facts. A plan
//! reserves nothing, releases nothing and cannot publish/activate a generation.
//! The future owner must serialize snapshot/plan/reservation/publication and
//! recheck every lease at actual eviction. Never use this module on Render.
const std = @import("std");
const music = @import("music");
const wire = @import("generation_wire.zig");
pub const version: u16 = 1;
/// Safety ceiling for this value contract, not a platform profile default.
pub const max_history_capacity: u32 = 64;
pub const max_snapshot_generations: usize = max_history_capacity + 1;
pub const Error = wire.Error || error{
    InvalidProfile, InvalidIdentity, DuplicateGeneration, NonMonotonicGeneration,
    InvalidSnapshot, ArithmeticOverflow, HistoryCapacityExceeded,
    ByteCapacityExceeded, LeaseCapacityExceeded,
};
pub const EvictionOrder = enum(u16) { oldest_generation_first = 1, _ };
pub const GenerationRetentionProfile = struct {
    schema_version: u16 = version,
    /// Old generations after commit, excluding the new active generation.
    history_capacity: u32,
    /// Protect this many newest old generations, up to available history,
    /// including the former active. Zero explicitly disables rollback reserve.
    rollback_retention: u32,
    /// Include active, candidate and every surviving old generation exactly once.
    max_retained_bytes: u64,
    max_retained_leases: u64,
    eviction_order: EvictionOrder = .oldest_generation_first,

    pub fn validate(self: GenerationRetentionProfile) Error!void {
        if (self.schema_version != version) return error.UnknownVersion;
        if (self.history_capacity > max_history_capacity or self.rollback_retention > self.history_capacity or
            self.max_retained_bytes == 0 or self.max_retained_leases == 0 or self.eviction_order != .oldest_generation_first) return error.InvalidProfile;
    }
    pub fn encode(self: GenerationRetentionProfile) Error![wire.header_bytes]u8 {
        try self.validate();
        var bytes: [wire.header_bytes]u8 = @splat(0);
        @memcpy(bytes[0..8], "BUGURET1");
        wire.put(&bytes, 8, version);
        wire.put(&bytes, 12, @as(u32, wire.header_bytes));
        wire.put(&bytes, 16, self.history_capacity);
        wire.put(&bytes, 20, self.rollback_retention);
        wire.put(&bytes, 24, self.max_retained_bytes);
        wire.put(&bytes, 32, self.max_retained_leases);
        wire.put(&bytes, 40, @intFromEnum(self.eviction_order));
        wire.finish(&bytes);
        return bytes;
    }
    pub fn contentHash(self: GenerationRetentionProfile) Error!wire.Hash {
        const bytes = try self.encode();
        return bytes[wire.hash_offset..][0..32].*;
    }
    pub fn decode(bytes: []const u8) Error!GenerationRetentionProfile {
        try wire.check(bytes, "BUGURET1", wire.header_bytes);
        if (!std.mem.allEqual(u8, bytes[10..12], 0) or !std.mem.allEqual(u8, bytes[42..48], 0)) return error.NonCanonicalEncoding;
        const result = GenerationRetentionProfile{
            .history_capacity = wire.get(bytes, 16, u32), .rollback_retention = wire.get(bytes, 20, u32),
            .max_retained_bytes = wire.get(bytes, 24, u64), .max_retained_leases = wire.get(bytes, 32, u64),
            .eviction_order = @enumFromInt(wire.get(bytes, 40, u16)),
        };
        try result.validate();
        return result;
    }
};
/// Each live ownership unit is counted once in its current category. Transfers
/// move the unit between categories rather than counting it twice. Facts also
/// include reservations held by an in-flight transaction. Byte facts likewise
/// cover all backing storage retained by this generation, not just bank bytes.
pub const LeaseCounts = struct {
    control_plan: u64 = 0,
    published_block: u64 = 0,
    acquired_snapshot_block: u64 = 0,
    playing_virtual_group: u64 = 0,
    voice: u64 = 0,
    stream_job: u64 = 0,
    stream_ring_cache: u64 = 0,
    capture_restore: u64 = 0,
    rollback_history: u64 = 0,
    pending_pcm: u64 = 0,
    pub fn total(self: LeaseCounts) Error!u64 {
        var result: u64 = 0;
        inline for (@typeInfo(LeaseCounts).@"struct".fields) |field| result = try add(result, @field(self, field.name));
        return result;
    }
};
pub const GenerationFacts = struct {
    generation: music.AssetGeneration,
    build_id: u64,
    content_hash: wire.Hash,
    retained_bytes: u64,
    leases: LeaseCounts = .{},
    pub fn validate(self: GenerationFacts) Error!void {
        if (!self.generation.isValid() or self.build_id == 0 or std.mem.allEqual(u8, &self.content_hash, 0) or self.retained_bytes == 0) return error.InvalidIdentity;
        _ = try self.leases.total();
    }
};
pub const Snapshot = struct {
    active_generation: music.AssetGeneration,
    /// Contains the active generation exactly once and only older histories.
    /// Input order is irrelevant; the planner uses monotonic generation IDs.
    generations: []const GenerationFacts,
};
pub const Totals = struct { generations: usize, history: usize, bytes: u64, leases: u64 };
pub const RetentionPlan = struct {
    outcome: enum { same_content, candidate_fits },
    active_generation: music.AssetGeneration,
    candidate_generation: ?music.AssetGeneration,
    eviction_count: usize = 0,
    /// Ordered oldest-first; never includes active or any nonzero-lease entry.
    evictions: [max_snapshot_generations]music.AssetGeneration = @splat(.invalid),
    totals: Totals,
    pub fn evictionSlice(self: *const RetentionPlan) []const music.AssetGeneration { return self.evictions[0..self.eviction_count]; }
};

fn add(a: u64, b: u64) Error!u64 {
    const sum = @addWithOverflow(a, b);
    if (sum[1] != 0) return error.ArithmeticOverflow;
    return sum[0];
}
fn capacity(profile: GenerationRetentionProfile, totals: Totals) Error!void {
    if (totals.history > profile.history_capacity) return error.HistoryCapacityExceeded;
    if (totals.bytes > profile.max_retained_bytes) return error.ByteCapacityExceeded;
    if (totals.leases > profile.max_retained_leases) return error.LeaseCapacityExceeded;
}
/// The snapshot is a committed-generation inventory. In-progress candidates
/// cannot be hidden in it. `candidate` must describe a separate proposed fresh
/// monotonic identity, even when its build/hash reuses a retained rollback bank.
/// Same-content uses no candidate generation or reservations and does not evict.
pub fn plan(profile: GenerationRetentionProfile, snapshot: Snapshot, candidate: GenerationFacts) Error!RetentionPlan {
    try profile.validate();
    try candidate.validate();
    if (!snapshot.active_generation.isValid() or snapshot.generations.len == 0 or snapshot.generations.len > max_snapshot_generations) return error.InvalidSnapshot;
    var active: ?GenerationFacts = null;
    var totals = Totals{ .generations = snapshot.generations.len, .history = snapshot.generations.len - 1, .bytes = 0, .leases = 0 };
    var sorted: [max_snapshot_generations]usize = undefined;
    var lease_totals: [max_snapshot_generations]u64 = undefined;
    for (snapshot.generations, 0..) |entry, i| {
        try entry.validate();
        if (entry.generation.value() > snapshot.active_generation.value()) return error.NonMonotonicGeneration;
        for (snapshot.generations[0..i]) |prior| {
            if (prior.generation == entry.generation) return error.DuplicateGeneration;
            // Repeated build IDs across rollback generations must refer to the
            // same content, and identical content must carry the same build ID.
            if ((prior.build_id == entry.build_id) != std.mem.eql(u8, &prior.content_hash, &entry.content_hash)) return error.InvalidIdentity;
        }
        if (entry.generation == snapshot.active_generation) active = entry;
        sorted[i] = i;
        lease_totals[i] = try entry.leases.total();
        totals.bytes = try add(totals.bytes, entry.retained_bytes);
        totals.leases = try add(totals.leases, lease_totals[i]);
        if ((entry.build_id == candidate.build_id) != std.mem.eql(u8, &entry.content_hash, &candidate.content_hash)) return error.InvalidIdentity;
    }
    const old_active = active orelse return error.InvalidSnapshot;
    if (std.mem.eql(u8, &old_active.content_hash, &candidate.content_hash)) {
        try capacity(profile, totals);
        return .{ .outcome = .same_content, .active_generation = old_active.generation, .candidate_generation = null, .totals = totals };
    }
    if (candidate.generation.value() <= old_active.generation.value()) return error.NonMonotonicGeneration;
    totals.generations += 1;
    totals.history += 1;
    totals.bytes = try add(totals.bytes, candidate.retained_bytes);
    totals.leases = try add(totals.leases, try candidate.leases.total());
    // Evictions can never make leased generations eligible; fail before work.
    if (totals.leases > profile.max_retained_leases) return error.LeaseCapacityExceeded;
    std.mem.sort(usize, sorted[0..snapshot.generations.len], snapshot.generations, struct {
        fn less(entries: []const GenerationFacts, a: usize, b: usize) bool { return entries[a].generation.value() < entries[b].generation.value(); }
    }.less);
    var result = RetentionPlan{ .outcome = .candidate_fits, .active_generation = old_active.generation, .candidate_generation = candidate.generation, .totals = totals };
    const protect_from = snapshot.generations.len - @min(snapshot.generations.len, profile.rollback_retention);
    for (sorted[0..snapshot.generations.len], 0..) |index, rank| {
        if (result.totals.history <= profile.history_capacity and result.totals.bytes <= profile.max_retained_bytes) break;
        const entry = snapshot.generations[index];
        // The prior active is ALWAYS pinned through prepare/activation, even
        // with rollback_retention=0. Reclaiming it is a future post-commit plan.
        if (entry.generation == old_active.generation or rank >= protect_from or lease_totals[index] != 0) continue;
        result.evictions[result.eviction_count] = entry.generation;
        result.eviction_count += 1;
        result.totals.generations -= 1;
        result.totals.history -= 1;
        result.totals.bytes -= entry.retained_bytes;
    }
    try capacity(profile, result.totals);
    return result;
}
