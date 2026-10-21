# 先持久化，再验证

1. 每个小步变更先冻结文本补丁，记录精确基线树、文件大小、SHA-256、适用路径与明确状态。先保存到独立 Git 检查点并读回比对，不能只存在临时环境里。
2. 在隔离副本校验基线与补丁，记录应用后内容树。应用失败保留失败状态，不强行修补旧 checkpoint；新改动另建新 checkpoint，保留来源关系。
3. 长构建或原生运行前，把精确源码树、工具链/依赖身份、完整命令、超时及资源限制和预期判据一并存入 Git。未定的内容保持 pending，不能当成可执行计划。
4. 按计划做有界验证。每阶段完成后，把机器可读结果、摘要、实际退出码、源码前后身份、证据大小/哈希和覆盖范围单独追加到 results，不回写抹掉原候选状态。
5. 结果只能按证据标记 passed / failed / unknown / not_run。超时、环境重启、日志丢失或退出状态无法确认是 unknown；从未启动为 not_run。保存成功、编译成功、日志可解析均不能替代行为验证通过。
6. 只针对已明确测试范围报告通过。新构建不能继承旧 ELF/tape 的 strict replay 成绩，云端通过不能替代 Windows 验收。失败证据和未知状态保留，不通过重复尝试筛选有利结果。
7. 多人/多任务协作时先读取当前远端 tip；提交以该 tip 为父，并使用 expected SHA 的非强制快进更新。冲突或结果不确定时先只读核实，不盲重试，不覆盖他人变更，不改 main。

后续结果文件至少包含：checkpoint_id、candidate_tree、patch_sha256、toolchain_identity、command、started_at、finished_at、timeout_seconds、exit_code、outcome、source_before/source_after、evidence_sha256、scope、limitations。未知值用 null 和原因，不能猜测。

对可公开的结果只保留技术性摘要与哈希。完整私人日志、大型录制/二进制、凭证、本机私有路径、私人工作笔记不进入公开仓库。
