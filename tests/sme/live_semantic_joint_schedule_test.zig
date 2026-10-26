const std = @import("std");
const t = std.testing;
const m = @import("sme-live-semantic-joint-schedule");
const Op = m.Operation;
fn scalar(kind: m.Kind, b: u64, e: u64, value: u64) Op {
    return .{ .role = if (kind == .frame_read or kind == .sequence_read) .control else .render, .kind = kind, .before = b, .after = e, .value = value };
}
fn job(kind: m.Kind, b: u64, e: u64, id: u64) Op {
    return .{ .role = if (kind == .queued or kind == .free) .control else .worker, .kind = kind, .before = b, .after = e, .generation = id };
}
// Independent interpreter: separate numeric job FSM and scalar episode phase;
// verifies every returned observation, original role order and interval embedding.
// It neither calls planner helpers nor assigns read values to model state.
const Oracle = struct {
    state: [48]u8 = @splat(0),
    ids: [48]u64 = @splat(0),
    frame: u64 = 0,
    sequence: u64 = 0,
    phase: u8 = 0,
    fn execute(self: *Oracle, op: Op) !void {
        const i: usize = @intCast(op.index);
        switch (op.kind) {
            .scan => try t.expectEqual(op.eligible.?, self.state[i] == (if (op.role == .worker) @as(u8, 1) else 3)),
            .queued => {
                try t.expectEqual(@as(u8, 0), self.state[i]);
                self.state[i] = 1;
                self.ids[i] = op.generation;
            },
            .running, .completed, .free => {
                const expected: u8 = if (op.kind == .running) 1 else if (op.kind == .completed) 2 else 3;
                try t.expectEqual(expected, self.state[i]);
                try t.expectEqual(self.ids[i], op.generation);
                self.state[i] = if (expected == 3) 0 else expected + 1;
            },
            .frame_read => try t.expectEqual(self.frame, op.value.?),
            .sequence_read => try t.expectEqual(self.sequence, op.value.?),
            .sequence_odd => {
                try t.expectEqual(@as(u8, 0), self.phase);
                try t.expectEqual(self.sequence + 1, op.value.?);
                self.sequence += 1;
                self.phase = 1;
            },
            .frame_store => {
                try t.expectEqual(@as(u8, 1), self.phase);
                try t.expect(op.value.? >= self.frame);
                self.frame = op.value.?;
                self.phase = 2;
            },
            .sequence_even => {
                try t.expectEqual(@as(u8, 2), self.phase);
                try t.expectEqual(self.sequence + 1, op.value.?);
                self.sequence += 1;
                self.phase = 0;
            },
        }
    }
};
const Result = struct { ops: [64]Op = undefined, len: usize = 0 };
fn run(inputs: [3][]const Op) !Result {
    var s: m.Scheduler = .{};
    try s.init(48);
    var input: [3]usize = @splat(0);
    var output: [3]usize = @splat(0);
    var oracle: Oracle = .{};
    var frontier: u64 = 0;
    var result: Result = .{};
    while (true) {
        for (0..3) |r| {
            if (s.roles[r].head != null or s.roles[r].eof) continue;
            if (input[r] == inputs[r].len) try s.roleEOF(@enumFromInt(r)) else {
                try s.push(inputs[r][input[r]]);
                input[r] += 1;
            }
        }
        const pick = (try s.next()) orelse break;
        const r = @intFromEnum(pick.op.role);
        try t.expectEqualDeep(inputs[r][output[r]], pick.op);
        output[r] += 1;
        try t.expectEqual(result.len, pick.ordinal);
        frontier = @max(frontier, pick.op.before);
        try t.expect(frontier < pick.op.after);
        try oracle.execute(pick.op);
        try t.expect(result.len < result.ops.len);
        result.ops[result.len] = pick.op;
        result.len += 1;
    }
    try s.finish();
    try t.expectEqualDeep(input, output);
    try t.expectEqual(@as(u8, 0), oracle.phase);
    for (oracle.state) |state| try t.expectEqual(@as(u8, 0), state);
    return result;
}
test "joint clean lifecycle and canonical independent interpretation" {
    const c = [_]Op{ job(.queued, 1, 2, 1), scalar(.sequence_read, 3, 6, 0), scalar(.frame_read, 9, 12, 1), job(.free, 19, 20, 1) };
    const w = [_]Op{ job(.running, 7, 8, 1), job(.completed, 15, 16, 1) };
    const r = [_]Op{ scalar(.sequence_odd, 4, 5, 1), scalar(.frame_store, 10, 11, 1), scalar(.sequence_even, 13, 14, 2) };
    const first = try run(.{ &c, &w, &r });
    const again = try run(.{ &c, &w, &r });
    try t.expectEqual(first.len, again.len);
    try t.expectEqualDeep(first.ops[0..first.len], again.ops[0..again.len]);
    // The already-started sequence0 read must precede the nested odd write.
    try t.expectEqual(m.Kind.sequence_read, first.ops[1].kind);
}
test "frame all six bracket shapes zero and one read observations" {
    const shapes = [_][4]u64{ .{ 3, 4, 5, 6 }, .{ 5, 6, 3, 4 }, .{ 3, 5, 4, 6 }, .{ 4, 6, 3, 5 }, .{ 3, 6, 4, 5 }, .{ 4, 5, 3, 6 } };
    for (shapes, 0..) |p, i| for (0..2) |value| {
        const c = [_]Op{scalar(.frame_read, p[0], p[1], value)};
        const r = [_]Op{ scalar(.sequence_odd, 1, 2, 1), scalar(.frame_store, p[2], p[3], 1), scalar(.sequence_even, 7, 8, 2) };
        if ((i == 0 and value == 1) or (i == 1 and value == 0)) {
            try t.expectError(error.ImpossibleSchedule, run(.{ &c, &.{}, &r }));
        } else _ = try run(.{ &c, &.{}, &r });
    };
}
test "same frame writes retain distinct sequence episodes and odd reads" {
    _ = try run(.{ &.{ scalar(.sequence_read, 3, 4, 1), scalar(.frame_read, 7, 8, 0), scalar(.sequence_read, 15, 20, 4) }, &.{}, &.{
        scalar(.sequence_odd, 1, 2, 1),   scalar(.frame_store, 5, 6, 0),   scalar(.sequence_even, 9, 10, 2),
        scalar(.sequence_odd, 11, 12, 3), scalar(.frame_store, 13, 14, 0), scalar(.sequence_even, 17, 18, 4),
    } });
}
test "pending false job read protected against destructive queued publication" {
    const false_scan: Op = .{ .role = .worker, .kind = .scan, .before = 1, .after = 8, .eligible = false };
    const result = try run(.{ &.{ job(.queued, 2, 3, 1), job(.free, 13, 14, 1) }, &.{ false_scan, job(.running, 9, 10, 1), job(.completed, 11, 12, 1) }, &.{} });
    try t.expectEqual(m.Kind.scan, result.ops[0].kind);
}
test "mixed-domain dependency deadline and forged observation reject" {
    // Control requires future frame1 before it can queue job; Worker requires
    // queued job before deadline preceding Render's future frame publication.
    try t.expectError(error.ImpossibleSchedule, run(.{
        &.{ scalar(.frame_read, 1, 10, 1), job(.queued, 11, 12, 1), job(.free, 19, 20, 1) },
        &.{ job(.running, 2, 3, 1), job(.completed, 13, 14, 1) },
        &.{ scalar(.sequence_odd, 4, 5, 1), scalar(.frame_store, 6, 7, 1), scalar(.sequence_even, 15, 16, 2) },
    }));
    try t.expectError(error.ImpossibleSchedule, run(.{ &.{scalar(.frame_read, 1, 2, 99)}, &.{}, &.{} }));
    try t.expectError(error.ImpossibleSchedule, run(.{ &.{ job(.queued, 1, 2, 1), job(.free, 7, 8, 1) }, &.{ job(.running, 3, 4, 2), job(.completed, 5, 6, 2) }, &.{} }));
}
test "episode grammar final state and frame regression fail closed" {
    try t.expectError(error.ImpossibleSchedule, run(.{ &.{}, &.{}, &.{scalar(.frame_store, 1, 2, 0)} }));
    try t.expectError(error.ImpossibleSchedule, run(.{ &.{}, &.{}, &.{ scalar(.sequence_odd, 1, 2, 1), scalar(.frame_store, 3, 4, 0), scalar(.frame_store, 5, 6, 0), scalar(.sequence_even, 7, 8, 2) } }));
    try t.expectError(error.Incomplete, run(.{ &.{}, &.{}, &.{scalar(.sequence_odd, 1, 2, 1)} }));
    try t.expectError(error.ImpossibleSchedule, run(.{ &.{}, &.{}, &.{ scalar(.sequence_odd, 1, 2, 1), scalar(.sequence_even, 3, 4, 2) } }));
    try t.expectError(error.ImpossibleSchedule, run(.{ &.{}, &.{}, &.{ scalar(.sequence_odd, 1, 2, 1), scalar(.frame_store, 3, 4, 5), scalar(.sequence_even, 5, 6, 2), scalar(.sequence_odd, 7, 8, 3), scalar(.frame_store, 9, 10, 4) } }));
    try t.expectError(error.Incomplete, run(.{ &.{job(.queued, 1, 2, 1)}, &.{}, &.{} }));
}
test "bounded API rejects missing heads malformed owner and overflow without mutation" {
    var s: m.Scheduler = .{};
    try t.expectError(error.InvalidState, s.next());
    try t.expectError(error.UnsupportedSlots, s.init(0));
    try t.expectError(error.UnsupportedSlots, s.init(49));
    try s.init(48);
    try t.expectError(error.MissingHead, s.next());
    var malformed = scalar(.frame_read, 1, 2, 0);
    malformed.role = .worker;
    try t.expectError(error.InvalidOperation, s.push(malformed));
    malformed = scalar(.sequence_read, 1, 2, 0);
    malformed.generation = 1;
    try t.expectError(error.InvalidOperation, s.push(malformed));
    malformed = job(.queued, 1, 2, 1);
    malformed.index = 48;
    try t.expectError(error.InvalidSlot, s.push(malformed));
    try s.push(scalar(.frame_read, 1, 2, 0));
    try s.roleEOF(.worker);
    try s.roleEOF(.render);
    s.next_ordinal = std.math.maxInt(u64);
    try t.expectError(error.CounterOverflow, s.next());
    try t.expect(s.roles[0].head != null);
    try t.expectEqual(@as(u64, 0), s.frontier);
    try t.expect(@sizeOf(m.Scheduler) < 8192);
}

// Independent existential oracle. Exhaustive choices among source heads, with
// numeric states and a separate phase FSM; no planner helpers/choice heuristic.
const SearchState = struct {
    job: u8 = 0,
    id: u64 = 0,
    frame: u64 = 0,
    seq: u64 = 0,
    phase: u8 = 0,
    fn apply(self: *SearchState, op: Op) bool {
        switch (op.kind) {
            .scan => if ((self.job == (if (op.role == .worker) @as(u8, 1) else 3)) != op.eligible.?) {
                return false;
            },
            .queued => {
                if (self.job != 0) return false;
                self.job = 1;
                self.id = op.generation;
            },
            .running => {
                if (self.job != 1 or self.id != op.generation) return false;
                self.job = 2;
            },
            .completed => {
                if (self.job != 2 or self.id != op.generation) return false;
                self.job = 3;
            },
            .free => {
                if (self.job != 3 or self.id != op.generation) return false;
                self.job = 0;
            },
            .frame_read => if (self.frame != op.value.?) {
                return false;
            },
            .sequence_read => if (self.seq != op.value.?) {
                return false;
            },
            .sequence_odd => {
                if (self.phase != 0 or self.seq == std.math.maxInt(u64) or op.value.? != self.seq + 1) return false;
                self.seq += 1;
                self.phase = 1;
            },
            .frame_store => {
                if (self.phase != 1 or op.value.? < self.frame) return false;
                self.frame = op.value.?;
                self.phase = 2;
            },
            .sequence_even => {
                if (self.phase != 2 or self.seq == std.math.maxInt(u64) or op.value.? != self.seq + 1) return false;
                self.seq += 1;
                self.phase = 0;
            },
        }
        return true;
    }
};
fn search(inputs: [3][]const Op, cursor: [3]usize, state: SearchState, lower: u64) bool {
    if (cursor[0] == inputs[0].len and cursor[1] == inputs[1].len and cursor[2] == inputs[2].len) return state.job == 0 and state.phase == 0;
    for (0..3) |r| {
        if (cursor[r] == inputs[r].len) continue;
        const op = inputs[r][cursor[r]];
        const gap = @max(lower, op.before);
        if (gap >= op.after) continue;
        var next_state = state;
        if (!next_state.apply(op)) continue;
        var next = cursor;
        next[r] += 1;
        if (search(inputs, next, next_state, gap)) return true;
    }
    return false;
}
const Corpus = struct {
    ops: [3][3]Op = undefined,
    cases: u64 = 0,
    accepted: u64 = 0,
    feasible: u64 = 0,
};
fn endpoints(corpus: *Corpus, cursor: [3]usize, marker: u64) !void {
    const prefix_lengths = [3]usize{ 2, 1, 3 };
    if (marker == 13) {
        // Fixed final cleanup after EVERY enumerated prefix. It is real FSM
        // completion, not a reset of the oracle or scheduler state.
        corpus.ops[0][2] = job(.free, 15, 16, 1);
        corpus.ops[1][1] = job(.completed, 13, 14, 1);
        const inputs = [3][]const Op{ corpus.ops[0][0..3], corpus.ops[1][0..2], corpus.ops[2][0..3] };
        const feasible = search(inputs, .{ 0, 0, 0 }, .{}, 0);
        corpus.cases += 1;
        if (feasible) corpus.feasible += 1;
        const result = run(inputs) catch |err| switch (err) {
            error.ImpossibleSchedule, error.Incomplete => return,
            else => return err,
        };
        _ = result;
        corpus.accepted += 1;
        // Soundness only. Deliberate conservative rejection is permitted.
        try t.expect(feasible);
        return;
    }
    // Every shuffle of the role-local BEFORE,AFTER endpoint words. This
    // includes nesting/crossing, serial gaps and deadlines before another B.
    for (0..3) |r| {
        if (cursor[r] == prefix_lengths[r] * 2) continue;
        const op = &corpus.ops[r][cursor[r] / 2];
        if (cursor[r] % 2 == 0) op.before = marker else op.after = marker;
        var next = cursor;
        next[r] += 1;
        try endpoints(corpus, next, marker + 1);
    }
}
test "independent exhaustive mixed-domain oracle checks 194040 histories soundness" {
    var corpus: Corpus = .{};
    // Three frame observations (including impossible2), four sequence
    // observations (including impossible3), each with frame0 or frame1 store.
    for (0..2) |published| for (0..7) |observation| {
        corpus.ops[0][0] = scalar(if (observation < 3) .frame_read else .sequence_read, 1, 2, if (observation < 3) observation else observation - 3);
        corpus.ops[0][1] = job(.queued, 3, 4, 1);
        corpus.ops[1][0] = job(.running, 5, 6, 1);
        corpus.ops[2][0] = scalar(.sequence_odd, 7, 8, 1);
        corpus.ops[2][1] = scalar(.frame_store, 9, 10, published);
        corpus.ops[2][2] = scalar(.sequence_even, 11, 12, 2);
        try endpoints(&corpus, .{ 0, 0, 0 }, 1);
    };
    try t.expectEqual(@as(u64, 194040), corpus.cases);
    try t.expect(corpus.accepted > 0 and corpus.feasible >= corpus.accepted and corpus.feasible < corpus.cases);
    std.debug.print("JOINT_ORACLE cases={d} feasible={d} accepted={d} conservative_rejects={d}\n", .{ corpus.cases, corpus.feasible, corpus.accepted, corpus.feasible - corpus.accepted });
}
