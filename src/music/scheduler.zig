//! Fixed-storage absolute-frame command publication. Control owns construction and
//! reclamation; one render owner owns all gates, execution and phase receipts.
//! No payload pointer is ever freed by render. Terminal slot storage is the
//! lossless receipt queue: a slot cannot be reused until Control acknowledges it.
const std = @import("std");
const music = @import("music");
const order = @import("sme-capture-order");
const semantic = @import("sme-live-semantic");
pub const trace = @import("sme-trace").schema;
pub const Error = error{ InvalidState, InvalidArgument, CommandQueueFull, StaleAssetGeneration, LateCommand, UnsafeFrameRange };
/// Exact failed pre-allocation admission acquire. The live Stop caller owns
/// this stack copy; it cannot classify any later prepare/publish failure.
pub const LivePrepareLateV1 = struct {
    start_frame: u64,
    end_frame: u64,
    observed_horizon: u64,
    minimum_frame: u64,
};
pub const SchedulerCapacityProfile = struct {
    request_capacity: u32 = 4096,
    immediate_capacity: u32 = 4096,
    block_capacity: u32 = 64,
    commands_per_block: u32 = 32,
    commands_per_group: u32 = 8,
    command_capacity: u32 = 2048,
    receipt_capacity: u32 = 2176,
    emergency_capacity: u32 = 32,
    epoch_fence_capacity: u32 = 64,
    plan_capacity: u32 = 64,
    phases_per_plan: u32 = 64,
    commands_per_plan: u32 = 512,
    min_plan_lead_frames: u32 = 64,
    late_race_budget_frames: u32 = 64,
    max_commit_span_frames: u32 = 64,
    emergency_ramp_frames: u32 = 32,
    pub fn validate(p: SchedulerCapacityProfile) Error!void {
        const product = std.math.mul(u32, p.block_capacity, p.commands_per_block) catch return error.InvalidArgument;
        const per_plan = std.math.mul(u32, p.phases_per_plan, p.commands_per_group) catch return error.InvalidArgument;
        const receipts = std.math.add(u32, product, std.math.mul(u32, p.block_capacity, 2) catch return error.InvalidArgument) catch return error.InvalidArgument;
        if (p.request_capacity == 0 or p.immediate_capacity == 0 or p.block_capacity == 0 or p.commands_per_group == 0 or p.commands_per_group > p.commands_per_block or p.command_capacity != product or p.receipt_capacity < receipts or p.emergency_capacity == 0 or p.epoch_fence_capacity == 0 or p.plan_capacity == 0 or p.phases_per_plan == 0 or p.phases_per_plan > 64 or p.commands_per_plan != per_plan or p.epoch_fence_capacity > p.block_capacity or p.max_commit_span_frames == 0 or p.min_plan_lead_frames < p.max_commit_span_frames or p.late_race_budget_frames < p.max_commit_span_frames or p.emergency_ramp_frames == 0) return error.InvalidArgument;
    }
};
pub const default_profile: SchedulerCapacityProfile = .{};
pub const block_capacity = default_profile.block_capacity;
pub const commands_per_block = default_profile.commands_per_block;
pub const commands_per_group = default_profile.commands_per_group;
pub const emergency_capacity = default_profile.emergency_capacity;
pub const Handle = struct { index: u16, generation: u64 };
pub const render_observation = @import("render_observation.zig");
pub const State = render_observation.State;
pub const Outcome = enum { executed, cancelled, rejected };
pub const GateStage = enum { acquired, before_group, after_group, before_span, invalidation_target, acquire_scan, command_receipt, after_acquire_scan, executed_phase, terminal_state };
pub const GateHook = struct { context: *anyopaque, call: *const fn (*anyopaque, GateStage) void };
/// Offline barriers around the actual Control release, absent in shipping state.
pub const PublicationStage = enum { before_release, after_release };
pub const PublicationHook = struct { context: *anyopaque, call: *const fn (*anyopaque, PublicationStage, Handle) void };
/// Private offline replay checkpoints. These callbacks may park only the
/// executor's own offline threads. A live/capture owner never installs them.
pub const OfflineSite = enum { scheduler_validate, scheduler_ack_terminal, scheduler_control_scan, scheduler_reap_phase, scheduler_reap_readers, scheduler_slot_return, scheduler_scan, scheduler_publication, scheduler_acquired, scheduler_phase, scheduler_terminal, scheduler_receipt, scheduler_horizon, scheduler_prepare_horizon, scheduler_invalidation_before_scan, scheduler_invalidation_after_scan, scheduler_invalidation_pre_claim, scheduler_invalidation_poll, scheduler_invalidation_publication };
pub const OfflineCheckpoint = struct { site: OfflineSite, edge: enum { before, after }, index: u64 = 0, generation: u64 = 0, value: u64 = 0 };
pub const OfflineReplayHooks = struct {
    context: *anyopaque,
    checkpoint: *const fn (*anyopaque, OfflineCheckpoint) void,
    /// Explicit opt-in for the semantic phase/poll/publication vocabulary.
    /// Old replay profiles keep their existing callback sequence unchanged.
    semantic_invalidations: bool = false,
};
/// No Scheduler state is latched by these Render-owned pass markers.
/// Pre-claim iteration is zero-based within this gate's arbitration loop.
pub const InvalidationPhase = enum { before_scan, after_scan, pre_claim };
pub const CausalPublication = struct { block: Handle, batch_id: u64, content_hash: trace.Hash, sequence: u64 };
/// The Control producer copies a successful actual release. The sink may only
/// append to its bounded Control-owned lane; it cannot affect publication.
pub const CausalPublicationSink = struct { context: *anyopaque, emit: *const fn (*anyopaque, CausalPublication) void };
pub const CausalProgress = struct {
    site: enum { scheduler_acquired, scheduler_phase, scheduler_receipt, scheduler_terminal },
    index: u64,
    generation: u64,
    value: u64,
    frame: u64,
    command_id: u64 = 0,
};
/// Separate Render producer; never writes the Control publication lane.
pub const CausalProgressSink = struct { context: *anyopaque, emit: *const fn (*anyopaque, CausalProgress) void };
pub const CommandIdentity = struct {
    command_id: u64,
    token: music.PhaseToken,
    phase_order: u32,
    execute_frame: u64,
    group_id: u64,
};
pub const Invalidation = struct {
    target: Handle = .{ .index = std.math.maxInt(u16), .generation = 0 },
    plan_target: ?Handle = null,
    requested_frame: u64,
    /// 0 leaves the current epoch unchanged; otherwise strictly advances it.
    next_transport_epoch: u64 = 0,
    next_asset_generation: u64 = 0,
    emergency_stop_music: bool = false,
};
pub const Counters = struct {
    blocks_high_water: std.atomic.Value(u32) = .init(0),
    command_high_water: std.atomic.Value(u32) = .init(0),
    emergency_high_water: std.atomic.Value(u32) = .init(0),
    plan_overflow: std.atomic.Value(u64) = .init(0),
    fence_overflow: std.atomic.Value(u64) = .init(0),
    overflow: std.atomic.Value(u64) = .init(0),
    late: std.atomic.Value(u64) = .init(0),
    rejected: std.atomic.Value(u64) = .init(0),
    receipt_backpressure: std.atomic.Value(u64) = .init(0),
};
pub const Telemetry = struct { plan_overflow: u64, fence_overflow: u64, blocks_high_water: u32, command_high_water: u32, emergency_high_water: u32, overflow: u64, late: u64, rejected: u64, receipt_backpressure: u64 };

/// Control-only copied observations. A chunk preserves sequential loads, not a
/// snapshot. Optional fields are absent when the original short circuit did not
/// reach that read. Callbacks must not inspect owners or retain borrowed data.
pub const ControlOperationKind = enum { prepare, reconcile, reap, acknowledge };
pub const ControlResult = enum {
    success,
    invalid_state,
    invalid_argument,
    command_queue_full,
    stale_asset_generation,
    late_command,
    unsafe_frame_range,

    fn fromError(err: Error) ControlResult {
        return switch (err) {
            error.InvalidState => .invalid_state,
            error.InvalidArgument => .invalid_argument,
            error.CommandQueueFull => .command_queue_full,
            error.StaleAssetGeneration => .stale_asset_generation,
            error.LateCommand => .late_command,
            error.UnsafeFrameRange => .unsafe_frame_range,
        };
    }
};
pub const ControlOperation = struct {
    operation_id: u64,
    parent_operation_id: u64,
    kind: ControlOperationKind,
    target: ?Handle = null,
    /// Null denotes begin; a result denotes the matching end.
    result: ?ControlResult = null,
    sequence_exhausted: bool = false,
};
pub const ControlScan = struct {
    pub const slots_per_chunk = 32;
    operation_id: u64,
    first_slot: u16,
    count: u16 = 0,
    /// Two four-bit states per byte, in increasing slot order.
    states: [slots_per_chunk / 2]u8 = @splat(0),

    pub fn state(self: ControlScan, offset: usize) State {
        std.debug.assert(offset < self.count);
        return @enumFromInt((self.states[offset / 2] >> @as(u3, @intCast((offset % 2) * 4))) & 15);
    }
    fn put(self: *ControlScan, value: State) void {
        const offset: usize = self.count;
        std.debug.assert(offset < slots_per_chunk);
        self.states[offset / 2] |= @as(u8, @intFromEnum(value)) << @as(u3, @intCast((offset % 2) * 4));
        self.count += 1;
    }
};
pub const ControlValidation = struct {
    operation_id: u64,
    target: Handle,
    state: ?State = null,
    generation: ?u64 = null,
    valid: bool = false,
};
pub const ControlPreparedCancellation = struct {
    operation_id: u64,
    block: Handle,
    plan: Handle,
    cancelled: bool,
    /// Cancellation metadata is copied only after the true acquire.
    cancel_frame: ?u64 = null,
    cancel_requested: ?u64 = null,
    cancel_horizon: ?u64 = null,
    cancel_before: ?trace.ExecutionState = null,
    cancel_reason: ?trace.Reason = null,
    /// These are the two distinct existing cancelSlot acquires.
    receipt_executed_count: ?u16 = null,
    disposition_executed_count: ?u16 = null,
    terminal_stored: bool = false,
};
pub const ControlObservation = union(enum) {
    operation: ControlOperation,
    prepare_horizon: struct {
        operation_id: u64,
        start: u64,
        end: u64,
        command_count: u16,
        declared_phases: ?u16,
        observation_only: bool,
        horizon: u64,
    },
    slot_scan: ControlScan,
    prepared_cancellation: ControlPreparedCancellation,
    plan_reap: struct {
        operation_id: u64,
        plan: Handle,
        fence_index: ?u16 = null,
        block_refs: u16,
        intent_refs: u16,
        transaction_refs: u16,
        total_phases: ?u16 = null,
        cancelled: bool,
        executed_count: ?u16 = null,
        readers_cas_reached: bool = false,
        /// Null after a reached CAS means the expected zero was acquired.
        readers_cas_failure: ?u32 = null,
        fence_refs_before: ?u16 = null,
        fence_refs_after: ?u16 = null,
        returned: bool = false,
    },
    prepared: struct {
        operation_id: u64,
        block: Handle,
        plan: Handle,
        batch_id: u64,
        fence_index: u16,
        fence_refs: u16,
        plan_block_refs: u16,
        existing_plan: bool,
        first_phase: u16,
        phase_count: u16,
        total_phases: u16,
    },
    acknowledge_validation: ControlValidation,
    acknowledge_terminal: struct {
        operation_id: u64,
        block: Handle,
        state: State,
        invalidation_refs: ?u16 = null,
        queue_refs: ?u8 = null,
        eligible: bool = false,
    },
    slot_return: struct {
        operation_id: u64,
        block: Handle,
        plan: Handle,
        plan_block_refs_before: u16,
        plan_block_refs_after: u16,
    },
};
pub const ControlSink = struct {
    context: *anyopaque,
    emit: *const fn (*anyopaque, ControlObservation) void,
};
comptime {
    if (@sizeOf(ControlObservation) > 320) @compileError("scheduler Control observation exceeds bounded payload");
}

pub fn Scheduler(comptime Payload: type) type {
    return struct {
        const Self = @This();
        pub const Command = struct { identity: CommandIdentity, payload: Payload, sequence: u64 = 0, ordinal: u16 = 0 };
        pub const Block = struct {
            id: u64,
            content_hash: trace.Hash,
            start_frame: u64,
            end_frame: u64,
            commands: [commands_per_block]Command = undefined,
            count: u16 = 0,
        };
        pub const Slot = struct {
            state: std.atomic.Value(State) = .init(.free),
            generation: u64 = 0,
            block: Block = undefined,
            next_command: u16 = 0,
            executed_count: u16 = 0, // phases, never individual commands
            phase_count: u16 = 0,
            next_phase: u16 = 0,
            queue_refs: u8 = 0, // Control ticket keeps a cancelled queued slot alive
            invalidation_refs: u16 = 0, // Control only; prevents recycle while Render reads intents
            fence_index: u16 = 0,
            plan_index: u16 = 0,
            first_phase: u16 = 0,
            disposition: music.PlanExecutionState = .prepared,
            receipts: [commands_per_block]trace.ScheduleRecord = undefined,
            receipt_count: u16 = 0,
            published_receipts: std.atomic.Value(u16) = .init(0),
            admission: ?trace.Admission = null,
            cancellation: ?trace.ScheduleRecord = null,
            /// Control only. Immutable command storage remains pinned until release.
            polled: bool = false,
            reconciled: bool = false,
            /// Exact phase ownership marker; later block release never reads a recycled transaction.
            transaction_reconciled: [commands_per_block]bool = @splat(false),
        };
        pub const Intent = struct {
            state: std.atomic.Value(u8) = .init(0), // free, prepared, published, complete
            generation: u64 = 0,
            value: Invalidation = undefined,
            token: music.PhaseToken = undefined,
            batch_id: u64 = 0,
            content_hash: trace.Hash = undefined,
            sequence: u64 = 0,
            plan_index: u16 = 0,
            target_has_slot: bool = true,
            // Control-exclusive device fence may reject while the immutable
            // handle still sits in reserved ingress. Keep state=prepared until
            // publication consumes that handle, then expose the stored terminal.
            device_rejected: bool = false,
            admission: ?trace.Admission = null,
            receipt: ?trace.ScheduleRecord = null,
        };
        /// Control owns the reference count. Render alone advances the epoch.
        /// All live block stages retain this cell, including old prepared work.
        pub const EpochFence = struct {
            plan_id: u64 = 0,
            references: u16 = 0,
            prepared_epoch: u64 = 0,
            admitted_epoch: std.atomic.Value(u64) = .init(0),
        };
        pub const Plan = struct {
            const writing: u32 = 1 << 31;
            readers: std.atomic.Value(u32) = .init(writing),
            active: bool = false, // Control only, retained by blocks/intents/open suffix
            generation: u64 = 0,
            token: music.PhaseToken = undefined,
            fence_index: u16 = 0,
            block_refs: u16 = 0,
            intent_refs: u16 = 0,
            transaction_refs: u16 = 0,
            total_phases: u16 = 0,
            prepared_phases: u16 = 0,
            queued_phases: u16 = 0,
            command_count: u16 = 0,
            command_ids: [default_profile.commands_per_plan]u64 = undefined,
            phase_ids: [default_profile.phases_per_plan]music.PhaseId = undefined,
            phase_groups: [default_profile.phases_per_plan]u64 = undefined,
            last_frame: u64 = 0,
            executed_frames: [default_profile.phases_per_plan]u64 = undefined,
            executed_ordinals: [default_profile.phases_per_plan]u64 = undefined,
            executed_count: std.atomic.Value(u16) = .init(0),
            acquired: std.atomic.Value(bool) = .init(false),
            published: std.atomic.Value(bool) = .init(false),
            cancelled: std.atomic.Value(bool) = .init(false),
            cancel_frame: u64 = 0,
            cancel_requested: u64 = 0,
            cancel_horizon: u64 = 0,
            cancel_before: music.PlanExecutionState = .prepared,
            cancel_reason: trace.Reason = .stale_epoch,
        };
        plans: [default_profile.plan_capacity]Plan = [_]Plan{.{}} ** default_profile.plan_capacity,
        fences: [default_profile.epoch_fence_capacity]EpochFence = [_]EpochFence{.{}} ** default_profile.epoch_fence_capacity,
        context_id: u64 = 0,
        slots: [block_capacity]Slot = [_]Slot{.{}} ** block_capacity,
        intents: [emergency_capacity]Intent = [_]Intent{.{}} ** emergency_capacity,
        intent_order: [emergency_capacity]u16 = undefined,
        intent_write: std.atomic.Value(usize) = .init(0),
        intent_read: std.atomic.Value(usize) = .init(0),
        render_frame: std.atomic.Value(u64) = .init(0),
        commit_horizon: std.atomic.Value(u64) = .init(0),
        counters: Counters = .{},
        shutdown_requested: std.atomic.Value(bool) = .init(false),
        next_batch_id: u64 = 1,
        latest_plan_id: u64 = 0,
        latest_plan_epoch: u64 = 0,
        transport_epoch: u64 = 1, // render owner only
        asset_generation: u64 = 1, // render owner only
        gate_number: u64 = 0,
        gate_order: u32 = 0,
        /// Actual execution claim order, distinct from admission gate_order.
        execution_ordinal: u64 = 0,
        test_hook: if (@import("builtin").is_test) ?GateHook else void = if (@import("builtin").is_test) null else {},
        test_publication_hook: if (@import("builtin").is_test) ?PublicationHook else void = if (@import("builtin").is_test) null else {},
        offline_causal_replay: ?OfflineReplayHooks = null,
        /// Private partial observation only. Same pinned per-role collectors as
        /// the other subsystems; immutable binding while producers can run.
        prerequisite_order: ?order.Roles = null,
        /// Collector-free finite cuts. Immutable from excluded startup through
        /// actual Control/Render exclusion and joins at the matching detach.
        /// Capture callbacks only copy into bounded role-local storage; they
        /// cannot wait, allocate, reenter, or change any computed result.
        live_semantic_hooks: ?semantic.Binding = null,
        public_causal_publication_sink: ?CausalPublicationSink = null,
        public_causal_progress_sink: ?CausalProgressSink = null,

        test_scan_index: if (@import("builtin").is_test) usize else void = if (@import("builtin").is_test) 0 else {},

        /// Installed by the runtime only during an admitted observed tick.
        control_sink: ?ControlSink = null,
        control_operation_sequence: u64 = 0,
        control_parent_operation: u64 = 0,

        /// Host custody is required: exclude Control and Render before calling,
        /// and keep the binding, context and queues pinned until genuine joins.
        /// The checks below reject noninitial/occupied state; none proves that
        /// another caller is excluded. Capture uses nonblocking output callbacks;
        /// only a separate offline owner may coordinate its own threads here.
        pub fn attachLiveSemanticQuiescent(self: *Self, binding: semantic.Binding) Error!void {
            if (self.live_semantic_hooks != null or self.prerequisite_order != null or
                self.offline_causal_replay != null or self.control_sink != null or
                self.control_parent_operation != 0 or self.control_operation_sequence != 0 or
                self.next_batch_id != 1 or self.latest_plan_id != 0 or self.latest_plan_epoch != 0 or
                self.gate_number != 0 or self.gate_order != 0 or self.execution_ordinal != 0 or
                self.intent_write.load(.acquire) != 0 or self.intent_read.load(.acquire) != 0 or
                self.render_frame.load(.acquire) != 0 or self.commit_horizon.load(.acquire) != 0 or
                self.shutdown_requested.load(.acquire)) return error.InvalidState;
            if (comptime @import("builtin").is_test) {
                if (self.test_hook != null or self.test_publication_hook != null) return error.InvalidState;
            }
            try self.validateSemanticIdle();
            self.live_semantic_hooks = binding;
        }
        /// The host has excluded all callers and joined producers/consumer, or
        /// is rolling back before starting them. This exact identity/resource
        /// check is not a join and cannot turn recorder health into custody.
        /// Reject a foreign binding without clearing the attached one.
        pub fn detachLiveSemanticQuiescent(self: *Self, expected: semantic.Binding) Error!void {
            const actual = self.live_semantic_hooks orelse return error.InvalidState;
            if (!semantic.Binding.same(actual, expected) or self.prerequisite_order != null or
                self.offline_causal_replay != null or self.control_sink != null or
                self.control_parent_operation != 0) return error.InvalidState;
            try self.validateSemanticIdle();
            self.live_semantic_hooks = null;
        }
        fn validateSemanticIdle(self: *const Self) Error!void {
            if (self.intent_write.load(.acquire) != self.intent_read.load(.acquire)) return error.InvalidState;
            for (&self.slots) |*slot| if (slot.state.load(.acquire) != .free or
                slot.queue_refs != 0 or slot.invalidation_refs != 0) return error.InvalidState;
            for (&self.intents) |*intent| if (intent.state.load(.acquire) != 0) return error.InvalidState;
            for (&self.plans) |*plan| if (plan.active or plan.block_refs != 0 or
                plan.intent_refs != 0 or plan.transaction_refs != 0) return error.InvalidState;
            for (&self.fences) |*fence| if (fence.references != 0) return error.InvalidState;
        }

        fn emitControl(self: *Self, value: ControlObservation) void {
            if (self.control_sink) |sink| sink.emit(sink.context, value);
        }
        fn beginControl(self: *Self, kind: ControlOperationKind, target: ?Handle) ControlOperation {
            var operation: ControlOperation = .{ .operation_id = 0, .parent_operation_id = self.control_parent_operation, .kind = kind, .target = target };
            if (self.control_sink == null) return operation;
            operation.sequence_exhausted = self.control_operation_sequence == std.math.maxInt(u64);
            self.control_operation_sequence +|= 1;
            operation.operation_id = self.control_operation_sequence;
            self.control_parent_operation = operation.operation_id;
            self.emitControl(.{ .operation = operation });
            return operation;
        }
        fn endControl(self: *Self, operation: ControlOperation, result: ControlResult) void {
            if (operation.operation_id == 0) return;
            var finished = operation;
            finished.result = result;
            self.emitControl(.{ .operation = finished });
            self.control_parent_operation = operation.parent_operation_id;
        }
        fn flushControlScan(self: *Self, scan: *ControlScan) void {
            if (scan.count == 0) return;
            self.emitControl(.{ .slot_scan = scan.* });
            scan.* = .{ .operation_id = scan.operation_id, .first_slot = scan.first_slot + scan.count };
        }

        pub fn prepare(self: *Self, start: u64, end: u64, commands: []const Command, hash: trace.Hash, declared_phases: ?u16) Error!Handle {
            return self.prepareInternal(start, end, commands, hash, declared_phases, false, null);
        }
        /// Opt-in source witness. Runtime restricts its live use to a single
        /// initial emergency Stop descriptor, before any block exists.
        pub fn prepareWithLateWitnessV1(self: *Self, start: u64, end: u64, commands: []const Command, hash: trace.Hash, late: *?LivePrepareLateV1) Error!Handle {
            late.* = null;
            return self.prepareInternal(start, end, commands, hash, null, false, late);
        }
        /// An observation-only fence needs no media/planning lead. Runtime
        /// restricts this seam to its one non-mutating resident capture command.
        /// Publication racing a later Render gate is rejected as ordinary late.
        pub fn prepareObservationFence(self: *Self, frame: u64, commands: []const Command, hash: trace.Hash) Error!Handle {
            if (commands.len != 1 or frame == std.math.maxInt(u64)) return error.InvalidArgument;
            return self.prepareInternal(frame, frame + 1, commands, hash, null, true, null);
        }
        fn prepareInternal(self: *Self, start: u64, end: u64, commands: []const Command, hash: trace.Hash, declared_phases: ?u16, observation_only: bool, late: ?*?LivePrepareLateV1) Error!Handle {
            const operation = self.beginControl(.prepare, null);
            var result: ControlResult = .success;
            defer self.endControl(operation, result);
            errdefer |err| result = ControlResult.fromError(err);
            if (commands.len == 0 or commands.len > commands_per_block or trace.isZero(hash)) return error.InvalidArgument;
            if (start >= end or end > std.math.maxInt(u64) - @as(u64, default_profile.max_commit_span_frames)) return error.UnsafeFrameRange;
            self.checkpoint(.control, .{ .site = .scheduler_prepare_horizon, .edge = .before }, self.control_sink != null);
            const horizon = self.commit_horizon.load(.acquire);
            self.checkpoint(.control, .{ .site = .scheduler_prepare_horizon, .edge = .after, .value = horizon }, self.control_sink != null);
            self.emitControl(.{ .prepare_horizon = .{
                .operation_id = operation.operation_id,
                .start = start,
                .end = end,
                .command_count = @intCast(commands.len),
                .declared_phases = declared_phases,
                .observation_only = observation_only,
                .horizon = horizon,
            } });
            const minimum = if (observation_only or horizon == 0) horizon else std.math.add(u64, horizon, default_profile.min_plan_lead_frames + default_profile.late_race_budget_frames) catch return error.UnsafeFrameRange;
            if (start < minimum) {
                _ = self.counters.late.fetchAdd(1, .monotonic);
                if (late) |value| value.* = .{ .start_frame = start, .end_frame = end, .observed_horizon = horizon, .minimum_frame = minimum };
                return error.LateCommand;
            }
            const plan = commands[0].identity.token;
            if (self.context_id != 0 and plan.context.value() != self.context_id) return error.InvalidState;

            var block: Block = .{ .id = self.next_batch_id, .content_hash = hash, .start_frame = start, .end_frame = end, .count = @intCast(commands.len) };
            for (commands, 0..) |command, i| {
                command.identity.token.validate() catch return error.InvalidState;
                if (command.identity.command_id == 0 or command.identity.group_id == 0 or command.identity.execute_frame < start or command.identity.execute_frame >= end) return error.InvalidArgument;
                const first = commands[0].identity.token;
                const token = command.identity.token;
                if (token.context != first.context or token.plan_id != first.plan_id or token.plan_epoch != first.plan_epoch or token.transport_epoch != first.transport_epoch or token.asset_generation != first.asset_generation) return error.InvalidState;
                for (commands[0..i]) |previous| {
                    if (previous.identity.command_id == command.identity.command_id) return error.InvalidArgument;
                    if (previous.identity.group_id == command.identity.group_id and (previous.identity.execute_frame != command.identity.execute_frame or previous.identity.phase_order != command.identity.phase_order or previous.identity.token.phase_id != command.identity.token.phase_id)) return error.InvalidArgument;
                }
                block.commands[i] = command;
                block.commands[i].ordinal = @intCast(i);
                block.commands[i].sequence = 0;
            }
            std.mem.sort(Command, block.commands[0..block.count], {}, less);
            var i: usize = 0;
            var previous_phase: ?u32 = null;
            var phase_count: u16 = 0;
            while (i < block.count) {
                const begin = i;
                const current = block.commands[i].identity;
                if (current.phase_order >= default_profile.phases_per_plan) return error.InvalidArgument;
                if (previous_phase) |p| if (current.phase_order != p + 1) return error.InvalidArgument;
                previous_phase = current.phase_order;
                phase_count += 1;
                while (i < block.count and block.commands[i].identity.group_id == current.group_id) : (i += 1) {}
                if (i - begin > commands_per_group) return error.InvalidArgument;
            }
            const first_phase = block.commands[0].identity.phase_order;
            if (first_phase + phase_count > default_profile.phases_per_plan) return error.InvalidArgument;
            const total_phases = declared_phases orelse phase_count;
            if (total_phases == 0 or total_phases > default_profile.phases_per_plan or first_phase + phase_count > total_phases) return error.InvalidArgument;
            var plan_index: ?u16 = null;
            var free_plan: ?u16 = null;
            for (&self.plans, 0..) |*ledger, index| {
                if (!ledger.active) {
                    if (free_plan == null) free_plan = @intCast(index);
                    continue;
                }
                if (ledger.token.plan_id == plan.plan_id and ledger.token.plan_epoch == plan.plan_epoch) {
                    plan_index = @intCast(index);
                    break;
                }
            }
            const existing_plan = plan_index != null;
            if (plan_index) |index| {
                const ledger = &self.plans[index];
                if (declared_phases == null or ledger.total_phases != total_phases or ledger.cancelled.load(.acquire) or ledger.prepared_phases != first_phase or ledger.token.transport_epoch != plan.transport_epoch or ledger.token.asset_generation != plan.asset_generation or block.commands[0].identity.execute_frame < ledger.last_frame) return error.InvalidState;
                if (ledger.command_count + block.count > default_profile.commands_per_plan) return error.CommandQueueFull;
                for (block.commands[0..block.count]) |command| {
                    for (ledger.command_ids[0..ledger.command_count]) |id| if (id == command.identity.command_id) return error.InvalidArgument;
                    for (0..ledger.prepared_phases) |phase| if (ledger.phase_ids[phase] == command.identity.token.phase_id or ledger.phase_groups[phase] == command.identity.group_id) return error.InvalidArgument;
                }
            } else {
                if (first_phase != 0) return error.InvalidArgument;
                plan_index = free_plan;
            }
            var fence_index: ?u16 = null;
            var empty_fence: ?u16 = null;
            for (&self.fences, 0..) |*fence, index| {
                if (fence.references != 0 and fence.plan_id == plan.plan_id.value()) {
                    fence_index = @intCast(index);
                    break;
                }
                if (fence.references == 0 and empty_fence == null) empty_fence = @intCast(index);
            }
            if (!existing_plan) {
                if (fence_index) |index| {
                    if (plan.plan_epoch.value() <= self.fences[index].prepared_epoch) return error.InvalidState;
                } else if (plan.plan_id.value() < self.latest_plan_id or (plan.plan_id.value() == self.latest_plan_id and plan.plan_epoch.value() <= self.latest_plan_epoch)) return error.InvalidState;
            }
            fence_index = fence_index orelse empty_fence;
            if (fence_index == null) {
                _ = self.counters.fence_overflow.fetchAdd(1, .monotonic);
                _ = self.counters.overflow.fetchAdd(1, .monotonic);
                _ = self.counters.receipt_backpressure.fetchAdd(1, .monotonic);
                return error.CommandQueueFull;
            }
            if (plan_index == null) {
                _ = self.counters.plan_overflow.fetchAdd(1, .monotonic);
                _ = self.counters.overflow.fetchAdd(1, .monotonic);
                _ = self.counters.receipt_backpressure.fetchAdd(1, .monotonic);
                return error.CommandQueueFull;
            }
            var scan: ControlScan = .{ .operation_id = operation.operation_id, .first_slot = 0 };
            defer self.flushControlScan(&scan);
            // A finite scan envelope replaces semantic per-slot diagnostics.
            // The reader rejects crossed foreign publications; it must not use
            // the captured state or chosen slot as a selection override.
            self.semanticBoundary(.control, .scheduler_prepare_scan, .before, block_capacity, 0, null);
            defer self.semanticBoundary(.control, .scheduler_prepare_scan, .after, block_capacity, 0, null);
            for (&self.slots, 0..) |*slot, index| {
                self.checkpoint(.control, .{ .site = .scheduler_control_scan, .edge = .before, .index = index }, self.control_sink != null);
                const state = slot.state.load(.acquire);
                self.checkpoint(.control, .{ .site = .scheduler_control_scan, .edge = .after, .index = index, .value = @intFromEnum(state) }, self.control_sink != null);
                if (self.control_sink != null) {
                    scan.put(state);
                    if (scan.count == ControlScan.slots_per_chunk or state == .free) self.flushControlScan(&scan);
                }
                if (state != .free) continue;
                if (slot.generation == std.math.maxInt(u64) or self.next_batch_id == std.math.maxInt(u64)) return error.InvalidState;
                slot.generation += 1;
                slot.block = block;
                slot.next_command = 0;
                slot.executed_count = 0;
                slot.phase_count = phase_count;
                slot.next_phase = 0;
                slot.invalidation_refs = 0;
                slot.queue_refs = 0;
                const fence = &self.fences[fence_index.?];
                const ledger = &self.plans[plan_index.?];
                if (!existing_plan) {
                    if (ledger.generation == std.math.maxInt(u64)) return error.InvalidState;
                    const generation = ledger.generation + 1;
                    ledger.* = .{ .active = true, .generation = generation, .token = plan, .total_phases = total_phases, .fence_index = fence_index.? };
                    if (fence.references == 0) {
                        fence.plan_id = plan.plan_id.value();
                        fence.admitted_epoch.store(0, .release);
                    }
                    fence.prepared_epoch = plan.plan_epoch.value();
                    fence.references += 1; // one lease per live plan version
                }
                ledger.block_refs += 1;
                ledger.prepared_phases += phase_count;
                ledger.last_frame = block.commands[block.count - 1].identity.execute_frame;
                for (block.commands[0..block.count]) |command| {
                    ledger.command_ids[ledger.command_count] = command.identity.command_id;
                    ledger.command_count += 1;
                    ledger.phase_ids[command.identity.phase_order] = command.identity.token.phase_id;
                    ledger.phase_groups[command.identity.phase_order] = command.identity.group_id;
                }
                slot.fence_index = fence_index.?;
                slot.plan_index = plan_index.?;
                slot.first_phase = @intCast(first_phase);
                self.context_id = plan.context.value();
                slot.receipt_count = 0;
                slot.published_receipts.store(0, .monotonic);
                slot.admission = null;
                slot.cancellation = null;
                slot.polled = false;
                slot.reconciled = false;
                slot.transaction_reconciled = @splat(false);
                slot.disposition = .prepared;
                self.next_batch_id += 1;
                if (plan.plan_id.value() > self.latest_plan_id) {
                    self.latest_plan_id = plan.plan_id.value();
                    self.latest_plan_epoch = plan.plan_epoch.value();
                } else if (plan.plan_id.value() == self.latest_plan_id) self.latest_plan_epoch = @max(self.latest_plan_epoch, plan.plan_epoch.value());
                if (!existing_plan) ledger.readers.store(0, .release);
                slot.state.store(.prepared, .release);
                self.emitControl(.{ .prepared = .{
                    .operation_id = operation.operation_id,
                    .block = .{ .index = @intCast(index), .generation = slot.generation },
                    .plan = .{ .index = plan_index.?, .generation = ledger.generation },
                    .batch_id = block.id,
                    .fence_index = fence_index.?,
                    .fence_refs = fence.references,
                    .plan_block_refs = ledger.block_refs,
                    .existing_plan = existing_plan,
                    .first_phase = slot.first_phase,
                    .phase_count = phase_count,
                    .total_phases = total_phases,
                } });
                self.recordPressure();
                return .{ .index = @intCast(index), .generation = slot.generation };
            }
            _ = self.counters.overflow.fetchAdd(1, .monotonic);
            _ = self.counters.receipt_backpressure.fetchAdd(1, .monotonic);
            return error.CommandQueueFull;
        }
        fn less(_: void, a: Command, b: Command) bool {
            if (a.identity.execute_frame != b.identity.execute_frame) return a.identity.execute_frame < b.identity.execute_frame;
            return a.ordinal < b.ordinal;
        }
        pub fn get(self: *Self, handle: Handle) Error!*Slot {
            // A generic caller does not establish role ownership. Known Control
            // paths use getControl/getObserved; this entry remains uncovered.
            return self.getValidated(handle, null, null, null);
        }
        fn getControl(self: *Self, handle: Handle) Error!*Slot {
            return self.getValidated(handle, null, null, .control);
        }
        /// Control-only observation path; all runtime callers hold Control.
        /// Copies the existing validation acquire; never adds a second read.
        pub fn getObserved(self: *Self, handle: Handle, observed: ?*?State) Error!*Slot {
            return self.getValidated(handle, observed, null, .control);
        }
        fn getValidated(self: *Self, handle: Handle, observed: ?*?State, validation: ?*ControlValidation, actual_role: ?order.Role) Error!*Slot {
            if (handle.index >= block_capacity) return error.InvalidState;
            const slot = &self.slots[handle.index];
            // Only attributed validation reads consume this site's occurrence.
            // Internal get() calls have no matching observation in the format.
            const represented = observed != null or validation != null;
            self.checkpoint(actual_role, .{ .site = .scheduler_validate, .edge = .before, .index = handle.index, .generation = handle.generation }, represented);
            const state = slot.state.load(.acquire);
            self.checkpoint(actual_role, .{ .site = .scheduler_validate, .edge = .after, .index = handle.index, .generation = handle.generation, .value = @intFromEnum(state) }, represented);
            if (observed) |value| value.* = state;
            if (validation) |value| value.state = state;
            if (state == .free) return error.InvalidState;
            const generation = slot.generation;
            if (validation) |value| value.generation = generation;
            if (generation != handle.generation) return error.InvalidState;
            if (validation) |value| value.valid = true;
            return slot;
        }
        pub fn publish(self: *Self, handle: Handle, sequence: u64) Error!void {
            const slot = try self.getControl(handle);
            if (slot.state.load(.acquire) != .queued) return error.InvalidState;
            for (slot.block.commands[0..slot.block.count]) |*command| command.sequence = sequence;
            slot.disposition = .published;
            self.plans[slot.plan_index].published.store(true, .release);
            const causal_publication: CausalPublication = .{ .block = handle, .batch_id = slot.block.id, .content_hash = slot.block.content_hash, .sequence = sequence };
            if (@import("builtin").is_test) if (self.test_publication_hook) |hook_value| hook_value.call(hook_value.context, .before_release, handle);
            self.checkpoint(.control, .{ .site = .scheduler_publication, .edge = .before, .index = handle.index, .generation = handle.generation, .value = @intFromEnum(State.published) }, true);
            slot.state.store(.published, .release);
            self.checkpoint(.control, .{ .site = .scheduler_publication, .edge = .after, .index = handle.index, .generation = handle.generation, .value = @intFromEnum(State.published) }, true);
            if (self.public_causal_publication_sink) |sink| sink.emit(sink.context, causal_publication);
            if (@import("builtin").is_test) if (self.test_publication_hook) |hook_value| hook_value.call(hook_value.context, .after_release, handle);
        }
        pub fn getPlan(self: *Self, handle: Handle) Error!*Plan {
            if (handle.index >= default_profile.plan_capacity) return error.InvalidState;
            const plan = &self.plans[handle.index];
            if (!plan.active or plan.generation != handle.generation) return error.InvalidState;
            return plan;
        }
        /// Serialized Control lease survives terminal block acknowledgement.
        pub fn retainPlan(self: *Self, handle: Handle) Error!void {
            const plan = try self.getPlan(handle);
            if (plan.transaction_refs == std.math.maxInt(u16)) return error.CommandQueueFull;
            plan.transaction_refs += 1;
        }
        pub fn releasePlan(self: *Self, handle: Handle) Error!void {
            const plan = try self.getPlan(handle);
            if (plan.transaction_refs == 0) return error.InvalidState;
            plan.transaction_refs -= 1;
            self.reapPlan(plan);
        }
        pub fn claimExecution(self: *Self) void {
            // Never silently reuse an ordering authority.
            std.debug.assert(self.execution_ordinal != std.math.maxInt(u64));
            self.execution_ordinal += 1;
        }
        /// Render-only no-fail commit after resident preflight and owner pins.
        /// The retained old plan is exact; new restore phases are untouched.
        pub fn replaceResidentEpoch(self: *Self, old_plan: ?Handle, generation: u64, epoch: u64, frame: u64) void {
            if (old_plan) |handle| {
                const plan = &self.plans[handle.index];
                std.debug.assert(plan.generation == handle.generation and plan.transaction_refs != 0);
                self.cancelPlanState(plan, frame, frame, self.planState(plan), .stale_epoch, .render);
            }
            // Render owns both values. No command claim, span generation or
            // receipt publication can intervene between these assignments.
            self.asset_generation = generation;
            self.transport_epoch = epoch;
            self.shutdownAtGate(frame);
        }
        pub fn planHandle(self: *Self, block: Handle) Error!Handle {
            const slot = try self.getControl(block);
            const plan = &self.plans[slot.plan_index];
            return .{ .index = slot.plan_index, .generation = plan.generation };
        }
        pub fn localCancellationAllowed(self: *Self, handle: Handle) Error!bool {
            const slot = try self.getControl(handle);
            return !self.shutdown_requested.load(.acquire) and slot.state.load(.acquire) == .prepared and self.plans[slot.plan_index].queued_phases == 0 and self.plans[slot.plan_index].intent_refs == 0;
        }
        /// Control-local only while no phase has ever entered the render lane.
        /// Effective time is the Control-observed generated-frame frontier,
        /// distinct from historical request metadata and a Render claim gate.
        pub fn cancelPrepared(self: *Self, handle: Handle, requested: u64, observed_frame: u64) Error!void {
            const slot = try self.getControl(handle);
            if (!(try self.localCancellationAllowed(handle))) return error.InvalidState;
            const plan = &self.plans[slot.plan_index];
            self.cancelPlanState(plan, requested, observed_frame, .prepared, .stale_epoch, .control);
            self.reconcilePrepared();
        }
        /// Control-owned prepared/queued blocks are never mutated by Render.
        /// Render publishes the durable plan fence; Control retires its local
        /// storage after acquiring that fence and after consuming any ingress.
        pub fn reconcilePrepared(self: *Self) void {
            const operation = self.beginControl(.reconcile, null);
            defer self.endControl(operation, .success);
            self.semanticBoundary(.control, .scheduler_reconcile_scan, .before, block_capacity, 0, null);
            defer self.semanticBoundary(.control, .scheduler_reconcile_scan, .after, block_capacity, 0, null);
            var scan: ControlScan = .{ .operation_id = operation.operation_id, .first_slot = 0 };
            for (&self.slots, 0..) |*slot, index| {
                self.checkpoint(.control, .{ .site = .scheduler_control_scan, .edge = .before, .index = index }, self.control_sink != null);
                const state = slot.state.load(.acquire);
                self.checkpoint(.control, .{ .site = .scheduler_control_scan, .edge = .after, .index = index, .value = @intFromEnum(state) }, self.control_sink != null);
                if (self.control_sink != null) scan.put(state);
                if (state == .prepared) {
                    const plan = &self.plans[slot.plan_index];
                    const cancelled = plan.cancelled.load(.acquire);
                    var read: ControlPreparedCancellation = .{
                        .operation_id = operation.operation_id,
                        .block = .{ .index = @intCast(index), .generation = slot.generation },
                        .plan = .{ .index = slot.plan_index, .generation = plan.generation },
                        .cancelled = cancelled,
                    };
                    if (cancelled) self.cancelSlotObserved(slot, if (self.control_sink != null) &read else null, false, .control);
                    self.emitControl(.{ .prepared_cancellation = read });
                }
                if (scan.count == ControlScan.slots_per_chunk) self.flushControlScan(&scan);
            }
            self.flushControlScan(&scan);
            for (&self.plans) |*plan| self.reapPlan(plan);
        }
        pub fn abortQueued(self: *Self, slot: *Slot, frame: u64) void {
            const plan = &self.plans[slot.plan_index];
            _ = frame;
            std.debug.assert(plan.cancelled.load(.acquire));
            // Reserved ingress is consumed by Control. Keep the historical
            // progress sink flag unchanged; prerequisite attribution is actual.
            self.cancelSlotObserved(slot, null, true, .control);
        }
        pub fn reapPlan(self: *Self, plan: *Plan) void {
            if (!plan.active) return;
            const block_refs = plan.block_refs;
            if (block_refs != 0) return;
            const intent_refs = plan.intent_refs;
            if (intent_refs != 0) return;
            const transaction_refs = plan.transaction_refs;
            if (transaction_refs != 0) return;
            const handle: Handle = .{ .index = @intCast((@intFromPtr(plan) - @intFromPtr(&self.plans)) / @sizeOf(Plan)), .generation = plan.generation };
            const operation = self.beginControl(.reap, handle);
            defer self.endControl(operation, .success);
            const cancelled = plan.cancelled.load(.acquire);
            var observed: ControlObservation = .{ .plan_reap = .{
                .operation_id = operation.operation_id,
                .plan = handle,
                .block_refs = block_refs,
                .intent_refs = intent_refs,
                .transaction_refs = transaction_refs,
                .cancelled = cancelled,
            } };
            defer self.emitControl(observed);
            if (!cancelled) {
                self.checkpoint(.control, .{ .site = .scheduler_reap_phase, .edge = .before, .index = handle.index, .generation = handle.generation }, true);
                const executed_count = plan.executed_count.load(.acquire);
                self.checkpoint(.control, .{ .site = .scheduler_reap_phase, .edge = .after, .index = handle.index, .generation = handle.generation, .value = executed_count }, true);
                observed.plan_reap.executed_count = executed_count;
                const total_phases = plan.total_phases;
                observed.plan_reap.total_phases = total_phases;
                if (executed_count != total_phases) return;
            }
            self.checkpoint(.control, .{ .site = .scheduler_reap_readers, .edge = .before, .index = handle.index, .generation = handle.generation }, true);
            const readers = plan.readers.cmpxchgStrong(0, Plan.writing, .acq_rel, .acquire);
            // 0 is success. A failed observed reader count is encoded plus 1.
            self.checkpoint(.control, .{ .site = .scheduler_reap_readers, .edge = .after, .index = handle.index, .generation = handle.generation, .value = if (readers) |count| @as(u64, count) + 1 else 0 }, true);
            observed.plan_reap.readers_cas_reached = true;
            observed.plan_reap.readers_cas_failure = readers;
            if (readers != null) return;
            const fence_index = plan.fence_index;
            observed.plan_reap.fence_index = fence_index;
            const fence = &self.fences[fence_index];
            const references = fence.references;
            observed.plan_reap.fence_refs_before = references;
            fence.references = references - 1;
            observed.plan_reap.fence_refs_after = references - 1;
            plan.active = false;
            observed.plan_reap.returned = true;
        }
        pub fn prepareInvalidation(self: *Self, value: Invalidation, hash: trace.Hash) Error!Handle {
            const target_slot: ?*Slot = if (value.plan_target == null) try self.getControl(value.target) else null;
            const plan_handle = value.plan_target orelse try self.planHandle(value.target);
            const ledger = try self.getPlan(plan_handle);
            if (trace.isZero(hash)) return error.InvalidArgument;
            for (&self.intents, 0..) |*intent, index| {
                if (intent.state.load(.acquire) != 0) continue;
                if (intent.generation == std.math.maxInt(u64) or self.next_batch_id == std.math.maxInt(u64)) return error.InvalidState;
                intent.generation += 1;
                intent.value = value;
                intent.token = ledger.token;
                intent.plan_index = plan_handle.index;
                intent.target_has_slot = target_slot != null;
                intent.device_rejected = false;
                intent.batch_id = self.next_batch_id;
                intent.content_hash = hash;
                intent.admission = null;
                intent.receipt = null;
                self.next_batch_id += 1;
                ledger.intent_refs += 1;
                if (target_slot) |slot| slot.invalidation_refs += 1;
                intent.state.store(1, .release);
                self.recordPressure();
                return .{ .index = @intCast(index), .generation = intent.generation };
            }
            _ = self.counters.overflow.fetchAdd(1, .monotonic);
            return error.CommandQueueFull;
        }
        pub fn publishInvalidation(self: *Self, handle: Handle, sequence: u64) Error!void {
            return self.publishInvalidationObserved(handle, sequence, null);
        }
        pub fn publishInvalidationObserved(self: *Self, handle: Handle, sequence: u64, observed: ?*render_observation.InvalidationPublication) Error!void {
            if (handle.index >= emergency_capacity) return error.InvalidState;
            const intent = &self.intents[handle.index];
            if (intent.generation != handle.generation) return error.InvalidState;
            const state = intent.state.load(.acquire);
            if (observed) |read| read.state_before = state;
            if (state != 1) return error.InvalidState;
            intent.sequence = sequence;
            if (observed) |read| read.identity = self.invalidationIdentity(intent, handle.index);
            if (intent.device_rejected) {
                std.debug.assert(intent.admission != null and intent.receipt != null);
                // Control has now bound the real queue sequence and canonical
                // batch hash. Preserve the earlier actual device gate identity,
                // but never publish the preparation placeholder hash.
                intent.admission.?.content_hash = intent.content_hash;
                intent.state.store(3, .release);
                if (observed) |read| read.state_published = 3;
                return; // queued handle discharged; no new Render obligation
            }
            intent.state.store(2, .release);
            const write = self.intent_write.load(.monotonic);
            std.debug.assert(write -% self.intent_read.load(.acquire) < emergency_capacity);
            self.intent_order[write % emergency_capacity] = handle.index;
            // Copy the intent handle, actual release value and binding before
            // publication permits Render to finish and Control to reclaim it.
            var publication: OfflineCheckpoint = .{ .site = .scheduler_invalidation_publication, .edge = .before, .index = handle.index, .generation = handle.generation, .value = write +% 1 };
            const binding = self.orderBinding(.control, publication.index, publication.generation);
            self.invalidationOffline(publication);
            self.emitOrder(binding, .control, publication);
            self.intent_write.store(write +% 1, .release);
            publication.edge = .after;
            self.invalidationOffline(publication);
            self.emitOrder(binding, .control, publication);
            if (observed) |read| {
                read.state_published = 2;
                read.write_before = write;
                read.write_after = write +% 1;
                read.queue_published = true;
            }
        }
        pub fn invalidationIdentity(self: *const Self, intent: *const Intent, index: u16) render_observation.InvalidationIdentity {
            return .{
                .intent = .{ .index = index, .generation = intent.generation },
                .target = .{ .index = intent.value.target.index, .generation = intent.value.target.generation },
                .plan = .{ .index = intent.plan_index, .generation = self.plans[intent.plan_index].generation },
                .batch_id = intent.batch_id,
                .content_hash = intent.content_hash,
                .sequence = intent.sequence,
                .context = intent.token.context.value(),
                .plan_id = intent.token.plan_id.value(),
                .plan_epoch = intent.token.plan_epoch.value(),
                .phase_id = intent.token.phase_id.value(),
                .transport_epoch = intent.token.transport_epoch.value(),
                .asset_generation = intent.token.asset_generation.value(),
                .requested_frame = intent.value.requested_frame,
                .next_transport_epoch = intent.value.next_transport_epoch,
                .next_asset_generation = intent.value.next_asset_generation,
                .emergency_stop_music = intent.value.emergency_stop_music,
                .plan_target = intent.value.plan_target != null,
                .target_has_slot = intent.target_has_slot,
            };
        }
        pub fn beginGate(self: *Self, frame: u64) void {
            self.gate_number += 1;
            self.gate_order = 0;
            self.checkpoint(.render, .{ .site = .scheduler_horizon, .edge = .before, .value = frame }, true);
            self.commit_horizon.store(frame, .release);
            self.checkpoint(.render, .{ .site = .scheduler_horizon, .edge = .after, .value = frame }, true);
        }
        /// The serialized Render owner, or its explicitly acquired host-quiescent
        /// replacement, records a real device fence for this exact owned plan.
        /// This never changes global transport identity or unrelated SFX plans.
        pub fn cancelDevicePlanAtGate(self: *Self, handle: Handle, frame: u64) Error!void {
            const plan = try self.getPlan(handle);
            self.cancelPlanState(plan, frame, frame, self.planState(plan), .stale_epoch, .render);
            // Do not enter global shutdown here: its pending obligation may
            // include unrelated SFX plans that only a real Render/shutdown gate
            // is allowed to retire. This fence owns exactly one plan's suffix.
            for (&self.slots) |*slot| {
                if (slot.plan_index != handle.index) continue;
                const state = slot.state.load(.acquire);
                if (state != .published and state != .acquired and state != .partially_executed) continue;
                if (!plan.cancelled.load(.acquire)) continue;
                if (state == .published) slot.admission = self.admission(slot.block.id, slot.block.content_hash, .commands, frame, .rejected);
                self.cancelSlot(slot);
            }
        }
        /// Host-quiescent AND Control-exclusive only. The loss fence has
        /// already terminalized its exact owned plans. Reject their obsolete
        /// published invalidations, returning each original receipt/credit, but
        /// never apply old epoch changes or unrelated intents. Compact the fixed
        /// FIFO without rewinding either cursor or reordering retained entries.
        pub fn rejectDeviceIntentsAtGate(self: *Self, owned: *const [default_profile.plan_capacity]bool, frame: u64) void {
            // State 1 is still owned by Control reserved ingress, not the
            // Render FIFO. Preserve its handle/generation and all credits until
            // publishInvalidation consumes it; never reclaim beneath the queue.
            for (&self.intents) |*intent| {
                if (intent.state.load(.acquire) != 1 or intent.device_rejected or !owned[intent.plan_index]) continue;
                self.recordDeviceIntentRejection(intent, frame);
                intent.device_rejected = true;
            }
            const read = self.intent_read.load(.acquire);
            const write = self.intent_write.load(.acquire);
            const count = write -% read;
            std.debug.assert(count <= emergency_capacity);
            var retained: [emergency_capacity]u16 = undefined;
            var keep: u32 = 0;
            for (0..count) |offset| {
                const index = self.intent_order[(read +% @as(u32, @intCast(offset))) % emergency_capacity];
                const intent = &self.intents[index];
                std.debug.assert(intent.state.load(.acquire) == 2);
                if (!owned[intent.plan_index]) {
                    retained[keep] = index;
                    keep += 1;
                    continue;
                }
                self.recordDeviceIntentRejection(intent, frame);
                intent.state.store(3, .release);
            }
            const next_read = write -% keep;
            for (retained[0..keep], 0..) |index, offset| self.intent_order[(next_read +% @as(u32, @intCast(offset))) % emergency_capacity] = index;
            self.intent_read.store(next_read, .release);
        }
        fn recordDeviceIntentRejection(self: *Self, intent: *Intent, frame: u64) void {
            const plan = &self.plans[intent.plan_index];
            std.debug.assert(self.planState(plan).isTerminal());
            self.claimExecution();
            intent.admission = self.admission(intent.batch_id, intent.content_hash, .invalidations, frame, .rejected);
            var record = baseRecord(intent.token, .rejected, frame);
            record.result = .rejected;
            record.reason = .stale_epoch;
            record.state_before = toTraceState(self.planState(plan));
            record.executed_prefix_count = plan.executed_count.load(.acquire);
            record.cancel_requested_frame = intent.value.requested_frame;
            record.commit_horizon = self.commit_horizon.load(.acquire);
            intent.receipt = record;
        }
        pub fn acquirePublished(self: *Self, frame: u64) void {
            self.acquirePublishedObserved(frame, null);
        }
        pub fn acquirePublishedObserved(self: *Self, frame: u64, sink: ?*render_observation.Sink) void {
            // Admission is recorded at the actual acquire gate, never at Control
            // acceptance. Published metadata cannot change underneath this load.
            const scan_gate = self.gate_number;
            self.semanticBoundary(.render, .scheduler_acquire_scan, .before, scan_gate, frame, block_capacity);
            defer self.semanticBoundary(.render, .scheduler_acquire_scan, .after, scan_gate, frame, block_capacity);
            var active_sink = sink;
            var chunk: ?*render_observation.ScanChunk = null;
            for (&self.slots, 0..) |*slot, index| {
                const offset = index % render_observation.slots_per_chunk;
                if (offset == 0) {
                    chunk = if (active_sink) |observer| observer.begin_chunk(observer.context, @intCast(index), self.gate_order) else null;
                    if (chunk) |value| {
                        value.* = .{ .gate = self.gate_number, .frame = frame };
                    } else active_sink = null;
                }
                const read: ?*render_observation.SlotRead = if (chunk) |value| &value.reads[offset] else null;
                if (@import("builtin").is_test) self.test_scan_index = index;
                self.hook(.acquire_scan);
                self.checkpoint(.render, .{ .site = .scheduler_scan, .edge = .before, .index = index }, true);
                const state = slot.state.load(.acquire);
                self.checkpoint(.render, .{ .site = .scheduler_scan, .edge = .after, .index = index, .value = @intFromEnum(state) }, true);
                self.hook(.after_acquire_scan);
                if (read) |value| {
                    value.slot_index = @intCast(index);
                    value.state = state;
                }
                if (state == .published) {
                    const first = &slot.block.commands[0];
                    const execute_frame = first.identity.execute_frame;
                    const late = execute_frame < frame;
                    const admission_value = self.admission(slot.block.id, slot.block.content_hash, .commands, frame, if (late) .late else .admitted);
                    slot.admission = admission_value;
                    if (read) |value| {
                        // Copy while publication still pins immutable storage,
                        // before acquired/terminal stores permit reclamation.
                        value.generation = slot.generation;
                        value.batch_id = slot.block.id;
                        value.content_hash = slot.block.content_hash;
                        value.first_command_id = first.identity.command_id;
                        value.first_execute_frame = execute_frame;
                        value.first_group_id = first.identity.group_id;
                        value.first_sequence = first.sequence;
                        value.first_phase_order = first.identity.phase_order;
                        value.command_count = slot.block.count;
                        value.admission_disposition = admission_value.disposition;
                        value.admission_order = admission_value.gate_order;
                    }
                    const token = first.identity.token;
                    const fence = &self.fences[slot.fence_index];
                    fence.admitted_epoch.store(@max(fence.admitted_epoch.load(.acquire), token.plan_epoch.value()), .release);
                    self.plans[slot.plan_index].acquired.store(true, .release);
                    slot.disposition = .acquired;
                    const acquired_generation = slot.generation;
                    self.checkpoint(.render, .{ .site = .scheduler_acquired, .edge = .before, .index = index, .generation = acquired_generation, .value = @intFromEnum(State.acquired) }, true);
                    slot.state.store(.acquired, .release);
                    self.checkpoint(.render, .{ .site = .scheduler_acquired, .edge = .after, .index = index, .generation = acquired_generation, .value = @intFromEnum(State.acquired) }, true);
                    self.causalProgress(.{ .site = .scheduler_acquired, .index = index, .generation = acquired_generation, .value = @intFromEnum(State.acquired), .frame = frame });
                    if (late) {
                        _ = self.counters.late.fetchAdd(1, .monotonic);
                        self.rejectRemainder(slot, frame, .late);
                    }
                }
                if (offset + 1 == render_observation.slots_per_chunk) {
                    if (chunk) |value| {
                        const observer = active_sink.?;
                        if (!observer.end_chunk(observer.context, value)) active_sink = null;
                    }
                    chunk = null;
                }
            }
            self.hook(.acquired);
        }
        pub fn shutdownAtGate(self: *Self, frame: u64) void {
            self.shutdownAtGateObserved(frame, null);
        }
        /// Mark unsupported shutdown from the values this operation already
        /// loads, without an earlier diagnostic read changing the causal cut.
        pub fn shutdownAtGateObserved(self: *Self, frame: u64, unsupported: ?*bool) void {
            const initial_shutdown = self.shutdown_requested.load(.acquire);
            if (initial_shutdown) if (unsupported) |value| {
                value.* = true;
            };
            if (initial_shutdown) for (&self.plans) |*plan| {
                // One bounded reader claim protects even a between-block plan
                // from Control reclamation while shutdown records its suffix.
                const readers = plan.readers.load(.acquire);
                if (readers >= Plan.writing - 1 or plan.readers.cmpxchgStrong(readers, readers + 1, .acquire, .monotonic) != null) continue;
                self.cancelPlanState(plan, frame, frame, self.planState(plan), .stale_epoch, .render);
                _ = plan.readers.fetchSub(1, .release);
            };
            for (&self.slots) |*slot| {
                const state = slot.state.load(.acquire);
                if (state != .published and state != .acquired and state != .partially_executed) continue;
                const plan = &self.plans[slot.plan_index];
                const shutdown = self.shutdown_requested.load(.acquire);
                if (shutdown) if (unsupported) |value| {
                    value.* = true;
                };
                if (shutdown and !plan.cancelled.load(.acquire)) self.cancelPlanState(plan, frame, frame, self.planState(plan), .stale_epoch, .render);
                if (!plan.cancelled.load(.acquire)) continue;
                if (state == .published) slot.admission = self.admission(slot.block.id, slot.block.content_hash, .commands, frame, .rejected);
                self.cancelSlot(slot);
            }
        }
        pub fn planState(self: *Self, plan: *const Plan) music.PlanExecutionState {
            return self.planStateObserved(plan, null);
        }
        fn planStateObserved(_: *Self, plan: *const Plan, observed: ?*render_observation.PlanStateRead) music.PlanExecutionState {
            const prefix = plan.executed_count.load(.acquire);
            const cancelled = plan.cancelled.load(.acquire);
            if (observed) |read| {
                read.* = .{ .prefix = prefix, .total = plan.total_phases, .cancelled = cancelled };
            }
            if (cancelled) return if (prefix == 0) .cancelled else .superseded_after_partial;
            if (prefix == plan.total_phases) return .complete;
            if (prefix != 0) return .partially_executed;
            const acquired = plan.acquired.load(.acquire);
            if (observed) |read| read.acquired = acquired;
            if (acquired) return .acquired;
            const published = plan.published.load(.acquire);
            if (observed) |read| read.published = published;
            return if (published) .published else .prepared;
        }
        /// Control-owner observation: terminal receipt storage needs no Render
        /// callback, but every live suffix or system intent still does.
        pub fn hasRenderObligations(self: *const Self) bool {
            for (&self.intents) |*intent| {
                const state = intent.state.load(.acquire);
                if (state == 1 or state == 2) return true;
            }
            for (&self.slots) |*slot| {
                const state = slot.state.load(.acquire);
                if (state == .free or state == .terminal) continue;
                if (state == .prepared and self.plans[slot.plan_index].cancelled.load(.acquire)) continue;
                return true;
            }
            for (&self.plans) |*plan| {
                if (plan.active and !plan.cancelled.load(.acquire) and plan.executed_count.load(.acquire) != plan.total_phases) return true;
            }
            return false;
        }
        /// Stateless marker at the real Runtime pass entry, before its shutdown
        /// check and every reached poll. The shared Render sequence identifies
        /// poll occurrence, including repeated empty polls at the same gate.
        /// No snapshot/frontier is frozen here and gate_order is not advanced.
        pub fn markInvalidationPass(self: *Self, frame: u64, phase: InvalidationPhase, iteration: u64) void {
            const site: OfflineSite = switch (phase) {
                .before_scan => .scheduler_invalidation_before_scan,
                .after_scan => .scheduler_invalidation_after_scan,
                .pre_claim => .scheduler_invalidation_pre_claim,
            };
            self.invalidationCheckpoint(.render, .{ .site = site, .edge = .before, .index = self.gate_number, .generation = frame, .value = iteration });
        }
        pub fn nextInvalidation(self: *Self) ?*Intent {
            return self.nextInvalidationObserved(null);
        }
        pub fn nextInvalidationObserved(self: *Self, observed: ?*render_observation.InvalidationPoll) ?*Intent {
            // Control's exact-ticket drain already orders this system lane. No
            // render sorting/scanning or speculative reads of prepared intents.
            const read = self.intent_read.load(.monotonic);
            // These endpoints surround the ORIGINAL acquire. In particular the
            // before point must not read a speculative/diagnostic write prefix.
            var point: OfflineCheckpoint = .{ .site = .scheduler_invalidation_poll, .edge = .before, .index = read, .generation = self.gate_number };
            self.invalidationCheckpoint(.render, point);
            const write = self.intent_write.load(.acquire);
            point.edge = .after;
            point.value = write;
            self.invalidationCheckpoint(.render, point);
            if (observed) |value| value.* = .{ .read_cursor = read, .write_prefix = write };
            if (read == write) return null;
            const index = self.intent_order[read % emergency_capacity];
            const intent = &self.intents[index];
            if (observed) |value| value.identity = self.invalidationIdentity(intent, index);
            return intent;
        }
        fn finishIntent(self: *Self, intent: *Intent, observed: ?*render_observation.InvalidationResult) void {
            const read = self.intent_read.load(.monotonic);
            if (observed) |value| {
                value.finish_read_before = read;
                value.finish_read_after = read +% 1;
            }
            self.intent_read.store(read +% 1, .release);
            intent.state.store(3, .release);
            // Only bridge-owned copies may be touched after the terminal store.
            if (observed) |value| value.finish_state = 3;
        }
        pub fn applyInvalidation(self: *Self, intent: *Intent, frame: u64) void {
            self.applyInvalidationObserved(intent, frame, null);
        }
        pub fn applyInvalidationObserved(self: *Self, intent: *Intent, frame: u64, observed: ?*render_observation.InvalidationResult) void {
            if (observed) |read| {
                read.* = .{ .identity = self.invalidationIdentity(intent, @intCast((@intFromPtr(intent) - @intFromPtr(&self.intents[0])) / @sizeOf(Intent))), .execution_ordinal = self.execution_ordinal };
            }
            intent.admission = self.admission(intent.batch_id, intent.content_hash, .invalidations, frame, .admitted);
            const plan = &self.plans[intent.plan_index];
            self.hook(.invalidation_target);
            const before = self.planStateObserved(plan, if (observed) |read| &read.state else null);
            if (observed) |read| {
                read.before = toTraceState(before);
                read.supported = before == .complete and intent.target_has_slot and intent.value.plan_target == null and
                    !intent.value.emergency_stop_music and intent.value.next_transport_epoch == 0 and intent.value.next_asset_generation == 0;
            }
            if (before.isTerminal()) {
                var record = baseRecord(intent.token, .cancel_too_late, frame);
                record.result = .too_late;
                record.state_before = toTraceState(before);
                record.executed_prefix_count = plan.executed_count.load(.acquire);
                if (record.executed_prefix_count != 0) record.executed_frame = plan.executed_frames[record.executed_prefix_count - 1];
                record.cancel_requested_frame = intent.value.requested_frame;
                record.commit_horizon = self.commit_horizon.load(.acquire);
                intent.receipt = record;
            } else {
                self.cancelPlanState(plan, intent.value.requested_frame, frame, before, .stale_epoch, .render);
                intent.receipt = self.planCancellationRecord(plan);
                self.shutdownAtGate(frame); // retires every visible suffix block
            }
            if (intent.value.next_transport_epoch > self.transport_epoch) self.transport_epoch = intent.value.next_transport_epoch;
            if (intent.value.next_asset_generation > self.asset_generation) self.asset_generation = intent.value.next_asset_generation;
            if (observed) |read| {
                read.admission = intent.admission;
                read.receipt = render_observation.TooLateReceipt.from(intent.receipt.?);
            }
            self.finishIntent(intent, observed);
        }
        fn cancelPlanState(self: *Self, plan: *Plan, requested: u64, frame: u64, before: music.PlanExecutionState, reason: trace.Reason, actual_role: semantic.Role) void {
            if (plan.cancelled.load(.acquire) or plan.executed_count.load(.acquire) == plan.total_phases) return;
            plan.cancel_requested = requested;
            plan.cancel_frame = frame;
            plan.cancel_horizon = self.commit_horizon.load(.acquire);
            plan.cancel_before = before;
            plan.cancel_reason = reason;
            // Reconcile observes this real publication. Copy identity before
            // release; never read the plan after Control can reclaim it.
            const plan_index = (@intFromPtr(plan) - @intFromPtr(&self.plans[0])) / @sizeOf(Plan);
            const plan_generation = plan.generation;
            self.semanticBoundary(actual_role, .scheduler_plan_cancel_release, .before, plan_index, plan_generation, 1);
            plan.cancelled.store(true, .release);
            self.semanticBoundary(actual_role, .scheduler_plan_cancel_release, .after, plan_index, plan_generation, 1);
        }
        fn planCancellationRecord(_: *Self, plan: *const Plan) trace.ScheduleRecord {
            const prefix = plan.executed_count.load(.acquire);
            var record = baseRecord(plan.token, if (prefix == 0) .cancel_effective else .superseded_after_partial, plan.cancel_frame);
            record.cancel_requested_frame = plan.cancel_requested;
            record.effective_frame = plan.cancel_frame;
            record.state_before = toTraceState(plan.cancel_before);
            record.result = .cancelled;
            record.cancelled_suffix_start = prefix;
            record.cancelled_suffix_count = plan.total_phases - prefix;
            record.executed_prefix_count = prefix;
            record.cancellation_scope = if (prefix == 0) .all_unexecuted else .remaining_only;
            record.commit_horizon = plan.cancel_horizon;
            record.reason = plan.cancel_reason;
            return record;
        }
        fn cancelSlot(self: *Self, slot: *Slot) void {
            self.cancelSlotObserved(slot, null, true, .render);
        }
        fn cancelSlotObserved(self: *Self, slot: *Slot, observed: ?*ControlPreparedCancellation, render_owned: bool, actual_role: order.Role) void {
            const plan = &self.plans[slot.plan_index];
            slot.cancellation = self.planCancellationRecord(plan);
            if (observed) |read| {
                const cancellation = slot.cancellation.?;
                read.cancel_frame = cancellation.effective_frame;
                read.cancel_requested = cancellation.cancel_requested_frame;
                read.cancel_horizon = cancellation.commit_horizon;
                read.cancel_before = cancellation.state_before;
                read.cancel_reason = cancellation.reason;
                read.receipt_executed_count = @intCast(cancellation.executed_prefix_count);
            }
            while (slot.next_command < slot.block.count) {
                self.recordCommandOwned(slot, slot.next_command, plan.cancel_frame, .cancelled, plan.cancel_reason, render_owned, actual_role);
                slot.next_command += 1;
            }
            const executed_count = plan.executed_count.load(.acquire);
            if (observed) |read| read.disposition_executed_count = executed_count;
            slot.disposition = if (executed_count == 0) .cancelled else .superseded_after_partial;
            self.publishTerminalOwned(slot, plan.cancel_frame, render_owned, actual_role);
            if (observed) |read| read.terminal_stored = true;
        }
        pub fn nextDue(self: *Self, frame: u64) ?*Slot {
            var best: ?*Slot = null;
            for (&self.slots) |*slot| {
                const state = slot.state.load(.acquire);
                if (state != .acquired and state != .partially_executed) continue;
                const command = slot.block.commands[slot.next_command];
                if (command.identity.execute_frame > frame) continue;
                if (best == null or commandBefore(command, best.?.block.commands[best.?.next_command])) best = slot;
            }
            return best;
        }
        pub fn nextFrame(self: *Self, end: u64) u64 {
            var next = end;
            for (&self.slots) |*slot| {
                const state = slot.state.load(.acquire);
                if (state != .acquired and state != .partially_executed) continue;
                next = @min(next, slot.block.commands[slot.next_command].identity.execute_frame);
            }
            return next;
        }
        pub fn group(slot: *Slot) []const Command {
            var end: usize = slot.next_command + 1;
            const id = slot.block.commands[slot.next_command].identity.group_id;
            while (end < slot.block.count and slot.block.commands[end].identity.group_id == id) : (end += 1) {}
            return slot.block.commands[slot.next_command..end];
        }
        pub fn finishGroup(self: *Self, slot: *Slot, frame: u64, reason: trace.Reason) void {
            const count = group(slot).len;
            for (0..count) |_| {
                self.recordCommand(slot, slot.next_command, frame, if (reason == .none) .executed else .rejected, reason);
                slot.next_command += 1;
            }
            slot.next_phase += 1;
            const plan = &self.plans[slot.plan_index];
            if (reason == .none) {
                slot.executed_count += 1;
                const phase = slot.first_phase + slot.next_phase - 1;
                std.debug.assert(phase == plan.executed_count.load(.monotonic));
                plan.executed_frames[phase] = frame;
                plan.executed_ordinals[phase] = self.execution_ordinal;
                const plan_generation = plan.generation;
                const plan_index = slot.plan_index;
                self.checkpoint(.render, .{ .site = .scheduler_phase, .edge = .before, .index = plan_index, .generation = plan_generation, .value = phase + 1 }, true);
                plan.executed_count.store(phase + 1, .release);
                self.checkpoint(.render, .{ .site = .scheduler_phase, .edge = .after, .index = plan_index, .generation = plan_generation, .value = phase + 1 }, true);
                self.causalProgress(.{ .site = .scheduler_phase, .index = plan_index, .generation = plan_generation, .value = phase + 1, .frame = frame });
                if (comptime @import("builtin").is_test) self.hook(.executed_phase);
            }
            if (reason != .none) {
                _ = self.counters.rejected.fetchAdd(1, .monotonic);
                self.rejectRemainder(slot, frame, reason);
            } else if (slot.next_command == slot.block.count) {
                slot.disposition = if (plan.executed_count.load(.acquire) == plan.total_phases) .complete else .partially_executed;
                self.publishTerminal(slot, frame);
                if (comptime @import("builtin").is_test) self.hook(.terminal_state);
            } else {
                slot.disposition = .partially_executed;
                slot.state.store(.partially_executed, .release);
            }
        }
        pub fn rejectRemainder(self: *Self, slot: *Slot, frame: u64, reason: trace.Reason) void {
            const plan = &self.plans[slot.plan_index];
            self.cancelPlanState(plan, frame, frame, self.planState(plan), reason, .render);
            while (slot.next_command < slot.block.count) {
                self.recordCommand(slot, slot.next_command, frame, .rejected, reason);
                slot.next_command += 1;
            }
            slot.disposition = if (plan.executed_count.load(.acquire) == 0) .cancelled else .superseded_after_partial;
            self.publishTerminal(slot, frame);
            if (comptime @import("builtin").is_test) self.hook(.terminal_state);
        }
        fn recordCommand(self: *Self, slot: *Slot, index: u16, frame: u64, outcome: Outcome, reason: trace.Reason) void {
            self.recordCommandOwned(slot, index, frame, outcome, reason, true, .render);
        }
        fn recordCommandOwned(self: *Self, slot: *Slot, index: u16, frame: u64, outcome: Outcome, reason: trace.Reason, render_owned: bool, actual_role: order.Role) void {
            const command = slot.block.commands[index];
            var record = baseRecord(command.identity.token, switch (outcome) {
                .executed => .executed,
                .cancelled => .cancel_effective,
                .rejected => .rejected,
            }, frame);
            record.command_id = command.identity.command_id;
            record.planned_frame = command.identity.execute_frame;
            record.executed_frame = if (outcome == .executed) frame else 0;
            record.sequence = command.sequence;
            record.group = command.identity.group_id;
            record.phase_order = command.identity.phase_order;
            record.result = switch (outcome) {
                .executed => .success,
                .cancelled => .cancelled,
                .rejected => .rejected,
            };
            record.reason = reason;
            if (outcome == .cancelled) {
                record.cancelled_suffix_start = command.identity.phase_order;
                record.cancelled_suffix_count = 1;
            }
            slot.receipts[slot.receipt_count] = record;
            slot.receipt_count += 1;
            var publication = self.slotCheckpoint(.scheduler_receipt, .before, slot, slot.receipt_count);
            const binding = self.orderBinding(actual_role, publication.index, publication.generation);
            self.offline(publication);
            self.emitOrder(binding, actual_role, publication);
            slot.published_receipts.store(slot.receipt_count, .release);
            publication.edge = .after;
            self.offline(publication);
            self.emitOrder(binding, actual_role, publication);
            if (render_owned) self.causalProgress(.{ .site = .scheduler_receipt, .index = publication.index, .generation = publication.generation, .value = publication.value, .frame = frame, .command_id = record.command_id });
            // Tests may stop the actual publisher after the receipt release,
            // before its caller publishes the whole-block terminal state.
            // No callback, pointer, branch, or wait exists in shipping builds.
            if (comptime @import("builtin").is_test) self.hook(.command_receipt);
        }
        fn admission(self: *Self, id: u64, hash: trace.Hash, kind: trace.BatchKind, frame: u64, disposition: trace.AdmissionDisposition) trace.Admission {
            defer self.gate_order += 1;
            return .{ .batch_id = id, .content_hash = hash, .kind = kind, .gate = self.gate_number, .frame = frame, .commit_horizon = self.commit_horizon.load(.acquire), .gate_order = self.gate_order, .disposition = disposition };
        }
        pub fn hook(self: *Self, stage: GateStage) void {
            if (@import("builtin").is_test) if (self.test_hook) |h| h.call(h.context, stage);
        }
        fn orderBinding(self: *const Self, role: order.Role, index: u64, generation: u64) ?order.Binding {
            const roles = self.prerequisite_order orelse return null;
            return .{ .collector = roles.get(role), .index = index, .generation = generation };
        }
        fn semanticBoundary(self: *const Self, role: semantic.Role, site: semantic.Boundary, edge: semantic.Edge, index: u64, generation: u64, value: ?u64) void {
            const hooks = self.live_semantic_hooks orelse return;
            hooks.boundary(hooks.context, .{ .role = role, .site = site, .edge = edge, .index = index, .generation = generation, .value = value });
        }
        fn emitOrder(self: *const Self, binding: ?order.Binding, role: order.Role, point: OfflineCheckpoint) void {
            if (binding) |value| value.emitFor(role, captureOrderSite(point.site), switch (point.edge) {
                .before => .before,
                .after => .after,
            }, captureOrderValue(point));
            // All call sites, including direct receipt/terminal/invalidation
            // releases, pass the same copied native coordinate. No collector
            // attachment or legacy observation gate is needed for this fan-out.
            // In particular, never reread a slot generation after its release.
            if (self.live_semantic_hooks) |hooks| {
                const cut: semantic.Point = .{
                    .role = role,
                    .site = captureOrderSite(point.site),
                    .edge = switch (point.edge) {
                        .before => .before,
                        .after => .after,
                    },
                    .index = point.index,
                    .generation = point.generation,
                    .value = captureOrderValue(point),
                };
                if (semantic.allowedPoint(cut)) hooks.point(hooks.context, cut);
            }
        }
        fn checkpoint(self: *Self, actual_role: ?order.Role, point: OfflineCheckpoint, legacy: bool) void {
            if (legacy) self.offline(point);
            if (actual_role) |role| self.emitOrder(self.orderBinding(role, point.index, point.generation), role, point);
        }
        fn offline(self: *Self, point: OfflineCheckpoint) void {
            if (self.offline_causal_replay) |hooks| hooks.checkpoint(hooks.context, point);
        }
        fn invalidationOffline(self: *Self, point: OfflineCheckpoint) void {
            if (self.offline_causal_replay) |hooks| {
                if (hooks.semantic_invalidations) hooks.checkpoint(hooks.context, point);
            }
        }
        fn invalidationCheckpoint(self: *Self, role: order.Role, point: OfflineCheckpoint) void {
            // Only explicitly opted-in offline owners may install a callback.
            // Live capture still uses the same bounded, nonwaiting role lane.
            self.invalidationOffline(point);
            self.emitOrder(self.orderBinding(role, point.index, point.generation), role, point);
        }
        fn causalProgress(self: *Self, value: CausalProgress) void {
            if (self.public_causal_progress_sink) |sink| sink.emit(sink.context, value);
        }
        fn slotCheckpoint(self: *Self, site: OfflineSite, edge: @FieldType(OfflineCheckpoint, "edge"), slot: *const Slot, value: u64) OfflineCheckpoint {
            return .{ .site = site, .edge = edge, .index = (@intFromPtr(slot) - @intFromPtr(&self.slots[0])) / @sizeOf(Slot), .generation = slot.generation, .value = value };
        }
        fn publishTerminal(self: *Self, slot: *Slot, frame: u64) void {
            self.publishTerminalOwned(slot, frame, true, .render);
        }
        fn publishTerminalOwned(self: *Self, slot: *Slot, frame: u64, render_owned: bool, actual_role: order.Role) void {
            var publication = self.slotCheckpoint(.scheduler_terminal, .before, slot, @intFromEnum(State.terminal));
            const binding = self.orderBinding(actual_role, publication.index, publication.generation);
            self.offline(publication);
            self.emitOrder(binding, actual_role, publication);
            slot.state.store(.terminal, .release);
            publication.edge = .after;
            // Identity, collector and value were copied before the final release.
            // No slot access after it: Control may already reuse this storage.
            self.offline(publication);
            self.emitOrder(binding, actual_role, publication);
            // Control-only prepared cancellation is already attributed by its
            // ControlPreparedCancellation witness, never a Render SPSC fact.
            if (render_owned) self.causalProgress(.{ .site = .scheduler_terminal, .index = publication.index, .generation = publication.generation, .value = publication.value, .frame = frame });
        }
        pub fn acknowledge(self: *Self, handle: Handle) Error!void {
            const operation = self.beginControl(.acknowledge, handle);
            var result: ControlResult = .success;
            defer self.endControl(operation, result);
            errdefer |err| result = ControlResult.fromError(err);
            var validation: ControlValidation = .{ .operation_id = operation.operation_id, .target = handle };
            const slot = self.getValidated(handle, null, &validation, .control) catch |err| {
                self.emitControl(.{ .acknowledge_validation = validation });
                return @as(Error!void, err);
            };
            self.emitControl(.{ .acknowledge_validation = validation });
            {
                self.checkpoint(.control, .{ .site = .scheduler_ack_terminal, .edge = .before, .index = handle.index, .generation = handle.generation }, true);
                const state = slot.state.load(.acquire);
                self.checkpoint(.control, .{ .site = .scheduler_ack_terminal, .edge = .after, .index = handle.index, .generation = handle.generation, .value = @intFromEnum(state) }, true);
                var terminal: ControlObservation = .{ .acknowledge_terminal = .{ .operation_id = operation.operation_id, .block = handle, .state = state } };
                defer self.emitControl(terminal);
                if (state != .terminal) return error.InvalidState;
                const invalidation_refs = slot.invalidation_refs;
                terminal.acknowledge_terminal.invalidation_refs = invalidation_refs;
                if (invalidation_refs != 0) return error.InvalidState;
                const queue_refs = slot.queue_refs;
                terminal.acknowledge_terminal.queue_refs = queue_refs;
                if (queue_refs != 0) return error.InvalidState;
                terminal.acknowledge_terminal.eligible = true;
            }
            const plan_index = slot.plan_index;
            const plan = &self.plans[plan_index];
            const plan_handle: Handle = .{ .index = plan_index, .generation = plan.generation };
            const block_refs = plan.block_refs;
            std.debug.assert(block_refs != 0);
            plan.block_refs = block_refs - 1;
            const binding = self.orderBinding(.control, handle.index, handle.generation);
            var publication: OfflineCheckpoint = .{ .site = .scheduler_slot_return, .edge = .before, .index = handle.index, .generation = handle.generation, .value = @intFromEnum(State.free) };
            self.offline(publication);
            self.emitOrder(binding, .control, publication);
            slot.state.store(.free, .release);
            publication.edge = .after;
            self.offline(publication);
            self.emitOrder(binding, .control, publication);
            self.emitControl(.{ .slot_return = .{
                .operation_id = operation.operation_id,
                .block = handle,
                .plan = plan_handle,
                .plan_block_refs_before = block_refs,
                .plan_block_refs_after = block_refs - 1,
            } });
            self.reapPlan(plan);
        }
        fn recordPressure(self: *Self) void {
            var blocks: u32 = 0;
            var commands: u32 = 0;
            var emergency: u32 = 0;
            for (&self.slots) |*s| if (s.state.load(.acquire) != .free) {
                blocks += 1;
                commands += s.block.count;
            };
            for (&self.intents) |*s| if (s.state.load(.acquire) != 0) {
                emergency += 1;
            };
            high(&self.counters.blocks_high_water, blocks);
            high(&self.counters.command_high_water, commands);
            high(&self.counters.emergency_high_water, emergency);
        }
        pub fn telemetry(self: *const Self) Telemetry {
            return .{ .plan_overflow = self.counters.plan_overflow.load(.monotonic), .fence_overflow = self.counters.fence_overflow.load(.monotonic), .blocks_high_water = self.counters.blocks_high_water.load(.monotonic), .command_high_water = self.counters.command_high_water.load(.monotonic), .emergency_high_water = self.counters.emergency_high_water.load(.monotonic), .overflow = self.counters.overflow.load(.monotonic), .late = self.counters.late.load(.monotonic), .rejected = self.counters.rejected.load(.monotonic), .receipt_backpressure = self.counters.receipt_backpressure.load(.monotonic) };
        }
    };
}
fn captureOrderSite(site: OfflineSite) order.Site {
    return switch (site) {
        .scheduler_validate => .scheduler_validate,
        .scheduler_ack_terminal => .scheduler_ack_terminal,
        .scheduler_control_scan => .scheduler_control_scan,
        .scheduler_reap_phase => .scheduler_reap_phase,
        .scheduler_reap_readers => .scheduler_reap_readers,
        .scheduler_slot_return => .scheduler_slot_return,
        .scheduler_scan => .scheduler_scan,
        .scheduler_publication => .scheduler_publication,
        .scheduler_acquired => .scheduler_acquired,
        .scheduler_phase => .scheduler_phase,
        .scheduler_terminal => .scheduler_terminal,
        .scheduler_receipt => .scheduler_receipt,
        .scheduler_horizon => .scheduler_horizon,
        .scheduler_prepare_horizon => .scheduler_prepare_horizon,
        .scheduler_invalidation_before_scan => .scheduler_invalidation_before_scan,
        .scheduler_invalidation_after_scan => .scheduler_invalidation_after_scan,
        .scheduler_invalidation_pre_claim => .scheduler_invalidation_pre_claim,
        .scheduler_invalidation_poll => .scheduler_invalidation_poll,
        .scheduler_invalidation_publication => .scheduler_invalidation_publication,
    };
}
fn captureOrderValue(point: OfflineCheckpoint) ?u64 {
    if (point.edge == .after) return point.value;
    return switch (point.site) {
        .scheduler_validate, .scheduler_ack_terminal, .scheduler_control_scan, .scheduler_reap_phase, .scheduler_reap_readers, .scheduler_scan, .scheduler_prepare_horizon, .scheduler_invalidation_poll => null,
        .scheduler_slot_return, .scheduler_publication, .scheduler_acquired, .scheduler_phase, .scheduler_terminal, .scheduler_receipt, .scheduler_horizon, .scheduler_invalidation_before_scan, .scheduler_invalidation_after_scan, .scheduler_invalidation_pre_claim, .scheduler_invalidation_publication => point.value,
    };
}

/// Importable focused checks only; production has no callable testing surface.
pub const PrerequisiteOrderTests = if (@import("builtin").is_test) struct {
    pub fn mapping() !void {
        inline for (std.meta.fields(OfflineSite)) |field| {
            const site: OfflineSite = @enumFromInt(field.value);
            try std.testing.expectEqual(@field(order.Site, field.name), captureOrderSite(site));
            try std.testing.expectEqual(@as(?u64, 0), captureOrderValue(.{ .site = site, .edge = .after }));
            try std.testing.expectEqual(@as(?u64, 19), captureOrderValue(.{ .site = site, .edge = .after, .value = 19 }));
        }
        inline for (.{ OfflineSite.scheduler_validate, .scheduler_ack_terminal, .scheduler_control_scan, .scheduler_reap_phase, .scheduler_reap_readers, .scheduler_scan, .scheduler_prepare_horizon, .scheduler_invalidation_poll }) |site| {
            try std.testing.expectEqual(@as(?u64, null), captureOrderValue(.{ .site = site, .edge = .before, .value = 19 }));
        }
        inline for (.{ OfflineSite.scheduler_slot_return, .scheduler_publication, .scheduler_acquired, .scheduler_phase, .scheduler_terminal, .scheduler_receipt, .scheduler_horizon, .scheduler_invalidation_before_scan, .scheduler_invalidation_after_scan, .scheduler_invalidation_pre_claim, .scheduler_invalidation_publication }) |site| {
            try std.testing.expectEqual(@as(?u64, 0), captureOrderValue(.{ .site = site, .edge = .before }));
            try std.testing.expectEqual(@as(?u64, 19), captureOrderValue(.{ .site = site, .edge = .before, .value = 19 }));
        }
    }
} else void;

pub fn serialBefore(a: u64, b: u64) bool {
    return @as(i64, @bitCast(a -% b)) < 0;
}
pub fn commandBefore(a: anytype, b: @TypeOf(a)) bool {
    if (a.identity.execute_frame != b.identity.execute_frame) return a.identity.execute_frame < b.identity.execute_frame;
    if (a.sequence != b.sequence) return serialBefore(a.sequence, b.sequence);
    return a.ordinal < b.ordinal;
}
fn high(value: *std.atomic.Value(u32), count: u32) void {
    const old = value.load(.monotonic);
    if (count > old) value.store(count, .monotonic);
}
fn baseRecord(token: music.PhaseToken, kind: trace.ScheduleKind, frame: u64) trace.ScheduleRecord {
    return .{ .kind = kind, .context = token.context.value(), .plan_id = token.plan_id.value(), .phase_id = token.phase_id.value(), .plan_epoch = token.plan_epoch.value(), .transport_epoch = token.transport_epoch.value(), .asset_generation = token.asset_generation.value(), .observed_render_frame = frame, .effective_frame = frame };
}
fn toTraceState(state: music.PlanExecutionState) trace.ExecutionState {
    return switch (state) {
        .prepared => .prepared,
        .published => .published,
        .acquired => .acquired,
        .partially_executed => .partially_executed,
        .complete => .complete,
        .cancelled => .cancelled,
        .superseded_after_partial => .superseded_after_partial,
    };
}
