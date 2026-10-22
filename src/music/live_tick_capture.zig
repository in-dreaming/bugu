//! Call-scoped Control chronology capture. This is not a replay driver, public
//! recording profile, durability guarantee or proof of Worker/Render closure.
//! The caller owns fixed record and byte storage; do not move/free/overwrite it
//! until all borrowed records have been encoded or discarded. Never attach the
//! same instance concurrently. Sink loss is sticky and cannot affect audio.
const std = @import("std");
const audio = @import("bugu_audio");
const rt = audio.runtime;
const trace = @import("sme-trace");
pub const grammar = @import("live_chronology.zig");
pub const format = @import("live_chronology_format.zig");
pub const Error = error{ Overflow, Unsupported, InvalidObservation, Closed, Incomplete, Poisoned };

/// Explicit protocol codes, independent of compiler error-set ordinals.
pub const Reason = enum(u32) {
    invalid_state = 1, concurrent_control = 2, invalid_argument = 3,
    late_command = 4, command_queue_full = 5, invalid_mode = 6,
    out_of_memory = 7, buffer_too_small = 8, invalid_order = 9,
    runtime_stopped = 10, stale_asset_generation = 11, source_read_failed = 12,
    source_unavailable = 13, invalid_source = 14, invalid_binding = 15,
    stream_capacity = 16, job_capacity = 17, stale_stream = 18,
    drain_pending = 19, worker_busy = 20, invalid_window = 21,
    ring_full = 22, hash_mismatch = 23, resource_not_prepared = 24,
    incomplete_trace = 25, unsafe_frame_range = 26, snapshot_busy = 27,
    overflow = 28, invalid_handle = 29, unsupported_capability = 30,
    availability_deferred = 100, stop_deferred = 101, cold_start_deferred = 102,
    odd_sequence = 200, sequence_changed = 201, ring_capacity = 202, publication_capacity = 203,
};
pub fn reasonForError(err: anyerror) ?Reason {
    return switch (err) {
        error.InvalidState => .invalid_state, error.ConcurrentControl => .concurrent_control,
        error.InvalidArgument => .invalid_argument, error.LateCommand => .late_command,
        error.CommandQueueFull => .command_queue_full, error.InvalidMode => .invalid_mode,
        error.OutOfMemory => .out_of_memory, error.BufferTooSmall => .buffer_too_small,
        error.InvalidOrder => .invalid_order, error.RuntimeStopped => .runtime_stopped,
        error.StaleAssetGeneration => .stale_asset_generation, error.SourceReadFailed => .source_read_failed,
        error.SourceUnavailable => .source_unavailable, error.InvalidSource => .invalid_source,
        error.InvalidBinding => .invalid_binding, error.StreamCapacity => .stream_capacity,
        error.JobCapacity => .job_capacity, error.StaleStream => .stale_stream,
        error.DrainPending => .drain_pending, error.WorkerBusy => .worker_busy,
        error.InvalidWindow => .invalid_window, error.RingFull => .ring_full,
        error.HashMismatch => .hash_mismatch, error.ResourceNotPrepared => .resource_not_prepared,
        error.IncompleteTrace => .incomplete_trace, error.UnsafeFrameRange => .unsafe_frame_range,
        error.SnapshotBusy => .snapshot_busy, error.Overflow => .overflow,
        error.InvalidHandle => .invalid_handle, error.UnsupportedCapability => .unsupported_capability,
        else => null,
    };
}
fn phase(value: rt.ControlRuntime.TickPhaseV1) ?grammar.Phase {
    return switch (value) { .collect => .collect, .accept => .accept, .prepare => .prepare, .publish => .publish, .idle => null };
}
fn origin(value: rt.ControlRuntime.LiveTickFailureOriginV1) grammar.FailureOrigin {
    return switch (value) {
        .collect_owner => .collect_owner, .accept_device => .accept_device, .accept_replay => .accept_replay,
        .accept_drain => .accept_drain, .prepare_owner => .prepare_owner,
        .prepare_failure_drain => .prepare_failure_drain, .prepare_success_drain => .prepare_success_drain,
        .snapshot => .snapshot, .accept_acquire => .accept_acquire, .accept_sync => .accept_sync, .accept_live => .accept_live,
    };
}
fn preparationReason(value: @import("resident_runtime.zig").MusicRuntime.LiveTickPreparationV1) ?Reason {
    if (value.deferred != null) return .availability_deferred;
    if (value.stop_deferred != null) return .stop_deferred;
    if (value.cold_start_deferred != null) return .cold_start_deferred;
    return null;
}
fn scheduleDetail(value: @import("resident_runtime.zig").MusicRuntime.LiveStopDeferV1) grammar.ScheduleDefer {
    return .{
        .ticket_context = value.ticket.context, .request_id = value.ticket.request_id,
        .bank_context = value.ticket.bank.context, .bank_index = value.ticket.bank.handle.index,
        .bank_generation = value.ticket.bank.handle.generation, .asset_generation = value.ticket.bank.asset_generation,
        .group_index = value.group.index, .group_generation = value.group.generation, .plan_id = value.plan_id,
        .start_frame = value.prepare.start_frame, .end_frame = value.prepare.end_frame,
        .observed_horizon = value.prepare.observed_horizon, .minimum_frame = value.prepare.minimum_frame,
    };
}

pub const Capture = struct {
    header: format.Header,
    records: []grammar.Record,
    input_bytes: []u8,
    count: usize = 0,
    used: usize = 0,
    wire_bytes: u64 = format.header_size + format.frame_size, // reserve terminal
    operations: u64 = 0,
    points: u64 = 0,
    occurrences: [14]u64 = @splat(0),
    active: bool = false,
    current_tick: u64 = 0,
    current_frame: u64 = 0,
    pending_worker: ?[]const u8 = null,
    failure: ?Error = null,
    closed: bool = false,

    pub fn init(header: format.Header, records: []grammar.Record, input_bytes: []u8) !Capture {
        _ = try grammar.Validator.init(header.chronology, header.chronology.identity);
        if (header.max_bytes < format.header_size + format.frame_size or header.max_bytes == std.math.maxInt(u64)) return error.Overflow;
        return .{ .header = header, .records = records, .input_bytes = input_bytes };
    }
    pub fn sink(self: *Capture) rt.ControlRuntime.LiveAcceptanceSinkV1 {
        return .{ .context = self, .emit = onAcceptance, .frontier = onFrontier, .event = onEvent, .input = onInput };
    }
    pub fn retained(self: *const Capture) []const grammar.Record { return self.records[0..self.count]; }
    fn fail(self: *Capture, err: Error) void { if (self.failure == null) self.failure = err; }
    fn point(self: *Capture, site: grammar.Site) grammar.PointId {
        const index = @intFromEnum(site) - 1;
        if (self.points >= self.header.chronology.max_points_per_operation or self.occurrences[index] == std.math.maxInt(u64)) {
            self.fail(error.Overflow);
            return .{ .site = site, .occurrence = 0 };
        }
        self.points += 1; self.occurrences[index] += 1;
        return .{ .site = site, .occurrence = self.occurrences[index] };
    }
    fn append(self: *Capture, payload: grammar.Payload) void {
        if (self.failure != null) return;
        if (self.closed) { self.fail(error.Closed); return; }
        if (self.count >= self.records.len or self.count >= self.header.chronology.max_records or self.count == std.math.maxInt(u64)) { self.fail(error.Overflow); return; }
        var size: u64 = format.frame_size;
        switch (payload) {
            .retained_input => |value| size = format.input_frame_overhead + value.bytes.len,
            .preparation_defer => |value| {
                var buffer: [trace.codec.maxSize(grammar.PreparationDefer)]u8 = undefined;
                var encoder: trace.codec.Encoder = .{ .bytes = &buffer };
                encoder.put(value) catch { self.fail(error.InvalidObservation); return; };
                size = 96 + encoder.offset;
            },
            else => {},
        }
        const next = std.math.add(u64, self.wire_bytes, size) catch { self.fail(error.Overflow); return; };
        if (next > self.header.max_bytes) { self.fail(error.Overflow); return; }
        self.records[self.count] = .{ .identity = self.header.chronology.identity, .role = .control, .sequence = self.count + 1, .operation = self.operations + 1, .payload = payload };
        self.count += 1; self.wire_bytes = next;
    }
    fn errorCode(self: *Capture, err: anyerror) ?u32 {
        const reason = reasonForError(err) orelse { self.fail(error.Unsupported); return null; };
        return @intFromEnum(reason);
    }
    fn onInput(raw: *anyopaque, value: trace.Input) void {
        const self: *Capture = @ptrCast(@alignCast(raw));
        if (self.failure != null) return;
        if (!self.active or self.pending_worker != null) { self.fail(error.InvalidObservation); return; }
        switch (value.payload) { .request, .worker, .device, .admission, .readiness_snapshot => {}, else => { self.fail(error.Unsupported); return; } }
        // Encode directly into caller-owned storage. No source pointer escapes.
        const remaining = self.input_bytes[self.used..];
        var encoder: trace.codec.Encoder = .{ .bytes = remaining[0..@min(remaining.len, grammar.input_max_bytes)] };
        encoder.put(value) catch { self.fail(error.Overflow); return; };
        const bytes = encoder.bytes[0..encoder.offset];
        self.used += encoder.offset;
        self.append(.{ .retained_input = .{ .id = self.point(.control_input), .bytes = bytes } });
        if (value.payload == .worker) self.pending_worker = bytes;
    }
    fn onFrontier(raw: *anyopaque, native_phase: rt.ControlRuntime.TickPhaseV1, observed: u64, effective: u64) void {
        const self: *Capture = @ptrCast(@alignCast(raw));
        if (self.failure != null) return;
        const site: grammar.Site = switch (native_phase) { .collect => .control_collect_frontier, .accept => .control_accept_frontier, else => { self.fail(error.InvalidObservation); return; } };
        self.append(.{ .frontier = .{ .id = self.point(site), .raw_frame = observed, .effective_frame = effective } });
        self.current_frame = effective;
    }
    fn onAcceptance(raw: *anyopaque, attempt: *const rt.streaming.stream.LiveAcceptanceAttemptV1, effective: u64) void {
        const self: *Capture = @ptrCast(@alignCast(raw));
        if (self.failure != null) return;
        const observed = attempt.evidence.availability;
        var value: grammar.Acceptance = .{ .id = self.point(.control_accept), .incoming_frame = attempt.incoming.accepted_control_frame, .outcome = .no_completion };
        if (observed.sequence_before) |before| value.cut = .{ .sequence_before = before, .sequence_after = observed.sequence_after, .frame = observed.frame, .consumed = observed.consumed, .produced = observed.produced };
        if (attempt.returned_error) |err| {
            value.outcome = .failed; value.reason = self.errorCode(err) orelse return;
        } else if (attempt.deferred) |deferred| {
            value.outcome = .unstable;
            value.reason = @intFromEnum(switch (deferred.reason) { .odd_sequence => Reason.odd_sequence, .sequence_changed => Reason.sequence_changed });
        } else switch (attempt.evidence.outcome) {
            .no_completion => {},
            .ring_capacity => { value.outcome = .deferred; value.reason = @intFromEnum(Reason.ring_capacity); },
            .publication_capacity => { value.outcome = .deferred; value.reason = @intFromEnum(Reason.publication_capacity); },
            .accepted => {
                const accepted = attempt.evidence.accepted orelse { self.fail(error.InvalidObservation); return; };
                const retained_bytes = self.pending_worker orelse { self.fail(error.Incomplete); return; };
                var bytes: [grammar.input_max_bytes]u8 = undefined;
                var encoder: trace.codec.Encoder = .{ .bytes = &bytes };
                encoder.put(accepted.input) catch { self.fail(error.InvalidObservation); return; };
                if (!std.mem.eql(u8, retained_bytes, bytes[0..encoder.offset]) or accepted.input.payload != .worker) { self.fail(error.InvalidObservation); return; }
                value.outcome = .accepted; value.input_order = accepted.input.position.input_order;
                value.batch = attempt.evidence.batch_id; value.worker_job = accepted.input.payload.worker.job;
                self.pending_worker = null;
            },
            else => { self.fail(error.Unsupported); return; },
        }
        self.append(.{ .acceptance = value }); self.current_frame = effective;
    }
    fn onEvent(raw: *anyopaque, event: rt.ControlRuntime.LiveTickEventV1) void {
        const self: *Capture = @ptrCast(@alignCast(raw));
        if (self.failure != null) return;
        switch (event) {
            .begin => |value| {
                if (self.active or value.tick == 0 or self.operations >= self.header.chronology.max_operations_per_role) { self.fail(error.InvalidObservation); return; }
                self.active = true; self.points = 0; self.occurrences = @splat(0);
                self.current_tick = value.tick; self.current_frame = value.entry_frame;
                self.append(.{ .begin = .{ .tick = value.tick, .entry_frame = value.entry_frame, .prior_tick = if (self.operations == 0) value.tick - 1 else 0, .retained_inputs = true } });
            },
            .phase => |value| self.append(.{ .phase = phase(value) orelse { self.fail(error.InvalidObservation); return; } }),
            .collect_returned => |frame| self.append(.{ .observation = .{ .id = self.point(.control_collect), .outcome = .value, .effective_frame = frame } }),
            .prepare_returned => |prepared| {
                const value = prepared.value;
                const count: u8 = @as(u8, @intFromBool(value.deferred != null)) + @as(u8, @intFromBool(value.stop_deferred != null)) + @as(u8, @intFromBool(value.cold_start_deferred != null));
                if (count > 1) { self.fail(error.InvalidObservation); return; }
                const reason = preparationReason(value) orelse {
                    self.append(.{ .observation = .{ .id = self.point(.control_prepare), .outcome = .value, .effective_frame = prepared.frame } });
                    return;
                };
                var deferred: grammar.PreparationDefer = .{ .id = self.point(.control_prepare), .tick = self.current_tick, .frame = prepared.frame, .reason = @intFromEnum(reason), .detail = undefined };
                if (value.deferred) |cause| {
                    deferred.tick = cause.control_tick; deferred.frame = cause.accepted_control_frame;
                    const observation = cause.observation;
                    deferred.detail = .{ .availability = .{
                        .stage = switch (cause.stage) { .entry_supply => 1, .entry_readiness => 2, .recovery_supply => 3, .recovery_readiness => 4, .background_supply => 5 },
                        .operation = switch (observation.operation) { .prefetch => 1, .request => 2, .readiness => 3, .readiness_control_before => 4, .readiness_control_after => 5 },
                        .reason = switch (observation.reason) { .odd_sequence => 1, .frame_mismatch => 2, .sequence_changed => 3 },
                        .handle_index = observation.handle.index, .handle_generation = observation.handle.generation,
                        .requested_frame = observation.requested_frame, .observed_frame = observation.observed_frame,
                        .sequence_before = observation.sequence_before, .sequence_after = observation.sequence_after,
                    } };
                } else if (value.stop_deferred) |cause| {
                    deferred.tick = cause.control_tick; deferred.frame = cause.accepted_control_frame; deferred.detail = .{ .stop = scheduleDetail(cause) };
                } else if (value.cold_start_deferred) |cause| {
                    deferred.tick = cause.control_tick; deferred.frame = cause.accepted_control_frame; deferred.detail = .{ .cold_start = scheduleDetail(cause) };
                }
                self.append(.{ .preparation_defer = deferred });
            },
            .failure => |value| self.append(.{ .failure = .{ .id = self.point(.control_failure), .origin = origin(value.origin), .reason = self.errorCode(value.reason) orelse return } }),
            .snapshot => |recovery| self.append(.{ .snapshot = .{ .id = self.point(.control_snapshot), .path = if (recovery) .prepare_failure else .ordinary } }),
            .publish_returned => |frame| self.append(.{ .observation = .{ .id = self.point(.control_publish), .outcome = .value, .effective_frame = frame } }),
            .final_publish => |value| self.append(.{ .final_publish = .{ .id = self.point(.control_final_publish), .exit_phase = phase(value.exit_phase) orelse { self.fail(error.InvalidObservation); return; }, .effective_frame = value.frame } }),
            .end => |value| {
                if (!self.active or self.pending_worker != null) { self.fail(error.Incomplete); return; }
                const deferred = preparationReason(value.preparation);
                const reason: u32 = if (value.failure) |err| self.errorCode(err) orelse return else if (deferred) |cause| @intFromEnum(cause) else 0;
                self.append(.{ .end = .{ .outcome = if (value.failure != null) .failed else if (deferred != null) .deferred else .returned, .points = self.points, .effective_frame = value.frame, .reason = reason } });
                self.active = false; self.operations += 1;
            },
        }
    }
    /// Call only after this instance is detached from its synchronous tick.
    /// This seals Control-only structural evidence; never claims real joins.
    pub fn encodeStructural(self: *Capture, out: []u8) ![]const u8 {
        if (self.failure != null) return error.Poisoned;
        if (self.active or self.operations == 0) return error.Incomplete;
        if (self.closed) return error.Closed;
        errdefer self.fail(error.InvalidObservation);
        var encoder = try format.Encoder.init(self.header, self.header.chronology.identity, out);
        var used: usize = format.header_size;
        for (self.retained()) |record| used += (try encoder.record(record, out[used..])).len;
        const terminal: grammar.Terminal = .{ .identity = self.header.chronology.identity, .records = self.count, .role_sequences = .{ self.count, 0, 0 }, .role_operations = .{ self.operations, 0, 0 }, .producer_closed = @splat(true), .complete = true };
        used += (try encoder.finish(terminal, out[used..])).len;
        _ = try format.preflightCapture(out[0..used], self.header.chronology.identity, .{ .max_bytes = self.header.max_bytes, .max_records = self.header.chronology.max_records });
        self.closed = true;
        return out[0..used];
    }
};
