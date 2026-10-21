SME acceptance scan 诊断补缺，不是新生产修复

基底内容树：78d48eed7e7fabf242a7a0572a944e2c13f2a656（94d77ca）
当前源码提交：2f766bb8db0addb92c23d7a72e228b9b7ea9fd18
当前内容树：63994cdb520eb3ece4ac137a46a830bf96101340
当前提交建立在本轮明确标注的 synthetic 恢复基底之上，不冒称原历史。

仅修改 tests/sme/author_live_default_chronology_test.zig，生产代码不变。
以前 Service 已保存真实逐槽扫描的 states/scanned，但诊断投影遗漏，导致 Windows no_completion 的日志无法区分 queued/running。此次保留 job_slots、scanned、原 representation_complete；输出256字节状态的固定hex编码，0=free、1=queued、2=running、3=completed、255=未观察。有效长度 min(scanned,job_slots,256)，截断、不一致和投影完整性分别标记。未扫描项绝不宣称 free；逐槽观察不等于一致快照或全局时序。

没有新增引擎读、同步或时钟；仅复制既有已初始化证据。固定尾部容量未扩大，仍在真实join后输出。实际诊断存储由225432B增至299160B，固定增加73728B；每条输出的Acceptance另增加512个hex字符及元数据。复制开销仍可能影响时序，覆盖/遗漏标记仍必须保留。

实际验证
- 默认云端 Debug chronology：9/9，通过77.48秒（含冷编译）。新自测逐字节解析真实writer输出；另解析实际native日志32条Acceptance，编码、有效长度和未扫描255全部通过。
- 预声明单次 Worker wait16ms / Control额外delay0：9/9，12.17秒，实际日志30条Acceptance编码通过。原PCM/Stop/Close断言未变。
- Worker16实验没有重现Windows故障，不能证明或排除Windows具体调度/解码延迟，更不能声称解释或修复Windows根因。没有追加别的cadence或时序重跑。
- 94d77ca Windows panel、Debug chronology、ReleaseSafe chronology 的真实失败全部保留；本诊断版本尚未在Windows运行。

补丁：94d77ca-to-2f766bb.patch
8945B，SHA256 b7f8e7a79bf7e1d936956d2aafa0b4b390ee841a1aef6f235f3e972561372217
只能对精确基底内容树应用一次。Git保存源码/计划/结果摘要，不把重建可执行文件当作历史原件。
