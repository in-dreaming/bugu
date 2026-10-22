//! TASK-007 deterministic tempo compiler. Seconds-linear ramps are integrated
//! offline, never approximated by interpolation between materialized beats.
const std = @import("std");
pub const s = @import("sme-bank").schema;
const clock = @import("sme-clock");
const compiler = @import("sme-compiler");
pub const Error = s.BankError || std.mem.Allocator.Error;
pub const encoded_region_limit: u32 = 65_536;
pub const encoded_grid_limit: u32 = 16_777_216;
pub const maximum_duration_frames: u64 = 48_000 * 60 * 60 * 24;
pub const fixed_fraction_bits = 128;
const scale: u256 = @as(u256, 1) << fixed_fraction_bits;

pub const MeterChange = struct { tick: u64 = 0, numerator: u8 = 4, denominator: u8 = 4, beat_groups: []const u8 = &.{} };
pub const Source = struct {
    header: s.Tempo = .{},
    regions: []const s.TempoSpan,
    meters: []const MeterChange = &.{.{}},
    anchors: []const s.Anchor = &.{},
    cues: []const s.Cue = &.{},
};
pub const Budget = struct {
    max_regions: u32 = 4096,
    max_grid_entries: u32 = 1_048_576,
    max_peak_bytes: u64 = 128 * 1024 * 1024,
};
pub const Report = struct {
    ppq: u16,
    beat_unit: s.TempoBeatUnit = .quarter_note,
    ramp_domain: s.TempoRampDomain = .seconds,
    rounding: s.TempoRounding = .nearest_ties_even,
    fraction_bits: u16 = fixed_fraction_bits,
    regions: u32,
    query_spans: u32,
    rational_spans: u32,
    materialized_ticks: u32,
    beat_entries: u32,
    bar_entries: u32,
    resolved_groups: u32,
    /// Borrowed from Compiled.arena, just like the numeric runtime tables.
    resolved_meters: []const s.TempoMeter,
    beat_groups: []const u8,
    max_grid_entries: u32,
    estimated_peak_bytes: u64,
    total_frames: u64,
    loop_frames: u64,
};
pub const Compiled = struct {
    arena: std.heap.ArenaAllocator,
    tables: s.Tables,
    report: Report,
    profile: s.Platform,
    pub fn deinit(self: *Compiled) void {
        self.arena.deinit();
        self.* = undefined;
    }
    pub fn map(self: *const Compiled) clock.Error!clock.Map {
        return clock.Map.init(self.tables, 0, self.tables.cues, self.profile);
    }
};
fn gcd(a_: u256, b_: u256) u256 {
    var a = a_;
    var b = b_;
    while (b != 0) {
        const r = a % b;
        a = b;
        b = r;
    }
    return a;
}
fn narrow(v: u512) ?u256 {
    return if (v > std.math.maxInt(u256)) null else @intCast(v);
}
const Rational = struct {
    n: u256,
    d: u256,
    fn init(n: u256, d: u256) Rational {
        const g = gcd(n, d);
        return .{ .n = n / g, .d = d / g };
    }
    fn integer(n: u64) Rational {
        return .{ .n = n, .d = 1 };
    }
    fn plus(a: Rational, b: Rational) ?Rational {
        const g = gcd(a.d, b.d);
        const sum = @addWithOverflow(@as(u512, a.n) * (b.d / g), @as(u512, b.n) * (a.d / g));
        if (sum[1] != 0) return null;
        const n = sum[0];
        const d: u512 = @as(u512, a.d) * (b.d / g);
        const common = gcd(@intCast(n % g), g);
        const nn = narrow(n / common) orelse return null;
        const dd = narrow(d / common) orelse return null;
        return init(nn, dd);
    }
    fn minus(a: Rational, b: Rational) ?Rational {
        const g = gcd(a.d, b.d);
        const left = @as(u512, a.n) * (b.d / g);
        const right = @as(u512, b.n) * (a.d / g);
        if (left < right) return null;
        const common = gcd(@intCast((left - right) % g), g);
        const nn = narrow((left - right) / common) orelse return null;
        const dd = narrow(@as(u512, a.d) * (b.d / g) / common) orelse return null;
        return init(nn, dd);
    }
    fn times(a: Rational, b: Rational) ?Rational {
        const g1 = gcd(a.n, b.d);
        const g2 = gcd(b.n, a.d);
        const n = narrow(@as(u512, a.n / g1) * (b.n / g2)) orelse return null;
        const d = narrow(@as(u512, a.d / g2) * (b.d / g1)) orelse return null;
        return init(n, d);
    }
    fn divided(a: Rational, b: Rational) ?Rational {
        if (b.n == 0) return null;
        return a.times(.{ .n = b.d, .d = b.n });
    }
    fn interval(a: Rational) Interval {
        const n = @as(u512, a.n) * scale;
        const lo: u256 = @intCast(n / a.d);
        return .{ .lo = lo, .hi = lo + @intFromBool(n % a.d != 0) };
    }
    fn rounded(a: Rational) Error!u64 {
        return clock.roundRational(a.n, a.d) catch return error.InvalidTempo;
    }
};
const Interval = struct {
    lo: u256,
    hi: u256,
    fn plus(a: Interval, b: Interval) Interval {
        return .{ .lo = a.lo + b.lo, .hi = a.hi + b.hi };
    }
    fn rounded(a: Interval) Error!u64 {
        const lo = clock.roundRational(a.lo, scale) catch return error.InvalidTempo;
        const hi = clock.roundRational(a.hi, scale) catch return error.InvalidTempo;
        if (lo != hi) return error.InvalidTempo; // Never guess at an uncertified half-sample.
        return lo;
    }
};
const Value = struct {
    interval: Interval,
    exact: ?Rational,
    fn from(r: Rational) Value {
        return .{ .interval = r.interval(), .exact = r };
    }
    fn rounded(v: Value) Error!u64 {
        return if (v.exact) |r| r.rounded() else v.interval.rounded();
    }
};
fn duration(region: s.TempoSpan, ppq: u16) Rational {
    return Rational.init(@as(u256, 48_000) * 120_000 * (region.end_tick - region.start_tick), @as(u256, ppq) * (region.start_milli_bpm + region.end_milli_bpm));
}
fn integerSqrt(value: u256) u256 {
    if (value < 2) return value;
    const bits: usize = 256 - @as(usize, @intCast(@clz(value)));
    const rounds = (bits + 1) / 2;
    var lo: u256 = 0;
    var hi: u256 = @as(u256, 1) << @as(u8, @intCast(rounds));
    for (0..rounds) |_| {
        const mid = lo + (hi - lo) / 2;
        if (mid * mid <= value) lo = mid else hi = mid;
    }
    return lo;
}
const Model = struct {
    source: Source,
    origins: []Value,
    endpoints: []s.Anchor,
    anchor_values: []Value,
    fn regionAt(self: Model, tick: u64) usize {
        var lo: usize = 0;
        var hi = self.source.regions.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.source.regions[mid].start_tick <= tick) lo = mid + 1 else hi = mid;
        }
        return lo - 1;
    }
    fn nominal(self: Model, tick: u64) Value {
        const index = self.regionAt(tick);
        const region = self.source.regions[index];
        const origin = self.origins[index];
        const count = region.end_tick - region.start_tick;
        const delta = tick - region.start_tick;
        const d = duration(region, self.source.header.ppq);
        var local: Value = undefined;
        if (delta == 0) return origin;
        if (delta == count) local = Value.from(d) else if (region.start_milli_bpm == region.end_milli_bpm) {
            local = Value.from(d.times(Rational.init(delta, count)).?);
        } else {
            const b0: u256 = region.start_milli_bpm;
            const b1: u256 = region.end_milli_bpm;
            // D = b0^2 + (b1^2-b0^2)*tick_fraction. All terms here
            // are nonnegative after weighting; no cancellation or signed overflow.
            const discriminant = b0 * b0 * (count - delta) + b1 * b1 * delta;
            const root = integerSqrt(discriminant * count);
            if (root * root == discriminant * count) {
                const x = Rational.init((b0 + b1) * delta, b0 * count + root);
                local = Value.from(d.times(x).?);
            } else {
                var lo: u256 = 0;
                var hi = scale;
                const target = @as(u512, b0 + b1) * delta * scale * scale;
                for (0..fixed_fraction_bits) |_| {
                    const mid = lo + (hi - lo) / 2;
                    const integrated = (@as(u512, b0) * mid * (2 * scale - mid) + @as(u512, b1) * mid * mid) * count;
                    if (integrated <= target) lo = mid else hi = mid;
                }
                const low = @as(u512, d.n) * lo;
                const high = @as(u512, d.n) * hi;
                local = .{ .exact = null, .interval = .{ .lo = @intCast(low / d.d), .hi = @intCast(high / d.d + @intFromBool(high % d.d != 0)) } };
            }
        }
        const exact = if (origin.exact != null and local.exact != null) origin.exact.?.plus(local.exact.?) else null;
        return if (exact) |r| Value.from(r) else .{ .interval = origin.interval.plus(local.interval), .exact = null };
    }
    fn anchorAt(self: Model, tick: u64) usize {
        var lo: usize = 0;
        var hi = self.endpoints.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.endpoints[mid].tick <= tick) lo = mid + 1 else hi = mid;
        }
        return @min(lo - 1, self.endpoints.len - 2);
    }
    fn corrected(self: Model, tick: u64) Error!Value {
        const value = self.nominal(tick);
        if (self.source.anchors.len == 0) return value;
        const i = self.anchorAt(tick);
        const a = self.endpoints[i];
        const b = self.endpoints[i + 1];
        if (tick == a.tick) return Value.from(Rational.integer(a.frame));
        if (tick == b.tick) return Value.from(Rational.integer(b.frame));
        const va = self.anchor_values[i];
        const vb = self.anchor_values[i + 1];
        if (value.exact != null and va.exact != null and vb.exact != null) {
            const offset = value.exact.?.minus(va.exact.?) orelse return error.InvalidTempo;
            const length = vb.exact.?.minus(va.exact.?) orelse return error.InvalidTempo;
            const factor = Rational.integer(b.frame - a.frame).divided(length) orelse return error.InvalidTempo;
            const result = Rational.integer(a.frame).plus(offset.times(factor) orelse return error.InvalidTempo) orelse return error.InvalidTempo;
            return Value.from(result);
        }
        // Interval arithmetic around A + (N(t)-N(A))*(B-A)/(N(B)-N(A)).
        // This is precisely elapsed-time proportional residual redistribution.
        if (vb.interval.lo <= va.interval.hi or value.interval.lo < va.interval.hi) return error.InvalidTempo;
        const length_lo = vb.interval.lo - va.interval.hi;
        const length_hi = vb.interval.hi - va.interval.lo;
        const offset_lo = value.interval.lo - va.interval.hi;
        const offset_hi = value.interval.hi - va.interval.lo;
        const low = @as(u512, offset_lo) * (b.frame - a.frame) * scale;
        const high = @as(u512, offset_hi) * (b.frame - a.frame) * scale;
        return .{ .exact = null, .interval = .{
            .lo = @as(u256, a.frame) * scale + @as(u256, @intCast(low / length_hi)),
            .hi = @as(u256, a.frame) * scale + @as(u256, @intCast(high / length_lo + @intFromBool(high % length_lo != 0))),
        } };
    }
};
fn anchorFits(value: Value, frame: u64) bool {
    if (value.exact) |r| {
        const target = @as(u512, frame) * r.d;
        const difference = if (target > r.n) target - r.n else r.n - target;
        return difference < r.d;
    }
    const target = @as(u256, frame) * scale;
    const below = if (target > value.interval.lo) target - value.interval.lo else 0;
    const above = if (value.interval.hi > target) value.interval.hi - target else 0;
    return @max(below, above) < scale;
}
fn resolveGroups(m: MeterChange, buffer: *[32]u8) Error![]const u8 {
    if (m.numerator == 0 or m.numerator > 32 or !(m.denominator == 1 or m.denominator == 2 or m.denominator == 4 or m.denominator == 8 or m.denominator == 16 or m.denominator == 32)) return error.InvalidMeter;
    if (m.beat_groups.len != 0) {
        if (m.beat_groups.len > 32) return error.InvalidMeter;
        var total: u16 = 0;
        for (m.beat_groups) |group| {
            if (group == 0) return error.InvalidMeter;
            total += group;
        }
        if (total != m.numerator) return error.InvalidMeter;
        return m.beat_groups;
    }
    if (m.denominator == 8 and (m.numerator == 6 or m.numerator == 9 or m.numerator == 12)) {
        const n = m.numerator / 3;
        @memset(buffer[0..n], 3);
        return buffer[0..n];
    }
    if (m.numerator > 4) return error.AmbiguousBeatGrouping;
    @memset(buffer[0..m.numerator], 1);
    return buffer[0..m.numerator];
}
fn budgetCheck(grid: u64, budget: Budget) Error!void {
    if (grid > budget.max_grid_entries or grid > encoded_grid_limit) return error.InvalidTempo;
}
fn appendGrid(list: ?*std.ArrayList(s.Grid), allocator: std.mem.Allocator, tick: u64, ordinal: u64, span: u32, count: *u64, budget: Budget) Error!void {
    count.* += 1;
    try budgetCheck(count.*, budget);
    if (list) |values| try values.append(allocator, .{ .tick = tick, .ordinal = ordinal, .span = span });
}
/// Same bounded traversal first counts (without grid allocation), then emits.
const GridCounts = struct { beats: usize, bars: usize };
fn grids(source: Source, meters: []const s.TempoMeter, groups: []const u8, allocator: std.mem.Allocator, beats: ?*std.ArrayList(s.Grid), bars: ?*std.ArrayList(s.Grid), count: *u64, budget: Budget) Error!GridCounts {
    const total = source.regions[source.regions.len - 1].end_tick;
    var bar_ordinal: u64 = 0;
    var beat_ordinal: u64 = 0;
    var span: u32 = 0;
    for (meters, 0..) |meter, meter_index| {
        const end = if (meter_index + 1 < meters.len) meters[meter_index + 1].tick else total;
        const unit = @as(u64, source.header.ppq) * 4 / meter.denominator;
        const length = unit * meter.numerator;
        const pulse_groups = groups[meter.groups.first..][0..meter.groups.count];
        var bar_tick = meter.tick;
        while (bar_tick < end or (bar_tick == end and meter_index + 1 == meters.len)) {
            while (span + 1 < source.regions.len and source.regions[span + 1].start_tick <= bar_tick) span += 1;
            try appendGrid(bars, allocator, bar_tick, bar_ordinal, span, count, budget);
            bar_ordinal += 1;
            const pickup = bar_tick == 0 and source.header.pickup_ticks > 0;
            const bar_length = if (pickup) source.header.pickup_ticks else length;
            const omitted = if (pickup) length - bar_length else 0;
            var phase: u64 = 0;
            for (pulse_groups, 0..) |group, pulse_index| {
                _ = pulse_index;
                if (phase >= omitted) {
                    const tick = bar_tick + phase - omitted;
                    if (tick <= total and (tick < end or meter_index + 1 == meters.len)) {
                        var pulse_span = span;
                        while (pulse_span + 1 < source.regions.len and source.regions[pulse_span + 1].start_tick <= tick) pulse_span += 1;
                        try appendGrid(beats, allocator, tick, beat_ordinal, pulse_span, count, budget);
                        beat_ordinal += 1;
                    }
                } else if (phase + unit * group > omitted) {
                    // The beginning of a partial pickup pulse is a real boundary.
                    try appendGrid(beats, allocator, bar_tick, beat_ordinal, span, count, budget);
                    beat_ordinal += 1;
                }
                phase += unit * group;
            }
            if (bar_tick == end or bar_length > end - bar_tick) break;
            bar_tick += bar_length;
        }
    }
    return .{ .beats = @intCast(beat_ordinal), .bars = @intCast(bar_ordinal) };
}
fn queryFromRational(start: u64, end: u64, origin: Rational, step: Rational) Error!s.TempoQuery {
    const g = gcd(origin.d, step.d);
    const d = narrow(@as(u512, origin.d) * (step.d / g)) orelse return error.InvalidTempo;
    const n = narrow(@as(u512, origin.n) * (step.d / g)) orelse return error.InvalidTempo;
    const increment = narrow(@as(u512, step.n) * (origin.d / g)) orelse return error.InvalidTempo;
    return .{ .start_tick = start, .end_tick = end, .kind = .rational, .origin_numerator = n, .step_numerator = increment, .denominator = d };
}
fn frameFromQueries(queries: []const s.TempoQuery, frames: []const u64, tick: u64) Error!u64 {
    var lo: usize = 0;
    var hi = queries.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (queries[mid].start_tick <= tick) lo = mid + 1 else hi = mid;
    }
    if (lo == 0) return error.InvalidTempo;
    const q = queries[lo - 1];
    const offset = tick - q.start_tick;
    if (tick > q.end_tick) return error.InvalidTempo;
    return switch (q.kind) {
        .rational => clock.roundRational(@as(u512, q.origin_numerator) + @as(u512, offset) * q.step_numerator, q.denominator) catch return error.InvalidTempo,
        .materialized => frames[q.frames.first + @as(usize, @intCast(offset))],
    };
}
pub fn compile(allocator: std.mem.Allocator, source: Source, budget: Budget) Error!Compiled {
    if (source.header.ppq < 24 or source.header.ppq > 9600 or source.header.ppq % 24 != 0 or source.regions.len == 0 or source.regions.len > budget.max_regions or budget.max_regions == 0 or budget.max_regions > encoded_region_limit or budget.max_grid_entries == 0 or budget.max_grid_entries > s.Limits.grid_entries or budget.max_peak_bytes == 0) return error.InvalidTempo;
    if (source.meters.len == 0 or source.meters.len > budget.max_regions or source.anchors.len > encoded_region_limit or source.cues.len > encoded_region_limit) return error.InvalidTempo;
    if (source.header.loop_present > 1) return error.NonClosingLoop;
    // A small bounded metadata stage precedes the exact full peak preflight.
    const metadata_peak = @as(u64, source.regions.len) * (@sizeOf(Value) + @sizeOf(s.TempoSpan) + @sizeOf(s.TempoQuery) * 4) + @as(u64, source.anchors.len + 2) * (@sizeOf(Value) + @sizeOf(s.Anchor)) + @as(u64, source.meters.len) * (@sizeOf(s.TempoMeter) + 32) * 3;
    if (metadata_peak > budget.max_peak_bytes) return error.InvalidTempo;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const origins = try a.alloc(Value, source.regions.len);
    var running = Value.from(Rational.integer(0));
    var previous_tick: u64 = 0;
    for (source.regions, 0..) |region, i| {
        if (region.start_tick != previous_tick or region.end_tick <= region.start_tick or region.start_milli_bpm < 1000 or region.start_milli_bpm > 1_000_000 or region.end_milli_bpm < 1000 or region.end_milli_bpm > 1_000_000 or (region.curve == .constant and region.start_milli_bpm != region.end_milli_bpm)) return error.InvalidTempo;
        origins[i] = running;
        const d = duration(region, source.header.ppq);
        const value = Value.from(d);
        const exact = if (running.exact) |r| r.plus(d) else null;
        running = if (exact) |r| Value.from(r) else .{ .interval = running.interval.plus(value.interval), .exact = null };
        if (running.interval.hi > @as(u256, maximum_duration_frames) * scale) return error.InvalidTempo;
        previous_tick = region.end_tick;
    }
    const total_ticks = previous_tick;
    if (source.header.total_ticks != 0 and source.header.total_ticks != total_ticks) return error.InvalidTempo;
    const maximum_ticks = @as(u64, 24 * 60 * 1000) * source.header.ppq;
    if (total_ticks > maximum_ticks) return error.InvalidTempo;
    var meter_list: std.ArrayList(s.TempoMeter) = .empty;
    var group_list: std.ArrayList(u8) = .empty;
    for (source.meters, 0..) |meter, i| {
        var group_buffer: [32]u8 = undefined;
        const resolved = try resolveGroups(meter, &group_buffer);
        if (meter.tick >= total_ticks or (i == 0 and meter.tick != 0)) return error.InvalidMeter;
        if (i > 0) {
            const prev = source.meters[i - 1];
            if (meter.tick <= prev.tick) return error.InvalidMeter;
            const first_full = if (i == 1 and source.header.pickup_ticks > 0) source.header.pickup_ticks else prev.tick;
            const prev_length = @as(u64, source.header.ppq) * 4 * prev.numerator / prev.denominator;
            if (meter.tick < first_full or (meter.tick - first_full) % prev_length != 0) return error.InvalidMeter;
        }
        try meter_list.append(a, .{ .tick = meter.tick, .numerator = meter.numerator, .denominator = meter.denominator, .groups = .{ .first = @intCast(group_list.items.len), .count = @intCast(resolved.len) } });
        try group_list.appendSlice(a, resolved);
    }
    const first_meter = source.meters[0];
    const first_bar_length = @as(u64, source.header.ppq) * 4 * first_meter.numerator / first_meter.denominator;
    if (source.header.pickup_ticks >= first_bar_length or source.header.pickup_ticks > total_ticks) return error.InvalidMeter;
    var model: Model = .{ .source = source, .origins = origins, .endpoints = &.{}, .anchor_values = &.{} };
    var endpoints: std.ArrayList(s.Anchor) = .empty;
    if (source.anchors.len > 0) {
        if (source.anchors[0].tick != 0) try endpoints.append(a, .{ .tick = 0, .frame = 0 });
        for (source.anchors, 0..) |anchor, i| {
            if (anchor.tick > total_ticks or anchor.frame > maximum_duration_frames or (i > 0 and (anchor.tick <= source.anchors[i - 1].tick or anchor.frame <= source.anchors[i - 1].frame))) return error.AnchorMismatch;
            if (!anchorFits(model.nominal(anchor.tick), anchor.frame)) return error.AnchorMismatch;
            try endpoints.append(a, anchor);
        }
        if (endpoints.items[endpoints.items.len - 1].tick != total_ticks) try endpoints.append(a, .{ .tick = total_ticks, .frame = try running.rounded() });
        if (endpoints.items.len < 2) return error.AnchorMismatch;
        for (endpoints.items[1..], 0..) |anchor, i| if (anchor.frame <= endpoints.items[i].frame) return error.AnchorMismatch;
        model.endpoints = endpoints.items;
        model.anchor_values = try a.alloc(Value, endpoints.items.len);
        for (endpoints.items, model.anchor_values) |anchor, *value| value.* = model.nominal(anchor.tick);
    }
    var queries: std.ArrayList(s.TempoQuery) = .empty;
    var materialized_count: u64 = 0;
    var rational_count: u32 = 0;
    var tick: u64 = 0;
    while (tick < total_ticks) {
        const region = source.regions[model.regionAt(tick)];
        var end = region.end_tick;
        if (source.anchors.len > 0) end = @min(end, model.endpoints[model.anchorAt(tick) + 1].tick);
        if (queries.items.len >= budget.max_regions) return error.InvalidTempo;
        const corrected_origin = try model.corrected(tick);
        const ai = if (source.anchors.len > 0) model.anchorAt(tick) else 0;
        const exact_anchors = source.anchors.len == 0 or (model.anchor_values[ai].exact != null and model.anchor_values[ai + 1].exact != null);
        if (region.start_milli_bpm == region.end_milli_bpm and corrected_origin.exact != null and exact_anchors) {
            const origin = corrected_origin.exact.?;
            var step = Rational.init(@as(u256, 48_000) * 60_000, @as(u256, source.header.ppq) * region.start_milli_bpm);
            if (source.anchors.len > 0) {
                const length = model.anchor_values[ai + 1].exact.?.minus(model.anchor_values[ai].exact.?) orelse return error.InvalidTempo;
                step = step.times(Rational.integer(model.endpoints[ai + 1].frame - model.endpoints[ai].frame).divided(length) orelse return error.InvalidTempo) orelse return error.InvalidTempo;
            }
            try queries.append(a, try queryFromRational(tick, end, origin, step));
            rational_count += 1;
        } else {
            const count = end - tick + 1;
            materialized_count += count;
            try budgetCheck(materialized_count, budget);
            try queries.append(a, .{ .start_tick = tick, .end_tick = end, .kind = .materialized, .frames = .{ .first = @intCast(materialized_count - count), .count = @intCast(count) } });
        }
        tick = end;
    }
    var total_entries = materialized_count;
    const grid_counts = try grids(source, meter_list.items, group_list.items, a, null, null, &total_entries, budget);
    // ArrayLists retain old arena blocks on growth: x3 is a conservative bound.
    const estimated_peak = 65_536 + 2 * (metadata_peak + materialized_count * @sizeOf(u64) + (total_entries - materialized_count) * @sizeOf(s.Grid) + @as(u64, source.cues.len) * @sizeOf(s.Cue) * 2 + @as(u64, queries.items.len) * @sizeOf(s.TempoQuery) * 3);
    if (estimated_peak > budget.max_peak_bytes) return error.InvalidTempo;
    const frames = try a.alloc(u64, @intCast(materialized_count));
    for (queries.items) |query| if (query.kind == .materialized) {
        var previous: u64 = 0;
        for (frames[query.frames.first..][0..query.frames.count], 0..) |*frame, i| {
            frame.* = try (try model.corrected(query.start_tick + i)).rounded();
            if (i > 0 and frame.* < previous) return error.AnchorMismatch;
            previous = frame.*;
        }
    };
    var beats: std.ArrayList(s.Grid) = .empty;
    var bars: std.ArrayList(s.Grid) = .empty;
    try beats.ensureTotalCapacityPrecise(a, grid_counts.beats);
    try bars.ensureTotalCapacityPrecise(a, grid_counts.bars);
    var written_count = materialized_count;
    _ = try grids(source, meter_list.items, group_list.items, a, &beats, &bars, &written_count, budget);
    for ([_][]s.Grid{ beats.items, bars.items }) |grid| {
        var previous: u64 = 0;
        for (grid, 0..) |*entry, i| {
            entry.frame = try frameFromQueries(queries.items, frames, entry.tick);
            if (i > 0 and entry.frame <= previous) return error.AnchorMismatch;
            previous = entry.frame;
        }
    }
    const spans = try a.dupe(s.TempoSpan, source.regions);
    var mi: usize = 0;
    for (spans) |*span| {
        while (mi + 1 < meter_list.items.len and meter_list.items[mi + 1].tick <= span.start_tick) mi += 1;
        const m = meter_list.items[mi];
        span.start_frame = try frameFromQueries(queries.items, frames, span.start_tick);
        span.end_frame = try frameFromQueries(queries.items, frames, span.end_tick);
        span.numerator = m.numerator;
        span.denominator = m.denominator;
        span.groups = m.groups;
    }
    const cues = try a.dupe(s.Cue, source.cues);
    std.mem.sort(s.Cue, cues, {}, struct {
        fn less(_: void, x: s.Cue, y: s.Cue) bool {
            return if (x.tick == y.tick) x.key.id < y.key.id else x.tick < y.tick;
        }
    }.less);
    var cue_ids: std.AutoHashMapUnmanaged(u64, void) = .empty;
    for (cues) |*cue| {
        if (cue.key.id == 0 or cue.tick > total_ticks) return error.InvalidTempo;
        const result = try cue_ids.getOrPut(a, cue.key.id);
        if (result.found_existing) return error.IdCollision;
        cue.frame = try frameFromQueries(queries.items, frames, cue.tick);
    }
    const tempos = try a.alloc(s.Tempo, 1);
    tempos[0] = source.header;
    tempos[0].total_ticks = total_ticks;
    tempos[0].total_frames = try frameFromQueries(queries.items, frames, total_ticks);
    tempos[0].spans = .{ .count = @intCast(spans.len) };
    tempos[0].beats = .{ .count = @intCast(beats.items.len) };
    tempos[0].bars = .{ .count = @intCast(bars.items.len) };
    tempos[0].anchors = .{ .count = @intCast(source.anchors.len) };
    tempos[0].meters = .{ .count = @intCast(meter_list.items.len) };
    tempos[0].queries = .{ .count = @intCast(queries.items.len) };
    const tables: s.Tables = .{ .tempos = tempos, .tempo_spans = spans, .tempo_meters = meter_list.items, .tempo_queries = queries.items, .tempo_tick_frames = frames, .beat_groups = group_list.items, .beats = beats.items, .bars = bars.items, .anchors = try a.dupe(s.Anchor, source.anchors), .cues = cues };
    var result: Compiled = .{ .arena = arena, .tables = tables, .profile = .{ .max_tempo_spans = budget.max_regions, .max_grid_entries = budget.max_grid_entries }, .report = .{ .ppq = source.header.ppq, .regions = @intCast(spans.len), .query_spans = @intCast(queries.items.len), .rational_spans = rational_count, .materialized_ticks = @intCast(materialized_count), .beat_entries = @intCast(beats.items.len), .bar_entries = @intCast(bars.items.len), .resolved_groups = @intCast(group_list.items.len), .resolved_meters = meter_list.items, .beat_groups = group_list.items, .max_grid_entries = budget.max_grid_entries, .estimated_peak_bytes = estimated_peak, .total_frames = tempos[0].total_frames, .loop_frames = 0 } };
    if (source.header.loop_present == 1) {
        const start = source.header.loop_start_tick;
        const end = source.header.loop_end_tick;
        if (start >= end or end > total_ticks or (start == 0 and source.header.pickup_ticks > 0)) return error.NonClosingLoop;
        var start_bar = false;
        var end_bar = false;
        for (bars.items) |bar| {
            if (bar.tick == start) start_bar = true;
            if (bar.tick == end) end_bar = true;
        }
        if (!start_bar or !end_bar) return error.NonClosingLoop;
        // Inspect the produced metadata directly here so the compiler retains
        // its specific NonClosingLoop diagnostic before runtime Map validation.
        var sm = meter_list.items[0];
        var em = meter_list.items[0];
        for (meter_list.items) |meter| {
            if (meter.tick <= start) sm = meter;
            if (meter.tick <= end) em = meter;
        }
        if (sm.numerator != em.numerator or sm.denominator != em.denominator or !std.mem.eql(u8, group_list.items[sm.groups.first..][0..sm.groups.count], group_list.items[em.groups.first..][0..em.groups.count])) return error.NonClosingLoop;
        const start_frame = try frameFromQueries(queries.items, frames, start);
        const end_frame = try frameFromQueries(queries.items, frames, end);
        if (end_frame <= start_frame) return error.NonClosingLoop;
        result.report.loop_frames = end_frame - start_frame;
    }
    try @import("sme-bank").tempo_validation.validate(result.tables, result.profile, result.tables.tempos[0]);
    return result;
}

fn sourceSlice(comptime T: type, values: []const T, r: s.Range) Error![]const T {
    const end = @as(u64, r.first) + r.count;
    if (end > values.len) return error.InvalidTempo;
    return values[r.first..@intCast(end)];
}
fn sourceFor(allocator: std.mem.Allocator, tables: s.Tables, index: usize) Error!Source {
    const header = tables.tempos[index];
    const regions = try sourceSlice(s.TempoSpan, tables.tempo_spans, header.spans);
    var meters: std.ArrayList(MeterChange) = .empty;
    if (header.meters.count > 0) {
        for (try sourceSlice(s.TempoMeter, tables.tempo_meters, header.meters)) |meter| try meters.append(allocator, .{ .tick = meter.tick, .numerator = meter.numerator, .denominator = meter.denominator, .beat_groups = try sourceSlice(u8, tables.beat_groups, meter.groups) });
    } else {
        // Legacy authored span meter fields remain a source-compatible spelling.
        // Only actual meter changes are emitted; a ramp's tempo boundary does
        // not introduce a fake bar boundary when its meter is unchanged.
        for (regions) |region_| {
            const groups = try sourceSlice(u8, tables.beat_groups, region_.groups);
            if (meters.items.len > 0) {
                const previous = meters.items[meters.items.len - 1];
                if (previous.numerator == region_.numerator and previous.denominator == region_.denominator and std.mem.eql(u8, previous.beat_groups, groups)) continue;
            }
            try meters.append(allocator, .{ .tick = region_.start_tick, .numerator = region_.numerator, .denominator = region_.denominator, .beat_groups = groups });
        }
    }
    return .{ .header = header, .regions = regions, .meters = meters.items, .anchors = try sourceSlice(s.Anchor, tables.anchors, header.anchors) };
}
fn profileBudget(profile: s.Platform) Budget {
    return .{ .max_regions = profile.max_tempo_spans, .max_grid_entries = profile.max_grid_entries, .max_peak_bytes = @min(profile.max_bank_bytes, 128 * 1024 * 1024) };
}
/// Register the real tempo producer and source-bound verifier. Registration
/// cannot certify another missing compiler pass or unrelated media products.
pub fn install(registry: *compiler.Registry) compiler.CompileError!void {
    try registry.registerPass(.tempo, runPass);
    try registry.registerValidator(.tempos, validateCompiledSource);
}
/// Counts actual backing allocations, including arena growth and retained old
/// blocks, relative to the pre-pass baseline. The wrapper lives only during
/// this synchronous pass; child_allocator is restored before returning.
const PassQuota = struct {
    backing: std.mem.Allocator,
    limit: u64,
    delta: i128 = 0,
    peak: u64 = 0,
    exceeded: bool = false,
    fn allocator(self: *PassQuota) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = std.mem.Allocator.noRemap, .free = free } };
    }
    fn permits(self: *PassQuota, change: i128) bool {
        if (self.delta + change > self.limit) {
            self.exceeded = true;
            return false;
        }
        return true;
    }
    fn record(self: *PassQuota, change: i128) void {
        self.delta += change;
        if (self.delta > self.peak) self.peak = @intCast(self.delta);
    }
    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *PassQuota = @ptrCast(@alignCast(context));
        if (!self.permits(len)) return null;
        const ptr = self.backing.rawAlloc(len, alignment, ret) orelse return null;
        self.record(len);
        return ptr;
    }
    fn resize(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, len: usize, ret: usize) bool {
        const self: *PassQuota = @ptrCast(@alignCast(context));
        const change = @as(i128, len) - bytes.len;
        if (!self.permits(change) or !self.backing.rawResize(bytes, alignment, len, ret)) return false;
        self.record(change);
        return true;
    }
    fn free(context: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ret: usize) void {
        const self: *PassQuota = @ptrCast(@alignCast(context));
        self.record(-@as(i128, bytes.len));
        self.backing.rawFree(bytes, alignment, ret);
    }
};
pub fn runPass(owned: *compiler.OwnedIR, ast: *const compiler.SourceAST) compiler.CompileError!void {
    if (ast.metadata.profile >= ast.tables.platforms.len) return error.InvalidTempo;
    var quota: PassQuota = .{ .backing = owned.arena.child_allocator, .limit = profileBudget(ast.tables.platforms[ast.metadata.profile]).max_peak_bytes };
    owned.arena.child_allocator = quota.allocator();
    defer owned.arena.child_allocator = quota.backing;
    runPassWithinQuota(owned, ast) catch |err| {
        if (err == error.OutOfMemory and quota.exceeded) return error.InvalidTempo;
        return err;
    };
}
fn runPassWithinQuota(owned: *compiler.OwnedIR, ast: *const compiler.SourceAST) compiler.CompileError!void {
    if (ast.metadata.profile >= ast.tables.platforms.len) return error.InvalidTempo;
    const profile = ast.tables.platforms[ast.metadata.profile];
    const a = owned.arena.allocator();
    var tempos: std.ArrayList(s.Tempo) = .empty;
    var spans: std.ArrayList(s.TempoSpan) = .empty;
    var meters: std.ArrayList(s.TempoMeter) = .empty;
    var queries: std.ArrayList(s.TempoQuery) = .empty;
    var frames: std.ArrayList(u64) = .empty;
    var beats: std.ArrayList(s.Grid) = .empty;
    var bars: std.ArrayList(s.Grid) = .empty;
    var anchors: std.ArrayList(s.Anchor) = .empty;
    var groups: std.ArrayList(u8) = .empty;
    var aggregate: u64 = 0;
    for (ast.tables.tempos, 0..) |_, index| {
        const source = try sourceFor(a, ast.tables, index);
        var compiled = try compile(a, source, profileBudget(profile));
        defer compiled.deinit();
        aggregate += @as(u64, compiled.report.materialized_ticks) + compiled.report.beat_entries + compiled.report.bar_entries;
        if (aggregate > profile.max_grid_entries or spans.items.len + compiled.tables.tempo_spans.len > profile.max_tempo_spans or queries.items.len + compiled.tables.tempo_queries.len > profile.max_tempo_spans or meters.items.len + compiled.tables.tempo_meters.len > profile.max_tempo_spans) return error.InvalidTempo;
        var header = compiled.tables.tempos[0];
        header.spans.first = @intCast(spans.items.len);
        header.meters.first = @intCast(meters.items.len);
        header.queries.first = @intCast(queries.items.len);
        header.beats.first = @intCast(beats.items.len);
        header.bars.first = @intCast(bars.items.len);
        header.anchors.first = @intCast(anchors.items.len);
        const group_offset: u32 = @intCast(groups.items.len);
        const frame_offset: u32 = @intCast(frames.items.len);
        for (compiled.tables.tempo_spans) |entry| {
            var copy = entry;
            copy.groups.first += group_offset;
            try spans.append(a, copy);
        }
        for (compiled.tables.tempo_meters) |entry| {
            var copy = entry;
            copy.groups.first += group_offset;
            try meters.append(a, copy);
        }
        for (compiled.tables.tempo_queries) |entry| {
            var copy = entry;
            if (copy.kind == .materialized) copy.frames.first += frame_offset;
            try queries.append(a, copy);
        }
        for (compiled.tables.beats) |entry| {
            var copy = entry;
            copy.span += header.spans.first;
            try beats.append(a, copy);
        }
        for (compiled.tables.bars) |entry| {
            var copy = entry;
            copy.span += header.spans.first;
            try bars.append(a, copy);
        }
        try frames.appendSlice(a, compiled.tables.tempo_tick_frames);
        try anchors.appendSlice(a, compiled.tables.anchors);
        try groups.appendSlice(a, compiled.tables.beat_groups);
        try tempos.append(a, header);
    }
    var next_tables = owned.ir.tables;
    const tables = &next_tables;
    tables.tempos = tempos.items;
    tables.tempo_spans = spans.items;
    tables.tempo_meters = meters.items;
    tables.tempo_queries = queries.items;
    tables.tempo_tick_frames = frames.items;
    tables.beats = beats.items;
    tables.bars = bars.items;
    tables.anchors = anchors.items;
    tables.beat_groups = groups.items;
    const cues = try a.dupe(s.Cue, tables.cues);
    for (cues) |*cue| {
        if (cue.segment >= tables.segments.len) return error.InvalidReference;
        const tempo_index = tables.segments[cue.segment].tempo;
        if (tempo_index >= tables.tempos.len) return error.InvalidTempo;
        const header = tables.tempos[tempo_index];
        if (cue.tick > header.total_ticks) return error.InvalidTempo;
        cue.frame = try frameFromQueries(try sourceSlice(s.TempoQuery, tables.tempo_queries, header.queries), tables.tempo_tick_frames, cue.tick);
    }
    tables.cues = cues;
    owned.ir.tables = next_tables;
}
/// The pipeline's validator recompiles authored tempo inputs and compares the
/// derived values after all registered passes have run. It catches later pass
/// mutations without trusting authored grids or forged precomputed queries.
pub fn validateCompiledSource(allocator: std.mem.Allocator, ast: *const compiler.SourceAST, ir: *const s.ValidatedIR) compiler.CompileError!void {
    if (ir.metadata.profile != ast.metadata.profile or ir.metadata.profile >= ir.tables.platforms.len or ast.tables.tempos.len != ir.tables.tempos.len) return error.InvalidTempo;
    const profile = ir.tables.platforms[ir.metadata.profile];
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    for (ast.tables.tempos, 0..) |_, index| {
        const source = try sourceFor(scratch.allocator(), ast.tables, index);
        var expected = try compile(allocator, source, profileBudget(profile));
        defer expected.deinit();
        const actual = ir.tables.tempos[index];
        const wanted = expected.tables.tempos[0];
        if (actual.key.id != wanted.key.id or actual.ppq != wanted.ppq or actual.total_ticks != wanted.total_ticks or actual.total_frames != wanted.total_frames or actual.pickup_ticks != wanted.pickup_ticks or actual.loop_present != wanted.loop_present or actual.loop_start_tick != wanted.loop_start_tick or actual.loop_end_tick != wanted.loop_end_tick) return error.InvalidTempo;
        const actual_spans = try sourceSlice(s.TempoSpan, ir.tables.tempo_spans, actual.spans);
        if (actual_spans.len != expected.tables.tempo_spans.len) return error.InvalidTempo;
        for (actual_spans, expected.tables.tempo_spans) |span, expected_span| {
            if (span.start_tick != expected_span.start_tick or span.end_tick != expected_span.end_tick or span.start_frame != expected_span.start_frame or span.end_frame != expected_span.end_frame or span.start_milli_bpm != expected_span.start_milli_bpm or span.end_milli_bpm != expected_span.end_milli_bpm or span.curve != expected_span.curve or span.numerator != expected_span.numerator or span.denominator != expected_span.denominator or !std.mem.eql(u8, try sourceSlice(u8, ir.tables.beat_groups, span.groups), try sourceSlice(u8, expected.tables.beat_groups, expected_span.groups))) return error.InvalidTempo;
        }
        const qs = try sourceSlice(s.TempoQuery, ir.tables.tempo_queries, actual.queries);
        if (qs.len != expected.tables.tempo_queries.len) return error.InvalidTempo;
        for (qs, expected.tables.tempo_queries) |q, eq| {
            if (q.start_tick != eq.start_tick or q.end_tick != eq.end_tick or q.kind != eq.kind or q.origin_numerator != eq.origin_numerator or q.step_numerator != eq.step_numerator or q.denominator != eq.denominator or q.frames.count != eq.frames.count) return error.InvalidTempo;
            if (q.kind == .materialized and !std.mem.eql(u64, try sourceSlice(u64, ir.tables.tempo_tick_frames, q.frames), try sourceSlice(u64, expected.tables.tempo_tick_frames, eq.frames))) return error.InvalidTempo;
        }
        const actual_meters = try sourceSlice(s.TempoMeter, ir.tables.tempo_meters, actual.meters);
        if (actual_meters.len != expected.tables.tempo_meters.len) return error.InvalidTempo;
        for (actual_meters, expected.tables.tempo_meters) |m, em| if (m.tick != em.tick or m.numerator != em.numerator or m.denominator != em.denominator or !std.mem.eql(u8, try sourceSlice(u8, ir.tables.beat_groups, m.groups), try sourceSlice(u8, expected.tables.beat_groups, em.groups))) return error.InvalidTempo;
        const actual_anchors = try sourceSlice(s.Anchor, ir.tables.anchors, actual.anchors);
        if (!std.meta.eql(actual_anchors.len, expected.tables.anchors.len)) return error.InvalidTempo;
        for (actual_anchors, expected.tables.anchors) |anchor, expected_anchor| if (!std.meta.eql(anchor, expected_anchor)) return error.InvalidTempo;
        try @import("sme-bank").tempo_validation.validate(ir.tables, profile, actual);
    }
}
