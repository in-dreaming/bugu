const std = @import("std");
const builtin = @import("builtin");
const f = @import("music").LiveSemanticFormat;
const integrity = f.IntegrityHash;
const Sha256 = f.IntegrityHasher;
const StandardSha256 = std.crypto.hash.sha2.Sha256;
const t = std.testing;

fn digest(comptime Hasher: type, bytes: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    Hasher.hash(bytes, &out, .{});
    return out;
}

fn expectHex(expected: []const u8, actual: [32]u8) !void {
    const hex = std.fmt.bytesToHex(actual, .lower);
    try t.expectEqualStrings(expected, &hex);
}

test "integrity SHA256 actual isolated backend ABI and safe compilation mode" {
    const info = integrity.backendInfo();
    try t.expectEqual(std.builtin.OptimizeMode.ReleaseSafe, integrity.backendMode());
    try t.expectEqual(@as(u32, @intFromEnum(std.builtin.OptimizeMode.ReleaseSafe)), info.mode);
    try t.expect(info.state_size > 0 and info.state_alignment > 0);
    try t.expect(info.standard_state_size > 0 and info.standard_state_alignment > 0);
    try t.expect(info.state_s_offset < info.state_buf_offset);
    try t.expect(info.state_buf_offset < info.state_buf_len_offset);
    try t.expect(info.state_buf_len_offset < info.state_total_len_offset);
    std.debug.print("INTEGRITY_HASH_ABI version={d} backend_mode={s} state_bytes={d} state_alignment={d} official_state_bytes={d} official_state_alignment={d} signature={d}\n", .{ info.abi_version, @tagName(integrity.backendMode()), info.state_size, info.state_alignment, info.standard_state_size, info.standard_state_alignment, info.abi_signature });
}

test "integrity SHA256 known vectors and inherited compilation mode" {
    try t.expectEqual(builtin.mode, integrity.compilation_mode);
    try t.expectEqual(@as(usize, 64), Sha256.block_length);
    try t.expectEqual(@as(usize, 32), Sha256.digest_length);
    try expectHex("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", digest(Sha256, ""));
    try expectHex("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", digest(Sha256, "abc"));
    try expectHex("cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1", digest(Sha256, "abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu"));

    const million_a = try t.allocator.alloc(u8, 1_000_000);
    defer t.allocator.free(million_a);
    @memset(million_a, 'a');
    try expectHex("cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0", digest(Sha256, million_a));
}

test "integrity SHA256 comptime known vectors use official std fallback" {
    // The facade preserves compile-time evaluation through official std.
    const empty = comptime blk: {
        @setEvalBranchQuota(100_000);
        break :blk digest(Sha256, "");
    };
    const abc = comptime blk: {
        @setEvalBranchQuota(100_000);
        break :blk digest(Sha256, "abc");
    };
    try expectHex("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", empty);
    try expectHex("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", abc);
    const split_abc = comptime blk: {
        @setEvalBranchQuota(100_000);
        var h = Sha256.init(.{});
        h.update("a");
        var copy = h;
        copy.update("bc");
        break :blk copy.finalResult();
    };
    try t.expectEqualSlices(u8, &abc, &split_abc);
    var preinitialized = comptime blk: {
        var h = Sha256.init(.{});
        h.update("a");
        break :blk h;
    };
    preinitialized.update("bc");
    try t.expectEqualSlices(u8, &abc, &preinitialized.finalResult());
}

test "integrity SHA256 standard differential boundaries unaligned splits copies and peek" {
    var storage: [1041]u8 align(16) = undefined;
    for (&storage, 0..) |*byte, i| byte.* = @truncate((i *% 73) ^ (i >> 3) ^ 0xa5);
    const lengths = [_]usize{ 0, 1, 55, 56, 63, 64, 65, 127, 128, 129, 1024 };
    const split_points = [_]usize{ 0, 1, 2, 7, 31, 54, 55, 56, 57, 63, 64, 65, 66, 127, 128, 129, 1024 };
    // The nonzero offsets deliberately avoid 16-byte and 4-byte alignment.
    for ([_]usize{ 0, 1, 7 }) |offset| {
        for (lengths) |len| {
            const bytes = storage[offset..][0..len];
            const expected = digest(StandardSha256, bytes);
            try t.expectEqualSlices(u8, &expected, &digest(Sha256, bytes));

            for (split_points) |split| {
                if (split > len) continue;
                var h = Sha256.init(.{});
                h.update("");
                h.update(bytes[0..split]);
                h.update("");
                h.update(bytes[split..]);
                h.update("");
                try t.expectEqualSlices(u8, &expected, &h.finalResult());
            }

            var incremental = Sha256.init(.{});
            for (bytes) |byte| incremental.update(&.{byte});
            try t.expectEqualSlices(u8, &expected, &incremental.finalResult());

            const midpoint = len / 2;
            var original = Sha256.init(.{});
            original.update(bytes[0..midpoint]);
            var clone = original;
            const prefix_expected = digest(StandardSha256, bytes[0..midpoint]);
            try t.expectEqualSlices(u8, &prefix_expected, &original.peek());
            try t.expectEqualSlices(u8, &prefix_expected, &original.peek());
            try t.expectEqualSlices(u8, &prefix_expected, &clone.peek());
            original.update(bytes[midpoint..]);
            for (bytes[midpoint..]) |byte| clone.update(&.{byte});
            try t.expectEqualSlices(u8, &expected, &original.finalResult());
            try t.expectEqualSlices(u8, &expected, &clone.finalResult());
        }
    }
}

fn fixedStreamingDigest(comptime Hasher: type, bytes: []const u8) [32]u8 {
    var h = Hasher.init(.{});
    var offset: usize = 0;
    while (offset < bytes.len) {
        const end = @min(offset + 64, bytes.len);
        h.update(bytes[offset..end]);
        offset = end;
    }
    return h.finalResult();
}

fn elapsedNs(start: std.Io.Timestamp, end: std.Io.Timestamp) !u64 {
    const ns = start.durationTo(end).nanoseconds;
    if (ns <= 0 or ns > std.math.maxInt(u64)) return error.IntegrityHashClockUnavailable;
    return @intCast(ns);
}

test "integrity SHA256 fixed one batch offline throughput comparison" {
    const bytes = try t.allocator.alloc(u8, 1024 * 1024);
    defer t.allocator.free(bytes);
    for (bytes, 0..) |*byte, i| byte.* = @truncate((i *% 131) ^ (i >> 7) ^ 0x5a);
    const x86_sha = switch (builtin.cpu.arch) {
        .x86_64, .x86 => builtin.cpu.has(.x86, .sha),
        else => false,
    };
    const x86_avx2 = switch (builtin.cpu.arch) {
        .x86_64, .x86 => builtin.cpu.has(.x86, .avx2),
        else => false,
    };
    const arm_sha2 = switch (builtin.cpu.arch) {
        .aarch64 => builtin.cpu.has(.aarch64, .sha2),
        else => false,
    };
    const sha_ni_eligible = builtin.cpu.arch == .x86_64 and builtin.zig_backend != .stage2_c and x86_sha and x86_avx2;
    const arm_sha2_eligible = builtin.cpu.arch == .aarch64 and builtin.zig_backend != .stage2_c and arm_sha2;
    try t.expectEqual(builtin.mode, integrity.compilation_mode);
    std.debug.print("INTEGRITY_HASH_CONFIG schema=1 bytes={d} batches=1 order=standard,candidate retries=0 caller_mode={s} frontend_mode={s} backend_mode={s} caller_arch={s} caller_backend={s} caller_x86_sha={} caller_x86_avx2={} caller_arm_sha2={} caller_sha_ni_eligible={} caller_arm_sha2_eligible={} runtime_safety_override=false native_capture=false performance_floor=false hybrid_build=true\n", .{ bytes.len, @tagName(builtin.mode), @tagName(integrity.compilation_mode), @tagName(integrity.backendMode()), @tagName(builtin.cpu.arch), @tagName(builtin.zig_backend), x86_sha, x86_avx2, arm_sha2, sha_ni_eligible, arm_sha2_eligible });

    // One fixed batch per implementation. Setup, allocation and printing are
    // outside both intervals; no warmup, retry, performance gate or best-of-N.
    var baseline: [32]u8 = undefined;
    const baseline_start = std.Io.Clock.awake.now(t.io);
    StandardSha256.hash(bytes, &baseline, .{});
    const baseline_ns = try elapsedNs(baseline_start, std.Io.Clock.awake.now(t.io));
    var candidate: [32]u8 = undefined;
    const candidate_start = std.Io.Clock.awake.now(t.io);
    Sha256.hash(bytes, &candidate, .{});
    const candidate_ns = try elapsedNs(candidate_start, std.Io.Clock.awake.now(t.io));
    try t.expectEqualSlices(u8, &baseline, &candidate);
    const baseline_bytes_per_second = @as(f64, @floatFromInt(bytes.len)) * std.time.ns_per_s / @as(f64, @floatFromInt(baseline_ns));
    const candidate_bytes_per_second = @as(f64, @floatFromInt(bytes.len)) * std.time.ns_per_s / @as(f64, @floatFromInt(candidate_ns));
    const hex = std.fmt.bytesToHex(candidate, .lower);
    std.debug.print("INTEGRITY_HASH_RESULT schema=1 bytes={d} batches=1 standard_wall_ns={d} candidate_wall_ns={d} standard_bytes_per_second={d} candidate_bytes_per_second={d} digest_match=true sha256={s}\n", .{ bytes.len, baseline_ns, candidate_ns, baseline_bytes_per_second, candidate_bytes_per_second, hex });
    const stream_baseline_start = std.Io.Clock.awake.now(t.io);
    const stream_baseline = fixedStreamingDigest(StandardSha256, bytes);
    const stream_baseline_ns = try elapsedNs(stream_baseline_start, std.Io.Clock.awake.now(t.io));
    const stream_candidate_start = std.Io.Clock.awake.now(t.io);
    const stream_candidate = fixedStreamingDigest(Sha256, bytes);
    const stream_candidate_ns = try elapsedNs(stream_candidate_start, std.Io.Clock.awake.now(t.io));
    try t.expectEqualSlices(u8, &baseline, &stream_baseline);
    try t.expectEqualSlices(u8, &baseline, &stream_candidate);
    std.debug.print("INTEGRITY_STREAM_RESULT schema=1 bytes={d} chunk_bytes=64 batches=1 order=standard,candidate retries=0 standard_wall_ns={d} candidate_wall_ns={d} digest_match=true sha256={s}\n", .{ bytes.len, stream_baseline_ns, stream_candidate_ns, hex });
}
