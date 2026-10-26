# Render fixed-corpus throughput diagnosis (2026-10-26)

Baseline source tree: `1521f609dd10e4eaa53fd4f494121647c0f1489f`.

One explicitly profiled long, notified, streaming run completed 35,840 submitted
frames and drained every queue. Strict admission rejected `UnsupportedOverlap`;
this is not an end-to-end pass. Render peak was 144,668 bytes out of the unchanged
4 MiB lane. Prior Render overflow remains historical evidence, not reproduced by
this run and not explained away. No production scheduling/buffering changes.

The private fixed corpus is sealed framing, not admitted history. Its SHA256 is
in the result JSON. Original audio/tapes/logs/private paths are not in this public
checkpoint. Reproduce the diagnostic with an authorized local copy:

```sh
SME_RENDER_TAPE="$FIXED_TAPE" zig build sme-live-render-throughput-check -Dsme-test-use-llvm=true -j1
```

The diagnostic validates all complete frame hashes/ordinals, then reconstructs
canonical native representatives of every Render record. Unsupported families or
error variants fail explicitly. All 11,702 Render records (8 families) roundtrip
exactly. Real Lane push/pop preserves every byte, and StreamingWriter output
matches the original per-Render frame projection. Fixed three timing rounds:

- Sum of per-family median encode: 43.982 ms.
- Sum of per-family median sequential Lane push/pop: 5.583 ms.
- Median memory-sink append: 9.837 ms.
- Packet families 11/115 account for 91.47% of encoding time.

These isolated costs exclude other roles, Recorder.observe, file I/O, concurrent
queue contention, scheduling and producer packet assembly. They are **not** a
59.4 ms end-to-end replay or throughput guarantee. The source frame count spans
about 0.747 s of 48 kHz audio, but that ratio is not full-system headroom.

The separate 10 ms CPU sampler saw about 0.895 s of Host-active wall time and
0.73 s of collector/coordinator CPU. CPU tick resolution is 10 ms; boundaries are
approximate. Full process time includes bank preparation and post-capture
validation and must not be treated as audio callback time.

All tests use Debug caller/queue and explicit ReleaseSafe LLVM codec/wire encoder
and SHA. Production modes, admission checks, queue sizes and event coverage are
unchanged. Initial diagnostic compile and missing frame-magic parse errors were
corrected before the reported 1/1 pass; there was no repeated live capture to
select a good result. Producer-cost isolation and independent review follow.

## Completed bounded comparisons

The fixed corpus also runs through actual Recorder.observe and drainStreaming,
with one-record injection and other lanes empty. Three rounds each:

- Profile off: 66.141 / 65.178 / 63.780 ms.
- Profile on: 72.628 / 81.013 / 74.367 ms.
- Median observer overhead in **this fixture only**: 14.1%.

Both modes reproduce every original Render frame exactly and leave an empty,
healthy queue. This is not a complete Host lifecycle and finish is not called.
Use `SME_RENDER_RECORDER_ONLY=1` with the same tape to run only this comparison.

Actual Service.endRenderSpan producer testing uses fresh Service instances and
real asset preparation/open, then 128 spans in each of three fixed trials:

| Slots/open | Points/span | Producer median | Collector median |
|---|---:|---:|---:|
| 4/4 | 30 | 1.258 ms | 3.863 ms |
| 48/4 | 118 | 3.850 ms | 9.595 ms |
| 48/48 | 294 | 12.044 ms | 25.900 ms |

Production uses the default 48-slot Service profile; 48 is not the maximum
supported slot count (64). Tests verify callback counts, real forwarding and
queue health; they do not independently prove each point's wire contents.
Capture timing uses a clock pair per span while plain/counting modes use one
pair around all spans, so differences cannot be interpreted as precise hook
cost. A synthetic final boundary flush contributes to byte/record totals but
not timings. Collector output is a counting sink, not file I/O. No playback or
replay is performed by this fixture. Run using:

```sh
SME_RENDER_COST_BANK="$FIXED_BANK" zig build sme-live-render-producer-cost-check -Dsme-test-use-llvm=true -j1
```

A single predefined **unprofiled** long counterpart then completed 12/12 tests,
35,072 submitted frames and strict admission with zero unresolved scalar
overlaps. Render peak was 150,612 bytes (3.59% of unchanged 4 MiB); Control peak
588,980 bytes. Approximate Host-active collector/coordinator CPU was 0.56 s over
0.864 s sampled wall time. This case and the earlier profiled UnsupportedOverlap
case are both retained. No further live repetitions were performed. Fresh
replay and negative qualification are separate integration acceptance work.

Historical overflow is **not causally explained or fixed** by these successes.
Consumer-observed submitted_frames cannot reconstruct producer wall-time rates
at that old failure. Current evidence does not justify changing queue sizes,
scan coverage, concurrency, atomic order or round-robin service. No production
fix was made on speculation. The supported measured environment here is Linux
null-device 48 kHz four-stem long workload, Debug engine/Recorder/queues plus the
explicit existing ReleaseSafe LLVM codec/encoder/SHA hybrid; this does not
qualify arbitrary workloads, physical devices, Windows or scheduling stalls.

Independent reviews found no functional blocker in both diagnostics and
confirmed these scope limits. Initial producer fixture attach-after-open was
correctly rejected; the passing test attaches before setup on fresh Service
instances, without relaxing production attach rules.
