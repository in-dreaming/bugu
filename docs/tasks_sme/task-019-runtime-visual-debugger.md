# TASK-019：实现 in-dreaming/gpu SME runtime 可视调试器

## 元数据
- 状态：待实施
- 执行波次：9
- 硬依赖：TASK-015、TASK-018
- 协作关系：读取TASK-004 trace和runtime snapshots；不得修改authoring project语义
- 预计改动范围：`tools/sme_debug/`（新增）、`build.zig`、`docs/validation/sme/runtime-debug-smoke.json`

## 目标
交付连接运行中MusicRuntime或replay trace的调试器，显示transport、state/candidates、transition phases、layers、Bus/sidechain、stream和generation。

## 上下文
作者应用面向资产编辑；runtime debugger面向运行诊断，职责分开。两者可复用GPU adapter和只读widget，但debugger不能编辑或隐式修复bank。

## 前置条件
- authoring UI基础/GPU路径通过。
- stinger/duck/acoustic trace字段存在。

## 实施范围
### 必须完成
- live snapshot/trace接入与offline replay打开。
- tempo/meter/cue transport、committed/pending state。
- candidate rejection、selector history、source/fill/target phases。
- group/layer real/virtual/drop、gain/filter/send。
- bus meters、detector envelope、gain reduction。
- stream watermarks/prefetch/decode/underrun。
- generation/hot reload/rollback timeline。
- automated replay smoke。

### 明确不包含
- 修改runtime状态的cheat controls。
- authoring编辑。

## 设计与执行细节
1. 只消费versioned snapshot/trace，不能读内部mutable pointers。
2. UI采样慢不得反压audio/control。
3. dropped records/trace overflow明显显示。
4. replay与live采用同一view model。
5. headless trace仍是correctness source。

## 接口与数据契约
新增`SmeDebugSnapshot`只读copy和build steps `sme-debug-build/smoke`。连接失败/版本不兼容必须明确。

## 文件变更
- 新增debug tool/build/smoke artifact。

## 验证
### 自动化验证
- `zig build sme-debug-smoke`加载TASK-020前置最小fixture/replay（若TASK-020尚未完成，使用TASK-017测试fixture）。
- snapshot version、overflow、disconnect、replay EOF。
### 手工验证
- live运行中触发state/fill/stinger/duck/reload，观察对应panel。
### 边界与失败场景
- runtime关闭、trace版本旧、GPU设备丢失、UI帧率低。

## 完成定义
- [ ] 必需视图均由真实trace/snapshot驱动。
- [ ] 工具不影响audio timing。
- [ ] live/replay结果一致。
- [ ] 使用in-dreaming/gpu。

## 风险与注意事项
不要为可视效果向runtime增加非实时安全查询。
