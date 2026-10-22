# Headless SME 源码范围

这是从已验证的 Live 候选中提取的独立源码导入，不是合并交付记录分支。保留原 main 的现有目标与无关文件；不导入旧开发历史、验证日志、二进制录制、GPU 作者界面或字体资源。

## 能力和边界

保留公开 audio/music API、实际 Live Host、Opus 编解码、持久化 Live history CLI 和相关原始测试。普通 Host 使用事件通知；现有 semantic/private capture 仍使用 legacy polling。通知模式的真实录制/独立回放支持尚未实现，不能将旧模式的回放通过当作通知模式的证明。

本提取图注册 63 个模块、19 个检查和两个 SME 生产目标：`sme-live-history`、`sme-author-live-production-check`。公共与生产源码保持原字节。构建差异限于选取原注册项，以及仅在对应原测试套件存在时注册三项历史附加 runner；已登记的依赖、文件和检查仍必须存在。

本图不纳入需要旧固定 Opus/f32 oracle 的 `sme-live-initial-headroom-test`、`sme-live-semantic-service-check`，没有删改其测试内部断言来冒充覆盖。生产 Opus API、固定 Ogg/Opus gitlink 和 native C 编译选项保留。完整作者 panel/GPU 应用不在此源码子集内。

## 准备真实输入

需要官方 Zig 0.16.0，以及根 `.gitmodules` 中的固定 miniaudio、Ogg、Opus 子模块。原 main 的 GPU 目标仍在，其依赖需按原目标另外准备，不属于 headless SME 验证。

测试用 16 个 WAV 不进入 Git。使用 Python 3 标准库运行：

    python3 tools/sme/prepare_live_fixtures.py
    python3 tools/sme/prepare_live_fixtures.py --verify-only

脚本使用原全整数合成器和 score，在临时目录生成真实 authored 输入。全部 16 个文件的长度和 SHA256 匹配固定清单后才写入缺失文件，不改 project、期望输出或运行时采样。已有不匹配文件会报错且不会被覆盖；磁盘错误可能留下部分文件，下次运行仍会验证并拒绝不匹配内容。生成素材约 12.3 MB，保留原 MIT 许可和来源说明。

## 验证身份

来源基线的精确 tree 是 `9c2a25a4a9750e098e93a6949749ee717640aae8`。新提取树有独立构建接线，必须单独验证，不能继承来源基线的测试计数。当前文件的初始状态是 UNVERIFIED；每次有界验证计划和真实终态另行记录，不覆盖旧失败。
