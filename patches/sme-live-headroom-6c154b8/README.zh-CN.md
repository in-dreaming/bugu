# SME 初始 Live 供给余量：增量源码交付

本目录通过 Git 同步一份纯文本源码补丁，不是已合并到 main 的修复，也不是完整候选源码分支。交付分支基于仓库 main 的 `c9628460a07cea3f5e432e88c09169d4385df672`，只新增本说明与补丁文件，不修改项目源码或 main。

**不能把补丁直接应用到远端 main，也不能将本交付提交号当作候选源码提交号。** 补丁依赖此前已经恢复到 `6f3fb3a` 源码树的验收副本。没有该基线源码或此前补丁时，请停止；本目录不能独立恢复完整项目。

## 源码身份与校验

- 基线来源提交：`6f3fb3a30a0202048863af5f4a78c919e044b040`
- 必须匹配的基线树：`49098fa120fe090e3c81c320bca9161d16d749d1`
- 候选来源提交：`6c154b876eb8f837fa617756d6b1b81f4fe25f6e`
- 应用后必须匹配的候选树：`6e2ad9f1b59a78257c06a5d7710d4ab2e24af58b`
- 补丁：`checkpoint-6f3fb3a-to-6c154b8.patch`
- 补丁大小：45,820 字节
- 补丁 SHA-256：`de6d2296c77392ff5ad9dd38db5602d82c35286f537079a3672b3863506fb857`

补丁逐字节匹配上述两个源码提交之间的 `git diff --binary --full-index`，实际内容为 UTF-8 文本，无二进制补丁段。它仅修改 8 个路径、增加 584 行并删除 7 行。已在独立临时索引中实际应用，得到上述目标树；此操作只校验补丁，不编译、不运行测试，也不操作 Windows 副本。

## 范围

初始 chronology Live Play 等待四个流真正可见且已由 Control 承认的 PCM 余量达到已有 high-water（默认 6,144 帧），再发布初始播放。播放环仍为 8,192 帧。信用来自真实 Render visibility 回执，不填入预期就绪或 PCM 值，不要求 Recorder，也不阻塞音频回调。

补丁包含相关回执专测、默认 Host 诊断、固定 Control 间隔实验入口和用法更新。该初始准备条件增加真实首播准备延迟，不保证任意调度停顿下持续供给无 underrun。旧 direct Live/offline serial API 不使用此 chronology-only gate。

涉及路径：

- `build_support/sme_tasks/task-017.zon`
- `docs/sme/author-live-owner-usage.md`
- `src/music/resident_runtime.zig`
- `src/streaming/music_stream.zig`
- `tests/sme/author_live_default_chronology_test.zig`
- `tests/sme/author_live_default_mode_test.zig`
- `tests/sme/live_initial_headroom_test.zig`
- `tools/sme_authoring/core/live_owner.zig`

## 安全应用（手动操作说明）

先把本目录两份文件下载到验收仓库以外的目录，避免交付文件本身改变源码树。检查补丁哈希：

```powershell
(Get-FileHash -Algorithm SHA256 'C:\path\to\checkpoint-6f3fb3a-to-6c154b8.patch').Hash.ToLowerInvariant()
```

输出必须等于上面的 SHA-256。然后进入此前恢复正确的源码工作目录，先备份自有修改，并执行：

```sh
git status --short
git diff --quiet
git write-tree
```

`git diff --quiet` 必须退出成功，表示跟踪工作文件与索引相同。索引相对 HEAD 保留此前补丁的 staged 改动是允许的；不要求 HEAD 等于来源提交，也不需要本地存在该提交对象。`git write-tree` 必须输出基线树 `49098fa120fe090e3c81c320bca9161d16d749d1`。若有冲突、未暂存修改、树不匹配或未跟踪文件与补丁路径冲突，停止，不强行应用。

确认基线后，使用下载文件的实际路径依次执行：

```sh
git apply --check --index /path/to/checkpoint-6f3fb3a-to-6c154b8.patch
git apply --index /path/to/checkpoint-6f3fb3a-to-6c154b8.patch
git write-tree
```

每一步都须成功，最后必须输出候选树 `6e2ad9f1b59a78257c06a5d7710d4ab2e24af58b`。如果不符，停止并保留现场；不要用 reset、强制、忽略空白或三方应用绕过基线检查。应用后源码处于已暂存状态，本说明不自动提交或改变 Git 身份，也不声称重建了候选提交历史。

## 验证边界

本次 Git 同步只验证文件、补丁和源码树身份，不重新运行测试，也不启动 Windows 验收。此前候选云端验证不能替代 Windows 验收；候选新源码仍未完成 Windows 验收。旧 Windows 基线为 14/18 通过，保留 4 项失败，不能称为全通过。

此前候选云端 Debug 完整矩阵为 54/55（保留固定录制容量溢出失败），ReleaseSafe 完整矩阵为 55/55；这些是已有结果，不是本次同步的新测试。完整原始证据不在此目录，不能把这份小补丁当作完整证据包、可运行发行包或离线自包含项目。工具链和锁定依赖仍需既有正确配置；后续 Windows 验收另行安排。
