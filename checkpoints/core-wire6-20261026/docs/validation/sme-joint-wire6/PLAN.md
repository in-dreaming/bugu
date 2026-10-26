# Wire 6 proposal after the first controlled wire 5 failure

Status: implementation checkpoint, not Host-qualified. Independent design review permits the approach; implementation and domain-scope review remain in progress. No retry of the failed recording.

The captured real frame load/store overlap passed the independent bracket/value
witness. New policy correctly rejected a separate, later same-incarnation
control_consumed overlap. The failed recording remains immutable and cannot be
upgraded: its INPUT does not include the missing actual consumed observations.

## Implemented bounded extension
- Capture existing original AFTER point values for control_consumed acquires,
  Render control_consumed release stores, slot guard open/close/claim/release.
  No additional atomic read and no reference-to-input conversion.
- Increment wire/schema version; old histories require their exact original tool.
- Add a fixed stream-slot state domain to the same three-role planner, separate
  from job slots: guard (closed 2 / free 0 / Render-owned 1), incarnation and
  consumed prefix. Initial closed/zero; open resets prefix while publishing new
  incarnation; successful close ends lifetime. Failed CAS must match real state.
- Put every consumed read/store AND every guard/lifetime operation in the same
  chosen order as frame/sequence/jobs. Never compose two separately feasible
  orders while one thread holds a guard. Release remains an actual release.
- Generation-zero CAS identity is only a slot guard address, not a stream.
  Descriptor accesses and consumed observations require the matching live
  incarnation; initial/reset memory is excluded by the closed guard.
- Render publishes a raw-consumed value loaded BEFORE the store bracket. The
  joint planner models only control_consumed publication, not the raw load's
  microscopic position or a weak-memory proof.
- Deferral is permitted only with mandatory complete joint admission. All actual
  operations compare observations; mismatches fail and cleanly join, never retry
  a new order or inject a value.

## Unchanged explicit boundaries
Scheduler per-entry scalar scan values are absent. Whole prepare/reconcile/
acquire envelopes still exclude conflicting publication/phase/terminal/receipt/
cancellation. Supporting those histories requires actual additional observations,
not silently relaxing admission. Raw Ring consumed progress gates, Worker busy,
Runtime publication and mailbox calendars remain actual-operation mechanisms;
combined termination and held-resource negatives are required, not assumed.

## Gates before a new capture
Independent design review; pure state-machine tests plus independent small mixed
oracle; stale incarnation, same-value stores, false CAS, wrong source coordinate,
reset, held-guard cross-domain cycle and missing operations negatives. Production
codec/driver mixed real-thread tests must reject/abort/join. Then freeze source
and exact binary with private readback before a predeclared actual recording.
Natural and deliberately instrumented fixtures remain separate evidence. Full
product integration and Windows acceptance remain separate downstream work.

Pure planning is not a full descriptor-lifetime proof: job-slot IDs are not
mapped to stream handles in this model. Native close still checks pending job,
visibility references and Ring references before guard CAS. Those original
checks and exact comparison remain authoritative; no new suppression or inferred
job-to-stream feasibility is permitted. Successful planner admission alone does
not qualify a replay. The original real close, EOF and joins must still succeed.
