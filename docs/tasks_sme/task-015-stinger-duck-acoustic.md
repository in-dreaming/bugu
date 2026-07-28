# TASK-015：实现 Stinger、duck request 与 acoustic-to-music 映射

## 元数据
- 状态：待实施
- 执行波次：6
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
- stinger immediate/beat/bar sync、并发上限、repeat、drop/replace/defer。
- stinger priority/protection/duck main music。
- begin/end duck request、priority/combine/attack/hold/release。
- AcousticMusicProfile：clamp/smooth/rate-limit/quantize openness/room/path等输入。
- acoustic result stale/GPU late/CPU fallback semantics。
- telemetry 与 trace。

### 明确不包含
- 修改 acoustic solver。
- 用声学参数直接切主 state。

## 设计与执行细节
1. stinger 是独立 scheduled group，不加入 selector history。
2. repeated trigger 使用 stable request ID tie-break。
3. duck request handle generation 防止重复 end。
4. acoustic mapping 在 control thread，规则来自 bank。
5. 缺 acoustic input 保留上值/neutral profile，不影响 clock。

## 接口与数据契约
`StingerDesc`、`DuckRequest/DuckRequestId`、`AcousticMusicProfile`。错误：stinger limit、invalid duck handle、stale acoustic sample；不得返回假 success。

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

## 风险与注意事项
不要让 stinger 或 acoustic path 绕过 voice budget和stream readiness。

