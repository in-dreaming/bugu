# TASK-022：完成实时安全审计、真实设备与 8 小时压力 gate

## 元数据
- 状态：TODO
- Owner：`UNASSIGNED`
- Reviewer：`UNASSIGNED`
- 实施角色：Performance/Device QA
- 评审角色：实时安全、设备、性能
- 工作量等级：`L`
- 证据路径：`docs/validation/sme/TASK-022/evidence.md`（脱敏摘要）、`zig-out/sme-validation/TASK-022/`（原始产物）
- 执行波次：12
- 硬依赖：TASK-011、TASK-013、TASK-014、TASK-021
- 协作关系：TASK-023引用support matrix；本任务不改validation wrapper主逻辑
- 预计改动范围：`tools/sme_stress/`（新增）、`zig-out/sme-validation/TASK-022/`、`docs/validation/sme/TASK-022/evidence.md` 与 `device-matrix.md`、必要 runtime 修复归属原 Owner

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
- 最小设备矩阵：Windows x86_64、WASAPI、48 kHz/stereo、至少一个真实物理输出设备；记录 OS build、CPU architecture、device model、driver version，不记录机器名或序列号。额外设备/格式只能增加覆盖，不能替代此行。
- device start/stop/lost/reopen 证据。
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
5. profile 采集本身不得造成 render 阻塞。相对 instrumentation-disabled baseline，启用 profiling 后 control/render p999 增幅必须不超过 5%，且 dropout/underrun/overflow/skew 仍为 0；报告同时保存 baseline、instrumented 值和样本数。

## 接口与数据契约
新增`zig build sme-stress -- --device|--offline --hours 8 --seed ... --report ...`。提前退出、指标非0、duration不足均失败。

## 文件变更
- stress tool与build helper（不直接改`run_validation.ps1`）。
- `docs/validation/sme/TASK-022/device-matrix.md`：脱敏最小支持矩阵与实际覆盖。
- raw audit/device/stress artifacts 写入 `zig-out/sme-validation/TASK-022/`，仓库只提交 evidence 摘要。

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
- [ ] 报告只含允许共享的 OS/CPU architecture/device model/driver/toolchain/commit/bank hash，不含机器名、用户名、绝对路径或序列号。
- [ ] 最小设备矩阵通过，profiling p999 overhead ≤ 5% 且零错误指标不变。

## 活动日志

- 2026-07-28：根据评审报告完成规格收口；状态保持 `TODO`，未开始代码实施。

## 风险与注意事项
任务耗时长不是降低门槛的理由；未满8小时不得完成。
