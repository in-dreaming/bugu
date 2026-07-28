# TASK-001：冻结 SME 公共契约并建立可编译模块扩展点

## 元数据
- 状态：待实施
- 执行波次：0
- 硬依赖：无
- 协作关系：为全部后续任务提供唯一命名、类型和目录契约
- 预计改动范围：`src/music/`（新增）、`src/bugu_audio.zig`、`build.zig`、`build/sme_steps.zig`（新增）、`tests/sme/contract_test.zig`（新增）

## 目标
交付能被现有 `zig build test` 编译的 SME module skeleton，冻结公共 ID、handle、error、request、receipt、thread annotation、生命周期状态和 task 扩展 seam，使后续任务不再各自定义冲突接口。

## 上下文
当前 `src/bugu_audio.zig` 只汇总 core/device/mixer/assets/events/spatial/acoustic。SME 目标 contract 已在 `setup.md` 第 4 节给出，但代码中不存在。该任务只建立真实可编译契约与无行为 module seam，不宣称任何音乐功能完成。

## 前置条件
- Zig 0.16.0 可运行。
- 当前 `zig build test` 通过，或先记录与本任务无关的基线失败。

## 实施范围
### 必须完成
- 新增 `src/music/root.zig`、`ids.zig`、`errors.zig`、`contract.zig`。
- 定义 FNV-1a 64 stable IDs、opaque generation handles、`MusicError`、`MusicRequest`、`MusicReceipt`、runtime state enum。
- 定义 Game/Control/Worker/Render API thread requirement，使用注释和 compile-time test 固化，不把第三方类型暴露到公共 API。
- 在 `src/bugu_audio.zig` 导出 `music` namespace；不导出未实现 runtime。
- 把 `build.zig` 的 SME 追加点抽到新增 `build/sme_steps.zig`，不改变已有 step 行为。
- 为后续 module 预留稳定 import 规则，但不得创建返回 success 的空实现。

### 明确不包含
- scheduler、clock、bank、director、mixer group 或播放逻辑。
- C ABI。
- libogg/libopus 或 GPU 工具。

## 设计与执行细节
1. ID 均为 distinct packed/enum wrapper，避免把 StateId 当 SegmentId。
2. handle 至少含 index + generation；默认零值无效。
3. `MusicRequest` 覆盖 set state/parameter/context、stinger、duck、pause/resume/stop；preview seek 必须标为 tool-only。
4. `MusicError` 使用 `setup.md` 的冻结基线；新增错误必须有触发语义测试。
5. `MusicReceipt` 表达 accepted/rejected/planned/executed/cancelled，不把 accepted 当 executed。
6. build seam 只能组织构建，不产生 fake target。

## 接口与数据契约
- ID hash：FNV-1a 64；空字符串禁止；collision 在 bank compiler 检测。
- `MusicRequest.request_id` 单调 `u64`，0 保留为 invalid。
- 所有公共 slice 的所有权必须写明 borrowed/owned 和有效期。
- 错误返回给调用线程；render thread 只产生数值 receipt/counter。

## 文件变更
- `src/music/{root,ids,errors,contract}.zig`：新增公共 contract。
- `src/bugu_audio.zig`：新增 `music` namespace。
- `build/sme_steps.zig`：新增稳定 build extension。
- `build.zig`：调用 extension，不改变已有 commands。
- `tests/sme/contract_test.zig`：类型、hash、handle/error 语义。

## 验证
### 自动化验证
- `zig build test`：现有测试与新增 contract tests 全通过。
- 编译一个只 import `bugu_audio.music` 的最小 test，证明无 miniaudio/gpu 类型泄漏。
### 手工验证
- 不需要。
### 边界与失败场景
- 空 ID、request_id=0、invalid handle、重复 ID 类型误用必须编译失败或返回明确错误。

## 完成定义
- [ ] 单一公共 contract 可编译并由 root module 导出。
- [ ] build seam 不改变现有 demos/tests。
- [ ] 后续 23 个任务引用的名字均已定义或明确标记为该任务新增。
- [ ] 没有空 runtime/stub 被当作成功路径。

## 风险与注意事项
过度提前冻结内部布局会阻塞实现。只冻结公共语义和 stable extension seam；内部 struct 保持私有。

