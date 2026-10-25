//! Profile 9 integrity hashing through an isolated official std SHA-256 unit.
//! This facade keeps its importing module's mode and safety checks. Only the
//! four hash operations cross into the separately compiled ReleaseSafe object.
//! The private ABI copies logical fields, never casts std's automatic layout.

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("live_integrity_hash_abi.zig");
const StandardSha256 = std.crypto.hash.sha2.Sha256;

pub const compilation_mode = builtin.mode;
pub const BackendInfo = abi.BackendInfo;

extern fn sme_live_integrity_sha256_v1_info() abi.BackendInfo;
extern fn sme_live_integrity_sha256_v1_init(signature: u64, state: *abi.State) void;
extern fn sme_live_integrity_sha256_v1_update(signature: u64, state: *abi.State, data: ?[*]const u8, length: usize) void;
extern fn sme_live_integrity_sha256_v1_final(signature: u64, state: *abi.State, out: *[32]u8) void;
extern fn sme_live_integrity_sha256_v1_hash(signature: u64, data: ?[*]const u8, length: usize, out: *[32]u8) void;

comptime {
    if (StandardSha256.block_length != 64 or StandardSha256.digest_length != 32 or
        @typeInfo(StandardSha256).@"struct".fields.len != 4 or
        @TypeOf(@as(StandardSha256, undefined).s) != [8]u32 or
        @TypeOf(@as(StandardSha256, undefined).buf) != [64]u8 or
        @TypeOf(@as(StandardSha256, undefined).buf_len) != u8 or
        @TypeOf(@as(StandardSha256, undefined).total_len) != u64 or
        @typeInfo(StandardSha256.Options).@"struct".fields.len != 0)
        @compileError("official std SHA-256 logical state changed; review the integrity ABI bridge");
}

/// Actual linked-backend evidence, not an assumed optimization-mode constant.
/// Both this check and the per-operation backend ABI check fail in every mode.
pub fn backendInfo() BackendInfo {
    const info = sme_live_integrity_sha256_v1_info();
    if (info.abi_version != abi.version or info.abi_signature != abi.signature or
        info.state_size != @sizeOf(abi.State) or info.state_alignment != @alignOf(abi.State) or
        info.state_s_offset != @offsetOf(abi.State, "s") or
        info.state_buf_offset != @offsetOf(abi.State, "buf") or
        info.state_buf_len_offset != @offsetOf(abi.State, "buf_len") or
        info.state_total_len_offset != @offsetOf(abi.State, "total_len") or
        info.mode != @intFromEnum(std.builtin.OptimizeMode.ReleaseSafe))
        @panic("integrity SHA-256 backend metadata mismatch");
    return info;
}

pub fn backendMode() std.builtin.OptimizeMode {
    return @enumFromInt(backendInfo().mode);
}

pub const Sha256 = struct {
    const Self = @This();
    pub const block_length = StandardSha256.block_length;
    pub const digest_length = StandardSha256.digest_length;
    pub const Options = StandardSha256.Options;

    state: abi.State,

    pub fn init(options: Options) Self {
        if (@inComptime()) {
            var value = StandardSha256.init(options);
            value.buf = @splat(0);
            return .{ .state = fromStandard(value) };
        }
        var result: Self = undefined;
        sme_live_integrity_sha256_v1_init(abi.signature, &result.state);
        return result;
    }

    pub fn hash(bytes: []const u8, out: *[digest_length]u8, options: Options) void {
        if (@inComptime()) return StandardSha256.hash(bytes, out, options);
        sme_live_integrity_sha256_v1_hash(abi.signature, inputPointer(bytes), bytes.len, out);
    }

    pub fn update(self: *Self, bytes: []const u8) void {
        if (@inComptime()) {
            var value = self.toStandard();
            value.update(bytes);
            self.state = fromStandard(value);
            return;
        }
        sme_live_integrity_sha256_v1_update(abi.signature, &self.state, inputPointer(bytes), bytes.len);
    }

    pub fn final(self: *Self, out: *[digest_length]u8) void {
        if (@inComptime()) {
            var value = self.toStandard();
            var result: [digest_length]u8 = undefined;
            value.final(&result);
            self.state = fromStandard(value);
            out.* = result;
            return;
        }
        sme_live_integrity_sha256_v1_final(abi.signature, &self.state, out);
    }

    pub fn finalResult(self: *Self) [digest_length]u8 {
        var result: [digest_length]u8 = undefined;
        self.final(&result);
        return result;
    }

    pub fn peek(self: Self) [digest_length]u8 {
        var copy = self;
        return copy.finalResult();
    }

    fn toStandard(self: Self) StandardSha256 {
        return .{
            .s = self.state.s,
            .buf = self.state.buf,
            .buf_len = self.state.buf_len,
            .total_len = self.state.total_len,
        };
    }

    fn fromStandard(value: StandardSha256) abi.State {
        return .{
            .s = value.s,
            .buf = value.buf,
            .buf_len = value.buf_len,
            .total_len = value.total_len,
        };
    }
};

fn inputPointer(bytes: []const u8) ?[*]const u8 {
    // A zero-length Zig slice need not designate readable storage. Do not
    // construct a nonempty C input or dereference its pointer for empty input.
    return if (bytes.len == 0) null else bytes.ptr;
}
