//! Narrow TASK-008 admission for typed selection artifacts. This deliberately
//! does not certify audio, tempo, cue paths, or the whole MusicBank.
const std = @import("std");
pub const s = @import("music_schema.zig");
pub const Error = s.BankError;
pub const AdmissionError = Error || std.mem.Allocator.Error;
pub const Kind = enum(u8) { boolean, integer, scalar, id };
pub fn quantize(value: f64) Error!i32 {
    if (!std.math.isFinite(value)) return error.InvalidMusicGraph;
    const x = value * 65536;
    if (x < -2147483648.0 or x > 2147483647.0) return error.InvalidMusicGraph;
    const lo = @floor(x);
    var n: i64 = @intFromFloat(lo);
    if (x - lo > 0.5 or (x - lo == 0.5 and @mod(n, 2) != 0)) n += 1;
    return @intCast(n);
}
pub fn contextKind(kind: s.ContextKind) Kind {
    return switch (kind) {
        .boolean => .boolean,
        .integer => .integer,
        .scalar => .scalar,
        .id => .id,
    };
}
pub fn items(comptime T: type, all: []const T, range: s.Range) Error![]const T {
    const end = @as(u64, range.first) + range.count;
    if (end > all.len) return error.InvalidMusicGraph;
    return all[range.first..@intCast(end)];
}
fn reference(index: u32, length: usize) Error!void {
    if (index >= length) return error.InvalidMusicGraph;
}
fn optionalReference(index: u32, length: usize) Error!void {
    if (index != s.none) try reference(index, length);
}
fn idLess(_: void, a: u64, b: u64) bool {
    return a < b;
}
/// Admission-only caller-owned heap scratch, never part of a control query.
fn names(records: anytype, scratch: []u64) Error!void {
    if (records.len > s.Limits.records) return error.ResourceLimitExceeded;
    if (scratch.len < records.len) return error.ResourceLimitExceeded;
    for (records, 0..) |record, i| {
        if (record.key.id == 0) return error.InvalidMusicGraph;
        scratch[i] = record.key.id;
    }
    std.mem.sort(u64, scratch[0..records.len], {}, idLess);
    for (scratch[0..records.len], 0..) |id, i| if (i > 0 and id == scratch[i - 1]) return error.IdCollision;
}
const RuleKey = struct { from: u32, to: u32, priority: u8, specificity: u16, authored: u32 };
fn ruleLess(_: void, a: RuleKey, b: RuleKey) bool {
    inline for (.{ "from", "to", "priority", "specificity", "authored" }) |field| {
        if (@field(a, field) != @field(b, field)) return @field(a, field) < @field(b, field);
    }
    return false;
}
/// Flat-record admission also checks operands outside referenced programs.
pub fn operand(t: s.Tables, op: s.Instruction) Error!void {
    // Unused operands must retain canonical defaults: one bytecode has one
    // representation, and malformed/NaN fields cannot hide in ignored data.
    if (!std.math.isFinite(op.number)) return error.InvalidMusicGraph;
    const has_ref = op.op == .load_state or op.op == .load_parameter or op.op == .load_context;
    if (!has_ref and op.reference != s.none) return error.InvalidMusicGraph;
    if (op.op != .push_number and op.number != 0) return error.InvalidMusicGraph;
    if (op.op != .push_id and op.unsigned != 0) return error.InvalidMusicGraph;
    if (op.op != .push_integer and op.op != .push_bool and op.integer != 1) return error.InvalidMusicGraph;
    switch (op.op) {
        .load_state => try reference(op.reference, t.states.len),
        .load_parameter => try reference(op.reference, t.parameters.len),
        .load_context => try reference(op.reference, t.contexts.len),
        .push_bool => if (op.integer != 0 and op.integer != 1) return error.InvalidMusicGraph,
        .push_id => if (op.unsigned == 0) return error.InvalidMusicGraph,
        .push_number => {
            _ = try quantize(op.number);
        },
        else => {},
    }
}
/// End-of-slice is not a terminator. Exactly one final return_bool is required.
pub fn program(t: s.Tables, code: []const s.Instruction, stack_limit: u16, profile: s.Platform) Error!u16 {
    if (code.len == 0 or code.len > s.Limits.logic_instructions or code.len > profile.max_logic_instructions or stack_limit == 0 or stack_limit > s.Limits.logic_stack or stack_limit > profile.max_logic_stack) return error.ResourceLimitExceeded;
    var stack: [s.Limits.logic_stack]Kind = undefined;
    var depth: usize = 0;
    var peak: usize = 0;
    for (code, 0..) |op, pc| {
        try operand(t, op);
        var pushed: ?Kind = null;
        switch (op.op) {
            .push_bool => {
                if (op.integer != 0 and op.integer != 1) return error.InvalidMusicGraph;
                pushed = .boolean;
            },
            .push_integer => pushed = .integer,
            .push_id => {
                if (op.unsigned == 0) return error.InvalidMusicGraph;
                pushed = .id;
            },
            .push_number => {
                _ = try quantize(op.number);
                pushed = .scalar;
            },
            .load_state => {
                try reference(op.reference, t.states.len);
                pushed = .boolean;
            },
            .load_parameter => {
                try reference(op.reference, t.parameters.len);
                pushed = .scalar;
            },
            .load_context => {
                try reference(op.reference, t.contexts.len);
                pushed = contextKind(t.contexts[op.reference].kind);
            },
            .eq, .ne, .lt, .le, .gt, .ge => {
                if (depth < 2 or stack[depth - 1] != stack[depth - 2]) return error.InvalidMusicGraph;
                if (op.op != .eq and op.op != .ne and stack[depth - 1] != .integer and stack[depth - 1] != .scalar) return error.InvalidMusicGraph;
                depth -= 2;
                pushed = .boolean;
            },
            .and_op, .or_op => {
                if (depth < 2 or stack[depth - 1] != .boolean or stack[depth - 2] != .boolean) return error.InvalidMusicGraph;
                depth -= 2;
                pushed = .boolean;
            },
            .not_op => {
                if (depth < 1 or stack[depth - 1] != .boolean) return error.InvalidMusicGraph;
            },
            .in_range => {
                if (depth < 3 or stack[depth - 1] != stack[depth - 2] or stack[depth - 1] != stack[depth - 3] or (stack[depth - 1] != .scalar and stack[depth - 1] != .integer)) return error.InvalidMusicGraph;
                depth -= 3;
                pushed = .boolean;
            },
            .return_bool => {
                if (pc + 1 != code.len or depth != 1 or stack[0] != .boolean) return error.InvalidMusicGraph;
                return @intCast(peak);
            },
        }
        if (pushed) |kind| {
            if (depth >= stack_limit) return error.ResourceLimitExceeded;
            stack[depth] = kind;
            depth += 1;
            peak = @max(peak, depth);
        }
    }
    return error.InvalidMusicGraph;
}
pub fn validate(allocator: std.mem.Allocator, t: s.Tables, profile: s.Platform) AdmissionError!void {
    if (profile.max_table_records == 0 or profile.max_table_records > s.Limits.records or profile.max_planner_candidates == 0 or profile.max_planner_candidates > s.Limits.planner_candidates) return error.ResourceLimitExceeded;
    if (profile.max_logic_stack == 0 or profile.max_logic_stack > s.Limits.logic_stack or profile.max_logic_instructions == 0 or profile.max_logic_instructions > s.Limits.logic_instructions) return error.ResourceLimitExceeded;
    if (t.states.len > s.Limits.selection_states or t.parameters.len > s.Limits.selection_parameters or t.contexts.len > s.Limits.selection_contexts or t.selectors.len > s.Limits.selection_selectors or t.logic.len > s.Limits.logic_programs or t.instructions.len > s.Limits.logic_total_instructions or t.transitions.len > s.Limits.selection_transitions or t.segments.len > s.Limits.records or t.candidates.len > s.Limits.selection_selectors * s.Limits.selector_candidates) return error.ResourceLimitExceeded;
    inline for (.{ "states", "parameters", "contexts", "selectors", "logic", "transitions", "segments" }) |name| if (@field(t, name).len > profile.max_table_records) return error.ResourceLimitExceeded;
    // Flat tables include valid unowned records, so profile ceilings apply
    // independently of referenced program and selector ranges.
    if (t.candidates.len > profile.max_table_records or t.instructions.len > @as(u64, profile.max_table_records) * profile.max_logic_instructions) return error.ResourceLimitExceeded;
    const largest = @max(t.states.len, t.parameters.len, t.contexts.len, t.selectors.len, t.logic.len, t.segments.len, t.transitions.len);
    const scratch = try allocator.alloc(u64, largest);
    defer allocator.free(scratch);
    try names(t.states, scratch);
    try names(t.parameters, scratch);
    try names(t.contexts, scratch);
    try names(t.selectors, scratch);
    try names(t.logic, scratch);
    try names(t.segments, scratch);
    try names(t.transitions, scratch);
    for (t.parameters) |v| {
        const lo = try quantize(v.minimum);
        const hi = try quantize(v.maximum);
        const initial = try quantize(v.initial);
        if (v.minimum > v.maximum or v.initial < v.minimum or v.initial > v.maximum or lo > hi or initial < lo or initial > hi) return error.InvalidMusicGraph;
    }
    for (t.contexts) |v| {
        if (!std.math.isFinite(v.initial_scalar)) return error.InvalidMusicGraph;
        switch (v.kind) {
            .boolean => if ((v.initial_integer != 0 and v.initial_integer != 1) or v.initial_scalar != 0 or v.initial_id != 0) return error.InvalidMusicGraph,
            .integer => if (v.initial_scalar != 0 or v.initial_id != 0) return error.InvalidMusicGraph,
            .scalar => {
                _ = try quantize(v.initial_scalar);
                if (v.initial_integer != 0 or v.initial_id != 0) return error.InvalidMusicGraph;
            },
            .id => if (v.initial_id == 0 or v.initial_integer != 0 or v.initial_scalar != 0) return error.InvalidMusicGraph,
        }
    }
    for (t.instructions) |op| try operand(t, op);
    for (t.candidates) |candidate| {
        try reference(candidate.segment, t.segments.len);
        try optionalReference(candidate.condition, t.logic.len);
    }
    for (t.logic) |v| {
        _ = try program(t, try items(s.Instruction, t.instructions, v.instructions), v.stack_limit, profile);
    }
    for (t.selectors) |v| {
        const pool = try items(s.Candidate, t.candidates, v.candidates);
        if (pool.len > s.Limits.selector_candidates or pool.len > profile.max_planner_candidates or v.history_capacity > s.Limits.selector_history or v.no_repeat_window > v.history_capacity) return error.ResourceLimitExceeded;
        if (v.kind == .fixed and pool.len != 1) return error.InvalidMusicGraph;
        if (v.kind == .shuffle and (pool.len > v.history_capacity or v.history_capacity == 0)) return error.InvalidMusicGraph;
        if ((v.kind == .history or v.kind == .no_repeat) and (v.history_capacity == 0 or v.no_repeat_window > pool.len or v.no_repeat_window == 0)) return error.InvalidMusicGraph;
        if (v.kind != .history and v.kind != .no_repeat and v.no_repeat_window != 0) return error.InvalidMusicGraph;
        if (v.exhaustion == .fallback) {
            try reference(v.fallback_segment, t.segments.len);
        } else if (v.fallback_segment != s.none) return error.InvalidMusicGraph;
        var total: u64 = 0;
        for (pool, 0..) |candidate, i| {
            try reference(candidate.segment, t.segments.len);
            try optionalReference(candidate.condition, t.logic.len);
            if (i > 0 and candidate.authored_order <= pool[i - 1].authored_order) return error.InvalidMusicGraph;
            for (pool[0..i]) |prior| if (candidate.segment == prior.segment) return error.InvalidMusicGraph;
            total += candidate.weight;
        }
        if ((v.kind == .weighted_random or v.kind == .no_repeat) and pool.len > 0 and total == 0) return error.InvalidMusicGraph;
    }
    for (t.states) |v| {
        try reference(v.selector, t.selectors.len);
        if (v.required > 1) return error.InvalidMusicGraph;
    }
    const rule_keys = try allocator.alloc(RuleKey, t.transitions.len);
    defer allocator.free(rule_keys);
    for (t.transitions, 0..) |v, i| {
        try reference(v.from, t.states.len);
        try reference(v.to, t.states.len);
        try reference(v.selector, t.selectors.len);
        try optionalReference(v.condition, t.logic.len);
        rule_keys[i] = .{ .from = v.from, .to = v.to, .priority = v.priority, .specificity = v.specificity, .authored = v.authored_order };
    }
    std.mem.sort(RuleKey, rule_keys[0..t.transitions.len], {}, ruleLess);
    for (rule_keys[0..t.transitions.len], 0..) |key, i| if (i > 0 and std.meta.eql(key, rule_keys[i - 1])) return error.InvalidMusicGraph;
}
/// Peak simultaneous initialization scratch; no automatic large arrays.
pub const maximum_scratch_bytes: usize = s.Limits.records * @sizeOf(u64) + s.Limits.selection_transitions * @sizeOf(RuleKey);
