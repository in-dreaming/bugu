# T006 Asset import、Decode、Bank MVP

状态：TODO  
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

## 7. Activity Log

- 2026-07-07：任务创建。
