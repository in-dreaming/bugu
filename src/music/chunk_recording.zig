//! Fixed-memory ChunkRecordingV1 producer and non-RT exporter.
//! No runtime/Render hooks, allocator, filesystem, or legacy recorder changes.
//! Address-stable Storage and Scratch belong to the caller for their full lives.
const std = @import("std");
const schema = @import("trace_schema.zig");
const chunks = @import("recording_chunks.zig");

pub const data_cell_count: usize = 4;
pub const records_per_cell: usize = chunks.max_chunk_records;
pub const Record = chunks.Record;
pub const Error = chunks.Error || error{ InvalidIdentity, IdentityExhausted, Busy, StaleLease, LeaseNotEncoded, PartialWrite, InUse, ExportFailed, UnconfirmedWrites };
pub const CaptureResult = enum { retained, closed, failed };
pub const Frontier = struct { control_tick: u64, control_frame: u64, render_call_sequence: u64 };
pub const State = enum(u8) { uninitialized, active, sealed, failed, retired };
const CellState = enum(u8) { free, writing, ready, leased };
pub const Kind = enum(u8) { data, terminal };
var next_storage_generation: std.atomic.Value(u64) = .init(1);

pub const Status = struct {
    state: State,
    reason: chunks.TerminalReason,
    producer_closed: bool,
    successful_end_staged: bool,
    terminal_acknowledged: bool,
    export_failed: bool,
    /// False requires an acknowledged genuine success terminal. Even then this
    /// is neither a durable-write claim nor runtime/replay validation evidence.
    incomplete: bool,
    /// Concurrent snapshots are individually atomic, not a coherent multiword
    /// cut. Control may read them exactly between its own capture operations.
    retained_inputs: u64,
    retained_schedule: u64,
};

const DataCell = struct {
    state: std.atomic.Value(CellState) = .init(.free),
    generation: u64 = 0,
    sequence: u64 = 0,
    input_begin: u64 = 0,
    schedule_begin: u64 = 0,
    count: usize = 0,
    input_count: usize = 0,
    schedule_count: usize = 0,
    records: [records_per_cell]Record = undefined,
};
const TerminalCell = struct {
    state: std.atomic.Value(CellState) = .init(.free),
    value: chunks.Terminal = undefined,
    end: ?schema.Input = null,
};

/// Exact, one-time capability for one immutable cell. Local address and unique
/// storage generation additionally bind caller-provided IDs against reuse.
pub const Lease = struct {
    storage_address: usize,
    storage_id: u64,
    incarnation: u64,
    storage_generation: u64,
    recording_id: schema.Hash,
    kind: Kind,
    cell_index: usize,
    cell_generation: u64,
    sequence: u64,
};

/// Caller initializes the value with .{} BEFORE init, then never copies/moves
/// it. init is one-shot, including after deinit. Lifecycle operations require
/// external exclusion from all producer/exporter calls and pointer acquisition.
/// One serialized Control owner calls capture/finish/fail/serviceFailure.
pub const Storage = struct {
    lifecycle: std.atomic.Value(State) = .init(.uninitialized),
    failure: std.atomic.Value(chunks.TerminalReason) = .init(.none),
    closed: std.atomic.Value(bool) = .init(false),
    end_staged: std.atomic.Value(bool) = .init(false),
    terminal_acked: std.atomic.Value(bool) = .init(false),
    export_failed: std.atomic.Value(bool) = .init(false),
    exporter_attached: std.atomic.Value(bool) = .init(false),
    exporter_address: std.atomic.Value(usize) = .init(0),
    exporter_ever_attached: bool = false,
    published_inputs: std.atomic.Value(u64) = .init(0),
    published_schedule: std.atomic.Value(u64) = .init(0),
    bound_address: usize = 0,
    storage_id: u64 = 0,
    incarnation: u64 = 0,
    storage_generation: u64 = 0,
    preamble: chunks.Preamble = undefined,
    cells: [data_cell_count]DataCell = .{ .{}, .{}, .{}, .{} },
    terminal: TerminalCell = .{},
    // Below are exclusively owned by serialized Control until closed publishes.
    active: ?usize = null,
    next_sequence: u64 = 0,
    input_total: u64 = 0,
    schedule_total: u64 = 0,
    attempted_inputs: u64 = 0,
    attempted_schedule: u64 = 0,
    counters_exhausted: bool = false,
    frontier: Frontier = .{ .control_tick = 0, .control_frame = 0, .render_call_sequence = 0 },
    previous: ?schema.Position = null,
    admission: ?schema.Admission = null,
    host_journal: schema.context_host.Journal = .{},

    /// Non-RT initialization: validates the preamble (including its hash).
    /// No allocations, large by-value Storage temporary, or implicit reset.
    pub fn init(self: *Storage, preamble: chunks.Preamble, storage_id: u64, incarnation: u64) Error!void {
        if (self.lifecycle.load(.acquire) != .uninitialized) return error.InvalidState;
        if (storage_id == 0 or incarnation == 0) return error.InvalidIdentity;
        try preamble.validate();
        const generation = next_storage_generation.load(.monotonic);
        if (generation == std.math.maxInt(u64)) return error.IdentityExhausted;
        if (next_storage_generation.cmpxchgStrong(generation, generation + 1, .monotonic, .monotonic) != null) return error.Busy;
        self.bound_address = @intFromPtr(self);
        self.storage_id = storage_id;
        self.incarnation = incarnation;
        self.storage_generation = generation;
        self.preamble = preamble;
        self.lifecycle.store(.active, .release);
    }

    pub fn requiredBytes() usize {
        return @sizeOf(Storage);
    }

    pub fn status(self: *const Storage) Status {
        const reason = self.failure.load(.acquire);
        const phase = self.lifecycle.load(.acquire);
        const end = self.end_staged.load(.acquire);
        const acked = self.terminal_acked.load(.acquire);
        return .{
            .state = if (reason != .none and phase != .retired) .failed else phase,
            .reason = reason,
            .producer_closed = self.closed.load(.acquire),
            .successful_end_staged = end and reason == .none,
            .terminal_acknowledged = acked,
            .export_failed = self.export_failed.load(.acquire),
            .incomplete = reason != .none or !end or !acked,
            .retained_inputs = self.published_inputs.load(.acquire) + @as(u64, @intFromBool(end and reason == .none)),
            .retained_schedule = self.published_schedule.load(.acquire),
        };
    }

    /// This result describes recording ONLY. A runtime must not interpret failed
    /// as "audio operation did not execute" or retry an already executed call.
    pub fn appendInput(self: *Storage, input: schema.Input, frontier: Frontier) CaptureResult {
        if (self.beforeCapture(frontier)) |result| return result;
        self.attempted_inputs = std.math.add(u64, self.input_total, 1) catch {
            self.counters_exhausted = true;
            self.fail(.counter_exhausted, frontier);
            return .failed;
        };
        // Keep representable space for a genuine terminal end even if this
        // session ultimately fails and never writes that end.
        if (self.attempted_inputs == std.math.maxInt(u64)) {
            self.counters_exhausted = true;
            self.fail(.counter_exhausted, frontier);
            return .failed;
        }
        self.checkInput(input, false) catch {
            self.fail(.runtime_closure_failed, frontier);
            return .failed;
        };
        const cell = self.acquireWritable() orelse return .failed;
        cell.records[cell.count] = .{ .input = input };
        cell.count += 1;
        cell.input_count += 1;
        self.input_total = self.attempted_inputs;
        self.previous = input.position;
        if (input.payload == .admission) self.admission = input.payload.admission;
        self.published_inputs.store(self.input_total, .release);
        if (cell.count == records_per_cell) self.sealActive();
        self.serviceFailure();
        return if (self.failure.load(.acquire) == .none) .retained else .failed;
    }

    pub fn appendSchedule(self: *Storage, entry: schema.ScheduleEntry, frontier: Frontier) CaptureResult {
        if (self.beforeCapture(frontier)) |result| return result;
        self.attempted_schedule = std.math.add(u64, self.schedule_total, 1) catch {
            self.counters_exhausted = true;
            self.fail(.counter_exhausted, frontier);
            return .failed;
        };
        entry.validate() catch {
            self.fail(.runtime_closure_failed, frontier);
            return .failed;
        };
        const cell = self.acquireWritable() orelse return .failed;
        cell.records[cell.count] = .{ .schedule = entry };
        cell.count += 1;
        cell.schedule_count += 1;
        self.schedule_total = self.attempted_schedule;
        self.published_schedule.store(self.schedule_total, .release);
        if (cell.count == records_per_cell) self.sealActive();
        self.serviceFailure();
        return if (self.failure.load(.acquire) == .none) .retained else .failed;
    }

    pub fn flush(self: *Storage) CaptureResult {
        if (self.beforeCapture(self.frontier)) |result| return result;
        self.sealActive();
        self.serviceFailure();
        return if (self.failure.load(.acquire) == .none) .retained else .failed;
    }

    /// Called only AFTER caller runtime closure and public grammar checks.
    /// Accepts a real collected .end; never creates or repairs an end record.
    pub fn finish(self: *Storage, real_end: schema.Input) CaptureResult {
        const frontier: Frontier = .{
            .control_tick = real_end.position.control_tick,
            .control_frame = real_end.position.accepted_control_frame,
            .render_call_sequence = if (real_end.payload == .runtime_step) real_end.payload.runtime_step.render_call_sequence else self.frontier.render_call_sequence,
        };
        if (self.beforeCapture(frontier)) |result| return result;
        self.attempted_inputs = std.math.add(u64, self.input_total, 1) catch {
            self.counters_exhausted = true;
            self.fail(.counter_exhausted, frontier);
            return .failed;
        };
        self.checkInput(real_end, true) catch {
            self.fail(.runtime_closure_failed, frontier);
            return .failed;
        };
        self.sealActive();
        if (self.failure.load(.acquire) != .none) {
            self.serviceFailure();
            return .failed;
        }
        self.terminal.value = self.makeTerminal(.complete, .none);
        self.terminal.value.total_inputs = self.attempted_inputs;
        self.terminal.value.attempted_input_frontier = self.attempted_inputs;
        self.terminal.end = real_end;
        self.end_staged.store(true, .release);
        self.terminal.state.store(.ready, .release);
        self.closed.store(true, .release);
        self.lifecycle.store(.sealed, .release);
        return if (self.failure.load(.acquire) == .none) .retained else .failed;
    }

    /// Control-only. The FIRST reason is irreversible. A late failure changes
    /// status but never mutates an already published/leased success terminal.
    pub fn fail(self: *Storage, reason: chunks.TerminalReason, frontier: Frontier) void {
        if (!self.isBound() or self.lifecycle.load(.acquire) == .retired) return;
        self.frontier = frontier;
        const actual = if (reason == .none) chunks.TerminalReason.runtime_closure_failed else reason;
        if (actual == .counter_exhausted) self.counters_exhausted = true;
        if (actual == .export_failed) self.export_failed.store(true, .release);
        _ = self.failure.cmpxchgStrong(.none, actual, .acq_rel, .acquire);
        self.serviceFailure();
    }

    /// Control-only reconciliation of asynchronous exporter failure. The failure
    /// is already visible atomically; this publishes reserved terminal metadata.
    /// Broken storage cannot guarantee persistence of any terminal bytes.
    pub fn serviceFailure(self: *Storage) void {
        if (!self.isBound() or self.closed.load(.acquire)) return;
        const reason = self.failure.load(.acquire);
        if (reason == .none) return;
        self.sealActive();
        self.terminal.value = self.makeTerminal(.recorder_failed, reason);
        self.terminal.end = null;
        self.terminal.state.store(.ready, .release);
        self.closed.store(true, .release);
        self.lifecycle.store(.failed, .release);
    }

    pub fn deinit(self: *Storage) Error!void {
        if (!self.isBound() or self.lifecycle.load(.acquire) == .retired) return error.InvalidState;
        if (!self.closed.load(.acquire) or self.exporter_attached.load(.acquire) or self.active != null) return error.InUse;
        for (&self.cells) |*cell| if (cell.state.load(.acquire) != .free) return error.InUse;
        if (self.terminal.state.load(.acquire) != .free) return error.InUse;
        self.lifecycle.store(.retired, .release);
    }

    fn isBound(self: *const Storage) bool {
        return self.bound_address == @intFromPtr(self) and self.storage_generation != 0;
    }
    fn beforeCapture(self: *Storage, frontier: Frontier) ?CaptureResult {
        if (!self.isBound() or self.lifecycle.load(.acquire) == .retired) return .closed;
        if (self.failure.load(.acquire) != .none) {
            self.serviceFailure();
            return .failed;
        }
        if (self.closed.load(.acquire)) return .closed;
        self.frontier = frontier;
        return null;
    }
    fn checkInput(self: *Storage, input: schema.Input, terminal: bool) Error!void {
        try input.validate();
        if (self.previous) |p| {
            if (!schema.before(p, input.position) or input.position.accepted_control_frame < p.accepted_control_frame) return error.InvalidOrder;
        }
        const profile = self.preamble.runtime_profile;
        if (profile == .stream_context_serial_v1) {
            if (input.payload == .context_host_operation) {
                try self.host_journal.accept(input.payload.context_host_operation);
            } else try self.host_journal.boundary();
            if (terminal) try self.host_journal.finish();
        }
        switch (input.payload) {
            .context_host_operation => if (profile != .stream_context_serial_v1) return error.UnsupportedProfile,
            .state_host_operation => if (profile == .stream_context_serial_v1) return error.UnsupportedProfile,
            .runtime_step => |step| {
                if (step.profile != self.preamble.runtime_profile) return error.UnsupportedProfile;
                if ((step.kind == .end) != terminal) return error.UnexpectedEnd;
            },
            .admission => |a| if (self.admission) |g| {
                if (a.gate < g.gate or a.frame < g.frame or (a.gate == g.gate and (a.frame != g.frame or a.gate_order <= g.gate_order or a.commit_horizon != g.commit_horizon))) return error.InvalidOrder;
            },
            .acoustic_observation => |value| if (value.hasLoss()) return error.IncompleteTrace,
            else => {},
        }
        if (terminal and (input.payload != .runtime_step or input.payload.runtime_step.kind != .end)) return error.UnexpectedEnd;
    }
    fn acquireWritable(self: *Storage) ?*DataCell {
        if (self.active) |index| return &self.cells[index];
        if (self.next_sequence > std.math.maxInt(u64) - 2) {
            self.counters_exhausted = true;
            self.fail(.counter_exhausted, self.frontier);
            return null;
        }
        const index: usize = @intCast(self.next_sequence % data_cell_count);
        const cell = &self.cells[index];
        if (cell.state.load(.acquire) != .free) {
            self.fail(.capacity_exhausted, self.frontier);
            return null;
        }
        if (cell.generation == std.math.maxInt(u64)) {
            self.counters_exhausted = true;
            self.fail(.counter_exhausted, self.frontier);
            return null;
        }
        cell.generation += 1;
        cell.sequence = self.next_sequence;
        cell.input_begin = self.input_total;
        cell.schedule_begin = self.schedule_total;
        cell.count = 0;
        cell.input_count = 0;
        cell.schedule_count = 0;
        cell.state.store(.writing, .monotonic);
        self.active = index;
        return cell;
    }
    fn sealActive(self: *Storage) void {
        const index = self.active orelse return;
        const cell = &self.cells[index];
        std.debug.assert(cell.count != 0 and cell.count <= records_per_cell);
        // acquireWritable reserved this addition AND the terminal frame count.
        self.next_sequence += 1;
        self.active = null;
        cell.state.store(.ready, .release);
    }
    fn makeTerminal(self: *const Storage, status_value: chunks.TerminalStatus, reason: chunks.TerminalReason) chunks.Terminal {
        return .{
            .status = status_value,
            .reason = reason,
            .total_inputs = self.input_total,
            .total_schedule = self.schedule_total,
            .data_chunk_count = self.next_sequence,
            .final_control_tick = self.frontier.control_tick,
            .final_control_frame = self.frontier.control_frame,
            .final_render_call_sequence = self.frontier.render_call_sequence,
            .attempted_input_frontier = @max(self.attempted_inputs, self.input_total),
            .attempted_schedule_frontier = @max(self.attempted_schedule, self.schedule_total),
            .counters_exhausted = self.counters_exhausted,
        };
    }
    fn signalExportFailure(self: *Storage) void {
        self.export_failed.store(true, .release);
        _ = self.failure.cmpxchgStrong(.none, .export_failed, .acq_rel, .acquire);
    }
};

/// Typed regrouping is fixed scratch, since trace.chunks accepts channel slices.
/// These are not 254 additional retained records PER CHANNEL in the queue: every
/// cell has only 254 tagged records COMBINED. Scratch is reused for one lease.
pub const Scratch = struct {
    preamble: [chunks.preamble_bytes]u8 = undefined,
    header: [chunks.frame_header_bytes]u8 = undefined,
    payload: [chunks.max_payload_bytes]u8 = undefined,
    inputs: [records_per_cell]schema.Input = undefined,
    schedule: [records_per_cell]schema.ScheduleEntry = undefined,
    pub fn requiredBytes() usize {
        return @sizeOf(Scratch);
    }
};
pub const EncodedBatch = struct {
    preamble: []const u8,
    header: []const u8,
    payload: []const u8,
    chunk_hash: schema.Hash,
    pub fn byteCount(self: EncodedBatch) usize {
        return self.preamble.len + self.header.len + self.payload.len;
    }
    fn suffix(self: EncodedBatch, offset: usize) []const u8 {
        if (offset < self.preamble.len) return self.preamble[offset..];
        const frame_offset = offset - self.preamble.len;
        if (frame_offset < self.header.len) return self.header[frame_offset..];
        return self.payload[frame_offset - self.header.len ..];
    }
};

/// The sink MUST confirm writing at this exact absolute offset. written(n)
/// means precisely that prefix accepted, 0 <= n <= offered length. would_block
/// and failed mean NO bytes accepted by that call. uncertain is irrecoverable.
/// Caller performs I/O off RT and may not hide an unbounded copy/queue here.
pub const WriteResult = union(enum) { written: usize, would_block, failed, uncertain };
pub const Sink = struct { context: *anyopaque, writeAt: *const fn (*anyopaque, u64, []const u8) WriteResult };
pub const WriteProgress = enum { idle, progress, would_block, frame_accepted, terminal_accepted, failed };

/// Issued only after the sink confirmed every write and the success terminal
/// was acknowledged. This is an acceptance receipt, not filesystem durability
/// or runtime/replay proof. An uncertain artifact may contain a complete-looking
/// terminal in raw bytes but can NEVER obtain this receipt.
pub const ExportCompletion = struct {
    storage_id: u64,
    incarnation: u64,
    storage_generation: u64,
    recording_id: schema.Hash,
    terminal_hash: schema.Hash,
    total_inputs: u64,
    total_schedule: u64,
    total_frames: u64,
    total_bytes: u64,
    durability_not_attested: void = {},
    replay_validation_required: void = {},
};

/// Exactly one independently serialized exporter owns all its methods. Do not
/// copy/move it or Scratch while active. init/deinit additionally require host
/// lifecycle exclusion. Poll/ack never acquire a producer mutex or call audio.
pub const Exporter = struct {
    storage: *Storage,
    scratch: *Scratch,
    encoder: chunks.Encoder,
    bound_address: usize = 0,
    next_sequence: u64 = 0,
    active: ?Lease = null,
    encoded: ?EncodedBatch = null,
    encoded_terminal_success: bool = false,
    write_offset: usize = 0,
    stream_offset: u64 = 0,
    preamble_accepted: bool = false,
    terminal_consumed: bool = false,
    writes_confirmed: bool = true,
    terminal_hash: ?schema.Hash = null,
    poisoned: bool = false,
    detached: bool = false,

    /// Small exporter metadata only; storage/scratch payloads are never copied.
    /// Before the first method call, bind() fixes this value's final address.
    pub fn init(storage: *Storage, scratch: *Scratch) Error!Exporter {
        if (!storage.isBound() or storage.lifecycle.load(.acquire) == .retired) return error.InvalidState;
        if (storage.exporter_ever_attached or storage.exporter_attached.load(.acquire)) return error.InUse;
        const encoder = try chunks.Encoder.init(storage.preamble);
        _ = try chunks.encodePreamble(&scratch.preamble, storage.preamble);
        storage.exporter_ever_attached = true;
        storage.exporter_attached.store(true, .release);
        return .{ .storage = storage, .scratch = scratch, .encoder = encoder };
    }

    pub fn poll(self: *Exporter) Error!?Lease {
        try self.bind();
        if (self.poisoned) return error.ExportFailed;
        if (self.active != null) return error.Busy;
        return self.pollOwned();
    }

    /// Hashing and encoding are non-RT, once per lease. Repeat calls return the
    /// same borrowed byte slices without advancing the chain or changing bytes.
    pub fn encodeLease(self: *Exporter, lease: Lease) Error!EncodedBatch {
        try self.bind();
        try self.validateLease(lease);
        if (self.poisoned) return error.ExportFailed;
        if (self.encoded_terminal_success and self.storage.failure.load(.acquire) != .none) {
            self.failExport();
            return error.ExportFailed;
        }
        if (self.encoded) |batch| return batch;
        errdefer self.failExport();
        var terminal_success = false;
        const frame = switch (lease.kind) {
            .data => blk: {
                const cell = &self.storage.cells[lease.cell_index];
                if (cell.input_begin != self.encoder.input_total or cell.schedule_begin != self.encoder.schedule_total or cell.sequence != self.encoder.next_sequence) return error.InvalidOrder;
                var inputs: usize = 0;
                var schedule: usize = 0;
                for (cell.records[0..cell.count]) |record| switch (record) {
                    .input => |input| {
                        self.scratch.inputs[inputs] = input;
                        inputs += 1;
                    },
                    .schedule => |entry| {
                        self.scratch.schedule[schedule] = entry;
                        schedule += 1;
                    },
                };
                if (inputs != cell.input_count or schedule != cell.schedule_count) return error.InvalidState;
                break :blk try self.encoder.encodeData(&self.scratch.header, &self.scratch.payload, self.scratch.inputs[0..inputs], self.scratch.schedule[0..schedule]);
            },
            .terminal => blk: {
                var terminal = self.storage.terminal.value;
                var end = self.storage.terminal.end;
                // A failure after producer sealing cannot repair this artifact
                // into success. No shared/leased payload is changed here.
                const reason = self.storage.failure.load(.acquire);
                if (reason != .none and terminal.status == .complete) {
                    terminal.status = .recorder_failed;
                    terminal.reason = reason;
                    terminal.total_inputs -= 1;
                    if (reason == .counter_exhausted) terminal.counters_exhausted = true;
                    end = null;
                }
                terminal_success = terminal.status == .complete;
                break :blk try self.encoder.encodeTerminal(&self.scratch.header, &self.scratch.payload, terminal, end);
            },
        };
        const batch: EncodedBatch = .{
            .preamble = if (self.preamble_accepted) self.scratch.preamble[0..0] else &self.scratch.preamble,
            .header = frame.header,
            .payload = frame.payload,
            .chunk_hash = frame.chunk_hash,
        };
        // Refuse the whole bounded batch before offering ANY of its bytes when
        // the sink's absolute offset horizon cannot represent its final byte.
        _ = std.math.add(u64, self.stream_offset, @intCast(batch.byteCount())) catch return error.CounterOverflow;
        self.encoded = batch;
        self.encoded_terminal_success = terminal_success;
        return batch;
    }

    /// Transfers memory ownership after a consumer accepts the entire encoded
    /// batch. Does NOT assert a write, fsync, durable completion, or replay proof.
    /// A direct consumer can ack with write_offset=0. The built-in writer may
    /// only ack after accepting every byte; a partially written batch is pinned.
    pub fn ack(self: *Exporter, lease: Lease) Error!void {
        try self.bind();
        try self.validateLease(lease);
        if (self.poisoned) return error.ExportFailed;
        if (self.encoded_terminal_success and self.storage.failure.load(.acquire) != .none) {
            self.failExport();
            return error.ExportFailed;
        }
        const batch = self.encoded orelse return error.LeaseNotEncoded;
        if (self.write_offset != 0 and self.write_offset != batch.byteCount()) return error.PartialWrite;
        const next_offset = std.math.add(u64, self.stream_offset, @intCast(batch.byteCount())) catch {
            self.failExport();
            return error.CounterOverflow;
        };
        if (self.write_offset != batch.byteCount()) self.writes_confirmed = false;
        if (lease.kind == .terminal) self.terminal_hash = batch.chunk_hash;
        self.releaseLease(lease, true);
        self.stream_offset = next_offset;
        self.preamble_accepted = true;
    }

    /// A manual ownership-only ack cannot produce this confirmed-write receipt.
    /// Keep failed/uncertain outputs private and never publish or use them even
    /// if their raw bytes happen to pass framing validation. Host publication
    /// must be externally serialized with failure/finalization and use private
    /// staging plus a no-replace commit; this module performs no publication.
    pub fn completion(self: *Exporter) Error!ExportCompletion {
        try self.bind();
        const status_value = self.storage.status();
        if (self.poisoned or status_value.reason != .none) return error.ExportFailed;
        if (!self.terminal_consumed or !status_value.producer_closed or !status_value.successful_end_staged or !status_value.terminal_acknowledged) return error.InvalidState;
        if (!self.writes_confirmed) return error.UnconfirmedWrites;
        return .{
            .storage_id = self.storage.storage_id,
            .incarnation = self.storage.incarnation,
            .storage_generation = self.storage.storage_generation,
            .recording_id = self.storage.preamble.recording_id,
            .terminal_hash = self.terminal_hash orelse return error.InvalidState,
            .total_inputs = status_value.retained_inputs,
            .total_schedule = status_value.retained_schedule,
            .total_frames = self.next_sequence,
            .total_bytes = self.stream_offset,
        };
    }

    /// At most one bounded sink call. WouldBlock/zero writes preserve immutable
    /// bytes, the exact lease, chain state, and byte offset for a later call.
    pub fn writeStep(self: *Exporter, sink: Sink, byte_budget: usize) Error!WriteProgress {
        try self.bind();
        if (byte_budget == 0) return error.InvalidLimits;
        if (self.poisoned) return .failed;
        const lease = if (self.active) |held| held else (try self.poll()) orelse return .idle;
        const batch = try self.encodeLease(lease);
        const suffix = batch.suffix(self.write_offset);
        const offered = suffix[0..@min(suffix.len, byte_budget)];
        const absolute_offset = std.math.add(u64, self.stream_offset, @intCast(self.write_offset)) catch {
            self.failExport();
            return .failed;
        };
        switch (sink.writeAt(sink.context, absolute_offset, offered)) {
            .would_block => return .would_block,
            .failed, .uncertain => {
                self.failExport();
                return .failed;
            },
            .written => |n| {
                if (n > offered.len) {
                    self.failExport();
                    return .failed;
                }
                if (n == 0) return .would_block;
                self.write_offset += n;
                if (self.write_offset == batch.byteCount()) {
                    try self.ack(lease);
                    return if (lease.kind == .terminal) .terminal_accepted else .frame_accepted;
                }
                return .progress;
            },
        }
    }

    /// Abandon an unusable artifact; never retry unknown-offset bytes. Control
    /// must call serviceFailure before discardRemaining can release the tail.
    pub fn abandonArtifact(self: *Exporter) Error!void {
        try self.bind();
        self.failExport();
        if (self.active) |lease| self.releaseLease(lease, false);
    }

    /// Explicit failure-only ownership cleanup, bounded by 4 cells + terminal.
    /// Not an acknowledgement and never makes terminal_acknowledged true.
    pub fn discardRemaining(self: *Exporter) Error!void {
        try self.bind();
        if (self.storage.failure.load(.acquire) == .none or !self.storage.closed.load(.acquire)) return error.InvalidState;
        self.poisoned = true;
        if (self.active) |lease| self.releaseLease(lease, false);
        for (0..data_cell_count + 1) |_| {
            const lease = (try self.pollOwned()) orelse return;
            self.releaseLease(lease, false);
        }
    }

    pub fn deinit(self: *Exporter) Error!void {
        try self.bind();
        if (self.active != null or !self.storage.closed.load(.acquire) or !self.terminal_consumed) return error.InUse;
        self.detached = true;
        self.storage.exporter_attached.store(false, .release);
    }

    fn bind(self: *Exporter) Error!void {
        if (self.detached or !self.storage.isBound()) return error.InvalidState;
        if (self.bound_address == 0) self.bound_address = @intFromPtr(self);
        if (self.bound_address != @intFromPtr(self)) return error.InvalidIdentity;
        const owner = self.storage.exporter_address.load(.acquire);
        if (owner == 0) {
            if (self.storage.exporter_address.cmpxchgStrong(0, self.bound_address, .acq_rel, .acquire)) |other| {
                if (other != self.bound_address) return error.InvalidIdentity;
            }
        } else if (owner != self.bound_address) return error.InvalidIdentity;
    }
    fn pollOwned(self: *Exporter) Error!?Lease {
        if (self.terminal_consumed) return null;
        const index: usize = @intCast(self.next_sequence % data_cell_count);
        const cell = &self.storage.cells[index];
        // Only this exporter can transition READY to LEASED. Producer only
        // reuses a cell after observing our release-store FREE.
        if (cell.state.load(.acquire) == .ready) {
            if (cell.sequence != self.next_sequence) return error.InvalidOrder;
            cell.state.store(.leased, .monotonic);
            const lease = self.makeLease(.data, index, cell.generation);
            self.active = lease;
            return lease;
        }
        if (self.storage.terminal.state.load(.acquire) == .ready and self.storage.terminal.value.data_chunk_count == self.next_sequence) {
            self.storage.terminal.state.store(.leased, .monotonic);
            const lease = self.makeLease(.terminal, data_cell_count, 1);
            self.active = lease;
            return lease;
        }
        return null;
    }
    fn makeLease(self: *const Exporter, kind: Kind, index: usize, generation: u64) Lease {
        return .{
            .storage_address = @intFromPtr(self.storage),
            .storage_id = self.storage.storage_id,
            .incarnation = self.storage.incarnation,
            .storage_generation = self.storage.storage_generation,
            .recording_id = self.storage.preamble.recording_id,
            .kind = kind,
            .cell_index = index,
            .cell_generation = generation,
            .sequence = self.next_sequence,
        };
    }
    fn validateLease(self: *const Exporter, lease: Lease) Error!void {
        const active = self.active orelse return error.StaleLease;
        if (!std.meta.eql(active, lease) or lease.sequence != self.next_sequence or lease.storage_address != @intFromPtr(self.storage)) return error.StaleLease;
        switch (lease.kind) {
            .data => {
                if (lease.cell_index >= data_cell_count) return error.StaleLease;
                const cell = &self.storage.cells[lease.cell_index];
                if (cell.state.load(.acquire) != .leased or cell.generation != lease.cell_generation or cell.sequence != lease.sequence) return error.StaleLease;
            },
            .terminal => if (lease.cell_index != data_cell_count or self.storage.terminal.state.load(.acquire) != .leased or self.storage.terminal.value.data_chunk_count != lease.sequence) return error.StaleLease,
        }
    }
    fn releaseLease(self: *Exporter, lease: Lease, acknowledged: bool) void {
        // Every call site already owns the exact active lease. Reserve its
        // sequence addition at producer acquisition; no wrapping counters.
        self.next_sequence += 1;
        self.active = null;
        self.encoded = null;
        self.encoded_terminal_success = false;
        self.write_offset = 0;
        switch (lease.kind) {
            .data => self.storage.cells[lease.cell_index].state.store(.free, .release),
            .terminal => {
                self.terminal_consumed = true;
                if (acknowledged) self.storage.terminal_acked.store(true, .release);
                self.storage.terminal.state.store(.free, .release);
            },
        }
    }
    fn failExport(self: *Exporter) void {
        self.poisoned = true;
        self.storage.signalExportFailure();
    }
};

pub const RamUsage = struct { storage_bytes: usize, scratch_bytes: usize, exporter_bytes: usize, total_owned_bytes: usize };
pub fn ramUsage() RamUsage {
    return .{ .storage_bytes = @sizeOf(Storage), .scratch_bytes = @sizeOf(Scratch), .exporter_bytes = @sizeOf(Exporter), .total_owned_bytes = @sizeOf(Storage) + @sizeOf(Scratch) + @sizeOf(Exporter) };
}

fn requireOwned(comptime T: type) void {
    switch (@typeInfo(T)) {
        .int, .bool, .@"enum", .void => {},
        .array => |info| requireOwned(info.child),
        .optional => |info| requireOwned(info.child),
        .@"struct" => |info| inline for (info.fields) |field| requireOwned(field.type),
        .@"union" => |info| {
            if (info.tag_type == null) @compileError("chunk cells require owned tagged records");
            inline for (info.fields) |field| requireOwned(field.type);
        },
        else => @compileError("chunk cells cannot borrow pointers or resources"),
    }
}
comptime {
    @setEvalBranchQuota(30_000);
    requireOwned(Record);
    if (records_per_cell * (schema.max_record_bytes + 4) > chunks.max_payload_bytes) @compileError("retained records must fit wire payload");
}
