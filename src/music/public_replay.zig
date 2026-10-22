//! Real public MusicRuntime replay for explicit bounded serial profiles.
//! Every host tick/render operation is an input. Requests are resubmitted to the
//! public ingress; Director, Planner, scheduler and the one Renderer recompute.
//! Recorded admissions are compared with real observations, never injected.
const std = @import("std");
const trace = @import("sme-trace");
pub const Profile = trace.schema.RuntimeProfile;
pub const Step = trace.schema.RuntimeStep;
/// Incremental grammar preparation only; does not run or certify replay.
pub const ChunkCursor = @import("public_replay_cursor.zig").Cursor;
/// Immutable bounded readers/preflight; not a production replay executor.
pub const ChunkSource = @import("public_replay_source.zig");
pub const ChunkRecording = trace.chunk_recording;
/// Explicitly separate an invoked owner operation from a pure preflight rejection.
/// An invoked error can follow partial engine work: it never authorizes retry.
pub fn Invocation(comptime T: type) type {
    return union(enum) {
        not_started: anyerror,
        started: struct {
            engine_result: anyerror!T,
            recording_status: ChunkRecording.Status,
        },
    };
}
pub const ChunkOptions = struct {
    profile: Profile = .stream_serial_v1,
    recording_nonce: trace.schema.Hash,
    storage_id: u64,
    incarnation: u64,
    max_inputs: u64,
};
pub const RenderObservation = struct {
    requested_frames: u32,
    frame_before: u64,
    frame_after: u64,
    call_sequence_before: u64,
    call_sequence_after: u64,
    /// The one real render call advanced the requested frame and call frontiers.
    completed: bool,
};
const save = @import("save_state.zig");
const v1 = @import("runtime_contract.zig");
/// Legacy retained stream profiles. Fill-state recording is chunk-only.
pub fn isStream(profile: Profile) bool {
    return profile == .stream_serial_v1 or profile == .stream_direct_state_serial_v1;
}
/// Explicit chunk paths may additionally opt into profiles 4 and 7.
pub fn isChunkStream(profile: Profile) bool {
    return isStream(profile) or profile == .stream_fill_state_serial_v1 or profile == .stream_context_serial_v1;
}
pub fn isStateProfile(profile: Profile) bool {
    return profile == .stream_direct_state_serial_v1 or profile == .stream_fill_state_serial_v1;
}
/// One caller-owned encoded resource, never a historical capture fabrication.
/// Large decoded validation scratch is heap-owned and released synchronously.
pub const SnapshotResources = struct {
    snapshot: save.SnapshotV1 = .{},
    resource: ?trace.schema.lifecycle.SnapshotResource = null,
    pub fn clearV1(self: *SnapshotResources) void {
        self.snapshot.length = 0;
        self.resource = null;
    }
    /// Compatibility entry: only semantic-profile-2 DIRECT snapshots.
    pub fn registerV1(self: *SnapshotResources, allocator: std.mem.Allocator, expected: trace.schema.lifecycle.SnapshotResource, bytes: []const u8) !void {
        return self.registerForProfileV1(allocator, .stream_direct_state_serial_v1, expected, bytes);
    }
    /// Explicit recording-profile opt-in. One slot; validation precedes mutation.
    pub fn registerForProfileV1(self: *SnapshotResources, allocator: std.mem.Allocator, profile: Profile, expected: trace.schema.lifecycle.SnapshotResource, bytes: []const u8) !void {
        if (!isStateProfile(profile)) return error.UnsupportedCapability;
        try expected.validate();
        if (bytes.len > save.capacity or bytes.len != expected.byte_size) return error.InvalidSnapshot;
        if (self.resource) |old| if (!std.meta.eql(old, expected)) return error.ResourceCapacity;
        const decoded = try allocator.create(save.Decoded);
        defer allocator.destroy(decoded);
        try save.decode(bytes, decoded);
        try requireSnapshotForProfile(decoded, profile);
        if (!std.meta.eql(save.resource(decoded, bytes), expected)) return error.ResourceNotPrepared;
        if (self.snapshot.bytes[0..bytes.len].ptr != bytes.ptr) @memcpy(self.snapshot.bytes[0..bytes.len], bytes);
        self.snapshot.length = @intCast(bytes.len);
        self.resource = expected;
    }
    /// Compatibility verification never accepts fill snapshots, including those
    /// previously registered through the explicit profile-aware entry.
    pub fn verifyV1(self: *const SnapshotResources, allocator: std.mem.Allocator) !void {
        return self.verifyForProfileV1(allocator, .stream_direct_state_serial_v1);
    }
    pub fn verifyForProfileV1(self: *const SnapshotResources, allocator: std.mem.Allocator, profile: Profile) !void {
        if (!isStateProfile(profile)) return error.UnsupportedCapability;
        const expected = self.resource orelse {
            if (self.snapshot.length != 0) return error.ResourceNotPrepared;
            return;
        };
        try expected.validate();
        if (self.snapshot.length > save.capacity or self.snapshot.length != expected.byte_size) return error.InvalidSnapshot;
        const decoded = try allocator.create(save.Decoded);
        defer allocator.destroy(decoded);
        try save.decode(self.snapshot.slice(), decoded);
        try requireSnapshotForProfile(decoded, profile);
        if (!std.meta.eql(save.resource(decoded, self.snapshot.slice()), expected)) return error.ResourceNotPrepared;
    }
    pub fn resolveV1(self: *const SnapshotResources, expected: trace.schema.lifecycle.SnapshotResource) ![]const u8 {
        if (self.snapshot.length > save.capacity or self.resource == null or !std.meta.eql(self.resource.?, expected) or
            self.snapshot.length != expected.byte_size or !std.mem.eql(u8, &save.hash(self.snapshot.slice()), &expected.bytes_hash)) return error.ResourceNotPrepared;
        return self.snapshot.slice();
    }
};
pub fn requireDirectSnapshot(decoded: *const save.Decoded) !void {
    const h = decoded.header;
    if (h.profile_version != save.stream_direct_profile_version or h.mode == .paused or h.entry_count != 0 or h.executed_prefix != 0 or h.fill_occurrence != null or
        h.physical_path_id != 0 or h.physical_fill_route != null or h.source_exit_cue != 0 or h.fill_route != null or h.path_id != 0) return error.UnsupportedCapability;
}
/// Snapshot wire version stays 1; the recording profile selects its semantic
/// capability. Fill recording additionally permits paused snapshots; decoded
/// mode, resource identity and loaded-bank semantics still require validation.
pub fn requireSnapshotForProfile(decoded: *const save.Decoded, profile: Profile) !void {
    switch (profile) {
        .stream_direct_state_serial_v1 => try requireDirectSnapshot(decoded),
        .stream_fill_state_serial_v1 => {
            if (decoded.header.profile_version != save.stream_fill_profile_version) return error.UnsupportedCapability;
        },
        else => return error.UnsupportedCapability,
    }
}
pub const Capture = struct {
    /// Sticky even after failure/seal; chunk artifacts are never legacy envelopes.
    mode: enum { retained, chunks } = .retained,
    chunk_storage: ?*ChunkRecording.Storage = null,
    chunk_cursor: ?ChunkCursor = null,
    chunk_evidence_incomplete: bool = false,
    sealed_chunk_inputs: u64 = 0,
    sealed_chunk_schedule: u64 = 0,
    phase: enum { disabled, active, sealed, failed } = .disabled,
    driving: bool = false,
    profile: Profile = .resident_serial_v1,
    recomputing: bool = false,
    state_host: bool = false,
    next_state_operation: u64 = 1,
    state_ticket: ?struct { kind: enum { capture, restore }, id: u64, terminal_polled: bool = false } = null,
    captured_once: bool = false,
    restored_once: bool = false,
    captured_resource: ?trace.schema.lifecycle.SnapshotResource = null,
    // Stream-only construction identity. Resident wire/guard behavior is frozen.
    stream_identity: ?trace.Header = null,
    // Borrowed only during the synchronous replay tick; never retained at seal.
    tick_inputs: []const trace.Input = &.{},
    call_sequence: u64 = 0,
    frame: u64 = 0,
    tick: u64 = 0,
    next_sequence: u64 = 1,
    next_control_sequence: u64 = 1,
    submitted: u64 = 0,
    next_reservation: u64 = 1,
    reservations: u64 = 0,
    next_batch: u64 = 1,
    prepared_batches: u64 = 0,
    published: u64 = 0,
    sealed_inputs: usize = 0,
    sealed_schedule: usize = 0,
};
pub const Result = struct {
    samples: []f32,
    allocator: std.mem.Allocator,
    pub fn deinit(self: *Result) void {
        self.allocator.free(self.samples);
    }
};

/// Checks identity without turning an unfinished live capture into a complete
/// header. The supplied recording must independently validate as complete.
pub fn requireIdentity(recorded: trace.Header, live: trace.Header) !void {
    try recorded.validate();
    if (!std.meta.eql(recorded.base(), live.base()) or
        recorded.bank_major != live.bank_major or recorded.bank_minor != live.bank_minor or
        recorded.bank_build_id != live.bank_build_id or recorded.generation != live.generation or
        !std.mem.eql(u8, &recorded.capacity_profile_hash, &live.capacity_profile_hash) or
        recorded.rules_version != live.rules_version or
        recorded.field_classification_version != live.field_classification_version) return error.InvalidHeader;
}

/// Grammar is checked before any request or render call. The begin record binds
/// profile/version, and an explicit end prevents a valid truncated prefix from
/// being mistaken for a recording. Facts belong to one explicit tick or one
/// paired state-host call. Results close calls; only ticks admit restore work.
pub fn validate(inputs: []const trace.Input) !void {
    try trace.replay.validateSequence(inputs);
    if (inputs.len < 2 or inputs[0].payload != .runtime_step or inputs[0].payload.runtime_step.kind != .begin or
        inputs[inputs.len - 1].payload != .runtime_step or inputs[inputs.len - 1].payload.runtime_step.kind != .end) return error.IncompleteTrace;
    const context = inputs[0].payload.runtime_step.context;
    const profile = inputs[0].payload.runtime_step.profile;
    // Retained envelopes have no profile-4 path. Chunk callers must explicitly
    // select it through ChunkCursor.beginForProfile and state resource preflight.
    if (profile == .stream_fill_state_serial_v1 or profile == .stream_context_serial_v1) return error.UnsupportedOperation;
    var kind: trace.schema.RuntimeStepKind = .begin;
    var tick: u64 = 0;
    var frame: u64 = 0;
    var call: u64 = 0;
    var operation_serial: u64 = 1;
    var operation: ?trace.schema.StateHostOperation = null;
    var transaction: ?enum { capture, restore } = null;
    var ticket: u64 = 0;
    var terminal_polled = false;
    var captured = false;
    var restored = false;
    var resource: ?trace.schema.lifecycle.SnapshotResource = null;
    for (inputs, 0..) |input, index| switch (input.payload) {
        .context_host_operation => return error.UnsupportedOperation,
        .runtime_step => |step| {
            if (operation != null or step.context != context or step.profile != profile or (step.kind == .begin and index != 0) or
                (step.kind == .end and index + 1 != inputs.len)) return error.InvalidOrder;
            if (input.position.control_tick != tick or input.position.accepted_control_frame != frame or step.render_call_sequence != call) return error.InvalidOrder;
            switch (step.kind) {
                .control_tick => tick = try std.math.add(u64, tick, 1),
                .render => {
                    frame = try std.math.add(u64, frame, step.frame_count);
                    call = try std.math.add(u64, call, 2);
                },
                .end => if (transaction != null) return error.IncompleteTrace,
                else => {},
            }
            kind = step.kind;
        },
        .state_host_operation => |record| {
            if (profile != .stream_direct_state_serial_v1) return error.UnsupportedOperation;
            if (input.position.control_tick != tick or input.position.accepted_control_frame != frame) return error.InvalidOrder;
            switch (record) {
                .call => |op| {
                    if (operation != null or op.operation_serial != operation_serial or op.context != context or op.render_call_sequence != call) return error.InvalidOrder;
                    switch (op.kind) {
                        .capture_begin => if (transaction != null or captured or restored) return error.UnsupportedOperation,
                        .restore_submit => {
                            if (transaction != null or restored) return error.UnsupportedOperation;
                            if (resource) |known| if (!std.meta.eql(known, op.snapshot.?)) return error.ResourceNotPrepared;
                            resource = op.snapshot;
                        },
                        .capture_poll, .capture_ack => if (transaction != .capture or op.ticket != ticket) return error.InvalidOrder,
                        .restore_poll, .restore_ack => if (transaction != .restore or op.ticket != ticket) return error.InvalidOrder,
                    }
                    if ((op.kind == .capture_ack or op.kind == .restore_ack) and !terminal_polled) return error.IncompleteTrace;
                    operation = op;
                },
                .result => |result| {
                    const op = operation orelse return error.InvalidOrder;
                    if (result.operation_serial != op.operation_serial) return error.InvalidOrder;
                    switch (op.kind) {
                        .capture_begin, .restore_submit => {
                            if (result.status != .submitted) return error.InvalidEvent;
                            transaction = if (op.kind == .capture_begin) .capture else .restore;
                            ticket = result.ticket;
                            terminal_polled = false;
                            if (op.kind == .capture_begin) captured = true else restored = true;
                        },
                        .capture_poll, .restore_poll => {
                            if (result.ticket != ticket) return error.InvalidOrder;
                            if (result.status != .pending and result.status != .failed and result.status != (if (op.kind == .capture_poll) trace.schema.StateHostStatus.ready else .installed)) return error.InvalidEvent;
                            if (terminal_polled and result.status == .pending) return error.InvalidOrder;
                            terminal_polled = result.status != .pending;
                            if (result.snapshot) |value| {
                                if (resource) |known| if (!std.meta.eql(known, value)) return error.ResourceNotPrepared;
                                resource = value;
                            }
                            if (result.installed) |value| if (value.context != context or value.asset_generation != op.bank.generation) return error.InvalidEvent;
                        },
                        .capture_ack, .restore_ack => {
                            if (result.ticket != ticket or result.status != .acknowledged) return error.InvalidEvent;
                            transaction = null;
                            terminal_polled = false;
                        },
                    }
                    operation = null;
                    operation_serial = try std.math.add(u64, operation_serial, 1);
                    // No ordinary facts may trail a completed host operation.
                    kind = .begin;
                },
            }
        },
        .request => |request| {
            if (input.position.control_tick != tick or input.position.accepted_control_frame != frame) return error.InvalidOrder;
            if (operation != null or transaction != null or kind != .control_tick or request.context != context or request.producer != 1 or request.producer_order != request.request_id) return error.InvalidOrder;
            switch (request.payload) {
                .set_state, .stop_emergency => {},
                .pause, .@"resume" => if (profile != .resident_serial_v1) return error.UnsupportedOperation,
                else => return error.UnsupportedOperation,
            }
        },
        .admission => |admission| {
            if (input.position.control_tick != tick or input.position.accepted_control_frame != frame) return error.InvalidOrder;
            const host_poll = if (operation) |op| op.kind == .capture_poll or op.kind == .restore_poll else false;
            if ((!host_poll and kind != .control_tick) or (admission.kind == .stream_visibility and !isStream(profile))) return error.UnsupportedOperation;
        },
        .worker, .readiness_snapshot => {
            if (!isStream(profile) or operation != null or kind != .control_tick) return error.UnsupportedOperation;
            if (input.position.control_tick != tick or input.position.accepted_control_frame != frame) return error.InvalidOrder;
        },
        .lifecycle => |value| {
            if (profile != .stream_direct_state_serial_v1 or value.context != context or input.position.control_tick != tick or input.position.accepted_control_frame != frame) return error.UnsupportedOperation;
            switch (value.payload) {
                .capture_state => if (operation == null or operation.?.kind != .capture_begin) return error.InvalidOrder,
                .restore_state => |restore| {
                    if (operation != null or kind != .control_tick or transaction != .restore or value.operation_id != ticket or resource == null or
                        !std.meta.eql(restore.snapshot, resource.?) or restore.migration != null) return error.InvalidOrder;
                },
                else => return error.UnsupportedOperation,
            }
        },
        .generation_preparation => |value| {
            if (profile != .stream_direct_state_serial_v1 or operation != null or kind != .control_tick or transaction != .restore or
                value.kind != .restore_state or value.context != context or value.operation_id != ticket or value.state != .ready or
                value.snapshot == null or resource == null or !std.meta.eql(value.snapshot.?, resource.?) or value.migration != null or
                input.position.control_tick != tick or input.position.accepted_control_frame != frame) return error.UnsupportedOperation;
        },
        else => return error.UnsupportedOperation,
    };
    if (operation != null or transaction != null) return error.IncompleteTrace;
}

/// Control-thread offline entry. The supplied owner must have independently
/// loaded/authenticated the same bank and be pristine. No asset or ready flag
/// is fabricated. The full canonical schedule is mandatory as the oracle.
pub fn recompute(owner: anytype, allocator: std.mem.Allocator, envelope: @import("contract.zig").ReplayInputV2, expected_schedule: []const trace.ScheduleEntry) !Result {
    return recomputeImpl(owner, allocator, envelope, expected_schedule, null);
}
pub fn recomputeWithStateResources(owner: anytype, allocator: std.mem.Allocator, envelope: @import("contract.zig").ReplayInputV2, expected_schedule: []const trace.ScheduleEntry, resources: *SnapshotResources) !Result {
    return recomputeImpl(owner, allocator, envelope, expected_schedule, resources);
}
fn boundary(input: trace.Input) bool {
    return input.payload == .runtime_step or (input.payload == .state_host_operation and input.payload.state_host_operation == .call);
}
fn recomputeImpl(owner: anytype, allocator: std.mem.Allocator, envelope: @import("contract.zig").ReplayInputV2, expected_schedule: []const trace.ScheduleEntry, resources: ?*SnapshotResources) !Result {
    var decoded = try trace.decodeInputEnvelope(allocator, envelope, 4096);
    defer decoded.deinit();
    try validate(decoded.records);
    for (decoded.records) |input| if (input.payload == .runtime_step and input.payload.runtime_step.frame_count > decoded.header.quantum_frames) return error.InvalidEvent;
    const profile = decoded.records[0].payload.runtime_step.profile;
    if (profile == .stream_direct_state_serial_v1) {
        const table = resources orelse return error.ResourceNotPrepared;
        try table.verifyV1(allocator);
        if (table.resource != null) {
            const snapshot = try allocator.create(save.Decoded);
            defer allocator.destroy(snapshot);
            try save.decode(table.snapshot.slice(), snapshot);
            try save.validateIdentity(snapshot, decoded.header.bank_build_id, decoded.header.bank_content_hash, decoded.header.profile);
        }
        for (decoded.records) |input| if (input.payload == .state_host_operation) {
            const resource = switch (input.payload.state_host_operation) {
                .call => |op| op.snapshot,
                .result => |result| result.snapshot,
            };
            if (resource) |value| if (value.bank_build_id != decoded.header.bank_build_id or value.byte_size > save.capacity) return error.ResourceNotPrepared;
        };
        var captures = false;
        for (decoded.records) |input| if (input.payload == .state_host_operation and input.payload.state_host_operation == .call) {
            const op = input.payload.state_host_operation.call;
            if (op.bank.build_id != decoded.header.bank_build_id or op.bank.generation != decoded.header.generation or
                op.bank.major != decoded.header.bank_major or op.bank.minor != decoded.header.bank_minor or
                !std.mem.eql(u8, &op.bank.content_hash, &decoded.header.bank_content_hash)) return error.InvalidHeader;
            if (op.kind == .capture_begin) {
                if (table.resource != null) return error.ResourceCapacity;
                captures = true;
            }
            if (op.kind == .restore_submit and !captures) _ = try table.resolveV1(op.snapshot.?);
        };
    }
    try owner.beginRecordingV1(profile);
    errdefer owner.failRecordingV1();
    try requireIdentity(decoded.header, owner.recordingHeader());
    if (isStream(profile)) try owner.beginStreamReplayV1();
    var samples: std.ArrayList(f32) = .empty;
    errdefer samples.deinit(allocator);
    var cursor: usize = 0;
    while (cursor < decoded.records.len) {
        const marker = decoded.records[cursor];
        if (!boundary(marker)) return error.InvalidOrder;
        var end = cursor + 1;
        while (end < decoded.records.len and !boundary(decoded.records[end])) : (end += 1) {}
        const first = if (cursor == 0) 0 else owner.replayInputs().len;
        if (marker.payload == .state_host_operation) {
            const op = marker.payload.state_host_operation.call;
            const bank: v1.BankRefV1 = .{ .context = op.context, .handle = .{ .index = op.bank_index, .generation = op.bank_incarnation }, .asset_generation = op.bank.generation };
            const capture_ticket: save.TicketV1 = .{ .context = op.context, .incarnation = op.ticket };
            const restore_ticket: v1.RequestTicketV1 = .{ .context = op.context, .request_id = op.ticket, .bank = bank };
            const table = resources orelse return error.ResourceNotPrepared;
            switch (op.kind) {
                .capture_begin => _ = try owner.recordCaptureStateV1(bank),
                .capture_poll => _ = try owner.recordPollCaptureStateV1(capture_ticket, table),
                .capture_ack => try owner.recordAcknowledgeCaptureV1(capture_ticket),
                .restore_submit => {
                    _ = try table.resolveV1(op.snapshot.?);
                    _ = try owner.recordRestoreStateV1(bank, table);
                },
                .restore_poll => _ = try owner.recordPollRestoreStateV1(restore_ticket),
                .restore_ack => try owner.recordAcknowledgeRestoreV1(restore_ticket),
            }
        } else {
            const step = marker.payload.runtime_step;
            switch (step.kind) {
                .begin => if (cursor != 0) return error.InvalidOrder,
                .control_tick => {
                    if (isStream(profile)) try owner.prepareStreamReplayTickV1(decoded.records[cursor + 1 .. end]);
                    // Only accepted request facts feed ingress. Gates, planned rows
                    // and final outcomes cannot become commands or expected success.
                    for (decoded.records[cursor + 1 .. end]) |input| if (input.payload == .request) {
                        const request = input.payload.request;
                        const payload: @import("contract.zig").MusicRequestPayload = switch (request.payload) {
                            .set_state => |v| .{ .set_state = .{ .state = @enumFromInt(v.state), .priority = v.priority } },
                            .pause => .pause,
                            .@"resume" => .@"resume",
                            .stop_emergency => .{ .stop = .emergency_ramp },
                            else => return error.UnsupportedOperation,
                        };
                        const status = try owner.snapshotV1();
                        const ticket = try owner.submitV1(status.bank orelse return error.InvalidState, payload);
                        if (ticket.request_id != request.request_id) return error.InvalidOrder;
                    };
                    _ = try owner.recordControlTickV1(step.control_limit);
                    // These are actual diagnostic copies, not input or injected
                    // outcomes. A live host may drain this finite queue after each
                    // tick; replay must do the same so long valid traces cannot
                    // overflow the 256-copy queue solely because of this driver.
                    for (0..@import("runtime_contract.zig").resident_fill_hard_cut_v1.phase_receipt_slots) |_| {
                        if (try owner.pollPhaseReceiptV1() == null) break;
                    }
                },
                .render => {
                    if (isStream(profile)) try owner.prepareStreamReplayRenderV1(decoded.records[end..]);
                    const count = try std.math.mul(usize, step.frame_count, 2);
                    const old = samples.items.len;
                    try samples.resize(allocator, try std.math.add(usize, old, count));
                    try owner.recordRenderV1(samples.items[old..], step.frame_count);
                },
                .end => try owner.endRecordingV1(),
                _ => return error.UnknownVersion,
            }
        }
        const actual = owner.replayInputs()[first..];
        const expected = decoded.records[cursor..end];
        if (actual.len != expected.len) return error.MissingAdmission;
        for (actual, expected) |a, e| if (!std.meta.eql(a, e)) return error.ReplayMismatch;
        cursor = end;
    }
    try owner.validateReplayHeader(decoded.header);
    const actual_schedule = owner.scheduleRecords();
    if (actual_schedule.len != expected_schedule.len) return error.ScheduleMismatch;
    for (actual_schedule, expected_schedule) |actual, expected| if (!std.meta.eql(actual, expected)) return error.ScheduleMismatch;
    return .{ .samples = try samples.toOwnedSlice(allocator), .allocator = allocator };
}
