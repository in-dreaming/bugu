# TASK-020：交付完整 SME 示例项目与真实运行 demo

## 元数据
- 状态：待实施
- 执行波次：10
- 硬依赖：TASK-015、TASK-016、TASK-017、TASK-018、TASK-019
- 协作关系：TASK-021以本任务为E2E fixture；本任务拥有`examples/sme/`
- 预计改动范围：`examples/sme/`（新增）、`build.zig`、`docs/validation/sme/demo-report.json`

## 目标
用一个可审查的author project和真实音频数据演示完整v1：变tempo/拍号、selectors、cue/fill、multistem、streaming、stinger、sidechain、acoustic mapping、save/restore、reload/rollback。

## 上下文
单元fixtures不能替代产品链演示。示例艺术质量不作为验收，但音频必须是真实PCM/Opus资产并由Bugu runtime播放，不得使用外部播放器或固定trace。

## 前置条件
- CLI/GUI/runtime debugger全部可用。
- hot reload、stinger/duck/acoustic功能通过。

## 实施范围
### 必须完成
- 可diff TOML author project和可再生/授权明确的multi-stem source。
- explore/tension/combat/dialogue states。
- tempo ramp、meter change、entry/exit、multi-fill、weighted/no-repeat。
- 4+同步layers、variant、virtualize/realize。
- Ogg Opus streaming/seek/loop。
- dialogue PCM触发真实sidechain、stinger和acoustic parameter。
- scripted request trace、save/restore、hot reload/rollback。
- device与offline运行模式、report。

### 明确不包含
- 将demo数据硬编码到runtime。
- 用测试tone代替全部音乐；可生成fixture，但必须有可听区分的多stem结构与许可证说明。

## 设计与执行细节
1. project必须由CLI重新build得到相同bank hash。
2. demo只用公共API。
3. scripted mode固定seed并可无人值守。
4. interactive mode可改变state/intensity/dialogue/acoustic/ reload。
5. 输出WAV、trace、report并校验非静音/无clipping。

## 接口与数据契约
新增`zig build sme-demo -- --offline|--device --script <path> --report <path>`。退出码反映runtime/validation失败。

## 文件变更
- 新增example project/assets/scripts/demo。
- build step和validation artifact。

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
- [ ] assets来源/生成方式明确。

## 风险与注意事项
demo通过不能代替TASK-021/022的全量矩阵。
