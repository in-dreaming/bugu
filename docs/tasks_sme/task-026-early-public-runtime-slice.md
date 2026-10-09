# TASK-026：验证早期真实音乐与 SFX 公共路径

## 元数据
- 状态：TODO
- Owner：`UNASSIGNED`
- Reviewer：`UNASSIGNED`
- 实施角色：Runtime integration / QA
- 评审角色：独立 runtime/UI 架构与 QA
- 工作量等级：`L`
- 证据路径：`docs/validation/sme/TASK-026/evidence.md`（脱敏摘要）、`zig-out/sme-validation/TASK-026/`（原始产物）
- 执行波次：7
- 硬依赖：TASK-005、TASK-007、TASK-008、TASK-009
- 协作关系：遵守 setup.md 的模块所有权；子交付物分别审查后才允许 epic DONE
- 预计改动范围：见文件变更

## 目标
在完整MusicRuntime集成前，以已实现组件证明 public production backend 真正执行 next-bar 两stem切换并与SFX共存。

## 上下文
本任务是内部垂直切片，不是MVP产品或任何v1范围变更。全功能014仍必须覆盖streaming、多fill、lifecycle、save/restore等全部要求。不能手写plan/PCM或直接操作Mixer冒充public API。

## 前置条件
005多声道group和public runtime seam；007真实tempo grid；008真实Director/selector；009真实TransitionPlanner；003/010正常compiler生成的compiled resident bank；002/004已交付scheduler/receipt/replay。

## 实施范围
### 必须完成
- 026-A fixture：真实短WAV经010真实media pass与003 builder生成resident bank，两个state、两个同步stem、明确tempo/bar，加入实际SFX sample；确定性生成测试音可以，但不能按scenario硬编码输出。
- 026-B integration：从public music submission进入ControlRuntime/Director/scheduler→RuntimeRenderer→RuntimeOfflineBackend输出PCM和真实receipts；第一次开始与next-bar切换都精确frame，stem skew0。
- 026-C regression：通过已有ControlRuntime.submitPlay在同一mixer播放SFX；完整legacy EventRuntime adapter由014实现，本任务不依赖它，验证两个来源同clock、共同voice budget、music pause不停止SFX、关闭引用归零。
- 026-D CI：Windows/Linux canonical schedule一致，callback sizes1/127/256/300/513等价；存小型golden/hash，raw WAV遵守setup隐私和产物规则。

### 明确不包含
不重新实现Director/planner；使用009同一真实planner的resident、无fill、next-bar fixture，所有TransitionPlan均由production planner生成，不手工构造或由测试glue算frame。014接入后扩展更多lifecycle用例，不能把早期fixture限制写成release范围。

## 设计与执行细节
公共runtime扩展仅开放已实现的resident受限入口并显式capability标记；其内部由001冻结的seam实现，014扩展同一入口。production接线在src/music/api.zig及既有runtime seam，调用009真实planner；tests/examples仅提交公共请求与验证输出，不含plan构建/调度算法，避免第二runtime。编译资产经正常loader，receipt来自真实render；真PCM验证峰值/RMS、非静音和脉冲起点，不只构造对象。

## 接口与数据契约
输入：compiled bank hash、seed、ReplayInputV2、ControlRuntime SFX requests；输出：PCM、canonical schedule、group/phase receipts、唯一runtime owner与最终lease计数。unsupported功能在受限fixture明确拒绝，不返回空success。

## 文件变更
- 新增 `tests/sme/early_public_runtime_test.zig`、`examples/sme/early_runtime_slice.zig`。
- `src/music/api.zig` / runtime既有seam：仅已实现能力的早期接线，014按依赖顺序继续。
- 新增TASK-026 evidence和小型golden fixtures；通过001稳定test注册加入CI。

## 验证
### 自动化验证
`zig build test`包含public backend集成；对每callback partition比较canonical schedule与PCM容差；SFX叠加与独立reference和声道脉冲一致；满queue/group reject不产生半组。
### 手工验证
可听检但不代替精确frame/PCM断言。
### 边界与失败场景
bar前/上/后请求、SFX和music同frame、pause、rapid supersede、generation stale、shutdown未消费receipt、非法bank拒绝。

## 完成定义
- [ ] public RuntimeOffline路径实际输出音乐与SFX，非legacy Engine-only。
- [ ] 两stem起点/cursor skew0且真实next-bar切换。
- [ ] replay+callback partition一致并在持续CI运行。
- [ ] fixture限制显式且完整v1无任何能力移除。

## 风险与注意事项
不把抽象/mock backend当真实路径。最终TASK-014/022仍须覆盖真实设备，offline不证明物理无glitch。

## 活动日志
- 2026-10-09：文档修订新增实施任务；状态 TODO，未实施或运行测试。
