//! Opt-in offline diagnostic. Canonical native representatives, not recovered
//! original native padding or producer timing. No Host/device and no admission claim.
const std = @import("std");
const audio = @import("bugu_audio");
const codec = @import("sme-live-codec");
const recording = @import("sme-author-live-owner").semantic_recording;
const f = codec.format;
const t = std.testing;
const a = t.allocator;
const Record = struct { native: f.NativeRecord, wire: []const u8, frame: []const u8 };
const Sink = struct {
    bytes: []u8,
    used: usize = 0,
    fn write(raw: *anyopaque, bytes: []const u8) !usize {
        const self: *Sink = @ptrCast(@alignCast(raw));
        if (bytes.len > self.bytes.len - self.used) return error.OutOfSpace;
        @memcpy(self.bytes[self.used..][0..bytes.len], bytes);
        self.used += bytes.len;
        return bytes.len;
    }
};
fn audioEvent(payload: []const u8) ![]u8 {
    const T = audio.device.SemanticAudioEvent;
    var d: codec.Decoder = .{ .wire = .{ .bytes = payload } };
    const occurrence = try d.get(u64);
    const tag = try d.get(std.meta.Tag(T));
    const value: T = switch (tag) {
        .callback_return => blk: {
            const kind = try d.get(@FieldType(@FieldType(T, "callback_return"), "kind"));
            if (try d.get(bool)) return error.UnsupportedRecordedFailure;
            break :blk .{ .callback_return = .{ .kind = kind, .failure = null, .accounting = try d.get(audio.device.RuntimeAccounting) } };
        },
        inline else => |tag_value| @unionInit(T, @tagName(tag_value), try d.get(@FieldType(T, @tagName(tag_value)))),
    };
    try d.wire.finish();
    const native: codec.Native(T) = .{ .occurrence = occurrence, .value = value };
    return a.dupe(u8, std.mem.asBytes(&native));
}
fn uint(d: *f.Decoder) !u64 {
    var value: u64 = 0;
    for (0..10) |i| {
        const byte = try d.int(u8);
        const low: u64 = byte & 0x7f;
        if (i == 9 and (low > 1 or byte & 0x80 != 0)) return error.CounterOverflow;
        value |= low << @as(u6, @intCast(i * 7));
        if (byte & 0x80 == 0) {
            if (i != 0 and low == 0) return error.Noncanonical;
            return value;
        }
    }
    return error.CounterOverflow;
}
fn input(d: *f.Decoder) !codec.PacketInput {
    var v: codec.PacketInput = .{
        .occurrence = try uint(d),
        .site = std.enums.fromInt(codec.cuts.Site, try d.int(u16)) orelse return error.InvalidEnum,
        .edge = std.enums.fromInt(codec.cuts.Edge, try d.int(u8)) orelse return error.InvalidEnum,
        .index = try uint(d),
        .generation = try uint(d),
        .publication_prefix = try uint(d),
    };
    const present = try d.int(u8);
    const eligible = try d.int(u8);
    if (present > 1 or eligible > 1 or (present == 0 and eligible != 0)) return error.Noncanonical;
    v.job_scan_eligible = if (present == 1) eligible == 1 else null;
    // Worker/Control raw job states are not recoverable from projected eligibility.
    // They are outside this Render-only diagnostic; do not synthesize those states.
    if (v.site == .service_worker_scan or v.site == .service_acceptance_scan) return error.UnsupportedProjection;
    return v;
}
fn typed(comptime T: type, payload: []const u8) ![]u8 {
    const value = try codec.decode(codec.Native(T), payload);
    return a.dupe(u8, std.mem.asBytes(&value));
}
fn reconstruct(family: codec.Family, payload: []const u8, first: *usize) ![]u8 {
    switch (family) {
        .point_packet_input, .point_packet_reference => {
            var d: f.Decoder = .{ .bytes = payload };
            const count = try d.int(u16);
            if (count == 0 or count > codec.max_packet_points) return error.InvalidLength;
            const size: usize = if (family == .point_packet_input) @sizeOf(codec.PacketInput) else @sizeOf(codec.PacketReference);
            first.* = @sizeOf(codec.PacketHeader);
            const bytes = try a.alloc(u8, first.* + count * size);
            errdefer a.free(bytes);
            const header: codec.PacketHeader = .{ .count = count };
            @memcpy(bytes[0..first.*], std.mem.asBytes(&header));
            for (0..count) |i| {
                const v = try input(&d);
                const target = bytes[first.* + i * size ..][0..size];
                if (family == .point_packet_input) {
                    @memcpy(target, std.mem.asBytes(&v));
                } else {
                    const present = try d.int(u8);
                    const bits = try uint(&d);
                    if (present > 1 or (present == 0 and bits != 0)) return error.Noncanonical;
                    const ref: codec.PacketReference = .{ .input = v, .value = if (present == 1) bits else null };
                    @memcpy(target, std.mem.asBytes(&ref));
                }
            }
            try d.finish();
            return bytes;
        },
        .pcm => {
            var d: codec.Decoder = .{ .wire = .{ .bytes = payload } };
            const header = try d.get(codec.Native(codec.Pcm));
            first.* = @sizeOf(@TypeOf(header));
            if (header.value.samples > f.max_payload / 4) return error.InvalidLength;
            const bytes = try a.alloc(u8, first.* + header.value.samples * 4);
            errdefer a.free(bytes);
            @memcpy(bytes[0..first.*], std.mem.asBytes(&header));
            for (0..header.value.samples) |i| {
                const bits = try d.wire.int(u32);
                @memcpy(bytes[first.* + i * 4 ..][0..4], std.mem.asBytes(&bits));
            }
            try d.wire.finish();
            return bytes;
        },
        else => {
            const bytes = switch (family) {
                .cut => try typed(codec.Cut, payload),
                .cut_fact => try typed(codec.cuts.Point, payload),
                .boundary => try typed(codec.Boundary, payload),
                .boundary_fact => try typed(codec.cuts.BoundaryPoint, payload),
                .callback => try typed(codec.Callback, payload),
                .event_cut => try typed(codec.EventCut, payload),
                .exclusion_claim => try typed(bool, payload),
                .audio_event => try audioEvent(payload),
                else => {
                    std.debug.print("unsupported Render family={d}\n", .{@intFromEnum(family)});
                    return error.UnsupportedRenderFamily;
                },
            };
            first.* = bytes.len;
            return bytes;
        },
    }
}
fn elapsed(start: std.Io.Timestamp) !u64 {
    const ns = start.durationTo(std.Io.Clock.awake.now(t.io)).nanoseconds;
    if (ns <= 0 or ns > std.math.maxInt(u64)) return error.ClockUnavailable;
    return @intCast(ns);
}
test "recorded Render canonical roundtrip and fixed encode copy measurements" {
    const path = std.process.Environ.getPosix(t.environ, "SME_RENDER_TAPE") orelse return error.SkipZigTest;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(t.io, path, a, .limited(f.max_file_bytes));
    defer a.free(bytes);
    if (bytes.len < f.header_size) return error.Truncated;
    try t.expectEqualSlices(u8, f.magic, bytes[0..8]);
    try t.expectEqualSlices(u8, &f.hash(bytes[0..160]), bytes[160..192]);
    var h: f.Decoder = .{ .bytes = bytes };
    _ = try h.raw(8);
    try t.expectEqual(f.profile_id, try h.int(u16));
    try t.expectEqual(f.wire_version, try h.int(u16));
    try t.expectEqual(f.header_size, try h.int(u16));
    try t.expectEqual(@as(u16, 0), try h.int(u16));
    const bound = try h.int(u64);
    try t.expectEqual(f.max_payload, try h.int(u32));
    try t.expectEqual(f.role_count, try h.int(u16));
    try t.expectEqual(@as(u16, 0), try h.int(u16));
    var identity: f.Identity = undefined;
    inline for (.{ "build", "bank", "config", "source" }) |name| @memcpy(&@field(identity, name), try h.raw(32));
    const sealed = bytes.len >= f.header_size + f.trailer_size and std.mem.eql(u8, bytes[bytes.len - f.trailer_size ..][0..8], "SMELEND1");
    if (sealed) _ = try f.Reader.preflight(bytes, identity, codec.validate);
    const end = if (sealed) bytes.len - f.trailer_size else bytes.len;
    var records: std.ArrayList(Record) = .empty;
    defer {
        for (records.items) |r| a.free(r.native.bytes);
        records.deinit(a);
    }
    var offset: usize = f.header_size;
    var counts: [120]u64 = @splat(0);
    var native_bytes: [120]u64 = @splat(0);
    var wire_bytes: [120]u64 = @splat(0);
    var ordinals: [4]u64 = @splat(0);
    var scratch: [f.max_payload]u8 = undefined;
    while (end - offset >= f.frame_header_size) {
        var d: f.Decoder = .{ .bytes = bytes[offset..end] };
        try t.expectEqualSlices(u8, "EVT1", try d.raw(4));
        const length = try d.int(u32);
        if (length < f.frame_header_size or length > f.frame_header_size + f.max_payload) return error.InvalidLength;
        if (length > end - offset) break;
        const role = std.enums.fromInt(f.Role, try d.int(u8)) orelse return error.Noncanonical;
        const class = std.enums.fromInt(f.Class, try d.int(u8)) orelse return error.Noncanonical;
        const family = try d.int(u16);
        if (!codec.validate(family, class)) return error.UnsupportedFamily;
        try t.expectEqual(@as(u32, 0), try d.int(u32));
        const ordinal = try d.int(u64);
        try t.expectEqual(ordinals[@intFromEnum(role)] + 1, ordinal);
        ordinals[@intFromEnum(role)] = ordinal;
        const size = try d.int(u32);
        try t.expectEqual(length - f.frame_header_size, size);
        try t.expectEqual(@as(u32, 0), try d.int(u32));
        const hash = try d.raw(32);
        const payload = try d.raw(size);
        try t.expectEqualSlices(u8, hash, &f.hash(payload));
        if (role == .render) {
            var first: usize = 0;
            const native = try reconstruct(@enumFromInt(family), payload, &first);
            errdefer a.free(native);
            const r: f.NativeRecord = .{ .role = role, .class = class, .family = family, .ordinal = ordinal, .bytes = native, .first_len = first };
            try t.expectEqualSlices(u8, payload, try codec.encodeNative(r, &scratch));
            try records.append(a, .{ .native = r, .wire = payload, .frame = bytes[offset..][0..length] });
            counts[family] += 1;
            native_bytes[family] += native.len;
            wire_bytes[family] += payload.len;
        }
        offset += length;
    }
    if (sealed) try t.expectEqual(end, offset);
    try t.expect(records.items.len > 0);
    const lane = try a.create(f.Lane);
    defer a.destroy(lane);
    // Verify actual queue copies preserve every native byte before timed work.
    lane.init(.render, codec.validate);
    for (records.items) |r| {
        try t.expect(lane.push(r.native.family, r.native.class, r.native.first(), r.native.second()));
        const popped = (try lane.pop(&scratch)).?;
        try t.expectEqualSlices(u8, r.native.bytes, popped.bytes);
        try t.expectEqual(r.native.first_len, popped.first_len);
    }
    std.debug.print("RENDER_CORPUS records={d} complete_all_roles={any} sealed={} excluded_tail={d} caller={s} codec={s} hash_backend={s} roundtrip=true native_original=false\n", .{ records.items.len, ordinals, sealed, end - offset, @tagName(@import("builtin").mode), @tagName(codec.compilation_mode), @tagName(f.IntegrityHash.backendMode()) });
    const recorder_only = std.process.Environ.getPosix(t.environ, "SME_RENDER_RECORDER_ONLY") != null;
    if (!recorder_only) for (counts, 0..) |count, family| {
        if (count == 0) continue;
        var selected: std.ArrayList(Record) = .empty;
        defer selected.deinit(a);
        for (records.items) |r| if (r.native.family == family) {
            try selected.append(a, r);
        };
        var encode_ns: [3]u64 = undefined;
        var copy_ns: [3]u64 = undefined;
        for (0..3) |round| {
            var encoded_bytes: usize = 0;
            var start = std.Io.Clock.awake.now(t.io);
            for (selected.items) |r| {
                const output = try codec.encodeNative(r.native, &scratch);
                std.mem.doNotOptimizeAway(output);
                encoded_bytes += output.len;
            }
            encode_ns[round] = try elapsed(start);
            try t.expectEqual(wire_bytes[family], encoded_bytes);
            lane.init(.render, codec.validate);
            var copied_bytes: usize = 0;
            start = std.Io.Clock.awake.now(t.io);
            for (selected.items) |r| {
                if (!lane.push(r.native.family, r.native.class, r.native.first(), r.native.second())) return error.QueueRejected;
                const popped = (try lane.pop(&scratch)) orelse return error.QueueEmpty;
                std.mem.doNotOptimizeAway(popped.bytes);
                copied_bytes += popped.bytes.len;
            }
            copy_ns[round] = try elapsed(start);
            try t.expectEqual(native_bytes[family], copied_bytes);
        }
        std.debug.print("RENDER_FAMILY family={d} count={d} native_bytes={d} wire_bytes={d} encode_ns={any} push_pop_ns={any}\n", .{ family, count, native_bytes[family], wire_bytes[family], encode_ns, copy_ns });
    };
    var append_bytes: usize = f.header_size;
    for (records.items) |r| append_bytes += r.frame.len;
    const storage = try a.alloc(u8, append_bytes);
    defer a.free(storage);
    var append_ns: [3]u64 = undefined;
    if (!recorder_only) for (0..3) |round| {
        var sink: Sink = .{ .bytes = storage };
        var writer = try f.StreamingWriter.init(.{ .context = &sink, .write = Sink.write }, bound, identity, codec.validate);
        const start = std.Io.Clock.awake.now(t.io);
        for (records.items) |r| try writer.append(r.native.role, r.native.ordinal, r.native.family, r.native.class, r.wire);
        append_ns[round] = try elapsed(start);
        try t.expectEqual(append_bytes, sink.used);
        try t.expectEqualSlices(u8, bytes[0..f.header_size], storage[0..f.header_size]);
        var cursor: usize = f.header_size;
        for (records.items) |r| {
            try t.expectEqualSlices(u8, r.frame, storage[cursor..][0..r.frame.len]);
            cursor += r.frame.len;
        }
    };
    if (!recorder_only) std.debug.print("RENDER_APPEND frames_bytes={d} append_ns={any} exact_frame_projection=true\n", .{ append_bytes - f.header_size, append_ns });
    if (recorder_only) {
        const recorder = try a.create(recording.Recorder);
        defer a.destroy(recorder);
        const profile = try a.create(recording.collector_profile.Profile);
        defer a.destroy(profile);
        inline for (.{ false, true }) |profiling| {
            var full_ns: [3]u64 = undefined;
            for (0..3) |round| {
                recorder.address = null;
                recorder.session = .{};
                profile.* = .init(t.io);
                var sink: Sink = .{ .bytes = storage };
                try recorder.initStreaming(identity, .{ .context = &sink, .write = Sink.write }, bound, storage.len + @sizeOf(Sink) + @sizeOf(recording.collector_profile.Profile));
                if (profiling) recorder.test_collector_profile = profile;
                const start = std.Io.Clock.awake.now(t.io);
                // One-record injection bounds occupancy without changing capacity.
                // Includes producer push and4-lane drain; other roles remain empty.
                for (records.items) |r| {
                    if (!recorder.capture.lane(.render).push(r.native.family, r.native.class, r.native.first(), r.native.second())) return error.QueueRejected;
                    if (!try recorder.drainStreaming()) return error.QueueEmpty;
                }
                full_ns[round] = try elapsed(start);
                try t.expect(recorder.healthy());
                try t.expect(recorder.session.host == null);
                try t.expectEqual(append_bytes, sink.used);
                try t.expectEqualSlices(u8, bytes[0..f.header_size], storage[0..f.header_size]);
                var cursor: usize = f.header_size;
                for (records.items) |r| {
                    try t.expectEqualSlices(u8, r.frame, storage[cursor..][0..r.frame.len]);
                    cursor += r.frame.len;
                }
                const stats = recorder.capture.lane(.render).finalStats();
                try t.expectEqual(records.items.len, stats.produced);
                try t.expectEqual(records.items.len, stats.consumed);
                try t.expectEqual(@as(u64, 0), stats.queued_bytes);
                if (profiling) {
                    try t.expectEqual(records.items.len, profile.report.roles[2].metrics.appended_records);
                    try t.expectEqual(@as(u64, 0), profile.report.failed_passes);
                }
            }
            std.debug.print("RENDER_RECORDER profiling={} push_drain_ns={any} exact_frame_projection=true observe=true queue_peak_records=1 other_roles_empty=true finish_called=false\n", .{ profiling, full_ns });
        }
    }
}
