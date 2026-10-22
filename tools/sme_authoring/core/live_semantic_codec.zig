//! Profile 9 finite Host payload schema. Native padding never enters a file.
//! The exact build identity binds enum codes and this field-order schema. Only
//! the non-RT consumer encodes; execution decoders reject error-valued inputs.
const std = @import("std");
const audio = @import("bugu_audio");
pub const semantic = @import("live_semantic.zig");
pub const format = audio.music.LiveSemanticFormat;
pub const cuts = audio.runtime.live_semantic;
pub const stream = audio.runtime.streaming.stream;
pub const source = @import("sme-author-preview-v1").source;
pub const payload_overlap = @import("live_semantic_payload_overlap.zig");
pub const Error = format.Error || payload_overlap.Error || error{ UnsupportedValue, BorrowedValue, InvalidEnum, InvalidBoolean, ErrorInput, CrossedScan };
pub const schema_version: u16 = 2;
pub const Family = enum(u16) {
    cut = 1,
    boundary = 2,
    raw_clock = 3,
    control_call = 4,
    command_dequeued = 5,
    close_observed = 6,
    worker_call = 7,
    callback = 8,
    event_cut = 9,
    close_polled = 10,
    point_packet_input = 11,
    ui_call = 12,
    mailbox_cut = 13,
    launch_descriptor = 14,
    exclusion_claim = 15,
    worker_gate_cut = 16,
    worker_gate_packet_input = 17,
    cut_fact = 101,
    boundary_fact = 102,
    control_event = 103,
    worker_event = 104,
    worker_fact = 105,
    source_event = 106,
    source_fact = 107,
    public_input = 108,
    schedule = 109,
    acceptance = 110,
    tick = 111,
    frontier = 112,
    audio_event = 113,
    pcm = 114,
    point_packet_reference = 115,
    ui_event = 116,
    mailbox_event = 117,
    worker_gate_event = 118,
    worker_gate_packet_reference = 119,
};
pub fn validate(family: u16, class: format.Class) bool {
    const f = std.enums.fromInt(Family, family) orelse return false;
    const expected: format.Class = switch (f) {
        .cut, .boundary, .raw_clock, .control_call, .worker_call, .callback, .event_cut, .point_packet_input, .ui_call, .mailbox_cut, .launch_descriptor, .exclusion_claim, .worker_gate_cut, .worker_gate_packet_input => .input,
        else => .reference,
    };
    return class == expected;
}
pub fn wireRole(role: cuts.Role) format.Role {
    return switch (role) {
        .control => .control,
        .render => .render,
        .worker => .worker,
    };
}
pub fn nativeRole(role: format.Role) Error!cuts.Role {
    return switch (role) {
        .control => .control,
        .worker => .worker,
        .render => .render,
        .ui => error.UnsupportedValue,
    };
}
/// Finite event occurrence marker: no observed result, readiness, or plan.
pub const EventCut = struct { family: Family, tag: u16 };
pub fn eventTag(value: anytype) u16 {
    return switch (@typeInfo(@TypeOf(value))) {
        .@"union" => @intCast(@intFromEnum(std.meta.activeTag(value))),
        else => 0,
    };
}
/// Explicit INPUT publication coordinate, independently compared to the native
/// point value. Control acquires a PCM-consumed, Service sequence, Runtime frame
/// or commit-horizon prefix; Render publishes the corresponding global scalar.
/// Replay orders actual operations only:
/// it never assigns a recorded prefix to an engine counter. Zero is a real
/// acquired prefix, not an absent value. Only supported AFTER points carry it.
pub const Cut = struct { role: format.Role, site: cuts.Site, edge: cuts.Edge, index: u64, generation: u64, publication_prefix: u64 = 0 };
/// All six acquire sites read one Service-wide observation_sequence counter,
/// regardless of the point's stream slot / generation coordinates.
pub fn serviceSequenceRead(site: cuts.Site) bool {
    return switch (site) {
        .service_availability_readiness_sequence_before,
        .service_availability_readiness_sequence_after,
        .service_availability_acceptance_sequence_before,
        .service_availability_acceptance_sequence_after,
        .service_readiness_sequence,
        .service_readiness_final_sequence,
        => true,
        else => false,
    };
}
pub fn serviceSequencePublication(site: cuts.Site) bool {
    return site == .service_render_sequence_odd or site == .service_render_sequence_even;
}
/// Closed scalar identities of one Host. Index/generation remain native point
/// coordinates, never separate frame or commit-horizon counters.
pub const RuntimePublicationDomain = enum { frame, commit_horizon };
pub fn runtimePublicationRead(site: cuts.Site) ?RuntimePublicationDomain {
    return switch (site) {
        .runtime_collection_frame,
        .runtime_control_accept_frame,
        .runtime_control_collect_frame,
        .runtime_readiness_outer_before,
        .runtime_readiness_outer_after,
        => .frame,
        .runtime_control_horizon, .scheduler_prepare_horizon => .commit_horizon,
        else => null,
    };
}
pub fn runtimePublicationStore(site: cuts.Site) ?RuntimePublicationDomain {
    return switch (site) {
        .runtime_render_frame => .frame,
        .runtime_render_commit_horizon, .scheduler_horizon => .commit_horizon,
        else => null,
    };
}
/// Both sites acquire the same per-stream raw consumed atomic, never the
/// completed-DSP control_consumed projection. Generation remains part of key.
pub fn rawConsumedRead(site: cuts.Site) bool {
    return site == .ring_consumed or site == .service_initial_entry_consumed;
}
pub fn publicationPrefixPoint(role: format.Role, site: cuts.Site, edge: cuts.Edge) bool {
    if (edge != .after) return false;
    return (role == .control and (rawConsumedRead(site) or serviceSequenceRead(site) or runtimePublicationRead(site) != null)) or
        (role == .render and (serviceSequencePublication(site) or runtimePublicationStore(site) != null));
}
pub fn validatePublicationPrefix(role: format.Role, site: cuts.Site, edge: cuts.Edge, prefix: u64) Error!void {
    if (((rawConsumedRead(site) or serviceSequenceRead(site) or runtimePublicationRead(site) != null) and role != .control) or
        ((serviceSequencePublication(site) or runtimePublicationStore(site) != null) and role != .render)) return error.UnsupportedValue;
    if (!publicationPrefixPoint(role, site, edge) and prefix != 0) return error.Noncanonical;
}
/// The finite Service worker_busy exclusion has one Control claimant and two
/// Worker claimants. These are not generic CAS result inputs or owner tokens.
pub fn exclusionClaim(role: format.Role, site: cuts.Site) bool {
    return switch (site) {
        .service_stream_close_claim => role == .control,
        .service_worker_claim, .service_service_prepare_claim => role == .worker,
        else => false,
    };
}
pub fn exclusionRelease(role: format.Role, site: cuts.Site) bool {
    return switch (site) {
        .service_stream_close_idle => role == .control,
        .service_worker_idle, .service_service_prepare_idle => role == .worker,
        else => false,
    };
}
pub fn exclusionRole(site: cuts.Site) ?format.Role {
    return switch (site) {
        .service_stream_close_claim, .service_stream_close_idle => .control,
        .service_worker_claim, .service_worker_idle, .service_service_prepare_claim, .service_service_prepare_idle => .worker,
        else => null,
    };
}
fn validateExclusionRole(role: format.Role, site: cuts.Site) Error!void {
    if (exclusionRole(site)) |expected| if (role != expected) return error.UnsupportedValue;
}
/// Validate the independently observed native scalar; never construct it from
/// an exclusion_claim scheduling input. Known releases publish false on both
/// edges. Claim BEFORE has no result, AFTER has actual busy=false/true only.
pub fn validateExclusionPoint(value: cuts.Point) Error!void {
    const role = wireRole(value.role);
    try validateExclusionRole(role, value.site);
    if (exclusionClaim(role, value.site)) {
        if (value.edge == .before) {
            if (value.value != null) return error.Noncanonical;
        } else if (value.value == null or value.value.? > 1) return error.Noncanonical;
    } else if (exclusionRelease(role, value.site) and value.value != @as(?u64, 0)) return error.Noncanonical;
}
pub const Boundary = struct { role: format.Role, site: cuts.Boundary, edge: cuts.Edge, index: u64, generation: u64 };
pub const RawClock = @FieldType(stream.WorkerFact, "clock");
/// provider_release's Counts are computed output, not original call arguments.
pub const ControlArguments = union(enum) {
    provider_create: @FieldType(semantic.ControlCall, "provider_create"),
    owner_create: @FieldType(semantic.ControlCall, "owner_create"),
    bind_output,
    bind_live,
    startup_quiescence,
    bind_audio,
    release_quiescence,
    load: @FieldType(semantic.ControlCall, "load"),
    poll_load: @FieldType(semantic.ControlCall, "poll_load"),
    acknowledge_load: @FieldType(semantic.ControlCall, "acknowledge_load"),
    device_open: @FieldType(semantic.ControlCall, "device_open"),
    device_start,
    play: @FieldType(semantic.ControlCall, "play"),
    stop: @FieldType(semantic.ControlCall, "stop"),
    tick: @FieldType(semantic.ControlCall, "tick"),
    receipt,
    snapshot,
    drain_status,
    shutdown,
    device_stop,
    cleanup_render: @FieldType(semantic.ControlCall, "cleanup_render"),
    destroy_unbound: u64,
    provider_release,
    final_quiescence,
    detach_audio,
    stop_progress,
};
pub fn controlArguments(value: semantic.ControlCall) ControlArguments {
    return switch (value) {
        .provider_release => .provider_release,
        inline else => |v, tag| @unionInit(ControlArguments, @tagName(tag), v),
    };
}
pub const ControlInvocation = struct { call_id: u64, call: ControlArguments };
/// Original UI arguments only. UiResult is never an execution input.
pub const UiInvocation = @FieldType(semantic.UiEvent, "enter");
/// Original finite launch arguments, excluding the allocator-issued Host epoch
/// and diagnostic OS thread identity. Runtime config is authenticated separately.
pub const LaunchDescriptor = struct {
    document_id: u64,
    revision: u64,
    draft_hash: [32]u8,
    state: audio.music.MusicStateId,
    device: audio.device.DeviceConfig,
    pacing: semantic.PacingMode = .legacy_poll,
};
pub fn launchDescriptor(value: @FieldType(semantic.ControlEvent, "started")) LaunchDescriptor {
    return .{ .document_id = value.identity.document_id, .revision = value.identity.revision, .draft_hash = value.identity.draft_hash, .state = value.identity.state, .device = value.device, .pacing = value.pacing };
}
fn validateDeviceConfig(value: audio.device.DeviceConfig) Error!void {
    if (value.sample_rate != 48000 or value.channels != 2 or value.period_frames != 256 or value.output_layout_request != null) return error.UnsupportedValue;
    switch (value.backend) {
        .system, .null_backend => {},
    }
}
pub fn validateLaunchDescriptor(value: LaunchDescriptor) Error!void {
    try validateDeviceConfig(value.device);
}
/// Input-only capability: no comparison cursor or returned Host value is read.
/// The caller still performs complete validateInputs before any owner effects.
pub fn readLaunchDescriptor(reader: *const format.Reader) Error!LaunchDescriptor {
    var result: ?LaunchDescriptor = null;
    inline for (.{ format.Role.control, format.Role.worker, format.Role.render, format.Role.ui }) |role| {
        var cursor = InputCursor.init(reader, role);
        while (try cursor.next()) |record| {
            if (record.family != @intFromEnum(Family.launch_descriptor)) continue;
            if (role != .control or result != null) return error.InvalidOrder;
            result = (try decodeInput(LaunchDescriptor, record, .launch_descriptor)).value;
        }
    }
    return result orelse error.Incomplete;
}

/// Only the sticky Close predicate is a scheduling coordinate. The admission
/// word and the request_close RMW return remain comparison-only observations.
pub const MailboxCut = union(enum) {
    ring: mailbox.RingCheckpoint,
    admission: struct { role: mailbox.Role, operation: mailbox.AdmissionOperation, edge: mailbox.Edge, closed: ?bool },
};
pub fn mailboxCut(value: mailbox.Checkpoint) MailboxCut {
    return switch (value) {
        .ring => |ring| .{ .ring = ring },
        .admission => |admission| .{ .admission = .{
            .role = admission.role,
            .operation = admission.operation,
            .edge = admission.edge,
            .closed = if (admission.edge == .before) null else if (admission.value) |word| word & 2 != 0 else null,
        } },
    };
}
pub fn mailboxRole(role: mailbox.Role) format.Role {
    return switch (role) {
        .ui => .ui,
        .control => .control,
    };
}
fn mailboxCutRole(value: MailboxCut) mailbox.Role {
    return switch (value) {
        inline else => |v| v.role,
    };
}
fn mailboxCutEdge(value: MailboxCut) mailbox.Edge {
    return switch (value) {
        inline else => |v| v.edge,
    };
}
pub fn validateMailboxCut(value: MailboxCut) Error!void {
    switch (value) {
        .ring => |ring| {
            const producer: mailbox.Role = if (ring.queue == .commands) .ui else .control;
            const consumer: mailbox.Role = if (ring.queue == .commands) .control else .ui;
            if (ring.role != (if (ring.operation == .push) producer else consumer)) return error.InvalidOrder;
            const counter: mailbox.Counter = switch (ring.operation) {
                .push => if (ring.access == .acquire) .read else .written,
                .pop => if (ring.access == .acquire) .written else .read,
                .empty => if (ring.access == .acquire) .written else return error.Noncanonical,
            };
            if (ring.counter != counter) return error.Noncanonical;
            if (ring.access == .release) {
                if (ring.prefix != @as(?usize, ring.local_prefix +% 1)) return error.Noncanonical;
            } else if (ring.edge == .before) {
                if (ring.prefix != null) return error.Noncanonical;
            } else {
                const prefix = ring.prefix orelse return error.Incomplete;
                const distance = if (ring.operation == .push) ring.local_prefix -% prefix else prefix -% ring.local_prefix;
                const capacity: usize = if (ring.queue == .commands) mailbox.command_capacity else mailbox.event_capacity;
                if (distance > capacity) return error.InvalidOrder;
            }
        },
        .admission => |admission| {
            if (admission.operation != .request_close and admission.role != .control) return error.InvalidOrder;
            if (admission.edge == .before) {
                if (admission.closed != null) return error.Noncanonical;
            } else {
                const closed = admission.closed orelse return error.Incomplete;
                if (admission.operation == .request_close and !closed) return error.Noncanonical;
            }
        },
    }
}
pub fn validateMailboxCheckpoint(value: mailbox.Checkpoint) Error!void {
    try validateMailboxCut(mailboxCut(value));
    switch (value) {
        .ring => {},
        .admission => |admission| {
            // The admitted calendar has one UI Close publisher and cannot order
            // a Control-origin Close or a drain read observing UI publication
            // custody. Inspect exact reference fields before owner creation;
            // the normalized closed predicate cannot distinguish 0/1 or 2/3.
            if (admission.operation == .request_close and admission.role == .control) return error.UnsupportedValue;
            if (admission.edge == .before) {
                if (admission.value != null or admission.prior != null) return error.Noncanonical;
            } else {
                const word = admission.value orelse return error.Incomplete;
                if (word > 3) return error.Noncanonical;
                if (admission.operation == .admission_drained and word & 1 != 0) return error.UnsupportedValue;
                if (admission.operation == .request_close) {
                    const prior = admission.prior orelse return error.Incomplete;
                    if (prior > 3 or word != (prior | 2)) return error.Noncanonical;
                } else {
                    if (admission.prior != null) return error.Noncanonical;
                    if (admission.operation == .close_requested and word != 0 and word != 2) return error.Noncanonical;
                }
            }
        },
    }
}
/// Same-actor atomic brackets only. Cross-actor mailbox calendars and real
/// acquire/release replay waits are validated by the independent scheduler.
const MailboxPairs = struct {
    active: [2]?MailboxCut = @splat(null),
    fn other(self: *const MailboxPairs, role: format.Role) Error!void {
        const index: usize = switch (role) {
            .ui => @intFromEnum(mailbox.Role.ui),
            .control => @intFromEnum(mailbox.Role.control),
            else => return,
        };
        if (self.active[index] != null) return error.Incomplete;
    }
    fn observe(self: *MailboxPairs, value: MailboxCut) Error!void {
        try validateMailboxCut(value);
        const entry = &self.active[@intFromEnum(mailboxCutRole(value))];
        if (mailboxCutEdge(value) == .before) {
            if (entry.* != null) return error.InvalidOrder;
            entry.* = value;
            return;
        }
        const before = entry.* orelse return error.InvalidOrder;
        var paired = value;
        switch (paired) {
            .ring => |*ring| {
                ring.edge = .before;
                if (ring.access == .acquire) ring.prefix = null;
            },
            .admission => |*admission| {
                admission.edge = .before;
                admission.closed = null;
            },
        }
        if (!std.meta.eql(before, paired)) return error.InvalidOrder;
        entry.* = null;
    }
    fn finish(self: *const MailboxPairs) Error!void {
        for (self.active) |entry| if (entry != null) return error.Incomplete;
    }
};

/// Scheduling coordinates for the five WorkerGate counters only. This INPUT
/// has its own encoding and is never populated by reading a comparison cursor.
pub const WorkerGateCut = struct {
    role: mailbox.GateRole,
    counter: @FieldType(mailbox.WorkerGateCheckpoint, "counter"),
    access: @FieldType(mailbox.WorkerGateCheckpoint, "access"),
    edge: @FieldType(mailbox.WorkerGateCheckpoint, "edge"),
    epoch: u64,
    prefix: ?u64,
};
pub fn workerGateCut(value: mailbox.WorkerGateCheckpoint) WorkerGateCut {
    return .{ .role = value.role, .counter = value.counter, .access = value.access, .edge = value.edge, .epoch = value.epoch, .prefix = value.prefix };
}
pub fn workerGateRole(role: mailbox.GateRole) format.Role {
    return switch (role) {
        .control => .control,
        .worker => .worker,
    };
}
pub fn validateWorkerGateCut(value: WorkerGateCut) Error!void {
    if (value.epoch == 0) return error.Noncanonical;
    const publisher: mailbox.GateRole = switch (value.counter) {
        .request, .resumed, .stopped => .control,
        .acknowledgment, .progress => .worker,
    };
    const reader: mailbox.GateRole = if (publisher == .control) .worker else .control;
    if (value.role != (if (value.access == .release) publisher else reader)) return error.InvalidOrder;
    if (value.access == .acquire and value.edge == .before) {
        if (value.prefix != null) return error.Noncanonical;
    } else {
        const prefix = value.prefix orelse return error.Incomplete;
        if (value.counter == .stopped and prefix > 1) return error.Noncanonical;
        if (value.access == .release and prefix == 0) return error.Noncanonical;
    }
}
pub fn validateWorkerGateCheckpoint(value: mailbox.WorkerGateCheckpoint) Error!void {
    try validateWorkerGateCut(workerGateCut(value));
}
/// Pair only the source's adjacent same-actor atomic edges. The lifetime epoch
/// is established solely by the first INPUT cut, never Control.started or any
/// reference. Cross-actor prefix reachability belongs to the input scheduler.
const WorkerGatePairs = struct {
    epoch: ?u64 = null,
    active: [2]?WorkerGateCut = @splat(null),
    fn actor(role: format.Role) ?usize {
        return switch (role) {
            .control => 0,
            .worker => 1,
            else => null,
        };
    }
    fn other(self: *const WorkerGatePairs, role: format.Role) Error!void {
        const index = actor(role) orelse return;
        if (self.active[index] != null) return error.Incomplete;
    }
    fn observe(self: *WorkerGatePairs, value: WorkerGateCut) Error!void {
        try validateWorkerGateCut(value);
        if (self.epoch) |epoch| {
            if (value.epoch != epoch) return error.InvalidOrder;
        } else self.epoch = value.epoch;
        const entry = &self.active[actor(workerGateRole(value.role)).?];
        if (value.edge == .before) {
            if (entry.* != null) return error.InvalidOrder;
            entry.* = value;
            return;
        }
        const before = entry.* orelse return error.InvalidOrder;
        var paired = value;
        paired.edge = .before;
        if (paired.access == .acquire) paired.prefix = null;
        if (!std.meta.eql(before, paired)) return error.InvalidOrder;
        entry.* = null;
    }
    fn finish(self: *const WorkerGatePairs) Error!void {
        for (self.active) |entry| if (entry != null) return error.Incomplete;
    }
};

pub const Callback = struct { frame_count: u32, channels: u16, output_present: bool };
pub const Acceptance = struct { attempt: stream.LiveAcceptanceAttemptV1, effective_frame: u64 };
/// Queue-only transport for acceptance. The public Acceptance and canonical
/// wire schema stay unchanged. Only the five fields already excluded by
/// acceptanceDiagnostic are absent; no selected result or native error is lost.
const CompactAcceptanceEvidence = struct {
    position: @FieldType(stream.observation.Acceptance, "position"),
    batch_id: @FieldType(stream.observation.Acceptance, "batch_id"),
    runtime_attached: @FieldType(stream.observation.Acceptance, "runtime_attached"),
    replay_mode: @FieldType(stream.observation.Acceptance, "replay_mode"),
    selected: @FieldType(stream.observation.Acceptance, "selected"),
    availability: @FieldType(stream.observation.Acceptance, "availability"),
    ring_capacity: @FieldType(stream.observation.Acceptance, "ring_capacity"),
    publication_preflight: @FieldType(stream.observation.Acceptance, "publication_preflight"),
    publication_commit: @FieldType(stream.observation.Acceptance, "publication_commit"),
    last_batch_id: @FieldType(stream.observation.Acceptance, "last_batch_id"),
    next_snapshot: @FieldType(stream.observation.Acceptance, "next_snapshot"),
    cancel: @FieldType(stream.observation.Acceptance, "cancel"),
    stopped: @FieldType(stream.observation.Acceptance, "stopped"),
    generation: @FieldType(stream.observation.Acceptance, "generation"),
    transport_epoch: @FieldType(stream.observation.Acceptance, "transport_epoch"),
    stale: @FieldType(stream.observation.Acceptance, "stale"),
    actual_worker: @FieldType(stream.observation.Acceptance, "actual_worker"),
    coordinate: @FieldType(stream.observation.Acceptance, "coordinate"),
    ring_produced: @FieldType(stream.observation.Acceptance, "ring_produced"),
    ring_writable: @FieldType(stream.observation.Acceptance, "ring_writable"),
    ring_publish: @FieldType(stream.observation.Acceptance, "ring_publish"),
    publication: @FieldType(stream.observation.Acceptance, "publication"),
    outcome: @FieldType(stream.observation.Acceptance, "outcome"),
    error_code: @FieldType(stream.observation.Acceptance, "error_code"),
    effects: @FieldType(stream.observation.Acceptance, "effects"),
    accepted: @FieldType(stream.observation.Acceptance, "accepted"),
};
pub const CompactAcceptance = struct {
    attempt: struct {
        incoming: @FieldType(stream.LiveAcceptanceAttemptV1, "incoming"),
        cut: @FieldType(stream.LiveAcceptanceAttemptV1, "cut"),
        deferred: @FieldType(stream.LiveAcceptanceAttemptV1, "deferred"),
        evidence: CompactAcceptanceEvidence,
        returned_error: @FieldType(stream.LiveAcceptanceAttemptV1, "returned_error"),
    },
    effective_frame: u64,
};
pub fn packAcceptance(value: Acceptance) Error!CompactAcceptance {
    if (!value.attempt.evidence.representation_complete) return error.Incomplete;
    var result: CompactAcceptance = undefined;
    result.effective_frame = value.effective_frame;
    inline for (@typeInfo(stream.LiveAcceptanceAttemptV1).@"struct".fields) |field| {
        if (comptime !std.mem.eql(u8, field.name, "evidence")) @field(result.attempt, field.name) = @field(value.attempt, field.name);
    }
    // Field-based copies fail compilation if the canonical source schema gains
    // a semantic field not represented by this explicit finite transport.
    inline for (@typeInfo(stream.observation.Acceptance).@"struct".fields) |field| {
        if (comptime !acceptanceDiagnostic(field.name)) @field(result.attempt.evidence, field.name) = @field(value.attempt.evidence, field.name);
    }
    inline for (@typeInfo(CompactAcceptanceEvidence).@"struct".fields) |field| {
        if (comptime acceptanceDiagnostic(field.name)) @compileError("diagnostic field entered compact acceptance transport");
    }
    return result;
}
pub fn unpackAcceptance(value: CompactAcceptance) Acceptance {
    var result: Acceptance = .{ .attempt = .{ .incoming = value.attempt.incoming, .evidence = .{} }, .effective_frame = value.effective_frame };
    inline for (@typeInfo(stream.LiveAcceptanceAttemptV1).@"struct".fields) |field| {
        if (comptime !std.mem.eql(u8, field.name, "evidence")) @field(result.attempt, field.name) = @field(value.attempt, field.name);
    }
    inline for (@typeInfo(stream.observation.Acceptance).@"struct".fields) |field| {
        if (comptime !acceptanceDiagnostic(field.name)) @field(result.attempt.evidence, field.name) = @field(value.attempt.evidence, field.name);
    }
    return result;
}
pub const Frontier = struct { phase: audio.ControlRuntime.TickPhaseV1, acquired_frame: u64, effective_frame: u64 };
pub const Pcm = struct { disposition: audio.device.SemanticAudioPcmDisposition, device_epoch: u64, first_frame: ?u64, channels: u16, samples: u32 };
pub fn Native(comptime T: type) type {
    return struct { occurrence: u64, value: T };
}

/// Reject borrowed nonempty data before it can enter the native queue. Empty
/// const slices are canonical empty values; no address is ever encoded.
pub fn owned(value: anytype) bool {
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .pointer => |p| if (p.size == .slice and p.is_const) value.len == 0 else false,
        .@"struct" => |s| blk: {
            inline for (s.fields) |f| if (!owned(@field(value, f.name))) break :blk false;
            break :blk true;
        },
        .@"union" => switch (value) {
            inline else => |v| owned(v),
        },
        .optional => if (value) |v| owned(v) else true,
        .array => blk: {
            for (value) |v| if (!owned(v)) break :blk false;
            break :blk true;
        },
        .error_union => if (value) |v| owned(v) else |_| true,
        .int, .float, .bool, .@"enum", .error_set, .void => true,
        else => false,
    };
}
fn Integer(comptime T: type) type {
    const i = @typeInfo(T).int;
    if (i.bits > 64) @compileError("unsupported wide Host integer");
    // usize/isize are fixed at 64 wire bits even on a 32-bit native host.
    const bits = if (T == usize or T == isize) 64 else ((i.bits + 7) / 8) * 8;
    return std.meta.Int(i.signedness, @max(bits, 8));
}
fn acceptanceDiagnostic(comptime name: []const u8) bool {
    return std.mem.eql(u8, name, "job_slots") or std.mem.eql(u8, name, "scanned") or
        std.mem.eql(u8, name, "representation_complete") or std.mem.eql(u8, name, "states") or
        std.mem.eql(u8, name, "completed");
}
pub const Encoder = struct {
    wire: format.Encoder,
    class: format.Class,
    pub fn put(self: *Encoder, value: anytype) Error!void {
        const T = @TypeOf(value);
        if (T == cuts.Role) return self.put(wireRole(value));
        if (T == stream.observation.Acceptance) {
            // Internal scan telemetry is not an observable decision. Preserve
            // the actual selected/accepted descriptor, cut and effects only.
            inline for (@typeInfo(T).@"struct".fields) |f| {
                if (comptime !acceptanceDiagnostic(f.name)) try self.put(@field(value, f.name));
            }
            return;
        }
        switch (@typeInfo(T)) {
            .int => try self.wire.int(Integer(T), value),
            .float => |f| try self.wire.int(std.meta.Int(.unsigned, f.bits), @bitCast(value)),
            .bool => try self.wire.int(u8, @intFromBool(value)),
            .@"enum" => try self.wire.int(u64, @intCast(@intFromEnum(value))),
            .array => for (value) |v| try self.put(v),
            .@"struct" => |s| inline for (s.fields) |f| try self.put(@field(value, f.name)),
            .optional => {
                try self.put(value != null);
                if (value) |v| try self.put(v);
            },
            .@"union" => {
                try self.put(std.meta.activeTag(value));
                switch (value) {
                    inline else => |v| try self.put(v),
                }
            },
            .error_set => {
                if (self.class != .reference) return error.ErrorInput;
                const name = @errorName(value);
                if (name.len > std.math.maxInt(u16)) return error.UnsupportedValue;
                try self.wire.int(u16, @intCast(name.len));
                try self.wire.raw(name);
            },
            .error_union => {
                if (value) |v| {
                    try self.put(false);
                    try self.put(v);
                } else |err| {
                    try self.put(true);
                    try self.put(err);
                }
            },
            .pointer => |p| {
                if (p.size != .slice or !p.is_const) return error.BorrowedValue;
                if (value.len != 0) return error.BorrowedValue;
                try self.wire.int(u32, 0);
            },
            .void => {},
            else => return error.UnsupportedValue,
        }
    }
    pub fn result(self: Encoder) []const u8 {
        return self.wire.result();
    }
};
pub const Decoder = struct {
    wire: format.Decoder,
    pub fn get(self: *Decoder, comptime T: type) Error!T {
        if (T == cuts.Role) return nativeRole(try self.get(format.Role));
        return switch (@typeInfo(T)) {
            .int => std.math.cast(T, try self.wire.int(Integer(T))) orelse error.Noncanonical,
            .float => |f| @bitCast(try self.wire.int(std.meta.Int(.unsigned, f.bits))),
            .bool => switch (try self.wire.int(u8)) {
                0 => false,
                1 => true,
                else => error.InvalidBoolean,
            },
            .@"enum" => |e| blk: {
                const raw = try self.wire.int(u64);
                const bounded = std.math.cast(e.tag_type, raw) orelse return error.InvalidEnum;
                // Stable IDs/counters intentionally admit unnamed integer
                // values. Closed protocol vocabularies remain exhaustive.
                if (!e.is_exhaustive) break :blk @enumFromInt(bounded);
                inline for (e.fields) |f| if (raw == f.value) break :blk @enumFromInt(bounded);
                return error.InvalidEnum;
            },
            .array => |a| blk: {
                var v: T = undefined;
                for (&v) |*x| x.* = try self.get(a.child);
                break :blk v;
            },
            .@"struct" => |s| blk: {
                var v: T = undefined;
                inline for (s.fields) |f| @field(v, f.name) = try self.get(f.type);
                break :blk v;
            },
            .optional => |o| if (try self.get(bool)) try self.get(o.child) else null,
            .@"union" => |u| blk: {
                const tag = try self.get(u.tag_type.?);
                inline for (u.fields) |f| if (tag == @field(u.tag_type.?, f.name)) break :blk @unionInit(T, f.name, try self.get(f.type));
                return error.InvalidEnum;
            },
            .pointer => |p| blk: {
                if (p.size != .slice or !p.is_const) return error.BorrowedValue;
                if (try self.wire.int(u32) != 0) return error.BorrowedValue;
                break :blk &.{};
            },
            .error_set, .error_union => error.ErrorInput,
            .void => {},
            else => error.UnsupportedValue,
        };
    }
};
pub fn encode(value: anytype, class: format.Class, bytes: []u8) Error![]const u8 {
    var e: Encoder = .{ .wire = .{ .bytes = bytes }, .class = class };
    try e.put(value);
    return e.result();
}
pub fn decode(comptime T: type, bytes: []const u8) Error!T {
    var d: Decoder = .{ .wire = .{ .bytes = bytes } };
    const value = try d.get(T);
    try d.wire.finish();
    return value;
}
pub fn configHash(value: audio.music.MusicRuntimeConfigV1) Error!format.Hash {
    var bytes: [4096]u8 = undefined;
    return format.hash(try encode(value, .input, &bytes));
}
pub fn native(comptime T: type, bytes: []const u8) Error!Native(T) {
    if (bytes.len != @sizeOf(Native(T))) return error.InvalidLength;
    var value: Native(T) = undefined;
    @memcpy(std.mem.asBytes(&value), bytes);
    if (value.occurrence == 0) return error.InvalidOrder;
    if (T == Cut) {
        try validatePublicationPrefix(value.value.role, value.value.site, value.value.edge, value.value.publication_prefix);
        try validateExclusionRole(value.value.role, value.value.site);
    }
    if (T == MailboxCut) try validateMailboxCut(value.value);
    if (T == WorkerGateCut) try validateWorkerGateCut(value.value);
    if (T == mailbox.WorkerGateCheckpoint) try validateWorkerGateCheckpoint(value.value);
    if (T == LaunchDescriptor) try validateLaunchDescriptor(value.value);
    return value;
}
pub fn canonicalNative(comptime T: type, value: Native(T)) Native(T) {
    var result = value;
    // OS thread IDs are validation diagnostics, not portable outputs.
    if (T == semantic.ControlEvent) switch (result.value) {
        .started => |*v| v.thread = 1,
        else => {},
    };
    if (T == semantic.WorkerEvent) switch (result.value) {
        .started => |*v| v.* = 2,
        else => {},
    };
    return result;
}
fn encodeTyped(comptime T: type, r: format.NativeRecord, bytes: []u8) Error![]const u8 {
    if (r.second().len != 0) return error.InvalidLength;
    var value = canonicalNative(T, try native(T, r.first()));
    if (T == cuts.Point) value.value = try comparisonPoint(value.value);
    return encode(value, r.class, bytes);
}
/// Native bytes are copied back into their exact schema type, then every field
/// is serialized. PCM suffixes contain owned native f32 bits, not a slice.
pub fn encodeNative(r: format.NativeRecord, bytes: []u8) Error![]const u8 {
    if (!validate(r.family, r.class)) return error.UnsupportedFamily;
    const family: Family = @enumFromInt(r.family);
    return switch (family) {
        .point_packet_input => encodeNativePacket(PacketInput, r, bytes),
        .point_packet_reference => encodeNativePacket(PacketReference, r, bytes),
        .worker_gate_packet_input => encodeNativeWorkerGatePacket(WorkerGateCut, r, bytes),
        .worker_gate_packet_reference => encodeNativeWorkerGatePacket(mailbox.WorkerGateCheckpoint, r, bytes),
        .event_cut => encodeTyped(EventCut, r, bytes),
        .close_polled => encodeTyped(bool, r, bytes),
        .cut => encodeTyped(Cut, r, bytes),
        .exclusion_claim => encodeTyped(bool, r, bytes),
        .boundary => encodeTyped(Boundary, r, bytes),
        .raw_clock => encodeTyped(RawClock, r, bytes),
        .control_call => encodeTyped(ControlInvocation, r, bytes),
        .ui_call => encodeTyped(UiInvocation, r, bytes),
        .ui_event => encodeTyped(semantic.UiEvent, r, bytes),
        .mailbox_cut => encodeTyped(MailboxCut, r, bytes),
        .launch_descriptor => encodeTyped(LaunchDescriptor, r, bytes),
        .mailbox_event => encodeTyped(mailbox.Checkpoint, r, bytes),
        .worker_gate_cut => encodeTyped(WorkerGateCut, r, bytes),
        .worker_gate_event => encodeTyped(mailbox.WorkerGateCheckpoint, r, bytes),
        .command_dequeued => encodeTyped(?semantic.Command, r, bytes),
        .close_observed => encodeTyped(void, r, bytes),
        .worker_call => encodeTyped(u64, r, bytes),
        .callback => encodeTyped(Callback, r, bytes),
        .cut_fact => encodeTyped(cuts.Point, r, bytes),
        .boundary_fact => encodeTyped(cuts.BoundaryPoint, r, bytes),
        .control_event => encodeTyped(semantic.ControlEvent, r, bytes),
        .worker_event => encodeTyped(semantic.WorkerEvent, r, bytes),
        .worker_fact => encodeTyped(stream.WorkerFact, r, bytes),
        .source_event => encodeTyped(source.SemanticEvent, r, bytes),
        .source_fact => encodeTyped(stream.SourceFact, r, bytes),
        .public_input => encodeTyped(audio.music.trace.Input, r, bytes),
        .schedule => encodeTyped(audio.music.trace.ScheduleEntry, r, bytes),
        .acceptance => blk: {
            if (r.role != .control) return error.UnsupportedValue;
            if (r.second().len != 0) return error.InvalidLength;
            const compact = try native(CompactAcceptance, r.first());
            const full: Native(Acceptance) = .{ .occurrence = compact.occurrence, .value = unpackAcceptance(compact.value) };
            break :blk try encode(full, r.class, bytes);
        },
        .tick => encodeTyped(audio.ControlRuntime.LiveTickEventV1, r, bytes),
        .frontier => encodeTyped(Frontier, r, bytes),
        .audio_event => encodeTyped(audio.device.SemanticAudioEvent, r, bytes),
        .pcm => blk: {
            const header = try native(Pcm, r.first());
            if (r.second().len != @as(usize, header.value.samples) * @sizeOf(f32)) return error.InvalidLength;
            var e: Encoder = .{ .wire = .{ .bytes = bytes }, .class = .reference };
            try e.put(header);
            var offset: usize = 0;
            while (offset < r.second().len) : (offset += 4) {
                var bits: u32 = undefined;
                @memcpy(std.mem.asBytes(&bits), r.second()[offset..][0..4]);
                try e.wire.f32Bits(bits);
            }
            break :blk e.result();
        },
    };
}
/// A packet is only bounded storage compression of consecutive real Point
/// callbacks, never a scan result. Inputs contain coordinates and occurrence
/// stamps plus an explicit supported publication scheduling prefix; references
/// independently retain actual comparison values.
pub const max_packet_points: usize = 512;
pub const PacketInput = struct { occurrence: u64, site: cuts.Site, edge: cuts.Edge, index: u64, generation: u64, publication_prefix: u64 = 0 };
pub const PacketReference = struct { input: PacketInput, value: ?u64 };
pub const PacketHeader = struct { count: u16 };
comptime {
    if (@sizeOf(PacketHeader) + max_packet_points * @sizeOf(Native(WorkerGateCut)) > format.max_payload or
        @sizeOf(PacketHeader) + max_packet_points * @sizeOf(Native(mailbox.WorkerGateCheckpoint)) > format.max_payload or
        2 + max_packet_points * (10 + 3 + 10 + 1 + 10) > format.max_payload)
        @compileError("WorkerGate packets exceed the unchanged finite payload bound");
}
// Canonical unsigned LEB128, bounded to ten bytes for every u64. Encoding
// runs only on the non-RT collector; native capture packets are unchanged.
fn putPacketUint(e: *format.Encoder, original: u64) Error!void {
    var value = original;
    while (true) {
        const low: u8 = @intCast(value & 0x7f);
        value >>= 7;
        try e.int(u8, low | (if (value != 0) @as(u8, 0x80) else 0));
        if (value == 0) return;
    }
}
fn getPacketUint(d: *format.Decoder) Error!u64 {
    var value: u64 = 0;
    for (0..10) |i| {
        const byte = try d.int(u8);
        const low = byte & 0x7f;
        if (i == 9 and (byte & 0x80 != 0 or low > 1)) return error.CounterOverflow;
        const shift: u6 = @intCast(i * 7);
        value |= @as(u64, low) << shift;
        if (byte & 0x80 == 0) {
            if (i != 0 and low == 0) return error.Noncanonical;
            return value;
        }
    }
    return error.CounterOverflow;
}
pub fn packetEnvelope(site: cuts.Boundary) bool {
    return switch (site) {
        .service_worker_scan, .service_acceptance_scan, .service_render_consumed_prefix => true,
        else => false,
    };
}
fn packetCoordinate(role: format.Role, value: PacketInput) Error!void {
    if (value.occurrence == 0) return error.InvalidOrder;
    try validatePublicationPrefix(role, value.site, value.edge, value.publication_prefix);
    try validateExclusionRole(role, value.site);
    if (!cuts.allowedPoint(.{ .role = try nativeRole(role), .site = value.site, .edge = value.edge, .index = value.index, .generation = value.generation })) return error.UnsupportedValue;
    switch (value.site) {
        .service_worker_scan => if (role != .worker or value.index >= 256 or value.generation != 0) return error.UnsupportedValue,
        .service_acceptance_scan => if (role != .control or value.index >= 256 or value.generation != 0) return error.UnsupportedValue,
        .service_slot_guard_render_claim => if (role != .render or value.index >= 64 or value.generation != 0) return error.UnsupportedValue,
        .service_slot_guard_render_release, .service_render_consumed => if (role != .render or value.index >= 64) return error.UnsupportedValue,
        else => {},
    }
}
fn putPacketInput(e: *format.Encoder, role: format.Role, value: PacketInput) Error!void {
    try packetCoordinate(role, value);
    try putPacketUint(e, value.occurrence);
    try e.int(u16, @intFromEnum(value.site));
    try e.int(u8, @intFromEnum(value.edge));
    try putPacketUint(e, value.index);
    try putPacketUint(e, value.generation);
    try putPacketUint(e, value.publication_prefix);
}
fn getPacketInput(d: *format.Decoder, role: format.Role) Error!PacketInput {
    const value: PacketInput = .{
        .occurrence = try getPacketUint(d),
        .site = std.enums.fromInt(cuts.Site, try d.int(u16)) orelse return error.InvalidEnum,
        .edge = std.enums.fromInt(cuts.Edge, try d.int(u8)) orelse return error.InvalidEnum,
        .index = try getPacketUint(d),
        .generation = try getPacketUint(d),
        .publication_prefix = try getPacketUint(d),
    };
    try packetCoordinate(role, value);
    return value;
}
fn packetCount(bytes: []const u8) Error!u16 {
    var d: format.Decoder = .{ .bytes = bytes };
    const count = try d.int(u16);
    if (count == 0 or count > max_packet_points) return error.InvalidLength;
    return count;
}
pub fn encodePointInputs(role: format.Role, values: []const PacketInput, bytes: []u8) Error![]const u8 {
    if (values.len == 0 or values.len > max_packet_points) return error.InvalidLength;
    var e: format.Encoder = .{ .bytes = bytes };
    try e.int(u16, @intCast(values.len));
    var last: u64 = 0;
    for (values) |value| {
        if (value.occurrence <= last) return error.InvalidOrder;
        last = value.occurrence;
        try putPacketInput(&e, role, value);
    }
    return e.result();
}
/// Inputs here are genuine native values. Scan comparisons retain only the
/// eligibility predicate used by the real selector, not incidental state labels.
pub fn encodePointReferences(role: format.Role, values: []const PacketReference, bytes: []u8) Error![]const u8 {
    if (values.len == 0 or values.len > max_packet_points) return error.InvalidLength;
    var e: format.Encoder = .{ .bytes = bytes };
    try e.int(u16, @intCast(values.len));
    var last: u64 = 0;
    for (values) |value| {
        if (value.input.occurrence <= last) return error.InvalidOrder;
        last = value.input.occurrence;
        try putPacketInput(&e, role, value.input);
        const point = try comparisonPoint(.{ .role = try nativeRole(role), .site = value.input.site, .edge = value.input.edge, .index = value.input.index, .generation = value.input.generation, .value = value.value });
        try e.int(u8, @intFromBool(point.value != null));
        try putPacketUint(&e, point.value orelse 0);
    }
    return e.result();
}
fn encodeNativePacket(comptime T: type, r: format.NativeRecord, bytes: []u8) Error![]const u8 {
    if (r.first().len != @sizeOf(PacketHeader)) return error.InvalidLength;
    var header: PacketHeader = undefined;
    @memcpy(std.mem.asBytes(&header), r.first());
    if (header.count == 0 or header.count > max_packet_points or r.second().len != @as(usize, header.count) * @sizeOf(T)) return error.InvalidLength;
    // The queue's byte arena has no alignment promise. Copy one exact native
    // element at a time; no large stack array and no padding reaches the wire.
    var e: format.Encoder = .{ .bytes = bytes };
    try e.int(u16, header.count);
    var last: u64 = 0;
    for (0..header.count) |i| {
        var value: T = undefined;
        @memcpy(std.mem.asBytes(&value), r.second()[i * @sizeOf(T) ..][0..@sizeOf(T)]);
        const coordinate: PacketInput = if (T == PacketInput) value else value.input;
        if (coordinate.occurrence <= last) return error.InvalidOrder;
        last = coordinate.occurrence;
        try putPacketInput(&e, r.role, coordinate);
        if (T == PacketReference) {
            const point = try comparisonPoint(.{ .role = try nativeRole(r.role), .site = coordinate.site, .edge = coordinate.edge, .index = coordinate.index, .generation = coordinate.generation, .value = value.value });
            try e.int(u8, @intFromBool(point.value != null));
            try putPacketUint(&e, point.value orelse 0);
        }
    }
    return e.result();
}
/// Gate packets compress transport only. Each owned element keeps its real
/// occurrence and its independently captured input or comparison checkpoint.
fn putWorkerGate(comptime T: type, e: *format.Encoder, role: format.Role, value: Native(T)) Error!void {
    if (value.occurrence == 0) return error.InvalidOrder;
    const cut = if (T == WorkerGateCut) value.value else workerGateCut(value.value);
    try validateWorkerGateCut(cut);
    if (workerGateRole(cut.role) != role) return error.InvalidOrder;
    try putPacketUint(e, value.occurrence);
    try e.int(u8, @intFromEnum(cut.counter));
    try e.int(u8, @intFromEnum(cut.access));
    try e.int(u8, @intFromEnum(cut.edge));
    try putPacketUint(e, cut.epoch);
    try e.int(u8, @intFromBool(cut.prefix != null));
    try putPacketUint(e, cut.prefix orelse 0);
}
fn getWorkerGate(comptime T: type, d: *format.Decoder, role: format.Role) Error!Native(T) {
    const gate_role: mailbox.GateRole = switch (role) {
        .control => .control,
        .worker => .worker,
        else => return error.UnsupportedValue,
    };
    const occurrence = try getPacketUint(d);
    if (occurrence == 0) return error.InvalidOrder;
    const counter = std.enums.fromInt(mailbox.GateCounter, try d.int(u8)) orelse return error.InvalidEnum;
    const access = std.enums.fromInt(mailbox.Access, try d.int(u8)) orelse return error.InvalidEnum;
    const edge = std.enums.fromInt(mailbox.Edge, try d.int(u8)) orelse return error.InvalidEnum;
    const epoch = try getPacketUint(d);
    const present = try d.int(u8);
    if (present > 1) return error.InvalidBoolean;
    const bits = try getPacketUint(d);
    if (present == 0 and bits != 0) return error.Noncanonical;
    const checkpoint: mailbox.WorkerGateCheckpoint = .{ .role = gate_role, .counter = counter, .access = access, .edge = edge, .epoch = epoch, .prefix = if (present == 1) bits else null };
    try validateWorkerGateCheckpoint(checkpoint);
    return .{ .occurrence = occurrence, .value = if (T == WorkerGateCut) workerGateCut(checkpoint) else checkpoint };
}
fn encodeWorkerGates(comptime T: type, role: format.Role, values: []const Native(T), bytes: []u8) Error![]const u8 {
    if (values.len == 0 or values.len > max_packet_points) return error.InvalidLength;
    var e: format.Encoder = .{ .bytes = bytes };
    try e.int(u16, @intCast(values.len));
    var last: u64 = 0;
    for (values) |value| {
        if (value.occurrence <= last) return error.InvalidOrder;
        last = value.occurrence;
        try putWorkerGate(T, &e, role, value);
    }
    return e.result();
}
pub fn encodeWorkerGateInputs(role: format.Role, values: []const Native(WorkerGateCut), bytes: []u8) Error![]const u8 {
    return encodeWorkerGates(WorkerGateCut, role, values, bytes);
}
pub fn encodeWorkerGateReferences(role: format.Role, values: []const Native(mailbox.WorkerGateCheckpoint), bytes: []u8) Error![]const u8 {
    return encodeWorkerGates(mailbox.WorkerGateCheckpoint, role, values, bytes);
}
fn encodeNativeWorkerGatePacket(comptime T: type, r: format.NativeRecord, bytes: []u8) Error![]const u8 {
    if (r.first().len != @sizeOf(PacketHeader)) return error.InvalidLength;
    var header: PacketHeader = undefined;
    @memcpy(std.mem.asBytes(&header), r.first());
    const Elem = Native(T);
    if (header.count == 0 or header.count > max_packet_points or r.second().len != @as(usize, header.count) * @sizeOf(Elem)) return error.InvalidLength;
    var e: format.Encoder = .{ .bytes = bytes };
    try e.int(u16, header.count);
    var last: u64 = 0;
    for (0..header.count) |i| {
        var value: Elem = undefined;
        @memcpy(std.mem.asBytes(&value), r.second()[i * @sizeOf(Elem) ..][0..@sizeOf(Elem)]);
        if (value.occurrence <= last) return error.InvalidOrder;
        last = value.occurrence;
        try putWorkerGate(T, &e, r.role, value);
    }
    return e.result();
}
const PacketKind = enum { point, worker_gate };
fn comparisonPoint(value: cuts.Point) Error!cuts.Point {
    var result = value;
    switch (value.site) {
        .service_worker_scan, .service_acceptance_scan => {
            if (value.edge == .before) {
                if (value.value != null) return error.Noncanonical;
            } else {
                const state = std.enums.fromInt(stream.observation.JobState, value.value orelse return error.Noncanonical) orelse return error.InvalidEnum;
                result.value = @intFromBool(if (value.site == .service_worker_scan) state == .queued else state == .completed);
            }
        },
        else => {},
    }
    return result;
}
/// Value-copyable forward cursor. All stored slices refer to immutable Reader
/// backing, never this cursor's scratch. A returned expanded payload is valid
/// until the next call on this cursor. Virtual ordinals count this class only.
pub const InputCursor = struct {
    raw: format.InputCursor,
    packet: []const u8 = &.{},
    offset: usize = 0,
    remaining: u16 = 0,
    pending: ?PacketInput = null,
    pending_gate: ?Native(WorkerGateCut) = null,
    packet_kind: PacketKind = .point,
    ordinal: u64 = 0,
    scratch: [128]u8 = undefined,
    pub fn init(reader: *const format.Reader, role: format.Role) InputCursor {
        return .{ .raw = reader.execution(role) };
    }
    pub fn next(self: *InputCursor) Error!?format.InputRecord {
        self.ordinal = std.math.add(u64, self.ordinal, 1) catch return error.CounterOverflow;
        if (self.pending) |value| {
            self.pending = null;
            const payload = try encode(@as(Native(Cut), .{ .occurrence = value.occurrence, .value = .{ .role = self.raw.role, .site = value.site, .edge = value.edge, .index = value.index, .generation = value.generation, .publication_prefix = value.publication_prefix } }), .input, &self.scratch);
            return .{ .role = self.raw.role, .ordinal = self.ordinal, .family = @intFromEnum(Family.cut), .bytes = payload };
        }
        if (self.pending_gate) |value| {
            self.pending_gate = null;
            const payload = try encode(value, .input, &self.scratch);
            return .{ .role = self.raw.role, .ordinal = self.ordinal, .family = @intFromEnum(Family.worker_gate_cut), .bytes = payload };
        }
        if (self.remaining == 0) {
            const record = try self.raw.next() orelse {
                self.ordinal -= 1;
                return null;
            };
            // A flushed packet may be followed by its last claim AFTER's
            // exclusion_claim. Pass it through as a distinct INPUT with the
            // same occurrence; it is not a point and invents no event marker.
            self.packet_kind = if (record.family == @intFromEnum(Family.point_packet_input)) .point else if (record.family == @intFromEnum(Family.worker_gate_packet_input)) .worker_gate else return .{ .role = record.role, .ordinal = self.ordinal, .family = record.family, .bytes = record.bytes };
            self.remaining = try packetCount(record.bytes);
            self.packet = record.bytes;
            self.offset = 2;
        }
        var d: format.Decoder = .{ .bytes = self.packet, .offset = self.offset };
        if (self.packet_kind == .worker_gate) {
            const value = try getWorkerGate(WorkerGateCut, &d, self.raw.role);
            self.offset = d.offset;
            self.remaining -= 1;
            if (self.remaining == 0 and self.offset != self.packet.len) return error.InvalidLength;
            self.pending_gate = value;
            const payload = try encode(@as(Native(EventCut), .{ .occurrence = value.occurrence, .value = .{ .family = .worker_gate_event, .tag = 0 } }), .input, &self.scratch);
            return .{ .role = self.raw.role, .ordinal = self.ordinal, .family = @intFromEnum(Family.event_cut), .bytes = payload };
        }
        const value = try getPacketInput(&d, self.raw.role);
        self.offset = d.offset;
        self.remaining -= 1;
        if (self.remaining == 0 and self.offset != self.packet.len) return error.InvalidLength;
        self.pending = value;
        const payload = try encode(@as(Native(EventCut), .{ .occurrence = value.occurrence, .value = .{ .family = .cut_fact, .tag = 0 } }), .input, &self.scratch);
        return .{ .role = self.raw.role, .ordinal = self.ordinal, .family = @intFromEnum(Family.event_cut), .bytes = payload };
    }
    pub fn finish(self: *InputCursor) Error!void {
        if (try self.next() != null) return error.TrailingBytes;
    }
};
pub const ComparisonCursor = struct {
    raw: format.ComparisonCursor,
    packet_kind: PacketKind = .point,
    packet: []const u8 = &.{},
    offset: usize = 0,
    remaining: u16 = 0,
    ordinal: u64 = 0,
    scratch: [128]u8 = undefined,
    pub fn init(reader: *const format.Reader, role: format.Role) ComparisonCursor {
        return .{ .raw = reader.comparison(role) };
    }
    pub fn next(self: *ComparisonCursor) Error!?format.ReferenceRecord {
        self.ordinal = std.math.add(u64, self.ordinal, 1) catch return error.CounterOverflow;
        if (self.remaining == 0) {
            const record = try self.raw.next() orelse {
                self.ordinal -= 1;
                return null;
            };
            self.packet_kind = if (record.family == @intFromEnum(Family.point_packet_reference)) .point else if (record.family == @intFromEnum(Family.worker_gate_packet_reference)) .worker_gate else return .{ .role = record.role, .ordinal = self.ordinal, .family = record.family, .bytes = record.bytes };
            self.remaining = try packetCount(record.bytes);
            self.packet = record.bytes;
            self.offset = 2;
        }
        var d: format.Decoder = .{ .bytes = self.packet, .offset = self.offset };
        if (self.packet_kind == .worker_gate) {
            const value = try getWorkerGate(mailbox.WorkerGateCheckpoint, &d, self.raw.role);
            self.offset = d.offset;
            self.remaining -= 1;
            if (self.remaining == 0 and self.offset != self.packet.len) return error.InvalidLength;
            const payload = try encode(value, .reference, &self.scratch);
            return .{ .role = self.raw.role, .ordinal = self.ordinal, .family = @intFromEnum(Family.worker_gate_event), .bytes = payload };
        }
        const value = try getPacketInput(&d, self.raw.role);
        const present = try d.int(u8);
        if (present > 1) return error.InvalidBoolean;
        const bits = try getPacketUint(&d);
        if (present == 0 and bits != 0) return error.Noncanonical;
        if ((value.site == .service_worker_scan or value.site == .service_acceptance_scan) and
            (if (value.edge == .before) present != 0 else present != 1 or bits > 1)) return error.Noncanonical;
        self.offset = d.offset;
        self.remaining -= 1;
        if (self.remaining == 0 and self.offset != self.packet.len) return error.InvalidLength;
        const payload = try encode(@as(Native(cuts.Point), .{ .occurrence = value.occurrence, .value = .{ .role = try nativeRole(self.raw.role), .site = value.site, .edge = value.edge, .index = value.index, .generation = value.generation, .value = if (present == 1) bits else null } }), .reference, &self.scratch);
        return .{ .role = self.raw.role, .ordinal = self.ordinal, .family = @intFromEnum(Family.cut_fact), .bytes = payload };
    }
    pub fn finish(self: *ComparisonCursor) Error!void {
        if (try self.next() != null) return error.TrailingBytes;
    }
};
pub fn decodeInput(comptime T: type, record: format.InputRecord, family: Family) Error!Native(T) {
    if (record.family != @intFromEnum(family) or !validate(record.family, .input)) return error.UnsupportedFamily;
    const value = try decode(Native(T), record.bytes);
    if (value.occurrence == 0) return error.InvalidOrder;
    if (T == Cut) {
        try validatePublicationPrefix(value.value.role, value.value.site, value.value.edge, value.value.publication_prefix);
        try validateExclusionRole(value.value.role, value.value.site);
    }
    if (T == MailboxCut) try validateMailboxCut(value.value);
    if (T == WorkerGateCut) try validateWorkerGateCut(value.value);
    if (T == LaunchDescriptor) try validateLaunchDescriptor(value.value);
    return value;
}
pub fn decodeUiCall(record: format.InputRecord) Error!Native(UiInvocation) {
    if (record.role != .ui) return error.InvalidOrder;
    return decodeInput(UiInvocation, record, .ui_call);
}
pub fn decodeControlCall(record: format.InputRecord) Error!Native(ControlInvocation) {
    return decodeInput(ControlInvocation, record, .control_call);
}
/// Structural reference validation never constructs an error value and never
/// returns expected decisions to execution. It is solely pre-owner admission.
const ReferenceValidator = struct {
    decoder: Decoder,
    accepted: bool = false,
    fn skip(self: *ReferenceValidator, comptime T: type) Error!void {
        if (T == stream.observation.Acceptance) {
            inline for (@typeInfo(T).@"struct".fields) |f| {
                if (comptime acceptanceDiagnostic(f.name)) {
                    continue;
                } else if (comptime std.mem.eql(u8, f.name, "accepted")) {
                    self.accepted = try self.decoder.get(bool);
                    if (self.accepted) try self.skip(@typeInfo(f.type).optional.child);
                } else try self.skip(f.type);
            }
            return;
        }
        switch (@typeInfo(T)) {
            .int, .float, .bool, .@"enum", .pointer => {
                _ = try self.decoder.get(T);
            },
            .array => |a| for (0..a.len) |_| try self.skip(a.child),
            .@"struct" => |s| inline for (s.fields) |f| try self.skip(f.type),
            .optional => |o| if (try self.decoder.get(bool)) {
                try self.skip(o.child);
            },
            .@"union" => |u| {
                const tag = try self.decoder.get(u.tag_type.?);
                inline for (u.fields) |f| if (tag == @field(u.tag_type.?, f.name)) try self.skip(f.type);
            },
            .error_union => |e| if (try self.decoder.get(bool)) {
                _ = try self.errorName(e.error_set);
            } else {
                try self.skip(e.payload);
            },
            .error_set => {
                _ = try self.errorName(T);
            },
            .void => {},
            else => return error.UnsupportedValue,
        }
    }
    fn errorName(self: *ReferenceValidator, comptime T: type) Error![]const u8 {
        const length = try self.decoder.wire.int(u16);
        if (length == 0) return error.Noncanonical;
        const name = try self.decoder.wire.raw(length);
        for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return error.Noncanonical;
        if (@typeInfo(T).error_set) |members| {
            inline for (members) |member| if (std.mem.eql(u8, name, member.name)) return name;
            return error.InvalidEnum;
        }
        return name;
    }
};
fn validateReferenceType(comptime T: type, bytes: []const u8) Error!void {
    var scanner: ReferenceValidator = .{ .decoder = .{ .wire = .{ .bytes = bytes } } };
    try scanner.skip(Native(T));
    try scanner.decoder.wire.finish();
}
pub fn validateReference(record: format.ReferenceRecord) Error!void {
    if (!validate(record.family, .reference)) return error.UnsupportedFamily;
    switch (@as(Family, @enumFromInt(record.family))) {
        .cut_fact => try validateReferenceType(cuts.Point, record.bytes),
        .boundary_fact => try validateReferenceType(cuts.BoundaryPoint, record.bytes),
        .control_event => try validateReferenceType(semantic.ControlEvent, record.bytes),
        .ui_event => try validateReferenceType(semantic.UiEvent, record.bytes),
        .mailbox_event => {
            const value = try decode(Native(mailbox.Checkpoint), record.bytes);
            if (value.occurrence == 0 or mailboxRole(mailboxCutRole(mailboxCut(value.value))) != record.role) return error.InvalidOrder;
            try validateMailboxCheckpoint(value.value);
        },
        .worker_gate_event => {
            const value = try decode(Native(mailbox.WorkerGateCheckpoint), record.bytes);
            if (value.occurrence == 0 or workerGateRole(value.value.role) != record.role) return error.InvalidOrder;
            try validateWorkerGateCheckpoint(value.value);
        },
        .command_dequeued => try validateReferenceType(?semantic.Command, record.bytes),
        .close_observed => try validateReferenceType(void, record.bytes),
        .close_polled => try validateReferenceType(bool, record.bytes),
        .worker_event => try validateReferenceType(semantic.WorkerEvent, record.bytes),
        .worker_fact => try validateReferenceType(stream.WorkerFact, record.bytes),
        .source_event => try validateReferenceType(source.SemanticEvent, record.bytes),
        .source_fact => try validateReferenceType(stream.SourceFact, record.bytes),
        .public_input => try validateReferenceType(audio.music.trace.Input, record.bytes),
        .schedule => try validateReferenceType(audio.music.trace.ScheduleEntry, record.bytes),
        .acceptance => try validateReferenceType(Acceptance, record.bytes),
        .tick => try validateReferenceType(audio.ControlRuntime.LiveTickEventV1, record.bytes),
        .frontier => try validateReferenceType(Frontier, record.bytes),
        .audio_event => try validateReferenceType(audio.device.SemanticAudioEvent, record.bytes),
        .pcm => {
            var d: Decoder = .{ .wire = .{ .bytes = record.bytes } };
            const pcm = try d.get(Native(Pcm));
            if (pcm.occurrence == 0 or pcm.value.channels != 2 or pcm.value.samples % 2 != 0) return error.InvalidLength;
            _ = try d.wire.raw(@as(usize, pcm.value.samples) * 4);
            try d.wire.finish();
        },
        else => return error.UnsupportedFamily,
    }
}
/// These parsers inspect references only for admission/accounting. They never
/// manufacture a Zig error value and are not an execution capability.
pub const mailbox = @import("sme-author-live-mailbox");
const UiReference = struct {
    occurrence: u64,
    tag: std.meta.Tag(semantic.UiEvent),
    call_id: u64,
    call: ?UiInvocation = null,
    operation: ?semantic.UiOperation = null,
    failure: ?[]const u8 = null,
    command: ?semantic.Command = null,
    event: ?semantic.UiMailboxEvent = null,
};
fn referencePayload(comptime T: type, bytes: []const u8, tag: std.meta.Tag(T)) Error!Decoder {
    var decoder: Decoder = .{ .wire = .{ .bytes = bytes } };
    if (try decoder.get(u64) == 0 or try decoder.get(std.meta.Tag(T)) != tag) return error.InvalidOrder;
    return decoder;
}
fn uiReference(bytes: []const u8) Error!UiReference {
    try validateReferenceType(semantic.UiEvent, bytes);
    var scanner: ReferenceValidator = .{ .decoder = .{ .wire = .{ .bytes = bytes } } };
    const occurrence = try scanner.decoder.get(u64);
    if (occurrence == 0) return error.InvalidOrder;
    const tag = try scanner.decoder.get(std.meta.Tag(semantic.UiEvent));
    if (tag == .enter) {
        const call = try scanner.decoder.get(UiInvocation);
        try scanner.decoder.wire.finish();
        return .{ .occurrence = occurrence, .tag = tag, .call_id = call.call_id, .call = call };
    }
    var result: UiReference = .{ .occurrence = occurrence, .tag = tag, .call_id = try scanner.decoder.get(u64) };
    const operation = try scanner.decoder.get(semantic.UiOperation);
    result.operation = operation;
    if (operation == .pop_event) {
        result.event = try scanner.decoder.get(?semantic.UiMailboxEvent);
    } else if (try scanner.decoder.get(bool)) {
        result.failure = try scanner.errorName(mailbox.Error);
    } else if (operation == .submit) {
        result.command = try scanner.decoder.get(semantic.Command);
    }
    try scanner.decoder.wire.finish();
    return result;
}
fn increment(value: *u64) Error!void {
    value.* = std.math.add(u64, value.*, 1) catch return error.CounterOverflow;
}
fn expectFailure(actual: ?[]const u8, expected: []const u8) Error!void {
    if (actual == null or !std.mem.eql(u8, actual.?, expected)) return error.InvalidOrder;
}
fn commandShape(command: semantic.Command) Error!void {
    if (command.id == 0 or command.identity.epoch == 0 or command.slot >= mailbox.command_capacity) return error.InvalidOrder;
    if (command.kind == .recover or command.device_epoch != 0) return error.UnsupportedValue;
}
fn eventShape(event: semantic.UiMailboxEvent) Error!void {
    try commandShape(event.command);
    if (event.recovery != null) return error.UnsupportedValue;
    switch (event.kind) {
        .accepted => if (event.terminal != null or event.receipt == null) return error.Noncanonical,
        .terminal => if (event.terminal == null) return error.Noncanonical else if (event.terminal.? == .interrupted) return error.UnsupportedValue,
    }
}
/// Bounded structural validation of the one non-reentrant UI transcript. This
/// ledger exists only before owner creation; it is never loaded into Mailbox.
/// Wrong/duplicate ACK and rejected submit attempts are retained as actual
/// error references, not rejected merely because the UI attempted them.
pub const UiTranscriptValidator = struct {
    const Reservation = struct { command: semantic.Command, accepted: bool = false, terminal: bool = false };
    identity: ?semantic.Identity = null,
    active: ?UiInvocation = null,
    last_occurrence: u64 = 0,
    reservations: [mailbox.command_capacity]?Reservation = @splat(null),
    calls: u64 = 0,
    submit_attempts: u64 = 0,
    successful_submissions: u64 = 0,
    accepted_events: u64 = 0,
    terminal_events: u64 = 0,
    terminal_acks: u64 = 0,
    close_succeeded: bool = false,
    pub fn observe(self: *UiTranscriptValidator, record: format.ReferenceRecord) Error!void {
        if (record.role != .ui or record.family != @intFromEnum(Family.ui_event)) return error.UnsupportedFamily;
        const value = try uiReference(record.bytes);
        if (value.occurrence <= self.last_occurrence) return error.InvalidOrder;
        self.last_occurrence = value.occurrence;
        if (value.tag == .enter) {
            if (self.active != null) return error.InvalidOrder;
            try increment(&self.calls);
            if (value.call_id != self.calls) return error.InvalidOrder;
            self.active = value.call.?;
            if (self.active.?.call == .submit) try increment(&self.submit_attempts);
            return;
        }
        const active = self.active orelse return error.InvalidOrder;
        if (value.call_id != active.call_id or value.operation.? != std.meta.activeTag(active.call)) return error.InvalidOrder;
        switch (active.call) {
            .submit => |input| {
                if (input.kind == .recover) {
                    // Ordinary submit rejects Recover natively; requestRecovery
                    // is a different public operation and is not represented.
                    try expectFailure(value.failure, "InvalidState");
                } else if (value.failure) |failure| {
                    const allowed = [_][]const u8{ "InvalidEpoch", "IdentityMismatch", "QueueFull", "AdmissionClosed", "SequenceExhausted" };
                    var found = false;
                    for (allowed) |name| if (std.mem.eql(u8, failure, name)) {
                        found = true;
                        break;
                    };
                    if (!found) return error.InvalidOrder;
                } else {
                    const command = value.command orelse return error.Incomplete;
                    try commandShape(command);
                    const identity = self.identity orelse return error.Incomplete;
                    if (self.close_succeeded or !std.meta.eql(command.identity, identity) or !std.meta.eql(command.identity, input.identity) or command.kind != input.kind) return error.InvalidOrder;
                    try increment(&self.successful_submissions);
                    if (command.id != self.successful_submissions) return error.InvalidOrder;
                    var free: ?usize = null;
                    for (self.reservations, 0..) |entry, i| if (entry == null) {
                        free = i;
                        break;
                    };
                    if (free == null or command.slot != free.?) return error.InvalidOrder;
                    self.reservations[command.slot] = .{ .command = command };
                }
            },
            .pop_event => if (value.event) |event| {
                try eventShape(event);
                const reservation = self.reservations[event.command.slot] orelse return error.InvalidOrder;
                if (!std.meta.eql(reservation.command, event.command)) return error.InvalidOrder;
                const entry = &self.reservations[event.command.slot].?;
                if (entry.terminal) return error.InvalidOrder;
                switch (event.kind) {
                    .accepted => {
                        if (entry.accepted) return error.InvalidOrder;
                        entry.accepted = true;
                        try increment(&self.accepted_events);
                    },
                    .terminal => {
                        entry.terminal = true;
                        try increment(&self.terminal_events);
                    },
                }
            },
            .acknowledge_terminal => |id| {
                var found: ?usize = null;
                for (self.reservations, 0..) |entry, i| if (entry) |reservation| {
                    if (reservation.command.id == id) {
                        found = i;
                        break;
                    }
                };
                if (found) |index| {
                    if (self.reservations[index].?.terminal) {
                        if (value.failure != null) return error.InvalidOrder;
                        self.reservations[index] = null;
                        try increment(&self.terminal_acks);
                    } else try expectFailure(value.failure, "TerminalNotConsumed");
                } else try expectFailure(value.failure, "UnknownCommand");
            },
            .request_close => |epoch| {
                const identity = self.identity orelse return error.Incomplete;
                if (epoch != identity.epoch) {
                    try expectFailure(value.failure, "InvalidEpoch");
                } else {
                    if (value.failure != null) return error.InvalidOrder;
                    self.close_succeeded = true;
                }
            },
        }
        self.active = null;
    }
    pub fn finish(self: *const UiTranscriptValidator) Error!void {
        if (self.active != null or !self.close_succeeded) return error.Incomplete;
        for (self.reservations) |entry| if (entry != null) return error.Incomplete;
        if (self.successful_submissions != self.terminal_events or self.terminal_events != self.terminal_acks) return error.CountMismatch;
    }
};
/// Two independent forward reference scans reconcile identities without assuming
/// submit-return precedes Control dequeue or emit-hook precedes UI pop-return.
/// Queue release/acquire cuts, not these return stamps, own overlap scheduling.
const CommandAccounting = struct {
    const Emission = struct { command: semantic.Command, accepted: bool = false, terminal: bool = false };
    submissions: ComparisonCursor,
    pops: ComparisonCursor,
    slots: [mailbox.command_capacity]?Emission = @splat(null),
    accepted: u64 = 0,
    terminals: u64 = 0,
    fn init(reader: *const format.Reader) CommandAccounting {
        return .{ .submissions = ComparisonCursor.init(reader, .ui), .pops = ComparisonCursor.init(reader, .ui) };
    }
    fn nextSubmission(self: *CommandAccounting) Error!?semantic.Command {
        while (try self.submissions.next()) |record| {
            if (record.family == @intFromEnum(Family.mailbox_event)) continue;
            if (record.family != @intFromEnum(Family.ui_event)) return error.UnsupportedFamily;
            const reference = try uiReference(record.bytes);
            if (reference.tag == .end and reference.operation.? == .submit and reference.command != null) return reference.command;
        }
        return null;
    }
    fn nextPop(self: *CommandAccounting) Error!?semantic.UiMailboxEvent {
        while (try self.pops.next()) |record| {
            if (record.family == @intFromEnum(Family.mailbox_event)) continue;
            if (record.family != @intFromEnum(Family.ui_event)) return error.UnsupportedFamily;
            const reference = try uiReference(record.bytes);
            if (reference.tag == .end and reference.operation.? == .pop_event and reference.event != null) return reference.event;
        }
        return null;
    }
    fn dequeued(self: *CommandAccounting, command: semantic.Command) Error!void {
        try commandShape(command);
        const submitted = try self.nextSubmission() orelse return error.Incomplete;
        if (!std.meta.eql(command, submitted)) return error.InvalidOrder;
        if (self.slots[command.slot]) |previous| if (!previous.terminal) return error.Incomplete;
        self.slots[command.slot] = .{ .command = command };
    }
    fn emitted(self: *CommandAccounting, event: @FieldType(semantic.ControlEvent, "command_emitted")) Error!void {
        try commandShape(event.command);
        const popped = try self.nextPop() orelse return error.Incomplete;
        try eventShape(popped);
        if (!std.meta.eql(popped.command, event.command) or @intFromEnum(popped.kind) != @intFromEnum(event.kind) or
            !std.meta.eql(popped.receipt, event.receipt) or popped.terminal != event.terminal) return error.InvalidOrder;
        const stored = self.slots[event.command.slot] orelse return error.InvalidOrder;
        if (!std.meta.eql(stored.command, event.command) or stored.terminal) return error.InvalidOrder;
        const entry = &self.slots[event.command.slot].?;
        switch (event.kind) {
            .accepted => {
                if (entry.accepted) return error.InvalidOrder;
                entry.accepted = true;
                try increment(&self.accepted);
            },
            .terminal => {
                entry.terminal = true;
                try increment(&self.terminals);
            },
        }
    }
    fn finish(self: *CommandAccounting) Error!void {
        if (try self.nextSubmission() != null or try self.nextPop() != null) return error.Incomplete;
        for (self.slots) |entry| if (entry) |emission| if (!emission.terminal) return error.Incomplete;
    }
};

pub const InputPreflight = struct {
    /// Diagnostic attempt only: no ordering is inferred for these overlaps.
    unresolved_scalar_overlaps: u64 = 0,
    events: u64 = 0,
    control_calls: u64 = 0,
    worker_calls: u64 = 0,
    callbacks: u64 = 0,
    callback_frames: u64 = 0,
    /// Diagnostic cardinalities only, never replay instructions.
    commands: u64 = 0,
    ui_calls: u64 = 0,
    submit_attempts: u64 = 0,
    successful_submissions: u64 = 0,
    accepted_events: u64 = 0,
    terminal_events: u64 = 0,
    terminal_acks: u64 = 0,
    multi_frame_ticks: u64 = 0,
};
const AcceptanceSummary = struct { tick: u64, frame: u64, accepted: bool };
fn acceptanceSummary(bytes: []const u8) Error!AcceptanceSummary {
    var scanner: ReferenceValidator = .{ .decoder = .{ .wire = .{ .bytes = bytes } } };
    _ = try scanner.decoder.get(u64);
    const incoming = try scanner.decoder.get(@FieldType(stream.LiveAcceptanceAttemptV1, "incoming"));
    try scanner.skip(@FieldType(stream.LiveAcceptanceAttemptV1, "cut"));
    try scanner.skip(@FieldType(stream.LiveAcceptanceAttemptV1, "deferred"));
    try scanner.skip(stream.observation.Acceptance);
    try scanner.skip(@FieldType(stream.LiveAcceptanceAttemptV1, "returned_error"));
    const frame = try scanner.decoder.get(u64);
    try scanner.decoder.wire.finish();
    return .{ .tick = incoming.control_tick, .frame = frame, .accepted = scanner.accepted };
}
fn validateReferenceTag(marker: EventCut, record: format.ReferenceRecord) Error!void {
    switch (marker.family) {
        .control_event, .ui_event, .mailbox_event, .worker_event, .worker_fact, .source_event, .schedule, .tick, .audio_event => {
            if (record.family == @intFromEnum(Family.pcm)) return;
            var d: format.Decoder = .{ .bytes = record.bytes };
            _ = try d.int(u64);
            if (try d.int(u64) != marker.tag) return error.InvalidOrder;
        },
        else => {},
    }
}
fn unionTag(comptime T: type, value: u16) Error!std.meta.Tag(T) {
    return std.enums.fromInt(std.meta.Tag(T), value) orelse error.InvalidEnum;
}
fn expectRole(actual: format.Role, expected: format.Role) Error!void {
    if (actual != expected) return error.InvalidOrder;
}
fn sameOccurrence(comptime T: type, r: format.InputRecord, family: Family, occurrence: u64) Error!T {
    const value = try decodeInput(T, r, family);
    if (value.occurrence != occurrence) return error.InvalidOrder;
    return value.value;
}
fn expectedInput(marker: EventCut, role: format.Role, reference: ?format.ReferenceRecord) Error!?Family {
    switch (marker.family) {
        .raw_clock => {
            try expectRole(role, .worker);
            if (marker.tag != 0) return error.InvalidEnum;
            return .raw_clock;
        },
        .cut_fact => {
            _ = try nativeRole(role);
            if (marker.tag != 0) return error.InvalidEnum;
            return .cut;
        },
        .boundary_fact => {
            _ = try nativeRole(role);
            if (marker.tag != 0) return error.InvalidEnum;
            // Reference inspection here checks grammar only. It cannot choose
            // an actual selector or grant a later runtime call.
            const value = try decode(Native(cuts.BoundaryPoint), (reference orelse return error.Incomplete).bytes);
            return switch (value.value.site) {
                .service_acceptance_selected, .service_worker_selected => null,
                else => .boundary,
            };
        },
        .control_event => {
            try expectRole(role, .control);
            return switch (try unionTag(semantic.ControlEvent, marker.tag)) {
                .started => .launch_descriptor,
                .enter => .control_call,
                else => null,
            };
        },
        .worker_gate_event => {
            if (role != .control and role != .worker) return error.InvalidOrder;
            if (marker.tag != 0) return error.InvalidEnum;
            return .worker_gate_cut;
        },
        .mailbox_event => {
            if (role != .control and role != .ui) return error.InvalidOrder;
            _ = try unionTag(mailbox.Checkpoint, marker.tag);
            return .mailbox_cut;
        },
        .ui_event => {
            try expectRole(role, .ui);
            return if (try unionTag(semantic.UiEvent, marker.tag) == .enter) .ui_call else null;
        },
        .worker_event => {
            try expectRole(role, .worker);
            return if (try unionTag(semantic.WorkerEvent, marker.tag) == .enter) .worker_call else null;
        },
        .worker_fact => {
            try expectRole(role, .worker);
            switch (try unionTag(stream.WorkerFact, marker.tag)) {
                .scan, .idle, .clock => return error.UnsupportedValue,
                else => {},
            }
        },
        .source_event => switch (try unionTag(source.SemanticEvent, marker.tag)) {
            .load_begin, .load_return => try expectRole(role, .control),
            else => try expectRole(role, .worker),
        },
        .source_fact => {
            try expectRole(role, .worker);
            if (marker.tag != 0) return error.InvalidEnum;
        },
        .public_input, .acceptance, .frontier => {
            try expectRole(role, .control);
            if (marker.tag != 0) return error.InvalidEnum;
        },
        .schedule => {
            try expectRole(role, .control);
            _ = try unionTag(audio.music.trace.ScheduleEntry, marker.tag);
        },
        .tick => {
            try expectRole(role, .control);
            _ = try unionTag(audio.ControlRuntime.LiveTickEventV1, marker.tag);
        },
        .audio_event => {
            try expectRole(role, .render);
            return if (try unionTag(audio.device.SemanticAudioEvent, marker.tag) == .callback_begin) .callback else null;
        },
        else => return error.UnsupportedFamily,
    }
    return null;
}
/// Complete finite payload/role/local-order/global-occurrence admission before
/// any fresh owner effects. References are parsed only for canonical shape and
/// comparison pairing; their decisions are never returned in this result.
pub const AdmissionPolicy = enum {
    /// Compatibility contract: one strict native attempt, not recovered atomic order.
    native_attempt,
    /// Reject the two unsequenced job-selector predicate conflicts before owners.
    ordered_job_scans,
};

pub fn validateInputs(reader: *const format.Reader, identity: format.Identity) Error!InputPreflight {
    return validateInputsWithPolicy(reader, identity, .native_attempt);
}

pub fn validateInputsWithPolicy(reader: *const format.Reader, identity: format.Identity, policy: AdmissionPolicy) Error!InputPreflight {
    var summary: InputPreflight = .{};
    var config_seen = false;
    var provider_seen = false;
    var loaded = false;
    var closed = false;
    var returned = false;
    var joined = false;
    var worker_returned = false;
    var worker_joined = false;
    var close_seen = false;
    var active_control = false;
    var launch_identity: ?semantic.Identity = null;
    var launch_descriptor: ?LaunchDescriptor = null;
    var ui: UiTranscriptValidator = .{};
    var mailbox_pairs: MailboxPairs = .{};
    var worker_gate_pairs: WorkerGatePairs = .{};
    var command_accounting = CommandAccounting.init(reader);
    var control_result = false;
    var active_worker: ?u64 = null;
    var worker_result = false;
    var accepted_tick: ?u64 = null;
    var accepted_frame: u64 = 0;
    var witnessed_tick: ?u64 = null;
    inline for (.{ format.Role.control, format.Role.worker, format.Role.render, format.Role.ui }) |role| {
        var input = InputCursor.init(reader, role);
        var comparison = ComparisonCursor.init(reader, role);
        var last_occurrence: u64 = 0;
        while (try input.next()) |raw_marker| {
            const marker = try decodeInput(EventCut, raw_marker, .event_cut);
            if (marker.occurrence <= last_occurrence) return error.InvalidOrder;
            last_occurrence = marker.occurrence;
            summary.events = try std.math.add(u64, summary.events, 1);
            var reference: ?format.ReferenceRecord = null;
            if (marker.value.family != .raw_clock) {
                const r = try comparison.next() orelse return error.Incomplete;
                const expected_family: Family = if (marker.value.family == .audio_event and try unionTag(audio.device.SemanticAudioEvent, marker.value.tag) == .pcm) .pcm else marker.value.family;
                if (r.family != @intFromEnum(expected_family)) return error.UnsupportedFamily;
                var d: format.Decoder = .{ .bytes = r.bytes };
                if (try d.int(u64) != marker.occurrence) return error.InvalidOrder;
                try validateReference(r);
                try validateReferenceTag(marker.value, r);
                if (marker.value.family == .acceptance) {
                    const accepted = try acceptanceSummary(r.bytes);
                    if (accepted.accepted) {
                        if (accepted_tick != accepted.tick) {
                            accepted_tick = accepted.tick;
                            accepted_frame = accepted.frame;
                        } else if (accepted_frame != accepted.frame and witnessed_tick != accepted.tick) {
                            summary.multi_frame_ticks = std.math.add(u64, summary.multi_frame_ticks, 1) catch return error.CounterOverflow;
                            witnessed_tick = accepted.tick;
                        }
                    }
                }
                reference = r;
            }
            if (marker.value.family != .mailbox_event) try mailbox_pairs.other(role);
            if (marker.value.family != .worker_gate_event) try worker_gate_pairs.other(role);
            const expected = try expectedInput(marker.value, role, reference);
            if (expected) |family| {
                const r = try input.next() orelse return error.Incomplete;
                switch (family) {
                    .launch_descriptor => {
                        if (launch_descriptor != null) return error.InvalidOrder;
                        const descriptor = try sameOccurrence(LaunchDescriptor, r, family, marker.occurrence);
                        var observed = try referencePayload(semantic.ControlEvent, reference.?.bytes, .started);
                        const original = try observed.get(@FieldType(semantic.ControlEvent, "started"));
                        if (!std.meta.eql(descriptor, launchDescriptor(original))) return error.InvalidOrder;
                        launch_descriptor = descriptor;
                    },
                    .control_call => {
                        const invocation = try sameOccurrence(ControlInvocation, r, family, marker.occurrence);
                        var observed = try referencePayload(semantic.ControlEvent, reference.?.bytes, .enter);
                        const original = try observed.get(@FieldType(semantic.ControlEvent, "enter"));
                        if (original.call_id != invocation.call_id or !std.meta.eql(controlArguments(original.call), invocation.call)) return error.InvalidOrder;
                        summary.control_calls = std.math.add(u64, summary.control_calls, 1) catch return error.CounterOverflow;
                        if (invocation.call_id != summary.control_calls) return error.InvalidOrder;
                        switch (invocation.call) {
                            .provider_create => |v| {
                                if (provider_seen or v.source_bytes == 0 or !std.mem.eql(u8, &v.source_hash, &identity.source)) return error.WrongSource;
                                provider_seen = true;
                            },
                            .owner_create => |v| {
                                if (config_seen or !std.mem.eql(u8, &try configHash(v), &identity.config)) return error.WrongConfig;
                                config_seen = true;
                            },
                            .load => |v| {
                                if (loaded or v.source_bytes == 0 or !std.mem.eql(u8, &v.source_hash, &identity.source)) return error.WrongSource;
                                loaded = true;
                            },
                            .device_open => |v| try validateDeviceConfig(v),
                            .cleanup_render => |v| if (v.frames == 0 or v.channels != 2) {
                                return error.UnsupportedValue;
                            },
                            else => {},
                        }
                    },
                    .mailbox_cut => {
                        const value = try sameOccurrence(MailboxCut, r, family, marker.occurrence);
                        const actual = try decode(Native(mailbox.Checkpoint), (reference orelse return error.Incomplete).bytes);
                        if (mailboxRole(mailboxCutRole(value)) != role or !std.meta.eql(value, mailboxCut(actual.value))) return error.InvalidOrder;
                        if (role == .ui) {
                            const active = ui.active orelse return error.InvalidOrder;
                            switch (value) {
                                .ring => |ring| switch (active.call) {
                                    .submit => if (ring.queue != .commands or ring.operation != .push) return error.InvalidOrder,
                                    .pop_event => if (ring.queue != .events or ring.operation != .pop) return error.InvalidOrder,
                                    else => return error.InvalidOrder,
                                },
                                .admission => |admission| if (active.call != .request_close or admission.operation != .request_close) return error.InvalidOrder,
                            }
                        }
                        try mailbox_pairs.observe(value);
                    },
                    .worker_gate_cut => {
                        const value = try sameOccurrence(WorkerGateCut, r, family, marker.occurrence);
                        const actual = try decode(Native(mailbox.WorkerGateCheckpoint), (reference orelse return error.Incomplete).bytes);
                        if (workerGateRole(value.role) != role or !std.meta.eql(value, workerGateCut(actual.value))) return error.InvalidOrder;
                        try worker_gate_pairs.observe(value);
                    },
                    .ui_call => {
                        const invocation = try sameOccurrence(UiInvocation, r, family, marker.occurrence);
                        const observed = try uiReference((reference orelse return error.Incomplete).bytes);
                        if (observed.tag != .enter or !std.meta.eql(invocation, observed.call.?)) return error.InvalidOrder;
                    },
                    .worker_call => {
                        const call = try sameOccurrence(u64, r, family, marker.occurrence);
                        summary.worker_calls = std.math.add(u64, summary.worker_calls, 1) catch return error.CounterOverflow;
                        if (call != summary.worker_calls) return error.InvalidOrder;
                    },
                    .callback => {
                        const callback = try sameOccurrence(Callback, r, family, marker.occurrence);
                        if (!callback.output_present or callback.channels != 2 or callback.frame_count == 0) return error.UnsupportedValue;
                        summary.callbacks = std.math.add(u64, summary.callbacks, 1) catch return error.CounterOverflow;
                        summary.callback_frames = std.math.add(u64, summary.callback_frames, callback.frame_count) catch return error.CounterOverflow;
                        if (summary.callback_frames > 262144) return error.UnsupportedValue;
                    },
                    .raw_clock => {
                        const clock = try sameOccurrence(RawClock, r, family, marker.occurrence);
                        if (clock.job == 0 or clock.error_code > 1 or (!clock.available and (clock.error_code != 0 or clock.value != 0)) or (clock.error_code != 0 and clock.value != 0)) return error.Noncanonical;
                    },
                    .cut => {
                        const cut = try sameOccurrence(Cut, r, family, marker.occurrence);
                        const point = try decode(Native(cuts.Point), (reference orelse return error.Incomplete).bytes);
                        try validateExclusionPoint(point.value);
                        if (wireRole(point.value.role) != cut.role or point.value.site != cut.site or point.value.edge != cut.edge or point.value.index != cut.index or point.value.generation != cut.generation) return error.InvalidOrder;
                        if (publicationPrefixPoint(cut.role, cut.site, cut.edge) and point.value.value != @as(?u64, cut.publication_prefix)) return error.InvalidOrder;
                        if (cut.role != role or !cuts.allowedPoint(.{ .role = try nativeRole(role), .site = cut.site, .edge = cut.edge, .index = cut.index, .generation = cut.generation })) return error.UnsupportedValue;
                        if (exclusionClaim(cut.role, cut.site) and cut.edge == .after) {
                            const claim = try input.next() orelse return error.Incomplete;
                            if (claim.role != role) return error.InvalidOrder;
                            const success = try sameOccurrence(bool, claim, .exclusion_claim, marker.occurrence);
                            // The explicit INPUT only schedules the original CAS.
                            // Its actual scalar reference remains independently
                            // encoded and must be exactly 0(success)/1(failure).
                            if (point.value.value != @as(?u64, if (success) 0 else 1)) return error.InvalidOrder;
                        }
                    },
                    .boundary => {
                        const boundary = try sameOccurrence(Boundary, r, family, marker.occurrence);
                        if (boundary.role != role) return error.InvalidOrder;
                        switch (boundary.site) {
                            .service_acceptance_selected, .service_worker_selected => return error.UnsupportedValue,
                            else => {},
                        }
                    },
                    else => return error.UnsupportedFamily,
                }
            }
            if (marker.value.family == .control_event) {
                const event = try unionTag(semantic.ControlEvent, marker.value.tag);
                if (joined) return error.InvalidOrder;
                if (returned and event != .control_joined) return error.InvalidOrder;
                if (closed and event != .returned and event != .control_joined) return error.InvalidOrder;
                var event_decoder = try referencePayload(semantic.ControlEvent, reference.?.bytes, event);
                switch (event) {
                    .started => {
                        if (launch_identity != null or summary.control_calls != 0) return error.InvalidOrder;
                        const value = try event_decoder.get(@FieldType(semantic.ControlEvent, "started"));
                        if (value.identity.epoch == 0 or !std.mem.eql(u8, &value.identity.artifact_hash, &identity.source)) return error.WrongSource;
                        launch_identity = value.identity;
                        ui.identity = value.identity;
                    },
                    .enter => {
                        const value = try event_decoder.get(@FieldType(semantic.ControlEvent, "enter"));
                        if (value.call_id != summary.control_calls) return error.InvalidOrder;
                        if (active_control) return error.InvalidOrder;
                        active_control = true;
                        control_result = false;
                    },
                    .result => {
                        if (!active_control or control_result or try event_decoder.get(u64) != summary.control_calls) return error.InvalidOrder;
                        control_result = true;
                    },
                    .end => {
                        const value = try event_decoder.get(@FieldType(semantic.ControlEvent, "end"));
                        if (!active_control or !control_result or value.call_id != summary.control_calls) return error.InvalidOrder;
                        active_control = false;
                    },
                    .command_dequeued => if (try event_decoder.get(?semantic.Command)) |command| {
                        try command_accounting.dequeued(command);
                        summary.commands = std.math.add(u64, summary.commands, 1) catch return error.CounterOverflow;
                    },
                    .command_emitted => try command_accounting.emitted(try event_decoder.get(@FieldType(semantic.ControlEvent, "command_emitted"))),
                    .close_observed => close_seen = true,
                    .worker_joined => worker_joined = true,
                    .closed => {
                        if (!worker_joined or !close_seen or active_control) return error.Incomplete;
                        closed = true;
                    },
                    .returned => {
                        if (!closed) return error.Incomplete;
                        returned = true;
                    },
                    .control_joined => {
                        if (!returned) return error.Incomplete;
                        joined = true;
                    },
                    else => {},
                }
            } else if (marker.value.family == .worker_event) {
                const event = try unionTag(semantic.WorkerEvent, marker.value.tag);
                if (worker_returned) return error.InvalidOrder;
                if (event == .startup_aborted) return error.UnsupportedValue;
                var event_decoder = try referencePayload(semantic.WorkerEvent, reference.?.bytes, event);
                switch (event) {
                    .enter => {
                        const id = try event_decoder.get(u64);
                        if (active_worker != null or id != summary.worker_calls) return error.InvalidOrder;
                        active_worker = id;
                        worker_result = false;
                    },
                    .result => {
                        if (active_worker == null or worker_result or try event_decoder.get(u64) != active_worker.?) return error.InvalidOrder;
                        worker_result = true;
                    },
                    .end => {
                        const value = try event_decoder.get(@FieldType(semantic.WorkerEvent, "end"));
                        if (active_worker == null or !worker_result or value.call_id != active_worker.?) return error.InvalidOrder;
                        active_worker = null;
                    },
                    .returned => {
                        if (active_worker != null) return error.Incomplete;
                        worker_returned = true;
                    },
                    else => {},
                }
            } else if (marker.value.family == .ui_event) {
                try ui.observe(reference.?);
            }
        }
        try comparison.finish();
    }
    if (!provider_seen or !config_seen or !loaded or launch_identity == null or launch_descriptor == null or !joined or !worker_returned or !worker_joined or active_control or active_worker != null) return error.Incomplete;
    try ui.finish();
    try mailbox_pairs.finish();
    try worker_gate_pairs.finish();
    try command_accounting.finish();
    if (summary.commands != ui.successful_submissions or command_accounting.terminals != ui.terminal_events or command_accounting.accepted != ui.accepted_events) return error.CountMismatch;
    summary.ui_calls = ui.calls;
    summary.submit_attempts = ui.submit_attempts;
    summary.successful_submissions = ui.successful_submissions;
    summary.accepted_events = ui.accepted_events;
    summary.terminal_events = ui.terminal_events;
    summary.terminal_acks = ui.terminal_acks;
    // Four producer cursors, never a graph or array proportional to event count.
    // UI brackets alone do not identify mailbox atomic linearization order.
    var cursors = [_]InputCursor{ InputCursor.init(reader, .control), InputCursor.init(reader, .worker), InputCursor.init(reader, .render), InputCursor.init(reader, .ui) };
    var heads: [format.role_count]?OrderedEvent = @splat(null);
    for (&cursors, 0..) |*cursor, i| heads[i] = try nextOrderedEvent(cursor);
    var occurrence: u64 = 0;
    // The compatibility policy allows one strict native attempt for fully represented job reads.
    // ordered_job_scans instead rejects these known predicate overlaps before owners.
    // This does not resolve their atomic order: the real after-read predicate
    // comparison is mandatory, and any mismatch terminates the attempt. Guard
    // custody and omitted Scheduler scans remain pre-owner rejection cases.
    var intervals: ScanIntervals = .{ .allow_unresolved_job_reads = policy == .native_attempt };
    var grammar: ServiceScanGrammar = .{};
    var payload_intervals: payload_overlap.Validator = .{};
    var ui_invocation_active = false;
    while (true) {
        var selected: ?usize = null;
        for (heads, 0..) |head, i| if (head) |value| {
            if (selected == null or value.occurrence < heads[selected.?].?.occurrence) selected = i;
        };
        const i = selected orelse break;
        occurrence = std.math.add(u64, occurrence, 1) catch return error.CounterOverflow;
        const event = heads[i].?;
        if (event.occurrence != occurrence) return error.InvalidOrder;
        // Join runs on the same designated UI owner as submit/pop/ACK/Close.
        // Its global occurrence cannot fall inside a synchronous UI invocation:
        // that call would wait for a join which this same thread cannot perform.
        // Only occurrence markers (execution inputs), never references, decide
        // this finite exclusion rule.
        if (event.marker.family == .ui_event) {
            switch (try unionTag(semantic.UiEvent, event.marker.tag)) {
                .enter => {
                    if (ui_invocation_active) return error.InvalidOrder;
                    ui_invocation_active = true;
                },
                .end => {
                    if (!ui_invocation_active) return error.InvalidOrder;
                    ui_invocation_active = false;
                },
            }
        } else if (event.marker.family == .control_event and
            try unionTag(semantic.ControlEvent, event.marker.tag) == .control_joined and ui_invocation_active) return error.InvalidOrder;
        if (event.cut) |cut| {
            try payload_intervals.observe(cut);
            try grammar.point(cut);
            try intervals.point(cut);
        } else if (event.boundary) |boundary| {
            try grammar.boundary(boundary);
            try intervals.boundary(boundary);
        } else try grammar.other(event.role);
        heads[i] = try nextOrderedEvent(&cursors[i]);
    }
    if (ui_invocation_active) return error.Incomplete;
    if (occurrence != summary.events) return error.CountMismatch;
    try intervals.finish();
    try grammar.finish();
    try payload_intervals.finish();
    summary.unresolved_scalar_overlaps = intervals.unresolved_scalar_overlaps;
    return summary;
}
const OrderedEvent = struct { role: format.Role, occurrence: u64, marker: EventCut, cut: ?Cut = null, boundary: ?Boundary = null, exclusion_claim: ?bool = null };
fn nextOrderedEvent(cursor: *InputCursor) Error!?OrderedEvent {
    while (try cursor.next()) |record| if (record.family == @intFromEnum(Family.event_cut)) {
        const marker = try decodeInput(EventCut, record, .event_cut);
        var result: OrderedEvent = .{ .role = record.role, .occurrence = marker.occurrence, .marker = marker.value };
        if (marker.value.family == .cut_fact) {
            const next = try cursor.next() orelse return error.Incomplete;
            result.cut = try sameOccurrence(Cut, next, .cut, marker.occurrence);
            if (exclusionClaim(result.cut.?.role, result.cut.?.site) and result.cut.?.edge == .after) {
                const claim = try cursor.next() orelse return error.Incomplete;
                result.exclusion_claim = try sameOccurrence(bool, claim, .exclusion_claim, marker.occurrence);
            }
        } else if (marker.value.family == .boundary_fact) {
            var peek = cursor.*;
            if (try peek.next()) |next| if (next.family == @intFromEnum(Family.boundary)) {
                result.boundary = try sameOccurrence(Boundary, next, .boundary, marker.occurrence);
                cursor.* = peek;
            };
        }
        return result;
    };
    return null;
}

/// Completeness grammar for the three finite Service envelopes. No loaded
/// state or CAS result is inspected: only actual callback coordinates. The
/// Host uses release_profile; smaller bounds are exposed for focused tests.
pub const ServiceScanGrammar = struct {
    const Span = struct { boundary: Boundary, slot: u16 = 0, phase: u8 = 0, generation: u64 = 0 };
    jobs: u16 = audio.runtime.streaming.release_profile.job_capacity,
    streams: u16 = audio.runtime.streaming.release_profile.max_streams,
    spans: [3]?Span = @splat(null),
    pub fn boundary(self: *ServiceScanGrammar, value: Boundary) Error!void {
        _ = try nativeRole(value.role);
        const entry = &self.spans[@intFromEnum(value.role)];
        if (!packetEnvelope(value.site)) {
            if (entry.* != null) return error.InvalidOrder;
            return;
        }
        const expected: format.Role = switch (value.site) {
            .service_worker_scan => .worker,
            .service_acceptance_scan => .control,
            else => .render,
        };
        try expectRole(value.role, expected);
        if (self.jobs == 0 or self.jobs > 256 or self.streams == 0 or self.streams > 64) return error.UnsupportedValue;
        if (value.role != .render and (value.index != self.jobs or value.generation != 0)) return error.InvalidLength;
        if (value.edge == .before) {
            if (entry.* != null) return error.InvalidOrder;
            entry.* = .{ .boundary = value };
        } else {
            var span = entry.* orelse return error.InvalidOrder;
            var end = span.boundary;
            end.edge = .after;
            if (!std.meta.eql(end, value)) return error.InvalidOrder;
            if (value.role == .render and span.phase == 2) {
                span.slot += 1;
                span.phase = 0;
            }
            if (span.phase != 0 or span.slot != (if (value.role == .render) self.streams else self.jobs)) return error.Incomplete;
            entry.* = null;
        }
    }
    pub fn point(self: *ServiceScanGrammar, value: Cut) Error!void {
        _ = try nativeRole(value.role);
        const entry = &self.spans[@intFromEnum(value.role)];
        if (entry.*) |*span| {
            if (value.role != .render) {
                const site: cuts.Site = if (value.role == .worker) .service_worker_scan else .service_acceptance_scan;
                if (value.site != site or value.index != span.slot or value.index >= self.jobs or value.generation != 0 or
                    value.edge != (if (span.phase == 0) cuts.Edge.before else cuts.Edge.after)) return error.InvalidOrder;
                if (span.phase == 0) span.phase = 1 else {
                    span.phase = 0;
                    span.slot += 1;
                }
                return;
            }
            // A failed claim advances directly to the next slot. A successful
            // claim necessarily has the consumed publication and guard release.
            if (span.phase == 2 and value.site == .service_slot_guard_render_claim) {
                span.slot += 1;
                span.phase = 0;
            }
            if (value.index != span.slot or value.index >= self.streams) return error.InvalidOrder;
            const expected_site: cuts.Site = switch (span.phase) {
                0, 1 => .service_slot_guard_render_claim,
                2, 3 => .service_render_consumed,
                4, 5 => .service_slot_guard_render_release,
                else => return error.InvalidOrder,
            };
            const expected_edge: cuts.Edge = if (span.phase % 2 == 0) .before else .after;
            if (value.site != expected_site or value.edge != expected_edge) return error.InvalidOrder;
            if (span.phase < 2) {
                if (value.generation != 0) return error.InvalidOrder;
            } else if (span.phase == 2) span.generation = value.generation else if (value.generation != span.generation) return error.InvalidOrder;
            if (span.phase == 5) {
                span.slot += 1;
                span.phase = 0;
            } else span.phase += 1;
        } else switch (value.site) {
            .service_worker_scan, .service_acceptance_scan, .service_slot_guard_render_claim, .service_slot_guard_render_release, .service_render_consumed => return error.InvalidOrder,
            else => {},
        }
    }
    pub fn other(self: *const ServiceScanGrammar, role: format.Role) Error!void {
        if (role == .ui) return;
        if (self.spans[@intFromEnum(role)] != null) return error.InvalidOrder;
    }
    pub fn finish(self: *const ServiceScanGrammar) Error!void {
        for (self.spans) |span| if (span != null) return error.Incomplete;
    }
};

/// Finite scalar conflict admission, not a generic dependency graph. Service
/// scan packets retain every read/CAS edge. Strict mode rejects same-slot
/// conflicting atomic overlap; explicit attempt mode counts unresolved job
/// reads without deriving an order or weakening the actual comparator. Omitted Scheduler scalar scans still use
/// whole-envelope exclusion. Global RMW stamps anchor original source brackets.
pub const ScanIntervals = struct {
    const Identity = struct { role: format.Role, index: u64, generation: u64 };
    const Scan = enum { worker_jobs, acceptance_jobs, scheduler_prepare, scheduler_reconcile, scheduler_acquire, render_consumed };
    const Publication = enum { queued, completed, published, acquired, phase, terminal, receipt, cancelled, slot_open, slot_close };
    scans: [6]?Identity = @splat(null),
    publications: [3][10]?Identity = @splat(@splat(null)),
    operations: [3]?Cut = @splat(null),
    allow_unresolved_job_reads: bool = false,
    unresolved_scalar_overlaps: u64 = 0,
    fn scalarOverlap(self: *ScanIntervals, read_cut: Cut) Error!void {
        if (!self.allow_unresolved_job_reads or (read_cut.site != .service_worker_scan and read_cut.site != .service_acceptance_scan)) return error.CrossedScan;
        self.unresolved_scalar_overlaps = std.math.add(u64, self.unresolved_scalar_overlaps, 1) catch return error.CounterOverflow;
    }
    fn scalarConflict(read_cut: Cut, publication_kind: Publication, identity: Identity) bool {
        if (read_cut.index != identity.index) return false;
        return switch (read_cut.site) {
            .service_worker_scan => identity.role == .control and publication_kind == .queued,
            .service_acceptance_scan => identity.role == .worker and publication_kind == .completed,
            .service_slot_guard_render_claim, .service_slot_guard_render_release => identity.role == .control and (publication_kind == .slot_open or publication_kind == .slot_close),
            else => false,
        };
    }
    fn operation(self: *ScanIntervals, value: Cut) Error!void {
        const active = &self.operations[@intFromEnum(value.role)];
        const expected: format.Role = switch (value.site) {
            .service_worker_scan => .worker,
            .service_acceptance_scan => .control,
            else => .render,
        };
        try expectRole(value.role, expected);
        if (value.edge == .before) {
            if (active.* != null) return error.InvalidOrder;
            for (self.publications, 0..) |publications, role| for (publications, 0..) |publication_value, p| {
                if (publication_value) |identity| {
                    if (identity.role != @as(format.Role, @enumFromInt(role))) return error.InvalidOrder;
                    if (scalarConflict(value, @enumFromInt(p), identity)) try self.scalarOverlap(value);
                }
            };
            active.* = value;
        } else {
            var expected_end = active.* orelse return error.InvalidOrder;
            expected_end.edge = .after;
            if (!std.meta.eql(expected_end, value)) return error.InvalidOrder;
            active.* = null;
        }
    }
    fn pair(slot: *?Identity, edge: cuts.Edge, identity: Identity) Error!void {
        switch (edge) {
            .before => {
                if (slot.* != null) return error.InvalidOrder;
                slot.* = identity;
            },
            .after => {
                if (slot.* == null or !std.meta.eql(slot.*.?, identity)) return error.InvalidOrder;
                slot.* = null;
            },
        }
    }
    fn conflict(scan_kind: Scan, publication_kind: Publication, role: format.Role) bool {
        return switch (scan_kind) {
            .worker_jobs, .acceptance_jobs, .render_consumed => false,
            .scheduler_acquire => role == .control and publication_kind == .published,
            .scheduler_prepare, .scheduler_reconcile => role == .render and switch (publication_kind) {
                .acquired, .phase, .terminal, .receipt, .cancelled => true,
                else => false,
            },
        };
    }
    fn scan(self: *ScanIntervals, kind: Scan, edge: cuts.Edge, identity: Identity) Error!void {
        const expected: format.Role = switch (kind) {
            .worker_jobs => .worker,
            .scheduler_acquire, .render_consumed => .render,
            else => .control,
        };
        if (identity.role != expected) return error.InvalidOrder;
        if (edge == .before) {
            for (self.publications, 0..) |publications, role| for (publications, 0..) |active, p| {
                if (active != null and conflict(kind, @enumFromInt(p), @enumFromInt(role))) return error.CrossedScan;
            };
        }
        try pair(&self.scans[@intFromEnum(kind)], edge, identity);
    }
    fn publication(self: *ScanIntervals, kind: Publication, edge: cuts.Edge, identity: Identity) Error!void {
        if (identity.role == .worker and kind != .completed) return error.InvalidOrder;
        switch (kind) {
            .queued, .published, .slot_open, .slot_close => try expectRole(identity.role, .control),
            .completed => try expectRole(identity.role, .worker),
            .acquired, .phase => try expectRole(identity.role, .render),
            else => {},
        }
        if (edge == .before) for (self.scans, 0..) |active, s| {
            if (active != null and conflict(@enumFromInt(s), kind, identity.role)) return error.CrossedScan;
        };
        if (edge == .before) for (self.operations) |active| if (active) |value| {
            if (scalarConflict(value, kind, identity)) try self.scalarOverlap(value);
        };
        try pair(&self.publications[@intFromEnum(identity.role)][@intFromEnum(kind)], edge, identity);
    }
    pub fn point(self: *ScanIntervals, value: Cut) Error!void {
        _ = try nativeRole(value.role);
        switch (value.site) {
            .service_worker_scan, .service_acceptance_scan, .service_slot_guard_render_claim, .service_slot_guard_render_release => return self.operation(value),
            else => {},
        }
        const kind: Publication = switch (value.site) {
            .service_job_queued => .queued,
            .service_worker_completed => .completed,
            .scheduler_publication => .published,
            .scheduler_acquired => .acquired,
            .scheduler_phase => .phase,
            .scheduler_terminal => .terminal,
            .scheduler_receipt => .receipt,
            .service_slot_guard_open => .slot_open,
            .service_slot_guard_close => .slot_close,
            else => return,
        };
        try self.publication(kind, value.edge, .{ .role = value.role, .index = value.index, .generation = value.generation });
    }
    pub fn boundary(self: *ScanIntervals, value: Boundary) Error!void {
        _ = try nativeRole(value.role);
        const identity: Identity = .{ .role = value.role, .index = value.index, .generation = value.generation };
        const kind: Scan = switch (value.site) {
            .service_worker_scan => .worker_jobs,
            .service_acceptance_scan => .acceptance_jobs,
            .scheduler_prepare_scan => .scheduler_prepare,
            .scheduler_reconcile_scan => .scheduler_reconcile,
            .scheduler_acquire_scan => .scheduler_acquire,
            .service_render_consumed_prefix => .render_consumed,
            .scheduler_plan_cancel_release => return self.publication(.cancelled, value.edge, identity),
            else => return,
        };
        try self.scan(kind, value.edge, identity);
    }
    pub fn finish(self: *const ScanIntervals) Error!void {
        for (self.scans) |active| if (active != null) return error.Incomplete;
        for (self.operations) |active| if (active != null) return error.Incomplete;
        for (self.publications) |publications| for (publications) |active| if (active != null) return error.Incomplete;
    }
};

test "semantic scheduler scan preflight rejects publication crossings" {
    const t = std.testing;
    const acquire: Boundary = .{ .role = .render, .site = .scheduler_acquire_scan, .edge = .before, .index = 2, .generation = 256 };
    const published: Cut = .{ .role = .control, .site = .scheduler_publication, .edge = .before, .index = 1, .generation = 3 };
    var intervals: ScanIntervals = .{};
    try intervals.boundary(acquire);
    try t.expectError(error.CrossedScan, intervals.point(published));
    intervals = .{};
    try intervals.point(published);
    try t.expectError(error.CrossedScan, intervals.boundary(acquire));
    inline for (.{ cuts.Boundary.scheduler_prepare_scan, cuts.Boundary.scheduler_reconcile_scan }) |site| {
        const scan: Boundary = .{ .role = .control, .site = site, .edge = .before, .index = 32, .generation = 0 };
        const cancellation: Boundary = .{ .role = .render, .site = .scheduler_plan_cancel_release, .edge = .before, .index = 1, .generation = 3 };
        intervals = .{};
        try intervals.boundary(scan);
        try t.expectError(error.CrossedScan, intervals.boundary(cancellation));
        intervals = .{};
        try intervals.boundary(cancellation);
        try t.expectError(error.CrossedScan, intervals.boundary(scan));
        inline for (.{ cuts.Site.scheduler_acquired, cuts.Site.scheduler_phase, cuts.Site.scheduler_terminal, cuts.Site.scheduler_receipt }) |publication_site| {
            const release: Cut = .{ .role = .render, .site = publication_site, .edge = .before, .index = 1, .generation = 3 };
            intervals = .{};
            try intervals.boundary(scan);
            try t.expectError(error.CrossedScan, intervals.point(release));
            intervals = .{};
            try intervals.point(release);
            try t.expectError(error.CrossedScan, intervals.boundary(scan));
        }
    }
}

test "semantic stable IDs roundtrip while finite enum vocabularies stay closed" {
    const t = std.testing;
    var bytes: [8192]u8 = undefined;
    const identity: semantic.Identity = .{
        .epoch = 1,
        .document_id = 19,
        .revision = 7,
        .draft_hash = @splat(1),
        .artifact_hash = @splat(2),
        .state = @enumFromInt(0xa102030405060708),
    };
    const started: Native(semantic.ControlEvent) = .{
        .occurrence = 1,
        .value = .{ .started = .{ .thread = 999, .identity = identity, .config = .{}, .device = .{} } },
    };
    const reference = try encode(canonicalNative(semantic.ControlEvent, started), .reference, &bytes);
    try validateReference(.{ .role = .control, .ordinal = 1, .family = @intFromEnum(Family.control_event), .bytes = reference });
    const command: Native(?semantic.Command) = .{
        .occurrence = 2,
        .value = .{ .id = 1, .identity = identity, .kind = .play, .slot = 0, .device_epoch = 0 },
    };
    const command_reference = try encode(command, .reference, &bytes);
    try validateReference(.{ .role = .control, .ordinal = 2, .family = @intFromEnum(Family.command_dequeued), .bytes = command_reference });
    const decoded = try decode(Native(?semantic.Command), command_reference);
    try t.expectEqual(@intFromEnum(identity.state), @intFromEnum(decoded.value.?.identity.state));
    try t.expectError(error.UnsupportedFamily, decodeInput(?semantic.Command, .{ .role = .control, .ordinal = 2, .family = @intFromEnum(Family.command_dequeued), .bytes = command_reference }, .command_dequeued));
    const Open = enum(u8) { named = 0, _ };
    const open = try encode(@as(Open, @enumFromInt(255)), .input, &bytes);
    try t.expectEqual(@as(u8, 255), @intFromEnum(try decode(Open, open)));
    var wire: format.Encoder = .{ .bytes = &bytes };
    try wire.int(u64, 256);
    try t.expectError(error.InvalidEnum, decode(Open, wire.result()));
    const Closed = enum(u8) { only = 0 };
    try t.expectError(error.InvalidEnum, decode(Closed, wire.result()));
    try t.expectError(error.ErrorInput, encode(@as(anyerror, error.UnsupportedValue), .input, &bytes));
    try t.expectError(error.BorrowedValue, encode(@as([]const u8, "borrowed"), .input, &bytes));
}
