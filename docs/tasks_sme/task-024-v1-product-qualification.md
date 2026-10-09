# TASK-024：执行 SME v1 产品资格审查并给出唯一发布结论

## 元数据
- 状态：TODO
- Owner：`UNASSIGNED`
- Reviewer：`UNASSIGNED`
- 实施角色：Independent Release Qualification
- 评审角色：Release authority、QA、架构
- 工作量等级：`M`
- 证据路径：`docs/validation/sme/TASK-024/evidence.md`（脱敏摘要）、`zig-out/sme-validation/TASK-024/`（原始产物）
- 执行波次：18
- 硬依赖：TASK-018、TASK-019、TASK-021、TASK-022、TASK-023、TASK-025、TASK-026、TASK-027
- 协作关系：最终审查任务；不得代替任何前置任务自身验证
- 预计改动范围：`docs/validation/sme/v1-qualification-report.md`（新增）及只读证据索引

## 目标
逐条对照`setup.md`和`arch_sme.md`完整v1范围，以当前commit的可重复证据给出`PASS`或`FAIL`；只有PASS才允许称SME v1。

## 上下文
任务状态、历史成功或局部测试不是发布证据。审查必须在clean checkout/current commit复跑权威gates并检查产物。

## 前置条件
- 所有硬依赖标记完成且证据存在；若缺失，直接FAIL并列缺口。
- 可用Windows设备、GPU/MSVC环境和8小时报告。

## 实施范围
### 必须完成
- 固定 Gate Matrix，覆盖全部 27 任务和架构能力；列为 `Gate ID`、Requirement、Owner task、Command、Artifact/hash、Artifact commit、Environment/profile、Result、Failure reason、Reviewer。
- clean build/package、headless validation、GPU author/debug smoke、demo、device、8小时报告复核。
- API/schema/package/docs一致性。
- RT safety、anti-mock、fallback、submodule/license审查。
- 当前commit与所有artifact commit/hash一致。
- 明确PASS/FAIL和阻塞项。

### 明确不包含
- 在资格报告中现场实现修复。
- 用“低风险”“基本完成”替代FAIL。
- 将缺失能力移出当前 v1 scope。

## 设计与执行细节
1. 每个acceptance item列命令、artifact、结果、owner。
2. stale artifact或不同commit视为无证据。
3. GPU/device/8小时不能因环境不便豁免。
4. 发现失败退回对应任务，修复后全量重审。
5. 必须逐项核验 TASK-025 的基线事实、TASK-026 的公共 runtime resident 纵切、TASK-027 的 GPU 平台 text/IME/focus prerequisite；以及 TASK-010 的媒体 SRC/质量/Seek producer、TASK-005 的 matching-layout 输出、TASK-007 独立 tempo oracle、TASK-006/012 的真实 streaming/DSP 依赖。任何子交付缺独立审查或以 mock/late fixture 替代真实路径即 FAIL。
6. CI 证据需证明 TASK-001 scaffold 即运行、后续功能持续注册且最终 full matrix 未跳过；只附 TASK-021 首次建 CI 的当前绿色日志不能满足持续 gate 验收。
7. 报告首段给唯一结论和通过数/总数。每个 required gate 权重相同，不做加权、豁免或四舍五入；`PASS` 当且仅当 `passed == required_total` 且不存在 missing/stale/mismatched artifact，否则 `FAIL`。

## 接口与数据契约
报告固定章节：Scope、Commit/Environment、Gate Matrix、Commands、Artifacts、Failures、Verdict。Gate result 只能 `PASS`/`FAIL`，总 Verdict 只能 `PASS`/`FAIL`；固定摘要字段为 `required_total`、`passed`、`failed`、`missing`、`stale`，并断言 `required_total == passed + failed + missing + stale`。

## 文件变更
- 新增qualification report；不修改runtime/tooling来制造通过。

## 验证
### 自动化验证
- 复跑TASK-021权威wrapper与package consumer。
- 校验 TASK-022 报告 duration、device matrix、profiling overhead 和 metrics。
- 用故意标记一个 artifact stale/missing 的 qualification fixture 验证总 Verdict 必为 `FAIL`，随后恢复 fixture。
- GPU author/debug smoke。
### 手工验证
- 真实device、authoring workflow、runtime debugger、quick start抽检。
### 边界与失败场景
- artifact缺失/stale、commit不一致、任何v1 capability缺失、fallback冒充、docs命令错误。

## 完成定义
- [ ] `passed == required_total`，且 failed/missing/stale 均为 0；任何一项不满足时 Verdict 为 `FAIL`。
- [ ] 所有权威gates通过。
- [ ] 报告结论无模糊措辞。
- [ ] 27 任务及每个 required 独立子交付都有当前 commit 证据，media/multichannel/tempo/replay/GPU prerequisite/持续 CI 不存在隐性缩范围或未建 owner。
- [ ] 只有PASS时更新对外状态为SME v1。

## 活动日志

- 2026-07-28：根据评审报告完成规格收口；状态保持 `TODO`，未开始代码实施。
- 2026-10-09：补齐完整 27 任务/子交付证据、完整 replay 输入与从 scaffold 起持续 CI 的资格要求；状态保持 `TODO`。

## 风险与注意事项
资格任务最容易把历史局部绿色误判为完成；必须以当前commit真实执行为准。

