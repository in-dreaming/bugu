#include "gpu/gpu.h"

#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define WINDOW_W 1280u
#define WINDOW_H 720u
#define MAX_SEGMENTS 16u
#define MAX_RAYS 96u
#define PARAM_BASE 0u
#define SEG_BASE 64u
#define SEG_STRIDE 8u
#define RAY_BASE (SEG_BASE + MAX_SEGMENTS * SEG_STRIDE)
#define RAY_STRIDE 12u
#define METRIC_BASE (RAY_BASE + MAX_RAYS * RAY_STRIDE)
#define FLOAT_COUNT (METRIC_BASE + 32u)
#define MAX_VERTICES 32768u

#define KEY_ESCAPE 0x0000001bu
#define KEY_SPACE 0x00000020u
#define KEY_1 0x00000031u
#define KEY_2 0x00000032u
#define KEY_3 0x00000033u
#define KEY_A 0x00000061u
#define KEY_D 0x00000064u
#define KEY_R 0x00000072u
#define KEY_S 0x00000073u
#define KEY_W 0x00000077u
#define KEY_LEFT 0x40000050u
#define KEY_DOWN 0x40000051u
#define KEY_UP 0x40000052u
#define KEY_RIGHT 0x4000004fu

typedef struct Vec2 {
    float x;
    float y;
} Vec2;

typedef struct Segment {
    Vec2 a;
    Vec2 b;
    float transmission;
    float kind;
    float active;
} Segment;

typedef struct Material {
    const char* name;
    float absorption;
    float transmission;
    float reflection;
} Material;

typedef struct Vertex {
    float x;
    float y;
    float z;
    float w;
    float r;
    float g;
    float b;
    float a;
} Vertex;

typedef struct AppState {
    Vec2 source;
    Vec2 listener;
    bool doorOpen;
    int materialIndex;
    bool keyW;
    bool keyA;
    bool keyS;
    bool keyD;
    bool keyUp;
    bool keyDown;
    bool keyLeft;
    bool keyRight;
    bool draggingSource;
    uint32_t width;
    uint32_t height;
} AppState;

static const Material MATERIALS[3] = {
    { "concrete", 0.18f, 0.06f, 0.82f },
    { "wood", 0.42f, 0.18f, 0.48f },
    { "rock", 0.10f, 0.03f, 0.90f },
};

static float clampf(float v, float lo, float hi)
{
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

static Vec2 add2(Vec2 a, Vec2 b)
{
    Vec2 out = { a.x + b.x, a.y + b.y };
    return out;
}

static Vec2 sub2(Vec2 a, Vec2 b)
{
    Vec2 out = { a.x - b.x, a.y - b.y };
    return out;
}

static Vec2 mul2(Vec2 a, float s)
{
    Vec2 out = { a.x * s, a.y * s };
    return out;
}

static float len2(Vec2 a)
{
    return sqrtf(a.x * a.x + a.y * a.y);
}

static Vec2 norm2(Vec2 a)
{
    const float l = len2(a);
    if (l < 0.0001f) {
        Vec2 out = { 1.0f, 0.0f };
        return out;
    }
    return mul2(a, 1.0f / l);
}

static Vec2 world_to_ndc(Vec2 p)
{
    Vec2 out = { p.x / 6.2f, -p.y / 3.55f };
    return out;
}

static Vec2 screen_to_world(const AppState* app, int x, int y)
{
    float nx = ((float)x / (float)app->width) * 2.0f - 1.0f;
    float ny = ((float)y / (float)app->height) * 2.0f - 1.0f;
    Vec2 out = { nx * 6.2f, ny * 3.55f };
    return out;
}

static void push_vertex(Vertex* vertices, uint32_t* count, Vec2 p, float r, float g, float b, float a)
{
    if (*count >= MAX_VERTICES) return;
    Vec2 n = world_to_ndc(p);
    vertices[*count].x = n.x;
    vertices[*count].y = n.y;
    vertices[*count].z = 0.0f;
    vertices[*count].w = 1.0f;
    vertices[*count].r = r;
    vertices[*count].g = g;
    vertices[*count].b = b;
    vertices[*count].a = a;
    (*count)++;
}

static void add_tri(Vertex* vertices, uint32_t* count, Vec2 a, Vec2 b, Vec2 c, float r, float g, float bl, float alpha)
{
    push_vertex(vertices, count, a, r, g, bl, alpha);
    push_vertex(vertices, count, b, r, g, bl, alpha);
    push_vertex(vertices, count, c, r, g, bl, alpha);
}

static void add_rect(Vertex* vertices, uint32_t* count, Vec2 minp, Vec2 maxp, float r, float g, float b, float a)
{
    Vec2 p0 = { minp.x, minp.y };
    Vec2 p1 = { maxp.x, minp.y };
    Vec2 p2 = { maxp.x, maxp.y };
    Vec2 p3 = { minp.x, maxp.y };
    add_tri(vertices, count, p0, p1, p2, r, g, b, a);
    add_tri(vertices, count, p0, p2, p3, r, g, b, a);
}

static void add_line(Vertex* vertices, uint32_t* count, Vec2 a, Vec2 b, float thickness, float r, float g, float bl, float alpha)
{
    Vec2 d = sub2(b, a);
    Vec2 n = norm2((Vec2){ -d.y, d.x });
    Vec2 off = mul2(n, thickness * 0.5f);
    Vec2 p0 = add2(a, off);
    Vec2 p1 = add2(b, off);
    Vec2 p2 = sub2(b, off);
    Vec2 p3 = sub2(a, off);
    add_tri(vertices, count, p0, p1, p2, r, g, bl, alpha);
    add_tri(vertices, count, p0, p2, p3, r, g, bl, alpha);
}

static void add_circle(Vertex* vertices, uint32_t* count, Vec2 c, float radius, float r, float g, float b, float a)
{
    const int steps = 24;
    for (int i = 0; i < steps; i++) {
        float a0 = ((float)i / (float)steps) * 6.2831853f;
        float a1 = ((float)(i + 1) / (float)steps) * 6.2831853f;
        Vec2 p0 = { c.x + cosf(a0) * radius, c.y + sinf(a0) * radius };
        Vec2 p1 = { c.x + cosf(a1) * radius, c.y + sinf(a1) * radius };
        add_tri(vertices, count, c, p0, p1, r, g, b, a);
    }
}

static void add_bar(Vertex* vertices, uint32_t* count, float x, float y, float value, float r, float g, float b)
{
    add_rect(vertices, count, (Vec2){ x, y }, (Vec2){ x + 0.22f, y + 1.25f }, 0.10f, 0.12f, 0.14f, 1.0f);
    add_rect(vertices, count, (Vec2){ x + 0.03f, y + 0.03f }, (Vec2){ x + 0.19f, y + 0.03f + clampf(value, 0.0f, 1.0f) * 1.19f }, r, g, b, 1.0f);
}

static void reset_scene(AppState* app)
{
    app->source = (Vec2){ 3.9f, -1.55f };
    app->listener = (Vec2){ -3.7f, 1.35f };
    app->doorOpen = false;
    app->materialIndex = 0;
    app->draggingSource = false;
}

static uint32_t build_segments(const AppState* app, Segment* segs)
{
    uint32_t n = 0;
    const Material* m = &MATERIALS[app->materialIndex];
#define SEG(ax, ay, bx, by, kindValue, activeValue)                 \
    do {                                                            \
        if (n < MAX_SEGMENTS) {                                     \
            segs[n].a = (Vec2){ (ax), (ay) };                       \
            segs[n].b = (Vec2){ (bx), (by) };                       \
            segs[n].transmission = m->transmission;                 \
            segs[n].kind = (kindValue);                             \
            segs[n].active = (activeValue);                         \
            n++;                                                    \
        }                                                           \
    } while (0)

    SEG(-5.2f, -2.9f, 5.2f, -2.9f, 0.0f, 1.0f);
    SEG(5.2f, -2.9f, 5.2f, 2.9f, 0.0f, 1.0f);
    SEG(5.2f, 2.9f, -5.2f, 2.9f, 0.0f, 1.0f);
    SEG(-5.2f, 2.9f, -5.2f, -2.9f, 0.0f, 1.0f);
    SEG(0.0f, -2.9f, 0.0f, -0.62f, 0.0f, 1.0f);
    SEG(0.0f, 0.62f, 0.0f, 2.9f, 0.0f, 1.0f);
    SEG(0.0f, -0.62f, 0.0f, 0.62f, 0.0f, app->doorOpen ? 0.0f : 1.0f);
    SEG(0.0f, -0.62f, 0.0f, 0.62f, 2.0f, app->doorOpen ? 1.0f : 0.0f);
    SEG(2.05f, -2.9f, 2.05f, -1.55f, 0.0f, 1.0f);
    SEG(2.05f, 0.95f, 2.05f, 2.9f, 0.0f, 1.0f);
    SEG(-4.55f, -0.85f, -2.15f, -0.85f, 0.0f, 1.0f);
    SEG(-2.15f, -0.85f, -2.15f, -2.05f, 0.0f, 1.0f);

#undef SEG
    return n;
}

static void pack_gpu_data(const AppState* app, float* data)
{
    Segment segs[MAX_SEGMENTS];
    uint32_t segmentCount = build_segments(app, segs);
    const Material* m = &MATERIALS[app->materialIndex];

    memset(data, 0, FLOAT_COUNT * sizeof(float));
    data[PARAM_BASE + 0u] = app->source.x;
    data[PARAM_BASE + 1u] = app->source.y;
    data[PARAM_BASE + 2u] = app->listener.x;
    data[PARAM_BASE + 3u] = app->listener.y;
    data[PARAM_BASE + 4u] = (float)segmentCount;
    data[PARAM_BASE + 5u] = 8.5f;
    data[PARAM_BASE + 6u] = app->doorOpen ? 1.0f : 0.0f;
    data[PARAM_BASE + 7u] = (float)app->materialIndex;
    data[PARAM_BASE + 8u] = m->absorption;
    data[PARAM_BASE + 9u] = m->transmission;
    data[PARAM_BASE + 10u] = m->reflection;
    data[PARAM_BASE + 11u] = 0.0f;
    data[PARAM_BASE + 12u] = 0.0f;
    data[PARAM_BASE + 13u] = 0.62f;

    for (uint32_t i = 0; i < segmentCount; i++) {
        uint32_t base = SEG_BASE + i * SEG_STRIDE;
        data[base + 0u] = segs[i].a.x;
        data[base + 1u] = segs[i].a.y;
        data[base + 2u] = segs[i].b.x;
        data[base + 3u] = segs[i].b.y;
        data[base + 4u] = segs[i].transmission;
        data[base + 5u] = segs[i].kind;
        data[base + 6u] = segs[i].active;
    }
}

static void build_vertices(const AppState* app, const float* data, Vertex* vertices, uint32_t* vertexCount)
{
    *vertexCount = 0;

    add_rect(vertices, vertexCount, (Vec2){ -5.25f, -2.95f }, (Vec2){ 5.25f, 2.95f }, 0.035f, 0.04f, 0.05f, 1.0f);

    Segment segs[MAX_SEGMENTS];
    uint32_t segmentCount = build_segments(app, segs);
    for (uint32_t i = 0; i < segmentCount; i++) {
        if (segs[i].active < 0.5f) continue;
        if (segs[i].kind > 1.5f) {
            add_line(vertices, vertexCount, segs[i].a, segs[i].b, 0.08f, 0.18f, 0.72f, 0.92f, 1.0f);
        } else {
            add_line(vertices, vertexCount, segs[i].a, segs[i].b, 0.095f, 0.72f, 0.74f, 0.69f, 1.0f);
        }
    }

    if (app->doorOpen) {
        add_circle(vertices, vertexCount, (Vec2){ 0.0f, 0.0f }, 0.16f, 0.18f, 0.76f, 0.94f, 0.95f);
    } else {
        add_line(vertices, vertexCount, (Vec2){ -0.18f, -0.62f }, (Vec2){ -0.18f, 0.62f }, 0.035f, 0.92f, 0.58f, 0.20f, 1.0f);
    }

    for (uint32_t r = 0; r < MAX_RAYS; r++) {
        uint32_t base = RAY_BASE + r * RAY_STRIDE;
        Vec2 a = { data[base + 0u], data[base + 1u] };
        Vec2 b = { data[base + 2u], data[base + 3u] };
        Vec2 c = { data[base + 4u], data[base + 5u] };
        float type = data[base + 6u];
        float energy = clampf(data[base + 7u], 0.05f, 1.0f);
        float cr = 0.45f, cg = 0.48f, cb = 0.52f;
        if (type == 1.0f) { cr = 0.20f; cg = 0.88f; cb = 0.58f; }
        if (type == 2.0f) { cr = 0.95f; cg = 0.78f; cb = 0.25f; }
        if (type == 3.0f) { cr = 0.77f; cg = 0.48f; cb = 0.95f; }
        if (type == 4.0f) { cr = 0.24f; cg = 0.68f; cb = 1.00f; }
        add_line(vertices, vertexCount, a, b, 0.018f + energy * 0.012f, cr, cg, cb, 0.62f);
        if (type == 2.0f || type == 3.0f || type == 4.0f) {
            add_line(vertices, vertexCount, b, c, 0.014f, cr, cg, cb, 0.38f);
            add_circle(vertices, vertexCount, b, 0.035f, cr, cg, cb, 0.85f);
        }
    }

    add_circle(vertices, vertexCount, app->source, 0.18f, 0.98f, 0.32f, 0.26f, 1.0f);
    add_line(vertices, vertexCount, (Vec2){ app->source.x - 0.28f, app->source.y }, (Vec2){ app->source.x + 0.28f, app->source.y }, 0.035f, 0.98f, 0.32f, 0.26f, 1.0f);
    add_line(vertices, vertexCount, (Vec2){ app->source.x, app->source.y - 0.28f }, (Vec2){ app->source.x, app->source.y + 0.28f }, 0.035f, 0.98f, 0.32f, 0.26f, 1.0f);

    add_circle(vertices, vertexCount, app->listener, 0.18f, 0.25f, 0.76f, 1.0f, 1.0f);
    add_circle(vertices, vertexCount, app->listener, 0.09f, 0.03f, 0.04f, 0.05f, 1.0f);

    add_rect(vertices, vertexCount, (Vec2){ 3.55f, 1.05f }, (Vec2){ 5.05f, 2.65f }, 0.075f, 0.085f, 0.095f, 0.94f);
    add_bar(vertices, vertexCount, 3.72f, 1.24f, data[METRIC_BASE + 0u], 0.20f, 0.88f, 0.58f);
    add_bar(vertices, vertexCount, 4.02f, 1.24f, data[METRIC_BASE + 1u], 0.88f, 0.30f, 0.24f);
    add_bar(vertices, vertexCount, 4.32f, 1.24f, data[METRIC_BASE + 2u], 0.95f, 0.78f, 0.25f);
    add_bar(vertices, vertexCount, 4.62f, 1.24f, data[METRIC_BASE + 3u], 0.24f, 0.68f, 1.00f);
}

static void handle_key(AppState* app, uint32_t key, bool down, bool* quit)
{
    if (key == KEY_ESCAPE && down) *quit = true;
    if (key == KEY_W) app->keyW = down;
    if (key == KEY_A) app->keyA = down;
    if (key == KEY_S) app->keyS = down;
    if (key == KEY_D) app->keyD = down;
    if (key == KEY_UP) app->keyUp = down;
    if (key == KEY_DOWN) app->keyDown = down;
    if (key == KEY_LEFT) app->keyLeft = down;
    if (key == KEY_RIGHT) app->keyRight = down;

    if (!down) return;
    if (key == KEY_SPACE) app->doorOpen = !app->doorOpen;
    if (key == KEY_R) reset_scene(app);
    if (key == KEY_1) app->materialIndex = 0;
    if (key == KEY_2) app->materialIndex = 1;
    if (key == KEY_3) app->materialIndex = 2;
}

static void update_motion(AppState* app)
{
    const float step = 0.045f;
    if (app->keyW) app->listener.y += step;
    if (app->keyS) app->listener.y -= step;
    if (app->keyA) app->listener.x -= step;
    if (app->keyD) app->listener.x += step;
    if (app->keyUp) app->source.y += step;
    if (app->keyDown) app->source.y -= step;
    if (app->keyLeft) app->source.x -= step;
    if (app->keyRight) app->source.x += step;

    app->listener.x = clampf(app->listener.x, -4.9f, 4.9f);
    app->listener.y = clampf(app->listener.y, -2.65f, 2.65f);
    app->source.x = clampf(app->source.x, -4.9f, 4.9f);
    app->source.y = clampf(app->source.y, -2.65f, 2.65f);
}

static void print_queue_info(GpuDevice device)
{
    GpuQueueInfo graphics = {0};
    GpuQueueInfo compute = {0};
    gpuGetQueueInfo(device, GPU_QUEUE_TYPE_GRAPHICS, &graphics);
    gpuGetQueueInfo(device, GPU_QUEUE_TYPE_COMPUTE, &compute);
    printf("Bugu Acoustic Ray Visualizer\n");
    printf("controls: WASD listener, arrows source, Space door, R reset, 1/2/3 material, Esc quit\n");
    printf("graphics queue support=%d reason=%s\n", (int)graphics.support, graphics.reason ? graphics.reason : "");
    printf("compute queue support=%d reason=%s\n", (int)compute.support, compute.reason ? compute.reason : "");
}

int main(int argc, char** argv)
{
    bool once = false;
    const char* reportPath = "acoustic-ray-visualizer-runtime-report.txt";
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--once") == 0) once = true;
        if (strcmp(argv[i], "--report") == 0 && i + 1 < argc) {
            reportPath = argv[++i];
        }
    }

    FILE* report = fopen(reportPath, "w");
    if (!report) {
        fprintf(stderr, "Failed to open runtime report: %s\n", reportPath);
        return 1;
    }

    AppState app = {0};
    app.width = WINDOW_W;
    app.height = WINDOW_H;
    reset_scene(&app);

    float data[FLOAT_COUNT];
    Vertex* vertices = (Vertex*)calloc(MAX_VERTICES, sizeof(Vertex));
    if (!vertices) {
        fprintf(stderr, "Failed to allocate vertex buffer data\n");
        fclose(report);
        return 1;
    }

    GpuResult res = gpuPlatformInit();
    if (res != GPU_SUCCESS) {
        fprintf(stderr, "Failed to init GPU platform: %d\n", res);
        fclose(report);
        free(vertices);
        return 1;
    }

    GpuWindow window = NULL;
    GpuWindowDesc winDesc = {
        .title = "Bugu Acoustic Ray Visualizer",
        .width = WINDOW_W,
        .height = WINDOW_H,
        .vsync = true,
        .resizable = true,
    };
    res = gpuCreateWindow(&winDesc, &window);
    if (res != GPU_SUCCESS) {
        fprintf(stderr, "Failed to create GPU/SDL window: %d\n", res);
        fclose(report);
        gpuPlatformShutdown();
        free(vertices);
        return 1;
    }

    GpuDevice device = NULL;
    GpuDeviceDesc devDesc = {
        .appName = "Bugu Acoustic Ray Visualizer",
        .adapterIndex = 0,
        .enableDebugLayer = false,
    };
    res = gpuCreateDevice(&devDesc, &device);
    if (res != GPU_SUCCESS) {
        fprintf(stderr, "Failed to create GPU device: %d\n", res);
        fclose(report);
        gpuDestroyWindow(window);
        gpuPlatformShutdown();
        free(vertices);
        return 1;
    }
    print_queue_info(device);
    GpuQueueInfo reportGraphics = {0};
    GpuQueueInfo reportCompute = {0};
    gpuGetQueueInfo(device, GPU_QUEUE_TYPE_GRAPHICS, &reportGraphics);
    gpuGetQueueInfo(device, GPU_QUEUE_TYPE_COMPUTE, &reportCompute);
    fprintf(report, "Bugu Acoustic Ray Visualizer runtime report\n");
    fprintf(report, "window=1280x720 title=\"Bugu Acoustic Ray Visualizer\"\n");
    fprintf(report, "graphics_queue support=%d reason=%s\n", (int)reportGraphics.support, reportGraphics.reason ? reportGraphics.reason : "");
    fprintf(report, "compute_queue support=%d reason=%s\n", (int)reportCompute.support, reportCompute.reason ? reportCompute.reason : "");

    GpuSurface surface = NULL;
    res = gpuCreateSurface(device, window, GPU_SURFACE_TYPE_VULKAN, &surface);
    if (res != GPU_SUCCESS) {
        fprintf(stderr, "Failed to create GPU surface: %d\n", res);
        fclose(report);
        gpuDestroyDevice(device);
        gpuDestroyWindow(window);
        gpuPlatformShutdown();
        free(vertices);
        return 1;
    }

    GpuFormat format = gpuSurfaceGetPreferredFormat(surface);
    res = gpuSurfaceConfigure(surface, WINDOW_W, WINDOW_H, format, true);
    if (res != GPU_SUCCESS) {
        fprintf(stderr, "Failed to configure GPU surface: %d\n", res);
        fclose(report);
        gpuDestroySurface(device, surface);
        gpuDestroyDevice(device);
        gpuDestroyWindow(window);
        gpuPlatformShutdown();
        free(vertices);
        return 1;
    }

    GpuCommandQueue graphicsQueue = NULL;
    res = gpuGetQueue(device, GPU_QUEUE_TYPE_GRAPHICS, &graphicsQueue);
    if (res != GPU_SUCCESS) {
        fprintf(stderr, "Failed to get graphics queue: %d\n", res);
        fclose(report);
        gpuSurfaceUnconfigure(surface);
        gpuDestroySurface(device, surface);
        gpuDestroyDevice(device);
        gpuDestroyWindow(window);
        gpuPlatformShutdown();
        free(vertices);
        return 1;
    }

    GpuCommandQueue computeQueue = NULL;
    res = gpuGetQueue(device, GPU_QUEUE_TYPE_COMPUTE, &computeQueue);
    if (res != GPU_SUCCESS) {
        fprintf(stderr, "Failed to get compute queue: %d\n", res);
        fclose(report);
        gpuSurfaceUnconfigure(surface);
        gpuDestroySurface(device, surface);
        gpuDestroyDevice(device);
        gpuDestroyWindow(window);
        gpuPlatformShutdown();
        free(vertices);
        return 1;
    }

    GpuShaderCompiler compiler = NULL;
    res = gpuCreateShaderCompiler(device, &compiler);
    if (res != GPU_SUCCESS) {
        fprintf(stderr, "Failed to create shader compiler: %d\n", res);
        fclose(report);
        gpuSurfaceUnconfigure(surface);
        gpuDestroySurface(device, surface);
        gpuDestroyDevice(device);
        gpuDestroyWindow(window);
        gpuPlatformShutdown();
        free(vertices);
        return 1;
    }

    GpuShaderProgram traceProgram = NULL;
    GpuShaderCompileDesc traceDesc = {
        .sourcePath = "acoustic_trace.slang",
        .entryPoint = "traceMain",
        .target = GPU_SHADER_TARGET_SPIRV,
    };
    res = gpuCompileShader(compiler, &traceDesc, &traceProgram);
    if (res != GPU_SUCCESS) {
        fprintf(stderr, "Compute shader compile failed: %d diagnostic=%s\n", res, gpuGetShaderCompileDiagnostic(compiler));
        fclose(report);
        gpuDestroyShaderCompiler(compiler);
        gpuSurfaceUnconfigure(surface);
        gpuDestroySurface(device, surface);
        gpuDestroyDevice(device);
        gpuDestroyWindow(window);
        gpuPlatformShutdown();
        free(vertices);
        return 1;
    }
    printf("compute shader compiled: acoustic_trace.slang\n");
    fprintf(report, "compute_shader=compiled source=acoustic_trace.slang entry=traceMain\n");

    GpuShaderProgram drawProgram = NULL;
    GpuShaderCompileDesc drawDesc = {
        .sourcePath = "acoustic_draw.slang",
        .entryPoint = "vertexMain",
        .fragmentEntryPoint = "fragmentMain",
        .target = GPU_SHADER_TARGET_SPIRV,
    };
    res = gpuCompileShader(compiler, &drawDesc, &drawProgram);
    if (res != GPU_SUCCESS) {
        fprintf(stderr, "Render shader compile failed: %d diagnostic=%s\n", res, gpuGetShaderCompileDiagnostic(compiler));
        fclose(report);
        gpuDestroyShaderProgram(traceProgram);
        gpuDestroyShaderCompiler(compiler);
        gpuSurfaceUnconfigure(surface);
        gpuDestroySurface(device, surface);
        gpuDestroyDevice(device);
        gpuDestroyWindow(window);
        gpuPlatformShutdown();
        free(vertices);
        return 1;
    }
    printf("render shader compiled: acoustic_draw.slang\n");
    fprintf(report, "render_shader=compiled source=acoustic_draw.slang entry=vertexMain fragment=fragmentMain\n");

    GpuComputePipeline tracePipeline = NULL;
    GpuComputePipelineDesc tracePipelineDesc = {
        .program = traceProgram,
        .label = "bugu_acoustic_trace",
    };
    res = gpuCreateComputePipeline(device, &tracePipelineDesc, &tracePipeline);
    if (res != GPU_SUCCESS) {
        fprintf(stderr, "Failed to create compute pipeline: %d\n", res);
        fclose(report);
        gpuDestroyShaderProgram(drawProgram);
        gpuDestroyShaderProgram(traceProgram);
        gpuDestroyShaderCompiler(compiler);
        gpuSurfaceUnconfigure(surface);
        gpuDestroySurface(device, surface);
        gpuDestroyDevice(device);
        gpuDestroyWindow(window);
        gpuPlatformShutdown();
        free(vertices);
        return 1;
    }

    GpuComputeBinding traceBinding = NULL;
    res = gpuCreateComputeBinding(device, tracePipeline, &traceBinding);
    if (res != GPU_SUCCESS) {
        fprintf(stderr, "Failed to create compute binding: %d\n", res);
        fclose(report);
        gpuDestroyComputePipeline(device, tracePipeline);
        gpuDestroyShaderProgram(drawProgram);
        gpuDestroyShaderProgram(traceProgram);
        gpuDestroyShaderCompiler(compiler);
        gpuSurfaceUnconfigure(surface);
        gpuDestroySurface(device, surface);
        gpuDestroyDevice(device);
        gpuDestroyWindow(window);
        gpuPlatformShutdown();
        free(vertices);
        return 1;
    }

    GpuColorTargetDesc targetDesc = { .format = format };
    GpuRenderPipelineDesc renderPipelineDesc = {
        .program = drawProgram,
        .primitiveTopology = GPU_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
        .targets = &targetDesc,
        .targetCount = 1,
        .label = "bugu_acoustic_draw",
    };
    GpuRenderPipeline renderPipeline = NULL;
    res = gpuCreateRenderPipeline(device, &renderPipelineDesc, &renderPipeline);
    if (res != GPU_SUCCESS) {
        fprintf(stderr, "Failed to create render pipeline: %d\n", res);
        fclose(report);
        gpuDestroyComputeBinding(traceBinding);
        gpuDestroyComputePipeline(device, tracePipeline);
        gpuDestroyShaderProgram(drawProgram);
        gpuDestroyShaderProgram(traceProgram);
        gpuDestroyShaderCompiler(compiler);
        gpuSurfaceUnconfigure(surface);
        gpuDestroySurface(device, surface);
        gpuDestroyDevice(device);
        gpuDestroyWindow(window);
        gpuPlatformShutdown();
        free(vertices);
        return 1;
    }

    GpuPipelineLayout drawLayout = NULL;
    res = gpuReflectPipelineLayout(drawProgram, &drawLayout);
    if (res != GPU_SUCCESS) {
        fprintf(stderr, "Failed to reflect draw pipeline layout: %d\n", res);
        fclose(report);
        gpuDestroyRenderPipeline(device, renderPipeline);
        gpuDestroyComputeBinding(traceBinding);
        gpuDestroyComputePipeline(device, tracePipeline);
        gpuDestroyShaderProgram(drawProgram);
        gpuDestroyShaderProgram(traceProgram);
        gpuDestroyShaderCompiler(compiler);
        gpuSurfaceUnconfigure(surface);
        gpuDestroySurface(device, surface);
        gpuDestroyDevice(device);
        gpuDestroyWindow(window);
        gpuPlatformShutdown();
        free(vertices);
        return 1;
    }

    GpuDescriptorPool descriptorPool = NULL;
    GpuDescriptorPoolDesc descriptorPoolDesc = {
        .maxSets = 8,
        .maxBindingsPerSet = 8,
    };
    res = gpuCreateDescriptorPool(device, &descriptorPoolDesc, &descriptorPool);
    if (res != GPU_SUCCESS) {
        fprintf(stderr, "Failed to create descriptor pool: %d\n", res);
        fclose(report);
        gpuDestroyPipelineLayout(drawLayout);
        gpuDestroyRenderPipeline(device, renderPipeline);
        gpuDestroyComputeBinding(traceBinding);
        gpuDestroyComputePipeline(device, tracePipeline);
        gpuDestroyShaderProgram(drawProgram);
        gpuDestroyShaderProgram(traceProgram);
        gpuDestroyShaderCompiler(compiler);
        gpuSurfaceUnconfigure(surface);
        gpuDestroySurface(device, surface);
        gpuDestroyDevice(device);
        gpuDestroyWindow(window);
        gpuPlatformShutdown();
        free(vertices);
        return 1;
    }

    pack_gpu_data(&app, data);
    GpuBufferDesc acousticDesc = {
        .size = sizeof(data),
        .elementSize = sizeof(float),
        .usage = GPU_BUFFER_USAGE_UNORDERED_ACCESS | GPU_BUFFER_USAGE_COPY_SOURCE | GPU_BUFFER_USAGE_COPY_DEST,
        .label = "bugu_acoustic_visualizer_io",
    };
    GpuBufferHandle acousticBuffer = {0};
    res = gpuCreateBufferInit(device, &acousticDesc, data, &acousticBuffer);
    if (res != GPU_SUCCESS) {
        fprintf(stderr, "Failed to create acoustic buffer: %d\n", res);
        fclose(report);
        gpuDestroyDescriptorPool(descriptorPool);
        gpuDestroyPipelineLayout(drawLayout);
        gpuDestroyRenderPipeline(device, renderPipeline);
        gpuDestroyComputeBinding(traceBinding);
        gpuDestroyComputePipeline(device, tracePipeline);
        gpuDestroyShaderProgram(drawProgram);
        gpuDestroyShaderProgram(traceProgram);
        gpuDestroyShaderCompiler(compiler);
        gpuSurfaceUnconfigure(surface);
        gpuDestroySurface(device, surface);
        gpuDestroyDevice(device);
        gpuDestroyWindow(window);
        gpuPlatformShutdown();
        free(vertices);
        return 1;
    }

    GpuBufferDesc vertexDesc = {
        .size = MAX_VERTICES * sizeof(Vertex),
        .elementSize = sizeof(float) * 4u,
        .usage = GPU_BUFFER_USAGE_SHADER_RESOURCE | GPU_BUFFER_USAGE_COPY_DEST,
        .label = "bugu_acoustic_visualizer_vertices",
    };
    GpuBufferHandle vertexBuffer = {0};
    res = gpuCreateBuffer(device, &vertexDesc, &vertexBuffer);
    if (res != GPU_SUCCESS) {
        fprintf(stderr, "Failed to create vertex buffer: %d\n", res);
        fclose(report);
        gpuDestroyDescriptorPool(descriptorPool);
        gpuDestroyPipelineLayout(drawLayout);
        gpuDestroyBuffer(device, acousticBuffer);
        gpuDestroyRenderPipeline(device, renderPipeline);
        gpuDestroyComputeBinding(traceBinding);
        gpuDestroyComputePipeline(device, tracePipeline);
        gpuDestroyShaderProgram(drawProgram);
        gpuDestroyShaderProgram(traceProgram);
        gpuDestroyShaderCompiler(compiler);
        gpuSurfaceUnconfigure(surface);
        gpuDestroySurface(device, surface);
        gpuDestroyDevice(device);
        gpuDestroyWindow(window);
        gpuPlatformShutdown();
        free(vertices);
        return 1;
    }

    GpuDescriptorSet drawSet = NULL;
    res = gpuAllocateDescriptorSet(descriptorPool, drawLayout, 0, &drawSet);
    if (res != GPU_SUCCESS) {
        fprintf(stderr, "Failed to allocate draw descriptor set: %d\n", res);
        fclose(report);
        gpuDestroyBuffer(device, vertexBuffer);
        gpuDestroyDescriptorPool(descriptorPool);
        gpuDestroyPipelineLayout(drawLayout);
        gpuDestroyBuffer(device, acousticBuffer);
        gpuDestroyRenderPipeline(device, renderPipeline);
        gpuDestroyComputeBinding(traceBinding);
        gpuDestroyComputePipeline(device, tracePipeline);
        gpuDestroyShaderProgram(drawProgram);
        gpuDestroyShaderProgram(traceProgram);
        gpuDestroyShaderCompiler(compiler);
        gpuSurfaceUnconfigure(surface);
        gpuDestroySurface(device, surface);
        gpuDestroyDevice(device);
        gpuDestroyWindow(window);
        gpuPlatformShutdown();
        free(vertices);
        return 1;
    }
    GpuDescriptorWrite vertexWrite = {
        .type = GPU_DESCRIPTOR_WRITE_BUFFER,
        .buffer = vertexBuffer,
        .bufferOffset = 0,
        .bufferRange = MAX_VERTICES * sizeof(Vertex),
    };
    res = gpuUpdateDescriptorSetByName(drawSet, "gVertices", &vertexWrite);
    if (res != GPU_SUCCESS) {
        fprintf(stderr, "Failed to update draw descriptor set: %d\n", res);
        fclose(report);
        gpuFreeDescriptorSet(drawSet);
        gpuDestroyBuffer(device, vertexBuffer);
        gpuDestroyDescriptorPool(descriptorPool);
        gpuDestroyPipelineLayout(drawLayout);
        gpuDestroyBuffer(device, acousticBuffer);
        gpuDestroyRenderPipeline(device, renderPipeline);
        gpuDestroyComputeBinding(traceBinding);
        gpuDestroyComputePipeline(device, tracePipeline);
        gpuDestroyShaderProgram(drawProgram);
        gpuDestroyShaderProgram(traceProgram);
        gpuDestroyShaderCompiler(compiler);
        gpuSurfaceUnconfigure(surface);
        gpuDestroySurface(device, surface);
        gpuDestroyDevice(device);
        gpuDestroyWindow(window);
        gpuPlatformShutdown();
        free(vertices);
        return 1;
    }

    bool quit = false;
    uint32_t frameCount = 0;
    while (!quit) {
        GpuPlatformEvent ev;
        while (gpuPollEvent(&ev)) {
            if (ev.type == GPU_PLATFORM_EVENT_QUIT) quit = true;
            if (ev.type == GPU_PLATFORM_EVENT_RESIZE) {
                app.width = ev.resize.width > 0 ? ev.resize.width : 1u;
                app.height = ev.resize.height > 0 ? ev.resize.height : 1u;
                gpuSurfaceConfigure(surface, app.width, app.height, format, true);
            }
            if (ev.type == GPU_PLATFORM_EVENT_KEY_DOWN) handle_key(&app, ev.key.keycode, true, &quit);
            if (ev.type == GPU_PLATFORM_EVENT_KEY_UP) handle_key(&app, ev.key.keycode, false, &quit);
            if (ev.type == GPU_PLATFORM_EVENT_MOUSE_BUTTON_DOWN && ev.mouse.button == 1u) {
                app.draggingSource = true;
                app.source = screen_to_world(&app, ev.mouse.x, ev.mouse.y);
            }
            if (ev.type == GPU_PLATFORM_EVENT_MOUSE_BUTTON_UP && ev.mouse.button == 1u) {
                app.draggingSource = false;
            }
            if (ev.type == GPU_PLATFORM_EVENT_MOUSE_MOVE && app.draggingSource) {
                app.source = screen_to_world(&app, ev.mouse.x, ev.mouse.y);
            }
        }
        if (quit) break;

        update_motion(&app);
        pack_gpu_data(&app, data);
        res = gpuUploadToBuffer(device, acousticBuffer, data, sizeof(data), 0);
        if (res != GPU_SUCCESS) {
            fprintf(stderr, "Failed to upload acoustic buffer: %d\n", res);
            quit = true;
            continue;
        }

        GpuCommandEncoder computeEncoder = gpuBeginCommandEncoder(device, computeQueue);
        if (!computeEncoder) {
            fprintf(stderr, "Failed to begin compute command encoder\n");
            quit = true;
            continue;
        }
        GpuComputePassEncoder computePass = gpuCmdBeginComputePass(computeEncoder);
        res = GPU_SUCCESS;
        if (computePass) {
            res = gpuComputeBindingDispatch(traceBinding, computePass, "gAcoustic", acousticBuffer, 2, 1, 1);
            gpuCmdEndComputePass(computePass);
        } else {
            res = GPU_ERROR_INTERNAL;
        }
        GpuCommandBuffer computeCmd = gpuFinishCommandEncoder(computeEncoder);
        if (res != GPU_SUCCESS || !computeCmd) {
            fprintf(stderr, "Failed to dispatch acoustic compute: %d\n", res);
            quit = true;
            continue;
        }
        res = gpuQueueSubmit(computeQueue, 1, &computeCmd);
        if (res != GPU_SUCCESS) {
            fprintf(stderr, "Failed to submit acoustic compute: %d\n", res);
            quit = true;
            continue;
        }
        gpuQueueWaitOnHost(computeQueue);

        res = gpuDownloadFromBuffer(device, acousticBuffer, data, sizeof(data), 0);
        if (res != GPU_SUCCESS) {
            fprintf(stderr, "Failed to download acoustic data: %d\n", res);
            quit = true;
            continue;
        }

        uint32_t vertexCount = 0;
        build_vertices(&app, data, vertices, &vertexCount);
        res = gpuUploadToBuffer(device, vertexBuffer, vertices, vertexCount * sizeof(Vertex), 0);
        if (res != GPU_SUCCESS) {
            fprintf(stderr, "Failed to upload render vertices: %d\n", res);
            quit = true;
            continue;
        }

        GpuSurfaceTexture backbuffer = NULL;
        res = gpuSurfaceAcquireNextImage(surface, &backbuffer);
        if (res != GPU_SUCCESS) {
            continue;
        }

        GpuCommandEncoder encoder = gpuBeginCommandEncoder(device, graphicsQueue);
        if (!encoder) {
            gpuSurfaceTextureRelease(backbuffer);
            continue;
        }

        GpuRenderPassColorAttachment colorAttachment = {
            .attachment = backbuffer,
            .textureHandle = {0, 0},
            .mipLevel = 0,
            .loadOp = GPU_LOAD_OP_CLEAR,
            .storeOp = GPU_STORE_OP_STORE,
            .clearValue = { 0.02f, 0.024f, 0.028f, 1.0f },
        };
        GpuRenderPassDesc passDesc = {
            .colorAttachmentCount = 1,
            .colorAttachments = &colorAttachment,
        };
        GpuRenderPassEncoder pass = gpuCmdBeginRenderPass(encoder, &passDesc);
        if (pass) {
            gpuCmdBindRenderPipeline(pass, renderPipeline);
            gpuCmdBindDescriptorSetPass(pass, drawLayout, 0, drawSet);
            gpuCmdSetViewport(pass, 0.0f, 0.0f, (float)app.width, (float)app.height);
            gpuCmdDraw(pass, vertexCount, 1, 0, 0);
            gpuCmdEndRenderPass(pass);
        }

        GpuCommandBuffer cmd = gpuFinishCommandEncoder(encoder);
        if (cmd) {
            gpuQueueSubmit(graphicsQueue, 1, &cmd);
        }
        gpuSurfacePresent(surface);
        gpuSurfaceTextureRelease(backbuffer);

        if ((frameCount % 120u) == 0u) {
            printf("frame=%u material=%s door=%s rays=%u direct=%.3f occlusion=%.3f reflection=%.3f portal=%.3f reverb=%.3f confidence=%.3f\n",
                   frameCount,
                   MATERIALS[app.materialIndex].name,
                   app.doorOpen ? "open" : "closed",
                   (uint32_t)data[METRIC_BASE + 6u],
                   data[METRIC_BASE + 0u],
                   data[METRIC_BASE + 1u],
                   data[METRIC_BASE + 2u],
                   data[METRIC_BASE + 3u],
                   data[METRIC_BASE + 4u],
                   data[METRIC_BASE + 5u]);
        }
        if (frameCount < 3u) {
            fprintf(report, "sample frame=%u material=%s door=%s rays=%u direct=%.3f occlusion=%.3f reflection=%.3f portal=%.3f reverb_send=%.3f confidence=%.3f vertices=%u\n",
                    frameCount,
                    MATERIALS[app.materialIndex].name,
                    app.doorOpen ? "open" : "closed",
                    (uint32_t)data[METRIC_BASE + 6u],
                    data[METRIC_BASE + 0u],
                    data[METRIC_BASE + 1u],
                    data[METRIC_BASE + 2u],
                    data[METRIC_BASE + 3u],
                    data[METRIC_BASE + 4u],
                    data[METRIC_BASE + 5u],
                    vertexCount);
            fflush(report);
        }

        frameCount++;
        if (once && frameCount >= 3u) {
            quit = true;
        }
        if (once && frameCount == 1u) {
            app.doorOpen = true;
        }
        if (once && frameCount == 2u) {
            app.materialIndex = 1;
        }
    }

    gpuQueueWaitOnHost(graphicsQueue);
    gpuQueueWaitOnHost(computeQueue);
    printf("closed cleanly after %u frames\n", frameCount);
    fprintf(report, "shutdown=clean frames=%u\n", frameCount);
    fprintf(report, "visual_inspection=not_performed_by_automated_once_run\n");
    fclose(report);

    gpuFreeDescriptorSet(drawSet);
    gpuDestroyBuffer(device, vertexBuffer);
    gpuDestroyDescriptorPool(descriptorPool);
    gpuDestroyPipelineLayout(drawLayout);
    gpuDestroyBuffer(device, acousticBuffer);
    gpuDestroyRenderPipeline(device, renderPipeline);
    gpuDestroyComputeBinding(traceBinding);
    gpuDestroyComputePipeline(device, tracePipeline);
    gpuDestroyShaderProgram(drawProgram);
    gpuDestroyShaderProgram(traceProgram);
    gpuDestroyShaderCompiler(compiler);
    gpuSurfaceUnconfigure(surface);
    gpuDestroySurface(device, surface);
    gpuDestroyDevice(device);
    gpuDestroyWindow(window);
    gpuPlatformShutdown();
    free(vertices);
    return 0;
}
