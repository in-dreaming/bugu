SME Live bounded retry 候选验证说明

源码：94d77ca413ef1e99207aed79ec57948bf06df610
源码树：78d48eed7e7fabf242a7a0572a944e2c13f2a656
基底为精确恢复的 e15de12 源码内容；恢复提交为合成提交，不冒称原历史。

修复范围
Windows 既有日志已确认 Worker completion ready 后，availability 的真实 odd sequence 导致整个 Control tick 延期。候选只在现有 completion_capacity 总预算内，遇到 odd_sequence 或 sequence_changed 时增加至多一次真实尝试。持续 odd 仍在两次尝试后返回；不自旋，不阻塞音频回调，不扩大缓冲，不把失败读取写进派生状态。它修复已证的整轮延期路径，不承诺下一次真实读取必成功，也不承诺所有平台的实时持续供给。

已完成云端 Debug 验证
1. 未修复基线：受控真实 odd 到 even 的测试按预期失败；此前编译和 fixture 前置失败分别保留。
2. 早期 runtime 候选树28163955b35b0fc304055574b2ea069c9615f378：受控三个测试与 codec 五十个测试合计 53/53；这不是最终78d48ee树的全回归结果。后续最终树新增的改动仅为测试专用接线/握手与诊断，实际 native/fresh/RS/legacy 结果如下。
3. 独立短 native 场景：真实 Host、Worker、解码与 null 音频回调录制，10/10，生产非 test 编译通过。测试专用握手保持真实 even 直到第二次尝试结束，500 ms 有界，取消和关闭均释放；只用于 capture/null/close-only，在生产编译剔除、replay 中拒绝，不能当作持续实时负载资格。
4. 实际 sealed 文件含三组 same-incoming 重复尝试，强制目标 job29 的 occurrence 51542 → 52291，先 odd 失败，后真实 acceptance 成功。
5. 同一 ELF 的全新进程严格重放 10/10：四角色记录全部匹配，含 canonical Input400、Schedule16、submitted PCM28672 样本及 discarded-generated512 样本，两个命令终态和 EOF，真实 Host joined/destroyed。
6. 定点负例：只改第二次尝试的 PCM hash 比较参考值，所有执行 Input/Schedule 不变。真实 preflight 通过后，在 occurrence52291、acceptance payload byte223 精确 ReplayMismatch。原始非零退出保留；实际 joined/destroyed，16/16 source，live/leases/instances0，cleanup_error null。

已知边界
原 long Debug 录制在 submitted30720 frames 达到既有 Control4MiB lane 容量，明确拒绝，未 sealed，不能重放；未扩容量或降低原 long >=32768 frames 断言。短场景仅验证受控语义，不代替持续吞吐资格。当前 tape 绑定 exact ELF/bank，不能宣称跨构建可移植；源码重建应重新录制再严格重放。Windows 旧候选的所有真实失败仍保留，当前候选尚未获 Windows 验收。

ReleaseSafe 默认路径
已实际通过 11/11（chronology8、mode3），总计275.36秒含编译。未安装新增 retry workload，保留原一次跨帧 pause，Control/Worker 延迟实验变量均清除。真实跨帧2048→2560，四 stem PCM35072 frames，audible33024；原关闭断言验证16/16 source、live/leases/instances0。此结果仍不是 Windows 验收。

旧路径兼容
Debug 精确过滤运行原 live_tick_test.zig 的两条测试，2/2 通过（编译57.74秒，运行17.12秒）。原 supply frame mismatch 仍拒绝原ticket；同一注册Worker上合法开始的 serial recording 仍在 Service scan 前拒绝。使用同构模块图参数派生，未修改原测试或运行整个大型 suite。未重复跑其他历史总矩阵。

应用与恢复
仅当基底是精确 e15de12 内容树9c726fe11f07af1936f365a6b9b505153be93709时，应用 e15-to-94d77ca.patch。已独立index验证结果树78d48eed7e7fabf242a7a0572a944e2c13f2a656；若已按增量链更新，不要重复应用。此补丁仅71799字节，SHA256 c53f2c09da22be36e0c193af9586f989136c83863992d1cb4c9850ec3fd115e8。

本轮 Git 持久化源码、计划、工具和验证摘要，不包含 exact ELF/tape 原件。原件云端本地保留；若环境丢失，hash不能恢复原字节，应按计划同一构建重新录制并重放。当前源码未在 Windows 上验收；既有 Windows 失败全部保留。
