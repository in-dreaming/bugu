//! Bounded OFFLINE source preparation for ChunkRecordingV1, profiles 2, 3, 4 and 7.
//! State profiles require their explicit resource-aware entry point before
//! attachment; the fill path never widens the existing profile-2/3 APIs.
//! No runtime calls, allocation, filesystem operations, PCM or replay acceptance.
//! All callbacks, scans and lookahead must run outside Render. Independent scans
//! bound storage, not latency: one next() can traverse the entire remaining file.
const std = @import("std");
const trace = @import("sme-trace");
const chunks = trace.chunks;
const grammar = @import("public_replay_cursor.zig");
const schema = trace.schema;
const public = @import("public_replay.zig");
const save = @import("save_state.zig");

pub const Error = chunks.Error || grammar.Error || error{
    InvalidSource,
    SourceLengthMismatch,
    SourceChanged,
    OperationTooLarge,
    OperationBurstTooLarge,
    UnconsumedRecords,
};

/// The caller MUST supply a finalized/published recording, then hold immutable
/// bytes or an effective immutable read lease
/// from before preflight until every cursor is exhausted/destroyed. Opening an
/// ordinary mutable file does not satisfy this contract. The context and lease
/// outlive Prepared and all cursors. Source bytes cannot alias writable scratch
/// or the state-resource table later populated by replay.
/// read_at may return a positive short read, 0 ONLY at actual EOF, or an error.
/// It must not write past buffer, return more than buffer.len, mutate source,
/// or retain buffer. Its own resource/time cost is the provider's responsibility.
/// Hashes detect corruption; they do NOT defeat arbitrary mutable-file TOCTOU.
/// Finalization/publication is a caller contract, not inferred from a terminal's
/// bytes. A failed/uncertain final write can leave identical valid-looking bytes;
/// preflight cannot discover that earlier I/O result or certify durability. A
/// producer ExportCompletion may be bound by the integration separately.
pub const ImmutableSource = struct {
    context: *anyopaque,
    byte_length: u64,
    read_at: *const fn (context: *anyopaque, offset: u64, buffer: []u8) anyerror!usize,
};

/// Private to one live scan; must not overlap another scan's scratch, a live
/// operation buffer, the immutable source, or each other. No retained slices
/// point into io after it is refilled. Payload lives until its frame is drained.
pub const Scratch = struct { io: []u8, payload: []u8 };

/// Every pass has its own finite allowance, including filtered scans. Work
/// counters measure callback invocations, parser feeds and decoded record
/// visits. Canonical decoding/hashing is additionally bounded by container's
/// explicit byte/frame/record caps. Callback latency itself is not bounded here.
pub const Limits = struct {
    container: chunks.LocalLimits,
    max_read_calls: u64,
    max_parser_calls: u64,
    max_record_visits: u64,
    max_operation_records: usize,
    max_operations: u64,
    max_rendered_frames: u64,
    /// Optional replay capture-queue restriction, NOT a total recording limit.
    /// Bounds conservative_operation_burst_records below. Null preserves the
    /// reader's existing acceptance without a synchronous capture-queue cap.
    max_conservative_operation_burst_records: ?u64 = null,

    fn validate(self: Limits) Error!void {
        if (self.max_read_calls == 0 or self.max_parser_calls == 0 or
            self.max_record_visits < 2 or self.max_operation_records == 0 or
            self.max_operations < 2) return error.InvalidLimits;
        if (self.max_conservative_operation_burst_records) |maximum|
            if (maximum == 0) return error.InvalidLimits;
    }
};

pub const Work = struct { read_calls: u64 = 0, parser_calls: u64 = 0, record_visits: u64 = 0 };
pub const EvidenceTier = enum { complete_container_and_public_grammar_only };

/// Not an export/durability receipt, runtime seal, completed legacy Header,
/// resource authorization, authenticity claim, or proof of recomputed results.
/// Construction is exclusively via one of the preflight entry points. The
/// caller must preserve this value unchanged while cursors borrow it.
pub const Prepared = struct {
    evidence_tier: EvidenceTier = .complete_container_and_public_grammar_only,
    runtime_reconciliation_required: void = {},
    source: ImmutableSource,
    limits: Limits,
    framing: chunks.SuccessfulTerminalFraming,
    runtime_profile: schema.RuntimeProfile,
    /// One consistent full-bank resource descriptor from restore preparation.
    /// Source validation binds identity and descriptor equality; replay MUST
    /// compare size/hash with the actually loaded bank before owner attachment.
    bank_resource: ?schema.lifecycle.BankResource = null,
    total_visibility: u64,
    total_operations: u64,
    rendered_frames: u64,
    required_group_records: usize,
    /// Maximum over NONTERMINAL operation groups of their input count plus all
    /// schedule rows in the source frames from that group's marker through the
    /// next marker, inclusive. Shared boundary-frame schedules are deliberately
    /// counted for both operations, even for several markers in a single frame.
    /// This is a conservative supported-representation/resource bound for the
    /// ordered producer that captures each marker before its generated records;
    /// it is not exact inter-channel ordering or an arbitrary-container runtime
    /// guarantee. Begin is included. Serial-profile closure currently emits no rows
    /// before its genuine end, which uses a separate reserved terminal cell.
    /// End is therefore excluded; changing closure to emit rows invalidates that
    /// integration contract. State-host calls are complete groups. This field
    /// does not certify owner state, recomputation, or a caller-modified value.
    conservative_operation_burst_records: u64,
    preflight_work: Work,
};

pub const IndexedInput = struct { ordinal: u64, value: trace.Input };
pub const IndexedSchedule = struct { ordinal: u64, value: trace.ScheduleEntry };
const IndexedRecord = union(enum) { input: IndexedInput, schedule: IndexedSchedule };

/// Admission is selected by the entry point, never inferred from a resource or
/// container. Existing DIRECT-resource scans preserve their profile-2/3 scope.
const ProfileScope = enum {
    serial,
    direct_state,
    fill_state,
    context_calls,

    fn accepts(self: ProfileScope, profile: schema.RuntimeProfile) bool {
        return switch (self) {
            .serial => profile == .stream_serial_v1,
            .direct_state => profile == .stream_serial_v1 or profile == .stream_direct_state_serial_v1,
            .fill_state => profile == .stream_fill_state_serial_v1,
            .context_calls => profile == .stream_context_serial_v1,
        };
    }

    fn forPrepared(profile: schema.RuntimeProfile) Error!ProfileScope {
        return switch (profile) {
            .stream_serial_v1 => .serial,
            .stream_direct_state_serial_v1 => .direct_state,
            .stream_fill_state_serial_v1 => .fill_state,
            .stream_context_serial_v1 => .context_calls,
            else => error.UnsupportedProfile,
        };
    }
};

fn overlap(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const ap = @intFromPtr(a.ptr);
    const bp = @intFromPtr(b.ptr);
    return if (ap <= bp) bp - ap < a.len else ap - bp < b.len;
}
fn increment(value: *u64, limit: u64) Error!void {
    if (value.* >= limit) return error.WorkLimit;
    value.* += 1;
}
fn sameFraming(a: chunks.SuccessfulTerminalFraming, b: chunks.SuccessfulTerminalFraming) bool {
    return std.meta.eql(a.identity, b.identity) and
        std.mem.eql(u8, &a.recording_id, &b.recording_id) and
        std.mem.eql(u8, &a.terminal_hash, &b.terminal_hash) and
        a.total_inputs == b.total_inputs and a.total_schedule == b.total_schedule and
        a.total_frames == b.total_frames and a.total_bytes == b.total_bytes;
}

/// Full framing validation is deliberately repeated on each independent pass.
/// A pin is checked as soon as the preamble is decoded and again at true EOF.
/// Per-frame integrity is checked before any record in that frame is exposed.
const Scan = struct {
    source: ImmutableSource,
    limits: Limits,
    io: []u8,
    validator: chunks.Validator,
    pin: ?chunks.SuccessfulTerminalFraming,
    io_used: usize = 0,
    io_cursor: usize = 0,
    read_offset: u64 = 0,
    iterator: ?chunks.RecordIterator = null,
    frame_schedule_begin: u64 = 0,
    input_ordinal: u64 = 0,
    schedule_ordinal: u64 = 0,
    work: Work = .{},
    evidence: ?chunks.SuccessfulTerminalFraming = null,
    checked_preamble: bool = false,
    profile_scope: ProfileScope,
    poisoned: bool = false,

    fn init(source: ImmutableSource, scratch: Scratch, limits: Limits, pin: ?chunks.SuccessfulTerminalFraming, profile_scope: ProfileScope) Error!Scan {
        try limits.validate();
        if (scratch.io.len == 0 or overlap(scratch.io, scratch.payload)) return error.InvalidLimits;
        if (source.byte_length > limits.container.max_total_bytes) return error.WorkLimit;
        if (pin) |expected| if (source.byte_length != expected.total_bytes) return error.SourceChanged;
        return .{ .source = source, .limits = limits, .io = scratch.io, .validator = try chunks.Validator.init(scratch.payload, limits.container), .pin = pin, .profile_scope = profile_scope };
    }

    fn next(self: *Scan) anyerror!?IndexedRecord {
        if (self.poisoned) return error.InvalidState;
        errdefer self.poisoned = true;
        if (self.evidence != null) return null;
        while (true) {
            if (self.iterator) |*iterator| {
                if (iterator.inputs_remaining != 0 or iterator.schedule_remaining != 0)
                    try increment(&self.work.record_visits, self.limits.max_record_visits);
                if (try iterator.next()) |record| switch (record) {
                    .input => |input| {
                        const ordinal = self.input_ordinal;
                        self.input_ordinal = try std.math.add(u64, ordinal, 1);
                        return .{ .input = .{ .ordinal = ordinal, .value = input } };
                    },
                    .schedule => |entry| {
                        const ordinal = self.schedule_ordinal;
                        self.schedule_ordinal = try std.math.add(u64, ordinal, 1);
                        return .{ .schedule = .{ .ordinal = ordinal, .value = entry } };
                    },
                };
                self.iterator = null;
            }
            if (self.io_cursor == self.io_used) {
                if (self.read_offset == self.source.byte_length) {
                    // A trusted length alone is not EOF evidence. Probe actual
                    // EOF even after the terminal frame was fully consumed.
                    try increment(&self.work.read_calls, self.limits.max_read_calls);
                    const extra = try self.source.read_at(self.source.context, self.read_offset, self.io[0..1]);
                    if (extra > 1) return error.InvalidSource;
                    if (extra != 0) return error.SourceLengthMismatch;
                    const evidence = try self.validator.finishAtEof();
                    if (evidence.total_bytes != self.source.byte_length or
                        evidence.total_inputs != self.input_ordinal or
                        evidence.total_schedule != self.schedule_ordinal) return error.SourceLengthMismatch;
                    if (self.pin) |expected| if (!sameFraming(evidence, expected)) return error.SourceChanged;
                    self.evidence = evidence;
                    return null;
                }
                const amount: usize = @intCast(@min(@as(u64, @intCast(self.io.len)), self.source.byte_length - self.read_offset));
                try increment(&self.work.read_calls, self.limits.max_read_calls);
                const n = try self.source.read_at(self.source.context, self.read_offset, self.io[0..amount]);
                if (n > amount) return error.InvalidSource;
                if (n == 0) return error.Truncated;
                self.read_offset = try std.math.add(u64, self.read_offset, @intCast(n));
                self.io_used = n;
                self.io_cursor = 0;
            }
            try increment(&self.work.parser_calls, self.limits.max_parser_calls);
            const result = try self.validator.feed(self.io[self.io_cursor..self.io_used]);
            if (result.consumed == 0 or result.consumed > self.io_used - self.io_cursor) return error.InvalidSource;
            self.io_cursor += result.consumed;
            if (!self.checked_preamble) if (self.validator.preamble) |preamble| {
                // Container framing alone never grants state-resource scope.
                // Check the explicitly selected profile before exposing inputs.
                if (!self.profile_scope.accepts(preamble.runtime_profile)) return error.UnsupportedProfile;
                if (self.pin) |expected| if (!std.mem.eql(u8, &preamble.recording_id, &expected.recording_id) or
                    !std.meta.eql(preamble.identity, expected.identity)) return error.SourceChanged;
                self.checked_preamble = true;
            };
            if (result.frame) |frame| {
                // Validator has checked the entire frame, including canonical
                // schedule records, before exposing its first input. Its
                // schedule_total already includes ALL of this frame's rows.
                self.frame_schedule_begin = frame.header.schedule_begin;
                self.iterator = frame.records();
            }
        }
    }
};

/// Exact legacy grouping rule, not a transport-frame boundary. A state call,
/// its generated facts and its result remain one group across any frames.
pub fn operationBoundary(input: trace.Input) bool {
    return input.payload == .runtime_step or
        (input.payload == .state_host_operation and input.payload.state_host_operation == .call) or
        (input.payload == .context_host_operation and input.payload.context_host_operation == .call);
}

/// Must complete successfully BEFORE any replay owner mutation. Validates every
/// source byte, the real EOF seal, all public grammar, every render quantum and
/// the largest complete operation group. The optional combined-burst restriction
/// is also decided here, never after beginning a runtime operation. No whole-
/// recording storage is retained, and no source cross-channel order is inferred.
pub fn preflight(source: ImmutableSource, scratch: Scratch, limits: Limits) anyerror!Prepared {
    return preflightImpl(source, scratch, limits, .serial, null);
}

/// Explicit profile-7 opt-in. Host calls/results are structurally checked and
/// clock-bound before owner mutation. Invalid API arguments remain valid host
/// evidence for the runtime to reject; no snapshot resources are admitted.
pub fn preflightWithContextCalls(source: ImmutableSource, scratch: Scratch, limits: Limits) anyerror!Prepared {
    return preflightImpl(source, scratch, limits, .context_calls, null);
}

/// Explicit profile-3 opt-in. The fixed one-slot table and decoded scratch are
/// caller-owned, disjoint, and never retained by it. The table is read-only
/// during this scan; decoded scratch is exclusively writable.
/// External restores require exact registered bytes; an in-record capture must
/// start with an empty table so replay can only obtain its own actual snapshot.
/// Decoding/hashing runs offline, before any owner attachment or state call.
/// For an external snapshot, decoded scratch retains the authenticated value;
/// replay must also validate its semantics against the loaded bank before
/// attachment. This source-only pass cannot certify bank-dependent state.
pub fn preflightWithStateResources(source: ImmutableSource, scratch: Scratch, limits: Limits, snapshots: *const public.SnapshotResources, snapshot_scratch: *save.Decoded) anyerror!Prepared {
    return preflightWithResources(source, scratch, limits, snapshots, snapshot_scratch, .stream_direct_state_serial_v1);
}

/// Explicit profile-4 opt-in for fill-profile snapshots, including settled
/// paused continuation. The fixed slot and decoded scratch have the same
/// ownership/nonalias contract as the DIRECT entry point. Cross-profile
/// resources and recordings remain rejected.
/// Exact external bytes are authenticated here, but the replay owner must still
/// validate their loaded-bank semantics before attachment. In-record capture
/// starts with an empty slot and obtains its bytes only from actual state polls.
pub fn preflightWithFillStateResources(source: ImmutableSource, scratch: Scratch, limits: Limits, snapshots: *const public.SnapshotResources, snapshot_scratch: *save.Decoded) anyerror!Prepared {
    return preflightWithResources(source, scratch, limits, snapshots, snapshot_scratch, .stream_fill_state_serial_v1);
}

fn preflightWithResources(source: ImmutableSource, scratch: Scratch, limits: Limits, snapshots: *const public.SnapshotResources, snapshot_scratch: *save.Decoded, profile: schema.RuntimeProfile) anyerror!Prepared {
    const table_bytes = std.mem.asBytes(snapshots);
    const decoded_bytes = std.mem.asBytes(snapshot_scratch);
    const ranges = [_][]const u8{ scratch.io, scratch.payload, table_bytes, decoded_bytes };
    for (ranges, 0..) |left, i| for (ranges[i + 1 ..]) |right| {
        if (overlap(left, right)) return error.InvalidLimits;
    };
    var resources = try StateResources.init(snapshots, snapshot_scratch, profile);
    return preflightImpl(source, scratch, limits, try ProfileScope.forPrepared(profile), &resources);
}

/// A constant-sized authorization pass. Descriptor equality includes every
/// field, including byte hash, size, saved generation and capture frame. These
/// are resource requirements, never injected state outcomes or replay facts.
const StateResources = struct {
    snapshots: *const public.SnapshotResources,
    decoded: *save.Decoded,
    checked_identity: bool = false,
    captured: bool = false,
    reference: ?schema.lifecycle.SnapshotResource = null,
    bank_resource: ?schema.lifecycle.BankResource = null,

    fn init(snapshots: *const public.SnapshotResources, decoded: *save.Decoded, profile: schema.RuntimeProfile) !StateResources {
        if (snapshots.resource) |expected| {
            try expected.validate();
            const bytes = try snapshots.resolveV1(expected);
            try save.decode(bytes, decoded);
            try public.requireSnapshotForProfile(decoded, profile);
            if (!std.meta.eql(save.resource(decoded, bytes), expected)) return error.ResourceNotPrepared;
        } else if (snapshots.snapshot.length != 0) return error.ResourceNotPrepared;
        return .{ .snapshots = snapshots, .decoded = decoded, .reference = snapshots.resource };
    }

    fn requireBank(identity: chunks.Identity, bank: schema.lifecycle.BankIdentity) !void {
        if (bank.build_id != identity.bank_build_id or bank.generation != identity.generation or
            bank.major != identity.bank_major or bank.minor != identity.bank_minor or
            !std.mem.eql(u8, &bank.content_hash, &identity.bank_content_hash)) return error.InvalidHeader;
    }

    fn requireSnapshot(self: *StateResources, identity: chunks.Identity, value: schema.lifecycle.SnapshotResource) !void {
        try value.validate();
        if (value.byte_size > save.capacity or value.bank_build_id != identity.bank_build_id) return error.ResourceNotPrepared;
        if (self.reference) |known| {
            if (!std.meta.eql(known, value)) return error.ResourceNotPrepared;
        } else self.reference = value;
    }

    fn accept(self: *StateResources, identity: chunks.Identity, input: trace.Input) !void {
        if (!self.checked_identity) {
            if (self.snapshots.resource != null)
                try save.validateIdentity(self.decoded, identity.bank_build_id, identity.bank_content_hash, identity.profile);
            self.checked_identity = true;
        }
        switch (input.payload) {
            .state_host_operation => |record| switch (record) {
                .call => |op| {
                    try requireBank(identity, op.bank);
                    if (op.kind == .capture_begin) {
                        if (self.snapshots.resource != null) return error.ResourceCapacity;
                        self.captured = true;
                    }
                    if (op.snapshot) |value| {
                        try self.requireSnapshot(identity, value);
                        if (op.kind == .restore_submit and !self.captured) _ = try self.snapshots.resolveV1(value);
                    }
                },
                .result => |result| if (result.snapshot) |value| {
                    try self.requireSnapshot(identity, value);
                    if (self.captured and (value.bank_generation != identity.generation or
                        value.capture_render_frame > input.position.accepted_control_frame)) return error.ResourceNotPrepared;
                },
            },
            .lifecycle => |value| switch (value.payload) {
                .capture_state => |bank| try requireBank(identity, bank),
                .restore_state => |restore| {
                    try requireBank(identity, restore.target_bank);
                    try self.requireSnapshot(identity, restore.snapshot);
                },
                else => {}, // Public grammar already rejects other operations.
            },
            .generation_preparation => |value| {
                try requireBank(identity, value.bank.identity);
                if (self.bank_resource) |known| {
                    if (!std.meta.eql(known, value.bank)) return error.ResourceNotPrepared;
                } else self.bank_resource = value.bank;
                if (value.snapshot) |snapshot| try self.requireSnapshot(identity, snapshot);
            },
            else => {},
        }
    }
};

fn preflightImpl(source: ImmutableSource, scratch: Scratch, limits: Limits, profile_scope: ProfileScope, resources: ?*StateResources) anyerror!Prepared {
    var scan = try Scan.init(source, scratch, limits, null, profile_scope);
    var public_grammar = if (profile_scope == .fill_state)
        try grammar.Cursor.beginForProfile(limits.container.max_total_inputs, .stream_fill_state_serial_v1)
    else if (profile_scope == .context_calls)
        try grammar.Cursor.beginForProfile(limits.container.max_total_inputs, .stream_context_serial_v1)
    else
        try grammar.Cursor.begin(limits.container.max_total_inputs);
    var visibility: u64 = 0;
    var operations: u64 = 0;
    var rendered: u64 = 0;
    var group_records: usize = 0;
    var largest_group: usize = 0;
    var group_schedule_begin: u64 = 0;
    var largest_operation_burst: u64 = 0;
    while (try scan.next()) |record| switch (record) {
        .input => |row| {
            const input = row.value;
            try public_grammar.feed(&.{input});
            if (resources) |state| try state.accept(scan.validator.preamble.?.identity, input);
            if (operationBoundary(input)) {
                if (operations != 0) {
                    // The verified current frame contains the next marker.
                    // Include every schedule in BOTH boundary frames, including
                    // rows serialized after this marker or after other markers
                    // in the same frame. One scalar start frontier suffices.
                    const schedule_span = std.math.sub(u64, scan.validator.schedule_total, group_schedule_begin) catch return error.CounterOverflow;
                    const input_count = std.math.cast(u64, group_records) orelse return error.CounterOverflow;
                    const combined = std.math.add(u64, input_count, schedule_span) catch return error.CounterOverflow;
                    largest_operation_burst = @max(largest_operation_burst, combined);
                    if (limits.max_conservative_operation_burst_records) |maximum|
                        if (combined > maximum) return error.OperationBurstTooLarge;
                }
                try increment(&operations, limits.max_operations);
                group_records = 0;
                group_schedule_begin = scan.frame_schedule_begin;
            } else if (operations == 0) return error.InvalidOrder;
            if (group_records >= limits.max_operation_records) return error.OperationTooLarge;
            group_records += 1;
            largest_group = @max(largest_group, group_records);
            if (input.payload == .runtime_step) {
                const step = input.payload.runtime_step;
                if (step.frame_count > scan.validator.preamble.?.identity.quantum_frames) return error.InvalidEvent;
                if (step.kind == .render) {
                    rendered = try std.math.add(u64, rendered, step.frame_count);
                    if (rendered > limits.max_rendered_frames) return error.WorkLimit;
                }
            }
            if (input.payload == .admission and input.payload.admission.kind == .stream_visibility)
                visibility = try std.math.add(u64, visibility, 1);
        },
        .schedule => {},
    };
    try public_grammar.finish();
    // Successful grammar and framing require the final group to be exactly the
    // real terminal end. It closed the preceding span above, but is not itself
    // a data-cell burst. Only complete source/EOF validation yields Prepared.
    return .{ .source = source, .limits = limits, .framing = scan.evidence.?, .runtime_profile = public_grammar.profile, .bank_resource = if (resources) |state| state.bank_resource else null, .total_visibility = visibility, .total_operations = operations, .rendered_frames = rendered, .required_group_records = largest_group, .conservative_operation_burst_records = largest_operation_burst, .preflight_work = scan.work };
}

fn FilteredCursor(comptime kind: enum { inputs, schedule, visibility }) type {
    const Row = if (kind == .schedule) IndexedSchedule else IndexedInput;
    return struct {
        const Self = @This();
        scan: Scan,
        expected_count: u64,
        returned: u64 = 0,
        pub fn init(prepared: *const Prepared, scratch: Scratch) Error!Self {
            return .{ .scan = try Scan.init(prepared.source, scratch, prepared.limits, prepared.framing, try ProfileScope.forPrepared(prepared.runtime_profile)), .expected_count = switch (kind) {
                .inputs => prepared.framing.total_inputs,
                .schedule => prepared.framing.total_schedule,
                .visibility => prepared.total_visibility,
            } };
        }
        /// Values are returned by copy. Visibility preserves original input
        /// ordinal and Position, even when it scans far ahead of the main input.
        pub fn next(self: *Self) anyerror!?Row {
            if (self.scan.poisoned) return error.InvalidState;
            errdefer self.scan.poisoned = true;
            while (try self.scan.next()) |record| {
                if (comptime kind == .schedule) {
                    if (record == .schedule) {
                        try increment(&self.returned, self.expected_count);
                        return record.schedule;
                    }
                } else if (record == .input) {
                    const row = record.input;
                    if (comptime kind == .visibility) {
                        if (row.value.payload != .admission or row.value.payload.admission.kind != .stream_visibility) continue;
                    }
                    try increment(&self.returned, self.expected_count);
                    return row;
                }
            }
            if (self.returned != self.expected_count) return error.SourceChanged;
            return null;
        }
        /// Read/validate the remaining unrelated channel, but never silently
        /// discard an expected row. A leftover is a poisoned-cursor failure.
        pub fn requireExhausted(self: *Self) anyerror!void {
            if (try self.next() != null) {
                self.scan.poisoned = true;
                return error.UnconsumedRecords;
            }
        }
        pub fn work(self: *const Self) Work {
            return self.scan.work;
        }
    };
}

pub const InputCursor = FilteredCursor(.inputs);
pub const ScheduleCursor = FilteredCursor(.schedule);
pub const VisibilityCursor = FilteredCursor(.visibility);

pub const OperationGroup = struct {
    input_begin: u64,
    records: []const trace.Input,
    pub fn marker(self: OperationGroup) trace.Input {
        return self.records[0];
    }
    pub fn facts(self: OperationGroup) []const trace.Input {
        return self.records[1..];
    }
};

/// Owns one input cursor and one scalar lookahead. The group buffer is borrowed
/// until the next next()/requireExhausted() call. Initialize all cursors before
/// owner.begin: short scratch/group buffers must fail before runtime mutation.
pub const GroupCursor = struct {
    inputs: InputCursor,
    buffer: []trace.Input,
    lookahead: ?IndexedInput = null,
    expected_groups: u64,
    groups: u64 = 0,
    done: bool = false,
    poisoned: bool = false,

    pub fn init(prepared: *const Prepared, scratch: Scratch, buffer: []trace.Input) Error!GroupCursor {
        if (buffer.len < prepared.required_group_records or buffer.len == 0 or
            overlap(std.mem.sliceAsBytes(buffer), scratch.io) or
            overlap(std.mem.sliceAsBytes(buffer), scratch.payload)) return error.InvalidLimits;
        return .{ .inputs = try InputCursor.init(prepared, scratch), .buffer = buffer[0..prepared.required_group_records], .expected_groups = prepared.total_operations };
    }
    pub fn next(self: *GroupCursor) anyerror!?OperationGroup {
        if (self.poisoned) return error.InvalidState;
        errdefer self.poisoned = true;
        if (self.done) return null;
        const first = self.lookahead orelse (try self.inputs.next()) orelse {
            if (self.groups != self.expected_groups) return error.SourceChanged;
            self.done = true;
            return null;
        };
        self.lookahead = null;
        if (!operationBoundary(first.value)) return error.InvalidOrder;
        self.buffer[0] = first.value;
        var used: usize = 1;
        while (try self.inputs.next()) |row| {
            if (row.ordinal != try std.math.add(u64, first.ordinal, @intCast(used))) return error.InvalidOrder;
            if (operationBoundary(row.value)) {
                self.lookahead = row;
                break;
            }
            if (used >= self.buffer.len) return error.OperationTooLarge;
            self.buffer[used] = row.value;
            used += 1;
        }
        try increment(&self.groups, self.expected_groups);
        // End is returned only after next() above proved true source EOF and
        // rechecked the pinned terminal, never merely on seeing an end record.
        if (self.lookahead == null) {
            if (self.groups != self.expected_groups) return error.SourceChanged;
            self.done = true;
        }
        return .{ .input_begin = first.ordinal, .records = self.buffer[0..used] };
    }
    pub fn requireExhausted(self: *GroupCursor) anyerror!void {
        if (try self.next() != null) {
            self.poisoned = true;
            return error.UnconsumedRecords;
        }
    }
    pub fn work(self: *const GroupCursor) Work {
        return self.inputs.work();
    }
};
