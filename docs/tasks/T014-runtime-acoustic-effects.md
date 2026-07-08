# T014 Runtime acoustic effects integration

状态：DONE  
类型：Implementation  
优先级：P2  
依赖：T011,T012,T013  
预计产物：voice handle/update path、real mixer reverb send、acoustic effects demo、[effects snapshot](../validation/acoustic-t014-effects-snapshot.txt)

## 1. 背景

T011 已经把 `AcousticResponse` 映射到 `AcousticMixerSnapshot`，但仍主要通过 demo layer 参数证明映射。T014 将这些参数接入真实 mixer 运行路径：voice handle、参数更新、early reflection delayed layers、late reverb send。

## 2. 实现范围

- Stable `VoiceHandle` generation id for mixer voices.
- Control-side voice parameter update for gain、pan、lowpass、pitch、reverb send.
- Fixed-size mixer reverb send/return path，render thread 无 allocation/lock/I/O/GPU wait。
- Acoustic effects demo：door closed/open portal update、transmission layer、cave direct/reflection/reverb send。

## 3. 验收标准

- 不按场景名写 mixer 参数；参数来自 T010 solver 和 T011 snapshot mapping。
- 不直接改 voice hot data 绕过 public engine/mixer method；demo 通过 `Engine.startTestVoiceWithHandle` 和 `Engine.updateVoice`。
- Offline render 输出真实 sample telemetry，peak/RMS 非零，clipping=0。
- Reverb send produces delayed tail in mixer unit test.
- Existing T004-T013 validation remains green.

## 4. Evidence

- `zig build test` 通过。
- `zig build acoustic-effects-demo` 通过。
- Demo 输出保存到 [acoustic-t014-effects-snapshot.txt](../validation/acoustic-t014-effects-snapshot.txt)：
  - door_closed_portal=0.00201
  - door_open_portal=0.07408
  - cave_reverb=1.00000
  - rendered frames=28928
  - peak=0.318379
  - rms=0.082150
  - active=7
  - clipping=0

## 5. Activity Log

- 2026-07-08：新增 voice handle/update path、per-voice `reverb_send`、fixed reverb delay line、engine facade exports。
- 2026-07-08：新增 `examples/acoustic_effects_demo.zig` 和 `zig build acoustic-effects-demo`，使用 T010/T011 输出驱动真实 mixer/offline render。
- 2026-07-08：验证 `zig build test`、`zig build acoustic-effects-demo` 通过；无 mock、无 fallback、无直接写 audio render thread mutable state。
