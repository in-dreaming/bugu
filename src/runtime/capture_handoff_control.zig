//! Internal bounded continuous-capture control. No recording wire grammar.
//! PinFailureAtomic is initialized in place and retained through every bridge
//! detach AND the actual sink writer return/join. A failed flag or producer ack
//! never releases a borrow and never proves a coherent final engine frontier.
const std = @import("std");

pub const version: u32 = 1;
pub const event_limit: u64 = 65_536;
pub const Producer = enum(u8) { frontier, acceptance, readiness, render };
pub const Failure = enum(u8) { none, producer_failure, queue_full, event_budget, counter_exhausted, cancelled, writer_failure, transport_failure, dependency_budget, byte_budget, invalid_state };
pub const Error = error{ InvalidState, StaleSession, IdentityExhausted, ConcurrentLifecycle };
pub const Descriptor = struct { version: u32 = 1, incarnation: u64, interval_id: u64, event_limit: u64 = 65_536 };
pub const Session = struct { state: *PinFailureAtomic, descriptor: Descriptor };
pub const Acknowledgement = struct { events_attempted: u64, events_published: u64 };
const AckSlot = struct { ready: std.atomic.Value(bool) = .init(false), value: Acknowledgement = undefined };
var next_incarnation: std.atomic.Value(u64) = .init(1);

pub const PinFailureAtomic = struct {
    // Immutable after initExclusive. Host lifecycle excludes initialization,
    // configuration and consumer/request callers. Never reinitialize in place.
    descriptor: Descriptor = .{ .incarnation = 0, .interval_id = 0 },
    pinned_address: ?*const PinFailureAtomic = null,
    failure_value: std.atomic.Value(Failure) = .init(.none),
    acknowledgements: [4]AckSlot = .{ .{}, .{}, .{}, .{} },
    // Host-only one-shot attachment slots: a bridge generation cannot silently
    // restart an already used producer within the same capture identity.
    producer_bound: [4]bool = .{ false, false, false, false },

    pub fn initExclusive(self: *PinFailureAtomic, interval_id: u64) Error!Session {
        if (self.descriptor.incarnation != 0 or interval_id == 0) return error.InvalidState;
        const incarnation = next_incarnation.load(.acquire);
        if (incarnation == std.math.maxInt(u64)) return error.IdentityExhausted;
        if (next_incarnation.cmpxchgStrong(incarnation, incarnation + 1, .acq_rel, .acquire) != null) return error.ConcurrentLifecycle;
        self.descriptor = .{ .incarnation = incarnation, .interval_id = interval_id };
        self.pinned_address = self;
        return .{ .state = self, .descriptor = self.descriptor };
    }
};

pub fn validate(session: Session) Error!void {
    if (session.state.pinned_address != session.state or session.descriptor.version != version or session.descriptor.incarnation == 0 or session.descriptor.interval_id == 0 or session.descriptor.event_limit != event_limit or !std.meta.eql(session.descriptor, session.state.descriptor)) return error.StaleSession;
}
pub fn sameSession(a: Session, b: Session) bool {
    validate(a) catch return false;
    validate(b) catch return false;
    return a.state == b.state and std.meta.eql(a.descriptor, b.descriptor);
}
/// Multi-writer sticky publication. Exactly one strong CAS, never a retry loop.
/// A losing publisher leaves the already published failure unchanged.
pub fn fail(session: Session, reason: Failure) Error!void {
    try validate(session);
    if (reason == .none) return error.InvalidState;
    _ = session.state.failure_value.cmpxchgStrong(.none, reason, .acq_rel, .acquire);
}
pub fn failure(session: Session) Error!Failure {
    try validate(session);
    return session.state.failure_value.load(.acquire);
}
/// Only the named producer may publish its slot, after its in-flight operation
/// and all evidence construction have finished. This is not a successful close.
pub fn acknowledgeProducer(session: Session, producer: Producer, value: Acknowledgement) Error!void {
    try validate(session);
    if (try failure(session) == .none or value.events_published > value.events_attempted) return error.InvalidState;
    const slot = &session.state.acknowledgements[@intFromEnum(producer)];
    if (slot.ready.load(.monotonic)) return; // immutable first acknowledgement
    slot.value = value;
    slot.ready.store(true, .release);
}
pub fn acknowledgement(session: Session, producer: Producer) Error!?Acknowledgement {
    try validate(session);
    const slot = &session.state.acknowledgements[@intFromEnum(producer)];
    if (!slot.ready.load(.acquire)) return null;
    return slot.value;
}
/// Runtime lifecycle only, before mutating a bridge attachment.
pub fn validateAttachment(session: Session, producer: Producer, interval_id: u64) Error!void {
    try validate(session);
    if (session.descriptor.interval_id != interval_id) return error.StaleSession;
    if (try failure(session) != .none or session.state.producer_bound[@intFromEnum(producer)]) return error.InvalidState;
}
/// Called only after all attach validation/allocation that can fail has passed.
pub fn bindProducer(session: Session, producer: Producer) void {
    session.state.producer_bound[@intFromEnum(producer)] = true;
}
/// Checked peer mode/identity comparison for lifecycle wrappers. Legacy peers
/// must all be legacy; continuous peers must use the exact same pinned state.
pub fn validatePeers(a: ?Session, b: ?Session) Error!void {
    if (a) |left| {
        const right = b orelse return error.InvalidState;
        if (!sameSession(left, right)) return error.StaleSession;
    } else if (b != null) return error.InvalidState;
}
pub const shared_control_bytes: usize = @sizeOf(PinFailureAtomic);
pub const acknowledgement_bytes: usize = @sizeOf([4]AckSlot);
