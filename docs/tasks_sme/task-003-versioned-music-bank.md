# TASK-003：实现版本化 MusicBank schema 与 compiler core

## 元数据
- 状态：TODO
- Owner：`UNASSIGNED`
- Reviewer：`UNASSIGNED`
- 实施角色：Asset Schema/Compiler
- 评审角色：资产运行时、兼容性、安全
- 工作量等级：`L`
- 证据路径：`docs/validation/sme/TASK-003/evidence.md`（脱敏摘要）、`zig-out/sme-validation/TASK-003/`（原始产物）
- 执行波次：2
- 硬依赖：TASK-001
- 协作关系：TASK-007/008/009/010/011/016/017 共享本任务 schema；本任务是表结构唯一所有者
- 预计改动范围：`src/assets/music_schema.zig`、`src/assets/music_bank.zig`、`tools/sme_compiler/schema.zig`、`tests/sme/music_bank_test.zig`（均新增），`src/assets/bank.zig`

## 目标
交付可确定性编译和严格加载的 binary MusicBank v1，包含所有 v1 table、capability、hash、generation 和旧 bank 隔离规则。

## 上下文
当前 bank 是未版本化 `[[sounds]]` TOML + mono float blob。SME 需要跨表引用和完整能力检查；宽松忽略未知字段会产生不可审计行为。

## 前置条件
- TASK-001 的 IDs/errors、compiler pass/validator 注册点和从 scaffold 起运行的 CI。
- 源格式固定为版本化 TOML project；compiled bank 是 runtime 唯一输入。

## 实施范围
### 必须完成
- Header、String/Sound/State/Parameter/Context/Theme/Segment/Selector/Layer/Transition/Tempo/Cue/Fill/Stinger/Logic/Curve/Bus/Sidechain/AcousticProfile/Platform/Codec/Chunk/Seek tables。
- `major.minor`、capability bits、SHA-256 content hash、generation。
- FNV ID collision、offset/length/overflow、UTF-8、cross-reference 校验。
- deterministic serialization；相同输入 byte-identical。
- legacy bank 明确走旧 loader，不自动升级。
- compiler core 先能处理 `tests/fixtures/sme/minimal-v1/` 中的最小合法 bank；fixture 必须含每个 required table 的最小记录和明确许可证/生成说明。特定表的深层语义由后续任务扩展同一 validator registry。
- 在 `docs/design/sme-music-bank-v1-layout.md` 冻结 header、table directory、alignment、endian、offset/length、capability 和 table count 上限。

### 明确不包含
- tempo grid 算法、Opus decode、transition 求解、GUI。
- 把缺失表写成空 success；完整 capability bank 缺表必须失败。
- 本任务不实现 SRC/媒体扫描/Opus seek 算法；TASK-010 提供唯一媒体导入 pass，TASK-017 只编排和展示，禁止重复实现。

## 设计与执行细节
1. Header 使用固定 endian、size/version/capability。
2. 所有表索引在 load 时一次校验；runtime 不字符串查找。
3. unknown required capability 失败；unknown optional debug section 可跳过。
4. builder 分离 source AST、validated IR、runtime binary。
5. compiler report 列出 hash、counts、budgets、warnings/errors。
6. 每个 table 的最大 count、总 bank bytes 和 blob/chunk 上限必须进入 schema constants、loader 校验和 layout 文档，禁止仅依赖 `usize` 或 allocator 失败。
7. 本任务拥有 `AudioImportPolicyV1`、`AudioQualityReportV1`、`StreamStorageDecisionV1`、Seek/Chunk 输出 schema；TASK-010 是这些媒体产物的 producer，TASK-011 是消费者。Bank build 在媒体 pass 缺失/失败、report hash 与音频不匹配、流式资产缺 seek/chunk 表时失败，不允许 registry 未注册就略过 required pass。
8. MusicBank 的音乐 sample 时间域固定为 48,000 Hz。Source sample rate、channel layout、SRC algorithm/version/hash、转换后 frame 数与 cue/loop remap 结果写入 import report；任何运行时 bank/sample-rate 不匹配明确拒绝。旧 SFX/device sample-rate contract 不因音乐导入规则隐式改变。
9. `resident_limit_bytes` 是每个 segment 的全部 stems 解码后 float32 bytes 总和上限，按 `sum(frame_count * channel_count * 4)` checked arithmetic 计算，不能按压缩文件大小判定。base profile 默认 16 MiB，profile 必须显式序列化取值；严格大于上限强制编译 streaming descriptor，即使源声明 resident 也报告 `ForcedStreaming`。等于上限可 resident；resident emergency 超限则 `EmergencyMustBeResident` 构建失败，不允许自动流式或任意扩大上限。实际平台总 resident bytes 另受 TASK-006 总预算限制。

## 接口与数据契约
- `MusicBank.load` 返回 owned immutable generation。
- `InvalidBankVersion`、`UnsupportedCapability`、`InvalidMusicGraph`、hash mismatch 分开。
- content hash 不含非确定时间戳；build metadata 单独存放。
- `AudioQualityReportV1` 必须含采样峰值 dBFS、true peak dBTP、每声道及汇总 RMS、integrated loudness LUFS、DC、loop seam 连续性、测量窗口/算法版本/阈值/profile hash、pass/warn/fail；silence 的 LUFS 用显式 undefined/silence 状态，禁止 JSON NaN/Inf。Schema 不以 RMS 代替 integrated loudness。
- `SeekEntryV1` 至少含 logical decoded PCM frame、Ogg page byte offset、granule position、packet/recovery offset、preroll/discard frames、stream serial/link ID；定义见 TASK-010，frame 原点一律为补偿 pre-skip 后首个可听 sample。

## 文件变更
- 新增 schema/bank/compiler/test 文件与 `tests/fixtures/sme/minimal-v1/`。
- `docs/design/sme-music-bank-v1-layout.md`：新增可审查的二进制布局和 table 索引。
- `src/assets/bank.zig`：只增加显式 legacy/music dispatch seam，保留旧格式。

## 验证
### 自动化验证
- `zig build test`。
- golden binary round-trip、重复构建 hash/bytes、truncated/overflow/bad endian/bad version/missing table/collision/bad reference/hash mismatch。
- media-pass 未注册不得构建 full-capability bank；storage gate 在 decoded bytes=limit−4/limit/limit+4、multi-stem 合计超限、乘法溢出、resident emergency 超限时有独立断言；TASK-010 的真实导入产物接入后重跑，schema fixture 不冒充媒体分析验收。
### 手工验证
- 不需要。
### 边界与失败场景
- 0 entries、超大 count、交叠 blob、unknown capability、旧 bank 被误送 music loader。

## 完成定义
- [ ] 本任务已交付测试/fixture 通过 TASK-001 的稳定注册 seam 加入既有 `zig build test`/PR gate，证据随子交付持续产生，不等待 TASK-021 首次接入 CI。
- [ ] 所有 v1 tables、capability 位、table 索引和容量上限存在。
- [ ] 最小合法fixture可从prevalidated IR及checked-in媒体报告golden经builder确定性序列化、加载并round-trip；真实源音频构建由TASK-010验收。
- [ ] loader 对 malformed 输入 fail closed。
- [ ] 相同输入 byte-identical。
- [ ] 旧 bank 测试保持通过。
- [ ] 导入、质量、seek producer/consumer 和 decoded resident size gate 的 schema/所有者/错误均明确；未完成生产媒体 pass 时不报告完整 compiler 产品通过。

## 活动日志

- 2026-07-28：根据评审报告完成规格收口；状态保持 `TODO`，未开始代码实施。
- 2026-10-09：补齐实际依赖、量化/输入契约、独立审查产物与持续 gate；仅修订任务文档，状态保持 `TODO`。

## 风险与注意事项
后续任务只能通过注册的 table validator/IR extension 扩展，不得 fork 第二种 MusicBank。



## Schema交付与真实媒体集成的依赖边界
本任务DONE验收输入为prevalidated IR及带hash的checked-in media report/PCM golden，只验证serializer、loader、schema约束和缺required pass时fail-closed；不得据此宣称真实音频分析/SRC已实现。source音频→media pass→legal compiled bank的真实集成验收由TASK-010独占，TASK-017再验证CLI编排；003不等待010、不要求010实现作为自己的DONE前提。003的CLI/schema测试模式必须标明IR fixture-only，不能作为production source build绕过required pass。TASK-010消费003已完成schema/builder再交付实际producer，保持单向DAG。
