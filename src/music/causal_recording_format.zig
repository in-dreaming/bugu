//! Public bounded direct-host causal envelope. No serial profile is extended.
//! Scalar field order is wire order. Exhaustive enum/union tags use LE u32;
//! nonexhaustive numeric identities retain their declared width. trace.Input
//! and ScheduleEntry retain their existing canonical scalar encoding.
//! Completion below is STRUCTURAL only: neither EOF nor a digest certifies
//! causal replay, original provenance, writer return/join, sync or publication.
const std = @import("std");
const trace = @import("sme-trace");
const schema = trace.schema;
const legacy_codec = trace.codec;
const rt = @import("bugu_audio").runtime;
const v1 = @import("runtime_contract.zig");
const contract = @import("contract.zig");
pub const frontier = rt.control_frontier_witness;
pub const acceptance = rt.stream_acceptance_witness;
pub const readiness = rt.readiness_witness;
pub const render = rt.render_causal_witness;
pub const WorkerFact = rt.streaming.stream.WorkerFact;
pub const ServiceExclusion = rt.streaming.stream.ServiceExclusion;
pub const ServiceClaimKind = rt.streaming.stream.ServiceClaimKind;
pub const ServiceClaimAttempt = rt.streaming.stream.ServiceClaimAttempt;
pub const ServiceWorkerRelease = rt.streaming.stream.ServiceWorkerRelease;
pub const QueueObservation = trace.QueueObservation;
pub const group_event_capacity: u64 = trace.schema.default_ring_capacity;
pub const group_event_epoch: u64 = 1;
pub const consumed_slots = rt.streaming.stream.consumed_slots;
pub const ConsumedRange = rt.streaming.stream.ConsumedRange;
pub const Hash = [32]u8;
pub const version: u16 = 1;
pub const profile: u16 = 5;
pub const partitioned_recording_profile: u16 = 6;
/// Resource selection is injected into this artifact's canonical music
/// module. It must not depend on a declaration in another module's root.
pub const ResourceProfile = enum { baseline256, partitioned544 };
pub const compiled_resource_profile: ResourceProfile = switch (@import("sme-causal-resource-options").resource_profile) {
    .baseline256 => .baseline256,
    .partitioned544 => .partitioned544,
};
pub const magic = "SMECAU01";
pub const page_bytes: usize = 64 * 1024;
pub const max_file_bytes: u64 = 64 * 1024 * 1024;
pub const max_producer_events: u32 = 65_536;
/// Independent public-operation bound; replay stores at most this many keys
/// per role. Existing four witness producers retain their 65,536-event limit.
pub const max_operations_per_role: u32 = 4096;
/// Profile 5's direct Render-call eligibility bound, not the engine quantum or
/// PCM storage capacity. Existing witness profiles keep their own bounds.
pub const max_recordable_render_frames: u32 = 64;
pub const max_render_progress_per_call: u32 = 256;
pub const max_pcm_frames: u32 = 4096;
/// Local-table and legacy-default bound. Do not scale nested local arrays with
/// the extended total credit budget.
pub const max_dependencies: u32 = 256;
pub const default_pending_dependencies: u32 = 256;
pub const partitioned_pending_dependencies: u32 = 544;
pub const supported_pending_dependencies: u32 = switch (compiled_resource_profile) {
    .baseline256 => default_pending_dependencies,
    .partitioned544 => partitioned_pending_dependencies,
};
pub const Error = error{ BufferTooSmall, Truncated, InvalidEnum, InvalidBoolean, TrailingBytes, InvalidLength, InvalidHeader, UnknownVersion, InvalidLimits, InvalidRecord, InvalidOrder, StaleIdentity, HashMismatch, ByteBudget, WorkBudget, EventBudget, MissingTerminal, DuplicateTerminal, Incomplete, UnsupportedOperation, InvalidPcm, ProofBindingMismatch };
pub const Limits = struct {
    file_bytes: u64 = max_file_bytes,
    producer_events: u32 = max_producer_events,
    operations_per_role: u32 = max_operations_per_role,
    parser_steps: u64 = max_file_bytes,
    checkpoint_steps: u64 = 1024 * 1024,
    pending_dependencies: u32 = default_pending_dependencies,
    max_pcm_frames: u32 = 4096,
    /// Explicit runtime opt-in, independent of the compiled storage profile.
    pub fn forResourceProfile(resource_profile: ResourceProfile) Error!Limits {
        const limits: Limits = .{ .pending_dependencies = switch (resource_profile) {
            .baseline256 => default_pending_dependencies,
            .partitioned544 => partitioned_pending_dependencies,
        } };
        try limits.validate();
        return limits;
    }
    pub fn validate(self: Limits) Error!void {
        if (self.file_bytes == 0 or self.file_bytes > max_file_bytes or self.producer_events == 0 or self.producer_events > max_producer_events or self.operations_per_role == 0 or self.operations_per_role > max_operations_per_role or self.parser_steps == 0 or self.parser_steps > max_file_bytes or self.checkpoint_steps == 0 or self.checkpoint_steps > max_file_bytes or self.pending_dependencies == 0 or (self.pending_dependencies > default_pending_dependencies and (compiled_resource_profile != .partitioned544 or self.pending_dependencies != partitioned_pending_dependencies)) or self.max_pcm_frames == 0 or self.max_pcm_frames > 4096) return error.InvalidLimits;
    }
};
/// The header binds the named resource contract without adding wire fields or
/// changing rules-version grammar. Older profile-5 readers reject profile 6.
pub fn recordingProfileForLimits(limits: Limits) Error!u16 {
    try limits.validate();
    return if (limits.pending_dependencies <= default_pending_dependencies) profile else partitioned_recording_profile;
}
pub const SessionIdentity = struct { incarnation: u64, interval_id: u64 };
pub const ProducerIdentity = render.ControlSession;
pub const Bindings = struct {
    frontier: ProducerIdentity,
    acceptance: ProducerIdentity,
    readiness: ProducerIdentity,
    render: ProducerIdentity,
    readiness_manifest: readiness.Manifest,
    render_manifest: render.Manifest,
};
pub const Identity = struct {
    compiler_version: u32,
    algorithm_version: u32,
    bank_content_hash: Hash,
    bank_profile: u64,
    seed: u64,
    initial_state_hash: Hash,
    sample_rate: u32,
    quantum_frames: u32,
    bank_major: u16,
    bank_minor: u16,
    bank_build_id: u64,
    generation: u64,
    capacity_profile_hash: Hash,
    source_set_hash: Hash,
    service_profile_hash: Hash,
    context: u64,
    channels: u16 = 2,
    rules_version: u16 = 1,
    field_classification_version: u16 = 1,
    pub fn validate(self: Identity) Error!void {
        if (self.compiler_version == 0 or self.algorithm_version == 0 or self.bank_profile == 0 or self.sample_rate == 0 or self.quantum_frames == 0 or self.quantum_frames > max_pcm_frames or self.bank_major == 0 or self.bank_build_id == 0 or self.generation == 0 or self.context == 0 or self.channels != 2) return error.InvalidHeader;
        if ((self.rules_version != 1 and self.rules_version != 2) or self.field_classification_version != 1) return error.UnknownVersion;
        inline for (.{ "bank_content_hash", "initial_state_hash", "capacity_profile_hash", "source_set_hash", "service_profile_hash" }) |field| if (zero(@field(self, field))) return error.InvalidHeader;
    }
};
pub const Header = struct {
    magic: [8]u8 = "SMECAU01".*,
    version: u16 = 1,
    recording_profile: u16 = 5,
    identity: Identity,
    session: SessionIdentity,
    limits: Limits = .{},
    bindings: Bindings,
    pub fn validate(self: Header) Error!void {
        if (!std.mem.eql(u8, &self.magic, "SMECAU01")) return error.InvalidHeader;
        if (self.version != 1 or (self.recording_profile != profile and
            (compiled_resource_profile != .partitioned544 or self.recording_profile != partitioned_recording_profile))) return error.UnknownVersion;
        try self.identity.validate();
        try self.limits.validate();
        if (self.recording_profile != try recordingProfileForLimits(self.limits)) return error.InvalidLimits;
        if (self.identity.quantum_frames > self.limits.max_pcm_frames or self.session.incarnation == 0 or self.session.interval_id == 0) return error.InvalidHeader;
        inline for (.{ "frontier", "acceptance", "readiness", "render" }) |field| {
            const p = @field(self.bindings, field);
            if (p.incarnation == 0 or p.generation == 0 or p.owner_identity == 0 or p.interval_id != self.session.interval_id) return error.StaleIdentity;
        }
        const r = self.bindings.render_manifest;
        const q = self.bindings.readiness_manifest;
        if (r.music_handle_incarnation == 0 or q.music_handle_incarnation != r.music_handle_incarnation) return error.StaleIdentity;
        if (r.interval_id != self.session.interval_id or q.interval_id != self.session.interval_id or r.renderer_identity != self.bindings.render.owner_identity or q.renderer_identity != r.renderer_identity or q.render_incarnation != self.bindings.render.incarnation or q.render_generation != self.bindings.render.generation or r.music_context != self.identity.context or q.music_context != self.identity.context or r.sample_rate != self.identity.sample_rate or r.channels != self.identity.channels or r.asset_generation != self.identity.generation or q.asset_generation != self.identity.generation or !equal(q.bank_hash, self.identity.bank_content_hash) or !equal(q.profile_hash, self.identity.service_profile_hash) or !std.meta.eql(r.control_frontier, self.bindings.frontier) or !std.meta.eql(q.control_frontier, self.bindings.frontier) or !std.meta.eql(r.stream_acceptance, self.bindings.acceptance) or !std.meta.eql(q.stream_acceptance, self.bindings.acceptance)) return error.StaleIdentity;
    }
};
pub const Role = enum(u8) { control = 0, render = 1, worker = 2 };
pub const OperationKey = struct { role: Role, ordinal: u64 };
pub const OperationArgs = union(enum(u16)) {
    submit: struct { bank: v1.BankRefV1, request: schema.RequestPayload },
    tick: u32,
    poll_receipt: void,
    render: struct { frames: u32, channels: u16 },
    worker_one: void,
    retire_sources: void,
    poll_phase_receipt: void,
};
pub const OperationBegin = struct { key: OperationKey, args: OperationArgs };
pub const RenderResult = struct { frame_begin: u64, frame_end: u64, call_sequence_begin: u64, call_sequence_end: u64, completed: bool };
pub const TickResult = struct { processed: u32, control_tick: u64, frontier_tick_serial: u64 };
pub const TickFailure = struct { failure: v1.FailureV1, control_tick: u64, frontier_tick_serial: u64 };
/// Profile 5 observation classifications; each allowed cause is proved separately.
pub const ObservedError = enum(u32) { none = 0, invalid_state = 1, drain_pending = 2 };
pub const observed_invalid_state: u32 = @intFromEnum(ObservedError.invalid_state);
pub const observed_drain_pending: u32 = @intFromEnum(ObservedError.drain_pending);
pub const WorkerResult = struct { worked: bool, closed_source: ?u64 = null, unbound: bool = false, retirement_acknowledged: bool = false };
pub const OperationResult = union(enum(u16)) { failed: v1.FailureV1, submitted: v1.RequestTicketV1, ticked: TickResult, receipt: ?v1.ReceiptV1, rendered: RenderResult, worked: WorkerResult, retirement_requested: void, phase_receipt: ?contract.PhaseReceipt, tick_failed: TickFailure };
pub const OperationEnd = struct { key: OperationKey, result: OperationResult };
pub const PcmBlock = struct { key: OperationKey, frames: u32, channels: u16, digest: Hash };
pub const Record = union(enum(u16)) {
    begin: OperationBegin,
    end: OperationEnd,
    input: struct { key: OperationKey, value: schema.Input },
    schedule: struct { key: OperationKey, value: schema.ScheduleEntry },
    worker: struct { key: OperationKey, value: WorkerFact },
    frontier: frontier.Event,
    acceptance: acceptance.Event,
    readiness: readiness.Event,
    render: render.Event,
    frontier_terminal: frontier.Terminal,
    acceptance_terminal: acceptance.Terminal,
    readiness_terminal: readiness.Terminal,
    render_terminal: render.Terminal,
    pcm: PcmBlock,
    scheduler_publication: struct { key: OperationKey, value: rt.scheduler.CausalPublication },
    scheduler_progress: struct { key: OperationKey, value: rt.scheduler.CausalProgress },
    group_terminal: struct { key: OperationKey, value: rt.music_group.Terminal },
    // Append-only profile-5 tag; shared profiles 2/3/4 witness codecs stay fixed.
    service_exclusion: struct { key: OperationKey, value: ServiceExclusion },
    group_source_final: struct { key: OperationKey, value: rt.GroupSourceFinal },
    group_event_queue: struct { key: OperationKey, epoch: u64, observation: QueueObservation },
    group_event_queue_terminal: struct { epoch: u64, head: u64, tail: u64 },
    stream_consumed_range: struct { key: OperationKey, index: u16, generation: u64, first: u64, last: u64, count: u32 },
    stream_consumed_call_end: struct { key: OperationKey, ranges: u16, publications: u32 },
    // Rules 2 only. The preceding 23 wire tags and their payloads are fixed.
    service_claim: struct { key: OperationKey, value: ServiceClaimAttempt },
    service_worker_release: struct { key: OperationKey, value: ServiceWorkerRelease },
    service_release_observation: struct { key: OperationKey, token: u64, after_claims: u64 },
};

/// Pointer-free canonical witness codec. It rejects padding, invalid booleans,
/// unrecognized closed tags, noncanonical sub-byte integers and trailing bytes.
pub const Encoder = struct {
    bytes: []u8,
    offset: usize = 0,
    pub fn put(self: *Encoder, value: anytype) Error!void {
        const T = @TypeOf(value);
        if (T == schema.Input or T == schema.ScheduleEntry or T == schema.RequestPayload) {
            var e: legacy_codec.Encoder = .{ .bytes = self.bytes, .offset = self.offset };
            e.put(value) catch return error.BufferTooSmall;
            self.offset = e.offset;
            return;
        }
        switch (@typeInfo(T)) {
            .int => |info| {
                const width = (info.bits + 7) / 8;
                const U = std.meta.Int(.unsigned, width * 8);
                const Bits = std.meta.Int(.unsigned, info.bits);
                if (self.offset > self.bytes.len or width > self.bytes.len - self.offset) return error.BufferTooSmall;
                std.mem.writeInt(U, self.bytes[self.offset..][0..width], @as(U, @as(Bits, @bitCast(value))), .little);
                self.offset += width;
            },
            .bool => try self.put(@as(u8, @intFromBool(value))),
            .@"enum" => |info| if (info.is_exhaustive) try self.put(@as(u32, @intCast(@intFromEnum(value)))) else try self.put(@as(info.tag_type, @intFromEnum(value))),
            .array => for (value) |v| try self.put(v),
            .@"struct" => |info| inline for (info.fields) |field| try self.put(@field(value, field.name)),
            .optional => {
                try self.put(value != null);
                if (value) |v| try self.put(v);
            },
            .@"union" => |info| {
                const tag = std.meta.activeTag(value);
                try self.put(tag);
                inline for (info.fields) |field| if (std.mem.eql(u8, @tagName(tag), field.name)) try self.put(@field(value, field.name));
            },
            .void => {},
            else => @compileError("Noncanonical causal value: " ++ @typeName(T)),
        }
    }
};
pub const Decoder = struct {
    bytes: []const u8,
    offset: usize = 0,
    pub fn get(self: *Decoder, comptime T: type) Error!T {
        if (T == schema.Input or T == schema.ScheduleEntry or T == schema.RequestPayload) {
            var d: legacy_codec.Decoder = .{ .bytes = self.bytes, .offset = self.offset };
            const value = d.get(T) catch |err| return switch (err) {
                error.Truncated => error.Truncated,
                error.InvalidBoolean => error.InvalidBoolean,
                error.InvalidEnum => error.InvalidEnum,
                else => error.InvalidRecord,
            };
            self.offset = d.offset;
            return value;
        }
        return switch (@typeInfo(T)) {
            .int => |info| blk: {
                const width = (info.bits + 7) / 8;
                const U = std.meta.Int(.unsigned, width * 8);
                const Bits = std.meta.Int(.unsigned, info.bits);
                if (self.offset > self.bytes.len or width > self.bytes.len - self.offset) return error.Truncated;
                const raw = std.mem.readInt(U, self.bytes[self.offset..][0..width], .little);
                self.offset += width;
                const bits = std.math.cast(Bits, raw) orelse return error.InvalidRecord;
                break :blk @bitCast(bits);
            },
            .bool => switch (try self.get(u8)) {
                0 => false,
                1 => true,
                else => error.InvalidBoolean,
            },
            .@"enum" => |info| blk: {
                if (!info.is_exhaustive) break :blk @enumFromInt(try self.get(info.tag_type));
                const raw = try self.get(u32);
                inline for (info.fields) |field| if (raw == field.value) break :blk @enumFromInt(raw);
                return error.InvalidEnum;
            },
            .array => |info| blk: {
                var value: T = undefined;
                for (&value) |*item| item.* = try self.get(info.child);
                break :blk value;
            },
            .@"struct" => |info| blk: {
                var value: T = undefined;
                inline for (info.fields) |field| @field(value, field.name) = try self.get(field.type);
                break :blk value;
            },
            .optional => |info| if (try self.get(bool)) try self.get(info.child) else null,
            .@"union" => |info| blk: {
                const tag = try self.get(info.tag_type.?);
                inline for (info.fields) |field| if (std.mem.eql(u8, @tagName(tag), field.name)) break :blk @unionInit(T, field.name, try self.get(field.type));
                return error.InvalidEnum;
            },
            .void => {},
            else => @compileError("Noncanonical causal value: " ++ @typeName(T)),
        };
    }
    pub fn finish(self: Decoder) Error!void {
        if (self.offset != self.bytes.len) return error.TrailingBytes;
    }
};
pub fn maxSize(comptime T: type) usize {
    @setEvalBranchQuota(100_000);
    if (T == schema.Input or T == schema.ScheduleEntry or T == schema.RequestPayload) return legacy_codec.maxSize(T);
    return switch (@typeInfo(T)) {
        .int => |i| (i.bits + 7) / 8,
        .bool => 1,
        .@"enum" => |e| if (e.is_exhaustive) 4 else maxSize(e.tag_type),
        .array => |a| a.len * maxSize(a.child),
        .@"struct" => |s| blk: {
            var n: usize = 0;
            inline for (s.fields) |f| n += maxSize(f.type);
            break :blk n;
        },
        .optional => |o| 1 + maxSize(o.child),
        .@"union" => |u| blk: {
            var n: usize = 0;
            inline for (u.fields) |f| n = @max(n, maxSize(f.type));
            break :blk maxSize(u.tag_type.?) + n;
        },
        .void => 0,
        else => @compileError("Noncanonical causal value"),
    };
}
pub fn zero(h: Hash) bool {
    return std.mem.allEqual(u8, &h, 0);
}
pub fn equal(a: Hash, b: Hash) bool {
    return std.mem.eql(u8, &a, &b);
}
pub fn hashBytes(domain: []const u8, bytes: []const u8) Hash {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(domain);
    h.update(bytes);
    var out: Hash = undefined;
    h.final(&out);
    return out;
}
pub fn hashValue(domain: []const u8, value: anytype) Error!Hash {
    var bytes: [maxSize(@TypeOf(value))]u8 = undefined;
    var e: Encoder = .{ .bytes = &bytes };
    try e.put(value);
    return hashBytes(domain, bytes[0..e.offset]);
}
pub const header_bytes = maxSize(Header);
pub const max_record_bytes = 4 + maxSize(Record);
pub fn encodeHeader(header: Header, bytes: []u8) Error![]const u8 {
    try header.validate();
    var e: Encoder = .{ .bytes = bytes };
    try e.put(header);
    return bytes[0..e.offset];
}
pub fn decodeHeader(bytes: []const u8) Error!Header {
    var d: Decoder = .{ .bytes = bytes };
    const h = try d.get(Header);
    try d.finish();
    try h.validate();
    return h;
}
pub fn encodeRecord(record: Record, bytes: []u8) Error![]const u8 {
    if (bytes.len < 4) return error.BufferTooSmall;
    var e: Encoder = .{ .bytes = bytes, .offset = 4 };
    try e.put(record);
    std.mem.writeInt(u32, bytes[0..4], @intCast(e.offset - 4), .little);
    return bytes[0..e.offset];
}
pub fn decodeRecord(bytes: []const u8) Error!Record {
    if (bytes.len < 4) return error.Truncated;
    const n = std.mem.readInt(u32, bytes[0..4], .little);
    if (n == 0 or n > max_record_bytes - 4 or n != bytes.len - 4) return error.InvalidLength;
    var d: Decoder = .{ .bytes = bytes[4..] };
    const r = try d.get(Record);
    try d.finish();
    return r;
}

// Runtime-local anyerror ordinals are never stable public failure semantics.
// Only explicitly recognized observation paths may carry a stable nonzero
// classification. All remaining runtime-local ordinals fail closed.
fn rejectUnsupportedErrorCodes(value: anytype) Error!void {
    switch (@typeInfo(@TypeOf(value))) {
        .@"struct" => |info| inline for (info.fields) |field| {
            if (comptime std.mem.eql(u8, field.name, "error_code") or std.mem.eql(u8, field.name, "last_error_code") or std.mem.eql(u8, field.name, "service_error")) {
                if (@field(value, field.name) != 0) return error.UnsupportedOperation;
            } else try rejectUnsupportedErrorCodes(@field(value, field.name));
        },
        .@"union" => |info| {
            const tag = std.meta.activeTag(value);
            inline for (info.fields) |field| if (std.mem.eql(u8, @tagName(tag), field.name)) try rejectUnsupportedErrorCodes(@field(value, field.name));
        },
        .optional => if (value) |v| try rejectUnsupportedErrorCodes(v),
        .array => for (value) |v| try rejectUnsupportedErrorCodes(v),
        else => {},
    }
}

/// Structural candidate for an interrupted availability check. Causal
/// validation must independently bind every reached value to real Render
/// evidence. This never approves a tick or supplies a missing read.
pub fn availabilityChanged(supply: readiness.observation.SupplyRead) bool {
    const a = supply.availability;
    if (supply.error_code != observed_invalid_state or !availabilityPrefixChanged(a)) return false;
    var expected: u64 = readiness.observation.bit(.availability_sequence);
    if (a.frame != null) expected |= readiness.observation.bit(.availability_frame);
    if (a.consumed != null) expected |= readiness.observation.bit(.availability_consumed);
    if (a.produced != null) expected |= readiness.observation.bit(.availability_produced);
    if (a.sequence_after != null) expected |= readiness.observation.bit(.availability_after);
    switch (supply.kind) {
        .prefetch => if (a.requested_frame == null) return false,
        .request => {
            if (a.requested_frame != null) return false;
            expected |= readiness.observation.bit(.request_cancel) | readiness.observation.bit(.request_stopped) | readiness.observation.bit(.request_failed) | readiness.observation.bit(.request_pending);
        },
    }
    if (supply.reached != expected or supply.cancel or supply.stopped or supply.failure_code != 0 or supply.pending_job != null or supply.ordinal != 0 or supply.job_slot != null or supply.descriptor != null or supply.count != 0 or supply.result_job != null or supply.invokes_request) return false;
    return true;
}
fn availabilityPrefixChanged(a: acceptance.observation.Availability) bool {
    if (a.error_code != observed_invalid_state or !a.attached or a.available != null) return false;
    const before = a.sequence_before orelse return false;
    if (before & 1 != 0) return a.frame == null and a.consumed == null and a.produced == null and a.sequence_after == null;
    const frame = a.frame orelse return false;
    if (a.requested_frame) |requested| if (frame != requested) return a.consumed == null and a.produced == null and a.sequence_after == null;
    return a.consumed != null and a.produced != null and a.sequence_after != null and a.sequence_after.? != before;
}

/// The actual suppressed null-return branch after selecting a completed job.
/// No ownership or publication effect has occurred. This is a structural
/// candidate only; semantic validation still proves every reached atomic cut.
pub fn acceptanceAvailabilityChanged(value: acceptance.observation.Acceptance) bool {
    if (!value.runtime_attached or value.replay_mode or !value.representation_complete or value.job_slots == 0 or value.job_slots > value.states.len or value.scanned != value.job_slots or value.outcome != .availability_unavailable or value.error_code != observed_invalid_state) return false;
    if (value.availability.requested_frame == null or value.availability.requested_frame.? != value.position.accepted_control_frame or !availabilityPrefixChanged(value.availability)) return false;
    const selected = value.selected orelse return false;
    if (selected.slot >= value.scanned or selected.descriptor.job == 0 or selected.handle.generation == 0 or selected.count == 0 or value.states[selected.slot] != .completed) return false;
    const completed = value.completed[selected.slot];
    if (completed.job != selected.descriptor.job or !std.meta.eql(completed.handle, selected.handle) or completed.generation == 0 or completed.generation != selected.descriptor.generation or completed.transport_epoch != selected.descriptor.transport_epoch) return false;
    for (value.states[0..value.scanned], value.completed[0..value.scanned], 0..) |state, identity, index| {
        if (state == .completed) {
            if (identity.job == 0 or identity.handle.generation == 0 or identity.generation == 0 or identity.job < selected.descriptor.job or (identity.job == selected.descriptor.job and index != selected.slot)) return false;
        } else if (!std.meta.eql(identity, acceptance.observation.CompletedIdentity{})) return false;
    }
    inline for (.{ "ring_capacity", "publication_preflight", "publication_commit", "last_batch_id", "next_snapshot", "cancel", "stopped", "generation", "transport_epoch", "stale", "actual_worker", "coordinate", "ring_produced", "ring_writable", "publication", "accepted" }) |field| {
        if (@field(value, field) != null) return false;
    }
    if (!std.meta.eql(value.effects, acceptance.observation.Effects{}) or !std.meta.eql(value.ring_publish, @as(@TypeOf(value.ring_publish), .{}))) return false;
    return true;
}

/// Only the first group-release pin acquire may explain this DrainPending.
/// A zero mask can reach unrepresented terminal/source/layer checks, and is
/// never admitted here. Semantic validation must still prove the exact pins.
pub fn groupReleasePinsPending(value: readiness.Reconciliation) bool {
    const pins = value.pin_mask orelse return false;
    if (value.kind != .group_release or value.error_code != observed_drain_pending or value.handle.generation == 0 or value.bank_generation == 0 or pins == 0) return false;
    const expected: readiness.Reconciliation = .{
        .kind = .group_release,
        .handle = value.handle,
        .bank_generation = value.bank_generation,
        .pin_mask = pins,
        .error_code = observed_drain_pending,
    };
    return std.meta.eql(expected, value);
}

/// The reached short-circuit after zero pins/references is proved separately
/// by the validator against this release's prepared group and desired owner.
/// This shape alone supplies neither that ownership nor a release effect.
pub fn groupDesiredPending(value: readiness.Reconciliation) bool {
    if (value.kind != .group_desired or value.error_code != observed_drain_pending or value.parent_attempt == 0 or value.handle.generation == 0 or value.instance.generation == 0 or value.reservation == 0) return false;
    const expected: readiness.Reconciliation = .{
        .kind = .group_desired,
        .parent_attempt = value.parent_attempt,
        .handle = value.handle,
        .instance = value.instance,
        .reservation = value.reservation,
        .ordinal = value.ordinal,
        .start_scheduled = true,
        .desired_active = true,
        .reservation_matches = true,
        .error_code = observed_drain_pending,
    };
    return std.meta.eql(expected, value);
}

/// Only the pending-job early exit after an actual successful Worker claim.
/// The validator must still prove the full stream/job owner interval and real
/// Worker exclusion; a structural match never authorizes their reconstruction.
pub fn streamClosePendingJob(value: readiness.observation.StreamCloseRead) bool {
    if (value.error_code != observed_drain_pending or value.parent_attempt == 0 or value.handle.generation == 0 or value.pending_job == null) return false;
    const expected: readiness.observation.StreamCloseRead = .{
        .parent_attempt = value.parent_attempt,
        .handle = value.handle,
        .worker_busy = false,
        .validation = .{ .index_in_bounds = true, .occupied = true, .generation = value.handle.generation },
        .pending_job_reached = true,
        .pending_job = value.pending_job,
        .worker_idle_published = true,
        .error_code = observed_drain_pending,
    };
    return std.meta.eql(expected, value);
}

/// Only the nonzero visibility-reference exit after an empty pending-job read.
/// This is a structural candidate; semantic validation must independently prove
/// the exact reference count, stream ownership, and successful Worker exclusion.
pub fn streamCloseVisibilityPending(value: readiness.observation.StreamCloseRead) bool {
    const visibility_refs = value.visibility_refs orelse return false;
    if (value.error_code != observed_drain_pending or value.parent_attempt == 0 or value.handle.generation == 0 or visibility_refs == 0) return false;
    const expected: readiness.observation.StreamCloseRead = .{
        .parent_attempt = value.parent_attempt,
        .handle = value.handle,
        .worker_busy = false,
        .validation = .{ .index_in_bounds = true, .occupied = true, .generation = value.handle.generation },
        .pending_job_reached = true,
        .visibility_refs = visibility_refs,
        .worker_idle_published = true,
        .error_code = observed_drain_pending,
    };
    return std.meta.eql(expected, value);
}

/// Exact first-CAS early exit: no validation or later atomic was reached.
/// Rules 2 separately proves the actual held token; the shared bool stays fixed.
pub fn streamCloseBusy(value: readiness.observation.StreamCloseRead) bool {
    if (value.error_code != observed_drain_pending or value.handle.generation == 0) return false;
    const expected: readiness.observation.StreamCloseRead = .{
        .parent_attempt = value.parent_attempt,
        .handle = value.handle,
        .worker_busy = true,
        .error_code = observed_drain_pending,
    };
    return std.meta.eql(expected, value);
}

/// Token 1 is the uncaptured fallback and never identifies a captured holder.
pub fn serviceClaimRole(token: u64) ?Role {
    if (token / 4 == 0) return null;
    return switch (token % 4) {
        1 => .control,
        2 => .worker,
        else => null,
    };
}

fn stableCode(raw: u32) Error!u32 {
    if (raw == 0) return 0;
    if (raw != @intFromError(error.InvalidState)) return error.UnsupportedOperation;
    return observed_invalid_state;
}
/// Assembler-only conversion of genuine in-process observations, never used by
/// file decoding. Only the listed paths translate a dynamic Zig error ordinal.
/// All other nonzero errors remain rejected. Every reached/optional value stays
/// byte-for-byte unchanged, so validation can independently prove the cause.
pub fn normalizeRecord(raw: Record) Error!Record {
    return normalizeRecordForRules(raw, 1);
}
pub fn normalizeRecordForRules(raw: Record, rules_version: u16) Error!Record {
    if (rules_version != 1 and rules_version != 2) return error.UnknownVersion;
    var record = raw;
    switch (record) {
        .frontier => |*v| if (v.kind == .tick_close) {
            v.error_code = try stableCode(v.error_code);
        },
        .acceptance => |*v| {
            if (v.kind == .tick_close) v.error_code = try stableCode(v.error_code);
            if (v.kind == .acceptance) if (v.acceptance) |*value| {
                value.error_code = try stableCode(value.error_code);
                value.availability.error_code = try stableCode(value.availability.error_code);
            };
        },
        .frontier_terminal => |*v| {
            v.last_error_code = try stableCode(v.last_error_code);
        },
        .acceptance_terminal => |*v| {
            v.last_error_code = try stableCode(v.last_error_code);
        },
        .readiness => |*v| switch (v.payload) {
            .supply => |*supply| {
                supply.error_code = try stableCode(supply.error_code);
                supply.availability.error_code = try stableCode(supply.availability.error_code);
            },
            .tick_close => |*code| {
                code.* = try stableCode(code.*);
            },
            .reconciliation => |*value| if (value.error_code != 0) {
                if ((value.kind != .group_release and value.kind != .group_desired) or value.error_code != @intFromError(error.DrainPending)) return error.UnsupportedOperation;
                value.error_code = observed_drain_pending;
            },
            .stream_lifecycle => |*value| switch (value.*) {
                .close => |*closed| if (closed.error_code != 0) {
                    if (closed.error_code != @intFromError(error.DrainPending)) return error.UnsupportedOperation;
                    closed.error_code = observed_drain_pending;
                },
                else => {},
            },
            else => {},
        },
        else => {},
    }
    try requireCanonicalErrors(record, rules_version);
    return record;
}
fn requireCanonicalErrors(record: Record, rules_version: u16) Error!void {
    if ((record == .service_claim or record == .service_worker_release or record == .service_release_observation) and rules_version != 2) return error.UnsupportedOperation;
    var checked = record;
    switch (checked) {
        .frontier => |*v| if (v.kind == .tick_close and v.error_code != 0) {
            if (v.error_code != observed_invalid_state or v.outcome != .failed) return error.UnsupportedOperation;
            v.error_code = 0;
        },
        .acceptance => |*v| {
            if (v.kind == .tick_close and v.error_code != 0) {
                if (v.error_code != observed_invalid_state or v.outcome != .failed) return error.UnsupportedOperation;
                v.error_code = 0;
            }
            if (v.acceptance) |*value| if (value.error_code != 0 or value.availability.error_code != 0) {
                if (v.kind != .acceptance or v.phase != .accept or v.visibility != null or v.outcome != .none or v.error_code != 0 or v.exit_phase != .idle or !std.meta.eql(v.position, value.position) or v.batch_id != value.batch_id or !acceptanceAvailabilityChanged(value.*)) return error.UnsupportedOperation;
                value.error_code = 0;
                value.availability.error_code = 0;
            };
        },
        .frontier_terminal => |*v| if (v.last_error_code != 0) {
            if (v.last_error_code != observed_invalid_state or v.last_outcome != .failed) return error.UnsupportedOperation;
            v.last_error_code = 0;
        },
        .acceptance_terminal => |*v| if (v.last_error_code != 0) {
            if (v.last_error_code != observed_invalid_state or v.last_outcome != .failed) return error.UnsupportedOperation;
            v.last_error_code = 0;
        },
        .readiness => |*v| switch (v.payload) {
            .supply => |*supply| if (supply.error_code != 0 or supply.availability.error_code != 0) {
                if (!availabilityChanged(supply.*)) return error.UnsupportedOperation;
                supply.error_code = 0;
                supply.availability.error_code = 0;
            },
            .tick_close => |*code| {
                if (code.* != 0 and code.* != observed_invalid_state) return error.UnsupportedOperation;
                code.* = 0;
            },
            .reconciliation => |*value| if (value.error_code != 0) {
                if (!groupReleasePinsPending(value.*) and !groupDesiredPending(value.*)) return error.UnsupportedOperation;
                value.error_code = 0;
            },
            .stream_lifecycle => |*value| switch (value.*) {
                .close => |*closed| if (closed.error_code != 0) {
                    if (!streamClosePendingJob(closed.*) and !streamCloseVisibilityPending(closed.*) and !(rules_version == 2 and streamCloseBusy(closed.*))) return error.UnsupportedOperation;
                    closed.error_code = 0;
                },
                else => {},
            },
            else => {},
        },
        else => {},
    }
    try rejectUnsupportedErrorCodes(checked);
}

/// Incremental grammar validator. Cross-role file order is NOT a happens-before
/// relation. Causal dependency validation is a separate semantic replay pass.
pub const Cursor = struct {
    header: Header,
    operations: [3]u64 = @splat(0),
    active: [3]?OperationBegin = @splat(null),
    events: [4]u64 = @splat(0),
    failed_ticks: [2]u64 = @splat(0),
    last_tick_error: [2]u32 = @splat(0),
    closed: [4]bool = @splat(false),
    // Exact Session.appendControl/appendWorker totals, including begin/end.
    // Typed facts do not get separate quotas in either host producer lane.
    control_events: u64 = 0,
    worker_events: u64 = 0,
    worker_facts: u64 = 0,
    service_exclusion_facts: u64 = 0,
    service_claim_facts: u64 = 0,
    service_claim_ordinals: [3]u64 = @splat(0),
    worker_release_facts: u64 = 0,
    release_observations: u64 = 0,
    worker_release_operation: u64 = 0,
    control_release_operation: u64 = 0,
    control_release_token: u64 = 0,
    progress_facts: u64 = 0,
    last_progress_ordinal: u64 = 0,
    progress_in_call: u32 = 0,
    consumed_calls: u64 = 0,
    consumed_range_mask: u64 = 0,
    consumed_range_count: u16 = 0,
    consumed_publications: u32 = 0,
    records: u64 = 0,
    steps: u64 = 0,
    pcm_frames: u64 = 0,
    pcm_calls: u64 = 0,
    rendered_calls: u64 = 0,
    last_pcm_ordinal: u64 = 0,
    // The assembler emits each role-local Render begin/end/PCM triplet before
    // the next Render begin. Other role/witness records may freely interleave.
    // This single fixed slot binds PCM to the actual successful call, not totals.
    pending_pcm: ?struct { key: OperationKey, frames: u32, channels: u16 } = null,
    group_event_head: u64 = 0,
    group_event_tail: u64 = 0,
    group_event_closed: bool = false,
    failed: bool = false,
    pub fn init(header: Header) Error!Cursor {
        try header.validate();
        return .{ .header = header };
    }
    fn charge(self: *Cursor) Error!void {
        if (self.failed) return error.Incomplete;
        if (self.steps == self.header.limits.parser_steps) return error.WorkBudget;
        self.steps += 1;
    }
    fn requireKey(self: *Cursor, key: OperationKey) Error!OperationBegin {
        const begin = self.active[@intFromEnum(key.role)] orelse return error.InvalidOrder;
        if (!std.meta.eql(begin.key, key)) return error.InvalidOrder;
        return begin;
    }
    fn hostEvent(self: *Cursor, record: Record) Error!void {
        const role: Role = switch (record) {
            .begin => |value| value.key.role,
            .end => |value| value.key.role,
            .input, .schedule, .scheduler_publication, .group_source_final => .control,
            .worker => .worker,
            .service_exclusion => |value| value.key.role,
            .service_claim => |value| value.key.role,
            .service_worker_release => .worker,
            .service_release_observation => .control,
            .group_event_queue => |value| value.key.role,
            else => return,
        };
        const count = switch (role) {
            .control => &self.control_events,
            .worker => &self.worker_events,
            // Render begin/end/PCM use their existing RenderCell contract.
            .render => return,
        };
        if (count.* >= self.header.limits.producer_events) return error.EventBudget;
        count.* += 1;
    }
    fn renderProgressKey(self: *Cursor, key: OperationKey) Error!void {
        if (key.role != .render or key.ordinal == 0 or key.ordinal > self.header.limits.operations_per_role or key.ordinal < self.last_progress_ordinal) return error.InvalidRecord;
        if (key.ordinal <= self.consumed_calls) return error.InvalidOrder;
        if (key.ordinal != self.last_progress_ordinal) self.progress_in_call = 0;
        if (self.progress_in_call == max_render_progress_per_call) return error.EventBudget;
        if (self.progress_facts == self.header.limits.producer_events) return error.EventBudget;
        self.progress_facts += 1;
        self.progress_in_call += 1;
        self.last_progress_ordinal = key.ordinal;
    }
    fn event(self: *Cursor, index: usize, value: anytype) Error!void {
        const p = switch (index) {
            0 => self.header.bindings.frontier,
            1 => self.header.bindings.acceptance,
            2 => self.header.bindings.readiness,
            3 => self.header.bindings.render,
            else => unreachable,
        };
        if (self.closed[index] or value.sequence != self.events[index] + 1) return error.InvalidOrder;
        if (value.incarnation != p.incarnation or value.generation != p.generation) return error.StaleIdentity;
        if (@hasField(@TypeOf(value), "owner_identity")) if (value.owner_identity != p.owner_identity or value.interval_id != p.interval_id) return error.StaleIdentity;
        if (@hasField(@TypeOf(value), "key")) if (value.key.interval_id != p.interval_id) return error.StaleIdentity;
        if (self.events[index] == self.header.limits.producer_events) return error.EventBudget;
        if (comptime @TypeOf(value) == frontier.Event or @TypeOf(value) == acceptance.Event) {
            if (value.kind == .tick_close) {
                if ((value.error_code == observed_invalid_state) != (value.outcome == .failed)) return error.InvalidRecord;
                if (value.error_code != 0) self.failed_ticks[index] += 1;
                self.last_tick_error[index] = value.error_code;
            }
        }
        self.events[index] += 1;
    }
    fn terminal(self: *Cursor, index: usize, value: anytype) Error!void {
        if (self.closed[index]) return error.DuplicateTerminal;
        const p = switch (index) {
            0 => self.header.bindings.frontier,
            1 => self.header.bindings.acceptance,
            2 => self.header.bindings.readiness,
            3 => self.header.bindings.render,
            else => unreachable,
        };
        if (value.incarnation != p.incarnation or value.generation != p.generation) return error.StaleIdentity;
        if (@hasField(@TypeOf(value), "owner_identity")) if (value.owner_identity != p.owner_identity or value.interval_id != p.interval_id) return error.StaleIdentity;
        if (value.incomplete or value.failure != .none or value.events_attempted != value.events_published or value.events_published != self.events[index]) return error.Incomplete;
        if (@hasField(@TypeOf(value), "dropped_events")) if (value.dropped_events != 0) return error.Incomplete;
        if (@hasField(@TypeOf(value), "ticks_opened")) if (value.ticks_opened != value.ticks_closed) return error.Incomplete;
        if (comptime @TypeOf(value) == frontier.Terminal or @TypeOf(value) == acceptance.Terminal) {
            if (value.ticks_failed != self.failed_ticks[index] or value.last_error_code != self.last_tick_error[index]) return error.Incomplete;
        }
        if (@hasField(@TypeOf(value), "reason")) if (value.reason == .cancelled) return error.Incomplete;
        self.closed[index] = true;
    }
    pub fn accept(self: *Cursor, record: Record) Error!void {
        errdefer self.failed = true;
        try self.charge();
        try requireCanonicalErrors(record, self.header.identity.rules_version);
        switch (record) {
            .begin => |value| {
                const role: usize = @intFromEnum(value.key.role);
                if (value.key.role == .render and self.pending_pcm != null) return error.InvalidPcm;
                if (self.active[role] != null or value.key.ordinal != self.operations[role] + 1) return error.InvalidOrder;
                if (self.operations[role] == self.header.limits.operations_per_role) return error.EventBudget;
                switch (value.args) {
                    .submit => |s| {
                        if (value.key.role != .control or s.bank.context != self.header.identity.context or s.bank.asset_generation != self.header.identity.generation or s.bank.handle.index != 0 or s.bank.handle.generation != self.header.bindings.render_manifest.music_handle_incarnation) return error.StaleIdentity;
                        switch (s.request) {
                            .set_state => |state| if (state.state == 0) return error.InvalidRecord,
                            .stop_emergency => {},
                            else => return error.UnsupportedOperation,
                        }
                    },
                    .tick, .poll_receipt, .retire_sources, .poll_phase_receipt => if (value.key.role != .control) return error.InvalidRecord,
                    .render => |r| if (value.key.role != .render or r.frames == 0 or r.frames > max_recordable_render_frames or r.frames > self.header.identity.quantum_frames or r.frames > self.header.limits.max_pcm_frames or r.channels != self.header.identity.channels) return error.InvalidRecord,
                    .worker_one => if (value.key.role != .worker) return error.InvalidRecord,
                }
                self.operations[role] += 1;
                self.active[role] = value;
            },
            .end => |value| {
                const begin = try self.requireKey(value.key);
                const valid = switch (value.result) {
                    .failed => |failure| !(begin.args == .tick and failure == .invalid_state),
                    .tick_failed => |tick| begin.args == .tick and tick.failure == .invalid_state and tick.control_tick != 0 and tick.frontier_tick_serial != 0,
                    .submitted => |ticket| switch (begin.args) {
                        .submit => |s| ticket.request_id != 0 and ticket.context == s.bank.context and std.meta.eql(ticket.bank, s.bank),
                        else => false,
                    },
                    .ticked => |tick| begin.args == .tick and tick.frontier_tick_serial != 0 and tick.control_tick != 0,
                    .receipt => |receipt| blk: {
                        if (begin.args != .poll_receipt) break :blk false;
                        if (receipt) |r| {
                            if (r.version != 1 or r.ticket.context != self.header.identity.context or r.ticket.request_id == 0 or r.ticket.bank.context != self.header.identity.context or r.ticket.bank.handle.index != 0 or r.ticket.bank.handle.generation != self.header.bindings.render_manifest.music_handle_incarnation or r.ticket.bank.asset_generation != self.header.identity.generation) break :blk false;
                            // The shared receipt codec may represent normal V1
                            // Control application; this causal profile cannot.
                            if (r.event == .terminal and r.event.terminal == .control_applied) return error.UnsupportedOperation;
                        }
                        break :blk true;
                    },
                    .phase_receipt => |receipt| blk: {
                        if (begin.args != .poll_phase_receipt) break :blk false;
                        if (receipt) |r| {
                            r.token.validate() catch break :blk false;
                            if (r.token.context.value() != self.header.identity.context or r.token.asset_generation.value() != self.header.identity.generation or r.token.transport_epoch.value() != self.header.bindings.render_manifest.transport_epoch) break :blk false;
                        }
                        break :blk true;
                    },
                    .rendered => |r| blk: {
                        if (begin.args != .render or !r.completed or r.frame_end < r.frame_begin or r.frame_end - r.frame_begin != begin.args.render.frames or r.call_sequence_begin & 1 != 0 or r.call_sequence_end < r.call_sequence_begin or r.call_sequence_end - r.call_sequence_begin != 2) break :blk false;
                        if (self.pending_pcm != null) return error.InvalidPcm;
                        self.pending_pcm = .{ .key = value.key, .frames = begin.args.render.frames, .channels = begin.args.render.channels };
                        self.rendered_calls += 1;
                        break :blk true;
                    },
                    .worked => begin.args == .worker_one,
                    .retirement_requested => begin.args == .retire_sources,
                };
                if (!valid) return error.InvalidRecord;
                if (self.header.identity.rules_version == 2) {
                    if (begin.args == .tick and self.control_release_operation != value.key.ordinal) return error.InvalidOrder;
                    if (begin.args == .worker_one and value.result == .worked and self.worker_release_operation != value.key.ordinal) return error.InvalidOrder;
                }
                self.active[@intFromEnum(value.key.role)] = null;
            },
            .input => |value| {
                if (value.key.role != .control) return error.InvalidRecord;
                _ = try self.requireKey(value.key);
                value.value.validate() catch return error.InvalidRecord;
                switch (value.value.payload) {
                    .runtime_step, .state_host_operation, .context_host_operation, .generation_intent, .generation_preparation, .device => return error.UnsupportedOperation,
                    .request => |r| switch (r.payload) {
                        .set_state, .stop_emergency => {},
                        else => return error.UnsupportedOperation,
                    },
                    else => {},
                }
            },
            .schedule => |value| {
                if (value.key.role != .control) return error.InvalidRecord;
                _ = try self.requireKey(value.key);
                value.value.validate() catch return error.InvalidRecord;
            },
            .scheduler_publication => |value| {
                if (value.key.role != .control) return error.InvalidRecord;
                const begin = try self.requireKey(value.key);
                if (begin.args != .tick or value.value.block.generation == 0 or value.value.batch_id == 0 or value.value.sequence == 0 or zero(value.value.content_hash)) return error.InvalidRecord;
            },
            .group_source_final => |value| {
                if (value.key.role != .control) return error.InvalidRecord;
                const begin = try self.requireKey(value.key);
                if (begin.args != .tick or value.value.group.index >= rt.music_group.max_groups or value.value.group.generation == 0) return error.InvalidRecord;
                if (value.value.bank_generation != self.header.identity.generation) return error.StaleIdentity;
            },
            .scheduler_progress => |value| {
                // A separate Render-owned lane may drain before or after its
                // RenderCell. File order cannot manufacture an operation edge.
                // The contiguous begin/end stream and final check bind keys;
                // semantic replay separately binds each actual publication.
                try self.renderProgressKey(value.key);
                const p = value.value;
                if (p.generation == 0) return error.StaleIdentity;
                switch (p.site) {
                    .scheduler_phase => if (p.index >= rt.scheduler.default_profile.plan_capacity or p.value == 0 or p.value > rt.scheduler.default_profile.phases_per_plan or p.command_id != 0) return error.InvalidRecord,
                    .scheduler_acquired => if (p.index >= rt.scheduler.block_capacity or p.value != @intFromEnum(rt.scheduler.State.acquired) or p.command_id != 0) return error.InvalidRecord,
                    .scheduler_terminal => if (p.index >= rt.scheduler.block_capacity or p.value != @intFromEnum(rt.scheduler.State.terminal) or p.command_id != 0) return error.InvalidRecord,
                    .scheduler_receipt => if (p.index >= rt.scheduler.block_capacity or p.value == 0 or p.value > rt.scheduler.commands_per_block or p.command_id == 0) return error.InvalidRecord,
                }
            },
            .stream_consumed_range => |value| {
                try self.renderProgressKey(value.key);
                if (value.key.ordinal != self.consumed_calls + 1 or value.index >= consumed_slots or value.generation == 0 or value.first == 0 or value.last < value.first or value.count == 0 or value.count > max_recordable_render_frames or value.last - value.first != value.count - 1) return error.InvalidRecord;
                const bit = @as(u64, 1) << @intCast(value.index);
                if (self.consumed_range_mask & bit != 0) return error.InvalidOrder;
                self.consumed_range_mask |= bit;
                self.consumed_range_count += 1;
                self.consumed_publications += value.count;
            },
            .stream_consumed_call_end => |value| {
                try self.renderProgressKey(value.key);
                if (value.key.ordinal != self.consumed_calls + 1 or value.ranges != self.consumed_range_count or value.publications != self.consumed_publications) return error.InvalidOrder;
                self.consumed_calls += 1;
                self.consumed_range_mask = 0;
                self.consumed_range_count = 0;
                self.consumed_publications = 0;
            },
            .group_terminal => |value| {
                try self.renderProgressKey(value.key);
                const outcome = value.value;
                if (outcome.group.generation == 0 or outcome.bank_generation != self.header.identity.generation) return error.StaleIdentity;
                if (outcome.group.index >= rt.music_group.max_groups) return error.InvalidRecord;
                if (outcome.last_sample_frame) |last| if (last >= outcome.boundary_frame) return error.InvalidRecord;
            },
            .group_event_queue => |value| {
                if (self.group_event_closed) return error.InvalidOrder;
                if (value.epoch != group_event_epoch) return error.StaleIdentity;
                switch (value.observation) {
                    .push => |p| {
                        try self.renderProgressKey(value.key);
                        if (!p.enabled or !p.accepted) return error.Incomplete;
                        const head = p.head_before orelse return error.InvalidRecord;
                        const tail = p.tail_acquired orelse return error.InvalidRecord;
                        const after = p.head_after orelse return error.InvalidRecord;
                        if (head != self.group_event_head or head == std.math.maxInt(u64) or tail > head or head - tail >= group_event_capacity or after != head + 1) return error.InvalidRecord;
                        self.group_event_head = after;
                    },
                    .pop => |p| {
                        if (value.key.role != .control) return error.InvalidRecord;
                        const begin = try self.requireKey(value.key);
                        if (begin.args != .tick or p.tail_before != self.group_event_tail or p.head_acquired < p.tail_before or p.head_acquired - p.tail_before > group_event_capacity or p.present != (p.head_acquired > p.tail_before)) return error.InvalidRecord;
                        if (p.present and p.tail_before == std.math.maxInt(u64)) return error.InvalidRecord;
                        if (p.tail_after != p.tail_before + @intFromBool(p.present)) return error.InvalidRecord;
                        self.group_event_tail = p.tail_after;
                    },
                }
            },
            .group_event_queue_terminal => |value| {
                if (self.group_event_closed) return error.DuplicateTerminal;
                if (value.epoch != group_event_epoch) return error.StaleIdentity;
                for (self.active) |active| if (active != null) return error.InvalidOrder;
                if (value.head != self.group_event_head or value.tail != self.group_event_tail or value.head != value.tail) return error.Incomplete;
                self.group_event_closed = true;
            },
            .worker => |value| {
                if (value.key.role != .worker) return error.InvalidRecord;
                _ = try self.requireKey(value.key);
            },
            .service_worker_release => |value| {
                const begin = try self.requireKey(value.key);
                if (value.key.role != .worker or begin.args != .worker_one or value.value.ticket == 0 or serviceClaimRole(value.value.token) != .worker) return error.InvalidRecord;
                if (value.key.ordinal <= self.worker_release_operation or value.value.token / 4 != self.worker_release_facts + 1 or value.value.token / 4 != self.service_claim_ordinals[@intFromEnum(Role.worker)]) return error.InvalidOrder;
                self.worker_release_operation = value.key.ordinal;
            },
            .service_release_observation => |value| {
                const begin = try self.requireKey(value.key);
                if (value.key.role != .control or begin.args != .tick or (value.token != 0 and serviceClaimRole(value.token) != .worker)) return error.InvalidRecord;
                if (value.key.ordinal <= self.control_release_operation or value.token < self.control_release_token or value.after_claims != self.service_claim_ordinals[@intFromEnum(Role.control)]) return error.InvalidOrder;
                self.control_release_operation = value.key.ordinal;
                self.control_release_token = value.token;
            },
            .service_claim => |value| {
                if (self.header.identity.rules_version != 2 or value.key.role == .render) return error.InvalidRecord;
                const begin = try self.requireKey(value.key);
                const claim = value.value;
                if (value.key.role == .control and self.control_release_operation != value.key.ordinal) return error.InvalidOrder;
                if (serviceClaimRole(claim.token) != value.key.role) return error.InvalidRecord;
                const role = @intFromEnum(value.key.role);
                if (claim.token / 4 != self.service_claim_ordinals[role] + 1) return error.InvalidOrder;
                if (claim.observed != 0 and (serviceClaimRole(claim.observed) == null or claim.observed == claim.token)) return error.InvalidRecord;
                switch (claim.kind) {
                    .worker => if (value.key.role != .worker or begin.args != .worker_one) return error.InvalidRecord,
                    .stream_close => |closed| if (value.key.role != .control or begin.args != .tick or closed.handle.generation == 0) return error.InvalidRecord,
                    .prepare_asset => |prepared| if (value.key.role != .worker or begin.args != .worker_one or prepared.asset == 0 or zero(prepared.encoded_hash)) return error.InvalidRecord,
                }
                self.service_claim_ordinals[role] += 1;
            },
            .service_exclusion => |value| {
                if (value.key.role == .render or value.value.ticket == 0) return error.InvalidRecord;
                const begin = try self.requireKey(value.key);
                switch (value.value.owner) {
                    .worker => if (value.key.role != .worker or begin.args != .worker_one) return error.InvalidRecord,
                    .stream_close => |closed| {
                        if (value.key.role != .control or begin.args != .tick or closed.handle.generation == 0) return error.InvalidRecord;
                    },
                    .prepare_asset => |prepared| {
                        if (value.key.role != .worker or begin.args != .worker_one or prepared.asset == 0 or zero(prepared.encoded_hash)) return error.InvalidRecord;
                    },
                }
                // Ticket continuity/uniqueness and exact claim/release pairing
                // are semantic obligations, independent of lane arrival order.
            },
            .frontier => |v| try self.event(0, v),
            .acceptance => |v| try self.event(1, v),
            .readiness => |v| try self.event(2, v),
            .render => |v| try self.event(3, v),
            .frontier_terminal => |v| try self.terminal(0, v),
            .acceptance_terminal => |v| try self.terminal(1, v),
            .readiness_terminal => |v| {
                if (!std.meta.eql(v.manifest, self.header.bindings.readiness_manifest)) return error.StaleIdentity;
                try self.terminal(2, v);
            },
            .render_terminal => |v| {
                if (!std.meta.eql(v.manifest, self.header.bindings.render_manifest)) return error.StaleIdentity;
                if (v.reason != .host_quiescent or v.refused_events != 0 or v.suppressed_work or v.calls_opened != v.calls_closed or v.final_call_sequence & 1 != 0) return error.Incomplete;
                try self.terminal(3, v);
            },
            .pcm => |v| {
                const expected = self.pending_pcm orelse return error.InvalidPcm;
                if (!std.meta.eql(v.key, expected.key) or v.frames != expected.frames or v.channels != expected.channels) return error.InvalidPcm;
                if (v.key.role != .render or v.key.ordinal == 0 or v.key.ordinal <= self.last_pcm_ordinal or v.key.ordinal > self.operations[1] or v.frames == 0 or v.frames > self.header.identity.quantum_frames or v.channels != self.header.identity.channels or zero(v.digest)) return error.InvalidPcm;
                self.pending_pcm = null;
                self.last_pcm_ordinal = v.key.ordinal;
                self.pcm_frames += v.frames;
                self.pcm_calls += 1;
            },
        }
        // Check typed errors first, then account the same shared lane that
        // actually appended this record. A rejected fact consumes no count.
        try self.hostEvent(record);
        switch (record) {
            .worker => self.worker_facts += 1,
            .service_exclusion => self.service_exclusion_facts += 1,
            .service_claim => self.service_claim_facts += 1,
            .service_worker_release => self.worker_release_facts += 1,
            .service_release_observation => self.release_observations += 1,
            else => {},
        }
        self.records += 1;
    }
    pub fn finish(self: *const Cursor) Error!void {
        if (self.failed) return error.Incomplete;
        for (self.active) |active| if (active != null) return error.Incomplete;
        for (self.closed) |closed| if (!closed) return error.MissingTerminal;
        // Mandatory even for an empty interval: older incomplete profile-5
        // evidence must not silently omit every group-event queue cut.
        if (!self.group_event_closed) return error.MissingTerminal;
        if (self.last_progress_ordinal > self.operations[@intFromEnum(Role.render)]) return error.InvalidOrder;
        if (self.pending_pcm != null or self.pcm_calls != self.rendered_calls) return error.InvalidPcm;
        if (self.consumed_range_count != 0 or self.consumed_calls != self.operations[@intFromEnum(Role.render)]) return error.MissingTerminal;
    }
};

pub const PageHeader = struct {
    magic: [8]u8 = "SMECPG01".*,
    sequence: u64,
    first_record: u64,
    record_count: u32,
    payload_bytes: u32,
    previous_digest: Hash,
    payload_digest: Hash,
    page_digest: Hash,
};
pub const page_header_bytes = maxSize(PageHeader);
pub const max_page_payload = page_bytes - page_header_bytes;
pub const PcmSummary = struct { frames: u64 = 0, calls: u64 = 0, digest: Hash };
pub const Terminal = struct {
    magic: [8]u8 = "SMECTM01".*,
    version: u16 = 1,
    session: SessionIdentity,
    header_digest: Hash,
    final_page_digest: Hash,
    page_count: u64,
    record_count: u64,
    file_bytes: u64,
    pcm: PcmSummary,
    terminal_digest: Hash,
};
pub const terminal_bytes = maxSize(Terminal);
fn pageDigest(value: PageHeader) Error!Hash {
    var v = value;
    v.page_digest = @splat(0);
    return hashValue("SME/causal-page/v1\x00", v);
}
pub fn terminalDigest(value: Terminal) Error!Hash {
    var v = value;
    v.terminal_digest = @splat(0);
    return hashValue("SME/causal-terminal/v1\x00", v);
}
pub const Chain = struct {
    header: Header,
    header_digest: Hash,
    previous_digest: Hash,
    pages: u64 = 0,
    records: u64 = 0,
    bytes: u64 = header_bytes,
    sealed: bool = false,
    pub fn init(header: Header) Error!Chain {
        try header.validate();
        const h = try hashValue("SME/causal-header/v1\x00", header);
        return .{ .header = header, .header_digest = h, .previous_digest = h };
    }
    pub fn encodePage(self: *Chain, payload: []const u8, record_count: u32, output: []u8) Error![]const u8 {
        if (self.sealed) return error.Incomplete;
        if (payload.len == 0 or payload.len > max_page_payload or record_count == 0 or record_count > payload.len / 8) return error.InvalidLength;
        if (record_count > self.header.limits.parser_steps - self.records) return error.WorkBudget;
        if (self.bytes + page_header_bytes + payload.len + terminal_bytes > self.header.limits.file_bytes) return error.ByteBudget;
        var iterator: RecordIterator = .{ .bytes = payload, .remaining = record_count };
        while (try iterator.next()) |_| {}
        var p: PageHeader = .{ .sequence = self.pages, .first_record = self.records, .record_count = record_count, .payload_bytes = @intCast(payload.len), .previous_digest = self.previous_digest, .payload_digest = hashBytes("SME/causal-payload/v1\x00", payload), .page_digest = @splat(0) };
        p.page_digest = try pageDigest(p);
        if (output.len < page_header_bytes + payload.len) return error.BufferTooSmall;
        var e: Encoder = .{ .bytes = output };
        try e.put(p);
        @memcpy(output[e.offset..][0..payload.len], payload);
        self.pages += 1;
        self.records += record_count;
        self.bytes += page_header_bytes + payload.len;
        self.previous_digest = p.page_digest;
        return output[0 .. e.offset + payload.len];
    }
    pub fn finish(self: *Chain, pcm: PcmSummary) Error!Terminal {
        if (self.sealed) return error.DuplicateTerminal;
        if (self.bytes + terminal_bytes > self.header.limits.file_bytes) return error.ByteBudget;
        var terminal: Terminal = .{ .session = self.header.session, .header_digest = self.header_digest, .final_page_digest = self.previous_digest, .page_count = self.pages, .record_count = self.records, .file_bytes = self.bytes + terminal_bytes, .pcm = pcm, .terminal_digest = @splat(0) };
        terminal.terminal_digest = try terminalDigest(terminal);
        self.sealed = true;
        return terminal;
    }
};
pub fn encodeTerminal(value: Terminal, bytes: []u8) Error![]const u8 {
    if (!equal(value.terminal_digest, try terminalDigest(value))) return error.HashMismatch;
    var e: Encoder = .{ .bytes = bytes };
    try e.put(value);
    return bytes[0..e.offset];
}
pub fn decodeTerminal(bytes: []const u8) Error!Terminal {
    var d: Decoder = .{ .bytes = bytes };
    const v = try d.get(Terminal);
    try d.finish();
    if (!std.mem.eql(u8, &v.magic, "SMECTM01") or v.version != 1) return error.UnknownVersion;
    if (!equal(v.terminal_digest, try terminalDigest(v))) return error.HashMismatch;
    return v;
}
pub const RecordIterator = struct {
    bytes: []const u8,
    remaining: u32,
    offset: usize = 0,
    pub fn next(self: *RecordIterator) Error!?Record {
        if (self.remaining == 0) {
            if (self.offset != self.bytes.len) return error.TrailingBytes;
            return null;
        }
        if (self.offset > self.bytes.len or self.bytes.len - self.offset < 4) return error.Truncated;
        const n = std.mem.readInt(u32, self.bytes[self.offset..][0..4], .little);
        if (n == 0 or n > max_record_bytes - 4) return error.InvalidLength;
        if (n > self.bytes.len - self.offset - 4) return error.Truncated;
        const value = try decodeRecord(self.bytes[self.offset..][0 .. 4 + n]);
        self.offset += 4 + n;
        self.remaining -= 1;
        return value;
    }
};
/// Caller supplies one bounded page. No file-sized allocation, index or PCM.
/// acceptPage validates all records before returning an iterator for semantics.
pub const Reader = struct {
    chain: Chain,
    cursor: Cursor,
    terminal: ?Terminal = null,
    failed: bool = false,
    pub fn init(header: Header) Error!Reader {
        return .{ .chain = try Chain.init(header), .cursor = try Cursor.init(header) };
    }
    pub fn acceptPage(self: *Reader, bytes: []const u8) Error!RecordIterator {
        errdefer self.failed = true;
        if (self.failed or self.terminal != null) return error.Incomplete;
        if (bytes.len < page_header_bytes or bytes.len > page_bytes) return error.InvalidLength;
        var d: Decoder = .{ .bytes = bytes[0..page_header_bytes] };
        const p = try d.get(PageHeader);
        try d.finish();
        if (!std.mem.eql(u8, &p.magic, "SMECPG01")) return error.InvalidRecord;
        if (p.sequence != self.chain.pages or p.first_record != self.chain.records) return error.InvalidOrder;
        if (p.record_count == 0 or p.payload_bytes == 0 or p.payload_bytes != bytes.len - page_header_bytes or p.record_count > p.payload_bytes / 8) return error.InvalidLength;
        // Reject declared byte/work overruns before hashing or record traversal.
        if (self.chain.bytes + bytes.len + terminal_bytes > self.chain.header.limits.file_bytes) return error.ByteBudget;
        if (p.record_count > self.chain.header.limits.parser_steps - self.cursor.steps) return error.WorkBudget;
        if (!equal(p.previous_digest, self.chain.previous_digest) or !equal(p.payload_digest, hashBytes("SME/causal-payload/v1\x00", bytes[page_header_bytes..])) or !equal(p.page_digest, try pageDigest(p))) return error.HashMismatch;
        const result: RecordIterator = .{ .bytes = bytes[page_header_bytes..], .remaining = p.record_count };
        var iterator = result;
        while (try iterator.next()) |record| try self.cursor.accept(record);
        self.chain.pages += 1;
        self.chain.records += p.record_count;
        self.chain.bytes += bytes.len;
        self.chain.previous_digest = p.page_digest;
        return result;
    }
    pub fn acceptTerminal(self: *Reader, bytes: []const u8) Error!Terminal {
        errdefer self.failed = true;
        if (self.failed) return error.Incomplete;
        if (self.terminal != null) return error.DuplicateTerminal;
        const value = try decodeTerminal(bytes);
        try self.cursor.finish();
        if (!std.meta.eql(value.session, self.chain.header.session) or !equal(value.header_digest, self.chain.header_digest)) return error.StaleIdentity;
        if (value.page_count != self.chain.pages or value.record_count != self.chain.records or value.file_bytes != self.chain.bytes + terminal_bytes or !equal(value.final_page_digest, self.chain.previous_digest)) return error.InvalidOrder;
        if (value.file_bytes > self.chain.header.limits.file_bytes) return error.ByteBudget;
        if (value.pcm.frames != self.cursor.pcm_frames or value.pcm.calls != self.cursor.pcm_calls or zero(value.pcm.digest)) return error.InvalidPcm;
        self.terminal = value;
        return value;
    }
    /// Call only after checking actual EOF. This asserts no successful writes.
    pub fn finishEOF(self: *const Reader) Error!Terminal {
        if (self.failed) return error.Incomplete;
        return self.terminal orelse error.MissingTerminal;
    }
};

/// Assembler-only accumulator of the actual owned mixed Render samples.
/// All f32 bits survive: signed zero, infinities and NaN payload/signs are never
/// normalized. Neither this hash nor its proof creates provenance on its own.
pub const PcmAccumulator = struct {
    hash: std.crypto.hash.sha2.Sha256,
    frames: u64 = 0,
    calls: u64 = 0,
    last_ordinal: u64 = 0,
    pub fn init() PcmAccumulator {
        var h = std.crypto.hash.sha2.Sha256.init(.{});
        h.update("SME/causal-pcm-samples/v1\x00");
        return .{ .hash = h };
    }
    pub fn append(self: *PcmAccumulator, key: OperationKey, frames: u32, channels: u16, samples: []const f32) Error!PcmBlock {
        if (key.role != .render or key.ordinal == 0 or key.ordinal > max_operations_per_role or key.ordinal <= self.last_ordinal or frames == 0 or frames > max_pcm_frames or channels != 2 or samples.len != @as(usize, frames) * channels or self.calls == max_operations_per_role) return error.InvalidPcm;
        var block = std.crypto.hash.sha2.Sha256.init(.{});
        block.update("SME/causal-pcm-block/v1\x00");
        var bits: [4]u8 = undefined;
        for (samples) |sample| {
            std.mem.writeInt(u32, &bits, @bitCast(sample), .little);
            self.hash.update(&bits);
            block.update(&bits);
        }
        var digest: Hash = undefined;
        block.final(&digest);
        self.frames += frames;
        self.calls += 1;
        self.last_ordinal = key.ordinal;
        return .{ .key = key, .frames = frames, .channels = channels, .digest = digest };
    }
    pub fn finish(self: *const PcmAccumulator) PcmSummary {
        var h = self.hash;
        var digest: Hash = undefined;
        h.final(&digest);
        return .{ .frames = self.frames, .calls = self.calls, .digest = digest };
    }
};
pub const PcmProof = struct {
    magic: [8]u8 = "SMECPM01".*,
    version: u16 = 1,
    digest_algorithm: u16 = 1,
    sample_encoding: u16 = 1,
    session: SessionIdentity,
    header_digest: Hash,
    terminal_digest: Hash,
    sample_rate: u32,
    channels: u16,
    pcm: PcmSummary,
    proof_digest: Hash,
    pub fn init(header: Header, terminal: Terminal) Error!PcmProof {
        try header.validate();
        if (!std.mem.eql(u8, &terminal.magic, "SMECTM01") or terminal.version != 1) return error.UnknownVersion;
        if (!std.meta.eql(header.session, terminal.session) or !equal(terminal.header_digest, try hashValue("SME/causal-header/v1\x00", header)) or !equal(terminal.terminal_digest, try terminalDigest(terminal))) return error.ProofBindingMismatch;
        var proof: PcmProof = .{ .session = header.session, .header_digest = terminal.header_digest, .terminal_digest = terminal.terminal_digest, .sample_rate = header.identity.sample_rate, .channels = header.identity.channels, .pcm = terminal.pcm, .proof_digest = @splat(0) };
        proof.proof_digest = try proof.expectedDigest();
        try proof.validate();
        return proof;
    }
    pub fn expectedDigest(self: PcmProof) Error!Hash {
        var p = self;
        p.proof_digest = @splat(0);
        return hashValue("SME/causal-pcm-proof/v1\x00", p);
    }
    pub fn validate(self: PcmProof) Error!void {
        if (!std.mem.eql(u8, &self.magic, "SMECPM01") or self.version != 1 or self.digest_algorithm != 1 or self.sample_encoding != 1) return error.UnknownVersion;
        if (self.session.incarnation == 0 or self.session.interval_id == 0 or self.sample_rate == 0 or self.channels != 2 or zero(self.header_digest) or zero(self.terminal_digest) or zero(self.pcm.digest) or self.pcm.calls > max_operations_per_role or self.pcm.frames > @as(u64, max_operations_per_role) * max_pcm_frames or (self.pcm.frames == 0) != (self.pcm.calls == 0) or self.pcm.calls > self.pcm.frames or self.pcm.frames > self.pcm.calls * max_pcm_frames) return error.InvalidPcm;
        if (!equal(self.proof_digest, try self.expectedDigest())) return error.HashMismatch;
    }
    pub fn requireBinding(self: PcmProof, header: Header, terminal: Terminal) Error!void {
        try self.validate();
        const expected = try PcmProof.init(header, terminal);
        if (!std.meta.eql(self, expected)) return error.ProofBindingMismatch;
    }
    pub fn requirePcm(self: PcmProof, actual: PcmSummary) Error!void {
        try self.validate();
        if (!std.meta.eql(self.pcm, actual)) return error.InvalidPcm;
    }
};
pub const pcm_proof_bytes = maxSize(PcmProof);
pub fn encodePcmProof(proof: PcmProof, bytes: []u8) Error![]const u8 {
    try proof.validate();
    var e: Encoder = .{ .bytes = bytes };
    try e.put(proof);
    return bytes[0..e.offset];
}
pub fn decodePcmProof(bytes: []const u8) Error!PcmProof {
    var d: Decoder = .{ .bytes = bytes };
    const p = try d.get(PcmProof);
    try d.finish();
    try p.validate();
    return p;
}

comptime {
    @setEvalBranchQuota(100_000);
    if (header_bytes > page_bytes or max_record_bytes > max_page_payload or page_header_bytes != 128) @compileError("causal fixed representation exceeds its page bound");
}
