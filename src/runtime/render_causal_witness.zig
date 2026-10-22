//! Bounded, opt-in evidence from actual Render reads. Not a recording profile.
//! The first binding is deliberately direct-Render-only. No callback, device
//! delivery, readiness, reclamation, cancellation or whole-runtime proof is
//! implied by a complete terminal. The reconstruction harness must additionally
//! validate its supported operation set and close/join both Control producers.
//!
//! One serialized Render producer, one serialized consumer. Host lifecycle
//! requires genuine device/renderer quiescence, Control exclusion, and external
//! exclusion of consumer/request/direct callers. Storage remains pinned until
//! explicit close + drain + detach. The terminal does not release ownership.
const std = @import("std");
const capture = @import("sme-capture-handoff-control");
pub const scheduler_observation = @import("sme-scheduler").render_observation;
pub const stream_observation = @import("sme-streaming").stream.render_observation;

pub const slot_capacity: usize = 256;
pub const events_per_call: u32 = 64;
pub const events_per_session: u64 = 4096;
pub const max_event_bytes: usize = 512;
pub const slots_per_chunk: usize = 4;
pub const Error = error{ InvalidState, StaleSession, Undrained, IdentityExhausted, ConcurrentLifecycle };
var next_incarnation: std.atomic.Value(u64) = .init(1);
var next_owner_identity: std.atomic.Value(u64) = .init(1);
fn claim(counter: *std.atomic.Value(u64)) Error!u64 {
    const value = counter.load(.acquire);
    if (value == std.math.maxInt(u64)) return error.IdentityExhausted;
    if (counter.cmpxchgStrong(value, value + 1, .acq_rel, .acquire) != null) return error.ConcurrentLifecycle;
    return value;
}
pub fn allocateOwnerIdentity() Error!u64 {
    return claim(&next_owner_identity);
}

/// Owned session identities only: no live/possibly dangling addresses in tape.
pub const ControlSession = struct { incarnation: u64, generation: u64, owner_identity: u64, interval_id: u64 };
pub const Manifest = struct {
    /// Only COMPLETE retained-block cancel_too_late; all other cancellation remains unsupported.
    capture_terminal_invalidations: bool = false,
    capture_reconciliation: bool = false,
    interval_id: u64,
    renderer_identity: u64,
    control_frontier: ControlSession,
    stream_acceptance: ControlSession,
    music_handle_incarnation: u32,
    music_context: u64,
    sample_rate: u32,
    channels: u16,
    initial_frame: u64,
    initial_call_sequence: u64,
    initial_gate: u64,
    transport_epoch: u64,
    asset_generation: u64,
    /// Binding is verified by the RuntimeRenderer host wrapper. Callback and
    /// adapter calls are explicitly unsupported, not inferred from counters.
    mode: enum(u8) { direct_render } = .direct_render,
};
pub const Session = struct { bridge: *const Bridge, incarnation: u64, generation: u64, renderer_identity: u64, interval_id: u64 };
pub const Failure = enum(u8) {
    none,
    queue_full,
    call_budget,
    session_budget,
    counter_exhausted,
    interrupted,
    invalid_call,
    render_error,
    cancelled,
    unsupported_adapter,
    unsupported_shutdown,
    unsupported_replay,
    unsupported_immediate,
    unsupported_invalidation,
    unsupported_epoch,
    unsupported_binding,
    capture_failed,
};
pub const CloseReason = enum(u8) { producer_boundary, host_quiescent, cancelled };
pub const StreamMode = enum(u8) { absent, live, replay };
pub const CallBegin = struct { requested_frames: u32, channels: u16, valid: bool };
pub const CallEnd = struct { frame_end: u64, completed: bool, error_code: u32 };
pub const ResourceKind = enum { completion_enqueue, group_pin_publish, group_pin_return };
pub const CallSubstage = enum { before_gate, in_gate, after_gate };
pub const ResourceEvent = struct {
    kind: ResourceKind,
    substage: CallSubstage = .before_gate,
    group_index: u16 = 0,
    group_generation: u64 = 0,
    bank_generation: u64 = 0,
    context: u64 = 0,
    instance_index: u16 = 0,
    instance_generation: u16 = 0,
    reservation: u64 = 0,
    start_order: u64 = 0,
    play_index: u16 = 0,
    mask_before: u16 = 0,
    mask_after: u16 = 0,
    queue_read: u64 = 0,
    queue_write: u64 = 0,
    queue_after: u64 = 0,
    completion_reason: u8 = 0,
};
pub const Payload = union(enum) {
    call_begin: CallBegin,
    call_end: CallEnd,
    gate_begin: StreamMode,
    gate_end: u64,
    frontier: stream_observation.Frontier,
    stream_attempt: stream_observation.Attempt,
    scan_chunk: scheduler_observation.ScanChunk,
    invalidation_poll: scheduler_observation.InvalidationPoll,
    invalidation_result: scheduler_observation.InvalidationResult,
    resource: ResourceEvent,
};
pub const Kind = std.meta.Tag(Payload);
pub const Event = struct {
    incarnation: u64,
    generation: u64,
    /// Producer-local successful/reserved attempt order, never global causality.
    sequence: u64,
    /// The real odd RuntimeRenderer call sequence, including invalid calls.
    render_call_sequence: u64,
    gate: u64,
    frame: u64,
    gate_order: u32,
    payload: Payload,
};
comptime {
    if (@sizeOf(Event) > max_event_bytes) @compileError("Render causal Event exceeds the 512-byte representation bound");
    if (scheduler_observation.slots_per_chunk != slots_per_chunk) @compileError("Render causal scan chunk mismatch");
}
pub const Status = struct {
    closed: bool,
    incomplete: bool,
    failure: Failure,
    calls_opened: u64,
    calls_closed: u64,
    events_attempted: u64,
    events_published: u64,
    events_consumed: u64,
    /// A refused reservation, not an invented count of the unobserved suffix.
    refused_events: u64,
    suppressed_work: bool,
};
pub const Terminal = struct {
    incarnation: u64,
    generation: u64,
    manifest: Manifest,
    reason: CloseReason,
    incomplete: bool,
    failure: Failure,
    calls_opened: u64,
    calls_closed: u64,
    events_attempted: u64,
    events_published: u64,
    refused_events: u64,
    suppressed_work: bool,
    final_frame: u64,
    final_call_sequence: u64,
    final_gate: u64,
};

pub const Bridge = struct {
    /// Detached setup field; changing it cannot alter an attached generation.
    configured_continuous: ?capture.Session = null,
    // Frozen producer binding. Only attach/detach may replace this handle.
    continuous: ?capture.Session = null,
    /// Set only while detached, then frozen in the manifest.
    capture_terminal_invalidations: bool = false,
    capture_reconciliation: bool = false,
    slots: [slot_capacity]Event = undefined,
    incarnation: std.atomic.Value(u64) = .init(0),
    generation: std.atomic.Value(u64) = .init(0),
    write_cursor: std.atomic.Value(u64) = .init(0),
    read_cursor: std.atomic.Value(u64) = .init(0),
    closed: std.atomic.Value(bool) = .init(true),
    stop_requested: std.atomic.Value(bool) = .init(false),
    cancel_requested: std.atomic.Value(bool) = .init(false),
    failure: std.atomic.Value(Failure) = .init(.none),
    calls_opened: std.atomic.Value(u64) = .init(0),
    calls_closed: std.atomic.Value(u64) = .init(0),
    events_attempted: std.atomic.Value(u64) = .init(0),
    refused_events: std.atomic.Value(u64) = .init(0),
    suppressed_work: std.atomic.Value(bool) = .init(false),
    // Producer-only until true host quiescence. Consumer never reads these.
    owner: ?*const anyopaque = null,
    manifest: Manifest = undefined,
    producer_incarnation: u64 = 0,
    producer_generation: u64 = 0,
    producer_write: u64 = 0,
    producer_attempted: u64 = 0,
    capture_enabled: bool = false,
    call_open: bool = false,
    gate_open: bool = false,
    call_substage: CallSubstage = .before_gate,
    reservation_open: bool = false,
    call_events: u32 = 0,
    call_sequence: u64 = 0,
    last_complete_sequence: u64 = 0,
    frame: u64 = 0,
    gate: u64 = 0,
    gate_order: u32 = 0,
    terminal_value: Terminal = undefined,

    pub fn configureContinuous(self: *Bridge, session: ?capture.Session) Error!void {
        if (self.owner != null or !self.closed.load(.acquire)) return error.InvalidState;
        if (self.read_cursor.load(.acquire) != self.write_cursor.load(.acquire)) return error.Undrained;
        if (session) |value| try capture.validateAttachment(value, .render, value.descriptor.interval_id);
        self.configured_continuous = session;
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
            if (self.failure.load(.monotonic) == .none) self.failure.store(.capture_failed, .release);
            self.capture_enabled = false;
            self.suppressed_work.store(true, .release);
            return true;
        }
        return false;
    }
    fn acknowledgeContinuousFailure(self: *Bridge) void {
        if (self.call_open or self.gate_open or self.reservation_open or !self.observeContinuousFailure()) return;
        capture.acknowledgeProducer(self.continuous.?, .render, .{ .events_attempted = self.producer_attempted, .events_published = self.producer_write }) catch {};
    }

    /// Runtime lifecycle only. The wrapper checks all live bindings while
    /// holding actual device quiescence and the Control guard.
    pub fn attachQuiescent(self: *Bridge, owner: *const anyopaque, manifest: Manifest) Error!Session {
        if (self.owner != null or !self.closed.load(.acquire) or manifest.interval_id == 0 or manifest.renderer_identity == 0 or manifest.initial_call_sequence & 1 != 0) return error.InvalidState;
        if (manifest.control_frontier.interval_id != manifest.interval_id or manifest.stream_acceptance.interval_id != manifest.interval_id) return error.InvalidState;
        if (self.read_cursor.load(.acquire) != self.write_cursor.load(.acquire)) return error.Undrained;
        if (self.configured_continuous) |session| try capture.validateAttachment(session, .render, manifest.interval_id);
        const old_generation = self.generation.load(.monotonic);
        if (old_generation == std.math.maxInt(u64)) return error.IdentityExhausted;
        var incarnation = self.incarnation.load(.monotonic);
        if (incarnation == 0) {
            incarnation = try claim(&next_incarnation);
            self.incarnation.store(incarnation, .release);
        }
        if (self.configured_continuous) |session| capture.bindProducer(session, .render);
        self.continuous = self.configured_continuous;
        self.configured_continuous = null; // consume the setup borrow
        self.owner = owner;
        self.manifest = manifest;
        self.manifest.capture_terminal_invalidations = self.capture_terminal_invalidations;
        self.manifest.capture_reconciliation = self.capture_reconciliation;
        self.producer_incarnation = incarnation;
        self.producer_generation = old_generation + 1;
        self.producer_write = 0;
        self.producer_attempted = 0;
        self.capture_enabled = true;
        self.call_open = false;
        self.gate_open = false;
        self.reservation_open = false;
        self.call_events = 0;
        self.call_sequence = manifest.initial_call_sequence;
        self.last_complete_sequence = manifest.initial_call_sequence;
        self.frame = manifest.initial_frame;
        self.gate = manifest.initial_gate;
        self.gate_order = 0;
        self.write_cursor.store(0, .monotonic);
        self.read_cursor.store(0, .monotonic);
        self.stop_requested.store(false, .monotonic);
        self.cancel_requested.store(false, .monotonic);
        self.failure.store(.none, .monotonic);
        self.calls_opened.store(0, .monotonic);
        self.calls_closed.store(0, .monotonic);
        self.events_attempted.store(0, .monotonic);
        self.refused_events.store(0, .monotonic);
        self.suppressed_work.store(false, .monotonic);
        self.closed.store(false, .monotonic);
        self.generation.store(old_generation + 1, .release);
        return .{ .bridge = self, .incarnation = incarnation, .generation = old_generation + 1, .renderer_identity = manifest.renderer_identity, .interval_id = manifest.interval_id };
    }
    pub fn requestStop(self: *Bridge, session: Session) Error!void {
        try self.validate(session);
        if (self.closed.load(.acquire)) return error.InvalidState;
        if (self.continuous) |value| {
            try capture.fail(value, .cancelled);
            return;
        }
        self.stop_requested.store(true, .release);
    }
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
    /// Render owner only. The false return leaves the actual audio untouched.
    pub fn beginCall(self: *Bridge, sequence: u64, frame: u64, frames: u32, channels: u16, valid: bool, observable: bool) bool {
        if (self.closed.load(.acquire)) return false;
        // Runtime has already admitted the real operation. Even if failure
        // predates this call, retain its end hook and acknowledge only there.
        _ = self.observeContinuousFailure();
        if (self.call_open) {
            self.markIncomplete(.interrupted);
            return false;
        }
        // RuntimeRenderer has already entered the real odd call sequence.
        // Even a request predating entry is acknowledged only by endCall after
        // its actual even completion store, never from inside this active call.
        self.call_open = true;
        self.call_substage = .before_gate;
        self.call_events = 0;
        self.bump(&self.calls_opened);
        if (!observable or sequence == 0 or sequence & 1 == 0) self.markIncomplete(.counter_exhausted);
        if (self.last_complete_sequence == std.math.maxInt(u64) or sequence != self.last_complete_sequence + 1 or frame != self.frame) self.markIncomplete(.interrupted);
        self.call_sequence = sequence;
        self.frame = frame;
        if (self.reserve(.call_begin)) |event| {
            event.payload.call_begin = .{ .requested_frames = frames, .channels = channels, .valid = valid };
            self.publish();
        }
        if (!valid) self.markIncomplete(.invalid_call);
        return true;
    }
    pub fn endCall(self: *Bridge, frame_end: u64, completed: bool, error_code: u32, complete_sequence: u64) void {
        if (!self.call_open) return;
        if (self.gate_open or self.reservation_open) self.markIncomplete(.interrupted);
        if (!completed) self.markIncomplete(.render_error);
        if (self.reserve(.call_end)) |event| {
            event.payload.call_end = .{ .frame_end = frame_end, .completed = completed, .error_code = error_code };
            self.publish();
        }
        self.frame = frame_end;
        self.last_complete_sequence = complete_sequence;
        self.call_open = false;
        self.bump(&self.calls_closed);
        self.acknowledgeContinuousFailure();
        if (self.stop_requested.load(.acquire)) self.close(.producer_boundary);
    }
    pub fn beginGate(self: *Bridge, gate: u64, frame: u64, mode: StreamMode) void {
        if (!self.call_open) return;
        if (self.gate_open or self.gate == std.math.maxInt(u64) or gate != self.gate + 1) self.markIncomplete(.interrupted);
        self.gate_open = true;
        self.call_substage = .in_gate;
        self.gate = gate;
        self.frame = frame;
        self.gate_order = 0;
        if (self.reserve(.gate_begin)) |event| {
            event.payload.gate_begin = mode;
            self.publish();
        }
        if (mode == .replay) self.markIncomplete(.unsupported_replay);
    }
    pub fn endGate(self: *Bridge, frame_end: u64, order: u32) void {
        if (!self.call_open) return;
        self.gate_order = order;
        if (!self.gate_open) self.markIncomplete(.interrupted);
        if (self.reserve(.gate_end)) |event| {
            event.payload.gate_end = frame_end;
            self.publish();
        }
        self.frame = frame_end;
        self.gate_open = false;
        self.call_substage = .after_gate;
    }
    pub fn observeResource(self: *Bridge, value: ResourceEvent) void {
        if (!self.manifest.capture_reconciliation) return;
        if (self.reserve(.resource)) |event| {
            event.payload.resource = value;
            event.payload.resource.substage = self.call_substage;
            self.publish();
        }
    }
    /// Reserve BEFORE Service executes/builds the optional observation. Payload
    /// lives directly in the unpublished ring slot: no Event-sized RT scratch.
    pub fn reserveFrontier(self: *Bridge) ?*stream_observation.Frontier {
        const event = self.reserve(.frontier) orelse return null;
        return &event.payload.frontier;
    }
    pub fn finishFrontier(self: *Bridge) void {
        self.publish();
    }
    pub fn reserveStreamAttempt(self: *Bridge, order: u32) ?*stream_observation.Attempt {
        self.gate_order = order;
        const event = self.reserve(.stream_attempt) orelse return null;
        return &event.payload.stream_attempt;
    }
    pub fn finishStreamAttempt(self: *Bridge, failed: bool) void {
        self.publish();
        if (failed) self.markIncomplete(.render_error);
    }
    pub fn reserveInvalidationPoll(self: *Bridge, order: u32) ?*scheduler_observation.InvalidationPoll {
        self.gate_order = order;
        const event = self.reserve(.invalidation_poll) orelse return null;
        return &event.payload.invalidation_poll;
    }
    pub fn finishInvalidationPoll(self: *Bridge) void {
        self.publish();
    }
    pub fn reserveInvalidationResult(self: *Bridge, order: u32) ?*scheduler_observation.InvalidationResult {
        self.gate_order = order;
        const event = self.reserve(.invalidation_result) orelse return null;
        return &event.payload.invalidation_result;
    }
    pub fn finishInvalidationResult(self: *Bridge, supported: bool) void {
        self.publish();
        if (!supported) self.markIncomplete(.unsupported_invalidation);
    }
    pub fn scanSink(self: *Bridge) scheduler_observation.Sink {
        return .{ .context = self, .begin_chunk = beginScanChunk, .end_chunk = endScanChunk };
    }
    fn beginScanChunk(context: *anyopaque, _: u16, order: u32) ?*scheduler_observation.ScanChunk {
        const self: *Bridge = @ptrCast(@alignCast(context));
        self.gate_order = order;
        const event = self.reserve(.scan_chunk) orelse return null;
        return &event.payload.scan_chunk;
    }
    fn endScanChunk(context: *anyopaque, _: *const scheduler_observation.ScanChunk) bool {
        const self: *Bridge = @ptrCast(@alignCast(context));
        self.publish();
        return self.capture_enabled;
    }
    /// Only the Render producer or genuinely quiescent host may report loss.
    /// First failure permanently stops further payload construction this session.
    pub fn markIncomplete(self: *Bridge, reason: Failure) void {
        if (reason == .none or !self.capture_enabled) return;
        if (self.continuous) |session| capture.fail(session, .producer_failure) catch {};
        self.failure.store(reason, .release);
        self.capture_enabled = false;
        self.suppressed_work.store(true, .release);
    }
    fn reserve(self: *Bridge, comptime kind: Kind) ?*Event {
        if (self.observeContinuousFailure() or !self.capture_enabled or !self.call_open) return null;
        self.producer_attempted = std.math.add(u64, self.producer_attempted, 1) catch {
            self.markIncomplete(.counter_exhausted);
            return null;
        };
        self.events_attempted.store(self.producer_attempted, .release);
        if (self.reservation_open) {
            self.markIncomplete(.interrupted);
            return null;
        }
        const limit = if (self.continuous) |session| session.descriptor.event_limit else events_per_session;
        const failure: Failure = if (self.producer_write == std.math.maxInt(u64)) .counter_exhausted else if (self.call_events == events_per_call) .call_budget else if (self.producer_write >= limit) .session_budget else if (self.producer_write - self.read_cursor.load(.acquire) == slot_capacity) .queue_full else .none;
        if (failure != .none) {
            self.refused_events.store(1, .release);
            self.markIncomplete(failure);
            return null;
        }
        self.reservation_open = true;
        const slot = &self.slots[@intCast(self.producer_write % slot_capacity)];
        slot.incarnation = self.producer_incarnation;
        slot.generation = self.producer_generation;
        slot.sequence = self.producer_attempted;
        slot.render_call_sequence = self.call_sequence;
        slot.gate = self.gate;
        slot.frame = self.frame;
        slot.gate_order = self.gate_order;
        slot.payload = @unionInit(Payload, @tagName(kind), undefined);
        return slot;
    }
    fn publish(self: *Bridge) void {
        if (!self.reservation_open) return;
        self.reservation_open = false;
        if (self.observeContinuousFailure()) return;
        self.producer_write += 1;
        self.call_events += 1;
        self.write_cursor.store(self.producer_write, .release);
    }
    fn bump(self: *Bridge, counter: *std.atomic.Value(u64)) void {
        const value = counter.load(.monotonic);
        if (value == std.math.maxInt(u64)) {
            self.markIncomplete(.counter_exhausted);
            return;
        }
        counter.store(value + 1, .release);
    }
    pub fn closeQuiescent(self: *Bridge, session: Session, owner: *const anyopaque, frame: u64, sequence: u64, gate: u64) Error!void {
        try self.validateOwner(session, owner);
        if (self.closed.load(.acquire)) return;
        if (frame != self.frame or sequence != self.last_complete_sequence or gate != self.gate) self.markIncomplete(.interrupted);
        self.frame = frame;
        self.last_complete_sequence = sequence;
        self.gate = gate;
        self.close(.host_quiescent);
    }
    pub fn detachQuiescent(self: *Bridge, session: Session, owner: *const anyopaque) Error!void {
        try self.validateOwner(session, owner);
        if (!self.closed.load(.acquire)) return error.InvalidState;
        if (self.read_cursor.load(.acquire) != self.write_cursor.load(.acquire)) return error.Undrained;
        self.owner = null;
        self.continuous = null;
        self.configured_continuous = null; // no hidden borrow after detach
    }
    pub fn pop(self: *Bridge, session: Session) Error!?Event {
        try self.validate(session);
        const read = self.read_cursor.load(.monotonic);
        if (read == self.write_cursor.load(.acquire)) return null;
        const event = self.slots[@intCast(read % slot_capacity)];
        self.read_cursor.store(read + 1, .release);
        return event;
    }
    /// Live fields are individually published, not a coherent snapshot.
    pub fn status(self: *const Bridge, session: Session) Error!Status {
        try self.validate(session);
        const local_failure = self.failure.load(.acquire);
        const failure: Failure = if (local_failure != .none) local_failure else if (self.continuous) |value| (if ((capture.failure(value) catch .invalid_state) != .none) .capture_failed else .none) else .none;
        return .{ .closed = self.closed.load(.acquire), .incomplete = failure != .none, .failure = failure, .calls_opened = self.calls_opened.load(.acquire), .calls_closed = self.calls_closed.load(.acquire), .events_attempted = self.events_attempted.load(.acquire), .events_published = self.write_cursor.load(.acquire), .events_consumed = self.read_cursor.load(.acquire), .refused_events = self.refused_events.load(.acquire), .suppressed_work = self.suppressed_work.load(.acquire) };
    }
    pub fn terminal(self: *const Bridge, session: Session) Error!?Terminal {
        try self.validate(session);
        if (!self.closed.load(.acquire)) return null;
        return self.terminal_value;
    }
    fn validate(self: *const Bridge, session: Session) Error!void {
        if (session.bridge != self or session.incarnation == 0 or session.incarnation != self.incarnation.load(.acquire) or session.generation == 0 or session.generation != self.generation.load(.acquire)) return error.StaleSession;
        // Immutable during attachment; lifecycle must exclude consumer/requests.
        if (session.renderer_identity != self.manifest.renderer_identity or session.interval_id != self.manifest.interval_id) return error.StaleSession;
    }
    fn validateOwner(self: *const Bridge, session: Session, owner: *const anyopaque) Error!void {
        try self.validate(session);
        if (self.owner != owner) return error.InvalidState;
    }
    fn close(self: *Bridge, reason: CloseReason) void {
        _ = self.observeContinuousFailure();
        if (self.call_open or self.gate_open or self.reservation_open or self.calls_opened.load(.monotonic) != self.calls_closed.load(.monotonic)) self.markIncomplete(.interrupted);
        const cancelled = self.cancel_requested.load(.acquire);
        if (cancelled) self.markIncomplete(.cancelled);
        const failure = self.failure.load(.monotonic);
        self.terminal_value = .{ .incarnation = self.producer_incarnation, .generation = self.producer_generation, .manifest = self.manifest, .reason = if (cancelled) .cancelled else reason, .incomplete = failure != .none, .failure = failure, .calls_opened = self.calls_opened.load(.monotonic), .calls_closed = self.calls_closed.load(.monotonic), .events_attempted = self.producer_attempted, .events_published = self.producer_write, .refused_events = self.refused_events.load(.monotonic), .suppressed_work = self.suppressed_work.load(.monotonic), .final_frame = self.frame, .final_call_sequence = self.last_complete_sequence, .final_gate = self.gate };
        self.capture_enabled = false;
        self.acknowledgeContinuousFailure();
        self.closed.store(true, .release);
    }
};

// Target ABI values, not total stack high-water/latency estimates. Observation
// payloads are constructed in reserved unpublished slots; no staging Event is
// passed by value on Render. pop's owned copy belongs to the host consumer.
pub const event_bytes: usize = @sizeOf(Event);
pub const slot_storage_bytes: usize = @sizeOf([slot_capacity]Event);
pub const bridge_bytes: usize = @sizeOf(Bridge);
pub const producer_event_scratch_bytes: usize = 0;
pub const scan_sink_scratch_bytes: usize = @sizeOf(scheduler_observation.Sink);
pub const max_published_payload_bytes_per_call: usize = events_per_call * max_event_bytes;
pub const max_published_payload_bytes_per_session: usize = events_per_session * max_event_bytes;
// These payload-volume bounds are not store-traffic estimates: default
// initialization and individual field assignments can write a byte repeatedly.
// Per successful reserve/publication: attempted release-store, read-cursor
// acquire-load, write-cursor release-store (three new atomics). Quota refusal
// skips the cursor read; failure adds fixed flag publication, no CAS/retry.
pub const queue_atomic_ops_per_event: usize = 3;

// Continuous mode adds one shared-failure acquire per reserve and per publish.
// The bounded call-boundary checks and first-failure/ack publications are extra.
pub const continuous_shared_loads_per_published_event: usize = 2;
pub const continuous_max_published_payload_bytes: usize = capture.event_limit * max_event_bytes;
