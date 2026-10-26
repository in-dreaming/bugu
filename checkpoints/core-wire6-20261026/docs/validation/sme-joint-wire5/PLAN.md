# Wire 5 joint Service observation candidate

Status: implementation checkpoint, NOT end-to-end qualified. This work addresses the supported headless Live recording/replay profile, not completion of the full 27-task SME editor/product roadmap.

## Frozen acceptance intent

- Keep current native_attempt and ordered_job_scans policy defaults and their strict overlap exclusions. Add explicitly selected joint_service_reads; no silent policy change.
- Wire/schema 5 records real Service frame AFTER values as scheduling INPUT from the original Point callback. Old v2/v3/v4 need their matching tools; never derive missing input from old references or rewrite their version headers.
- Jointly plan actual Service frame, sequence and job operations from three serial role streams, with before/after marker brackets and exact slot/job identity. Global frame/sequence keys are not per stream. A scalar identity normalization is performed only after canonical native role/site and matching bracket checks; the full native identity remains independently compared.
- One fresh Service epoch starts frame/sequence zero and free jobs. Sequence must follow odd -> one frame store -> even, without wrap; frames may repeat or advance. Read values constrain a finite feasible execution; they never become returned load values.
- The canonical planner has three heads and at most 48 fixed job slots, no event-count-sized graph or search tree. Each accepted atomic is assigned an ordered position in a dense marker gap: max(previous BEFORE, current BEFORE) must be less than every pending deadline. This is not an integer timestamp claim. No-progress is immediate rejection, not an unbounded retry. Conservative false rejection is permitted; no existential completeness claim.
- The real gate releases BEFORE global marker before waiting; actual AFTER completion validates values/identity and releases ordinal before entering its AFTER global marker. Three private immutable-input planner copies choose the same plan. Mismatch aborts; no result injection, alternate ordering, or cleanup counterfeit.
- Unscheduled consumed/guard/lifetime and Scheduler overlap exclusions remain strict. Existing raw consumed, mailbox, runtime-frontier and busy-claim calendars remain active. Their marker embedding/claim-path composition must be reviewed and tested before qualification; pure local model success alone is insufficient.
- No occurrence drops, larger lane buffers, reduced PCM oracle, lower long workload, or altered production supply policy.

## Gates before qualification

1. Pure joint schedule tests plus an independent small mixed-domain enumerator; accepted plans must satisfy its actual state interpretation and bracket constraints.
2. Codec role/edge/version/input rejection, gate actual-value mismatch/EOF/abort and current negative regression suites.
3. One newly built, bounded, genuine long recording (>=32768 frames), sealed and strict admitted. Failed first attempts remain evidence; no reroll to select a favorable history.
4. The same ELF in a fresh process runs actual Host/decoder/renderer and compares PCM, Input, Schedule, commands, native facts and every role EOF. True join/destroy/provider closure required.
5. Wrong identity/pacing/version fail before owner; comparison mutation fails during actual execution with cleanup.
6. Final Debug engine + existing ReleaseSafe SHA and ReleaseSafe regression results, source/tree/ELF/input identities, and independent integration review.

Render collector throughput and original physical-device qualification remain separately evidenced. The current headless import excludes the full GPU authoring panel/debugger; this is not a waiver of original TASK-018/019/024 product requirements.

## Deterministic actual-Host overlap fixture

The first uninstrumented wire5 long recording and same-ELF fresh replay passed, but the same tape also passed old ordered_job_scans admission. Therefore it is NOT evidence of the newly admitted overlap.

A separate explicit test-only controlled workload now pauses Control after an original Service frame load but before its AFTER marker. It waits for two actual Render even notifications, avoiding a delayed notification from a store already completed before the load. No Recorder callback waits, no load result changes, and non-test compilation removes the seam. Timeout, cancellation or unhealthy capture makes the fixture fail; a final post-wake check prevents a delayed wake from masquerading as an in-budget success.

After genuine joins, an independent INPUT cursor scan must find read.before < store.before < store.after < read.after with actual_store > actual_read, matching the recorded loaded frame. The untouched tape must fail old ordered_job_scans admission with UnsupportedOverlap and pass joint_service_reads. Fresh same-ELF replay forbids the workload option and must reproduce actual reads and all outputs without the capture pause. This controlled run remains separate from the uninstrumented natural sample; no repeated recording to hunt a favorable interleaving.
