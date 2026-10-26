# Bugu Service frame 离线小模型（实验产物）

## 运行

Python 3.10+ 标准库，无安装依赖。在本目录执行 `python3 run_tests.py`。
运行只产生 `results.json`，不调用 Bugu、Host、音频、网络或生产测试。

## 当前结论

这是一个**有限、串行一致见证（SC witness）的标量投影模型**，不是原生回放实现，
不是 Zig/LLVM 弱内存验证器，也不证明丢失的原始录制可回放。

模型中，observed read values 仅用于选择满足约束的规范顺序；回放使用独立初始化的
sequence/frame 状态执行读，再比较实际结果。不会把期待读值写入状态。
回放开始前冻结计划，不匹配立即退出，不换计划直到碰到成功。
frame_write 的值是显式模型输入，不证明真实 Renderer 如何计算它。

支持的封闭集合：单 Service epoch，初始 frame/sequence=0；一个序列化 Render 写者，
一个序列化 Control 读者；最多两次 odd→frame→even 发布；最多两个读 episode，
总最多 12 个操作；值为 0..7，frame 值非递减，无回绕/重置；每个 hook occurrence 唯一。
每个写事件保留独立 ID，即使发布相同值。

控制路径只投影 sequence-before、frame、sequence-after：odd 提前退出；frame mismatch
提前退出且没有 final read；稳定或 sequence_changed 都保留。
真实路径中夹着 consumed、produced、slot guard、worker/job 和错误路径；它们没有被模拟，
所以模型中的 stable **不是生产 Control 操作成功**。

显式排除：control_consumed、其他 Runtime 原子、RMW/CAS 语义、slot 复用、跨代次、ABA/回绕、
crossfade 的未捕获读取、动态 owner/claim、持有 claim 等待 gate、完整生命周期回收、PCM、
所有 weak-memory 行为。生命周期只是已知 birth/death 边界与单 epoch 身份检查。
没有声称生产系统不存在这些行为；实际应用前必须单独审计或拒绝。

## 两套实现与证据

- `frame_model.py`：确定性字典序 DFS，联合 interval order、角色顺序、附加依赖边、实际值约束；
  每次搜索最多 50,000 节点，超限明确拒绝。搜索在离线规划中，不在音频路径中。
- `oracle.py`：独立枚举所有两角色链 shuffle，并从零解释每条完整顺序。
  不调用 solver、apply 或 predecessor builder。oracle 只对结构合法输入核对语义可行性；
  结构验证器由独立固定预期的 malformed tests 覆盖，不冒称独立验证全部 parser。
- `run_tests.py`：完整枚举明确声明的一次发布/一次读取的小宇宙，以及固定反例。
  该枚举不是所有最多 12 操作的穷尽证明。两次发布为定向用例。
- `results.json`：实际计数、判定摘要、时长、测试名。无随机种子，因为穷举确定性集合。

观察到的 before/after hook 总序只导出不重叠 interval 的先后；重叠并不自动确定访问顺序。
模型允许寻找一个合法见证，不推断原始 CPU 线性化时刻。一般 relaxed/acquire-release 执行
未必有这种总序，本模型只接受存在所声明 SC 见证的受限子集。

跨域测试只验证显式提供的约束边与本域共同无环/可执行，并不自动发现所有真实跨域依赖。
两个局部边集合各可行、合并形成环的反例必须拒绝。持锁 gate 目前直接排除，不是假装证明无死锁。

## 历史与范围

源码基线 c963aec1c6b74e17da52ce553520aa7c0e4b5e2f，tree
123baa533e50ffcaa3210ec00b4d977e94ef7b29。生产 checkout 保持原样。
原始 tape 未保存；本模型不填造缺失读值，不转换或接纳那条录制。
Render 队列溢出是独立未解决问题，本模型没有性能或实时资格结论。

初次测试运行在构造跨域环反例时失败：错误地要求 seq=0 的读既可在 odd 前也可在 odd 后。
这是测试前提错误，不是被隐藏的产品失败；现改为同值 frame 发布/读的真正双向可行顺序，
并保留这个说明。无生产改动。

## 验证结果与决策（2026-10-26）

37 个固定预期测试通过；35,840 个声明范围内的穷举输入与独立 oracle 一致：
3,316 接纳、32,524 拒绝。判定序列 SHA256 为
245f3e405200085b5c1651687a4d409da0450b56b858032b3da42fa23c6ef017。
一次本地完整运行约 4.3 秒；该时间仅是离线 Python 小模型成本，不能作为音频开销依据。
两次发布/两次读 episode 只做定向测试，未穷举整个 MAX_OPS=12 空间。

**部分可行，联合生产可行性尚未证明。** 数值约束、同值写身份及联合依赖拒绝可以在
这个小集合内一致工作；但动态跨域边、真实 guard/claim、生命周期及所有可达读取没有完成
端到端映射。不能将“模型 PASS”写成“回放协议已可实施”或“原录制可回放”。

下一步最小有价值的闭环不是继续扩大抽象枚举，而是：做一个**独立 Zig 测试适配器**，
调用固定源码的真实 Service readiness 与 endRenderSpan，通过已有 hooks 施加预定交错，
将真实记录投影到本模型，再按一次冻结计划执行真实操作、核对值与早退结果。
适配器只进入测试产物，不改生产协议，不启动音频；先覆盖 stable/odd/mismatch/changed
四种路径及一个跨两个发布的重叠。必须保留与现有 sequence、consumed、guard/job calendar
的约束；无法构造/完整解释输入或出现依赖环则明确失败，不能假定未知依赖不存在。

四处 runtime_assets 直接读取属于通用 runtime 的 loop/linear crossfade 路径，但当前严格
author Live 已通过 live_admission 与 validateLiveTickProfileStateV1 显式拒绝相关配置。
这不是仅凭 fixture 没触发而推断不可达，也不是本次发现的当前 profile 覆盖漏洞；
下一步应以负向测试锁定这些既有排除，并把 frame 模型与现有 sequence calendar 联合适配。
现有排除是有用的缩小范围，**不是充分证明**：普通 readiness 仍有 consumed/guard/job
等状态域。因此暂不直接实现新生产 profile；先完成真实函数测试适配器和跨域约束映射，
再决定是否具备有限候选资格。

本次没有实现上述下一步，也没有自动扩大授权。
