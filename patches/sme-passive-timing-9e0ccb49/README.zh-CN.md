# SME 被动供给计时诊断：9e0ccb49

## 应用身份

本目录 source.patch 仅适用于基底 f28bee4e4f6cbb0e0b8fdb8d1d4decad37e76fef / tree f8bbbebd01520966237fab954a868c4dd1dee85f。候选为 9e0ccb49f39ed5eeebe4b8d030880726e7810721 / tree 088da407ad1d556f4c831778fe16742ef1a182fd。补丁 SHA256：990572215211ea113b99afd42fe2baa89df488f50dc7bb7730445cf68b4cfa83。

在干净且基底树匹配的副本上先 git apply --check，再应用 source.patch。交付Git提交不等于源码提交；可用临时index独立核对目标tree，勿重复应用原分阶段补丁。

## 改动范围

只有测试诊断变化，没有调整生产供给策略、Worker sleep、buffer容量、retry次数或PCM断言。

- Worker复用本来就取得的真实begin/end时钟样本，不新增Worker时钟或引擎读取；附在原completed事件，不增加每job事件数。
- Control仅在request_queued及有selected job的acceptance诊断回调观察同一个Service Clock，Linux MONOTONIC、Windows QPC换算ns。音频回调不采时钟、不等待、不打印。
- 缺失、不可用、错误、非单调及错误job配对均保留；完成真正join后才扁平输出。
- 新observer在生产构建中剔除，也进入原semantic/bootstrap受限hook拒绝清单，不改变旧可替换clock hook权限或重放合同。

Control的queued时间是实际发布之后的回调观测，不是store线性化时刻；Worker begin可早于该观测。begin/end包含系统调度和观察开销，不等于CPU解码时间或完整Worker任务。任何带诊断的新结果都不能倒推出旧Windows运行的时间原因。

## 实际验证

本源码单次云端Debug默认chronology：10/10通过，生产编译通过，16.16秒，源码守卫不变。真实PCM35840帧、四声部、原Play/Stop执行及关闭清理断言通过。未运行ReleaseSafe或Windows新测试。

纯只读parser的7个合成自测与该次真实stderr解析通过；尾部找到10条身份一致、样本可用的queue→Worker→acceptance关联链，无身份冲突、错误配对或非单调对。事件尾部确有覆盖：Control覆盖8725、Worker覆盖602，54个保留孤立链不伪装成完整链；不声明全局顺序或timing完整性。

实际测试诊断存储从299160增至315640字节，固定增加16480字节；其中Control尾部增加6144、Worker尾部增加10240，其余96为上下文。容量仍为256条Control、128条Worker。生产构建不承担该诊断存储。

当前补丁只补充证据，不修复持续播放故障。此前Windows首次Play已执行的单次正证与持续underrun失败均保留；此前同ELF fresh replay失败也不变。本次没有重录、挑时序重跑或上传原日志/二进制。

## 若另获授权，最小下一次Windows验收

只需此候选的一次Debug默认chronology目标，null backend、无GUI/物理声音，不跑panel或ReleaseSafe，不改变seed策略、容量或delay。先核对目标tree，保留原stderr及失败结果，再用同版本只读parser提取同job的queue观测、Worker原begin/end、acceptance观测、有效性及覆盖标志。若缺覆盖或测试失败，按原结果报告，不自动重跑。

这是待另行授权的建议，不是已运行或已获Windows执行许可。
