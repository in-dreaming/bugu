# Wire6 bounded actual-execution qualification

Runtime candidate: `982cb753ea4376ffba3631bf9e406ad4d78f70ca`; final test candidate: `6d2ff7c6605f237c448f34f95c08e0c278049472`.
Exact Debug executable SHA256: `23e14e5e26ba2c30ed28f515ac857025fefb62c8cae08bd015e6057bc42c65a2`.
Profile 9 / wire 6, explicit `joint_service_reads`, `notified_v1`, null device, streaming writer. No physical audio. Original admission default remains unchanged.

## Actual gates

One natural and one deliberately controlled recording on this corrected candidate both admitted; each was replayed in a separate process with the same executable, both controlled hooks absent, actual operations and complete reference comparison. Both replay reports have EOF, Host joined and Host destroyed true, two accepted/terminal commands, and zero discarded pending samples.

| Scene | Submitted frames | Matched Control / Worker / Render / UI | Submitted samples |
|---|---:|---|---:|
| Natural | 34,816 | 204899 / 185031 / 80400 / 5076 | 69,632 |
| Controlled | 36,096 | 196889 / 188861 / 82660 / 5544 | 72,192 |

Controlled INPUT-only witnesses use original actual values, not injected results:
- Frame read bracket `[3954,6572]` wholly encloses store `[5462,5463]`, observed read 768 and store 832.
- Slot 0, generation 1 consumed read `[24594,26868]` wholly encloses projection store `[25772,25773]`, observed read 384 and store 448.
- The same untouched controlled tape rejects with `UnsupportedOverlap` under the old `ordered_job_scans` policy, then admits under the new policy. These brackets do not establish unique microscopic atomic ordering.

Negative gates on the frozen controlled tape:
- One PCM reference float low-bit mutation, repaired integrity hashes, all INPUT bytes unchanged: actual Render `ReplayMismatch`, occurrence 2727, byte 2083; genuine join/destruction, 16 providers opened/closed, zero sample leases, no retained owner.
- Wrong pacing: `WrongLaunch` before native owner effects, zero matched operations.
- Controlled-hook environment during replay: `ControlledPauseForbiddenDuringReplay` before preflight/owner creation.

## Failure preserved, not rerolled

The first natural wire6 candidate `6a7678f` failed deterministically: interval pairing compared BEFORE 0 against the legitimate captured failed Render guard CAS AFTER 2. Its exact tape and executable are privately retained. No controlled capture ran on that candidate. A five-line correction validates the observed field and permits only the legitimate 0/2 AFTER change while preserving full identity equality. The exact unchanged failed tape then passes input-only admission with 172,447 joint operations; this is not native replay evidence. Only after the fix and affected gates was the corrected two-capture plan frozen and executed once per scene.

Control close AFTER 1 uses a different publication-identity path. A separate regression preserves that legitimate observed change and rejects role/site/index/generation mismatches. A test-development error initially expected the upstream error name at the interval layer; both layers are now separately asserted. No production relaxation followed that test error.

## Regression provenance

- Frozen core `7dea36e`: all 36 registered SME checks plus non-test production compile, Debug and ReleaseSafe each 113/113 steps, 319 passed / 5 skipped.
- Domain/dual-fixture delta `6a7678f`: affected checks Debug 17/17 and ReleaseSafe 14/14 steps; each 82 passed / 2 skipped.
- Pairing fix `982cb753`: affected codec, joint replay/gate, job replay, process, format, legacy rejection and production compile; Debug 29/29, ReleaseSafe 26/26 steps; each 121 passed / 3 skipped.
- Final codec-only test delta `6d2ff7c`: Debug and ReleaseSafe each 6/6 steps; 69 passed / 2 skipped.
- Independent small-history oracles: 194,040 original and 37,800 mixed histories, zero observed false accepts; bounded model only.

This is baseline-plus-affected-delta evidence, not a full-suite run on the final tree. The actual executable ran all 13 process tests in each successful record/replay invocation.

## Supported boundary and remaining product work

The profile uses true captured read/CAS observations as scheduling constraints, never as substituted native results. Finite deterministic admission is conservative; no backtracking, reroll, or arbitrary-history completeness claim. It jointly covers frame/sequence, job state, slot incarnation/guard and control-consumed projection constraints. Detached raw-readiness is explicitly unsupported. Scheduler whole-scan and other existing lifecycle/raw-progress checks remain strict; unsupported histories still reject before replay owners. This does not prove weak-memory behavior, unique original execution reconstruction, or the raw Ring/DSP/lifetime system solely from the scalar model.

Historical Render overflow was not reproduced or causally repaired; queues were not enlarged and records were not dropped. Current bounded success is not a universal real-time headroom guarantee. Full-product GUI/debugger integration, full-tree affected regression and current Windows validation remain separate acceptance obligations. This report qualifies the bounded headless runtime only, not all SME requirements. Public push remains blocked pending the separate exact disclosure authorization process; private source and exact execution artifacts are retained with verified readback.
