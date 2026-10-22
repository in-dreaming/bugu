//! TASK-015 pure Control admission proposals, not a scheduler or runtime facade.
const std = @import("std");
const trace = @import("sme-trace").schema;
const types = @import("sme-policy-types").stinger;
pub const version = types.version;
pub const hard_max_stingers = types.hard_max_stingers;
pub const Error = types.Error;
pub const Sync = types.Sync;
pub const ConflictPolicy = types.ConflictPolicy;
pub const Policy = types.Policy;
/// Full identity belongs to the future owner; this module never mints epochs.
pub const Identity = struct {
    context: u64,
    asset_generation: u64,
    transport_epoch: u64,
    device_epoch: u64,
    pub fn validate(self: Identity) Error!void {
        if (self.context == 0 or self.asset_generation == 0 or self.transport_epoch == 0 or self.device_epoch == 0) return error.InvalidIdentity;
    }
};
pub const Request = struct { identity: Identity, position: trace.Position, request_id: u64, stinger_id: u64 };
pub const Previous = struct { request_id: u64, accepted_frame: u64 };
pub const Active = struct { request_id: u64, stinger_id: u64, accepted_frame: u64, priority: u8, protected: bool };
pub const Snapshot = struct { identity: Identity, active: []const Active, previous: ?Previous = null };
/// Caller-resolved actual clock candidate. Its kind is checked, not synthesized.
pub const BoundaryCandidate = struct { sync: Sync, frame: u64 };
pub const Reason = enum { deadline, repeat_window, polyphony, platform_limit, media_unready, no_replaceable_victim };
pub const Proposal = union(enum) {
    admit: struct { frame: u64, deadline: u64 },
    drop: Reason,
    replace: struct { victim_request_id: u64, frame: u64, deadline: u64, reason: Reason },
    @"defer": struct { not_before: u64, deadline: u64, reason: Reason },
};
pub const Decision = struct { request: Request, proposal: Proposal };
fn add(a: u64, b: u64) Error!u64 {
    const sum = @addWithOverflow(a, b);
    if (sum[1] != 0) return error.Overflow;
    return sum[0];
}
fn earlier(a: Active, b: Active) bool {
    return a.priority < b.priority or (a.priority == b.priority and (a.accepted_frame < b.accepted_frame or (a.accepted_frame == b.accepted_frame and a.request_id < b.request_id)));
}
/// O(64²) snapshot validation, O(64) decision. No allocation or mutation.
/// Admit means policy eligibility only, never renderer admission or playback.
pub fn decide(policy: Policy, max_stingers: u16, request: Request, snapshot: Snapshot, candidate: BoundaryCandidate, earliest_submit_frame: u64, media_ready: bool) Error!Decision {
    return decideAt(policy, max_stingers, request, snapshot, candidate, earliest_submit_frame, media_ready, null);
}
/// An owned retry observes the real current Control Position and transport.
/// The original acceptance/identity/deadline in Decision.request is unchanged.
/// This remains an eligibility proposal, never a source/scheduler reservation.
pub const Retry = struct { identity: Identity, position: trace.Position };
pub fn decideRetained(policy: Policy, max_stingers: u16, original: Request, snapshot: Snapshot, candidate: BoundaryCandidate, earliest_submit_frame: u64, media_ready: bool, retry: Retry) Error!Decision {
    try retry.identity.validate();
    if (retry.identity.context != original.identity.context or retry.identity.asset_generation != original.identity.asset_generation or
        retry.identity.device_epoch != original.identity.device_epoch or retry.identity.transport_epoch < original.identity.transport_epoch) return error.InvalidIdentity;
    if (retry.position.accepted_control_frame < original.position.accepted_control_frame or retry.position.control_tick < original.position.control_tick or
        (retry.position.control_tick == original.position.control_tick and retry.position.input_order < original.position.input_order)) return error.InvalidOrder;
    if (candidate.frame < retry.position.accepted_control_frame) return error.InvalidBoundary;
    return decideAt(policy, max_stingers, original, snapshot, candidate, earliest_submit_frame, media_ready, retry);
}
fn decideAt(policy: Policy, max_stingers: u16, request: Request, snapshot: Snapshot, candidate: BoundaryCandidate, earliest_submit_frame: u64, media_ready: bool, retry: ?Retry) Error!Decision {
    try policy.validate(max_stingers);
    try request.identity.validate();
    if (request.request_id == 0 or request.stinger_id == 0) return error.InvalidIdentity;
    const current_identity = if (retry) |current| current.identity else request.identity;
    const current_frame = if (retry) |current| current.position.accepted_control_frame else request.position.accepted_control_frame;
    if (!std.meta.eql(current_identity, snapshot.identity) or snapshot.active.len > max_stingers) return error.InvalidSnapshot;
    if (candidate.sync != policy.sync or candidate.frame < request.position.accepted_control_frame or candidate.frame < earliest_submit_frame) return error.InvalidBoundary;
    var same: usize = 0;
    for (snapshot.active, 0..) |entry, i| {
        if (entry.request_id == 0 or entry.stinger_id == 0 or entry.request_id == request.request_id or
            (retry == null and entry.request_id > request.request_id) or entry.accepted_frame > current_frame) return error.InvalidSnapshot;
        for (snapshot.active[0..i]) |prior| if (prior.request_id == entry.request_id) return error.InvalidSnapshot;
        same += @intFromBool(entry.stinger_id == request.stinger_id);
    }
    const deadline = try add(request.position.accepted_control_frame, policy.deadline_frames);
    var repeat_end: u64 = request.position.accepted_control_frame;
    var repeated = false;
    if (snapshot.previous) |last| {
        if (last.request_id == 0 or request.request_id == last.request_id or
            (retry == null and request.request_id < last.request_id) or last.accepted_frame > current_frame) return error.InvalidOrder;
        repeat_end = try add(last.accepted_frame, policy.repeat_frames);
        repeated = (if (retry != null) candidate.frame else request.position.accepted_control_frame) < repeat_end;
    }
    if (candidate.frame > deadline) return .{ .request = request, .proposal = .{ .drop = .deadline } };
    const reason: ?Reason = if (repeated) .repeat_window else if (same >= policy.max_polyphony) .polyphony else if (snapshot.active.len >= max_stingers) .platform_limit else if (!media_ready) .media_unready else null;
    if (reason == null) return .{ .request = request, .proposal = .{ .admit = .{ .frame = candidate.frame, .deadline = deadline } } };
    const why = reason.?;
    switch (policy.conflict) {
        .drop => return .{ .request = request, .proposal = .{ .drop = why } },
        .@"defer" => {
            const not_before = @max(candidate.frame, if (repeated) repeat_end else candidate.frame);
            return .{ .request = request, .proposal = if (not_before > deadline) .{ .drop = .deadline } else .{ .@"defer" = .{ .not_before = not_before, .deadline = deadline, .reason = why } } };
        },
        .replace => {
            if (!media_ready) return .{ .request = request, .proposal = .{ .drop = .media_unready } };
            var victim: ?Active = null;
            for (snapshot.active) |entry| {
                if (entry.protected or entry.priority > policy.priority) continue;
                if ((repeated or same >= policy.max_polyphony) and entry.stinger_id != request.stinger_id) continue;
                if (victim == null or earlier(entry, victim.?)) victim = entry;
            }
            if (victim) |v| return .{ .request = request, .proposal = .{ .replace = .{ .victim_request_id = v.request_id, .frame = candidate.frame, .deadline = deadline, .reason = why } } };
            return .{ .request = request, .proposal = .{ .drop = .no_replaceable_victim } };
        },
    }
}
