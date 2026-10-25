//! Narrow ReleaseSafe compilation unit for official std SHA-256 only.
//! No vendored algorithm, allocation, clock, lock, or mutable global state.
//! The build embeds this object's code into its ordinary-mode consumers.

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("live_integrity_hash_abi.zig");
const StandardSha256 = std.crypto.hash.sha2.Sha256;

comptime {
    if (builtin.mode != .ReleaseSafe)
        @compileError("the integrity SHA-256 backend must be compiled independently in ReleaseSafe");
    if (StandardSha256.block_length != 64 or StandardSha256.digest_length != 32 or
        @typeInfo(StandardSha256).@"struct".fields.len != 4 or
        @TypeOf(@as(StandardSha256, undefined).s) != [8]u32 or
        @TypeOf(@as(StandardSha256, undefined).buf) != [64]u8 or
        @TypeOf(@as(StandardSha256, undefined).buf_len) != u8 or
        @TypeOf(@as(StandardSha256, undefined).total_len) != u64 or
        @typeInfo(StandardSha256.Options).@"struct".fields.len != 0)
        @compileError("official std SHA-256 logical state changed; review the integrity ABI bridge");
}

fn requireAbi(signature: u64) void {
    // Explicit failure, not an assertion that disappears in another mode.
    // This precedes every state access, including a state's first runtime use
    // after a comptime initializer. There is no separate metadata round trip.
    if (signature != abi.signature) @panic("integrity SHA-256 backend ABI mismatch");
}

fn inputBytes(data: ?[*]const u8, length: usize) []const u8 {
    if (length == 0) return "";
    return (data orelse @panic("null integrity SHA-256 input with nonzero length"))[0..length];
}

fn load(state: *const abi.State) StandardSha256 {
    return .{
        .s = state.s,
        .buf = state.buf,
        .buf_len = state.buf_len,
        .total_len = state.total_len,
    };
}

fn store(state: *abi.State, value: StandardSha256) void {
    state.* = .{
        .s = value.s,
        .buf = value.buf,
        .buf_len = value.buf_len,
        .total_len = value.total_len,
    };
}

export fn sme_live_integrity_sha256_v1_info() abi.BackendInfo {
    return .{
        .abi_version = abi.version,
        .mode = @intFromEnum(builtin.mode),
        .state_size = @sizeOf(abi.State),
        .state_alignment = @alignOf(abi.State),
        .standard_state_size = @sizeOf(StandardSha256),
        .standard_state_alignment = @alignOf(StandardSha256),
        .state_s_offset = @offsetOf(abi.State, "s"),
        .state_buf_offset = @offsetOf(abi.State, "buf"),
        .state_buf_len_offset = @offsetOf(abi.State, "buf_len"),
        .state_total_len_offset = @offsetOf(abi.State, "total_len"),
        .abi_signature = abi.signature,
    };
}

export fn sme_live_integrity_sha256_v1_init(signature: u64, state: *abi.State) void {
    requireAbi(signature);
    var value = StandardSha256.init(.{});
    // The official initializer leaves inactive buffer bytes undefined. Give
    // the bridge a defined, copyable value without changing digest semantics.
    value.buf = @splat(0);
    store(state, value);
}

export fn sme_live_integrity_sha256_v1_update(signature: u64, state: *abi.State, data: ?[*]const u8, length: usize) void {
    requireAbi(signature);
    var value = load(state);
    value.update(inputBytes(data, length));
    store(state, value);
}

export fn sme_live_integrity_sha256_v1_final(signature: u64, state: *abi.State, out: *[32]u8) void {
    requireAbi(signature);
    var value = load(state);
    var result: [32]u8 = undefined;
    value.final(&result);
    store(state, value);
    out.* = result;
}

export fn sme_live_integrity_sha256_v1_hash(signature: u64, data: ?[*]const u8, length: usize, out: *[32]u8) void {
    requireAbi(signature);
    StandardSha256.hash(inputBytes(data, length), out, .{});
}
