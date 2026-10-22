//! Bounded control-only transition planning. Uses admitted cue/path tables,
//! accepted real streaming observations and actual scheduler phase receipts.
const std = @import("std");
const music = @import("music");
const bank = @import("sme-bank");
pub const s = bank.schema;
const clock = @import("sme-clock");
const director = @import("sme-director");
const streaming = @import("sme-streaming");
const recording = @import("sme-trace");
pub const trace = recording.schema;
pub const Error = s.BankError || clock.Error || streaming.stream.Error || error{ InvalidOrder, IncompleteTrace };
pub const algorithm_version: u16 = 1;
pub const max_phases: usize = 64;
pub const max_chunks: usize = 256;
pub const max_bindings: usize = 48;
pub const max_issued_plans: usize = 64;
pub const Config = struct { issued_plan_capacity: u16 = max_issued_plans };
const Issued = struct { active: bool = false, plan_id: u64 = 0, plan_epoch: u64 = 0, digest: [32]u8 = @splat(0) };
pub const score_fields = [_][]const u8{ "sync_penalty", "readiness_penalty", "authored_rank", "audible_frame", "source_cue_id", "fill_route_id", "target_cue_id", "target_segment_id" };
/// One-based first differing score column, zero means exact equality.
pub fn scoreDifference(a: anytype, b: @TypeOf(a)) u8 {
    inline for (score_fields, 0..) |name, i| if (@field(a, name) != @field(b, name)) return i + 1;
    return 0;
}
pub fn scoreLess(a: anytype, b: @TypeOf(a)) bool {
    inline for (score_fields) |name| {
        if (@field(a, name) != @field(b, name)) return @field(a, name) < @field(b, name);
    }
    return false;
}
fn add(a: u64, b: u64) Error!u64 {
    return std.math.add(u64, a, b) catch error.ArithmeticOverflow;
}
fn mul(a: u64, b: u64) Error!u64 {
    return std.math.mul(u64, a, b) catch error.ArithmeticOverflow;
}
pub const PhaseKind = enum(u8) { source_tail, source_stop, fill_entry, fill_tail, fill_stop, target_entry };
pub const Phase = struct {
    token: music.PhaseToken,
    kind: PhaseKind,
    segment: u64,
    cue: u64,
    execute_frame: u64,
    end_frame: u64,
    source_cursor: u64,
    tempo_span: u32,
    stop_segment: u64 = 0,
};
pub const BoundedTransitionPhases = struct {
    count: u16 = 0,
    items: [max_phases]Phase = undefined,
    pub fn slice(self: *const BoundedTransitionPhases) []const Phase {
        return self.items[0..self.count];
    }
    fn append(self: *BoundedTransitionPhases, phase: Phase, limit: usize) Error!void {
        if (self.count >= max_phases or self.count >= limit) return error.ResourceLimitExceeded;
        self.items[self.count] = phase;
        self.count += 1;
    }
};
pub const RequiredChunk = struct { sound: u64, chunk_index: u32, first_frame: u64, end_frame: u64, deadline_frame: u64, phase_mask: u64 };
pub const BoundedChunkSet = struct {
    count: u16 = 0,
    items: [max_chunks]RequiredChunk = undefined,
    pub fn slice(self: *const BoundedChunkSet) []const RequiredChunk {
        return self.items[0..self.count];
    }
    fn include(self: *BoundedChunkSet, item: RequiredChunk, limit: usize) Error!void {
        for (self.items[0..self.count]) |*previous| if (previous.sound == item.sound and previous.chunk_index == item.chunk_index) {
            if (previous.first_frame != item.first_frame or previous.end_frame != item.end_frame) return error.InvalidMusicGraph;
            previous.deadline_frame = @min(previous.deadline_frame, item.deadline_frame);
            previous.phase_mask |= item.phase_mask;
            return;
        };
        if (self.count >= max_chunks or self.count >= limit) return error.ResourceLimitExceeded;
        self.items[self.count] = item;
        self.count += 1;
    }
};
/// One prepared stream per sound/window; immutable identity is rechecked against
/// actual Service facts. The caller owns the stream/asset lease through execution.
pub const StreamBinding = struct { sound: u64, layer: u64, segment: u64, cue: u64, occurrence: u16 = 0, source_cursor: u64, handle: streaming.Handle };
pub const ReadinessSnapshot = struct {
    complete: bool = false,
    stream_profile: streaming.StreamCapacityProfile = .{},
    count: u16 = 0,
    bindings: [max_bindings]StreamBinding = undefined,
    observations: [max_bindings]trace.Input = undefined,
    failures: [max_bindings]streaming.stream.Failure = undefined,
    identities: [max_bindings]streaming.SourceIdentity = undefined,
    /// This produces genuine TASK-011 observations, not an application-provided
    /// ready boolean. Caller records the returned observations in ReplayInputV2.
    /// In replay Service returns its already accepted, recomputed cached facts.
    pub fn collect(self: *ReadinessSnapshot, service: *streaming.Service, bindings: []const StreamBinding, position: trace.Position, context: u64, control_epoch: u64) Error!void {
        if (service.runtime_attached) return error.InvalidState;
        if (bindings.len > max_bindings) return error.ResourceLimitExceeded;
        self.complete = false;
        self.stream_profile = service.profile;
        self.count = 0;
        for (bindings, 0..) |binding, i| {
            if (binding.sound == 0 or binding.layer == 0) return error.InvalidState;
            for (bindings[0..i]) |previous| if (std.meta.eql(previous.handle, binding.handle) or (previous.layer == binding.layer and previous.segment == binding.segment and previous.cue == binding.cue and previous.occurrence == binding.occurrence)) return error.InvalidState;
            var accepted = position;
            accepted.input_order = try add(position.input_order, i);
            const input = try service.readiness(binding.handle, accepted, context, control_epoch);
            const facts = input.payload.readiness_snapshot.facts;
            const identity = (try service.renderSource(binding.handle)).identity;
            if (facts.asset != binding.sound or identity.start_cursor != binding.source_cursor) return error.InvalidState;
            self.bindings[i] = binding;
            self.observations[i] = input;
            self.failures[i] = try service.failure(binding.handle);
            self.identities[i] = identity;
            self.count += 1;
        }
        self.complete = true;
    }
    /// Attached production observations go through the one Control owner so
    /// acceptance position/order and ReplayInputV2 recording remain canonical.
    pub fn collectControl(self: *ReadinessSnapshot, control: anytype, bindings: []const StreamBinding, context: u64, control_epoch: u64) Error!void {
        self.complete = false;
        const service = control.streaming_service orelse return error.InvalidState;
        return self.collectOwned(control, service, bindings, context, control_epoch, false, null);
    }
    /// The integrated Runtime owner already holds Control. The checked TickV1
    /// retains one genuine observation frame and rejects stale/reentrant use.
    pub fn collectTick(self: *ReadinessSnapshot, scope: anytype, bindings: []const StreamBinding, context: u64, control_epoch: u64) Error!void {
        self.complete = false;
        const service = scope.readinessService() catch return error.InvalidState;
        return self.collectOwned(scope, service, bindings, context, control_epoch, false, null);
    }
    /// The same collector with an explicit stack-carried live query outcome.
    /// The failed query returns immediately; no later planner error can borrow
    /// its provenance, and an incomplete snapshot never reaches the solver.
    pub fn collectTickLiveV1(self: *ReadinessSnapshot, scope: anytype, bindings: []const StreamBinding, context: u64, control_epoch: u64) Error!?streaming.stream.LiveObservationDeferV1 {
        self.complete = false;
        const service = scope.readinessService() catch return error.InvalidState;
        var deferred: ?streaming.stream.LiveObservationDeferV1 = null;
        self.collectOwned(scope, service, bindings, context, control_epoch, true, &deferred) catch |err| {
            if (err == error.InvalidState) if (deferred) |value| return value;
            return err;
        };
        return null;
    }
    pub fn collectTickInitialEntryV1(self: *ReadinessSnapshot, scope: anytype, request_id: u64, bindings: []const StreamBinding, context: u64, control_epoch: u64) Error!void {
        self.complete = false;
        self.count = 0;
        const service = scope.readinessService() catch return error.InvalidState;
        const Adapter = struct {
            tick: @TypeOf(scope),
            request: u64,
            pub fn streamReadiness(adapter: @This(), handle: streaming.Handle, query_context: u64, epoch: u64) !trace.Input {
                return adapter.tick.streamReadinessInitialEntryV1(adapter.request, handle, query_context, epoch);
            }
        };
        return self.collectOwned(Adapter{ .tick = scope, .request = request_id }, service, bindings, context, control_epoch, false, null);
    }
    fn collectOwned(self: *ReadinessSnapshot, control: anytype, service: *streaming.Service, bindings: []const StreamBinding, context: u64, control_epoch: u64, comptime live: bool, deferred: ?*?streaming.stream.LiveObservationDeferV1) Error!void {
        if (!service.runtime_attached or bindings.len > max_bindings) return error.InvalidState;
        self.complete = false;
        self.count = 0;
        self.stream_profile = service.profile;
        for (bindings, 0..) |binding, i| {
            if (binding.sound == 0 or binding.layer == 0) return error.InvalidState;
            for (bindings[0..i]) |previous| if (std.meta.eql(previous.handle, binding.handle) or (previous.layer == binding.layer and previous.segment == binding.segment and previous.cue == binding.cue and previous.occurrence == binding.occurrence)) return error.InvalidState;
            const input = if (live)
                control.streamReadinessLiveV1(binding.handle, context, control_epoch, deferred.?) catch return error.InvalidState
            else
                control.streamReadiness(binding.handle, context, control_epoch) catch return error.InvalidState;
            if (i > 0 and (input.position.accepted_control_frame != self.observations[0].position.accepted_control_frame or input.position.control_tick != self.observations[0].position.control_tick or !trace.before(self.observations[i - 1].position, input.position))) return error.InvalidState;
            const facts = input.payload.readiness_snapshot.facts;
            const identity = (try service.renderSource(binding.handle)).identity;
            if (facts.asset != binding.sound or identity.start_cursor != binding.source_cursor) return error.InvalidState;
            self.bindings[i] = binding;
            self.observations[i] = input;
            self.failures[i] = try service.failure(binding.handle);
            self.identities[i] = identity;
            self.count += 1;
        }
        self.complete = true;
    }
};
/// Receipt ledger is a control-owned consumer of TASK-002 terminal facts.
/// Cancellation requests never fabricate outcomes or erase an executed prefix.
pub const GroupBinding = struct { index: u16, generation: u64, stable_id: u64 };
pub const Continuation = struct { source_segment: u64, source_group: u64, observed_frame: u64, source_clock: clock.Clock, previous_plan_id: u64, previous_plan_epoch: u64 };
pub const PlanCursor = struct {
    phases: BoundedTransitionPhases,
    groups: [max_phases]?GroupBinding = @splat(null),
    outcomes: [max_phases]?music.PhaseOutcome = @splat(null),
    effective_frames: [max_phases]u64 = @splat(0),
    cancel_requested_frame: ?u64 = null,
    last_executed_frame: ?u64 = null,
    pub fn init(phases: BoundedTransitionPhases) Error!PlanCursor {
        if (phases.count == 0 or phases.count > max_phases) return error.InvalidState;
        const first = phases.items[0].token;
        for (phases.slice(), 0..) |phase, i| {
            try phase.token.validate();
            if (phase.end_frame < phase.execute_frame or phase.segment == 0 or phase.token.context != first.context or phase.token.plan_id != first.plan_id or phase.token.plan_epoch != first.plan_epoch or phase.token.transport_epoch != first.transport_epoch or phase.token.asset_generation != first.asset_generation) return error.InvalidState;
            if (i > 0 and phase.execute_frame < phases.items[i - 1].execute_frame) return error.InvalidOrder;
            for (phases.slice()[0..i]) |prior| if (prior.token.phase_id == phase.token.phase_id) return error.InvalidState;
        }
        return .{ .phases = phases };
    }
    /// Control records the actual prepared handle before publishing its entry.
    pub fn bindGroup(self: *PlanCursor, phase_token: music.PhaseToken, handle: anytype, stable_id: u64) Error!void {
        if (handle.generation == 0 or stable_id == 0) return error.InvalidState;
        for (self.phases.slice(), 0..) |phase_value, i| if (std.meta.eql(phase_value.token, phase_token)) {
            if ((phase_value.kind != .fill_entry and phase_value.kind != .target_entry) or self.groups[i] != null or self.outcomes[i] != null) return error.InvalidState;
            for (self.groups) |prior| if (prior != null and prior.?.index == handle.index and prior.?.generation == handle.generation) return error.InvalidState;
            self.groups[i] = .{ .index = handle.index, .generation = handle.generation, .stable_id = stable_id };
            return;
        };
        return error.InvalidState;
    }
    /// Host-quiescent/serialized observation only: renderer group state is not a
    /// cross-thread snapshot API. Consume real terminal receipts for every old
    /// phase first. A remaining overlap group must be explicitly stopped and
    /// acknowledged; this method never invents a stop or discards its cursor.
    /// Generic renderer/handle retain the actual RuntimeRenderer type identity
    /// without adding a facade-to-runtime import cycle.
    pub fn continuationQuiescent(self: *const PlanCursor, solver: *const Planner, renderer: anytype, handle: anytype) Error!Continuation {
        if (!self.isTerminal()) return error.InvalidState;
        const group = renderer.musicGroup(handle) orelse return error.TransitionNotFound;
        const actual = group.snapshot();
        if (actual.state != .playing or actual.degraded or actual.underrun_frame != null or actual.generation != solver.generation) return error.TransitionNotFound;
        const frame = renderer.renderFrame();
        const binding = renderer.group_bindings[handle.index] orelse return error.InvalidState;
        var entered: ?Phase = null;
        var stable_id: u64 = 0;
        for (self.phases.slice(), 0..) |phase_value, i| if (self.groups[i]) |bound| {
            if (bound.index == handle.index and bound.generation == handle.generation) {
                if (self.outcomes[i] != .executed or phase_value.segment != actual.segment or phase_value.execute_frame != actual.start_render_frame or self.effective_frames[i] != actual.start_render_frame or binding.context != phase_value.token.context.value() or binding.transport_epoch != phase_value.token.transport_epoch.value()) return error.InvalidState;
                entered = phase_value;
                stable_id = bound.stable_id;
            }
        };
        const phase_value = entered orelse return error.InvalidState;
        for (renderer.group_bindings) |other| if (other) |entry| {
            if (entry.context != binding.context or entry.control.eql(handle)) continue;
            if (renderer.musicGroup(entry.control)) |active| if (active.state == .playing or active.state == .releasing) return error.TransitionNotFound;
        };
        if (frame < actual.start_render_frame or actual.cursor >= group.frames) return error.InvalidState;
        const index = try solver.findSegment(actual.segment);
        const definition = solver.tables.segments[index];
        if (definition.frames != group.frames) return error.InvalidState;
        if (definition.loop_end > definition.loop_start) {
            const actual_loop = group.loop orelse return error.InvalidState;
            if (actual_loop.start != definition.loop_start or actual_loop.end != definition.loop_end) return error.InvalidState;
        } else if (group.loop != null) return error.InvalidState;
        const map = solver.maps[definition.tempo];
        var elapsed = actual.cursor;
        if (map.tempo.loop_present == 1) {
            const first = try map.frameAtTick(map.tempo.loop_start_tick);
            const end = try map.frameAtTick(map.tempo.loop_end_tick);
            const loop = group.loop orelse return error.InvalidState;
            if (loop.start != first or loop.end != end) return error.InvalidState;
            elapsed = try add(elapsed, try mul(actual.loop_epoch, end - first));
        } else if (group.loop != null or actual.loop_epoch != 0) return error.InvalidState;
        var transport = clock.Clock.init(map, frame);
        transport.anchor_elapsed = elapsed;
        transport.transport_epoch = phase_value.token.transport_epoch.value();
        return .{ .source_segment = actual.segment, .source_group = stable_id, .observed_frame = frame, .source_clock = transport, .previous_plan_id = phase_value.token.plan_id.value(), .previous_plan_epoch = phase_value.token.plan_epoch.value() };
    }
    pub fn requestCancel(self: *PlanCursor, frame: u64) Error!void {
        if (self.cancel_requested_frame != null) return error.InvalidState;
        if (self.last_executed_frame != null and frame < self.last_executed_frame.?) return error.InvalidOrder;
        self.cancel_requested_frame = frame;
    }
    pub fn receipt(self: *PlanCursor, value: music.PhaseReceipt) Error!void {
        try value.token.validate();
        for (self.phases.slice(), 0..) |phase, i| if (std.meta.eql(phase.token, value.token)) {
            if (self.outcomes[i] != null) return error.InvalidState;
            if (value.outcome == .executed) {
                if (value.effective_frame != phase.execute_frame or (self.last_executed_frame != null and value.effective_frame < self.last_executed_frame.?)) return error.InvalidOrder;
                self.last_executed_frame = value.effective_frame;
            }
            self.outcomes[i] = value.outcome;
            self.effective_frames[i] = value.effective_frame;
            return;
        };
        return error.InvalidState;
    }
    /// Consume the real scheduler's plan-level cancelled suffix fact after
    /// draining its real executed-prefix PhaseReceipts. No request is evidence.
    pub fn cancellation(self: *PlanCursor, record: trace.ScheduleRecord) Error!void {
        record.validate() catch return error.InvalidState;
        const first = self.phases.items[0].token;
        if ((record.kind != .cancel_effective and record.kind != .superseded_after_partial) or record.result != .cancelled or record.context != first.context.value() or record.plan_id != first.plan_id.value() or record.plan_epoch != first.plan_epoch.value() or record.transport_epoch != first.transport_epoch.value() or record.asset_generation != first.asset_generation.value() or record.executed_prefix_count != self.executedCount() or record.cancelled_suffix_start != record.executed_prefix_count or @as(u64, record.executed_prefix_count) + record.cancelled_suffix_count != self.phases.count) return error.InvalidState;
        for (self.outcomes[0..self.phases.count], 0..) |outcome, i| {
            if (i < record.executed_prefix_count) {
                if (outcome != .executed) return error.InvalidState;
            } else if (outcome != null) return error.InvalidState;
        }
        for (record.cancelled_suffix_start..self.phases.count) |i| {
            self.outcomes[i] = .cancelled;
            self.effective_frames[i] = record.effective_frame;
        }
    }
    pub fn terminalReceipt(self: *const PlanCursor, index: usize) Error!music.PhaseReceipt {
        if (index >= self.phases.count) return error.InvalidState;
        return .{ .token = self.phases.items[index].token, .outcome = self.outcomes[index] orelse return error.InvalidState, .effective_frame = self.effective_frames[index] };
    }
    pub fn isTerminal(self: *const PlanCursor) bool {
        for (self.outcomes[0..self.phases.count]) |outcome| if (outcome == null) return false;
        return true;
    }
    pub fn executedCount(self: *const PlanCursor) u16 {
        var count: u16 = 0;
        for (self.outcomes[0..self.phases.count]) |outcome| if (outcome == .executed) {
            count += 1;
        };
        return count;
    }
};
pub const PlannerTrace = struct {
    records: []trace.ScheduleEntry,
    count: usize = 0,
    enabled: bool = true,
    next_sequence: u64 = 0,
    dropped: u64 = 0,
    incomplete: bool = false,
    pub fn disabled() PlannerTrace {
        return .{ .records = &.{}, .enabled = false };
    }
    pub fn emit(self: *PlannerTrace, value: trace.PlannerRecord) void {
        var row = value;
        row.sequence = self.next_sequence;
        if (self.next_sequence == std.math.maxInt(u64)) self.incomplete = true else self.next_sequence += 1;
        if (!self.enabled or self.count >= self.records.len) {
            self.incomplete = true;
            self.dropped +|= 1;
            return;
        }
        self.records[self.count] = .{ .planner_candidate = row };
        self.count += 1;
    }
    pub fn requireComplete(self: *const PlannerTrace) trace.Error!void {
        if (self.incomplete) return error.IncompleteTrace;
    }
    pub fn recordingHeader(self: *const PlannerTrace, header: trace.Header) trace.Header {
        var result = header;
        result.complete = result.complete and !self.incomplete;
        return result;
    }
};
pub const Score = trace.PlannerScore;
/// Rolling admission is a distinct proof, never a full-fill PCM assertion.
/// The default retains complete pre-publication coverage for every fill.
pub const FillPcmMode = enum(u8) { full_span, rolling_high_watermark };
/// The default keeps the existing one-interval source proof byte-for-byte.
/// Only the integrated original-group observation may opt into a loop seam.
pub const SourceTailPcmMode = enum(u8) { contiguous, live_one_loop, _ };
pub const live_source_layers: usize = 4;
pub const source_tail_proof_version: u16 = 1;
pub const SourceTailCoordinate = struct { cursor: u64, loop_epoch: u64 };
pub const LiveSourceTailLayer = struct {
    layer: u64,
    sound: u64,
    handle: streaming.Handle,
    identity: streaming.SourceIdentity,
    consumed: u64,
    control_consumed: u64,
    visible_produced: u64,
    capacity_frames: u32,
    real: bool,
    gated: bool,
    stopped: bool,
    references: u32,
    failure: streaming.stream.Failure,
};
/// Borrowed, candidate-independent values captured from the original playing
/// group and four rings within one checked Control Tick. The constructor owns
/// coherence and custody; no ring pointers or synthetic readiness are accepted.
pub const LiveSourceTailSnapshot = struct {
    complete: bool = false,
    count: u8 = 0,
    context: u64 = 0,
    asset_generation: u64 = 0,
    transport_epoch: u64 = 0,
    source_segment: u64 = 0,
    group: GroupBinding = .{ .index = 0, .generation = 0, .stable_id = 0 },
    source_incarnation: u64 = 0,
    position: trace.Position = .{ .accepted_control_frame = 0, .control_tick = 0, .input_order = 0 },
    observed_frame: u64 = 0,
    cursor: u64 = 0,
    loop_epoch: u64 = 0,
    loop: ?streaming.Loop = null,
    observation_sequence: u64 = 0,
    playing: bool = false,
    paused: bool = false,
    stream_profile: streaming.StreamCapacityProfile = .{},
    layers: [live_source_layers]LiveSourceTailLayer = undefined,
    pub fn digest(self: *const LiveSourceTailSnapshot) Error![32]u8 {
        if (!self.complete or self.count != live_source_layers) return error.InvalidState;
        var h = std.crypto.hash.sha2.Sha256.init(.{});
        h.update("SME-live-source-tail-snapshot-v1");
        hashValue(&h, self.*);
        var result: [32]u8 = undefined;
        h.final(&result);
        return result;
    }
};
pub const LiveSourceTailReference = struct {
    layer: u64,
    sound: u64,
    handle: streaming.Handle,
    consumed: u64,
    onset_ordinal: u64,
    end_ordinal: u64,
};
/// Fixed issued obligation. The one digest binds every original snapshot and
/// SourceIdentity scalar; identities themselves are deliberately not retained.
pub const LiveSourceTailObligation = struct {
    version: u16 = source_tail_proof_version,
    count: u8 = live_source_layers,
    snapshot_digest: [32]u8,
    group: GroupBinding,
    source_incarnation: u64,
    observed_frame: u64,
    observed: SourceTailCoordinate,
    onset: SourceTailCoordinate,
    terminal: SourceTailCoordinate,
    layers: [live_source_layers]LiveSourceTailReference,
};
comptime {
    if (@sizeOf(LiveSourceTailObligation) > 512) @compileError("live source-tail obligation exceeds its fixed budget");
}
pub const ReadinessReference = struct { sound: u64, layer: u64, segment: u64, cue: u64, occurrence: u16, cursor: u64, version: u64, deadline_frame: u64, required_pcm_frames: u64 };
pub const TransitionPlan = struct {
    version: u16 = algorithm_version,
    bank_build_id: u64,
    request_position: trace.Position,
    planning_position: trace.Position,
    planning_frontier: u64,
    source_anchor_render: u64,
    source_anchor_elapsed: u64,
    source_device_epoch: u64,
    source_tempo_id: u64,
    plan_id: u64,
    plan_epoch: u64,
    request_id: u64,
    request_epoch: u64,
    selector_epoch: u64,
    rule_id: u64,
    from_state: u64,
    to_state: u64,
    source_group: ?u64,
    source_segment: u64,
    target_segment: u64,
    source_exit_cue: u64,
    target_entry_cue: u64,
    fill_route: ?u64,
    path_id: u64,
    execute_frame: u64,
    target_start_frame: u64,
    fill_start_frame: ?u64 = null,
    fill_end_frame: ?u64 = null,
    fade_frames: u64 = 0,
    asset_generation: u64,
    transport_epoch: u64,
    sync: s.Sync,
    score: Score,
    phases: BoundedTransitionPhases = .{},
    required_chunks: BoundedChunkSet = .{},
    readiness_count: u16 = 0,
    readiness: [max_bindings]ReadinessReference = undefined,
    requires_pcm_recheck: bool = false,
    /// Included in the issued-plan integrity digest alongside exact coverage.
    fill_pcm_mode: FillPcmMode = .full_span,
    source_tail_pcm_mode: SourceTailPcmMode = .contiguous,
    source_tail_obligation: ?LiveSourceTailObligation = null,
    pub fn targetToken(self: *const TransitionPlan) Error!music.PhaseToken {
        for (self.phases.slice()) |phase| if (phase.kind == .target_entry) return phase.token;
        return error.InvalidMusicGraph;
    }
};
pub const Query = struct {
    intent: director.TransitionIntent,
    source_segment: u64,
    source_group: ?u64 = null,
    source_clock: clock.Clock,
    request_position: trace.Position,
    position: trace.Position,
    frontier: clock.SchedulingFrontier,
    context: u64,
    asset_generation: u64,
    transport_epoch: u64,
    plan_id: u64,
    plan_epoch: u64,
    plan_id_floor: u64 = 1,
    readiness: ?*const ReadinessSnapshot = null,
    fill_pcm_mode: FillPcmMode = .full_span,
    source_tail_pcm_mode: SourceTailPcmMode = .contiguous,
    live_source_tail: ?*const LiveSourceTailSnapshot = null,
};
const IdIndex = struct {
    id: u64,
    index: u32,
    fn less(_: void, left: IdIndex, right: IdIndex) bool {
        return left.id < right.id;
    }
};
fn buildIndex(allocator: std.mem.Allocator, records: anytype) Error![]IdIndex {
    const result = try allocator.alloc(IdIndex, records.len);
    errdefer allocator.free(result);
    for (records, result, 0..) |record, *entry, i| {
        if (record.key.id == 0) return error.InvalidMusicGraph;
        entry.* = .{ .id = record.key.id, .index = @intCast(i) };
    }
    std.mem.sort(IdIndex, result, {}, IdIndex.less);
    for (result, 0..) |entry, i| if (i > 0 and result[i - 1].id == entry.id) return error.IdCollision;
    return result;
}
fn lookupIndex(index: []const IdIndex, id: u64) Error!u32 {
    var lo: usize = 0;
    var hi = index.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (index[mid].id < id) lo = mid + 1 else hi = mid;
    }
    if (lo == index.len or index[lo].id != id) return error.InvalidMusicGraph;
    return index[lo].index;
}
const Candidate = struct { path: u32 = 0, score: ?Score = null, reason: trace.Reason = .none, awaiting_pcm: bool = false };
pub const Planner = struct {
    allocator: std.mem.Allocator,
    tables: s.Tables,
    profile: s.Platform,
    generation: u64,
    bank_build_id: u64,
    maps: []clock.Map,
    segment_ids: []IdIndex,
    cue_ids: []IdIndex,
    candidates: []Candidate,
    issued: []Issued,
    scratch: *TransitionPlan,
    best: *TransitionPlan,
    last_plan_id: u64 = 0,
    failure_reason: trace.Reason = .none,
    retry_after: ?u64 = null,
    require_actual_pcm: bool = false,
    failed_candidate_paths: ?s.Range = null,
    pub fn init(self: *Planner, allocator: std.mem.Allocator, tables: s.Tables, profile: s.Platform, generation: u64, bank_build_id: u64) Error!void {
        return self.initWithConfig(allocator, tables, profile, generation, bank_build_id, .{});
    }
    pub fn initWithConfig(self: *Planner, allocator: std.mem.Allocator, tables: s.Tables, profile: s.Platform, generation: u64, bank_build_id: u64, config: Config) Error!void {
        if (config.issued_plan_capacity == 0 or config.issued_plan_capacity > max_issued_plans) return error.ResourceLimitExceeded;
        if (generation == 0 or bank_build_id == 0) return error.InvalidState;
        try bank.transition_validation.validateLimits(tables, profile);
        if (tables.segments.len > profile.max_table_records or tables.segments.len > s.Limits.records or tables.tempos.len > profile.max_table_records or tables.tempos.len > s.Limits.records) return error.ResourceLimitExceeded;
        // Reused ranges can amplify validation work despite small flat tables.
        // Count the admitted work before any heap allocation or grid traversal.
        var work: u64 = 0;
        for (tables.tempos) |tempo| {
            work = try add(work, @as(u64, tempo.spans.count) + tempo.meters.count + tempo.queries.count + tempo.beats.count + tempo.bars.count);
            if (work > s.Limits.grid_entries) return error.ResourceLimitExceeded;
            for (try bank.transition_validation.items(s.TempoQuery, tables.tempo_queries, tempo.queries)) |query| {
                work = try add(work, query.frames.count);
                if (work > s.Limits.grid_entries) return error.ResourceLimitExceeded;
            }
        }
        if (work > s.Limits.grid_entries) return error.ResourceLimitExceeded;
        const maps = try allocator.alloc(clock.Map, tables.tempos.len);
        errdefer allocator.free(maps);
        for (maps, 0..) |*map, index| map.* = try clock.Map.init(tables, @intCast(index), &.{}, profile);
        for (tables.cues) |cue| {
            if (cue.segment >= tables.segments.len or tables.segments[cue.segment].tempo >= maps.len) return error.InvalidMusicGraph;
            if (cue.frame != try maps[tables.segments[cue.segment].tempo].frameAtTick(cue.tick)) return error.InvalidTempo;
        }
        try bank.transition_validation.validate(allocator, tables, profile, true);
        const segment_ids = try buildIndex(allocator, tables.segments);
        errdefer allocator.free(segment_ids);
        const cue_ids = try buildIndex(allocator, tables.cues);
        errdefer allocator.free(cue_ids);
        const candidates = try allocator.alloc(Candidate, profile.max_planner_candidates);
        errdefer allocator.free(candidates);
        const issued = try allocator.alloc(Issued, config.issued_plan_capacity);
        errdefer allocator.free(issued);
        @memset(issued, .{});
        const scratch = try allocator.create(TransitionPlan);
        errdefer allocator.destroy(scratch);
        const best = try allocator.create(TransitionPlan);
        errdefer allocator.destroy(best);
        self.* = .{ .allocator = allocator, .tables = tables, .profile = profile, .generation = generation, .bank_build_id = bank_build_id, .maps = maps, .segment_ids = segment_ids, .cue_ids = cue_ids, .candidates = candidates, .issued = issued, .scratch = scratch, .best = best };
    }
    pub fn deinit(self: *Planner) void {
        self.allocator.destroy(self.best);
        self.allocator.destroy(self.scratch);
        self.allocator.free(self.issued);
        self.allocator.free(self.candidates);
        self.allocator.free(self.cue_ids);
        self.allocator.free(self.segment_ids);
        self.allocator.free(self.maps);
        self.* = undefined;
    }
    fn findSegment(self: *const Planner, id: u64) Error!u32 {
        return lookupIndex(self.segment_ids, id);
    }
    fn findCue(self: *const Planner, id: u64) Error!u32 {
        return lookupIndex(self.cue_ids, id);
    }
    fn find(records: anytype, id: u64) Error!u32 {
        for (records, 0..) |record, i| if (record.key.id == id) return @intCast(i);
        return error.InvalidMusicGraph;
    }
    fn phase(self: *Planner, q: Query, kind: PhaseKind, segment: u32, cue: u32, execute: u64, end: u64, cursor: u64, stop: u64) Error!void {
        if (end < execute) return error.InvalidMusicGraph;
        const def = self.tables.segments[segment];
        if (cursor > def.frames) return error.InvalidMusicGraph;
        const phase_id = @as(u64, self.scratch.phases.count) + 1;
        try self.scratch.phases.append(.{ .token = .{ .context = @enumFromInt(q.context), .transport_epoch = @enumFromInt(q.transport_epoch), .asset_generation = @enumFromInt(q.asset_generation), .plan_id = @enumFromInt(q.plan_id), .plan_epoch = @enumFromInt(q.plan_epoch), .phase_id = @enumFromInt(phase_id) }, .kind = kind, .segment = def.key.id, .cue = self.tables.cues[cue].key.id, .execute_frame = execute, .end_frame = end, .source_cursor = cursor, .tempo_span = try bank.transition_validation.span(self.tables, segment, self.tables.cues[cue].tick), .stop_segment = stop }, self.profile.max_planner_phases);
    }
    fn makeCandidate(self: *Planner, q: Query, path_index: u32, boundary: u64, sync_penalty: u64) Error!void {
        const path = self.tables.transition_paths[path_index];
        const rule = self.tables.transitions[path.transition];
        const exit = self.tables.cues[path.source_exit];
        const entry = self.tables.cues[path.target_entry];
        const live_layout: ?bank.transition_validation.BoundedDirectTailLayout = if (q.source_tail_pcm_mode == .live_one_loop) try bank.transition_validation.boundedDirectTailLayout(self.tables, path, self.profile) else null;
        if (live_layout) |layout| if (!layout.crosses_loop) return error.UnsupportedCapability;
        self.scratch.* = .{ .bank_build_id = self.bank_build_id, .fill_pcm_mode = q.fill_pcm_mode, .source_tail_pcm_mode = q.source_tail_pcm_mode, .request_position = q.request_position, .planning_position = q.position, .planning_frontier = q.frontier.earliest_submit_frame, .source_anchor_render = q.source_clock.anchor_render, .source_anchor_elapsed = q.source_clock.anchor_elapsed, .source_device_epoch = q.source_clock.device_epoch, .source_tempo_id = q.source_clock.map.tempo.key.id, .plan_id = q.plan_id, .plan_epoch = q.plan_epoch, .request_id = q.intent.request_id, .request_epoch = q.intent.request_epoch, .selector_epoch = q.intent.selector_epoch, .rule_id = q.intent.rule_id, .from_state = q.intent.from, .to_state = q.intent.to, .source_group = q.source_group, .source_segment = q.source_segment, .target_segment = q.intent.resolved_segment, .source_exit_cue = exit.key.id, .target_entry_cue = entry.key.id, .fill_route = if (path.fill == s.none) null else self.tables.fills[path.fill].key.id, .path_id = path.key.id, .execute_frame = boundary, .target_start_frame = 0, .asset_generation = q.asset_generation, .transport_epoch = q.transport_epoch, .sync = rule.sync, .score = .{ .sync_penalty = sync_penalty, .readiness_penalty = 0, .authored_rank = path.authored_rank, .audible_frame = 0, .source_cue_id = exit.key.id, .fill_route_id = if (path.fill == s.none) 0 else self.tables.fills[path.fill].key.id, .target_cue_id = entry.key.id, .target_segment_id = q.intent.resolved_segment } };
        var previous = exit;
        var previous_index = path.source_exit;
        var previous_exit_frame = boundary;
        var overlap = rule.overlap_frames;
        var stop_segment: u64 = 0;
        const steps: []const s.FillStep = if (path.fill == s.none) &.{} else try bank.transition_validation.items(s.FillStep, self.tables.fill_steps, self.tables.fills[path.fill].steps);
        for (0..steps.len + 1) |hop_index| {
            const tail: u64 = if (path.handoff == .hard_cut) 0 else previous.tail_frames;
            if (overlap > tail) return error.InvalidMusicGraph;
            const stop_frame = try add(previous_exit_frame, tail);
            const start_frame = stop_frame - overlap;
            if (tail > 0) try self.phase(q, if (hop_index == 0) .source_tail else .fill_tail, previous.segment, previous_index, previous_exit_frame, stop_frame, previous.frame, 0);
            if (overlap > 0) {
                try self.phase(q, if (hop_index == 0) .source_stop else .fill_stop, previous.segment, previous_index, stop_frame, stop_frame, if (hop_index == 0 and live_layout != null) live_layout.?.terminal_cursor else try add(previous.frame, tail), 0);
                stop_segment = 0;
            } else stop_segment = self.tables.segments[previous.segment].key.id;
            if (hop_index < steps.len) {
                const step = steps[hop_index];
                const fill_entry = self.tables.cues[step.entry];
                const fill_exit = self.tables.cues[step.exit];
                const end = try add(start_frame, fill_exit.frame - fill_entry.frame);
                try self.phase(q, .fill_entry, step.segment, step.entry, start_frame, try add(end, if (path.handoff == .hard_cut) 0 else fill_exit.tail_frames), fill_entry.frame, stop_segment);
                if (self.scratch.fill_start_frame == null) self.scratch.fill_start_frame = start_frame;
                self.scratch.fill_end_frame = end;
                previous = fill_exit;
                previous_index = step.exit;
                previous_exit_frame = end;
                overlap = step.overlap_frames;
            } else {
                const target = self.tables.segments[entry.segment];
                try self.phase(q, .target_entry, entry.segment, path.target_entry, start_frame, try add(start_frame, target.frames - entry.frame), entry.frame, stop_segment);
                self.scratch.target_start_frame = start_frame;
                self.scratch.score.audible_frame = if (self.scratch.fill_start_frame) |first| first else start_frame;
            }
        }
        if (live_layout) |layout| {
            self.scratch.fade_frames = layout.fade_frames;
        } else if (rule.fade_ticks > 0) {
            const map = self.maps[self.tables.segments[exit.segment].tempo];
            const fade_end_tick = try add(exit.tick, rule.fade_ticks);
            if (fade_end_tick > map.tempo.total_ticks) return error.InvalidMusicGraph;
            self.scratch.fade_frames = (try map.frameAtTick(fade_end_tick)) - exit.frame;
            if (self.scratch.fade_frames > exit.tail_frames) return error.InvalidMusicGraph;
        }
        const Order = struct {
            fn less(_: void, a: Phase, b: Phase) bool {
                if (a.execute_frame != b.execute_frame) return a.execute_frame < b.execute_frame;
                return a.token.phase_id.value() < b.token.phase_id.value();
            }
        };
        std.mem.sort(Phase, self.scratch.phases.items[0..self.scratch.phases.count], {}, Order.less);
        for (self.scratch.phases.items[0..self.scratch.phases.count], 0..) |*value, i| value.token.phase_id = @enumFromInt(i + 1);
        self.retry_after = null;
        try self.requiredAssets(q);
    }
    fn requiredAssets(self: *Planner, q: Query) Error!void {
        const ready = q.readiness;
        const initial_window: u64 = self.profile.planner_minimum_window_frames;
        if (ready != null and (!ready.?.complete or ready.?.count > max_bindings)) return error.IncompleteTrace;
        if (ready) |snapshot| try snapshot.stream_profile.validate();
        var late = false;
        var late_reason: trace.Reason = .none;
        for (self.scratch.phases.slice(), 0..) |phase_value, phase_index| {
            if (phase_value.kind != .source_tail and phase_value.kind != .fill_entry and phase_value.kind != .target_entry) continue;
            const segment_index = try self.findSegment(phase_value.segment);
            const segment = self.tables.segments[segment_index];
            const cue_index = try self.findCue(phase_value.cue);
            const lead_frame = try add(if (self.require_actual_pcm) q.request_position.accepted_control_frame else q.position.accepted_control_frame, self.tables.cues[cue_index].min_lead_frames);
            if (phase_value.execute_frame < lead_frame) {
                late_reason = .insufficient_lead;
                self.retry_after = @max(self.retry_after orelse 0, lead_frame - (phase_value.execute_frame - self.scratch.execute_frame));
                late = true;
            }
            if (phase_value.kind == .source_tail and q.source_tail_pcm_mode == .live_one_loop) {
                try self.requiredLiveSourceTail(q, phase_value, phase_index);
                continue;
            }
            const duration = phase_value.end_frame - phase_value.execute_frame;
            const phase_playable = if (phase_value.kind == .target_entry) @min(initial_window, duration) else duration;
            if (phase_playable == 0) return error.InvalidMusicGraph;
            // Source/chunk coverage remains the entire fill span in both modes.
            const source_end = try add(phase_value.source_cursor, phase_playable);
            if (source_end > segment.frames) return error.InvalidMusicGraph;
            var occurrence: u16 = 0;
            for (self.scratch.phases.slice()[0..phase_index]) |prior| if (prior.segment == phase_value.segment and prior.cue == phase_value.cue and (prior.kind == .source_tail or prior.kind == .fill_entry or prior.kind == .target_entry)) {
                occurrence += 1;
            };
            for (try bank.transition_validation.items(s.Layer, self.tables.layers, segment.layers)) |layer| {
                if (layer.segment != segment_index or layer.sound >= self.tables.sounds.len or layer.required > 1) return error.InvalidMusicGraph;
                if (layer.required == 0) continue;
                const sound = self.tables.sounds[layer.sound];
                const start = try add(layer.source_start, phase_value.source_cursor);
                const end = try add(layer.source_start, source_end);
                if (end > sound.frames) return error.MisalignedStems;
                if (sound.storage == .resident) continue;
                self.failure_reason = .readiness_unknown;
                const observations = ready orelse return error.TargetNotResident;
                const rolling = phase_value.kind == .fill_entry and q.fill_pcm_mode == .rolling_high_watermark and duration > observations.stream_profile.high_frames;
                if (rolling) {
                    const path = self.tables.transition_paths[try find(self.tables.transition_paths, self.scratch.path_id)];
                    // No tail, overlap, nonzero-entry or fading contract is
                    // silently introduced by opting into rolling supply.
                    if (path.handoff != .hard_cut or phase_value.source_cursor != 0 or self.scratch.fade_frames != 0 or phase_value.stop_segment == 0) return error.UnsupportedCapability;
                }
                const playable = if (rolling) observations.stream_profile.high_frames else phase_playable;
                var matched: ?usize = null;
                for (observations.bindings[0..observations.count], 0..) |binding, i| if (binding.sound == sound.key.id and binding.layer == layer.key.id and binding.segment == phase_value.segment and binding.cue == phase_value.cue and binding.occurrence == occurrence) {
                    if (matched != null) return error.InvalidMusicGraph;
                    matched = i;
                };
                const index = matched orelse return error.TargetNotResident;
                if (rolling and observations.failures[index] != .none) return error.TargetNotResident;
                const input = observations.observations[index];
                input.validate() catch return error.InvalidMusicGraph;
                if (input.payload != .readiness_snapshot) return error.InvalidMusicGraph;
                const observed = input.payload.readiness_snapshot;
                const facts = observed.facts;
                if (facts.generation != q.asset_generation or facts.transport_epoch != q.transport_epoch) return error.StaleAssetGeneration;
                if (facts.context != q.context or facts.control_epoch != q.intent.request_epoch or input.position.accepted_control_frame != q.position.accepted_control_frame or input.position.control_tick != q.position.control_tick or facts.asset != sound.key.id) return error.InvalidState;
                const identity = observations.identities[index];
                if (identity.asset != sound.key.id or identity.frame_count != sound.frames or identity.asset_generation != q.asset_generation or identity.transport_epoch != q.transport_epoch or !std.mem.eql(u8, &identity.encoded_hash, &sound.audio_hash)) return error.StaleAssetGeneration;
                if (facts.profile != observations.stream_profile.id or identity.profile_id != facts.profile or !std.mem.eql(u8, &facts.profile_hash, &observations.stream_profile.hash()) or !std.mem.eql(u8, &identity.profile_hash, &facts.profile_hash)) return error.InvalidState;
                if (identity.loop) |loop| if (loop.start >= loop.end or loop.end > identity.frame_count) return error.InvalidState;
                if (segment.loop_end > segment.loop_start) {
                    const actual_loop = identity.loop orelse return error.InvalidState;
                    if (actual_loop.start != try add(layer.source_start, segment.loop_start) or actual_loop.end != try add(layer.source_start, segment.loop_end)) return error.InvalidState;
                } else if (identity.loop != null) return error.InvalidState;
                const actual_end = if (identity.loop) |loop| loop.end else identity.frame_count;
                if (facts.pcm_start > actual_end) return error.InvalidState;
                const required_end = try add(start, playable);
                if (end > actual_end or required_end > actual_end) return error.TargetNotResident;
                const actual = facts.pcm_start <= start and facts.pcm_end >= required_end and facts.available_frames >= required_end - facts.pcm_start;
                if (!actual) {
                    if (self.require_actual_pcm or rolling) return error.TargetNotResident;
                    // A forecast certifies only the Service's queried starting
                    // window. Never extend a finite ETA to another source cursor.
                    if (start != facts.pcm_start or playable > @min(@as(u64, observations.stream_profile.critical_frames), actual_end - facts.pcm_start) or observations.failures[index] != .none) return error.TargetNotResident;
                    const estimate = observed.expected.estimated_ready_frame orelse return error.TargetNotResident;
                    if (estimate > phase_value.execute_frame) {
                        const offset = phase_value.execute_frame - self.scratch.execute_frame;
                        self.retry_after = @max(self.retry_after orelse 0, estimate - offset);
                        late = true;
                        late_reason = .target_not_resident;
                    }
                    self.scratch.requires_pcm_recheck = true;
                    self.scratch.score.readiness_penalty = 1;
                }
                if (self.scratch.readiness_count >= max_bindings) return error.ResourceLimitExceeded;
                self.scratch.readiness[self.scratch.readiness_count] = .{ .sound = sound.key.id, .layer = layer.key.id, .segment = phase_value.segment, .cue = phase_value.cue, .occurrence = occurrence, .cursor = start, .version = facts.snapshot_version, .deadline_frame = phase_value.execute_frame, .required_pcm_frames = playable };
                self.scratch.readiness_count += 1;
                try self.includeLayerChunks(sound, layer.sound, start, end, phase_value.execute_frame, phase_index);
            }
        }
        if (@as(usize, self.scratch.readiness_count) + (if (self.scratch.source_tail_obligation != null) live_source_layers else @as(usize, 0)) > max_bindings) return error.ResourceLimitExceeded;
        if (late) {
            self.failure_reason = late_reason;
            return if (late_reason == .insufficient_lead) error.TransitionNotFound else error.TargetNotResident;
        }
    }
    fn requiredLiveSourceTail(self: *Planner, q: Query, phase_value: Phase, phase_index: usize) Error!void {
        self.failure_reason = .readiness_unknown;
        const snapshot = q.live_source_tail orelse return error.InvalidState;
        const path_index = try find(self.tables.transition_paths, self.scratch.path_id);
        const layout = try bank.transition_validation.boundedDirectTailLayout(self.tables, self.tables.transition_paths[path_index], self.profile);
        if (!layout.crosses_loop or layout.span_count != 2 or layout.terminal_epoch_increment != 1 or self.scratch.source_tail_obligation != null) return error.InvalidState;
        if (!snapshot.complete or snapshot.count != live_source_layers or snapshot.source_incarnation != 1 or
            snapshot.group.generation == 0 or snapshot.group.stable_id == 0 or q.source_group != snapshot.group.stable_id or
            snapshot.source_segment != q.source_segment or snapshot.context != q.context or snapshot.asset_generation != q.asset_generation or
            snapshot.transport_epoch != q.transport_epoch or !std.meta.eql(snapshot.position, q.position) or
            snapshot.observed_frame != q.position.accepted_control_frame or
            snapshot.observation_sequence & 1 != 0 or snapshot.paused or !snapshot.playing) return error.InvalidState;
        if (snapshot.loop == null or snapshot.loop.?.start != layout.loop_start or snapshot.loop.?.end != layout.loop_end or
            snapshot.cursor >= layout.loop_end or (snapshot.loop_epoch > 0 and snapshot.cursor < layout.loop_start)) return error.InvalidState;
        try snapshot.stream_profile.validate();
        if (!std.meta.eql(snapshot.stream_profile, streaming.release_profile)) return error.UnsupportedCapability;
        const observations = q.readiness orelse return error.TargetNotResident;
        if (!std.meta.eql(observations.stream_profile, snapshot.stream_profile)) return error.InvalidState;
        const segment_index = try self.findSegment(phase_value.segment);
        const segment = self.tables.segments[segment_index];
        const layers = try bank.transition_validation.items(s.Layer, self.tables.layers, segment.layers);
        if (layers.len != live_source_layers or phase_value.source_cursor != layout.onset_cursor or
            phase_value.end_frame - phase_value.execute_frame != layout.fade_frames or phase_value.execute_frame < snapshot.observed_frame) return error.InvalidState;
        const loop_length = layout.loop_end - layout.loop_start;
        if (try q.source_clock.elapsedAt(snapshot.observed_frame) != try add(snapshot.cursor, try mul(snapshot.loop_epoch, loop_length))) return error.InvalidState;
        const lead = phase_value.execute_frame - snapshot.observed_frame;
        const needed = try add(lead, layout.fade_frames);
        const terminal_epoch = try add(snapshot.loop_epoch, 1);
        var obligation: LiveSourceTailObligation = .{
            .snapshot_digest = try snapshot.digest(),
            .group = snapshot.group,
            .source_incarnation = snapshot.source_incarnation,
            .observed_frame = snapshot.observed_frame,
            .observed = .{ .cursor = snapshot.cursor, .loop_epoch = snapshot.loop_epoch },
            .onset = .{ .cursor = layout.onset_cursor, .loop_epoch = snapshot.loop_epoch },
            .terminal = .{ .cursor = layout.terminal_cursor, .loop_epoch = terminal_epoch },
            .layers = undefined,
        };
        var cold = false;
        for (layers, snapshot.layers, 0..) |layer, observed, i| {
            if (layer.segment != segment_index or layer.sound >= self.tables.sounds.len or layer.required != 1 or layer.source_start != 0) return error.InvalidMusicGraph;
            const sound = self.tables.sounds[layer.sound];
            const identity = observed.identity;
            if (sound.storage != .streaming or observed.layer != layer.key.id or observed.sound != sound.key.id or
                !observed.real or !observed.gated or observed.stopped or observed.references != 1 or observed.handle.generation == 0 or
                observed.handle.index >= snapshot.stream_profile.max_streams or observed.capacity_frames != snapshot.stream_profile.ring_frames or
                identity.asset != sound.key.id or identity.asset_generation != q.asset_generation or identity.transport_epoch != q.transport_epoch or
                identity.stream_generation != observed.handle.generation or identity.frame_count != sound.frames or identity.channels != sound.channels or
                identity.profile_id != snapshot.stream_profile.id or !std.mem.eql(u8, &identity.profile_hash, &snapshot.stream_profile.hash()) or
                !std.mem.eql(u8, &identity.encoded_hash, &sound.audio_hash) or identity.minimum_playable_frames == 0 or
                identity.minimum_playable_frames >= observed.capacity_frames or !std.meta.eql(identity.loop, snapshot.loop)) return error.InvalidState;
            for (snapshot.layers[0..i]) |prior| if (prior.layer == observed.layer or std.meta.eql(prior.handle, observed.handle)) return error.InvalidState;
            var matched: ?usize = null;
            for (observations.bindings[0..observations.count], 0..) |binding, j| if (binding.layer == layer.key.id and binding.segment == phase_value.segment and binding.cue == phase_value.cue and binding.occurrence == 0) {
                if (matched != null or binding.sound != sound.key.id or !std.meta.eql(binding.handle, observed.handle) or
                    binding.source_cursor != identity.start_cursor or !std.meta.eql(observations.identities[j], identity)) return error.InvalidState;
                matched = j;
            };
            if (matched == null) return error.InvalidState;
            // Validate all four original identities and actual coordinates
            // before a legitimate future-epoch candidate is treated as cold.
            // A forged cursor/epoch must never be disguised as a retry.
            const coordinate = try sourceTailCoordinate(identity, observed.consumed);
            if (!std.meta.eql(coordinate, obligation.observed)) return error.InvalidState;
            const onset_ordinal = try add(observed.consumed, lead);
            const end_ordinal = try add(onset_ordinal, layout.fade_frames);
            const onset = try sourceTailCoordinate(identity, onset_ordinal);
            const terminal = try sourceTailCoordinate(identity, end_ordinal);
            const last = try sourceTailCoordinate(identity, end_ordinal - 1);
            const candidate_terminal_epoch = try add(onset.loop_epoch, 1);
            if (onset.cursor != layout.onset_cursor or onset.loop_epoch < snapshot.loop_epoch or
                terminal.cursor != layout.terminal_cursor or terminal.loop_epoch != candidate_terminal_epoch or
                last.loop_epoch != candidate_terminal_epoch or last.cursor + 1 != layout.terminal_cursor) return error.InvalidState;
            // B after this epoch's exit is legal scheduling, but cannot use
            // the same-epoch live-tail certificate. Recollect after the seam.
            cold = cold or onset.loop_epoch != snapshot.loop_epoch or observed.failure != .none or
                observed.consumed != observed.control_consumed or needed > observed.capacity_frames or
                observed.visible_produced < observed.consumed or
                (observed.visible_produced >= observed.consumed and observed.visible_produced - observed.consumed > observed.capacity_frames) or
                observed.visible_produced < end_ordinal;
            obligation.layers[i] = .{ .layer = layer.key.id, .sound = sound.key.id, .handle = observed.handle, .consumed = observed.consumed, .onset_ordinal = onset_ordinal, .end_ordinal = end_ordinal };
        }
        if (cold) return error.TargetNotResident;
        for (layers) |layer| {
            const sound = self.tables.sounds[layer.sound];
            for (layout.spans[0..layout.span_count]) |span_value| {
                try self.includeLayerChunks(sound, layer.sound, try add(layer.source_start, span_value.first_frame), try add(layer.source_start, span_value.end_frame), phase_value.execute_frame, phase_index);
            }
        }
        // Four dedicated obligations replace four contiguous references; they
        // do not consume eight credits merely because the layout has two spans.
        if (@as(usize, self.scratch.readiness_count) + live_source_layers > max_bindings) return error.ResourceLimitExceeded;
        self.scratch.source_tail_obligation = obligation;
    }
    fn includeLayerChunks(self: *Planner, sound: s.Sound, sound_index: u32, start: u64, end: u64, deadline: u64, phase_index: usize) Error!void {
        const chunks = try bank.transition_validation.items(s.Chunk, self.tables.chunks, sound.chunks);
        var coverage = start;
        var lo: usize = 0;
        var hi: usize = chunks.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (try add(chunks[mid].first_frame, chunks[mid].frame_count) <= start) lo = mid + 1 else hi = mid;
        }
        for (chunks[lo..], lo..) |chunk, chunk_offset| {
            const chunk_end = try add(chunk.first_frame, chunk.frame_count);
            if (chunk.first_frame >= end) break;
            if (chunk.sound != sound_index or chunk.frame_count == 0 or chunk.first_frame > coverage) return error.InvalidMusicGraph;
            try self.scratch.required_chunks.include(.{ .sound = sound.key.id, .chunk_index = sound.chunks.first + @as(u32, @intCast(chunk_offset)), .first_frame = chunk.first_frame, .end_frame = chunk_end, .deadline_frame = deadline, .phase_mask = @as(u64, 1) << @as(u6, @intCast(phase_index)) }, self.profile.max_required_chunks);
            coverage = @min(end, chunk_end);
        }
        if (coverage != end) return error.InvalidMusicGraph;
    }
    fn elapsedFrame(transport: clock.Clock, frame: u64) Error!u64 {
        return transport.elapsedAt(frame);
    }
    fn renderFrame(transport: clock.Clock, elapsed: u64) Error!u64 {
        if (transport.paused) return error.ClockPaused;
        if (elapsed < transport.anchor_elapsed) return error.OutOfRange;
        return add(transport.anchor_render, elapsed - transport.anchor_elapsed);
    }
    fn cueOccurrence(transport: clock.Clock, cue: s.Cue, minimum: u64) Error!u64 {
        const elapsed = try elapsedFrame(transport, minimum);
        var candidate = cue.frame;
        const tempo = transport.map.tempo;
        if (tempo.loop_present == 1) {
            const start = try transport.map.frameAtTick(tempo.loop_start_tick);
            const end = try transport.map.frameAtTick(tempo.loop_end_tick);
            if (end <= start or cue.frame < start or cue.frame > end) return error.TransitionNotFound;
            const length = end - start;
            if (candidate < elapsed) {
                const delta = elapsed - candidate;
                candidate = try add(candidate, try mul(delta / length + @intFromBool(delta % length != 0), length));
            }
        } else if (candidate < elapsed) return error.TransitionNotFound;
        return renderFrame(transport, candidate);
    }
    fn findBoundary(self: *Planner, q: Query, path: s.TransitionPath, retry_minimum: u64) Error!struct { frame: u64, penalty: u64 } {
        const rule = self.tables.transitions[path.transition];
        const cue = self.tables.cues[path.source_exit];
        const strict_request = try add(q.request_position.accepted_control_frame, if (rule.sync == .immediate) 0 else 1);
        const lead_origin = if (self.require_actual_pcm) q.request_position.accepted_control_frame else q.position.accepted_control_frame;
        const first_minimum = @max(strict_request, q.position.accepted_control_frame, try add(lead_origin, cue.min_lead_frames), q.frontier.earliest_submit_frame);
        const minimum = @max(first_minimum, retry_minimum);
        if (rule.sync == .immediate and path.handoff == .hard_cut) return .{ .frame = first_minimum, .penalty = path.sync_penalty };
        if (rule.sync == .segment_end) {
            const tempo = q.source_clock.map.tempo;
            const now = try q.source_clock.elapsedAt(@max(q.request_position.accepted_control_frame, q.source_clock.anchor_render));
            var end = tempo.total_frames;
            if (tempo.loop_present == 1) {
                const loop_start = try q.source_clock.map.frameAtTick(tempo.loop_start_tick);
                const loop_end = try q.source_clock.map.frameAtTick(tempo.loop_end_tick);
                if (loop_end <= loop_start or cue.frame != loop_end) return error.TransitionNotFound;
                const epoch: u64 = if (now < loop_start) 0 else (now - loop_start) / (loop_end - loop_start);
                end = try add(loop_end, try mul(epoch, loop_end - loop_start));
            } else if (cue.frame != end) return error.TransitionNotFound;
            const frame = try renderFrame(q.source_clock, end);
            if (frame < minimum) return error.TransitionNotFound;
            return .{ .frame = frame, .penalty = path.sync_penalty };
        }
        const frame = try cueOccurrence(q.source_clock, cue, minimum);
        var penalty: u64 = path.sync_penalty;
        switch (rule.sync) {
            .next_beat, .next_bar => {
                const kind: clock.BoundaryKind = if (rule.sync == .next_beat) .beat else .bar;
                const first = try q.source_clock.strictNext(kind, q.request_position.accepted_control_frame, .{ .earliest_submit_frame = first_minimum });
                const own = try q.source_clock.strictNext(kind, frame - 1, .{ .earliest_submit_frame = frame });
                if (own.frame != frame) return error.TransitionNotFound;
                if (frame != first.frame) {
                    if (rule.fallback != .next_boundary) return error.TransitionNotFound;
                    penalty = try add(path.sync_penalty, 65536);
                }
            },
            .immediate => if (frame != first_minimum) return error.TransitionNotFound,
            .next_cue, .authored_exit_cue => {},
            .segment_end => unreachable,
        }
        if (retry_minimum > first_minimum and frame > try cueOccurrence(q.source_clock, cue, first_minimum)) penalty = @max(penalty, try add(path.sync_penalty, 65536));
        return .{ .frame = frame, .penalty = penalty };
    }
    fn candidateWithDeferral(self: *Planner, q: Query, index: u32, point: anytype) Error!void {
        self.makeCandidate(q, index, point.frame, point.penalty) catch |err| {
            const path = self.tables.transition_paths[index];
            const rule = self.tables.transitions[path.transition];
            if ((err != error.TargetNotResident and err != error.TransitionNotFound) or self.retry_after == null or rule.fallback != .next_boundary or rule.sync == .segment_end or rule.sync == .immediate) return err;
            // All required windows contributed their certified ETA. One direct
            // arithmetic jump reaches the earliest occurrence satisfying every
            // deadline; there is no potentially unbounded boundary walk.
            const later = self.findBoundary(q, path, self.retry_after.?) catch return err;
            if (later.frame <= point.frame) return err;
            try self.makeCandidate(q, index, later.frame, later.penalty);
        };
    }
    pub fn planContinuation(self: *Planner, input: Query, proof: Continuation, out: *TransitionPlan, log: *PlannerTrace) Error!void {
        self.failed_candidate_paths = null;
        if (input.plan_id <= proof.previous_plan_id or input.plan_epoch <= proof.previous_plan_epoch or input.position.accepted_control_frame < proof.observed_frame or input.transport_epoch != proof.source_clock.transport_epoch) return error.InvalidState;
        var q = input;
        q.source_segment = proof.source_segment;
        q.source_group = proof.source_group;
        q.source_clock = proof.source_clock;
        try self.plan(q, out, log);
    }
    /// Final Control-side PCM proof before publication. Rebuilds the plan's
    /// mode-specific required windows from admitted tables, rejects all ETA-only
    /// coverage, and does not change issued IDs, phases, score or histories.
    /// Rolling mode certifies its real entry watermark, never future fill PCM.
    /// Render's actual TASK-002/011 gate remains authoritative after this query.
    pub fn verifyPcm(self: *Planner, input: Query, plan_value: *const TransitionPlan) Error!void {
        self.failed_candidate_paths = null;
        var q = input;
        try validateSourceTailQuery(q);
        try validateSourceTailPlan(plan_value);
        if (q.source_tail_pcm_mode != plan_value.source_tail_pcm_mode) return error.InvalidState;
        if (plan_value == self.scratch or plan_value == self.best) return error.InvalidState;
        if (plan_value.phases.count > max_phases or plan_value.required_chunks.count > max_chunks or plan_value.readiness_count > max_bindings) return error.InvalidState;
        const issued = self.issuedPlan(plan_value.plan_id, plan_value.plan_epoch) orelse return error.InvalidState;
        if (!std.mem.eql(u8, &issued.digest, &planDigest(plan_value)) or q.fill_pcm_mode != plan_value.fill_pcm_mode) return error.InvalidState;
        if (q.source_clock.paused) return error.ClockPaused;
        if (q.source_clock.transport_epoch != q.transport_epoch or q.source_clock.anchor_render != plan_value.source_anchor_render or q.source_clock.anchor_elapsed != plan_value.source_anchor_elapsed or q.source_clock.device_epoch != plan_value.source_device_epoch or q.source_clock.map.tempo.key.id != plan_value.source_tempo_id or !std.meta.eql(q.request_position, plan_value.request_position)) return error.InvalidState;
        if (plan_value.version != algorithm_version or plan_value.bank_build_id != self.bank_build_id or q.asset_generation != self.generation or plan_value.asset_generation != self.generation or plan_value.transport_epoch != q.transport_epoch) return error.StaleAssetGeneration;
        if (plan_value.plan_id != q.plan_id or plan_value.plan_epoch != q.plan_epoch or plan_value.request_id != q.intent.request_id or plan_value.request_epoch != q.intent.request_epoch or plan_value.selector_epoch != q.intent.selector_epoch or plan_value.rule_id != q.intent.rule_id or plan_value.source_segment != q.source_segment or plan_value.target_segment != q.intent.resolved_segment or plan_value.from_state != q.intent.from or plan_value.to_state != q.intent.to or plan_value.source_group != q.source_group) return error.InvalidState;
        if (q.position.accepted_control_frame < plan_value.planning_position.accepted_control_frame or trace.before(q.position, plan_value.planning_position) or trace.before(q.position, q.request_position)) return error.InvalidOrder;
        if (q.position.accepted_control_frame > plan_value.execute_frame or q.frontier.earliest_submit_frame > plan_value.execute_frame or q.request_position.accepted_control_frame > q.position.accepted_control_frame) return error.InvalidOrder;
        const source_index = try self.findSegment(q.source_segment);
        q.source_clock.map = self.maps[self.tables.segments[source_index].tempo];
        const path_index = try find(self.tables.transition_paths, plan_value.path_id);
        const path = self.tables.transition_paths[path_index];
        if (self.tables.transitions[path.transition].key.id != q.intent.rule_id or self.tables.cues[path.source_exit].segment != source_index or self.tables.segments[self.tables.cues[path.target_entry].segment].key.id != q.intent.resolved_segment) return error.InvalidMusicGraph;
        var original = q;
        original.position = plan_value.planning_position;
        original.frontier.earliest_submit_frame = plan_value.planning_frontier;
        const legal = try self.findBoundary(original, path, plan_value.execute_frame);
        if (legal.frame != plan_value.execute_frame) return error.InvalidState;
        var expected_penalty = legal.penalty;
        const rule = self.tables.transitions[path.transition];
        if (rule.sync == .next_cue) for (try bank.transition_validation.items(s.TransitionPath, self.tables.transition_paths, rule.paths)) |other| {
            if (self.tables.cues[other.source_exit].segment != source_index or self.tables.segments[self.tables.cues[other.target_entry].segment].key.id != q.intent.resolved_segment) continue;
            const first = self.findBoundary(original, other, 0) catch |err| switch (err) {
                error.TransitionNotFound, error.OutOfRange => continue,
                else => return err,
            };
            if (first.frame < plan_value.execute_frame) {
                if (rule.fallback != .next_boundary) return error.InvalidState;
                expected_penalty = try add(path.sync_penalty, 65536);
            }
        };
        if (expected_penalty != plan_value.score.sync_penalty) return error.InvalidState;
        self.require_actual_pcm = true;
        defer self.require_actual_pcm = false;
        try self.makeCandidate(q, path_index, plan_value.execute_frame, expected_penalty);
        if (!std.meta.eql(self.scratch.source_tail_obligation, plan_value.source_tail_obligation)) return error.InvalidState;
        inline for (.{ "source_exit_cue", "target_entry_cue", "fill_route", "target_start_frame", "fill_start_frame", "fill_end_frame", "fade_frames", "sync" }) |field| if (!std.meta.eql(@field(self.scratch.*, field), @field(plan_value.*, field))) return error.InvalidState;
        if (plan_value.phases.count > max_phases or plan_value.required_chunks.count > max_chunks or plan_value.readiness_count > max_bindings or plan_value.phases.count != self.scratch.phases.count or plan_value.required_chunks.count != self.scratch.required_chunks.count or plan_value.readiness_count != self.scratch.readiness_count) return error.InvalidState;
        for (plan_value.phases.slice(), self.scratch.phases.slice()) |old, rebuilt| if (!std.meta.eql(old, rebuilt)) return error.InvalidState;
        for (plan_value.required_chunks.slice(), self.scratch.required_chunks.slice()) |old, rebuilt| if (!std.meta.eql(old, rebuilt)) return error.InvalidState;
        for (plan_value.readiness[0..plan_value.readiness_count], self.scratch.readiness[0..self.scratch.readiness_count]) |old, rebuilt| if (old.sound != rebuilt.sound or old.layer != rebuilt.layer or old.segment != rebuilt.segment or old.cue != rebuilt.cue or old.occurrence != rebuilt.occurrence or old.cursor != rebuilt.cursor or old.deadline_frame != rebuilt.deadline_frame or old.required_pcm_frames != rebuilt.required_pcm_frames or old.version > rebuilt.version) return error.InvalidState;
        var score = plan_value.score;
        if (score.readiness_penalty > 1) return error.InvalidState;
        score.readiness_penalty = 0;
        if (!std.meta.eql(score, self.scratch.score)) return error.InvalidState;
    }
    fn issuedPlan(self: *Planner, id: u64, epoch: u64) ?*Issued {
        for (self.issued) |*entry| if (entry.active and entry.plan_id == id and entry.plan_epoch == epoch) return entry;
        return null;
    }
    /// Invalidates future verification only. This is not a cancellation fact,
    /// does not release streams/groups and does not lower the PlanId watermark.
    pub fn forgetPlan(self: *Planner, id: u64, epoch: u64) Error!void {
        const entry = self.issuedPlan(id, epoch) orelse return error.InvalidState;
        entry.* = .{};
    }
    pub fn retainedBytes(self: *const Planner) usize {
        return @sizeOf(Planner) + self.maps.len * @sizeOf(clock.Map) + (self.segment_ids.len + self.cue_ids.len) * @sizeOf(IdIndex) + self.candidates.len * @sizeOf(Candidate) + self.issued.len * @sizeOf(Issued) + 2 * @sizeOf(TransitionPlan);
    }
    /// Initial entry uses the same genuine required-window proof as transitions.
    /// Streaming starts require actual PCM now, never an ETA-only authorization.
    /// A cold query does not issue a plan ID or create an invented target phase.
    pub fn planStart(self: *Planner, q: Query, out: *TransitionPlan) Error!void {
        self.failed_candidate_paths = null;
        try validateSourceTailQuery(q);
        if (q.source_tail_pcm_mode != .contiguous) return error.UnsupportedCapability;
        if (q.asset_generation != self.generation) return error.StaleAssetGeneration;
        if (q.intent.rule_id != 0 or q.context == 0 or q.transport_epoch == 0 or q.plan_epoch == 0 or q.plan_id == 0 or q.plan_id <= self.last_plan_id or q.plan_id < q.plan_id_floor or q.intent.request_id == 0 or q.intent.selector_epoch == 0 or q.intent.request_epoch == 0 or out == self.scratch or out == self.best) return error.InvalidState;
        if (q.request_position.accepted_control_frame > q.position.accepted_control_frame or trace.before(q.position, q.request_position)) return error.InvalidOrder;
        const issued = for (self.issued) |*entry| {
            if (!entry.active) break entry;
        } else return error.ResourceLimitExceeded;
        const segment_index = try self.findSegment(q.intent.resolved_segment);
        const segment = self.tables.segments[segment_index];
        const state = self.tables.states[try find(self.tables.states, q.intent.to)];
        if (self.tables.selectors[state.selector].key.id != q.intent.selector) return error.UnsupportedCapability;
        var entry_index: ?u32 = null;
        for (self.tables.cues, 0..) |cue, i| {
            if (cue.segment != segment_index or (cue.kind != .entry and cue.kind != .both) or cue.frame != 0) continue;
            if (entry_index != null) return error.InvalidMusicGraph;
            entry_index = @intCast(i);
        }
        const cue_index = entry_index orelse return error.TransitionNotFound;
        const execute = @max(q.position.accepted_control_frame, q.frontier.earliest_submit_frame, try add(q.position.accepted_control_frame, self.tables.cues[cue_index].min_lead_frames));
        self.scratch.* = .{ .bank_build_id = self.bank_build_id, .fill_pcm_mode = q.fill_pcm_mode, .request_position = q.request_position, .planning_position = q.position, .planning_frontier = q.frontier.earliest_submit_frame, .source_anchor_render = q.source_clock.anchor_render, .source_anchor_elapsed = q.source_clock.anchor_elapsed, .source_device_epoch = q.source_clock.device_epoch, .source_tempo_id = self.maps[segment.tempo].tempo.key.id, .plan_id = q.plan_id, .plan_epoch = q.plan_epoch, .request_id = q.intent.request_id, .request_epoch = q.intent.request_epoch, .selector_epoch = q.intent.selector_epoch, .rule_id = 0, .from_state = q.intent.from, .to_state = q.intent.to, .source_group = null, .source_segment = segment.key.id, .target_segment = segment.key.id, .source_exit_cue = 0, .target_entry_cue = self.tables.cues[cue_index].key.id, .fill_route = null, .path_id = 0, .execute_frame = execute, .target_start_frame = execute, .asset_generation = q.asset_generation, .transport_epoch = q.transport_epoch, .sync = .immediate, .score = .{ .sync_penalty = 0, .readiness_penalty = 0, .authored_rank = 0, .audible_frame = execute, .source_cue_id = 0, .fill_route_id = 0, .target_cue_id = self.tables.cues[cue_index].key.id, .target_segment_id = segment.key.id } };
        try self.phase(q, .target_entry, segment_index, cue_index, execute, try add(execute, segment.frames), 0, 0);
        self.require_actual_pcm = true;
        defer self.require_actual_pcm = false;
        try self.requiredAssets(q);
        out.* = self.scratch.*;
        issued.* = .{ .active = true, .plan_id = q.plan_id, .plan_epoch = q.plan_epoch, .digest = planDigest(out) };
        self.last_plan_id = q.plan_id;
    }

    /// Borrowed result of the immediately preceding complete TargetNotResident
    /// search. Only Planner-admissible paths awaiting PCM return true; timing,
    /// cue and lead rejections return false. Every planning/proof entry clears
    /// validity before validation. Diagnostic trace capacity is irrelevant.
    pub fn candidateAwaitingPcm(self: *const Planner, path_index: u32) Error!bool {
        const paths = self.failed_candidate_paths orelse return error.InvalidState;
        if (path_index < paths.first or path_index - paths.first >= paths.count) return error.InvalidState;
        const candidate = self.candidates[path_index - paths.first];
        if (candidate.path != path_index) return error.InvalidState;
        return candidate.awaiting_pcm;
    }

    /// Allocation-free exhaustive bounded search. All candidates are visited;
    /// exceeding a declared capacity fails the whole query, never truncates it.
    /// Output changes only after a unique winner and all checks have succeeded.
    pub fn plan(self: *Planner, input: Query, out: *TransitionPlan, log: *PlannerTrace) Error!void {
        self.failed_candidate_paths = null;
        var q = input;
        try validateSourceTailQuery(q);
        if (out == self.scratch or out == self.best or q.source_group == @as(?u64, 0)) return error.InvalidState;
        if (self.last_plan_id == std.math.maxInt(u64)) return error.ResourceLimitExceeded;
        var free_issued: ?*Issued = null;
        for (self.issued) |*entry| if (!entry.active) {
            free_issued = entry;
            break;
        };
        if (free_issued == null) return error.ResourceLimitExceeded;
        if (q.asset_generation != self.generation) return error.StaleAssetGeneration;
        if (q.context == 0 or q.transport_epoch == 0 or q.plan_id == 0 or q.plan_epoch == 0 or q.plan_id < q.plan_id_floor or q.plan_id <= self.last_plan_id or q.intent.request_id == 0 or q.intent.request_epoch == 0 or q.intent.selector_epoch == 0) return error.InvalidState;
        if (q.request_position.accepted_control_frame > q.position.accepted_control_frame or (!trace.before(q.request_position, q.position) and !std.meta.eql(q.request_position, q.position))) return error.InvalidOrder;
        const rule_index = try find(self.tables.transitions, q.intent.rule_id);
        const rule = self.tables.transitions[rule_index];
        if (rule.from >= self.tables.states.len or rule.to >= self.tables.states.len or rule.selector >= self.tables.selectors.len or self.tables.states[rule.from].key.id != q.intent.from or self.tables.states[rule.to].key.id != q.intent.to or self.tables.selectors[rule.selector].key.id != q.intent.selector) return error.InvalidMusicGraph;
        const source_index = try self.findSegment(q.source_segment);
        _ = try self.findSegment(q.intent.resolved_segment);
        const tempo_index = self.tables.segments[source_index].tempo;
        if (tempo_index >= self.maps.len or q.source_clock.map.tempo.key.id != self.maps[tempo_index].tempo.key.id or q.source_clock.transport_epoch != q.transport_epoch) return error.InvalidState;
        // Keep the real transport anchors but use this planner's admitted map.
        q.source_clock.map = self.maps[tempo_index];
        if (q.source_clock.paused) return error.ClockPaused;
        const paths = try bank.transition_validation.items(s.TransitionPath, self.tables.transition_paths, rule.paths);
        if (paths.len == 0) return error.TransitionNotFound;
        if (paths.len > self.candidates.len) return error.ResourceLimitExceeded;
        var first_matching_frame: ?u64 = null;
        if (rule.sync == .next_cue) for (paths) |path| {
            if (self.tables.cues[path.source_exit].segment != source_index or self.tables.segments[self.tables.cues[path.target_entry].segment].key.id != q.intent.resolved_segment) continue;
            const point = self.findBoundary(q, path, 0) catch |err| switch (err) {
                error.TransitionNotFound, error.OutOfRange => continue,
                else => return err,
            };
            first_matching_frame = @min(first_matching_frame orelse std.math.maxInt(u64), point.frame);
        };
        var winner: ?usize = null;
        var saw_not_ready = false;
        for (paths, 0..) |path, i| {
            const index = rule.paths.first + @as(u32, @intCast(i));
            self.candidates[i] = .{ .path = index };
            if (self.tables.cues[path.source_exit].segment != source_index or self.tables.segments[self.tables.cues[path.target_entry].segment].key.id != q.intent.resolved_segment) {
                self.candidates[i].reason = .cue_mismatch;
                continue;
            }
            var point = self.findBoundary(q, path, 0) catch |err| switch (err) {
                error.TransitionNotFound, error.OutOfRange => {
                    self.candidates[i].reason = .cue_mismatch;
                    continue;
                },
                else => return err,
            };
            if (first_matching_frame != null and point.frame > first_matching_frame.?) {
                if (rule.fallback != .next_boundary) {
                    self.candidates[i].reason = .cue_mismatch;
                    continue;
                }
                point.penalty = try add(path.sync_penalty, 65536);
            }
            self.failure_reason = .transition_not_found;
            self.candidateWithDeferral(q, index, point) catch |err| switch (err) {
                error.TargetNotResident => {
                    saw_not_ready = true;
                    self.candidates[i].awaiting_pcm = true;
                    self.candidates[i].reason = self.failure_reason;
                    continue;
                },
                error.TransitionNotFound => {
                    self.candidates[i].reason = self.failure_reason;
                    continue;
                },
                else => return err,
            };
            self.candidates[i].score = self.scratch.score;
            if (winner) |best_index| {
                const best_score = self.candidates[best_index].score.?;
                if (scoreDifference(self.scratch.score, best_score) == 0) return error.InvalidMusicGraph;
                if (!scoreLess(self.scratch.score, best_score)) continue;
            }
            winner = i;
            self.best.* = self.scratch.*;
        }
        for (self.candidates[0..paths.len], 0..) |candidate, i| {
            const path = self.tables.transition_paths[candidate.path];
            var row: trace.PlannerRecord = .{ .context = q.context, .request_id = q.intent.request_id, .control_tick = q.request_position.control_tick, .input_order = q.request_position.input_order, .accepted_control_frame = q.request_position.accepted_control_frame, .transport_epoch = q.transport_epoch, .asset_generation = q.asset_generation, .rule_id = rule.key.id, .path_id = path.key.id, .source_segment = q.source_segment, .sync = traceSync(rule.sync), .score = candidate.score, .result = .rejected, .reason = candidate.reason };
            if (candidate.score != null) {
                if (winner != null and winner.? == i) {
                    row.result = .success;
                    row.reason = .none;
                    for (self.best.readiness[0..self.best.readiness_count]) |reference| row.readiness_snapshot_version = @max(row.readiness_snapshot_version, reference.version);
                } else {
                    row.reason = .score_lost;
                    row.score_loser_column = scoreDifference(self.best.score, candidate.score.?);
                }
            }
            log.emit(row);
        }
        if (winner == null) {
            if (saw_not_ready) {
                self.failed_candidate_paths = rule.paths;
                return error.TargetNotResident;
            }
            return error.TransitionNotFound;
        }
        out.* = self.best.*;
        free_issued.?.* = .{ .active = true, .plan_id = q.plan_id, .plan_epoch = q.plan_epoch, .digest = planDigest(out) };
        self.last_plan_id = q.plan_id;
    }
};

/// Checked counterpart of the ring's immutable ordinal mapping, used without
/// retaining a ring pointer. Storage wrap is unrelated to this musical epoch.
pub fn sourceTailCoordinate(identity: streaming.SourceIdentity, ordinal: u64) Error!SourceTailCoordinate {
    const loop = identity.loop orelse return error.InvalidState;
    if (loop.start >= loop.end or loop.end > identity.frame_count or identity.start_cursor >= loop.end or
        (identity.start_loop_epoch > 0 and identity.start_cursor < loop.start)) return error.InvalidState;
    const first_length = loop.end - identity.start_cursor;
    if (ordinal < first_length) return .{ .cursor = try add(identity.start_cursor, ordinal), .loop_epoch = identity.start_loop_epoch };
    const after = ordinal - first_length;
    const advance = try add(1, after / (loop.end - loop.start));
    return .{ .cursor = try add(loop.start, after % (loop.end - loop.start)), .loop_epoch = try add(identity.start_loop_epoch, advance) };
}
fn validateSourceTailQuery(q: Query) Error!void {
    switch (q.source_tail_pcm_mode) {
        .contiguous => if (q.live_source_tail != null) return error.InvalidState,
        .live_one_loop => if (q.live_source_tail == null or q.source_group == null) return error.InvalidState,
        _ => return error.UnsupportedCapability,
    }
}
fn validateSourceTailPlan(plan_value: *const TransitionPlan) Error!void {
    switch (plan_value.source_tail_pcm_mode) {
        .contiguous => if (plan_value.source_tail_obligation != null) return error.InvalidState,
        .live_one_loop => {
            const obligation = plan_value.source_tail_obligation orelse return error.InvalidState;
            if (obligation.version != source_tail_proof_version or obligation.count != live_source_layers) return error.InvalidState;
        },
        _ => return error.UnsupportedCapability,
    }
}

fn traceSync(sync: s.Sync) trace.TransitionSync {
    return switch (sync) {
        .immediate => .immediate,
        .next_beat => .next_beat,
        .next_bar => .next_bar,
        .next_cue => .next_matching_cue,
        .segment_end => .segment_end,
        .authored_exit_cue => .authored_exit_cue,
    };
}

// Canonical LE integrity bytes: explicit values only, never struct padding or
// unused fixed-capacity slots. This runs solely on the serialized Control owner.
fn hashValue(h: *std.crypto.hash.sha2.Sha256, value: anytype) void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .int => {
            var bytes: [@sizeOf(T)]u8 = undefined;
            std.mem.writeInt(T, &bytes, value, .little);
            h.update(&bytes);
        },
        .bool => h.update(&.{@intFromBool(value)}),
        .@"enum" => hashValue(h, @intFromEnum(value)),
        .optional => {
            hashValue(h, value != null);
            if (value) |inner| hashValue(h, inner);
        },
        .@"struct" => inline for (std.meta.fields(T)) |field| hashValue(h, @field(value, field.name)),
        .array => for (value) |item| hashValue(h, item),
        else => @compileError("planner digest requires owned scalar fields"),
    }
}
fn planDigest(value: *const TransitionPlan) [32]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    inline for (std.meta.fields(TransitionPlan)) |field| {
        if (comptime !std.mem.eql(u8, field.name, "phases") and !std.mem.eql(u8, field.name, "required_chunks") and !std.mem.eql(u8, field.name, "readiness") and !std.mem.eql(u8, field.name, "source_tail_pcm_mode") and !std.mem.eql(u8, field.name, "source_tail_obligation")) hashValue(&h, @field(value.*, field.name));
    }
    hashValue(&h, value.phases.count);
    for (value.phases.slice()) |phase_value| hashValue(&h, phase_value);
    hashValue(&h, value.required_chunks.count);
    for (value.required_chunks.slice()) |chunk| hashValue(&h, chunk);
    for (value.readiness[0..value.readiness_count]) |reference| hashValue(&h, reference);
    // Default plans append no bytes. The legacy field and collection ordering
    // above is unchanged, including the existing fill-mode scalar.
    if (value.source_tail_pcm_mode == .live_one_loop) {
        h.update("SME-plan-live-source-tail-v1");
        hashValue(&h, value.source_tail_pcm_mode);
        hashValue(&h, value.source_tail_obligation.?);
    }
    var result: [32]u8 = undefined;
    h.final(&result);
    return result;
}
