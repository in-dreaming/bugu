//! Deterministic selection attempts are separate from actual-entry history.
//! No allocation, recursion, wall clock, native PRNG, or mixer access.
const std = @import("std");
pub const s = @import("sme-bank").schema;
const logic = @import("sme-logic");
pub const trace = @import("sme-trace").schema;
pub const Error = s.BankError;
pub const algorithm_version: u16 = 1;
pub const State = struct {
    stable_id: u64 = 0,
    kind: s.SelectorKind = .fixed,
    capacity: u16 = 0,
    epoch: u64 = 0,
    revision: u64 = 0,
    sequence_cursor: u32 = 0,
    history_len: u16 = 0,
    /// Oldest to newest stable segment IDs, never bank indexes.
    history: [s.Limits.selector_history]u64 = @splat(0),
    pub fn init(selector: s.Selector) State {
        return .{ .stable_id = selector.key.id, .kind = selector.kind, .capacity = selector.history_capacity };
    }
};
pub const Choice = struct { segment: u32, candidate: u32, epoch: u64, history_revision: u64, reset_history: bool, fallback: bool };
/// Purely observational bounded trace. Dropped/disabled records invalidate
/// replay evidence but never change acceptance, RNG, intents or history.
pub const Trace = struct {
    records: []trace.ScheduleRecord,
    count: usize = 0,
    base: trace.ScheduleRecord,
    enabled: bool = true,
    next_sequence: u64 = 0,
    dropped: u64 = 0,
    overflowed: bool = false,
    pub fn disabled(base: trace.ScheduleRecord) Trace {
        return .{ .records = &.{}, .base = base, .enabled = false };
    }
    pub fn isComplete(self: Trace) bool {
        return self.enabled and !self.overflowed and self.dropped == 0;
    }
    pub fn requireComplete(self: Trace) trace.Error!void {
        if (!self.isComplete()) return error.IncompleteTrace;
    }
    pub fn recordingHeader(self: Trace, header: trace.Header) trace.Header {
        var result = header;
        result.complete = header.complete and self.isComplete();
        return result;
    }
    pub fn emit(self: *Trace, record: trace.ScheduleRecord) void {
        var row = record;
        row.sequence = self.next_sequence;
        if (self.next_sequence == std.math.maxInt(u64)) self.overflowed = true else self.next_sequence += 1;
        if (!self.enabled or self.count >= self.records.len) {
            self.dropped +|= 1;
            self.overflowed = true;
            return;
        }
        self.records[self.count] = row;
        self.count += 1;
    }
};
pub const Random = struct {
    state: u64,
    pub fn next(self: *Random) u64 {
        self.state +%= 0x9e3779b97f4a7c15;
        var z = self.state;
        z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
        z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
        return z ^ (z >> 31);
    }
    /// Rejection sampling is unbiased and strictly bounded (16 draws). An
    /// astronomically unlikely exhaustion is explicit, never an unbounded loop.
    pub fn bounded(self: *Random, bound: u64) Error!u64 {
        if (bound == 0) return error.InvalidMusicGraph;
        const threshold = (0 -% bound) % bound;
        for (0..16) |_| {
            const r = self.next();
            if (r >= threshold) return r % bound;
        }
        return error.ResourceLimitExceeded;
    }
};
pub fn randomFor(seed: u64, stable_id: u64, epoch: u64) Random {
    var r: Random = .{ .state = seed ^ 0x534d4553454c3031 };
    r.state ^= stable_id;
    const a = r.next();
    r.state = a ^ epoch;
    _ = r.next();
    return r;
}
fn inHistory(state: State, id: u64, window: usize) bool {
    const n = @min(window, state.history_len);
    for (state.history[state.history_len - n .. state.history_len]) |old| if (old == id) return true;
    return false;
}
fn candidateRecord(log: *Trace, selector: s.Selector, candidate: s.Candidate, segment_id: u64, epoch: u64, reason: trace.Reason) void {
    var row = log.base;
    row.kind = .rule_candidate;
    row.selector_id = selector.key.id;
    row.target_segment = segment_id;
    row.selector_epoch = epoch;
    row.authored_order = candidate.authored_order;
    row.reason = reason;
    row.result = if (reason == .none) .none else .rejected;
    log.emit(row);
}
/// Call only with selection_validation-admitted immutable tables/state. Each
/// attempt consumes an epoch even if its explicit exhaustion policy rejects.
pub fn choose(t: s.Tables, profile: s.Platform, index: u32, state: *State, seed: u64, env: logic.Environment, log: *Trace) Error!Choice {
    _ = profile; // Immutable tables carry the selected profile admission proof.
    if (index >= t.selectors.len) return error.InvalidMusicGraph;
    const definition = t.selectors[index];
    const pool = try logic.validation.items(s.Candidate, t.candidates, definition.candidates);
    if (state.stable_id != definition.key.id or state.kind != definition.kind or state.capacity != definition.history_capacity or state.history_len > state.capacity or state.capacity > s.Limits.selector_history or pool.len > s.Limits.selector_candidates) return error.InvalidMusicGraph;
    if (state.epoch == std.math.maxInt(u64)) return error.ResourceLimitExceeded;
    state.epoch += 1;
    var eligible: [s.Limits.selector_candidates]u16 = undefined;
    var count: usize = 0;
    var reset = false;
    for (0..2) |pass| {
        count = 0;
        for (pool, 0..) |candidate, i| {
            var reason: trace.Reason = .none;
            const id = t.segments[candidate.segment].key.id;
            if (!try logic.evaluateAdmitted(t, candidate.condition, env)) reason = .condition_false else if ((definition.kind == .weighted_random or definition.kind == .no_repeat) and candidate.weight == 0) reason = .zero_weight else if (!reset and definition.kind == .sequence and i < state.sequence_cursor) reason = .history_excluded else if (!reset and definition.kind == .shuffle and inHistory(state.*, id, state.history_len)) reason = .history_excluded else if (!reset and (definition.kind == .no_repeat or definition.kind == .history) and inHistory(state.*, id, definition.no_repeat_window)) reason = .history_excluded;
            candidateRecord(log, definition, candidate, id, state.epoch, reason);
            if (reason == .none) {
                eligible[count] = @intCast(i);
                count += 1;
            }
        }
        if (count > 0) break;
        if (pass == 0 and definition.exhaustion == .reset) {
            reset = true;
            continue;
        }
        if (definition.exhaustion == .fallback) {
            if (definition.fallback_segment >= t.segments.len) return error.InvalidMusicGraph;
            var row = log.base;
            row.kind = .selector_choice;
            row.selector_id = definition.key.id;
            row.selector_epoch = state.epoch;
            row.target_segment = t.segments[definition.fallback_segment].key.id;
            row.reason = .selector_exhausted;
            row.result = .degraded;
            log.emit(row);
            return .{ .segment = definition.fallback_segment, .candidate = s.none, .epoch = state.epoch, .history_revision = state.revision, .reset_history = false, .fallback = true };
        }
        var row = log.base;
        row.kind = .rejected;
        row.selector_id = definition.key.id;
        row.selector_epoch = state.epoch;
        row.reason = .selector_exhausted;
        row.result = .rejected;
        log.emit(row);
        return error.TransitionNotFound;
    }
    var rng = randomFor(seed, definition.key.id, state.epoch);
    var picked: usize = eligible[0];
    switch (definition.kind) {
        .fixed, .sequence, .condition => {},
        .shuffle => picked = eligible[@intCast(try rng.bounded(count))],
        .weighted_random, .no_repeat => {
            var total: u64 = 0;
            for (eligible[0..count]) |i| total += pool[i].weight;
            var draw = try rng.bounded(total);
            for (eligible[0..count]) |i| {
                if (draw < pool[i].weight) {
                    picked = i;
                    break;
                }
                draw -= pool[i].weight;
            }
        },
        .history => {
            var best_count: usize = std.math.maxInt(usize);
            var best_last: usize = std.math.maxInt(usize);
            for (eligible[0..count]) |i| {
                var uses: usize = 0;
                var last: usize = 0;
                if (!reset) for (state.history[0..state.history_len], 0..) |id, h| if (id == t.segments[pool[i].segment].key.id) {
                    uses += 1;
                    last = h + 1;
                };
                if (uses < best_count or (uses == best_count and last < best_last)) {
                    picked = i;
                    best_count = uses;
                    best_last = last;
                }
            }
        },
    }
    var row = log.base;
    row.kind = .selector_choice;
    row.selector_id = definition.key.id;
    row.selector_epoch = state.epoch;
    row.target_segment = t.segments[pool[picked].segment].key.id;
    row.authored_order = pool[picked].authored_order;
    row.result = .success;
    row.reason = .none;
    log.emit(row);
    return .{ .segment = pool[picked].segment, .candidate = @intCast(picked), .epoch = state.epoch, .history_revision = state.revision, .reset_history = reset, .fallback = false };
}
/// Only a matching successful target-entry receipt may call this. Superseded
/// intents can still execute; their real entry is counted in receipt order.
fn validateCommit(t: s.Tables, index: u32, state: *const State, choice: Choice) Error!void {
    if (index >= t.selectors.len or choice.segment >= t.segments.len or choice.epoch == 0 or choice.epoch > state.epoch or choice.history_revision > state.revision or state.revision == std.math.maxInt(u64)) return error.InvalidMusicGraph;
    const definition = t.selectors[index];
    if (state.stable_id != definition.key.id or state.kind != definition.kind or state.capacity != definition.history_capacity or state.history_len > state.capacity or state.capacity > s.Limits.selector_history) return error.InvalidMusicGraph;
}
pub fn commit(t: s.Tables, index: u32, state: *State, choice: Choice) Error!void {
    try validateCommit(t, index, state, choice);
    const definition = t.selectors[index];
    if (choice.fallback) {
        if (definition.exhaustion != .fallback or choice.candidate != s.none or choice.segment != definition.fallback_segment) return error.InvalidMusicGraph;
    } else {
        const pool = try logic.validation.items(s.Candidate, t.candidates, definition.candidates);
        if (choice.candidate >= pool.len or pool[choice.candidate].segment != choice.segment) return error.InvalidMusicGraph;
    }
    try commitHistory(t, index, state, choice);
}
pub const CommitProvenance = enum { selector, rule_fallback };
/// Director-only actual-entry path for an explicitly authored rule fallback.
/// It cannot be used as a selector exhaustion result or reset pending history.
pub fn commitRuleFallback(t: s.Tables, index: u32, state: *State, choice: Choice, rule_index: u32, provenance: CommitProvenance) Error!void {
    try validateCommit(t, index, state, choice);
    if (state.revision >= state.epoch or choice.history_revision >= choice.epoch or provenance != .rule_fallback or rule_index >= t.transitions.len or !choice.fallback or choice.candidate != s.none or choice.reset_history or choice.epoch < 2) return error.InvalidMusicGraph;
    const rule = t.transitions[rule_index];
    if (rule.selector != index or rule.fallback != .segment or rule.fallback_segment != choice.segment) return error.InvalidMusicGraph;
    try commitHistory(t, index, state, choice);
}
fn commitHistory(t: s.Tables, index: u32, state: *State, choice: Choice) Error!void {
    const definition = t.selectors[index];
    const id = t.segments[choice.segment].key.id;
    var track_history = true;
    if (definition.kind == .shuffle and choice.fallback) {
        track_history = false;
        for (try logic.validation.items(s.Candidate, t.candidates, definition.candidates)) |candidate| if (candidate.segment == choice.segment) {
            track_history = true;
            break;
        };
    }
    if (definition.kind == .sequence and !choice.fallback) state.sequence_cursor = choice.candidate + 1;
    // An uncontested explicit reset starts a fresh history. A reset selected
    // against older pending state cannot erase intervening real entries.
    if (choice.reset_history and state.revision == choice.history_revision) state.history_len = 0;
    if (track_history and state.capacity > 0 and (definition.kind != .shuffle or !inHistory(state.*, id, state.history_len))) {
        if (state.history_len == state.capacity) {
            std.mem.copyForwards(u64, state.history[0 .. state.history_len - 1], state.history[1..state.history_len]);
            state.history_len -= 1;
        }
        state.history[state.history_len] = id;
        state.history_len += 1;
    }
    state.revision += 1;
}
pub const state_bytes = @sizeOf(State);
