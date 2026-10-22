//! Bounded metadata observations of the production callback/quantum path.
//! This is NOT a recording format, a PCM witness, or a replay contract. There
//! is no Control/Render ordering proof and no claim about hardware delivery.
//!
//! One serialized callback producer, one serialized host/Control consumer.
//! Construct once at a stable address. Attach/reset/detach/free require actual
//! device callback quiescence AND external exclusion of the consumer. A closed
//! terminal alone never permits freeing storage. pop() returns a value, never
//! a borrowed slot. No allocation, IO, hash, lock, retry, or PCM copy occurs on
//! the producer path. Host lifecycle methods are for the device adapter only;
//! its validated RuntimeRenderer.DeviceQuiescence supplies the lifetime proof.
const std = @import("std");

pub const slot_capacity: usize = 64;
pub const sample_capacity: usize = 0;
pub const Error = error{ InvalidState, StaleSession, Undrained, IdentityExhausted, ConcurrentLifecycle };

// Process-lifetime identity; never reset. A reconstructed Bridge at the same
// address obtains a fresh identity. One host CAS attempt, never a callback CAS.
var next_incarnation: std.atomic.Value(u64) = .init(1);

pub const Session = struct {
    bridge: *const Bridge,
    incarnation: u64,
    generation: u64,
};
pub const Source = enum(u8) { device_callback, adapter_call, negotiated_call };
pub const Kind = enum(u8) { callback_enter, callback_complete, quantum_enter, quantum_complete };
pub const Failure = enum(u8) {
    none,
    queue_full,
    counter_exhausted,
    interrupted,
    callback_error,
    renderer_not_generated,
    unobserved_render,
    device_epoch_changed,
    cancelled,
};
pub const CloseReason = enum(u8) { producer_boundary, host_quiescent, cancelled };
pub const Delivery = struct {
    quality: enum(u8) { unavailable, exact, estimated } = .unavailable,
    frames: u64 = 0,
    max_error_frames: u64 = 0,
};
pub const Observation = struct {
    render_frame: u64 = 0,
    render_call_sequence: u64 = 0,
    render_call_exhausted: bool = false,
    generated_frames: u64 = 0,
    submitted_frames: u64 = 0,
    epoch_submitted_frames: u64 = 0,
    pending_frames: u64 = 0,
    pending_start_frame: u64 = 0,
    pending_end_frame: u64 = 0,
    flushed_frames: u64 = 0,
    device_epoch: u64 = 0,
    delivery: Delivery = .{},
};
pub const Event = struct {
    incarnation: u64,
    generation: u64,
    /// Attempt number, including dropped events. Not a replay order.
    sequence: u64,
    kind: Kind,
    source: Source,
    callback_index: u64,
    quantum_index: u64,
    requested_frames: u32,
    channels: u16,
    observation: Observation,
};
pub const Status = struct {
    closed: bool,
    failure: Failure,
    callbacks_entered: u64,
    callbacks_completed: u64,
    quanta_entered: u64,
    quanta_completed: u64,
    events_attempted: u64,
    events_published: u64,
    events_consumed: u64,
    dropped_events: u64,
};
pub const Terminal = struct {
    incarnation: u64,
    generation: u64,
    reason: CloseReason,
    /// Only says whether this bounded metadata interval lost evidence.
    /// false does NOT imply a complete recording, replayability, or PCM proof.
    incomplete: bool,
    failure: Failure,
    callbacks_entered: u64,
    callbacks_completed: u64,
    quanta_entered: u64,
    quanta_completed: u64,
    events_attempted: u64,
    events_published: u64,
    dropped_events: u64,
    observation: Observation,
};

pub const PublishHook = struct { context: *anyopaque, call: *const fn (*anyopaque, *Bridge, Event) void };

pub const Bridge = struct {
    slots: [slot_capacity]Event = undefined,
    /// Test only, after slot payload write and before release publication. A
    /// bounded hook may inspect/drain/request stop; it must not wait or render.
    test_before_publish_hook: if (@import("builtin").is_test) ?PublishHook else void = if (@import("builtin").is_test) null else {},
    incarnation: std.atomic.Value(u64) = .init(0),
    generation: std.atomic.Value(u64) = .init(0),
    write_cursor: std.atomic.Value(u64) = .init(0),
    read_cursor: std.atomic.Value(u64) = .init(0),
    closed: std.atomic.Value(bool) = .init(true),
    stop_requested: std.atomic.Value(bool) = .init(false),
    cancel_requested: std.atomic.Value(bool) = .init(false),
    failure: std.atomic.Value(Failure) = .init(.none),
    callbacks_entered: std.atomic.Value(u64) = .init(0),
    callbacks_completed: std.atomic.Value(u64) = .init(0),
    quanta_entered: std.atomic.Value(u64) = .init(0),
    quanta_completed: std.atomic.Value(u64) = .init(0),
    events_attempted: std.atomic.Value(u64) = .init(0),
    dropped_events: std.atomic.Value(u64) = .init(0),
    // Producer-only until genuine quiescence; never read by live consumers.
    owner: ?*const anyopaque = null,
    callback_open: bool = false,
    quantum_open: bool = false,
    source: Source = .adapter_call,
    callback_frames: u32 = 0,
    callback_channels: u16 = 0,
    callback_epoch: u64 = 0,
    quantum_before: Observation = .{},
    quantum_frames: u32 = 0,
    quantum_channels: u16 = 0,
    terminal_value: Terminal = undefined,

    /// Adapter host only, with validated renderer quiescence and no consumer.
    /// Drain the previous interval and detach it before starting a new one.
    pub fn attachQuiescent(self: *Bridge, owner: *const anyopaque) Error!Session {
        if (self.owner != null or !self.closed.load(.acquire)) return error.InvalidState;
        if (self.read_cursor.load(.acquire) != self.write_cursor.load(.acquire)) return error.Undrained;
        const old_generation = self.generation.load(.monotonic);
        if (old_generation == std.math.maxInt(u64)) return error.IdentityExhausted;
        var identity = self.incarnation.load(.monotonic);
        if (identity == 0) {
            identity = next_incarnation.load(.acquire);
            if (identity == std.math.maxInt(u64)) return error.IdentityExhausted;
            if (next_incarnation.cmpxchgStrong(identity, identity + 1, .acq_rel, .acquire) != null) return error.ConcurrentLifecycle;
            self.incarnation.store(identity, .release);
        }
        self.owner = owner;
        self.callback_open = false;
        self.quantum_open = false;
        self.write_cursor.store(0, .monotonic);
        self.read_cursor.store(0, .monotonic);
        self.stop_requested.store(false, .monotonic);
        self.cancel_requested.store(false, .monotonic);
        self.failure.store(.none, .monotonic);
        self.callbacks_entered.store(0, .monotonic);
        self.callbacks_completed.store(0, .monotonic);
        self.quanta_entered.store(0, .monotonic);
        self.quanta_completed.store(0, .monotonic);
        self.events_attempted.store(0, .monotonic);
        self.dropped_events.store(0, .monotonic);
        self.closed.store(false, .monotonic);
        self.generation.store(old_generation + 1, .release);
        return .{ .bridge = self, .incarnation = identity, .generation = old_generation + 1 };
    }

    /// Requests only. No detach, callback lifetime change, or synchronous ack.
    /// Stop is sampled at callback entry and exit, never inside a quantum.
    pub fn requestStop(self: *Bridge, session: Session) Error!void {
        try self.validate(session);
        if (self.closed.load(.acquire)) return error.InvalidState;
        self.stop_requested.store(true, .release);
    }
    /// Closure may win a concurrent cancellation. Read the terminal for the
    /// acknowledged outcome; a request itself is never an acknowledgement.
    pub fn requestCancel(self: *Bridge, session: Session) Error!void {
        try self.validate(session);
        if (self.closed.load(.acquire)) return error.InvalidState;
        self.cancel_requested.store(true, .release);
        self.stop_requested.store(true, .release);
    }

    /// Producer only. false means this callback is outside the observation
    /// interval. A stop at entry closes before incrementing entered counters.
    pub fn beginCallback(self: *Bridge, session: Session, source: Source, frames: u32, channels: u16, observation: Observation) bool {
        self.validate(session) catch return false;
        if (self.closed.load(.acquire)) return false;
        if (self.callback_open or self.quantum_open) {
            self.fail(.interrupted);
            return false;
        }
        if (self.stop_requested.load(.acquire)) {
            self.close(.producer_boundary, observation);
            return false;
        }
        self.callback_open = true;
        self.source = source;
        self.callback_frames = frames;
        self.callback_channels = channels;
        self.callback_epoch = observation.device_epoch;
        self.bump(&self.callbacks_entered);
        self.publish(session, .callback_enter, frames, channels, observation);
        return true;
    }
    /// Completion means callback code reached its return path. Submitted
    /// frames and delivered frames remain separate from callback completion.
    pub fn endCallback(self: *Bridge, session: Session, observation: Observation, failure: Failure) void {
        self.validate(session) catch return;
        if (self.closed.load(.acquire) or !self.callback_open) return;
        if (failure != .none) self.fail(failure);
        if (self.quantum_open) self.fail(.interrupted);
        if (observation.device_epoch != self.callback_epoch) self.fail(.device_epoch_changed);
        self.bump(&self.callbacks_completed);
        self.publish(session, .callback_complete, self.callback_frames, self.callback_channels, observation);
        self.callback_open = false;
        if (self.stop_requested.load(.acquire)) self.close(.producer_boundary, observation);
    }
    pub fn beginQuantum(self: *Bridge, session: Session, frames: u32, channels: u16, observation: Observation) void {
        self.validate(session) catch return;
        if (self.closed.load(.acquire) or !self.callback_open) return;
        if (self.quantum_open) {
            self.fail(.interrupted);
            return;
        }
        self.quantum_open = true;
        self.quantum_before = observation;
        self.quantum_frames = frames;
        self.quantum_channels = channels;
        self.bump(&self.quanta_entered);
        self.publish(session, .quantum_enter, frames, channels, observation);
    }
    /// Around the real renderer call, before adapter pending/submission updates.
    /// Verify actual generation rather than inferring it from requested frames.
    pub fn endQuantum(self: *Bridge, session: Session, observation: Observation) void {
        self.validate(session) catch return;
        if (self.closed.load(.acquire) or !self.quantum_open) return;
        const before = self.quantum_before;
        const expected_frame: ?u64 = std.math.add(u64, before.render_frame, self.quantum_frames) catch null;
        const expected_call: ?u64 = std.math.add(u64, before.render_call_sequence, 2) catch null;
        if (expected_frame == null or expected_call == null or observation.render_frame != expected_frame.? or observation.render_call_sequence != expected_call.? or before.render_call_sequence & 1 != 0 or before.render_call_exhausted or observation.render_call_exhausted) self.fail(.renderer_not_generated);
        if (observation.device_epoch != before.device_epoch) self.fail(.device_epoch_changed);
        self.bump(&self.quanta_completed);
        self.publish(session, .quantum_complete, self.quantum_frames, self.quantum_channels, observation);
        self.quantum_open = false;
    }

    /// Adapter producer or genuinely quiescent host only. A Render frontier
    /// advanced outside observed callbacks (for example shutdown drain). Keep
    /// the raw closing observation, but never certify that gap as covered.
    /// Later audio progress cannot change an already-closed interval.
    pub fn observeUncoveredRender(self: *Bridge, session: Session) void {
        self.validate(session) catch return;
        if (!self.closed.load(.acquire)) self.fail(.unobserved_render);
    }

    /// The caller supplies actual device quiescence, not merely a lost flag or
    /// an idle observation. Detect an interrupted producer without fabricating
    /// its completion. Closing an already-closed interval is idempotent.
    pub fn closeQuiescent(self: *Bridge, session: Session, owner: *const anyopaque, observation: Observation) Error!void {
        try self.validateOwner(session, owner);
        if (!self.closed.load(.acquire)) self.close(.host_quiescent, observation);
    }
    pub fn detachQuiescent(self: *Bridge, session: Session, owner: *const anyopaque) Error!void {
        try self.validateOwner(session, owner);
        if (!self.closed.load(.acquire)) return error.InvalidState;
        self.owner = null;
    }

    /// Sole consumer: one acquire, copy one published slot, release the read
    /// cursor. An unpublished producer never reserves a slot visible to pop.
    pub fn pop(self: *Bridge, session: Session) Error!?Event {
        try self.validate(session);
        const read = self.read_cursor.load(.monotonic);
        if (read == self.write_cursor.load(.acquire)) return null;
        const event = self.slots[@intCast(read % slot_capacity)];
        self.read_cursor.store(read + 1, .release);
        return event;
    }
    /// Live counters are individually published and may be from different
    /// instants. Only terminal() is an immutable, coherent closing snapshot.
    pub fn status(self: *const Bridge, session: Session) Error!Status {
        try self.validate(session);
        return .{
            .closed = self.closed.load(.acquire),
            .failure = self.failure.load(.acquire),
            .callbacks_entered = self.callbacks_entered.load(.acquire),
            .callbacks_completed = self.callbacks_completed.load(.acquire),
            .quanta_entered = self.quanta_entered.load(.acquire),
            .quanta_completed = self.quanta_completed.load(.acquire),
            .events_attempted = self.events_attempted.load(.acquire),
            .events_published = self.write_cursor.load(.acquire),
            .events_consumed = self.read_cursor.load(.acquire),
            .dropped_events = self.dropped_events.load(.acquire),
        };
    }
    /// Queue-independent release/acquire publication. The full queue cannot
    /// hide a failure or closure. Safe while producer continues ordinary audio.
    pub fn terminal(self: *const Bridge, session: Session) Error!?Terminal {
        try self.validate(session);
        if (!self.closed.load(.acquire)) return null;
        return self.terminal_value;
    }
    fn validate(self: *const Bridge, session: Session) Error!void {
        if (session.bridge != self or session.incarnation == 0 or session.incarnation != self.incarnation.load(.acquire) or session.generation == 0 or session.generation != self.generation.load(.acquire)) return error.StaleSession;
    }
    fn validateOwner(self: *const Bridge, session: Session, owner: *const anyopaque) Error!void {
        try self.validate(session);
        if (self.owner != owner) return error.InvalidState;
    }
    // Only producer or quiescent host writes failure: first failure sticks.
    fn fail(self: *Bridge, failure: Failure) void {
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
    fn publish(self: *Bridge, session: Session, kind: Kind, frames: u32, channels: u16, observation: Observation) void {
        const sequence = self.events_attempted.load(.monotonic);
        if (sequence == std.math.maxInt(u64)) {
            self.fail(.counter_exhausted);
            self.bump(&self.dropped_events);
            return;
        }
        self.events_attempted.store(sequence + 1, .release);
        const write = self.write_cursor.load(.monotonic);
        const read = self.read_cursor.load(.acquire);
        if (write == std.math.maxInt(u64) or write - read == slot_capacity) {
            self.fail(if (write == std.math.maxInt(u64)) .counter_exhausted else .queue_full);
            self.bump(&self.dropped_events);
            return;
        }
        self.slots[@intCast(write % slot_capacity)] = .{
            .incarnation = session.incarnation,
            .generation = session.generation,
            .sequence = sequence + 1,
            .kind = kind,
            .source = self.source,
            .callback_index = self.callbacks_entered.load(.monotonic),
            .quantum_index = self.quanta_entered.load(.monotonic),
            .requested_frames = frames,
            .channels = channels,
            .observation = observation,
        };
        if (@import("builtin").is_test) if (self.test_before_publish_hook) |hook| hook.call(hook.context, self, self.slots[@intCast(write % slot_capacity)]);
        self.write_cursor.store(write + 1, .release);
    }
    fn close(self: *Bridge, reason: CloseReason, observation: Observation) void {
        if (self.callback_open or self.quantum_open or self.callbacks_entered.load(.monotonic) != self.callbacks_completed.load(.monotonic) or self.quanta_entered.load(.monotonic) != self.quanta_completed.load(.monotonic)) self.fail(.interrupted);
        const cancelled = self.cancel_requested.load(.acquire);
        if (cancelled) self.fail(.cancelled);
        const failure = self.failure.load(.monotonic);
        self.terminal_value = .{
            .incarnation = self.incarnation.load(.monotonic),
            .generation = self.generation.load(.monotonic),
            .reason = if (cancelled) .cancelled else reason,
            .incomplete = failure != .none,
            .failure = failure,
            .callbacks_entered = self.callbacks_entered.load(.monotonic),
            .callbacks_completed = self.callbacks_completed.load(.monotonic),
            .quanta_entered = self.quanta_entered.load(.monotonic),
            .quanta_completed = self.quanta_completed.load(.monotonic),
            .events_attempted = self.events_attempted.load(.monotonic),
            .events_published = self.write_cursor.load(.monotonic),
            .dropped_events = self.dropped_events.load(.monotonic),
            .observation = observation,
        };
        self.closed.store(true, .release);
    }
};

pub const event_bytes: usize = @sizeOf(Event);
pub const slot_storage_bytes: usize = slot_capacity * event_bytes;
pub const bridge_bytes: usize = @sizeOf(Bridge);

// Conservative static operation bounds for the added production instrumentation,
// including the renderer's three atomic observation loads per boundary, error
// reporting and terminal publication. Existing audio/accounting atomics and
// test-only hooks are excluded. Each generated quantum adds its own bound;
// pending-only callbacks therefore pay no quantum bound. No loop is added.
pub const max_atomic_ops_per_callback: usize = 72;
pub const max_atomic_ops_per_quantum: usize = 40;
