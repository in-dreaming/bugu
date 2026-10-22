//! Control-only bounded lowering to the existing group-layer-gain primitive.
//! No map is retained; all returned spans contain owned scalar values.
const std = @import("std");
const clock = @import("sme-clock");
const contract = @import("sme-layer-contract");
pub const Error = clock.Error || error{ InvalidDuration, UnsupportedFractionalTick, UnsupportedTempoAutomation, UnsupportedLoopAutomation, TimelineBudgetExceeded, UnsafeFrameRange, InvalidGain };
pub const capacity = 32;
pub const Span = struct {
    start_frame: u64,
    end_frame: u64,
    from: f32,
    to: f32,
    pub fn frames(self: Span) u32 {
        return @intCast(self.end_frame - self.start_frame);
    }
    pub fn valueAt(self: Span, frame: u64) f32 {
        if (frame >= self.end_frame) return self.to;
        if (frame <= self.start_frame) return self.from;
        const t = @as(f64, @floatFromInt(frame - self.start_frame)) / @as(f64, @floatFromInt(self.end_frame - self.start_frame));
        return @floatCast(@as(f64, self.from) + (@as(f64, self.to) - self.from) * t);
    }
};
pub const Timeline = struct {
    spans: [capacity]Span = undefined,
    count: u16 = 0,
    rounded_instant: bool = false,
    pub fn items(self: *const Timeline) []const Span {
        return self.spans[0..self.count];
    }
    fn append(self: *Timeline, span: Span, limit: u16) Error!void {
        if (self.count >= limit or self.count >= capacity) return error.TimelineBudgetExceeded;
        self.spans[self.count] = span;
        self.count += 1;
    }
};
pub const MusicalStart = struct { map: clock.Map, tick: u64 };
fn add(a: u64, b: u64) Error!u64 {
    return std.math.add(u64, a, b) catch error.UnsafeFrameRange;
}
fn interpolate(a: f32, b: f32, n: u64, d: u64) f32 {
    if (n == d) return b;
    return @floatCast(@as(f64, a) + (@as(f64, b) - a) * (@as(f64, @floatFromInt(n)) / @as(f64, @floatFromInt(d))));
}
fn segment(result: *Timeline, start: u64, end: u64, from: f32, to: f32, limit: u16) Error!void {
    const length = end - start;
    if (length == 0) {
        // A collapsed internal knot would need a seed plus a start at one frame.
        // M1 rejects that case rather than dropping a required value silently.
        return error.UnsupportedTempoAutomation;
    }
    var offset: u64 = 0;
    while (offset < length) {
        const next = offset + @min(length - offset, std.math.maxInt(u32));
        try result.append(.{ .start_frame = try add(start, offset), .end_frame = try add(start, next), .from = interpolate(from, to, offset, length), .to = interpolate(from, to, next, length) }, limit);
        offset = next;
    }
}
pub fn compile(start_frame: u64, from: f32, to: f32, duration: contract.Duration, musical: ?MusicalStart, limit: u16) Error!Timeline {
    _ = try contract.validateGain(from, .reject);
    _ = try contract.validateGain(to, .reject);
    if (limit == 0 or limit > capacity) return error.TimelineBudgetExceeded;
    var result: Timeline = .{};
    switch (duration) {
        .frames => |frames| {
            const end = try add(start_frame, frames);
            if (frames == 0) try result.append(.{ .start_frame = start_frame, .end_frame = start_frame, .from = from, .to = to }, limit) else try segment(&result, start_frame, end, from, to, limit);
        },
        .quarter_beats => |q| {
            if (q.denominator == 0) return error.InvalidDuration;
            const position = musical orelse return error.InvalidDuration;
            const map = position.map;
            if (map.tempo.loop_present != 0) return error.UnsupportedLoopAutomation;
            const product = @as(u128, q.numerator) * map.tempo.ppq;
            if (product % q.denominator != 0) return error.UnsupportedFractionalTick;
            const ticks128 = product / q.denominator;
            if (ticks128 > std.math.maxInt(u64)) return error.UnsafeFrameRange;
            const ticks: u64 = @intCast(ticks128);
            const end_tick = try add(position.tick, ticks);
            if (end_tick > map.tempo.total_ticks) return error.OutOfRange;
            const origin = try map.frameAtTick(position.tick);
            const endpoint = try map.frameAtTick(end_tick);
            _ = try add(start_frame, endpoint - origin);
            // Explicitly reject varying/materialized queries even if rounding
            // happens to collapse their endpoints to one frame.
            for (map.queries) |query| {
                if (query.end_tick > position.tick and query.start_tick < end_tick and query.kind != .rational) return error.UnsupportedTempoAutomation;
            }
            for (map.spans) |span| {
                if (span.end_tick > position.tick and span.start_tick < end_tick and (span.curve != .constant or span.start_milli_bpm != span.end_milli_bpm)) return error.UnsupportedTempoAutomation;
            }
            if (ticks == 0 or endpoint == origin) {
                _ = try add(start_frame, 65);
                result.rounded_instant = ticks != 0;
                try result.append(.{ .start_frame = start_frame, .end_frame = start_frame, .from = from, .to = to }, limit);
                return result;
            }
            var tick = position.tick;
            while (tick < end_tick) {
                var next = end_tick;
                for (map.queries) |query| if (query.end_tick > tick) {
                    next = @min(next, query.end_tick);
                };
                for (map.spans) |span| if (span.end_tick > tick) {
                    next = @min(next, span.end_tick);
                };
                const a = try map.frameAtTick(tick);
                const b = try map.frameAtTick(next);
                try segment(&result, try add(start_frame, a - origin), try add(start_frame, b - origin), interpolate(from, to, tick - position.tick, ticks), interpolate(from, to, next - position.tick, ticks), limit);
                tick = next;
            }
        },
    }
    // The production schedule needs [start,end) plus its commit-span safety tail.
    const end = result.spans[result.count - 1].end_frame;
    _ = try add(end, 65);
    return result;
}
