//! Provider identities are resource contracts, separate from Render generations.
const std = @import("std");

/// Frozen V1 meaning: asset_generation authenticates the authored bank identity.
/// Runtime job/window identity is never substituted into this request.
pub const V1 = struct {
    pub const Error = error{ SourceUnavailable, SourceReadFailed, SourceCloseFailed, InvalidSource };
    pub const Request = struct { bank_hash: [32]u8, asset_generation: u64, sound_id: u64, encoded_hash: [32]u8, encoded_bytes: u64 };
    pub const Opened = struct { token: u64, encoded_bytes: u64 };
    context: *anyopaque,
    open: *const fn (*anyopaque, Request) Error!Opened,
    read_at: *const fn (*anyopaque, u64, u64, []u8) Error!void,
    close: *const fn (*anyopaque, u64) Error!void,
};

/// Constructed by serialized Control from acquired Worker-validated content and
/// its separately reserved runtime identity, before source work is published.
pub const IdentityV2 = struct {
    version: u16 = 2,
    context: u64,
    runtime_generation: u64,
    bank_hash: [32]u8,
    authored_generation: u64,
    pub fn validate(self: IdentityV2) V2.Error!void {
        if (self.version != 2 or self.context == 0 or self.runtime_generation == 0 or self.authored_generation == 0 or std.mem.allEqual(u8, &self.bank_hash, 0)) return error.InvalidBinding;
    }
};
pub const TokenV2 = struct {
    context: u64,
    runtime_generation: u64,
    incarnation: u64,
    pub fn matches(self: TokenV2, identity: IdentityV2) bool {
        return self.context == identity.context and self.runtime_generation == identity.runtime_generation and self.incarnation != 0;
    }
};

/// Successful bind acquires provider custody. Every successful open is closed
/// exactly once before unbind; failed close/unbind retains the exact live token
/// and is retryable. All callbacks run on the sole Worker, never Render/Control.
/// Failed bind acquires no custody. Tokens are valid only for the exact provider
/// context and binding incarnation; providers must reject stale bindings.
pub const V2 = struct {
    pub const Error = V1.Error || error{ InvalidBinding, BindingBusy, IdentityExhausted };
    pub const Request = struct { sound_id: u64, encoded_hash: [32]u8, encoded_bytes: u64 };
    pub const Opened = V1.Opened;
    context: *anyopaque,
    bind: *const fn (*anyopaque, IdentityV2) Error!TokenV2,
    open: *const fn (*anyopaque, TokenV2, Request) Error!Opened,
    read_at: *const fn (*anyopaque, TokenV2, u64, u64, []u8) Error!void,
    close: *const fn (*anyopaque, TokenV2, u64) Error!void,
    unbind: *const fn (*anyopaque, TokenV2) Error!void,
};

/// Internal dispatch only. Each public version retains its own request meaning.
pub const Any = union(enum) { v1: V1, v2: V2 };
pub const BoundV2 = struct { provider: V2, identity: IdentityV2, token: TokenV2 };
