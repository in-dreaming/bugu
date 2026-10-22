const std = @import("std");
const schedule = @import("sme-author-live-owner").semantic_replay.exclusion_schedule;
const t = std.testing;
fn create(limit: usize) !*schedule.Scheduler {
    const s = try t.allocator.create(schedule.Scheduler);
    errdefer t.allocator.destroy(s);
    s.* = .{};
    try s.init(limit);
    return s;
}
fn op(role: schedule.Role, kind: schedule.Kind, before: u64, after: u64, success: ?bool) schedule.Operation {
    return .{ .role = role, .kind = kind, .before = before, .after = after, .site = if (role == .control) (if (kind == .claim) @as(u16, 0x6c) else 0x6e) else (if (kind == .claim) @as(u16, 0x4e) else 0x52), .index = 0, .generation = if (role == .control) 1 else 0, .success = success };
}
test "exclusion successful close handoff can follow release inside its bracket" {
    const s = try create(4);
    defer t.allocator.destroy(s);
    try s.add(op(.worker, .claim, 1, 2, true));
    try s.add(op(.worker, .release, 4, 5, null));
    try s.add(op(.control, .claim, 3, 6, true));
    try s.add(op(.control, .release, 7, 8, null));
    try s.seal();
    try t.expect(try s.ready(.worker, 1));
    try s.completed(.worker, 2, true);
    try t.expect(!try s.ready(.control, 3));
    try t.expect(try s.ready(.worker, 4));
    try s.completed(.worker, 5, null);
    try t.expect(try s.ready(.control, 3));
    try t.expectError(error.ReplayMismatch, s.completed(.control, 6, false));
    try s.completed(.control, 6, true);
    try t.expect(try s.ready(.control, 7));
    try s.completed(.control, 8, null);
    try t.expect(s.complete());
}
test "exclusion failed claim may linearize before earlier stamped release after" {
    const s = try create(3);
    defer t.allocator.destroy(s);
    try s.add(op(.worker, .claim, 1, 2, true));
    try s.add(op(.worker, .release, 4, 5, null));
    try s.add(op(.control, .claim, 3, 6, false));
    try s.seal();
    try t.expect(try s.ready(.worker, 1));
    try s.completed(.worker, 2, true);
    try t.expect(!try s.ready(.worker, 4));
    try t.expect(try s.ready(.control, 3));
    // Progress advances here even though its global AFTER6 must wait for5.
    try s.completed(.control, 6, false);
    try t.expect(try s.ready(.worker, 4));
    try s.completed(.worker, 5, null);
    try t.expect(s.complete());
}
test "exclusion failed idle logical claim can follow overlapping successful other claim" {
    const s = try create(3);
    defer t.allocator.destroy(s);
    try s.add(op(.control, .claim, 1, 3, false));
    try s.add(op(.worker, .claim, 2, 4, true));
    try s.add(op(.worker, .release, 5, 6, null));
    try s.seal();
    try t.expect(!try s.ready(.control, 1));
    try t.expect(try s.ready(.worker, 2));
    try s.completed(.worker, 4, true);
    try t.expect(try s.ready(.control, 1));
    try s.completed(.control, 3, false);
    try t.expect(try s.ready(.worker, 5));
    try s.completed(.worker, 6, null);
    try t.expect(s.complete());
}
test "exclusion successful claim can precede later stamped enabling release" {
    const s = try create(4);
    defer t.allocator.destroy(s);
    try s.add(op(.worker, .claim, 1, 2, true));
    try s.add(op(.control, .claim, 3, 5, true));
    try s.add(op(.worker, .release, 4, 6, null));
    try s.add(op(.control, .release, 7, 8, null));
    try s.seal();
    try t.expect(try s.ready(.worker, 1));
    try s.completed(.worker, 2, true);
    try t.expect(!try s.ready(.control, 3));
    try t.expect(try s.ready(.worker, 4));
    try s.completed(.worker, 6, null);
    try t.expect(try s.ready(.control, 3));
    try s.completed(.control, 5, true);
    try t.expect(try s.ready(.control, 7));
    try s.completed(.control, 8, null);
    try t.expect(s.complete());
}
test "exclusion rejects impossible claim order foreign release and missing release" {
    const s = try create(3);
    defer t.allocator.destroy(s);
    try s.add(op(.control, .claim, 1, 2, false));
    try s.add(op(.worker, .claim, 3, 4, true));
    try s.add(op(.worker, .release, 5, 6, null));
    try t.expectError(error.ImpossibleExclusion, s.seal());
    const foreign = try create(2);
    defer t.allocator.destroy(foreign);
    try foreign.add(op(.worker, .claim, 1, 2, true));
    try foreign.add(op(.control, .release, 3, 4, null));
    try t.expectError(error.ImpossibleExclusion, foreign.seal());
    const missing = try create(1);
    defer t.allocator.destroy(missing);
    try missing.add(op(.worker, .claim, 1, 2, true));
    try t.expectError(error.Incomplete, missing.seal());
}
test "exclusion finite identity rejects nesting budget overflow and wrong prepare release" {
    const s = try create(2);
    defer t.allocator.destroy(s);
    var claim = op(.worker, .claim, 1, 2, true);
    claim.site = 0x6f;
    claim.index = 7;
    claim.generation = 31;
    try s.add(claim);
    try t.expectError(error.InvalidOrder, s.add(op(.worker, .release, 2, 3, null)));
    try s.add(op(.worker, .release, 3, 4, null));
    try t.expectError(error.OperationBudgetExceeded, s.add(op(.control, .claim, 5, 6, true)));
    try t.expectError(error.ImpossibleExclusion, s.seal());
}
test "exclusion abort safe before init and releases wait without granting completion" {
    const s = try t.allocator.create(schedule.Scheduler);
    defer t.allocator.destroy(s);
    s.* = .{};
    s.abort();
    try t.expect(!s.complete());
    try s.init(0);
    try s.seal();
    try t.expect(s.complete());
    s.abort();
    try t.expectError(error.Aborted, s.ready(.control, 1));
    try t.expect(!s.complete());
}

test "exclusion repeated zero busy epochs retain operation occurrence identity" {
    const s = try create(4);
    defer t.allocator.destroy(s);
    try s.add(op(.worker, .claim, 1, 2, true));
    try s.add(op(.worker, .release, 3, 4, null));
    try s.add(op(.worker, .claim, 5, 6, true));
    try s.add(op(.worker, .release, 7, 8, null));
    try s.seal();
    try t.expect(try s.ready(.worker, 1));
    try s.completed(.worker, 2, true);
    try t.expect(try s.ready(.worker, 3));
    try s.completed(.worker, 4, null);
    try t.expectError(error.InvalidOrder, s.ready(.worker, 1));
    try t.expect(try s.ready(.worker, 5));
    try t.expectError(error.InvalidOrder, s.completed(.worker, 2, true));
    try s.completed(.worker, 6, true);
    try t.expect(try s.ready(.worker, 7));
    try s.completed(.worker, 8, null);
    try t.expect(s.complete());
}
test "exclusion prepare release preserves exact asset claim identity" {
    const s = try create(2);
    defer t.allocator.destroy(s);
    var claim = op(.worker, .claim, 1, 2, true);
    claim.site = 0x6f;
    claim.index = 7;
    claim.generation = 31;
    var release = claim;
    release.kind = .release;
    release.site = 0x70;
    release.before = 3;
    release.after = 4;
    release.success = null;
    try s.add(claim);
    try s.add(release);
    try s.seal();
    try t.expect(try s.ready(.worker, 1));
    try s.completed(.worker, 2, true);
    try t.expect(try s.ready(.worker, 3));
    try s.completed(.worker, 4, null);
    try t.expect(s.complete());
}

test "exclusion same holder fully bracketed failed claim preserves original ownership" {
    const s = try create(3);
    defer t.allocator.destroy(s);
    try s.add(op(.worker, .claim, 1, 2, true));
    try t.expectError(error.InvalidOrder, s.add(op(.worker, .claim, 2, 3, false)));
    try s.add(op(.worker, .claim, 3, 4, false));
    try s.add(op(.worker, .release, 5, 6, null));
    try s.seal();
    try t.expect(try s.ready(.worker, 1));
    try s.completed(.worker, 2, true);
    try t.expect(try s.ready(.worker, 3));
    try s.completed(.worker, 4, false);
    try t.expect(try s.ready(.worker, 5));
    try s.completed(.worker, 6, null);
    try t.expect(s.complete());
}
