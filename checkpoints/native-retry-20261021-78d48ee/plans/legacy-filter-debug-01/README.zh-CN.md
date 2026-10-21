# 两条 legacy 原断言的过滤计划

这是从相同模块/native 构建图派生的 Debug 命令，不是恢复出的原 live_tick 编译 argv。当前为未执行计划，不能作为测试通过证据。只保留 manifest 指定的两条原测试断言，不改源码、目标注册、容量或 oracle，不运行整套 live_tick。

公开 argv-template.rsp 仅把原绝对仓库、缓存、Zig-lib 路径换为占位路径；其公开 SHA 与原始 SHA 均在 manifest 中，因此不能声称公开模板与原始归档逐字一致。原参数数量 3772 保持不变；对 runner 的路径/root/name/cache/options 替换做纯数据比较后，两份模板导出相同 argv。没有因此执行编译或测试。runner 和 options.zig 保持原字节。不要直接运行 rsp；使用同目录 runner，它会按显式参数替换占位路径。

调用模板见 invocation-plan.json。需要精确源码树、已校验的 Zig 0.16.0、目录外全新输出位置。先不加 --execute 可检查参数；仅按已批准的有界计划执行时加 --execute。默认本地和全局缓存均独立，清除 SME_* 环境变量，不附加 semantic workload 或控制延迟。

编译和生成的 ELF 共享 600 秒进程预算；初始磁盘下限 3355443200 字节、运行下限 2281701376 字节，一秒检查，五秒进度。不要叠加外部进程组 timeout。源检查和结果写入在进程预算之外。runner 在可捕获的异常中终止自身活动进程组，但环境整体消失不保证能写结果；终态缺失必须报 unknown。

通过必须同时看见两条完整原测试名称及 All 2 tests passed.，并且源前后身份一致。失败、超时、磁盘不足或源变化均如实记录，不重试。原始日志、执行文件和缓存不上传本分支。

必须使用未启用 -O/-OO 且没有 PYTHONOPTIMIZE 的普通 Python；runner 使用 assert 进行身份和资源前置检查。
