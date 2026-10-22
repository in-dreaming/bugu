//! Fixed-work single-writer atomic counters and monotonic timing. Readout is
//! concurrently safe, but a multi-counter snapshot is not a coherent transaction.
//! Reset requires stopped producers/readers, an advancing epoch and a new run.
const std = @import("std");
const builtin = @import("builtin");
const trace = @import("trace.zig");
pub const Metric = enum(u8) { callback_duration, callback_deadline_miss, render_duration, control_duration, planner_duration, rendered_frames, submitted_frames, pending_frames, flushed_frames, delivered_observation, stream_starvation, backend_reported_underrun, physical_glitch, command_overflow, receipt_overflow, completion_overflow, trace_overflow, cancellation, stale_epoch, acquire_retry, lease_pin_retry, lease_retired, lease_reclaimed };
pub const Unit = enum { nanoseconds, frames, events };
pub const Scope = enum { callback, render, control, planner, backend, external_observer };
pub const Support = enum(u8) { unsupported, invalid, valid };
pub const OverflowBehavior = enum { saturates_and_invalidates };
pub const Descriptor = struct { metric: Metric, owner_task: u16, producer: Scope, unit: Unit, overflow: OverflowBehavior = .saturates_and_invalidates };
pub fn descriptor(metric: Metric) Descriptor {
    return .{ .metric = metric, .owner_task = switch (metric) {
        .stream_starvation => 11,
        .physical_glitch => 22,
        .planner_duration => 9,
        .command_overflow, .receipt_overflow, .cancellation, .stale_epoch => 2,
        .trace_overflow => 4,
        else => 14,
    }, .producer = switch (metric) {
        .callback_duration, .callback_deadline_miss => .callback,
        .control_duration, .command_overflow, .completion_overflow, .lease_retired, .lease_reclaimed => .control,
        .planner_duration => .planner,
        .submitted_frames, .pending_frames, .flushed_frames, .delivered_observation, .backend_reported_underrun => .backend,
        .physical_glitch => .external_observer,
        else => .render,
    }, .unit = switch (metric) {
        .callback_duration, .render_duration, .control_duration, .planner_duration => .nanoseconds,
        .rendered_frames, .submitted_frames, .pending_frames, .flushed_frames, .delivered_observation, .stream_starvation => .frames,
        else => .events,
    } };
}
pub const Reading = struct {
    value: u64,
    sample_count: u64,
    high_water: u64,
    reset_epoch: u64,
    support: Support,
    overflowed: bool,
    pub fn requireValid(self: Reading) !void {
        if (self.support == .unsupported) return error.UnsupportedProducer;
        if (self.support != .valid or self.sample_count == 0 or self.overflowed) return error.InvalidMeasurement;
    }
};
pub const Counter = struct {
    value: std.atomic.Value(u64) = .init(0),
    samples: std.atomic.Value(u64) = .init(0),
    high_water: std.atomic.Value(u64) = .init(0),
    epoch: std.atomic.Value(u64) = .init(1),
    support: std.atomic.Value(Support) = .init(.unsupported),
    failed: std.atomic.Value(bool) = .init(false),
    overflowed: std.atomic.Value(bool) = .init(false),
    /// Non-RT configuration by the actual producer owner, before callbacks start.
    pub fn connectQuiescent(self: *Counter, supported: bool) void {
        self.support.store(if (supported) .invalid else .unsupported, .release);
    }
    /// Single writer. Constant number of atomics, no retry loops or allocation.
    /// Recording zero is an observed event/interval, distinct from no producer.
    pub fn observe(self: *Counter, value: u64) void {
        if (self.support.load(.monotonic) == .unsupported) return;
        const previous = self.value.load(.monotonic);
        const count = self.samples.load(.monotonic);
        const sum = @addWithOverflow(previous, value);
        const sample_sum = @addWithOverflow(count, 1);
        self.value.store(if (sum[1] == 0) sum[0] else std.math.maxInt(u64), .monotonic);
        self.samples.store(if (sample_sum[1] == 0) sample_sum[0] else std.math.maxInt(u64), .monotonic);
        if (value > self.high_water.load(.monotonic)) self.high_water.store(value, .monotonic);
        if (sum[1] != 0 or sample_sum[1] != 0) self.overflowed.store(true, .monotonic);
        self.support.store(if (self.overflowed.load(.monotonic) or self.failed.load(.monotonic)) .invalid else .valid, .release);
    }
    pub fn invalidate(self: *Counter) void {
        self.failed.store(true, .monotonic);
        if (self.support.load(.monotonic) != .unsupported) self.support.store(.invalid, .release);
    }
    pub fn read(self: *const Counter) Reading {
        const support = self.support.load(.acquire);
        return .{ .value = self.value.load(.monotonic), .sample_count = self.samples.load(.monotonic), .high_water = self.high_water.load(.monotonic), .reset_epoch = self.epoch.load(.monotonic), .support = support, .overflowed = self.overflowed.load(.monotonic) };
    }
    pub fn resetQuiescent(self: *Counter, epoch: u64) !void {
        if (epoch <= self.epoch.load(.monotonic)) return error.InvalidEvent;
        const connected = self.support.load(.monotonic) != .unsupported;
        self.value.store(0, .monotonic);
        self.samples.store(0, .monotonic);
        self.high_water.store(0, .monotonic);
        self.overflowed.store(false, .monotonic);
        self.failed.store(false, .monotonic);
        self.epoch.store(epoch, .monotonic);
        self.support.store(if (connected) .invalid else .unsupported, .release);
    }
};
pub const Counters = struct {
    entries: [std.meta.fields(Metric).len]Counter = @splat(.{}),
    pub fn get(self: *Counters, metric: Metric) *Counter {
        return &self.entries[@intFromEnum(metric)];
    }
    pub fn read(self: *const Counters, metric: Metric) Reading {
        return self.entries[@intFromEnum(metric)].read();
    }
    /// Software nominal gate. Each required metric must have a connected valid
    /// producer and samples; positive fault measurements fail instead of being
    /// mistaken for a successful observability self-test. Physical output needs
    /// its own independently connected observer.
    pub fn requireNominal(self: *const Counters, required: []const Metric) !void {
        if (required.len == 0) return error.InvalidMeasurement;
        for (required) |metric| {
            const reading = self.read(metric);
            try reading.requireValid();
            const fault = switch (metric) {
                .callback_deadline_miss, .stream_starvation, .backend_reported_underrun, .physical_glitch, .command_overflow, .receipt_overflow, .completion_overflow, .trace_overflow, .stale_epoch => true,
                else => false,
            };
            if (fault and reading.value != 0) return error.ObservedFault;
        }
    }
    /// Legacy-compatible numerical view carries validity alongside values; it
    /// never translates software misses into physical dropout/underrun claims.
    pub fn legacyView(self: *const Counters) LegacyView {
        return .{ .rendered_frames = self.read(.rendered_frames), .callback_count = self.read(.callback_duration).sample_count, .max_callback_nanos = self.read(.callback_duration).high_water, .callback_support = self.read(.callback_duration).support, .underrun = self.read(.backend_reported_underrun), .dropout = self.read(.physical_glitch) };
    }
};
pub const LegacyView = struct { rendered_frames: Reading, callback_count: u64, max_callback_nanos: u64, callback_support: Support, underrun: Reading, dropout: Reading };
pub const TimingScope = enum(u8) { callback, render, control, planner };
pub const TimingSample = struct { scope: TimingScope, epoch: u64, nanos: u64, budget_nanos: u64, deadline_missed: bool };
pub const TimingRing = trace.Ring(TimingSample, 1024);
pub const Clock = struct {
    frequency: u64,
    pub fn init() !Clock {
        if (builtin.os.tag == .windows) {
            var frequency: std.os.windows.LARGE_INTEGER = 0;
            if (!std.os.windows.ntdll.RtlQueryPerformanceFrequency(&frequency).toBool() or frequency <= 0) return error.ClockUnsupported;
            return .{ .frequency = @intCast(frequency) };
        } else if (builtin.os.tag == .linux) {
            const clock: Clock = .{ .frequency = std.time.ns_per_s };
            _ = try clock.now();
            return clock;
        } else return error.ClockUnsupported;
    }
    /// Linux uses one audited clock_gettime syscall, Windows one performance
    /// counter call. No frequency query/lazy initialization on render.
    pub fn now(self: Clock) !u64 {
        if (builtin.os.tag == .linux) {
            var ts: std.os.linux.timespec = undefined;
            if (std.os.linux.clock_gettime(.MONOTONIC, &ts) != 0 or ts.sec < 0 or ts.nsec < 0 or ts.nsec >= std.time.ns_per_s) return error.ClockFailure;
            const value: u128 = @as(u128, @intCast(ts.sec)) * std.time.ns_per_s + @as(u128, @intCast(ts.nsec));
            if (value > std.math.maxInt(u64)) return error.ClockFailure;
            return @intCast(value);
        } else if (builtin.os.tag == .windows) {
            var counter: std.os.windows.LARGE_INTEGER = 0;
            if (!std.os.windows.ntdll.RtlQueryPerformanceCounter(&counter).toBool() or counter < 0 or self.frequency == 0) return error.ClockFailure;
            const value = @as(u128, @intCast(counter)) * std.time.ns_per_s / self.frequency;
            if (value > std.math.maxInt(u64)) return error.ClockFailure;
            return @intCast(value);
        } else return error.ClockUnsupported;
    }
};
pub const Timer = struct {
    clock: Clock,
    scope: TimingScope,
    duration: *Counter,
    misses: ?*Counter,
    samples: *TimingRing,
    trace_overflow: *Counter,
    pub fn begin(self: *Timer) !u64 {
        return self.clock.now() catch |err| {
            self.duration.invalidate();
            return err;
        };
    }
    pub fn end(self: *Timer, start: u64, frame_count: u32, sample_rate: u32) !void {
        const end_ns = self.clock.now() catch |err| {
            self.duration.invalidate();
            return err;
        };
        if (end_ns <= start or sample_rate == 0 or frame_count == 0) {
            self.duration.invalidate();
            return error.InvalidMeasurement;
        }
        const nanos = end_ns - start;
        const budget: u64 = @intCast(@as(u128, frame_count) * std.time.ns_per_s / sample_rate);
        // Compare exact rational deadline; flooring nanoseconds must not misclassify.
        const missed = @as(u128, nanos) * sample_rate > @as(u128, frame_count) * std.time.ns_per_s;
        self.duration.observe(nanos);
        if (self.misses) |m| m.observe(if (missed) 1 else 0);
        const recorded = self.samples.push(.{ .scope = self.scope, .epoch = self.duration.epoch.load(.monotonic), .nanos = nanos, .budget_nanos = budget, .deadline_missed = missed });
        // A successful push is an observed zero-loss sample, not no observation.
        self.trace_overflow.observe(if (recorded) 0 else 1);
    }
};
pub const Percentiles = struct { sample_count: usize, p50: u64, p95: u64, p99: u64, p999: u64 };
/// Control-only; caller owns the sample copy. Nearest-rank integer quantiles.
pub fn aggregate(samples: []u64) !Percentiles {
    if (samples.len == 0) return error.InvalidMeasurement;
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    return .{ .sample_count = samples.len, .p50 = rank(samples, 500), .p95 = rank(samples, 950), .p99 = rank(samples, 990), .p999 = rank(samples, 999) };
}
fn rank(samples: []const u64, per_mille: usize) u64 {
    const index = (@as(u128, samples.len) * per_mille + 999) / 1000 - 1;
    return samples[@intCast(index)];
}
