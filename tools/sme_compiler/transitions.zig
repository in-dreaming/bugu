//! Actual TASK-009 source producer and source-bound post-pass verification.
//! Consumes already compiled tempo/media tables and authored path declarations.
const std = @import("std");
const bank = @import("sme-bank");
const s = bank.schema;
const compiler = @import("sme-compiler");
const v = bank.transition_validation;
pub const Error = compiler.CompileError;
pub fn install(registry: *compiler.Registry) Error!void {
    try registry.registerPass(.transitions, runPass);
    try registry.registerValidator(.transitions, validateCompiledSource);
}
fn less(_: void, a: s.TransitionPath, b: s.TransitionPath) bool {
    if (a.transition != b.transition) return a.transition < b.transition;
    return a.key.id < b.key.id;
}
fn sourceBindings(ast: *const compiler.SourceAST, t: s.Tables) Error!void {
    if (ast.metadata.profile >= ast.tables.platforms.len or ast.metadata.profile >= t.platforms.len) return error.InvalidMusicGraph;
    inline for (.{ "max_planner_candidates", "max_planner_phases", "max_fill_steps", "max_required_chunks", "planner_minimum_window_frames", "max_table_records" }) |field| if (@field(ast.tables.platforms[ast.metadata.profile], field) != @field(t.platforms[ast.metadata.profile], field)) return error.InvalidMusicGraph;
    if (ast.tables.cues.len != t.cues.len or ast.tables.segments.len != t.segments.len) return error.InvalidMusicGraph;
    for (ast.tables.cues, t.cues) |source, actual| {
        inline for (.{ "key", "segment", "kind", "tick", "harmony", "phrase", "energy", "beat_role", "tail_frames", "min_lead_frames" }) |field| if (!std.meta.eql(@field(source, field), @field(actual, field))) return error.InvalidMusicGraph;
        if (source.frame != 0 and source.frame != actual.frame) return error.AnchorMismatch;
        if (actual.segment >= t.segments.len or t.segments[actual.segment].tempo >= t.tempos.len) return error.InvalidReference;
        if (actual.frame != try bank.tempo_validation.frameForTick(t, t.tempos[t.segments[actual.segment].tempo], actual.tick)) return error.AnchorMismatch;
    }
    for (ast.tables.segments, t.segments) |source, actual| {
        inline for (.{ "key", "theme", "tempo", "layers", "cues", "pickup_ticks", "harmony", "phrase", "energy", "emergency", "fallback_segment" }) |field| if (!std.meta.eql(@field(source, field), @field(actual, field))) return error.InvalidMusicGraph;
    }
}
pub fn runPass(owned: *compiler.OwnedIR, ast: *const compiler.SourceAST) Error!void {
    if (ast.metadata.profile >= ast.tables.platforms.len) return error.InvalidSource;
    const profile = ast.tables.platforms[ast.metadata.profile];
    try v.validateLimits(ast.tables, profile);
    try sourceBindings(ast, owned.ir.tables);
    var bounds = owned.ir.tables;
    bounds.transitions = ast.tables.transitions;
    bounds.transition_paths = ast.tables.transition_paths;
    bounds.fills = ast.tables.fills;
    bounds.fill_steps = ast.tables.fill_steps;
    try v.validatePlanBounds(bounds, profile);
    const a = owned.arena.allocator();
    const rules = try a.dupe(s.Transition, ast.tables.transitions);
    var paths: std.ArrayList(s.TransitionPath) = .empty;
    // Validate references before canonicalization. No orphan declaration drops.
    for (ast.tables.transition_paths) |path| {
        if (path.transition >= rules.len) return error.InvalidReference;
        try paths.append(a, path);
    }
    for (rules, 0..) |rule, i| {
        var authored = false;
        for (ast.tables.transition_paths) |path| if (path.transition == i) {
            authored = true;
            break;
        };
        // Existing exact cue/fill references are themselves an explicit authored
        // single path. Its ID is the transition ID in the separate path namespace.
        if (!authored) {
            if (paths.items.len >= v.max_paths or paths.items.len >= profile.max_table_records) return error.ResourceLimitExceeded;
            try paths.append(a, .{ .key = .{ .id = rule.key.id }, .transition = @intCast(i), .source_exit = rule.source_exit, .target_entry = rule.target_entry, .fill = rule.fill });
        }
    }
    std.mem.sort(s.TransitionPath, paths.items, {}, less);
    var at: usize = 0;
    for (rules, 0..) |*rule, i| {
        const first = at;
        while (at < paths.items.len and paths.items[at].transition == i) : (at += 1) {}
        rule.paths = .{ .first = @intCast(first), .count = @intCast(at - first) };
    }
    var result = owned.ir.tables;
    result.transitions = rules;
    result.transition_paths = paths.items;
    result.fills = try a.dupe(s.Fill, ast.tables.fills);
    result.fill_steps = try a.dupe(s.FillStep, ast.tables.fill_steps);
    try v.validate(a, result, profile, true);
    owned.ir.tables = result;
}
pub fn validateCompiledSource(allocator: std.mem.Allocator, ast: *const compiler.SourceAST, ir: *const s.ValidatedIR) Error!void {
    if (ir.metadata.profile != ast.metadata.profile or ir.metadata.profile >= ir.tables.platforms.len) return error.InvalidMusicGraph;
    try sourceBindings(ast, ir.tables);
    var expected = compiler.OwnedIR.init(allocator);
    defer expected.deinit();
    expected.ir.tables = ir.tables;
    try runPass(&expected, ast);
    inline for (.{ "transitions", "transition_paths", "fills", "fill_steps" }) |field| {
        const actual = @field(ir.tables, field);
        const wanted = @field(expected.ir.tables, field);
        if (actual.len != wanted.len) return error.InvalidMusicGraph;
        for (actual, wanted) |a, b| if (!std.meta.eql(a, b)) return error.InvalidMusicGraph;
    }
    try v.validate(allocator, ir.tables, ir.tables.platforms[ir.metadata.profile], true);
}
