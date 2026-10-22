//! Portable scalar fixed-point profile. Version changes require a new ID/hash.
const std = @import("std");
const t = @import("types.zig");
pub const id = "bugu-opus-fixed24-cbr20-v1";
pub const opus_version = "1.6.1";
pub const frame_frames = 960;
pub const serial: u32 = 0x534d4501;
pub const description = id ++ ";opus=22244de5a79bd1d6d623c32e72bf1954b56235be;ogg=be05b13e98b048f0b5a0f5fa8ce514d56db5f822;rate=48000;frame=960;bitrate=64000/channel;cbr;application=audio;signal=music;complexity=10;lsb=24;fec=0;loss=0;dtx=0;phase-inversion=0;fixed-point;res24=on;float-api=off;rtcd=off;intrinsics=off;dnn=off;qext=off;fast-math=off;fma=off;pcm=ties-even-s24;header-gain=zig-f64-postdecode-unclipped;seek-preroll=11520;seek-oracle-max-abs=0.0002;pad=zeros;serial=534d4501";
pub const hash: [32]u8 = blk: {
    @setEvalBranchQuota(100000);
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(description, &out, .{});
    break :blk out;
};
pub fn toInt24(value: f32) t.Error!i32 {
    if (!std.math.isFinite(value) or value < -1 or value > 1) return error.InvalidPcm;
    const x: f64 = @as(f64, value) * 8388608.0;
    const base = @floor(x);
    const fraction = x - base;
    var rounded: i64 = @intFromFloat(base);
    if (fraction > 0.5 or (fraction == 0.5 and @mod(rounded, 2) != 0)) rounded += 1;
    return @intCast(@min(rounded, 8388607));
}
pub fn fromInt24(value: i32) f32 {
    return @as(f32, @floatFromInt(value)) / 8388608.0;
}
