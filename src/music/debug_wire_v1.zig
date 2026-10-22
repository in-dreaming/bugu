//! Length-delimited local debugger protocol. No native struct/usize/pointer dump.
//! Reuses the canonical typed trace codec; owned status has an explicit byte ABI.
const std = @import("std");
const music = @import("api.zig");
pub const observer = @import("runtime_observer.zig");
const trace = @import("sme-trace");
const codec = trace.codec;

pub const major: u16 = 1;
pub const minor: u16 = 0;
pub const prefix_bytes: usize = 40;
pub const max_request_bytes: usize = prefix_bytes + 18;
pub const max_response_bytes: usize = prefix_bytes + 512 + observer.record_capacity * (17 + trace.schema.max_record_bytes);
pub const supported_sections: u64 = 7; // status, canonical inputs, canonical schedule
pub const Nonce = [16]u8;
pub const zero_nonce: Nonce = @splat(0);
pub const Kind = enum(u16) { hello = 1, poll = 2, bye = 3, welcome = 129, empty = 130, frame = 131, closed = 132, bye_ack = 133, rejected = 255 };
pub const Reject = enum(u16) { protocol_version = 1, observer_version = 2, trace_version = 3, capability = 4, message_size = 5, order = 6, nonce = 7, unsupported_request = 8 };
pub const Envelope = struct { kind: Kind, payload_bytes: u32, request_sequence: u64, nonce: Nonce };
pub const Hello = struct { protocol_minor: u16 = minor, observer_version: u16 = 1, trace_version: u16 = trace.schema.version, max_response_bytes: u32 = max_response_bytes, required_sections: u64 = supported_sections };
pub const Welcome = struct {
    protocol_minor: u16,
    observer_version: u16,
    trace_version: u16,
    max_response_bytes: u32,
    supported_sections: u64,
    subscription: observer.Handle,
    transport_dropped_frames: u64,
};
pub const DecodedFrame = struct { transport_dropped_frames: u64 };
pub const DecodedFooter = struct { footer: observer.Footer, transport_dropped_frames: u64 };

// Fixed scalar status layout, including a present BankRefV1 and its explicit
// index/generation fields. Reserved fixed-header budget is checked at compile.
const max_status_bytes = 2 + 8 + 1 + 1 + codec.maxSize(?music.MusicBankRefV1) + 32 + 8 + 8 + 8 + 8 + 1 + 8 + 8 + 1 + 8;
const max_frame_header_bytes = 8 + 2 + codec.maxSize(observer.Handle) + 8 + 1 + 9 + max_status_bytes + 8 + 8 + 8 + 2 + 8 + codec.maxSize(observer.Loss) + 1;
comptime {
    @setEvalBranchQuota(40_000);
    if (max_frame_header_bytes > 512) @compileError("local observer header exceeds reserved byte budget");
    if (codec.maxSize(trace.Input) > trace.schema.max_record_bytes or codec.maxSize(trace.ScheduleEntry) > trace.schema.max_record_bytes)
        @compileError("observer trace extension exceeds the frozen local message bound");
}

pub fn encodeEnvelope(output: []u8, envelope: Envelope) !void {
    if (output.len < prefix_bytes) return error.BufferTooSmall;
    var encoder: codec.Encoder = .{ .bytes = output[0..prefix_bytes] };
    try encoder.put(@as([8]u8, "SMEDBG01".*));
    try encoder.put(major);
    try encoder.put(@intFromEnum(envelope.kind));
    try encoder.put(envelope.payload_bytes);
    try encoder.put(envelope.request_sequence);
    try encoder.put(envelope.nonce);
    std.debug.assert(encoder.offset == prefix_bytes);
}
pub fn decodeEnvelope(input: []const u8, max_total_bytes: usize) !Envelope {
    if (input.len != prefix_bytes) return error.InvalidLength;
    var decoder: codec.Decoder = .{ .bytes = input };
    const magic = try decoder.get([8]u8);
    if (!std.mem.eql(u8, &magic, "SMEDBG01")) return error.InvalidMagic;
    if (try decoder.get(u16) != major) return error.ProtocolVersionMismatch;
    const kind = try decoder.get(Kind);
    const payload = try decoder.get(u32);
    if (max_total_bytes < prefix_bytes or payload > max_total_bytes - prefix_bytes) return error.MessageTooLarge;
    const sequence = try decoder.get(u64);
    if (sequence == 0) return error.InvalidOrder;
    const nonce = try decoder.get(Nonce);
    try decoder.finish();
    return .{ .kind = kind, .payload_bytes = payload, .request_sequence = sequence, .nonce = nonce };
}
pub fn encodeRequest(output: []u8, kind: Kind, sequence: u64, nonce: Nonce, hello: ?Hello) ![]const u8 {
    var encoder: codec.Encoder = .{ .bytes = if (output.len >= prefix_bytes) output[prefix_bytes..] else return error.BufferTooSmall };
    switch (kind) {
        .hello => try encoder.put(hello orelse return error.InvalidLength),
        .poll, .bye => if (hello != null) return error.InvalidLength,
        else => return error.UnsupportedRequest,
    }
    try encodeEnvelope(output, .{ .kind = kind, .payload_bytes = @intCast(encoder.offset), .request_sequence = sequence, .nonce = nonce });
    return output[0 .. prefix_bytes + encoder.offset];
}
pub fn decodeHello(payload: []const u8) !Hello {
    var decoder: codec.Decoder = .{ .bytes = payload };
    const value = try decoder.get(Hello);
    try decoder.finish();
    return value;
}
pub fn validateHello(value: Hello) ?Reject {
    if (value.protocol_minor != minor) return .protocol_version;
    if (value.observer_version != observer.version) return .observer_version;
    if (value.trace_version != trace.schema.version) return .trace_version;
    if (value.required_sections & ~supported_sections != 0) return .capability;
    if (value.max_response_bytes < max_response_bytes) return .message_size;
    return null;
}
pub fn encodeWelcome(output: []u8, value: Welcome) !usize {
    var encoder: codec.Encoder = .{ .bytes = output };
    try encoder.put(value);
    return encoder.offset;
}
pub fn decodeWelcome(input: []const u8) !Welcome {
    var decoder: codec.Decoder = .{ .bytes = input };
    const value = try decoder.get(Welcome);
    try decoder.finish();
    if (value.protocol_minor != minor) return error.ProtocolVersionMismatch;
    if (value.observer_version != observer.version) return error.SnapshotVersionMismatch;
    if (value.trace_version != trace.schema.version) return error.TraceVersionMismatch;
    if (value.max_response_bytes != max_response_bytes or value.supported_sections != supported_sections) return error.UnsupportedCapability;
    try validateHandle(value.subscription);
    return value;
}
fn validateHandle(value: observer.Handle) !void {
    if (value.context == 0 or value.storage_id == 0 or value.incarnation == 0) return error.StaleObserver;
}
fn putStatus(encoder: *codec.Encoder, status: music.MusicRuntimeStatusV1) !void {
    try encoder.put(status.version);
    try encoder.put(status.context);
    const kind: u8 = switch (status.kind) { .shipping_game => 0, .authoring => 1, .offline => 2, .debug => 3 };
    const state: u8 = switch (status.state) {
        .uninitialized => 0, .loading_bank => 1, .ready => 2, .starting => 3, .playing => 4,
        .paused => 5, .stopping => 6, .shutting_down => 7, .destroyed => 8,
    };
    try encoder.put(kind);
    try encoder.put(state);
    try encoder.put(status.bank);
    try encoder.put(status.bank_content_hash);
    try encoder.put(@intFromEnum(status.committed_state));
    try encoder.put(@intFromEnum(status.committed_segment));
    try encoder.put(status.render_frame);
    try encoder.put(status.transport_epoch);
    try encoder.put(status.pending);
    try encoder.put(status.outstanding_sample_leases);
    try encoder.put(status.observation_sequence);
    try encoder.put(status.complete);
    try encoder.put(status.dropped_observations);
}
fn getStatus(decoder: *codec.Decoder) !music.MusicRuntimeStatusV1 {
    const version = try decoder.get(u16);
    if (version != 1) return error.SnapshotVersionMismatch;
    const context = try decoder.get(u64);
    if (context == 0) return error.InvalidStatus;
    const kind: music.MusicContextKind = switch (try decoder.get(u8)) { 0 => .shipping_game, 1 => .authoring, 2 => .offline, 3 => .debug, else => return error.InvalidEnum };
    const state: music.MusicRuntimeState = switch (try decoder.get(u8)) {
        0 => .uninitialized, 1 => .loading_bank, 2 => .ready, 3 => .starting, 4 => .playing,
        5 => .paused, 6 => .stopping, 7 => .shutting_down, 8 => .destroyed, else => return error.InvalidEnum,
    };
    const bank = try decoder.get(?music.MusicBankRefV1);
    if (bank) |value| if (value.context != context or !value.handle.isValid() or value.asset_generation == 0) return error.InvalidStatus;
    return .{ .version = version, .context = context, .kind = kind, .state = state, .bank = bank,
        .bank_content_hash = try decoder.get([32]u8), .committed_state = @enumFromInt(try decoder.get(u64)),
        .committed_segment = @enumFromInt(try decoder.get(u64)), .render_frame = try decoder.get(u64),
        .transport_epoch = try decoder.get(u64), .pending = try decoder.get(bool),
        .outstanding_sample_leases = try decoder.get(u64), .observation_sequence = try decoder.get(u64),
        .complete = try decoder.get(bool), .dropped_observations = try decoder.get(u64) };
}
pub fn encodeFrame(output: []u8, frame: *const observer.Frame, transport_drops: u64) !usize {
    const header = frame.header;
    if (header.record_count > observer.record_capacity or !std.meta.eql(header.sections, observer.Sections{})) return error.UnsupportedCapability;
    var encoder: codec.Encoder = .{ .bytes = output };
    try encoder.put(transport_drops);
    try encoder.put(header.version);
    try encoder.put(header.subscription);
    try encoder.put(header.sequence);
    try encoder.put(header.operation);
    try encoder.put(header.control_tick);
    try putStatus(&encoder, header.status);
    try encoder.put(supported_sections);
    try encoder.put(header.input_begin);
    try encoder.put(header.schedule_begin);
    try encoder.put(@as(u16, @intCast(header.record_count)));
    try encoder.put(header.offered_records);
    try encoder.put(header.loss);
    try encoder.put(header.canonical_history_incomplete);
    for (0..header.record_count) |i| {
        const row = frame.records[i] orelse return error.InvalidLength;
        try encoder.put(row.sequence);
        try encoder.put(row.source_ordinal);
        switch (row.fact) {
            .input => |fact| { try encoder.put(@as(u8, 1)); try encoder.put(fact); },
            .schedule => |fact| { try encoder.put(@as(u8, 2)); try encoder.put(fact); },
        }
    }
    return encoder.offset;
}
/// Decodes into a caller-owned scratch Frame. On failure it is partial and must
/// not replace a visible model. No maximal Frame by-value return or allocation.
pub fn decodeFrame(input: []const u8, output: *observer.Frame) !DecodedFrame {
    var decoder: codec.Decoder = .{ .bytes = input };
    const transport_drops = try decoder.get(u64);
    output.header.version = try decoder.get(u16);
    if (output.header.version != observer.version) return error.SnapshotVersionMismatch;
    output.header.owned_value_bytes = @sizeOf(observer.Frame); // Local ABI only.
    output.header.subscription = try decoder.get(observer.Handle);
    try validateHandle(output.header.subscription);
    output.header.sequence = try decoder.get(u64);
    output.header.operation = try decoder.get(observer.Operation);
    output.header.control_tick = try decoder.get(?u64);
    output.header.status = try getStatus(&decoder);
    if (output.header.status.context != output.header.subscription.context) return error.InvalidStatus;
    if (try decoder.get(u64) != supported_sections) return error.UnsupportedCapability;
    output.header.sections = .{};
    output.header.input_begin = try decoder.get(u64);
    output.header.schedule_begin = try decoder.get(u64);
    output.header.record_count = try decoder.get(u16);
    if (output.header.record_count > observer.record_capacity) return error.InvalidLength;
    output.header.offered_records = try decoder.get(u64);
    output.header.loss = try decoder.get(observer.Loss);
    output.header.canonical_history_incomplete = try decoder.get(bool);
    for (&output.records) |*row| row.* = null;
    var previous: u64 = 0;
    for (0..output.header.record_count) |i| {
        const sequence = try decoder.get(u64);
        if (sequence <= previous or sequence > output.header.offered_records) return error.InvalidOrder;
        previous = sequence;
        const ordinal = try decoder.get(u64);
        const fact: @FieldType(observer.Record, "fact") = switch (try decoder.get(u8)) {
            1 => .{ .input = try decoder.get(trace.Input) },
            2 => .{ .schedule = try decoder.get(trace.ScheduleEntry) },
            else => return error.InvalidEnum,
        };
        switch (fact) {
            .input => |value| { if (ordinal < output.header.input_begin) return error.InvalidOrder; try value.validate(); },
            .schedule => |value| { if (ordinal < output.header.schedule_begin) return error.InvalidOrder; try value.validate(); },
        }
        output.records[i] = .{ .sequence = sequence, .source_ordinal = ordinal, .fact = fact };
    }
    if (output.header.sequence == 0 or (output.header.operation == .control_tick) != (output.header.control_tick != null)) return error.InvalidOrder;
    try decoder.finish();
    return .{ .transport_dropped_frames = transport_drops };
}
pub fn encodeFooter(output: []u8, footer: observer.Footer, transport_drops: u64) !usize {
    var encoder: codec.Encoder = .{ .bytes = output };
    try encoder.put(transport_drops);
    try encoder.put(footer.version);
    try encoder.put(footer.subscription);
    try encoder.put(footer.reason);
    try encoder.put(footer.attempted_publications);
    try encoder.put(footer.offered_records);
    try putStatus(&encoder, footer.last_status);
    try encoder.put(footer.loss);
    try encoder.put(footer.canonical_history_incomplete);
    return encoder.offset;
}
pub fn decodeFooter(input: []const u8) !DecodedFooter {
    var decoder: codec.Decoder = .{ .bytes = input };
    const drops = try decoder.get(u64);
    const version = try decoder.get(u16);
    if (version != observer.version) return error.SnapshotVersionMismatch;
    const handle = try decoder.get(observer.Handle);
    try validateHandle(handle);
    const reason = try decoder.get(observer.CloseReason);
    const attempts = try decoder.get(u64);
    const offered = try decoder.get(u64);
    const status = try getStatus(&decoder);
    if (status.context != handle.context) return error.InvalidStatus;
    const loss = try decoder.get(observer.Loss);
    const incomplete = try decoder.get(bool);
    try decoder.finish();
    return .{ .transport_dropped_frames = drops, .footer = .{ .version = version, .subscription = handle,
        .reason = reason, .attempted_publications = attempts, .offered_records = offered,
        .last_status = status, .loss = loss, .canonical_history_incomplete = incomplete } };
}
