//! New implementation after source recovery, not the original b6b34e8 blob.
//! Real decoded completions and a bounded actual Render frontier barrier.
//! Offline causal regression, not a Windows timing or native device claim.
const std = @import("std");
const f = @import("sme-stream-reload-fixture");
const source = @import("sme-author-preview-v1").source;
const stream = @import("sme-streaming").stream;
const t = std.testing;
const a = t.allocator;

const Rig = struct {
    engine: *f.Rig,
    provider: *source.Provider,
    fn create(bytes: []const u8) !Rig {
        const provider = try source.Provider.create(a, bytes, .{});
        errdefer provider.destroy() catch @panic("provider retained");
        const engine = try f.Rig.createWithConfig(.{ .kind = .authoring, .control_driver = .integrated, .quantum_frames = 256 });
        errdefer engine.finish() catch @panic("owner retained");
        try engine.enableWorkerThread();
        const ticket = try engine.run.owner.loadBankWithSources(bytes, provider.provider());
        for (0..128) |_| {
            _ = try engine.workerOne();
            switch (try engine.run.owner.pollLoad(ticket)) {
                .pending => {},
                .failed => return error.LoadFailed,
                .ready => |loaded| {
                    engine.run.bank = loaded.bank;
                    try engine.run.owner.acknowledgeLoad(ticket);
                    return .{ .engine = engine, .provider = provider };
                },
            }
        }
        return error.LoadDidNotFinish;
    }
    fn finish(self: Rig) !void {
        try self.engine.finishChronology();
        try self.provider.destroy();
    }
};
fn bank() ![]u8 {
    const text = try std.mem.replaceOwned(u8, a, f.authored_source, "max_chunk_bytes=262144", "max_chunk_bytes=65536");
    defer a.free(text);
    return f.buildSource(.a, text, null);
}

fn ready(rig: Rig) ![4]stream.Handle {
    const owner = rig.engine.run.owner;
    const service = owner.owned_streaming.?;
    const ticket = try owner.start(rig.engine.run.bank.?, f.state);
    var executed = false;
    for (0..512) |_| {
        _ = try owner.controlTickLiveChronologyV1(f.rt.max_control_drain, null);
        try rig.engine.workers();
        var pcm: [128]f32 = undefined;
        rig.engine.run.renderer.render(&pcm, 64, 2);
        while (try owner.pollReceiptV1()) |receipt| {
            try t.expectEqualDeep(ticket, receipt.ticket);
            if (receipt.event == .terminal) {
                try t.expect(receipt.event.terminal == .executed);
                rig.engine.start_frame = receipt.event.terminal.executed.effective_frame;
                executed = true;
            }
        }
        if (executed and owner.pending == null and owner.preparing == null) break;
    }
    try t.expect(executed);
    try t.expectEqual(.playing, owner.state);
    const group = owner.active_group orelse return error.MissingActiveGroup;
    var handles: [4]stream.Handle = undefined;
    var count: usize = 0;
    for (owner.generation.?.windows) |item| if (item) |window| {
        if (window.retiring or window.group == null or !window.group.?.eql(group)) continue;
        if (count == handles.len) return error.TooManyActiveWindows;
        handles[count] = window.binding.handle;
        count += 1;
    };
    try t.expectEqual(@as(usize, 4), count);
    // No Render here: genuine accepted suffixes can await admission. Raw
    // produced-minus-consumed proves actual fill, not yet-visible availability.
    for (0..128) |_| {
        try rig.engine.workers();
        _ = try owner.controlTickLiveChronologyV1(f.rt.max_control_drain, null);
        var settled = true;
        for (handles) |handle| {
            const ring = try service.ringFor(handle);
            if (service.slots[handle.index].pending_job != null or
                ring.produced.load(.acquire) - ring.consumed.load(.acquire) < service.profile.high_frames) settled = false;
        }
        if (settled) return handles;
    }
    return error.InitialFillDidNotSettle;
}

fn pause() void {
    std.Io.sleep(t.io, .fromMilliseconds(1), .awake) catch {};
}
fn expired(start: anytype) bool {
    return start.durationTo(std.Io.Clock.awake.now(t.io)).nanoseconds >= 5 * std.time.ns_per_s;
}
const Probe = struct {
    renderer: *f.runtime.audio.RuntimeRenderer,
    release_on_first: bool,
    thread: ?std.Thread = null,
    reached: std.atomic.Value(bool) = .init(false),
    released: std.atomic.Value(bool) = .init(false),
    timed_out: std.atomic.Value(bool) = .init(false),
    pcm: [128]f32 = undefined,
    attempts: [8]stream.LiveAcceptanceAttemptV1 = undefined,
    finished: [8]bool = undefined,
    count: usize = 0,
    overflow: bool = false,
    fn render(self: *Probe) void {
        self.renderer.render(&self.pcm, 64, 2);
    }
    fn frontier(raw: *anyopaque, stage: stream.readiness_observation.FrontierStage, _: u64) void {
        const self: *Probe = @ptrCast(@alignCast(raw));
        if (stage != .after_odd) return;
        self.reached.store(true, .release);
        const began = std.Io.Clock.awake.now(t.io);
        while (!self.released.load(.acquire)) {
            if (expired(began)) {
                self.timed_out.store(true, .release);
                return;
            }
            pause();
        }
    }
    fn stop(self: *Probe) void {
        self.released.store(true, .release);
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }
    fn attempt(raw: *anyopaque, value: *const stream.LiveAcceptanceAttemptV1, _: u64, finished: bool) void {
        const self: *Probe = @ptrCast(@alignCast(raw));
        if (self.count == self.attempts.len) {
            self.overflow = true;
            return;
        }
        self.attempts[self.count] = value.*;
        self.finished[self.count] = finished;
        self.count += 1;
        // Explicit test workload seam after the real attempt returns. Joining
        // completes the actual frontier; it never supplies an engine value.
        if (self.count == 1 and self.release_on_first) self.stop();
    }
};
// Test-only observation after real Render joins/returns; no consumer cursor
// moves and cleanup still owns collection of the exact pending receipt.
fn pendingFault(control: *f.rt.ControlRuntime) ?f.rt.StreamFault {
    const queue = &control.stream_faults;
    const read = queue.read_position.load(.acquire);
    if (read == queue.write_position.load(.acquire)) return null;
    return queue.values[read % queue.values.len];
}
const Case = enum { release, hold, empty };
fn exercise(case: Case) !void {
    const bytes = try bank();
    defer a.free(bytes);
    var oracle = try f.Oracle.decode(bytes);
    defer oracle.deinit();
    const rig = try Rig.create(bytes);
    defer rig.finish() catch @panic("acceptance retry fixture retained custody");
    const handles = try ready(rig);
    const owner = rig.engine.run.owner;
    const service = owner.owned_streaming.?;
    const renderer = rig.engine.run.renderer;
    var jobs: [4]u64 = undefined;
    var prefixes: [4]u64 = undefined;
    if (case != .empty) {
        const first_ring = try service.ringFor(handles[0]);
        const remaining = first_ring.produced.load(.acquire) - first_ring.consumed.load(.acquire);
        try t.expect(remaining > 64 and remaining <= 6144);
        for (handles) |handle| {
            const ring = try service.ringFor(handle);
            try t.expectEqual(remaining, ring.produced.load(.acquire) - ring.consumed.load(.acquire));
        }
        // Actual DSP consumes all but its final64; no readiness/counter writes.
        var pcm: [6144 * 2]f32 = undefined;
        const drain: u32 = @intCast(remaining - 64);
        renderer.render(pcm[0 .. @as(usize, drain) * 2], drain, 2);
        for (handles, 0..) |handle, i| {
            const ring = try service.ringFor(handle);
            try t.expectEqual(@as(u64, 64), ring.available());
            prefixes[i] = ring.visible_produced.load(.acquire);
            jobs[i] = (try service.request(handle)) orelse return error.ExpectedActualRefill;
        }
        try rig.engine.workers();
    }
    const accepted_before = service.accepted_count;
    const first_frame = renderer.renderFrame();
    var probe: Probe = .{ .renderer = renderer, .release_on_first = case == .release };
    owner.control.test_live_acceptance_attempt = .{ .context = &probe, .call = Probe.attempt };
    defer {
        // Must precede hook-context destruction and every fixture shutdown.
        probe.stop();
        owner.control.test_live_acceptance_attempt = null;
        service.test_frontier_hook = null;
    }
    if (case != .empty) {
        service.test_frontier_hook = .{ .context = &probe, .call = Probe.frontier };
        probe.thread = try std.Thread.spawn(.{}, Probe.render, .{&probe});
        const began = std.Io.Clock.awake.now(t.io);
        while (!probe.reached.load(.acquire)) {
            if (expired(began)) return error.RenderDidNotReachBarrier;
            pause();
        }
    }
    _ = try owner.controlTickLiveChronologyV1(f.rt.max_control_drain, null);
    probe.stop();
    owner.control.test_live_acceptance_attempt = null;
    service.test_frontier_hook = null;
    var next_pcm: [128]f32 = undefined;
    var visible_before: [4]u64 = undefined;
    var visible_after: [4]u64 = undefined;
    var actual_fault: ?f.rt.StreamFault = null;
    if (case == .release) {
        for (handles, 0..) |handle, i| visible_before[i] = (try service.ringFor(handle)).visible_produced.load(.acquire);
        // Preserve the missing-suffix physical consequence on unchanged
        // production BEFORE any assertion can exit or cleanup can accept it.
        renderer.render(&next_pcm, 64, 2);
        for (handles, 0..) |handle, i| visible_after[i] = (try service.ringFor(handle)).visible_produced.load(.acquire);
        std.debug.print("ACCEPTANCE_RETRY attempts={d} accepted_before={d} accepted_after={d} frame={d} visible_before={any} visible_after={any} collected_fault_count={d}\n", .{ probe.count, accepted_before, service.accepted_count, renderer.renderFrame(), visible_before, visible_after, owner.stream_fault_count });
        // Collected count can be stale: this is the actual next-Render receipt.
        actual_fault = pendingFault(owner.control);
        if (actual_fault) |fault| std.debug.print("ACCEPTANCE_RETRY_FAULT frame={d} cursor={d} layer={d}\n", .{ fault.frame, fault.cursor, fault.layer });
    }
    try t.expect(!probe.timed_out.load(.acquire));
    try t.expect(!probe.overflow);
    if (case == .empty) {
        try t.expectEqual(@as(usize, 1), probe.count);
        try t.expectEqual(.no_completion, probe.attempts[0].evidence.outcome);
        try t.expectEqual(accepted_before, service.accepted_count);
        return;
    }
    try t.expect(probe.attempts[0].evidence.selected != null);
    try t.expectEqual(jobs[0], probe.attempts[0].evidence.selected.?.descriptor.job);
    try t.expectEqual(.ready, probe.attempts[0].evidence.selected.?.outcome);
    try t.expectEqual(.odd_sequence, probe.attempts[0].deferred.?.reason);
    try t.expectEqual(.availability_unavailable, probe.attempts[0].evidence.outcome);
    try t.expect(probe.attempts[0].evidence.publication == null);
    try t.expectEqualDeep(stream.observation.Effects{}, probe.attempts[0].evidence.effects);
    try t.expect(!probe.finished[0]);
    if (case == .hold) {
        try t.expectEqual(@as(usize, 2), probe.count);
        try t.expectEqualDeep(probe.attempts[0].incoming, probe.attempts[1].incoming);
        try t.expectEqualDeep(probe.attempts[0].evidence.selected, probe.attempts[1].evidence.selected);
        try t.expectEqual(.odd_sequence, probe.attempts[1].deferred.?.reason);
        try t.expectEqualDeep(stream.observation.Effects{}, probe.attempts[1].evidence.effects);
        try t.expect(!probe.finished[1]);
        try t.expectEqual(accepted_before, service.accepted_count);
        for (handles, 0..) |handle, i| try t.expectEqual(prefixes[i], (try service.ringFor(handle)).produced.load(.acquire));
        return;
    }
    try t.expectEqual(accepted_before + 4, service.accepted_count);
    try t.expectEqual(@as(usize, 6), probe.count);
    try t.expectEqualDeep(probe.attempts[0].incoming, probe.attempts[1].incoming);
    try t.expectEqualDeep(probe.attempts[0].evidence.selected, probe.attempts[1].evidence.selected);
    for (jobs, 0..) |job, i| {
        const attempt = probe.attempts[i + 1];
        const publication = attempt.evidence.publication orelse return error.MissingActualPublication;
        try t.expect(probe.finished[i + 1]);
        try t.expectEqual(job, publication.worker_job);
        try t.expectEqual(probe.attempts[0].incoming.control_tick, attempt.incoming.control_tick);
        try t.expectEqual(probe.attempts[0].incoming.input_order + @as(@TypeOf(attempt.incoming.input_order), @intCast(i)), attempt.incoming.input_order);
        try t.expectEqual(prefixes[i], publication.prefix_start);
        try t.expectEqual(prefixes[i] + attempt.evidence.selected.?.count, publication.prefix_end);
        try t.expectEqual(prefixes[i], visible_before[i]);
        try t.expectEqual(publication.prefix_end, visible_after[i]);
    }
    try t.expectEqual(.no_completion, probe.attempts[5].evidence.outcome);
    try t.expectEqual(probe.attempts[0].incoming.input_order + 4, probe.attempts[5].incoming.input_order);
    var evidence: f.Oracle.Evidence = .{};
    try evidence.expectPcm(&oracle, first_frame, rig.engine.start_frame, &probe.pcm);
    try evidence.expectPcm(&oracle, first_frame + 64, rig.engine.start_frame, &next_pcm);
    try t.expect(evidence.nonzero > 0);
    try t.expect(actual_fault == null);
}

test "chronology retries one actual odd ready completion in the same tick" {
    try exercise(.release);
}
test "chronology acceptance returns after two attempts while real Render stays odd" {
    try exercise(.hold);
}
test "chronology acceptance does not retry actual no completion" {
    try exercise(.empty);
}
