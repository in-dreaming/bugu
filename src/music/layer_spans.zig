//! Pure prepared gain-program contract. No runtime, mixer, bank or owner imports.
//! Gain primitives preserve the existing old-value-on-command-frame semantics.
const std = @import("std");
pub const contract = @import("sme-layer-contract");
pub const Error = error{ InvalidLayerProgram, LayerProgramBudgetExceeded, StaleLayerProgram, LayerProgramBusy, UnsupportedLayerPolicy, UnsupportedLayerSource };
pub const max_programs = 24;
pub const max_tracks = 16;
pub const max_retained_tracks = 320;
pub const max_retained_spans = 65_536;
pub const max_metadata_bytes = 16 * 1024 * 1024;
pub const max_tick_visits = 1_048_576;
pub const max_loop_seams = 4096;
pub const Profile = struct {
    version: u16 = 1,
    programs: u16 = max_programs,
    tracks: u16 = max_retained_tracks,
    spans: u32 = max_retained_spans,
    metadata_bytes: u32 = max_metadata_bytes,
    tick_visits: u32 = max_tick_visits,
    loop_seams: u32 = max_loop_seams,
    pub fn validate(self: Profile) Error!void {
        if (self.version != 1 or self.programs == 0 or self.programs > max_programs or self.tracks == 0 or self.tracks > max_retained_tracks or self.spans == 0 or self.spans > max_retained_spans or self.metadata_bytes == 0 or self.metadata_bytes > max_metadata_bytes or self.tick_visits == 0 or self.tick_visits > max_tick_visits or self.loop_seams > max_loop_seams) return error.LayerProgramBudgetExceeded;
    }
};
pub const ProgramHandle = struct {
    context: u64,
    index: u16,
    generation: u64,
    pub fn eql(a: ProgramHandle, b: ProgramHandle) bool {
        return std.meta.eql(a, b);
    }
};
pub const GroupIdentity = struct { index: u16, generation: u64 };
pub const Loop = struct { start: u64, end: u64 };
pub const Anchor = struct {
    source_incarnation: u64 = 1,
    context: u64,
    group: GroupIdentity,
    bank_generation: u64,
    binding_revision: u64 = 1,
    mutation_epoch: u64,
    transport_epoch: u64,
    install_frame: u64,
    cursor: u64,
    loop_epoch: u64,
    source_frames: u64,
    sample_rate: u32,
    channels: u8,
    loop: ?Loop = null,
    expected_previous: ?ProgramHandle = null,
};
pub const Range = struct { first: u32, count: u32 };
pub const Domain = enum(u8) { frames, quarter_beats };
pub const Rounding = enum(u8) { exact, nearest_ties_even, rounded_instant };
pub const Span = struct { end_offset: u64, target: f32, remaining_max: f32 = 4 };
pub const TrackDesc = struct {
    ordinal: u16,
    stable_layer_id: u64,
    spans: Range,
    initial_prediction: f32,
    final_target: f32,
    source_endpoint: u64,
    instant: bool = false,
    domain: Domain = .frames,
    duration_numerator: u64,
    duration_denominator: u64 = 1,
    endpoint_rounding: Rounding = .exact,
    /// Canonical ideal endpoint in unfolded tick units, retained for audit.
    endpoint_tick_numerator: u256 = 0,
    endpoint_tick_denominator: u256 = 1,
};
pub const ProgramDesc = struct {
    version: u16 = 1,
    profile: Profile = .{},
    anchor: Anchor,
    tracks: []const TrackDesc,
    spans: []const Span,
    tempo_hash: [32]u8 = @splat(0),
    content_hash: [32]u8 = @splat(0),
    target_mask: u16,
};
pub const TerminalReason = enum(u8) { completed, stopped, superseded, paused, plan_epoch_invalidated, transport_invalidated, asset_invalidated, source_replaced, group_ended, group_stopped, shutdown, install_rejected };
pub const Terminal = struct {
    reason: TerminalReason,
    frame: u64,
    release_frontier: u64,
    elapsed_source_frames: u64,
    gain_bits: u32,
    audible: bool,
};
pub const Primitive = struct { target: f32, frames: u32 };
/// Render-owned fixed cursor. Immutable storage is retained by the manager.
/// The group clears its cursor pointer before manager publishes terminal state.
pub const RenderCursor = struct {
    program: ProgramHandle,
    track: *const TrackDesc,
    spans: []const Span,
    binding_revision: u64 = 1,
    next_span: u32 = 0,
    elapsed: u64 = 0,
    started: bool = false,
    terminal: ?Terminal = null,
    transitions: u64 = 0,
    pub fn remainingGain(self: *const RenderCursor, current: f32) f32 {
        if (self.terminal != null) return current;
        if (self.track.instant) return @max(current, self.track.final_target);
        const index: usize = if (self.next_span == 0) 0 else self.next_span - 1;
        return @max(current, self.spans[index].remaining_max);
    }
    pub fn beforeCapture(self: *RenderCursor) ?Primitive {
        if (self.terminal != null) return null;
        if (self.track.instant) {
            if (self.started) return null;
            self.started = true;
            self.transitions += 1;
            return .{ .target = self.track.final_target, .frames = 0 };
        }
        if (self.next_span >= self.spans.len) return null;
        const start: u64 = if (self.next_span == 0) 0 else self.spans[self.next_span - 1].end_offset;
        if (self.elapsed != start) return null;
        const span = self.spans[self.next_span];
        self.next_span += 1;
        self.started = true;
        self.transitions += 1;
        return .{ .target = span.target, .frames = @intCast(span.end_offset - start) };
    }
    /// Called after successful capture, with the gain actually emitted.
    pub fn afterCapture(self: *RenderCursor, frame: u64, gain: f32, audible: bool) bool {
        if (self.elapsed == self.track.source_endpoint) {
            self.finish(.completed, frame, frame + 1, gain, audible);
            return true;
        }
        self.elapsed += 1;
        return false;
    }
    pub fn finish(self: *RenderCursor, reason: TerminalReason, frame: u64, frontier: u64, gain: f32, audible: bool) void {
        if (self.terminal == null) self.terminal = .{ .reason = reason, .frame = frame, .release_frontier = frontier, .elapsed_source_frames = self.elapsed, .gain_bits = @bitCast(gain), .audible = audible };
    }
};
fn hashInt(h: anytype, value: anytype) void {
    const T = @TypeOf(value);
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    h.update(&bytes);
}
pub fn profileHash(profile: Profile) [32]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update("SME-LAYER-SPANS-PROFILE-v1");
    inline for (@typeInfo(Profile).@"struct".fields) |f| hashInt(&h, @field(profile, f.name));
    var result: [32]u8 = undefined;
    h.final(&result);
    return result;
}
pub fn contentHash(desc: ProgramDesc) [32]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update("SME-LAYER-SPANS-v1");
    hashInt(&h, desc.version);
    inline for (@typeInfo(Profile).@"struct".fields) |f| hashInt(&h, @field(desc.profile, f.name));
    const a = desc.anchor;
    for ([_]u64{ a.context, a.group.index, a.group.generation, a.bank_generation, a.binding_revision, a.mutation_epoch, a.transport_epoch, a.install_frame, a.cursor, a.loop_epoch, a.source_frames, a.sample_rate, a.channels, @intFromBool(a.loop != null) }) |v| hashInt(&h, v);
    if (a.loop) |loop| {
        hashInt(&h, loop.start);
        hashInt(&h, loop.end);
    }
    hashInt(&h, @as(u8, @intFromBool(a.expected_previous != null)));
    if (a.expected_previous) |p| {
        hashInt(&h, p.context);
        hashInt(&h, p.index);
        hashInt(&h, p.generation);
    }
    if (a.source_incarnation != 1) {
        h.update("LAYER-SOURCE-INCARNATION-V1");
        hashInt(&h, a.source_incarnation);
    }
    h.update(&desc.tempo_hash);
    hashInt(&h, desc.target_mask);
    hashInt(&h, @as(u32, @intCast(desc.tracks.len)));
    for (desc.tracks) |t| {
        hashInt(&h, t.ordinal);
        hashInt(&h, t.stable_layer_id);
        hashInt(&h, t.spans.first);
        hashInt(&h, t.spans.count);
        hashInt(&h, @as(u32, @bitCast(t.initial_prediction)));
        hashInt(&h, @as(u32, @bitCast(t.final_target)));
        hashInt(&h, t.source_endpoint);
        hashInt(&h, @as(u8, @intFromBool(t.instant)));
        hashInt(&h, @as(u8, @intFromEnum(t.domain)));
        hashInt(&h, t.duration_numerator);
        hashInt(&h, t.duration_denominator);
        hashInt(&h, @as(u8, @intFromEnum(t.endpoint_rounding)));
        hashInt(&h, t.endpoint_tick_numerator);
        hashInt(&h, t.endpoint_tick_denominator);
    }
    hashInt(&h, @as(u32, @intCast(desc.spans.len)));
    for (desc.spans) |s| {
        hashInt(&h, s.end_offset);
        hashInt(&h, @as(u32, @bitCast(s.target)));
        hashInt(&h, @as(u32, @bitCast(s.remaining_max)));
    }
    var result: [32]u8 = undefined;
    h.final(&result);
    return result;
}
pub fn validate(desc: ProgramDesc) Error!void {
    try desc.profile.validate();
    const a = desc.anchor;
    if (desc.version != 1 or a.source_incarnation == 0 or a.context == 0 or a.group.generation == 0 or a.bank_generation == 0 or a.binding_revision == 0 or a.mutation_epoch == 0 or a.transport_epoch == 0 or a.source_frames == 0 or a.cursor >= a.source_frames or a.sample_rate == 0 or a.channels == 0 or a.channels > 8 or desc.tracks.len == 0 or desc.tracks.len > max_tracks or desc.tracks.len > desc.profile.tracks or desc.spans.len > desc.profile.spans or @sizeOf(ProgramDesc) + desc.tracks.len * @sizeOf(TrackDesc) + desc.spans.len * @sizeOf(Span) > desc.profile.metadata_bytes) return error.InvalidLayerProgram;
    if (a.install_frame > std.math.maxInt(u64) - 65) return error.InvalidLayerProgram;
    if (a.loop) |l| if (l.start >= l.end or l.end > a.source_frames or a.cursor >= l.end) return error.InvalidLayerProgram;
    var mask: u16 = 0;
    var first: u32 = 0;
    for (desc.tracks) |t| {
        if (t.ordinal >= max_tracks or t.stable_layer_id == 0 or t.duration_denominator == 0 or t.endpoint_tick_denominator == 0 or t.spans.first != first or @as(u64, t.spans.first) + t.spans.count > desc.spans.len) return error.InvalidLayerProgram;
        const bit = @as(u16, 1) << @intCast(t.ordinal);
        if (mask & bit != 0) return error.InvalidLayerProgram;
        mask |= bit;
        _ = contract.validateGain(t.initial_prediction, .reject) catch return error.InvalidLayerProgram;
        _ = contract.validateGain(t.final_target, .reject) catch return error.InvalidLayerProgram;
        if (t.instant != (t.source_endpoint == 0) or t.instant != (t.spans.count == 0)) return error.InvalidLayerProgram;
        if (t.source_endpoint > std.math.maxInt(u64) - a.install_frame - 1) return error.InvalidLayerProgram;
        var end: u64 = 0;
        var max: f32 = t.final_target;
        const track_spans = desc.spans[t.spans.first..][0..t.spans.count];
        for (track_spans) |s| {
            _ = contract.validateGain(s.target, .reject) catch return error.InvalidLayerProgram;
            _ = contract.validateGain(s.remaining_max, .reject) catch return error.InvalidLayerProgram;
            if (s.end_offset <= end or s.end_offset - end > std.math.maxInt(u32)) return error.InvalidLayerProgram;
            end = s.end_offset;
        }
        var i = track_spans.len;
        while (i > 0) {
            i -= 1;
            max = @max(max, track_spans[i].target);
            if (track_spans[i].remaining_max < max) return error.InvalidLayerProgram;
        }
        if (end != t.source_endpoint or (!t.instant and track_spans[track_spans.len - 1].target != t.final_target)) return error.InvalidLayerProgram;
        first += t.spans.count;
    }
    if (mask != desc.target_mask or first != desc.spans.len or !std.mem.eql(u8, &contentHash(desc), &desc.content_hash)) return error.InvalidLayerProgram;
}
