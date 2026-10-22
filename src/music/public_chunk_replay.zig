//! Offline serial profile-2/3/4/7 replay through one actual owner, Worker and Renderer.
//! Duration-independent scratch; independent immutable file cursors; no source
//! I/O, container hashing/encoding or PCM sink callback enters an engine call.
//! The four-cell recorder supports only a preflight-proven <=1016 combined
//! input/schedule burst per nonterminal operation. This is intentionally not an
//! arbitrary-container or repeated-capture replay qualification. Playing and
//! paused fill state require the separate profile-4 resource-aware entry point.
const std = @import("std");
const trace = @import("sme-trace");
const chunks = trace.chunks;
const capture = trace.chunk_recording;
const pcm_proof = trace.chunk_pcm_proof;
const public = @import("public_replay.zig");
const save = @import("save_state.zig");
const v1 = @import("runtime_contract.zig");
const context_host = trace.schema.context_host;
pub const Source = public.ChunkSource;
pub const maximum_operation_burst: u64 = capture.data_cell_count * capture.records_per_cell;

/// These buffers and storage belong exclusively to this invocation. Storage is
/// address-stable and must outlive the owner, including owner destruction. Source
/// holds a finalized immutable lease for the entire call. Source/sink contexts
/// must not alias buffers or mutate/reenter the owner, exporter or this session.
/// No allocation is performed by this driver. Sizes are fixed by local limits,
/// operation burst capacity and quantum, never total duration.
pub const Resources = struct {
    preflight: Source.Scratch,
    groups: Source.Scratch,
    schedule: Source.Scratch,
    visibility: Source.Scratch,
    operation: []trace.Input,
    pcm: []f32,
    storage: *capture.Storage,
    export_scratch: *capture.Scratch,
    actual_payload: []u8,
};

/// One synchronous non-RT call per completed and evidence-checked Render.
/// accepted must confirm precisely the ENTIRE span. Partial/would_block/error/
/// uncertainty permanently fail this run; the span and Render are never retried.
/// Keep all output provisional until recompute returns successfully. Consumers
/// requiring asynchronous backpressure must provide their own bounded blocking
/// sink outside the engine and must not retain the borrowed PCM slice.
pub const WriteResult = union(enum) { accepted: usize, would_block, failed, uncertain };
pub const PcmSpan = struct { frame_begin: u64, render_index: u64, samples: []const f32 };
pub const Sink = struct { context: *anyopaque, write: *const fn (*anyopaque, PcmSpan) WriteResult };
pub const Options = struct {
    source_limits: Source.Limits,
    recording_nonce: trace.schema.Hash,
    storage_id: u64,
    incarnation: u64,
    original_pcm: ?pcm_proof.Proof = null,
    sink: ?Sink = null,
};
pub const Result = struct {
    /// Full canonical input/schedule equality and real runtime closure. No
    /// legacy envelope seal, export/durability receipt or source authenticity.
    evidence: enum { actual_runtime_and_ordered_records_match } = .actual_runtime_and_ordered_records_match,
    source_recording_id: trace.schema.Hash,
    source_terminal_hash: trace.schema.Hash,
    inputs: u64,
    schedule: u64,
    operations: u64,
    pcm: pcm_proof.PcmAssessment,
};
pub const State = enum { unused, preparing, running, complete, failed };
pub const Operation = enum { none, begin, tick_preparation, control_tick, render_preparation, render, end, capture_begin, capture_poll, capture_ack, restore_submit, restore_poll, restore_ack, context_start, context_submit, context_poll_receipt, context_poll_phase_receipt };

/// One-shot attempt, including failed preflight. Inspect state/last_operation
/// after an error; a started/partially failed owner call must never be repeated.
/// A new session requires fresh storage and a pristine independently loaded owner.
pub const Session = struct {
    state: State = .unused,
    last_operation: Operation = .none,
    owner_attached: bool = false,
    completed_operations: u64 = 0,
    completed_renders: u64 = 0,
    rendered_frames: u64 = 0,
    failure: ?anyerror = null,

    /// Compatibility entry point: profile 2 only, with no state-resource access.
    pub fn recompute(self: *Session, owner: anytype, source: Source.ImmutableSource, resources: Resources, options: Options) anyerror!Result {
        return self.recomputeImpl(null, owner, source, resources, options, null, null);
    }

    /// Explicit profile-7 opt-in. Replay invokes only recorded host calls and
    /// preserves their original typed arguments, exact errors and every poll.
    /// Accepted request facts are comparison-only; no implicit drain is used.
    pub fn recomputeWithContextCalls(self: *Session, owner: anytype, source: Source.ImmutableSource, resources: Resources, options: Options) anyerror!Result {
        return self.recomputeImpl(.stream_context_serial_v1, owner, source, resources, options, null, null);
    }

    /// Explicit profile-3 opt-in with one fixed, caller-owned snapshot slot and
    /// decoded preflight scratch. Both outlive this invocation and are disjoint
    /// from every writable range and immutable source bytes. No captured state
    /// is supplied as an outcome:
    /// in-record capture starts empty and populates the slot through real polls.
    pub fn recomputeWithStateResources(self: *Session, owner: anytype, source: Source.ImmutableSource, resources: Resources, options: Options, snapshots: *public.SnapshotResources, snapshot_scratch: *save.Decoded) anyerror!Result {
        return self.recomputeImpl(.stream_direct_state_serial_v1, owner, source, resources, options, snapshots, snapshot_scratch);
    }

    /// Explicit profile-4 opt-in, with the same fixed one-slot/nonalias contract.
    /// Playing/settled-paused fill capture, drained restore and pause/resume use
    /// the real owner calls; live-route replacement remains unsupported.
    /// Registered external bytes are checked against the loaded bank
    /// before attachment, and an in-record capture requires an empty slot.
    pub fn recomputeWithFillStateResources(self: *Session, owner: anytype, source: Source.ImmutableSource, resources: Resources, options: Options, snapshots: *public.SnapshotResources, snapshot_scratch: *save.Decoded) anyerror!Result {
        return self.recomputeImpl(.stream_fill_state_serial_v1, owner, source, resources, options, snapshots, snapshot_scratch);
    }

    fn recomputeImpl(self: *Session, comptime resource_profile: ?public.Profile, owner: anytype, source: Source.ImmutableSource, resources: Resources, options: Options, snapshots: ?*public.SnapshotResources, snapshot_scratch: ?*save.Decoded) anyerror!Result {
        if (self.state != .unused) return error.InvalidState;
        // Validate all writable ranges before touching even this session. The
        // caller's immutable source/context lifetime is an explicit contract.
        try requireDisjoint(owner, self, resources, snapshots, snapshot_scratch);
        self.state = .preparing;
        errdefer |err| {
            self.failure = err;
            self.state = .failed;
            if (self.owner_attached) owner.failRecordingV1();
        }
        if (resources.storage.status().state != .uninitialized or options.storage_id == 0 or options.incarnation == 0) return error.InvalidState;
        var limits = options.source_limits;
        limits.max_conservative_operation_burst_records = @min(limits.max_conservative_operation_burst_records orelse maximum_operation_burst, maximum_operation_burst);
        // Never trust a caller-modified Prepared value. Every byte and all
        // grammar/burst/resource bounds are revalidated before owner attachment.
        const prepared = if (resource_profile == .stream_context_serial_v1)
            try Source.preflightWithContextCalls(source, resources.preflight, limits)
        else if (resource_profile == .stream_fill_state_serial_v1)
            try Source.preflightWithFillStateResources(source, resources.preflight, limits, snapshots orelse return error.ResourceNotPrepared, snapshot_scratch orelse return error.InvalidLimits)
        else if (snapshots) |table|
            try Source.preflightWithStateResources(source, resources.preflight, limits, table, snapshot_scratch orelse return error.InvalidLimits)
        else
            try Source.preflight(source, resources.preflight, limits);
        if (!public.isChunkStream(prepared.runtime_profile)) return error.UnsupportedProfile;
        if (prepared.conservative_operation_burst_records > maximum_operation_burst) return error.OperationBurstTooLarge;
        const quantum = prepared.framing.identity.quantum_frames;
        if (quantum > pcm_proof.max_quantum_frames or resources.pcm.len < try std.math.mul(usize, quantum, 2)) return error.InvalidLimits;
        _ = try chunks.Preamble.init(prepared.framing.identity, prepared.runtime_profile, options.recording_nonce);
        try owner.requireChunkReplayIdentityForProfileV1(prepared.framing.identity, prepared.runtime_profile);
        if (prepared.bank_resource) |expected| try owner.requireChunkReplayBankResourceV1(expected);
        if (public.isStateProfile(prepared.runtime_profile)) {
            const table = snapshots orelse return error.ResourceNotPrepared;
            // Source preflight authenticated these exact bytes and populated
            // decoded scratch. Check bank-dependent semantics while the owner
            // is still pristine, before attachment or any restore submission.
            if (table.resource != null) {
                const decoded = snapshot_scratch orelse return error.InvalidLimits;
                if (resource_profile == .stream_fill_state_serial_v1)
                    try owner.requireChunkReplayFillSnapshotV1(decoded)
                else
                    try owner.requireChunkReplaySnapshotV1(decoded);
            }
        }
        var groups = try Source.GroupCursor.init(&prepared, resources.groups, resources.operation);
        var schedule = try Source.ScheduleCursor.init(&prepared, resources.schedule);
        var visibility = try Source.VisibilityCursor.init(&prepared, resources.visibility);
        var pcm = try pcm_proof.Verifier.init(options.original_pcm, pcm_proof.SourceBinding.fromFraming(prepared.framing, prepared.rendered_frames));
        // Flushing after every operation can change transport framing and byte
        // count. Bound this independently of the original frame partitioning.
        const actual_limits = try outputLimits(&prepared);
        var actual: Comparison = .{
            .validator = try chunks.Validator.init(resources.actual_payload, actual_limits),
            .schedule = &schedule,
            .max_parser_calls = try std.math.add(u64, try std.math.mul(u64, actual_limits.max_frames, 4), 1),
            .max_record_visits = try std.math.add(u64, prepared.framing.total_inputs, prepared.framing.total_schedule),
        };
        // Load the first complete group before mutation; begin is emitted by the
        // one attachment and is compared rather than executed a second time.
        const first = (try groups.next()) orelse return error.IncompleteTrace;
        if (first.input_begin != 0 or first.marker().payload != .runtime_step or first.marker().payload.runtime_step.kind != .begin) return error.InvalidOrder;
        const beginning = owner.beginChunkRecordingV1(resources.storage, .{
            .profile = prepared.runtime_profile,
            .recording_nonce = options.recording_nonce,
            .storage_id = options.storage_id,
            .incarnation = options.incarnation,
            .max_inputs = prepared.framing.total_inputs,
        });
        switch (beginning) {
            .not_started => |err| return @as(anyerror!Result, err),
            .started => |started| {
                self.owner_attached = true;
                self.last_operation = .begin;
                try started.engine_result;
                try healthy(started.recording_status, false);
            },
        }
        var exporter = try capture.Exporter.init(resources.storage, resources.export_scratch);
        // Failure cleanup never retries an operation or certifies accepted bytes.
        // Storage remains attached/address-stable until the owner is destroyed.
        errdefer {
            owner.failRecordingV1();
            exporter.abandonArtifact() catch {};
            resources.storage.serviceFailure();
            exporter.discardRemaining() catch {};
            exporter.deinit() catch {};
        }
        self.state = .running;
        try owner.beginChunkStreamReplayV1();
        try actual.drain(resources.storage, &exporter, first);
        self.completed_operations = 1;
        var ended = false;
        while (try groups.next()) |group| {
            try actual.requireDrained(resources.storage, &exporter);
            if (ended) return error.InvalidOrder;
            const marker = group.marker();
            var render_observation: ?public.RenderObservation = null;
            if (marker.payload == .context_host_operation) {
                if (prepared.runtime_profile != .stream_context_serial_v1 or group.records.len != 2 or
                    marker.payload.context_host_operation != .call or group.records[1].payload != .context_host_operation or
                    group.records[1].payload.context_host_operation != .result) return error.InvalidOrder;
                const op = marker.payload.context_host_operation.call;
                const expected = group.records[1].payload.context_host_operation.result.outcome;
                switch (op.args) {
                    .start => |args| try self.contextInvocation(owner.recordChunkStartV1(args.bank.toPublic(), @enumFromInt(args.state)), .context_start, expected),
                    .submit => |args| try self.contextInvocation(owner.recordChunkSubmitV1(args.bank.toPublic(), args.payload.toPublic()), .context_submit, expected),
                    .poll_receipt => try self.contextInvocation(owner.recordChunkPollReceiptV1(), .context_poll_receipt, expected),
                    .poll_phase_receipt => try self.contextInvocation(owner.recordChunkPollPhaseReceiptV1(), .context_poll_phase_receipt, expected),
                }
            } else if (marker.payload == .state_host_operation) {
                // The source already proved call -> generated facts -> result
                // grouping, even across frames. Only invoke the actual call;
                // no recorded result, snapshot or install receipt is injected.
                const op = marker.payload.state_host_operation.call;
                const table = snapshots orelse return error.ResourceNotPrepared;
                const bank: v1.BankRefV1 = .{ .context = op.context, .handle = .{ .index = op.bank_index, .generation = op.bank_incarnation }, .asset_generation = op.bank.generation };
                const capture_ticket: save.TicketV1 = .{ .context = op.context, .incarnation = op.ticket };
                const restore_ticket: v1.RequestTicketV1 = .{ .context = op.context, .request_id = op.ticket, .bank = bank };
                switch (op.kind) {
                    .capture_begin => try self.stateInvocation(owner.recordChunkCaptureStateV1(bank), .capture_begin),
                    .capture_poll => try self.stateInvocation(owner.recordChunkPollCaptureStateV1(capture_ticket, table), .capture_poll),
                    .capture_ack => try self.stateInvocation(owner.recordChunkAcknowledgeCaptureV1(capture_ticket), .capture_ack),
                    .restore_submit => {
                        _ = try table.resolveV1(op.snapshot.?);
                        try self.stateInvocation(owner.recordChunkRestoreStateV1(bank, table), .restore_submit);
                    },
                    .restore_poll => try self.stateInvocation(owner.recordChunkPollRestoreStateV1(restore_ticket), .restore_poll),
                    .restore_ack => try self.stateInvocation(owner.recordChunkAcknowledgeRestoreV1(restore_ticket), .restore_ack),
                }
            } else {
                if (marker.payload != .runtime_step) return error.InvalidOrder;
                const step = marker.payload.runtime_step;
                switch (step.kind) {
                    .begin => return error.InvalidOrder,
                    .control_tick => {
                        self.last_operation = .tick_preparation;
                        try owner.prepareChunkStreamReplayTickV1(group.facts());
                        // Profile 7 has already invoked the exact host calls.
                        // Re-submitting accepted facts would lose synchronous
                        // failures, duplicate requests and change receipt credits.
                        if (prepared.runtime_profile != .stream_context_serial_v1) for (group.facts()) |input| if (input.payload == .request) {
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
                        const invocation = owner.recordChunkControlTickV1(step.control_limit);
                        switch (invocation) {
                            .not_started => |err| return @as(anyerror!Result, err),
                            .started => |started| {
                                self.last_operation = .control_tick;
                                _ = try started.engine_result;
                                try healthy(started.recording_status, false);
                            },
                        }
                        if (prepared.runtime_profile != .stream_context_serial_v1) try drainHostReceipts(owner);
                    },
                    .render => {
                        self.last_operation = .render_preparation;
                        try owner.prepareChunkStreamReplayRenderV1(&visibility);
                        const count = try std.math.mul(usize, step.frame_count, 2);
                        const invocation = owner.recordChunkRenderV1(resources.pcm[0..count], step.frame_count);
                        switch (invocation) {
                            .not_started => |err| return @as(anyerror!Result, err),
                            .started => |started| {
                                self.last_operation = .render;
                                const observation = try started.engine_result;
                                if (!observation.completed) return error.IncompleteTrace;
                                // Preserve actual progress even if evidence/sink
                                // subsequently fails; Render already happened.
                                self.rendered_frames = observation.frame_after;
                                self.completed_renders = try std.math.add(u64, self.completed_renders, 1);
                                try healthy(started.recording_status, false);
                                render_observation = observation;
                            },
                        }
                    },
                    .end => {
                        const invocation = owner.endChunkRecordingV1();
                        switch (invocation) {
                            .not_started => |err| return @as(anyerror!Result, err),
                            .started => |started| {
                                self.last_operation = .end;
                                try started.engine_result;
                                try healthy(started.recording_status, true);
                            },
                        }
                        ended = true;
                    },
                    else => return error.UnsupportedOperation,
                }
            }
            // Authoritative record equality before publishing this PCM span.
            try actual.drain(resources.storage, &exporter, group);
            if (render_observation) |observation| {
                const samples = resources.pcm[0 .. @as(usize, observation.requested_frames) * 2];
                try pcm.appendSuccessfulRender(observation, samples);
                if (options.sink) |sink| switch (sink.write(sink.context, .{ .frame_begin = observation.frame_before, .render_index = self.completed_renders - 1, .samples = samples })) {
                    .accepted => |n| if (n != samples.len) return error.PcmSinkPartial,
                    .would_block => return error.PcmSinkWouldBlock,
                    .failed => return error.PcmSinkFailed,
                    .uncertain => return error.PcmSinkUncertain,
                };
            }
            self.completed_operations = try std.math.add(u64, self.completed_operations, 1);
        }
        if (!ended or self.completed_operations != prepared.total_operations or self.rendered_frames != prepared.rendered_frames) return error.IncompleteTrace;
        try groups.requireExhausted();
        try schedule.requireExhausted();
        try visibility.requireExhausted();
        try actual.requireDrained(resources.storage, &exporter);
        if (!exporter.terminal_consumed) return error.IncompleteTrace;
        const framing = try actual.validator.finishAtEof();
        if (!std.meta.eql(framing.identity, prepared.framing.identity) or
            framing.total_inputs != prepared.framing.total_inputs or framing.total_schedule != prepared.framing.total_schedule or
            actual.inputs != prepared.framing.total_inputs or actual.schedules != prepared.framing.total_schedule) return error.ReplayMismatch;
        const status = try owner.chunkRecordingStatusV1();
        try healthy(status, true);
        if (status.incomplete or !status.terminal_acknowledged or status.retained_inputs != actual.inputs or status.retained_schedule != actual.schedules) return error.IncompleteTrace;
        const assessment = try pcm.finish();
        // Manual acknowledgements intentionally cannot yield ExportCompletion.
        // This run compared semantic rows, not partition-sensitive chunk hashes.
        try exporter.deinit();
        self.state = .complete;
        return .{ .source_recording_id = prepared.framing.recording_id, .source_terminal_hash = prepared.framing.terminal_hash, .inputs = actual.inputs, .schedule = actual.schedules, .operations = self.completed_operations, .pcm = assessment };
    }

    fn contextInvocation(self: *Session, invocation: anytype, comptime operation: Operation, expected: context_host.Outcome) anyerror!void {
        switch (invocation) {
            .not_started => |err| return err,
            .started => |started| {
                self.last_operation = operation;
                // Known synchronous errors are genuine recorded observations,
                // not failed replay ticks and not permission to invent results.
                const observed: context_host.Outcome = if (started.engine_result) |value|
                    switch (operation) {
                        .context_start, .context_submit => .{ .submitted = context_host.Ticket.fromPublic(value) },
                        .context_poll_receipt => .{ .receipt = if (value) |receipt| context_host.Receipt.fromPublic(receipt) else null },
                        .context_poll_phase_receipt => .{ .phase_receipt = if (value) |receipt| context_host.PhaseReceipt.fromPublic(receipt) else null },
                        else => @compileError("unsupported context host invocation"),
                    }
                else |err|
                    .{ .failed = try context_host.SyncError.fromError(err) };
                if (!std.meta.eql(observed, expected)) return error.ReplayMismatch;
                try healthy(started.recording_status, false);
            },
        }
    }

    fn stateInvocation(self: *Session, invocation: anytype, operation: Operation) anyerror!void {
        switch (invocation) {
            .not_started => |err| return err,
            .started => |started| {
                self.last_operation = operation;
                _ = try started.engine_result;
                try healthy(started.recording_status, false);
            },
        }
    }
};

/// A valid live host may poll these queues between ticks. Ordinary request
/// receipt polling returns reserved ingress credits; omitting it would impose a
/// hidden lifetime request-count limit even though every operation is bounded.
/// Drain only actual public receipts, never fabricate/inject expected outcomes.
/// State-ticket polls are separate operations; these ordinary diagnostic queues
/// do not acknowledge or advance capture/restore transactions.
fn drainHostReceipts(owner: anytype) !void {
    const contract = @import("runtime_contract.zig");
    const capacity: contract.CapacityV1 = .{};
    for (0..capacity.receipt_slots) |_| {
        if (try owner.pollReceiptV1() == null) break;
    }
    for (0..contract.resident_fill_hard_cut_v1.phase_receipt_slots) |_| {
        if (try owner.pollPhaseReceiptV1() == null) break;
    }
}

fn healthy(status: capture.Status, sealed: bool) !void {
    if (status.state != (if (sealed) capture.State.sealed else capture.State.active) or status.reason != .none or status.export_failed or
        status.producer_closed != sealed or status.successful_end_staged != sealed) return error.RecorderIncomplete;
}
fn outputLimits(prepared: *const Source.Prepared) !chunks.LocalLimits {
    const data_frames = try std.math.mul(u64, prepared.total_operations - 1, capture.data_cell_count);
    const frames = try std.math.add(u64, data_frames, 1);
    const bytes = try std.math.add(u64, chunks.preamble_bytes, try std.math.mul(u64, frames, chunks.frame_header_bytes + chunks.max_payload_bytes));
    return .{ .max_total_inputs = prepared.framing.total_inputs, .max_total_schedule = prepared.framing.total_schedule, .max_frames = frames, .max_total_bytes = bytes };
}
fn overlaps(a: []const u8, b: []const u8) bool {
    if (a.len == 0 or b.len == 0) return false;
    const ap = @intFromPtr(a.ptr);
    const bp = @intFromPtr(b.ptr);
    return if (ap <= bp) bp - ap < a.len else ap - bp < b.len;
}
fn requireDisjoint(owner: anytype, session: *Session, r: Resources, snapshots: ?*public.SnapshotResources, snapshot_scratch: ?*save.Decoded) !void {
    const ranges = [_][]const u8{
        std.mem.asBytes(owner),                                             std.mem.asBytes(session),    std.mem.asBytes(r.storage), std.mem.asBytes(r.export_scratch),
        r.preflight.io,                                                     r.preflight.payload,         r.groups.io,                r.groups.payload,
        r.schedule.io,                                                      r.schedule.payload,          r.visibility.io,            r.visibility.payload,
        std.mem.sliceAsBytes(r.operation),                                  std.mem.sliceAsBytes(r.pcm), r.actual_payload,           if (snapshots) |table| std.mem.asBytes(table) else &.{},
        if (snapshot_scratch) |decoded| std.mem.asBytes(decoded) else &.{},
    };
    for (ranges, 0..) |left, i| for (ranges[i + 1 ..]) |right| {
        if (overlaps(left, right)) return error.InvalidLimits;
    };
}

const Comparison = struct {
    validator: chunks.Validator,
    schedule: *Source.ScheduleCursor,
    inputs: u64 = 0,
    schedules: u64 = 0,
    parser_calls: u64 = 0,
    record_visits: u64 = 0,
    max_parser_calls: u64,
    max_record_visits: u64,

    fn requireDrained(self: *const Comparison, storage: *const capture.Storage, exporter: *const capture.Exporter) !void {
        if (exporter.active != null or storage.active != null or exporter.next_sequence != storage.next_sequence + @intFromBool(exporter.terminal_consumed)) return error.UndrainedCapture;
        for (&storage.cells) |*cell| if (cell.state.load(.acquire) != .free) return error.UndrainedCapture;
        const status = storage.status();
        if (status.retained_inputs != self.inputs or status.retained_schedule != self.schedules) return error.UndrainedCapture;
    }
    fn drain(self: *Comparison, storage: *capture.Storage, exporter: *capture.Exporter, group: Source.OperationGroup) !void {
        if (self.inputs != group.input_begin) return error.ReplayMismatch;
        if (storage.status().state == .active and storage.flush() != .retained) return error.RecorderIncomplete;
        var matched: usize = 0;
        // Four data cells plus the separately reserved terminal. No unbounded
        // polling loop or scheduling-dependent concurrent exporter is needed.
        for (0..capture.data_cell_count + 1) |_| {
            const lease = (try exporter.poll()) orelse break;
            const batch = try exporter.encodeLease(lease);
            try self.consume(batch.preamble, group, &matched);
            try self.consume(batch.header, group, &matched);
            try self.consume(batch.payload, group, &matched);
            try exporter.ack(lease);
        }
        if (matched != group.records.len) return error.MissingAdmission;
        try self.requireDrained(storage, exporter);
    }
    fn consume(self: *Comparison, bytes: []const u8, group: Source.OperationGroup, matched: *usize) !void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            if (self.parser_calls >= self.max_parser_calls) return error.WorkLimit;
            self.parser_calls += 1;
            const result = try self.validator.feed(bytes[offset..]);
            if (result.consumed == 0 or result.consumed > bytes.len - offset) return error.InvalidState;
            offset += result.consumed;
            if (result.frame) |frame| {
                var records = frame.records();
                while (try records.next()) |record| {
                    if (self.record_visits >= self.max_record_visits) return error.WorkLimit;
                    self.record_visits += 1;
                    switch (record) {
                        .input => |input| {
                            if (matched.* >= group.records.len or self.inputs != group.input_begin + matched.* or
                                !std.meta.eql(input, group.records[matched.*])) return error.ReplayMismatch;
                            matched.* += 1;
                            self.inputs += 1;
                        },
                        .schedule => |entry| {
                            const expected = (try self.schedule.next()) orelse return error.ScheduleMismatch;
                            if (expected.ordinal != self.schedules or !std.meta.eql(entry, expected.value)) return error.ScheduleMismatch;
                            self.schedules += 1;
                        },
                    }
                }
            }
        }
    }
};
