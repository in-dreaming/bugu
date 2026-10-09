# TASK-005：实现 multichannel mixer 与原子 MusicVoiceGroup

## 元数据
- 状态：TODO
- Owner：`UNASSIGNED`
- Reviewer：`UNASSIGNED`
- 实施角色：Mixer/DSP
- 评审角色：实时安全、multichannel、QA
- 工作量等级：`L`
- 证据路径：`docs/validation/sme/TASK-005/evidence.md`（脱敏摘要）、`zig-out/sme-validation/TASK-005/`（原始产物）
- 执行波次：4
- 硬依赖：TASK-002、TASK-004
- 协作关系：TASK-006/012/013/014 消费 group/channel contract
- 预计改动范围：`src/mixer/channel_layout.zig`、`src/mixer/music_group.zig`（新增）、`src/mixer/mixer.zig`、`src/core/engine.zig`、`src/runtime/runtime.zig`、`src/device/device.zig`、`tests/sme/music_group_test.zig`、`tests/sme/multichannel_output_test.zig`（新增）

## 目标
让 mixer 正确处理 mono、stereo、5.1、7.1 stems，并以一个原子 command group 创建、seek、loop、stop 多 layer MusicVoiceGroup，保证必需 stem skew 为 0。

## 上下文
当前 sample voice 是 mono 输入到 stereo 输出，voice 独立启动。`Engine.init` 和 runtime backend init 仍检查 `channels != 2`，device 的两个 fixed-quantum adapter 与 WAV 临时 buffer 使用 `max_channels = 2`；只改 mixer 会留下越界或隐藏 stereo 降级。完整 SME 不能以逐 voice 调用近似同步。

## 前置条件
- scheduler 支持 quantum 内原子 group。
- trace 能记录 group/layer frame。

## 实施范围
### 必须完成
- `ChannelLayout`、mask/order、interleaved frame view，以及 mono/stereo/5.1/7.1 的 canonical channel order 与逐项 downmix/upmix matrix；顺序和系数以代码常量、schema enum 与数值 fixture 三处同源生成。
- mixer multichannel input 和 stereo/匹配 layout output；mono、stereo、5.1、7.1 及合法显式 mask 的 matching-layout output 是必需交付，不能把 v1 缩成 multichannel 输入→stereo 输出。
- 本任务唯一拥有 Engine/RuntimeRenderer/device/offline 端到端 output layout 协商、声道顺序、两个 callback FIFO 容量与索引、PCM/WAV 输出 header 和回归；TASK-022 扩展设备矩阵，不替代本任务的功能测试。
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
6. `OutputLayoutRequest` 携带 layout/mask 和 `strict_match` 或调用者显式选择的转换目标；默认 `strict_match`。打开设备时核验 miniaudio negotiated layout/count 与请求，合法重排使用预编译 permutation，无法匹配返回 `UnsupportedChannelLayout`。不能自动重试 stereo；显式 downmix 记录 requested/negotiated layouts、matrix ID 和 reason。
7. Legacy `FixedQuantumAdapter` 与 `RuntimeFixedQuantumAdapter` 都使用 `max_quantum_frames * supported_max_channels` 的已校验预分配 storage；所有长度换算统一以 frames×channels checked multiplication，FIFO 剩余长度必须为完整 frames。保留 partial callback（1、127、255、257、1025 frames）语义及绝对 engine render frame，不能将 callback 请求 frames 当已提交 render frontier。
8. Offline float PCM 与 WAV header 使用实际 output count/mask/order；超过双声道写带有效 speaker mask 的 WAVE_FORMAT_EXTENSIBLE，导出前后逐 speaker 标记不变。浮点检验在量化/限幅前执行，16-bit 导出误差单列。
9. canonical 顺序固定：mono=FC；stereo=FL,FR；5.1=FL,FR,FC,LFE,BL,BR；7.1=FL,FR,FC,LFE,BL,BR,SL,SR；其他显式 mask 按 schema speaker 位序列化。Opus mapping family 的 codec 顺序由 TASK-010 显式重排，不能误当 canonical PCM 顺序。

## 接口与数据契约
`MusicGroupDesc` 含 segment/generation/layout/layers/loop/start cursor。`ChannelLayout` 必须同时携带 channel count 与 canonical speaker mask/order；转换矩阵的输入/输出 layout 和系数精度属于 bank/runtime contract。layer sample storage 必须在 group lifetime 内由 bank lease 保证。`MisalignedStems`、`VoiceBudgetExceeded`、`UnsupportedChannelLayout` 分开返回。

## 文件变更
- 新增 channel/group modules 与 tests。
- 修改 mixer/engine 接入 scheduled group payload；修改 runtime renderer/output view 和 device 的 legacy/runtime 两条后端与 WAV writer，禁止遗漏公共 runtime 主路径。

## 验证
### 自动化验证
- `zig build test`。
- mono/stereo/5.1/7.1 对每个输入 speaker 的 impulse routing 数值 oracle；group 2/4/16 layers start/seek/loop/stop；容量不足；layout mismatch；连续 loop 10000 次。
- 对 legacy/runtime device adapter 分别覆盖 1/2/6/8 channels × 上述 partial callback sizes 的 canary buffer、FIFO wrap/余留样本、frame conservation、声道串扰和 out-of-bounds；真实 matching-layout offline PCM/WAV round-trip 逐 speaker exact routing。
- 设备拒绝 strict matching layout、显式 stereo 转换、unsupported mask 和 negotiated order 变化的控制层测试；真实 device smoke 独立记录，不以模拟 backend 替代。
### 手工验证
- 在有 5.1/7.1 能力的受管设备逐 speaker 播放标记并记录 requested/negotiated count/mask/order；缺设备的开发机只可通过 headless 子检查点，不能把 matching-layout 设备 gate 标成通过。
### 边界与失败场景
- 0 channel、未知 mask、frame count 不一致、loop 越界、group 跨 generation。

## 完成定义
- [ ] 本任务已交付测试/fixture 通过 TASK-001 的稳定注册 seam 加入既有 `zig build test`/PR gate，证据随子交付持续产生，不等待 TASK-021 首次接入 CI。
- [ ] 必需 stems start/cursor skew 恒为 0。
- [ ] canonical channel order/mask 与全部受支持转换矩阵已冻结并有逐 speaker 数值 oracle。
- [ ] 原子失败无孤立 voice。
- [ ] 旧 mixer tests 全通过。
- [ ] Engine/public runtime→两个 callback adapters→设备及 offline WAV 的 matching-layout 输出全部实现，1/2/6/8 声道边界测试与真实设备顺序证据通过。

## 活动日志

- 2026-07-28：根据评审报告完成规格收口；状态保持 `TODO`，未开始代码实施。
- 2026-10-09：补齐实际依赖、量化/输入契约、独立审查产物与持续 gate；仅修订任务文档，状态保持 `TODO`。

## 风险与注意事项
不要在 task 内引入 virtual voice 或重配器策略，保持 group execution 边界单一。


