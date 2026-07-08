RWStructuredBuffer<float> gAcoustic : register(u0);

static const uint MAX_SEGMENTS = 16u;
static const uint MAX_RAYS = 96u;
static const uint PARAM_BASE = 0u;
static const uint SEG_BASE = 64u;
static const uint SEG_STRIDE = 8u;
static const uint RAY_BASE = SEG_BASE + MAX_SEGMENTS * SEG_STRIDE;
static const uint RAY_STRIDE = 12u;
static const uint METRIC_BASE = RAY_BASE + MAX_RAYS * RAY_STRIDE;

float cross2(float2 a, float2 b)
{
    return a.x * b.y - a.y * b.x;
}

float lengthSafe(float2 v)
{
    return max(length(v), 0.001);
}

bool raySegment(float2 origin, float2 dir, float2 a, float2 b, out float rayT, out float segT)
{
    float2 edge = b - a;
    float denom = cross2(dir, edge);
    if (abs(denom) < 0.0001)
    {
        rayT = 0.0;
        segT = 0.0;
        return false;
    }

    float2 rel = a - origin;
    rayT = cross2(rel, edge) / denom;
    segT = cross2(rel, dir) / denom;
    return rayT > 0.001 && segT >= 0.0 && segT <= 1.0;
}

bool segmentSegment(float2 a0, float2 a1, float2 b0, float2 b1, out float at)
{
    float2 ad = a1 - a0;
    float2 bd = b1 - b0;
    float denom = cross2(ad, bd);
    if (abs(denom) < 0.0001)
    {
        at = 0.0;
        return false;
    }

    float2 rel = b0 - a0;
    float t = cross2(rel, bd) / denom;
    float u = cross2(rel, ad) / denom;
    at = t;
    return t >= 0.0 && t <= 1.0 && u >= 0.0 && u <= 1.0;
}

bool pathBlocked(float2 from, float2 to, uint segmentCount)
{
    float hitT = 0.0;
    for (uint i = 0u; i < segmentCount; i++)
    {
        uint s = SEG_BASE + i * SEG_STRIDE;
        if (gAcoustic[s + 6u] < 0.5)
            continue;

        float kind = gAcoustic[s + 5u];
        if (kind > 1.5)
            continue;

        float2 a = float2(gAcoustic[s + 0u], gAcoustic[s + 1u]);
        float2 b = float2(gAcoustic[s + 2u], gAcoustic[s + 3u]);
        if (segmentSegment(from, to, a, b, hitT))
            return true;
    }
    return false;
}

[shader("compute")]
[numthreads(64, 1, 1)]
void traceMain(uint3 tid : SV_DispatchThreadID)
{
    uint ray = tid.x;
    float2 source = float2(gAcoustic[PARAM_BASE + 0u], gAcoustic[PARAM_BASE + 1u]);
    float2 listener = float2(gAcoustic[PARAM_BASE + 2u], gAcoustic[PARAM_BASE + 3u]);
    uint segmentCount = min((uint)gAcoustic[PARAM_BASE + 4u], MAX_SEGMENTS);
    float maxDistance = max(gAcoustic[PARAM_BASE + 5u], 1.0);
    float doorOpen = gAcoustic[PARAM_BASE + 6u];
    float absorption = saturate(gAcoustic[PARAM_BASE + 8u]);
    float transmission = saturate(gAcoustic[PARAM_BASE + 9u]);
    float reflection = saturate(gAcoustic[PARAM_BASE + 10u]);
    float2 portal = float2(gAcoustic[PARAM_BASE + 11u], gAcoustic[PARAM_BASE + 12u]);

    if (ray < MAX_RAYS)
    {
        float angle = ((float)ray + 0.5) * 6.2831853 / (float)MAX_RAYS;
        float2 dir = float2(cos(angle), sin(angle));

        float bestT = maxDistance;
        float hitKind = 0.0;
        float hitTransmission = 0.0;
        float hitReflection = 0.0;
        float2 hitA = source;
        float2 hitB = source + dir;
        bool didHit = false;

        for (uint i = 0u; i < segmentCount; i++)
        {
            uint s = SEG_BASE + i * SEG_STRIDE;
            if (gAcoustic[s + 6u] < 0.5)
                continue;

            float2 a = float2(gAcoustic[s + 0u], gAcoustic[s + 1u]);
            float2 b = float2(gAcoustic[s + 2u], gAcoustic[s + 3u]);
            float rt = 0.0;
            float st = 0.0;
            if (raySegment(source, dir, a, b, rt, st) && rt < bestT)
            {
                bestT = rt;
                hitKind = gAcoustic[s + 5u];
                hitTransmission = gAcoustic[s + 4u] * transmission;
                hitReflection = reflection * (1.0 - absorption);
                hitA = a;
                hitB = b;
                didHit = true;
            }
        }

        float2 end = source + dir * bestT;
        float pathType = 0.0;
        float energy = 0.35 / (1.0 + 0.08 * bestT);
        float2 secondary = end;

        if (didHit)
        {
            float2 edge = normalize(hitB - hitA);
            float2 n = normalize(float2(-edge.y, edge.x));
            float2 reflected = normalize(dir - 2.0 * dot(dir, n) * n);
            secondary = end + reflected * 1.0;
            if (hitKind > 1.5 && doorOpen > 0.5)
            {
                pathType = 4.0;
                energy *= 0.75;
                secondary = portal;
            }
            else if (hitTransmission > 0.08)
            {
                pathType = 3.0;
                energy *= hitTransmission;
                secondary = end + dir * 0.75;
            }
            else
            {
                pathType = 2.0;
                energy *= max(hitReflection, 0.05);
            }
        }
        else
        {
            pathType = 1.0;
        }

        float aim = dot(normalize(listener - source), dir);
        if (aim > 0.995 && !pathBlocked(source, listener, segmentCount))
        {
            end = listener;
            secondary = listener;
            pathType = 1.0;
            energy = 1.0 / (1.0 + 0.16 * lengthSafe(listener - source));
        }

        uint outBase = RAY_BASE + ray * RAY_STRIDE;
        gAcoustic[outBase + 0u] = source.x;
        gAcoustic[outBase + 1u] = source.y;
        gAcoustic[outBase + 2u] = end.x;
        gAcoustic[outBase + 3u] = end.y;
        gAcoustic[outBase + 4u] = secondary.x;
        gAcoustic[outBase + 5u] = secondary.y;
        gAcoustic[outBase + 6u] = pathType;
        gAcoustic[outBase + 7u] = energy;
        gAcoustic[outBase + 8u] = didHit ? 1.0 : 0.0;
    }

    if (ray == 0u)
    {
        float distance = lengthSafe(listener - source);
        bool blocked = pathBlocked(source, listener, segmentCount);
        float directGain = blocked ? 0.0 : 1.0 / (1.0 + 0.16 * distance);
        float occlusion = blocked ? 1.0 : 0.0;
        float transmissionGain = blocked ? transmission * 0.45 / (1.0 + 0.16 * distance) : 0.0;

        float portalGain = 0.0;
        if (doorOpen > 0.5)
        {
            bool lp = pathBlocked(listener, portal, segmentCount);
            bool sp = pathBlocked(source, portal, segmentCount);
            if (!lp && !sp)
            {
                portalGain = 0.85 / (1.0 + 0.16 * (lengthSafe(listener - portal) + lengthSafe(source - portal)));
            }
        }

        float reflectionEnergy = saturate(reflection * (1.0 - absorption) * (blocked ? 0.55 : 0.85));

        gAcoustic[METRIC_BASE + 0u] = directGain;
        gAcoustic[METRIC_BASE + 1u] = occlusion;
        gAcoustic[METRIC_BASE + 2u] = reflectionEnergy;
        gAcoustic[METRIC_BASE + 3u] = portalGain;
        gAcoustic[METRIC_BASE + 4u] = saturate(reflectionEnergy * 0.7 + portalGain * 0.6 + absorption * 0.15);
        gAcoustic[METRIC_BASE + 5u] = blocked ? 0.91 : 0.97;
        gAcoustic[METRIC_BASE + 6u] = (float)MAX_RAYS;
        gAcoustic[METRIC_BASE + 7u] = doorOpen;
    }
}
