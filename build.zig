const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const bugu_audio = b.addModule("bugu_audio", .{
        .root_source_file = b.path("src/bugu_audio.zig"),
        .target = target,
        .optimize = optimize,
    });
    addMiniaudio(bugu_audio, target.result);

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "bugu_audio",
        .root_module = bugu_audio,
    });
    b.installArtifact(lib);

    const unit_tests = b.addTest(.{
        .root_module = bugu_audio,
    });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const tone_exe = b.addExecutable(.{
        .name = "bugu-tone",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/tone_demo.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tone_exe.root_module.addImport("bugu_audio", bugu_audio);
    b.installArtifact(tone_exe);

    const run_tone = b.addRunArtifact(tone_exe);
    if (b.args) |args| {
        run_tone.addArgs(args);
    }
    const tone_step = b.step("tone", "Run the P0 backend tone demo");
    tone_step.dependOn(&run_tone.step);

    const asset_exe = b.addExecutable(.{
        .name = "bugu-asset-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/asset_demo.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    asset_exe.root_module.addImport("bugu_audio", bugu_audio);
    b.installArtifact(asset_exe);

    const run_asset = b.addRunArtifact(asset_exe);
    const asset_step = b.step("asset-demo", "Run the WAV import and bank playback demo");
    asset_step.dependOn(&run_asset.step);

    const event_exe = b.addExecutable(.{
        .name = "bugu-event-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/event_demo.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    event_exe.root_module.addImport("bugu_audio", bugu_audio);
    b.installArtifact(event_exe);

    const run_event = b.addRunArtifact(event_exe);
    const event_step = b.step("event-demo", "Run the event runtime demo");
    event_step.dependOn(&run_event.step);

    const spatial_exe = b.addExecutable(.{
        .name = "bugu-spatial-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/spatial_demo.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    spatial_exe.root_module.addImport("bugu_audio", bugu_audio);
    b.installArtifact(spatial_exe);

    const run_spatial = b.addRunArtifact(spatial_exe);
    const spatial_step = b.step("spatial-demo", "Run the spatial baseline demo");
    spatial_step.dependOn(&run_spatial.step);

    const runtime_embedding = b.addExecutable(.{
        .name = "bugu-runtime-embedding",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/runtime_embedding.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    runtime_embedding.root_module.addImport("bugu_audio", bugu_audio);
    const run_runtime_embedding = b.addRunArtifact(runtime_embedding);
    const runtime_embedding_step = b.step("runtime-embedding", "Run the hardened control/snapshot compatibility sample");
    runtime_embedding_step.dependOn(&run_runtime_embedding.step);

    const acoustic_exe = b.addExecutable(.{
        .name = "bugu-acoustic-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/acoustic_demo.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    acoustic_exe.root_module.addImport("bugu_audio", bugu_audio);
    b.installArtifact(acoustic_exe);

    const run_acoustic = b.addRunArtifact(acoustic_exe);
    if (b.args) |args| {
        run_acoustic.addArgs(args);
    }
    const acoustic_step = b.step("acoustic-demo", "Run the CPU acoustic propagation demo");
    acoustic_step.dependOn(&run_acoustic.step);

    const acoustic_mapping_exe = b.addExecutable(.{
        .name = "bugu-acoustic-mapping-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/acoustic_mapping_demo.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    acoustic_mapping_exe.root_module.addImport("bugu_audio", bugu_audio);
    b.installArtifact(acoustic_mapping_exe);

    const run_acoustic_mapping = b.addRunArtifact(acoustic_mapping_exe);
    const acoustic_mapping_step = b.step("acoustic-mapping-demo", "Run AcousticResponse to mixer mapping demo");
    acoustic_mapping_step.dependOn(&run_acoustic_mapping.step);

    const validation_report_exe = b.addExecutable(.{
        .name = "bugu-validation-report",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/validation_report.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    validation_report_exe.root_module.addImport("bugu_audio", bugu_audio);
    b.installArtifact(validation_report_exe);

    const run_validation_report = b.addRunArtifact(validation_report_exe);
    const validation_report_step = b.step("validation-report", "Run text validation and profile report");
    validation_report_step.dependOn(&run_validation_report.step);

    const acoustic_effects_exe = b.addExecutable(.{
        .name = "bugu-acoustic-effects-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/acoustic_effects_demo.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    acoustic_effects_exe.root_module.addImport("bugu_audio", bugu_audio);
    b.installArtifact(acoustic_effects_exe);

    const run_acoustic_effects = b.addRunArtifact(acoustic_effects_exe);
    const acoustic_effects_step = b.step("acoustic-effects-demo", "Run acoustic snapshot runtime effects demo");
    acoustic_effects_step.dependOn(&run_acoustic_effects.step);

    const acoustic_event_exe = b.addExecutable(.{
        .name = "bugu-acoustic-event-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/acoustic_event_demo.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    acoustic_event_exe.root_module.addImport("bugu_audio", bugu_audio);
    b.installArtifact(acoustic_event_exe);

    const run_acoustic_event = b.addRunArtifact(acoustic_event_exe);
    const acoustic_event_step = b.step("acoustic-event-demo", "Run event-driven acoustic voice update demo");
    acoustic_event_step.dependOn(&run_acoustic_event.step);

    const effect_bus_exe = b.addExecutable(.{
        .name = "bugu-effect-bus-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/effect_bus_demo.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    effect_bus_exe.root_module.addImport("bugu_audio", bugu_audio);
    b.installArtifact(effect_bus_exe);

    const run_effect_bus = b.addRunArtifact(effect_bus_exe);
    const effect_bus_step = b.step("effect-bus-demo", "Run fixed effect bus routing demo");
    effect_bus_step.dependOn(&run_effect_bus.step);

    addAcousticVisualizerSteps(b, target, optimize, bugu_audio);
}

fn addMiniaudio(module: *std.Build.Module, target: std.Target) void {
    const b = module.owner;
    module.addIncludePath(b.path("third_party/miniaudio"));
    module.addCSourceFile(.{
        .file = b.path("third_party_adapters/miniaudio/miniaudio_impl.c"),
        .flags = &.{
            "-DMA_NO_ENCODING",
            "-DMA_NO_DECODING",
            "-DMA_NO_GENERATION",
            "-DMA_NO_RESOURCE_MANAGER",
            "-DMA_NO_NODE_GRAPH",
            "-DMA_NO_ENGINE",
        },
    });
    module.link_libc = true;

    switch (target.os.tag) {
        .windows => {
            module.linkSystemLibrary("ole32", .{});
            module.linkSystemLibrary("uuid", .{});
            module.linkSystemLibrary("avrt", .{});
        },
        .linux => {
            module.linkSystemLibrary("pthread", .{});
            module.linkSystemLibrary("m", .{});
            module.linkSystemLibrary("dl", .{});
        },
        else => {},
    }
}

fn addAcousticVisualizerSteps(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    bugu_audio: *std.Build.Module,
) void {
    _ = target;
    _ = bugu_audio;
    // GPU/MSVC CRT must stay Release to match slang-rhi/gpu import libs.
    const cmake_build_type = b.option(
        []const u8,
        "acoustic-visualizer-cmake-build-type",
        "CMake build type for the acoustic visualizer",
    ) orelse "Release";
    const cmake_c_compiler = b.option(
        []const u8,
        "acoustic-visualizer-c-compiler",
        "C compiler for the acoustic visualizer CMake build",
    ) orelse if (b.graph.host.result.os.tag == .windows) "cl" else "";
    const cmake_cxx_compiler = b.option(
        []const u8,
        "acoustic-visualizer-cxx-compiler",
        "C++ compiler for the acoustic visualizer CMake build",
    ) orelse if (b.graph.host.result.os.tag == .windows) "cl" else "";

    const build_dir = "build/acoustic_visualizer";
    const is_windows = b.graph.host.result.os.tag == .windows;
    const viz_target = if (is_windows)
        b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .msvc })
    else
        b.graph.host;
    const exe_name = if (is_windows) "bugu_acoustic_visualizer.exe" else "bugu_acoustic_visualizer";
    const zig_lib_name = "bugu_acoustic_visualizer_zig";
    // Prefer ReleaseSafe for the Zig lib so C sources are not built with ubsan.
    const viz_optimize: std.builtin.OptimizeMode = switch (optimize) {
        .Debug => .ReleaseSafe,
        else => optimize,
    };

    const viz_bugu = b.createModule(.{
        .root_source_file = b.path("src/bugu_audio.zig"),
        .target = viz_target,
        .optimize = viz_optimize,
    });
    addMiniaudio(viz_bugu, viz_target.result);
    viz_bugu.sanitize_c = .off;

    const gpu_adapter = b.createModule(.{
        .root_source_file = b.path("third_party_adapters/gpu/gpu_adapter.zig"),
        .target = viz_target,
        .optimize = viz_optimize,
    });
    gpu_adapter.addIncludePath(b.path("third_party_adapters/gpu"));
    gpu_adapter.addIncludePath(b.path("third_party/in_dreaming_gpu/src"));
    gpu_adapter.link_libc = true;

    const visualizer_mod = b.createModule(.{
        .root_source_file = b.path("tools/acoustic_visualizer/main.zig"),
        .target = viz_target,
        .optimize = viz_optimize,
    });
    visualizer_mod.addImport("bugu_audio", viz_bugu);
    visualizer_mod.addImport("gpu_adapter", gpu_adapter);
    visualizer_mod.addIncludePath(b.path("third_party_adapters/gpu"));
    visualizer_mod.addIncludePath(b.path("third_party/in_dreaming_gpu/src"));
    visualizer_mod.link_libc = true;
    visualizer_mod.sanitize_c = .off;

    const visualizer_lib = b.addLibrary(.{
        .linkage = .static,
        .name = zig_lib_name,
        .root_module = visualizer_mod,
    });
    visualizer_lib.bundle_compiler_rt = true;
    b.installArtifact(visualizer_lib);

    const configure = b.addSystemCommand(&.{
        "cmake",
        "-S",
        "tools/acoustic_visualizer",
        "-B",
        build_dir,
        "-G",
        "Ninja",
        b.fmt("-DCMAKE_BUILD_TYPE={s}", .{cmake_build_type}),
    });
    configure.addPrefixedFileArg("-DBUGU_ZIG_VISUALIZER_LIB=", visualizer_lib.getEmittedBin());
    if (cmake_c_compiler.len > 0) {
        configure.addArg(b.fmt("-DCMAKE_C_COMPILER={s}", .{cmake_c_compiler}));
    }
    if (cmake_cxx_compiler.len > 0) {
        configure.addArg(b.fmt("-DCMAKE_CXX_COMPILER={s}", .{cmake_cxx_compiler}));
    }
    configure.step.dependOn(&visualizer_lib.step);

    const build_exe = b.addSystemCommand(&.{
        "cmake",
        "--build",
        build_dir,
        "--target",
        "bugu_acoustic_visualizer",
    });
    build_exe.step.dependOn(&configure.step);

    const visualizer_build_step = b.step(
        "acoustic-visualizer-build",
        "Build the Zig GPU acoustic ray visualizer through CMake/Ninja",
    );
    visualizer_build_step.dependOn(&build_exe.step);

    const run_visualizer = b.addSystemCommand(&.{if (is_windows) b.fmt(".\\{s}", .{exe_name}) else b.fmt("./{s}", .{exe_name})});
    run_visualizer.setCwd(b.path(build_dir));
    run_visualizer.step.dependOn(&build_exe.step);
    if (b.args) |args| {
        run_visualizer.addArgs(args);
    }

    const visualizer_step = b.step(
        "acoustic-visualizer",
        "Build and run the interactive GPU acoustic ray visualizer",
    );
    visualizer_step.dependOn(&run_visualizer.step);

    const smoke_visualizer = b.addSystemCommand(&.{
        if (is_windows) b.fmt(".\\{s}", .{exe_name}) else b.fmt("./{s}", .{exe_name}),
        "--once",
        "--mute",
        "--report",
        "acoustic-ray-visualizer-runtime-report.txt",
    });
    smoke_visualizer.setCwd(b.path(build_dir));
    smoke_visualizer.step.dependOn(&build_exe.step);

    const visualizer_smoke_step = b.step(
        "acoustic-visualizer-smoke",
        "Build and run the acoustic ray visualizer automated smoke test",
    );
    visualizer_smoke_step.dependOn(&smoke_visualizer.step);
}
