# Headless SME 源码范围

这是从已验证的 Live 候选中提取的独立源码导入，不是合并交付记录分支。保留原 main 的现有目标与无关文件；不导入旧开发历史、验证日志、二进制录制、GPU 作者界面或字体资源。

## 能力和边界

保留公开 audio/music API、实际 Live Host、Opus 编解码、持久化 Live history CLI 和相关原始测试。普通 Host 使用事件通知。阶段2候选为 semantic 录制/回放增加显式 pacing；旧 API wrapper 与 CLI 默认仍为 legacy_poll，测试私有 capture 也保持旧模式。新增 notified_v1 必须单独验证，不能将旧模式或阶段1普通播放的通过当作其回放证明。

初次提取图注册 63 个模块、19 个检查和两个 SME 生产目标，后续候选另显式增加有界回放检查：`sme-live-history`、`sme-author-live-production-check`。初次导入时公共与生产源码保持来源原字节。提取构建差异限于选取原注册项，以及仅在对应原测试套件存在时注册三项历史附加 runner；已登记的依赖、文件和检查仍必须存在。

本图不纳入需要旧固定 Opus/f32 oracle 的 `sme-live-initial-headroom-test`、`sme-live-semantic-service-check`，没有删改其测试内部断言来冒充覆盖。生产 Opus API、固定 Ogg/Opus gitlink 和 native C 编译选项保留。完整作者 panel/GPU 应用不在此源码子集内。

## 准备真实输入

需要官方 Zig 0.16.0，以及根 `.gitmodules` 中的固定 miniaudio、Ogg、Opus 子模块。原 main 的 GPU 目标仍在，其依赖需按原目标另外准备，不属于 headless SME 验证。

测试用 16 个 WAV 不进入 Git。使用 Python 3 标准库运行：

    python3 tools/sme/prepare_live_fixtures.py
    python3 tools/sme/prepare_live_fixtures.py --verify-only

脚本使用原全整数合成器和 score，在临时目录生成真实 authored 输入。全部 16 个文件的长度和 SHA256 匹配固定清单后才写入缺失文件，不改 project、期望输出或运行时采样。已有不匹配文件会报错且不会被覆盖；磁盘错误可能留下部分文件，下次运行仍会验证并拒绝不匹配内容。生成素材约 12.3 MB，保留原 MIT 许可和来源说明。

## 验证身份

来源基线的精确 tree 是 `9c2a25a4a9750e098e93a6949749ee717640aae8`。新提取树有独立构建接线，必须单独验证，不能继承来源基线的测试计数。当前文件的初始状态是 UNVERIFIED；每次有界验证计划和真实终态另行记录，不覆盖旧失败。

## 阶段2候选：显式通知模式录制/回放

profile 9 的前一候选使用 wire 3 增加 pacing；当前候选使用 wire 4 增加真实 job scan 谓词 INPUT。launch INPUT 明确携带 legacy_poll 或 notified_v1，实际 Host started 仍独立记录并逐项比较。当前 Reader 对 v2/v3 返回 UnsupportedVersion，不改旧文件头、不猜缺失字段。已有 v2/v3 录制只能交给其原匹配可执行文件；重新编译并不保证同一二进制身份，Git 源码也不是旧 ELF 的替代品。其它旧 offline API 不因此改用通知模式。

Recorder 新增 initWithPacing 与 initStreamingWithPacing；Driver 新增 runWithPacing。旧构造/运行 wrapper 明确选择 legacy_poll。pacing 在 Session 初始化之前固定，直到真实 Host 销毁；回放从已验证 launch INPUT 建立配置，并在创建 Host 前拒绝调用者期望的模式不匹配。没有用比较结果注入原子状态、PCM 或命令结果，也没有扩展通用内部竞态调度。

真实 CLI 的两端均可显式选择：

    sme-live-history record --bank BANK --state STATE --script SCRIPT --out TAPE --pacing notified_v1 --admission ordered_job_scans
    sme-live-history replay --bank BANK --state STATE --tape TAPE --pacing notified_v1 --admission ordered_job_scans

仍须同一可执行文件、固定 null backend 48000Hz/stereo/256-frame 配置与原有容量上限。native_attempt 保留“允许实际尝试，不承诺所有未定序重叠均可重放”的语义；ordered_job_scans 使用下述有界 job 状态规划准入，仍不是所有 Live 历史均可重放的保证；其它未支持重叠和非法历史在回放 owner 创建前拒绝。录制后 strict 检查失败保留不适用证据，不为取得通过而循环重录。

short-play 是新增的无时序 hook 最小协议夹具：在真实 Play 后至少 8192 帧再发 Stop，检验真实非零 PCM、Input、Schedule、命令与完整清理。它不代替原 long 至少 32768 帧断言，不代表长期或真实设备稳定性。新候选先冻结源码与计划，实际录制、同 ELF 新进程回放和拒绝负例各自记录结果。未取得这些结果前不得声称通知录制/回放已通过；long 覆盖仍是独立门槛。

## Wire 4 候选：真实 job 扫描 INPUT 与有界调度

只有 Worker 对 queued、Control 对 completed 的真实 scan AFTER 谓词进入新增 INPUT 字段。它取自原 load 已经返回的 Point 值，不新增引擎读取、不从 reference 推断；reference 继续独立逐项比较。其它角色、位置、缺失或非规范布尔值拒绝。旧 wire 3 文件没有这个 INPUT，不允许根据旧 reference 转换。

strict 先验证完整全局 marker、scan grammar、载荷和既有其它重叠合同，再以 Control/Worker 两条只读 INPUT 流规划四态 free→queued→running→completed→free。规划器明确支持 1..48 个 slot，超过上限拒绝，不截断；当前 Host 仍固定 48。初始和最终必须全 free，job identity、角色、状态迁移和全局区间均须成立。每个角色各自维护两个流游标与固定 slot 状态，不按事件数分配计划数组。

回放仍执行原始原子读写：先释放真实 BEFORE marker，再等待已证明的操作序号；执行后核验真实谓词和身份，发布完成序号，最后进入 AFTER marker。没有把预期值赋给引擎状态，也不阻塞 Audio 线程。取消沿用现有失败传播和真实 owner join/销毁，不以计数器跳跃代替清理。native_attempt 不启用这个执行门，保留实际尝试、可能不匹配的合同。

这是待独立验证的接入候选。纯模型的有限穷举不是完整系统证明；短闭环、既有 wire 3 的成功或失败也不是 wire 4 long 录制与 fresh replay 的替代。生产供给策略、真实 PCM/命令 oracle、4 MiB lane 容量和原 long 门槛不变。
