//! Deterministic policy and Event-boundary tests. These exercise the exact
//! production decision helper, not a fabricated engine recording or replay.
const std = @import("std");
const live = @import("sme-author-live-owner");
const t = std.testing;
const Burst = live.Host.WorkerBurstTests;

test "notified burst ends only for a normal empty scan or an existing defer" {
    inline for (.{ live.PacingMode.legacy_poll, live.PacingMode.notified_v1 }) |mode| {
        inline for (.{ false, true }) |worked| {
            inline for (.{ false, true }) |deferred| {
                inline for (.{ false, true }) |step_failed| {
                    inline for (.{ false, true }) |completion_failed| {
                        const expected = if (deferred) true else if (mode == .legacy_poll) false else !worked and !step_failed and !completion_failed;
                        try t.expectEqual(expected, Burst.endAfterCall(mode, worked, deferred, step_failed, completion_failed));
                    }
                }
            }
        }
    }
}

const Return = struct { worked: bool = false, deferred: bool = false, failed: bool = false, completion_failed: bool = false };
fn calls(mode: live.PacingMode, returns: []const Return) usize {
    var count: usize = 0;
    for (0..Burst.limit) |index| {
        const value = returns[@min(index, returns.len - 1)];
        count += 1;
        if (Burst.endAfterCall(mode, value.worked, value.deferred, value.failed, value.completion_failed)) break;
    }
    return count;
}
test "worker burst keeps the four-call bound and legacy error and defer policies" {
    try t.expectEqual(@as(usize, 4), Burst.limit);
    try t.expectEqual(@as(usize, 1), calls(.notified_v1, &.{.{}}));
    try t.expectEqual(@as(usize, 3), calls(.notified_v1, &.{ .{ .worked = true }, .{ .worked = true }, .{} }));
    try t.expectEqual(@as(usize, 4), calls(.notified_v1, &.{.{ .worked = true }}));
    try t.expectEqual(@as(usize, 4), calls(.legacy_poll, &.{.{}}));
    inline for (.{ live.PacingMode.legacy_poll, live.PacingMode.notified_v1 }) |mode| {
        try t.expectEqual(@as(usize, 1), calls(mode, &.{.{ .deferred = true }}));
        try t.expectEqual(@as(usize, 4), calls(mode, &.{.{ .failed = true }}));
        try t.expectEqual(@as(usize, 4), calls(mode, &.{.{ .completion_failed = true }}));
    }
}

test "notification after turn reset survives empty scan decision and actual wait" {
    var signal: live.WakeSignal = .{};
    signal.notify(t.io); // Consume a notification belonging to the previous turn.
    signal.beginTurn();
    try t.expect(!signal.event.isSet());
    // Cover both publication before the no-work decision and between decision
    // and wait. These are deterministic orderings, not a sleep timing oracle.
    inline for (.{ false, true }) |notify_before_decision| {
        if (notify_before_decision) signal.notify(t.io);
        try t.expect(Burst.endAfterCall(.notified_v1, false, false, false, false));
        if (!notify_before_decision) signal.notify(t.io);
        try t.expect(signal.event.isSet());
        signal.wait(t.io, 1); // Production Event wait must not clear the hint.
        try t.expect(signal.event.isSet());
        signal.beginTurn();
        try t.expect(!signal.event.isSet());
    }
}
