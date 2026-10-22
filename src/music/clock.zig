//! Integer-only musical queries and transport. No allocation, floating point,
//! wall clock or quantum phase integration is used by this module.
const std = @import("std");
pub const schema = @import("sme-bank").schema;
const s = schema;
pub const Error = error{ InvalidTempo, OutOfRange, ClockPaused, InvalidState, DeviceDiscontinuity, NonClosingLoop };
pub const MusicalPosition = struct { tick: u64, bar: i64, beat: u8, subdivision: u64, loop_epoch: u64 = 0 };
pub const BoundaryKind = enum { beat, bar, cue };
/// The caller supplies the real scheduler's earliest still-submittable frame.
/// This is an observation, not a reservation: the scheduler's admission gate
/// remains authoritative if Render advances after this query.
pub const SchedulingFrontier = struct { earliest_submit_frame: u64 };
pub const Boundary = struct { frame: u64, tick: u64, ordinal: u64, loop_epoch: u64 };

fn add(a: u64, b: u64) Error!u64 {
    const r = @addWithOverflow(a, b);
    if (r[1] != 0) return error.OutOfRange;
    return r[0];
}
fn mul(a: u64, b: u64) Error!u64 {
    const r = @mulWithOverflow(a, b);
    if (r[1] != 0) return error.OutOfRange;
    return r[0];
}
pub fn roundRational(n: u512, d: u512) Error!u64 {
    if (d == 0) return error.InvalidTempo;
    const q = n / d;
    const r = n % d;
    const up = r > d - r or (r == d - r and q & 1 == 1);
    if (q > std.math.maxInt(u64) or (up and q == std.math.maxInt(u64))) return error.OutOfRange;
    return @as(u64, @intCast(q)) + @intFromBool(up);
}
fn slice(comptime T: type, items: []const T, range: s.Range) Error![]const T {
    const end = @as(u64, range.first) + range.count;
    if (end > items.len) return error.InvalidTempo;
    return items[range.first..@intCast(end)];
}
/// A borrowed view. The owning validated MusicBank/Compiled must outlive it.
/// init performs one-time allocation-free compiled-table validation, including
/// musical grids and cue consistency. Individual real-time queries use that
/// established invariant; source-curve certification belongs to the compiler.
pub const Map = struct {
    tempo: s.Tempo,
    spans: []const s.TempoSpan,
    meters: []const s.TempoMeter,
    groups: []const u8,
    queries: []const s.TempoQuery,
    tick_frames: []const u64,
    beats: []const s.Grid,
    bars: []const s.Grid,
    cues: []const s.Cue,
    pub fn init(tables: s.Tables, tempo_index: u32, cues: []const s.Cue, profile: s.Platform) Error!Map {
        if (tempo_index >= tables.tempos.len) return error.InvalidTempo;
        const t = tables.tempos[tempo_index];
        @import("sme-bank").tempo_validation.validate(tables, profile, t) catch return error.InvalidTempo;
        if (cues.len > 65_536) return error.InvalidTempo;
        for (cues, 0..) |cue, i| {
            if (cue.tick > t.total_ticks or cue.frame > t.total_frames or (i > 0 and (cue.tick < cues[i - 1].tick or cue.frame < cues[i - 1].frame))) return error.InvalidTempo;
        }
        const result: Map = .{
            .tempo = t,
            .spans = try slice(s.TempoSpan, tables.tempo_spans, t.spans),
            .meters = try slice(s.TempoMeter, tables.tempo_meters, t.meters),
            .groups = tables.beat_groups,
            .queries = try slice(s.TempoQuery, tables.tempo_queries, t.queries),
            .tick_frames = tables.tempo_tick_frames,
            .beats = try slice(s.Grid, tables.beats, t.beats),
            .bars = try slice(s.Grid, tables.bars, t.bars),
            .cues = cues,
        };
        if (result.queries.len == 0 or result.meters.len == 0 or result.bars.len == 0) return error.InvalidTempo;
        for (cues) |cue| if (cue.frame != try result.frameAtTick(cue.tick)) return error.InvalidTempo;
        return result;
    }
    fn queryAt(self: Map, tick: u64) Error!s.TempoQuery {
        if (tick > self.tempo.total_ticks) return error.OutOfRange;
        var lo: usize = 0;
        var hi = self.queries.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.queries[mid].start_tick <= tick) lo = mid + 1 else hi = mid;
        }
        if (lo == 0) return error.InvalidTempo;
        const q = self.queries[lo - 1];
        if (tick > q.end_tick) return error.InvalidTempo;
        return q;
    }
    pub fn frameAtTick(self: Map, tick: u64) Error!u64 {
        const q = try self.queryAt(tick);
        const delta = tick - q.start_tick;
        return switch (q.kind) {
            .rational => roundRational(@as(u512, q.origin_numerator) + @as(u512, delta) * q.step_numerator, q.denominator),
            .materialized => blk: {
                const values = try slice(u64, self.tick_frames, q.frames);
                if (delta >= values.len) return error.InvalidTempo;
                break :blk values[@intCast(delta)];
            },
        };
    }
    /// Floor is defined on the rounded tick mapping, including duplicate tick
    /// frames: return the greatest tick whose rounded frame is <= frame.
    pub fn tickAtFrame(self: Map, frame: u64) Error!u64 {
        if (frame > self.tempo.total_frames) return error.OutOfRange;
        var lo: u64 = 0;
        var hi = self.tempo.total_ticks;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2 + (hi - lo) % 2;
            if (try self.frameAtTick(mid) <= frame) lo = mid else hi = mid - 1;
        }
        return lo;
    }
    pub fn meterAtTick(self: Map, tick: u64) Error!s.TempoMeter {
        if (tick > self.tempo.total_ticks) return error.OutOfRange;
        var lo: usize = 0;
        var hi = self.meters.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.meters[mid].tick <= tick) lo = mid + 1 else hi = mid;
        }
        if (lo == 0) return error.InvalidTempo;
        return self.meters[lo - 1];
    }
    pub fn positionAtFrame(self: Map, frame: u64) Error!MusicalPosition {
        const tick = try self.tickAtFrame(frame);
        const bar_index = floorGridTick(self.bars, tick) orelse return error.InvalidTempo;
        const bar = self.bars[bar_index];
        const meter = try self.meterAtTick(tick);
        const groups = try slice(u8, self.groups, meter.groups);
        const unit = @as(u64, self.tempo.ppq) * 4 / meter.denominator;
        var offset = tick - bar.tick;
        if (bar.ordinal == 0 and self.tempo.pickup_ticks > 0) offset += unit * meter.numerator - self.tempo.pickup_ticks;
        var pulse: u8 = 0;
        while (pulse + 1 < groups.len and offset >= unit * groups[pulse]) : (pulse += 1) offset -= unit * groups[pulse];
        if (bar.ordinal > std.math.maxInt(i64)) return error.OutOfRange;
        return .{ .tick = tick, .bar = @as(i64, @intCast(bar.ordinal)) - @as(i64, @intFromBool(self.tempo.pickup_ticks > 0)), .beat = pulse, .subdivision = offset };
    }
    pub fn frameAtBeat(self: Map, ordinal: u64) Error!u64 {
        if (ordinal >= self.beats.len) return error.OutOfRange;
        return self.beats[@intCast(ordinal)].frame;
    }
    pub fn frameAtBar(self: Map, bar: i64) Error!u64 {
        const shifted = @as(i128, bar) + @intFromBool(self.tempo.pickup_ticks > 0);
        if (shifted < 0 or shifted >= self.bars.len) return error.OutOfRange;
        return self.bars[@intCast(shifted)].frame;
    }
    /// Cue IDs are resolved to a bank index by the caller; time tables stay
    /// chronological so frame->cue and strict-next are binary searches.
    pub fn frameAtCue(self: Map, index: u32) Error!u64 {
        if (index >= self.cues.len) return error.OutOfRange;
        return self.cues[index].frame;
    }
    pub fn cueAtFrame(self: Map, frame: u64) Error!u32 {
        if (frame > self.tempo.total_frames) return error.OutOfRange;
        var lo: usize = 0;
        var hi = self.cues.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.cues[mid].frame <= frame) lo = mid + 1 else hi = mid;
        }
        if (lo == 0) return error.OutOfRange;
        return @intCast(lo - 1);
    }
    fn lowerBoundary(self: Map, kind: BoundaryKind, frame: u64) ?Boundary {
        const len = switch (kind) {
            .beat => self.beats.len,
            .bar => self.bars.len,
            .cue => self.cues.len,
        };
        var lo: usize = 0;
        var hi = len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const f = switch (kind) {
                .beat => self.beats[mid].frame,
                .bar => self.bars[mid].frame,
                .cue => self.cues[mid].frame,
            };
            if (f < frame) lo = mid + 1 else hi = mid;
        }
        if (lo == len) return null;
        return switch (kind) {
            .beat => .{ .frame = self.beats[lo].frame, .tick = self.beats[lo].tick, .ordinal = self.beats[lo].ordinal, .loop_epoch = 0 },
            .bar => .{ .frame = self.bars[lo].frame, .tick = self.bars[lo].tick, .ordinal = self.bars[lo].ordinal, .loop_epoch = 0 },
            .cue => .{ .frame = self.cues[lo].frame, .tick = self.cues[lo].tick, .ordinal = lo, .loop_epoch = 0 },
        };
    }
    pub fn strictNext(self: Map, kind: BoundaryKind, accepted_frame: u64, frontier: SchedulingFrontier) Error!Boundary {
        const minimum = @max(try add(accepted_frame, 1), frontier.earliest_submit_frame);
        return self.lowerBoundary(kind, minimum) orelse error.OutOfRange;
    }
};
fn floorGridTick(grid: []const s.Grid, tick: u64) ?usize {
    var lo: usize = 0;
    var hi = grid.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (grid[mid].tick <= tick) lo = mid + 1 else hi = mid;
    }
    return if (lo == 0) null else lo - 1;
}
pub const DiscontinuityPolicy = enum {
    /// Absolute generated render frames remain the musical timeline.
    advance_render_gap,
    /// Resume from the last generated position at the new explicit frontier.
    preserve_position,
};
pub const Clock = struct {
    map: Map,
    anchor_render: u64,
    anchor_elapsed: u64 = 0,
    paused: bool = false,
    transport_epoch: u64 = 1,
    device_epoch: u64 = 1,
    pub fn init(map: Map, render_frame: u64) Clock {
        return .{ .map = map, .anchor_render = render_frame };
    }
    pub fn elapsedAt(self: Clock, render_frame: u64) Error!u64 {
        if (render_frame < self.anchor_render) return error.DeviceDiscontinuity;
        return if (self.paused) self.anchor_elapsed else add(self.anchor_elapsed, render_frame - self.anchor_render);
    }
    fn loopBounds(self: Clock) Error!struct { start: u64, end: u64, length: u64 } {
        const start = try self.map.frameAtTick(self.map.tempo.loop_start_tick);
        const end = try self.map.frameAtTick(self.map.tempo.loop_end_tick);
        if (end <= start) return error.NonClosingLoop;
        return .{ .start = start, .end = end, .length = end - start };
    }
    pub fn position(self: Clock, render_frame: u64) Error!MusicalPosition {
        var elapsed = try self.elapsedAt(render_frame);
        var epoch: u64 = 0;
        if (self.map.tempo.loop_present == 1) {
            const loop = try self.loopBounds();
            if (elapsed >= loop.start) {
                epoch = (elapsed - loop.start) / loop.length;
                elapsed = loop.start + (elapsed - loop.start) % loop.length;
            }
        }
        var result = try self.map.positionAtFrame(elapsed);
        result.loop_epoch = epoch;
        return result;
    }
    pub fn renderFrameForTick(self: Clock, tick: u64, loop_epoch: u64) Error!u64 {
        if (self.paused) return error.ClockPaused;
        var elapsed = try self.map.frameAtTick(tick);
        if (self.map.tempo.loop_present == 1 and tick >= self.map.tempo.loop_end_tick) return error.OutOfRange;
        if (loop_epoch > 0) {
            if (self.map.tempo.loop_present != 1 or tick < self.map.tempo.loop_start_tick or tick >= self.map.tempo.loop_end_tick) return error.OutOfRange;
            const loop = try self.loopBounds();
            elapsed = try add(elapsed, try mul(loop_epoch, loop.length));
        }
        if (elapsed < self.anchor_elapsed) return error.OutOfRange;
        return add(self.anchor_render, elapsed - self.anchor_elapsed);
    }
    pub fn pause(self: *Clock, frame: u64) Error!void {
        if (self.paused) return error.InvalidState;
        const elapsed = try self.elapsedAt(frame);
        const epoch = try add(self.transport_epoch, 1);
        self.anchor_elapsed = elapsed;
        self.anchor_render = frame;
        self.paused = true;
        self.transport_epoch = epoch;
    }
    pub fn resumeAt(self: *Clock, frame: u64) Error!void {
        if (!self.paused or frame < self.anchor_render) return error.InvalidState;
        const epoch = try add(self.transport_epoch, 1);
        self.anchor_render = frame;
        self.paused = false;
        self.transport_epoch = epoch;
    }
    pub fn seek(self: *Clock, tick: u64, frame: u64) Error!void {
        if (frame < self.anchor_render) return error.DeviceDiscontinuity;
        const elapsed = try self.map.frameAtTick(tick);
        const epoch = try add(self.transport_epoch, 1);
        self.anchor_render = frame;
        self.anchor_elapsed = elapsed;
        self.transport_epoch = epoch;
    }
    /// Device events never use wall time, estimated delivered frames or a
    /// hardware tail to alter musical position. The owner supplies the actual
    /// old/new generated frontiers and an explicit gap policy.
    pub fn deviceDiscontinuity(self: *Clock, old_frontier: u64, new_frontier: u64, next_device_epoch: u64, policy: DiscontinuityPolicy) Error!void {
        if (new_frontier < old_frontier or next_device_epoch <= self.device_epoch) return error.DeviceDiscontinuity;
        var elapsed = try self.elapsedAt(old_frontier);
        if (policy == .advance_render_gap and !self.paused) elapsed = try add(elapsed, new_frontier - old_frontier);
        const epoch = try add(self.transport_epoch, 1);
        self.anchor_elapsed = elapsed;
        self.anchor_render = new_frontier;
        self.device_epoch = next_device_epoch;
        self.transport_epoch = epoch;
    }
    pub fn strictNext(self: Clock, kind: BoundaryKind, accepted_frame: u64, frontier: SchedulingFrontier) Error!Boundary {
        if (self.paused) return error.ClockPaused;
        const minimum = @max(try add(accepted_frame, 1), frontier.earliest_submit_frame);
        const elapsed = try self.elapsedAt(minimum);
        var boundary: Boundary = undefined;
        var target_elapsed: u64 = undefined;
        if (self.map.tempo.loop_present == 1) {
            const loop = try self.loopBounds();
            const epoch: u64 = if (elapsed < loop.start) 0 else (elapsed - loop.start) / loop.length;
            const phase = if (elapsed < loop.start) elapsed else loop.start + (elapsed - loop.start) % loop.length;
            const candidate = self.map.lowerBoundary(kind, phase);
            if (candidate != null and candidate.?.frame < loop.end) {
                boundary = candidate.?;
                boundary.loop_epoch = epoch;
            } else {
                boundary = self.map.lowerBoundary(kind, loop.start) orelse return error.OutOfRange;
                if (boundary.frame >= loop.end) return error.OutOfRange;
                boundary.loop_epoch = try add(epoch, 1);
            }
            target_elapsed = try add(boundary.frame, try mul(boundary.loop_epoch, loop.length));
        } else {
            boundary = self.map.lowerBoundary(kind, elapsed) orelse return error.OutOfRange;
            target_elapsed = boundary.frame;
        }
        if (target_elapsed < self.anchor_elapsed) return error.OutOfRange;
        boundary.frame = try add(self.anchor_render, target_elapsed - self.anchor_elapsed);
        return boundary;
    }
};
