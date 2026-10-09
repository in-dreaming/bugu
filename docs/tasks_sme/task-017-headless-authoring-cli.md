# TASK-017：实现 headless authoring core 与 SME compiler CLI

## 元数据
- 状态：TODO
- Owner：`UNASSIGNED`
- Reviewer：`UNASSIGNED`
- 实施角色：Tooling/Compiler
- 评审角色：资产管线、CLI 契约、QA
- 工作量等级：`XL`
- 证据路径：`docs/validation/sme/TASK-017/evidence.md`（脱敏摘要）、`zig-out/sme-validation/TASK-017/`（原始产物）
- 执行波次：10
- 硬依赖：TASK-003、TASK-007、TASK-008、TASK-009、TASK-010、TASK-014
- 协作关系：与 TASK-015/016 并行；TASK-018 必须复用本任务 core；本任务拥有 CLI/project orchestration，不覆盖 TASK-003/007/008/009/010/012/013 分别拥有的 compiler pass
- 预计改动范围：`tools/sme_compiler/`、`tools/sme_authoring/core/`（新增）、`build.zig`、`tests/sme/authoring_cli_test.zig`

## 目标
交付可在无 GPU/设备的 CI 中创建、导入、校验、构建、检查和 offline preview 完整 SME project 的 Zig shared authoring core 与 CLI。

## 上下文
手写 manifest 不是完整 authoring workflow。CLI 与 GUI/runtime 必须共享 schema、tempo、logic、selector、planner和validation。

## 前置条件
- 完整 compiler/runtime libraries可 import。
- TASK-010 的真实 Ogg Opus build、媒体 import/SRC/quality/storage pass、Chunk/Seek producer、各自已通过的 fixtures；不得重新实现这些算法。

## 实施范围
### 必须完成
- versioned TOML project parser/writer，稳定格式化；canonical source layout 固定为 `project.toml`、`audio/`、`markers/`、可选 `profiles/`、被忽略的 `.sme-recovery/`，所有引用使用 project-relative path。
- stems/marker import、tempo/cue/fill/state/layer/bus/sidechain/stinger/profile author model。
- commands：`new`、`import`、`validate`、`build`、`inspect`、`preview`、`migrate`；`import` 将声明的源 rate/layout、source hash 和 marker 送入 TASK-010 共享媒体管线，显式显示转换和 storage decision。
- build report、dependency graph、hash、budget和全部诊断。
- offline preview 使用真实 MusicRuntime，输出 WAV + trace。
- source migration只支持明确版本路径并保留备份。

### 明确不包含
- GPU GUI。
- DAW波形编辑/录音。

## 交付检查点

- `T017-A / ProjectRoundTrip`：输入为TASK-003 source/IR schema 与 minimal-v1 source fixture；产物为 `tools/sme_authoring/core/project.zig`（新增）、版本化 parser/writer、canonical source fixture；独立测试 new→read→write→read、unknown optional author metadata 保留、duplicate/missing/path escape 错误。
- `T017-B / CliDiagnosticsAndMigration`：输入为T017-A project reader/writer 与显式旧版本 migration fixtures；产物为 CLI argument/exit-code contract、diagnostics JSON golden、显式版本迁移与 backup manifest；独立测试每条 command 的非零错误传播、字段定位、不可写输出、rollback-safe migration。
- `T017-C / SharedMediaBuild`：输入为T017-A/B CLI/project 模型、TASK-010 已实现的媒体 passes 和全部领域 validators；产物为注册 pass 编排器、import/build/inspect、sample-rate/quality/storage/seek 报告；独立测试真实 44.1/96 kHz 多声道导入、long resident→streaming、每个质量 gate 和重复 bank bytes/hash，禁止自建第二套算法。
- `T017-D / HeadlessRuntimePreview`：输入为T017-C compiled bank、TASK-014 公共 runtime、TASK-004 replay schema 与 TASK-005 offline output；产物为真实公共 MusicRuntime preview driver、matching-layout WAV/PCM、完整 replay 输入及 execution trace；独立测试 request→Director→Planner→scheduler→PCM、preview 与加载同 bank 的 runtime 一致、无 GPU/device 动态依赖。
- 每片使用单独变更集与独立 Reviewer，记录可运行测试、commit 和产物 hash；A→B/C→D，全部通过后整体进入 `REVIEW`。路径为计划新增定位，可按 TASK-001 命名 review 微调并同步任务。

## 设计与执行细节
1. CLI error包含文件/字段/ID/规则，不仅 exit 1。
2. writer round-trip不丢未知 optional author metadata。
3. build严禁warning降级为 silent field ignore。
4. preview和runtime使用相同 compiled bank。
5. CLI 在 `build_support/sme_steps.zig` 注册新增 `sme-compiler`/`sme-preview`。
6. diagnostics JSON 固定 envelope：`schema_version`、`command`、`success`、`project_id/hash`、`diagnostics[]`、`outputs[]`；每条 diagnostic 含 code、severity、repo/project-relative file、line/column 或 object ID、field、message key 和 structured args，不写绝对路径。
7. CLI 明确呈现原始/目标 sample rate、SRC delay/remap、true peak/RMS/LUFS/DC/loop 结果、warning/error policy、decoded resident bytes/limit、forced streaming、seek entry/chunk counts 和 codec priming；`validate`/`build` 同用一个 media gate，缺报告/producer 失败不能只给 warning。
8. Tempo editor/source round-trip 保留 PPQ、quarter-note BPM 单位、canonical `beat_groups`、seconds-linear ramp、anchors 和 ties-even policy；不得在导入6/8时将120 quarter-note BPM转换为120 dotted-quarter pulse BPM。

## 接口与数据契约
TOML schema 固定为 `bugu.music.source/v1`；project layout 使用 project-relative paths。CLI 成功=exit 0；validation/build failure 非 0。`--diagnostics-json <path>` 是显式输出参数：请求该参数而路径不可写时命令必须非 0，未请求时不得在未知目录静默写文件。

## 文件变更
- 新增 compiler/authoring core/tests。
- build integration。

## 验证
### 自动化验证
- `zig build test`。
- 新增 `zig build sme-compiler-test`：new→import→edit fixture→validate→build→inspect→preview，重复 build bytes 相同，invalid projects 矩阵。
- 使用真实非48 kHz sources 和多声道/长 segment，断言 quality reports、forced-streaming descriptor、SeekTable 均为 TASK-010 产物；相同坏资产在 CLI/共享 core 的 diagnostic code、字段与 severity 相同。
### 手工验证
- 用CLI生成一个最小project并检查输出。
### 边界与失败场景
- missing stem、逃逸 project root 的相对路径、bad TOML、duplicate ID、tempo/fill/logic/channel/budget 错误、diagnostics 路径不可写、migration 失败。

## 完成定义
- [ ] 本任务已交付测试/fixture 通过 TASK-001 的稳定注册 seam 加入既有 `zig build test`/PR gate，证据随子交付持续产生，不等待 TASK-021 首次接入 CI。
- [ ] CLI覆盖完整v1 author data。
- [ ] preview走真实runtime并产生PCM/trace。
- [ ] headless环境不加载GPU。
- [ ] GUI 可直接复用 core，无第二套模型。
- [ ] Source layout 和 diagnostics JSON schema 已版本化、脱敏并有 golden tests。
- [ ] 所有媒体质量/存储/seek 结果可审计，CLI 与 GUI 能消费同一份 report，不存在 late-only compiler pass。

## 活动日志

- 2026-07-28：根据评审报告完成规格收口；状态保持 `TODO`，未开始代码实施。
- 2026-10-09：补齐实际依赖、量化/输入契约、独立审查产物与持续 gate；仅修订任务文档，状态保持 `TODO`。

## 风险与注意事项
不要把 GUI 所需校验留到 TASK-018；所有语义校验必须在 shared core。


