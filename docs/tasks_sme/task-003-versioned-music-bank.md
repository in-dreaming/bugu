# TASK-003：实现版本化 MusicBank schema 与 compiler core

## 元数据
- 状态：待实施
- 执行波次：1
- 硬依赖：TASK-001
- 协作关系：TASK-007/008/009/010/011/016/017 共享本任务 schema；本任务是表结构唯一所有者
- 预计改动范围：`src/assets/music_schema.zig`、`src/assets/music_bank.zig`、`tools/sme_compiler/schema.zig`、`tests/sme/music_bank_test.zig`（均新增），`src/assets/bank.zig`

## 目标
交付可确定性编译和严格加载的 binary MusicBank v1，包含所有 v1 table、capability、hash、generation 和旧 bank 隔离规则。

## 上下文
当前 bank 是未版本化 `[[sounds]]` TOML + mono float blob。SME 需要跨表引用和完整能力检查；宽松忽略未知字段会产生不可审计行为。

## 前置条件
- TASK-001 的 IDs/errors。
- 源格式固定为版本化 TOML project；compiled bank 是 runtime 唯一输入。

## 实施范围
### 必须完成
- Header、String/Sound/State/Parameter/Context/Theme/Segment/Selector/Layer/Transition/Tempo/Cue/Fill/Stinger/Logic/Curve/Bus/Sidechain/AcousticProfile/Platform/Codec/Chunk/Seek tables。
- `major.minor`、capability bits、SHA-256 content hash、generation。
- FNV ID collision、offset/length/overflow、UTF-8、cross-reference 校验。
- deterministic serialization；相同输入 byte-identical。
- legacy bank 明确走旧 loader，不自动升级。
- compiler core 先能处理最小完整结构；特定表的深层语义由后续任务扩展同一 validator registry。

### 明确不包含
- tempo grid 算法、Opus decode、transition 求解、GUI。
- 把缺失表写成空 success；完整 capability bank 缺表必须失败。

## 设计与执行细节
1. Header 使用固定 endian、size/version/capability。
2. 所有表索引在 load 时一次校验；runtime 不字符串查找。
3. unknown required capability 失败；unknown optional debug section 可跳过。
4. builder 分离 source AST、validated IR、runtime binary。
5. compiler report 列出 hash、counts、budgets、warnings/errors。

## 接口与数据契约
- `MusicBank.load` 返回 owned immutable generation。
- `InvalidBankVersion`、`UnsupportedCapability`、`InvalidMusicGraph`、hash mismatch 分开。
- content hash 不含非确定时间戳；build metadata 单独存放。

## 文件变更
- 新增 schema/bank/compiler/test 文件。
- `src/assets/bank.zig`：只增加显式 legacy/music dispatch seam，保留旧格式。

## 验证
### 自动化验证
- `zig build test`。
- golden binary round-trip、重复构建 hash/bytes、truncated/overflow/bad endian/bad version/missing table/collision/bad reference/hash mismatch。
### 手工验证
- 不需要。
### 边界与失败场景
- 0 entries、超大 count、交叠 blob、unknown capability、旧 bank 被误送 music loader。

## 完成定义
- [ ] 所有 v1 tables 与 capability 位存在。
- [ ] loader 对 malformed 输入 fail closed。
- [ ] 相同输入 byte-identical。
- [ ] 旧 bank 测试保持通过。

## 风险与注意事项
后续任务只能通过注册的 table validator/IR extension 扩展，不得 fork 第二种 MusicBank。

