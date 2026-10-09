# TASK-020：交付完整 SME 示例项目与真实运行 demo

## 元数据
- 状态：TODO
- Owner：`UNASSIGNED`
- Reviewer：`UNASSIGNED`
- 实施角色：Example/Integration
- 评审角色：QA、资产许可、Runtime
- 工作量等级：`L`
- 证据路径：`docs/validation/sme/TASK-020/evidence.md`（脱敏摘要）、`zig-out/sme-validation/TASK-020/`（原始产物）
- 执行波次：14
- 硬依赖：TASK-015、TASK-016、TASK-017、TASK-018、TASK-019
- 协作关系：TASK-021以本任务为E2E fixture；本任务拥有`examples/sme/`
- 预计改动范围：`examples/sme/`（新增）、`build_support/sme_steps.zig`、`zig-out/sme-validation/TASK-020/demo-report.json`

## 目标
用一个可审查的author project和真实音频数据演示完整v1：变tempo/拍号、selectors、cue/fill、multistem、streaming、stinger、sidechain、acoustic mapping、save/restore、reload/rollback。

## 上下文
单元fixtures不能替代产品链演示。示例艺术质量不作为验收，但音频必须是真实PCM/Opus资产并由Bugu runtime播放，不得使用外部播放器或固定trace。

## 前置条件
- CLI/GUI/runtime debugger全部可用。
- hot reload、stinger/duck/acoustic功能通过。

## 实施范围
### 必须完成
- 可 diff TOML author project 和可再生/授权明确的 multi-stem source；`examples/sme/LICENSES/assets.toml` 逐资产记录 logical ID、source/生成命令、license、copyright、SHA-256、bytes 和 package inclusion。
- explore/tension/combat/dialogue states。
- tempo ramp、meter change、entry/exit、multi-fill、weighted/no-repeat。
- 4+同步layers、variant、virtualize/realize。
- Ogg Opus streaming/seek/loop。
- dialogue PCM触发真实sidechain、stinger和acoustic parameter。
- `examples/sme/scripts/schema-v1.json` 定义的 scripted request trace、save/restore、hot reload/rollback；每条 action 显式 frame/musical boundary、request ID、expected receipt/result，不接受自由文本判据。
- 在 TASK-020 evidence 冻结 source/package 资产总 bytes、单文件上限和 package inclusion budget；超限使 demo gate 失败并由 TASK-023 继承。
- device与offline运行模式、report。

### 明确不包含
- 将demo数据硬编码到runtime。
- 用测试tone代替全部音乐；可生成fixture，但必须有可听区分的多stem结构与许可证说明。

## 设计与执行细节
1. project必须由CLI重新build得到相同bank hash。
2. demo只用公共API。
3. scripted mode固定seed并可无人值守。
4. interactive mode可改变state/intensity/dialogue/acoustic/ reload。
5. 输出 WAV、trace、report 到 `zig-out/sme-validation/TASK-020/`，校验非静音、peak/RMS、clipping、expected receipts 和 artifact hashes；report 不包含绝对路径或源 stem 文件名。

## 接口与数据契约
新增`zig build sme-demo -- --offline|--device --script <path> --report <path>`。退出码反映runtime/validation失败。

## 文件变更
- 新增 example project/assets/scripts/demo、`LICENSES/assets.toml` 与 `scripts/schema-v1.json`。
- build step 和 raw validation artifacts；仓库只提交脱敏 evidence/hash。

## 验证
### 自动化验证
- CLI rebuild bank hash一致。
- `zig build sme-demo -- --offline ...`执行全脚本，assert全部planned/executed frames和0 skew/underrun/dropout。
### 手工验证
- device模式听取transition/fill/layer/sidechain并使用runtime debugger观察。
### 边界与失败场景
- missing asset、corrupt bank、device absent、reload invalid、stream pressure。

## 完成定义
- [ ] 完整能力在单一真实项目中贯通。
- [ ] demo只用公共API和compiled bank。
- [ ] offline可重复、device可听。
- [ ] 每个 asset 的来源/生成方式、license、hash、bytes 和 package inclusion 可审计。
- [ ] Script schema 与 demo report schema 已版本化，资产体积预算已冻结。

## 活动日志

- 2026-07-28：根据评审报告完成规格收口；状态保持 `TODO`，未开始代码实施。

## 风险与注意事项
demo通过不能代替TASK-021/022的全量矩阵。


## 生产路径与验证演示补充
Demo必须沿ControlRuntime→RenderSnapshot+ScheduledCommandBlock→RuntimeRenderer→RuntimeMiniaudioBackend，offline用RuntimeOfflineBackend；不能用Engine-only或外部播放器冒充。演示SFX+音乐并行、multichannel匹配输出（不支持设备明确拒绝/显式矩阵转换）、记录完整ReplayInputV2并复放相同schedule；设备loss使旧epoch FIFO flush且不重放已生成PCM。继承026早期slice而不是复制第二套runtime。
