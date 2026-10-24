//! New point-only regression implementation, not a recovered historical file.
//! These tapes exercise production Driver.onPoint through its test-only facade
//! with two real actor threads and one real atomic job-state cell. They do not
//! construct a Host, reproduce Service selection control flow, or establish
//! full native lifecycle qualification. No expected observation is returned to
//! an actor or installed by the Driver into the atomic cell.
const std = @import("std");
const live = @import("sme-author-live-owner");
const codec = live.semantic_recording.codec;
const f = codec.format;
const Regression = live.semantic_replay.JobObservationRegression;
const Driver = live.semantic_replay.Driver;
const t = std.testing;

const State = struct {
    const free: u8 = 0;
    const queued: u8 = 1;
    const running: u8 = 2;
    const completed: u8 = 3;
};
const Scenario = enum {
    worker_true,
    worker_false_scan_after_first,
    worker_false_queue_after_first,
    acceptance_true,
    acceptance_false,

    fn controlScan(self: Scenario) bool {
        return self == .acceptance_true or self == .acceptance_false;
    }
    /// Used only to construct independent tape evidence and assert results
    /// after genuine joins. Actor execution never receives this expected value.
    fn expectedObservation(self: Scenario) u8 {
        return switch (self) {
            .worker_true => State.queued,
            .worker_false_scan_after_first, .worker_false_queue_after_first => State.free,
            .acceptance_true => State.completed,
            .acceptance_false => State.running,
        };
    }
};

fn identity() f.Identity {
    return .{ .build = @splat(1), .bank = @splat(2), .config = @splat(3), .source = @splat(4) };
}
fn point(role: codec.cuts.Role, site: codec.cuts.Site, edge: codec.cuts.Edge, value: ?u64) codec.cuts.Point {
    const is_scan = site == .service_worker_scan or site == .service_acceptance_scan;
    return .{ .role = role, .site = site, .edge = edge, .index = 0, .generation = if (is_scan) 0 else 1, .value = value };
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
            },
        };
        try self.appendInput(role, .cut, coordinate);

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

fn makeTape(output: []u8, scenario: Scenario) ![]const u8 {
    var tape: Tape = .{ .writer = try f.Writer.init(output, identity(), codec.validate) };
    const observed = scenario.expectedObservation();
    const points: [10]codec.cuts.Point = if (scenario.controlScan()) .{
        point(.control, .service_job_queued, .before, State.queued),
        point(.control, .service_job_queued, .after, State.queued),
        point(.worker, .service_worker_running, .before, State.running),
        point(.worker, .service_worker_running, .after, State.running),
        point(.worker, .service_worker_completed, .before, State.completed),
        point(.control, .service_acceptance_scan, .before, null),
        point(.worker, .service_worker_completed, .after, State.completed),
        point(.control, .service_acceptance_scan, .after, observed),
        point(.control, .service_job_free, .before, State.free),
        point(.control, .service_job_free, .after, State.free),
    } else .{
        point(.control, .service_job_queued, .before, State.queued),
        point(.worker, .service_worker_scan, .before, null),
        if (scenario == .worker_false_scan_after_first)
            point(.worker, .service_worker_scan, .after, observed)
        else
            point(.control, .service_job_queued, .after, State.queued),
        if (scenario == .worker_false_scan_after_first)
            point(.control, .service_job_queued, .after, State.queued)
        else
            point(.worker, .service_worker_scan, .after, observed),
        point(.worker, .service_worker_running, .before, State.running),
        point(.worker, .service_worker_running, .after, State.running),
        point(.worker, .service_worker_completed, .before, State.completed),
        point(.worker, .service_worker_completed, .after, State.completed),
        point(.control, .service_job_free, .before, State.free),
        point(.control, .service_job_free, .after, State.free),
    };
    for (points) |value| try tape.appendPoint(value);
    return tape.finish();
}

const Deadline = struct {
    started: @TypeOf(std.Io.Clock.awake.now(t.io)),
    fn begin() Deadline {
        return .{ .started = std.Io.Clock.awake.now(t.io) };
    }
    fn check(self: Deadline) !void {
        if (self.started.durationTo(std.Io.Clock.awake.now(t.io)).nanoseconds >= 5 * std.time.ns_per_s)
            return error.TestDeadlineExceeded;
    }
};
fn pause() !void {
    try std.Io.sleep(t.io, .fromNanoseconds(50_000), .awake);
}

const Actors = struct {
    driver: *Driver,
    control_scan: bool,
    state: std.atomic.Value(u8) = .init(State.free),
    observed: std.atomic.Value(u8) = .init(255),
    stores: std.atomic.Value(u32) = .init(0),
    scans: std.atomic.Value(u32) = .init(0),
    control_done: std.atomic.Value(bool) = .init(false),
    worker_done: std.atomic.Value(bool) = .init(false),

    fn emit(self: *Actors, role: codec.cuts.Role, site: codec.cuts.Site, edge: codec.cuts.Edge, value: ?u64) bool {
        Regression.point(self.driver, point(role, site, edge, value));
        // These synthetic actors have no native cleanup custody and choose
        // to stop after failure. Production void hooks may instead return
        // to an in-flight atomic; cancellation does not skip that atomic.
        return !Regression.progress(self.driver).failed;
    }
    fn store(self: *Actors, role: codec.cuts.Role, site: codec.cuts.Site, value: u8) bool {
        if (!self.emit(role, site, .before, value)) return false;
        self.state.store(value, .release);
        _ = self.stores.fetchAdd(1, .release);
        return self.emit(role, site, .after, value);
    }
    fn scan(self: *Actors, role: codec.cuts.Role, site: codec.cuts.Site) bool {
        if (!self.emit(role, site, .before, null)) return false;
        const actual = self.state.load(.acquire);
        self.observed.store(actual, .release);
        _ = self.scans.fetchAdd(1, .release);
        return self.emit(role, site, .after, actual);
    }
    fn control(self: *Actors) void {
        defer self.control_done.store(true, .release);
        if (!self.store(.control, .service_job_queued, State.queued)) return;
        if (self.control_scan and !self.scan(.control, .service_acceptance_scan)) return;
        _ = self.store(.control, .service_job_free, State.free);
    }
    fn worker(self: *Actors) void {
        defer self.worker_done.store(true, .release);
        if (!self.control_scan and !self.scan(.worker, .service_worker_scan)) return;
        if (!self.store(.worker, .service_worker_running, State.running)) return;
        _ = self.store(.worker, .service_worker_completed, State.completed);
    }
};

/// Own every successfully spawned thread immediately. All error paths,
/// including failure of the second spawn, cancel before joining live actors.
/// Reader bytes, Reader, Driver and Actors all outlive these genuine joins.
const Threads = struct {
    actors: *Actors,
    control: ?std.Thread = null,
    worker: ?std.Thread = null,

    fn startControl(self: *Threads) !void {
        self.control = std.Thread.spawn(.{}, Actors.control, .{self.actors}) catch |err| {
            Regression.cancel(self.actors.driver);
            return err;
        };
    }
    fn startWorker(self: *Threads) !void {
        self.worker = std.Thread.spawn(.{}, Actors.worker, .{self.actors}) catch |err| {
            Regression.cancel(self.actors.driver);
            return err;
        };
    }
    fn join(self: *Threads) void {
        if (self.control) |thread| {
            thread.join();
            self.control = null;
        }
        if (self.worker) |thread| {
            thread.join();
            self.worker = null;
        }
    }
    fn cleanup(self: *Threads) void {
        if (self.control != null or self.worker != null) Regression.cancel(self.actors.driver);
        self.join();
    }
    fn waitAndJoin(self: *Threads, deadline: Deadline) !void {
        while ((self.control != null and !self.actors.control_done.load(.acquire)) or
            (self.worker != null and !self.actors.worker_done.load(.acquire)))
        {
            try deadline.check();
            try pause();
        }
        self.join();
        try deadline.check();
    }
    fn waitForControlAtMarkerTwo(self: *Threads, deadline: Deadline) !void {
        while (true) {
            try deadline.check();
            const progress = Regression.progress(self.actors.driver);
            if (progress.failed) return error.UnexpectedReplayFailure;
            if (progress.marker == 2) break;
            if (progress.marker > 2 or self.actors.control_done.load(.acquire)) return error.UnexpectedControlProgress;
            try pause();
        }
        // Only Control exists. It has released BEFORE1 and is genuinely
        // waiting for the unstarted Worker at next global marker2 / job turn0.
        const progress = Regression.progress(self.actors.driver);
        try t.expectEqual(@as(u64, 0), progress.job_completed);
        try t.expectEqual(@as(u32, 0), self.actors.stores.load(.acquire));
        try t.expectEqual(@as(u32, 0), self.actors.scans.load(.acquire));
        try t.expect(!self.actors.control_done.load(.acquire));
    }
};

fn allocateDriver(reader: *const f.Reader) !*Driver {
    const driver = try t.allocator.create(Driver);
    errdefer t.allocator.destroy(driver);
    driver.* = .{};
    try Regression.initialize(driver, reader);
    return driver;
}

fn successfulReplay(scenario: Scenario) !void {
    var output: [8192]u8 = undefined;
    const reader = try f.Reader.preflight(try makeTape(&output, scenario), identity(), codec.validate);
    const driver = try allocateDriver(&reader);
    defer t.allocator.destroy(driver);
    errdefer Regression.cancel(driver);
    var actors: Actors = .{ .driver = driver, .control_scan = scenario.controlScan() };
    var threads: Threads = .{ .actors = &actors };
    defer threads.cleanup();
    const deadline = Deadline.begin();
    try threads.startControl();
    try threads.startWorker();
    try threads.waitAndJoin(deadline);

    const progress = Regression.progress(driver);
    try t.expect(!progress.failed);
    try t.expectEqual(@as(u64, 11), progress.marker);
    try t.expectEqual(@as(u64, 5), progress.job_completed);
    try t.expectEqual(@as(u32, 4), actors.stores.load(.acquire));
    try t.expectEqual(@as(u32, 1), actors.scans.load(.acquire));
    try t.expectEqual(State.free, actors.state.load(.acquire));
    try t.expectEqual(scenario.expectedObservation(), actors.observed.load(.acquire));
    // The facade checks every one of the four INPUT/reference lane pairs and
    // both gate planner EOFs. This is not Driver.run/Host completion evidence.
    try Regression.finish(driver);
    try t.expect(!Regression.progress(driver).failed);
}

fn expectNoSuccessProof(driver: *Driver) !void {
    if (Regression.finish(driver)) |_| {
        return error.UnexpectedSuccessProof;
    } else |_| {}
}

test "job replay Worker true scan sees original queued store through crossed markers" {
    try successfulReplay(.worker_true);
}

test "job replay Worker false scan AFTER precedes queued store AFTER" {
    try successfulReplay(.worker_false_scan_after_first);
}

test "job replay false Worker completion releases queued store before its own later AFTER marker" {
    // C.before1, W.before2, C.after3, W.after4. The false read must
    // complete job turn0 before waiting at marker4, or both actors deadlock.
    try successfulReplay(.worker_false_queue_after_first);
}

test "job replay acceptance true scan reads actual completed state through crossed markers" {
    try successfulReplay(.acceptance_true);
}

test "job replay acceptance false scan reads actual running before completed publication" {
    // W.complete.before5, C.scan.before6, W.complete.after7, C.scan.after8.
    // Raw running=2 must compare as false=0, never as a substituted load.
    try successfulReplay(.acceptance_false);
}

test "job replay mismatched actual scan aborts without releasing original actor stores" {
    var output: [8192]u8 = undefined;
    const reader = try f.Reader.preflight(try makeTape(&output, .worker_false_queue_after_first), identity(), codec.validate);
    const driver = try allocateDriver(&reader);
    defer t.allocator.destroy(driver);
    errdefer Regression.cancel(driver);
    var actors: Actors = .{ .driver = driver, .control_scan = false };
    var threads: Threads = .{ .actors = &actors };
    defer threads.cleanup();
    const deadline = Deadline.begin();
    try threads.startControl();
    try threads.waitForControlAtMarkerTwo(deadline);

    // Deliberate test-only fault in this test's own atomic cell. This is not
    // an original actor store, not a Driver operation, and not an expected
    // result returned to Worker. Worker must still execute its real load.
    actors.state.store(State.queued, .release);
    try threads.startWorker();
    try threads.waitAndJoin(deadline);
    const progress = Regression.progress(driver);
    try t.expect(progress.failed);
    try t.expectEqual(@as(u64, 0), progress.job_completed);
    try t.expectEqual(@as(u32, 0), actors.stores.load(.acquire));
    try t.expectEqual(@as(u32, 1), actors.scans.load(.acquire));
    try t.expectEqual(State.queued, actors.observed.load(.acquire));
    try t.expectEqual(State.queued, actors.state.load(.acquire));
    try expectNoSuccessProof(driver);
}

test "job replay cancellation unblocks genuinely waiting Control without starting Worker" {
    var output: [8192]u8 = undefined;
    const reader = try f.Reader.preflight(try makeTape(&output, .worker_false_queue_after_first), identity(), codec.validate);
    const driver = try allocateDriver(&reader);
    defer t.allocator.destroy(driver);
    errdefer Regression.cancel(driver);
    var actors: Actors = .{ .driver = driver, .control_scan = false };
    var threads: Threads = .{ .actors = &actors };
    defer threads.cleanup();
    const deadline = Deadline.begin();
    try threads.startControl();
    try threads.waitForControlAtMarkerTwo(deadline);
    Regression.cancel(driver);
    try threads.waitAndJoin(deadline);
    const progress = Regression.progress(driver);
    try t.expect(progress.failed);
    try t.expectEqual(@as(u64, 2), progress.marker);
    try t.expectEqual(@as(u64, 0), progress.job_completed);
    try t.expectEqual(@as(u32, 0), actors.stores.load(.acquire));
    try t.expectEqual(@as(u32, 0), actors.scans.load(.acquire));
    try t.expectEqual(State.free, actors.state.load(.acquire));
    try t.expect(actors.control_done.load(.acquire));
    try t.expect(!actors.worker_done.load(.acquire));
    try expectNoSuccessProof(driver);
}
