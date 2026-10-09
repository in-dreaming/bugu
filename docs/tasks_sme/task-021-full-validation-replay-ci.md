# TASK-021：集成并资格验证 SME 全量矩阵、golden replay 与持续 CI

## 元数据
- 状态：TODO
- Owner：`UNASSIGNED`
- Reviewer：`UNASSIGNED`
- 实施角色：QA/CI
- 评审角色：各组件 Owner、CI、安全
- 工作量等级：`XL`
- 证据路径：`docs/validation/sme/TASK-021/evidence.md`（脱敏摘要）、`zig-out/sme-validation/TASK-021/`（原始产物）
- 执行波次：15
- 硬依赖：TASK-004、TASK-010、TASK-011、TASK-012、TASK-013、TASK-014、TASK-015、TASK-016、TASK-020、TASK-026
- 协作关系：TASK-001 建立 CI scaffold/test registration；各任务持续注册自身 gate；本任务拥有最终 full-matrix wrapper/CI 集成与资格验证，TASK-022 追加独立 stress 入口
- 预计改动范围：`tests/sme/`、`tools/run_validation.ps1`、TASK-001 已新增的 `.github/workflows/sme-validation.yml`（扩展）、`zig-out/sme-validation/`、`docs/validation/sme/`

## 目标
把全部v1正常、边界、失败、deterministic replay和demo路径接入一个可重复headless gate与CI artifact链。

## 上下文
各任务自身测试不能替代跨组件矩阵。TASK-001 必须从 module scaffold 起建立实际 PR/push headless CI 和注册机制；TASK-002 起每个任务在同一 gate 持续加入测试、fixture 和失败传播。本任务是完整 v1 的矩阵整合与 qualification，不是首次建立 CI，不能将此前任务的持续验证延期到完整 demo 之后。

## 前置条件
- 完整demo和所有runtime能力。
- trace/replay schema稳定。
- TASK-001 scaffold workflow 和各已完成任务的 CI 注册/历史失败演练证据可追溯；缺失需退回负责 owner 补齐，而非本任务第一次开通。

## 实施范围
### 必须完成
- unit/integration/failure tests索引，验证每项架构能力至少一个owner和case。
- golden schedule replay：相同完整输入 bit-identical。输入包括 bank/hash/seed/save state、accepted request frame/sequence/control epoch、readiness snapshots、worker completion/failure/cancellation 接受顺序、device lost/reopen/recovery policy 和影响调度的 quantum/frontier 信息；不能只录 MusicRequest 内容、只重放输出 commands 或依赖重放主机真实完成顺序。
- PCM tolerance：同target逐sample绝对误差`1e-6`并校验peak/RMS。
- malformed bank/project/tempo/cue/fill/logic/channel/codec/seek矩阵。
- queue/voice/stream/generation/device-discontinuity矩阵。
- 扩展`run_validation.ps1` SME默认headless步骤，GPU author/debug显式硬件步骤。
- 扩展 TASK-001 已新增的 GitHub Actions workflow `.github/workflows/sme-validation.yml`：pull request/push 的 Windows + Linux headless SME gate 持续覆盖所有已交付能力，失败即非 0；GPU/device/8 小时 gate 只在带明确 label 的受管 runner 上运行且不得伪装成 hosted gate。
- artifact 名固定为 `sme-validation-<commit>-<runner-os>-<profile>`，内容根为 `zig-out/sme-validation/`，携带 versioned manifest 和 SHA-256；GitHub retention 为 14 天。

### 明确不包含
- 8小时/真实device长期gate；TASK-022。
- 修复被发现的跨任务产品bug；退回owner任务，不能在validation里绕过。

## 交付检查点

- `T021-A / RequirementsMatrix`：输入为setup 全部27任务、各任务当前commit验收与 fixture metadata；产物为 versioned capability→owner→case/command→oracle 索引、fixture license/hash index 和 golden update policy；检查所有 27 任务和完整 v1 requirements 无空行/重复所有者/未实施 required gate。
- `T021-B / DecisionReplayMatrix`：输入为T021-A case index、TASK-004 完整 replay 输入、各 owner 已验证的独立 oracle；产物为完整 accepted-input logs、跨 target golden schedules、独立 tempo/media/DSP oracle 汇总；在 readiness/worker/device 故障顺序和 scheduling 扰动下重算，缺记录/改字段/变算法必须失败，PCM 容差单列。
- `T021-C / HeadlessGatePackaging`：输入为TASK-001 既有 scaffold/registry、T021-A/B cases 与各 task commands；产物为扩展 wrapper、机器 report/human summary、artifact manifest/hash/脱敏/retention；测试 command 非零传播、artifact 不可写、private 字段拒绝、故意坏 fixture 失败且不自动更新 golden。
- `T021-D / ContinuousCiQualification`：输入为T021-C wrapper/artifacts、既有 workflow/注册历史与受管 runner manifest；产物为扩展既有 workflow、从 TASK-001 起的注册审计、受管 GPU/device runner 条件与最终 full-matrix 演练；受控失败验证 PR gate 阻断，缺硬件显示未执行/失败且 release verdict FAIL，不能绿色静默跳过。
- 每片独立 Reviewer、commit、commands 和产物 hash；A→B/C→D，全部通过后整体进入 `REVIEW`。

## 设计与执行细节
1. 每个 command 记录版本、commit、逻辑 input ID/hash、repo-relative output、profile 和结果；遵守 `setup.md` 4.10，不记录绝对路径、用户名、机器名或设备序列号。
2. golden更新需显式命令和review，测试不自动accept。
3. GPU请求缺环境必须fail，不fallback。
4. fixture生成确定，不依赖网络。
5. report 机器可读并有 human summary。Artifact manifest 固定包含 schema version、commit、runner OS/arch、profile、command IDs、artifact repo-relative paths、bytes、SHA-256、classification 和 retention days。
6. 早期 CI 允许某功能尚无实现时仅运行已交付注册项，但每个任务 REVIEW 前其 required tests 必须进入 gate；final v1 qualification 必须要求完整 capability set，任何未注册/跳过/缺环境均不能 PASS。CI scope 的增长与最终 release readiness 分别报告，不以早期绿色冒充完整 v1。
7. 完整 matrix 特别列出 SRC/loop/DC/true-peak/RMS/integrated-LUFS、decoded size→streaming、Seek producer、matching-layout device/offline/FIFO、compound meter/seconds-ramp/oracle、streaming realize、real bus targets、GPU text/IME/focus、公共 runtime 早期纵切和完整生命周期；分别链接负责产物，不新增替代实现。

## 接口与数据契约
新增`zig build sme-validation`、`zig build sme-replay-test`；wrapper可加`-SmeGpu`但默认CPU/offline必须覆盖完整runtime。

## 文件变更
- SME tests/goldens/validation artifacts。
- validation wrapper。
- `.github/workflows/sme-validation.yml`：扩展 TASK-001 创建的唯一 SME CI workflow 入口，不另建晚期平行 gate。
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
- [ ] `.github/workflows/sme-validation.yml` 从 TASK-001 scaffold 起持续在 PR/push 运行已交付 headless gates，最终覆盖完整矩阵；硬件 gate 的 runner 条件不会静默跳过后报告成功。
- [ ] replay 包含全部 accepted-frame 外部输入，在实际 worker 调度扰动下仍重算相同 schedule；缺输入/overflow 明确失败。

## 活动日志

- 2026-07-28：根据评审报告完成规格收口；状态保持 `TODO`，未开始代码实施。
- 2026-10-09：补齐完整 27 任务/子交付证据、完整 replay 输入与从 scaffold 起持续 CI 的资格要求；状态保持 `TODO`。

## 风险与注意事项
不能用宽容阈值掩盖schedule错位；frame/IDs必须exact，只有PCM浮点使用容差。


## 完整跨平台Canonical Corpus Gate
同一ReplayInputV2 corpus与bank/profile/compiler版本在Windows和Linux各运行，独立comparison job逐byte比较ScheduleTraceV2并报告首个差异。全矩阵至少含resident、Opus streaming、worker readiness/失败/取消、预算压力、device loss/reopen/flush、render admission delay及partial-fill取消；026的早期resident corpus不能代替本任务。Device事件重放使用真实RuntimeOffline路径和录制输入，不能宣称它等价真实物理设备gate。任一平台未运行/trace incomplete/版本不匹配皆非PASS。
