//! Real four-stem, eight-second no-fill reload derivative. No compiled tables,
//! runtime rings, decoder results or readiness counters are fabricated here.
const std = @import("std");
pub const FinalizationDriver = @import("sme-live-finalization-driver").Driver;
pub const bank = @import("sme-bank");
const compiler = @import("sme-compiler");
const media = @import("sme-media-pipeline");
const opus = @import("sme-opus");
pub const runtime = @import("sme-runtime-v1-fixture");
pub const music = runtime.music;
pub const rt = runtime.audio.runtime;
pub const a = std.testing.allocator;
const t = std.testing;
const reload = music.ResidentReloadV1;
pub const Variant = enum { a, b };
pub const loop_frames: u64 = 384000;
pub const bar_frames: u64 = 96000; // Authored 48000 Hz * 60 * 4 / 120 BPM.
pub const stem_count = 4;
pub const resource_count = 16;
pub const state: music.MusicStateId = @enumFromInt(bank.schema.music.hashName("explore") catch unreachable);
pub const segment_id = bank.schema.music.hashName("explore-loop") catch unreachable;
pub const authored_source = @embedFile("project.toml");
const original_root = "tests/fixtures/sme/readiness_causal/four_stem/";
const changed_paths = [_][]const u8{ "audio/explore-harmony.wav", "audio/explore-bass.wav", "audio/explore-motif.wav", "audio/explore-percussion.wav" };
const divisors = [_]i16{ 2, 3, 4, 5 };

fn original(allocator: std.mem.Allocator, path: []const u8, limit: usize) media.Error![]u8 {
    const full = std.mem.concat(allocator, u8, &.{ original_root, path }) catch return error.OutOfMemory;
    defer allocator.free(full);
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, full, allocator, .limited(limit)) catch return error.SourceReadFailed;
}
fn modify(bytes: []u8, divisor: i16) media.Error!void {
    // The tracked originals are canonical mono PCM16 RIFFs with 44-byte headers.
    if (bytes.len != 44 + loop_frames * 2 or !std.mem.eql(u8, bytes[0..4], "RIFF") or
        !std.mem.eql(u8, bytes[36..40], "data") or std.mem.readInt(u16, bytes[34..36], .little) != 16) return error.SourceReadFailed;
    var offset: usize = 44;
    while (offset < bytes.len) : (offset += 2) {
        const value = std.mem.readInt(i16, bytes[offset..][0..2], .little);
        std.mem.writeInt(i16, bytes[offset..][0..2], @divTrunc(value, divisor), .little);
    }
}
const Sources = struct {
    variant: Variant,
    reads: usize = 0,
    fn read(raw: *anyopaque, allocator: std.mem.Allocator, input: compiler.SoundSource, limit: usize) media.Error![]u8 {
        const self: *Sources = @ptrCast(@alignCast(raw));
        const bytes = try original(allocator, input.path, limit);
        errdefer allocator.free(bytes);
        if (self.variant == .b) for (changed_paths, divisors) |path, divisor| {
            if (std.mem.eql(u8, path, input.path)) try modify(bytes, divisor);
        };
        self.reads += 1;
        return bytes;
    }
};
pub fn build(variant: Variant) ![]u8 {
    return buildSource(variant, authored_source, null);
}
/// Source-only derivatives may install additional genuine compiler features.
/// The original reload fixture retains precisely its previous source/defaults.
pub fn buildSource(variant: Variant, source: []const u8, install_features: ?*const fn (*compiler.Registry) anyerror!void) ![]u8 {
    var text = try a.dupe(u8, source);
    defer a.free(text);
    if (variant == .b) for (changed_paths, divisors) |path, divisor| {
        const bytes = try original(a, path, 1024 * 1024);
        defer a.free(bytes);
        var old_hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &old_hash, .{});
        try modify(bytes, divisor);
        var new_hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes, &new_hash, .{});
        const old_hex = std.fmt.bytesToHex(old_hash, .lower);
        const new_hex = std.fmt.bytesToHex(new_hash, .lower);
        try t.expectEqual(@as(usize, 1), std.mem.count(u8, text, &old_hex));
        const changed = try std.mem.replaceOwned(u8, a, text, &old_hex, &new_hex);
        a.free(text);
        text = changed;
    };
    var input: Sources = .{ .variant = variant };
    var pipeline: media.Pipeline = .{ .resolver = .{ .context = &input, .read = Sources.read } };
    var registry: compiler.Registry = .{};
    try registry.registerMediaProviderContext(pipeline.provider());
    try @import("sme-tempo").install(&registry);
    try @import("sme-selection-compiler").install(&registry);
    try @import("sme-transition-compiler").install(&registry);
    try @import("sme-bus-compiler").install(&registry);
    if (install_features) |install| try install(&registry);
    var result = try registry.buildSource(a, text);
    errdefer result.deinit();
    var loaded = try bank.MusicBank.load(a, result.bytes);
    defer loaded.deinit();
    try t.expectEqual(@as(usize, resource_count), input.reads);
    try t.expectEqual(@as(usize, resource_count), loaded.tables.sounds.len);
    try t.expectEqual(@as(usize, 0), loaded.tables.fills.len);
    try t.expectEqual(@as(usize, 0), loaded.tables.transitions.len);
    try t.expectEqual(@as(usize, 0), loaded.tables.transition_paths.len);
    for (loaded.tables.sounds) |sound| {
        try t.expectEqual(.streaming, sound.storage);
        try t.expectEqual(.ogg_opus, loaded.tables.codecs[sound.codec].kind);
        try t.expectEqual(loop_frames, sound.frames);
    }
    for (loaded.tables.segments) |segment| {
        try t.expectEqual(@as(u32, stem_count), segment.layers.count);
        try t.expectEqual(@as(u64, 0), segment.loop_start);
        try t.expectEqual(loop_frames, segment.loop_end);
        const layers = loaded.tables.layers[segment.layers.first..][0..segment.layers.count];
        for (layers, 0..) |layer, i| for (layers[0..i]) |prior| try t.expect(layer.sound != prior.sound);
    }
    a.free(result.report.storage_decisions);
    return result.bytes;
}

pub const Maps = struct {
    map: reload.migration.MigrationMapV1,
    rules: reload.epoch_policy.RuntimeMigrationPolicyV1,
    pub fn init(old_bytes: []const u8, new_bytes: []const u8) !Maps {
        var old = try bank.MusicBank.load(a, old_bytes);
        defer old.deinit();
        var fresh = try bank.MusicBank.load(a, new_bytes);
        defer fresh.deinit();
        var old_states: [32]music.MusicStateId = undefined;
        var new_states: [32]music.MusicStateId = undefined;
        var old_segments: [32]music.SegmentId = undefined;
        var new_segments: [32]music.SegmentId = undefined;
        var old_selectors: [32]music.SegmentSelectorId = undefined;
        var new_selectors: [32]music.SegmentSelectorId = undefined;
        var states: [32]reload.migration.StateMapping = undefined;
        var segments: [32]reload.migration.SegmentMapping = undefined;
        var selectors: [32]reload.migration.SelectorMapping = undefined;
        var kinds: [32]reload.epoch_policy.Selector = undefined;
        for (old.tables.states, 0..) |row, i| {
            old_states[i] = @enumFromInt(row.key.id);
            states[i] = .{ .from = old_states[i], .to = old_states[i] };
        }
        for (fresh.tables.states, 0..) |row, i| new_states[i] = @enumFromInt(row.key.id);
        for (old.tables.segments, 0..) |row, i| {
            old_segments[i] = @enumFromInt(row.key.id);
            segments[i] = .{ .from = old_segments[i], .to = old_segments[i] };
        }
        for (fresh.tables.segments, 0..) |row, i| new_segments[i] = @enumFromInt(row.key.id);
        for (old.tables.selectors, 0..) |row, i| {
            old_selectors[i] = @enumFromInt(row.key.id);
            selectors[i] = .{ .from = old_selectors[i], .to = old_selectors[i] };
            kinds[i] = .{ .id = old_selectors[i], .stochastic = switch (row.kind) {
                .weighted_random, .shuffle, .no_repeat => true,
                else => false,
            } };
        }
        for (fresh.tables.selectors, 0..) |row, i| new_selectors[i] = @enumFromInt(row.key.id);
        const source: reload.migration.Inventory = .{ .states = old_states[0..old.tables.states.len], .segments = old_segments[0..old.tables.segments.len], .selectors = old_selectors[0..old.tables.selectors.len] };
        const context: reload.migration.ValidationContext = .{ .from_build_id = buildId(old.content_hash), .to_build_id = buildId(fresh.content_hash), .source = source, .target = .{ .states = new_states[0..fresh.tables.states.len], .segments = new_segments[0..fresh.tables.segments.len], .selectors = new_selectors[0..fresh.tables.selectors.len] }, .required = source };
        var map = try reload.migration.MigrationMapV1.init(a, .{ .from_build_id = context.from_build_id, .to_build_id = context.to_build_id, .required_capabilities = 15, .history_policy = .remap_exact, .states = states[0..old.tables.states.len], .segments = segments[0..old.tables.segments.len], .selectors = selectors[0..old.tables.selectors.len] }, context);
        errdefer map.deinit();
        const rules = try reload.epoch_policy.RuntimeMigrationPolicyV1.init(a, .{ .from_build_id = context.from_build_id, .to_build_id = context.to_build_id, .map_hash = map.content_hash, .required_capabilities = 0 }, &map, context, .{ .source = kinds[0..old.tables.selectors.len], .target = kinds[0..old.tables.selectors.len] }, null);
        return .{ .map = map, .rules = rules };
    }
    pub fn deinit(self: *Maps) void {
        self.map.deinit();
        self.rules.deinit();
    }
};
fn buildId(hash: [32]u8) u64 {
    return std.mem.readInt(u64, hash[0..8], .little) | 1;
}

/// Independent full-stream decoders resolve authored layer bindings, rather
/// than assuming the first four sound records happen to be the playing stems.
pub const Oracle = struct {
    samples: [stem_count][]f32,
    gains: [stem_count]f64,
    sound_ids: [stem_count]u64,
    hashes: [stem_count][32]u8,
    pub fn decode(bytes: []const u8) !Oracle {
        return decodeSegment(bytes, segment_id);
    }
    pub fn decodeSegment(bytes: []const u8, selected_segment: u64) !Oracle {
        var loaded = try bank.MusicBank.load(a, bytes);
        defer loaded.deinit();
        const segment = for (loaded.tables.segments) |value| {
            if (value.key.id == selected_segment) break value;
        } else return error.InvalidFixture;
        try t.expectEqual(@as(u32, stem_count), segment.layers.count);
        var result: Oracle = undefined;
        var completed: usize = 0;
        errdefer for (result.samples[0..completed]) |samples| a.free(samples);
        for (loaded.tables.layers[segment.layers.first..][0..segment.layers.count], 0..) |layer, i| {
            const sound = loaded.tables.sounds[layer.sound];
            try t.expectEqual(@as(u64, 0), layer.source_start);
            const encoded = loaded.tables.blob[@intCast(sound.blob_offset)..][0..@intCast(sound.blob_length)];
            var scan = try opus.inspect(a, encoded);
            defer scan.deinit();
            try t.expectEqual(@as(u8, 1), scan.info.channels);
            try t.expectEqual(loop_frames, scan.info.audible_frames);
            var decoder = try opus.Decoder.prepare(a, scan.info, opus.scanReader(&scan), scan.packets[2].byte_offset);
            defer decoder.deinit();
            result.samples[i] = try a.alloc(f32, @intCast(scan.info.audible_frames));
            completed += 1;
            const decoded = try decoder.decode(result.samples[i]);
            try t.expect(decoded.eos);
            try decoder.validatePayloadToEnd();
            result.gains[i] = std.math.pow(f64, 10, @as(f64, layer.gain_db) / 20);
            result.sound_ids[i] = sound.key.id;
            result.hashes[i] = sound.audio_hash;
            var energy: f64 = 0;
            for (result.samples[i]) |sample| energy += @as(f64, sample) * sample;
            try t.expect(energy > 0.01);
        }
        return result;
    }
    pub fn deinit(self: *Oracle) void {
        for (self.samples) |samples| a.free(samples);
        self.* = undefined;
    }
    pub fn stemAt(self: *const Oracle, index: usize, cursor: u64) f64 {
        return @as(f64, self.samples[index][@intCast(cursor)]) * self.gains[index] * @sqrt(@as(f64, 0.5));
    }
    pub fn sampleAt(self: *const Oracle, cursor: u64) f32 {
        var sum: f64 = 0;
        for (0..stem_count) |i| sum += self.stemAt(i, cursor);
        return @floatCast(sum);
    }
    pub const tolerance: f32 = 0.00002;
    pub const Evidence = struct {
        frames: usize = 0,
        nonzero: usize = 0,
        max_error: f32 = 0,
        pub fn expectPcm(self: *Evidence, oracle: *const Oracle, first: u64, start: u64, pcm: []const f32) !void {
            try t.expectEqual(@as(usize, 0), pcm.len % 2);
            for (0..pcm.len / 2) |i| {
                const frame = first + i;
                const want = if (frame < start) @as(f32, 0) else oracle.sampleAt((frame - start) % loop_frames);
                for (pcm[i * 2 ..][0..2]) |got| {
                    self.max_error = @max(self.max_error, @abs(got - want));
                    try t.expectApproxEqAbs(want, got, tolerance);
                }
                self.frames += 1;
                if (@abs(want) > tolerance) self.nonzero += 1;
            }
        }
    };
    /// The chosen oracle windows distinguish all-A, one missing/mixed stem,
    /// cursor zero, and a one-bar retarget. Require every alternative to differ
    /// by more than the comparison tolerance at some actual audible sample.
    pub fn distinguish(self: *const Oracle, other: *const Oracle, cursor: u64) !void {
        var wrong_generation: f64 = 0;
        var wrong_cursor: f64 = 0;
        var one_bar: f64 = 0;
        var missing: [stem_count]f64 = @splat(0);
        var mixed: [stem_count]f64 = @splat(0);
        for (0..1024) |offset| {
            const at = (cursor + offset) % loop_frames;
            const expected = self.sampleAt(at);
            wrong_generation = @max(wrong_generation, @abs(expected - other.sampleAt(at)));
            wrong_cursor = @max(wrong_cursor, @abs(expected - self.sampleAt((at + 1) % loop_frames)));
            one_bar = @max(one_bar, @abs(expected - self.sampleAt((at + bar_frames) % loop_frames)));
            for (0..stem_count) |i| {
                missing[i] = @max(missing[i], @abs(self.stemAt(i, at)));
                mixed[i] = @max(mixed[i], @abs(self.stemAt(i, at) - other.stemAt(i, at)));
            }
        }
        try t.expect(wrong_generation > tolerance * 8);
        try t.expect(wrong_cursor > tolerance * 8);
        try t.expect(one_bar > tolerance * 8);
        for (missing, mixed) |absent, replaced| {
            try t.expect(absent > tolerance * 8);
            try t.expect(replaced > tolerance * 8);
        }
    }
};

/// Forwarding recorder: every byte and lifecycle operation goes to the actual
/// bank-backed V2 provider. Mutable observations are read only between sole
/// Worker calls. Fault hooks affect real reads/callbacks for later small cases.
pub const ObservedProvider = struct {
    const V2 = music.MusicSourceProviderV2;
    const Token = music.SourceBindingTokenV2;
    pub const Operation = enum { bind, open, read, close, unbind };
    pub const Event = struct {
        sequence: u64,
        operation: Operation,
        binding: Token,
        source: u64 = 0,
        sound: u64 = 0,
        failure: ?V2.Error = null,
    };
    actual: *music.BankSourceProviderV2,
    owner: *music.MusicRuntime,
    sequence: *u64,
    events: [32768]Event = undefined,
    event_count: usize = 0,
    overflow: bool = false,
    wrong_owner: bool = false,
    fail_read_call: ?usize = null,
    reads: usize = 0,
    pub fn create(owner: *music.MusicRuntime, sequence: *u64, bytes: []const u8) !*ObservedProvider {
        const self = try a.create(ObservedProvider);
        errdefer a.destroy(self);
        self.* = .{ .actual = try music.BankSourceProviderV2.create(a, bytes, .{}), .owner = owner, .sequence = sequence };
        return self;
    }
    pub fn provider(self: *ObservedProvider) V2 {
        return .{ .context = self, .bind = bind, .open = open, .read_at = read, .close = close, .unbind = unbind };
    }
    fn record(self: *ObservedProvider, operation: Operation, binding: Token, source_token: u64, sound: u64, failure: ?V2.Error) void {
        self.wrong_owner = self.wrong_owner or !self.owner.worker_guard.load(.acquire);
        self.sequence.* += 1;
        if (self.event_count == self.events.len) {
            self.overflow = true;
            return;
        }
        self.events[self.event_count] = .{ .sequence = self.sequence.*, .operation = operation, .binding = binding, .source = source_token, .sound = sound, .failure = failure };
        self.event_count += 1;
    }
    fn bind(raw: *anyopaque, identity: music.SourceIdentityV2) V2.Error!Token {
        const self: *ObservedProvider = @ptrCast(@alignCast(raw));
        const api = self.actual.provider();
        const token = api.bind(api.context, identity) catch |err| {
            self.record(.bind, .{ .context = identity.context, .runtime_generation = identity.runtime_generation, .incarnation = 0 }, 0, 0, err);
            return err;
        };
        self.record(.bind, token, 0, 0, null);
        return token;
    }
    fn open(raw: *anyopaque, binding: Token, request: V2.Request) V2.Error!V2.Opened {
        const self: *ObservedProvider = @ptrCast(@alignCast(raw));
        const api = self.actual.provider();
        const opened = api.open(api.context, binding, request) catch |err| {
            self.record(.open, binding, 0, request.sound_id, err);
            return err;
        };
        self.record(.open, binding, opened.token, request.sound_id, null);
        return opened;
    }
    fn read(raw: *anyopaque, binding: Token, source_token: u64, offset: u64, destination: []u8) V2.Error!void {
        const self: *ObservedProvider = @ptrCast(@alignCast(raw));
        self.reads += 1;
        if (self.fail_read_call == self.reads) {
            self.record(.read, binding, source_token, 0, error.SourceReadFailed);
            return error.SourceReadFailed;
        }
        const api = self.actual.provider();
        api.read_at(api.context, binding, source_token, offset, destination) catch |err| {
            self.record(.read, binding, source_token, 0, err);
            return err;
        };
        self.record(.read, binding, source_token, 0, null);
    }
    fn close(raw: *anyopaque, binding: Token, source_token: u64) V2.Error!void {
        const self: *ObservedProvider = @ptrCast(@alignCast(raw));
        const api = self.actual.provider();
        api.close(api.context, binding, source_token) catch |err| {
            self.record(.close, binding, source_token, 0, err);
            return err;
        };
        self.record(.close, binding, source_token, 0, null);
    }
    fn unbind(raw: *anyopaque, binding: Token) V2.Error!void {
        const self: *ObservedProvider = @ptrCast(@alignCast(raw));
        const api = self.actual.provider();
        api.unbind(api.context, binding) catch |err| {
            self.record(.unbind, binding, 0, 0, err);
            return err;
        };
        self.record(.unbind, binding, 0, 0, null);
    }
    pub fn expectReleased(self: *const ObservedProvider) !void {
        try t.expect(!self.wrong_owner and !self.overflow);
        try t.expect(self.actual.binding == null);
        try t.expectEqual(@as(usize, 0), self.actual.counts.live);
        try t.expectEqual(self.actual.counts.opened, self.actual.counts.closed);
        try t.expectEqual(self.actual.counts.binds, self.actual.counts.unbound);
        var opened: [resource_count + 1]bool = @splat(false);
        var binding: ?Token = null;
        for (self.events[0..self.event_count]) |event| {
            if (event.failure != null) continue;
            switch (event.operation) {
                .bind => {
                    try t.expect(binding == null);
                    binding = event.binding;
                },
                .open => {
                    try t.expectEqual(binding.?, event.binding);
                    try t.expect(event.source > 0 and event.source <= resource_count);
                    try t.expect(!opened[event.source]);
                    opened[event.source] = true;
                },
                .read => {
                    try t.expectEqual(binding.?, event.binding);
                    try t.expect(opened[event.source]);
                },
                .close => {
                    try t.expectEqual(binding.?, event.binding);
                    try t.expect(opened[event.source]);
                    opened[event.source] = false;
                },
                .unbind => {
                    try t.expectEqual(binding.?, event.binding);
                    try t.expect(std.mem.allEqual(bool, &opened, false));
                    binding = null;
                },
            }
        }
        try t.expect(binding == null);
    }
    pub fn destroy(self: *ObservedProvider) !void {
        try self.expectReleased();
        try self.actual.destroy();
        a.destroy(self);
    }
};

/// Hold an actual selected job before its real decode, including packet-cache
/// hits. Only the one persistent Worker exists; no alternate Worker bypasses it.
pub const JobBarrier = struct {
    job_id: u64,
    entered: std.atomic.Value(bool) = .init(false),
    released: std.atomic.Value(bool) = .init(false),
    timed_out: std.atomic.Value(bool) = .init(false),
    fn hook(raw: *anyopaque, job_id: u64) void {
        const self: *JobBarrier = @ptrCast(@alignCast(raw));
        if (job_id != self.job_id) return;
        if (!self.entered.swap(true, .acq_rel)) {
            const began = std.Io.Clock.awake.now(t.io);
            while (!self.released.load(.acquire)) {
                // Deadlock guard only, never a musical/readiness oracle.
                if (began.durationTo(std.Io.Clock.awake.now(t.io)).nanoseconds > 5 * std.time.ns_per_s) {
                    self.timed_out.store(true, .release);
                    self.released.store(true, .release);
                    return;
                }
                std.atomic.spinLoopHint();
            }
        }
    }
};
const PersistentWorker = struct {
    const State = enum(u8) { idle, requested, running, done, stopping };
    owner: *music.MusicRuntime,
    thread: std.Thread = undefined,
    state: std.atomic.Value(State) = .init(.idle),
    stopped: std.atomic.Value(bool) = .init(false),
    result: bool = false,
    live_call: bool = false,
    failure: ?anyerror = null,
    fn create(owner: *music.MusicRuntime) !*PersistentWorker {
        const self = try a.create(PersistentWorker);
        errdefer a.destroy(self);
        self.* = .{ .owner = owner };
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }
    fn run(self: *PersistentWorker) void {
        while (true) switch (self.state.load(.acquire)) {
            .stopping => {
                self.stopped.store(true, .release);
                return;
            },
            .requested => {
                self.state.store(.running, .release);
                self.result = (if (self.live_call) live: {
                    const result = self.owner.workerOneLiveV1() catch |err| {
                        self.failure = err;
                        break :live false;
                    };
                    break :live result.worked;
                } else self.owner.workerOneV1() catch |err| failure: {
                    self.failure = err;
                    break :failure false;
                });
                self.state.store(.done, .release);
            },
            else => std.atomic.spinLoopHint(),
        };
    }
    fn begin(self: *PersistentWorker) void {
        std.debug.assert(self.state.load(.acquire) == .idle);
        self.failure = null;
        self.state.store(.requested, .release);
    }
    fn finish(self: *PersistentWorker) !bool {
        const began = std.Io.Clock.awake.now(t.io);
        while (self.state.load(.acquire) != .done) {
            // A truly stuck callback cannot be safely freed or detached. Abort
            // this test without unwinding/freeing its live Worker-owned memory.
            if (began.durationTo(std.Io.Clock.awake.now(t.io)).nanoseconds > 30 * std.time.ns_per_s)
                @panic("stream reload fixture Worker timeout; live custody retained");
            std.atomic.spinLoopHint();
        }
        const result = self.result;
        const failure = self.failure;
        self.state.store(.idle, .release);
        if (failure) |err| return err;
        return result;
    }
    fn one(self: *PersistentWorker) !bool {
        self.begin();
        return self.finish();
    }
    fn oneLive(self: *PersistentWorker) !bool {
        std.debug.assert(self.state.load(.acquire) == .idle);
        self.live_call = true;
        defer self.live_call = false;
        self.begin();
        return self.finish();
    }
    fn destroy(self: *PersistentWorker) void {
        std.debug.assert(self.state.load(.acquire) == .idle);
        self.state.store(.stopping, .release);
        const began = std.Io.Clock.awake.now(t.io);
        while (!self.stopped.load(.acquire)) {
            if (began.durationTo(std.Io.Clock.awake.now(t.io)).nanoseconds > 5 * std.time.ns_per_s)
                @panic("stream reload fixture Worker stop timeout; live custody retained");
            std.atomic.spinLoopHint();
        }
        self.thread.join();
        a.destroy(self);
    }
};

pub const Rig = struct {
    run: *runtime.Run,
    providers: [3]?*ObservedProvider = @splat(null),
    sequence: u64 = 0,
    worker: ?*PersistentWorker = null,
    // Explicit playback-fixture opt-in only. Embedded storage is pinned from
    // registration before first load through actual final free and Worker join.
    gate_worker: ?FinalizationDriver = null,
    gate_quiescence: ?runtime.audio.RuntimeRenderer.DeviceQuiescence = null,
    held_job: ?*JobBarrier = null,
    start_frame: u64 = 0,
    evidence: Oracle.Evidence = .{},
    pub fn create() !*Rig {
        return createWithConfig(.{ .kind = .offline, .control_driver = .integrated, .quantum_frames = 32, .streaming_reservation = .release_profile });
    }
    /// Configuration is copied at construction; callers never patch a live owner.
    pub fn createWithConfig(config: music.MusicRuntimeConfigV1) !*Rig {
        const self = try a.create(Rig);
        errdefer a.destroy(self);
        self.* = .{ .run = try runtime.Run.create(config) };
        return self;
    }
    pub fn enableWorkerThread(self: *Rig) !void {
        try t.expect(self.worker == null and self.gate_worker == null and self.run.owner.worker_thread == null);
        self.worker = try PersistentWorker.create(self.run.owner);
    }
    pub fn enableGateWorker(self: *Rig) !void {
        if (self.worker != null or self.gate_worker != null or self.run.owner.worker_thread != null) return error.InvalidFixture;
        for (self.providers) |provider| if (provider != null) return error.InvalidFixture;
        self.gate_worker = .{};
        const driver = &self.gate_worker.?;
        try driver.init(self.run.owner);
        try driver.start();
    }
    pub fn attachWorkerEnd(self: *Rig, observer: FinalizationDriver.EndObserver) !void {
        const driver = if (self.gate_worker) |*value| value else return error.InvalidFixture;
        try driver.attachEndObserver(observer);
    }
    pub fn detachWorkerEnd(self: *Rig, observer: FinalizationDriver.EndObserver) !void {
        const driver = if (self.gate_worker) |*value| value else return error.InvalidFixture;
        try driver.detachEndObserver(observer);
    }
    pub fn workerOne(self: *Rig) !bool {
        if (self.gate_worker) |*driver| return driver.one(false);
        if (self.worker) |worker| return worker.one();
        return self.run.owner.workerOneV1();
    }
    pub fn workerOneLive(self: *Rig) !bool {
        if (self.gate_worker) |*driver| return driver.one(true);
        if (self.worker) |worker| return worker.oneLive();
        return (try self.run.owner.workerOneLiveV1()).worked;
    }
    pub fn blockJob(self: *Rig, barrier: *JobBarrier) !void {
        const worker = self.worker orelse return error.InvalidFixture;
        const service = self.run.owner.owned_streaming.?;
        try t.expect(self.held_job == null and service.test_worker_hook == null);
        self.held_job = barrier;
        service.test_worker_hook = .{ .context = barrier, .call = JobBarrier.hook };
        errdefer {
            barrier.released.store(true, .release);
            if (worker.state.load(.acquire) != .idle) _ = worker.finish() catch {};
            self.held_job = null;
            service.test_worker_hook = null;
        }
        for (0..rt.streaming.release_profile.job_capacity + 1) |_| {
            worker.begin();
            const began = std.Io.Clock.awake.now(t.io);
            while (!barrier.entered.load(.acquire) and worker.state.load(.acquire) != .done) {
                if (began.durationTo(std.Io.Clock.awake.now(t.io)).nanoseconds > 5 * std.time.ns_per_s)
                    return error.WorkerJobEntryTimeout;
                std.atomic.spinLoopHint();
            }
            if (barrier.entered.load(.acquire)) return;
            _ = try worker.finish();
        }
        return error.MissingRealWorkerJob;
    }
    pub fn releaseJob(self: *Rig, barrier: *JobBarrier) !void {
        try t.expect(self.held_job == barrier);
        barrier.released.store(true, .release);
        defer {
            self.run.owner.owned_streaming.?.test_worker_hook = null;
            self.held_job = null;
        }
        _ = try self.worker.?.finish();
        try t.expect(!barrier.timed_out.load(.acquire));
    }
    /// Every old ring is independently Render-visible; this is measured live
    /// reserve, not a configured high-water guess or a synthesized ready flag.
    pub fn minimumReserve(self: *Rig) !u64 {
        const generation = self.run.owner.generation.?;
        var result: u64 = std.math.maxInt(u64);
        var count: usize = 0;
        for (generation.windows) |entry| if (entry) |window| {
            if (window.retiring or window.group == null or !window.group.?.eql(self.run.owner.active_group.?)) continue;
            const stream = try generation.service.?.renderSource(window.binding.handle);
            result = @min(result, stream.ring.renderProduced() - stream.ring.consumed.load(.acquire));
            count += 1;
        };
        try t.expectEqual(@as(usize, stem_count), count);
        return result;
    }
    pub fn addProvider(self: *Rig, slot: usize, bytes: []const u8) !*ObservedProvider {
        if (self.gate_worker != null) return error.InvalidFixture;
        try t.expect(self.providers[slot] == null);
        const provider = try ObservedProvider.create(self.run.owner, &self.sequence, bytes);
        self.providers[slot] = provider;
        return provider;
    }
    pub fn workers(self: *Rig) !void {
        // Bound includes all release-profile queued decode jobs plus the real
        // sixteen source closes and one unbind per in-flight retirement.
        for (0..rt.streaming.release_profile.job_capacity + resource_count * 3 + 8) |_| {
            if (!try self.workerOne()) return;
        }
        return error.WorkerDidNotDrain;
    }
    pub fn settle(self: *Rig) !void {
        try self.run.pump();
        try self.workers();
        try self.run.pump();
    }
    pub fn load(self: *Rig, bytes: []const u8, provider: *ObservedProvider) !void {
        const ticket = try self.run.owner.loadBankWithSourcesV2(bytes, provider.provider());
        for (0..8) |_| {
            _ = try self.workerOne();
            const result = try self.run.owner.pollLoad(ticket);
            switch (result) {
                .pending => {},
                .ready => |ready| {
                    self.run.bank = ready.bank;
                    try self.run.owner.acknowledgeLoad(ticket);
                    return;
                },
                .failed => return error.LoadFailed,
            }
        }
        return error.LoadDidNotFinish;
    }
    pub fn start(self: *Rig) !void {
        const ticket = try self.run.owner.start(self.run.bank.?, state);
        for (0..128) |_| {
            try self.settle();
            const pcm = try self.run.render(32);
            a.free(pcm);
            try self.run.pump();
            while (try self.run.owner.pollReceiptV1()) |receipt| {
                if (!std.meta.eql(receipt.ticket, ticket) or receipt.event != .terminal) continue;
                try t.expect(receipt.event.terminal == .executed);
                self.start_frame = receipt.event.terminal.executed.effective_frame;
                const observed = try self.run.control.musicVoiceObservation(self.run.owner.active_group.?);
                try t.expectEqual(@as(u16, stem_count), observed.layer_count);
                try t.expectEqual(@as(u64, 1), observed.mutation_epoch);
                return;
            }
        }
        return error.StartDidNotExecute;
    }
    pub fn render(self: *Rig, frames: u32, oracle: *const Oracle) !void {
        const first = self.run.renderer.renderFrame();
        const pcm = try self.run.render(frames);
        defer a.free(pcm);
        try self.evidence.expectPcm(oracle, first, self.start_frame, pcm);
    }
    pub fn advance(self: *Rig, end: u64, oracle: *const Oracle) !void {
        try t.expect(self.run.renderer.renderFrame() <= end);
        while (self.run.renderer.renderFrame() < end) {
            try self.settle();
            const amount: u32 = @intCast(@min(256, end - self.run.renderer.renderFrame()));
            try self.render(amount, oracle);
        }
        try self.settle();
    }
    pub fn acknowledge(self: *Rig, ticket: music.MusicRequestTicketV1, oracle: *const Oracle) !void {
        for (0..128) |_| {
            self.run.owner.acknowledgeReloadV1(ticket) catch |err| switch (err) {
                error.DrainPending => {
                    try self.settle();
                    try self.render(32, oracle);
                    continue;
                },
                else => return err,
            };
            return;
        }
        return error.ReloadAcknowledgementDidNotDrain;
    }
    pub fn finish(self: *Rig) !void {
        return self.finishMode(false);
    }
    pub fn finishChronology(self: *Rig) !void {
        return self.finishMode(true);
    }
    fn finishPump(self: *Rig, comptime chronology: bool) !void {
        if (chronology) {
            _ = try self.run.owner.controlTickLiveChronologyV1(rt.max_control_drain, null);
        } else try self.run.pump();
    }
    fn finishSettle(self: *Rig, comptime chronology: bool) !void {
        try self.finishPump(chronology);
        try self.workers();
        try self.finishPump(chronology);
    }
    fn finishGateMode(self: *Rig, comptime chronology: bool) !void {
        const driver = &self.gate_worker.?;
        if (self.worker != null or self.held_job != null or driver.end_observer != null) return error.InvalidFixture;
        // The opt-in authoring wrapper retains its own V1 provider through join.
        // This narrow path does not adopt the reload fixture's V2 providers.
        for (self.providers) |provider| if (provider != null) return error.InvalidFixture;
        if (!driver.started() and !driver.joined) {
            // Failed registration/spawn has no actual Worker and no queued load.
            // Keep the embedded session alive until ordinary owner free returns.
            if (self.run.bank != null or self.run.owner.worker_thread != null or self.run.owner.load.state.load(.acquire) != .idle or
                self.run.owner.generation != null or self.run.owner.owned_streaming != null) return error.InvalidFixture;
            try self.run.finish();
            a.destroy(self);
            return;
        }
        if (driver.owner_alive and !driver.session.blocked()) {
            if (self.gate_quiescence == null) {
                // This staged boundary needs a genuinely loaded Service. Never
                // invent an early seal for a failed, still-running constructor.
                if (self.run.owner.owned_streaming == null) return error.UnloadedGateFixture;
                try self.run.owner.shutdown();
                for (0..16) |_| {
                    try self.finishSettle(chronology);
                    const pcm = try self.run.render(256);
                    a.free(pcm);
                }
                try self.finishSettle(chronology);
                self.gate_quiescence = try self.run.renderer.acquireDeviceQuiescence();
            }
            for (0..resource_count * 3 + 32) |_| {
                const outcome = driver.prepare(self.gate_quiescence.?) catch |err| {
                    if (err != error.DrainPending or driver.session.blocked()) return err;
                    // Only pre-token DrainPending can resume the same Worker.
                    // Real provider close/retirement progresses before a new ACK.
                    try driver.resumePending();
                    try self.workers();
                    // Preserve required Control collection until its actual
                    // destruction. Never Render after retaining quiescence.
                    if (!self.run.owner.control_torn_down) try self.finishPump(chronology);
                    continue;
                };
                const capability = switch (outcome) {
                    .ready_for_final_free => |value| value,
                    .destroyed => return error.UnexpectedEarlyFree,
                };
                _ = try driver.finalize(capability);
                break;
            }
            if (driver.owner_alive) return error.FinalBoundaryDidNotFinish;
        } else if (driver.owner_alive) {
            // Including failure after the actual stopped store: retain and
            // retry only the identical cap, never ordinary cleanup or resume.
            _ = try driver.finalize(driver.session.capability orelse return error.InvalidFixture);
        }
        if (!driver.joined) try driver.joinAfterDestroyed();
        try t.expect(driver.joined and driver.gate.stopped.load(.acquire));
        try t.expectEqual(.destroyed, driver.session.phase.load(.acquire));
        try t.expectEqual(driver.begin_attempts.load(.acquire), driver.end_attempts.load(.acquire));
        try t.expectEqual(driver.end_attempts.load(.acquire), driver.ack_end_attempts.load(.acquire));
        const report = driver.session.actual_report orelse return error.InvalidFixture;
        try t.expectEqual(@as(u64, 0), report.sample_leases);
        try t.expectEqual(@as(u64, 0), report.live_instances);
        if (self.gate_quiescence) |token| {
            try self.run.renderer.releaseDeviceQuiescence(token);
            self.gate_quiescence = null;
        }
        a.destroy(self.run.renderer);
        a.destroy(self.run.control);
        a.destroy(self.run);
        a.destroy(self);
    }
    fn finishMode(self: *Rig, comptime chronology: bool) !void {
        if (self.gate_worker != null) return self.finishGateMode(chronology);
        if (self.held_job != null) return error.WorkerJobStillBlocked;
        try self.run.owner.shutdown();
        for (0..16) |_| {
            try self.finishSettle(chronology);
            const pcm = try self.run.render(256);
            a.free(pcm);
        }
        try self.finishSettle(chronology);
        var destroyed = false;
        for (0..resource_count * 3 + 32) |_| {
            const report = self.run.owner.destroyQuiescent() catch |err| switch (err) {
                error.DrainPending => {
                    try self.workers();
                    try self.finishPump(chronology);
                    continue;
                },
                else => return err,
            };
            try t.expectEqual(@as(u64, 0), report.sample_leases);
            try t.expectEqual(@as(u64, 0), report.live_instances);
            destroyed = true;
            break;
        }
        try t.expect(destroyed);
        if (self.worker) |worker| worker.destroy();
        for (self.providers) |provider| if (provider) |value| try value.destroy();
        a.destroy(self.run.renderer);
        a.destroy(self.run.control);
        a.destroy(self.run);
        a.destroy(self);
    }
};
/// Source-only preview geometry derivative. The normal reload constructor and
/// its zero-intro/zero-origin assertions above remain unchanged.
pub const PreviewSeekGeometry = struct {
    pub const intro_frames: u64 = 96_000;
    pub const end_frame: u64 = loop_frames;

    fn replace(text: *[]u8, before: []const u8, after: []const u8, expected: usize) !void {
        try t.expectEqual(expected, std.mem.count(u8, text.*, before));
        const next = try std.mem.replaceOwned(u8, a, text.*, before, after);
        a.free(text.*);
        text.* = next;
    }
    fn install(registry: *compiler.Registry, pipeline: *media.Pipeline) !void {
        try registry.registerMediaProviderContext(pipeline.provider());
        try @import("sme-tempo").install(registry);
        try @import("sme-selection-compiler").install(registry);
        try @import("sme-transition-compiler").install(registry);
        try @import("sme-bus-compiler").install(registry);
    }
    pub fn buildIntro() ![]u8 {
        var text = try a.dupe(u8, authored_source);
        defer a.free(text);
        // One genuine bar of intro, then three bars of looping playback. All
        // original media bytes, lengths, hashes, IDs and gains are unchanged.
        try replace(&text, "loop_start_tick=0\n", "loop_start_tick=3840\n", 1);
        try replace(&text, "loop_start=0\nloop_end=384000", "loop_start=96000\nloop_end=384000", 4);
        try replace(&text, "loop={start=0,end=384000}", "loop={start=96000,end=384000}", resource_count);
        var input: Sources = .{ .variant = .a };
        var pipeline: media.Pipeline = .{ .resolver = .{ .context = &input, .read = Sources.read } };
        var registry: compiler.Registry = .{};
        try install(&registry, &pipeline);
        var result = try registry.buildSource(a, text);
        errdefer result.deinit();
        var loaded = try bank.MusicBank.load(a, result.bytes);
        defer loaded.deinit();
        try t.expectEqual(@as(usize, resource_count), input.reads);
        try t.expectEqual(@as(usize, resource_count), loaded.tables.sounds.len);
        try t.expectEqual(@as(usize, 0), loaded.tables.fills.len);
        try t.expectEqual(@as(usize, 0), loaded.tables.transitions.len);
        try t.expectEqual(@as(usize, 0), loaded.tables.transition_paths.len);
        for (loaded.tables.sounds) |sound| {
            try t.expectEqual(.streaming, sound.storage);
            try t.expectEqual(.ogg_opus, loaded.tables.codecs[sound.codec].kind);
            try t.expectEqual(end_frame, sound.frames);
        }
        for (loaded.tables.segments) |value| {
            try t.expectEqual(@as(u32, stem_count), value.layers.count);
            try t.expectEqual(end_frame, value.frames);
            try t.expectEqual(intro_frames, value.loop_start);
            try t.expectEqual(end_frame, value.loop_end);
            const layers = loaded.tables.layers[value.layers.first..][0..value.layers.count];
            for (layers, 0..) |layer, i| {
                try t.expectEqual(@as(u64, 0), layer.source_start);
                for (layers[0..i]) |prior| try t.expect(layer.sound != prior.sound);
            }
        }
        result.report.music_policy.deinit(a);
        a.free(result.report.storage_decisions);
        return result.bytes;
    }
    pub fn expectSourceOriginsRejected() !void {
        var text = try a.dupe(u8, authored_source);
        defer a.free(text);
        const names = [_][]const u8{ "explore-harmony", "explore-bass", "explore-motif", "explore-percussion" };
        const origins = [_]u64{ 257, 1_031, 2_053, 4_099 };
        for (names, origins) |name, origin| {
            const before = try std.fmt.allocPrint(a, "sound=\"{s}\"\nbus=\"music\"", .{name});
            defer a.free(before);
            const after = try std.fmt.allocPrint(a, "sound=\"{s}\"\nsource_start={d}\nbus=\"music\"", .{ name, origin });
            defer a.free(after);
            try replace(&text, before, after, 1);
        }
        var input: Sources = .{ .variant = .a };
        var pipeline: media.Pipeline = .{ .resolver = .{ .context = &input, .read = Sources.read } };
        var registry: compiler.Registry = .{};
        try install(&registry, &pipeline);
        // The unchanged media pipeline refuses source_start before it emits a
        // bank. This is the current unsupported boundary, not seek admission.
        if (registry.buildSource(a, text)) |built| {
            var unexpected = built;
            defer unexpected.deinit();
            return error.NonzeroSourceOriginsUnexpectedlyAccepted;
        } else |err| {
            try t.expectEqual(error.InvalidReference, err);
        }
        try t.expectEqual(@as(usize, resource_count), input.reads);
    }
};
