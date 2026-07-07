# T005 Mixer、Voice、Bus core 实现

状态：DONE  
类型：Implementation  
优先级：P0  
依赖：T002，T003，T004  
预计产物：固定 quantum mixer、voice pool、simple bus、测试 demo。

## 1. 背景

Mixer core 是引擎心脏。P0 目标不是音质极致，而是稳定、可测、实时安全。

## 2. 必读

- docs/tasks/asetup.md
- docs/design/audio-engine-design.md 第 5、6、12、14 节
- T002、T003、T004 产物

## 3. 实现范围

必须实现：

- fixed quantum mixer，默认 256 frames，内部 float32。
- Voice pool，至少 64 real voices。
- Voice state：Free、Starting、Real、Virtual、Releasing、Stolen、Paused。
- mono input 到 stereo output。
- gain ramp，避免 click。
- simple bus：SFX、Music、Master 至少三类。
- simple limiter 或 clipping counter。
- telemetry：active voices、virtual voices、stolen voices、peak、RMS、mixer time。

## 4. 不需要实现

- 完整 Bus DAG。
- HRTF。
- 复杂 effect chain。
- streaming decode。
- acoustic propagation。

## 5. 验收标准

- 可同时播放 64 个 test voices，无明显爆音。
- 超过 voice limit 时触发可解释的 stealing 策略。
- 所有热路径无动态分配。
- gain ramp 能避免 start/stop click。
- telemetry 可从非 audio thread 查询。
- demo 证明 backend callback 调用 mixer，而不是直接生成 sine。
- Evidence 必须包含真实 sample buffer 的 peak/RMS、voice count、steal count、mixer time 记录。
- 至少一个测试必须离线渲染固定输入并比较输出摘要，避免“听起来可以”成为唯一证据。

## 6. 测试场景

- 1 voice sine。
- 64 voices 不同频率和 gain。
- 128 voice requests，确认 stealing。
- 快速 start/stop 1000 次。
- master volume ramp。

## 6.1 禁止 mock

- 不能用预混好的 wav 或固定数组冒充 mixer 输出。
- 不能只更新 telemetry 而不生成 sample。
- voice stealing 必须基于 voice state/priority/audibility 数据，不能按调用次数硬编码。

## 7. Deliverables

- `src/mixer/mixer.zig`：fixed quantum mixer、64 real voice pool、voice state enum、gain ramp、SFX/Music/Master bus gain、clipping counter、peak/RMS/voice/steal/mixer-time telemetry。
- `src/core/engine.zig`：Engine render path now owns `Mixer`; public test voice scheduling and bus/master gain controls for T005/T006/T007 demos.
- `src/device/device.zig`：offline and miniaudio backends render through `FixedQuantumAdapter` -> `Engine.render` -> `Mixer.render`; offline buffer now supports the configured max quantum.
- `examples/tone_demo.zig`：demo supports `--voices`, schedules voices through Engine/mixer, and prints active/virtual/stolen/clipping/RMS/mixer-time telemetry.
- Removed direct `src/mixer/tone_renderer.zig` path so backend callback no longer generates sine directly.

## 8. Evidence

- Build/test command:
  - `zig build test`
  - Result: passed.
- Offline 64-voice command:
  - `zig build tone -- --offline --seconds 2 --voices 64 --out bugu-mixer-64.wav`
  - Output summary: `callbacks=375 frames=96000 quantums=375 underruns=0 dropouts=0 max_callback_ns=0 peak_abs=0.342439`
  - Mixer telemetry: `active=64 virtual=0 stolen=0 clipping=0 rms=0.051835 mixer_time_ns=299800`
  - WAV output summary before cleanup: `bugu-mixer-64.wav`, `384044` bytes.
- Offline 128-request stealing command:
  - `zig build tone -- --offline --seconds 2 --voices 128 --out bugu-mixer-128.wav`
  - Output summary: `callbacks=375 frames=96000 quantums=375 underruns=0 dropouts=0 max_callback_ns=0 peak_abs=0.431696`
  - Mixer telemetry: `active=64 virtual=0 stolen=64 clipping=0 rms=0.051849 mixer_time_ns=311700`
  - WAV output summary before cleanup: `bugu-mixer-128.wav`, `384044` bytes.
- Real device mixer command:
  - `zig build tone -- --device --seconds 5 --voices 64`
  - Output summary: `callbacks=930 frames=238080 quantums=930 underruns=0 dropouts=0 max_callback_ns=0 peak_abs=0.342447`
  - Mixer telemetry: `active=64 virtual=0 stolen=0 clipping=0 rms=0.004247 mixer_time_ns=321000`
- Tests cover:
  - 1 voice sine via `engine renders nonzero stereo samples`.
  - non-quantum callback adapter via `offline backend writes samples`.
  - 64 real voices and 128 requests/stealing via `mixer renders 64 real voices and steals beyond limit`.
  - gain release ramp via `gain ramp releases without discontinuous hard stop`.
  - 1000 rapid start/stop and master ramp via `rapid start stop and master ramp stay bounded`.
- Real implementation path:
  - `MiniaudioBackend.dataCallback` calls `FixedQuantumAdapter.render`.
  - `FixedQuantumAdapter.render` adapts callback frame counts to 256-frame `Engine.render` calls with a preallocated pending buffer.
  - `Engine.render` calls `Mixer.render`.
  - `Mixer.render` walks fixed voice pool state and writes real stereo samples.
- Realtime-safety note:
  - Mixer hot path does not allocate, lock, perform file I/O, format logs, call decoders, or wait on GPU.
  - Voice pool, pending buffer, and output buffers are fixed capacity.

## 9. Activity Log

- 2026-07-07：任务创建。
- 2026-07-08：开始 T005，读取 T002/T003/T004 产物并替换 direct tone renderer 为 mixer/voice/bus path。
- 2026-07-08：实现 fixed quantum mixer、64 voice pool、gain ramp、bus gain、stealing、clipping/peak/RMS/voice/mixer-time telemetry 和 demo `--voices` 参数。
- 2026-07-08：通过 unit tests、64/128 voice offline render、64 voice real-device smoke；状态置为 DONE。
