# Live integrity SHA-256 source and license

## Provenance

- Upstream: Zig 0.16.0, `lib/std/crypto/sha2.zig`.
- Source URL: https://github.com/ziglang/zig/blob/0.16.0/lib/std/crypto/sha2.zig
- Release distribution: https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz
- Complete original `sha2.zig` SHA-256: `e58c67128f2c754049f737688ddcef809c017dbdd6de59995da3fbe99938db85`.
- Upstream `LICENSE` SHA-256: `5c537d6853e005298a285d508cff9ac7192cea23576c840d485b2b586a7ff177`.
- Local derivative: `src/music/live_integrity_hash.zig`.

The original distributed source, not a rewritten SHA-256 implementation, is the
baseline. SHA-NI was already enabled on eligible targets. This change does not
enable a new acceleration path or change CPU feature selection.

## Exact extraction and change audit

The derivative preserves these two complete byte ranges, concatenated in order:

1. Lines 51-63: the `iv256` documentation and declaration, including
   its following blank line. Start at `/// First thirty-two bits of the fractional
   parts of the square`; stop immediately before the `iv384` documentation.
2. Lines 89-404: `Iv32`, `Sha2x32`, `RoundParam256`, and
   `roundParam256`, including blank lines. Start at `const Iv32 = [8]u32;`; stop
   immediately before `test Sha224 {`.

Original concatenated excerpt SHA-256:
`746862688c85870a622075c216e3964ae3799a90da90325ed0d5671331154863`.

The only expression substitution inside those inherited ranges is the second
SHA-NI round's `xmm0` input:

```zig
// Original:
@as(V4u32, @bitCast(@as(u128, @bitCast(w)) >> 64))
// Derivative:
shaNiSecondRoundWords(w)
```

The added public `inline` pure helper has exactly the `@Vector(4, u32)` input and
output type and consists of this expression, with no other logic:

```zig
@shuffle(u32, w, @as(V4u32, @splat(0)), [4]i32{ 2, 3, -1, -2 })
```

On x86_64's little-endian representation, both expressions yield all 128 bits
`[w[2], w[3], 0, 0]`. The negative mask indices select zero lanes 0 and 1 of the
second vector. The helper is deliberately shared by the production expression
and its independent lane-equivalence test.

Other mechanical additions are the file header, imports relocated from
`@import("../std.zig")` to `@import("std")`, the original `builtin`, `mem`, and
`math` aliases, the original `Sha256 = Sha2x32(iv256, 256)` export, and a read-only
`compilation_mode = builtin.mode` marker for qualification. Unrelated hash
variants and upstream test imports are not extracted.

The existing `!@inComptime()` check, architecture switch, x86_64 `sha` plus `avx2`
feature guard, C-backend exclusion, assembly constraints, ARM path, scalar path,
padding, lengths, state, and streaming methods are unchanged. There is no
`@setRuntimeSafety`, optimization-mode override, alternate algorithm, or new
runtime feature dispatch. Importing this file from the ordinary music module
keeps the same compilation mode as that module. Untouched ARM source is not a
claim of ARM runtime validation.

To reproduce the byte audit with the complete original source available:

```python
from pathlib import Path
import hashlib
original = Path("path/to/zig-0.16.0/lib/std/crypto/sha2.zig").read_bytes()
derivative = Path("src/music/live_integrity_hash.zig").read_bytes()
assert hashlib.sha256(original).hexdigest() == "e58c67128f2c754049f737688ddcef809c017dbdd6de59995da3fbe99938db85"
a = original.index(b"/// First thirty-two bits of the fractional parts of the square\n")
b = original.index(b"/// First sixty-four bits of the fractional parts of the square\n", a)
c = original.index(b"const Iv32 = [8]u32;\n")
d = original.index(b"test Sha224 {\n", c)
expected = original[a:b] + original[c:d]
actual = derivative[derivative.index(original[a:b]):]
old = b"@as(V4u32, @bitCast(@as(u128, @bitCast(w)) >> 64))"
new = b"shaNiSecondRoundWords(w)"
assert actual.count(new) == 1
assert old not in actual
assert actual.replace(new, old) == expected
assert hashlib.sha256(expected).hexdigest() == "746862688c85870a622075c216e3964ae3799a90da90325ed0d5671331154863"
```

## Qualification boundaries

`tests/sme/live_integrity_hash_test.zig` covers known empty, `abc`, long, and
million-`a` vectors; inherited scalar evaluation at comptime; differential
standard-library comparisons at padding/block boundaries and unaligned input
addresses; streaming, empty updates, splits, state copies and non-mutating
`peek`; and full-width lane equivalence against the original expression on
little-endian targets.

The offline measurement is one fixed 1 MiB batch for standard and derivative
hashers, in that order, with digest comparison. It reports actual caller/module
mode, target/backend and relevant feature flags, monotonic wall time and bytes
per second. It does not assert a performance floor, retry, auto-select a better
run, execute a native capture, or use measurements as a cryptographic proof.
Qualification in Debug requires the external build invocation and reported
mode to actually be Debug; this file does not force Debug in other builds.

## Upstream license (verbatim)

```text
The MIT License (Expat)

Copyright (c) Zig contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```
