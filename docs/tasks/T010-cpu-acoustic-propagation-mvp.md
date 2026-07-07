# T010 CPU 复合声学传播 MVP

状态：TODO  
类型：Implementation  
优先级：P2  
依赖：T009  
预计产物：CPU acoustic propagation prototype、AcousticResponse 输出、测试场景。

## 1. 背景

GPU 之前必须先在 CPU 上验证传播模型正确性。MVP 要能听出无墙、厚墙、墙洞/门窗、山洞、开阔地的差异。

## 2. 必读

- docs/design/audio-engine-design.md 第 10 节
- T009 acoustic scene 设计

## 3. 实现范围

必须实现：

- CPU voxel ray traversal。
- Direct rays：判断直达清晰度。
- Penetration rays：累积 solid/material depth。
- Escape/openness rays：估计开放程度和外部方向。
- Single-bounce reflection rays：估计早期反射 tap。
- Portal/opening 查询：洞口、门、窗。
- 3-band material absorption/transmission。
- AcousticResponse 输出。
- Temporal smoothing。

## 4. AcousticResponse 最小字段

必须包含：

- direct_gain
- direct_delay
- direct_lowpass_hz
- transmission_gain
- transmission_lowpass_hz
- diffraction_or_portal_gain
- diffraction_or_portal_direction
- early_reflection_taps，至少 4 个
- late_reverb_send
- openness
- ambient_direction
- confidence

## 5. 验收场景

必须构造并验证：

1. 无墙：direct_gain 高，low-pass 弱。
2. 厚墙：direct 低，transmission 有低通，高频衰减明显。
3. 墙洞：声音方向偏向洞口，portal gain 随洞大小变化。
4. 门开关：door_open_fraction 改变 propagation response，平滑无硬跳。
5. 山洞：reflection/reverb/openness 与开阔地不同。
6. 开阔地：openness 高，late reverb 低。

每个场景必须有可重复的输入数据和数值输出摘要；推荐保存为 JSON/CSV snapshot，供 T011/T012 复用。

## 6. 不得越界

- 不做 GPU。
- 不把结果直接写入 audio render thread mutable state。
- 不追求物理完美；先追求可解释、可调、可验证。
- 不按场景名或测试名硬编码 AcousticResponse。
- 不跳过 voxel/material/portal 数据直接返回人工参数。

## 6.1 验收标准

- AcousticResponse 由 T009 定义的 scene/voxel/material/portal 输入计算得到。
- 六个场景的 direct/transmission/portal/openness/reverb 指标变化方向符合预期。
- temporal smoothing 可开关测试；关闭时能看到原始 solver 输出。
- Evidence 包含执行命令、输入 scene、输出 AcousticResponse 摘要。

## 7. Activity Log

- 2026-07-07：任务创建。
