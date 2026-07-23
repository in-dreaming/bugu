const std = @import("std");
const core = @import("../core/engine.zig");
const runtime = @import("../runtime/runtime.zig");

const c = @cImport({
    @cInclude("miniaudio.h");
});

pub const DeviceConfig = struct {
    sample_rate: u32 = 48_000,
    channels: u32 = 2,
    period_frames: u32 = 256,
};

pub const RuntimeDeviceEvidence = struct {
    identity: [256]u8 = [_]u8{0} ** 256,
    identity_len: u16 = 0,
    driver: [32]u8 = [_]u8{0} ** 32,
    driver_len: u8 = 0,
    sample_rate: u32 = 0,
    channels: u16 = 0,
    period_frames: u32 = 0,

    pub fn identitySlice(self: *const RuntimeDeviceEvidence) []const u8 {
        return self.identity[0..self.identity_len];
    }
    pub fn driverSlice(self: *const RuntimeDeviceEvidence) []const u8 {
        return self.driver[0..self.driver_len];
    }
};

const max_quantum_frames = 1024;
const max_channels = 2;
const max_pending_samples = max_quantum_frames * max_channels;

const FixedQuantumAdapter = struct {
    engine: *core.Engine,
    pending: [max_pending_samples]f32 = undefined,
    pending_start: usize = 0,
    pending_len: usize = 0,

    fn init(engine: *core.Engine) FixedQuantumAdapter {
        return .{ .engine = engine };
    }

    fn render(self: *FixedQuantumAdapter, output: []f32, frame_count: u32) void {
        _ = self.engine.telemetry.callback_count.fetchAdd(1, .monotonic);

        const channels = self.engine.config.channels;
        const quantum_frames = self.engine.config.quantum_frames;
        const quantum_samples = @as(usize, quantum_frames) * channels;
        const requested_samples = @as(usize, frame_count) * channels;
        var written: usize = 0;

        if (self.pending_len > 0) {
            const take = @min(self.pending_len, requested_samples);
            @memcpy(output[0..take], self.pending[self.pending_start..][0..take]);
            self.pending_start += take;
            self.pending_len -= take;
            written += take;
            if (self.pending_len == 0) {
                self.pending_start = 0;
            }
        }

        while (written < requested_samples) {
            const remaining = requested_samples - written;
            if (remaining >= quantum_samples) {
                self.engine.render(output[written..][0..quantum_samples], quantum_frames);
                written += quantum_samples;
            } else {
                self.engine.render(self.pending[0..quantum_samples], quantum_frames);
                @memcpy(output[written..][0..remaining], self.pending[0..remaining]);
                self.pending_start = remaining;
                self.pending_len = quantum_samples - remaining;
                written += remaining;
            }
        }
    }
};

const RuntimeFixedQuantumAdapter = struct {
    renderer: *runtime.RuntimeRenderer,
    quantum_frames: u32,
    channels: u16,
    pending: [max_pending_samples]f32 = undefined,
    pending_start: usize = 0,
    pending_len: usize = 0,

    fn init(renderer: *runtime.RuntimeRenderer, quantum_frames: u32, channels: u16) RuntimeFixedQuantumAdapter {
        return .{ .renderer = renderer, .quantum_frames = quantum_frames, .channels = channels };
    }

    fn render(self: *RuntimeFixedQuantumAdapter, output: []f32, frame_count: u32) void {
        _ = self.renderer.telemetry.callback_count.fetchAdd(1, .monotonic);
        const quantum_samples = @as(usize, self.quantum_frames) * self.channels;
        const requested_samples = @as(usize, frame_count) * self.channels;
        var written: usize = 0;
        if (self.pending_len > 0) {
            const take = @min(self.pending_len, requested_samples);
            @memcpy(output[0..take], self.pending[self.pending_start..][0..take]);
            self.pending_start += take;
            self.pending_len -= take;
            written += take;
            if (self.pending_len == 0) self.pending_start = 0;
        }
        while (written < requested_samples) {
            const remaining = requested_samples - written;
            if (remaining >= quantum_samples) {
                self.renderer.render(output[written..][0..quantum_samples], self.quantum_frames, self.channels);
                written += quantum_samples;
            } else {
                self.renderer.render(self.pending[0..quantum_samples], self.quantum_frames, self.channels);
                @memcpy(output[written..][0..remaining], self.pending[0..remaining]);
                self.pending_start = remaining;
                self.pending_len = quantum_samples - remaining;
                written += remaining;
            }
        }
    }
};

pub const OfflineBackend = struct {
    engine: *core.Engine,
    adapter: FixedQuantumAdapter,

    pub fn init(engine: *core.Engine) OfflineBackend {
        return .{
            .engine = engine,
            .adapter = .init(engine),
        };
    }

    pub fn renderFrames(self: *OfflineBackend, allocator: std.mem.Allocator, frame_count: u32) ![]f32 {
        const sample_count = @as(usize, frame_count) * self.engine.config.channels;
        const buffer = try allocator.alloc(f32, sample_count);
        self.adapter.render(buffer, frame_count);
        return buffer;
    }

    pub fn renderWavFile(self: *OfflineBackend, io: std.Io, path: []const u8, seconds: f32) !void {
        const frame_count: u32 = @intFromFloat(@as(f32, @floatFromInt(self.engine.config.sample_rate)) * seconds);
        const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
        defer file.close(io);

        var writer_buffer: [4096]u8 = undefined;
        var writer = file.writer(io, &writer_buffer);
        try writeWavHeader(&writer.interface, frame_count, self.engine.config.sample_rate, self.engine.config.channels);

        var frame_buffer: [max_pending_samples]f32 = undefined;
        var frames_remaining = frame_count;
        while (frames_remaining > 0) {
            const frames_this_chunk = @min(frames_remaining, self.engine.config.quantum_frames);
            const sample_count = @as(usize, frames_this_chunk) * self.engine.config.channels;
            self.adapter.render(frame_buffer[0..sample_count], frames_this_chunk);
            for (frame_buffer[0..sample_count]) |sample| {
                const clamped = std.math.clamp(sample, -1.0, 1.0);
                const pcm: i16 = @intFromFloat(clamped * 32767.0);
                try writer.interface.writeInt(i16, pcm, .little);
            }
            frames_remaining -= frames_this_chunk;
        }
        try writer.interface.flush();
    }
};

pub const RuntimeOfflineBackend = struct {
    renderer: *runtime.RuntimeRenderer,
    adapter: RuntimeFixedQuantumAdapter,

    pub fn init(renderer: *runtime.RuntimeRenderer, quantum_frames: u32, channels: u16) core.BuguError!RuntimeOfflineBackend {
        if (quantum_frames == 0 or quantum_frames > max_quantum_frames or channels != 2) return core.BuguError.InvalidArgument;
        return .{ .renderer = renderer, .adapter = .init(renderer, quantum_frames, channels) };
    }

    pub fn renderFrames(self: *RuntimeOfflineBackend, allocator: std.mem.Allocator, frame_count: u32) ![]f32 {
        const sample_count = @as(usize, frame_count) * self.adapter.channels;
        const buffer = try allocator.alloc(f32, sample_count);
        self.adapter.render(buffer, frame_count);
        return buffer;
    }
};

pub const RuntimeDeviceState = enum { closed, open, running, lost, reopening, stopped };

pub const RuntimeMiniaudioBackend = struct {
    renderer: *runtime.RuntimeRenderer,
    adapter: RuntimeFixedQuantumAdapter,
    device: c.ma_device = undefined,
    config: DeviceConfig = .{},
    state: RuntimeDeviceState = .closed,
    generation: u32 = 0,
    lost_count: u64 = 0,
    reopen_count: u64 = 0,
    notification_pending: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    evidence_value: RuntimeDeviceEvidence = .{},

    pub fn init(renderer: *runtime.RuntimeRenderer, quantum_frames: u32, channels: u16) core.BuguError!RuntimeMiniaudioBackend {
        if (quantum_frames == 0 or quantum_frames > max_quantum_frames or channels != 2) return core.BuguError.InvalidArgument;
        return .{ .renderer = renderer, .adapter = .init(renderer, quantum_frames, channels) };
    }

    pub fn open(self: *RuntimeMiniaudioBackend, config: DeviceConfig) core.BuguError!void {
        if (self.state == .open or self.state == .running) return;
        if (self.state != .closed and self.state != .stopped and self.state != .reopening and self.state != .lost) return core.BuguError.InvalidState;
        if (config.sample_rate != self.renderer.mixer.sample_rate or config.channels != self.adapter.channels or config.period_frames == 0) return core.BuguError.InvalidArgument;
        var ma_config = c.ma_device_config_init(c.ma_device_type_playback);
        ma_config.playback.format = c.ma_format_f32;
        ma_config.playback.channels = config.channels;
        ma_config.sampleRate = config.sample_rate;
        ma_config.periodSizeInFrames = config.period_frames;
        ma_config.dataCallback = runtimeDataCallback;
        ma_config.notificationCallback = runtimeNotificationCallback;
        ma_config.pUserData = self;
        if (c.ma_device_init(null, &ma_config, &self.device) != c.MA_SUCCESS) return core.BuguError.DeviceUnavailable;
        self.evidence_value = .{ .sample_rate = self.device.sampleRate, .channels = @intCast(self.device.playback.channels), .period_frames = self.device.playback.internalPeriodSizeInFrames };
        const name = std.mem.sliceTo(self.device.playback.name[0..], 0);
        const name_len = @min(name.len, self.evidence_value.identity.len);
        @memcpy(self.evidence_value.identity[0..name_len], name[0..name_len]);
        self.evidence_value.identity_len = @intCast(name_len);
        const driver = std.mem.span(c.ma_get_backend_name(self.device.pContext.*.backend));
        const driver_len = @min(driver.len, self.evidence_value.driver.len);
        @memcpy(self.evidence_value.driver[0..driver_len], driver[0..driver_len]);
        self.evidence_value.driver_len = @intCast(driver_len);
        self.config = config;
        self.state = .open;
        self.generation +%= 1;
        if (self.generation == 0) self.generation = 1;
    }

    pub fn start(self: *RuntimeMiniaudioBackend) core.BuguError!void {
        if (self.state == .running) return;
        if (self.state != .open) return core.BuguError.InvalidState;
        if (c.ma_device_start(&self.device) != c.MA_SUCCESS) return core.BuguError.DeviceStartFailed;
        self.state = .running;
    }

    pub fn notifyLost(self: *RuntimeMiniaudioBackend) void {
        if (self.state == .closed or self.state == .stopped or self.state == .lost) return;
        if (self.state == .running) _ = c.ma_device_stop(&self.device);
        c.ma_device_uninit(&self.device);
        self.state = .lost;
        self.lost_count += 1;
    }

    pub fn pollLostNotification(self: *RuntimeMiniaudioBackend) bool {
        return self.notification_pending.swap(0, .acq_rel) != 0;
    }

    pub fn evidence(self: *const RuntimeMiniaudioBackend) RuntimeDeviceEvidence {
        return self.evidence_value;
    }

    pub fn reopen(self: *RuntimeMiniaudioBackend) core.BuguError!void {
        if (self.state != .lost) return core.BuguError.InvalidState;
        self.state = .reopening;
        self.open(self.config) catch |err| {
            self.state = .lost;
            return err;
        };
        self.start() catch |err| {
            c.ma_device_uninit(&self.device);
            self.state = .lost;
            return err;
        };
        self.reopen_count += 1;
    }

    pub fn stop(self: *RuntimeMiniaudioBackend) void {
        if (self.state == .running) {
            _ = c.ma_device_stop(&self.device);
            self.state = .open;
        }
        if (self.state == .open) {
            c.ma_device_uninit(&self.device);
            self.state = .stopped;
        }
    }

    pub fn deinit(self: *RuntimeMiniaudioBackend) void {
        self.stop();
        if (self.state == .lost or self.state == .reopening) self.state = .stopped;
    }
};

pub const MiniaudioBackend = struct {
    engine: *core.Engine,
    adapter: FixedQuantumAdapter,
    device: c.ma_device = undefined,
    initialized: bool = false,
    started: bool = false,

    pub fn init(engine: *core.Engine) MiniaudioBackend {
        return .{
            .engine = engine,
            .adapter = .init(engine),
        };
    }

    pub fn open(self: *MiniaudioBackend, config: DeviceConfig) core.BuguError!void {
        if (self.initialized) return;
        if (config.sample_rate != self.engine.config.sample_rate or config.channels != self.engine.config.channels) {
            return core.BuguError.InvalidArgument;
        }
        var ma_config = c.ma_device_config_init(c.ma_device_type_playback);
        ma_config.playback.format = c.ma_format_f32;
        ma_config.playback.channels = config.channels;
        ma_config.sampleRate = config.sample_rate;
        ma_config.periodSizeInFrames = config.period_frames;
        ma_config.dataCallback = dataCallback;
        ma_config.pUserData = self;

        if (c.ma_device_init(null, &ma_config, &self.device) != c.MA_SUCCESS) {
            return core.BuguError.DeviceUnavailable;
        }
        self.initialized = true;
    }

    pub fn start(self: *MiniaudioBackend) core.BuguError!void {
        if (self.started) return;
        if (!self.initialized) return core.BuguError.InvalidState;
        if (c.ma_device_start(&self.device) != c.MA_SUCCESS) {
            return core.BuguError.DeviceStartFailed;
        }
        self.started = true;
    }

    pub fn stop(self: *MiniaudioBackend) void {
        if (self.started) {
            _ = c.ma_device_stop(&self.device);
            self.started = false;
        }
    }

    pub fn deinit(self: *MiniaudioBackend) void {
        self.stop();
        if (self.initialized) {
            c.ma_device_uninit(&self.device);
            self.initialized = false;
        }
    }
};

fn dataCallback(device: [*c]c.ma_device, output: ?*anyopaque, input: ?*const anyopaque, frame_count: c.ma_uint32) callconv(.c) void {
    _ = input;
    if (device == null or output == null) return;
    const backend: *MiniaudioBackend = @ptrCast(@alignCast(device.*.pUserData));
    const sample_count = @as(usize, frame_count) * backend.engine.config.channels;
    const out: [*]f32 = @ptrCast(@alignCast(output));
    backend.adapter.render(out[0..sample_count], frame_count);
}

fn runtimeDataCallback(device: [*c]c.ma_device, output: ?*anyopaque, input: ?*const anyopaque, frame_count: c.ma_uint32) callconv(.c) void {
    _ = input;
    if (device == null or output == null) return;
    const backend: *RuntimeMiniaudioBackend = @ptrCast(@alignCast(device.*.pUserData));
    const sample_count = @as(usize, frame_count) * backend.adapter.channels;
    const out: [*]f32 = @ptrCast(@alignCast(output));
    backend.adapter.render(out[0..sample_count], frame_count);
}

fn runtimeNotificationCallback(notification: [*c]const c.ma_device_notification) callconv(.c) void {
    if (notification == null or notification.*.pDevice == null) return;
    const backend: *RuntimeMiniaudioBackend = @ptrCast(@alignCast(notification.*.pDevice.*.pUserData));
    switch (notification.*.type) {
        c.ma_device_notification_type_rerouted, c.ma_device_notification_type_interruption_began => backend.notification_pending.store(1, .release),
        else => {},
    }
}

fn writeWavHeader(writer: *std.Io.Writer, frame_count: u32, sample_rate: u32, channels: u16) !void {
    const bits_per_sample: u16 = 16;
    const block_align: u16 = channels * (bits_per_sample / 8);
    const byte_rate: u32 = sample_rate * block_align;
    const data_bytes: u32 = frame_count * block_align;
    const riff_size: u32 = 36 + data_bytes;

    try writer.writeAll("RIFF");
    try writer.writeInt(u32, riff_size, .little);
    try writer.writeAll("WAVE");
    try writer.writeAll("fmt ");
    try writer.writeInt(u32, 16, .little);
    try writer.writeInt(u16, 1, .little);
    try writer.writeInt(u16, channels, .little);
    try writer.writeInt(u32, sample_rate, .little);
    try writer.writeInt(u32, byte_rate, .little);
    try writer.writeInt(u16, block_align, .little);
    try writer.writeInt(u16, bits_per_sample, .little);
    try writer.writeAll("data");
    try writer.writeInt(u32, data_bytes, .little);
}

test "offline backend writes samples" {
    var engine = try core.Engine.init(.{});
    try engine.startTestVoice(.{ .frequency_hz = 330.0, .gain = 0.2 });
    var backend = OfflineBackend.init(&engine);
    const samples = try backend.renderFrames(std.testing.allocator, 127);
    defer std.testing.allocator.free(samples);
    try std.testing.expect(samples.len == 254);
    try std.testing.expectEqual(@as(u64, 1), engine.telemetrySnapshot().callback_count);
    try std.testing.expectEqual(@as(u64, 256), engine.telemetrySnapshot().rendered_frames);
    try std.testing.expect(engine.telemetrySnapshot().peak_abs > 0.0);
}

test "runtime offline backend handles variable callback sizes through immutable snapshots" {
    const samples = [_]f32{ 0.25, -0.25, 0.5, -0.5 };
    var owner = try runtime.SampleOwner.init(&samples);
    var control = runtime.ControlRuntime.init();
    const instance = try control.reserveInstance();
    try control.submitPlay(.{ .instance = instance, .owner = &owner, .params = .{ .loop = true } });
    _ = try control.controlTick(runtime.max_control_drain);
    var renderer = runtime.RuntimeRenderer.init(&control, 48_000);
    var backend = try RuntimeOfflineBackend.init(&renderer, 256, 2);
    inline for (.{ 1, 127, 256, 300, 513 }) |frames| {
        const output = try backend.renderFrames(std.testing.allocator, frames);
        defer std.testing.allocator.free(output);
        for (output) |sample| try std.testing.expect(std.math.isFinite(sample));
    }
    try control.submitStop(.{ .instance = instance, .fade_frames = 1 });
    _ = try control.controlTick(runtime.max_control_drain);
    const tail = try backend.renderFrames(std.testing.allocator, 513);
    defer std.testing.allocator.free(tail);
    _ = try control.controlTick(runtime.max_control_drain);
    owner.retire();
    try control.destroy();
    try std.testing.expect(owner.canDestroy());
}
