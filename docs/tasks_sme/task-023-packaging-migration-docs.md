# TASK-023：完成 SME release packaging、legacy迁移与用户文档

## 元数据
- 状态：待实施
- 执行波次：13
- 硬依赖：TASK-017、TASK-018、TASK-019、TASK-020、TASK-021、TASK-022
- 协作关系：`src/bugu_audio.zig`和build/package surface最终所有者；TASK-024审查本产物
- 预计改动范围：`build.zig`、`src/bugu_audio.zig`、release/package配置（按实际新增）、`docs/sme/`（新增）、`README.md`

## 目标
交付可被游戏团队安装、构建、集成、制作资产、迁移legacy音乐、运行工具和排障的完整v1 package。

## 上下文
源码和tests存在不等于可交付。当前API/asset/device仍标prototype；SME必须明确支持矩阵、ownership和实际命令。

## 前置条件
- 完整validation、device/stress通过。
- CLI/GUI/debug/demo稳定。

## 实施范围
### 必须完成
- release build/package包含runtime、compiler、authoring、debugger、licenses、schemas。
- public Zig API surface收口与compile-only consumer sample。
- legacy event/music bus与WAV bank迁移指南和工具命令。
- runtime integration、ownership/threading、save/reload、error troubleshooting。
- authoring、tempo/cue/fill/layer/sidechain/streaming教程。
- platform/codec/channel/device/toolchain矩阵。
- validation/release命令与已知限制。
- README链接与版本标识。

### 明确不包含
- C ABI，除非另有已批准ADR。
- 声称未验证的平台。

## 设计与执行细节
1. package从clean checkout构建，不依赖本机cache。
2. submodule init和MSVC/GPU要求明确。
3. 文档命令必须实际执行。
4. migration不自动猜tempo/cue；无法转换项明确诊断。
5. 旧event路径继续可用，不称其为SME功能。

## 接口与数据契约
release manifest列schema/API/tool versions、submodule commits、supported targets、artifacts SHA-256。

## 文件变更
- final build/export/package。
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
- [ ] package/manifest/hash/license完整。
- [ ] 文档命令与实际surface一致。
- [ ] 支持/限制无夸大。

## 风险与注意事项
不要把内部测试fixture当作用户资产模板；模板必须最小、合法、可说明。
