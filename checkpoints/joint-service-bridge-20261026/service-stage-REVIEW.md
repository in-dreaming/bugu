独立审查通过，范围限定于真实 Service/Ring 的同步测试交错。

仅新增测试与注册文件；生产代码未改。实际frame、sequence、consumed、job、guard及代次生命周期受检查；capture回调仅复制，主动交错仅使用test hook。crossfade拒绝区分普通校验与Live限制。

这不是原生并发、全局无死锁、弱内存或完整回放证明。负向比较是冻结预期不匹配，不是生产故障注入。
