//! Single source of speaker order, schema layout tags and frozen linear routing.
//! Matrix coefficients never include clipping, normalization or a limiter.
const std = @import("std");
pub const max_channels = 8;
pub const Error = error{ UnsupportedChannelLayout, InvalidArgument, ArithmeticOverflow };
pub const Layout = enum(u8) { mono, stereo, surround_5_1, surround_7_1, explicit_mask };
pub const Speaker = enum(u32) {
    fl = 0x1,
    fr = 0x2,
    fc = 0x4,
    lfe = 0x8,
    bl = 0x10,
    br = 0x20,
    flc = 0x40,
    frc = 0x80,
    bc = 0x100,
    sl = 0x200,
    sr = 0x400,
    tc = 0x800,
    tfl = 0x1000,
    tfc = 0x2000,
    tfr = 0x4000,
    tbl = 0x8000,
    tbc = 0x10000,
    tbr = 0x20000,
};
pub const known_mask: u32 = 0x3ffff;
pub const canonical_masks = [_]u32{ 0x4, 0x3, 0x3f, 0x63f };
pub const canonical_counts = [_]u16{ 1, 2, 6, 8 };
pub const half_power: f32 = 0.70710678118654752440;
pub const matrix_version: u32 = 1;

pub const ChannelLayout = struct {
    kind: Layout,
    count: u16,
    mask: u32,
    order: [max_channels]Speaker = @splat(.fc),

    pub fn canonical(kind: Layout) Error!ChannelLayout {
        if (kind == .explicit_mask) return error.UnsupportedChannelLayout;
        const i = @intFromEnum(kind);
        return init(kind, canonical_counts[i], canonical_masks[i]);
    }
    pub fn fromCount(count: u16) Error!ChannelLayout {
        return canonical(switch (count) {
            1 => .mono,
            2 => .stereo,
            6 => .surround_5_1,
            8 => .surround_7_1,
            else => return error.UnsupportedChannelLayout,
        });
    }
    pub fn init(kind: Layout, count: u16, mask: u32) Error!ChannelLayout {
        if (count == 0 or count > max_channels or mask & ~known_mask != 0 or @popCount(mask) != count) return error.UnsupportedChannelLayout;
        if (kind != .explicit_mask and (mask != canonical_masks[@intFromEnum(kind)] or count != canonical_counts[@intFromEnum(kind)])) return error.UnsupportedChannelLayout;
        var result: ChannelLayout = .{ .kind = kind, .count = count, .mask = mask };
        var remaining = mask;
        var slot: usize = 0;
        while (remaining != 0) : (slot += 1) {
            const bit: u32 = @as(u32, 1) << @as(u5, @intCast(@ctz(remaining)));
            result.order[slot] = @enumFromInt(bit);
            remaining &= ~bit;
        }
        return result;
    }
    pub fn validate(self: ChannelLayout) Error!void {
        const expected = try init(self.kind, self.count, self.mask);
        if (!std.mem.eql(Speaker, self.order[0..self.count], expected.order[0..self.count])) return error.UnsupportedChannelLayout;
    }
    pub fn eql(a: ChannelLayout, b: ChannelLayout) bool {
        return a.count == b.count and a.mask == b.mask and std.mem.eql(Speaker, a.order[0..a.count], b.order[0..b.count]);
    }
    pub fn index(self: ChannelLayout, speaker: Speaker) ?usize {
        for (self.order[0..self.count], 0..) |s, i| if (s == speaker) return i;
        return null;
    }
};
pub const mono = ChannelLayout.canonical(.mono) catch unreachable;
pub const stereo = ChannelLayout.canonical(.stereo) catch unreachable;
pub const surround_5_1 = ChannelLayout.canonical(.surround_5_1) catch unreachable;
pub const surround_7_1 = ChannelLayout.canonical(.surround_7_1) catch unreachable;
pub const canonical_layouts = [_]ChannelLayout{ mono, stereo, surround_5_1, surround_7_1 };

pub fn sampleCount(frames: usize, channels: u16) Error!usize {
    if (channels == 0 or channels > max_channels) return error.UnsupportedChannelLayout;
    return std.math.mul(usize, frames, channels) catch error.ArithmeticOverflow;
}
pub const InterleavedView = struct {
    samples: []const f32,
    frames: usize,
    layout: ChannelLayout,
    pub fn init(samples: []const f32, layout: ChannelLayout) Error!InterleavedView {
        try layout.validate();
        if (samples.len % layout.count != 0) return error.InvalidArgument;
        return .{ .samples = samples, .frames = samples.len / layout.count, .layout = layout };
    }
    pub fn frame(self: InterleavedView, i: usize) []const f32 {
        std.debug.assert(i < self.frames);
        return self.samples[i * self.layout.count ..][0..self.layout.count];
    }
};

pub const Matrix = struct {
    input: ChannelLayout,
    output: ChannelLayout,
    id: u64,
    /// Destination-major: coefficients[output channel][input channel].
    coefficients: [max_channels][max_channels]f32 = @splat(@splat(0)),
    pub fn compile(input: ChannelLayout, output: ChannelLayout) Error!Matrix {
        try input.validate();
        try output.validate();
        var result: Matrix = .{ .input = input, .output = output, .id = (@as(u64, matrix_version) << 40) | (@as(u64, input.mask) << 20) | output.mask };
        if (ChannelLayout.eql(input, output)) {
            for (0..input.count) |i| result.coefficients[i][i] = 1;
            return result;
        }
        if (output.mask == stereo.mask and input.mask & ~surround_7_1.mask == 0) {
            for (input.order[0..input.count], 0..) |speaker, i| switch (speaker) {
                .fl => result.coefficients[0][i] = 1,
                .fr => result.coefficients[1][i] = 1,
                .fc => {
                    result.coefficients[0][i] = half_power;
                    result.coefficients[1][i] = half_power;
                },
                .bl, .sl => result.coefficients[0][i] = half_power,
                .br, .sr => result.coefficients[1][i] = half_power,
                .lfe => {}, // Deliberate exclusion. Never inject LFE into full-range output.
                else => unreachable,
            };
            return result;
        }
        if (output.mask == mono.mask and input.mask == stereo.mask) {
            result.coefficients[0][0] = half_power;
            result.coefficients[0][1] = half_power;
            return result;
        }
        const canonical_input = input.mask == mono.mask or input.mask == stereo.mask or input.mask == surround_5_1.mask or input.mask == surround_7_1.mask;
        const surround_output = output.mask == surround_5_1.mask or output.mask == surround_7_1.mask;
        if (canonical_input and surround_output) {
            for (input.order[0..input.count], 0..) |speaker, i| {
                if (output.index(speaker)) |o| result.coefficients[o][i] = 1 else switch (speaker) {
                    .sl => result.coefficients[output.index(.bl).?][i] = half_power,
                    .sr => result.coefficients[output.index(.br).?][i] = half_power,
                    else => return error.UnsupportedChannelLayout,
                }
            }
            return result;
        }
        // Surround-to-mono uses the frozen stereo fold followed by the mono fold.
        if (output.mask == mono.mask and (input.mask == surround_5_1.mask or input.mask == surround_7_1.mask)) {
            const fold = try compile(input, stereo);
            for (0..input.count) |i| result.coefficients[0][i] = (fold.coefficients[0][i] + fold.coefficients[1][i]) * half_power;
            return result;
        }
        return error.UnsupportedChannelLayout;
    }
    pub fn addFrame(self: *const Matrix, source: []const f32, destination: []f32, gain: f32) void {
        std.debug.assert(source.len == self.input.count and destination.len == self.output.count);
        for (0..self.output.count) |o| {
            var sum: f32 = 0;
            for (0..self.input.count) |i| sum += source[i] * self.coefficients[o][i];
            destination[o] += sum * gain;
        }
    }
};

pub const OutputLayoutRequest = struct {
    layout: ChannelLayout = stereo,
    policy: enum { strict_match, explicit_conversion } = .strict_match,
    conversion_target: ?ChannelLayout = null,
    pub fn target(self: OutputLayoutRequest) Error!ChannelLayout {
        try self.layout.validate();
        switch (self.policy) {
            .strict_match => {
                if (self.conversion_target != null) return error.InvalidArgument;
                return self.layout;
            },
            .explicit_conversion => {
                const output = self.conversion_target orelse return error.InvalidArgument;
                _ = try Matrix.compile(self.layout, output);
                return output;
            },
        }
    }
};

pub const Permutation = struct {
    count: u16,
    source_for_destination: [max_channels]u8 = @splat(0),
    pub fn compile(canonical: ChannelLayout, negotiated: []const Speaker) Error!Permutation {
        try canonical.validate();
        if (negotiated.len != canonical.count) return error.UnsupportedChannelLayout;
        var result: Permutation = .{ .count = canonical.count };
        var mask: u32 = 0;
        for (negotiated, 0..) |speaker, index| {
            const bit = @intFromEnum(speaker);
            if (bit & known_mask == 0 or mask & bit != 0) return error.UnsupportedChannelLayout;
            result.source_for_destination[index] = @intCast(canonical.index(speaker) orelse return error.UnsupportedChannelLayout);
            mask |= bit;
        }
        if (mask != canonical.mask) return error.UnsupportedChannelLayout;
        return result;
    }
    pub fn apply(self: Permutation, interleaved: []f32) void {
        std.debug.assert(interleaved.len % self.count == 0);
        var offset: usize = 0;
        while (offset < interleaved.len) : (offset += self.count) {
            var frame: [max_channels]f32 = undefined;
            @memcpy(frame[0..self.count], interleaved[offset..][0..self.count]);
            for (0..self.count) |i| interleaved[offset + i] = frame[self.source_for_destination[i]];
        }
    }
};
