# TASK-010：集成 Ogg Opus submodule 与 sample-accurate codec adapter

## 元数据
- 状态：TODO
- Owner：`UNASSIGNED`
- Reviewer：`UNASSIGNED`
- 实施角色：Codec/Third-party Build
- 评审角色：Codec、许可证、跨平台构建
- 工作量等级：`L`
- 证据路径：`docs/validation/sme/TASK-010/evidence.md`（脱敏摘要）、`zig-out/sme-validation/TASK-010/`（原始产物）
- 执行波次：2
- 硬依赖：TASK-003
- 协作关系：TASK-011 消费 decoder/seek contract；TASK-017 compiler 使用 encoder metadata；`build.zig` 本波次唯一修改者
- 预计改动范围：`.gitmodules`、`third_party/ogg`、`third_party/opus`（新增 submodule）、`third_party_adapters/opus/`（新增）、`build.zig`、`tests/sme/opus_adapter_test.zig`

## 目标
通过官方 Xiph submodule 提供隔离的 Ogg Opus decode/metadata/seek 接口，正确处理 pre-skip、end padding、channel mapping 和 loop sample position。

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
- sample-accurate seek index 输入输出 contract。
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
6. `third_party_adapters/opus/PINS.toml` 记录 ogg/opus URL、exact commit、build flags、license file 路径与验证 target；`.gitmodules` 与实际 submodule HEAD 必须一致。

## 接口与数据契约
`OpusStreamInfo`、`Decoder.prepare/decode/seek/reset`；返回实际 frames 和 EOS。错误区分 invalid container、unsupported channels、decode failure、seek unavailable。

## 文件变更
- submodules/.gitmodules。
- opus adapter/C shim。
- build integration/tests、`tests/fixtures/sme/opus/LICENSES.toml` 与 `third_party_adapters/opus/PINS.toml`。

## 验证
### 自动化验证
- `zig build test`。
- 新增 `zig build sme-codec-test`：mono/stereo/5.1、pre-skip、end trim、随机 seek、loop、truncated/corrupt。
### 手工验证
- Windows 与 Linux 各构建一次并记录 commit/toolchain。
### 边界与失败场景
- chained Ogg（若不支持则明确拒绝）、unknown mapping family、seek 超界、partial packet。

## 完成定义
- [ ] submodule URL/commit/build flags 在 `.gitmodules`、gitlink 与 `PINS.toml` 三处一致且可重复构建。
- [ ] 每个 codec fixture 的来源、license 和 SHA-256 可审计。
- [ ] decoded frame 与 PCM oracle/seek cursor 一致。
- [ ] 无第三方类型进入公共 API。
- [ ] render path 不链接调用 decoder。

## 活动日志

- 2026-07-28：根据评审报告完成规格收口；状态保持 `TODO`，未开始代码实施。

## 风险与注意事项
不得复制 third-party 源码或依赖系统预装 codec。

