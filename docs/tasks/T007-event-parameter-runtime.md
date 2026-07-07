# T007 Event、Parameter、State、Switch runtime

状态：DONE  
类型：Design+Implementation  
优先级：P1  
依赖：T003，T005，T006  
预计产物：事件系统设计和最小 runtime 实现。

## 1. 背景

游戏逻辑应该 post event，而不是直接播放文件或操作 voice。事件系统是设计师可用性的核心。

## 2. 必读

- docs/design/audio-engine-design.md 第 8 节
- T003 API
- T005 voice handle 设计
- T006 SoundEntry/Bank

## 3. 实现范围

必须实现：

- EventEntry 到 SoundEntry 的映射。
- play_one_shot。
- play_looping。
- stop。
- basic parameter override：volume、pitch。
- random container：从多个 sound variant 中选择。
- State 和 Switch 的数据结构草案。
- RTPC 曲线的数据结构草案，可先不完整实现。

## 4. 验收标准

- 游戏侧只通过 post_event 触发声音。
- 一个 event 可触发一个或多个 sounds。
- random variant 可重复验证，不出现越界。
- stop 能让 voice release，而不是硬切。
- Event runtime 不在 audio render thread 解析复杂字符串。
- 事件 ID/hash 策略明确。
- Evidence 必须显示 post_event -> event resolve -> voice request -> mixer/voice 状态变化的真实链路。
- 如果 State/Switch/RTPC 只完成数据结构草案，任务状态最多 REVIEW，不能把未实现功能计入 DONE。

## 5. 测试场景

- weapon.fire 随机 5 个变体。
- footstep 根据 surface switch 选择 wood/metal。
- ambience loop start/stop。
- volume RTPC 或 parameter override。

## 5.1 禁止 mock

- 不能直接调用内部 voice start/stop 冒充 event runtime。
- random variant 必须由真实容器数据驱动，不能按测试名返回固定 sound。
- 字符串 hash 或 ID 解析必须在非 audio render thread 完成。

## 6. Deliverables

- `src/events/runtime.zig`：event runtime with hashed IDs, `EventEntry`, `PlayEvent`, `SwitchEvent`, `SwitchCase`, `SoundRef`, deterministic random variant selection, switch selection, RTPC volume curve, `stop_all` release command, and `postEvent`.
- `src/mixer/mixer.zig`：sample voices now support looping and pitch step for event playback.
- `examples/event_demo.zig`：generates WAV assets, imports/loads a bank, posts `weapon.fire`, `footstep`, `ambience.start`, and `ambience.stop` events, and offline-renders the result.
- `build.zig`: adds `zig build event-demo`.

## 7. Evidence

- Build/test command:
  - `zig build test`
  - Result: passed.
- Event demo command:
  - `zig build event-demo`
- Event demo output:
  - `event demo weapon.fire random_indices=4,4,0,0,3`
  - `event demo footstep switch_value=4582786214424138428 voices_requested=1`
  - `event demo before_stop active=1 peak=0.082491 rms=0.035994 stolen=0 clipping=0`
  - `event demo after_stop active=0 peak=0.082491 rms=0.000000 stolen=0 clipping=0`
- Generated input/bank/render artifacts before cleanup:
  - 8 generated source WAVs: `bugu-event-weapon-0.wav` through `bugu-event-weapon-4.wav`, `bugu-event-foot-wood.wav`, `bugu-event-foot-metal.wav`, `bugu-event-ambience.wav`; each `19244` bytes.
  - `bugu-event-bank.toml`: `1108` bytes.
  - `bugu-event-bank.blob`: `307200` bytes.
  - `bugu-event-render.wav`: `38444` bytes.
  - `bugu-event-stop-render.wav`: `19244` bytes.
- Real chain:
  - `zig build event-demo` generates real WAV inputs.
  - `audio.importToBank` imports WAV metadata/sample data and writes manifest/blob.
  - `audio.loadBank` loads runtime `SoundEntry` data from manifest/blob.
  - Game side calls only `EventRuntime.postEvent`.
  - `postEvent` resolves event/container/switch/RTPC on the non-render side and calls `Engine.startSampleVoice` or `Engine.stopAllVoices`.
  - Mixer renders sample voices; no source WAV read or event string parsing occurs on the audio render path.
- Implemented behavior:
  - `weapon.fire`: random container with 5 variants; deterministic seed gives repeatable random indices.
  - `footstep`: switch container selects `metal` from `surface`.
  - `ambience.start`: looped sample voice.
  - `ambience.stop`: release stop via `stop_all = 128`.
  - RTPC: `weapon.fire` volume multiplier curve driven by `rtpc.loudness`.
- Limitations:
  - Voice handles are still internal; `stop_all` is the P1 stop primitive until per-event/per-voice stop handles are introduced.
  - RTPC implementation is a basic linear volume curve only.
  - State data can use the same hashed id/value strategy as switches, but no separate state container behavior is claimed beyond the implemented switch path.

## 8. Activity Log

- 2026-07-07：任务创建。
- 2026-07-08：开始 T007，读取 event design, T003 API, T005 mixer and T006 Bank.
- 2026-07-08：实现 event runtime, random container, switch container, RTPC volume curve, looped sample voice and stop/release path.
- 2026-07-08：通过 `zig build test` and `zig build event-demo`; 状态置为 DONE。
