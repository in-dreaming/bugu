//! Deterministic actual-DSP first-defer background supply regression.
//! Offline workload only, not a native scheduling or Windows qualification.
const std = @import("std");
const f = @import("sme-stream-reload-fixture");
const source = @import("sme-author-preview-v1").source;
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
                .ready => |ready| {
                    engine.run.bank = ready.bank;
                    try engine.run.owner.acknowledgeLoad(ticket);
                    return .{ .engine = engine, .provider = provider };
                },
            }
        }
        return error.LoadDidNotFinish;
    }
    fn finish(self: Rig, chronology: bool) !void {
        if (chronology) try self.engine.finishChronology() else try self.engine.finish();
        try self.provider.destroy();
    }
};
fn bank() ![]u8 {
    const text = try std.mem.replaceOwned(u8, a, f.authored_source, "max_chunk_bytes=262144", "max_chunk_bytes=65536");
    defer a.free(text);
    return f.buildSource(.a, text, null);
}

const stream = @import("sme-streaming").stream;
const Probe = struct {
    owner: *f.music.MusicRuntime,
    renderer: *f.runtime.audio.RuntimeRenderer,
    handles: [4]stream.Handle,
    current: ?usize = null,
    armed: bool = false,
    rendered: bool = false,
    visits: [4]usize = @splat(0),
    queued: [4]usize = @splat(0),
    returns: [16]stream.TestSupplyReturn = undefined,
    return_count: usize = 0,
    return_overflow: bool = false,
    fn returned(raw: *anyopaque, point: stream.TestSupplyReturn) void {
        const self: *Probe = @ptrCast(@alignCast(raw));
        if (!self.armed) return;
        if (self.return_count == self.returns.len) {
            self.return_overflow = true;
            return;
        }
        self.returns[self.return_count] = point;
        self.return_count += 1;
    }
    fn tick(raw: *anyopaque, stage: f.music.MusicRuntime.TickStage) void {
        const self: *Probe = @ptrCast(@alignCast(raw));
        if (stage == .before_background_supply) self.armed = true;
        if (stage == .after_background_supply) self.armed = false;
    }
    fn supply(raw: *anyopaque, point: stream.TestSupplyPoint) void {
        const self: *Probe = @ptrCast(@alignCast(raw));
        if (!self.armed) return;
        for (self.handles, 0..) |handle, i| if (std.meta.eql(handle, point.handle)) {
            if (point.stage == .prefetch_begin) {
                self.current = i;
                self.visits[i] += 1;
            }
            if (point.stage == .request_queued) self.queued[i] += 1;
            return;
        };
    }
    fn availability(raw: *anyopaque, stage: stream.AvailabilityStage, _: u64) void {
        const self: *Probe = @ptrCast(@alignCast(raw));
        if (!self.armed or self.rendered or self.current != 0 or stage != .after_sequence) return;
        self.rendered = true;
        // Actual DSP publishes the new sequence; no engine counters are assigned.
        var pcm: [128]f32 = undefined;
        self.renderer.render(&pcm, 64, 2);
    }
};

const Case = enum { chronology, legacy_background, request_scope, later_error };

fn exercise(case: Case) !void {
    const bytes = try bank();
    defer a.free(bytes);
    const rig = try Rig.create(bytes);
    defer rig.finish(true) catch @panic("background test retained custody");
    const owner = rig.engine.run.owner;
    const service = owner.owned_streaming.?;
    const ticket = try owner.start(rig.engine.run.bank.?, f.state);
    var executed = false;
    for (0..512) |_| {
        _ = try owner.controlTickLiveChronologyV1(f.rt.max_control_drain, null);
        try rig.engine.workers();
        const pcm = try rig.engine.run.render(64);
        a.free(pcm);
        while (try owner.pollReceiptV1()) |receipt| {
            try t.expectEqualDeep(ticket, receipt.ticket);
            if (receipt.event == .terminal) {
                try t.expect(receipt.event.terminal == .executed);
                executed = true;
            }
        }
        if (executed and owner.pending == null and owner.preparing == null) break;
    }
    try t.expect(executed);
    try t.expectEqual(.playing, owner.state);
    const group = owner.active_group orelse return error.MissingActiveGroup;
    try t.expect(owner.device_stream_origin != null);
    var handles: [4]stream.Handle = undefined;
    var count: usize = 0;
    for (owner.generation.?.windows) |item| if (item) |window| {
        if (window.retiring or window.group == null or !window.group.?.eql(group)) continue;
        if (count == handles.len) return error.TooManyActiveWindows;
        handles[count] = window.binding.handle;
        count += 1;
    };
    try t.expectEqual(@as(usize, 4), count);
    // Settle actual queued work until each stem has lead and no outstanding job.
    var settled = false;
    for (0..128) |_| {
        _ = try owner.controlTickLiveChronologyV1(f.rt.max_control_drain, null);
        var ready = true;
        for (handles) |handle| {
            const ring = try service.ringFor(handle);
            if (service.slots[handle.index].pending_job != null or ring.available() < 4096) ready = false;
        }
        if (ready) {
            settled = true;
            break;
        }
        try rig.engine.workers();
        const pcm = try rig.engine.run.render(64);
        a.free(pcm);
    }
    try t.expect(settled);
    // Consume genuine samples, without refill, until all streams need supply.
    for (0..128) |_| {
        var below = true;
        for (handles) |handle| if ((try service.ringFor(handle)).available() >= service.profile.low_frames) {
            below = false;
        };
        if (below) break;
        const pcm = try rig.engine.run.render(64);
        a.free(pcm);
    }
    for (handles) |handle| {
        const available = (try service.ringFor(handle)).available();
        try t.expect(available >= 128 and available < service.profile.low_frames);
        try t.expect(service.slots[handle.index].pending_job == null);
    }
    var probe: Probe = .{ .owner = owner, .renderer = rig.engine.run.renderer, .handles = handles };
    owner.test_tick_hook = .{ .context = &probe, .call = Probe.tick };
    service.test_supply_hook = .{ .context = &probe, .call = Probe.supply };
    service.test_supply_return_hook = .{ .context = &probe, .call = Probe.returned };
    service.test_availability_hook = .{ .context = &probe, .call = Probe.availability };
    defer {
        owner.test_tick_hook = null;
        service.test_supply_hook = null;
        service.test_supply_return_hook = null;
        service.test_availability_hook = null;
    }
    if (case == .later_error) try service.cancel(handles[1]);
    const observed = switch (case) {
        .chronology => blk: {
            const outcome = try owner.controlTickLiveChronologyV1(f.rt.max_control_drain, null);
            const deferred = outcome.deferred orelse return error.MissingActualDefer;
            try t.expectEqual(.background_supply, deferred.stage);
            break :blk deferred.observation;
        },
        .legacy_background => blk: {
            probe.armed = true;
            break :blk (try owner.generation.?.prefetchStableActiveWindowsLiveV1(null, owner.control.scheduled.render_frame.load(.acquire), group)) orelse return error.MissingActualDefer;
        },
        .request_scope => blk: {
            probe.armed = true;
            break :blk (try owner.generation.?.prefetchRequestWindowsScopedLiveV1(.request, ticket.request_id, owner.control.scheduled.render_frame.load(.acquire))) orelse return error.MissingActualDefer;
        },
        .later_error => {
            // Explicit cancellation input. A genuine later InvalidState must
            // not be hidden by the first stream's typed sequence defer.
            try t.expectError(error.InvalidState, owner.controlTickLiveChronologyV1(f.rt.max_control_drain, null));
            try t.expect(probe.rendered);
            try t.expectEqual([4]usize{ 1, 1, 0, 0 }, probe.visits);
            try t.expectEqual([4]usize{ 0, 0, 0, 0 }, probe.queued);
            try t.expect(!probe.return_overflow);
            try t.expectEqual(@as(usize, 3), probe.return_count);
            try t.expectEqual(.availability_error, probe.returns[0].reason);
            const rejected = probe.returns[1];
            try t.expectEqual(.request, rejected.operation);
            try t.expect(rejected.nested_prefetch);
            try t.expectEqual(.cancelled, rejected.reason);
            try t.expectEqual(error.InvalidState, rejected.returned_error.?);
            try t.expect(rejected.available == null and !rejected.pending_observed and rejected.pending_job == null);
            try t.expect(rejected.job == null and rejected.job_slot == null and rejected.deferred == null);
            const outer = probe.returns[2];
            try t.expectEqual(.prefetch, outer.operation);
            try t.expectEqual(.nested_request, outer.reason);
            try t.expectEqualDeep(handles[1], outer.handle);
            try t.expectEqual(error.InvalidState, outer.returned_error.?);
            try t.expect(outer.available != null and outer.job == null and !outer.pending_observed);
            return;
        },
    };
    try t.expect(probe.rendered);
    const expected_reason: @TypeOf(observed.reason) = if (case == .request_scope) .frame_mismatch else .sequence_changed;
    try t.expectEqual(expected_reason, observed.reason);
    try t.expectEqualDeep(handles[0], observed.handle);
    std.debug.print("BACKGROUND_SWEEP actual_defer={s} visits={any} queued={any}\n", .{ @tagName(observed.reason), probe.visits, probe.queued });
    try t.expectEqual(if (case == .chronology) [4]usize{ 1, 1, 1, 1 } else [4]usize{ 1, 0, 0, 0 }, probe.visits);
    try t.expectEqual(if (case == .chronology) [4]usize{ 0, 1, 1, 1 } else [4]usize{ 0, 0, 0, 0 }, probe.queued);
    try t.expect(!probe.return_overflow);
    try t.expectEqual(@as(usize, if (case == .chronology) 7 else 1), probe.return_count);
    const first = probe.returns[0];
    try t.expectEqual(.prefetch, first.operation);
    try t.expectEqual(.availability_error, first.reason);
    try t.expectEqual(error.InvalidState, first.returned_error.?);
    try t.expectEqualDeep(observed, first.deferred.?);
    try t.expect(first.available == null and !first.pending_observed and first.pending_job == null);
    try t.expect(first.job == null and first.job_slot == null and !first.nested_prefetch);
    if (case == .chronology) {
        for (1..4) |i| {
            const inner = probe.returns[1 + (i - 1) * 2];
            const outer = probe.returns[2 + (i - 1) * 2];
            try t.expectEqual(.request, inner.operation);
            try t.expect(inner.nested_prefetch);
            try t.expectEqual(.queued, inner.reason);
            try t.expectEqualDeep(handles[i], inner.handle);
            try t.expect(inner.available != null and inner.pending_observed and inner.pending_job == null);
            try t.expect(inner.job != null and inner.job_slot != null and inner.returned_error == null and inner.deferred == null);
            try t.expectEqual(.prefetch, outer.operation);
            try t.expectEqual(.nested_request, outer.reason);
            try t.expectEqualDeep(inner.handle, outer.handle);
            try t.expectEqual(inner.job, outer.job);
            try t.expect(outer.available != null and !outer.pending_observed and outer.returned_error == null);
        }
        // No Worker pump occurs between the actual enqueue and this request.
        // The real pending branch must not invent an availability acquire.
        probe.armed = true;
        try t.expectEqual(@as(?u64, null), try service.request(handles[1]));
        const pending = probe.returns[7];
        try t.expectEqual(@as(usize, 8), probe.return_count);
        try t.expectEqual(.pending, pending.reason);
        try t.expect(!pending.nested_prefetch and pending.pending_observed);
        try t.expectEqual(probe.returns[1].job_slot, pending.pending_job);
        try t.expect(pending.available == null and pending.job == null and pending.returned_error == null);
        // An explicitly invalid caller handle exercises initialization before get.
        var stale = handles[1];
        stale.generation += 1;
        try t.expectError(error.StaleStream, service.request(stale));
        try t.expectEqual(@as(usize, 9), probe.return_count);
        const invalid = probe.returns[8];
        try t.expectEqual(.lookup_error, invalid.reason);
        try t.expectEqualDeep(stale, invalid.handle);
        try t.expectEqual(error.StaleStream, invalid.returned_error.?);
        try t.expect(!invalid.pending_observed and invalid.pending_job == null and invalid.available == null);
        try t.expect(invalid.job == null and invalid.job_slot == null and invalid.deferred == null);
        probe.armed = false;
    }
    try t.expectEqual(@as(u64, 0), (try owner.snapshotV1()).stream_fault_count);
}

test "chronology background visits later stems after first actual sequence defer" {
    try exercise(.chronology);
}
test "legacy background retains first actual defer" {
    try exercise(.legacy_background);
}
test "request scoped supply retains first actual defer" {
    try exercise(.request_scope);
}
test "later real supply error overrides first chronology defer" {
    try exercise(.later_error);
}
