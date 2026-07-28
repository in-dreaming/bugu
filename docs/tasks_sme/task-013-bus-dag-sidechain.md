# TASK-013：实现 Bus DAG、automation ducking 与真实 signal sidechain

## 元数据
- 状态：TODO
- Owner：`UNASSIGNED`
- Reviewer：`UNASSIGNED`
- 实施角色：Mixer DSP/Bus
- 评审角色：实时安全、DSP 数值、QA
- 工作量等级：`L`
- 证据路径：`docs/validation/sme/TASK-013/evidence.md`（脱敏摘要）、`zig-out/sme-validation/TASK-013/`（原始产物）
- 执行波次：4
- 硬依赖：TASK-002、TASK-004、TASK-005、TASK-006
- 协作关系：TASK-012 写 bus/send targets；TASK-015 发 duck requests；TASK-018/019 读取 meters
- 预计改动范围：`src/mixer/bus_graph.zig`、`src/mixer/sidechain.zig`（新增）、`src/mixer/mixer.zig`、`tools/sme_compiler/buses.zig`、`tests/sme/sidechain_test.zig`

## 目标
替换固定标签式音乐路由为加载期编译的有界 Bus DAG，并实现 state automation duck 与 Dialogue detector 驱动的真实 Music compressor。

## 上下文
当前只有 SFX/Music/Master label 和固定 reverb bus。v1 不允许用固定 gain ramp冒充 sidechain。

## 前置条件
- scheduled block。
- multichannel mixer。
- trace/telemetry。

## 实施范围
### 必须完成
- Bus nodes、send/return、topological compile、cycle rejection。
- gain/mute/channel layout/effect chain/meter。
- automation duck combine mode、clamp、attack/hold/release。
- detector/compressor threshold dBFS、ratio、knee dB、attack/release/hold frames、detector RMS/peak window frames、meter window frames、lookahead frames/bound、makeup dB 与总 latency frames；所有字段有合法范围和默认 preset。
- Dialogue->detector->Music compressor 路径。
- peak/RMS/envelope/gain reduction telemetry。

### 明确不包含
- convolution/HRTF 新效果。
- stinger/duck high-level request policy。

## 设计与执行细节
1. graph 在 bank load 编译成 flat node list。
2. effect state预分配；render只遍历 fixed nodes。
3. automation 与 signal reduction 分开计算、合并后 clamp。
4. lookahead 使用固定 ring 并计入 latency。默认 release preset 的 detector/meter window、lookahead 与最大总 latency 必须在实现前冻结；bank 加载报告和 runtime snapshot 同时暴露实际值。
5. unknown bus/send/layout load 失败。

## 接口与数据契约
`BusGraphDesc`、`SidechainPreset`、`DuckAutomationTarget`、`BusMeterSnapshot`。`SidechainPreset` 所有时间均以 frames 存储并在 authoring 层显示毫秒；snapshot 携带 preset ID、window/lookahead/latency frames，避免工具猜测。cycle/unsupported layout/invalid compressor 参数为 bank error。

## 文件变更
- 新增 bus/sidechain/compiler/tests。
- mixer 接入 DAG，同时保留 legacy fixed bus adapter。

## 验证
### 自动化验证
- `zig build test`。
- graph topology/cycle、multichannel send、automation combine、真实 dialogue PCM detector、默认 preset exact 值、detector/meter 窗口、attack/release/knee/lookahead/latency、silence、非法或数值不稳定参数。
### 手工验证
- offline 对比 dialogue on/off gain reduction trace。
### 边界与失败场景
- zero attack、ratio invalid、feedback send、meter overflow。

## 完成定义
- [ ] sidechain 由真实 PCM envelope 驱动。
- [ ] graph/effects render 无分配和锁。
- [ ] legacy bus 回归。
- [ ] meter 与 PCM oracle 在已冻结窗口/容差内一致。
- [ ] 默认 `SidechainPreset` 的范围、窗口、lookahead 与 latency budget 已冻结并写入 evidence。

## 活动日志

- 2026-07-28：根据评审报告完成规格收口；状态保持 `TODO`，未开始代码实施。

## 风险与注意事项
不要把 graph 拓扑排序放到 render callback。
