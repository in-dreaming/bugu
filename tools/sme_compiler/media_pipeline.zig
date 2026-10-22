//! TASK-010 source media composition. Offline/compiler only, with explicit I/O.
//! Produces media tables; subsequent musical passes and bank.validateIR remain
//! mandatory. A successful media result alone is not a validated whole bank.
const std = @import("std");
const builtin = @import("builtin");
const compiler = @import("sme-compiler");
const s = @import("sme-bank").schema;
const importer = @import("sme-import");
const quality = @import("sme-audio-quality");
const quality_record = @import("sme-quality-record");
const opus = @import("sme-opus");
const indexer = @import("sme-stream-index");
pub const Error = compiler.CompileError || importer.Error || quality.Error || error{ SourceReadFailed, UnsafeSourcePath, UnsupportedSourceFormat };

/// Returns caller-owned bytes allocated with the supplied allocator. Resolver
/// contexts must outlive the synchronous compile. There is no default resolver.
pub const SourceResolver = struct {
    context: *anyopaque,
    read: *const fn (*anyopaque, std.mem.Allocator, compiler.SoundSource, usize) Error![]u8,
};
/// Explicit caller-selected directory and I/O implementation. Every path
/// component is opened without following symlinks; no cwd/global I/O is used.
pub const DirectoryResolver = struct {
    io: std.Io,
    dir: std.Io.Dir,
    pub fn resolver(self: *DirectoryResolver) SourceResolver {
        return .{ .context = self, .read = read };
    }
    fn read(context: *anyopaque, allocator: std.mem.Allocator, source: compiler.SoundSource, max_bytes: usize) Error![]u8 {
        const self: *DirectoryResolver = @ptrCast(@alignCast(context));
        try validateRelativePath(source.path);
        var current = self.dir;
        var close_current = false;
        defer if (close_current) current.close(self.io);
        var parts = std.mem.splitScalar(u8, source.path, '/');
        var component = parts.next().?;
        while (parts.next()) |next| {
            const child = current.openDir(self.io, component, .{ .follow_symlinks = false }) catch return error.SourceReadFailed;
            if (close_current) current.close(self.io);
            current = child;
            close_current = true;
            component = next;
        }
        const file = try openSourceLeaf(current, self.io, component);
        defer file.close(self.io);
        const stat = file.stat(self.io) catch return error.SourceReadFailed;
        if (stat.kind != .file) return error.SourceReadFailed;
        if (stat.size > max_bytes) return error.ResourceLimitExceeded;
        const bytes = try allocator.alloc(u8, @intCast(stat.size));
        errdefer allocator.free(bytes);
        var buffer: [4096]u8 = undefined;
        var reader = file.reader(self.io, &buffer);
        reader.interface.readSliceAll(bytes) catch return error.SourceReadFailed;
        _ = reader.interface.takeByte() catch |err| switch (err) {
            error.EndOfStream => return bytes,
            else => return error.SourceReadFailed,
        };
        // Reject a source that grew after stat, rather than silently accepting a
        // prefix or allocating beyond the caller's bound.
        return error.SourceReadFailed;
    }
};
/// POSIX uses an explicit descriptor-relative native open because std.Io's
/// general open lacks a nonblocking flag. A raced-in FIFO cannot wait for a
/// writer, and NOFOLLOW prevents a raced-in symlink from escaping the root.
/// Subsequent stat/read/close use the caller's std.Io and the opened handle.
fn openSourceLeaf(dir: std.Io.Dir, io: std.Io, name: []const u8) Error!std.Io.File {
    if (builtin.os.tag == .windows) {
        // Zig's no-follow Windows open uses handle-relative NtCreateFile with
        // OPEN_REPARSE_POINT and ASYNCHRONOUS. Relative validated components
        // cannot select the absolute named-pipe namespace.
        return dir.openFile(io, name, .{ .follow_symlinks = false, .resolve_beneath = true, .allow_directory = false }) catch error.SourceReadFailed;
    } else if (@hasField(std.posix.O, "NONBLOCK") and @hasField(std.posix.O, "NOFOLLOW")) {
        var flags: std.posix.O = .{ .ACCMODE = .RDONLY, .NONBLOCK = true, .NOFOLLOW = true };
        if (@hasField(std.posix.O, "CLOEXEC")) flags.CLOEXEC = true;
        if (@hasField(std.posix.O, "NOCTTY")) flags.NOCTTY = true;
        const fd = std.posix.openat(dir.handle, name, flags, 0) catch return error.SourceReadFailed;
        return .{ .handle = fd, .flags = .{ .nonblocking = true } };
    } else return error.UnsupportedOperation;
}
pub fn validateRelativePath(path: []const u8) Error!void {
    if (path.len == 0 or path.len > 4096 or path[0] == '/' or std.mem.indexOfAny(u8, path, "\\:\x00") != null) return error.UnsafeSourcePath;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| if (part.len == 0 or std.mem.eql(u8, part, "..") or std.mem.eql(u8, part, ".")) return error.UnsafeSourcePath;
}
pub const MarkerTarget = struct {
    /// Original source marker ID, including a WAV cue ID when applicable.
    id: u64,
    target: union(enum) { cue: u32, anchor: u32 },
};
pub const SoundOptions = struct {
    sound: u32,
    import: importer.Options = .{},
    policy: quality.QualityPolicyV1 = .{},
    marker_targets: []const MarkerTarget = &.{},
};
/// One typed source-to-import bridge, reused by full media compilation and
/// selected-source replacement. Caller owns all returned marker slices.
pub fn sourceOptions(allocator: std.mem.Allocator, declaration: compiler.SourceImportV1, options: SoundOptions) Error!SoundOptions {
    if (declaration.version != 1) return error.UnsupportedSourceImportVersion;
    var result = options;
    if (result.import.markers.len != 0 or result.import.loop != null or result.marker_targets.len != 0) return error.ConflictingMetadata;
    if (declaration.markers.len > @min(result.import.limits.markers, (importer.Limits{}).markers)) return error.ResourceLimitExceeded;
    const markers = try allocator.alloc(importer.Marker, declaration.markers.len);
    errdefer allocator.free(markers);
    var binding_count: usize = 0;
    for (declaration.markers) |marker| if (marker.target != s.none) {
        binding_count += 1;
    };
    const targets = try allocator.alloc(MarkerTarget, binding_count);
    var target_count: usize = 0;
    for (declaration.markers, markers) |marker, *out| {
        out.* = .{ .id = marker.id, .kind = if (marker.kind == .cue) .cue else .anchor, .frame = marker.source_frame };
        if (marker.target != s.none) {
            targets[target_count] = .{ .id = marker.id, .target = if (marker.kind == .cue) .{ .cue = marker.target } else .{ .anchor = marker.target } };
            target_count += 1;
        }
    }
    result.import.markers = markers;
    result.marker_targets = targets;
    result.import.loop = if (declaration.loop) |loop| .{ .start = loop.start, .end = loop.end, .play_count = loop.play_count } else null;
    return result;
}
pub const Limits = struct {
    sounds: usize = 4096,
    /// Aggregate bytes read, not just the largest individual source.
    source_bytes: usize = 64 * 1024 * 1024,
    /// Aggregate retained normalized PCM; samples, not frames or bytes.
    normalized_samples: usize = 16 * 1024 * 1024,
};
/// Synchronous owned-by-value report delivery, including a failed gate. This
/// lets authoring show the measured reason without admitting bad media to IR.
pub const QualityObserver = struct {
    context: *anyopaque,
    report: *const fn (*anyopaque, u64, quality.Report) void,
};
pub const ConflictDiagnostic = struct { sound_id: u64, first_segment_id: u64, second_segment_id: u64 };
pub const SourceExpectationField = enum { source_hash, source_rate_hz, source_layout, source_channel_mask };
pub const SourceExpectationDiagnostic = struct { sound_id: u64, field: SourceExpectationField };
pub const Pipeline = struct {
    source_expectation: ?*?SourceExpectationDiagnostic = null,
    /// Optional caller-owned diagnostic destination; contains only public IDs.
    storage_conflict: ?*ConflictDiagnostic = null,
    quality_observer: ?QualityObserver = null,
    resolver: SourceResolver,
    sound_options: []const SoundOptions = &.{},
    limits: Limits = .{},
    seek_interval_frames: u32 = 48_000,
    target_chunk_bytes: u32 = 256 * 1024,
    pub fn provider(self: *Pipeline) compiler.MediaProviderContext {
        return .{ .context = self, .compile = compileCallback };
    }
    fn compileCallback(context: *anyopaque, allocator: std.mem.Allocator, ast: *const compiler.SourceAST) compiler.CompileError!compiler.OwnedIR {
        const self: *Pipeline = @ptrCast(@alignCast(context));
        return self.compile(allocator, ast) catch |err| return bankError(err);
    }
    fn optionsFor(self: *const Pipeline, indexes: []const ?usize, sound: u32) SoundOptions {
        return if (indexes[sound]) |index| self.sound_options[index] else .{ .sound = sound };
    }
    pub fn compile(self: *const Pipeline, allocator: std.mem.Allocator, ast: *const compiler.SourceAST) Error!compiler.OwnedIR {
        if (self.source_expectation) |out| out.* = null;
        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();
        var configured = self.*;
        configured.sound_options = try self.withSourceOptions(scratch.allocator(), ast);
        return configured.compilePrepared(allocator, ast);
    }
    fn expectationMismatch(self: *const Pipeline, ast: *const compiler.SourceAST, source: compiler.SoundSource, field: SourceExpectationField) Error {
        if (self.source_expectation) |out| out.* = .{ .sound_id = ast.tables.sounds[source.sound].key.id, .field = field };
        return error.SourceExpectationMismatch;
    }
    fn withSourceOptions(self: *const Pipeline, allocator: std.mem.Allocator, ast: *const compiler.SourceAST) Error![]const SoundOptions {
        var present = false;
        for (ast.sound_sources) |source| if (source.import != null) {
            present = true;
        };
        if (!present) return self.sound_options;
        // Preserve the old gate and its bounded index checks before allocating
        // or lowering source-only options. The final gate sees merged options.
        const indexes = try self.validateOptions(allocator, ast);
        const merged = try allocator.alloc(SoundOptions, ast.tables.sounds.len);
        @memcpy(merged[0..self.sound_options.len], self.sound_options);
        var count = self.sound_options.len;
        for (ast.sound_sources) |source| {
            const declaration = source.import orelse continue;
            if (source.sound >= indexes.len) return error.InvalidReference;
            if (declaration.version != 1) return error.UnsupportedSourceImportVersion;
            const index = indexes[source.sound] orelse blk: {
                const next = count;
                merged[next] = .{ .sound = source.sound };
                indexes[source.sound] = next;
                count += 1;
                break :blk next;
            };
            merged[index] = try sourceOptions(allocator, declaration, merged[index]);
        }
        return merged[0..count];
    }
    fn compilePrepared(self: *const Pipeline, allocator: std.mem.Allocator, ast: *const compiler.SourceAST) Error!compiler.OwnedIR {
        const option_indexes = try self.validateOptions(allocator, ast);
        defer allocator.free(option_indexes);
        const profile = ast.tables.platforms[ast.metadata.profile];
        var owned = try compiler.OwnedIR.clone(allocator, .{ .metadata = ast.metadata, .tables = ast.tables });
        errdefer owned.deinit();
        const arena = owned.arena.allocator();
        const sounds = @constCast(owned.ir.tables.sounds);
        const segments = @constCast(owned.ir.tables.segments);
        const cues = @constCast(owned.ir.tables.cues);
        const anchors = @constCast(owned.ir.tables.anchors);
        const media = try allocator.alloc(?Media, sounds.len);
        @memset(media, null);
        defer {
            for (media) |*item| if (item.*) |*m| m.deinit(allocator);
            allocator.free(media);
        }
        const assigned_storage = try allocator.alloc(?s.Storage, sounds.len);
        defer allocator.free(assigned_storage);
        @memset(assigned_storage, null);
        const assigned_segment = try allocator.alloc(u64, sounds.len);
        defer allocator.free(assigned_segment);
        @memset(assigned_segment, 0);
        const assigned_loop = try allocator.alloc(?quality.Loop, sounds.len);
        defer allocator.free(assigned_loop);
        @memset(assigned_loop, null);
        const cue_assigned = try allocator.alloc(bool, cues.len);
        defer allocator.free(cue_assigned);
        @memset(cue_assigned, false);
        const anchor_assigned = try allocator.alloc(bool, anchors.len);
        defer allocator.free(anchor_assigned);
        @memset(anchor_assigned, false);
        var total_source: usize = 0;
        var total_samples: usize = 0;
        var total_remaps: usize = 0;
        for (ast.sound_sources) |source| {
            if (source.sound >= sounds.len or media[source.sound] != null) return error.InvalidReference;
            const options = self.optionsFor(option_indexes, source.sound);
            const remaining = self.limits.source_bytes - total_source;
            if (remaining == 0) return error.ResourceLimitExceeded;
            const bytes = try self.resolver.read(self.resolver.context, allocator, source, @min(remaining, options.import.limits.encoded_bytes));
            var keep_bytes = false;
            defer if (!keep_bytes) allocator.free(bytes);
            if (bytes.len == 0 or bytes.len > remaining or bytes.len > options.import.limits.encoded_bytes) return error.ResourceLimitExceeded;
            total_source += bytes.len;
            if (source.import) |declaration| {
                if (!std.mem.eql(u8, &declaration.source_hash, &hash(bytes))) return self.expectationMismatch(ast, source, .source_hash);
            }
            var import_options = options.import;
            // Reserve only remaining output metadata. A zero remaining budget
            // must still admit a later source with no markers or source loop.
            import_options.limits.markers = @min(import_options.limits.markers, @max(1, profile.max_table_records - total_remaps));
            import_options.limits.normalized_samples = @min(import_options.limits.normalized_samples, self.limits.normalized_samples - total_samples);
            if (import_options.limits.normalized_samples == 0) return error.ResourceLimitExceeded;
            const is_opus = std.mem.startsWith(u8, bytes, "OggS");
            var normalized = if (is_opus)
                try importer.importOpus(allocator, bytes, import_options)
            else if (std.mem.startsWith(u8, bytes, "RIFF"))
                try importer.importWav(allocator, bytes, import_options)
            else
                return error.UnsupportedSourceFormat;
            errdefer normalized.deinit();
            if (source.import) |declaration| {
                if (declaration.source_rate_hz != normalized.report.source_rate_hz) return self.expectationMismatch(ast, source, .source_rate_hz);
                if (declaration.source_layout != normalized.report.layout) return self.expectationMismatch(ast, source, .source_layout);
                if (declaration.source_channel_mask != normalized.report.channel_mask) return self.expectationMismatch(ast, source, .source_channel_mask);
            }
            const authored = sounds[source.sound];
            if ((authored.layout != .explicit_mask and normalized.layout != authored.layout) or normalized.channels != authored.channels or normalized.report.channel_mask != authored.channel_mask) return error.MisalignedStems;
            if (authored.frames != 0 and authored.frames != normalized.frames) return error.MisalignedStems;
            if (authored.sample_rate_hz != 48_000) return error.InvalidSampleRate;
            total_samples += normalized.samples.len;
            // Embedded WAV cues/loops may exceed the authored lower bound.
            // Reject before retaining this metadata or reading another source.
            try consumeRemaps(&total_remaps, normalized.markers.len, profile.max_table_records);
            if (normalized.report.source_loop != null) try consumeRemaps(&total_remaps, 2, profile.max_table_records);
            // Index scratch is sorted, never the authored markers or bindings.
            const marker_indexes: []const MarkerIndex = if (options.marker_targets.len != 0)
                try indexMarkers(allocator, normalized.markers, import_options.limits.markers)
            else
                &.{};
            defer allocator.free(marker_indexes);
            for (options.marker_targets) |binding| {
                const marker_index = findMarker(marker_indexes, binding.id) orelse return error.InvalidReference;
                const mapped = normalized.markers[marker_index];
                switch (binding.target) {
                    .cue => |target| {
                        if (target >= cues.len or mapped.kind != .cue) return error.InvalidReference;
                        if (cue_assigned[target] and cues[target].frame != mapped.target_frame) return error.MisalignedStems;
                        cues[target].frame = mapped.target_frame;
                        cue_assigned[target] = true;
                    },
                    .anchor => |target| {
                        if (target >= anchors.len or mapped.kind != .anchor) return error.InvalidReference;
                        if (anchor_assigned[target] and anchors[target].frame != mapped.target_frame) return error.MisalignedStems;
                        anchors[target].frame = mapped.target_frame;
                        anchor_assigned[target] = true;
                    },
                }
            }
            media[source.sound] = .{ .audio = normalized, .source_opus = if (is_opus) bytes else null };
            keep_bytes = is_opus;
            sounds[source.sound].frames = normalized.frames;
            sounds[source.sound].layout = normalized.layout;
        }
        for (media) |m| if (m == null) return error.MissingField;
        const decisions = try arena.alloc(compiler.StorageDecisionV1, segments.len);
        var sizes: std.ArrayList(s.StemSize) = .empty;
        defer sizes.deinit(allocator);
        for (segments, decisions, 0..) |*segment, *decision, segment_index| {
            try checkRange(segment.layers, owned.ir.tables.layers.len);
            if (segment.layers.count == 0 or segment.emergency > 1) return error.InvalidMusicGraph;
            sizes.clearRetainingCapacity();
            const layers = owned.ir.tables.layers[segment.layers.first..][0..segment.layers.count];
            var first: ?*const importer.NormalizedAudio = null;
            for (layers) |layer| {
                if (layer.segment != segment_index or layer.sound >= sounds.len or layer.source_start != 0) return error.InvalidReference;
                const audio = &media[layer.sound].?.audio;
                if (first) |initial| {
                    importer.validateAlignment(&.{ initial, audio }) catch return error.MisalignedStems;
                } else first = audio;
                try sizes.append(allocator, .{ .frames = audio.frames, .channels = audio.channels });
            }
            const initial = first.?;
            if (segment.frames != 0 and segment.frames != initial.frames) return error.MisalignedStems;
            segment.frames = initial.frames;
            if (segment.loop_end == 0) {
                if (segment.loop_start != 0) return error.InvalidLoop;
                segment.loop_start = if (initial.loop) |loop| loop.start else 0;
                segment.loop_end = if (initial.loop) |loop| loop.end else initial.frames;
            }
            if (segment.loop_start >= segment.loop_end or segment.loop_end > initial.frames) return error.InvalidLoop;
            if (initial.loop) |loop| if (loop.start != segment.loop_start or loop.end != segment.loop_end) return error.MisalignedStems;
            const result = try s.storageDecision(sizes.items, profile.resident_limit_bytes, segment.storage, segment.emergency == 1);
            decision.* = .{ .segment_id = segment.key.id, .requested = segment.storage, .produced = result.storage, .decoded_bytes = result.decoded_bytes, .resident_limit_bytes = profile.resident_limit_bytes, .forced_streaming = result.forced_streaming };
            segment.storage = result.storage;
            segment.decoded_bytes = result.decoded_bytes;
            for (layers) |layer| {
                if (assigned_storage[layer.sound]) |previous| {
                    if (previous != result.storage) {
                        if (self.storage_conflict) |diagnostic| diagnostic.* = .{ .sound_id = sounds[layer.sound].key.id, .first_segment_id = assigned_segment[layer.sound], .second_segment_id = segment.key.id };
                        return error.InvalidStorageDecision;
                    }
                } else assigned_segment[layer.sound] = segment.key.id;
                assigned_storage[layer.sound] = result.storage;
                const loop: quality.Loop = .{ .start = segment.loop_start, .end = segment.loop_end };
                if (assigned_loop[layer.sound]) |previous| if (!std.meta.eql(previous, loop)) return error.AudioReportMismatch;
                assigned_loop[layer.sound] = loop;
            }
        }
        owned.storage_decisions = decisions;
        var codecs: std.ArrayList(s.Codec) = .empty;
        var imports: std.ArrayList(s.AudioImportReportV1) = .empty;
        var reports: std.ArrayList(s.AudioQualityReportV1) = .empty;
        var remaps: std.ArrayList(s.Remap) = .empty;
        var chunks: std.ArrayList(s.Chunk) = .empty;
        var seeks: std.ArrayList(s.SeekEntryV1) = .empty;
        var blob: std.ArrayList(u8) = .empty;
        // These lists use the result arena; failure frees all of them atomically.
        const policies = try arena.alloc(s.AudioImportPolicyV1, 1);
        policies[0] = .{ .src_algorithm = importer.algorithm_id, .src_version = importer.algorithm_version, .coefficients_hash = importer.coefficientsHash(), .policy_hash = importPolicyHash(), .quality_policy_hash = quality.frozen_policy_hash };
        for (sounds, media, 0..) |*sound, maybe_media, i| {
            const m = maybe_media.?;
            const audio = m.audio;
            const options = self.optionsFor(option_indexes, @intCast(i));
            const storage = assigned_storage[i] orelse return error.InvalidStorageDecision;
            const loop = assigned_loop[i];
            const normalized_report = try quality.scan(allocator, .{ .samples = audio.samples, .layout = audio.layout, .channel_mask = audio.report.channel_mask, .source_hash = audio.report.source_hash, .profile_hash = profile.profile_hash, .loop = loop }, options.policy);
            self.observe(sound.key.id, normalized_report);
            try normalized_report.requirePassed();
            sound.quality_report = try recordIndex(reports.items.len, profile);
            try reports.append(arena, try quality_record.fromReport(normalized_report));
            sound.normalized_hash = audio.report.normalized_hash;
            sound.import_report = try recordIndex(imports.items.len, profile);
            const remap_first = try rangeOffset(remaps.items.len, profile);
            for (audio.markers) |marker| {
                _ = try recordIndex(remaps.items.len, profile);
                try remaps.append(arena, .{ .source_frame = marker.source_frame, .target_frame = marker.target_frame, .marker_id = marker.id, .kind = @enumFromInt(@intFromEnum(marker.kind)) });
            }
            if (audio.report.source_loop) |source_loop| {
                const mapped = audio.loop.?;
                _ = try recordIndex(remaps.items.len + 1, profile);
                try remaps.appendSlice(arena, &.{ .{ .source_frame = source_loop.start, .target_frame = mapped.start, .kind = .loop_start }, .{ .source_frame = source_loop.end, .target_frame = mapped.end, .kind = .loop_end } });
            }
            try imports.append(arena, .{ .source_format = @enumFromInt(@intFromEnum(audio.report.source_format)), .layout = audio.layout, .bypass = @intFromBool(audio.report.bypass), .opus_input_rate_hint_present = @intFromBool(audio.report.opus_input_rate_hint != null), .opus_input_rate_hint = audio.report.opus_input_rate_hint orelse 0, .loop_present = @intFromBool(audio.report.source_loop != null), .source_loop_start = if (audio.report.source_loop) |source_loop| source_loop.start else 0, .source_loop_end = if (audio.report.source_loop) |source_loop| source_loop.end else 0, .target_loop_start = if (audio.loop) |mapped_loop| mapped_loop.start else 0, .target_loop_end = if (audio.loop) |mapped_loop| mapped_loop.end else 0, .loop_play_count = if (audio.report.source_loop) |source_loop| source_loop.play_count else 0, .source_hash = audio.report.source_hash, .normalized_hash = audio.report.normalized_hash, .source_sample_rate = audio.report.source_rate_hz, .channels = audio.channels, .channel_mask = audio.report.channel_mask, .source_frames = audio.report.source_frames, .target_frames = audio.frames, .src_algorithm = audio.report.src_algorithm, .src_version = audio.report.src_version, .coefficients_hash = audio.report.coefficients_hash, .remaps = .{ .first = remap_first, .count = @intCast(remaps.items.len - remap_first) } });
            sound.storage = storage;
            sound.codec = try recordIndex(codecs.items.len, profile);
            sound.blob_offset = blob.items.len;
            sound.chunks = .{};
            sound.seeks = .{};
            sound.encoded_quality_report = s.none;
            if (storage == .resident) {
                const byte_count = std.math.mul(usize, audio.samples.len, 4) catch return error.ArithmeticOverflow;
                try checkBlob(blob.items.len, byte_count, profile);
                const bytes = try blob.addManyAsSlice(arena, byte_count);
                for (audio.samples, 0..) |sample, sample_index| std.mem.writeInt(u32, bytes[sample_index * 4 ..][0..4], @bitCast(sample), .little);
                sound.blob_length = byte_count;
                sound.audio_hash = audio.report.normalized_hash;
                if (m.source_opus) |source_encoded| {
                    const encoded_report = try quality.scan(allocator, .{ .samples = audio.samples, .layout = audio.layout, .channel_mask = audio.report.channel_mask, .source_hash = audio.report.source_hash, .encoded_hash = hash(source_encoded), .stage = .decoded_encoded, .profile_hash = profile.profile_hash, .loop = loop }, options.policy);
                    self.observe(sound.key.id, encoded_report);
                    try encoded_report.requirePassed();
                    sound.encoded_quality_report = try recordIndex(reports.items.len, profile);
                    try reports.append(arena, try quality_record.fromReport(encoded_report));
                }
                try codecs.append(arena, .{});
            } else {
                if (owned.ir.metadata.required_capabilities & s.bit(.streaming) == 0) return error.InvalidCapabilityDeclaration;
                var encoded: ?opus.Encoded = null;
                defer if (encoded) |*owned_encoded| owned_encoded.deinit();
                const bytes = if (m.source_opus) |original| original else blk: {
                    var encoder = try opus.Encoder.prepare(allocator, audio.layout);
                    defer encoder.deinit();
                    try encoder.encode(audio.samples);
                    encoded = try encoder.finalize();
                    break :blk encoded.?.bytes;
                };
                if (bytes.len == 0) return error.EncodeFailure;
                try checkBlob(blob.items.len, bytes.len, profile);
                const encoded_hash = hash(bytes);
                var decoded: ?importer.NormalizedAudio = null;
                defer if (decoded) |*decoded_audio| decoded_audio.deinit();
                const decoded_audio = if (m.source_opus != null) &audio else blk: {
                    decoded = try importer.importOpus(allocator, bytes, .{ .limits = options.import.limits });
                    break :blk &decoded.?;
                };
                if (decoded_audio.frames != audio.frames or decoded_audio.layout != audio.layout or decoded_audio.channels != audio.channels) return error.AudioReportMismatch;
                const encoded_report = try quality.scan(allocator, .{ .samples = decoded_audio.samples, .layout = audio.layout, .channel_mask = audio.report.channel_mask, .source_hash = audio.report.source_hash, .encoded_hash = encoded_hash, .stage = .decoded_encoded, .profile_hash = profile.profile_hash, .loop = loop }, options.policy);
                self.observe(sound.key.id, encoded_report);
                try encoded_report.requirePassed();
                sound.encoded_quality_report = try recordIndex(reports.items.len, profile);
                try reports.append(arena, try quality_record.fromReport(encoded_report));
                var index = try indexer.build(allocator, bytes, .{ .sound = @intCast(i), .interval_frames = self.seek_interval_frames, .target_chunk_bytes = @min(self.target_chunk_bytes, @as(u32, @intCast(profile.max_chunk_bytes))), .max_chunk_bytes = @intCast(profile.max_chunk_bytes), .max_records = profile.max_table_records });
                defer index.deinit();
                if (index.info.audible_frames != audio.frames or index.info.channels != audio.channels or !std.mem.eql(u8, &index.encoded_hash, &encoded_hash)) return error.InvalidSeekIndex;
                sound.chunks = .{ .first = try recordIndex(chunks.items.len, profile), .count = @intCast(index.chunks.len) };
                sound.seeks = .{ .first = try recordIndex(seeks.items.len, profile), .count = @intCast(index.seeks.len) };
                if (chunks.items.len + index.chunks.len > profile.max_table_records or seeks.items.len + index.seeks.len > profile.max_table_records) return error.ResourceLimitExceeded;
                try chunks.appendSlice(arena, index.chunks);
                try seeks.appendSlice(arena, index.seeks);
                // An unknown external encoder is never falsely labeled our profile.
                try codecs.append(arena, index.info.codec(if (m.source_opus == null) opus.profile.hash else s.zero_hash));
                try blob.appendSlice(arena, bytes);
                sound.blob_length = bytes.len;
                sound.audio_hash = encoded_hash;
            }
        }
        owned.ir.tables.codecs = try codecs.toOwnedSlice(arena);
        owned.ir.tables.import_policies = policies;
        owned.ir.tables.import_reports = try imports.toOwnedSlice(arena);
        owned.ir.tables.quality_reports = try reports.toOwnedSlice(arena);
        owned.ir.tables.remaps = try remaps.toOwnedSlice(arena);
        owned.ir.tables.chunks = try chunks.toOwnedSlice(arena);
        owned.ir.tables.seeks = try seeks.toOwnedSlice(arena);
        owned.ir.tables.blob = try blob.toOwnedSlice(arena);
        try compiler.validateStorageDecisions(allocator, ast, &owned);
        return owned;
    }
    fn observe(self: *const Pipeline, sound_id: u64, report: quality.Report) void {
        if (self.quality_observer) |observer| observer.report(observer.context, sound_id, report);
    }
    fn validateOptions(self: *const Pipeline, allocator: std.mem.Allocator, ast: *const compiler.SourceAST) Error![]?usize {
        const maximum: Limits = .{};
        inline for (std.meta.fields(Limits)) |field| if (@field(self.limits, field.name) == 0 or @field(self.limits, field.name) > @field(maximum, field.name)) return error.ResourceLimitExceeded;
        if (ast.tables.sounds.len == 0 or ast.tables.sounds.len > self.limits.sounds or ast.sound_sources.len != ast.tables.sounds.len or ast.metadata.profile >= ast.tables.platforms.len) return error.InvalidReference;
        if (self.sound_options.len > ast.tables.sounds.len or self.seek_interval_frames == 0 or self.seek_interval_frames > 48_000 or self.target_chunk_bytes == 0) return error.InvalidSource;
        const profile = ast.tables.platforms[ast.metadata.profile];
        if (profile.resident_limit_bytes == 0 or profile.resident_limit_bytes > s.Limits.blob_bytes or profile.max_blob_bytes == 0 or profile.max_blob_bytes > s.Limits.blob_bytes or profile.max_chunk_bytes == 0 or profile.max_chunk_bytes > s.Limits.chunk_bytes or profile.max_table_records == 0 or profile.max_table_records > s.Limits.records) return error.ResourceLimitExceeded;
        // A compact, bounded sound-index space needs no hashing or pairwise scan.
        const indexes = try allocator.alloc(?usize, ast.tables.sounds.len);
        errdefer allocator.free(indexes);
        @memset(indexes, null);
        for (self.sound_options, 0..) |options, i| {
            if (options.sound >= ast.tables.sounds.len or options.marker_targets.len > options.import.limits.markers) return error.InvalidReference;
            try quality.validatePolicy(options.policy);
            const import_maximum: importer.Limits = .{};
            inline for (std.meta.fields(importer.Limits)) |field| if (@field(options.import.limits, field.name) == 0 or @field(options.import.limits, field.name) > @field(import_maximum, field.name)) return error.ResourceLimitExceeded;
            if (indexes[options.sound] != null) return error.DuplicateField;
            indexes[options.sound] = i;
        }
        // A source build cannot carry prevalidated/fabricated derived media.
        if (ast.tables.codecs.len != 0 or ast.tables.import_policies.len != 0 or ast.tables.import_reports.len != 0 or ast.tables.quality_reports.len != 0 or ast.tables.remaps.len != 0 or ast.tables.chunks.len != 0 or ast.tables.seeks.len != 0 or ast.tables.blob.len != 0) return error.InvalidSource;
        // Every valid binding needs its own source marker, including embedded
        // WAV cues. Authored markers and bindings may identify the same marker,
        // so their maximum (not sum) is a necessary lower bound. Check the whole
        // request before any per-binding scratch allocation or sorting.
        var minimum_remaps: usize = 0;
        for (self.sound_options) |options| {
            try consumeRemaps(&minimum_remaps, @max(options.import.markers.len, options.marker_targets.len), profile.max_table_records);
            if (options.import.loop != null) try consumeRemaps(&minimum_remaps, 2, profile.max_table_records);
        }
        for (self.sound_options) |options| try validateBindingKeys(allocator, options.marker_targets);
        return indexes;
    }
};
fn consumeRemaps(total: *usize, additional: usize, limit: usize) Error!void {
    if (total.* > limit or additional > limit - total.*) return error.ResourceLimitExceeded;
    total.* += additional;
}
/// Tagged destination keys distinguish cue index N from anchor index N. Heap
/// sort guarantees bounded O(n log n) work even for adversarial authored IDs.
const BindingKey = struct {
    id: u64,
    target: u64,
    fn lessId(_: void, left: BindingKey, right: BindingKey) bool {
        return left.id < right.id or (left.id == right.id and left.target < right.target);
    }
    fn lessTarget(_: void, left: BindingKey, right: BindingKey) bool {
        return left.target < right.target or (left.target == right.target and left.id < right.id);
    }
};
fn validateBindingKeys(allocator: std.mem.Allocator, bindings: []const MarkerTarget) Error!void {
    // validateOptions has checked the caller's possibly smaller bound first.
    if (bindings.len > (importer.Limits{}).markers) return error.ResourceLimitExceeded;
    if (bindings.len < 2) return;
    const keys = try allocator.alloc(BindingKey, bindings.len);
    defer allocator.free(keys);
    for (bindings, keys) |binding, *key| key.* = .{
        .id = binding.id,
        .target = switch (binding.target) {
            .cue => |index| index,
            .anchor => |index| (@as(u64, 1) << 32) | index,
        },
    };
    std.sort.heap(BindingKey, keys, {}, BindingKey.lessId);
    for (keys[1..], keys[0 .. keys.len - 1]) |current, previous| if (current.id == previous.id) return error.DuplicateField;
    std.sort.heap(BindingKey, keys, {}, BindingKey.lessTarget);
    for (keys[1..], keys[0 .. keys.len - 1]) |current, previous| if (current.target == previous.target) return error.DuplicateField;
}
const MarkerIndex = struct {
    id: u64,
    original_index: usize,
    fn less(_: void, left: MarkerIndex, right: MarkerIndex) bool {
        return left.id < right.id or (left.id == right.id and left.original_index < right.original_index);
    }
};
fn indexMarkers(allocator: std.mem.Allocator, markers: []const importer.MappedMarker, limit: usize) Error![]MarkerIndex {
    if (markers.len > limit or markers.len > (importer.Limits{}).markers) return error.ResourceLimitExceeded;
    const indexes = try allocator.alloc(MarkerIndex, markers.len);
    errdefer allocator.free(indexes);
    for (markers, indexes, 0..) |marker, *index, i| index.* = .{ .id = marker.id, .original_index = i };
    std.sort.heap(MarkerIndex, indexes, {}, MarkerIndex.less);
    // The importer already rejects duplicates. Retain that error if a future
    // importer violates its unique-ID contract instead of selecting one silently.
    if (indexes.len > 1) for (indexes[1..], indexes[0 .. indexes.len - 1]) |current, previous| if (current.id == previous.id) return error.ConflictingMetadata;
    return indexes;
}
fn findMarker(indexes: []const MarkerIndex, id: u64) ?usize {
    var first: usize = 0;
    var end = indexes.len;
    while (first < end) {
        const middle = first + (end - first) / 2;
        if (indexes[middle].id < id) first = middle + 1 else end = middle;
    }
    return if (first < indexes.len and indexes[first].id == id) indexes[first].original_index else null;
}
const Media = struct {
    audio: importer.NormalizedAudio,
    source_opus: ?[]u8,
    fn deinit(self: *Media, allocator: std.mem.Allocator) void {
        self.audio.deinit();
        if (self.source_opus) |bytes| allocator.free(bytes);
    }
};
fn checkRange(range: s.Range, count: usize) Error!void {
    if (@as(u64, range.first) + range.count > count) return error.InvalidReference;
}
/// An empty range may start exactly at the end of a full table.
fn rangeOffset(count: usize, profile: s.Platform) Error!u32 {
    if (count > profile.max_table_records) return error.ResourceLimitExceeded;
    return @intCast(count);
}
fn recordIndex(count: usize, profile: s.Platform) Error!u32 {
    if (count >= profile.max_table_records) return error.ResourceLimitExceeded;
    return @intCast(count);
}
fn checkBlob(existing: usize, extra: usize, profile: s.Platform) Error!void {
    if (existing > profile.max_blob_bytes or extra > profile.max_blob_bytes - existing) return error.ResourceLimitExceeded;
}
fn hash(bytes: []const u8) s.Hash {
    var out: s.Hash = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &out, .{});
    return out;
}
pub fn importPolicyHash() s.Hash {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update("bugu-media-import-v1;rate=48000;SBC1-v1;canonical-f32le;source-origin-ties-even;no-normalization;no-channel-fold;");
    h.update(&importer.coefficientsHash());
    return h.finalResult();
}
/// Registry's established error domain, while compile() retains detailed media
/// diagnostics for authoring tools. No new public runtime error enum is created.
pub fn bankError(err: Error) compiler.CompileError {
    return err;
}
