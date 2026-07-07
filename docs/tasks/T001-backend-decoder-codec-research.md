# T001 后端、decoder、codec 选型补充调研

状态：DONE  
类型：Research  
优先级：P0  
依赖：无  
预计产物：docs/research/audio-backend-decoder-codec.md，必要时补充 ADR 草案。

## 1. 背景

当前设计已决定：SDL_sound 不作为底层后端，只能作为 decoder adapter 候选；P0 暂推荐 miniaudio backend；P1 可引入 SDL3 Audio 作为对照；长期做 native backend。补充硬约束：Bugu 必须用 Zig 实现，三方库必须用 git submodule 引入；如果使用 SDL，必须使用 in-dreaming/SDL.git 的 enjin/gpu/main 分支。这个任务要把结论做成可执行的选型依据，而不是口头判断。

## 2. 必读

- docs/tasks/asetup.md
- docs/tasks/tasks.md
- docs/design/audio-engine-design.md 的第 0、1、4、7、17、19 节

## 3. 调研范围

必须覆盖：

- miniaudio：device backend、callback、decoder、custom backend、license、可裁剪性、Zig build.zig/submodule 集成方式。
- SDL3 Audio：只调研 in-dreaming/SDL.git enjin/gpu/main 分支；覆盖 AudioStream、device callback、格式转换、延迟控制、license、Zig 绑定方式。
- SDL_sound：支持格式、当前维护状态、SDL3 关系、能否独立作为 decoder。
- dr_wav、dr_flac、dr_mp3、stb_vorbis、libvorbis、Opus/libopus、ADPCM 方案。
- 平台 native backend：WASAPI、CoreAudio、AAudio、PipeWire/ALSA 的 P2 风险点。
- git submodule 引入策略：路径、版本锁定、分支跟踪、update 命令、CI/本地构建影响。

## 4. 必须回答的问题

1. P0 选择 miniaudio 是否仍是最优？如果不是，给出证据。
2. SDL3 Audio 应作为 runtime backend、editor backend、fallback，还是不引入？
3. SDL_sound 在资产管线和运行时 decoder 中分别是否值得引入？
4. P0/P1 最小 codec 集合是什么？
5. 哪些 codec 适合 streaming，哪些适合 preload？
6. license、构建复杂度、seek 能力、延迟、内存占用有什么差异？
7. native backend 什么时候必须启动，不能被 miniaudio 长期替代的原因是什么？
8. 每个三方库作为 submodule 的推荐路径和 build.zig 集成方式是什么？
9. 如果选择 SDL，in-dreaming/SDL.git enjin/gpu/main 与 upstream SDL 的关键差异或潜在风险是什么？

## 5. 输出要求

输出 docs/research/audio-backend-decoder-codec.md，必须包含：

- Executive summary。
- 对比表。
- 推荐方案。
- rejected alternatives。
- 风险与缓解。
- 对 T003、T004、T006 的影响。
- 来源链接，优先官方文档或代码仓库。
- 每个来源的访问日期和适用版本、分支、commit 或 release。
- 明确 fallback 决策：首选失败时允许用什么替代，替代后哪些验收不能算 DONE。

## 6. 验收标准

- 每个核心库至少有一个权威来源链接。
- 明确 P0、P1、P2 的后端与 codec 方案。
- 没有把 SDL_sound 描述为完整底层音频系统。
- 明确哪些结论会影响 Zig API、可选 C ABI 或 Bank 格式。
- 明确每个推荐三方依赖的 submodule URL、branch/tag/commit 策略和本地构建入口。
- 明确不推荐项为什么不能作为 fallback。
- docs/tasks/tasks.md 状态更新为 REVIEW 或 DONE。

## 7. 不得越界

- 不实现代码。
- 不引入依赖到仓库。
- 不修改核心设计结论，除非同时新增 ADR 草案并标记需要 review。

## 8. Deliverables

- [docs/research/audio-backend-decoder-codec.md](../research/audio-backend-decoder-codec.md)：完成后端、decoder、codec 选型补充调研。
- ADR 结论：不需要新增 ADR；现有 ADR-002、ADR-003 方向保持成立，本文仅补充可执行选型依据。

## 9. Evidence

- 覆盖范围：miniaudio、SDL3 Audio（in-dreaming fork/branch）、SDL_sound、dr_wav、dr_flac、dr_mp3、stb_vorbis、libvorbis、Opus/libopus、ADPCM、WASAPI、CoreAudio、AAudio、PipeWire/ALSA、submodule 策略。
- 权威来源：research 文档 `Source links and applicability` 表列出官方文档、官方代码仓库、访问日期、适用版本/branch/commit。
- 关键结论：P0 miniaudio device backend + PCM/WAV/ADPCM 子集；P1 SDL3 对照/editor/fallback backend + Vorbis streaming；P2 native WASAPI/CoreAudio/AAudio 与 Opus 验证。
- 边界确认：SDL_sound 明确只作为可选 decoder/import adapter，不作为底层音频系统。
- 后续影响：research 文档明确列出对 T003、T004、T006 的 API、backend 和 Bank 格式影响。
- 验证命令：research 文档 `Verification commands` 记录 `git ls-remote` 核验的分支/tag/commit。

## 10. Activity Log

- 2026-07-07：任务创建。
- 2026-07-08：开始 T001，阅读任务总览、T001 任务文件和 audio-engine-design 相关章节，准备补充官方来源核验与 research 产物。
- 2026-07-08：完成官方/权威来源核验，新增 research 产物，更新 T001 Deliverables/Evidence，并将状态标记为 DONE。
