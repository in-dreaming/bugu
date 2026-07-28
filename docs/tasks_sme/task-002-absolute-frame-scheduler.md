# TASK-002：实现绝对 render-frame scheduler 与原子 command block

## 元数据
- 状态：待实施
- 执行波次：1
- 硬依赖：TASK-001
- 协作关系：TASK-005/007/011/013/014 消费本任务 contract；`src/core/engine.zig` 由本任务先修改
- 预计改动范围：`src/core/engine.zig`、`src/device/device.zig`、`src/mixer/mixer.zig`、`src/music/scheduler.zig`（新增）、`tests/sme/scheduler_test.zig`（新增）

## 目标
使 control side 可以提交按绝对 `u64 render_frame` 排序的有界命令组，mixer 在 quantum 内精确 sample offset 执行，并返回实际 frame receipt。

## 上下文
当前 engine 直接 start/update voice，只有 rendered frame telemetry，没有未来命令队列。仅在 quantum 边界启动无法满足任意 BPM；逐 stem 即时启动也不原子。

## 前置条件
- TASK-001 提供 request/receipt/error/handle 契约。
- 明确当前 `EngineConfig.quantum_frames` 和 FixedQuantumAdapter 行为。

## 实施范围
### 必须完成
- 建立单调绝对 render frame，设备与 offline 共用。
- 实现固定容量 `ScheduledCommandBlock` 和原子 command group。
- control side 预排序 `(execute_frame, sequence)`；render 不排序/分配。
- quantum 内按命令 frame 切分有界 render spans。
- 支持取消尚未发布 plan、stale sequence 拒绝和 execution receipt。
- queue/block high-water、overflow、late command telemetry。

### 明确不包含
- 音乐 clock、state/planner。
- voice group 具体命令；只提供 typed payload seam。
- worker I/O 或 codec。

## 设计与执行细节
1. block 覆盖明确 `[start_frame,end_frame)`；只接受窗口内或未来 block 命令。
2. 同 group 全部命令容量预检成功后一次发布；失败不部分写入。
3. late command 默认拒绝并 receipt=`late`；紧急 stop 走独立 bounded emergency lane 和最短 ramp。
4. device callback frame count 不规则仍经 FixedQuantumAdapter 保持相同绝对 frame。
5. counter 使用 atomics；详细 reason 在 control side 格式化。

## 接口与数据契约
`ScheduledMusicCommand { execute_frame:u64, sequence:u64, group_id:u64, payload }`。
`ExecutionReceipt { sequence, planned_frame, executed_frame, result }`。
`CommandQueueFull`、`InvalidState`、`StaleAssetGeneration` 语义不得合并。

## 文件变更
- `src/music/scheduler.zig`：新增 queue/block/receipt。
- `src/core/engine.zig`：拥有绝对 frame 和 publish/poll API。
- `src/device/device.zig`：adapter frame 连续性。
- `src/mixer/mixer.zig`：quantum span 执行 seam。
- `tests/sme/scheduler_test.zig`：确定性、原子性、offset。

## 验证
### 自动化验证
- `zig build test`。
- 覆盖 quantum 首/中/尾 frame、同 frame sequence、跨 quantum、queue full、原子 group 容量不足、late command、callback 非固定 frame。
### 手工验证
- 不需要。
### 边界与失败场景
- `u64` 接近 wrap 时初始化拒绝不安全 duration。
- publish 与 render 交错不得读取半写 block。

## 完成定义
- [ ] offline 实测脉冲出现在计划 sample。
- [ ] 原子 group 永不部分执行。
- [ ] render path 无 alloc/lock/log/I/O。
- [ ] 现有 voice/demo 行为回归通过。

## 风险与注意事项
不要为了 scheduler 把 Music Director 放进 render thread；payload 只表达已经规划好的 bounded 操作。

