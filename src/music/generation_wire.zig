//! Internal explicit little-endian scalar encoding shared by TASK-016 values.
const std = @import("std");
pub const Hash = [32]u8;
pub const Error = error{ InvalidLength, InvalidMagic, UnknownVersion, NonCanonicalEncoding, HashMismatch, BufferTooSmall };
pub const hash_offset: usize = 48;
pub const header_bytes: usize = 80;

pub fn put(bytes: []u8, offset: usize, value: anytype) void {
    const T = @TypeOf(value);
    std.mem.writeInt(T, bytes[offset..][0..@sizeOf(T)], value, .little);
}
pub fn get(bytes: []const u8, offset: usize, comptime T: type) T {
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .little);
}
pub fn digest(bytes: []const u8) Hash {
    std.debug.assert(bytes.len >= header_bytes);
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(bytes[0..hash_offset]);
    h.update(&@as(Hash, @splat(0)));
    h.update(bytes[hash_offset + 32 ..]);
    var out: Hash = undefined;
    h.final(&out);
    return out;
}
pub fn finish(bytes: []u8) void {
    @memcpy(bytes[hash_offset..][0..32], &digest(bytes));
}
pub fn check(bytes: []const u8, magic: *const [8]u8, maximum: usize) Error!void {
    if (bytes.len < header_bytes or bytes.len > maximum) return error.InvalidLength;
    if (!std.mem.eql(u8, bytes[0..8], magic)) return error.InvalidMagic;
    if (get(bytes, 8, u16) != 1) return error.UnknownVersion;
    if (get(bytes, 12, u32) != bytes.len) return error.InvalidLength;
    if (!std.mem.eql(u8, bytes[hash_offset..][0..32], &digest(bytes))) return error.HashMismatch;
}
