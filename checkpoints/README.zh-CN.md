# 源码检查点与验证结果导航

这里保存的是纯文本补丁、恢复配方、计划和结果摘要。delivery 分支的 Git 提交是交付记录，不是可直接构建的候选源码提交；不能直接在远端 main 上套用这些补丁。

## 固定的复原入口

[源码链清单](source-chain-2816395.json) 固定从 e15de12 内容树到首个 runtime 重试候选的四步增量、每项交付提交、补丁大小/哈希及前后树。先按 [恢复配方](../recovery/e15de12-20261021/README.md) 得到精确 e15de12 基线，或核实已有验收副本与该树相同，再依序应用。缺少配方规定的原始归档时，不能只凭 main 与补丁恢复。

每一步均先核对补丁 SHA-256 和基线树，再检查可应用性，应用后核对结果树。不匹配即停下，不用强制覆盖、忽略上下文或改容量来绕过。不要同时应用最初保存的 runtime-retry.patch 和后来的 source.patch，两者包含同一生产改动。

本链包含重新实现的测试，不声称恢复了此前丢失的测试 blob 或原始 Git 历史。后续检查点可以从链尾继续，必须查看其独立 manifest 中的 base_tree 和 source_tree。

## 先保存，再运行，再保存结果

1. 小步改动先形成纯文本增量，固定来源、基线/目标树、哈希、精确命令及资源边界，提交为 UNVERIFIED，并读回核对。
2. 再执行已保存的有界计划。公开命令使用路径参数，原本地 manifest 的哈希用于绑定；公开版不是原绝对 argv 的逐字副本。
3. 每次运行单独追加结果摘要、exit、源文件前后校验、用时、覆盖范围与日志哈希。失败或零测试也必须留下记录，不能只保存通过结果。
4. 尚未运行写 not_run；环境消失、中断或没有终态结果写 unknown，不能写 pass。源码变化会使本次资格验证失效。
5. 结果只能支持其明确覆盖的目标、平台和源码树。源码存证、恢复成功、codec 检查都不自动证明 native fresh replay、完整矩阵或 Windows 验收通过。

manifest 的 UNVERIFIED 是计划保存时的状态，保持不改写；后续验证查该目录的 results。原始日志、录制二进制、ELF 和缓存不放入本分支，摘要中的哈希不意味着原始大文件已公开或持久保存。

## 已保存的阶段记录

- [基线编译失败，零测试](https://github.com/in-dreaming/bugu/blob/61c76f25e149b7565b23b6a029e64f3d7b7d324c/checkpoints/baseline-retry-20261021-6327086/results/debug-attempt-01.json)。
- [测试前置条件失败，不构成因果基线](https://github.com/in-dreaming/bugu/blob/37e61ec44b6fe3b8d3cb1a881fb2900370430f60/checkpoints/baseline-retry-20261021-c0529a1/results/debug-attempt-01.json)。
- [真实 Render 因果基线，1 通过、2 预期失败](https://github.com/in-dreaming/bugu/blob/9536ff27a6b6a0a1be2ce038418489797ceb02a7/checkpoints/baseline-retry-20261021-aa0726b/results/debug-attempt-01.json)。
- [候选 Debug 53/53，通过 3 个受控真实 Render 检查与 50 个 codec 检查](https://github.com/in-dreaming/bugu/blob/5075d29b3eb3b1f5a34510a1383e78bbfe266d00/checkpoints/runtime-retry-20261021-2816395/results/debug-attempt-01.json)。
- [既有 long native 录制因控制 lane 溢出而拒绝，没有 sealed tape，不能 fresh replay](https://github.com/in-dreaming/bugu/blob/e5c3165d851aab7d9c14d6b563013bde7a93c384/checkpoints/runtime-retry-20261021-2816395/results/native-record-debug-01.json)。

以上固定记录不被后续短测试或新检查点覆盖；新增的窄范围测试不能替代失败的 long 录制。此索引不宣称所有 Windows 故障根因已经消除。

## 后续受控 native 验证与完整增量链

新增 [完整七步源码链](source-chain-78d48ee.json)，从相同 e15de12 基线复原至源码提交 94d77ca413ef1e99207aed79ec57948bf06df610、内容树 78d48eed7e7fabf242a7a0572a944e2c13f2a656。后面三步只增加或修正显式测试 workload、测试门控回调与诊断；原 long 录制时长及容量不改。生产有限重试仍是之前的 +15/-1 改动。

- [短受控 native 录制 10/10 与 production compile](https://github.com/in-dreaming/bugu/blob/53987eeaa6b14be02872d6464695a5ca2c4bec73/checkpoints/native-retry-20261021-78d48ee/results/record-debug-01.json)：形成完整 sealed tape，文件中三组真实 same-incoming / same-selected 的失败后成功，其中一组由明确的测试握手控制。
- [同一 ELF、新 OS 进程 strict replay 10/10](https://github.com/in-dreaming/bugu/blob/4f34ad1293d51616f942574d02686427dd3f2326/checkpoints/native-retry-20261021-78d48ee/results/fresh-replay-debug-01.json)：逐条四角色、PCM、命令和 EOF 匹配，真实 Host join/destroy，ELF/bank/tape 前后哈希一致。
- [指定第二次 attempt 的 reference 单字节负例](https://github.com/in-dreaming/bugu/blob/a6db250d0db577d168a6db5cb15359a26381d552/checkpoints/native-retry-20261021-78d48ee/results/reference-negative-debug-01.json)：preflight 准入后，在 occurrence 52291、payload byte 223 精确 ReplayMismatch，真实清理归零。exit 1、9 通过和 1 预期失败原样保留，不冒称全部测试通过。

这些都是对应源码树、单次短受控场景的证据。前述 Debug 53/53 属于较早的 2816395 内容树，不能混称为最终树的完整回归。ReleaseSafe default 有[独立计划](https://github.com/in-dreaming/bugu/blob/ac68c2f6aaa64ad5fdfbf2368eedce3f9b7bcd29/checkpoints/native-retry-20261021-78d48ee/plans/default-releasesafe-01.json)，只有其另行追加的终态结果才能证明执行情况。Windows、持续吞吐和全部故障根因仍不能据此判定通过。

## 最终交付入口

[合并后的单份补丁与中文说明](../patches/sme-bounded-retry-94d77ca/README-zh.txt) 可从精确 e15de12 基线直接更新至上述94d77ca / 78d48ee源码树；补丁71799字节，不能与七步增量链重复应用，也不能直接在远端main应用。交付Git提交与来源源码提交不同。

最终树的 [ReleaseSafe default11/11](https://github.com/in-dreaming/bugu/blob/4d008f10c31d6b242837196deb3e07ca281bfc50/checkpoints/native-retry-20261021-78d48ee/results/default-releasesafe-01.json) 与 [两条原legacy Debug2/2](https://github.com/in-dreaming/bugu/blob/2b3ae3b1c4c4796a19cbcb48f01cd4bea7469086/checkpoints/native-retry-20261021-78d48ee/results/legacy-filter-debug-01.json) 已分别实际执行并追加终态结果。未运行完整历史矩阵、完整live_tick套件或本候选Windows验收；前述long录制失败保持有效，不被这些结果覆盖。

## Windows 验收更新（2026-10-21）

上述“Windows 未运行”为先前交付时状态。现已收到同一 94d77ca / 78d48ee 内容树的 [Windows 独立验收摘要](native-retry-20261021-78d48ee/results/windows-acceptance-01.json)：panel 8/9、chronology Debug 7/8、ReleaseSafe 7/8，三项均失败，候选仍未修复完成。该文件是 Windows 执行结果的转述摘要；原始日志仍仅在 Windows，本分支未备份原件。此前云端通过记录不覆盖这些失败。

## 诊断补缺交付（2f766bb / 63994cd）

[独立诊断补丁与短说明](../patches/sme-scan-state-2f766bb/README-zh.txt) 只从精确 94d77ca / 78d48ee 基底补齐测试日志的扫描槽状态，生产代码不变。[默认 Debug 9/9](https://github.com/in-dreaming/bugu/blob/d36175ddc62cca3f4a822abdb32c88864fcf555e/checkpoints/scan-state-20261021-63994cd/results/default-debug-01.json) 和 [预声明 Worker16/Control0 单次 9/9](https://github.com/in-dreaming/bugu/blob/cb1a35184b458b76a7bbedbab8ac8093e25b546f/checkpoints/scan-state-20261021-63994cd/results/worker16-control0-debug-01.json) 均为云端结果，未复现 Windows 故障，也不证明已修复。Windows 最小下一步只是一份待授权建议，本轮没有执行。

## Windows 诊断单次结果更新（2026-10-21）

[2f766bb / 63994cd 的单次默认 Debug 摘要](scan-state-20261021-63994cd/results/windows-default-debug-01.json) 已报告：8/9，Host 在等待首个 Play receipt 时发生 DefaultPcmCapacityOrShape，样本容量 384000/384000 耗尽；58 条扫描编码检查通过。没有确认的 runtime stream fault/handle，不能混同此前持续播放故障。此轮已完成、未重跑，候选仍未修复。仅存执行结果转述摘要，原始日志仍在 Windows，并未由本分支备份。

## 首次 Play 启动与显式准入交付（f28bee4 / f8bbbeb）

[合并补丁与验证范围](../patches/sme-initial-entry-f28bee4/README.zh-CN.md) 从精确 2f766bb / 63994cd 更新至 f28bee4 / f8bbbeb，不能与分阶段增量重复应用，也不能直接套用远端 main。最终树 [codec/CLI 73/73](https://github.com/in-dreaming/bugu/blob/fe24282cdac16fc3e882144b338fec053ea79e17/checkpoints/ordered-admission-20261021-f8bbbeb/results/codec-cli-debug-01.json)、[默认 RS 12/12](https://github.com/in-dreaming/bugu/blob/85763958ff36c501ea5581d203f77ae390904a0c/checkpoints/ordered-admission-20261021-f8bbbeb/results/default-releasesafe-01.json) 与 [两条旧断言 2/2](https://github.com/in-dreaming/bugu/blob/ab411ba22fff559b6c7a9462a067cad33ad2e150/checkpoints/ordered-admission-20261021-f8bbbeb/results/legacy-filter-debug-01.json) 各自独立保存。

此前同 ELF 的 [fresh replay 失败](https://github.com/in-dreaming/bugu/blob/41e73c51baf885dceb34deadaac60912a8bf55b1/checkpoints/initial-entry-20261021-1dafd4a/results/fresh-replay-debug-01.json) 仍然有效；新 ordered_job_scans 的 owner 前拒绝不是重放成功。最终候选 Windows 尚未验收，不代表整体 SME 或持续播放问题已经解决。
