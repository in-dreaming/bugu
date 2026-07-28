# TASK-005：实现 multichannel mixer 与原子 MusicVoiceGroup

## 元数据
- 状态：TODO
- Owner：`UNASSIGNED`
- Reviewer：`UNASSIGNED`
- 实施角色：Mixer/DSP
- 评审角色：实时安全、multichannel、QA
- 工作量等级：`L`
- 证据路径：`docs/validation/sme/TASK-005/evidence.md`（脱敏摘要）、`zig-out/sme-validation/TASK-005/`（原始产物）
- 执行波次：2
- 硬依赖：TASK-002、TASK-004
- 协作关系：TASK-006/012/013/014 消费 group/channel contract
- 预计改动范围：`src/mixer/channel_layout.zig`、`src/mixer/music_group.zig`（新增）、`src/mixer/mixer.zig`、`src/core/engine.zig`、`tests/sme/music_group_test.zig`

## 目标
让 mixer 正确处理 mono、stereo、5.1、7.1 stems，并以一个原子 command group 创建、seek、loop、stop 多 layer MusicVoiceGroup，保证必需 stem skew 为 0。

## 上下文
当前 sample voice 是 mono 输入到 stereo 输出，voice 独立启动。完整 SME 不能以逐 voice 调用近似同步。

## 前置条件
- scheduler 支持 quantum 内原子 group。
- trace 能记录 group/layer frame。

## 实施范围
### 必须完成
- `ChannelLayout`、mask/order、interleaved frame view，以及 mono/stereo/5.1/7.1 的 canonical channel order 与逐项 downmix/upmix matrix；顺序和系数以代码常量、schema enum 与数值 fixture 三处同源生成。
- mixer multichannel input 和 stereo/匹配 layout output。
- `MusicVoiceGroup` 共享 start frame、segment cursor、loop epoch、seek/stop。
- group 创建前容量与所有必需 layers 一次预留。
- group-level ramp/release 和 execution receipt。
- 旧 mono voice 行为兼容。

### 明确不包含
- virtual voice、intensity 曲线、stream decode。
- 杜比等专有编码或 spatial object audio。

## 设计与执行细节
1. `frames` 与 scalar sample count 分离，杜绝多声道 offset 错误。
2. group render 以一个 cursor 派生所有 layer source frame。
3. channel conversion matrix 在 load/prepare 时预编译；render 不创建矩阵。未知/重复 speaker、mask 与 channel count 不一致必须加载失败，不得按位置猜测。
4. required layer 失败整组失败；optional layer 由 TASK-006/012 管理。
5. seek/loop command 必须在同一个 sample frame 原子生效。

## 接口与数据契约
`MusicGroupDesc` 含 segment/generation/layout/layers/loop/start cursor。`ChannelLayout` 必须同时携带 channel count 与 canonical speaker mask/order；转换矩阵的输入/输出 layout 和系数精度属于 bank/runtime contract。layer sample storage 必须在 group lifetime 内由 bank lease 保证。`MisalignedStems`、`VoiceBudgetExceeded`、`UnsupportedChannelLayout` 分开返回。

## 文件变更
- 新增 channel/group modules 与 tests。
- 修改 mixer/engine 接入 scheduled group payload。

## 验证
### 自动化验证
- `zig build test`。
- mono/stereo/5.1/7.1 对每个输入 speaker 的 impulse routing 数值 oracle；group 2/4/16 layers start/seek/loop/stop；容量不足；layout mismatch；连续 loop 10000 次。
### 手工验证
- offline 输出抽查声道顺序。
### 边界与失败场景
- 0 channel、未知 mask、frame count 不一致、loop 越界、group 跨 generation。

## 完成定义
- [ ] 必需 stems start/cursor skew 恒为 0。
- [ ] canonical channel order/mask 与全部受支持转换矩阵已冻结并有逐 speaker 数值 oracle。
- [ ] 原子失败无孤立 voice。
- [ ] 旧 mixer tests 全通过。

## 活动日志

- 2026-07-28：根据评审报告完成规格收口；状态保持 `TODO`，未开始代码实施。

## 风险与注意事项
不要在 task 内引入 virtual voice 或重配器策略，保持 group execution 边界单一。

