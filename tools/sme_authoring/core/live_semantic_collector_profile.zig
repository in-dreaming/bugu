//! Test-only, single-consumer diagnostics. Never read or update this object on
//! a producer. Attach only after Recorder initialization; its external owner
//! retains stable storage until genuine join. No allocations or logging occur
//! while collecting. This module deliberately imports no engine/runtime code.
const std = @import("std");
const builtin = @import("builtin");

pub const role_count = 4;
pub const family_codes = [_]u16{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110, 111, 112, 113, 114, 115, 116, 117, 118, 119 };
pub const timeline_capacity = 128;
pub const timeline_pass_stride = 1024;
pub const sample_denominator = 64;
pub const Stage = enum { pop_observe, encode, append };
pub const SnapshotReason = enum { start, periodic, first_failure, joined };

fn increment(value: *u64, amount: u64, overflow: *bool) void {
    const sum = @addWithOverflow(value.*, amount);
    value.* = if (sum[1] == 0) sum[0] else std.math.maxInt(u64);
    overflow.* = overflow.* or sum[1] != 0;
}

/// Population counters are exact until explicitly saturated. Durations and
/// sample_bytes describe ONLY observed samples, never a 64x extrapolation.
/// A zero sample_count means unknown cost, not a zero-cost stage. Wall-clock
/// stages are inclusive: append includes hashing/buffering/sink/raw writes;
/// never add raw_write time to append time. Harness raw_write may also cover
/// headers, trailers, and a final flush outside sampled append intervals, so
/// the two reports do not have identical populations or coverage.
pub const Duration = struct {
    population: u64 = 0,
    errors: u64 = 0,
    bytes: u64 = 0,
    sample_count: u64 = 0,
    sample_errors: u64 = 0,
    sample_bytes: u64 = 0,
    total_ns: u64 = 0,
    min_ns: u64 = 0,
    max_ns: u64 = 0,
    invalid_durations: u64 = 0,
    overflow: bool = false,

    /// All-events timing interface for the harness's raw-write wrapper.
    pub fn observe(self: *Duration, duration_ns: i128, success: bool, bytes: u64) void {
        self.complete(duration_ns, success, bytes);
    }
    pub fn complete(self: *Duration, duration_ns: ?i128, success: bool, bytes: u64) void {
        increment(&self.population, 1, &self.overflow);
        increment(&self.bytes, bytes, &self.overflow);
        if (!success) increment(&self.errors, 1, &self.overflow);
        const ns = duration_ns orelse return;
        increment(&self.sample_count, 1, &self.overflow);
        increment(&self.sample_bytes, bytes, &self.overflow);
        if (!success) increment(&self.sample_errors, 1, &self.overflow);
        if (ns < 0) {
            increment(&self.invalid_durations, 1, &self.overflow);
            return;
        }
        const bounded_ns: u64 = if (ns <= std.math.maxInt(u64)) @intCast(ns) else blk: {
            self.overflow = true;
            break :blk std.math.maxInt(u64);
        };
        increment(&self.total_ns, bounded_ns, &self.overflow);
        if (self.sample_count - self.invalid_durations == 1) self.min_ns = bounded_ns else self.min_ns = @min(self.min_ns, bounded_ns);
        self.max_ns = @max(self.max_ns, bounded_ns);
    }
};

pub const Metrics = struct {
    records: u64 = 0,
    native_bytes: u64 = 0,
    encoded_records: u64 = 0,
    wire_bytes: u64 = 0, // Encoded payload bytes, excluding framing.
    appended_records: u64 = 0,
    framed_wire_bytes: u64 = 0, // Successful appends only; not uncertain writes.
    pop_observe: Duration = .{},
    encode: Duration = .{},
    append: Duration = .{},
};
pub const RoleMetrics = struct {
    attempted_pops: u64 = 0,
    sampled_attempts: u64 = 0,
    empty_pops: u64 = 0,
    pop_errors: u64 = 0,
    observe_errors: u64 = 0,
    metrics: Metrics = .{},
};
pub const LaneSnapshot = struct {
    record_write: u64 = 0,
    record_read: u64 = 0,
    peak_bytes: u64 = 0,
    peak_records: u64 = 0,
};
pub const Snapshot = struct {
    pass: u64 = 0,
    elapsed_ns: u64 = 0,
    lanes: [role_count]LaneSnapshot = @splat(.{}),
};
pub const Report = struct {
    role_names: [role_count][]const u8 = .{ "control", "worker", "render", "ui" },
    families: [family_codes.len]u16 = family_codes,
    sampling_denominator: u64 = sample_denominator,
    timeline_stride: u64 = timeline_pass_stride,
    passes: u64 = 0,
    successful_passes: u64 = 0,
    progressed_passes: u64 = 0,
    failed_passes: u64 = 0,
    clock_calls: u64 = 0,
    stage_clock_calls: u64 = 0,
    timeline_clock_calls: u64 = 0,
    invalid_timestamps: u64 = 0,
    // Collector-only saturation flag; raw_write reports its own overflow.
    overflow: bool = false,
    unknown_families: u64 = 0,
    roles: [role_count]RoleMetrics = @splat(.{}),
    by_role_family: [role_count][family_codes.len]Metrics = @splat(@splat(.{})),
    raw_write: Duration = .{},
    first: ?Snapshot = null,
    first_failure: ?Snapshot = null,
    joined: ?Snapshot = null,
    // Ring order is timeline_next..end then 0..timeline_next once full.
    // Retention loss is intentional and explicit; the first/failure/final
    // points are pinned separately. Ordinary sampling freezes on first error.
    // elapsed_ns begins at the first collector snapshot, not Host.launch.
    timeline: [timeline_capacity]Snapshot = @splat(.{}),
    timeline_count: usize = 0,
    timeline_next: usize = 0,
    timeline_overwrites: u64 = 0,
};

fn familyIndex(family: u16) ?usize {
    return if (family >= 1 and family <= 17) family - 1 else if (family >= 101 and family <= 119) 17 + family - 101 else null;
}
/// Independent deterministic Bernoulli selection for each role. This is a
/// diagnostic sample, not a confidence guarantee. Xorshift's low bits avoid
/// the fixed phase alias of one global every-64th-record counter.
pub const Sampler = struct {
    states: [role_count]u64 = .{ 0x243f6a8885a308d3, 0x13198a2e03707344, 0xa4093822299f31d0, 0x082efa98ec4e6c89 },
    pub fn next(self: *Sampler, role: usize) bool {
        var value = self.states[role];
        value ^= value << 13;
        value ^= value >> 7;
        value ^= value << 17;
        self.states[role] = value;
        return (value & (sample_denominator - 1)) == 0;
    }
};

/// Production has no profiler object or optional-pointer field storage.
pub const Profile = if (builtin.is_test) TestProfile else struct {};
pub const Pointer = if (builtin.is_test) ?*Profile else void;
const Timestamp = @TypeOf(std.Io.Clock.awake.now(@as(std.Io, undefined)));
pub const Token = struct { started: ?Timestamp = null };
const TestProfile = struct {
    io: std.Io,
    report: Report = .{},
    sampler: Sampler = .{},
    origin: ?Timestamp = null,

    pub fn init(io: std.Io) Profile {
        return .{ .io = io };
    }
    pub fn beginPass(self: *TestProfile) void {
        increment(&self.report.passes, 1, &self.report.overflow);
    }
    pub fn endPass(self: *TestProfile, success: bool, progressed: bool) void {
        if (success) increment(&self.report.successful_passes, 1, &self.report.overflow) else increment(&self.report.failed_passes, 1, &self.report.overflow);
        if (progressed) increment(&self.report.progressed_passes, 1, &self.report.overflow);
    }
    pub fn sample(self: *TestProfile, role: usize) bool {
        increment(&self.report.roles[role].attempted_pops, 1, &self.report.overflow);
        const selected = self.sampler.next(role);
        if (selected) increment(&self.report.roles[role].sampled_attempts, 1, &self.report.overflow);
        return selected;
    }
    fn now(self: *TestProfile, comptime stage: bool) Timestamp {
        increment(&self.report.clock_calls, 1, &self.report.overflow);
        if (stage) increment(&self.report.stage_clock_calls, 1, &self.report.overflow) else increment(&self.report.timeline_clock_calls, 1, &self.report.overflow);
        return std.Io.Clock.awake.now(self.io);
    }
    pub fn start(self: *TestProfile, sampled: bool) Token {
        return .{ .started = if (sampled) self.now(true) else null };
    }
    fn duration(metrics: *Metrics, comptime stage: Stage) *Duration {
        return switch (stage) {
            .pop_observe => &metrics.pop_observe,
            .encode => &metrics.encode,
            .append => &metrics.append,
        };
    }
    pub fn complete(self: *TestProfile, role: usize, family: ?u16, comptime stage: Stage, token: Token, success: bool, bytes: u64) void {
        const elapsed: ?i128 = if (token.started) |started| started.durationTo(self.now(true)).nanoseconds else null;
        const role_duration = duration(&self.report.roles[role].metrics, stage);
        role_duration.complete(elapsed, success, bytes);
        self.report.overflow = self.report.overflow or role_duration.overflow;
        if (family) |code| if (familyIndex(code)) |index| {
            const family_duration = duration(&self.report.by_role_family[role][index], stage);
            family_duration.complete(elapsed, success, bytes);
            self.report.overflow = self.report.overflow or family_duration.overflow;
        };
    }
    pub fn empty(self: *TestProfile, role: usize) void {
        increment(&self.report.roles[role].empty_pops, 1, &self.report.overflow);
    }
    pub fn popError(self: *TestProfile, role: usize) void {
        increment(&self.report.roles[role].pop_errors, 1, &self.report.overflow);
    }
    pub fn observeError(self: *TestProfile, role: usize) void {
        increment(&self.report.roles[role].observe_errors, 1, &self.report.overflow);
    }
    fn account(self: *TestProfile, metrics: *Metrics, comptime stage: Stage, bytes: u64) void {
        switch (stage) {
            .pop_observe => {
                increment(&metrics.records, 1, &self.report.overflow);
                increment(&metrics.native_bytes, bytes, &self.report.overflow);
            },
            .encode => {
                increment(&metrics.encoded_records, 1, &self.report.overflow);
                increment(&metrics.wire_bytes, bytes, &self.report.overflow);
            },
            .append => {
                increment(&metrics.appended_records, 1, &self.report.overflow);
                increment(&metrics.framed_wire_bytes, bytes, &self.report.overflow);
            },
        }
    }
    pub fn accountRecord(self: *TestProfile, role: usize, family: u16, comptime stage: Stage, bytes: u64) void {
        self.account(&self.report.roles[role].metrics, stage, bytes);
        if (familyIndex(family)) |index| {
            self.account(&self.report.by_role_family[role][index], stage, bytes);
        } else if (stage == .pop_observe) {
            increment(&self.report.unknown_families, 1, &self.report.overflow);
        }
    }
    pub fn snapshot(self: *TestProfile, capture: anytype, reason: SnapshotReason) void {
        switch (reason) {
            .start => if (self.report.first != null) return,
            .first_failure => if (self.report.first_failure != null) return,
            .periodic => if (self.report.first_failure != null or self.report.passes % timeline_pass_stride != 0) return,
            .joined => {},
        }
        const stamp = self.now(false);
        if (self.origin == null) self.origin = stamp;
        const elapsed = self.origin.?.durationTo(stamp).nanoseconds;
        var value: Snapshot = .{ .pass = self.report.passes };
        if (elapsed < 0) {
            increment(&self.report.invalid_timestamps, 1, &self.report.overflow);
        } else if (elapsed > std.math.maxInt(u64)) {
            value.elapsed_ns = std.math.maxInt(u64);
            self.report.overflow = true;
        } else value.elapsed_ns = @intCast(elapsed);
        // These are independently acquired observations, not an atomic view
        // across lanes. In particular, never inspect producer-only byte_write
        // or call finalStats while any producer may still be alive.
        for (&capture.lanes, &value.lanes) |*lane, *out| {
            // This sole consumer does not advance read while snapshotting.
            // Read first, then acquire the producer's publication frontier.
            const consumed = lane.record_read.load(.acquire);
            const produced = lane.record_write.load(.acquire);
            out.* = .{
                .record_write = produced,
                .record_read = consumed,
                .peak_bytes = lane.peak_bytes.load(.monotonic),
                .peak_records = lane.peak_records.load(.monotonic),
            };
        }
        switch (reason) {
            .start => self.report.first = value,
            .first_failure => self.report.first_failure = value,
            .joined => self.report.joined = value,
            .periodic => {
                self.report.timeline[self.report.timeline_next] = value;
                self.report.timeline_next = (self.report.timeline_next + 1) % timeline_capacity;
                if (self.report.timeline_count < timeline_capacity) self.report.timeline_count += 1 else increment(&self.report.timeline_overwrites, 1, &self.report.overflow);
            },
        }
    }
};

comptime {
    if (!builtin.is_test and (@sizeOf(Profile) != 0 or @sizeOf(Pointer) != 0)) @compileError("production collector profiling must be zero-sized");
    if (@sizeOf(TestProfile) > 96 * 1024) @compileError("collector diagnostics exceed their fixed 96 KiB bound");
}

test "collector profile duration includes error completion and unknown unsampled cost" {
    var value: Duration = .{};
    value.complete(null, true, 20);
    value.observe(11, true, 7);
    value.observe(5, false, 3);
    try std.testing.expectEqual(@as(u64, 3), value.population);
    try std.testing.expectEqual(@as(u64, 1), value.errors);
    try std.testing.expectEqual(@as(u64, 2), value.sample_count);
    try std.testing.expectEqual(@as(u64, 1), value.sample_errors);
    try std.testing.expectEqual(@as(u64, 30), value.bytes);
    try std.testing.expectEqual(@as(u64, 10), value.sample_bytes);
    try std.testing.expectEqual(@as(u64, 16), value.total_ns);
    try std.testing.expectEqual(@as(u64, 5), value.min_ns);
    try std.testing.expectEqual(@as(u64, 11), value.max_ns);
}

test "collector profile diagnostic overflow and backwards time stay explicit" {
    var value: Duration = .{ .population = std.math.maxInt(u64), .total_ns = std.math.maxInt(u64) };
    value.observe(1, false, 4);
    try std.testing.expect(value.overflow);
    try std.testing.expectEqual(std.math.maxInt(u64), value.population);
    try std.testing.expectEqual(std.math.maxInt(u64), value.total_ns);
    value.observe(-1, false, 0);
    try std.testing.expectEqual(@as(u64, 1), value.invalid_durations);
}

test "collector profile deterministic independent role sampling avoids fixed phases" {
    var a: Sampler = .{};
    var b: Sampler = .{};
    var counts: [role_count]u64 = @splat(0);
    var phases: [role_count]u64 = @splat(0);
    for (0..16384) |attempt| {
        for (0..role_count) |role| {
            const sampled = a.next(role);
            try std.testing.expectEqual(sampled, b.next(role));
            if (sampled) {
                counts[role] += 1;
                phases[role] |= @as(u64, 1) << @as(u6, @intCast(attempt % 64));
            }
        }
    }
    for (counts, phases) |count, phase| {
        try std.testing.expect(count > 100 and count < 400);
        try std.testing.expect(@popCount(phase) > 32);
    }
}

test "collector profile unsampled stages do not read the clock and preserve errors" {
    var profile = Profile.init(std.testing.io);
    const token = profile.start(false);
    profile.complete(0, 1, .encode, token, false, 12);
    try std.testing.expectEqual(@as(u64, 0), profile.report.clock_calls);
    try std.testing.expectEqual(@as(u64, 1), profile.report.roles[0].metrics.encode.errors);
    try std.testing.expectEqual(@as(u64, 0), profile.report.by_role_family[0][0].encode.sample_count);
    for (family_codes, 0..) |code, index| try std.testing.expectEqual(index, familyIndex(code).?);
}

test "collector profile JSON preserves exact zero error overflow and unknown fields" {
    var profile = Profile.init(std.testing.io);
    profile.report.raw_write.observe(4, true, 16);
    profile.report.raw_write.observe(8, false, 7);
    profile.report.raw_write.total_ns = std.math.maxInt(u64);
    profile.report.raw_write.observe(1, false, 2);
    profile.accountRecord(3, 65535, .pop_observe, 9);
    profile.complete(3, 65535, .encode, .{}, false, 0);
    const bytes = try std.json.Stringify.valueAlloc(std.testing.allocator, profile.report, .{});
    defer std.testing.allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(Report, std.testing.allocator, bytes, .{});
    defer parsed.deinit();
    const report = parsed.value;
    try std.testing.expectEqual(@as(u64, 3), report.raw_write.population);
    try std.testing.expectEqual(@as(u64, 3), report.raw_write.sample_count);
    try std.testing.expectEqual(@as(u64, 2), report.raw_write.errors);
    try std.testing.expectEqual(@as(u64, 25), report.raw_write.bytes);
    try std.testing.expectEqual(std.math.maxInt(u64), report.raw_write.total_ns);
    try std.testing.expect(report.raw_write.overflow);
    try std.testing.expectEqual(@as(u64, 0), report.clock_calls);
    try std.testing.expectEqual(@as(u64, 1), report.unknown_families);
    try std.testing.expectEqual(@as(u64, 1), report.roles[3].metrics.records);
    try std.testing.expectEqual(@as(u64, 1), report.roles[3].metrics.encode.errors);
    try std.testing.expectEqual(@as(u64, 0), report.by_role_family[3][0].records);
    try std.testing.expect(report.first == null and report.first_failure == null and report.joined == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"io\"") == null);
}

test "collector profile atomic timeline pins first failure and bounds retention" {
    const AtomicLane = struct {
        record_write: std.atomic.Value(u64) = .init(9),
        record_read: std.atomic.Value(u64) = .init(3),
        peak_bytes: std.atomic.Value(u64) = .init(120),
        peak_records: std.atomic.Value(u64) = .init(6),
    };
    var capture: struct { lanes: [role_count]AtomicLane = @splat(.{}) } = .{};
    var profile = Profile.init(std.testing.io);
    profile.beginPass();
    profile.snapshot(&capture, .start);
    for (0..timeline_capacity + 2) |index| {
        profile.report.passes = (index + 1) * timeline_pass_stride;
        profile.snapshot(&capture, .periodic);
    }
    try std.testing.expectEqual(timeline_capacity, profile.report.timeline_count);
    try std.testing.expectEqual(@as(u64, 2), profile.report.timeline_overwrites);
    profile.snapshot(&capture, .first_failure);
    const first_failure = profile.report.first_failure.?;
    const calls = profile.report.clock_calls;
    capture.lanes[0].record_write.store(10, .release);
    profile.snapshot(&capture, .first_failure);
    profile.snapshot(&capture, .periodic);
    try std.testing.expectEqual(calls, profile.report.clock_calls);
    try std.testing.expectEqual(@as(u64, 9), first_failure.lanes[0].record_write);
    try std.testing.expectEqual(@as(u64, 9), profile.report.first_failure.?.lanes[0].record_write);
    profile.snapshot(&capture, .joined);
    try std.testing.expectEqual(@as(u64, 10), profile.report.joined.?.lanes[0].record_write);
    try std.testing.expectEqual(profile.report.clock_calls, profile.report.timeline_clock_calls);
}
