const std = @import("std");

pub const Vec3 = struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,

    pub fn sub(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
    }

    pub fn dot(a: Vec3, b: Vec3) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z;
    }

    pub fn length(a: Vec3) f32 {
        return @sqrt(dot(a, a));
    }

    pub fn normalize(a: Vec3) Vec3 {
        const len = a.length();
        if (len <= 0.00001) return .{};
        return .{ .x = a.x / len, .y = a.y / len, .z = a.z / len };
    }
};

pub const Transform = struct {
    position: Vec3 = .{},
    forward: Vec3 = .{ .x = 0, .y = 0, .z = 1 },
    right: Vec3 = .{ .x = 1, .y = 0, .z = 0 },
    velocity: Vec3 = .{},
};

pub const DistanceCurve = union(enum) {
    linear,
    inverse,
    custom_lut: []const f32,
};

pub const Cone = struct {
    inner_degrees: f32 = 60.0,
    outer_degrees: f32 = 120.0,
    outer_gain: f32 = 0.35,
    outer_lowpass_hz: f32 = 1800.0,
};

pub const AttenuationProfile = struct {
    min_distance: f32 = 1.0,
    max_distance: f32 = 40.0,
    curve: DistanceCurve = .inverse,
    cone: ?Cone = null,
    doppler_scale: f32 = 1.0,
    min_pitch_ratio: f32 = 0.5,
    max_pitch_ratio: f32 = 2.0,
};

pub const SpatialParams = struct {
    distance: f32,
    gain: f32,
    pan: f32,
    lowpass_hz: f32,
    pitch_ratio: f32,
    cone_gain: f32,
};

pub const Smoother = struct {
    value: f32 = 0,

    pub fn step(self: *Smoother, target: f32, alpha: f32) f32 {
        self.value += (target - self.value) * std.math.clamp(alpha, 0.0, 1.0);
        return self.value;
    }
};

pub fn evaluate(listener: Transform, emitter: Transform, profile: AttenuationProfile) SpatialParams {
    const to_emitter = emitter.position.sub(listener.position);
    const distance = @max(to_emitter.length(), 0.0001);
    const dir_listener_to_emitter = to_emitter.normalize();
    const dir_emitter_to_listener = listener.position.sub(emitter.position).normalize();

    const distance_gain = evaluateDistance(profile, distance);
    const pan = std.math.clamp(Vec3.dot(dir_listener_to_emitter, listener.right), -1.0, 1.0);

    var cone_gain: f32 = 1.0;
    var lowpass_hz: f32 = 20_000.0;
    if (profile.cone) |cone| {
        const facing = std.math.clamp(Vec3.dot(emitter.forward.normalize(), dir_emitter_to_listener), -1.0, 1.0);
        const angle = radiansToDegrees(std.math.acos(facing));
        const inner = cone.inner_degrees * 0.5;
        const outer = @max(cone.outer_degrees * 0.5, inner + 0.001);
        const t = std.math.clamp((angle - inner) / (outer - inner), 0.0, 1.0);
        const smooth = t * t * (3.0 - 2.0 * t);
        cone_gain = 1.0 + (cone.outer_gain - 1.0) * smooth;
        lowpass_hz = 20_000.0 + (cone.outer_lowpass_hz - 20_000.0) * smooth;
    }

    const speed_of_sound = 343.0;
    const listener_velocity = Vec3.dot(listener.velocity, dir_listener_to_emitter) * profile.doppler_scale;
    const emitter_velocity = Vec3.dot(emitter.velocity, dir_listener_to_emitter) * profile.doppler_scale;
    const raw_pitch = (speed_of_sound - listener_velocity) / @max(speed_of_sound - emitter_velocity, 1.0);
    const pitch = std.math.clamp(raw_pitch, profile.min_pitch_ratio, profile.max_pitch_ratio);

    return .{
        .distance = distance,
        .gain = distance_gain * cone_gain,
        .pan = pan,
        .lowpass_hz = lowpass_hz,
        .pitch_ratio = pitch,
        .cone_gain = cone_gain,
    };
}

fn evaluateDistance(profile: AttenuationProfile, distance: f32) f32 {
    const min_d = @max(profile.min_distance, 0.0001);
    const max_d = @max(profile.max_distance, min_d + 0.0001);
    const t = std.math.clamp((distance - min_d) / (max_d - min_d), 0.0, 1.0);
    return switch (profile.curve) {
        .linear => 1.0 - t,
        .inverse => min_d / @max(distance, min_d),
        .custom_lut => |lut| sampleLut(lut, t),
    };
}

fn sampleLut(lut: []const f32, t: f32) f32 {
    if (lut.len == 0) return 1.0;
    if (lut.len == 1) return lut[0];
    const x = t * @as(f32, @floatFromInt(lut.len - 1));
    const i: usize = @intFromFloat(@floor(x));
    const j = @min(i + 1, lut.len - 1);
    const f = x - @as(f32, @floatFromInt(i));
    return lut[i] + (lut[j] - lut[i]) * f;
}

fn radiansToDegrees(radians: f32) f32 {
    return radians * 180.0 / std.math.pi;
}

test "spatial params are transform derived and clamped" {
    const profile: AttenuationProfile = .{
        .curve = .linear,
        .min_distance = 1,
        .max_distance = 11,
        .cone = .{ .inner_degrees = 60, .outer_degrees = 120, .outer_gain = 0.25, .outer_lowpass_hz = 1000 },
    };
    const listener: Transform = .{ .position = .{ .x = 0, .y = 0, .z = 0 } };
    const emitter: Transform = .{
        .position = .{ .x = 10, .y = 0, .z = 0 },
        .forward = .{ .x = 1, .y = 0, .z = 0 },
        .velocity = .{ .x = -120, .y = 0, .z = 0 },
    };
    const params = evaluate(listener, emitter, profile);
    try std.testing.expect(params.gain < 0.1);
    try std.testing.expect(params.pan > 0.9);
    try std.testing.expect(params.lowpass_hz < 20_000);
    try std.testing.expect(params.pitch_ratio > 0.5 and params.pitch_ratio <= 2.0);
}
