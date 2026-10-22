//! Control-only compilation of immutable source-clock gain programs.
//! The caller supplies an admitted clock.Map and a real observed/predicted
//! runtime anchor. No bank validation, map or borrowed source escapes compile.
const std = @import("std");
const spans = @import("sme-layer-spans");
const contract = @import("sme-layer-contract");
const clock = @import("sme-clock");
pub const Error = spans.Error || clock.Error || std.mem.Allocator.Error || error{ InvalidGain, InvalidDuration, UnsafeFrameRange };
pub const TrackRequest = struct {
    ordinal: u16,
    stable_layer_id: u64,
    from: f32,
    to: f32,
    duration: contract.Duration,
};
pub const OwnedProgram = struct {
    allocator: std.mem.Allocator,
    desc: spans.ProgramDesc,
    pub fn deinit(self: *OwnedProgram) void {
        self.allocator.free(self.desc.tracks);
        self.allocator.free(self.desc.spans);
        self.* = undefined;
    }
};

fn gcd(a_: u256, b_: u256) u256 {
    var a = a_;
    var b = b_;
    while (b != 0) {
        const r = a % b;
        a = b;
        b = r;
    }
    return a;
}
fn narrow(value: u512) Error!u256 {
    return std.math.cast(u256, value) orelse error.UnsafeFrameRange;
}
/// Reduced fractions; every product/addition is checked before narrowing.
const Rational = struct {
    n: u256,
    d: u256,
    fn init(n: u256, d: u256) Error!Rational {
        if (d == 0) return error.InvalidDuration;
        const g = gcd(n, d);
        return .{ .n = n / g, .d = d / g };
    }
    fn integer(n: u256) Rational {
        return .{ .n = n, .d = 1 };
    }
    fn plus(a: Rational, b: Rational) Error!Rational {
        const g = gcd(a.d, b.d);
        const sum = @addWithOverflow(@as(u512, a.n) * (b.d / g), @as(u512, b.n) * (a.d / g));
        if (sum[1] != 0) return error.UnsafeFrameRange;
        const common = gcd(@intCast(sum[0] % g), g);
        return init(try narrow(sum[0] / common), try narrow(@as(u512, a.d) * (b.d / g) / common));
    }
    fn minus(a: Rational, b: Rational) Error!Rational {
        const g = gcd(a.d, b.d);
        const left = @as(u512, a.n) * (b.d / g);
        const right = @as(u512, b.n) * (a.d / g);
        if (left < right) return error.InvalidTempo;
        const common = gcd(@intCast((left - right) % g), g);
        return init(try narrow((left - right) / common), try narrow(@as(u512, a.d) * (b.d / g) / common));
    }
    fn times(a: Rational, b: Rational) Error!Rational {
        const g1 = gcd(a.n, b.d);
        const g2 = gcd(b.n, a.d);
        return init(try narrow(@as(u512, a.n / g1) * (b.n / g2)), try narrow(@as(u512, a.d / g2) * (b.d / g1)));
    }
    fn divided(a: Rational, b: Rational) Error!Rational {
        if (b.n == 0) return error.InvalidTempo;
        return a.times(.{ .n = b.d, .d = b.n });
    }
    fn order(a: Rational, b: Rational) std.math.Order {
        return std.math.order(@as(u512, a.n) * b.d, @as(u512, b.n) * a.d);
    }
    fn float(a: Rational) f64 {
        return @as(f64, @floatFromInt(a.n)) / @as(f64, @floatFromInt(a.d));
    }
};
const Work = struct {
    profile: spans.Profile,
    visits: u32 = 0,
    seams: u32 = 0,
    fn charge(self: *Work, count: usize) Error!void {
        if (count > self.profile.tick_visits - self.visits) return error.LayerProgramBudgetExceeded;
        self.visits += @intCast(count);
    }
    fn seam(self: *Work) Error!void {
        if (self.seams == self.profile.loop_seams) return error.LayerProgramBudgetExceeded;
        self.seams += 1;
    }
    fn frame(self: *Work, map: clock.Map, tick: u64) Error!u64 {
        try self.charge(1);
        return map.frameAtTick(tick);
    }
    fn floor(self: *Work, map: clock.Map, frame_: u64) Error!u64 {
        var lo: u64 = 0;
        var hi = map.tempo.total_ticks;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2 + (hi - lo) % 2;
            if (try self.frame(map, mid) <= frame_) lo = mid else hi = mid - 1;
        }
        return lo;
    }
};
fn hashNumber(h: anytype, value: anytype) void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .@"struct" => inline for (@typeInfo(T).@"struct".fields) |field| hashNumber(h, @field(value, field.name)),
        .@"enum" => hashNumber(h, @intFromEnum(value)),
        .int => {
            var bytes: [@sizeOf(T)]u8 = undefined;
            std.mem.writeInt(T, &bytes, value, .little);
            h.update(&bytes);
        },
        else => @compileError("Only explicit numeric tempo metadata is hashed"),
    }
}
/// Fingerprint the admitted mapping, not unrelated global table storage,
/// pointers, padding, BPM estimates, or meter-pulse interpretations.
fn mapHash(map: clock.Map, work: *Work) Error![32]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update("SME-LAYER-SOURCE-CLOCK-v1");
    hashNumber(&h, map.tempo);
    hashNumber(&h, @as(u64, @intCast(map.queries.len)));
    try work.charge(map.queries.len);
    for (map.queries) |q| {
        hashNumber(&h, q);
        if (q.kind == .materialized) {
            const end = @as(u64, q.frames.first) + q.frames.count;
            if (end > map.tick_frames.len) return error.InvalidTempo;
            const values = map.tick_frames[q.frames.first..@intCast(end)];
            try work.charge(values.len);
            for (values) |f| hashNumber(&h, f);
        }
    }
    var result: [32]u8 = undefined;
    h.final(&result);
    return result;
}
fn validateAnchor(a: spans.Anchor) Error!void {
    if (a.source_incarnation == 0 or a.context == 0 or a.group.generation == 0 or a.bank_generation == 0 or a.binding_revision == 0 or a.mutation_epoch == 0 or a.transport_epoch == 0 or a.source_frames == 0 or a.cursor >= a.source_frames or a.sample_rate == 0 or a.channels == 0 or a.channels > 8) return error.InvalidLayerProgram;
    if (a.install_frame > std.math.maxInt(u64) - 65) return error.UnsafeFrameRange;
    if (a.loop) |loop| {
        if (loop.start >= loop.end or loop.end > a.source_frames or a.cursor >= loop.end) return error.InvalidLayerProgram;
    }
    // seek/setLoop preserve the runtime epoch. It is an identity binding,
    // not proof that the present cursor has already passed this loop start.
}
fn validateMap(a: spans.Anchor, map: clock.Map, work: *Work) Error!void {
    // Map.init/Compiled.map are the typed admission authority. This checks the
    // source binding only, and deliberately does not revalidate a MusicBank.
    if (a.sample_rate != 48_000 or a.source_frames != map.tempo.total_frames or map.tempo.ppq == 0 or map.tempo.total_ticks == 0 or map.tempo.loop_present > 1 or map.queries.len == 0) return error.InvalidLayerProgram;
    if (try work.frame(map, 0) != 0 or try work.frame(map, map.tempo.total_ticks) != a.source_frames) return error.InvalidTempo;
    if (a.loop) |loop| {
        if (map.tempo.loop_present != 1 or map.tempo.loop_start_tick >= map.tempo.loop_end_tick or map.tempo.loop_end_tick > map.tempo.total_ticks) return error.InvalidLayerProgram;
        if (try work.frame(map, map.tempo.loop_start_tick) != loop.start or try work.frame(map, map.tempo.loop_end_tick) != loop.end) return error.InvalidLayerProgram;
    } else if (map.tempo.loop_present != 0) return error.InvalidLayerProgram;
}
const Knot = struct { frame: u128, tick: u128 };
const Grid = struct {
    map: clock.Map,
    work: *Work,
    loop: ?spans.Loop,
    epoch: u64,
    tick: u64,
    pending: ?Knot = null,
    fn current(self: *Grid) Error!Knot {
        const f = try self.work.frame(self.map, self.tick);
        return .{
            .frame = @as(u128, f) + if (self.loop) |l| @as(u128, self.epoch) * (l.end - l.start) else 0,
            .tick = @as(u128, self.tick) + if (self.loop != null) @as(u128, self.epoch) * (self.map.tempo.loop_end_tick - self.map.tempo.loop_start_tick) else 0,
        };
    }
    fn rawNext(self: *Grid) Error!?Knot {
        if (self.loop != null and self.tick == self.map.tempo.loop_end_tick) {
            try self.work.seam();
            self.epoch = std.math.add(u64, self.epoch, 1) catch return error.UnsafeFrameRange;
            self.tick = self.map.tempo.loop_start_tick;
        } else {
            if (self.tick == self.map.tempo.total_ticks) return null;
            self.tick += 1;
        }
        return try self.current();
    }
    /// Collapse an entire same-frame run to its greatest unfolded tick. At a
    /// loop seam this includes the end, next start, and start-frame duplicates.
    fn next(self: *Grid) Error!?Knot {
        var candidate = self.pending orelse (try self.rawNext() orelse return null);
        self.pending = null;
        while (try self.rawNext()) |next_| {
            if (next_.frame < candidate.frame or next_.tick < candidate.tick) return error.InvalidTempo;
            if (next_.frame != candidate.frame) {
                self.pending = next_;
                break;
            }
            candidate = next_;
        }
        return candidate;
    }
};
fn valueAt(request: TrackRequest, progress: Rational) f32 {
    const t = std.math.clamp(progress.float(), 0, 1);
    if (t == 0) return request.from;
    if (t == 1) return request.to;
    return @floatCast(@as(f64, request.from) + (@as(f64, request.to) - request.from) * t);
}
const Sink = struct {
    profile: spans.Profile,
    tracks_len: usize,
    storage: ?[]spans.Span = null,
    count: usize = 0,
    first: usize = 0,
    end: u64 = 0,
    last_target: f32 = 0,
    fn begin(self: *Sink, from: f32) void {
        self.first = self.count;
        self.end = 0;
        self.last_target = from;
    }
    fn checkBytes(self: Sink, count: usize) Error!void {
        const bytes = @sizeOf(spans.ProgramDesc) + @as(u64, @intCast(self.tracks_len)) * @sizeOf(spans.TrackDesc) + @as(u64, @intCast(count)) * @sizeOf(spans.Span);
        if (bytes > self.profile.metadata_bytes) return error.LayerProgramBudgetExceeded;
    }
    fn append(self: *Sink, end: u64, target: f32) Error!void {
        if (end < self.end or end - self.end > std.math.maxInt(u32)) return error.InvalidLayerProgram;
        if (end == self.end) {
            if (self.count > self.first) if (self.storage) |storage| {
                storage[self.count - 1].target = target;
            };
            self.last_target = target;
            return;
        }
        if (self.count == self.profile.spans) return error.LayerProgramBudgetExceeded;
        try self.checkBytes(self.count + 1);
        if (self.storage) |storage| {
            if (self.count == storage.len) return error.InvalidLayerProgram;
            storage[self.count] = .{ .end_offset = end, .target = target };
        }
        self.count += 1;
        self.end = end;
        self.last_target = target;
    }
    fn interval(self: *Sink, end: u64, target: f32) Error!void {
        if (end < self.end) return error.InvalidLayerProgram;
        const start = self.end;
        const from = self.last_target;
        const length = end - start;
        while (end - self.end > std.math.maxInt(u32)) {
            const next = self.end + std.math.maxInt(u32);
            const t = @as(f64, @floatFromInt(next - start)) / @as(f64, @floatFromInt(length));
            try self.append(next, @floatCast(@as(f64, from) + (@as(f64, target) - from) * t));
        }
        try self.append(end, target);
    }
};
fn endpointSafe(anchor: spans.Anchor, endpoint: u64) Error!void {
    if (endpoint > std.math.maxInt(u64) - anchor.install_frame - 1) return error.UnsafeFrameRange;
}
fn quarterTrack(anchor: spans.Anchor, request: TrackRequest, map: clock.Map, work: *Work, sink: *Sink, track: *spans.TrackDesc) Error!void {
    const q = request.duration.quarter_beats;
    const duration = try Rational.init(@as(u256, q.numerator) * map.tempo.ppq, q.denominator);
    var grid: Grid = .{ .map = map, .work = work, .loop = anchor.loop, .epoch = anchor.loop_epoch, .tick = try work.floor(map, anchor.cursor) };
    var left = try grid.current();
    const origin: u128 = @as(u128, anchor.cursor) + if (anchor.loop) |l| @as(u128, anchor.loop_epoch) * (l.end - l.start) else 0;
    if (left.frame > origin) return error.InvalidTempo;
    var right: ?Knot = null;
    var start = Rational.integer(left.tick);
    if (left.frame != origin) {
        right = try grid.next() orelse return error.OutOfRange;
        if (right.?.frame <= origin or right.?.tick <= left.tick) return error.InvalidTempo;
        start = try start.plus(try (try Rational.init(origin - left.frame, right.?.frame - left.frame)).times(Rational.integer(right.?.tick - left.tick)));
    }
    const end_tick = try start.plus(duration);
    track.endpoint_tick_numerator = end_tick.n;
    track.endpoint_tick_denominator = end_tick.d;
    if (duration.n == 0) return;
    // Retain only an iterator snapshot. Resolve the rounded endpoint first,
    // then emit the same grid without retaining any map-derived allocation.
    const initial_grid = grid;
    const initial_left = left;
    const initial_right = right;
    var offset: Rational = undefined;
    while (true) {
        const next = right orelse (try grid.next() orelse return error.OutOfRange);
        right = null;
        if (next.frame <= left.frame or next.tick <= left.tick) return error.InvalidTempo;
        if (end_tick.order(Rational.integer(next.tick)) != .gt) {
            const proportion = try (try end_tick.minus(Rational.integer(left.tick))).divided(Rational.integer(next.tick - left.tick));
            const absolute_end = try Rational.integer(left.frame).plus(try proportion.times(Rational.integer(next.frame - left.frame)));
            offset = try absolute_end.minus(Rational.integer(origin));
            break;
        }
        left = next;
    }
    const endpoint = try clock.roundRational(offset.n, offset.d);
    try endpointSafe(anchor, endpoint);
    track.source_endpoint = endpoint;
    track.endpoint_rounding = if (endpoint == 0) .rounded_instant else if (offset.d == 1) .exact else .nearest_ties_even;
    if (endpoint == 0) return;

    // A fractional endpoint must not stretch the entire final tick interval.
    // Preserve the ideal musical value at E-1, then force the exact target at
    // E with one final primitive. This also handles rounding back onto a knot.
    const cap = if (offset.d == 1) endpoint else endpoint - 1;
    grid = initial_grid;
    left = initial_left;
    right = initial_right;
    if (cap != 0) while (true) {
        const next = right orelse (try grid.next() orelse return error.OutOfRange);
        right = null;
        const cap_frame = origin + cap;
        if (next.frame >= cap_frame) {
            if (offset.d == 1) {
                try sink.interval(cap, request.to);
            } else {
                const position = try Rational.integer(left.tick).plus(try (try Rational.init(cap_frame - left.frame, next.frame - left.frame)).times(Rational.integer(next.tick - left.tick)));
                const progress = try (try position.minus(start)).divided(duration);
                try sink.interval(cap, valueAt(request, progress));
            }
            break;
        }
        const frame_offset = std.math.cast(u64, next.frame - origin) orelse return error.UnsafeFrameRange;
        const progress = try (try Rational.integer(next.tick).minus(start)).divided(duration);
        try sink.interval(frame_offset, valueAt(request, progress));
        left = next;
    };
    if (offset.d != 1) try sink.interval(endpoint, request.to);
}
fn compileTrack(anchor: spans.Anchor, request: TrackRequest, musical: ?clock.Map, work: *Work, sink: *Sink) Error!spans.TrackDesc {
    sink.begin(request.from);
    var track: spans.TrackDesc = .{
        .ordinal = request.ordinal,
        .stable_layer_id = request.stable_layer_id,
        .spans = .{ .first = @intCast(sink.count), .count = 0 },
        .initial_prediction = request.from,
        .final_target = request.to,
        .source_endpoint = 0,
        .duration_numerator = 0,
    };
    switch (request.duration) {
        .frames => |frames| {
            try endpointSafe(anchor, frames);
            track.duration_numerator = frames;
            track.source_endpoint = frames;
            try sink.interval(frames, request.to);
        },
        .quarter_beats => |q| {
            track.domain = .quarter_beats;
            track.duration_numerator = q.numerator;
            track.duration_denominator = q.denominator;
            try quarterTrack(anchor, request, musical orelse return error.InvalidDuration, work, sink, &track);
        },
    }
    track.spans.count = @intCast(sink.count - sink.first);
    track.instant = track.source_endpoint == 0;
    // Keep the canonical bound at 4: actual Render gain can exceed the
    // analytic initial prediction, including the start of descending ramps.
    return track;
}

/// Compilation is failure-atomic. A bounded allocation-free count pass runs
/// first; two exact final allocations are the only owned storage. Work budgets
/// cover fingerprinting and both count/write passes, including endpoint resolution,
/// knot emission, and duplicate/loop lookahead.
/// Do not mutate the admitted map concurrently with this Control operation.
pub fn compile(allocator: std.mem.Allocator, anchor: spans.Anchor, tracks: []const TrackRequest, musical: ?clock.Map, profile: spans.Profile) Error!OwnedProgram {
    return compileWithHeapBudget(allocator, anchor, tracks, musical, profile, std.math.maxInt(usize));
}
/// Additional caller-owned heap admission, independent of the descriptor's
/// profile/hash. The exact count pass rejects before either final allocation;
/// an existing owner's arrays may remain live throughout this operation.
pub fn compileWithHeapBudget(allocator: std.mem.Allocator, anchor: spans.Anchor, tracks: []const TrackRequest, musical: ?clock.Map, profile: spans.Profile, max_new_heap_bytes: usize) Error!OwnedProgram {
    try profile.validate();
    try validateAnchor(anchor);
    if (tracks.len == 0 or tracks.len > spans.max_tracks or tracks.len > profile.tracks) return error.LayerProgramBudgetExceeded;
    var mask: u16 = 0;
    var needs_map = false;
    for (tracks) |request| {
        if (request.ordinal >= spans.max_tracks or request.stable_layer_id == 0) return error.InvalidLayerProgram;
        const bit = @as(u16, 1) << @intCast(request.ordinal);
        if (mask & bit != 0) return error.InvalidLayerProgram;
        mask |= bit;
        _ = try contract.validateGain(request.from, .reject);
        _ = try contract.validateGain(request.to, .reject);
        switch (request.duration) {
            .frames => |frames| try endpointSafe(anchor, frames),
            .quarter_beats => |q| {
                if (q.denominator == 0) return error.InvalidDuration;
                needs_map = true;
            },
        }
    }
    var work: Work = .{ .profile = profile };
    var tempo_hash: [32]u8 = @splat(0);
    if (needs_map) {
        const map = musical orelse return error.InvalidDuration;
        try validateMap(anchor, map, &work);
        tempo_hash = try mapHash(map, &work);
    }
    var count: Sink = .{ .profile = profile, .tracks_len = tracks.len };
    try count.checkBytes(0);
    const start_visits = work.visits;
    const start_seams = work.seams;
    for (tracks) |request| _ = try compileTrack(anchor, request, musical, &work, &count);
    // The identical write pass cannot unexpectedly exceed admission after an
    // allocation. Reject aggregate work limits before allocating either array.
    if (work.visits - start_visits > profile.tick_visits - work.visits or work.seams - start_seams > profile.loop_seams - work.seams) return error.LayerProgramBudgetExceeded;
    const heap_bytes = tracks.len * @sizeOf(spans.TrackDesc) + count.count * @sizeOf(spans.Span);
    if (heap_bytes > max_new_heap_bytes) return error.LayerProgramBudgetExceeded;
    const owned_tracks = try allocator.alloc(spans.TrackDesc, tracks.len);
    errdefer allocator.free(owned_tracks);
    const owned_spans = try allocator.alloc(spans.Span, count.count);
    errdefer allocator.free(owned_spans);
    var sink: Sink = .{ .profile = profile, .tracks_len = tracks.len, .storage = owned_spans };
    for (tracks, 0..) |request, i| owned_tracks[i] = try compileTrack(anchor, request, musical, &work, &sink);
    if (sink.count != count.count) return error.InvalidLayerProgram;
    var desc: spans.ProgramDesc = .{ .profile = profile, .anchor = anchor, .tracks = owned_tracks, .spans = owned_spans, .tempo_hash = tempo_hash, .target_mask = mask };
    desc.content_hash = spans.contentHash(desc);
    try spans.validate(desc);
    return .{ .allocator = allocator, .desc = desc };
}
