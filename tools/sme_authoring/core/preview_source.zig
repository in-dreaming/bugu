//! Offline host byte provider over a retained, ordinarily loaded compiled bank.
//! No codec, readiness, stream cursor or runtime ownership is implemented here.
const std = @import("std");
const bank = @import("sme-bank");
const music = @import("bugu_audio").music;
pub const max_sources = 48;
pub const ProviderError = music.MusicSourceProviderV1.Error;
pub const Fault = struct {
    fail_open_call: ?usize = null,
    fail_read_call: ?usize = null,
    fail_close_call: ?usize = null,
    fail_close: bool = false,
};
pub const Counts = struct {
    open_attempts: usize = 0,
    read_attempts: usize = 0,
    close_attempts: usize = 0,
    opened: usize = 0,
    closed: usize = 0,
    live: usize = 0,
};
/// Passive source boundaries, including raw loader access before Service exists.
/// All slices are consumed by the native provider, never supplied by observers.
/// Sink/context are immutable through the last actual source close and destroy.
/// Callbacks copy bounded facts only: no allocation, IO, waits, locks or reentry.
pub const SemanticCall = union(enum) {
    open: music.MusicSourceProviderV1.Request,
    read: struct { token: u64, offset: u64, length: usize },
    close: u64,
};
pub const SemanticEvent = union(enum) {
    load_begin: struct { source_hash: [32]u8, source_bytes: usize },
    load_return: union(enum) {
        loaded: struct { bank_hash: [32]u8, generation: u64, streams: usize },
        failure: anyerror,
    },
    enter: struct { call: u64, operation: SemanticCall },
    result: struct { call: u64, value: union(enum) { opened: music.MusicSourceProviderV1.Opened, read_hash: [32]u8, done, failure: ProviderError } },
    end: struct { call: u64, failed: bool },
};
pub const SemanticSink = struct { context: *anyopaque, emit: *const fn (*anyopaque, SemanticEvent) void };
pub const Provider = struct {
    allocator: std.mem.Allocator,
    loaded: bank.MusicBank,
    /// Sound indices, retained metadata and encoded bytes are immutable. Only
    /// the serialized Worker callbacks mutate this bounded token ledger.
    sounds: [max_sources]u32 = undefined,
    open_tokens: [max_sources]bool = @splat(false),
    ever_opened: [max_sources]bool = @splat(false),
    stream_count: usize = 0,
    counts: Counts = .{},
    fault: Fault = .{},
    first_error: ?music.MusicSourceProviderV1.Error = null,
    semantic: ?SemanticSink = null,
    semantic_calls: u64 = 0,
    pub fn create(allocator: std.mem.Allocator, compiled: []const u8, fault: Fault) !*Provider {
        return createObserved(allocator, compiled, fault, null);
    }
    pub fn createObserved(allocator: std.mem.Allocator, compiled: []const u8, fault: Fault, semantic: ?SemanticSink) !*Provider {
        if (semantic) |sink| {
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(compiled, &digest, .{});
            sink.emit(sink.context, .{ .load_begin = .{ .source_hash = digest, .source_bytes = compiled.len } });
        }
        errdefer |err| if (semantic) |sink| sink.emit(sink.context, .{ .load_return = .{ .failure = err } });
        var loaded = try bank.MusicBank.load(allocator, compiled);
        errdefer loaded.deinit();
        const self = try allocator.create(Provider);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .loaded = loaded, .fault = fault, .semantic = semantic };
        for (loaded.tables.sounds, 0..) |sound, index| if (sound.storage == .streaming) {
            if (self.stream_count == max_sources) return error.ResourceLimitExceeded;
            self.sounds[self.stream_count] = @intCast(index);
            self.stream_count += 1;
        };
        if (semantic) |sink| sink.emit(sink.context, .{ .load_return = .{ .loaded = .{ .bank_hash = loaded.content_hash, .generation = loaded.metadata.generation, .streams = self.stream_count } } });
        return self;
    }
    /// One successful open per sound for this provider lifetime. Closed token
    /// values are never reincarnated; a new session owns a new provider.
    pub fn provider(self: *Provider) music.MusicSourceProviderV1 {
        return .{ .context = self, .open = open, .read_at = read, .close = close };
    }
    /// Call only after the real runtime has acknowledged all source closes.
    pub fn destroy(self: *Provider) !void {
        if (self.counts.live != 0) return error.DrainPending;
        self.loaded.deinit();
        const allocator = self.allocator;
        allocator.destroy(self);
    }
    fn failed(self: *Provider, err: music.MusicSourceProviderV1.Error) music.MusicSourceProviderV1.Error {
        if (self.first_error == null) self.first_error = err;
        return err;
    }
    fn semanticBegin(self: *Provider, operation: SemanticCall) u64 {
        const sink = self.semantic orelse return 0;
        // Zero is an explicit incomplete sentinel; counter health never affects IO.
        const id = if (self.semantic_calls == std.math.maxInt(u64)) 0 else self.semantic_calls + 1;
        if (id != 0) self.semantic_calls = id;
        sink.emit(sink.context, .{ .enter = .{ .call = id, .operation = operation } });
        return id;
    }
    fn open(raw: *anyopaque, request: music.MusicSourceProviderV1.Request) ProviderError!music.MusicSourceProviderV1.Opened {
        const self: *Provider = @ptrCast(@alignCast(raw));
        const id = self.semanticBegin(.{ .open = request });
        var failure = true;
        defer if (self.semantic) |sink| sink.emit(sink.context, .{ .end = .{ .call = id, .failed = failure } });
        const value = openNative(raw, request) catch |err| {
            if (self.semantic) |sink| sink.emit(sink.context, .{ .result = .{ .call = id, .value = .{ .failure = err } } });
            return err;
        };
        if (self.semantic) |sink| sink.emit(sink.context, .{ .result = .{ .call = id, .value = .{ .opened = value } } });
        failure = false;
        return value;
    }
    fn read(raw: *anyopaque, token: u64, offset: u64, destination: []u8) ProviderError!void {
        const self: *Provider = @ptrCast(@alignCast(raw));
        const id = self.semanticBegin(.{ .read = .{ .token = token, .offset = offset, .length = destination.len } });
        var failure = true;
        defer if (self.semantic) |sink| sink.emit(sink.context, .{ .end = .{ .call = id, .failed = failure } });
        readNative(raw, token, offset, destination) catch |err| {
            if (self.semantic) |sink| sink.emit(sink.context, .{ .result = .{ .call = id, .value = .{ .failure = err } } });
            return err;
        };
        if (self.semantic) |sink| {
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(destination, &digest, .{});
            sink.emit(sink.context, .{ .result = .{ .call = id, .value = .{ .read_hash = digest } } });
        }
        failure = false;
    }
    fn close(raw: *anyopaque, token: u64) ProviderError!void {
        const self: *Provider = @ptrCast(@alignCast(raw));
        const id = self.semanticBegin(.{ .close = token });
        var failure = true;
        defer if (self.semantic) |sink| sink.emit(sink.context, .{ .end = .{ .call = id, .failed = failure } });
        closeNative(raw, token) catch |err| {
            if (self.semantic) |sink| sink.emit(sink.context, .{ .result = .{ .call = id, .value = .{ .failure = err } } });
            return err;
        };
        if (self.semantic) |sink| sink.emit(sink.context, .{ .result = .{ .call = id, .value = .done } });
        failure = false;
    }
    fn openNative(raw: *anyopaque, request: music.MusicSourceProviderV1.Request) music.MusicSourceProviderV1.Error!music.MusicSourceProviderV1.Opened {
        const self: *Provider = @ptrCast(@alignCast(raw));
        self.counts.open_attempts += 1;
        if (self.fault.fail_open_call == self.counts.open_attempts) return self.failed(error.SourceUnavailable);
        if (!std.mem.eql(u8, &request.bank_hash, &self.loaded.content_hash) or request.asset_generation != self.loaded.metadata.generation) return self.failed(error.InvalidSource);
        for (self.sounds[0..self.stream_count], 0..) |sound_index, index| {
            const sound = self.loaded.tables.sounds[sound_index];
            if (sound.key.id != request.sound_id) continue;
            if (self.ever_opened[index] or request.encoded_bytes != sound.blob_length or !std.mem.eql(u8, &request.encoded_hash, &sound.audio_hash)) return self.failed(error.InvalidSource);
            self.ever_opened[index] = true;
            self.open_tokens[index] = true;
            self.counts.opened += 1;
            self.counts.live += 1;
            return .{ .token = index + 1, .encoded_bytes = sound.blob_length };
        }
        return self.failed(error.SourceUnavailable);
    }
    fn indexFor(self: *Provider, token: u64) music.MusicSourceProviderV1.Error!usize {
        if (token == 0 or token > self.stream_count) return self.failed(error.InvalidSource);
        const index: usize = @intCast(token - 1);
        if (!self.open_tokens[index]) return self.failed(error.InvalidSource);
        return index;
    }
    fn readNative(raw: *anyopaque, token: u64, offset: u64, destination: []u8) music.MusicSourceProviderV1.Error!void {
        const self: *Provider = @ptrCast(@alignCast(raw));
        const index = try self.indexFor(token);
        self.counts.read_attempts += 1;
        if (self.fault.fail_read_call == self.counts.read_attempts) return self.failed(error.SourceReadFailed);
        const sound = self.loaded.tables.sounds[self.sounds[index]];
        if (offset > sound.blob_length or destination.len > sound.blob_length - offset) return self.failed(error.InvalidSource);
        const start = std.math.add(u64, sound.blob_offset, offset) catch return self.failed(error.InvalidSource);
        if (start > self.loaded.tables.blob.len or destination.len > self.loaded.tables.blob.len - start) return self.failed(error.InvalidSource);
        @memcpy(destination, self.loaded.tables.blob[@intCast(start)..][0..destination.len]);
    }
    fn closeNative(raw: *anyopaque, token: u64) music.MusicSourceProviderV1.Error!void {
        const self: *Provider = @ptrCast(@alignCast(raw));
        const index = try self.indexFor(token);
        self.counts.close_attempts += 1;
        // An injected failure leaves the exact token readable and retryable.
        if (self.fault.fail_close or self.fault.fail_close_call == self.counts.close_attempts) return self.failed(error.SourceCloseFailed);
        self.open_tokens[index] = false;
        self.counts.closed += 1;
        self.counts.live -= 1;
    }
};
