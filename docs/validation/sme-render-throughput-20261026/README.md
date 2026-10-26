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
