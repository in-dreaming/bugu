# T009 Acoustic scene、voxel、materials、portal 设计

状态：TODO  
类型：Research+Design  
优先级：P1/P2  
依赖：T008  
预计产物：docs/design/acoustic-scene.md

## 1. 背景

复合声学传播不能直接依赖渲染 mesh。需要专用 acoustic scene，表达空气、固体、材质、厚度、门窗洞口、动态障碍、room/portal/probe。

## 2. 必读

- docs/design/audio-engine-design.md 第 10 节
- Back2Gaming Vericidium ray-traced audio 文章
- Steam Audio 和 Project Acoustics 相关参考

## 3. 设计范围

必须设计：

- AcousticScene 数据结构。
- AcousticVoxelGrid 或 SDF 表示。
- AcousticMaterial 3-band 或 4-band 参数。
- Portal/opening 表示：门、窗、洞、山洞出口。
- DynamicObstacleLayer：门、移动墙、可破坏物。
- Room/Zone graph。
- ProbeField，用于 late reverb 统计。
- 场景更新策略：全量 build、局部 brick update、dynamic overlay。

## 4. 必须回答的问题

1. voxel 分辨率如何选择？如何做 LOD？
2. 薄墙、厚墙、空洞如何表达？
3. 门开关如何映射到 portal area 或 dynamic obstacle？
4. 材质参数从哪里来？设计师如何编辑？
5. CPU 和 GPU backend 如何共享同一份声学场景语义？
6. 什么时候需要 offline bake，什么时候 runtime voxel 足够？

## 5. 验收标准

- 输出数据结构草案和更新流程。
- 覆盖无墙、厚墙、墙洞、门开关、山洞、开阔地六类 case。
- 明确材质频段模型。
- 明确与渲染/物理场景的同步边界。
- 不把声学场景简化为渲染 mesh raycast。
- 明确 fallback 表示：没有 voxel/SDF 时哪些 case 不能验收，哪些可用简化 primitive scene 先验证。
- 给出最小 test scene 数据格式，供 T010 直接实现，不允许 T010 重新发明场景输入。

## 5.1 防偏移检查

- 声学 scene 必须包含厚度、材质、portal/opening、dynamic layer；只写 triangle raycast 方案不合格。
- 设计必须支持 CPU 和 GPU backend 共享语义，不能绑定某个 backend 的私有结构。

## 6. Activity Log

- 2026-07-07：任务创建。
