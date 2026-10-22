const std = @import("std");
const schema = @import("sme-bank").schema;
pub const Layout = schema.Layout;
pub const sample_rate = 48_000;
pub const max_channels = 8;
pub const max_packet_frames = 5760;
pub const Error = error{
    InvalidContainer,
    TruncatedContainer,
    ContainerCrcMismatch,
    ContainerSequenceGap,
    PartialPacket,
    ChainedStreamUnsupported,
    UnsupportedChannelMapping,
    UnsupportedChannels,
    InvalidHeader,
    InvalidGranule,
    DecodeFailure,
    EncodeFailure,
    InvalidPcm,
    InvalidState,
    SeekOutOfRange,
    BufferTooSmall,
    ResourceLimitExceeded,
} || std.mem.Allocator.Error;
/// The adapter is private to worker/compiler modules. Detailed diagnostics map
/// through the existing public error seam rather than creating another façade.
pub fn musicError(err: Error) schema.music.MusicError {
    return switch (err) {
        error.UnsupportedChannels, error.UnsupportedChannelMapping, error.ChainedStreamUnsupported => error.UnsupportedCapability,
        error.SeekOutOfRange, error.InvalidState, error.BufferTooSmall => error.InvalidState,
        error.OutOfMemory, error.ResourceLimitExceeded => error.VoiceBudgetExceeded,
        else => error.InvalidMusicGraph,
    };
}
pub fn channels(layout: Layout) Error!u8 {
    return switch (layout) {
        .mono => 1,
        .stereo => 2,
        .surround_5_1 => 6,
        .surround_7_1 => 8,
        .explicit_mask => error.UnsupportedChannels,
    };
}
pub fn layoutFor(count: u8) Error!Layout {
    return switch (count) {
        1 => .mono,
        2 => .stereo,
        6 => .surround_5_1,
        8 => .surround_7_1,
        else => error.UnsupportedChannels,
    };
}
pub fn mask(layout: Layout) Error!u32 {
    return switch (layout) {
        .mono => 4,
        .stereo => 3,
        .surround_5_1 => 0x3f,
        .surround_7_1 => 0x63f,
        .explicit_mask => error.UnsupportedChannels,
    };
}
/// Canonical PCM index -> RFC 7845 family-1 (Vorbis) channel index.
pub fn canonicalToOpus(count: u8) [8]u8 {
    return switch (count) {
        6 => .{ 0, 2, 1, 5, 3, 4, 0, 0 },
        8 => .{ 0, 2, 1, 7, 5, 6, 3, 4 },
        else => .{ 0, 1, 0, 0, 0, 0, 0, 0 },
    };
}
pub const OpusStreamInfo = struct {
    sample_rate_hz: u32 = sample_rate,
    input_rate_hint: u32,
    channels: u8,
    layout: Layout,
    channel_mask: u32,
    pre_skip: u16,
    end_trim: u32 = 0,
    output_gain_q8: i16,
    mapping_family: u8,
    stream_count: u8,
    coupled_count: u8,
    channel_mapping: [8]u8,
    stream_serial: u32 = 0,
    link_id: u32 = 0,
    raw_frames: u64 = 0,
    audible_frames: u64 = 0,
    granule_origin: u64 = 0,
    final_granule: u64 = 0,
    pub fn codec(self: OpusStreamInfo, encoder_hash: schema.Hash) schema.Codec {
        return .{ .kind = .ogg_opus, .version = 1, .pre_skip = self.pre_skip, .end_trim = self.end_trim, .channel_mapping_family = self.mapping_family, .stream_count = self.stream_count, .coupled_count = self.coupled_count, .channel_mapping = self.channel_mapping, .encoder_hash = encoder_hash };
    }
};
pub const DecodeResult = struct { frames: usize, eos: bool };
