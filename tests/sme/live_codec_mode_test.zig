const std = @import("std");
const live = @import("sme-author-live-owner");
const encoder_module = @import("sme-live-wire-encoder");
const t = std.testing;
test "actual imported codec and scalar encoder are isolated from requested engine mode" {
    try t.expectEqual(std.builtin.OptimizeMode.ReleaseSafe, live.semantic_recording.codec.compilation_mode);
    try t.expectEqual(std.builtin.OptimizeMode.ReleaseSafe, encoder_module.compilation_mode);
    try t.expectEqual(@import("builtin").mode, live.semantic_recording.compilation_mode);
    try t.expectEqual(@import("builtin").mode, live.semantic.compilation_mode);
    try t.expectEqual(@import("builtin").mode, live.semantic_recording.format.compilation_mode);
    try t.expectEqual(std.builtin.OptimizeMode.ReleaseSafe, live.semantic_recording.format.IntegrityHash.backendMode());
}
fn referenceInt(bytes: []u8, offset: *usize, comptime T: type, value: T) error{BufferTooSmall}!void {
    if (offset.* > bytes.len or bytes.len - offset.* < @sizeOf(T)) return error.BufferTooSmall;
    std.mem.writeInt(T, bytes[offset.*..][0..@sizeOf(T)], value, .little);
    offset.* += @sizeOf(T);
}
test "isolated encoder matches original integer bytes offsets partial writes and bounds" {
    inline for (.{ u8, u16, u32, u64, i8, i16, i32, i64 }) |T| {
        for (0..18) |capacity| for (0..20) |initial| {
            inline for (.{ std.math.minInt(T), std.math.maxInt(T), @as(T, 0) }) |value| {
                var expected: [18]u8 = @splat(0xa5);
                var actual = expected;
                var offset = initial;
                var encoder: encoder_module.Encoder = .{ .bytes = actual[0..capacity], .offset = initial };
                const old = referenceInt(expected[0..capacity], &offset, T, value);
                const new = encoder.int(T, value);
                if (old) |_| {
                    try new;
                } else |err| {
                    try t.expectError(err, new);
                }
                try t.expectEqual(offset, encoder.offset);
                try t.expectEqualSlices(u8, &expected, &actual);
            }
        };
    }
    for (0..18) |capacity| for (0..20) |initial| {
        var expected: [18]u8 = @splat(0xa5);
        var actual = expected;
        const input = "raw\x00\xff";
        var encoder: encoder_module.Encoder = .{ .bytes = actual[0..capacity], .offset = initial };
        if (initial > capacity or capacity - initial < input.len) {
            try t.expectError(error.BufferTooSmall, encoder.raw(input));
            try t.expectEqual(initial, encoder.offset);
        } else {
            @memcpy(expected[initial..][0..input.len], input);
            try encoder.raw(input);
            try t.expectEqual(initial + input.len, encoder.offset);
        }
        try t.expectEqualSlices(u8, &expected, &actual);
    };
}
