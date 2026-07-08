const std = @import("std");
const bugu = @import("bugu_audio");

const DoorCase = struct {
    name: []const u8,
    closed_percent: u8,
};

const SceneCase = struct {
    name: []const u8,
    note: []const u8,
    scene: bugu.acoustic.TestScene,
    listener: bugu.Vec3,
    sender: bugu.Vec3,
};

const PlaybackCase = struct {
    name: []const u8,
    response: bugu.AcousticResponse,
    seconds: f32,
};

pub fn main(init: std.process.Init) !void {
    var play_device = false;
    var seconds_per_case: f32 = 1.75;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--device")) {
            play_device = true;
        } else if (std.mem.eql(u8, arg, "--seconds")) {
            const value = args.next() orelse return error.MissingSecondsValue;
            seconds_per_case = try std.fmt.parseFloat(f32, value);
        } else {
            return error.UnknownArgument;
        }
    }

    const allocator = std.heap.page_allocator;

    std.debug.print("Bugu acoustic showcase\n", .{});
    std.debug.print("======================\n\n", .{});
    std.debug.print("Can the current foundation support these demos? yes, for lightweight authored showcase scenes.\n", .{});
    std.debug.print("- Room + door: modeled as two zones separated by a solid wall and a wood portal. The door close percent drives portal open area.\n", .{});
    std.debug.print("- Cave: modeled with rock boundary solids plus a reverb probe, enough to show darker direct sound, reflections, lower openness, and a larger tail.\n", .{});
    std.debug.print("- Not yet full production acoustics: no arbitrary mesh baking, multi-room graph traversal, dynamic voxel updates, or physically exact wave propagation.\n\n", .{});

    try runDoorShowcase(allocator);
    try runCaveShowcase(allocator);

    if (play_device) {
        try runDeviceShowcase(init.io, allocator, seconds_per_case);
    }
}

fn runDoorShowcase(allocator: std.mem.Allocator) !void {
    const listener = bugu.Vec3{ .x = -4, .y = 0, .z = 0 };
    const sender = bugu.Vec3{ .x = 4, .y = 0, .z = 0 };
    const config = bugu.acoustic.SolveConfig{ .enable_smoothing = false };

    const cases = [_]DoorCase{
        .{ .name = "door_closed", .closed_percent = 100 },
        .{ .name = "door_75_closed", .closed_percent = 75 },
        .{ .name = "door_50_closed", .closed_percent = 50 },
        .{ .name = "door_25_closed", .closed_percent = 25 },
        .{ .name = "door_open", .closed_percent = 0 },
    };

    std.debug.print("Case 1: one room with a door between listener and sender\n", .{});
    std.debug.print("listener=(-4,0,0), sender=(4,0,0), wall at x=0, wood door portal at center\n", .{});
    std.debug.print("name              closed% open%  direct  direct_lpf  transmit transmit_lpf portal  reverb openness\n", .{});
    std.debug.print("------------------------------------------------------------------------------------------------\n", .{});

    for (cases) |case| {
        const open_fraction = 1.0 - (@as(f32, @floatFromInt(case.closed_percent)) / 100.0);
        const portal = makeDoorPortal(open_fraction);
        const portals = [_]bugu.acoustic.AcousticPortal{portal};
        const scene = bugu.acoustic.TestScenes.doorOpening(&portals);
        const response = try bugu.acoustic.solve(allocator, scene, listener, sender, config, null);

        std.debug.print(
            "{s:<17} {d:>6.0} {d:>5.0} {d:>7.4} {d:>11.0} {d:>9.4} {d:>12.0} {d:>7.4} {d:>7.4} {d:>8.4}\n",
            .{
                case.name,
                @as(f32, @floatFromInt(case.closed_percent)),
                open_fraction * 100.0,
                response.direct_gain,
                response.direct_lowpass_hz,
                response.transmission_gain,
                response.transmission_lowpass_hz,
                response.diffraction_or_portal_gain,
                response.late_reverb_send,
                response.openness,
            },
        );
    }

    std.debug.print("\n", .{});
    std.debug.print("Reading this case: as the door opens, portal gain should rise; when the direct path is blocked, transmission remains low-passed and quieter.\n\n", .{});
}

fn runCaveShowcase(allocator: std.mem.Allocator) !void {
    const listener = bugu.Vec3{ .x = -4, .y = 0, .z = 0 };
    const sender = bugu.Vec3{ .x = 4, .y = 0, .z = 0 };
    const config = bugu.acoustic.SolveConfig{ .enable_smoothing = false };

    const cases = [_]SceneCase{
        .{
            .name = "open_field",
            .note = "reference outdoor-ish scene",
            .scene = bugu.acoustic.TestScenes.openField(),
            .listener = listener,
            .sender = sender,
        },
        .{
            .name = "cave",
            .note = "rock tunnel with enclosed probe reverb",
            .scene = bugu.acoustic.TestScenes.cave(),
            .listener = listener,
            .sender = sender,
        },
    };

    std.debug.print("Case 2: cave\n", .{});
    std.debug.print("name        note                                direct  reflect0 reverb openness ambient_dir\n", .{});
    std.debug.print("--------------------------------------------------------------------------------------------\n", .{});

    for (cases) |case| {
        const response = try bugu.acoustic.solve(allocator, case.scene, case.listener, case.sender, config, null);

        std.debug.print(
            "{s:<11} {s:<35} {d:>7.4} {d:>8.4} {d:>7.4} {d:>8.4} [{d:>5.2},{d:>5.2},{d:>5.2}]\n",
            .{
                case.name,
                case.note,
                response.direct_gain,
                response.early_reflection_taps[0].gain,
                response.late_reverb_send,
                response.openness,
                response.ambient_direction.x,
                response.ambient_direction.y,
                response.ambient_direction.z,
            },
        );
    }

    std.debug.print("\n", .{});
    std.debug.print("Reading this case: the cave should have stronger early reflections, higher reverb send, and lower openness than the field.\n", .{});
}

fn makeDoorPortal(open_fraction: f32) bugu.acoustic.AcousticPortal {
    const max_area_m2 = 2.0;
    const clamped_open = std.math.clamp(open_fraction, 0.0, 1.0);
    const state: bugu.acoustic.PortalState = if (clamped_open <= 0.001)
        .closed
    else if (clamped_open >= 0.999)
        .open
    else
        .partial;

    return .{
        .id = 7,
        .center = .{ .x = 0, .y = 0, .z = 0 },
        .normal_a_to_b = .{ .x = 1, .y = 0, .z = 0 },
        .radius = 0.9,
        .area_open_m2 = max_area_m2 * clamped_open,
        .max_area_m2 = max_area_m2,
        .material_id = bugu.acoustic.TestScenes.wood_id,
        .state = state,
    };
}

fn runDeviceShowcase(io: std.Io, allocator: std.mem.Allocator, seconds_per_case: f32) !void {
    const manifest_path = "bugu-acoustic-demo-hello.toml";
    const blob_path = "bugu-acoustic-demo-hello.blob";
    const sources = [_]bugu.ImportSource{.{
        .id = "hello",
        .path = "examples/data/hello.wav",
    }};
    _ = try bugu.importToBank(io, allocator, &sources, manifest_path, blob_path);
    defer std.Io.Dir.cwd().deleteFile(io, manifest_path) catch {};
    defer std.Io.Dir.cwd().deleteFile(io, blob_path) catch {};

    var bank = try bugu.loadBank(io, allocator, manifest_path, blob_path);
    defer bank.deinit();
    const hello = bank.find("hello") orelse return error.MissingHelloSample;

    const listener = bugu.Vec3{ .x = -4, .y = 0, .z = 0 };
    const sender = bugu.Vec3{ .x = 4, .y = 0, .z = 0 };

    const closed_portals = [_]bugu.acoustic.AcousticPortal{makeDoorPortal(0.0)};
    const half_portals = [_]bugu.acoustic.AcousticPortal{makeDoorPortal(0.5)};
    const open_portals = [_]bugu.acoustic.AcousticPortal{makeDoorPortal(1.0)};

    const cases = [_]PlaybackCase{
        .{
            .name = "door closed",
            .response = try bugu.solveAcoustic(allocator, bugu.acoustic.TestScenes.doorOpening(&closed_portals), listener, sender, .{}, null),
            .seconds = seconds_per_case,
        },
        .{
            .name = "door half open",
            .response = try bugu.solveAcoustic(allocator, bugu.acoustic.TestScenes.doorOpening(&half_portals), listener, sender, .{}, null),
            .seconds = seconds_per_case,
        },
        .{
            .name = "door open",
            .response = try bugu.solveAcoustic(allocator, bugu.acoustic.TestScenes.doorOpening(&open_portals), listener, sender, .{}, null),
            .seconds = seconds_per_case,
        },
        .{
            .name = "cave",
            .response = try bugu.solveAcoustic(allocator, bugu.acoustic.TestScenes.cave(), listener, sender, .{}, null),
            .seconds = seconds_per_case + 0.75,
        },
    };

    var engine = try bugu.Engine.init(.{});
    engine.setMasterGain(0.75, 0);
    engine.setEffectBus(.reverb, .{ .return_gain = 0.55, .feedback = 0.42, .crossfeed = 0.08 });

    var backend = bugu.MiniaudioBackend.init(&engine);
    defer backend.deinit();
    try backend.open(.{});
    try backend.start();

    std.debug.print("\nRealtime playback: source=examples/data/hello.wav. Listen for muffled door leakage, clearer portal speech as it opens, then a longer cave tail.\n", .{});
    for (cases) |case| {
        const snapshot = bugu.mapAcousticResponseToSnapshot(case.response, .{ .base_gain = 0.75 });
        std.debug.print("playing: {s}\n", .{case.name});
        try startAudibleScene(&engine, snapshot, hello.samples);
        try sleepSeconds(io, case.seconds);
        engine.stopAllVoices(2400);
        try sleepSeconds(io, 0.18);
    }

    backend.stop();
    const telemetry = engine.telemetrySnapshot();
    std.debug.print(
        "playback done frames={} peak={d:.6} rms={d:.6} active={} clipping={}\n",
        .{ telemetry.rendered_frames, telemetry.peak_abs, telemetry.rms, telemetry.active_voices, telemetry.clipping_count },
    );
}

fn startAudibleScene(engine: *bugu.Engine, snapshot: bugu.AcousticMixerSnapshot, samples: []const f32) !void {
    try startOptionalLayer(engine, snapshot.direct, samples, snapshot.late_reverb_send * 0.55);
    try startOptionalLayer(engine, snapshot.transmission, samples, snapshot.late_reverb_send * 0.35);
    try startOptionalLayer(engine, snapshot.portal, samples, snapshot.late_reverb_send * 0.5);
    for (snapshot.early_reflections, 0..) |layer, index| {
        if (!layer.valid) continue;
        const reflection_send = snapshot.late_reverb_send * (1.0 - 0.08 * @as(f32, @floatFromInt(index)));
        try startOptionalLayer(engine, layer, samples, reflection_send);
    }
}

fn startOptionalLayer(engine: *bugu.Engine, layer: bugu.acoustic.AcousticLayerParams, samples: []const f32, reverb_send: f32) !void {
    if (!layer.valid or layer.gain <= 0.0) return;
    try engine.startSampleVoice(.{
        .samples = samples,
        .gain = layer.gain,
        .loop = true,
        .pan = layer.pan,
        .lowpass_hz = layer.lowpass_hz,
        .start_delay_frames = layer.delay_frames,
        .reverb_send = reverb_send,
    });
}

fn sleepSeconds(io: std.Io, seconds: f32) !void {
    const nanos: u64 = @intFromFloat(@max(seconds, 0.0) * @as(f32, @floatFromInt(std.time.ns_per_s)));
    try std.Io.sleep(io, .fromNanoseconds(nanos), .boot);
}
