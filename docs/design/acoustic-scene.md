# Bugu Acoustic Scene, Voxel, Material, and Portal Design

状态：Draft v0.1  
日期：2026-07-08  
任务：T009 Acoustic scene、voxel、materials、portal 设计  
依赖：T008 spatial baseline

## 1. Goal

The acoustic scene is a runtime representation for sound propagation. It is not a render mesh raycast shortcut. It must encode air/solid classification, material thickness, openings, dynamic obstacles, room/zone topology, and probe data so T010 can compute `AcousticResponse` from scene data rather than from scenario names.

References verified:

- Steam Audio documentation: https://partner.steamgames.com/doc/features/steam_audio
- Microsoft Project Acoustics repository: https://github.com/microsoft/ProjectAcoustics
- Back2Gaming Vericidium technical preview: https://www.back2gaming.com/features/implementing-ray-traced-audio-in-games-a-technical-preview-of-vericidiums-plugin/

## 2. Data Model

```zig
pub const AcousticScene = struct {
    units_per_meter: f32,
    bounds_min: Vec3,
    bounds_max: Vec3,
    voxel_grid: AcousticVoxelGrid,
    materials: []const AcousticMaterial,
    portals: []const AcousticPortal,
    rooms: []const AcousticRoom,
    dynamic_layer: DynamicObstacleLayer,
    probe_field: ProbeField,
    revision: u64,
};
```

Ownership:

- Build/update thread owns mutable scene builders.
- Audio Control Thread receives completed immutable scene snapshots.
- Audio Render Thread never reads mutable scene data and never traces rays.
- CPU and GPU propagation backends consume the same semantic scene snapshot.

## 3. Voxel Grid

```zig
pub const AcousticVoxelGrid = struct {
    origin: Vec3,
    cell_size_meters: f32,
    dims: UVec3,
    bricks: []const AcousticBrick,
    lods: []const VoxelLod,
};

pub const AcousticVoxel = packed struct {
    occupancy: enum(u2) { air, solid, mixed, portal },
    material_id: u14,
    thickness_cm: u8,
    openness: u8,
};
```

Resolution:

- Indoor gameplay spaces: 0.25-0.5 m cells for P1/P2 CPU correctness.
- Outdoor/open world: 1-2 m base grid plus local high-resolution bricks around listener, emitters, portals, and moving geometry.
- Thin walls: mark `mixed` or `solid` cells with `thickness_cm`; do not rely on a single triangle hit.
- Holes/windows/doors: portal cells carry `openness` and link to an `AcousticPortal`.

LOD:

- LOD0 near listener/source/portal.
- LOD1 for room-scale traversal.
- LOD2 for outdoor openness/escape rays.
- Propagation must record confidence when LOD is coarse.

## 4. Materials

```zig
pub const AcousticBands = struct {
    low: f32,
    mid: f32,
    high: f32,
};

pub const AcousticMaterial = struct {
    id: u16,
    name_hash: u64,
    absorption: AcousticBands,
    reflection: AcousticBands,
    transmission: AcousticBands,
    scattering: AcousticBands,
    density: f32,
};
```

Materials come from authoring metadata on physics/render surfaces, with defaults for concrete, glass, wood, metal, fabric, foliage, water, and rock. Designers edit named presets; scene extraction maps render/physics materials to acoustic material ids. Runtime code uses numeric ids and 3-band coefficients only.

## 5. Portals and Openings

```zig
pub const AcousticPortal = struct {
    id: u32,
    room_a: u32,
    room_b: u32,
    center: Vec3,
    normal_a_to_b: Vec3,
    radius: f32,
    area_open_m2: f32,
    max_area_m2: f32,
    material_id: u16,
    state: enum { open, closed, partial, dynamic },
};
```

Doors map animation/open fraction to `area_open_m2`. Windows, holes, cave exits, corridor mouths, and broken walls are all portals. Closed doors can still transmit through material; open doors act as diffraction/leakage paths.

## 6. Dynamic Layer

```zig
pub const DynamicObstacle = struct {
    id: u64,
    bounds_min: Vec3,
    bounds_max: Vec3,
    material_id: u16,
    thickness_cm: u8,
    velocity: Vec3,
    portal_id: ?u32,
};

pub const DynamicObstacleLayer = struct {
    obstacles: []const DynamicObstacle,
    dirty_bricks: []const BrickCoord,
    revision: u64,
};
```

Dynamic geometry is an overlay, not a full rebuild trigger. Doors update portal openness and optionally dirty nearby bricks. Moving walls/vehicles/destruction update dynamic obstacle bounds and a small dirty brick list.

## 7. Rooms, Zones, and Probes

Rooms/zones encode topology and late-reverb context:

```zig
pub const AcousticRoom = struct {
    id: u32,
    bounds_min: Vec3,
    bounds_max: Vec3,
    portal_ids: []const u32,
    default_material_id: u16,
    reverb_preset_id: u32,
};

pub const Probe = struct {
    position: Vec3,
    room_id: u32,
    rt60: AcousticBands,
    density: f32,
    coloration: AcousticBands,
    openness: f32,
};
```

ProbeField is optional in P1 but required for caves/large rooms when late reverb cannot be estimated cheaply at runtime.

## 8. Update Flow

1. Extract acoustic primitives from physics/render/editor scene.
2. Map source materials to `AcousticMaterial`.
3. Build voxel bricks and room/portal graph.
4. Add dynamic overlay for doors, moving obstacles, breakables.
5. Publish immutable `AcousticSceneSnapshot` to propagation workers.
6. CPU/GPU propagation computes `AcousticResponseBuffer`.
7. Audio Control Thread converts responses to `AcousticSnapshot`.

Full rebuild:

- level load, major scene streaming transition, material table change.

Local brick update:

- breakable wall, moved obstacle, local construction/destruction.

Dynamic overlay only:

- door open fraction, vehicle passing, temporary cover.

## 9. Required Cases

| Case | Representation | Expected T010 behavior |
|---|---|---|
| No wall | Air voxels between listener/source | direct path high confidence |
| Thick wall | solid voxels with thickness/material | transmission gain/filter from material depth |
| Wall hole/window | portal cells and `AcousticPortal` | leakage/diffraction from portal direction |
| Door open/close | portal `area_open_m2` plus optional obstacle | smooth response as openness changes |
| Cave | room/zone graph, rock material, probes, cave portal | strong reflection/reverb, outside leakage via entrance |
| Open field | sparse solids, high escape/openness, low probe density | weak reflections, high openness |

## 10. CPU/GPU Shared Semantics

Backends may store private acceleration structures, but they must be derived from:

- voxel grid and LODs,
- material table,
- portal graph,
- dynamic layer,
- room/probe field.

CPU backend may use brick DDA traversal. GPU backend may use compute ray marching or ray queries, but it still outputs the same path terms: direct, transmission, diffraction/portal, reflection, escape/openness, and confidence.

## 11. Fallback Rules

Allowed fallback for T010 correctness:

- Primitive scene format with boxes, materials, and portals that builds an equivalent minimal voxel grid.
- CPU-only voxel propagation when GPU is unavailable.
- No ProbeField for direct/transmission/portal tests.

Not accepted:

- render mesh triangle raycast as the only acoustic scene,
- scenario-name hardcoded responses,
- no material thickness,
- no portal/opening representation for wall-hole/door cases.

Without voxel/SDF or primitive-to-voxel conversion, only no-wall distance tests are valid; thick wall, wall hole, door, cave, and open-field propagation are not accepted.

## 12. Minimal T010 Test Scene Format

T010 should consume this simple data shape directly:

```zig
pub const TestScene = struct {
    bounds_min: Vec3,
    bounds_max: Vec3,
    cell_size_meters: f32,
    materials: []const AcousticMaterial,
    solids: []const SolidBox,
    portals: []const AcousticPortal,
    rooms: []const AcousticRoom,
    probes: []const Probe,
};

pub const SolidBox = struct {
    min: Vec3,
    max: Vec3,
    material_id: u16,
    thickness_cm: u8,
};
```

Required scenes:

- `open_air`: listener/source with all-air grid.
- `thick_wall`: one concrete box between listener/source.
- `wall_hole`: concrete wall plus circular/box portal.
- `door_opening`: two rooms, one portal with openness 0.0/0.5/1.0.
- `cave`: rock corridor room with entrance portal and probe.
- `open_field`: large bounds, sparse distant reflector, high openness.

## 13. Source Notes

Steam Audio is used as a reference for HRTF, occlusion, reflections, paths, reverb, and CPU/GPU acceleration concepts. Project Acoustics is used as an architectural reference for baked wave-acoustic probes/runtime queries, not as a dependency. The Back2Gaming/Vericidium article supports the voxel/ray-family approach and reinforces that dynamic geometry and environment direction are part of the acoustic scene problem.
