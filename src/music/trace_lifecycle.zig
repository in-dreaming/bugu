//! Bounded lifecycle/generation value facts. Resource semantic validation belongs
//! to the actual bank/snapshot/migration consumers; no algorithms are simulated.
const std = @import("std");
const s = @import("trace_schema.zig");
pub const BankIdentity = struct {
    major: u16,
    minor: u16,
    build_id: u64,
    generation: u64,
    content_hash: s.Hash,
    pub fn validate(self: BankIdentity) s.Error!void {
        if (self.major == 0 or self.build_id == 0 or self.generation == 0 or s.isZero(self.content_hash)) return error.InvalidEvent;
    }
};
/// bytes_hash hashes the exact stored bytes. It is deliberately distinct from
/// the bank's content hash, which TASK003 computes with its hash field zeroed.
pub const BankResource = struct {
    identity: BankIdentity,
    byte_size: u64,
    bytes_hash: s.Hash,
    pub fn validate(self: BankResource) s.Error!void {
        try self.identity.validate();
        if (self.byte_size == 0 or s.isZero(self.bytes_hash)) return error.InvalidEvent;
    }
};
pub const SnapshotResource = struct {
    schema_version: u16,
    byte_size: u64,
    bytes_hash: s.Hash,
    bank_build_id: u64,
    bank_generation: u64,
    capture_render_frame: u64,
    pub fn validate(self: SnapshotResource) s.Error!void {
        if (self.schema_version != 1) return error.UnknownVersion;
        if (self.byte_size == 0 or s.isZero(self.bytes_hash) or self.bank_build_id == 0 or self.bank_generation == 0) return error.InvalidEvent;
    }
};
pub const MigrationIdentity = struct {
    schema_version: u16,
    content_hash: s.Hash,
    from_build_id: u64,
    to_build_id: u64,
    history_policy_id: u64,
    pub fn validate(self: MigrationIdentity) s.Error!void {
        if (self.schema_version != 1) return error.UnknownVersion;
        if (s.isZero(self.content_hash) or self.from_build_id == 0 or self.to_build_id == 0 or self.history_policy_id == 0) return error.InvalidEvent;
    }
};
pub const MigrationResource = struct {
    identity: MigrationIdentity,
    byte_size: u64,
    bytes_hash: s.Hash,
    required_capabilities: u64,
    pub fn validate(self: MigrationResource) s.Error!void {
        try self.identity.validate();
        if (self.byte_size == 0 or s.isZero(self.bytes_hash)) return error.InvalidEvent;
    }
};
pub const PublishMode = enum(u8) { next_bar = 1, authored_cue = 2, metadata_only = 3 };
pub const PublishPolicy = struct {
    mode: PublishMode,
    cue: ?u64,
    requested_not_before_frame: ?u64,
    pub fn validate(self: PublishPolicy) s.Error!void {
        if ((self.mode == .authored_cue) != (self.cue != null)) return error.InvalidEvent;
        if (self.cue) |cue| if (cue == 0) return error.InvalidEvent;
        // metadata_only is additionally allowlist-validated by the real consumer.
    }
};
pub const ContextMode = enum(u8) { shipping_game = 1, authoring = 2, offline = 3, debug = 4 };
pub const LifecycleTag = enum(u16) { initialize = 1, load_bank = 2, unload_bank = 3, start = 4, capture_state = 5, restore_state = 6, shutdown = 7 };
pub const Restore = struct { snapshot: SnapshotResource, target_bank: BankIdentity, migration: ?MigrationResource, reanchor_frontier: u64 };
pub const LifecyclePayload = union(LifecycleTag) {
    initialize: struct { mode: ContextMode, seed: u64, profile: u64, profile_hash: s.Hash },
    load_bank: BankResource,
    unload_bank: BankIdentity,
    start: struct { bank: BankIdentity, initial_state: u64 },
    capture_state: BankIdentity,
    restore_state: Restore,
    shutdown: void,
};
pub const Lifecycle = struct {
    operation_id: u64,
    context: u64,
    producer: u64,
    producer_order: u64,
    expected_transport_epoch: u64,
    payload: LifecyclePayload,
    pub fn validate(self: Lifecycle) s.Error!void {
        if (self.operation_id == 0 or self.context == 0 or self.producer == 0) return error.InvalidEvent;
        if (self.payload != .initialize and self.expected_transport_epoch == 0) return error.InvalidEvent;
        switch (self.payload) {
            .initialize => |v| {
                if (v.profile == 0 or s.isZero(v.profile_hash)) return error.InvalidEvent;
            },
            .load_bank => |v| try v.validate(),
            .unload_bank, .capture_state => |v| try v.validate(),
            .start => |v| {
                try v.bank.validate();
                if (v.initial_state == 0) return error.InvalidEvent;
            },
            .restore_state => |v| {
                try v.snapshot.validate();
                try v.target_bank.validate();
                try validateMigration(v.migration, v.snapshot.bank_build_id, v.target_bank.build_id);
            },
            .shutdown => {},
        }
    }
};
pub fn validateMigration(migration: ?MigrationResource, from: u64, to: u64) s.Error!void {
    if (migration) |m| {
        try m.validate();
        if (m.identity.from_build_id != from or m.identity.to_build_id != to) return error.InvalidEvent;
    } else if (from != to) return error.InvalidEvent;
}
pub const GenerationOperation = enum(u8) { hot_reload = 1, rollback = 2 };
pub const GenerationIntent = struct {
    transaction_id: u64,
    context: u64,
    producer: u64,
    producer_order: u64,
    expected_plan_epoch: u64,
    expected_transport_epoch: u64,
    operation: GenerationOperation,
    active_bank: BankIdentity,
    candidate_bank: BankResource,
    migration: ?MigrationResource,
    policy: PublishPolicy,
    pub fn validate(self: GenerationIntent) s.Error!void {
        if (self.transaction_id == 0 or self.context == 0 or self.producer == 0 or self.expected_plan_epoch == 0 or self.expected_transport_epoch == 0) return error.InvalidEvent;
        try self.active_bank.validate();
        try self.candidate_bank.validate();
        try self.policy.validate();
        try validateMigration(self.migration, self.active_bank.build_id, self.candidate_bank.identity.build_id);
        // Candidate generation is the prepared/retained bank's identity. A real
        // rollback assigns its NEW monotonic active generation during execution.
    }
};
pub const PreparationKind = enum(u8) { load_bank = 1, restore_state = 2, hot_reload = 3, rollback = 4 };
pub const GenerationPreparation = struct {
    operation_id: u64,
    context: u64,
    job: u64,
    control_epoch: u64,
    transport_epoch: u64,
    kind: PreparationKind,
    state: s.Readiness,
    bank: BankResource,
    migration: ?MigrationResource,
    snapshot: ?SnapshotResource,
    failure_code: u16,
    pub fn validate(self: GenerationPreparation) s.Error!void {
        if (self.operation_id == 0 or self.context == 0 or self.job == 0 or self.control_epoch == 0 or self.transport_epoch == 0) return error.InvalidEvent;
        try self.bank.validate();
        if (self.migration) |m| {
            try m.validate();
            if (m.identity.to_build_id != self.bank.identity.build_id) return error.InvalidEvent;
        }
        if (self.snapshot) |v| {
            try v.validate();
            try validateMigration(self.migration, v.bank_build_id, self.bank.identity.build_id);
        }
        if ((self.kind == .restore_state) != (self.snapshot != null)) return error.InvalidEvent;
        if ((self.state == .failed) != (self.failure_code != 0)) return error.InvalidEvent;
    }
};
pub const TransactionOperation = enum(u8) { initialize = 1, load_bank = 2, unload_bank = 3, start = 4, capture_state = 5, restore_state = 6, shutdown = 7, hot_reload = 8, rollback = 9 };
pub const TransactionStage = enum(u8) { prepare = 1, publish_candidate = 2, activate = 3, commit = 4, abort = 5, recovery = 6, no_op = 7 };
/// Computed output only. Every phase remains separately observable via event
/// rows; prefix/suffix/cursor facts summarize the actually retained state.
pub const TransactionRecord = struct {
    operation: TransactionOperation,
    stage: TransactionStage,
    context: u64,
    transaction_id: u64,
    sequence: u64,
    accepted_control_frame: u64,
    effective_frame: u64,
    old_bank: ?BankIdentity,
    new_bank: ?BankIdentity,
    old_plan_epoch: u64,
    new_plan_epoch: u64,
    old_transport_epoch: u64,
    new_transport_epoch: u64,
    migration: ?MigrationIdentity,
    policy: ?PublishPolicy,
    snapshot_hash: ?s.Hash,
    snapshot_capture_frame: u64,
    plan_id: u64,
    phase_id: u64,
    phase_order: u32,
    executed_prefix_count: u32,
    cancelled_suffix_start: u32,
    cancelled_suffix_count: u32,
    source_segment: u64,
    fill_segment: u64,
    target_segment: u64,
    cursor: u64,
    result: s.Result,
    reason: s.Reason,
    pub fn validate(self: TransactionRecord) s.Error!void {
        if (self.context == 0 or self.transaction_id == 0 or self.effective_frame < self.accepted_control_frame) return error.InvalidEvent;
        if (self.old_bank) |b| try b.validate();
        if (self.new_bank) |b| try b.validate();
        if (self.migration) |m| {
            try m.validate();
            if (self.new_bank == null or m.to_build_id != self.new_bank.?.build_id) return error.InvalidEvent;
        }
        if (self.policy) |p| try p.validate();
        if (self.snapshot_hash) |h| if (s.isZero(h)) return error.InvalidEvent;
        if ((self.phase_id != 0 or self.executed_prefix_count != 0 or self.cancelled_suffix_count != 0) and self.plan_id == 0) return error.InvalidEvent;
        if (self.cancelled_suffix_count != 0 and self.cancelled_suffix_start < self.executed_prefix_count) return error.InvalidEvent;
        if (self.operation == .hot_reload or self.operation == .rollback) {
            if (self.old_bank == null or self.policy == null or self.old_plan_epoch == 0 or self.old_transport_epoch == 0) return error.InvalidEvent;
            if (self.migration) |m| if (m.from_build_id != self.old_bank.?.build_id) return error.InvalidEvent;
            if ((self.new_plan_epoch == 0) != (self.new_transport_epoch == 0)) return error.InvalidEvent;
            switch (self.stage) {
                .prepare => if (self.new_plan_epoch != 0 or self.new_transport_epoch != 0) return error.InvalidEvent,
                .abort => {
                    if (self.new_plan_epoch != 0 and self.new_bank == null) return error.InvalidEvent;
                },
                .publish_candidate, .activate, .commit, .recovery, .no_op => {
                    if (self.new_bank == null or self.new_plan_epoch == 0 or self.new_transport_epoch == 0) return error.InvalidEvent;
                },
            }
            if (self.stage == .publish_candidate or self.stage == .activate or self.stage == .commit) {
                if (self.old_bank.?.build_id != self.new_bank.?.build_id and self.migration == null) return error.InvalidEvent;
            }
            if (self.stage == .commit and self.new_bank.?.generation <= self.old_bank.?.generation) return error.InvalidEvent;
        }
        if (self.stage == .no_op) {
            if (self.old_bank == null or !std.meta.eql(self.old_bank, self.new_bank) or self.old_plan_epoch != self.new_plan_epoch or self.old_transport_epoch != self.new_transport_epoch or self.result != .success or self.cancelled_suffix_count != 0) return error.InvalidEvent;
        }
    }
};

/// Additive wire fact. The original TransactionRecord wire is unchanged.
pub const ResidentFenceV1 = struct {
    version: u16 = 1,
    context: u64,
    operation_id: u64,
    restore: bool,
    frame: u64,
    gate: u64,
    execution_ordinal: u64,
    executed_prefix_count: u16,
    segment: u64,
    cursor: u64,
    loop_epoch: u64,
    paused: bool,
    snapshot_hash: s.Hash,
    pub fn validate(self: ResidentFenceV1) s.Error!void {
        if (self.version != 1) return error.UnknownVersion;
        if (self.context == 0 or self.operation_id == 0 or self.gate == 0 or self.execution_ordinal == 0 or self.executed_prefix_count > 4 or s.isZero(self.snapshot_hash)) return error.InvalidEvent;
        if (self.segment == 0 and (self.cursor != 0 or self.loop_epoch != 0 or self.paused)) return error.InvalidEvent;
    }
};
