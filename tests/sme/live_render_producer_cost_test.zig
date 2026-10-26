//! Bounded, single-thread actual Service.endRenderSpan producer experiment.
//! No Host, device, decode work, replay qualification or concurrent timing claim.
const std = @import("std");
const bank = @import("sme-bank");
const stream = @import("sme-streaming").stream;
const opus = @import("sme-opus");
const live = @import("sme-author-live-owner");
const recording = live.semantic_recording;
const codec = recording.codec;
const f = recording.format;
const t = std.testing;
const n = 128;
const Source = struct {
    bytes: []const u8,
    fn read(raw: *anyopaque, offset: u64, out: []u8) opus.Error!void {
        const self: *Source = @ptrCast(@alignCast(raw));
        if (offset > self.bytes.len or out.len > self.bytes.len - offset) return error.TruncatedContainer;
        @memcpy(out, self.bytes[@intCast(offset)..][0..out.len]);
    }
};
const Sink = struct {
    bytes: u64 = 0,
    fn write(raw: *anyopaque, bytes: []const u8) !usize {
        const self: *Sink = @ptrCast(@alignCast(raw));
        self.bytes += bytes.len;
        return bytes.len;
    }
};
const Probe = struct {
    forward: ?stream.live_semantic.Binding = null,
    points: u64 = 0,
    boundaries: u64 = 0,
    fn point(raw: *anyopaque, value: stream.live_semantic.Point) void {
        const self: *Probe = @ptrCast(@alignCast(raw));
        self.points += 1;
        if (self.forward) |binding| binding.point(binding.context, value);
    }
    fn boundary(raw: *anyopaque, value: stream.live_semantic.BoundaryPoint) void {
        const self: *Probe = @ptrCast(@alignCast(raw));
        self.boundaries += 1;
        if (self.forward) |binding| binding.boundary(binding.context, value);
    }
    fn hooks(self: *Probe) stream.LiveSemanticHooks {
        return .{ .cuts = .{ .context = self, .point = point, .boundary = boundary } };
    }
};
fn now() std.Io.Timestamp {
    return std.Io.Clock.awake.now(t.io);
}
fn elapsed(start: std.Io.Timestamp) u64 {
    return @intCast(start.durationTo(now()).nanoseconds);
}
fn measure(loaded: *bank.MusicBank, slots: u16, opened: u16) !void {
    var sound_index: u32 = 0;
    for (loaded.tables.sounds, 0..) |sound, index| if (sound.storage == .streaming) {
        sound_index = @intCast(index);
        break;
    };
    const sound = loaded.tables.sounds[sound_index];
    const encoded = loaded.tables.blob[@intCast(sound.blob_offset)..][0..@intCast(sound.blob_length)];
    var source: Source = .{ .bytes = encoded };
    var plain_ns: [3]u64 = undefined;
    var counted_ns: [3]u64 = undefined;
    var producer_ns: [3]u64 = undefined;
    var drain_ns: [3]u64 = undefined;
    var wire_bytes: [3]u64 = undefined;
    var native_bytes: [3]u64 = undefined;
    var record_counts: [3]u64 = undefined;
    const expected_points: u64 = 2 * @as(u64, slots) + 4 * @as(u64, opened) + 6;
    for (0..3) |trial| {
        for (0..3) |mode| {
            var probe: Probe = .{};
            const hooks = probe.hooks();
            const service = try stream.Service.create(t.allocator, .{ .max_streams = slots, .max_channels = 2, .job_capacity = 1, .completion_capacity = 1, .max_encoded_chunk_bytes = 65536 });
            defer service.destroy() catch @panic("service retained");
            try t.expectEqual(slots, service.profile.max_streams);
            if (mode != 0) try service.attachLiveSemanticQuiescent(hooks);
            defer if (mode != 0) service.detachLiveSemanticQuiescent(hooks) catch @panic("hooks retained");
            var asset = try service.prepareAsset(.{ .sound_index = sound_index, .sound = sound, .codec = loaded.tables.codecs[sound.codec], .chunks = loaded.tables.chunks[sound.chunks.first..][0..sound.chunks.count], .seeks = loaded.tables.seeks[sound.seeks.first..][0..sound.seeks.count], .source = .{ .context = &source, .length = encoded.len, .read_at = Source.read } });
            defer asset.retire();
            var handles: [64]stream.Handle = undefined;
            var handle_count: usize = 0;
            defer for (handles[0..handle_count]) |handle| service.close(handle) catch @panic("stream retained");
            for (0..opened) |i| {
                handles[i] = try service.open(&asset, .{ .generation = i + 1, .transport_epoch = 1, .group = i + 1, .layer = 1 });
                handle_count += 1;
            }

            probe.points = 0;
            probe.boundaries = 0;
            if (mode < 2) {
                const start = now();
                for (0..n) |i| service.endRenderSpan((i + 1) * 64);
                if (mode == 0) plain_ns[trial] = elapsed(start) else counted_ns[trial] = elapsed(start);
                if (mode == 1) {
                    try t.expectEqual(expected_points * n, probe.points);
                    try t.expectEqual(@as(u64, n * 2), probe.boundaries);
                }
                continue;
            }
            const recorder = try t.allocator.create(recording.Recorder);
            defer t.allocator.destroy(recorder);
            recorder.address = null;
            recorder.session = .{};
            var sink: Sink = .{};
            const identity: f.Identity = .{ .build = @splat(1), .bank = @splat(2), .config = @splat(3), .source = @splat(4) };
            try recorder.initStreaming(identity, .{ .context = &sink, .write = Sink.write }, f.max_file_bytes, @sizeOf(Sink));
            // Setup is excluded: forward only the actual Render publication path.
            probe.forward = recorder.sessionConfig().service.cuts;
            defer probe.forward = null;
            producer_ns[trial] = 0;
            drain_ns[trial] = 0;
            native_bytes[trial] = 0;
            for (0..n) |i| {
                var start = now();
                service.endRenderSpan((i + 1) * 64);
                producer_ns[trial] += elapsed(start);
                // Actual producer exclusion here makes finalStats legal.
                native_bytes[trial] += recorder.capture.lane(.render).finalStats().queued_bytes;
                start = now();
                while (try recorder.drainStreaming()) {}
                drain_ns[trial] += elapsed(start);
                try t.expect(recorder.healthy());
            }
            try t.expectEqual(expected_points * n, probe.points);
            try t.expectEqual(@as(u64, n * 2), probe.boundaries);
            // Explicit test-only boundary pair flushes final pending points. Not
            // represented as a genuine DSP operation or included in timings above.
            const binding = recorder.sessionConfig().service.cuts;
            binding.boundary(binding.context, .{ .role = .render, .site = .service_render_consumed_prefix, .edge = .before, .index = n * 64, .generation = 0 });
            binding.boundary(binding.context, .{ .role = .render, .site = .service_render_consumed_prefix, .edge = .after, .index = n * 64, .generation = 0 });
            native_bytes[trial] += recorder.capture.lane(.render).finalStats().queued_bytes;
            while (try recorder.drainStreaming()) {}
            try t.expect(recorder.healthy());
            const stats = recorder.capture.lane(.render).finalStats();
            try t.expectEqual(stats.produced, stats.consumed);
            try t.expectEqual(@as(u64, 0), stats.queued_bytes);
            try t.expectEqual(f.Poison.none, stats.poison);
            record_counts[trial] = stats.produced;
            wire_bytes[trial] = sink.bytes;
        }
    }
    std.debug.print("RENDER_PRODUCER_COST slots={d} opened={d} spans={d} points_per_span={d} plain_ns={any} counted_ns={any} captured_producer_ns={any} collector_ns={any} native_bytes={any} wire_bytes={any} records={any} PacketInput={d} PacketReference={d} Lane={d} offsets_write={d}/{d} offsets_read={d}/{d}\n", .{ slots, opened, n, expected_points, plain_ns, counted_ns, producer_ns, drain_ns, native_bytes, wire_bytes, record_counts, @sizeOf(codec.PacketInput), @sizeOf(codec.PacketReference), @sizeOf(f.Lane), @offsetOf(f.Lane, "byte_write"), @offsetOf(f.Lane, "record_write"), @offsetOf(f.Lane, "byte_read"), @offsetOf(f.Lane, "record_read") });
}
test "actual Render publication producer cost with explicit slot and open counts" {
    const path = std.process.Environ.getPosix(t.environ, "SME_RENDER_COST_BANK") orelse return error.SkipZigTest;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(t.io, path, t.allocator, .limited(16 * 1024 * 1024));
    defer t.allocator.free(bytes);
    var loaded = try bank.MusicBank.load(t.allocator, bytes);
    defer loaded.deinit();
    try measure(&loaded, 4, 4);
    try measure(&loaded, 48, 4);
    try measure(&loaded, 48, 48);
}
