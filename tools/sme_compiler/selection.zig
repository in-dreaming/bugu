//! Canonical authored-order pool producer and source-bound post-pass validator.
const std = @import("std");
const bank = @import("sme-bank");
pub const s = bank.schema;
const v = bank.selection_validation;
const compiler = @import("sme-compiler");
pub const Error = compiler.CompileError;
pub fn install(registry: *compiler.Registry) Error!void {
    try registry.registerPass(.selection, runPass);
    try registry.registerValidator(.selectors, validateCompiledSource);
}
fn less(_: void, a: s.Candidate, b: s.Candidate) bool {
    return a.authored_order < b.authored_order;
}
pub fn runPass(owned: *compiler.OwnedIR, ast: *const compiler.SourceAST) Error!void {
    if (ast.tables.selectors.len > s.Limits.selection_selectors or ast.tables.candidates.len > s.Limits.selection_selectors * s.Limits.selector_candidates) return error.ResourceLimitExceeded;
    for (ast.tables.candidates) |candidate| {
        if (candidate.segment >= ast.tables.segments.len or (candidate.condition != s.none and candidate.condition >= ast.tables.logic.len)) return error.InvalidMusicGraph;
    }
    const a = owned.arena.allocator();
    const selectors = try a.dupe(s.Selector, ast.tables.selectors);
    var pool: std.ArrayList(s.Candidate) = .empty;
    for (selectors) |*selector| {
        const source = try v.items(s.Candidate, ast.tables.candidates, selector.candidates);
        if (source.len > s.Limits.selector_candidates) return error.ResourceLimitExceeded;
        const first = pool.items.len;
        try pool.appendSlice(a, source);
        std.mem.sort(s.Candidate, pool.items[first..], {}, less);
        selector.candidates = .{ .first = @intCast(first), .count = @intCast(source.len) };
    }
    owned.ir.tables.states = try a.dupe(s.State, ast.tables.states);
    owned.ir.tables.parameters = try a.dupe(s.Parameter, ast.tables.parameters);
    owned.ir.tables.contexts = try a.dupe(s.Context, ast.tables.contexts);
    owned.ir.tables.selectors = selectors;
    owned.ir.tables.candidates = pool.items;
}
pub fn validateCompiledSource(allocator: std.mem.Allocator, ast: *const compiler.SourceAST, ir: *const s.ValidatedIR) Error!void {
    var expected = compiler.OwnedIR.init(allocator);
    defer expected.deinit();
    try runPass(&expected, ast);
    inline for (.{ "states", "parameters", "contexts", "selectors", "candidates" }) |name| {
        const actual = @field(ir.tables, name);
        const wanted = @field(expected.ir.tables, name);
        if (actual.len != wanted.len) return error.InvalidMusicGraph;
        for (actual, wanted) |entry, source| if (!std.meta.eql(entry, source)) return error.InvalidMusicGraph;
    }
    if (ir.tables.transitions.len != ast.tables.transitions.len or ir.tables.segments.len != ast.tables.segments.len) return error.InvalidMusicGraph;
    for (ir.tables.transitions, ast.tables.transitions) |actual, authored| if (!std.meta.eql(actual, authored)) return error.InvalidMusicGraph;
    for (ir.tables.segments, ast.tables.segments) |actual, authored| if (actual.key.id != authored.key.id) return error.InvalidMusicGraph;
    if (ir.metadata.profile >= ir.tables.platforms.len) return error.InvalidMusicGraph;
    try v.validate(allocator, ir.tables, ir.tables.platforms[ir.metadata.profile]);
}
