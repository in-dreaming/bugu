//! Profile-7 host ingress values. These are calls and observations, never
//! accepted Control requests or permission to synthesize a runtime result.
//! No floats, native enum ordinals, pointers, allocation or retained history.
const std = @import("std");
const music = @import("music");
pub const version: u16 = 1;
pub const max_operations: u64 = 65_536;
pub const Error = error{ UnknownVersion, InvalidEvent, InvalidOrder, InvalidCapacity, IncompleteTrace, UnsupportedOperation, UnknownSynchronousError, WorkLimit, InvalidState };

/// Public BankRef arguments are intentionally not API-validated here. Zero,
/// stale and wrong-context values must reach the real API for its own rejection.
pub const BankRef = struct {
    context: u64,
    index: u32,
    incarnation: u32,
    asset_generation: u64,
    pub fn fromPublic(value: music.MusicBankRefV1) BankRef {
        return .{ .context = value.context, .index = value.handle.index, .incarnation = value.handle.generation, .asset_generation = value.asset_generation };
    }
    pub fn toPublic(self: BankRef) music.MusicBankRefV1 {
        return .{ .context = self.context, .handle = .{ .index = self.index, .generation = self.incarnation }, .asset_generation = self.asset_generation };
    }
    fn validateObserved(self: BankRef) Error!void {
        if (self.context == 0 or self.index != 0 or self.incarnation == 0 or self.asset_generation == 0) return error.InvalidEvent;
    }
};
pub const Ticket = struct {
    context: u64,
    request_id: u64,
    bank: BankRef,
    pub fn fromPublic(value: music.MusicRequestTicketV1) Ticket {
        return .{ .context = value.context, .request_id = value.request_id, .bank = BankRef.fromPublic(value.bank) };
    }
    pub fn toPublic(self: Ticket) music.MusicRequestTicketV1 {
        return .{ .context = self.context, .request_id = self.request_id, .bank = self.bank.toPublic() };
    }
    pub fn validate(self: Ticket) Error!void {
        try self.bank.validateObserved();
        if (self.context != self.bank.context or self.request_id == 0) return error.InvalidEvent;
    }
};
/// Distinct from trace.RequestPayload: its scalar remains the ORIGINAL f32
/// bit pattern, including signed zero and invalid nonfinite API arguments.
pub const RequestTag = enum(u8) { set_state = 1, context_boolean = 2, context_integer = 3, context_scalar = 4, context_id = 5, stop_emergency = 6 };
pub const RequestPayload = union(RequestTag) {
    set_state: struct { state: u64, priority: u8 },
    context_boolean: struct { key: u64, value: bool },
    context_integer: struct { key: u64, value: i64 },
    context_scalar: struct { key: u64, scalar_bits: u32 },
    context_id: struct { key: u64, value: u64 },
    stop_emergency: void,
    pub fn fromPublic(value: music.MusicRequestPayload) Error!RequestPayload {
        return switch (value) {
            .set_state => |v| .{ .set_state = .{ .state = v.state.value(), .priority = v.priority } },
            .set_context => |v| switch (v.value) {
                .boolean => |x| .{ .context_boolean = .{ .key = v.key.value(), .value = x } },
                .integer => |x| .{ .context_integer = .{ .key = v.key.value(), .value = x } },
                .scalar => |x| .{ .context_scalar = .{ .key = v.key.value(), .scalar_bits = @bitCast(x) } },
                .id => |x| .{ .context_id = .{ .key = v.key.value(), .value = x.value() } },
            },
            .stop => |mode| if (mode == .emergency_ramp) .stop_emergency else error.UnsupportedOperation,
            else => error.UnsupportedOperation,
        };
    }
    /// No normalization/validation: replay invokes the original public API.
    pub fn toPublic(self: RequestPayload) music.MusicRequestPayload {
        return switch (self) {
            .set_state => |v| .{ .set_state = .{ .state = @enumFromInt(v.state), .priority = v.priority } },
            .context_boolean => |v| .{ .set_context = .{ .key = @enumFromInt(v.key), .value = .{ .boolean = v.value } } },
            .context_integer => |v| .{ .set_context = .{ .key = @enumFromInt(v.key), .value = .{ .integer = v.value } } },
            .context_scalar => |v| .{ .set_context = .{ .key = @enumFromInt(v.key), .value = .{ .scalar = @bitCast(v.scalar_bits) } } },
            .context_id => |v| .{ .set_context = .{ .key = @enumFromInt(v.key), .value = .{ .id = @enumFromInt(v.value) } } },
            .stop_emergency => .{ .stop = .emergency_ramp },
        };
    }
};
/// Versioned, profile-local exact synchronous API errors. Never serialize
/// @intFromError, and never coalesce these through public FailureV1.
pub const SyncError = enum(u16) {
    invalid_mode = 1,
    wrong_thread = 2,
    concurrent_control = 3,
    runtime_stopped = 4,
    wrong_context = 5,
    stale_asset_generation = 6,
    invalid_state = 7,
    invalid_music_graph = 8,
    unsupported_operation = 9,
    command_queue_full = 10,
    ticket_exhausted = 11,
    resident_transaction_busy = 12,
    unattributed_causal_operation = 13,
    pub fn fromError(err: anyerror) Error!SyncError {
        return switch (err) {
            error.InvalidMode => .invalid_mode,
            error.WrongThread => .wrong_thread,
            error.ConcurrentControl => .concurrent_control,
            error.RuntimeStopped => .runtime_stopped,
            error.WrongContext => .wrong_context,
            error.StaleAssetGeneration => .stale_asset_generation,
            error.InvalidState => .invalid_state,
            error.InvalidMusicGraph => .invalid_music_graph,
            error.UnsupportedOperation => .unsupported_operation,
            error.CommandQueueFull => .command_queue_full,
            error.TicketExhausted => .ticket_exhausted,
            error.ResidentTransactionBusy => .resident_transaction_busy,
            error.UnattributedCausalOperation => .unattributed_causal_operation,
            else => error.UnknownSynchronousError,
        };
    }
    pub fn toError(self: SyncError) anyerror {
        return switch (self) {
            .invalid_mode => error.InvalidMode,
            .wrong_thread => error.WrongThread,
            .concurrent_control => error.ConcurrentControl,
            .runtime_stopped => error.RuntimeStopped,
            .wrong_context => error.WrongContext,
            .stale_asset_generation => error.StaleAssetGeneration,
            .invalid_state => error.InvalidState,
            .invalid_music_graph => error.InvalidMusicGraph,
            .unsupported_operation => error.UnsupportedOperation,
            .command_queue_full => error.CommandQueueFull,
            .ticket_exhausted => error.TicketExhausted,
            .resident_transaction_busy => error.ResidentTransactionBusy,
            .unattributed_causal_operation => error.UnattributedCausalOperation,
        };
    }
};
/// These exact codes mirror the existing public Control rejection categories.
/// They do not claim to recover the original synchronous Zig error.
pub const Failure = enum(u8) {
    invalid_bank = 0,
    unsupported_capability = 1,
    invalid_state = 2,
    invalid_order = 3,
    wrong_context = 4,
    stale_bank = 5,
    out_of_memory = 6,
    resource_limit = 7,
    cancelled = 8,
    runtime_stopped = 9,
    command_queue_full = 10,
    transition_not_found = 11,
    voice_budget_exceeded = 12,
    internal_failure = 13,
    request_in_progress = 14,
    source_unavailable = 15,
    source_io = 16,
    source_close = 17,
    stream_underrun = 18,
    pub fn fromPublic(value: music.MusicRuntimeFailureV1) Failure {
        return switch (value) {
            inline else => |v| @field(Failure, @tagName(v)),
        };
    }
    pub fn toPublic(self: Failure) music.MusicRuntimeFailureV1 {
        return switch (self) {
            inline else => |v| @field(music.MusicRuntimeFailureV1, @tagName(v)),
        };
    }
};
pub const PhaseOutcome = enum(u8) { executed = 1, cancelled = 2 };
pub const PhaseReceipt = struct {
    context: u64,
    transport_epoch: u64,
    plan_id: u64,
    plan_epoch: u64,
    phase_id: u64,
    asset_generation: u64,
    outcome: PhaseOutcome,
    effective_frame: u64,
    pub fn fromPublic(value: music.PhaseReceipt) PhaseReceipt {
        return .{ .context = value.token.context.value(), .transport_epoch = value.token.transport_epoch.value(), .plan_id = value.token.plan_id.value(), .plan_epoch = value.token.plan_epoch.value(), .phase_id = value.token.phase_id.value(), .asset_generation = value.token.asset_generation.value(), .outcome = switch (value.outcome) {
            .executed => .executed,
            .cancelled => .cancelled,
        }, .effective_frame = value.effective_frame };
    }
    pub fn toPublic(self: PhaseReceipt) music.PhaseReceipt {
        return .{ .token = .{ .context = @enumFromInt(self.context), .transport_epoch = @enumFromInt(self.transport_epoch), .plan_id = @enumFromInt(self.plan_id), .plan_epoch = @enumFromInt(self.plan_epoch), .phase_id = @enumFromInt(self.phase_id), .asset_generation = @enumFromInt(self.asset_generation) }, .outcome = switch (self.outcome) {
            .executed => .executed,
            .cancelled => .cancelled,
        }, .effective_frame = self.effective_frame };
    }
    pub fn validate(self: PhaseReceipt) Error!void {
        if (self.context == 0 or self.transport_epoch == 0 or self.plan_id == 0 or self.plan_epoch == 0 or self.phase_id == 0 or self.asset_generation == 0) return error.InvalidEvent;
    }
};
pub const ReceiptTag = enum(u8) { accepted = 1, executed = 2, unchanged = 3, rejected = 4, cancelled_before_entry = 5, control_applied = 6 };
pub const ReceiptEvent = union(ReceiptTag) {
    accepted: struct { control_tick: u64, render_frame: u64 },
    executed: PhaseReceipt,
    unchanged: void,
    rejected: Failure,
    cancelled_before_entry: PhaseReceipt,
    control_applied: struct { control_tick: u64, render_frame: u64, input_order: u64 },
};
pub const Receipt = struct {
    version: u16 = 1,
    ticket: Ticket,
    event: ReceiptEvent,
    pub fn fromPublic(value: music.MusicRuntimeReceiptV1) Receipt {
        return .{ .version = value.version, .ticket = Ticket.fromPublic(value.ticket), .event = switch (value.event) {
            .accepted => |v| .{ .accepted = .{ .control_tick = v.control_tick, .render_frame = v.render_frame } },
            .terminal => |terminal| switch (terminal) {
                .executed => |v| .{ .executed = PhaseReceipt.fromPublic(v) },
                .unchanged => .unchanged,
                .rejected => |v| .{ .rejected = Failure.fromPublic(v) },
                .cancelled_before_entry => |v| .{ .cancelled_before_entry = PhaseReceipt.fromPublic(v) },
                .control_applied => |v| .{ .control_applied = .{ .control_tick = v.control_tick, .render_frame = v.render_frame, .input_order = v.input_order } },
            },
        } };
    }
    pub fn toPublic(self: Receipt) music.MusicRuntimeReceiptV1 {
        return .{ .version = self.version, .ticket = self.ticket.toPublic(), .event = switch (self.event) {
            .accepted => |v| .{ .accepted = .{ .control_tick = v.control_tick, .render_frame = v.render_frame } },
            .executed => |v| .{ .terminal = .{ .executed = v.toPublic() } },
            .unchanged => .{ .terminal = .unchanged },
            .rejected => |v| .{ .terminal = .{ .rejected = v.toPublic() } },
            .cancelled_before_entry => |v| .{ .terminal = .{ .cancelled_before_entry = v.toPublic() } },
            .control_applied => |v| .{ .terminal = .{ .control_applied = .{ .control_tick = v.control_tick, .render_frame = v.render_frame, .input_order = v.input_order } } },
        } };
    }
    pub fn validate(self: Receipt) Error!void {
        if (self.version != 1) return error.UnknownVersion;
        try self.ticket.validate();
        switch (self.event) {
            .accepted => |v| if (v.control_tick == 0) return error.InvalidEvent,
            .control_applied => |v| if (v.control_tick == 0) return error.InvalidEvent,
            .executed, .cancelled_before_entry => |v| {
                try v.validate();
                if (v.context != self.ticket.context or v.asset_generation != self.ticket.bank.asset_generation) return error.InvalidEvent;
                if ((self.event == .executed) != (v.outcome == .executed)) return error.InvalidEvent;
            },
            .unchanged, .rejected => {},
        }
    }
};
pub const Kind = enum(u8) { start = 1, submit = 2, poll_receipt = 3, poll_phase_receipt = 4 };
pub const Args = union(Kind) {
    start: struct { bank: BankRef, state: u64 },
    submit: struct { bank: BankRef, payload: RequestPayload },
    poll_receipt: void,
    poll_phase_receipt: void,
};
pub const Call = struct {
    version: u16 = 1,
    operation_serial: u64,
    /// Actual recording session; independent of a possibly invalid bank argument.
    context: u64,
    render_call_sequence: u64,
    args: Args,
    pub fn validate(self: Call) Error!void {
        if (self.version != 1) return error.UnknownVersion;
        if (self.operation_serial == 0 or self.operation_serial > max_operations or self.context == 0 or self.render_call_sequence & 1 != 0) return error.InvalidEvent;
    }
};
pub const OutcomeTag = enum(u8) { submitted = 1, failed = 2, receipt = 3, phase_receipt = 4 };
pub const Outcome = union(OutcomeTag) { submitted: Ticket, failed: SyncError, receipt: ?Receipt, phase_receipt: ?PhaseReceipt };
pub const Result = struct {
    version: u16 = 1,
    operation_serial: u64,
    outcome: Outcome,
    pub fn validate(self: Result) Error!void {
        if (self.version != 1) return error.UnknownVersion;
        if (self.operation_serial == 0 or self.operation_serial > max_operations) return error.InvalidEvent;
        switch (self.outcome) {
            .submitted => |v| try v.validate(),
            .receipt => |v| if (v) |r| try r.validate(),
            .phase_receipt => |v| if (v) |r| try r.validate(),
            .failed => {},
        }
    }
};
pub const RecordTag = enum(u8) { call = 1, result = 2 };
pub const Record = union(RecordTag) {
    call: Call,
    result: Result,
    pub fn validate(self: Record) Error!void {
        switch (self) {
            inline else => |v| try v.validate(),
        }
    }
};

/// Fixed memory: one outstanding synchronous invocation and finite total work.
/// Pairing verifies representation only. Runtime replay still compares every
/// actual result, accepted request fact and receipt; no result is injected.
pub const Journal = struct {
    limit: u64 = max_operations,
    next_serial: u64 = 1,
    next_request_id: u64 = 1,
    context: ?u64 = null,
    pending: ?Call = null,
    incomplete: bool = false,
    poisoned: bool = false,
    pub fn init(limit: u64) Error!Journal {
        if (limit == 0 or limit > max_operations) return error.InvalidCapacity;
        return .{ .limit = limit };
    }
    pub fn accept(self: *Journal, record: Record) Error!void {
        if (self.poisoned) return error.InvalidState;
        errdefer self.poisoned = true;
        try record.validate();
        switch (record) {
            .call => |call| {
                if (self.pending != null or call.operation_serial != self.next_serial) return error.InvalidOrder;
                if (self.next_serial > self.limit) return error.WorkLimit;
                if (self.context) |context| if (call.context != context) return error.InvalidEvent;
                self.context = call.context;
                self.pending = call;
            },
            .result => |result| {
                const call = self.pending orelse return error.InvalidOrder;
                if (result.operation_serial != call.operation_serial) return error.InvalidOrder;
                switch (result.outcome) {
                    .submitted => |ticket| {
                        const bank = switch (call.args) {
                            .start => |v| v.bank,
                            .submit => |v| v.bank,
                            else => return error.InvalidEvent,
                        };
                        if (ticket.context != call.context or !std.meta.eql(ticket.bank, bank)) return error.InvalidEvent;
                        if (ticket.request_id != self.next_request_id) return error.InvalidOrder;
                        self.next_request_id += 1;
                    },
                    .failed => |failure| {
                        // Preserve the actual observation, but never certify a
                        // complete synchronous queue-overload witness in v1.
                        if (failure == .command_queue_full) self.incomplete = true;
                    },
                    .receipt => |value| {
                        if (call.args != .poll_receipt) return error.InvalidEvent;
                        if (value) |receipt| if (receipt.ticket.context != call.context or receipt.ticket.request_id >= self.next_request_id) return error.InvalidEvent;
                    },
                    .phase_receipt => |value| {
                        if (call.args != .poll_phase_receipt) return error.InvalidEvent;
                        if (value) |receipt| if (receipt.context != call.context) return error.InvalidEvent;
                    },
                }
                self.pending = null;
                self.next_serial += 1; // bounded by max_operations + 1
            },
        }
    }
    /// Calls are synchronous: no tick/render/ordinary fact may split a pair.
    pub fn boundary(self: *Journal) Error!void {
        if (self.poisoned) return error.InvalidState;
        if (self.pending != null) {
            self.poisoned = true;
            return error.InvalidOrder;
        }
    }
    pub fn finish(self: *Journal) Error!void {
        if (self.poisoned) return error.InvalidState;
        if (self.pending != null or self.incomplete) {
            self.poisoned = true;
            return error.IncompleteTrace;
        }
    }
};
