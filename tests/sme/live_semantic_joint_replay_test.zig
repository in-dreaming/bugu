//! Synthetic point-only Driver regression with three real actor threads and
//! independently executed atomics. NOT a Service/Host qualification. Tape is
//! comparison/scheduling evidence; actor loads never receive expected results.
const std = @import("std");
const live = @import("sme-author-live-owner");
const codec = live.semantic_recording.codec;
const f = codec.format;
const Regression = live.semantic_replay.JointObservationRegression;
const Driver = live.semantic_replay.Driver;
const t = std.testing;
fn identity() f.Identity {
    return .{ .build = @splat(1), .bank = @splat(2), .config = @splat(3), .source = @splat(4) };
}
fn point(role: codec.cuts.Role, site: codec.cuts.Site, edge: codec.cuts.Edge, value: ?u64) codec.cuts.Point {
    const generation: u64 = switch (site) {
        .service_job_queued, .service_worker_running, .service_worker_completed, .service_job_free, .service_stream_close_claim => 1,
        else => 0,
    };
    return .{ .role = role, .site = site, .edge = edge, .index = 0, .generation = generation, .value = value };
}
const Tape = struct {
    writer: f.Writer,
    occurrence: u64 = 0,
    ordinals: [f.role_count]u64 = @splat(0),
    scratch: [512]u8 = undefined,

    fn appendInput(self: *Tape, role: f.Role, family: codec.Family, value: anytype) !void {
        const r = @intFromEnum(role);
        self.ordinals[r] += 1;
        try self.writer.append(role, self.ordinals[r], @intFromEnum(family), .input, try codec.encode(value, .input, &self.scratch));
    }
    fn appendPoint(self: *Tape, raw: codec.cuts.Point) !void {
        self.occurrence += 1;
        const role = codec.wireRole(raw.role);
        const marker: codec.Native(codec.EventCut) = .{
            .occurrence = self.occurrence,
            .value = .{ .family = .cut_fact, .tag = codec.eventTag(raw) },
        };
        try self.appendInput(role, .event_cut, marker);
        const coordinate: codec.Native(codec.Cut) = .{
            .occurrence = self.occurrence,
            .value = .{
                .role = role,
                .site = raw.site,
                .edge = raw.edge,
                .index = raw.index,
                .generation = raw.generation,
                .job_scan_eligible = try codec.jobObservedEligibility(raw),
                .publication_prefix = if (codec.publicationPrefixPoint(role, raw.site, raw.edge)) raw.value.? else 0,
            },
        };
        try self.appendInput(role, .cut, coordinate);
        if (codec.exclusionClaim(role, raw.site) and raw.edge == .after)
            try self.appendInput(role, .exclusion_claim, @as(codec.Native(bool), .{ .occurrence = self.occurrence, .value = raw.value.? == 0 }));

        // Match production comparison encoding, including the acceptance
        // predicate normalization: raw running=2 -> false=0, completed=3 ->
        // true=1. Direct codec.encode(raw Point) would be an invalid oracle.
        const native: codec.Native(codec.cuts.Point) = .{ .occurrence = self.occurrence, .value = raw };
        const bytes = std.mem.asBytes(&native);
        const r = @intFromEnum(role);
        self.ordinals[r] += 1;
        const reference = try codec.encodeNative(.{
            .role = role,
            .ordinal = self.ordinals[r],
            .family = @intFromEnum(codec.Family.cut_fact),
            .class = .reference,
            .bytes = bytes,
            .first_len = bytes.len,
        }, &self.scratch);
        try self.writer.append(role, self.ordinals[r], @intFromEnum(codec.Family.cut_fact), .reference, reference);
    }
    fn finish(self: *Tape) ![]const u8 {
        return self.writer.sealFraming(.{ .healthy = true, .closed_roles = @splat(true), .role_counts = self.ordinals });
    }
};
fn makeTape(out: []u8) ![]const u8 {
    var tape: Tape = .{ .writer = try f.Writer.init(out, identity(), codec.validate) };
    const points = [_]codec.cuts.Point{
        point(.worker, .service_worker_claim, .before, null),            point(.worker, .service_worker_claim, .after, 0),
        point(.worker, .service_worker_scan, .before, null),             point(.control, .service_job_queued, .before, 1),
        point(.render, .service_render_sequence_odd, .before, null),     point(.render, .service_render_sequence_odd, .after, 1),
        point(.control, .service_job_queued, .after, 1),                 point(.control, .service_stream_close_claim, .before, null),
        point(.control, .service_stream_close_claim, .after, 1),         point(.worker, .service_worker_scan, .after, 1),
        point(.worker, .service_worker_running, .before, 2),             point(.worker, .service_worker_running, .after, 2),
        point(.render, .service_stream_observation_frame, .before, 256), point(.render, .service_stream_observation_frame, .after, 256),
        point(.control, .service_readiness_sequence, .before, null),     point(.control, .service_readiness_sequence, .after, 1),
        point(.worker, .service_worker_completed, .before, 3),           point(.worker, .service_worker_completed, .after, 3),
        point(.worker, .service_worker_idle, .before, 0),                point(.worker, .service_worker_idle, .after, 0),
        point(.control, .service_job_free, .before, 0),                  point(.control, .service_job_free, .after, 0),
        point(.render, .service_render_sequence_even, .before, null),    point(.render, .service_render_sequence_even, .after, 2),
        point(.control, .runtime_control_collect_frame, .before, null),  point(.render, .runtime_render_frame, .before, 256),
        point(.render, .runtime_render_frame, .after, 256),              point(.control, .runtime_control_collect_frame, .after, 0),
        point(.control, .service_readiness_frame, .before, null),        point(.control, .service_readiness_frame, .after, 256),
    };
    for (points) |p| try tape.appendPoint(p);
    return tape.finish();
}
const Actors = struct {
    driver: *Driver,
    job: std.atomic.Value(u64) = .init(0),
    busy: std.atomic.Value(bool) = .init(false),
    sequence: std.atomic.Value(u64) = .init(0),
    frame: std.atomic.Value(u64) = .init(0),
    runtime_frame: std.atomic.Value(u64) = .init(0),
    worker_observed: std.atomic.Value(u64) = .init(99),
    sequence_observed: std.atomic.Value(u64) = .init(99),
    frame_observed: std.atomic.Value(u64) = .init(99),
    runtime_observed: std.atomic.Value(u64) = .init(99),
    close_failed: std.atomic.Value(bool) = .init(false),
    done: [3]std.atomic.Value(bool) = .{ .init(false), .init(false), .init(false) },
    fn emit(self: *Actors, role: codec.cuts.Role, site: codec.cuts.Site, edge: codec.cuts.Edge, value: ?u64) bool {
        Regression.point(self.driver, point(role, site, edge, value));
        return !Regression.progress(self.driver).failed;
    }
    fn store(self: *Actors, role: codec.cuts.Role, site: codec.cuts.Site, cell: *std.atomic.Value(u64), value: u64) bool {
        if (!self.emit(role, site, .before, value)) return false;
        cell.store(value, .release);
        return self.emit(role, site, .after, value);
    }
    fn read(self: *Actors, site: codec.cuts.Site, cell: *std.atomic.Value(u64), result: *std.atomic.Value(u64)) bool {
        if (!self.emit(.control, site, .before, null)) return false;
        const actual = cell.load(.acquire);
        result.store(actual, .release);
        return self.emit(.control, site, .after, actual);
    }
    fn control(self: *Actors) void {
        defer self.done[0].store(true, .release);
        if (!self.store(.control, .service_job_queued, &self.job, 1)) return;
        if (!self.emit(.control, .service_stream_close_claim, .before, null)) return;
        const previous = self.busy.swap(true, .acq_rel);
        self.close_failed.store(previous, .release);
        // An unexpectedly successful synthetic claim owns a real cell lease.
        defer if (!previous) self.busy.store(false, .release);
        if (!self.emit(.control, .service_stream_close_claim, .after, @intFromBool(previous))) return;
        if (!self.read(.service_readiness_sequence, &self.sequence, &self.sequence_observed)) return;
        if (!self.store(.control, .service_job_free, &self.job, 0)) return;
        if (!self.read(.runtime_control_collect_frame, &self.runtime_frame, &self.runtime_observed)) return;
        _ = self.read(.service_readiness_frame, &self.frame, &self.frame_observed);
    }
    fn worker(self: *Actors) void {
        defer self.done[1].store(true, .release);
        if (!self.emit(.worker, .service_worker_claim, .before, null)) return;
        const previous = self.busy.swap(true, .acq_rel);
        defer if (!previous) self.busy.store(false, .release);
        if (!self.emit(.worker, .service_worker_claim, .after, @intFromBool(previous))) return;
        if (!self.emit(.worker, .service_worker_scan, .before, null)) return;
        const actual = self.job.load(.acquire);
        self.worker_observed.store(actual, .release);
        if (!self.emit(.worker, .service_worker_scan, .after, actual)) return;
        if (!self.store(.worker, .service_worker_running, &self.job, 2)) return;
        if (!self.store(.worker, .service_worker_completed, &self.job, 3)) return;
        if (!self.emit(.worker, .service_worker_idle, .before, 0)) return;
        self.busy.store(false, .release);
        _ = self.emit(.worker, .service_worker_idle, .after, 0);
    }
    fn publishSequence(self: *Actors, site: codec.cuts.Site) bool {
        if (!self.emit(.render, site, .before, null)) return false;
        const actual = self.sequence.fetchAdd(1, .acq_rel) + 1;
        return self.emit(.render, site, .after, actual);
    }
    fn render(self: *Actors) void {
        defer self.done[2].store(true, .release);
        if (!self.publishSequence(.service_render_sequence_odd)) return;
        if (!self.store(.render, .service_stream_observation_frame, &self.frame, 256)) return;
        if (!self.publishSequence(.service_render_sequence_even)) return;
        _ = self.store(.render, .runtime_render_frame, &self.runtime_frame, 256);
    }
};
const Deadline = struct {
    start: @TypeOf(std.Io.Clock.awake.now(t.io)),
    fn begin() Deadline {
        return .{ .start = std.Io.Clock.awake.now(t.io) };
    }
    fn check(self: Deadline) !void {
        if (self.start.durationTo(std.Io.Clock.awake.now(t.io)).nanoseconds >= 5 * std.time.ns_per_s) return error.TestDeadlineExceeded;
    }
};
fn pause() !void {
    try std.Io.sleep(t.io, .fromNanoseconds(50_000), .awake);
}
const Threads = struct {
    actors: *Actors,
    threads: [3]?std.Thread = .{ null, null, null },
    fn start(self: *Threads, r: usize) !void {
        self.threads[r] = switch (r) {
            0 => std.Thread.spawn(.{}, Actors.control, .{self.actors}),
            1 => std.Thread.spawn(.{}, Actors.worker, .{self.actors}),
            2 => std.Thread.spawn(.{}, Actors.render, .{self.actors}),
            else => unreachable,
        } catch |err| {
            Regression.cancel(self.actors.driver);
            return err;
        };
    }
    fn join(self: *Threads) void {
        for (&self.threads) |*handle| if (handle.*) |thread| {
            thread.join();
            handle.* = null;
        };
    }
    fn cleanup(self: *Threads) void {
        for (self.threads) |handle| if (handle != null) {
            Regression.cancel(self.actors.driver);
            break;
        };
        self.join();
    }
    fn waitAndJoin(self: *Threads, deadline: Deadline) !void {
        while (true) {
            try deadline.check();
            var all = true;
            for (self.threads, 0..) |handle, r| if (handle != null and !self.actors.done[r].load(.acquire)) {
                all = false;
            };
            if (all) break;
            try pause();
        }
        self.join();
        try deadline.check();
    }
};
fn allocate(reader: *const f.Reader) !*Driver {
    const driver = try t.allocator.create(Driver);
    errdefer t.allocator.destroy(driver);
    driver.* = .{};
    try Regression.initialize(driver, reader);
    return driver;
}
test "joint three-actor actual atomics cross held busy joint reads and runtime publication calendars" {
    var bytes: [32768]u8 = undefined;
    const reader = try f.Reader.preflight(try makeTape(&bytes), identity(), codec.validate);
    const driver = try allocate(&reader);
    defer t.allocator.destroy(driver);
    var actors: Actors = .{ .driver = driver };
    var threads: Threads = .{ .actors = &actors };
    defer threads.cleanup();
    const deadline = Deadline.begin();
    try threads.start(1);
    try threads.start(0);
    try threads.start(2);
    try threads.waitAndJoin(deadline);
    const progress = Regression.progress(driver);
    try t.expect(!progress.failed);
    try t.expectEqual(@as(u64, 31), progress.marker);
    try t.expectEqual(@as(u64, 10), progress.joint_completed);
    try t.expectEqual(@as(u64, 0), actors.job.load(.acquire));
    try t.expect(!actors.busy.load(.acquire));
    try t.expectEqual(@as(u64, 2), actors.sequence.load(.acquire));
    try t.expectEqual(@as(u64, 256), actors.frame.load(.acquire));
    try t.expectEqual(@as(u64, 256), actors.runtime_frame.load(.acquire));
    try t.expectEqual(@as(u64, 1), actors.worker_observed.load(.acquire));
    try t.expect(actors.close_failed.load(.acquire));
    try t.expectEqual(@as(u64, 1), actors.sequence_observed.load(.acquire));
    try t.expectEqual(@as(u64, 256), actors.frame_observed.load(.acquire));
    try t.expectEqual(@as(u64, 0), actors.runtime_observed.load(.acquire));
    try Regression.finish(driver); // Every INPUT/reference role EOF, all calendars.
}
test "joint cancellation releases genuinely blocked Worker and its held synthetic busy lease" {
    var bytes: [32768]u8 = undefined;
    const reader = try f.Reader.preflight(try makeTape(&bytes), identity(), codec.validate);
    const driver = try allocate(&reader);
    defer t.allocator.destroy(driver);
    var actors: Actors = .{ .driver = driver };
    var threads: Threads = .{ .actors = &actors };
    defer threads.cleanup();
    const deadline = Deadline.begin();
    try threads.start(1);
    while (true) {
        try deadline.check();
        const progress = Regression.progress(driver);
        if (progress.failed) return error.UnexpectedReplayFailure;
        if (progress.marker == 4) break;
        if (progress.marker > 4 or actors.done[1].load(.acquire)) return error.UnexpectedWorkerProgress;
        try pause();
    }
    try t.expect(actors.busy.load(.acquire));
    try t.expectEqual(@as(u64, 0), Regression.progress(driver).joint_completed);
    try t.expectEqual(@as(u64, 99), actors.worker_observed.load(.acquire));
    Regression.cancel(driver);
    try threads.waitAndJoin(deadline);
    try t.expect(Regression.progress(driver).failed);
    try t.expect(!actors.busy.load(.acquire));
    try t.expect(actors.done[1].load(.acquire));
    try t.expect(!actors.done[0].load(.acquire) and !actors.done[2].load(.acquire));
    try t.expectEqual(@as(u64, 0), actors.job.load(.acquire));
    if (Regression.finish(driver)) |_| return error.UnexpectedSuccessProof else |_| {}
}

test "joint actual runtime scalar fault rejects without substituting the recorded read" {
    var bytes: [32768]u8 = undefined;
    const reader = try f.Reader.preflight(try makeTape(&bytes), identity(), codec.validate);
    const driver = try allocate(&reader);
    defer t.allocator.destroy(driver);
    var actors: Actors = .{ .driver = driver };
    // Deliberate corruption of this synthetic fixture's own actual state,
    // outside Driver. The unchanged frozen tape still expects initial zero.
    actors.runtime_frame.store(99, .release);
    var threads: Threads = .{ .actors = &actors };
    defer threads.cleanup();
    const deadline = Deadline.begin();
    try threads.start(1);
    try threads.start(0);
    try threads.start(2);
    try threads.waitAndJoin(deadline);
    try t.expect(Regression.progress(driver).failed);
    try t.expectEqual(@as(u64, 99), actors.runtime_observed.load(.acquire));
    try t.expect(!actors.busy.load(.acquire));
    try t.expectEqual(@as(u64, 0), actors.job.load(.acquire));
    if (Regression.finish(driver)) |_| return error.UnexpectedSuccessProof else |_| {}
}

fn streamPoint(role: codec.cuts.Role, site: codec.cuts.Site, edge: codec.cuts.Edge, generation: u64, value: ?u64) codec.cuts.Point {
    var p = point(role, site, edge, value);
    p.generation = generation;
    return p;
}
fn makeStreamTape(out: []u8) ![]const u8 {
    var tape: Tape = .{ .writer = try f.Writer.init(out, identity(), codec.validate) };
    const points = [_]codec.cuts.Point{
        streamPoint(.control, .service_slot_guard_open, .before, 1, 0),           streamPoint(.control, .service_slot_guard_open, .after, 1, 0),
        streamPoint(.render, .service_render_sequence_odd, .before, 0, null),     streamPoint(.render, .service_render_sequence_odd, .after, 0, 1),
        streamPoint(.render, .service_slot_guard_render_claim, .before, 0, null), streamPoint(.render, .service_slot_guard_render_claim, .after, 0, 0),
        streamPoint(.render, .service_render_consumed, .before, 1, 4),            streamPoint(.control, .service_readiness_consumed, .before, 1, null),
        streamPoint(.render, .service_render_consumed, .after, 1, 4),             streamPoint(.control, .service_readiness_consumed, .after, 1, 0),
        streamPoint(.control, .service_slot_guard_close, .before, 1, null),       streamPoint(.control, .service_slot_guard_close, .after, 1, 1),
        streamPoint(.render, .service_slot_guard_render_release, .before, 1, 0),  streamPoint(.control, .service_slot_guard_close, .before, 1, null),
        streamPoint(.control, .service_slot_guard_close, .after, 1, 0),           streamPoint(.control, .service_slot_guard_open, .before, 2, 0),
        streamPoint(.control, .service_slot_guard_open, .after, 2, 0),            streamPoint(.render, .service_slot_guard_render_release, .after, 1, 0),
        streamPoint(.render, .service_stream_observation_frame, .before, 0, 256), streamPoint(.render, .service_stream_observation_frame, .after, 0, 256),
        streamPoint(.render, .service_render_sequence_even, .before, 0, null),    streamPoint(.render, .service_render_sequence_even, .after, 0, 2),
        streamPoint(.control, .service_readiness_consumed, .before, 2, null),     streamPoint(.control, .service_readiness_consumed, .after, 2, 0),
        streamPoint(.control, .service_slot_guard_close, .before, 2, null),       streamPoint(.control, .service_slot_guard_close, .after, 2, 0),
    };
    for (points) |p| try tape.appendPoint(p);
    return tape.finish();
}
// These cells model only atomic composition. No claim of source Service close
// prerequisites, descriptor custody, Ring DSP or native Host qualification.
const StreamActors = struct {
    driver: *Driver,
    guard: std.atomic.Value(u8) = .init(2),
    generation: std.atomic.Value(u64) = .init(0),
    consumed: std.atomic.Value(u64) = .init(0),
    raw_consumed: std.atomic.Value(u64) = .init(4),
    sequence: std.atomic.Value(u64) = .init(0),
    frame: std.atomic.Value(u64) = .init(0),
    observed_old: std.atomic.Value(u64) = .init(99),
    observed_new: std.atomic.Value(u64) = .init(99),
    published: std.atomic.Value(u64) = .init(99),
    claim_observed: std.atomic.Value(u8) = .init(99),
    failed_close: std.atomic.Value(u8) = .init(99),
    held: std.atomic.Value(bool) = .init(false),
    fault_consumed: bool = false,
    pause_control: bool = false,
    allow_control: std.atomic.Value(bool) = .init(false),
    done: [2]std.atomic.Value(bool) = .{ .init(false), .init(false) },
    fn emit(self: *StreamActors, role: codec.cuts.Role, site: codec.cuts.Site, edge: codec.cuts.Edge, gen: u64, value: ?u64) bool {
        Regression.point(self.driver, streamPoint(role, site, edge, gen, value));
        return !Regression.progress(self.driver).failed;
    }
    fn open(self: *StreamActors, gen: u64) bool {
        // Real source initializes while closed, then publishes guard0.
        self.consumed.store(0, .release);
        self.generation.store(gen, .release);
        if (!self.emit(.control, .service_slot_guard_open, .before, gen, 0)) return false;
        self.guard.store(0, .release);
        return self.emit(.control, .service_slot_guard_open, .after, gen, 0);
    }
    fn read(self: *StreamActors, gen: u64, result: *std.atomic.Value(u64)) bool {
        if (!self.emit(.control, .service_readiness_consumed, .before, gen, null)) return false;
        const actual = self.consumed.load(.acquire);
        result.store(actual, .release);
        return self.emit(.control, .service_readiness_consumed, .after, gen, actual);
    }
    fn close(self: *StreamActors, gen: u64, save: bool) bool {
        if (!self.emit(.control, .service_slot_guard_close, .before, gen, null)) return false;
        const actual = self.guard.cmpxchgStrong(0, 2, .acq_rel, .acquire) orelse 0;
        if (save) self.failed_close.store(actual, .release);
        return self.emit(.control, .service_slot_guard_close, .after, gen, actual);
    }
    fn control(self: *StreamActors) void {
        defer self.done[0].store(true, .release);
        if (!self.open(1)) return;
        if (self.fault_consumed) self.consumed.store(99, .release); // synthetic fault, not Driver output
        while (self.pause_control and !self.allow_control.load(.acquire)) {
            if (Regression.progress(self.driver).failed) return;
            pause() catch {
                Regression.cancel(self.driver);
                return;
            };
        }
        if (!self.read(1, &self.observed_old)) return;
        if (!self.close(1, true)) return;
        if (!self.close(1, false)) return;
        if (!self.open(2)) return;
        if (!self.read(2, &self.observed_new)) return;
        _ = self.close(2, false);
    }
    fn increment(self: *StreamActors, site: codec.cuts.Site) bool {
        if (!self.emit(.render, site, .before, 0, null)) return false;
        const actual = self.sequence.fetchAdd(1, .acq_rel) + 1;
        return self.emit(.render, site, .after, 0, actual);
    }
    fn render(self: *StreamActors) void {
        defer self.done[1].store(true, .release);
        defer if (self.held.swap(false, .acq_rel)) self.guard.store(0, .release);
        if (!self.increment(.service_render_sequence_odd)) return;
        if (!self.emit(.render, .service_slot_guard_render_claim, .before, 0, null)) return;
        const actual = self.guard.cmpxchgStrong(0, 1, .acquire, .monotonic) orelse 0;
        self.claim_observed.store(actual, .release);
        if (actual == 0) self.held.store(true, .release);
        if (!self.emit(.render, .service_slot_guard_render_claim, .after, 0, actual)) return;
        if (actual != 0) return;
        const owned_generation = self.generation.load(.acquire);
        const sampled = self.raw_consumed.load(.monotonic); // before publication bracket, as source
        if (!self.emit(.render, .service_render_consumed, .before, owned_generation, sampled)) return;
        self.consumed.store(sampled, .release);
        self.published.store(sampled, .release);
        if (!self.emit(.render, .service_render_consumed, .after, owned_generation, sampled)) return;
        if (!self.emit(.render, .service_slot_guard_render_release, .before, owned_generation, 0)) return;
        self.guard.store(0, .release);
        self.held.store(false, .release);
        // No descriptor reload: Control may already close/reopen before AFTER.
        if (!self.emit(.render, .service_slot_guard_render_release, .after, owned_generation, 0)) return;
        if (!self.emit(.render, .service_stream_observation_frame, .before, 0, 256)) return;
        self.frame.store(256, .release);
        if (!self.emit(.render, .service_stream_observation_frame, .after, 0, 256)) return;
        _ = self.increment(.service_render_sequence_even);
    }
};
const StreamThreads = struct {
    actors: *StreamActors,
    handles: [2]?std.Thread = .{ null, null },
    fn start(self: *StreamThreads, r: usize) !void {
        self.handles[r] = (if (r == 0) std.Thread.spawn(.{}, StreamActors.control, .{self.actors}) else std.Thread.spawn(.{}, StreamActors.render, .{self.actors})) catch |err| {
            Regression.cancel(self.actors.driver);
            return err;
        };
    }
    fn join(self: *StreamThreads) void {
        for (&self.handles) |*h| if (h.*) |thread| {
            thread.join();
            h.* = null;
        };
    }
    fn cleanup(self: *StreamThreads) void {
        for (self.handles) |h| if (h != null) {
            Regression.cancel(self.actors.driver);
            break;
        };
        self.join();
    }
    fn wait(self: *StreamThreads, d: Deadline) !void {
        while (true) {
            try d.check();
            var all = true;
            for (self.handles, 0..) |h, r| if (h != null and !self.actors.done[r].load(.acquire)) {
                all = false;
            };
            if (all) break;
            try pause();
        }
        self.join();
        try d.check();
    }
};
fn allocateStreams(reader: *const f.Reader) !*Driver {
    const driver = try t.allocator.create(Driver);
    errdefer t.allocator.destroy(driver);
    driver.* = .{};
    try Regression.initializeStreams(driver, reader, 1);
    return driver;
}
test "stream joint actual guard consumed read and close reopen cross old release AFTER" {
    var bytes: [32768]u8 = undefined;
    const reader = try f.Reader.preflight(try makeStreamTape(&bytes), identity(), codec.validate);
    const driver = try allocateStreams(&reader);
    defer t.allocator.destroy(driver);
    var a: StreamActors = .{ .driver = driver };
    var threads: StreamThreads = .{ .actors = &a };
    defer threads.cleanup();
    const d = Deadline.begin();
    try threads.start(0);
    try threads.start(1);
    try threads.wait(d);
    try t.expect(!Regression.progress(driver).failed);
    try t.expectEqual(@as(u64, 27), Regression.progress(driver).marker);
    try t.expectEqual(@as(u64, 13), Regression.progress(driver).joint_completed);
    try t.expectEqual(@as(u64, 0), a.observed_old.load(.acquire));
    try t.expectEqual(@as(u64, 0), a.observed_new.load(.acquire));
    try t.expectEqual(@as(u64, 4), a.published.load(.acquire));
    try t.expectEqual(@as(u8, 1), a.failed_close.load(.acquire));
    try t.expectEqual(@as(u8, 2), a.guard.load(.acquire));
    try t.expectEqual(@as(u64, 2), a.generation.load(.acquire));
    try t.expectEqual(@as(u64, 2), a.sequence.load(.acquire));
    try t.expectEqual(@as(u64, 256), a.frame.load(.acquire));
    try t.expect(!a.held.load(.acquire));
    try Regression.finish(driver);
}
test "stream joint actual projection fault rejects without using expected consumed" {
    var bytes: [32768]u8 = undefined;
    const reader = try f.Reader.preflight(try makeStreamTape(&bytes), identity(), codec.validate);
    const driver = try allocateStreams(&reader);
    defer t.allocator.destroy(driver);
    var a: StreamActors = .{ .driver = driver };
    a.raw_consumed.store(5, .release);
    var threads: StreamThreads = .{ .actors = &a };
    defer threads.cleanup();
    const d = Deadline.begin();
    try threads.start(0);
    try threads.start(1);
    try threads.wait(d);
    try t.expect(Regression.progress(driver).failed);
    try t.expect(!a.held.load(.acquire));
    // Fault is visible in the original sampled argument BEFORE publication;
    // comparison may abort there, so do not claim the actual store executed.
    try t.expectEqual(@as(u64, 5), a.raw_consumed.load(.acquire));
    if (Regression.finish(driver)) |_| return error.UnexpectedSuccessProof else |_| {}
}
test "stream joint cancellation with held guard aborts all waits and genuinely joins" {
    var bytes: [32768]u8 = undefined;
    const reader = try f.Reader.preflight(try makeStreamTape(&bytes), identity(), codec.validate);
    const driver = try allocateStreams(&reader);
    defer t.allocator.destroy(driver);
    var a: StreamActors = .{ .driver = driver, .pause_control = true };
    var threads: StreamThreads = .{ .actors = &a };
    defer threads.cleanup();
    const d = Deadline.begin();
    try threads.start(0);
    try threads.start(1);
    while (true) {
        try d.check();
        const p = Regression.progress(driver);
        if (p.failed) return error.UnexpectedReplayFailure;
        if (p.marker == 8) break;
        if (p.marker > 8) return error.UnexpectedWorkerProgress;
        try pause();
    }
    try t.expect(a.held.load(.acquire));
    try t.expectEqual(@as(u8, 1), a.guard.load(.acquire));
    try t.expectEqual(@as(u64, 0), a.consumed.load(.acquire));
    Regression.cancel(driver);
    try threads.wait(d);
    try t.expect(!a.held.load(.acquire));
    try t.expect(Regression.progress(driver).failed);
    try t.expect(a.done[0].load(.acquire) and a.done[1].load(.acquire));
    if (Regression.finish(driver)) |_| return error.UnexpectedSuccessProof else |_| {}
}
test "stream joint actual failed CAS differs from frozen successful claim and rejects" {
    var bytes: [32768]u8 = undefined;
    const reader = try f.Reader.preflight(try makeStreamTape(&bytes), identity(), codec.validate);
    const driver = try allocateStreams(&reader);
    defer t.allocator.destroy(driver);
    var a: StreamActors = .{ .driver = driver, .pause_control = true };
    var threads: StreamThreads = .{ .actors = &a };
    defer threads.cleanup();
    const d = Deadline.begin();
    try threads.start(0);
    while (true) {
        try d.check();
        const p = Regression.progress(driver);
        if (p.failed) return error.UnexpectedReplayFailure;
        if (p.marker == 3) break;
        try pause();
    }
    // Deliberate fixture-only atomic corruption, never a Driver return value.
    a.guard.store(2, .release);
    try threads.start(1);
    try threads.wait(d);
    try t.expect(Regression.progress(driver).failed);
    try t.expectEqual(@as(u8, 2), a.claim_observed.load(.acquire));
    try t.expect(!a.held.load(.acquire));
    if (Regression.finish(driver)) |_| return error.UnexpectedSuccessProof else |_| {}
}

test "stream joint actual consumed load mismatch is not replaced by expected zero" {
    var bytes: [32768]u8 = undefined;
    const reader = try f.Reader.preflight(try makeStreamTape(&bytes), identity(), codec.validate);
    const driver = try allocateStreams(&reader);
    defer t.allocator.destroy(driver);
    var a: StreamActors = .{ .driver = driver, .fault_consumed = true };
    var threads: StreamThreads = .{ .actors = &a };
    defer threads.cleanup();
    const d = Deadline.begin();
    try threads.start(0);
    try threads.start(1);
    try threads.wait(d);
    try t.expect(Regression.progress(driver).failed);
    try t.expectEqual(@as(u64, 99), a.observed_old.load(.acquire));
    try t.expect(!a.held.load(.acquire));
    if (Regression.finish(driver)) |_| return error.UnexpectedSuccessProof else |_| {}
}
