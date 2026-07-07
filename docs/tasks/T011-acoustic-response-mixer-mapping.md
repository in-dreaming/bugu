# T011 AcousticResponse 到 mixer 的映射

状态：TODO  
类型：Design+Implementation  
优先级：P2  
依赖：T010，T005  
预计产物：AcousticSnapshot 到 voice/bus/effect 参数的映射实现和听感 demo。

## 1. 背景

Acoustic solver 输出的是物理或近似物理响应；mixer 需要的是 gain、filter、delay、reverb send、direction、HRTF/pan 参数。这个任务负责中间翻译层。

## 2. 必读

- T010 AcousticResponse
- T005 mixer/effect 能力
- docs/design/audio-engine-design.md 第 9、10、11、12 节

## 3. 设计范围

必须定义：

- AcousticResponse 到 voice direct path 的 gain/filter/delay。
- transmission 到 muffled layer 的 gain/filter。
- diffraction/portal 到 apparent direction 的映射。
- early_reflection_taps 到 delay taps 或 early reflection bus 的映射。
- late_reverb_send 到 reverb bus 或 preset 的映射。
- openness 到 outdoor/indoor ambience 参数。
- confidence 到 smoothing 强度的映射。

## 4. 实现范围

至少实现：

- direct path gain + low-pass。
- transmitted path gain + stronger low-pass。
- portal direction 影响 pan。
- simple early reflection delay taps。
- late reverb send scalar。
- 20-100 ms smoothing。

## 5. 验收标准

- T010 六个场景能在听感上区分。
- 墙洞 case 中声音方向来自洞口，而不是简单从 source 穿墙。
- door open/close 不出现突兀 click 或参数爆跳。
- 所有参数通过 AcousticSnapshot 进入 audio thread。
- 能 debug 打印或可视化 response 到 mixer 参数的映射。
- Evidence 必须包含 AcousticResponse 输入、生成的 mixer 参数、输出 sample 或 telemetry 摘要。
- fallback 允许只实现 direct/transmission/portal/reverb_send 子集，但未实现字段必须在 snapshot 中显式标 invalid/default，不能静默忽略。

## 5.1 禁止 mock

- 不能按六个场景名手写 mixer 参数。
- 不能绕过 AcousticSnapshot 直接改 voice 内部状态。
- 不能只打印参数而不接入 mixer 或离线渲染路径。

## 6. Activity Log

- 2026-07-07：任务创建。
