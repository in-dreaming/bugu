# Bugu：真实 Service 联合约束测试适配器

日期：2026-10-26。状态：独立测试适配器，**不是新回放协议或端到端修复**。

## 固定版本

- 恢复基线：`c963aec1c6b74e17da52ce553520aa7c0e4b5e2f`，树 `123baa533e50ffcaa3210ec00b4d977e94ef7b29`。
- 本轮测试版本：`d9441b3fb55168d61c3576e84b1335c988e2fb27`，树 `fa935986001365670dfed19f79537e9bb82c3523`。
- 本轮只新增 `tests/sme/joint_frame_service_test.zig` 和 `build_support/sme_tasks/task-029.zon`。
- 相对 c963aec，生产源码、协议、准入实现及共享构建器逐字节不变。

## 做了什么

执行真正的 Service、原子 load/store/RMW、Opus 解码、PCM Ring 和现有 hooks，而非把期望读取结果写入引擎。使用仓库原始生成器恢复16个输入 WAV，逐个校验已保存 SHA；这些输入不是运行输出或伪造期望结果。没有启动 Host、音频设备或 Windows。

两个 Zig test body 覆盖下列固定场景（不是声称有十几个独立测试根）：

1. 正常 readiness 读取实际 sequence/frame/consumed/produced/job states，区分未读字段与值为零。
2. 在初始 sequence 读后执行真正的 endRenderSpan：真实 frame mismatch 提前返回，不读取 consumed/final sequence。
3. 在 frame 读后或最终 sequence 前完成 Render 发布：sequence_changed 拒绝；相同帧号再次发布也不能用值相等冒充同一个事件。
4. 在真实 odd sequence 后读取 readiness：odd_sequence 拒绝，frame/consumed 尚未读取。
5. 两个真实 request 产生 job；在 readiness 扫描处完成真正的 Worker 解码。实际 job 状态改变，但非 free backlog/queued 数量不被伪造或覆盖。
6. 两个实际 Live acceptance、Render visibility admission 和 Control acknowledgement 均被计数核对。
7. 真正的 Ring peek/consume 前进后，Control 仍看到上一 completed prefix；endRenderSpan 后才观察到新的 consumed。真实 frame/consumed 与固定期望独立比较，错误期望明确失败。
8. 被动记录精确 Render 次序：odd → slot guard CAS → consumed release → guard release → frame → even。缺少或多余记录失败；closed slot 的 guard CAS=2 后不得读取旧 descriptor。
9. 在测试专用 checkpoint 处插入真正的 close，已被 Render CAS 持有的 guard 导致 DrainPending；另外真实 Ring lease 也阻止 close。这两者分别断言，不互相冒充。
10. 真正 cancel/close/open 复用 slot 后产生新 generation；旧 handle 的 readiness/close 返回 StaleStream。
11. 普通合法 crossfade 配置在 author Live 被拒绝。配对验证明确区分：release_profile 本身已被 author Live 排除；initial_bank_only+crossfade 在普通 Config.validate 已返回 UnsupportedCapability。**不声称单独覆盖了 bindings 拒绝分支**。

## 固定计划和观测边界

Plan enum 与具体插入点在每段执行前固定；适配器不会在读值不符后重新挑选一个“成功”计划。capture Point 回调只复制固定容量数据，溢出使测试失败；它不重入或修改 Service。刻意的 interleaving 仅通过既有 test_readiness_hook、test_frontier_hook、test_checkpoint_hook 同步调用真实操作。

这相当于执行明确的原子操作交错，**不是启动原生 Control/Worker/Render 三线程**。因此它证明这些具体交错和错误路径符合声明，不证明所有内存重排、真实等待 gate、无死锁或任意历史可重现。held-guard 的同步 close 拒绝不是无死锁证明。

## 运行

要求 Zig 0.16.0、固定 submodule（opus/ogg/miniaudio）；使用可写 Zig cache。

```sh
python3 tools/sme/prepare_live_fixtures.py
zig build sme-joint-frame-service-check -j2 --summary all
zig build sme-joint-frame-service-check -Doptimize=ReleaseSafe -j2 --summary all
```

附带 bundle 是从公开已保存 d2ea6c7 到本测试版的完整增量，包含此前重建源码；这不代表此前已知问题被修复。已有 d2ea 对象的 repo 可验证 bundle、fetch HEAD，再单独 checkout；不要覆盖用户修改或更新 main。`source.patch` 提供同一增量。`manifest.json` 给出身份与内容散列。两个原生模式的实际结果见 `results.json`。

## 失败记录保留

- 第一次构建未启动：默认全局 cache 不可写；改为显式可写 cache。
- 初始适配器编译失败：对 optional pollVisibility 错加 try；仅修测试。
- 初始执行 0/2：attached Service 调用了普通 acceptCompleted，原 API 正确拒绝；清理因 pending job 造成 fixture panic。crossfade 测试遗漏普通配置所需 release_profile，普通验证正确拒绝。
- 修正为真实 acceptCompletedLiveV1 和合法配置，保持原生产拒绝行为，之后再进行当前版本完整复测。

## 尚未证明与下一步

这些结果把此前标量小模型映射到具体 frame/sequence/consumed/guard/job/lifetime 路径，但没有实现从完整 tape 提取联合约束图、没有求解/回放任意历史，也未将原 wire-4 的 UnsupportedOverlap 改成接纳。

最小下一步是**一个有限完整 witness → 联合准入 → 冻结计划 → 全新 Service 执行**的桥接：从单个受支持场景收集 frame/sequence/consumed/slot-generation/job 生命周期证据；独立验证跨域图，然后冻结计划；新 Service 按计划运行，比较所有读取、事件和 EOF。加入跨域环与篡改观测值反例，失败不能重新择序。先在测试工具内闭环，再考虑独立线程 gate 与协议版本，不直接改变生产协议。

Render 队列溢出仍独立未解决。本轮未做实时录制、fresh replay、PCM 全流等价或音频性能验收。
