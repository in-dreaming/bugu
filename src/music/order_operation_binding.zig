//! Narrow, allocation-free binding of assembled operation/PCM facts to the
//! observed capture-order endpoints. This is not a semantic replay validator,
//! a source-completeness certificate, or a lifecycle/publication guarantee.
//!
//! One non-RT consumer owns a verifier. Observe every actual order record,
//! including valueless points, in per-role order BEFORE binding its endpoint.
//! There is no asynchronous merge, wait, retry, or search for a matching item.
//! The caller admits fixed FIFO storage; exhaustion and every rejection are
//! permanent. A successful finish only closes the supplied endpoint/PCM set.
const std = @import("std");
const order = @import("sme-capture-order");
const format = @import("causal_recording_format.zig");

pub const result_code_version: u16 = 1;
pub const max_points_per_operation: u64 = 65_536;
pub const max_endpoint_capacity: usize = 65_536;

/// Private binding convention v1, not a change to Record or any wire codec.
/// Render's real void return is success even if its completion diagnostic is
/// false. That diagnostic is checked independently by bind, never substituted
/// for the engine's true return value. Runtime-local error ordinals are unused.
pub fn stableResultCode(result: format.OperationResult) u32 {
    return switch (result) {
        .failed => |failure| 1 + @as(u32, @intFromEnum(failure)),
        .tick_failed => |value| 1 + @as(u32, @intFromEnum(value.failure)),
        else => 0,
    };
}

pub const BoundFact = union(enum) {
    operation: struct { receipt: order.EndpointReceipt, value: format.Record },
    pcm: struct {
        begin_receipt: order.EndpointReceipt,
        end_receipt: order.EndpointReceipt,
        value: format.PcmBlock,
        /// Borrowed only for this non-RT callback. Neither Sink nor Verifier
        /// retains this pointer; a sink must consume/copy before returning.
        samples: []const f32,
    },
};

/// Optional Session assembler callback. A rejected callback must permanently
/// invalidate that recording, without changing already-committed engine work.
pub const Sink = struct {
    context: *anyopaque,
    on_fact: *const fn (*anyopaque, BoundFact) anyerror!void,

    pub fn emit(self: Sink, fact: BoundFact) anyerror!void {
        try self.on_fact(self.context, fact);
    }
};

pub const Error = error{
    AlreadyFinished,
    InvalidOrder,
    InvalidEndpoint,
    MissingEndpoint,
    EndpointMismatch,
    CapacityExceeded,
    WorkBudget,
    InvalidOperation,
    InvalidResult,
    InvalidPcm,
    MissingPcm,
    UnsealedOrder,
    UnboundEndpoint,
    MissingOperationEnd,
};

fn semanticRole(role: order.Role) format.Role {
    return switch (role) {
        .control => .control,
        .render => .render,
        .worker => .worker,
    };
}
fn keyMatches(key: format.OperationKey, receipt: order.EndpointReceipt) bool {
    return key.role == semanticRole(receipt.role) and key.ordinal == receipt.operation;
}
fn receiptMatches(receipt: order.EndpointReceipt, actual: order.Record) bool {
    return receipt.role == actual.role and receipt.sequence == actual.sequence and
        receipt.operation == actual.operation and receipt.point_ordinal == actual.point_ordinal and
        receipt.kind == actual.kind and receipt.result_code == actual.result_code;
}
fn legalArgs(role: format.Role, args: format.OperationArgs) bool {
    return switch (args) {
        .submit, .tick, .poll_receipt, .retire_sources, .poll_phase_receipt => role == .control,
        .render => |value| role == .render and value.frames != 0 and
            value.frames <= format.max_recordable_render_frames and value.channels == 2,
        .worker_one => role == .worker,
    };
}
fn legalResult(begin: format.OperationBegin, result: format.OperationResult) bool {
    return switch (result) {
        .failed => |failure| begin.args != .render and !(begin.args == .tick and failure == .invalid_state),
        .tick_failed => |value| begin.args == .tick and value.failure == .invalid_state and
            value.control_tick != 0 and value.frontier_tick_serial != 0,
        .submitted => begin.args == .submit,
        .ticked => begin.args == .tick,
        .receipt => begin.args == .poll_receipt,
        .worked => begin.args == .worker_one,
        .retirement_requested => begin.args == .retire_sources,
        .phase_receipt => begin.args == .poll_phase_receipt,
        .rendered => |value| begin.args == .render and value.completed and
            value.frame_end >= value.frame_begin and value.frame_end - value.frame_begin == begin.args.render.frames and
            value.call_sequence_begin & 1 == 0 and value.call_sequence_end >= value.call_sequence_begin and
            value.call_sequence_end - value.call_sequence_begin == 2,
    };
}

/// All state is fixed, caller-owned storage. No allocator or sample pointer is
/// stored. Capacity is PER ROLE, counting only observed, still-unbound begin
/// and end records. Observed points cost constant work and no queue cell.
pub fn Verifier(comptime endpoint_capacity: usize) type {
    if (endpoint_capacity == 0 or endpoint_capacity > max_endpoint_capacity)
        @compileError("endpoint capacity must be 1..65536 per role");
    return struct {
        const Self = @This();
        const Active = struct { receipt: order.EndpointReceipt, value: format.OperationBegin };
        const PendingPcm = struct {
            begin_receipt: order.EndpointReceipt,
            end_receipt: order.EndpointReceipt,
            key: format.OperationKey,
            frames: u32,
            channels: u16,
        };
        const Lane = struct {
            sequence: u64 = 0,
            operation: u64 = 0,
            point_ordinal: u64 = 0,
            active_order: bool = false,
            endpoints: [endpoint_capacity]order.Record = undefined,
            head: usize = 0,
            len: usize = 0,
            active_bound: ?Active = null,

            fn append(self: *Lane, record: order.Record) Error!void {
                if (self.len == endpoint_capacity) return error.CapacityExceeded;
                self.endpoints[(self.head + self.len) % endpoint_capacity] = record;
                self.len += 1;
            }
            fn consume(self: *Lane) void {
                self.head = (self.head + 1) % endpoint_capacity;
                self.len -= 1;
            }
        };
        lanes: [3]Lane = .{ .{}, .{}, .{} },
        pending_pcm: ?PendingPcm = null,
        failure: ?Error = null,
        finished: bool = false,

        pub fn failureValue(self: *const Self) ?Error {
            return self.failure;
        }
        pub fn incomplete(self: *const Self) bool {
            return self.failure != null;
        }
        fn reject(self: *Self, err: Error) Error {
            if (self.failure == null) self.failure = err;
            return self.failure.?;
        }
        fn requireOpen(self: *Self) Error!void {
            if (self.failure) |err| return err;
            if (self.finished) return self.reject(error.AlreadyFinished);
        }

        pub fn observe(self: *Self, record: order.Record) Error!void {
            try self.requireOpen();
            self.observeChecked(record) catch |err| return self.reject(err);
        }
        fn observeChecked(self: *Self, record: order.Record) Error!void {
            const lane = &self.lanes[@intFromEnum(record.role)];
            if (lane.sequence == std.math.maxInt(u64) or record.sequence != lane.sequence + 1)
                return error.InvalidOrder;
            if (record.point_ordinal == 0 or record.point_ordinal > max_points_per_operation)
                return error.WorkBudget;
            switch (record.kind) {
                .begin => {
                    if (lane.active_order or record.operation != lane.operation + 1 or
                        record.operation > format.max_operations_per_role or record.point_ordinal != 1)
                        return error.InvalidOrder;
                    if (record.edge != .before or record.site != null or record.index != 0 or
                        record.generation != 0 or record.value != null or record.point_count != 0 or record.result_code != 0)
                        return error.InvalidEndpoint;
                    try lane.append(record);
                    lane.active_order = true;
                    lane.operation = record.operation;
                },
                .point, .end => {
                    if (!lane.active_order or record.operation != lane.operation or
                        record.point_ordinal != lane.point_ordinal + 1) return error.InvalidOrder;
                    if (record.kind == .point) {
                        if (record.site == null or record.point_count != 0 or record.result_code != 0)
                            return error.InvalidOrder;
                    } else {
                        if (record.edge != .after or record.site != null or record.index != 0 or
                            record.generation != 0 or record.value != null or record.point_count != record.point_ordinal)
                            return error.InvalidEndpoint;
                        try lane.append(record);
                        lane.active_order = false;
                    }
                },
            }
            lane.sequence = record.sequence;
            lane.point_ordinal = record.point_ordinal;
        }

        pub fn bind(self: *Self, fact: BoundFact) Error!void {
            try self.requireOpen();
            self.bindChecked(fact) catch |err| return self.reject(err);
        }
        fn bindChecked(self: *Self, fact: BoundFact) Error!void {
            switch (fact) {
                .operation => |bound| {
                    const receipt = bound.receipt;
                    if (receipt.kind == .point) return error.InvalidEndpoint;
                    const lane = &self.lanes[@intFromEnum(receipt.role)];
                    if (lane.len == 0) return error.MissingEndpoint;
                    if (!receiptMatches(receipt, lane.endpoints[lane.head])) return error.EndpointMismatch;
                    switch (bound.value) {
                        .begin => |value| {
                            if (receipt.kind != .begin or !keyMatches(value.key, receipt) or
                                !legalArgs(value.key.role, value.args) or lane.active_bound != null)
                                return error.InvalidOperation;
                            if (receipt.role == .render and self.pending_pcm != null) return error.MissingPcm;
                            lane.active_bound = .{ .receipt = receipt, .value = value };
                        },
                        .end => |value| {
                            const active = lane.active_bound orelse return error.InvalidOperation;
                            if (receipt.kind != .end or !keyMatches(value.key, receipt) or
                                !std.meta.eql(active.value.key, value.key)) return error.InvalidOperation;
                            if (!legalResult(active.value, value.result) or
                                receipt.result_code != stableResultCode(value.result)) return error.InvalidResult;
                            if (value.result == .rendered) {
                                if (self.pending_pcm != null) return error.MissingPcm;
                                self.pending_pcm = .{
                                    .begin_receipt = active.receipt,
                                    .end_receipt = receipt,
                                    .key = value.key,
                                    .frames = active.value.args.render.frames,
                                    .channels = active.value.args.render.channels,
                                };
                            }
                            lane.active_bound = null;
                        },
                        else => return error.InvalidOperation,
                    }
                    lane.consume();
                },
                .pcm => |bound| {
                    const pending = self.pending_pcm orelse return error.InvalidPcm;
                    if (!std.meta.eql(bound.begin_receipt, pending.begin_receipt) or
                        !std.meta.eql(bound.end_receipt, pending.end_receipt) or
                        !std.meta.eql(bound.value.key, pending.key) or bound.value.frames != pending.frames or
                        bound.value.channels != pending.channels or
                        bound.samples.len != @as(usize, pending.frames) * pending.channels) return error.InvalidPcm;
                    // The bound begin was admitted at <=64 stereo frames. This
                    // canonical accumulator hashes at most 128 samples and
                    // preserves signed zero, infinity and every NaN payload.
                    var accumulator = format.PcmAccumulator.init();
                    const actual = accumulator.append(pending.key, pending.frames, pending.channels, bound.samples) catch
                        return error.InvalidPcm;
                    if (!std.mem.eql(u8, &actual.digest, &bound.value.digest)) return error.InvalidPcm;
                    self.pending_pcm = null;
                },
            }
        }

        /// Called after the caller has supplied its complete observed set.
        /// This does not prove actual producer stop, drain, source coverage,
        /// ownership, causality, writer join, durability, or publication.
        pub fn finish(self: *Self) Error!void {
            if (self.failure) |err| return err;
            if (self.finished) return;
            for (&self.lanes) |*lane| {
                if (lane.active_order) return self.reject(error.UnsealedOrder);
                if (lane.len != 0) return self.reject(error.UnboundEndpoint);
                if (lane.active_bound != null) return self.reject(error.MissingOperationEnd);
            }
            if (self.pending_pcm != null) return self.reject(error.MissingPcm);
            self.finished = true;
        }
    };
}
