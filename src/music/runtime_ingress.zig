//! Bounded MPSC resident intent admission and reserved lossless host receipts.
//! No producer reads bank/Director/PCM memory. Both lanes share one ticket
//! allocator; Control consumes exactly the next published ticket.
const std = @import("std");
const c = @import("contract.zig");
const v1 = @import("runtime_contract.zig");
const limits: v1.CapacityV1 = .{};
pub const Stage = enum { claimed, numbered, published };
pub const Hook = struct { context: *anyopaque, call: *const fn (*anyopaque, Stage, c.MusicRequestPayload) void };
pub const Command = union(enum) { music: c.MusicRequestPayload, restore: u64, reload: u64 };
pub const Item = struct { ticket: v1.RequestTicketV1, command: Command };
pub const Ingress = struct {
    const Cell = struct { state: std.atomic.Value(u8), value: Item };
    cells: [limits.request_slots]Cell,
    normal_hint: std.atomic.Value(u64),
    reserved_hint: std.atomic.Value(u64),
    next_ticket: std.atomic.Value(u64),
    occupied: std.atomic.Value(u32),
    credits: std.atomic.Value(u32),
    receipts: [limits.receipt_slots]v1.ReceiptV1,
    receipt_head: std.atomic.Value(u64),
    receipt_tail: std.atomic.Value(u64),
    next_control: u64,
    test_hook: if (@import("builtin").is_test) ?Hook else void,

    pub fn init(self: *Ingress) void {
        for (&self.cells) |*cell| cell.state = .init(0);
        self.normal_hint = .init(0);
        self.reserved_hint = .init(0);
        self.next_ticket = .init(1);
        self.occupied = .init(0);
        self.credits = .init(limits.receipt_slots);
        self.receipt_head = .init(0);
        self.receipt_tail = .init(0);
        self.next_control = 1;
        if (@import("builtin").is_test) self.test_hook = null;
    }
    fn hook(self: *Ingress, stage: Stage, payload: c.MusicRequestPayload) void {
        if (@import("builtin").is_test) if (self.test_hook) |h| h.call(h.context, stage, payload);
    }
    pub fn push(self: *Ingress, bank: v1.BankRefV1, payload: c.MusicRequestPayload) !v1.RequestTicketV1 {
        return self.pushCommand(bank, .{ .music = payload });
    }
    /// Restore shares the exact same cell, sequence and two receipt credits.
    /// It is a distinct operation, never a synthetic Director music request.
    pub fn pushRestore(self: *Ingress, bank: v1.BankRefV1, incarnation: u64) !v1.RequestTicketV1 {
        return self.pushCommand(bank, .{ .restore = incarnation });
    }
    /// Reload and rollback use the same total order and two real receipt credits.
    pub fn pushReload(self: *Ingress, bank: v1.BankRefV1, incarnation: u64) !v1.RequestTicketV1 {
        return self.pushCommand(bank, .{ .reload = incarnation });
    }
    fn pushCommand(self: *Ingress, bank: v1.BankRefV1, command: Command) !v1.RequestTicketV1 {
        const reserved = command == .music and (command.music == .pause or command.music == .stop);
        const normal_count = limits.request_slots - limits.reserved_request_slots;
        const first: usize = if (reserved) normal_count else 0;
        const count: usize = if (reserved) limits.reserved_request_slots else normal_count;
        const hint = if (reserved) &self.reserved_hint else &self.normal_hint;
        const begin = hint.fetchAdd(1, .monotonic) % count;
        for (0..count) |offset| {
            const cell = &self.cells[first + (begin + offset) % count];
            if (cell.state.cmpxchgStrong(0, 1, .acquire, .monotonic) != null) continue;
            _ = self.occupied.fetchAdd(1, .monotonic);
            errdefer {
                _ = self.occupied.fetchSub(1, .monotonic);
                cell.state.store(0, .release);
            }
            if (command == .music) self.hook(.claimed, command.music);
            const floor: u32 = if (reserved) 0 else limits.reserved_request_slots * 2;
            var available = self.credits.load(.acquire);
            var credited = false;
            for (0..64) |_| {
                if (available < floor + 2) break;
                available = self.credits.cmpxchgStrong(available, available - 2, .acq_rel, .acquire) orelse {
                    credited = true;
                    break;
                };
            }
            if (!credited) return error.CommandQueueFull;
            errdefer _ = self.credits.fetchAdd(2, .release);
            var next = self.next_ticket.load(.acquire);
            var assigned: ?u64 = null;
            for (0..64) |_| {
                if (next == std.math.maxInt(u64)) return error.TicketExhausted;
                next = self.next_ticket.cmpxchgStrong(next, next + 1, .acq_rel, .acquire) orelse {
                    assigned = next;
                    break;
                };
            }
            const id = assigned orelse return error.CommandQueueFull;
            const ticket: v1.RequestTicketV1 = .{ .context = bank.context, .request_id = id, .bank = bank };
            cell.value = .{ .ticket = ticket, .command = command };
            if (command == .music) self.hook(.numbered, command.music);
            cell.state.store(2, .release);
            if (command == .music) self.hook(.published, command.music);
            return ticket;
        }
        return error.CommandQueueFull;
    }
    pub fn pop(self: *Ingress) ?Item {
        for (&self.cells) |*cell| {
            if (cell.state.load(.acquire) != 2) continue;
            if (cell.value.ticket.request_id != self.next_control) continue;
            const item = cell.value;
            self.next_control += 1;
            _ = self.occupied.fetchSub(1, .monotonic);
            cell.state.store(0, .release);
            return item;
        }
        return null;
    }
    /// Exactly two records per accepted item: accepted and one terminal. The
    /// admission credit proof makes failure impossible, even with no polling.
    pub fn emit(self: *Ingress, value: v1.ReceiptV1) void {
        const head = self.receipt_head.load(.monotonic);
        std.debug.assert(head -% self.receipt_tail.load(.acquire) < limits.receipt_slots);
        self.receipts[head % limits.receipt_slots] = value;
        self.receipt_head.store(head +% 1, .release);
    }
    pub fn poll(self: *Ingress) ?v1.ReceiptV1 {
        const tail = self.receipt_tail.load(.monotonic);
        if (tail == self.receipt_head.load(.acquire)) return null;
        const value = self.receipts[tail % limits.receipt_slots];
        self.receipt_tail.store(tail +% 1, .release);
        _ = self.credits.fetchAdd(1, .release);
        return value;
    }
};
