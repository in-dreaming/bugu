//! Bounded, serialized-Control ownership registry. It owns actual payloads, not
//! fabricated generation facts. Borrowed pointers never authorize publication.
const std = @import("std");
const music = @import("music");
pub const retention = @import("sme-reload-contract").retention;
pub const capacity = retention.max_snapshot_generations + 1;
pub const Handle = struct { index: u8, incarnation: u64 };
pub const Coverage = enum { complete, worker_memory_unknown, physical_ownership_unknown };
pub const Identity = struct { build_id: u64, content_hash: [32]u8 };
/// Identity-only startup reservation. The LoadTransaction remains the actual
/// payload owner until final adoption; this value reserves no storage or media.
pub const InitialReservation = struct { identity: Identity, generation: music.AssetGeneration };
pub const Observation = struct {
    retained_bytes: u64,
    coverage: Coverage,
};
pub const Admission = struct {
    serial: u64,
    candidate: Handle,
    runtime_generation: music.AssetGeneration,
    profile_hash: [32]u8,
    map_hash: [32]u8,
    policy_hash: [32]u8,
    totals: retention.Totals,
};
pub const Error = retention.Error || error{
    InvalidHandle,
    InvalidState,
    RegistryFull,
    OwnershipPending,
    UnknownWorkerMemory,
    UnknownPhysicalOwnership,
    SameContent,
    StaleAdmission,
    IdentityExhausted,
    AcquisitionClosed,
};

/// Payload lifetime is transferred into adopt; withdraw transfers it back only
/// after Control-plan AND explicit borrowed-PCM credits reach zero. The caller's normal physical teardown
/// checks still precede destruction. No eviction or active swap is implemented
/// by withdraw, and no caller can turn an Admission into an activation receipt.
pub fn Registry(comptime Payload: type) type {
    return struct {
        const Self = @This();
        pub const Entry = struct {
            payload: *Payload,
            identity: Identity,
            generation: music.AssetGeneration,
            candidate: bool,
            control_plan_leases: u64 = 0,
            // Separate actual borrow ownership, never relabeled as Control-plan
            // or inferred from aggregate SampleOwner reference counts.
            borrowed_resident_pcm: u64 = 0,
            // Actual prepared-group custody, acquired before the Control slot
            // becomes visible and returned only after physical group drain.
            prepared_music_groups: u64 = 0,
            // One actual backing-owner envelope per snapshot slot and generation.
            snapshot_slots: u64 = 0,
            // Pre-funded fixed play envelopes, including unused reservations.
            // A root/derivative claim never creates an unfunded registry lease.
            play_envelopes: u64 = 0,
            borrowed_acquisition_open: bool = true,
            observation: Observation = .{ .retained_bytes = 0, .coverage = .worker_memory_unknown },
        };
        entries: [capacity]?Entry = @splat(null),
        incarnations: [capacity]u64 = @splat(0),
        active: ?Handle = null,
        initial_reservation: ?InitialReservation = null,
        high_water: u64 = 0,
        next_admission: u64 = 1,
        admission: ?Admission = null,

        pub fn count(self: *const Self) usize {
            var n: usize = 0;
            for (self.entries) |entry| n += @intFromBool(entry != null);
            return n;
        }
        pub fn get(self: *Self, handle: Handle) Error!*Entry {
            if (handle.index >= capacity or self.incarnations[handle.index] != handle.incarnation or self.entries[handle.index] == null) return error.InvalidHandle;
            return &self.entries[handle.index].?;
        }
        fn identityValid(identity: Identity) bool {
            return identity.build_id != 0 and !std.mem.allEqual(u8, &identity.content_hash, 0);
        }
        fn adopt(self: *Self, payload: *Payload, identity: Identity, generation: music.AssetGeneration, candidate: bool) Error!Handle {
            if (!identityValid(identity)) return error.InvalidIdentity;
            for (self.entries) |entry| if (entry) |value| {
                if (value.payload == payload) return error.InvalidState;
                if (candidate and value.candidate) return error.InvalidState;
                if ((value.identity.build_id == identity.build_id) != std.mem.eql(u8, &value.identity.content_hash, &identity.content_hash)) return error.InvalidIdentity;
            };
            for (&self.entries, 0..) |*entry, i| if (entry.* == null) {
                if (self.incarnations[i] == std.math.maxInt(u64)) continue;
                self.incarnations[i] += 1;
                entry.* = .{ .payload = payload, .identity = identity, .generation = generation, .candidate = candidate };
                self.admission = null;
                return .{ .index = @intCast(i), .incarnation = self.incarnations[i] };
            };
            return error.RegistryFull;
        }
        /// Exact serialized-Control preflight before another owner's fallible
        /// attachment. No identity, ownership or admission is reserved here.
        pub fn validateInitialAdoption(self: *const Self, identity: Identity, generation: music.AssetGeneration) Error!void {
            if (self.active != null or self.count() != 0 or self.high_water != 0 or self.initial_reservation != null) return error.InvalidState;
            if (!identityValid(identity) or !generation.isValid()) return error.InvalidIdentity;
            for (self.incarnations) |incarnation| if (incarnation != std.math.maxInt(u64)) return;
            return error.RegistryFull;
        }
        pub fn adoptInitial(self: *Self, payload: *Payload, identity: Identity, generation: music.AssetGeneration) Error!Handle {
            try self.validateInitialAdoption(identity, generation);
            const handle = try self.adopt(payload, identity, generation, false);
            self.active = handle;
            self.high_water = generation.value();
            return handle;
        }
        /// Used by the explicit startup-reserved Service path before provider
        /// work. The first ID preserves authored startup compatibility; retries
        /// consume fresh monotonic IDs even if an earlier attempt was aborted.
        pub fn reserveInitialIdentity(self: *Self, identity: Identity, authored: music.AssetGeneration) Error!InitialReservation {
            if (self.active != null or self.count() != 0 or self.initial_reservation != null) return error.InvalidState;
            if (!identityValid(identity) or !authored.isValid()) return error.InvalidIdentity;
            var available = false;
            for (self.incarnations) |incarnation| available = available or incarnation != std.math.maxInt(u64);
            if (!available) return error.RegistryFull;
            const generation = if (self.high_water == 0) authored else blk: {
                if (self.high_water == std.math.maxInt(u64)) return error.IdentityExhausted;
                break :blk @as(music.AssetGeneration, @enumFromInt(self.high_water + 1));
            };
            const reservation: InitialReservation = .{ .identity = identity, .generation = generation };
            self.high_water = generation.value();
            self.initial_reservation = reservation;
            return reservation;
        }
        pub fn validateInitialReservation(self: *const Self, value: InitialReservation) Error!void {
            if (self.active != null or self.count() != 0 or self.initial_reservation == null or !std.meta.eql(self.initial_reservation.?, value)) return error.InvalidState;
        }
        pub fn cancelInitialIdentity(self: *Self, value: InitialReservation) Error!void {
            try self.validateInitialReservation(value);
            self.initial_reservation = null; // high_water is deliberately retained.
        }
        pub fn adoptReservedInitial(self: *Self, payload: *Payload, value: InitialReservation) Error!Handle {
            try self.validateInitialReservation(value);
            const handle = try self.adopt(payload, value.identity, value.generation, false);
            self.initial_reservation = null;
            self.active = handle;
            return handle;
        }
        pub fn adoptCandidate(self: *Self, payload: *Payload, identity: Identity) Error!Handle {
            if (self.active == null) return error.InvalidState;
            return self.adopt(payload, identity, .invalid, true);
        }
        /// Reserve identity before any provider/window/job can observe a
        /// candidate. This is deliberately NOT retention/readiness admission.
        /// Aborted identities remain consumed; repeat reservation is idempotent
        /// only for this exact live handle. Same-content never consumes an ID.
        pub fn reserveCandidateIdentity(self: *Self, handle: Handle) Error!music.AssetGeneration {
            const candidate = try self.get(handle);
            if (!candidate.candidate) return error.InvalidState;
            const active = try self.get(self.active orelse return error.InvalidState);
            if (std.mem.eql(u8, &candidate.identity.content_hash, &active.identity.content_hash)) return error.SameContent;
            if (candidate.generation.isValid()) return candidate.generation;
            if (self.high_water == std.math.maxInt(u64)) return error.IdentityExhausted;
            const generation: music.AssetGeneration = @enumFromInt(self.high_water + 1);
            candidate.generation = generation;
            self.high_water = generation.value();
            self.admission = null;
            return generation;
        }
        /// Serialized owner calls this only after its exact Render activation
        /// receipt. Admission alone is deliberately insufficient authority.
        pub fn commitActivatedCandidate(self: *Self, source: Handle, handle: Handle, generation: music.AssetGeneration) Error!void {
            if (self.active == null or !std.meta.eql(self.active.?, source)) return error.InvalidState;
            const old = try self.get(source);
            const candidate = try self.get(handle);
            if (old.candidate or !candidate.candidate or candidate.generation != generation or generation.value() <= old.generation.value()) return error.InvalidState;
            old.borrowed_acquisition_open = false;
            candidate.candidate = false;
            self.active = handle;
            self.admission = null;
        }
        pub fn acquireControl(self: *Self, handle: Handle) Error!void {
            const entry = try self.get(handle);
            const next = std.math.add(u64, entry.control_plan_leases, 1) catch return error.ArithmeticOverflow;
            entry.control_plan_leases = next;
            self.admission = null;
        }
        pub fn releaseControl(self: *Self, handle: Handle) Error!void {
            const entry = try self.get(handle);
            if (entry.control_plan_leases == 0) return error.InvalidState;
            entry.control_plan_leases -= 1;
            self.admission = null;
        }
        pub fn acquirePreparedGroup(self: *Self, handle: Handle) Error!void {
            const entry = try self.get(handle);
            if (!entry.generation.isValid() or !entry.borrowed_acquisition_open) return error.AcquisitionClosed;
            entry.prepared_music_groups = std.math.add(u64, entry.prepared_music_groups, 1) catch return error.ArithmeticOverflow;
            self.admission = null;
        }
        pub fn releasePreparedGroup(self: *Self, handle: Handle) Error!void {
            const entry = try self.get(handle);
            if (entry.prepared_music_groups == 0) return error.InvalidState;
            entry.prepared_music_groups -= 1;
            self.admission = null;
        }
        /// Derivative custody from already Control-owned desired voices. Closing
        /// external borrowed acquisition must not prevent shutdown snapshots.
        pub fn acquireSnapshot(self: *Self, handle: Handle) Error!void {
            const entry = try self.get(handle);
            if (!entry.generation.isValid()) return error.AcquisitionClosed;
            entry.snapshot_slots = std.math.add(u64, entry.snapshot_slots, 1) catch return error.ArithmeticOverflow;
            self.admission = null;
        }
        pub fn releaseSnapshot(self: *Self, handle: Handle) Error!void {
            const entry = try self.get(handle);
            if (entry.snapshot_slots == 0) return error.InvalidState;
            entry.snapshot_slots -= 1;
            self.admission = null;
        }
        pub fn reservePlayEnvelopes(self: *Self, handle: Handle, count_value: u64) Error!void {
            const entry = try self.get(handle);
            if (!entry.generation.isValid() or !entry.borrowed_acquisition_open) return error.AcquisitionClosed;
            if (count_value == 0 or entry.play_envelopes != 0) return error.InvalidState;
            entry.play_envelopes = count_value;
            self.admission = null;
        }
        pub fn releasePlayEnvelopes(self: *Self, handle: Handle, count_value: u64) Error!void {
            const entry = try self.get(handle);
            if (count_value == 0 or entry.play_envelopes != count_value) return error.InvalidState;
            entry.play_envelopes = 0;
            self.admission = null;
        }
        pub fn acquireBorrowed(self: *Self, handle: Handle) Error!void {
            const entry = try self.get(handle);
            if (!entry.borrowed_acquisition_open) return error.AcquisitionClosed;
            entry.borrowed_resident_pcm = std.math.add(u64, entry.borrowed_resident_pcm, 1) catch return error.ArithmeticOverflow;
            self.admission = null;
        }
        pub fn releaseBorrowed(self: *Self, handle: Handle) Error!void {
            const entry = try self.get(handle);
            if (entry.borrowed_resident_pcm == 0) return error.InvalidState;
            entry.borrowed_resident_pcm -= 1;
            self.admission = null;
        }
        pub fn closeBorrowed(self: *Self, handle: Handle) Error!void {
            const entry = try self.get(handle);
            entry.borrowed_acquisition_open = false;
            self.admission = null;
        }
        pub fn observe(self: *Self, handle: Handle, value: Observation) Error!void {
            if (value.retained_bytes == 0 and value.coverage == .complete) return error.InvalidIdentity;
            const entry = try self.get(handle);
            if (!std.meta.eql(entry.observation, value)) self.admission = null;
            entry.observation = value;
        }
        pub fn invalidateAdmission(self: *Self) void {
            self.admission = null;
        }
        pub fn withdraw(self: *Self, handle: Handle) Error!*Payload {
            const entry = try self.get(handle);
            if (entry.control_plan_leases != 0 or entry.borrowed_resident_pcm != 0 or entry.prepared_music_groups != 0 or entry.snapshot_slots != 0 or entry.play_envelopes != 0) return error.OwnershipPending;
            if (self.active) |active| if (std.meta.eql(active, handle)) {
                // No live candidate may outlive its exact source ownership.
                for (self.entries) |other| if (other) |value| if (value.candidate) return error.OwnershipPending;
                self.active = null;
            };
            const payload = entry.payload;
            self.entries[handle.index] = null;
            self.admission = null;
            return payload;
        }
        fn facts(entry: Entry, generation: music.AssetGeneration) Error!retention.GenerationFacts {
            // V1 retention has no explicit borrowed-PCM category. Until a
            // deliberate physical-inventory extension exists, fail closed even
            // if an internal caller mistakenly labels its observation complete.
            if (entry.borrowed_resident_pcm != 0 or entry.prepared_music_groups != 0 or entry.snapshot_slots != 0 or entry.play_envelopes != 0) return error.UnknownPhysicalOwnership;
            switch (entry.observation.coverage) {
                .worker_memory_unknown => return error.UnknownWorkerMemory,
                .physical_ownership_unknown => return error.UnknownPhysicalOwnership,
                .complete => {},
            }
            return .{ .generation = generation, .build_id = entry.identity.build_id, .content_hash = entry.identity.content_hash, .retained_bytes = entry.observation.retained_bytes, .leases = .{ .control_plan = entry.control_plan_leases } };
        }
        /// Admits only exact currently observed owned assets/Control credits. It
        /// does not reserve future commands/Render leases or imply activation.
        /// Any changed ownership/observation invalidates the retained admission.
        pub fn admit(self: *Self, handle: Handle, profile: retention.GenerationRetentionProfile, map_hash: [32]u8, policy_hash: [32]u8) Error!Admission {
            try profile.validate();
            if (std.mem.allEqual(u8, &map_hash, 0) or std.mem.allEqual(u8, &policy_hash, 0)) return error.InvalidIdentity;
            const candidate = try self.get(handle);
            if (!candidate.candidate) return error.InvalidState;
            const active = try self.get(self.active orelse return error.InvalidState);
            // No-op is not capacity/freshness validation and owns no reservation.
            // Caller must explicitly withdraw/destroy its redundant candidate.
            if (std.mem.eql(u8, &candidate.identity.content_hash, &active.identity.content_hash)) return error.SameContent;
            if (self.next_admission == std.math.maxInt(u64)) return error.IdentityExhausted;
            const proposed = if (candidate.generation.isValid()) candidate.generation else blk: {
                if (self.high_water == std.math.maxInt(u64)) return error.IdentityExhausted;
                break :blk @as(music.AssetGeneration, @enumFromInt(self.high_water + 1));
            };
            var inventory: [retention.max_snapshot_generations]retention.GenerationFacts = undefined;
            var count_value: usize = 0;
            for (self.entries) |entry| if (entry) |value| {
                if (value.candidate) continue;
                if (count_value == inventory.len) return error.RegistryFull;
                inventory[count_value] = try facts(value, value.generation);
                count_value += 1;
            };
            const plan = try retention.plan(profile, .{ .active_generation = active.generation, .generations = inventory[0..count_value] }, try facts(candidate.*, proposed));
            // The current owner has initial + candidate only. Eviction requires
            // actual retained-history ownership and rechecks, not a planner list.
            if (plan.outcome != .candidate_fits or plan.eviction_count != 0) return error.InvalidState;
            const result: Admission = .{ .serial = self.next_admission, .candidate = handle, .runtime_generation = proposed, .profile_hash = try profile.contentHash(), .map_hash = map_hash, .policy_hash = policy_hash, .totals = plan.totals };
            candidate.generation = proposed;
            self.high_water = @max(self.high_water, proposed.value());
            self.next_admission += 1;
            self.admission = result;
            return result;
        }
        pub fn validateAdmission(self: *const Self, value: Admission) Error!void {
            if (self.admission == null or !std.meta.eql(self.admission.?, value)) return error.StaleAdmission;
        }
    };
}
