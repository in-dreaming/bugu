//! One finite witness -> independent joint check -> frozen macro-plan -> fresh
//! Service bridge. Test-only, serial roles, no production tape or admission.
const std = @import("std");
const t = std.testing;
const a = t.allocator;
const f = @import("sme-stream-reload-fixture");
const stream = @import("sme-streaming").stream;
const trace = @import("sme-trace");
const opus = @import("sme-opus");
const R = stream.readiness_observation;
const Op = enum { request, worker, accept, admit, ack, consume, publish, query, close };
const n = std.meta.fields(Op).len;
const Edge = struct { from: Op, to: Op };
// Separate declarative dependencies, not inferred from solver execution.
const dependencies = [_]Edge{
    .{ .from = .request, .to = .worker }, .{ .from = .worker, .to = .accept },
    .{ .from = .accept, .to = .admit },   .{ .from = .admit, .to = .ack },
    .{ .from = .admit, .to = .consume },  .{ .from = .consume, .to = .publish },
    .{ .from = .publish, .to = .query },  .{ .from = .query, .to = .close },
    .{ .from = .ack, .to = .close },
};
const Plan = struct { ops: [n]Op, publish_frame: u64 = 1 };
const canonical: Plan = .{ .ops = .{ .request, .worker, .accept, .admit, .ack, .consume, .publish, .query, .close } };
const Step = struct { op: Op, first: usize, end: usize };
const Clock = struct { stage: stream.WorkerClockStage, job: u64, sample: stream.OfflineClockSample };
const Witness = struct {
    points: [1024]stream.live_semantic.Point = undefined,
    used: usize = 0,
    boundaries: [64]stream.live_semantic.BoundaryPoint = undefined,
    boundary_used: usize = 0,
    clocks: [2]Clock = undefined,
    clocks_used: usize = 0,
    steps: [n]Step = undefined,
    handle: stream.Handle = .{ .index = 0, .generation = 0 },
    job: u64 = 0,
    read: R.QueryRead = .{},
    input: ?trace.Input = null,
    worker_input: ?trace.Input = null,
    pcm: [2]f32 = .{ 0, 0 },
    channels: usize = 0,
    consumed_before: u64 = 0,
    consumed_after: u64 = 0,
    closed: bool = false,
    overflow: bool = false,
};
const Recorder = struct {
    actual: *Witness,
    expected: ?*const Witness = null,
    clock_cursor: usize = 0,
    mismatch: bool = false,
    fn point(raw: *anyopaque, p: stream.live_semantic.Point) void {
        const self: *Recorder = @ptrCast(@alignCast(raw));
        const w = self.actual;
        if (w.used == w.points.len) {
            w.overflow = true;
            return;
        }
        if (self.expected) |e| {
            if (w.used >= e.used or !std.meta.eql(p, e.points[w.used])) self.mismatch = true;
        }
        w.points[w.used] = p;
        w.used += 1;
    }
    fn boundary(raw: *anyopaque, p: stream.live_semantic.BoundaryPoint) void {
        const self: *Recorder = @ptrCast(@alignCast(raw));
        const w = self.actual;
        if (w.boundary_used == w.boundaries.len) {
            w.overflow = true;
            return;
        }
        if (self.expected) |e| {
            if (w.boundary_used >= e.boundary_used or !std.meta.eql(p, e.boundaries[w.boundary_used])) self.mismatch = true;
        }
        w.boundaries[w.boundary_used] = p;
        w.boundary_used += 1;
    }
    fn clockObserve(raw: *anyopaque, stage: stream.WorkerClockStage, job: u64, sample: stream.OfflineClockSample) void {
        const self: *Recorder = @ptrCast(@alignCast(raw));
        const w = self.actual;
        if (w.clocks_used == w.clocks.len) {
            w.overflow = true;
            return;
        }
        w.clocks[w.clocks_used] = .{ .stage = stage, .job = job, .sample = sample };
        w.clocks_used += 1;
    }
    fn rawClock(raw: *anyopaque, stage: stream.WorkerClockStage, job: u64) stream.OfflineClockSample {
        const self: *Recorder = @ptrCast(@alignCast(raw));
        const e = self.expected.?;
        if (self.clock_cursor >= e.clocks_used) {
            self.mismatch = true;
            return .{ .value = 0, .available = false };
        }
        const c = e.clocks[self.clock_cursor];
        self.clock_cursor += 1;
        if (c.stage != stage or c.job != job) {
            self.mismatch = true;
            return .{ .value = 0, .available = false };
        }
        return c.sample; // Only external raw clock input. Never elapsed/throughput/read results.
    }
};
const Source = struct {
    bytes: []const u8,
    fn read(raw: *anyopaque, offset: u64, out: []u8) opus.Error!void {
        const self: *Source = @ptrCast(@alignCast(raw));
        if (offset > self.bytes.len or out.len > self.bytes.len - offset) return error.TruncatedContainer;
        @memcpy(out, self.bytes[@intCast(offset)..][0..out.len]);
    }
};
// Checker uses only immutable copied witness. It never receives a Service.
fn check(w: *const Witness, extra: ?Edge) !Plan {
    if (w.overflow or w.used < 6 or w.used > w.points.len or w.boundary_used > w.boundaries.len or w.clocks_used != 2 or !w.closed or w.handle.generation == 0 or w.job == 0) return error.IncompleteWitness;
    if (w.clocks[0].stage != .begin or w.clocks[1].stage != .end or w.clocks[0].job != w.job or w.clocks[1].job != w.job) return error.ClockMismatch;
    if (!w.clocks[0].sample.available or !w.clocks[1].sample.available or w.clocks[0].sample.error_code != 0 or w.clocks[1].sample.error_code != 0 or w.clocks[1].sample.value <= w.clocks[0].sample.value) return error.ClockMismatch;
    // Startup is asset preparation claim/release then open guard store.
    if (w.steps[0].first != 6) return error.InvalidOrder;
    for (w.points[0..4], 0..) |point, i| {
        const site: stream.live_semantic.Site = if (i < 2) .service_service_prepare_claim else .service_service_prepare_idle;
        const edge: stream.live_semantic.Edge = if (i % 2 == 0) .before else .after;
        if (point.site != site or point.role != .worker or point.index != 0 or point.generation != w.points[0].generation or point.edge != edge or point.value != (if (i == 0) @as(?u64, null) else 0)) return error.InvalidOrder;
    }
    for (w.points[4..6], 0..) |point, i| {
        if (point.site != .service_slot_guard_open or point.role != .control or point.index != w.handle.index or point.generation != w.handle.generation or point.value != 0 or point.edge != @as(stream.live_semantic.Edge, if (i == 0) .before else .after)) return error.InvalidOrder;
    }
    var seen: [n]bool = @splat(false);
    var position: [n]usize = undefined;
    for (w.steps, 0..) |step, i| {
        const k = @intFromEnum(step.op);
        if (seen[k] or step.first > step.end or step.end > w.used or (i > 0 and step.first != w.steps[i - 1].end)) return error.InvalidOrder;
        seen[k] = true;
        position[k] = i;
    }
    if (w.steps[n - 1].end != w.used) return error.InvalidOrder;
    for (dependencies) |edge| if (position[@intFromEnum(edge.from)] >= position[@intFromEnum(edge.to)]) return error.InvalidOrder;
    // Solve all fixed role/data/lifetime dependencies plus optional cross-domain edge.
    var edges: [dependencies.len + 1]Edge = undefined;
    @memcpy(edges[0..dependencies.len], &dependencies);
    var count: usize = dependencies.len;
    if (extra) |e| {
        edges[count] = e;
        count += 1;
    }
    var done: [n]bool = @splat(false);
    var plan: Plan = undefined;
    plan.publish_frame = 1;
    for (0..n) |out| {
        var chosen: ?usize = null;
        for (0..n) |candidate| {
            if (done[candidate]) continue;
            var blocked = false;
            for (edges[0..count]) |edge| {
                if (@intFromEnum(edge.to) == candidate and !done[@intFromEnum(edge.from)]) blocked = true;
            }
            if (!blocked) {
                chosen = candidate;
                break;
            }
        }
        const c = chosen orelse return error.JointCycle;
        done[c] = true;
        plan.ops[out] = @enumFromInt(c);
    }
    if (!w.read.has(.sequence_before) or !w.read.has(.sequence_after) or !w.read.has(.observation_frame) or !w.read.has(.consumed) or !w.read.has(.produced) or w.read.sequence_before != 2 or w.read.sequence_after != 2 or w.read.frame != 1 or w.read.consumed != 1 or w.read.produced < 1 or w.read.pending_job != null or w.read.scanned != 1 or w.read.state(0) != .free or w.consumed_before != 0 or w.consumed_after != 1) return error.ObservationMismatch;
    const input = w.input orelse return error.IncompleteWitness;
    if (input.payload != .readiness_snapshot or input.payload.readiness_snapshot.facts.pcm_start != 1 or input.payload.readiness_snapshot.facts.available_frames != w.read.produced - 1) return error.ObservationMismatch;
    const work = w.worker_input orelse return error.IncompleteWitness;
    if (work.payload != .worker or work.payload.worker.state != .ready or work.payload.worker.job != w.job or work.payload.worker.available_frames != w.read.produced) return error.JobMismatch;
    var queued: ?usize = null;
    var running: ?usize = null;
    var completed: ?usize = null;
    var freed: ?usize = null;
    var guard: ?usize = null;
    var released: ?usize = null;
    var consumed: ?usize = null;
    var frame: ?usize = null;
    var even: ?usize = null;
    var closed: ?usize = null;
    for (w.points[0..w.used], 0..) |p, i| {
        if (p.edge != .after) continue;
        switch (p.site) {
            .service_job_queued => {
                if (p.value != @intFromEnum(@TypeOf(w.read.state(0)).queued)) return error.JobMismatch;
                if (queued != null or p.role != .control or p.index != 0) return error.InvalidOrder;
                if (p.generation != w.job) return error.JobMismatch;
                queued = i;
            },
            .service_worker_running => {
                if (p.value != @intFromEnum(@TypeOf(w.read.state(0)).running)) return error.JobMismatch;
                if (running != null or p.role != .worker or p.index != 0) return error.InvalidOrder;
                if (p.generation != w.job) return error.JobMismatch;
                running = i;
            },
            .service_worker_completed => {
                if (p.value != @intFromEnum(@TypeOf(w.read.state(0)).completed)) return error.JobMismatch;
                if (completed != null or p.role != .worker or p.index != 0) return error.InvalidOrder;
                if (p.generation != w.job) return error.JobMismatch;
                completed = i;
            },
            .service_job_free => {
                if (p.value != @intFromEnum(@TypeOf(w.read.state(0)).free)) return error.JobMismatch;
                if (freed != null or p.role != .control or p.index != 0) return error.InvalidOrder;
                if (p.generation != w.job) return error.JobMismatch;
                freed = i;
            },
            .service_slot_guard_render_claim => {
                if (guard != null or p.role != .render or p.index != 0) return error.InvalidOrder;
                if (p.value != 0 or p.index != w.handle.index) return error.GuardMismatch;
                guard = i;
            },
            .service_render_consumed => {
                if (consumed != null or p.role != .render or p.index != 0) return error.InvalidOrder;
                if (p.generation != w.handle.generation or p.value != 1) return error.GenerationMismatch;
                consumed = i;
            },
            .service_slot_guard_render_release => {
                if (released != null or p.role != .render or p.index != 0) return error.InvalidOrder;
                if (p.generation != w.handle.generation or p.value != 0) return error.GenerationMismatch;
                released = i;
            },
            .service_stream_observation_frame => {
                if (frame != null or p.role != .render or p.index != 0) return error.InvalidOrder;
                if (p.value != 1) return error.ObservationMismatch;
                frame = i;
            },
            .service_render_sequence_even => {
                if (even != null or p.role != .render or p.index != 0) return error.InvalidOrder;
                if (p.value != 2) return error.ObservationMismatch;
                even = i;
            },
            .service_slot_guard_close => {
                if (closed != null or p.role != .control or p.index != 0) return error.InvalidOrder;
                if (p.generation != w.handle.generation or p.value != 0) return error.GenerationMismatch;
                closed = i;
            },
            else => {},
        }
    }
    var worker_selected: usize = 0;
    var acceptance_selected: usize = 0;
    var prefix_before: usize = 0;
    var prefix_after: usize = 0;
    for (w.boundaries[0..w.boundary_used]) |b| switch (b.site) {
        .service_worker_selected, .service_acceptance_selected => {
            if (b.index != 0 or b.generation != w.job or b.edge != .after or b.value != null) return error.JobMismatch;
            if (b.site == .service_worker_selected) {
                if (b.role != .worker) return error.JobMismatch;
                worker_selected += 1;
            } else {
                if (b.role != .control) return error.JobMismatch;
                acceptance_selected += 1;
            }
        },
        .service_render_consumed_prefix => {
            if (b.role != .render or b.index != 1 or b.generation != 1 or b.value != null) return error.GenerationMismatch;
            if (b.edge == .before) prefix_before += 1 else prefix_after += 1;
        },
        else => {},
    };
    if (worker_selected != 1 or acceptance_selected != 1 or prefix_before != 1 or prefix_after != 1) return error.IncompleteWitness;
    const q = queued orelse return error.IncompleteWitness;
    const r = running orelse return error.IncompleteWitness;
    const c = completed orelse return error.IncompleteWitness;
    const free = freed orelse return error.IncompleteWitness;
    const g = guard orelse return error.IncompleteWitness;
    const co = consumed orelse return error.IncompleteWitness;
    const re = released orelse return error.IncompleteWitness;
    const fr = frame orelse return error.IncompleteWitness;
    const ev = even orelse return error.IncompleteWitness;
    const cl = closed orelse return error.IncompleteWitness;
    if (!(q < r and r < c and c < free and free < g and g < co and co < re and re < fr and fr < ev and ev < cl)) return error.InvalidOrder;
    // Bind semantic events to the API operation that actually emitted them.
    const bindings = [_]struct { event: usize, op: Op }{
        .{ .event = q, .op = .request },  .{ .event = r, .op = .worker },
        .{ .event = c, .op = .worker },   .{ .event = free, .op = .accept },
        .{ .event = g, .op = .publish },  .{ .event = co, .op = .publish },
        .{ .event = re, .op = .publish }, .{ .event = fr, .op = .publish },
        .{ .event = ev, .op = .publish }, .{ .event = cl, .op = .close },
    };
    for (bindings) |binding| {
        const step = w.steps[position[@intFromEnum(binding.op)]];
        if (binding.event < step.first or binding.event >= step.end) return error.InvalidOrder;
    }
    return plan;
}
fn run(bytes: []const u8, plan: Plan, expected: ?*const Witness, out: *Witness) !void {
    var loaded = try f.bank.MusicBank.load(a, bytes);
    defer loaded.deinit();
    const sound = loaded.tables.sounds[0];
    var source: Source = .{ .bytes = loaded.tables.blob[@intCast(sound.blob_offset)..][0..@intCast(sound.blob_length)] };
    const service = try stream.Service.create(a, .{ .max_streams = 1, .max_channels = 2, .job_capacity = 1, .completion_capacity = 1, .max_encoded_chunk_bytes = 65536 });
    defer service.destroy() catch @panic("bridge service retained");
    var recorder: Recorder = .{ .actual = out, .expected = expected };
    const hooks: stream.LiveSemanticHooks = .{ .cuts = .{ .context = &recorder, .point = Recorder.point, .boundary = Recorder.boundary } };
    try service.attachLiveSemanticQuiescent(hooks);
    defer service.detachLiveSemanticQuiescent(hooks) catch @panic("bridge hooks retained");
    service.test_worker_clock_hook = .{ .context = &recorder, .observe = Recorder.clockObserve, .replay = if (expected != null) Recorder.rawClock else null };
    defer service.test_worker_clock_hook = null;
    var asset = try service.prepareAsset(.{ .sound_index = 0, .sound = sound, .codec = loaded.tables.codecs[sound.codec], .chunks = loaded.tables.chunks[sound.chunks.first..][0..sound.chunks.count], .seeks = loaded.tables.seeks[sound.seeks.first..][0..sound.seeks.count], .source = .{ .context = &source, .length = source.bytes.len, .read_at = Source.read } });
    defer asset.retire();
    out.handle = try service.open(&asset, .{ .generation = 1, .transport_epoch = 1, .group = 1, .layer = 1 });
    var is_open = true;
    defer if (is_open) service.close(out.handle) catch @panic("bridge stream retained");
    try service.attachRuntime();
    defer service.detachRuntimeQuiescent() catch @panic("bridge runtime retained");
    for (plan.ops, 0..) |op, index| {
        const start = out.used;
        switch (op) {
            .request => out.job = (try service.request(out.handle)) orelse return error.MissingJob,
            .worker => {
                if ((try service.workerOne()) != out.job) return error.JobMismatch;
            },
            .accept => {
                var attempt: stream.LiveAcceptanceAttemptV1 = undefined;
                const accepted = (try service.acceptCompletedLiveV1(.{ .accepted_control_frame = 0, .control_tick = 1, .input_order = 1 }, 1, &attempt)) orelse return error.MissingCompletion;
                out.worker_input = accepted.input;
            },
            .admit => {
                const value = (try service.admitPublication(service.publicationFrontier(), 1, 0, 1)) orelse return error.MissingAdmission;
                if (value.disposition != .admitted) return error.Rejected;
            },
            .ack => {
                if (service.pollVisibility() == null) return error.MissingAcknowledgement;
            },
            .consume => {
                const pcm = try service.ringFor(out.handle);
                out.channels = pcm.channels;
                out.consumed_before = pcm.consumed.load(.acquire);
                if (!pcm.peek(0, 0, out.pcm[0..out.channels])) return error.Unready;
                pcm.consume();
                out.consumed_after = pcm.consumed.load(.acquire);
            },
            .publish => service.endRenderSpan(plan.publish_frame),
            .query => {
                var deferred: ?stream.LiveObservationDeferV1 = null;
                out.input = try service.readinessLiveObservedV1(out.handle, .{ .accepted_control_frame = 1, .control_tick = 2, .input_order = 1 }, 1, 1, &out.read, .{}, &deferred);
                if (deferred != null) return error.UnexpectedDefer;
            },
            .close => {
                try service.cancel(out.handle);
                try service.close(out.handle);
                is_open = false;
                out.closed = true;
            },
        }
        out.steps[index] = .{ .op = op, .first = start, .end = out.used };
    }
    if (out.overflow) return error.CaptureOverflow;
    if (expected) |e| {
        if (recorder.mismatch or recorder.clock_cursor != e.clocks_used or out.used != e.used or out.boundary_used != e.boundary_used or out.clocks_used != e.clocks_used) return error.ReplayMismatch;
        if (!std.meta.eql(out.read, e.read) or !std.meta.eql(out.input, e.input) or !std.meta.eql(out.worker_input, e.worker_input) or !std.meta.eql(out.steps, e.steps) or !std.meta.eql(out.clocks, e.clocks) or !std.meta.eql(out.pcm, e.pcm) or out.channels != e.channels or !std.meta.eql(out.handle, e.handle) or out.job != e.job or out.consumed_before != e.consumed_before or out.consumed_after != e.consumed_after or !out.closed) return error.ReplayMismatch;
    }
}
test "finite joint witness freezes plan before fresh Service and rejects cycles altered values and EOF" {
    const source = try std.mem.replaceOwned(u8, a, f.authored_source, "max_chunk_bytes=262144", "max_chunk_bytes=65536");
    defer a.free(source);
    const bytes = try f.buildSource(.a, source, null);
    defer a.free(bytes);
    const recorded = try a.create(Witness);
    defer a.destroy(recorded);
    recorded.* = .{};
    try run(bytes, canonical, null, recorded);
    const frozen = try check(recorded, null);
    try t.expectEqualDeep(canonical, frozen);
    // No Service exists while preflight rejects a cross-domain cycle or bad evidence.
    try t.expectError(error.JointCycle, check(recorded, .{ .from = .query, .to = .publish }));
    const bad = try a.create(Witness);
    defer a.destroy(bad);
    bad.* = recorded.*;
    bad.read.consumed = 2;
    try t.expectError(error.ObservationMismatch, check(bad, null));
    bad.* = recorded.*;
    bad.read.frame = 99;
    try t.expectError(error.ObservationMismatch, check(bad, null));
    bad.* = recorded.*;
    bad.job += 1;
    try t.expectError(error.ClockMismatch, check(bad, null));
    bad.* = recorded.*;
    bad.worker_input.?.payload.worker.job += 1;
    try t.expectError(error.JobMismatch, check(bad, null));
    bad.* = recorded.*;
    bad.handle.generation += 1;
    try t.expectError(error.InvalidOrder, check(bad, null));
    bad.* = recorded.*;
    bad.clocks[1].stage = .begin;
    try t.expectError(error.ClockMismatch, check(bad, null));
    bad.* = recorded.*;
    bad.clocks_used = 1;
    try t.expectError(error.IncompleteWitness, check(bad, null));
    bad.* = recorded.*;
    bad.closed = false;
    try t.expectError(error.IncompleteWitness, check(bad, null));
    bad.* = recorded.*;
    std.mem.swap(Step, &bad.steps[1], &bad.steps[2]);
    try t.expectError(error.InvalidOrder, check(bad, null));
    bad.* = recorded.*;
    bad.steps[n - 1].end -= 1;
    try t.expectError(error.InvalidOrder, check(bad, null));
    bad.* = recorded.*;
    for (bad.points[0..bad.used]) |*point| {
        if (point.site == .service_job_free and point.edge == .after) {
            point.generation += 1;
            break;
        }
    }
    try t.expectError(error.JobMismatch, check(bad, null));
    bad.* = recorded.*;
    for (bad.points[0..bad.used]) |*point| {
        if (point.site == .service_render_consumed and point.edge == .after) {
            point.role = .control;
            break;
        }
    }
    try t.expectError(error.InvalidOrder, check(bad, null));
    const fresh = try a.create(Witness);
    defer a.destroy(fresh);
    fresh.* = .{};
    try run(bytes, frozen, recorded, fresh);
    _ = try check(fresh, null);
    // Corrupt comparison-only recorded read AFTER freezing. Fresh actual load
    // and all operations still execute; no check/solver reselection on failure.
    bad.* = recorded.*;
    bad.read.frame = 99;
    fresh.* = .{};
    try t.expectError(error.ReplayMismatch, run(bytes, frozen, bad, fresh));
    try t.expectEqual(@as(u64, 1), fresh.read.frame);
    try t.expect(fresh.closed);
    // Truncated raw input cannot fall back to native time or hide extra draws.
    bad.* = recorded.*;
    bad.clocks_used = 1;
    fresh.* = .{};
    try t.expectError(error.ReplayMismatch, run(bytes, frozen, bad, fresh));
    try t.expectEqual(@as(usize, 2), fresh.clocks_used);
    try t.expect(!fresh.clocks[1].sample.available);
    try t.expect(fresh.closed);
}
