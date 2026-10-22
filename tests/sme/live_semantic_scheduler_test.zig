//! Collector-free Scheduler cuts at native stores/loads. Serialized fixtures
//! establish caller exclusion; these tests are not a concurrent Host replay or
//! evidence that idle flags alone prove custody.
const std = @import("std");
const audio = @import("bugu_audio");
const scheduler = @import("sme-scheduler");
const semantic = @import("sme-live-semantic");
const order = @import("sme-capture-order");
const t = std.testing;
const Tiny = scheduler.Scheduler(u8);

const Probe = struct {
    points: [4096]semantic.Point = undefined,
    count: usize = 0,
    limit: usize = 4096,
    overflow: bool = false,
    boundaries: [1024]semantic.BoundaryPoint = undefined,
    boundary_count: usize = 0,
    ordinal: usize = 0,
    point_ordinals: [4096]usize = undefined,
    boundary_ordinals: [1024]usize = undefined,

    fn binding(self: *Probe) semantic.Binding {
        return .{ .context = self, .point = point, .boundary = boundary };
    }
    fn point(raw: *anyopaque, value: semantic.Point) void {
        const self: *Probe = @ptrCast(@alignCast(raw));
        // Output-only bounded copy, including overflow. Never inspect or alter
        // the Scheduler, synthesize outcomes, or retry the native operation.
        if (self.count == self.limit) {
            self.overflow = true;
            return;
        }
        self.points[self.count] = value;
        self.point_ordinals[self.count] = self.ordinal;
        self.count += 1;
        self.ordinal += 1;
    }
    fn boundary(raw: *anyopaque, value: semantic.BoundaryPoint) void {
        const self: *Probe = @ptrCast(@alignCast(raw));
        if (self.boundary_count == @min(self.limit, self.boundaries.len)) {
            self.overflow = true;
            return;
        }
        self.boundaries[self.boundary_count] = value;
        self.boundary_ordinals[self.boundary_count] = self.ordinal;
        self.boundary_count += 1;
        self.ordinal += 1;
    }
    fn foreignPoint(_: *anyopaque, _: semantic.Point) void {}
    fn foreignBoundary(_: *anyopaque, _: semantic.BoundaryPoint) void {}
    fn legacy(_: *anyopaque, _: scheduler.OfflineCheckpoint) void {}
    fn gate(_: *anyopaque, _: scheduler.GateStage) void {}

    fn countSite(self: *const Probe, role: semantic.Role, site: semantic.Site) usize {
        var count: usize = 0;
        for (self.points[0..self.count]) |value| {
            if (value.role == role and value.site == site) count += 1;
        }
        return count;
    }
    fn countBoundary(self: *const Probe, role: semantic.Role, site: semantic.Boundary) usize {
        var count: usize = 0;
        for (self.boundaries[0..self.boundary_count]) |value| {
            if (value.role == role and value.site == site) count += 1;
        }
        return count;
    }
    fn expectBoundaryPair(self: *const Probe, role: semantic.Role, site: semantic.Boundary, index: u64, generation: u64, value: ?u64) !void {
        var count: usize = 0;
        for (self.boundaries[0..self.boundary_count]) |actual| {
            if (actual.role != role or actual.site != site or actual.index != index or actual.generation != generation) continue;
            try t.expect(count < 2);
            try t.expectEqual(if (count == 0) semantic.Edge.before else semantic.Edge.after, actual.edge);
            try t.expectEqual(value, actual.value);
            count += 1;
        }
        try t.expectEqual(@as(usize, 2), count);
    }
    fn expectPair(self: *const Probe, role: semantic.Role, site: semantic.Site, handle: scheduler.Handle, value: u64) !void {
        var count: usize = 0;
        for (self.points[0..self.count]) |actual| {
            if (actual.role != role or actual.site != site or actual.index != handle.index or actual.generation != handle.generation) continue;
            try t.expect(count < 2);
            try t.expectEqual(if (count == 0) semantic.Edge.before else semantic.Edge.after, actual.edge);
            try t.expectEqual(@as(?u64, value), actual.value);
            count += 1;
        }
        try t.expectEqual(@as(usize, 2), count);
    }
    fn verifyVocabulary(self: *const Probe) !void {
        try t.expect(!self.overflow);
        for (self.points[0..self.count]) |point_value| try t.expect(semantic.allowedPoint(point_value));
        inline for (.{ semantic.Site.scheduler_slot_return, .scheduler_reap_phase, .scheduler_reap_readers, .scheduler_control_scan, .scheduler_scan }) |site| {
            inline for (.{ semantic.Role.control, .render }) |role| {
                try t.expectEqual(@as(usize, 0), self.countSite(role, site));
            }
        }
        var active: [std.meta.fields(semantic.Boundary).len]?semantic.BoundaryPoint = @splat(null);
        for (self.boundaries[0..self.boundary_count]) |value| {
            switch (value.site) {
                .scheduler_prepare_scan, .scheduler_reconcile_scan => {
                    try t.expectEqual(semantic.Role.control, value.role);
                    try t.expectEqual(@as(u64, scheduler.block_capacity), value.index);
                    try t.expectEqual(@as(u64, 0), value.generation);
                    try t.expect(value.value == null);
                },
                .scheduler_acquire_scan => {
                    try t.expectEqual(semantic.Role.render, value.role);
                    try t.expectEqual(@as(?u64, scheduler.block_capacity), value.value);
                },
                .scheduler_plan_cancel_release => try t.expectEqual(@as(?u64, 1), value.value),
                else => return error.UnexpectedBoundary,
            }
            const pending = &active[@intFromEnum(value.site)];
            if (value.edge == .before) {
                try t.expect(pending.* == null);
                pending.* = value;
            } else {
                var wanted = pending.* orelse return error.MissingBefore;
                wanted.edge = .after;
                try t.expectEqualDeep(wanted, value);
                pending.* = null;
            }
        }
        for (active) |value| try t.expect(value == null);
    }
};

fn identity(plan: u64, frame: u64) scheduler.CommandIdentity {
    return .{
        .command_id = plan,
        .token = .{
            .context = @enumFromInt(1),
            .transport_epoch = @enumFromInt(1),
            .plan_id = @enumFromInt(plan),
            .plan_epoch = @enumFromInt(1),
            .phase_id = @enumFromInt(1),
            .asset_generation = @enumFromInt(1),
        },
        .phase_order = 0,
        .execute_frame = frame,
        .group_id = plan,
    };
}

fn newProbe() !*Probe {
    const probe = try t.allocator.create(Probe);
    probe.* = .{};
    return probe;
}

fn newTiny() !*Tiny {
    const schedule = try t.allocator.create(Tiny);
    schedule.* = .{};
    return schedule;
}

test "Live semantic Scheduler attachment rejects conflicting custody and foreign detach" {
    const schedule = try newTiny();
    defer t.allocator.destroy(schedule);
    const probe = try newProbe();
    defer t.allocator.destroy(probe);
    const foreign = try newProbe();
    defer t.allocator.destroy(foreign);
    const binding = probe.binding();
    try t.expect(schedule.live_semantic_hooks == null);

    schedule.offline_causal_replay = .{ .context = probe, .checkpoint = Probe.legacy };
    try t.expectError(error.InvalidState, schedule.attachLiveSemanticQuiescent(binding));
    try t.expect(schedule.live_semantic_hooks == null);
    schedule.offline_causal_replay = null;

    var control: order.Storage(1) = .{};
    var render: order.Storage(1) = .{};
    var worker: order.Storage(1) = .{};
    try control.initInPlace(.control);
    try render.initInPlace(.render);
    try worker.initInPlace(.worker);
    schedule.prerequisite_order = .{ .control = &control.collector, .render = &render.collector, .worker = &worker.collector };
    try t.expectError(error.InvalidState, schedule.attachLiveSemanticQuiescent(binding));
    try t.expect(schedule.live_semantic_hooks == null);
    schedule.prerequisite_order = null;
    schedule.test_hook = .{ .context = probe, .call = Probe.gate };
    try t.expectError(error.InvalidState, schedule.attachLiveSemanticQuiescent(binding));
    schedule.test_hook = null;

    try schedule.attachLiveSemanticQuiescent(binding);
    try t.expectError(error.InvalidState, schedule.attachLiveSemanticQuiescent(binding));
    try t.expectError(error.InvalidState, schedule.detachLiveSemanticQuiescent(foreign.binding()));
    var changed = binding;
    changed.point = Probe.foreignPoint;
    try t.expectError(error.InvalidState, schedule.detachLiveSemanticQuiescent(changed));
    changed = binding;
    changed.boundary = Probe.foreignBoundary;
    try t.expectError(error.InvalidState, schedule.detachLiveSemanticQuiescent(changed));
    try t.expect(semantic.Binding.same(binding, schedule.live_semantic_hooks.?));
    try schedule.detachLiveSemanticQuiescent(binding);
    try t.expect(schedule.live_semantic_hooks == null);
    try t.expectError(error.InvalidState, schedule.detachLiveSemanticQuiescent(binding));

    // A real Render gate, even at zero with no occupied slot, is not startup.
    schedule.beginGate(0);
    try t.expectError(error.InvalidState, schedule.attachLiveSemanticQuiescent(binding));
    try t.expectEqual(@as(usize, 0), probe.count);
}

test "Live semantic Scheduler Control cancellation preserves incarnation and filters reclamation" {
    const schedule = try newTiny();
    defer t.allocator.destroy(schedule);
    const probe = try newProbe();
    defer t.allocator.destroy(probe);
    const binding = probe.binding();
    try schedule.attachLiveSemanticQuiescent(binding);
    var previous: ?scheduler.Handle = null;
    for (1..3) |plan_id| {
        const handle = try schedule.prepare(0, 1, &.{.{ .identity = identity(plan_id, 0), .payload = 7 }}, @splat(1), null);
        if (previous) |old| {
            try t.expectEqual(old.index, handle.index);
            try t.expectEqual(old.generation + 1, handle.generation);
        }
        try t.expectError(error.InvalidState, schedule.detachLiveSemanticQuiescent(binding));
        const before_get = probe.count;
        _ = try schedule.get(handle); // No asserted producer role: no guessed cut.
        try t.expectEqual(before_get, probe.count);
        const plan = try schedule.planHandle(handle);
        try schedule.cancelPrepared(handle, 0, 0);
        try probe.expectBoundaryPair(.control, .scheduler_plan_cancel_release, plan.index, plan.generation, 1);
        try t.expectError(error.InvalidState, schedule.detachLiveSemanticQuiescent(binding));
        try probe.expectPair(.control, .scheduler_receipt, handle, 1);
        try probe.expectPair(.control, .scheduler_terminal, handle, @intFromEnum(scheduler.State.terminal));
        try t.expectEqual(scheduler.trace.Result.cancelled, schedule.slots[handle.index].receipts[0].result);
        try schedule.acknowledge(handle);
        previous = handle;
    }
    try probe.verifyVocabulary();
    try t.expect(probe.countSite(.control, .scheduler_prepare_horizon) == 4);
    try t.expectEqual(@as(usize, 0), probe.countSite(.control, .scheduler_control_scan));
    try t.expectEqual(@as(usize, 4), probe.countBoundary(.control, .scheduler_prepare_scan));
    try t.expectEqual(@as(usize, 4), probe.countBoundary(.control, .scheduler_reconcile_scan));
    try t.expectEqual(@as(usize, 0), probe.countSite(.render, .scheduler_receipt));
    try t.expectEqual(@as(usize, 0), probe.countSite(.render, .scheduler_terminal));
    try schedule.detachLiveSemanticQuiescent(binding);
    // Reclaimed is not fresh startup, even with no remaining native obligation.
    try t.expectError(error.InvalidState, schedule.attachLiveSemanticQuiescent(binding));
}

const Summary = struct {
    handle: scheduler.Handle,
    plan: scheduler.Handle,
    intent: scheduler.Handle,
    receipt: scheduler.trace.ScheduleRecord,
    cancellation: scheduler.trace.ScheduleRecord,
    output: [4]f32,
    frame: u64,
    horizon: u64,
    gain: f32,
    telemetry: scheduler.Telemetry,
};

fn nativeRuntime(probe: ?*Probe) !Summary {
    const control = try audio.runtime.ControlRuntime.create(t.allocator);
    defer t.allocator.destroy(control);
    if (probe) |sink| try control.scheduled.attachLiveSemanticQuiescent(sink.binding());
    const command: audio.runtime.ScheduledCommand = .{ .identity = identity(1, 0), .payload = .{ .bus = .{ .bus = .music, .gain = 0.75, .ramp_frames = 1 } } };
    const handle = try control.prepareSchedule(0, 1, &.{command});
    const plan = try control.schedulePlan(handle);
    try control.submitSchedule(handle);
    _ = try control.controlTick(audio.runtime.max_control_drain);
    var renderer = audio.runtime.RuntimeRenderer.init(control, 48_000);
    var output: [4]f32 = undefined;
    renderer.render(output[0..2], 1, 2);
    const receipt = (try control.scheduleResult(handle)).?.receipts[0];
    // Genuine completed command retains its identity until Control releases it.
    // The later invalidation computes too-late, never a recorded substitution.
    const intent = (try control.cancelSchedule(.{ .target = handle, .requested_frame = 1 })).?;
    _ = try control.controlTick(audio.runtime.max_control_drain);
    renderer.render(output[2..4], 1, 2);
    const cancellation = (try control.cancellationResult(intent)).?.receipt;
    try control.releaseSchedule(handle);
    _ = try control.controlTick(audio.runtime.max_control_drain);
    const result: Summary = .{
        .handle = handle,
        .plan = plan,
        .intent = intent,
        .receipt = receipt,
        .cancellation = cancellation,
        .output = output,
        .frame = control.scheduled.render_frame.load(.acquire),
        .horizon = control.scheduled.commit_horizon.load(.acquire),
        .gain = renderer.mixer.music_gain,
        .telemetry = control.scheduled.telemetry(),
    };
    if (probe) |sink| try control.scheduled.detachLiveSemanticQuiescent(sink.binding());
    try control.destroy();
    return result;
}

test "Live semantic Scheduler captures native publication scan execution and invalidation without collectors" {
    const probe = try newProbe();
    defer t.allocator.destroy(probe);
    const plain = try nativeRuntime(null);
    const observed = try nativeRuntime(probe);
    try t.expectEqualDeep(plain, observed);
    try t.expectEqual(scheduler.trace.Result.success, observed.receipt.result);
    try t.expectEqual(scheduler.trace.Result.too_late, observed.cancellation.result);
    try t.expectEqual(@as(u64, 2), observed.frame);
    try t.expectEqualSlices(f32, &.{ 0, 0, 0, 0 }, &observed.output);
    try probe.verifyVocabulary();
    try probe.expectPair(.control, .scheduler_publication, observed.handle, @intFromEnum(scheduler.State.published));
    try probe.expectPair(.control, .scheduler_invalidation_publication, observed.intent, 1);
    try probe.expectPair(.render, .scheduler_acquired, observed.handle, @intFromEnum(scheduler.State.acquired));
    try probe.expectPair(.render, .scheduler_phase, observed.plan, 1);
    try probe.expectPair(.render, .scheduler_receipt, observed.handle, 1);
    try probe.expectPair(.render, .scheduler_terminal, observed.handle, @intFromEnum(scheduler.State.terminal));
    try t.expectEqual(@as(usize, 0), probe.countSite(.render, .scheduler_scan));
    try t.expectEqual(@as(usize, 4), probe.countBoundary(.render, .scheduler_acquire_scan));
    try probe.expectBoundaryPair(.render, .scheduler_acquire_scan, 1, 0, scheduler.block_capacity);
    try probe.expectBoundaryPair(.render, .scheduler_acquire_scan, 2, 1, scheduler.block_capacity);
    // The chosen native acquisition remains inside the exact scan envelope,
    // while command execution occurs after the scan. No per-empty-slot tape.
    var scan_begin: ?usize = null;
    var scan_end: ?usize = null;
    for (probe.boundaries[0..probe.boundary_count], 0..) |value, index| {
        if (value.site != .scheduler_acquire_scan or value.index != 1) continue;
        if (value.edge == .before) scan_begin = probe.boundary_ordinals[index] else scan_end = probe.boundary_ordinals[index];
    }
    for (probe.points[0..probe.count], 0..) |value, index| {
        if (value.site == .scheduler_acquired) {
            try t.expect(scan_begin.? < probe.point_ordinals[index]);
            try t.expect(probe.point_ordinals[index] < scan_end.?);
        }
        if (value.site == .scheduler_phase) try t.expect(scan_end.? < probe.point_ordinals[index]);
    }
    try t.expectEqual(@as(usize, 4), probe.countSite(.render, .scheduler_horizon));
    inline for (.{ semantic.Site.scheduler_invalidation_before_scan, .scheduler_invalidation_after_scan, .scheduler_invalidation_pre_claim }) |site| {
        try t.expect(probe.countSite(.render, site) >= 2);
    }
    var empty_poll = false;
    var published_poll = false;
    for (probe.points[0..probe.count]) |point_value| {
        if (point_value.site == .scheduler_invalidation_poll) {
            try t.expectEqual(semantic.Role.render, point_value.role);
            if (point_value.edge == .before) {
                try t.expect(point_value.value == null);
            } else if (point_value.value.? == 0) {
                empty_poll = true;
            } else if (point_value.value.? == 1) {
                published_poll = true;
            }
        }
    }
    try t.expect(empty_poll and published_poll);
}

test "Live semantic Scheduler sink exhaustion cannot suppress actual engine work" {
    const probe = try newProbe();
    defer t.allocator.destroy(probe);
    probe.limit = 1;
    const plain = try nativeRuntime(null);
    const overflowed = try nativeRuntime(probe);
    try t.expectEqualDeep(plain, overflowed);
    try t.expect(probe.overflow);
    try t.expectEqual(@as(usize, 1), probe.count);
}

test "Live semantic empty Scheduler scans emit only finite envelopes" {
    const schedule = try newTiny();
    defer t.allocator.destroy(schedule);
    const probe = try newProbe();
    defer t.allocator.destroy(probe);
    const binding = probe.binding();
    try schedule.attachLiveSemanticQuiescent(binding);
    schedule.reconcilePrepared();
    try t.expectEqual(@as(usize, 0), probe.count);
    try t.expectEqual(@as(usize, 2), probe.boundary_count);
    schedule.beginGate(0);
    schedule.acquirePublished(0);
    try t.expectEqual(@as(usize, 2), probe.count); // Only the native horizon pair.
    try t.expectEqual(@as(usize, 4), probe.boundary_count);
    try probe.expectBoundaryPair(.control, .scheduler_reconcile_scan, scheduler.block_capacity, 0, null);
    try probe.expectBoundaryPair(.render, .scheduler_acquire_scan, 1, 0, scheduler.block_capacity);
    try probe.verifyVocabulary();
    try schedule.detachLiveSemanticQuiescent(binding);
}

test "Live semantic Render cancellation publication precedes the native Control reconcile scan" {
    const schedule = try newTiny();
    defer t.allocator.destroy(schedule);
    const probe = try newProbe();
    defer t.allocator.destroy(probe);
    const binding = probe.binding();
    try schedule.attachLiveSemanticQuiescent(binding);
    const handle = try schedule.prepare(96, 97, &.{.{ .identity = identity(1, 96), .payload = 7 }}, @splat(1), null);
    const plan = try schedule.planHandle(handle);
    schedule.beginGate(17);
    // Genuine serialized Render-owner fence, not a callback changing state.
    try schedule.cancelDevicePlanAtGate(plan, 17);
    try probe.expectBoundaryPair(.render, .scheduler_plan_cancel_release, plan.index, plan.generation, 1);
    try t.expectEqual(@as(usize, 0), probe.countBoundary(.control, .scheduler_plan_cancel_release));
    try t.expectEqual(scheduler.State.prepared, schedule.slots[handle.index].state.load(.acquire));
    schedule.reconcilePrepared();
    try t.expectEqual(scheduler.State.terminal, schedule.slots[handle.index].state.load(.acquire));
    try probe.expectPair(.control, .scheduler_receipt, handle, 1);
    try probe.expectPair(.control, .scheduler_terminal, handle, @intFromEnum(scheduler.State.terminal));
    try t.expectEqual(@as(u64, 17), schedule.slots[handle.index].receipts[0].effective_frame);
    try schedule.acknowledge(handle);
    try probe.verifyVocabulary();
    try schedule.detachLiveSemanticQuiescent(binding);
}
