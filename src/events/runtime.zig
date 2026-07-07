const std = @import("std");
const core = @import("../core/engine.zig");
const mixer = @import("../mixer/mixer.zig");

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
        if (play.variants.len == 0) return error.EmptyEvent;
        const index = if (play.random) self.nextRandomIndex(play.variants.len) else 0;
        const sound = play.variants[index];
        var gain = sound.gain * play.volume;
        if (play.volume_rtpc) |curve| {
            if (curve.parameter == self.rtpc_id) gain *= curve.evaluate(self.rtpc_value);
        }
        try engine.startSampleVoice(.{
            .samples = sound.samples,
            .gain = gain,
            .pitch = sound.pitch * play.pitch,
            .priority = sound.priority,
            .bus = sound.bus,
            .loop = play.loop,
        });
        return .{
            .resolved_event = id,
            .voices_requested = 1,
            .random_index = @intCast(index),
            .switch_value = switch_value,
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
    _ = try runtime.postEvent(&engine, hashName("stop"));
}
