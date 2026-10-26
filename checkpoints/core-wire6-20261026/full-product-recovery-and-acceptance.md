# SME 完整产品恢复与验收审计

2026-10-26；只读源码与历史证据审计。未修改产品源码，未构建、运行测试或接触用户机器。本表区分“已有实现”“历史限定验证”“当前完整产品验收”，不将缺少当前证据写成没有实现。

## 结论

**先恢复完整产品树，再集成当前 headless 修复；不能以 headless 19 项取代原全部 27 TASK，也不应重写已经存在的编辑器。** main `c9628460a07cea3f5e432e88c09169d4385df672` 是规格/基础，不是完整 SME 实现基线。delivery `128be5f09d610c7dd68c5f7279d95305e3a9abe4` 是恢复补丁/计划/结果载体，也不能当完整实现 checkout。

本次已实际读取完整源归档，核验外层与内部 source tar SHA256，并检查 authoring、UI、debug、demo 与原资格记录。历史证据只保持其原修订身份，不自动转移到最新树。

## 可复核恢复身份与正确集成起点

1. 已核验的完整源起点为 source commit `cb2c224d5d36519c534ce14d5d6d2730693b1834`，tree `85b35b269e470ffb253b127d6b1ae9a7e7c3ecc0`。恢复归档不随本审计公开；公开恢复清单提供后续精确身份约束。
2. 按[正式恢复清单](https://github.com/in-dreaming/bugu/blob/128be5f09d610c7dd68c5f7279d95305e3a9abe4/recovery/e15de12-20261021/recovery-manifest.json)：反向 cb2c224 checkpoint 补丁到 `4cdbbf5` tree `b0e1334ea1030f9920ef1f84671b6736aa78d916`；正向 default 补丁到 `6f3fb3a` tree `49098fa120fe090e3c81c320bca9161d16d749d1`；按清单依次应用 headroom/sustained/diagnostic 补丁，得到 `e15de1243d23fa67449674ab75fcebe735e9840d` tree `9c726fe11f07af1936f365a6b9b505153be93709`。所有输入必须校验清单中的大小、SHA256、精确 base/result tree；不匹配即停止，不能直接对 main 应用。
3. **e15de12 不是最后完整基线。** [后续 source-chain](https://github.com/in-dreaming/bugu/blob/128be5f09d610c7dd68c5f7279d95305e3a9abe4/checkpoints/source-chain-78d48ee.json) 将完整树继续到 source `94d77ca413ef1e99207aed79ec57948bf06df610`、tree `78d48eed7e7fabf242a7a0572a944e2c13f2a656`，中间逐项身份均由该清单约束。再接 scan-state 补丁 `patches/sme-scan-state-2f766bb/94d77ca-to-2f766bb.patch`（SHA256 `b7f8e7a79bf7e1d936956d2aafa0b4b390ee841a1aef6f235f3e972561372217`，8945 bytes），得到 `2f766bb8db0addb92c23d7a72e228b9b7ea9fd18` tree `63994cdb520eb3ece4ac137a46a830bf96101340`；`patches/sme-initial-entry-f28bee4/manifest.json` 的累积补丁到 `f28bee4e4f6cbb0e0b8fdb8d1d4decad37e76fef` tree `f8bbbebd01520966237fab954a868c4dd1dee85f`；`patches/sme-passive-timing-9e0ccb49/manifest.json` 再到下述9e0ccb49；[host-wait 清单](https://github.com/in-dreaming/bugu/blob/128be5f09d610c7dd68c5f7279d95305e3a9abe4/patches/sme-host-wait-e09b38df/manifest.json) 明确 `9e0ccb49f39ed5eeebe4b8d030880726e7810721` tree `088da407ad1d556f4c831778fe16742ef1a182fd` → `e09b38df925020f5877e0ed637d75fad5ea3e681` tree `8ba69a82caabe29ed9a6a55566d90969497b110a`。
4. 本次确认到的最新**完整 notified Host 候选**为 `4f2710c7a3db88649c3a495b5d7fe7950633788f`，tree `9c2a25a4a9750e098e93a6949749ee717640aae8`；[notified-host 清单](https://github.com/in-dreaming/bugu/blob/128be5f09d610c7dd68c5f7279d95305e3a9abe4/checkpoints/notified-host-20261021-9c2a25a/manifest.json) 以 e09b38df 为精确 base，patch SHA256 `f3a09f1920180cca73730f29b5c503260e7e54a2d91ff6370f39cc748384b278`。未来完整集成应首先恢复/核验此树或证明更晚的完整后继，不能从缺少 panel 的提取树倒推产品不存在。**2026-10-26 本次已实际完整恢复并逐段核验所有补丁SHA256与结果树，最终 index tree 精确匹配 `9c2a25a4a9750e098e93a6949749ee717640aae8`。这是内容恢复，不冒称重建原commit历史，也不是构建或验收通过。**
5. [headless 提取计划](https://github.com/in-dreaming/bugu/blob/128be5f09d610c7dd68c5f7279d95305e3a9abe4/checkpoints/headless-source-20261022-82cec8a/qualification-plan.json) 单独声明 foundation tree `35aee6c461b1edd82c1b7cf2916b044ce990e0ec`、target tree `82cec8a633cbb8376dc652f8a410c05b1684ba6c`、相同 notification patch SHA256；该 foundation 是提取构建的身份，不能据此宣称它是完整产品树。当前 headless 后续改动必须按文件/依赖做三方整合，而不是覆盖完整 build graph。完整 app/panel、debug、demo、七个 gitlink 与显式 GPU/SDL overlay 都要保留并重新锁定。

## 需求 → 真实实现 → 已有证据 → 最小下一步

最终9c2a25a树已核对：`tools/sme_authoring/app`、`tools/sme_ui`、`tools/sme_debug`、`examples/sme`、`docs/validation/sme/TASK-019`、`build_support/sme_tasks/task-019.zon` 与完整cb2c224归档逐字节Git树差异为空。因此以下app/debug/demo实现与TASK019缺口不是仅根据旧归档猜测；本次未运行其测试。七个gitlink完整保留；GPU/SDL显式overlay身份仍需从原资格包恢复，不可假称默认GPU gitlink包含overlay。

| 原始要求 | 已找到实现 | 已有证据及边界 | 下一步/当前缺口 |
|---|---|---|---|
| TASK018 完整 GPU 编辑器/恢复/发布 | `tools/sme_authoring/app` 内真实 gpu_host、controller、inspector、recovery、resident_publish、live_session；不是空壳 | `TASK-018/application-validation.md`：f440b28 模型14/14 两模式；后续 `panel-publish-controls-20261015.md`：303d758 LLVM15/15、resident兼容46/46，真实 dispatcher→provider Publish/Rollback，非 native GUI | 保留现有实现；按 task018 逐控件核对专用编辑器、browser/new/open、waveform/snap、实时 meters/tuning/reload。旧“pending”文档有后继，不能直接当最新缺失清单。做当前完整树 GUI/IME/恢复/close 资格；不以 synthetic pointer 代替 |
| TASK019 live/replay GPU debugger | `tools/sme_debug` protocol/live_model/wire_receiver/panel_model/gpu_panels；RuntimeObserver、debug bridge、adopted connected AF_UNIX provider | `tools/sme_debug/README.md` 与 `TASK-019/local-provider-source.md` 明确 composed source 未执行；有真实有界 owned-copy协议、draw adapter，不等于 runnable debugger | 核对后继是否新增入口；归档明确 standalone endpoint/discovery、完整 GPU app、replay runner 尚未实现，不能把 CLI replay当其完成。先独立编译/审查现有 composition，再补确实缺失集成 |
| TASK020 完整 showcase/public SFX/music/device/offline | `examples/sme` 实际 authored project、resident/stream/rolling-fill/record drivers、脚本/资产生成/验证器；app实际原生链接 | `TASK-020/rolling-fill-usage.md`：真实 normal 1,310,720 frames，slow/pause/undersupply/provider-failure；0faea67当前 caller120次执行；398步 native link。明确非全demo，whole trace有160行测量差异 | 不重造示例；将原 task020 tempo/fills/layers/stinger/sidechain/save/reload/public SFX+music需求映射现有项目与实际 driver，补缺失组合和 current-tree offline/device证据；不能由4-stem Play/Stop推全demo通过 |
| TASK025 ordering/exactly-once/RT | runtime真实修复FIFO、one-shot重复PCM、stop-before-play泄漏；bounded snapshots/terminal retention | `TASK-025/evidence.md` 保存前修复红例与Linux限定通过；Windows及remoteCI当时未完成 | 在整合树重跑相关严格回归、RT边界与跨平台CI；旧红例不得删/改预期 |
| TASK026 public2stem nextbar+SFX/partition replay | 同一 ControlRuntime内 public MusicRuntime、真实bank/planner、publicsubmitPlay SFX，native recompute | `TASK-026/evidence.md`：限定Linuxresident/no-fill独立审查；注册Debug31/31、LLVM136次，Windows仅PE编译 | 保留真实public集成/oracle；当前树重新验证callback分区和SFX路径、Windows执行/CI。不能用Service-only bridge替代 |
| TASK027 UI库/IME/GPU | `tools/sme_ui` atlas/font/gpu_renderer/input/textbox/unicode/widgets；真实 app host | `TASK-027/evidence.md`明确headless model与原生IME资格有区别；后续TASK018有真实使用 | 核对当前GPU/SDL overlay精确来源、native会话identity与关闭证据；历史有限呈现不等于完整nativeIME/全UI资格 |
| TASK021 全27 Windows/Linux持续CI | `.github/workflows/runtime-baseline.yml`存在Windows/Linux×Debug/ReleaseSafe runtime scaffold，固定依赖/toolchain | workflow文本不是成功run；归档没有TASK021最终验收报告 | 从全部27验收项生成当前源码矩阵；确认CI覆盖而非仅runtime baseline；保留独立审查未完成项 |
| TASK022 Windows设备+两次8h | 真实 miniaudio/device路径及live恢复实现；历史Windows执行记录存在 | 当前笔记仅有2026-10-24静音600.018秒两cycle限定结果；不是两次8h，不是物理声学证明 | 在适用权限、设备与资源条件下另行安排完整设备/两次8h；本次未启动，不能以nullbackend/短录制替代 |
| TASK023 API/package/support | API、dependency manifests、source package/demo manifests及恢复说明存在 | 源归档完整可读≠干净机器可构建/可安装包；0fa native link显式非clean-package资格 | 完整树固定依赖/overlay/toolchain、支持矩阵，独立干净build/install/run与负例；不要把headless源码发布冒充完整包 |
| TASK024 唯一full-v1 PASS | 原规范要求全部当前工件无missing/stale才PASS | 未找到满足全27＋GUI/device/8h/cleanpackage的当前汇总；现有证据反复明确非full-v1 | 维持全产品未完成；建立每项same-source/真实命令/结果/原始证据索引，最后汇总，任何missing/stale保留FAIL/未验收 |

## 最小真实完成顺序

1. 恢复上述完整候选、验证每段树与原生依赖；列出 headless 当前修复与完整 app 共同文件的三方差异，确认无 panel/build/test遗漏。此步骤先于任何“新建UI”。
2. 冻结新的完整整合身份；先验证当前录制/回放修复及原有核心/author/runtime兼容，不放宽 overlap、溢出、完整性或输入契约。
3. 完成源码存在但未资格的 debugger/GUI组合审查；仅对规格映射证明确实没有的入口/功能实施补齐，保留 boundedRT和只读debug边界。
4. 同一完整源码开展原全部27矩阵＋完整示例＋cleanpackage；随后在另行适用授权下完成Windows/nativeIME/device与两次8h。每步一份精确冻结计划；失败保留，不择幸运运行。
5. 最后TASK024汇总。任何headless成功只能记其限定slice，不能关闭整个SME。

不确定项：完整后继树已恢复；历史记录中的五个中断独立验收门需按原任务再定位；TASK018早期pending文字可能被后继实现覆盖；TASK019归档后的独立完整实现尚未找到。因此这些是定向核验项，不是授权重写或宣告永久缺失。
