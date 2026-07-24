# TASK-021：建立 SME 全量自动验证、golden replay 与 CI gate

## 元数据
- 状态：待实施
- 执行波次：11
- 硬依赖：TASK-004、TASK-010、TASK-011、TASK-012、TASK-013、TASK-014、TASK-015、TASK-016、TASK-020
- 协作关系：本任务是`tools/run_validation.ps1`唯一功能所有者；TASK-022追加独立stress入口
- 预计改动范围：`tests/sme/`、`tools/run_validation.ps1`、CI配置（按仓库实际位置新增/修改）、`docs/validation/sme/`

## 目标
把全部v1正常、边界、失败、deterministic replay和demo路径接入一个可重复headless gate与CI artifact链。

## 上下文
各任务自身测试不能替代跨组件矩阵。当前validation wrapper尚不知道SME。

## 前置条件
- 完整demo和所有runtime能力。
- trace/replay schema稳定。

## 实施范围
### 必须完成
- unit/integration/failure tests索引，验证每项架构能力至少一个owner和case。
- golden schedule replay：相同输入bit-identical。
- PCM tolerance：同target逐sample绝对误差`1e-6`并校验peak/RMS。
- malformed bank/project/tempo/cue/fill/logic/channel/codec/seek矩阵。
- queue/voice/stream/generation/device-discontinuity矩阵。
- 扩展`run_validation.ps1` SME默认headless步骤，GPU author/debug显式硬件步骤。
- CI job、artifact archive、失败即非0。

### 明确不包含
- 8小时/真实device长期gate；TASK-022。
- 修复被发现的跨任务产品bug；退回owner任务，不能在validation里绕过。

## 设计与执行细节
1. 每个command记录版本/commit/input/output。
2. golden更新需显式命令和review，测试不自动accept。
3. GPU请求缺环境必须fail，不fallback。
4. fixture生成确定，不依赖网络。
5. report机器可读并有human summary。

## 接口与数据契约
新增`zig build sme-validation`、`zig build sme-replay-test`；wrapper可加`-SmeGpu`但默认CPU/offline必须覆盖完整runtime。

## 文件变更
- SME tests/goldens/validation artifacts。
- validation wrapper。
- CI配置；若仓库无CI目录，新增位置必须在实施证据说明。

## 验证
### 自动化验证
- `powershell -ExecutionPolicy Bypass -File tools\run_validation.ps1`。
- 在故意损坏fixture的临时测试中确认gate非0，测试后恢复fixture。
### 手工验证
- 检查CI artifact包含trace/WAV/report但不包含巨大临时cache。
### 边界与失败场景
- GPU env missing、golden mismatch、trace overflow、flaky ordering、artifact write failure。

## 完成定义
- [ ] 全部v1能力映射到自动case。
- [ ] 默认wrapper真实跑SME headless链。
- [ ] replay/golden不可静默更新。
- [ ] CI失败artifact可诊断。

## 风险与注意事项
不能用宽容阈值掩盖schedule错位；frame/IDs必须exact，只有PCM浮点使用容差。
