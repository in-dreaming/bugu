//! Owned metadata from each actual Render slot-state acquire. Four consecutive
//! reads share storage, not a snapshot: Control may publish between any reads.
//! This module does not import the scheduler or retain pointers into its slots.
const trace = @import("sme-trace").schema;

pub const State = enum(u8) { free, prepared, queued, published, acquired, partially_executed, terminal };
pub const slots_per_chunk: usize = 4;

pub const SlotRead = struct {
    slot_index: u16 = 0,
    state: State = .free,
    /// All remaining fields are valid only for the observed .published state.
    /// In particular, an observer never inspects Control-owned queued payloads.
    generation: u64 = 0,
    batch_id: u64 = 0,
    content_hash: trace.Hash = @splat(0),
    first_command_id: u64 = 0,
    first_execute_frame: u64 = 0,
    first_group_id: u64 = 0,
    first_sequence: u64 = 0,
    first_phase_order: u32 = 0,
    command_count: u16 = 0,
    admission_disposition: ?trace.AdmissionDisposition = null,
    admission_order: u32 = 0,
};

pub const ScanChunk = struct {
    gate: u64 = 0,
    frame: u64 = 0,
    reads: [slots_per_chunk]SlotRead = @splat(.{}),
};

/// Render-local bounded callbacks. begin_chunk reserves all event budget and
/// queue storage before returning final-address, bridge-owned staging storage.
/// Null/false permanently disables this scan's remaining observations. Neither
/// callback may allocate, block, retry, hash, or inspect operational owner state.
pub const Sink = struct {
    context: *anyopaque,
    begin_chunk: *const fn (*anyopaque, u16, u32) ?*ScanChunk,
    end_chunk: *const fn (*anyopaque, *const ScanChunk) bool,
};

pub const slot_read_bytes: usize = @sizeOf(SlotRead);
pub const scan_chunk_bytes: usize = @sizeOf(ScanChunk);
comptime {
    if (@sizeOf(ScanChunk) > 448) @compileError("scheduler scan must leave room in the 512-byte Render event envelope");
}

/// Finite retained COMPLETE-plan invalidation evidence. These identities are
/// immutable under the intent's existing block/plan leases until Control ack.
pub const Handle = struct { index: u16 = 0, generation: u64 = 0 };
pub const InvalidationIdentity = struct {
    intent: Handle = .{},
    target: Handle = .{},
    plan: Handle = .{},
    batch_id: u64 = 0,
    content_hash: trace.Hash = @splat(0),
    sequence: u64 = 0,
    context: u64 = 0,
    plan_id: u64 = 0,
    plan_epoch: u64 = 0,
    phase_id: u64 = 0,
    transport_epoch: u64 = 0,
    asset_generation: u64 = 0,
    requested_frame: u64 = 0,
    next_transport_epoch: u64 = 0,
    next_asset_generation: u64 = 0,
    emergency_stop_music: bool = false,
    plan_target: bool = false,
    target_has_slot: bool = false,
};
pub const InvalidationPublication = struct {
    state_before: ?u8 = null,
    identity: InvalidationIdentity = .{},
    write_before: u64 = 0,
    write_after: u64 = 0,
    state_published: u8 = 0,
    queue_published: bool = false,
    error_code: u32 = 0,
};
pub const InvalidationPoll = struct {
    read_cursor: u64 = 0,
    write_prefix: u64 = 0,
    identity: ?InvalidationIdentity = null,
};
/// Optional fields are reached-load flags, not inferred later snapshots.
pub const PlanStateRead = struct {
    prefix: u16 = 0,
    total: u16 = 0,
    cancelled: bool = false,
    acquired: ?bool = null,
    published: ?bool = null,
};
/// The exact nondefault fields of the supported cancel_too_late record.
/// Token identity is retained separately; full ScheduleRecord stays comparator
/// data and is never supplied to Render or Control by this observation.
pub const TooLateReceipt = struct {
    kind: trace.ScheduleKind,
    result: trace.Result,
    state_before: trace.ExecutionState,
    executed_prefix_count: u32,
    executed_frame: u64,
    effective_frame: u64,
    cancel_requested_frame: u64,
    commit_horizon: u64,
    pub fn from(record: trace.ScheduleRecord) TooLateReceipt {
        return .{ .kind = record.kind, .result = record.result, .state_before = record.state_before, .executed_prefix_count = record.executed_prefix_count, .executed_frame = record.executed_frame, .effective_frame = record.effective_frame, .cancel_requested_frame = record.cancel_requested_frame, .commit_horizon = record.commit_horizon };
    }
};
pub const InvalidationResult = struct {
    identity: InvalidationIdentity = .{},
    state: PlanStateRead = .{},
    before: trace.ExecutionState = .none,
    admission: ?trace.Admission = null,
    receipt: ?TooLateReceipt = null,
    execution_ordinal: u64 = 0,
    finish_read_before: u64 = 0,
    finish_read_after: u64 = 0,
    finish_state: u8 = 0,
    supported: bool = false,
};
pub const CancellationRead = struct {
    first_state: ?u8 = null,
    second_state: ?u8 = null,
    target: Handle = .{},
    receipt: ?TooLateReceipt = null,
    released: bool = false,
};
comptime {
    if (@sizeOf(InvalidationPoll) > 448 or @sizeOf(InvalidationResult) > 448) @compileError("invalidation evidence must fit the existing Render envelope");
}
