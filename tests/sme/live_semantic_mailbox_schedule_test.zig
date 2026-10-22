//! Bounded nonwaiting unit coverage. Native concurrent process replay remains
//! integration proof; these tests never install values into an actual mailbox.
const std = @import("std");
const schedule = @import("sme-author-live-owner").semantic_replay.mailbox_schedule;
const t = std.testing;
fn create(limit: usize) !*schedule.Scheduler {
    const s = try t.allocator.create(schedule.Scheduler);
    errdefer t.allocator.destroy(s);
    s.* = .{};
    try s.init(limit);
    return s;
}

test "mailbox repeated equal prefixes retain exact read identities" {
    const s = try create(2);
    defer t.allocator.destroy(s);
    try s.addRead(.commands_written, 10, 14, 0);
    try s.addRead(.commands_written, 15, 19, 0);
    try s.addPublication(.commands_written, 12, 20, 1);
    try s.seal();
    try t.expect(!try s.publicationReady(.commands_written, 1));
    try t.expect(try s.readReady(.commands_written, 10));
    try t.expect(try s.readReady(.commands_written, 10)); // repeat-ready is idempotent
    try t.expectEqual(@as(u64, 14), try s.acquired(.commands_written, 0));
    try t.expect(!try s.publicationReady(.commands_written, 1)); // second pin survives
    try t.expectError(error.InvalidOrder, s.readReady(.commands_written, 10));
    try t.expect(try s.readReady(.commands_written, 15));
    try t.expectEqual(@as(u64, 19), try s.acquired(.commands_written, 0));
    try t.expect(try s.publicationReady(.commands_written, 1));
    try t.expectEqual(@as(u64, 0), s.observed(.commands_written));
    try s.published(.commands_written, 1);
    try t.expect(s.complete());
}

test "mailbox acquired pin retires before delayed after marker and real store advances only afterward" {
    const s = try create(1);
    defer t.allocator.destroy(s);
    try s.addRead(.events_read, 5, 9, 0);
    try s.addPublication(.events_read, 6, 7, 1);
    try s.seal();
    var global_turn: u64 = 6; // Caller already left read-before occurrence5.
    try t.expect(try s.readReady(.events_read, 5));
    const after_occurrence = try s.acquired(.events_read, 0);
    try t.expectEqual(@as(u64, 9), after_occurrence);
    // The exact load is complete, even though its hook stamp9 is still future.
    try t.expect(try s.publicationReady(.events_read, 1));
    try t.expectEqual(@as(u64, 0), s.observed(.events_read));
    global_turn += 1; // Intervening native publisher marker6 can run.
    try s.published(.events_read, 1);
    try t.expectEqual(@as(u64, 1), s.observed(.events_read));
    try t.expect(global_turn < after_occurrence);
    try t.expect(s.complete()); // No global occurrence ownership is inferred.
}

test "mailbox acquisition waits for actual publication without assigning target" {
    const s = try create(1);
    defer t.allocator.destroy(s);
    try s.addRead(.events_written, 10, 13, 1);
    try s.addPublication(.events_written, 11, 12, 1);
    try s.seal();
    try t.expect(!try s.readReady(.events_written, 10));
    try t.expectEqual(@as(u64, 0), s.observed(.events_written));
    try t.expectError(error.InvalidState, s.acquired(.events_written, 1));
    try t.expectError(error.InvalidState, s.published(.events_written, 1));
    try t.expect(try s.publicationReady(.events_written, 1));
    try t.expect(!try s.readReady(.events_written, 10));
    try s.published(.events_written, 1);
    try t.expect(try s.readReady(.events_written, 10));
    try t.expectError(error.ReplayMismatch, s.acquired(.events_written, 0));
    _ = try s.acquired(.events_written, 1);
    try t.expect(s.complete());
}

test "mailbox counters have independent read identity progress and pins" {
    const s = try create(2);
    defer t.allocator.destroy(s);
    try s.addRead(.commands_read, 2, 3, 0);
    try s.addRead(.events_written, 4, 5, 1);
    try s.addPublication(.commands_read, 6, 7, 1);
    try s.addPublication(.events_written, 1, 3, 1);
    try s.seal();
    try t.expectError(error.InvalidOrder, s.readReady(.events_written, 2));
    try t.expect(!try s.publicationReady(.commands_read, 1));
    try t.expect(try s.publicationReady(.events_written, 1));
    try s.published(.events_written, 1);
    try t.expectEqual(@as(u64, 0), s.observed(.commands_read));
    try t.expect(try s.readReady(.events_written, 4));
    _ = try s.acquired(.events_written, 1);
    try t.expect(!try s.publicationReady(.commands_read, 1));
    try t.expect(try s.readReady(.commands_read, 2));
    _ = try s.acquired(.commands_read, 0);
    try t.expect(try s.publicationReady(.commands_read, 1));
    try s.published(.commands_read, 1);
    try t.expect(s.complete());
}

test "mailbox sticky Close allows repeated actual one publications but pins earlier zero read" {
    const s = try create(2);
    defer t.allocator.destroy(s);
    try s.addRead(.closed, 1, 2, 0);
    try s.addRead(.closed, 5, 8, 1);
    try s.addPublication(.closed, 3, 4, 1);
    try s.addPublication(.closed, 6, 7, 1);
    try t.expectError(error.InvalidPrefix, s.addPublication(.closed, 9, 10, 0));
    try s.seal();
    try t.expect(!try s.publicationReady(.closed, 1));
    try t.expect(try s.readReady(.closed, 1));
    _ = try s.acquired(.closed, 0);
    try t.expect(try s.publicationReady(.closed, 1));
    try s.published(.closed, 1);
    try t.expect(try s.readReady(.closed, 5));
    // An idempotent1→1 cannot alter the in-flight read's observed closed value.
    try t.expect(try s.publicationReady(.closed, 1));
    try s.published(.closed, 1);
    _ = try s.acquired(.closed, 1);
    try t.expect(s.complete());
    try t.expectError(error.UnreachablePrefix, s.publicationReady(.closed, 1));
}

test "mailbox preflight rejects impossible prefixes budget order and invalid closed state" {
    const s = try create(2);
    defer t.allocator.destroy(s);
    try s.addRead(.commands_written, 1, 2, 1);
    try t.expectError(error.UnreachablePrefix, s.seal());
    try t.expectError(error.InvalidOrder, s.addRead(.commands_written, 2, 3, 1));
    try t.expectError(error.InvalidOrder, s.addRead(.commands_written, 3, 4, 0));
    try t.expectError(error.InvalidPrefix, s.addRead(.closed, 3, 4, 2));
    try t.expectError(error.InvalidPrefix, s.addPublication(.commands_written, 1, 3, 2));
    try s.addPublication(.commands_written, 1, 3, 1);
    try s.addRead(.commands_written, 3, 4, 1);
    try t.expectError(error.ReadBudgetExceeded, s.addRead(.events_read, 5, 6, 0));
    try s.seal();
    try t.expectError(error.InvalidState, s.addPublication(.commands_written, 5, 6, 2));
    try t.expect(!s.complete());
    s.abort();
    try t.expectError(error.Aborted, s.readReady(.commands_written, 1));
    try t.expectError(error.Aborted, s.publicationReady(.commands_written, 1));
}

test "mailbox abort safe before init and zero-read budget has finite empty completion" {
    const s = try t.allocator.create(schedule.Scheduler);
    defer t.allocator.destroy(s);
    s.* = .{};
    s.abort();
    try t.expect(!s.complete());
    try t.expectError(error.ReadBudgetExceeded, s.init(schedule.hard_read_cap + 1));
    try s.init(0);
    try s.seal();
    try t.expect(s.complete());
    try t.expectError(error.InvalidState, s.init(0));
}

test "mailbox preflight rejects future establishing publication and already-ended newer publication" {
    const future = try create(1);
    defer t.allocator.destroy(future);
    try future.addRead(.commands_written, 3, 4, 1);
    try future.addPublication(.commands_written, 5, 6, 1);
    try t.expectError(error.UnreachablePrefix, future.seal());
    const stale = try create(1);
    defer t.allocator.destroy(stale);
    try stale.addRead(.commands_written, 5, 6, 0);
    try stale.addPublication(.commands_written, 3, 4, 1);
    try t.expectError(error.UnreachablePrefix, stale.seal());
}

test "mailbox publication brackets reject order and bounded overflow before owner" {
    const s = try create(0);
    defer t.allocator.destroy(s);
    try t.expectError(error.InvalidOrder, s.addPublication(.closed, 2, 2, 1));
    try s.addPublication(.closed, 1, 2, 1);
    try t.expectError(error.InvalidOrder, s.addPublication(.closed, 2, 4, 1));
    for (1..schedule.hard_publication_cap) |i| try s.addPublication(.closed, 2 * i + 1, 2 * i + 2, 1);
    try t.expectError(error.PublicationBudgetExceeded, s.addPublication(.closed, 131073, 131074, 1));
    try s.seal();
}

test "service sequence old read pins overlapping odd publication until actual acquire" {
    const s = try create(2);
    defer t.allocator.destroy(s);
    // Counter zero stands for the preceding even episode. This is the exact
    // r14 bracket order translated to small occurrences, not a forced result.
    try s.addPublication(.service_sequence, 1, 4, 1);
    try s.addRead(.service_sequence, 2, 3, 0);
    try s.addRead(.service_sequence, 5, 6, 1);
    try s.seal();
    try t.expect(!try s.publicationReady(.service_sequence, 1));
    try t.expect(try s.readReady(.service_sequence, 2));
    _ = try s.acquired(.service_sequence, 0);
    try t.expect(try s.publicationReady(.service_sequence, 1));
    try t.expectEqual(@as(u64, 0), s.observed(.service_sequence));
    try s.published(.service_sequence, 1);
    try t.expect(try s.readReady(.service_sequence, 5));
    _ = try s.acquired(.service_sequence, 1);
    try t.expect(s.complete());
}

test "service sequence new target waits actual publication and has one global stream-independent key" {
    const s = try create(2);
    defer t.allocator.destroy(s);
    // The driver maps all six source read sites to this single slot regardless
    // of their diagnostic stream index/generation; those labels stay on tape.
    try s.addRead(.service_sequence, 1, 4, 1);
    try s.addRead(.service_sequence, 5, 6, 1);
    try s.addPublication(.service_sequence, 2, 3, 1);
    try s.addPublication(.service_sequence, 7, 8, 2);
    try s.seal();
    try t.expect(!try s.readReady(.service_sequence, 1));
    try t.expect(try s.publicationReady(.service_sequence, 1));
    try t.expect(!try s.readReady(.service_sequence, 1));
    try s.published(.service_sequence, 1);
    try t.expect(try s.readReady(.service_sequence, 1));
    _ = try s.acquired(.service_sequence, 1);
    try t.expect(!try s.publicationReady(.service_sequence, 2));
    try t.expect(try s.readReady(.service_sequence, 5));
    _ = try s.acquired(.service_sequence, 1);
    try t.expect(try s.publicationReady(.service_sequence, 2));
    try s.published(.service_sequence, 2);
    try t.expectEqual(@as(u64, 0), s.observed(.commands_written));
    try t.expect(s.complete());
}

test "service sequence temporal impossibility reset and skipped epochs reject before owner" {
    const future = try create(1);
    defer t.allocator.destroy(future);
    try future.addRead(.service_sequence, 1, 2, 1);
    try future.addPublication(.service_sequence, 3, 4, 1);
    try t.expectError(error.UnreachablePrefix, future.seal());
    try t.expectError(error.InvalidPrefix, future.addPublication(.service_sequence, 5, 6, 0));
    try t.expectError(error.InvalidPrefix, future.addPublication(.service_sequence, 5, 6, 3));
    const stale = try create(1);
    defer t.allocator.destroy(stale);
    try stale.addPublication(.service_sequence, 1, 2, 1);
    try stale.addRead(.service_sequence, 3, 4, 0);
    try t.expectError(error.UnreachablePrefix, stale.seal());
}

test "lifecycle gate prefix slots support only native repeated acknowledgments and progress" {
    const s = try create(3);
    defer t.allocator.destroy(s);
    try s.addRead(.gate_ack, 1, 2, 0);
    try s.addPublication(.gate_ack, 3, 4, 1);
    try s.addPublication(.gate_ack, 5, 6, 1);
    try s.addRead(.gate_progress, 7, 8, 1);
    try s.addPublication(.gate_progress, 3, 4, 1);
    try s.addPublication(.gate_progress, 5, 6, 1);
    try t.expectError(error.InvalidPrefix, s.addPublication(.gate_progress, 9, 10, 3));
    try s.addPublication(.gate_request, 1, 2, 1);
    try t.expectError(error.InvalidPrefix, s.addPublication(.gate_request, 3, 4, 1));
    try s.addPublication(.gate_resumed, 1, 2, 1);
    try s.addPublication(.gate_stopped, 9, 10, 1);
    try t.expectError(error.InvalidPrefix, s.addRead(.gate_stopped, 11, 12, 2));
    try s.seal();
    try t.expect(!try s.publicationReady(.gate_ack, 1));
    try t.expect(try s.readReady(.gate_ack, 1));
    _ = try s.acquired(.gate_ack, 0);
    for (0..2) |_| {
        try t.expect(try s.publicationReady(.gate_ack, 1));
        try s.published(.gate_ack, 1);
        try t.expect(try s.publicationReady(.gate_progress, 1));
        try s.published(.gate_progress, 1);
    }
    try t.expect(try s.readReady(.gate_progress, 7));
    _ = try s.acquired(.gate_progress, 1);
    for ([_]schedule.Slot{ .gate_request, .gate_resumed, .gate_stopped }) |slot| {
        try t.expect(try s.publicationReady(slot, 1));
        try s.published(slot, 1);
    }
    try t.expect(s.complete());
}

test "gate progress read uses first publication not a future equal-value store" {
    const s = try create(1);
    defer t.allocator.destroy(s);
    try s.addPublication(.gate_progress, 1, 2, 1);
    try s.addRead(.gate_progress, 3, 4, 1);
    try s.addPublication(.gate_progress, 5, 6, 1);
    try s.seal();
    try t.expect(!try s.readReady(.gate_progress, 3));
    try t.expect(try s.publicationReady(.gate_progress, 1));
    try s.published(.gate_progress, 1);
    try t.expect(try s.readReady(.gate_progress, 3));
    _ = try s.acquired(.gate_progress, 1);
    // Equal values do not erase either physical publication obligation.
    try t.expect(!s.complete());
    try t.expect(try s.publicationReady(.gate_progress, 1));
    try s.published(.gate_progress, 1);
    try t.expect(s.complete());
}

test "runtime frame sparse progress preserves overlapping old acquire before native publication" {
    const s = try create(1);
    defer t.allocator.destroy(s);
    try s.addPublication(.runtime_frame, 1, 2, 64);
    try s.addPublication(.runtime_frame, 3, 5, 128);
    try s.addRead(.runtime_frame, 4, 6, 64);
    try s.seal();
    try t.expect(try s.publicationReady(.runtime_frame, 64));
    try s.published(.runtime_frame, 64);
    try t.expect(!try s.publicationReady(.runtime_frame, 128));
    try t.expect(try s.readReady(.runtime_frame, 4));
    try t.expectEqual(@as(u64, 6), try s.acquired(.runtime_frame, 64));
    try t.expect(try s.publicationReady(.runtime_frame, 128));
    try t.expectEqual(@as(u64, 64), s.observed(.runtime_frame));
    try s.published(.runtime_frame, 128);
    try t.expect(s.complete());
}

test "runtime frame variable span target waits for actual sparse publication" {
    const s = try create(1);
    defer t.allocator.destroy(s);
    try s.addPublication(.runtime_frame, 1, 2, 64);
    try s.addRead(.runtime_frame, 3, 6, 73);
    try s.addPublication(.runtime_frame, 4, 5, 73);
    try s.seal();
    try t.expect(!try s.readReady(.runtime_frame, 3));
    try t.expect(try s.publicationReady(.runtime_frame, 64));
    try s.published(.runtime_frame, 64);
    try t.expect(!try s.readReady(.runtime_frame, 3));
    try t.expect(try s.publicationReady(.runtime_frame, 73));
    try t.expect(!try s.readReady(.runtime_frame, 3));
    try s.published(.runtime_frame, 73);
    try t.expect(try s.readReady(.runtime_frame, 3));
    _ = try s.acquired(.runtime_frame, 73);
    try t.expectEqual(@as(u64, 0), s.observed(.runtime_commit_horizon));
    try t.expect(s.complete());
}

test "runtime sparse frame rejects holes resets duplicates and impossible brackets" {
    const s = try create(1);
    defer t.allocator.destroy(s);
    try t.expectError(error.InvalidPrefix, s.addPublication(.runtime_frame, 1, 2, 0));
    try s.addPublication(.runtime_frame, 1, 2, 64);
    try t.expectError(error.InvalidPrefix, s.addPublication(.runtime_frame, 3, 4, 64));
    try t.expectError(error.InvalidPrefix, s.addPublication(.runtime_frame, 3, 4, 0));
    try s.addPublication(.runtime_frame, 3, 4, 128);
    try s.addRead(.runtime_frame, 5, 6, 65);
    try t.expectError(error.UnreachablePrefix, s.seal());
    const future = try create(1);
    defer t.allocator.destroy(future);
    try future.addRead(.runtime_frame, 1, 2, 64);
    try future.addPublication(.runtime_frame, 3, 4, 64);
    try t.expectError(error.UnreachablePrefix, future.seal());
    const stale = try create(1);
    defer t.allocator.destroy(stale);
    try stale.addPublication(.runtime_frame, 1, 2, 64);
    try stale.addRead(.runtime_frame, 3, 4, 0);
    try t.expectError(error.UnreachablePrefix, stale.seal());
}

test "commit horizon initial and repeated stores retain actual operation obligations" {
    const s = try create(2);
    defer t.allocator.destroy(s);
    try s.addPublication(.runtime_commit_horizon, 1, 2, 0);
    try s.addRead(.runtime_commit_horizon, 3, 4, 0);
    try s.addPublication(.runtime_commit_horizon, 5, 6, 64);
    try s.addRead(.runtime_commit_horizon, 7, 8, 64);
    try s.addPublication(.runtime_commit_horizon, 9, 10, 64);
    try t.expectError(error.InvalidPrefix, s.addPublication(.runtime_commit_horizon, 11, 12, 63));
    try s.seal();
    try t.expect(try s.publicationReady(.runtime_commit_horizon, 0));
    try s.published(.runtime_commit_horizon, 0);
    try t.expect(!try s.publicationReady(.runtime_commit_horizon, 64));
    try t.expect(try s.readReady(.runtime_commit_horizon, 3));
    _ = try s.acquired(.runtime_commit_horizon, 0);
    try t.expect(try s.publicationReady(.runtime_commit_horizon, 64));
    try s.published(.runtime_commit_horizon, 64);
    try t.expect(try s.readReady(.runtime_commit_horizon, 7));
    _ = try s.acquired(.runtime_commit_horizon, 64);
    try t.expect(!s.complete());
    try t.expect(try s.publicationReady(.runtime_commit_horizon, 64));
    try s.published(.runtime_commit_horizon, 64);
    try t.expect(s.complete());
}

test "runtime sparse calendar abort releases both waiting operation classes" {
    const s = try create(1);
    defer t.allocator.destroy(s);
    try s.addRead(.runtime_frame, 1, 4, 64);
    try s.addPublication(.runtime_frame, 2, 3, 64);
    try s.seal();
    try t.expect(!try s.readReady(.runtime_frame, 1));
    s.abort();
    try t.expectError(error.Aborted, s.readReady(.runtime_frame, 1));
    try t.expectError(error.Aborted, s.publicationReady(.runtime_frame, 64));
    try t.expect(!s.complete());
}
