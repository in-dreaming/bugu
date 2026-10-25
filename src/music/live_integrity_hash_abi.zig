//! Private C ABI for the isolated official-standard-library SHA-256 backend.
//! This is a logical state bridge, not a serialized hash state or wire format.
//! Neither side depends on the automatic layout of std.crypto.hash.sha2.Sha256.

pub const version: u32 = 1;

pub const State = extern struct {
    s: [8]u32,
    buf: [64]u8,
    buf_len: u8,
    total_len: u64,
};

pub const BackendInfo = extern struct {
    abi_version: u32,
    mode: u32,
    state_size: u32,
    state_alignment: u32,
    standard_state_size: u32,
    standard_state_alignment: u32,
    state_s_offset: u32,
    state_buf_offset: u32,
    state_buf_len_offset: u32,
    state_total_len_offset: u32,
    abi_signature: u64,
};

// Each component occupies one whole byte, so this identity has no hash
// collisions. Refuse future layouts that would truncate a component. Both
// compilation units evaluate this from their own target's extern layout.
comptime {
    for (.{
        version,
        @sizeOf(State),
        @alignOf(State),
        @offsetOf(State, "s"),
        @offsetOf(State, "buf"),
        @offsetOf(State, "buf_len"),
        @offsetOf(State, "total_len"),
    }) |component| {
        if (component > 255) @compileError("integrity SHA-256 ABI identity component exceeds one byte");
    }
}

pub const signature: u64 =
    (@as(u64, 0x53) << 56) |
    (@as(u64, version) << 48) |
    (@as(u64, @sizeOf(State)) << 40) |
    (@as(u64, @alignOf(State)) << 32) |
    (@as(u64, @offsetOf(State, "s")) << 24) |
    (@as(u64, @offsetOf(State, "buf")) << 16) |
    (@as(u64, @offsetOf(State, "buf_len")) << 8) |
    @as(u64, @offsetOf(State, "total_len"));
