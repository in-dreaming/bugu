# e15de12：诊断输出增量，不是 Windows 欠载修复

本目录只交付纯文本补丁与应用说明。它追加到原 delivery 分支，旧交付文件保留，main 不变；交付提交号不等于候选源码提交号。

**本次仅修正诊断，生产播放行为不变。此前 Windows 欠载失败仍有效，e15de12 尚未进行 Windows 验证。不能把更完整的日志或本轮云端通过当作欠载已解决。**

## 基线与校验

- 基线来源提交：`94f5907d9a58eb19ae2ff8a3fd1b870a7aa23385`
- 必须匹配的基线树：`7544c203628534da89cd65084e65163d272a6e8a`
- 候选来源提交：`e15de1243d23fa67449674ab75fcebe735e9840d`
- 应用后目标树：`9c726fe11f07af1936f365a6b9b505153be93709`
- 补丁：`94f5907-to-e15de12.patch`，57,408 字节
- SHA-256：`f6880415eaf68c5778fc45879e84533753b32322d8b9728b4aeb568b009bbb9c`

补丁与两个来源提交间的 Git diff 逐字节一致：5 个源码/测试路径，增加 525 行、删除 35 行，无二进制段。已在隔离索引实际应用并核对目标树。本目录不包含原始日志、大型证据、ZIP、可执行文件或完整源码历史。

## 诊断修正范围

- 原始 stderr 中 Zig 默认格式的深度截断确实产生字面 `.{ ... }`。本版改为 `schema=1` 扁平字段，显式区分 optional presence/null 与实际零值，保留枚举名字及数值、完整字节 hash。
- 新增 test-only 的 prefetch/request 返回观察，只复制已有局部值，区分 high_water、pending、queued、availability/error 等真实返回路径。不新增引擎状态读、同步或生产返回/dispatch 修改。
- 完整输出在真实 join 后进行，输出或 flush 失败标记不完整。补齐禁止测试钩子进入 semantic/生产资格绑定的 guard；生产编译中测试钩子字段与诊断局部量消除。
- 没有添加新的 Worker 唤醒、缓冲扩容或持续供给调度修复。测试观察仍有真实开销，可能扰动测试时序。

## 安全应用

必须在已有 **94f5907 源码树** 的验收副本应用，不能直接应用到远端 main。先把补丁保存到源码仓库外的目录，备份自有修改，并核验：

```powershell
(Get-FileHash -Algorithm SHA256 'C:\path\to\94f5907-to-e15de12.patch').Hash.ToLowerInvariant()
```

哈希必须匹配上面的值。进入正确的源码目录：

```sh
git status --short
git diff --quiet
git write-tree
```

`git diff --quiet` 必须成功，`git write-tree` 必须输出基线树 `7544c203628534da89cd65084e65163d272a6e8a`。索引相对 HEAD 保留此前补丁的 staged 改动是允许的，不要求 HEAD 等于来源提交。若有未暂存修改、冲突、树不符或未跟踪文件与补丁路径冲突，停止。

将路径替换为实际文件位置，每一步成功后再执行下一步：

```sh
git apply --check --index /path/to/94f5907-to-e15de12.patch
git apply --index /path/to/94f5907-to-e15de12.patch
git write-tree
```

最后必须输出 `9c726fe11f07af1936f365a6b9b505153be93709`。不符时保留现场，不用 reset、强制、忽略空白或三方应用绕过校验。应用后源码处于已暂存状态；不自动创建源码提交、更改 Git 身份或重建候选提交历史。

## 既有验证与明确未验证部分

以下是 e15de12 的已有云端结果，本次 Git 同步未重跑测试：

- Debug：default chronology 8/8 + background supply 4/4，共 12/12，production compile 通过。
- ReleaseSafe：同样 12/12，production compile 通过。
- 两份实际 native stderr 独立解析后各有 8 条完整保留身份链，覆盖 4 个流，从请求排队、Worker 运行/完成到接纳/发布、public Worker 与 stream_visibility admission；选定记录的已输出字段没有深度省略。
- 解析器的 3 个故意损坏格式/身份负例均被拒绝；另有字节级输出测试覆盖深层身份、错误/空/零、fault 状态、尾部覆盖、hash 和输出失败。

**本轮未重跑全兼容矩阵、完整新构建 strict replay 或 CLI 矩阵。94f5907 的历史 strict replay 及其精确 ELF/tape 不能算作本次新构建成绩。** 本次没有 Windows 操作，新 Windows 验收需另行安排。

## 使用诊断时的限制

每条记录形如 `MARKER schema=1 dotted.key=value ...`，按键解析，不依赖字段位置。可选项有 `.present`；缺失不是零。按 handle+generation、job、publication batch、prefix 和 admission 身份关联，不能从跨线程打印顺序推断全局先后，也不能把 Worker 调用次数当作解码完成量。

Control 256 条、Worker 128 条固定滚动尾部未扩容。覆盖、身份缺失、故障后省略等均标记；Control 首个故障冻结自身尾部，Worker 仍可能覆盖。记录完整不等于整个历史完整。缺少链端代表证据不足，不证明事件未发生，也不能把故障后的 defer 当作根因。

若真实 join 失败，不读取共享非原子诊断。输出/flush 故障会尝试写出 `DEFAULT_HOST_DIAGNOSTIC_WRITE_ERROR`，但损坏的 stderr 也可能无法送达该标记。诊断只覆盖专用 chronology 目标，不应泛化为 panel 或所有播放路径的完整证据。
