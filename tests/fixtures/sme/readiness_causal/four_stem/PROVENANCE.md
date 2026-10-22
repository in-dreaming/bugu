# Exact four-stem public causal regression inputs

These are the original Lantern Circuit source inputs produced by the repository's
`examples/sme/assets/generate.py` from `examples/sme/assets/score.json`. Each WAV
hash below matches the existing `examples/sme/LICENSES/assets.toml` inventory and
the authored `source_import.source_hash`; no external assets or dependencies
were added. See LICENSE and NOTICE.md.

The source is the prepared CLI DIRECT variant, copied byte-for-byte. Relative to
`examples/sme/stream-direct-v1/project.toml`, all four transition fallbacks change
from `next_boundary` to `reject` and all eight transition/path references to the
unused zero-step fills are removed. The four unused fill declarations remain.
No exit/entry cue, loop, frame count, stem, source hash, gain or timing is changed.

The test compiles this source and its sixteen genuine WAV files through the
existing compiler and Opus media pipeline. It records/recomputes through the
existing public example with initial state `explore`, eight 256-frame quanta and
seed 1. It does not embed a compiled bank, plans, PCM proof or expected outcomes.
The three original unused fill/stinger WAVs are omitted.

Source SHA-256: 775128188dee97898ca0a9da1599acb26b61ec659946621c84262567c455650f

| Source WAV | Bytes | SHA-256 |
| --- | ---: | --- |
| audio/explore-harmony.wav | 768044 | ede2f4f9a85951f7d8515d3a034b18204425479756712b253c177995d3252272 |
| audio/explore-bass.wav | 768044 | 3c88f75469ef251dba8d3c28440f208fc3724c66a2dfe32e00974c04c08c32af |
| audio/explore-motif.wav | 768044 | d3214c12e595629a583a1e42d48997a7c4b6fbc61dc40f71a83125b95d4b0545 |
| audio/explore-percussion.wav | 768044 | a1b477aff2fbf80769df5f4ee5c678e4a1de52724bcce77767715b0c39af91ec |
| audio/tension-harmony.wav | 768044 | cba19e54f4fa8dac970c4491b16b7a3217f8fce333081ff09acba1f53db989e0 |
| audio/tension-bass.wav | 768044 | 67308dc315b44c56abf558eb20ed452e319ae19a6ddc3de19035e8cd6f3ec65f |
| audio/tension-motif.wav | 768044 | 17aeed15e6cfeb2c9dc9f6310a7db5f34ff5050764b1fc285d660ddc95ca81d1 |
| audio/tension-percussion.wav | 768044 | 90bcf85cdbd5ce37764d94d162b0addc1c8085f54456aef41376314cd18d7737 |
| audio/combat-harmony.wav | 768044 | 638c779b91c4af4f3f937a1a0ef26f0ec64fb2ec9e1a97ab4c6ebf57bd01a7b8 |
| audio/combat-bass.wav | 768044 | 7164a98b3c707ce0861284ab1b911dcec653a6732932be1948076260acbc857b |
| audio/combat-motif.wav | 768044 | 70abf722d68b75321be9fea5a83ad2263591b402904148b0cf0ea3c14f8f2b16 |
| audio/combat-percussion.wav | 768044 | 0a10675d160adf04fcc94d3ac8b8be90c5c391a53ea0c99599147d46c45f81e2 |
| audio/dialogue-harmony.wav | 768044 | a2547eec72cec9cec77b4126548d5f61c4f4fbe179438621f40158642a259d4e |
| audio/dialogue-bass.wav | 768044 | 4426c434f52e298bbf812749b572c50d4d00843737783f24cb51bdd8051c88e2 |
| audio/dialogue-motif.wav | 768044 | 1d9a0e0ea3ae641d8b14106df2fe7bb630f0ff462e1bb3076039dd86f96bb102 |
| audio/dialogue-percussion.wav | 768044 | c2fbe465fcca634334e9cc4b3af76d2269e354b42b1690899ae2c6337724142a |
