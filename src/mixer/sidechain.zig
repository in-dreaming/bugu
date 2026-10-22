//! TASK-013: bounded, real-PCM detector, compressor and independent automation.
//! Contract: docs/validation/sme/TASK-013/numerical-contract.md.
const std = @import("std");
const channels = @import("sme-channels");
pub const duck_lifetime = @import("sme-duck-lifetime");
pub const Error = error{ InvalidParameter, InvalidChannels, TooManyRequests, DuplicateRequest, UnknownRequest };
pub const max_window = 4_800;
pub const max_meter_window = 48_000;
pub const max_lookahead = 1024;
pub const DetectorMode = enum { rms, peak };
pub const SidechainPreset = struct {
    id: u32 = 1,
    sample_rate: u32 = 48_000,
    detector_mode: DetectorMode = .rms,
    rms_window_frames: u32 = 480,
    peak_window_frames: u32 = 48,
    meter_window_frames: u32 = 4800,
    threshold_dbfs: f32 = -18,
    ratio: f32 = 4,
    knee_db: f32 = 6,
    attack_frames: u32 = 480,
    hold_frames: u32 = 2400,
    release_frames: u32 = 4800,
    lookahead_frames: u32 = 240,
    makeup_db: f32 = 0,
    signal_cap_db: f32 = 12,
    automation_cap_db: f32 = 12,
    combined_cap_db: f32 = 24,
    /// Null freezes canonical full-range=1, LFE=0; otherwise active slots only.
    weights: ?[channels.max_channels]f32 = null,

    pub fn validate(self: SidechainPreset) Error!void {
        if (self.sample_rate != 48000 or
            self.rms_window_frames == 0 or self.rms_window_frames > max_window or
            self.peak_window_frames == 0 or self.peak_window_frames > max_window or
            self.meter_window_frames == 0 or self.meter_window_frames > max_meter_window or
            self.attack_frames > 48000 or self.hold_frames > 480000 or self.release_frames > 480000 or
            self.lookahead_frames > max_lookahead) return error.InvalidParameter;
        try inRange(self.threshold_dbfs, -96, 0);
        try inRange(self.ratio, 1, 100);
        try inRange(self.knee_db, 0, 24);
        try inRange(self.makeup_db, -24, 24);
        try inRange(self.signal_cap_db, 0, 96);
        try inRange(self.automation_cap_db, 0, 96);
        try inRange(self.combined_cap_db, 0, 96);
        if (self.weights) |weights| for (weights) |weight| {
            if (!std.math.isFinite(weight) or weight < 0) return error.InvalidParameter;
        };
    }
};
pub fn inRange(value: f32, low: f32, high: f32) Error!void {
    if (!std.math.isFinite(value) or value < low or value > high) return error.InvalidParameter;
}
pub fn dbToLinear(db: f32) f32 {
    return std.math.pow(f32, 10, db / 20);
}
pub fn levelDb(level: f32) f32 {
    return if (level > 0) 20 * @log10(level) else -std.math.inf(f32);
}
pub fn requestedReduction(level_db: f32, preset: SidechainPreset) f32 {
    if (level_db == -std.math.inf(f32)) return 0;
    const x = level_db - preset.threshold_dbfs;
    const slope = 1 - 1 / preset.ratio;
    const knee = preset.knee_db;
    const raw = if (knee == 0) @max(0, slope * x) else if (x <= -knee / 2) 0 else if (x >= knee / 2) slope * x else slope * (x + knee / 2) * (x + knee / 2) / (2 * knee);
    return @min(raw, preset.signal_cap_db);
}
pub fn smoothDb(current: f32, target: f32, frames: u32) f32 {
    if (frames == 0) return target;
    const c: f64 = @exp(-1 / @as(f64, @floatFromInt(frames)));
    return @floatCast(@as(f64, target) + (@as(f64, current) - target) * c);
}

pub const MeterSnapshot = struct {
    start_frame: u64 = 0,
    end_frame: u64 = 0,
    valid_frames: u32 = 0,
    window_frames: u32 = 0,
    partial: bool = true,
    peak: f32 = 0,
    rms: f32 = 0,
};
pub const Meter = struct {
    window_frames: u32,
    start_frame: u64 = 0,
    count: u32 = 0,
    power_sum: f64 = 0,
    peak: f32 = 0,
    completed: MeterSnapshot = .{},
    pub fn init(window: u32) Error!Meter {
        if (window == 0 or window > max_meter_window) return error.InvalidParameter;
        return .{ .window_frames = window, .completed = .{ .window_frames = window } };
    }
    /// One weighted mean-power and one peak observation per render frame.
    pub fn observe(self: *Meter, power: f64, peak: f32) void {
        self.power_sum += power;
        self.peak = @max(self.peak, peak);
        self.count += 1;
        if (self.count == self.window_frames) {
            self.completed = self.partialSnapshot();
            self.completed.partial = false;
            self.start_frame += self.count;
            self.count = 0;
            self.power_sum = 0;
            self.peak = 0;
        }
    }
    pub fn observeFrame(self: *Meter, frame: []const f32) void {
        var power: f64 = 0;
        var peak: f32 = 0;
        for (frame) |sample| {
            const x = if (std.math.isFinite(sample)) sample else 0;
            power += @as(f64, x) * x;
            peak = @max(peak, @abs(x));
        }
        self.observe(power / @as(f64, @floatFromInt(frame.len)), peak);
    }
    pub fn partialSnapshot(self: *const Meter) MeterSnapshot {
        return .{ .start_frame = self.start_frame, .end_frame = self.start_frame + self.count, .valid_frames = self.count, .window_frames = self.window_frames, .partial = self.count != self.window_frames, .peak = self.peak, .rms = if (self.count == 0) 0 else @floatCast(@sqrt(self.power_sum / @as(f64, @floatFromInt(self.count)))) };
    }
};
const PeakEntry = struct { frame: u64, power: f64 };
pub const DetectorSnapshot = struct {
    rms: f32 = 0,
    peak: f32 = 0,
    envelope: f32 = 0,
    invalid_samples: u64 = 0,
    meter: MeterSnapshot = .{},
    completed_meter: MeterSnapshot = .{},
};
pub const Detector = struct {
    layout: channels.ChannelLayout,
    weights: [channels.max_channels]f64 = @splat(0),
    peak_weights: [channels.max_channels]f64 = @splat(0),
    power_ring: []f64,
    peak_queue: []PeakEntry,
    rms_cursor: usize = 0,
    sum: f64 = 0,
    peak_head: usize = 0,
    peak_count: usize = 0,
    frame: u64 = 0,
    mode: DetectorMode,
    meter: Meter,
    snapshot: DetectorSnapshot = .{},
    pub fn stateBytes(preset: SidechainPreset) usize {
        return @as(usize, preset.rms_window_frames) * @sizeOf(f64) + @as(usize, preset.peak_window_frames) * @sizeOf(PeakEntry);
    }
    pub fn init(allocator: std.mem.Allocator, layout: channels.ChannelLayout, preset: SidechainPreset) !Detector {
        try preset.validate();
        try layout.validate();
        var weights: [channels.max_channels]f64 = @splat(0);
        var total: f64 = 0;
        for (0..layout.count) |i| {
            const weight: f32 = if (preset.weights) |w| w[i] else if (layout.order[i] == .lfe) 0 else 1;
            if (!std.math.isFinite(weight) or weight < 0) return error.InvalidParameter;
            weights[i] = weight;
            total += weight;
        }
        if (total <= 0 or !std.math.isFinite(total)) return error.InvalidParameter;
        var peak_weights = weights;
        var max_weight: f64 = 0;
        for (weights[0..layout.count]) |w| max_weight = @max(max_weight, w);
        for (peak_weights[0..layout.count]) |*w| w.* /= max_weight;
        for (weights[0..layout.count]) |*w| w.* /= total;
        const ring = try allocator.alloc(f64, preset.rms_window_frames);
        errdefer allocator.free(ring);
        @memset(ring, 0);
        const queue = try allocator.alloc(PeakEntry, preset.peak_window_frames);
        return .{ .layout = layout, .weights = weights, .peak_weights = peak_weights, .power_ring = ring, .peak_queue = queue, .mode = preset.detector_mode, .meter = try Meter.init(preset.meter_window_frames), .snapshot = .{ .meter = .{ .window_frames = preset.meter_window_frames }, .completed_meter = .{ .window_frames = preset.meter_window_frames } } };
    }
    pub fn deinit(self: *Detector, allocator: std.mem.Allocator) void {
        allocator.free(self.power_ring);
        allocator.free(self.peak_queue);
        self.* = undefined;
    }
    pub fn process(self: *Detector, samples: []const f32) DetectorSnapshot {
        std.debug.assert(samples.len == self.layout.count);
        var power: f64 = 0;
        var peak_power: f64 = 0;
        for (samples, 0..) |sample, i| {
            const x: f64 = if (std.math.isFinite(sample)) sample else blk: {
                self.snapshot.invalid_samples +|= 1;
                break :blk 0;
            };
            power += x * x * self.weights[i];
            peak_power = @max(peak_power, x * x * self.peak_weights[i]);
        }
        self.sum = @max(0, self.sum - self.power_ring[self.rms_cursor] + power);
        self.power_ring[self.rms_cursor] = power;
        self.rms_cursor = (self.rms_cursor + 1) % self.power_ring.len;
        while (self.peak_count > 0 and self.frame - self.peak_queue[self.peak_head].frame >= self.peak_queue.len) {
            self.peak_head = (self.peak_head + 1) % self.peak_queue.len;
            self.peak_count -= 1;
        }
        while (self.peak_count > 0) {
            const last = (self.peak_head + self.peak_count - 1) % self.peak_queue.len;
            if (self.peak_queue[last].power > peak_power) break;
            self.peak_count -= 1;
        }
        self.peak_queue[(self.peak_head + self.peak_count) % self.peak_queue.len] = .{ .frame = self.frame, .power = peak_power };
        self.peak_count += 1;
        self.frame +|= 1;
        self.snapshot.rms = @floatCast(@sqrt(self.sum / @as(f64, @floatFromInt(self.power_ring.len))));
        self.snapshot.peak = @floatCast(@sqrt(self.peak_queue[self.peak_head].power));
        self.snapshot.envelope = if (self.mode == .rms) self.snapshot.rms else self.snapshot.peak;
        self.meter.observe(power, @floatCast(@sqrt(peak_power)));
        self.snapshot.meter = self.meter.partialSnapshot();
        self.snapshot.completed_meter = self.meter.completed;
        return self.snapshot;
    }
};

/// Allocated only at preparation. A zero-length delay is exactly transparent.
pub const Delay = struct {
    data: []f32,
    channels_count: u16,
    cursor: usize = 0,
    pub fn init(allocator: std.mem.Allocator, frames: u32, count: u16) !Delay {
        const data = try allocator.alloc(f32, try channels.sampleCount(frames, count));
        @memset(data, 0);
        return .{ .data = data, .channels_count = count };
    }
    pub fn deinit(self: *Delay, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
        self.* = undefined;
    }
    pub fn process(self: *Delay, input: []const f32, output: []f32) void {
        std.debug.assert(input.len == self.channels_count and output.len == self.channels_count);
        if (self.data.len == 0) {
            @memmove(output, input);
            return;
        }
        for (0..input.len) |i| {
            const x = input[i];
            output[i] = self.data[self.cursor + i];
            self.data[self.cursor + i] = x;
        }
        self.cursor = (self.cursor + input.len) % self.data.len;
    }
};
const ch_layout = channels.ChannelLayout;
pub const CompressorSnapshot = struct {
    preset: SidechainPreset = .{},
    detector_layout: ch_layout = @import("sme-channels").mono,
    preset_id: u32,
    rms_window_frames: u32,
    peak_window_frames: u32,
    meter_window_frames: u32,
    lookahead_frames: u32,
    latency_frames: u32,
    detector: DetectorSnapshot = .{},
    signal_reduction_db: f32 = 0,
    automation_reduction_db: f32 = 0,
    applied_signal_reduction_db: f32 = 0,
    applied_automation_reduction_db: f32 = 0,
    applied_makeup_db: f32 = 0,
    bypass_wet: f32 = 1,
    invalid_program_samples: u64 = 0,
    combined_reduction_db: f32 = 0,
    applied_gain: f32 = 1,
    meter: MeterSnapshot = .{},
    completed_meter: MeterSnapshot = .{},
};
pub const Compressor = struct {
    preset: SidechainPreset,
    detector: Detector,
    lookahead: Delay,
    meter: Meter,
    reduction_db: f32 = 0,
    hold_remaining: u32 = 0,
    bypass: bool = false,
    snapshot: CompressorSnapshot,
    pub fn stateBytes(preset: SidechainPreset, count: u16) usize {
        return Detector.stateBytes(preset) + @as(usize, preset.lookahead_frames) * count * @sizeOf(f32);
    }
    pub fn init(allocator: std.mem.Allocator, program: channels.ChannelLayout, detector_layout: channels.ChannelLayout, preset: SidechainPreset) !Compressor {
        try program.validate();
        var detector = try Detector.init(allocator, detector_layout, preset);
        errdefer detector.deinit(allocator);
        const delay = try Delay.init(allocator, preset.lookahead_frames, program.count);
        return .{ .preset = preset, .detector = detector, .lookahead = delay, .meter = try Meter.init(preset.meter_window_frames), .snapshot = .{ .preset = preset, .detector_layout = detector_layout, .preset_id = preset.id, .rms_window_frames = preset.rms_window_frames, .peak_window_frames = preset.peak_window_frames, .meter_window_frames = preset.meter_window_frames, .lookahead_frames = preset.lookahead_frames, .latency_frames = preset.lookahead_frames, .detector = detector.snapshot, .meter = .{ .window_frames = preset.meter_window_frames }, .completed_meter = .{ .window_frames = preset.meter_window_frames } } };
    }
    pub fn deinit(self: *Compressor, allocator: std.mem.Allocator) void {
        self.detector.deinit(allocator);
        self.lookahead.deinit(allocator);
        self.* = undefined;
    }
    pub fn process(self: *Compressor, detector_frame: []const f32, program: []const f32, output: []f32, automation_db: f32) void {
        self.processWet(detector_frame, program, output, automation_db, 1);
    }
    pub fn processWet(self: *Compressor, detector_frame: []const f32, program: []const f32, output: []f32, automation_db: f32, wet: f32) void {
        const detector = self.detector.process(detector_frame);
        const target = requestedReduction(levelDb(detector.envelope), self.preset);
        if (target >= self.reduction_db) {
            self.reduction_db = smoothDb(self.reduction_db, target, self.preset.attack_frames);
            self.hold_remaining = self.preset.hold_frames;
        } else if (self.hold_remaining > 0) {
            self.hold_remaining -= 1;
        } else {
            self.reduction_db = smoothDb(self.reduction_db, target, self.preset.release_frames);
        }
        const automation = if (std.math.isFinite(automation_db)) std.math.clamp(automation_db, 0, self.preset.automation_cap_db) else 0;
        const effective_wet = if (self.bypass or !std.math.isFinite(wet)) 0 else std.math.clamp(wet, 0, 1);
        const applied_automation = @min(automation, self.preset.combined_cap_db);
        const applied_signal = @min(self.reduction_db * effective_wet, self.preset.combined_cap_db - applied_automation);
        const combined = applied_automation + applied_signal;
        const makeup = self.preset.makeup_db * effective_wet;
        const gain = dbToLinear(makeup - combined);
        var clean: [channels.max_channels]f32 = undefined;
        for (program, 0..) |sample, i| {
            clean[i] = if (std.math.isFinite(sample)) sample else blk: {
                self.snapshot.invalid_program_samples +|= 1;
                break :blk 0;
            };
        }
        self.lookahead.process(clean[0..program.len], output);
        for (output) |*sample| {
            sample.* *= gain;
            if (!std.math.isFinite(sample.*)) {
                sample.* = 0;
                self.snapshot.invalid_program_samples +|= 1;
            }
        }
        self.meter.observeFrame(output);
        self.snapshot.preset = self.preset;
        self.snapshot.detector = detector;
        self.snapshot.signal_reduction_db = self.reduction_db;
        self.snapshot.automation_reduction_db = automation;
        self.snapshot.applied_signal_reduction_db = applied_signal;
        self.snapshot.applied_automation_reduction_db = applied_automation;
        self.snapshot.applied_makeup_db = makeup;
        self.snapshot.bypass_wet = effective_wet;
        self.snapshot.combined_reduction_db = combined;
        self.snapshot.applied_gain = gain;
        self.snapshot.meter = self.meter.partialSnapshot();
        self.snapshot.completed_meter = self.meter.completed;
    }
};

pub const CombineMode = enum { strongest, additive, priority };
pub const DuckAutomationTarget = struct {
    id: u32,
    reduction_db: f32,
    priority: i16 = 0,
    authored_order: u32 = 0,
    attack_frames: u32 = 480,
    hold_frames: u32 = 2400,
    release_frames: u32 = 4800,
    pub fn validate(self: DuckAutomationTarget) Error!void {
        try inRange(self.reduction_db, 0, 96);
        if (self.attack_frames > 48000 or self.hold_frames > 480000 or self.release_frames > 480000) return error.InvalidParameter;
    }
};
const Duck = struct {
    terminal_cell: ?*duck_lifetime.Cell = null,
    end_requested: bool = false,
    target: DuckAutomationTarget,
    elapsed: u64 = 0,
    releasing: bool = false,
    release_start: f32 = 0,
    value: f32 = 0,
    fn next(self: *Duck) ?f32 {
        if (self.releasing) {
            if (self.elapsed >= self.target.release_frames) return null;
            self.elapsed += 1;
            self.value = self.release_start * (1 - @as(f32, @floatFromInt(self.elapsed)) / @as(f32, @floatFromInt(self.target.release_frames)));
            return self.value;
        }
        if (self.elapsed < self.target.attack_frames) {
            self.elapsed += 1;
            self.value = self.target.reduction_db * @as(f32, @floatFromInt(self.elapsed)) / @as(f32, @floatFromInt(self.target.attack_frames));
            return self.value;
        }
        if (self.elapsed < @as(u64, self.target.attack_frames) + self.target.hold_frames) {
            self.elapsed += 1;
            self.value = self.target.reduction_db;
            return self.value;
        }
        self.releasing = true;
        self.release_start = self.target.reduction_db;
        self.elapsed = 0;
        return self.next();
    }
};
pub const Automation = struct {
    pub const capacity = 8;
    requests: [capacity]?Duck = @splat(null),
    mode: CombineMode = .strongest,
    cap_db: f32 = 12,
    pub fn hasTracked(self: *const Automation) bool {
        for (self.requests) |request| if (request) |duck| if (duck.terminal_cell != null) return true;
        return false;
    }
    pub fn count(self: *const Automation) usize {
        var n: usize = 0;
        for (self.requests) |r| if (r != null) {
            n += 1;
        };
        return n;
    }
    pub fn begin(self: *Automation, target: DuckAutomationTarget) Error!void {
        return self.beginTracked(target, null);
    }
    /// A stable cell is supplied only by the admitted lifetime owner. Trial
    /// automations use null; no preflight can publish a terminal.
    pub fn beginTracked(self: *Automation, target: DuckAutomationTarget, cell: ?*duck_lifetime.Cell) Error!void {
        try target.validate();
        for (self.requests) |r| if (r) |d| {
            if (d.target.id == target.id) return error.DuplicateRequest;
        };
        for (&self.requests) |*r| if (r.* == null) {
            r.* = .{ .target = target, .terminal_cell = cell };
            return;
        };
        return error.TooManyRequests;
    }
    pub fn end(self: *Automation, id: u32) Error!void {
        return self.endAt(id, null);
    }
    /// Null is the historical/untracked or Trial path, with no publication.
    pub fn endAt(self: *Automation, id: u32, frame: ?u64) Error!void {
        for (&self.requests) |*r| if (r.*) |*d| {
            if (d.target.id == id) {
                if (d.target.release_frames == 0) {
                    const cell = d.terminal_cell;
                    r.* = null;
                    if (frame) |at| if (cell) |terminal| terminal.publish(.ended, at, at);
                    return;
                }
                d.end_requested = true;
                d.releasing = true;
                d.release_start = d.value;
                d.elapsed = 0;
                return;
            }
        };
        return error.UnknownRequest;
    }
    pub fn process(self: *Automation) f32 {
        return self.processAt(null);
    }
    fn removed(request: Duck, frame: ?u64) void {
        if (request.terminal_cell) |cell| {
            // Tracked processing requires the actual render coordinate and a
            // representable next frontier. Runtime spans guarantee both.
            const at = frame orelse unreachable;
            std.debug.assert(at < std.math.maxInt(u64));
            cell.publish(if (request.end_requested) .ended else .expired, at, at + 1);
        }
    }
    /// Graph detach is an actual removal independent of automation duration.
    pub fn detachTracked(self: *Automation, frame: u64) void {
        for (&self.requests) |*request| if (request.*) |duck| if (duck.terminal_cell) |cell| {
            request.* = null;
            cell.publish(.graph_retired, frame, frame);
        };
    }
    pub fn processAt(self: *Automation, frame: ?u64) f32 {
        var combined: f32 = 0;
        var priority: i32 = std.math.minInt(i32);
        var chosen_order: u32 = std.math.maxInt(u32);
        var chosen_id: u32 = std.math.maxInt(u32);
        for (&self.requests) |*r| if (r.*) |*d| {
            const value = d.next() orelse {
                const removed_request = d.*;
                r.* = null;
                removed(removed_request, frame);
                continue;
            };
            switch (self.mode) {
                .strongest => combined = @max(combined, value),
                .additive => combined += value,
                .priority => if (d.target.priority > priority or (d.target.priority == priority and (d.target.authored_order < chosen_order or (d.target.authored_order == chosen_order and d.target.id < chosen_id)))) {
                    priority = d.target.priority;
                    chosen_order = d.target.authored_order;
                    chosen_id = d.target.id;
                    combined = value;
                },
            }
            if (d.releasing and d.elapsed == d.target.release_frames) {
                const removed_request = d.*;
                r.* = null;
                removed(removed_request, frame);
            }
        };
        return @min(combined, self.cap_db);
    }
};
