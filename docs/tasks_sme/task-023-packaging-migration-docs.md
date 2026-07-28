# TASK-023：完成 SME release packaging、legacy迁移与用户文档

## 元数据
- 状态：TODO
- Owner：`UNASSIGNED`
- Reviewer：`UNASSIGNED`
- 实施角色：Release/Developer Experience
- 评审角色：Package、迁移、文档、QA
- 工作量等级：`XL`
- 证据路径：`docs/validation/sme/TASK-023/evidence.md`（脱敏摘要）、`zig-out/sme-validation/TASK-023/`（原始产物）
- 执行波次：13
- 硬依赖：TASK-017、TASK-018、TASK-019、TASK-020、TASK-021、TASK-022
- 协作关系：`src/bugu_audio.zig`和build/package surface最终所有者；TASK-024审查本产物
- 预计改动范围：`build.zig`、`build.zig.zon`（若 package 尚未存在则新增）、`build_support/sme_steps.zig`、`src/bugu_audio.zig`、`tools/package_sme.ps1`（新增）、`tools/validate_sme_docs.ps1`（新增）、`docs/sme/`（新增）、`README.md`

## 目标
交付可被游戏团队安装、构建、集成、制作资产、迁移legacy音乐、运行工具和排障的完整v1 package。

## 上下文
源码和tests存在不等于可交付。当前API/asset/device仍标prototype；SME必须明确支持矩阵、ownership和实际命令。

## 前置条件
- 完整validation、device/stress通过。
- CLI/GUI/debug/demo稳定。

## 实施范围
### 必须完成
- release package 固定根布局：`build.zig`/`build.zig.zon`、`src/` runtime、`bin/` compiler/authoring/debugger、`schemas/`、`examples/`、`docs/`、`licenses/`、`manifest.json`；目录缺失或多出未清单文件均失败。
- public Zig API surface收口与compile-only consumer sample。
- legacy event/music bus与WAV bank迁移指南和工具命令。
- runtime integration、ownership/threading、save/reload、error troubleshooting。
- authoring、tempo/cue/fill/layer/sidechain/streaming教程。
- platform/codec/channel/device/toolchain矩阵。
- validation/release命令与已知限制。
- README链接与版本标识。

### 明确不包含
- C ABI，除非另有已批准 ADR。
- 声称未验证的平台。

## 交付检查点

1. Package manifest/layout、clean build 和 public consumer sample。
2. Legacy migration command、诊断与保留旧 event/WAV 行为。
3. Runtime/authoring/troubleshooting/support 文档和可执行命令校验。
4. License/schema/tool version/hash 收口与 README release surface。
5. 四个检查点独立 review；全部通过后任务才可进入 `REVIEW`。

## 设计与执行细节
1. `tools/package_sme.ps1` 从 clean checkout 构建到 `zig-out/sme-package/`，先创建 manifest allowlist，再拒绝任何未列入 manifest 的文件；不依赖本机 cache 或绝对路径。
2. submodule init和MSVC/GPU要求明确。
3. `tools/validate_sme_docs.ps1` 从文档中维护的命令清单执行 quick start、build、validate、preview、package consumer 和 troubleshooting probes；任何命令漂移使 gate 非 0。
4. migration不自动猜tempo/cue；无法转换项明确诊断。
5. 旧event路径继续可用，不称其为SME功能。

## 接口与数据契约
`manifest.json` 固定列 schema/API/tool versions、Zig minimum version、submodule commits、supported targets、package-relative path、artifact kind、bytes、SHA-256、license ID 和 executable bit；manifest 自身有 schema version，路径按 Unicode/大小写冲突规则校验。

## 文件变更
- `tools/package_sme.ps1`、`tools/validate_sme_docs.ps1` 与固定 `zig-out/sme-package/` layout。
- `docs/sme/quick-start.md`、`runtime-integration.md`、`authoring-guide.md`、`migration.md`、`troubleshooting.md`、`support-matrix.md`。
- README。

## 验证
### 自动化验证
- clean package build。
- consumer sample仅使用public imports编译运行。
- CLI/GUI/debug/demo从package运行。
- docs command script执行。
### 手工验证
- 新目录按quick start完成project build和offline preview。
### 边界与失败场景
- missing submodule、unsupported platform、旧bank、schema mismatch、无GPU/无device。

## 完成定义
- [ ] clean consumer无需源码内部路径。
- [ ] 固定 package layout 中每个文件均由 manifest 覆盖，hash/license/version 完整且无额外文件。
- [ ] 文档命令由 `tools/validate_sme_docs.ps1` 从 clean package 实际执行。
- [ ] 文档命令与实际surface一致。
- [ ] 支持/限制无夸大。

## 活动日志

- 2026-07-28：根据评审报告完成规格收口；状态保持 `TODO`，未开始代码实施。

## 风险与注意事项
不要把内部测试fixture当作用户资产模板；模板必须最小、合法、可说明。
