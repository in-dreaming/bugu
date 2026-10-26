//! Actual provider/Service reads: hashes stay byte-identical and corruption/IO
//! remain failures. This is an offline regression, not a timing qualification.
const std = @import("std");
const f = @import("sme-stream-reload-fixture");
const stream = @import("sme-streaming").stream;
const opus = @import("sme-opus");
const preview = @import("sme-author-preview-v1").source;
const t = std.testing;
const a = t.allocator;
fn buildBank() ![]u8 {
    const source = try std.mem.replaceOwned(u8, a, f.authored_source, "max_chunk_bytes=262144", "max_chunk_bytes=65536");
    defer a.free(source);
    return f.buildSource(.a, source, null);
}
fn hash(bytes: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &out, .{});
    return out;
}
const ReadSource = struct {
    bytes: []const u8,
    corrupt: bool = false,
    fail: bool = false,
    calls: usize = 0,
    last_hash: [32]u8 = @splat(0),
    fn read(raw: *anyopaque, offset: u64, destination: []u8) opus.Error!void {
        const self: *ReadSource = @ptrCast(@alignCast(raw));
        self.calls += 1;
        if (self.fail) return error.TruncatedContainer;
        if (offset > self.bytes.len or destination.len > self.bytes.len - offset) return error.TruncatedContainer;
        @memcpy(destination, self.bytes[@intCast(offset)..][0..destination.len]);
        if (self.corrupt and destination.len > 0) destination[0] ^= 1;
        self.last_hash = hash(destination);
    }
};
const Probe = struct {
    source: *ReadSource,
    successes: usize = 0,
    failures: usize = 0,
    mismatch: bool = false,
    fn point(_: *anyopaque, _: stream.live_semantic.Point) void {}
    fn boundary(_: *anyopaque, _: stream.live_semantic.BoundaryPoint) void {}
    fn fact(raw: *anyopaque, value: stream.SourceFact) void {
        const self: *Probe = @ptrCast(@alignCast(raw));
        if (value.edge != .after) return;
        if (value.error_code != 0) {
            self.failures += 1;
            if (value.error_code != @intFromError(error.TruncatedContainer)) self.mismatch = true;
            if (!std.mem.eql(u8, &value.bytes_hash, &@as([32]u8, @splat(0)))) self.mismatch = true;
        } else {
            self.successes += 1;
            if (!std.mem.eql(u8, &value.bytes_hash, &self.source.last_hash)) self.mismatch = true;
        }
    }
};
test "supply hashes preserve actual prepare decode corruption and IO results" {
    const bytes = try buildBank();
    defer a.free(bytes);
    var loaded = try f.bank.MusicBank.load(a, bytes);
    defer loaded.deinit();
    const sound_index: u32 = blk: {
        for (loaded.tables.sounds, 0..) |sound, i| if (sound.storage == .streaming) break :blk @intCast(i);
        return error.MissingStream;
    };
    const sound = loaded.tables.sounds[sound_index];
    const encoded = loaded.tables.blob[@intCast(sound.blob_offset)..][0..@intCast(sound.blob_length)];
    inline for (.{ false, true }) |io_failure| {
        var source: ReadSource = .{ .bytes = encoded };
        var probe: Probe = .{ .source = &source };
        const service = try stream.Service.create(a, .{ .max_streams = 1, .max_channels = 2, .job_capacity = 1, .completion_capacity = 1, .max_encoded_chunk_bytes = 65536 });
        defer service.destroy() catch @panic("service retained");
        const hooks: stream.LiveSemanticHooks = .{ .cuts = .{ .context = &probe, .point = Probe.point, .boundary = Probe.boundary }, .source = .{ .context = &probe, .emit = Probe.fact } };
        try service.attachLiveSemanticQuiescent(hooks);
        defer service.detachLiveSemanticQuiescent(hooks) catch @panic("semantic binding retained");
        const descriptor: stream.Asset.Descriptor = .{
            .sound_index = sound_index,
            .sound = sound,
            .codec = loaded.tables.codecs[sound.codec],
            .chunks = loaded.tables.chunks[sound.chunks.first..][0..sound.chunks.count],
            .seeks = loaded.tables.seeks[sound.seeks.first..][0..sound.seeks.count],
            .source = .{ .context = &source, .length = encoded.len, .read_at = ReadSource.read },
        };
        var asset = try service.prepareAsset(descriptor);
        defer asset.retire();
        try t.expect(probe.successes > 0 and !probe.mismatch);
        // The unchanged preparation authenticator still rejects bad bytes.
        source.corrupt = true;
        try t.expectError(error.HashMismatch, service.prepareAsset(descriptor));
        source.corrupt = false;
        source.fail = true;
        try t.expectError(error.TruncatedContainer, service.prepareAsset(descriptor));
        source.fail = false;
        const handle = try service.open(&asset, .{ .generation = 1, .transport_epoch = 1, .group = 1, .layer = 1 });
        defer service.close(handle) catch @panic("stream retained");
        // Change only the provider after the authenticated asset is prepared.
        // The real cache miss must authenticate again and fail, not decode it.
        source.corrupt = !io_failure;
        source.fail = io_failure;
        const before_reads = source.calls;
        const job = (try service.request(handle)) orelse return error.MissingJob;
        try t.expectEqual(job, (try service.workerOne()).?);
        try t.expect(source.calls > before_reads);
        const accepted = (try service.acceptCompleted(.{ .accepted_control_frame = 0, .control_tick = 1, .input_order = 1 })) orelse return error.MissingCompletion;
        try t.expectEqual(.failed, accepted.input.payload.worker.state);
        const failure: stream.Failure = if (io_failure) .io else .hash;
        try t.expectEqual(@intFromEnum(failure), accepted.input.payload.worker.failure_code);
        try t.expectEqual(@as(u64, 0), accepted.input.payload.worker.available_frames);
        try t.expect(!probe.mismatch);
        try t.expect(probe.failures >= 1);
        try service.cancel(handle);
    }
}
const ProviderProbe = struct {
    digest: ?[32]u8 = null,
    failure: ?preview.ProviderError = null,
    fn event(raw: *anyopaque, value: preview.SemanticEvent) void {
        const self: *ProviderProbe = @ptrCast(@alignCast(raw));
        if (value == .result) switch (value.result.value) {
            .read_hash => |digest| self.digest = digest,
            .failure => |err| self.failure = err,
            else => {},
        };
    }
};
test "provider read digest matches actual bytes and IO failure has no success digest" {
    const bytes = try buildBank();
    defer a.free(bytes);
    const owner = try preview.Provider.create(a, bytes, .{});
    defer owner.destroy() catch @panic("provider retained");
    var probe: ProviderProbe = .{};
    owner.semantic = .{ .context = &probe, .emit = ProviderProbe.event };
    const provider = owner.provider();
    const sound = owner.loaded.tables.sounds[owner.sounds[0]];
    const opened = try provider.open(provider.context, .{ .bank_hash = owner.loaded.content_hash, .asset_generation = owner.loaded.metadata.generation, .sound_id = sound.key.id, .encoded_hash = sound.audio_hash, .encoded_bytes = sound.blob_length });
    defer provider.close(provider.context, opened.token) catch @panic("token retained");
    var buffer: [65536]u8 = undefined;
    const destination = buffer[0..@min(buffer.len, @as(usize, @intCast(sound.blob_length)))];
    try provider.read_at(provider.context, opened.token, 0, destination);
    try t.expectEqualSlices(u8, &hash(destination), &probe.digest.?);
    probe.digest = null;
    owner.fault.fail_read_call = owner.counts.read_attempts + 1;
    try t.expectError(error.SourceReadFailed, provider.read_at(provider.context, opened.token, 0, destination));
    try t.expectEqual(error.SourceReadFailed, probe.failure.?);
    try t.expect(probe.digest == null);
}
