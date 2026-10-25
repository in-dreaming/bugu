//! Standalone downstream archive consumer, not imported by the engine graph.
//! Its only linked implementation is the already built production archive.
const std = @import("std");
const builtin = @import("builtin");
const abi = @import("integrity_abi");
extern fn sme_live_integrity_sha256_v1_info() abi.BackendInfo;
extern fn sme_live_integrity_sha256_v1_hash(signature: u64, data: ?[*]const u8, length: usize, out: *[32]u8) void;

test "production archive independently supplies official safe SHA backend" {
    const info = sme_live_integrity_sha256_v1_info();
    try std.testing.expectEqual(abi.signature, info.abi_signature);
    try std.testing.expectEqual(@as(u32, @intFromEnum(std.builtin.OptimizeMode.ReleaseSafe)), info.mode);
    var digest: [32]u8 = undefined;
    sme_live_integrity_sha256_v1_hash(abi.signature, "abc".ptr, 3, &digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    try std.testing.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", &hex);
    std.debug.print("INTEGRITY_ARCHIVE_CONSUMER caller_mode={s} backend_mode=ReleaseSafe digest_match=true abi_match=true\n", .{@tagName(builtin.mode)});
}
