const std = @import("std");
const f = @import("music").LiveSemanticFormat;
const t = std.testing;

fn valid(family: u16, class: f.Class) bool {
    return switch (family) {
        1, 2 => class == .input,
        100, 101 => class == .reference,
        else => false,
    };
}
fn identity() f.Identity {
    return .{ .build = @splat(1), .bank = @splat(2), .config = @splat(3), .source = @splat(4) };
}
fn evidence(counts: [f.role_count]u64) f.SealEvidence {
    return .{ .role_counts = counts, .closed_roles = @splat(true), .healthy = true };
}
fn corpus(out: []u8) ![]const u8 {
    var w = try f.Writer.init(out, identity(), valid);
    try w.append(.control, 1, 1, .input, "command");
    try w.append(.render, 1, 100, .reference, "pcm");
    try w.append(.control, 2, 101, .reference, "result");
    try w.append(.worker, 1, 2, .input, "source");
    try w.append(.control, 3, 1, .input, "close");
    try w.append(.ui, 1, 1, .input, "submit");
    try w.append(.ui, 2, 101, .reference, "submitted");
    return try w.sealFraming(evidence(.{ 3, 1, 1, 2 }));
}
fn reseal(bytes: []u8) void {
    const digest = f.hash(bytes[0 .. bytes.len - 32]);
    @memcpy(bytes[bytes.len - 32 ..], &digest);
}
fn reheader(bytes: []u8) void {
    const digest = f.hash(bytes[0..160]);
    @memcpy(bytes[160..192], &digest);
    reseal(bytes);
}

// All test mutation helpers deliberately reframe bytes. Reader negatives below
// therefore test real order/family/count gates, not just a stale outer digest.
test "live semantic profile has independent fixed identity and separate read capabilities" {
    var out: [2048]u8 = undefined;
    const bytes = try corpus(&out);
    try t.expectEqualSlices(u8, "SMELSB01\x09\x00\x03\x00", bytes[0..12]);
    const r = try f.Reader.preflight(bytes, identity(), valid);
    try t.expectEqual(@as(u64, 7), r.counts.total);
    try t.expectEqualSlices(u64, &.{ 3, 1, 1, 2 }, &r.counts.roles);
    var input = r.execution(.control);
    const a = (try input.next()).?;
    try t.expectEqual(@as(u64, 1), a.ordinal);
    try t.expectEqualSlices(u8, "command", a.bytes);
    const b = (try input.next()).?;
    try t.expectEqual(@as(u64, 3), b.ordinal); // Class filtering never renumbers.
    try t.expectEqualSlices(u8, "close", b.bytes);
    try input.finish();
    var comparison = r.comparison(.control);
    const reference = (try comparison.next()).?;
    try t.expectEqual(@as(u64, 2), reference.ordinal);
    try t.expectEqualSlices(u8, "result", reference.bytes);
    try comparison.finish();
    var worker = r.execution(.worker);
    try t.expectEqualSlices(u8, "source", (try worker.next()).?.bytes);
    try worker.finish();
    var render_input = r.execution(.render);
    try render_input.finish();
    var render_reference = r.comparison(.render);
    try t.expectEqualSlices(u8, "pcm", (try render_reference.next()).?.bytes);
    try render_reference.finish();
    var ui_input = r.execution(.ui);
    try t.expectEqualSlices(u8, "submit", (try ui_input.next()).?.bytes);
    try ui_input.finish();
    var ui_reference = r.comparison(.ui);
    try t.expectEqualSlices(u8, "submitted", (try ui_reference.next()).?.bytes);
    try ui_reference.finish();
}

test "profile9 v3 explicitly rejects a validly resealed v2 envelope without inferring pacing" {
    var output: [2048]u8 = undefined;
    const bytes = try corpus(&output);
    try t.expectEqual(@as(u16, 9), f.profile_id);
    try t.expectEqual(@as(u16, 3), f.wire_version);
    _ = try f.Reader.preflight(bytes, identity(), valid);
    // This is a framing-only legacy-version specimen, not a converted history.
    // Rehash both envelopes so rejection cannot be attributed to stale digests.
    std.mem.writeInt(u16, output[10..12], 2, .little);
    reheader(output[0..bytes.len]);
    try t.expectError(error.UnsupportedVersion, f.Reader.preflight(bytes, identity(), valid));
}

test "live semantic bytes are producer owned and native padding is not the wire" {
    const lane = try t.allocator.create(f.Lane);
    defer t.allocator.destroy(lane);
    lane.init(.render, valid);
    const Header = extern struct { marker: u8, frames: u64 };
    var native: Header = undefined;
    @memset(std.mem.asBytes(&native), 0xaa);
    native.marker = 7;
    native.frames = 4;
    const original_bits = [_]u32{ 0x80000000, 0x7fa12345, 0xff800000, 0x3f800001 };
    var samples: [4]f32 = undefined;
    @memcpy(std.mem.asBytes(&samples), std.mem.asBytes(&original_bits));
    try t.expect(lane.push(100, .reference, std.mem.asBytes(&native), std.mem.asBytes(&samples)));
    @memset(std.mem.asBytes(&native), 0);
    @memset(std.mem.asBytes(&samples), 0);
    var scratch: [f.max_payload]u8 = undefined;
    const n = (try lane.pop(&scratch)).?;
    try t.expectEqual(@sizeOf(Header), n.first_len);
    const received = std.mem.bytesAsValue(Header, n.first());
    try t.expectEqual(@as(u8, 7), received.marker);
    try t.expectEqual(@as(u64, 4), received.frames);
    var canonical: [64]u8 = undefined;
    var encoder: f.Encoder = .{ .bytes = &canonical };
    try encoder.int(u8, received.marker);
    try encoder.int(u64, received.frames);
    for (0..4) |i| try encoder.f32Bits(std.mem.bytesAsValue(u32, n.second()[i * 4 ..][0..4]).*);
    try t.expectEqual(@as(usize, 25), encoder.result().len);
    var decoder: f.Decoder = .{ .bytes = encoder.result() };
    try t.expectEqual(@as(u8, 7), try decoder.int(u8));
    try t.expectEqual(@as(u64, 4), try decoder.int(u64));
    for (original_bits) |bits| try t.expectEqual(bits, try decoder.f32Bits());
    try decoder.finish();
    try t.expectEqual(@as(?f.NativeRecord, null), try lane.pop(&scratch));
}

test "live semantic byte ring wraps both copy segments without aliasing producer memory" {
    const lane = try t.allocator.create(f.Lane);
    defer t.allocator.destroy(lane);
    lane.init(.worker, valid);
    var payload: [f.max_payload]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @truncate(i * 17);
    var scratch: [f.max_payload]u8 = undefined;
    // Position the write cursor three bytes before the ring boundary. Neither
    // byte nor descriptor counters are reset when a record has been consumed.
    for (0..64) |i| {
        const size = if (i == 63) payload.len - 3 else payload.len;
        try t.expect(lane.push(2, .input, payload[0..size], ""));
        const n = (try lane.pop(&scratch)).?;
        try t.expectEqualSlices(u8, payload[0..size], n.bytes);
    }
    try t.expect(lane.push(2, .input, payload[0..11], payload[11..]));
    const n = (try lane.pop(&scratch)).?;
    try t.expectEqual(@as(u64, 65), n.ordinal);
    try t.expectEqual(@as(usize, 11), n.first_len);
    try t.expectEqualSlices(u8, &payload, n.bytes);
}

test "live semantic truncation corruption extra bytes and wrong identities reject before cursors" {
    var out: [2048]u8 = undefined;
    const bytes = try corpus(&out);
    for (0..bytes.len) |len| {
        if (f.Reader.preflight(bytes[0..len], identity(), valid)) |_| return error.AcceptedTruncation else |_| {}
    }
    var wrong = identity();
    wrong.build[0] ^= 1;
    try t.expectError(error.WrongBuild, f.Reader.preflight(bytes, wrong, valid));
    wrong = identity();
    wrong.bank[0] ^= 1;
    try t.expectError(error.WrongBank, f.Reader.preflight(bytes, wrong, valid));
    wrong = identity();
    wrong.config[0] ^= 1;
    try t.expectError(error.WrongConfig, f.Reader.preflight(bytes, wrong, valid));
    wrong = identity();
    wrong.source[0] ^= 1;
    try t.expectError(error.WrongSource, f.Reader.preflight(bytes, wrong, valid));
    out[f.header_size + f.frame_header_size] ^= 1;
    try t.expectError(error.HashMismatch, f.Reader.preflight(bytes, identity(), valid));
    reseal(out[0..bytes.len]);
    try t.expectError(error.HashMismatch, f.Reader.preflight(bytes, identity(), valid));
    _ = try corpus(&out);
    out[bytes.len] = 0;
    try t.expectError(error.Incomplete, f.Reader.preflight(out[0 .. bytes.len + 1], identity(), valid));
}

test "live semantic reader rejects legacy profile wrong version unknown family and wrong local order" {
    var out: [2048]u8 = undefined;
    const bytes = try corpus(&out);
    for (1..9) |legacy| {
        out[8] = @intCast(legacy);
        reheader(out[0..bytes.len]);
        try t.expectError(error.UnsupportedProfile, f.Reader.preflight(bytes, identity(), valid));
    }
    _ = try corpus(&out);
    out[10] = 1; // Explicitly reject the older three-role wire version.
    reheader(out[0..bytes.len]);
    try t.expectError(error.UnsupportedVersion, f.Reader.preflight(bytes, identity(), valid));
    _ = try corpus(&out);
    std.mem.writeInt(u16, out[f.header_size + 10 ..][0..2], 777, .little);
    reseal(out[0..bytes.len]);
    try t.expectError(error.UnsupportedFamily, f.Reader.preflight(bytes, identity(), valid));
    _ = try corpus(&out);
    std.mem.writeInt(u64, out[f.header_size + 16 ..][0..8], 2, .little);
    reseal(out[0..bytes.len]);
    try t.expectError(error.InvalidOrder, f.Reader.preflight(bytes, identity(), valid));
    _ = try corpus(&out);
    // The reference event is ordinal 2, even though input cursors skip it.
    const control_reference = f.header_size + f.frame_header_size + 7 + f.frame_header_size + 3;
    std.mem.writeInt(u64, out[control_reference + 16 ..][0..8], 1, .little);
    reseal(out[0..bytes.len]);
    try t.expectError(error.InvalidOrder, f.Reader.preflight(bytes, identity(), valid));
}

test "live semantic sealed totals class counts and complete flags cannot lie" {
    var out: [2048]u8 = undefined;
    const bytes = try corpus(&out);
    const trailer = bytes.len - f.trailer_size;
    out[trailer + 8] = 0;
    reseal(out[0..bytes.len]);
    try t.expectError(error.Incomplete, f.Reader.preflight(bytes, identity(), valid));
    _ = try corpus(&out);
    out[trailer + 9] = 3;
    reseal(out[0..bytes.len]);
    try t.expectError(error.Incomplete, f.Reader.preflight(bytes, identity(), valid));
    _ = try corpus(&out);
    out[trailer + 64] += 1; // control input count after four role counters
    reseal(out[0..bytes.len]);
    try t.expectError(error.CountMismatch, f.Reader.preflight(bytes, identity(), valid));
    _ = try corpus(&out);
    out[trailer + 24] += 1;
    reseal(out[0..bytes.len]);
    try t.expectError(error.CountMismatch, f.Reader.preflight(bytes, identity(), valid));
}

test "live semantic writer failure and incomplete closure permanently bar framing seal" {
    var out: [1024]u8 = undefined;
    var w = try f.Writer.init(&out, identity(), valid);
    try t.expectError(error.InvalidOrder, w.append(.control, 2, 1, .input, ""));
    try t.expectError(error.Poisoned, w.append(.control, 1, 1, .input, ""));
    try t.expectError(error.Poisoned, w.sealFraming(evidence(.{ 0, 0, 0, 0 })));
    w = try f.Writer.init(&out, identity(), valid);
    var closure = evidence(.{ 0, 0, 0, 0 });
    closure.closed_roles[1] = false;
    try t.expectError(error.Incomplete, w.sealFraming(closure));
    try t.expectError(error.Poisoned, w.sealFraming(evidence(.{ 0, 0, 0, 0 })));
    w = try f.Writer.init(&out, identity(), valid);
    try t.expectError(error.CountMismatch, w.sealFraming(evidence(.{ 1, 0, 0, 0 })));
    w = try f.Writer.init(&out, identity(), valid);
    closure = evidence(.{ 0, 0, 0, 0 });
    closure.healthy = false;
    try t.expectError(error.Poisoned, w.sealFraming(closure));
    var tiny: [f.header_size + f.trailer_size]u8 = undefined;
    w = try f.Writer.init(&tiny, identity(), valid);
    try t.expectError(error.BufferTooSmall, w.append(.control, 1, 1, .input, ""));
    try t.expectError(error.Poisoned, w.sealFraming(evidence(.{ 0, 0, 0, 0 })));
}

test "live semantic fixed transport overflows poison without waiting or resetting" {
    const lane = try t.allocator.create(f.Lane);
    defer t.allocator.destroy(lane);
    lane.init(.render, valid);
    var payload: [f.max_payload]u8 = @splat(42);
    for (0..f.lane_byte_capacity / f.max_payload) |_| try t.expect(lane.push(100, .reference, &payload, ""));
    try t.expect(!lane.push(100, .reference, "x", ""));
    try t.expectEqual(f.Poison.overflow, lane.failure());
    try t.expect(!lane.push(100, .reference, "", ""));
    var scratch: [f.max_payload]u8 = undefined;
    try t.expectError(error.Poisoned, lane.pop(&scratch));
    lane.closeAfterJoin();
    const stats = lane.finalStats();
    try t.expectEqual(@as(u64, f.lane_byte_capacity), stats.peak_bytes);
    lane.init(.control, valid);
    for (0..f.lane_record_capacity) |_| try t.expect(lane.push(1, .input, "", ""));
    try t.expect(!lane.push(1, .input, "", ""));
    try t.expectEqual(f.Poison.overflow, lane.failure());
    lane.init(.worker, valid);
    try t.expect(!lane.push(777, .input, "", ""));
    try t.expectEqual(f.Poison.unsupported, lane.failure());
    lane.init(.worker, valid);
    try t.expect(!lane.push(1, .reference, "", ""));
    try t.expectEqual(f.Poison.unsupported, lane.failure());
    lane.init(.render, valid);
    try t.expect(!lane.push(100, .reference, &payload, "x"));
    try t.expectEqual(f.Poison.overflow, lane.failure());
}

test "live semantic counter order and post-join pushes poison" {
    const lane = try t.allocator.create(f.Lane);
    defer t.allocator.destroy(lane);
    lane.init(.control, valid);
    lane.record_write.store(std.math.maxInt(u64), .monotonic);
    lane.record_read.store(std.math.maxInt(u64), .monotonic);
    try t.expect(!lane.push(1, .input, "", ""));
    try t.expectEqual(f.Poison.counter, lane.failure());
    lane.init(.control, valid);
    lane.byte_write = std.math.maxInt(u64);
    lane.byte_read.store(std.math.maxInt(u64), .monotonic);
    try t.expect(!lane.push(1, .input, "x", ""));
    try t.expectEqual(f.Poison.counter, lane.failure());
    lane.init(.control, valid);
    lane.record_read.store(1, .monotonic);
    try t.expect(!lane.push(1, .input, "", ""));
    try t.expectEqual(f.Poison.order, lane.failure());
    lane.init(.control, valid);
    lane.closeAfterJoin();
    try t.expect(!lane.push(1, .input, "", ""));
    try t.expectEqual(f.Poison.closed, lane.failure());
}

test "live semantic capture closure requires real drained lane counters and joins" {
    const capture = try t.allocator.create(f.Capture);
    defer t.allocator.destroy(capture);
    capture.init(valid);
    var out: [2048]u8 = undefined;
    var w = try f.Writer.init(&out, identity(), valid);
    try t.expect(capture.lane(.control).push(1, .input, "owned", ""));
    try t.expectError(error.NotDrained, capture.sealFraming(&w));
    var scratch: [f.max_payload]u8 = undefined;
    const n = (try capture.lane(.control).pop(&scratch)).?;
    // These raw bytes represent an explicitly byte-string schema in this test.
    try w.append(n.role, n.ordinal, n.family, n.class, n.bytes);
    for (&capture.lanes) |*lane| lane.closeAfterJoin();
    const bytes = try capture.sealFraming(&w);
    _ = try f.Reader.preflight(bytes, identity(), valid);
    try t.expect(@sizeOf(f.Capture) < f.max_capture_bytes);
    try t.expectError(error.AlreadySealed, capture.sealFraming(&w));
    capture.init(valid);
    w = try f.Writer.init(&out, identity(), valid);
    capture.lane(.worker).poison(.unsupported);
    for (&capture.lanes) |*lane| lane.closeAfterJoin();
    try t.expectError(error.Poisoned, capture.sealFraming(&w));
}

test "live semantic short scratch does not consume a published record" {
    const lane = try t.allocator.create(f.Lane);
    defer t.allocator.destroy(lane);
    lane.init(.control, valid);
    try t.expect(lane.push(1, .input, "1234", "5678"));
    var small: [7]u8 = undefined;
    try t.expectError(error.BufferTooSmall, lane.pop(&small));
    var enough: [8]u8 = undefined;
    const record = (try lane.pop(&enough)).?;
    try t.expectEqualSlices(u8, "12345678", record.bytes);
    try t.expectEqual(f.Poison.none, lane.failure());
}

const StreamTestSink = struct {
    bytes: []u8,
    used: usize = 0,
    max_write: usize = std.math.maxInt(usize),
    fail_at: ?usize = null,
    failure: enum { io, zero, oversized } = .io,
    fn write(context: *anyopaque, bytes: []const u8) !usize {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (self.fail_at) |at| if (self.used >= at) return switch (self.failure) {
            .io => error.InjectedSinkFailure,
            .zero => 0,
            .oversized => bytes.len + 1,
        };
        var n = @min(bytes.len, self.max_write);
        if (self.fail_at) |at| n = @min(n, at - self.used);
        if (n > self.bytes.len - self.used) return error.SinkCapacity;
        @memcpy(self.bytes[self.used..][0..n], bytes[0..n]);
        self.used += n;
        return n;
    }
    fn sink(self: *@This()) f.StreamSink {
        return .{ .context = self, .write = write };
    }
};
fn streamCorpus(w: *f.StreamingWriter) !f.StreamSeal {
    try w.append(.control, 1, 1, .input, "command");
    try w.append(.render, 1, 100, .reference, "pcm");
    try w.append(.control, 2, 101, .reference, "result");
    try w.append(.worker, 1, 2, .input, "source");
    try w.append(.control, 3, 1, .input, "close");
    try w.append(.ui, 1, 1, .input, "submit");
    try w.append(.ui, 2, 101, .reference, "submitted");
    return try w.sealFraming(evidence(.{ 3, 1, 1, 2 }));
}

test "live semantic streaming exactly matches canonical memory writer with short writes" {
    var memory: [2048]u8 = undefined;
    const expected = try corpus(&memory);
    for ([_]usize{ 1, 2, 31, 64, 159, 192, 2048 }) |chunk| {
        var output: [2048]u8 = undefined;
        var sink: StreamTestSink = .{ .bytes = &output, .max_write = chunk };
        var writer = try f.StreamingWriter.init(sink.sink(), output.len, identity(), valid);
        const seal = try streamCorpus(&writer);
        try t.expectEqual(expected.len, seal.bytes);
        try t.expectEqualSlices(u8, expected, output[0..sink.used]);
        try t.expectEqualSlices(u8, expected[expected.len - 32 ..], &seal.hash);
        const reader = try f.Reader.preflight(output[0..sink.used], identity(), valid);
        try t.expectEqual(reader.counts, seal.counts);
        try t.expectError(error.AlreadySealed, writer.append(.worker, 2, 2, .input, "later"));
        try t.expectError(error.AlreadySealed, writer.sealFraming(evidence(.{ 3, 1, 1, 2 })));
    }
}

test "live semantic streaming supports empty framing and reserves complete trailer" {
    var memory: [f.header_size + f.trailer_size]u8 = undefined;
    var memory_writer = try f.Writer.init(&memory, identity(), valid);
    const expected = try memory_writer.sealFraming(evidence(.{ 0, 0, 0, 0 }));
    var output: [memory.len]u8 = undefined;
    var sink: StreamTestSink = .{ .bytes = &output };
    var writer = try f.StreamingWriter.init(sink.sink(), output.len, identity(), valid);
    const sealed = try writer.sealFraming(evidence(.{ 0, 0, 0, 0 }));
    try t.expectEqual(output.len, sealed.bytes);
    try t.expectEqualSlices(u8, expected, &output);
    _ = try f.Reader.preflight(&output, identity(), valid);
    sink.used = 0;
    writer = try f.StreamingWriter.init(sink.sink(), output.len, identity(), valid);
    try t.expectError(error.BufferTooSmall, writer.append(.control, 1, 1, .input, ""));
    try t.expectEqual(@as(usize, f.header_size), sink.used);
    try t.expect(writer.failed);
    try t.expectError(error.Poisoned, writer.sealFraming(evidence(.{ 0, 0, 0, 0 })));
    sink.used = 0;
    try t.expectError(error.InvalidLength, f.StreamingWriter.init(sink.sink(), f.header_size + f.trailer_size - 1, identity(), valid));
    try t.expectError(error.InvalidLength, f.StreamingWriter.init(sink.sink(), f.max_file_bytes + 1, identity(), valid));
    try t.expectEqual(@as(usize, 0), sink.used);
}

test "live semantic streaming sink failures at every byte never seal or retry uncertain prefix" {
    var memory: [2048]u8 = undefined;
    const expected = try corpus(&memory);
    for (0..expected.len) |failure_offset| {
        inline for (.{ .io, .zero, .oversized }) |mode| {
            var output: [2048]u8 = undefined;
            var sink: StreamTestSink = .{ .bytes = &output, .fail_at = failure_offset, .failure = mode };
            const expected_error = if (mode == .io) error.InjectedSinkFailure else error.InvalidWrite;
            if (failure_offset < f.header_size) {
                try t.expectError(expected_error, f.StreamingWriter.init(sink.sink(), output.len, identity(), valid));
            } else {
                var writer = try f.StreamingWriter.init(sink.sink(), output.len, identity(), valid);
                try t.expectError(expected_error, streamCorpus(&writer));
                try t.expect(writer.failed and !writer.sealed);
                try t.expectEqual(expected_error, writer.first_error.?);
                const written = sink.used;
                try t.expectError(error.Poisoned, writer.append(.control, 99, 1, .input, "retry"));
                try t.expectError(error.Poisoned, writer.sealFraming(evidence(.{ 3, 1, 1, 2 })));
                try t.expectEqual(written, sink.used);
                try t.expectEqual(expected_error, writer.first_error.?);
            }
            try t.expectEqual(failure_offset, sink.used);
        }
    }
}

test "live semantic streaming rejects unhealthy or unjoined evidence before footer" {
    for (0..3) |which| {
        var output: [512]u8 = undefined;
        var sink: StreamTestSink = .{ .bytes = &output };
        var writer = try f.StreamingWriter.init(sink.sink(), output.len, identity(), valid);
        var e = evidence(.{ 0, 0, 0, 0 });
        switch (which) {
            0 => e.healthy = false,
            1 => e.closed_roles[1] = false,
            2 => e.role_counts[2] = 1,
            else => unreachable,
        }
        const expected_error = switch (which) {
            0 => error.Poisoned,
            1 => error.Incomplete,
            else => error.CountMismatch,
        };
        try t.expectError(expected_error, writer.sealFraming(e));
        try t.expectEqual(@as(usize, f.header_size), sink.used);
        try t.expect(writer.failed);
    }
}

test "fourth UI producer must be independently drained and excluded" {
    const capture = try t.allocator.create(f.Capture);
    defer t.allocator.destroy(capture);
    capture.init(valid);
    try t.expect(capture.lane(.ui).push(1, .input, "ui-owned", ""));
    try t.expectError(error.NotDrained, capture.sealEvidence());
    var scratch: [f.max_payload]u8 = undefined;
    const record = (try capture.lane(.ui).pop(&scratch)).?;
    try t.expectEqual(f.Role.ui, record.role);
    try t.expectEqual(@as(u64, 1), record.ordinal);
    var output: [1024]u8 = undefined;
    var writer = try f.Writer.init(&output, identity(), valid);
    try writer.append(record.role, record.ordinal, record.family, record.class, record.bytes);
    capture.lane(.control).closeAfterJoin();
    capture.lane(.worker).closeAfterJoin();
    capture.lane(.render).closeAfterJoin();
    const not_closed = try capture.sealEvidence();
    try t.expect(!not_closed.closed_roles[3]);
    try t.expectError(error.Incomplete, writer.sealFraming(not_closed));
    // A poisoned writer cannot be salvaged. Reconstruct from actual drained data.
    writer = try f.Writer.init(&output, identity(), valid);
    try writer.append(record.role, record.ordinal, record.family, record.class, record.bytes);
    capture.lane(.ui).closeAfterJoin(); // Explicit UI-owner exclusion, not a fake thread join.
    const bytes = try capture.sealFraming(&writer);
    const reader = try f.Reader.preflight(bytes, identity(), valid);
    try t.expectEqualSlices(u64, &.{ 0, 0, 0, 1 }, &reader.counts.roles);
    try t.expectEqual(@as(u8, 15), bytes[bytes.len - f.trailer_size + 9]);
    try t.expectEqual(@as(usize, 184), f.trailer_size);
    try t.expect(!capture.lane(.ui).push(1, .input, "late", ""));
}

test "v1 empty header rejects by version before v3 trailer interpretation" {
    var bytes: [352]u8 = @splat(0); // The old minimum192+160 byte envelope.
    @memcpy(bytes[0..8], f.magic);
    std.mem.writeInt(u16, bytes[8..10], f.profile_id, .little);
    std.mem.writeInt(u16, bytes[10..12], 1, .little);
    try t.expectError(error.UnsupportedVersion, f.Reader.preflight(&bytes, identity(), valid));
}

test "v3 rejects three-role header mask and wrong UI counter" {
    var output: [2048]u8 = undefined;
    const bytes = try corpus(&output);
    std.mem.writeInt(u16, output[28..30], 3, .little);
    reheader(output[0..bytes.len]);
    try t.expectError(error.Noncanonical, f.Reader.preflight(bytes, identity(), valid));
    _ = try corpus(&output);
    const trailer = bytes.len - f.trailer_size;
    output[trailer + 9] = 7;
    reseal(output[0..bytes.len]);
    try t.expectError(error.Incomplete, f.Reader.preflight(bytes, identity(), valid));
    _ = try corpus(&output);
    output[trailer + 56] += 1; // UI role count, distinct from class counts.
    reseal(output[0..bytes.len]);
    try t.expectError(error.CountMismatch, f.Reader.preflight(bytes, identity(), valid));
}
