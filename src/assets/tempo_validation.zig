//! Narrow, allocation-free validation of the TASK-007 compiled tempo tables.
//! This is not approval of the whole-bank loader or of unrelated TASK-003 gates.
const std = @import("std");
const s = @import("music_schema.zig");
const Error = s.BankError;
fn take(comptime T: type, items: []const T, r: s.Range) Error![]const T {
    const end = @as(u64, r.first) + r.count;
    if (end > items.len) return error.InvalidTempo;
    return items[r.first..@intCast(end)];
}
fn rounded(n: u512, d: u512) Error!u64 {
    if (d == 0) return error.InvalidTempo;
    const q = n / d;
    const r = n % d;
    const up = r > d - r or (r == d - r and q & 1 == 1);
    if (q > std.math.maxInt(u64) or (up and q == std.math.maxInt(u64))) return error.InvalidTempo;
    return @as(u64, @intCast(q)) + @intFromBool(up);
}
fn queryFrame(q: s.TempoQuery, values: []const u64, tick: u64) Error!u64 {
    if (tick < q.start_tick or tick > q.end_tick) return error.InvalidTempo;
    const delta = tick - q.start_tick;
    return switch (q.kind) {
        .rational => rounded(@as(u512, q.origin_numerator) + @as(u512, delta) * q.step_numerator, q.denominator),
        .materialized => blk: {
            const frames = try take(u64, values, q.frames);
            if (delta >= frames.len) return error.InvalidTempo;
            break :blk frames[@intCast(delta)];
        },
    };
}
fn frameAt(queries: []const s.TempoQuery, values: []const u64, tick: u64) Error!u64 {
    var lo: usize = 0;
    var hi = queries.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (queries[mid].start_tick <= tick) lo = mid + 1 else hi = mid;
    }
    if (lo == 0) return error.InvalidTempo;
    return queryFrame(queries[lo - 1], values, tick);
}
fn checkGridEntry(grid: []const s.Grid, index: *usize, tick: u64, spans: []const s.TempoSpan, first_span: u32, queries: []const s.TempoQuery, frames: []const u64) Error!void {
    if (index.* >= grid.len) return error.InvalidTempo;
    const entry = grid[index.*];
    if (entry.tick != tick or entry.ordinal != index.* or entry.frame != try frameAt(queries, frames, tick)) return error.InvalidTempo;
    if (index.* > 0 and (entry.tick <= grid[index.* - 1].tick or entry.frame <= grid[index.* - 1].frame)) return error.InvalidTempo;
    if (entry.span < first_span or entry.span - first_span >= spans.len) return error.InvalidTempo;
    const span_index = entry.span - first_span;
    const span = spans[span_index];
    if (tick < span.start_tick or tick > span.end_tick or (tick == span.end_tick and span_index + 1 < spans.len)) return error.InvalidTempo;
    index.* += 1;
}
pub fn validate(t: s.Tables, profile: s.Platform, tempo: s.Tempo) Error!void {
    if (tempo.ppq < 24 or tempo.ppq > 9600 or tempo.ppq % 24 != 0 or tempo.total_ticks == 0 or tempo.total_frames == 0 or tempo.total_frames > 4_147_200_000 or tempo.loop_present > 1 or tempo.spans.count == 0 or tempo.spans.count > profile.max_tempo_spans or tempo.spans.count > 65_536 or tempo.queries.count == 0 or tempo.queries.count > profile.max_tempo_spans or tempo.queries.count > 65_536 or tempo.meters.count == 0 or tempo.meters.count > profile.max_tempo_spans or tempo.meters.count > 65_536 or tempo.anchors.count > 65_536) return error.InvalidTempo;
    if (tempo.total_ticks > @as(u64, 24 * 60 * 1000) * tempo.ppq) return error.InvalidTempo;
    const queries = try take(s.TempoQuery, t.tempo_queries, tempo.queries);
    const spans = try take(s.TempoSpan, t.tempo_spans, tempo.spans);
    const meters = try take(s.TempoMeter, t.tempo_meters, tempo.meters);
    const beats = try take(s.Grid, t.beats, tempo.beats);
    const bars = try take(s.Grid, t.bars, tempo.bars);
    const anchors = try take(s.Anchor, t.anchors, tempo.anchors);
    var entries: u64 = @as(u64, beats.len) + bars.len;
    var next_tick: u64 = 0;
    var next_frame: u64 = 0;
    for (queries) |query| {
        if (query.start_tick != next_tick or query.end_tick <= query.start_tick or query.end_tick > tempo.total_ticks) return error.InvalidTempo;
        switch (query.kind) {
            .rational => if (query.denominator == 0 or query.step_numerator == 0 or query.frames.count != 0) return error.InvalidTempo,
            .materialized => {
                if (@as(u64, query.frames.count) != query.end_tick - query.start_tick + 1) return error.InvalidTempo;
                const values = try take(u64, t.tempo_tick_frames, query.frames);
                entries += values.len;
                for (values, 0..) |frame, i| {
                    if (frame > tempo.total_frames or (i > 0 and frame < values[i - 1])) return error.InvalidTempo;
                }
            },
        }
        if (try queryFrame(query, t.tempo_tick_frames, query.start_tick) != next_frame) return error.InvalidTempo;
        next_tick = query.end_tick;
        next_frame = try queryFrame(query, t.tempo_tick_frames, query.end_tick);
        if (next_frame > tempo.total_frames) return error.InvalidTempo;
    }
    if (entries > profile.max_grid_entries or entries > 16_777_216 or next_tick != tempo.total_ticks or next_frame != tempo.total_frames) return error.InvalidTempo;
    next_tick = 0;
    next_frame = 0;
    for (spans) |span| {
        if (span.start_tick != next_tick or span.end_tick <= span.start_tick or span.start_frame != next_frame or span.end_frame < span.start_frame or span.end_tick > tempo.total_ticks or span.start_milli_bpm < 1000 or span.start_milli_bpm > 1_000_000 or span.end_milli_bpm < 1000 or span.end_milli_bpm > 1_000_000 or (span.curve == .constant and span.start_milli_bpm != span.end_milli_bpm)) return error.InvalidTempo;
        if (span.start_frame != try frameAt(queries, t.tempo_tick_frames, span.start_tick) or span.end_frame != try frameAt(queries, t.tempo_tick_frames, span.end_tick)) return error.InvalidTempo;
        next_tick = span.end_tick;
        next_frame = span.end_frame;
    }
    if (next_tick != tempo.total_ticks or next_frame != tempo.total_frames) return error.InvalidTempo;
    for (anchors, 0..) |anchor, i| {
        if (anchor.tick > tempo.total_ticks or anchor.frame != try frameAt(queries, t.tempo_tick_frames, anchor.tick) or (i > 0 and (anchor.tick <= anchors[i - 1].tick or anchor.frame <= anchors[i - 1].frame))) return error.AnchorMismatch;
    }
    var bi: usize = 0;
    var bai: usize = 0;
    for (meters, 0..) |meter, index| {
        if (meter.numerator == 0 or meter.numerator > 32 or meter.denominator == 0 or meter.denominator > 32 or !std.math.isPowerOfTwo(meter.denominator) or meter.groups.count == 0 or meter.groups.count > 32 or (index == 0 and meter.tick != 0) or meter.tick >= tempo.total_ticks) return error.InvalidMeter;
        const groups = try take(u8, t.beat_groups, meter.groups);
        var sum: u16 = 0;
        for (groups) |group| {
            if (group == 0) return error.InvalidMeter;
            sum += group;
        }
        if (sum != meter.numerator) return error.InvalidMeter;
        if (index > 0) {
            const prev = meters[index - 1];
            const length = @as(u64, tempo.ppq) * 4 * prev.numerator / prev.denominator;
            const first_full = if (index == 1 and tempo.pickup_ticks > 0) tempo.pickup_ticks else prev.tick;
            if (meter.tick <= prev.tick or meter.tick < first_full or (meter.tick - first_full) % length != 0) return error.InvalidMeter;
        }
        const unit = @as(u64, tempo.ppq) * 4 / meter.denominator;
        const length = unit * meter.numerator;
        if (index == 0 and (tempo.pickup_ticks >= length or tempo.pickup_ticks > tempo.total_ticks)) return error.InvalidMeter;
        const end = if (index + 1 < meters.len) meters[index + 1].tick else tempo.total_ticks;
        var bar_tick = meter.tick;
        while (bar_tick < end or (bar_tick == end and index + 1 == meters.len)) {
            try checkGridEntry(bars, &bai, bar_tick, spans, tempo.spans.first, queries, t.tempo_tick_frames);
            const pickup = bar_tick == 0 and tempo.pickup_ticks > 0;
            const bar_length = if (pickup) tempo.pickup_ticks else length;
            const omitted = if (pickup) length - bar_length else 0;
            var phase: u64 = 0;
            for (groups) |group| {
                if (phase >= omitted) {
                    const tick = bar_tick + phase - omitted;
                    if (tick <= tempo.total_ticks and (tick < end or index + 1 == meters.len)) try checkGridEntry(beats, &bi, tick, spans, tempo.spans.first, queries, t.tempo_tick_frames);
                } else if (phase + unit * group > omitted) try checkGridEntry(beats, &bi, bar_tick, spans, tempo.spans.first, queries, t.tempo_tick_frames);
                phase += unit * group;
            }
            if (bar_tick == end or bar_length > end - bar_tick) break;
            bar_tick += bar_length;
        }
    }
    if (bi != beats.len or bai != bars.len) return error.InvalidTempo;
    if (tempo.loop_present == 1) {
        if (tempo.loop_start_tick >= tempo.loop_end_tick or tempo.loop_end_tick > tempo.total_ticks or (tempo.loop_start_tick == 0 and tempo.pickup_ticks > 0)) return error.NonClosingLoop;
        var starts = false;
        var ends = false;
        for (bars) |bar| {
            if (bar.tick == tempo.loop_start_tick) starts = true;
            if (bar.tick == tempo.loop_end_tick) ends = true;
        }
        if (!starts or !ends or try frameAt(queries, t.tempo_tick_frames, tempo.loop_start_tick) >= try frameAt(queries, t.tempo_tick_frames, tempo.loop_end_tick)) return error.NonClosingLoop;
        var sm = meters[0];
        var em = meters[0];
        for (meters) |meter| {
            if (meter.tick <= tempo.loop_start_tick) sm = meter;
            if (meter.tick <= tempo.loop_end_tick) em = meter;
        }
        if (sm.numerator != em.numerator or sm.denominator != em.denominator or !std.mem.eql(u8, try take(u8, t.beat_groups, sm.groups), try take(u8, t.beat_groups, em.groups))) return error.NonClosingLoop;
    } else if (tempo.loop_start_tick != 0 or tempo.loop_end_tick != 0) return error.NonClosingLoop;
}

/// Call only after validate when querying an untrusted loaded table set.
pub fn frameForTick(t: s.Tables, tempo: s.Tempo, tick: u64) Error!u64 {
    if (tick > tempo.total_ticks) return error.InvalidTempo;
    return frameAt(try take(s.TempoQuery, t.tempo_queries, tempo.queries), t.tempo_tick_frames, tick);
}

/// The same exact cue binding used by the bank loader and focused clock tests.
pub fn validateCue(t: s.Tables, tempo: s.Tempo, cue: s.Cue) Error!void {
    if (cue.tick > tempo.total_ticks or cue.frame > tempo.total_frames or cue.frame != try frameForTick(t, tempo, cue.tick)) return error.InvalidTempo;
}
