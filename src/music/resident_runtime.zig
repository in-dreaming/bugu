//! TASK026 bounded production owner. This is the public MusicRuntime entry which
//! TASK014 extends; there is no second mixer, scheduler or render clock here.
const std = @import("std");
const api = @import("api.zig");
const audio = @import("bugu_audio");
const rt = audio.runtime;
const bank = @import("sme-bank");
const planner = @import("sme-planner");
const crossfade_projection = @import("sme-runtime-crossfade-projection");
const director = @import("sme-director");
const selectors = @import("sme-selector");
const clock = @import("sme-clock");
const trace = @import("sme-trace");
const public_replay = @import("public_replay.zig");
const chunk_recording = trace.chunk_recording;
const context_host = trace.schema.context_host;
const s = bank.schema;
const v1 = @import("runtime_contract.zig");
const ingress = @import("runtime_ingress.zig");
const save = @import("save_state.zig");
const observer = @import("runtime_observer.zig");
const assets = @import("runtime_assets.zig");
const Generation = assets.Generation;
const TestFinalization = if (@import("builtin").is_test) @import("live_finalization_test_binding.zig") else struct {};
const layer_owner = assets.runtime_layers;
const prepared_layers = @import("sme-layers");
const reload_staging = @import("reload_staging.zig");
const borrowed_sound = @import("borrowed_sound_lease.zig");
const admission_model = @import("sme-generation-admission");
const generation_registry = admission_model.registry;
const GenerationRegistry = generation_registry.Registry(Generation);
const migration = admission_model.contracts.migration;
const retention = admission_model.contracts.retention;
const epoch_policy = admission_model.policy;
const live_reload_contract = @import("resident_reload_contract.zig");
const device_recovery = @import("device_recovery.zig");
// Heap-only bounded Control validation scratch; never Render stack storage.
const GenerationInventory = struct {
    states: [migration.max_entries_per_category]api.MusicStateId = undefined,
    segments: [migration.max_entries_per_category]api.SegmentId = undefined,
    selectors: [migration.max_entries_per_category]api.SegmentSelectorId = undefined,
    kinds: [migration.max_entries_per_category]epoch_policy.Selector = undefined,
    inventory: migration.Inventory = .{},
    fn init(self: *GenerationInventory, tables: s.Tables) !void {
        if (tables.states.len > self.states.len or tables.segments.len > self.segments.len or tables.selectors.len > self.selectors.len) return error.ResourceLimitExceeded;
        for (tables.states, 0..) |value, i| self.states[i] = @enumFromInt(value.key.id);
        for (tables.segments, 0..) |value, i| self.segments[i] = @enumFromInt(value.key.id);
        for (tables.selectors, 0..) |value, i| {
            self.selectors[i] = @enumFromInt(value.key.id);
            self.kinds[i] = .{ .id = self.selectors[i], .stochastic = switch (value.kind) {
                .weighted_random, .shuffle, .no_repeat => true,
                else => false,
            } };
        }
        self.inventory = .{ .states = self.states[0..tables.states.len], .segments = self.segments[0..tables.segments.len], .selectors = self.selectors[0..tables.selectors.len] };
    }
};
const ReloadInventory = struct {
    source: GenerationInventory,
    target: GenerationInventory,
    fn context(self: *const ReloadInventory, source_build: u64, target_build: u64) migration.ValidationContext {
        // Conservative first ownership admission requires explicit coverage of
        // the complete source catalogs, not implicit identity or guessed roots.
        return .{ .from_build_id = source_build, .to_build_id = target_build, .source = self.source.inventory, .target = self.target.inventory, .required = self.source.inventory };
    }
    fn catalogs(self: *const ReloadInventory) epoch_policy.Catalogs {
        return .{ .source = self.source.kinds[0..self.source.inventory.selectors.len], .target = self.target.kinds[0..self.target.inventory.selectors.len] };
    }
};
const policy = @import("runtime_policy.zig");
const policy_helper = @import("sme-policy-runtime");
/// Dedicated public causal fan-out. Attached/detached only at the session's
/// owned producer safe points; producer callbacks never allocate or block.
pub const CausalRoleV1 = enum { control, worker };
pub const CausalSinkV1 = struct {
    context: *anyopaque,
    permitted: *const fn (*anyopaque, CausalRoleV1) bool,
    input: *const fn (*anyopaque, trace.Input) void,
    schedule: *const fn (*anyopaque, trace.ScheduleEntry) void,
    invalidate: *const fn (*anyopaque) void,
};
/// Output-only public-value observer for the separate semantic capture path.
/// The caller pins context from attachment until successful destroyQuiescent
/// return (and its own real producer joins), or a successful pristine detach.
/// Callbacks must be bounded, allocation-free, nonblocking, and non-reentrant;
/// they own retained copies and may never mutate the engine or select outcomes.
pub const SemanticOutputSinkV1 = struct {
    context: *anyopaque,
    input: *const fn (*anyopaque, trace.Input) void,
    schedule: *const fn (*anyopaque, trace.ScheduleEntry) void,
    invalidate: *const fn (*anyopaque) void,
};
const SemanticOutputSink = SemanticOutputSinkV1;
pub const request_capacity = 32;
pub const observation_capacity = 4096;
pub const Config = assets.Config;
pub const Snapshot = struct {
    state: api.MusicRuntimeState,
    committed_state: api.MusicStateId,
    committed_segment: api.SegmentId,
    render_frame: u64,
    pending: bool,
    asset_generation: u64,
    transport_epoch: u64,
    outstanding_sample_leases: u64,
};
/// Single-use borrowed PCM ownership. Copying this value does not duplicate a
/// lease; owner access after release and token use after runtime destruction are
/// invalid. Release may run on any thread and allocates/frees no storage.
pub const SoundLease = struct {
    owner: *rt.SampleOwner,
    return_token: borrowed_sound.Token,
    pub fn release(self: SoundLease) void {
        _ = self.return_token.release();
    }
};
pub const ShutdownReport = struct { sample_leases: u64, live_instances: u64 };
const SnapshotSlot = struct { readers: std.atomic.Value(u32) = .init(0), value: Snapshot = undefined, value_v1: v1.StatusV1 = undefined };
const Operation = enum { transition, pause, resume_music, stop };
/// Accepted Control provenance and exact source binding. This follows the stop
/// action into Pending; later requests can never replace its accepted position.
const BoundaryStop = struct {
    kind: v1.BoundaryStopV1,
    accepted: trace.schema.Position,
    group: rt.GroupHandle,
    bank_generation: u64,
    source_incarnation: u64,
    segment: u64,
    transport: clock.Clock,
};
const StateRecordingGate = enum(u8) { disabled, direct, fill };
// A single prepared block owns at most two hard-cut fills and the target.
// Every prepared group transfers exactly once: to active_group on its acquired
// entry receipt, or to retired_groups on failure/cancellation. The cursor owns
// musical phase facts; group/schedule credits remain the physical authority.
const TransitionExecution = struct {
    crossfade: ?crossfade_projection.Projection = null,
    cursor: planner.PlanCursor,
    solver_owned: bool = true,
    scheduler_prefix_offset: u16 = 0,
    source_exit_cue: u64 = 0,
    fill_route: ?u64 = null,
    path_id: u64 = 0,
    groups: [assets.max_resident_fill_steps + 1]?rt.GroupHandle = @splat(null),
    // Immutable scheduler-reference inventory. Entry custody can transfer to
    // active/retired while the block still owns every stop/start reference.
    referenced_groups: [assets.max_resident_fill_steps + 2]?rt.GroupHandle = @splat(null),
    segments: [assets.max_resident_fill_steps + 1]u32 = undefined,
    // Absolute route/snapshot position, NOT StreamBinding repetition identity.
    occurrences: [assets.max_resident_fill_steps + 1]u8 = .{ 0, 1, 2 },
};
const ConfirmedFill = struct {
    group: rt.GroupHandle,
    entry: api.PhaseReceipt, // Actual acquired entry, never a planned phase.
    occurrence: u8 = 0,
    source_exit_cue: u64 = 0,
    fill_route: ?u64 = null,
    path_id: u64 = 0,
};
const FillContinuation = struct {
    generation: *Generation, // One additional real pending-plan registry credit.
    group: rt.GroupHandle, // Borrowed active physical group, never a second owner.
    suspended: ?director.SuspendedTargetEntry,
    intent: ?director.TransitionIntent = null, // Internal; no public ticket.
    resume_request: ?u64 = null, // Actual resume won; consumption waits for prepare.
};
const Pending = struct {
    // Held from before publication through actual terminal collection.
    generation: *Generation,
    block: rt.scheduler.Handle,
    plan: rt.scheduler.Handle,
    token: api.PhaseToken,
    operation: Operation,
    intent: ?director.TransitionIntent = null,
    target_group: ?rt.GroupHandle = null,
    transition: ?*TransitionExecution = null,
    operation_groups: [2]?rt.GroupHandle = @splat(null),
    source_fill: ?ConfirmedFill = null,
    phase_cursor: u16 = 0,
    receipt_cursor: u16 = 0,
    admission_seen: bool = false,
    invalidation: ?rt.scheduler.Handle = null,
    effective: bool = false,
    request_ticket: ?v1.RequestTicketV1 = null,
    continuity: ?rt.source_continuity.Handle = null,
    source_incarnation: u64 = 1,
    boundary_stop: ?BoundaryStop = null,
    boundary_failure: ?v1.FailureV1 = null,
};
const ColdStartCandidate = struct {
    generation: *assets.Generation,
    runtime_generation: u64,
    transport_epoch: u64,
    request_id: u64,
    segment_index: usize,
    entry: assets.EntryWindow,
    group: rt.GroupHandle,
    bindings: [4]planner.StreamBinding,
};
const Preparing = struct { intent: director.TransitionIntent, plan_id: u64, cold_candidate: ?ColdStartCandidate = null };
const Interruption = struct {
    ticket: v1.RequestTicketV1,
    cancelled_before_entry: ?api.PhaseReceipt = null,
};

// Control -> game owned-copy queue. Unlike numeric wire trace, a public receipt
// may contain MusicError and finite float request values; it is not serialized.
const ReceiptQueue = struct {
    values: [v1.resident_fill_hard_cut_v1.phase_receipt_slots]api.MusicReceipt = undefined,
    head: std.atomic.Value(u64) = .init(0),
    tail: std.atomic.Value(u64) = .init(0),
    fn push(self: *ReceiptQueue, value: api.MusicReceipt) bool {
        const head = self.head.load(.monotonic);
        if (head -% self.tail.load(.acquire) == self.values.len) return false;
        self.values[head % self.values.len] = value;
        self.head.store(head +% 1, .release);
        return true;
    }
    fn pop(self: *ReceiptQueue) ?api.MusicReceipt {
        const tail = self.tail.load(.monotonic);
        if (tail == self.head.load(.acquire)) return null;
        const result = self.values[tail % self.values.len];
        self.tail.store(tail +% 1, .release);
        return result;
    }
};

const LoadTransaction = struct {
    const State = enum(u8) { idle, queued, preparing, sources_queued, sources_preparing, sources_completed, retiring, retired, completed };
    state: std.atomic.Value(State) = .init(.idle),
    bytes: []u8 = &.{},
    candidate: ?*Generation = null,
    provider: ?assets.AnySourceProvider = null,
    shared_preparation: bool = false,
    initial_identity: ?generation_registry.InitialReservation = null,
    failure: ?v1.FailureV1 = null,
    cancelled: std.atomic.Value(bool) = .init(false),
    input_bytes: std.atomic.Value(u64) = .init(0),
};

const ResidentState = struct {
    const Kind = enum { capture, restore };
    kind: Kind,
    incarnation: u64,
    generation: *Generation,
    lower: ?rt.resident_transaction.Handle,
    block: ?rt.scheduler.Handle,
    plan: ?rt.scheduler.Handle,
    invalidation: ?rt.scheduler.Handle,
    terminal: bool,
    failure: ?v1.FailureV1,
    restore_ticket: ?v1.RequestTicketV1,
    accepted: bool,
    terminal_emitted: bool,
    install: ?api.PhaseReceipt,
    replacement: ?rt.GroupHandle,
    execution: ?*TransitionExecution,
    groups: rt.resident_transaction.GroupSet,
    token: api.PhaseToken,
    phase_cursor: u16,
    receipt_cursor: u16,
    admission_seen: bool,
    initial_prefix: u8,
    phase_count: u8,
    scheduler_prefix_offset: u16,
    phases: [3]planner.Phase,
    occurrences: [3]u8,
    source_present: bool,
    clock: clock.Clock,
    bar_offset: u64,
    fill_occurrence: ?u8,
    physical_path_id: u64,
    physical_fill_route: ?u64,
    source_exit_cue: u64,
    fill_route: ?u64,
    path_id: u64,
    position: trace.schema.Position,
    cancel_requested: bool,
    baseline: director.ResidentCaptureBaseline,
    decoded: save.Decoded,
    snapshot: save.SnapshotV1,
    staging: director.ResidentImportStaging,
    anchor: director.ResidentImportAnchor,
    restored_clock: clock.Clock,
    restored_bar_offset: u64,
    continuation_credit: bool,
    profile: v1.SnapshotProfileV1,
    restore_stage: enum { queued, accepted, opening, prefetching, ready, published, installed, rejected, drained },
    restore_epoch: u64,
    request_windows_owned: bool,
    drain_groups: rt.resident_transaction.GroupSet,
};

/// One result/transaction owns its exact old and candidate resources until
/// lower receipt and physical retirement have both been reconciled.
const LiveReload = struct {
    ticket: v1.RequestTicketV1 = undefined,
    staging_ticket: reload_staging.Ticket = undefined,
    source: *Generation,
    map: migration.MigrationMapV1,
    rules: epoch_policy.RuntimeMigrationPolicyV1,
    options: live_reload_contract.Options,
    rollback: bool,
    streamed: bool = false,
    stream_stage: enum { validated, source_bound, windows_preparing, published } = .validated,
    frozen_frame: u64 = 0,
    frozen_bar: u64 = 0,
    frozen_cursor: u64 = 0,
    frozen_loop_epoch: u64 = 0,
    frozen_transport_epoch: u64 = 0,
    frozen_source_segment: u64 = 0,
    target_segment_index: u32 = 0,
    request_windows_owned: bool = false,
    outgoing_released: bool = false,
    eviction_cursor: usize = 0,
    accepted: bool = false,
    terminal_emitted: bool = false,
    result: live_reload_contract.Poll = .pending,
    position: trace.schema.Position = undefined,
    lower: ?rt.resident_transaction.Handle = null,
    block: ?rt.scheduler.Handle = null,
    plan: ?rt.scheduler.Handle = null,
    invalidation: ?rt.scheduler.Handle = null,
    replacement: ?rt.GroupHandle = null,
    old_group: ?rt.GroupHandle = null,
    token: api.PhaseToken = undefined,
    staged: director.ResidentReloadStaging = undefined,
    transport: clock.Clock = undefined,
    bar_offset: u64 = 0,
    retention_plan: retention.RetentionPlan = undefined,
    receipt_cursor: u16 = 0,
    admission_seen: bool = false,
    committed: bool = false,
    cancel_requested: bool = false,
    resource_size: u64,
    resource_hash: [32]u8,
    target_identity: ?trace.schema.lifecycle.BankIdentity = null,
    migration_resource: ?trace.schema.lifecycle.MigrationResource = null,
    // Owned fixed-size projection is included in retained-byte accounting.
    // Its storage may remain until acknowledgement after candidate cleanup;
    // read bindings only while both banks live and validation has succeeded.
    // Cleanup never dereferences the projection's former bank bindings.
    migration_projection: director.resident_migration.Projection = .{},
};

/// Exclusive same-generation audition owner. Main ingress credits stay here
/// until the real lower outcome; storage/lease survives terminal until windows drain.
const PreviewSeek = struct {
    ticket: v1.RequestTicketV1,
    generation: *Generation,
    position: trace.schema.Position,
    old_group: rt.GroupHandle,
    segment_index: u32,
    target: u64,
    old_transport_epoch: u64,
    new_transport_epoch: u64,
    mutation_epoch: u64,
    replacement: ?rt.GroupHandle = null,
    drain_group: ?rt.GroupHandle = null,
    lower: ?rt.resident_transaction.Handle = null,
    block: ?rt.scheduler.Handle = null,
    plan: ?rt.scheduler.Handle = null,
    invalidation: ?rt.scheduler.Handle = null,
    token: api.PhaseToken = undefined,
    staged: director.PreviewSeekStaging = undefined,
    transport: clock.Clock = undefined,
    bar_offset: u64 = 0,
    phase_cursor: u16 = 0,
    receipt_cursor: u16 = 0,
    admission_seen: bool = false,
    published: bool = false,
    cancel_requested: bool = false,
    committed: bool = false,
    terminal: bool = false,
    failure: ?v1.FailureV1 = null,
    executed_phase: ?api.PhaseReceipt = null,
};

const DeviceRecovery = struct {
    loss: device_recovery.Loss,
    clock: ?clock.Clock = null,
    physical: ?rt.resident_transaction.Physical = null,
    compatible: bool = false,
    // Resident compatibility still controls resume. Streams admit restart only.
    stream_restart_compatible: bool = false,
    generation: u64 = 0,
    segment: u32 = 0,
    block: ?rt.scheduler.Handle = null,
    plan: ?rt.scheduler.Handle = null,
    group: ?rt.GroupHandle = null,
    token: api.PhaseToken = undefined,
    phase_cursor: u16 = 0,
    receipt_cursor: u16 = 0,
    admission_seen: bool = false,
    transport: ?clock.Clock = null,
    interrupted_by_loss: bool = false,
    source_pending: bool = true,
    generation_owner: ?*Generation = null,
    source_bar_offset: u64 = 0,
    restart_bar_offset: u64 = 0,
    restart_logical_bar: u64 = 0,
};

/// Exact lineage of the owner's first real DIRECT entry. Later ordinary group
/// changes cannot regain eligibility by reusing source or transport numbers.
const DeviceStreamOrigin = struct { generation: u64, group: rt.GroupHandle };

/// Separate from the musical basis: an interrupted attempt retains every exact
/// owner until real schedule, group, Worker and visibility acknowledgements.
const DeviceStreamCandidate = struct {
    window_id: u64,
    generation: *Generation,
    origin: DeviceStreamOrigin,
    device_epoch: u64,
    stage: enum { opening, ready, scheduled, retiring } = .opening,
    preparation_lease: bool = true,
    pending_lease: bool = false,
    group: ?rt.GroupHandle = null,
    drain_group: ?rt.GroupHandle = null,
    block: ?rt.scheduler.Handle = null,
    plan: ?rt.scheduler.Handle = null,
    invalidation: ?rt.scheduler.Handle = null,
    cleanup_stop: ?rt.scheduler.Handle = null,
    cancel_requested: bool = false,
    published: bool = false,
    committed: bool = false,
    windows_opened: bool = false,
    token: api.PhaseToken = undefined,
    phase_cursor: u16 = 0,
    receipt_cursor: u16 = 0,
    admission_seen: bool = false,
    transport: clock.Clock = undefined,
    logical_bar: u64 = 0,
    bar_offset: u64 = 0,
};

/// Heap-stable, one serialized Control owner, one serialized ingress producer.
/// submit is bounded/nonblocking; concurrent producers are explicitly rejected.
/// ControlRuntime and RuntimeRenderer must outlive this object and keep addresses.
pub const MusicRuntime = struct {
    /// Deterministic qualification barriers; absent from production storage.
    pub const CollectStage = enum { after_frame_observation, after_schedule_result, after_phase_poll, before_group_release };
    pub const CollectHook = struct { context: *anyopaque, call: *const fn (*anyopaque, CollectStage) void };
    pub const TickStage = enum { after_prepare, before_music_publish, after_music_publish, before_stream_supply, before_stream_readiness, after_stream_readiness, before_recovery_supply, before_recovery_readiness, after_recovery_readiness, before_crossfade_source_observation, before_schedule_prepare, after_schedule_prepare, before_operation_schedule_prepare, after_operation_schedule_prepare, before_loop_crossfade_publish, before_background_supply, after_background_supply };
    pub const TickHook = struct { context: *anyopaque, call: *const fn (*anyopaque, TickStage) void };
    const TickEntry = enum { idle, collecting, collected, preparing, prepared, failed, publishing, published };
    pub const LiveTickDeferV1 = struct {
        stage: enum { entry_supply, entry_readiness, recovery_supply, recovery_readiness, background_supply },
        control_tick: u64,
        accepted_control_frame: u64,
        observation: rt.streaming.stream.LiveObservationDeferV1,
    };
    /// A real pre-allocation Stop admission raced the Render horizon. Its
    /// accepted ticket remains owned; this is never a request/Render terminal.
    pub const LiveStopDeferV1 = struct {
        control_tick: u64,
        accepted_control_frame: u64,
        ticket: v1.RequestTicketV1,
        group: rt.GroupHandle,
        plan_id: u64,
        prepare: rt.scheduler.LivePrepareLateV1,
    };
    pub const LiveColdStartDeferV1 = LiveStopDeferV1;
    pub const LiveControlTickOutcomeV1 = struct { drained: usize, deferred: ?LiveTickDeferV1 = null, stop_deferred: ?LiveStopDeferV1 = null, cold_start_deferred: ?LiveColdStartDeferV1 = null };
    pub const LiveTickPreparationV1 = struct { deferred: ?LiveTickDeferV1 = null, stop_deferred: ?LiveStopDeferV1 = null, cold_start_deferred: ?LiveColdStartDeferV1 = null };
    const LiveTickAttempt = LiveTickPreparationV1;
    /// Internal actual prepared-slot custody; no public reload transaction.
    pub const GroupGenerationCredit = struct {
        context: u64,
        runtime_generation: u64,
        registry: generation_registry.Handle,
        group: rt.GroupHandle,
        layer_controller: bool = false,
        layer_controller_count: u8 = 0,
    };
    pub const snapshot_credit_capacity = generation_registry.capacity;
    pub const SnapshotGenerationCredit = struct {
        context: u64,
        runtime_generation: u64,
        registry: generation_registry.Handle,
        slot_index: u8,
        snapshot_generation: u64,
    };
    group_generation_credits: [rt.music_group.max_groups]?GroupGenerationCredit = @splat(null),
    allocator: std.mem.Allocator,
    control: *rt.ControlRuntime,
    renderer: *rt.RuntimeRenderer,
    generation: ?*Generation = null,
    layer_config: ?layer_owner.OwnedConfig = null,
    crossfade_config: ?@import("sme-runtime-crossfade-contract").OwnedConfig = null,
    // Published only after startup adoption; cleared before generation free.
    worker_generation: std.atomic.Value(?*Generation) = .init(null),
    // One publication, read only after Worker claims worker_guard. Control
    // clears it and acquires that same guard before releasing pointer custody.
    outgoing_generation: std.atomic.Value(?*Generation) = .init(null),
    worker_failure: std.atomic.Value(u8) = .init(0),
    // Compatibility observation alias, never an additional allocation owner.
    owned_streaming: ?*rt.streaming.Service = null,
    service_custody: ?assets.ServiceCustody = null,
    worker_streaming: std.atomic.Value(?*rt.streaming.Service) = .init(null),
    control_torn_down: bool = false,
    event_adapter: ?*audio.events.RuntimeAdapterV1 = null,
    policy_storage: ?*policy.Storage = null,
    policy_render_permitted: std.atomic.Value(bool) = .init(false),
    config: Config,

    resident_state: ?*ResidentState = null,
    live_reload: ?*LiveReload = null,
    preview_seek: ?*PreviewSeek = null,
    device_event: ?struct { loss: device_recovery.Loss, token: rt.RuntimeRenderer.DeviceQuiescence } = null,
    device_recovery_state: ?DeviceRecovery = null,
    device_stream_candidate: ?DeviceStreamCandidate = null,
    next_device_window_id: u64 = 1,
    device_status: device_recovery.Status = .{},
    device_accepted_epoch: std.atomic.Value(u64) = .init(1),
    resident_incarnation: u64 = 0,
    bank_resource_size: u64 = 0,
    bank_resource_hash: [32]u8 = @splat(0),
    bar_offset: u64 = 0,
    state: api.MusicRuntimeState = .ready,
    active_group: ?rt.GroupHandle = null,
    // Borrowed retirement custody. Cleared only after real lower release.
    crossfade_outgoing: ?rt.GroupHandle = null,
    confirmed_fill: ?ConfirmedFill = null,
    active_source_incarnation: u64 = 0,
    rendering_segment: u64 = 0,
    last_source_switch: ?v1.SourceSwitchV1 = null,
    source_switch_count: u64 = 0,
    source_switch_history: [rt.music_group.max_groups]?v1.SourceSwitchV1 = @splat(null),
    switched_source_retirements: [rt.music_group.max_groups]?rt.GroupHandle = @splat(null),
    last_stream_fault: ?v1.StreamFaultV1 = null,
    stream_fault_detail: ?rt.StreamFault = null,
    stream_fault_count: u64 = 0,
    stream_fault_details_dropped: u64 = 0,
    retired_groups: [rt.music_group.max_groups]?rt.GroupHandle = @splat(null),
    pending: ?Pending = null,
    preparing: ?Preparing = null,
    fill_continuation: ?FillContinuation = null,
    cleanup_stop_pending: bool = false, // Durable until actual stop/physical drain.
    resuming_request: ?u64 = null,
    paused_coordinate: ?rt.music_group.ContinuityCoordinate = null,
    action: ?Operation = null,
    // Explicit provenance: lifecycle stops have no external request ticket.
    action_ticket: ?v1.RequestTicketV1 = null,
    action_boundary_stop: ?BoundaryStop = null,
    request_guard: std.atomic.Value(bool) = .init(false),
    queue: [request_capacity]api.MusicRequest = undefined,
    queue_count: usize = 0,
    last_submitted: u64 = 0,
    next_plan_id: u64 = 1,
    tick: u64 = 0,
    control_frame: u64 = 0,
    collected_call_sequence: u64 = 0,
    input_order: u64 = 0,
    latest_request_position: trace.schema.Position = .{ .accepted_control_frame = 0, .control_tick = 0, .input_order = 0 },
    observations: [observation_capacity]trace.ScheduleEntry = undefined,
    observation_count: usize = 0,
    observation_base: u64 = 0,
    observation_lost: u64 = 0,
    // Fixed Control scratch lives in this heap-stable owner, not the small
    // execution thread's stack. The Control guard gives it one serialized user.
    decision_records: [512]trace.ScheduleRecord = undefined,
    planner_records: [64]trace.ScheduleEntry = undefined,
    inputs: [observation_capacity]trace.Input = undefined,
    input_count: usize = 0,
    input_base: u64 = 0,
    input_lost: u64 = 0,
    trace_counter_exhausted: bool = false,
    replay_unsupported: bool = false,
    receipts: ReceiptQueue = .{},
    group_events: rt.MusicGroupTrace = .{},
    incomplete: bool = false,
    shutdown_requested: std.atomic.Value(bool) = .init(false),
    control_guard: std.atomic.Value(bool) = .init(false),
    snapshots: [3]SnapshotSlot = @splat(.{}),
    published_snapshot: std.atomic.Value(u8) = .init(0),
    replay_failed: bool = false,
    public_recording: public_replay.Capture = .{},
    causal_driver_pin: ?*anyopaque = null,
    causal_sink: ?CausalSinkV1 = null,
    // Sole Control-owned immutable borrow; Worker/Render never read this field.
    semantic_output_sink: ?SemanticOutputSink = null,
    // MPSC ingress reads only atomic profile/ticket gates, never recorder state.
    direct_state_recording: std.atomic.Value(StateRecordingGate) = .init(.disabled),
    direct_state_busy: std.atomic.Value(bool) = .init(false),
    // Profile-7 raw callers, including foreign receipt consumers, touch only
    // these atomics. Control alone owns the journal and recorder state.
    context_recording_gate: std.atomic.Value(bool) = .init(false),
    context_recording_violation: std.atomic.Value(bool) = .init(false),
    context_raw_callers: std.atomic.Value(u32) = .init(0),
    context_host_journal: context_host.Journal = .{},
    test_collect_hook: if (@import("builtin").is_test) ?CollectHook else void = if (@import("builtin").is_test) null else {},
    /// Test-only simulation of a temporarily unavailable coherent observation.
    /// It never supplies a switch fact, cursor, epoch or receipt.
    test_source_observation_unavailable: if (@import("builtin").is_test) bool else void = if (@import("builtin").is_test) false else {},

    mode: enum { compatibility, versioned } = .compatibility,
    config_v1: v1.ConfigV1 = .{},
    control_thread: std.Thread.Id,
    worker_guard: std.atomic.Value(bool) = .init(false),
    worker_thread: ?std.Thread.Id = null,
    load: LoadTransaction = .{},
    reload: reload_staging.Slot(Generation) = .{},
    reload_provider: ?assets.AnySourceProvider = null,
    generations: GenerationRegistry = .{},
    // Allocated separately; never points back into this runtime. Freed LAST on
    // Control, after every releasing thread's final returned publication.
    borrowed_sounds: *borrowed_sound.Anchor,
    reload_map: ?migration.MigrationMapV1 = null,
    reload_epoch_policy: ?epoch_policy.RuntimeMigrationPolicyV1 = null,
    next_load: u64 = 1,
    handle_incarnation: u32 = 0,
    load_ticket: ?v1.LoadTicketV1 = null,
    load_status: v1.LoadStatusV1 = .pending,
    last_error: ?v1.FailureV1 = null,
    ingress: ingress.Ingress,
    admission_handle: std.atomic.Value(u32) = .init(0),
    admission_generation: std.atomic.Value(u64) = .init(0),
    active_producers: std.atomic.Value(u32) = .init(0),
    in_flight: ?v1.RequestTicketV1 = null,
    /// One gain request may coexist with a published single-fill transition.
    /// Its receipt and M2 physical custody remain independent of target entry.
    layer_in_flight: ?v1.RequestTicketV1 = null,
    interruption: ?Interruption = null,
    tick_scope: ?rt.ControlRuntime.TickV1 = null,
    tick_entry: TickEntry = .idle,
    /// Session ownership only, never observation/error provenance. A new live
    /// session starts from a clean ready owner; interleaved legacy ticks cannot
    /// import an unreviewed preparation or action into this narrow driver.
    live_tick_control_stamp: ?u64 = null,
    /// Proven frontier for this owner lifetime, not another Render read.
    /// Set only by admitted chronology observations; thereafter never reset by
    /// Stop, bank/source retirement, an empty tick, or a legacy cleanup tick.
    /// A fresh MusicRuntime starts a fresh identity and resets this to null.
    live_chronology_frontier: ?u64 = null,
    /// Explicit profile-9 startup binding, inherited by the first real Service.
    live_semantic_service_hooks: ?rt.streaming.stream.LiveSemanticHooks = null,
    test_tick_hook: if (@import("builtin").is_test) ?TickHook else void = if (@import("builtin").is_test) null else {},
    unloading: bool = false,
    has_executed: bool = false,
    device_stream_entry_seen: bool = false,
    device_stream_origin: ?DeviceStreamOrigin = null,
    observer_storage: ?*observer.Storage = null,
    observer_handle: ?observer.Handle = null,
    observation_sequence: u64 = 0,
    dropped_observations: u64 = 0,
    test_load_hook: if (@import("builtin").is_test) ?LoadHook else void = if (@import("builtin").is_test) null else {},
    // Internal first-slice fixture only. The shipping owner cannot install it.
    test_live_bootstrap: if (@import("builtin").is_test) ?*assets.TestLiveBootstrap.Session else void = if (@import("builtin").is_test) null else {},
    test_finalization: if (@import("builtin").is_test) ?*TestFinalization.Session else void = if (@import("builtin").is_test) null else {},
    test_finalization_nonce: if (@import("builtin").is_test) u64 else void = if (@import("builtin").is_test) 0 else {},
    /// Test-only actual boundary; shipping Host and capture admission do not use
    /// this adapter. Its fixed fixture registers before any Worker/load exists.
    pub const FinalizationTests = if (@import("builtin").is_test) struct {
        pub const Session = TestFinalization.Session;
        pub const Hooks = assets.TestLiveBootstrap.Hooks;
        pub const NativeHooks = assets.TestLiveBootstrap.Native.Hooks;
        pub const ServiceBirth = assets.TestLiveBootstrap.Native.ServiceBirth;
        pub const JoinedClock = rt.streaming.stream.TestJoinedClock;
        pub const Adapter = TestFinalization.Adapter;
        pub const Capability = TestFinalization.Capability;
        pub const Park = TestFinalization.Park;
        pub const HostIdentity = TestFinalization.HostIdentity;
        pub const Outcome = TestFinalization.Outcome;
        pub const Report = ShutdownReport;
        pub const TickMode = TestFinalization.TickMode;
        pub const TickStage = TestFinalization.TickStage;
        pub const TickRequest = TestFinalization.TickRequest;
        pub fn bind(self: *MusicRuntime, session: *Session, adapter: Adapter) !void {
            if (self.renderer.test_render_admission_hook != null or self.renderer.test_owned_render_facts != null or self.control.test_owned_control_facts != null) return error.InvalidState;
            try self.claimControlV1();
            defer self.control_guard.store(false, .release);
            if (!self.usesIntegratedTickV1() or self.config_v1.kind != .authoring or self.config_v1.streaming_reservation != .initial_bank_only or
                self.state != .uninitialized or self.shutdown_requested.load(.acquire) or self.worker_thread != null or self.worker_guard.load(.acquire) or
                self.generation != null or self.owned_streaming != null or self.service_custody != null or self.worker_streaming.load(.acquire) != null or
                self.worker_generation.load(.acquire) != null or self.outgoing_generation.load(.acquire) != null or self.test_live_bootstrap != null or
                self.load.state.load(.acquire) != .idle or self.load_ticket != null or self.load.candidate != null or self.next_load != 1 or
                self.control.music_runtime != self or self.renderer.runtime != self.control or self.renderer.music_trace != &self.group_events or
                self.renderer.device_callbacks_active.load(.acquire) or self.renderer.device_access.load(.acquire) != 0 or
                self.renderer.callObservation().sequence != 0 or self.renderer.renderFrame() != 0 or
                self.control.stream_control_tick != 0 or self.control.scheduled.render_frame.load(.acquire) != 0 or
                self.causal_sink != null or self.causal_driver_pin != null or self.public_recording.phase != .disabled or self.test_finalization_nonce != 0) return error.InvalidState;
            try session.register(self, &self.test_finalization, adapter);
        }
        pub fn bindJoined(self: *MusicRuntime, session: *Session, bootstrap: *assets.TestLiveBootstrap.Session, adapter: Adapter, roles: rt.capture_order.Roles, bytes: []const u8, provider: assets.SourceProvider, quiescence: rt.RuntimeRenderer.DeviceQuiescence) !void {
            return bindJoinedHooks(self, session, bootstrap, adapter, roles, bytes, provider, quiescence, null);
        }
        pub fn bindJoinedHooks(self: *MusicRuntime, session: *Session, bootstrap: *assets.TestLiveBootstrap.Session, adapter: Adapter, roles: rt.capture_order.Roles, bytes: []const u8, provider: assets.SourceProvider, quiescence: rt.RuntimeRenderer.DeviceQuiescence, hooks: ?Hooks) !void {
            try self.claimControlV1();
            defer self.control_guard.store(false, .release);
            try BootstrapTests.validateStartup(self, bytes, quiescence);
            try TestFinalization.validateJoinedControlHooks(self.control);
            if (hooks) |value| {
                try value.validateInitial();
                if (value.native != null) try assets.TestLiveBootstrap.Native.validateStartup(self.control, self.renderer, &self.group_events);
            }
            if (adapter.validate_startup == null or adapter.validate_borrows == null or adapter.clear_borrows == null or adapter.validate_empty == null) return error.InvalidState;
            try bootstrap.validateIssue(&self.test_live_bootstrap, roles);
            try session.validateRegister(&self.test_finalization, adapter);
            // The fixed registration callback performs every check before its
            // own commit. Nothing after it can fail or leave half-registration.
            try adapter.register(adapter.identity.context, self, session, adapter.identity);
            session.commitRegister(self, &self.test_finalization, adapter);
            bootstrap.commitIssue(self, &self.test_live_bootstrap, self.control, self.renderer, self.config.context, roles, bytes, provider);
            bootstrap.combined = session;
            session.bootstrap = bootstrap;
            session.startup_quiescence = quiescence;
            bootstrap.commitHooks(hooks, &self.group_events);
        }
        pub fn tick(self: *MusicRuntime, request_value: TickRequest) !LiveControlTickOutcomeV1 {
            return tickOwned(self, request_value, false);
        }
        /// Private fixed independent Host only; public/serialized entries stay strict.
        pub fn hostTick(self: *MusicRuntime, request_value: TickRequest) !LiveControlTickOutcomeV1 {
            return tickOwned(self, request_value, true);
        }
        fn tickOwned(self: *MusicRuntime, request_value: TickRequest, comptime host: bool) !LiveControlTickOutcomeV1 {
            if (request_value.owner != self or request_value.session.adapter == null or
                request_value.session.adapter.?.tick_kind != (if (host) .independent_host else .serialized)) return error.InvalidState;
            try request_value.session.enterTickOwner(request_value);
            defer request_value.session.returnedTick(request_value);
            try self.checkControlV1();
            try self.claimControlV1();
            defer {
                self.tick_scope = null;
                self.tick_entry = .idle;
                self.control_guard.store(false, .release);
            }
            try validateTickProfileOwned(self, request_value.session, request_value.mode, host);
            const before = self.control.stream_control_tick;
            defer if (self.control.stream_control_tick != before) {
                self.live_tick_control_stamp = self.control.stream_control_tick;
            };
            if (host) return rt.ControlRuntime.JoinedTickTests.hostCall(self.control, self, request_value);
            return rt.ControlRuntime.JoinedTickTests.call(self.control, self, request_value);
        }
        pub fn validateTickProfile(self: *MusicRuntime, session: *Session, mode: TickMode) !void {
            return validateTickProfileOwned(self, session, mode, false);
        }
        pub fn validateHostTickProfile(self: *MusicRuntime, session: *Session, mode: TickMode) !void {
            return validateTickProfileOwned(self, session, mode, true);
        }
        fn validateTickProfileOwned(self: *MusicRuntime, session: *Session, mode: TickMode, comptime host: bool) !void {
            if (session.adapter == null or session.adapter.?.tick_kind != (if (host) .independent_host else .serialized)) return error.InvalidState;
            if (!host and (self.renderer.test_render_admission_hook != null or self.renderer.test_owned_render_facts != null or self.control.test_owned_control_facts != null)) return error.InvalidMode;
            if (self.control_torn_down or session.phase.load(.acquire) != .registered) return error.InvalidMode;
            const bootstrap = try session.validateJoined(self);
            if (bootstrap.hooks == null) return error.InvalidState;
            const service = self.owned_streaming orelse return error.InvalidState;
            if (host) try session.validatePublishedBorrowSet(self, service) else try session.validateBorrowSet(self, service);
            if (self.control.streaming_service != service or !service.runtime_attached or service.public_causal_exclusion != null or
                service.test_consumed_hook != null or service.test_readiness_hook != null or service.test_availability_hook != null or
                service.test_supply_hook != null or service.test_supply_return_hook != null or service.test_worker_clock_observer != null or service.test_frontier_hook != null or service.test_worker_hook != null or
                service.test_worker_stage_hook != null or service.test_publication_hook != null) return error.InvalidMode;
            if (self.test_collect_hook != null or self.test_tick_hook != null or self.test_load_hook != null or
                self.test_source_observation_unavailable or self.ingress.test_hook != null or self.observer_storage != null or self.observer_handle != null or
                self.control.voice_binding_test_hook != null or self.control.normal.test_hook != null or self.control.reserved.test_hook != null or
                (!host and (self.control.prerequisite_terminal_order != null or self.control.public_causal_group_terminal_sink != null or
                    self.control.public_causal_group_source_final_sink != null)) or self.control.offline_causal_group_terminal != null or
                self.control.scheduled.test_hook != null or self.control.scheduled.test_publication_hook != null or
                (!host and (self.control.scheduled.prerequisite_order != null or self.control.scheduled.public_causal_publication_sink != null or
                    self.control.scheduled.public_causal_progress_sink != null or self.control.scheduled.control_sink != null or self.renderer.prerequisite_order != null)) or
                self.control.scheduled.offline_causal_replay != null or self.renderer.offline_causal_replay != null or
                self.renderer.test_device_registration_hook != null or self.renderer.test_group_release_hook != null or self.renderer.test_play_release_hook != null)
                return error.InvalidMode;
            if (mode == .playback) try self.validateLiveTickModeProfileV1(true, host) else try self.validateChronologyCleanupProfileV1(true, host);
        }
        pub fn destroyEmpty(self: *MusicRuntime, session: *Session, park: ?Park, quiescence: rt.RuntimeRenderer.DeviceQuiescence) !Report {
            if ((self.renderer.test_render_admission_hook != null or self.renderer.test_owned_render_facts != null or self.control.test_owned_control_facts != null) and !session.hasNativeBorrow()) return error.InvalidState;
            try self.checkControlIdentityV1();
            try session.validateEmptyRequest(self, park, quiescence);
            if (self.generation != null or self.owned_streaming != null or self.service_custody != null or
                self.worker_streaming.load(.acquire) != null or self.worker_generation.load(.acquire) != null or self.outgoing_generation.load(.acquire) != null or
                self.load.state.load(.acquire) != .idle or self.load.candidate != null or self.load_ticket != null or self.load.bytes.len != 0 or self.load.input_bytes.load(.acquire) != 0 or
                self.generations.count() != 0 or self.reload.ownsResources() or self.live_reload != null or self.active_producers.load(.acquire) != 0 or
                self.context_raw_callers.load(.acquire) != 0 or self.borrowed_sounds.outstanding != 0 or self.renderer.device_callbacks_active.load(.acquire)) return error.DrainPending;
            for (&self.snapshots) |*slot| if (slot.readers.load(.acquire) != 0) return error.DrainPending;
            return self.destroyQuiescentOwned(.test_empty, .{ .session = session, .park = park, .quiescence = quiescence });
        }
        pub fn prepare(self: *MusicRuntime, session: *Session, park: Park, quiescence: rt.RuntimeRenderer.DeviceQuiescence) !Outcome {
            const phase = session.phase.load(.acquire);
            if (phase != .registered and phase != .issued) return error.InvalidState;
            return self.destroyQuiescentOwned(.test_staged, .{ .session = session, .park = park, .quiescence = quiescence });
        }
        pub fn finalize(self: *MusicRuntime, capability: Capability) !Outcome {
            try self.checkControlIdentityV1();
            const session = self.test_finalization orelse return error.InvalidState;
            // Validate complete identity before acquiring or changing any state.
            try session.validateCapability(self, &self.test_finalization, capability);
            {
                if (self.control_guard.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.DrainPending;
                defer self.control_guard.store(false, .release);
                if (self.worker_guard.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.DrainPending;
                defer self.worker_guard.store(false, .release);
                try self.validateFinalizationBoundary(session, capability.service);
                try session.validateCapability(self, &self.test_finalization, capability);
                // Session enters irreversible sealing BEFORE the adapter runs.
                // An error even after its actual stopped store retains custody.
                if (session.phase.load(.acquire) != .borrow_ended) {
                    try session.seal(capability);
                    if (session.bootstrap != null) {
                        session.endBorrowSet();
                        if (session.adapter.?.after_borrow_end) |fault| try fault(session.adapter.?.identity.context);
                    }
                }
            }
            return self.destroyQuiescentOwned(.test_staged, .{ .session = session, .park = capability.park, .quiescence = capability.quiescence });
        }
    } else struct {};

    pub const BootstrapTests = if (@import("builtin").is_test) struct {
        pub const Session = assets.TestLiveBootstrap.Session;
        /// Actual fixture boundary: createV1 completed, no Worker thread or
        /// backend callback has started, and all backing storage stays pinned
        /// through real fixture Worker/Control destruction and join.
        pub fn bind(self: *MusicRuntime, session: *Session, roles: rt.capture_order.Roles, bytes: []const u8, provider: assets.SourceProvider) !void {
            try self.claimControlV1();
            defer self.control_guard.store(false, .release);
            try validateStartup(self, bytes, null);
            try session.issue(self, &self.test_live_bootstrap, self.control, self.renderer, self.config.context, roles, bytes, provider);
        }
        fn validateStartup(self: *MusicRuntime, bytes: []const u8, quiescence: ?rt.RuntimeRenderer.DeviceQuiescence) !void {
            if (self.renderer.test_render_admission_hook != null or self.renderer.test_owned_render_facts != null or self.control.test_owned_control_facts != null) return error.InvalidState;
            if (!self.usesIntegratedTickV1() or self.config_v1.kind != .authoring or self.config_v1.streaming_reservation != .initial_bank_only or
                self.config_v1.policy_support != .disabled or self.config_v1.crossfade.bindings.len != 0 or self.config_v1.layer_gain.bindings.len != 0 or
                self.config_v1.preview_seek != null or self.config_v1.boundary_stop != null or self.config_v1.snapshot_profile != .resident_v1 or
                self.config_v1.sfx_generation_custody != .untracked or self.config_v1.streamed_fill_mode != .full_span or
                self.state != .uninitialized or self.shutdown_requested.load(.acquire) or self.worker_thread != null or self.worker_guard.load(.acquire) or
                self.generation != null or self.owned_streaming != null or self.service_custody != null or self.worker_streaming.load(.acquire) != null or
                self.worker_generation.load(.acquire) != null or self.outgoing_generation.load(.acquire) != null or
                self.load.state.load(.acquire) != .idle or self.load_ticket != null or self.load.candidate != null or self.load.provider != null or
                self.next_load != 1 or self.handle_incarnation != 0 or self.active_group != null or self.pending != null or self.preparing != null or
                self.in_flight != null or self.action != null or self.queue_count != 0 or self.active_producers.load(.acquire) != 0 or
                self.ingress.occupied.load(.acquire) != 0 or self.renderer.callObservation().sequence != 0 or self.renderer.renderFrame() != 0 or
                self.control.stream_control_tick != 0 or self.control.scheduled.render_frame.load(.acquire) != 0 or
                self.control.music_runtime != self or self.renderer.runtime != self.control or self.renderer.music_trace != &self.group_events or
                self.control.streaming_service != null or self.renderer.device_callbacks_active.load(.acquire) or self.renderer.device_access.load(.acquire) != (if (quiescence != null) @as(u8, 2) else @as(u8, 0)) or
                self.public_recording.phase != .disabled or self.causal_sink != null or self.causal_driver_pin != null or
                self.control.control_frontier_binding != null or self.control.stream_acceptance_binding != null or self.control.readiness_binding != null or
                self.control.offline_causal_replay != null or self.control.prerequisite_order != null or self.control.prerequisite_terminal_order != null or
                self.control.public_causal_group_terminal_sink != null or self.control.public_causal_group_source_final_sink != null or self.control.offline_causal_group_terminal != null or
                self.renderer.prerequisite_order != null or self.renderer.offline_causal_replay != null or self.renderer.render_causal_binding != null or
                self.event_adapter != null or self.control.source_continuity_manager != null or self.test_load_hook != null or
                bytes.len == 0 or bytes.len > self.config_v1.capacity.max_bank_bytes) return error.InvalidState;
            if (self.test_finalization != null or self.test_live_bootstrap != null or self.test_finalization_nonce != 0) return error.InvalidState;
            if (quiescence) |token| try self.renderer.validateDeviceQuiescence(token);
        }
    } else struct {};

    pub const IngressStage = ingress.Stage;
    pub const IngressHook = ingress.Hook;
    pub const LoadStage = enum { claimed, prepared };
    pub const LoadHook = struct { context: *anyopaque, call: *const fn (*anyopaque, LoadStage) void };

    pub fn create(allocator: std.mem.Allocator, control: *rt.ControlRuntime, renderer: *rt.RuntimeRenderer, compiled: []const u8, config: Config) !*MusicRuntime {
        if (control.music_runtime != null or control.scheduled.context_id != 0 or renderer.runtime != control or renderer.music_trace != null or config.context == 0 or config.quantum_frames == 0 or renderer.renderFrame() != 0 or !control.accepting.load(.acquire)) return error.InvalidState;
        if (renderer.mixer.sample_rate != s.sample_rate or renderer.mixer.output_layout.kind != .stereo) return error.UnsupportedCapability;
        try audio.device.RuntimeFixedQuantumAdapter.validateConfig(renderer, config.quantum_frames, 2);
        const generation = try Generation.prepare(allocator, compiled);
        errdefer generation.destroy();
        try generation.activate(config);
        const self = try allocate(allocator, control, renderer, config);
        errdefer {
            allocator.destroy(self.borrowed_sounds);
            allocator.destroy(self);
        }
        const handle = try self.generations.adoptInitial(generation, .{ .build_id = buildId(generation.loaded.content_hash), .content_hash = generation.loaded.content_hash }, @enumFromInt(generation.runtime_generation));
        generation.registered(&self.generations, handle);
        self.generation = generation;
        self.state = .ready;
        self.attach();
        return self;
    }

    fn allocate(allocator: std.mem.Allocator, control: *rt.ControlRuntime, renderer: *rt.RuntimeRenderer, config: Config) !*MusicRuntime {
        const self = try allocator.create(MusicRuntime);
        errdefer allocator.destroy(self);
        const anchor = try allocator.create(borrowed_sound.Anchor);
        anchor.* = .{};
        // These large trace arrays stay on the heap, never on a Control stack.
        @memset(std.mem.asBytes(self), 0);
        self.allocator = allocator;
        self.control = control;
        self.renderer = renderer;
        self.config = config;
        self.collected_call_sequence = renderer.callObservation().sequence;
        self.state = .uninitialized;
        self.next_plan_id = 1;
        self.next_device_window_id = 1;
        self.device_stream_entry_seen = false;
        self.device_stream_origin = null;
        self.config_v1 = .{};
        self.public_recording = .{};
        self.direct_state_recording = .init(.disabled);
        self.direct_state_busy = .init(false);
        self.context_recording_gate = .init(false);
        self.context_recording_violation = .init(false);
        self.context_raw_callers = .init(0);
        self.context_host_journal = .{};
        self.receipts = .{};
        self.group_events = .{};
        self.request_guard = .init(false);
        self.control_thread = std.Thread.getCurrentId();
        self.load = .{};
        self.worker_generation = .init(null);
        self.outgoing_generation = .init(null);
        self.worker_streaming = .init(null);
        self.worker_failure = .init(0);
        self.reload = .{};
        self.device_status = .{};
        self.device_accepted_epoch = .init(1);
        self.generations = .{};
        self.borrowed_sounds = anchor;
        self.policy_render_permitted = .init(false);
        self.ingress.init();
        self.published_snapshot = .init(0);
        return self;
    }

    fn attach(self: *MusicRuntime) void {
        if (self.generation) |generation| self.control.scheduled.asset_generation = generation.runtime_generation;
        self.control.music_runtime = self;
        self.renderer.music_trace = &self.group_events;
        for (&self.snapshots) |*slot| {
            slot.readers = .init(0);
            slot.value = self.controlSnapshot();
            slot.value_v1 = self.controlStatusV1();
        }
    }

    /// Host-quiescent initial binding. Default loads retain their historical
    /// Ready-before-callback contract. Explicit duck_v1 graph loads require the
    /// existing Render driver to execute bootstrap while pollLoad is Pending;
    /// ordinary request/SFX admission stays closed until the real install receipt. This increment does not change a running render
    /// owner's generation, reopen a device, or silently provide hot reload.
    pub fn createV1(allocator: std.mem.Allocator, control: *rt.ControlRuntime, renderer: *rt.RuntimeRenderer, config: v1.ConfigV1) !*MusicRuntime {
        return createV1Profile(allocator, control, renderer, config, rt.streaming.release_profile);
    }
    /// Qualification uses the same constructor and immutable real Service
    /// budgets. Production callers cannot select this test-only entry point.
    pub fn createV1WithStreamingProfile(allocator: std.mem.Allocator, control: *rt.ControlRuntime, renderer: *rt.RuntimeRenderer, config: v1.ConfigV1, profile: rt.streaming.StreamCapacityProfile) !*MusicRuntime {
        if (!@import("builtin").is_test) return error.UnsupportedCapability;
        return createV1Profile(allocator, control, renderer, config, profile);
    }
    fn createV1Profile(allocator: std.mem.Allocator, control: *rt.ControlRuntime, renderer: *rt.RuntimeRenderer, config: v1.ConfigV1, profile: rt.streaming.StreamCapacityProfile) !*MusicRuntime {
        try config.validate();
        if (control.music_runtime != null or control.scheduled.context_id != 0 or renderer.runtime != control or renderer.music_trace != null or renderer.callObservation().sequence != 0 or !control.accepting.load(.acquire)) return error.InvalidState;
        if (renderer.mixer.sample_rate != s.sample_rate or renderer.mixer.output_layout.kind != .stereo) return error.UnsupportedCapability;
        if (control.voice_admission != null and control.voice_context_id != config.context) return error.InvalidState;
        _ = try audio.RuntimeOfflineBackend.init(renderer, config.quantum_frames, 2);
        const self = try allocate(allocator, control, renderer, .{ .context = config.context, .seed = config.seed, .quantum_frames = config.quantum_frames });
        errdefer {
            allocator.destroy(self.borrowed_sounds);
            allocator.destroy(self);
        }
        if (config.policy_support != .disabled) self.policy_storage = try policy.Storage.create(allocator);
        errdefer if (self.policy_storage) |storage| allocator.destroy(storage);
        self.layer_config = try layer_owner.OwnedConfig.init(allocator, config.layer_gain);
        errdefer self.layer_config.?.deinit();
        self.crossfade_config = try @import("sme-runtime-crossfade-contract").OwnedConfig.init(allocator, config.crossfade);
        errdefer self.crossfade_config.?.deinit();
        self.mode = .versioned;
        self.config_v1 = config;
        self.config_v1.layer_gain = self.layer_config.?.value;
        self.config_v1.crossfade = self.crossfade_config.?.value;
        self.next_load = 1;
        if (config.streaming_reservation == .release_profile) {
            const service = try rt.streaming.Service.create(allocator, profile);
            errdefer service.destroy() catch unreachable;
            // There are no Worker/Render users yet. Attachment is the last
            // fallible step before publishing the actual context owner.
            self.service_custody = .{ .service = service };
            self.owned_streaming = service;
            try self.attachInitialService(service);
            self.worker_streaming.store(service, .release);
        }
        self.attach();
        return self;
    }

    pub const SemanticOutputSinkV1 = SemanticOutputSink;
    /// Attach at genuine Host startup, before load and before starting Worker or
    /// callbacks. This does not enable a legacy recording profile, install any
    /// execution input, certify completeness, or change playback admission.
    pub fn attachSemanticOutputSinkV1(self: *MusicRuntime, sink: SemanticOutputSink) !void {
        try self.checkControlV1();
        if (self.control_guard.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_guard.store(false, .release);
        if (self.worker_guard.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentWorker;
        defer self.worker_guard.store(false, .release);
        if (self.semantic_output_sink != null) return error.InvalidState;
        try self.requireSemanticOutputStartupV1();
        self.semantic_output_sink = sink;
    }
    /// Only an unused startup attachment can be cancelled explicitly. Once
    /// activity starts, retain the borrow through every failed destruction retry
    /// and final canonical emission. Successful destruction ends it at the real
    /// no-failure free boundary, not at a zero-drain snapshot or presumed join.
    pub fn detachSemanticOutputSinkV1(self: *MusicRuntime, context: *anyopaque) !void {
        try self.checkControlV1();
        if (self.control_guard.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_guard.store(false, .release);
        if (self.worker_guard.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentWorker;
        defer self.worker_guard.store(false, .release);
        const sink = self.semantic_output_sink orelse return error.InvalidState;
        if (sink.context != context) return error.InvalidState;
        try self.requireSemanticOutputStartupV1();
        self.semantic_output_sink = null;
    }
    fn requireSemanticOutputStartupV1(self: *const MusicRuntime) !void {
        if (!self.usesIntegratedTickV1() or (self.config_v1.kind != .authoring and self.config_v1.kind != .offline) or
            self.config_v1.streaming_reservation != .initial_bank_only) return error.InvalidMode;
        if (self.control.control_active.load(.acquire)) return error.ConcurrentControl;
        if (self.state != .uninitialized or self.shutdown_requested.load(.acquire) or self.control_torn_down or
            self.worker_thread != null or self.generation != null or self.owned_streaming != null or self.service_custody != null or
            self.worker_streaming.load(.acquire) != null or self.worker_generation.load(.acquire) != null or self.outgoing_generation.load(.acquire) != null or
            self.load.state.load(.acquire) != .idle or self.load_ticket != null or self.load.candidate != null or self.next_load != 1 or
            self.tick != 0 or self.tick_scope != null or self.tick_entry != .idle or self.input_count != 0 or self.observation_count != 0 or
            self.input_base != 0 or self.observation_base != 0 or self.incomplete or self.trace_counter_exhausted or self.replay_unsupported or
            self.control.music_runtime != self or self.renderer.runtime != self.control or self.renderer.music_trace != &self.group_events or
            self.renderer.device_callbacks_active.load(.acquire) or self.renderer.device_access.load(.acquire) != 0 or
            self.renderer.callObservation().sequence != 0 or self.renderer.renderFrame() != 0 or
            self.control.stream_control_tick != 0 or self.control.scheduled.render_frame.load(.acquire) != 0 or
            self.control.scheduled.commit_horizon.load(.acquire) != 0 or self.control.stream_input_evidence_failures != 0 or
            !self.group_events.enabled.load(.acquire) or self.group_events.incomplete.load(.acquire) or
            self.group_events.head.load(.acquire) != 0 or self.group_events.tail.load(.acquire) != 0 or
            self.group_events.lost.load(.acquire) != 0 or self.group_events.reset_epoch.load(.acquire) != 1 or self.active_producers.load(.acquire) != 0 or
            self.causal_sink != null or self.causal_driver_pin != null or self.public_recording.phase != .disabled) return error.InvalidState;
        if (@import("builtin").is_test) if (self.test_live_bootstrap != null or self.test_finalization != null) return error.InvalidState;
    }
    /// Separate semantic Live profile. The Host excludes Worker startup and
    /// device registration; these guards reject overlap, not manufacture joins.
    /// Contexts stay pinned through native destruction and both actual joins.
    pub fn attachLiveSemanticV1(self: *MusicRuntime, hooks: rt.streaming.stream.LiveSemanticHooks) !void {
        if (hooks.clock != null or hooks.consume != null) return error.InvalidMode;
        return self.attachLiveSemanticOwnedV1(hooks);
    }
    /// Only an independently constructed offline executor may call this entry.
    /// Raw clocks are inputs; Service.replay_mode remains false. No recorded
    /// plan/readiness/result may be installed through this binding.
    pub fn attachLiveSemanticReplayV1(self: *MusicRuntime, hooks: rt.streaming.stream.LiveSemanticHooks) !void {
        if (@import("builtin").is_test) if (hooks.test_retry_workload != null) return error.InvalidMode;
        const offline_clock = hooks.clock orelse return error.InvalidMode;
        try offline_clock.validateInitial();
        return self.attachLiveSemanticOwnedV1(hooks);
    }
    fn attachLiveSemanticOwnedV1(self: *MusicRuntime, hooks: rt.streaming.stream.LiveSemanticHooks) !void {
        try self.checkControlV1();
        if (self.control_guard.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_guard.store(false, .release);
        if (self.worker_guard.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentWorker;
        defer self.worker_guard.store(false, .release);
        try self.requireSemanticOutputStartupV1();
        if (self.config_v1.kind != .authoring or self.live_semantic_service_hooks != null or
            self.control.live_semantic_hooks != null or self.renderer.live_semantic_hooks != null or
            self.control.offline_causal_replay != null or self.renderer.offline_causal_replay != null or
            self.control.prerequisite_order != null or self.renderer.prerequisite_order != null or
            self.control.control_frontier_binding != null or self.control.stream_acceptance_binding != null or
            self.control.readiness_binding != null or self.renderer.render_causal_binding != null) return error.InvalidMode;
        const token = try self.renderer.acquireDeviceQuiescence();
        defer self.renderer.releaseDeviceQuiescence(token) catch unreachable;
        if (self.control.control_active.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control.control_active.store(false, .release);
        try self.control.scheduled.attachLiveSemanticQuiescent(hooks.cuts);
        self.control.live_semantic_hooks = hooks.cuts;
        self.renderer.live_semantic_hooks = hooks.cuts;
        self.live_semantic_service_hooks = hooks;
        self.group_events.live_semantic_hooks = hooks.cuts;
    }
    /// Startup rollback only; active borrows end at the native final-free
    /// boundary, never at a health/zero-drain snapshot.
    pub fn detachLiveSemanticV1(self: *MusicRuntime, expected: rt.streaming.stream.LiveSemanticHooks) !void {
        try self.checkControlV1();
        if (self.control_guard.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_guard.store(false, .release);
        if (self.worker_guard.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentWorker;
        defer self.worker_guard.store(false, .release);
        try self.requireSemanticOutputStartupV1();
        const actual = self.live_semantic_service_hooks orelse return error.InvalidState;
        if (!rt.streaming.stream.LiveSemanticHooks.same(actual, expected)) return error.InvalidState;
        const token = try self.renderer.acquireDeviceQuiescence();
        defer self.renderer.releaseDeviceQuiescence(token) catch unreachable;
        try self.control.scheduled.detachLiveSemanticQuiescent(expected.cuts);
        self.live_semantic_service_hooks = null;
        self.group_events.live_semantic_hooks = null;
        self.control.live_semantic_hooks = null;
        self.renderer.live_semantic_hooks = null;
    }

    fn invalidateSemanticOutputV1(self: *MusicRuntime) void {
        if (self.semantic_output_sink) |sink| sink.invalidate(sink.context);
    }

    fn publishLoadReady(self: *MusicRuntime) void {
        const generation = self.generation.?;
        generation.transport.device_epoch = self.device_accepted_epoch.load(.acquire);
        self.state = .ready;
        self.admission_generation.store(generation.runtime_generation, .release);
        self.admission_handle.store(self.handle_incarnation, .release);
        self.load_status = .{ .ready = .{ .bank = self.bankRef(), .content_hash = generation.loaded.content_hash } };
        self.policy_render_permitted.store(true, .release);
    }
    fn preparePolicyGraphLoad(self: *MusicRuntime) !void {
        const storage = self.policy_storage orelse return;
        const state = self.load.state.load(.acquire);
        if ((state != .completed and state != .sources_completed) or self.generation != null or storage.graph != null) return;
        const candidate = self.load.candidate orelse return;
        const graph = candidate.loaded.bus_graph orelse return;
        // Control must have assigned the real runtime identity first. Source
        // completion is acquired before graph admission; no Worker fields race.
        if (candidate.runtime_generation == 0 or candidate.preparation_failure != null) return;
        if (self.shutdown_requested.load(.acquire) or self.load.cancelled.load(.acquire)) return;
        const scope = self.tick_scope orelse return error.InvalidMode;
        // Only published Control observations are read here. Render keeps the
        // final quiescent install check; preparation never binds the mixer.
        if (self.control.telemetry().live_instances != 0) return self.rollbackLoad(candidate, .invalid_state);
        if (self.control.bus_manager) |manager| for (manager.graphs) |entry| if (entry) |foreign| if (foreign.active.load(.acquire)) return self.rollbackLoad(candidate, .invalid_state);
        const desc = graph.adapter;
        const handle = scope.prepareBusGraph(self.allocator, graph.desc, graph.profile, .{ .music_bus = desc.music_bus, .sfx_bus = desc.sfx_bus, .legacy_music_bus = desc.legacy_music_bus, .legacy_master_bus = desc.legacy_master_bus, .reverb_bus = desc.reverb_bus }) catch |err| return self.rollbackLoad(candidate, failureV1(err));
        storage.graph = .{ .handle = handle, .generation = candidate.runtime_generation, .authored_generation = candidate.loaded.metadata.generation, .build_id = buildId(candidate.loaded.content_hash), .bank_content_hash = candidate.loaded.content_hash };
    }
    fn policyCommand(self: *MusicRuntime) !rt.scheduler.CommandIdentity {
        return self.policyCommandFor(self.generation orelse return error.InvalidState);
    }
    fn policyCommandFor(self: *MusicRuntime, generation: *Generation) !rt.scheduler.CommandIdentity {
        const id = try self.takePlan();
        return .{ .command_id = 1, .group_id = id, .phase_order = 0, .execute_frame = try self.planningFrontier(), .token = .{ .context = @enumFromInt(self.config.context), .transport_epoch = @enumFromInt(generation.transport.transport_epoch), .asset_generation = @enumFromInt(generation.runtime_generation), .plan_id = @enumFromInt(id), .plan_epoch = @enumFromInt(1), .phase_id = @enumFromInt(1) } };
    }
    fn preparePolicyPlan(self: *MusicRuntime, command: rt.ScheduledCommand) !policy.Plan {
        const frame = command.identity.execute_frame;
        const block = try self.prepareSchedule(frame, try std.math.add(u64, frame, 1), &.{command});
        return .{ .block = block, .plan = try self.schedulePlan(block), .token = command.identity.token };
    }
    fn submitPolicyPlan(self: *MusicRuntime, plan: *policy.Plan) !void {
        if (plan.submitted) return;
        self.submitSchedule(plan.block) catch |err| switch (err) {
            error.CommandQueueFull => return,
            else => {
                plan.failure = failureV1(err);
                plan.cancellation = try self.cancelSchedule(.{ .target = plan.block, .requested_frame = self.control_frame });
                plan.submitted = true; // terminal collection now owns this block
                return err;
            },
        };
        plan.submitted = true;
    }
    /// Return only an acquired actual scheduler phase. Rejected plans have no
    /// synthetic executed phase; their copied request terminal uses rejection.
    fn collectPolicyPlan(self: *MusicRuntime, plan: *policy.Plan) !bool {
        const terminal = try self.scheduleResult(plan.block);
        if (!plan.admission_seen) if (try self.scheduleAdmission(plan.block)) |admission| {
            self.input(.{ .position = self.position(), .payload = .{ .admission = admission } });
            plan.admission_seen = true;
        };
        if (plan.cancellation) |handle| if (try self.cancellationResult(handle)) |result| {
            self.input(.{ .position = self.position(), .payload = .{ .admission = result.admission } });
            self.observe(.{ .event = result.receipt });
            plan.cancellation = null;
        };
        while (try self.pollExecutionReceipt(plan.block, &plan.receipt_cursor)) |record| {
            self.observe(.{ .event = record });
            if (record.result == .rejected) {
                plan.rejection_reason = record.reason;
                plan.rejection_frame = record.effective_frame;
                plan.failure = switch (record.reason) {
                    .command_queue_full => .command_queue_full,
                    .voice_budget_exceeded => .voice_budget_exceeded,
                    .stale_asset_generation => .stale_bank,
                    .unsupported_capability, .unsupported_operation => .unsupported_capability,
                    .planner_capacity => .resource_limit,
                    else => .invalid_state,
                };
            }
        }
        while (try self.pollPlanPhase(plan.plan, &plan.phase_cursor)) |phase| plan.phase = phase;
        return terminal != null and plan.cancellation == null;
    }
    fn releasePolicyPlan(self: *MusicRuntime, value: *?policy.Plan) !bool {
        const plan = value.* orelse return true;
        self.releaseSchedule(plan.block) catch |err| switch (err) {
            error.DuckDrainPending, error.InvalidState => return false,
            else => return err,
        };
        value.* = null;
        return true;
    }
    fn policyGeneration(self: *MusicRuntime, slot: *const policy.Slot) *Generation {
        const lease = slot.generation_lease orelse unreachable;
        const entry = self.generations.get(lease.registry) catch unreachable;
        std.debug.assert(entry.payload == lease.payload and entry.generation.value() == lease.runtime_generation and
            slot.ticket.bank.asset_generation == lease.runtime_generation and slot.ticket.context == self.config.context and
            lease.authored_generation == lease.payload.loaded.metadata.generation and std.mem.eql(u8, &lease.bank_content_hash, &lease.payload.loaded.content_hash));
        return lease.payload;
    }
    /// Internal checked helper seam. A current-generation standalone preparation
    /// may have no public policy slot; an old-generation helper MUST have one.
    pub fn retainedPolicyGeneration(self: *MusicRuntime, control: *rt.ControlRuntime, ticket: v1.RequestTicketV1) rt.RuntimeError!?*Generation {
        try self.checkGroupCreditControl(control);
        const storage = self.policy_storage orelse return null;
        const slot = storage.slotForTicket(ticket) orelse storage.action(ticket) orelse return null;
        if (!slot.occupied or slot.drained() or slot.generation_lease == null) return error.InvalidState;
        if (ticket.context != self.config.context or !std.meta.eql(ticket.bank, slot.ticket.bank)) return error.StaleAssetGeneration;
        const lease = slot.generation_lease.?;
        const entry = self.generations.get(lease.registry) catch return error.StaleAssetGeneration;
        if (entry.payload != lease.payload or entry.generation.value() != lease.runtime_generation or ticket.bank.asset_generation != lease.runtime_generation or
            lease.authored_generation != lease.payload.loaded.metadata.generation or !std.mem.eql(u8, &lease.bank_content_hash, &lease.payload.loaded.content_hash)) return error.StaleAssetGeneration;
        return lease.payload;
    }
    fn assertPolicyCredits(self: *MusicRuntime) void {
        const storage = self.policy_storage orelse return;
        for (self.generations.entries) |entry| if (entry) |value| {
            var count: u32 = 0;
            for (storage.slots) |slot| if (slot.occupied) if (slot.generation_lease) |lease| {
                if (lease.payload == value.payload) {
                    std.debug.assert(lease.runtime_generation == value.generation.value());
                    count += 1;
                }
            };
            std.debug.assert(count == value.payload.policy_leases);
            value.payload.assertControlCredits();
        };
    }
    fn collectPolicyCredits(self: *MusicRuntime) void {
        const storage = self.policy_storage orelse return;
        self.assertPolicyCredits();
        defer self.assertPolicyCredits();
        for (&storage.slots) |*slot| if (slot.occupied and slot.drained()) if (slot.generation_lease) |lease| {
            switch (slot.data) {
                .duck => |value| std.debug.assert(value.begin == null and value.end == null and value.lease == null),
                .stinger => |value| std.debug.assert(value.begin == null and value.end == null and value.group == null),
            }
            lease.payload.releasePolicy(lease) catch unreachable;
            slot.generation_lease = null;
        };
    }
    fn acceptPolicy(self: *MusicRuntime, item: ingress.Item) !void {
        const storage = self.policy_storage orelse return error.UnsupportedOperation;
        const normalized = try trace.schema.normalizeRequest(.{ .request_id = item.ticket.request_id, .payload = item.command.music }, self.config_v1.kind, 1, item.ticket.request_id, self.config.context);
        if (self.generation.?.policies == null or !storage.graph_installed) return error.UnsupportedOperation;
        const external_id = if (item.command.music == .begin_duck) item.command.music.begin_duck.id.value() else item.command.music.end_duck.value();
        var owned: ?*policy.Slot = null;
        for (&storage.slots) |*slot| if (slot.occupied and slot.data == .duck and slot.data.duck.external_id == external_id and std.meta.eql(slot.ticket.bank, item.ticket.bank)) {
            owned = slot;
            break;
        };
        var slot: *policy.Slot = undefined;
        if (item.command.music == .begin_duck) {
            if (owned != null) return error.DuckBusy;
            const preset = item.command.music.begin_duck.preset.value();
            _ = for (self.generation.?.policies.?.ducks) |row| {
                if (row.key.id == preset) break row;
            } else return error.UnknownDuckPreset;
            slot = for (&storage.slots) |*entry| {
                if (!entry.occupied) break entry;
            } else return error.ResourceLimitExceeded;
            const next_incarnation = try std.math.add(u64, storage.next_incarnation, 1);
            const next_render_id = try std.math.add(u32, storage.next_render_id, 1);
            const generation_lease = try self.generation.?.retainPolicy();
            slot.* = .{ .occupied = true, .generation_lease = generation_lease, .ticket = item.ticket, .incarnation = storage.next_incarnation, .action_ticket = item.ticket, .data = .{ .duck = .{ .preset = preset, .external_id = external_id, .render_id = storage.next_render_id, .result = .{ .begin_ticket = item.ticket, .external_id = external_id, .incarnation = storage.next_incarnation } } } };
            storage.next_incarnation = next_incarnation;
            storage.next_render_id = next_render_id;
        } else {
            slot = owned orelse return error.StaleDuck;
            if (slot.action_ticket != null or slot.data.duck.stop_requested) return error.DuckBusy;
            slot.action_ticket = item.ticket;
            slot.data.duck.stop_requested = true;
        }
        self.assertPolicyCredits();
        const at = self.position();
        if (item.command.music == .begin_duck) slot.accepted = at else slot.data.duck.end_accepted = at;
        self.ingress.emit(.{ .ticket = item.ticket, .event = .{ .accepted = .{ .control_tick = self.tick, .render_frame = self.control_frame } } });
        self.input(.{ .position = at, .payload = .{ .request = normalized } });
        if (slot.data.duck.result.physical_drained and slot.action_ticket != null) self.finishTicketV1(item.ticket, .unchanged);
    }
    fn acceptStinger(self: *MusicRuntime, item: ingress.Item) !void {
        if (self.config_v1.policy_support != .resident_stinger_v1) return error.UnsupportedOperation;
        const storage = self.policy_storage orelse return error.UnsupportedOperation;
        const generation = self.generation orelse return error.InvalidState;
        const owned = generation.policies orelse return error.UnsupportedOperation;
        if (!storage.graph_installed) return error.InvalidState;
        const id = item.command.music.trigger_stinger.value();
        const entry_index: u32 = for (owned.stingers, 0..) |entry, index| {
            if (entry.id == id) break @intCast(index);
        } else return error.UnknownStinger;
        const slot = for (&storage.slots) |*entry| {
            if (!entry.occupied) break entry;
        } else return error.ResourceLimitExceeded;
        const next = try std.math.add(u64, storage.next_incarnation, 1);
        const normalized = try trace.schema.normalizeRequest(.{ .request_id = item.ticket.request_id, .payload = item.command.music }, self.config_v1.kind, 1, item.ticket.request_id, self.config.context);
        const generation_lease = try generation.retainPolicy();
        const accepted = self.position();
        slot.* = .{ .occupied = true, .generation_lease = generation_lease, .ticket = item.ticket, .accepted = accepted, .incarnation = storage.next_incarnation, .action_ticket = item.ticket, .data = .{ .stinger = .{
            .entry_index = entry_index,
            .identity = .{ .context = self.config.context, .asset_generation = generation.runtime_generation, .transport_epoch = generation.transport.transport_epoch, .device_epoch = generation.transport.device_epoch },
            .result = .{ .trigger_ticket = item.ticket, .stinger_id = id, .incarnation = storage.next_incarnation, .accepted = accepted },
        } } };
        storage.next_incarnation = next;
        self.assertPolicyCredits();
        self.ingress.emit(.{ .ticket = item.ticket, .event = .{ .accepted = .{ .control_tick = self.tick, .render_frame = self.control_frame } } });
        self.input(.{ .position = accepted, .payload = .{ .request = normalized } });
    }
    fn stingerContext(self: *MusicRuntime, slot: *const policy.Slot, identity: rt.scheduler.CommandIdentity) policy_helper.Context {
        const generation = self.policyGeneration(slot);
        return .{ .tick = self.tick_scope.?, .ticket = slot.ticket, .accepted = slot.accepted, .command = identity, .transport = &generation.transport, .loaded = &generation.loaded, .policies = &generation.policies.?, .runtime_generation = generation.runtime_generation };
    }
    fn prepareStingerGroup(self: *MusicRuntime, slot: *const policy.Slot, identity: rt.scheduler.CommandIdentity) !policy_helper.Prepared {
        const generation = self.policyGeneration(slot);
        const entry = generation.policies.?.stingers[slot.data.stinger.entry_index];
        const segment = generation.loaded.tables.segments[entry.segment];
        const cue = generation.loaded.tables.cues[entry.cue];
        var layers: [rt.music_group.max_layers]rt.MusicGroupLayer = undefined;
        var layout: rt.channel_layout.ChannelLayout = undefined;
        for (generation.loaded.tables.layers[segment.layers.first..][0..segment.layers.count], 0..) |layer, i| {
            const sound = generation.loaded.tables.sounds[layer.sound];
            if (sound.storage != .resident) return error.UnsupportedOperation;
            layout = try rt.channel_layout.ChannelLayout.init(sound.layout, sound.channels, sound.channel_mask);
            layers[i] = .{ .owner = &generation.owners[layer.sound], .layout = layout, .generation = generation.runtime_generation, .gain = std.math.pow(f32, 10, layer.gain_db / 20), .authored = .{ .layer_id = layer.key.id, .drop_rank = layer.drop_rank }, .asset_frame_origin = layer.source_start };
        }
        return policy_helper.prepareStinger(self.stingerContext(slot, identity), entry.id, .{ .segment = segment.key.id, .generation = generation.runtime_generation, .layout = layout, .layers = layers[0..segment.layers.count], .segment_frames = segment.frames, .start_cursor = cue.frame, .loop = null }, self.renderer.mixer.output_layout);
    }
    fn rejectStinger(self: *MusicRuntime, slot: *policy.Slot, failure: v1.FailureV1) void {
        slot.data.stinger.result.preparation_failure = failure;
        slot.data.stinger.reprepare = false;
        slot.data.stinger.waiting_victim = null;
        slot.data.stinger.stop_requested = true;
        if (slot.action_ticket) |ticket| self.finishTicketV1(ticket, .{ .rejected = failure });
        if (slot.data.stinger.group == null and slot.data.stinger.begin == null and slot.data.stinger.end == null) slot.data.stinger.result.physical_drained = true;
    }
    fn deferFutureStingers(self: *MusicRuntime) void {
        const storage = self.policy_storage orelse return;
        for (&storage.slots) |*slot| if (slot.occupied and slot.data == .stinger and slot.action_ticket != null and !slot.data.stinger.stop_requested) {
            if (slot.data.stinger.begin != null) slot.data.stinger.reprepare = true;
        };
    }
    fn prepareStingers(self: *MusicRuntime) !void {
        const storage = self.policy_storage orelse return;
        for (&storage.slots) |*slot| if (slot.occupied and slot.data == .stinger and !slot.drained()) {
            const generation = self.policyGeneration(slot);
            const owned = generation.policies orelse return error.InvalidState;
            self.prepareOneStinger(storage, generation, owned, slot) catch |err| {
                self.last_error = failureV1(err);
                // A failed cleanup keeps the still-live group. An unexecuted
                // trigger retains its terminal credit until cancellation/close.
                if (slot.data.stinger.result.start_phase == null and slot.data.stinger.begin == null) self.rejectStinger(slot, self.last_error.?);
            };
        };
    }
    fn prepareOneStinger(self: *MusicRuntime, storage: *policy.Storage, generation: *Generation, owned: bank.music_policy_adapter.Owned, slot: *policy.Slot) !void {
        const value = &slot.data.stinger;
        if (value.begin) |*plan| {
            if ((value.stop_requested or value.reprepare) and value.result.start_phase == null) {
                if (plan.cancellation == null) plan.cancellation = try self.cancelSchedule(.{ .target = plan.block, .requested_frame = self.control_frame });
                plan.submitted = true;
            } else try self.submitPolicyPlan(plan);
            return;
        }
        if (value.stop_requested) {
            if (value.group == null) {
                if (slot.action_ticket != null) self.rejectStinger(slot, .cancelled);
                return;
            }
            if (value.result.start_phase != null and value.result.terminal == null and value.end == null) {
                const identity = try self.policyCommandFor(generation);
                value.end = try self.preparePolicyPlan(.{ .identity = identity, .payload = .{ .group_stop = .{ .group = value.group.?, .release_frames = value.stop_release_frames } } });
            }
            if (value.end) |*plan| try self.submitPolicyPlan(plan);
            return;
        }
        if (value.group != null or slot.action_ticket == null) return;
        value.prepared_victim = null;
        const entry = owned.stingers[value.entry_index];
        const deadline = try std.math.add(u64, slot.accepted.accepted_control_frame, entry.policy.deadline_frames);
        if (self.control_frame > deadline) {
            value.result.policy_reason = .deadline;
            self.rejectStinger(slot, .cancelled);
            return;
        }
        if (generation.transport.paused or (entry.policy.sync != .immediate and !self.has_executed)) return;
        if (self.pending) |pending| if (pending.operation == .pause) return;
        if (value.waiting_victim) |waiting| {
            if (storage.slotForTicket(waiting.ticket)) |old| {
                if (old.data != .stinger or old.incarnation != waiting.incarnation) return error.InvalidState;
                // A trigger terminal or published group terminal is insufficient.
                // Cancellation can lose to execution; its separate stop and all
                // retained scheduler/group owners must genuinely retire first.
                if (!old.drained()) return;
                if (old.data.stinger.begin != null or old.data.stinger.end != null or old.data.stinger.group != null) return error.InvalidState;
            }
            // An absent exact ticket was acknowledged only after physical drain.
            // Reuse of that cell cannot retarget this dependency to a new owner.
            value.waiting_victim = null;
        }
        const admission = policy_helper.stinger_admission;
        const observed = self.position();
        const current: admission.Identity = .{ .context = self.config.context, .asset_generation = generation.runtime_generation, .transport_epoch = generation.transport.transport_epoch, .device_epoch = generation.transport.device_epoch };
        const frontier = try self.planningFrontier();
        const frame = switch (entry.policy.sync) {
            .immediate => @max(observed.accepted_control_frame, frontier),
            .next_beat => (try generation.transport.strictNext(.beat, observed.accepted_control_frame, .{ .earliest_submit_frame = frontier })).frame,
            .next_bar => (try generation.transport.strictNext(.bar, observed.accepted_control_frame, .{ .earliest_submit_frame = frontier })).frame,
        };
        var active: [policy.capacity]admission.Active = undefined;
        var count: usize = 0;
        for (&storage.slots) |*other| if (other != slot and other.occupied and other.data == .stinger and other.data.stinger.group != null and other.data.stinger.result.terminal == null and self.policyGeneration(other) == generation) {
            const other_policy = owned.stingers[other.data.stinger.entry_index].policy;
            active[count] = .{ .request_id = other.ticket.request_id, .stinger_id = other.data.stinger.result.stinger_id, .accepted_frame = other.accepted.accepted_control_frame, .priority = other_policy.priority, .protected = other_policy.protected };
            count += 1;
        };
        const last = generation.stinger_history[value.entry_index].last;
        const decision = try admission.decideRetained(entry.policy, owned.max_stingers, .{ .identity = value.identity, .position = slot.accepted, .request_id = slot.ticket.request_id, .stinger_id = entry.id }, .{ .identity = current, .active = active[0..count], .previous = if (last) |previous| .{ .request_id = previous.request_id, .accepted_frame = previous.accepted_frame } else null }, .{ .sync = entry.policy.sync, .frame = frame }, frontier, true, .{ .identity = current, .position = observed });
        value.result.last_retry = observed;
        var victim: ?*policy.Slot = null;
        switch (decision.proposal) {
            .drop => |reason| {
                value.result.policy_reason = @enumFromInt(@intFromEnum(reason));
                self.rejectStinger(slot, .cancelled);
                return;
            },
            .@"defer" => |proposal| {
                value.result.policy_reason = @enumFromInt(@intFromEnum(proposal.reason));
                return;
            },
            .admit => {},
            .replace => |proposal| {
                victim = for (&storage.slots) |*other| {
                    if (other.occupied and other.data == .stinger and other.ticket.request_id == proposal.victim_request_id) break other;
                } else return error.InvalidState;
                // A pending victim has no audible group to stop. Cancel its
                // actual block first; a too-late cancellation preserves execution.
                if (victim.?.data.stinger.result.start_phase == null) {
                    value.waiting_victim = .{ .ticket = victim.?.ticket, .incarnation = victim.?.incarnation };
                    victim.?.data.stinger.replacement_requested = true;
                    victim.?.data.stinger.stop_requested = true;
                    return;
                }
            },
        }
        var identity = try self.policyCommandFor(generation);
        identity.execute_frame = frame;
        if (victim != null) identity.command_id = 2;
        const prepared = try self.prepareStingerGroup(slot, identity);
        value.group = prepared.resource.group;
        if (victim) |old| {
            var stop_identity = identity;
            stop_identity.command_id = 1;
            const block = try self.prepareSchedule(frame, try std.math.add(u64, frame, 1), &.{ .{ .identity = stop_identity, .payload = .{ .group_stop = .{ .group = old.data.stinger.group.?, .release_frames = 0 } } }, prepared.command });
            value.begin = .{ .block = block, .plan = try self.schedulePlan(block), .token = identity.token };
            value.prepared_victim = .{ .identity = .{ .ticket = old.ticket, .incarnation = old.incarnation }, .group = old.data.stinger.group.? };
        } else value.begin = try self.preparePolicyPlan(prepared.command);
        value.reprepare = false;
        value.result.policy_reason = null;
        try self.submitPolicyPlan(&value.begin.?);
    }
    /// A failed atomic replacement may be reevaluated only when the exact
    /// retained victim really ended naturally before that rejected phase.
    /// The old-stop command still leases this full group incarnation here;
    /// no prediction or reused Render slot supplies the terminal fact.
    fn replacementVictimEnded(self: *MusicRuntime, storage: *policy.Storage, value: *const policy.StingerState, plan: *const policy.Plan) !bool {
        const expected = value.prepared_victim orelse return false;
        if (plan.rejection_reason != .invalid_state and plan.rejection_reason != .invalid_handle) return false;
        if (plan.phase != null) return false;
        const rejected_at = plan.rejection_frame orelse return false;
        const victim = storage.slotForTicket(expected.identity.ticket) orelse return false;
        if (victim.incarnation != expected.identity.incarnation or victim.data != .stinger) return false;
        const group = victim.data.stinger.group orelse return false;
        if (!group.eql(expected.group)) return false;
        const terminal = (if (self.tick_scope) |scope| try scope.musicGroupTerminal(group) else try self.control.musicGroupTerminal(group)) orelse return false;
        return terminal.group.eql(expected.group) and terminal.bank_generation == expected.identity.ticket.bank.asset_generation and
            terminal.reason == .natural and terminal.boundary_frame <= rejected_at;
    }
    fn collectStingers(self: *MusicRuntime) !void {
        const storage = self.policy_storage orelse return;
        for (&storage.slots) |*slot| if (slot.occupied and slot.data == .stinger and !slot.drained()) {
            const value = &slot.data.stinger;
            if (self.shutdown_requested.load(.acquire) and value.group == null) {
                self.rejectStinger(slot, .runtime_stopped);
                continue;
            }
            if (value.begin) |*plan| {
                const complete = try self.collectPolicyPlan(plan);
                if (plan.phase) |phase| if (phase.outcome == .executed) {
                    if (value.result.start_phase == null) {
                        value.result.start_phase = phase;
                        const history = &self.policyGeneration(slot).stinger_history[value.entry_index];
                        if (history.last == null or history.last.?.request_id < slot.ticket.request_id) history.last = .{ .request_id = slot.ticket.request_id, .accepted_frame = slot.accepted.accepted_control_frame };
                        if (slot.action_ticket) |ticket| self.finishTicketV1(ticket, .{ .executed = phase });
                    }
                    value.reprepare = false;
                };
                if (complete) {
                    if (value.result.start_phase == null) {
                        const retry = !value.stop_requested and !self.shutdown_requested.load(.acquire) and !self.unloading and
                            (value.reprepare or plan.rejection_reason == .stale_epoch or try self.replacementVictimEnded(storage, value, plan));
                        if (retry) value.reprepare = true else self.rejectStinger(slot, plan.failure orelse .cancelled);
                    }
                    _ = try self.releasePolicyPlan(&value.begin);
                }
            }
            if (value.end) |*plan| if (try self.collectPolicyPlan(plan)) {
                if (plan.phase) |phase| {
                    if (phase.outcome == .executed) storage.cleanup_phase = phase;
                }
                _ = try self.releasePolicyPlan(&value.end);
            };
            if (value.group) |group| {
                const terminal = if (self.tick_scope) |scope| try scope.musicGroupTerminal(group) else try self.control.musicGroupTerminal(group);
                if (terminal) |actual| value.result.terminal = .{ .reason = @enumFromInt(@intFromEnum(actual.reason)), .boundary_frame = actual.boundary_frame, .last_sample_frame = actual.last_sample_frame };
                if (value.begin == null and value.end == null and (terminal != null or value.result.start_phase == null)) {
                    self.releaseMusicGroup(group) catch |err| switch (err) {
                        error.DrainPending, error.InvalidState => continue,
                        else => return err,
                    };
                    value.group = null;
                    if (!value.reprepare) value.result.physical_drained = true;
                }
            }
        };
    }
    fn requestPolicyStop(self: *MusicRuntime) void {
        self.requestPolicyStopAt(null);
    }
    fn requestPolicyStopAt(self: *MusicRuntime, accepted: ?trace.schema.Position) void {
        const storage = self.policy_storage orelse return;
        storage.lifecycle_stop = true;
        if (storage.cleanup_accepted == null) storage.cleanup_accepted = accepted;
        for (&storage.slots) |*slot| if (slot.occupied and !slot.drained()) slot.requestStop(accepted);
    }
    fn policyContext(self: *MusicRuntime, slot: *const policy.Slot, identity: rt.scheduler.CommandIdentity, ending: bool) policy_helper.Context {
        const generation = self.policyGeneration(slot);
        return .{ .tick = self.tick_scope.?, .ticket = if (ending) slot.action_ticket orelse slot.ticket else slot.ticket, .accepted = if (ending) slot.data.duck.end_accepted.? else slot.accepted, .command = identity, .transport = &generation.transport, .loaded = &generation.loaded, .policies = &generation.policies.?, .runtime_generation = generation.runtime_generation };
    }
    fn failPolicyBootstrap(self: *MusicRuntime, err: anyerror) void {
        self.last_error = failureV1(err);
        self.load_status = .{ .failed = self.last_error.? };
        // The adopted generation and graph keep their real retirement owners.
        // No bootstrap was published merely because preparation failed.
        self.unloading = true;
    }
    fn preparePolicies(self: *MusicRuntime) !void {
        const storage = self.policy_storage orelse return;
        defer self.collectPolicyCredits();
        if (self.unloading or storage.lifecycle_stop) self.requestPolicyStopAt(storage.cleanup_accepted);
        if (storage.graph) |graph| if (!storage.graph_installed and !self.unloading) {
            // Graph reservation precedes actual startup adoption by one Control
            // collection. Only that adopted identity may publish the bootstrap;
            // waiting here grants neither Render permission nor load success.
            if (self.generation == null) return;
            if (storage.bootstrap == null) {
                const command = self.policyCommand() catch |err| {
                    self.failPolicyBootstrap(err);
                    return err;
                };
                storage.bootstrap = self.preparePolicyPlan(.{ .identity = command, .payload = .{ .graph_install = .{ .graph = graph.handle } } }) catch |err| {
                    self.failPolicyBootstrap(err);
                    return err;
                };
            }
            try self.submitPolicyPlan(&storage.bootstrap.?);
            return;
        };
        try self.prepareStingers();
        for (&storage.slots) |*slot| if (slot.occupied and slot.data == .duck and !slot.data.duck.result.physical_drained) {
            if (slot.data.duck.stop_requested and slot.data.duck.begin == null and slot.data.duck.lease == null) {
                if (slot.action_ticket) |ticket| self.finishTicketV1(ticket, .{ .rejected = .cancelled });
                slot.data.duck.result.preparation_failure = .cancelled;
                slot.data.duck.result.physical_drained = true;
                continue;
            }
            if (slot.data.duck.lease == null) {
                const identity = self.policyCommandFor(self.policyGeneration(slot)) catch |err| {
                    self.rejectPolicyPreparation(slot, err);
                    continue;
                };
                const prepared = policy_helper.prepareDuckBegin(self.policyContext(slot, identity, false), storage.graph.?, slot.data.duck.preset, slot.data.duck.external_id, slot.data.duck.render_id) catch |err| {
                    self.rejectPolicyPreparation(slot, err);
                    continue;
                };
                slot.data.duck.lease = prepared.lease;
                slot.data.duck.begin = self.preparePolicyPlan(prepared.prepared.command) catch |err| {
                    try self.tick_scope.?.releaseTrackedDuck(prepared.lease.tracked.?.handle);
                    slot.data.duck.lease = null;
                    self.rejectPolicyPreparation(slot, err);
                    continue;
                };
            }
            if (slot.data.duck.begin) |*plan| {
                if (slot.data.duck.stop_requested and plan.phase == null) {
                    if (plan.cancellation == null) plan.cancellation = self.cancelSchedule(.{ .target = plan.block, .requested_frame = self.control_frame }) catch |err| {
                        self.last_error = failureV1(err);
                        continue;
                    };
                    plan.submitted = true;
                    continue;
                }
                self.submitPolicyPlan(plan) catch |err| {
                    self.last_error = failureV1(err);
                };
            }
            if (slot.data.duck.stop_requested and !slot.data.duck.end_executed and slot.data.duck.result.begin_phase != null and slot.data.duck.result.terminal == null and slot.data.duck.end == null) {
                if (slot.data.duck.end_accepted == null) slot.data.duck.end_accepted = self.position();
                const identity = self.policyCommandFor(self.policyGeneration(slot)) catch |err| {
                    self.failPolicyEnd(slot, err);
                    continue;
                };
                const prepared = policy_helper.prepareDuckEnd(self.policyContext(slot, identity, true), slot.data.duck.lease.?) catch |err| {
                    self.failPolicyEnd(slot, err);
                    continue;
                };
                slot.data.duck.end = self.preparePolicyPlan(prepared.command) catch |err| {
                    self.failPolicyEnd(slot, err);
                    continue;
                };
            }
            if (slot.data.duck.end) |*plan| self.submitPolicyPlan(plan) catch |err| {
                self.last_error = failureV1(err);
            };
        };
    }
    fn failPolicyEnd(self: *MusicRuntime, slot: *policy.Slot, err: anyerror) void {
        self.last_error = failureV1(err);
        if (slot.action_ticket) |ticket| {
            self.finishTicketV1(ticket, .{ .rejected = self.last_error.? });
            // The failed external end is terminal. Its still-live duck retains
            // original DSP ownership and may receive a new explicit end.
            slot.data.duck.stop_requested = false;
            slot.data.duck.end_accepted = null;
        }
        // Lifecycle-owned cleanup keeps its retry obligation. One failed end
        // cannot starve other slots, SFX publication or the main music request.
    }
    fn rejectPolicyPreparation(self: *MusicRuntime, slot: *policy.Slot, err: anyerror) void {
        const reason = failureV1(err);
        if (slot.action_ticket) |ticket| self.finishTicketV1(ticket, .{ .rejected = reason });
        slot.data.duck.result.preparation_failure = reason;
        slot.data.duck.result.physical_drained = true;
    }
    fn collectPolicies(self: *MusicRuntime) !void {
        const storage = self.policy_storage orelse return;
        defer self.collectPolicyCredits();
        if (storage.bootstrap) |*plan| if (try self.collectPolicyPlan(plan)) {
            const executed = plan.phase != null and plan.phase.?.outcome == .executed;
            const failure = plan.failure orelse .cancelled;
            if (!try self.releasePolicyPlan(&storage.bootstrap)) return;
            storage.graph_installed = executed;
            if (executed and !self.shutdown_requested.load(.acquire) and !self.unloading) self.publishLoadReady() else if (!executed) {
                self.load_status = .{ .failed = failure };
                self.last_error = failure;
                self.unloading = self.generation != null;
            }
        };
        for (&storage.slots) |*slot| if (slot.occupied and slot.data == .duck and !slot.data.duck.result.physical_drained) {
            if (self.shutdown_requested.load(.acquire) and slot.data.duck.lease == null) {
                self.rejectPolicyPreparation(slot, error.RuntimeStopped);
                continue;
            }
            if (slot.data.duck.begin) |*plan| {
                const complete = try self.collectPolicyPlan(plan);
                if (plan.phase) |phase| {
                    slot.data.duck.result.begin_phase = phase;
                    if (slot.action_ticket) |ticket| if (std.meta.eql(ticket, slot.ticket)) self.finishTicketV1(ticket, .{ .executed = phase });
                } else if (complete) {
                    if (slot.action_ticket) |ticket| if (std.meta.eql(ticket, slot.ticket)) self.finishTicketV1(ticket, .{ .rejected = plan.failure orelse .cancelled });
                }
                if (complete) _ = try self.releasePolicyPlan(&slot.data.duck.begin);
            }
            if (slot.data.duck.end) |*plan| if (try self.collectPolicyPlan(plan)) {
                if (plan.phase) |phase| {
                    storage.cleanup_phase = phase;
                    slot.data.duck.end_executed = true;
                } else {
                    // A failed external action cannot execute later ticketless.
                    // Independent lifecycle cleanup may retain its own obligation.
                    slot.data.duck.stop_requested = false;
                    slot.data.duck.end_accepted = null;
                }
                if (slot.action_ticket) |ticket| self.finishTicketV1(ticket, if (plan.phase) |phase| .{ .executed = phase } else .{ .rejected = plan.failure orelse .cancelled });
                _ = try self.releasePolicyPlan(&slot.data.duck.end);
            };
            if (slot.data.duck.lease) |lease| {
                if (!slot.data.duck.terminal_consumed) {
                    const terminal = if (self.tick_scope) |scope| try scope.consumeDuckTerminal(lease.tracked.?.handle) else try self.control.consumeDuckTerminal(lease.tracked.?.handle);
                    if (terminal) |value| {
                        slot.data.duck.result.terminal = .{ .reason = @enumFromInt(@intFromEnum(value.reason)), .frame = value.frame, .release_frontier = value.release_frontier };
                        slot.data.duck.terminal_consumed = true;
                        // Expiry can beat an accepted end before it is prepared.
                        if (slot.data.duck.end == null) if (slot.action_ticket) |ticket| self.finishTicketV1(ticket, .unchanged);
                    }
                }
                if (slot.data.duck.terminal_consumed and slot.data.duck.begin == null and slot.data.duck.end == null) {
                    if (self.tick_scope) |scope| try scope.releaseTrackedDuck(lease.tracked.?.handle) else try self.control.releaseTrackedDuck(lease.tracked.?.handle);
                    slot.data.duck.lease = null;
                    slot.data.duck.result.physical_drained = true;
                }
            }
        };
        try self.collectStingers();
        if (storage.music_stop_ticket) |ticket| if (storage.physicalCount() == 0) {
            // A main stop keeps its original actual phase, even when an internal
            // duck-end phase and a later release frontier finish its lifetime.
            const phase = storage.music_stop_phase orelse storage.cleanup_phase;
            self.finishTicketV1(ticket, if (phase) |actual| .{ .executed = actual } else .unchanged);
            var groups_remain = self.active_group != null or self.pending != null;
            for (self.retired_groups) |group| groups_remain = groups_remain or group != null;
            if (!groups_remain and !self.shutdown_requested.load(.acquire) and !self.unloading) self.state = .ready;
        };
        if (storage.physicalCount() == 0) {
            storage.lifecycle_stop = false;
            storage.cleanup_accepted = null;
        }
        // The renderer performs final context graph retirement on shutdown.
        // Keep an active graph lease across music-only unload and foreign SFX.
        if (storage.graph) |graph| if (storage.bootstrap == null and storage.physicalCount() == 0 and (self.shutdown_requested.load(.acquire) or (self.unloading and !storage.graph_installed))) {
            const active = if (self.tick_scope) |scope| try scope.graphActive(graph.handle) else (try self.control.bus_manager.?.get(graph.handle)).active.load(.acquire);
            if (!active) {
                if (self.tick_scope) |scope| try scope.releaseBusGraph(graph.handle) else try self.control.releaseBusGraph(graph.handle);
                storage.graph = null;
                storage.graph_installed = false;
            }
        };
    }
    pub fn duckLifetimeV1(self: *MusicRuntime, begin_ticket: v1.RequestTicketV1) !v1.DuckLifetimeV1 {
        try self.claimControlV1();
        defer self.control_guard.store(false, .release);
        const slot = (self.policy_storage orelse return error.UnsupportedOperation).slotForTicket(begin_ticket) orelse return error.StaleDuck;
        if (slot.data != .duck) return error.StaleDuck;
        return slot.data.duck.result;
    }
    pub fn acknowledgeDuckV1(self: *MusicRuntime, begin_ticket: v1.RequestTicketV1, incarnation: u64) !void {
        try self.claimControlV1();
        defer self.control_guard.store(false, .release);
        const slot = (self.policy_storage orelse return error.UnsupportedOperation).slotForTicket(begin_ticket) orelse return error.StaleDuck;
        if (slot.data != .duck or slot.incarnation != incarnation) return error.StaleDuck;
        if (!slot.data.duck.result.physical_drained or slot.action_ticket != null) return error.DrainPending;
        std.debug.assert(slot.generation_lease == null);
        slot.* = .{};
    }

    pub fn stingerLifetimeV1(self: *MusicRuntime, trigger_ticket: v1.RequestTicketV1) !v1.StingerLifetimeV1 {
        try self.claimControlV1();
        defer self.control_guard.store(false, .release);
        const slot = (self.policy_storage orelse return error.UnsupportedOperation).slotForTicket(trigger_ticket) orelse return error.InvalidHandle;
        if (slot.data != .stinger) return error.InvalidHandle;
        return slot.data.stinger.result;
    }
    pub fn acknowledgeStingerV1(self: *MusicRuntime, trigger_ticket: v1.RequestTicketV1, incarnation: u64) !void {
        try self.claimControlV1();
        defer self.control_guard.store(false, .release);
        const slot = (self.policy_storage orelse return error.UnsupportedOperation).slotForTicket(trigger_ticket) orelse return error.InvalidHandle;
        if (slot.data != .stinger or slot.incarnation != incarnation) return error.InvalidHandle;
        if (!slot.data.stinger.result.physical_drained or slot.action_ticket != null) return error.DrainPending;
        std.debug.assert(slot.generation_lease == null);
        slot.* = .{};
    }

    /// Test-only retained-finalization admission. This is phase-only: receipt
    /// consumers and snapshot readers keep their original thread contract.
    /// Immutable getters still require the caller to retain the owner lifetime.
    inline fn requireFinalizationOpen(self: *const MusicRuntime) !void {
        if (@import("builtin").is_test) if (self.test_finalization) |session| if (session.blocked()) return error.InvalidState;
    }
    fn checkControlIdentityV1(self: *const MusicRuntime) !void {
        if (self.mode != .versioned) return error.InvalidMode;
        if (self.control_thread != std.Thread.getCurrentId()) return error.WrongThread;
    }
    fn checkControlV1(self: *const MusicRuntime) !void {
        try self.checkControlIdentityV1();
        try self.requireFinalizationOpen();
    }
    fn claimControlV1(self: *MusicRuntime) !void {
        try self.checkControlV1();
        try self.requireCausalRoleV1(.control);
        if (self.control_guard.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
    }
    fn claimSoundControl(self: *MusicRuntime) !void {
        try self.requireCausalRoleV1(.control);
        if (self.mode == .versioned) try self.checkControlV1();
        if (self.control_guard.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
    }
    fn assertServiceCredits(self: *MusicRuntime) void {
        var leases: u32 = 0;
        for (self.generations.entries) |entry| if (entry) |value| {
            if (value.payload.service_custody) |custody| {
                std.debug.assert(self.service_custody != null and custody == &self.service_custody.?);
                std.debug.assert(value.payload.service == custody.service and !value.payload.owns_service);
                leases += 1;
            }
        };
        // Reserved-Service initial preparation is not yet in the registry.
        // Its pointer/custody fields stay immutable during source/retire Worker
        // phases; only acquired content completion first exposes the pointer.
        const load_state = self.load.state.load(.acquire);
        if (self.load.shared_preparation and load_state != .idle and load_state != .queued and load_state != .preparing) {
            if (self.load.candidate) |candidate| if (candidate.registry == null and candidate.service_custody != null) {
                std.debug.assert(candidate.service_custody.? == &self.service_custody.?);
                leases += 1;
            };
        }
        if (self.service_custody) |custody| {
            std.debug.assert(self.owned_streaming == custody.service and leases == custody.generation_leases);
        } else std.debug.assert(self.owned_streaming == null and leases == 0);
    }
    fn assertBorrowedCredits(self: *MusicRuntime) void {
        var total: u64 = 0;
        for (self.generations.entries, 0..) |entry, index| if (entry) |value| {
            const handle: generation_registry.Handle = .{ .index = @intCast(index), .incarnation = self.generations.incarnations[index] };
            std.debug.assert(value.borrowed_resident_pcm == self.borrowed_sounds.countFor(handle));
            total += value.borrowed_resident_pcm;
        };
        std.debug.assert(total == self.borrowed_sounds.outstanding);
    }
    fn collectBorrowedSounds(self: *MusicRuntime) void {
        std.debug.assert(self.control_guard.load(.acquire));
        self.assertBorrowedCredits();
        for (0..borrowed_sound.capacity) |index| if (self.borrowed_sounds.collect(index)) |handle| {
            // Anchor custody was removed after acquiring the actual final
            // return. This local exact handle owns the credit until this call.
            self.generations.releaseBorrowed(handle) catch unreachable;
        };
        self.assertBorrowedCredits();
        for (self.generations.entries) |entry| if (entry) |value| value.payload.collectPlayCustody();
    }
    fn closeBorrowedSounds(self: *MusicRuntime) void {
        self.borrowed_sounds.close();
        for (self.generations.entries, 0..) |entry, index| if (entry != null) {
            self.generations.closeBorrowed(.{ .index = @intCast(index), .incarnation = self.generations.incarnations[index] }) catch unreachable;
            entry.?.payload.closePlayCustody();
        };
    }
    fn hasBorrowedSounds(self: *MusicRuntime, generation: *Generation) bool {
        return (self.generations.get(generation.registry_handle.?) catch unreachable).borrowed_resident_pcm != 0;
    }
    fn checkGroupCreditControl(self: *MusicRuntime, control: *rt.ControlRuntime) rt.RuntimeError!void {
        if (control != self.control or control.music_runtime != self or !control.control_active.load(.acquire) or
            std.Thread.getCurrentId() != self.control_thread) return error.InvalidState;
    }
    fn assertGroupCredits(self: *MusicRuntime) void {
        for (self.generations.entries, 0..) |entry, index| if (entry) |value| {
            var count: u64 = 0;
            for (self.group_generation_credits) |credit| if (credit) |owned| {
                if (owned.registry.index != index) continue;
                std.debug.assert(owned.context == self.config.context and owned.registry.incarnation == self.generations.incarnations[index] and owned.runtime_generation == value.generation.value());
                count += 1;
            };
            std.debug.assert(value.prepared_music_groups == count);
        };
    }
    /// Called by the real serialized Control preparation boundary, after all
    /// fallible physical preparation and before prepared-slot visibility.
    pub fn acquirePreparedGroupCredit(self: *MusicRuntime, control: *rt.ControlRuntime, group: rt.GroupHandle, desc: rt.MusicGroupDesc) rt.RuntimeError!?GroupGenerationCredit {
        try self.checkGroupCreditControl(control);
        if (group.index >= self.group_generation_credits.len or group.generation != control.next_group_generation or
            control.prepared_groups[group.index].occupied or self.group_generation_credits[group.index] != null) return error.InvalidState;
        var generation: ?*Generation = null;
        // Foreign standalone assets need no music-generation credit. Mixing
        // them with an owned generation, or mixing generations, is rejected.
        for (self.generations.entries) |entry| if (entry) |value| {
            var touches = false;
            for (desc.layers) |layer| touches = touches or value.payload.ownsSampleOwner(layer.owner);
            if (desc.emergency) |emergency| for (emergency.layers) |layer| {
                touches = touches or value.payload.ownsSampleOwner(layer.owner);
            };
            if (touches) {
                if (generation != null) return error.InvalidArgument;
                generation = value.payload;
            }
        };
        const owned = generation orelse return null;
        if (self.shutdown_requested.load(.acquire) or desc.generation != owned.runtime_generation or owned.retirement.load(.acquire) != .active) return error.InvalidState;
        for (desc.layers) |layer| if (!owned.ownsGroupLayer(layer)) return error.InvalidArgument;
        if (desc.emergency) |emergency| for (emergency.layers) |layer| {
            if (!owned.ownsGroupLayer(layer)) return error.InvalidArgument;
        };
        const handle = owned.registry_handle orelse return error.InvalidState;
        var credit: GroupGenerationCredit = .{ .context = self.config.context, .runtime_generation = owned.runtime_generation, .registry = handle, .group = group };
        self.assertGroupCredits();
        self.generations.acquirePreparedGroup(handle) catch return error.InvalidState;
        errdefer self.generations.releasePreparedGroup(handle) catch unreachable;
        credit.layer_controller_count = owned.prepareLayerControllers(group, desc.segment, if (desc.emergency) |emergency| emergency.segment else null) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidState,
        };
        credit.layer_controller = credit.layer_controller_count != 0;
        self.group_generation_credits[group.index] = credit;
        self.assertGroupCredits();
        return credit;
    }
    /// Fallible M2 retirement precedes physical prepared-group release. A
    /// copied terminal is not a release: controller.deinit rejects live program,
    /// scheduler, predecessor and cancellation-loser cleanup ownership.
    pub fn closePreparedGroupController(self: *MusicRuntime, control: *rt.ControlRuntime, credit: GroupGenerationCredit) rt.RuntimeError!void {
        try self.checkGroupCreditControl(control);
        if (credit.context != self.config.context or credit.group.index >= self.group_generation_credits.len) return error.InvalidState;
        const owned = self.group_generation_credits[credit.group.index] orelse return error.InvalidState;
        if (!std.meta.eql(owned, credit)) return error.InvalidState;
        if (!credit.layer_controller) return;
        const entry = self.generations.get(credit.registry) catch return error.InvalidState;
        if (entry.generation.value() != credit.runtime_generation) return error.InvalidState;
        entry.payload.closeLayerController(credit.group) catch |err| switch (err) {
            error.DrainPending => return error.DrainPending,
            else => return error.InvalidState,
        };
    }
    /// The prepared slot marks this exact boundary only after its real physical
    /// releases succeed. Duplicate/stale releases cannot debit a newer slot.
    pub fn releasePreparedGroupCredit(self: *MusicRuntime, control: *rt.ControlRuntime, credit: GroupGenerationCredit) rt.RuntimeError!void {
        try self.checkGroupCreditControl(control);
        if (credit.context != self.config.context or credit.group.index >= self.group_generation_credits.len) return error.InvalidState;
        const owned = self.group_generation_credits[credit.group.index] orelse return error.InvalidState;
        if (!std.meta.eql(owned, credit)) return error.InvalidState;
        const slot = &control.prepared_groups[credit.group.index];
        if (!slot.occupied or slot.generation != credit.group.generation or !slot.generation_credit_releasing or
            slot.generation_credit == null or !std.meta.eql(slot.generation_credit.?, credit) or slot.references != 0 or slot.render_pin_mask.load(.acquire) != 0 or
            slot.source_ownership.initial_stream_leases != 0 or slot.source_ownership.current_continuity != null) return error.InvalidState;
        self.assertGroupCredits();
        if (credit.layer_controller) {
            const entry = self.generations.get(credit.registry) catch return error.InvalidState;
            if (entry.generation.value() != credit.runtime_generation) return error.InvalidState;
            entry.payload.releaseLayerController(credit.group) catch return error.InvalidState;
        }
        self.generations.releasePreparedGroup(credit.registry) catch return error.InvalidState;
        self.group_generation_credits[credit.group.index] = null;
        self.assertGroupCredits();
    }
    fn assertSnapshotCredits(self: *MusicRuntime) void {
        for (self.generations.entries, 0..) |entry, index| if (entry) |value| {
            var count: u64 = 0;
            for (&self.control.snapshots, 0..) |*slot, slot_index| if (slot.generation_credits[index]) |credit| {
                std.debug.assert(credit.context == self.config.context and credit.registry.index == index and
                    credit.registry.incarnation == self.generations.incarnations[index] and credit.runtime_generation == value.generation.value() and
                    credit.slot_index == slot_index and credit.snapshot_generation == slot.snapshot.generation);
                count += 1;
            };
            std.debug.assert(value.snapshot_slots == count);
        };
    }
    /// Identical production Control path. Coalesce one envelope per generation
    /// in each real slot; the registry capacity bounds every slot's credit set.
    /// This is called after owner.pin and before that voice or slot is visible.
    pub fn acquireSnapshotCredit(self: *MusicRuntime, control: *rt.ControlRuntime, slot_index: u8, sample: *rt.SampleOwner) rt.RuntimeError!void {
        try self.checkGroupCreditControl(control);
        if (slot_index >= control.snapshots.len) return error.InvalidState;
        const slot = &control.snapshots[slot_index];
        if (slot.credit_phase != .acquiring or slot.snapshot.generation == 0 or slot.readers.load(.acquire) != @TypeOf(slot.*).writing) return error.InvalidState;
        var found: ?generation_registry.Handle = null;
        for (self.generations.entries, 0..) |entry, index| if (entry) |value| if (value.payload.ownsSampleOwner(sample)) {
            if (found != null or value.payload.retirement.load(.acquire) != .active) return error.InvalidState;
            found = .{ .index = @intCast(index), .incarnation = self.generations.incarnations[index] };
        };
        // Standalone external owners remain outside this music inventory. Their
        // actual SampleOwner pin still applies; this is not SFX completeness.
        const handle = found orelse return;
        const generation = (self.generations.get(handle) catch return error.InvalidState).generation;
        const credit: SnapshotGenerationCredit = .{ .context = self.config.context, .runtime_generation = generation.value(), .registry = handle, .slot_index = slot_index, .snapshot_generation = slot.snapshot.generation };
        if (slot.generation_credits[handle.index]) |existing| {
            if (!std.meta.eql(existing, credit)) return error.InvalidState;
            return;
        }
        self.assertSnapshotCredits();
        self.generations.acquireSnapshot(handle) catch return error.InvalidState;
        slot.generation_credits[handle.index] = credit;
        self.assertSnapshotCredits();
    }
    /// Only the actual Control physical-release boundary may return an envelope.
    /// Reader/Render release merely publishes its atomic reader decrement.
    pub fn releaseSnapshotCredit(self: *MusicRuntime, control: *rt.ControlRuntime, credit: SnapshotGenerationCredit) rt.RuntimeError!void {
        try self.checkGroupCreditControl(control);
        if (credit.context != self.config.context or credit.slot_index >= control.snapshots.len or credit.registry.index >= snapshot_credit_capacity) return error.InvalidState;
        const slot = &control.snapshots[credit.slot_index];
        const readers = slot.readers.load(.acquire);
        if (slot.credit_phase != .releasing or slot.snapshot.voice_count != 0 or slot.snapshot.generation != credit.snapshot_generation or
            (readers != 0 and readers != @TypeOf(slot.*).writing)) return error.InvalidState;
        const canonical = slot.generation_credits[credit.registry.index] orelse return error.InvalidState;
        if (!std.meta.eql(canonical, credit)) return error.InvalidState;
        self.assertSnapshotCredits();
        self.generations.releaseSnapshot(credit.registry) catch return error.InvalidState;
        slot.generation_credits[credit.registry.index] = null;
        self.assertSnapshotCredits();
    }
    fn sharedStorageBytes(self: *const MusicRuntime) u64 {
        var bytes: u64 = @sizeOf(MusicRuntime) + @sizeOf(borrowed_sound.Anchor) + (if (self.policy_storage != null) @as(u64, @sizeOf(policy.Storage)) else 0);
        // Both are separate allocations made with this owner's allocator.
        // Their inline descriptors/Control fields are not charged a second time.
        if (self.layer_config) |value| bytes += value.ownedBytes();
        if (self.crossfade_config) |value| bytes += value.ownedBytes();
        if (self.control.source_continuity_manager != null) bytes += @sizeOf(rt.source_continuity.Manager);
        return bytes;
    }
    /// Host allocates storage separately and retains it through publisher and
    /// reader release. The observer never owns a bank, receipt or Render hook.
    pub fn subscribeObserverV1(self: *MusicRuntime, storage: *observer.Storage) !observer.Handle {
        try self.claimControlV1();
        defer self.control_guard.store(false, .release);
        if (self.shutdown_requested.load(.acquire)) return error.RuntimeStopped;
        if (self.observer_storage != null) return error.ObserverAlreadyAttached;
        const handle = try storage.attach(self.config.context, self.input_base + self.input_count, self.observation_base + self.observation_count);
        self.observer_storage = storage;
        self.observer_handle = handle;
        storage.publish(self.controlStatusV1(), .subscribed, null);
        return handle;
    }
    pub fn detachObserverV1(self: *MusicRuntime, handle: observer.Handle) !void {
        try self.claimControlV1();
        defer self.control_guard.store(false, .release);
        const current = self.observer_handle orelse return error.StaleObserver;
        if (!std.meta.eql(current, handle)) return error.StaleObserver;
        self.closeObserver(.detached);
    }
    fn closeObserver(self: *MusicRuntime, reason: observer.CloseReason) void {
        const storage = self.observer_storage orelse return;
        storage.close(self.controlStatusV1(), reason);
        self.observer_storage = null;
        self.observer_handle = null;
    }

    fn bankRef(self: *const MusicRuntime) v1.BankRefV1 {
        return .{ .context = self.config.context, .handle = .{ .index = 0, .generation = self.handle_incarnation }, .asset_generation = self.generation.?.runtime_generation };
    }
    fn checkBank(self: *const MusicRuntime, reference: v1.BankRefV1) !void {
        if (reference.context != self.config.context) return error.WrongContext;
        if (self.generation == null or !reference.handle.matches(self.bankRef().handle) or reference.asset_generation != self.bankRef().asset_generation) return error.StaleAssetGeneration;
    }

    // These observations are comparison-only. The actual atomics retain their
    // original ordering/results; an offline semantic owner may schedule threads
    // at the callbacks but cannot select a state or forge a successful claim.
    fn semanticLoadPoint(self: *MusicRuntime, role: rt.live_semantic.Role, site: rt.live_semantic.Site, edge: rt.live_semantic.Edge, index: u64, generation: u64, value: ?u64) void {
        if (self.live_semantic_service_hooks) |hooks| hooks.cuts.point(hooks.cuts.context, .{ .role = role, .site = site, .edge = edge, .index = index, .generation = generation, .value = value });
    }
    fn loadStateReadSemantic(self: *MusicRuntime, role: rt.live_semantic.Role) LoadTransaction.State {
        self.semanticLoadPoint(role, .runtime_load_state_read, .before, 0, 0, null);
        const state = self.load.state.load(.acquire);
        self.semanticLoadPoint(role, .runtime_load_state_read, .after, 0, 0, @intFromEnum(state));
        return state;
    }
    fn loadStatePublishSemantic(self: *MusicRuntime, role: rt.live_semantic.Role, state: LoadTransaction.State) void {
        self.semanticLoadPoint(role, .runtime_load_state_publish, .before, @intFromEnum(state), 0, null);
        self.load.state.store(state, .release);
        self.semanticLoadPoint(role, .runtime_load_state_publish, .after, @intFromEnum(state), 0, @intFromEnum(state));
    }
    fn loadStateClaimSemantic(self: *MusicRuntime, expected: LoadTransaction.State, desired: LoadTransaction.State) ?LoadTransaction.State {
        self.semanticLoadPoint(.worker, .runtime_load_state_claim, .before, @intFromEnum(expected), @intFromEnum(desired), null);
        const observed = self.load.state.cmpxchgStrong(expected, desired, .acq_rel, .acquire);
        // Zero denotes a successful real CAS; failures carry the actual old state + 1.
        self.semanticLoadPoint(.worker, .runtime_load_state_claim, .after, @intFromEnum(expected), @intFromEnum(desired), if (observed) |state| @as(u64, @intFromEnum(state)) + 1 else 0);
        return observed;
    }
    fn workerServiceReadSemantic(self: *MusicRuntime) ?*rt.streaming.Service {
        self.semanticLoadPoint(.worker, .runtime_worker_service_read, .before, 0, 0, null);
        const service = self.worker_streaming.load(.acquire);
        self.semanticLoadPoint(.worker, .runtime_worker_service_read, .after, 0, 0, @intFromBool(service != null));
        return service;
    }
    fn workerServicePublishSemantic(self: *MusicRuntime, service: ?*rt.streaming.Service) void {
        self.semanticLoadPoint(.control, .runtime_worker_service_publish, .before, @intFromBool(service != null), 0, null);
        self.worker_streaming.store(service, .release);
        self.semanticLoadPoint(.control, .runtime_worker_service_publish, .after, @intFromBool(service != null), 0, @intFromBool(service != null));
    }

    /// Copies the complete compiled bank before return. Only the sole worker
    /// decodes/validates it. The retained terminal ticket requires acknowledgeLoad.
    pub fn loadBank(self: *MusicRuntime, compiled: []const u8) !v1.LoadTicketV1 {
        return self.loadWithSources(compiled, null);
    }
    /// Provider callbacks and borrowed context remain valid through the owned
    /// rollback/retirement acknowledgement. No callback runs on this thread.
    pub fn loadBankWithSources(self: *MusicRuntime, compiled: []const u8, provider: assets.SourceProvider) !v1.LoadTicketV1 {
        if (!self.usesIntegratedTickV1()) return error.InvalidMode;
        return self.loadWithSources(compiled, .{ .v1 = provider });
    }
    /// V2 binds original resource identity and fresh runtime custody separately.
    /// The shared pool must be explicitly attached during context construction.
    pub fn loadBankWithSourcesV2(self: *MusicRuntime, compiled: []const u8, provider: assets.SourceProviderV2) !v1.LoadTicketV1 {
        if (!self.usesIntegratedTickV1()) return error.InvalidMode;
        return self.loadWithSources(compiled, .{ .v2 = provider });
    }
    fn loadWithSources(self: *MusicRuntime, compiled: []const u8, provider: ?assets.AnySourceProvider) !v1.LoadTicketV1 {
        try self.claimControlV1();
        defer self.control_guard.store(false, .release);
        if (self.shutdown_requested.load(.acquire)) return error.RuntimeStopped;
        if (self.generation != null) return error.UnsupportedOperation;
        if (provider) |value| if (value == .v2 and self.service_custody == null) return error.UnsupportedOperation;
        if (self.load_ticket != null or self.loadStateReadSemantic(.control) != .idle) return error.LoadPending;
        // Future rebind/reload needs an execution-fenced asset epoch operation.
        if (self.handle_incarnation != 0 or self.renderer.callObservation().sequence != 0) return error.UnsupportedOperation;
        if (compiled.len == 0 or compiled.len > self.config_v1.capacity.max_bank_bytes) return error.ResourceLimitExceeded;
        if (self.next_load == std.math.maxInt(u64)) return error.TicketExhausted;
        if (@import("builtin").is_test) if (self.test_live_bootstrap) |session| {
            try session.validateOwner(self, &self.test_live_bootstrap, self.control, self.renderer);
            try session.validateSource(compiled, provider);
        };
        const bytes = try self.allocator.dupe(u8, compiled);
        const ticket: v1.LoadTicketV1 = .{ .context = self.config.context, .sequence = self.next_load };
        self.next_load += 1;
        self.bank_resource_size = bytes.len;
        self.bank_resource_hash = save.hash(bytes);
        self.load.bytes = bytes;
        self.load.input_bytes.store(bytes.len, .release);
        self.load.candidate = null;
        self.load.provider = provider;
        std.debug.assert(self.load.initial_identity == null);
        self.load.shared_preparation = self.service_custody != null;
        self.load.failure = null;
        self.load.cancelled.store(false, .release);
        self.load_ticket = ticket;
        self.load_status = .pending;
        self.state = .loading_bank;
        if (@import("builtin").is_test) if (self.test_live_bootstrap) |session| session.queued(ticket);
        self.loadStatePublishSemantic(.control, .queued);
        self.publishSnapshot();
        return ticket;
    }

    /// One host-owned Worker pump. No worker thread is spawned or joined by
    /// MusicRuntime. The allocator must support this serialized worker and Control.
    pub const LiveWorkerOutcomeV1 = struct {
        worked: bool,
        deferred: ?rt.streaming.stream.ServiceClaimAttempt = null,
    };
    pub fn workerOneV1(self: *MusicRuntime) !bool {
        return self.workerOneOwnedV1(null);
    }
    /// Same registered Worker and real progress; the opt-in result reports only
    /// the initial Service pump's actual failed claim without latching failure.
    /// Internal Host seam: recording/observer setup must remain Worker-quiescent.
    /// The Host's private owner exposes no such reconfiguration; these guards
    /// reject incompatible setup, not synchronize concurrent reconfiguration.
    pub fn workerOneLiveV1(self: *MusicRuntime) !LiveWorkerOutcomeV1 {
        if (self.config_v1.kind != .authoring or !self.usesIntegratedTickV1() or self.config_v1.streaming_reservation != .initial_bank_only) return error.InvalidMode;
        var deferred: ?rt.streaming.stream.ServiceClaimAttempt = null;
        const worked = try self.workerOneOwnedV1(&deferred);
        return .{ .worked = worked, .deferred = deferred };
    }
    fn workerOneOwnedV1(self: *MusicRuntime, deferred: ?*?rt.streaming.stream.ServiceClaimAttempt) !bool {
        try self.requireFinalizationOpen();
        try self.requireCausalRoleV1(.worker);
        if (self.mode != .versioned) return error.InvalidMode;
        if (@import("builtin").is_test) if (self.test_live_bootstrap) |session| {
            if (session.combined != null) {
                const final = self.test_finalization orelse return error.InvalidState;
                _ = try final.validateJoined(self);
                try session.enterCombined(final);
            }
        };
        errdefer |err| self.worker_failure.store(@as(u8, @intFromEnum(failureV1(err))) + 1, .release);
        if (self.worker_guard.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentWorker;
        defer self.worker_guard.store(false, .release);
        const thread = std.Thread.getCurrentId();
        if (self.worker_thread) |owner| {
            if (owner != thread) return error.WrongThread;
        } else self.worker_thread = thread;
        if (deferred != null and (self.causal_sink != null or self.causal_driver_pin != null or self.public_recording.phase != .disabled)) return error.InvalidMode;
        const bootstrap = if (@import("builtin").is_test) self.test_live_bootstrap else {};
        if (@import("builtin").is_test) if (bootstrap) |session| {
            try session.validateOwner(self, &self.test_live_bootstrap, self.control, self.renderer);
            if (session.combined == null) try session.beginWorker();
        };
        var bootstrap_failed = false;
        defer if (@import("builtin").is_test) {
            if (bootstrap) |session| if (session.combined == null) session.endWorker(bootstrap_failed);
        };
        errdefer bootstrap_failed = true;

        // The context Service continues decoding even if one generation is
        // retiring or a provider close subsequently fails. Its address/lifetime
        // is published independently of the active generation pointer.
        const streamed = if (self.workerServiceReadSemantic()) |service| blk: {
            if (deferred) |observation| switch (try service.workerOneLiveV1()) {
                .completed => |job| break :blk job != null,
                .deferred => |attempt| {
                    observation.* = attempt;
                    return false;
                },
            };
            break :blk (try service.workerOne()) != null;
        } else false;
        if (self.loadStateReadSemantic(.worker) == .retiring) {
            const candidate = self.load.candidate.?;
            const worked = try candidate.workerRetireOne();
            if (candidate.retirementAcknowledged()) {
                if (self.load.shared_preparation) {
                    // Service custody is Control-owned; Worker acknowledges but
                    // never destroys a generation that could return its credit.
                    self.loadStatePublishSemantic(.worker, .retired);
                } else {
                    if (@import("builtin").is_test) if (candidate.test_live_bootstrap) |session| {
                        if (bootstrap != session or self.load_ticket == null or self.generation != null or self.owned_streaming != null or
                            self.service_custody != null or self.control.streaming_service != null or self.worker_streaming.load(.acquire) != null or
                            self.worker_generation.load(.acquire) != null or self.outgoing_generation.load(.acquire) != null) return error.InvalidState;
                        try session.endUnpublished(self.load_ticket.?, candidate);
                    };
                    candidate.destroy();
                    self.load.candidate = null;
                    self.loadStatePublishSemantic(.worker, .completed);
                }
            }
            return worked or streamed;
        }
        if (self.loadStateClaimSemantic(.sources_queued, .sources_preparing) == null) {
            self.load.candidate.?.prepareSources(self.load.provider.?);
            self.loadStatePublishSemantic(.worker, .sources_completed);
            return true;
        }
        if (self.loadStateClaimSemantic(.queued, .preparing) == null) {
            self.loadHook(.claimed);
            self.load.candidate = (if (self.load.shared_preparation)
                Generation.prepareContentCrossfade(self.allocator, self.load.bytes, self.load.provider != null, self.config_v1.policy_support, self.config_v1.layer_gain, self.fillPcmMode(), self.config_v1.streaming_reservation == .release_profile, self.config_v1.crossfade)
            else if (@import("builtin").is_test and self.test_live_bootstrap != null)
                Generation.BootstrapTests.prepare(self.allocator, self.load.bytes, if (self.load.provider) |value| value.v1 else null, self.config_v1.policy_support, self.config_v1.layer_gain, self.fillPcmMode(), self.config_v1.streaming_reservation == .release_profile, self.config_v1.crossfade, self.test_live_bootstrap.?, self.load_ticket orelse return error.InvalidState)
            else if (self.live_semantic_service_hooks) |hooks|
                Generation.prepareSemanticCrossfade(self.allocator, self.load.bytes, if (self.load.provider) |value| value.v1 else null, self.config_v1.policy_support, self.config_v1.layer_gain, self.fillPcmMode(), self.config_v1.streaming_reservation == .release_profile, self.config_v1.crossfade, hooks)
            else
                Generation.prepareProfileCrossfade(self.allocator, self.load.bytes, if (self.load.provider) |value| value.v1 else null, self.config_v1.policy_support, self.config_v1.layer_gain, self.fillPcmMode(), self.config_v1.streaming_reservation == .release_profile, self.config_v1.crossfade)) catch |err| blk: {
                self.load.failure = failureV1(err);
                break :blk null;
            };
            self.allocator.free(self.load.bytes);
            self.load.bytes = &.{};
            self.load.input_bytes.store(0, .release);
            if (self.load.candidate) |candidate| if (candidate.preparation_failure) |err| {
                self.load.failure = failureV1(err);
                try candidate.requestRetirement();
                self.loadStatePublishSemantic(.worker, .retiring);
                return true;
            };
            // A cancelled late result remains in this owned slot until Control
            // requests rollback; only a worker can acknowledge provider close.
            self.loadHook(.prepared);
            self.loadStatePublishSemantic(.worker, .completed);
            return true;
        }
        if (try self.prepareReloadWorker()) return true;
        if (self.outgoing_generation.load(.acquire)) |generation| {
            if (try generation.workerRetireOne()) return true;
        }
        if (self.worker_generation.load(.acquire)) |generation| {
            if (try generation.workerRetireOne()) return true;
        }
        return streamed;
    }

    fn loadHook(self: *MusicRuntime, stage: LoadStage) void {
        if (@import("builtin").is_test) if (self.test_load_hook) |hook| hook.call(hook.context, stage);
    }

    fn cancelInitialIdentity(self: *MusicRuntime) void {
        if (self.load.initial_identity) |identity| {
            self.generations.cancelInitialIdentity(identity) catch unreachable;
            self.load.initial_identity = null;
        }
    }
    fn rollbackLoad(self: *MusicRuntime, candidate: *Generation, failure: v1.FailureV1) !void {
        // Unadopted graph reservation has no Render binding or schedule refs.
        // Release it before handing the candidate to Worker close rollback.
        if (self.generation != candidate) if (self.policy_storage) |storage| if (storage.graph) |graph| {
            std.debug.assert(storage.bootstrap == null and !storage.graph_installed);
            if (self.tick_scope) |scope| try scope.releaseBusGraph(graph.handle) else try self.control.releaseBusGraph(graph.handle);
            storage.graph = null;
        };
        self.load.failure = failure;
        if (candidate.sources.len != 0) {
            try candidate.requestRetirement();
            self.loadStatePublishSemantic(.control, .retiring);
            return;
        }
        candidate.destroy();
        self.load.candidate = null;
        self.cancelInitialIdentity();
        self.load_status = .{ .failed = failure };
        self.loadStatePublishSemantic(.control, .idle);
        if (!self.shutdown_requested.load(.acquire)) self.state = .uninitialized;
    }
    fn collectLoad(self: *MusicRuntime) !void {
        defer self.collectReload();
        const failure = self.worker_failure.load(.acquire);
        if (failure != 0) self.last_error = @enumFromInt(failure - 1);
        const load_state = self.loadStateReadSemantic(.control);
        if (load_state == .retired) {
            const retired = self.load.candidate.?;
            std.debug.assert(retired.retirementAcknowledged());
            self.load.candidate = null;
            retired.destroy();
            self.cancelInitialIdentity();
            self.assertServiceCredits();
            self.load_status = .{ .failed = if (self.load.cancelled.load(.acquire) or self.shutdown_requested.load(.acquire)) .cancelled else self.load.failure orelse .internal_failure };
            self.loadStatePublishSemantic(.control, .idle);
            if (!self.shutdown_requested.load(.acquire)) self.state = .uninitialized;
            return;
        }
        if (load_state != .completed and load_state != .sources_completed) return;
        const candidate = self.load.candidate;
        if (self.load.cancelled.load(.acquire) or self.shutdown_requested.load(.acquire)) {
            if (candidate) |value| return self.rollbackLoad(value, .cancelled);
            self.load_status = .{ .failed = .cancelled };
            self.loadStatePublishSemantic(.control, .idle);
            return;
        }
        if (candidate) |value| {
            // Only the exact startup-linked combined session can transfer its
            // Service borrow. Bootstrap-only success remains unpublished.
            if (@import("builtin").is_test) if (self.test_live_bootstrap) |session| {
                const ticket = self.load_ticket orelse return error.InvalidState;
                try session.validateTicket(ticket);
                if (session.combined == null) return error.InvalidMode;
                if (value.preparation_failure) |err| return self.rollbackLoad(value, failureV1(err));
                const final = self.test_finalization orelse return error.InvalidState;
                if (try final.publication(self) != session) return error.InvalidState;
                // Service-only scope: a resident candidate remains unpublished
                // and is retired by genuine shutdown/cancellation.
                try session.validateTransfer(ticket, value);
            };
            if (self.load.shared_preparation and load_state == .completed and self.load.initial_identity == null) {
                // Real initial content was acquired first. Authenticate initial
                // registry identity before any provider receives it; no bank
                // metadata is rewritten and no registry ownership is fabricated.
                const identity: generation_registry.Identity = .{ .build_id = buildId(value.loaded.content_hash), .content_hash = value.loaded.content_hash };
                const reserved = self.generations.reserveInitialIdentity(identity, @enumFromInt(value.loaded.metadata.generation)) catch |err| return self.rollbackLoad(value, failureV1(err));
                self.load.initial_identity = reserved;
                value.assignRuntimeIdentity(reserved.generation.value()) catch unreachable;
                if (value.sources.len != 0) {
                    self.bindCandidateService(value) catch |err| return self.rollbackLoad(value, failureV1(err));
                    self.loadStatePublishSemantic(.control, .sources_queued);
                    return;
                }
            }
            if (value.preparation_failure) |err| return self.rollbackLoad(value, failureV1(err));
            // Graph reservation is prepare-phase Control work. Keep the real
            // candidate in its owned load slot until that reservation succeeds.
            if (value.loaded.bus_graph != null and self.policy_storage.?.graph == null) return;
            if (self.config_v1.sfx_generation_custody == .bounded_v1) value.allocatePlayCustody() catch |err| return self.rollbackLoad(value, failureV1(err));
            value.activate(self.config) catch |err| {
                self.last_error = failureV1(err);
                return self.rollbackLoad(value, self.last_error.?);
            };
            // Startup adoption still requires actual callback quiescence.
            if (self.renderer.callObservation().sequence != 0) {
                self.last_error = .invalid_state;
                return self.rollbackLoad(value, .invalid_state);
            }
            // Preflight the exact initial registry transfer before attaching
            // a Service. Control stays serialized through the infallible adopt.
            const identity: generation_registry.Identity = .{ .build_id = buildId(value.loaded.content_hash), .content_hash = value.loaded.content_hash };
            const initial_generation: api.AssetGeneration = @enumFromInt(value.runtime_generation);
            if (self.load.initial_identity) |reserved| {
                std.debug.assert(std.meta.eql(identity, reserved.identity) and initial_generation == reserved.generation);
                self.generations.validateInitialReservation(reserved) catch |err| return self.rollbackLoad(value, failureV1(err));
            } else self.generations.validateInitialAdoption(identity, initial_generation) catch |err| return self.rollbackLoad(value, failureV1(err));
            if (value.service_custody == null) if (value.service) |service| {
                std.debug.assert(self.service_custody == null and self.owned_streaming == null);
                self.service_custody = .{ .service = service };
                value.bindSharedService(&self.service_custody.?) catch unreachable;
                self.attachInitialService(service) catch |err| {
                    value.undoSharedServiceTransfer();
                    self.service_custody = null;
                    return self.rollbackLoad(value, failureV1(err));
                };
                if (@import("builtin").is_test) if (self.test_live_bootstrap) |session| session.transfer(value);
                self.owned_streaming = service;
                self.workerServicePublishSemantic(service);
            };
            const handle = if (self.load.initial_identity) |reserved|
                self.generations.adoptReservedInitial(value, reserved) catch |err| return self.rollbackLoad(value, failureV1(err))
            else
                self.generations.adoptInitial(value, identity, initial_generation) catch unreachable;
            self.load.initial_identity = null;
            value.registered(&self.generations, handle);
            value.bindPlayCustody(self.config.context);
            self.assertServiceCredits();
            self.generation = value;
            self.device_stream_origin = null;
            self.load.candidate = null;
            self.handle_incarnation += 1;
            if (value.layer_owner) |owner| owner.adopt(self.bankRef(), value.runtime_generation) catch unreachable;
            self.control.scheduled.asset_generation = value.runtime_generation;
            self.worker_generation.store(value, .release);
            if (value.loaded.bus_graph == null) self.publishLoadReady() else self.state = .loading_bank;
        } else {
            self.last_error = self.load.failure orelse .internal_failure;
            self.load_status = .{ .failed = self.last_error.? };
            self.state = .uninitialized;
        }
        self.loadStatePublishSemantic(.control, .idle);
    }

    fn attachInitialService(self: *MusicRuntime, service: *rt.streaming.Service) !void {
        // The Control/Render attachment field is plain startup-only storage.
        if (self.renderer.callObservation().sequence != 0) return error.InvalidState;
        if (self.tick_scope) |scope| return scope.attachStreaming(service, null);
        return self.control.attachStreaming(service, null);
    }

    // Internal transaction entry, deliberately absent from the public facade.
    // Copies input and pins the exact source before the Worker can claim it.
    fn beginReloadPreparation(self: *MusicRuntime, source: v1.BankRefV1, compiled: []const u8) !reload_staging.Ticket {
        return self.beginReloadWithSources(source, compiled, null);
    }
    fn beginReloadWithSources(self: *MusicRuntime, source: v1.BankRefV1, compiled: []const u8, provider: ?assets.SourceProvider) !reload_staging.Ticket {
        return self.beginReloadWithProvider(source, compiled, if (provider) |value| .{ .v1 = value } else null);
    }
    fn beginReloadWithSourcesV2(self: *MusicRuntime, source: v1.BankRefV1, compiled: []const u8, provider: assets.SourceProviderV2) !reload_staging.Ticket {
        return self.beginReloadWithProvider(source, compiled, .{ .v2 = provider });
    }
    fn beginReloadWithProvider(self: *MusicRuntime, source: v1.BankRefV1, compiled: []const u8, provider: ?assets.AnySourceProvider) !reload_staging.Ticket {
        try self.claimControlV1();
        defer self.control_guard.store(false, .release);
        if (self.shutdown_requested.load(.acquire)) return error.RuntimeStopped;
        try self.checkBank(source);
        if (self.unloading) return error.DrainPending;
        if (self.preview_seek != null) return error.ResidentTransactionBusy;
        if (self.reload.state.load(.acquire) != .idle) return error.LoadPending;
        if (provider != null and !self.usesIntegratedTickV1()) return error.InvalidMode;
        if (compiled.len == 0 or compiled.len > self.config_v1.capacity.max_bank_bytes) return error.ResourceLimitExceeded;
        if (self.reload.next_sequence == std.math.maxInt(u64)) return error.TicketExhausted;
        const bytes = try self.allocator.dupe(u8, compiled);
        errdefer self.allocator.free(bytes);
        const generation = self.generation.?;
        try generation.retainPreparation();
        const ticket: reload_staging.Ticket = .{ .source = source, .sequence = self.reload.next_sequence };
        self.reload.next_sequence += 1;
        self.reload.bytes = bytes;
        self.reload.input_bytes.store(bytes.len, .release);
        self.reload.candidate = null;
        self.reload.failure = null;
        self.reload.source = generation;
        self.reload.ticket = ticket;
        self.reload.status = .pending;
        self.reload.terminal_status = null;
        self.reload_provider = provider;
        self.reload.abort_reason = .requested;
        self.reload.cancelled.store(false, .release);
        self.reload.state.store(.queued, .release);
        return ticket;
    }

    // Called only under the same Worker guard/thread check as initial loading.
    fn prepareReloadWorker(self: *MusicRuntime) !bool {
        if (self.reload.state.load(.acquire) == .retiring) {
            const candidate = self.reload.candidate.?;
            const worked = try candidate.workerRetireOne();
            if (candidate.retirementAcknowledged()) self.reload.state.store(.retired, .release);
            return worked;
        }
        if (self.reload.state.cmpxchgStrong(.sources_queued, .sources_preparing, .acq_rel, .acquire) == null) {
            self.reload.candidate.?.prepareSources(self.reload_provider.?);
            self.reload.state.store(.sources_completed, .release);
            return true;
        }
        if (self.reload.state.cmpxchgStrong(.queued, .preparing, .acq_rel, .acquire) != null) return false;
        self.loadHook(.claimed);
        self.reload.candidate = Generation.prepareContentBindingsReservation(self.allocator, self.reload.bytes, self.reload_provider != null, self.config_v1.policy_support, self.config_v1.layer_gain, self.fillPcmMode(), self.config_v1.streaming_reservation == .release_profile) catch |err| blk: {
            self.reload.failure = failureV1(err);
            break :blk null;
        };
        // Public streamed candidates retain the exact authenticated image.
        // Transfer before clearing Worker input ownership; never reconstruct it.
        if (self.reload.candidate) |candidate| {
            if (self.reload_provider != null and self.reload_provider.? == .v2 and self.live_reload != null and self.live_reload.?.streamed) {
                candidate.adoptCompiledImage(self.reload.bytes);
                self.reload.bytes = &.{};
            }
        }
        self.allocator.free(self.reload.bytes);
        self.reload.bytes = &.{};
        self.reload.input_bytes.store(0, .release);
        self.loadHook(.prepared);
        self.reload.state.store(.completed, .release);
        return true;
    }

    fn finishReloadPreparation(self: *MusicRuntime, status: reload_staging.Status) void {
        std.debug.assert(status.terminal());
        const state = self.reload.state.load(.acquire);
        std.debug.assert(state == .held or state == .completed or state == .sources_completed or state == .retired);
        self.reload.terminal_status = status;
        self.reload.status = .pending;
        self.clearReloadAdmission();
        if (self.reload.candidate) |value| {
            if (self.live_reload) |live| if (live.streamed and live.request_windows_owned) {
                value.retireRequestWindows(live.ticket.request_id);
                value.collectWindows() catch |err| {
                    self.last_error = failureV1(err);
                    return;
                };
                if (value.requestWindowCount(live.ticket.request_id) != 0) return;
                live.request_windows_owned = false;
            };
            if (value.registry != null) {
                self.generations.closeBorrowed(value.registry_handle.?) catch unreachable;
                if (value.preparation_leases != 0) value.releasePreparation();
                value.closePlayCustody();
                if (value.play_custody_funded) return;
                // A prepared candidate can already occur in normal Control
                // snapshots before its gate. Keep its original allocation and
                // registry credit until actual slot reuse returns every pin.
                if (value.hasSnapshotLeases()) return;
            }
            if (value.service_custody != null) {
                // Real source metadata remains owned through Worker close ack.
                // No provider callback, Service reset or storage free on Control.
                value.requestRetirement() catch return;
                if (!value.retirementAcknowledged()) {
                    self.reload.status = .pending;
                    self.reload.state.store(.retiring, .release);
                    return;
                }
            }
            // A retirement acknowledgement may precede Worker's final return.
            // Acquire its original guard rather than sampling a boolean flag.
            if (self.worker_guard.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return;
            defer self.worker_guard.store(false, .release);
            self.reload.candidate = null;
            if (value.registry != null) value.withdraw();
            value.destroy();
            self.assertServiceCredits();
        }
        const source = self.reload.source.?;
        self.reload.source = null;
        source.releasePreparation();
        self.reload_provider = null;
        self.reload.status = status;
        self.reload.terminal_status = null;
        // The source is pinned through actual candidate/provider cleanup.
        self.reload.state.store(.terminal, .release);
    }

    fn publishPreparedReload(self: *MusicRuntime) void {
        const candidate = self.reload.candidate.?;
        const source = self.reload.source.?;
        self.reload.status = .{ .assets_prepared = .{
            .source_build_id = buildId(source.loaded.content_hash),
            .target_build_id = buildId(candidate.loaded.content_hash),
            .content_hash = candidate.loaded.content_hash,
            .authored_generation = candidate.loaded.metadata.generation,
        } };
    }
    /// Bounded source-preparation budget only. It reserves no retention history,
    /// command/receipt capacity or minimum ready media for activation. The one
    /// Service has a conservative all-slot decoder bound; each generation adds
    /// its actual stable source-record storage once. Provider-private memory and
    /// partial Worker allocation remain unknown for final retention admission.
    fn bindCandidateService(self: *MusicRuntime, candidate: *Generation) !void {
        const custody = if (self.service_custody) |*value| value else return error.UnsupportedOperation;
        std.debug.assert(self.owned_streaming == custody.service);
        var bytes = try rt.streaming.Service.capacityBytes(custody.service.profile);
        if (candidate.registry == null) bytes = try std.math.add(usize, bytes, candidate.sourceStorageBytes());
        for (self.generations.entries) |entry| if (entry) |value| {
            bytes = try std.math.add(usize, bytes, value.payload.sourceStorageBytes());
        };
        if (bytes > rt.virtual_voice.releaseProfile().stream_budget_bytes) return error.ResourceLimitExceeded;
        try candidate.bindSharedService(custody);
        candidate.authorizeSourceIdentity(self.config.context) catch unreachable;
        self.assertServiceCredits();
    }
    fn collectReload(self: *MusicRuntime) void {
        const state = self.reload.state.load(.acquire);
        if (state == .retired or (state == .held and self.reload.terminal_status != null)) {
            self.finishReloadPreparation(self.reload.terminal_status.?);
            return;
        }
        if (state != .completed and state != .sources_completed) return;
        self.reload.state.store(.held, .release);
        if (self.reload.cancelled.load(.acquire)) {
            self.finishReloadPreparation(.{ .aborted = self.reload.abort_reason });
            return;
        }
        if (self.generation != self.reload.source or self.generation == null or !std.meta.eql(self.bankRef(), self.reload.ticket.?.source)) {
            self.finishReloadPreparation(.{ .failed = .stale_bank });
            return;
        }
        const candidate = self.reload.candidate orelse {
            self.finishReloadPreparation(.{ .failed = self.reload.failure orelse .internal_failure });
            return;
        };
        if (state == .sources_completed) {
            if (candidate.preparation_failure) |err| {
                self.finishReloadPreparation(.{ .failed = failureV1(err) });
                return;
            }
            self.publishPreparedReload();
            return;
        }
        const source = self.reload.source.?;
        // Both hashes come from genuinely loaded/validated owned content. This
        // path performs no identity reservation, provider open or Service bind.
        if (std.mem.eql(u8, &candidate.loaded.content_hash, &source.loaded.content_hash)) {
            self.finishReloadPreparation(.unchanged);
            return;
        }
        if (self.live_reload != null) {
            // Public path validates topology/maps and real live ownership before
            // consuming any fresh identity or publishing any physical command.
            self.publishPreparedReload();
            return;
        }
        if (self.config_v1.sfx_generation_custody == .bounded_v1) candidate.allocatePlayCustody() catch |err| {
            self.finishReloadPreparation(.{ .failed = failureV1(err) });
            return;
        };
        const handle = self.generations.adoptCandidate(candidate, .{ .build_id = buildId(candidate.loaded.content_hash), .content_hash = candidate.loaded.content_hash }) catch |err| {
            self.finishReloadPreparation(.{ .failed = failureV1(err) });
            return;
        };
        candidate.registered(&self.generations, handle);
        candidate.retainPreparation() catch unreachable;
        const identity = self.generations.reserveCandidateIdentity(handle) catch |err| {
            self.finishReloadPreparation(.{ .failed = failureV1(err) });
            return;
        };
        candidate.assignRuntimeIdentity(identity.value()) catch unreachable;
        candidate.bindPlayCustody(self.config.context);
        if (candidate.sources.len != 0) {
            self.bindCandidateService(candidate) catch |err| {
                self.finishReloadPreparation(.{ .failed = failureV1(err) });
                return;
            };
            // Release publication follows identity, registry/preparation credit,
            // bounded source budget and actual context-Service custody acquisition.
            self.reload.state.store(.sources_queued, .release);
            return;
        }
        self.publishPreparedReload();
    }

    fn checkReloadTicket(self: *const MusicRuntime, ticket: reload_staging.Ticket) !void {
        if (ticket.source.context != self.config.context) return error.WrongContext;
        if (self.reload.ticket == null or !std.meta.eql(ticket, self.reload.ticket.?)) return error.InvalidHandle;
    }
    fn pollReloadPreparation(self: *MusicRuntime, ticket: reload_staging.Ticket) !reload_staging.Status {
        try self.claimControlV1();
        defer self.control_guard.store(false, .release);
        try self.checkReloadTicket(ticket);
        self.collectReload();
        return self.reload.status;
    }
    fn abortReloadOwned(self: *MusicRuntime, reason: reload_staging.AbortReason) void {
        if (!self.reload.ownsResources()) return;
        if (!self.reload.cancelled.load(.acquire)) {
            self.reload.abort_reason = reason;
            self.reload.cancelled.store(true, .release);
        }
        while (true) switch (self.reload.state.load(.acquire)) {
            .queued => {
                if (self.reload.state.cmpxchgStrong(.queued, .held, .acq_rel, .acquire) != null) continue;
                self.allocator.free(self.reload.bytes);
                self.reload.bytes = &.{};
                self.reload.input_bytes.store(0, .release);
                self.finishReloadPreparation(.{ .aborted = self.reload.abort_reason });
                return;
            },
            .sources_queued => {
                if (self.reload.state.cmpxchgStrong(.sources_queued, .held, .acq_rel, .acquire) != null) continue;
                self.finishReloadPreparation(.{ .aborted = self.reload.abort_reason });
                return;
            },
            .preparing, .sources_preparing, .retiring => return,
            .completed, .sources_completed, .retired => {
                self.collectReload();
                return;
            },
            .held => {
                self.finishReloadPreparation(.{ .aborted = self.reload.abort_reason });
                return;
            },
            .idle, .terminal => return,
        };
    }
    fn abortReloadPreparation(self: *MusicRuntime, ticket: reload_staging.Ticket) !reload_staging.Status {
        try self.claimControlV1();
        defer self.control_guard.store(false, .release);
        try self.checkReloadTicket(ticket);
        self.abortReloadOwned(.requested);
        return self.reload.status;
    }
    fn acknowledgeReloadPreparation(self: *MusicRuntime, ticket: reload_staging.Ticket) !void {
        try self.claimControlV1();
        defer self.control_guard.store(false, .release);
        try self.checkReloadTicket(ticket);
        if (self.reload.state.load(.acquire) != .terminal) return error.DrainPending;
        self.reload.ticket = null;
        self.reload.state.store(.idle, .release);
    }
    fn reloadDiagnostics(self: *MusicRuntime) !reload_staging.Diagnostics {
        try self.claimControlV1();
        defer self.control_guard.store(false, .release);
        const state = self.reload.state.load(.acquire);
        return .{
            .source_preparation_leases = if (self.generation) |g| g.preparation_leases else 0,
            .pending_plan_leases = if (self.generation) |g| g.pending_plan_leases else 0,
            .candidate_owned = if (state == .held or state == .completed or state == .sources_completed or state == .retired) self.reload.candidate != null else false,
            .input_bytes = self.reload.input_bytes.load(.acquire),
            .worker_preparing = state == .preparing or state == .sources_preparing or state == .retiring,
        };
    }
    fn clearReloadAdmission(self: *MusicRuntime) void {
        self.generations.invalidateAdmission();
        if (self.reload_epoch_policy) |*rules| rules.deinit();
        self.reload_epoch_policy = null;
        if (self.reload_map) |*map| map.deinit();
        self.reload_map = null;
    }
    fn reloadContractBytes(self: *const MusicRuntime) !u64 {
        var bytes: u64 = 0;
        if (self.reload_map) |map| {
            bytes = try std.math.add(u64, bytes, try std.math.mul(u64, map.description.states.len, @sizeOf(migration.StateMapping)));
            bytes = try std.math.add(u64, bytes, try std.math.mul(u64, map.description.segments.len, @sizeOf(migration.SegmentMapping)));
            bytes = try std.math.add(u64, bytes, try std.math.mul(u64, map.description.selectors.len, @sizeOf(migration.SelectorMapping)));
        }
        if (self.reload_epoch_policy) |rules| bytes = try std.math.add(u64, bytes, try std.math.mul(u64, rules.description.entries.len, @sizeOf(epoch_policy.Entry)));
        return bytes;
    }
    fn refreshRegistryObservations(self: *MusicRuntime) !void {
        self.collectBorrowedSounds();
        // Queued may already have become preparing. No Worker-mutated candidate
        // fields are read until completed ownership was acquired by Control.
        const load_state = self.load.state.load(.acquire);
        const reload_state = self.reload.state.load(.acquire);
        if (load_state == .queued or load_state == .preparing or load_state == .sources_queued or load_state == .sources_preparing or load_state == .retiring or reload_state == .queued or reload_state == .preparing or reload_state == .sources_queued or reload_state == .sources_preparing or reload_state == .retiring) {
            self.generations.invalidateAdmission();
            return error.UnknownWorkerMemory;
        }
        // First slice only: once callbacks have run, real published/acquired/
        // voice/PCM/stream provider facts are not complete here. Aggregate sample
        // refcounts are rejection signals, never manufactured lease totals.
        var physical_unknown = self.preparing != null or self.resuming_request != null or self.owned_streaming != null or self.control.source_continuity_manager != null or self.event_adapter != null or self.renderer.callObservation().sequence != 0 or self.pending != null or self.active_group != null or self.active_producers.load(.acquire) != 0 or self.ingress.occupied.load(.acquire) != 0;
        // Policy graph/plan/duck ownership is real but not yet represented by
        // this narrow host-quiescent retention inventory. Reject incomplete
        // coverage; the fixed context Storage allocation is counted separately.
        if (self.policy_storage) |storage| physical_unknown = physical_unknown or storage.graph != null or storage.bootstrap != null or storage.physicalCount() != 0 or storage.planCount() != 0;
        for (self.retired_groups) |group| physical_unknown = physical_unknown or group != null;
        for (self.generations.entries) |entry| if (entry) |value| {
            // This semantic merge does not pretend provider/stream ownership
            // is complete. Preserve rejection until real shared-Service admission.
            if (value.borrowed_resident_pcm != 0 or value.payload.sources.len != 0 or value.payload.service != null) physical_unknown = true;
            for (value.payload.owners) |*owner| if (owner.referenceCount() != 1) {
                physical_unknown = true;
            };
        };
        if (physical_unknown) {
            self.generations.invalidateAdmission();
            return error.UnknownPhysicalOwnership;
        }
        const contracts_bytes = try self.reloadContractBytes();
        for (self.generations.entries, 0..) |entry, i| if (entry) |value| {
            value.payload.assertControlCredits();
            var bytes = try value.payload.retainedBytes();
            // MusicRuntime embeds registry, slots, snapshots and contract values;
            // charge it and the separate return anchor ONCE to active. Heap
            // contract arrays belong to candidate ONCE. Host Control/Renderer/backend are separate owners.
            bytes = try std.math.add(u64, bytes, if (value.candidate) contracts_bytes else self.sharedStorageBytes());
            try self.generations.observe(.{ .index = @intCast(i), .incarnation = self.generations.incarnations[i] }, .{ .retained_bytes = bytes, .coverage = .complete });
        };
    }
    // Host-quiescent owned-assets/Control-credit admission, before any Render call.
    // The host keeps callbacks stopped throughout this internal initial window.
    // It is not minimum media/command/receipt reservation or full migration.
    fn admitReloadOwnership(self: *MusicRuntime, ticket: reload_staging.Ticket, map: *const migration.MigrationMapV1, rules: *const epoch_policy.RuntimeMigrationPolicyV1, profile: retention.GenerationRetentionProfile, diagnostic: ?*epoch_policy.Diagnostic) !generation_registry.Admission {
        try self.claimControlV1();
        defer self.control_guard.store(false, .release);
        try self.checkReloadTicket(ticket);
        self.collectReload();
        try self.refreshRegistryObservations();
        if (self.reload.state.load(.acquire) != .held or self.reload.status != .assets_prepared) return error.InvalidState;
        try self.checkBank(ticket.source);
        if (self.shutdown_requested.load(.acquire) or self.unloading) return error.DrainPending;
        const source = self.reload.source.?;
        const candidate = self.reload.candidate.?;
        const inventory = try self.allocator.create(ReloadInventory);
        defer self.allocator.destroy(inventory);
        try inventory.source.init(source.loaded.tables);
        try inventory.target.init(candidate.loaded.tables);
        const context = inventory.context(buildId(source.loaded.content_hash), buildId(candidate.loaded.content_hash));
        try map.validateFor(context); // Never sanitize a mutated map by rehashing it.
        try rules.validateFor(map, context, inventory.catalogs(), diagnostic);
        // This first slice proves exact catalogs and explicit epoch intent only.
        // Full cursor/revision/history transplant remains activation preparation.
        const owned = blk: {
            var owned_map = try migration.MigrationMapV1.init(self.allocator, map.description, context);
            errdefer owned_map.deinit();
            const owned_policy = try epoch_policy.RuntimeMigrationPolicyV1.init(self.allocator, rules.description, &owned_map, context, inventory.catalogs(), diagnostic);
            break :blk .{ .map = owned_map, .policy = owned_policy };
        };
        // Clone fully before freeing a prior owned value, so even an internal
        // alias cannot become a dangling input. Control scratch and replacement
        // copy overlap are transient allocation work, not retained reservations.
        self.clearReloadAdmission();
        self.reload_map = owned.map;
        self.reload_epoch_policy = owned.policy;
        errdefer self.clearReloadAdmission();
        try self.refreshRegistryObservations();
        return try self.generations.admit(candidate.registry_handle.?, profile, self.reload_map.?.content_hash, self.reload_epoch_policy.?.content_hash);
    }
    fn validateReloadAdmission(self: *MusicRuntime, ticket: reload_staging.Ticket, admission: generation_registry.Admission) !void {
        try self.claimControlV1();
        defer self.control_guard.store(false, .release);
        try self.checkReloadTicket(ticket);
        try self.checkBank(ticket.source);
        try self.refreshRegistryObservations();
        try self.generations.validateAdmission(admission);
    }
    const RegistryEntryView = struct { handle: generation_registry.Handle, candidate: bool, runtime_generation: api.AssetGeneration, build_id: u64, content_hash: [32]u8, control_plan_leases: u64, prepared_music_groups: u64, snapshot_slots: u64, play_envelopes: u64, borrowed_resident_pcm: u64, borrowed_acquisition_open: bool, retained_bytes: u64 };
    fn registryEntry(self: *MusicRuntime, handle: generation_registry.Handle) !RegistryEntryView {
        try self.claimControlV1();
        defer self.control_guard.store(false, .release);
        const entry = try self.generations.get(handle);
        entry.payload.assertControlCredits();
        return .{ .handle = handle, .candidate = entry.candidate, .runtime_generation = entry.generation, .build_id = entry.identity.build_id, .content_hash = entry.identity.content_hash, .control_plan_leases = entry.control_plan_leases, .prepared_music_groups = entry.prepared_music_groups, .snapshot_slots = entry.snapshot_slots, .play_envelopes = entry.play_envelopes, .borrowed_resident_pcm = entry.borrowed_resident_pcm, .borrowed_acquisition_open = entry.borrowed_acquisition_open, .retained_bytes = try entry.payload.retainedBytes() };
    }
    const RegistryView = struct { count: usize, active: ?generation_registry.Handle, candidate: ?generation_registry.Handle, high_water: u64, shared_storage_bytes: u64, contract_storage_bytes: u64 };
    fn registryView(self: *MusicRuntime) !RegistryView {
        try self.claimControlV1();
        defer self.control_guard.store(false, .release);
        const state = self.reload.state.load(.acquire);
        return .{ .count = self.generations.count(), .active = self.generations.active, .candidate = if (state == .held) (if (self.reload.candidate) |candidate| candidate.registry_handle else null) else null, .high_water = self.generations.high_water, .shared_storage_bytes = self.sharedStorageBytes(), .contract_storage_bytes = try self.reloadContractBytes() };
    }
    fn borrowedSoundSnapshot(self: *MusicRuntime) !borrowed_sound.Snapshot {
        try self.claimSoundControl();
        defer self.control_guard.store(false, .release);
        self.assertBorrowedCredits();
        return self.borrowed_sounds.snapshot();
    }
    fn collectBorrowedSoundReturns(self: *MusicRuntime) !void {
        try self.claimSoundControl();
        defer self.control_guard.store(false, .release);
        self.collectBorrowedSounds();
    }
    const BorrowedOwnerView = struct { references: u32, retired: bool, pcm_bytes: u64 };
    fn borrowedSoundOwnerView(self: *MusicRuntime, sound_id: u64) !BorrowedOwnerView {
        try self.claimSoundControl();
        defer self.control_guard.store(false, .release);
        const generation = self.generation orelse return error.InvalidState;
        const index = try find(generation.loaded.tables.sounds, sound_id);
        const owner = &generation.owners[index];
        return .{ .references = owner.referenceCount(), .retired = owner.retired.load(.acquire), .pcm_bytes = owner.samples.len * @sizeOf(f32) };
    }
    /// Access only to the identical production return/collection algorithm.
    pub const BorrowedSoundTesting = if (@import("builtin").is_test) struct {
        pub const snapshot = borrowedSoundSnapshot;
        pub const owner = borrowedSoundOwnerView;
        pub const collect = collectBorrowedSoundReturns;
        pub const nextIncarnation = borrowed_sound.nextIncarnation;
        pub const max_incarnation = borrowed_sound.max_incarnation;
        pub const anchor_bytes = @sizeOf(borrowed_sound.Anchor);
    } else void;
    const SharedServiceView = struct {
        generation_leases: u32,
        service_bytes: u64,
        candidate_generation: ?u64,
        candidate_authored_generation: ?u64,
        candidate_source_bytes: u64,
    };
    fn sharedServiceView(self: *MusicRuntime) !SharedServiceView {
        try self.claimControlV1();
        defer self.control_guard.store(false, .release);
        self.assertServiceCredits();
        const state = self.reload.state.load(.acquire);
        // Content preparation owns/mutates the pointer. Later source phases
        // mutate only SourceRecord payload, never these acquired fixed fields.
        const candidate = if (state == .queued or state == .preparing) null else self.reload.candidate;
        return .{
            .generation_leases = if (self.service_custody) |custody| custody.generation_leases else 0,
            .service_bytes = if (self.owned_streaming) |service| service.memory().total_requested_bytes else 0,
            .candidate_generation = if (candidate) |value| value.runtime_generation else null,
            .candidate_authored_generation = if (candidate) |value| value.loaded.metadata.generation else null,
            .candidate_source_bytes = if (candidate) |value| value.sourceStorageBytes() else 0,
        };
    }
    pub const SharedServiceTesting = if (@import("builtin").is_test) struct {
        pub const view = sharedServiceView;
    } else void;
    /// Test access only. These are the identical private production operations.
    pub const RegistryTesting = if (@import("builtin").is_test) struct {
        pub const view = registryView;
        pub const entry = registryEntry;
        pub const admit = admitReloadOwnership;
        pub const validate = validateReloadAdmission;
    } else void;

    /// Access only: these aliases invoke the exact production implementations.
    /// There are no test-created generations, fake receipts or alternate owners.
    pub const ReloadTesting = if (@import("builtin").is_test) struct {
        pub const begin = beginReloadPreparation;
        pub const beginWithSources = beginReloadWithSources;
        pub const beginWithSourcesV2 = beginReloadWithSourcesV2;
        pub const poll = pollReloadPreparation;
        pub const abort = abortReloadPreparation;
        pub const acknowledge = acknowledgeReloadPreparation;
        pub const diagnostics = reloadDiagnostics;
    } else void;

    pub fn pollLoad(self: *MusicRuntime, ticket: v1.LoadTicketV1) !v1.LoadStatusV1 {
        try self.claimControlV1();
        defer self.control_guard.store(false, .release);
        if (ticket.context != self.config.context) return error.WrongContext;
        if (self.load_ticket == null or !std.meta.eql(ticket, self.load_ticket.?)) return error.InvalidHandle;
        try self.collectLoad();
        self.publishSnapshot();
        return self.load_status;
    }
    /// Host-visible authority for the explicit graph bootstrap handoff. The
    /// original pending/ready/failed union remains source compatible.
    pub fn loadProgressV1(self: *MusicRuntime, ticket: v1.LoadTicketV1) !v1.LoadProgressV1 {
        try self.claimControlV1();
        defer self.control_guard.store(false, .release);
        if (ticket.context != self.config.context) return error.WrongContext;
        if (self.load_ticket == null or !std.meta.eql(ticket, self.load_ticket.?)) return error.InvalidHandle;
        const permitted = self.renderPermittedV1();
        const stage: @FieldType(v1.LoadProgressV1, "stage") = switch (self.load_status) {
            .ready => .ready,
            .failed => .failed,
            .pending => switch (self.load.state.load(.acquire)) {
                .queued, .sources_queued => .queued,
                .preparing, .sources_preparing => .worker_preparation,
                .retiring, .retired => .retiring,
                .completed, .sources_completed, .idle => if (permitted and self.generation != null and self.generation.?.loaded.bus_graph != null) .bootstrap else .control_admission,
            },
        };
        return .{ .stage = stage, .render_permitted = permitted };
    }
    /// Host permission query reads only immutable mode/config and the published
    /// handoff. Direct callbacks still retain truthful call-sequence evidence;
    /// violating initial quiescence is rejected by the existing adoption check.
    pub fn renderPermittedV1(self: *const MusicRuntime) bool {
        return self.mode != .versioned or self.policy_render_permitted.load(.acquire);
    }
    pub fn acknowledgeLoad(self: *MusicRuntime, ticket: v1.LoadTicketV1) !void {
        try self.claimControlV1();
        defer self.control_guard.store(false, .release);
        if (ticket.context != self.config.context) return error.WrongContext;
        if (self.load_ticket == null or !std.meta.eql(ticket, self.load_ticket.?)) return error.InvalidHandle;
        if (self.load_status == .pending) return error.LoadPending;
        self.load_ticket = null;
    }

    /// Public bounded resident reload. Inputs are copied before return; Worker
    /// loading is pumped through workerOneV1. Exactly one result must be acknowledged.
    pub fn hotReloadV1(self: *MusicRuntime, reference: v1.BankRefV1, compiled: []const u8, map: *const migration.MigrationMapV1, rules: *const epoch_policy.RuntimeMigrationPolicyV1, options: live_reload_contract.Options) !v1.RequestTicketV1 {
        try self.claimControlV1();
        defer self.control_guard.store(false, .release);
        return self.beginLiveReload(reference, compiled, null, map, rules, options, false);
    }
    /// Rebuild immutable retained content into a fresh Worker-owned Generation.
    /// The retained payload is never relabeled, rebound, or reactivated.
    pub fn rollbackGenerationV1(self: *MusicRuntime, reference: v1.BankRefV1, retained_generation: u64, map: *const migration.MigrationMapV1, rules: *const epoch_policy.RuntimeMigrationPolicyV1, options: live_reload_contract.Options) !v1.RequestTicketV1 {
        try self.claimControlV1();
        defer self.control_guard.store(false, .release);
        try self.liveReloadProfile(reference, false);
        const retained = for (self.generations.entries) |entry| {
            if (entry) |value| if (!value.candidate and value.generation.value() == retained_generation and value.payload != self.generation.?) break value.payload;
        } else return error.InvalidHandle;
        const compiled = try bank.build(self.allocator, .{ .metadata = retained.loaded.metadata, .tables = retained.loaded.tables });
        defer self.allocator.free(compiled);
        return self.beginLiveReload(reference, compiled, null, map, rules, options, true);
    }
    /// Atomic fixed-next-bar switch of a stable four-stem streamed main group.
    /// V2 provider custody lasts through the successor's successful acknowledge,
    /// not merely this operation's activated result. Worker performs all I/O.
    pub fn hotReloadWithSourcesV2(self: *MusicRuntime, reference: v1.BankRefV1, compiled: []const u8, provider: assets.SourceProviderV2, map: *const migration.MigrationMapV1, rules: *const epoch_policy.RuntimeMigrationPolicyV1, options: live_reload_contract.Options) !v1.RequestTicketV1 {
        try self.claimControlV1();
        defer self.control_guard.store(false, .release);
        return self.beginLiveReload(reference, compiled, provider, map, rules, options, false);
    }
    /// Rollback authenticates retained original bytes and creates fresh source
    /// binding, runtime generation, decoders and rings using the supplied V2.
    pub fn rollbackGenerationWithSourcesV2(self: *MusicRuntime, reference: v1.BankRefV1, retained_generation: u64, provider: assets.SourceProviderV2, map: *const migration.MigrationMapV1, rules: *const epoch_policy.RuntimeMigrationPolicyV1, options: live_reload_contract.Options) !v1.RequestTicketV1 {
        try self.claimControlV1();
        defer self.control_guard.store(false, .release);
        try self.liveReloadProfileMode(reference, false, true);
        const retained = for (self.generations.entries) |entry| {
            if (entry) |value| if (!value.candidate and value.generation.value() == retained_generation and value.payload != self.generation.?) break value.payload;
        } else return error.InvalidHandle;
        if (retained.retained_compiled.len == 0) return error.UnsupportedCapability;
        return self.beginLiveReload(reference, retained.retained_compiled, provider, map, rules, options, true);
    }
    fn beginLiveReload(self: *MusicRuntime, reference: v1.BankRefV1, compiled: []const u8, provider: ?assets.SourceProviderV2, map: *const migration.MigrationMapV1, rules: *const epoch_policy.RuntimeMigrationPolicyV1, options: live_reload_contract.Options, rollback: bool) !v1.RequestTicketV1 {
        try options.validate();
        if (self.preview_seek != null or self.live_reload != null or self.resident_state != null or self.reload.state.load(.acquire) != .idle) return error.ResidentTransactionBusy;
        try self.liveReloadProfileMode(reference, false, provider != null);
        if (compiled.len == 0 or compiled.len > self.config_v1.capacity.max_bank_bytes) return error.ResourceLimitExceeded;
        if (map.description.states.len > migration.max_entries_per_category or map.description.segments.len > migration.max_entries_per_category or map.description.selectors.len > migration.max_entries_per_category or rules.description.entries.len > epoch_policy.max_entries) return error.ResourceLimitExceeded;
        try director.resident_migration.validateHistoryPolicies(map, rules);
        if (self.reload.next_sequence == std.math.maxInt(u64) or self.handle_incarnation == std.math.maxInt(u32)) return error.IdentityExhausted;
        const bytes = try self.allocator.dupe(u8, compiled);
        errdefer self.allocator.free(bytes);
        const state = try self.allocator.create(LiveReload);
        errdefer self.allocator.destroy(state);
        // Preserve the supplied authenticated hash; do not sanitize a mutated
        // value by rebuilding/re-hashing its description. Exact bank validation
        // occurs after Worker acquires the real candidate catalogs.
        var copied_map = map.*;
        copied_map.allocator = self.allocator;
        copied_map.description.states = try self.allocator.dupe(migration.StateMapping, map.description.states);
        errdefer self.allocator.free(copied_map.description.states);
        copied_map.description.segments = try self.allocator.dupe(migration.SegmentMapping, map.description.segments);
        errdefer self.allocator.free(copied_map.description.segments);
        copied_map.description.selectors = try self.allocator.dupe(migration.SelectorMapping, map.description.selectors);
        errdefer self.allocator.free(copied_map.description.selectors);
        var copied_rules = rules.*;
        copied_rules.allocator = self.allocator;
        copied_rules.description.entries = try self.allocator.dupe(epoch_policy.Entry, rules.description.entries);
        errdefer self.allocator.free(copied_rules.description.entries);
        const source = self.generation.?;
        try source.retainPreparation();
        errdefer source.releasePreparation();
        const staging_ticket: reload_staging.Ticket = .{ .source = reference, .sequence = self.reload.next_sequence };
        const ticket = try self.ingress.pushReload(reference, staging_ticket.sequence);
        // All following publication is infallible. The input and result slot are
        // fully owned before Worker can acquire the queue state.
        state.* = .{ .ticket = ticket, .staging_ticket = staging_ticket, .source = source, .map = copied_map, .rules = copied_rules, .options = options, .rollback = rollback, .streamed = provider != null, .resource_size = bytes.len, .resource_hash = save.hash(bytes) };
        self.live_reload = state;
        self.reload.next_sequence += 1;
        self.reload.bytes = bytes;
        self.reload.input_bytes.store(bytes.len, .release);
        self.reload.source = source;
        self.reload.candidate = null;
        self.reload.failure = null;
        self.reload.ticket = staging_ticket;
        self.reload.status = .pending;
        self.reload.terminal_status = null;
        self.reload_provider = if (provider) |value| .{ .v2 = value } else null;
        self.reload.cancelled.store(false, .release);
        self.reload.abort_reason = .requested;
        self.reload.state.store(.queued, .release);
        return ticket;
    }
    fn liveReloadProfile(self: *MusicRuntime, reference: v1.BankRefV1, preparing: bool) !void {
        return self.liveReloadProfileMode(reference, preparing, false);
    }
    fn liveReloadProfileMode(self: *MusicRuntime, reference: v1.BankRefV1, preparing: bool, streamed: bool) !void {
        if (self.config_v1.crossfade.bindings.len != 0) return error.UnsupportedCapability;
        try self.checkBank(reference);
        if (self.shutdown_requested.load(.acquire) or self.unloading) return error.RuntimeStopped;
        if (self.resident_state != null or self.state != .playing or self.active_group == null or self.pending != null or self.preparing != null or self.resuming_request != null or self.fill_continuation != null or self.confirmed_fill != null or self.action != null or self.in_flight != null or self.interruption != null or self.queue_count != 0) return error.UnsupportedCapability;
        const generation = self.generation.?;
        if ((!preparing and self.live_reload != null) or (!streamed and generation.service != null) or generation.layer_owner != null or generation.loaded.bus_graph != null or self.policy_storage != null or self.event_adapter != null or (!streamed and self.owned_streaming != null) or self.control.source_continuity_manager != null or self.active_source_incarnation != 1 or self.activeSourceSwitchV1() != null or generation.transport.device_epoch != 1 or self.config_v1.sfx_generation_custody != .untracked) return error.UnsupportedCapability;
        if (streamed) {
            if (!self.usesIntegratedTickV1() or self.config_v1.streaming_reservation != .release_profile or self.service_custody == null or generation.service != self.owned_streaming or generation.source_binding == null or generation.loaded.tables.fills.len != 0 or self.outgoing_generation.load(.acquire) != null) return error.UnsupportedCapability;
            for (generation.loaded.tables.sounds) |sound| if (sound.storage != .streaming) return error.UnsupportedCapability;
        } else for (generation.loaded.tables.sounds) |sound| if (sound.storage != .resident) return error.UnsupportedCapability;
        const current = generation.loaded.tables.segments[try find(generation.loaded.tables.segments, self.rendering_segment)];
        if (current.loop_end <= current.loop_start or current.fallback_segment != s.none) return error.UnsupportedCapability;
        if (streamed and (current.storage != .streaming or current.layers.count != 4 or current.emergency != 0)) return error.UnsupportedCapability;
        if (generation.director.?.pendingCount() != 0 or generation.director.?.desired != null or generation.director.?.paused) return error.UnsupportedCapability;
        for (self.retired_groups) |group| if (group != null) return error.RequestInProgress;
        self.collectBorrowedSounds();
        // This profile has one stable looping group and no scheduled suffix.
        // Every bank SampleOwner pin must be one of its known prepared, desired
        // or Render roles. Extra pins (including legacy borrowed SFX) reject;
        // counts are not promoted into invented generation custody categories.
        const group = self.active_group.?;
        const observed = try self.musicVoiceObservation(group);
        // MusicVoiceGroup starts at mutation identity 1. Ordinary rendering and
        // natural loop wraps preserve it; seek/loop/pause mutations increment it.
        // The lower gate repeats this check against its actual Render owner.
        if (observed.generation != generation.runtime_generation or observed.transport_epoch != generation.transport.transport_epoch or observed.mutation_epoch != 1 or observed.paused or observed.source_incarnation != 1) return error.UnsupportedCapability;
        const slot = &self.control.prepared_groups[group.index];
        if (!slot.occupied or slot.generation != group.generation or slot.prepared.generation != generation.runtime_generation or slot.references != 0 or !slot.render_pins_started.load(.acquire)) return error.RequestInProgress;
        const mask: u16 = @intCast((@as(u32, 1) << @as(u5, @intCast(slot.prepared.voice_count))) - 1);
        if (slot.render_pin_mask.load(.acquire) != mask) return error.UnsupportedCapability;
        if (streamed) {
            if (slot.prepared.layer_count != 4 or slot.prepared.voice_count != 4 or slot.prepared.policy_managed or slot.prepared.emergency != null or slot.prepared.ramp_frames != 0 or generation.groupWindowCount(group) != 4 or generation.windowCount() != 4) return error.UnsupportedCapability;
            for (slot.prepared.layers[0..4], generation.loaded.tables.layers[current.layers.first..][0..4]) |layer, authored| {
                const source = layer.stream orelse return error.UnsupportedCapability;
                const sound = generation.loaded.tables.sounds[authored.sound];
                if (layer.initial_state != .real or !layer.required or layer.authored.layer_id != authored.key.id or layer.asset_frame_origin != authored.source_start or layer.gain != std.math.pow(f32, 10, authored.gain_db / 20) or !source.validate() or source.identity.asset != sound.key.id or source.identity.asset_generation != generation.runtime_generation or source.identity.transport_epoch != generation.transport.transport_epoch or source.ring.references.load(.acquire) != 1) return error.UnsupportedCapability;
                var matched = false;
                for (generation.windows) |window| if (window) |owned| {
                    if (owned.group == null or !owned.group.?.eql(group) or owned.binding.layer != authored.key.id) continue;
                    if (matched or owned.retiring or owned.binding.sound != sound.key.id or owned.binding.segment != current.key.id or !std.meta.eql(try generation.service.?.renderSource(owned.binding.handle), source)) return error.InvalidState;
                    matched = true;
                };
                if (!matched) return error.InvalidState;
            }
        }
        const record = try self.generations.get(generation.registry_handle.?);
        if (record.borrowed_resident_pcm != 0 or record.play_envelopes != 0 or record.prepared_music_groups != 1) return error.UnsupportedCapability;
        // Normal Control snapshots pin scheduled desired voices too. Authenticate
        // each source credit and full play identity; a reader retains this exact
        // slot until its genuine release, including across generation activation.
        var snapshot_credits: u64 = 0;
        for (&self.control.snapshots, 0..) |*snapshot_slot, slot_index| {
            var owned_voices: usize = 0;
            for (snapshot_slot.snapshot.voices[0..snapshot_slot.snapshot.voice_count]) |voice| {
                if (!generation.ownsSampleOwner(voice.owner)) continue;
                var known = false;
                for (slot.plays[0..slot.prepared.voice_count]) |play| {
                    if (voice.owner == play.owner and std.meta.eql(voice.instance, play.instance) and voice.reservation == play.reservation) known = true;
                }
                if (!known) return error.UnsupportedCapability;
                owned_voices += 1;
            }
            if (snapshot_slot.generation_credits[generation.registry_handle.?.index]) |credit| {
                if (owned_voices == 0 or credit.context != self.config.context or credit.runtime_generation != generation.runtime_generation or !std.meta.eql(credit.registry, generation.registry_handle.?) or credit.slot_index != slot_index or credit.snapshot_generation != snapshot_slot.snapshot.generation) return error.InvalidState;
                snapshot_credits += 1;
            } else if (owned_voices != 0) return error.InvalidState;
        }
        if (record.snapshot_slots != snapshot_credits) return error.InvalidState;
        for (generation.owners) |*owner| {
            var expected: u32 = 1;
            for (slot.plays[0..slot.prepared.voice_count]) |play| if (play.owner == owner) {
                const desired = self.control.desired[play.instance.index];
                if (!desired.active or !desired.scheduled or desired.reservation != play.reservation or desired.owner != owner) return error.UnsupportedCapability;
                expected += 3;
            };
            for (&self.control.snapshots) |*snapshot_slot| {
                for (snapshot_slot.snapshot.voices[0..snapshot_slot.snapshot.voice_count]) |voice| if (voice.owner == owner) {
                    expected += 1;
                };
            }
            if (owner.retired.load(.acquire) or owner.referenceCount() != expected) return error.UnsupportedCapability;
        }
        // Reject every unrelated retained scheduler owner before candidate
        // identity allocation. The lower gate repeats this exact authority check.
        for (&self.control.scheduled.slots) |*block| {
            const block_state = block.state.load(.acquire);
            if (block_state != .free and block_state != .terminal) return error.UnsupportedCapability;
        }
        for (&self.control.scheduled.plans) |*ledger| if (ledger.active and !ledger.cancelled.load(.acquire) and ledger.executed_count.load(.acquire) != ledger.total_phases) return error.UnsupportedCapability;
        for (&self.control.scheduled.intents) |*intent| {
            const intent_state = intent.state.load(.acquire);
            if (intent_state != 0 and intent_state != 3) return error.ResidentTransactionBusy;
        }
    }
    fn liveReloadFor(self: *MusicRuntime, ticket: v1.RequestTicketV1) !*LiveReload {
        const state = self.live_reload orelse return error.StaleResidentTransaction;
        if (!std.meta.eql(ticket, state.ticket)) return error.StaleResidentTransaction;
        return state;
    }
    pub fn pollReloadV1(self: *MusicRuntime, ticket: v1.RequestTicketV1) !live_reload_contract.Poll {
        try self.claimControlV1();
        defer self.control_guard.store(false, .release);
        const state = try self.liveReloadFor(ticket);
        self.collectReload();
        self.collectLiveReload() catch |err| {
            if (!state.streamed or !state.committed) return err;
            if (err != error.DrainPending) self.last_error = failureV1(err);
        };
        try self.finishLiveReloadWorkerResult();
        if (state.streamed and state.committed) try self.collectStreamReloadRetirement();
        self.publishSnapshot();
        return state.result;
    }
    pub fn acknowledgeReloadV1(self: *MusicRuntime, ticket: v1.RequestTicketV1) !void {
        try self.claimControlV1();
        defer self.control_guard.store(false, .release);
        const state = try self.liveReloadFor(ticket);
        if (state.result == .pending or state.lower != null or state.block != null or state.replacement != null or self.reload.ownsResources()) return error.DrainPending;
        if (state.streamed and state.committed) {
            try self.collectStreamReloadRetirement();
            if (!state.outgoing_released) return error.DrainPending;
            // Oldest histories are cold. Every planned eviction retains its
            // allocation charge until this actual, retryable disposal succeeds.
            const evictions = state.retention_plan.evictionSlice();
            while (state.eviction_cursor < evictions.len) : (state.eviction_cursor += 1) try self.evictRetainedGeneration(evictions[state.eviction_cursor].value());
        }
        self.discardLiveReload();
    }
    pub fn cancelReloadV1(self: *MusicRuntime, ticket: v1.RequestTicketV1) !void {
        try self.claimControlV1();
        defer self.control_guard.store(false, .release);
        const state = try self.liveReloadFor(ticket);
        if (state.result != .pending) return;
        state.cancel_requested = true;
        if (state.lower == null) self.abortReloadOwned(.requested);
        try self.collectLiveReload();
        try self.finishLiveReloadWorkerResult();
    }
    fn discardLiveReload(self: *MusicRuntime) void {
        const state = self.live_reload.?;
        std.debug.assert(state.lower == null and state.block == null and state.replacement == null and !self.reload.ownsResources());
        state.map.deinit();
        state.rules.deinit();
        self.allocator.destroy(state);
        self.live_reload = null;
        self.reload.ticket = null;
        self.reload_provider = null;
        self.reload.state.store(.idle, .release);
    }
    fn acceptLiveReload(self: *MusicRuntime, item: ingress.Item) !void {
        const state = self.live_reload orelse return error.InvalidState;
        if (state.staging_ticket.sequence != item.command.reload or !std.meta.eql(state.ticket, item.ticket)) return error.InvalidState;
        state.accepted = true;
        state.position = self.position();
        self.ingress.emit(.{ .ticket = item.ticket, .event = .{ .accepted = .{ .control_tick = self.tick, .render_frame = self.control_frame } } });
        if (state.streamed) {
            self.freezeStreamReload(state) catch |err| {
                self.reload.failure = failureV1(err);
                self.abortReloadOwned(.requested);
                return;
            };
        }
        try self.progressLiveReload();
    }
    fn finishLiveReload(self: *MusicRuntime, result: live_reload_contract.Poll) void {
        const state = self.live_reload.?;
        if (!state.accepted or state.terminal_emitted) return;
        state.result = result;
        self.ingress.emit(.{ .ticket = state.ticket, .event = .{ .terminal = switch (result) {
            .activated => |value| .{ .executed = value.phase },
            .unchanged => .unchanged,
            .failed => |failure| .{ .rejected = failure },
            .pending => unreachable,
        } } });
        state.terminal_emitted = true;
    }
    fn finishLiveReloadWorkerResult(self: *MusicRuntime) !void {
        const state = self.live_reload orelse return;
        if (!state.accepted or state.terminal_emitted or self.reload.state.load(.acquire) != .terminal) return;
        switch (self.reload.status) {
            .unchanged => {
                self.recordLiveReload(.no_op, 0, null, .success, .none);
                self.finishLiveReload(.unchanged);
            },
            .failed => |failure| {
                self.recordLiveReload(.abort, 0, null, .rejected, .invalid_state);
                self.finishLiveReload(.{ .failed = failure });
            },
            .aborted => {
                self.recordLiveReload(.abort, 0, null, .cancelled, .none);
                self.finishLiveReload(.{ .failed = .cancelled });
            },
            else => {},
        }
    }
    fn progressLiveReload(self: *MusicRuntime) !void {
        const state = self.live_reload orelse return;
        if (!state.accepted or state.result != .pending or state.lower != null) return;
        self.collectReload();
        try self.finishLiveReloadWorkerResult();
        if (state.result != .pending or self.reload.state.load(.acquire) != .held or self.reload.status != .assets_prepared) return;
        (if (state.streamed) self.prepareStreamLiveReload(state) else self.prepareLiveReload(state)) catch |err| {
            try self.releaseLiveReloadPreparation(state);
            if (state.replacement != null) return;
            self.finishReloadPreparation(.{ .failed = failureV1(err) });
            try self.finishLiveReloadWorkerResult();
        };
    }
    fn validateLiveReloadMap(self: *MusicRuntime, state: *LiveReload, candidate: *Generation) !void {
        if (state.streamed) {
            try state.migration_projection.initStreaming(self.allocator, state.source.loaded.tables, candidate.loaded.tables, buildId(state.source.loaded.content_hash), buildId(candidate.loaded.content_hash), &state.map, &state.rules);
        } else try state.migration_projection.init(self.allocator, state.source.loaded.tables, candidate.loaded.tables, buildId(state.source.loaded.content_hash), buildId(candidate.loaded.content_hash), &state.map, &state.rules);
        const inventory = try self.allocator.create(ReloadInventory);
        defer self.allocator.destroy(inventory);
        try inventory.source.init(state.source.loaded.tables);
        try inventory.target.init(candidate.loaded.tables);
        const context = inventory.context(buildId(state.source.loaded.content_hash), buildId(candidate.loaded.content_hash));
        const encoded = try self.allocator.alloc(u8, state.map.encodedLen());
        defer self.allocator.free(encoded);
        const len = try state.map.encode(context, encoded);
        state.migration_resource = .{ .identity = .{ .schema_version = 1, .content_hash = state.map.content_hash, .from_build_id = context.from_build_id, .to_build_id = context.to_build_id, .history_policy_id = @intFromEnum(state.map.description.history_policy) }, .byte_size = len, .bytes_hash = save.hash(encoded[0..len]), .required_capabilities = state.map.description.required_capabilities };
    }
    fn generationFacts(self: *MusicRuntime, generation: *Generation, reserve_render: bool) !retention.GenerationFacts {
        const entry = try self.generations.get(generation.registry_handle.?);
        if (entry.borrowed_resident_pcm != 0 or entry.play_envelopes != 0 or generation.layer_owner != null) return error.UnknownPhysicalOwnership;
        if (generation.service) |service| if (generation.service_custody == null or service != self.owned_streaming) return error.UnknownPhysicalOwnership;
        var leases: retention.LeaseCounts = .{ .control_plan = entry.control_plan_leases, .playing_virtual_group = entry.prepared_music_groups, .acquired_snapshot_block = entry.snapshot_slots };
        if (generation.service) |service| for (generation.windows) |window| if (window) |owned| {
            const ring = try service.ringFor(owned.binding.handle);
            const slot = &service.slots[owned.binding.handle.index];
            leases.stream_ring_cache = try std.math.add(u64, leases.stream_ring_cache, 1 + @as(u64, ring.references.load(.acquire)));
            leases.stream_job = try std.math.add(u64, leases.stream_job, @intFromBool(slot.pending_job != null));
            leases.pending_pcm = try std.math.add(u64, leases.pending_pcm, slot.visibility_refs);
        };
        var snapshot_voices: u64 = 0;
        for (generation.owners) |*owner| leases.voice = try std.math.add(u64, leases.voice, owner.referenceCount() - @as(u32, @intFromBool(!owner.retired.load(.acquire))));
        for (self.group_generation_credits) |credit| if (credit) |owned| if (std.meta.eql(owned.registry, generation.registry_handle.?)) {
            const slot = &self.control.prepared_groups[owned.group.index];
            leases.published_block = try std.math.add(u64, leases.published_block, slot.references);
            // Admission includes the one future real Render pin per candidate
            // voice before it exists. It is released/converted by the gate.
            if (reserve_render) {
                snapshot_voices = try std.math.add(u64, snapshot_voices, slot.prepared.voice_count);
                if (!slot.render_pins_started.load(.acquire)) leases.voice = try std.math.add(u64, leases.voice, slot.prepared.voice_count);
            }
        };
        if (reserve_render and snapshot_voices != 0) {
            // Every physical snapshot slot can publish both old and candidate
            // desired voices before the gate. Reserve the missing real envelope
            // and per-voice pins, rather than observing only today's slots.
            const missing = rt.snapshot_count - @min(rt.snapshot_count, entry.snapshot_slots);
            leases.acquired_snapshot_block = try std.math.add(u64, leases.acquired_snapshot_block, missing);
            leases.voice = try std.math.add(u64, leases.voice, try std.math.mul(u64, missing, snapshot_voices));
        }
        return .{ .generation = entry.generation, .build_id = entry.identity.build_id, .content_hash = entry.identity.content_hash, .retained_bytes = try generation.retainedBytes(), .leases = leases };
    }
    fn planLiveReloadRetention(self: *MusicRuntime, state: *LiveReload, candidate: *Generation) !retention.RetentionPlan {
        var facts: [retention.max_snapshot_generations]retention.GenerationFacts = undefined;
        var count: usize = 0;
        const service_bytes: u64 = if (state.streamed) try rt.streaming.Service.capacityBytes(self.owned_streaming.?.profile) else 0;
        var peak_bytes = try std.math.add(u64, (self.sharedStorageBytes() + @sizeOf(@TypeOf(self.control.snapshots))), @sizeOf(LiveReload));
        peak_bytes = try std.math.add(u64, peak_bytes, service_bytes);
        peak_bytes = try std.math.add(u64, peak_bytes, state.map.description.states.len * @sizeOf(migration.StateMapping) + state.map.description.segments.len * @sizeOf(migration.SegmentMapping) + state.map.description.selectors.len * @sizeOf(migration.SelectorMapping) + state.rules.description.entries.len * @sizeOf(epoch_policy.Entry));
        for (self.generations.entries) |entry| if (entry) |value| {
            if (value.candidate) continue;
            facts[count] = try self.generationFacts(value.payload, value.payload == state.source);
            peak_bytes = try std.math.add(u64, peak_bytes, facts[count].retained_bytes);
            count += 1;
        };
        var fresh = try self.generationFacts(candidate, true);
        peak_bytes = try std.math.add(u64, peak_bytes, fresh.retained_bytes);
        // Eviction after activation cannot excuse a prepare-time overlap peak.
        if (peak_bytes > state.options.retention.max_retained_bytes) return error.ByteCapacityExceeded;
        fresh.retained_bytes = try std.math.add(u64, fresh.retained_bytes, service_bytes + (self.sharedStorageBytes() + @sizeOf(@TypeOf(self.control.snapshots))) + @sizeOf(LiveReload) + state.map.description.states.len * @sizeOf(migration.StateMapping) + state.map.description.segments.len * @sizeOf(migration.SegmentMapping) + state.map.description.selectors.len * @sizeOf(migration.SelectorMapping) + state.rules.description.entries.len * @sizeOf(epoch_policy.Entry));
        return retention.plan(state.options.retention, .{ .active_generation = @enumFromInt(state.source.runtime_generation), .generations = facts[0..count] }, fresh);
    }
    fn freezeStreamReload(self: *MusicRuntime, state: *LiveReload) !void {
        try self.liveReloadProfileMode(state.ticket.bank, true, true);
        const boundary = try state.source.transport.strictNext(.bar, state.position.accepted_control_frame, .{ .earliest_submit_frame = try self.planningFrontier() });
        state.frozen_frame = boundary.frame;
        state.frozen_bar = try self.barAt(boundary.frame);
        state.frozen_cursor = try state.source.transport.map.frameAtTick(boundary.tick);
        state.frozen_loop_epoch = boundary.loop_epoch;
        state.frozen_transport_epoch = try std.math.add(u64, state.source.transport.transport_epoch, 1);
        state.frozen_source_segment = self.rendering_segment;
        state.old_group = self.active_group;
    }
    fn retainStreamSourceImage(self: *MusicRuntime, source: *Generation) !void {
        if (source.retained_compiled.len != 0) return;
        const compiled = try bank.build(self.allocator, .{ .metadata = source.loaded.metadata, .tables = source.loaded.tables });
        errdefer self.allocator.free(compiled);
        // Initial load deliberately retained no second compiled allocation.
        // Rebuilding is accepted only with proof of its exact original image.
        if (compiled.len != self.bank_resource_size or !std.mem.eql(u8, &save.hash(compiled), &self.bank_resource_hash)) return error.UnsupportedCapability;
        source.adoptCompiledImage(compiled);
    }
    fn prepareStreamLiveReload(self: *MusicRuntime, state: *LiveReload) !void {
        const scope = self.tick_scope orelse return error.InvalidMode;
        try self.liveReloadProfileMode(state.ticket.bank, true, true);
        // This deadline never changes with Worker progress or readiness. A late
        // preparation gets its own failure; only a new request can choose a bar.
        if (state.frozen_frame == 0 or self.control_frame >= state.frozen_frame or try self.planningFrontier() > state.frozen_frame) return error.InvalidState;
        const candidate = self.reload.candidate.?;
        if (state.stream_stage == .validated) {
            try self.validateLiveReloadMap(state, candidate);
            if (candidate.loaded.metadata.initial_state != try state.migration_projection.state(state.source.loaded.metadata.initial_state) or candidate.loaded.metadata.profile != state.source.loaded.metadata.profile or candidate.loaded.metadata.required_capabilities != state.source.loaded.metadata.required_capabilities or candidate.loaded.metadata.optional_capabilities != state.source.loaded.metadata.optional_capabilities) return error.UnsupportedCapability;
            try self.retainStreamSourceImage(state.source);
            if (candidate.retained_compiled.len != state.resource_size or !std.mem.eql(u8, &save.hash(candidate.retained_compiled), &state.resource_hash)) return error.InvalidState;
            state.target_segment_index = try state.migration_projection.segment(try find(state.source.loaded.tables.segments, state.frozen_source_segment));
            const segment = candidate.loaded.tables.segments[state.target_segment_index];
            if (segment.storage != .streaming or segment.layers.count != 4 or segment.loop_end <= segment.loop_start or state.frozen_cursor >= segment.frames or (state.frozen_loop_epoch != 0 and state.frozen_cursor < segment.loop_start)) return error.UnsupportedCapability;
            const handle = try self.generations.adoptCandidate(candidate, .{ .build_id = buildId(candidate.loaded.content_hash), .content_hash = candidate.loaded.content_hash });
            candidate.registered(&self.generations, handle);
            try candidate.retainPreparation();
            const identity = try self.generations.reserveCandidateIdentity(handle);
            try candidate.assignRuntimeIdentity(identity.value());
            try self.bindCandidateService(candidate);
            // Allocate the planner/readiness storage exactly once, after Service
            // custody is attached and before any source windows are requested.
            try candidate.activate(self.config);
            state.target_identity = bankIdentityFor(candidate);
            const id = try self.takePlan();
            state.transport = clock.Clock.init(candidate.solver.?.maps[segment.tempo], state.frozen_frame);
            state.transport.anchor_elapsed = try std.math.add(u64, state.frozen_cursor, try std.math.mul(u64, state.frozen_loop_epoch, segment.loop_end - segment.loop_start));
            state.transport.transport_epoch = state.frozen_transport_epoch;
            const physical_bar = try director.Director.barAtClock(state.transport, state.frozen_frame);
            if (physical_bar > state.frozen_bar) return error.InvalidState;
            state.bar_offset = state.frozen_bar - physical_bar;
            const anchor: director.ResidentImportAnchor = .{ .request_id = state.ticket.request_id, .position = state.position, .context = self.config.context, .asset_generation = candidate.runtime_generation, .transport_epoch = state.frozen_transport_epoch, .plan_id = id, .frame = state.frozen_frame, .bar = state.frozen_bar };
            try state.source.director.?.stageMappedResidentReload(candidate.director.?, anchor, &state.migration_projection, &state.staged);
            state.token = .{ .context = @enumFromInt(self.config.context), .asset_generation = @enumFromInt(candidate.runtime_generation), .transport_epoch = @enumFromInt(state.frozen_transport_epoch), .plan_id = @enumFromInt(id), .plan_epoch = @enumFromInt(1), .phase_id = @enumFromInt(1) };
            _ = try self.planLiveReloadRetention(state, candidate);
            state.stream_stage = .source_bound;
            self.reload.status = .pending;
            self.reload.state.store(.sources_queued, .release);
            return;
        }
        if (state.stream_stage == .source_bound) state.stream_stage = .windows_preparing;
        if (state.stream_stage != .windows_preparing) return error.InvalidState;
        state.request_windows_owned = true;
        try candidate.prepareRestoreWindows(state.ticket.request_id, state.target_segment_index, state.frozen_cursor, state.frozen_loop_epoch, state.frozen_transport_epoch, state.frozen_frame);
        try candidate.prefetchRequestWindows(state.ticket.request_id, self.control_frame);
        const readiness = candidate.readiness.?;
        try readiness.collectTick(scope, candidate.requestBindings(state.ticket.request_id), self.config.context, candidate.director.?.request_epoch);
        if (!try candidate.restoreWindowsReady(state.ticket.request_id, .{ .segment_index = state.target_segment_index, .cursor = state.frozen_cursor, .loop_epoch = state.frozen_loop_epoch }, &.{}, state.frozen_transport_epoch, readiness)) return;
        // Final authority/capacity checks occur before publishing the one gate.
        if (try self.planningFrontier() > state.frozen_frame or self.outgoing_generation.load(.acquire) != null) return error.InvalidState;
        var free_retirement: usize = 0;
        for (self.retired_groups) |entry| free_retirement += @intFromBool(entry == null);
        if (free_retirement < 2) return error.ResourceLimitExceeded;
        state.replacement = try self.prepareGroupFor(candidate, state.target_segment_index, state.frozen_cursor, state.frozen_loop_epoch, state.ticket.request_id);
        candidate.bindRequestWindows(state.ticket.request_id, state.replacement.?);
        var groups: rt.resident_transaction.GroupSet = .{};
        groups.items[0] = state.old_group.?;
        groups.count = 1;
        const desc: rt.resident_transaction.RestoreDesc = .{ .profile = .stream_reload_v1, .expected_bank_generation = state.source.runtime_generation, .bank_generation = candidate.runtime_generation, .expected_transport_epoch = state.source.transport.transport_epoch, .new_transport_epoch = state.frozen_transport_epoch, .install_frame = state.frozen_frame, .old_groups = groups, .replacement = state.replacement, .expected_outgoing_segment = state.frozen_source_segment, .expected_outgoing_cursor = state.frozen_cursor, .expected_outgoing_loop_epoch = state.frozen_loop_epoch };
        state.lower = try scope.prepareResidentRestore(desc);
        const command: rt.ScheduledCommand = .{ .identity = .{ .command_id = 1, .token = state.token, .phase_order = 0, .execute_frame = state.frozen_frame, .group_id = state.token.plan_id.value() }, .payload = .{ .resident_restore = .{ .transaction = state.lower.?, .content_hash = try scope.residentTransactionHash(state.lower.?) } } };
        state.block = try self.prepareSchedule(state.frozen_frame, try std.math.add(u64, state.frozen_frame, 1), &.{command});
        state.plan = try self.schedulePlan(state.block.?);
        state.retention_plan = try self.planLiveReloadRetention(state, candidate);
        try state.source.director.?.validateResidentReload(candidate.director.?, &state.staged);
        const resource: trace.schema.lifecycle.BankResource = .{ .identity = state.target_identity.?, .byte_size = state.resource_size, .bytes_hash = state.resource_hash };
        self.input(.{ .position = self.position(), .payload = .{ .generation_intent = .{ .transaction_id = state.ticket.request_id, .context = self.config.context, .producer = 1, .producer_order = state.ticket.request_id, .expected_plan_epoch = 1, .expected_transport_epoch = state.source.transport.transport_epoch, .operation = if (state.rollback) .rollback else .hot_reload, .active_bank = bankIdentityFor(state.source), .candidate_bank = resource, .migration = state.migration_resource, .policy = .{ .mode = .next_bar, .cue = null, .requested_not_before_frame = null } } } });
        self.input(.{ .position = self.position(), .payload = .{ .generation_preparation = .{ .operation_id = state.ticket.request_id, .context = self.config.context, .job = state.staging_ticket.sequence, .control_epoch = @max(1, self.tick), .transport_epoch = state.source.transport.transport_epoch, .kind = if (state.rollback) .rollback else .hot_reload, .state = .ready, .bank = resource, .migration = state.migration_resource, .snapshot = null, .failure_code = 0 } } });
        self.recordLiveReload(.prepare, 0, null, .success, .none);
        try self.submitSchedule(state.block.?);
        state.stream_stage = .published;
        self.recordLiveReload(.publish_candidate, 0, null, .success, .none);
        self.markAuthoritativeTraceIncompleteV1();
    }
    fn prepareLiveReload(self: *MusicRuntime, state: *LiveReload) !void {
        try self.liveReloadProfile(state.ticket.bank, true);
        const candidate = self.reload.candidate.?;
        try self.validateLiveReloadMap(state, candidate);
        const identity = try std.math.add(u64, self.generations.high_water, 1);
        try candidate.assignRuntimeIdentity(identity);
        try candidate.activate(self.config);
        if (candidate.loaded.metadata.initial_state != try state.migration_projection.state(state.source.loaded.metadata.initial_state) or candidate.loaded.metadata.profile != state.source.loaded.metadata.profile or candidate.loaded.metadata.required_capabilities != state.source.loaded.metadata.required_capabilities or candidate.loaded.metadata.optional_capabilities != state.source.loaded.metadata.optional_capabilities) return error.UnsupportedCapability;
        const id = try self.takePlan();
        const epoch = try std.math.add(u64, state.source.transport.transport_epoch, 1);
        const boundary = try state.source.transport.strictNext(.bar, state.position.accepted_control_frame, .{ .earliest_submit_frame = try self.planningFrontier() });
        const frame = boundary.frame;
        const logical_bar = try self.barAt(frame);
        const segment_index = try state.migration_projection.segment(try find(state.source.loaded.tables.segments, self.rendering_segment));
        const segment = candidate.loaded.tables.segments[segment_index];
        const cursor = try state.source.transport.map.frameAtTick(boundary.tick);
        if (cursor >= segment.frames or (boundary.loop_epoch != 0 and cursor < segment.loop_start)) return error.UnsupportedCapability;
        state.transport = clock.Clock.init(candidate.solver.?.maps[segment.tempo], frame);
        state.transport.anchor_elapsed = try std.math.add(u64, cursor, try std.math.mul(u64, boundary.loop_epoch, segment.loop_end - segment.loop_start));
        state.transport.transport_epoch = epoch;
        const physical_bar = try director.Director.barAtClock(state.transport, frame);
        if (physical_bar > logical_bar) return error.InvalidState;
        state.bar_offset = logical_bar - physical_bar;
        const anchor: director.ResidentImportAnchor = .{ .request_id = state.ticket.request_id, .position = state.position, .context = self.config.context, .asset_generation = identity, .transport_epoch = epoch, .plan_id = id, .frame = frame, .bar = logical_bar };
        try state.source.director.?.stageMappedResidentReload(candidate.director.?, anchor, &state.migration_projection, &state.staged);
        // Registry adoption and identity reservation follow complete semantic
        // validation. They still never change current/playing generation.
        const handle = try self.generations.adoptCandidate(candidate, .{ .build_id = buildId(candidate.loaded.content_hash), .content_hash = candidate.loaded.content_hash });
        candidate.registered(&self.generations, handle);
        try candidate.retainPreparation();
        const reserved = try self.generations.reserveCandidateIdentity(handle);
        std.debug.assert(reserved.value() == identity);
        state.target_identity = bankIdentityFor(candidate);
        state.old_group = self.active_group;
        state.replacement = try self.prepareGroupFor(candidate, segment_index, cursor, boundary.loop_epoch, state.ticket.request_id);
        var free_retirement: usize = 0;
        for (self.retired_groups) |entry| free_retirement += @intFromBool(entry == null);
        if (free_retirement < 2) return error.ResourceLimitExceeded;
        var groups: rt.resident_transaction.GroupSet = .{};
        groups.items[0] = state.old_group.?;
        groups.count = 1;
        const desc: rt.resident_transaction.RestoreDesc = .{ .expected_bank_generation = state.source.runtime_generation, .bank_generation = identity, .expected_transport_epoch = state.source.transport.transport_epoch, .new_transport_epoch = epoch, .install_frame = frame, .old_groups = groups, .replacement = state.replacement };
        state.lower = if (self.tick_scope) |scope| try scope.prepareResidentRestore(desc) else try self.control.prepareResidentRestore(desc);
        state.token = .{ .context = @enumFromInt(self.config.context), .asset_generation = @enumFromInt(identity), .transport_epoch = @enumFromInt(epoch), .plan_id = @enumFromInt(id), .plan_epoch = @enumFromInt(1), .phase_id = @enumFromInt(1) };
        const command: rt.ScheduledCommand = .{ .identity = .{ .command_id = 1, .token = state.token, .phase_order = 0, .execute_frame = frame, .group_id = id }, .payload = .{ .resident_restore = .{ .transaction = state.lower.?, .content_hash = if (self.tick_scope) |scope| try scope.residentTransactionHash(state.lower.?) else try self.control.residentTransactionHash(state.lower.?) } } };
        state.block = try self.prepareSchedule(frame, try std.math.add(u64, frame, 1), &.{command});
        state.plan = try self.schedulePlan(state.block.?);
        state.retention_plan = try self.planLiveReloadRetention(state, candidate);
        try state.source.director.?.validateResidentReload(candidate.director.?, &state.staged);
        const resource: trace.schema.lifecycle.BankResource = .{ .identity = state.target_identity.?, .byte_size = state.resource_size, .bytes_hash = state.resource_hash };
        self.input(.{ .position = self.position(), .payload = .{ .generation_intent = .{ .transaction_id = state.ticket.request_id, .context = self.config.context, .producer = 1, .producer_order = state.ticket.request_id, .expected_plan_epoch = 1, .expected_transport_epoch = state.source.transport.transport_epoch, .operation = if (state.rollback) .rollback else .hot_reload, .active_bank = bankIdentityFor(state.source), .candidate_bank = resource, .migration = state.migration_resource, .policy = .{ .mode = .next_bar, .cue = null, .requested_not_before_frame = null } } } });
        self.input(.{ .position = self.position(), .payload = .{ .generation_preparation = .{ .operation_id = state.ticket.request_id, .context = self.config.context, .job = state.staging_ticket.sequence, .control_epoch = @max(1, self.tick), .transport_epoch = state.source.transport.transport_epoch, .kind = if (state.rollback) .rollback else .hot_reload, .state = .ready, .bank = resource, .migration = state.migration_resource, .snapshot = null, .failure_code = 0 } } });
        self.recordLiveReload(.prepare, 0, null, .success, .none);
        try self.submitSchedule(state.block.?);
        self.recordLiveReload(.publish_candidate, 0, null, .success, .none);
        self.markAuthoritativeTraceIncompleteV1();
    }
    fn releaseLiveReloadPreparation(self: *MusicRuntime, state: *LiveReload) !void {
        if (state.streamed and state.request_windows_owned) if (self.reload.candidate) |candidate| candidate.retireRequestWindows(state.ticket.request_id);
        if (state.block) |block| {
            _ = try self.cancelSchedule(.{ .target = block, .requested_frame = self.control_frame });
            try self.releaseSchedule(block);
            state.block = null;
        }
        if (state.lower) |handle| {
            _ = if (self.tick_scope) |scope| try scope.cancelResidentTransaction(handle) else try self.control.cancelResidentTransaction(handle);
            if (self.tick_scope) |scope| try scope.acknowledgeResidentTransaction(handle) else try self.control.acknowledgeResidentTransaction(handle);
            state.lower = null;
        }
        if (state.replacement) |group| {
            try self.releaseMusicGroup(group);
            state.replacement = null;
        }
    }
    fn collectLiveReload(self: *MusicRuntime) !void {
        const state = self.live_reload orelse return;
        if (state.lower == null) {
            try self.finishLiveReloadWorkerResult();
            return;
        }
        // A quiescent device fence can already have produced the real lower
        // terminal. Do not enqueue a redundant cancel requiring a future Render
        // gate merely to collect that terminal and return its original credits.
        const terminal = if (self.tick_scope) |scope| try scope.pollResidentTransaction(state.lower.?) else try self.control.pollResidentTransaction(state.lower.?);
        if (terminal == null and (state.cancel_requested or self.shutdown_requested.load(.acquire)) and state.invalidation == null and !state.committed) state.invalidation = if (self.tick_scope) |scope| try scope.cancelResidentTransaction(state.lower.?) else try self.control.cancelResidentTransaction(state.lower.?);
        if (state.invalidation) |gate| if (try self.cancellationResult(gate)) |result| {
            self.input(.{ .position = self.position(), .payload = .{ .admission = result.admission } });
            self.observe(.{ .event = result.receipt });
            state.invalidation = null;
        };
        const result = (if (self.tick_scope) |scope| try scope.pollResidentTransaction(state.lower.?) else try self.control.pollResidentTransaction(state.lower.?)) orelse return;
        if (state.block) |block| {
            if (!state.admission_seen) if (try self.scheduleAdmission(block)) |admission| {
                self.input(.{ .position = self.position(), .payload = .{ .admission = admission } });
                state.admission_seen = true;
            };
            while (try self.pollExecutionReceipt(block, &state.receipt_cursor)) |record| self.observe(.{ .event = record });
        }
        if (result.outcome == .executed and !state.committed) try self.commitLiveReload(state, result);
        if (state.invalidation != null) return;
        if (state.block) |block| if (try self.scheduleResult(block) == null) return;
        if (state.streamed) {
            // Keep the lower handle until every fallible scheduler return has
            // succeeded. A retry must not strand a block behind lower == null.
            if (state.block) |block| {
                try self.releaseSchedule(block);
                state.block = null;
            }
        }
        if (self.tick_scope) |scope| try scope.acknowledgeResidentTransaction(state.lower.?) else try self.control.acknowledgeResidentTransaction(state.lower.?);
        state.lower = null;
        if (state.block) |block| {
            try self.releaseSchedule(block);
            state.block = null;
        }
        if (!state.committed) {
            try self.releaseLiveReloadPreparation(state);
            self.finishReloadPreparation(if (result.outcome == .cancelled) .{ .aborted = .requested } else .{ .failed = .invalid_state });
            try self.finishLiveReloadWorkerResult();
        }
    }
    fn commitLiveReload(self: *MusicRuntime, state: *LiveReload, result: rt.resident_transaction.Result) !void {
        const candidate = self.reload.candidate.?;
        const anchor = state.staged.anchor;
        if (result.kind != .restore or result.frame != anchor.frame or result.bank_generation != candidate.runtime_generation or result.previous_bank_generation != state.source.runtime_generation or result.transport_epoch != anchor.transport_epoch or result.previous_transport_epoch != state.source.transport.transport_epoch or result.physical == null or !result.physical.?.group.eql(state.replacement.?)) return error.InvalidState;
        if (state.streamed) {
            const physical = result.physical.?;
            if (physical.segment != candidate.loaded.tables.segments[state.target_segment_index].key.id or physical.cursor != state.frozen_cursor or physical.loop_epoch != state.frozen_loop_epoch or physical.paused or physical.source_incarnation != 1 or physical.mutation_epoch != 1 or result.execution_ordinal == 0) return error.InvalidState;
        }
        const phase: api.PhaseReceipt = .{ .token = state.token, .outcome = .executed, .effective_frame = result.frame };
        // All fallible validation precedes the Render publication. This exact
        // receipt now commits the independently staged logical/clock/registry
        // owners together; old receipts retain their original tickets/credits.
        state.source.director.?.commitResidentReload(candidate.director.?, &state.staged, phase) catch unreachable;
        self.generations.commitActivatedCandidate(state.source.registry_handle.?, candidate.registry_handle.?, @enumFromInt(candidate.runtime_generation)) catch unreachable;
        if (state.streamed) self.retireResidentGroup(state.old_group.?) catch unreachable else try self.retireResidentGroup(state.old_group.?);
        if (state.streamed) {
            std.debug.assert(self.outgoing_generation.load(.acquire) == null);
            self.outgoing_generation.store(state.source, .release);
            candidate.bindExecutedRequestWindows(state.ticket.request_id, state.replacement.?);
            state.request_windows_owned = false;
        }
        self.generation = candidate;
        self.device_stream_origin = null;
        self.device_stream_entry_seen = true;
        self.worker_generation.store(candidate, .release);
        self.active_group = state.replacement;
        state.replacement = null;
        self.confirmed_fill = null;
        self.active_source_incarnation = 1;
        self.rendering_segment = candidate.loaded.tables.segments[candidate.director.?.committed_segment].key.id;
        candidate.transport = state.transport;
        self.bar_offset = state.bar_offset;
        self.handle_incarnation += 1;
        self.admission_generation.store(candidate.runtime_generation, .release);
        self.admission_handle.store(self.handle_incarnation, .release);
        self.bank_resource_size = state.resource_size;
        self.bank_resource_hash = state.resource_hash;
        self.latest_request_position = state.position;
        candidate.releasePreparation();
        state.source.releasePreparation();
        self.reload.source = null;
        self.reload.candidate = null;
        self.reload.status = .unchanged; // Private preparation resources are drained.
        self.reload.state.store(.terminal, .release);
        state.committed = true;
        // Record the irreversible gate before any fallible retirement work.
        // Streamed eviction remains bounded pending work until acknowledgement.
        if (!state.streamed) for (state.retention_plan.evictionSlice()) |identity| try self.evictRetainedGeneration(identity.value());
        self.recordLiveReload(.activate, result.execution_ordinal, result, .success, .none);
        self.recordLiveReload(.commit, result.execution_ordinal, result, .success, .none);
        self.finishLiveReload(.{ .activated = .{ .bank = self.bankRef(), .previous_generation = state.source.runtime_generation, .content_hash = candidate.loaded.content_hash, .phase = phase } });
        self.has_executed = true;
        if (!self.shutdown_requested.load(.acquire)) self.state = .playing;
        self.publishSnapshot();
    }
    fn collectGenerationWindows(self: *MusicRuntime) !void {
        // Registry traversal is serialized Control work. The Service accepts
        // completions globally, then each exact owning generation closes its
        // own retired windows, including histories and a failed candidate.
        for (self.generations.entries) |entry| if (entry) |value| try value.payload.collectWindows();
    }
    fn collectStreamReloadRetirement(self: *MusicRuntime) !void {
        const state = self.live_reload orelse return;
        if (!state.streamed or !state.committed or state.outgoing_released) return;
        const source = state.source;
        source.collectWindows() catch |err| {
            self.last_error = failureV1(err);
            return;
        };
        // This checks actual window, group, snapshot, sample and source credits.
        // The live result protects the object but holds no preparation credit.
        source.requestRetirement() catch |err| {
            if (err != error.DrainPending) self.last_error = failureV1(err);
            return;
        };
        if (!source.retirementAcknowledged()) return;
        self.outgoing_generation.store(null, .release);
        // A Worker may have loaded the old pointer before its acknowledgement.
        // Clear the publication, then nonblockingly join that exact owner.
        if (self.worker_guard.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return;
        defer self.worker_guard.store(false, .release);
        std.debug.assert(source.retirementAcknowledged());
        state.outgoing_released = true;
    }
    fn collectDetachedGenerationWindows(self: *MusicRuntime) !void {
        const service = self.owned_streaming orelse return;
        std.debug.assert(!service.runtime_attached);
        self.control_frame = self.control.scheduled.render_frame.load(.acquire);
        // Iterate all owning generations, not just current. A global queue may
        // contain the last cancelled job from a retained outgoing generation.
        for (self.generations.entries) |entry| if (entry) |value| {
            const generation = value.payload;
            if (generation.service == null) continue;
            for (generation.windows) |window| if (window) |owned| if (!owned.retiring) return error.DrainPending;
            try generation.collectWindows();
            for (0..service.profile.completion_capacity) |_| {
                const accepted = try generation.acceptDetachedRetiringCompletion(self.position()) orelse break;
                std.debug.assert(accepted.input.payload.worker.state == .cancelled);
                self.markAuthoritativeTraceIncompleteV1();
            }
            try generation.collectWindows();
        };
    }
    fn evictRetainedGeneration(self: *MusicRuntime, identity: u64) !void {
        const generation = for (self.generations.entries) |entry| {
            if (entry) |value| if (!value.candidate and value.generation.value() == identity and value.payload != self.generation) break value.payload;
        } else return error.InvalidHandle;
        if (self.live_reload) |live| if (live.source == generation) return error.OwnershipPending;
        const facts = try self.generationFacts(generation, false);
        if (try facts.leases.total() != 0) return error.OwnershipPending;
        try generation.requestRetirement();
        if (!generation.retirementAcknowledged()) return error.DrainPending;
        if (self.worker_guard.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.DrainPending;
        defer self.worker_guard.store(false, .release);
        generation.withdraw();
        generation.destroy();
    }
    fn destroyRetainedGenerations(self: *MusicRuntime) !void {
        for (self.generations.entries) |entry| if (entry) |value| {
            if (value.payload == self.generation or value.candidate) continue;
            try self.evictRetainedGeneration(value.generation.value());
        };
    }
    /// Caller-owned bounded inventory. Returns required length without partial
    /// writes when the output is too small. Never exposes retained pointers.
    pub fn retainedGenerationsV1(self: *MusicRuntime, out: []live_reload_contract.Retained) !usize {
        try self.claimControlV1();
        defer self.control_guard.store(false, .release);
        var count: usize = 0;
        for (self.generations.entries) |entry| if (entry) |value| {
            count += @intFromBool(!value.candidate);
        };
        if (out.len < count) return error.BufferTooSmall;
        var index: usize = 0;
        for (self.generations.entries) |entry| if (entry) |value| {
            if (value.candidate) continue;
            const facts = try self.generationFacts(value.payload, false);
            out[index] = .{ .generation = value.generation.value(), .build_id = value.identity.build_id, .content_hash = value.identity.content_hash, .active = value.payload == self.generation, .retained_bytes = facts.retained_bytes, .leases = try facts.leases.total() };
            index += 1;
        };
        std.mem.sort(live_reload_contract.Retained, out[0..count], {}, struct {
            fn less(_: void, a: live_reload_contract.Retained, b: live_reload_contract.Retained) bool {
                return a.generation < b.generation;
            }
        }.less);
        return count;
    }
    fn bankIdentityFor(generation: *const Generation) trace.schema.lifecycle.BankIdentity {
        return .{ .major = s.major, .minor = s.minor, .build_id = buildId(generation.loaded.content_hash), .generation = generation.runtime_generation, .content_hash = generation.loaded.content_hash };
    }
    fn recordLiveReload(self: *MusicRuntime, stage: trace.schema.lifecycle.TransactionStage, sequence: u64, lower: ?rt.resident_transaction.Result, result: trace.schema.Result, reason: trace.schema.Reason) void {
        const state = self.live_reload.?;
        const old = bankIdentityFor(state.source);
        const target = if (stage == .no_op) old else state.target_identity;
        const phase = state.lower != null and stage != .prepare;
        const fresh_epoch = if (stage == .no_op) state.source.transport.transport_epoch else if (phase) state.token.transport_epoch.value() else 0;
        const identity: ?trace.schema.lifecycle.MigrationIdentity = if (target != null and stage != .no_op) .{ .schema_version = 1, .content_hash = state.map.content_hash, .from_build_id = state.map.description.from_build_id, .to_build_id = state.map.description.to_build_id, .history_policy_id = @intFromEnum(state.map.description.history_policy) } else null;
        self.observe(.{ .transaction = .{ .operation = if (state.rollback) .rollback else .hot_reload, .stage = stage, .context = self.config.context, .transaction_id = state.ticket.request_id, .sequence = sequence, .accepted_control_frame = state.position.accepted_control_frame, .effective_frame = if (lower) |value| value.frame else @max(self.control_frame, state.position.accepted_control_frame), .old_bank = old, .new_bank = target, .old_plan_epoch = 1, .new_plan_epoch = if (fresh_epoch != 0) 1 else 0, .old_transport_epoch = state.source.transport.transport_epoch, .new_transport_epoch = fresh_epoch, .migration = identity, .policy = .{ .mode = .next_bar, .cue = null, .requested_not_before_frame = null }, .snapshot_hash = null, .snapshot_capture_frame = 0, .plan_id = if (phase) state.token.plan_id.value() else 0, .phase_id = if (lower != null) 1 else 0, .phase_order = 0, .executed_prefix_count = if (lower) |value| value.executed_prefix_count else 0, .cancelled_suffix_start = 0, .cancelled_suffix_count = 0, .source_segment = state.source.loaded.tables.segments[state.source.director.?.committed_segment].key.id, .fill_segment = 0, .target_segment = self.rendering_segment, .cursor = if (lower) |value| (if (value.physical) |physical| physical.cursor else 0) else 0, .result = result, .reason = reason } });
        self.markAuthoritativeTraceIncompleteV1(); // Full replay consumer remains unimplemented.
    }

    fn residentProfile(self: *MusicRuntime, reference: v1.BankRefV1) !void {
        try self.checkBank(reference);
        if (self.preview_seek != null) return error.ResidentTransactionBusy;
        if (self.config_v1.boundary_stop != null) return error.UnsupportedCapability;
        const generation = self.generation.?;
        if (self.shutdown_requested.load(.acquire) or self.unloading) return error.RuntimeStopped;
        if (generation.loaded.bus_graph != null or self.policy_storage != null or self.config_v1.layer_gain.bindings.len != 0 or self.reload.ownsResources() or self.active_source_incarnation > 1 or self.activeSourceSwitchV1() != null or self.preparing != null or self.resuming_request != null or self.action != null or self.interruption != null) return error.UnsupportedCapability;
        if (generation.transport.device_epoch != 1 or self.deviceRecoveryActive()) return error.UnsupportedCapability;
        switch (self.config_v1.snapshot_profile) {
            .resident_v1 => {
                if (generation.service != null) return error.UnsupportedCapability;
                if (self.pending) |pending| if (pending.operation != .transition or pending.invalidation != null) return error.RequestInProgress;
                for (generation.loaded.tables.sounds) |sound| if (sound.storage != .resident) return error.UnsupportedCapability;
            },
            .stream_direct_v1 => {
                if (!self.usesIntegratedTickV1() or self.pending != null or self.confirmed_fill != null or self.fill_continuation != null or self.in_flight != null or self.queue_count != 0 or generation.director.?.desired != null) return error.UnsupportedCapability;
                if (self.state != .ready and self.state != .playing and self.state != .paused) return error.UnsupportedCapability;
                if (self.active_group != null) try self.validateStreamSnapshotSegment(self.rendering_segment);
            },
            .stream_fill_v1 => {
                if (!self.usesIntegratedTickV1() or self.queue_count != 0 or self.cleanup_stop_pending) return error.UnsupportedCapability;
                if (self.state != .ready and self.state != .playing and self.state != .paused) return error.UnsupportedCapability;
                if (self.pending) |pending| {
                    if (pending.operation != .transition or pending.invalidation != null or pending.transition == null) return error.RequestInProgress;
                    const execution = pending.transition.?;
                    if (execution.cursor.phases.count > 3) return error.UnsupportedCapability;
                    for (execution.cursor.phases.slice()) |phase| {
                        if (phase.kind != .fill_entry and phase.kind != .target_entry) return error.UnsupportedCapability;
                        try self.validateStreamSnapshotSegment(phase.segment);
                    }
                    if (self.in_flight) |ticket| if (pending.request_ticket == null or !std.meta.eql(ticket, pending.request_ticket.?)) return error.RequestInProgress;
                } else if (self.in_flight != null or generation.director.?.desired != null) return error.RequestInProgress;
                if (self.fill_continuation) |continuation| {
                    if (self.state != .paused or continuation.suspended == null or continuation.intent != null or continuation.resume_request != null) return error.RequestInProgress;
                }
                if (self.active_group != null) try self.validateStreamSnapshotSegment(self.rendering_segment);
            },
            _ => return error.UnsupportedCapability,
        }
    }
    fn validateStreamSnapshotSegment(self: *const MusicRuntime, id: u64) !void {
        const generation = self.generation.?;
        const segment = generation.loaded.tables.segments[try find(generation.loaded.tables.segments, id)];
        if (generation.service == null or segment.storage != .streaming or segment.emergency != 0 or segment.fallback_segment != s.none) return error.UnsupportedCapability;
        for (generation.loaded.tables.layers[segment.layers.first..][0..segment.layers.count]) |layer| {
            if (generation.loaded.tables.sounds[layer.sound].storage != .streaming) return error.UnsupportedCapability;
        }
    }
    fn isStreamSnapshotProfile(profile: v1.SnapshotProfileV1) bool {
        return profile == .stream_direct_v1 or profile == .stream_fill_v1;
    }
    fn lowerSnapshotProfile(profile: v1.SnapshotProfileV1) rt.resident_transaction.Profile {
        return switch (profile) {
            .resident_v1 => .resident_v1,
            .stream_direct_v1 => .stream_direct_v1,
            .stream_fill_v1 => .stream_fill_v1,
            else => unreachable,
        };
    }
    fn residentGroups(self: *const MusicRuntime) rt.resident_transaction.GroupSet {
        var result: rt.resident_transaction.GroupSet = .{};
        if (self.active_group) |group| {
            result.items[0] = group;
            result.count = 1;
        }
        if (self.pending) |pending| if (pending.transition) |execution| {
            for (execution.referenced_groups) |candidate| if (candidate) |group| {
                if (!result.contains(group)) {
                    result.items[result.count] = group;
                    result.count += 1;
                }
            };
        };
        return result;
    }
    fn residentBankIdentity(self: *const MusicRuntime) trace.schema.lifecycle.BankIdentity {
        const generation = self.generation.?;
        return .{ .major = s.major, .minor = s.minor, .build_id = buildId(generation.loaded.content_hash), .generation = generation.runtime_generation, .content_hash = generation.loaded.content_hash };
    }
    fn residentProfileId(self: *const MusicRuntime) u64 {
        return self.generation.?.loaded.tables.platforms[self.generation.?.loaded.metadata.profile].key.id;
    }
    fn newResidentState(self: *MusicRuntime, kind: ResidentState.Kind) !*ResidentState {
        if (self.resident_state != null or self.live_reload != null or self.preview_seek != null) return error.ResidentTransactionBusy;
        const next = try std.math.add(u64, self.resident_incarnation, 1);
        const state = try self.allocator.create(ResidentState);
        errdefer self.allocator.destroy(state);
        // Initialize only small ownership fields. Large codec/checkpoint storage
        // is initialized directly by its actual producer, never on a stack.
        state.kind = kind;
        state.incarnation = next;
        state.generation = self.generation.?;
        state.lower = null;
        state.block = null;
        state.plan = null;
        state.invalidation = null;
        state.terminal = false;
        state.failure = null;
        state.restore_ticket = null;
        state.accepted = false;
        state.terminal_emitted = false;
        state.install = null;
        state.replacement = null;
        state.execution = null;
        state.groups = .{};
        state.phase_cursor = 0;
        state.receipt_cursor = 0;
        state.admission_seen = false;
        state.initial_prefix = 0;
        state.phase_count = 0;
        state.scheduler_prefix_offset = 0;
        state.fill_occurrence = null;
        state.physical_path_id = 0;
        state.physical_fill_route = null;
        state.source_present = self.active_group != null;
        state.clock = self.generation.?.transport;
        state.bar_offset = self.bar_offset;
        state.source_exit_cue = 0;
        state.fill_route = null;
        state.path_id = 0;
        state.position = self.position();
        state.cancel_requested = false;
        state.continuation_credit = false;
        state.profile = self.config_v1.snapshot_profile;
        state.restore_stage = .queued;
        state.restore_epoch = 0;
        state.request_windows_owned = false;
        state.drain_groups = .{};
        try state.generation.retainPending();
        self.resident_incarnation = next;
        self.resident_state = state;
        return state;
    }
    fn discardResidentState(self: *MusicRuntime) void {
        const state = self.resident_state orelse return;
        std.debug.assert(state.lower == null and state.block == null and state.execution == null and state.replacement == null and !state.continuation_credit and !state.request_windows_owned and !self.residentResourcesPending(state));
        state.generation.releasePending();
        self.allocator.destroy(state);
        self.resident_state = null;
    }
    /// Control owner only. The returned ticket owns one bounded transaction
    /// until explicit acknowledgement; snapshot bytes are never borrowed.
    pub fn captureStateV1(self: *MusicRuntime, reference: v1.BankRefV1) !save.TicketV1 {
        try self.requireRecordedStateCallV1(false);
        try self.claimControlV1();
        defer self.control_guard.store(false, .release);
        try self.residentProfile(reference);
        const state = try self.newResidentState(.capture);
        errdefer self.discardResidentState();
        var capture_plan: ?director.ResidentCapturePlan = null;
        state.groups = self.residentGroups();
        if (self.pending) |pending| {
            const execution = pending.transition.?;
            state.initial_prefix = @intCast(execution.cursor.executedCount());
            state.phase_count = @intCast(execution.cursor.phases.count);
            @memcpy(state.phases[0..state.phase_count], execution.cursor.phases.slice());
            @memcpy(state.occurrences[0..state.phase_count], execution.occurrences[0..state.phase_count]);
            capture_plan = .{ .phase_count = state.phase_count, .baseline_executed_prefix = state.initial_prefix, .target_phase_index = state.phase_count - 1, .target_token = pending.token };
            state.scheduler_prefix_offset = execution.scheduler_prefix_offset;
            state.source_exit_cue = execution.source_exit_cue;
            state.fill_route = execution.fill_route;
            state.path_id = execution.path_id;
        }
        if (self.confirmed_fill) |fill| {
            state.fill_occurrence = fill.occurrence;
            state.physical_path_id = fill.path_id;
            state.physical_fill_route = fill.fill_route;
            if (self.pending == null) {
                state.source_exit_cue = fill.source_exit_cue;
                state.fill_route = fill.fill_route;
                state.path_id = fill.path_id;
            }
        }
        try state.generation.director.?.beginResidentCapture(&state.baseline, capture_plan);
        const desc: rt.resident_transaction.CaptureDesc = .{ .profile = lowerSnapshotProfile(state.profile), .bank_generation = state.generation.runtime_generation, .transport_epoch = state.generation.transport.transport_epoch, .groups = state.groups, .plan = if (self.pending) |pending| pending.plan else null };
        state.lower = try self.control.prepareResidentCapture(desc);
        errdefer {
            _ = self.control.cancelResidentTransaction(state.lower.?) catch {};
            self.control.acknowledgeResidentTransaction(state.lower.?) catch {};
            state.lower = null;
        }
        const id = try self.takePlan();
        const frame = try self.control.residentCaptureFrame();
        state.token = self.residentToken(id, 1, state.generation.transport.transport_epoch);
        const command: rt.ScheduledCommand = .{ .identity = .{ .command_id = 1, .token = state.token, .phase_order = 0, .execute_frame = frame, .group_id = id }, .payload = .{ .resident_capture = .{ .transaction = state.lower.?, .content_hash = try self.control.residentTransactionHash(state.lower.?) } } };
        const block = try self.prepareSchedule(frame, try std.math.add(u64, frame, 1), &.{command});
        errdefer {
            _ = self.cancelSchedule(.{ .target = block, .requested_frame = self.control_frame }) catch {};
            self.releaseSchedule(block) catch {};
        }
        state.plan = try self.schedulePlan(block);
        try self.submitSchedule(block);
        state.block = block;
        self.input(.{ .position = state.position, .payload = .{ .lifecycle = .{ .operation_id = state.incarnation, .context = self.config.context, .producer = 2, .producer_order = state.incarnation, .expected_transport_epoch = state.generation.transport.transport_epoch, .payload = .{ .capture_state = self.residentBankIdentity() } } } });
        return .{ .context = self.config.context, .incarnation = state.incarnation };
    }
    fn residentToken(self: *const MusicRuntime, plan: u64, phase: u64, epoch: u64) api.PhaseToken {
        return .{ .context = @enumFromInt(self.config.context), .asset_generation = self.bankGeneration(), .transport_epoch = @enumFromInt(epoch), .plan_id = @enumFromInt(plan), .plan_epoch = @enumFromInt(1), .phase_id = @enumFromInt(phase) };
    }
    fn captureStateFor(self: *MusicRuntime, ticket: save.TicketV1) !*ResidentState {
        const state = self.resident_state orelse return error.StaleResidentTransaction;
        if (ticket.context != self.config.context or ticket.incarnation != state.incarnation or state.kind != .capture) return error.StaleResidentTransaction;
        return state;
    }
    pub fn pollCaptureStateV1(self: *MusicRuntime, ticket: save.TicketV1, out: *save.SnapshotV1) !save.PollV1 {
        try self.requireRecordedStateCallV1(false);
        try self.claimControlV1();
        defer self.control_guard.store(false, .release);
        const state = try self.captureStateFor(ticket);
        try self.collectResidentState();
        if (!state.terminal) return .pending;
        if (state.failure) |failure| return .{ .failed = failure };
        out.length = state.snapshot.length;
        @memcpy(out.bytes[0..out.length], state.snapshot.bytes[0..out.length]);
        return .{ .ready = .{ .byte_size = out.length, .capture_frame = state.decoded.header.capture_frame, .hash = save.hash(out.slice()) } };
    }
    pub fn acknowledgeCaptureV1(self: *MusicRuntime, ticket: save.TicketV1) !void {
        try self.requireRecordedStateCallV1(false);
        try self.claimControlV1();
        defer self.control_guard.store(false, .release);
        const state = try self.captureStateFor(ticket);
        if (!state.terminal or state.lower != null or state.block != null) return error.DrainPending;
        self.discardResidentState();
    }
    pub fn cancelCaptureV1(self: *MusicRuntime, ticket: save.TicketV1) !void {
        try self.requireRecordedStateCallV1(true);
        try self.claimControlV1();
        defer self.control_guard.store(false, .release);
        const state = try self.captureStateFor(ticket);
        if (!state.terminal) {
            state.cancel_requested = true;
            try self.cancelResidentState();
        }
    }
    /// Input is copied and decoded before admission. A restore consumes a real
    /// shared ingress sequence and retains its own two receipt credits.
    pub fn restoreStateV1(self: *MusicRuntime, reference: v1.BankRefV1, bytes: []const u8) !v1.RequestTicketV1 {
        try self.requireRecordedStateCallV1(false);
        try self.claimControlV1();
        defer self.control_guard.store(false, .release);
        try self.residentProfile(reference);
        const state = try self.newResidentState(.restore);
        errdefer self.discardResidentState();
        if (bytes.len > save.capacity) return error.InvalidSnapshot;
        @memcpy(state.snapshot.bytes[0..bytes.len], bytes);
        state.snapshot.length = @intCast(bytes.len);
        try save.decode(state.snapshot.slice(), &state.decoded);
        if (state.decoded.header.profile_version != @intFromEnum(state.profile)) return error.UnsupportedCapability;
        try save.validateIdentity(&state.decoded, buildId(state.generation.loaded.content_hash), state.generation.loaded.content_hash, self.residentProfileId());
        try self.validateResidentSnapshot(&state.decoded);
        const ticket = try self.ingress.pushRestore(reference, state.incarnation);
        state.restore_ticket = ticket;
        return ticket;
    }
    fn restoreStateFor(self: *MusicRuntime, ticket: v1.RequestTicketV1) !*ResidentState {
        const state = self.resident_state orelse return error.StaleResidentTransaction;
        if (state.kind != .restore or state.restore_ticket == null or !std.meta.eql(state.restore_ticket.?, ticket)) return error.StaleResidentTransaction;
        return state;
    }
    pub fn pollRestoreStateV1(self: *MusicRuntime, ticket: v1.RequestTicketV1) !save.RestorePollV1 {
        try self.requireRecordedStateCallV1(false);
        try self.claimControlV1();
        defer self.control_guard.store(false, .release);
        const state = try self.restoreStateFor(ticket);
        try self.collectResidentState();
        if (!state.terminal) return .pending;
        if (state.failure) |failure| return .{ .failed = failure };
        return .{ .installed = state.install.? };
    }
    pub fn acknowledgeRestoreV1(self: *MusicRuntime, ticket: v1.RequestTicketV1) !void {
        try self.requireRecordedStateCallV1(false);
        try self.claimControlV1();
        defer self.control_guard.store(false, .release);
        const state = try self.restoreStateFor(ticket);
        try self.collectResidentWindows(state);
        if (!state.terminal or state.lower != null or state.block != null or self.residentResourcesPending(state)) return error.DrainPending;
        state.restore_stage = .drained;
        self.discardResidentState();
    }
    /// Cancels preparation or competes at the existing Render invalidation gate.
    /// An already executed install remains executed; acknowledgement still waits
    /// for owned windows and groups to drain through their actual owners.
    pub fn cancelRestoreV1(self: *MusicRuntime, ticket: v1.RequestTicketV1) !void {
        try self.requireRecordedStateCallV1(true);
        try self.claimControlV1();
        defer self.control_guard.store(false, .release);
        const state = try self.restoreStateFor(ticket);
        if (!state.terminal) {
            state.cancel_requested = true;
            try self.cancelResidentState();
        }
    }
    fn residentResourcesPending(self: *const MusicRuntime, state: *const ResidentState) bool {
        if (state.request_windows_owned) return true;
        for (state.drain_groups.items[0..state.drain_groups.count]) |group| {
            for (self.retired_groups) |retired| if (retired) |owned| if (owned.eql(group)) return true;
            if (state.generation.groupWindowCount(group) != 0) return true;
        }
        return false;
    }
    fn collectResidentWindows(self: *MusicRuntime, state: *ResidentState) !void {
        _ = self;
        if (state.request_windows_owned and state.terminal) {
            state.generation.retireRequestWindows(state.restore_ticket.?.request_id);
            try state.generation.collectWindows();
            if (state.generation.requestWindowCount(state.restore_ticket.?.request_id) == 0) state.request_windows_owned = false;
        }
    }
    fn validateResidentSnapshot(self: *MusicRuntime, value: *const save.Decoded) !void {
        const h = &value.header;
        if ((h.profile_version == save.stream_direct_profile_version or h.profile_version == save.stream_fill_profile_version) and h.physical_segment != 0) try self.validateStreamSnapshotSegment(h.physical_segment);
        if (h.physical_segment != 0) {
            const segment = self.generation.?.loaded.tables.segments[try find(self.generation.?.loaded.tables.segments, h.physical_segment)];
            const elapsed = try self.residentElapsed(h.physical_segment, h.cursor, h.loop_epoch);
            var restored_clock = clock.Clock.init(self.generation.?.solver.?.maps[segment.tempo], 0);
            restored_clock.anchor_elapsed = elapsed;
            if (h.cursor >= segment.frames or (h.loop_epoch != 0 and segment.loop_end <= segment.loop_start) or (segment.loop_end > segment.loop_start and h.cursor >= segment.loop_end)) return error.InvalidSnapshot;
            // A linear elapsed value alone is not a physical loop coordinate:
            // after the first wrap, the cursor cannot return into the intro.
            const coordinate = try restored_clock.position(0);
            var canonical_cursor = elapsed;
            if (restored_clock.map.tempo.loop_present == 1) {
                const begin = try restored_clock.map.frameAtTick(restored_clock.map.tempo.loop_start_tick);
                const end = try restored_clock.map.frameAtTick(restored_clock.map.tempo.loop_end_tick);
                if (end <= begin) return error.InvalidSnapshot;
                if (elapsed >= begin) canonical_cursor = begin + (elapsed - begin) % (end - begin);
            }
            if (coordinate.loop_epoch != h.loop_epoch or canonical_cursor != h.cursor) return error.InvalidSnapshot;
            if (try director.Director.barAtClock(restored_clock, 0) > h.logical_bar) return error.InvalidSnapshot;
        }
        for (value.entries[0..h.entry_count]) |entry| {
            if (h.profile_version == save.stream_fill_profile_version) try self.validateStreamSnapshotSegment(entry.segment);
            const segment = self.generation.?.loaded.tables.segments[try find(self.generation.?.loaded.tables.segments, entry.segment)];
            _ = try find(self.generation.?.loaded.tables.cues, entry.cue);
            if (entry.cursor >= segment.frames or entry.tempo_span >= self.generation.?.loaded.tables.tempo_spans.len) return error.InvalidSnapshot;
        }
        if (h.mode == .paused and h.entry_count != 0) return error.UnsupportedCapability;
    }
    fn residentRoute(self: *const MusicRuntime, path_id: u64, fill_id: ?u64, intent: director.TransitionIntent) !s.TransitionPath {
        const tables = self.generation.?.loaded.tables;
        const path = tables.transition_paths[try find(tables.transition_paths, path_id)];
        const rule = tables.transitions[path.transition];
        if (rule.key.id != intent.rule_id or tables.states[rule.from].key.id != intent.from or tables.states[rule.to].key.id != intent.to or tables.selectors[rule.selector].key.id != intent.selector or tables.segments[tables.cues[path.target_entry].segment].key.id != intent.resolved_segment or path.handoff != .hard_cut or rule.fade_ticks != 0 or rule.overlap_frames != 0) return error.InvalidSnapshot;
        const expected_fill: ?u64 = if (path.fill == s.none) null else tables.fills[path.fill].key.id;
        if (expected_fill != fill_id) return error.InvalidSnapshot;
        return path;
    }
    fn validateResidentComposition(self: *MusicRuntime, state: *const ResidentState) !void {
        try self.validateResidentSnapshotComposition(state.generation, &state.decoded, &state.staging);
    }
    fn validateResidentSnapshotComposition(self: *MusicRuntime, generation: *const Generation, value: *const save.Decoded, staged: *const director.ResidentImportStaging) !void {
        const tables = generation.loaded.tables;
        const h = &value.header;
        const logical = &staged.logical;
        if (staged.result.saved_bar != h.logical_bar) return error.InvalidSnapshot;
        // The supported Director seam exposes the one reserved Choice even
        // while paused. No future selector draw may repair a corrupt envelope.
        const reservation = staged.result.reservation;
        if (h.fill_occurrence) |occurrence| {
            const intent = reservation orelse return error.InvalidSnapshot;
            const path = try self.residentRoute(h.physical_path_id, h.physical_fill_route, intent);
            if (path.fill == s.none) return error.InvalidSnapshot;
            const steps = try bank.transition_validation.items(s.FillStep, tables.fill_steps, tables.fills[path.fill].steps);
            if (occurrence >= steps.len or tables.segments[steps[occurrence].segment].key.id != h.physical_segment) return error.InvalidSnapshot;
            if (h.entry_count == 0 and (h.mode != .paused or staged.result.suspended == null or
                h.path_id != h.physical_path_id or h.fill_route != h.physical_fill_route or
                h.source_exit_cue != tables.cues[path.source_exit].key.id)) return error.InvalidSnapshot;
        } else {
            if (h.physical_path_id != 0 or h.physical_fill_route != null) return error.InvalidSnapshot;
            if (h.physical_segment != 0 and tables.segments[logical.committed_segment].key.id != h.physical_segment) return error.InvalidSnapshot;
        }
        if (h.entry_count == 0) {
            if (staged.result.intent != null or (staged.result.suspended != null and (h.mode != .paused or h.fill_occurrence == null))) return error.InvalidSnapshot;
            return;
        }
        const intent = reservation orelse return error.InvalidSnapshot;
        if (staged.result.suspended != null or value.entries[h.entry_count - 1].segment != intent.resolved_segment) return error.InvalidSnapshot;
        var steps: []const s.FillStep = &.{};
        var target_cue: u32 = undefined;
        var exit_cue: ?u32 = null;
        if (intent.rule_id == 0) {
            if (h.path_id != 0 or h.fill_route != null or h.source_exit_cue != 0 or h.physical_segment != 0 or h.fill_occurrence != null or h.entry_count != 1 or value.entries[0].occurrence != 0) return error.InvalidSnapshot;
            target_cue = try find(tables.cues, value.entries[0].cue);
            const cue = tables.cues[target_cue];
            if ((cue.kind != .entry and cue.kind != .both) or cue.frame != 0) return error.InvalidSnapshot;
        } else {
            const path = try self.residentRoute(h.path_id, h.fill_route, intent);
            target_cue = path.target_entry;
            if (tables.cues[path.source_exit].key.id != h.source_exit_cue) return error.InvalidSnapshot;
            if (path.fill != s.none) steps = try bank.transition_validation.items(s.FillStep, tables.fill_steps, tables.fills[path.fill].steps);
            if (steps.len > 2) return error.UnsupportedCapability;
            const first = value.entries[0].occurrence;
            if (first > steps.len or h.entry_count != steps.len + 1 - first) return error.InvalidSnapshot;
            exit_cue = if (first == 0) path.source_exit else steps[first - 1].exit;
            if (h.physical_segment != tables.segments[tables.cues[exit_cue.?].segment].key.id) return error.InvalidSnapshot;
            if (first > 0 and (h.fill_occurrence == null or h.fill_occurrence.? != first - 1 or h.physical_path_id != h.path_id or h.physical_fill_route != h.fill_route)) return error.InvalidSnapshot;
        }
        const first = value.entries[0].occurrence;
        for (value.entries[0..h.entry_count], 0..) |entry, i| {
            const occurrence = first + i;
            if (entry.occurrence != occurrence) return error.InvalidSnapshot;
            const cue_index = if (occurrence < steps.len) steps[occurrence].entry else target_cue;
            const cue = tables.cues[cue_index];
            const segment = tables.segments[cue.segment];
            const duration = if (occurrence < steps.len) tables.cues[steps[occurrence].exit].frame - cue.frame else segment.frames - cue.frame;
            if (entry.segment != segment.key.id or entry.cue != cue.key.id or entry.cursor != cue.frame or entry.cursor != 0 or entry.tempo_span != try bank.transition_validation.span(tables, cue.segment, cue.tick) or entry.duration != duration or entry.target != (occurrence == steps.len)) return error.InvalidSnapshot;
            if (i > 0 and entry.distance != value.entries[i - 1].duration) return error.InvalidSnapshot;
        }
        if (exit_cue) |index| {
            const exit = tables.cues[index];
            const segment = tables.segments[exit.segment];
            const boundary = try std.math.add(u64, try self.residentElapsed(h.physical_segment, h.cursor, h.loop_epoch), value.entries[0].distance);
            if (segment.loop_end > segment.loop_start) {
                const length = segment.loop_end - segment.loop_start;
                if (boundary < exit.frame or (boundary - exit.frame) % length != 0) return error.InvalidSnapshot;
            } else if (boundary != exit.frame) return error.InvalidSnapshot;
        }
    }
    fn validateResidentBarProgress(self: *const MusicRuntime, state: *const ResidentState) !void {
        try self.validateResidentSnapshotBarProgress(state.generation, &state.decoded, state.restored_clock, state.restored_bar_offset, state.anchor.frame);
    }
    fn validateResidentSnapshotBarProgress(self: *const MusicRuntime, generation: *const Generation, value: *const save.Decoded, restored_clock: clock.Clock, restored_bar_offset: u64, anchor_frame: u64) !void {
        _ = self;
        const header = &value.header;
        // Reserve one physical segment cycle and the supported two fills plus
        // target. This also covers a paused continuation's later resume or a
        // Ready snapshot's initial start without accepting an exhausted count.
        var maximum_segment_bars: u64 = 1;
        for (generation.loaded.tables.segments) |segment| {
            const source = clock.Clock.init(generation.solver.?.maps[segment.tempo], 0);
            maximum_segment_bars = @max(maximum_segment_bars, try director.Director.barAtClock(source, segment.frames));
        }
        _ = try std.math.add(u64, header.logical_bar, try std.math.mul(u64, maximum_segment_bars, 4));
        // Simulate the exact finite saved suffix before preparing any physical
        // resource. Distances can span loops, so the coarse reserve is not a
        // substitute for checking the actual entry and bounded target duration.
        var source = restored_clock;
        source.paused = false;
        var offset = restored_bar_offset;
        var frame = anchor_frame;
        var sounding = header.physical_segment != 0;
        if (sounding) {
            const segment = generation.loaded.tables.segments[try find(generation.loaded.tables.segments, header.physical_segment)];
            const end_cursor = if (segment.loop_end > segment.loop_start) segment.loop_end else segment.frames;
            const end = try std.math.add(u64, frame, end_cursor - header.cursor);
            _ = try std.math.add(u64, offset, try director.Director.barAtClock(source, end));
        }
        for (value.entries[0..header.entry_count]) |entry| {
            frame = try std.math.add(u64, frame, entry.distance);
            const entry_bar = if (sounding) try std.math.add(u64, offset, try director.Director.barAtClock(source, frame)) else header.logical_bar;
            const segment = generation.loaded.tables.segments[try find(generation.loaded.tables.segments, entry.segment)];
            source = clock.Clock.init(generation.solver.?.maps[segment.tempo], frame);
            source.anchor_elapsed = entry.cursor;
            offset = entry_bar;
            sounding = true;
            const end = try std.math.add(u64, frame, entry.duration);
            _ = try std.math.add(u64, offset, try director.Director.barAtClock(source, end));
        }
    }
    fn acceptResidentRestore(self: *MusicRuntime, item: ingress.Item) !void {
        const state = self.resident_state orelse return error.InvalidState;
        if (state.kind != .restore or state.incarnation != item.command.restore or !std.meta.eql(state.restore_ticket.?, item.ticket)) return error.InvalidState;
        state.accepted = true;
        state.restore_stage = .accepted;
        self.ingress.emit(.{ .ticket = item.ticket, .event = .{ .accepted = .{ .control_tick = self.tick, .render_frame = self.control_frame } } });
        if (state.cancel_requested) {
            self.failResidentRestore(state, .cancelled);
            return;
        }
        self.residentProfile(item.ticket.bank) catch |err| {
            self.failResidentRestore(state, failureV1(err));
            return;
        };
        self.prepareResidentRestoreState(state) catch |err| {
            // Before publication all staged groups and descriptors remain owned
            // here. No old music or Director state has changed.
            try self.releaseResidentPreparation(state);
            self.failResidentRestore(state, failureV1(err));
        };
    }
    fn failResidentRestore(self: *MusicRuntime, state: *ResidentState, failure: v1.FailureV1) void {
        state.failure = failure;
        state.terminal = true;
        state.restore_stage = .rejected;
        if (state.request_windows_owned) state.generation.retireRequestWindows(state.restore_ticket.?.request_id);
        if (state.accepted and !state.terminal_emitted) {
            self.ingress.emit(.{ .ticket = state.restore_ticket.?, .event = .{ .terminal = .{ .rejected = failure } } });
            state.terminal_emitted = true;
        }
    }
    fn prepareStreamRestoreWindows(self: *MusicRuntime, state: *ResidentState) !bool {
        const header = &state.decoded.header;
        if (header.physical_segment == 0) return true;
        const generation = state.generation;
        const scope = self.tick_scope orelse return error.InvalidMode;
        const request = state.restore_ticket.?.request_id;
        const segment_index = try find(generation.loaded.tables.segments, header.physical_segment);
        const segment = generation.loaded.tables.segments[segment_index];
        if (state.restore_epoch == 0) state.restore_epoch = try std.math.add(u64, generation.transport.transport_epoch, 1);
        state.request_windows_owned = true;
        state.restore_stage = .opening;
        try generation.prepareRestoreWindows(request, segment_index, header.cursor, header.loop_epoch, state.restore_epoch, try self.planningFrontier());
        state.restore_stage = .prefetching;
        try generation.prefetchRequestWindows(request, self.control_frame);
        const readiness = generation.readiness.?;
        try readiness.collectTick(scope, generation.requestBindings(request), self.config.context, generation.director.?.request_epoch);
        var ready = readiness.complete and readiness.count == segment.layers.count;
        for (readiness.observations[0..readiness.count], readiness.failures[0..readiness.count]) |observation, failure| {
            if (failure != .none) return error.SourceReadFailed;
            ready = ready and observation.payload.readiness_snapshot.expected.ready;
        }
        for (generation.loaded.tables.layers[segment.layers.first..][0..segment.layers.count]) |layer| {
            const source = try generation.sourceFor(request, layer.key.id);
            if (source.identity.transport_epoch != state.restore_epoch) return error.InvalidState;
            ready = ready and source.ready(try std.math.add(u64, layer.source_start, header.cursor), header.loop_epoch);
        }
        return ready;
    }
    fn streamFillRestorePhysical(self: *MusicRuntime, state: *const ResidentState) !?assets.RestorePhysical {
        return self.streamFillSnapshotPhysical(state.generation, &state.decoded);
    }
    /// Read-only physical validation is shared with replay preattachment. A
    /// paused snapshot has no scheduled entries to validate its authored exit.
    fn streamFillSnapshotPhysical(self: *MusicRuntime, generation: *const Generation, decoded: *const save.Decoded) !?assets.RestorePhysical {
        const header = &decoded.header;
        if (header.physical_segment == 0) return null;
        var remaining: ?u64 = null;
        if (header.fill_occurrence) |occurrence| {
            if (header.entry_count != 0) {
                remaining = decoded.entries[0].distance;
            } else {
                // A settled paused continuation stores its selected route in
                // the logical checkpoint, without scheduled suffix entries.
                const tables = generation.loaded.tables;
                const fill = tables.fills[try find(tables.fills, header.physical_fill_route orelse return error.InvalidSnapshot)];
                const steps = try bank.transition_validation.items(s.FillStep, tables.fill_steps, fill.steps);
                if (header.mode != .paused or occurrence >= steps.len) return error.InvalidSnapshot;
                const elapsed = try self.residentElapsed(header.physical_segment, header.cursor, header.loop_epoch);
                const exit = tables.cues[steps[occurrence].exit].frame;
                if (elapsed >= exit) return error.InvalidSnapshot;
                remaining = exit - elapsed;
            }
        }
        return .{ .segment_index = try find(generation.loaded.tables.segments, header.physical_segment), .cursor = header.cursor, .loop_epoch = header.loop_epoch, .remaining = remaining };
    }
    fn prepareStreamFillRestoreWindows(self: *MusicRuntime, state: *ResidentState) !bool {
        const generation = state.generation;
        const scope = self.tick_scope orelse return error.InvalidMode;
        const request = state.restore_ticket.?.request_id;
        const entries = state.decoded.entries[0..state.decoded.header.entry_count];
        const physical = try self.streamFillRestorePhysical(state);
        if (physical == null and entries.len == 0) return true;
        const frontier = try self.planningFrontier();
        if (state.restore_epoch == 0) state.restore_epoch = try std.math.add(u64, generation.transport.transport_epoch, 1);
        state.request_windows_owned = true;
        state.restore_stage = .opening;
        if (physical) |value| try generation.prepareRestoreWindows(request, value.segment_index, value.cursor, value.loop_epoch, state.restore_epoch, frontier);
        try generation.prepareRestoreEntryWindows(request, entries, state.restore_epoch, frontier);
        state.restore_stage = .prefetching;
        try generation.prefetchRequestWindows(request, self.control_frame);
        const readiness = generation.readiness.?;
        try readiness.collectTick(scope, generation.requestBindings(request), self.config.context, generation.director.?.request_epoch);
        return generation.restoreWindowsReady(request, physical, entries, state.restore_epoch, readiness);
    }
    fn progressResidentRestore(self: *MusicRuntime, state: *ResidentState) !void {
        if (state.cancel_requested or self.shutdown_requested.load(.acquire)) {
            try self.cancelResidentState();
            return;
        }
        self.prepareResidentRestoreState(state) catch |err| {
            try self.releaseResidentPreparation(state);
            self.failResidentRestore(state, failureV1(err));
        };
    }
    fn prepareResidentRestoreState(self: *MusicRuntime, state: *ResidentState) !void {
        const generation = state.generation;
        if (state.profile == .stream_direct_v1 and !try self.prepareStreamRestoreWindows(state)) return;
        if (state.profile == .stream_fill_v1) {
            // Authenticate the saved selected route before opening any stream.
            // This staging copy is rebuilt at the real frontier after readiness;
            // it publishes neither logical state nor execution authority.
            state.anchor = .{ .request_id = state.restore_ticket.?.request_id, .position = state.position, .context = self.config.context, .asset_generation = generation.runtime_generation, .transport_epoch = try std.math.add(u64, generation.transport.transport_epoch, 1), .plan_id = self.next_plan_id, .frame = try self.planningFrontier(), .bar = state.decoded.header.logical_bar };
            try generation.director.?.stageResidentImport(&state.decoded.logical, state.anchor, &state.staging);
            try self.validateResidentComposition(state);
            if (!try self.prepareStreamFillRestoreWindows(state)) return;
        }
        state.restore_stage = .ready;
        // Re-anchor only after every real stem is playable. A frontier sampled
        // at request acceptance must never become install authority after I/O.
        const id = try self.takePlan();
        const frame = try self.planningFrontier();
        const epoch = try std.math.add(u64, generation.transport.transport_epoch, 1);
        if (state.restore_epoch != 0 and state.restore_epoch != epoch) return error.InvalidState;
        state.position = self.position();
        self.input(.{ .position = state.position, .payload = .{ .lifecycle = .{ .operation_id = state.restore_ticket.?.request_id, .context = self.config.context, .producer = 1, .producer_order = state.restore_ticket.?.request_id, .expected_transport_epoch = generation.transport.transport_epoch, .payload = .{ .restore_state = .{ .snapshot = save.resource(&state.decoded, state.snapshot.slice()), .target_bank = self.residentBankIdentity(), .migration = null, .reanchor_frontier = state.position.accepted_control_frame } } } } });
        state.anchor = .{ .request_id = state.restore_ticket.?.request_id, .position = state.position, .context = self.config.context, .asset_generation = generation.runtime_generation, .transport_epoch = epoch, .plan_id = id, .frame = frame, .bar = state.decoded.header.logical_bar };
        try generation.director.?.stageResidentImport(&state.decoded.logical, state.anchor, &state.staging);
        const header = &state.decoded.header;
        const expected_mode: director.ResidentPlaybackMode = switch (header.mode) {
            .ready => .ready,
            .playing => .playing,
            .paused => .paused,
        };
        if (state.staging.result.mode != expected_mode) return error.InvalidSnapshot;
        try self.validateResidentComposition(state);
        const physical_id = if (header.physical_segment != 0) header.physical_segment else generation.loaded.tables.segments[state.staging.logical.committed_segment].key.id;
        const physical_segment = generation.loaded.tables.segments[try find(generation.loaded.tables.segments, physical_id)];
        state.restored_clock = clock.Clock.init(generation.solver.?.maps[physical_segment.tempo], frame);
        state.restored_clock.transport_epoch = epoch;
        state.restored_clock.paused = header.mode == .paused;
        if (header.physical_segment != 0) state.restored_clock.anchor_elapsed = try self.residentElapsed(physical_id, header.cursor, header.loop_epoch);
        const physical_bar = try director.Director.barAtClock(state.restored_clock, frame);
        if (physical_bar > header.logical_bar) return error.InvalidSnapshot;
        state.restored_bar_offset = header.logical_bar - physical_bar;
        try self.validateResidentBarProgress(state);
        if (header.entry_count != 0 or state.staging.result.suspended != null) {
            try generation.retainPending();
            state.continuation_credit = true;
        }
        if (header.physical_segment != 0) {
            state.replacement = try self.prepareGroupAt(try find(generation.loaded.tables.segments, header.physical_segment), header.cursor, header.loop_epoch, state.restore_ticket.?.request_id);
            if (state.request_windows_owned) {
                if (state.profile == .stream_fill_v1) try generation.bindPhysicalWindows(state.restore_ticket.?.request_id, state.replacement.?) else generation.bindRequestWindows(state.restore_ticket.?.request_id, state.replacement.?);
            }
        }
        state.groups = self.residentGroups();
        var free_retirement: usize = 0;
        for (self.retired_groups) |retired| free_retirement += @intFromBool(retired == null);
        var required_retirement: usize = 0;
        for (state.groups.items[0..state.groups.count]) |group| {
            const retained = for (self.retired_groups) |retired| {
                if (retired) |old| if (old.eql(group)) break true;
            } else false;
            required_retirement += @intFromBool(!retained);
        }
        if (required_retirement > free_retirement) return error.ResourceLimitExceeded;
        const desc: rt.resident_transaction.RestoreDesc = .{ .profile = lowerSnapshotProfile(state.profile), .bank_generation = generation.runtime_generation, .expected_transport_epoch = generation.transport.transport_epoch, .new_transport_epoch = epoch, .install_frame = frame, .old_groups = state.groups, .old_plan = if (self.pending) |pending| pending.plan else null, .replacement = state.replacement, .paused = header.mode == .paused };
        state.lower = if (self.tick_scope) |scope| try scope.prepareResidentRestore(desc) else try self.control.prepareResidentRestore(desc);
        state.token = self.residentToken(id, 1, epoch);
        var commands: [7]rt.ScheduledCommand = undefined;
        commands[0] = .{ .identity = .{ .command_id = 1, .token = state.token, .phase_order = 0, .execute_frame = frame, .group_id = 1 }, .payload = .{ .resident_restore = .{ .transaction = state.lower.?, .content_hash = if (self.tick_scope) |scope| try scope.residentTransactionHash(state.lower.?) else try self.control.residentTransactionHash(state.lower.?) } } };
        var count: usize = 1;
        var at = frame;
        var source = state.replacement;
        var source_segment = header.physical_segment;
        if (header.entry_count != 0) {
            const execution = try self.allocator.create(TransitionExecution);
            state.execution = execution;
            execution.* = .{ .cursor = undefined, .solver_owned = false, .scheduler_prefix_offset = 1, .source_exit_cue = header.source_exit_cue, .fill_route = header.fill_route, .path_id = header.path_id };
            execution.referenced_groups[0] = source;
            var phases: planner.BoundedTransitionPhases = .{};
            phases.count = header.entry_count;
            for (state.decoded.entries[0..header.entry_count], 0..) |entry, index| {
                // Musical distances were captured from the actual fence/cursor;
                // only this new frontier supplies absolute execution authority.
                at = try std.math.add(u64, at, entry.distance);
                const window: ?assets.EntryWindow = if (state.profile == .stream_fill_v1) assets.restoreEntryWindow(state.decoded.entries[0..header.entry_count], index) else null;
                const group = try self.prepareGroupForEntry(generation, try find(generation.loaded.tables.segments, entry.segment), entry.cursor, 0, state.restore_ticket.?.request_id, window);
                execution.groups[index] = group;
                if (window) |selected| try generation.bindEntryWindows(state.restore_ticket.?.request_id, selected, group);
                execution.referenced_groups[index + 1] = group;
                execution.segments[index] = try find(generation.loaded.tables.segments, entry.segment);
                execution.occurrences[index] = entry.occurrence;
                const token = self.residentToken(id, index + 2, epoch);
                phases.items[index] = .{ .token = token, .kind = if (entry.target) .target_entry else .fill_entry, .segment = entry.segment, .cue = entry.cue, .execute_frame = at, .end_frame = try std.math.add(u64, at, entry.duration), .source_cursor = entry.cursor, .tempo_span = entry.tempo_span, .stop_segment = source_segment };
                var identity: rt.scheduler.CommandIdentity = .{ .command_id = count + 1, .token = token, .phase_order = @intCast(index + 1), .execute_frame = at, .group_id = index + 2 };
                if (source) |group_to_stop| {
                    commands[count] = .{ .identity = identity, .payload = .{ .group_stop = .{ .group = group_to_stop, .release_frames = 0 } } };
                    count += 1;
                }
                identity.command_id = count + 1;
                commands[count] = .{ .identity = identity, .payload = .{ .group_start = .{ .group = group } } };
                count += 1;
                source = group;
                source_segment = entry.segment;
            }
            execution.cursor = try planner.PlanCursor.init(phases);
            for (phases.slice(), 0..) |phase, index| try execution.cursor.bindGroup(phase.token, execution.groups[index].?, execution.groups[index].?.generation);
            const intent = state.staging.result.intent orelse return error.InvalidSnapshot;
            try state.staging.logical.bindTargetEntry(intent, phases.items[header.entry_count - 1].token);
        } else if (state.staging.result.intent != null) return error.InvalidSnapshot;
        try generation.director.?.validateResidentImport(&state.staging, state.anchor);
        const block = try self.prepareSchedule(frame, try std.math.add(u64, at, 1), commands[0..count]);
        state.block = block;
        state.plan = try self.schedulePlan(block);
        try self.submitSchedule(block);
        state.restore_stage = .published;
        self.input(.{ .position = self.position(), .payload = .{ .generation_preparation = .{ .operation_id = state.restore_ticket.?.request_id, .context = self.config.context, .job = state.incarnation, .control_epoch = @max(1, self.tick), .transport_epoch = generation.transport.transport_epoch, .kind = .restore_state, .state = .ready, .bank = .{ .identity = self.residentBankIdentity(), .byte_size = self.bank_resource_size, .bytes_hash = self.bank_resource_hash }, .migration = null, .snapshot = save.resource(&state.decoded, state.snapshot.slice()), .failure_code = 0 } } });
    }
    fn releaseResidentPreparation(self: *MusicRuntime, state: *ResidentState) !void {
        if (state.request_windows_owned) state.generation.retireRequestWindows(state.restore_ticket.?.request_id);
        if (state.continuation_credit) {
            state.generation.releasePending();
            state.continuation_credit = false;
        }
        if (state.block) |block| {
            _ = try self.cancelSchedule(.{ .target = block, .requested_frame = self.control_frame });
            try self.releaseSchedule(block);
            state.block = null;
        }
        if (state.lower) |handle| {
            _ = if (self.tick_scope) |scope| try scope.cancelResidentTransaction(handle) else try self.control.cancelResidentTransaction(handle);
            if (self.tick_scope) |scope| try scope.acknowledgeResidentTransaction(handle) else try self.control.acknowledgeResidentTransaction(handle);
            state.lower = null;
        }
        if (state.execution) |execution| {
            for (&execution.groups) |*group| if (group.*) |owned| {
                try self.retireGroup(owned);
                if (isStreamSnapshotProfile(state.profile)) {
                    state.drain_groups.items[state.drain_groups.count] = owned;
                    state.drain_groups.count += 1;
                }
                group.* = null;
            };
            self.allocator.destroy(execution);
            state.execution = null;
        }
        if (state.replacement) |group| {
            try self.retireGroup(group);
            if (isStreamSnapshotProfile(state.profile)) {
                state.drain_groups.items[state.drain_groups.count] = group;
                state.drain_groups.count += 1;
            }
            state.replacement = null;
        }
        state.groups = .{};
    }
    fn cancelResidentState(self: *MusicRuntime) !void {
        const state = self.resident_state orelse return;
        if (state.terminal or state.invalidation != null) return;
        if (state.lower == null) {
            if (state.kind == .restore and state.accepted) {
                try self.releaseResidentPreparation(state);
                self.failResidentRestore(state, .cancelled);
                try self.collectResidentWindows(state);
            }
            return;
        }
        if ((if (self.tick_scope) |scope| try scope.pollResidentTransaction(state.lower.?) else try self.control.pollResidentTransaction(state.lower.?)) != null) return;
        state.invalidation = if (self.tick_scope) |scope| try scope.cancelResidentTransaction(state.lower.?) else try self.control.cancelResidentTransaction(state.lower.?);
    }
    fn collectResidentState(self: *MusicRuntime) !void {
        if (self.public_recording.phase == .active and self.public_recording.profile == .stream_fill_state_serial_v1)
            self.collectFillRecordingAdmissionsV1() catch self.failRecordingV1();
        const state = self.resident_state orelse return;
        if (state.terminal) {
            try self.collectResidentWindows(state);
            return;
        }
        if (state.cancel_requested or self.shutdown_requested.load(.acquire)) try self.cancelResidentState();
        if (state.lower == null) return;
        if (state.invalidation) |gate| if (try self.cancellationResult(gate)) |result| {
            self.input(.{ .position = self.position(), .payload = .{ .admission = result.admission } });
            self.observe(.{ .event = result.receipt });
            state.invalidation = null;
        };
        if (self.public_recording.phase == .active and self.public_recording.profile == .stream_direct_state_serial_v1) {
            // Acquire the fence admission before later visibility facts, even
            // while its execution is pending. Collection order is real order.
            if (state.block) |block| if (!state.admission_seen) if (try self.scheduleAdmission(block)) |admission| {
                try self.recordStreamCollectedAdmissionsV1(&.{admission});
                state.admission_seen = true;
            };
        }
        const result = (if (self.tick_scope) |scope| try scope.pollResidentTransaction(state.lower.?) else try self.control.pollResidentTransaction(state.lower.?)) orelse return;
        if (state.block) |block| {
            if (!state.admission_seen) if (try self.scheduleAdmission(block)) |admission| {
                self.input(.{ .position = self.position(), .payload = .{ .admission = admission } });
                state.admission_seen = true;
            };
            while (try self.pollExecutionReceipt(block, &state.receipt_cursor)) |record| self.observe(.{ .event = record });
        }
        if (result.outcome == .executed) {
            if (state.kind == .capture and !state.baseline.projected) {
                self.encodeResidentCapture(state, result) catch |err| {
                    state.failure = failureV1(err);
                };
            } else if (state.kind == .restore) {
                try self.installResidentRestore(state, result);
            }
        } else {
            state.failure = if (result.outcome == .cancelled) .cancelled else .invalid_state;
        }
        if (state.invalidation != null) return;
        // A transaction phase may publish before its whole block terminal.
        // Keep the descriptor until cleanup is resumable; never clear the only
        // retained handle and then strand a still-live block.
        if (state.block) |block| if (try self.scheduleResult(block) == null) return;
        // Per-command reconciliation allows releasing the descriptor while an
        // installed suffix keeps its ordinary immutable schedule references.
        if (self.tick_scope) |scope| try scope.acknowledgeResidentTransaction(state.lower.?) else try self.control.acknowledgeResidentTransaction(state.lower.?);
        state.lower = null;
        state.groups = .{};
        if (state.block) |block| {
            try self.releaseSchedule(block);
            state.block = null;
        }
        if (state.kind == .restore and state.failure != null) {
            try self.releaseResidentPreparation(state);
            self.failResidentRestore(state, state.failure.?);
        }
        state.terminal = true;
    }
    fn encodeResidentCapture(self: *MusicRuntime, state: *ResidentState, result: rt.resident_transaction.Result) !void {
        if (result.executed_prefix_count < state.scheduler_prefix_offset) return error.InvalidState;
        const musical_prefix = result.executed_prefix_count - state.scheduler_prefix_offset;
        if (musical_prefix > state.phase_count or musical_prefix < state.initial_prefix) return error.InvalidState;
        const prefix: u8 = @intCast(musical_prefix);
        var source_clock = state.clock;
        var offset = state.bar_offset;
        var source_present = state.source_present;
        var target_entry: ?api.PhaseReceipt = null;
        var target_bar: ?u64 = null;
        for (state.initial_prefix..prefix) |index| {
            const phase = state.phases[index];
            const frame = result.executed_frames[index + state.scheduler_prefix_offset];
            if (frame > result.frame or result.executed_ordinals[index + state.scheduler_prefix_offset] == 0 or result.executed_ordinals[index + state.scheduler_prefix_offset] >= result.execution_ordinal) return error.InvalidState;
            const bar = if (source_present) try std.math.add(u64, offset, try director.Director.barAtClock(source_clock, frame)) else state.baseline.logical.current_bar;
            const segment = state.generation.loaded.tables.segments[try find(state.generation.loaded.tables.segments, phase.segment)];
            source_clock = clock.Clock.init(state.generation.solver.?.maps[segment.tempo], frame);
            source_clock.anchor_elapsed = phase.source_cursor;
            source_clock.transport_epoch = phase.token.transport_epoch.value();
            offset = bar;
            source_present = true;
            if (phase.kind == .target_entry) {
                target_entry = .{ .token = phase.token, .outcome = .executed, .effective_frame = frame };
                target_bar = bar;
            }
        }
        const physical = result.physical;
        const mode: save.Mode = if (physical) |value| (if (value.paused) .paused else .playing) else .ready;
        var logical_bar = state.baseline.logical.current_bar;
        if (physical) |value| {
            const segment = state.generation.loaded.tables.segments[try find(state.generation.loaded.tables.segments, value.segment)];
            var at = clock.Clock.init(state.generation.solver.?.maps[segment.tempo], result.frame);
            at.anchor_elapsed = try self.residentElapsed(value.segment, value.cursor, value.loop_epoch);
            logical_bar = @max(logical_bar, try std.math.add(u64, offset, try director.Director.barAtClock(at, result.frame)));
        }
        try director.Director.projectResidentCapture(&state.baseline, .{ .frame = result.frame, .bar = logical_bar, .mode = switch (mode) {
            .ready => .ready,
            .playing => .playing,
            .paused => .paused,
        }, .executed_prefix = prefix, .target_entry = target_entry, .target_entry_bar = target_bar });
        try state.baseline.logical.exportResident(&state.decoded.logical);
        state.decoded.header = .{ .profile_version = @intFromEnum(state.profile), .bank_build_id = buildId(state.generation.loaded.content_hash), .bank_content_hash = state.generation.loaded.content_hash, .profile = self.residentProfileId(), .saved_generation = state.generation.runtime_generation, .capture_frame = result.frame, .capture_gate = result.gate, .execution_ordinal = result.execution_ordinal, .executed_prefix = prefix, .mode = mode, .physical_segment = if (physical) |value| value.segment else 0, .cursor = if (physical) |value| value.cursor else 0, .loop_epoch = if (physical) |value| value.loop_epoch else 0, .logical_bar = logical_bar, .fill_occurrence = if (physical == null) null else if (prefix > 0 and prefix < state.phase_count) state.occurrences[prefix - 1] else if (prefix == state.phase_count and state.phase_count != 0) null else state.fill_occurrence, .physical_path_id = if (prefix > 0 and prefix < state.phase_count) state.path_id else if (prefix == state.phase_count and state.phase_count != 0) 0 else state.physical_path_id, .physical_fill_route = if (prefix > 0 and prefix < state.phase_count) state.fill_route else if (prefix == state.phase_count and state.phase_count != 0) null else state.physical_fill_route, .entry_count = state.phase_count - prefix, .source_exit_cue = state.source_exit_cue, .fill_route = state.fill_route, .path_id = state.path_id };
        var previous = result.frame;
        for (prefix..state.phase_count, 0..) |index, remaining| {
            const phase = state.phases[index];
            if (phase.execute_frame < previous) return error.InvalidState;
            state.decoded.entries[remaining] = .{ .segment = phase.segment, .cue = phase.cue, .distance = phase.execute_frame - previous, .duration = phase.end_frame - phase.execute_frame, .cursor = phase.source_cursor, .tempo_span = phase.tempo_span, .occurrence = state.occurrences[index], .target = phase.kind == .target_entry };
            previous = phase.execute_frame;
        }
        try save.encode(&state.decoded, &state.snapshot);
        self.recordResidentFence(state, result);
    }
    fn residentElapsed(self: *const MusicRuntime, segment_id: u64, cursor: u64, loop_epoch: u64) !u64 {
        const segment = self.generation.?.loaded.tables.segments[try find(self.generation.?.loaded.tables.segments, segment_id)];
        if (loop_epoch == 0) return cursor;
        if (segment.loop_end <= segment.loop_start) return error.InvalidSnapshot;
        return std.math.add(u64, cursor, try std.math.mul(u64, loop_epoch, segment.loop_end - segment.loop_start));
    }
    fn retireResidentGroup(self: *MusicRuntime, group: rt.GroupHandle) !void {
        for (self.retired_groups) |retired| if (retired) |existing| if (existing.eql(group)) return;
        try self.retireGroup(group);
    }
    fn installResidentRestore(self: *MusicRuntime, state: *ResidentState, result: rt.resident_transaction.Result) !void {
        if (state.install != null) return;
        if (result.frame != state.anchor.frame or result.transport_epoch != state.anchor.transport_epoch) return error.InvalidState;
        // The real atomic gate supersedes old music. Consume actual old records
        // without committing their logical state into this staged restored copy.
        if (self.pending) |*old| {
            const terminal = (try self.scheduleResult(old.block)) orelse return error.DrainPending;
            if (!old.admission_seen) if (try self.scheduleAdmission(old.block)) |admission| self.input(.{ .position = self.position(), .payload = .{ .admission = admission } });
            while (try self.pollExecutionReceipt(old.block, &old.receipt_cursor)) |record| self.observe(.{ .event = record });
            var target_seen = false;
            while (true) {
                var next_phase_cursor = old.phase_cursor;
                const phase = (try self.pollPlanPhase(old.plan, &next_phase_cursor)) orelse break;
                if (state.profile == .stream_fill_v1) {
                    const execution = old.transition orelse return error.InvalidState;
                    try execution.cursor.receipt(phase);
                }
                old.phase_cursor = next_phase_cursor;
                target_seen = target_seen or std.meta.eql(phase.token, old.token);
                self.receipt(.{ .phase_terminal = phase });
            }
            if (state.profile == .stream_fill_v1) {
                const execution = old.transition orelse return error.InvalidState;
                if (!execution.cursor.isTerminal()) {
                    if (terminal.disposition != .cancelled and terminal.disposition != .superseded_after_partial) return error.InvalidState;
                    const prefix = execution.cursor.executedCount();
                    // Validate the whole actual suffix before publishing any of
                    // its phases. The cursor also prevents duplicate emission
                    // if schedule release has to be retried after collection.
                    var cancelled = execution.cursor;
                    if (terminal.cancellation) |cancel| {
                        if (execution.scheduler_prefix_offset == 0) {
                            try cancelled.cancellation(cancel);
                        } else {
                            const offset = execution.scheduler_prefix_offset;
                            if (cancel.executed_prefix_count != prefix + offset or cancel.cancelled_suffix_start != prefix + offset or cancel.cancelled_suffix_count != cancelled.phases.count - prefix) return error.InvalidState;
                            for (prefix..cancelled.phases.count) |index| try cancelled.receipt(.{ .token = cancelled.phases.items[index].token, .outcome = .cancelled, .effective_frame = cancel.effective_frame });
                        }
                    } else {
                        // An actual admission/group rejection can carry only
                        // command receipts, rather than an invalidation record.
                        for (prefix..cancelled.phases.count) |index| {
                            const token = cancelled.phases.items[index].token;
                            const row = for (terminal.receipts[0..terminal.count]) |record| {
                                if (record.phase_id == token.phase_id.value() and (record.result == .cancelled or record.result == .rejected)) break record;
                            } else return error.InvalidState;
                            try cancelled.receipt(.{ .token = token, .outcome = .cancelled, .effective_frame = row.effective_frame });
                        }
                    }
                    execution.cursor = cancelled;
                    for (prefix..execution.cursor.phases.count) |index| self.receipt(.{ .phase_terminal = try execution.cursor.terminalReceipt(index) });
                }
                std.debug.assert(execution.cursor.isTerminal());
            } else if (!target_seen and !old.effective and old.request_ticket != null) {
                const row = for (terminal.receipts[0..terminal.count]) |record| {
                    if (record.phase_id == old.token.phase_id.value() and (record.result == .cancelled or record.result == .rejected)) break record;
                } else return error.InvalidState;
                self.receipt(.{ .phase_terminal = .{ .token = old.token, .outcome = .cancelled, .effective_frame = row.effective_frame } });
            }
            try self.releaseSchedule(old.block);
            if (old.transition) |execution| {
                if (execution.solver_owned) try old.generation.solver.?.forgetPlan(old.token.plan_id.value(), old.token.plan_epoch.value());
                self.allocator.destroy(execution);
            }
            old.generation.releasePending();
            self.pending = null;
        }
        for (state.groups.items[0..state.groups.count]) |group| try self.retireResidentGroup(group);
        if (isStreamSnapshotProfile(state.profile)) state.drain_groups = state.groups;
        if (self.fill_continuation) |continuation| {
            continuation.generation.releasePending();
            self.fill_continuation = null;
        }
        const install: api.PhaseReceipt = .{ .token = state.token, .outcome = .executed, .effective_frame = result.frame };
        // The live logical owner is frozen from publication through this gate.
        // Any failure here is an invariant violation, never a recoverable partial install.
        const imported = state.generation.director.?.importResident(&state.staging, state.anchor, install) catch unreachable;
        self.device_stream_origin = null;
        self.device_stream_entry_seen = true;
        self.active_group = state.replacement;
        if (state.request_windows_owned) {
            if (state.profile == .stream_fill_v1) {
                if (self.active_group) |group| try state.generation.bindExecutedPhysicalWindows(state.restore_ticket.?.request_id, group);
                if (state.execution) |execution| for (execution.groups[0..state.decoded.header.entry_count], 0..) |group, index| {
                    try state.generation.bindExecutedEntryWindows(state.restore_ticket.?.request_id, assets.restoreEntryWindow(state.decoded.entries[0..state.decoded.header.entry_count], index), group.?);
                };
            } else state.generation.bindExecutedRequestWindows(state.restore_ticket.?.request_id, self.active_group.?);
            state.request_windows_owned = false;
        }
        state.replacement = null;
        const header = &state.decoded.header;
        self.rendering_segment = header.physical_segment;
        self.active_source_incarnation = if (self.active_group != null) 1 else 0;
        self.confirmed_fill = if (header.fill_occurrence != null and self.active_group != null) .{ .group = self.active_group.?, .entry = install, .occurrence = header.fill_occurrence.?, .source_exit_cue = header.source_exit_cue, .fill_route = header.physical_fill_route, .path_id = header.physical_path_id } else null;
        self.paused_coordinate = if (header.mode == .paused and isStreamSnapshotProfile(state.profile)) coordinate: {
            const physical = result.physical orelse unreachable;
            std.debug.assert(physical.paused and physical.group.eql(self.active_group.?));
            break :coordinate .{ .source_incarnation = physical.source_incarnation, .frame = result.frame, .cursor = physical.cursor, .loop_epoch = physical.loop_epoch, .mutation_epoch = physical.mutation_epoch, .transport_epoch = result.transport_epoch, .paused = physical.paused };
        } else null;
        self.has_executed = self.active_group != null;
        self.state = if (self.active_group == null) .ready else if (header.mode == .paused) .paused else .playing;
        // All clock arithmetic and additional credits were validated before
        // publication. No fallible computation follows logical installation.
        state.generation.transport = state.restored_clock;
        self.bar_offset = state.restored_bar_offset;
        self.latest_request_position = state.position;
        if (imported.suspended) |suspended| {
            std.debug.assert(state.continuation_credit and self.active_group != null);
            state.continuation_credit = false;
            self.fill_continuation = .{ .generation = state.generation, .group = self.active_group.?, .suspended = suspended };
        }
        if (state.execution) |execution| {
            const target_token = execution.cursor.phases.items[execution.cursor.phases.count - 1].token;
            std.debug.assert(state.continuation_credit);
            state.continuation_credit = false;
            self.pending = .{ .generation = state.generation, .block = state.block.?, .plan = state.plan.?, .token = target_token, .operation = .transition, .intent = imported.intent, .target_group = execution.groups[execution.cursor.phases.count - 1], .transition = execution, .source_fill = self.confirmed_fill, .phase_cursor = 1, .receipt_cursor = state.receipt_cursor, .admission_seen = state.admission_seen };
            state.execution = null;
            state.block = null;
            state.plan = null;
            if (self.active_group == null) self.state = .starting;
        }
        if (!state.terminal_emitted) {
            self.ingress.emit(.{ .ticket = state.restore_ticket.?, .event = .{ .terminal = .{ .executed = install } } });
            state.terminal_emitted = true;
        }
        if (!self.receipts.push(.{ .phase_terminal = install })) self.phaseReceiptOverflowV1();
        self.recordResidentFence(state, result);
        state.install = install;
        state.restore_stage = .installed;
    }
    fn recordResidentFence(self: *MusicRuntime, state: *ResidentState, result: rt.resident_transaction.Result) void {
        const header = &state.decoded.header;
        self.observe(.{ .resident_fence = .{ .version = 1, .context = self.config.context, .operation_id = if (state.restore_ticket) |ticket| ticket.request_id else state.incarnation, .restore = state.kind == .restore, .frame = result.frame, .gate = result.gate, .execution_ordinal = result.execution_ordinal, .executed_prefix_count = result.executed_prefix_count, .segment = if (result.physical) |physical| physical.segment else 0, .cursor = if (result.physical) |physical| physical.cursor else 0, .loop_epoch = if (result.physical) |physical| physical.loop_epoch else 0, .paused = if (result.physical) |physical| physical.paused else false, .snapshot_hash = save.hash(state.snapshot.slice()) } });
        self.observe(.{ .transaction = .{ .operation = if (state.kind == .restore) .restore_state else .capture_state, .stage = .commit, .context = self.config.context, .transaction_id = if (state.restore_ticket) |ticket| ticket.request_id else state.incarnation, .sequence = result.execution_ordinal, .accepted_control_frame = state.position.accepted_control_frame, .effective_frame = result.frame, .old_bank = self.residentBankIdentity(), .new_bank = self.residentBankIdentity(), .old_plan_epoch = 1, .new_plan_epoch = 1, .old_transport_epoch = state.clock.transport_epoch, .new_transport_epoch = result.transport_epoch, .migration = null, .policy = null, .snapshot_hash = save.hash(state.snapshot.slice()), .snapshot_capture_frame = header.capture_frame, .plan_id = state.token.plan_id.value(), .phase_id = state.token.phase_id.value(), .phase_order = 0, .executed_prefix_count = result.executed_prefix_count, .cancelled_suffix_start = 0, .cancelled_suffix_count = 0, .source_segment = header.physical_segment, .fill_segment = if (header.fill_occurrence != null) header.physical_segment else 0, .target_segment = if (header.entry_count != 0) state.decoded.entries[header.entry_count - 1].segment else header.physical_segment, .cursor = header.cursor, .result = .success, .reason = .none } });
        // Unsupported replay is distinct from actual diagnostic loss. The
        // conservative legacy complete/header gates still include this sticky bit.
        if (self.public_recording.phase != .active or !public_replay.isStateProfile(self.public_recording.profile)) self.replay_unsupported = true;
    }

    /// Nonblocking MPSC entry. Admission uses only immutable config and atomic
    /// bank identity. It never dereferences a generation that Control may retire.
    pub fn submitV1(self: *MusicRuntime, reference: v1.BankRefV1, payload: api.MusicRequestPayload) !v1.RequestTicketV1 {
        try self.requireFinalizationOpen();
        // Pair registration with the admission gate in one sequentially
        // consistent order, including producers paused before their gate read.
        _ = self.context_raw_callers.fetchAdd(1, .seq_cst);
        defer _ = self.context_raw_callers.fetchSub(1, .seq_cst);
        return self.submitActualV1(reference, payload, false);
    }
    fn submitActualV1(self: *MusicRuntime, reference: v1.BankRefV1, payload: api.MusicRequestPayload, recorded_context_call: bool) !v1.RequestTicketV1 {
        try self.requireFinalizationOpen();
        if (!recorded_context_call) try self.requireRawContextCallV1();
        try self.requireCausalRoleV1(.control);
        if (self.mode != .versioned) return error.InvalidMode;
        _ = self.active_producers.fetchAdd(1, .acq_rel);
        defer _ = self.active_producers.fetchSub(1, .release);
        if (self.shutdown_requested.load(.acquire) or !self.control.accepting.load(.acquire)) return error.RuntimeStopped;
        if (reference.context != self.config.context) return error.WrongContext;
        const incarnation = self.admission_handle.load(.acquire);
        if (incarnation == 0 or reference.handle.index != 0 or reference.handle.generation != incarnation or reference.asset_generation != self.admission_generation.load(.acquire)) return error.StaleAssetGeneration;
        try (api.MusicRequest{ .request_id = 1, .payload = payload }).validate(self.config_v1.kind);
        // Bounded crossfades compose only with explicitly bound layer gains.
        // Continuity/policy requests still reject before ingress ownership.
        if (self.config_v1.crossfade.bindings.len != 0) switch (payload) {
            .set_state, .set_parameter, .stop => {},
            else => return error.UnsupportedOperation,
        };
        const state_recording = self.direct_state_recording.load(.acquire);
        if (state_recording != .disabled) {
            if (self.direct_state_busy.load(.acquire)) return error.ResidentTransactionBusy;
            switch (payload) {
                .set_state, .stop => {},
                .pause, .@"resume" => if (state_recording != .fill) return error.UnsupportedOperation,
                else => return error.UnsupportedOperation,
            }
        }
        switch (payload) {
            .set_state, .pause, .@"resume" => {},
            .set_context => if (!self.usesIntegratedTickV1()) return error.UnsupportedOperation,
            .seek_preview => if (self.config_v1.preview_seek != .stream_same_segment_v1 or !self.usesIntegratedTickV1()) return error.UnsupportedOperation,
            .set_parameter => if (self.config_v1.layer_gain.bindings.len == 0 or !self.usesIntegratedTickV1()) return error.UnsupportedOperation,
            .begin_duck, .end_duck => if (self.config_v1.policy_support == .disabled or !self.usesIntegratedTickV1()) return error.UnsupportedOperation,
            .trigger_stinger => if (self.config_v1.policy_support != .resident_stinger_v1 or !self.usesIntegratedTickV1()) return error.UnsupportedOperation,
            .stop => |mode| if (mode == .next_boundary and self.config_v1.boundary_stop == null) return error.UnsupportedOperation,
        }
        return self.ingress.push(reference, payload);
    }

    /// Control-only cancellation of the exact accepted audition. A queued ticket
    /// is not yet owned: InvalidState leaves it unchanged; tick/poll acceptance
    /// before retrying. Unknown/completed identities are stale. An execution
    /// that wins the lower race remains executed and is never stopped here.
    pub fn cancelSeekPreviewV1(self: *MusicRuntime, ticket: v1.RequestTicketV1) !void {
        try self.claimControlV1();
        defer self.control_guard.store(false, .release);
        if (self.preview_seek) |state| if (std.meta.eql(state.ticket, ticket)) {
            if (state.committed) return error.AlreadyExecuted;
            if (state.terminal) return error.StaleResidentTransaction;
            if (state.lower) |handle| if (try self.control.pollResidentTransaction(handle)) |result| {
                if (result.outcome == .executed) return error.AlreadyExecuted;
            };
            state.cancel_requested = true;
            return;
        };
        if (ticket.context == self.config.context and ticket.request_id >= self.ingress.next_control and
            ticket.request_id < self.ingress.next_ticket.load(.acquire)) return error.InvalidState;
        return error.StaleResidentTransaction;
    }
    fn previewSeekFrozen(self: *const MusicRuntime) bool {
        return if (self.preview_seek) |state| state.published and !state.committed and !state.terminal else false;
    }
    /// Only Control reads mutable generation/source state. MPSC ingress checks
    /// immutable configuration and value identity, then owns its usual credits.
    fn previewSeekSource(self: *MusicRuntime, owned: ?*const PreviewSeek) !rt.MusicGroupObservation {
        if (self.config_v1.preview_seek != .stream_same_segment_v1 or !self.usesIntegratedTickV1() or self.config_v1.kind == .shipping_game) return error.UnsupportedOperation;
        if (self.shutdown_requested.load(.acquire) or self.unloading) return error.RuntimeStopped;
        if (self.deviceRecoveryActive() or self.resident_state != null or self.live_reload != null or self.reload.ownsResources() or
            self.pending != null or self.preparing != null or self.layer_in_flight != null or self.interruption != null or
            self.action != null or self.queue_count != 0 or self.resuming_request != null or self.fill_continuation != null or
            self.confirmed_fill != null or self.cleanup_stop_pending or self.crossfade_outgoing != null or
            self.outgoing_generation.load(.acquire) != null) return error.RequestInProgress;
        if (owned) |state| {
            if (self.preview_seek != state or self.in_flight == null or !std.meta.eql(self.in_flight.?, state.ticket)) return error.InvalidState;
        } else if (self.preview_seek != null or self.in_flight != null) return error.RequestInProgress;
        const generation = self.generation orelse return error.InvalidState;
        const group = self.active_group orelse return error.InvalidState;
        if (self.state != .playing or generation.transport.paused or generation.transport.device_epoch != 1) return error.InvalidState;
        if (self.config_v1.crossfade.bindings.len != 0 or self.config_v1.layer_gain.bindings.len != 0 or self.policy_storage != null or
            generation.layer_owner != null or generation.loaded.bus_graph != null or self.event_adapter != null or
            self.control.source_continuity_manager != null or self.public_recording.phase != .disabled or self.causal_sink != null or
            self.causal_driver_pin != null or self.config_v1.streamed_fill_mode != .full_span or self.active_source_incarnation != 1 or
            self.activeSourceSwitchV1() != null) return error.UnsupportedCapability;
        const service = generation.service orelse return error.UnsupportedCapability;
        if (service != self.owned_streaming or service.replay_mode or generation.readiness == null) return error.UnsupportedCapability;
        const logical = generation.director.?;
        if (logical.desired != null or logical.pendingCount() != 0 or logical.paused or logical.suspended_target_entry != null or
            logical.pause_acceptance != null or logical.resume_acceptance != null) return error.RequestInProgress;
        const segment = generation.loaded.tables.segments[logical.committed_segment];
        if (segment.key.id != self.rendering_segment or segment.storage != .streaming or segment.layers.count == 0 or segment.layers.count > 4 or
            segment.loop_end <= segment.loop_start or segment.fallback_segment != s.none or segment.emergency != 0) return error.UnsupportedCapability;
        if (!std.meta.eql(generation.transport.map, generation.solver.?.maps[segment.tempo])) return error.InvalidState;
        for (self.retired_groups) |retired| if (retired != null) return error.RequestInProgress;
        const terminal = if (self.tick_scope) |scope| try scope.musicGroupTerminal(group) else try self.control.musicGroupTerminal(group);
        if (terminal) |ended| return if (ended.reason == .underrun) error.StreamUnderrun else error.InvalidState;
        const observed = try self.musicVoiceObservation(group);
        if (!observed.group.eql(group) or observed.generation != generation.runtime_generation or observed.transport_epoch != generation.transport.transport_epoch or
            observed.state != .playing or observed.paused or observed.source_incarnation != 1 or observed.mutation_epoch == 0 or observed.graph_generation != 0) return error.InvalidState;
        if (owned) |state| {
            if (state.generation != generation or !state.old_group.eql(group) or state.mutation_epoch != observed.mutation_epoch or
                state.old_transport_epoch != observed.transport_epoch or state.segment_index != logical.committed_segment) return error.InvalidState;
        }
        const slot = &self.control.prepared_groups[group.index];
        if (!slot.occupied or slot.generation != group.generation or slot.references != 0 or !slot.render_pins_started.load(.acquire)) return error.RequestInProgress;
        const prepared = &slot.prepared;
        if (prepared.segment != segment.key.id or prepared.generation != generation.runtime_generation or prepared.layer_count != segment.layers.count or
            prepared.voice_count != segment.layers.count or prepared.policy_managed or prepared.emergency != null or prepared.ramp_frames != 0 or
            observed.layer_count != segment.layers.count or observed.gain != prepared.gain or !std.meta.eql(observed.loop, prepared.loop)) return error.UnsupportedCapability;
        const loop = observed.loop orelse return error.UnsupportedCapability;
        if (loop.start != segment.loop_start or loop.end != segment.loop_end or observed.cursor >= segment.loop_end) return error.InvalidState;
        const elapsed = try std.math.add(u64, observed.cursor, try std.math.mul(u64, observed.loop_epoch, loop.end - loop.start));
        if (elapsed != try generation.transport.elapsedAt(observed.frame)) return error.InvalidState;
        const mask: u16 = @intCast((@as(u32, 1) << @as(u5, @intCast(prepared.voice_count))) - 1);
        if (slot.render_pin_mask.load(.acquire) != mask) return error.UnsupportedCapability;
        const fresh_count = if (owned) |state| generation.requestWindowCount(state.ticket.request_id) else 0;
        if (generation.groupWindowCount(group) != segment.layers.count or generation.windowCount() != segment.layers.count + fresh_count) return error.RequestInProgress;
        if (service.slots.len < 2 * segment.layers.count) return error.ResourceLimitExceeded;
        for (prepared.layers[0..prepared.layer_count], generation.loaded.tables.layers[segment.layers.first..][0..segment.layers.count], observed.layers[0..observed.layer_count]) |layer, authored, actual| {
            const source = layer.stream orelse return error.UnsupportedCapability;
            const sound = generation.loaded.tables.sounds[authored.sound];
            if (sound.storage != .streaming or layer.initial_state != .real or !layer.required or layer.authored.layer_id != authored.key.id or
                layer.asset_frame_origin != authored.source_start or layer.gain != std.math.pow(f32, 10, authored.gain_db / 20) or
                actual.state != .real or actual.automation_generation != 0 or actual.gain != layer.gain or
                actual.stream_generation != source.identity.stream_generation or !source.validate() or source.identity.asset != sound.key.id or
                source.identity.asset_generation != generation.runtime_generation or source.identity.transport_epoch != observed.transport_epoch) return error.UnsupportedCapability;
            var matched = false;
            for (generation.windows) |window| if (window) |entry| {
                if (entry.group == null or !entry.group.?.eql(group) or entry.binding.layer != authored.key.id) continue;
                if (matched or entry.retiring or entry.binding.sound != sound.key.id or entry.binding.segment != segment.key.id or
                    !std.meta.eql(try service.renderSource(entry.binding.handle), source)) return error.InvalidState;
                matched = true;
            };
            if (!matched) return error.InvalidState;
        }
        return observed;
    }
    fn acceptPreviewSeek(self: *MusicRuntime, item: ingress.Item) void {
        self.beginPreviewSeek(item) catch |err| {
            self.rejectItemV1(item, previewSeekError(err));
            return;
        };
        self.progressPreviewSeek() catch |err| {
            // Collection pressure is retryable and never abandons the owner.
            self.last_error = failureV1(err);
        };
    }
    fn beginPreviewSeek(self: *MusicRuntime, item: ingress.Item) !void {
        try self.checkBank(item.ticket.bank);
        const observed = try self.previewSeekSource(null);
        const request = item.command.music.seek_preview;
        const generation = self.generation.?;
        const segment_index = generation.director.?.committed_segment;
        const segment = generation.loaded.tables.segments[segment_index];
        if (request.segment.value() != segment.key.id) return error.InvalidState;
        const target = if (request.frame) |frame| frame else blk: {
            const cue_index = find(generation.loaded.tables.cues, request.cue.?.value()) catch return error.InvalidState;
            const cue = generation.loaded.tables.cues[cue_index];
            if (cue.segment != segment_index) return error.InvalidState;
            break :blk cue.frame;
        };
        if (target >= segment.loop_end) return error.InvalidState;
        for (generation.loaded.tables.layers[segment.layers.first..][0..segment.layers.count]) |layer| _ = try std.math.add(u64, layer.source_start, target);
        const epoch = try std.math.add(u64, generation.transport.transport_epoch, 1);
        var free_retirement: usize = 0;
        for (self.retired_groups) |entry| free_retirement += @intFromBool(entry == null);
        if (free_retirement < 2) return error.ResourceLimitExceeded;
        const state = try self.allocator.create(PreviewSeek);
        errdefer self.allocator.destroy(state);
        try generation.retainPreparation();
        const at = self.position();
        state.* = .{ .ticket = item.ticket, .generation = generation, .position = at, .old_group = self.active_group.?, .segment_index = segment_index, .target = target, .old_transport_epoch = observed.transport_epoch, .new_transport_epoch = epoch, .mutation_epoch = observed.mutation_epoch };
        self.preview_seek = state;
        self.acceptV1(item);
        const normalized = trace.schema.normalizeRequest(.{ .request_id = item.ticket.request_id, .payload = item.command.music }, self.config_v1.kind, 1, item.ticket.request_id, self.config.context) catch unreachable;
        self.input(.{ .position = at, .payload = .{ .request = normalized } });
        self.latest_request_position = at;
        // Audition has genuine timeline inputs/receipts, but no replay profile
        // or save-state lifecycle is claimed by this opt-in implementation.
        self.replay_unsupported = true;
    }
    /// Fresh-window failures are adjudicated only by the request preparation
    /// path. Independent background supply keeps the old audible rings fed.
    fn prefetchMusicWindowsForTick(self: *MusicRuntime, generation: *Generation, frame: u64, live: ?*LiveTickAttempt) !void {
        if (live) |attempt| {
            const excluded: ?assets.WindowKey = if (self.device_stream_candidate) |candidate|
                (if (!candidate.committed and candidate.generation == generation) .{ .scope = .device_recovery, .request_id = candidate.window_id } else null)
            else
                null;
            // Only an actually executed, stable initial source (including its
            // successfully recovered successor) may replenish from the current
            // completed frontier. Future/preparing groups retain exact cuts.
            const active: ?rt.GroupHandle = blk: {
                if (self.state != .playing or self.pending != null or self.preparing != null or self.device_stream_candidate != null or self.deviceRecoveryActive()) break :blk null;
                const origin = self.device_stream_origin orelse break :blk null;
                const group = self.active_group orelse break :blk null;
                if (origin.generation != generation.runtime_generation or !origin.group.eql(group)) break :blk null;
                break :blk group;
            };
            if (try (if (self.live_chronology_frontier != null) generation.prefetchChronologyActiveWindowsLiveV1(excluded, frame, active) else generation.prefetchStableActiveWindowsLiveV1(excluded, frame, active))) |observation|
                return self.deferLiveTick(attempt, .background_supply, observation);
        } else try self.prefetchMusicWindows(generation, frame);
    }
    fn prefetchMusicWindows(self: *MusicRuntime, generation: *Generation, frame: u64) !void {
        if (self.preview_seek) |state| if (!state.committed and !state.terminal) {
            const service = generation.service orelse return error.InvalidState;
            for (generation.windows) |entry| if (entry) |window| {
                if (window.retiring or window.group == null or !window.group.?.eql(state.old_group)) continue;
                if (try service.failure(window.binding.handle) != .none) return error.SourceReadFailed;
                _ = try service.prefetch(window.binding.handle, frame);
            };
            return;
        };
        const excluded: ?assets.WindowKey = if (self.device_stream_candidate) |candidate|
            (if (!candidate.committed and candidate.generation == generation) .{ .scope = .device_recovery, .request_id = candidate.window_id } else null)
        else
            null;
        try generation.prefetchWindowsExcluding(excluded, frame);
    }
    fn progressPreviewSeek(self: *MusicRuntime) !void {
        const state = self.preview_seek orelse return;
        if (state.terminal) {
            if (state.committed and self.control_frame >= state.generation.director.?.current_frame)
                try state.generation.director.?.advance(self.control_frame, try self.barAt(self.control_frame));
            return;
        }
        if (state.published or state.lower != null or state.failure != null or state.cancel_requested) {
            try self.collectPreviewSeek();
            return;
        }
        self.preparePreviewSeek(state) catch |err| {
            state.failure = previewSeekError(err);
            state.cancel_requested = true;
            try self.collectPreviewSeek();
        };
    }
    fn preparePreviewSeek(self: *MusicRuntime, state: *PreviewSeek) !void {
        const scope = self.tick_scope orelse return error.InvalidMode;
        _ = try self.previewSeekSource(state);
        const generation = state.generation;
        try generation.director.?.advance(self.control_frame, try self.barAt(self.control_frame));
        try generation.prepareRestoreWindows(state.ticket.request_id, state.segment_index, state.target, 0, state.new_transport_epoch, try self.planningFrontier());
        try generation.prefetchRequestWindows(state.ticket.request_id, self.control_frame);
        const readiness = generation.readiness.?;
        try readiness.collectTick(scope, generation.requestBindings(state.ticket.request_id), self.config.context, generation.director.?.request_epoch);
        if (!try generation.restoreWindowsReady(state.ticket.request_id, .{ .segment_index = state.segment_index, .cursor = state.target, .loop_epoch = 0 }, &.{}, state.new_transport_epoch, readiness)) return;
        // All fresh stems are genuinely Render-visible before sampling this new
        // frontier. Exact frame origins do not round through tempo ticks.
        const frame = try self.planningFrontier();
        const end = try std.math.add(u64, frame, 1);
        state.transport = clock.Clock.init(generation.solver.?.maps[generation.loaded.tables.segments[state.segment_index].tempo], frame);
        state.transport.anchor_elapsed = state.target;
        state.transport.transport_epoch = state.new_transport_epoch;
        state.transport.device_epoch = generation.transport.device_epoch;
        const physical_bar = try director.Director.barAtClock(state.transport, frame);
        const logical_bar = @max(try self.barAt(frame), physical_bar);
        state.bar_offset = logical_bar - physical_bar;
        const id = try self.takePlan();
        const anchor: director.ResidentImportAnchor = .{ .request_id = state.ticket.request_id, .position = state.position, .context = self.config.context, .asset_generation = generation.runtime_generation, .transport_epoch = state.new_transport_epoch, .plan_id = id, .frame = frame, .bar = logical_bar };
        try generation.director.?.stagePreviewSeek(anchor, &state.staged);
        state.token = .{ .context = @enumFromInt(self.config.context), .asset_generation = @enumFromInt(generation.runtime_generation), .transport_epoch = @enumFromInt(state.new_transport_epoch), .plan_id = @enumFromInt(id), .plan_epoch = @enumFromInt(1), .phase_id = @enumFromInt(1) };
        state.replacement = try self.prepareGroupFor(generation, state.segment_index, state.target, 0, state.ticket.request_id);
        generation.bindRequestWindows(state.ticket.request_id, state.replacement.?);
        var groups: rt.resident_transaction.GroupSet = .{};
        groups.items[0] = state.old_group;
        groups.count = 1;
        state.lower = try scope.prepareResidentRestore(.{ .profile = .stream_direct_v1, .bank_generation = generation.runtime_generation, .expected_transport_epoch = state.old_transport_epoch, .new_transport_epoch = state.new_transport_epoch, .install_frame = frame, .old_groups = groups, .replacement = state.replacement, .seek_guard = .{ .outgoing = state.old_group, .segment = generation.loaded.tables.segments[state.segment_index].key.id, .source_incarnation = 1, .mutation_epoch = state.mutation_epoch } });
        const command: rt.ScheduledCommand = .{ .identity = .{ .command_id = 1, .token = state.token, .phase_order = 0, .execute_frame = frame, .group_id = id }, .payload = .{ .resident_restore = .{ .transaction = state.lower.?, .content_hash = try scope.residentTransactionHash(state.lower.?) } } };
        state.block = try self.prepareSchedule(frame, end, &.{command});
        state.plan = try self.schedulePlan(state.block.?);
        try generation.director.?.validatePreviewSeek(&state.staged);
        try self.submitSchedule(state.block.?);
        state.published = true;
    }
    fn finishPreviewSeek(self: *MusicRuntime, state: *PreviewSeek, terminal: @FieldType(@FieldType(v1.ReceiptV1, "event"), "terminal")) void {
        if (state.terminal) return;
        state.terminal = true;
        self.finishTicketV1(state.ticket, terminal);
    }
    fn previewSeekError(err: anyerror) v1.FailureV1 {
        return switch (err) {
            error.LateCommand => .invalid_order,
            error.TargetNotResident, error.InvalidArgument, error.StaleInstance => .invalid_state,
            else => failureV1(boundaryStopError(err)),
        };
    }
    fn previewSeekSourceFailure(self: *MusicRuntime, state: *const PreviewSeek) !?v1.FailureV1 {
        const terminal = if (self.tick_scope) |scope| try scope.musicGroupTerminal(state.old_group) else try self.control.musicGroupTerminal(state.old_group);
        if (terminal) |ended| return if (ended.reason == .underrun) .stream_underrun else .invalid_state;
        return null;
    }
    fn collectPreviewSeek(self: *MusicRuntime) !void {
        const state = self.preview_seek orelse return;
        if (state.terminal) return;
        if (self.shutdown_requested.load(.acquire)) state.cancel_requested = true;
        if (state.lower == null and !state.cancel_requested and state.failure == null) {
            if (try self.previewSeekSourceFailure(state)) |failure| {
                state.failure = failure;
                state.cancel_requested = true;
            }
        }
        if (state.lower) |handle| {
            var result = if (self.tick_scope) |scope| try scope.pollResidentTransaction(handle) else try self.control.pollResidentTransaction(handle);
            if (result == null and state.cancel_requested and state.invalidation == null) {
                state.invalidation = if (self.tick_scope) |scope| try scope.cancelResidentTransaction(handle) else try self.control.cancelResidentTransaction(handle);
            }
            if (state.invalidation) |gate| if (try self.cancellationResult(gate)) |cancel| {
                state.invalidation = null;
                self.input(.{ .position = self.position(), .payload = .{ .admission = cancel.admission } });
                self.observe(.{ .event = cancel.receipt });
            };
            result = if (self.tick_scope) |scope| try scope.pollResidentTransaction(handle) else try self.control.pollResidentTransaction(handle);
            if (state.block) |block| {
                if (!state.admission_seen) if (try self.scheduleAdmission(block)) |admission| {
                    state.admission_seen = true;
                    self.input(.{ .position = self.position(), .payload = .{ .admission = admission } });
                };
                while (try self.pollExecutionReceipt(block, &state.receipt_cursor)) |record| self.observe(.{ .event = record });
                if (state.plan) |plan| while (try self.pollPlanPhase(plan, &state.phase_cursor)) |phase| {
                    if (!std.meta.eql(phase.token, state.token)) return error.InvalidState;
                    if (phase.outcome == .executed) state.executed_phase = phase;
                    self.receipt(.{ .phase_terminal = phase });
                };
            }
            const actual = result orelse return;
            if (actual.outcome == .executed and !state.committed) {
                const phase = state.executed_phase orelse return;
                try self.commitPreviewSeek(state, actual, phase);
            }
            if (state.invalidation != null) return;
            if (state.block) |block| {
                if (try self.scheduleResult(block) == null) return;
                try self.releaseSchedule(block);
                state.block = null;
                state.plan = null;
            }
            if (actual.outcome == .rejected and state.failure == null)
                state.failure = try self.previewSeekSourceFailure(state);
            if (self.tick_scope) |scope| try scope.acknowledgeResidentTransaction(handle) else try self.control.acknowledgeResidentTransaction(handle);
            state.lower = null;
            if (state.committed) {
                self.finishPreviewSeek(state, .{ .executed = state.executed_phase.? });
                return;
            }
            state.failure = state.failure orelse if (actual.outcome == .cancelled) .cancelled else previewSeekFailure(actual.reason);
        } else if (!state.cancel_requested and state.failure == null) return;
        // No executed result can reach this branch. Only fresh resources retire;
        // neither the old playback nor an execution-winning ring is cancelled.
        state.generation.retireRequestWindows(state.ticket.request_id);
        if (state.replacement) |group| {
            try self.retireResidentGroup(group);
            state.drain_group = group;
            state.replacement = null;
        }
        self.finishPreviewSeek(state, .{ .rejected = state.failure orelse .cancelled });
    }
    fn previewSeekFailure(reason: trace.schema.Reason) v1.FailureV1 {
        return switch (reason) {
            .stream_underrun => .stream_underrun,
            .stale_asset_generation, .invalid_handle => .stale_bank,
            .command_queue_full => .command_queue_full,
            .planner_capacity => .resource_limit,
            .voice_budget_exceeded => .voice_budget_exceeded,
            .unsupported_operation, .unsupported_capability => .unsupported_capability,
            .stale_epoch, .late => .invalid_order,
            else => .invalid_state,
        };
    }
    fn commitPreviewSeek(self: *MusicRuntime, state: *PreviewSeek, result: rt.resident_transaction.Result, phase: api.PhaseReceipt) !void {
        const physical = result.physical orelse return error.InvalidState;
        const generation = state.generation;
        if (!state.published or result.kind != .restore or result.outcome != .executed or result.execution_ordinal == 0 or
            result.frame != state.staged.anchor.frame or result.frame != phase.effective_frame or result.bank_generation != generation.runtime_generation or
            result.previous_bank_generation != generation.runtime_generation or result.previous_transport_epoch != state.old_transport_epoch or
            result.transport_epoch != state.new_transport_epoch or !physical.group.eql(state.replacement.?) or physical.paused or
            physical.segment != generation.loaded.tables.segments[state.segment_index].key.id or physical.cursor != state.target or
            physical.loop_epoch != 0 or physical.source_incarnation != 1 or physical.mutation_epoch != 1) return error.InvalidState;
        try generation.director.?.validatePreviewSeek(&state.staged);
        // Capacity and exact logical ownership were preflighted before publish.
        // This genuine scheduler phase is the sole logical commit authority.
        try generation.director.?.commitPreviewSeek(&state.staged, phase);
        self.retireResidentGroup(state.old_group) catch unreachable;
        state.drain_group = state.old_group;
        generation.bindExecutedRequestWindows(state.ticket.request_id, state.replacement.?);
        self.device_stream_origin = null;
        self.device_stream_entry_seen = true;
        self.active_group = state.replacement;
        state.replacement = null;
        generation.transport = state.transport;
        self.bar_offset = state.bar_offset;
        self.active_source_incarnation = 1;
        self.rendering_segment = generation.loaded.tables.segments[state.segment_index].key.id;
        self.has_executed = true;
        state.committed = true;
        if (!self.shutdown_requested.load(.acquire)) self.state = .playing;
    }
    fn collectPreviewSeekRetirement(self: *MusicRuntime) !void {
        const state = self.preview_seek orelse return;
        if (!state.terminal or state.lower != null or state.block != null or state.invalidation != null or state.replacement != null) return;
        if (state.drain_group) |group| {
            for (self.retired_groups) |entry| if (entry) |retired| if (retired.eql(group)) return;
            if (state.generation.groupWindowCount(group) != 0) return;
        }
        if (!state.committed and state.generation.requestWindowCount(state.ticket.request_id) != 0) return;
        state.generation.releasePreparation();
        self.preview_seek = null;
        self.allocator.destroy(state);
    }

    pub fn start(self: *MusicRuntime, reference: v1.BankRefV1, initial_state: api.MusicStateId) !v1.RequestTicketV1 {
        try self.requireFinalizationOpen();
        _ = self.context_raw_callers.fetchAdd(1, .seq_cst);
        defer _ = self.context_raw_callers.fetchSub(1, .seq_cst);
        try self.requireRawContextCallV1();
        return self.startActualV1(reference, initial_state, false);
    }
    fn startActualV1(self: *MusicRuntime, reference: v1.BankRefV1, initial_state: api.MusicStateId, recorded_context_call: bool) !v1.RequestTicketV1 {
        try self.claimControlV1();
        defer self.control_guard.store(false, .release);
        try self.checkBank(reference);
        if (self.state != .ready or self.unloading or self.pending != null or self.in_flight != null or self.layer_in_flight != null or self.interruption != null or self.ingress.occupied.load(.acquire) != 0) return error.InvalidState;
        _ = try find(self.generation.?.loaded.tables.states, initial_state.value());
        return self.submitActualV1(reference, .{ .set_state = .{ .state = initial_state } }, recorded_context_call);
    }

    pub fn pollReceiptV1(self: *MusicRuntime) !?v1.ReceiptV1 {
        try self.requireFinalizationOpen();
        _ = self.context_raw_callers.fetchAdd(1, .seq_cst);
        defer _ = self.context_raw_callers.fetchSub(1, .seq_cst);
        try self.requireRawContextCallV1();
        return self.pollReceiptActualV1();
    }
    fn pollReceiptActualV1(self: *MusicRuntime) !?v1.ReceiptV1 {
        try self.requireCausalRoleV1(.control);
        if (self.mode != .versioned) return error.InvalidMode;
        return self.ingress.poll();
    }
    fn acceptV1(self: *MusicRuntime, item: ingress.Item) void {
        self.in_flight = item.ticket;
        self.ingress.emit(.{ .ticket = item.ticket, .event = .{ .accepted = .{ .control_tick = if (self.tick_scope != null) self.tick else self.tick + 1, .render_frame = if (self.tick_scope != null) self.control_frame else self.control.scheduled.render_frame.load(.acquire) } } });
    }
    fn finishTicketV1(self: *MusicRuntime, ticket: v1.RequestTicketV1, terminal: @FieldType(@FieldType(v1.ReceiptV1, "event"), "terminal")) void {
        const primary = if (self.in_flight) |current| std.meta.eql(current, ticket) else false;
        const interrupt = if (self.interruption) |current| std.meta.eql(current.ticket, ticket) else false;
        const layer = if (self.layer_in_flight) |current| std.meta.eql(current, ticket) else false;
        // Shutdown/unload may already have retired an unpublished intent, but
        // a later observation never emits a second terminal against its credit.
        const policy_slot = if (self.policy_storage) |storage| storage.action(ticket) else null;
        if (!primary and !interrupt and !layer and policy_slot == null) return;
        if (terminal == .rejected) self.last_error = terminal.rejected;
        self.ingress.emit(.{ .ticket = ticket, .event = .{ .terminal = terminal } });
        if (primary) self.in_flight = null;
        if (layer) self.layer_in_flight = null;
        if (interrupt) self.interruption = null;
        if (policy_slot) |slot| slot.action_ticket = null;
        if (self.policy_storage) |storage| if (storage.music_stop_ticket) |bound| if (std.meta.eql(bound, ticket)) {
            storage.music_stop_ticket = null;
            storage.music_stop_phase = null;
            storage.cleanup_phase = null;
        };
        if (self.action_ticket) |action_ticket| if (std.meta.eql(action_ticket, ticket)) {
            self.action = null;
            self.action_ticket = null;
            self.action_boundary_stop = null;
        };
    }
    fn finishV1(self: *MusicRuntime, terminal: @FieldType(@FieldType(v1.ReceiptV1, "event"), "terminal")) void {
        if (self.in_flight) |ticket| self.finishTicketV1(ticket, terminal);
    }
    fn finishInterruptionV1(self: *MusicRuntime, terminal: @FieldType(@FieldType(v1.ReceiptV1, "event"), "terminal")) void {
        if (self.interruption) |interrupt| self.finishTicketV1(interrupt.ticket, terminal);
    }
    fn ticketForRequestV1(self: *const MusicRuntime, request_id: u64) ?v1.RequestTicketV1 {
        if (self.in_flight) |ticket| if (ticket.request_id == request_id) return ticket;
        if (self.layer_in_flight) |ticket| if (ticket.request_id == request_id) return ticket;
        if (self.interruption) |interrupt| if (interrupt.ticket.request_id == request_id) return interrupt.ticket;
        return null;
    }
    fn policyStopOwnsV1(self: *const MusicRuntime, ticket: v1.RequestTicketV1) bool {
        if (self.policy_storage) |storage| if (storage.music_stop_ticket) |bound| return std.meta.eql(bound, ticket);
        return false;
    }
    fn ticketHasPlanV1(self: *const MusicRuntime, ticket: v1.RequestTicketV1) bool {
        if (self.preview_seek) |state| if (std.meta.eql(state.ticket, ticket)) return true;
        if (self.pending) |pending| if (pending.request_ticket) |bound| if (std.meta.eql(bound, ticket)) return true;
        return self.policyStopOwnsV1(ticket) or self.layerTicketOwnsV1(ticket);
    }
    fn layerTicketOwnsV1(self: *const MusicRuntime, ticket: v1.RequestTicketV1) bool {
        for (self.generations.entries) |entry| if (entry) |value| if (value.payload.layer_owner) |owner| {
            for ([_][]?*layer_owner.Instance{ &owner.instances, &owner.fallback_instances }) |instances| {
                for (instances) |instance| if (instance) |current| if (current.pending_request) |request| {
                    if (std.meta.eql(request.ticket, ticket)) return true;
                };
            }
        };
        return false;
    }
    fn collectLayerControllers(self: *MusicRuntime, control: anytype) !void {
        for (self.generations.entries) |entry| if (entry) |value| if (value.payload.layer_owner) |owner| {
            for ([_][]?*layer_owner.Instance{ &owner.instances, &owner.fallback_instances }) |instances| {
                for (instances) |instance| if (instance) |current| {
                    // Validate before polling: a successful poll consumes its
                    // installation event, so a late ownership check is lossy.
                    if (current.pending_request) |request| {
                        const owned = self.ticketForRequestV1(request.ticket.request_id) orelse return error.InvalidState;
                        if (!std.meta.eql(owned, request.ticket)) return error.InvalidState;
                    }
                    const result = try current.collectPrepared(control);
                    for (result.installations[0..result.installation_count]) |installation| {
                        const failure = layerInstallationFailure(installation.rejection orelse .none);
                        if (current.driver.pending) |program| if (program.eql(installation.program)) {
                            current.driver.pending = null;
                            if (installation.phase == null) {
                                // A failed initial binding cannot leave a ghost
                                // trajectory. Internal rejection also stops that
                                // driver; only a new accepted input can rearm it.
                                current.driver.enabled = false;
                                current.driver.failure = failure;
                                self.last_error = failure;
                            }
                        };
                        if (current.pending_request) |request| if (installation.program.eql(request.program)) {
                            // Copied by the sole M2 collector before block release.
                            self.finishTicketV1(request.ticket, if (installation.phase) |phase| .{ .executed = phase } else .{ .rejected = failure });
                            current.pending_request = null;
                        };
                    }
                };
            }
        };
    }
    fn layerInstallationFailure(reason: trace.schema.Reason) v1.FailureV1 {
        return switch (reason) {
            .none => .cancelled,
            .stale_asset_generation, .invalid_handle => .stale_bank,
            .command_queue_full => .command_queue_full,
            .planner_capacity => .resource_limit,
            .voice_budget_exceeded => .voice_budget_exceeded,
            .unsupported_operation, .unsupported_capability => .unsupported_capability,
            .stale_epoch, .late => .invalid_order,
            else => .invalid_state,
        };
    }
    /// Sample the genuine Director only at this owned completed-frame frontier.
    /// Latest unpublished values are coalesced while the two-slot M2 owner is
    /// busy. No new host acceptance or source-clock origin is manufactured.
    fn prepareLayerDrivers(self: *MusicRuntime) !void {
        const generation = self.generation orelse return;
        const owner = generation.layer_owner orelse return;
        if (!owner.observed_sampling) return;
        const group = self.active_group orelse return;
        const current = (try owner.getSource(group, self.active_source_incarnation)) orelse return;
        if (current.controller_closed or current.retiring) return;
        if (self.shutdown_requested.load(.acquire) or self.unloading or self.state == .stopping or
            (self.pending != null and self.pending.?.operation == .stop) or self.action == .stop)
        {
            current.driver.enabled = false;
            return;
        }
        // Verify identity before advancing any source-derived musical clock.
        // Render may switch after collection but before this preparation phase.
        const scope = self.tick_scope orelse return error.InvalidMode;
        try scope.requirePhase(.prepare);
        if ((try scope.musicGroupTerminal(group)) != null) return;
        const observed = self.musicVoiceObservation(group) catch |err| switch (err) {
            error.InvalidState => return,
            else => return err,
        };
        const source = try scope.musicGroupSource(group);
        if ((try scope.musicGroupTerminal(group)) != null) return;
        if (source.source_incarnation != current.source_incarnation or observed.source_incarnation != current.source_incarnation or observed.state == .finished) return;
        // Director time is physical Control time; the bar comes only from the
        // matching source coordinate. Deferred adoption cannot advance it.
        try generation.director.?.advance(self.control_frame, try self.barAt(self.control_frame));
        if (!current.driver.enabled or self.state != .playing or self.pending != null or self.action != null or
            current.pending_request != null or current.driver.pending != null or !current.controller.preparedCanSubmit()) return;
        const values = generation.director.?.values[0..generation.loaded.tables.parameters.len];
        if (!current.driverValuesChanged(values)) return;
        if (observed.paused) return;
        var updates: [rt.music_group.max_layers]prepared_layers.Update = undefined;
        const targets = try current.evaluate(values, &updates);
        const order = std.math.add(u64, current.controller.last_input_order, 1) catch {
            current.driver.enabled = false;
            current.driver.failure = .resource_limit;
            self.last_error = .resource_limit;
            return;
        };
        const plan = self.takePlan() catch |err| {
            current.driver.enabled = false;
            current.driver.failure = failureV1(err);
            self.last_error = failureV1(err);
            return;
        };
        const submitted = current.controller.submitPreparedTargets(scope, targets, .{
            .execute_frame = try scope.earliestPlanFrame(),
            .plan_id = plan,
            .plan_epoch = 1,
            .input_order = order,
            .bank_generation = generation.runtime_generation,
            .transport_epoch = observed.transport_epoch,
            .mutation_epoch = observed.mutation_epoch,
            .source_incarnation = current.source_incarnation,
            .expected_previous = current.controller.preparedProgram(),
            .musical = generation.transport.map,
        }) catch |err| {
            current.driver.failure = failureV1(err);
            self.last_error = failureV1(err);
            switch (err) {
                error.PendingAutomation, error.RollbackPending, error.LayerProgramBusy, error.PreparedCapacity, error.CommandQueueFull, error.OutOfMemory, error.StaleBinding, error.InvalidState => {},
                else => current.driver.enabled = false,
            }
            return;
        };
        current.observeDriverValues(values, self.control_frame, self.tick);
        current.driver.failure = null;
        if (submitted == .scheduled) current.driver.pending = submitted.scheduled.program;
        self.markAuthoritativeTraceIncompleteV1();
    }
    /// One genuine Director proposal on heap scratch. Failure before schedule
    /// publication leaves every authoritative parameter, accepted frontier and
    /// controller target unchanged. No second Director or mixer is attached.
    fn acceptLayerParameter(self: *MusicRuntime, request: api.MusicRequest, accepted: trace.Input, bar: u64, decisions: *selectors.Trace) !void {
        const generation = self.generation orelse return error.InvalidState;
        const owner = generation.layer_owner orelse return error.UnsupportedOperation;
        const group = self.active_group orelse return error.InvalidState;
        const current = (try owner.getSource(group, self.active_source_incarnation)) orelse return error.UnsupportedOperation;
        if (self.state == .paused or current.retiring or current.controller_closed or current.pending_request != null) return error.InvalidState;
        const parameter = try find(generation.loaded.tables.parameters, request.payload.set_parameter.parameter.value());
        var bound = false;
        for (current.parameters[0..current.controller.bindings.len]) |index| bound = bound or index == parameter;
        if (!bound) return error.UnsupportedOperation;
        const ticket = self.ticketForRequestV1(request.request_id) orelse return error.InvalidState;
        const scope = self.tick_scope orelse return error.InvalidMode;
        try scope.requirePhase(.prepare);
        const proposal = generation.layer_director_scratch orelse return error.InvalidState;
        proposal.* = generation.director.?.*;
        const before_decisions = decisions.count;
        errdefer decisions.count = before_decisions;
        try proposal.accept(&.{accepted}, bar, decisions);
        var updates: [rt.music_group.max_layers]prepared_layers.Update = undefined;
        const targets = try current.evaluate(proposal.values[0..proposal.tables.parameters.len], &updates);
        // A hard cut can reuse the Render slot before a finished observation
        // is copied for this exact Control-owned group. In particular, an
        // unchanged target returns before lower M2 binding admission. Retained
        // terminal custody must therefore fence both sides of this read.
        if ((try scope.musicGroupTerminal(group)) != null) return error.InvalidState;
        const observed = try scope.musicVoiceObservation(group);
        if ((try scope.musicGroupTerminal(group)) != null) return error.InvalidState;
        if (observed.paused or observed.state != .playing or observed.source_incarnation != current.source_incarnation) return error.InvalidState;
        // Sample once after the exact playing observation. An unchanged target
        // bypasses lower M2 admission, so it needs the same pre-onset fence as
        // a changed target before either can commit Director scratch.
        const execute_frame = try scope.earliestPlanFrame();
        if (self.pending) |pending| if (pending.transition) |execution| if (execution.crossfade != null) {
            if (self.pendingCrossfadeLayerOnsetV1(group)) |onset| {
                if (execute_frame >= onset) return error.InvalidState;
            } else if (!self.pendingCrossfadeTargetLayerV1(group)) return error.InvalidState;
        };
        // This is the existing controller's local decision order. Retain the
        // host RequestID/Position separately; internal samples share no host ID.
        const order = try std.math.add(u64, current.controller.last_input_order, 1);
        const plan = try self.takePlan();
        const submitted = try current.controller.submitPreparedTargets(scope, targets, .{
            .execute_frame = execute_frame,
            .plan_id = plan,
            .plan_epoch = 1,
            .input_order = order,
            .bank_generation = generation.runtime_generation,
            .transport_epoch = observed.transport_epoch,
            .mutation_epoch = observed.mutation_epoch,
            .source_incarnation = current.source_incarnation,
            .expected_previous = current.controller.preparedProgram(),
            .force_binding_install = owner.observed_sampling,
            .musical = generation.transport.map,
        });
        // All remaining publication is infallible, after actual M2 admission.
        generation.director.?.* = proposal.*;
        if (owner.observed_sampling) {
            current.driver.enabled = true;
            current.driver.ticket = ticket;
            current.driver.accepted = accepted.position;
            current.driver.failure = null;
            current.observeDriverValues(proposal.values[0..proposal.tables.parameters.len], accepted.position.accepted_control_frame, accepted.position.control_tick);
            // Forced admission must produce the first real binding receipt.
            std.debug.assert(submitted == .scheduled);
            current.driver.pending = submitted.scheduled.program;
        }
        // A subordinate gain does not replace the transition provenance.
        if (self.layer_in_flight == null or !std.meta.eql(self.layer_in_flight.?, ticket))
            self.latest_request_position = accepted.position;
        self.input(accepted);
        self.receipt(.{ .request_accepted = .{ .context = @enumFromInt(self.config.context), .accepted_control_frame = accepted.position.accepted_control_frame, .control_tick = accepted.position.control_tick, .input_order = accepted.position.input_order, .request = request } });
        switch (submitted) {
            .unchanged => self.finishTicketV1(ticket, .unchanged),
            .scheduled => |scheduled| current.pending_request = .{ .ticket = ticket, .accepted = accepted.position, .program = scheduled.program },
        }
        // Full capture does not yet encode versioned host bindings and all M2
        // owner decisions. Preserve existing truthful incomplete capability.
        self.markAuthoritativeTraceIncompleteV1();
    }
    fn rejectUnpublishedV1(self: *MusicRuntime, reason: v1.FailureV1) void {
        // Plan-bound owners must await their real phase, including a phase that
        // already executed before Control collected it. Other owners have no
        // published operation that could justify an executed terminal.
        if (self.in_flight) |ticket| if (!self.ticketHasPlanV1(ticket)) self.finishTicketV1(ticket, .{ .rejected = reason });
        if (self.layer_in_flight) |ticket| if (!self.layerTicketOwnsV1(ticket)) self.finishTicketV1(ticket, .{ .rejected = reason });
        if (self.interruption) |interrupt| if (!self.ticketHasPlanV1(interrupt.ticket)) self.finishTicketV1(interrupt.ticket, .{ .rejected = reason });
    }
    /// The bank whitelist is validated before provider opens. This is the
    /// independent live-state half: never consume a cold/resume acceptance or
    /// target a prepared future group. No Render work or waiting occurs here.
    fn canAcceptFillLayerV1(self: *const MusicRuntime) bool {
        if (self.layer_in_flight != null or self.state != .playing or self.active_group == null or
            self.active_source_incarnation != 1 or self.preparing != null or self.resuming_request != null or
            self.fill_continuation != null or self.action != null or self.interruption != null or
            self.resident_state != null or self.live_reload != null or self.preview_seek != null or self.unloading or
            self.shutdown_requested.load(.acquire) or self.cleanup_stop_pending) return false;
        if (self.config_v1.streamed_fill_mode != .rolling_high_watermark or
            self.config_v1.streaming_reservation != .release_profile or
            self.config_v1.layer_gain.bindings.len == 0 or
            self.config_v1.layer_gain.parameter_sampling != .accepted_only) return false;
        const pending = self.pending orelse return false;
        const execution = pending.transition orelse return false;
        if (pending.invalidation != null or pending.effective or pending.request_ticket == null or
            self.in_flight == null or !std.meta.eql(pending.request_ticket.?, self.in_flight.?)) return false;
        // Only the already prepared bounded hard-cut route may share its
        // primary ticket with a group-local parameter installation. A three-
        // phase count alone is insufficient: every prefix must be a fill and
        // the sole final phase must be the target.
        const phases = execution.cursor.phases.slice();
        if (phases.len < 2 or phases.len > assets.max_resident_fill_steps + 1 or
            phases[phases.len - 1].kind != .target_entry) return false;
        for (phases[0 .. phases.len - 1]) |phase| if (phase.kind != .fill_entry) return false;
        return true;
    }
    fn canAcceptCrossfadeLayerV1(self: *const MusicRuntime) bool {
        const group = self.active_group orelse return false;
        return self.layer_in_flight == null and
            (self.pendingCrossfadeLayerOnsetV1(group) != null or self.pendingCrossfadeTargetLayerV1(group));
    }
    /// The pending crossfade source may accept one subordinate gain. Validate
    /// the exact published projection and primary ticket, never infer this
    /// permission from a phase count or a merely prepared future target.
    /// This is also rechecked after the live source observation, when the
    /// subordinate already owns layer_in_flight but has not committed scratch.
    fn pendingCrossfadeLayerOnsetV1(self: *const MusicRuntime, group: rt.GroupHandle) ?u64 {
        if (self.state != .playing or self.active_group == null or !self.active_group.?.eql(group) or
            self.active_source_incarnation != 1 or self.preparing != null or self.resuming_request != null or
            self.fill_continuation != null or self.confirmed_fill != null or self.action != null or self.interruption != null or
            self.resident_state != null or self.live_reload != null or self.preview_seek != null or self.unloading or self.crossfade_outgoing != null or
            self.shutdown_requested.load(.acquire) or self.cleanup_stop_pending) return null;
        if (self.config_v1.crossfade.bindings.len == 0 or self.config_v1.layer_gain.bindings.len == 0 or
            self.config_v1.layer_gain.parameter_sampling != .accepted_only or
            self.config_v1.streaming_reservation != .release_profile) return null;
        const generation = self.generation orelse return null;
        const pending = self.pending orelse return null;
        const execution = pending.transition orelse return null;
        const projection = execution.crossfade orelse return null;
        const primary = pending.request_ticket orelse return null;
        const intent = pending.intent orelse return null;
        if (pending.operation != .transition or pending.generation != generation or pending.invalidation != null or pending.effective or
            self.in_flight == null or !std.meta.eql(primary, self.in_flight.?) or pending.source_incarnation != 1 or
            primary.request_id != projection.identity.request_id or intent.request_id != primary.request_id or
            intent.rule_id != projection.identity.rule_id or !std.meta.eql(pending.token, projection.identity.target_token)) return null;
        const curve = self.config_v1.crossfade.curveFor(projection.identity.rule_id) orelse return null;
        switch (curve) {
            .linear => if (projection.kind != .bound_linear_direct) return null,
            .equal_power => if (projection.kind != .bound_equal_power_direct) return null,
            else => return null,
        }
        const source = projection.source.group;
        const referenced_source = execution.referenced_groups[0] orelse return null;
        if (source.index != group.index or source.generation != group.generation or source.stable_id != group.generation or
            !referenced_source.eql(group) or projection.source.tail.segment != self.rendering_segment) return null;
        if (execution.cursor.phases.count != 1 or projection.phases.count != 1 or
            execution.cursor.cancel_requested_frame != null or execution.cursor.outcomes[0] != null) return null;
        const phase = execution.cursor.phases.items[0];
        if (phase.kind != .target_entry or !std.meta.eql(phase, projection.phases.items[0]) or
            !std.meta.eql(phase.token, pending.token) or phase.execute_frame != projection.onset_frame or
            phase.segment != projection.identity.target_segment) return null;
        const target = pending.target_group orelse return null;
        const prepared_target = execution.groups[0] orelse return null;
        const bound_target = execution.cursor.groups[0] orelse return null;
        if (!target.eql(prepared_target) or bound_target.index != target.index or bound_target.generation != target.generation or
            bound_target.stable_id != target.generation) return null;
        return projection.onset_frame;
    }
    /// Entry collection can finish the primary ticket while an earlier null
    /// schedule-result acquisition retains Pending until the next tick. Only
    /// the exact collected target may use that retained plan's subordinate lane;
    /// its executed cursor receipt, not a finished primary ticket, is authority.
    fn pendingCrossfadeTargetLayerV1(self: *const MusicRuntime, group: rt.GroupHandle) bool {
        if (self.state != .playing or self.active_group == null or !self.active_group.?.eql(group) or
            self.active_source_incarnation != 1 or self.preparing != null or self.resuming_request != null or
            self.fill_continuation != null or self.confirmed_fill != null or self.action != null or self.interruption != null or
            self.resident_state != null or self.live_reload != null or self.preview_seek != null or self.unloading or self.in_flight != null or
            self.shutdown_requested.load(.acquire) or self.cleanup_stop_pending) return false;
        if (self.config_v1.crossfade.bindings.len == 0 or self.config_v1.layer_gain.bindings.len == 0 or
            self.config_v1.layer_gain.parameter_sampling != .accepted_only or
            self.config_v1.streaming_reservation != .release_profile) return false;
        const generation = self.generation orelse return false;
        const pending = self.pending orelse return false;
        const execution = pending.transition orelse return false;
        const projection = execution.crossfade orelse return false;
        const primary = pending.request_ticket orelse return false;
        const intent = pending.intent orelse return false;
        if (pending.operation != .transition or pending.generation != generation or pending.invalidation != null or !pending.effective or
            pending.source_incarnation != 1 or primary.context != self.config.context or !std.meta.eql(primary.bank, self.bankRef()) or
            primary.request_id != projection.identity.request_id or intent.request_id != primary.request_id or
            intent.rule_id != projection.identity.rule_id or !std.meta.eql(pending.token, projection.identity.target_token)) return false;
        const curve = self.config_v1.crossfade.curveFor(projection.identity.rule_id) orelse return false;
        switch (curve) {
            .linear => if (projection.kind != .bound_linear_direct) return false,
            .equal_power => if (projection.kind != .bound_equal_power_direct) return false,
            else => return false,
        }
        const source = projection.source.group;
        const referenced_source = execution.referenced_groups[0] orelse return false;
        if (source.index != referenced_source.index or source.generation != referenced_source.generation or
            source.stable_id != referenced_source.generation or referenced_source.eql(group)) return false;
        if (self.crossfade_outgoing) |outgoing| if (!outgoing.eql(referenced_source)) return false;
        if (execution.cursor.phases.count != 1 or projection.phases.count != 1 or execution.cursor.cancel_requested_frame != null or
            execution.cursor.outcomes[0] != .executed or execution.cursor.effective_frames[0] != projection.onset_frame) return false;
        const phase = execution.cursor.phases.items[0];
        if (phase.kind != .target_entry or !std.meta.eql(phase, projection.phases.items[0]) or
            !std.meta.eql(phase.token, pending.token) or phase.execute_frame != projection.onset_frame or
            phase.segment != projection.identity.target_segment or phase.segment != self.rendering_segment) return false;
        const target = pending.target_group orelse return false;
        const bound_target = execution.cursor.groups[0] orelse return false;
        const referenced_target = execution.referenced_groups[1] orelse return false;
        if (!target.eql(group) or !referenced_target.eql(group) or execution.groups[0] != null or
            bound_target.index != group.index or bound_target.generation != group.generation or
            bound_target.stable_id != group.generation) return false;
        return true;
    }
    fn acceptInterruptionV1(self: *MusicRuntime, item: ingress.Item) void {
        self.interruption = .{ .ticket = item.ticket };
        self.ingress.emit(.{ .ticket = item.ticket, .event = .{ .accepted = .{ .control_tick = if (self.tick_scope != null) self.tick else self.tick + 1, .render_frame = if (self.tick_scope != null) self.control_frame else self.control.scheduled.render_frame.load(.acquire) } } });
        // Director mutation and cancellation follow its successful preflight.
        // A rejected interrupt must leave the existing desired/plan intact.
    }
    fn recordedContextRejectionV1(self: *const MusicRuntime, item: ingress.Item, reason: v1.FailureV1) bool {
        if (self.public_recording.mode != .chunks or self.public_recording.profile != .stream_context_serial_v1 or
            !self.public_recording.driving or self.tick_scope == null or !self.control_guard.load(.acquire) or
            self.context_host_journal.pending != null or self.context_host_journal.poisoned or self.context_host_journal.incomplete or
            self.context_recording_violation.load(.acquire) or self.generation == null or item.command != .music) return false;
        // These real queued rejections need no accepted request fact. Their
        // exact host submit and explicit receipt polls supply the missing proof.
        switch (reason) {
            .request_in_progress, .invalid_state => {},
            else => return false,
        }
        _ = context_host.RequestPayload.fromPublic(item.command.music) catch return false;
        // The pristine, raw-gated ingress issues contiguous tickets solely via
        // completed host calls. Verify this is its actual just-consumed ticket.
        return item.ticket.context == self.config.context and std.meta.eql(item.ticket.bank, self.bankRef()) and
            item.ticket.request_id != 0 and item.ticket.request_id < self.context_host_journal.next_request_id and
            item.ticket.request_id + 1 == self.ingress.next_control;
    }
    fn rejectItemV1(self: *MusicRuntime, item: ingress.Item, reason: v1.FailureV1) void {
        // Older profiles have no rejected-ingress host proof. Profile 7 permits
        // only known, journal-bound no-tick-error Busy/state rejection paths.
        if (self.public_recording.phase == .active and !self.recordedContextRejectionV1(item, reason)) self.failRecordingV1();
        self.last_error = reason;
        self.ingress.emit(.{ .ticket = item.ticket, .event = .{ .accepted = .{ .control_tick = if (self.tick_scope != null) self.tick else self.tick + 1, .render_frame = if (self.tick_scope != null) self.control_frame else self.control.scheduled.render_frame.load(.acquire) } } });
        self.ingress.emit(.{ .ticket = item.ticket, .event = .{ .terminal = .{ .rejected = reason } } });
    }
    fn rejectQueuedV1(self: *MusicRuntime) void {
        // Bounded drain. An in-progress producer may publish the missing next
        // ticket later; no later ticket is skipped or silently discarded.
        for (0..512) |_| {
            const item = self.ingress.pop() orelse break;
            self.ingress.emit(.{ .ticket = item.ticket, .event = .{ .accepted = .{ .control_tick = self.tick, .render_frame = self.control.scheduled.render_frame.load(.acquire) } } });
            self.ingress.emit(.{ .ticket = item.ticket, .event = .{ .terminal = .{ .rejected = if (self.unloading) .stale_bank else .runtime_stopped } } });
            if (item.command == .reload) if (self.live_reload) |state| {
                state.accepted = true;
                state.terminal_emitted = true;
                state.result = .{ .failed = .runtime_stopped };
            };
            if (item.command == .restore) if (self.resident_state) |state| {
                state.accepted = true;
                state.terminal_emitted = true;
                state.terminal = true;
                state.failure = .runtime_stopped;
            };
        }
    }

    /// Versioned resident pump. It preserves the existing update/controlTick
    /// split internally and is NOT the future integrated streaming tick seam.
    /// Worker preparation is always explicitly pumped by the host.
    pub fn pumpResidentV1(self: *MusicRuntime, control_limit: usize) !usize {
        try self.checkControlV1();
        if (self.usesIntegratedTickV1()) return error.InvalidMode;
        try self.claimControlV1();
        self.collectBorrowedSounds();
        self.collectLoad() catch |err| {
            self.control_guard.store(false, .release);
            return err;
        };
        self.control_guard.store(false, .release);
        if (self.deviceRecoveryActive()) {
            try self.beginSplitReloadTick();
            errdefer self.control_guard.store(false, .release);
            if (self.generation != null) try self.collect();
            try self.acceptDeviceLossOwned();
            try self.progressDeviceRecovery(null);
            self.control_guard.store(false, .release);
            const count = try self.control.controlTick(control_limit);
            self.publishSnapshot();
            return count;
        }
        if (self.shutdown_requested.load(.acquire)) {
            try self.collectShutdownV1();
            self.rejectQueuedV1();
            const count = try self.control.controlTick(control_limit);
            self.publishSnapshot();
            return count;
        }
        // Preflight the split tick counter before admitting/owning a new input.
        if (self.generation != null) _ = try std.math.add(u64, self.tick, 1);
        try self.stepResidentV1(false, null);
        const count = try self.control.controlTick(control_limit);
        self.publishSnapshot();
        return count;
    }

    fn beginSplitReloadTick(self: *MusicRuntime) !void {
        try self.claimControlV1();
        errdefer self.control_guard.store(false, .release);
        self.tick = try std.math.add(u64, self.tick, 1);
        self.input_order = 0;
        // Observe this actual completed frontier without advancing or resolving
        // the old Director. The exclusive reload owns this whole split tick.
        self.control_frame = self.control.scheduled.render_frame.load(.acquire);
    }

    /// The streamed preparation phase may wait on I/O indefinitely. Drain the
    /// original ingress order so a reserved stop/pause can cancel that wait.
    /// Intervening ordinary requests receive their real Busy terminal; no
    /// ticket is skipped, copied into another queue, or silently discarded.
    fn interruptStreamRestore(self: *MusicRuntime, state: *ResidentState) !bool {
        for (0..self.config_v1.capacity.music_request_drain) |_| {
            const item = self.ingress.pop() orelse return false;
            self.checkBank(item.ticket.bank) catch |err| {
                self.rejectItemV1(item, failureV1(err));
                continue;
            };
            if (item.command != .music or (item.command.music != .stop and item.command.music != .pause)) {
                self.rejectItemV1(item, .request_in_progress);
                continue;
            }
            if (self.state == .stopping or (item.command.music == .pause and (self.state == .paused or self.active_group == null))) {
                self.rejectItemV1(item, .invalid_state);
                continue;
            }
            state.cancel_requested = true;
            try self.cancelResidentState();
            // Keep the cancelled restore ticket and all Worker drain ownership.
            // The priority request uses the established one music action path.
            // An old fill route can still own its public terminal credit while
            // this independent restore waits for new streams. Keep that owner.
            if (self.pending != null or self.in_flight != null) self.acceptInterruptionV1(item) else self.acceptV1(item);
            if (self.active_group == null) {
                // A valid stop cancels initial restore preparation, but no
                // audible group existed and no Render execution is invented.
                std.debug.assert(item.command.music == .stop);
                const at = self.position();
                const normalized = try trace.schema.normalizeRequest(.{ .request_id = item.ticket.request_id, .payload = item.command.music }, self.config_v1.kind, 1, item.ticket.request_id, self.config.context);
                self.input(.{ .position = at, .payload = .{ .request = normalized } });
                self.finishV1(.unchanged);
                return true;
            }
            self.queue[0] = .{ .request_id = item.ticket.request_id, .payload = item.command.music };
            self.queue_count = 1;
            try self.updateResidentOwned(true, null);
            if (self.in_flight != null and self.pending == null and self.generation.?.director.?.desired == null and self.action == null) self.finishV1(.unchanged);
            return true;
        }
        return false;
    }
    fn stepResidentV1(self: *MusicRuntime, integrated: bool, live: ?*LiveTickAttempt) !void {
        if (self.preview_seek != null) {
            // Exclusive through terminal cleanup: each competing request keeps
            // its real ingress order and receives an explicit Busy terminal.
            for (0..self.config_v1.capacity.music_request_drain) |_| {
                const item = self.ingress.pop() orelse break;
                self.rejectItemV1(item, .request_in_progress);
            }
            try self.progressPreviewSeek();
            return;
        }
        if (self.deviceRecoveryActive()) {
            try self.progressDeviceRecovery(live);
            return;
        }
        if (self.live_reload) |state| if (state.accepted and state.result == .pending) {
            // The split driver normally enters this ownership scope through
            // updateResident. Reload's exclusive early path must hold it too.
            if (!integrated) try self.beginSplitReloadTick();
            defer if (!integrated) self.control_guard.store(false, .release);
            if (!integrated) try self.collectLiveReload();
            try self.progressLiveReload();
            return;
        };
        if (self.resident_state) |state| if (!state.terminal and (state.lower != null or (state.kind == .restore and state.accepted))) {
            if (isStreamSnapshotProfile(state.profile) and state.kind == .restore and state.accepted and state.lower == null) {
                if (try self.interruptStreamRestore(state)) return;
            }
            if (state.kind == .restore and state.accepted and state.lower == null) try self.progressResidentRestore(state);
            if (!integrated) try self.updateResident();
            return;
        };
        if (self.generation != null) {
            if (self.unloading) {
                self.requestPolicyStop();
                try self.discardFillContinuation();
                try self.abandonResume();
                // A published plan may already have executed even when Control
                // has not collected its receipt. Its ticket stays owned until
                // that real executed/cancelled phase is acquired by collect().
                self.rejectUnpublishedV1(.stale_bank);
                self.rejectQueuedV1();
                self.generation.?.director.?.desired = null;
                if (self.active_group != null or self.pending != null) {
                    self.action = .stop;
                    self.action_ticket = null;
                    self.action_boundary_stop = null;
                }
            } else for (0..self.config_v1.capacity.music_request_drain) |_| {
                const item = self.ingress.pop() orelse break;
                if (live != null) {
                    const supported = item.command == .music and switch (item.command.music) {
                        .set_state => self.liveInitialEntryV1(),
                        .stop => |mode| mode == .emergency_ramp,
                        else => false,
                    };
                    if (!supported) {
                        self.rejectItemV1(item, .unsupported_capability);
                        continue;
                    }
                }
                if (item.command == .music and item.command.music == .seek_preview) {
                    self.acceptPreviewSeek(item);
                    return;
                }
                if (item.command == .restore) {
                    try self.acceptResidentRestore(item);
                    break;
                }
                if (item.command == .reload) {
                    if (!integrated) try self.beginSplitReloadTick();
                    defer if (!integrated) self.control_guard.store(false, .release);
                    try self.acceptLiveReload(item);
                    return;
                }
                // Never skip the exact next ticket to reach a reserved lane.
                // While an ordinary request owns pending work, intervening
                // ordinary requests receive explicit Busy terminals; a reserved
                // pause/stop can then use a separately owned interruption slot.
                const invalid: ?v1.FailureV1 = validation: {
                    self.checkBank(item.ticket.bank) catch |err| break :validation failureV1(err);
                    const emergency = item.command.music == .stop and item.command.music.stop == .emergency_ramp;
                    if (self.hasBoundaryStopV1() and !emergency) break :validation .request_in_progress;
                    if (item.command.music == .stop and item.command.music.stop == .next_boundary) {
                        if (self.pending != null or self.in_flight != null or self.layer_in_flight != null or
                            self.interruption != null or self.action != null) break :validation .request_in_progress;
                        _ = self.boundaryStopSourceV1(null, false) catch |err| break :validation failureV1(boundaryStopError(err));
                    }
                    if (self.state == .stopping or (self.cleanup_stop_pending and item.command.music != .stop)) break :validation .invalid_state;
                    if (item.command.music == .set_parameter and self.config_v1.streamed_fill_mode == .rolling_high_watermark and
                        self.config_v1.layer_gain.bindings.len != 0 and (self.fill_continuation != null or self.resuming_request != null))
                        break :validation .request_in_progress;
                    if (item.command.music == .pause and self.state == .paused and (self.pending == null or self.pending.?.operation != .resume_music)) break :validation .invalid_state;
                    if (item.command.music == .set_state) {
                        if (integrated) if (self.active_group) |group| {
                            _ = self.collectSourceSwitchHistoryV1(group, self.generation.?) catch |err| break :validation failureV1(err);
                        };
                        if (self.active_source_incarnation == 2 or self.activeSourceSwitchV1() != null) break :validation .unsupported_capability;
                        if (self.state == .paused) break :validation .invalid_state;
                        _ = find(self.generation.?.loaded.tables.states, item.command.music.set_state.state.value()) catch break :validation .invalid_state;
                    }
                    if (item.command.music == .set_context) {
                        // A failed profile-7 capture must not disable genuine
                        // context control or cleanup. Older profiles still reject.
                        const context_profile = self.public_recording.mode == .chunks and
                            self.public_recording.profile == .stream_context_serial_v1 and
                            (self.public_recording.phase == .active or self.public_recording.phase == .failed);
                        if ((self.public_recording.phase != .disabled and !context_profile) or self.causal_sink != null)
                            break :validation .unsupported_capability;
                        if (context_profile and self.state == .paused) break :validation .invalid_state;
                        if (self.state != .ready and self.state != .playing and self.state != .paused)
                            break :validation .invalid_state;
                        if (self.pending != null or self.preparing != null or self.in_flight != null or
                            self.layer_in_flight != null or self.interruption != null or self.action != null or
                            self.live_reload != null or self.reload.ownsResources() or self.resident_state != null or self.deviceRecoveryActive() or
                            self.fill_continuation != null or self.resuming_request != null or self.confirmed_fill != null or
                            self.generation.?.director.?.desired != null)
                            break :validation .request_in_progress;
                    }
                    break :validation null;
                };
                if (invalid == null and item.command.music == .stop and self.active_group == null and self.pending == null and self.in_flight == null and self.interruption == null) {
                    if (self.policy_storage) |storage| if (storage.physicalCount() != 0) {
                        self.acceptV1(item);
                        storage.music_stop_ticket = item.ticket;
                        storage.music_stop_phase = null;
                        storage.cleanup_phase = null;
                        const at = self.position();
                        self.requestPolicyStopAt(at);
                        const normalized = try trace.schema.normalizeRequest(.{ .request_id = item.ticket.request_id, .payload = item.command.music }, self.config_v1.kind, 1, item.ticket.request_id, self.config.context);
                        self.input(.{ .position = at, .payload = .{ .request = normalized } });
                        self.state = .stopping;
                        break;
                    };
                }
                if (invalid == null and item.command.music == .trigger_stinger) {
                    self.acceptStinger(item) catch |err| self.rejectItemV1(item, failureV1(err));
                    continue;
                }
                if (invalid == null and (item.command.music == .begin_duck or item.command.music == .end_duck)) {
                    self.acceptPolicy(item) catch |err| self.rejectItemV1(item, failureV1(err));
                    continue;
                }
                const busy = self.pending != null or self.in_flight != null or self.layer_in_flight != null or self.interruption != null;
                const can_layer = integrated and item.command.music == .set_parameter and
                    (self.canAcceptFillLayerV1() or self.canAcceptCrossfadeLayerV1());
                const emergency = item.command.music == .stop and item.command.music.stop == .emergency_ramp;
                const future_boundary = self.action_boundary_stop != null or
                    (self.pending != null and self.pending.?.boundary_stop != null and !self.pending.?.effective);
                const can_interrupt = self.interruption == null and
                    ((emergency and future_boundary) or
                        (!self.hasBoundaryStopV1() and (item.command.music == .pause or emergency) and
                            (self.pending == null or self.pending.?.operation != .stop)));
                if (invalid) |reason| {
                    self.rejectItemV1(item, reason);
                } else if (busy and !can_interrupt and !can_layer) {
                    self.rejectItemV1(item, .request_in_progress);
                } else {
                    if (can_layer) {
                        self.layer_in_flight = item.ticket;
                        self.ingress.emit(.{ .ticket = item.ticket, .event = .{ .accepted = .{ .control_tick = self.tick, .render_frame = self.control_frame } } });
                    } else if (busy) self.acceptInterruptionV1(item) else self.acceptV1(item);
                    self.queue[0] = .{ .request_id = item.ticket.request_id, .payload = item.command.music };
                    self.queue_count = 1;
                    break;
                }
            }
            if (self.resident_state) |state| if (state.kind == .restore and state.accepted and !state.terminal) return;
            (if (integrated) self.updateResidentOwned(true, live) else self.updateResident()) catch |err| {
                if (live != null and ((err == error.LiveStreamAvailabilityDeferred and live.?.deferred != null) or (err == error.LiveStopPrepareDeferred and live.?.stop_deferred != null) or (err == error.LiveColdStartPrepareDeferred and live.?.cold_start_deferred != null))) return err;
                self.last_error = failureV1(err);
                // The failing input/intent owns its own error boundary below.
                // No prepared plan does not imply that another deferred owner
                // failed; cancellation/publication pressure may also be retryable.
                return err;
            };
            if (self.in_flight != null and self.pending == null and self.generation.?.director.?.desired == null and self.action == null and !self.policyStopOwnsV1(self.in_flight.?) and !self.layerTicketOwnsV1(self.in_flight.?)) self.finishV1(.unchanged);
            if (self.unloading) {
                try self.collectUnload();
                if (self.unloading) self.state = .stopping;
            }
        }
    }

    pub fn usesIntegratedTickV1(self: *const MusicRuntime) bool {
        return self.mode == .versioned and self.config_v1.control_driver == .integrated;
    }

    /// Host Control thread only. Backend owns a stopped callback and transfers
    /// its exclusive renderer token with a copied, validated real flush fact.
    /// The fixed one-event slot never overwrites an unaccepted discontinuity.
    pub fn enqueueDeviceLossV1(self: *MusicRuntime, loss: device_recovery.Loss, token: rt.RuntimeRenderer.DeviceQuiescence) !void {
        try self.claimControlV1();
        defer self.control_guard.store(false, .release);
        try self.renderer.validateDeviceQuiescence(token);
        try loss.flush.validate();
        if (self.device_event != null) return error.CommandQueueFull;
        if (loss.flush.new_device_epoch.value() <= self.device_accepted_epoch.load(.acquire) or loss.flush.old_device_epoch.value() >= loss.flush.new_device_epoch.value() or loss.render_frame != self.renderer.renderFrame() or loss.flush.discarded.end > loss.render_frame) return error.InvalidState;
        if (loss.sample_rate != self.renderer.mixer.sample_rate or loss.channels != self.renderer.mixer.output_layout.count or loss.channel_mask != self.renderer.mixer.output_layout.mask) return error.InvalidState;
        self.device_event = .{ .loss = loss, .token = token };
        self.device_status.stage = .queued;
    }
    /// Compatibility create() retains the original host flush/reopen contract.
    /// Only versioned owners participate in the ordered Control loss ingress.
    /// Non-mutating preflight for host services, before driver/adapter mutation.
    /// The recorded Control thread is immutable for the owner's lifetime.
    pub fn validateDeviceServiceThreadV1(self: *const MusicRuntime) !void {
        try self.checkControlV1();
        if (self.control_guard.load(.acquire)) return error.ConcurrentControl;
    }
    pub fn usesDeviceControlV1(self: *const MusicRuntime) bool {
        return self.mode == .versioned;
    }
    pub fn deviceEpochAcceptedV1(self: *const MusicRuntime, epoch: u64) bool {
        return self.device_accepted_epoch.load(.acquire) == epoch;
    }
    pub fn deviceRecoveryStatusV1(self: *MusicRuntime) !device_recovery.Status {
        try self.claimControlV1();
        defer self.control_guard.store(false, .release);
        return self.device_status;
    }
    pub fn chooseDeviceRecoveryV1(self: *MusicRuntime, epoch: u64, policy_value: api.DeviceRecoveryPolicy) !void {
        try self.claimControlV1();
        defer self.control_guard.store(false, .release);
        if (self.device_status.device_epoch != epoch or self.device_status.stage != .policy_required) return error.InvalidState;
        const recovery = if (self.device_recovery_state) |*value| value else return error.InvalidState;
        if (self.device_stream_candidate != null) return error.DrainPending;
        if (policy_value == .resume_phase and (!recovery.compatible or recovery.physical == null)) return error.UnsupportedCapability;
        self.device_recovery_state.?.loss.policy = policy_value;
        recovery.source_pending = true;
        self.device_status.policy = policy_value;
        self.device_status.failure = null;
        self.device_status.preparation_failure = null;
        self.device_status.stage = .draining;
    }
    /// Exact owned scheduler ledgers, including between-block owners. A matching
    /// context/generation number alone is never authority to cancel SFX work.
    pub fn ownsDevicePlanV1(self: *const MusicRuntime, handle: rt.scheduler.Handle) bool {
        if (self.preview_seek) |value| if (value.plan) |plan| if (std.meta.eql(plan, handle)) return true;
        if (self.pending) |value| if (std.meta.eql(value.plan, handle)) return true;
        if (self.live_reload) |value| if (value.plan) |plan| if (std.meta.eql(plan, handle)) return true;
        if (self.resident_state) |value| if (value.plan) |plan| if (std.meta.eql(plan, handle)) return true;
        if (self.device_recovery_state) |value| if (value.plan) |plan| if (std.meta.eql(plan, handle)) return true;
        if (self.device_stream_candidate) |value| if (value.plan) |plan| if (std.meta.eql(plan, handle)) return true;
        if (self.policy_storage) |storage| {
            if (storage.bootstrap) |plan| if (std.meta.eql(plan.plan, handle)) return true;
            for (storage.slots) |slot| if (slot.occupied) switch (slot.data) {
                inline else => |value| {
                    if (value.begin) |plan| if (std.meta.eql(plan.plan, handle)) return true;
                    if (value.end) |plan| if (std.meta.eql(plan.plan, handle)) return true;
                },
            };
        }
        return false;
    }
    pub fn acceptDeviceControlTickV1(self: *MusicRuntime, scope: rt.ControlRuntime.TickV1) !void {
        try scope.requirePhase(.accept);
        if (self.tick_scope == null or !std.meta.eql(self.tick_scope.?, scope)) return error.InvalidState;
        try self.acceptDeviceLossOwned();
    }
    fn acceptDeviceLossOwned(self: *MusicRuntime) !void {
        const event = self.device_event orelse return;
        // All pre-loss receipts were collected first. If activation won, the
        // now-current generation supplies the source; if not, its real suffix
        // is cancelled below and retains its own ticket and candidate leases.
        var recovery: DeviceRecovery = .{ .loss = event.loss };
        if (self.generation) |generation| {
            recovery.generation = generation.runtime_generation;
            recovery.segment = generation.director.?.committed_segment;
            recovery.clock = generation.transport;
            recovery.source_bar_offset = self.bar_offset;
            recovery.compatible = generation.service == null and generation.layer_owner == null and generation.loaded.bus_graph == null and self.policy_storage == null and self.active_source_incarnation == 1 and self.confirmed_fill == null and self.fill_continuation == null;
            for (generation.loaded.tables.sounds) |sound| if (sound.storage != .resident) {
                recovery.compatible = false;
            };
            const segment = generation.loaded.tables.segments[recovery.segment];
            var zero_entry = false;
            for (generation.loaded.tables.cues[segment.cues.first..][0..segment.cues.count]) |cue| {
                zero_entry = zero_entry or ((cue.kind == .entry or cue.kind == .both) and cue.frame == 0);
            }
            recovery.compatible = recovery.compatible and zero_entry and segment.pickup_ticks == 0 and segment.fallback_segment == s.none;
            recovery.stream_restart_compatible = zero_entry and self.streamDeviceRestartCompatible(generation);
            if (self.active_group) |handle| if (self.renderer.musicGroup(handle)) |group| {
                recovery.compatible = recovery.compatible and !group.paused and group.source_incarnation == 1 and !group.degraded and !group.prepared.hasStreams() and !group.prepared.hasVirtual() and group.ramp_remaining == 0 and group.gain_current == group.prepared.gain and std.meta.eql(group.loop, group.prepared.loop);
                for (group.layers[0..group.layer_count]) |layer| recovery.compatible = recovery.compatible and layer.automation == null and layer.ramp_remaining == 0 and layer.gain_current == layer.prepared.gain;
            };
        }
        recovery.physical = try self.renderer.deviceLossFenceQuiescent(event.token, self);
        if (recovery.stream_restart_compatible) {
            const physical = recovery.physical;
            recovery.stream_restart_compatible = physical != null and !physical.?.paused and physical.?.source_incarnation == 1 and physical.?.segment == self.generation.?.loaded.tables.segments[recovery.segment].key.id;
        }
        const stream_path = recovery.stream_restart_compatible or self.device_stream_candidate != null or
            (if (self.device_recovery_state) |old| old.stream_restart_compatible else false);
        // Old recovery is also genuine scheduled work. Do not overwrite its
        // block/group ownership before consuming the just-created cancellation.
        if (self.device_recovery_state) |old| if (!stream_path and old.block != null) {
            // Collection belongs to prepare, after Control reconciles the fence.
            self.device_recovery_state.?.interrupted_by_loss = true;
            return error.DrainPending;
        };
        if (self.device_recovery_state) |old| if ((old.interrupted_by_loss or old.source_pending) and old.generation == recovery.generation and recovery.physical == null and !self.shutdown_requested.load(.acquire) and !self.unloading) {
            // The next device can fail while old cancellation/Worker credits
            // are still draining, before a restart block even exists. Retain the
            // original real source until recovery executes or actually stops.
            recovery.clock = old.clock;
            recovery.physical = old.physical;
            recovery.compatible = old.compatible;
            recovery.stream_restart_compatible = old.stream_restart_compatible;
            recovery.segment = old.segment;
            recovery.source_bar_offset = old.source_bar_offset;
        };
        if (self.preview_seek) |state| state.cancel_requested = true;
        if (self.live_reload) |state| {
            state.cancel_requested = true;
            if (state.lower == null) self.abortReloadOwned(.requested);
        }
        if (self.resident_state) |state| if (!state.terminal) {
            state.cancel_requested = true;
        };
        if (self.generation) |generation| {
            generation.transport.device_epoch = event.loss.flush.new_device_epoch.value();
            generation.director.?.desired = null;
        }
        self.action = null;
        self.action_ticket = null;
        self.action_boundary_stop = null;
        self.admission_handle.store(0, .release);
        // The fence has already cancelled this exact plan. Keep its identity
        // through late Worker/visibility returns, without holding the loss token.
        if (self.device_stream_candidate) |*candidate| {
            candidate.stage = .retiring;
            candidate.cancel_requested = true;
            if (candidate.committed) candidate.drain_group = self.active_group;
            candidate.generation.retireRequestWindowsScoped(.device_recovery, candidate.window_id);
        }
        const first_failure = if (stream_path) self.device_status.preparation_failure else null;
        self.device_recovery_state = recovery;
        self.device_status = .{ .device_epoch = event.loss.flush.new_device_epoch.value(), .stage = .draining, .policy = event.loss.policy, .accepted_tick = self.tick, .accepted_frame = event.loss.render_frame, .discarded_frames = event.loss.flush.discarded.end - event.loss.flush.discarded.start };
        self.device_status.preparation_failure = first_failure;
        if (first_failure != null) self.device_status.failure = .invalid_state;
        self.input(.{ .position = self.position(), .payload = .{ .device = .{ .kind = .lost, .device_epoch = event.loss.flush.old_device_epoch.value(), .next_device_epoch = event.loss.flush.new_device_epoch.value(), .render_frontier = event.loss.render_frame, .submitted_frontier = event.loss.submitted_frames, .delivered = 0, .delivery_quality = .unavailable, .delivery_error = 0, .flush_start = event.loss.flush.discarded.start, .flush_end = event.loss.flush.discarded.end, .hardware_tail_known = false, .hardware_tail_start = 0, .hardware_tail_end = 0, .recovery = if (event.loss.policy == .restart_at_bar) .restart_at_bar else .resume_phase, .result = .observed } } });
        self.device_accepted_epoch.store(self.device_status.device_epoch, .release);
        self.markAuthoritativeTraceIncompleteV1(); // Device lifecycle is not yet replay-complete.
        self.state = .stopping;
        self.device_event = null;
        try self.renderer.releaseDeviceQuiescence(event.token);
    }
    /// Called only under the backend's genuine quiescence token, before fence.
    /// Inspect the real all-stem source, not an incarnation-number shortcut.
    fn streamDeviceRestartCompatible(self: *MusicRuntime, generation: *Generation) bool {
        // Keep initial DIRECT admission conservative after seek/restore/reload.
        // Device restarts preserve this epoch and still require every live check.
        if (generation.transport.transport_epoch != 1) return false;
        if (!self.usesIntegratedTickV1() or self.state != .playing or generation.transport.paused or
            self.pending != null or self.preparing != null or self.preview_seek != null or self.resident_state != null or
            self.live_reload != null or self.reload.ownsResources() or self.layer_in_flight != null or self.interruption != null or
            self.in_flight != null or self.action != null or self.resuming_request != null or self.fill_continuation != null or
            self.confirmed_fill != null or self.crossfade_outgoing != null or self.cleanup_stop_pending or self.unloading or
            self.shutdown_requested.load(.acquire) or self.outgoing_generation.load(.acquire) != null or
            self.policy_storage != null or generation.layer_owner != null or generation.loaded.bus_graph != null or
            self.config_v1.crossfade.bindings.len != 0 or self.config_v1.layer_gain.bindings.len != 0 or
            self.active_source_incarnation != 1 or self.activeSourceSwitchV1() != null) return false;
        const service = generation.service orelse return false;
        if (service != self.owned_streaming or service.replay_mode or generation.readiness == null) return false;
        const logical = generation.director.?;
        if (logical.desired != null or logical.pendingCount() != 0 or logical.paused or logical.suspended_target_entry != null or logical.pause_acceptance != null or logical.resume_acceptance != null) return false;
        const segment = generation.loaded.tables.segments[logical.committed_segment];
        if (segment.key.id != self.rendering_segment or segment.storage != .streaming or segment.layers.count != 4 or
            segment.loop_end <= segment.loop_start or segment.pickup_ticks != 0 or segment.fallback_segment != s.none or segment.emergency != 0) return false;
        if (!std.meta.eql(generation.transport.map, generation.solver.?.maps[segment.tempo])) return false;
        const handle = self.active_group orelse return false;
        const origin = self.device_stream_origin orelse return false;
        if (origin.generation != generation.runtime_generation or !origin.group.eql(handle)) return false;
        const group = self.renderer.musicGroup(handle) orelse return false;
        const authored_loop = group.loop orelse return false;
        if (authored_loop.start != segment.loop_start or authored_loop.end != segment.loop_end) return false;
        if (!group.handle.eql(handle) or group.state != .playing or group.generation != generation.runtime_generation or
            group.segment != segment.key.id or group.layer_count != 4 or group.source_incarnation != 1 or group.paused or group.degraded or
            group.ramp_remaining != 0 or group.gain_current != group.prepared.gain or !std.meta.eql(group.loop, group.prepared.loop) or
            group.prepared.policy_managed or group.prepared.emergency != null or group.prepared.voice_count != 4 or
            group.prepared.ramp_frames != 0 or group.prepared.start_cursor != 0 or group.prepared.start_loop_epoch != 0 or
            generation.groupWindowCount(handle) != 4) return false;
        for (group.layers[0..4], generation.loaded.tables.layers[segment.layers.first..][0..4]) |layer, authored| {
            const sound = generation.loaded.tables.sounds[authored.sound];
            const source = layer.stream() orelse return false;
            if (sound.storage != .streaming or authored.required != 1 or layer.state != .real or !layer.prepared.required or layer.prepared.initial_state != .real or
                layer.automation != null or layer.ramp_remaining != 0 or layer.release_remaining != 0 or layer.source_override != null or layer.continuity_source != null or
                layer.gain_current != layer.prepared.gain or layer.prepared.gain != std.math.pow(f32, 10, authored.gain_db / 20) or
                layer.prepared.authored.layer_id != authored.key.id or layer.prepared.asset_frame_origin != authored.source_start or
                !source.validate() or source.identity.asset != sound.key.id or source.identity.asset_generation != generation.runtime_generation or
                source.identity.transport_epoch != generation.transport.transport_epoch or source.identity.start_cursor != authored.source_start or source.identity.start_loop_epoch != 0) return false;
            var matched = false;
            for (generation.windows) |entry| if (entry) |window| {
                if (window.group == null or !window.group.?.eql(handle) or window.binding.layer != authored.key.id) continue;
                if (matched or window.retiring or window.binding.sound != sound.key.id or window.binding.segment != segment.key.id) return false;
                const owned = service.renderSource(window.binding.handle) catch return false;
                if (!std.meta.eql(owned, source)) return false;
                matched = true;
            };
            if (!matched) return false;
        }
        return true;
    }
    fn deviceRecoveryActive(self: *const MusicRuntime) bool {
        return self.device_event != null or switch (self.device_status.stage) {
            .queued, .draining, .policy_required, .scheduled => true,
            else => false,
        };
    }
    fn progressDeviceRecovery(self: *MusicRuntime, live: ?*LiveTickAttempt) !void {
        if (self.device_recovery_state == null) return;
        if (self.device_recovery_state.?.stream_restart_compatible or self.device_stream_candidate != null) {
            try self.progressStreamDeviceRecovery(live);
            return;
        }
        self.collectReload();
        try self.collectDeviceRecovery();
        if (!self.deviceRecoveryActive() or self.device_status.stage == .scheduled) return;
        for (0..self.config_v1.capacity.music_request_drain) |_| {
            const item = self.ingress.pop() orelse break;
            self.rejectItemV1(item, .cancelled);
            if (item.command == .reload) if (self.live_reload) |state| {
                state.accepted = true;
                state.terminal_emitted = true;
                state.result = .{ .failed = .cancelled };
            };
            if (item.command == .restore) if (self.resident_state) |state| {
                state.accepted = true;
                state.terminal_emitted = true;
                state.terminal = true;
                state.failure = .cancelled;
            };
        }
        self.queue_count = 0;
        try self.discardFillContinuation();
        try self.abandonPreparing();
        try self.abandonResume();
        self.requestPolicyStop();
        if (self.generation != null) try self.collect();
        if (self.pending != null or self.preview_seek != null) return;
        if (self.live_reload) |state| if (state.lower != null or self.reload.ownsResources()) return;
        if (self.resident_state) |state| if (state.lower != null and !state.terminal) return;
        if (self.active_group) |handle| {
            const terminal = if (self.tick_scope) |scope| try scope.musicGroupTerminal(handle) else try self.control.musicGroupTerminal(handle);
            if (terminal == null) return error.InvalidState;
            try self.retireResidentGroup(handle);
            self.active_group = null;
            self.confirmed_fill = null;
            self.active_source_incarnation = 0;
            self.rendering_segment = 0;
        }
        if (self.in_flight) |ticket| if (!self.policyStopOwnsV1(ticket) and !self.layerTicketOwnsV1(ticket)) self.finishTicketV1(ticket, .{ .rejected = .cancelled });
        if (self.interruption) |value| if (!self.policyStopOwnsV1(value.ticket)) self.finishTicketV1(value.ticket, .{ .rejected = .cancelled });
        if (self.generation != null) try self.collect();
        self.state = .ready;
        if (self.shutdown_requested.load(.acquire) or self.unloading or self.generation == null or !self.has_executed or self.device_recovery_state.?.physical == null) {
            self.device_recovery_state.?.source_pending = false;
            self.device_status.stage = .stopped;
            if (!self.shutdown_requested.load(.acquire) and !self.unloading and self.generation != null) self.admission_handle.store(self.handle_incarnation, .release);
            return;
        }
        if (self.device_status.stage == .policy_required) return;
        const recovery = &self.device_recovery_state.?;
        if (!recovery.compatible) {
            recovery.source_pending = false;
            self.device_status.stage = .policy_required;
            self.device_status.failure = .unsupported_profile;
            return;
        }
        if (recovery.loss.policy == .resume_phase and (recovery.physical == null or recovery.physical.?.source_incarnation != 1 or recovery.physical.?.segment != self.generation.?.loaded.tables.segments[recovery.segment].key.id)) {
            recovery.source_pending = false;
            self.device_status.stage = .policy_required;
            self.device_status.failure = .unavailable_phase;
            return;
        }
        try self.prepareDeviceRecovery();
    }
    fn prepareDeviceRecovery(self: *MusicRuntime) !void {
        const recovery = &self.device_recovery_state.?;
        const generation = self.generation.?;
        if (generation.runtime_generation != recovery.generation) return error.InvalidState;
        const segment = generation.loaded.tables.segments[recovery.segment];
        var source = recovery.clock.?;
        // A paused source has a real saved elapsed coordinate. Restart selects
        // the next legal bar from that position, never elapsed wall time.
        source.anchor_elapsed = try source.elapsedAt(recovery.loss.render_frame);
        source.anchor_render = recovery.loss.render_frame;
        source.paused = false;
        const frontier = try self.planningFrontier();
        const frame = if (recovery.loss.policy == .restart_at_bar) (try source.strictNext(.bar, self.control_frame, .{ .earliest_submit_frame = frontier })).frame else frontier;
        const cursor = if (recovery.loss.policy == .resume_phase) recovery.physical.?.cursor else 0;
        const loop_epoch = if (recovery.loss.policy == .resume_phase) recovery.physical.?.loop_epoch else 0;
        var transport = clock.Clock.init(generation.solver.?.maps[segment.tempo], frame);
        transport.anchor_elapsed = try self.residentElapsed(segment.key.id, cursor, loop_epoch);
        transport.transport_epoch = generation.transport.transport_epoch;
        transport.device_epoch = self.device_status.device_epoch;
        const logical_frame = if (recovery.loss.policy == .restart_at_bar) frame else recovery.loss.render_frame;
        const logical_bar = try std.math.add(u64, recovery.source_bar_offset, try director.Director.barAtClock(source, logical_frame));
        const physical_bar = try director.Director.barAtClock(transport, frame);
        if (physical_bar > logical_bar) return error.InvalidState;
        const end = try std.math.add(u64, frame, 1);
        const id = try self.takePlan();
        try generation.retainPending();
        errdefer generation.releasePending();
        const group = try self.prepareGroupFor(generation, recovery.segment, cursor, loop_epoch, id);
        // Every rollback below is unpublished and Control-local: no queue or
        // Render pin can own these reservations until submitSchedule succeeds.
        errdefer self.releaseMusicGroup(group) catch unreachable;
        const token: api.PhaseToken = .{ .context = @enumFromInt(self.config.context), .asset_generation = @enumFromInt(generation.runtime_generation), .transport_epoch = @enumFromInt(generation.transport.transport_epoch), .plan_id = @enumFromInt(id), .plan_epoch = @enumFromInt(1), .phase_id = @enumFromInt(1) };
        const command: rt.ScheduledCommand = .{ .identity = .{ .command_id = 1, .token = token, .phase_order = 0, .execute_frame = frame, .group_id = id }, .payload = .{ .group_start = .{ .group = group } } };
        const block = try self.prepareSchedule(frame, end, &.{command});
        errdefer {
            _ = self.cancelSchedule(.{ .target = block, .requested_frame = self.control_frame }) catch unreachable;
            self.releaseSchedule(block) catch unreachable;
        }
        const plan = try self.schedulePlan(block);
        try self.submitSchedule(block);
        recovery.group = group;
        recovery.block = block;
        recovery.plan = plan;
        recovery.token = token;
        recovery.transport = transport;
        recovery.generation_owner = generation;
        recovery.restart_logical_bar = logical_bar;
        recovery.restart_bar_offset = logical_bar - physical_bar;
        self.device_status.stage = .scheduled;
        self.device_status.restart_frame = frame;
        self.state = .starting;
    }
    fn streamRecoveryFailure(err: anyerror) device_recovery.PreparationFailure {
        return switch (err) {
            error.ResourceLimitExceeded, error.StreamCapacity, error.JobCapacity, error.CapacityExceeded, error.CommandQueueFull, error.VoiceBudgetExceeded, error.InstanceCapacity, error.OutOfMemory, error.RingFull, error.CapacityOverflow => .capacity,
            error.SourceReadFailed, error.SourceUnavailable, error.TruncatedContainer, error.HashMismatch => .source_read,
            error.Overflow, error.OutOfRange, error.LateCommand => .clock_range,
            error.DeviceWindowIdentityExhausted, error.DevicePlanIdentityExhausted => .identity_exhausted,
            else => .invalid_state,
        };
    }
    fn failStreamDeviceRecovery(self: *MusicRuntime, err: anyerror) void {
        if (@import("builtin").is_test and self.device_status.preparation_failure == null) {
            std.debug.print("stream device recovery first preparation error: {s}\n", .{@errorName(err)});
            if (@errorReturnTrace()) |error_trace| std.debug.dumpErrorReturnTrace(error_trace);
        }
        if (self.device_status.preparation_failure == null) self.device_status.preparation_failure = streamRecoveryFailure(err);
        self.device_status.failure = .invalid_state;
        self.device_status.stage = .draining;
        self.last_error = failureV1(err);
        if (self.device_stream_candidate) |*candidate| {
            candidate.stage = .retiring;
            candidate.cancel_requested = true;
            candidate.generation.retireRequestWindowsScoped(.device_recovery, candidate.window_id);
        } else self.device_status.stage = .policy_required;
    }
    fn progressStreamDeviceRecovery(self: *MusicRuntime, live: ?*LiveTickAttempt) !void {
        const recovery = &self.device_recovery_state.?;
        if (self.shutdown_requested.load(.acquire) or self.unloading) {
            recovery.source_pending = false;
            if (self.device_stream_candidate) |*candidate| {
                candidate.stage = .retiring;
                candidate.cancel_requested = true;
                candidate.generation.retireRequestWindowsScoped(.device_recovery, candidate.window_id);
            }
        }
        try self.collectStreamDeviceRecovery();
        if (self.device_stream_candidate) |*candidate| {
            if (candidate.stage == .retiring) {
                if (candidate.block) |block| {
                    if (candidate.invalidation == null and try self.scheduleResult(block) == null) {
                        candidate.invalidation = self.cancelSchedule(.{ .target = block, .requested_frame = self.control_frame }) catch |err| {
                            if (err == error.CommandQueueFull or err == error.CapacityExceeded) return;
                            self.failStreamDeviceRecovery(err);
                            return;
                        };
                    }
                }
                // A supply failure may lose the race with real execution. The
                // committed group then needs its own exact lifecycle stop.
                if (candidate.committed and self.active_group != null and self.pending == null and !self.shutdown_requested.load(.acquire)) {
                    const group = self.active_group.?;
                    if (candidate.drain_group != null and candidate.drain_group.?.eql(group)) {
                        const terminal = try self.tick_scope.?.musicGroupTerminal(group);
                        if (terminal == null) {
                            self.scheduleOperation(.stop, null, null, null) catch |err| {
                                self.failStreamDeviceRecovery(err);
                                return;
                            };
                            candidate.cleanup_stop = self.pending.?.block;
                            self.cleanup_stop_pending = true;
                        } else {
                            try self.retireResidentGroup(group);
                            self.active_group = null;
                            self.active_source_incarnation = 0;
                            self.rendering_segment = 0;
                        }
                    }
                }
                return;
            }
            if (candidate.stage == .scheduled) {
                if (!candidate.committed) self.prefetchStreamDeviceRecovery(candidate.generation, candidate.window_id, live) catch |err| {
                    if (err == error.LiveStreamAvailabilityDeferred and live != null and live.?.deferred != null) return err;
                    self.failStreamDeviceRecovery(err);
                };
                return;
            }
        }
        if (!self.deviceRecoveryActive()) return;
        for (0..self.config_v1.capacity.music_request_drain) |_| {
            const item = self.ingress.pop() orelse break;
            self.rejectItemV1(item, .cancelled);
        }
        self.queue_count = 0;
        try self.discardFillContinuation();
        try self.abandonPreparing();
        try self.abandonResume();
        if (self.generation != null) try self.collect();
        if (self.pending != null) return;
        if (self.active_group) |group| {
            if (try self.tick_scope.?.musicGroupTerminal(group) == null) return;
            try self.retireResidentGroup(group);
            self.active_group = null;
            self.active_source_incarnation = 0;
            self.rendering_segment = 0;
        }
        if (self.generation != null) try self.collect();
        if (self.shutdown_requested.load(.acquire) or self.unloading or self.generation == null or !recovery.source_pending or recovery.physical == null) {
            if (self.device_stream_candidate == null) self.device_status.stage = .stopped;
            return;
        }
        if (self.device_status.stage == .policy_required) return;
        if (!recovery.stream_restart_compatible or recovery.loss.policy != .restart_at_bar) {
            self.device_status.stage = .policy_required;
            self.device_status.failure = .unsupported_profile;
            return;
        }
        if (self.device_stream_candidate == null) {
            if (self.device_status.preparation_failure != null) {
                self.device_status.stage = .policy_required;
                return;
            }
            const generation = self.generation.?;
            // Keep the previous source's four windows, but never allocate a
            // third set while any older source still has actual custody.
            for (generation.windows) |entry| if (entry) |window| {
                if (window.group == null or !window.group.?.eql(recovery.physical.?.group)) return;
            };
            if (generation.windowCount() > 4) return;
            const origin = self.device_stream_origin orelse {
                self.failStreamDeviceRecovery(error.InvalidState);
                return;
            };
            if (origin.generation != generation.runtime_generation or !origin.group.eql(recovery.physical.?.group)) {
                self.failStreamDeviceRecovery(error.InvalidState);
                return;
            }
            const id = self.next_device_window_id;
            self.next_device_window_id = std.math.add(u64, id, 1) catch {
                self.failStreamDeviceRecovery(error.DeviceWindowIdentityExhausted);
                return;
            };
            generation.retainPreparation() catch |err| {
                self.failStreamDeviceRecovery(if (err == error.Overflow) error.ResourceLimitExceeded else err);
                return;
            };
            self.device_stream_candidate = .{ .window_id = id, .generation = generation, .origin = origin, .device_epoch = self.device_status.device_epoch };
        }
        self.prepareStreamDeviceRecovery(live) catch |err| {
            // Only this attempt's typed observation can unwind without failing
            // the candidate. Unknown errors retain the original failure path.
            if (err == error.LiveStreamAvailabilityDeferred and live != null and live.?.deferred != null) return err;
            self.failStreamDeviceRecovery(err);
        };
    }
    fn prefetchStreamDeviceRecovery(self: *MusicRuntime, generation: *Generation, window_id: u64, live: ?*LiveTickAttempt) !void {
        self.tickHook(.before_recovery_supply);
        if (live) |attempt| {
            if (try generation.prefetchRequestWindowsScopedLiveV1(.device_recovery, window_id, self.control_frame)) |observation|
                return self.deferLiveTick(attempt, .recovery_supply, observation);
        } else try generation.prefetchRequestWindowsScoped(.device_recovery, window_id, self.control_frame);
    }
    fn prepareStreamDeviceRecovery(self: *MusicRuntime, live: ?*LiveTickAttempt) !void {
        const recovery = &self.device_recovery_state.?;
        const candidate = &self.device_stream_candidate.?;
        const generation = candidate.generation;
        if (generation != self.generation.? or generation.runtime_generation != recovery.generation or candidate.device_epoch != self.device_status.device_epoch) return error.InvalidState;
        const scope = self.tick_scope orelse return error.InvalidMode;
        if (!candidate.windows_opened) {
            try generation.prepareRestoreWindowsScoped(.device_recovery, candidate.window_id, recovery.segment, 0, 0, generation.transport.transport_epoch, try self.planningFrontier());
            candidate.windows_opened = true;
        }
        try self.prefetchStreamDeviceRecovery(generation, candidate.window_id, live);
        const readiness = generation.readiness.?;
        self.tickHook(.before_recovery_readiness);
        defer self.tickHook(.after_recovery_readiness);
        const bindings = generation.requestBindingsScoped(.device_recovery, candidate.window_id);
        if (live) |attempt| {
            if (try readiness.collectTickLiveV1(scope, bindings, self.config.context, generation.director.?.request_epoch)) |observation|
                return self.deferLiveTick(attempt, .recovery_readiness, observation);
        } else try readiness.collectTick(scope, bindings, self.config.context, generation.director.?.request_epoch);
        if (!try generation.restoreWindowsReadyScoped(.device_recovery, candidate.window_id, .{ .segment_index = recovery.segment, .cursor = 0, .loop_epoch = 0 }, &.{}, generation.transport.transport_epoch, readiness)) return;
        candidate.stage = .ready;
        // The preparation deadline is not publication authority. Select again
        // after every stem has crossed its actual Render visibility gate.
        var source = recovery.clock.?;
        source.anchor_elapsed = try source.elapsedAt(recovery.loss.render_frame);
        source.anchor_render = recovery.loss.render_frame;
        source.paused = false;
        const frame = (try source.strictNext(.bar, self.control_frame, .{ .earliest_submit_frame = try self.planningFrontier() })).frame;
        const segment = generation.loaded.tables.segments[recovery.segment];
        candidate.transport = clock.Clock.init(generation.solver.?.maps[segment.tempo], frame);
        candidate.transport.transport_epoch = generation.transport.transport_epoch;
        candidate.transport.device_epoch = candidate.device_epoch;
        candidate.logical_bar = try std.math.add(u64, recovery.source_bar_offset, try director.Director.barAtClock(source, frame));
        const physical_bar = try director.Director.barAtClock(candidate.transport, frame);
        if (physical_bar > candidate.logical_bar) return error.InvalidState;
        candidate.bar_offset = candidate.logical_bar - physical_bar;
        const end = try std.math.add(u64, frame, 1);
        const id = self.takePlan() catch |err| return if (err == error.Overflow) error.DevicePlanIdentityExhausted else err;
        candidate.group = try self.prepareGroupForEntryRampScoped(generation, recovery.segment, 0, 0, .device_recovery, candidate.window_id, null, 0);
        generation.bindRequestWindowsScoped(.device_recovery, candidate.window_id, candidate.group.?);
        candidate.token = .{ .context = @enumFromInt(self.config.context), .asset_generation = @enumFromInt(generation.runtime_generation), .transport_epoch = @enumFromInt(generation.transport.transport_epoch), .plan_id = @enumFromInt(id), .plan_epoch = @enumFromInt(1), .phase_id = @enumFromInt(1) };
        const command: rt.ScheduledCommand = .{ .identity = .{ .command_id = 1, .token = candidate.token, .phase_order = 0, .execute_frame = frame, .group_id = id }, .payload = .{ .group_start = .{ .group = candidate.group.? } } };
        candidate.block = try self.prepareSchedule(frame, end, &.{command});
        candidate.plan = try self.schedulePlan(candidate.block.?);
        generation.retainPending() catch |err| return if (err == error.Overflow) error.ResourceLimitExceeded else err;
        candidate.pending_lease = true;
        try self.submitSchedule(candidate.block.?);
        candidate.published = true;
        candidate.stage = .scheduled;
        generation.releasePreparation();
        candidate.preparation_lease = false;
        self.device_status.stage = .scheduled;
        self.device_status.restart_frame = frame;
        self.state = .starting;
    }
    fn collectStreamDeviceRecovery(self: *MusicRuntime) !void {
        const candidate = if (self.device_stream_candidate) |*value| value else return;
        const generation = candidate.generation;
        if (self.shutdown_requested.load(.acquire)) {
            candidate.stage = .retiring;
            candidate.cancel_requested = true;
            generation.retireRequestWindowsScoped(.device_recovery, candidate.window_id);
        }
        if (candidate.invalidation) |handle| if (try self.cancellationResult(handle)) |result| {
            candidate.invalidation = null;
            self.input(.{ .position = self.position(), .payload = .{ .admission = result.admission } });
            self.observe(.{ .event = result.receipt });
        };
        if (candidate.block) |block| {
            const terminal = try self.scheduleResult(block);
            if (!candidate.admission_seen) if (try self.scheduleAdmission(block)) |admission| {
                candidate.admission_seen = true;
                self.input(.{ .position = self.position(), .payload = .{ .admission = admission } });
            };
            while (try self.pollExecutionReceipt(block, &candidate.receipt_cursor)) |record| self.observe(.{ .event = record });
            if (candidate.plan) |plan| while (try self.pollPlanPhase(plan, &candidate.phase_cursor)) |phase| {
                if (!std.meta.eql(phase.token, candidate.token) or phase.outcome != .executed or candidate.committed) return error.InvalidState;
                const group = candidate.group orelse return error.InvalidState;
                generation.bindExecutedRequestWindowsScoped(.device_recovery, candidate.window_id, group);
                // Only the exact admitted initial lineage can transfer to this
                // genuinely executed replacement; readiness is not provenance.
                if (self.device_stream_origin) |origin| {
                    self.device_stream_origin = if (std.meta.eql(origin, candidate.origin))
                        .{ .generation = generation.runtime_generation, .group = group }
                    else
                        null;
                }
                self.active_group = group;
                candidate.group = null;
                candidate.committed = true;
                self.active_source_incarnation = 1;
                self.rendering_segment = generation.loaded.tables.segments[self.device_recovery_state.?.segment].key.id;
                generation.transport = candidate.transport;
                generation.director.?.paused = false;
                self.bar_offset = candidate.bar_offset;
                try generation.director.?.advance(phase.effective_frame, candidate.logical_bar);
                self.has_executed = true;
                self.device_recovery_state.?.source_pending = false;
                self.device_status.phase = phase;
                if (candidate.stage == .retiring) {
                    candidate.drain_group = group;
                } else {
                    self.state = .playing;
                    self.device_status.stage = .recovered;
                    self.admission_handle.store(self.handle_incarnation, .release);
                }
            };
            if (terminal == null or candidate.invalidation != null) return;
            // The loss fence can terminalize a queued block before Control
            // consumes its ingress reference. Collection must return normally
            // so this tick reaches that actual drain, rather than repeatedly
            // failing releaseSchedule before acceptance. Validate the complete
            // block handle; only these explicit custody counts mean pending.
            const slot = try self.control.scheduled.getObserved(block, null);
            if (slot.state.load(.acquire) != .terminal) return error.InvalidState;
            if (slot.queue_refs != 0 or slot.invalidation_refs != 0) return;
            if (!candidate.committed) {
                candidate.stage = .retiring;
                generation.retireRequestWindowsScoped(.device_recovery, candidate.window_id);
                if (!candidate.cancel_requested and self.device_status.preparation_failure == null) self.failStreamDeviceRecovery(error.InvalidState);
            }
            if (candidate.stage == .retiring and !candidate.preparation_lease) {
                generation.retainPreparation() catch |err| return if (err == error.Overflow) error.ResourceLimitExceeded else err;
                candidate.preparation_lease = true;
            }
            try self.releaseSchedule(block);
            candidate.block = null;
            candidate.plan = null;
            if (candidate.pending_lease) {
                generation.releasePending();
                candidate.pending_lease = false;
            }
        }
        if (candidate.committed and candidate.stage != .retiring) {
            std.debug.assert(!candidate.preparation_lease and !candidate.pending_lease);
            self.device_stream_candidate = null;
            return;
        }
        if (candidate.stage != .retiring or candidate.invalidation != null) return;
        if (candidate.cleanup_stop) |block| {
            if (self.pending) |pending| {
                if (!std.meta.eql(pending.block, block) or pending.operation != .stop or pending.request_ticket != null or pending.generation != generation) return error.InvalidState;
                return;
            }
            // The ordinary collector clears Pending only after real schedule
            // release and its pending-generation credit have both settled.
            candidate.cleanup_stop = null;
        }
        generation.retireRequestWindowsScoped(.device_recovery, candidate.window_id);
        if (candidate.group) |group| {
            try self.retireResidentGroup(group);
            candidate.drain_group = group;
            candidate.group = null;
        }
        if (candidate.drain_group) |group| {
            if (self.active_group) |active| if (active.eql(group)) return;
            for (self.retired_groups) |entry| if (entry) |retired| if (retired.eql(group)) return;
            if (generation.groupWindowCount(group) != 0) return;
        }
        try generation.collectWindows();
        if (generation.requestWindowCountScoped(.device_recovery, candidate.window_id) != 0) return;
        if (candidate.pending_lease) {
            generation.releasePending();
            candidate.pending_lease = false;
        }
        if (candidate.preparation_lease) generation.releasePreparation();
        self.device_stream_candidate = null;
        if (self.shutdown_requested.load(.acquire) or self.unloading or !self.device_recovery_state.?.source_pending) {
            self.device_status.stage = .stopped;
        } else if (self.device_status.preparation_failure != null) self.device_status.stage = .policy_required;
    }
    fn collectDeviceRecovery(self: *MusicRuntime) !void {
        try self.collectStreamDeviceRecovery();
        const recovery = if (self.device_recovery_state) |*value| value else return;
        const block = recovery.block orelse return;
        if (!recovery.admission_seen) if (try self.scheduleAdmission(block)) |admission| {
            self.input(.{ .position = self.position(), .payload = .{ .admission = admission } });
            recovery.admission_seen = true;
        };
        while (try self.pollExecutionReceipt(block, &recovery.receipt_cursor)) |record| self.observe(.{ .event = record });
        while (try self.pollPlanPhase(recovery.plan.?, &recovery.phase_cursor)) |phase| {
            if (!std.meta.eql(phase.token, recovery.token)) return error.InvalidState;
            self.active_group = recovery.group;
            recovery.group = null;
            self.active_source_incarnation = 1;
            self.rendering_segment = self.generation.?.loaded.tables.segments[recovery.segment].key.id;
            self.generation.?.transport = recovery.transport.?;
            self.generation.?.director.?.paused = false;
            self.bar_offset = recovery.restart_bar_offset;
            try self.generation.?.director.?.advance(phase.effective_frame, recovery.restart_logical_bar);
            self.state = .playing;
            recovery.source_pending = false;
            self.device_status.stage = .recovered;
            self.device_status.phase = phase;
            self.admission_handle.store(self.handle_incarnation, .release);
        }
        const terminal = (try self.scheduleResult(block)) orelse return;
        if (terminal.disposition == .cancelled or terminal.disposition == .superseded_after_partial) {
            if (recovery.group) |group| {
                try self.retireResidentGroup(group);
                recovery.group = null;
            }
            recovery.source_pending = false;
            self.device_status.stage = .stopped;
            self.device_status.failure = .cancelled;
        }
        try self.releaseSchedule(block);
        recovery.block = null;
        recovery.plan = null;
        recovery.generation_owner.?.releasePending();
        recovery.generation_owner = null;
    }
    pub fn controlTickV1(self: *MusicRuntime, limit: usize) !usize {
        try self.checkControlV1();
        if (self.live_semantic_service_hooks != null) return error.InvalidMode;
        if (self.live_chronology_frontier != null) return error.InvalidMode;
        if (!self.usesIntegratedTickV1()) return error.InvalidMode;
        try self.claimControlV1();
        defer {
            self.tick_scope = null;
            self.tick_entry = .idle;
            self.control_guard.store(false, .release);
        }
        return self.control.withMusicTickV1(self, limit);
    }
    /// Explicit live-authoring driver. Existing controlTickV1 and recording
    /// entry points retain their original errors and publication contract.
    pub fn controlTickLiveV1(self: *MusicRuntime, limit: usize) !LiveControlTickOutcomeV1 {
        if (self.live_semantic_service_hooks != null) return error.InvalidMode;
        return self.controlTickLiveModeV1(limit, false, null);
    }
    /// Recorder-independent chronology used by ordinary authoring Host ticks.
    /// A non-null sink observes acceptance only; it does not provide full replay.
    pub fn controlTickLiveChronologyV1(self: *MusicRuntime, limit: usize, sink: ?rt.ControlRuntime.LiveAcceptanceSinkV1) !LiveControlTickOutcomeV1 {
        if (self.live_semantic_service_hooks != null) return error.InvalidMode;
        return self.controlTickLiveModeV1(limit, true, sink);
    }
    /// Never-started semantic owner cleanup. This retains the original initial
    /// cleanup driver and may not be used after a chronology frontier exists.
    pub fn controlTickSemanticInitialCleanupV1(self: *MusicRuntime, limit: usize) !LiveControlTickOutcomeV1 {
        try self.checkControlV1();
        if (self.live_semantic_service_hooks == null or self.live_chronology_frontier != null or
            !self.shutdown_requested.load(.acquire) or !self.usesIntegratedTickV1()) return error.InvalidMode;
        try self.claimControlV1();
        defer {
            self.tick_scope = null;
            self.tick_entry = .idle;
            self.control_guard.store(false, .release);
        }
        return .{ .drained = try self.control.withMusicTickV1(self, limit), .deferred = null };
    }
    /// Explicit semantic profile dispatch; uses real multi-cut acceptance and
    /// original planner/readiness code, not legacy expected-outcome replay.
    pub fn controlTickLiveSemanticV1(self: *MusicRuntime, limit: usize, sink: ?rt.ControlRuntime.LiveAcceptanceSinkV1) !LiveControlTickOutcomeV1 {
        const hooks = self.live_semantic_service_hooks orelse return error.InvalidMode;
        const control = self.control.live_semantic_hooks orelse return error.InvalidMode;
        const render = self.renderer.live_semantic_hooks orelse return error.InvalidMode;
        if (!rt.live_semantic.Binding.same(hooks.cuts, control) or !rt.live_semantic.Binding.same(hooks.cuts, render)) return error.InvalidMode;
        return self.controlTickLiveModeV1(limit, true, sink);
    }
    fn controlTickLiveModeV1(self: *MusicRuntime, limit: usize, comptime chronology: bool, sink: ?rt.ControlRuntime.LiveAcceptanceSinkV1) !LiveControlTickOutcomeV1 {
        try self.checkControlV1();
        if (!chronology and self.live_chronology_frontier != null) return error.InvalidMode;
        if (!self.usesIntegratedTickV1()) return error.InvalidMode;
        try self.claimControlV1();
        defer {
            self.tick_scope = null;
            self.tick_entry = .idle;
            self.control_guard.store(false, .release);
        }
        const cleanup = chronology and (self.shutdown_requested.load(.acquire) or self.unloading);
        if (cleanup) try self.validateChronologyCleanupV1() else try self.validateLiveTickModeV1();
        const before = self.control.stream_control_tick;
        defer if (self.control.stream_control_tick != before) {
            self.live_tick_control_stamp = self.control.stream_control_tick;
        };
        if (cleanup) return self.control.withMusicTickChronologyCleanupV1(self, limit, sink);
        if (chronology) return self.control.withMusicTickLiveChronologyV1(self, limit, sink);
        return self.control.withMusicTickLiveV1(self, limit);
    }
    /// Only an already admitted new-mode owner can enter this cleanup path.
    /// This is not permission to free live resources: original drain/join and
    /// destroy checks still apply. The old recorder/witness profiles stay out.
    pub fn validateChronologyCleanupV1(self: *const MusicRuntime) !void {
        return self.validateChronologyCleanupOwnedV1(false);
    }
    fn validateChronologyCleanupOwnedV1(self: *const MusicRuntime, comptime joined: bool) !void {
        return self.validateChronologyCleanupProfileV1(joined, false);
    }
    fn validateChronologyCleanupProfileV1(self: *const MusicRuntime, comptime joined: bool, comptime host: bool) !void {
        if (@import("builtin").is_test) if (!host and (self.renderer.test_render_admission_hook != null or self.renderer.test_owned_render_facts != null or self.control.test_owned_control_facts != null)) return error.InvalidMode;
        if (self.live_chronology_frontier == null or
            (!self.shutdown_requested.load(.acquire) and !self.unloading) or
            self.live_tick_control_stamp == null or self.live_tick_control_stamp.? != self.control.stream_control_tick or
            !self.usesIntegratedTickV1() or self.config_v1.kind != .authoring or
            self.public_recording.phase != .disabled or self.causal_sink != null or self.causal_driver_pin != null or
            self.control.control_frontier_binding != null or self.control.stream_acceptance_binding != null or
            self.control.readiness_binding != null or self.control.offline_causal_replay != null or
            (!host and self.control.prerequisite_order != null) or self.renderer.render_causal_binding != null)
            return error.InvalidMode;
        if (self.owned_streaming) |service| if (service.replay_mode or service.readiness_attached or
            (!host and (service.readiness_supply_sink != null or service.readiness_lifecycle_sink != null or service.public_causal_worker_sink != null)) or
            service.public_causal_consumed_sink != null or
            service.offline_causal_replay != null or (!joined and service.prerequisite_order != null)) return error.InvalidMode;
    }
    /// Admission for a loaded authoring stream. Stop/loss/shutdown cleanup
    /// keeps its ordinary guarded driver after real callback quiescence.
    fn liveInitialEntryV1(self: *const MusicRuntime) bool {
        const generation = self.generation orelse return false;
        const logical = generation.director orelse return false;
        return self.state == .ready and !self.has_executed and self.active_group == null and
            self.pending == null and self.preparing == null and self.in_flight == null and
            self.interruption == null and self.action == null and self.queue_count == 0 and
            logical.last_request_id == 0 and logical.desired == null;
    }
    pub fn validateLiveTickModeV1(self: *const MusicRuntime) !void {
        return self.validateLiveTickModeOwnedV1(false);
    }
    fn validateLiveTickModeOwnedV1(self: *const MusicRuntime, comptime joined: bool) !void {
        return self.validateLiveTickModeProfileV1(joined, false);
    }
    fn validateLiveTickModeProfileV1(self: *const MusicRuntime, comptime joined: bool, comptime host: bool) !void {
        if (self.live_tick_control_stamp) |stamp| {
            if (stamp != self.control.stream_control_tick) return error.InvalidMode;
        } else if (!self.liveInitialEntryV1()) return error.InvalidMode;
        return self.validateLiveTickProfileStateV1(joined, host);
    }
    /// Entry stamps describe the last returned tick, not an in-progress tick.
    /// Reuse every profile/state restriction inside an already-validated Tick
    /// without pretending its new stream_control_tick has returned yet.
    fn validateLiveTickProfileStateV1(self: *const MusicRuntime, comptime joined: bool, comptime host: bool) !void {
        if (@import("builtin").is_test) if (!host and (self.renderer.test_render_admission_hook != null or self.renderer.test_owned_render_facts != null or self.control.test_owned_control_facts != null)) return error.InvalidMode;
        if (!self.usesIntegratedTickV1() or self.config_v1.kind != .authoring or
            self.public_recording.phase != .disabled or self.causal_sink != null or self.causal_driver_pin != null or
            self.control.control_frontier_binding != null or self.control.stream_acceptance_binding != null or
            self.control.readiness_binding != null or self.control.offline_causal_replay != null or
            (!host and self.control.prerequisite_order != null) or self.renderer.render_causal_binding != null or
            self.config_v1.policy_support != .disabled or self.config_v1.crossfade.bindings.len != 0 or
            self.config_v1.layer_gain.bindings.len != 0 or self.config_v1.preview_seek != null or self.config_v1.boundary_stop != null or
            self.config_v1.snapshot_profile != .resident_v1 or self.config_v1.sfx_generation_custody != .untracked or
            self.config_v1.streaming_reservation != .initial_bank_only or self.config_v1.streamed_fill_mode != .full_span or
            self.resident_state != null or self.live_reload != null or self.reload.ownsResources() or self.preview_seek != null or
            self.event_adapter != null or self.control.source_continuity_manager != null or self.fill_continuation != null or self.confirmed_fill != null or
            self.state == .paused or self.resuming_request != null or self.crossfade_outgoing != null or self.active_source_incarnation > 1 or
            self.layer_in_flight != null or self.action_boundary_stop != null or self.outgoing_generation.load(.acquire) != null or
            self.shutdown_requested.load(.acquire) or self.unloading)
            return error.InvalidMode;
        const generation = self.generation orelse return error.InvalidMode;
        if (generation.loaded.bus_graph != null or generation.layer_owner != null) return error.InvalidMode;
        if (self.action) |action| if (action != .stop) return error.InvalidMode;
        if (self.pending) |pending| if ((pending.operation != .transition and pending.operation != .stop) or pending.boundary_stop != null or pending.source_fill != null or pending.continuity != null) return error.InvalidMode;
        if (self.live_tick_control_stamp == null) {
            // Inert legacy fill labels are legal; actual fill/fallback/overlap
            // routes and non-streamed or non-fixed entry sources are not.
            const tables = generation.loaded.tables;
            for (tables.fills) |fill| if (fill.steps.count != 0) return error.InvalidMode;
            for (tables.transitions) |transition| if (transition.fill != s.none or transition.condition != s.none or transition.fade_ticks != 0 or transition.overlap_frames != 0 or transition.fallback != .reject or transition.fallback_segment != s.none) return error.InvalidMode;
            for (tables.transition_paths) |path| if (path.fill != s.none or path.handoff != .hard_cut) return error.InvalidMode;
            for (tables.segments) |segment| if (segment.storage != .streaming or segment.emergency != 0 or segment.fallback_segment != s.none or segment.layers.count != 4) return error.InvalidMode;
            for (tables.selectors) |selector| if (selector.kind != .fixed or selector.candidates.count != 1 or selector.fallback_segment != s.none) return error.InvalidMode;
            for (tables.candidates) |candidate| if (candidate.condition != s.none) return error.InvalidMode;
        }
        const service = self.owned_streaming orelse return error.InvalidMode;
        if (generation.service != service or service.replay_mode or service.readiness_attached or
            (!host and (service.readiness_supply_sink != null or service.readiness_lifecycle_sink != null or service.public_causal_worker_sink != null)) or
            service.public_causal_consumed_sink != null or service.offline_causal_replay != null or (!joined and service.prerequisite_order != null))
            return error.InvalidMode;
    }
    /// Checked internal seam; the public driver above owns the guard lifetime.
    pub fn validateControlTickV1(self: *MusicRuntime, control: *rt.ControlRuntime) !void {
        try self.checkControlV1();
        if (self.public_recording.phase == .active and !self.public_recording.driving) {
            self.failRecordingV1();
            return error.InvalidMode;
        }
        if (!self.usesIntegratedTickV1() or control != self.control or !self.control_guard.load(.acquire) or self.tick_scope != null or self.tick_entry != .idle) return error.InvalidState;
    }
    pub fn collectControlTickV1(self: *MusicRuntime, scope: rt.ControlRuntime.TickV1) !void {
        try scope.requirePhase(.collect);
        if (scope.runtime != self.control or !self.control_guard.load(.acquire) or self.tick_scope != null or self.tick_entry != .idle) return error.InvalidState;
        self.tick_entry = .collecting;
        self.collectBorrowedSounds();
        errdefer self.tick_entry = .failed;
        self.tick_scope = scope;
        self.tick = self.control.stream_control_tick;
        if (self.control.prerequisite_order) |order| order.pointFor(.control, .runtime_control_collect_frame, .before, 0, 0, null);
        if (self.control.offline_causal_replay) |hooks| hooks.checkpoint(hooks.context, .{ .site = .control_collect_frame, .edge = .before });
        if (self.control.live_semantic_hooks) |hooks| hooks.point(hooks.context, .{ .role = .control, .site = .runtime_control_collect_frame, .edge = .before });
        const observed_collect_frame = self.control.scheduled.render_frame.load(.acquire);
        self.control_frame = try self.resolveControlFrameV1(scope, observed_collect_frame);
        if (self.control.prerequisite_order) |order| order.pointFor(.control, .runtime_control_collect_frame, .after, 0, 0, observed_collect_frame);
        if (self.control.offline_causal_replay) |hooks| hooks.checkpoint(hooks.context, .{ .site = .control_collect_frame, .edge = .after, .value = observed_collect_frame });
        if (self.control.live_semantic_hooks) |hooks| hooks.point(hooks.context, .{ .role = .control, .site = .runtime_control_collect_frame, .edge = .after, .value = observed_collect_frame });
        scope.observeControlCollectionV1(observed_collect_frame);
        try scope.observeLiveFrontierV1(observed_collect_frame, self.control_frame);
        self.input_order = 0;
        try self.collectLoad();
        try self.collectPolicies();
        if (self.shutdown_requested.load(.acquire)) {
            try self.collectShutdownV1();
        } else if (self.generation != null) {
            try self.collect();
            if (!self.previewSeekFrozen()) {
                try self.collectSourceSwitchV1();
                try self.collectStreamFaultV1();
            }
            self.drainGroupEvents();
        }
        self.tick_entry = .collected;
    }
    pub const ControlFrameAcquireV1 = struct { observed: u64, effective: u64 };
    /// Checked acquisition, not a setter. This performs the single scheduler
    /// load formerly inside Control's accept phase, between its unchanged
    /// before/after observation hooks. No caller supplies frontier authority.
    pub fn acquireAcceptanceFrameV1(self: *MusicRuntime, scope: rt.ControlRuntime.TickV1) !ControlFrameAcquireV1 {
        try scope.requirePhase(.accept);
        if (scope.runtime != self.control or !self.control_guard.load(.acquire) or
            self.tick_scope == null or !std.meta.eql(self.tick_scope.?, scope) or
            self.tick_entry != .collected or self.tick != self.control.stream_control_tick) return error.InvalidState;
        const observed = self.control.scheduled.render_frame.load(.acquire);
        return .{ .observed = observed, .effective = try self.resolveControlFrameV1(scope, observed) };
    }
    /// Resolve an actual existing frontier acquire against this owner's
    /// previously proven chronology. Does not perform or fabricate a read.
    /// Old owners retain exact observed frames. Once chronology is admitted,
    /// every tick including cleanup must use the new mode until owner teardown.
    fn resolveControlFrameV1(self: *MusicRuntime, scope: rt.ControlRuntime.TickV1, observed: u64) !u64 {
        const chronology = try scope.liveChronologyTickV1();
        if (scope.runtime != self.control or !self.control_guard.load(.acquire) or
            self.tick_scope == null or !std.meta.eql(self.tick_scope.?, scope)) return error.InvalidState;
        if (chronology) {
            const effective = @max(observed, self.live_chronology_frontier orelse observed);
            self.live_chronology_frontier = effective;
            return effective;
        }
        if (self.live_chronology_frontier != null) return error.InvalidMode;
        return observed;
    }
    /// Checked owner synchronization, not an externally writable frontier.
    /// The only frame source is the same-thread active Control capability.
    pub fn syncLiveAcceptanceFrameV1(self: *MusicRuntime, scope: rt.ControlRuntime.TickV1) !void {
        const frame = try scope.liveAcceptanceFrameV1();
        if (scope.runtime != self.control or !self.control_guard.load(.acquire) or
            self.tick_scope == null or !std.meta.eql(self.tick_scope.?, scope) or
            self.tick_entry != .collected or self.tick != self.control.stream_control_tick or
            frame < self.control_frame or frame < (self.live_chronology_frontier orelse frame)) return error.InvalidState;
        self.control_frame = frame;
        self.live_chronology_frontier = frame;
    }
    pub fn prepareControlTickV1(self: *MusicRuntime, scope: rt.ControlRuntime.TickV1, frame: u64) !void {
        return self.prepareControlTickOwnedV1(scope, frame, null);
    }
    pub fn prepareControlTickLiveV1(self: *MusicRuntime, scope: rt.ControlRuntime.TickV1, frame: u64) !LiveTickPreparationV1 {
        var live: LiveTickAttempt = .{};
        self.prepareControlTickOwnedV1(scope, frame, &live) catch |err| {
            // Only the dedicated unwind from this stack attempt is consumed.
            // Unknown failures, including a later publication error, cannot
            // acquire deferred status by consulting a historical last_error.
            if (err == error.LiveStreamAvailabilityDeferred and live.deferred != null) return live;
            if (err == error.LiveStopPrepareDeferred and live.stop_deferred != null) return live;
            if (err == error.LiveColdStartPrepareDeferred and live.cold_start_deferred != null) return live;
            return err;
        };
        return .{};
    }
    fn deferLiveTick(self: *const MusicRuntime, live: *LiveTickAttempt, stage: @FieldType(LiveTickDeferV1, "stage"), observation: rt.streaming.stream.LiveObservationDeferV1) error{LiveStreamAvailabilityDeferred} {
        live.deferred = .{ .stage = stage, .control_tick = self.tick, .accepted_control_frame = self.control_frame, .observation = observation };
        return error.LiveStreamAvailabilityDeferred;
    }
    fn prepareControlTickOwnedV1(self: *MusicRuntime, scope: rt.ControlRuntime.TickV1, frame: u64, live: ?*LiveTickAttempt) !void {
        try scope.requirePhase(.prepare);
        if (self.tick_scope == null or !std.meta.eql(self.tick_scope.?, scope) or self.tick_entry != .collected) return error.InvalidState;
        self.tick_entry = .preparing;
        errdefer self.tick_entry = .failed;
        self.control_frame = frame;
        try self.preparePolicyGraphLoad();
        // Collection continues through stop/unload/shutdown for original
        // generation owners. It never substitutes the current generation.
        try self.collectLayerControllers(scope);
        try self.cancelFaultedSuffixV1();
        try self.retireSwitchedSourcesV1();
        if (self.deviceRecoveryActive()) try self.progressDeviceRecovery(live);
        if (self.shutdown_requested.load(.acquire)) {
            self.rejectQueuedV1();
        } else {
            try self.preparePolicies();
            try self.stepResidentV1(true, live);
        }
        try self.prepareLayerDrivers();
        // Accepted requests and retirement must progress before background
        // supply reports a persistent failure. Cold preparation has its own
        // request-scoped failure boundary in scheduleTransition; active supply
        // must never consume that ticket or starve a later reserved stop.
        if (self.generation) |generation| if (!self.shutdown_requested.load(.acquire) and !self.unloading) {
            self.tickHook(.before_background_supply);
            defer self.tickHook(.after_background_supply);
            self.prefetchMusicWindowsForTick(generation, frame, live) catch |err| {
                if (live != null and err == error.LiveStreamAvailabilityDeferred and live.?.deferred != null) return err;
                self.last_error = failureV1(err);
                // A genuine failed source read cannot leave an uneffected
                // boundary stop queued as if its waiting interval succeeded.
                // Capacity pressure alone is not a source-failure observation.
                if (err == error.SourceReadFailed or err == error.SourceUnavailable or err == error.InvalidSource or err == error.InvalidBinding) {
                    if (self.action_boundary_stop != null) if (self.action_ticket) |ticket|
                        self.finishTicketV1(ticket, .{ .rejected = failureV1(err) });
                    if (self.pending) |*pending| {
                        if (pending.boundary_stop != null and !pending.effective)
                            pending.boundary_failure = failureV1(err);
                    }
                    // Retain the cause so the next prepare retries a full
                    // cancellation queue. Preserve this original supply error.
                    self.cancelFutureBoundaryStopV1() catch {};
                }
                return err;
            };
        };
        self.tick_entry = .prepared;
        self.tickHook(.after_prepare);
    }
    pub fn publishControlTickV1(self: *MusicRuntime, scope: rt.ControlRuntime.TickV1) !void {
        try scope.requirePhase(.publish);
        if (scope.runtime != self.control or self.tick_scope == null or !std.meta.eql(self.tick_scope.?, scope) or !self.control_guard.load(.acquire)) return error.InvalidState;
        switch (self.tick_entry) {
            .collected, .prepared, .failed => {},
            else => return error.InvalidState,
        }
        self.tick_entry = .publishing;
        if (self.policy_storage) |storage| if (storage.bootstrap) |bootstrap| if (bootstrap.submitted) self.policy_render_permitted.store(true, .release);
        self.tickHook(.before_music_publish);
        self.publishSnapshot();
        self.tick_entry = .published;
        self.tickHook(.after_music_publish);
    }
    fn tickHook(self: *MusicRuntime, stage: TickStage) void {
        if (@import("builtin").is_test) if (self.test_tick_hook) |hook| hook.call(hook.context, stage);
    }
    /// Music-only drain. Ordinary SFX and the single render clock keep running.
    /// A borrowed resident SFX SampleOwner pins this bank until its final release.
    pub fn unloadBank(self: *MusicRuntime, reference: v1.BankRefV1) !void {
        if (self.deviceRecoveryActive()) return error.DrainPending;
        if (self.resident_state != null or self.live_reload != null or self.preview_seek != null) return error.DrainPending;
        try self.claimControlV1();
        defer self.control_guard.store(false, .release);
        try self.checkBank(reference);
        if (self.shutdown_requested.load(.acquire)) return error.RuntimeStopped;
        // Keep the actual cancellation owner before closing admission/supply.
        // Queue pressure leaves all unload flags unchanged and can be retried.
        try self.cancelFutureBoundaryStopV1();
        self.admission_handle.store(0, .release);
        self.unloading = true;
        self.generations.closeBorrowed(self.generation.?.registry_handle.?) catch unreachable;
        self.generation.?.closePlayCustody();
        self.collectBorrowedSounds();
        self.abortReloadOwned(.unloading);
        self.state = .stopping;
        self.publishSnapshot();
        return error.DrainPending;
    }
    fn collectUnload(self: *MusicRuntime) !void {
        if (self.layer_in_flight != null) return;
        if (self.pending != null or self.active_group != null or self.active_producers.load(.acquire) != 0 or self.ingress.occupied.load(.acquire) != 0) return;
        for (self.retired_groups) |group| if (group != null) return;
        try self.abandonPreparing();
        try self.abandonResume();
        const generation = self.generation.?;
        if (generation.hasControlLeases() or self.hasBorrowedSounds(generation) or self.reload.ownsResources()) return;
        if (self.policy_storage) |storage| if (storage.physicalCount() != 0 or storage.bootstrap != null) return;
        try generation.collectWindows();
        // Do not retire the intrinsic owner until all external bank users have
        // released, so failed drain is retryable without partially freed assets.
        generation.requestRetirement() catch |err| switch (err) {
            error.DrainPending => return,
        };
        if (!generation.retirementAcknowledged()) return;
        // Cold histories perform their own bounded Worker exclusion. Do not
        // nest those claims inside the final current-generation handoff.
        try self.destroyRetainedGenerations();
        self.worker_generation.store(null, .release);
        if (self.worker_guard.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return;
        defer self.worker_guard.store(false, .release);
        self.generation = null;
        self.device_stream_origin = null;
        generation.withdraw();
        generation.destroy();
        self.assertServiceCredits();
        self.admission_generation.store(0, .release);
        self.action = null;
        self.action_ticket = null;
        self.action_boundary_stop = null;
        self.unloading = false;
        self.state = .uninitialized;
    }

    pub fn bankGeneration(self: *const MusicRuntime) api.AssetGeneration {
        if (self.mode == .versioned) return @enumFromInt(self.admission_generation.load(.acquire));
        if (self.generation == null) return @enumFromInt(0);
        return @enumFromInt(self.generation.?.runtime_generation);
    }
    pub fn bankHash(self: *const MusicRuntime) [32]u8 {
        if (self.mode == .versioned) return if (@constCast(self).snapshotV1()) |status| status.bank_content_hash else |_| @splat(0);
        if (self.generation == null) return @splat(0);
        return self.generation.?.loaded.content_hash;
    }
    pub fn submit(self: *MusicRuntime, generation: api.AssetGeneration, request: api.MusicRequest) !void {
        if (self.mode != .compatibility) return error.InvalidMode;
        if (generation != self.bankGeneration()) return error.StaleAssetGeneration;
        try request.validate(.offline);
        switch (request.payload) {
            .set_state => |value| {
                _ = try find(self.generation.?.loaded.tables.states, value.state.value());
            },
            .pause, .@"resume" => {},
            .stop => |mode| if (mode != .emergency_ramp) return error.UnsupportedOperation,
            else => return error.UnsupportedOperation,
        }
        if (self.request_guard.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.request_guard.store(false, .release);
        if (self.shutdown_requested.load(.acquire) or !self.control.accepting.load(.acquire)) return error.RuntimeStopped;
        if (request.request_id <= self.last_submitted) return error.InvalidOrder;
        if (self.queue_count == request_capacity) return error.CommandQueueFull;
        self.queue[self.queue_count] = request;
        self.queue_count += 1;
        self.last_submitted = request.request_id;
    }
    /// Borrows authenticated decoded resident PCM for the existing submitPlay
    /// entry. Caller releases this lease; every actual SFX voice retains its own.
    pub fn bindEventAdapterV1(self: *MusicRuntime, adapter: *audio.events.RuntimeAdapterV1, reference: v1.BankRefV1) !void {
        try self.claimControlV1();
        defer self.control_guard.store(false, .release);
        try self.checkBank(reference);
        if (self.preview_seek != null) return error.ResidentTransactionBusy;
        if (!self.usesIntegratedTickV1() or adapter.owner != self or self.event_adapter != null or self.shutdown_requested.load(.acquire) or self.unloading or self.admission_handle.load(.acquire) == 0) return error.InvalidState;
        self.event_adapter = adapter;
    }
    pub fn unbindEventAdapterV1(self: *MusicRuntime, adapter: *audio.events.RuntimeAdapterV1) !void {
        try self.claimControlV1();
        defer self.control_guard.store(false, .release);
        if (self.event_adapter != adapter) return error.InvalidState;
        if (adapter.active != 0) return error.DrainPending;
        self.event_adapter = null;
    }
    pub fn captureSfxCompletionV1(self: *MusicRuntime, control: *rt.ControlRuntime, completion: rt.Completion) void {
        if (control != self.control or !control.control_active.load(.acquire) or std.Thread.getCurrentId() != self.control_thread) return;
        if (self.event_adapter) |adapter| adapter.recordCompletion(completion);
    }
    pub fn acquireSoundV1(self: *MusicRuntime, reference: v1.BankRefV1, sound_id: u64) !SoundLease {
        try self.claimControlV1();
        defer self.control_guard.store(false, .release);
        try self.checkBank(reference);
        if (self.shutdown_requested.load(.acquire)) return error.RuntimeStopped;
        if (self.unloading or self.admission_handle.load(.acquire) == 0) return error.InvalidState;
        const index = try find(self.generation.?.loaded.tables.sounds, sound_id);
        const sound = self.generation.?.loaded.tables.sounds[index];
        if (sound.channels != 1 or sound.storage != .resident) return error.UnsupportedCapability;
        return self.borrowSoundOwned(index);
    }
    pub fn acquireSound(self: *MusicRuntime, generation: api.AssetGeneration, sound_id: u64) !SoundLease {
        try self.claimSoundControl();
        defer self.control_guard.store(false, .release);
        if (self.shutdown_requested.load(.acquire)) return error.RuntimeStopped;
        if (self.generation == null or self.unloading or (self.mode == .versioned and self.admission_handle.load(.acquire) == 0)) return error.InvalidState;
        if (generation != self.bankGeneration()) return error.StaleAssetGeneration;
        const index = try find(self.generation.?.loaded.tables.sounds, sound_id);
        if (self.generation.?.loaded.tables.sounds[index].channels != 1 or self.generation.?.loaded.tables.sounds[index].storage != .resident) return error.UnsupportedCapability;
        return self.borrowSoundOwned(index);
    }
    /// Both public acquisition entries have already authenticated their exact
    /// generation and resident sound while holding the same Control guard.
    /// A SoundLease becomes visible only after cell, registry and physical owner
    /// custody all succeed; each earlier step rolls back on later failure.
    fn borrowSoundOwned(self: *MusicRuntime, index: u32) !SoundLease {
        std.debug.assert(self.control_guard.load(.acquire));
        if (self.live_reload != null or self.preview_seek != null) return error.ResidentTransactionBusy;
        self.collectBorrowedSounds();
        const handle = self.generation.?.registry_handle.?;
        const owner = &self.generation.?.owners[index];
        const token = try self.borrowed_sounds.reserve(.{ .generation = handle, .owner = owner });
        errdefer self.borrowed_sounds.cancel(token);
        try self.generations.acquireBorrowed(handle);
        errdefer self.generations.releaseBorrowed(handle) catch unreachable;
        try owner.retain();
        self.borrowed_sounds.publish(token);
        self.assertBorrowedCredits();
        return .{ .owner = owner, .return_token = token };
    }
    fn position(self: *MusicRuntime) trace.schema.Position {
        if (self.tick_scope) |scope| {
            const result = scope.position(self.control_frame) catch unreachable;
            self.input_order = result.input_order + 1;
            return result;
        }
        const result: trace.schema.Position = .{ .accepted_control_frame = self.control_frame, .control_tick = self.tick, .input_order = self.input_order };
        if (self.public_recording.mode == .chunks and self.input_order == std.math.maxInt(u64)) {
            self.public_recording.chunk_storage.?.fail(.counter_exhausted, self.chunkFrontierV1());
            self.failRecordingV1();
        } else self.input_order += 1;
        return result;
    }
    /// Internal Control observation fan-out. The already-owned integrated tick
    /// calls this before any optional host trace queue can lose the real input.
    pub fn captureStreamingInputV1(self: *MusicRuntime, control: *rt.ControlRuntime, value: trace.Input) void {
        if (!self.usesIntegratedTickV1() or control != self.control or !self.control_guard.load(.acquire)) return;
        self.input_order = value.position.input_order + 1;
        if (self.public_recording.phase == .active and public_replay.isChunkStream(self.public_recording.profile) and value.payload == .worker) {
            if (!self.public_recording.driving or self.tick_scope == null) {
                self.failRecordingV1();
                return;
            }
            self.public_recording.prepared_batches += 1;
        }
        self.input(value);
    }
    fn loseTrace(self: *MusicRuntime, counter: *u64) void {
        self.incomplete = true;
        const next = @addWithOverflow(counter.*, 1);
        if (next[1] != 0) self.trace_counter_exhausted = true;
        counter.* = if (next[1] == 0) next[0] else std.math.maxInt(u64);
        // Exhausting this optional retained suffix is not semantic loss: the
        // output sink already received the original value. Counter exhaustion
        // cannot preserve ordinal evidence and must invalidate the capture.
        if (self.trace_counter_exhausted) self.invalidateSemanticOutputV1();
    }
    fn input(self: *MusicRuntime, value: trace.Input) void {
        // The guarded actual fanout precedes optional diagnostic loss. A sink
        // owns any retained copy and cannot affect this Input or audio outcome.
        if (self.semantic_output_sink) |sink| sink.input(sink.context, value);
        if (self.tick_scope) |scope| scope.observeLiveInputV1(value);
        if (self.causal_sink) |sink| sink.input(sink.context, value);
        if (self.public_recording.mode == .chunks and self.public_recording.phase == .active) {
            self.serviceChunkFailureV1();
            if (self.public_recording.phase == .active) {
                const storage = self.public_recording.chunk_storage.?;
                if (storage.appendInput(value, self.chunkFrontierV1()) == .retained) {
                    self.public_recording.chunk_cursor.?.feed(&.{value}) catch self.failRecordingV1();
                } else self.failRecordingV1();
            }
        }
        self.inputDiagnosticV1(value);
    }
    fn inputDiagnosticV1(self: *MusicRuntime, value: trace.Input) void {
        if (self.input_count == self.inputs.len) {
            self.loseTrace(&self.input_lost);
            return;
        }
        _ = std.math.add(u64, self.input_base, self.input_count + 1) catch {
            self.trace_counter_exhausted = true;
            self.loseTrace(&self.input_lost);
            return;
        };
        self.inputs[self.input_count] = value;
        if (self.observer_storage) |storage| storage.recordInput(self.input_base + self.input_count, value);
        self.input_count += 1;
    }
    fn observe(self: *MusicRuntime, value: trace.ScheduleEntry) void {
        if (self.semantic_output_sink) |sink| sink.schedule(sink.context, value);
        if (self.causal_sink) |sink| sink.schedule(sink.context, value);
        if (self.public_recording.mode == .chunks and self.public_recording.phase == .active) {
            self.serviceChunkFailureV1();
            if (self.public_recording.phase == .active and
                self.public_recording.chunk_storage.?.appendSchedule(value, self.chunkFrontierV1()) != .retained) self.failRecordingV1();
        }
        self.observeDiagnosticV1(value);
    }
    fn observeDiagnosticV1(self: *MusicRuntime, value: trace.ScheduleEntry) void {
        if (self.observation_count == self.observations.len) {
            self.loseTrace(&self.observation_lost);
            return;
        }
        _ = std.math.add(u64, self.observation_base, self.observation_count + 1) catch {
            self.trace_counter_exhausted = true;
            self.loseTrace(&self.observation_lost);
            return;
        };
        self.observations[self.observation_count] = value;
        if (self.observer_storage) |storage| storage.recordSchedule(self.observation_base + self.observation_count, value);
        self.observation_count += 1;
    }
    fn markAuthoritativeTraceIncompleteV1(self: *MusicRuntime) void {
        self.invalidateSemanticOutputV1();
        if (self.causal_sink) |sink| sink.invalidate(sink.context);
        self.markSerialTraceIncompleteV1();
    }
    // Legacy serial histories cannot describe overlap. The public causal path
    // records the actual acquire cuts, so this specific limitation is not loss.
    fn markSerialTraceIncompleteV1(self: *MusicRuntime) void {
        self.incomplete = true;
        if (self.public_recording.mode == .chunks) {
            self.public_recording.chunk_evidence_incomplete = true;
            if (self.public_recording.phase == .active) self.failRecordingV1();
        }
    }
    fn legacyTraceIncomplete(self: *const MusicRuntime) bool {
        return self.incomplete or self.replay_unsupported or self.live_chronology_frontier != null or self.input_base != 0 or self.observation_base != 0;
    }
    fn receipt(self: *MusicRuntime, value: api.MusicReceipt) void {
        if (self.mode == .versioned) {
            switch (value) {
                .rejected => |rejected| self.rejectRequest(rejected.request_id, rejected.reason),
                .phase_terminal => |phase| {
                    // Independent bounded diagnostic feed: request credits still
                    // guarantee exactly one accepted/terminal pair. A lost phase
                    // copy marks the public snapshot incomplete, never lifetime.
                    if (!self.receipts.push(value)) self.phaseReceiptOverflowV1();
                    if (self.pending) |pending| {
                        if (pending.operation == .transition and !std.meta.eql(phase.token, pending.token)) return;
                        if (phase.outcome == .cancelled and pending.operation == .transition and self.interruption != null) self.interruption.?.cancelled_before_entry = phase;
                        if (pending.request_ticket) |ticket| {
                            if (phase.outcome == .executed and pending.operation == .stop) {
                                if (self.policy_storage) |storage| if (storage.physicalCount() != 0) {
                                    // Keep whichever real owner issued this stop:
                                    // primary or interruption, never an internal end.
                                    storage.music_stop_ticket = ticket;
                                    storage.music_stop_phase = phase;
                                    return;
                                };
                            }
                            self.finishTicketV1(ticket, if (phase.outcome == .executed) .{ .executed = phase } else .{ .rejected = pending.boundary_failure orelse .cancelled });
                        }
                    }
                },
                else => {},
            }
            return;
        }
        if (!self.receipts.push(value)) self.incomplete = true;
    }
    fn phaseReceiptOverflowV1(self: *MusicRuntime) void {
        self.invalidateSemanticOutputV1();
        self.incomplete = true;
        // Only actual diagnostic queue loss is fatal here. Exhausting bounded
        // legacy input/schedule retention must not impose a playback-length cap.
        if (self.public_recording.mode == .chunks and self.public_recording.profile == .stream_context_serial_v1) {
            self.context_recording_violation.store(true, .release);
            self.failRecordingV1();
        }
    }
    fn requireRawContextCallV1(self: *const MusicRuntime) !void {
        try self.requireFinalizationOpen();
        if (self.context_recording_gate.load(.seq_cst)) return error.UnsupportedOperation;
    }
    fn rejectRequest(self: *MusicRuntime, request_id: u64, err: anyerror) void {
        // Preserve the original V1 failure category. Legacy MusicError cannot
        // represent memory/capacity/order errors and deliberately keeps its old
        // compatibility mapping; it is never an intermediate V1 representation.
        if (self.mode == .versioned) {
            if (self.in_flight) |ticket| if (ticket.request_id == request_id) self.finishTicketV1(ticket, .{ .rejected = failureV1(err) });
            if (self.layer_in_flight) |ticket| if (ticket.request_id == request_id) {
                if (!self.layerTicketOwnsV1(ticket)) self.finishTicketV1(ticket, .{ .rejected = failureV1(err) });
            };
            if (self.interruption) |interrupt| if (interrupt.ticket.request_id == request_id) self.finishTicketV1(interrupt.ticket, .{ .rejected = failureV1(err) });
        } else self.receipt(.{ .rejected = .{ .request_id = request_id, .reason = publicError(err) } });
    }
    pub fn pollReceipt(self: *MusicRuntime) ?api.MusicReceipt {
        // This legacy API has no error channel. A retained finalization cannot
        // acquire caller custody or pop a receipt; unbound behavior is unchanged.
        self.requireFinalizationOpen() catch return null;
        _ = self.context_raw_callers.fetchAdd(1, .seq_cst);
        defer _ = self.context_raw_callers.fetchSub(1, .seq_cst);
        // This legacy API has no error channel. Preserve the actual pop, while
        // safely telling Control that its explicit poll journal is incomplete.
        if (self.context_recording_gate.load(.seq_cst)) self.context_recording_violation.store(true, .release);
        return self.receipts.pop();
    }
    /// Actual acquired phase outcomes, including each cancelled suffix phase.
    /// Diagnostic queue overflow sets StatusV1.complete=false; request terminals
    /// remain independently credit-backed. One serialized game-side consumer.
    pub fn pollPhaseReceiptV1(self: *MusicRuntime) !?api.PhaseReceipt {
        try self.requireFinalizationOpen();
        _ = self.context_raw_callers.fetchAdd(1, .seq_cst);
        defer _ = self.context_raw_callers.fetchSub(1, .seq_cst);
        try self.requireRawContextCallV1();
        return self.pollPhaseReceiptActualV1();
    }
    fn pollPhaseReceiptActualV1(self: *MusicRuntime) !?api.PhaseReceipt {
        try self.requireCausalRoleV1(.control);
        if (self.mode != .versioned) return error.InvalidMode;
        const value = self.receipts.pop() orelse return null;
        return value.phase_terminal;
    }
    fn barAt(self: *MusicRuntime, frame: u64) !u64 {
        var source_frame = frame;
        if (self.usesIntegratedTickV1()) if (self.active_group) |group| {
            const terminal = if (self.tick_scope) |scope| try scope.musicGroupTerminal(group) else try self.control.musicGroupTerminal(group);
            // A terminal bounds actual source progress; it does not erase bars
            // rendered since the last Control collection. Ordinary transition
            // accounting must be independent of that collection cadence.
            if (terminal) |ended| source_frame = @min(source_frame, ended.boundary_frame);
            if (try self.collectSourceSwitchHistoryV1(group, self.generation.?)) |switched| {
                // Reserved stop acceptance remains possible while a coherent
                // live source observation is unavailable. Hold its logical bar
                // at the proven original boundary, never extrapolate old PCM.
                if (self.active_source_incarnation != switched.source_incarnation and source_frame >= switched.frame)
                    return self.originalBarAtSwitch(switched);
            }
        };
        return std.math.add(u64, self.bar_offset, try director.Director.barAtClock(self.generation.?.transport, source_frame));
    }
    fn originalBarAtSwitch(self: *MusicRuntime, switched: rt.music_group.SourceSwitch) !u64 {
        const generation = self.generation.?;
        const original_index = try find(generation.loaded.tables.segments, switched.original_segment);
        const original = generation.loaded.tables.segments[original_index];
        var original_clock = clock.Clock.init(generation.solver.?.maps[original.tempo], switched.frame);
        original_clock.anchor_elapsed = switched.cursor;
        if (switched.loop_epoch != 0) {
            if (original.loop_end <= original.loop_start) return error.InvalidState;
            original_clock.anchor_elapsed = try std.math.add(u64, switched.cursor, try std.math.mul(u64, switched.loop_epoch, original.loop_end - original.loop_start));
        }
        return std.math.add(u64, self.bar_offset, try director.Director.barAtClock(original_clock, switched.frame));
    }
    fn musicGroupSourceSwitch(self: *MusicRuntime, group: rt.GroupHandle) rt.RuntimeError!?rt.music_group.SourceSwitch {
        if (self.tick_scope) |scope| return scope.musicGroupSourceSwitch(group);
        return self.control.musicGroupSourceSwitch(group);
    }
    fn musicVoiceObservation(self: *MusicRuntime, group: rt.GroupHandle) !rt.MusicGroupObservation {
        if (@import("builtin").is_test) if (self.test_source_observation_unavailable) return error.InvalidState;
        if (self.tick_scope) |scope| return scope.musicVoiceObservation(group);
        return self.control.musicVoiceObservation(group);
    }
    /// Immutable lifetime history also survives transition slot reuse. No live
    /// observation or controller adoption is needed to copy this actual fact.
    fn collectSourceSwitchHistoryV1(self: *MusicRuntime, group: rt.GroupHandle, generation: *assets.Generation) rt.RuntimeError!?rt.music_group.SourceSwitch {
        if (!self.usesIntegratedTickV1()) return null;
        const switched = (try self.musicGroupSourceSwitch(group)) orelse return null;
        if (!switched.group.eql(group) or switched.bank_generation != generation.runtime_generation or switched.source_incarnation != 2) return error.InvalidState;
        self.recordSourceSwitchV1(switched);
        return switched;
    }
    /// Consumes only a copied immutable lower fact. In particular, release
    /// results reach this function after the lower slot has already been reset.
    fn recordSourceSwitchV1(self: *MusicRuntime, switched: rt.music_group.SourceSwitch) void {
        const group = switched.group;
        std.debug.assert(group.index < self.source_switch_history.len and switched.source_incarnation == 2);
        // Immutable Render history does not require a live cursor observation.
        // Publish it before any transient observation failure or active-group
        // clear; only the separate adoption below may select a live controller.
        const recorded = self.source_switch_history[group.index];
        if (recorded == null or recorded.?.group_incarnation != group.generation) {
            const fact: v1.SourceSwitchV1 = .{ .group_index = group.index, .group_incarnation = group.generation, .asset_generation = switched.bank_generation, .original_segment = @enumFromInt(switched.original_segment), .fallback_segment = @enumFromInt(switched.emergency_segment), .frame = switched.frame, .cursor = switched.cursor, .loop_epoch = switched.loop_epoch, .layer = switched.layer, .source_incarnation = switched.source_incarnation };
            // Retired owners can be discovered out of Control collection order.
            // Latest means physical boundary, with a deterministic lifetime tie
            // break for simultaneous captures, never collection order.
            const newer = if (self.last_source_switch) |last| fact.frame > last.frame or
                (fact.frame == last.frame and (fact.group_incarnation > last.group_incarnation or
                    (fact.group_incarnation == last.group_incarnation and fact.group_index > last.group_index))) else true;
            if (newer) self.last_source_switch = fact;
            std.debug.assert(self.last_source_switch.?.frame >= fact.frame);
            self.source_switch_count +|= 1;
            self.switched_source_retirements[group.index] = group;
            self.markAuthoritativeTraceIncompleteV1();
            self.last_error = .stream_underrun;
            self.source_switch_history[group.index] = fact;
        }
    }
    /// Collection follows actual target-entry/pause/resume receipts. This
    /// lifetime fact never fabricates a Director entry or rewrites a request.
    fn collectSourceSwitchV1(self: *MusicRuntime) !void {
        if (!self.usesIntegratedTickV1()) return;
        const group = self.active_group orelse return;
        const generation = self.generation orelse return;
        const switched = (try self.collectSourceSwitchHistoryV1(group, generation)) orelse return;
        if (self.active_source_incarnation == switched.source_incarnation) return;
        if ((if (self.tick_scope) |scope| try scope.musicGroupTerminal(group) else try self.control.musicGroupTerminal(group)) != null) return;
        const observed = self.musicVoiceObservation(group) catch |err| switch (err) {
            error.InvalidState => return,
            else => return err,
        };
        // The fact can publish before the end-of-span observation. Wait for a
        // real matching completed capture; preparation metadata is not a cursor.
        if (observed.source_incarnation != switched.source_incarnation or observed.frame <= switched.frame) return;
        // Publication uses a global frame; old slot words can survive reuse.
        // Recheck the exact lifetime after acquiring the observation, so those
        // stale words never become a live replacement clock/controller.
        if ((if (self.tick_scope) |scope| try scope.musicGroupTerminal(group) else try self.control.musicGroupTerminal(group)) != null) return;
        const fallback_index = try find(generation.loaded.tables.segments, switched.emergency_segment);
        const fallback = generation.loaded.tables.segments[fallback_index];
        // A real original resume can execute before its phase is collected.
        // Derive the boundary bar from the durable original source coordinate,
        // not a possibly still-paused Control clock.
        const original_bar = try self.originalBarAtSwitch(switched);
        var recovered = clock.Clock.init(generation.solver.?.maps[fallback.tempo], observed.frame);
        recovered.anchor_elapsed = observed.cursor;
        if (observed.loop_epoch != 0) {
            const loop = observed.loop orelse return error.InvalidState;
            recovered.anchor_elapsed = try std.math.add(u64, observed.cursor, try std.math.mul(u64, observed.loop_epoch, loop.end - loop.start));
        }
        recovered.paused = observed.paused;
        recovered.transport_epoch = observed.transport_epoch;
        recovered.device_epoch = generation.transport.device_epoch;
        // Unpublished old-source work has no execution to preserve. Complete
        // fallible cleanup before publishing the idempotent source selection,
        // so a failed cleanup retains the obligation for the following tick.
        try self.abandonResume();
        if (self.preparing) |prepared| {
            self.abandonPreparing() catch |err| {
                // Window collection can fail after logical abandonment. Its
                // normal retirement loop retains physical ownership; finish
                // the abandoned request exactly once even in that case.
                if (self.preparing == null) {
                    generation.director.?.desired = null;
                    self.rejectRequest(prepared.intent.request_id, error.StreamUnderrun);
                }
                return err;
            };
            generation.director.?.desired = null;
            self.rejectRequest(prepared.intent.request_id, error.StreamUnderrun);
        }
        // The default authored gain remains until a real accepted parameter
        // request. Published old work keeps its real phase/terminal ownership.
        if (generation.layer_owner) |owner| _ = try owner.switchToFallback(group);
        self.active_source_incarnation = switched.source_incarnation;
        self.confirmed_fill = null;
        self.rendering_segment = switched.emergency_segment;
        generation.transport = recovered;
        generation.director.?.transport_epoch = observed.transport_epoch;
        generation.director.?.paused = observed.paused;
        self.state = if (observed.paused) .paused else .playing;
        self.bar_offset = original_bar;
    }
    fn activeSourceSwitchV1(self: *const MusicRuntime) ?v1.SourceSwitchV1 {
        const group = self.active_group orelse return null;
        const recorded = self.source_switch_history[group.index] orelse return null;
        return if (recorded.group_incarnation == group.generation) recorded else null;
    }
    fn sourceSwitchRetirementPending(self: *const MusicRuntime) bool {
        const switched = self.last_source_switch orelse return false;
        if (switched.group_index >= self.switched_source_retirements.len) return false;
        const group = self.switched_source_retirements[switched.group_index] orelse return false;
        return group.generation == switched.group_incarnation;
    }
    fn retireSwitchedSourcesV1(self: *MusicRuntime) !void {
        if (!self.usesIntegratedTickV1()) return;
        for (&self.switched_source_retirements) |*pending| {
            const group = pending.* orelse continue;
            var generation = self.generation orelse {
                pending.* = null;
                continue;
            };
            if (self.group_generation_credits[group.index]) |credit| {
                if (credit.group.eql(group)) {
                    generation = (try self.generations.get(credit.registry)).payload;
                    (if (self.tick_scope) |scope| scope.retireMusicGroupSource(group, 1) else self.control.retireMusicGroupSource(group, 1)) catch |err| switch (err) {
                        error.DrainPending, error.InvalidState => continue,
                        else => return err,
                    };
                }
            }
            generation.retireGroupWindows(group);
            try generation.collectWindows();
            var remaining = false;
            for (generation.windows) |entry| if (entry) |window| if (window.group) |owner| {
                remaining = remaining or owner.eql(group);
            };
            if (!remaining) pending.* = null;
        }
    }
    fn mainUnderrunV1(self: *MusicRuntime) !?rt.music_group.Terminal {
        if (!self.usesIntegratedTickV1()) return null;
        const group = self.active_group orelse return null;
        const generation = self.generation orelse return null;
        // shutdown() already owns serialized Music Control outside TickV1.
        // Use the existing guarded lower API there; never manufacture a tick.
        const terminal = (if (self.tick_scope) |scope|
            try scope.musicGroupTerminal(group)
        else
            try self.control.musicGroupTerminal(group)) orelse return null;
        if (!terminal.group.eql(group) or terminal.bank_generation != generation.runtime_generation) return error.InvalidState;
        return if (terminal.reason == .underrun) terminal else null;
    }
    /// Collect lossy detail separately from the immutable, acquire-published
    /// terminal. A dropped detail record can never prevent resource retirement.
    fn collectStreamFaultV1(self: *MusicRuntime) !void {
        if (!self.usesIntegratedTickV1()) return;
        for (0..rt.music_group.max_groups) |_| {
            const fault = self.control.pollStreamFault() orelse break;
            const generation = self.generation orelse continue;
            if (fault.generation != generation.runtime_generation or fault.degraded) continue;
            const active = if (self.active_group) |group| group.eql(fault.group) else false;
            const target = if (self.pending) |pending|
                (if (pending.target_group) |group| group.eql(fault.group) else false)
            else
                false;
            if (active or target) self.stream_fault_detail = fault;
        }
        self.stream_fault_details_dropped = self.control.stream_fault_overflow.load(.acquire);
        if (self.stream_fault_details_dropped != 0) self.markAuthoritativeTraceIncompleteV1();
        const terminal = (try self.mainUnderrunV1()) orelse return;
        const generation = self.generation.?;
        const already_seen = if (self.last_stream_fault) |fault|
            fault.group_index == terminal.group.index and fault.group_incarnation == terminal.group.generation and fault.asset_generation == terminal.bank_generation
        else
            false;
        if (!already_seen) {
            var fault: v1.StreamFaultV1 = .{
                .group_index = terminal.group.index,
                .group_incarnation = terminal.group.generation,
                .asset_generation = terminal.bank_generation,
                .segment = @enumFromInt(generation.loaded.tables.segments[generation.director.?.committed_segment].key.id),
                .boundary_frame = terminal.boundary_frame,
                .last_sample_frame = terminal.last_sample_frame,
            };
            if (self.stream_fault_detail) |detail| if (detail.group.eql(terminal.group) and detail.generation == terminal.bank_generation) {
                fault.segment = @enumFromInt(detail.segment);
                fault.cursor = detail.cursor;
                fault.loop_epoch = detail.loop_epoch;
                fault.layer = detail.layer;
            };
            self.last_stream_fault = fault;
            self.stream_fault_count +|= 1;
            // This new Control recovery decision has no complete V1 replay
            // injection contract yet. Playback evidence must not overclaim it.
            self.markAuthoritativeTraceIncompleteV1();
        }
        self.last_error = .stream_underrun;
        if (self.action_boundary_stop != null) if (self.action_ticket) |ticket|
            self.finishTicketV1(ticket, .{ .rejected = .stream_underrun });
        // A failed main music lifetime owns the same policy cleanup obligation
        // as an ordinary music stop. Real policy commands/terminals/frontiers
        // must drain long holds; never strand stopping behind unrelated expiry.
        self.requestPolicyStop();
        self.state = .stopping;
        // Phase collection stays authoritative. In particular, a replacement
        // may have executed before cancellation wins; never clear its group.
        if (self.pending != null) return;
        try self.abandonResume();
        if (self.preparing) |prepared| {
            try self.abandonPreparing();
            generation.director.?.desired = null;
            self.rejectRequest(prepared.intent.request_id, error.StreamUnderrun);
        }
        try self.retireGroup(terminal.group);
        self.active_group = null;
        self.confirmed_fill = null;
        self.active_source_incarnation = 0;
        self.rendering_segment = 0;
        self.paused_coordinate = null;
        const epoch = generation.transport.transport_epoch;
        generation.transport = clock.Clock.init(generation.transport.map, terminal.boundary_frame);
        generation.transport.device_epoch = self.device_accepted_epoch.load(.acquire);
        generation.transport.transport_epoch = epoch;
        generation.director.?.paused = false;
        self.bar_offset = generation.director.?.current_bar;
        // retireGroup merely transfers Control ownership. Existing group,
        // program, schedule, Worker and source-window leases still gate release.
    }
    fn cancelFaultedSuffixV1(self: *MusicRuntime) !void {
        const ended = (try self.mainUnderrunV1()) != null;
        if (self.pending) |*pending| {
            const source_changed = self.active_source_incarnation == 2 and pending.source_incarnation != self.active_source_incarnation;
            // Emergency stop retains its fallback tolerance. An uneffected
            // boundary stop loses its stable-source premise; a real phase that
            // already won cancellation still keeps its executed outcome.
            if (pending.boundary_stop != null and !pending.effective and (ended or source_changed))
                pending.boundary_failure = if (ended) .stream_underrun else .invalid_state;
            if (!pending.effective and pending.invalidation == null and
                (((ended or source_changed) and pending.operation != .stop) or pending.boundary_failure != null))
                pending.invalidation = try self.cancelSchedule(.{ .target = pending.block, .requested_frame = self.control_frame });
        }
    }
    fn streamFaultRetirementPending(self: *const MusicRuntime) bool {
        const fault = self.last_stream_fault orelse return false;
        if (fault.group_index >= self.group_generation_credits.len) return false;
        const credit = self.group_generation_credits[fault.group_index] orelse return false;
        return credit.group.generation == fault.group_incarnation and credit.runtime_generation == fault.asset_generation;
    }
    fn drainGroupEvents(self: *MusicRuntime) void {
        while (self.group_events.pop()) |event| self.observe(event);
        // This queue precedes canonical Schedule emission, unlike the optional
        // retained suffix. A lost Render event cannot be recovered by fan-out.
        if (self.group_events.incomplete.load(.acquire)) self.invalidateSemanticOutputV1();
    }

    /// Call on the sole Control thread, then call ControlRuntime.controlTick to
    /// publish both music blocks and ordinary SFX. Splitting these operations
    /// preserves observable publication delays and the existing ownership seam.
    pub fn update(self: *MusicRuntime) !void {
        if (self.mode != .compatibility) return error.InvalidMode;
        try self.updateResident();
    }
    fn updateResident(self: *MusicRuntime) !void {
        if (self.control_guard.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        defer self.control_guard.store(false, .release);
        defer self.publishSnapshot();
        try self.updateResidentOwned(false, null);
    }
    fn updateResidentOwned(self: *MusicRuntime, integrated: bool, live: ?*LiveTickAttempt) !void {
        self.collectBorrowedSounds();
        if (self.shutdown_requested.load(.acquire)) return error.RuntimeStopped;
        const capture_call = self.renderer.callObservation();
        const capture_frame = self.control.scheduled.render_frame.load(.acquire);
        const capture_horizon = self.control.scheduled.commit_horizon.load(.acquire);
        var collection_complete = false;
        defer {
            const finished_frame = self.control.scheduled.render_frame.load(.acquire);
            const finished_horizon = self.control.scheduled.commit_horizon.load(.acquire);
            const finished_call = self.renderer.callObservation();
            // This slice records controlled offline pumping, not unrecorded
            // concurrent planning/frontier facts. Playback remains valid, but
            // unsupported live captures must never advertise complete replay.
            if (capture_call.exhausted or finished_call.exhausted) {
                self.markAuthoritativeTraceIncompleteV1();
            } else if (capture_call.sequence & 1 != 0 or finished_call.sequence & 1 != 0 or capture_call.sequence != finished_call.sequence or capture_frame != finished_frame or capture_horizon != capture_frame or finished_horizon != finished_frame) {
                self.markSerialTraceIncompleteV1();
            } else if (collection_complete) self.collected_call_sequence = finished_call.sequence;
        }
        if (!integrated) {
            self.tick = try std.math.add(u64, self.tick, 1);
            self.input_order = 0;
        }
        var requests: [request_capacity]api.MusicRequest = undefined;
        if (self.request_guard.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.ConcurrentControl;
        const count = self.queue_count;
        @memcpy(requests[0..count], self.queue[0..count]);
        self.queue_count = 0;
        self.request_guard.store(false, .release);
        // Compatibility closes its batch before Render collection. Integrated
        // collection already completed before closing this bounded ingress batch;
        // both acceptance paths retain their actual tick/frontier observation.
        if (!integrated) self.collect() catch |err| {
            self.markAuthoritativeTraceIncompleteV1();
            for (requests[0..count]) |request| self.rejectRequest(request.request_id, err);
            return err;
        };
        self.drainGroupEvents();
        collection_complete = true;
        const rows = &self.decision_records;
        var decisions: selectors.Trace = .{ .records = rows, .base = .{ .kind = .request_accepted, .context = self.config.context, .transport_epoch = self.generation.?.transport.transport_epoch, .asset_generation = self.generation.?.runtime_generation } };
        defer {
            for (rows[0..decisions.count]) |row| self.observe(.{ .event = row });
            if (!decisions.isComplete()) self.markAuthoritativeTraceIncompleteV1();
        }
        for (requests[0..count]) |request| {
            const at = self.position();
            const is_boundary_stop = request.payload == .stop and request.payload.stop == .next_boundary;
            const normalized = trace.schema.normalizeRequest(request, if (self.mode == .versioned) self.config_v1.kind else .offline, 1, request.request_id, self.config.context) catch |err| {
                if (self.mode == .versioned) self.rejectRequest(request.request_id, err);
                return err;
            };
            const accepted: trace.Input = .{ .position = at, .payload = .{ .request = normalized } };
            // Revalidate immediately before Director acceptance. The public
            // MPSC enqueue never dereferences this mutable group/source state.
            const boundary: ?BoundaryStop = if (is_boundary_stop) bind: {
                const source = self.boundaryStopAcceptanceSourceV1() catch |err| {
                    self.input(accepted);
                    self.rejectRequest(request.request_id, boundaryStopError(err));
                    continue;
                };
                break :bind .{ .kind = self.config_v1.boundary_stop.?, .accepted = at, .group = source.group, .bank_generation = source.bank_generation, .source_incarnation = source.source_incarnation, .segment = source.segment, .transport = self.generation.?.transport };
            } else null;
            // Compatibility operates on executed groups only. V1 can also cancel
            // an initial published entry; a pause on a merely Ready owner still
            // rejects before mutating Director state.
            const cancels_initial_entry = self.mode == .versioned and self.interruption != null and (self.pending != null or self.in_flight != null) and (request.payload == .pause or request.payload == .stop);
            const control_context = self.usesIntegratedTickV1() and request.payload == .set_context;
            if (request.payload != .set_state and !control_context and self.active_group == null and !cancels_initial_entry) {
                self.input(accepted);
                self.receipt(.{ .rejected = .{ .request_id = request.request_id, .reason = error.InvalidState } });
                continue;
            }
            const accepted_bar = self.barAt(at.accepted_control_frame) catch |err| {
                const failure = if (is_boundary_stop) boundaryStopError(err) else err;
                if (self.mode == .versioned) self.rejectRequest(request.request_id, failure);
                return failure;
            };
            if (request.payload == .set_parameter) {
                self.acceptLayerParameter(request, accepted, accepted_bar, &decisions) catch |err| {
                    self.input(accepted);
                    self.rejectRequest(request.request_id, err);
                    return err;
                };
                continue;
            }
            self.generation.?.director.?.accept(&.{accepted}, accepted_bar, &decisions) catch |err| {
                if (self.mode == .versioned) self.rejectRequest(request.request_id, err);
                return err;
            };
            if (request.payload == .set_state or request.payload == .stop) self.discardFillContinuation() catch |err| {
                if (self.confirmed_fill != null) self.requireFillCleanupStop();
                self.generation.?.director.?.desired = null;
                self.rejectRequest(request.request_id, err);
                return err;
            };
            if (request.payload == .set_state and self.confirmed_fill != null and request.payload.set_state.state.value() == self.generation.?.loaded.tables.states[self.generation.?.director.?.committed_state].key.id) {
                // Director's ordinary committed-state no-op is not a physical
                // no-op while a fill is sounding. This profile does not infer a
                // reverse path; reject explicitly and stop the actual fill.
                self.generation.?.director.?.desired = null;
                self.input(accepted);
                self.rejectRequest(request.request_id, error.UnsupportedCapability);
                self.requireFillCleanupStop();
                continue;
            }
            // Successful preflight may now supersede the logical desire. Its
            // published work still owns its original ticket until actual phase
            // collection; unpublished desires can terminate immediately.
            if (self.mode == .versioned) if (self.interruption) |interrupt| if (interrupt.ticket.request_id == request.request_id) {
                self.generation.?.director.?.desired = null;
                if (self.pending == null) {
                    try self.abandonResume();
                    if (self.in_flight) |ticket| if (!self.layerTicketOwnsV1(ticket)) self.finishV1(.{ .rejected = .cancelled });
                }
                if (self.pending == null and self.active_group == null) {
                    self.generation.?.director.?.paused = false;
                    self.state = .ready;
                    self.finishInterruptionV1(.unchanged);
                    self.input(accepted);
                    continue;
                }
            };
            self.latest_request_position = at;
            self.input(accepted);
            self.receipt(.{ .request_accepted = .{ .context = @enumFromInt(self.config.context), .accepted_control_frame = at.accepted_control_frame, .control_tick = at.control_tick, .input_order = at.input_order, .request = request } });
            if (control_context) {
                // This request changes only Control selection inputs. Its ticket
                // ends here, independently of later audible state execution.
                self.finishV1(.{ .control_applied = .{
                    .control_tick = at.control_tick,
                    .render_frame = at.accepted_control_frame,
                    .input_order = at.input_order,
                } });
                continue;
            }
            switch (request.payload) {
                .pause => if (self.generation.?.director.?.last_stop_tick != self.tick) {
                    self.action = .pause;
                    self.action_ticket = self.ticketForRequestV1(request.request_id);
                    self.action_boundary_stop = null;
                },
                .@"resume" => if (!self.generation.?.director.?.paused and self.action != .stop) {
                    self.action = .resume_music;
                    self.action_ticket = self.ticketForRequestV1(request.request_id);
                    self.action_boundary_stop = null;
                },
                .stop => {
                    self.requestPolicyStopAt(at);
                    self.action = .stop;
                    self.action_ticket = self.ticketForRequestV1(request.request_id);
                    self.action_boundary_stop = boundary;
                    if (boundary != null) self.replay_unsupported = true;
                },
                else => {},
            }
        }
        if (self.preparing) |prepared| {
            if (self.unloading or self.generation.?.director.?.desired == null or !self.generation.?.director.?.isCurrent(prepared.intent)) try self.abandonPreparing();
        }
        if (self.pending) |*p| {
            if (p.invalidation == null and ((p.intent != null and !self.generation.?.director.?.isCurrent(p.intent.?)) or (self.action != null and (p.operation == .transition or (self.mode == .versioned and self.interruption != null))))) {
                const requested_frame = self.control.scheduled.render_frame.load(.acquire);
                p.invalidation = try self.cancelSchedule(.{ .target = p.block, .requested_frame = requested_frame });
                if (p.transition) |execution| if (execution.cursor.cancel_requested_frame == null) try execution.cursor.requestCancel(requested_frame);
            }
            return;
        }
        if (self.mode == .versioned and self.unloading) self.rejectUnpublishedV1(.stale_bank);
        if (self.cleanup_stop_pending and self.active_group != null and self.action != .stop) {
            self.action = .stop;
            self.action_ticket = null;
            self.action_boundary_stop = null;
        }
        if (self.action) |operation| {
            const action_ticket = self.action_ticket;
            const boundary = self.action_boundary_stop;
            self.action = null;
            self.action_ticket = null;
            self.action_boundary_stop = null;
            if (self.mode == .versioned and self.active_group == null) {
                if (self.interruption) |interrupt| if (interrupt.cancelled_before_entry) |phase| {
                    self.generation.?.director.?.paused = false;
                    self.state = .ready;
                    self.finishInterruptionV1(.{ .cancelled_before_entry = phase });
                    return;
                };
            }
            if (self.active_group == null or (operation == .pause and self.state == .paused) or (operation == .resume_music and self.state != .paused)) {
                if (self.mode == .versioned) {
                    if (action_ticket) |ticket| self.finishTicketV1(ticket, .{ .rejected = .invalid_state });
                } else self.receipt(.{ .rejected = .{ .request_id = self.generation.?.director.?.last_request_id, .reason = error.InvalidState } });
                return;
            }
            self.scheduleOperation(operation, action_ticket, boundary, live) catch |raw_err| {
                if (live != null and raw_err == error.LiveStopPrepareDeferred and live.?.stop_deferred != null) {
                    // No block was created. Preserve the already accepted Stop
                    // action/ticket; the next tick gets a fresh actual frontier.
                    self.action = operation;
                    self.action_ticket = action_ticket;
                    self.action_boundary_stop = boundary;
                    return raw_err;
                }
                const err = if (boundary != null) boundaryStopError(raw_err) else raw_err;
                if (err == error.StreamNotReady) {
                    self.action = operation;
                    self.action_ticket = action_ticket;
                    self.action_boundary_stop = boundary;
                    return;
                }
                try self.abandonResume();
                if (self.fill_continuation != null or (operation == .stop and self.cleanup_stop_pending)) {
                    self.requireFillCleanupStop();
                    try self.discardFillContinuation();
                }
                self.generation.?.director.?.paused = self.state == .paused;
                if (self.mode == .versioned) {
                    if (action_ticket) |ticket| self.finishTicketV1(ticket, .{ .rejected = failureV1(err) });
                } else self.rejectRequest(self.generation.?.director.?.last_request_id, err);
                return err;
            };
            return;
        }
        if (self.fill_continuation) |continuation| {
            if (continuation.intent != null or continuation.resume_request != null) {
                self.prepareFillContinuation(continuation) catch |err| {
                    if (err == error.StreamNotReady) return;
                    // This automatic suffix failure is recovered for playback,
                    // but resource availability is not an input of the bounded
                    // recorder. A fresh replay could prepare the suffix instead
                    // of taking cleanup, so it must never seal this recording.
                    if (self.public_recording.phase == .active) self.failRecordingV1();
                    self.last_error = failureV1(err);
                    // Record the obligation before fallible window retirement.
                    // Scheduler pressure never turns a looping fill into an
                    // unowned orphan after the selector reservation is gone.
                    self.requireFillCleanupStop();
                    try self.discardFillContinuation();
                    return;
                };
                // The successfully published Pending has its own generation
                // credit and owns the bound intent. Only transfer this credit.
                continuation.generation.releasePending();
                self.fill_continuation = null;
            }
            return;
        }
        const frame = self.control_frame;
        const desired_request: ?u64 = if (self.generation.?.director.?.desired) |desired| desired.request_id else null;
        const intent = if (self.preparing) |prepared| prepared.intent else (self.resolveIntent(frame, &decisions) catch |err| {
            if (self.confirmed_fill != null) self.requireFillCleanupStop();
            if (self.mode == .versioned) if (desired_request) |request_id| {
                self.rejectRequest(request_id, err);
                if (self.generation.?.director.?.desired) |desired| {
                    if (desired.request_id == request_id) self.generation.?.director.?.desired = null;
                }
            };
            return err;
        }) orelse return;
        self.scheduleTransition(intent, false, live) catch |err| {
            // This exact attempt still owns its original intent, plan and
            // windows. Return before the legacy destructive rejection path.
            if (live != null and err == error.LiveStreamAvailabilityDeferred and live.?.deferred != null) return err;
            if (live != null and err == error.LiveColdStartPrepareDeferred and live.?.cold_start_deferred != null) return err;
            if (err == error.StreamNotReady) return;
            if (self.preparing) |prepared| if (prepared.cold_candidate != null) {
                self.abandonPreparing() catch |cleanup_err| {
                    // Physical window collection may fail after logical
                    // abandonment. Preserve the original request failure once;
                    // a still-present Preparing retains its sole custody.
                    if (self.preparing == null) {
                        self.generation.?.director.?.desired = null;
                        self.rejectRequest(intent.request_id, err);
                    }
                    return cleanup_err;
                };
                self.generation.?.director.?.desired = null;
                self.rejectRequest(intent.request_id, err);
                return err;
            };
            if (self.confirmed_fill != null) self.requireFillCleanupStop();
            self.generation.?.retireEntryRequestWindows(intent.request_id);
            self.preparing = null;
            try self.generation.?.director.?.abandonPrepared(intent);
            self.generation.?.director.?.desired = null;
            self.rejectRequest(intent.request_id, err);
            return err;
        };
    }

    fn requireFillCleanupStop(self: *MusicRuntime) void {
        self.cleanup_stop_pending = true;
        if (self.action != .stop) {
            self.action = .stop;
            self.action_ticket = null;
            self.action_boundary_stop = null;
        }
    }
    fn discardFillContinuation(self: *MusicRuntime) !void {
        const continuation = self.fill_continuation orelse return;
        var collect_windows = false;
        if (continuation.suspended) |handle| {
            try continuation.generation.director.?.discardSuspendedTargetEntry(handle);
        } else if (continuation.intent) |intent| {
            // Service staging and automatic continuation refer to the SAME
            // unbound Director intent. Consume it once, clear both logical
            // aliases, and retire request windows before returning the credit.
            try continuation.generation.director.?.abandonPrepared(intent);
            if (self.preparing) |prepared| {
                if (std.meta.eql(prepared.intent, intent)) self.preparing = null;
            }
            continuation.generation.retireEntryRequestWindows(intent.request_id);
            collect_windows = true;
            if (continuation.generation.director.?.desired) |desired| {
                if (desired.request_id == intent.request_id) continuation.generation.director.?.desired = null;
            }
        }
        continuation.generation.releasePending();
        self.fill_continuation = null;
        // Physical closure has its own retained owner and may fail/retry. The
        // already-consumed selector identity must never be abandoned again.
        if (collect_windows) try continuation.generation.collectWindows();
    }
    fn prepareFillContinuation(self: *MusicRuntime, continuation: FillContinuation) !void {
        if (self.generation != continuation.generation or self.active_group == null or !self.active_group.?.eql(continuation.group) or self.active_source_incarnation != 1 or self.state != .playing) return error.InvalidState;
        const generation = continuation.generation;
        const actual = self.musicVoiceObservation(continuation.group) catch |err| switch (err) {
            error.InvalidState => return error.StreamNotReady,
            else => return err,
        };
        if (actual.paused) return error.StreamNotReady;
        if (!actual.group.eql(continuation.group) or actual.state != .playing or actual.source_incarnation != 1 or actual.generation != generation.runtime_generation or actual.transport_epoch != generation.transport.transport_epoch) return error.TransitionNotFound;
        const source = if (self.tick_scope) |scope| try scope.musicGroupSource(continuation.group) else try self.control.musicGroupSource(continuation.group);
        if (!source.group.eql(continuation.group) or source.bank_generation != generation.runtime_generation or source.segment != self.rendering_segment or source.source_incarnation != actual.source_incarnation) return error.InvalidState;
        const segment = generation.loaded.tables.segments[try find(generation.loaded.tables.segments, source.segment)];
        var elapsed = actual.cursor;
        if (actual.loop_epoch != 0) {
            if (segment.loop_end <= segment.loop_start) return error.InvalidState;
            elapsed = try std.math.add(u64, elapsed, try std.math.mul(u64, actual.loop_epoch, segment.loop_end - segment.loop_start));
        }
        // Re-anchor to the acquired physical fill observation, not the old
        // committed source or wall time elapsed while paused.
        generation.transport.anchor_render = actual.frame;
        generation.transport.anchor_elapsed = elapsed;
        const intent = continuation.intent orelse try generation.director.?.resumeTargetEntry(continuation.suspended.?, continuation.resume_request.?);
        self.fill_continuation.?.intent = intent;
        self.fill_continuation.?.suspended = null;
        try self.scheduleTransition(intent, true, null);
    }
    fn abandonResume(self: *MusicRuntime) !void {
        if (self.resuming_request) |request| {
            self.generation.?.retireRequestWindows(request);
            self.resuming_request = null;
            try self.generation.?.collectWindows();
        }
    }
    fn abandonPreparing(self: *MusicRuntime) !void {
        const prepared = self.preparing orelse return;
        if (self.fill_continuation) |continuation| if (continuation.intent) |intent| if (std.meta.eql(prepared.intent, intent)) return self.discardFillContinuation();
        if (prepared.cold_candidate) |candidate| {
            // Preparing owns this group until the real retirement ledger accepts it.
            try self.retireResidentGroup(candidate.group);
            self.preparing.?.cold_candidate = null;
        }
        try self.generation.?.director.?.abandonPrepared(prepared.intent);
        self.generation.?.retireEntryRequestWindows(prepared.intent.request_id);
        self.preparing = null;
        // Cancel queued supply now; close still waits for actual worker/gate pins.
        try self.generation.?.collectWindows();
    }
    fn resolveIntent(self: *MusicRuntime, frame: u64, decisions: *selectors.Trace) !?director.TransitionIntent {
        if (self.active_source_incarnation == 2 or self.activeSourceSwitchV1() != null) return null;
        if (self.active_group == null) return self.generation.?.director.?.resolveStart(frame, decisions);
        return self.generation.?.director.?.resolve(frame, try self.barAt(frame), decisions);
    }

    fn prepareMusicGroup(self: *MusicRuntime, desc: rt.MusicGroupDesc, output: rt.channel_layout.ChannelLayout, sample_rate: u32) rt.RuntimeError!rt.GroupHandle {
        const handle = if (self.tick_scope) |scope| try scope.prepareMusicGroup(desc, output, sample_rate) else try self.control.prepareMusicGroup(desc, output, sample_rate);
        if (self.public_recording.phase == .active) self.public_recording.reservations += self.control.prepared_groups[handle.index].prepared.voice_count;
        return handle;
    }
    fn releaseMusicGroup(self: *MusicRuntime, handle: rt.GroupHandle) rt.RuntimeError!void {
        if (self.preview_seek) |state| if (state.lower != null) {
            if (state.old_group.eql(handle)) return error.DrainPending;
            if (state.replacement) |fresh| if (fresh.eql(handle)) return error.DrainPending;
        };
        if (self.resident_state) |state| if (state.lower != null and state.groups.contains(handle)) return error.DrainPending;
        if (self.live_reload) |state| if (state.lower != null) {
            if (state.old_group) |old| if (old.eql(handle)) return error.DrainPending;
            if (state.replacement) |fresh| if (fresh.eql(handle)) return error.DrainPending;
        };
        // Earlier phases can finish physically while a later phase keeps this
        // one immutable schedule block live. Its exact full-handle inventory
        // retains group references until actual releaseSchedule, even after an
        // entered group leaves execution.groups for active/retired custody.
        if (self.pending) |pending| if (pending.transition) |execution| {
            for (execution.referenced_groups) |referenced| if (referenced) |group| {
                if (group.eql(handle)) return error.DrainPending;
            };
        };
        if (self.pending) |pending| for (pending.operation_groups) |referenced| {
            if (referenced) |group| if (group.eql(handle)) return error.DrainPending;
        };
        if (handle.index < self.group_generation_credits.len) if (self.group_generation_credits[handle.index]) |credit| {
            if (!credit.group.eql(handle)) return error.StaleInstance;
            const entry = self.generations.get(credit.registry) catch return error.InvalidState;
            // A nonzero stop ramp can switch after the public stop receipt has
            // cleared active_group. Retired custody remains authoritative until
            // actual physical release, so collect its durable history here too.
            _ = try self.collectSourceSwitchHistoryV1(handle, entry.payload);
            if (credit.layer_controller) {
                const owner = entry.payload.layer_owner orelse return error.InvalidState;
                if ((owner.controllerCount(handle) catch return error.InvalidState) != credit.layer_controller_count) return error.InvalidState;
                for ([_]u64{ 1, 2 }) |incarnation| if (owner.getSource(handle, incarnation) catch return error.InvalidState) |instance| {
                    // Actual program/block cleanup precedes physical group release.
                    if (instance.pending_request != null or (!instance.controller_closed and instance.controller.preparedBusy())) return error.DrainPending;
                };
            }
        };
        // This test-only seam may advance real Render between the optional
        // early history read and the lower acquired final-release proof.
        self.collectHook(.before_group_release);
        const released = if (self.tick_scope) |scope| try scope.releaseMusicGroupWithResult(handle) else try self.control.releaseMusicGroupWithResult(handle);
        std.debug.assert(released.group.eql(handle));
        if (self.usesIntegratedTickV1()) if (released.source_switch) |switched| {
            std.debug.assert(switched.group.eql(handle) and switched.bank_generation == released.bank_generation);
            // Never reread the released slot or Generation. The lower result
            // copied this fact after final zero-pin/frontier acquisition and
            // before reset; recording it is bounded and infallible.
            self.recordSourceSwitchV1(switched);
        };
    }
    fn prepareSchedule(self: *MusicRuntime, start_frame: u64, end_frame: u64, commands: []const rt.ScheduledCommand) rt.RuntimeError!rt.scheduler.Handle {
        const handle = if (self.tick_scope) |scope| try scope.prepareSchedule(start_frame, end_frame, commands) else try self.control.prepareSchedule(start_frame, end_frame, commands);
        if (self.public_recording.phase == .active) {
            self.public_recording.prepared_batches += 1;
            self.capturePlanCommandsV1(&(try self.control.scheduled.getObserved(handle, null)).block, .plan_prepared);
        }
        return handle;
    }
    fn submitSchedule(self: *MusicRuntime, handle: rt.scheduler.Handle) rt.RuntimeError!void {
        if (self.tick_scope) |scope| try scope.submitSchedule(handle) else try self.control.submitSchedule(handle);
        if (self.public_recording.phase == .active) self.public_recording.submitted += 1;
    }
    fn cancelSchedule(self: *MusicRuntime, value: rt.scheduler.Invalidation) rt.RuntimeError!?rt.scheduler.Handle {
        const handle = if (self.tick_scope) |scope| try scope.cancelSchedule(value) else try self.control.cancelSchedule(value);
        if (handle != null and self.public_recording.phase == .active) {
            self.public_recording.submitted += 1;
            self.public_recording.prepared_batches += 1;
        }
        return handle;
    }
    fn releaseSchedule(self: *MusicRuntime, handle: rt.scheduler.Handle) rt.RuntimeError!void {
        if (self.tick_scope) |scope| return scope.releaseSchedule(handle);
        return self.control.releaseSchedule(handle);
    }
    fn schedulePlan(self: *MusicRuntime, handle: rt.scheduler.Handle) rt.RuntimeError!rt.scheduler.Handle {
        if (self.tick_scope) |scope| return scope.schedulePlan(handle);
        return self.control.schedulePlan(handle);
    }
    fn pollPlanPhase(self: *MusicRuntime, handle: rt.scheduler.Handle, cursor: *u16) rt.RuntimeError!?api.PhaseReceipt {
        if (self.tick_scope) |scope| return scope.pollPlanPhase(handle, cursor);
        return self.control.pollPlanPhase(handle, cursor);
    }
    fn pollExecutionReceipt(self: *MusicRuntime, handle: rt.scheduler.Handle, cursor: *u16) rt.RuntimeError!?rt.scheduler.trace.ScheduleRecord {
        if (self.tick_scope) |scope| return scope.pollExecutionReceipt(handle, cursor);
        return self.control.pollExecutionReceipt(handle, cursor);
    }
    fn scheduleAdmission(self: *MusicRuntime, handle: rt.scheduler.Handle) rt.RuntimeError!?rt.scheduler.trace.Admission {
        if (self.tick_scope) |scope| return scope.scheduleAdmission(handle);
        return self.control.scheduleAdmission(handle);
    }
    fn scheduleResult(self: *MusicRuntime, handle: rt.scheduler.Handle) rt.RuntimeError!?rt.ScheduleResult {
        if (self.tick_scope) |scope| return scope.scheduleResult(handle);
        return self.control.scheduleResult(handle);
    }
    fn cancellationResult(self: *MusicRuntime, handle: rt.scheduler.Handle) rt.RuntimeError!?rt.CancellationResult {
        if (self.tick_scope) |scope| return scope.cancellationResult(handle);
        return self.control.cancellationResult(handle);
    }

    fn takePlan(self: *MusicRuntime) !u64 {
        const value = self.next_plan_id;
        self.next_plan_id = try std.math.add(u64, value, 1);
        return value;
    }
    fn prepareGroup(self: *MusicRuntime, segment_index: u32, cursor: u64, request_id: u64) !rt.GroupHandle {
        return self.prepareGroupAt(segment_index, cursor, 0, request_id);
    }
    fn prepareGroupAt(self: *MusicRuntime, segment_index: u32, cursor: u64, loop_epoch: u64, request_id: u64) !rt.GroupHandle {
        return self.prepareGroupFor(self.generation.?, segment_index, cursor, loop_epoch, request_id);
    }
    fn prepareGroupFor(self: *MusicRuntime, generation: *Generation, segment_index: u32, cursor: u64, loop_epoch: u64, request_id: u64) !rt.GroupHandle {
        return self.prepareGroupForEntry(generation, segment_index, cursor, loop_epoch, request_id, null);
    }
    fn prepareGroupForEntry(self: *MusicRuntime, generation: *Generation, segment_index: u32, cursor: u64, loop_epoch: u64, request_id: u64, entry: ?assets.EntryWindow) !rt.GroupHandle {
        return self.prepareGroupForEntryRamp(generation, segment_index, cursor, loop_epoch, request_id, entry, 0);
    }
    fn prepareGroupForEntryRamp(self: *MusicRuntime, generation: *Generation, segment_index: u32, cursor: u64, loop_epoch: u64, request_id: u64, entry: ?assets.EntryWindow, ramp_frames: u32) !rt.GroupHandle {
        return self.prepareGroupForEntryRampScoped(generation, segment_index, cursor, loop_epoch, .request, request_id, entry, ramp_frames);
    }
    fn prepareGroupForEntryRampScoped(self: *MusicRuntime, generation: *Generation, segment_index: u32, cursor: u64, loop_epoch: u64, window_scope: assets.WindowScope, request_id: u64, entry: ?assets.EntryWindow, ramp_frames: u32) !rt.GroupHandle {
        const segment = generation.loaded.tables.segments[segment_index];
        var layers: [rt.music_group.max_layers]rt.MusicGroupLayer = undefined;
        var layout: rt.channel_layout.ChannelLayout = undefined;
        for (generation.loaded.tables.layers[segment.layers.first..][0..segment.layers.count], 0..) |layer, i| {
            const sound = generation.loaded.tables.sounds[layer.sound];
            layout = try rt.channel_layout.ChannelLayout.init(sound.layout, sound.channels, sound.channel_mask);
            layers[i] = .{ .owner = &generation.owners[layer.sound], .layout = layout, .generation = generation.runtime_generation, .gain = std.math.pow(f32, 10, layer.gain_db / 20), .authored = .{ .layer_id = layer.key.id, .drop_rank = layer.drop_rank }, .asset_frame_origin = layer.source_start, .stream = if (sound.storage == .streaming) (if (entry) |window| try generation.sourceForEntryScoped(window_scope, request_id, window, layer.key.id, try std.math.add(u64, layer.source_start, cursor)) else try generation.sourceForScoped(window_scope, request_id, layer.key.id)) else null };
        }
        var fallback_layers: [rt.music_group.max_layers]rt.MusicGroupLayer = undefined;
        var emergency: ?rt.ResidentEmergency = null;
        if (self.usesIntegratedTickV1()) if (try generation.emergencyFallbackSegment(segment_index)) |fallback_index| {
            const fallback = generation.loaded.tables.segments[fallback_index];
            var fallback_layout: rt.channel_layout.ChannelLayout = undefined;
            for (generation.loaded.tables.layers[fallback.layers.first..][0..fallback.layers.count], 0..) |layer, i| {
                const sound = generation.loaded.tables.sounds[layer.sound];
                fallback_layout = try rt.channel_layout.ChannelLayout.init(sound.layout, sound.channels, sound.channel_mask);
                fallback_layers[i] = .{ .owner = &generation.owners[layer.sound], .layout = fallback_layout, .generation = generation.runtime_generation, .gain = std.math.pow(f32, 10, layer.gain_db / 20), .authored = .{ .layer_id = layer.key.id, .drop_rank = layer.drop_rank }, .asset_frame_origin = layer.source_start };
            }
            emergency = .{ .segment = fallback.key.id, .segment_frames = fallback.frames, .layout = fallback_layout, .layers = fallback_layers[0..fallback.layers.count], .loop = if (fallback.loop_end > fallback.loop_start) .{ .start = fallback.loop_start, .end = fallback.loop_end } else null };
        };
        return self.prepareMusicGroup(.{ .segment = segment.key.id, .generation = generation.runtime_generation, .layout = layout, .layers = layers[0..segment.layers.count], .segment_frames = segment.frames, .start_cursor = cursor, .start_loop_epoch = loop_epoch, .ramp_frames = ramp_frames, .loop = if (segment.loop_end > segment.loop_start) .{ .start = segment.loop_start, .end = segment.loop_end } else null, .emergency = emergency }, self.renderer.mixer.output_layout, s.sample_rate);
    }
    fn fillPcmMode(self: *const MusicRuntime) planner.FillPcmMode {
        return switch (self.config_v1.streamed_fill_mode) {
            .full_span => .full_span,
            .rolling_high_watermark => .rolling_high_watermark,
            else => unreachable, // ConfigV1.validate precedes publication.
        };
    }
    fn entryWindow(phases: []const planner.Phase, index: usize) assets.EntryWindow {
        const phase = phases[index];
        var occurrence: u16 = 0;
        for (phases[0..index]) |prior| if (prior.segment == phase.segment and prior.cue == phase.cue and
            (prior.kind == .source_tail or prior.kind == .fill_entry or prior.kind == .target_entry))
        {
            occurrence += 1;
        };
        return .{ .segment = phase.segment, .cue = phase.cue, .occurrence = occurrence };
    }
    /// Current Control custody, not a historical has_executed flag alone.
    /// A retained candidate is still unpublished: submitSchedule success has
    /// no fallible gap before pending is assigned and preparing is cleared.
    fn initialEntryEligibleV1(self: *MusicRuntime, scope: rt.ControlRuntime.TickV1, request_id: u64) bool {
        scope.requirePhase(.prepare) catch return false;
        if (scope.runtime != self.control or !self.control.tick_v1.live_chronology or
            !self.control_guard.load(.acquire) or self.tick_scope == null or
            !std.meta.eql(self.tick_scope.?, scope) or self.tick_entry != .preparing or
            self.mode != .versioned or self.has_executed or self.active_group != null or self.pending != null or
            self.interruption != null or self.layer_in_flight != null or self.action != null or self.deviceRecoveryActive()) return false;
        self.validateLiveTickProfileStateV1(true, true) catch return false;
        const generation = self.generation orelse return false;
        if (generation.transport.device_epoch != 1) return false;
        const prepared = self.preparing orelse return false;
        const primary = self.in_flight orelse return false;
        const ticket = self.ticketForRequestV1(request_id) orelse return false;
        if (!std.meta.eql(primary, ticket) or prepared.intent.request_id != request_id or
            primary.context != self.config.context or !std.meta.eql(primary.bank, self.bankRef()) or prepared.intent.request_epoch != generation.director.?.request_epoch) return false;
        if (prepared.cold_candidate) |candidate| {
            if (candidate.generation != generation or candidate.runtime_generation != generation.runtime_generation or
                candidate.transport_epoch != generation.transport.transport_epoch or candidate.request_id != request_id) return false;
            generation.validateRetainedColdStartBindings(request_id, candidate.entry, candidate.group, &candidate.bindings) catch return false;
        }
        // Read-only validation: do not overwrite binding_scratch while Planner
        // holds its slice. Reject extra/retiring/foreign bound request windows.
        var selected: [4]planner.StreamBinding = undefined;
        var count: usize = 0;
        for (generation.windows) |entry| if (entry) |window| {
            if (window.scope != .request or window.request_id != request_id) continue;
            if (window.retiring or window.binding.cue == 0 or count == selected.len) return false;
            if (prepared.cold_candidate) |candidate| {
                if (window.group == null or !window.group.?.eql(candidate.group)) return false;
            } else if (window.group != null) return false;
            selected[count] = window.binding;
            count += 1;
        };
        if (count != 4) return false;
        const bindings = selected[0..count];
        const service = generation.service orelse return false;
        for (bindings, 0..) |binding, i| {
            // Match entryBindings' failed-source exclusion. The old Planner
            // route retains authority over its rejection/error classification.
            if ((service.failure(binding.handle) catch return false) != .none) return false;
            if (binding.cue == 0) return false;
            for (bindings[0..i]) |prior| if (std.meta.eql(prior.handle, binding.handle)) return false;
            const identity = (service.renderSource(binding.handle) catch return false).identity;
            if (identity.asset != binding.sound or identity.asset_generation != generation.runtime_generation or
                identity.transport_epoch != generation.transport.transport_epoch or identity.stream_generation != binding.handle.generation or
                identity.start_cursor != binding.source_cursor or identity.start_loop_epoch != 0) return false;
        }
        return true;
    }
    /// Internal cross-layer authorization. A caller cannot select source-only
    /// reads with an arbitrary identity or initial flag; the active Tick and
    /// original primary request are rechecked for every real Service operation.
    pub fn validateInitialEntryV1(self: *MusicRuntime, scope: rt.ControlRuntime.TickV1, request_id: u64, handle: rt.streaming.Handle) !void {
        if (!self.initialEntryEligibleV1(scope, request_id)) return error.InvalidState;
        const generation = self.generation.?;
        for (generation.windows) |entry| if (entry) |window| {
            if (window.scope == .request and window.request_id == request_id and !window.retiring and std.meta.eql(window.binding.handle, handle)) return;
        };
        return error.InvalidState;
    }
    /// Chronology-only first-entry lead. All reads below are immutable identity,
    /// this tick's actual readiness, or Control-owned acknowledged receipts.
    /// No new Render counter sampling, forecast, or manufactured ready value.
    fn initialChronologyHeadroomReady(self: *MusicRuntime, request_id: u64, plan: *const planner.TransitionPlan, ready: *const planner.ReadinessSnapshot) !bool {
        const generation = self.generation orelse return error.InvalidState;
        const service = generation.service orelse return error.InvalidState;
        if (!ready.complete or ready.count > planner.max_bindings or plan.phases.count != 1) return error.InvalidState;
        const phase = plan.phases.items[0];
        if (phase.kind != .target_entry or phase.source_cursor != 0) return error.InvalidState;
        const window = entryWindow(plan.phases.slice(), 0);
        const segment = generation.loaded.tables.segments[try find(generation.loaded.tables.segments, phase.segment)];
        if (segment.layers.count != 4) return error.UnsupportedCapability;
        var all_ready = true;
        for (generation.loaded.tables.layers[segment.layers.first..][0..segment.layers.count]) |layer| {
            const sound = generation.loaded.tables.sounds[layer.sound];
            if (sound.storage != .streaming) return error.UnsupportedCapability;
            var selected: ?usize = null;
            for (ready.bindings[0..ready.count], 0..) |binding, index| {
                if (binding.segment != window.segment or binding.cue != window.cue or binding.occurrence != window.occurrence or binding.layer != layer.key.id) continue;
                if (selected != null or binding.sound != sound.key.id or binding.source_cursor != layer.source_start) return error.InvalidState;
                selected = index;
            }
            const index = selected orelse return error.InvalidState;
            const binding = ready.bindings[index];
            var owned = false;
            for (generation.windows) |item| if (item) |entry| {
                if (entry.retiring or entry.scope != .request or entry.request_id != request_id or !std.meta.eql(entry.binding, binding)) continue;
                if (owned) return error.InvalidState;
                owned = true;
            };
            if (!owned) return error.InvalidState;
            const identity = ready.identities[index];
            const readiness_input = ready.observations[index];
            if (readiness_input.payload != .readiness_snapshot or ready.failures[index] != .none) return error.SourceReadFailed;
            const facts = readiness_input.payload.readiness_snapshot.facts;
            if (identity.asset != sound.key.id or identity.asset_generation != generation.runtime_generation or
                identity.transport_epoch != generation.transport.transport_epoch or identity.stream_generation != binding.handle.generation or
                identity.start_cursor != binding.source_cursor or identity.start_loop_epoch != 0 or
                facts.asset != sound.key.id or facts.generation != generation.runtime_generation or
                facts.transport_epoch != generation.transport.transport_epoch or facts.pcm_start != binding.source_cursor or
                readiness_input.position.accepted_control_frame != self.control_frame or readiness_input.position.control_tick != self.tick)
                return error.InvalidState;
            const end = if (identity.loop) |loop| loop.end else identity.frame_count;
            if (binding.source_cursor >= end) return error.InvalidState;
            // Existing readiness covers one contiguous source interval. Actual
            // admitted ordinal prefixes may span multiple real loop decodes.
            const contiguous = @min(@as(u64, service.profile.high_frames), end - binding.source_cursor);
            const ordinal_needed = if (identity.loop != null) @as(u64, service.profile.high_frames) else contiguous;
            const acknowledged = try service.acknowledgedVisiblePrefix(binding.handle);
            if (facts.available_frames < contiguous or facts.pcm_end < try std.math.add(u64, binding.source_cursor, contiguous) or
                acknowledged < ordinal_needed) all_ready = false;
        }
        return all_ready;
    }
    /// Wait for the exact PCM coverage certified by Planner to cross the real
    /// Render visibility gate. Full-span is the default; explicitly rolling
    /// long fills certify a high-watermark entry prefix, not their future PCM.
    /// All occurrences pass before any group preparation or route publication.
    fn fillWindowsVisible(self: *MusicRuntime, request_id: u64, plan: *const planner.TransitionPlan) !bool {
        const generation = self.generation.?;
        const minimum = generation.loaded.tables.platforms[generation.loaded.metadata.profile].planner_minimum_window_frames;
        for (plan.phases.slice(), 0..) |phase, index| {
            if (phase.kind != .fill_entry and phase.kind != .target_entry) return error.UnsupportedCapability;
            const segment = generation.loaded.tables.segments[try find(generation.loaded.tables.segments, phase.segment)];
            const duration = phase.end_frame - phase.execute_frame;
            const needed = if (phase.kind == .target_entry) @min(duration, minimum) else if (plan.fill_pcm_mode == .rolling_high_watermark) @min(duration, generation.service.?.profile.high_frames) else duration;
            for (generation.loaded.tables.layers[segment.layers.first..][0..segment.layers.count]) |layer| {
                if (generation.loaded.tables.sounds[layer.sound].storage != .streaming) continue;
                const cursor = try std.math.add(u64, layer.source_start, phase.source_cursor);
                const window = entryWindow(plan.phases.slice(), index);
                const reference = for (plan.readiness[0..plan.readiness_count]) |value| {
                    if (value.layer == layer.key.id and value.segment == window.segment and value.cue == window.cue and value.occurrence == window.occurrence) break value;
                } else return error.InvalidState;
                if (reference.cursor != cursor or reference.required_pcm_frames != needed or plan.fill_pcm_mode != generation.fill_pcm_mode) return error.InvalidState;
                const source = try generation.sourceForEntry(request_id, window, layer.key.id, cursor);
                if (!source.ready(cursor, 0)) return false;
                const consumed = source.ring.consumed.load(.acquire);
                if (source.ring.renderProduced() - consumed < needed) return false;
            }
        }
        return true;
    }
    /// Only the complete Planner result identifies paths that can become ready
    /// at this clock/frontier. Source/target matching alone includes permanently
    /// ineligible cues. A real failed required window makes an awaiting path
    /// terminal; any nonfailed awaiting path keeps the proposal pending.
    fn crossfadeTargetVisible(self: *MusicRuntime, request_id: u64, projection: crossfade_projection.Projection) !bool {
        const generation = self.generation.?;
        const phase = projection.phases.items[0];
        const segment = generation.loaded.tables.segments[try find(generation.loaded.tables.segments, phase.segment)];
        const window = entryWindow(projection.phases.slice(), 0);
        for (generation.loaded.tables.layers[segment.layers.first..][0..segment.layers.count]) |layer| {
            const source = try generation.sourceForEntry(request_id, window, layer.key.id, layer.source_start);
            if (!source.ready(layer.source_start, 0)) return false;
            const consumed = source.ring.consumed.load(.acquire);
            const produced = source.ring.renderProduced();
            if (produced < consumed or produced - consumed < projection.fade_frames) return false;
        }
        return true;
    }
    fn allAwaitingPathsFailed(self: *MusicRuntime, intent: director.TransitionIntent) !bool {
        const generation = self.generation.?;
        const tables = generation.loaded.tables;
        const rule = tables.transitions[try find(tables.transitions, intent.rule_id)];
        var awaiting = false;
        for (0..rule.paths.count) |offset| {
            const path_index = rule.paths.first + @as(u32, @intCast(offset));
            if (!try generation.solver.?.candidateAwaitingPcm(path_index)) continue;
            awaiting = true;
            if (!try generation.pathEntryFailed(intent.request_id, path_index)) return false;
        }
        if (!awaiting) return error.InvalidState;
        return true;
    }
    fn loopCrossfadePublicationReady(self: *MusicRuntime, generation: *assets.Generation, captured: *const planner.LiveSourceTailSnapshot, plan: *const planner.TransitionPlan) !bool {
        if (plan.source_tail_pcm_mode != .live_one_loop) return error.InvalidState;
        const proof = &(plan.source_tail_obligation orelse return error.InvalidState);
        const group = self.active_group orelse return error.InvalidState;
        if (group.index != proof.group.index or group.generation != proof.group.generation) return error.InvalidState;
        const actual = self.musicVoiceObservation(group) catch |err| switch (err) {
            error.InvalidState => return false,
            else => return err,
        };
        return try generation.loopCrossfadeSourceStillReady(captured, proof, actual, plan.execute_frame) and
            (try self.control.earliestPlanFrame()) <= plan.execute_frame;
    }

    fn scheduleTransition(self: *MusicRuntime, intent: director.TransitionIntent, internal: bool, live: ?*LiveTickAttempt) !void {
        if (self.generation.?.loaded.bus_graph != null and !self.policy_storage.?.graph_installed) return error.StreamNotReady;
        if (self.pending != null) return error.InvalidState;
        if (self.crossfade_outgoing != null) return error.UnsupportedCapability;
        const generation = self.generation.?;
        try generation.retainPending();
        errdefer generation.releasePending();
        const request_ticket: ?v1.RequestTicketV1 = if (self.mode == .versioned and !internal) self.ticketForRequestV1(intent.request_id) orelse return error.InvalidState else null;
        // Cold main preparation may span ticks while an independent duck uses
        // the same allocator/scheduler. Never publish that older reserved ID
        // after a later real policy plan; its source windows remain request-owned.
        if (self.policy_storage != null) if (self.preparing) |*prepared| if (prepared.plan_id < self.next_plan_id - 1) {
            prepared.plan_id = try self.takePlan();
        };
        const id = if (self.preparing) |prepared| prepared.plan_id else try self.takePlan();
        const frame = self.control_frame;
        const loop_tail = if (self.active_group != null and self.config_v1.crossfade.curveFor(intent.rule_id) != null)
            try generation.crossfadeLoopTailLayout(intent.rule_id)
        else
            null;
        var live_source_tail: planner.LiveSourceTailSnapshot = undefined;
        var loop_observed: ?rt.MusicGroupObservation = null;
        var ready: ?*planner.ReadinessSnapshot = null;
        if (self.generation.?.service != null) {
            const scope = self.tick_scope orelse return error.InvalidMode;
            if (self.preparing == null or self.preparing.?.cold_candidate == null) self.preparing = .{ .intent = intent, .plan_id = id };
            if (self.preparing.?.cold_candidate) |candidate| {
                if (live == null or self.has_executed or candidate.generation != generation or
                    candidate.runtime_generation != generation.runtime_generation or candidate.transport_epoch != generation.transport.transport_epoch or
                    candidate.request_id != intent.request_id or self.active_group != null or self.deviceRecoveryActive()) return error.InvalidState;
                try generation.validateRetainedColdStartBindings(candidate.request_id, candidate.entry, candidate.group, &candidate.bindings);
            } else try self.generation.?.prepareEntryWindows(intent, if (self.active_group != null) self.rendering_segment else null, self.generation.?.transport.transport_epoch, try self.planningFrontier());
            self.tickHook(.before_stream_supply);
            const initial_entry = live != null and self.initialEntryEligibleV1(scope, intent.request_id);
            if (initial_entry) {
                try generation.prefetchInitialEntryV1(scope, intent.request_id, frame);
            } else if (live) |attempt| {
                if (try (if (self.preparing.?.cold_candidate != null) generation.prefetchRequestWindowsScopedLiveV1(.request, intent.request_id, frame) else generation.prefetchEntryWindowsLiveV1(intent.request_id, frame))) |observation|
                    return self.deferLiveTick(attempt, .entry_supply, observation);
            } else try generation.prefetchEntryWindows(intent.request_id, frame);
            ready = self.generation.?.readiness.?;
            self.tickHook(.before_stream_readiness);
            defer self.tickHook(.after_stream_readiness);
            const bindings = if (self.preparing.?.cold_candidate) |*candidate| &candidate.bindings else if (self.active_group != null and self.config_v1.crossfade.curveFor(intent.rule_id) != null)
                try generation.linearCrossfadeEntryBindings(intent.request_id, intent.rule_id, self.active_group.?, self.rendering_segment)
            else
                try generation.entryBindings(intent.request_id);
            if (initial_entry) {
                ready.?.collectTickInitialEntryV1(scope, intent.request_id, bindings, self.config.context, intent.request_epoch) catch |err| {
                    self.markAuthoritativeTraceIncompleteV1();
                    return err;
                };
            } else if (live) |attempt| {
                const observation = ready.?.collectTickLiveV1(scope, bindings, self.config.context, intent.request_epoch) catch |err| {
                    self.markAuthoritativeTraceIncompleteV1();
                    return err;
                };
                if (observation) |value| return self.deferLiveTick(attempt, .entry_readiness, value);
            } else ready.?.collectTick(scope, bindings, self.config.context, intent.request_epoch) catch |err| {
                self.markAuthoritativeTraceIncompleteV1();
                return err;
            };
        }
        if (loop_tail != null) {
            self.tickHook(.before_crossfade_source_observation);
            const observed = self.musicVoiceObservation(self.active_group.?) catch |err| switch (err) {
                error.InvalidState => return error.StreamNotReady,
                else => return err,
            };
            if (observed.frame != frame or !try generation.collectLoopCrossfadeSource(&live_source_tail, self.active_group.?, self.rendering_segment, self.config.context, generation.transport.transport_epoch, self.active_source_incarnation, .{ .accepted_control_frame = frame, .control_tick = self.tick, .input_order = self.input_order }, observed)) return error.StreamNotReady;
            loop_observed = observed;
        }
        const q: planner.Query = .{ .source_tail_pcm_mode = if (loop_tail != null) .live_one_loop else .contiguous, .live_source_tail = if (loop_tail != null) &live_source_tail else null, .readiness = ready, .fill_pcm_mode = generation.fill_pcm_mode, .intent = intent, .source_segment = if (self.active_group != null) self.rendering_segment else self.generation.?.loaded.tables.segments[self.generation.?.director.?.committed_segment].key.id, .source_group = if (self.active_group) |group| group.generation else null, .source_clock = self.generation.?.transport, .request_position = self.latest_request_position, .position = .{ .accepted_control_frame = frame, .control_tick = self.tick, .input_order = self.input_order }, .frontier = .{ .earliest_submit_frame = try self.planningFrontier() }, .context = self.config.context, .asset_generation = self.generation.?.runtime_generation, .transport_epoch = self.generation.?.transport.transport_epoch, .plan_id = id, .plan_epoch = 1, .plan_id_floor = (try self.generation.?.director.?.nextPlanIdFloor()).value() };
        var issued = false;
        errdefer if (issued) self.generation.?.solver.?.forgetPlan(id, 1) catch {};
        if (self.active_group == null) {
            self.generation.?.solver.?.planStart(q, self.generation.?.scratch_plan.?) catch |err| {
                if (err == error.TargetNotResident and ready != null) return error.StreamNotReady;
                return err;
            };
            issued = true;
        } else {
            const rows = &self.planner_records;
            var log: planner.PlannerTrace = .{ .records = rows };
            defer {
                for (rows[0..log.count]) |row| self.observe(row);
                if (log.incomplete) self.markAuthoritativeTraceIncompleteV1();
            }
            self.generation.?.solver.?.plan(q, self.generation.?.scratch_plan.?, &log) catch |err| {
                if (err == error.TargetNotResident and ready != null) {
                    if (try self.allAwaitingPathsFailed(intent)) return error.SourceReadFailed;
                    return error.StreamNotReady;
                }
                return err;
            };
            issued = true;
            self.generation.?.solver.?.verifyPcm(q, self.generation.?.scratch_plan.?) catch |err| {
                if (err == error.TargetNotResident and ready != null) {
                    // The forecast plan really consumed its ID. A later actual
                    // PCM proof gets a fresh ID, preserving the Planner watermark.
                    self.preparing.?.plan_id = try self.takePlan();
                    return error.StreamNotReady;
                }
                return err;
            };
        }
        const plan = self.generation.?.scratch_plan.?;
        var projected: ?crossfade_projection.Projection = null;
        if (plan.fade_frames != 0) {
            const group = self.active_group orelse return error.UnsupportedCapability;
            const curve = self.config_v1.crossfade.curveFor(plan.rule_id) orelse return error.UnsupportedCapability;
            if (loop_tail == null) self.tickHook(.before_crossfade_source_observation);
            const observed = loop_observed orelse (self.musicVoiceObservation(group) catch |err| switch (err) {
                error.InvalidState => {
                    self.preparing.?.plan_id = try self.takePlan();
                    return error.StreamNotReady;
                },
                else => return err,
            });
            if (observed.frame != self.control_frame or observed.source_incarnation != self.active_source_incarnation or plan.execute_frame < observed.frame) {
                self.preparing.?.plan_id = try self.takePlan();
                return error.StreamNotReady;
            }
            const segment = generation.loaded.tables.segments[try find(generation.loaded.tables.segments, self.rendering_segment)];
            const coordinate = try rt.virtual_voice.predict(observed.cursor, observed.loop_epoch, segment.frames, if (observed.loop) |loop| .{ .start = loop.start, .end = loop.end } else null, plan.execute_frame - observed.frame);
            projected = try crossfade_projection.project(plan, .{
                .binding = .{ .transition_id = plan.rule_id, .curve = curve },
                .tables = generation.loaded.tables,
                .bank_build_id = generation.solver.?.bank_build_id,
                .context = self.config.context,
                .asset_generation = generation.runtime_generation,
                .transport_epoch = generation.transport.transport_epoch,
                .source_group = .{ .index = group.index, .generation = group.generation, .stable_id = group.generation },
                .source_segment = self.rendering_segment,
                .target_segment = intent.resolved_segment,
                .source_exit_cursor = coordinate.cursor,
                .source_loop_epoch = coordinate.loop_epoch,
            });
            if ((loop_tail == null and !try generation.linearCrossfadeSourceTailReady(group, self.rendering_segment, generation.transport.transport_epoch, self.active_source_incarnation, observed, projected.?.onset_frame, projected.?.fade_frames)) or
                !try self.crossfadeTargetVisible(intent.request_id, projected.?))
            {
                self.preparing.?.plan_id = try self.takePlan();
                return error.StreamNotReady;
            }
        }
        const execution_phases = if (projected) |value| value.phases else plan.phases;
        if (execution_phases.count == 0 or execution_phases.count > assets.max_resident_fill_steps + 1) return error.UnsupportedCapability;
        if (projected == null and ready != null and plan.phases.count > 1 and !try self.fillWindowsVisible(intent.request_id, plan)) {
            // The real Planner consumed this ID even though visibility is not
            // yet sufficient. Preserve its watermark across the next attempt.
            self.preparing.?.plan_id = try self.takePlan();
            return error.StreamNotReady;
        }
        const cold_start = live != null and !internal and request_ticket != null and !self.has_executed and
            self.active_group == null and generation.service != null and generation.transport.device_epoch == 1 and
            !self.deviceRecoveryActive() and self.config_v1.streaming_reservation == .initial_bank_only and
            projected == null and execution_phases.count == 1 and execution_phases.items[0].kind == .target_entry and
            execution_phases.items[0].source_cursor == 0;
        if (self.preparing) |prepared| if (prepared.cold_candidate != null and !cold_start) return error.InvalidState;
        if (cold_start and self.live_chronology_frontier != null and
            !try self.initialChronologyHeadroomReady(intent.request_id, plan, ready orelse return error.InvalidState))
        {
            // Planner consumed this ID. Keep the original request/windows but
            // advance its watermark; the existing issued errdefer forgets it.
            self.preparing.?.plan_id = try self.takePlan();
            return error.StreamNotReady;
        }
        self.tickHook(.before_schedule_prepare);
        defer self.tickHook(.after_schedule_prepare);
        const target_token = try plan.targetToken();
        const cursor = try planner.PlanCursor.init(execution_phases);
        const execution = try self.allocator.create(TransitionExecution);
        execution.* = .{ .cursor = cursor, .crossfade = projected, .source_exit_cue = plan.source_exit_cue, .fill_route = plan.fill_route, .path_id = plan.path_id };
        execution.referenced_groups[0] = self.active_group;
        errdefer {
            for (execution.groups) |group| if (group) |handle| {
                // A retained cold candidate is borrowed by this temporary cursor.
                if (self.preparing) |prepared| if (prepared.cold_candidate) |candidate| if (candidate.group.eql(handle)) continue;
                self.retireGroup(handle) catch {
                    self.last_error = .resource_limit;
                };
            };
            self.allocator.destroy(execution);
        }
        var commands: [2 * (assets.max_resident_fill_steps + 1)]rt.ScheduledCommand = undefined;
        var count: usize = 0;
        var source = self.active_group;
        var source_segment = self.rendering_segment;
        var target: ?rt.GroupHandle = null;
        for (execution_phases.slice(), 0..) |phase, index| {
            if ((phase.kind != .fill_entry and phase.kind != .target_entry) or phase.source_cursor != 0 or
                (phase.kind == .target_entry) != (index + 1 == execution_phases.count) or
                (projected == null and source != null and phase.stop_segment != source_segment)) return error.UnsupportedCapability;
            const segment_index = try find(generation.loaded.tables.segments, phase.segment);
            const window = entryWindow(execution_phases.slice(), index);
            const group = group: {
                if (cold_start) {
                    if (self.preparing.?.cold_candidate) |candidate| {
                        if (candidate.segment_index != segment_index or !std.meta.eql(candidate.entry, window)) return error.InvalidState;
                        break :group candidate.group;
                    }
                    const bindings = try generation.entryBindings(intent.request_id);
                    if (bindings.len != 4 or generation.loaded.tables.segments[segment_index].layers.count != 4) return error.UnsupportedCapability;
                    const copied: [4]planner.StreamBinding = bindings[0..4].*;
                    const handle = try self.prepareGroupForEntryRamp(generation, segment_index, phase.source_cursor, 0, intent.request_id, window, 0);
                    self.preparing.?.cold_candidate = .{ .generation = generation, .runtime_generation = generation.runtime_generation, .transport_epoch = generation.transport.transport_epoch, .request_id = intent.request_id, .segment_index = segment_index, .entry = window, .group = handle, .bindings = copied };
                    break :group handle;
                }
                break :group try self.prepareGroupForEntryRamp(generation, segment_index, phase.source_cursor, 0, intent.request_id, window, if (projected) |value| value.fade_frames else 0);
            };
            execution.groups[index] = group;
            try generation.bindEntryWindows(intent.request_id, window, group);
            execution.referenced_groups[index + 1] = group;
            execution.segments[index] = segment_index;
            try execution.cursor.bindGroup(phase.token, group, group.generation);
            if (phase.kind == .target_entry) target = group;
            const identity: rt.scheduler.CommandIdentity = .{ .command_id = count + 1, .token = phase.token, .phase_order = @intCast(index), .execute_frame = phase.execute_frame, .group_id = if (execution_phases.count == 1) id else index + 1 };
            if (source) |previous| {
                commands[count] = .{ .identity = identity, .payload = .{ .group_stop = .{ .group = previous, .release_frames = if (projected) |value| value.fade_frames else 0, .release_curve = if (projected) |value| (if (value.kind == .bound_equal_power_direct) .equal_power_out else .linear) else .linear } } };
                count += 1;
            }
            var start_identity = identity;
            start_identity.command_id = count + 1;
            commands[count] = .{ .identity = start_identity, .payload = .{ .group_start = .{ .group = group, .start_curve = if (projected) |value| (if (value.kind == .bound_equal_power_direct) .equal_power_in else .linear) else .linear } } };
            count += 1;
            source = group;
            source_segment = phase.segment;
        }
        // All groups, phase bindings, Director preflight and block references
        // exist before the sole publication. Any failure above publishes none.
        try generation.director.?.validateTargetEntry(intent, target_token);
        const start_frame = execution_phases.items[0].execute_frame;
        const end = try std.math.add(u64, execution_phases.items[execution_phases.count - 1].execute_frame, 1);
        const block = prepare: {
            if (cold_start) {
                var late: ?rt.scheduler.LivePrepareLateV1 = null;
                const handle = (self.tick_scope orelse return error.InvalidMode).prepareLiveColdStartV1(start_frame, end, commands[0], &late) catch |err| {
                    if (err == error.LateCommand) if (late) |witness| {
                        self.preparing.?.plan_id = try self.takePlan();
                        live.?.cold_start_deferred = .{ .control_tick = self.tick, .accepted_control_frame = frame, .ticket = request_ticket.?, .group = target.?, .plan_id = id, .prepare = witness };
                        return error.LiveColdStartPrepareDeferred;
                    };
                    return err;
                };
                break :prepare handle;
            }
            break :prepare try self.prepareSchedule(start_frame, end, commands[0..count]);
        };
        const plan_handle = self.schedulePlan(block) catch |err| {
            _ = try self.cancelSchedule(.{ .target = block, .requested_frame = frame });
            try self.releaseSchedule(block);
            return err;
        };
        if (loop_tail != null) {
            self.tickHook(.before_loop_crossfade_publish);
            // Preparation may allocate/reserve while Render advances. Recheck
            // the original fixed proof immediately before the sole publication.
            // Failed checks release the unpublished block and all candidate
            // groups through the same error-defer transaction as other failures.
            const still_ready = self.loopCrossfadePublicationReady(generation, &live_source_tail, plan) catch |err| {
                _ = try self.cancelSchedule(.{ .target = block, .requested_frame = frame });
                try self.releaseSchedule(block);
                return err;
            };
            if (!still_ready) {
                _ = try self.cancelSchedule(.{ .target = block, .requested_frame = frame });
                try self.releaseSchedule(block);
                self.preparing.?.plan_id = try self.takePlan();
                return error.StreamNotReady;
            }
        }
        self.submitSchedule(block) catch |err| {
            _ = try self.cancelSchedule(.{ .target = block, .requested_frame = frame });
            try self.releaseSchedule(block);
            return err;
        };
        generation.director.?.bindTargetEntry(intent, target_token) catch unreachable;
        self.pending = .{ .generation = generation, .block = block, .plan = plan_handle, .token = target_token, .operation = .transition, .intent = intent, .target_group = target, .transition = execution, .source_fill = self.confirmed_fill, .request_ticket = request_ticket };
        generation.retireUnboundRequestWindows(intent.request_id);
        self.preparing = null;
        if (self.active_group == null) self.state = .starting;
        self.receipt(.{ .plan_prepared = .{ .token = target_token, .state = .prepared, .observed_render_frame = frame } });
    }

    fn prepareMusicContinuity(self: *MusicRuntime, request: rt.ControlRuntime.MusicContinuityRequest) !rt.source_continuity.Handle {
        // Only the explicit fill-state chunk profile records this existing
        // transaction. The lower owner still validates every source and hash.
        self.requireRecordedContinuityRequestV1(request) catch self.markAuthoritativeTraceIncompleteV1();
        if (self.tick_scope) |scope| return scope.prepareMusicContinuity(self.allocator, request);
        return self.control.prepareMusicContinuity(self.allocator, request);
    }
    fn releaseMusicContinuity(self: *MusicRuntime, handle: rt.source_continuity.Handle) !void {
        if (self.tick_scope) |scope| return scope.releaseMusicContinuity(handle);
        return self.control.releaseMusicContinuity(handle);
    }
    fn musicContinuityResult(self: *MusicRuntime, handle: rt.source_continuity.Handle) !?rt.music_group.ContinuityCoordinate {
        if (self.tick_scope) |scope| return scope.musicContinuityResult(handle);
        return self.control.musicContinuityResult(handle);
    }
    fn hasBoundaryStopV1(self: *const MusicRuntime) bool {
        return self.action_boundary_stop != null or (self.pending != null and self.pending.?.boundary_stop != null);
    }
    fn boundaryStopAcceptanceSourceV1(self: *MusicRuntime) !rt.MusicGroupSource {
        return self.boundaryStopSourceV1(null, true) catch |err| switch (err) {
            // A transient observation gap may own an unpublished action. Every
            // other physical/clock error rejects before mutating Director.
            error.StreamNotReady => self.boundaryStopSourceV1(null, false),
            else => return err,
        };
    }
    /// Control-only admission. Immutable source identity can be established
    /// before a coherent live observation is available; publication requires
    /// both, and retries preserve the original action's accepted position.
    fn boundaryStopSourceV1(self: *MusicRuntime, binding: ?BoundaryStop, coherent: bool) !rt.MusicGroupSource {
        if (!self.usesIntegratedTickV1() or self.config_v1.boundary_stop == null) return error.UnsupportedOperation;
        const generation = self.generation orelse return error.InvalidState;
        const group = self.active_group orelse return error.InvalidState;
        if (self.state != .playing or generation.transport.paused or generation.director.?.paused or
            self.unloading or self.shutdown_requested.load(.acquire)) return error.InvalidState;
        if (self.pending != null or self.preparing != null or self.fill_continuation != null or
            self.resuming_request != null or self.confirmed_fill != null or self.cleanup_stop_pending or
            self.resident_state != null or self.live_reload != null or self.preview_seek != null or self.reload.ownsResources() or
            self.deviceRecoveryActive() or generation.director.?.desired != null or
            generation.director.?.pendingCount() != 0) return error.RequestInProgress;
        if (self.crossfade_outgoing != null or self.outgoing_generation.load(.acquire) != null or
            generation.layer_owner != null or generation.loaded.bus_graph != null or self.policy_storage != null or self.event_adapter != null or
            self.public_recording.phase != .disabled or self.causal_sink != null or
            self.active_source_incarnation != 1 or self.activeSourceSwitchV1() != null) return error.UnsupportedCapability;
        for (self.retired_groups) |retired| if (retired != null) return error.RequestInProgress;
        const source = if (self.tick_scope) |scope| try scope.musicGroupSource(group) else try self.control.musicGroupSource(group);
        if (!source.group.eql(group) or source.bank_generation != generation.runtime_generation or
            source.source_incarnation != self.active_source_incarnation or source.segment != self.rendering_segment or
            source.degraded) return error.UnsupportedCapability;
        const segment = generation.loaded.tables.segments[try find(generation.loaded.tables.segments, source.segment)];
        if (generation.loaded.tables.segments[generation.director.?.committed_segment].key.id != segment.key.id or
            segment.fallback_segment != s.none or segment.emergency != 0 or segment.loop_end <= segment.loop_start or
            source.frames != segment.frames or source.layer_count != segment.layers.count) return error.UnsupportedCapability;
        const loop = source.loop orelse return error.UnsupportedCapability;
        const map = generation.solver.?.maps[segment.tempo];
        if (loop.start != segment.loop_start or loop.end != segment.loop_end or
            !std.meta.eql(generation.transport.map, map) or map.tempo.loop_present != 1 or
            try map.frameAtTick(map.tempo.loop_start_tick) != loop.start or
            try map.frameAtTick(map.tempo.loop_end_tick) != loop.end) return error.UnsupportedCapability;
        if (binding) |bound| {
            if (!bound.group.eql(group) or bound.bank_generation != generation.runtime_generation or
                bound.source_incarnation != source.source_incarnation or bound.segment != source.segment or
                !std.meta.eql(bound.transport, generation.transport)) return error.InvalidState;
        }
        const terminal = if (self.tick_scope) |scope| try scope.musicGroupTerminal(group) else try self.control.musicGroupTerminal(group);
        if (terminal) |ended| return if (ended.reason == .underrun) error.StreamUnderrun else error.InvalidState;
        if (coherent) {
            const observed = self.musicVoiceObservation(group) catch |err| switch (err) {
                error.InvalidState => return error.StreamNotReady,
                else => return err,
            };
            if (!observed.group.eql(group) or observed.generation != source.bank_generation or
                observed.source_incarnation != source.source_incarnation or observed.transport_epoch != generation.transport.transport_epoch or
                observed.paused or observed.state != .playing or observed.layer_count != source.layer_count or
                !std.meta.eql(observed.loop, source.loop)) return error.InvalidState;
            // Compare the actual source coordinate without rounding through a
            // musical tick. Both representations at an exact loop wrap agree.
            const elapsed = try std.math.add(u64, observed.cursor, try std.math.mul(u64, observed.loop_epoch, loop.end - loop.start));
            if (elapsed != try generation.transport.elapsedAt(observed.frame)) return error.InvalidState;
        }
        return source;
    }
    fn cancelFutureBoundaryStopV1(self: *MusicRuntime) !void {
        if (self.pending) |*pending| if (pending.boundary_stop != null and !pending.effective and pending.invalidation == null) {
            pending.invalidation = try self.cancelSchedule(.{ .target = pending.block, .requested_frame = self.control.scheduled.render_frame.load(.acquire) });
        };
    }
    fn scheduleOperation(self: *MusicRuntime, operation: Operation, request_ticket: ?v1.RequestTicketV1, boundary: ?BoundaryStop, live: ?*LiveTickAttempt) !void {
        if (self.pending != null) return error.InvalidState;
        const generation = self.generation.?;
        if (boundary != null and operation != .stop) return error.InvalidState;
        if (boundary != null) _ = self.boundaryStopSourceV1(boundary, true) catch |err| return boundaryStopError(err);
        try generation.retainPending();
        errdefer generation.releasePending();
        const group = self.active_group.?;
        const source = if (self.tick_scope) |scope| try scope.musicGroupSource(group) else try self.control.musicGroupSource(group);
        // Stop owns the group lifetime, not a source cursor. It must remain
        // schedulable while live fallback adoption awaits a coherent observation.
        if (operation != .stop) {
            const observed = self.musicVoiceObservation(group) catch |err| switch (err) {
                error.InvalidState => return error.StreamNotReady,
                else => return err,
            };
            if (source.source_incarnation != observed.source_incarnation or source.source_incarnation != self.active_source_incarnation) return error.StreamNotReady;
        }
        var streamed = false;
        for (source.layers[0..source.layer_count]) |layer| streamed = streamed or layer.streamed;
        const bound_gain = if (generation.layer_owner) |owner| (try owner.getSource(group, source.source_incarnation)) != null else false;
        var continuation: ?rt.source_continuity.Handle = null;
        errdefer if (continuation) |handle| self.releaseMusicContinuity(handle) catch {};
        const next_epoch = if (operation == .stop) generation.transport.transport_epoch else try std.math.add(u64, generation.transport.transport_epoch, 1);
        // The same immutable all-layer transaction preserves source-clock M2
        // progress for resident bindings; streamed bindings additionally retain
        // their real old/new physical sources through Worker retirement.
        if ((streamed or bound_gain or source.degraded) and operation != .stop) {
            var sources: [rt.music_group.max_layers]?rt.streaming.Source = @splat(null);
            const segment_index = try find(generation.loaded.tables.segments, source.segment);
            const segment = generation.loaded.tables.segments[segment_index];
            if (operation == .resume_music and streamed) {
                const pause = self.paused_coordinate orelse return error.InvalidState;
                const request = (request_ticket orelse return error.InvalidState).request_id;
                const scope = self.tick_scope orelse return error.InvalidMode;
                self.resuming_request = request;
                try generation.prepareResumeWindows(request, group, segment_index, pause, next_epoch, try self.planningFrontier());
                try generation.prefetchRequestWindows(request, self.control_frame);
                const readiness = generation.readiness.?;
                try readiness.collectTick(scope, generation.requestBindings(request), self.config.context, generation.director.?.request_epoch);
                var ready = readiness.complete;
                for (readiness.observations[0..readiness.count], readiness.failures[0..readiness.count]) |observation, failure| {
                    if (failure != .none) return error.SourceReadFailed;
                    ready = ready and observation.payload.readiness_snapshot.expected.ready;
                }
                for (generation.loaded.tables.layers[segment.layers.first..][0..segment.layers.count], 0..) |layer, i| {
                    if (generation.loaded.tables.sounds[layer.sound].storage == .streaming) {
                        sources[i] = try generation.sourceFor(request, layer.key.id);
                        ready = ready and sources[i].?.ready(try std.math.add(u64, layer.source_start, pause.cursor), pause.loop_epoch);
                    }
                }
                if (!ready) return error.StreamNotReady;
            }
            continuation = try self.prepareMusicContinuity(.{ .group = group, .source_incarnation = source.source_incarnation, .paused = operation == .pause, .next_transport_epoch = next_epoch, .expected_pause = if (operation == .resume_music) self.paused_coordinate else null, .sources = if (operation == .resume_music) sources[0..segment.layers.count] else &.{} });
        }
        const id = try self.takePlan();
        const frontier = try self.planningFrontier();
        const execute = if (boundary) |bound|
            (generation.transport.strictNext(switch (bound.kind) {
                .next_beat => .beat,
                .next_bar => .bar,
                else => unreachable, // Immutable ConfigV1 was validated.
            }, bound.accepted.accepted_control_frame, .{ .earliest_submit_frame = frontier }) catch |err| return boundaryStopError(err)).frame
        else
            frontier;
        const end = try std.math.add(u64, execute, 1);
        const token: api.PhaseToken = .{ .context = @enumFromInt(self.config.context), .transport_epoch = @enumFromInt(generation.transport.transport_epoch), .asset_generation = self.bankGeneration(), .plan_id = @enumFromInt(id), .plan_epoch = @enumFromInt(1), .phase_id = @enumFromInt(1) };
        const payload: rt.ScheduledPayload = if (operation == .stop) .{ .group_stop = .{ .group = group, .release_frames = rt.scheduler.default_profile.emergency_ramp_frames } } else .{ .group_pause = .{ .group = group, .paused = operation == .pause, .next_transport_epoch = next_epoch, .continuity = continuation } };
        const command: rt.ScheduledCommand = .{ .identity = .{ .command_id = 1, .token = token, .phase_order = 0, .execute_frame = execute, .group_id = id }, .payload = payload };
        var stop_commands: [2]rt.ScheduledCommand = .{ command, undefined };
        var stop_count: usize = 1;
        if (operation == .stop) if (self.crossfade_outgoing) |outgoing| {
            if (outgoing.eql(group)) return error.InvalidState;
            var outgoing_identity = command.identity;
            outgoing_identity.command_id = 2;
            stop_commands[1] = .{ .identity = outgoing_identity, .payload = .{ .group_stop = .{
                .group = outgoing,
                .release_frames = rt.scheduler.default_profile.emergency_ramp_frames,
                .allow_crossfade_source_stop = true,
            } } };
            stop_count = 2;
        };
        self.tickHook(.before_operation_schedule_prepare);
        const initial_source = if (self.device_stream_origin) |origin|
            origin.generation == generation.runtime_generation and origin.group.eql(group) and self.active_source_incarnation == 1 and source.source_incarnation == 1
        else
            false;
        const block = prepare: {
            if (live) |attempt| if (operation == .stop and request_ticket != null and boundary == null and stop_count == 1 and continuation == null and self.crossfade_outgoing == null and initial_source) {
                var late: ?rt.scheduler.LivePrepareLateV1 = null;
                const scope = self.tick_scope orelse return error.InvalidMode;
                const handle = scope.prepareLiveStopV1(execute, end, stop_commands[0], &late) catch |err| {
                    // Only the same-call scheduler pre-allocation guard may
                    // defer. Its temporary references unwind normally; the
                    // consumed plan ID and real late counter are never rewound.
                    if (err == error.LateCommand) if (late) |witness| {
                        attempt.stop_deferred = .{ .control_tick = self.tick, .accepted_control_frame = self.control_frame, .ticket = request_ticket.?, .group = group, .plan_id = id, .prepare = witness };
                        return error.LiveStopPrepareDeferred;
                    };
                    return err;
                };
                break :prepare handle;
            };
            break :prepare try self.prepareSchedule(execute, end, stop_commands[0..stop_count]);
        };
        self.tickHook(.after_operation_schedule_prepare);
        // The scheduler now owns the descriptor through actual terminal release.
        const bound_continuation = continuation;
        continuation = null;
        const plan_handle = self.schedulePlan(block) catch |err| {
            _ = try self.cancelSchedule(.{ .target = block, .requested_frame = self.control.scheduled.render_frame.load(.acquire) });
            try self.releaseSchedule(block);
            return err;
        };
        self.submitSchedule(block) catch |err| {
            _ = try self.cancelSchedule(.{ .target = block, .requested_frame = self.control.scheduled.render_frame.load(.acquire) });
            try self.releaseSchedule(block);
            return err;
        };
        self.pending = .{ .generation = generation, .block = block, .plan = plan_handle, .token = token, .operation = operation, .request_ticket = request_ticket, .continuity = bound_continuation, .source_incarnation = source.source_incarnation, .boundary_stop = boundary, .operation_groups = if (stop_count == 2) .{ group, self.crossfade_outgoing } else @splat(null) };
        if (operation == .resume_music) self.resuming_request = null;
    }

    fn planningFrontier(self: *MusicRuntime) !u64 {
        // Use this exact real sample for planning. A paused offline pump has
        // horizon == completed frame; normal safety lookahead is still required.
        const frontier = try self.control.earliestPlanFrame();
        const offline_frontier = try std.math.add(u64, self.control_frame, rt.scheduler.default_profile.min_plan_lead_frames + rt.scheduler.default_profile.late_race_budget_frames);
        if (frontier != offline_frontier) self.markSerialTraceIncompleteV1();
        return frontier;
    }

    fn retireGroup(self: *MusicRuntime, handle: rt.GroupHandle) !void {
        for (&self.retired_groups) |*entry| if (entry.* == null) {
            entry.* = handle;
            return;
        };
        return error.ResourceLimitExceeded;
    }
    fn recordCollectedAdmissions(self: *MusicRuntime, admissions: []trace.schema.Admission) void {
        if (self.public_recording.phase == .active and self.public_recording.profile == .stream_fill_state_serial_v1) {
            // The shared pre-collection entry has already acquired both owners
            // and visibility. A late admission would violate serialized driving.
            if (admissions.len != 0) self.failRecordingV1();
            return;
        }
        if (self.public_recording.phase == .active and public_replay.isChunkStream(self.public_recording.profile)) {
            self.recordStreamCollectedAdmissionsV1(admissions) catch self.failRecordingV1();
            return;
        }
        // These are acquired immutable facts, not expected replay outcomes.
        // Render can admit cancellation before the command it cancels. The
        // bounded profile assigns positions in that actual gate/order, rather
        // than the order in which Control reads the two independent slots.
        // Compatibility retains its historical collection order and bytes.
        if (self.public_recording.phase == .active and admissions.len == 2) {
            if (admissions[1].gate < admissions[0].gate or
                (admissions[1].gate == admissions[0].gate and admissions[1].gate_order < admissions[0].gate_order))
                std.mem.swap(trace.schema.Admission, &admissions[0], &admissions[1]);
            const first = admissions[0];
            const second = admissions[1];
            if (first.batch_id == second.batch_id or first.frame > second.frame or
                (first.gate == second.gate and (first.frame != second.frame or first.gate_order >= second.gate_order or first.commit_horizon != second.commit_horizon)))
            {
                self.failRecordingV1();
                return;
            }
        }
        for (admissions) |admission| self.input(.{ .position = self.position(), .payload = .{ .admission = admission } });
    }
    /// Profile 4 owns at most one Pending and one ResidentState. Each can
    /// contribute one repeat-observable block admission and one consuming
    /// invalidation result. Acquire all four before touching the visibility
    /// FIFO, installing a restore, releasing a block or advancing any phase.
    fn collectFillRecordingAdmissionsV1(self: *MusicRuntime) !void {
        var admissions: [4]trace.schema.Admission = undefined;
        var admission_count: usize = 0;
        var cancellations: [2]rt.scheduler.trace.ScheduleRecord = undefined;
        var cancellation_count: usize = 0;
        var acquired: ?struct { token: api.PhaseToken, frame: u64 } = null;
        // A cancellationResult consumes actual scheduler references. Preserve
        // its receipt even if a later acquisition or recorder retention fails;
        // the owner handle is cleared immediately, so no old collector repops it.
        defer {
            if (acquired) |value| self.receipt(.{ .plan_acquired = .{ .token = value.token, .state = .acquired, .observed_render_frame = value.frame } });
            for (cancellations[0..cancellation_count]) |record| self.observe(.{ .event = record });
        }
        if (self.pending) |*pending| {
            if (!pending.admission_seen) if (try self.scheduleAdmission(pending.block)) |admission| {
                admissions[admission_count] = admission;
                admission_count += 1;
                pending.admission_seen = true;
                acquired = .{ .token = pending.token, .frame = admission.frame };
            };
            if (pending.invalidation) |handle| if (try self.cancellationResult(handle)) |result| {
                pending.invalidation = null;
                admissions[admission_count] = result.admission;
                admission_count += 1;
                cancellations[cancellation_count] = result.receipt;
                cancellation_count += 1;
            };
        }
        if (self.resident_state) |state| {
            if (state.block) |block| if (!state.admission_seen) if (try self.scheduleAdmission(block)) |admission| {
                admissions[admission_count] = admission;
                admission_count += 1;
                state.admission_seen = true;
            };
            if (state.invalidation) |handle| if (try self.cancellationResult(handle)) |result| {
                state.invalidation = null;
                admissions[admission_count] = result.admission;
                admission_count += 1;
                cancellations[cancellation_count] = result.receipt;
                cancellation_count += 1;
            };
        }
        try self.mergeStreamCollectedAdmissionsV1(admissions[0..admission_count]);
    }
    fn recordStreamCollectedAdmissionsV1(self: *MusicRuntime, scheduled: []const trace.schema.Admission) !void {
        // Legacy stream profiles retain their exact two-receipt collection path.
        if (scheduled.len > 2) return error.InvalidState;
        var commands: [2]trace.schema.Admission = undefined;
        @memcpy(commands[0..scheduled.len], scheduled);
        try self.mergeStreamCollectedAdmissionsV1(commands[0..scheduled.len]);
    }
    fn mergeStreamCollectedAdmissionsV1(self: *MusicRuntime, commands: []trace.schema.Admission) !void {
        if (self.tick_scope) |scope| {
            try scope.requirePhase(.collect);
        } else if (!self.public_recording.state_host or !public_replay.isStateProfile(self.public_recording.profile) or !self.control_guard.load(.acquire)) return error.InvalidState;
        if (commands.len > 4) return error.InvalidState;
        const Order = struct {
            fn before(a: trace.schema.Admission, b: trace.schema.Admission) bool {
                return a.gate < b.gate or (a.gate == b.gate and a.gate_order < b.gate_order);
            }
        };
        // Only scheduler scratch is sorted. Visibility stays in its bounded
        // Render FIFO; no duration-sized allocation or FIFO copy is required.
        for (0..commands.len) |index| {
            var cursor = index;
            while (cursor != 0 and Order.before(commands[cursor], commands[cursor - 1])) : (cursor -= 1)
                std.mem.swap(trace.schema.Admission, &commands[cursor], &commands[cursor - 1]);
        }
        var streamed = try self.pollRecordingVisibilityV1();
        var index: usize = 0;
        var previous: ?trace.schema.Admission = null;
        var count: usize = 0;
        const maximum = if (self.public_recording.mode == .chunks)
            try std.math.add(usize, self.generation.?.service.?.profile.visibility_capacity, commands.len)
        else
            self.inputs.len;
        while (index < commands.len or streamed != null) {
            if (count == maximum) return error.IncompleteTrace;
            const take_stream = streamed != null and (index == commands.len or Order.before(streamed.?, commands[index]));
            const admission = if (take_stream) streamed.? else commands[index];
            if (previous) |old| {
                if (old.batch_id == admission.batch_id or old.frame > admission.frame or !Order.before(old, admission) or
                    (old.gate == admission.gate and (old.frame != admission.frame or old.commit_horizon != admission.commit_horizon))) return error.InvalidOrder;
            }
            self.input(.{ .position = self.position(), .payload = .{ .admission = admission } });
            previous = admission;
            count += 1;
            if (take_stream) streamed = try self.pollRecordingVisibilityV1() else index += 1;
        }
    }
    fn pollRecordingVisibilityV1(self: *MusicRuntime) !?trace.schema.Admission {
        if (self.tick_scope) |scope| return scope.pollStreamVisibility();
        if (!self.public_recording.state_host or !public_replay.isStateProfile(self.public_recording.profile) or !self.control_guard.load(.acquire)) return error.InvalidState;
        return self.generation.?.service.?.pollVisibility();
    }
    fn collectionFrame(self: *MusicRuntime, kind: rt.readiness_witness.AcquisitionKind) rt.RuntimeError!u64 {
        // The Control-owned attachment is pinned throughout this collection.
        // Preserve the original acquire without new scope-validation loads
        // when this finite diagnostic extension has not been enabled.
        if (self.tick_scope) |scope| {
            if (self.control.live_semantic_hooks != null) return scope.collectionFrame(kind);
            if (@import("builtin").is_test) if (self.control.test_owned_control_facts != null)
                return scope.collectionFrame(kind);
            if (self.control.readiness_binding) |binding| {
                if (binding.bridge.manifest.capture_acquisitions) return scope.collectionFrame(kind);
            }
        }
        return self.control.scheduled.render_frame.load(.acquire);
    }
    fn collect(self: *MusicRuntime) !void {
        try self.collectPreviewSeek();
        if (self.previewSeekFrozen()) return;
        try self.collectDeviceRecovery();
        try self.collectLiveReload();
        if (self.live_reload) |state| if (state.lower != null and !state.committed) return;
        try self.collectResidentState();
        if (self.resident_state) |state| if (state.kind == .restore and state.lower != null and !state.terminal) {
            if (self.public_recording.phase == .active and self.public_recording.profile == .stream_direct_state_serial_v1) try self.recordStreamCollectedAdmissionsV1(&.{});
            return;
        };
        var frame = try self.collectionFrame(.collect_frame);
        self.control_frame = frame;
        self.collectHook(.after_frame_observation);
        var admissions: [2]trace.schema.Admission = undefined;
        var admission_count: usize = 0;
        // Positions are assigned after acquiring the phase/frontier observation,
        // so admission facts and this tick's closed request batch share one real
        // completed-frame observation. No applied phase fabricates completed PCM.
        defer self.recordCollectedAdmissions(admissions[0..admission_count]);
        if (self.pending) |*p| {
            // Receipt-side tables/state belong to the plan's retained generation.
            // This stage never swaps active generations; future activation must
            // separately classify stale musical commits and resource retirement.
            std.debug.assert(self.generation == p.generation);
            // Render publishes command/phase data before release-storing terminal.
            // Acquire terminal BEFORE reading those data. If terminal arrives
            // later, retain this block until the next tick rather than mistaking
            // a phase not yet observed for a cancellation or dropping receipts.
            const terminal = try self.scheduleResult(p.block);
            self.collectHook(.after_schedule_result);
            if (!p.admission_seen) if (try self.scheduleAdmission(p.block)) |admission| {
                admissions[admission_count] = admission;
                admission_count += 1;
                p.admission_seen = true;
                self.receipt(.{ .plan_acquired = .{ .token = p.token, .state = .acquired, .observed_render_frame = admission.frame } });
            };
            if (p.invalidation) |handle| if (try self.cancellationResult(handle)) |result| {
                admissions[admission_count] = result.admission;
                admission_count += 1;
                self.observe(.{ .event = result.receipt });
                p.invalidation = null;
            };
            while (try self.pollExecutionReceipt(p.block, &p.receipt_cursor)) |record| self.observe(.{ .event = record });
            frame = try self.collectionFrame(.receipts_frame);
            self.control_frame = frame;
            while (true) {
                var next_phase_cursor = p.phase_cursor;
                const phase = (try self.pollPlanPhase(p.plan, &next_phase_cursor)) orelse break;
                if (p.operation != .transition) p.phase_cursor = next_phase_cursor;
                // The phase acquire follows its completed gate frontier store.
                // Refresh the actual frontier; never evaluate a new clock using
                // the older sample taken before this phase became visible.
                frame = try self.collectionFrame(.phase_frame);
                std.debug.assert(frame >= phase.effective_frame);
                self.control_frame = frame;
                switch (p.operation) {
                    .transition => {
                        const execution = p.transition.?;
                        const index = for (execution.cursor.phases.slice(), 0..) |entry, i| {
                            if (std.meta.eql(entry.token, phase.token)) break i;
                        } else return error.InvalidState;
                        const definition = execution.cursor.phases.items[index];
                        const group = execution.groups[index] orelse return error.InvalidState;
                        const bar = if (self.active_group != null) try self.barAt(phase.effective_frame) else p.generation.director.?.current_bar;
                        var entered = clock.Clock.init(p.generation.solver.?.maps[p.generation.loaded.tables.segments[execution.segments[index]].tempo], phase.effective_frame);
                        entered.anchor_elapsed = definition.source_cursor;
                        entered.transport_epoch = phase.token.transport_epoch.value();
                        entered.device_epoch = p.generation.transport.device_epoch;
                        // A late collection can acquire A, B and target together.
                        // Never extrapolate A's musical bars past B's actual entry.
                        var observed_frame = if (index + 1 < execution.cursor.phases.count) @min(frame, execution.cursor.phases.items[index + 1].execute_frame) else frame;
                        if (try self.musicGroupSourceSwitch(group)) |fact| observed_frame = @min(observed_frame, fact.frame);
                        const terminal_group = if (self.tick_scope) |scope| try scope.musicGroupTerminal(group) else try self.control.musicGroupTerminal(group);
                        if (terminal_group) |ended| observed_frame = @min(observed_frame, ended.boundary_frame);
                        const observed_bar = try std.math.add(u64, bar, try director.Director.barAtClock(entered, observed_frame));
                        // A rejected arithmetic observation must not consume
                        // either durable scheduler or private plan progress.
                        try execution.cursor.receipt(phase);
                        p.phase_cursor = next_phase_cursor;
                        try p.generation.director.?.advance(frame, observed_bar);
                        if (definition.kind == .target_entry) {
                            try p.generation.director.?.targetEntryReceipt(phase, bar);
                            p.effective = true;
                        }
                        const initial_direct = !self.device_stream_entry_seen and !self.has_executed and self.active_group == null and
                            execution.cursor.phases.count == 1 and definition.kind == .target_entry and definition.source_cursor == 0 and
                            execution.crossfade == null and execution.fill_route == null;
                        if (self.active_group) |old| {
                            _ = try self.collectSourceSwitchHistoryV1(old, p.generation);
                            try self.retireGroup(old);
                            if (execution.crossfade != null) self.crossfade_outgoing = old;
                        }
                        // Once any ordinary entry has executed, a later DIRECT
                        // or stop/new-start never becomes an initial source.
                        self.device_stream_entry_seen = true;
                        self.device_stream_origin = if (initial_direct)
                            .{ .generation = p.generation.runtime_generation, .group = group }
                        else
                            null;
                        self.active_group = group;
                        self.confirmed_fill = if (definition.kind == .fill_entry) .{ .group = group, .entry = phase, .occurrence = execution.occurrences[index], .source_exit_cue = execution.source_exit_cue, .fill_route = execution.fill_route, .path_id = execution.path_id } else null;
                        execution.groups[index] = null; // Pending -> active custody.
                        self.active_source_incarnation = 1;
                        self.rendering_segment = definition.segment;
                        p.generation.transport = entered;
                        self.bar_offset = bar;
                        self.state = .playing;
                        self.has_executed = true;
                    },
                    .pause => {
                        if (p.continuity) |handle| {
                            const coordinate = (try self.musicContinuityResult(handle)) orelse return error.InvalidState;
                            if (p.source_incarnation == self.active_source_incarnation) self.paused_coordinate = coordinate;
                            p.generation.retireGroupWindows(self.active_group.?);
                        }
                        if (p.source_incarnation != self.active_source_incarnation) {
                            // The old phase is still an executed receipt, but its
                            // clock mutation cannot apply to the replacement.
                            p.effective = true;
                            self.receipt(.{ .phase_terminal = phase });
                            continue;
                        }
                        try p.generation.transport.pause(phase.effective_frame);
                        p.generation.director.?.transport_epoch = p.generation.transport.transport_epoch;
                        p.generation.director.?.paused = true;
                        self.state = .paused;
                        if (self.fill_continuation) |*continuation| if (continuation.suspended) |handle| {
                            try p.generation.director.?.refreshSuspendedPause(handle);
                            continuation.resume_request = null;
                        };
                        // Only an actual successful music pause can revoke
                        // future stinger plans. Rejected requests/phases leave
                        // their original acceptance, deadline and schedule intact.
                        self.deferFutureStingers();
                    },
                    .resume_music => {
                        if (p.source_incarnation != self.active_source_incarnation) {
                            // A late original resume retains its truthful phase
                            // and physical window cleanup, never its old clock.
                            if (p.continuity != null) {
                                // The actual executed resume's windows remain
                                // attributable to this source lifetime while
                                // Worker cancellation/close is still pending.
                                p.generation.bindExecutedRequestWindows(p.request_ticket.?.request_id, self.active_group.?);
                                p.generation.retireRequestWindows(p.request_ticket.?.request_id);
                            }
                            p.effective = true;
                            self.receipt(.{ .phase_terminal = phase });
                            continue;
                        }
                        if (p.continuity != null) {
                            p.generation.bindRequestWindows(p.request_ticket.?.request_id, self.active_group.?);
                            self.paused_coordinate = null;
                        }
                        try p.generation.transport.resumeAt(phase.effective_frame);
                        p.generation.director.?.transport_epoch = p.generation.transport.transport_epoch;
                        p.generation.director.?.paused = false;
                        self.state = .playing;
                        if (self.fill_continuation) |*continuation| {
                            // A newer pause/stop can win acceptance while this
                            // already-linearized resume is still uncollected.
                            // Its action keeps priority and owns the next phase.
                            if (self.action == .pause or self.action == .stop) {
                                p.effective = true;
                                self.receipt(.{ .phase_terminal = phase });
                                continue;
                            }
                            std.debug.assert(continuation.intent == null);
                            if (continuation.generation != p.generation or self.active_group == null or !continuation.group.eql(self.active_group.?)) return error.InvalidState;
                            // Keep the suspension until prepare, after this
                            // tick's new requests have had their normal priority.
                            // The resume ticket below remains terminal now.
                            continuation.resume_request = p.generation.director.?.last_request_id;
                        }
                    },
                    .stop => {
                        // Render may have switched and then executed this stop
                        // before Control acquired either fact. Keep that durable
                        // source history before clearing the public active group.
                        _ = try self.collectSourceSwitchHistoryV1(self.active_group.?, p.generation);
                        self.paused_coordinate = null;
                        try self.retireGroup(self.active_group.?);
                        self.device_stream_origin = null;
                        self.active_group = null;
                        self.confirmed_fill = null;
                        self.active_source_incarnation = 0;
                        self.rendering_segment = 0;
                        const epoch = p.generation.transport.transport_epoch;
                        p.generation.transport = clock.Clock.init(p.generation.transport.map, phase.effective_frame);
                        p.generation.transport.device_epoch = self.device_accepted_epoch.load(.acquire);
                        p.generation.transport.transport_epoch = epoch;
                        p.generation.director.?.paused = false;
                        self.bar_offset = p.generation.director.?.current_bar;
                        self.state = .stopping;
                        self.cleanup_stop_pending = false;
                    },
                }
                if (p.operation != .transition) p.effective = true;
                self.receipt(.{ .phase_terminal = phase });
            }
            self.collectHook(.after_phase_poll);
            if (terminal) |result| {
                if (p.invalidation != null) return;
                if (self.device_stream_candidate) |candidate| if (candidate.cleanup_stop) |block| if (std.meta.eql(block, p.block)) {
                    if (p.operation != .stop or p.request_ticket != null or p.generation != candidate.generation) return error.InvalidState;
                    // This recovery-owned exact stop can also be fenced before
                    // its queued Control reference is consumed. Defer its one-
                    // time terminal handling, without changing ordinary paths.
                    const slot = try self.control.scheduled.getObserved(block, null);
                    if (slot.state.load(.acquire) != .terminal) return error.InvalidState;
                    if (slot.queue_refs != 0 or slot.invalidation_refs != 0) return;
                };
                if (p.transition) |execution| {
                    if (!p.effective) {
                        // Drain the exact executed prefix first, then acquire the
                        // scheduler's actual cancelled/rejected suffix. A mere
                        // cancellation request never supplies these outcomes.
                        if (result.disposition != .cancelled and result.disposition != .superseded_after_partial) return;
                        const prefix = execution.cursor.executedCount();
                        if (result.cancellation) |cancel| {
                            if (execution.scheduler_prefix_offset == 0) {
                                try execution.cursor.cancellation(cancel);
                            } else {
                                const offset = execution.scheduler_prefix_offset;
                                if (cancel.executed_prefix_count != prefix + offset or cancel.cancelled_suffix_start != prefix + offset or cancel.cancelled_suffix_count != execution.cursor.phases.count - prefix) return error.InvalidState;
                                for (prefix..execution.cursor.phases.count) |index| try execution.cursor.receipt(.{ .token = execution.cursor.phases.items[index].token, .outcome = .cancelled, .effective_frame = cancel.effective_frame });
                            }
                        } else {
                            // Admission/atomic-group rejection has real command
                            // receipts even without a separate invalidation record.
                            for (prefix..execution.cursor.phases.count) |index| {
                                const token = execution.cursor.phases.items[index].token;
                                const record = for (result.receipts[0..result.count]) |row| {
                                    if (row.phase_id == token.phase_id.value() and (row.result == .cancelled or row.result == .rejected)) break row;
                                } else return error.InvalidState;
                                try execution.cursor.receipt(.{ .token = token, .outcome = .cancelled, .effective_frame = record.effective_frame });
                            }
                        }
                        const rejected = try execution.cursor.terminalReceipt(execution.cursor.phases.count - 1);
                        try p.generation.director.?.advance(frame, if (self.active_group != null) try self.barAt(frame) else p.generation.director.?.current_bar);
                        // A resumed suffix may have entered none of its own
                        // phases while its source fill was genuinely entered by
                        // an older plan. Preserve that full-handle provenance;
                        // prefix=0 is not evidence that no fill is audible.
                        const continued_fill = if (p.source_fill) |source| self.confirmed_fill != null and self.active_group != null and
                            source.group.eql(self.active_group.?) and source.group.eql(self.confirmed_fill.?.group) and
                            std.meta.eql(source.entry, self.confirmed_fill.?.entry) and source.entry.outcome == .executed and
                            source.entry.token.asset_generation.value() == p.generation.runtime_generation and self.active_source_incarnation == 1 else false;
                        const retain_fill = (prefix != 0 or continued_fill) and self.action == .pause and !self.unloading and !self.shutdown_requested.load(.acquire);
                        if (retain_fill) {
                            std.debug.assert(self.fill_continuation == null and self.active_group != null);
                            try p.generation.retainPending();
                            const suspended = p.generation.director.?.suspendTargetEntry(rejected) catch |err| {
                                p.generation.releasePending();
                                return err;
                            };
                            self.fill_continuation = .{ .generation = p.generation, .group = self.active_group.?, .suspended = suspended };
                        } else {
                            if (p.generation.director.?.isCurrent(p.intent.?)) p.generation.director.?.desired = null;
                            try p.generation.director.?.targetEntryReceipt(rejected, p.generation.director.?.current_bar);
                            if (self.confirmed_fill) |fill| {
                                if (self.active_group == null or !fill.group.eql(self.active_group.?) or fill.entry.outcome != .executed or
                                    fill.entry.token.asset_generation.value() != p.generation.runtime_generation or self.active_source_incarnation != 1) return error.InvalidState;
                                // Actual late admission/atomic rejection has no
                                // pause action and no continuation object left.
                                // Keep physical cleanup after releasing Pending.
                                // Only a provably newer accepted state request
                                // can own immediate replanning below. A leftover
                                // desired field from this rejected intent cannot.
                                const owner = p.generation.director.?;
                                const replacement = if (owner.desired) |desired| desired.request_id > p.intent.?.request_id and
                                    owner.request_epoch > p.intent.?.request_epoch and owner.last_request_id == desired.request_id and
                                    owner.last_position != null and std.meta.eql(owner.last_position.?, desired.position) and
                                    std.meta.eql(self.latest_request_position, desired.position) and
                                    (self.mode != .versioned or self.ticketForRequestV1(desired.request_id) != null) else false;
                                // All replacement resolve/prepare failures also
                                // arm cleanup; explicit stop may share it.
                                if (!replacement) self.requireFillCleanupStop();
                            }
                        }
                        for (prefix..execution.cursor.phases.count) |index| self.receipt(.{ .phase_terminal = try execution.cursor.terminalReceipt(index) });
                        for (&execution.groups) |*entry| if (entry.*) |group| {
                            try self.retireGroup(group);
                            entry.* = null;
                        };
                        if (self.active_group == null) self.state = .ready;
                    } else self.receipt(.{ .plan_complete = .{ .token = p.token, .state = .complete, .observed_render_frame = frame } });
                    std.debug.assert(execution.cursor.isTerminal());
                } else if (!p.effective) {
                    if (result.disposition != .cancelled or (result.count == 0 and result.cancellation == null)) return;
                    p.generation.director.?.paused = self.state == .paused;
                    if (p.operation == .resume_music and p.continuity != null) p.generation.retireRequestWindows(p.request_ticket.?.request_id);
                    const rejected: api.PhaseReceipt = .{ .token = p.token, .outcome = .cancelled, .effective_frame = if (result.cancellation) |cancel| cancel.effective_frame else result.receipts[0].effective_frame };
                    const remains_paused = p.operation == .resume_music and self.action == .pause and self.state == .paused and self.fill_continuation != null;
                    if (remains_paused) {
                        const continuation = &self.fill_continuation.?;
                        const actual = try self.musicVoiceObservation(continuation.group);
                        if (!actual.paused or !actual.group.eql(continuation.group) or actual.generation != p.generation.runtime_generation or actual.source_incarnation != 1 or actual.transport_epoch != p.generation.transport.transport_epoch) return error.InvalidState;
                        // Cancellation won before resume: the earlier actual pause
                        // still freezes this same source. A newer pause is an
                        // unchanged request, never an invented execution phase.
                        try p.generation.director.?.refreshSuspendedPause(continuation.suspended.?);
                        continuation.resume_request = null;
                    } else if ((p.operation == .pause or p.operation == .resume_music) and self.fill_continuation != null) {
                        self.requireFillCleanupStop();
                        try self.discardFillContinuation();
                    }
                    self.receipt(.{ .phase_terminal = rejected });
                    if (remains_paused) {
                        if (self.action_ticket) |ticket| self.finishTicketV1(ticket, .unchanged);
                        self.action = null;
                        self.action_ticket = null;
                    }
                    if (self.active_group == null) self.state = .ready;
                } else self.receipt(.{ .plan_complete = .{ .token = p.token, .state = .complete, .observed_render_frame = frame } });
                if (p.intent != null and (p.transition == null or p.transition.?.solver_owned)) try p.generation.solver.?.forgetPlan(p.token.plan_id.value(), p.token.plan_epoch.value());
                try self.releaseSchedule(p.block);
                const pending_generation = p.generation;
                if (p.transition) |execution| self.allocator.destroy(execution);
                self.pending = null;
                pending_generation.releasePending();
            }
        }
        if (self.cleanup_stop_pending and self.pending == null) if (self.active_group) |group| {
            // Active custody retains the original full handle until retirement;
            // neither a slot index nor a reused source incarnation is authority.
            const credit = self.group_generation_credits[group.index] orelse return error.InvalidState;
            if (!credit.group.eql(group) or (try self.generations.get(credit.registry)).payload != self.generation.?) return error.InvalidState;
            const terminal = if (self.tick_scope) |scope| try scope.musicGroupTerminal(group) else try self.control.musicGroupTerminal(group);
            if (terminal) |ended| {
                if (ended.reason == .underrun and self.usesIntegratedTickV1()) {
                    // A late suffix rejection can reach cleanup before the
                    // outer fault collector. Preserve the real terminal and
                    // optional detail while this exact active handle is still
                    // owned; the existing collector records and retires it once.
                    try self.collectStreamFaultV1();
                } else {
                    // Capacity pressure may outlive a finite fill. Its durable
                    // terminal proves silence; do not publish endless stops
                    // against a group which has naturally completed.
                    _ = try self.collectSourceSwitchHistoryV1(group, self.generation.?);
                    try self.retireGroup(group);
                    self.paused_coordinate = null;
                    self.active_group = null;
                    self.confirmed_fill = null;
                    self.active_source_incarnation = 0;
                    self.rendering_segment = 0;
                    const epoch = self.generation.?.transport.transport_epoch;
                    self.generation.?.transport = clock.Clock.init(self.generation.?.transport.map, ended.boundary_frame);
                    self.generation.?.transport.device_epoch = self.device_accepted_epoch.load(.acquire);
                    self.generation.?.transport.transport_epoch = epoch;
                    self.generation.?.director.?.paused = false;
                    self.bar_offset = self.generation.?.director.?.current_bar;
                    self.state = .stopping;
                }
                self.cleanup_stop_pending = false;
                if (self.action_ticket == null) self.action = null;
            }
        };
        for (&self.retired_groups) |*entry| if (entry.*) |group| {
            const retired_generation = if (self.group_generation_credits[group.index]) |credit| (try self.generations.get(credit.registry)).payload else self.generation.?;
            self.releaseMusicGroup(group) catch |err| switch (err) {
                error.DrainPending => continue,
                else => return err,
            };
            retired_generation.retireGroupWindows(group);
            // Clear the released handle before fallible window collection in
            // the registry pass below; retries must never release it twice.
            if (self.crossfade_outgoing) |outgoing| if (outgoing.eql(group)) {
                self.crossfade_outgoing = null;
            };
            entry.* = null;
        };
        try self.collectGenerationWindows();
        try self.collectPreviewSeekRetirement();
        try self.collectStreamReloadRetirement();
        if (self.state == .stopping) {
            var remaining = false;
            for (self.retired_groups) |entry| if (entry != null) {
                remaining = true;
            };
            if (self.policy_storage) |storage| remaining = remaining or storage.music_stop_ticket != null or storage.physicalCount() != 0;
            if (!remaining) {
                self.state = .ready;
                self.cleanup_stop_pending = false;
            }
        }
        if (self.shutdown_requested.load(.acquire) and self.pending == null and self.active_group == null) {
            const any_retired = for (self.retired_groups) |entry| {
                if (entry != null) break true;
            } else false;
            if (!any_retired) self.cleanup_stop_pending = false;
        }
    }

    fn collectHook(self: *MusicRuntime, stage: CollectStage) void {
        if (@import("builtin").is_test) if (self.test_collect_hook) |hook| hook.call(hook.context, stage);
    }

    fn controlSnapshot(self: *const MusicRuntime) Snapshot {
        if (self.generation == null) return .{ .state = self.state, .committed_state = @enumFromInt(0), .committed_segment = @enumFromInt(0), .render_frame = self.control.scheduled.render_frame.load(.acquire), .pending = false, .asset_generation = 0, .transport_epoch = 0, .outstanding_sample_leases = 0 };
        var leases: u64 = 0;
        for (self.generation.?.owners) |*owner| leases += owner.referenceCount() - @as(u32, @intFromBool(!owner.retired.load(.acquire)));
        return .{ .state = self.state, .committed_state = @enumFromInt(self.generation.?.loaded.tables.states[self.generation.?.director.?.committed_state].key.id), .committed_segment = @enumFromInt(self.generation.?.loaded.tables.segments[self.generation.?.director.?.committed_segment].key.id), .render_frame = self.control.scheduled.render_frame.load(.acquire), .pending = self.pending != null or self.fill_continuation != null or self.cleanup_stop_pending or self.preview_seek != null, .asset_generation = self.generation.?.runtime_generation, .transport_epoch = self.generation.?.transport.transport_epoch, .outstanding_sample_leases = leases };
    }
    fn controlStatusV1(self: *const MusicRuntime) v1.StatusV1 {
        const transaction_pending = self.preview_seek != null or (if (self.resident_state) |state| !state.terminal else false) or (if (self.live_reload) |state| state.result == .pending else false);
        const value = self.controlSnapshot();
        const switched = self.activeSourceSwitchV1();
        return .{ .context = self.config.context, .kind = self.config_v1.kind, .state = value.state, .bank = if (self.generation != null) self.bankRef() else null, .bank_content_hash = if (self.generation) |generation| generation.loaded.content_hash else @splat(0), .committed_state = if (self.has_executed) value.committed_state else @enumFromInt(0), .committed_segment = if (self.has_executed) value.committed_segment else @enumFromInt(0), .render_frame = value.render_frame, .transport_epoch = value.transport_epoch, .pending = value.pending or self.in_flight != null or self.layer_in_flight != null or self.interruption != null or transaction_pending, .resident_transaction_pending = transaction_pending, .outstanding_sample_leases = value.outstanding_sample_leases, .observation_sequence = self.observation_sequence, .complete = !transaction_pending and !self.legacyTraceIncomplete() and !self.group_events.incomplete.load(.acquire), .diagnostics_complete = !transaction_pending and !self.incomplete and !self.group_events.incomplete.load(.acquire) and self.dropped_observations == 0 and self.input_lost == 0 and self.observation_lost == 0 and !self.trace_counter_exhausted, .replay_unsupported = self.replay_unsupported, .trace_inputs_dropped = self.input_lost, .trace_schedule_dropped = self.observation_lost, .trace_counter_exhausted = self.trace_counter_exhausted, .dropped_observations = self.dropped_observations, .stream_fault = self.last_stream_fault, .stream_fault_count = self.stream_fault_count, .stream_fault_details_dropped = self.stream_fault_details_dropped, .stream_fault_group_retirement_pending = self.streamFaultRetirementPending(), .degraded = switched != null, .rendering_segment = if (switched) |fact| fact.fallback_segment else @enumFromInt(self.rendering_segment), .source_incarnation = if (switched) |fact| fact.source_incarnation else self.active_source_incarnation, .source_switch = self.last_source_switch, .source_switch_count = self.source_switch_count, .source_switch_retirement_pending = self.sourceSwitchRetirementPending() };
    }
    pub fn snapshotV1(self: *MusicRuntime) !v1.StatusV1 {
        try self.requireFinalizationOpen();
        if (self.mode != .versioned) return error.InvalidMode;
        for (0..3) |_| {
            const index = self.published_snapshot.load(.acquire);
            const slot = &self.snapshots[index];
            const readers = slot.readers.load(.acquire);
            if (readers >= (1 << 31) - 1 or slot.readers.cmpxchgStrong(readers, readers + 1, .acquire, .monotonic) != null) continue;
            defer _ = slot.readers.fetchSub(1, .release);
            if (index != self.published_snapshot.load(.acquire)) continue;
            return slot.value_v1;
        }
        return error.SnapshotBusy;
    }

    fn publishSnapshot(self: *MusicRuntime) void {
        // A lower acceptance failure precedes public Input emission. Unlike a
        // full diagnostic suffix, it cannot be repaired by this output sink.
        if (self.control.stream_input_evidence_failures != 0 or self.replay_unsupported or self.trace_counter_exhausted) self.invalidateSemanticOutputV1();
        // Snapshot pin pressure and debug pressure are independent. Preserve the
        // actual status/frontier even when latest-value snapshot publication is busy.
        defer if (self.observer_storage) |storage| {
            const tick = self.tick_entry == .publishing and self.tick_scope != null;
            storage.publish(self.controlStatusV1(), if (tick) .control_tick else .control_operation, if (tick) self.tick else null);
        };
        const current = self.published_snapshot.load(.acquire);
        for (&self.snapshots, 0..) |*slot, i| {
            if (i == current or slot.readers.cmpxchgStrong(0, 1 << 31, .acquire, .monotonic) != null) continue;
            self.observation_sequence +|= 1;
            slot.value = self.controlSnapshot();
            slot.value_v1 = self.controlStatusV1();
            slot.readers.store(0, .release);
            self.published_snapshot.store(@intCast(i), .release);
            return;
        }
        self.dropped_observations +|= 1;
    }
    /// Game-thread owned copy. A bounded pin attempt may report SnapshotBusy;
    /// reader storage is never concurrently rewritten by Control.
    pub fn snapshot(self: *MusicRuntime) !Snapshot {
        try self.requireFinalizationOpen();
        for (0..3) |_| {
            const index = self.published_snapshot.load(.acquire);
            const slot = &self.snapshots[index];
            const readers = slot.readers.load(.acquire);
            if (readers >= (1 << 31) - 1 or slot.readers.cmpxchgStrong(readers, readers + 1, .acquire, .monotonic) != null) continue;
            defer _ = slot.readers.fetchSub(1, .release);
            if (index != self.published_snapshot.load(.acquire)) continue;
            return slot.value;
        }
        return error.SnapshotBusy;
    }
    /// Opt-in recording begins only after authentic bank loading has completed,
    /// before any request, render call, or external context mutation. Loading is
    /// a prerequisite checked by bank identity, not a fabricated replay event.
    pub fn beginRecordingV1(self: *MusicRuntime, profile: public_replay.Profile) !void {
        try self.claimControlV1();
        defer self.control_guard.store(false, .release);
        if (profile == .stream_fill_state_serial_v1 or profile == .stream_context_serial_v1) return error.UnsupportedCapability;
        try self.checkRecordingBeginV1(profile);
        self.public_recording = .{ .phase = .active, .profile = profile };
        self.direct_state_recording.store(if (profile == .stream_direct_state_serial_v1) .direct else .disabled, .release);
        self.direct_state_busy.store(false, .release);
        if (public_replay.isChunkStream(profile)) self.public_recording.stream_identity = self.recordingHeader();
        self.recordRuntimeStepV1(.begin, 0, 0);
    }
    /// Lower ingress must attribute every accepted command to the live Control
    /// operation. This rejects raw journal/SFX/bus commands while attached.
    pub fn causalLowerCommandAllowedV1(self: *MusicRuntime, control: *rt.ControlRuntime, command: rt.Command) bool {
        const sink = self.causal_sink orelse return true;
        const permitted = control == self.control and sink.permitted(sink.context, .control) and
            self.control_guard.load(.acquire) and self.tick_scope != null and
            (command == .scheduled or command == .invalidate);
        if (!permitted) sink.invalidate(sink.context);
        return permitted;
    }
    fn requireCausalRoleV1(self: *MusicRuntime, role: CausalRoleV1) !void {
        try self.requireFinalizationOpen();
        if (self.causal_sink) |sink| if (!sink.permitted(sink.context, role)) {
            sink.invalidate(sink.context);
            return error.UnattributedCausalOperation;
        };
    }
    /// Initial admission only. This does not install serial-recording state or
    /// require stationary Render frontiers during later real operations.
    pub fn requireCausalBeginV1(self: *MusicRuntime) !trace.Header {
        try self.checkControlV1();
        if (self.causal_sink != null or self.control_guard.load(.acquire)) return error.InvalidState;
        try self.checkRecordingBeginV1(.stream_direct_state_serial_v1);
        try self.requireCausalGroupQueueInitialV1();
        const generation = self.generation.?;
        for (generation.loaded.tables.candidates) |candidate| {
            try self.validateStreamSnapshotSegment(generation.loaded.tables.segments[candidate.segment].key.id);
        }
        for (generation.loaded.tables.selectors) |selector| if (selector.fallback_segment != s.none) return error.UnsupportedCapability;
        for (generation.loaded.tables.transitions) |transition| {
            if (transition.fill != s.none or transition.fade_ticks != 0 or transition.overlap_frames != 0 or
                transition.fallback != .reject) return error.UnsupportedCapability;
        }
        for (generation.loaded.tables.transition_paths) |path| {
            if (path.fill != s.none or path.handoff != .hard_cut) return error.UnsupportedCapability;
        }
        return self.recordingIdentityV1(.stream_direct_state_serial_v1);
    }
    /// Called again while Session owns real Render DeviceQuiescence, before
    /// attaching the immutable profile-5 queue observer.
    pub fn requireCausalGroupQueueInitialV1(self: *const MusicRuntime) !void {
        // This unreleased causal profile has no group-event queue prelude.
        // Equal nonzero cursors are not a seed and must never be reset here.
        if (self.group_events.head.load(.acquire) != 0 or self.group_events.tail.load(.acquire) != 0 or
            self.group_events.reset_epoch.load(.acquire) != 1 or self.group_events.lost.load(.acquire) != 0 or
            !self.group_events.enabled.load(.acquire) or self.group_events.incomplete.load(.acquire) or
            self.group_events.public_causal_sink != null) return error.InvalidState;
    }
    pub fn validateCausalReplayOwnerV1(self: *MusicRuntime) !void {
        if (self.config_v1.kind != .offline) return error.UnsupportedCapability;
        _ = try self.requireCausalBeginV1();
    }
    pub fn requireCausalSourceRetirementV1(self: *MusicRuntime) !void {
        try self.requireCausalDrainV1();
        const generation = self.generation.?;
        if (generation.hasControlLeases() or generation.hasPreparedGroupLeases() or generation.hasSnapshotLeases()) return error.DrainPending;
        if (generation.registry) |registry| if ((try registry.get(generation.registry_handle.?)).borrowed_resident_pcm != 0) return error.DrainPending;
        for (generation.owners) |*owner| {
            const intrinsic: u32 = @intFromBool(!owner.retired.load(.acquire));
            if (owner.referenceCount() != intrinsic) return error.DrainPending;
        }
        for (generation.sources) |*source| if (source.asset) |*asset| {
            if (asset.references.load(.acquire) != 1) return error.DrainPending;
        };
        if (generation.play_custody_funded) return error.DrainPending;
    }
    pub fn requestCausalSourceRetirementV1(self: *MusicRuntime) !void {
        try self.checkControlV1();
        try self.requireCausalRoleV1(.control);
        try self.requireCausalSourceRetirementV1();
        // This genuine check includes generation Control/registry/reference
        // leases. A live Control object alone is not a generation lease.
        try self.generation.?.requestRetirement();
    }
    pub fn requireCausalRequestV1(self: *MusicRuntime, reference: v1.BankRefV1, payload: api.MusicRequestPayload) !void {
        try self.checkControlV1();
        try self.checkBank(reference);
        try (api.MusicRequest{ .request_id = 1, .payload = payload }).validate(self.config_v1.kind);
        switch (payload) {
            .set_state => |request| {
                _ = try find(self.generation.?.loaded.tables.states, request.state.value());
            },
            .stop => |mode| {
                if (mode != .emergency_ramp) return error.UnsupportedOperation;
                if (self.pending != null or self.preparing != null or self.in_flight != null or self.interruption != null or
                    self.action != null or self.ingress.occupied.load(.acquire) != 0 or
                    self.generation.?.director.?.desired != null) return error.DrainRequired;
            },
            else => return error.UnsupportedOperation,
        }
    }
    /// Actual engine/resource drain, not a receipt/idle substitute. Session
    /// separately proves its producer joins before permitting witness closure.
    pub fn requireCausalDrainV1(self: *MusicRuntime) !void {
        try self.checkControlV1();
        try self.requireDirectStateDrainV1();
        if (self.ingress.receipt_head.load(.acquire) != self.ingress.receipt_tail.load(.acquire) or
            self.receipts.head.load(.acquire) != self.receipts.tail.load(.acquire) or self.worker_guard.load(.acquire) or self.active_producers.load(.acquire) != 0 or
            self.renderer.callObservation().sequence & 1 != 0 or
            self.collected_call_sequence != self.renderer.callObservation().sequence) return error.DrainPending;
    }
    pub fn causalSourceSetHashV1(self: *MusicRuntime) ![32]u8 {
        try self.checkControlV1();
        const generation = self.generation orelse return error.InvalidState;
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update("SME public causal source set v1");
        for (generation.sources) |*source| {
            const opened = source.opened orelse return error.SourceUnavailable;
            const asset = if (source.asset) |*value| value else return error.SourceUnavailable;
            if (opened.token == 0 or opened.encoded_bytes != asset.source.length) return error.InvalidSource;
            var index: [4]u8 = undefined;
            std.mem.writeInt(u32, &index, source.sound_index, .little);
            hash.update(&index);
            var sound_bytes: [bank.wireSize(s.Sound)]u8 = undefined;
            bank.encode(s.Sound, asset.sound, &sound_bytes);
            hash.update(&sound_bytes);
            var codec_bytes: [bank.wireSize(s.Codec)]u8 = undefined;
            bank.encode(s.Codec, asset.codec, &codec_bytes);
            hash.update(&codec_bytes);
            for (asset.chunks) |chunk| {
                var bytes: [bank.wireSize(s.Chunk)]u8 = undefined;
                bank.encode(s.Chunk, chunk, &bytes);
                hash.update(&bytes);
            }
            for (asset.seeks) |seek| {
                var bytes: [bank.wireSize(s.SeekEntryV1)]u8 = undefined;
                bank.encode(s.SeekEntryV1, seek, &bytes);
                hash.update(&bytes);
            }
        }
        var result: [32]u8 = undefined;
        hash.final(&result);
        return result;
    }
    pub fn causalFailureCodeV1(err: anyerror) v1.FailureV1 {
        return failureV1(err);
    }
    fn checkRecordingBeginV1(self: *MusicRuntime, profile: public_replay.Profile) !void {
        if (profile != .resident_serial_v1 and !public_replay.isChunkStream(profile)) return error.UnsupportedCapability;
        if (self.public_recording.mode != .retained) return error.InvalidMode;
        if (self.public_recording.phase != .disabled or self.semantic_output_sink != null) return error.InvalidState;
        try self.checkRecordingProfileV1(profile);
        if (self.state != .ready or self.tick != 0 or self.control.stream_control_tick != 0 or self.renderer.renderFrame() != 0 or
            self.renderer.callObservation().sequence != 0 or self.control.scheduled.gate_number != 0 or
            self.control.next_sequence.load(.acquire) != 1 or self.control.next_control_sequence != 1 or
            self.control.next_group_generation != 1 or self.control.scheduled.next_batch_id != 1 or self.handle_incarnation != 1 or
            self.control.instanceReservationFrontier() != 1 or
            self.generation.?.transport.transport_epoch != 1 or self.resident_incarnation != 0 or
            self.ingress.next_ticket.load(.acquire) != 1 or self.ingress.next_control != 1 or
            self.ingress.occupied.load(.acquire) != 0 or self.pending != null or self.in_flight != null or
            self.active_group != null or self.next_plan_id != 1 or self.input_count != 0 or self.observation_count != 0 or
            self.legacyTraceIncomplete() or self.group_events.incomplete.load(.acquire)) return error.InvalidState;
        if (profile == .stream_context_serial_v1) {
            if (self.context_raw_callers.load(.seq_cst) != 0 or
                self.ingress.receipt_head.load(.acquire) != self.ingress.receipt_tail.load(.acquire) or
                self.receipts.head.load(.acquire) != self.receipts.tail.load(.acquire)) return error.InvalidState;
            try self.checkContextDirectBankV1();
        }
        if (public_replay.isChunkStream(profile)) {
            const service = self.generation.?.service.?;
            if (service.replay_mode or service.worker_busy.load(.acquire) or service.next_job != 1 or
                service.next_generation != 1 or service.accepted_count != 0 or service.publication_head.load(.acquire) != 0) return error.InvalidState;
        }
    }
    fn checkRecordingProfileV1(self: *MusicRuntime, profile: public_replay.Profile) !void {
        if (self.config_v1.crossfade.bindings.len != 0 or self.config_v1.boundary_stop != null or self.config_v1.preview_seek != null) return error.UnsupportedCapability;
        try self.checkControlV1();
        const generation = self.generation orelse return error.InvalidState;
        if (!self.usesIntegratedTickV1() or (profile == .resident_serial_v1 and self.config_v1.snapshot_profile != .resident_v1) or
            self.config_v1.policy_support != .disabled or self.config_v1.layer_gain.bindings.len != 0 or
            self.config_v1.sfx_generation_custody != .untracked or
            generation.layer_owner != null or generation.loaded.bus_graph != null or
            self.policy_storage != null or self.event_adapter != null or self.control.voice_admission != null or
            (self.control.source_continuity_manager != null and profile != .stream_fill_state_serial_v1) or
            (self.resident_state != null and !public_replay.isStateProfile(profile)) or self.live_reload != null or
            self.unloading or self.shutdown_requested.load(.acquire) or self.deviceRecoveryActive() or
            generation.transport.device_epoch != 1 or self.renderer.device_callbacks_active.load(.acquire) or
            self.control.master_gain != 1 or self.control.music_gain != 1 or self.control.sfx_gain != 1 or
            self.active_producers.load(.acquire) != 0 or self.worker_guard.load(.acquire)) return error.UnsupportedCapability;
        if (profile == .resident_serial_v1) {
            if (self.config_v1.streaming_reservation != .initial_bank_only or generation.service != null or self.owned_streaming != null or self.control.streaming_service != null) return error.UnsupportedCapability;
        } else {
            const service = generation.service orelse return error.UnsupportedCapability;
            if (self.control.streaming_service != service or self.worker_streaming.load(.acquire) != service or
                !service.runtime_attached or service.worker_busy.load(.acquire) or service.visibility_discarded or
                self.renderer.stream_visibility_error or
                (if (self.public_recording.mode == .chunks) self.control.stream_input_evidence_failures != 0 else self.control.stream_input_overflow != 0) or
                self.last_stream_fault != null or self.last_source_switch != null or
                (self.fill_continuation != null and profile != .stream_fill_state_serial_v1)) return error.UnsupportedCapability;
        }
        if (profile == .stream_context_serial_v1 and (self.config_v1.kind != .offline or
            self.config_v1.streamed_fill_mode != .full_span or self.causal_sink != null or self.causal_driver_pin != null or
            self.reload.ownsResources() or self.active_source_incarnation > 1)) return error.UnsupportedCapability;
        if (profile == .stream_direct_state_serial_v1 or profile == .stream_context_serial_v1) {
            if (self.load_ticket != null or self.load.state.load(.acquire) != .idle) return error.UnsupportedCapability;
            if (self.config_v1.snapshot_profile != .stream_direct_v1 or self.state == .paused or self.confirmed_fill != null or self.paused_coordinate != null) return error.UnsupportedCapability;
            if (self.pending) |pending| if (pending.transition) |execution| {
                if (execution.cursor.phases.count != 1 or execution.fill_route != null) return error.UnsupportedCapability;
            };
        }
        if (profile == .stream_fill_state_serial_v1) {
            if (self.load_ticket != null or self.load.state.load(.acquire) != .idle or
                self.config_v1.snapshot_profile != .stream_fill_v1 or self.active_source_incarnation > 1) return error.UnsupportedCapability;
            try self.checkRecordedContinuityV1();
            try self.checkRecordedFillContinuationV1();
        }
        var active_voices: u32 = 0;
        for (&self.control.prepared_groups, 0..) |*group, index| if (group.occupied) {
            const credit = self.group_generation_credits[index] orelse return error.UnsupportedCapability;
            if (credit.group.generation != group.generation or credit.runtime_generation != generation.runtime_generation or
                group.emergency != null) return error.UnsupportedCapability;
            // A retained multi-phase block can keep an already finished source
            // group after its real voice completions released reservations.
            // Count current incarnations, not authored/prepared voice totals.
            for (group.plays[0..group.prepared.voice_count]) |play| {
                const desired = self.control.desired[play.instance.index];
                active_voices += @intFromBool(desired.active and desired.instance.eql(play.instance) and desired.reservation == play.reservation);
            }
        };
        if (self.control.telemetry().live_instances != active_voices or self.control.active_count != active_voices) return error.UnsupportedCapability;
        if (profile == .resident_serial_v1) for (generation.loaded.tables.sounds) |sound| {
            if (sound.storage != .resident) return error.UnsupportedCapability;
        };
    }
    fn checkContextDirectBankV1(self: *MusicRuntime) !void {
        const generation = self.generation.?;
        for (generation.loaded.tables.candidates) |candidate| {
            try self.validateStreamSnapshotSegment(generation.loaded.tables.segments[candidate.segment].key.id);
        }
        for (generation.loaded.tables.selectors) |selector| if (selector.fallback_segment != s.none) return error.UnsupportedCapability;
        for (generation.loaded.tables.transitions) |transition| {
            if (transition.fill != s.none or transition.fade_ticks != 0 or transition.overlap_frames != 0 or
                transition.fallback != .reject) return error.UnsupportedCapability;
        }
        for (generation.loaded.tables.transition_paths) |path| {
            if (path.fill != s.none or path.handoff != .hard_cut) return error.UnsupportedCapability;
        }
    }
    /// Render reads only the atomic opt-in and immutable attachment identities.
    /// Preparation/publication already binds the full continuity descriptor in
    /// the recorded admission hash; any recorder failure revokes this gate.
    pub fn recordsSourceContinuityV1(self: *const MusicRuntime, control: *const rt.ControlRuntime, sink: *const rt.MusicGroupTrace, source_incarnation: u64) bool {
        return self.control == control and sink == &self.group_events and source_incarnation == 1 and
            self.direct_state_recording.load(.acquire) == .fill;
    }
    /// The two-slot lower manager remains the physical owner. Recording only
    /// admits descriptors attributable to this generation's managed groups.
    fn requireRecordedContinuityGroupV1(self: *MusicRuntime, handle: rt.GroupHandle) !void {
        const generation = self.generation orelse return error.UnsupportedCapability;
        if (handle.index >= self.control.prepared_groups.len) return error.UnsupportedCapability;
        const group = &self.control.prepared_groups[handle.index];
        const credit = self.group_generation_credits[handle.index] orelse return error.UnsupportedCapability;
        if (!group.occupied or group.generation != handle.generation or !credit.group.eql(handle) or
            credit.context != self.config.context or credit.runtime_generation != generation.runtime_generation or
            (try self.generations.get(credit.registry)).payload != generation or group.prepared.generation != generation.runtime_generation or
            group.emergency != null or group.graph_source_replaced.load(.acquire) != 0 or group.source_switch.read() != null) return error.UnsupportedCapability;
    }
    fn requireRecordedContinuityRequestV1(self: *MusicRuntime, request: rt.ControlRuntime.MusicContinuityRequest) !void {
        if (self.public_recording.phase != .active or self.public_recording.mode != .chunks or
            self.public_recording.profile != .stream_fill_state_serial_v1 or !self.public_recording.driving or
            self.tick_scope == null or self.active_group == null or !request.group.eql(self.active_group.?) or
            self.active_source_incarnation != 1 or request.source_incarnation != 1) return error.UnsupportedCapability;
        try self.requireRecordedContinuityGroupV1(request.group);
        const transport = self.generation.?.transport;
        if (transport.transport_epoch == std.math.maxInt(u64) or request.next_transport_epoch != transport.transport_epoch + 1 or
            transport.paused != (self.state == .paused)) return error.UnsupportedCapability;
        if (request.paused) {
            if (self.state != .playing or request.expected_pause != null or request.sources.len != 0) return error.UnsupportedCapability;
        } else {
            if (self.state != .paused or request.expected_pause == null or
                !std.meta.eql(request.expected_pause, self.paused_coordinate) or
                request.sources.len != self.control.prepared_groups[request.group.index].prepared.layer_count) return error.UnsupportedCapability;
        }
    }
    fn requireRecordedContinuityCommandV1(self: *MusicRuntime, command: rt.ScheduledCommand) !void {
        if (self.public_recording.mode != .chunks or self.public_recording.profile != .stream_fill_state_serial_v1 or
            command.payload != .group_pause) return error.UnsupportedCapability;
        const pause = command.payload.group_pause;
        try self.requireRecordedContinuityGroupV1(pause.group);
        const manager = self.control.source_continuity_manager orelse return error.UnsupportedCapability;
        const slot = try manager.get(pause.continuity orelse return error.UnsupportedCapability);
        if (!slot.schedule_ref or slot.state.load(.acquire) != .bound or slot.desc.source_incarnation != 1 or
            slot.desc.bank_generation != self.generation.?.runtime_generation or !slot.desc.group.eql(pause.group) or
            slot.desc.paused != pause.paused or slot.desc.new_transport_epoch != pause.next_transport_epoch or
            slot.desc.old_transport_epoch != command.identity.token.transport_epoch.value() or
            !std.mem.eql(u8, &slot.content_hash, &pause.continuity_hash)) return error.UnsupportedCapability;
    }
    fn checkRecordedContinuityV1(self: *MusicRuntime) !void {
        const generation = self.generation.?;
        const pending_handle = if (self.pending) |pending| pending.continuity else null;
        var pending_seen = false;
        if (self.control.source_continuity_manager) |manager| for (&manager.slots, 0..) |*slot, index| {
            const state = slot.state.load(.acquire);
            if (state == .free) continue;
            const desc = &slot.desc;
            const handle: rt.source_continuity.Handle = .{ .index = @intCast(index), .generation = slot.generation };
            try self.requireRecordedContinuityGroupV1(desc.group);
            const group = &self.control.prepared_groups[desc.group.index];
            if (slot.generation == 0 or desc.source_incarnation != 1 or desc.bank_generation != generation.runtime_generation or
                desc.layer_count != group.prepared.layer_count or desc.layer_count == 0 or desc.layer_count > rt.music_group.max_layers or
                desc.old_transport_epoch == 0 or desc.old_transport_epoch == std.math.maxInt(u64) or
                desc.new_transport_epoch != desc.old_transport_epoch + 1 or slot.retired_completed_frontier != null) return error.UnsupportedCapability;
            if (slot.schedule_ref) {
                const pending = self.pending orelse return error.UnsupportedCapability;
                if (pending_handle == null or !std.meta.eql(pending_handle.?, handle) or pending.generation != generation or
                    pending.request_ticket == null or pending.source_incarnation != 1 or
                    pending.operation != (if (desc.paused) Operation.pause else .resume_music) or
                    pending.token.transport_epoch.value() != desc.old_transport_epoch or
                    (state != .bound and state != .executed) or slot.installed or slot.retired_frame != null) return error.UnsupportedCapability;
                pending_seen = true;
            } else {
                if (state != .executed) return error.UnsupportedCapability;
                const current = group.source_ownership.current_continuity;
                if (slot.retired_frame) |frame| {
                    if (frame < slot.coordinate.frame or frame > self.renderer.renderFrame() or
                        (current != null and std.meta.eql(current.?, handle))) return error.UnsupportedCapability;
                } else if (!slot.installed or desc.paused or current == null or !std.meta.eql(current.?, handle)) return error.UnsupportedCapability;
            }
            if (state == .executed and (slot.coordinate.source_incarnation != 1 or slot.coordinate.transport_epoch != desc.new_transport_epoch or
                slot.coordinate.paused != desc.paused or slot.coordinate.frame > self.renderer.renderFrame())) return error.UnsupportedCapability;
        };
        if (pending_handle != null and !pending_seen) return error.UnsupportedCapability;
        // Reverse attribution also rejects an installed handle whose manager
        // entry was lost, retired or rebound to another prepared-group lifetime.
        for (&self.control.prepared_groups, 0..) |*group, index| if (group.occupied) {
            if (group.source_ownership.current_continuity) |handle| {
                const manager = self.control.source_continuity_manager orelse return error.UnsupportedCapability;
                const slot = try manager.get(handle);
                if (slot.state.load(.acquire) != .executed or !slot.installed or slot.schedule_ref or slot.retired_frame != null or
                    slot.desc.paused or slot.desc.group.index != index or slot.desc.group.generation != group.generation) return error.UnsupportedCapability;
            }
        };
        if (self.state == .paused) {
            const coordinate = self.paused_coordinate orelse return error.UnsupportedCapability;
            if (self.active_group == null or self.active_source_incarnation != 1 or !generation.transport.paused or
                !coordinate.paused or coordinate.source_incarnation != 1 or coordinate.transport_epoch != generation.transport.transport_epoch) return error.UnsupportedCapability;
        } else if (self.paused_coordinate != null or generation.transport.paused) return error.UnsupportedCapability;
    }
    fn checkRecordedFillContinuationV1(self: *MusicRuntime) !void {
        const continuation = self.fill_continuation orelse return;
        const generation = self.generation.?;
        const owner = generation.director.?;
        const fill = self.confirmed_fill orelse return error.UnsupportedCapability;
        if (continuation.generation != generation or self.active_group == null or !continuation.group.eql(self.active_group.?) or
            !fill.group.eql(continuation.group) or fill.entry.outcome != .executed or
            fill.entry.token.asset_generation.value() != generation.runtime_generation or self.active_source_incarnation != 1) return error.UnsupportedCapability;
        try self.requireRecordedContinuityGroupV1(continuation.group);
        if (continuation.suspended) |handle| {
            const suspended = owner.suspended_target_entry orelse return error.UnsupportedCapability;
            if (continuation.intent != null or !std.meta.eql(handle, suspended.handle) or suspended.invalidated or
                handle.identity[0] != self.config.context or handle.identity[1] != generation.runtime_generation or
                handle.identity[2] != owner.bank_build_id or suspended.committed_state != owner.committed_state or
                suspended.committed_segment != owner.committed_segment) return error.UnsupportedCapability;
            if (continuation.resume_request) |request| {
                if (self.state != .playing or generation.transport.paused or
                    generation.transport.transport_epoch <= suspended.transport_epoch) return error.UnsupportedCapability;
                if (owner.resume_acceptance) |accepted| {
                    if (accepted.request_id != request or request != owner.last_request_id) return error.UnsupportedCapability;
                } else {
                    // Collect may observe an executed resume before this tick
                    // accepts a newer pause. The resume's marker stays owned by
                    // the suspension until that real replacing pause executes.
                    const pause = owner.pause_acceptance orelse return error.UnsupportedCapability;
                    if (!owner.paused or pause.request_id <= request or pause.request_id != owner.last_request_id or
                        pause.request_epoch != owner.request_epoch or pause.request_epoch <= suspended.request_epoch or
                        owner.last_position == null or !std.meta.eql(pause.position, owner.last_position.?)) return error.UnsupportedCapability;
                    var pause_owned = self.action == .pause and self.action_ticket != null and self.action_ticket.?.request_id == pause.request_id;
                    if (self.pending) |pending| pause_owned = pause_owned or (pending.operation == .pause and pending.generation == generation and
                        pending.source_incarnation == 1 and pending.request_ticket != null and pending.request_ticket.?.request_id == pause.request_id);
                    if (!pause_owned) return error.UnsupportedCapability;
                }
            } else if (self.state == .playing) {
                // Cancellation can retain the fill before the actual pause,
                // or a newer pause can win while an earlier resume is collected.
                const pausing = self.action == .pause or if (self.pending) |pending| pending.operation == .pause else false;
                if (!pausing) return error.UnsupportedCapability;
            } else if (self.state != .paused) return error.UnsupportedCapability;
        } else {
            const intent = continuation.intent orelse return error.UnsupportedCapability;
            const prepared = self.preparing orelse return error.UnsupportedCapability;
            if (continuation.resume_request == null or continuation.resume_request.? != intent.request_id or self.state != .playing or
                generation.transport.paused or self.pending != null or owner.suspended_target_entry != null or
                !owner.isCurrent(intent) or !std.meta.eql(prepared.intent, intent)) return error.UnsupportedCapability;
            var owned = false;
            for (owner.pending) |pending| if (pending.active and pending.token == null and std.meta.eql(pending.intent, intent)) {
                owned = true;
                break;
            };
            if (!owned) return error.UnsupportedCapability;
        }
    }
    /// Offline replay remains the same owner and the same bounded Worker. It
    /// changes only when external completion/measurement facts are accepted.
    pub fn beginStreamReplayV1(self: *MusicRuntime) !void {
        try self.checkRecordingFrontierV1();
        if (!public_replay.isChunkStream(self.public_recording.profile) or self.public_recording.recomputing) return error.InvalidState;
        self.generation.?.service.?.replay_mode = true;
        self.public_recording.recomputing = true;
    }
    /// Read-only pre-begin authentication of the independently loaded owner.
    /// A chunk identity is never converted into a falsely complete legacy header.
    pub fn requireChunkReplayIdentityV1(self: *MusicRuntime, identity: trace.chunks.Identity) !void {
        try self.requireChunkReplayIdentityForProfileV1(identity, .stream_serial_v1);
    }
    pub fn requireChunkReplayIdentityForProfileV1(self: *MusicRuntime, identity: trace.chunks.Identity, profile: public_replay.Profile) !void {
        try self.checkControlV1();
        if (self.control_guard.load(.acquire) or self.control.control_active.load(.acquire)) return error.ConcurrentControl;
        if (!public_replay.isChunkStream(profile)) return error.UnsupportedCapability;
        try identity.validate();
        try self.checkRecordingBeginV1(profile);
        if (!std.meta.eql(identity, trace.chunks.Identity.fromHeader(self.recordingIdentityV1(profile)))) return error.InvalidHeader;
    }
    /// Authenticate the complete restore-preparation descriptor once, before
    /// attachment, using the exact bytes/hash already authenticated at load.
    pub fn requireChunkReplayBankResourceV1(self: *MusicRuntime, expected: trace.schema.lifecycle.BankResource) !void {
        try self.checkControlV1();
        if (self.control_guard.load(.acquire) or self.control.control_active.load(.acquire)) return error.ConcurrentControl;
        if (self.public_recording.mode != .retained) return error.InvalidMode;
        if (self.public_recording.phase != .disabled or self.generation == null or self.state != .ready or
            self.load_ticket != null or self.load.state.load(.acquire) != .idle) return error.InvalidState;
        try expected.validate();
        const actual: trace.schema.lifecycle.BankResource = .{ .identity = self.residentBankIdentity(), .byte_size = self.bank_resource_size, .bytes_hash = self.bank_resource_hash };
        if (!std.meta.eql(expected, actual)) return error.ResourceNotPrepared;
    }
    /// Read-only admission of an external snapshot already decoded and
    /// authenticated by chunk preflight. Validate bank-dependent semantics
    /// before attaching storage or admitting any restore request ownership.
    pub fn requireChunkReplaySnapshotV1(self: *MusicRuntime, decoded: *const save.Decoded) !void {
        try self.requireChunkReplaySnapshotForProfileV1(decoded, .stream_direct_state_serial_v1);
    }
    pub fn requireChunkReplayFillSnapshotV1(self: *MusicRuntime, decoded: *const save.Decoded) !void {
        try self.requireChunkReplaySnapshotForProfileV1(decoded, .stream_fill_state_serial_v1);
    }
    pub fn requireChunkReplaySnapshotForProfileV1(self: *MusicRuntime, decoded: *const save.Decoded, profile: public_replay.Profile) !void {
        try self.checkControlV1();
        if (self.control_guard.load(.acquire) or self.control.control_active.load(.acquire)) return error.ConcurrentControl;
        if (!public_replay.isStateProfile(profile)) return error.UnsupportedCapability;
        try self.checkRecordingBeginV1(profile);
        try public_replay.requireSnapshotForProfile(decoded, profile);
        try save.validateIdentity(decoded, buildId(self.generation.?.loaded.content_hash), self.generation.?.loaded.content_hash, self.residentProfileId());
        try self.validateResidentSnapshot(decoded);
        if (profile == .stream_fill_state_serial_v1) try self.requireChunkReplayFillCompositionV1(decoded);
    }
    /// Validate the loaded-bank logical/physical composition before attaching
    /// recording storage. Only one fixed-size logical staging copy is needed;
    /// no ResidentState, identity, group, stream window or source claim is made.
    fn requireChunkReplayFillCompositionV1(self: *MusicRuntime, decoded: *const save.Decoded) !void {
        const generation = self.generation.?;
        const staged = try self.allocator.create(director.ResidentImportStaging);
        defer self.allocator.destroy(staged);
        const header = &decoded.header;
        // These unused counter/frontier values are validation anchors only.
        // The real restore must stage again at its actual ready frontier.
        const anchor: director.ResidentImportAnchor = .{
            .request_id = self.ingress.next_ticket.load(.acquire),
            .position = .{ .accepted_control_frame = self.control_frame, .control_tick = self.tick, .input_order = self.input_order },
            .context = self.config.context,
            .asset_generation = generation.runtime_generation,
            .transport_epoch = try std.math.add(u64, generation.transport.transport_epoch, 1),
            .plan_id = self.next_plan_id,
            .frame = try self.control.earliestPlanFrame(),
            .bar = header.logical_bar,
        };
        try generation.director.?.stageResidentImport(&decoded.logical, anchor, staged);
        const expected_mode: director.ResidentPlaybackMode = switch (header.mode) {
            .ready => .ready,
            .playing => .playing,
            .paused => .paused,
        };
        if (staged.result.mode != expected_mode) return error.InvalidSnapshot;
        try self.validateResidentSnapshotComposition(generation, decoded, staged);
        _ = try self.streamFillSnapshotPhysical(generation, decoded);
        const physical_id = if (header.physical_segment != 0) header.physical_segment else generation.loaded.tables.segments[staged.logical.committed_segment].key.id;
        const segment = generation.loaded.tables.segments[try find(generation.loaded.tables.segments, physical_id)];
        var restored_clock = clock.Clock.init(generation.solver.?.maps[segment.tempo], anchor.frame);
        restored_clock.transport_epoch = anchor.transport_epoch;
        restored_clock.paused = header.mode == .paused;
        if (header.physical_segment != 0) restored_clock.anchor_elapsed = try self.residentElapsed(physical_id, header.cursor, header.loop_epoch);
        const physical_bar = try director.Director.barAtClock(restored_clock, anchor.frame);
        if (physical_bar > header.logical_bar) return error.InvalidSnapshot;
        try self.validateResidentSnapshotBarProgress(generation, decoded, restored_clock, header.logical_bar - physical_bar, anchor.frame);
        try generation.director.?.validateResidentImport(staged, anchor);
    }
    /// Deliberately separate from the retained replay guards and entry points.
    /// Wrong-thread/concurrent calls remain pure rejections before recorder reads.
    fn checkChunkReplayPreparationV1(self: *MusicRuntime) !void {
        try self.checkChunkInvocationV1();
        self.serviceChunkFailureV1();
        if (!public_replay.isChunkStream(self.public_recording.profile) or self.public_recording.phase != .active) return error.InvalidState;
        errdefer self.failRecordingV1();
        try self.checkChunkRecordingFrontierV1();
    }
    pub fn beginChunkStreamReplayV1(self: *MusicRuntime) !void {
        try self.checkChunkReplayPreparationV1();
        if (self.public_recording.recomputing) return error.InvalidState;
        self.generation.?.service.?.replay_mode = true;
        self.public_recording.recomputing = true;
    }
    pub fn prepareChunkStreamReplayTickV1(self: *MusicRuntime, inputs: []const trace.Input) !void {
        try self.checkChunkReplayPreparationV1();
        if (!self.streamReplayActiveV1()) return error.InvalidState;
        errdefer self.failRecordingV1();
        self.public_recording.tick_inputs = inputs;
        // Identical real bounded Worker preparation to retained stream replay.
        const service = self.generation.?.service.?;
        for (0..service.profile.job_capacity) |_| {
            if (!try self.workerOneV1()) break;
        }
    }
    pub fn prepareChunkStreamReplayRenderV1(self: *MusicRuntime, visibility: anytype) !void {
        try self.checkChunkReplayPreparationV1();
        if (!self.streamReplayActiveV1()) return error.InvalidState;
        errdefer self.failRecordingV1();
        try self.generation.?.service.?.prepareAvailableVisibilityReplayCursor(visibility);
    }
    pub fn streamReplayActiveV1(self: *const MusicRuntime) bool {
        return self.public_recording.phase == .active and public_replay.isChunkStream(self.public_recording.profile) and self.public_recording.recomputing;
    }
    pub fn prepareStreamReplayTickV1(self: *MusicRuntime, inputs: []const trace.Input) !void {
        try self.checkRecordingFrontierV1();
        if (!self.streamReplayActiveV1()) return error.InvalidState;
        self.public_recording.tick_inputs = inputs;
        // Early decoding does not publish or free jobs. All nonfree jobs still
        // contribute their genuine queued/backlog counts at every query.
        const service = self.generation.?.service.?;
        for (0..service.profile.job_capacity) |_| {
            if (!try self.workerOneV1()) break;
        }
    }
    pub fn streamReplayInputV1(self: *MusicRuntime, at: trace.schema.Position) !trace.Input {
        try self.checkControlV1();
        if (!self.streamReplayActiveV1() or self.tick_scope == null or !self.control_guard.load(.acquire)) return error.InvalidState;
        for (self.public_recording.tick_inputs) |input_value| if (std.meta.eql(input_value.position, at)) return input_value;
        return error.IncompleteTrace;
    }
    pub fn acceptStreamReplayTickV1(self: *MusicRuntime, scope: rt.ControlRuntime.TickV1) !void {
        try scope.requirePhase(.accept);
        if (scope.runtime != self.control or !self.streamReplayActiveV1() or !self.control_guard.load(.acquire)) return error.InvalidState;
        for (self.public_recording.tick_inputs) |input_value| if (input_value.payload == .worker) try scope.acceptStreamReplay(input_value);
    }
    pub fn prepareStreamReplayRenderV1(self: *MusicRuntime, future: []const trace.Input) !void {
        try self.checkRecordingFrontierV1();
        if (!self.streamReplayActiveV1()) return error.InvalidState;
        try self.generation.?.service.?.prepareAvailableVisibilityReplay(future);
    }
    pub fn failRecordingV1(self: *MusicRuntime) void {
        if (self.causal_sink) |sink| sink.invalidate(sink.context);
        // Internal error cleanup may be called from the generic public driver.
        // A foreign caller cannot poison Control-owned, non-atomic evidence.
        if (std.Thread.getCurrentId() != self.control_thread) return;
        self.invalidateSemanticOutputV1();
        if (self.public_recording.mode == .chunks) {
            self.public_recording.chunk_evidence_incomplete = true;
            if (self.public_recording.chunk_storage) |storage| storage.fail(.runtime_closure_failed, self.chunkFrontierV1());
        }
        if (self.public_recording.recomputing) {
            if (self.generation) |generation| {
                if (generation.service) |service| service.replay_mode = false;
            }
            self.public_recording.recomputing = false;
            self.public_recording.tick_inputs = &.{};
        }
        self.public_recording.phase = .failed;
        self.context_recording_gate.store(false, .seq_cst);
        self.direct_state_recording.store(.disabled, .release);
        self.direct_state_busy.store(false, .release);
        self.incomplete = true;
    }
    fn checkRecordingIdentityV1(self: *const MusicRuntime) !void {
        if (!public_replay.isChunkStream(self.public_recording.profile)) return;
        const initial = self.public_recording.stream_identity orelse return error.InvalidState;
        // Active headers are intentionally incomplete. Compare their complete
        // stable identity directly without falsely sealing the initial header.
        if (!std.meta.eql(initial, self.recordingHeader())) return error.InvalidHeader;
    }
    fn checkRecordingFrontierV1(self: *MusicRuntime) !void {
        // Affinity and existing ownership are checked before reading recorder
        // state or installing a failure mutation. Wrong-thread calls are pure
        // rejections, even while Control is recording or publishing.
        try self.checkControlV1();
        if (self.control_guard.load(.acquire) or self.control.control_active.load(.acquire)) return error.ConcurrentControl;
        if (self.public_recording.mode != .retained) return error.InvalidMode;
        if (self.public_recording.phase != .active or self.public_recording.driving) return error.InvalidState;
        errdefer self.failRecordingV1();
        try self.checkRecordingProfileV1(self.public_recording.profile);
        try self.checkRecordingIdentityV1();
        const call = self.renderer.callObservation();
        if (call.exhausted or call.sequence != self.public_recording.call_sequence or call.sequence & 1 != 0 or
            self.renderer.renderFrame() != self.public_recording.frame or self.tick != self.public_recording.tick or
            self.control.stream_control_tick != self.tick or self.control.scheduled.commit_horizon.load(.acquire) != self.public_recording.frame or
            self.control.next_sequence.load(.acquire) != self.public_recording.next_sequence or
            self.control.next_control_sequence != self.public_recording.next_control_sequence or
            self.control.instanceReservationFrontier() != self.public_recording.next_reservation or
            self.control.scheduled.next_batch_id != self.public_recording.next_batch or
            self.legacyTraceIncomplete() or self.group_events.incomplete.load(.acquire)) return error.IncompleteTrace;
    }
    fn recordRuntimeStepV1(self: *MusicRuntime, kind: trace.schema.RuntimeStepKind, frames: u32, limit: u32) void {
        self.input(self.makeRuntimeStepV1(kind, frames, limit));
    }
    fn makeRuntimeStepV1(self: *MusicRuntime, kind: trace.schema.RuntimeStepKind, frames: u32, limit: u32) trace.Input {
        // Markers are outside a tick. They cannot consume the integrated tick's
        // existing acceptance order; its next scope still starts at order zero.
        const at: trace.schema.Position = .{ .accepted_control_frame = self.renderer.renderFrame(), .control_tick = self.tick, .input_order = self.input_order };
        self.input_order += 1;
        return .{ .position = at, .payload = .{ .runtime_step = .{
            .profile = self.public_recording.profile,
            .kind = kind,
            .context = self.config.context,
            .frame_count = frames,
            .control_limit = limit,
            .render_call_sequence = self.renderer.callObservation().sequence,
            .render_gate = self.control.scheduled.gate_number,
            .next_command_sequence = self.control.next_sequence.load(.acquire),
            .next_request_id = self.ingress.next_control,
        } } };
    }
    /// The ordinary integrated production tick, with explicit empty ticks and
    /// command publication budget, including a zero-budget delayed publication.
    /// Actual owned submissions account for all lower ingress; foreign commands
    /// or unrecorded publication cannot be silently replayed.
    pub fn recordControlTickV1(self: *MusicRuntime, limit: u32) !usize {
        try self.checkRecordingFrontierV1();
        errdefer self.failRecordingV1();
        if (limit > rt.max_control_drain) return error.UnsupportedCapacity;
        self.recordRuntimeStepV1(.control_tick, 0, limit);
        self.public_recording.driving = true;
        defer self.public_recording.driving = false;
        self.public_recording.published = 0;
        self.public_recording.submitted = 0;
        self.public_recording.reservations = 0;
        self.public_recording.prepared_batches = 0;
        defer self.public_recording.tick_inputs = &.{};
        const count = try self.controlTickV1(limit);
        const next = try std.math.add(u64, self.public_recording.next_sequence, self.public_recording.submitted);
        const next_control = try std.math.add(u64, self.public_recording.next_control_sequence, count);
        const next_reservation = try std.math.add(u64, self.public_recording.next_reservation, self.public_recording.reservations);
        const next_batch = try std.math.add(u64, self.public_recording.next_batch, self.public_recording.prepared_batches);
        if (self.control.scheduled.next_batch_id != next_batch or self.control.instanceReservationFrontier() != next_reservation or self.control.next_sequence.load(.acquire) != next or self.control.next_control_sequence != next_control or next_control > next or
            count < self.public_recording.published or self.renderer.callObservation().sequence != self.public_recording.call_sequence or
            self.renderer.renderFrame() != self.public_recording.frame or self.tick != self.public_recording.tick + 1) return error.IncompleteTrace;
        self.public_recording.next_sequence = next;
        self.public_recording.next_control_sequence = next_control;
        self.public_recording.next_reservation = next_reservation;
        self.public_recording.next_batch = next_batch;
        self.public_recording.tick = self.tick;
        try self.checkRecordingProfileV1(self.public_recording.profile);
        try self.checkRecordingIdentityV1();
        if (self.legacyTraceIncomplete() or self.group_events.incomplete.load(.acquire)) return error.IncompleteTrace;
        return count;
    }
    /// Caller-owned fixed storage must outlive this owner and all export leases.
    /// Stream profiles share the same fixed producer/exporter. Profile 3 also
    /// records real state host calls while preserving their independent results.
    pub fn beginChunkRecordingV1(self: *MusicRuntime, storage: *chunk_recording.Storage, options: public_replay.ChunkOptions) public_replay.Invocation(void) {
        self.checkControlV1() catch |err| return .{ .not_started = err };
        if (self.control_guard.load(.acquire) or self.control.control_active.load(.acquire)) return .{ .not_started = error.ConcurrentControl };
        if (!public_replay.isChunkStream(options.profile)) return .{ .not_started = error.UnsupportedCapability };
        self.claimControlV1() catch |err| return .{ .not_started = err };
        defer self.control_guard.store(false, .release);
        // Pre-arm the profile-7 raw-call gate before checking pristine ingress.
        // An already-entered producer/consumer is counted and prevents admission.
        if (self.public_recording.phase != .disabled) return .{ .not_started = error.InvalidState };
        const context_profile = options.profile == .stream_context_serial_v1;
        var attached = false;
        if (context_profile) {
            self.context_recording_violation.store(false, .release);
            self.context_recording_gate.store(true, .seq_cst);
        }
        defer if (context_profile and !attached) self.context_recording_gate.store(false, .seq_cst);
        // A caller that saw the old open gate must finish before ANY pristine
        // snapshot is inspected. Later zero alone cannot authenticate earlier
        // frontier reads taken while that caller was still mutating ingress.
        if (context_profile and self.context_raw_callers.load(.seq_cst) != 0)
            return .{ .not_started = error.InvalidState };
        self.checkRecordingBeginV1(options.profile) catch |err| return .{ .not_started = err };
        const cursor = public_replay.ChunkCursor.beginForProfile(options.max_inputs, options.profile) catch |err| return .{ .not_started = err };
        const preamble = trace.chunks.Preamble.init(trace.chunks.Identity.fromHeader(self.recordingIdentityV1(options.profile)), options.profile, options.recording_nonce) catch |err| return .{ .not_started = err };
        storage.init(preamble, options.storage_id, options.incarnation) catch |err| return .{ .not_started = err };
        // Attachment is the commit boundary. All later failures report started.
        self.public_recording = .{ .mode = .chunks, .phase = .active, .profile = options.profile, .chunk_storage = storage, .chunk_cursor = cursor };
        attached = true;
        self.context_host_journal = .{};
        self.public_recording.stream_identity = self.recordingHeader();
        self.direct_state_recording.store(switch (options.profile) {
            .stream_direct_state_serial_v1 => .direct,
            .stream_fill_state_serial_v1 => .fill,
            else => .disabled,
        }, .release);
        self.direct_state_busy.store(false, .release);
        self.recordChunkStepV1(.begin, 0, 0);
        self.serviceChunkFailureV1();
        return .{ .started = .{ .engine_result = {}, .recording_status = storage.status() } };
    }
    fn chunkFrontierV1(self: *const MusicRuntime) chunk_recording.Frontier {
        return .{ .control_tick = self.tick, .control_frame = self.renderer.renderFrame(), .render_call_sequence = self.renderer.callObservation().sequence };
    }
    fn serviceChunkFailureV1(self: *MusicRuntime) void {
        const storage = self.public_recording.chunk_storage orelse return;
        storage.serviceFailure();
        const status = storage.status();
        // incomplete is also true for a healthy live/unacknowledged recording.
        // Only irreversible failure/invalid storage lifecycle poisons capture.
        if (status.reason != .none or status.export_failed or status.state == .failed or status.state == .retired or
            (self.public_recording.profile == .stream_context_serial_v1 and self.context_recording_violation.load(.acquire)) or
            (self.public_recording.phase == .active and self.chunkEvidenceIncompleteV1())) self.failRecordingV1();
    }
    /// Control-only status; async exporter failure wins even after producer seal.
    pub fn chunkRecordingStatusV1(self: *MusicRuntime) !chunk_recording.Status {
        try self.checkControlV1();
        if (self.control_guard.load(.acquire) or self.control.control_active.load(.acquire)) return error.ConcurrentControl;
        if (self.public_recording.mode != .chunks or self.public_recording.chunk_storage == null) return error.InvalidMode;
        self.serviceChunkFailureV1();
        return self.public_recording.chunk_storage.?.status();
    }
    fn checkChunkInvocationV1(self: *MusicRuntime) !void {
        // Do not read plain session state before affinity and guard checks.
        try self.checkControlV1();
        if (self.control_guard.load(.acquire) or self.control.control_active.load(.acquire)) return error.ConcurrentControl;
        if (self.public_recording.mode != .chunks or self.public_recording.chunk_storage == null) return error.InvalidMode;
        if (self.public_recording.driving or !self.usesIntegratedTickV1()) return error.InvalidState;
        if (self.renderer.callObservation().sequence & 1 != 0) return error.ConcurrentRender;
        if (self.renderer.device_callbacks_active.load(.acquire)) return error.UnsupportedCapability;
        if (self.public_recording.phase != .active and self.public_recording.phase != .failed and self.public_recording.phase != .sealed) return error.InvalidState;
    }
    fn chunkEvidenceIncompleteV1(self: *const MusicRuntime) bool {
        return self.public_recording.chunk_evidence_incomplete or self.replay_unsupported or
            (self.public_recording.profile == .stream_context_serial_v1 and self.context_recording_violation.load(.acquire)) or
            self.group_events.incomplete.load(.acquire) or self.control.stream_input_evidence_failures != 0;
    }
    fn checkChunkRecordingFrontierV1(self: *MusicRuntime) !void {
        if (self.public_recording.phase != .active or self.public_recording.driving) return error.InvalidState;
        if (self.public_recording.profile == .stream_context_serial_v1) try self.context_host_journal.boundary();
        try self.checkRecordingProfileV1(self.public_recording.profile);
        try self.checkRecordingIdentityV1();
        const status = self.public_recording.chunk_storage.?.status();
        const cursor = &self.public_recording.chunk_cursor.?;
        const call = self.renderer.callObservation();
        if (status.state != .active or status.reason != .none or status.export_failed or status.producer_closed or
            cursor.poisoned or cursor.finished or cursor.records != status.retained_inputs or
            call.exhausted or call.sequence != self.public_recording.call_sequence or call.sequence & 1 != 0 or
            self.renderer.renderFrame() != self.public_recording.frame or self.tick != self.public_recording.tick or
            self.control.stream_control_tick != self.tick or self.control.scheduled.commit_horizon.load(.acquire) != self.public_recording.frame or
            self.control.next_sequence.load(.acquire) != self.public_recording.next_sequence or
            self.control.next_control_sequence != self.public_recording.next_control_sequence or
            self.control.instanceReservationFrontier() != self.public_recording.next_reservation or
            self.control.scheduled.next_batch_id != self.public_recording.next_batch or self.chunkEvidenceIncompleteV1()) return error.IncompleteTrace;
    }
    fn recordChunkStepV1(self: *MusicRuntime, kind: trace.schema.RuntimeStepKind, frames: u32, limit: u32) void {
        if (self.public_recording.phase != .active) return;
        if (self.input_order == std.math.maxInt(u64)) {
            self.public_recording.chunk_storage.?.fail(.counter_exhausted, self.chunkFrontierV1());
            self.failRecordingV1();
            return;
        }
        self.recordRuntimeStepV1(kind, frames, limit);
    }
    fn checkChunkContextInvocationV1(self: *MusicRuntime) !void {
        try self.checkChunkInvocationV1();
        if (self.public_recording.profile != .stream_context_serial_v1) return error.UnsupportedCapability;
        self.serviceChunkFailureV1();
        if (self.public_recording.phase == .sealed) return error.InvalidState;
    }
    fn appendContextHostV1(self: *MusicRuntime, record: context_host.Record) void {
        if (self.public_recording.phase != .active) return;
        if (self.input_order == std.math.maxInt(u64)) {
            self.public_recording.chunk_storage.?.fail(.counter_exhausted, self.chunkFrontierV1());
            self.failRecordingV1();
            return;
        }
        self.context_host_journal.accept(record) catch {
            self.failRecordingV1();
            return;
        };
        self.input(.{ .position = self.position(), .payload = .{ .context_host_operation = record } });
    }
    fn beginContextHostV1(self: *MusicRuntime, args: context_host.Args) void {
        if (self.public_recording.phase == .active) self.checkChunkRecordingFrontierV1() catch self.failRecordingV1();
        // Preserve the real host frontier, without advancing a tick or Render.
        self.control_frame = self.renderer.renderFrame();
        self.appendContextHostV1(.{ .call = .{
            .operation_serial = self.context_host_journal.next_serial,
            .context = self.config.context,
            .render_call_sequence = self.renderer.callObservation().sequence,
            .args = args,
        } });
        // Reentrant wrapper calls cannot split a synchronous call/result pair.
        // The private actual operation still acquires its ordinary engine guard.
        self.public_recording.driving = true;
    }
    fn finishContextHostV1(self: *MusicRuntime, outcome: context_host.Outcome) void {
        self.appendContextHostV1(.{ .result = .{
            .operation_serial = self.context_host_journal.next_serial,
            .outcome = outcome,
        } });
        self.public_recording.driving = false;
        if (self.public_recording.phase == .active) {
            // In particular, synchronous ingress overload is observed exactly,
            // but is not a complete-recording witness in this initial profile.
            if (self.context_host_journal.incomplete) self.failRecordingV1();
            if (self.public_recording.phase == .active) self.checkChunkRecordingFrontierV1() catch self.failRecordingV1();
        }
        self.serviceChunkFailureV1();
    }
    fn finishContextHostErrorV1(self: *MusicRuntime, err: anyerror) void {
        const failure = context_host.SyncError.fromError(err) catch {
            self.public_recording.driving = false;
            self.failRecordingV1();
            return;
        };
        self.finishContextHostV1(.{ .failed = failure });
    }
    /// Explicit profile-7 ingress preserves the actual start guard and performs
    /// exactly one actual submit. Capture failure never replaces its result.
    pub fn recordChunkStartV1(self: *MusicRuntime, reference: v1.BankRefV1, initial_state: api.MusicStateId) public_replay.Invocation(v1.RequestTicketV1) {
        self.checkChunkContextInvocationV1() catch |err| return .{ .not_started = err };
        self.beginContextHostV1(.{ .start = .{ .bank = context_host.BankRef.fromPublic(reference), .state = initial_state.value() } });
        defer self.public_recording.driving = false;
        const result = self.startActualV1(reference, initial_state, true);
        if (result) |ticket| {
            self.finishContextHostV1(.{ .submitted = context_host.Ticket.fromPublic(ticket) });
        } else |err| self.finishContextHostErrorV1(err);
        return .{ .started = .{ .engine_result = result, .recording_status = self.public_recording.chunk_storage.?.status() } };
    }
    /// Only the supported request shape is preflighted. Invalid bank/key/value
    /// arguments reach ordinary validation, including original scalar f32 bits.
    pub fn recordChunkSubmitV1(self: *MusicRuntime, reference: v1.BankRefV1, payload: api.MusicRequestPayload) public_replay.Invocation(v1.RequestTicketV1) {
        self.checkChunkContextInvocationV1() catch |err| return .{ .not_started = err };
        const args = context_host.RequestPayload.fromPublic(payload) catch |err| return .{ .not_started = err };
        self.beginContextHostV1(.{ .submit = .{ .bank = context_host.BankRef.fromPublic(reference), .payload = args } });
        defer self.public_recording.driving = false;
        const result = self.submitActualV1(reference, payload, true);
        if (result) |ticket| {
            self.finishContextHostV1(.{ .submitted = context_host.Ticket.fromPublic(ticket) });
        } else |err| self.finishContextHostErrorV1(err);
        return .{ .started = .{ .engine_result = result, .recording_status = self.public_recording.chunk_storage.?.status() } };
    }
    /// A recorded null is a real poll. No tick/render wrapper drains credits.
    pub fn recordChunkPollReceiptV1(self: *MusicRuntime) public_replay.Invocation(?v1.ReceiptV1) {
        self.checkChunkContextInvocationV1() catch |err| return .{ .not_started = err };
        self.beginContextHostV1(.poll_receipt);
        defer self.public_recording.driving = false;
        const result = self.pollReceiptActualV1();
        if (result) |value| {
            self.finishContextHostV1(.{ .receipt = if (value) |receipt_value| context_host.Receipt.fromPublic(receipt_value) else null });
        } else |err| self.finishContextHostErrorV1(err);
        return .{ .started = .{ .engine_result = result, .recording_status = self.public_recording.chunk_storage.?.status() } };
    }
    /// The independent phase queue is consumed only by an explicit real poll.
    pub fn recordChunkPollPhaseReceiptV1(self: *MusicRuntime) public_replay.Invocation(?api.PhaseReceipt) {
        self.checkChunkContextInvocationV1() catch |err| return .{ .not_started = err };
        self.beginContextHostV1(.poll_phase_receipt);
        defer self.public_recording.driving = false;
        const result = self.pollPhaseReceiptActualV1();
        if (result) |value| {
            self.finishContextHostV1(.{ .phase_receipt = if (value) |receipt_value| context_host.PhaseReceipt.fromPublic(receipt_value) else null });
        } else |err| self.finishContextHostErrorV1(err);
        return .{ .started = .{ .engine_result = result, .recording_status = self.public_recording.chunk_storage.?.status() } };
    }
    /// Exactly one ordinary production tick, even if its marker or facts cannot
    /// be retained. An invoked engine error may follow partial work, never retry.
    pub fn recordChunkControlTickV1(self: *MusicRuntime, limit: u32) public_replay.Invocation(usize) {
        self.checkChunkInvocationV1() catch |err| return .{ .not_started = err };
        if (limit > rt.max_control_drain) return .{ .not_started = error.UnsupportedCapacity };
        self.serviceChunkFailureV1();
        if (self.public_recording.phase == .sealed) return .{ .not_started = error.InvalidState };
        if (self.public_recording.phase == .active) self.checkChunkRecordingFrontierV1() catch self.failRecordingV1();
        self.recordChunkStepV1(.control_tick, 0, limit);
        self.public_recording.driving = true;
        defer self.public_recording.driving = false;
        self.public_recording.published = 0;
        self.public_recording.submitted = 0;
        self.public_recording.reservations = 0;
        self.public_recording.prepared_batches = 0;
        defer self.public_recording.tick_inputs = &.{};
        const result = self.controlTickV1(limit);
        if (result) |count| {
            if (self.public_recording.phase == .active) self.finishChunkControlTickV1(count) catch self.failRecordingV1();
        } else |_| self.failRecordingV1();
        self.serviceChunkFailureV1();
        return .{ .started = .{ .engine_result = result, .recording_status = self.public_recording.chunk_storage.?.status() } };
    }
    fn finishChunkControlTickV1(self: *MusicRuntime, count: usize) !void {
        const next = try std.math.add(u64, self.public_recording.next_sequence, self.public_recording.submitted);
        const next_control = try std.math.add(u64, self.public_recording.next_control_sequence, count);
        const next_reservation = try std.math.add(u64, self.public_recording.next_reservation, self.public_recording.reservations);
        const next_batch = try std.math.add(u64, self.public_recording.next_batch, self.public_recording.prepared_batches);
        const next_tick = try std.math.add(u64, self.public_recording.tick, 1);
        if (self.control.scheduled.next_batch_id != next_batch or self.control.instanceReservationFrontier() != next_reservation or
            self.control.next_sequence.load(.acquire) != next or self.control.next_control_sequence != next_control or next_control > next or
            count < self.public_recording.published or self.renderer.callObservation().sequence != self.public_recording.call_sequence or
            self.renderer.renderFrame() != self.public_recording.frame or self.tick != next_tick) return error.IncompleteTrace;
        self.public_recording.next_sequence = next;
        self.public_recording.next_control_sequence = next_control;
        self.public_recording.next_reservation = next_reservation;
        self.public_recording.next_batch = next_batch;
        self.public_recording.tick = self.tick;
        try self.checkRecordingProfileV1(self.public_recording.profile);
        try self.checkRecordingIdentityV1();
        if (self.chunkEvidenceIncompleteV1()) return error.IncompleteTrace;
    }
    /// The same serialized offline Renderer; marker failure never skips audio.
    pub fn recordChunkRenderV1(self: *MusicRuntime, output: []f32, frames: u32) public_replay.Invocation(public_replay.RenderObservation) {
        self.checkChunkInvocationV1() catch |err| return .{ .not_started = err };
        const samples = std.math.mul(usize, frames, 2) catch |err| return .{ .not_started = err };
        if (frames == 0 or frames > self.config.quantum_frames or output.len != samples) return .{ .not_started = error.InvalidArgument };
        const before = self.renderer.renderFrame();
        const call_before = self.renderer.callObservation();
        const next = std.math.add(u64, before, frames) catch |err| return .{ .not_started = err };
        self.serviceChunkFailureV1();
        if (self.public_recording.phase == .sealed) return .{ .not_started = error.InvalidState };
        if (self.public_recording.phase == .active) self.checkChunkRecordingFrontierV1() catch self.failRecordingV1();
        self.recordChunkStepV1(.render, frames, 0);
        // Exclude nested wrapper calls throughout the real Renderer invocation.
        self.public_recording.driving = true;
        defer self.public_recording.driving = false;
        // No fallible recorder operation can skip this actual invocation.
        self.renderer.render(output, frames, 2);
        const after = self.renderer.renderFrame();
        const call_after = self.renderer.callObservation();
        const expected_call: ?u64 = std.math.add(u64, call_before.sequence, 2) catch null;
        const completed = expected_call != null and !call_before.exhausted and !call_after.exhausted and
            call_before.sequence & 1 == 0 and after == next and call_after.sequence == expected_call.? and
            self.control.scheduled.commit_horizon.load(.acquire) == next;
        const result: public_replay.RenderObservation = .{ .requested_frames = frames, .frame_before = before, .frame_after = after, .call_sequence_before = call_before.sequence, .call_sequence_after = call_after.sequence, .completed = completed };
        if (!completed) self.failRecordingV1();
        if (self.public_recording.phase == .active) {
            self.public_recording.frame = after;
            self.public_recording.call_sequence = call_after.sequence;
            self.checkRecordingIdentityV1() catch self.failRecordingV1();
        }
        self.serviceChunkFailureV1();
        return .{ .started = .{ .engine_result = result, .recording_status = self.public_recording.chunk_storage.?.status() } };
    }
    /// A failed closure emits only a failure terminal. It does not manufacture
    /// .end, wait for Worker/queue space, stop audio, or dispose live resources.
    pub fn endChunkRecordingV1(self: *MusicRuntime) public_replay.Invocation(void) {
        self.checkChunkInvocationV1() catch |err| return .{ .not_started = err };
        self.serviceChunkFailureV1();
        if (self.public_recording.phase == .sealed) return .{ .not_started = error.InvalidState };
        if (self.public_recording.phase == .active) self.finishChunkRecordingV1() catch self.failRecordingV1();
        self.serviceChunkFailureV1();
        return .{ .started = .{ .engine_result = {}, .recording_status = self.public_recording.chunk_storage.?.status() } };
    }
    fn finishChunkRecordingV1(self: *MusicRuntime) !void {
        try self.checkChunkRecordingFrontierV1();
        try self.checkRecordingClosureV1();
        if (self.input_order == std.math.maxInt(u64)) {
            self.public_recording.chunk_storage.?.fail(.counter_exhausted, self.chunkFrontierV1());
            return error.IncompleteTrace;
        }
        const end = self.makeRuntimeStepV1(.end, 0, 0);
        try self.public_recording.chunk_cursor.?.feed(&.{end});
        try self.public_recording.chunk_cursor.?.finish();
        const storage = self.public_recording.chunk_storage.?;
        const retained = storage.finish(end);
        self.inputDiagnosticV1(end);
        if (retained != .retained) return error.IncompleteTrace;
        const status = storage.status();
        if (!status.successful_end_staged or status.reason != .none or
            status.retained_inputs != self.public_recording.chunk_cursor.?.records) return error.IncompleteTrace;
        self.public_recording.sealed_chunk_inputs = status.retained_inputs;
        self.public_recording.sealed_chunk_schedule = status.retained_schedule;
        if (self.public_recording.recomputing) {
            self.generation.?.service.?.replay_mode = false;
            self.public_recording.recomputing = false;
        }
        self.public_recording.tick_inputs = &.{};
        self.public_recording.phase = .sealed;
        self.direct_state_recording.store(.disabled, .release);
    }
    /// Old standalone state APIs retain their ownership contract. Under profile
    /// 3 every successful call must pass through the serialized host recorder.
    fn requireRecordedStateCallV1(self: *MusicRuntime, cancellation: bool) !void {
        try self.checkControlV1();
        if (self.public_recording.mode == .chunks) {
            // Export failure is asynchronous. Cleanup must not depend on a
            // separate status call to release a now-impossible recording gate.
            if (self.control_guard.load(.acquire) or self.control.control_active.load(.acquire)) return error.ConcurrentControl;
            self.serviceChunkFailureV1();
        }
        if (self.public_recording.profile == .stream_context_serial_v1 and
            (self.public_recording.phase == .active or self.public_recording.phase == .sealed)) return error.UnsupportedOperation;
        if (public_replay.isStateProfile(self.public_recording.profile) and
            (self.public_recording.phase == .active or self.public_recording.phase == .sealed) and
            (cancellation or !self.public_recording.state_host)) return error.UnsupportedOperation;
    }
    fn requireDirectStateRecordingV1(self: *MusicRuntime) !void {
        try self.checkRecordingFrontierV1();
        if (self.public_recording.profile != .stream_direct_state_serial_v1) return error.UnsupportedCapability;
    }
    /// Both same-owner and fresh-owner restore start from an actually drained
    /// owner. No old audible source, pending read, window, or publication can
    /// be silently replaced by this deliberately narrow Stage 2 profile.
    fn requireDirectStateDrainV1(self: *MusicRuntime) !void {
        if (self.load_ticket != null or self.load.state.load(.acquire) != .idle) return error.DrainPending;
        if (self.state != .ready or self.active_group != null or self.pending != null or self.preparing != null or
            self.in_flight != null or self.interruption != null or self.action != null or self.resuming_request != null or
            self.fill_continuation != null or self.confirmed_fill != null or self.queue_count != 0 or
            self.ingress.occupied.load(.acquire) != 0 or self.control.active_count != 0 or self.control.telemetry().live_instances != 0 or
            self.generation.?.windowCount() != 0 or self.generation.?.director.?.desired != null) return error.DrainPending;
        for (self.retired_groups) |group| if (group != null) return error.DrainPending;
        if (self.control.source_continuity_manager) |manager| if (manager.retained() != 0) return error.DrainPending;
        for (&self.control.scheduled.slots) |*slot| if (slot.state.load(.acquire) != .free) return error.DrainPending;
        for (&self.control.scheduled.intents) |*intent| if (intent.state.load(.acquire) != 0) return error.DrainPending;
        try self.generation.?.service.?.verifyReplayComplete();
    }
    fn beginStateHostV1(self: *MusicRuntime, kind: trace.schema.StateHostKind, reference: v1.BankRefV1, ticket: u64, resource: ?trace.schema.lifecycle.SnapshotResource) !void {
        try self.requireDirectStateRecordingV1();
        try self.checkBank(reference);
        if (self.public_recording.next_state_operation == std.math.maxInt(u64)) return error.ResourceLimitExceeded;
        self.enterStateHostV1(kind, reference, ticket, resource);
    }
    fn enterStateHostV1(self: *MusicRuntime, kind: trace.schema.StateHostKind, reference: v1.BankRefV1, ticket: u64, resource: ?trace.schema.lifecycle.SnapshotResource) void {
        self.public_recording.state_host = true;
        self.public_recording.driving = true;
        self.public_recording.published = 0;
        self.public_recording.submitted = 0;
        self.public_recording.reservations = 0;
        self.public_recording.prepared_batches = 0;
        // A host poll is a real completed-frontier observation, without creating
        // a Control tick or borrowing its guard. The public API takes that guard.
        self.control_frame = self.renderer.renderFrame();
        if (self.public_recording.phase != .active) return;
        self.input(.{ .position = self.position(), .payload = .{ .state_host_operation = .{ .call = .{
            .operation_serial = self.public_recording.next_state_operation,
            .kind = kind,
            .context = self.config.context,
            .bank = self.residentBankIdentity(),
            .bank_index = reference.handle.index,
            .bank_incarnation = reference.handle.generation,
            .ticket = ticket,
            .snapshot = resource,
            .render_call_sequence = self.public_recording.call_sequence,
        } } } });
    }
    fn finishStateHostV1(self: *MusicRuntime, result: trace.schema.StateHostResult) !void {
        if (!self.public_recording.state_host or self.control_guard.load(.acquire) or self.control.control_active.load(.acquire)) return error.InvalidState;
        const next = try std.math.add(u64, self.public_recording.next_sequence, self.public_recording.submitted);
        const reservation = try std.math.add(u64, self.public_recording.next_reservation, self.public_recording.reservations);
        const batch = try std.math.add(u64, self.public_recording.next_batch, self.public_recording.prepared_batches);
        if (self.public_recording.phase != .active or self.public_recording.published != 0 or
            self.control.next_sequence.load(.acquire) != next or self.control.next_control_sequence != self.public_recording.next_control_sequence or
            self.control.instanceReservationFrontier() != reservation or self.control.scheduled.next_batch_id != batch or
            self.renderer.callObservation().sequence != self.public_recording.call_sequence or self.renderer.renderFrame() != self.public_recording.frame or
            self.tick != self.public_recording.tick or self.control.stream_control_tick != self.tick) return error.IncompleteTrace;
        self.public_recording.next_sequence = next;
        self.public_recording.next_reservation = reservation;
        self.public_recording.next_batch = batch;
        try result.validate();
        self.input(.{ .position = self.position(), .payload = .{ .state_host_operation = .{ .result = result } } });
        self.public_recording.next_state_operation += 1;
        try self.checkRecordingProfileV1(self.public_recording.profile);
        try self.checkRecordingIdentityV1();
        if (self.public_recording.mode == .chunks) {
            if (self.public_recording.phase != .active or self.chunkEvidenceIncompleteV1()) return error.IncompleteTrace;
        } else if (self.legacyTraceIncomplete()) return error.IncompleteTrace;
    }
    fn leaveStateHostV1(self: *MusicRuntime) void {
        self.public_recording.state_host = false;
        self.public_recording.driving = false;
    }
    fn checkChunkStateInvocationV1(self: *MusicRuntime) !void {
        try self.checkChunkInvocationV1();
        const profile = self.public_recording.profile;
        if (!public_replay.isStateProfile(profile) or
            self.config_v1.snapshot_profile != (if (profile == .stream_fill_state_serial_v1) v1.SnapshotProfileV1.stream_fill_v1 else .stream_direct_v1)) return error.UnsupportedCapability;
        self.serviceChunkFailureV1();
        if (self.public_recording.phase == .sealed) return error.InvalidState;
    }
    /// The call marker commits the invocation, even if its retention fails.
    /// Every caller must now invoke the actual owner once and return that result.
    fn beginChunkStateHostV1(self: *MusicRuntime, kind: trace.schema.StateHostKind, reference: v1.BankRefV1, ticket: u64, resource: ?trace.schema.lifecycle.SnapshotResource) void {
        if (self.public_recording.phase == .active) self.checkChunkRecordingFrontierV1() catch self.failRecordingV1();
        if (self.public_recording.phase == .active and self.public_recording.next_state_operation == std.math.maxInt(u64)) {
            self.public_recording.chunk_storage.?.fail(.counter_exhausted, self.chunkFrontierV1());
            self.failRecordingV1();
        }
        self.enterStateHostV1(kind, reference, ticket, resource);
    }
    fn finishChunkStateHostV1(self: *MusicRuntime, result: trace.schema.StateHostResult) void {
        if (self.public_recording.phase == .active) self.finishStateHostV1(result) catch self.failRecordingV1();
    }
    fn chunkStateResultV1(self: *MusicRuntime, comptime T: type, actual: anyerror!T) public_replay.Invocation(T) {
        self.serviceChunkFailureV1();
        return .{ .started = .{ .engine_result = actual, .recording_status = self.public_recording.chunk_storage.?.status() } };
    }
    /// Like the retained state wrapper, but a started result always preserves
    /// the real ticket, independently of marker/result/exporter failure. Never
    /// retry a started operation merely because recording became incomplete.
    pub fn recordChunkCaptureStateV1(self: *MusicRuntime, reference: v1.BankRefV1) public_replay.Invocation(save.TicketV1) {
        self.checkChunkStateInvocationV1() catch |err| return .{ .not_started = err };
        if (self.public_recording.state_ticket != null or self.public_recording.captured_once or self.public_recording.restored_once or self.resident_state != null) return .{ .not_started = error.ResidentTransactionBusy };
        self.residentProfile(reference) catch |err| return .{ .not_started = err };
        if (self.state != .ready and self.state != .playing and
            !(self.state == .paused and self.public_recording.profile == .stream_fill_state_serial_v1)) return .{ .not_started = error.UnsupportedCapability };
        if (self.ingress.occupied.load(.acquire) != 0) return .{ .not_started = error.RequestInProgress };
        if (self.public_recording.profile == .stream_direct_state_serial_v1)
            for (self.retired_groups) |group| if (group != null) return .{ .not_started = error.DrainPending };
        self.beginChunkStateHostV1(.capture_begin, reference, 0, null);
        defer self.leaveStateHostV1();
        self.direct_state_busy.store(self.public_recording.phase == .active, .release);
        const actual: anyerror!save.TicketV1 = if (self.active_producers.load(.acquire) != 0 or self.ingress.occupied.load(.acquire) != 0)
            error.RequestInProgress
        else
            self.captureStateV1(reference);
        if (actual) |ticket| {
            self.public_recording.state_ticket = .{ .kind = .capture, .id = ticket.incarnation };
            self.public_recording.captured_once = true;
            self.finishChunkStateHostV1(.{ .operation_serial = self.public_recording.next_state_operation, .ticket = ticket.incarnation, .status = .submitted });
        } else |_| self.failRecordingV1();
        return self.chunkStateResultV1(save.TicketV1, actual);
    }
    pub fn recordChunkPollCaptureStateV1(self: *MusicRuntime, ticket: save.TicketV1, resources: *public_replay.SnapshotResources) public_replay.Invocation(save.PollV1) {
        self.checkChunkStateInvocationV1() catch |err| return .{ .not_started = err };
        const state = self.captureStateFor(ticket) catch |err| return .{ .not_started = err };
        if (self.public_recording.phase == .active) {
            const tracked = self.public_recording.state_ticket orelse return .{ .not_started = error.StaleResidentTransaction };
            if (tracked.kind != .capture or tracked.id != ticket.incarnation) return .{ .not_started = error.StaleResidentTransaction };
        }
        if (resources.resource) |previous| {
            const captured = self.public_recording.captured_resource orelse return .{ .not_started = error.ResourceCapacity };
            if (!std.meta.eql(previous, captured)) return .{ .not_started = error.ResourceCapacity };
        }
        self.beginChunkStateHostV1(.capture_poll, self.bankRef(), ticket.incarnation, null);
        defer self.leaveStateHostV1();
        const actual = self.pollCaptureStateV1(ticket, &resources.snapshot);
        if (actual) |value| {
            if (self.public_recording.state_ticket) |*tracked| {
                if (tracked.kind == .capture and tracked.id == ticket.incarnation) tracked.terminal_polled = value != .pending;
            }
            self.recordChunkCapturePollResultV1(ticket, state, resources, value) catch self.failRecordingV1();
        } else |_| self.failRecordingV1();
        return self.chunkStateResultV1(save.PollV1, actual);
    }
    fn recordChunkCapturePollResultV1(self: *MusicRuntime, ticket: save.TicketV1, state: *const ResidentState, resources: *public_replay.SnapshotResources, actual: save.PollV1) !void {
        var result: trace.schema.StateHostResult = .{ .operation_serial = self.public_recording.next_state_operation, .ticket = ticket.incarnation, .status = .pending };
        switch (actual) {
            .pending => {},
            .failed => |failure| {
                result.status = .failed;
                result.failure_code = @as(u8, @intFromEnum(failure)) + 1;
            },
            .ready => |ready| {
                try public_replay.requireSnapshotForProfile(&state.decoded, self.public_recording.profile);
                const resource = save.resource(&state.decoded, resources.snapshot.slice());
                if (ready.byte_size != resource.byte_size or ready.capture_frame != resource.capture_render_frame or !std.mem.eql(u8, &ready.hash, &resource.bytes_hash)) return error.InvalidState;
                if (self.public_recording.captured_resource) |previous| if (!std.meta.eql(previous, resource)) return error.ResourceNotPrepared;
                // Real capture bytes remain usable even if recording already
                // failed while collecting this fence's admissions/observations.
                resources.resource = resource;
                self.public_recording.captured_resource = resource;
                result.status = .ready;
                result.snapshot = resource;
            },
        }
        self.finishChunkStateHostV1(result);
    }
    pub fn recordChunkAcknowledgeCaptureV1(self: *MusicRuntime, ticket: save.TicketV1) public_replay.Invocation(void) {
        self.checkChunkStateInvocationV1() catch |err| return .{ .not_started = err };
        const state = self.captureStateFor(ticket) catch |err| return .{ .not_started = err };
        if (self.public_recording.phase == .active) {
            const tracked = self.public_recording.state_ticket orelse return .{ .not_started = error.StaleResidentTransaction };
            if (tracked.kind != .capture or tracked.id != ticket.incarnation) return .{ .not_started = error.StaleResidentTransaction };
            if (!tracked.terminal_polled) return .{ .not_started = error.DrainPending };
        }
        if (!state.terminal or state.lower != null or state.block != null) return .{ .not_started = error.DrainPending };
        self.beginChunkStateHostV1(.capture_ack, self.bankRef(), ticket.incarnation, null);
        defer self.leaveStateHostV1();
        const actual = self.acknowledgeCaptureV1(ticket);
        if (actual) |_| {
            self.public_recording.state_ticket = null;
            self.direct_state_busy.store(false, .release);
            self.finishChunkStateHostV1(.{ .operation_serial = self.public_recording.next_state_operation, .ticket = ticket.incarnation, .status = .acknowledged });
        } else |_| self.failRecordingV1();
        return self.chunkStateResultV1(void, actual);
    }
    pub fn recordChunkRestoreStateV1(self: *MusicRuntime, reference: v1.BankRefV1, resources: *const public_replay.SnapshotResources) public_replay.Invocation(v1.RequestTicketV1) {
        self.checkChunkStateInvocationV1() catch |err| return .{ .not_started = err };
        if (self.public_recording.state_ticket != null or self.public_recording.restored_once or self.resident_state != null) return .{ .not_started = error.ResidentTransactionBusy };
        self.residentProfile(reference) catch |err| return .{ .not_started = err };
        self.requireDirectStateDrainV1() catch |err| return .{ .not_started = err };
        resources.verifyForProfileV1(self.allocator, self.public_recording.profile) catch |err| return .{ .not_started = err };
        const resource = resources.resource orelse return .{ .not_started = error.ResourceNotPrepared };
        if (self.public_recording.captured_resource) |captured| if (!std.meta.eql(captured, resource)) return .{ .not_started = error.ResourceNotPrepared };
        if (self.public_recording.captured_once and self.public_recording.captured_resource == null) return .{ .not_started = error.ResourceNotPrepared };
        const bytes = resources.resolveV1(resource) catch |err| return .{ .not_started = err };
        const decoded = self.allocator.create(save.Decoded) catch |err| return .{ .not_started = err };
        defer self.allocator.destroy(decoded);
        save.decode(bytes, decoded) catch |err| return .{ .not_started = err };
        save.validateIdentity(decoded, buildId(self.generation.?.loaded.content_hash), self.generation.?.loaded.content_hash, self.residentProfileId()) catch |err| return .{ .not_started = err };
        self.validateResidentSnapshot(decoded) catch |err| return .{ .not_started = err };
        self.beginChunkStateHostV1(.restore_submit, reference, 0, resource);
        defer self.leaveStateHostV1();
        self.direct_state_busy.store(self.public_recording.phase == .active, .release);
        const actual: anyerror!v1.RequestTicketV1 = if (self.active_producers.load(.acquire) != 0 or self.ingress.occupied.load(.acquire) != 0)
            error.RequestInProgress
        else
            self.restoreStateV1(reference, bytes);
        if (actual) |ticket| {
            self.public_recording.state_ticket = .{ .kind = .restore, .id = ticket.request_id };
            self.public_recording.restored_once = true;
            self.finishChunkStateHostV1(.{ .operation_serial = self.public_recording.next_state_operation, .ticket = ticket.request_id, .status = .submitted });
        } else |_| self.failRecordingV1();
        return self.chunkStateResultV1(v1.RequestTicketV1, actual);
    }
    pub fn recordChunkPollRestoreStateV1(self: *MusicRuntime, ticket: v1.RequestTicketV1) public_replay.Invocation(save.RestorePollV1) {
        self.checkChunkStateInvocationV1() catch |err| return .{ .not_started = err };
        _ = self.restoreStateFor(ticket) catch |err| return .{ .not_started = err };
        if (self.public_recording.phase == .active) {
            const tracked = self.public_recording.state_ticket orelse return .{ .not_started = error.StaleResidentTransaction };
            if (tracked.kind != .restore or tracked.id != ticket.request_id) return .{ .not_started = error.StaleResidentTransaction };
        }
        self.beginChunkStateHostV1(.restore_poll, ticket.bank, ticket.request_id, null);
        defer self.leaveStateHostV1();
        const actual = self.pollRestoreStateV1(ticket);
        if (actual) |value| {
            if (self.public_recording.state_ticket) |*tracked| {
                if (tracked.kind == .restore and tracked.id == ticket.request_id) tracked.terminal_polled = value != .pending;
            }
            self.recordChunkRestorePollResultV1(ticket, value) catch self.failRecordingV1();
        } else |_| self.failRecordingV1();
        return self.chunkStateResultV1(save.RestorePollV1, actual);
    }
    fn recordChunkRestorePollResultV1(self: *MusicRuntime, ticket: v1.RequestTicketV1, actual: save.RestorePollV1) !void {
        var result: trace.schema.StateHostResult = .{ .operation_serial = self.public_recording.next_state_operation, .ticket = ticket.request_id, .status = .pending };
        switch (actual) {
            .pending => {},
            .failed => |failure| {
                result.status = .failed;
                result.failure_code = @as(u8, @intFromEnum(failure)) + 1;
            },
            .installed => |receipt_value| {
                if (receipt_value.outcome != .executed) return error.InvalidState;
                const token = receipt_value.token;
                result.status = .installed;
                result.installed = .{ .context = token.context.value(), .asset_generation = token.asset_generation.value(), .transport_epoch = token.transport_epoch.value(), .plan_id = token.plan_id.value(), .plan_epoch = token.plan_epoch.value(), .phase_id = token.phase_id.value(), .effective_frame = receipt_value.effective_frame };
            },
        }
        self.finishChunkStateHostV1(result);
    }
    /// A healthy recording requires its terminal poll. Once recording fails,
    /// the actual transaction still owns cleanup, and can be polled, cancelled,
    /// drained and acknowledged through the same public owner APIs.
    pub fn recordChunkAcknowledgeRestoreV1(self: *MusicRuntime, ticket: v1.RequestTicketV1) public_replay.Invocation(void) {
        self.checkChunkStateInvocationV1() catch |err| return .{ .not_started = err };
        const state = self.restoreStateFor(ticket) catch |err| return .{ .not_started = err };
        if (self.public_recording.phase == .active) {
            const tracked = self.public_recording.state_ticket orelse return .{ .not_started = error.StaleResidentTransaction };
            if (tracked.kind != .restore or tracked.id != ticket.request_id) return .{ .not_started = error.StaleResidentTransaction };
            if (!tracked.terminal_polled) return .{ .not_started = error.DrainPending };
        }
        if (!state.terminal or state.lower != null or state.block != null or self.residentResourcesPending(state)) return .{ .not_started = error.DrainPending };
        self.beginChunkStateHostV1(.restore_ack, ticket.bank, ticket.request_id, null);
        defer self.leaveStateHostV1();
        const actual = self.acknowledgeRestoreV1(ticket);
        if (actual) |_| {
            self.public_recording.state_ticket = null;
            self.direct_state_busy.store(false, .release);
            self.finishChunkStateHostV1(.{ .operation_serial = self.public_recording.next_state_operation, .ticket = ticket.request_id, .status = .acknowledged });
        } else |_| self.failRecordingV1();
        return self.chunkStateResultV1(void, actual);
    }

    pub fn recordCaptureStateV1(self: *MusicRuntime, reference: v1.BankRefV1) !save.TicketV1 {
        try self.requireDirectStateRecordingV1();
        if (self.public_recording.state_ticket != null or self.public_recording.captured_once or self.public_recording.restored_once or self.resident_state != null) return error.ResidentTransactionBusy;
        try self.residentProfile(reference);
        if (self.state != .ready and self.state != .playing) return error.UnsupportedCapability;
        if (self.ingress.occupied.load(.acquire) != 0) return error.RequestInProgress;
        for (self.retired_groups) |group| if (group != null) return error.DrainPending;
        try self.beginStateHostV1(.capture_begin, reference, 0, null);
        defer self.leaveStateHostV1();
        errdefer self.failRecordingV1();
        self.direct_state_busy.store(true, .release);
        if (self.active_producers.load(.acquire) != 0 or self.ingress.occupied.load(.acquire) != 0) return error.RequestInProgress;
        const ticket = try self.captureStateV1(reference);
        self.public_recording.state_ticket = .{ .kind = .capture, .id = ticket.incarnation };
        self.public_recording.captured_once = true;
        try self.finishStateHostV1(.{ .operation_serial = self.public_recording.next_state_operation, .ticket = ticket.incarnation, .status = .submitted });
        return ticket;
    }
    pub fn recordPollCaptureStateV1(self: *MusicRuntime, ticket: save.TicketV1, resources: *public_replay.SnapshotResources) !save.PollV1 {
        try self.requireDirectStateRecordingV1();
        const tracked = self.public_recording.state_ticket orelse return error.StaleResidentTransaction;
        if (tracked.kind != .capture or tracked.id != ticket.incarnation) return error.StaleResidentTransaction;
        const state = try self.captureStateFor(ticket);
        if (resources.resource) |previous| {
            const captured = self.public_recording.captured_resource orelse return error.ResourceCapacity;
            if (!std.meta.eql(previous, captured)) return error.ResourceCapacity;
        }
        try self.beginStateHostV1(.capture_poll, self.bankRef(), ticket.incarnation, null);
        defer self.leaveStateHostV1();
        errdefer self.failRecordingV1();
        const actual = try self.pollCaptureStateV1(ticket, &resources.snapshot);
        var result: trace.schema.StateHostResult = .{ .operation_serial = self.public_recording.next_state_operation, .ticket = ticket.incarnation, .status = .pending };
        switch (actual) {
            .pending => {},
            .failed => |failure| {
                result.status = .failed;
                result.failure_code = @as(u8, @intFromEnum(failure)) + 1;
            },
            .ready => |ready| {
                try public_replay.requireDirectSnapshot(&state.decoded);
                const resource = save.resource(&state.decoded, resources.snapshot.slice());
                if (ready.byte_size != resource.byte_size or ready.capture_frame != resource.capture_render_frame or !std.mem.eql(u8, &ready.hash, &resource.bytes_hash)) return error.InvalidState;
                if (self.public_recording.captured_resource) |previous| if (!std.meta.eql(previous, resource)) return error.ResourceNotPrepared;
                resources.resource = resource;
                self.public_recording.captured_resource = resource;
                result.status = .ready;
                result.snapshot = resource;
            },
        }
        self.public_recording.state_ticket.?.terminal_polled = result.status != .pending;
        try self.finishStateHostV1(result);
        return actual;
    }
    pub fn recordAcknowledgeCaptureV1(self: *MusicRuntime, ticket: save.TicketV1) !void {
        try self.requireDirectStateRecordingV1();
        const tracked = self.public_recording.state_ticket orelse return error.StaleResidentTransaction;
        if (tracked.kind != .capture or tracked.id != ticket.incarnation) return error.StaleResidentTransaction;
        const state = try self.captureStateFor(ticket);
        if (!tracked.terminal_polled or !state.terminal or state.lower != null or state.block != null) return error.DrainPending;
        try self.beginStateHostV1(.capture_ack, self.bankRef(), ticket.incarnation, null);
        defer self.leaveStateHostV1();
        errdefer self.failRecordingV1();
        try self.acknowledgeCaptureV1(ticket);
        self.public_recording.state_ticket = null;
        self.direct_state_busy.store(false, .release);
        try self.finishStateHostV1(.{ .operation_serial = self.public_recording.next_state_operation, .ticket = ticket.incarnation, .status = .acknowledged });
    }
    pub fn recordRestoreStateV1(self: *MusicRuntime, reference: v1.BankRefV1, resources: *const public_replay.SnapshotResources) !v1.RequestTicketV1 {
        try self.requireDirectStateRecordingV1();
        if (self.public_recording.state_ticket != null or self.public_recording.restored_once or self.resident_state != null) return error.ResidentTransactionBusy;
        try self.residentProfile(reference);
        try self.requireDirectStateDrainV1();
        try resources.verifyV1(self.allocator);
        const resource = resources.resource orelse return error.ResourceNotPrepared;
        if (self.public_recording.captured_resource) |captured| if (!std.meta.eql(captured, resource)) return error.ResourceNotPrepared;
        if (self.public_recording.captured_once and self.public_recording.captured_resource == null) return error.ResourceNotPrepared;
        const bytes = try resources.resolveV1(resource);
        // Reject wrong bank/profile/semantic state before creating a ticket or
        // transaction. The public restore then makes its own synchronous copy.
        const decoded = try self.allocator.create(save.Decoded);
        defer self.allocator.destroy(decoded);
        try save.decode(bytes, decoded);
        try save.validateIdentity(decoded, buildId(self.generation.?.loaded.content_hash), self.generation.?.loaded.content_hash, self.residentProfileId());
        try self.validateResidentSnapshot(decoded);
        try self.beginStateHostV1(.restore_submit, reference, 0, resource);
        defer self.leaveStateHostV1();
        errdefer self.failRecordingV1();
        self.direct_state_busy.store(true, .release);
        if (self.active_producers.load(.acquire) != 0 or self.ingress.occupied.load(.acquire) != 0) return error.RequestInProgress;
        const ticket = try self.restoreStateV1(reference, bytes);
        self.public_recording.state_ticket = .{ .kind = .restore, .id = ticket.request_id };
        self.public_recording.restored_once = true;
        try self.finishStateHostV1(.{ .operation_serial = self.public_recording.next_state_operation, .ticket = ticket.request_id, .status = .submitted });
        return ticket;
    }
    pub fn recordPollRestoreStateV1(self: *MusicRuntime, ticket: v1.RequestTicketV1) !save.RestorePollV1 {
        try self.requireDirectStateRecordingV1();
        const tracked = self.public_recording.state_ticket orelse return error.StaleResidentTransaction;
        if (tracked.kind != .restore or tracked.id != ticket.request_id) return error.StaleResidentTransaction;
        _ = try self.restoreStateFor(ticket);
        try self.beginStateHostV1(.restore_poll, ticket.bank, ticket.request_id, null);
        defer self.leaveStateHostV1();
        errdefer self.failRecordingV1();
        const actual = try self.pollRestoreStateV1(ticket);
        var result: trace.schema.StateHostResult = .{ .operation_serial = self.public_recording.next_state_operation, .ticket = ticket.request_id, .status = .pending };
        switch (actual) {
            .pending => {},
            .failed => |failure| {
                result.status = .failed;
                result.failure_code = @as(u8, @intFromEnum(failure)) + 1;
            },
            .installed => |receipt_value| {
                if (receipt_value.outcome != .executed) return error.InvalidState;
                const token = receipt_value.token;
                result.status = .installed;
                result.installed = .{ .context = token.context.value(), .asset_generation = token.asset_generation.value(), .transport_epoch = token.transport_epoch.value(), .plan_id = token.plan_id.value(), .plan_epoch = token.plan_epoch.value(), .phase_id = token.phase_id.value(), .effective_frame = receipt_value.effective_frame };
            },
        }
        self.public_recording.state_ticket.?.terminal_polled = result.status != .pending;
        try self.finishStateHostV1(result);
        return actual;
    }
    pub fn recordAcknowledgeRestoreV1(self: *MusicRuntime, ticket: v1.RequestTicketV1) !void {
        try self.requireDirectStateRecordingV1();
        const tracked = self.public_recording.state_ticket orelse return error.StaleResidentTransaction;
        if (tracked.kind != .restore or tracked.id != ticket.request_id) return error.StaleResidentTransaction;
        const state = try self.restoreStateFor(ticket);
        if (!tracked.terminal_polled or !state.terminal or state.lower != null or state.block != null or self.residentResourcesPending(state)) return error.DrainPending;
        try self.beginStateHostV1(.restore_ack, ticket.bank, ticket.request_id, null);
        defer self.leaveStateHostV1();
        errdefer self.failRecordingV1();
        try self.acknowledgeRestoreV1(ticket);
        self.public_recording.state_ticket = null;
        self.direct_state_busy.store(false, .release);
        try self.finishStateHostV1(.{ .operation_serial = self.public_recording.next_state_operation, .ticket = ticket.request_id, .status = .acknowledged });
    }

    /// Serialized offline Render operation, on the same production renderer.
    /// Each call partition is retained, because it determines actual gates.
    /// No device adapter, worker, timing estimate or second mixer is involved.
    pub fn recordRenderV1(self: *MusicRuntime, output: []f32, frames: u32) !void {
        try self.checkRecordingFrontierV1();
        errdefer self.failRecordingV1();
        if (frames == 0 or frames > self.config.quantum_frames or output.len != @as(usize, frames) * 2) return error.InvalidArgument;
        self.recordRuntimeStepV1(.render, frames, 0);
        const next = try std.math.add(u64, self.public_recording.frame, frames);
        const call = try std.math.add(u64, self.public_recording.call_sequence, 2);
        self.renderer.render(output, frames, 2);
        if (self.renderer.renderFrame() != next or self.renderer.callObservation().sequence != call or
            self.control.scheduled.commit_horizon.load(.acquire) != next) return error.IncompleteTrace;
        self.public_recording.frame = next;
        self.public_recording.call_sequence = call;
        try self.checkRecordingIdentityV1();
    }
    /// A fresh collection must reconcile every published batch and gate. An
    /// active resident loop can remain audible; no pending plan may be omitted.
    pub fn endRecordingV1(self: *MusicRuntime) !void {
        try self.checkRecordingFrontierV1();
        errdefer self.failRecordingV1();
        try self.checkRecordingClosureV1();
        self.recordRuntimeStepV1(.end, 0, 0);
        if (self.legacyTraceIncomplete()) return error.IncompleteTrace;
        try public_replay.validate(self.replayInputs());
        if (self.public_recording.recomputing) {
            self.generation.?.service.?.replay_mode = false;
            self.public_recording.recomputing = false;
        }
        self.public_recording.phase = .sealed;
        self.direct_state_recording.store(.disabled, .release);
        self.public_recording.sealed_inputs = self.input_count;
        self.public_recording.sealed_schedule = self.observation_count;
    }
    fn checkRecordingClosureV1(self: *MusicRuntime) !void {
        if (self.collected_call_sequence != self.public_recording.call_sequence or self.pending != null or
            self.preparing != null or self.in_flight != null or self.interruption != null or self.action != null or
            self.fill_continuation != null or self.ingress.occupied.load(.acquire) != 0) return error.IncompleteTrace;
        for (&self.control.scheduled.slots) |*slot| if (slot.state.load(.acquire) != .free) return error.IncompleteTrace;
        for (&self.control.scheduled.intents) |*intent| if (intent.state.load(.acquire) != 0) return error.IncompleteTrace;
        if (public_replay.isChunkStream(self.public_recording.profile)) try self.generation.?.service.?.verifyReplayComplete();
        if (self.public_recording.profile == .stream_context_serial_v1) {
            try self.context_host_journal.finish();
            try self.requireContextDirectDrainV1();
        }
        if (public_replay.isStateProfile(self.public_recording.profile)) {
            if (self.public_recording.state_ticket != null or self.resident_state != null) return error.IncompleteTrace;
            try self.requireDirectStateDrainV1();
        }
    }
    /// Closure is read-only: it neither stops audio nor secretly polls either
    /// public queue. Both queues and actual DIRECT resource custody must drain.
    fn requireContextDirectDrainV1(self: *MusicRuntime) !void {
        try self.requireDirectStateDrainV1();
        if (self.ingress.receipt_head.load(.acquire) != self.ingress.receipt_tail.load(.acquire) or
            self.receipts.head.load(.acquire) != self.receipts.tail.load(.acquire) or
            self.context_raw_callers.load(.seq_cst) != 0 or self.active_producers.load(.acquire) != 0 or
            self.worker_guard.load(.acquire) or self.layer_in_flight != null or self.resident_state != null or
            self.live_reload != null or self.reload.ownsResources() or self.cleanup_stop_pending) return error.DrainPending;
        const generation = self.generation.?;
        if (generation.hasControlLeases() or generation.hasPreparedGroupLeases() or generation.hasSnapshotLeases()) return error.DrainPending;
        if (generation.registry) |registry| if ((try registry.get(generation.registry_handle.?)).borrowed_resident_pcm != 0) return error.DrainPending;
        for (generation.owners) |*owner| {
            const intrinsic: u32 = @intFromBool(!owner.retired.load(.acquire));
            if (owner.referenceCount() != intrinsic) return error.DrainPending;
        }
        for (generation.sources) |*source| if (source.asset) |*asset| {
            if (asset.references.load(.acquire) != 1) return error.DrainPending;
        };
        if (generation.play_custody_funded) return error.DrainPending;
    }
    /// Called by the real Control publication path after sequence/hash binding
    /// and successful publication, while the immutable block is still owned.
    /// Disabled captures do not alter compatibility trace bytes or decisions.
    pub fn capturePublishedScheduleV1(self: *MusicRuntime, control: *rt.ControlRuntime, block: *const rt.Scheduler.Block) void {
        if (self.causal_sink) |sink| {
            if (control != self.control or !sink.permitted(sink.context, .control) or !self.control_guard.load(.acquire) or self.tick_scope == null) {
                sink.invalidate(sink.context);
                return;
            }
            self.capturePlanCommandsV1(block, .planned);
            self.capturePlanCommandsV1(block, .published);
            return;
        }
        if (std.Thread.getCurrentId() != self.control_thread) return;
        if (self.public_recording.phase != .active) return;
        if (control != self.control or !self.public_recording.driving or !self.control_guard.load(.acquire) or self.tick_scope == null) {
            self.failRecordingV1();
            return;
        }
        self.public_recording.published += 1;
        self.capturePlanCommandsV1(block, .planned);
        self.capturePlanCommandsV1(block, .published);
    }
    pub fn capturePublishedInvalidationV1(self: *MusicRuntime, control: *rt.ControlRuntime, intent: *const rt.Scheduler.Intent) void {
        if (self.causal_sink) |sink| {
            if (control != self.control or !sink.permitted(sink.context, .control) or !self.control_guard.load(.acquire) or self.tick_scope == null) {
                sink.invalidate(sink.context);
                return;
            }
            const token = intent.token;
            self.observe(.{ .event = .{
                .kind = .cancel_requested,
                .context = token.context.value(),
                .control_tick = self.tick,
                .accepted_control_frame = self.control_frame,
                .cancel_requested_frame = intent.value.requested_frame,
                .sequence = intent.sequence,
                .plan_id = token.plan_id.value(),
                .plan_epoch = token.plan_epoch.value(),
                .phase_id = token.phase_id.value(),
                .transport_epoch = token.transport_epoch.value(),
                .asset_generation = token.asset_generation.value(),
            } });
            return;
        }
        if (std.Thread.getCurrentId() != self.control_thread) return;
        if (self.public_recording.phase != .active) return;
        if (control != self.control or !self.public_recording.driving or !self.control_guard.load(.acquire) or self.tick_scope == null) {
            self.failRecordingV1();
            return;
        }
        self.public_recording.published += 1;
        const token = intent.token;
        self.observe(.{ .event = .{
            .kind = .cancel_requested,
            .context = token.context.value(),
            .control_tick = self.tick,
            .accepted_control_frame = self.control_frame,
            .cancel_requested_frame = intent.value.requested_frame,
            .sequence = intent.sequence,
            .plan_id = token.plan_id.value(),
            .plan_epoch = token.plan_epoch.value(),
            .phase_id = token.phase_id.value(),
            .transport_epoch = token.transport_epoch.value(),
            .asset_generation = token.asset_generation.value(),
        } });
    }
    fn capturePlanCommandsV1(self: *MusicRuntime, block: *const rt.Scheduler.Block, kind: trace.schema.ScheduleKind) void {
        for (block.commands[0..block.count]) |command| {
            const identity = command.identity;
            const token = identity.token;
            if (command.payload == .resident_capture or command.payload == .resident_restore) {
                if (!public_replay.isStateProfile(self.public_recording.profile) or token.context.value() != self.config.context or self.resident_state == null) {
                    self.failRecordingV1();
                    return;
                }
                self.observe(.{ .event = .{
                    .kind = kind,
                    .context = token.context.value(),
                    .command_id = identity.command_id,
                    .control_tick = self.tick,
                    .accepted_control_frame = self.control_frame,
                    .planned_frame = identity.execute_frame,
                    .sequence = command.sequence,
                    .plan_id = token.plan_id.value(),
                    .phase_id = token.phase_id.value(),
                    .phase_order = identity.phase_order,
                    .plan_epoch = token.plan_epoch.value(),
                    .transport_epoch = token.transport_epoch.value(),
                    .asset_generation = token.asset_generation.value(),
                    .group = identity.group_id,
                    .state_before = if (kind == .plan_prepared) .prepared else .published,
                } });
                continue;
            }
            const group = switch (command.payload) {
                .group_start => |v| v.group,
                .group_stop => |v| v.group,
                .group_pause => |v| group: {
                    if (self.causal_sink != null) {
                        self.failRecordingV1();
                        return;
                    }
                    if (v.continuity != null) self.requireRecordedContinuityCommandV1(command) catch {
                        self.failRecordingV1();
                        return;
                    };
                    break :group v.group;
                },
                else => {
                    self.failRecordingV1();
                    return;
                },
            };
            if (token.context.value() != self.config.context or self.group_generation_credits[group.index] == null) {
                self.failRecordingV1();
                return;
            }
            const source = &self.control.prepared_groups[group.index].prepared;
            self.observe(.{ .event = .{
                .kind = kind,
                .context = token.context.value(),
                .command_id = identity.command_id,
                .control_tick = self.tick,
                .input_order = self.latest_request_position.input_order,
                .accepted_control_frame = self.control_frame,
                .planned_frame = identity.execute_frame,
                .sequence = command.sequence,
                .plan_id = token.plan_id.value(),
                .phase_id = token.phase_id.value(),
                .phase_order = identity.phase_order,
                .plan_epoch = token.plan_epoch.value(),
                .transport_epoch = token.transport_epoch.value(),
                .asset_generation = token.asset_generation.value(),
                .group = identity.group_id,
                .source_segment = if (command.payload == .group_stop) source.segment else 0,
                .target_segment = if (command.payload == .group_start) source.segment else 0,
                .state_before = if (kind == .plan_prepared) .prepared else .published,
            } });
        }
    }

    /// Serializes a sealed capture directly as the existing ReplayInputV2.
    /// Caller owns the buffer; the borrowed payload lasts as long as that buffer.
    pub fn exportReplayV1(self: *const MusicRuntime, bytes: []u8) !api.ReplayInputV2 {
        try self.checkControlV1();
        if (self.live_chronology_frontier != null) return error.LiveChronologyRequired;
        if (self.public_recording.mode != .retained) return error.InvalidMode;
        if (self.mode != .versioned or self.public_recording.phase != .sealed) return error.IncompleteTrace;
        const header = self.recordingHeader();
        return trace.inputEnvelope(header, try trace.encode(trace.Input, bytes, header, self.replayInputs()));
    }
    pub fn validateReplayHeader(self: *const MusicRuntime, header: trace.Header) !void {
        try header.requireCompatible(self.recordingHeader());
    }
    fn historyRequirementsOwnedV1(self: *const MusicRuntime) v1.HistoryRequirementsV1 {
        return if (self.live_chronology_frontier != null)
            .{ .replay_contract = .live_chronology_v1, .live_capture = .unavailable }
        else
            .{ .replay_contract = .existing_contract, .live_capture = .not_applicable };
    }
    /// Control-only query. This says what protocol the lifetime history needs,
    /// not whether it has been captured, validated, sealed or published.
    pub fn historyRequirementsV1(self: *MusicRuntime) !v1.HistoryRequirementsV1 {
        try self.claimControlV1();
        defer self.control_guard.store(false, .release);
        if (self.control.control_active.load(.acquire)) return error.ConcurrentControl;
        return self.historyRequirementsOwnedV1();
    }
    /// Atomic prefix transfer plus its lifetime provenance. Failure has the
    /// same no-write/no-consume contract as the original diagnostic drain.
    pub fn copyAndDrainTraceWithProvenanceV1(self: *MusicRuntime, inputs: []trace.Input, schedule: []trace.ScheduleEntry) !v1.RetainedTraceWithProvenanceV1 {
        try self.claimControlV1();
        defer self.control_guard.store(false, .release);
        const requirements = self.historyRequirementsOwnedV1();
        const batch = try self.copyAndDrainTraceOwnedV1(inputs, schedule);
        return .{ .batch = batch, .requirements = requirements };
    }
    /// Control-only, allocation-free transfer of both retained prefixes into
    /// caller-owned memory. Payloads own every byte; no bank/decoder pointer or
    /// resource lease escapes. A successful nonempty transfer invalidates all
    /// prior borrowed prefix slices. Disabled/failed recorders may consume;
    /// active/sealed recorders pin their complete history. Failure is atomic.
    /// Diagnostic ABI only: exporters needing self-contained history provenance
    /// must use copyAndDrainTraceWithProvenanceV1 instead.
    pub fn copyAndDrainTraceV1(self: *MusicRuntime, inputs: []trace.Input, schedule: []trace.ScheduleEntry) !v1.RetainedTraceBatchV1 {
        try self.claimControlV1();
        defer self.control_guard.store(false, .release);
        return self.copyAndDrainTraceOwnedV1(inputs, schedule);
    }
    /// Caller holds the owner guard; no public guarded method is called here.
    fn copyAndDrainTraceOwnedV1(self: *MusicRuntime, inputs: []trace.Input, schedule: []trace.ScheduleEntry) !v1.RetainedTraceBatchV1 {
        comptime {
            @setEvalBranchQuota(30_000);
            observer.requireOwnedValue(trace.Input);
            observer.requireOwnedValue(trace.ScheduleEntry);
        }
        if (self.control.control_active.load(.acquire)) return error.ConcurrentControl;
        if (self.public_recording.mode != .retained) return error.InvalidMode;
        if (self.public_recording.phase == .active or self.public_recording.phase == .sealed) return error.TraceRecordingPinned;
        if (inputs.len < self.input_count or schedule.len < self.observation_count) return error.BufferTooSmall;
        const input_bytes = std.mem.sliceAsBytes(inputs);
        const schedule_bytes = std.mem.sliceAsBytes(schedule);
        const owner_bytes = std.mem.asBytes(self);
        if (traceBuffersOverlap(input_bytes, schedule_bytes) or traceBuffersOverlap(input_bytes, owner_bytes) or traceBuffersOverlap(schedule_bytes, owner_bytes)) return error.InvalidArgument;
        const next_input = std.math.add(u64, self.input_base, self.input_count) catch return error.TraceOrdinalExhausted;
        const next_schedule = std.math.add(u64, self.observation_base, self.observation_count) catch return error.TraceOrdinalExhausted;
        const result: v1.RetainedTraceBatchV1 = .{ .input_begin = self.input_base, .input_count = self.input_count, .schedule_begin = self.observation_base, .schedule_count = self.observation_count, .inputs_dropped = self.input_lost, .schedule_dropped = self.observation_lost, .counter_exhausted = self.trace_counter_exhausted };
        // All rejection paths are above this commit boundary. No failure can
        // consume one channel while leaving the other or partially write output.
        @memcpy(inputs[0..self.input_count], self.inputs[0..self.input_count]);
        @memcpy(schedule[0..self.observation_count], self.observations[0..self.observation_count]);
        self.input_base = next_input;
        self.observation_base = next_schedule;
        self.input_count = 0;
        self.observation_count = 0;
        // Do not publish a new snapshot or allocate any canonical identity here.
        // Existing snapshots describe their actual last publication; next Control
        // publication exposes consumed history, with diagnostics still separate.
        return result;
    }
    fn traceBuffersOverlap(a: []const u8, b: []const u8) bool {
        if (a.len == 0 or b.len == 0) return false;
        const a_start = @intFromPtr(a.ptr);
        const b_start = @intFromPtr(b.ptr);
        const a_end = std.math.add(usize, a_start, a.len) catch return true;
        const b_end = std.math.add(usize, b_start, b.len) catch return true;
        return a_start < b_end and b_start < a_end;
    }
    /// Borrowed retained diagnostic suffix only, never the full chunk recording.
    /// Explicit retained-mode consumption invalidates it.
    pub fn scheduleRecords(self: *const MusicRuntime) []const trace.ScheduleEntry {
        return self.observations[0..self.observation_count];
    }
    /// Borrowed retained diagnostic suffix only, never the full chunk recording.
    /// Explicit retained-mode consumption invalidates it.
    pub fn replayInputs(self: *const MusicRuntime) []const trace.Input {
        return self.inputs[0..self.input_count];
    }
    fn recordingIdentityV1(self: *const MusicRuntime, profile: public_replay.Profile) trace.Header {
        var profile_bytes: [bank.wireSize(s.Platform)]u8 = undefined;
        bank.encode(s.Platform, self.generation.?.loaded.tables.platforms[self.generation.?.loaded.metadata.profile], &profile_bytes);
        var capacity_hash = trace.replay.hashPcm(&profile_bytes);
        if (public_replay.isChunkStream(profile)) {
            var identity = std.crypto.hash.sha2.Sha256.init(.{});
            identity.update(switch (profile) {
                .stream_direct_state_serial_v1 => "stream_direct_state_serial_v1",
                .stream_fill_state_serial_v1 => "stream_fill_state_serial_v1",
                .stream_context_serial_v1 => "stream_context_serial_v1",
                else => "stream_serial_v1",
            });
            identity.update(&profile_bytes);
            const service_hash = self.generation.?.service.?.profile.hash();
            identity.update(&service_hash);
            const modes = [_]u8{ @intFromEnum(self.config_v1.streamed_fill_mode), @intFromEnum(self.config_v1.streaming_reservation), @intCast(@intFromEnum(self.config_v1.snapshot_profile)) };
            identity.update(&modes);
            identity.final(&capacity_hash);
        }
        var initial_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &initial_bytes, self.generation.?.loaded.tables.states[self.generation.?.loaded.metadata.initial_state].key.id, .little);
        return .{ .compiler_version = 1, .algorithm_version = planner.algorithm_version, .bank_content_hash = self.generation.?.loaded.content_hash, .profile = self.generation.?.loaded.tables.platforms[self.generation.?.loaded.metadata.profile].key.id, .seed = self.config.seed, .initial_state_hash = trace.replay.hashPcm(&initial_bytes), .sample_rate = s.sample_rate, .quantum_frames = self.config.quantum_frames, .bank_major = s.major, .bank_minor = s.minor, .bank_build_id = buildId(self.generation.?.loaded.content_hash), .generation = self.generation.?.runtime_generation, .capacity_profile_hash = capacity_hash, .complete = false };
    }
    pub fn recordingHeader(self: *const MusicRuntime) trace.Header {
        if ((self.mode == .versioned and self.public_recording.phase == .disabled) or self.generation == null) return .{ .compiler_version = 1, .algorithm_version = planner.algorithm_version, .bank_content_hash = @splat(0), .profile = 0, .seed = self.config.seed, .initial_state_hash = @splat(0), .sample_rate = s.sample_rate, .quantum_frames = self.config.quantum_frames, .bank_major = s.major, .bank_minor = s.minor, .bank_build_id = 0, .generation = 0, .capacity_profile_hash = @splat(0), .complete = false };
        var header = self.recordingIdentityV1(self.public_recording.profile);
        // Control-thread borrowed prefix, valid only through the last complete
        // collection. New or active Render work requires another quiescent
        // update before export; a previously observed overlap remains permanent.
        const call = self.renderer.callObservation();
        const sealed = self.mode == .compatibility or (self.public_recording.phase == .sealed and
            self.public_recording.sealed_inputs == self.input_count and self.public_recording.sealed_schedule == self.observation_count and
            self.public_recording.tick == self.tick and self.public_recording.frame == self.renderer.renderFrame() and
            self.public_recording.next_sequence == self.control.next_sequence.load(.acquire) and
            self.public_recording.next_reservation == self.control.instanceReservationFrontier() and
            self.public_recording.next_batch == self.control.scheduled.next_batch_id and
            self.ingress.occupied.load(.acquire) == 0 and self.active_producers.load(.acquire) == 0 and
            !self.shutdown_requested.load(.acquire) and !self.unloading and self.resident_state == null and self.live_reload == null and self.preview_seek == null and
            !self.deviceRecoveryActive());
        header.complete = self.public_recording.mode == .retained and sealed and !self.legacyTraceIncomplete() and !self.group_events.incomplete.load(.acquire) and !call.exhausted and call.sequence & 1 == 0 and call.sequence == self.collected_call_sequence;
        if (public_replay.isChunkStream(self.public_recording.profile)) {
            // A sealed capture still belongs to its original construction.
            // Never export old records under a newly recomputed identity.
            var identity = header;
            identity.complete = false;
            if (self.public_recording.stream_identity) |initial| {
                if (!std.meta.eql(initial, identity)) header.complete = false;
            } else header.complete = false;
        }
        return header;
    }
    /// Replay recomputes the real public update and checks every accepted input
    /// and actual renderer admission. It never injects execution outcomes.
    pub fn replayUpdate(self: *MusicRuntime, expected: []const trace.Input) !void {
        if (self.mode != .compatibility) return error.InvalidMode;
        if (self.replay_failed) return error.InvalidState;
        errdefer {
            self.replay_failed = true;
            self.incomplete = true;
        }
        try trace.replay.validateSequence(expected);
        for (expected) |value| {
            if (value.position.control_tick != self.tick + 1 or value.position.accepted_control_frame != self.control.scheduled.render_frame.load(.acquire)) return error.InvalidOrder;
            switch (value.payload) {
                .request => |r| {
                    if (r.context != self.config.context or r.producer != 1) return error.InvalidState;
                    const payload: api.MusicRequestPayload = switch (r.payload) {
                        .set_state => |v| .{ .set_state = .{ .state = @enumFromInt(v.state), .priority = v.priority } },
                        .pause => .pause,
                        .@"resume" => .@"resume",
                        .stop_emergency => .{ .stop = .emergency_ramp },
                        else => return error.UnsupportedOperation,
                    };
                    try self.submit(self.bankGeneration(), .{ .request_id = r.request_id, .payload = payload });
                },
                .admission => {},
                else => return error.UnsupportedOperation,
            }
        }
        const before = self.input_count;
        try self.update();
        const actual = self.inputs[before..self.input_count];
        if (actual.len != expected.len) return error.MissingAdmission;
        for (actual, expected) |a, e| if (!std.meta.eql(a, e)) return error.ReplayMismatch;
    }
    pub fn beginShutdown(self: *MusicRuntime) !void {
        if (self.mode == .versioned) return self.shutdown();
        try self.claimSoundControl();
        defer self.control_guard.store(false, .release);
        self.closeBorrowedSounds();
        if (self.service_custody) |*custody| custody.accepting = false;
        self.shutdown_requested.store(true, .release);
        self.collectBorrowedSounds();
        try self.discardFillContinuation();
        try self.control.submitShutdown();
        self.state = .shutting_down;
        self.publishSnapshot();
    }
    pub fn shutdown(self: *MusicRuntime) !void {
        try self.claimControlV1();
        defer self.control_guard.store(false, .release);
        self.admission_handle.store(0, .release);
        self.closeBorrowedSounds();
        if (self.service_custody) |*custody| custody.accepting = false;
        self.shutdown_requested.store(true, .release);
        self.collectBorrowedSounds();
        self.policy_render_permitted.store(true, .release);
        self.state = .shutting_down;
        // Queue the actual shutdown before candidate cleanup can be pending.
        // A full queue is retried by collection after real Control progress.
        if (self.device_stream_candidate != null or (if (self.generation) |generation| generation.service != null else false)) {
            self.control.submitShutdown() catch |err| {
                if (err != error.CommandQueueFull) return err;
            };
            if (self.device_event != null) {
                if (self.generation != null) try self.collect();
                try self.acceptDeviceLossOwned();
            }
        }
        if (self.preview_seek) |state| state.cancel_requested = true;
        if (self.live_reload) |state| {
            state.cancel_requested = true;
            if (state.lower == null) self.abortReloadOwned(.shutdown);
        } else self.abortReloadOwned(.shutdown);
        self.load.cancelled.store(true, .release);
        if (self.load.state.cmpxchgStrong(.queued, .idle, .acq_rel, .acquire) == null) {
            self.allocator.free(self.load.bytes);
            self.load.bytes = &.{};
            self.load.input_bytes.store(0, .release);
            self.load_status = .{ .failed = .cancelled };
        }
        _ = self.load.state.cmpxchgStrong(.sources_queued, .sources_completed, .acq_rel, .acquire);
        try self.collectLoad();
        try self.collectPolicies();
        try self.collectShutdownV1();
        self.rejectQueuedV1();
        self.publishSnapshot();
        // submitShutdown is idempotent and retains its retry obligation on a
        // full reserved queue. Admission remains closed on that recoverable error.
        try self.control.submitShutdown();
    }

    /// Compatibility shutdown cannot use update(), which correctly rejects
    /// new work once shutdown is requested. Acquire the existing terminal
    /// receipts here before Control teardown can reclaim their handles.
    fn collectShutdownCompatibility(self: *MusicRuntime) !void {
        std.debug.assert(self.mode == .compatibility and !self.control_torn_down);
        defer self.state = .shutting_down;
        if (self.generation == null) return;
        try self.discardFillContinuation();
        try self.abandonPreparing();
        try self.abandonResume();
        // The same collector acquires actual phases/cancellations, releases
        // their schedule exactly once, and returns the Pending registry lease.
        try self.collect();
        self.drainGroupEvents();
        if (self.pending != null) return error.DrainPending;
        if (self.active_group) |group| {
            try self.retireGroup(group);
            self.active_group = null;
            self.confirmed_fill = null;
            self.active_source_incarnation = 0;
            self.rendering_segment = 0;
        }
        // A group retired just above was not in the first collection pass.
        // One more bounded pass acquires real final pins/completions; never
        // substitute shutdown intent for a release proof or require user poll.
        try self.collect();
        for (self.retired_groups) |group| if (group != null) return error.DrainPending;
    }

    fn collectShutdownV1(self: *MusicRuntime) !void {
        defer self.state = .shutting_down;
        if (self.device_stream_candidate != null or (if (self.device_recovery_state) |recovery| recovery.stream_restart_compatible else false)) {
            self.control.submitShutdown() catch |err| {
                if (err != error.CommandQueueFull) return err;
            };
            if (self.device_recovery_state) |*recovery| recovery.source_pending = false;
            try self.collectStreamDeviceRecovery();
            if (self.device_stream_candidate == null) self.device_status.stage = .stopped;
        }
        if (self.preview_seek) |state| {
            state.cancel_requested = true;
            try self.collectPreviewSeek();
            if (state.lower != null or state.block != null or state.invalidation != null) return;
        }
        if (self.live_reload) |state| {
            state.cancel_requested = true;
            try self.collectLiveReload();
            if (state.lower != null) return;
            if (self.reload.ownsResources()) self.abortReloadOwned(.shutdown);
            try self.finishLiveReloadWorkerResult();
        }
        if (self.resident_state) |state| if (!state.terminal) {
            state.cancel_requested = true;
            try self.cancelResidentState();
            try self.collectResidentState();
            if (state.kind == .restore and state.lower != null) return;
        };
        if (self.generation != null) {
            try self.discardFillContinuation();
            try self.abandonPreparing();
            try self.abandonResume();
            // Acquire actual phase/terminal publication before considering an
            // intent rejected. Resource receipts are never replaced by a host
            // shutdown request, including render-before-Control interleavings.
            try self.collect();
            try self.collectSourceSwitchV1();
            try self.collectStreamFaultV1();
            try self.retireSwitchedSourcesV1();
            self.drainGroupEvents();
            if (self.pending == null) {
                if (self.active_group) |group| {
                    try self.retireGroup(group);
                    self.active_group = null;
                    self.confirmed_fill = null;
                    self.active_source_incarnation = 0;
                    self.rendering_segment = 0;
                }
                if (self.in_flight) |ticket| if (!self.policyStopOwnsV1(ticket) and !self.layerTicketOwnsV1(ticket)) self.finishTicketV1(ticket, .{ .rejected = .runtime_stopped });
                if (self.layer_in_flight) |ticket| if (!self.layerTicketOwnsV1(ticket)) self.finishTicketV1(ticket, .{ .rejected = .runtime_stopped });
                if (self.interruption) |interrupt| if (!self.policyStopOwnsV1(interrupt.ticket)) self.finishTicketV1(interrupt.ticket, .{ .rejected = .runtime_stopped });
            }
        } else {
            if (self.in_flight) |ticket| if (!self.policyStopOwnsV1(ticket) and !self.layerTicketOwnsV1(ticket)) self.finishTicketV1(ticket, .{ .rejected = .runtime_stopped });
            if (self.interruption) |interrupt| if (!self.policyStopOwnsV1(interrupt.ticket)) self.finishTicketV1(interrupt.ticket, .{ .rejected = .runtime_stopped });
        }
    }

    pub fn memoryUsageV1(self: *MusicRuntime) !v1.MemoryUsageV1 {
        try self.claimControlV1();
        defer self.control_guard.store(false, .release);
        const load_state = self.load.state.load(.acquire);
        const reload_state = self.reload.state.load(.acquire);
        var result: v1.MemoryUsageV1 = .{
            .owner_storage_bytes = @sizeOf(MusicRuntime),
            .borrowed_sound_storage_bytes = @sizeOf(borrowed_sound.Anchor),
            .ingress_receipt_storage_bytes = @sizeOf(ingress.Ingress),
            .request_ownership_storage_bytes = @sizeOf(?Pending) + @sizeOf(?Preparing) + @sizeOf(?FillContinuation) + 2 * @sizeOf(?v1.RequestTicketV1) + @sizeOf(?Interruption) + @as(u64, if (self.pending != null and self.pending.?.transition != null) @sizeOf(TransitionExecution) else 0),
            .control_tick_storage_bytes = @sizeOf(@TypeOf(self.control.tick_v1)),
            .snapshot_storage_bytes = @sizeOf(@TypeOf(self.snapshots)),
            .observer_attachment_bytes = @sizeOf(@TypeOf(self.observer_storage)) + @sizeOf(@TypeOf(self.observer_handle)),
            .observer_host_storage_bytes = if (self.observer_storage != null) observer.Storage.requiredBytes() else 0,
            .trace_storage_bytes = @sizeOf(@TypeOf(self.observations)) + @sizeOf(@TypeOf(self.inputs)) + @sizeOf(@TypeOf(self.decision_records)) + @sizeOf(@TypeOf(self.planner_records)) + @sizeOf(rt.MusicGroupTrace),
            .compiled_input_bytes = try std.math.add(u64, self.load.input_bytes.load(.acquire), self.reload.input_bytes.load(.acquire)),
            // Queued can become preparing while Control samples the byte count.
            // Mark the possible unobserved work even before the Worker claims it.
            .worker_allocations_unobserved = load_state == .queued or load_state == .preparing or load_state == .sources_queued or load_state == .sources_preparing or load_state == .retiring or reload_state == .queued or reload_state == .preparing or reload_state == .sources_queued or reload_state == .sources_preparing or reload_state == .retiring,
        };
        if (self.preview_seek != null) {
            result.preview_seek_storage_bytes = @sizeOf(PreviewSeek);
            result.owner_storage_bytes += @sizeOf(PreviewSeek);
        }
        if (self.resident_state != null) {
            result.resident_state_storage_bytes = @sizeOf(ResidentState);
            result.owner_storage_bytes += @sizeOf(ResidentState);
            if (self.resident_state.?.execution != null) result.owner_storage_bytes += @sizeOf(TransitionExecution);
        }
        if (self.live_reload) |state| {
            result.owner_storage_bytes += @sizeOf(LiveReload);
            result.control_state_bytes += (state.map.description.states.len * @sizeOf(migration.StateMapping)) + (state.map.description.segments.len * @sizeOf(migration.SegmentMapping)) + (state.map.description.selectors.len * @sizeOf(migration.SelectorMapping)) + state.rules.description.entries.len * @sizeOf(epoch_policy.Entry);
        }
        result.resident_transaction_host_bytes = rt.resident_transaction_host_bytes;
        if (self.pending) |pending| {
            if (pending.transition != null) result.owner_storage_bytes += @sizeOf(TransitionExecution);
        }
        if (self.layer_config) |value| result.control_state_bytes += value.ownedBytes();
        if (self.crossfade_config) |value| result.control_state_bytes += value.ownedBytes();
        if (self.policy_storage != null) {
            result.policy_owner_storage_bytes = @sizeOf(policy.Storage);
            result.owner_storage_bytes += result.policy_owner_storage_bytes;
        }
        const generation = self.generation orelse (if (load_state == .completed or load_state == .sources_completed or load_state == .retired) self.load.candidate else null);
        var candidates: [generation_registry.capacity + 2]?*Generation = @splat(null);
        var candidate_count: usize = 0;
        for (self.generations.entries) |entry| if (entry) |value| {
            candidates[candidate_count] = value.payload;
            candidate_count += 1;
        };
        for ([_]?*Generation{ generation, if (reload_state == .held or reload_state == .completed or reload_state == .sources_completed or reload_state == .retired) self.reload.candidate else null }) |extra| if (extra) |value| {
            var present = false;
            for (candidates[0..candidate_count]) |existing| present = present or existing == value;
            if (!present) {
                candidates[candidate_count] = value;
                candidate_count += 1;
            }
        };
        for (candidates) |entry| if (entry) |value| {
            result.generation_storage_bytes += @sizeOf(Generation) + value.owners.len * @sizeOf(rt.SampleOwner);
            result.source_storage_bytes += value.sourceStorageBytes();
            result.compiled_input_bytes = try std.math.add(u64, result.compiled_input_bytes, value.retained_compiled.len);
            if (value.loaded.bus_graph) |graph| result.loaded_graph_storage_bytes = try std.math.add(u64, result.loaded_graph_storage_bytes, try graph.backingAllocationBytes());
            if (value.policies) |owned| result.bank_metadata_bytes += owned.stingers.len * @sizeOf(bank.music_policy_adapter.Stinger) + owned.acoustics.len * @sizeOf(bank.music_policy_adapter.Acoustic) + owned.ducks.len * @sizeOf(s.AutomationDuckPreset);
            if (value.layer_owner) |owner| result.control_state_bytes += owner.ownedBytes();
            if (value.readiness != null) result.control_state_bytes += @sizeOf(planner.ReadinessSnapshot);
            if (value.play_custody != null) result.control_state_bytes += @sizeOf(rt.PlayCustodyAnchor);
            inline for (std.meta.fields(s.Tables)) |field| {
                const rows = @field(value.loaded.tables, field.name);
                if (comptime std.mem.eql(u8, field.name, "blob")) result.encoded_blob_bytes += rows.len * @sizeOf(std.meta.Elem(@TypeOf(rows))) else result.bank_metadata_bytes += rows.len * @sizeOf(std.meta.Elem(@TypeOf(rows)));
            }
            for (value.owners) |owner| if (!owner.stream_token) {
                result.resident_pcm_bytes += owner.samples.len * @sizeOf(f32);
            };
            result.control_state_bytes += value.stinger_history.len * @sizeOf(assets.StingerHistory);
            if (value.director != null) result.control_state_bytes += @sizeOf(director.Director);
            if (value.layer_director_scratch != null) result.control_state_bytes += @sizeOf(director.Director);
            if (value.scratch_plan != null) result.control_state_bytes += @sizeOf(planner.TransitionPlan);
            if (value.solver) |solver| result.control_state_bytes += solver.retainedBytes();
        };
        if (self.control.source_continuity_manager != null) result.source_continuity_bytes = @sizeOf(rt.source_continuity.Manager);
        result.source_binding_storage_bytes = rt.source_binding_control_bytes;
        result.group_terminal_storage_bytes = rt.music_group_terminal_bytes;
        result.group_terminal_render_storage_bytes = rt.music_group_terminal_render_bytes;
        result.source_binding_render_bytes = rt.music_group.max_groups * rt.music_group.max_layers * @sizeOf(?*const rt.streaming.Source);
        if (self.event_adapter) |adapter| result.event_adapter_bytes = adapter.retainedBytes();
        const service = self.owned_streaming orelse (if (generation) |value| value.service else null);
        if (service) |value| {
            const usage = value.memory();
            result.stream_service_bytes = usage.owned_bytes;
            result.stream_native_bytes = usage.native_decoder_bytes;
        }
        result.control_state_bytes = try std.math.add(u64, result.control_state_bytes, try self.reloadContractBytes());
        return result;
    }

    /// Control-owned progress remains meaningful while native callbacks run.
    /// Full lifecycle drain observations require the Host's joined/parked roles.
    pub fn stopProgressV1(self: *MusicRuntime) !v1.StopProgressV1 {
        try self.claimControlV1();
        defer self.control_guard.store(false, .release);
        const published = try self.snapshotV1();
        var retired: u32 = 0;
        for (self.retired_groups) |group| retired += @intFromBool(group != null);
        return .{ .state = published.state, .active_music_groups = @intFromBool(self.active_group != null), .retired_music_groups = retired, .live_instances = self.control.telemetry().live_instances };
    }

    pub fn drainStatusV1(self: *MusicRuntime) !v1.DrainStatusV1 {
        try self.claimControlV1();
        defer self.control_guard.store(false, .release);
        var retired: u32 = 0;
        for (self.retired_groups) |group| retired += @intFromBool(group != null);
        var readers: u32 = 0;
        for (&self.snapshots) |*slot| readers += slot.readers.load(.acquire) & ((1 << 31) - 1);
        var control_drained = true;
        self.control.drainStatus() catch {
            control_drained = false;
        };
        const borrowed = self.borrowed_sounds.snapshot();
        var layer_lifetimes: u32 = 0;
        for (self.generations.entries) |entry| if (entry) |value| {
            layer_lifetimes += value.payload.layer_controller_leases;
        };
        var play_envelopes: u64 = 0;
        var play_producers: u64 = 0;
        for (self.generations.entries) |entry| if (entry) |value| {
            play_envelopes = try std.math.add(u64, play_envelopes, value.play_envelopes);
            if (value.payload.play_custody_bound) play_producers = try std.math.add(u64, play_producers, value.payload.play_custody.?.producerCount());
        };
        return .{ .preview_seek_transactions = @intFromBool(self.preview_seek != null), .resident_reload_transactions = @intFromBool(self.live_reload != null), .resident_state_transactions = @intFromBool(self.resident_state != null), .layer_controller_lifetimes = layer_lifetimes, .play_envelope_reservations = play_envelopes, .play_active_producers = play_producers, .borrowed_sound_leases = borrowed.outstanding, .borrowed_sound_returns_pending = borrowed.returned_uncollected, .policy_request_slots = if (self.policy_storage) |storage| storage.requestCount() else 0, .policy_occupied_slots = if (self.policy_storage) |storage| storage.retainedCount() else 0, .policy_retained_results = if (self.policy_storage) |storage| storage.resultCount() else 0, .policy_physical_lifetimes = if (self.policy_storage) |storage| storage.physicalCount() else 0, .policy_graph_retained = if (self.policy_storage) |storage| storage.graph != null else false, .source_continuity_descriptors = if (self.control.source_continuity_manager) |manager| @intCast(manager.retained()) else 0, .event_instances = if (self.event_adapter) |adapter| @intCast(adapter.active) else 0, .event_terminal_credits = if (self.event_adapter) |adapter| @intCast(adapter.completion_count) else 0, .prepared_stream_windows = if (self.generation) |value| value.windowCount() else 0, .provider_sources = if (self.generation) |value| @intCast(value.sources.len - value.closed_sources.load(.acquire)) else 0, .source_close_pending = if (self.generation) |value| value.retirement.load(.acquire) != .active and !value.retirementAcknowledged() else false, .shutting_down = self.shutdown_requested.load(.acquire), .unloading = self.unloading, .queued_requests = self.ingress.occupied.load(.acquire), .active_producers = self.active_producers.load(.acquire), .in_flight_requests = @as(u32, @intFromBool(self.in_flight != null)) + @intFromBool(self.layer_in_flight != null) + @intFromBool(self.interruption != null) + (if (self.policy_storage) |storage| storage.requestCount() else @as(u32, 0)), .load_transactions = @as(u32, @intFromBool(self.load.state.load(.acquire) != .idle)) + @intFromBool(self.reload.ownsResources()), .worker_active = self.worker_guard.load(.acquire), .pending_plans = @as(u32, @intFromBool(self.pending != null)) + (if (self.device_stream_candidate) |candidate| @as(u32, @intFromBool(candidate.block != null)) else 0) + (if (self.preview_seek) |seek| @as(u32, @intFromBool(seek.block != null)) else 0) + @intFromBool(self.fill_continuation != null) + (if (self.policy_storage) |storage| storage.planCount() else @as(u32, 0)), .active_music_groups = @intFromBool(self.active_group != null), .retired_music_groups = retired, .sample_leases = self.controlSnapshot().outstanding_sample_leases, .live_instances = self.control.telemetry().live_instances, .snapshot_readers = readers, .control_drained = control_drained, .last_error = self.last_error };
    }
    fn validateFinalizationBoundary(self: *MusicRuntime, session: if (@import("builtin").is_test) *TestFinalization.Session else void, service: *rt.streaming.Service) !void {
        try session.identity(self, &self.test_finalization);
        if (session.bootstrap != null) _ = try session.validateJoined(self);
        if (@import("builtin").is_test) if ((self.renderer.test_render_admission_hook != null or self.renderer.test_owned_render_facts != null or self.control.test_owned_control_facts != null) and !session.hasNativeBorrow()) return error.DrainPending;
        if (!self.control_guard.load(.acquire) or !self.worker_guard.load(.acquire) or
            !self.control_torn_down or !self.shutdown_requested.load(.acquire) or self.control.streaming_service != null or
            self.generation != null or self.worker_generation.load(.acquire) != null or self.outgoing_generation.load(.acquire) != null or
            self.worker_streaming.load(.acquire) != null or self.owned_streaming != service or self.generations.count() != 0 or
            self.load.state.load(.acquire) != .idle or self.load.candidate != null or self.reload.ownsResources() or self.live_reload != null or
            self.active_producers.load(.acquire) != 0 or self.borrowed_sounds.outstanding != 0 or
            self.control.readiness_binding != null or self.control.control_frontier_binding != null or self.control.stream_acceptance_binding != null or
            self.control.offline_causal_replay != null or
            (!session.hasNativeBorrow() and (self.control.prerequisite_order != null or self.control.prerequisite_terminal_order != null or self.renderer.prerequisite_order != null)) or
            self.renderer.offline_causal_replay != null or self.renderer.render_causal_binding != null) return error.DrainPending;
        if (session.bootstrap != null) try session.validateBorrowSet(self, service) else if (self.test_live_bootstrap != null) return error.DrainPending;
        const custody = if (self.service_custody) |*value| value else return error.InvalidState;
        if (custody.service != service) return error.InvalidState;
        for (self.group_generation_credits) |credit| if (credit != null) return error.DrainPending;
        for (self.control.snapshots) |slot| for (slot.generation_credits) |credit| if (credit != null) return error.DrainPending;
        // Only the exact joined Service set was authenticated above. Unknown
        // bindings and all actual physical work retain the original rejection.
        if ((!session.hasNativeBorrow() and (service.readiness_supply_sink != null or service.readiness_lifecycle_sink != null or service.public_causal_worker_sink != null)) or
            service.public_causal_exclusion != null or service.public_causal_consumed_sink != null or
            service.offline_causal_replay != null or service.replay_mode or
            (session.bootstrap == null and (service.prerequisite_order_mode != .prerequisite or service.live_slot_guard_points or service.live_availability_points)) or
            (session.bootstrap == null and (service.test_checkpoint_hook != null or service.test_worker_clock_hook != null or service.test_acceptance_hook != null)) or service.test_consumed_hook != null or
            service.test_readiness_hook != null or service.test_availability_hook != null or service.test_supply_hook != null or service.test_supply_return_hook != null or service.test_worker_clock_observer != null or service.test_frontier_hook != null or
            service.test_worker_hook != null or service.test_worker_stage_hook != null or service.test_publication_hook != null) return error.DrainPending;
        if (session.hasNativeBorrow()) try session.validateNativeFinal();
        if (session.bootstrap != null and session.phase.load(.acquire) != .borrow_ended) {
            if (custody.generation_leases != 0) return error.DrainPending;
            try service.validatePhysicalDestroyQuiescent();
        } else try custody.validateDestroyQuiescent();
    }
    /// Host must stop callbacks/producers before this operation. Control teardown
    /// consumes any unpolled receipts. Failure preserves all storage for retry.
    pub fn destroyQuiescent(self: *MusicRuntime) !ShutdownReport {
        return self.destroyQuiescentOwned(.ordinary, {});
    }
    const DestroyMode = enum { ordinary, test_staged, test_empty };
    fn DestroyResult(comptime mode: DestroyMode) type {
        return if (mode == .test_staged) TestFinalization.Outcome else ShutdownReport;
    }
    fn destroyQuiescentOwned(self: *MusicRuntime, comptime mode: DestroyMode, request: if (mode == .test_staged) TestFinalization.Request else if (mode == .test_empty) TestFinalization.EmptyRequest else void) !DestroyResult(mode) {
        if (@import("builtin").is_test) if (mode == .ordinary) if (self.test_finalization) |session| {
            if (session.bootstrap != null) return error.InvalidState;
        };
        if (mode == .test_empty) try request.session.validateEmptyRequest(self, request.park, request.quiescence);
        if (mode == .test_staged) {
            try self.checkControlIdentityV1();
            try request.session.request(self, &self.test_finalization, request.park, request.quiescence);
            if (request.session.blocked()) {
                const capability = request.session.capability orelse return error.InvalidState;
                if (!std.meta.eql(capability.park, request.park) or !std.meta.eql(capability.quiescence, request.quiescence)) return error.InvalidState;
                try request.session.validateCapability(self, &self.test_finalization, capability);
            }
        }
        if (self.causal_driver_pin != null or self.causal_sink != null) return error.DrainPending;
        if (self.mode == .versioned) {
            if (mode == .test_staged) try self.checkControlIdentityV1() else try self.checkControlV1();
        }
        if (self.control_guard.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.DrainPending;
        errdefer self.control_guard.store(false, .release);
        // A retained late capability has already completed these original
        // irreversible retirements. Retry only revalidates the final boundary.
        if (!(mode == .test_staged and request.session.blocked())) {
            // A closed witness pins this exact owner until explicit detach.
            if (self.control.readiness_binding != null) return error.DrainPending;
            if (!self.shutdown_requested.load(.acquire)) return error.InvalidState;
            self.closeBorrowedSounds();
            self.collectBorrowedSounds();
            if (self.mode == .versioned) {
                if (mode == .test_staged) try self.checkControlIdentityV1() else try self.checkControlV1();
                if (self.worker_guard.load(.acquire) or self.active_producers.load(.acquire) != 0) return error.DrainPending;
                if (!self.shutdown_requested.load(.acquire)) return error.InvalidState;
                try self.collectLoad();
                if (self.load.state.load(.acquire) != .idle or self.reload.ownsResources()) return error.DrainPending;
                try self.collectPolicies();
                if (!self.control_torn_down) try self.collectLayerControllers(self.control);
                try self.collectShutdownV1();
                self.rejectQueuedV1();
                if (self.policy_storage) |storage| if (storage.physicalCount() != 0 or storage.bootstrap != null or storage.graph != null) return error.DrainPending;
                if (self.ingress.occupied.load(.acquire) != 0 or self.pending != null or self.layer_in_flight != null) return error.DrainPending;
                if (self.device_stream_candidate != null or self.device_event != null) return error.DrainPending;
                // Drain our group ledger before generic Control teardown, which
                // otherwise could reclaim handles that a retry would still visit.
                for (self.retired_groups) |group| if (group != null) return error.DrainPending;
            } else if (!self.control_torn_down) {
                // Later retries may still wait for borrowed/provider returns, but
                // must not revisit group/schedule handles already reclaimed below.
                try self.collectShutdownCompatibility();
            }
            if (!self.shutdown_requested.load(.acquire)) return error.InvalidState;
            if (self.event_adapter != null) return error.DrainPending;
            for (&self.snapshots) |*slot| if (slot.readers.load(.acquire) != 0) return error.DrainPending;
            try self.collectPreviewSeekRetirement();
            if (self.preview_seek != null) return error.DrainPending;
            if (self.resident_state) |state| {
                try self.collectResidentWindows(state);
                if (!state.terminal or state.lower != null or state.block != null or self.residentResourcesPending(state)) return error.DrainPending;
                self.discardResidentState();
            }
            if (self.live_reload) |state| {
                if (state.result == .pending or state.lower != null or state.block != null or self.reload.ownsResources()) return error.DrainPending;
                if (!state.streamed or !state.committed) self.discardLiveReload();
            }
            if (self.generation) |generation| if (generation.hasControlLeases()) return error.DrainPending;
            if (!self.control_torn_down) {
                try self.control.destroy();
                self.control_torn_down = true;
            }
            try self.collectDetachedGenerationWindows();
            if (self.live_reload) |state| {
                try self.collectStreamReloadRetirement();
                if (!state.outgoing_released) return error.DrainPending;
                self.discardLiveReload();
            }
            if (self.generation) |generation| {
                // Detached completion routing above included this current owner
                // and all retained outgoing owners before any provider retirement.
                // Host Control teardown has released its physical owners. Preserve
                // 511's shutdown intrinsic-retirement semantics, while exact borrow
                // credits still block provider/Generation disposal until collection.
                for (generation.owners) |*owner| owner.retire();
                if (self.hasBorrowedSounds(generation)) return error.DrainPending;
                try generation.requestRetirement();
                if (!generation.retirementAcknowledged()) return error.DrainPending;
                self.worker_generation.store(null, .release);
                if (self.worker_guard.cmpxchgStrong(false, true, .acquire, .monotonic) != null) return error.DrainPending;
                defer self.worker_guard.store(false, .release);
                self.generation = null;
                generation.withdraw();
                generation.destroy();
                self.assertServiceCredits();
            }
            try self.destroyRetainedGenerations();
        }
        if (self.service_custody) |*custody| {
            std.debug.assert(self.owned_streaming == custody.service);
            self.worker_streaming.store(null, .release);
            if (self.worker_guard.cmpxchgStrong(false, true, .acquire, .monotonic) != null) {
                if (mode == .test_staged) if (!request.session.blocked()) self.worker_streaming.store(custody.service, .release);
                return error.DrainPending;
            }
            defer self.worker_guard.store(false, .release);
            if (mode == .test_staged) {
                // A pre-token failure restores the original Worker publication;
                // an issued/sealing/sealed identity can never resume that work.
                errdefer if (!request.session.blocked()) self.worker_streaming.store(custody.service, .release);
                try self.validateFinalizationBoundary(request.session, custody.service);
                try request.session.request(self, &self.test_finalization, request.park, request.quiescence);
                switch (request.session.phase.load(.acquire)) {
                    .registered => {
                        if (self.test_finalization_nonce == std.math.maxInt(u64)) return error.IdentityExhausted;
                        self.test_finalization_nonce += 1;
                        const capability: TestFinalization.Capability = .{ .owner = self, .session = request.session, .service = custody.service, .park = request.park, .nonce = self.test_finalization_nonce, .quiescence = request.quiescence };
                        request.session.issued(capability);
                        // Unlike ordinary success, this new success retains self.
                        self.control_guard.store(false, .release);
                        return .{ .ready_for_final_free = capability };
                    },
                    .issued => {
                        const capability = request.session.capability.?;
                        self.control_guard.store(false, .release);
                        return .{ .ready_for_final_free = capability };
                    },
                    .sealed, .borrow_ended => {},
                    else => return error.InvalidState,
                }
            }
            custody.destroy() catch |err| {
                if (mode == .ordinary) self.worker_streaming.store(custody.service, .release);
                return err;
            };
            self.service_custody = null;
            self.owned_streaming = null;
        } else if (mode == .test_staged) return error.InvalidState;
        if (mode == .test_empty and request.session.hasNativeBorrow()) {
            // Revalidate the complete set after actual Control destruction.
            // Clearing owner-embedded group_events must precede owner free;
            // no fallible operation follows this exact empty-custody commit.
            try request.session.validateEmptyRequest(self, request.park, request.quiescence);
            try request.session.validateNativeFinal();
            request.session.bootstrap.?.clearControlHooks();
        }
        std.debug.assert(self.generations.count() == 0);
        for (self.group_generation_credits) |credit| std.debug.assert(credit == null);
        for (self.control.snapshots) |slot| for (slot.generation_credits) |credit| std.debug.assert(credit == null);
        if (self.policy_storage) |storage| {
            std.debug.assert(storage.physicalCount() == 0);
            self.allocator.destroy(storage);
            self.policy_storage = null;
        }
        self.closeObserver(.runtime_destroyed);
        self.renderer.music_trace = null;
        self.control.music_runtime = null;
        const allocator = self.allocator;
        const anchor = self.borrowed_sounds;
        std.debug.assert(!anchor.accepting and anchor.outstanding == 0);
        if (self.layer_config) |*value| value.deinit();
        if (self.crossfade_config) |*value| value.deinit();
        const report: ShutdownReport = .{ .sample_leases = 0, .live_instances = 0 };
        // No fallible step or canonical emission follows. The Host still owns
        // the pinned sink context until this return and its real producer joins.
        if (self.control.stream_input_evidence_failures != 0 or self.group_events.incomplete.load(.acquire) or self.replay_unsupported or self.trace_counter_exhausted) self.invalidateSemanticOutputV1();
        self.semantic_output_sink = null;
        // Native teardown has acquired all publications and the host has
        // excluded callback/Worker entry. No callback or failure follows.
        if (self.live_semantic_service_hooks != null) {
            self.control.live_semantic_hooks = null;
            self.renderer.live_semantic_hooks = null;
            self.control.scheduled.live_semantic_hooks = null;
            self.group_events.live_semantic_hooks = null;
            self.live_semantic_service_hooks = null;
        }
        allocator.destroy(self);
        allocator.destroy(anchor); // LAST: all actual release publications acquired.
        if (mode == .test_staged) request.session.destroyed(report);
        if (mode == .test_empty) request.session.destroyedEmpty(request.park, report);
        return if (mode == .test_staged) .{ .destroyed = report } else report;
    }
};
fn buildId(hash: [32]u8) u64 {
    return std.mem.readInt(u64, hash[0..8], .little) | 1;
}
fn find(rows: anytype, id: u64) !u32 {
    for (rows, 0..) |row, i| if (row.key.id == id) return @intCast(i);
    return error.InvalidMusicGraph;
}
fn publicError(err: anyerror) api.MusicError {
    return switch (err) {
        error.VoiceBudgetExceeded => error.VoiceBudgetExceeded,
        error.CommandQueueFull => error.CommandQueueFull,
        error.TransitionNotFound => error.TransitionNotFound,
        error.StaleAssetGeneration => error.StaleAssetGeneration,
        error.UnsupportedCapability => error.UnsupportedCapability,
        else => error.InvalidState,
    };
}

fn failureV1(err: anyerror) v1.FailureV1 {
    return switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.SourceUnavailable => .source_unavailable,
        error.SourceReadFailed, error.InvalidSource, error.InvalidBinding => .source_io,
        error.SourceCloseFailed => .source_close,
        error.StreamUnderrun => .stream_underrun,
        error.UnsupportedCapability, error.UnknownPhysicalOwnership, error.UnsupportedOperation, error.UnsupportedLayerPolicy, error.UnsupportedLayerSource => .unsupported_capability,
        error.StaleAssetGeneration, error.InvalidHandle => .stale_bank,
        error.WrongContext => .wrong_context,
        error.InvalidOrder => .invalid_order,
        error.ResourceLimitExceeded, error.ByteCapacityExceeded, error.LeaseCapacityExceeded, error.HistoryCapacityExceeded, error.RegistryFull, error.ArithmeticOverflow, error.Overflow, error.IdentityExhausted, error.ContinuityCapacity, error.StreamCapacity, error.DuckCapacity, error.DuckGenerationExhausted, error.PreparedCapacity, error.ProfileExceeded, error.StateBudgetExceeded, error.LayerProgramBudgetExceeded, error.UnsafeFrameRange => .resource_limit,
        error.RequestInProgress, error.ResidentTransactionBusy, error.DuckBusy, error.PendingAutomation, error.RollbackPending, error.LayerProgramBusy => .request_in_progress,
        error.StaleDuck, error.UnknownDuckPreset, error.InvalidDuckIdentity => .invalid_state,
        error.RuntimeStopped => .runtime_stopped,
        error.CommandQueueFull => .command_queue_full,
        error.TransitionNotFound => .transition_not_found,
        error.VoiceBudgetExceeded => .voice_budget_exceeded,
        error.InvalidState, error.InvalidMode, error.BindingBusy, error.StaleBinding, error.StaleLayerProgram => .invalid_state,
        else => .invalid_bank,
    };
}

/// Keep new clock classification local to the opt-in path. Legacy callers
/// retain their historical FailureV1 mapping.
fn boundaryStopError(err: anyerror) anyerror {
    return switch (err) {
        error.OutOfRange => error.ResourceLimitExceeded,
        error.ClockPaused, error.InvalidTempo, error.NonClosingLoop, error.DeviceDiscontinuity => error.InvalidState,
        else => err,
    };
}
