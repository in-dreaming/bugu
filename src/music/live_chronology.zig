//! Phase A: isolated, bounded Live chronology grammar. NOT semantic replay.
//! This module has no producer attachment, byte codec, engine effects or publisher.
//! Typed records must eventually be decoded from independently verified bytes.
//! Point occurrences establish identity, not completeness of semantic coverage.
//! Hashes bind identities; they neither authenticate facts nor prove PCM equality.
const std = @import("std");
const trace = @import("sme-trace");
pub const input_max_bytes: usize = 213;
pub const trace_input_max_bytes = trace.codec.maxSize(trace.Input);

/// Only the first-profile tick fanout is admitted. The bytes remain borrowed
/// from caller-owned immutable storage for the lifetime of this record.
pub fn decodeInput(bytes: []const u8) Error!trace.Input {
    if (bytes.len == 0 or bytes.len > input_max_bytes) return error.InvalidOutcome;
    var decoder: trace.codec.Decoder = .{ .bytes = bytes };
    const value = decoder.get(trace.Input) catch return error.InvalidOutcome;
    decoder.finish() catch return error.InvalidOutcome;
    switch (value.payload) {
        .request, .worker, .device, .admission, .readiness_snapshot => {},
        else => return error.Unsupported,
    }
    value.validate() catch return error.InvalidOutcome;
    return value;
}
comptime {
    if (26 + trace.codec.maxSize(trace.schema.readiness.Observation) != input_max_bytes or
        trace.codec.maxSize(trace.schema.Worker) + 26 > input_max_bytes or
        trace.codec.maxSize(trace.schema.Request) + 26 > input_max_bytes or
        trace.codec.maxSize(trace.schema.Device) + 26 > input_max_bytes or
        trace.codec.maxSize(trace.schema.Admission) + 26 > input_max_bytes) @compileError("Live Input bound changed");
}

pub const publication_enabled = false;
pub const magic = "SMELCH01";
pub const profile_id: u16 = 8;
pub const wire_version: u16 = 1;
pub const semantic_rules_version: u16 = 1;
pub const Hash = [32]u8;
pub const Role = enum(u8) { control = 0, worker = 1, render = 2, _ };
pub const Phase = enum(u8) { collect = 1, accept = 2, prepare = 3, publish = 4, _ };
pub const Site = enum(u8) {
    control_collect = 1,
    control_accept = 2,
    control_prepare = 3,
    control_publish = 4,
    worker_select = 5,
    worker_complete = 6,
    render_gate = 7,
    render_span = 8,
    control_collect_frontier = 9,
    control_accept_frontier = 10,
    control_failure = 11,
    control_final_publish = 12,
    control_snapshot = 13,
    control_input = 14,
    _,
};
pub const Outcome = enum(u8) { value = 1, empty = 2, deferred = 3, failed = 4, _ };
pub const AcceptanceOutcome = enum(u8) { accepted = 1, no_completion = 2, unstable = 3, deferred = 4, failed = 5, _ };
pub const EndOutcome = enum(u8) { returned = 1, deferred = 2, failed = 3, _ };
pub const Error = error{ Unsupported, IdentityMismatch, InvalidOrder, InvalidPoint, InvalidFrame, InvalidOutcome, Incomplete, Overflow, Poisoned, Closed };

/// Fixed first-profile source set, in canonical required-stem order. Callers must
/// bind immutable owned source bytes separately before semantic replay exists.
pub const Identity = struct {
    session: [16]u8,
    bank: Hash,
    build: Hash,
    sources: [4]Hash,
    pub fn eql(a: Identity, b: Identity) bool {
        return std.meta.eql(a, b);
    }
    fn valid(self: Identity) bool {
        if (std.mem.allEqual(u8, &self.session, 0) or std.mem.allEqual(u8, &self.bank, 0) or std.mem.allEqual(u8, &self.build, 0)) return false;
        for (self.sources) |source| if (std.mem.allEqual(u8, &source, 0)) return false;
        return true;
    }
};
pub const Header = struct {
    marker: [8]u8 = magic.*,
    profile: u16 = profile_id,
    version: u16 = wire_version,
    semantic_rules: u16 = semantic_rules_version,
    identity: Identity,
    /// Explicit caller-selected finite budgets, not qualified production limits.
    max_records: u64,
    max_operations_per_role: u64,
    max_points_per_operation: u64,
};
pub const PointId = struct { site: Site, occurrence: u64 };
pub const Observation = struct {
    id: PointId,
    outcome: Outcome,
    /// Exact current effective frame for Control observations; zero otherwise.
    effective_frame: u64,
    /// Null when no retained Input was emitted; actual orders start at zero per tick.
    input_order: ?u64 = null,
    /// Preserve the actual typed failure/defer reason, never a synthetic value.
    reason: u32 = 0,
};
/// Preserve reached reads only: odd sequence-before may short-circuit all others.
pub const Cut = struct {
    sequence_before: u64,
    sequence_after: ?u64 = null,
    frame: ?u64 = null,
    consumed: ?u64 = null,
    produced: ?u64 = null,
};
/// Exact bounded copied cause of a successful Live preparation deferral.
/// Numeric codes below follow the explicitly mapped native callback variants.
pub const AvailabilityDefer = struct {
    stage: u8, operation: u8, reason: u8,
    handle_index: u16, handle_generation: u64,
    requested_frame: ?u64, observed_frame: ?u64,
    sequence_before: ?u64, sequence_after: ?u64,
};
pub const ScheduleDefer = struct {
    ticket_context: u64, request_id: u64,
    bank_context: u64, bank_index: u32, bank_generation: u32, asset_generation: u64,
    group_index: u16, group_generation: u64, plan_id: u64,
    start_frame: u64, end_frame: u64, observed_horizon: u64, minimum_frame: u64,
};
pub const PreparationKind = enum(u8) { availability = 1, stop = 2, cold_start = 3 };
pub const PreparationDefer = struct {
    id: PointId, tick: u64, frame: u64, reason: u32,
    detail: union(PreparationKind) { availability: AvailabilityDefer, stop: ScheduleDefer, cold_start: ScheduleDefer },
};
pub const RetainedInput = struct { id: PointId, bytes: []const u8 };
pub const Acceptance = struct {
    id: PointId,
    incoming_frame: u64,
    outcome: AcceptanceOutcome,
    cut: ?Cut = null,
    input_order: ?u64 = null,
    batch: u64 = 0,
    /// Actual accepted worker identity, linked to the retained Input in capture mode.
    worker_job: u64 = 0,
    reason: u32 = 0,
};
pub const Begin = struct {
    /// Explicit first Control capture boundary; no engine tick renumbering.
    prior_tick: u64 = 0,
    /// False supports isolated order-only grammar experiments, never capture.
    retained_inputs: bool = false,
    /// Control tick is contiguous across Control operations. Other roles use 0.
    tick: u64 = 0,
    /// Previously known Control boundary, not a new Render read at begin.
    entry_frame: u64 = 0,
};
pub const End = struct {
    outcome: EndOutcome,
    /// Exact reached prefix, including failed/null/deferred points.
    points: u64,
    effective_frame: u64 = 0,
    reason: u32 = 0,
};
/// Retain the actual scheduled-frame load separately from the effective Control
/// frontier: Service's coherent cut can be ahead of scheduled-frame publication.
pub const Frontier = struct { id: PointId, raw_frame: u64, effective_frame: u64 };
pub const FailureOrigin = enum(u8) {
    collect_owner,
    accept_device,
    accept_replay,
    accept_drain,
    prepare_owner,
    prepare_failure_drain,
    prepare_success_drain,
    snapshot,
    accept_acquire,
    accept_sync,
    accept_live,
    _,
};
pub const Failure = struct { id: PointId, origin: FailureOrigin, reason: u32 };
pub const SnapshotPath = enum(u8) { ordinary, prepare_failure, _ };
pub const Snapshot = struct { id: PointId, path: SnapshotPath };
/// The unconditional owner.publishControlTickV1 defer, distinct from fallible
/// ControlRuntime.publishSnapshot. exit_phase is captured before defer changes
/// the runtime phase to publish: it does not fabricate ordinary phase progress.
pub const FinalPublish = struct { id: PointId, exit_phase: Phase, effective_frame: u64 };
pub const Payload = union(enum) {
    begin: Begin,
    phase: Phase,
    frontier: Frontier,
    observation: Observation,
    retained_input: RetainedInput,
    preparation_defer: PreparationDefer,
    acceptance: Acceptance,
    failure: Failure,
    snapshot: Snapshot,
    final_publish: FinalPublish,
    end: End,
};
/// In-memory grammar model, not a wire layout or a production queue cost.
pub const Record = struct {
    identity: Identity,
    role: Role,
    sequence: u64,
    operation: u64,
    payload: Payload,
};
pub const Terminal = struct {
    identity: Identity,
    records: u64,
    role_sequences: [3]u64,
    role_operations: [3]u64,
    /// These are reported closure facts only. Real joins require external proof.
    producer_closed: [3]bool,
    complete: bool,
};
const Lane = struct {
    sequence: u64 = 0,
    operations: u64 = 0,
    active: bool = false,
    phase: u8 = 0,
    points: u64 = 0,
    occurrences: [14]u64 = @splat(0),
    effective_frame: u64 = 0,
    last_site: u8 = 0,
    first_failure: ?Failure = null,
    returned_failure: ?u32 = null,
    snapshot_path: ?SnapshotPath = null,
    final_published: bool = false,
    acceptance_terminated: bool = false,
    retained_inputs: bool = false,
    // Validator state must survive callers reusing one Decoder.next buffer.
    pending_worker: ?struct { position: trace.schema.Position, job: u64 } = null,
    preparation_deferred: ?u32 = null,
};

/// Constant state: three role windows and thirteen site counters per window.
/// Merge order is NOT a global clock and no cross-role dependency is certified.
pub const Validator = struct {
    header: Header,
    lanes: [3]Lane = @splat(.{}),
    records: u64 = 0,
    ticks: u64 = 0,
    input_order: u64 = 0,
    last_batch: u64 = 0,
    last_control_frame: u64 = 0,
    failure: ?Error = null,
    terminal_seen: bool = false,
    capture_mode: ?bool = null,

    pub fn init(header: Header, expected: Identity) Error!Validator {
        if (!std.mem.eql(u8, &header.marker, magic) or header.profile != profile_id or header.version != wire_version or header.semantic_rules != semantic_rules_version) return error.Unsupported;
        if (!header.identity.valid() or !header.identity.eql(expected)) return error.IdentityMismatch;
        if (header.max_records == 0 or header.max_records == std.math.maxInt(u64) or header.max_operations_per_role == 0 or header.max_operations_per_role == std.math.maxInt(u64) or header.max_points_per_operation == 0 or header.max_points_per_operation == std.math.maxInt(u64)) return error.Overflow;
        return .{ .header = header };
    }
    /// Capture loss is latched independently of future record availability.
    pub fn poison(self: *Validator, why: Error) void {
        if (self.failure == null) self.failure = why;
    }
    pub fn push(self: *Validator, record: Record) Error!void {
        if (self.failure != null) return error.Poisoned;
        if (self.terminal_seen) {
            self.poison(error.Closed);
            return error.Closed;
        }
        // Transactional grammar update: rejected records cannot advance a frame.
        var next = self.*;
        next.apply(record) catch |err| {
            self.poison(err);
            return err;
        };
        self.* = next;
    }
    fn increment(value: u64) Error!u64 {
        return std.math.add(u64, value, 1) catch error.Overflow;
    }
    fn input(self: *Validator, order: u64) Error!void {
        if (order != self.input_order) return error.InvalidOrder;
        self.input_order = try increment(order);
    }
    fn point(self: *Validator, lane: *Lane, role: Role, id: PointId) Error!void {
        const site = @intFromEnum(id.site);
        if (site < 1 or site > 14) return error.InvalidPoint;
        switch (role) {
            .control => if (site != lane.phase and !(site == 9 and lane.phase == 1) and !(site == 10 and lane.phase == 2) and !(site >= 11 and site <= 12 and lane.phase >= 1 and lane.phase <= 4) and !(site == 13 and lane.phase == 4) and !(site == 14 and lane.phase >= 1 and lane.phase <= 3)) return error.InvalidPoint,
            .worker => if (site < 5 or site > 6 or (site == 6 and lane.occurrences[4] == 0)) return error.InvalidPoint,
            .render => if (site < 7 or site > 8 or (site == 8 and lane.occurrences[6] == 0)) return error.InvalidPoint,
            _ => return error.Unsupported,
        }
        if (role == .worker and site < lane.last_site) return error.InvalidOrder;
        if (id.occurrence != try increment(lane.occurrences[site - 1])) return error.InvalidOrder;
        if (lane.points >= self.header.max_points_per_operation) return error.Overflow;
        lane.points = try increment(lane.points);
        lane.occurrences[site - 1] = id.occurrence;
        lane.last_site = site;
    }
    fn knownFailureReason(reason: u32) bool { return reason >= 1 and reason <= 30; }
    fn validateAvailabilityDefer(value: AvailabilityDefer, frame: u64) Error!void {
        if (value.stage < 1 or value.stage > 5 or value.operation < 1 or value.operation > 5 or value.reason < 1 or value.reason > 3 or value.handle_generation == 0) return error.InvalidOutcome;
        const readiness = value.stage == 2 or value.stage == 4;
        if (readiness != (value.operation >= 3)) return error.InvalidOutcome;
        if (value.requested_frame) |requested| if (requested != frame) return error.InvalidFrame;
        if (value.operation >= 4) {
            if (value.reason != 2 or value.requested_frame == null or value.observed_frame == null or value.requested_frame.? == value.observed_frame.? or value.sequence_before != null or value.sequence_after != null) return error.InvalidOutcome;
            return;
        }
        if (value.operation == 2 and value.requested_frame != null) return error.InvalidOutcome;
        if (value.operation == 3 and value.requested_frame == null) return error.InvalidOutcome;
        const before = value.sequence_before orelse return error.InvalidOutcome;
        switch (value.reason) {
            1 => if (before & 1 == 0 or value.observed_frame != null or value.sequence_after != null) return error.InvalidOutcome,
            2 => {
                if (value.operation == 2 or before & 1 != 0 or value.requested_frame == null or value.observed_frame == null or value.requested_frame.? == value.observed_frame.? or value.sequence_after != null) return error.InvalidOutcome;
            },
            3 => {
                const after = value.sequence_after orelse return error.InvalidOutcome;
                const observed = value.observed_frame orelse return error.InvalidOutcome;
                if (before & 1 != 0 or after == before) return error.InvalidOutcome;
                if (value.requested_frame) |requested| if (requested != observed) return error.InvalidOutcome;
            },
            else => unreachable,
        }
    }
    fn validateCutPrefix(cut: Cut) Error!void {
        if (cut.sequence_before & 1 != 0) {
            if (cut.frame != null or cut.consumed != null or cut.produced != null or cut.sequence_after != null) return error.InvalidOutcome;
            return;
        }
        // The real helper records frame before its frame-mismatch return, then
        // stores consumed/produced/after together following all three reads.
        if (cut.frame == null) return error.InvalidOutcome;
        const tail = cut.consumed != null or cut.produced != null or cut.sequence_after != null;
        if (tail and (cut.frame == null or cut.consumed == null or cut.produced == null or cut.sequence_after == null)) return error.InvalidOutcome;
    }
    fn apply(self: *Validator, record: Record) Error!void {
        if (!record.identity.eql(self.header.identity)) return error.IdentityMismatch;
        const role = @intFromEnum(record.role);
        if (role >= self.lanes.len) return error.Unsupported;
        if (self.records >= self.header.max_records) return error.Overflow;
        const lane = &self.lanes[role];
        if (record.sequence != try increment(lane.sequence) or record.operation != try increment(lane.operations)) return error.InvalidOrder;
        if (lane.final_published and record.payload != .end and record.payload != .begin) return error.InvalidOrder;
        if (lane.first_failure != null) switch (record.payload) {
            .failure, .phase, .snapshot, .final_publish, .end, .begin => {},
            else => return error.InvalidOrder,
        };
        if (lane.pending_worker != null and record.payload != .acceptance) return error.InvalidOrder;
        switch (record.payload) {
            .begin => |begin| {
                if (lane.active) return error.InvalidOrder;
                if (lane.operations >= self.header.max_operations_per_role) return error.Overflow;
                const sequence = lane.sequence;
                const operations = lane.operations;
                lane.* = .{ .sequence = sequence, .operations = operations, .active = true };
                if (record.role == .control) {
                    if (lane.operations == 0) {
                        if (begin.tick != try increment(begin.prior_tick)) return error.InvalidOrder;
                        self.capture_mode = begin.retained_inputs;
                    } else if (begin.prior_tick != 0 or begin.tick != try increment(self.ticks) or begin.retained_inputs != self.capture_mode.?) return error.InvalidOrder;
                    lane.retained_inputs = begin.retained_inputs;
                    if (begin.entry_frame < self.last_control_frame or (lane.operations != 0 and begin.entry_frame != self.last_control_frame)) return error.InvalidFrame;
                    self.ticks = begin.tick;
                    self.input_order = 0;
                    lane.effective_frame = begin.entry_frame;
                } else if (begin.tick != 0 or begin.entry_frame != 0 or begin.prior_tick != 0 or begin.retained_inputs) return error.InvalidFrame;
            },
            .phase => |phase| {
                if (!lane.active or record.role != .control) return error.InvalidOrder;
                const value = @intFromEnum(phase);
                if (value < 1 or value > 4) return error.Unsupported;
                if (value != lane.phase + 1) return error.InvalidOrder;
                if (lane.first_failure) |first| {
                    if (first.origin != .prepare_owner or lane.phase != 3 or value != 4 or lane.occurrences[10] != 1) return error.InvalidOrder;
                } else if (lane.phase > 0 and lane.occurrences[lane.phase - 1] == 0) return error.Incomplete;
                if ((lane.phase == 1 and lane.occurrences[8] != 1) or (lane.phase == 2 and lane.occurrences[9] != 1)) return error.Incomplete;
                lane.phase = value;
            },
            .frontier => |frontier| {
                if (!lane.active or record.role != .control) return error.InvalidPoint;
                const site = @intFromEnum(frontier.id.site);
                if (site != 9 and site != 10) return error.InvalidPoint;
                if (frontier.id.occurrence != 1 or lane.occurrences[site - 1] != 0) return error.InvalidOrder;
                try self.point(lane, record.role, frontier.id);
                if (frontier.effective_frame != @max(lane.effective_frame, frontier.raw_frame)) return error.InvalidFrame;
                // Preserve the real raw load; a lagging scheduled-frame store
                // cannot erase an already accepted coherent Service frontier.
                lane.effective_frame = frontier.effective_frame;
            },
            .observation => |observation| {
                if (!lane.active or observation.id.site == .control_accept or @intFromEnum(observation.id.site) >= 9) return error.InvalidPoint;
                if (lane.retained_inputs and record.role == .control) {
                    if (observation.id.occurrence != 1 or observation.outcome != .value or observation.input_order != null or observation.reason != 0) return error.InvalidOutcome;
                    if (observation.id.site == .control_collect and lane.occurrences[8] != 1) return error.Incomplete;
                    if (observation.id.site == .control_prepare and lane.preparation_deferred != null) return error.InvalidOrder;
                    if (observation.id.site == .control_publish and lane.snapshot_path != .ordinary) return error.InvalidOrder;
                }
                try self.point(lane, record.role, observation.id);
                if (observation.effective_frame != lane.effective_frame) return error.InvalidFrame;
                switch (observation.outcome) {
                    .value, .empty => if (observation.reason != 0) return error.InvalidOutcome,
                    .deferred, .failed => if (observation.reason == 0) return error.InvalidOutcome,
                    _ => return error.Unsupported,
                }
                if (observation.input_order) |order| {
                    if (lane.retained_inputs or record.role != .control or observation.outcome != .value) return error.InvalidOutcome;
                    try self.input(order);
                }
            },
            .preparation_defer => |deferred| {
                if (!lane.active or record.role != .control or !lane.retained_inputs or lane.phase != 3 or deferred.id.site != .control_prepare or lane.preparation_deferred != null or deferred.reason == 0) return error.InvalidOutcome;
                if (deferred.tick != self.ticks or deferred.frame != lane.effective_frame) return error.InvalidFrame;
                if (lane.occurrences[2] != 0) return error.InvalidOrder;
                switch (deferred.detail) {
                    .availability => |value| {
                        if (deferred.reason != 100) return error.InvalidOutcome;
                        try validateAvailabilityDefer(value, deferred.frame);
                    },
                    .stop, .cold_start => |value| {
                        const expected: u32 = if (deferred.detail == .stop) 101 else 102;
                        if (deferred.reason != expected or value.ticket_context == 0 or value.request_id == 0 or value.bank_context != value.ticket_context or value.bank_generation == 0 or value.asset_generation == 0 or value.group_generation == 0 or value.plan_id == 0 or value.end_frame <= value.start_frame or value.start_frame >= value.minimum_frame or value.minimum_frame < value.observed_horizon) return error.InvalidOutcome;
                    },
                }
                try self.point(lane, record.role, deferred.id);
                lane.preparation_deferred = deferred.reason;
            },
            .retained_input => |retained| {
                if (!lane.active or record.role != .control or !lane.retained_inputs or retained.id.site != .control_input) return error.InvalidPoint;
                if ((lane.phase == 1 and lane.occurrences[8] != 1) or (lane.phase == 2 and lane.occurrences[9] != 1)) return error.Incomplete;
                const value = try decodeInput(retained.bytes);
                if (value.position.control_tick != self.ticks) return error.InvalidOrder;
                if (value.payload == .worker) {
                    if (lane.phase != 2 or lane.acceptance_terminated or value.position.accepted_control_frame < lane.effective_frame) return error.InvalidFrame;
                    lane.pending_worker = .{ .position = value.position, .job = value.payload.worker.job };
                } else if (value.position.accepted_control_frame != lane.effective_frame) return error.InvalidFrame;
                try self.point(lane, record.role, retained.id);
                try self.input(value.position.input_order);
            },
            .acceptance => |acceptance| {
                if (!lane.active or record.role != .control or lane.phase != 2 or acceptance.id.site != .control_accept) return error.InvalidPoint;
                if (lane.occurrences[9] != 1) return error.Incomplete;
                if (lane.acceptance_terminated) return error.InvalidOrder;
                try self.point(lane, record.role, acceptance.id);
                if (acceptance.cut) |cut| try validateCutPrefix(cut);
                if (lane.retained_inputs) switch (acceptance.outcome) {
                    .unstable => {
                        const cut = acceptance.cut orelse return error.InvalidOutcome;
                        if (acceptance.reason != (if (cut.sequence_before & 1 != 0) @as(u32, 200) else @as(u32, 201))) return error.InvalidOutcome;
                    },
                    .deferred => {
                        if (acceptance.reason != 202 and acceptance.reason != 203) return error.InvalidOutcome;
                        const cut = acceptance.cut orelse return error.InvalidOutcome;
                        const after = cut.sequence_after orelse return error.InvalidOutcome;
                        const frame = cut.frame orelse return error.InvalidOutcome;
                        const consumed = cut.consumed orelse return error.InvalidOutcome;
                        const produced = cut.produced orelse return error.InvalidOutcome;
                        if (cut.sequence_before & 1 != 0 or after != cut.sequence_before or consumed > produced or frame < lane.effective_frame) return error.InvalidOutcome;
                    },
                    .failed => if (!knownFailureReason(acceptance.reason)) return error.InvalidOutcome,
                    else => {},
                };
                if (acceptance.incoming_frame != lane.effective_frame) return error.InvalidFrame;
                switch (acceptance.outcome) {
                    .accepted => {
                        const cut = acceptance.cut orelse return error.InvalidOutcome;
                        const after = cut.sequence_after orelse return error.InvalidOutcome;
                        const frame = cut.frame orelse return error.InvalidOutcome;
                        const consumed = cut.consumed orelse return error.InvalidOutcome;
                        const produced = cut.produced orelse return error.InvalidOutcome;
                        if (cut.sequence_before & 1 != 0 or cut.sequence_before != after or consumed > produced) return error.InvalidOutcome;
                        if (frame < lane.effective_frame) return error.InvalidFrame;
                        if (acceptance.reason != 0 or acceptance.batch == 0 or acceptance.batch <= self.last_batch) return error.InvalidOutcome;
                        const input_order = acceptance.input_order orelse return error.InvalidOutcome;
                        if (lane.retained_inputs) {
                            const pending = lane.pending_worker orelse return error.Incomplete;
                            if (pending.position.input_order != input_order or pending.position.accepted_control_frame != frame or pending.job != acceptance.worker_job) return error.InvalidOutcome;
                            lane.pending_worker = null;
                        } else {
                            if (acceptance.worker_job != 0) return error.InvalidOutcome;
                            try self.input(input_order);
                        }
                        self.last_batch = acceptance.batch;
                        lane.effective_frame = frame;
                    },
                    .no_completion => if (acceptance.cut != null or acceptance.reason != 0) return error.InvalidOutcome,
                    .unstable => {
                        const cut = acceptance.cut orelse return error.InvalidOutcome;
                        if (cut.sequence_before & 1 == 0) {
                            const after = cut.sequence_after orelse return error.InvalidOutcome;
                            if (cut.sequence_before == after or cut.frame == null or cut.consumed == null or cut.produced == null) return error.InvalidOutcome;
                            if (cut.consumed.? > cut.produced.?) return error.InvalidOutcome;
                        }
                        if (acceptance.reason == 0) return error.InvalidOutcome;
                    },
                    .deferred, .failed => if (acceptance.reason == 0) return error.InvalidOutcome,
                    _ => return error.Unsupported,
                }
                if (acceptance.outcome != .accepted) {
                    if (acceptance.input_order != null or acceptance.batch != 0 or acceptance.worker_job != 0 or lane.pending_worker != null) return error.InvalidOutcome;
                    lane.acceptance_terminated = true;
                }
            },
            .failure => |failure| {
                if (!lane.active or record.role != .control or failure.id.site != .control_failure or failure.reason == 0 or lane.snapshot_path != null) return error.InvalidOutcome;
                if (lane.retained_inputs and !knownFailureReason(failure.reason)) return error.InvalidOutcome;
                const phase: u8 = switch (failure.origin) {
                    .collect_owner => 1,
                    .accept_device, .accept_replay, .accept_drain, .accept_acquire, .accept_sync, .accept_live => 2,
                    .prepare_owner, .prepare_failure_drain, .prepare_success_drain => 3,
                    .snapshot => 4,
                    _ => return error.Unsupported,
                };
                if (phase != lane.phase) return error.InvalidOrder;
                if (phase == 2 and failure.origin != .accept_acquire and lane.occurrences[9] != 1) return error.Incomplete;
                if (failure.origin == .accept_acquire and lane.occurrences[9] != 0) return error.InvalidOrder;
                // Device acceptance precedes Service scanning. The legacy replay
                // branch is exclusive with actual Service attempts; retaining its
                // failure origin here does not admit it to the new live profile.
                if ((failure.origin == .accept_device or failure.origin == .accept_replay or failure.origin == .accept_sync) and lane.occurrences[1] != 0) return error.InvalidOrder;
                if (failure.origin == .prepare_success_drain and lane.occurrences[2] == 0) return error.Incomplete;
                if (lane.first_failure) |first| {
                    if (first.origin != .prepare_owner or lane.occurrences[10] != 1 or
                        (failure.origin != .prepare_failure_drain and failure.origin != .snapshot)) return error.InvalidOrder;
                } else if (failure.origin == .prepare_failure_drain) return error.InvalidOrder;
                try self.point(lane, record.role, failure.id);
                if (lane.first_failure == null) lane.first_failure = failure;
                // A failing recovery drain or snapshot overrides the returned
                // error, while the original prepare failure stays retained.
                lane.returned_failure = failure.reason;
            },
            .snapshot => |snapshot| {
                if (!lane.active or record.role != .control or snapshot.id.site != .control_snapshot or lane.snapshot_path != null) return error.InvalidOrder;
                switch (snapshot.path) {
                    .ordinary => if (lane.first_failure != null) return error.InvalidOutcome,
                    .prepare_failure => {
                        const first = lane.first_failure orelse return error.InvalidOutcome;
                        if (first.origin != .prepare_owner or lane.occurrences[10] != 1) return error.InvalidOutcome;
                    },
                    _ => return error.Unsupported,
                }
                try self.point(lane, record.role, snapshot.id);
                lane.snapshot_path = snapshot.path;
            },
            .final_publish => |publication| {
                if (!lane.active or record.role != .control or publication.id.site != .control_final_publish or lane.final_published) return error.InvalidOrder;
                if (@intFromEnum(publication.exit_phase) != lane.phase) return error.InvalidOrder;
                if (publication.effective_frame != lane.effective_frame) return error.InvalidFrame;
                // Once prepare failed, reaching publish requires either the
                // successful recovery snapshot or its own captured failure.
                if (lane.first_failure) |first| {
                    if (first.origin == .prepare_owner and lane.phase == 4 and lane.snapshot_path == null and lane.occurrences[10] != 2) return error.Incomplete;
                    if (first.origin == .prepare_owner and lane.phase == 3 and lane.occurrences[10] != 2) return error.Incomplete;
                } else if (lane.phase != 4 or lane.snapshot_path != .ordinary) return error.Incomplete;
                try self.point(lane, record.role, publication.id);
                lane.final_published = true;
            },
            .end => |end| {
                if (!lane.active or end.points != lane.points) return error.Incomplete;
                if (end.effective_frame != lane.effective_frame) return error.InvalidFrame;
                if (record.role == .control) {
                    if (!lane.final_published) return error.Incomplete;
                    if (end.outcome == .failed) {
                        if (lane.returned_failure == null or end.reason != lane.returned_failure.?) return error.InvalidOutcome;
                    } else if (lane.first_failure != null or lane.snapshot_path != .ordinary or lane.phase != 4) return error.InvalidOutcome;
                }
                if (lane.retained_inputs and record.role == .control and end.outcome != .failed) {
                    if (lane.occurrences[3] != 1) return error.Incomplete;
                    if ((end.outcome == .deferred) != (lane.preparation_deferred != null)) return error.InvalidOutcome;
                    if (lane.preparation_deferred) |reason| if (end.reason != reason) return error.InvalidOutcome;
                }
                switch (end.outcome) {
                    .returned => {
                        if (end.reason != 0) return error.InvalidOutcome;
                        switch (record.role) {
                            .control => if (lane.phase != 4 or lane.occurrences[3] == 0) return error.Incomplete,
                            .worker => if (lane.occurrences[4] == 0 or lane.occurrences[5] == 0) return error.Incomplete,
                            .render => if (lane.occurrences[6] == 0 or lane.occurrences[7] == 0) return error.Incomplete,
                            _ => unreachable,
                        }
                    },
                    .deferred, .failed => if (end.reason == 0) return error.InvalidOutcome,
                    _ => return error.Unsupported,
                }
                lane.active = false;
                lane.operations = try increment(lane.operations);
                if (record.role == .control) self.last_control_frame = lane.effective_frame;
            },
        }
        lane.sequence = record.sequence;
        self.records = try increment(self.records);
    }
    pub fn finish(self: *Validator, terminal: Terminal) Error!void {
        if (self.failure != null) return error.Poisoned;
        self.checkTerminal(terminal) catch |err| {
            self.poison(err);
            return err;
        };
        self.terminal_seen = true;
    }
    fn checkTerminal(self: *Validator, terminal: Terminal) Error!void {
        if (self.terminal_seen) return error.Closed;
        if (!terminal.identity.eql(self.header.identity)) return error.IdentityMismatch;
        if (!terminal.complete or terminal.records != self.records) return error.Incomplete;
        for (self.lanes, 0..) |lane, i| {
            if (lane.active or !terminal.producer_closed[i] or terminal.role_sequences[i] != lane.sequence or terminal.role_operations[i] != lane.operations) return error.Incomplete;
        }
    }
    /// EOF without the exact terminal is always incomplete, even with no active
    /// operation. Successful EOF means grammar completeness only.
    pub fn eof(self: *Validator) Error!void {
        if (self.failure != null) return error.Poisoned;
        if (!self.terminal_seen) {
            self.poison(error.Incomplete);
            return error.Incomplete;
        }
    }
};

fn testIdentity() Identity {
    return .{ .session = @splat(1), .bank = @splat(2), .build = @splat(3), .sources = .{ @splat(4), @splat(5), @splat(6), @splat(7) } };
}
fn testValidator() !Validator {
    return Validator.init(.{ .identity = testIdentity(), .max_records = 100, .max_operations_per_role = 10, .max_points_per_operation = 20 }, testIdentity());
}
fn feed(v: *Validator, role: Role, payload: Payload) !void {
    const lane = v.lanes[@intFromEnum(role)];
    try v.push(.{ .identity = testIdentity(), .role = role, .sequence = lane.sequence + 1, .operation = lane.operations + 1, .payload = payload });
}
fn startAccept(v: *Validator) !void {
    try feed(v, .control, .{ .begin = .{ .tick = 1, .entry_frame = 10 } });
    try feed(v, .control, .{ .phase = .collect });
    try feed(v, .control, .{ .frontier = .{ .id = .{ .site = .control_collect_frontier, .occurrence = 1 }, .raw_frame = 10, .effective_frame = 10 } });
    try feed(v, .control, .{ .observation = .{ .id = .{ .site = .control_collect, .occurrence = 1 }, .outcome = .empty, .effective_frame = 10 } });
    try feed(v, .control, .{ .phase = .accept });
    try feed(v, .control, .{ .frontier = .{ .id = .{ .site = .control_accept_frontier, .occurrence = 1 }, .raw_frame = 10, .effective_frame = 10 } });
}
fn accepted(occurrence: u64, incoming: u64, frame: u64) Payload {
    return .{ .acceptance = .{ .id = .{ .site = .control_accept, .occurrence = occurrence }, .incoming_frame = incoming, .outcome = .accepted, .cut = .{ .sequence_before = 2, .sequence_after = 2, .frame = frame, .consumed = 4, .produced = 8 }, .input_order = occurrence - 1, .batch = occurrence } };
}
fn terminalFor(v: Validator) Terminal {
    var t: Terminal = .{ .identity = testIdentity(), .records = v.records, .role_sequences = @splat(0), .role_operations = @splat(0), .producer_closed = @splat(true), .complete = true };
    for (v.lanes, 0..) |lane, i| {
        t.role_sequences[i] = lane.sequence;
        t.role_operations[i] = lane.operations;
    }
    return t;
}

test "same tick multiple coherent frames then no completion and prepare publish" {
    var v = try testValidator();
    try startAccept(&v);
    try feed(&v, .control, accepted(1, 10, 20));
    // Independent Worker can progress inside the Control operation.
    try feed(&v, .worker, .{ .begin = .{} });
    try feed(&v, .worker, .{ .observation = .{ .id = .{ .site = .worker_select, .occurrence = 1 }, .outcome = .empty, .effective_frame = 0 } });
    try feed(&v, .worker, .{ .end = .{ .outcome = .deferred, .points = 1, .reason = 1 } });
    try feed(&v, .control, accepted(2, 20, 30));
    try feed(&v, .control, .{ .acceptance = .{ .id = .{ .site = .control_accept, .occurrence = 3 }, .incoming_frame = 30, .outcome = .no_completion } });
    try std.testing.expectEqual(@as(u64, 30), v.lanes[0].effective_frame);
    try feed(&v, .control, .{ .phase = .prepare });
    try feed(&v, .control, .{ .observation = .{ .id = .{ .site = .control_prepare, .occurrence = 1 }, .outcome = .empty, .effective_frame = 30 } });
    try feed(&v, .control, .{ .phase = .publish });
    try feed(&v, .control, .{ .observation = .{ .id = .{ .site = .control_publish, .occurrence = 1 }, .outcome = .value, .effective_frame = 30 } });
    try testPublish(&v, .ordinary);
    try feed(&v, .control, .{ .end = .{ .outcome = .returned, .points = 10, .effective_frame = 30 } });
    try v.finish(terminalFor(v));
    try v.eof();
    try std.testing.expect(!publication_enabled);
}

test "missing duplicate and reordered role records permanently poison" {
    for ([_]u64{ 0, 2 }) |sequence| {
        var v = try testValidator();
        try std.testing.expectError(error.InvalidOrder, v.push(.{ .identity = testIdentity(), .role = .control, .sequence = sequence, .operation = 1, .payload = .{ .begin = .{ .tick = 1 } } }));
        try std.testing.expectError(error.Poisoned, v.finish(terminalFor(v)));
    }
    var v = try testValidator();
    try startAccept(&v);
    try feed(&v, .control, accepted(1, 10, 20));
    try std.testing.expectError(error.InvalidOrder, feed(&v, .control, accepted(1, 20, 30)));
}

test "phase omission, wrong site and skipped occurrence rejected" {
    var a = try testValidator();
    try feed(&a, .control, .{ .begin = .{ .tick = 1 } });
    try std.testing.expectError(error.InvalidOrder, feed(&a, .control, .{ .phase = .accept }));
    var b = try testValidator();
    try startAccept(&b);
    try std.testing.expectError(error.InvalidOrder, feed(&b, .control, accepted(2, 10, 20)));
    var c = try testValidator();
    try startAccept(&c);
    try std.testing.expectError(error.InvalidPoint, feed(&c, .control, .{ .observation = .{ .id = .{ .site = .worker_select, .occurrence = 1 }, .outcome = .empty, .effective_frame = 10 } }));
}

test "old frame and forged coherence never advance effective frame" {
    var a = try testValidator();
    try startAccept(&a);
    try std.testing.expectError(error.InvalidFrame, feed(&a, .control, accepted(1, 10, 9)));
    try std.testing.expectEqual(@as(u64, 10), a.lanes[0].effective_frame);
    var b = try testValidator();
    try startAccept(&b);
    var p = accepted(1, 10, 20);
    p.acceptance.cut.?.sequence_after = 4;
    try std.testing.expectError(error.InvalidOutcome, feed(&b, .control, p));
    try std.testing.expectEqual(@as(u64, 10), b.lanes[0].effective_frame);
}

test "unknown protocol, role, site and changed immutable identity rejected" {
    const valid = (try testValidator()).header;
    var h = valid;
    h.version = 2;
    try std.testing.expectError(error.Unsupported, Validator.init(h, testIdentity()));
    h = valid;
    h.profile = 7;
    try std.testing.expectError(error.Unsupported, Validator.init(h, testIdentity()));
    h = valid;
    h.marker[0] = 0;
    try std.testing.expectError(error.Unsupported, Validator.init(h, testIdentity()));
    var v = try testValidator();
    var id = testIdentity();
    id.sources[2][0] = 99;
    try std.testing.expectError(error.IdentityMismatch, v.push(.{ .identity = id, .role = .control, .sequence = 1, .operation = 1, .payload = .{ .begin = .{ .tick = 1 } } }));
    v = try testValidator();
    try std.testing.expectError(error.Unsupported, v.push(.{ .identity = testIdentity(), .role = @enumFromInt(99), .sequence = 1, .operation = 1, .payload = .{ .begin = .{} } }));
    v = try testValidator();
    try feed(&v, .worker, .{ .begin = .{} });
    try std.testing.expectError(error.InvalidPoint, feed(&v, .worker, .{ .observation = .{ .id = .{ .site = @enumFromInt(99), .occurrence = 1 }, .outcome = .empty, .effective_frame = 0 } }));
}

test "missing terminal, active operation, false counts and unclosed producer reject" {
    var a = try testValidator();
    try std.testing.expectError(error.Incomplete, a.eof());
    var b = try testValidator();
    try feed(&b, .worker, .{ .begin = .{} });
    try std.testing.expectError(error.Incomplete, b.finish(terminalFor(b)));
    var c = try testValidator();
    var t = terminalFor(c);
    t.records = 1;
    try std.testing.expectError(error.Incomplete, c.finish(t));
    var d = try testValidator();
    t = terminalFor(d);
    t.producer_closed[2] = false;
    try std.testing.expectError(error.Incomplete, d.finish(t));
}

test "budget loss and integer exhaustion cannot regain completeness" {
    var a = try testValidator();
    a.header.max_records = 1;
    try feed(&a, .worker, .{ .begin = .{} });
    try std.testing.expectError(error.Overflow, feed(&a, .worker, .{ .end = .{ .outcome = .failed, .points = 0, .reason = 1 } }));
    try std.testing.expectError(error.Poisoned, a.finish(terminalFor(a)));
    var b = try testValidator();
    b.lanes[0].sequence = std.math.maxInt(u64);
    try std.testing.expectError(error.Overflow, b.push(.{ .identity = testIdentity(), .role = .control, .sequence = 0, .operation = 1, .payload = .{ .begin = .{ .tick = 1 } } }));
    var c = try testValidator();
    c.poison(error.Overflow);
    c.poison(error.Incomplete);
    try std.testing.expectEqual(error.Overflow, c.failure.?);
    try std.testing.expectError(error.Poisoned, c.finish(terminalFor(c)));
}

test "publish cannot reuse tick entry after successful acceptance" {
    var v = try testValidator();
    try startAccept(&v);
    try feed(&v, .control, accepted(1, 10, 20));
    try feed(&v, .control, .{ .phase = .prepare });
    try feed(&v, .control, .{ .observation = .{ .id = .{ .site = .control_prepare, .occurrence = 1 }, .outcome = .empty, .effective_frame = 20 } });
    try feed(&v, .control, .{ .phase = .publish });
    try std.testing.expectError(error.InvalidFrame, feed(&v, .control, .{ .observation = .{ .id = .{ .site = .control_publish, .occurrence = 1 }, .outcome = .value, .effective_frame = 10 } }));
}

test "operation gaps, omitted phase evidence and forged input order reject" {
    var a = try testValidator();
    try std.testing.expectError(error.InvalidOrder, a.push(.{ .identity = testIdentity(), .role = .worker, .sequence = 1, .operation = 2, .payload = .{ .begin = .{} } }));
    var b = try testValidator();
    try feed(&b, .control, .{ .begin = .{ .tick = 1 } });
    try feed(&b, .control, .{ .phase = .collect });
    try std.testing.expectError(error.Incomplete, feed(&b, .control, .{ .phase = .accept }));
    var c = try testValidator();
    try startAccept(&c);
    var p = accepted(1, 10, 20);
    p.acceptance.input_order = 2;
    try std.testing.expectError(error.InvalidOrder, feed(&c, .control, p));
    try std.testing.expectEqual(@as(u64, 10), c.lanes[0].effective_frame);
}

test "explicit failed and empty role operations survive exact terminal accounting" {
    var v = try testValidator();
    try feed(&v, .worker, .{ .begin = .{} });
    try feed(&v, .worker, .{ .end = .{ .outcome = .failed, .points = 0, .reason = 17 } });
    try feed(&v, .worker, .{ .begin = .{} });
    try feed(&v, .worker, .{ .observation = .{ .id = .{ .site = .worker_select, .occurrence = 1 }, .outcome = .empty, .effective_frame = 0 } });
    try feed(&v, .worker, .{ .observation = .{ .id = .{ .site = .worker_complete, .occurrence = 1 }, .outcome = .empty, .effective_frame = 0 } });
    try feed(&v, .worker, .{ .end = .{ .outcome = .returned, .points = 2 } });
    try feed(&v, .render, .{ .begin = .{} });
    try feed(&v, .render, .{ .observation = .{ .id = .{ .site = .render_gate, .occurrence = 1 }, .outcome = .empty, .effective_frame = 0 } });
    try feed(&v, .render, .{ .observation = .{ .id = .{ .site = .render_span, .occurrence = 1 }, .outcome = .empty, .effective_frame = 0 } });
    try feed(&v, .render, .{ .end = .{ .outcome = .returned, .points = 2 } });
    try std.testing.expectEqual(@as(u64, 2), v.lanes[1].operations);
    try v.finish(terminalFor(v));
    try v.eof();
    try std.testing.expectError(error.Closed, v.finish(terminalFor(v)));
}

test "odd short circuit and failed attempts preserve only reached fields" {
    for ([_]AcceptanceOutcome{ .unstable, .deferred, .failed }) |outcome| {
        var v = try testValidator();
        try startAccept(&v);
        try feed(&v, .control, .{ .acceptance = .{
            .id = .{ .site = .control_accept, .occurrence = 1 },
            .incoming_frame = 10,
            .outcome = outcome,
            .cut = if (outcome == .unstable) .{ .sequence_before = 3 } else null,
            .reason = 17,
        } });
        try std.testing.expectEqual(@as(u64, 10), v.lanes[0].effective_frame);
        try feed(&v, .control, .{ .phase = .prepare });
        try feed(&v, .control, .{ .observation = .{ .id = .{ .site = .control_prepare, .occurrence = 1 }, .outcome = .empty, .effective_frame = 10 } });
        try feed(&v, .control, .{ .phase = .publish });
        try feed(&v, .control, .{ .observation = .{ .id = .{ .site = .control_publish, .occurrence = 1 }, .outcome = .empty, .effective_frame = 10 } });
        try testPublish(&v, .ordinary);
        try feed(&v, .control, .{ .end = .{ .outcome = .returned, .points = 8, .effective_frame = 10 } });
        // A new actual tick restarts the retained Input order at zero.
        try feed(&v, .control, .{ .begin = .{ .tick = 2, .entry_frame = 10 } });
        try feed(&v, .control, .{ .phase = .collect });
        try feed(&v, .control, .{ .observation = .{ .id = .{ .site = .control_collect, .occurrence = 1 }, .outcome = .value, .effective_frame = 10, .input_order = 0 } });
        try std.testing.expectEqual(@as(u64, 1), v.input_order);
    }
}

test "actual collect and accept frontier may advance without a successful job" {
    var v = try testValidator();
    try feed(&v, .control, .{ .begin = .{ .tick = 1, .entry_frame = 5 } });
    try feed(&v, .control, .{ .phase = .collect });
    try feed(&v, .control, .{ .frontier = .{ .id = .{ .site = .control_collect_frontier, .occurrence = 1 }, .raw_frame = 10, .effective_frame = 10 } });
    try feed(&v, .control, .{ .observation = .{ .id = .{ .site = .control_collect, .occurrence = 1 }, .outcome = .value, .effective_frame = 10, .input_order = 0 } });
    try feed(&v, .control, .{ .phase = .accept });
    try feed(&v, .control, .{ .frontier = .{ .id = .{ .site = .control_accept_frontier, .occurrence = 1 }, .raw_frame = 20, .effective_frame = 20 } });
    try feed(&v, .control, .{ .acceptance = .{ .id = .{ .site = .control_accept, .occurrence = 1 }, .incoming_frame = 20, .outcome = .no_completion } });
    try feed(&v, .control, .{ .phase = .prepare });
    try feed(&v, .control, .{ .observation = .{ .id = .{ .site = .control_prepare, .occurrence = 1 }, .outcome = .empty, .effective_frame = 20 } });
    try feed(&v, .control, .{ .phase = .publish });
    try feed(&v, .control, .{ .observation = .{ .id = .{ .site = .control_publish, .occurrence = 1 }, .outcome = .empty, .effective_frame = 20 } });
    try testPublish(&v, .ordinary);
    try feed(&v, .control, .{ .end = .{ .outcome = .returned, .points = 8, .effective_frame = 20 } });
    try v.finish(terminalFor(v));
    try v.eof();
}

test "odd short circuit cannot invent later reads and changed sequence cannot omit them" {
    for ([_]Cut{
        .{ .sequence_before = 3, .frame = 20 },
        .{ .sequence_before = 3, .sequence_after = 4 },
        .{ .sequence_before = 2, .sequence_after = 4 },
        .{ .sequence_before = 2, .frame = 20, .consumed = 1 },
    }) |cut| {
        var v = try testValidator();
        try startAccept(&v);
        try std.testing.expectError(error.InvalidOutcome, feed(&v, .control, .{ .acceptance = .{
            .id = .{ .site = .control_accept, .occurrence = 1 },
            .incoming_frame = 10,
            .outcome = .unstable,
            .cut = cut,
            .reason = 1,
        } }));
        try std.testing.expectEqual(@as(u64, 10), v.lanes[0].effective_frame);
    }
}

test "initial accept frontier cannot be missing duplicated or regress" {
    var a = try testValidator();
    try startAccept(&a);
    try std.testing.expectError(error.InvalidOrder, feed(&a, .control, .{ .frontier = .{ .id = .{ .site = .control_accept_frontier, .occurrence = 2 }, .raw_frame = 20, .effective_frame = 20 } }));
    var b = try testValidator();
    try feed(&b, .control, .{ .begin = .{ .tick = 1, .entry_frame = 10 } });
    try feed(&b, .control, .{ .phase = .collect });
    try feed(&b, .control, .{ .frontier = .{ .id = .{ .site = .control_collect_frontier, .occurrence = 1 }, .raw_frame = 10, .effective_frame = 10 } });
    try feed(&b, .control, .{ .observation = .{ .id = .{ .site = .control_collect, .occurrence = 1 }, .outcome = .empty, .effective_frame = 10 } });
    try feed(&b, .control, .{ .phase = .accept });
    var c = b;
    try std.testing.expectError(error.Incomplete, feed(&b, .control, accepted(1, 10, 20)));
    try std.testing.expectError(error.InvalidFrame, feed(&c, .control, .{ .frontier = .{ .id = .{ .site = .control_accept_frontier, .occurrence = 1 }, .raw_frame = 9, .effective_frame = 9 } }));
}

fn testFinalPublish(v: *Validator) !void {
    try feed(v, .control, .{ .final_publish = .{
        .id = .{ .site = .control_final_publish, .occurrence = 1 },
        .exit_phase = @enumFromInt(v.lanes[0].phase),
        .effective_frame = v.lanes[0].effective_frame,
    } });
}
fn testPublish(v: *Validator, path: SnapshotPath) !void {
    try feed(v, .control, .{ .snapshot = .{ .id = .{ .site = .control_snapshot, .occurrence = 1 }, .path = path } });
    try testFinalPublish(v);
}
fn testFailure(v: *Validator, origin: FailureOrigin, reason: u32) !void {
    try feed(v, .control, .{ .failure = .{
        .id = .{ .site = .control_failure, .occurrence = v.lanes[0].occurrences[10] + 1 },
        .origin = origin,
        .reason = reason,
    } });
}
fn testReachPhase(v: *Validator, phase: Phase) !void {
    if (phase == .collect) {
        try feed(v, .control, .{ .begin = .{ .tick = 1, .entry_frame = 10 } });
        try feed(v, .control, .{ .phase = .collect });
        return;
    }
    try startAccept(v);
    if (phase == .accept) return;
    try feed(v, .control, .{ .acceptance = .{ .id = .{ .site = .control_accept, .occurrence = 1 }, .incoming_frame = 10, .outcome = .no_completion } });
    try feed(v, .control, .{ .phase = .prepare });
    if (phase == .prepare) return;
    try feed(v, .control, .{ .observation = .{ .id = .{ .site = .control_prepare, .occurrence = 1 }, .outcome = .value, .effective_frame = 10 } });
    try feed(v, .control, .{ .phase = .publish });
    try feed(v, .control, .{ .observation = .{ .id = .{ .site = .control_publish, .occurrence = 1 }, .outcome = .empty, .effective_frame = 10 } });
}
fn testFailedEnd(v: *Validator, reason: u32) !void {
    try feed(v, .control, .{ .end = .{ .outcome = .failed, .points = v.lanes[0].points, .effective_frame = v.lanes[0].effective_frame, .reason = reason } });
    try v.finish(terminalFor(v.*));
    try v.eof();
}

test "each direct error exit retains its origin and unconditional owner publication" {
    const cases = [_]struct { origin: FailureOrigin, phase: Phase }{
        .{ .origin = .collect_owner, .phase = .collect },
        .{ .origin = .accept_device, .phase = .accept },
        .{ .origin = .accept_replay, .phase = .accept },
        .{ .origin = .accept_drain, .phase = .accept },
        .{ .origin = .prepare_success_drain, .phase = .prepare },
        .{ .origin = .snapshot, .phase = .publish },
    };
    for (cases) |case| {
        var v = try testValidator();
        try testReachPhase(&v, case.phase);
        if (case.origin == .prepare_success_drain) try feed(&v, .control, .{ .observation = .{ .id = .{ .site = .control_prepare, .occurrence = 1 }, .outcome = .value, .effective_frame = 10 } });
        try testFailure(&v, case.origin, 41);
        const reached_frame = v.lanes[0].effective_frame;
        try testFinalPublish(&v);
        try std.testing.expectEqual(@intFromEnum(case.phase), v.lanes[0].phase);
        try std.testing.expectEqual(reached_frame, v.lanes[0].effective_frame);
        try testFailedEnd(&v, 41);
    }
}

test "prepare error publishes recovery snapshot then returns original error" {
    var v = try testValidator();
    try testReachPhase(&v, .prepare);
    try testFailure(&v, .prepare_owner, 41);
    // The real recovery drain succeeds, then phase moves to publish even though
    // no successful prepare observation exists. This is not a fabricated phase.
    try feed(&v, .control, .{ .phase = .publish });
    try testPublish(&v, .prepare_failure);
    try std.testing.expectEqual(@as(u32, 41), v.lanes[0].first_failure.?.reason);
    try testFailedEnd(&v, 41);
}

test "recovery drain and snapshot errors override return but preserve first failure" {
    for ([_]FailureOrigin{ .prepare_failure_drain, .snapshot }) |origin| {
        var v = try testValidator();
        try testReachPhase(&v, .prepare);
        try testFailure(&v, .prepare_owner, 41);
        if (origin == .snapshot) try feed(&v, .control, .{ .phase = .publish });
        try testFailure(&v, origin, 42);
        try testFinalPublish(&v);
        try std.testing.expectEqual(@as(u32, 41), v.lanes[0].first_failure.?.reason);
        try std.testing.expectEqual(@as(u32, 42), v.lanes[0].returned_failure.?);
        try testFailedEnd(&v, 42);
    }
}

test "missing final publication and fabricated phase progression cannot seal" {
    var a = try testValidator();
    try testReachPhase(&a, .collect);
    try testFailure(&a, .collect_owner, 41);
    var b = a;
    try std.testing.expectError(error.Incomplete, testFailedEnd(&a, 41));
    try std.testing.expectError(error.InvalidOrder, feed(&b, .control, .{ .phase = .accept }));
    var c = try testValidator();
    try testReachPhase(&c, .prepare);
    try testFailure(&c, .prepare_owner, 41);
    try std.testing.expectError(error.Incomplete, testFinalPublish(&c));
    var d = try testValidator();
    try testReachPhase(&d, .prepare);
    try testFailure(&d, .prepare_owner, 41);
    try feed(&d, .control, .{ .phase = .publish });
    try std.testing.expectError(error.Incomplete, testFinalPublish(&d));
}

test "fake recovery snapshot, missing failure origin and wrong returned error reject" {
    var a = try testValidator();
    try testReachPhase(&a, .publish);
    try std.testing.expectError(error.InvalidOutcome, testPublish(&a, .prepare_failure));
    var b = try testValidator();
    try testReachPhase(&b, .publish);
    try testPublish(&b, .ordinary);
    try std.testing.expectError(error.InvalidOutcome, testFailedEnd(&b, 41));
    var c = try testValidator();
    try testReachPhase(&c, .prepare);
    try testFailure(&c, .prepare_owner, 41);
    try testFailure(&c, .prepare_failure_drain, 42);
    try testFinalPublish(&c);
    try std.testing.expectError(error.InvalidOutcome, testFailedEnd(&c, 41));
    var d = try testValidator();
    try testReachPhase(&d, .accept);
    try std.testing.expectError(error.InvalidOrder, testFailure(&d, .collect_owner, 41));
}

fn testCompleteTick(v: *Validator, frame: u64) !void {
    try feed(v, .control, .{ .phase = .prepare });
    try feed(v, .control, .{ .observation = .{ .id = .{ .site = .control_prepare, .occurrence = 1 }, .outcome = .empty, .effective_frame = frame } });
    try feed(v, .control, .{ .phase = .publish });
    try feed(v, .control, .{ .observation = .{ .id = .{ .site = .control_publish, .occurrence = 1 }, .outcome = .empty, .effective_frame = frame } });
    try testPublish(v, .ordinary);
    try feed(v, .control, .{ .end = .{ .outcome = .returned, .points = v.lanes[0].points, .effective_frame = frame } });
}

test "later tick retains coherent 128 frontier when real scheduled loads remain 64" {
    var v = try testValidator();
    try startAccept(&v);
    try feed(&v, .control, accepted(1, 10, 128));
    try testCompleteTick(&v, 128);
    try feed(&v, .control, .{ .begin = .{ .tick = 2, .entry_frame = 128 } });
    try feed(&v, .control, .{ .phase = .collect });
    try feed(&v, .control, .{ .frontier = .{ .id = .{ .site = .control_collect_frontier, .occurrence = 1 }, .raw_frame = 64, .effective_frame = 128 } });
    try feed(&v, .control, .{ .observation = .{ .id = .{ .site = .control_collect, .occurrence = 1 }, .outcome = .empty, .effective_frame = 128 } });
    try feed(&v, .control, .{ .phase = .accept });
    try feed(&v, .control, .{ .frontier = .{ .id = .{ .site = .control_accept_frontier, .occurrence = 1 }, .raw_frame = 64, .effective_frame = 128 } });
    try feed(&v, .control, .{ .acceptance = .{ .id = .{ .site = .control_accept, .occurrence = 1 }, .incoming_frame = 128, .outcome = .no_completion } });
    try testCompleteTick(&v, 128);
    try v.finish(terminalFor(v));
    try v.eof();
}

test "raw64 with prior64 cannot manufacture effective128" {
    var v = try testValidator();
    try feed(&v, .control, .{ .begin = .{ .tick = 1, .entry_frame = 64 } });
    try feed(&v, .control, .{ .phase = .collect });
    try std.testing.expectError(error.InvalidFrame, feed(&v, .control, .{ .frontier = .{ .id = .{ .site = .control_collect_frontier, .occurrence = 1 }, .raw_frame = 64, .effective_frame = 128 } }));
}

test "accept errors cannot precede actual accept frontier" {
    for ([_]FailureOrigin{ .accept_device, .accept_replay, .accept_drain }) |origin| {
        var v = try testValidator();
        try feed(&v, .control, .{ .begin = .{ .tick = 1, .entry_frame = 10 } });
        try feed(&v, .control, .{ .phase = .collect });
        try feed(&v, .control, .{ .frontier = .{ .id = .{ .site = .control_collect_frontier, .occurrence = 1 }, .raw_frame = 10, .effective_frame = 10 } });
        try feed(&v, .control, .{ .observation = .{ .id = .{ .site = .control_collect, .occurrence = 1 }, .outcome = .empty, .effective_frame = 10 } });
        try feed(&v, .control, .{ .phase = .accept });
        try std.testing.expectError(error.Incomplete, testFailure(&v, origin, 41));
    }
}

test "even sequence cannot omit the real following frame read" {
    var v = try testValidator();
    try startAccept(&v);
    try std.testing.expectError(error.InvalidOutcome, feed(&v, .control, .{ .acceptance = .{
        .id = .{ .site = .control_accept, .occurrence = 1 },
        .incoming_frame = 10,
        .outcome = .failed,
        .cut = .{ .sequence_before = 2 },
        .reason = 41,
    } }));
}

test "terminal acceptance outcome closes attempt stream but permits later prepare" {
    const outcomes = [_]AcceptanceOutcome{ .no_completion, .unstable, .deferred, .failed };
    for (outcomes) |outcome| {
        var v = try testValidator();
        try startAccept(&v);
        const first: Acceptance = .{
            .id = .{ .site = .control_accept, .occurrence = 1 },
            .incoming_frame = 10,
            .outcome = outcome,
            .cut = if (outcome == .unstable) .{ .sequence_before = 3 } else null,
            .reason = if (outcome == .no_completion) 0 else 41,
        };
        try feed(&v, .control, .{ .acceptance = first });
        var later_success = v;
        var later_empty = v;
        try std.testing.expectError(error.InvalidOrder, feed(&later_success, .control, accepted(2, 10, 20)));
        var again = first;
        again.id.occurrence = 2;
        again.outcome = .no_completion;
        again.cut = null;
        again.reason = 0;
        try std.testing.expectError(error.InvalidOrder, feed(&later_empty, .control, .{ .acceptance = again }));
        // Breaking the Service accept loop does not end the Control tick.
        try testCompleteTick(&v, 10);
        try v.finish(terminalFor(v));
        try v.eof();
    }
}

test "device and exclusive replay failures cannot follow actual Service acceptance" {
    for ([_]FailureOrigin{ .accept_device, .accept_replay }) |origin| {
        var v = try testValidator();
        try startAccept(&v);
        try feed(&v, .control, accepted(1, 10, 20));
        try std.testing.expectError(error.InvalidOrder, testFailure(&v, origin, 41));
    }
    var drain = try testValidator();
    try startAccept(&drain);
    try feed(&drain, .control, accepted(1, 10, 20));
    try testFailure(&drain, .accept_drain, 41);
    try testFinalPublish(&drain);
    try testFailedEnd(&drain, 41);
}

fn capturePrepareValidator() !Validator {
    var v = try testValidator();
    try feed(&v, .control, .{ .begin = .{ .tick = 7, .prior_tick = 6, .entry_frame = 10, .retained_inputs = true } });
    try feed(&v, .control, .{ .phase = .collect });
    try feed(&v, .control, .{ .frontier = .{ .id = .{ .site = .control_collect_frontier, .occurrence = 1 }, .raw_frame = 10, .effective_frame = 10 } });
    try feed(&v, .control, .{ .observation = .{ .id = .{ .site = .control_collect, .occurrence = 1 }, .outcome = .value, .effective_frame = 10 } });
    try feed(&v, .control, .{ .phase = .accept });
    try feed(&v, .control, .{ .frontier = .{ .id = .{ .site = .control_accept_frontier, .occurrence = 1 }, .raw_frame = 10, .effective_frame = 10 } });
    try feed(&v, .control, .{ .acceptance = .{ .id = .{ .site = .control_accept, .occurrence = 1 }, .incoming_frame = 10, .outcome = .no_completion } });
    try feed(&v, .control, .{ .phase = .prepare });
    return v;
}
fn captureDeferral() PreparationDefer {
    return .{ .id = .{ .site = .control_prepare, .occurrence = 1 }, .tick = 7, .frame = 10, .reason = 100, .detail = .{ .availability = .{ .stage = 1, .operation = 1, .reason = 1, .handle_index = 0, .handle_generation = 1, .requested_frame = 10, .observed_frame = null, .sequence_before = 3, .sequence_after = null } } };
}
test "captured deferral reasons bind exact native reached read prefixes" {
    for (0..10) |mutation| {
        var v = try capturePrepareValidator();
        var deferred = captureDeferral();
        const detail = &deferred.detail.availability;
        switch (mutation) {
            0 => deferred.reason = 101,
            1 => detail.sequence_before = null,
            2 => detail.sequence_before = 2,
            3 => detail.observed_frame = 10,
            4 => detail.sequence_after = 4,
            5 => { detail.operation = 4; detail.stage = 2; },
            6 => { detail.reason = 2; detail.sequence_before = 2; },
            7 => { detail.reason = 2; detail.sequence_before = 2; detail.observed_frame = 10; },
            8 => { detail.reason = 3; detail.sequence_before = 2; detail.sequence_after = 2; detail.observed_frame = 10; },
            9 => { detail.reason = 3; detail.sequence_before = 2; detail.sequence_after = 4; detail.observed_frame = 11; },
            else => unreachable,
        }
        try std.testing.expectError(error.InvalidOutcome, feed(&v, .control, .{ .preparation_defer = deferred }));
    }
    // A real outer runtime frame mismatch has no Service sequence reads.
    var v = try capturePrepareValidator(); var deferred = captureDeferral();
    deferred.detail.availability = .{ .stage = 2, .operation = 4, .reason = 2, .handle_index = 0, .handle_generation = 1, .requested_frame = 10, .observed_frame = 11, .sequence_before = null, .sequence_after = null };
    try feed(&v, .control, .{ .preparation_defer = deferred });
}
test "captured deferred end requires actual successful publication marker" {
    var v = try capturePrepareValidator();
    try feed(&v, .control, .{ .preparation_defer = captureDeferral() });
    try feed(&v, .control, .{ .phase = .publish });
    try feed(&v, .control, .{ .snapshot = .{ .id = .{ .site = .control_snapshot, .occurrence = 1 }, .path = .ordinary } });
    try testFinalPublish(&v);
    try std.testing.expectError(error.Incomplete, feed(&v, .control, .{ .end = .{ .outcome = .deferred, .points = v.lanes[0].points, .effective_frame = 10, .reason = 100 } }));
}
test "captured prepare completion cannot be duplicated or changed to empty" {
    var v = try capturePrepareValidator();
    try std.testing.expectError(error.InvalidOutcome, feed(&v, .control, .{ .observation = .{ .id = .{ .site = .control_prepare, .occurrence = 1 }, .outcome = .empty, .effective_frame = 10 } }));
    v = try capturePrepareValidator();
    try feed(&v, .control, .{ .preparation_defer = captureDeferral() });
    try std.testing.expectError(error.InvalidOrder, feed(&v, .control, .{ .observation = .{ .id = .{ .site = .control_prepare, .occurrence = 1 }, .outcome = .value, .effective_frame = 10 } }));
}

test "captured Input cannot precede its actual phase frontier acquire" {
    for ([_]Phase{ .collect, .accept }) |phase| {
        var v = try testValidator();
        try feed(&v, .control, .{ .begin = .{ .tick = 7, .prior_tick = 6, .entry_frame = 10, .retained_inputs = true } });
        try feed(&v, .control, .{ .phase = .collect });
        if (phase == .accept) {
            try feed(&v, .control, .{ .frontier = .{ .id = .{ .site = .control_collect_frontier, .occurrence = 1 }, .raw_frame = 10, .effective_frame = 10 } });
            try feed(&v, .control, .{ .observation = .{ .id = .{ .site = .control_collect, .occurrence = 1 }, .outcome = .value, .effective_frame = 10 } });
            try feed(&v, .control, .{ .phase = .accept });
        }
        const input_value: trace.Input = .{ .position = .{ .control_tick = 7, .accepted_control_frame = 10, .input_order = 0 }, .payload = .{ .request = .{ .request_id = 1, .producer = 1, .producer_order = 1, .context = 1, .payload = .{ .set_state = .{ .state = 1, .priority = 0 } } } } };
        var storage: [input_max_bytes]u8 = undefined;
        var encoder: trace.codec.Encoder = .{ .bytes = &storage }; try encoder.put(input_value);
        try std.testing.expectError(error.Incomplete, feed(&v, .control, .{ .retained_input = .{ .id = .{ .site = .control_input, .occurrence = 1 }, .bytes = storage[0..encoder.offset] } }));
    }
}
