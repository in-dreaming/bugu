# Bugu 游戏音频引擎设计文档

状态：Draft v0.1  
日期：2026-07-07  
输入：docs/research/1.md 初步调研 + 2026-07 当前公开资料核验  
目标：为 Bugu sound engine 定义可落地的底层选型、运行时架构、资产管线、空间声学系统，以及“基于光锥 GPU 的 sounds 系统”的分期路线。

## 0. 结论先行

Bugu 的音频引擎建议采用“自研运行时核心 + 可插拔平台后端 + 可替换解码器”的结构。

| 决策点 | 推荐 | 原因 |
|---|---|---|
| 底层设备后端 | 中长期自研；短期允许 miniaudio 或 SDL3 Audio backend 过渡 | 音频线程、延迟、设备恢复、平台异常处理是引擎基础能力；但早期不要把时间烧在每个平台的设备细节上 |
| SDL_sound | 不作为底层音频引擎；只可作为可选解码/导入库 | SDL_sound 是 soundfile decoder，不负责混音图、Voice 调度、DSP、空间音频和设备级策略 |
| SDL3 Audio | 可作为一个平台后端适配层 | SDL3 Audio 以 SDL_AudioStream 为核心，适合跨平台播放、转换、流式缓冲；但 mixer 和资源管线仍应自研 |
| miniaudio | 推荐作为 P0/P1 原型后端 | 单文件、跨平台 backend 覆盖广，便于快速验证 mixer、streaming、voice manager |
| 混音核心 | 自研 | 实时安全、Bus 图、Voice virtualization、参数自动化、性能统计都要自己可控 |
| 空间声学 | CPU 先行，GPU 可选加速 | GPU 适合大批量可见性、遮挡、传播查询；不适合 P0 就进入 sample-accurate 混音热路径 |
| 光锥 GPU sounds | 作为复合声学传播模拟系统，而不是单纯的声源 culling | 用 GPU/CPU ray、voxel、probe 模拟直达声、反射、穿透、衍射、洞口/门窗泄露、山洞/开阔地混响等传播现象，音频线程消费上一帧或上两帧的稳定声学结果 |

一句话版本：不要把 SDL_sound 当作“底层方案”的对手；真正的路线是自研音频运行时，底层后端先借成熟库过桥，最终替换为可控的 native backend。

## 1. 公开资料核验与选型影响

### 1.1 SDL_sound 的真实边界

SDL_sound 当前定位是抽象音频文件解码库：输入文件或内存数据，输出解码后的 waveform，可分块解码，也能做采样率、格式、声道转换。它依赖 SDL；当前主线已要求 SDL 3.x，2.x 分支进入维护模式，项目正在聚焦 SDL_sound 3.x。

它能解决：

- WAV、MP3、Ogg Vorbis、FLAC、AIFF、AU、MOD、MIDI、Raw PCM 等格式导入或运行时解码；
- 简单分块读取；
- 简单格式转换。

它不能解决：

- 低延迟设备管理；
- 实时 mixer；
- Bus、Send、Return 图；
- Voice virtualization 和 stealing；
- HRTF、occlusion、diffraction、portal；
- 音频编辑器、Bank 编译、性能 profile。

结论：SDL_sound 不能作为 Bugu 音频引擎的“底层”整体方案，只能作为 decoder adapter 或资产导入工具链的一部分。

### 1.2 SDL3 Audio 与 miniaudio 的位置

SDL3 Audio 的核心抽象是 SDL_AudioStream：播放、录制、转换、流式、缓冲、混音都围绕 AudioStream 进行。它很适合作为跨平台 I/O 和格式转换适配层，但如果把引擎 mixer 直接建立在 SDL 的抽象上，后续会比较难做 sample-accurate 调度、Bus profile 和实时安全约束。

miniaudio 支持 WASAPI、DirectSound、WinMM、Core Audio、ALSA、PulseAudio、JACK、AAudio、OpenSL ES、Web Audio、Null、Custom 等 backend，并允许自定义 backend。它更像一个“低摩擦启动器”：P0 阶段用它打通设备、回调、streaming、capture 很划算。

建议路线：

- P0：使用 miniaudio device callback 承载自研 mixer。
- P1：新增 SDL3 backend，作为备用和对照。
- P2：实现 native WASAPI、CoreAudio、AAudio、PipeWire backend。
- P3：保留 miniaudio 和 SDL3 backend 作为 fallback、测试和工具链播放后端。

### 1.3 参考中间件的可借鉴点

FMOD 的 virtual voice 思路值得直接吸收：允许大量逻辑声音同时存在，但只有少量 real voices 真正产生音频；实时根据 audibility、priority、volume、fade、DSP send 等信息在 virtual 和 real 之间切换。

Wwise 和 Unreal 的空间化与衰减设计值得吸收：

- 距离衰减不只有 inverse，需要支持 linear、log、inverse、custom curve；
- cone attenuation 是一等公民：声源方向性会影响 dry volume 与 low-pass；
- air absorption、listener focus、reverb send、occlusion 应该是同一个 attenuation profile 的组成部分，而不是分散在代码里。

Steam Audio 是空间声学参考基线：HRTF、Ambisonics、自定义 SOFA HRTF、遮挡、反射、多路径传播、卷积混响、实时或预计算声学，以及 CPU/GPU 加速都覆盖得较完整。Bugu 不应照搬完整复杂度，但可以借鉴其“物理结果可被设计师再塑形”的原则。

Microsoft Project Acoustics 和 Project Triton 的思想仍有参考价值：离线波动声学烘焙，运行时查询 occlusion、portaling、reverb 参数。但它的 GitHub 仓库已于 2024-07-01 归档，不能作为未来长期依赖，只能作为论文和架构参考。

## 2. 目标与非目标

### 2.1 目标

P0/P1 必须达成：

- 稳定播放 one-shot、loop、streaming music；
- 支持 2D/3D 声源、距离衰减、cone directivity、Doppler；
- 自研 mixer、Voice manager、Bus routing、基础 DSP；
- 数据驱动事件系统；
- Bank 编译与运行时加载；
- 基础 profile：active voices、virtual voices、CPU time、dropout、stream underrun。

P2/P3 继续达成：

- HRTF binaural rendering；
- room、portal、reverb zone；
- occlusion、air absorption、diffraction 近似；
- GPU/CPU 复合声学传播模拟；
- 声学 probe、反射、混响参数查询；
- 编辑器预览、热更新、可视化 profile。

### 2.2 非目标

至少在前两个阶段不做：

- 完整替代 Wwise/FMOD 的 authoring suite；
- GPU sample-level mixer；
- 真实波动方程实时求解；
- 个性化 HRTF 生成；
- 复杂音乐作曲或 DAW 时间线；
- 跨网络协作编辑。

## 3. 分层架构

建议把 docs/research/1.md 的 L0-L9 思路保留，但边界微调如下：

| 层 | 名称 | 职责 |
|---|---|---|
| L9 | Designer/Game API | Event、State、Switch、RTPC、Script Binding、Editor Preview |
| L8 | Asset & Runtime Resource | AudioBank、Stream Cache、Decode Job、Hot Reload、Ref Counting |
| L7 | Spatial & Acoustic | Attenuation、Cone、HRTF、Ambisonics、Occlusion、Portal、Probe、Reverb Send |
| L6 | Effect Graph | EQ、Compressor、Limiter、Delay、Reverb、Convolution、Sidechain |
| L5 | Mixer Core | Voice、Bus DAG、Send/Return、Automation、Virtualization、Metering |
| L4 | DSP Primitives | Resampler、Biquad、FIR/IIR、FFT、Envelope、Gain Ramp、SIMD kernels |
| L3 | Decode & Format | PCM、ADPCM、Vorbis、Opus、FLAC、seek table、sample format conversion |
| L2 | Audio Device Backend Interface | callback/pull model、device reopen、latency query、channel layout |
| L1 | Platform Backend | WASAPI、CoreAudio、AAudio、PipeWire、ALSA、SDL3、miniaudio |
| L0 | OS & Runtime Foundation | thread、timer、atomic、allocator、file、job system、logger、profiler |

核心调整：

- 将“解码与格式”单独放到 L3，避免 SDL_sound 这类库污染设备层概念。
- 将“空间音频”和“声学传播”合并到 L7，因为它们共同输出 per-voice rendering parameters。
- 光锥声学传播不单独成为一层，而是 L7 的一个复合声学 solver 子系统，依赖 acoustic scene、voxel/probe、动态几何和可选 GPU infrastructure，但不能反向支配 mixer。

## 4. 底层后端设计

### 4.1 Backend 抽象

后端接口需要表达这些信息：

- sample rate，默认 48000；
- period frames，默认 256，后续支持 128；
- periods，默认 2 或 3；
- channels 和 channel layout；
- sample format，内部优先 float32；
- exclusive 或 low latency 的 best effort；
- 设备枚举、热插拔、重开、延迟查询。

音频输出建议采用 backend callback 驱动。callback 里只能调用 mixer render，不允许执行解码、资产加载、日志格式化或等待 GPU。

如果某后端 callback frame count 不稳定，mixer 内部仍保持固定 quantum，例如 128 或 256 frames，并用中间 FIFO 适配。

### 4.2 后端路线图

| 阶段 | 后端 | 用途 |
|---|---|---|
| P0 | miniaudio | 快速打通设备输出、跨平台 smoke test |
| P1 | SDL3 Audio | 对照 backend；用于工具、editor preview 或 fallback |
| P2 | WASAPI + CoreAudio + AAudio | 主力平台低延迟、自恢复、设备枚举 |
| P3 | PipeWire/ALSA + WebAudio | Linux/Web 支持 |
| P4 | Console backend | 主机专用音频和空间音频接口 |

## 5. Mixer Core

### 5.1 Quantum 与内部格式

内部格式：

- sample rate：48 kHz；
- sample format：float32；
- mix quantum：128 frames 起步，低风险可用 256 frames；
- channel：Voice 输入以 mono 为主；Bus 可以是 mono、stereo、ambisonic、multichannel；
- 参数变化必须做 sample ramp 或 block ramp，避免 zipper noise。

128 frames @ 48 kHz 约 2.67 ms；256 frames 约 5.33 ms。P0 选 256 更稳，P2 再允许低延迟配置 128。

### 5.2 Voice 生命周期

状态机：

- Free
- Requested：游戏线程提交命令，音频线程认领
- Starting：分配 voice slot，拉取或预热 decoder buffer
- Real：参与 DSP 与 mix
- Virtual：只推进时间，不产生 sample
- Releasing：fade out 或 envelope release
- Stolen：被抢占，之后进入 Releasing 或 Free
- Paused

Voice 拆分为三类数据：

- hot：state、gain、pitch、sample cursor、bus id、flags；
- warm：attenuation、spatial params、send levels、automation state；
- cold：asset id、debug name、authoring metadata。

hot 数据使用 SoA 或 hot/cold split，便于 SIMD 和 cache locality。

### 5.3 Virtual Voice 与 Stealing

每个逻辑 voice 都保留 audibility_score：

audibility = authored_priority_weight * peak_or_loudness_weight * current_gain * distance_gain * focus_gain * occlusion_gain * bus_gain

Real voice 预算不足时：

1. 保护类声音不偷：UI、剧情关键语音、当前武器反馈等。
2. 按 priority bucket 过滤。
3. 按 audibility score 淘汰。
4. 同分时淘汰离 listener 更远、剩余时长更短或重复度更高的声音。

Virtual voice 不执行 DSP，但必须推进 sample cursor、loop/stop 条件、fade/automation 时间，以及 event callback 的逻辑时间。

### 5.4 Bus DAG

推荐基础拓扑：

- Voice -> Actor/Category Bus -> SFX、Dialogue、Music、Ambience -> Master
- Voice/Bus -> Reverb Return
- Voice/Bus -> Delay Return
- Dialogue -> Sidechain Detector -> Music Ducking

Bus 图必须在编辑或加载阶段拓扑排序，音频线程只遍历预编译的 flat node list。

每个 Bus 需要：

- volume、pan、mute、solo；
- meter：peak、RMS、clipping count；
- effect chain；
- pre/post fader send；
- output channel layout。

## 6. DSP 与效果器

P0 必备：

- gain + ramp；
- linear/interpolating resampler；
- one-pole low-pass/high-pass；
- biquad；
- envelope；
- equal-power pan；
- simple limiter。

P1/P2 扩展：

- high-quality resampler；
- compressor/ducking；
- delay/echo；
- algorithmic reverb；
- FIR convolution；
- FFT/partitioned convolution；
- HRTF direct convolution 或 partitioned convolution。

效果器接口原则：

- prepare、reset、process、set_param_block 四类操作；
- 参数更新进入音频线程前要转成 block-local command buffer；
- effect 不得持有会在其他线程突变的指针；
- effect 内部状态全部预分配。

## 7. 资产与 Bank 管线

### 7.1 源资产到运行时资产

流程：

1. source wav/flac/ogg import；
2. normalize metadata；
3. loudness/peak scan；
4. trim/silence detect；
5. loop validation；
6. resample to platform target；
7. encode/compress；
8. seek table / prefetch chunk；
9. pack into AudioBank。

资产编译器生成：

- peak、RMS、近似 LUFS loudness；
- duration、loop point、zero-crossing 修正；
- recommended preload frames；
- seek table；
- waveform preview；
- per-platform codec variant；
- hash 与依赖图。

### 7.2 编码策略

| 类型 | 推荐格式 | 加载策略 |
|---|---|---|
| UI/枪声/短反馈 | PCM16、PCM float 或 ADPCM | 全量预载 |
| Foley/脚步/材质变化 | ADPCM 或 Vorbis/Opus | 小块预取 + streaming |
| Dialogue | Opus/Vorbis | streaming，按句子预取 |
| Music | Vorbis/Opus | streaming，较大环形缓冲 |
| Ambience loop | Vorbis/Opus/ADPCM | streaming 或常驻，视长度 |
| HRTF/IR | float、half、quantized FIR | Bank 常驻或按场景加载 |

是否引入 Opus 要单独做 license、build、seek、latency 验证。SDL_sound 的内置格式支持不等于完整生产 codec 策略；资产管线可以直接接 libopus、libvorbis、dr_flac、dr_mp3 等。

### 7.3 Bank 文件逻辑结构

AudioBank 建议包含：

- Header；
- StringTable；
- SoundTable；
- EventTable；
- BusTable；
- EffectPresetTable；
- AttenuationProfileTable；
- StreamChunkTable；
- SeekTable；
- BlobData。

运行时原则：

- Bank metadata mmap 或一次性加载；
- 小音效 data 可常驻；
- streaming chunk 使用 I/O job 读入 lock-free/free-list buffer；
- 热更新以新 Bank 原子替换，旧 Bank 延迟释放直到无 voice 引用。

## 8. 高层事件系统

游戏逻辑调用的是事件，而不是声音文件。一次 weapon.rifle.fire 事件可能解析为：

- 播放多个随机变体；
- 根据 surface switch 选择脚步材质；
- 根据 state 选择室内或室外尾音；
- 设置 pitch/volume randomization；
- 触发 sidechain；
- 启动或停止 loop；
- 设置 RTPC 曲线。

参数模型：

- State：离散全局状态，例如 combat/explore、indoor/outdoor；
- Switch：离散对象状态，例如 surface=wood/metal/water；
- RTPC：连续参数，例如 speed、rpm、health、wetness；
- Trigger：瞬时事件，例如 play、stop、hit、land。

参数曲线必须在 Bank 编译期烘焙成运行时友好的 piecewise linear 或小 LUT。

## 9. 空间音频与声学

### 9.1 Attenuation Profile

一个空间化声音不应只有 volume over distance，而应使用统一 profile：

- distance_volume_curve；
- distance_lpf_curve；
- distance_hpf_curve；
- reverb_send_curve；
- spread_curve；
- priority_curve；
- cone_directivity；
- listener_focus；
- occlusion_response。

支持 Unreal/Wwise 风格的 sphere、capsule、box、cone attenuation shape；linear、log、inverse、custom curve；air absorption；listener focus；reverb send by distance；occlusion low-pass + gain reduction。

### 9.2 Cone Directivity

声源方向性使用内外锥：

1. 计算 theta = angle(source_forward, listener_position - source_position)。
2. theta 小于 inner_angle 时不衰减。
3. theta 大于 outer_angle 时使用 outer_gain 和 outer_lpf。
4. 中间区域使用 smoothstep 插值。

cone 影响 dry signal 和 low-pass；是否影响 reverb send 可由 profile 决定。默认不影响 early/late reverb，以避免方向性声音在背向 listener 时空间尾音也突然消失。

### 9.3 Occlusion、Obstruction、Diffraction

P1 近似：

- 单 ray 或少量 rays；
- 命中后按材质给 dry gain attenuation 与 low-pass；
- 时间平滑，避免遮挡边界抖动。

P2：

- 多点采样：source bounds、listener head、portal points；
- partial occlusion；
- obstruction 与 occlusion 分离；
- 简化 diffraction：当 direct path blocked 时查询 portal/edge path，给一个延迟、低通和增益。

P3：

- room/portal graph；
- probe-based reverb 和 early reflection；
- GPU 批量传播查询。

### 9.4 HRTF 与 Ambisonics

P2 引入 HRTF：

- 输入优先 mono point source；
- 支持 SOFA 或自定义烘焙 HRIR；
- HRIR 插值在控制线程或 worker 上完成，音频线程消费已准备好的 FIR；
- 近场、头部跟踪和个性化 HRTF 放到后续阶段。

Ambisonics：

- 支持 FOA 作为 ambience 和 VR/AR 基线；
- 后续支持 HOA，按内容需求扩展；
- Ambisonics rotation 放在音频线程，但矩阵参数由空间系统更新。

## 10. 基于光锥 GPU 的复合声学传播系统

这里的“光锥 GPU sounds”不应理解为 clustered-lighting 式的声源筛选系统，而应理解为 **几何声学 + 材质声学 + 动态场景声学** 的实时近似模拟。

目标问题不是“哪些声音该播放”，而是：

- 声源和 listener 之间有墙时，直达声如何被遮挡和低通？
- 墙上有洞、门、窗时，声音如何从开口泄露出来？
- 墙体移动、门开关、结构破坏时，传播路径如何实时变化？
- 山洞、走廊、房间、开阔地分别产生怎样的早期反射、尾混响和方向感？
- 厚墙、薄墙、玻璃、木板、金属、岩石对穿透声的能量和频谱如何改变？
- 雨声、雷声、机器轰鸣等环境声，应该从洞口、窗口、洞穴出口还是天空方向传来？

因此它的本质是一个 **Acoustic Propagation Solver**。声源 culling、real/virtual voice 选择只是它的副产物。

### 10.1 物理分解：游戏里需要模拟的声学成分

实时游戏不可能完整解波动方程，所以应使用分层近似：

| 成分 | 含义 | 主要听感 | 运行时输出 |
|---|---|---|---|
| Direct sound | 声源到 listener 的直线路径 | 定位、清晰度、瞬态 | direct_gain、delay、azimuth/elevation |
| Occlusion | 直达路径被遮挡 | 闷、远、不清楚 | gain reduction、low-pass、high-pass |
| Transmission | 声音穿过墙体/材质 | 隔墙声、低频穿透 | transmitted_gain、frequency absorption |
| Diffraction | 声音绕过边缘、门缝、洞口 | 转角可闻、门后可闻 | diffracted_gain、path_delay、bend_direction |
| Early reflections | 1-4 次短路径反射 | 房间大小、墙面方向、 slap echo | reflection taps、directions、delays |
| Late reverb | 大量高阶反射的统计尾音 | 山洞、室内、空旷感 | reverb_send、RT60、density、coloration |
| Outdoor leakage | 从开口进入的外部环境声 | 雨从窗外来、洞口外风声 | portal_direction、ambient_gain |
| Dynamic geometry response | 门、墙、洞、可破坏物实时变化 | 声场随世界变化 | incremental update、temporal smoothing |

### 10.2 为什么叫“光锥”

渲染里的光线追踪计算的是光能传播；这里追踪的是声能传播。可以把每个声源或 listener 周围的采样射线束看成 **sound cone / acoustic cone**：

- 从 listener 向外发射：适合回答“我现在从哪些方向收到什么声学能量”。
- 从 source 向外发射：适合回答“这个声源的能量如何散播到世界里”，也适合做听障辅助的声音可视化。
- 从 portal/opening 向两侧发射：适合回答“门、窗、洞口把两个空间如何声学耦合”。

这和 Back2Gaming 文章提到的 Vericidium 插件思路接近：用不同类型的 ray 采样直达、反射、穿透和环境方向，并且把场景转成 voxel grid 来降低几何求交成本。文章里的实现是 CPU 后台线程，不依赖 RTX/DXR；Bugu 可以把同一模型设计为 CPU/GPU 双后端：低端硬件走 CPU voxel，高端硬件走 GPU ray query 或 compute。

### 10.3 声学场景表示

传播模拟不应直接拿渲染三角网格硬算。需要一份专门的 acoustic scene：

| 数据 | 用途 |
|---|---|
| Acoustic voxel grid / SDF | 快速判断射线在空气、固体、洞口、薄墙中的路径长度 |
| Acoustic material table | 每种材质的吸收、反射、透射、散射、频率响应 |
| Portal/opening graph | 门、窗、洞、走廊口、山洞出口等声学耦合点 |
| Room/zone graph | 室内、室外、山洞、走廊、半开放空间的拓扑关系 |
| Dynamic obstacle layer | 门、移动墙、载具、可破坏物、临时遮挡 |
| Probe field | 离线或后台更新的 late reverb、RT60、反射密度、空间颜色 |

材质参数至少按频段表达，不要只用一个 scalar：

| 参数 | 低频 | 中频 | 高频 |
|---|---:|---:|---:|
| absorption | 吸收系数 | 吸收系数 | 吸收系数 |
| reflection | 反射系数 | 反射系数 | 反射系数 |
| transmission | 穿透系数 | 穿透系数 | 穿透系数 |
| scattering | 散射系数 | 散射系数 | 散射系数 |

游戏运行时可先用 3-band 或 4-band；最终映射到 mixer 时再转换成 gain、low-pass、high-pass、EQ color、reverb send。

### 10.4 射线类型

参考 Vericidium 文章中的四类 ray，可以在 Bugu 中扩展成以下 ray families：

| Ray family | 发射方向 | 解决的问题 | 输出 |
|---|---|---|---|
| Direct rays | listener -> source 或 source -> listener | 有没有无遮挡直达路径 | clarity、direct_gain、direct_delay |
| Penetration rays | 穿过 solid voxel 或材质层 | 隔墙、厚墙、多层墙的闷化程度 | material_depth、transmission_gain、filter |
| Reflection rays | listener/source 半球采样，多次 bounce | 房间、走廊、山洞的早期反射 | reflection_taps、echo_delay、echo_gain |
| Diffraction rays | portal/edge/opening 采样 | 墙后、转角、洞口传播 | diffracted_paths、bend_direction |
| Escape rays | listener -> 外部空间 | 室内/室外、洞内/洞外判定 | openness、outdoor_leakage、sky/exit direction |
| Ambient direction rays | 环境声场方向平均 | 雨、风、雷、城市噪声从哪里来 | ambient_direction、ambient_occlusion |
| Probe rays | 低频率后台采样 | late reverb 统计 | RT60、density、decay_color |

注意：direct rays 决定“清晰度”，penetration rays 决定“隔墙听起来多闷”，reflection/diffraction/escape rays 决定“环境空间感”。

### 10.5 声能传播模型

每条路径都应累积一个路径状态：

- distance：空气传播距离；
- delay：distance / speed_of_sound；
- air_absorption：随距离和频率衰减；
- material_stack：穿过哪些材质、厚度多少；
- bounce_count：反射次数；
- reflection_loss：每次反射的频段损失；
- diffraction_loss：绕射损失；
- portal_loss：开口大小、朝向和可见比例导致的损失；
- direction：到达 listener 的方向；
- phase/random_seed：用于 decorrelation，避免 comb filtering。

最终把多条路径聚合为一个 AcousticResponse：

- direct_gain；
- direct_filter；
- direct_delay；
- transmission_gain；
- transmission_filter；
- diffraction_gain；
- diffraction_direction；
- early_reflection_taps；
- late_reverb_send；
- reverb_preset 或 RT60/density/color；
- ambient_direction；
- openness；
- confidence。

这里的 confidence 很重要：ray 数不足、GPU 超时、voxel 分辨率太低时，系统应该让结果更平滑、更保守，而不是突然让声音跳变。

### 10.6 墙、洞、门、移动物体的处理

#### 无墙

Direct rays 命中 source，direct_gain 接近距离衰减结果；early reflection 和 late reverb 由周围环境决定。开阔地 reflection 少、RT60 短或稀薄。

#### 完整厚墙

Direct rays 被阻挡。系统计算 penetration path：

- 在 solid voxel 内走过的长度越长，transmission 越低；
- 高频比低频衰减更强；
- 多层材质按频段累乘；
- direct component 变为 transmitted component，定位更模糊，HRTF 权重降低。

#### 墙上有洞/窗/门缝

Direct rays 可能无法命中 source，但 diffraction/portal rays 可以找到开口：

- 声音从洞口方向到达 listener，而不是从 source 原始方向“穿墙”过来；
- 洞口越大、越正对 source/listener，portal_loss 越小；
- 洞口会形成 outdoor leakage 或 room-to-room leakage；
- 对雨声、风声等环境声，洞口方向应成为 ambient_direction 的重要来源。

#### 门开关或墙移动

动态几何进入 dynamic obstacle layer：

- 小范围变化只更新局部 voxel bricks 或 dynamic BVH；
- acoustic response 做时间平滑，避免门打开瞬间声音硬跳；
- 允许显式 gameplay hint，例如 door_open_fraction 直接影响 portal area；
- 如果更新延迟，先使用上一帧响应并提高 confidence smoothing。

#### 山洞

山洞不是简单“室内 reverb”：

- 几何长、窄、粗糙，early reflection 方向性强；
- late reverb 衰减可能长，但高频因岩石/空气吸收而更暗；
- 洞口产生明显的 escape direction，外部声音从洞口泄露；
- 洞内声源经过多次反射后定位变模糊，direct-to-reverb ratio 降低。

#### 开阔地

开阔地的 escape rays 大量逃逸：

- openness 高；
- early reflection 少；
- late reverb 很弱；
- 远处山体/建筑可提供稀疏长延迟反射；
- 风、雨、雷等环境声方向更接近天空/天气系统，而不是房间 portal。

### 10.7 GPU/CPU 双后端

Back2Gaming 文章中的插件强调 CPU 后台线程和 voxel grid，优点是兼容性高，不依赖专有 GPU。Bugu 可以设计成双后端：

| 后端 | 适用 | 优点 | 缺点 |
|---|---|---|---|
| CPU voxel tracing | P1/P2、低端硬件、调试 | 稳定、易调试、不占 GPU | 大量声源或高 ray count 时成本高 |
| GPU compute voxel tracing | P3 | 与现有 GPU pipeline 结合，适合大批量 ray | 需要异步 readback 和调度控制 |
| GPU hardware ray query | P4 | 可利用 TLAS/BLAS 和硬件 RT | 平台差异大，移动/低端回退复杂 |
| Offline/probe bake | 静态大场景、山洞、建筑 | late reverb 质量高、运行时便宜 | 动态几何只能增量修正 |

建议架构：同一个 AcousticPropagation API，下挂 CPU 和 GPU backend。算法先在 CPU voxel 上做正确性，GPU 只做加速，不改变上层语义。

### 10.8 运行时管线

推荐管线：

1. Scene extraction：从物理/渲染场景抽取 acoustic geometry、material、portal、dynamic obstacle。
2. Voxelization / AS update：更新 acoustic voxel bricks、dynamic BVH 或 TLAS。
3. Ray dispatch：按 listener、重要 sound source、portal、probe 发射不同 ray families。
4. Path accumulation：累积 direct、transmission、reflection、diffraction、escape 能量。
5. Response solve：把路径云聚合成 AcousticResponse。
6. Temporal denoise：跨帧平滑，抑制 ray sampling 噪声。
7. Audio parameter mapping：映射到 gain、filter、delay taps、reverb send、HRTF direction。
8. Mixer consume：音频线程消费不可变 AcousticSnapshot。

### 10.9 Audio 线程消费模型

传播模拟可以慢一帧或几帧，但音频线程不能等它：

1. Frame N：CPU/GPU propagation backend 生成 AcousticResponseBuffer[N]。
2. Frame N+1：audio control thread 读取并转换成 AcousticSnapshot[N]。
3. Frame N+1 或 N+2：audio render thread 消费不可变 snapshot。

关键点：

- 至少双缓冲，推荐三缓冲；
- 如果 propagation 结果没回来，沿用上一份 snapshot；
- 如果连续超时，回退到 distance + simple occlusion；
- audio thread 永远不 wait fence；
- gain/filter/reverb send/delay taps 做 20-100 ms 平滑；
- 对门开关、爆炸破墙等剧烈变化，可允许设计师标注 fast transition。

### 10.10 为什么仍然不先做 GPU Mixer

这个系统模拟的是“声音如何到达耳朵前”，不是“最终 PCM 如何混出来”。GPU mixer 的问题仍然存在：

- 音频 callback 需要严格周期性，GPU 调度抖动不可控；
- 渲染 queue 压力会直接制造音频 dropout；
- 小 buffer 下 CPU/GPU 往返延迟很难接受；
- DSP 很多是 stateful、短 buffer、强实时约束；
- 平台 backend 行为差异大。

因此 GPU/CPU propagation 输出 AcousticResponse，mixer 仍在 CPU audio thread 中稳定渲染。远期可以实验 GPU convolution 或大量 reflection tap 预处理，但不作为主路径。

### 10.11 复合声学 MVP

MVP 不应从 top-k culling 开始，而应从三个能明显听出差异的传播 case 开始：

1. 无墙 vs 厚墙：direct sound 与 transmitted muffled sound 的差异。
2. 墙有洞/门打开：声音从开口方向泄露，且开口大小改变 gain/filter。
3. 山洞 vs 开阔地：early reflection、late reverb、openness、ambient direction 差异。

技术 MVP：

- CPU voxel grid；
- direct rays；
- penetration depth；
- escape/openness rays；
- single-bounce reflection rays；
- portal/opening 标记；
- 3-band material absorption/transmission；
- 输出 AcousticResponse；
- 映射到 gain、low-pass、simple delay taps、reverb send；
- editor debug view 显示 rays、voxel、portal、response 曲线。

P3 再做 GPU compute 版本；P4 再考虑硬件 ray query 和更复杂的多 bounce path tracing。

## 11. 线程模型

推荐线程：

- Game Thread：post events、set params、attach emitters。
- Audio Control Thread：resolve events、update voices、consume GPU spatial snapshot。
- Audio Render Thread / Device Callback：render mixer quantum，no locks、no alloc、no I/O、no GPU wait。
- Worker Threads：decode、stream I/O、bank load、HRTF prep、reverb IR prep。
- Render/GPU Thread：build sound emitter buffer、dispatch GPU sounds passes。

线程间通信：

- Game -> Audio Control：MPSC command queue；
- Audio Control -> Audio Render：double-buffer immutable render state；
- Worker -> Audio Control：job completion queue；
- GPU -> Audio Control：fenced readback 或 persistent mapped staging，但不能进入 audio render thread。

## 12. 实时安全规则

音频 render thread 禁止：

- malloc、free、new、delete；
- mutex、condition variable、blocking wait；
- 文件 I/O；
- GPU fence wait；
- printf 或 log format；
- 可能 page fault 的懒加载；
- 调用未知第三方代码；
- 修改复杂共享结构。

允许：

- 读取不可变 snapshot；
- 无锁 SPSC pop；
- 固定容量 pool；
- bounded loop；
- SIMD DSP；
- 原子读取少量 telemetry counter。

## 13. 编辑器与调试

### 13.1 必须有的可视化

- 当前 active、virtual、stolen voices；
- 每个 voice 的 audibility score 分解；
- attenuation shape、cone、focus 可视化；
- occlusion ray、portal path；
- Bus meter；
- stream buffer 水位；
- dropout、underrun 标记；
- 声学传播 debug：direct、penetration、reflection、diffraction、escape rays 与 CPU/GPU backend 对比。

### 13.2 Live Tuning

支持热更新：

- Event 配置；
- Attenuation profile；
- Bus volume/send；
- effect preset；
- random container；
- state/switch/RTPC curves。

热更新策略：生成新 immutable blob，音频控制线程在安全点切换，旧 blob 引用计数归零后释放。

## 14. 性能预算

| 项 | P0 | P2 |
|---|---:|---:|
| mix quantum | 256 frames | 128/256 frames |
| real voices | 64 | 128 |
| virtual voices | 512 | 2048+ |
| CPU mixer time | 小于 1.0 ms | 小于 1.5 ms |
| streaming underrun | 0 | 0 |
| audio memory | 小于 64 MB | 分平台预算 |
| Acoustic propagation | CPU simple occlusion | voxel/probe/ray response，CPU/GPU 双后端 |
| GPU readback latency | 无 | 可容忍 1-2 frames |

重要指标不是平均耗时，而是 p99、p999 和 dropout 次数。音频引擎宁可略微降低空间声学精度，也不能爆音。

## 15. 里程碑

### P0：能稳定发声

- miniaudio backend；
- fixed quantum mixer；
- one-shot、loop、stream；
- Voice pool；
- simple Bus；
- PCM/WAV 导入；
- basic attenuation；
- profile counters。

完成标准：能跑 30 分钟无 dropout；播放、停止、循环、streaming 不泄漏。

### P1：成为游戏可用音频系统

- Bank 编译；
- Event system；
- Random/Sequence container；
- RTPC、State、Switch；
- Voice virtualization；
- Bus DAG + send/return；
- ADPCM/Vorbis/Opus 至少一种压缩格式；
- cone directivity；
- simple occlusion。

完成标准：能接入一个小 demo 场景，支持脚步、武器、环境、音乐、UI。

### P2：空间声学

- HRTF；
- air absorption；
- listener focus；
- room/reverb zone；
- portal approximation；
- convolution 或 algorithmic reverb；
- native WASAPI/CoreAudio/AAudio backend。

完成标准：室内/室外、门后、转角、上下方位能听出稳定差异。

### P3：GPU/CPU 复合声学传播

- Acoustic scene extraction；
- voxel grid 或 SDF acoustic representation；
- direct、penetration、reflection、diffraction、escape ray families；
- 3-band material absorption/transmission；
- portal/opening graph；
- probe/reverb query；
- AcousticResponse snapshot；
- CPU backend 与 GPU compute backend；
- editor ray/path/response visualization。

完成标准：无墙、厚墙、墙洞/门窗、移动遮挡、山洞、开阔地这些 case 能产生稳定且可解释的听感差异，音频无 GPU stall。

## 16. 风险与对策

| 风险 | 后果 | 对策 |
|---|---|---|
| 过早自研所有平台后端 | 卡在设备细节，mixer 迟迟不可用 | P0 用 miniaudio，后端接口先固定 |
| 把 SDL_sound 当完整音频系统 | 后续推倒重来 | 明确 SDL_sound 只做 decoder adapter |
| GPU 结果阻塞音频线程 | dropout/爆音 | snapshot 异步消费，永不 wait |
| 空间声学过度物理化 | 设计师不可控，成本失控 | 物理结果作为起点，所有参数可艺术化曲线调整 |
| Bank 格式过早复杂 | 工具链拖慢 | P0 简单 manifest + blob，P1 再稳定二进制格式 |
| Voice stealing 生硬 | 重要声音被吞 | priority bucket、保护类、fade out、debug visualization |
| Streaming underrun | 音乐/语音断裂 | chunk 水位 profile，预读策略，I/O job 优先级 |

## 17. 初始 ADR

### ADR-001：Bugu 自研 mixer core

决定：自研 mixer、Voice manager、Bus graph、Event runtime。

理由：这是引擎行为和性能的核心，不应被 SDL_sound、SDL3、miniaudio 的高层封装限制。

### ADR-002：SDL_sound 仅作为可选 decoder

决定：SDL_sound 不进入 L1/L2 backend 设计，只作为 L3 decoder adapter 候选。

理由：SDL_sound 定位是解码库，不是混音、设备、空间音频系统。

### ADR-003：P0 使用 miniaudio backend

决定：先用 miniaudio device callback 让自研 mixer 发声。

理由：跨平台 backend 覆盖广、接入成本低，可快速验证核心架构。

### ADR-004：光锥 sounds 是声学传播 solver，不是声源筛选器

决定：光锥 sounds 第一阶段模拟 direct、transmission、reflection、diffraction、escape/openness 等传播响应，输出 AcousticResponse，不以 top-k candidate culling 为核心目标。

理由：目标是解决墙、洞、门、移动几何、山洞、开阔地等复合声学传播问题；声源筛选只是传播结果的副产物。

### ADR-004b：传播 solver 输出 AcousticResponse，不直接输出 PCM

决定：CPU/GPU propagation backend 输出 AcousticResponse，由 CPU audio mixer 继续生成最终 PCM。

理由：音频线程实时性比 GPU 加速收益更重要；GPU sample mixer 可作为远期实验，但不进入主路径。

### ADR-005：统一 Attenuation Profile

决定：距离、cone、air absorption、focus、reverb send、priority、occlusion 都归入同一 profile。

理由：设计师调参需要一个可理解的空间声音模型；运行时也可统一计算 audibility。

## 18. 下一步实现任务

建议立刻拆以下任务：

1. 定义 C API：device、engine、event、bank、voice handle。
2. 实现 miniaudio backend + fixed quantum callback adapter。
3. 实现 AudioCommandQueue 与 render snapshot。
4. 实现 64 real voices 的 mono-to-stereo mixer。
5. 实现 WAV/PCM importer 和临时 JSON manifest。
6. 实现 Event -> SoundEntry -> Voice 的最小链路。
7. 实现 distance + cone attenuation。
8. 实现 profile counters 和 dropout 检测。
9. 写一个 demo：100 个循环声源 + listener 移动 + voice virtualization。
10. 在 demo 稳定后，再进入 Bank 二进制格式和复合声学传播 MVP：无墙、厚墙、墙洞/门窗、山洞、开阔地。

## 19. 参考资料

- [SDL_sound GitHub releases](https://github.com/icculus/SDL_sound/releases)：2.x 维护模式，聚焦 SDL_sound 3.x；SDL_sound 是 decoder。
- [SDL_sound project page](https://www.icculus.org/SDL_sound/)：说明其输入文件/内存、输出解码 waveform、支持分块和格式转换的定位。
- [SDL3 Audio wiki](https://wiki.libsdl.org/SDL3/CategoryAudio)：SDL3 Audio 以 SDL_AudioStream 为核心。
- [miniaudio documentation](https://miniaud.io/docs/manual/index.html)：backend 覆盖与设备抽象。
- [miniaudio GitHub](https://github.com/mackron/miniaudio)：支持 WASAPI/Core Audio/ALSA/PulseAudio/JACK/AAudio/OpenSL ES/WebAudio/Custom 等 backend。
- [FMOD Virtual Voices](https://fmod.com/resources/documentation-api?page=white-papers-virtual-voices.html&version=2.1)：virtual voice、audibility、priority、real/virtual transition 参考。
- [Steam Audio documentation](https://partner.steamgames.com/doc/features/steam_audio)：HRTF、Ambisonics、SOFA、occlusion、reflection、多路径、convolution reverb、CPU/GPU 加速。
- [OpenAL Soft](https://openal-soft.org/)：3D audio、distance attenuation、Doppler、directional emitters、EFX、HRTF、B-Format 等参考。
- [Unreal Engine Sound Attenuation](https://dev.epicgames.com/documentation/unreal-engine/sound-attenuation-in-unreal-engine)：attenuation shape、cone、air absorption、focus、reverb send、occlusion 等设计参考。
- [Wwise cone attenuation documentation](https://www.audiokinetic.com/fr/public-library/2025.1.4_9062/?id=simulating_directivity_using_cone_shaped_boundaries&source=Help)：inner/outer cone、volume attenuation、low-pass directivity。
- [Microsoft Project Acoustics GitHub](https://github.com/microsoft/ProjectAcoustics)：仓库已于 2024-07-01 归档，只建议作为声学烘焙/运行时查询思想参考。
- [Back2Gaming - Implementing Ray-Traced Audio in Games](https://www.back2gaming.com/features/implementing-ray-traced-audio-in-games-a-technical-preview-of-vericidiums-plugin/)：Vericidium 插件技术预览，介绍基于 voxel/ray 的直达、反射、穿透、环境方向和动态几何声学处理思路。
