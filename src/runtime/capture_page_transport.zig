//! Internal bounded SPSC encoded-page handoff. This is not a recording format.
//!
//! One assembler owns reserve/writable/commit/seal/publishTerminal/handoff. One
//! writer owns tryLease/bytes/terminalValue/release. Neither side waits, retries,
//! allocates, performs IO, or calls a runtime owner. The filling and leased pages
//! count among the SAME four cells. Payloads are release-published and remain
//! immutable until the writer release-publishes their reclamation.
//!
//! Construct Pool as .{} at its final address, initialize before starting either
//! role, and never copy it. Returned writable spans expire at commit/cancellation;
//! returned read-only spans expire at release. The caller must not retain them.
//! All errors must feed the caller's shared sticky capture-failed policy. In
//! particular a PoolFull diagnostic prefix is never a successful recording.
//!
//! A .complete terminal and completion() establish ONLY structural transport
//! completion. They cannot certify causal completeness, confirmed/durable writes,
//! or absence of a late IO failure. A terminal may be visible before the explicit
//! producer handoff. Nothing here can replace the real writer return and join.
//! Host lifecycle exclusion is required for markWriterJoined and retire, and the
//! host retains every borrowed allocation/handle until the actual join.
const std = @import("std");

pub const data_cell_count: usize = 4;
pub const page_bytes: usize = 64 * 1024;
pub const data_bytes: usize = data_cell_count * page_bytes;
pub const Error = error{
    InvalidState,
    InvalidIdentity,
    ConcurrentInitialization,
    CounterOverflow,
    InvalidRecordSize,
    RecordTooLarge,
    PoolFull,
    ReservationOutstanding,
    StaleReservation,
    PartialCommit,
    ProducerClosed,
    ProducerOpen,
    LeaseOutstanding,
    StaleLease,
    InvalidOrdinal,
    InvalidTerminal,
    InUse,
    WriterNotJoined,
};
pub const Kind = enum(u8) { data, terminal };
pub const Outcome = enum(u8) { complete, failed };
const Lifecycle = enum(u8) { uninitialized, active, retired };
const CellState = enum(u8) { free, filling, ready, leased };
const TerminalState = enum(u8) { empty, ready, leased, released };
var next_pool_generation: std.atomic.Value(u64) = .init(1);

/// Process-local capability, never a serialized address or persistence record.
pub const Reservation = struct {
    pool_address: usize,
    pool_generation: u64,
    capture_incarnation: u64,
    cell_index: usize,
    cell_generation: u64,
    ordinal: u64,
    reservation_generation: u64,
    offset: usize,
    length: usize,
};

/// Exactly one outstanding lease is allowed, including the reserved terminal.
pub const Lease = struct {
    pool_address: usize,
    pool_generation: u64,
    capture_incarnation: u64,
    kind: Kind,
    cell_index: usize,
    cell_generation: u64,
    ordinal: u64,
};

/// An immutable structural declaration, not evidence that writes succeeded.
/// Failure reason is an opaque caller-owned nonzero code; complete uses zero.
pub const Terminal = struct {
    capture_incarnation: u64,
    outcome: Outcome,
    reason: u32,
    page_count: u64,
    byte_count: u64,
    record_count: u64,
};

const Cell = struct {
    state: std.atomic.Value(CellState) = .init(.free),
    // Producer owns these while free/filling. Consumer owns them while leased.
    // The opposite role reads them only after the corresponding acquire edge.
    generation: u64 = 0,
    ordinal: u64 = 0,
    used: usize = 0,
    payload: [page_bytes]u8 = undefined,
};

pub const Pool = struct {
    lifecycle: std.atomic.Value(Lifecycle) = .init(.uninitialized),
    bound_address: usize = 0,
    pool_generation: u64 = 0,
    capture_incarnation: u64 = 0,
    cells: [data_cell_count]Cell = .{ .{}, .{}, .{}, .{} },
    terminal_state: std.atomic.Value(TerminalState) = .init(.empty),
    terminal: Terminal = undefined,
    producer_closed: std.atomic.Value(bool) = .init(false),
    high_water_cells: std.atomic.Value(usize) = .init(0),

    // Assembler-only; observers and the writer must not read these live.
    producer_active: ?usize = null,
    producer_pending: ?Reservation = null,
    producer_next_page: u64 = 0,
    producer_next_reservation: u64 = 1,
    producer_bytes: u64 = 0,
    producer_records: u64 = 0,
    producer_terminal_staged: bool = false,

    // Writer-only until actual join. No producer or live observer reads these.
    consumer_lease: ?Lease = null,
    consumer_next_page: u64 = 0,
    consumer_terminal_done: bool = false,

    // Host-only; actual join and exclusion of both roles are prerequisites.
    writer_joined: bool = false,

    /// Initialize FRESH undefined storage without constructing/copying a Pool.
    /// Equivalent to .{} for metadata only; payloads remain undefined. Host-only,
    /// before initInPlace and before any pointer/capability escapes. NEVER use this
    /// to reset/reuse a live pool or to bypass its one-shot lifecycle checks.
    pub fn initStorageInPlace(self: *Pool) void {
        self.lifecycle = .init(.uninitialized);
        self.bound_address = 0;
        self.pool_generation = 0;
        self.capture_incarnation = 0;
        for (&self.cells) |*cell| {
            cell.state = .init(.free);
            cell.generation = 0;
            cell.ordinal = 0;
            cell.used = 0;
        }
        self.terminal_state = .init(.empty);
        self.producer_closed = .init(false);
        self.high_water_cells = .init(0);
        self.producer_active = null;
        self.producer_pending = null;
        self.producer_next_page = 0;
        self.producer_next_reservation = 1;
        self.producer_bytes = 0;
        self.producer_records = 0;
        self.producer_terminal_staged = false;
        self.consumer_lease = null;
        self.consumer_next_page = 0;
        self.consumer_terminal_done = false;
        self.writer_joined = false;
    }

    /// One-shot initialization of a default-initialized, address-pinned Pool.
    /// No by-value Pool temporary, payload clearing, allocation or retry.
    pub fn initInPlace(self: *Pool, capture_incarnation: u64) Error!void {
        if (self.lifecycle.load(.acquire) != .uninitialized) return error.InvalidState;
        if (capture_incarnation == 0) return error.InvalidIdentity;
        const generation = next_pool_generation.load(.monotonic);
        if (generation == std.math.maxInt(u64)) return error.CounterOverflow;
        if (next_pool_generation.cmpxchgStrong(generation, generation + 1, .monotonic, .monotonic) != null)
            return error.ConcurrentInitialization;
        self.bound_address = @intFromPtr(self);
        self.pool_generation = generation;
        self.capture_incarnation = capture_incarnation;
        self.lifecycle.store(.active, .release);
    }

    pub fn requiredBytes() usize {
        return @sizeOf(Pool);
    }

    /// Producer-only. Size must be the exact canonical encoded record length.
    /// A record is never split. If necessary, publish the current page first.
    /// PoolFull leaves every ready/leased page untouched, and is nonblocking.
    pub fn reserveRecord(self: *Pool, length: usize) Error!Reservation {
        try self.checkProducer();
        if (length == 0) return error.InvalidRecordSize;
        if (length > page_bytes) return error.RecordTooLarge;
        if (self.producer_pending != null) return error.ReservationOutstanding;
        if (self.producer_next_reservation == std.math.maxInt(u64)) return error.CounterOverflow;
        _ = std.math.add(u64, self.producer_bytes, @intCast(length)) catch return error.CounterOverflow;
        _ = std.math.add(u64, self.producer_records, 1) catch return error.CounterOverflow;
        if (self.producer_active) |index| {
            if (length > page_bytes - self.cells[index].used) try self.sealActive();
        }
        if (self.producer_active == null) {
            // Reserve the representable final ordinal for the terminal.
            if (self.producer_next_page == std.math.maxInt(u64)) return error.CounterOverflow;
            const index: usize = @intCast(self.producer_next_page % data_cell_count);
            const cell = &self.cells[index];
            if (cell.state.load(.acquire) != .free) return error.PoolFull;
            if (cell.generation == std.math.maxInt(u64)) return error.CounterOverflow;
            cell.generation += 1;
            cell.ordinal = self.producer_next_page;
            cell.used = 0;
            cell.state.store(.filling, .release);
            self.producer_active = index;
            self.observeHighWater();
        }
        const index = self.producer_active.?;
        const cell = &self.cells[index];
        const reservation: Reservation = .{
            .pool_address = self.bound_address,
            .pool_generation = self.pool_generation,
            .capture_incarnation = self.capture_incarnation,
            .cell_index = index,
            .cell_generation = cell.generation,
            .ordinal = cell.ordinal,
            .reservation_generation = self.producer_next_reservation,
            .offset = cell.used,
            .length = length,
        };
        self.producer_next_reservation += 1;
        self.producer_pending = reservation;
        return reservation;
    }

    /// Producer-only. The mutable span is borrowed only until commit or failure
    /// publication. Calling this again validates the exact current reservation.
    pub fn writable(self: *Pool, reservation: Reservation) Error![]u8 {
        const cell = try self.reservedCell(reservation);
        return cell.payload[reservation.offset..][0..reservation.length];
    }

    /// Reject partial, oversized, duplicate and stale commits without publishing
    /// the pending tail. Failure-terminal publication can discard that tail.
    pub fn commitRecord(self: *Pool, reservation: Reservation, actual_length: usize) Error!void {
        const cell = try self.reservedCell(reservation);
        if (actual_length != reservation.length) return error.PartialCommit;
        const byte_count = std.math.add(u64, self.producer_bytes, @intCast(actual_length)) catch return error.CounterOverflow;
        const record_count = std.math.add(u64, self.producer_records, 1) catch return error.CounterOverflow;
        cell.used += actual_length;
        self.producer_bytes = byte_count;
        self.producer_records = record_count;
        self.producer_pending = null;
    }

    /// Producer-only. Empty seals do nothing; outstanding reservations reject.
    pub fn seal(self: *Pool) Error!void {
        try self.checkProducer();
        try self.sealActive();
    }

    /// Producer-only. Fixed reserved storage guarantees a finite failed terminal
    /// even with all four data cells occupied. No new records are accepted after
    /// either outcome is staged. A failed outcome discards ONLY an uncommitted
    /// tail, invalidates its reservation, and publishes any committed prefix.
    pub fn publishTerminal(self: *Pool, outcome: Outcome, reason: u32) Error!void {
        try self.checkProducer();
        if ((outcome == .complete and reason != 0) or (outcome == .failed and reason == 0))
            return error.InvalidTerminal;
        if (self.producer_pending != null) {
            if (outcome == .complete) return error.ReservationOutstanding;
            self.producer_pending = null;
        }
        try self.sealActive();
        self.terminal = .{
            .capture_incarnation = self.capture_incarnation,
            .outcome = outcome,
            .reason = reason,
            .page_count = self.producer_next_page,
            .byte_count = self.producer_bytes,
            .record_count = self.producer_records,
        };
        self.producer_terminal_staged = true;
        self.terminal_state.store(.ready, .release);
    }

    /// Explicit final assembler handoff. This is NOT runtime producer closure or
    /// a writer join. The host must establish both under its own lifecycle.
    pub fn producerHandoff(self: *Pool) Error!void {
        try self.checkBound();
        if (self.producer_closed.load(.acquire)) return error.ProducerClosed;
        if (!self.producer_terminal_staged or self.producer_pending != null or self.producer_active != null)
            return error.InvalidState;
        self.producer_closed.store(true, .release);
    }

    /// Safe immutable observation by either role or the host. A visible terminal
    /// can precede producerHandoff and is not permission to release resources.
    pub fn terminalSnapshot(self: *const Pool) Error!?Terminal {
        try self.checkBound();
        if (self.terminal_state.load(.acquire) == .empty) return null;
        return self.terminal;
    }

    pub fn producerClosed(self: *const Pool) bool {
        return self.producer_closed.load(.acquire);
    }

    /// Maximum observed occupancy from bounded per-cell atomic samples, not a
    /// coherent instantaneous high-water measurement. The structural bound is
    /// always exactly four; simultaneous held-writer tests can establish four.
    pub fn maximumCellsInUse(self: *const Pool) usize {
        return self.high_water_cells.load(.acquire);
    }

    /// Writer-only, fixed work. A terminal may be leased before producer handoff,
    /// but never before ALL data leases have been released in ordinal order.
    pub fn tryLease(self: *Pool) Error!?Lease {
        try self.checkBound();
        if (self.consumer_lease != null) return error.LeaseOutstanding;
        if (self.consumer_terminal_done) return null;
        // Acquire the terminal before sampling its preceding data publication.
        // Otherwise a just-published terminal could follow an earlier empty-cell
        // sample and spuriously look as though a data ordinal were missing.
        const terminal_state = self.terminal_state.load(.acquire);
        const index: usize = @intCast(self.consumer_next_page % data_cell_count);
        const cell = &self.cells[index];
        if (cell.state.load(.acquire) == .ready) {
            if (cell.ordinal != self.consumer_next_page) return error.InvalidOrdinal;
            const lease: Lease = .{
                .pool_address = self.bound_address,
                .pool_generation = self.pool_generation,
                .capture_incarnation = self.capture_incarnation,
                .kind = .data,
                .cell_index = index,
                .cell_generation = cell.generation,
                .ordinal = cell.ordinal,
            };
            self.consumer_lease = lease;
            cell.state.store(.leased, .release);
            return lease;
        }
        if (terminal_state != .ready) return null;
        if (self.terminal.page_count != self.consumer_next_page) return error.InvalidOrdinal;
        const lease: Lease = .{
            .pool_address = self.bound_address,
            .pool_generation = self.pool_generation,
            .capture_incarnation = self.capture_incarnation,
            .kind = .terminal,
            .cell_index = data_cell_count,
            .cell_generation = 1,
            .ordinal = self.terminal.page_count,
        };
        self.consumer_lease = lease;
        self.terminal_state.store(.leased, .release);
        return lease;
    }

    /// Writer-only. The returned immutable span expires on release(lease).
    pub fn bytes(self: *Pool, lease: Lease) Error![]const u8 {
        try self.validateLease(lease);
        if (lease.kind != .data) return error.StaleLease;
        const cell = &self.cells[lease.cell_index];
        return cell.payload[0..cell.used];
    }

    pub fn terminalValue(self: *Pool, lease: Lease) Error!Terminal {
        try self.validateLease(lease);
        if (lease.kind != .terminal) return error.StaleLease;
        return self.terminal;
    }

    /// Writer-only. Validation occurs before reading metadata that could already
    /// belong to the producer again. A duplicate/stale ack cannot free a new page.
    pub fn release(self: *Pool, lease: Lease) Error!void {
        try self.validateLease(lease);
        switch (lease.kind) {
            .data => {
                const next = std.math.add(u64, self.consumer_next_page, 1) catch return error.CounterOverflow;
                self.consumer_next_page = next;
                self.consumer_lease = null;
                self.cells[lease.cell_index].state.store(.free, .release);
            },
            .terminal => {
                self.consumer_terminal_done = true;
                self.consumer_lease = null;
                self.terminal_state.store(.released, .release);
            },
        }
    }

    /// Structural result only; callers must also consult their sticky failure,
    /// causal validation and confirmed-write results, including late IO errors.
    pub fn completion(self: *const Pool) Error!Terminal {
        try self.checkBound();
        if (!self.producer_closed.load(.acquire)) return error.ProducerOpen;
        if (self.terminal_state.load(.acquire) != .released) return error.InUse;
        return self.terminal;
    }

    /// HOST ASSERTION: call only after the real writer return and thread.join (or
    /// a synchronous writer's final return), with both roles excluded. This flag
    /// cannot prove a join. Outstanding reservations/leases still block retire.
    /// After join the host may take over the consumer to discard diagnostic data.
    pub fn markWriterJoined(self: *Pool) Error!void {
        try self.checkBound();
        if (!self.producer_closed.load(.acquire)) return error.ProducerOpen;
        if (self.writer_joined) return error.InvalidState;
        self.writer_joined = true;
    }

    /// Host-only checked lifetime end; never frees memory itself. An early terminal
    /// or closed flag, a failed writer, or a timeout cannot satisfy these checks.
    pub fn retire(self: *Pool) Error!void {
        try self.checkBound();
        if (!self.producer_closed.load(.acquire)) return error.ProducerOpen;
        if (!self.writer_joined) return error.WriterNotJoined;
        if (self.producer_active != null or self.producer_pending != null or self.consumer_lease != null)
            return error.InUse;
        if (self.terminal_state.load(.acquire) != .released) return error.InUse;
        for (&self.cells) |*cell| {
            if (cell.state.load(.acquire) != .free) return error.InUse;
        }
        self.lifecycle.store(.retired, .release);
    }

    fn checkBound(self: *const Pool) Error!void {
        if (self.lifecycle.load(.acquire) != .active or self.bound_address != @intFromPtr(self))
            return error.InvalidState;
    }

    fn checkProducer(self: *Pool) Error!void {
        try self.checkBound();
        if (self.producer_terminal_staged or self.producer_closed.load(.acquire)) return error.ProducerClosed;
    }

    fn reservedCell(self: *Pool, reservation: Reservation) Error!*Cell {
        try self.checkBound();
        const pending = self.producer_pending orelse return error.StaleReservation;
        if (!std.meta.eql(pending, reservation)) return error.StaleReservation;
        if (self.producer_terminal_staged or self.producer_closed.load(.acquire)) return error.StaleReservation;
        const index = self.producer_active orelse return error.StaleReservation;
        if (index != reservation.cell_index or index >= data_cell_count) return error.StaleReservation;
        const cell = &self.cells[index];
        if (cell.state.load(.acquire) != .filling or cell.generation != reservation.cell_generation or
            cell.ordinal != reservation.ordinal or cell.used != reservation.offset)
            return error.StaleReservation;
        return cell;
    }

    fn sealActive(self: *Pool) Error!void {
        if (self.producer_pending != null) return error.ReservationOutstanding;
        const index = self.producer_active orelse return;
        const cell = &self.cells[index];
        if (cell.used == 0) {
            self.producer_active = null;
            cell.state.store(.free, .release);
            return;
        }
        const next = std.math.add(u64, self.producer_next_page, 1) catch return error.CounterOverflow;
        self.producer_next_page = next;
        self.producer_active = null;
        cell.state.store(.ready, .release);
    }

    fn validateLease(self: *Pool, lease: Lease) Error!void {
        try self.checkBound();
        const current = self.consumer_lease orelse return error.StaleLease;
        if (!std.meta.eql(current, lease)) return error.StaleLease;
        switch (lease.kind) {
            .data => {
                if (lease.cell_index >= data_cell_count) return error.StaleLease;
                const cell = &self.cells[lease.cell_index];
                if (cell.state.load(.acquire) != .leased or cell.generation != lease.cell_generation or cell.ordinal != lease.ordinal)
                    return error.StaleLease;
            },
            .terminal => {
                if (self.terminal_state.load(.acquire) != .leased) return error.StaleLease;
            },
        }
    }

    fn observeHighWater(self: *Pool) void {
        var count: usize = 0;
        for (&self.cells) |*cell| {
            if (cell.state.load(.acquire) != .free) count += 1;
        }
        // Only the producer increases occupancy or writes this high-water mark.
        // Concurrent reclamation may lower this sample, never exceed the pool.
        if (count > self.high_water_cells.load(.monotonic)) self.high_water_cells.store(count, .release);
    }
};
