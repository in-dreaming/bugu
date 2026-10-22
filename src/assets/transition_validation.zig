//! Narrow TASK-009 structural/adjacency admission. Tempo/media records are
//! separately admitted dependencies, never a replacement whole-bank review.
const std = @import("std");
pub const s = @import("music_schema.zig");
const tempo_validation = @import("tempo_validation.zig");
pub const Error = s.BankError || std.mem.Allocator.Error;
pub const max_paths: usize = 4096;
pub const max_fill_steps: usize = 16;
pub const max_required_chunks: usize = 256;
pub const max_readiness_references: usize = 48;
pub const compatibility_mask: u32 = 31;
pub const max_direct_loop_tail_frames: u64 = 6144;
pub const TailSpan = struct { first_frame: u64 = 0, end_frame: u64 = 0 };
pub const BoundedDirectTailLayout = struct {
    transition: u32,
    source_exit: u32,
    target_entry: u32,
    fade_frames: u64,
    loop_start: u64,
    loop_end: u64,
    loop_start_tick: u64,
    loop_end_tick: u64,
    onset_cursor: u64,
    spans: [2]TailSpan,
    span_count: u8,
    terminal_cursor: u64,
    terminal_epoch_increment: u8,
    crosses_loop: bool,
};
pub fn items(comptime T: type, all: []const T, range: s.Range) s.BankError![]const T {
    const end = @as(u64, range.first) + range.count;
    if (end > all.len) return error.InvalidReference;
    return all[range.first..@intCast(end)];
}
fn reference(index: u32, len: usize) s.BankError!void {
    if (index >= len) return error.InvalidReference;
}
pub fn isEntry(kind: s.CueKind) bool {
    return kind == .entry or kind == .both or kind == .fill_entry;
}
pub fn isExit(kind: s.CueKind) bool {
    return kind == .exit or kind == .both or kind == .fill_exit;
}
fn lessId(_: void, a: u64, b: u64) bool {
    return a < b;
}
fn names(records: anytype, scratch: []u64) s.BankError!void {
    if (records.len > scratch.len) return error.ResourceLimitExceeded;
    for (records, 0..) |record, i| {
        if (record.key.id == 0) return error.InvalidMusicGraph;
        scratch[i] = record.key.id;
    }
    std.mem.sort(u64, scratch[0..records.len], {}, lessId);
    for (scratch[0..records.len], 0..) |id, i| if (i > 0 and scratch[i - 1] == id) return error.IdCollision;
}
fn gridHas(grid: []const s.Grid, tick: u64) bool {
    var lo: usize = 0;
    var hi = grid.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (grid[mid].tick < tick) lo = mid + 1 else hi = mid;
    }
    return lo < grid.len and grid[lo].tick == tick;
}

fn crossesSourceLoop(segment: s.Segment, source: s.Cue) bool {
    return segment.loop_end > segment.loop_start and source.frame <= segment.loop_end and
        source.tail_frames > segment.loop_end - source.frame;
}

fn hasRequiredStreamedLayer(t: s.Tables, segment_index: u32) s.BankError!bool {
    const segment = t.segments[segment_index];
    for (try items(s.Layer, t.layers, segment.layers)) |layer| {
        if (layer.segment != segment_index or layer.required > 1) return error.InvalidMusicGraph;
        try reference(layer.sound, t.sounds.len);
        if (layer.required == 1 and t.sounds[layer.sound].storage == .streaming) return true;
    }
    return false;
}

/// Resolve an explicit authored relationship without relying on rule.paths:
/// the transitions producer has not generated canonical ranges yet. Canonical
/// admission separately checks those ranges in validate(..., true).
fn directTailOwner(t: s.Tables, candidate: s.TransitionPath, profile: s.Platform) s.BankError!void {
    if (t.transitions.len > max_paths or t.transition_paths.len > max_paths or
        t.fills.len > profile.max_table_records or t.fill_steps.len > profile.max_table_records or
        t.fills.len > s.Limits.records or t.fill_steps.len > s.Limits.records) return error.ResourceLimitExceeded;
    const rule = t.transitions[candidate.transition];
    if (rule.key.id == 0 or candidate.key.id == 0 or rule.source_exit != candidate.source_exit or
        rule.target_entry != candidate.target_entry or rule.fill != s.none or candidate.fill != s.none or
        candidate.handoff != .continuous or rule.fallback != .reject or rule.fallback_segment != s.none)
        return error.InvalidMusicGraph;
    var owners: usize = 0;
    for (t.transitions, 0..) |other, index| {
        try reference(other.source_exit, t.cues.len);
        try reference(other.target_entry, t.cues.len);
        if (other.target_entry == candidate.source_exit) return error.InvalidMusicGraph;
        if (other.source_exit == candidate.source_exit) {
            if (index != candidate.transition) return error.InvalidMusicGraph;
            owners += 1;
        }
    }
    if (owners != 1) return error.InvalidMusicGraph;
    var paths: usize = 0;
    for (t.transition_paths) |other| {
        try reference(other.transition, t.transitions.len);
        try reference(other.source_exit, t.cues.len);
        try reference(other.target_entry, t.cues.len);
        if (other.target_entry == candidate.source_exit) return error.InvalidMusicGraph;
        if (other.transition == candidate.transition) {
            if (!std.meta.eql(other, candidate)) return error.InvalidMusicGraph;
            paths += 1;
        } else if (other.source_exit == candidate.source_exit) return error.InvalidMusicGraph;
    }
    if (paths != 1) return error.InvalidMusicGraph;
    for (t.fills) |route| {
        try reference(route.source_exit, t.cues.len);
        try reference(route.target_entry, t.cues.len);
        _ = try items(s.FillStep, t.fill_steps, route.steps);
        if (route.source_exit == candidate.source_exit or route.target_entry == candidate.source_exit) return error.InvalidMusicGraph;
    }
    for (t.fill_steps) |step| {
        try reference(step.entry, t.cues.len);
        try reference(step.exit, t.cues.len);
        if (step.entry == candidate.source_exit or step.exit == candidate.source_exit) return error.InvalidMusicGraph;
    }
}

fn directTailLayers(t: s.Tables, segment_index: u32) s.BankError!void {
    const segment = t.segments[segment_index];
    if (segment.storage != .streaming or segment.layers.count != 4) return error.InvalidMusicGraph;
    const layers = try items(s.Layer, t.layers, segment.layers);
    for (layers, 0..) |layer, index| {
        try reference(layer.sound, t.sounds.len);
        const sound = t.sounds[layer.sound];
        if (layer.segment != segment_index or layer.required != 1 or layer.source_start != 0 or
            layer.key.id == 0 or sound.key.id == 0 or sound.storage != .streaming or sound.frames != segment.frames)
            return error.InvalidMusicGraph;
        for (layers[0..index]) |prior| if (prior.key.id == layer.key.id) return error.InvalidMusicGraph;
    }
}

fn sameMeter(t: s.Tables, a: s.TempoMeter, b: s.TempoMeter) s.BankError!bool {
    return a.numerator == b.numerator and a.denominator == b.denominator and
        std.mem.eql(u8, try items(u8, t.beat_groups, a.groups), try items(u8, t.beat_groups, b.groups));
}

/// Dependencies have already admitted the tempo map. This adds only the new
/// branch's fixed rate/meter requirement over a half-open physical interval.
fn constantTailInterval(t: s.Tables, segment_index: u32, first: u64, end: u64, bpm: u32, expected_meter: s.TempoMeter) s.BankError!void {
    const tempo = t.tempos[t.segments[segment_index].tempo];
    const spans = try items(s.TempoSpan, t.tempo_spans, tempo.spans);
    var coverage = first;
    for (spans) |region| {
        if (region.end_frame <= first or region.start_frame >= end) continue;
        if (region.start_frame > coverage or region.curve != .constant or
            region.start_milli_bpm != bpm or region.end_milli_bpm != bpm) return error.InvalidMusicGraph;
        coverage = @min(end, region.end_frame);
    }
    if (coverage != end) return error.InvalidMusicGraph;
    const meters = try items(s.TempoMeter, t.tempo_meters, tempo.meters);
    var found = false;
    for (meters, 0..) |value, index| {
        const start = try tempo_validation.frameForTick(t, tempo, value.tick);
        const stop = if (index + 1 < meters.len) try tempo_validation.frameForTick(t, tempo, meters[index + 1].tick) else tempo.total_frames;
        if (stop <= first or start >= end) continue;
        if (!try sameMeter(t, value, expected_meter)) return error.InvalidMusicGraph;
        found = true;
    }
    if (!found) return error.InvalidMusicGraph;
}

/// Pure shared geometry/authoring gate. Existing noncrossing beat mapping and
/// exact-end cursor semantics are retained. Only strict source-loop crossing
/// admits a bounded, explicit four-stream DIRECT source relationship.
pub fn boundedDirectTailLayout(t: s.Tables, candidate: s.TransitionPath, profile: s.Platform) s.BankError!BoundedDirectTailLayout {
    try reference(candidate.transition, t.transitions.len);
    try reference(candidate.source_exit, t.cues.len);
    try reference(candidate.target_entry, t.cues.len);
    const rule = t.transitions[candidate.transition];
    const source = t.cues[candidate.source_exit];
    const target = t.cues[candidate.target_entry];
    try reference(source.segment, t.segments.len);
    try reference(target.segment, t.segments.len);
    const segment = t.segments[source.segment];
    const target_segment = t.segments[target.segment];
    try reference(segment.tempo, t.tempos.len);
    try reference(target_segment.tempo, t.tempos.len);
    const tempo = t.tempos[segment.tempo];
    const crossing = crossesSourceLoop(segment, source);
    var result: BoundedDirectTailLayout = .{
        .transition = candidate.transition,
        .source_exit = candidate.source_exit,
        .target_entry = candidate.target_entry,
        .fade_frames = 0,
        .loop_start = segment.loop_start,
        .loop_end = segment.loop_end,
        .loop_start_tick = tempo.loop_start_tick,
        .loop_end_tick = tempo.loop_end_tick,
        .onset_cursor = source.frame,
        .spans = @splat(.{}),
        .span_count = 1,
        .terminal_cursor = source.frame,
        .terminal_epoch_increment = 0,
        .crosses_loop = crossing,
    };
    if (!crossing) {
        const end_tick = std.math.add(u64, source.tick, rule.fade_ticks) catch return error.ArithmeticOverflow;
        const end = try tempo_validation.frameForTick(t, tempo, end_tick);
        if (end < source.frame) return error.InvalidMusicGraph;
        result.fade_frames = end - source.frame;
        if (result.fade_frames > source.tail_frames) return error.InvalidMusicGraph;
        result.spans[0] = .{ .first_frame = source.frame, .end_frame = end };
        result.terminal_cursor = end;
        return result;
    }
    try directTailOwner(t, candidate, profile);
    if ((source.kind != .exit and source.kind != .both) or (target.kind != .entry and target.kind != .both) or
        segment.loop_start >= segment.loop_end or segment.loop_end > segment.frames or
        source.frame < segment.loop_start or source.frame >= segment.loop_end or target.frame != 0 or target.tick != 0 or
        tempo.loop_present != 1 or tempo.loop_start_tick >= tempo.loop_end_tick or tempo.loop_end_tick > tempo.total_ticks or
        source.tick < tempo.loop_start_tick or source.tick >= tempo.loop_end_tick)
        return error.InvalidMusicGraph;
    if (try tempo_validation.frameForTick(t, tempo, source.tick) != source.frame or
        try tempo_validation.frameForTick(t, tempo, tempo.loop_start_tick) != segment.loop_start or
        try tempo_validation.frameForTick(t, tempo, tempo.loop_end_tick) != segment.loop_end)
        return error.InvalidMusicGraph;
    const before_ticks = tempo.loop_end_tick - source.tick;
    if (rule.fade_ticks <= before_ticks or rule.fade_ticks > tempo.loop_end_tick - tempo.loop_start_tick) return error.InvalidMusicGraph;
    const after_tick = std.math.add(u64, tempo.loop_start_tick, rule.fade_ticks - before_ticks) catch return error.ArithmeticOverflow;
    if (after_tick >= tempo.loop_end_tick) return error.InvalidMusicGraph;
    const terminal = try tempo_validation.frameForTick(t, tempo, after_tick);
    if (terminal <= segment.loop_start or terminal >= segment.loop_end) return error.InvalidMusicGraph;
    const frames = std.math.add(u64, segment.loop_end - source.frame, terminal - segment.loop_start) catch return error.ArithmeticOverflow;
    if (frames == 0 or frames > std.math.maxInt(u32) or frames > max_direct_loop_tail_frames or
        frames > segment.loop_end - segment.loop_start or frames != source.tail_frames or frames != rule.overlap_frames)
        return error.InvalidMusicGraph;
    if ((target_segment.loop_start != 0 or target_segment.loop_end != 0) and
        (target_segment.loop_start >= target_segment.loop_end or target_segment.loop_end > target_segment.frames)) return error.InvalidMusicGraph;
    const target_end = if (target_segment.loop_end > target_segment.loop_start) target_segment.loop_end else target_segment.frames;
    if (frames > target_end) return error.InvalidMusicGraph;
    try directTailLayers(t, source.segment);
    try directTailLayers(t, target.segment);
    const region = t.tempo_spans[try span(t, source.segment, source.tick)];
    const expected_meter = try meter(t, source.segment, source.tick);
    try constantTailInterval(t, source.segment, segment.loop_start, segment.loop_end, region.start_milli_bpm, expected_meter);
    try constantTailInterval(t, target.segment, 0, frames, region.start_milli_bpm, expected_meter);
    try hop(t, rule, source, target, rule.overlap_frames, candidate.handoff);
    result.fade_frames = frames;
    result.spans = .{ .{ .first_frame = source.frame, .end_frame = segment.loop_end }, .{ .first_frame = segment.loop_start, .end_frame = terminal } };
    result.span_count = 2;
    result.terminal_cursor = terminal;
    result.terminal_epoch_increment = 1;
    return result;
}

fn admitExtendedCue(t: s.Tables, value: s.Cue) s.BankError!void {
    var cue_index: ?u32 = null;
    for (t.cues, 0..) |actual, index| if (std.meta.eql(actual, value)) {
        if (cue_index != null) return error.InvalidMusicGraph;
        cue_index = @intCast(index);
    };
    const source_index = cue_index orelse return error.InvalidMusicGraph;
    var found = false;
    for (t.transition_paths) |candidate| if (candidate.source_exit == source_index) {
        const layout = try boundedDirectTailLayout(t, candidate, .{});
        if (!layout.crosses_loop or found) return error.InvalidMusicGraph;
        found = true;
    };
    if (!found) return error.InvalidMusicGraph;
}

pub fn cue(t: s.Tables, value: s.Cue) s.BankError!void {
    try reference(value.segment, t.segments.len);
    const segment = t.segments[value.segment];
    if (isEntry(value.kind) and segment.loop_end > segment.loop_start and value.frame >= segment.loop_end) return error.InvalidMusicGraph;
    try reference(segment.tempo, t.tempos.len);
    const tempo = t.tempos[segment.tempo];
    if (value.frame > segment.frames or value.tick > tempo.total_ticks) return error.InvalidMusicGraph;
    if (value.tail_frames > segment.frames - value.frame) try admitExtendedCue(t, value);
    const beat = gridHas(try items(s.Grid, t.beats, tempo.beats), value.tick);
    const bar = gridHas(try items(s.Grid, t.bars, tempo.bars), value.tick);
    switch (value.beat_role) {
        .any => {},
        .downbeat => if (!bar) return error.InvalidMusicGraph,
        .beat => if (!beat) return error.InvalidMusicGraph,
        .offbeat => if (beat) return error.InvalidMusicGraph,
    }
}
pub fn span(t: s.Tables, segment: u32, tick: u64) s.BankError!u32 {
    try reference(segment, t.segments.len);
    try reference(t.segments[segment].tempo, t.tempos.len);
    const range = t.tempos[t.segments[segment].tempo].spans;
    const spans = try items(s.TempoSpan, t.tempo_spans, range);
    if (spans.len == 0) return error.InvalidTempo;
    var lo: usize = 0;
    var hi = spans.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (spans[mid].start_tick <= tick) lo = mid + 1 else hi = mid;
    }
    if (lo == 0 or tick > spans[lo - 1].end_tick) return error.InvalidTempo;
    return range.first + @as(u32, @intCast(lo - 1));
}
pub fn meter(t: s.Tables, segment: u32, tick: u64) s.BankError!s.TempoMeter {
    try reference(segment, t.segments.len);
    try reference(t.segments[segment].tempo, t.tempos.len);
    const rows = try items(s.TempoMeter, t.tempo_meters, t.tempos[t.segments[segment].tempo].meters);
    var lo: usize = 0;
    var hi = rows.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (rows[mid].tick <= tick) lo = mid + 1 else hi = mid;
    }
    if (lo == 0) return error.InvalidTempo;
    return rows[lo - 1];
}
const Rate = struct { n: i256, d: i256 };
fn rate(region: s.TempoSpan, frame: u64) s.BankError!Rate {
    if (frame < region.start_frame or frame > region.end_frame) return error.InvalidTempo;
    if (region.curve == .constant) return .{ .n = region.start_milli_bpm, .d = 1 };
    if (region.end_frame <= region.start_frame) return error.InvalidTempo;
    const duration: i256 = region.end_frame - region.start_frame;
    return .{ .n = @as(i256, region.start_milli_bpm) * duration + (@as(i256, region.end_milli_bpm) - region.start_milli_bpm) * (frame - region.start_frame), .d = duration };
}
/// Every hop uses explicit tags and nominal tempo/meter at its authored cues.
/// No waveform analysis, pitch shifting or implicit crossfade compatibility.
pub fn hop(t: s.Tables, rule: s.Transition, from: s.Cue, to: s.Cue, overlap: u32, handoff: s.Handoff) s.BankError!void {
    if (!isExit(from.kind) or !isEntry(to.kind) or rule.compatibility & ~compatibility_mask != 0) return error.InvalidMusicGraph;
    inline for (.{ .{ "harmony", @as(u32, 1) }, .{ "phrase", @as(u32, 2) }, .{ "energy", @as(u32, 4) } }) |pair| {
        const a = @field(from, pair[0]);
        const b = @field(to, pair[0]);
        const constraint = @field(rule, pair[0]);
        if ((constraint != 0 and (a != constraint or b != constraint)) or (rule.compatibility & pair[1] != 0 and (a == 0 or a != b))) return error.InvalidMusicGraph;
    }
    const a = t.tempo_spans[try span(t, from.segment, from.tick)];
    const b = t.tempo_spans[try span(t, to.segment, to.tick)];
    const ar = try rate(a, from.frame);
    const br = try rate(b, to.frame);
    const same_rate = ar.n * br.d == br.n * ar.d;
    const am = try meter(t, from.segment, from.tick);
    const bm = try meter(t, to.segment, to.tick);
    const same_meter = am.numerator == bm.numerator and am.denominator == bm.denominator and std.mem.eql(u8, try items(u8, t.beat_groups, am.groups), try items(u8, t.beat_groups, bm.groups));
    if ((rule.compatibility & 8 != 0 and !same_rate) or (rule.compatibility & 16 != 0 and !same_meter)) return error.InvalidMusicGraph;
    switch (handoff) {
        .continuous => if (!same_rate or !same_meter or overlap > from.tail_frames) return error.InvalidMusicGraph,
        .tail_overlap => if (overlap == 0 or overlap > from.tail_frames) return error.InvalidMusicGraph,
        .tempo_handoff => if (overlap > from.tail_frames) return error.InvalidMusicGraph,
        .hard_cut => if (overlap != 0 or rule.fade_ticks != 0) return error.InvalidMusicGraph,
    }
}
pub fn path(t: s.Tables, value: s.TransitionPath, profile: s.Platform) s.BankError!void {
    try reference(value.transition, t.transitions.len);
    try reference(value.source_exit, t.cues.len);
    try reference(value.target_entry, t.cues.len);
    const rule = t.transitions[value.transition];
    const source = t.cues[value.source_exit];
    const target = t.cues[value.target_entry];
    try reference(source.segment, t.segments.len);
    try reference(target.segment, t.segments.len);
    if (!isExit(source.kind) or !isEntry(target.kind) or target.frame >= t.segments[target.segment].frames) return error.InvalidMusicGraph;
    if (rule.beat_role != .any and source.beat_role != rule.beat_role and !(rule.beat_role == .beat and source.beat_role == .downbeat)) return error.InvalidMusicGraph;
    const source_segment = t.segments[source.segment];
    if (source_segment.loop_end > source_segment.loop_start and (source.frame < source_segment.loop_start or source.frame > source_segment.loop_end)) return error.InvalidMusicGraph;
    if (value.handoff != .hard_cut and crossesSourceLoop(source_segment, source) and
        try hasRequiredStreamedLayer(t, source.segment)) _ = try boundedDirectTailLayout(t, value, profile);
    if (value.fill == s.none) return hop(t, rule, source, target, rule.overlap_frames, value.handoff);
    try reference(value.fill, t.fills.len);
    const route = t.fills[value.fill];
    if (route.source_exit != value.source_exit or route.target_entry != value.target_entry) return error.InvalidMusicGraph;
    const steps = try items(s.FillStep, t.fill_steps, route.steps);
    if (steps.len > max_fill_steps or steps.len > profile.max_fill_steps) return error.ResourceLimitExceeded;
    var previous = source;
    var overlap = rule.overlap_frames;
    for (steps) |step| {
        try hop(t, rule, previous, t.cues[step.entry], overlap, value.handoff);
        previous = t.cues[step.exit];
        overlap = step.overlap_frames;
    }
    try hop(t, rule, previous, target, overlap, value.handoff);
}
const PathKey = struct {
    transition: u32,
    source_exit: u32,
    target_entry: u32,
    fill: u32,
    rank: u32,
    sync_penalty: u16,
    handoff: s.Handoff,
    fn less(_: void, a: PathKey, b: PathKey) bool {
        inline for (comptime std.meta.fieldNames(PathKey)) |name| if (@field(a, name) != @field(b, name)) {
            if (comptime std.mem.eql(u8, name, "handoff")) {
                return @intFromEnum(a.handoff) < @intFromEnum(b.handoff);
            } else return @field(a, name) < @field(b, name);
        };
        return false;
    }
};
pub fn phaseCount(t: s.Tables, candidate: s.TransitionPath, profile: s.Platform) s.BankError!u16 {
    try reference(candidate.transition, t.transitions.len);
    try reference(candidate.source_exit, t.cues.len);
    const rule = t.transitions[candidate.transition];
    const steps: []const s.FillStep = if (candidate.fill == s.none) &.{} else route: {
        try reference(candidate.fill, t.fills.len);
        const values = try items(s.FillStep, t.fill_steps, t.fills[candidate.fill].steps);
        if (values.len > max_fill_steps or values.len > profile.max_fill_steps) return error.ResourceLimitExceeded;
        break :route values;
    };
    var count: u16 = @intCast(steps.len + 1); // each actual fill/target entry
    if (candidate.handoff != .hard_cut) {
        count += @intFromBool(t.cues[candidate.source_exit].tail_frames > 0);
        count += @intFromBool(rule.overlap_frames > 0);
        for (steps) |step| {
            try reference(step.exit, t.cues.len);
            count += @intFromBool(t.cues[step.exit].tail_frames > 0);
            count += @intFromBool(step.overlap_frames > 0);
        }
    }
    if (count > profile.max_planner_phases or count > s.Limits.planner_phases) return error.ResourceLimitExceeded;
    return count;
}
fn windowChunks(t: s.Tables, segment_index: u32, first: u64, end: u64, used: *[max_required_chunks]u32, count: *usize, references: *usize, count_references: bool, profile: s.Platform) s.BankError!void {
    try reference(segment_index, t.segments.len);
    const segment = t.segments[segment_index];
    if (first >= end or end > segment.frames or segment.layers.count == 0 or segment.layers.count > 16) return error.InvalidMusicGraph;
    var required = false;
    for (try items(s.Layer, t.layers, segment.layers)) |layer| {
        if (layer.segment != segment_index or layer.required > 1) return error.InvalidMusicGraph;
        try reference(layer.sound, t.sounds.len);
        if (layer.required == 0) continue;
        required = true;
        const sound = t.sounds[layer.sound];
        const start = std.math.add(u64, first, layer.source_start) catch return error.ArithmeticOverflow;
        const stop = std.math.add(u64, end, layer.source_start) catch return error.ArithmeticOverflow;
        if (stop > sound.frames) return error.MisalignedStems;
        if (sound.storage == .resident) continue;
        // TASK-011 readiness certifies one contiguous source interval. Keep the
        // authored window unchanged; multi-cycle ring occupancy is not proof
        // that a single-cycle interval extends beyond the segment loop end.
        if (segment.loop_start != 0 or segment.loop_end != 0) {
            if (segment.loop_start >= segment.loop_end or segment.loop_end > segment.frames) return error.InvalidMusicGraph;
            const loop_end = std.math.add(u64, layer.source_start, segment.loop_end) catch return error.ArithmeticOverflow;
            if (stop > loop_end) return error.InvalidMusicGraph;
        }
        // A second physical span reuses the same four real source bindings.
        // Only the first span owns their once-per-layer reference credits.
        if (count_references) {
            if (references.* >= max_readiness_references) return error.ResourceLimitExceeded;
            references.* += 1;
        }
        const chunks = try items(s.Chunk, t.chunks, sound.chunks);
        var lo: usize = 0;
        var hi = chunks.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const chunk_end = std.math.add(u64, chunks[mid].first_frame, chunks[mid].frame_count) catch return error.ArithmeticOverflow;
            if (chunk_end <= start) lo = mid + 1 else hi = mid;
        }
        var coverage = start;
        while (lo < chunks.len and coverage < stop) : (lo += 1) {
            const chunk = chunks[lo];
            const chunk_end = std.math.add(u64, chunk.first_frame, chunk.frame_count) catch return error.ArithmeticOverflow;
            if (chunk.sound != layer.sound or chunk.frame_count == 0 or chunk.first_frame > coverage or chunk_end <= coverage) return error.InvalidMusicGraph;
            const index = sound.chunks.first + @as(u32, @intCast(lo));
            var seen = false;
            for (used[0..count.*]) |prior| if (prior == index) {
                seen = true;
                break;
            };
            if (!seen) {
                if (count.* >= max_required_chunks or count.* >= profile.max_required_chunks) return error.ResourceLimitExceeded;
                used[count.*] = index;
                count.* += 1;
            }
            coverage = @min(stop, chunk_end);
        }
        if (coverage != stop) return error.InvalidMusicGraph;
    }
    if (!required) return error.InvalidMusicGraph;
}
pub fn requiredChunkCount(t: s.Tables, candidate: s.TransitionPath, profile: s.Platform) s.BankError!usize {
    try reference(candidate.source_exit, t.cues.len);
    try reference(candidate.target_entry, t.cues.len);
    const source = t.cues[candidate.source_exit];
    const target = t.cues[candidate.target_entry];
    try reference(source.segment, t.segments.len);
    try reference(target.segment, t.segments.len);
    var used: [max_required_chunks]u32 = undefined;
    var count: usize = 0;
    var references: usize = 0;
    if (candidate.handoff != .hard_cut and source.tail_frames > 0) {
        if (crossesSourceLoop(t.segments[source.segment], source) and try hasRequiredStreamedLayer(t, source.segment)) {
            const layout = try boundedDirectTailLayout(t, candidate, profile);
            for (layout.spans[0..layout.span_count], 0..) |physical, index|
                try windowChunks(t, source.segment, physical.first_frame, physical.end_frame, &used, &count, &references, index == 0, profile);
        } else try windowChunks(t, source.segment, source.frame, std.math.add(u64, source.frame, source.tail_frames) catch return error.ArithmeticOverflow, &used, &count, &references, true, profile);
    }
    if (candidate.fill != s.none) {
        try reference(candidate.fill, t.fills.len);
        for (try items(s.FillStep, t.fill_steps, t.fills[candidate.fill].steps)) |step| {
            try reference(step.entry, t.cues.len);
            try reference(step.exit, t.cues.len);
            const entry = t.cues[step.entry];
            const exit = t.cues[step.exit];
            const end = std.math.add(u64, exit.frame, if (candidate.handoff == .hard_cut) 0 else exit.tail_frames) catch return error.ArithmeticOverflow;
            try windowChunks(t, step.segment, entry.frame, end, &used, &count, &references, true, profile);
        }
    }
    if (target.frame >= t.segments[target.segment].frames) return error.InvalidMusicGraph;
    const end = target.frame + @min(@as(u64, profile.planner_minimum_window_frames), t.segments[target.segment].frames - target.frame);
    try windowChunks(t, target.segment, target.frame, end, &used, &count, &references, true, profile);
    return count;
}
/// Uses already-produced media/cue frames; source AST dimensions may still be
/// unresolved, so producers call this against their prior media/tempo output.
pub fn validatePlanBounds(t: s.Tables, profile: s.Platform) s.BankError!void {
    if (t.transitions.len > max_paths or t.transition_paths.len > max_paths or t.segments.len > profile.max_table_records or t.segments.len > s.Limits.records) return error.ResourceLimitExceeded;
    // Tempo tables are separately admitted before this consumer. A missing
    // declaration is not invented, but two explicit loop identities must agree.
    for (t.segments) |segment| {
        if (segment.loop_start == 0 and segment.loop_end == 0) continue;
        if (segment.loop_start >= segment.loop_end or segment.loop_end > segment.frames) return error.InvalidMusicGraph;
        try reference(segment.tempo, t.tempos.len);
        const tempo = t.tempos[segment.tempo];
        if (tempo.loop_present == 1) {
            if (segment.loop_start != try tempo_validation.frameForTick(t, tempo, tempo.loop_start_tick) or segment.loop_end != try tempo_validation.frameForTick(t, tempo, tempo.loop_end_tick)) return error.InvalidMusicGraph;
        }
    }
    var seen: [max_paths]bool = @splat(false);
    for (t.transition_paths) |candidate| {
        try reference(candidate.transition, t.transitions.len);
        if (candidate.transition >= max_paths) return error.ResourceLimitExceeded;
        seen[candidate.transition] = true;
        _ = try phaseCount(t, candidate, profile);
        _ = try requiredChunkCount(t, candidate, profile);
    }
    for (t.transitions, 0..) |rule, i| if (!seen[i]) {
        const candidate: s.TransitionPath = .{ .transition = @intCast(i), .source_exit = rule.source_exit, .target_entry = rule.target_entry, .fill = rule.fill };
        _ = try phaseCount(t, candidate, profile);
        _ = try requiredChunkCount(t, candidate, profile);
    };
}
pub fn validateLimits(t: s.Tables, profile: s.Platform) s.BankError!void {
    if (profile.max_table_records == 0 or profile.max_table_records > s.Limits.records or profile.max_planner_candidates == 0 or profile.max_planner_candidates > max_paths or profile.max_planner_phases == 0 or profile.max_planner_phases > s.Limits.planner_phases or profile.max_fill_steps > max_fill_steps or profile.max_required_chunks == 0 or profile.max_required_chunks > max_required_chunks or profile.planner_minimum_window_frames == 0 or profile.planner_minimum_window_frames > 65536) return error.ResourceLimitExceeded;
    inline for (.{ "segments", "cues", "fills", "fill_steps", "transition_paths" }) |field| if (@field(t, field).len > profile.max_table_records or @field(t, field).len > s.Limits.records) return error.ResourceLimitExceeded;
    if (t.transition_paths.len > max_paths or t.transitions.len > max_paths or t.transitions.len > profile.max_table_records) return error.ResourceLimitExceeded;
    for (t.fills) |route| if (route.steps.count > max_fill_steps or route.steps.count > profile.max_fill_steps) return error.ResourceLimitExceeded;
    var counts: [max_paths]u16 = @splat(0);
    for (t.transition_paths) |candidate| {
        try reference(candidate.transition, t.transitions.len);
        if (counts[candidate.transition] >= profile.max_planner_candidates) return error.ResourceLimitExceeded;
        counts[candidate.transition] += 1;
        _ = try phaseCount(t, candidate, profile);
    }
    for (t.transitions, 0..) |rule, index| if (counts[index] == 0) {
        _ = try phaseCount(t, .{ .transition = @intCast(index), .source_exit = rule.source_exit, .target_entry = rule.target_entry, .fill = rule.fill }, profile);
    };
}
pub fn validate(allocator: std.mem.Allocator, t: s.Tables, profile: s.Platform, canonical: bool) Error!void {
    try validateLimits(t, profile);
    try validatePlanBounds(t, profile);
    const scratch = try allocator.alloc(u64, @max(t.cues.len, t.fills.len, t.transition_paths.len));
    defer allocator.free(scratch);
    try names(t.cues, scratch);
    try names(t.fills, scratch);
    try names(t.transition_paths, scratch);
    for (t.cues) |value| try cue(t, value);
    for (t.fill_steps) |step| {
        try reference(step.segment, t.segments.len);
        try reference(step.entry, t.cues.len);
        try reference(step.exit, t.cues.len);
        const entry = t.cues[step.entry];
        const exit = t.cues[step.exit];
        if (entry.segment != step.segment or exit.segment != step.segment or !isEntry(entry.kind) or !isExit(exit.kind) or exit.frame <= entry.frame or exit.tick <= entry.tick or step.overlap_frames > exit.tail_frames) return error.InvalidMusicGraph;
    }
    for (t.fills) |route| {
        try reference(route.source_exit, t.cues.len);
        try reference(route.target_entry, t.cues.len);
        if (!isExit(t.cues[route.source_exit].kind) or !isEntry(t.cues[route.target_entry].kind)) return error.InvalidMusicGraph;
        const steps = try items(s.FillStep, t.fill_steps, route.steps);
        if (steps.len > max_fill_steps or steps.len > profile.max_fill_steps) return error.ResourceLimitExceeded;
        // Finite routes cannot recurse. Each flat step makes positive musical
        // and frame progress, even when a segment is intentionally repeated.
    }
    for (t.transitions, 0..) |rule, i| {
        if (rule.compatibility & ~compatibility_mask != 0) return error.InvalidMusicGraph;
        try reference(rule.from, t.states.len);
        try reference(rule.to, t.states.len);
        try reference(rule.selector, t.selectors.len);
        if (rule.condition != s.none) try reference(rule.condition, t.logic.len);
        if (rule.fallback == .segment) try reference(rule.fallback_segment, t.segments.len) else if (rule.fallback_segment != s.none) return error.InvalidMusicGraph;
        try reference(rule.source_exit, t.cues.len);
        try reference(rule.target_entry, t.cues.len);
        if (rule.fill != s.none) try reference(rule.fill, t.fills.len);
        if (canonical) {
            const paths = try items(s.TransitionPath, t.transition_paths, rule.paths);
            if (paths.len == 0 or paths.len > profile.max_planner_candidates) return error.ResourceLimitExceeded;
            for (paths) |candidate| if (candidate.transition != i) return error.InvalidMusicGraph;
        }
    }
    const keys = try allocator.alloc(PathKey, t.transition_paths.len);
    defer allocator.free(keys);
    for (t.transition_paths, 0..) |candidate, i| {
        try path(t, candidate, profile);
        if (canonical) {
            const range = t.transitions[candidate.transition].paths;
            if (i < range.first or i >= @as(u64, range.first) + range.count) return error.InvalidMusicGraph;
        }
        keys[i] = .{ .transition = candidate.transition, .source_exit = candidate.source_exit, .target_entry = candidate.target_entry, .fill = candidate.fill, .rank = candidate.authored_rank, .sync_penalty = candidate.sync_penalty, .handoff = candidate.handoff };
    }
    std.mem.sort(PathKey, keys, {}, PathKey.less);
    for (keys, 0..) |key, i| if (i > 0 and std.meta.eql(key, keys[i - 1])) return error.InvalidMusicGraph;
}
