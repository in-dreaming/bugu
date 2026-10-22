# TASK010-A: portable Ogg Opus binding

This internal `sme-opus` module runs on compiler/worker threads only. It exposes
Bugu enums, owned byte/PCM slices, metadata and errors. It neither imports render
code nor changes the public facade. There is no first-party C implementation:
`c.zig` privately imports the official upstream ABI, and `include/ogg/config_types.h`
is only the required portable build type configuration.

## Frozen profile

`bugu-opus-fixed24-cbr20-v1`, libopus 1.6.1 + libogg 1.3.6 at the commits in
PINS.toml. The build manifest lists every compiled upstream source and flag.
Scalar fixed point with upstream `ENABLE_RES24`, which is the configure default,
retains 24-bit resolution. `DISABLE_FLOAT_API` also removes floating tonality
analysis. No runtime CPU dispatch, assembly, intrinsics, neural enhancements,
QEXT, fast math or FMA contraction. C arithmetic uses `-fwrapv`. Runtime profile:

- 48,000 Hz, 960 frames (20 ms), audio application, music signal, complexity 10
- 64,000 bit/s per channel; CBR; VBR constraint set; no FEC, packet loss or DTX
- 24-bit LSB depth, stereo phase inversion disabled
- family 0 mono/stereo; family 1 surround, standard upstream surround mapping
- canonical float32 PCM: mono FC; stereo FL FR; 5.1 FL FR FC LFE BL BR;
  7.1 FL FR FC LFE BL BR SL SR. Masks 4, 3, 0x3f, 0x63f
- canonical-to-Opus channel indices: 5.1 `[0,2,1,5,3,4]`;
  7.1 `[0,2,1,7,5,6,3,4]`. Decode permutes the mapping passed to libopus;
  encode permutes samples before the standard surround encoder
- normalized finite float32 input is multiplied by 2^23, rounded nearest ties
  to even in Zig, and represented as signed 24-bit integers. Only the exact
  positive endpoint +1 is saturated to 8388607; values outside [-1,1] fail
- decode24 output is converted to float32 by /2^23 without clipping. Mandatory
  OpusHead output gain is applied in Zig after conversion, with f64 factor
  `10^(gain_q8/5120)` and one final f32 rounding, without clipping
- libopus lookahead becomes pre-skip; final input is zero-padded to whole
  packets until raw frames cover input frames + lookahead. EOS granule is
  exactly input frames + pre-skip, including subpacket end trim
- Ogg serial 0x534d4501; deterministic vendor string; separate head/tags pages;
  one data packet flushed per page; no timestamps or random serial generation

The profile description and SHA256 are exported by profile.zig. Byte-equal
repeated/chunked encoding is tested on Linux. Native Windows byte equality is
not inferred from cross-compilation and remains unverified until executed.

## Ownership and limits

`inspect(allocator, encoded)` performs the offline strict whole-stream scan,
including checksum, serial, sequence, continuation, header, mapping and granule
validation. It owns page/packet arrays and assembled encoded payloads and must
be deinitialized. Compiler input is limited to 192 MiB; header packets to 1 MiB;
page and packet inventory each to 262144 entries;
Opus audio packets to 489600 bytes (8 streams x 48 frames x 1275 bytes).

`Decoder.prepare(allocator, info, reader, first_packet_byte_offset)` allocates
native decoder state checked against a 2 MiB allocation ceiling, at most 489600 bytes of encoded scratch and
5760 * channels * 4 bytes of PCM scratch, plus fixed bookkeeping. `decode`,
`reset` and `seek` do not allocate. `PacketReader` is a Bugu callback filling
that bounded scratch from worker-owned fetched chunks; runtime must validate
page CRC/serial/sequence and reassemble continued packets before returning.
It returns packet byte length and the next sound-relative packet-byte locator.
No whole-file PCM/encoded retention is imposed on the runtime reader.

`scanReader` is a compiler/test convenience over a stable-address Scan. It is
not the runtime storage architecture. `decode` supports arbitrary interleaved
output frame sizes, retaining the unfinished decoded packet and returning EOS.

`seek(recovery, logical_frame)` resets at an index-verified packet byte offset
and raw-frame coordinate, requires at least 11520 frames (240 ms) of preroll
unless the recovery point is BOS, decodes/discards precisely to the requested
first-audible-PCM coordinate and retains the partial target packet. It does not
replay from frame zero for later seeks. End trim and pre-skip are compensated.
Sample *coordinates* are exact; an Opus state reset has bounded convergence
error, tested against this decoder's continuous output, not source PCM. Frozen maximum
absolute sample tolerance is 0.0002 FS on tonal, noise, impulse and multichannel
fixtures (the 80 ms RFC minimum failed this stricter quality target).

## Validation and scope

Independent FFmpeg/libopus 1.5.2 fixtures are generated solely by optional test
tooling under tests/fixtures/sme/opus. The production path never invokes ffmpeg,
a runtime process, a system-installed codec or a copied upstream implementation.
Fixtures include canonical original PCM, independent decoder PCM, encoded bytes,
licenses and SHA256. PCM equality to the original is not demanded of a lossy
codec. Per-speaker independent decoder comparisons detect swapped channels.

This is CodecBinding only. Source-rate conversion, quality gates and bank
Chunk/Seek production remain TASK010-B/C/D; this module supplies actual encoded
bytes, scanner metadata and bounded decoder contracts to those implementations.
Chained/multiplexed streams and unknown channel families fail explicitly.
References: https://www.rfc-editor.org/rfc/rfc7845.html and the pinned upstream
include/opus_multistream.h, configure.ac, opus_sources.mk, celt_sources.mk and
silk_sources.mk.

## Distribution notices

Keep third_party/ogg/COPYING, third_party/opus/COPYING and applicable individual
source notices in source distributions. Reproduce their notices, conditions and
disclaimers in binary distribution documentation/materials. Preserve the Opus
patent references in PINS.toml and LICENSE_PLEASE_READ.txt. This inventory does
not claim independent patent clearance or legal assurance.

`BoundedPacketSource` supplies the actual worker demux implementation over a
`ByteSource.read_at` callback, owning one 65307-byte Ogg page buffer. It verifies
page checksum, serial, sequence, continuation and final granule, and reassembles
packets directly into Decoder scratch. Call `positionAt(recovery.page_byte_offset,
recovery.packet_byte_offset)` before decoder preparation or indexed seek/reset.
The callback may read from fetched chunks; full-file retention is unnecessary.

### Bank seek coordinates (TASK003 table layout unchanged)

For TASK010-D, page_byte_offset is the recovery packet START page;
recovery_byte_offset is the recovery packet's first payload byte;
packet_byte_offset is the target-containing packet's first payload byte;
granule_position is the target packet's COMPLETION page granule. Recovery raw
frame is `pre_skip + logical_frame - discard_frames` (checked arithmetic), and
preroll_frames is `logical_frame - max(0, recovery_raw_frame - pre_skip)`.
For BOS logical frame 0 the independent bank fixture has page127, recovery156,
packet156, discard312, preroll0. The earlier fixture's recovery127 identified a
page rather than a packet and needs this value-only clarification by TASK003's
owner. The Codec/Chunk/Seek field schema and wire strides do not change.

Pinned upstream gain caveat: libopus 1.6.1 src/opus_decoder.c:681–694 applies
SATURATE(x,32767) even under ENABLE_RES24. A +6 dB regression test exposed
clipping at approximately0.003906 FS. The unmodified codec therefore receives
zero native gain; the adapter applies the specified header gain in Zig after
decode24. Tests cover mandatory gain and unchanged input-rate-hint timing.

## Required compiler payload acceptance

After a continuous BOS decode reaches audible EOS, the compiler/importer must
call `Decoder.validatePayloadToEnd()` before accepting source PCM. Audible EOS
can precede fully trimmed packets. The explicit validation step reuses the
existing native state and bounded buffers, decodes all remaining packets, and
requires packet exhaustion. It is allocation-free and leaves audible cursor/EOS
unchanged. `InvalidState` rejects calls before audible EOS or after a non-BOS
recovery that skipped payloads; reset and full BOS decoding restore eligibility.
Native payload/container failures propagate. Ordinary runtime `decode` does not
perform this extra compiler work implicitly.

RFC 7845 edge rules: if the first completed audio page is also EOS, its granule
origin is `max(0, final_granule - raw_frames)` before ordinary pre-skip/end-trim
checks. Targets below the selected 11520-frame preroll recover from BOS,
regardless of the pre-skip amount; pre-roll is measured in logical audible time.
The decoder rejects a non-BOS recovery for such near-BOS targets.
