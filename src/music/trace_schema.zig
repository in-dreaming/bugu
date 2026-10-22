//! Versioned, public, numeric-only wire values. All exported schema fields in
//! this file are PUBLIC. No string/path/host pointer is a deterministic field.
const std = @import("std");
const music = @import("music");
pub const lifecycle = @import("trace_lifecycle.zig");
pub const readiness = @import("trace_readiness.zig");
pub const acoustic_observation = @import("acoustic_observation.zig");
pub const context_host = @import("context_host_journal.zig");
pub const version: u16 = 2;
pub const classification_version: u16 = 1;
pub const integer_rules_version: u16 = 1;
pub const max_record_bytes: usize = 512;
pub const max_events: u32 = 1_000_000;
pub const default_ring_capacity: usize = 1024;
pub const Error = error{ UnknownVersion, InvalidHeader, InvalidEvent, InvalidOrder, IncompleteTrace, HashMismatch, MissingReadiness, MissingAdmission, ResourceNotPrepared, UnsupportedMigration, InvalidScalar, InvalidCapacity, UnsupportedProducer, InvalidMeasurement };
pub const Hash = [32]u8;
pub const Classification = enum { public, sensitive, local_only };
pub fn fieldClassification(comptime T: type, comptime field: []const u8) Classification {
    if (!@hasField(T, field)) @compileError("unknown schema field");
    // Only types explicitly owned by these wire schemas may use this function.
    if (T == Diagnostic) return if (std.mem.eql(u8, field, "secret")) .sensitive else .local_only;
    if (comptime !publicType(T)) @compileError("type is not in the export allowlist");
    return .public;
}
fn containsType(comptime Root: type, comptime T: type) bool {
    if (Root == T) return true;
    return switch (@typeInfo(Root)) {
        .@"struct" => |v| blk: {
            inline for (v.fields) |f| if (comptime containsType(f.type, T)) break :blk true;
            break :blk false;
        },
        .@"union" => |v| blk: {
            inline for (v.fields) |f| if (comptime containsType(f.type, T)) break :blk true;
            break :blk false;
        },
        .array => |v| containsType(v.child, T),
        .optional => |v| containsType(v.child, T),
        else => false,
    };
}
pub fn publicType(comptime T: type) bool {
    // Negative allowlist queries traverse every additive schema fact. This is
    // compile-time work only; keep the same strict structural membership test.
    @setEvalBranchQuota(10_000);
    return containsType(Header, T) or containsType(Input, T) or containsType(ScheduleEntry, T);
}
/// Not part of any canonical record. Exporters explicitly omit this type.
pub const Diagnostic = struct { path: []const u8 = "", username: []const u8 = "", machine: []const u8 = "", serial: []const u8 = "", secret: []const u8 = "" };
/// Decoded metadata extending the TASK-001 envelope header. The envelope remains
/// music.ReplayInputV2 / music.ScheduleTraceV2; this is not another envelope.
pub const Header = struct {
    schema_version: u16 = version,
    compiler_version: u32,
    algorithm_version: u32,
    bank_content_hash: Hash,
    profile: u64,
    seed: u64,
    initial_state_hash: Hash,
    sample_rate: u32,
    quantum_frames: u32,
    bank_major: u16,
    bank_minor: u16,
    bank_build_id: u64,
    generation: u64,
    capacity_profile_hash: Hash,
    rules_version: u16 = integer_rules_version,
    field_classification_version: u16 = classification_version,
    complete: bool = true,
    pub fn base(self: Header) music.RecordingHeaderV2 {
        return .{ .schema_version = self.schema_version, .compiler_version = self.compiler_version, .algorithm_version = self.algorithm_version, .bank_content_hash = self.bank_content_hash, .profile = @enumFromInt(self.profile), .seed = self.seed, .initial_state_hash = self.initial_state_hash, .sample_rate = self.sample_rate, .quantum_frames = self.quantum_frames };
    }
    pub fn validate(self: Header) Error!void {
        if (self.schema_version != version or self.rules_version != integer_rules_version or self.field_classification_version != classification_version) return error.UnknownVersion;
        if (self.compiler_version == 0 or self.algorithm_version == 0 or self.profile == 0 or self.sample_rate == 0 or self.quantum_frames == 0 or self.bank_major == 0 or self.bank_build_id == 0 or self.generation == 0) return error.InvalidHeader;
        if (isZero(self.bank_content_hash) or isZero(self.capacity_profile_hash) or isZero(self.initial_state_hash)) return error.InvalidHeader;
        if (!self.complete) return error.IncompleteTrace;
    }
    pub fn matchesBase(self: Header, other: music.RecordingHeaderV2) bool {
        return std.meta.eql(self.base(), other);
    }
    pub fn requireCompatible(self: Header, expected: Header) Error!void {
        try self.validate();
        try expected.validate();
        if (!std.meta.eql(self, expected)) return error.InvalidHeader;
    }
};
pub fn isZero(hash: Hash) bool {
    return std.mem.allEqual(u8, &hash, 0);
}
/// Signed Q16.16, nearest ties-to-even. Integers and IDs never pass here.
pub fn scalar(value: f64) Error!i32 {
    if (!std.math.isFinite(value)) return error.InvalidScalar;
    const scaled = value * 65536.0;
    if (scaled < -2147483648.0 or scaled > 2147483647.0) return error.InvalidScalar;
    const floor = @floor(scaled);
    const fraction = scaled - floor;
    var n: i64 = @intFromFloat(floor);
    if (fraction > 0.5 or (fraction == 0.5 and @mod(n, 2) != 0)) n += 1;
    return @intCast(n);
}
pub const Position = struct { accepted_control_frame: u64, control_tick: u64, input_order: u64 };
pub fn before(a: Position, b: Position) bool {
    return a.control_tick < b.control_tick or (a.control_tick == b.control_tick and a.input_order < b.input_order);
}
pub const RequestTag = enum(u16) { set_state = 1, set_parameter = 2, context_boolean = 3, context_integer = 4, context_scalar = 5, context_id = 6, trigger_stinger = 7, begin_duck = 8, end_duck = 9, seek_cue = 10, seek_frame = 11, pause = 12, @"resume" = 13, stop_boundary = 14, stop_emergency = 15 };
pub const RequestPayload = union(RequestTag) {
    set_state: struct { state: u64, priority: u8 },
    set_parameter: struct { parameter: u64, value_q16: i32 },
    context_boolean: struct { key: u64, value: bool },
    context_integer: struct { key: u64, value: i64 },
    context_scalar: struct { key: u64, value_q16: i32 },
    context_id: struct { key: u64, value: u64 },
    trigger_stinger: u64,
    begin_duck: struct { request: u64, preset: u64 },
    end_duck: u64,
    seek_cue: struct { segment: u64, cue: u64 },
    seek_frame: struct { segment: u64, frame: u64 },
    pause: void,
    @"resume": void,
    stop_boundary: void,
    stop_emergency: void,
};
pub const Request = struct { request_id: u64, producer: u64, producer_order: u64, context: u64, payload: RequestPayload };
pub fn normalizeRequest(request: music.MusicRequest, context: music.MusicContextKind, producer: u64, producer_order: u64, runtime_context: u64) !Request {
    try request.validate(context);
    if (producer == 0 or runtime_context == 0) return error.InvalidEvent;
    const p: RequestPayload = switch (request.payload) {
        .set_state => |v| .{ .set_state = .{ .state = v.state.value(), .priority = v.priority } },
        .set_parameter => |v| .{ .set_parameter = .{ .parameter = v.parameter.value(), .value_q16 = try scalar(v.value) } },
        .set_context => |v| switch (v.value) {
            .boolean => |x| .{ .context_boolean = .{ .key = v.key.value(), .value = x } },
            .integer => |x| .{ .context_integer = .{ .key = v.key.value(), .value = x } },
            .scalar => |x| .{ .context_scalar = .{ .key = v.key.value(), .value_q16 = try scalar(x) } },
            .id => |x| .{ .context_id = .{ .key = v.key.value(), .value = x.value() } },
        },
        .trigger_stinger => |v| .{ .trigger_stinger = v.value() },
        .begin_duck => |v| .{ .begin_duck = .{ .request = v.id.value(), .preset = v.preset.value() } },
        .end_duck => |v| .{ .end_duck = v.value() },
        .seek_preview => |v| if (v.cue) |cue| .{ .seek_cue = .{ .segment = v.segment.value(), .cue = cue.value() } } else .{ .seek_frame = .{ .segment = v.segment.value(), .frame = v.frame.? } },
        .pause => .pause,
        .@"resume" => .@"resume",
        .stop => |v| if (v == .next_boundary) .stop_boundary else .stop_emergency,
    };
    return .{ .request_id = request.request_id, .producer = producer, .producer_order = producer_order, .context = runtime_context, .payload = p };
}
pub const WorkerOperation = enum(u8) { prefetch = 1, decode = 2, seek = 3 };
pub const Readiness = enum(u8) { not_ready = 1, ready = 2, failed = 3, cancelled = 4 };
pub const Worker = struct {
    job: u64,
    asset: u64,
    generation: u64,
    transport_epoch: u64,
    operation: WorkerOperation,
    state: Readiness,
    pcm_start: u64,
    pcm_end: u64,
    available_frames: u64,
    channel_count: u16,
    content_hash: Hash,
    readiness_version: u64,
    failure_code: u16,
    group: u64,
    layer: u64,
    loop_epoch: u64,
    target_cursor: u64,
    realize_frame: u64,
    job_descriptor_hash: Hash,
    /// Source PCM frame coordinates in this asset/loop epoch. Available frames
    /// are a contiguous prefix [pcm_start, pcm_start+available_frames); neither
    /// transport/render coordinates nor interleaved sample counts. A ready seek
    /// must cover target_cursor. Bank bounds/minimum playable set remain actual
    /// consumer checks against the loaded asset/profile before PCM is released.
    pub fn validateWindow(self: Worker) Error!void {
        if (self.pcm_end < self.pcm_start or self.available_frames > self.pcm_end - self.pcm_start) return error.InvalidEvent;
        if (self.state == .ready and self.operation == .seek and (self.target_cursor < self.pcm_start or self.target_cursor - self.pcm_start >= self.available_frames)) return error.InvalidEvent;
    }
};
pub const DeviceKind = enum(u8) { lost = 1, reopen = 2, reopen_failed = 3, flush = 4, observation = 5 };
pub const DeliveryQuality = enum(u8) { unavailable = 0, exact = 1, estimated = 2 };
pub const RecoveryPolicy = enum(u8) { restart_at_bar = 1, resume_phase = 2 };
pub const DeviceResult = enum(u8) { observed = 1, success = 2, failed = 3 };
pub const Device = struct { kind: DeviceKind, device_epoch: u64, next_device_epoch: u64, render_frontier: u64, submitted_frontier: u64, delivered: u64, delivery_quality: DeliveryQuality, delivery_error: u64, flush_start: u64, flush_end: u64, hardware_tail_known: bool, hardware_tail_start: u64, hardware_tail_end: u64, recovery: RecoveryPolicy, result: DeviceResult };
pub const BatchKind = enum(u8) { commands = 1, invalidations = 2, stream_visibility = 3 };
pub const AdmissionDisposition = enum(u8) { admitted = 1, late = 2, rejected = 3 };
pub const Admission = struct { batch_id: u64, content_hash: Hash, kind: BatchKind, gate: u64, frame: u64, commit_horizon: u64, gate_order: u32, disposition: AdmissionDisposition };
pub const PressureKind = enum(u8) { command = 1, receipt = 2, completion = 3, worker = 4, voice = 5, resident = 6, stream = 7 };
pub const Budget = struct { kind: PressureKind, capacity: u32, available: u32, reservation_id: u64, required: u32, admitted: bool };
pub const Acoustic = struct { context: u64, parameter: u64, value_q16: i32, source_version: u64 };
/// Additive public-runtime profile. Existing v2 records retain their exact
/// wire codes/bytes. Old readers reject tag 12; this profile rejects old files
/// without its explicit begin/end chronology. These are host operations, never
/// scheduler outcomes or synthetic worker readiness.
/// Profile 3 remains DIRECT-state only. Profile 4 explicitly opts into bounded
/// chunked fill-state recording, paired with stream_fill_v1 snapshot semantics.
/// Both reuse state-host tag 13 and snapshot wire version 1 without new fields.
pub const RuntimeProfile = enum(u16) { resident_serial_v1 = 1, stream_serial_v1 = 2, stream_direct_state_serial_v1 = 3, stream_fill_state_serial_v1 = 4, stream_context_serial_v1 = 7, _ };
pub const RuntimeStepKind = enum(u8) { begin = 1, control_tick = 2, render = 3, end = 4, _ };
pub const RuntimeStep = struct {
    version: u16 = 1,
    profile: RuntimeProfile = .resident_serial_v1,
    kind: RuntimeStepKind,
    context: u64,
    frame_count: u32 = 0,
    control_limit: u32 = 0,
    render_call_sequence: u64,
    render_gate: u64,
    next_command_sequence: u64,
    next_request_id: u64,
    pub fn validate(self: RuntimeStep) Error!void {
        if (self.version != 1 or (self.profile != .resident_serial_v1 and self.profile != .stream_serial_v1 and self.profile != .stream_direct_state_serial_v1 and self.profile != .stream_fill_state_serial_v1 and self.profile != .stream_context_serial_v1)) return error.UnknownVersion;
        if (self.context == 0 or self.render_call_sequence & 1 != 0 or self.next_request_id == 0) return error.InvalidEvent;
        switch (self.kind) {
            .begin, .end => if (self.frame_count != 0 or self.control_limit != 0) return error.InvalidEvent,
            .control_tick => if (self.frame_count != 0) return error.InvalidEvent,
            .render => if (self.frame_count == 0 or self.control_limit != 0) return error.InvalidEvent,
            _ => return error.UnknownVersion,
        }
    }
};
/// Serialized state API calls are ingress; their paired results are oracles.
/// Request submission, tick admission, and fence completion are distinct facts.
/// Poll/ack calls remain mandatory even when a tick already collected the fence.
pub const StateHostKind = enum(u8) { capture_begin = 1, capture_poll = 2, capture_ack = 3, restore_submit = 4, restore_poll = 5, restore_ack = 6 };
pub const StateHostOperation = struct {
    version: u16 = 1,
    operation_serial: u64,
    kind: StateHostKind,
    context: u64,
    bank: lifecycle.BankIdentity,
    bank_index: u32,
    bank_incarnation: u32,
    /// Zero for begin/submit; real incarnation or request ID for poll/ack.
    ticket: u64 = 0,
    snapshot: ?lifecycle.SnapshotResource = null,
    render_call_sequence: u64,
    pub fn validate(self: StateHostOperation) Error!void {
        if (self.version != 1) return error.UnknownVersion;
        try self.bank.validate();
        if (self.operation_serial == 0 or self.context == 0 or self.bank_incarnation == 0 or self.render_call_sequence & 1 != 0) return error.InvalidEvent;
        const begin = self.kind == .capture_begin or self.kind == .restore_submit;
        if (begin != (self.ticket == 0) or (self.kind == .restore_submit) != (self.snapshot != null)) return error.InvalidEvent;
        if (self.snapshot) |value| try value.validate();
    }
};
pub const StateHostStatus = enum(u8) { submitted = 1, pending = 2, ready = 3, installed = 4, acknowledged = 5, failed = 6 };
pub const StateInstalledReceipt = struct {
    context: u64,
    asset_generation: u64,
    transport_epoch: u64,
    plan_id: u64,
    plan_epoch: u64,
    phase_id: u64,
    effective_frame: u64,
};
pub const StateHostResult = struct {
    version: u16 = 1,
    operation_serial: u64,
    ticket: u64,
    status: StateHostStatus,
    /// FailureV1 wire code plus one; zero means no failure.
    failure_code: u8 = 0,
    snapshot: ?lifecycle.SnapshotResource = null,
    installed: ?StateInstalledReceipt = null,
    pub fn validate(self: StateHostResult) Error!void {
        if (self.version != 1) return error.UnknownVersion;
        if (self.operation_serial == 0 or self.ticket == 0 or (self.status == .failed) != (self.failure_code != 0) or self.failure_code > 19 or
            (self.status == .ready) != (self.snapshot != null) or (self.status == .installed) != (self.installed != null)) return error.InvalidEvent;
        if (self.snapshot) |value| try value.validate();
        if (self.installed) |value| if (value.context == 0 or value.asset_generation == 0 or value.transport_epoch == 0 or value.plan_id == 0 or value.plan_epoch == 0 or value.phase_id == 0) return error.InvalidEvent;
    }
};
pub const StateHostRecordTag = enum(u8) { call = 1, result = 2 };
pub const StateHostRecord = union(StateHostRecordTag) {
    call: StateHostOperation,
    result: StateHostResult,
    pub fn validate(self: StateHostRecord) Error!void {
        switch (self) {
            inline else => |value| try value.validate(),
        }
    }
};
pub const InputTag = enum(u16) { request = 1, worker = 2, device = 3, admission = 4, budget = 5, acoustic = 6, lifecycle = 7, generation_intent = 8, generation_preparation = 9, readiness_snapshot = 10, acoustic_observation = 11, runtime_step = 12, state_host_operation = 13, context_host_operation = 14 };
pub const InputPayload = union(InputTag) { request: Request, worker: Worker, device: Device, admission: Admission, budget: Budget, acoustic: Acoustic, lifecycle: lifecycle.Lifecycle, generation_intent: lifecycle.GenerationIntent, generation_preparation: lifecycle.GenerationPreparation, readiness_snapshot: readiness.Observation, acoustic_observation: acoustic_observation.Observation, runtime_step: RuntimeStep, state_host_operation: StateHostRecord, context_host_operation: context_host.Record };
pub const Input = struct {
    position: Position,
    payload: InputPayload,
    pub fn validate(self: Input) Error!void {
        switch (self.payload) {
            .request => |r| {
                if (r.request_id == 0 or r.context == 0 or r.producer == 0) return error.InvalidEvent;
                switch (r.payload) {
                    .set_state => |v| if (v.state == 0) return error.InvalidEvent,
                    .set_parameter => |v| if (v.parameter == 0) return error.InvalidEvent,
                    .context_boolean => |v| if (v.key == 0) return error.InvalidEvent,
                    .context_integer => |v| if (v.key == 0) return error.InvalidEvent,
                    .context_scalar => |v| if (v.key == 0) return error.InvalidEvent,
                    .context_id => |v| if (v.key == 0 or v.value == 0) return error.InvalidEvent,
                    .trigger_stinger, .end_duck => |v| if (v == 0) return error.InvalidEvent,
                    .begin_duck => |v| if (v.request == 0 or v.preset == 0) return error.InvalidEvent,
                    .seek_cue => |v| if (v.segment == 0 or v.cue == 0) return error.InvalidEvent,
                    .seek_frame => |v| if (v.segment == 0) return error.InvalidEvent,
                    else => {},
                }
            },
            .worker => |w| {
                try w.validateWindow();
                if (isZero(w.job_descriptor_hash) or (w.group == 0) != (w.layer == 0) or (w.operation == .seek and w.group == 0)) return error.InvalidEvent;
                if (w.channel_count == 0 or w.job == 0 or w.asset == 0 or w.generation == 0 or w.transport_epoch == 0 or w.readiness_version == 0 or w.pcm_end < w.pcm_start or w.available_frames > w.pcm_end - w.pcm_start) return error.InvalidEvent;
                if (w.state == .ready and (isZero(w.content_hash) or w.available_frames == 0)) return error.MissingReadiness;
                if (w.state != .ready and w.available_frames != 0) return error.InvalidEvent;
                if ((w.state == .failed) != (w.failure_code != 0)) return error.InvalidEvent;
            },
            .device => |d| {
                if (d.device_epoch == 0 or d.flush_end < d.flush_start or d.flush_end > d.render_frontier or d.hardware_tail_end < d.hardware_tail_start) return error.InvalidEvent;
                if (d.delivery_quality == .unavailable and (d.delivered != 0 or d.delivery_error != 0)) return error.InvalidEvent;
                if (d.delivery_quality == .exact and (d.delivery_error != 0 or d.delivered > d.submitted_frontier)) return error.InvalidEvent;
                if (d.delivery_quality == .estimated and (d.delivery_error == 0 or (d.delivered > d.submitted_frontier and d.delivered - d.submitted_frontier > d.delivery_error))) return error.InvalidEvent;
                if (!d.hardware_tail_known and (d.hardware_tail_start != 0 or d.hardware_tail_end != 0)) return error.InvalidEvent;
                if ((d.kind == .reopen or d.kind == .flush) and (d.next_device_epoch == 0 or d.next_device_epoch == d.device_epoch)) return error.InvalidEvent;
            },
            .admission => |a| {
                if (a.batch_id == 0 or isZero(a.content_hash) or a.commit_horizon < a.frame) return error.MissingAdmission;
            },
            .budget => |b| {
                if (b.capacity == 0 or b.available > b.capacity or b.reservation_id == 0) return error.InvalidEvent;
            },
            .acoustic => |a| {
                if (a.context == 0 or a.parameter == 0 or a.source_version == 0) return error.InvalidEvent;
            },
            .lifecycle => |v| {
                try v.validate();
                if (v.payload == .restore_state and v.payload.restore_state.reanchor_frontier != self.position.accepted_control_frame) return error.InvalidEvent;
            },
            .generation_intent => |v| try v.validate(),
            .generation_preparation => |v| try v.validate(),
            .readiness_snapshot => |v| try v.validate(),
            .acoustic_observation => |v| v.validateAt(self.position.accepted_control_frame) catch return error.InvalidEvent,
            .runtime_step => |v| try v.validate(),
            .state_host_operation => |v| try v.validate(),
            .context_host_operation => |v| v.validate() catch |err| return switch (err) {
                error.UnknownVersion => error.UnknownVersion,
                else => error.InvalidEvent,
            },
        }
    }
};
pub const ScheduleKind = enum(u16) { enqueue_observation = 1, request_accepted = 2, rule_candidate = 3, selector_choice = 4, plan_prepared = 5, planned = 6, published = 7, acquired = 8, executed = 9, cancel_requested = 10, cancel_effective = 11, cancel_too_late = 12, prefetch = 13, group = 14, layer = 15, duck = 16, sidechain = 17, reload = 18, rejected = 19, partially_executed = 20, complete = 21, superseded_after_partial = 22 };
pub const Result = enum(u16) { none = 0, success = 1, rejected = 2, deferred = 3, cancelled = 4, too_late = 5, degraded = 6 };
pub const Reason = enum(u16) { none = 0, invalid_state = 1, invalid_handle = 2, invalid_bank_version = 3, unsupported_capability = 4, invalid_music_graph = 5, invalid_tempo = 6, misaligned_stems = 7, transition_not_found = 8, target_not_resident = 9, voice_budget_exceeded = 10, command_queue_full = 11, stale_asset_generation = 12, stream_underrun = 13, unsupported_operation = 14, stale_epoch = 15, late = 16, condition_false = 17, lower_priority = 18, incomplete = 19, minimum_hold = 20, cooldown = 21, hysteresis = 22, selector_exhausted = 23, history_excluded = 24, zero_weight = 25, unsupported_request = 26, cue_mismatch = 27, incompatible_handoff = 28, insufficient_lead = 29, readiness_unknown = 30, score_lost = 31, planner_capacity = 32, rule_fallback = 33 };
/// Optional IDs use zero. Mandatory context/generation/epochs are never zero.
/// Fixed event fields cover partial plans individually; no cancelled boolean.
pub const ExecutionState = enum(u8) { none = 0, prepared = 1, published = 2, acquired = 3, partially_executed = 4, complete = 5, cancelled = 6, superseded_after_partial = 7 };
pub const CancelScope = enum(u8) { none = 0, all_unexecuted = 1, remaining_only = 2 };
/// Exact architecture 5.3 vocabulary; null on a record means not applicable.
pub const TransitionSync = enum(u8) { immediate = 1, next_beat = 2, next_bar = 3, next_matching_cue = 4, segment_end = 5, authored_exit_cue = 6 };
pub const ScheduleRecord = struct {
    kind: ScheduleKind,
    context: u64,
    request_id: u64 = 0,
    command_id: u64 = 0,
    control_tick: u64 = 0,
    input_order: u64 = 0,
    accepted_control_frame: u64 = 0,
    planned_frame: u64 = 0,
    executed_frame: u64 = 0,
    observed_render_frame: u64 = 0,
    effective_frame: u64 = 0,
    cancel_requested_frame: u64 = 0,
    cancelled_suffix_start: u32 = 0,
    cancelled_suffix_count: u32 = 0,
    state_before: ExecutionState = .none,
    cancellation_scope: CancelScope = .none,
    executed_prefix_count: u32 = 0,
    sequence: u64 = 0,
    plan_id: u64 = 0,
    phase_id: u64 = 0,
    phase_order: u32 = 0,
    plan_epoch: u64 = 0,
    transport_epoch: u64,
    asset_generation: u64,
    commit_horizon: u64 = 0,
    from_state: u64 = 0,
    to_state: u64 = 0,
    source_segment: u64 = 0,
    fill_segment: u64 = 0,
    target_segment: u64 = 0,
    cue: u64 = 0,
    selector_epoch: u64 = 0,
    group: u64 = 0,
    layer: u64 = 0,
    bus: u64 = 0,
    cursor: u64 = 0,
    ramp_start: u64 = 0,
    ramp_end: u64 = 0,
    value_q16: i32 = 0,
    auxiliary_q16: i32 = 0,
    result: Result = .none,
    reason: Reason = .none,
    rule_id: u64 = 0,
    selector_id: u64 = 0,
    sync: ?TransitionSync = null,
    candidate_priority: u8 = 0,
    candidate_specificity: u32 = 0,
    authored_order: u32 = 0,
    pub fn validate(self: ScheduleRecord) Error!void {
        if (self.context == 0 or self.transport_epoch == 0 or self.asset_generation == 0 or self.ramp_end < self.ramp_start) return error.InvalidEvent;
        if ((self.plan_id == 0) != (self.plan_epoch == 0) or (self.phase_id != 0 and self.plan_id == 0)) return error.InvalidEvent;
        if ((self.kind == .executed or self.kind == .cancel_effective or self.kind == .cancel_too_late) and self.phase_id == 0) return error.InvalidEvent;
        if (self.kind == .executed and self.command_id == 0) return error.InvalidEvent;
        if ((self.kind == .cancel_effective or self.kind == .superseded_after_partial) and self.cancelled_suffix_count == 0) return error.InvalidEvent;
        if (self.kind == .cancel_effective and self.effective_frame < self.cancel_requested_frame) return error.InvalidEvent;
        if (self.cancellation_scope == .remaining_only and (self.executed_prefix_count == 0 or self.cancelled_suffix_start < self.executed_prefix_count)) return error.InvalidEvent;
        if (self.kind == .superseded_after_partial and (self.plan_id == 0 or self.executed_prefix_count == 0 or self.cancellation_scope != .remaining_only)) return error.InvalidEvent;
    }
};

/// Receipt projection preserves real per-phase terminal facts and cancellation
/// state. Caller adds decision metadata from its actual planner, never invents it.
pub fn phaseRecord(receipt: music.PhaseReceipt, command_id: u64, planned_frame: u64, sequence: u64, phase_order: u32) !ScheduleRecord {
    try receipt.token.validate();
    const t = receipt.token;
    if (receipt.outcome == .executed and command_id == 0) return error.InvalidEvent;
    return .{ .kind = if (receipt.outcome == .executed) .executed else .cancel_effective, .context = t.context.value(), .command_id = command_id, .planned_frame = planned_frame, .cancelled_suffix_start = phase_order, .cancelled_suffix_count = if (receipt.outcome == .cancelled) 1 else 0, .plan_id = t.plan_id.value(), .phase_id = t.phase_id.value(), .plan_epoch = t.plan_epoch.value(), .transport_epoch = t.transport_epoch.value(), .asset_generation = t.asset_generation.value(), .sequence = sequence, .phase_order = phase_order, .executed_frame = if (receipt.outcome == .executed) receipt.effective_frame else 0, .effective_frame = receipt.effective_frame, .result = if (receipt.outcome == .executed) .success else .cancelled };
}
pub const CancellationFacts = struct { requested_frame: u64, executed_prefix_count: u32, cancelled_suffix_start: u32, cancelled_suffix_count: u32 };
pub fn cancellationRecord(receipt: music.CancellationReceipt, sequence: u64, phase_order: u32, facts: CancellationFacts) !ScheduleRecord {
    try receipt.validate();
    const t = receipt.token;
    var record: ScheduleRecord = .{ .kind = .cancel_effective, .context = t.context.value(), .plan_id = t.plan_id.value(), .phase_id = t.phase_id.value(), .plan_epoch = t.plan_epoch.value(), .transport_epoch = t.transport_epoch.value(), .asset_generation = t.asset_generation.value(), .sequence = sequence, .phase_order = phase_order, .executed_prefix_count = facts.executed_prefix_count, .cancel_requested_frame = facts.requested_frame, .cancelled_suffix_start = facts.cancelled_suffix_start, .cancelled_suffix_count = facts.cancelled_suffix_count, .state_before = switch (receipt.state_before) {
        .prepared => .prepared,
        .published => .published,
        .acquired => .acquired,
        .partially_executed => .partially_executed,
        .complete => .complete,
        .cancelled => .cancelled,
        .superseded_after_partial => .superseded_after_partial,
    } };
    switch (receipt.disposition) {
        .effective => |v| {
            record.effective_frame = v.effective_frame;
            record.result = .cancelled;
            record.cancellation_scope = if (v.remaining_only) .remaining_only else .all_unexecuted;
        },
        .too_late => |v| {
            record.kind = .cancel_too_late;
            record.executed_frame = v.executed_frame;
            record.result = .too_late;
        },
    }
    try record.validate();
    return record;
}

/// Additive candidate record. Existing event/transaction encodings are unchanged.
pub const PlannerScore = struct {
    sync_penalty: u64,
    readiness_penalty: u64,
    authored_rank: u64,
    audible_frame: u64,
    source_cue_id: u64,
    fill_route_id: u64,
    target_cue_id: u64,
    target_segment_id: u64,
};
pub const PlannerRecord = struct {
    context: u64,
    request_id: u64,
    sequence: u64 = 0,
    control_tick: u64 = 0,
    input_order: u64 = 0,
    accepted_control_frame: u64 = 0,
    transport_epoch: u64,
    asset_generation: u64,
    rule_id: u64,
    path_id: u64 = 0,
    source_segment: u64 = 0,
    readiness_snapshot_version: u64 = 0,
    sync: ?TransitionSync = null,
    score: ?PlannerScore = null,
    result: Result = .none,
    reason: Reason = .none,
    score_loser_column: u8 = 0,
    pub fn validate(self: PlannerRecord) Error!void {
        if (self.context == 0 or self.request_id == 0 or self.transport_epoch == 0 or self.asset_generation == 0 or self.rule_id == 0) return error.InvalidEvent;
        if (self.score_loser_column > 8) return error.InvalidEvent;
        if (self.score) |score| {
            if (score.source_cue_id == 0 or score.target_cue_id == 0 or score.target_segment_id == 0 or score.readiness_penalty > 1) return error.InvalidEvent;
        }
        if (self.reason == .score_lost) {
            if (self.result != .rejected or self.score == null or self.score_loser_column == 0) return error.InvalidEvent;
        } else if (self.score_loser_column != 0) return error.InvalidEvent;
        if (self.result == .success and (self.score == null or self.path_id == 0 or self.reason != .none)) return error.InvalidEvent;
        if (self.result == .cancelled or self.result == .too_late or self.result == .degraded) return error.InvalidEvent;
    }
};
/// Numeric-only policy outcome. Group is the monotonic handle generation.
pub const VoiceState = enum(u8) { real = 0, virtual = 1, releasing = 2, stolen = 3 };
pub const VoiceProtection = enum(u8) { optional = 0, stinger = 1, dialogue = 2, base = 3 };
pub const VoiceReason = enum(u16) { none = 0, below_threshold = 1, real_capacity = 2, virtual_capacity = 3, required_minimum = 4, stinger_capacity = 5, group_capacity = 6, resident_budget = 7, stream_budget = 8, held = 9, late_prepare = 10, stale_ticket = 11, unrealizable = 12 };
pub const VoiceBudgetRecord = struct {
    context: u64,
    transport_epoch: u64,
    asset_generation: u64,
    frame: u64,
    profile: u64,
    profile_hash: Hash,
    group: u64,
    layer: u64,
    from_state: VoiceState,
    to_state: VoiceState,
    protection: VoiceProtection,
    authored_priority: u16,
    audibility_q24: u32,
    drop_rank: u16,
    reason: VoiceReason,
    required: u64,
    available: u64,
    sequence: u64 = 0,
    control_tick: u64 = 0,
    input_order: u64 = 0,
    accepted_control_frame: u64 = 0,
    pub fn validate(self: VoiceBudgetRecord) Error!void {
        if (self.context == 0 or self.transport_epoch == 0 or self.asset_generation == 0 or self.profile == 0 or isZero(self.profile_hash) or self.audibility_q24 > 64 * (1 << 24)) return error.InvalidEvent;
        if ((self.group == 0) != (self.layer == 0)) return error.InvalidEvent;
        if (self.group == 0) switch (self.reason) {
            .real_capacity, .virtual_capacity, .stinger_capacity, .group_capacity, .resident_budget, .stream_budget => if (self.required <= self.available) return error.InvalidEvent,
            .required_minimum => {},
            else => return error.InvalidEvent,
        };
    }
};

/// Actual atomic executor outcome; numeric-only values preserve exact f32 bits.
/// Planner tag 3 and voice-budget tag 4 retain their established encoding.
pub const BusOperation = enum(u8) { install = 0, retire = 1, target = 2, duck_begin = 3, duck_end = 4, layer_route = 5 };
pub const BusTarget = enum(u8) { none = 0, bus_gain = 1, bus_mute = 2, channel_gain = 3, send_gain = 4, effect_gain = 5, lowpass_hz = 6, effect_bypass = 7, compressor_threshold_dbfs = 8, compressor_ratio = 9, compressor_knee_db = 10, compressor_attack_frames = 11, compressor_hold_frames = 12, compressor_release_frames = 13, compressor_makeup_db = 14, prepared_route = 15 };
pub const BusEvent = struct {
    context: u64,
    transport_epoch: u64,
    asset_generation: u64,
    command_id: u64,
    plan_id: u64 = 0,
    plan_epoch: u64 = 0,
    phase_id: u64 = 0,
    phase_order: u32 = 0,
    sequence: u64,
    planned_frame: u64,
    executed_frame: u64,
    graph_generation: u64,
    graph_hash: Hash,
    artifact_generation: u64 = 0,
    artifact_hash: Hash = @splat(0),
    operation_index: u16 = 0,
    operation_count: u16 = 1,
    operation: BusOperation,
    target: BusTarget = .none,
    object: u32 = 0,
    auxiliary: u32 = 0,
    group: u64 = 0,
    layer: u16 = 0,
    value_bits: u32 = 0,
    ramp_frames: u32 = 0,
    duck_id: u32 = 0,
    priority: i16 = 0,
    authored_order: u32 = 0,
    attack_frames: u32 = 0,
    hold_frames: u32 = 0,
    release_frames: u32 = 0,
    result: Result,
    reason: Reason = .none,

    pub fn validate(self: BusEvent) Error!void {
        if (self.context == 0 or self.transport_epoch == 0 or self.asset_generation == 0 or self.command_id == 0 or self.sequence == 0 or self.graph_generation == 0 or isZero(self.graph_hash)) return error.InvalidEvent;
        if ((self.plan_id == 0) != (self.plan_epoch == 0) or (self.phase_id != 0 and self.plan_id == 0)) return error.InvalidEvent;
        if (self.operation_count == 0 or self.operation_index >= self.operation_count) return error.InvalidEvent;
        if (!std.math.isFinite(@as(f32, @bitCast(self.value_bits)))) return error.InvalidEvent;
        switch (self.result) {
            .success => if (self.reason != .none) return error.InvalidEvent,
            .rejected => if (self.reason == .none) return error.InvalidEvent,
            else => return error.InvalidEvent,
        }
        switch (self.operation) {
            .install, .retire => {
                if (self.artifact_generation != 0 or !isZero(self.artifact_hash) or self.target != .none or self.object != 0 or self.group != 0 or self.layer != 0 or self.value_bits != 0 or self.operation_index != 0 or self.operation_count != 1) return error.InvalidEvent;
            },
            .target, .duck_begin, .duck_end, .layer_route => {
                if (self.artifact_generation == 0 or isZero(self.artifact_hash)) return error.InvalidEvent;
                switch (self.operation) {
                    // Authored bus/effect/edge IDs include zero. Only a selectable
                    // route group uses zero as the absent-group sentinel.
                    .target => if (self.target == .none or self.group != 0 or self.layer != 0 or (self.target == .channel_gain and self.auxiliary >= 8) or (self.target == .prepared_route and self.object == 0)) return error.InvalidEvent,
                    .duck_begin, .duck_end => if (self.target != .none or self.group != 0 or self.layer != 0) return error.InvalidEvent,
                    .layer_route => if (self.target != .none or self.object != 0 or self.auxiliary != 0 or self.group == 0 or self.layer >= 16 or self.value_bits != 0) return error.InvalidEvent,
                    else => unreachable,
                }
            },
        }
    }
};

/// Prepared gain automation, appended without changing existing wire records.
pub const LayerAutomationOperation = enum(u8) { install, terminal, rejected_install };
pub const LayerAutomationEvent = struct {
    version: u16 = 1,
    operation: LayerAutomationOperation,
    context: u64,
    group: u64,
    stable_layer_id: u64,
    ordinal: u16,
    program_generation: u64,
    content_hash: Hash,
    profile_hash: Hash,
    command_id: u64,
    plan_id: u64,
    plan_epoch: u64,
    phase_id: u64,
    phase_order: u32,
    transport_epoch: u64,
    asset_generation: u64,
    binding_revision: u64,
    planned_frame: u64,
    actual_frame: u64,
    source_start_cursor: u64,
    source_start_loop_epoch: u64,
    elapsed_source_frames: u64,
    source_endpoint: u64,
    duration_domain: u8,
    duration_numerator: u64,
    duration_denominator: u64,
    endpoint_rounding: u8,
    gain_bits: u32,
    final_gain_bits: u32,
    terminal_reason: u8 = 0,
    release_frontier: u64,
    audible: bool,
    pub fn validate(self: LayerAutomationEvent) Error!void {
        if (self.version != 1 or self.context == 0 or self.group == 0 or self.stable_layer_id == 0 or self.ordinal >= 16 or self.program_generation == 0 or isZero(self.content_hash) or isZero(self.profile_hash) or self.command_id == 0 or self.plan_id == 0 or self.plan_epoch == 0 or self.phase_id == 0 or self.transport_epoch == 0 or self.asset_generation == 0 or self.binding_revision == 0 or self.duration_domain > 1 or self.duration_denominator == 0 or self.endpoint_rounding > 2 or self.terminal_reason > 11 or self.elapsed_source_frames > self.source_endpoint or self.release_frontier < self.actual_frame) return error.InvalidEvent;
        // A rejected installation can expose a legacy out-of-range/NaN raw
        // value. Its gain_bits are diagnostic bits, never an admitted gain.
        const target: f32 = @bitCast(self.final_gain_bits);
        if (!std.math.isFinite(target) or target < 0 or target > 4) return error.InvalidEvent;
        if (self.operation != .rejected_install) {
            const value: f32 = @bitCast(self.gain_bits);
            if (!std.math.isFinite(value) or value < 0 or value > 4) return error.InvalidEvent;
        }
        if (self.operation == .install and (self.actual_frame != self.planned_frame or self.elapsed_source_frames != 0)) return error.InvalidEvent;
        if (self.operation == .terminal and self.terminal_reason == 0 and (self.elapsed_source_frames != self.source_endpoint or self.gain_bits != self.final_gain_bits or self.release_frontier <= self.actual_frame)) return error.InvalidEvent;
    }
};

pub const ScheduleEntryTag = enum(u16) { event = 1, transaction = 2, planner_candidate = 3, voice_budget = 4, bus = 5, layer_automation = 6, resident_fence = 7 };
pub const TransactionRecord = lifecycle.TransactionRecord;
pub const ScheduleEntry = union(ScheduleEntryTag) {
    event: ScheduleRecord,
    transaction: TransactionRecord,
    planner_candidate: PlannerRecord,
    voice_budget: VoiceBudgetRecord,
    bus: BusEvent,
    layer_automation: LayerAutomationEvent,
    resident_fence: lifecycle.ResidentFenceV1,
    pub fn validate(self: ScheduleEntry) Error!void {
        switch (self) {
            inline else => |v| try v.validate(),
        }
    }
};
