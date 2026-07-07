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
