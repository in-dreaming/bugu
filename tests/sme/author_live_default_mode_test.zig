//! Focused recorder-free chronology mode/cleanup checks on a real offline rig.
//! Actual concurrent default Host coverage is a separate native test.
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

test "default chronology null sink retains mode rejection history and genuine cleanup" {
    const bytes = try bank();
    defer a.free(bytes);
    const rig = try Rig.create(bytes);
    defer rig.finish(true) catch @panic("chronology cleanup retained native custody");
    const owner = rig.engine.run.owner;
    const before = try owner.snapshotV1();
    _ = try owner.controlTickLiveChronologyV1(f.rt.max_control_drain, null);
    const stamp = rig.engine.run.control.stream_control_tick;
    try t.expectError(error.InvalidMode, owner.controlTickV1(f.rt.max_control_drain));
    try t.expectError(error.InvalidMode, owner.controlTickLiveV1(f.rt.max_control_drain));
    try t.expectError(error.InvalidMode, owner.controlTickLiveSemanticV1(f.rt.max_control_drain, null));
    try t.expectEqual(stamp, rig.engine.run.control.stream_control_tick);
    const requirements = try owner.historyRequirementsV1();
    try t.expectEqual(.live_chronology_v1, requirements.replay_contract);
    try t.expectEqual(.unavailable, requirements.live_capture);
    const snapshot = try owner.snapshotV1();
    try t.expect(!snapshot.complete);
    try t.expectEqual(before.diagnostics_complete, snapshot.diagnostics_complete);
    var output: [0]u8 = .{};
    try t.expectError(error.LiveChronologyRequired, owner.exportReplayV1(&output));
    const pause = try owner.submitV1(rig.engine.run.bank.?, .pause);
    _ = try owner.controlTickLiveChronologyV1(f.rt.max_control_drain, null);
    var terminals: usize = 0;
    while (try owner.pollReceiptV1()) |receipt| {
        try t.expectEqualDeep(pause, receipt.ticket);
        if (receipt.event != .terminal) continue;
        terminals += 1;
        try t.expect(receipt.event.terminal == .rejected);
        try t.expectEqual(.unsupported_capability, receipt.event.terminal.rejected);
    }
    try t.expectEqual(@as(usize, 1), terminals);
    try t.expectEqual(.ready, owner.state);
}

test "default never-started initial cleanup retains legacy mode and history" {
    const bytes = try bank();
    defer a.free(bytes);
    const rig = try Rig.create(bytes);
    defer rig.finish(false) catch @panic("initial cleanup retained native custody");
    const owner = rig.engine.run.owner;
    try t.expect(owner.live_chronology_frontier == null);
    const requirements = try owner.historyRequirementsV1();
    try t.expectEqual(.existing_contract, requirements.replay_contract);
    try t.expectEqual(.not_applicable, requirements.live_capture);
    _ = try owner.controlTickV1(f.rt.max_control_drain);
    try t.expect(owner.live_chronology_frontier == null);
}

test "initial chronology waits for fourth actual visible highwater stem without replacing request" {
    const bytes = try bank();
    defer a.free(bytes);
    const rig = try Rig.create(bytes);
    defer rig.finish(true) catch @panic("headroom wait retained native custody");
    const owner = rig.engine.run.owner;
    const original = try owner.start(rig.engine.run.bank.?, f.state);
    var saw_wait = false;
    var saw_three = false;
    var published = false;
    var previous_plan: u64 = 0;
    for (0..512) |_| {
        _ = try owner.controlTickLiveChronologyV1(f.rt.max_control_drain, null);
        const readiness = owner.generation.?.readiness.?;
        var ready_count: usize = 0;
        if (readiness.complete and readiness.count == 4) {
            for (readiness.bindings[0..readiness.count]) |binding| {
                if (try owner.owned_streaming.?.acknowledgedVisiblePrefix(binding.handle) >= owner.owned_streaming.?.profile.high_frames)
                    ready_count += 1;
            }
        }
        if (owner.pending != null) {
            try t.expectEqual(@as(usize, 4), ready_count);
            published = true;
            break;
        }
        if (owner.preparing) |preparing| {
            saw_wait = true;
            try t.expectEqual(original.request_id, preparing.intent.request_id);
            try t.expect(preparing.plan_id >= previous_plan);
            previous_plan = preparing.plan_id;
            // No execution/group is allocated by the headroom wait itself.
            try t.expect(preparing.cold_candidate == null);
        }
        if (ready_count == 3) saw_three = true;
        // One genuine decode per turn exposes the missing-final-stem boundary.
        _ = try rig.engine.workerOne();
        const pcm = try rig.engine.run.render(256);
        a.free(pcm);
    }
    try t.expect(saw_wait and saw_three and published);
    var accepted: usize = 0;
    while (try owner.pollReceiptV1()) |receipt| {
        try t.expectEqualDeep(original, receipt.ticket);
        if (receipt.event == .accepted) accepted += 1;
        if (receipt.event == .terminal) try t.expect(receipt.event.terminal == .executed);
    }
    try t.expectEqual(@as(usize, 1), accepted);
}
