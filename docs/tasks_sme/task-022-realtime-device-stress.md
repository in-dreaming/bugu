# TASK-022：完成实时安全审计、真实设备与 8 小时压力 gate

## 元数据
- 状态：TODO
- Owner：`UNASSIGNED`
- Reviewer：`UNASSIGNED`
- 实施角色：Performance/Device QA
- 评审角色：实时安全、设备、性能
- 工作量等级：`L`
- 证据路径：`docs/validation/sme/TASK-022/evidence.md`（脱敏摘要）、`zig-out/sme-validation/TASK-022/`（原始产物）
- 执行波次：16
- 硬依赖：TASK-011、TASK-013、TASK-014、TASK-021、TASK-025
- 协作关系：TASK-023引用support matrix；本任务不改validation wrapper主逻辑
- 预计改动范围：`tools/sme_stress/`（新增）、`zig-out/sme-validation/TASK-022/`、`docs/validation/sme/TASK-022/evidence.md` 与 `device-matrix.md`、必要 runtime 修复归属原 Owner

## 目标
用审计和真实运行证据证明render path实时安全、Windows设备生命周期可靠，并通过至少8小时全能力压力运行。

## 上下文
build/test通过不是产品实时证据。Offline fallback不能替代真实设备gate。

## 前置条件
- headless 全量 validation 通过，TASK-025 production baseline 和 TASK-026 public vertical slice 回归仍有效。
- TASK-004/021 已提供每个关键 counter/timing 的 producer、单位、有效性、样本数及正向 fault-injection 证据；未连接计量点的 0 不满足此前置条件。
- 有支持矩阵中的Windows设备、driver和MSVC/Zig环境。

## 实施范围
### 必须完成
- 逐函数 production callback → RuntimeFixedQuantumAdapter → RuntimeRenderer → Mixer call graph 审计：alloc/lock/I/O/log/GPU wait/lazy decode、无界 CAS/retry、snapshot acquire、owner pin、最后引用释放与 receipt overflow。
- stress tool：state churn、tempo/fill、stream seek、virtual churn、stinger、sidechain、reload、device reopen。
- 8小时device run和8小时offline accelerated/real-time对应run。
- p50/p95/p99/p999/max、dropout/underrun/overflow/skew/leak。
- 最小设备矩阵：Windows x86_64、WASAPI、48 kHz/stereo、至少一个真实物理输出设备；记录 OS build、CPU architecture、device model、driver version，不记录机器名或序列号。额外设备/格式只能增加覆盖，不能替代此行。
- device start/stop/lost/reopen 证据。
- 内存/handle/generation稳定性。

### 明确不包含
- 以短smoke推算8小时结果。
- 以offline替代device。
- 在 stress tool 中绕过公共 production Runtime API/adapter；Engine-only 或直接 mixer 压力不能替代。

## 设计与执行细节
1. scenario seed与bank hash固定。
2. 每小时checkpoint report，最终report包含完整duration。
3. 失败保留最近trace/ring水位/generation状态。
4. 任何实时违规返回owner任务修复并重跑全8小时。
5. profile 采集本身不得造成 render 阻塞。相对 instrumentation-disabled baseline，启用 profiling 后 control/render p999 增幅必须不超过 5%，且 dropout/underrun/overflow/skew 仍为 0；报告同时保存 baseline、instrumented 值和样本数。

### 先证明指标会失败，再接受长时间为零

1. 固定 `MetricCoverageManifest`：每个 release 指标的 producer、单位、reset scope、采样数、有效标志、overflow 规则和 fault fixture；链接 TASK-004 schema 与 TASK-021 短测试 evidence。
2. 正向故障矩阵至少包含 callback 超时/deadline miss、必需 stream 空 ring、command/receipt/completion/trace 满、device lost/reopen、stale generation、取消 epoch 拒绝与 lease reclaim。通过真实输入/延迟/容量设置触发生产分支，不直接向 counter 写入测试值。
3. 每个 fixture 同时断言目标 counter/timing 增长、对应 event/receipt reason 存在、最终报告失败或声明预期 degraded、清理后无泄漏；错误计数恒为零或样本为空必须阻塞 release。
4. render/control/planner/callback timing 必须有非零样本数与合理单位范围，记录 timer source、精度、wrap/unsupported 处理。指标不受平台支持时标 unsupported 并补受支持测量方法，不输出 0 ns 当快速路径。
5. nominal 与 injected run 使用独立 seed/run ID、counter reset 和 verdict；nominal 8 小时中的意外 injected/real 错误仍失败。设备断开/reopen 专项可预期有 discontinuity 计数，但不能以它为理由抹掉 nominal 错误。

### 有界实时路径与 lease 审计

- 审计表逐函数列最大 iterations、输入 capacity、最大 render span、CAS retry 上限和失败策略；`lock-free` 不是 `bounded` 的证明。重点复查 `ControlRuntime.acquireSnapshot` 与 `SampleOwner.pin` 的 production 调用路径和 TASK-025 修复/证据。
- snapshot acquire 达预算时使用已持有且有效的 snapshot 或显式安全路径，计数并继续 callback；不得 busy-wait 等 Control。完成 one-shot 的 terminal 身份不能因复用旧 snapshot 重新启动。
- bank/stream/plan/voice owner 的最后 release 仅向固定 retire channel 交接，所有实际 free/join 在非 realtime；队列满也有 bounded backpressure/retention，不得退回 callback free 或等待。
- epoch invalidation 必须在实际执行 gate 审计，记录 acquire 后取消与 partial 多 fill 取消；不能把“control 不再发布旧计划”当作 RT 拒绝保证。

### 设备与长时间报告 oracle

- 同一公开 runtime 驱动 SFX+music+sidechain，记录唯一 renderer/mixer/context ID；不允许压力工具启动独立 Engine mixer 绕开共享预算/生命周期。
- 对 1/127/256/300/513 和实际设备 callback 分布，记录 render/submitted/pending/discarded frame账目守恒、delivered可选played观测质量与误差、device epoch；lost/reopen 时保留旧 pending 哨兵样本并证明它们不进入新 epoch。
- 8 小时 device run 以真实 monotonic elapsed time 计，offline run 至少渲染 `8*3600*sample_rate` frames 并报告加速后的实际 elapsed 与音乐模拟 duration。两者不可互换、不可拼接失败片段凑时长。
- 每小时 checkpoint 含 coverage validity/sample_count、lease/handle/generation 高水位与净差、p50/p95/p99/p999/max、对应 ReplayInputV2/trace hash。trace 丢失即无法完整证明，不能仅凭最后 counter 快照 PASS。
- hardware 未提供物理播放位置或 xrun 证据时，报告软件 deadline/delivery 检测的覆盖边界；物理无 glitch 结论必须有 loopback/外部录音独立证据，试听不能替代机器可审查的输出测量。四类指标 `stream_starvation`、`callback_deadline_miss`、`backend_reported_underrun`、`physical_glitch` 分别报告，不用同一个 dropout=0 掩盖不可观测项。

## 接口与数据契约
新增 `zig build sme-stress -- --device|--offline --hours 8 --seed ... --report ...`。nominal run 提前退出、关键指标非 0、计量 invalid/unsupported、样本数为 0、trace 不完整或 duration 不足均失败；fault-injection runs 单独报告预期错误，不能与 nominal 零错误统计混算。

## 文件变更
- stress tool与build helper（不直接改`run_validation.ps1`）。
- `docs/validation/sme/TASK-022/device-matrix.md`：脱敏最小支持矩阵与实际覆盖。
- raw audit/device/stress artifacts 写入 `zig-out/sme-validation/TASK-022/`，仓库只提交 evidence 摘要。

## 验证
### 自动化验证
- 先运行短 `--minutes 5` smoke；再运行新增 `--self-test-metrics` 模式，真实触发每个故障分支并验证报告必须非 PASS。未通过不得开始 8 小时 gate。
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

### 补充完成定义
- [ ] 8 小时启动前的 metrics 正向 fault-injection 真实使 gate 失败，所有 nominal 指标都具有有效 producer/样本。
- [ ] snapshot/owner pin/atomic retry/retire 的 RT 有界上限经代码审计与竞争测试证明。
- [ ] production shared SFX+music、acquired/partial cancellation、device pending flush 与 epoch 恢复进入长时矩阵。

## 活动日志

- 2026-07-28：根据评审报告完成规格收口；状态保持 `TODO`，未开始代码实施。
- 2026-10-09：依据 production runtime 代码校正规格，补充执行、取消、设备和证据契约；本次仅修订文档，未运行基线复现或实施代码。

## 风险与注意事项
任务耗时长不是降低门槛的理由；未满8小时不得完成。

