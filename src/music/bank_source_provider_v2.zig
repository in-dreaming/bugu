//! Real bank-backed V2 byte provider. Owns validated original encoded resources;
//! it implements no fake PCM, codec, readiness, stream or activation result.
const std = @import("std");
const bank = @import("sme-bank");
const protocol = @import("source_provider.zig");
pub const max_sources = 48;
pub const Fault = struct {
    fail_bind_call: ?usize = null,
    fail_open_call: ?usize = null,
    fail_close_call: ?usize = null,
    fail_unbind_call: ?usize = null,
};
pub const Counts = struct { bind_attempts: usize = 0, binds: usize = 0, open_attempts: usize = 0, opened: usize = 0, read_attempts: usize = 0, close_attempts: usize = 0, closed: usize = 0, unbind_attempts: usize = 0, unbound: usize = 0, live: usize = 0 };
pub const Provider = struct {
    // The sole Worker mutates binding/token/count state. Host inspection and
    // destruction require callback quiescence; runtime users additionally wait
    // for the acquired source-retirement acknowledgement, not these counters.
    allocator: std.mem.Allocator,
    loaded: bank.MusicBank,
    sounds: [max_sources]u32 = undefined,
    stream_count: usize = 0,
    open_tokens: [max_sources]bool = @splat(false),
    ever_opened: [max_sources]bool = @splat(false),
    binding: ?protocol.BoundV2 = null,
    bound_context: ?u64 = null,
    high_water: u64 = 0,
    incarnation: u64 = 0,
    counts: Counts = .{},
    fault: Fault = .{},
    pub fn create(allocator: std.mem.Allocator, compiled: []const u8, fault: Fault) !*Provider {
        var loaded = try bank.MusicBank.load(allocator, compiled);
        errdefer loaded.deinit();
        // Resource authentication stays independent of the runtime policy
        // profile. A graph-bearing bank retains its actual owned graph storage;
        // only MusicRuntime decides whether that policy profile is supported.
        const self = try allocator.create(Provider);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .loaded = loaded, .fault = fault };
        for (loaded.tables.sounds, 0..) |sound, i| if (sound.storage == .streaming) {
            if (self.stream_count == max_sources) return error.ResourceLimitExceeded;
            self.sounds[self.stream_count] = @intCast(i);
            self.stream_count += 1;
        };
        return self;
    }
    pub fn provider(self: *Provider) protocol.V2 {
        return .{ .context = self, .bind = bind, .open = open, .read_at = read, .close = close, .unbind = unbind };
    }
    /// Host-owned storage is reported separately; it is not implicitly folded
    /// into MusicRuntime's ledger for arbitrary externally borrowed providers.
    pub fn retainedBytes(self: *const Provider) !u64 {
        var bytes: u64 = @sizeOf(Provider);
        inline for (std.meta.fields(bank.schema.Tables)) |field| {
            const rows = @field(self.loaded.tables, field.name);
            bytes = try std.math.add(u64, bytes, try std.math.mul(u64, rows.len, @sizeOf(std.meta.Elem(@TypeOf(rows)))));
        }
        if (self.loaded.bus_graph) |graph| bytes = try std.math.add(u64, bytes, try graph.backingAllocationBytes());
        return bytes;
    }
    pub fn destroy(self: *Provider) !void {
        if (self.binding != null or self.counts.live != 0) return error.DrainPending;
        self.loaded.deinit();
        self.allocator.destroy(self);
    }
    fn bind(raw: *anyopaque, identity: protocol.IdentityV2) protocol.V2.Error!protocol.TokenV2 {
        const self: *Provider = @ptrCast(@alignCast(raw));
        self.counts.bind_attempts += 1;
        try identity.validate();
        if (self.binding != null) return error.BindingBusy;
        if (!std.mem.eql(u8, &identity.bank_hash, &self.loaded.content_hash) or identity.authored_generation != self.loaded.metadata.generation) return error.InvalidBinding;
        if (self.bound_context) |context| if (context != identity.context) return error.InvalidBinding;
        if (identity.runtime_generation <= self.high_water) return error.InvalidBinding;
        if (self.incarnation == std.math.maxInt(u64)) return error.IdentityExhausted;
        if (self.fault.fail_bind_call == self.counts.bind_attempts) return error.SourceUnavailable;
        self.incarnation += 1;
        const token: protocol.TokenV2 = .{ .context = identity.context, .runtime_generation = identity.runtime_generation, .incarnation = self.incarnation };
        self.binding = .{ .provider = self.provider(), .identity = identity, .token = token };
        self.bound_context = identity.context;
        self.high_water = identity.runtime_generation;
        self.ever_opened = @splat(false);
        std.debug.assert(self.counts.live == 0 and std.mem.allEqual(bool, &self.open_tokens, false));
        self.counts.binds += 1;
        return token;
    }
    fn require(self: *Provider, token: protocol.TokenV2) protocol.V2.Error!void {
        const current = self.binding orelse return error.InvalidBinding;
        if (!std.meta.eql(current.token, token)) return error.InvalidBinding;
    }
    fn open(raw: *anyopaque, binding: protocol.TokenV2, request: protocol.V2.Request) protocol.V2.Error!protocol.V2.Opened {
        const self: *Provider = @ptrCast(@alignCast(raw));
        try self.require(binding);
        self.counts.open_attempts += 1;
        if (self.fault.fail_open_call == self.counts.open_attempts) return error.SourceUnavailable;
        for (self.sounds[0..self.stream_count], 0..) |sound_index, index| {
            const sound = self.loaded.tables.sounds[sound_index];
            if (sound.key.id != request.sound_id) continue;
            if (self.ever_opened[index] or request.encoded_bytes != sound.blob_length or !std.mem.eql(u8, &request.encoded_hash, &sound.audio_hash)) return error.InvalidSource;
            self.ever_opened[index] = true;
            self.open_tokens[index] = true;
            self.counts.opened += 1;
            self.counts.live += 1;
            return .{ .token = index + 1, .encoded_bytes = sound.blob_length };
        }
        return error.SourceUnavailable;
    }
    fn indexFor(self: *Provider, binding: protocol.TokenV2, token: u64) protocol.V2.Error!usize {
        try self.require(binding);
        if (token == 0 or token > self.stream_count) return error.InvalidSource;
        const index: usize = @intCast(token - 1);
        if (!self.open_tokens[index]) return error.InvalidSource;
        return index;
    }
    fn read(raw: *anyopaque, binding: protocol.TokenV2, token: u64, offset: u64, destination: []u8) protocol.V2.Error!void {
        const self: *Provider = @ptrCast(@alignCast(raw));
        const index = try self.indexFor(binding, token);
        self.counts.read_attempts += 1;
        const sound = self.loaded.tables.sounds[self.sounds[index]];
        if (offset > sound.blob_length or destination.len > sound.blob_length - offset) return error.InvalidSource;
        const start = std.math.add(u64, sound.blob_offset, offset) catch return error.InvalidSource;
        if (start > self.loaded.tables.blob.len or destination.len > self.loaded.tables.blob.len - start) return error.InvalidSource;
        @memcpy(destination, self.loaded.tables.blob[@intCast(start)..][0..destination.len]);
    }
    fn close(raw: *anyopaque, binding: protocol.TokenV2, token: u64) protocol.V2.Error!void {
        const self: *Provider = @ptrCast(@alignCast(raw));
        const index = try self.indexFor(binding, token);
        self.counts.close_attempts += 1;
        if (self.fault.fail_close_call == self.counts.close_attempts) return error.SourceCloseFailed;
        self.open_tokens[index] = false;
        self.counts.closed += 1;
        self.counts.live -= 1;
    }
    fn unbind(raw: *anyopaque, binding: protocol.TokenV2) protocol.V2.Error!void {
        const self: *Provider = @ptrCast(@alignCast(raw));
        try self.require(binding);
        if (self.counts.live != 0) return error.BindingBusy;
        self.counts.unbind_attempts += 1;
        if (self.fault.fail_unbind_call == self.counts.unbind_attempts) return error.SourceCloseFailed;
        self.binding = null;
        self.counts.unbound += 1;
    }
};
