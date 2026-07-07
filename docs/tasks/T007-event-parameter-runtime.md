# T007 Event、Parameter、State、Switch runtime

状态：TODO  
类型：Design+Implementation  
优先级：P1  
依赖：T003，T005，T006  
预计产物：事件系统设计和最小 runtime 实现。

## 1. 背景

游戏逻辑应该 post event，而不是直接播放文件或操作 voice。事件系统是设计师可用性的核心。

## 2. 必读

- docs/design/audio-engine-design.md 第 8 节
- T003 API
- T005 voice handle 设计
- T006 SoundEntry/Bank

## 3. 实现范围

必须实现：

- EventEntry 到 SoundEntry 的映射。
- play_one_shot。
- play_looping。
- stop。
- basic parameter override：volume、pitch。
- random container：从多个 sound variant 中选择。
- State 和 Switch 的数据结构草案。
- RTPC 曲线的数据结构草案，可先不完整实现。

## 4. 验收标准

- 游戏侧只通过 post_event 触发声音。
- 一个 event 可触发一个或多个 sounds。
- random variant 可重复验证，不出现越界。
- stop 能让 voice release，而不是硬切。
- Event runtime 不在 audio render thread 解析复杂字符串。
- 事件 ID/hash 策略明确。
- Evidence 必须显示 post_event -> event resolve -> voice request -> mixer/voice 状态变化的真实链路。
- 如果 State/Switch/RTPC 只完成数据结构草案，任务状态最多 REVIEW，不能把未实现功能计入 DONE。

## 5. 测试场景

- weapon.fire 随机 5 个变体。
- footstep 根据 surface switch 选择 wood/metal。
- ambience loop start/stop。
- volume RTPC 或 parameter override。

## 5.1 禁止 mock

- 不能直接调用内部 voice start/stop 冒充 event runtime。
- random variant 必须由真实容器数据驱动，不能按测试名返回固定 sound。
- 字符串 hash 或 ID 解析必须在非 audio render thread 完成。

## 6. Activity Log

- 2026-07-07：任务创建。
