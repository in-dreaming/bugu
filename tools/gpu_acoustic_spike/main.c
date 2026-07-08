#include "gpu/gpu.h"

#include <math.h>
#include <stdbool.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#define SCENE_COUNT 7u
#define STRIDE 40u
#define CELL_BASE 16u
#define OUT_BASE 32u
#define FLOAT_COUNT (SCENE_COUNT * STRIDE)

typedef struct Expected {
    const char* name;
    float direct_gain;
    float transmission_gain;
    float portal_gain;
    float portal_dir_x;
    float portal_dir_y;
    float openness;
    float lowpass_hz;
} Expected;

static FILE* g_report = NULL;

static void emit(const char* fmt, ...)
{
    va_list args;
    va_start(args, fmt);
    vprintf(fmt, args);
    va_end(args);

    if (g_report != NULL) {
        va_start(args, fmt);
        vfprintf(g_report, fmt, args);
        va_end(args);
        fflush(g_report);
    }
}

static void fill_scene(float* data, unsigned scene, float solid_a, float solid_b, float portal_area, float portal_y, float portal_radius, float openness_solid_cells)
{
    const unsigned base = scene * STRIDE;
    data[base + 0] = -4.0f;
    data[base + 1] = 0.0f;
    data[base + 2] = 4.0f;
    data[base + 3] = 0.0f;
    data[base + 4] = 16.0f;
    data[base + 5] = 0.5f;
    data[base + 6] = -4.0f;
    data[base + 7] = 0.0f;
    data[base + 8] = portal_y;
    data[base + 9] = portal_area;
    data[base + 10] = 2.0f;
    data[base + 11] = portal_radius;
    data[base + 12] = 0.14f;
    data[base + 13] = 0.04f;
    data[base + 14] = 0.65f;
    data[base + 15] = openness_solid_cells;

    for (unsigned i = 0; i < 16; i++) {
        data[base + CELL_BASE + i] = (i == (unsigned)solid_a || i == (unsigned)solid_b) ? 1.0f : 0.0f;
    }
}

static bool approx(float actual, float expected, float abs_tol, float rel_tol)
{
    const float diff = fabsf(actual - expected);
    if (diff <= abs_tol) return true;
    return diff <= fabsf(expected) * rel_tol;
}

static int validate_scene(const float* data, unsigned scene, Expected expected)
{
    const unsigned base = scene * STRIDE + OUT_BASE;
    const float direct = data[base + 0];
    const float transmission = data[base + 1];
    const float portal = data[base + 2];
    const float portal_x = data[base + 3];
    const float portal_y = data[base + 4];
    const float openness = data[base + 5];
    const float confidence = data[base + 6];
    const float lowpass = data[base + 7];

    emit("gpu_acoustic scene=%s direct=%.5f transmission=%.5f portal=%.5f portal_dir=[%.3f,%.3f] openness=%.5f confidence=%.3f lowpass=%.1f\n",
         expected.name, direct, transmission, portal, portal_x, portal_y, openness, confidence, lowpass);

    int failures = 0;
    if (!approx(direct, expected.direct_gain, 0.04f, 0.10f)) failures++;
    if (!approx(transmission, expected.transmission_gain, 0.02f, 0.20f)) failures++;
    if (!approx(portal, expected.portal_gain, 0.03f, 0.20f)) failures++;
    if (expected.portal_gain > 0.001f) {
        const float dot = portal_x * expected.portal_dir_x + portal_y * expected.portal_dir_y;
        if (dot < 0.90f) failures++;
    }
    if (!approx(openness, expected.openness, 0.08f, 0.10f)) failures++;
    if (!approx(lowpass, expected.lowpass_hz, 20.0f, 0.02f)) failures++;
    if (confidence <= 0.0f || confidence > 1.0f) failures++;
    return failures;
}

int main(void)
{
    g_report = fopen("gpu_acoustic_spike_report.txt", "w");
    if (g_report == NULL) {
        return 1;
    }

    float data[FLOAT_COUNT];
    memset(data, 0, sizeof(data));

    fill_scene(data, 0, 100.0f, 101.0f, 0.0f, 0.0f, 1.0f, -1.0f);  // open_air
    fill_scene(data, 1, 7.0f, 8.0f, 0.0f, 0.0f, 1.0f, -1.0f);      // thick_wall
    fill_scene(data, 2, 7.0f, 8.0f, 1.8f, 2.0f, 1.0f, -1.0f);      // wall_hole
    fill_scene(data, 3, 7.0f, 8.0f, 0.0f, 0.0f, 0.9f, -1.0f);      // door_closed
    fill_scene(data, 4, 7.0f, 8.0f, 2.0f, 0.0f, 0.9f, -1.0f);      // door_open
    fill_scene(data, 5, 100.0f, 101.0f, 0.0f, 0.0f, 1.0f, 11.0f);  // cave
    fill_scene(data, 6, 100.0f, 101.0f, 0.0f, 0.0f, 1.0f, -1.0f);  // open_field

    const Expected expected[SCENE_COUNT] = {
        { "open_air", 0.51020f, 0.0f, 0.0f, 0.0f, 0.0f, 1.0f, 20000.0f },
        { "thick_wall", 0.44643f, 0.01442f, 0.0f, 0.0f, 0.0f, 0.875f, 1380.0f },
        { "wall_hole", 0.44643f, 0.01442f, 0.19884f, 0.894f, 0.447f, 0.875f, 1380.0f },
        { "door_closed", 0.44643f, 0.01442f, 0.0f, 0.0f, 0.0f, 0.875f, 1380.0f },
        { "door_open", 0.44643f, 0.01442f, 0.22959f, 1.0f, 0.0f, 0.875f, 1380.0f },
        { "cave", 0.51020f, 0.0f, 0.0f, 0.0f, 0.0f, 0.3125f, 20000.0f },
        { "open_field", 0.51020f, 0.0f, 0.0f, 0.0f, 0.0f, 1.0f, 20000.0f },
    };

    GpuDeviceDesc dev_desc = {
        .appName = "bugu_gpu_acoustic_spike",
        .adapterIndex = 0,
        .enableDebugLayer = false,
    };
    GpuDevice device = NULL;
    GpuResult result = gpuCreateDevice(&dev_desc, &device);
    if (result != GPU_SUCCESS) {
        emit("gpu_acoustic error=create_device result=%d\n", result);
        fclose(g_report);
        return 1;
    }

    GpuQueueInfo compute_info = {0};
    (void)gpuGetQueueInfo(device, GPU_QUEUE_TYPE_COMPUTE, &compute_info);
    emit("gpu_acoustic queue compute_support=%d reason=%s\n",
         (int)compute_info.support,
         compute_info.reason ? compute_info.reason : "");

    GpuShaderCompiler compiler = NULL;
    result = gpuCreateShaderCompiler(device, &compiler);
    if (result != GPU_SUCCESS) {
        emit("gpu_acoustic error=create_shader_compiler result=%d\n", result);
        gpuDestroyDevice(device);
        fclose(g_report);
        return 1;
    }

    GpuShaderCompileDesc shader_desc = {
        .sourcePath = "gpu_acoustic.slang",
        .entryPoint = "acousticMain",
        .target = GPU_SHADER_TARGET_SPIRV,
    };
    GpuShaderProgram program = NULL;
    result = gpuCompileShader(compiler, &shader_desc, &program);
    if (result != GPU_SUCCESS) {
        emit("gpu_acoustic error=compile_shader result=%d diagnostic=%s\n",
             result, gpuGetShaderCompileDiagnostic(compiler));
        gpuDestroyShaderCompiler(compiler);
        gpuDestroyDevice(device);
        fclose(g_report);
        return 1;
    }

    GpuComputePipelineDesc pipeline_desc = {
        .program = program,
        .label = "bugu_gpu_acoustic_pipeline",
    };
    GpuComputePipeline pipeline = NULL;
    result = gpuCreateComputePipeline(device, &pipeline_desc, &pipeline);
    if (result != GPU_SUCCESS) {
        emit("gpu_acoustic error=create_pipeline result=%d\n", result);
        gpuDestroyShaderProgram(program);
        gpuDestroyShaderCompiler(compiler);
        gpuDestroyDevice(device);
        fclose(g_report);
        return 1;
    }

    GpuComputeBinding binding = NULL;
    result = gpuCreateComputeBinding(device, pipeline, &binding);
    if (result != GPU_SUCCESS) {
        emit("gpu_acoustic error=create_binding result=%d\n", result);
        gpuDestroyComputePipeline(device, pipeline);
        gpuDestroyShaderProgram(program);
        gpuDestroyShaderCompiler(compiler);
        gpuDestroyDevice(device);
        fclose(g_report);
        return 1;
    }

    GpuBufferDesc buffer_desc = {
        .size = sizeof(data),
        .elementSize = sizeof(float),
        .usage = GPU_BUFFER_USAGE_UNORDERED_ACCESS | GPU_BUFFER_USAGE_COPY_SOURCE | GPU_BUFFER_USAGE_COPY_DEST,
        .label = "bugu_acoustic_io",
    };
    GpuBufferHandle buffer = {0};
    result = gpuCreateBufferInit(device, &buffer_desc, data, &buffer);
    if (result != GPU_SUCCESS) {
        emit("gpu_acoustic error=create_buffer result=%d\n", result);
        gpuDestroyComputeBinding(binding);
        gpuDestroyComputePipeline(device, pipeline);
        gpuDestroyShaderProgram(program);
        gpuDestroyShaderCompiler(compiler);
        gpuDestroyDevice(device);
        fclose(g_report);
        return 1;
    }

    GpuCommandQueue queue = NULL;
    result = gpuGetQueue(device, GPU_QUEUE_TYPE_COMPUTE, &queue);
    if (result != GPU_SUCCESS) {
        emit("gpu_acoustic error=get_compute_queue result=%d\n", result);
        gpuDestroyBuffer(device, buffer);
        gpuDestroyComputeBinding(binding);
        gpuDestroyComputePipeline(device, pipeline);
        gpuDestroyShaderProgram(program);
        gpuDestroyShaderCompiler(compiler);
        gpuDestroyDevice(device);
        fclose(g_report);
        return 1;
    }

    GpuCommandEncoder encoder = gpuBeginCommandEncoder(device, queue);
    GpuComputePassEncoder pass = gpuCmdBeginComputePass(encoder);
    result = gpuComputeBindingDispatch(binding, pass, "gAcoustic", buffer, SCENE_COUNT, 1, 1);
    gpuCmdEndComputePass(pass);
    GpuCommandBuffer command_buffer = gpuFinishCommandEncoder(encoder);
    if (result != GPU_SUCCESS || command_buffer == NULL) {
        emit("gpu_acoustic error=dispatch result=%d command_buffer=%p\n", result, (void*)command_buffer);
        gpuDestroyBuffer(device, buffer);
        gpuDestroyComputeBinding(binding);
        gpuDestroyComputePipeline(device, pipeline);
        gpuDestroyShaderProgram(program);
        gpuDestroyShaderCompiler(compiler);
        gpuDestroyDevice(device);
        fclose(g_report);
        return 1;
    }

    result = gpuQueueSubmit(queue, 1, &command_buffer);
    if (result != GPU_SUCCESS) {
        emit("gpu_acoustic error=queue_submit result=%d\n", result);
        gpuDestroyBuffer(device, buffer);
        gpuDestroyComputeBinding(binding);
        gpuDestroyComputePipeline(device, pipeline);
        gpuDestroyShaderProgram(program);
        gpuDestroyShaderCompiler(compiler);
        gpuDestroyDevice(device);
        fclose(g_report);
        return 1;
    }

    result = gpuQueueWaitOnHost(queue);
    if (result != GPU_SUCCESS) {
        emit("gpu_acoustic error=queue_wait result=%d\n", result);
        gpuDestroyBuffer(device, buffer);
        gpuDestroyComputeBinding(binding);
        gpuDestroyComputePipeline(device, pipeline);
        gpuDestroyShaderProgram(program);
        gpuDestroyShaderCompiler(compiler);
        gpuDestroyDevice(device);
        fclose(g_report);
        return 1;
    }

    result = gpuDownloadFromBuffer(device, buffer, data, sizeof(data), 0);
    if (result != GPU_SUCCESS) {
        emit("gpu_acoustic error=download result=%d\n", result);
        gpuDestroyBuffer(device, buffer);
        gpuDestroyComputeBinding(binding);
        gpuDestroyComputePipeline(device, pipeline);
        gpuDestroyShaderProgram(program);
        gpuDestroyShaderCompiler(compiler);
        gpuDestroyDevice(device);
        fclose(g_report);
        return 1;
    }

    int failures = 0;
    for (unsigned i = 0; i < SCENE_COUNT; i++) {
        failures += validate_scene(data, i, expected[i]);
    }

    gpuDestroyBuffer(device, buffer);
    gpuDestroyComputeBinding(binding);
    gpuDestroyComputePipeline(device, pipeline);
    gpuDestroyShaderProgram(program);
    gpuDestroyShaderCompiler(compiler);
    gpuDestroyDevice(device);

    if (failures != 0) {
        emit("gpu_acoustic validation=FAILED failures=%d\n", failures);
        fclose(g_report);
        return 1;
    }
    emit("gpu_acoustic validation=PASSED scenes=%u\n", SCENE_COUNT);
    fclose(g_report);
    return 0;
}
