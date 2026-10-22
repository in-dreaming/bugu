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
    const first = try acknowledgeSnapshot(&host);
    try SnapshotProbe.inspect(&host, snapshotPending);
    try t.expect(host.park_sequence == null and !host.gate.parked(91, first));
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
