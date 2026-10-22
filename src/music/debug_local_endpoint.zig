//! Opt-in Linux adopted-AF_UNIX provider. No listener, socket path, permissions,
//! process creation or TCP fallback. Host tool thread only; never Control/Render.
const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
pub const bridge = @import("debug_bridge.zig");
pub const wire = @import("debug_wire_v1.zig");
const observer = bridge.observer;

pub const Limits = struct {
    handshake_ms: u32 = 2000,
    partial_request_ms: u32 = 1000,
    write_ms: u32 = 1000,
    idle_ms: u32 = 5000,
    bytes_per_step: u32 = 4096,
    pub fn validate(self: Limits) !void {
        if (self.handshake_ms == 0 or self.partial_request_ms == 0 or self.write_ms == 0 or self.idle_ms == 0 or
            self.bytes_per_step == 0 or self.bytes_per_step > 4096) return error.InvalidCapacity;
    }
};
pub const Ownership = struct {
    /// Caller promises exclusive ownership of both the descriptor and its open
    /// file description for the entire session. dup/fork aliases cannot be
    /// detected or revoked by UID checks. False rejects without changing fd.
    exclusive_description: bool,
};
pub const Close = enum { peer_eof, peer_bye, protocol, handshake_timeout, partial_request_timeout, write_timeout, idle_timeout, clock_regressed, io_failure, runtime_closed, host_closed };
pub const Step = enum { no_peer, would_block, receiving, response_queued, writing, response_sent, disconnected };
const Peer = extern struct { pid: i32, uid: u32, gid: u32 };

fn option(comptime T: type, fd: i32, name: u32) !T {
    var value: T = undefined;
    var length: linux.socklen_t = @sizeOf(T);
    const result = linux.getsockopt(fd, linux.SOL.SOCKET, name, std.mem.asBytes(&value).ptr, &length);
    if (linux.errno(result) != .SUCCESS or length != @sizeOf(T)) return error.InvalidLocalSocket;
    return value;
}
/// Only read-only socket metadata is queried. Rejected adoption leaves the fd,
/// O_NONBLOCK/CLOEXEC flags and file description under unchanged caller control.
fn checkConnected(fd: i32, ownership: Ownership) !void {
    if (comptime builtin.os.tag != .linux) return error.UnsupportedPlatform;
    if (!ownership.exclusive_description) return error.ExclusiveOwnershipRequired;
    if (fd < 0) return error.InvalidLocalSocket;
    if (try option(i32, fd, linux.SO.DOMAIN) != linux.AF.UNIX) return error.NotLocalSocket;
    if (try option(i32, fd, linux.SO.TYPE) != linux.SOCK.STREAM) return error.NotStreamSocket;
    var address: linux.sockaddr.storage = undefined;
    var address_length: linux.socklen_t = @sizeOf(@TypeOf(address));
    const connected = linux.getpeername(fd, @ptrCast(&address), &address_length);
    if (linux.errno(connected) != .SUCCESS or address_length < @sizeOf(linux.sa_family_t) or address.family != linux.AF.UNIX) return error.NotConnected;
    const peer = try option(Peer, fd, linux.SO.PEERCRED);
    if (peer.pid <= 0 or peer.uid != linux.geteuid()) return error.PeerNotAuthorized;
}

/// Owns the existing bounded host bridge plus fixed RX/TX buffers. Control first
/// subscribes storage(), then the host calls adoptSubscription. A client session
/// never owns the runtime subscription or controls any resource-return credit.
/// Unique, host-serialized object. Destruction requires runtime publisher detach;
/// a disconnected client does not force runtime teardown or hide that obligation.
pub const Provider = struct {
    allocator: std.mem.Allocator,
    host: *bridge.Host,
    limits: Limits,
    fd: ?i32,
    nonce: wire.Nonce,
    hello_received: bool,
    request_sequence: u64,
    rx: [wire.max_request_bytes]u8,
    rx_count: usize,
    expected_request_bytes: usize,
    tx: [wire.max_response_bytes]u8,
    tx_count: usize,
    tx_offset: usize,
    tx_is_frame: bool,
    close_after_send: ?Close,
    last_close: ?Close,
    transport_dropped_frames: u64,
    transport_loss_exhausted: bool,
    session_started_ms: u64,
    partial_started_ms: u64,
    tx_started_ms: u64,
    last_activity_ms: u64,
    last_clock_ms: u64,

    pub fn requiredBytes() !usize { return std.math.add(usize, @sizeOf(Provider), try bridge.Host.requiredBytes()); }
    pub fn create(allocator: std.mem.Allocator, max_owned_bytes: usize, limits: Limits) !*Provider {
        try limits.validate();
        if (max_owned_bytes < try requiredBytes()) return error.ObserverBudgetExceeded;
        const host = try bridge.Host.create(allocator, try bridge.Host.requiredBytes());
        errdefer host.destroy() catch unreachable;
        const self = try allocator.create(Provider);
        @memset(std.mem.asBytes(self), 0);
        self.allocator = allocator;
        self.host = host;
        self.limits = limits;
        self.fd = null;
        self.close_after_send = null;
        self.last_close = null;
        self.expected_request_bytes = wire.prefix_bytes;
        return self;
    }
    pub fn storage(self: *Provider) *observer.Storage { return self.host.storage; }
    pub fn adoptSubscription(self: *Provider, handle: observer.Handle) !void { try self.host.adopt(handle); }
    /// Success transfers exclusive ownership exactly once. All rejection and
    /// nonce-generation paths precede the ownership assignment. No fd flags are
    /// changed: every send/recv explicitly uses MSG_DONTWAIT (and NOSIGNAL send).
    pub fn adoptConnectedFd(self: *Provider, fd: i32, ownership: Ownership, now_ms: u64) !void {
        if (comptime builtin.os.tag != .linux) return error.UnsupportedPlatform;
        if (self.fd != null) return error.PeerAlreadyAttached;
        if (self.host.subscription == null) return error.StaleObserver;
        if (self.transport_loss_exhausted) return error.TransportCounterExhausted;
        try checkConnected(fd, ownership);
        var nonce: wire.Nonce = undefined;
        // Linux GRND_NONBLOCK: never wait for entropy on the provider thread.
        const got = linux.getrandom(&nonce, nonce.len, 0x0001);
        if (linux.errno(got) != .SUCCESS or got != nonce.len or std.mem.eql(u8, &nonce, &wire.zero_nonce)) return error.SessionNonceUnavailable;
        self.fd = fd; // Ownership transfer; every preceding failure is read-only.
        self.nonce = nonce;
        self.hello_received = false;
        self.request_sequence = 0;
        self.rx_count = 0;
        self.expected_request_bytes = wire.prefix_bytes;
        self.tx_count = 0;
        self.tx_offset = 0;
        self.tx_is_frame = false;
        self.close_after_send = null;
        self.last_close = null;
        self.session_started_ms = now_ms;
        self.partial_started_ms = now_ms;
        self.tx_started_ms = now_ms;
        self.last_activity_ms = now_ms;
        self.last_clock_ms = now_ms;
    }
    fn accountLostFrame(self: *Provider) void {
        if (!self.tx_is_frame) return;
        if (self.transport_dropped_frames == std.math.maxInt(u64)) self.transport_loss_exhausted = true else self.transport_dropped_frames += 1;
    }
    fn disconnect(self: *Provider, reason: Close) void {
        if (self.fd) |fd| {
            self.accountLostFrame();
            // Linux close is attempted once. Retrying EINTR could close a reused
            // descriptor; exclusive ownership ends at this single close attempt.
            _ = linux.close(fd);
        }
        self.fd = null;
        self.rx_count = 0;
        self.expected_request_bytes = wire.prefix_bytes;
        self.tx_count = 0;
        self.tx_offset = 0;
        self.tx_is_frame = false;
        self.close_after_send = null;
        self.last_close = reason;
    }
    pub fn closePeer(self: *Provider) void { self.disconnect(.host_closed); }
    pub fn destroy(self: *Provider) !void {
        // Fail without changing the live peer if the real publisher still owns
        // storage. Caller must perform the existing guarded Control detach.
        if (self.storage().usage().publisher_attached) return error.ObserverInUse;
        self.closePeer();
        try self.host.destroy();
        self.allocator.destroy(self);
    }
    fn queue(self: *Provider, kind: wire.Kind, sequence: u64, payload_bytes: usize, now_ms: u64) !void {
        try wire.encodeEnvelope(&self.tx, .{ .kind = kind, .payload_bytes = @intCast(payload_bytes), .request_sequence = sequence, .nonce = self.nonce });
        self.tx_count = wire.prefix_bytes + payload_bytes;
        self.tx_offset = 0;
        self.tx_started_ms = now_ms;
        self.tx_is_frame = kind == .frame;
    }
    fn reject(self: *Provider, envelope: wire.Envelope, reason: wire.Reject, now_ms: u64) !void {
        var encoder: @import("sme-trace").codec.Encoder = .{ .bytes = self.tx[wire.prefix_bytes..] };
        try encoder.put(@intFromEnum(reason));
        try self.queue(.rejected, envelope.request_sequence, encoder.offset, now_ms);
        self.close_after_send = .protocol;
    }
    fn request(self: *Provider, envelope: wire.Envelope, now_ms: u64) !void {
        const payload = self.rx[wire.prefix_bytes..self.rx_count];
        if (self.request_sequence == std.math.maxInt(u64) or envelope.request_sequence != self.request_sequence + 1) return self.reject(envelope, .order, now_ms);
        if (!self.hello_received) {
            if (envelope.kind != .hello or !std.mem.eql(u8, &envelope.nonce, &wire.zero_nonce)) return self.reject(envelope, .unsupported_request, now_ms);
            const hello = try wire.decodeHello(payload);
            if (wire.validateHello(hello)) |reason| return self.reject(envelope, reason, now_ms);
            const bytes = try wire.encodeWelcome(self.tx[wire.prefix_bytes..], .{
                .protocol_minor = wire.minor, .observer_version = observer.version, .trace_version = @import("sme-trace").schema.version,
                .max_response_bytes = wire.max_response_bytes, .supported_sections = wire.supported_sections,
                .subscription = self.host.subscription.?, .transport_dropped_frames = self.transport_dropped_frames,
            });
            try self.queue(.welcome, envelope.request_sequence, bytes, now_ms);
            self.hello_received = true;
        } else {
            if (!std.mem.eql(u8, &envelope.nonce, &self.nonce)) return self.reject(envelope, .nonce, now_ms);
            if (payload.len != 0) return error.InvalidLength;
            switch (envelope.kind) {
                .poll => switch (try self.host.poll()) {
                    .empty => try self.queue(.empty, envelope.request_sequence, 0, now_ms),
                    .frame => {
                        self.tx_is_frame = true; // Count a failed encode as an unsent copied frame.
                        // At most one observer copy per request. Slow writes hold
                        // only this host buffer; Control may drop its debug queue.
                        const bytes = try wire.encodeFrame(self.tx[wire.prefix_bytes..], &self.host.frame, self.transport_dropped_frames);
                        try self.queue(.frame, envelope.request_sequence, bytes, now_ms);
                    },
                    .closed => |footer| {
                        const bytes = try wire.encodeFooter(self.tx[wire.prefix_bytes..], footer, self.transport_dropped_frames);
                        try self.queue(.closed, envelope.request_sequence, bytes, now_ms);
                        self.close_after_send = .runtime_closed;
                    },
                },
                .bye => {
                    try self.queue(.bye_ack, envelope.request_sequence, 0, now_ms);
                    self.close_after_send = .peer_bye;
                },
                else => return self.reject(envelope, .unsupported_request, now_ms),
            }
        }
        self.request_sequence = envelope.request_sequence;
    }
    /// One bounded nonblocking send OR recv syscall, and at most one request/
    /// observer poll per call. Host supplies a monotonic millisecond clock. All
    /// deadlines are absolute per operation, so trickled bytes cannot extend them.
    pub fn step(self: *Provider, now_ms: u64) !Step {
        if (comptime builtin.os.tag != .linux) return error.UnsupportedPlatform;
        const fd = self.fd orelse return .no_peer;
        if (now_ms < self.last_clock_ms) { self.disconnect(.clock_regressed); return error.ClockRegressed; }
        self.last_clock_ms = now_ms;
        if (!self.hello_received and now_ms - self.session_started_ms >= self.limits.handshake_ms) { self.disconnect(.handshake_timeout); return .disconnected; }
        if (self.tx_count != 0) {
            if (now_ms - self.tx_started_ms >= self.limits.write_ms) { self.disconnect(.write_timeout); return .disconnected; }
            const count = @min(self.tx_count - self.tx_offset, self.limits.bytes_per_step);
            const sent = linux.sendto(fd, self.tx[self.tx_offset..].ptr, count, linux.MSG.DONTWAIT | linux.MSG.NOSIGNAL, null, 0);
            switch (linux.errno(sent)) {
                .AGAIN, .INTR => return .would_block,
                .SUCCESS => {},
                else => { self.disconnect(.io_failure); return .disconnected; },
            }
            if (sent == 0) { self.disconnect(.io_failure); return .disconnected; }
            self.tx_offset += sent;
            if (self.tx_offset != self.tx_count) return .writing;
            self.tx_count = 0;
            self.tx_offset = 0;
            self.tx_is_frame = false;
            self.last_activity_ms = now_ms;
            if (self.close_after_send) |reason| { self.disconnect(reason); return .disconnected; }
            return .response_sent;
        }
        if (self.rx_count > 0 and now_ms - self.partial_started_ms >= self.limits.partial_request_ms) { self.disconnect(.partial_request_timeout); return .disconnected; }
        if (self.rx_count == 0 and now_ms - self.last_activity_ms >= self.limits.idle_ms) { self.disconnect(.idle_timeout); return .disconnected; }
        const count = @min(self.expected_request_bytes - self.rx_count, self.limits.bytes_per_step);
        const received = linux.recvfrom(fd, self.rx[self.rx_count..].ptr, count, linux.MSG.DONTWAIT, null, null);
        switch (linux.errno(received)) {
            .AGAIN, .INTR => return .would_block,
            .SUCCESS => {},
            else => { self.disconnect(.io_failure); return .disconnected; },
        }
        if (received == 0) { self.disconnect(.peer_eof); return .disconnected; }
        if (self.rx_count == 0) self.partial_started_ms = now_ms;
        self.rx_count += received;
        if (self.rx_count < wire.prefix_bytes) return .receiving;
        const envelope = wire.decodeEnvelope(self.rx[0..wire.prefix_bytes], wire.max_request_bytes) catch |err| {
            self.disconnect(.protocol);
            return err;
        };
        self.expected_request_bytes = wire.prefix_bytes + envelope.payload_bytes;
        if (self.rx_count != self.expected_request_bytes) return .receiving;
        self.request(envelope, now_ms) catch |err| {
            self.disconnect(.protocol);
            return err;
        };
        self.rx_count = 0;
        self.expected_request_bytes = wire.prefix_bytes;
        self.last_activity_ms = now_ms;
        return .response_queued;
    }
};
