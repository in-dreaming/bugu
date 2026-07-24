# TASK-017：实现 headless authoring core 与 SME compiler CLI

## 元数据
- 状态：待实施
- 执行波次：6
- 硬依赖：TASK-003、TASK-007、TASK-008、TASK-009、TASK-010、TASK-014
- 协作关系：与 TASK-015/016 并行；TASK-018 必须复用本任务 core；本任务拥有 `tools/sme_compiler/`
- 预计改动范围：`tools/sme_compiler/`、`tools/sme_authoring/core/`（新增）、`build.zig`、`tests/sme/authoring_cli_test.zig`

## 目标
交付可在无 GPU/设备的 CI 中创建、导入、校验、构建、检查和 offline preview 完整 SME project 的 Zig shared authoring core 与 CLI。

## 上下文
手写 manifest 不是完整 authoring workflow。CLI 与 GUI/runtime 必须共享 schema、tempo、logic、selector、planner和validation。

## 前置条件
- 完整 compiler/runtime libraries可 import。
- Ogg Opus build。

## 实施范围
### 必须完成
- versioned TOML project parser/writer，稳定格式化。
- stems/marker import、tempo/cue/fill/state/layer/bus/sidechain/stinger/profile author model。
- commands：`new`、`validate`、`build`、`inspect`、`preview`、`migrate`。
- build report、dependency graph、hash、budget和全部诊断。
- offline preview 使用真实 MusicRuntime，输出 WAV + trace。
- source migration只支持明确版本路径并保留备份。

### 明确不包含
- GPU GUI。
- DAW波形编辑/录音。

## 设计与执行细节
1. CLI error包含文件/字段/ID/规则，不仅 exit 1。
2. writer round-trip不丢未知 optional author metadata。
3. build严禁warning降级为 silent field ignore。
4. preview和runtime使用相同 compiled bank。
5. CLI在`build/sme_steps.zig`注册新增 `sme-compiler`/`sme-preview`。

## 接口与数据契约
TOML schema固定为 `bugu.music.source/v1`。CLI成功=exit0，validation/build failure非0并生成机器可读诊断 JSON（若路径可写）。

## 文件变更
- 新增 compiler/authoring core/tests。
- build integration。

## 验证
### 自动化验证
- `zig build test`。
- 新增 `zig build sme-compiler-test`：new->edit fixture->validate->build->inspect->preview，重复build bytes相同，invalid projects矩阵。
### 手工验证
- 用CLI生成一个最小project并检查输出。
### 边界与失败场景
- missing stem、bad TOML、duplicate ID、tempo/fill/logic/channel/budget错误、migration失败。

## 完成定义
- [ ] CLI覆盖完整v1 author data。
- [ ] preview走真实runtime并产生PCM/trace。
- [ ] headless环境不加载GPU。
- [ ] GUI可直接复用core，无第二套模型。

## 风险与注意事项
不要把 GUI 所需校验留到 TASK-018；所有语义校验必须在 shared core。

