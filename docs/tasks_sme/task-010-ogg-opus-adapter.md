# TASK-010：交付 Ogg Opus、确定性媒体导入与质量/seek 编译产物

## 元数据
- 状态：TODO
- Owner：`UNASSIGNED`
- Reviewer：`UNASSIGNED`
- 实施角色：Codec/Third-party Build
- 评审角色：Codec、许可证、跨平台构建
- 工作量等级：`XL`
- 证据路径：`docs/validation/sme/TASK-010/evidence.md`（脱敏摘要）、`zig-out/sme-validation/TASK-010/`（原始产物）
- 执行波次：3
- 硬依赖：TASK-003
- 协作关系：TASK-003 拥有 media report/Seek/Chunk schema；TASK-011 消费 decoder/index/quality/storage 产物；TASK-017 CLI 复用本任务媒体 compiler pass；构建文件由 TASK-001 注册 seam 接入，按 setup 的文件所有者合并
- 预计改动范围：`.gitmodules`、`third_party/ogg`、`third_party/opus`（新增 submodule）、`third_party_adapters/opus/`（新增）、`tools/sme_compiler/import_audio.zig`、`audio_quality.zig`、`stream_index.zig`（新增）、`build_support/sme_steps.zig`、`tests/sme/opus_adapter_test.zig`、`audio_import_test.zig`、`audio_quality_test.zig`、`stream_index_test.zig`（新增）

## 目标
通过官方 Xiph submodule 提供隔离的 Ogg Opus decode/metadata/seek 接口；交付 runtime 之前必需的真实媒体 compiler pass，完成 source sample-rate conversion、loop/DC 连续性、true-peak/RMS/integrated-loudness 扫描及 Chunk/Seek 表生成。TASK-017 只提供 CLI 编排，不能成为这些产物的隐藏晚期前置。

## 上下文
当前 miniaudio 构建禁用 decoding，bank 只有 PCM。v1 已冻结 Resident PCM + Ogg Opus，第三方必须 submodule，第三方类型不得泄漏。

## 前置条件
- MusicBank Codec/Seek/Chunk tables。
- 可访问官方 `https://github.com/xiph/ogg.git` 与 `https://github.com/xiph/opus.git`。

## 实施范围
### 必须完成
- 添加并固定通过 Windows/Linux 构建验证的 submodule commits。
- Zig adapter + 最小 C shim（仅第三方绑定）实现 header parse、decode、reset、seek。
- pre-skip/end trim/channel mapping metadata。
- 本任务是 sample-accurate `SeekTable` 和 `ChunkTable` 唯一 producer：扫描真实 encoded stream，生成可审查 index，并给 TASK-011 提供 seek/read/decode/trim 所需全部字段。
- 确定性 source→48 kHz float PCM 导入，保留全部 channel/layout，源 loop/cue/anchor 统一 remap，显式转换报告。
- 非实时音频质量扫描：sample peak、true peak、RMS、integrated LUFS、DC 和 loop seam；独立 oracle 与门槛失败测试。
- 根据 TASK-003 的 decoded resident size gate 生成 resident blob 或真正 streaming descriptor，不能因 CLI 尚未完成推迟本 pass。
- corrupted/truncated/unsupported mapping 错误。
- license/commit/build flags 记录。

### 明确不包含
- streaming ring/prefetch。
- 其他 codec。
- 用外部 ffmpeg/runtime process 解码。

## 设计与执行细节
1. adapter 对外只暴露 Bugu enums/slices/errors。
2. decoder allocation 在 worker/control prepare；render 不调用。
3. seek 结果以 decoded PCM frame 表示，补偿 pre-skip。
4. test fixture 固定在 `tests/fixtures/sme/opus/`，由受控小文件和 PCM oracle 组成；每个文件在同目录 `LICENSES.toml` 记录来源 URL/生成命令、license、copyright、content SHA-256。
5. `build.zig` 通过 `build_support/sme_steps.zig` 的 `addSmeSteps`/codec helper 接入，不破坏 miniaudio flags。
6. `third_party_adapters/opus/PINS.toml` 记录 ogg/opus URL、exact commit、build flags、license file 路径与验证 target；`.gitmodules` URL、gitlink exact commit 和实际 submodule HEAD 必须与其各自对应字段一致。
7. Import pass 接受声明 sample-rate/layout 的 WAV PCM 和 Opus，统一到 48,000 Hz。Opus 原始 input-rate hint 不参与重采样比例，先 decode 到其 48 kHz audible PCM 时间域；48 kHz PCM bypass 不增减 frame；其他合法源 rate 使用固定版本的带限 SRC，冻结 filter coefficients/taps、phase precision、边界延拓、group-delay compensation 和舍入。保留跨 stem 一致的有理数 `48000/source_rate` 时间映射，source cue/loop/anchor 用累计原点 nearest ties-to-even 映射，不逐片段累积。输出 length=`round_ties_even(source_frames*48000/source_rate)`；补偿滤波延迟后重跑 alignment/loop 校验，非 finite、未知 rate/layout、overflow 或 remap 后空 loop 均失败。
8. Quality pass 在 SRC 后 PCM 以及有损编码再解码后的可听 PCM 上运行，分别保留报告。Integrated loudness 与 true peak 使用固定版 [ITU-R BS.1770-5](https://www.itu.int/rec/R-REC-BS.1770-5-202311-I/) 的对应算法，RMS 则为明确窗口内 `sqrt(mean(x²))`，三者不能混用。记录所有 channel weights、滤波/oversampling 配置、gate/window 和 silence 行为；实现主体为 Zig，不调用外部播放器/ffmpeg 冒充生产路径。
9. `QualityPolicyV1` 的每项测量含单位、window、阈值、severity；本任务在媒体 pass 实施前提交并 review `tests/fixtures/sme/audio-quality/quality-policy.toml` 和 oracle。固定硬错误：NaN/Inf、PCM |sample|>1、编码后 true peak>0 dBTP、非法 loop；默认 DC 警告阈值 abs(mean)>0.001 FS。Loop 必测 seam sample delta、两侧一阶差分变化、首尾局部 DC 差，窗口默认 256 frames（短 loop 缩至 length/2），阈值在 policy 中显式给出；大音量合法周期信号与真正 step/DC discontinuity 用独立 fixture 区分，不能把自然相邻 sample 差等同 click。Integrated LUFS 默认只报告，无隐式响度归一化；作者声明的 LUFS 范围和 loop/DC error-severity 变为 build gate。所有 warning 必须出现在 report/UI，required gate 缺参数/未扫描则构建失败。
10. Seek producer 对每个 stream 从 header/page/packet 生成稳定排序 index；至少记录 byte/page/packet 位置、48 kHz granule、logical audible frame、recovery/preroll/discard、stream serial/link ID，索引 frame 原点补偿 pre-skip，EOS trim 从最终 granule 验证。Index 默认间距不超过 48,000 audible frames（1 秒），从安全恢复点解码并 discard 到目标，不能仅以 page granule 当精确 sample。Chunk hash 覆盖实际 encoded bytes；跨 page/packet、CRC/sequence gap、overflow 或 index 越界失败；chained Ogg 本版明确拒绝。
11. 原始 PCM reference 用于 SRC 的保真/带宽和 frame 定位测试；Opus seek 的 sample oracle 是同一固定 decoder 连续完整解码后的 PCM，与随机 seek 输出逐 sample 容差比较，不将 lossy decode 对原始 PCM 的逐 sample 相等当要求。

## 接口与数据契约
`OpusStreamInfo`、`Decoder.prepare/decode/seek/reset`；返回实际 frames 和 EOS。新增媒体 pass 输出 `{normalized_audio, quality_report, storage_decision, chunk_table, seek_table}`，全部绑定 source/encoded hash、algorithm versions、target sample-rate/layout 和 policy ID；只有 validate 成功才能提交 MusicBank builder。错误区分 invalid container、unsupported channels、decode failure、seek unavailable、`SampleRateConversionFailed`、`AudioQualityGateFailed`、`InvalidSeekIndex`、`EmergencyMustBeResident`，由 TASK-001 错误映射 seam 注册，不能独立扩散第二套公共错误。

## 文件变更
- submodules/.gitmodules。
- opus adapter/C shim。
- build integration/tests、`tests/fixtures/sme/opus/LICENSES.toml` 与 `third_party_adapters/opus/PINS.toml`。
- 新增 compiler 媒体三个模块及 `tests/fixtures/sme/audio-import/`、`audio-quality/`、`stream-index/`；fixture 均含许可证、source hash、独立 expected values 和生成说明。

## 验证
### 自动化验证
- `zig build test`。
- 新增 `zig build sme-codec-test`：mono/stereo/5.1/7.1、pre-skip、end trim、每 speaker 重排、随机 seek、loop、truncated/corrupt。
- 新增 `zig build sme-import-test`：44.1/48/96 kHz mono/stereo/5.1/7.1 的 length、impulse delay、bandlimited sine/alias rejection、多 stem cue/loop remap、重复输出 hash 和非法 rate；SRC 频带/阻带误差阈值在该子交付冻结的 numeric oracle 内 exact/容差检验。
- 独立 analytic sine/DC/silence、intersample overs、不同 channel weights、已知 LUFS、合法周期 loop/step discontinuity、阈值±epsilon 和 error/warn policy；true-peak 与 LUFS oracle 容差分别不超过 0.1 dB/0.1 LU，RMS 绝对误差≤1e-6，固定文件逐重复报告相同。
- Seek/Chunk producer 重复生成 byte-identical，随机/packet 边界/loop/EOS seek 与连续解码 oracle 对齐；超过 resident gate 的压缩小文件必须生成 streaming descriptor，放大 ring/preload 不能通过此测试。
### 手工验证
- Windows 与 Linux 各构建一次并记录 commit/toolchain。
### 边界与失败场景
- chained Ogg 明确拒绝；unknown mapping family、seek 超界、partial packet 和 container CRC/sequence gap 有独立错误。

## 完成定义
- [ ] 本任务已交付测试/fixture 通过 TASK-001 的稳定注册 seam 加入既有 `zig build test`/PR gate，证据随子交付持续产生，不等待 TASK-021 首次接入 CI。
- [ ] `.gitmodules` URL、gitlink exact commit、实际 HEAD 和 `PINS.toml` 对应字段一致，build flags 可审查且可重复构建。
- [ ] 每个 codec fixture 的来源、license 和 SHA-256 可审计。
- [ ] decoded frame 与 PCM oracle/seek cursor 一致。
- [ ] 无第三方类型进入公共 API。
- [ ] render path 不链接调用 decoder。
- [ ] SRC、loop/DC、true peak、RMS、integrated LUFS、resident forcing 和 seek/chunk generation 都有唯一 producer、明确 policy、独立 oracle 与失败 gate；TASK-011 不再等待 TASK-017 生成实际资产。

## 独立审查的子交付

- `T010-A / CodecBinding`：输入为TASK-003 Codec/Seek schema、官方 source pins 与 licensed encoded fixtures；产物为 submodule pins、Zig adapter、mono/stereo/multichannel 顺序与连续 decode fixtures；以 `sme-codec-test` 和 Windows/Linux 构建证据单独 review。
- `T010-B / NormalizedMediaImport`：输入为T010-A decode/PCM contract、source-rate/layout fixtures 与 TASK-003 import policy；产物为 `import_audio.zig`、SRC contract/coefficients/hash、对齐后 PCM 和 import report；以 `sme-import-test` 的 rates/layout/impulse/alias/remap/invalid matrix 单独 review。
- `T010-C / MediaQualityGates`：输入为T010-B normalized PCM、T010-A codec round-trip PCM、reviewed quality policy 与独立标准/reference fixtures；产物为 `audio_quality.zig`、版本化 quality policy 和 true-peak/RMS/LUFS/DC/loop 报告；以独立 oracle、阈值边界和未扫描拒绝测试单独 review。
- `T010-D / StreamIndexProducer`：输入为T010-A encoded stream/parser、T010-B frame remap、TASK-003 storage policy/Seek/Chunk schema；产物为 `stream_index.zig`、真实 Chunk/Seek tables 与随机 seek 回读；以连续解码对照、preroll/end trim、resident forcing 和损坏 index 测试单独 review。
- 顺序 A→B→C/D；每片登记自己的 Owner、独立 Reviewer、commit、inputs、commands 和接受结论，全部通过才可整体进入 REVIEW。这些是一个完整 v1 任务内可单独合并的产物，不是缩小发布范围。

## 活动日志

- 2026-07-28：根据评审报告完成规格收口；状态保持 `TODO`，未开始代码实施。
- 2026-10-09：补齐实际依赖、量化/输入契约、独立审查产物与持续 gate；仅修订任务文档，状态保持 `TODO`。

## 风险与注意事项
不得复制 third-party 源码或依赖系统预装 codec。



## Forced Streaming的真实媒体Producer
当长WAV/PCM导入被size gate强制streaming，TASK-010必须实际调用pinned libopus encoder与libogg muxer产生Ogg Opus bytes，再从该真实输出生成chunk/hash/seek表；不能仅写descriptor。新增Encoder.prepare/encode/finalize及Ogg mux接口在worker/compiler运行，Zig adapter不泄漏第三方类型。编码profile必须冻结sample rate48k、channel mapping、frame duration、bitrate/CBR或VBR、complexity、signal/application、pre-skip/padding/granule与encoder版本/build flags；选择对支持target可复现的配置，跨平台确定性测试不过则明确BLOCKED而非重写hash。已经Ogg Opus的输入可在格式验证后复用bytes，禁止无理由二次有损编码。

子交付T010-A加入真实encoder/mux binding与roundtrip，T010-D必须证明WAV→forced-streaming→encoded bytes→index→连续/随机seek decode（本任务独立验收止于解码；真实group播放由已依赖005/010的TASK-011及后续026/014集成复验）；quality扫描编码前后均有，decoded时长/priming/loop/cue与48k原点一致。有损PCM不要求逐sample等于源WAV，而用质量/时长/对齐oracle；seek对照同decoder连续解码结果。损坏/空encoder输出、EOS/granule错误、大小阈值+4 bytes都应失败或正确forced streaming，禁止把长WAV静默当未定义PCM stream格式。
