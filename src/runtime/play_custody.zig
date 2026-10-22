//! Fixed source-generation play envelopes. Serialized source Control funds every
//! cell before binding/exposing owners; producer and Render operations are atomic
//! and bounded. One independently incarnated role corresponds to one actual PCM
//! reference. No aggregate SampleOwner reference count manufactures a credit.
const std = @import("std");
pub const capacity = 1024;
pub const role_count = 7;
pub const max_incarnation = std.math.maxInt(u64) >> 3;
pub const Source = struct {
    context: u64,
    authored_generation: u64,
    runtime_generation: u64,
    registry_index: u8,
    registry_incarnation: u64,
    pub fn validate(self: Source) !void {
        if (self.context == 0 or self.authored_generation == 0 or self.runtime_generation == 0 or self.registry_incarnation == 0) return error.InvalidIdentity;
    }
};
pub const Destination = struct {
    control: *anyopaque,
    instance_index: u16,
    instance_generation: u16,
    reservation: u64,
};
pub const Role = enum(u3) { desired, journal, prepared_block, render, snapshot0, snapshot1, snapshot2 };
pub fn snapshotRole(index: u8) !Role {
    return switch (index) { 0 => .snapshot0, 1 => .snapshot1, 2 => .snapshot2, else => error.InvalidToken };
}
const CellPhase = enum(u3) { free, claimed, visible };
const RolePhase = enum(u3) { free, reserved, held, returning, returned };
fn word(incarnation: u64, tag: anytype) u64 { return (incarnation << 3) | @intFromEnum(tag); }
fn phase(comptime T: type, value: u64) T { return @enumFromInt(value & 7); }
fn next(value: u64) !u64 {
    if (value >= max_incarnation) return error.IdentityExhausted;
    return value + 1;
}

/// Owner must provide release(). Acquisition/pin stays at the real runtime
/// boundary: reserve, acquire the actual PCM reference, then publish. A failed
/// physical acquisition cancels only the reserved role, without releasing PCM.
pub fn Anchor(comptime Owner: type) type {
    return struct {
        const Self = @This();
        const closed: u64 = @as(u64, 1) << 63;
        const Cell = struct {
            state: std.atomic.Value(u64) = .init(0),
            roles: [role_count]std.atomic.Value(u64) = @splat(.init(0)),
            live_role_mask: std.atomic.Value(u8) = .init(0),
            // Immutable from root publication until Control acquires zero roles.
            owner: *Owner = undefined,
            destination: Destination = undefined,
        };
        source: Source,
        cells: [capacity]Cell = @splat(.{}),
        gate: std.atomic.Value(u64) = .init(0),
        hint: std.atomic.Value(usize) = .init(0),

        pub fn init(source: Source) !Self {
            try source.validate();
            return .{ .source = source };
        }
        pub const Producer = struct {
            anchor: *Self,
            /// Single-use guard. FINAL anchor access by this producer; Control
            /// cannot release closed funding while an entered producer remains.
            pub fn leave(self: Producer) void {
                const previous = self.anchor.gate.fetchSub(1, .release);
                std.debug.assert(previous & ~closed != 0);
            }
            pub fn reserve(self: Producer, owner: *Owner, destination: Destination) !Reservation {
                if (destination.reservation == 0) return error.InvalidIdentity;
                const begin = self.anchor.hint.fetchAdd(1, .monotonic) % capacity;
                for (0..capacity) |offset| {
                    const index = (begin + offset) % capacity;
                    const cell = &self.anchor.cells[index];
                    const old = cell.state.load(.acquire);
                    if (phase(CellPhase, old) != .free) continue;
                    const incarnation = next(old >> 3) catch continue;
                    if (cell.state.cmpxchgStrong(old, word(incarnation, CellPhase.claimed), .acq_rel, .acquire) != null) continue;
                    std.debug.assert(cell.live_role_mask.load(.acquire) == 0);
                    const prior = cell.roles[@intFromEnum(Role.desired)].load(.acquire);
                    const role_incarnation = next(prior >> 3) catch {
                        cell.state.store(word(incarnation, CellPhase.free), .release);
                        continue;
                    };
                    std.debug.assert(phase(RolePhase, prior) == .free or phase(RolePhase, prior) == .returned);
                    cell.owner = owner;
                    cell.destination = destination;
                    cell.roles[@intFromEnum(Role.desired)].store(word(role_incarnation, RolePhase.reserved), .monotonic);
                    cell.live_role_mask.store(1, .monotonic);
                    return .{ .token = .{ .anchor = self.anchor, .cell = @intCast(index), .cell_incarnation = incarnation, .role = .desired, .role_incarnation = role_incarnation }, .root = true };
                }
                return error.CapacityExceeded;
            }
        };
        pub fn enter(self: *Self) !Producer {
            var current = self.gate.load(.acquire);
            for (0..8) |_| {
                if (current & closed != 0) return error.AcquisitionClosed;
                if (current == closed - 1) return error.CapacityExceeded;
                current = self.gate.cmpxchgStrong(current, current + 1, .acq_rel, .acquire) orelse return .{ .anchor = self };
            }
            return error.CapacityExceeded;
        }
        /// Control closes root acquisition. Existing entered producers may still
        /// publish. Derivatives of retained roles remain legal while closing.
        pub fn close(self: *Self) void { _ = self.gate.fetchOr(closed, .acq_rel); }
        pub fn isClosed(self: *const Self) bool { return self.gate.load(.acquire) & closed != 0; }
        pub fn producerCount(self: *const Self) u64 { return self.gate.load(.acquire) & ~closed; }

        pub const Reservation = struct {
            token: Token,
            root: bool,
            pub fn publish(self: Reservation) Token {
                const cell = &self.token.anchor.cells[self.token.cell];
                const role = &cell.roles[@intFromEnum(self.token.role)];
                std.debug.assert(role.load(.acquire) == word(self.token.role_incarnation, RolePhase.reserved));
                role.store(word(self.token.role_incarnation, RolePhase.held), .release);
                if (self.root) cell.state.store(word(self.token.cell_incarnation, CellPhase.visible), .release);
                return self.token;
            }
            /// Only before publish and with no physical PCM reference remaining.
            pub fn cancel(self: Reservation) void {
                const cell = &self.token.anchor.cells[self.token.cell];
                const role = &cell.roles[@intFromEnum(self.token.role)];
                std.debug.assert(role.load(.acquire) == word(self.token.role_incarnation, RolePhase.reserved));
                role.store(word(self.token.role_incarnation, RolePhase.returned), .release);
                const bit = @as(u8, 1) << @intFromEnum(self.token.role);
                const previous = cell.live_role_mask.fetchAnd(~bit, .acq_rel);
                std.debug.assert(previous & bit != 0);
                if (self.root) {
                    std.debug.assert(previous == bit);
                    cell.state.store(word(self.token.cell_incarnation, CellPhase.free), .release);
                }
            }
        };
        pub const Token = struct {
            anchor: *Self,
            cell: u16,
            cell_incarnation: u64,
            role: Role,
            role_incarnation: u64,

            fn held(self: Token) bool {
                if (self.cell >= capacity or self.cell_incarnation == 0 or self.cell_incarnation > max_incarnation or self.role_incarnation == 0 or self.role_incarnation > max_incarnation) return false;
                const cell = &self.anchor.cells[self.cell];
                return cell.state.load(.acquire) == word(self.cell_incarnation, CellPhase.visible) and
                    cell.roles[@intFromEnum(self.role)].load(.acquire) == word(self.role_incarnation, RolePhase.held);
            }
            /// Caller exclusively owns this parent role until reserve returns.
            /// Each fixed role admits one physical pin at a time. Independent
            /// role incarnations prevent stale/duplicate snapshot-slot returns.
            pub fn reserveDerivative(self: Token, target: Role) !Reservation {
                if (!self.held() or target == .desired) return error.InvalidToken;
                const cell = &self.anchor.cells[self.cell];
                const role = &cell.roles[@intFromEnum(target)];
                const bit = @as(u8, 1) << @intFromEnum(target);
                if (cell.live_role_mask.load(.acquire) & bit != 0) return error.CapacityExceeded;
                const old = role.load(.acquire);
                if (phase(RolePhase, old) != .free and phase(RolePhase, old) != .returned) return error.CapacityExceeded;
                const incarnation = try next(old >> 3);
                if (role.cmpxchgStrong(old, word(incarnation, RolePhase.reserved), .acq_rel, .acquire) != null) return error.CapacityExceeded;
                const previous = cell.live_role_mask.fetchOr(bit, .acq_rel);
                std.debug.assert(previous != 0 and previous & bit == 0);
                return .{ .token = .{ .anchor = self.anchor, .cell = self.cell, .cell_incarnation = self.cell_incarnation, .role = target, .role_incarnation = incarnation }, .root = false };
            }
            pub fn matches(self: Token, owner: *Owner, destination: Destination) bool {
                if (!self.held()) return false;
                const cell = &self.anchor.cells[self.cell];
                return cell.owner == owner and std.meta.eql(cell.destination, destination);
            }
            /// Single use. A copy creates no ownership. Duplicate/stale calls
            /// are valid probes only while an independent lifetime retains this
            /// anchor. No token operation is valid after anchor destruction.
            pub fn releasePhysical(self: Token) bool {
                if (self.cell >= capacity or self.cell_incarnation == 0 or self.cell_incarnation > max_incarnation or self.role_incarnation == 0 or self.role_incarnation > max_incarnation) return false;
                const cell = &self.anchor.cells[self.cell];
                if (cell.state.load(.acquire) != word(self.cell_incarnation, CellPhase.visible)) return false;
                const role = &cell.roles[@intFromEnum(self.role)];
                if (role.cmpxchgStrong(word(self.role_incarnation, RolePhase.held), word(self.role_incarnation, RolePhase.returning), .acq_rel, .acquire) != null) return false;
                cell.owner.release();
                // No role/payload access after this publication. Reuse must
                // also acquire the cleared mask bit, so it cannot race ahead
                // of this releaser's final anchor access.
                role.store(word(self.role_incarnation, RolePhase.returned), .release);
                // FINAL anchor/owner access. Acquiring zero lets Control recycle
                // the cell and, after closed producer drain, destroy the anchor.
                const bit = @as(u8, 1) << @intFromEnum(self.role);
                const previous = cell.live_role_mask.fetchAnd(~bit, .acq_rel);
                std.debug.assert(previous & bit != 0);
                return true;
            }
        };
        /// Serialized source Control only. Payload is never inspected while a
        /// producer may be initializing it. Zero acquires every actual return.
        pub fn collect(self: *Self) u32 {
            var collected: u32 = 0;
            for (&self.cells) |*cell| {
                const current = cell.state.load(.acquire);
                if (phase(CellPhase, current) != .visible or cell.live_role_mask.load(.acquire) != 0) continue;
                for (&cell.roles) |*role| {
                    const value = phase(RolePhase, role.load(.acquire));
                    std.debug.assert(value == .free or value == .returned);
                }
                cell.state.store(word(current >> 3, CellPhase.free), .release);
                collected += 1;
            }
            return collected;
        }
        /// Closed acquisition + zero entered producers + collected real returns.
        /// No spin, queue-empty inference or SampleOwner aggregate substitution.
        pub fn drained(self: *const Self) bool {
            if (self.gate.load(.acquire) != closed) return false;
            for (&self.cells) |*cell| if (phase(CellPhase, cell.state.load(.acquire)) != .free) return false;
            return true;
        }
    };
}
