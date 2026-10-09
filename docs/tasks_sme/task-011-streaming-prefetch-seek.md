# TASK-011：实现音乐 streaming、prefetch、seek 与 emergency recovery

## 元数据
- 状态：TODO
- Owner：`UNASSIGNED`
- Reviewer：`UNASSIGNED`
- 实施角色：Streaming/Worker I/O
- 评审角色：实时安全、Codec、故障恢复
- 工作量等级：`L`
- 证据路径：`docs/validation/sme/TASK-011/evidence.md`（脱敏摘要）、`zig-out/sme-validation/TASK-011/`（原始产物）
- 执行波次：5
- 硬依赖：TASK-002、TASK-003、TASK-004、TASK-005、TASK-010
- 协作关系：TASK-006 virtual voice 发 seek intent；TASK-009 查询 readiness；TASK-014/016 管理生命周期
- 预计改动范围：`src/streaming/music_stream.zig`、`src/streaming/prefetch.zig`（新增）、`src/runtime/runtime.zig`（只接入已冻结扩展）、`tests/sme/streaming_test.zig`

## 目标
让长 stems 通过 worker 解码进入预分配 PCM ring，支持 transition 并发预取、sample-accurate seek/loop、group readiness 和真实 emergency segment。

## 上下文
当前 bank 全量 preload；render thread不得 I/O/解码。必需 stem 缺块时不能让其他 layers 静默继续。

## 前置条件
- scheduled command/receipt，以及TASK-005已完成的真实MusicVoiceGroup/multichannel/runtime seam，用于required underrun/emergency集成。
- MusicBank chunks/seek/profile。
- TASK-010 的 Ogg Opus adapter、真实媒体 compiler pass、已生成/校验的 Chunk/Seek tables 和超 resident gate 的真实 streaming fixture；Seek 表不能由本任务临时猜测或等待 TASK-017 CLI。
- trace contract。

## 实施范围
### 必须完成
- 固定容量 stream instances、PCM rings、free lists。
- worker decode jobs/completion queue。
- `StreamCapacityProfile` 中的 ring frames、chunk frames、decode job/completion capacity、critical/low/high watermarks、prefetch lead/deadline 和最大并发 stream；所有水位使用 PCM frames，不混用 bytes/samples。
- group minimum playable set readiness。
- seek/loop/virtual realize。
- required underrun 原子 degraded：切到已 resident emergency segment或明确 stop/error。
- stale generation/job cancellation。

### 明确不包含
- transition cue 选择。
- authoring UI。

## 设计与执行细节
1. render 只读 ring，不触发文件 API。
2. prefetch priority：imminent target/fill、active required、virtual soon-realize、optional。
3. chunk descriptors/hash 在读入时校验。Profile 必须满足 `0 < critical <= low < high < ring_capacity`，且 high/low 间隔足以容纳最大 decode chunk；初始化时验证乘法和单位转换溢出。
4. worker late 不阻塞；planner 推迟合法边界。
5. emergency segment 必须 bank build 时验证 resident。
6. 消费 TASK-010 producer 的 logical PCM seek entry，先 worker 恢复 decoder/preroll，再 discard 到目标可听 frame；完成通知携带 job ID、generation、loop epoch、target cursor、ready frame range 和 reason。Frame 完成范围与所需 playback window 不匹配时不得发布 ready。
7. 所有影响 planner/realize 的 readiness、worker 完成/失败/取消、吞吐估计输入和 Control 接受顺序记录为 TASK-004 replay 输入：`accepted_control_frame`、control epoch、stable event sequence、payload hash/范围/结果；重放在同一 accepted frame 注入记录，不能依重放机器真实 worker 速度作决定。Replay 可真实解码验证 PCM，但决策 readiness 由记录驱动。
8. resident size 强制规则由 TASK-003 schema/TASK-010 producer 执行，本任务 load 时再次核验 storage descriptor 与 profile，不得把超限 streaming 资产偷偷全量 decode 到 resident cache。持续测试资源上限包含 ring、decoder、job、temporary PCM，记录 peak bytes。

## 接口与数据契约
readiness snapshot 包含 resident chunks、`estimated_ready_frame`、watermark frames、deadline frame、generation 和 profile ID。`estimated_ready_frame` 必须由 queued bytes/frames、已测 decode throughput 与 worker backlog 的保守上界计算；未知时返回 not-ready，不写虚假时间。错误：`TargetNotResident`、`StreamUnderrun`、decode/hash/I/O reason。

## 文件变更
- 新增 streaming/prefetch/tests。
- standalone streaming worker/prefetch owner持有job/ring；ControlRuntime持有其control-side service handle并消费completion，RuntimeRenderer只借用稳定PCM ring。生产runtime扩展在TASK-005合并后由本任务接入，随后006/009/014消费；不写legacy Engine。

## 验证
### 自动化验证
- `zig build test`。
- 新增 `zig build sme-stream-test`：release profile exact 值、每个 watermark 边界、ring wrap、连续 stream、随机 seek、loop、source+fill+target 并发、slow worker、corrupt chunk、required/optional underrun、emergency。
- Replay 同一 worker completion/readiness log，同时扰动测试 worker 的真实调度/完成速度，要求 schedule bytes 相同；去掉 completion record 或改变 accepted frame 必须产生明确不完整输入/expected mismatch。
- 超 resident gate 的多声道长资产设小 ring，测量峰值 decoded/cache bytes 受 profile 限制；page/packet/loop/EOS seeks 与 TASK-010 连续 decode oracle 相同。
### 手工验证
- 使用真实 Ogg Opus 文件观察水位 trace。
### 边界与失败场景
- ring wrap、EOS、seek near end、job after unload、all required streams unavailable。

## 完成定义
- [ ] 本任务已交付测试/fixture 通过 TASK-001 的稳定注册 seam 加入既有 `zig build test`/PR gate，证据随子交付持续产生，不等待 TASK-021 首次接入 CI。
- [ ] nominal stream/seek/loop underrun=0。
- [ ] render 无 decode/I/O/alloc/lock。
- [ ] required failure 不产生残缺配器静默。
- [ ] planner 可依 readiness 作确定决策。
- [ ] release `StreamCapacityProfile` 的容量、水位、deadline 与静态内存占用已冻结。

## 活动日志

- 2026-07-28：根据评审报告完成规格收口；状态保持 `TODO`，未开始代码实施。
- 2026-10-09：补齐实际依赖、量化/输入契约、独立审查产物与持续 gate；仅修订任务文档，状态保持 `TODO`。

## 风险与注意事项
不要用无限缓存或全量 decode 通过测试；测试要设置小 ring 强制 wrap/prefetch。


