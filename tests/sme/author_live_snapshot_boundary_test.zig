//! Isolated production Host custody helpers, not a fabricated native replay.
const std = @import("std");
const live = @import("sme-author-live-owner");
const t = std.testing;

const SnapshotProbe = live.Host.SnapshotBoundaryTests;
fn snapshotPending(host: *live.Host) anyerror!bool {
    try t.expect(host.gate.parked(host.launch_identity.epoch, host.park_sequence.?));
    return false;
}
fn snapshotFailure(host: *live.Host) anyerror!bool {
    try t.expect(host.gate.parked(host.launch_identity.epoch, host.park_sequence.?));
    return error.SnapshotProbeFailure;
}
fn snapshotReady(host: *live.Host) anyerror!bool {
    try t.expect(host.gate.parked(host.launch_identity.epoch, host.park_sequence.?));
    return true;
}
fn snapshotResumeFailure(host: *live.Host) anyerror!bool {
    host.launch_identity.epoch += 1; // Inject only a helper-level invalid token.
    return false;
}
fn acknowledgeSnapshot(host: *live.Host) !u64 {
    const sequence = host.park_sequence.?;
    try t.expect((try host.gate.workerAction(host.launch_identity.epoch)).park == sequence);
    try host.gate.acknowledgePark(host.launch_identity.epoch, sequence);
    return sequence;
}
test "coherent close snapshot pending resumes and requires real progress before repark" {
    var host: live.Host = undefined;
    try SnapshotProbe.initProbe(&host, 91);
    try SnapshotProbe.inspect(&host, snapshotPending); // Request only, no fabricated ACK.
    try t.expect(host.worker_wake.event.isSet()); // real requestPark helper notification.
    host.worker_wake.beginTurn();
    const first = try acknowledgeSnapshot(&host);
    try SnapshotProbe.inspect(&host, snapshotPending);
    try t.expect(host.park_sequence == null and !host.gate.parked(91, first));
    try t.expect(host.worker_wake.event.isSet()); // real resume helper notification.
    try SnapshotProbe.inspect(&host, snapshotPending);
    try t.expect(host.park_sequence == null); // ProgressPending is an ordinary yield.
    try t.expect((try host.gate.workerAction(91)) == .work);
    try host.gate.workerDeferred(91);
    try SnapshotProbe.inspect(&host, snapshotPending);
    try t.expect(host.park_sequence == null); // Failed claim is not progress.
    try t.expect((try host.gate.workerAction(91)) == .work);
    try host.gate.workerCompleted(91);
    try SnapshotProbe.inspect(&host, snapshotPending);
    const second = try acknowledgeSnapshot(&host);
    try t.expect(second == first + 1);
    try SnapshotProbe.inspect(&host, snapshotReady);
    try t.expect(host.status.phase == .destroying and host.park_sequence == second);
    try t.expect(host.gate.parked(91, second)); // Exact custody is handed to destroy.
}
test "coherent close snapshot query failure resumes without swallowing original error" {
    var host: live.Host = undefined;
    try SnapshotProbe.initProbe(&host, 92);
    try SnapshotProbe.inspect(&host, snapshotFailure);
    _ = try acknowledgeSnapshot(&host);
    try t.expectError(error.SnapshotProbeFailure, SnapshotProbe.inspect(&host, snapshotFailure));
    try t.expect(host.park_sequence == null and host.status.phase == .closing);
    try t.expect(host.status.cleanup_error == null);
    try t.expect((try host.gate.workerAction(92)) == .work);
    try host.gate.workerCompleted(92);
}
test "coherent close snapshot failed resume retains sequence for explicit retry" {
    var host: live.Host = undefined;
    try SnapshotProbe.initProbe(&host, 93);
    try SnapshotProbe.inspect(&host, snapshotResumeFailure);
    const sequence = try acknowledgeSnapshot(&host);
    try SnapshotProbe.inspect(&host, snapshotResumeFailure);
    try t.expectEqual(@as(anyerror, error.InvalidEpoch), host.status.cleanup_error orelse return error.ExpectedResumeFailure);
    try t.expect(host.park_sequence == sequence and host.gate.parked(93, sequence));
    host.launch_identity.epoch = 93;
    try SnapshotProbe.resumePending(&host);
    try t.expect(host.park_sequence == null and !host.gate.parked(93, sequence));
}

// Protocol tests use actual threads/Event operations, not fake Host work or an
// OS sleep-duration oracle. A .waiting observation proves wait entry, not that
// the kernel already descheduled the thread. 500 ms is only a safety bound.
const EventProtocolProbe = struct {
    const Mode = enum { prewait, entered_wait, cancel_wait };
    signal: live.WakeSignal = .{},
    ready: std.Io.Event = .unset,
    gate: std.Io.Event = .unset,
    cancelled: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    mode: Mode,
    payload: u64 = 0,
    observed: u64 = 0,
    saw_cancel: bool = false,
    failure: ?anyerror = null,

    fn waitSet(event: *std.Io.Event) !void {
        const start = std.Io.Clock.awake.now(t.io);
        while (!event.isSet()) {
            if (start.durationTo(std.Io.Clock.awake.now(t.io)).nanoseconds >= 500 * std.time.ns_per_ms) return error.EventProtocolTimedOut;
            event.waitTimeout(t.io, .{ .duration = .{ .raw = .fromMilliseconds(500), .clock = .awake } }) catch |err| switch (err) {
                error.Timeout => continue, // also permitted for spurious wakes.
                else => return err,
            };
        }
    }
    fn run(self: *@This()) void {
        defer self.done.store(true, .release);
        self.signal.beginTurn(); // sole consumer, no outstanding wait.
        self.ready.set(t.io);
        if (self.mode == .prewait) waitSet(&self.gate) catch |err| {
            self.failure = err;
            return;
        };
        const start = std.Io.Clock.awake.now(t.io);
        while (!self.signal.event.isSet()) {
            if (start.durationTo(std.Io.Clock.awake.now(t.io)).nanoseconds >= 500 * std.time.ns_per_ms) {
                self.failure = error.EventProtocolTimedOut;
                return;
            }
            self.signal.wait(t.io, 1); // exact production helper, finite fallback.
        }
        self.saw_cancel = self.cancelled.load(.acquire);
        if (!self.saw_cancel) self.observed = self.payload;
    }
    fn exercise(mode: Mode) !void {
        var probe: EventProtocolProbe = .{ .mode = mode };
        const thread = try std.Thread.spawn(.{}, run, .{&probe});
        var joined = false;
        defer if (!joined) {
            probe.cancelled.store(true, .release);
            probe.signal.notify(t.io);
            probe.gate.set(t.io);
            thread.join();
        };
        try waitSet(&probe.ready);
        if (mode != .prewait) {
            const start = std.Io.Clock.awake.now(t.io);
            while (@atomicLoad(std.Io.Event, &probe.signal.event, .acquire) != .waiting) {
                if (probe.done.load(.acquire)) return error.EventConsumerReturnedBeforeNotification;
                if (start.durationTo(std.Io.Clock.awake.now(t.io)).nanoseconds >= 500 * std.time.ns_per_ms) return error.EventWaitEntryTimedOut;
                std.Thread.yield() catch {};
            }
        }
        probe.payload = 73; // ordinary payload published by the real Event set.
        if (mode == .cancel_wait) probe.cancelled.store(true, .release);
        probe.signal.notify(t.io);
        if (mode == .prewait) {
            try t.expect(probe.signal.event.isSet()); // notification retained before wait.
            probe.gate.set(t.io);
        }
        thread.join();
        joined = true;
        if (probe.failure) |err| return err;
        try t.expect(probe.done.load(.acquire));
        try t.expect(probe.signal.event.isSet());
        try t.expectEqual(mode == .cancel_wait, probe.saw_cancel);
        try t.expectEqual(@as(u64, if (mode == .cancel_wait) 0 else 73), probe.observed);
        // This tests lifecycle cancellation plus wake, not std.Io.Canceled.
    }
};

test "Host Event protocol retains a notification set before wait" {
    try EventProtocolProbe.exercise(.prewait);
}
test "Host Event protocol releases a consumer after real wait entry" {
    try EventProtocolProbe.exercise(.entered_wait);
}
test "Host Event protocol cancellation releases a waiting consumer before join" {
    try EventProtocolProbe.exercise(.cancel_wait);
}

// This fake Io tests only error dispatch in the exact production WakeSignal;
// it is not native scheduling evidence or a replacement engine clock/result.
test "Host WakeSignal handles spurious timeout and cancellation with bounded protected fallback" {
    const Fake = struct {
        cancel: bool,
        protection: std.Io.CancelProtection = .unblocked,
        calls: [4]u8 = @splat(0),
        len: usize = 0,
        wait_ms: i96 = 0,
        sleep_ms: i96 = 0,
        sleep_blocked: bool = false,
        fn mark(self: *@This(), value: u8) void {
            if (self.len < self.calls.len) self.calls[self.len] = value;
            self.len += 1;
        }
        fn futex(raw: ?*anyopaque, _: *const u32, _: u32, timeout: std.Io.Timeout) std.Io.Cancelable!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.mark(1);
            self.wait_ms = timeout.duration.raw.toMilliseconds();
            if (self.cancel) return error.Canceled;
            // No set, so real Event.waitTimeout returns Timeout on this wake.
        }
        fn swap(raw: ?*anyopaque, value: std.Io.CancelProtection) std.Io.CancelProtection {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.mark(if (value == .blocked) 2 else 4);
            const old = self.protection;
            self.protection = value;
            return old;
        }
        fn sleep(raw: ?*anyopaque, timeout: std.Io.Timeout) std.Io.Cancelable!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.mark(3);
            self.sleep_ms = timeout.duration.raw.toMilliseconds();
            self.sleep_blocked = self.protection == .blocked;
        }
    };
    var vtable = t.io.vtable.*;
    vtable.futexWait = Fake.futex;
    vtable.swapCancelProtection = Fake.swap;
    vtable.sleep = Fake.sleep;
    inline for (.{ false, true }) |cancel| {
        var fake: Fake = .{ .cancel = cancel };
        const io: std.Io = .{ .userdata = &fake, .vtable = &vtable };
        var signal: live.WakeSignal = .{};
        signal.beginTurn();
        signal.wait(io, 1);
        try t.expectEqual(@as(i96, 1), fake.wait_ms);
        try t.expect(!signal.event.isSet());
        try t.expectEqual(std.Io.CancelProtection.unblocked, fake.protection);
        if (cancel) {
            try t.expectEqual(@as(usize, 4), fake.len);
            try t.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, &fake.calls);
            try t.expectEqual(@as(i96, 1), fake.sleep_ms);
            try t.expect(fake.sleep_blocked);
        } else try t.expectEqual(@as(usize, 1), fake.len);
    }
}

test "Host pacing selection preserves semantic and private capture polling" {
    var host: live.Host = undefined;
    host.options = .{ .io = t.io };
    try t.expectEqual(live.PacingMode.notified_v1, host.pacingMode());
    var session: live.semantic.Session = .{};
    host.options.semantic = &session;
    inline for (.{ @as(@FieldType(live.semantic.Session, "mode"), .capture), @as(@FieldType(live.semantic.Session, "mode"), .replay) }) |mode| {
        session.mode = mode;
        try t.expectEqual(live.PacingMode.legacy_poll, host.pacingMode());
    }
    host.options.semantic = null;
    const capture = try t.allocator.create(live.TestCapture.Session);
    defer t.allocator.destroy(capture);
    host.options.test_capture = capture; // selection reads pointer only.
    try t.expectEqual(live.PacingMode.legacy_poll, host.pacingMode());
}

test "Host shared Worker notification policy does not ping pong on idle or repeated errors" {
    var host: live.Host = undefined;
    try SnapshotProbe.initProbe(&host, 94);
    SnapshotProbe.completedNotification(&host, false);
    try t.expect(!host.control_wake.event.isSet());
    SnapshotProbe.completedNotification(&host, true);
    try t.expect(host.control_wake.event.isSet());
    host.control_wake.beginTurn();
    SnapshotProbe.completedNotification(&host, false);
    try t.expect(!host.control_wake.event.isSet());
    SnapshotProbe.errorNotification(&host, error.FirstWorkerProbeFailure);
    try t.expect(host.control_wake.event.isSet());
    try t.expectEqual(@as(u32, @intFromError(error.FirstWorkerProbeFailure)), host.worker_error.load(.acquire));
    host.control_wake.beginTurn();
    SnapshotProbe.errorNotification(&host, error.LaterWorkerProbeFailure);
    try t.expect(!host.control_wake.event.isSet());
    try t.expectEqual(@as(u32, @intFromError(error.LaterWorkerProbeFailure)), host.worker_error.load(.acquire));
    // This is the shared policy function, not evidence of an engine completion.
}

test "Host beginTurn consumes an already published notification with payload visibility" {
    const Producer = struct {
        signal: live.WakeSignal = .{},
        payload: u64 = 0,
        fn run(self: *@This()) void {
            self.payload = 91;
            self.signal.notify(t.io);
        }
    };
    var producer: Producer = .{};
    const thread = try std.Thread.spawn(.{}, Producer.run, .{&producer});
    defer thread.join();
    const start = std.Io.Clock.awake.now(t.io);
    // Deliberately monotonic: payload acquisition must come from the actual
    // beginTurn operation, not this polling observation or the later join.
    while (@atomicLoad(std.Io.Event, &producer.signal.event, .monotonic) != .is_set) {
        if (start.durationTo(std.Io.Clock.awake.now(t.io)).nanoseconds >= 500 * std.time.ns_per_ms) return error.EventPublicationTimedOut;
        std.Thread.yield() catch {};
    }
    producer.signal.beginTurn();
    try t.expectEqual(@as(u64, 91), producer.payload);
    try t.expect(!producer.signal.event.isSet());
}

test "Host actual startup Worker abort wakes and joins before borrowing an owner" {
    var host: live.Host = undefined;
    try SnapshotProbe.initProbe(&host, 95);
    const thread = try std.Thread.spawn(.{}, SnapshotProbe.startupWorker, .{&host});
    var joined = false;
    defer if (!joined) {
        SnapshotProbe.abortStartup(&host);
        thread.join();
    };
    const start = std.Io.Clock.awake.now(t.io);
    while (@atomicLoad(std.Io.Event, &host.worker_wake.event, .acquire) != .waiting) {
        if (start.durationTo(std.Io.Clock.awake.now(t.io)).nanoseconds >= 500 * std.time.ns_per_ms) return error.StartupWaitEntryTimedOut;
        std.Thread.yield() catch {};
    }
    try t.expect(!host.worker_ready.load(.acquire));
    SnapshotProbe.abortStartup(&host); // same real store + notification as releaseTurn.
    thread.join();
    joined = true;
    try t.expect(host.startup_abort.load(.acquire));
    try t.expect(!host.worker_ready.load(.acquire));
    try t.expect(host.worker_id.load(.acquire) != 0);
    // owner remains undefined throughout: actual workerMain returns in startup.
    // This does not claim coverage of every constructor allocation failure.
}
