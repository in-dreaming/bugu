//! Explicit finite-window V1 rendering through the single public runtime owner.
//! This is not a complete recorder or replayer. Unsupported capabilities fail
//! through their real owner; compatibility preview lives in preview.zig.
const std = @import("std");
pub const audio = @import("bugu_audio");
pub const music = audio.music;
pub const source = @import("preview_source.zig");
pub const configuration = @import("preview_config.zig");
pub const quantum_frames: u32 = 256;
pub const max_frames: u32 = quantum_frames * 2048;
pub const max_requests: usize = 32;
pub const max_receipts: usize = max_requests * 2;
pub const max_worker_steps: usize = 64;
pub const max_load_steps: usize = 128;
pub const max_cleanup_steps: usize = 128;
pub const Request = struct { frame: u32, request: music.MusicRequest };
pub const Submission = struct { input_request_id: u64, frame: u32, ticket: music.MusicRequestTicketV1 };
pub const Options = struct {
    frame_count: u32,
    context: u64 = 1,
    seed: u64 = 1,
    /// Optional by-value public config; binding slices are copied synchronously
    /// into independent owned storage before Session or Capture can retain them.
    /// Explicit identity must agree with context/seed; finite constraints apply.
    runtime_config: ?music.MusicRuntimeConfigV1 = null,
    source_fault: source.Fault = .{},
    fail_first_capture_read: bool = false,
};
pub const Stage = enum { input, create, load, capture, shutdown, final_teardown, package };
pub const ClosePhase = enum { active, shutdown, final_teardown, provider_release };
/// Explicit author-host selection. Snapshot profiles alone never select V2.
pub const SourceMode = enum { legacy_v1, stream_reload_v2 };
/// Successful provider destruction evidence, collected only after the public
/// acknowledgement/shutdown frontier. Counters alone do not grant custody.
pub const ProviderReleaseV2 = struct {
    providers: usize = 0,
    counts: @FieldType(music.BankSourceProviderV2, "counts") = .{},
    pub fn release(self: *ProviderReleaseV2, slot: *?*music.BankSourceProviderV2) !void {
        const provider = slot.* orelse return;
        if (provider.binding != null or provider.counts.live != 0) return error.DrainPending;
        if (provider.counts.opened != provider.counts.closed or provider.counts.binds != provider.counts.unbound) return error.ProviderOwnershipMismatch;
        var next = self.*;
        next.providers = try std.math.add(usize, next.providers, 1);
        inline for (std.meta.fields(@TypeOf(next.counts))) |field| {
            @field(next.counts, field.name) = try std.math.add(usize, @field(next.counts, field.name), @field(provider.counts, field.name));
        }
        try provider.destroy();
        slot.* = null;
        self.* = next;
    }
};
pub const ShutdownReport = struct {
    sample_leases: u64,
    live_instances: u64,
    provider: source.Counts,
    released_v2: ProviderReleaseV2 = .{},
    /// Observations collected during drain, beyond the captured PCM window.
    shutdown_receipts: usize,
    control_tick_calls: usize,
    render_call_sequence: u64,
};
pub const Failure = struct {
    stage: Stage = .input,
    first_error: ?anyerror = null,
    first_provider_error: ?source.ProviderError = null,
    load_failure: ?music.MusicRuntimeFailureV1 = null,
    rejected_request_id: ?u64 = null,
    rejected_ticket_id: ?u64 = null,
    rejected_reason: ?music.MusicRuntimeFailureV1 = null,
    cleanup_phase: ?ClosePhase = null,
    cleanup_error: ?anyerror = null,
    /// Never serialize this pointer or free its allocator/provider underneath it.
    retained_session: ?*Session = null,
    pub fn retryCleanup(self: *Failure) !ShutdownReport {
        const session = self.retained_session orelse return error.InvalidState;
        const result = session.close() catch |err| {
            self.cleanup_error = err;
            self.cleanup_phase = session.close_phase;
            return err;
        };
        self.retained_session = null;
        self.cleanup_error = null;
        self.cleanup_phase = null;
        return result;
    }
};
pub const Capture = struct {
    allocator: std.mem.Allocator,
    options: Options,
    owned_config: *configuration.Owned,
    pcm: []f32,
    receipts: []music.MusicRuntimeReceiptV1,
    submissions: []Submission,
    final_snapshot: music.MusicRuntimeStatusV1,
    bank_content_hash: [32]u8,
    asset_generation: u64,
    pub fn pcmHash(self: *const Capture) [32]u8 {
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        for (self.pcm) |sample| {
            var bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &bytes, @bitCast(sample), .little);
            hash.update(&bytes);
        }
        return hash.finalResult();
    }
    pub fn encodeWav(self: *const Capture, allocator: std.mem.Allocator) ![]u8 {
        const count = try std.math.mul(usize, self.options.frame_count, 4);
        const buffer = try allocator.alloc(u8, try std.math.add(usize, count, 128));
        defer allocator.free(buffer);
        var writer = std.Io.Writer.fixed(buffer);
        try audio.device.writeWavHeader(&writer, self.options.frame_count, 48_000, audio.device.channel_layout.stereo);
        try audio.device.writeWavSamples(&writer, self.pcm);
        return allocator.dupe(u8, writer.buffered());
    }
    pub fn deinit(self: *Capture) void {
        self.allocator.free(self.pcm);
        self.allocator.free(self.receipts);
        self.allocator.free(self.submissions);
        self.owned_config.destroy();
        self.* = undefined;
    }
};
pub const Product = struct {
    capture: Capture,
    compiled_artifact_sha256: [32]u8,
    shutdown: ShutdownReport,
    complete_recording: bool = false,
    replay_verified: bool = false,
    pub fn deinit(self: *Product) void {
        self.capture.deinit();
        self.* = undefined;
    }
};
pub const Session = struct {
    allocator: std.mem.Allocator,
    control: *audio.ControlRuntime,
    renderer: *audio.RuntimeRenderer,
    owner: *music.MusicRuntime,
    backend: audio.RuntimeOfflineBackend,
    provider: *source.Provider,
    /// Immutable session selection. In V2 mode provider is a metadata-only V1
    /// bank owner, never passed to the runtime, with separately counted storage.
    source_mode: SourceMode = .legacy_v1,
    initial_provider_v2: ?*music.BankSourceProviderV2 = null,
    owned_config: *configuration.Owned,
    bank: ?music.MusicBankRefV1 = null,
    close_phase: ClosePhase = .active,
    shutdown_receipts: usize = 0,
    control_tick_calls: usize = 0,
    final_report: ?ShutdownReport = null,
    fn create(allocator: std.mem.Allocator, compiled: []const u8, options: Options) !*Session {
        const owned_config = try configuration.Owned.create(allocator, try configuration.resolve(options.context, options.seed, options.runtime_config));
        errdefer owned_config.destroy();
        const self = try allocator.create(Session);
        errdefer allocator.destroy(self);
        const provider = try source.Provider.create(allocator, compiled, options.source_fault);
        errdefer provider.destroy() catch unreachable; // No token can exist before load.
        const control = try audio.ControlRuntime.create(allocator);
        errdefer allocator.destroy(control);
        const renderer = try allocator.create(audio.RuntimeRenderer);
        errdefer allocator.destroy(renderer);
        renderer.* = audio.RuntimeRenderer.init(control, 48_000);
        const backend = try audio.RuntimeOfflineBackend.init(renderer, quantum_frames, 2);
        const owner = try music.MusicRuntime.createV1(allocator, control, renderer, owned_config.value);
        // No fallible operation follows owner attachment in this constructor.
        self.* = .{ .allocator = allocator, .control = control, .renderer = renderer, .owner = owner, .backend = backend, .provider = provider, .owned_config = owned_config };
        return self;
    }
    fn load(self: *Session, compiled: []const u8, failure: *Failure) !void {
        const ticket = if (self.provider.stream_count == 0) try self.owner.loadBank(compiled) else try self.owner.loadBankWithSources(compiled, self.provider.provider());
        for (0..max_load_steps) |_| {
            _ = try self.owner.workerOneV1();
            const status = try self.owner.pollLoad(ticket);
            switch (status) {
                .pending => {},
                .failed => |reason| {
                    failure.load_failure = reason;
                    try self.owner.acknowledgeLoad(ticket);
                    return error.LoadFailed;
                },
                .ready => |value| {
                    self.bank = value.bank;
                    try self.owner.acknowledgeLoad(ticket);
                    return;
                },
            }
        }
        return error.LoadPending;
    }
    fn worker(self: *Session) !void {
        for (0..max_worker_steps) |_| if (!try self.owner.workerOneV1()) break;
    }
    fn collect(self: *Session, receipts: *std.ArrayList(music.MusicRuntimeReceiptV1), submissions: []const Submission, failure: *Failure) !void {
        while (try self.owner.pollReceiptV1()) |receipt| {
            if (receipts.items.len == max_receipts) return error.ResourceLimitExceeded;
            receipts.appendAssumeCapacity(receipt);
            if (receipt.event == .terminal and receipt.event.terminal == .rejected) {
                failure.rejected_ticket_id = receipt.ticket.request_id;
                for (submissions) |submitted| if (std.meta.eql(submitted.ticket, receipt.ticket)) {
                    failure.rejected_request_id = submitted.input_request_id;
                    break;
                };
                failure.rejected_reason = receipt.event.terminal.rejected;
                return error.RequestRejected;
            }
        }
    }
    fn tick(self: *Session) !void {
        self.control_tick_calls += 1;
        _ = try self.owner.controlTickV1(audio.runtime.max_control_drain);
    }
    fn capture(self: *Session, options: Options, requests: []const Request, failure: *Failure) !Capture {
        const allocator = self.allocator;
        const owned_config = try self.owned_config.clone();
        errdefer owned_config.destroy();
        var captured_options = options;
        captured_options.runtime_config = owned_config.value;
        const pcm = try allocator.alloc(f32, try std.math.mul(usize, options.frame_count, 2));
        errdefer allocator.free(pcm);
        var receipts: std.ArrayList(music.MusicRuntimeReceiptV1) = .empty;
        defer receipts.deinit(allocator);
        var submissions: std.ArrayList(Submission) = .empty;
        defer submissions.deinit(allocator);
        // All fallible observation storage is reserved before admission.
        try receipts.ensureTotalCapacity(allocator, max_receipts);
        try submissions.ensureTotalCapacity(allocator, requests.len);
        if (options.fail_first_capture_read) self.provider.fault.fail_read_call = self.provider.counts.read_attempts + 1;
        var request_at: usize = 0;
        var frame: u32 = 0;
        while (true) {
            // Startup is adopted before this point. Worker facts are accepted
            // only by the following real integrated tick and visibility gate.
            try self.worker();
            while (request_at < requests.len and requests[request_at].frame == frame) : (request_at += 1) {
                const request = requests[request_at].request;
                const ticket = if (request_at == 0)
                    try self.owner.start(self.bank.?, request.payload.set_state.state)
                else
                    try self.owner.submitV1(self.bank.?, request.payload);
                submissions.appendAssumeCapacity(.{ .input_request_id = request.request_id, .frame = requests[request_at].frame, .ticket = ticket });
            }
            self.tick() catch |err| {
                // A real tick may publish its rejection before returning an
                // error. Preserve both facts without replacing the tick error.
                self.collect(&receipts, submissions.items, failure) catch {};
                return err;
            };
            try self.collect(&receipts, submissions.items, failure);
            if (frame == options.frame_count) break;
            try self.backend.adapter.renderChecked(pcm[@as(usize, frame) * 2 ..][0 .. quantum_frames * 2], quantum_frames);
            frame += quantum_frames;
        }
        if (request_at != requests.len) return error.InvalidOrder;
        // Submission is not application: a same-frame batch may still have
        // queued context operations at this finite capture frontier. Require
        // each context's one successful terminal in captured receipts, never
        // extending time or counting cleanup observations as preview success.
        for (requests, submissions.items) |request, submitted| {
            if (request.request.payload != .set_context) continue;
            var terminals: usize = 0;
            var applied: usize = 0;
            for (receipts.items) |receipt| {
                if (!std.meta.eql(receipt.ticket, submitted.ticket) or receipt.event != .terminal) continue;
                terminals += 1;
                if (receipt.event.terminal == .control_applied) applied += 1;
            }
            if (terminals != 1 or applied != 1) return error.IncompleteContextRequest;
        }
        const snapshot = try self.owner.snapshotV1();
        const owned_receipts = try receipts.toOwnedSlice(allocator);
        errdefer allocator.free(owned_receipts);
        const owned_submissions = try submissions.toOwnedSlice(allocator);
        return .{ .allocator = allocator, .options = captured_options, .owned_config = owned_config, .pcm = pcm, .receipts = owned_receipts, .submissions = owned_submissions, .final_snapshot = snapshot, .bank_content_hash = self.owner.bankHash(), .asset_generation = self.bank.?.asset_generation };
    }
    pub fn close(self: *Session) !ShutdownReport {
        if (self.close_phase == .active) self.close_phase = .shutdown;
        if (self.close_phase == .shutdown) {
            var scratch: [quantum_frames * 2]f32 = undefined;
            for (0..max_cleanup_steps) |_| {
                self.owner.shutdown() catch |err| switch (err) {
                    error.CommandQueueFull => {},
                    else => return err,
                };
                try self.worker();
                try self.tick();
                while (try self.owner.pollReceiptV1()) |_| self.shutdown_receipts += 1;
                const status = try self.owner.drainStatusV1();
                if (status.queued_requests == 0 and status.active_producers == 0 and status.in_flight_requests == 0 and status.load_transactions == 0 and !status.worker_active and status.pending_plans == 0 and status.active_music_groups == 0 and status.retired_music_groups == 0 and status.live_instances == 0 and status.snapshot_readers == 0 and status.control_drained) {
                    self.close_phase = .final_teardown;
                    break;
                }
                try self.backend.adapter.renderChecked(&scratch, quantum_frames);
            }
            if (self.close_phase != .final_teardown) return error.DrainPending;
        }
        // destroyQuiescent may have destroyed Control before returning pending
        // provider close. This phase never calls render, tick, status or shutdown.
        if (self.close_phase == .final_teardown) {
            for (0..max_cleanup_steps) |_| {
                const report = self.owner.destroyQuiescent() catch |err| switch (err) {
                    error.DrainPending => {
                        _ = try self.owner.workerOneV1();
                        continue;
                    },
                    else => return err,
                };
                self.final_report = .{ .sample_leases = report.sample_leases, .live_instances = report.live_instances, .provider = self.provider.counts, .shutdown_receipts = self.shutdown_receipts, .control_tick_calls = self.control_tick_calls, .render_call_sequence = self.renderer.callObservation().sequence };
                // The owner pointer is dead now. No retry can touch it again,
                // even if the host provider's final ownership assertion fails.
                self.close_phase = .provider_release;
                break;
            }
            if (self.close_phase != .provider_release) return error.DrainPending;
        }
        // Optional V2 release can fail. Keep the mandatory V1 owner alive until
        // it succeeds, so provider-release retries never touch a freed owner.
        if (self.final_report == null) return error.InvalidState;
        try self.final_report.?.released_v2.release(&self.initial_provider_v2);
        const result = self.final_report.?;
        if (result.provider.live != 0 or result.provider.opened != result.provider.closed) return error.ProviderOwnershipMismatch;
        try self.provider.destroy();
        const allocator = self.allocator;
        allocator.destroy(self.renderer);
        allocator.destroy(self.control);
        self.owned_config.destroy();
        allocator.destroy(self);
        return result;
    }
};
fn validate(options: Options, requests: []const Request) !void {
    if (options.context == 0 or options.frame_count == 0 or options.frame_count > max_frames or options.frame_count % quantum_frames != 0 or requests.len == 0 or requests.len > max_requests) return error.InvalidArgument;
    const runtime_config = try configuration.resolve(options.context, options.seed, options.runtime_config);
    if (requests[0].frame != 0 or requests[0].request.payload != .set_state or requests[0].request.payload.set_state.priority != 0) return error.InvalidArgument;
    var previous_frame: u32 = 0;
    var previous_id: u64 = 0;
    for (requests) |request| {
        if (request.frame >= options.frame_count or request.frame % quantum_frames != 0 or request.frame < previous_frame) return error.InvalidArgument;
        try request.request.validateAfter(previous_id, .offline);
        switch (request.request.payload) {
            .set_state, .pause, .@"resume" => {},
            .set_context => {
                // Later Control input only; the first selector still starts
                // from authored context. Public validation above owns IDs and
                // finite values; the runtime owns typed bank admission.
                if (request.frame == 0) return error.InvalidArgument;
                if (runtime_config.crossfade.bindings.len != 0) return error.UnsupportedOperation;
            },
            .set_parameter => |parameter| {
                // This finite consumer supports the public audible layer-gain
                // slice only. The public request validation above owns finite
                // value/ID checks; the real runtime owns bank/curve admission.
                // Never infer a writer from a parameter or layer name.
                const bindings = runtime_config.layer_gain.bindings;
                for (bindings) |binding| {
                    if (binding.parameter == parameter.parameter) break;
                } else return error.UnboundPreviewParameter;
            },
            .stop => |mode| if (mode != .emergency_ramp) return error.UnsupportedOperation,
            else => return error.UnsupportedOperation,
        }
        previous_frame = request.frame;
        previous_id = request.request.request_id;
    }
}
fn cleanup(session: *?*Session, failure: *Failure) void {
    const self = session.* orelse return;
    session.* = null;
    if (self.close()) |_| {} else |err| {
        failure.retained_session = self;
        failure.cleanup_error = err;
        failure.cleanup_phase = self.close_phase;
    }
}
pub fn render(allocator: std.mem.Allocator, compiled: []const u8, options: Options, requests: []const Request, failure: *Failure) anyerror!Product {
    if (failure.retained_session != null) return error.DrainPending;
    failure.* = .{};
    return renderOwned(allocator, compiled, options, requests, failure) catch |err| {
        // Keep operation error capture outside the ownership cleanup scope.
        // Cleanup may retain the session but must not replace this first cause.
        if (failure.first_error == null) failure.first_error = err;
        return err;
    };
}
fn renderOwned(allocator: std.mem.Allocator, compiled: []const u8, options: Options, requests: []const Request, failure: *Failure) anyerror!Product {
    try validate(options, requests);
    failure.stage = .create;
    var current: ?*Session = try Session.create(allocator, compiled, options);
    errdefer cleanup(&current, failure);
    failure.stage = .load;
    current.?.load(compiled, failure) catch |err| {
        failure.first_provider_error = current.?.provider.first_error;
        failure.first_error = if (failure.first_provider_error) |first| first else err;
        return err;
    };
    failure.stage = .capture;
    var captured = current.?.capture(options, requests, failure) catch |err| {
        failure.first_provider_error = current.?.provider.first_error;
        failure.first_error = if (failure.first_provider_error) |first| first else err;
        return err;
    };
    errdefer captured.deinit();
    failure.stage = .shutdown;
    const self = current.?;
    current = null;
    const shutdown = self.close() catch |err| {
        failure.first_provider_error = self.provider.first_error;
        failure.first_error = if (failure.first_provider_error) |first| first else err;
        failure.stage = if (self.close_phase == .shutdown) .shutdown else .final_teardown;
        failure.retained_session = self;
        failure.cleanup_error = err;
        failure.cleanup_phase = self.close_phase;
        return err;
    };
    return .{ .capture = captured, .compiled_artifact_sha256 = music.trace.replay.hashPcm(compiled), .shutdown = shutdown };
}
