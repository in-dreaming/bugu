# TASK-015：实现 Stinger、duck request 与 acoustic-to-music 映射

## 元数据
- 状态：TODO
- Owner：`UNASSIGNED`
- Reviewer：`UNASSIGNED`
- 实施角色：Runtime Audio Integration
- 评审角色：DSP、声学集成、实时安全
- 工作量等级：`M`
- 证据路径：`docs/validation/sme/TASK-015/evidence.md`（脱敏摘要）、`zig-out/sme-validation/TASK-015/`（原始产物）
- 执行波次：10
- 硬依赖：TASK-004、TASK-013、TASK-014
- 协作关系：与 TASK-016/017 可并行；只通过 MusicRuntime extension seam
- 预计改动范围：`src/music/stinger.zig`、`src/music/acoustic_mapping.zig`（新增）、`src/music/runtime.zig` 的注册扩展、`tests/sme/stinger_acoustic_test.zig`

## 目标
交付不改变主 transport 的 stinger 调度、可组合 automation duck request，以及将 AcousticResponse 平滑映射为音乐参数的可选输入能力。

## 上下文
Stinger 必须使用同一绝对 frame scheduler。声学可影响 layer/filter/send，但不能直接拥有 state graph 或阻塞 GPU。

## 前置条件
- MusicRuntime extension seam。
- Bus DAG/sidechain。
- trace。

## 实施范围
### 必须完成
- stinger immediate/beat/bar sync、`PlatformProfile.max_stingers`、每 stinger/polyphony 上限、repeat window 与 drop/replace/defer deadline；所有时间以 frames 或 musical boundary 表达。
- stinger priority/protection/duck main music。
- begin/end duck request、priority/combine/attack/hold/release。
- `AcousticMusicProfile`：每个 openness/room/path 输入的 min/max、neutral、attack/release smoothing frames、rate limit per second、quantize steps、stale timeout frames 和 missing-data policy。
- acoustic result stale/GPU late/CPU fallback semantics。
- telemetry 与 trace。

### 明确不包含
- 修改 acoustic solver。
- 用声学参数直接切主 state。

## 设计与执行细节
1. stinger 是独立 scheduled group，不加入 selector history。
2. repeated trigger 使用 stable request ID tie-break。
3. duck request handle generation 防止重复 end。
4. acoustic mapping 在 control thread，规则来自 bank；release profile 的 stinger 并发、duck ramp 和 acoustic smooth/rate-limit 默认值必须冻结并出现在 compiler report。
5. 缺 acoustic input 保留上值/neutral profile，不影响 clock。

## 接口与数据契约
`StingerDesc`、`DuckRequest/DuckRequestId`、`AcousticMusicProfile`。三者的容量、时间单位、默认值与 profile override 顺序必须显式；超出上限返回结构化 reason，不能 clamp 后假成功。错误：stinger limit、invalid duck handle、stale acoustic sample；不得返回假 success。

## 文件变更
- 新增 stinger/acoustic modules/tests。
- runtime 仅注册 extension，不改核心 tick 顺序。

## 验证
### 自动化验证
- `zig build test`。
- 各 sync、并发/repeat policy、duck combine、invalid handle、声学阶跃平滑、late GPU、CPU value、missing data、state/transport不变。
### 手工验证
- offline PCM/trace 观察 stinger 与 duck。
### 边界与失败场景
- stinger chunk late、duck owner销毁、NaN acoustic value。

## 完成定义
- [ ] stinger sample frame符合 sync。
- [ ] duck 真实控制 Bus DAG。
- [ ] acoustic input 永不阻塞/切 state。
- [ ] 所有策略可追踪。
- [ ] release profile 的 stinger/duck/acoustic 定量默认值和 override 顺序已冻结。

## 活动日志

- 2026-07-28：根据评审报告完成规格收口；状态保持 `TODO`，未开始代码实施。

## 风险与注意事项
不要让 stinger 或 acoustic path 绕过 voice budget和stream readiness。



## 统一调度与重放补充
Stinger、automation duck与主音乐共用production RuntimeRenderer的scheduler/clock，token含transport/device/generation epoch；stop/pause/reload对未来stinger/duck ramp的策略显式编码，不通过legacy Engine另一mixer播放。声学输入在control接受时量化并记录accepted frame和序号进入ReplayInputV2；重放不等待GPU，不读取本次异步到达顺序。测试same-frame stinger/state/cancel的稳定次序、pending block acquired后失效、旧generation receipt不重新开启duck。
