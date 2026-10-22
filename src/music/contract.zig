//! Value contracts only. Scheduling, playback, replay codecs and runtime methods
//! belong to their implementation tasks; none are simulated here.
const std = @import("std");
const ids = @import("ids.zig");
const MusicError = @import("errors.zig").MusicError;

pub const ApiThread = enum { game, control, worker, render, tool };
pub const ApiOperation = enum {
    submit,
    poll_receipt,
    snapshot,
    load_bank,
    unload_bank,
    start,
    capture_state,
    restore_state,
    hot_reload,
    rollback_generation,
    shutdown,
    prepare_assets,
    execute_commands,
    seek_preview,
};
/// Requirements for future runtime methods, not method implementations.
/// Control has exactly one owner; render has exactly one callback owner.
pub fn requiredThread(operation: ApiOperation) ApiThread {
    return switch (operation) {
        .submit, .poll_receipt, .snapshot => .game,
        .load_bank, .unload_bank, .start, .capture_state, .restore_state, .hot_reload, .rollback_generation, .shutdown => .control,
        .prepare_assets => .worker,
        .execute_commands => .render,
        .seek_preview => .tool,
    };
}
pub const ProductionOwnership = struct {
    pub const control_owner = ApiThread.control;
    pub const mixer_owner = ApiThread.render;
    pub const scheduler_owner = ApiThread.render;
    pub const render_frame_owner = ApiThread.render;
    pub const music_runtime_owner = ApiThread.control;
    pub const contexts_per_renderer = 1;
    pub const mixers_per_renderer = 1;
    pub const legacy_engine_is_separate = true;
    pub const legacy_adapter_implementation_task = 14;
    pub const host_quiescence_before_destroy = true;
};
/// Reviewed TASK-025 prerequisite from b618046 (src/runtime/runtime.zig and
/// docs/design/runtime-embedding-v1.md). These are audit facts, not extra queues
/// or dynamic enforcement. The public snapshot_count is checked by the harness;
/// owner-pin limit 8 and the ownership facts require the callback source audit.
pub const ProductionBaseline = struct {
    pub const snapshot_acquire_attempts = 3;
    pub const owner_pin_attempts = 8;
    pub const sequence_zero_is_valid = true;
    pub const sequence_assigned_after_cell_claim = true;
    pub const exact_ticket_drain = true;
    pub const max_live_serial_distance_exclusive: u64 = @as(u64, 1) << 63;
    pub const missed_snapshot_keeps_render_pins = true;
    pub const terminal_identity_includes_start_order = true;
    pub const render_completion_is_lossless_retry = true;
    pub const host_observation_can_overflow = true;
};

/// Starting becomes playing only after the first group execution receipt.
/// Paused freezes music cursor, not the SFX/render timeline. Shutdown requires
/// host quiescence and non-render reclamation; this enum is not a state machine.
pub const MusicRuntimeState = enum {
    uninitialized,
    loading_bank,
    ready,
    starting,
    playing,
    paused,
    stopping,
    shutting_down,
    destroyed,
};
pub const MusicContextKind = enum { shipping_game, authoring, offline, debug };
pub const MusicContextValue = union(enum) {
    boolean: bool,
    integer: i64,
    scalar: f32,
    id: ids.MusicContextValueId,
};
pub const MusicStopMode = enum { next_boundary, emergency_ramp };
pub const DuckRequest = struct {
    id: ids.DuckRequestId,
    preset: ids.DuckPresetId,
};
pub const MusicRequestPayload = union(enum) {
    set_state: struct { state: ids.MusicStateId, priority: u8 = 0 },
    set_parameter: struct { parameter: ids.MusicParameterId, value: f32 },
    set_context: struct { key: ids.MusicContextId, value: MusicContextValue },
    trigger_stinger: ids.StingerId,
    begin_duck: DuckRequest,
    end_duck: ids.DuckRequestId,
    /// Tool-only. Exactly one of cue or frame is supplied; frame zero is valid.
    seek_preview: struct { segment: ids.SegmentId, cue: ?ids.CueId = null, frame: ?u64 = null },
    pause,
    @"resume",
    stop: MusicStopMode,
};
/// Entirely owned/copyable value; no borrowed payload pointer crosses ingress.
/// IDs increase monotonically per runtime request stream and never wrap to zero.
/// This differs deliberately from the legacy queue's wrapping acceptance tickets.
pub const MusicRequest = struct {
    request_id: u64,
    payload: MusicRequestPayload,

    pub fn validate(self: MusicRequest, context: MusicContextKind) MusicError!void {
        if (self.request_id == 0) return error.InvalidState;
        switch (self.payload) {
            .set_state => |p| if (!p.state.isValid()) return error.InvalidState,
            .set_parameter => |p| {
                if (!p.parameter.isValid() or !std.math.isFinite(p.value)) return error.InvalidState;
            },
            .set_context => |p| {
                if (!p.key.isValid()) return error.InvalidState;
                switch (p.value) {
                    .scalar => |v| if (!std.math.isFinite(v)) return error.InvalidState,
                    .id => |v| if (!v.isValid()) return error.InvalidState,
                    else => {},
                }
            },
            .trigger_stinger => |id| if (!id.isValid()) return error.InvalidState,
            .begin_duck => |p| if (!p.id.isValid() or !p.preset.isValid()) return error.InvalidState,
            .end_duck => |id| if (!id.isValid()) return error.InvalidState,
            .seek_preview => |p| {
                if (context == .shipping_game) return error.UnsupportedOperation;
                if (!p.segment.isValid() or (p.cue == null) == (p.frame == null)) return error.InvalidState;
                if (p.cue) |cue| if (!cue.isValid()) return error.InvalidState;
            },
            .pause, .@"resume", .stop => {},
        }
    }

    pub fn validateAfter(self: MusicRequest, previous_request_id: u64, context: MusicContextKind) MusicError!void {
        try self.validate(context);
        if (self.request_id <= previous_request_id) return error.InvalidState;
    }
};

/// Authoritative Control observation. Caller enqueue/wall time is not this frame.
/// All fields, including the payload, are owned values.
pub const ControlAcceptedInput = struct {
    context: ids.RuntimeContextId,
    accepted_control_frame: u64,
    control_tick: u64,
    input_order: u64,
    request: MusicRequest,
};

pub const PlanExecutionState = enum {
    prepared,
    published,
    acquired,
    partially_executed,
    complete,
    cancelled,
    superseded_after_partial,

    pub fn isTerminal(self: PlanExecutionState) bool {
        return switch (self) {
            .complete, .cancelled, .superseded_after_partial => true,
            else => false,
        };
    }
    /// Classification only. Actual cancellation wins at the render execution gate.
    pub fn cancellationScope(self: PlanExecutionState) CancellationScope {
        return switch (self) {
            .prepared, .published, .acquired => .all_unexecuted,
            .partially_executed => .remaining_only,
            .complete, .cancelled, .superseded_after_partial => .none,
        };
    }
};
pub const CancellationScope = enum { all_unexecuted, remaining_only, none };
pub const PhaseToken = struct {
    context: ids.RuntimeContextId,
    transport_epoch: ids.TransportEpoch,
    plan_id: ids.PlanId,
    plan_epoch: ids.PlanEpoch,
    phase_id: ids.PhaseId,
    asset_generation: ids.AssetGeneration,

    pub fn validate(self: PhaseToken) MusicError!void {
        if (!self.context.isValid() or !self.transport_epoch.isValid() or !self.plan_id.isValid() or
            !self.plan_epoch.isValid() or !self.phase_id.isValid()) return error.InvalidState;
        if (!self.asset_generation.isValid()) return error.StaleAssetGeneration;
    }
};
pub const PlanReceipt = struct {
    token: PhaseToken,
    state: PlanExecutionState,
    observed_render_frame: u64,
};
pub const PhaseOutcome = enum { executed, cancelled };
/// One terminal outcome per phase. Actual deduplication is TASK-002's scheduler.
pub const PhaseReceipt = struct {
    token: PhaseToken,
    outcome: PhaseOutcome,
    effective_frame: u64,
};
pub const CancellationDisposition = union(enum) {
    /// No execution claim had won for this phase at the effective frame.
    effective: struct { effective_frame: u64, remaining_only: bool },
    /// PCM already generated is irreversible, including pending backend PCM.
    too_late: struct { executed_frame: u64 },
};
/// Render emits one fixed-size receipt per phase, never an allocated phase set.
/// Control reconstructs an executed phase set from PhaseReceipt values.
pub const CancellationReceipt = struct {
    token: PhaseToken,
    state_before: PlanExecutionState,
    disposition: CancellationDisposition,

    pub fn validate(self: CancellationReceipt) MusicError!void {
        try self.token.validate();
        switch (self.disposition) {
            .effective => |p| {
                if (self.state_before.cancellationScope() == .none) return error.InvalidState;
                if (p.remaining_only != (self.state_before == .partially_executed)) return error.InvalidState;
            },
            .too_late => {
                if (self.state_before != .partially_executed and self.state_before != .complete) return error.InvalidState;
            },
        }
    }
};
pub const MusicReceipt = union(enum) {
    request_accepted: ControlAcceptedInput,
    plan_prepared: PlanReceipt,
    plan_published: PlanReceipt,
    plan_acquired: PlanReceipt,
    plan_partially_executed: PlanReceipt,
    plan_complete: PlanReceipt,
    phase_terminal: PhaseReceipt,
    cancel_requested: PhaseToken,
    cancellation_result: CancellationReceipt,
    rejected: struct { request_id: u64, reason: MusicError },

    /// Reject inconsistent stage tags before observation/serialization. This does
    /// not implement state transitions, scheduling or receipt deduplication.
    pub fn validate(self: MusicReceipt, context: MusicContextKind) MusicError!void {
        switch (self) {
            .request_accepted => |p| {
                if (!p.context.isValid()) return error.InvalidState;
                try p.request.validate(context);
            },
            .plan_prepared, .plan_published, .plan_acquired, .plan_partially_executed, .plan_complete => |p| {
                try p.token.validate();
                const expected: PlanExecutionState = switch (self) {
                    .plan_prepared => .prepared,
                    .plan_published => .published,
                    .plan_acquired => .acquired,
                    .plan_partially_executed => .partially_executed,
                    .plan_complete => .complete,
                    else => unreachable,
                };
                if (p.state != expected) return error.InvalidState;
            },
            .phase_terminal => |p| try p.token.validate(),
            .cancel_requested => |p| try p.validate(),
            .cancellation_result => |p| try p.validate(),
            // Rejection may report request_id zero precisely because ingress
            // rejected that invalid ID; do not erase the caller's diagnostic.
            .rejected => {},
        }
    }
};

/// Half-open interval on the monotonic PCM production timeline.
pub const FrameRange = struct {
    start: u64,
    end: u64,
    pub fn validate(self: FrameRange) MusicError!void {
        if (self.end < self.start) return error.InvalidState;
    }
    pub fn length(self: FrameRange) MusicError!u64 {
        try self.validate();
        return self.end - self.start;
    }
};
pub const DeliveredFrames = union(enum) {
    unavailable,
    exact: u64,
    estimated: struct { frames: u64, max_error_frames: u64 },
};
/// submitted_frames is a backend count, not an audible position or necessarily a
/// render coordinate after a flush. Delivered observations refer to this device
/// epoch. No inference converts the submitted count into an exact observation.
pub const DeliveryObservation = struct {
    device_epoch: ids.DeviceEpoch,
    render_frame: u64,
    submitted_frames: u64,
    delivered_frames: DeliveredFrames = .unavailable,
    pub fn validate(self: DeliveryObservation) MusicError!void {
        if (!self.device_epoch.isValid()) return error.InvalidState;
        switch (self.delivered_frames) {
            .unavailable => {},
            .exact => |frames| if (frames > self.submitted_frames) return error.InvalidState,
            .estimated => |p| {
                if (p.max_error_frames == 0) return error.InvalidState;
                // A bounded estimate may lie ahead, but its lower bound cannot.
                if (p.frames > self.submitted_frames and p.frames - self.submitted_frames > p.max_error_frames)
                    return error.InvalidState;
            },
        }
    }
};
pub const PendingPcmRange = struct {
    device_epoch: ids.DeviceEpoch,
    transport_epoch: ids.TransportEpoch,
    render_frames: FrameRange,
    pub fn validate(self: PendingPcmRange) MusicError!void {
        if (!self.device_epoch.isValid() or !self.transport_epoch.isValid()) return error.InvalidState;
        try self.render_frames.validate();
    }
};
pub const DeviceFlushRecord = struct {
    old_device_epoch: ids.DeviceEpoch,
    new_device_epoch: ids.DeviceEpoch,
    discarded: FrameRange,
    /// Unretractable hardware tail; absent means the interval is unknown.
    hardware_uncertainty: ?FrameRange,
    pub fn validate(self: DeviceFlushRecord) MusicError!void {
        if (!self.old_device_epoch.isValid() or !self.new_device_epoch.isValid() or self.old_device_epoch == self.new_device_epoch)
            return error.InvalidState;
        try self.discarded.validate();
        if (self.hardware_uncertainty) |range| try range.validate();
    }
};
pub const DeviceRecoveryPolicy = enum { restart_at_bar, resume_phase };

/// This header is a memory/API contract, NOT an on-disk Zig struct dump.
/// TASK-004 supplies canonical encoding and the complete event payload schema.
pub const RecordingHeaderV2 = struct {
    schema_version: u16 = 2,
    compiler_version: u32,
    algorithm_version: u32,
    bank_content_hash: [32]u8,
    profile: ids.PlatformProfileId,
    seed: u64,
    initial_state_hash: [32]u8,
    sample_rate: u32,
    quantum_frames: u32,
};
fn RecordingEnvelope(comptime schema: enum { replay_input, schedule_trace }) type {
    return struct {
        pub const schema_name = if (schema == .replay_input) "ReplayInputV2" else "ScheduleTraceV2";
        pub const schema_version: u16 = 2;
        pub const codec_implementation_task = 4;
        header: RecordingHeaderV2,
        /// Borrowed immutable encoded storage, valid for the entire consumer call.
        /// Persisting/enqueuing the envelope requires an owned copy or owner lease.
        payload: []const u8,
    };
}
pub const ReplayInputV2 = RecordingEnvelope(.replay_input);
pub const ScheduleTraceV2 = RecordingEnvelope(.schedule_trace);
