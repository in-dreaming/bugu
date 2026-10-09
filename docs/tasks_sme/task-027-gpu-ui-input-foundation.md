# TASK-027：补齐 GPU 作者工具输入与文本基础

## 元数据
- 状态：TODO
- Owner：`UNASSIGNED`
- Reviewer：`UNASSIGNED`
- 实施角色：GPU platform integration / Zig UI
- 评审角色：独立 runtime/UI 架构与 QA
- 工作量等级：`L`
- 证据路径：`docs/validation/sme/TASK-027/evidence.md`（脱敏摘要）、`zig-out/sme-validation/TASK-027/`（原始产物）
- 执行波次：2
- 硬依赖：TASK-001
- 协作关系：遵守 setup.md 的模块所有权；子交付物分别审查后才允许 epic DONE
- 预计改动范围：见文件变更

## 目标
为作者应用与调试器交付可验证的输入、文本、IME、focus和UI基础契约，以及可复现GPU submodule pin；不再把已有C import等同完整UI框架。

## 上下文
当前GPU submodule pin为 `8b0f2bc657775d899dc4d724918a1e6be9ffa450`，`third_party_adapters/gpu/gpu_adapter.zig`只是C import adapter。现有可视化不能证明文本编辑/IME/焦点/复杂控件能力；缺口属于v1工作而非未知外部前提。可视化仍必须in-dreaming/gpu，禁止另引窗口/RHI。

## 前置条件
001固定tool/runtime边界、Zig和submodule约束；核对GPU pin公开API、当前build/toolchain和支持平台。若upstream扩展需另repo写权限，实施者取得明确授权后才做外部写入；本任务文档本身不授权本轮改另repo。

## 实施范围
### 必须完成
- 027-A capability inventory：逐项证明现有pointer/keyboard/window/clipboard/text输入、IME composition/commit、focus、DPI、字体/字形布局的真实可用接口，形成缺口矩阵与版本化Zig adapter contract。
- 027-B platform extension：在允许的GPU仓库流程补所缺平台事件与文本/IME hooks；提交独立可审查patch/commit及测试，由Bugu选择固定可重现pin，不用浮动branch或私接第二RHI。
- 027-C Zig UI foundation：Bugu工具侧建立event dispatch、focus/capture、text edit model、selection/clipboard、Unicode/IME composition、glyph atlas/text layout、DPI缩放与基础widgets；不把music业务logic放入GPU仓库。
- 027-D integration smoke：用真实GPU窗口演示鼠标/键盘导航、中文IME composition/cancel/commit、焦点切换、剪贴板、多行文本/选择、拖动capture、DPI/window resize、关闭重开和资源释放。

### 明确不包含
graph/timeline/music editors及live tuning由018负责，runtime调试业务由019负责。不在本轮文档修订中实际改GPU仓库。

## 设计与执行细节
各slice有自己的输出和review，GPU扩展与Bugu adapter分开验收。input/text事件排队给UI thread，不进入audio render；shader/glyph资源预建/工具线程管理。公开文本API明确UTF-8与composition范围单位，拒绝无效边界，focus loss不得重复提交composition。保存文档快捷键不抢IME组合键。

## 接口与数据契约
versioned InputEvent/TextComposition/FocusEvent、logical/physical pixel转换、text buffer grapheme/byte offset约定、font fallback/许可证和atlas上限。基础schema/fixture先交付，真实实现/pin验收后018/019才可完成。

## 文件变更
- `third_party_adapters/gpu/`：Zig API适配与能力版本验证；不再仅靠C import。
- `third_party/in_dreaming_gpu`：仅在获准且扩展资格通过后更新固定gitlink；记录旧/新pin及迁移测试。
- 新增 `tools/sme_ui/`：共享Zig UI基础（不含music业务），以及独立input/text smoke。
- build注册遵循001稳定扩展；TASK-018/019只消费该公共模块。

## 验证
### 自动化验证
input/focus/text状态机纯Zig tests进`zig build test`；真实GPU smoke新增命令由本任务注册后可用，明确区分headless状态机和window/IME证据。记录Windows/Linux各目标build和pin。
### 手工验证
真实中文IME、composition取消/重复enter、焦点丢失、窗口切换、DPI、剪贴板；录制结构化事件和截图（不含用户私人输入）。
### 边界与失败场景
GPU不可用、字体缺失、无IME、失焦释放capture、Unicode组合字符、长文本、事件队列满。缺少平台能力明确BLOCKED，不能用另一framework或headless结果代替。

## 完成定义
- [ ] 输入/text/IME/focus/UI能力与许可证矩阵有实际证据。
- [ ] 新pin与adapter可复现，缺口补丁独立审查。
- [ ] 真实窗口smoke通过，音频thread不受UI/GPU wait影响。
- [ ] 018/019可只读setup+自己的任务消费明确模块契约。

## 风险与注意事项
upstream扩展可能是外部阻塞，需记录具体缺口和负责人，不能把UI基础工作隐藏在018的“接GPU”一句话里。

## 活动日志
- 2026-10-09：文档修订新增实施任务；状态 TODO，未实施或运行测试。
