# SME 首次 Play 启动资格与显式重放准入候选

## 应用范围与身份

- 基底源码：2f766bb8db0addb92c23d7a72e228b9b7ea9fd18，tree 63994cdb520eb3ece4ac137a46a830bf96101340。
- 候选源码：f28bee4e4f6cbb0e0b8fdb8d1d4decad37e76fef，tree f8bbbebd01520966237fab954a868c4dd1dee85f。
- 本目录补丁一次性应用于上述基底，勿重复应用分阶段补丁。Git 发布提交与源码提交不同。恢复提交不代表原历史。
- 检查干净工作树与基底 tree，再执行 `git apply --check sme-initial-entry-f28bee4.patch` 和 `git apply sme-initial-entry-f28bee4.patch`。应用后以临时 index 的 `git write-tree` 核对目标 tree，不以本地提交号相等为条件。

## 修复内容

默认 Live 首次 Play 的原请求，在 owner 证明它尚未提交、没有 active/pending/seek/recovery 等竞争生命周期，且流身份、请求 epoch 和真实 consumed==0 均符合时，以真实 source-domain 可用量完成启动准备。它不再因无声 Render 帧前进而只能反复 entry_supply/frame_mismatch。正常播放、已提交请求、旧 offline 路径不获得此资格。

真实 Worker 解码、Render publication acknowledgement、高水位6144、PCM、输入与调度比较、清理边界均保留。没有扩大 buffer、录制容量或持续重试，没有音频线程等待，也没有注入记录结果。

## 两种显式准入策略

API 新增 validateInputsWithPolicy / Driver.initWithPolicy；CLI record/replay 新增 `--admission native_attempt|ordered_job_scans`。省略参数和旧 API 均保持 native_attempt。

- native_attempt：完整记录的 job scan 交叠可做一次真实严格比较尝试，但未恢复原子顺序，实际可能 mismatch。
- ordered_job_scans：在建立 Session/Host 前拒绝同槽 Worker scan/Control queued 和 Control acceptance scan/Worker completed 的未定序交叠，报 CrossedScan。

严格策略是更窄的准入子集，不是所有 native 历史必然成功的承诺。录制先真实关闭并封帧，再完整 readback 验证，失败不发布最终文件。策略不写入 tape，重放需显式再选；wire 2/profile 9、原四项身份和执行比较不变。

## 证据必须分开理解

1. 修复前受控因果基线真实失败，已保存，没有抹去。
2. 5dc8a313 / tree 1dafd4a 阶段 Debug 54/54：真实 Render 干预仍开启时，原 Play 已执行，entry defer 为0，四声部1024帧 Oracle、Stop及真实16/16关闭、零资源和 Worker join 通过。无 Worker、无 Render ack、错误请求/生命周期等反例保留。
3. 同阶段真实 native 录制10/10及生产编译通过，但其同 ELF fresh-process replay **真实失败**：Worker occurrence52704，cut_fact byte49，EOF=false。原 tape/ELF 保留，未重新录制挑成功。
4. 当前源码 Debug 73/73：54 codec与19 CLI。含12个完整 schema 矩阵；原失败 tape 在 native_attempt 仍准入 unresolved=1，而 ordered_job_scans 在 owner 前准确 CrossedScan，未调用 Driver.run。这是严格拒绝负例，不是重放成功。
5. 当前源码单次 ReleaseSafe 默认 chronology+mode **12/12通过**。无 recorder/无额外delay/无retry workload，真实四声部PCM35072帧、跨帧与Play/Stop/Close通过，清理断言16/16、零lease/instance和Worker join通过。
6. 当前源码两项定向旧行为兼容检查 **2/2通过**（31.77秒）：旧 serial tick 对真实 frame mismatch 仍拒绝原 ticket；同注册 Worker 上合法开启旧 serial recording 仍在 Service scan 前被拒绝。仅这两个过滤用例，不是完整旧套件。

启动因果修复不等于解决先前 Windows 持续播放 underrun。Windows 本候选未验收，物理设备未测试，普遍确定重放与持续吞吐未证明。原 fresh 失败和此前所有 Windows 失败仍有效。

## 容量与使用限制

沿用现有有界诊断 profile；CLI 支持的 null device 仍为48000Hz、stereo、256 frames，单进程一个Host、同可执行文件重放和显式文件/采集/时限界限保持。超限或不支持历史必须显式失败，不承诺任意时长和任意Live历史。当前包仅含源码补丁和文本证据，不含原ELF/tape；重建品不能冒充原同build证据。

未在此轮操作 Windows、GUI、物理音频或 main。后续 Windows 验收须另行明确范围，不能将本包云端通过替代。
