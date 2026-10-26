# Bugu：真实 Service 的有限联合 witness 桥接

2026-10-26。测试版 `4b5910bb84cc8e18a7af3837d58ef90b0d8b9eb2`，树 `1521f609dd10e4eaa53fd4f494121647c0f1489f`。

**结论：一个受支持的干净场景已完成 witness → 独立场景检查 → 冻结宏步骤 → 全新真实 Service 的桥接。不是任意历史求解器，也不是生产回放协议修复。**

相对恢复基线 c963aec，只新增两个 Zig 测试文件和 TASK-029 构建片段；所有生产源码、协议、准入、共享构建器不变。旧阶段说明和结果保留为 service-stage-*，其中“下一步 bridge 尚未实现”已由本文件更新。

## 场景和证据

真实资产/Opus 解码、单 stream/单 job、真实 request → worker → accept → publication admit → ack → Ring consume → endRenderSpan → readiness → cancel/close。没有 Host、音频设备、Windows 或实时录制。

先执行真实 Service，既有被动 hooks 复制实际语义点/边界。独立 `check` 函数仅接收复制后的 witness，不接收 Service；核对 startup、宏步骤连续区间、声明的数据/生命周期依赖、job queued/running/completed/free 的实际状态与身份、guard claim/consumed/release、frame/sequence、close generation、selected 与 consumed-prefix 边界。关键 after 事件要求唯一并绑定到实际发出它的 API 步骤。

手写的**单场景声明依赖图**以 enum 次序作确定性拓扑 tie-break，形成冻结宏计划。新 Service 创建前完成检查与冻结；失败不得重选顺序。这里不是从任意 tape 自动抽取完整约束，也不声称检查器能判定所有伪造证据。非关键事件未全量语义判定，但 fresh 执行必须逐点、逐边界和 EOF 完全匹配。

fresh 执行实际 load/store/RMW、读取、job 生命周期、解码与 Ring consume；不会写入预期 readiness、耗时、吞吐或 PCM。唯一回放输入是原始 Worker 外部时钟采样；capture 要求 Linux 实际 native monotonic begin/end 可用、无错误且递增。fresh 按 stage/job 顺序消费这两个原始值，由引擎自己计算派生量。完整 QueryRead、worker/readiness Input、clock trace、handle/job、consumed、单帧 PCM、宏步骤区间及语义点/边界均比较，EOF 精确。

## 阴性验证

在 fresh Service 创建前拒绝：Control query → Render publish 与原依赖相冲突的声明图环、篡改 consumed/frame、job/worker job、slot generation、clock stage/count、未关闭、宏步骤换序/截断、free job identity、Render role。

冻结后另做两次真实 fresh 执行：
- 只把比较副本的 expected frame 改成 99，实际 Service 仍读到 frame=1，返回 ReplayMismatch，不修改实际值求通过。
- 截断原始时钟输入，额外请求得到显式不可用输入并锁存 mismatch，禁止静默 native fallback；完整真实执行后以 ReplayMismatch 拒绝。

此前两个 service adapter 测试另覆盖 sequence odd/change/early return、同值 frame 重写、两 job 扫描、真实 held guard 与 lease 的 close 拒绝、stale generation、当前 author Live crossfade 拒绝；详见 service-stage-README.md。

## 复现

Zig 0.16.0，固定仓库 submodules，Linux；将 Zig cache 配到可写位置。输入 WAV 来自仓库原始生成器并校验散列，不包含在此交付物中。

```sh
python3 tools/sme/prepare_live_fixtures.py
zig build sme-joint-frame-service-check sme-joint-frame-bridge-check -j2 --summary all
zig build sme-joint-frame-service-check sme-joint-frame-bridge-check -Doptimize=ReleaseSafe -j2 --summary all
```

Git 交付不含 bundle、patch、音频或二进制。源码见 source/sme-headless-notified-20261022 的 f4f9efdcd6f638eaf7d6e1a4b58a1170753b4b3f；其树与本地测试版本 4b5910bb 精确一致。源文件清单见 source-manifest.json。原私有归档仍保留原始说明与完整本地历史。

## 已修正的测试问题

初版 bridge Debug 通过；review 加严后曾有 enum literal 编译错误、startup 前缀只计 open 未计 prepare 的错误预期、代际伪造错误优先级断言过旧。仅修测试，保留事实，不是发现生产并发反例。

## 明确边界与下一项决定

这是同步单场景宏步骤执行和测试 hook 下的原子交错验证，不是原生三线程 gate、弱内存证明、死锁证明或任意历史可实现性证明。仅比较一个真实 PCM 帧，不是全流音频等价。未恢复/回放原始失败 tape；未改变 wire-4 UnsupportedOverlap；Render 队列溢出仍独立未解决。

当前决定：**该有限场景可以继续作为后续离线实现的可执行验收样例；不能据此放宽生产准入或宣称回放修复。** 如继续扩大能力，应先单独提出多 job/交错的约束提取与原生 gate 设计及审查，再改变协议。不要以本测试通过替代生产授权或音频性能验收。
