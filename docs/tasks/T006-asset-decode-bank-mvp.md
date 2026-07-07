# T006 Asset import、Decode、Bank MVP

状态：DONE  
类型：Implementation  
优先级：P0/P1  
依赖：T001，T003，T005  
预计产物：asset manifest、WAV/PCM importer、Bank MVP、加载测试。

## 1. 背景

运行时不能直接散读任意源音频文件。P0 可以先用简单 manifest 和 blob，P1 再稳定二进制 Bank。

## 2. 必读

- docs/tasks/asetup.md
- docs/design/audio-engine-design.md 第 7 节
- T001 codec 结论
- T003 Zig API / 可选 C ABI 设计

## 3. 实现范围

P0 必须实现：

- WAV/PCM import。
- 源文件 metadata 提取：sample rate、channels、duration、format。
- 转成内部可播放格式：48 kHz float32 或明确约定的 P0 格式。
- 临时 JSON 或 TOML manifest。
- SoundEntry 表。
- Bank load/unload 的最小 runtime。
- 小音效 preload。

P1 设计但可不实现：

- streaming chunk table。
- seek table。
- codec variants。
- hash 和依赖图。
- waveform preview。

## 4. 验收标准

- 能从 manifest 播放至少 3 个真实 WAV 文件；测试资产需要放在明确的 testdata 路径或由脚本生成。
- mono 和 stereo 输入行为明确，3D sound 使用 mono 或定义 downmix。
- Bank unload 时正在播放的 voice 行为明确。
- importer 输出 peak/RMS 或至少 peak。
- 不在 audio render thread 做文件 I/O 或 decode。
- decoder 三方库如果引入，必须通过 git submodule，并在 build.zig 中显式接入。
- Evidence 必须包含每个 WAV 的 metadata、生成的 manifest/blob 摘要、播放或离线渲染摘要。

## 5. 风险点

- 如果 P0 不做重采样，必须在文档中限制输入 sample rate。
- 如果 runtime decode 暂不做，必须明确 streaming 任务后续入口。
- 如果只支持 PCM/WAV，这是允许的 P0 fallback；但不能宣称完成 Vorbis/Opus/streaming。

## 6. 禁止 mock

- 不能手写假 metadata 冒充 importer 输出。
- 不能让运行时直接读取源 wav 来绕过 Bank/manifest。
- 不能把空 blob 或固定 sine 当作导入资产。

## 7. Deliverables

- `src/assets/bank.zig`：P0 WAV/PCM importer, TOML-style manifest writer/parser, raw float32 mono blob writer/loader, `Bank`/`SoundEntry` runtime structures, preload-only bank unload via `Bank.deinit`.
- `src/mixer/mixer.zig` and `src/core/engine.zig`：sample-backed voices via `SampleVoiceDesc`, so loaded bank entries can render through the existing mixer path.
- `examples/asset_demo.zig`：generates three real WAV files, imports them into `bugu-bank.toml` + `bugu-bank.blob`, loads the bank, starts sample voices, and offline-renders `bugu-bank-render.wav`.
- `build.zig`: adds `zig build asset-demo`.

## 8. Evidence

- Build/test command:
  - `zig build test`
  - Result: passed.
- Asset demo command:
  - `zig build asset-demo`
  - Generated real input WAV files:
    - `bugu-asset-a.wav`: `24044` bytes, mono, 48 kHz, 12000 frames.
    - `bugu-asset-b.wav`: `48044` bytes, stereo, 48 kHz, 12000 frames.
    - `bugu-asset-c.wav`: `24044` bytes, mono, 48 kHz, 12000 frames.
  - Generated bank files:
    - `bugu-bank.toml`: `424` bytes.
    - `bugu-bank.blob`: `144000` bytes, float32 mono samples.
  - Generated playback output:
    - `bugu-bank-render.wav`: `38444` bytes, real offline render through Bank -> sample voice -> Mixer -> OfflineBackend.
- Asset demo output:
  - `asset demo imported=3 total_frames=36000 blob_bytes=144000 import_peak=0.249969`
  - `sound id=tone_a_mono rate=48000 source_channels=1 frames=12000 offset=0 peak=0.249969 rms=0.176758`
  - `sound id=tone_b_stereo rate=48000 source_channels=2 frames=12000 offset=48000 peak=0.249969 rms=0.176757`
  - `sound id=tone_c_mono rate=48000 source_channels=1 frames=12000 offset=96000 peak=0.249969 rms=0.176758`
  - `render callbacks=38 frames=9728 active=3 peak=0.128414 rms=0.069680 stolen=0 clipping=0`
- Manifest excerpt:
  - `[[sounds]] id = "tone_a_mono" sample_rate = 48000 source_channels = 1 frames = 12000 offset_bytes = 0 peak = 0.24996948 rms = 0.17675766`
  - `[[sounds]] id = "tone_b_stereo" sample_rate = 48000 source_channels = 2 frames = 12000 offset_bytes = 48000 peak = 0.24996948 rms = 0.17675728`
  - `[[sounds]] id = "tone_c_mono" sample_rate = 48000 source_channels = 1 frames = 12000 offset_bytes = 96000 peak = 0.24996948 rms = 0.17675819`
- Input behavior:
  - P0 supports RIFF/WAVE PCM16 and float32 at 48 kHz, 1 or 2 channels.
  - Mono is imported directly.
  - Stereo is downmixed to mono for the P0 mixer/sample voice path; this is the intended behavior for later 3D sounds.
- Bank runtime behavior:
  - Runtime loads from manifest/blob, not source WAV files.
  - Small sound data is preloaded into immutable `Bank.samples`.
  - Active sample voices hold slices into the loaded bank; callers must delay `Bank.deinit` until voices are stopped or finished. Full ref-counted bank lifetime remains for later runtime tasks.
- Limitations:
  - No resampling; non-48 kHz input is rejected.
  - No streaming, seek table, compressed Vorbis/Opus, hash/dependency graph, or waveform preview is claimed.
  - No third-party decoder was introduced for P0; the WAV PCM subset is implemented in Zig, so no new submodule is needed.

## 9. Activity Log

- 2026-07-07：任务创建。
- 2026-07-08：开始 T006，读取 T001/T003/T005 产物并 scope 为 P0 WAV/PCM preload bank。
- 2026-07-08：实现 WAV metadata/PCM decode、TOML manifest/blob generation, runtime Bank load/unload, sample voice playback and asset demo.
- 2026-07-08：通过 `zig build test` and `zig build asset-demo`; 状态置为 DONE。
