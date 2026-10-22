//! Bounded metadata observations of admitted integrated Control ticks.
//! This is not a recording format, replay contract, or PCM/causal-completeness
//! proof. Collection results, Worker admissions, readiness and Render gates
//! are deliberately outside its coverage. Render has its own separate ring.
//!
//! One serialized Control producer, one serialized host consumer. Construct at
//! a stable address before attachment. Runtime lifecycle wrappers exclude the
//! producer with its existing Control guard. The host must additionally exclude
//! the consumer and request callers for attachment, detachment, reuse and free.
//! Published records must be drained before detachment. Neither an incomplete
//! flag nor a terminal permits freeing a live owner or an attached Bridge.
//! Producer publication has fixed work: no allocation, IO, lock, wait or retry.
const std = @import("std");
const capture = @import("sme-capture-handoff-control");

pub const slot_capacity: usize = 64;
pub const Error = error{ InvalidState, StaleSession, Undrained, IdentityExhausted, ConcurrentLifecycle };
var next_incarnation: std.atomic.Value(u64) = .init(1);
var next_owner_identity: std.atomic.Value(u64) = .init(1);

/// Host lifecycle only. An owner retains this identity across observer reuse;
/// a newly constructed owner at the same address must obtain a new identity.
pub fn allocateOwnerIdentity() Error!u64 {
    return claimIdentity(&next_owner_identity);
}
fn claimIdentity(counter: *std.atomic.Value(u64)) Error!u64 {
    const value = counter.load(.acquire);
    if (value == std.math.maxInt(u64)) return error.IdentityExhausted;
    if (counter.cmpxchgStrong(value, value + 1, .acq_rel, .acquire) != null) return error.ConcurrentLifecycle;
    return value;
}

pub const Session = struct {
    bridge: *const Bridge,
    incarnation: u64,
    generation: u64,
    owner_identity: u64,
    interval_id: u64,
};
pub const Phase = enum { idle, collect, accept, prepare, publish };
pub const Kind = enum { tick_open, collect_frame, accept_frame, plan_query, tick_close };
pub const Failure = enum(u8) { none, queue_full, counter_exhausted, interrupted, cancelled, capture_failed, capture_budget };
pub const CloseReason = enum { producer_boundary, owner_boundary, cancelled };
pub const PlanResult = enum { none, frame, unsafe_frame_range };
pub const Outcome = enum { none, success, failed };
/// Observed source of the returned error. The preparation marker is emitted
/// only after the real fallback Control publication completed successfully.
/// It does not classify an error by its numeric code or supply a recovery.
pub const ReturnPath = enum { ordinary, prepare_failure_after_control_publication };
pub const Event = struct {
    incarnation: u64,
    generation: u64,
    owner_identity: u64,
    interval_id: u64,
    /// Checked producer-local event-attempt number; never a replay order.
    sequence: u64,
    kind: Kind,
    phase: Phase,
    tick_serial: u64,
    control_tick: u64,
    /// Exact collected/accepted frame or actual successful planning result.
    frame: u64 = 0,
    /// One-based within each admitted tick, for every actual helper query.
    /// Zero on exhausted ordinal; the interval is then permanently incomplete.
    query_ordinal: u64 = 0,
    horizon: u64 = 0,
    min_plan_lead_frames: u64 = 0,
    late_race_budget_frames: u64 = 0,
    plan_result: PlanResult = .none,
    outcome: Outcome = .none,
    /// Process-local numeric Zig error identity; not a serialized error schema.
    error_code: u32 = 0,
    /// Tick return-path phase, before mandatory deferred Music publication.
    exit_phase: Phase = .idle,
    return_path: ReturnPath = .ordinary,
};
pub const Status = struct {
    closed: bool,
    incomplete: bool,
    failure: Failure,
    ticks_opened: u64,
    ticks_closed: u64,
    ticks_failed: u64,
    planning_queries: u64,
    events_attempted: u64,
    events_published: u64,
    events_consumed: u64,
    dropped_events: u64,
};
pub const Terminal = struct {
    incarnation: u64,
    generation: u64,
    owner_identity: u64,
    interval_id: u64,
    reason: CloseReason,
    /// false means no known loss in this narrow observer, not causal coverage.
    incomplete: bool,
    failure: Failure,
    ticks_opened: u64,
    ticks_closed: u64,
    ticks_failed: u64,
    planning_queries: u64,
    events_attempted: u64,
    events_published: u64,
    dropped_events: u64,
    last_tick_serial: u64,
    last_control_tick: u64,
    last_query_ordinal: u64,
    last_outcome: Outcome,
    last_error_code: u32,
    last_exit_phase: Phase,
};
pub const PublishHook = struct { context: *anyopaque, call: *const fn (*anyopaque, *Bridge, Event) void };

pub const Bridge = struct {
    /// Detached setup field; changing it cannot alter an attached generation.
    configured_continuous: ?capture.Session = null,
    // Frozen producer binding. Only attach/detach may replace this handle.
    continuous: ?capture.Session = null,
    continuous_failed: bool = false,
    slots: [slot_capacity]Event = undefined,
    /// Test-only, before release publication. May inspect/drain/request stop;
    /// must not reenter the producer or alter engine state.
    test_before_publish_hook: if (@import("builtin").is_test) ?PublishHook else void = if (@import("builtin").is_test) null else {},
    incarnation: std.atomic.Value(u64) = .init(0),
    generation: std.atomic.Value(u64) = .init(0),
    owner_identity: std.atomic.Value(u64) = .init(0),
    interval_id: std.atomic.Value(u64) = .init(0),
    write_cursor: std.atomic.Value(u64) = .init(0),
    read_cursor: std.atomic.Value(u64) = .init(0),
    closed: std.atomic.Value(bool) = .init(true),
    stop_requested: std.atomic.Value(bool) = .init(false),
    cancel_requested: std.atomic.Value(bool) = .init(false),
    failure: std.atomic.Value(Failure) = .init(.none),
    ticks_opened: std.atomic.Value(u64) = .init(0),
    ticks_closed: std.atomic.Value(u64) = .init(0),
    ticks_failed: std.atomic.Value(u64) = .init(0),
    planning_queries: std.atomic.Value(u64) = .init(0),
    events_attempted: std.atomic.Value(u64) = .init(0),
    dropped_events: std.atomic.Value(u64) = .init(0),
    // Producer-only until owner lifecycle exclusion. Never read live by host.
    owner: ?*const anyopaque = null,
    tick_open: bool = false,
    tick_serial: u64 = 0,
    control_tick: u64 = 0,
    query_ordinal: u64 = 0,
    last_outcome: Outcome = .none,
    last_error_code: u32 = 0,
    last_exit_phase: Phase = .idle,
    terminal_value: Terminal = undefined,

    /// Host-only configuration. The handle and policy remain frozen while
    /// attached, and the shared state stays pinned through the writer join.
    pub fn configureContinuous(self: *Bridge, session: ?capture.Session) Error!void {
        if (self.owner != null or !self.closed.load(.acquire)) return error.InvalidState;
        if (self.read_cursor.load(.acquire) != self.write_cursor.load(.acquire)) return error.Undrained;
        if (session) |value| try capture.validateAttachment(value, .frontier, value.descriptor.interval_id);
        self.configured_continuous = session;
        self.continuous_failed = false;
    }
    pub fn continuousSession(self: *const Bridge) Error!?capture.Session {
        const session = if (self.owner != null) self.continuous else self.configured_continuous;
        if (session) |value| try capture.validate(value);
        return session;
    }
    pub fn continuousDescriptor(self: *const Bridge) Error!?capture.Descriptor {
        return if (try self.continuousSession()) |session| session.descriptor else null;
    }
    fn observeContinuousFailure(self: *Bridge) bool {
        const session = self.continuous orelse return false;
        if ((capture.failure(session) catch .invalid_state) != .none) {
            self.continuous_failed = true;
            if (self.failure.load(.monotonic) == .none) self.failure.store(.capture_failed, .release);
        }
        return self.continuous_failed;
    }
    fn acknowledgeContinuousFailure(self: *Bridge) void {
        if (self.tick_open or !self.observeContinuousFailure()) return;
        capture.acknowledgeProducer(self.continuous.?, .frontier, .{ .events_attempted = self.events_attempted.load(.monotonic), .events_published = self.write_cursor.load(.monotonic) }) catch {};
    }

    /// Runtime lifecycle only: Control guard held, no active tick, and host
    /// exclusion of consumers/requests. Keep both objects at stable addresses.
    pub fn attachAtBoundary(self: *Bridge, owner: *const anyopaque, owner_identity: u64, interval_id: u64) Error!Session {
        if (owner_identity == 0 or interval_id == 0 or self.owner != null or !self.closed.load(.acquire)) return error.InvalidState;
        if (self.read_cursor.load(.acquire) != self.write_cursor.load(.acquire)) return error.Undrained;
        if (self.configured_continuous) |session| try capture.validateAttachment(session, .frontier, interval_id);
        const old_generation = self.generation.load(.monotonic);
        if (old_generation == std.math.maxInt(u64)) return error.IdentityExhausted;
        var identity = self.incarnation.load(.monotonic);
        if (identity == 0) {
            identity = try claimIdentity(&next_incarnation);
            self.incarnation.store(identity, .release);
        }
        if (self.configured_continuous) |session| capture.bindProducer(session, .frontier);
        self.continuous = self.configured_continuous;
        self.configured_continuous = null; // consume the setup borrow
        self.continuous_failed = false;
        self.owner = owner;
        self.tick_open = false;
        self.tick_serial = 0;
        self.control_tick = 0;
        self.query_ordinal = 0;
        self.last_outcome = .none;
        self.last_error_code = 0;
        self.last_exit_phase = .idle;
        self.owner_identity.store(owner_identity, .monotonic);
        self.interval_id.store(interval_id, .monotonic);
        self.write_cursor.store(0, .monotonic);
        self.read_cursor.store(0, .monotonic);
        self.stop_requested.store(false, .monotonic);
        self.cancel_requested.store(false, .monotonic);
        self.failure.store(.none, .monotonic);
        self.ticks_opened.store(0, .monotonic);
        self.ticks_closed.store(0, .monotonic);
        self.ticks_failed.store(0, .monotonic);
        self.planning_queries.store(0, .monotonic);
        self.events_attempted.store(0, .monotonic);
        self.dropped_events.store(0, .monotonic);
        self.closed.store(false, .monotonic);
        self.generation.store(old_generation + 1, .release);
        return .{ .bridge = self, .incarnation = identity, .generation = old_generation + 1, .owner_identity = owner_identity, .interval_id = interval_id };
    }

    /// Requests are safe with the live producer, but never acknowledge closure.
    /// A request during a tick closes after its real deferred publication; with
    /// no later tick the owner must explicitly call closeAtBoundary instead.
    pub fn requestStop(self: *Bridge, session: Session) Error!void {
        try self.validate(session);
        if (self.closed.load(.acquire)) return error.InvalidState;
        if (self.continuous) |value| {
            try capture.fail(value, .cancelled);
            return;
        }
        self.stop_requested.store(true, .release);
    }
    /// Closure can win a concurrent cancellation. A successful request return
    /// is not an accepted cancellation; only the immutable terminal reports the
    /// acknowledged outcome and reason.
    pub fn requestCancel(self: *Bridge, session: Session) Error!void {
        try self.validate(session);
        if (self.closed.load(.acquire)) return error.InvalidState;
        self.cancel_requested.store(true, .release);
        if (self.continuous) |value| {
            try capture.fail(value, .cancelled);
            return;
        }
        self.stop_requested.store(true, .release);
    }

    pub fn beginTick(self: *Bridge, session: Session, tick_serial: u64, control_tick: u64) void {
        self.validate(session) catch return;
        if (self.closed.load(.acquire)) return;
        // Runtime has already admitted the real operation. Even if failure
        // predates this call, retain its end hook and acknowledge only there.
        _ = self.observeContinuousFailure();
        if (self.tick_open or tick_serial == 0 or control_tick == 0 or tick_serial <= self.tick_serial or control_tick <= self.control_tick) {
            self.fail(.interrupted);
            return;
        }
        if (self.stop_requested.load(.acquire)) {
            self.close(.producer_boundary);
            return;
        }
        self.tick_open = true;
        self.tick_serial = tick_serial;
        self.control_tick = control_tick;
        self.query_ordinal = 0;
        self.bump(&self.ticks_opened);
        self.publish(self.event(session, .tick_open, .collect));
    }
    pub fn observeFrame(self: *Bridge, session: Session, tick_serial: u64, kind: Kind, phase: Phase, frame: u64) void {
        if (!self.activeTick(session, tick_serial) or self.observeContinuousFailure()) return;
        if ((kind != .collect_frame or phase != .collect) and (kind != .accept_frame or phase != .accept)) {
            self.fail(.interrupted);
            return;
        }
        var value = self.event(session, kind, phase);
        value.frame = frame;
        self.publish(value);
    }
    pub fn observePlan(self: *Bridge, session: Session, tick_serial: u64, phase: Phase, horizon: u64, min_plan_lead_frames: u64, late_race_budget_frames: u64, result: ?u64) void {
        if (!self.activeTick(session, tick_serial) or self.observeContinuousFailure()) return;
        self.bump(&self.planning_queries);
        const ordinal = std.math.add(u64, self.query_ordinal, 1) catch 0;
        if (ordinal == 0) self.fail(.counter_exhausted) else self.query_ordinal = ordinal;
        var value = self.event(session, .plan_query, phase);
        value.query_ordinal = ordinal;
        value.horizon = horizon;
        value.min_plan_lead_frames = min_plan_lead_frames;
        value.late_race_budget_frames = late_race_budget_frames;
        value.plan_result = if (result != null) .frame else .unsafe_frame_range;
        value.frame = result orelse 0;
        value.error_code = if (result != null) 0 else @intFromError(error.UnsafeFrameRange);
        self.publish(value);
    }
    /// After mandatory Music publication, before token/Control guard release.
    /// An observed engine error is an outcome, not itself lost witness evidence.
    pub fn endTick(self: *Bridge, session: Session, tick_serial: u64, exit_phase: Phase, tick_error: ?anyerror) void {
        self.endTickObserved(session, tick_serial, exit_phase, tick_error, .ordinary);
    }
    pub fn endTickObserved(self: *Bridge, session: Session, tick_serial: u64, exit_phase: Phase, tick_error: ?anyerror, return_path: ReturnPath) void {
        if (!self.activeTick(session, tick_serial)) return;
        self.last_outcome = if (tick_error != null) .failed else .success;
        self.last_error_code = if (tick_error) |err| @intFromError(err) else 0;
        self.last_exit_phase = exit_phase;
        self.bump(&self.ticks_closed);
        if (tick_error != null) self.bump(&self.ticks_failed);
        var value = self.event(session, .tick_close, .publish);
        value.outcome = self.last_outcome;
        value.error_code = self.last_error_code;
        value.exit_phase = exit_phase;
        value.return_path = return_path;
        value.query_ordinal = self.query_ordinal;
        self.publish(value);
        self.tick_open = false;
        self.acknowledgeContinuousFailure();
        if (self.stop_requested.load(.acquire)) self.close(.producer_boundary);
    }
    pub fn closeAtBoundary(self: *Bridge, session: Session, owner: *const anyopaque) Error!void {
        try self.validateOwner(session, owner);
        if (self.tick_open) return error.InvalidState;
        if (!self.closed.load(.acquire)) self.close(.owner_boundary);
    }
    pub fn detachAtBoundary(self: *Bridge, session: Session, owner: *const anyopaque) Error!void {
        try self.validateOwner(session, owner);
        if (self.tick_open or !self.closed.load(.acquire)) return error.InvalidState;
        if (self.read_cursor.load(.acquire) != self.write_cursor.load(.acquire)) return error.Undrained;
        self.owner = null;
        self.continuous = null;
        self.configured_continuous = null; // no hidden borrow after detach
    }
    pub fn pop(self: *Bridge, session: Session) Error!?Event {
        try self.validate(session);
        const read = self.read_cursor.load(.monotonic);
        if (read == self.write_cursor.load(.acquire)) return null;
        const value = self.slots[@intCast(read % slot_capacity)];
        self.read_cursor.store(read + 1, .release);
        return value;
    }
    /// Live counters are advisory, individually acquired observations. Only
    /// terminal() provides the immutable coherent closing accounting frontier.
    pub fn status(self: *const Bridge, session: Session) Error!Status {
        try self.validate(session);
        const local_failure = self.failure.load(.acquire);
        const failure: Failure = if (local_failure != .none) local_failure else if (self.continuous) |value| (if ((capture.failure(value) catch .invalid_state) != .none) .capture_failed else .none) else .none;
        return .{
            .closed = self.closed.load(.acquire),
            .incomplete = failure != .none,
            .failure = failure,
            .ticks_opened = self.ticks_opened.load(.acquire),
            .ticks_closed = self.ticks_closed.load(.acquire),
            .ticks_failed = self.ticks_failed.load(.acquire),
            .planning_queries = self.planning_queries.load(.acquire),
            .events_attempted = self.events_attempted.load(.acquire),
            .events_published = self.write_cursor.load(.acquire),
            .events_consumed = self.read_cursor.load(.acquire),
            .dropped_events = self.dropped_events.load(.acquire),
        };
    }
    pub fn terminal(self: *const Bridge, session: Session) Error!?Terminal {
        try self.validate(session);
        if (!self.closed.load(.acquire)) return null;
        return self.terminal_value;
    }
    fn validate(self: *const Bridge, session: Session) Error!void {
        if (session.bridge != self or session.incarnation == 0 or session.incarnation != self.incarnation.load(.acquire) or session.generation == 0 or session.generation != self.generation.load(.acquire) or session.owner_identity == 0 or session.owner_identity != self.owner_identity.load(.acquire) or session.interval_id == 0 or session.interval_id != self.interval_id.load(.acquire)) return error.StaleSession;
    }
    fn validateOwner(self: *const Bridge, session: Session, owner: *const anyopaque) Error!void {
        try self.validate(session);
        if (self.owner != owner) return error.InvalidState;
    }
    fn activeTick(self: *Bridge, session: Session, tick_serial: u64) bool {
        self.validate(session) catch return false;
        if (self.closed.load(.acquire) or !self.tick_open) return false;
        if (tick_serial != self.tick_serial) {
            self.fail(.interrupted);
            return false;
        }
        return true;
    }
    fn event(self: *const Bridge, session: Session, kind: Kind, phase: Phase) Event {
        return .{ .incarnation = session.incarnation, .generation = session.generation, .owner_identity = session.owner_identity, .interval_id = session.interval_id, .sequence = 0, .kind = kind, .phase = phase, .tick_serial = self.tick_serial, .control_tick = self.control_tick };
    }
    fn fail(self: *Bridge, failure: Failure) void {
        if (failure == .none) return;
        if (self.continuous) |session| {
            self.continuous_failed = true;
            capture.fail(session, .producer_failure) catch {};
        }
        if (self.failure.load(.monotonic) == .none) self.failure.store(failure, .release);
    }
    fn bump(self: *Bridge, counter: *std.atomic.Value(u64)) void {
        const value = counter.load(.monotonic);
        if (value == std.math.maxInt(u64)) {
            self.fail(.counter_exhausted);
            return;
        }
        counter.store(value + 1, .release);
    }
    fn publish(self: *Bridge, value: Event) void {
        if (self.observeContinuousFailure()) return;
        const attempted = self.events_attempted.load(.monotonic);
        if (attempted == std.math.maxInt(u64)) {
            self.fail(.counter_exhausted);
            self.bump(&self.dropped_events);
            return;
        }
        self.events_attempted.store(attempted + 1, .release);
        if (self.continuous) |session| if (attempted >= session.descriptor.event_limit) {
            self.fail(.capture_budget);
            self.bump(&self.dropped_events);
            return;
        };
        const write = self.write_cursor.load(.monotonic);
        const read = self.read_cursor.load(.acquire);
        if (write == std.math.maxInt(u64) or write - read == slot_capacity) {
            self.fail(if (write == std.math.maxInt(u64)) .counter_exhausted else .queue_full);
            self.bump(&self.dropped_events);
            return;
        }
        const slot = &self.slots[@intCast(write % slot_capacity)];
        slot.* = value;
        slot.sequence = attempted + 1;
        if (@import("builtin").is_test) if (self.test_before_publish_hook) |hook| hook.call(hook.context, self, slot.*);
        self.write_cursor.store(write + 1, .release);
    }
    fn close(self: *Bridge, reason: CloseReason) void {
        _ = self.observeContinuousFailure();
        if (self.tick_open or self.ticks_opened.load(.monotonic) != self.ticks_closed.load(.monotonic)) self.fail(.interrupted);
        const cancelled = self.cancel_requested.load(.acquire);
        if (cancelled) self.fail(.cancelled);
        const failure = self.failure.load(.monotonic);
        self.terminal_value = .{
            .incarnation = self.incarnation.load(.monotonic),
            .generation = self.generation.load(.monotonic),
            .owner_identity = self.owner_identity.load(.monotonic),
            .interval_id = self.interval_id.load(.monotonic),
            .reason = if (cancelled) .cancelled else reason,
            .incomplete = failure != .none,
            .failure = failure,
            .ticks_opened = self.ticks_opened.load(.monotonic),
            .ticks_closed = self.ticks_closed.load(.monotonic),
            .ticks_failed = self.ticks_failed.load(.monotonic),
            .planning_queries = self.planning_queries.load(.monotonic),
            .events_attempted = self.events_attempted.load(.monotonic),
            .events_published = self.write_cursor.load(.monotonic),
            .dropped_events = self.dropped_events.load(.monotonic),
            .last_tick_serial = self.tick_serial,
            .last_control_tick = self.control_tick,
            .last_query_ordinal = self.query_ordinal,
            .last_outcome = self.last_outcome,
            .last_error_code = self.last_error_code,
            .last_exit_phase = self.last_exit_phase,
        };
        self.acknowledgeContinuousFailure();
        self.closed.store(true, .release);
    }
};

pub const event_bytes: usize = @sizeOf(Event);
pub const slot_storage_bytes: usize = slot_capacity * event_bytes;
pub const bridge_bytes: usize = @sizeOf(Bridge);
