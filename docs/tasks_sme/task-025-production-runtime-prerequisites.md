# TASK-025：验证并修复生产 runtime 前置不变量

## 元数据
- 状态：TODO
- Owner：`UNASSIGNED`
- Reviewer：`UNASSIGNED`
- 实施角色：Runtime concurrency / RT safety
- 评审角色：独立 runtime/UI 架构与 QA
- 工作量等级：`L`
- 证据路径：`docs/validation/sme/TASK-025/evidence.md`（脱敏摘要）、`zig-out/sme-validation/TASK-025/`（原始产物）
- 执行波次：0
- 硬依赖：无
- 协作关系：遵守 setup.md 的模块所有权；子交付物分别审查后才允许 epic DONE
- 预计改动范围：见文件变更

## 目标
以可重放的强制交错测试确定 production runtime 基线是否满足顺序、exactly-once 和有界实时要求；只在复现后修复，保持嵌入兼容 contract。

## 上下文
基线 commit `63dec6de2992610865a7a103cede612e28ace203` 的生产链为 ControlRuntime→RenderSnapshot→RuntimeRenderer→Runtime backend，非 Engine-only。静态检查发现两个待验证风险：MPSC push先reserve ring slot再分配global sequence（runtime.zig约140–165），consumer严格等next sequence（约419–442），producer inversion可能阻塞；renderer sync/render（约650–695）可能在Control尚未处理completion时从同一snapshot重启自然结束one-shot。尚未运行复现，不能称确认故障。

## 前置条件
- 获取并记录当前 commit/submodule/toolchain；先跑现有 `zig build test`、runtime-embedding兼容例子。
- setup.md的实时红线、SampleOwner/pin、reserved stop/shutdown与compatibility要求。

## 实施范围
### 必须完成
- 025-A ordering：测试钩子在reserve slot、sequence assignment、publish三个点暂停指定producer；覆盖同ring、normal/reserved交错以及至少4 producer，证明完整队列最终有限步drain并维持定义的接受顺序。若复现死锁/永久gap则修复slot与sequence的线性化协议，不用跳过未知命令掩盖丢失。
- 025-B exactly-once：one-shot少于一quantum，连续render多个callback而不跑controlTick；assert仅一个start、一次finish和PCM脉冲，不可restart。覆盖stop/steal/generation reuse/completion full；若复现则以render-owned generation terminal状态或等价机制修复，不能依赖control及时tick。
- 025-C bounded RT：遍历callback路径，给snapshot acquire重试、pin CAS、reconcile/completion写入明确固定上限和失败语义；争用时复用已持有合法snapshot或输出明确计量的安全路径，不能无限retry或在callback退还最后引用并free。
- 025-D baseline CI：将上述测试加入现有test命令和持续CI（若当前无workflow，新增独立runtime baseline workflow）；验证故意破坏ordering/exactly-once时gate会失败；移除故障后复跑。

### 明确不包含
SME scheduler、Director、music schema或功能实现。本任务不因尚未复现就预先改runtime算法；无需修复时交付测试/审计证据亦可。

## 设计与执行细节
先固定允许的接受顺序和饱和拒绝语义，再跑强制交错；随机压力仅补充。每个修复独立commit/review，附最小失败序列、修复前后结果及compatibility检查。禁止让consumer无限等被后来slot挡住的低seq；禁止取消accepted command却返回success。Terminal实例身份包含generation，旧completion不能杀死复用实例。

## 接口与数据契约
保持现有public API；必要新增诊断hook限定test build。输出经评审的队列线性化、不丢stop/shutdown、render terminal identity、snapshot/pin retry bound和lease生命周期表供001/002消费。

## 文件变更
- `src/runtime/runtime.zig`：测试与仅在复现/审计证明必要时的修复。
- `src/device/device.zig`：仅callback reachability/adapter基线测试。
- `docs/design/runtime-embedding-v1.md`：实施后同步真实保证，不改兼容surface。
- 新增独立runtime baseline CI workflow及测试（位置通过现有build发现规则确定，不伪称当前已存在）。

## 验证
### 自动化验证
现有 `zig build test` 和 `zig build runtime-embedding`（以build中实际step核验）通过；强制producer inversion/finish-before-control fixture有明确最大drain步数和exactly-once断言；release/debug及Windows/Linux都运行。snapshot发布竞争、owner retire、shutdown drain、满completion queue不会UAF/双释放/无限重试。
### 手工验证
审查callback call graph和每个循环上界，不以压力“未挂住”代替证明。
### 边界与失败场景
sequence/generation wrap、slot满、producer被暂停、retire和shutdown竞争、callback sizes1/127/256/300/513、sample少于quantum。

## 完成定义
- [ ] 每个疑点有复现或未复现的准确记录，未复现不冒充不存在风险的数学证明。
- [ ] 若复现，修复后强制交错回归与原有embedding兼容测试通过。
- [ ] callback全部重试有固定上界，lease生命周期可审计。
- [ ] baseline CI已跑真实路径且故障注入证明gate有效。

## 风险与注意事项
改动基础并发协议风险高；本任务最多可因基线失败BLOCKED，不能把阻塞延期到SME完成后。不得用sleep碰运气作为唯一oracle。

## 活动日志
- 2026-10-09：文档修订新增实施任务；状态 TODO，未实施或运行测试。
