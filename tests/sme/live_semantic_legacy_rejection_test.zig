//! Reciprocal wire separation only, not Host lifecycle or replay admission.
//! The unchanged profile-9 bytes first pass the production framing reader and
//! canonical PCM-reference validator. No legacy magic/profile is patched in.
const std = @import("std");
const music = @import("music");
const live = @import("sme-author-live-owner");
const format = music.LiveSemanticFormat;
const codec = live.semantic_recording.codec;
const trace = music.trace;
const chunks = trace.chunks;
const source = music.PublicReplayV1.ChunkSource;
const causal = music.CausalRecordingFormatV1;
const t = std.testing;

// One reference is enough. Include enough zero samples that the causal reader
// receives its full fixed header, so its rejection is not just truncation.
const sample_count = ((causal.header_bytes + 7) / 8) * 2;
const payload_capacity = 64 + sample_count * 4;
const capacity = format.header_size + format.frame_header_size + payload_capacity + format.trailer_size;

fn identity() format.Identity {
    return .{ .build = @splat(1), .bank = @splat(2), .config = @splat(3), .source = @splat(4) };
}

fn envelope(storage: []u8) ![]const u8 {
    var payload: [payload_capacity]u8 = @splat(0);
    const pcm: codec.Native(codec.Pcm) = .{ .occurrence = 1, .value = .{
        .disposition = .submitted,
        .device_epoch = 1,
        .first_frame = 0,
        .channels = 2,
        .samples = @intCast(sample_count),
    } };
    const prefix = try codec.encode(pcm, .reference, &payload);
    const length = prefix.len + sample_count * 4;
    var writer = try format.Writer.init(storage, identity(), codec.validate);
    try writer.append(.render, 1, @intFromEnum(codec.Family.pcm), .reference, payload[0..length]);
    const bytes = try writer.sealFraming(.{ .role_counts = .{ 0, 0, 1, 0 }, .closed_roles = .{ true, true, true, true }, .healthy = true });
    try t.expectEqualSlices(u8, "SMELSB01\x09\x00\x02\x00", bytes[0..12]);
    try t.expect(bytes.len >= causal.header_bytes);
    const reader = try format.Reader.preflight(bytes, identity(), codec.validate);
    try t.expectEqual(@as(u64, 1), reader.counts.total);
    var references = reader.comparison(.render);
    try codec.validateReference((try references.next()).?);
    try references.finish();
    return bytes;
}

const Memory = struct {
    bytes: []const u8,
    calls: usize = 0,

    fn immutable(self: *Memory) source.ImmutableSource {
        return .{ .context = self, .byte_length = @intCast(self.bytes.len), .read_at = readAt };
    }

    fn readAt(context: *anyopaque, offset: u64, output: []u8) anyerror!usize {
        const self: *Memory = @ptrCast(@alignCast(context));
        self.calls += 1;
        if (offset >= self.bytes.len) return 0;
        const start: usize = @intCast(offset);
        const length = @min(output.len, self.bytes.len - start);
        @memcpy(output[0..length], self.bytes[start..][0..length]);
        return length;
    }
};

fn limits() source.Limits {
    return .{
        .container = .{ .max_total_inputs = 8, .max_total_schedule = 8, .max_frames = 8, .max_total_bytes = capacity, .max_frame_payload_bytes = 512 },
        .max_read_calls = capacity,
        .max_parser_calls = capacity,
        .max_record_visits = 16,
        .max_operation_records = 8,
        .max_operations = 8,
        .max_rendered_frames = 1024,
    };
}

test "valid profile9 envelope is rejected by legacy retained Input and Schedule readers" {
    var storage: [capacity]u8 = undefined;
    const bytes = try envelope(&storage);
    try t.expectError(error.InvalidMagic, trace.decode(trace.Input, t.allocator, bytes, 8));
    try t.expectError(error.InvalidMagic, trace.decode(trace.ScheduleEntry, t.allocator, bytes, 8));
}

test "valid profile9 envelope is rejected by shared legacy chunk framing and public source readers" {
    var storage: [capacity]u8 = undefined;
    const bytes = try envelope(&storage);
    // Profiles 2/3/4/7 all use this unchanged preamble decoder. Its strict
    // enum decoder rejects the new prefix before legacy magic validation.
    try t.expectError(error.InvalidEnum, chunks.decodePreamble(bytes[0..chunks.preamble_bytes]));
    var io: [37]u8 = undefined;
    var payload: [512]u8 = undefined;
    const scratch: source.Scratch = .{ .io = &io, .payload = &payload };
    var serial: Memory = .{ .bytes = bytes };
    try t.expectError(error.InvalidEnum, source.preflight(serial.immutable(), scratch, limits()));
    try t.expect(serial.calls > 1);
    var context: Memory = .{ .bytes = bytes };
    try t.expectError(error.InvalidEnum, source.preflightWithContextCalls(context.immutable(), scratch, limits()));
    try t.expect(context.calls > 1);
}

test "valid profile9 envelope is rejected by the legacy causal header reader" {
    var storage: [capacity]u8 = undefined;
    const bytes = try envelope(&storage);
    // Profiles 5/6 share this fixed header reader. Feed the genuine complete
    // prefix it reads from a file, rather than a short or numerically relabeled
    // old header. The remaining zero PCM bytes are still in the valid envelope.
    try t.expectError(error.InvalidHeader, causal.decodeHeader(bytes[0..causal.header_bytes]));
}

test "valid profile9 envelope is rejected by the reserved profile8 chronology reader" {
    const chronology = music.live_tick_capture.format;
    var storage: [capacity]u8 = undefined;
    const bytes = try envelope(&storage);
    try t.expect(bytes.len >= chronology.header_size);
    const expected: chronology.grammar.Identity = .{
        .session = @splat(1),
        .bank = @splat(2),
        .build = @splat(3),
        .sources = @splat(@as(chronology.grammar.Hash, @splat(4))),
    };
    // Give the existing decoder its complete fixed-size header prefix from
    // the unchanged valid profile-9 envelope, not a truncated or relabeled file.
    try t.expectError(error.Unsupported, chronology.Decoder.init(bytes[0..chronology.header_size], expected, .{
        .max_bytes = capacity,
        .max_records = 8,
    }));
}
