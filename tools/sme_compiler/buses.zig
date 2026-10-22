//! Source-bound producer for the v1 static bus graph. Authored bus order is
//! explicit topological order: every parent/send destination precedes its
//! source. This pass emits owned bus/send records and verifies layer routing;
//! it does not implement effects, sidechains, or a runtime bus graph.
const std = @import("std");
const bank = @import("sme-bank");
const compiler = @import("sme-compiler");
const channels = @import("sme-channels");
const s = bank.schema;
pub const Error = compiler.CompileError;

pub fn install(registry: *compiler.Registry) Error!void {
    try registry.registerPass(.buses, runPass);
    try registry.registerValidator(.buses, validateCompiledSource);
}
fn sameLayout(a: s.Bus, b: s.Bus) bool {
    return a.layout == b.layout and a.channel_mask == b.channel_mask;
}
fn validateGraph(t: s.Tables, profile: s.Platform) Error!void {
    if (profile.max_table_records == 0 or profile.max_table_records > s.Limits.records) return error.ResourceLimitExceeded;
    if (t.buses.len == 0) return error.MissingRequiredTable;
    if (t.buses.len > profile.max_table_records or t.buses.len > s.Limits.records or t.bus_sends.len > profile.max_table_records or t.bus_sends.len > s.Limits.records) return error.ResourceLimitExceeded;
    for (t.bus_sends) |send| {
        if (send.target >= t.buses.len) return error.InvalidReference;
        if (!std.math.isFinite(send.gain_db)) return error.InvalidRecord;
    }
    for (t.buses, 0..) |bus, index| {
        if (!std.math.isFinite(bus.gain_db)) return error.InvalidRecord;
        _ = channels.ChannelLayout.init(bus.layout, @intCast(@popCount(bus.channel_mask)), bus.channel_mask) catch return error.InvalidRecord;
        if (@as(u64, bus.sends.first) + bus.sends.count > t.bus_sends.len) return error.InvalidReference;
        if (bus.parent != s.none) {
            if (bus.parent >= t.buses.len) return error.InvalidReference;
            if (bus.parent >= index) return error.InvalidMusicGraph;
            if (!sameLayout(bus, t.buses[bus.parent])) return error.UnsupportedOperation;
        }
        for (t.bus_sends[bus.sends.first..][0..bus.sends.count]) |send| {
            if (send.target >= index) return error.InvalidMusicGraph;
            if (!sameLayout(bus, t.buses[send.target])) return error.UnsupportedOperation;
        }
    }
    for (t.layers) |layer| {
        if (layer.bus >= t.buses.len or layer.sound >= t.sounds.len) return error.InvalidReference;
        const sound = t.sounds[layer.sound];
        const bus = t.buses[layer.bus];
        if (sound.layout != bus.layout or sound.channel_mask != bus.channel_mask) return error.UnsupportedOperation;
    }
}
fn validateSourceBindings(allocator: std.mem.Allocator, ast: *const compiler.SourceAST, ir: *const s.ValidatedIR) Error!void {
    if (ast.metadata.profile >= ast.tables.platforms.len or ir.metadata.profile != ast.metadata.profile or ir.metadata.profile >= ir.tables.platforms.len) return error.InvalidReference;
    if (ast.tables.platforms[ast.metadata.profile].max_table_records != ir.tables.platforms[ir.metadata.profile].max_table_records) return error.InvalidMusicGraph;
    if (ast.tables.layers.len != ir.tables.layers.len) return error.InvalidMusicGraph;
    for (ast.tables.layers, ir.tables.layers) |authored, actual| if (!std.meta.eql(authored, actual)) return error.InvalidMusicGraph;
    if (ast.tables.buses.len > ast.tables.platforms[ast.metadata.profile].max_table_records or ast.tables.buses.len > s.Limits.records) return error.ResourceLimitExceeded;
    var ids = std.AutoHashMap(u64, void).init(allocator);
    defer ids.deinit();
    for (ast.tables.buses) |bus| {
        const name = try bank.string(ast.tables, bus.key.name);
        if (bus.key.id != try s.music.hashName(name)) return error.IdCollision;
        const entry = try ids.getOrPut(bus.key.id);
        if (entry.found_existing) return error.IdCollision;
    }
}
pub fn runPass(owned: *compiler.OwnedIR, ast: *const compiler.SourceAST) Error!void {
    try validateSourceBindings(owned.arena.allocator(), ast, &owned.ir);
    var next = owned.ir.tables;
    next.buses = ast.tables.buses;
    next.bus_sends = ast.tables.bus_sends;
    try validateGraph(next, ast.tables.platforms[ast.metadata.profile]);
    const allocator = owned.arena.allocator();
    const buses = try allocator.dupe(s.Bus, next.buses);
    const sends = try allocator.dupe(s.BusSend, next.bus_sends);
    next.buses = buses;
    next.bus_sends = sends;
    // Do not publish partial tables if either allocation or validation fails.
    owned.ir.tables = next;
}
pub fn validateCompiledSource(allocator: std.mem.Allocator, ast: *const compiler.SourceAST, ir: *const s.ValidatedIR) Error!void {
    try validateSourceBindings(allocator, ast, ir);
    inline for (.{ "buses", "bus_sends" }) |field| {
        const authored = @field(ast.tables, field);
        const actual = @field(ir.tables, field);
        if (authored.len != actual.len) return error.InvalidMusicGraph;
        for (authored, actual) |source, result| if (!std.meta.eql(source, result)) return error.InvalidMusicGraph;
    }
    try validateGraph(ir.tables, ir.tables.platforms[ir.metadata.profile]);
}
