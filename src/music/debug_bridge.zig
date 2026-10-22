//! Opt-in, in-process host bridge for RuntimeObserverV1. It owns storage and a
//! bounded copied output, never a MusicRuntime/Render/resource pointer. No socket
//! listener is enabled by importing this module. Network framing, remote access,
//! timeout handling and GPU panels remain separate, unimplemented endpoint gates.
const std = @import("std");
pub const observer = @import("runtime_observer.zig");
pub const Handshake = struct {
    protocol_major: u16 = 1,
    protocol_minor: u16 = 0,
    observer_version: u16 = observer.version,
    max_owned_frame_bytes: usize = @sizeOf(observer.Frame),
    publication_capacity: usize = observer.publication_capacity,
    records_per_publication: usize = observer.record_capacity,
    sections: observer.Sections = .{},
    transport: enum { in_process_owned_copy } = .in_process_owned_copy,
};
pub const Requirements = struct {
    protocol_major: u16 = 1,
    observer_version: u16 = 1,
    max_owned_frame_bytes: usize = @sizeOf(observer.Frame),
    sections: observer.Sections = .{},
};
pub fn negotiate(request: Requirements) !Handshake {
    const response: Handshake = .{};
    if (request.protocol_major != response.protocol_major) return error.ProtocolVersionMismatch;
    if (request.observer_version != response.observer_version) return error.SnapshotVersionMismatch;
    if (request.max_owned_frame_bytes < response.max_owned_frame_bytes) return error.MessageTooLarge;
    inline for (std.meta.fields(observer.Sections)) |field| {
        if (@field(request.sections, field.name) and !@field(response.sections, field.name)) return error.UnsupportedCapability;
    }
    return response;
}

/// Unique host owner; allocate before MusicRuntime.subscribeObserverV1(storage),
/// then adopt its returned handle. After runtime detach/destruction, drain until
/// Closed, stop the reader, and destroy. Calls on this object are host-serialized;
/// the publisher may run concurrently on its own Control thread.
pub const Host = struct {
    allocator: std.mem.Allocator,
    storage: *observer.Storage,
    subscription: ?observer.Handle,
    frame: observer.Frame,
    last_sequence: u64,
    skipped_publications: u64,
    saw_debug_loss: bool,
    footer: ?observer.Footer,

    pub fn requiredBytes() !usize {
        return std.math.add(usize, @sizeOf(Host), observer.Storage.requiredBytes());
    }
    pub fn create(allocator: std.mem.Allocator, max_owned_bytes: usize) !*Host {
        const required = try requiredBytes();
        if (max_owned_bytes < required) return error.ObserverBudgetExceeded;
        const storage = try observer.Storage.create(allocator, observer.Storage.requiredBytes());
        errdefer storage.destroy() catch unreachable;
        const self = try allocator.create(Host);
        // No by-value maximal host/frame construction on the caller stack.
        @memset(std.mem.asBytes(self), 0);
        self.allocator = allocator;
        self.storage = storage;
        self.subscription = null;
        self.footer = null;
        for (&self.frame.records) |*row| row.* = null;
        return self;
    }
    pub fn adopt(self: *Host, handle: observer.Handle) !void {
        if (self.subscription != null) return error.ObserverAlreadyAttached;
        if (!std.meta.eql(handle, self.storage.handle) or !self.storage.reader_attached.load(.acquire)) return error.StaleObserver;
        self.subscription = handle;
        self.last_sequence = 0;
        self.skipped_publications = 0;
        self.saw_debug_loss = false;
        self.footer = null;
    }
    pub fn poll(self: *Host) !observer.Poll {
        const handle = self.subscription orelse return error.StaleObserver;
        const result = try self.storage.poll(handle, &self.frame);
        switch (result) {
            .frame => {
                const header = self.frame.header;
                if (header.version != observer.version or header.owned_value_bytes != @sizeOf(observer.Frame)) return error.SnapshotVersionMismatch;
                if (!std.meta.eql(header.subscription, handle)) return error.StaleObserver;
                if (header.sequence <= self.last_sequence or header.record_count > observer.record_capacity) return error.InvalidOrder;
                self.skipped_publications +|= header.sequence - self.last_sequence - 1;
                self.saw_debug_loss = self.saw_debug_loss or header.loss.incomplete() or self.skipped_publications != 0;
                self.last_sequence = header.sequence;
            },
            .closed => |footer| {
                if (footer.attempted_publications < self.last_sequence) return error.InvalidOrder;
                if (self.footer == null) self.skipped_publications +|= footer.attempted_publications - self.last_sequence;
                self.footer = footer;
                self.saw_debug_loss = self.saw_debug_loss or footer.loss.incomplete() or self.skipped_publications != 0;
            },
            .empty => {},
        }
        return result;
    }
    /// Stop/join reader calls before disconnect. The runtime publisher remains
    /// attached until its Control owner detaches or destroys it.
    pub fn disconnect(self: *Host) !void {
        const handle = self.subscription orelse return error.StaleObserver;
        try self.storage.releaseReader(handle);
        self.subscription = null;
    }
    pub fn destroy(self: *Host) !void {
        if (self.storage.publisher_attached.load(.acquire)) return error.ObserverInUse;
        if (self.subscription != null) try self.disconnect();
        try self.storage.destroy();
        const allocator = self.allocator;
        allocator.destroy(self);
    }
};
