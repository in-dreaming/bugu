const std = @import("std");
const audio = @import("bugu_audio");

pub fn main(init: std.process.Init) !void {
    var samples: [1024]f32 = undefined;
    for (&samples, 0..) |*sample, index| sample.* = if (index & 31 < 16) 0.2 else -0.2;
    var owner = try audio.RuntimeSampleOwner.init(&samples);
    var control = audio.ControlRuntime.init();
    const instance = try control.reserveInstance();
    try control.submitPlay(.{ .instance = instance, .owner = &owner, .params = .{ .loop = true, .gain = 0.5, .bus = .sfx } });
    _ = try control.controlTick(audio.runtime.max_control_drain);

    // ControlRuntime and RuntimeRenderer have stable addresses from this point.
    var renderer = audio.RuntimeRenderer.init(&control, 48_000);
    var backend = try audio.RuntimeOfflineBackend.init(&renderer, 256, 2);
    const pcm = try backend.renderFrames(init.gpa, 513);
    defer init.gpa.free(pcm);

    try control.submitStop(.{ .instance = instance, .fade_frames = 64 });
    _ = try control.controlTick(audio.runtime.max_control_drain);
    const tail = try backend.renderFrames(init.gpa, 513);
    defer init.gpa.free(tail);
    _ = try control.controlTick(audio.runtime.max_control_drain);
    owner.retire();
    try control.destroy();

    var buffer: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    try stdout.interface.print("runtime embedding: pcm={} tail={} owner_retired={}\n", .{ pcm.len, tail.len, owner.canDestroy() });
    try stdout.interface.flush();
}
