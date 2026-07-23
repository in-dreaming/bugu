# Bugu production runtime embedding v1

Status: implemented and compatibility-frozen for Enjin Audio Phase 1.

The v1 embedding path is `ControlRuntime -> RenderSnapshot -> RuntimeRenderer`. Legacy `Engine` APIs remain available for Bugu demos, but an embedding host must use the runtime path when game/control and a device callback execute concurrently.

## Command and instance contract

`ControlRuntime` owns one fixed 4,096-command FIFO MPSC ring with atomic admission quotas: 3,968 normal commands plus 128 entries reserved for `stop` and `shutdown`. Producers receive `error.CommandQueueFull`; no command is overwritten or dynamically allocated. The ring-slot claim is the single global order, so producers cannot invert a separate sequence behind a FIFO head. At most 512 commands are drained per `controlTick`.

Commands are value-semantic `play`, `update`, `bus`, `stop`, and `shutdown` records. A play record carries a stable `SampleOwner` pointer rather than owning allocation or source metadata. `reserveInstance` returns `{index: u16, generation: u16}` from a fixed 1,024-slot atomic pool. Reuse increments a nonzero generation; stale update/stop commands are rejected and cannot affect a reused slot.

Control is guarded by an atomic single-owner entry check. It maintains at most 64 desired real voices. When full, a strictly higher-priority arrival steals the deterministic weakest voice; priority ties use newest start order and then greatest instance identity as the victim. Otherwise the arrival is rejected. Stop affects one generation only and carries a bounded fade.

## Snapshot and memory ordering

Three fixed `SnapshotSlot` values hold a complete desired render state, bus state, generation, and at most 64 voice records. Control writes only a non-current slot whose reader count is zero. It pins every referenced `SampleOwner`, completes all ordinary writes, then publishes generation and slot index with release stores.

Render acquisition loads the slot index with acquire ordering, increments that slot's reader count, and rechecks the published index. A mismatch releases and retries. Release decrements the reader count with release ordering. Control may overwrite a retired non-current slot only after an acquire load observes zero readers; overwriting releases its owner pins. Snapshot generation is monotonic and wraps past zero.

`RuntimeRenderer` is callback-local mutable state. It reads an immutable snapshot, reconciles instance generations/revisions into the existing Bugu `Mixer`, releases the snapshot lease, and renders PCM. Mixer cursors, ramps, filters, and effect delay remain render-owned; Control never reads or writes them. Offline and miniaudio backends both use the same `RuntimeFixedQuantumAdapter` and `RuntimeRenderer` path.

## Sample ownership and retirement

`SampleOwner` begins with one caller reference. A successful play command pins it; Control transfers that pin into desired state. Every live snapshot slot has an additional pin. When render starts a voice it takes a render pin before releasing the snapshot, so a bare PCM slice inside Mixer is always covered by an owner token.

`retire` prevents new external plays and drops the caller reference, but existing internal state/snapshot/render references may continue their pin chain while the count is nonzero. It is impossible to pin from zero. Natural finish or fade completion sends a bounded render-to-control completion, releases the render pin, and Control releases desired state. Retired snapshot slots release their pins only after all readers leave. The host may destroy payload bytes only when `canDestroy()` is true.

## Completion, shutdown, and device lifecycle

Render completions use a fixed SPSC ring; Control validates the full instance generation, retires state, and publishes a second bounded SPSC completion stream to the host. Completion overflow is atomic telemetry and never triggers callback allocation or logging.

Shutdown is idempotent by stages: `stopAccepting`, reserved `submitShutdown`, repeated control ticks and render callbacks until `drainStatus` succeeds, backend stop, then `destroy`. `destroy` refuses live queues/instances/render pins/readers, releases all retired snapshot pins, and clears completion observations. It does not wait, join, free, or perform I/O.

`RuntimeMiniaudioBackend` exposes `closed/open/running/lost/reopening/stopped`, a non-callback `notifyLost`, atomic miniaudio reroute/interruption notification polling, `reopen`, device generation, lost/reopen counters, and fixed-capacity actual device identity/format/period evidence. Its callbacks only enter the preallocated fixed-quantum adapter or store the lost-notification flag; reopen and evidence inspection remain Control-side. `RuntimeOfflineBackend` is the backend-neutral test path and does not count as physical-device evidence.

The fixed-quantum callback records duration into 32 fixed atomic log2 buckets and an atomic maximum. `TelemetryCounters.snapshot` performs the non-realtime p50/p95/p99 aggregation; the callback never sorts, allocates, locks, or formats telemetry.

## Callback audit surface

The reachable production callback chain is:

`runtimeDataCallback -> RuntimeFixedQuantumAdapter.render -> RuntimeRenderer.render -> acquireSnapshot/sync -> Mixer.render`

These functions use fixed arrays, scalar/atomic operations, bounded loops, and caller-provided output. They contain no allocator/free, mutex/wait/join, file/VFS I/O, logging/formatting, device reopen, or GPU operation. Resource destruction and miniaudio recovery remain non-callback operations.

The `runtime-embedding` build step is the compatibility sample. `zig build test` covers queue saturation and reserved control, concurrent four-producer/control/render stress, generation reuse, single-instance fade/stop completion, owner retirement, triple-snapshot pinning, 64-voice policy, and callback sizes 1/127/256/300/513.
