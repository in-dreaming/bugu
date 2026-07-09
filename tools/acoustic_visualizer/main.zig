const std = @import("std");
const bugu = @import("bugu_audio");
const scene = @import("scene.zig");
const render_cpu = @import("render_cpu.zig");
const gpu_app = @import("gpu_app.zig");
const audio_bridge = @import("audio_bridge.zig");

const Cli = struct {
    once: bool = false,
    mute: bool = false,
    report_path: []const u8 = "acoustic-ray-visualizer-runtime-report.txt",
};

export fn buguAcousticVisualizerMain(argc: c_int, argv: [*][*:0]u8) callconv(.c) c_int {
    return run(argc, argv) catch |err| {
        std.log.err("acoustic visualizer failed: {s}", .{@errorName(err)});
        return 1;
    };
}

fn run(argc: c_int, argv: [*][*:0]u8) !c_int {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var cli: Cli = .{};
    var i: usize = 1;
    while (i < @as(usize, @intCast(argc))) : (i += 1) {
        const arg = std.mem.span(argv[i]);
        if (std.mem.eql(u8, arg, "--once")) {
            cli.once = true;
        } else if (std.mem.eql(u8, arg, "--mute")) {
            cli.mute = true;
        } else if (std.mem.eql(u8, arg, "--report")) {
            i += 1;
            if (i >= @as(usize, @intCast(argc))) return error.MissingReportPath;
            cli.report_path = std.mem.span(argv[i]);
        } else {
            return error.UnknownArgument;
        }
    }

    const report_file = try std.Io.Dir.cwd().createFile(io, cli.report_path, .{ .truncate = true });
    defer report_file.close(io);
    var report_buf: [4096]u8 = undefined;
    var report_writer = report_file.writer(io, &report_buf);

    var app: scene.AppState = .{};
    app.reset();

    var data: [scene.FLOAT_COUNT]f32 = undefined;
    scene.packGpuData(&app, &data);

    var vertices = try gpa.alloc(render_cpu.Vertex, render_cpu.MAX_VERTICES);
    defer gpa.free(vertices);

    var gpu = try gpu_app.GpuApp.init(&app, &data);
    defer gpu.deinit();

    std.debug.print("Bugu Acoustic Ray Visualizer (Zig)\n", .{});
    std.debug.print("controls: WASD listener, arrows source, Space door, R reset, 1/2/3 material, Esc quit\n", .{});
    std.debug.print("graphics queue support={d} reason={s}\n", .{ @intFromBool(gpu.graphics_support), gpu.graphics_reason });
    std.debug.print("compute queue support={d} reason={s}\n", .{ @intFromBool(gpu.compute_support), gpu.compute_reason });
    std.debug.print("compute shader compiled: acoustic_trace.slang\n", .{});
    std.debug.print("render shader compiled: acoustic_draw.slang\n", .{});

    try report_writer.interface.print("Bugu Acoustic Ray Visualizer runtime report\n", .{});
    try report_writer.interface.print("window=1280x720 title=\"Bugu Acoustic Ray Visualizer\"\n", .{});
    try report_writer.interface.print("graphics_queue support={d} reason={s}\n", .{ @intFromBool(gpu.graphics_support), gpu.graphics_reason });
    try report_writer.interface.print("compute_queue support={d} reason={s}\n", .{ @intFromBool(gpu.compute_support), gpu.compute_reason });
    try report_writer.interface.print("compute_shader=compiled source=acoustic_trace.slang entry=traceMain\n", .{});
    try report_writer.interface.print("render_shader=compiled source=acoustic_draw.slang entry=vertexMain fragment=fragmentMain\n", .{});
    try report_writer.interface.flush();

    // AudioBridge must stay at a fixed address: MiniaudioBackend holds
    // pointers into `engine` / itself for the device callback.
    var audio: audio_bridge.AudioBridge = undefined;
    try audio.init(gpa, io, cli.mute or cli.once);
    defer audio.deinit();
    if (!(cli.mute or cli.once)) {
        std.debug.print("audio: looping hello.wav; dual-solve CPU acoustics drive mixer\n", .{});
    } else {
        std.debug.print("audio: muted (--mute/--once)\n", .{});
    }

    var quit = false;
    var frame_count: u32 = 0;
    while (!quit) {
        gpu.pollEvents(&app, &quit);
        if (quit) break;

        app.updateMotion();
        scene.packGpuData(&app, &data);
        try gpu.traceAndReadback(&data);

        const snapshot = try audio.startOrUpdate(&app, 16.0);

        const vertex_count = render_cpu.buildVertices(&app, &data, vertices);
        try gpu.draw(&app, vertices[0..vertex_count], vertex_count);

        if ((frame_count % 120) == 0) {
            std.debug.print(
                "frame={d} material={s} door={s} rays={d} direct={d:.3} occlusion={d:.3} reflection={d:.3} portal={d:.3} reverb={d:.3} confidence={d:.3} audio_direct={d:.3} audio_pan={d:.3} audio_portal={d:.3} audio_reverb={d:.3}\n",
                .{
                    frame_count,
                    app.material().name,
                    if (app.door_open) "open" else "closed",
                    @as(u32, @intFromFloat(data[scene.METRIC_BASE + 6])),
                    data[scene.METRIC_BASE + 0],
                    data[scene.METRIC_BASE + 1],
                    data[scene.METRIC_BASE + 2],
                    data[scene.METRIC_BASE + 3],
                    data[scene.METRIC_BASE + 4],
                    data[scene.METRIC_BASE + 5],
                    snapshot.direct.gain,
                    snapshot.direct.pan,
                    snapshot.portal.gain,
                    snapshot.late_reverb_send,
                },
            );
        }
        if (frame_count < 3) {
            try report_writer.interface.print(
                "sample frame={d} material={s} door={s} rays={d} direct={d:.3} occlusion={d:.3} reflection={d:.3} portal={d:.3} reverb_send={d:.3} confidence={d:.3} vertices={d} audio_direct={d:.3} audio_pan={d:.3} audio_portal={d:.3}\n",
                .{
                    frame_count,
                    app.material().name,
                    if (app.door_open) "open" else "closed",
                    @as(u32, @intFromFloat(data[scene.METRIC_BASE + 6])),
                    data[scene.METRIC_BASE + 0],
                    data[scene.METRIC_BASE + 1],
                    data[scene.METRIC_BASE + 2],
                    data[scene.METRIC_BASE + 3],
                    data[scene.METRIC_BASE + 4],
                    data[scene.METRIC_BASE + 5],
                    vertex_count,
                    snapshot.direct.gain,
                    snapshot.direct.pan,
                    snapshot.portal.gain,
                },
            );
            try report_writer.interface.flush();
        }

        frame_count += 1;
        if (cli.once and frame_count >= 3) quit = true;
        if (cli.once and frame_count == 1) app.door_open = true;
        if (cli.once and frame_count == 2) app.material_index = 1;
    }

    std.debug.print("closed cleanly after {d} frames\n", .{frame_count});
    try report_writer.interface.print("shutdown=clean frames={d}\n", .{frame_count});
    try report_writer.interface.print("visual_inspection=not_performed_by_automated_once_run\n", .{});
    try report_writer.interface.flush();
    _ = bugu;
    return 0;
}
