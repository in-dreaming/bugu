//! TASK-015 pure default resolver. The separate music_policies pass owns serialization.
const std = @import("std");
const stinger = @import("sme-policy-types").stinger;
const acoustic = @import("sme-policy-types").acoustic;
pub const Error = stinger.Error || acoustic.Error;
pub const Origin = enum { release, platform, asset };
pub fn Value(comptime T: type) type {
    return struct { value: T, origin: Origin };
}
pub fn PolicyReport(comptime T: type) type {
    return struct {
        value: T,
        /// Canonical order is the declared policy field order, including version.
        provenance: [@typeInfo(T).@"struct".fields.len]Origin,
        pub fn origin(self: @This(), field: std.meta.FieldEnum(T)) Origin {
            return self.provenance[@intFromEnum(field)];
        }
    };
}
pub const StingerOverride = struct {
    max_polyphony: ?u16 = null,
    repeat_frames: ?u64 = null,
    deadline_frames: ?u64 = null,
    sync: ?stinger.Sync = null,
    conflict: ?stinger.ConflictPolicy = null,
    priority: ?u8 = null,
    protected: ?bool = null,
    /// Outer null inherits; an explicit inner null disables an inherited duck.
    duck_preset: ??u64 = null,
};
pub const AcousticOverride = struct {
    minimum_q16: ?i32 = null,
    maximum_q16: ?i32 = null,
    neutral_q16: ?i32 = null,
    attack_frames: ?u64 = null,
    release_frames: ?u64 = null,
    rate_per_second_q16: ?u32 = null,
    quantize_intervals: ?u32 = null,
    stale_frames: ?u64 = null,
    missing: ?acoustic.Missing = null,
};
pub const Overrides = struct {
    max_stingers: ?u16 = null,
    stinger: StingerOverride = .{},
    /// Stable order is openness, room, path; overrides never leak across inputs.
    inputs: [3]AcousticOverride = .{ .{}, .{}, .{} },
};
pub const Report = struct {
    producer_version: u16 = 1,
    sample_rate: u32,
    max_stingers: Value(u16),
    stinger: PolicyReport(stinger.Policy),
    inputs: [3]PolicyReport(acoustic.Policy),
};
fn choose(comptime T: type, release: T, platform: ?T, asset: ?T) Value(T) {
    if (asset) |value| return .{ .value = value, .origin = .asset };
    if (platform) |value| return .{ .value = value, .origin = .platform };
    return .{ .value = release, .origin = .release };
}
fn resolve(comptime T: type, release: T, platform: anytype, asset: @TypeOf(platform)) PolicyReport(T) {
    var report: PolicyReport(T) = .{ .value = release, .provenance = @splat(.release) };
    inline for (@typeInfo(T).@"struct".fields, 0..) |field, i| {
        if (comptime !std.mem.eql(u8, field.name, "version")) {
            const chosen = choose(field.type, @field(release, field.name), @field(platform, field.name), @field(asset, field.name));
            @field(report.value, field.name) = chosen.value;
            report.provenance[i] = chosen.origin;
        }
    }
    return report;
}
/// Checked nearest/ties-even conversion; no hidden fixed 48 kHz assumption.
pub fn framesFromMilliseconds(milliseconds: u64, sample_rate: u32) Error!u64 {
    if (sample_rate < 8000 or sample_rate > 384000) return error.InvalidPolicy;
    const numerator = @as(u128, milliseconds) * sample_rate;
    const q = numerator / 1000;
    const r = numerator % 1000;
    const rounded = q + @intFromBool(r > 500 or (r == 500 and q & 1 == 1));
    if (rounded > std.math.maxInt(u64)) return error.Overflow;
    return @intCast(rounded);
}
/// Select only this global field. The final stinger validator or the serialized
/// PolicyConfig validator owns its range check; no hypothetical policy is built.
pub fn selectMaxStingers(platform: ?u16, asset: ?u16) Value(u16) {
    return choose(u16, 8, platform, asset);
}
/// Resolve and validate one actual stinger against its final global limit.
pub fn compileStinger(sample_rate: u32, max_stingers: u16, platform: StingerOverride, asset: StingerOverride) Error!PolicyReport(stinger.Policy) {
    const release_stinger: stinger.Policy = .{
        .max_polyphony = 1,
        .repeat_frames = try framesFromMilliseconds(100, sample_rate),
        .deadline_frames = try framesFromMilliseconds(500, sample_rate),
        .sync = .immediate,
        .conflict = .drop,
        .priority = 0,
        .protected = false,
        .duck_preset = null,
    };
    const report = resolve(stinger.Policy, release_stinger, platform, asset);
    try report.value.validate(max_stingers);
    return report;
}
/// Resolve and validate one actual input; other inputs are not intermediate
/// policies and cannot invalidate this input before their own asset overrides.
pub fn compileAcoustic(sample_rate: u32, platform: AcousticOverride, asset: AcousticOverride) Error!PolicyReport(acoustic.Policy) {
    const release_acoustic: acoustic.Policy = .{
        .minimum_q16 = 0,
        .maximum_q16 = acoustic.one,
        .neutral_q16 = acoustic.one / 2,
        .attack_frames = try framesFromMilliseconds(50, sample_rate),
        .release_frames = try framesFromMilliseconds(250, sample_rate),
        .rate_per_second_q16 = 2 * acoustic.one,
        .quantize_intervals = 256,
        .stale_frames = try framesFromMilliseconds(250, sample_rate),
        .missing = .hold_last,
    };
    const report = resolve(acoustic.Policy, release_acoustic, platform, asset);
    try report.value.validate();
    return report;
}
/// Existing complete-report API keeps the same defaults, precedence and final
/// policy validation. Serialized producers use the scoped entry points above.
pub fn compile(sample_rate: u32, platform: Overrides, asset: Overrides) Error!Report {
    const max_stingers = selectMaxStingers(platform.max_stingers, asset.max_stingers);
    var report: Report = .{
        .sample_rate = sample_rate,
        .max_stingers = max_stingers,
        .stinger = try compileStinger(sample_rate, max_stingers.value, platform.stinger, asset.stinger),
        .inputs = undefined,
    };
    for (&report.inputs, platform.inputs, asset.inputs) |*input, p, a| input.* = try compileAcoustic(sample_rate, p, a);
    return report;
}
