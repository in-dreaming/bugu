# TASK-011：实现音乐 streaming、prefetch、seek 与 emergency recovery

## 元数据
- 状态：待实施
- 执行波次：3
- 硬依赖：TASK-002、TASK-003、TASK-004、TASK-010
- 协作关系：TASK-006 virtual voice 发 seek intent；TASK-009 查询 readiness；TASK-014/016 管理生命周期
- 预计改动范围：`src/streaming/music_stream.zig`、`src/streaming/prefetch.zig`（新增）、`src/core/engine.zig`、`tests/sme/streaming_test.zig`

## 目标
让长 stems 通过 worker 解码进入预分配 PCM ring，支持 transition 并发预取、sample-accurate seek/loop、group readiness 和真实 emergency segment。

## 上下文
当前 bank 全量 preload；render thread不得 I/O/解码。必需 stem 缺块时不能让其他 layers 静默继续。

## 前置条件
- scheduled command/receipt。
- MusicBank chunks/seek/profile。
- Ogg Opus adapter。
- trace contract。

## 实施范围
### 必须完成
- 固定容量 stream instances、PCM rings、free lists。
- worker decode jobs/completion queue。
- low/high/critical watermarks 和 deadline-aware prefetch。
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
3. chunk descriptors/hash 在读入时校验。
4. worker late 不阻塞；planner 推迟合法边界。
5. emergency segment 必须 bank build 时验证 resident。

## 接口与数据契约
readiness snapshot 包含 resident chunks、estimated ready frame、watermark、generation。错误：`TargetNotResident`、`StreamUnderrun`、decode/hash/I/O reason。

## 文件变更
- 新增 streaming/prefetch/tests。
- engine 增加 worker ownership/completion，不放入 mixer。

## 验证
### 自动化验证
- `zig build test`。
- 新增 `zig build sme-stream-test`：连续 stream、随机 seek、loop、source+fill+target 并发、slow worker、corrupt chunk、required/optional underrun、emergency。
### 手工验证
- 使用真实 Ogg Opus 文件观察水位 trace。
### 边界与失败场景
- ring wrap、EOS、seek near end、job after unload、all required streams unavailable。

## 完成定义
- [ ] nominal stream/seek/loop underrun=0。
- [ ] render 无 decode/I/O/alloc/lock。
- [ ] required failure 不产生残缺配器静默。
- [ ] planner 可依 readiness 作确定决策。

## 风险与注意事项
不要用无限缓存或全量 decode 通过测试；测试要设置小 ring 强制 wrap/prefetch。

