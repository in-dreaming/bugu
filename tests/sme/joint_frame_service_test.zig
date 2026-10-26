//! Test-only joint Service adapter. No protocol, replay-mode or result injection.
//! Deliberate interleavings use existing test hooks, never capture callbacks.
const std = @import("std");
const f = @import("sme-stream-reload-fixture");
const stream = @import("sme-streaming").stream;
const opus = @import("sme-opus");
const admission = @import("sme-author-live-admission");
const t = std.testing;
const a = t.allocator;
const Read = stream.readiness_observation;
const Source = struct {
    bytes: []const u8,
    fn read(raw: *anyopaque, offset: u64, destination: []u8) opus.Error!void {
        const self: *Source = @ptrCast(@alignCast(raw));
        if (offset > self.bytes.len or destination.len > self.bytes.len - offset) return error.TruncatedContainer;
        @memcpy(destination, self.bytes[@intCast(offset)..][0..destination.len]);
    }
};
const Plan = enum { none, render_after_sequence, render_after_frame, render_before_final, worker_during_scan };
const Probe = struct {
    service: *stream.Service,
    handle: stream.Handle = .{ .index = 0, .generation = 0 },
    plan: Plan = .none,
    frame: u64 = 8,
    fired: bool = false,
    worker_error: ?stream.Error = null,
    worker_job: ?u64 = null,
    query_odd: bool = false,
    close_under_guard: bool = false,
    guard_close_error: ?stream.Error = null,
    guard_close_attempts: usize = 0,
    odd_result: ?stream.Error = null,
    odd_defer: ?stream.LiveObservationDeferV1 = null,
    odd_read: Read.QueryRead = .{},
    points: [2048]stream.live_semantic.Point = undefined,
    len: usize = 0,
    overflow: bool = false,
    fn point(raw: *anyopaque, p: stream.live_semantic.Point) void {
        const self: *Probe = @ptrCast(@alignCast(raw));
        if (self.len == self.points.len) {
            self.overflow = true;
            return;
        }
        self.points[self.len] = p;
        self.len += 1;
    }
    fn boundary(_: *anyopaque, _: stream.live_semantic.BoundaryPoint) void {}
    fn readHook(raw: *anyopaque, stage: Read.ReadStage, _: u64) void {
        const self: *Probe = @ptrCast(@alignCast(raw));
        if (self.fired) return;
        const hit = switch (self.plan) {
            .none => false,
            .render_after_sequence => stage == .after_sequence,
            .render_after_frame => stage == .after_frame,
            .render_before_final => stage == .before_final_sequence,
            .worker_during_scan => stage == .before_job_state,
        };
        if (!hit) return;
        self.fired = true;
        if (self.plan == .worker_during_scan) {
            self.worker_job = self.service.workerOne() catch |err| {
                self.worker_error = err;
                return;
            };
        } else self.service.endRenderSpan(self.frame);
    }
    fn frontier(raw: *anyopaque, stage: Read.FrontierStage, _: u64) void {
        const self: *Probe = @ptrCast(@alignCast(raw));
        if (!self.query_odd or stage != .after_odd) return;
        self.query_odd = false;
        _ = self.service.readinessLiveObservedV1(self.handle, .{ .accepted_control_frame = self.frame, .control_tick = 1, .input_order = 1 }, 1, 1, &self.odd_read, .{}, &self.odd_defer) catch |err| {
            self.odd_result = err;
            return;
        };
    }
    fn checkpoint(raw: *anyopaque, p: stream.OfflineCheckpoint) void {
        const self: *Probe = @ptrCast(@alignCast(raw));
        if (!self.close_under_guard or p.site != .slot_guard_render_claim or p.edge != .after or p.index != self.handle.index or p.value != 0) return;
        self.close_under_guard = false;
        self.guard_close_attempts += 1;
        self.service.close(self.handle) catch |err| {
            self.guard_close_error = err;
            return;
        };
    }
    fn reset(self: *Probe, plan: Plan, frame: u64) void {
        self.plan = plan;
        self.frame = frame;
        self.fired = false;
    }
};
fn query(service: *stream.Service, handle: stream.Handle, frame: u64, observed: *Read.QueryRead, deferred: *?stream.LiveObservationDeferV1) !@import("sme-trace").Input {
    return service.readinessLiveObservedV1(handle, .{ .accepted_control_frame = frame, .control_tick = 1, .input_order = 1 }, 1, 1, observed, .{}, deferred);
}
fn compareFrozenRead(observed: Read.QueryRead, expected_frame: u64, expected_consumed: u64) !void {
    if (!observed.has(.observation_frame) or !observed.has(.consumed) or observed.frame != expected_frame or observed.consumed != expected_consumed) return error.ObservationMismatch;
}
fn assertPrefix(points: []const stream.live_semantic.Point, first: stream.Handle, second: stream.Handle, frame: u64, first_closed: bool) !void {
    var after: [16]stream.live_semantic.Point = undefined;
    var len: usize = 0;
    for (points) |p| if (p.role == .render and p.edge == .after) {
        if (len == after.len) return error.ExtraCut;
        after[len] = p;
        len += 1;
    };
    try t.expectEqual(@as(usize, if (first_closed) 7 else 9), len);
    var i: usize = 0;
    try t.expectEqual(.service_render_sequence_odd, after[i].site);
    i += 1;
    const handles = [_]stream.Handle{ first, second };
    for (0..2) |slot| {
        const h = if (first.index == slot) handles[0] else handles[1];
        try t.expectEqual(.service_slot_guard_render_claim, after[i].site);
        try t.expectEqual(slot, after[i].index);
        const closed = first_closed and slot == first.index;
        try t.expectEqual(@as(u64, if (closed) 2 else 0), after[i].value.?);
        i += 1;
        if (closed) continue;
        try t.expectEqual(.service_render_consumed, after[i].site);
        try t.expectEqual(slot, after[i].index);
        try t.expectEqual(h.generation, after[i].generation);
        i += 1;
        try t.expectEqual(.service_slot_guard_render_release, after[i].site);
        try t.expectEqual(slot, after[i].index);
        i += 1;
    }
    try t.expectEqual(.service_stream_observation_frame, after[i].site);
    try t.expectEqual(frame, after[i].value.?);
    i += 1;
    try t.expectEqual(.service_render_sequence_even, after[i].site);
    i += 1;
    try t.expectEqual(len, i);
}
test "joint Service frozen hook plans preserve reads sequence jobs guards lifetime and strict errors" {
    const source_text = try std.mem.replaceOwned(u8, a, f.authored_source, "max_chunk_bytes=262144", "max_chunk_bytes=65536");
    defer a.free(source_text);
    const bytes = try f.buildSource(.a, source_text, null);
    defer a.free(bytes);
    var bank = try f.bank.MusicBank.load(a, bytes);
    defer bank.deinit();
    const sound = bank.tables.sounds[0];
    var source: Source = .{ .bytes = bank.tables.blob[@intCast(sound.blob_offset)..][0..@intCast(sound.blob_length)] };
    const service = try stream.Service.create(a, .{ .max_streams = 2, .max_channels = 2, .job_capacity = 2, .completion_capacity = 2, .max_encoded_chunk_bytes = 65536 });
    defer service.destroy() catch @panic("retained service");
    var probe: Probe = .{ .service = service };
    const hooks: stream.LiveSemanticHooks = .{ .cuts = .{ .context = &probe, .point = Probe.point, .boundary = Probe.boundary } };
    try service.attachLiveSemanticQuiescent(hooks);
    defer service.detachLiveSemanticQuiescent(hooks) catch @panic("retained semantic binding");
    var asset = try service.prepareAsset(.{ .sound_index = 0, .sound = sound, .codec = bank.tables.codecs[sound.codec], .chunks = bank.tables.chunks[sound.chunks.first..][0..sound.chunks.count], .seeks = bank.tables.seeks[sound.seeks.first..][0..sound.seeks.count], .source = .{ .context = &source, .length = source.bytes.len, .read_at = Source.read } });
    defer asset.retire();
    var h = try service.open(&asset, .{ .generation = 1, .transport_epoch = 1, .group = 1, .layer = 1 });
    defer service.close(h) catch @panic("retained first stream");
    const other = try service.open(&asset, .{ .generation = 1, .transport_epoch = 1, .group = 1, .layer = 2 });
    defer service.close(other) catch @panic("retained second stream");
    try service.attachRuntime();
    defer service.detachRuntimeQuiescent() catch @panic("retained runtime");
    service.test_readiness_hook = .{ .context = &probe, .call = Probe.readHook };
    service.test_frontier_hook = .{ .context = &probe, .call = Probe.frontier };
    service.test_checkpoint_hook = .{ .context = &probe, .call = Probe.checkpoint };
    defer {
        service.test_readiness_hook = null;
        service.test_frontier_hook = null;
        service.test_checkpoint_hook = null;
    }
    probe.handle = h;
    var observed: Read.QueryRead = .{};
    var deferred: ?stream.LiveObservationDeferV1 = null;
    const initial = try query(service, h, 0, &observed, &deferred);
    try t.expect(deferred == null);
    try compareFrozenRead(observed, 0, 0);
    try t.expect(observed.has(.sequence_after) and observed.sequence_before == observed.sequence_after);
    try t.expectEqual(@as(u16, 2), observed.scanned);
    try t.expectEqual(@as(u64, 0), initial.payload.readiness_snapshot.facts.backlog_frames);
    try t.expectError(error.ObservationMismatch, compareFrozenRead(observed, 1, 0));

    // A real Render publication between sequence and frame causes early failure.
    probe.reset(.render_after_sequence, 8);
    observed = .{};
    try t.expectError(error.InvalidState, query(service, h, 0, &observed, &deferred));
    try t.expect(probe.fired);
    try t.expectEqual(.frame_mismatch, deferred.?.reason);
    try t.expectEqual(@as(u64, 8), observed.frame);
    try t.expect(!observed.has(.consumed) and !observed.has(.sequence_after));

    // Correct acquired frame followed by new publication must fail final sequence.
    probe.reset(.render_after_frame, 16);
    observed = .{};
    try t.expectError(error.InvalidState, query(service, h, 8, &observed, &deferred));
    try t.expectEqual(.sequence_changed, deferred.?.reason);
    try t.expect(observed.has(.consumed) and observed.has(.sequence_after));
    try t.expect(observed.sequence_before != observed.sequence_after);
    // Equal-value publication also advances sequence; value equality is not identity.
    probe.reset(.render_before_final, 16);
    observed = .{};
    try t.expectError(error.InvalidState, query(service, h, 16, &observed, &deferred));
    try t.expectEqual(.sequence_changed, deferred.?.reason);
    try t.expectEqual(@as(u64, 16), observed.frame);

    probe.reset(.none, 24);
    probe.query_odd = true;
    service.endRenderSpan(24);
    try t.expectEqual(error.InvalidState, probe.odd_result.?);
    try t.expectEqual(.odd_sequence, probe.odd_defer.?.reason);
    try t.expect(probe.odd_read.has(.sequence_before));
    try t.expect(!probe.odd_read.has(.observation_frame) and !probe.odd_read.has(.consumed));

    // Both pending jobs are produced by actual request, decoded by actual Worker.
    _ = (try service.request(h)) orelse return error.MissingJob;
    _ = (try service.request(other)) orelse return error.MissingJob;
    observed = .{};
    const before = try query(service, h, 24, &observed, &deferred);
    const states_before = observed;
    try t.expect(before.payload.readiness_snapshot.facts.backlog_jobs == 1);
    try t.expect(before.payload.readiness_snapshot.facts.backlog_frames > 0);
    probe.reset(.worker_during_scan, 24);
    observed = .{};
    const after = try query(service, h, 24, &observed, &deferred);
    try t.expect(probe.fired and probe.worker_error == null and probe.worker_job != null);
    try t.expectEqual(before.payload.readiness_snapshot.facts.backlog_frames, after.payload.readiness_snapshot.facts.backlog_frames);
    try t.expectEqual(before.payload.readiness_snapshot.facts.queued_frames, after.payload.readiness_snapshot.facts.queued_frames);
    try t.expect(!std.mem.eql(u8, &states_before.states, &observed.states));
    probe.reset(.none, 24);
    _ = try service.workerOne();
    var input_order: u32 = 1;
    var attempt: stream.LiveAcceptanceAttemptV1 = undefined;
    while (try service.acceptCompletedLiveV1(.{ .accepted_control_frame = 24, .control_tick = 2, .input_order = input_order }, input_order, &attempt)) |accepted| {
        try t.expectEqual(.ready, accepted.input.payload.worker.state);
        try t.expect(attempt.returned_error == null and attempt.cut != null);
        input_order += 1;
    }
    try t.expectEqual(@as(u32, 3), input_order);
    const frontier = service.publicationFrontier();
    var gate_order: u32 = 1;
    while (try service.admitPublication(frontier, 1, 24, gate_order)) |_| {
        gate_order += 1;
    }
    try t.expectEqual(@as(u32, 3), gate_order);
    var acknowledged: usize = 0;
    while (service.pollVisibility()) |_| {
        acknowledged += 1;
    }
    try t.expectEqual(@as(usize, 2), acknowledged);
    const pcm = try service.ringFor(h);
    var sample: [2]f32 = undefined;
    try t.expect(pcm.peek(0, 0, sample[0..pcm.channels]));
    pcm.consume();
    // Control sees the last completed prefix, not instantaneous consumed.
    observed = .{};
    _ = try query(service, h, 24, &observed, &deferred);
    try compareFrozenRead(observed, 24, 0);
    probe.close_under_guard = true;
    const prefix_start = probe.len;
    service.endRenderSpan(25);
    try assertPrefix(probe.points[prefix_start..probe.len], h, other, 25, false);
    try t.expectEqual(@as(usize, 1), probe.guard_close_attempts);
    try t.expectEqual(error.DrainPending, probe.guard_close_error.?);
    var close_guard_reached = false;
    for (probe.points[prefix_start..probe.len]) |p| {
        if (p.site == .service_slot_guard_close and p.edge == .after and p.index == h.index and p.value == 1) close_guard_reached = true;
    }
    try t.expect(close_guard_reached);
    observed = .{};
    _ = try query(service, h, 25, &observed, &deferred);
    try compareFrozenRead(observed, 25, 1);
    try t.expectError(error.ObservationMismatch, compareFrozenRead(observed, 25, 0));

    // Real lease blocks close; then genuine close/open changes incarnation.
    try pcm.retain();
    try t.expectError(error.DrainPending, service.close(h));
    pcm.release();
    const old = h;
    try service.cancel(h);
    try service.close(h);
    const closed_start = probe.len;
    service.endRenderSpan(26); // closed slot guard fails safely, no descriptor read
    try assertPrefix(probe.points[closed_start..probe.len], old, other, 26, true);
    h = try service.open(&asset, .{ .generation = 1, .transport_epoch = 1, .group = 1, .layer = 1 });
    try t.expectEqual(old.index, h.index);
    try t.expect(h.generation != old.generation);
    observed = .{};
    try t.expectError(error.StaleStream, query(service, old, 26, &observed, &deferred));
    try t.expectEqual(@as(u64, 0), observed.reached);
    try t.expectError(error.StaleStream, service.close(old));
    service.endRenderSpan(27);
    observed = .{};
    _ = try query(service, h, 27, &observed, &deferred);
    try compareFrozenRead(observed, 27, 0);
    try t.expect(!probe.overflow);
}
test "joint current author Live rejects valid crossfade configuration before owner creation" {
    var config = admission.default_config;
    try admission.validateConfig(config);
    config.streaming_reservation = .release_profile;
    try config.validate();
    try t.expectError(error.UnsupportedLiveConfig, admission.validateConfig(config));
    config.crossfade.bindings = &.{.{ .transition_id = 1, .curve = .linear }};
    try config.validate();
    try t.expectError(error.UnsupportedLiveConfig, admission.validateConfig(config));
    config.streaming_reservation = .initial_bank_only;
    try config.crossfade.validate();
    try t.expectError(error.UnsupportedCapability, config.validate());
    try t.expectError(error.UnsupportedCapability, admission.validateConfig(config));
}
