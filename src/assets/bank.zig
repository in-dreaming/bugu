const std = @import("std");

pub const AssetError = error{
    UnsupportedWav,
    CorruptWav,
    InvalidManifest,
    InvalidBlob,
    MissingSound,
};

pub const SourceMetadata = struct {
    id: []const u8,
    path: []const u8,
    sample_rate: u32,
    source_channels: u16,
    frames: u32,
    duration_seconds: f32,
    peak: f32,
    rms: f32,
};

pub const SoundEntry = struct {
    id: []const u8,
    sample_rate: u32,
    source_channels: u16,
    frames: u32,
    blob_offset_bytes: u32,
    peak: f32,
    rms: f32,
    samples: []const f32,
};

pub const ImportSource = struct {
    id: []const u8,
    path: []const u8,
};

pub const ImportSummary = struct {
    source_count: usize,
    total_frames: u32,
    blob_bytes: u32,
    peak: f32,
};

pub const Bank = struct {
    allocator: std.mem.Allocator,
    entries: []SoundEntry,
    ids: [][]u8,
    samples: []f32,

    pub fn deinit(self: *Bank) void {
        for (self.ids) |id| self.allocator.free(id);
        self.allocator.free(self.ids);
        self.allocator.free(self.entries);
        self.allocator.free(self.samples);
        self.* = undefined;
    }

    pub fn find(self: *const Bank, id: []const u8) ?*const SoundEntry {
        for (self.entries) |*entry| {
            if (std.mem.eql(u8, entry.id, id)) return entry;
        }
        return null;
    }
};

const ImportedSound = struct {
    id: []const u8,
    metadata: SourceMetadata,
    samples: []f32,
};

pub fn importToBank(
    io: std.Io,
    allocator: std.mem.Allocator,
    sources: []const ImportSource,
    manifest_path: []const u8,
    blob_path: []const u8,
) !ImportSummary {
    var imported = try allocator.alloc(ImportedSound, sources.len);
    defer allocator.free(imported);
    defer for (imported) |sound| {
        if (sound.samples.len > 0) allocator.free(sound.samples);
    };
    @memset(imported, .{
        .id = "",
        .metadata = undefined,
        .samples = &.{},
    });

    var total_frames: u32 = 0;
    var peak: f32 = 0.0;
    for (sources, 0..) |source, index| {
        const wav_bytes = try std.Io.Dir.cwd().readFileAlloc(io, source.path, allocator, .unlimited);
        defer allocator.free(wav_bytes);
        const decoded = try decodeWavPcmToMono(allocator, source.id, source.path, wav_bytes);
        imported[index] = .{
            .id = source.id,
            .metadata = decoded.metadata,
            .samples = decoded.samples,
        };
        total_frames += decoded.metadata.frames;
        peak = @max(peak, decoded.metadata.peak);
    }

    try writeManifest(io, imported, manifest_path);
    const blob_bytes = try writeBlob(io, imported, blob_path);
    return .{
        .source_count = sources.len,
        .total_frames = total_frames,
        .blob_bytes = blob_bytes,
        .peak = peak,
    };
}

pub fn loadBank(io: std.Io, allocator: std.mem.Allocator, manifest_path: []const u8, blob_path: []const u8) !Bank {
    const manifest = try std.Io.Dir.cwd().readFileAlloc(io, manifest_path, allocator, .unlimited);
    defer allocator.free(manifest);
    const blob = try std.Io.Dir.cwd().readFileAlloc(io, blob_path, allocator, .unlimited);
    defer allocator.free(blob);
    if (blob.len % @sizeOf(f32) != 0) return AssetError.InvalidBlob;

    const samples = try allocator.alloc(f32, blob.len / @sizeOf(f32));
    errdefer allocator.free(samples);
    var sample_index: usize = 0;
    while (sample_index < samples.len) : (sample_index += 1) {
        const offset = sample_index * @sizeOf(f32);
        const bits = std.mem.readInt(u32, blob[offset..][0..4], .little);
        samples[sample_index] = @bitCast(bits);
    }

    var entries_list: std.ArrayList(SoundEntry) = .empty;
    defer entries_list.deinit(allocator);
    var ids_list: std.ArrayList([]u8) = .empty;
    defer ids_list.deinit(allocator);

    var current: PartialEntry = .{};
    var have_entry = false;
    var lines = std.mem.splitScalar(u8, manifest, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r\t");
        if (line.len == 0) continue;
        if (std.mem.eql(u8, line, "[[sounds]]")) {
            if (have_entry) try appendEntry(allocator, &entries_list, &ids_list, &current, samples);
            current = .{};
            have_entry = true;
            continue;
        }
        if (!have_entry) continue;
        try parseManifestLine(line, &current);
    }
    if (have_entry) try appendEntry(allocator, &entries_list, &ids_list, &current, samples);

    return .{
        .allocator = allocator,
        .entries = try entries_list.toOwnedSlice(allocator),
        .ids = try ids_list.toOwnedSlice(allocator),
        .samples = samples,
    };
}

const DecodedWav = struct {
    metadata: SourceMetadata,
    samples: []f32,
};

fn decodeWavPcmToMono(allocator: std.mem.Allocator, id: []const u8, path: []const u8, bytes: []const u8) !DecodedWav {
    if (bytes.len < 44 or !std.mem.eql(u8, bytes[0..4], "RIFF") or !std.mem.eql(u8, bytes[8..12], "WAVE")) {
        return AssetError.CorruptWav;
    }

    var format: u16 = 0;
    var channels: u16 = 0;
    var sample_rate: u32 = 0;
    var bits_per_sample: u16 = 0;
    var data: []const u8 = &.{};

    var offset: usize = 12;
    while (offset + 8 <= bytes.len) {
        const tag = bytes[offset..][0..4];
        const size = std.mem.readInt(u32, bytes[offset + 4 ..][0..4], .little);
        const payload_start = offset + 8;
        const payload_end = payload_start + size;
        if (payload_end > bytes.len) return AssetError.CorruptWav;
        if (std.mem.eql(u8, tag, "fmt ")) {
            if (size < 16) return AssetError.CorruptWav;
            format = std.mem.readInt(u16, bytes[payload_start..][0..2], .little);
            channels = std.mem.readInt(u16, bytes[payload_start + 2 ..][0..2], .little);
            sample_rate = std.mem.readInt(u32, bytes[payload_start + 4 ..][0..4], .little);
            bits_per_sample = std.mem.readInt(u16, bytes[payload_start + 14 ..][0..2], .little);
        } else if (std.mem.eql(u8, tag, "data")) {
            data = bytes[payload_start..payload_end];
        }
        offset = payload_end + (size & 1);
    }

    if (sample_rate != 48_000 or channels == 0 or channels > 2 or data.len == 0) return AssetError.UnsupportedWav;
    if (!((format == 1 and bits_per_sample == 16) or (format == 3 and bits_per_sample == 32))) {
        return AssetError.UnsupportedWav;
    }

    const bytes_per_sample = bits_per_sample / 8;
    const frame_bytes = @as(usize, channels) * bytes_per_sample;
    if (frame_bytes == 0 or data.len % frame_bytes != 0) return AssetError.CorruptWav;
    const frames: u32 = @intCast(data.len / frame_bytes);
    const samples = try allocator.alloc(f32, frames);
    errdefer allocator.free(samples);

    var peak: f32 = 0.0;
    var sum_squares: f64 = 0.0;
    var frame: usize = 0;
    while (frame < frames) : (frame += 1) {
        var mono: f32 = 0.0;
        var channel: usize = 0;
        while (channel < channels) : (channel += 1) {
            const sample_offset = frame * frame_bytes + channel * bytes_per_sample;
            const sample = if (format == 1)
                @as(f32, @floatFromInt(std.mem.readInt(i16, data[sample_offset..][0..2], .little))) / 32768.0
            else
                @as(f32, @bitCast(std.mem.readInt(u32, data[sample_offset..][0..4], .little)));
            mono += sample;
        }
        mono /= @floatFromInt(channels);
        samples[frame] = mono;
        peak = @max(peak, @abs(mono));
        sum_squares += @as(f64, @floatCast(mono * mono));
    }

    return .{
        .metadata = .{
            .id = id,
            .path = path,
            .sample_rate = sample_rate,
            .source_channels = channels,
            .frames = frames,
            .duration_seconds = @as(f32, @floatFromInt(frames)) / @as(f32, @floatFromInt(sample_rate)),
            .peak = peak,
            .rms = @floatCast(@sqrt(sum_squares / @as(f64, @floatFromInt(frames)))),
        },
        .samples = samples,
    };
}

fn writeManifest(io: std.Io, sounds: []const ImportedSound, path: []const u8) !void {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    var offset_bytes: u32 = 0;
    for (sounds) |sound| {
        try writer.interface.print(
            "[[sounds]]\nid = \"{s}\"\nsample_rate = {}\nsource_channels = {}\nframes = {}\noffset_bytes = {}\npeak = {d:.8}\nrms = {d:.8}\n\n",
            .{
                sound.id,
                sound.metadata.sample_rate,
                sound.metadata.source_channels,
                sound.metadata.frames,
                offset_bytes,
                sound.metadata.peak,
                sound.metadata.rms,
            },
        );
        offset_bytes += @intCast(sound.samples.len * @sizeOf(f32));
    }
    try writer.interface.flush();
}

fn writeBlob(io: std.Io, sounds: []const ImportedSound, path: []const u8) !u32 {
    const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    var bytes: u32 = 0;
    for (sounds) |sound| {
        for (sound.samples) |sample| {
            try writer.interface.writeInt(u32, @bitCast(sample), .little);
            bytes += @sizeOf(f32);
        }
    }
    try writer.interface.flush();
    return bytes;
}

const PartialEntry = struct {
    id: []const u8 = "",
    sample_rate: u32 = 0,
    source_channels: u16 = 0,
    frames: u32 = 0,
    offset_bytes: u32 = 0,
    peak: f32 = 0.0,
    rms: f32 = 0.0,
};

fn parseManifestLine(line: []const u8, entry: *PartialEntry) !void {
    const eq = std.mem.indexOfScalar(u8, line, '=') orelse return AssetError.InvalidManifest;
    const key = std.mem.trim(u8, line[0..eq], " \t");
    const raw_value = std.mem.trim(u8, line[eq + 1 ..], " \t");
    if (std.mem.eql(u8, key, "id")) {
        entry.id = std.mem.trim(u8, raw_value, "\"");
    } else if (std.mem.eql(u8, key, "sample_rate")) {
        entry.sample_rate = try std.fmt.parseInt(u32, raw_value, 10);
    } else if (std.mem.eql(u8, key, "source_channels")) {
        entry.source_channels = try std.fmt.parseInt(u16, raw_value, 10);
    } else if (std.mem.eql(u8, key, "frames")) {
        entry.frames = try std.fmt.parseInt(u32, raw_value, 10);
    } else if (std.mem.eql(u8, key, "offset_bytes")) {
        entry.offset_bytes = try std.fmt.parseInt(u32, raw_value, 10);
    } else if (std.mem.eql(u8, key, "peak")) {
        entry.peak = try std.fmt.parseFloat(f32, raw_value);
    } else if (std.mem.eql(u8, key, "rms")) {
        entry.rms = try std.fmt.parseFloat(f32, raw_value);
    }
}

fn appendEntry(
    allocator: std.mem.Allocator,
    entries: *std.ArrayList(SoundEntry),
    ids: *std.ArrayList([]u8),
    partial: *const PartialEntry,
    samples: []const f32,
) !void {
    if (partial.id.len == 0 or partial.frames == 0 or partial.sample_rate != 48_000) return AssetError.InvalidManifest;
    const sample_offset = partial.offset_bytes / @sizeOf(f32);
    if (sample_offset + partial.frames > samples.len) return AssetError.InvalidBlob;
    const owned_id = try allocator.dupe(u8, partial.id);
    errdefer allocator.free(owned_id);
    try ids.append(allocator, owned_id);
    try entries.append(allocator, .{
        .id = owned_id,
        .sample_rate = partial.sample_rate,
        .source_channels = partial.source_channels,
        .frames = partial.frames,
        .blob_offset_bytes = partial.offset_bytes,
        .peak = partial.peak,
        .rms = partial.rms,
        .samples = samples[sample_offset .. sample_offset + partial.frames],
    });
}

test "import generated wavs into bank and load entries" {
    _ = Bank;
}
