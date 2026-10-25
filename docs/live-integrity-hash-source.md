# Live integrity SHA-256 compilation boundary

Profile 9 uses the official Zig 0.16.0 `std.crypto.hash.sha2.Sha256` unchanged.
There is no retained copied SHA implementation, custom compression round, new
CPU feature selection, reduced digest, or weaker validation. The earlier
pure-Debug lane-shuffle experiment passed correctness tests but failed its
predeclared one-sample performance gate. Its commits and results remain history;
this candidate removes the maintenance fork rather than describing it as a fix.

## Explicit hybrid build

The build creates one target-matched standalone object from
`src/music/live_integrity_hash_backend.zig` with `ReleaseSafe`. That compilation
unit has its own root and official standard library. The object is linked into
music consumers and production archives. All engine, recorder, runtime, tests
and frontend code retain the requested build mode. A Debug qualification is
therefore **Debug engine + ReleaseSafe SHA-256**, not an entirely Debug binary.
A wrapper module alone is not relied on to change globally owned std functions.
Runtime safety is not disabled. No global toolchain or compiler options change.

The frontend retains the SHA-256 API used by the format, streaming writer and
executable identity hashing. A shared internal C ABI carries explicit logical
state fields, not Zig automatic-layout assumptions or a new persisted format.
The backend copies those fields into and out of its official std implementation.
This adds bounded state-copy cost per call and requires no allocation, locks,
clock calls, device activity or engine callback. Value copies and peek must
preserve streaming semantics. Compile-time use remains the official std path.
The ABI and actual backend build-mode metadata are checked by focused tests.

## Integrity and qualification

Header, per-record payload and whole-stream SHA-256 checks, full executable
identity, wire version, writer order, short-write accounting, poisoning and
capacity limits are unchanged. The wire oracle constructs fixed wire-4 bytes
using literal fields and the original std implementation, independently of the
candidate writer and frontend. A payload corruption with only the outer digest
repaired must still fail the original per-record check.

Focused gates include known vectors, boundary lengths, unaligned inputs, split
updates, empty updates, copies, peek, compile-time vectors, actual ABI/mode
identity, independent wire equality and existing streaming error tests. One
fixed 1 MiB standard-Debug then isolated-SHA batch for each of one-shot and
64-byte-chunk streaming reports consumed equal digests
and elapsed wall times, including scheduling and order/cache effects. It is not
a universal CPU benchmark. Native recording is permitted only after the frozen
correctness and improvement gates pass, using unchanged lane capacities and
strict admission. No timing retries are allowed to select a favorable result.

Actual native record, same-executable fresh replay, negative rejection and real
resource teardown remain separate qualifications. Neither the isolated object
nor an offline timing improvement proves that the recorder can keep up. Existing
Debug overflow and failed hypotheses remain evidence. Windows and other CPU
architectures require their own validation; no such new qualification is claimed
by this cloud change.
