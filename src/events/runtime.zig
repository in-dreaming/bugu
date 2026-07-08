const std = @import("std");
const core = @import("../core/engine.zig");
const mixer = @import("../mixer/mixer.zig");
const acoustic = @import("../acoustic/acoustic.zig");

pub const EventId = u64;
pub const SwitchGroupId = u64;
pub const SwitchValueId = u64;
pub const RtpcId = u64;

pub const SoundRef = struct {
    id: []const u8,
    samples: []const f32,
    gain: f32 = 0.2,
    pitch: f32 = 1.0,
    priority: f32 = 1.0,
    bus: mixer.BusId = .sfx,
};

pub const RtpcCurve = struct {
    parameter: RtpcId,
    input_min: f32 = 0.0,
    input_max: f32 = 1.0,
    output_min: f32 = 0.0,
    output_max: f32 = 1.0,

    fn evaluate(self: RtpcCurve, value: f32) f32 {
        const span = self.input_max - self.input_min;
        if (span == 0.0) return self.output_min;
        const t = std.math.clamp((value - self.input_min) / span, 0.0, 1.0);
        return self.output_min + (self.output_max - self.output_min) * t;
    }
};

pub const PlayEvent = struct {
    variants: []const SoundRef,
    random: bool = false,
    loop: bool = false,
    volume: f32 = 1.0,
    pitch: f32 = 1.0,
    volume_rtpc: ?RtpcCurve = null,
};

pub const SwitchCase = struct {
    value: SwitchValueId,
    event: PlayEvent,
};

pub const SwitchEvent = struct {
    group: SwitchGroupId,
    cases: []const SwitchCase,
    default: PlayEvent,
};

pub const EventEntry = struct {
    id: EventId,
    action: union(enum) {
        play: PlayEvent,
        switch_play: SwitchEvent,
        stop_all: u32,
    },
};

pub const PostResult = struct {
    resolved_event: EventId,
    voices_requested: u32 = 0,
    random_index: u32 = 0,
    switch_value: ?SwitchValueId = null,
    voice_handle: ?mixer.VoiceHandle = null,
};

pub const AcousticLayerHandles = struct {
    direct: ?mixer.VoiceHandle = null,
    transmission: ?mixer.VoiceHandle = null,
    portal: ?mixer.VoiceHandle = null,
    early_reflections: [4]?mixer.VoiceHandle = [_]?mixer.VoiceHandle{null} ** 4,
};

pub const AcousticEventInstance = struct {
    sound: SoundRef,
    loop: bool = false,
    pitch: f32 = 1.0,
    base_gain: f32 = 1.0,
    handles: AcousticLayerHandles = .{},
    smoother: acoustic.AcousticSnapshotSmoother = .{},

    pub fn update(self: *AcousticEventInstance, engine: *core.Engine, snapshot: acoustic.AcousticMixerSnapshot, delta_ms: f32) !u32 {
        const smoothed = self.smoother.step(snapshot, delta_ms);
        const ramp_frames = msToFrames(@max(smoothed.smoothing_ms, delta_ms), engine.config.sample_rate);
        return self.applySnapshot(engine, smoothed, ramp_frames);
    }

    fn applyInitial(self: *AcousticEventInstance, engine: *core.Engine, snapshot: acoustic.AcousticMixerSnapshot) !u32 {
        self.smoother.initialized = true;
        self.smoother.previous = snapshot;
        return self.applySnapshot(engine, snapshot, 1);
    }

    fn applySnapshot(self: *AcousticEventInstance, engine: *core.Engine, snapshot: acoustic.AcousticMixerSnapshot, ramp_frames: u32) !u32 {
        var started: u32 = 0;
        started += try self.startOrUpdateLayer(engine, &self.handles.direct, snapshot.direct, snapshot.late_reverb_send, ramp_frames);
        started += try self.startOrUpdateLayer(engine, &self.handles.transmission, snapshot.transmission, snapshot.late_reverb_send, ramp_frames);
        started += try self.startOrUpdateLayer(engine, &self.handles.portal, snapshot.portal, snapshot.late_reverb_send, ramp_frames);
        for (&self.handles.early_reflections, 0..) |*handle, index| {
            started += try self.startOrUpdateLayer(engine, handle, snapshot.early_reflections[index], snapshot.late_reverb_send, ramp_frames);
        }
        return started;
    }

    fn startOrUpdateLayer(
        self: *AcousticEventInstance,
        engine: *core.Engine,
        handle: *?mixer.VoiceHandle,
        layer: acoustic.AcousticLayerParams,
        reverb_send: f32,
        ramp_frames: u32,
    ) !u32 {
        const target_gain = if (layer.valid) self.base_gain * layer.gain else 0.0;
        if (handle.*) |h| {
            try engine.updateVoice(h, .{
                .gain = target_gain,
                .pan = layer.pan,
                .lowpass_hz = layer.lowpass_hz,
                .pitch_ratio = self.pitch,
                .reverb_send = reverb_send,
            }, ramp_frames);
            return 0;
        }

        if (!layer.valid or target_gain <= 0.0) return 0;
        handle.* = try engine.startSampleVoiceWithHandle(.{
            .samples = self.sound.samples,
            .gain = target_gain,
            .pitch = self.pitch,
            .priority = self.sound.priority,
            .bus = self.sound.bus,
            .loop = self.loop,
            .pan = layer.pan,
            .lowpass_hz = layer.lowpass_hz,
            .start_delay_frames = layer.delay_frames,
            .reverb_send = reverb_send,
        });
        return 1;
    }
};

pub const AcousticPostResult = struct {
    post: PostResult,
    instance: AcousticEventInstance,
};

pub const EventRuntime = struct {
    entries: []const EventEntry,
    seed: u64 = 0x9e37_79b9_7f4a_7c15,
    switch_group: SwitchGroupId = 0,
    switch_value: SwitchValueId = 0,
    rtpc_id: RtpcId = 0,
    rtpc_value: f32 = 1.0,

    pub fn init(entries: []const EventEntry) EventRuntime {
        return .{ .entries = entries };
    }

    pub fn setSwitch(self: *EventRuntime, group: SwitchGroupId, value: SwitchValueId) void {
        self.switch_group = group;
        self.switch_value = value;
    }

    pub fn setRtpc(self: *EventRuntime, id: RtpcId, value: f32) void {
        self.rtpc_id = id;
        self.rtpc_value = value;
    }

    pub fn postEvent(self: *EventRuntime, engine: *core.Engine, id: EventId) !PostResult {
        const entry = self.find(id) orelse return error.EventNotFound;
        return switch (entry.action) {
            .play => |play| self.postPlay(engine, id, play, null),
            .switch_play => |switch_event| self.postSwitch(engine, id, switch_event),
            .stop_all => |release_frames| {
                engine.stopAllVoices(release_frames);
                return .{ .resolved_event = id };
            },
        };
    }

    pub fn postAcousticEvent(self: *EventRuntime, engine: *core.Engine, id: EventId, snapshot: acoustic.AcousticMixerSnapshot) !AcousticPostResult {
        const entry = self.find(id) orelse return error.EventNotFound;
        return switch (entry.action) {
            .play => |play| self.postAcousticPlay(engine, id, play, null, snapshot),
            .switch_play => |switch_event| self.postAcousticSwitch(engine, id, switch_event, snapshot),
            .stop_all => error.InvalidArgument,
        };
    }

    fn postSwitch(self: *EventRuntime, engine: *core.Engine, id: EventId, switch_event: SwitchEvent) !PostResult {
        var selected = switch_event.default;
        var selected_value: ?SwitchValueId = null;
        if (self.switch_group == switch_event.group) {
            for (switch_event.cases) |case| {
                if (case.value == self.switch_value) {
                    selected = case.event;
                    selected_value = case.value;
                    break;
                }
            }
        }
        return self.postPlay(engine, id, selected, selected_value);
    }

    fn postPlay(self: *EventRuntime, engine: *core.Engine, id: EventId, play: PlayEvent, switch_value: ?SwitchValueId) !PostResult {
        const resolved = try self.resolvePlay(play);
        const handle = try engine.startSampleVoiceWithHandle(.{
            .samples = resolved.sound.samples,
            .gain = resolved.gain,
            .pitch = resolved.sound.pitch * play.pitch,
            .priority = resolved.sound.priority,
            .bus = resolved.sound.bus,
            .loop = play.loop,
        });
        return .{
            .resolved_event = id,
            .voices_requested = 1,
            .random_index = resolved.random_index,
            .switch_value = switch_value,
            .voice_handle = handle,
        };
    }

    fn postAcousticSwitch(
        self: *EventRuntime,
        engine: *core.Engine,
        id: EventId,
        switch_event: SwitchEvent,
        snapshot: acoustic.AcousticMixerSnapshot,
    ) !AcousticPostResult {
        var selected = switch_event.default;
        var selected_value: ?SwitchValueId = null;
        if (self.switch_group == switch_event.group) {
            for (switch_event.cases) |case| {
                if (case.value == self.switch_value) {
                    selected = case.event;
                    selected_value = case.value;
                    break;
                }
            }
        }
        return self.postAcousticPlay(engine, id, selected, selected_value, snapshot);
    }

    fn postAcousticPlay(
        self: *EventRuntime,
        engine: *core.Engine,
        id: EventId,
        play: PlayEvent,
        switch_value: ?SwitchValueId,
        snapshot: acoustic.AcousticMixerSnapshot,
    ) !AcousticPostResult {
        const resolved = try self.resolvePlay(play);
        var instance: AcousticEventInstance = .{
            .sound = resolved.sound,
            .loop = play.loop,
            .pitch = resolved.sound.pitch * play.pitch,
            .base_gain = resolved.gain,
        };
        const started = try instance.applyInitial(engine, snapshot);
        return .{
            .post = .{
                .resolved_event = id,
                .voices_requested = started,
                .random_index = resolved.random_index,
                .switch_value = switch_value,
                .voice_handle = instance.handles.direct,
            },
            .instance = instance,
        };
    }

    const ResolvedPlay = struct {
        sound: SoundRef,
        gain: f32,
        random_index: u32,
    };

    fn resolvePlay(self: *EventRuntime, play: PlayEvent) !ResolvedPlay {
        if (play.variants.len == 0) return error.EmptyEvent;
        const index = if (play.random) self.nextRandomIndex(play.variants.len) else 0;
        const sound = play.variants[index];
        var gain = sound.gain * play.volume;
        if (play.volume_rtpc) |curve| {
            if (curve.parameter == self.rtpc_id) gain *= curve.evaluate(self.rtpc_value);
        }
        return .{
            .sound = sound,
            .gain = gain,
            .random_index = @intCast(index),
        };
    }

    fn find(self: *const EventRuntime, id: EventId) ?EventEntry {
        for (self.entries) |entry| {
            if (entry.id == id) return entry;
        }
        return null;
    }

    fn nextRandomIndex(self: *EventRuntime, len: usize) usize {
        self.seed ^= self.seed << 13;
        self.seed ^= self.seed >> 7;
        self.seed ^= self.seed << 17;
        return @intCast(self.seed % len);
    }
};

pub fn hashName(name: []const u8) EventId {
    var hash: u64 = 0xcbf2_9ce4_8422_2325;
    for (name) |byte| {
        hash ^= byte;
        hash *%= 0x0000_0100_0000_01b3;
    }
    return hash;
}

fn msToFrames(ms: f32, sample_rate: u32) u32 {
    const frames = @max(ms, 0.0) * @as(f32, @floatFromInt(sample_rate)) / 1000.0;
    return @max(@as(u32, @intFromFloat(@ceil(frames))), 1);
}

test "event runtime posts random switch and stop through engine" {
    var engine = try core.Engine.init(.{});
    const a = [_]f32{ 0.1, 0.2, 0.1, 0.0 };
    const b = [_]f32{ -0.1, -0.2, -0.1, 0.0 };
    const variants = [_]SoundRef{
        .{ .id = "a", .samples = &a, .gain = 0.1 },
        .{ .id = "b", .samples = &b, .gain = 0.1 },
    };
    const wood = [_]SoundRef{.{ .id = "wood", .samples = &a, .gain = 0.1 }};
    const metal = [_]SoundRef{.{ .id = "metal", .samples = &b, .gain = 0.1 }};
    const surface = hashName("surface");
    const cases = [_]SwitchCase{.{
        .value = hashName("metal"),
        .event = .{ .variants = &metal },
    }};
    const entries = [_]EventEntry{
        .{ .id = hashName("weapon.fire"), .action = .{ .play = .{ .variants = &variants, .random = true } } },
        .{ .id = hashName("footstep"), .action = .{ .switch_play = .{ .group = surface, .cases = &cases, .default = .{ .variants = &wood } } } },
        .{ .id = hashName("stop"), .action = .{ .stop_all = 8 } },
    };
    var runtime = EventRuntime.init(&entries);
    _ = try runtime.postEvent(&engine, hashName("weapon.fire"));
    runtime.setSwitch(surface, hashName("metal"));
    const result = try runtime.postEvent(&engine, hashName("footstep"));
    try std.testing.expectEqual(hashName("metal"), result.switch_value.?);
    try std.testing.expect(result.voice_handle != null);
    _ = try runtime.postEvent(&engine, hashName("stop"));
}

test "acoustic event posts sample layer handles and updates them over time" {
    var engine = try core.Engine.init(.{});
    const sample = [_]f32{ 0.0, 0.25, 0.0, -0.25 } ** 64;
    const refs = [_]SoundRef{.{ .id = "tone", .samples = &sample, .gain = 0.5, .priority = 2.0 }};
    const entries = [_]EventEntry{.{
        .id = hashName("door.loop"),
        .action = .{ .play = .{ .variants = &refs, .loop = true } },
    }};
    var runtime = EventRuntime.init(&entries);

    const closed: acoustic.AcousticMixerSnapshot = .{
        .direct = .{ .valid = true, .gain = 0.08, .lowpass_hz = 1600.0 },
        .transmission = .{ .valid = true, .gain = 0.04, .lowpass_hz = 900.0, .delay_frames = 120 },
        .late_reverb_send = 0.1,
        .smoothing_ms = 30.0,
    };
    var posted = try runtime.postAcousticEvent(&engine, hashName("door.loop"), closed);
    try std.testing.expect(posted.instance.handles.direct != null);
    try std.testing.expect(posted.instance.handles.transmission != null);
    try std.testing.expectEqual(@as(u32, 2), posted.post.voices_requested);

    var buffer: [512 * 2]f32 = undefined;
    engine.render(&buffer, 256);
    const before = engine.telemetrySnapshot();

    const open: acoustic.AcousticMixerSnapshot = .{
        .direct = .{ .valid = true, .gain = 0.2, .lowpass_hz = 18_000.0 },
        .portal = .{ .valid = true, .gain = 0.16, .lowpass_hz = 12_000.0, .pan = 0.6, .delay_frames = 240 },
        .late_reverb_send = 0.35,
        .smoothing_ms = 30.0,
    };
    const started = try posted.instance.update(&engine, open, 30.0);
    try std.testing.expectEqual(@as(u32, 1), started);
    try std.testing.expect(posted.instance.handles.portal != null);

    engine.render(&buffer, 256);
    const after = engine.telemetrySnapshot();
    try std.testing.expect(after.rendered_frames > before.rendered_frames);
    try std.testing.expect(after.rms > 0.0);
    try std.testing.expect(after.clipping_count == 0);
}
