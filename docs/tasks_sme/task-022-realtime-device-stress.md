# TASK-022：完成实时安全审计、真实设备与 8 小时压力 gate

## 元数据
- 状态：待实施
- 执行波次：12
- 硬依赖：TASK-011、TASK-013、TASK-014、TASK-021
- 协作关系：TASK-023引用support matrix；本任务不改validation wrapper主逻辑
- 预计改动范围：`tools/sme_stress/`（新增）、`docs/validation/sme/rt-audit.md`、设备/压力报告、必要runtime修复归属原owner

## 目标
用审计和真实运行证据证明render path实时安全、Windows设备生命周期可靠，并通过至少8小时全能力压力运行。

## 上下文
build/test通过不是产品实时证据。Offline fallback不能替代真实设备gate。

## 前置条件
- headless全量validation通过。
- 有支持矩阵中的Windows设备、driver和MSVC/Zig环境。

## 实施范围
### 必须完成
- 逐函数render call graph审计：alloc/lock/I/O/log/GPU wait/lazy decode。
- stress tool：state churn、tempo/fill、stream seek、virtual churn、stinger、sidechain、reload、device reopen。
- 8小时device run和8小时offline accelerated/real-time对应run。
- p50/p95/p99/p999/max、dropout/underrun/overflow/skew/leak。
- device start/stop/lost/reopen证据。
- 内存/handle/generation稳定性。

### 明确不包含
- 以短smoke推算8小时结果。
- 以offline替代device。
- 在stress tool中绕过publicAPI。

## 设计与执行细节
1. scenario seed与bank hash固定。
2. 每小时checkpoint report，最终report包含完整duration。
3. 失败保留最近trace/ring水位/generation状态。
4. 任何实时违规返回owner任务修复并重跑全8小时。
5. profile采集本身不得造成render阻塞。

## 接口与数据契约
新增`zig build sme-stress -- --device|--offline --hours 8 --seed ... --report ...`。提前退出、指标非0、duration不足均失败。

## 文件变更
- stress tool与build helper（不直接改`run_validation.ps1`）。
- audit/device/stress artifacts。

## 验证
### 自动化验证
- 先运行短`--minutes 5` smoke验证工具。
- 正式执行两条8小时命令并校验report duration/metrics。
### 手工验证
- 物理断开/恢复设备；确认transport按next bar/cue策略恢复。
### 边界与失败场景
- disk pressure、CPU pressure、device lost、worker late、reload during transition。

## 完成定义
- [ ] RT call graph无红线违规。
- [ ] 真实device和offline各8小时完整通过。
- [ ] dropout/underrun/overflow/skew=0。
- [ ] 报告含机器/driver/toolchain/commit/bank hash。

## 风险与注意事项
任务耗时长不是降低门槛的理由；未满8小时不得完成。
