# TASK-021：建立 SME 全量自动验证、golden replay 与 CI gate

## 元数据
- 状态：TODO
- Owner：`UNASSIGNED`
- Reviewer：`UNASSIGNED`
- 实施角色：QA/CI
- 评审角色：各组件 Owner、CI、安全
- 工作量等级：`XL`
- 证据路径：`docs/validation/sme/TASK-021/evidence.md`（脱敏摘要）、`zig-out/sme-validation/TASK-021/`（原始产物）
- 执行波次：11
- 硬依赖：TASK-004、TASK-010、TASK-011、TASK-012、TASK-013、TASK-014、TASK-015、TASK-016、TASK-020
- 协作关系：本任务是`tools/run_validation.ps1`唯一功能所有者；TASK-022追加独立stress入口
- 预计改动范围：`tests/sme/`、`tools/run_validation.ps1`、`.github/workflows/sme-validation.yml`（新增）、`zig-out/sme-validation/`、`docs/validation/sme/`

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
- 新增 GitHub Actions workflow `.github/workflows/sme-validation.yml`：pull request/push 的 Windows headless SME gate，失败即非 0；GPU/device/8 小时 gate 只在带明确 label 的受管 runner 上运行且不得伪装成 hosted gate。
- artifact 名固定为 `sme-validation-<commit>-<runner-os>-<profile>`，内容根为 `zig-out/sme-validation/`，携带 versioned manifest 和 SHA-256；GitHub retention 为 14 天。

### 明确不包含
- 8小时/真实device长期gate；TASK-022。
- 修复被发现的跨任务产品bug；退回owner任务，不能在validation里绕过。

## 交付检查点

1. validation matrix、fixture index 与 golden update policy 通过 QA/owner review。
2. headless wrapper、artifact manifest、脱敏与 retention 通过 CI/security review。
3. GitHub workflow、受管硬件 runner 条件和失败传播通过受控演练。
4. 以上检查点全部有当前 commit 证据后才可整体进入 `REVIEW`。

## 设计与执行细节
1. 每个 command 记录版本、commit、逻辑 input ID/hash、repo-relative output、profile 和结果；遵守 `setup.md` 4.10，不记录绝对路径、用户名、机器名或设备序列号。
2. golden更新需显式命令和review，测试不自动accept。
3. GPU请求缺环境必须fail，不fallback。
4. fixture生成确定，不依赖网络。
5. report 机器可读并有 human summary。Artifact manifest 固定包含 schema version、commit、runner OS/arch、profile、command IDs、artifact repo-relative paths、bytes、SHA-256、classification 和 retention days。

## 接口与数据契约
新增`zig build sme-validation`、`zig build sme-replay-test`；wrapper可加`-SmeGpu`但默认CPU/offline必须覆盖完整runtime。

## 文件变更
- SME tests/goldens/validation artifacts。
- validation wrapper。
- `.github/workflows/sme-validation.yml`：唯一 SME CI workflow 入口。
- `zig-out/sme-validation/TASK-021/manifest.json`：raw artifact manifest；`docs/validation/sme/TASK-021/evidence.md` 保存脱敏摘要。

## 验证
### 自动化验证
- `powershell -ExecutionPolicy Bypass -File tools\run_validation.ps1`。
- 在故意损坏fixture的临时测试中确认gate非0，测试后恢复fixture。
### 手工验证
- 检查 CI artifact 只包含 manifest 标为 `public` 的 trace/WAV/report/JSON，拒绝 cache、source stems、recovery、absolute paths 和 `local_only` 字段；确认 retention-days=14。
### 边界与失败场景
- GPU env missing、golden mismatch、trace overflow、flaky ordering、artifact write failure。

## 完成定义
- [ ] 全部v1能力映射到自动case。
- [ ] 默认wrapper真实跑SME headless链。
- [ ] replay/golden不可静默更新。
- [ ] CI 失败 artifact 可诊断且 manifest/hash/命名/14 天保留策略固定。
- [ ] `.github/workflows/sme-validation.yml` 在 PR/push 上运行 headless gate，硬件 gate 的 runner 条件不会静默跳过后报告成功。

## 活动日志

- 2026-07-28：根据评审报告完成规格收口；状态保持 `TODO`，未开始代码实施。

## 风险与注意事项
不能用宽容阈值掩盖schedule错位；frame/IDs必须exact，只有PCM浮点使用容差。
