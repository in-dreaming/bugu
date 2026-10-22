//! Immutable source-clock progress for actual TASK013 scalar parameters.
//! Control reuses the admitted M2 clock compiler. Render seeds live DSP values.
//! No source reader, bank wire format, predicted value, or second DSP exists here.
const std = @import("std");
pub const spans = @import("sme-layer-spans");
pub const compiler = @import("sme-layer-span-compile");
pub const clock = @import("sme-clock");
pub const bg = @import("sme-bus-graph");
pub const contract = @import("sme-layer-contract");
pub const Error = compiler.Error || bg.Error || error{ InvalidGraphProgram, GraphProgramBusy, GraphProgramBudgetExceeded, StaleGraphProgram, UnsupportedGraphClockTarget, UnsupportedGraphSourceHandoff, DrainPending };
// Candidate component limits. Actual fixed/retained/peak allocation sizes must
// be admitted and reported; these limits do not prove the whole-context budget.
pub const max_programs = 16;
pub const max_targets = 64;
pub const max_retained_spans = 16_384;
pub const max_metadata_bytes = 2 * 1024 * 1024;
pub const Profile = struct {
    programs: u16 = max_programs,
    targets_per_program: u16 = max_targets,
    spans: u32 = max_retained_spans,
    metadata_bytes: u32 = max_metadata_bytes,
    pub fn validate(self: Profile) Error!void {
        if (self.programs == 0 or self.programs > max_programs or self.targets_per_program == 0 or self.targets_per_program > max_targets or self.spans == 0 or self.spans > max_retained_spans or self.metadata_bytes == 0 or self.metadata_bytes > max_metadata_bytes) return error.GraphProgramBudgetExceeded;
    }
};
pub const Handle = struct {
    context: u64,
    index: u16,
    generation: u64,
    pub fn eql(a: Handle, b: Handle) bool {
        return std.meta.eql(a, b);
    }
};
pub const GraphIdentity = struct { context: u64, index: u16, generation: u64 };
pub const Write = struct { target: bg.Target, value: f32 };
pub const Desc = struct {
    graph: GraphIdentity,
    /// Exactly one normalized 0-to-1 track. Its ordinal selects the logical
    /// source layer; its elapsed clock is the group's shared successful capture.
    progress: spans.ProgramDesc,
    targets: []const Write,
    previous: ?Handle = null,
    profile: Profile = .{},
    content_hash: [32]u8 = @splat(0),
};
pub fn scalarRange(target: bg.Target) Error!struct { min: f32, max: f32 } {
    return switch (target) {
        .channel_gain, .send_gain => .{ .min = 0, .max = 4 },
        .lowpass_hz => .{ .min = 20, .max = 20000 },
        // Wet/bypass and prepared route envelopes are a following vertical slice.
        else => error.UnsupportedGraphClockTarget,
    };
}
pub fn sameTarget(a: bg.Target, b: bg.Target) bool {
    return std.meta.eql(a, b);
}
fn number(hash: anytype, value: anytype) void {
    var bytes: [@sizeOf(@TypeOf(value))]u8 = undefined;
    std.mem.writeInt(@TypeOf(value), &bytes, value, .little);
    hash.update(&bytes);
}
pub fn contentHash(desc: Desc) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("SME-GRAPH-SOURCE-CLOCK-v1");
    hash.update(&desc.progress.content_hash);
    inline for (@typeInfo(Profile).@"struct".fields) |field| number(&hash, @field(desc.profile, field.name));
    number(&hash, desc.graph.context);
    number(&hash, desc.graph.index);
    number(&hash, desc.graph.generation);
    number(&hash, @as(u8, @intFromBool(desc.previous != null)));
    if (desc.previous) |p| {
        number(&hash, p.context);
        number(&hash, p.index);
        number(&hash, p.generation);
    }
    number(&hash, @as(u32, @intCast(desc.targets.len)));
    for (desc.targets) |write| {
        number(&hash, @as(u8, @intCast(@intFromEnum(write.target))));
        switch (write.target) {
            .channel_gain => |v| {
                number(&hash, v.bus);
                number(&hash, v.channel);
            },
            .prepared_route => |v| {
                number(&hash, v.group);
                number(&hash, v.edge);
            },
            inline else => |id| number(&hash, id),
        }
        number(&hash, @as(u32, @bitCast(write.value)));
    }
    var result: [32]u8 = undefined;
    hash.final(&result);
    return result;
}
pub fn validate(desc: Desc) Error!void {
    try desc.profile.validate();
    try spans.validate(desc.progress);
    if (desc.graph.context == 0 or desc.graph.generation == 0 or desc.progress.tracks.len != 1 or desc.progress.anchor.expected_previous != null or desc.targets.len == 0 or desc.targets.len > desc.profile.targets_per_program or desc.progress.spans.len > desc.profile.spans) return error.InvalidGraphProgram;
    const track = desc.progress.tracks[0];
    if (track.initial_prediction != 0 or track.final_target != 1) return error.InvalidGraphProgram;
    var prior: f32 = 0;
    for (desc.progress.spans) |span| {
        if (span.target < prior or span.target > 1) return error.InvalidGraphProgram;
        prior = span.target;
    }
    for (desc.targets, 0..) |write, i| {
        const range = try scalarRange(write.target);
        if (!std.math.isFinite(write.value) or write.value < range.min or write.value > range.max) return error.InvalidGraphProgram;
        for (desc.targets[0..i]) |other| if (sameTarget(write.target, other.target)) return error.GraphProgramBusy;
    }
    if (!std.mem.eql(u8, &contentHash(desc), &desc.content_hash)) return error.InvalidGraphProgram;
}
pub const Owned = struct {
    allocator: std.mem.Allocator,
    progress: compiler.OwnedProgram,
    desc: Desc,
    pub fn deinit(self: *Owned) void {
        self.allocator.free(self.desc.targets);
        self.progress.deinit();
        self.* = undefined;
    }
};
/// Transient producer allocation is admitted together with future consumer
/// copies by the caller's remaining peak budget. No target value seeds Render.
pub fn compile(allocator: std.mem.Allocator, graph: GraphIdentity, anchor: spans.Anchor, ordinal: u16, stable_layer_id: u64, duration: contract.Duration, musical: ?clock.Map, targets: []const Write, previous: ?Handle, profile: Profile, remaining_peak_bytes: usize) Error!Owned {
    try profile.validate();
    if (targets.len == 0 or targets.len > profile.targets_per_program or anchor.expected_previous != null) return error.InvalidGraphProgram;
    for (targets, 0..) |write, i| {
        const range = try scalarRange(write.target);
        if (!std.math.isFinite(write.value) or write.value < range.min or write.value > range.max) return error.InvalidGraphProgram;
        for (targets[0..i]) |other| if (sameTarget(write.target, other.target)) return error.GraphProgramBusy;
    }
    const target_bytes = targets.len * @sizeOf(Write);
    if (remaining_peak_bytes < target_bytes) return error.GraphProgramBudgetExceeded;
    var progress = try compiler.compileWithHeapBudget(allocator, anchor, &.{.{ .ordinal = ordinal, .stable_layer_id = stable_layer_id, .from = 0, .to = 1, .duration = duration }}, musical, .{ .programs = profile.programs, .tracks = 1, .spans = profile.spans, .metadata_bytes = profile.metadata_bytes }, remaining_peak_bytes - target_bytes);
    errdefer progress.deinit();
    const copied = try allocator.dupe(Write, targets);
    errdefer allocator.free(copied);
    var desc: Desc = .{ .graph = graph, .progress = progress.desc, .targets = copied, .previous = previous, .profile = profile };
    desc.content_hash = contentHash(desc);
    try validate(desc);
    return .{ .allocator = allocator, .progress = progress, .desc = desc };
}
pub const Reason = enum(u8) { completed, stopped, superseded, clock_discontinuity, plan_invalidated, transport_invalidated, asset_invalidated, source_replaced, group_ended, group_stopped, graph_retired, shutdown, install_rejected };
pub const Result = struct { reason: Reason, frame: u64, release_frontier: u64, elapsed_source_frames: u64, count: u8, value_bits: [max_targets]u32 = undefined };
/// One Render-owned cursor per program, independent of output audibility. Its
/// caller invokes capture only after a real successful shared-source capture.
pub const Progress = struct {
    elapsed: u64 = 0,
    span_index: usize = 0,
    span_start: u64 = 0,
    initial: [max_targets]f32 = undefined,
    start: [max_targets]f32 = undefined,
    current: [max_targets]f32 = undefined,
    terminal: ?Result = null,
    pub fn init(desc: Desc, actual: []const f32) Error!Progress {
        if (actual.len != desc.targets.len) return error.InvalidGraphProgram;
        var self: Progress = .{};
        for (actual, 0..) |value, i| {
            const range = try scalarRange(desc.targets[i].target);
            if (!std.math.isFinite(value) or value < range.min or value > range.max) return error.InvalidGraphProgram;
            self.initial[i] = value;
            self.start[i] = value;
            self.current[i] = if (desc.progress.tracks[0].instant) desc.targets[i].value else value;
        }
        return self;
    }
    /// Distinct multiply and add in f32, clamped to segment endpoints. Exact
    /// p=0/p=1 branches retain original endpoint bits, including tiny values.
    fn interpolate(start: f32, target: f32, p: f32) f32 {
        if (p == 0) return start;
        if (p == 1) return target;
        const delta: f32 = target - start;
        const scaled: f32 = delta * p;
        return std.math.clamp(start + scaled, @min(start, target), @max(start, target));
    }
    pub fn capture(self: *Progress, desc: Desc, frame: u64) void {
        if (self.terminal != null) return;
        const track = desc.progress.tracks[0];
        if (!track.instant) {
            while (self.elapsed > desc.progress.spans[self.span_index].end_offset) {
                self.span_start = desc.progress.spans[self.span_index].end_offset;
                self.span_index += 1;
                @memcpy(self.start[0..desc.targets.len], self.current[0..desc.targets.len]);
            }
            const span = desc.progress.spans[self.span_index];
            const at_endpoint = self.elapsed == span.end_offset;
            const ratio: f32 = if (at_endpoint) 1 else @as(f32, @floatFromInt(self.elapsed - self.span_start)) / @as(f32, @floatFromInt(span.end_offset - self.span_start));
            for (desc.targets, 0..) |write, i| {
                const target = interpolate(self.initial[i], write.value, span.target);
                self.current[i] = interpolate(self.start[i], target, ratio);
            }
        }
        if (self.elapsed == track.source_endpoint) self.finish(desc, .completed, frame, frame + 1) else self.elapsed += 1;
    }
    pub fn finish(self: *Progress, desc: Desc, reason: Reason, frame: u64, frontier: u64) void {
        if (self.terminal != null) return;
        var result: Result = .{ .reason = reason, .frame = frame, .release_frontier = frontier, .elapsed_source_frames = self.elapsed, .count = @intCast(desc.targets.len) };
        for (self.current[0..desc.targets.len], 0..) |value, i| result.value_bits[i] = @bitCast(value);
        self.terminal = result;
    }
};
