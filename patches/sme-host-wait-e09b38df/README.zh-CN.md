# SME Host wait 边界诊断：e09b38df

## 应用身份

基底源码 9e0ccb49f39ed5eeebe4b8d030880726e7810721，tree 088da407ad1d556f4c831778fe16742ef1a182fd。
目标源码 e09b38df925020f5877e0ed637d75fad5ea3e681，tree 8ba69a82caabe29ed9a6a55566d90969497b110a。
source.patch SHA256：061f507d7333e6d8072459ff457865fea4bfa50cf857b6cb08b63cdbd29a6c8e。

仅在干净且基底tree匹配的副本上先执行 git apply --check，再应用 source.patch；可用临时index核对目标tree。交付Git提交不是源码提交，勿重复应用分阶段补丁。

## 本次只补证据，不改策略

上一轮Windows同域时钟显示四个相邻Worker样本区间约2.4–2.8ms、批间空档约20ms，以及Control接受观测延迟。此前begin/end并非Host sleep边界，不能据此证明空档全部来自sleep或OS定时器。

本补丁在原两处Host wait调用前后添加测试专用void观察，原sleep参数、4-call循环、catch、park/stop及调度逻辑不变。不加notify、不忙轮询、不增buffer、不调整retry或PCM断言。

Worker摘要只复制原calls、正常worked、失败次数与deferred分支；它不参与调度决策。早期尚未发布的Service Clock通过测试专用release/acquire标记为不可用，绝不读取未初始化Clock或owner。Clock发布后沿用同源MONOTONIC/QPC→ns。音频回调不参与。

每角色独占64个完整wait pair和一个pending，join后输出 DEFAULT_HOST_WAIT_TAIL/EVENT/STORAGE。缺边、错配、非单调、计数耗尽和覆盖均显式保留。原Control256、Worker128事件容量不变。新observer在创建owner前拒绝与semantic capture/replay、legacy capture混用；生产字段和回调编译剔除。

## 实际云端验证

本源码单次Debug默认chronology12/12与生产编译通过，17.16秒，源码守卫相同；四声部PCM36352帧、Play/Stop、16/16来源关闭、零lease/instance及Worker join断言通过。没有运行新的Windows或ReleaseSafe验收。

8个parser合成自测与该次真实stderr解析通过；两角色各保留64对有效样本，8条完整job链可关联Control等待观测。此Linux运行请求1ms的wait观测约1.05–1.14ms，不是Windows故障重现。

诊断存储由315640增至330296字节，本补丁固定增加14656字节。wait尾部真实覆盖Control606对、Worker501对，因此不声称完整性。overlap只代表保留且有效wait观测区间的并集；0不能证明缺失期间没有等待。

## 解释和下一步边界

before→after包含诊断读时钟及线程调度成本，不等于纯内核睡眠或CPU耗时。after只表示原catch后的返回，不证明sleep成功。生产供给策略未修复，旧Windows持续fault与旧fresh replay失败全部保留。实际Zig0.16 Windows等待路径采用parking_sleep/NtWaitForAlertByThreadId，不能仅从API名称推断计时精度。

若另获授权，建议仅一次Windows Debug默认chronology（null backend，无GUI/物理声音，无panel/RS），核对目标tree后保留原始stderr，再运行 inspect_wait_output.py。它依赖同目录固定 inspect_timing_output.py，不要替换版本。按同job时钟与分角色wait pair判断约20ms空档在wait内部还是两侧；缺覆盖按未知报告，不能自动重跑或启用新唤醒策略。

本目录仅源码/脚本/说明和脱敏结果，原日志与二进制不上传；下一次Windows执行仍需单独授权。
