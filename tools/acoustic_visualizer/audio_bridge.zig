const std = @import("std");
const bugu = @import("bugu_audio");
const scene = @import("scene.zig");

pub const AudioBridge = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    engine: bugu.Engine,
    backend: ?bugu.MiniaudioBackend = null,
    bank: ?bugu.Bank = null,
    runtime: bugu.EventRuntime = undefined,
    event_entries: [1]bugu.EventEntry = undefined,
    sound_refs: [1]bugu.SoundRef = undefined,
    instance: ?bugu.AcousticEventInstance = null,
    portal_storage: [1]bugu.acoustic.AcousticPortal = undefined,
    muted: bool = false,
    manifest_path: []const u8 = "bugu-acoustic-visualizer-hello.toml",
    blob_path: []const u8 = "bugu-acoustic-visualizer-hello.blob",
    event_id: u64 = 0,

    /// Initialize in place. Must not move `self` after this returns while the
    /// miniaudio device is open — the device callback holds pointers into `self`.
    pub fn init(self: *AudioBridge, allocator: std.mem.Allocator, io: std.Io, muted: bool) !void {
        self.* = .{
            .allocator = allocator,
            .io = io,
            .engine = try bugu.Engine.init(.{}),
            .muted = muted,
        };
        self.engine.setMasterGain(0.75, 0);
        self.engine.setEffectBus(.reverb, .{ .return_gain = 0.55, .feedback = 0.42, .crossfeed = 0.08 });
        self.event_id = bugu.hashEventName("viz.hello.loop");

        const wav_path = try resolveHelloWav(io);
        const sources = [_]bugu.ImportSource{.{
            .id = "hello",
            .path = wav_path,
        }};
        _ = try bugu.importToBank(io, allocator, &sources, self.manifest_path, self.blob_path);
        self.bank = try bugu.loadBank(io, allocator, self.manifest_path, self.blob_path);
        const hello = self.bank.?.find("hello") orelse return error.MissingHelloSample;

        self.sound_refs[0] = .{
            .id = "hello",
            .samples = hello.samples,
            .gain = 1.0,
            .priority = 2.0,
        };
        self.event_entries[0] = .{
            .id = self.event_id,
            .action = .{ .play = .{ .variants = &self.sound_refs, .loop = true } },
        };
        self.runtime = bugu.EventRuntime.init(&self.event_entries);

        if (!muted) {
            // Open the device against the stable `self.backend` slot so
            // `pUserData` / `engine` pointers remain valid for the callback.
            self.backend = bugu.MiniaudioBackend.init(&self.engine);
            const backend = &self.backend.?;
            try backend.open(.{});
            try backend.start();
        }
    }

    pub fn deinit(self: *AudioBridge) void {
        self.engine.stopAllVoices(2400);
        if (self.backend) |*backend| {
            backend.stop();
            backend.deinit();
            self.backend = null;
        }
        if (self.bank) |*bank| {
            bank.deinit();
            self.bank = null;
        }
        std.Io.Dir.cwd().deleteFile(self.io, self.manifest_path) catch {};
        std.Io.Dir.cwd().deleteFile(self.io, self.blob_path) catch {};
    }

    pub fn startOrUpdate(self: *AudioBridge, app: *const scene.AppState, dt_ms: f32) !bugu.AcousticMixerSnapshot {
        const snapshot = try self.solveSnapshot(app);
        if (self.instance) |*inst| {
            _ = try inst.update(&self.engine, snapshot, dt_ms);
        } else {
            const posted = try self.runtime.postAcousticEvent(&self.engine, self.event_id, snapshot);
            self.instance = posted.instance;
        }
        return snapshot;
    }

    pub fn solveSnapshot(self: *AudioBridge, app: *const scene.AppState) !bugu.AcousticMixerSnapshot {
        self.portal_storage[0] = app.makePortal();
        const acoustic_scene = app.toAcousticScene(&self.portal_storage);
        const response = try bugu.solveAcoustic(
            self.allocator,
            acoustic_scene,
            app.listener3d(),
            app.source3d(),
            .{},
            null,
        );
        return bugu.mapAcousticResponseToSnapshot(response, .{
            .base_gain = 0.75,
            .sample_rate = self.engine.config.sample_rate,
        });
    }
};

fn resolveHelloWav(io: std.Io) ![]const u8 {
    const candidates = [_][]const u8{
        "hello.wav",
        "examples/data/hello.wav",
        "../examples/data/hello.wav",
        "../../examples/data/hello.wav",
    };
    for (candidates) |path| {
        std.Io.Dir.cwd().access(io, path, .{}) catch continue;
        return path;
    }
    return error.MissingHelloWav;
}
