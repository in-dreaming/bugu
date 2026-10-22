//! ChunkRecordingV1: bounded, explicit container framing, independent of legacy
//! envelopes. Control/export-side only; no allocation, I/O or runtime hooks.
//!
//! Wire integers are little endian via the existing canonical scalar codec.
//! Preamble is 262 bytes: 56-byte prefix, all 154 identity bytes in Header field
//! order EXCEPT complete, 20 bytes of limits, then 32-byte recording_id. The
//! identity's schema_version is deliberately repeated and checked. Frame header
//! is exactly 180 bytes: 84 scalar/identity bytes and three 32-byte hashes.
//! Terminal fixed prefix is 76 bytes. Success adds a u32 length and the caller's
//! actual final runtime .end Input; this module never manufactures that event.
//!
//! Validation proves framing, canonical records and persistent Position/admission
//! ordering ONLY. It does not validate begin/end host grammar, paired operations,
//! transactions, runtime closure, resource preparation, or recomputed playback.
//! In particular a successful terminal is a producer assertion, not proof of
//! those semantics. finishAtEof returns an explicitly limited evidence type,
//! never a complete legacy Header or a public-replay acceptance result.
const std = @import("std");
const schema = @import("trace_schema.zig");
const codec = @import("trace_codec.zig");
pub const Hash = schema.Hash;
pub const container_version: u16 = 1;
pub const preamble_bytes: usize = 262;
pub const frame_header_bytes: usize = 180;
pub const terminal_prefix_bytes: usize = 76;
pub const max_payload_bytes: u32 = 131072;
pub const max_chunk_records: u32 = 254;
const preamble_domain = "SME/chunk-recording/v1\x00";
const payload_domain = "SME/chunk-payload/v1\x00";
const frame_domain = "SME/chunk-frame/v1\x00";
pub const Error = schema.Error || codec.Error || schema.context_host.Error || error{
    InvalidMagic,
    InvalidPreamble,
    UnsupportedProfile,
    InvalidFrame,
    InvalidTerminal,
    NonCanonicalRecord,
    InvalidChain,
    CounterOverflow,
    WorkLimit,
    InvalidLimits,
    InvalidState,
    MissingTerminal,
    RecorderIncomplete,
    UnexpectedEnd,
};

/// Execution identity only: deliberately has no completeness field or conversion
/// to a replay-accepted Header. Kept byte-for-byte in existing Header field order.
pub const Identity = struct {
    schema_version: u16 = schema.version,
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
    rules_version: u16 = schema.integer_rules_version,
    field_classification_version: u16 = schema.classification_version,

    pub fn fromHeader(header: schema.Header) Identity {
        var result: Identity = undefined;
        inline for (@typeInfo(Identity).@"struct".fields) |field| {
            @field(result, field.name) = @field(header, field.name);
        }
        return result;
    }
    pub fn validate(self: Identity) Error!void {
        // Match Header's field rules without ever making an incomplete Header
        // look complete merely to call Header.validate(). Legacy code is untouched.
        if (self.schema_version != schema.version or self.rules_version != schema.integer_rules_version or self.field_classification_version != schema.classification_version) return error.UnknownVersion;
        if (self.compiler_version == 0 or self.algorithm_version == 0 or self.profile == 0 or self.sample_rate == 0 or self.quantum_frames == 0 or self.bank_major == 0 or self.bank_build_id == 0 or self.generation == 0) return error.InvalidHeader;
        if (schema.isZero(self.bank_content_hash) or schema.isZero(self.capacity_profile_hash) or schema.isZero(self.initial_state_hash)) return error.InvalidHeader;
    }
};

pub const Preamble = struct {
    magic: [8]u8 = "SMECHN01".*,
    version: u16 = container_version,
    trace_schema_version: u16 = schema.version,
    record_codec_version: u16 = 1,
    hash_algorithm: u16 = 1,
    length: u32 = preamble_bytes,
    runtime_profile: schema.RuntimeProfile,
    reserved: u16 = 0,
    recording_nonce: Hash,
    identity: Identity,
    max_chunk_payload_bytes: u32 = max_payload_bytes,
    max_chunk_inputs: u32 = max_chunk_records,
    max_chunk_schedule: u32 = max_chunk_records,
    max_chunk_combined_records: u32 = max_chunk_records,
    limits_profile: u16 = 1,
    reserved_limits: u16 = 0,
    recording_id: Hash = [_]u8{0} ** 32,

    pub fn init(identity: Identity, profile: schema.RuntimeProfile, nonce: Hash) Error!Preamble {
        var result: Preamble = .{ .identity = identity, .runtime_profile = profile, .recording_nonce = nonce };
        try result.validateFields();
        result.recording_id = try result.expectedId();
        return result;
    }
    fn validateFields(self: Preamble) Error!void {
        if (!std.mem.eql(u8, &self.magic, "SMECHN01")) return error.InvalidMagic;
        if (self.version != container_version or self.trace_schema_version != schema.version or self.record_codec_version != 1 or self.hash_algorithm != 1 or self.limits_profile != 1) return error.UnknownVersion;
        if (self.runtime_profile != .stream_serial_v1 and self.runtime_profile != .stream_direct_state_serial_v1 and self.runtime_profile != .stream_fill_state_serial_v1 and self.runtime_profile != .stream_context_serial_v1) return error.UnsupportedProfile;
        if (self.length != preamble_bytes or self.reserved != 0 or self.reserved_limits != 0 or schema.isZero(self.recording_nonce)) return error.InvalidPreamble;
        if (self.max_chunk_payload_bytes != max_payload_bytes or self.max_chunk_inputs != max_chunk_records or self.max_chunk_schedule != max_chunk_records or self.max_chunk_combined_records != max_chunk_records) return error.InvalidPreamble;
        try self.identity.validate();
    }
    fn expectedId(self: Preamble) Error!Hash {
        var bytes: [preamble_bytes]u8 = undefined;
        var e: codec.Encoder = .{ .bytes = &bytes };
        try e.put(self);
        return digest(preamble_domain, bytes[0 .. preamble_bytes - 32], "");
    }
    pub fn validate(self: Preamble) Error!void {
        try self.validateFields();
        const expected = try self.expectedId();
        if (!std.mem.eql(u8, &self.recording_id, &expected)) return error.HashMismatch;
    }
};

pub fn encodePreamble(bytes: []u8, preamble: Preamble) Error![]const u8 {
    try preamble.validate();
    var e: codec.Encoder = .{ .bytes = bytes };
    try e.put(preamble);
    return bytes[0..e.offset];
}
pub fn decodePreamble(bytes: []const u8) Error!Preamble {
    var d: codec.Decoder = .{ .bytes = bytes };
    const result = try d.get(Preamble);
    try d.finish();
    try result.validate();
    return result;
}

pub const FrameKind = enum(u8) { data = 1, terminal = 2 };
pub const FrameHeader = struct {
    magic: [4]u8 = "SMCF".*,
    version: u16 = container_version,
    kind: FrameKind,
    flags: u8 = 0,
    header_bytes: u32 = frame_header_bytes,
    payload_bytes: u32,
    recording_id: Hash,
    chunk_sequence: u64,
    input_begin: u64,
    input_count: u32,
    schedule_begin: u64,
    schedule_count: u32,
    reserved: u32 = 0,
    previous_hash: Hash,
    payload_hash: Hash,
    chunk_hash: Hash,
};
pub const TerminalStatus = enum(u8) { complete = 1, recorder_failed = 2, cancelled = 3 };
/// Version-1 numeric reasons only. These describe artifacts; no producer failure
/// or saturation policy is implemented here.
pub const TerminalReason = enum(u8) {
    none = 0,
    capacity_exhausted = 1,
    counter_exhausted = 2,
    export_failed = 3,
    cancelled_by_host = 4,
    runtime_closure_failed = 5,
};
pub const Terminal = struct {
    version: u16 = 1,
    status: TerminalStatus,
    reason: TerminalReason = .none,
    total_inputs: u64,
    total_schedule: u64,
    data_chunk_count: u64,
    final_control_tick: u64,
    final_control_frame: u64,
    final_render_call_sequence: u64,
    attempted_input_frontier: u64,
    attempted_schedule_frontier: u64,
    counters_exhausted: bool = false,
    reserved: [7]u8 = [_]u8{0} ** 7,
};

comptime {
    @setEvalBranchQuota(20_000);
    if (codec.maxSize(Identity) != 154 or codec.maxSize(Identity) + 1 != codec.maxSize(schema.Header)) @compileError("chunk identity must explicitly track Header changes");
    if (codec.maxSize(Preamble) != preamble_bytes) @compileError("preamble wire size changed");
    if (codec.maxSize(FrameHeader) != frame_header_bytes) @compileError("frame header must encode exactly 180 bytes");
    if (codec.maxSize(Terminal) != terminal_prefix_bytes) @compileError("terminal wire size changed");
    if (codec.maxSize(schema.Input) > schema.max_record_bytes or codec.maxSize(schema.ScheduleEntry) > schema.max_record_bytes) @compileError("record maximum changed");
    if (max_chunk_records * (schema.max_record_bytes + 4) > max_payload_bytes) @compileError("records cannot fit payload bound");
}

fn digest(domain: []const u8, first: []const u8, second: []const u8) Hash {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(domain);
    hash.update(first);
    hash.update(second);
    var result: Hash = undefined;
    hash.final(&result);
    return result;
}
fn add(a: u64, b: u64) Error!u64 {
    return std.math.add(u64, a, b) catch error.CounterOverflow;
}
fn putRecord(e: *codec.Encoder, record: anytype) Error!void {
    try record.validate();
    var bytes: [schema.max_record_bytes]u8 = undefined;
    var row: codec.Encoder = .{ .bytes = &bytes };
    try row.put(record);
    try e.put(@as(u32, @intCast(row.offset)));
    if (row.offset > e.bytes.len - e.offset) return error.BufferTooSmall;
    @memcpy(e.bytes[e.offset..][0..row.offset], bytes[0..row.offset]);
    e.offset += row.offset;
}
fn getRecord(comptime T: type, d: *codec.Decoder) Error!T {
    const length = try d.get(u32);
    if (length == 0 or length > schema.max_record_bytes) return error.InvalidLength;
    if (length > d.bytes.len - d.offset) return error.Truncated;
    const bytes = d.bytes[d.offset..][0..length];
    var row: codec.Decoder = .{ .bytes = bytes };
    const record = try row.get(T);
    try row.finish();
    try record.validate();
    // Explicit canonicality check also guards future permissive codec additions.
    var scratch: [schema.max_record_bytes]u8 = undefined;
    var e: codec.Encoder = .{ .bytes = &scratch };
    try e.put(record);
    if (!std.mem.eql(u8, bytes, scratch[0..e.offset])) return error.NonCanonicalRecord;
    d.offset += length;
    return record;
}

/// Same Position/admission rules as replay.validateSequence, persisted across
/// frames, without legacy max_events or any new schedule timestamp ordering.
const InputChecks = struct {
    previous: ?schema.Position = null,
    admission: ?schema.Admission = null,
    host_journal: schema.context_host.Journal = .{},
    fn accept(self: *InputChecks, input: schema.Input, profile: schema.RuntimeProfile, terminal: bool) Error!void {
        try input.validate();
        if (self.previous) |p| {
            if (!schema.before(p, input.position) or input.position.accepted_control_frame < p.accepted_control_frame) return error.InvalidOrder;
        }
        if (profile == .stream_context_serial_v1) {
            if (input.payload == .context_host_operation) {
                try self.host_journal.accept(input.payload.context_host_operation);
            } else try self.host_journal.boundary();
            if (terminal) try self.host_journal.finish();
        }
        switch (input.payload) {
            .context_host_operation => if (profile != .stream_context_serial_v1) return error.UnsupportedProfile,
            .state_host_operation => if (profile == .stream_context_serial_v1) return error.UnsupportedProfile,
            .runtime_step => |step| {
                if (step.profile != profile) return error.UnsupportedProfile;
                if ((step.kind == .end) != terminal) return error.UnexpectedEnd;
            },
            .admission => |a| if (self.admission) |g| {
                if (a.gate < g.gate or a.frame < g.frame or (a.gate == g.gate and (a.frame != g.frame or a.gate_order <= g.gate_order or a.commit_horizon != g.commit_horizon))) return error.InvalidOrder;
            },
            .acoustic_observation => |value| if (value.hasLoss()) return error.IncompleteTrace,
            else => {},
        }
        if (terminal and (input.payload != .runtime_step or input.payload.runtime_step.kind != .end)) return error.UnexpectedEnd;
        self.previous = input.position;
        if (input.payload == .admission) self.admission = input.payload.admission;
    }
};
fn checkTerminal(terminal: Terminal, end: ?schema.Input, profile: schema.RuntimeProfile, input_total: u64, schedule_total: u64, sequence: u64) Error!void {
    if (terminal.version != 1) return error.UnknownVersion;
    if (!std.mem.allEqual(u8, &terminal.reserved, 0) or terminal.data_chunk_count != sequence or terminal.total_schedule != schedule_total) return error.InvalidTerminal;
    const success = terminal.status == .complete;
    if (terminal.total_inputs != try add(input_total, @intFromBool(success))) return error.InvalidTerminal;
    if (success) {
        if (terminal.reason != .none or terminal.counters_exhausted or end == null or terminal.attempted_input_frontier != terminal.total_inputs or terminal.attempted_schedule_frontier != terminal.total_schedule) return error.InvalidTerminal;
        const input = end.?;
        if (input.payload != .runtime_step or input.payload.runtime_step.kind != .end or input.payload.runtime_step.profile != profile) return error.UnexpectedEnd;
        try input.validate();
        if (input.position.control_tick != terminal.final_control_tick or input.position.accepted_control_frame != terminal.final_control_frame or input.payload.runtime_step.render_call_sequence != terminal.final_render_call_sequence) return error.InvalidTerminal;
    } else {
        if (terminal.reason == .none or end != null or terminal.attempted_input_frontier < terminal.total_inputs or terminal.attempted_schedule_frontier < terminal.total_schedule) return error.InvalidTerminal;
    }
}

pub const EncodedFrame = struct {
    header: []const u8,
    payload: []const u8,
    chunk_hash: Hash,
};
/// No I/O and no producer policy. Caller owns nonoverlapping header/payload
/// buffers and supplies immutable, genuinely collected records. Failed encoding
/// leaves chain/counters unchanged (output scratch may have been overwritten).
pub const Encoder = struct {
    preamble: Preamble,
    next_sequence: u64 = 0,
    input_total: u64 = 0,
    schedule_total: u64 = 0,
    previous_hash: Hash,
    inputs: InputChecks = .{},
    sealed: bool = false,

    pub fn init(preamble: Preamble) Error!Encoder {
        try preamble.validate();
        return .{ .preamble = preamble, .previous_hash = preamble.recording_id };
    }
    pub fn encodeData(self: *Encoder, header_buffer: *[frame_header_bytes]u8, payload_buffer: []u8, inputs: []const schema.Input, schedule: []const schema.ScheduleEntry) Error!EncodedFrame {
        if (self.sealed) return error.InvalidState;
        if (inputs.len > max_chunk_records or schedule.len > max_chunk_records or inputs.len + schedule.len == 0 or inputs.len + schedule.len > max_chunk_records) return error.InvalidLength;
        const next_sequence = try add(self.next_sequence, 1);
        _ = try add(next_sequence, 1); // Reserve the terminal's frame count.
        const input_total = try add(self.input_total, @intCast(inputs.len));
        _ = try add(input_total, 1); // Reserve the real final end input.
        const schedule_total = try add(self.schedule_total, @intCast(schedule.len));
        var checks = self.inputs;
        var e: codec.Encoder = .{ .bytes = payload_buffer[0..@min(payload_buffer.len, max_payload_bytes)] };
        for (inputs) |input| {
            try checks.accept(input, self.preamble.runtime_profile, false);
            try putRecord(&e, input);
        }
        for (schedule) |record| try putRecord(&e, record);
        const result = try self.encodeFrame(header_buffer, e.bytes[0..e.offset], .data, @intCast(inputs.len), @intCast(schedule.len));
        self.next_sequence = next_sequence;
        self.input_total = input_total;
        self.schedule_total = schedule_total;
        self.inputs = checks;
        self.previous_hash = result.chunk_hash;
        return result;
    }
    pub fn encodeTerminal(self: *Encoder, header_buffer: *[frame_header_bytes]u8, payload_buffer: []u8, terminal: Terminal, end: ?schema.Input) Error!EncodedFrame {
        if (self.sealed) return error.InvalidState;
        _ = try add(self.next_sequence, 1);
        try checkTerminal(terminal, end, self.preamble.runtime_profile, self.input_total, self.schedule_total, self.next_sequence);
        var checks = self.inputs;
        if (end) |input| try checks.accept(input, self.preamble.runtime_profile, true);
        var e: codec.Encoder = .{ .bytes = payload_buffer[0..@min(payload_buffer.len, max_payload_bytes)] };
        try e.put(terminal);
        if (end) |input| try putRecord(&e, input);
        const result = try self.encodeFrame(header_buffer, e.bytes[0..e.offset], .terminal, @intFromBool(end != null), 0);
        self.sealed = true;
        self.previous_hash = result.chunk_hash;
        return result;
    }
    fn encodeFrame(self: *const Encoder, header_buffer: *[frame_header_bytes]u8, payload: []const u8, kind: FrameKind, input_count: u32, schedule_count: u32) Error!EncodedFrame {
        var header: FrameHeader = .{
            .kind = kind,
            .payload_bytes = @intCast(payload.len),
            .recording_id = self.preamble.recording_id,
            .chunk_sequence = self.next_sequence,
            .input_begin = self.input_total,
            .input_count = input_count,
            .schedule_begin = self.schedule_total,
            .schedule_count = schedule_count,
            .previous_hash = self.previous_hash,
            .payload_hash = digest(payload_domain, payload, ""),
            .chunk_hash = [_]u8{0} ** 32,
        };
        var e: codec.Encoder = .{ .bytes = header_buffer };
        try e.put(header);
        header.chunk_hash = digest(frame_domain, header_buffer[0 .. frame_header_bytes - 32], payload);
        @memcpy(header_buffer[frame_header_bytes - 32 ..], &header.chunk_hash);
        return .{ .header = header_buffer, .payload = payload, .chunk_hash = header.chunk_hash };
    }
};

/// Mandatory caller budgets; total frame/byte counts INCLUDE preamble/terminal
/// bytes and the terminal frame. Payload/record caps may be stricter than the
/// profile's advertised maximum; oversized actual frames are refused before
/// payload copying. Caller scratch must hold the local payload cap.
pub const LocalLimits = struct {
    max_total_inputs: u64,
    max_total_schedule: u64,
    max_frames: u64,
    max_total_bytes: u64,
    max_frame_payload_bytes: u32 = max_payload_bytes,
    max_frame_records: u32 = max_chunk_records,
    fn validate(self: LocalLimits, scratch_len: usize) Error!void {
        if (self.max_total_inputs == 0 or self.max_frames == 0 or self.max_total_bytes < preamble_bytes or self.max_frame_payload_bytes < terminal_prefix_bytes or self.max_frame_payload_bytes > max_payload_bytes or self.max_frame_payload_bytes > scratch_len or self.max_frame_records == 0 or self.max_frame_records > max_chunk_records) return error.InvalidLimits;
    }
};
pub const Record = union(enum) { input: schema.Input, schedule: schema.ScheduleEntry };
pub const RecordIterator = struct {
    decoder: codec.Decoder,
    inputs_remaining: u32,
    schedule_remaining: u32,
    pub fn next(self: *RecordIterator) Error!?Record {
        if (self.inputs_remaining != 0) {
            const input = try getRecord(schema.Input, &self.decoder);
            self.inputs_remaining -= 1;
            return .{ .input = input };
        }
        if (self.schedule_remaining != 0) {
            const schedule = try getRecord(schema.ScheduleEntry, &self.decoder);
            self.schedule_remaining -= 1;
            return .{ .schedule = schedule };
        }
        try self.decoder.finish();
        return null;
    }
};
/// Borrowed bytes are verified only after BOTH hashes and all records pass.
/// Consume them before the next feed(), and do not modify the caller scratch.
pub const VerifiedFrame = struct {
    header: FrameHeader,
    payload: []const u8,
    terminal: ?Terminal,
    pub fn records(self: VerifiedFrame) RecordIterator {
        return .{ .decoder = .{ .bytes = if (self.terminal != null) self.payload[terminal_prefix_bytes..] else self.payload }, .inputs_remaining = self.header.input_count, .schedule_remaining = self.header.schedule_count };
    }
};
pub const FeedResult = struct { consumed: usize, frame: ?VerifiedFrame = null };
pub const EvidenceTier = enum { framing_and_record_checks_only };
/// Deliberately cannot stand in for public_replay.validate/recompute or a legacy
/// Header. Runtime semantics and resource/replay checks remain mandatory.
pub const SuccessfulTerminalFraming = struct {
    evidence_tier: EvidenceTier = .framing_and_record_checks_only,
    replay_validation_required: void = {},
    identity: Identity,
    recording_id: Hash,
    terminal_hash: Hash,
    total_inputs: u64,
    total_schedule: u64,
    total_frames: u64,
    total_bytes: u64,
};

/// Incremental arbitrary-byte parser, at most one frame returned per feed.
/// Advance the source by result.consumed and feed ALL remaining bytes. Call
/// finishAtEof ONLY on actual source EOF. Errors poison the parser, preventing
/// callers from repairing/skipping damaged data and certifying a suffix.
/// Storage is fixed metadata plus the borrowed local-capacity payload buffer.
pub const Validator = struct {
    limits: LocalLimits,
    scratch: []u8,
    prefix: [preamble_bytes]u8 = undefined,
    prefix_used: usize = 0,
    preamble: ?Preamble = null,
    header_bytes: [frame_header_bytes]u8 = undefined,
    header_used: usize = 0,
    header: ?FrameHeader = null,
    payload_used: usize = 0,
    next_sequence: u64 = 0,
    input_total: u64 = 0,
    schedule_total: u64 = 0,
    total_bytes: u64 = 0,
    previous_hash: Hash = undefined,
    inputs: InputChecks = .{},
    terminal: ?Terminal = null,
    poisoned: bool = false,
    eof: bool = false,

    pub fn init(scratch: []u8, limits: LocalLimits) Error!Validator {
        try limits.validate(scratch.len);
        return .{ .scratch = scratch[0..limits.max_frame_payload_bytes], .limits = limits };
    }
    pub fn feed(self: *Validator, bytes: []const u8) Error!FeedResult {
        if (self.poisoned or self.eof) return error.InvalidState;
        errdefer self.poisoned = true;
        if (self.terminal != null) {
            if (bytes.len != 0) return error.TrailingBytes;
            return .{ .consumed = 0 };
        }
        var consumed: usize = 0;
        if (self.preamble == null) {
            const n = @min(bytes.len, preamble_bytes - self.prefix_used);
            try self.charge(n);
            @memcpy(self.prefix[self.prefix_used..][0..n], bytes[0..n]);
            self.prefix_used += n;
            consumed += n;
            if (self.prefix_used != preamble_bytes) return .{ .consumed = consumed };
            self.preamble = try decodePreamble(&self.prefix);
            self.previous_hash = self.preamble.?.recording_id;
        }
        if (self.header == null) {
            const n = @min(bytes.len - consumed, frame_header_bytes - self.header_used);
            try self.charge(n);
            @memcpy(self.header_bytes[self.header_used..][0..n], bytes[consumed..][0..n]);
            self.header_used += n;
            consumed += n;
            if (self.header_used != frame_header_bytes) return .{ .consumed = consumed };
            var d: codec.Decoder = .{ .bytes = &self.header_bytes };
            const header = try d.get(FrameHeader);
            try d.finish();
            try self.checkHeader(header);
            self.header = header;
        }
        const header = self.header.?;
        const n = @min(bytes.len - consumed, header.payload_bytes - self.payload_used);
        try self.charge(n);
        @memcpy(self.scratch[self.payload_used..][0..n], bytes[consumed..][0..n]);
        self.payload_used += n;
        consumed += n;
        if (self.payload_used != header.payload_bytes) return .{ .consumed = consumed };
        const frame = try self.verifyFrame(header);
        if (self.terminal != null and consumed != bytes.len) return error.TrailingBytes;
        self.header_used = 0;
        self.header = null;
        self.payload_used = 0;
        return .{ .consumed = consumed, .frame = frame };
    }
    fn charge(self: *Validator, amount: usize) Error!void {
        const total = try add(self.total_bytes, @intCast(amount));
        if (total > self.limits.max_total_bytes) return error.WorkLimit;
        self.total_bytes = total;
    }
    fn checkHeader(self: *const Validator, header: FrameHeader) Error!void {
        if (!std.mem.eql(u8, &header.magic, "SMCF")) return error.InvalidMagic;
        if (header.version != container_version) return error.UnknownVersion;
        if (header.header_bytes != frame_header_bytes or header.flags != 0 or header.reserved != 0) return error.InvalidFrame;
        if (!std.mem.eql(u8, &header.recording_id, &self.preamble.?.recording_id) or !std.mem.eql(u8, &header.previous_hash, &self.previous_hash)) return error.InvalidChain;
        if (header.chunk_sequence != self.next_sequence or header.input_begin != self.input_total or header.schedule_begin != self.schedule_total) return error.InvalidOrder;
        const count = @as(u64, header.input_count) + header.schedule_count;
        if (count > max_chunk_records or header.input_count > max_chunk_records or header.schedule_count > max_chunk_records or header.payload_bytes > max_payload_bytes) return error.InvalidLength;
        if (count > self.limits.max_frame_records or header.payload_bytes > self.limits.max_frame_payload_bytes) return error.WorkLimit;
        if (header.payload_bytes > self.limits.max_total_bytes - self.total_bytes) return error.WorkLimit;
        const next = try add(self.next_sequence, 1);
        const inputs = try add(self.input_total, header.input_count);
        const schedule = try add(self.schedule_total, header.schedule_count);
        if (next > self.limits.max_frames or inputs > self.limits.max_total_inputs or schedule > self.limits.max_total_schedule) return error.WorkLimit;
        switch (header.kind) {
            .data => {
                if (count == 0 or header.payload_bytes < count * 5 or header.payload_bytes > count * (schema.max_record_bytes + 4)) return error.InvalidLength;
                _ = try add(next, 1);
                _ = try add(inputs, 1);
                if (next == self.limits.max_frames or inputs == self.limits.max_total_inputs) return error.WorkLimit;
            },
            .terminal => {
                if (header.input_count > 1 or header.schedule_count != 0 or header.payload_bytes < terminal_prefix_bytes or header.payload_bytes > terminal_prefix_bytes + 4 + schema.max_record_bytes) return error.InvalidTerminal;
            },
        }
    }
    fn verifyFrame(self: *Validator, header: FrameHeader) Error!VerifiedFrame {
        const payload = self.scratch[0..header.payload_bytes];
        const payload_hash = digest(payload_domain, payload, "");
        const chunk_hash = digest(frame_domain, self.header_bytes[0 .. frame_header_bytes - 32], payload);
        if (!std.mem.eql(u8, &payload_hash, &header.payload_hash) or !std.mem.eql(u8, &chunk_hash, &header.chunk_hash)) return error.HashMismatch;
        var checks = self.inputs;
        var d: codec.Decoder = .{ .bytes = payload };
        var terminal: ?Terminal = null;
        if (header.kind == .data) {
            for (0..header.input_count) |_| try checks.accept(try getRecord(schema.Input, &d), self.preamble.?.runtime_profile, false);
            for (0..header.schedule_count) |_| _ = try getRecord(schema.ScheduleEntry, &d);
        } else {
            terminal = try d.get(Terminal);
            const end: ?schema.Input = if (header.input_count == 1) try getRecord(schema.Input, &d) else null;
            try checkTerminal(terminal.?, end, self.preamble.?.runtime_profile, self.input_total, self.schedule_total, self.next_sequence);
            if (end) |input| try checks.accept(input, self.preamble.?.runtime_profile, true);
        }
        try d.finish();
        self.next_sequence = try add(self.next_sequence, 1);
        self.input_total = try add(self.input_total, header.input_count);
        self.schedule_total = try add(self.schedule_total, header.schedule_count);
        self.previous_hash = header.chunk_hash;
        self.inputs = checks;
        self.terminal = terminal;
        return .{ .header = header, .payload = payload, .terminal = terminal };
    }
    pub fn finishAtEof(self: *Validator) Error!SuccessfulTerminalFraming {
        if (self.poisoned or self.eof) return error.InvalidState;
        errdefer self.poisoned = true;
        self.eof = true;
        if (self.preamble == null or self.header_used != 0 or self.header != null or self.payload_used != 0) return error.Truncated;
        const terminal = self.terminal orelse return error.MissingTerminal;
        if (terminal.status != .complete) return error.RecorderIncomplete;
        return .{
            .identity = self.preamble.?.identity,
            .recording_id = self.preamble.?.recording_id,
            .terminal_hash = self.previous_hash,
            .total_inputs = self.input_total,
            .total_schedule = self.schedule_total,
            .total_frames = self.next_sequence,
            .total_bytes = self.total_bytes,
        };
    }
};
