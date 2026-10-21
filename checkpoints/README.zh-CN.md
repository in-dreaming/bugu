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
