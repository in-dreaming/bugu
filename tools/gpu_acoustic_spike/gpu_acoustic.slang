RWStructuredBuffer<float> gAcoustic : register(u0);

static const uint STRIDE = 40u;
static const uint CELL_BASE = 16u;
static const uint OUT_BASE = 32u;

[shader("compute")]
[numthreads(1, 1, 1)]
void acousticMain(uint3 tid : SV_DispatchThreadID)
{
    uint scene = tid.x;
    uint base = scene * STRIDE;

    float listenerX = gAcoustic[base + 0u];
    float listenerY = gAcoustic[base + 1u];
    float sourceX = gAcoustic[base + 2u];
    float sourceY = gAcoustic[base + 3u];
    uint cellCount = (uint)gAcoustic[base + 4u];
    float cellSize = gAcoustic[base + 5u];
    float portalX = gAcoustic[base + 7u];
    float portalY = gAcoustic[base + 8u];
    float portalArea = gAcoustic[base + 9u];
    float portalMaxArea = max(gAcoustic[base + 10u], 0.001);
    float portalRadius = gAcoustic[base + 11u];
    float materialTransmissionMid = saturate(gAcoustic[base + 12u]);
    float materialTransmissionHigh = saturate(gAcoustic[base + 13u]);

    float dx = sourceX - listenerX;
    float dy = sourceY - listenerY;
    float distance = max(sqrt(dx * dx + dy * dy), 0.001);
    float distanceGain = 1.0 / (1.0 + 0.12 * distance);

    float solidDepth = 0.0;
    for (uint i = 0u; i < cellCount; i++)
    {
        solidDepth += step(0.5, gAcoustic[base + CELL_BASE + i]) * cellSize;
    }

    float occlusion = saturate(1.0 - solidDepth / max(distance, cellSize));
    float directGain = distanceGain * occlusion;

    float transmissionGain = 0.0;
    float lowpassHz = 20000.0;
    if (solidDepth > 0.0)
    {
        transmissionGain = distanceGain * materialTransmissionMid * exp(-1.6 * solidDepth);
        lowpassHz = clamp(12000.0 * materialTransmissionHigh + 900.0, 700.0, 12000.0);
    }

    float portalGain = 0.0;
    float portalDirX = 0.0;
    float portalDirY = 0.0;
    if (portalArea > 0.0)
    {
        float lpX = portalX - listenerX;
        float lpY = portalY - listenerY;
        float spX = portalX - sourceX;
        float spY = portalY - sourceY;
        float listenerDist = max(sqrt(lpX * lpX + lpY * lpY), 0.001);
        float sourceDist = max(sqrt(spX * spX + spY * spY), 0.001);
        float pathGain = 1.0 / (1.0 + 0.12 * (listenerDist + sourceDist));
        float radiusGain = clamp(portalRadius / 2.0, 0.05, 1.0);
        portalGain = pathGain * radiusGain * saturate(portalArea / portalMaxArea);
        portalDirX = lpX / listenerDist;
        portalDirY = lpY / listenerDist;
    }

    float openness = saturate(1.0 - solidDepth / max((float)cellCount * cellSize, cellSize));

    gAcoustic[base + OUT_BASE + 0u] = directGain;
    gAcoustic[base + OUT_BASE + 1u] = transmissionGain;
    gAcoustic[base + OUT_BASE + 2u] = portalGain;
    gAcoustic[base + OUT_BASE + 3u] = portalDirX;
    gAcoustic[base + OUT_BASE + 4u] = portalDirY;
    gAcoustic[base + OUT_BASE + 5u] = openness;
    gAcoustic[base + OUT_BASE + 6u] = 0.938;
    gAcoustic[base + OUT_BASE + 7u] = lowpassHz;
}
