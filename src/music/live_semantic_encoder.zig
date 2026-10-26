//! Exact scalar wire encoder, isolated for ReleaseSafe compilation.
const std = @import("std");
pub const compilation_mode = @import("builtin").mode;
pub const Error = error{
    Poisoned,
    Closed,
    Overflow,
    CounterOverflow,
    InvalidOrder,
    UnsupportedFamily,
    BufferTooSmall,
    InvalidLength,
    UnsupportedProfile,
    UnsupportedVersion,
    Noncanonical,
    HashMismatch,
    WrongBuild,
    WrongBank,
    WrongConfig,
    WrongSource,
    Incomplete,
    NotDrained,
    CountMismatch,
    AlreadySealed,
    Truncated,
    TrailingBytes,
};
pub const Encoder = struct {
    bytes: []u8,
    offset: usize = 0,
    pub fn int(self: *Encoder, comptime T: type, value: T) Error!void {
        if (self.offset > self.bytes.len or self.bytes.len - self.offset < @sizeOf(T)) return error.BufferTooSmall;
        std.mem.writeInt(T, self.bytes[self.offset..][0..@sizeOf(T)], value, .little);
        self.offset += @sizeOf(T);
    }
    pub fn raw(self: *Encoder, bytes: []const u8) Error!void {
        if (self.offset > self.bytes.len or self.bytes.len - self.offset < bytes.len) return error.BufferTooSmall;
        @memcpy(self.bytes[self.offset..][0..bytes.len], bytes);
        self.offset += bytes.len;
    }
    pub fn f32Bits(self: *Encoder, bits: u32) Error!void {
        try self.int(u32, bits);
    }
    pub fn result(self: Encoder) []const u8 {
        return self.bytes[0..self.offset];
    }
};
