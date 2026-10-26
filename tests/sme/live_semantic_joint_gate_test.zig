const std = @import("std");
const t = std.testing;
const m = @import("sme-live-semantic-joint-schedule");
const gate = @import("sme-author-live-owner").semantic_replay.joint_gate;
const Cursor = struct {
    operations: []const m.Operation,
    index: usize = 0,
    pub fn next(self: *Cursor) !?m.Operation {
        if (self.index == self.operations.len) return null;
        const op = self.operations[self.index];
        self.index += 1;
        return op;
    }
};
const control = [_]m.Operation{.{ .role = .control, .kind = .frame_read, .before = 4, .after = 7, .value = 0 }};
const render = [_]m.Operation{
    .{ .role = .render, .kind = .sequence_odd, .before = 1, .after = 2, .value = 1 },
    .{ .role = .render, .kind = .frame_store, .before = 3, .after = 5, .value = 256 },
    .{ .role = .render, .kind = .sequence_even, .before = 6, .after = 8, .value = 2 },
};
fn init(g: *gate.Gate(Cursor)) !void {
    try g.init(1, .{ .{ .operations = &control }, .{ .operations = &.{} }, .{ .operations = &render } }, 4);
}
test "joint gate freezes crossed frame load before store and advances only actual completion" {
    var g: gate.Gate(Cursor) = .{};
    try init(&g);
    try t.expect(try g.ready(.render, 1));
    try t.expectEqual(@as(u64, 2), try g.completed(.render, .sequence_odd, 0, 0, null, 1));
    try t.expect(!try g.ready(.render, 3));
    try t.expect(try g.ready(.control, 4));
    var actual_frame = std.atomic.Value(u64).init(0);
    try t.expectEqual(@as(u64, 7), try g.completed(.control, .frame_read, 0, 0, null, actual_frame.load(.acquire)));
    try t.expect(try g.ready(.render, 3));
    actual_frame.store(256, .monotonic);
    try t.expectEqual(@as(u64, 5), try g.completed(.render, .frame_store, 0, 0, null, actual_frame.load(.acquire)));
    try t.expect(try g.ready(.render, 6));
    _ = try g.completed(.render, .sequence_even, 0, 0, null, 2);
    try g.finish();
}
test "joint gate mismatched actual read never advances or falls back to another plan" {
    var g: gate.Gate(Cursor) = .{};
    try init(&g);
    try t.expect(try g.ready(.render, 1));
    _ = try g.completed(.render, .sequence_odd, 0, 0, null, 1);
    try t.expect(try g.ready(.control, 4));
    try t.expectError(error.ReplayMismatch, g.completed(.control, .frame_read, 0, 0, null, 99));
    try t.expectEqual(@as(u64, 1), g.turn.load(.acquire));
    try t.expectError(error.Incomplete, g.finish());
    g.abort();
    try t.expectError(error.Aborted, g.ready(.render, 3));
}
