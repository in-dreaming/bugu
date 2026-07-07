# Audio backend, decoder, codec selection research

状态：T001 deliverable  
访问日期：2026-07-08（Asia/Shanghai）  
范围：后端、decoder、codec、submodule 策略。本文不实现代码、不引入依赖。

## Executive summary

Bugu 现有方向仍成立：**P0 用 miniaudio 的 low level device API 打通设备输出，Bugu 自研 mixer/render hot path；P1 增加 SDL3 Audio 对照后端和 editor/tool backend；P2 启动主平台 native backend。** SDL_sound 只应作为可选导入/decoder adapter，不应进入 L1/L2 设备后端设计。

P0 codec 集合应收窄为 **PCM/WAV + WAV ADPCM 子集**。这样可以让 T006 先证明真实 asset pipeline、metadata、seek/preload 策略，而不把 compressed streaming、sample-accurate seek、专利/许可、跨平台构建风险提前塞进 P0。P1 再引入 **Vorbis streaming**；Opus 适合 dialogue、VOIP-style 和长音频，但需要单独验证 seek、预跳过、容器、延迟和 build 复杂度后再进 runtime。FLAC/MP3 更适合作为 asset importer 输入格式，不建议作为 Bank runtime 主格式。

第三方依赖必须通过 git submodule 引入并 pin 到 tag/commit。单文件库也不能复制源码进仓库；应 submodule 到 `third_party/*`，由 `build.zig` 显式添加 include path 和一个带 `*_IMPLEMENTATION` 宏的 C translation unit。

## Decision matrix

### Backend candidates

| 方案 | 阶段 | 结论 | 主要理由 | 限制 |
|---|---|---|---|---|
| miniaudio low level device | P0 | 推荐 | 单仓库、跨平台 backend 覆盖广；device callback 正好承载 Bugu mixer；有 backend 裁剪、custom/null backend | 不使用 high level engine/node graph/resource manager 作为 Bugu 运行时主体；callback 内仍遵守无 I/O/alloc/lock |
| SDL3 Audio via `in-dreaming/SDL.git` `enjin/gpu/main` | P1 | 推荐为对照、editor/tool、fallback backend | SDL3 AudioStream 覆盖播放、转换、stream buffer、device callback；逻辑设备和默认设备迁移对工具友好 | 只能使用指定 fork/branch；不能用 upstream SDL 替代；需要 Zig binding 层和 fork 差异审查 |
| SDL_sound | P1/P2 | 仅可选 decoder/import adapter | 官方定位是解码多种 sound file，输出 waveform，可分块或整文件 decode | 不是设备 backend、mixer、voice manager、DSP 或空间音频系统；依赖 SDL3 后会拉入 SDL 复杂度 |
| Native WASAPI/CoreAudio/AAudio | P2 | 必须启动 | 低延迟、设备枚举、热插拔、自恢复、平台策略最终必须可控 | 每个平台的线程、错误恢复、格式协商和权限模型不同 |
| PipeWire/ALSA native | P3 | Linux 主线风险项 | PipeWire 已是图式多媒体框架并通过 ALSA/JACK/PulseAudio 生态互通 | session manager、格式协商、server availability、fallback 到 ALSA 的策略要单独设计 |

### Codec and decoder candidates

| Codec/库 | 推荐阶段 | 用途 | Streaming | Seek | License/build | 结论 |
|---|---|---|---|---|---|---|
| PCM/WAV via dr_wav | P0 | source import、runtime preload、offline WAV fallback | 不需要 | 简单，按帧直接定位 | public domain/MIT-0；单文件 | P0 必选 |
| WAV IMA/MS ADPCM via dr_wav | P0/P1 | 短 SFX、foley、ambience 子集 | 可做 chunk decode，但先 preload/小块预取 | block 边界 seek，需要 Bank seek table | public domain/MIT-0；单文件 | P0 可支持明确子集，P1 扩展 |
| FLAC via dr_flac | P1 import | lossless source/import、非 runtime Bank | 可分块 decode | 有 `seek_to_pcm_frame`，seek table 可用 | public domain/MIT-0；单文件 | import 推荐，runtime 不优先 |
| MP3 via dr_mp3 | P1 import | 外部素材兼容输入 | 可分块 decode | 可绑定 seek table，但 MP3 sample-exact 成本高 | public domain/MIT-0；单文件 | import 可选，Bank runtime 不推荐 |
| Vorbis via stb_vorbis | P1 | music/ambience streaming 的低成本候选 | 支持 push/pull，适合 worker decode | 有 seek API，但限制和内存模型要测 | public domain；单文件 | P1 runtime 候选 |
| libvorbis | P1/P2 | 生产级 Vorbis encode/decode | 支持 | 成熟 | BSD；需 libogg，多 submodule/build | 比 stb_vorbis 更重，适合 asset tool 或 P2 runtime |
| Opus/libopus + opusfile | P1.5/P2 | dialogue、streaming music、低码率长音频 | 适合 streaming | 需要容器/预跳过/seek 验证 | BSD-3 + patent grant；多库构建 | 不进 P0，需 spike 后进 runtime |
| SDL_sound | P1 tool/import | 多格式导入兼容层 | 可分块 decode | 取决于后端 decoder | zlib；依赖 SDL3 | 不作为 runtime 主 decoder；只做可选 adapter |

## Recommended plan

### P0

- Backend：`third_party/miniaudio`，使用 low level `ma_device` playback callback；禁用不需要的 high level engine、resource manager、node graph 使用路径。
- Mixer contract：backend callback 只调用 Bugu mixer render。若 miniaudio callback frame count 与 Bugu fixed quantum 不一致，用预分配 FIFO 适配。
- Codec：`third_party/dr_libs` 中 `dr_wav`。支持 PCM16、PCM float32 WAV；可选支持 IMA ADPCM/MS ADPCM，但必须在 manifest/Bank 中标注 block alignment、decode block size、seek granularity。
- Runtime asset policy：短音效 preload；streaming 先只允许明确的 WAV/PCM chunk 测试，不宣称 compressed streaming DONE。
- Offline/CI fallback：允许 miniaudio null backend 或 Bugu offline backend 真实生成 PCM/WAV；不能用空 callback 冒充成功。

### P1

- Backend：增加 SDL3 backend，但只允许 `https://github.com/in-dreaming/SDL.git` 的 `enjin/gpu/main` 分支。用途优先级：editor/tool preview、backend 对照、miniaudio 问题定位时的 fallback。
- Codec：加入 Vorbis runtime streaming 候选。先用 `stb_vorbis` 做低成本 worker decode spike；若 seek/metadata/edge cases 不足，再用 `libvorbis + libogg`。
- Import：`dr_flac` 用于 lossless source 输入；`dr_mp3` 只做外部素材导入兼容，不作为 Bank runtime 主格式。
- SDL_sound：只在 asset importer 或工具链中作为多格式 fallback adapter 评估；不进入 audio render thread。

### P2

- Backend：启动 native WASAPI、CoreAudio、AAudio。目标是设备枚举、低延迟、热插拔、自恢复、精确 latency query、平台错误恢复。
- Linux：PipeWire 优先，ALSA 作为更低层 fallback；需要单独处理 session manager、server unavailable、格式协商。
- Codec：Opus/libopus + opusfile 可进入 runtime streaming 前，必须完成 latency、seek、loop、pre-skip、Bank seek table 和 build matrix 验证。

## Answers to T001 questions

1. P0 miniaudio 是否仍最优：是。官方文档明确 low level API 直接暴露设备 callback，支持 playback/capture/device enumeration，且支持 WASAPI/CoreAudio/ALSA/PulseAudio/AAudio/WebAudio/Custom/Null 等 backend。P0 只取 device layer，不取 miniaudio high level engine。
2. SDL3 Audio 定位：P1 comparison/editor/fallback backend。它的 AudioStream 模型适合转换、缓冲、工具预览和默认设备迁移，但 Bugu mixer/Bank/voice 仍自研。实现依赖只能用 in-dreaming fork，不能用 upstream SDL 作为 fallback。
3. SDL_sound 定位：asset pipeline 可选，runtime decoder 暂不推荐为主路径。它能读取多种格式并输出 waveform，但不是完整音频系统。若引入，必须隔离在 worker/tool adapter。
4. P0/P1 最小 codec 集合：P0 = PCM/WAV + 明确子集 ADPCM；P1 = P0 + Vorbis streaming；P1.5/P2 = Opus；FLAC/MP3 import-only。
5. Streaming vs preload：短 UI/weapon/feedback 用 PCM/ADPCM preload；music/ambience/dialogue 用 Vorbis/Opus streaming；FLAC/MP3 先作为 import source；HRTF/IR 用 float/half/quantized FIR 常驻或按场景加载。
6. 差异：PCM license/build 最简单但体积最大；ADPCM CPU 低、seek 粗；Vorbis 压缩率好、seek 需验证；Opus 低延迟/低码率强但容器和 build 更复杂；FLAC lossless 大且 decode CPU 高于 PCM；MP3 兼容输入好但不适合作为可控 Bank runtime 格式。
7. native backend 何时启动：当 T004/T005 能稳定跑 mixer 后，P2 需要开始。miniaudio 不能长期替代 native，因为设备恢复、平台低延迟、session/permission、exclusive/shared mode、精确 latency query 和 console 平台能力都要由 Bugu 控制。
8. submodule/build：见下表。所有依赖 pin tag/commit，`build.zig` 显式集成，不允许包管理器隐式下载。
9. SDL fork 风险：已核验 `enjin/gpu/main` 存在，当前 head 为 `6180b71d7c7ff25f232e9ca2f386cec37c507da0`。风险是 fork 与 upstream SDL Audio 文档/API 的差异、更新滞后、Zig binding 维护成本。缓解：T004 只依赖任务内列出的 SDL3 Audio 子集，并在 PR 中记录 fork commit；不能在 fork 不可用时退回 upstream SDL。

## Submodule and build.zig strategy

| 依赖 | URL | 推荐 pin | 路径 | build.zig 入口 |
|---|---|---|---|---|
| miniaudio | `https://github.com/mackron/miniaudio.git` | tag `0.11.25`, commit `9634bedb5b5a2ca38c1ee7108a9358a4e233f14d` | `third_party/miniaudio` | 添加 include path；编译一个 Bugu-owned C shim，定义 `MINIAUDIO_IMPLEMENTATION` 和裁剪宏；Zig 只调用 low level device wrapper |
| SDL fork | `https://github.com/in-dreaming/SDL.git` | branch `enjin/gpu/main`, current `6180b71d7c7ff25f232e9ca2f386cec37c507da0` | `third_party/SDL` | P1 再接入；从 SDL build 产物链接；Zig binding 只暴露 `SDL_AudioStream`、device open/bind/resume/callback 子集 |
| SDL_sound | `https://github.com/icculus/SDL_sound.git` | tag `v3.2.0`, commit `49b3fad05c70c4f0eeb2a10055dee7a633d86cda` | `third_party/SDL_sound` | 仅工具/import target；链接 SDL fork；不链接到 core runtime hot path |
| dr_libs | `https://github.com/mackron/dr_libs.git` | pin repo commit after selecting required tags: `wav-0.14.5`, `flac-0.13.3`, `mp3-0.7.3` were latest tagged refs seen | `third_party/dr_libs` | 添加 include path；每个 decoder 一个 C shim，定义 `DR_WAV_IMPLEMENTATION` 等；禁用 stdio 时接 Bugu VFS callbacks |
| stb | `https://github.com/nothings/stb.git` | branch `master`, current `31c1ad37456438565541f4919958214b6e762fb4` until a project pin is chosen | `third_party/stb` | P1 Vorbis spike；C shim 定义 `STB_VORBIS_NO_STDIO`/自定义 allocator；仅 worker decode |
| libvorbis | `https://github.com/xiph/vorbis.git` | tag `v1.3.7`, commit `0657aee69dec8508a0011f47f3b69d7538e9d262` | `third_party/vorbis` | P1/P2 heavier path；also require libogg submodule; prefer asset compiler unless runtime tests justify |
| libogg | `https://github.com/xiph/ogg.git` | tag `v1.3.6`, commit `be05b13e98b048f0b5a0f5fa8ce514d56db5f822` | `third_party/ogg` | Required by libvorbis and opusfile Ogg container paths; not needed for P0 |
| opus | `https://github.com/xiph/opus.git` | tag `v1.6.1`, annotated object `22244de5a79bd1d6d623c32e72bf1954b56235be` / peeled commit `a8b13e40d751c7b40833b94fc9437c5c3439da89` | `third_party/opus` | P1.5/P2 spike; static lib target; worker decode only |
| opusfile | `https://github.com/xiph/opusfile.git` | tag `v0.12`, commit `a55c164e9891a9326188b7d4d216ec9a88373739` | `third_party/opusfile` | Only if Opus-in-Ogg runtime streaming is accepted; requires libogg |

Submodule command pattern:

```powershell
git submodule add --name third_party/miniaudio https://github.com/mackron/miniaudio.git third_party/miniaudio
git -C third_party/miniaudio checkout 0.11.25
git submodule update --init --recursive
```

CI must run `git submodule sync --recursive` and `git submodule update --init --recursive --depth 1` only when all pinned commits are reachable with shallow clone; otherwise omit `--depth`.

## Fallback policy

| Failure | Allowed fallback | DONE limitation |
|---|---|---|
| miniaudio device open fails in CI/no device | Bugu offline backend or miniaudio null backend that generates real PCM/WAV | T004 physical-device acceptance is not DONE without a real device run |
| miniaudio unavailable | SDL3 backend from in-dreaming fork, once P1 exists | Before P1 SDL backend exists, do not mark backend implementation DONE |
| SDL fork unavailable | Stay on miniaudio/native; mark SDL-specific work BLOCKED | Upstream SDL is not an allowed fallback |
| compressed codec not integrated | PCM/WAV-only manifest and Bank subset | T006 cannot claim compressed streaming, Vorbis, Opus, or sample-accurate seek DONE |
| SDL_sound missing | Direct dr_libs/stb/libvorbis/libopus import path | No loss of core acceptance; SDL_sound is optional |
| Opus build/seek risk | Vorbis streaming or PCM/ADPCM Bank variant | Opus-specific runtime acceptance remains TODO/REVIEW |

不推荐项不能作为 fallback：

- SDL_sound 不能 fallback 成底层 audio backend，因为它没有设备 callback、device recovery、mixer、bus、voice 和 DSP 管理职责。
- upstream SDL 不能 fallback 成 SDL backend，因为项目硬约束指定 in-dreaming fork/branch。
- miniaudio high level engine 不能 fallback 成 Bugu runtime core，因为会绕过自研 mixer/voice/bus 的验收目标。
- 外部播放器、系统命令或 mock PCM 不能 fallback 成 audio pipeline 验证。

## Rejected alternatives

| 备选项 | 拒绝原因 | 是否可作为 fallback |
|---|---|---|
| SDL_sound 作为“底层音频方案” | SDL_sound 是 sound file decoder，不负责设备、mixer、voice、bus、DSP、空间音频或实时策略 | 否 |
| upstream SDL3 替代 in-dreaming SDL fork | 违反项目硬约束；fork 可能包含与 gpu/RHI 集成相关差异 | 否 |
| miniaudio engine/node graph/resource manager 作为 Bugu runtime core | 会绕过自研 mixer、voice manager、bus graph 和 event runtime 的验收目标 | 否 |
| P0 直接上 Opus/Vorbis 压缩 Bank | streaming、seek、loop、worker buffer、build matrix 风险会阻塞 T004/T006 基线 | 否；P0 fallback 只能是明确的 PCM/WAV/ADPCM 子集 |
| MP3 作为 runtime Bank 主格式 | sample-exact seek/loop、编码控制和游戏音频资产管线可控性弱于 Vorbis/Opus/ADPCM | 否；只建议 import |
| FLAC 作为 runtime streaming 主格式 | lossless 体积和 decode 成本不适合多数游戏 runtime Bank；更适合作为 source/import | 否；可转码到验收过的 runtime codec |

## Risks and mitigations

| 风险 | 影响 | 缓解 |
|---|---|---|
| miniaudio callback 内误用 decoder/high level engine | 破坏实时安全，掩盖 Bugu mixer 缺口 | T004 API 只暴露 device callback adapter；decoder 在 worker/T006 |
| SDL fork 与 upstream docs 不一致 | SDL backend 编译或行为偏差 | SDL backend PR 记录 fork commit、API subset、编译命令；不依赖未核验 SDL APIs |
| ADPCM seek 粗糙 | loop/seek 不准 | Bank 记录 block alignment 和 seek table；P0 只承诺 block 边界或 preload |
| Vorbis/Opus streaming underrun | 音乐/对白断裂 | worker decode + ring buffer 水位 telemetry；T012 收集 underrun |
| 多 codec 过早进入 runtime | T006 范围失控 | P0 强制 PCM/WAV；compressed codec 通过独立 spike 升级 |
| GPL/LGPL transitive code accidental inclusion | license 风险 | SDL_sound 只按 zlib 版本接入；避免 mpg123/MikMod 等可选 LGPL/GPL path 进入 runtime，或在 build 中显式关闭 |

## Impact on later tasks

### T003 Zig API / optional C ABI

- Device backend API 要抽象为 callback/pull model、sample rate、format、channels、period frames、latency query、reopen/error callback。
- Decoder API 不属于 device backend API；应放入 L3 asset/decode module。
- C ABI 只导出 Bugu-owned handles，不直接暴露 `ma_device`、`SDL_AudioStream`、`drwav` 等第三方结构。

### T004 P0 backend

- 实现 miniaudio device adapter，不接 miniaudio engine。
- callback frame count 可变时，用 fixed quantum adapter/FIFO。
- Evidence 必须记录真实设备或 offline/null backend 真实 PCM 输出；空 callback 不合格。
- SDL3 backend 不是 T004 P0 必需项；若做 SDL，只能用 in-dreaming fork。

### T006 Asset decode / Bank MVP

- MVP Bank 支持 PCM/WAV metadata、duration、sample rate、channels、format、loop points、preload frames。
- ADPCM 若进入 P0，Bank 必须记录 codec id、block size、samples per block、seek granularity。
- compressed streaming 不能在 P0 伪装完成；Vorbis/Opus 需要独立 seek table、prefetch chunk、decoder worker evidence。
- Importer 可以接受 FLAC/MP3 source，但输出 runtime Bank 先转 PCM/ADPCM/Vorbis/Opus 中被验收的格式。

## Source links and applicability

| Source | Link | Accessed | Applicable version/branch | Used for |
|---|---|---|---|---|
| miniaudio manual | https://miniaud.io/docs/manual/index.html | 2026-07-08 | docs current; tag checked separately `0.11.25` | low level API, callback, backend list, build/cut macros |
| miniaudio license | https://raw.githubusercontent.com/mackron/miniaudio/0.11.25/LICENSE | 2026-07-08 | `0.11.25` | public domain/MIT-0 choice |
| SDL3 Audio wiki | https://wiki.libsdl.org/SDL3/CategoryAudio | 2026-07-08 | SDL3 docs current | AudioStream, device callback, PCM/conversion model |
| SDL license | https://raw.githubusercontent.com/libsdl-org/SDL/main/LICENSE.txt | 2026-07-08 | upstream license; fork expected same unless changed | zlib license terms |
| in-dreaming SDL branch | https://github.com/in-dreaming/SDL.git | 2026-07-08 | `enjin/gpu/main` head `6180b71d7c7ff25f232e9ca2f386cec37c507da0` | required SDL fork/branch pin |
| SDL_sound project | https://www.icculus.org/SDL_sound/ | 2026-07-08 | project page, 2026-06-08 release note | decoder boundary, supported formats, zlib license |
| SDL_sound 3.2.0 release | https://github.com/icculus/SDL_sound/releases/tag/v3.2.0 | 2026-07-08 | tag `v3.2.0`, commit `49b3fad05c70c4f0eeb2a10055dee7a633d86cda` | SDL3 relation and release status |
| dr_wav | https://raw.githubusercontent.com/mackron/dr_libs/master/dr_wav.h | 2026-07-08 | latest source says `v0.14.6`; latest tag seen `wav-0.14.5` | WAV/ADPCM support, single-file integration |
| dr_flac | https://raw.githubusercontent.com/mackron/dr_libs/master/dr_flac.h | 2026-07-08 | latest source says `v0.13.4`; latest tag seen `flac-0.13.3` | FLAC decode, seek, buffer notes |
| dr_mp3 | https://raw.githubusercontent.com/mackron/dr_libs/master/dr_mp3.h | 2026-07-08 | latest source says `v0.7.4`; latest tag seen `mp3-0.7.3` | MP3 import compatibility |
| stb_vorbis | https://raw.githubusercontent.com/nothings/stb/master/stb_vorbis.c | 2026-07-08 | branch `master` head `31c1ad37456438565541f4919958214b6e762fb4` | Vorbis single-file candidate, limits, memory/seek |
| Xiph Vorbis | https://xiph.org/vorbis/ | 2026-07-08 | libvorbis `v1.3.7` | format/license and libvorbis reference implementation |
| Xiph Ogg | https://github.com/xiph/ogg | 2026-07-08 | libogg `v1.3.6` | Ogg container dependency for libvorbis/opusfile paths |
| Opus overview | https://opus-codec.org/ | 2026-07-08 | libopus `1.6.1` news | streaming/storage suitability, bitrate/frame size |
| Opus license | https://www.opus-codec.org/license/ | 2026-07-08 | current | BSD implementation and royalty-free patent grant |
| WASAPI | https://learn.microsoft.com/en-us/windows/win32/coreaudio/wasapi | 2026-07-08 | Microsoft docs updated 2025-07-26 | Windows native backend scope and recovery concerns |
| Core Audio overview | https://developer.apple.com/library/archive/documentation/MusicAudio/Conceptual/CoreAudioOverview/WhatisCoreAudio/WhatisCoreAudio.html | 2026-07-08 | Apple archive updated 2017-10-30 | HAL, low latency, native PCM/format conversion |
| AAudio | https://developer.android.com/ndk/guides/audio/aaudio/aaudio | 2026-07-08 | Android docs updated 2026-03-06 | low latency callback, no file I/O/decoder, performance mode |
| PipeWire overview | https://docs.pipewire.org/page_overview.html | 2026-07-08 | PipeWire 1.6.7 docs | graph model, ALSA/JACK/PulseAudio interop |

## Verification commands

Executed from `E:\ws\infra\bugu`:

```powershell
git ls-remote --heads https://github.com/in-dreaming/SDL.git enjin/gpu/main
git ls-remote --tags --sort=-v:refname https://github.com/mackron/miniaudio.git | Select-Object -First 10
git ls-remote --tags --sort=-v:refname https://github.com/mackron/dr_libs.git | Select-Object -First 10
git ls-remote --tags --sort=-v:refname https://github.com/icculus/SDL_sound.git | Select-Object -First 10
git ls-remote --tags --sort=-v:refname https://github.com/xiph/opus.git | Select-Object -First 10
git ls-remote --tags --sort=-v:refname https://github.com/xiph/vorbis.git | Select-Object -First 10
git ls-remote --tags --sort=-v:refname https://github.com/xiph/ogg.git | Select-Object -First 5
git ls-remote --heads https://github.com/nothings/stb.git master
```

Key observed refs are recorded in the source and submodule tables above.
