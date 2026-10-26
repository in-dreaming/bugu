# 独立源码与模型审查

日期：2026-10-26。审查对象为独立 Python 离线模型，不是生产实现。

## 结论

在声明的有限、顺序一致性见证（SC-witness）标量投影范围内，未发现阻塞问题。独立重跑 37 项定名测试及 35,840 个枚举案例通过；其中接纳 3,316、拒绝 32,524，判定序列 SHA256 为 `245f3e405200085b5c1651687a4d409da0450b56b858032b3da42fa23c6ef017`。

这个结论**不是**原生 Bugu 回放、弱内存模型、所有并发历史、原始失败 tape、PCM 或实时性能的证明。两次写入或两次 Control episode 仅有定名案例覆盖，不属于本次完整枚举宇宙。

## 固定源码与对应关系

源码提交 `c963aec1c6b74e17da52ce553520aa7c0e4b5e2f`，树 `123baa533e50ffcaa3210ec00b4d977e94ef7b29`；审查后生产 checkout 仍干净。

| 源码位置 | 实际含义 | 模型边界 |
|---|---|---|
| `src/streaming/music_stream.zig:569–570` | Service sequence/frame 初值均为零 | 单个预先存在的 Service epoch，初态为零 |
| 同文件 `1022/1033/1055` | `controlAvailableCutObserved` 的 sequence/frame/final sequence；origin 为 readiness 或 acceptance | 只投影这三个标量观察；不模拟中间 consumed/produced、ring 错误和完整返回值 |
| 同文件 `2171/2189/2278` | `observeReadinessObserved` 的非 initial、runtime-attached 路径 | 只投影标量；真实函数还可因坐标、ring、input.validate 等中途返回 |
| 同文件 `2394` | 附着时检查 sequence/frame 为零 | quiescent 前置检查，不是一个被建模的并发读取 |
| 同文件 `2588–2629` | Render odd RMW(acq_rel) → slot guards/consumed → frame store(monotonic) → even RMW(release) | 保留标量顺序；明确不模拟 slot guards、consumed 的 release 发布和相关生命周期 |
| `src/runtime/runtime.zig:6199` | Render 调用 `endRenderSpan(frame)` | 模型把 frame 发布值当声明的输入，不证明 Renderer 如何算出它 |

Service frame 是全局对象字段，不能按 stream slot 拆成互不相关的原子。正常 Render 路径在调用前令 frame=next，但 `endRenderSpan` 本身没有数值单调性检查。模型的非回绕、非递减数值要求是显式支持范围，不能从内存序名称 `monotonic` 推出。

### 已识别但排除的读取

- `src/music/runtime_assets.zig:1046/1094`：`collectLoopCrossfadeSource`；由 `src/music/resident_runtime.zig:8341` 调用，`loopCrossfadeSourceStillReady` 也会复核该路径。
- `src/music/runtime_assets.zig:1145/1185`：`linearCrossfadeSourceTailReady`；由 `resident_runtime.zig:8410` 调用。
- 这些读取未经过本模型针对的 frame hook。通用 Runtime 中调用路径确实存在，但**当前受检 author Live Host 配置已显式排除 crossfade**，不能误说这四处在当前限定 profile 内可达。
- 具体排除证据：`tools/sme_authoring/core/live_admission.zig:34–44` 拒绝非空 `crossfade.bindings`；`live_owner.zig:258` 在创建 owner 前调用它；`live_semantic_replay.zig:1266` 也在创建 Host 前调用。`resident_runtime.zig:6686–6718` 进一步排除 crossfade 配置/运行状态和 fade、overlap、非 hard-cut 路由。`scheduleTransition` 的 loop 分支在 `8289` 依赖 `curveFor != null`，fade 分支在 `8382` 无 curve 即拒绝。因此当前入口有静态源码可核的排除链，而非仅凭 fixture 缺少 crossfade。
- 这个排除链尚未在本 Python 模型中通过真实 admission 调用执行测试。下一步可固定该限定配置并补实际拒绝测试；不能将它推广至普通 Runtime 或任意直接调用 Service 的消费者。
- `src/music/live_bootstrap_test_binding.zig:363` 是测试绑定的初态检查。
- Runtime 的 `music_observation_frame` 是另一原子域，不是这里的 Service frame；本模型未覆盖它。

## 分支与生命周期限制

源码中 odd sequence 立即返回；frame mismatch 也立即返回，不执行 final sequence。模型按这些分支限制读取形状，并以独立状态读取核对各记录值。但它没有执行原生 Control 函数；成功的三读形状只能称为“标量投影稳定”，不是完整 readiness 成功。

单 epoch、出生/死亡区间和 epoch 一致性是声明的模型输入。模型拒绝 claims-held gate、未知 site、consumed family、回绕与 frame 值下降。它没有证明真实对象回收、slot reopen、锁持有关系或跨所有 calendar 的无死锁。额外 edges 的联合环测试是合成约束测试，不等于从生产系统提取了完整依赖图。

## 算法与测试审查

- 求解器以固定标识排序搜索有界候选，基于实际模型状态判断读值，不把期望读值赋给 frame 或 sequence。
- replay 接收冻结 plan；实际读值突变立即失败，不调用求解器重新挑选路径。写入的 frame 值仍是模型的声明输入，而非对生产算式的验证。
- oracle 不导入求解器、状态转换函数或前驱构造器；它独立枚举角色链交错并从初态解释。
- oracle 的调度独立性以结构已合法的输入为前提；结构验证由定名反例测试覆盖，不声称存在独立完整 wire/parser 验证器。
- 已修正测试中将“缺少首读”误命名为“缺少末读”的问题，现在两者分别测试。
- 已修正测试辅助函数吞掉 solve-success/replay-failure 的风险；此类不一致现在使整组测试失败，而不是被算作普通拒绝。
- 额外加入整数类型边界及第二个串行 Control episode。输入仍是程序内 dataclass，不是任意不可信 JSON 或生产 tape parser。

## 后续生产工作前必须补齐

1. 从完整可信 tape/配置提取所有受支持操作及跨域边，而不是从摘要补造缺失观察。
2. 沿已存在的 author Live admission 排除链补真实配置拒绝测试并固定输入身份；扩大到通用 Runtime 前才需要新增覆盖或更强白名单。排除 crossfade 不足以证明普通 readiness 的 consumed/guard/job 依赖。
3. 把单域可行性与 sequence、旧 calendars、所有权及实际 gate 同步联合验证；有限 SC witness 不覆盖一般弱内存行为。
4. 独立检验真实 gate 的同步和持锁路径；模型中的 `held_claims=False` 不是无死锁证明。
5. 使用真实原子操作、完整输出、PCM、EOF 和清理比较进行新版本验收，并单独解决 Render 队列溢出。

本次未修改任何生产源码、协议、准入规则或远端状态；未运行 Host、音频或 Windows。
