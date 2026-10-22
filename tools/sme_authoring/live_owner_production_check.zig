//! Compile-only production specialization. No executable entry point or runtime
//! scenario. Independent exports force method bodies without an unsafe sequence.
//! These symbols are qualification probes, not a supported public C interface.
const std = @import("std");
const live = @import("sme-author-live-owner");
const Snapshot = live.mailbox.StatusCell(live.Status).Versioned;

comptime {
    if (@import("builtin").is_test) @compileError("This qualification requires a non-test static library");
    if (@FieldType(live.Options, "test_setup") != void or
        @FieldType(live.Options, "test_tick_outcome") != void)
        @compileError("Production options must not retain test hook storage");
}

export fn sme_author_live_create_check(launch: *const live.Launch, io: *const std.Io, out: *?*live.Host) c_int {
    out.* = live.Host.create(launch.*, .{ .io = io.* }) catch |err| return @intCast(@intFromError(err));
    return 0;
}
export fn sme_author_live_recovery_create_check(launch: *const live.Launch, io: *const std.Io, out: *?*live.Host) c_int {
    out.* = live.Host.create(launch.*, .{ .io = io.*, .recovery = .restart_at_bar }) catch |err| return @intCast(@intFromError(err));
    return 0;
}
export fn sme_author_live_recovery_request_check(host: *live.Host, identity: *const live.Identity, device_epoch: u64, out: *live.Mailbox.Command) c_int {
    out.* = host.requestRecovery(identity.*, device_epoch) catch |err| return @intCast(@intFromError(err));
    return 0;
}
export fn sme_author_live_identity_check(host: *const live.Host, out: *live.Identity) void {
    out.* = host.identity();
}
export fn sme_author_live_submit_check(host: *live.Host, identity: *const live.Identity, stop: bool, out: *live.Mailbox.Command) c_int {
    out.* = host.submit(identity.*, if (stop) .stop else .play) catch |err| return @intCast(@intFromError(err));
    return 0;
}
export fn sme_author_live_status_check(host: *live.Host, out: *Snapshot) bool {
    out.* = host.readStatus() orelse return false;
    return true;
}
export fn sme_author_live_event_check(host: *live.Host, out: *live.Mailbox.Event) bool {
    out.* = host.popEvent() orelse return false;
    return true;
}
export fn sme_author_live_ack_terminal_check(host: *live.Host, command_id: u64) c_int {
    host.acknowledgeTerminal(command_id) catch |err| return @intCast(@intFromError(err));
    return 0;
}
export fn sme_author_live_close_check(host: *live.Host, epoch: u64) c_int {
    host.requestClose(epoch) catch |err| return @intCast(@intFromError(err));
    return 0;
}
export fn sme_author_live_is_closed_check(host: *live.Host) bool {
    return host.isClosed();
}
export fn sme_author_live_ack_closed_check(host: *live.Host) c_int {
    host.acknowledgeClosed() catch |err| return @intCast(@intFromError(err));
    return 0;
}
export fn sme_author_live_join_check(host: *live.Host) c_int {
    host.join() catch |err| return @intCast(@intFromError(err));
    return 0;
}
export fn sme_author_live_destroy_check(host: *live.Host) c_int {
    host.destroy() catch |err| return @intCast(@intFromError(err));
    return 0;
}

// Profile 9 production specialization. Caller-owned pointers avoid constructing
// large Recorder/Driver values on a probe stack. These independent exports are
// compiled into this non-installed static library only: no probe is invoked,
// no native threads are started, and no probe allocation is performed by the
// qualification build. Each body forces the real production method to compile.
const recording = live.semantic_recording;
const replay = live.semantic_replay;
const semantic_format = recording.format;

export fn sme_author_live_semantic_record_init_check(recorder: *recording.Recorder, identity: *const semantic_format.Identity, corpus: [*]u8, corpus_len: usize) c_int {
    recorder.init(identity.*, corpus[0..corpus_len]) catch |err| return @intCast(@intFromError(err));
    return 0;
}
export fn sme_author_live_semantic_record_drain_check(recorder: *recording.Recorder, drained: *bool) c_int {
    drained.* = recorder.drain() catch |err| return @intCast(@intFromError(err));
    return 0;
}
export fn sme_author_live_semantic_record_finish_check(recorder: *recording.Recorder, bytes: *[*]const u8, length: *usize) c_int {
    const result = recorder.finish() catch |err| return @intCast(@intFromError(err));
    bytes.* = result.ptr;
    length.* = result.len;
    return 0;
}
export fn sme_author_live_semantic_replay_init_check(driver: *replay.Driver, reader: *const semantic_format.Reader, identity: *const semantic_format.Identity, io: *const std.Io) c_int {
    driver.init(reader, identity.*, io.*) catch |err| return @intCast(@intFromError(err));
    return 0;
}
export fn sme_author_live_semantic_replay_run_check(driver: *replay.Driver, launch: *const live.Launch, device: *const live.audio.device.DeviceConfig, report: *replay.Report) c_int {
    report.* = driver.run(launch.*, device.*) catch |err| return @intCast(@intFromError(err));
    return 0;
}

export fn sme_author_live_semantic_stream_init_check(recorder: *recording.Recorder, identity: *const semantic_format.Identity, sink: *const semantic_format.StreamSink, byte_cap: u64, resident_staging_bytes: usize) c_int {
    recorder.initStreaming(identity.*, sink.*, byte_cap, resident_staging_bytes) catch |err| return @intCast(@intFromError(err));
    return 0;
}
export fn sme_author_live_semantic_stream_drain_check(recorder: *recording.Recorder, drained: *bool) c_int {
    drained.* = recorder.drainStreaming() catch |err| return @intCast(@intFromError(err));
    return 0;
}
export fn sme_author_live_semantic_stream_finish_check(recorder: *recording.Recorder, seal: *semantic_format.StreamSeal) c_int {
    seal.* = recorder.finishStreaming() catch |err| return @intCast(@intFromError(err));
    return 0;
}
