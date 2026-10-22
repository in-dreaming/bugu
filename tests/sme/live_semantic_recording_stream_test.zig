//! Transport/unit fixtures only: none claim genuine native lifecycle completion.
const std = @import("std");
const live = @import("sme-author-live-owner");
const recording = live.semantic_recording;
const codec = recording.codec;
const f = recording.format;
const t = std.testing;
fn identity() f.Identity {
    return .{ .build = @splat(1), .bank = @splat(2), .config = @splat(3), .source = @splat(4) };
}
const Sink = struct {
    bytes: [4096]u8 = undefined,
    used: usize = 0,
    reject: bool = false,
    fn write(raw: *anyopaque, bytes: []const u8) !usize {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (self.reject) return error.DiskUnavailable;
        if (bytes.len > self.bytes.len - self.used) return error.OutOfSpace;
        @memcpy(self.bytes[self.used..][0..bytes.len], bytes);
        self.used += bytes.len;
        return bytes.len;
    }
    fn binding(self: *@This()) f.StreamSink {
        return .{ .context = self, .write = write };
    }
};
fn makeRecorder() !*recording.Recorder {
    const recorder = try t.allocator.create(recording.Recorder);
    // Match the existing process fixture's pinned allocation initialization.
    recorder.address = null;
    recorder.session = .{};
    return recorder;
}
test "streaming Recorder accounts resident staging not file cap and cannot seal unused Session" {
    const recorder = try makeRecorder();
    defer t.allocator.destroy(recorder);
    var sink: Sink = .{};
    try recorder.initStreaming(identity(), sink.binding(), f.max_file_bytes, @sizeOf(Sink));
    try t.expect(recorder.healthy());
    try t.expectEqual(@sizeOf(recording.Recorder) + @sizeOf(Sink), recorder.allocation_bytes);
    try t.expect(!try recorder.drainStreaming());
    try t.expectError(error.InvalidState, recorder.drain());
    try t.expectError(error.InvalidState, recorder.finish());
    try t.expectError(error.Incomplete, recorder.finishStreaming());
    try t.expectEqual(@as(usize, f.header_size), sink.used);
    try t.expect(!recorder.finished);
    try t.expect(recorder.session.host == null);
}
test "streaming Recorder admission checks resident budget before sink side effects" {
    const recorder = try makeRecorder();
    defer t.allocator.destroy(recorder);
    var sink: Sink = .{};
    try t.expectError(error.CaptureBudgetExceeded, recorder.initStreaming(identity(), sink.binding(), f.max_file_bytes, f.max_capture_bytes));
    try t.expectEqual(@as(usize, 0), sink.used);
    try t.expect(recorder.address == null);
    try t.expect(recorder.session.host == null);
}
test "streaming Recorder init IO error stays sticky without attached native roles" {
    const recorder = try makeRecorder();
    defer t.allocator.destroy(recorder);
    var sink: Sink = .{ .reject = true };
    try t.expectError(error.DiskUnavailable, recorder.initStreaming(identity(), sink.binding(), f.max_file_bytes, @sizeOf(Sink)));
    try t.expectEqual(error.DiskUnavailable, recorder.first_output_error.?);
    try t.expect(!recorder.healthy());
    try t.expect(recorder.session.host == null);
    sink.reject = false;
    try t.expectError(error.InvalidState, recorder.initStreaming(identity(), sink.binding(), f.max_file_bytes, @sizeOf(Sink)));
    try t.expectEqual(@as(usize, 0), sink.used);
}
test "streaming Recorder drain IO failure preserves original error and poisons capture" {
    const recorder = try makeRecorder();
    defer t.allocator.destroy(recorder);
    var sink: Sink = .{};
    try recorder.initStreaming(identity(), sink.binding(), f.max_file_bytes, @sizeOf(Sink));
    // A finite codec input fixture, not an injected native completion event.
    const cut: codec.Native(codec.Cut) = .{ .occurrence = 1, .value = .{ .role = .control, .site = .runtime_load_state_read, .edge = .before, .index = 0, .generation = 0 } };
    try t.expect(recorder.capture.lane(.control).push(@intFromEnum(codec.Family.cut), .input, std.mem.asBytes(&cut), &.{}));
    sink.reject = true;
    try t.expectError(error.DiskUnavailable, recorder.drainStreaming());
    try t.expectEqual(error.DiskUnavailable, recorder.first_output_error.?);
    try t.expect(!recorder.healthy());
    try t.expect(recorder.streaming_writer.?.failed);
    try t.expectError(error.Poisoned, recorder.drainStreaming());
    try t.expectEqual(@as(usize, f.header_size), sink.used);
    // No Host was attached, and no lifecycle facts were manufactured to seal.
    try t.expect(recorder.session.host == null);
    try t.expect(!recorder.finished);
}

test "streaming Recorder queues compact acceptance and reconstructs it during drain" {
    const recorder = try makeRecorder();
    defer t.allocator.destroy(recorder);
    var sink: Sink = .{};
    try recorder.initStreaming(identity(), sink.binding(), f.max_file_bytes, @sizeOf(Sink));
    var attempt: codec.stream.LiveAcceptanceAttemptV1 = .{
        .incoming = .{ .accepted_control_frame = 128, .control_tick = 7, .input_order = 3 },
        .evidence = .{
            .job_slots = codec.stream.observation.job_capacity,
            .scanned = codec.stream.observation.job_capacity,
            .states = @splat(.completed),
            .completed = @splat(.{ .job = 42 }),
            .outcome = .no_completion,
        },
    };
    const observer = recorder.sessionConfig().acceptance;
    observer.emit(observer.context, &attempt, 256);
    const queued = recorder.capture.lane(.control).finalStats();
    try t.expectEqual(@as(u64, 2), queued.produced);
    try t.expectEqual(@as(u64, @sizeOf(codec.Native(codec.EventCut)) + @sizeOf(codec.Native(codec.CompactAcceptance))), queued.queued_bytes);
    try t.expectEqual(@as(u64, 1), recorder.occurrence.load(.acquire));
    // Both physical records retain one original event occurrence, with no Host
    // lifecycle fabricated by this transport-only test.
    try t.expect(try recorder.drainStreaming());
    try t.expect(try recorder.drainStreaming());
    try t.expect(!try recorder.drainStreaming());
    try t.expect(recorder.healthy());
    try t.expectEqual(@as(u64, 0), recorder.progress().multi_frame_ticks);
    try t.expect(recorder.session.host == null);
}

test "streaming Recorder rejects incomplete acceptance before queue publication" {
    const recorder = try makeRecorder();
    defer t.allocator.destroy(recorder);
    var sink: Sink = .{};
    try recorder.initStreaming(identity(), sink.binding(), f.max_file_bytes, @sizeOf(Sink));
    var attempt: codec.stream.LiveAcceptanceAttemptV1 = .{
        .incoming = .{ .accepted_control_frame = 0, .control_tick = 0, .input_order = 0 },
        .evidence = .{ .representation_complete = false },
    };
    const observer = recorder.sessionConfig().acceptance;
    observer.emit(observer.context, &attempt, 0);
    try t.expect(!recorder.healthy());
    try t.expectEqual(@as(u64, 0), recorder.occurrence.load(.acquire));
    const queued = recorder.capture.lane(.control).finalStats();
    try t.expectEqual(@as(u64, 0), queued.produced);
    try t.expectEqual(@as(u64, 0), queued.queued_bytes);
    try t.expectEqual(@as(usize, f.header_size), sink.used);
    try t.expect(recorder.session.host == null);
}

test "streaming Recorder observes genuine WorkerGate publication and acquired prefixes" {
    const recorder = try makeRecorder();
    defer t.allocator.destroy(recorder);
    var sink: Sink = .{};
    try recorder.initStreaming(identity(), sink.binding(), f.max_file_bytes, @sizeOf(Sink));
    var gate = try codec.mailbox.WorkerGate.initObserved(17, recorder.sessionConfig().worker_gate);
    try t.expectEqual(@as(u64, 1), try gate.requestPark(17));
    try t.expectEqualDeep(@as(codec.mailbox.WorkerGate.Action, .{ .park = 1 }), try gate.workerAction(17));
    // One native store and three native cross-role loads, each with two edges,
    // remain buffered without changing their original global occurrences.
    try t.expectEqual(@as(u64, 8), recorder.occurrence.load(.acquire));
    try t.expectEqual(@as(u64, 0), recorder.capture.lane(.control).finalStats().produced);
    try t.expectEqual(@as(u64, 0), recorder.capture.lane(.worker).finalStats().produced);
    const config = recorder.sessionConfig();
    // Engine-point arrival flushes the earlier gate packet. Ordinary hooks
    // then flush those engine points before their own event markers.
    config.service.cuts.point(config.service.cuts.context, .{ .role = .control, .site = .service_acceptance_scan, .edge = .before, .index = 0 });
    config.service.cuts.point(config.service.cuts.context, .{ .role = .worker, .site = .service_worker_scan, .edge = .before, .index = 0 });
    config.acceptance.frontier.?(config.acceptance.context, .idle, 0, 0);
    const worker = config.service.worker_facts.?;
    worker.emit(worker.context, .{ .selected = .{ .job = 1, .slot = 0 } });
    try t.expectEqual(@as(u64, 12), recorder.occurrence.load(.acquire));
    try t.expectEqual(@as(u64, 6), recorder.capture.lane(.control).finalStats().produced);
    try t.expectEqual(@as(u64, 6), recorder.capture.lane(.worker).finalStats().produced);
    inline for (.{ f.Role.control, f.Role.worker }) |role| {
        const families = [_]codec.Family{ .worker_gate_packet_input, .worker_gate_packet_reference, .point_packet_input, .point_packet_reference, .event_cut, if (role == .control) .frontier else .worker_fact };
        for (families) |family| {
            const record = (try recorder.capture.lane(role).pop(&recorder.native_scratch)).?;
            try t.expectEqual(@intFromEnum(family), record.family);
            _ = try codec.encodeNative(record, &recorder.wire_scratch);
        }
        try t.expect(try recorder.capture.lane(role).pop(&recorder.native_scratch) == null);
    }
    // This is a transport fixture, not manufactured Host lifecycle completion.
    try t.expect(recorder.healthy());
    try t.expect(recorder.session.host == null);
}

test "Recorder explicit pacing is pinned before Session init and legacy wrappers remain polling" {
    const constructors = enum { legacy_memory, explicit_memory, legacy_stream, explicit_stream };
    inline for (.{ constructors.legacy_memory, constructors.explicit_memory, constructors.legacy_stream, constructors.explicit_stream }) |constructor| {
        inline for (.{ live.PacingMode.legacy_poll, live.PacingMode.notified_v1 }) |requested| {
            const recorder = try makeRecorder();
            defer t.allocator.destroy(recorder);
            var corpus: [4096]u8 = undefined;
            var sink: Sink = .{};
            switch (constructor) {
                .legacy_memory => try recorder.init(identity(), &corpus),
                .explicit_memory => try recorder.initWithPacing(identity(), &corpus, requested),
                .legacy_stream => try recorder.initStreaming(identity(), sink.binding(), f.max_file_bytes, @sizeOf(Sink)),
                .explicit_stream => try recorder.initStreamingWithPacing(identity(), sink.binding(), f.max_file_bytes, @sizeOf(Sink), requested),
            }
            const expected = switch (constructor) {
                .legacy_memory, .legacy_stream => live.PacingMode.legacy_poll,
                .explicit_memory, .explicit_stream => requested,
            };
            try t.expectEqual(expected, recorder.pacing);
            try t.expectEqual(expected, recorder.session.config.pacing);
            try t.expectEqual(expected, recorder.sessionConfig().pacing);
            try t.expect(recorder.session.pristine());
            try t.expect(recorder.session.host == null and !recorder.session.used);
            try t.expect(recorder.healthy());
            try t.expectEqual(@as(u64, 0), recorder.occurrence.load(.acquire));
            // No owner, native clock, callback, output or lifecycle is simulated.
        }
    }
}
