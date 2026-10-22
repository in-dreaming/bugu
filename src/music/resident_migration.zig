//! Control-only bounded resident or explicit streamed ID projection. This owns indices and
//! policies; the transaction retains both immutable banks through the receipt.
const std = @import("std");
const music = @import("music");
const bank = @import("sme-bank");
const s = bank.schema;
const selector = @import("sme-selector");
const admission = @import("sme-generation-admission");
pub const migration = admission.contracts.migration;
pub const policy = admission.policy;
pub const Error = migration.Error || policy.Error || bank.BankError || error{ IncompatibleHistoryPolicy, InvalidMigrationProjection };
/// Pure pre-ingress combination check. Exact hashes/catalogs are still checked
/// after Worker loads the candidate; this never consumes a request/identity.
pub fn validateHistoryPolicies(map: *const migration.MigrationMapV1, rules: *const policy.RuntimeMigrationPolicyV1) Error!void {
    if (map.description.selectors.len > migration.max_entries_per_category or rules.description.entries.len > policy.max_entries) return error.ResourceLimitExceeded;
    if (map.description.history_policy == .reset_explicit) {
        var renamed = false;
        for (map.description.selectors) |pair| renamed = renamed or pair.from != pair.to;
        if (!renamed) return error.IncompatibleHistoryPolicy;
    }
    for (rules.description.entries) |entry| {
        if ((entry.policy == .reset_epoch and map.description.history_policy != .reset_explicit) or (entry.policy == .preserve_epoch and map.description.history_policy != .remap_exact)) return error.IncompatibleHistoryPolicy;
    }
}
const capacity = migration.max_entries_per_category;
const Inventory = struct {
    states: [capacity]music.MusicStateId = undefined,
    segments: [capacity]music.SegmentId = undefined,
    selectors: [capacity]music.SegmentSelectorId = undefined,
    kinds: [capacity]policy.Selector = undefined,
    value: migration.Inventory = .{},
    fn init(self: *Inventory, tables: s.Tables) Error!void {
        if (tables.states.len > capacity or tables.segments.len > capacity or tables.selectors.len > capacity) return error.ResourceLimitExceeded;
        for (tables.states, 0..) |v, i| self.states[i] = @enumFromInt(v.key.id);
        for (tables.segments, 0..) |v, i| self.segments[i] = @enumFromInt(v.key.id);
        for (tables.selectors, 0..) |v, i| {
            self.selectors[i] = @enumFromInt(v.key.id);
            self.kinds[i] = .{ .id = self.selectors[i], .stochastic = switch (v.kind) {
                .weighted_random, .shuffle, .no_repeat => true,
                else => false,
            } };
        }
        self.value = .{ .states = self.states[0..tables.states.len], .segments = self.segments[0..tables.segments.len], .selectors = self.selectors[0..tables.selectors.len] };
    }
};
const Scratch = struct { source: Inventory, target: Inventory };
/// Heap-place this value. Catalog order changes never copy old array indices.
pub const Projection = struct {
    pub const Mode = enum { resident, streaming };
    mode: Mode = .resident,
    source: s.Tables = .{},
    target: s.Tables = .{},
    from_build_id: u64 = 0,
    to_build_id: u64 = 0,
    map_hash: [32]u8 = @splat(0),
    policy_hash: [32]u8 = @splat(0),
    states: [capacity]u32 = undefined,
    segments: [capacity]u32 = undefined,
    selectors: [capacity]u32 = undefined,
    reset: [capacity]bool = @splat(false),
    reset_epoch: [capacity]bool = @splat(false),
    prepared: bool = false,
    consistency_digest: [32]u8 = @splat(0),
    pub fn init(self: *Projection, allocator: std.mem.Allocator, source: s.Tables, target: s.Tables, from_build: u64, to_build: u64, map: *const migration.MigrationMapV1, rules: *const policy.RuntimeMigrationPolicyV1) Error!void {
        return self.initMode(.resident, allocator, source, target, from_build, to_build, map, rules);
    }
    /// Both table sets must belong to separately validated, retained MusicBanks.
    /// Encoded resource indices and container coordinates are not musical IDs.
    /// This proves whole-bank musical equivalence, not four-stem live admission,
    /// provider identity, decoded readiness, or support for any extra profile.
    pub fn initStreaming(self: *Projection, allocator: std.mem.Allocator, source: s.Tables, target: s.Tables, from_build: u64, to_build: u64, map: *const migration.MigrationMapV1, rules: *const policy.RuntimeMigrationPolicyV1) Error!void {
        return self.initMode(.streaming, allocator, source, target, from_build, to_build, map, rules);
    }
    fn initMode(self: *Projection, mode: Mode, allocator: std.mem.Allocator, source: s.Tables, target: s.Tables, from_build: u64, to_build: u64, map: *const migration.MigrationMapV1, rules: *const policy.RuntimeMigrationPolicyV1) Error!void {
        self.prepared = false;
        self.mode = mode;
        self.states = @splat(0);
        self.segments = @splat(0);
        self.selectors = @splat(0);
        self.reset = @splat(false);
        self.reset_epoch = @splat(false);
        const scratch = try allocator.create(Scratch);
        defer allocator.destroy(scratch);
        try scratch.source.init(source);
        try scratch.target.init(target);
        const context: migration.ValidationContext = .{ .from_build_id = from_build, .to_build_id = to_build, .source = scratch.source.value, .target = scratch.target.value, .required = scratch.source.value };
        try map.validateFor(context);
        try rules.validateFor(map, context, .{ .source = scratch.source.kinds[0..source.selectors.len], .target = scratch.target.kinds[0..target.selectors.len] }, null);
        try validateHistoryPolicies(map, rules);
        if (source.states.len != target.states.len or source.segments.len != target.segments.len or source.selectors.len != target.selectors.len) return error.UnsupportedCapability;
        self.source = source;
        self.target = target;
        self.from_build_id = from_build;
        self.to_build_id = to_build;
        self.map_hash = map.content_hash;
        self.policy_hash = rules.content_hash;
        inline for (.{ "states", "segments", "selectors" }) |field| {
            for (@field(source, field), 0..) |row, i| {
                const id = mappedId(@field(map.description, field), row.key.id) orelse return error.MissingRequiredMapping;
                @field(self, field)[i] = try locate(@field(target, field), id);
            }
        }
        for (source.selectors, 0..) |row, i| {
            const renamed = row.key.id != target.selectors[self.selectors[i]].key.id;
            self.reset[i] = false;
            self.reset_epoch[i] = false;
            if (!renamed) continue;
            var epoch: ?policy.EpochPolicy = null;
            for (rules.description.entries) |entry| if (entry.from.value() == row.key.id) {
                epoch = entry.policy;
                break;
            };
            if (epoch) |choice| {
                self.reset_epoch[i] = choice == .reset_epoch;
            }
            self.reset[i] = map.description.history_policy == .reset_explicit;
        }
        try self.validateTopology();
        self.consistency_digest = self.calculateDigest();
        self.prepared = true;
    }
    pub fn validateFor(self: *const Projection, source: s.Tables, target: s.Tables, from_build: u64, to_build: u64) Error!void {
        if (self.from_build_id != from_build or self.to_build_id != to_build) return error.InvalidMigrationProjection;
        // Compare to the caller's actual retained banks before dereferencing any
        // stored binding. The seal itself only reads owned fixed-size fields.
        inline for (std.meta.fields(s.Tables)) |field| {
            const old = @field(source, field.name);
            const bound_old = @field(self.source, field.name);
            const fresh = @field(target, field.name);
            const bound_fresh = @field(self.target, field.name);
            if (old.ptr != bound_old.ptr or old.len != bound_old.len or fresh.ptr != bound_fresh.ptr or fresh.len != bound_fresh.len) return error.InvalidMigrationProjection;
        }
        try self.checkConsistency();
        try self.validateTopology();
    }
    pub fn validateProfile(self: *const Projection, source: s.Platform, target: s.Platform) Error!void {
        try self.checkConsistency();
        try equalName(self.source, source.key.name, self.target, target.key.name);
        var expected = source;
        expected.key.name = target.key.name;
        if (!std.meta.eql(expected, target)) return error.UnsupportedCapability;
    }
    pub fn state(self: *const Projection, index: u32) Error!u32 {
        return indexAt(self.states[0..self.source.states.len], index);
    }
    pub fn segment(self: *const Projection, index: u32) Error!u32 {
        return indexAt(self.segments[0..self.source.segments.len], index);
    }
    pub fn selectorIndex(self: *const Projection, index: u32) Error!u32 {
        return indexAt(self.selectors[0..self.source.selectors.len], index);
    }
    fn optionalSegment(self: *const Projection, index: u32) Error!u32 {
        return if (index == s.none) s.none else self.segment(index);
    }
    pub fn convertSelector(self: *const Projection, index: u32, previous: selector.State) Error!selector.State {
        try self.checkConsistency();
        if (index >= self.source.selectors.len) return error.InvalidMigrationProjection;
        const old = self.source.selectors[index];
        const fresh = self.target.selectors[try self.selectorIndex(index)];
        if (previous.stable_id != old.key.id or previous.kind != old.kind or previous.capacity != old.history_capacity or previous.history_len > previous.capacity or previous.history_len > previous.history.len) return error.InvalidMigrationProjection;
        var result = previous;
        result.stable_id = fresh.key.id;
        if (self.reset[index]) {
            result = selector.State.init(fresh);
            result.epoch = if (self.reset_epoch[index]) 0 else previous.epoch;
        } else {
            for (result.history[0..result.history_len]) |*id| id.* = self.target.segments[try self.segment(try locate(self.source.segments, id.*))].key.id;
        }
        return result;
    }
    // A process-local owned consistency seal, not a security/authentication
    // boundary. The transaction still validates the original owned map/policy.
    // Cover all initialized owned indices/flags and table pointer/length values,
    // never pointee data. Thus standalone conversion rejects corrupt pointers or
    // lengths before dereferencing them. Both immutable banks remain retained.
    fn calculateDigest(self: *const Projection) [32]u8 {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        // Preserve the resident domain and all its bytes exactly. A separate
        // domain seals the explicit stream mode: flipping mode invalidates a
        // prepared projection even when its bank pointers have not changed.
        hash.update(switch (self.mode) {
            .resident => "BUGU-resident-migration-projection-v1",
            .streaming => "BUGU-stream-migration-projection-v1",
        });
        hashInteger(&hash, self.from_build_id);
        hashInteger(&hash, self.to_build_id);
        hash.update(&self.map_hash);
        hash.update(&self.policy_hash);
        inline for (std.meta.fields(s.Tables)) |field| {
            const source = @field(self.source, field.name);
            const target = @field(self.target, field.name);
            hashInteger(&hash, @intFromPtr(source.ptr));
            hashInteger(&hash, source.len);
            hashInteger(&hash, @intFromPtr(target.ptr));
            hashInteger(&hash, target.len);
        }
        inline for (.{ "states", "segments", "selectors" }) |field| {
            for (@field(self, field)) |index| hashInteger(&hash, index);
        }
        for (0..capacity) |i| {
            hashInteger(&hash, @intFromBool(self.reset[i]));
            hashInteger(&hash, @intFromBool(self.reset_epoch[i]));
        }
        return hash.finalResult();
    }
    fn checkConsistency(self: *const Projection) Error!void {
        if (!self.prepared) return error.InvalidMigrationProjection;
        inline for (.{ "states", "segments", "selectors" }) |field| {
            if (@field(self.source, field).len > capacity or @field(self.target, field).len > capacity) return error.InvalidMigrationProjection;
        }
        if (!std.mem.eql(u8, &self.consistency_digest, &self.calculateDigest())) return error.InvalidMigrationProjection;
    }
    fn validateTopology(self: *const Projection) Error!void {
        @setEvalBranchQuota(10_000);
        inline for (.{ "states", "segments", "selectors" }) |field| {
            const count = @field(self.source, field).len;
            if (count != @field(self.target, field).len or count > capacity) return error.InvalidMigrationProjection;
            for (@field(self, field)[0..count], 0..) |index, i| {
                if (index >= count) return error.InvalidMigrationProjection;
                for (@field(self, field)[0..i]) |prior| if (prior == index) return error.InvalidMigrationProjection;
            }
        }
        inline for (std.meta.fields(s.Tables)) |field| {
            const tag = @field(s.Table, field.name);
            // Text storage is compared through Named references. Only renamed
            // state/segment/selector labels may change. Resident media retains
            // its old gate. Stream resources have separate per-bank validation.
            if (comptime tag != .blob and tag != .sounds and tag != .import_reports and tag != .quality_reports and tag != .strings and tag != .string_data and tag != .candidates) {
                if (self.mode != .streaming or (tag != .codecs and tag != .chunks and tag != .seeks)) {
                    const old = @field(self.source, field.name);
                    const fresh = @field(self.target, field.name);
                    if (old.len != fresh.len) return error.UnsupportedCapability;
                    for (old, 0..) |row, i| {
                        const j: usize = switch (tag) {
                            .states => try self.state(@intCast(i)),
                            .segments => try self.segment(@intCast(i)),
                            .selectors => try self.selectorIndex(@intCast(i)),
                            else => i,
                        };
                        var expected = row;
                        const actual = fresh[j];
                        switch (tag) {
                            .states => {
                                expected.key.id = actual.key.id;
                                expected.selector = try self.selectorIndex(row.selector);
                            },
                            .segments => {
                                expected.key.id = actual.key.id;
                                expected.fallback_segment = try self.optionalSegment(row.fallback_segment);
                            },
                            .selectors => {
                                expected.key.id = actual.key.id;
                                expected.fallback_segment = try self.optionalSegment(row.fallback_segment);
                                const a = try bank.selection_validation.items(s.Candidate, self.source.candidates, row.candidates);
                                const b = try bank.selection_validation.items(s.Candidate, self.target.candidates, actual.candidates);
                                if (a.len != b.len) return error.UnsupportedCapability;
                                for (a, b) |before, after| {
                                    var next = before;
                                    next.segment = try self.segment(before.segment);
                                    if (!std.meta.eql(next, after)) return error.UnsupportedCapability;
                                }
                                expected.candidates = actual.candidates;
                            },
                            .themes => expected.initial_segment = try self.segment(row.initial_segment),
                            .layers, .cues, .fill_steps, .stingers, .stinger_policies => expected.segment = try self.segment(row.segment),
                            .transitions => {
                                expected.from = try self.state(row.from);
                                expected.to = try self.state(row.to);
                                expected.selector = try self.selectorIndex(row.selector);
                                expected.fallback_segment = try self.optionalSegment(row.fallback_segment);
                            },
                            .instructions => if (row.op == .load_state) {
                                expected.reference = try self.state(row.reference);
                            },
                            else => {},
                        }
                        if (comptime @typeInfo(@TypeOf(row)) == .@"struct") {
                            if (comptime @hasField(@TypeOf(row), "key")) {
                                const renamed = (tag == .states or tag == .segments or tag == .selectors) and row.key.id != actual.key.id;
                                if (!renamed) try equalName(self.source, row.key.name, self.target, actual.key.name);
                                expected.key.name = actual.key.name;
                            }
                        }
                        if (!std.meta.eql(expected, actual)) return error.UnsupportedCapability;
                    }
                }
            }
        }
        if (self.source.sounds.len != self.target.sounds.len or self.source.candidates.len != self.target.candidates.len) return error.UnsupportedCapability;
        if (self.mode == .streaming) {
            if (self.source.sounds.len == 0 or self.source.segments.len == 0) return error.UnsupportedCapability;
            // Whole-bank streaming is intentional, including inactive segments.
            // Equivalence above still covers every unused semantic entity.
            for (self.source.segments) |segment_row| if (segment_row.storage != .streaming) return error.UnsupportedCapability;
            for (self.target.segments) |segment_row| if (segment_row.storage != .streaming) return error.UnsupportedCapability;
            // Mapped selector pools were compared above. Records not used by
            // any selector are still semantics and must not silently change.
            for (self.source.candidates, self.target.candidates, 0..) |before, after, i| {
                const old_owned = candidateReferenced(self.source, i);
                const new_owned = candidateReferenced(self.target, i);
                if (old_owned and new_owned) continue;
                if (old_owned != new_owned) return error.UnsupportedCapability;
                var expected = before;
                expected.segment = try self.segment(before.segment);
                if (!std.meta.eql(expected, after)) return error.UnsupportedCapability;
            }
        }
        for (self.source.sounds, self.target.sounds) |a, b| {
            try equalName(self.source, a.key.name, self.target, b.key.name);
            switch (self.mode) {
                .resident => if (a.storage != .resident or b.storage != .resident or a.key.id != b.key.id or a.codec != b.codec or a.layout != b.layout or a.channels != b.channels or a.channel_mask != b.channel_mask or a.sample_rate_hz != b.sample_rate_hz or a.frames != b.frames or a.blob_length != b.blob_length or !std.meta.eql(a.chunks, b.chunks) or !std.meta.eql(a.seeks, b.seeks)) return error.UnsupportedCapability,
                .streaming => {
                    // Only the following Sound resource fields may change:
                    // codec/report indices, blob offset/length, audio/normalized
                    // hashes and chunk/seek ranges. Compare all other fields,
                    // including any future fields, by default.
                    var expected = a;
                    expected.key.name = b.key.name;
                    inline for (.{ "codec", "import_report", "quality_report", "encoded_quality_report", "blob_offset", "blob_length", "audio_hash", "normalized_hash", "chunks", "seeks" }) |field| @field(expected, field) = @field(b, field);
                    if (a.storage != .streaming or b.storage != .streaming or !std.meta.eql(expected, b)) return error.UnsupportedCapability;
                    if (a.codec >= self.source.codecs.len or b.codec >= self.target.codecs.len) return error.InvalidReference;
                    var before_codec = self.source.codecs[a.codec];
                    const after_codec = self.target.codecs[b.codec];
                    // Codec kind/version, channel interpretation and decoded
                    // frame domain stay fixed. Pre-skip, trim and encoder
                    // provenance are each bank's own validated media facts.
                    before_codec.pre_skip = after_codec.pre_skip;
                    before_codec.end_trim = after_codec.end_trim;
                    before_codec.encoder_hash = after_codec.encoder_hash;
                    if (before_codec.kind != .ogg_opus or after_codec.kind != .ogg_opus or !std.meta.eql(before_codec, after_codec) or a.sample_rate_hz != s.sample_rate) return error.UnsupportedCapability;
                },
            }
        }
    }
};
fn candidateReferenced(tables: s.Tables, index: usize) bool {
    for (tables.selectors) |row| if (index >= row.candidates.first and index - row.candidates.first < row.candidates.count) return true;
    return false;
}
fn indexAt(values: []const u32, index: u32) Error!u32 {
    if (index >= values.len) return error.InvalidMigrationProjection;
    return values[index];
}
fn mappedId(pairs: anytype, id: u64) ?u64 {
    for (pairs) |pair| if (pair.from.value() == id) return pair.to.value();
    return null;
}
fn locate(rows: anytype, id: u64) Error!u32 {
    for (rows, 0..) |row, i| if (row.key.id == id) return @intCast(i);
    return error.MissingTarget;
}
fn equalName(source: s.Tables, from: u32, target: s.Tables, to: u32) Error!void {
    if (from == s.none or to == s.none) {
        if (from != to) return error.UnsupportedCapability;
        return;
    }
    if (!std.mem.eql(u8, try bank.string(source, from), try bank.string(target, to))) return error.UnsupportedCapability;
}

fn hashInteger(hash: *std.crypto.hash.sha2.Sha256, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hash.update(&bytes);
}
