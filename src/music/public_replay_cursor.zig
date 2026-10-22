//! Allocation-free, incremental PUBLIC replay grammar validation only.
//! This does not drive a runtime or change the existing bounded recorder/API.
//! Feed decoded records in order, then call finish after transport completion.
//! An explicit runtime end is mandatory; a valid prefix is never complete.
const std = @import("std");
const trace = @import("sme-trace");
const schema = trace.schema;
pub const Profile = schema.RuntimeProfile;
pub const Error = schema.Error || schema.context_host.Error || error{ UnsupportedOperation, Overflow, InvalidState, WorkLimitExceeded };

fn isStream(profile: Profile) bool {
    return profile == .stream_serial_v1 or profile == .stream_direct_state_serial_v1 or profile == .stream_fill_state_serial_v1 or profile == .stream_context_serial_v1;
}
fn isStateProfile(profile: Profile) bool {
    return profile == .stream_direct_state_serial_v1 or profile == .stream_fill_state_serial_v1;
}

/// Fixed-size state, independent of recording length. No input or chunk storage
/// is retained. The caller supplies a total record/work budget explicitly; the
/// legacy schema.max_events envelope limit does not apply to this cursor.
///
/// With begin and records within the legacy limit, successful finish has the
/// same grammar acceptance as public_replay.validate. Explicit beginForProfile
/// additionally supports chunk-only profiles 4 and 7. The retained validator checks the
/// full sequence before its grammar pass; this cursor fails early, so errors can differ
/// for traces with multiple faults. Any feed/finish failure poisons the cursor.
/// This validates chronology, not snapshot bytes, recomputation or authenticity.
pub const Cursor = struct {
    max_records: u64,
    required_profile: ?Profile = null,
    records: u64 = 0,
    previous: ?schema.Position = null,
    admission: ?schema.Admission = null,
    context: u64 = 0,
    profile: Profile = .resident_serial_v1,
    kind: schema.RuntimeStepKind = .begin,
    tick: u64 = 0,
    frame: u64 = 0,
    call: u64 = 0,
    operation_serial: u64 = 1,
    operation: ?schema.StateHostOperation = null,
    context_journal: schema.context_host.Journal = .{},
    transaction: ?enum { capture, restore } = null,
    ticket: u64 = 0,
    terminal_polled: bool = false,
    captured: bool = false,
    restored: bool = false,
    resource: ?schema.lifecycle.SnapshotResource = null,
    ended: bool = false,
    finished: bool = false,
    poisoned: bool = false,

    pub fn begin(max_records: u64) Error!Cursor {
        if (max_records < 2) return error.InvalidCapacity;
        return .{ .max_records = max_records, .context_journal = try schema.context_host.Journal.init(@min(max_records, schema.context_host.max_operations)) };
    }

    /// Explicit bounded grammar opt-in. Every runtime step must match the
    /// selected profile; legacy begin still rejects profiles 4/7 at the first record.
    pub fn beginForProfile(max_records: u64, profile: Profile) Error!Cursor {
        if (profile != .resident_serial_v1 and !isStream(profile)) return error.UnknownVersion;
        var result = try begin(max_records);
        result.required_profile = profile;
        return result;
    }

    /// Chunk boundaries have no grammatical meaning, including between a host
    /// call, its facts and result. Empty chunks are permitted before finish.
    /// Work is linear in the slice length and cannot exceed the total budget.
    /// On error, earlier records in this call may have advanced state; retrying
    /// the suffix or a replacement chunk is forbidden on this poisoned cursor.
    pub fn feed(self: *Cursor, inputs: []const trace.Input) Error!void {
        if (self.poisoned) return error.InvalidState;
        errdefer self.poisoned = true;
        if (self.finished) return error.InvalidState;
        for (inputs) |input| {
            if (self.ended) return error.InvalidOrder;
            if (self.records >= self.max_records) return error.WorkLimitExceeded;
            try self.accept(input);
            self.records = try std.math.add(u64, self.records, 1);
        }
    }

    /// Call only once all chunks have been supplied. Missing begin/end, an open
    /// host call or an unacknowledged transaction can never certify completion.
    pub fn finish(self: *Cursor) Error!void {
        if (self.poisoned) return error.InvalidState;
        errdefer self.poisoned = true;
        if (self.finished) return error.InvalidState;
        if (self.records < 2 or !self.ended or self.operation != null or self.transaction != null) return error.IncompleteTrace;
        if (self.profile == .stream_context_serial_v1) try self.context_journal.finish();
        self.finished = true;
    }

    fn accept(self: *Cursor, input: trace.Input) Error!void {
        // Same per-record, Position and global admission-gate checks as the
        // legacy replay.validateSequence, carried across all chunk boundaries.
        try input.validate();
        if (self.previous) |p| {
            if (!schema.before(p, input.position) or input.position.accepted_control_frame < p.accepted_control_frame) return error.InvalidOrder;
        }
        self.previous = input.position;
        switch (input.payload) {
            .admission => |a| {
                if (self.admission) |g| {
                    if (a.gate < g.gate or a.frame < g.frame or (a.gate == g.gate and (a.frame != g.frame or a.gate_order <= g.gate_order or a.commit_horizon != g.commit_horizon))) return error.InvalidOrder;
                }
                self.admission = a;
            },
            .acoustic_observation => |v| if (v.hasLoss()) return error.IncompleteTrace,
            else => {},
        }
        if (self.records == 0) {
            if (input.payload != .runtime_step or input.payload.runtime_step.kind != .begin) return error.IncompleteTrace;
            self.context = input.payload.runtime_step.context;
            self.profile = input.payload.runtime_step.profile;
            if (self.required_profile) |expected| {
                if (self.profile != expected) return error.UnsupportedOperation;
            } else if (self.profile == .stream_fill_state_serial_v1 or self.profile == .stream_context_serial_v1) return error.UnsupportedOperation;
        }
        // Host calls are synchronous and have exactly one paired result. No
        // clock marker or ordinary fact may split that pair. Position carries
        // actual tick/frame; no Control input order is invented for Busy.
        if (self.profile == .stream_context_serial_v1 and input.payload != .context_host_operation)
            try self.context_journal.boundary();
        switch (input.payload) {
            .context_host_operation => |record| {
                if (self.profile != .stream_context_serial_v1) return error.UnsupportedOperation;
                if (input.position.control_tick != self.tick or input.position.accepted_control_frame != self.frame) return error.InvalidOrder;
                if (record == .call) {
                    const op = record.call;
                    if (op.context != self.context or op.render_call_sequence != self.call) return error.InvalidOrder;
                }
                try self.context_journal.accept(record);
                // The completed host operation closes the preceding tick's
                // ordinary fact scope; later facts need a real new tick.
                if (record == .result) self.kind = .begin;
            },
            .runtime_step => |step| {
                if (self.operation != null or step.context != self.context or step.profile != self.profile or (step.kind == .begin and self.records != 0)) return error.InvalidOrder;
                if (input.position.control_tick != self.tick or input.position.accepted_control_frame != self.frame or step.render_call_sequence != self.call) return error.InvalidOrder;
                switch (step.kind) {
                    .control_tick => self.tick = try std.math.add(u64, self.tick, 1),
                    .render => {
                        self.frame = try std.math.add(u64, self.frame, step.frame_count);
                        self.call = try std.math.add(u64, self.call, 2);
                    },
                    .end => {
                        if (self.transaction != null) return error.IncompleteTrace;
                        self.ended = true;
                    },
                    else => {},
                }
                self.kind = step.kind;
            },
            .state_host_operation => |record| {
                if (!isStateProfile(self.profile)) return error.UnsupportedOperation;
                if (input.position.control_tick != self.tick or input.position.accepted_control_frame != self.frame) return error.InvalidOrder;
                switch (record) {
                    .call => |op| {
                        if (self.operation != null or op.operation_serial != self.operation_serial or op.context != self.context or op.render_call_sequence != self.call) return error.InvalidOrder;
                        switch (op.kind) {
                            .capture_begin => if (self.transaction != null or self.captured or self.restored) return error.UnsupportedOperation,
                            .restore_submit => {
                                if (self.transaction != null or self.restored) return error.UnsupportedOperation;
                                if (self.resource) |known| if (!std.meta.eql(known, op.snapshot.?)) return error.ResourceNotPrepared;
                                self.resource = op.snapshot;
                            },
                            .capture_poll, .capture_ack => if (self.transaction != .capture or op.ticket != self.ticket) return error.InvalidOrder,
                            .restore_poll, .restore_ack => if (self.transaction != .restore or op.ticket != self.ticket) return error.InvalidOrder,
                        }
                        if ((op.kind == .capture_ack or op.kind == .restore_ack) and !self.terminal_polled) return error.IncompleteTrace;
                        self.operation = op;
                    },
                    .result => |result| {
                        const op = self.operation orelse return error.InvalidOrder;
                        if (result.operation_serial != op.operation_serial) return error.InvalidOrder;
                        switch (op.kind) {
                            .capture_begin, .restore_submit => {
                                if (result.status != .submitted) return error.InvalidEvent;
                                self.transaction = if (op.kind == .capture_begin) .capture else .restore;
                                self.ticket = result.ticket;
                                self.terminal_polled = false;
                                if (op.kind == .capture_begin) self.captured = true else self.restored = true;
                            },
                            .capture_poll, .restore_poll => {
                                if (result.ticket != self.ticket) return error.InvalidOrder;
                                if (result.status != .pending and result.status != .failed and result.status != (if (op.kind == .capture_poll) schema.StateHostStatus.ready else .installed)) return error.InvalidEvent;
                                if (self.terminal_polled and result.status == .pending) return error.InvalidOrder;
                                self.terminal_polled = result.status != .pending;
                                if (result.snapshot) |value| {
                                    if (self.resource) |known| if (!std.meta.eql(known, value)) return error.ResourceNotPrepared;
                                    self.resource = value;
                                }
                                if (result.installed) |value| if (value.context != self.context or value.asset_generation != op.bank.generation) return error.InvalidEvent;
                            },
                            .capture_ack, .restore_ack => {
                                if (result.ticket != self.ticket or result.status != .acknowledged) return error.InvalidEvent;
                                self.transaction = null;
                                self.terminal_polled = false;
                            },
                        }
                        self.operation = null;
                        self.operation_serial = try std.math.add(u64, self.operation_serial, 1);
                        // A completed host operation ends ordinary fact scope.
                        self.kind = .begin;
                    },
                }
            },
            .request => |request| {
                if (input.position.control_tick != self.tick or input.position.accepted_control_frame != self.frame) return error.InvalidOrder;
                if (self.operation != null or self.transaction != null or self.kind != .control_tick or request.context != self.context or request.producer != 1 or request.producer_order != request.request_id) return error.InvalidOrder;
                if (self.profile == .stream_context_serial_v1 and request.request_id >= self.context_journal.next_request_id) return error.InvalidOrder;
                switch (request.payload) {
                    .set_state, .stop_emergency => {},
                    .context_boolean, .context_integer, .context_scalar, .context_id => if (self.profile != .stream_context_serial_v1) return error.UnsupportedOperation,
                    .pause, .@"resume" => if (self.profile != .resident_serial_v1 and self.profile != .stream_fill_state_serial_v1) return error.UnsupportedOperation,
                    else => return error.UnsupportedOperation,
                }
            },
            .admission => |a| {
                if (input.position.control_tick != self.tick or input.position.accepted_control_frame != self.frame) return error.InvalidOrder;
                const host_poll = if (self.operation) |op| op.kind == .capture_poll or op.kind == .restore_poll else false;
                if ((!host_poll and self.kind != .control_tick) or (a.kind == .stream_visibility and !isStream(self.profile))) return error.UnsupportedOperation;
            },
            .worker, .readiness_snapshot => {
                if (!isStream(self.profile) or self.operation != null or self.kind != .control_tick) return error.UnsupportedOperation;
                if (input.position.control_tick != self.tick or input.position.accepted_control_frame != self.frame) return error.InvalidOrder;
            },
            .lifecycle => |value| {
                if (!isStateProfile(self.profile) or value.context != self.context or input.position.control_tick != self.tick or input.position.accepted_control_frame != self.frame) return error.UnsupportedOperation;
                switch (value.payload) {
                    .capture_state => if (self.operation == null or self.operation.?.kind != .capture_begin) return error.InvalidOrder,
                    .restore_state => |restore| {
                        if (self.operation != null or self.kind != .control_tick or self.transaction != .restore or value.operation_id != self.ticket or self.resource == null or
                            !std.meta.eql(restore.snapshot, self.resource.?) or restore.migration != null) return error.InvalidOrder;
                    },
                    else => return error.UnsupportedOperation,
                }
            },
            .generation_preparation => |value| {
                if (!isStateProfile(self.profile) or self.operation != null or self.kind != .control_tick or self.transaction != .restore or
                    value.kind != .restore_state or value.context != self.context or value.operation_id != self.ticket or value.state != .ready or
                    value.snapshot == null or self.resource == null or !std.meta.eql(value.snapshot.?, self.resource.?) or value.migration != null or
                    input.position.control_tick != self.tick or input.position.accepted_control_frame != self.frame) return error.UnsupportedOperation;
            },
            else => return error.UnsupportedOperation,
        }
    }
};
