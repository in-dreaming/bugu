#include "acoustic/gpu_external.h"

#include "gpu/gpu.h"

#include <cstring>
#include <new>

static_assert(sizeof(BuguGpuIdentity) == 56);
static_assert(sizeof(BuguGpuPackedRequest) == 216);
static_assert(sizeof(BuguGpuPackedResponse) == 96);

namespace {
constexpr size_t kValues = 40;
constexpr size_t kOutputBase = 32;
constexpr size_t kBufferBytes = BUGU_GPU_MAX_BATCH * kValues * sizeof(float);

struct Slot {
    GpuBufferHandle io{};
    GpuBufferHandle readback{};
    GpuCommandBuffer command = nullptr;
    uint64_t ticket = 0;
    uint64_t generation = 0;
    size_t count = 0;
    bool in_flight = false;
    bool discarded = false;
    BuguGpuIdentity identities[BUGU_GPU_MAX_BATCH]{};
};

} // namespace

struct BuguGpuExternal {
    GpuDevice device = nullptr;              // non-owning
    GpuCommandQueue compute_queue = nullptr; // non-owning
    uint32_t device_generation = 0;
    void* executor_context = nullptr;
    BuguGpuSubmitCommandFn submit_command = nullptr;
    BuguGpuPollTicketFn poll_ticket = nullptr;
    BuguGpuDiscardTicketFn discard_ticket = nullptr;
    GpuShaderCompiler compiler = nullptr;
    GpuShaderProgram program = nullptr;
    GpuComputePipeline pipeline = nullptr;
    GpuComputeBinding binding = nullptr;
    Slot slots[BUGU_GPU_READBACK_SLOTS]{};
};

static void destroy_resources(BuguGpuExternal* context)
{
    for (Slot& slot : context->slots) {
        if (slot.command) gpuDestroyCommandBuffer(slot.command);
        if (gpuHandleIsValid(slot.readback)) gpuDestroyBuffer(context->device, slot.readback);
        if (gpuHandleIsValid(slot.io)) gpuDestroyBuffer(context->device, slot.io);
    }
    if (context->binding) gpuDestroyComputeBinding(context->binding);
    if (context->pipeline) gpuDestroyComputePipeline(context->device, context->pipeline);
    if (context->program) gpuDestroyShaderProgram(context->program);
    if (context->compiler) gpuDestroyShaderCompiler(context->compiler);
}

extern "C" BuguGpuExternalStatus buguGpuExternalCreate(const BuguGpuExternalCreateInfo* info,
                                                        BuguGpuExternal** out_context)
{
    if (!info || !out_context || !info->device || !info->compute_queue ||
        !info->shader_path || info->device_generation == 0 || !info->submit_command ||
        !info->poll_ticket || !info->discard_ticket) {
        return BUGU_GPU_INVALID_ARGUMENT;
    }
    *out_context = nullptr;
    BuguGpuExternal* context = new (std::nothrow) BuguGpuExternal{};
    if (!context) return BUGU_GPU_FAILURE;
    context->device = static_cast<GpuDevice>(info->device);
    context->compute_queue = static_cast<GpuCommandQueue>(info->compute_queue);
    context->device_generation = info->device_generation;
    context->executor_context = info->executor_context;
    context->submit_command = info->submit_command;
    context->poll_ticket = info->poll_ticket;
    context->discard_ticket = info->discard_ticket;

    GpuResult result = gpuCreateShaderCompiler(context->device, &context->compiler);
    GpuShaderCompileDesc shader_desc{};
    shader_desc.sourcePath = info->shader_path;
    shader_desc.entryPoint = "acousticMain";
    switch (gpuGetBackendType(context->device)) {
    case GPU_BACKEND_D3D12: shader_desc.target = GPU_SHADER_TARGET_DXIL; break;
    case GPU_BACKEND_METAL: shader_desc.target = GPU_SHADER_TARGET_MSL; break;
    default: shader_desc.target = GPU_SHADER_TARGET_SPIRV; break;
    }
    if (result == GPU_SUCCESS) result = gpuCompileShader(context->compiler, &shader_desc, &context->program);
    GpuComputePipelineDesc pipeline_desc{};
    pipeline_desc.program = context->program;
    pipeline_desc.label = "bugu_external_acoustic";
    if (result == GPU_SUCCESS) result = gpuCreateComputePipeline(context->device, &pipeline_desc, &context->pipeline);
    if (result == GPU_SUCCESS) result = gpuCreateComputeBinding(context->device, context->pipeline, &context->binding);

    GpuBufferDesc buffer_desc{};
    buffer_desc.size = kBufferBytes;
    buffer_desc.elementSize = sizeof(float);
    buffer_desc.usage = GPU_BUFFER_USAGE_UNORDERED_ACCESS | GPU_BUFFER_USAGE_COPY_SOURCE |
                        GPU_BUFFER_USAGE_COPY_DEST;
    buffer_desc.label = "bugu_external_acoustic_io";
    for (Slot& slot : context->slots) {
        if (result == GPU_SUCCESS) result = gpuCreateBuffer(context->device, &buffer_desc, &slot.io);
        if (result == GPU_SUCCESS) result = gpuCreateReadbackBuffer(context->device, kBufferBytes, &slot.readback);
    }
    if (result != GPU_SUCCESS) {
        destroy_resources(context);
        delete context;
        return result == GPU_ERROR_NOT_SUPPORTED ? BUGU_GPU_UNSUPPORTED : BUGU_GPU_FAILURE;
    }
    *out_context = context;
    return BUGU_GPU_SUCCESS;
}

extern "C" BuguGpuExternalStatus buguGpuExternalDestroy(BuguGpuExternal* context)
{
    if (!context) return BUGU_GPU_INVALID_ARGUMENT;
    for (const Slot& slot : context->slots) if (slot.in_flight) return BUGU_GPU_QUEUE_FULL;
    destroy_resources(context);
    delete context;
    return BUGU_GPU_SUCCESS;
}

extern "C" BuguGpuExternalStatus buguGpuExternalSubmit(BuguGpuExternal* context,
                                                        uint8_t slot_index,
                                                        uint64_t slot_generation,
                                                        const BuguGpuPackedRequest* requests,
                                                        size_t count)
{
    if (!context || !requests || count == 0 || count > BUGU_GPU_MAX_BATCH ||
        slot_index >= BUGU_GPU_READBACK_SLOTS || slot_generation == 0) {
        return BUGU_GPU_INVALID_ARGUMENT;
    }
    Slot& slot = context->slots[slot_index];
    if (slot.in_flight && slot.discarded &&
        context->poll_ticket(context->executor_context, slot.ticket) == BUGU_GPU_SUCCESS) {
        slot.in_flight = false;
        slot.discarded = false;
    }
    if (slot.in_flight) return BUGU_GPU_QUEUE_FULL;
    for (size_t i = 0; i < count; ++i)
        if (requests[i].identity.device_generation != context->device_generation)
            return BUGU_GPU_STALE;

    float packed[BUGU_GPU_MAX_BATCH * kValues]{};
    for (size_t i = 0; i < count; ++i) {
        std::memcpy(packed + i * kValues, requests[i].values, kValues * sizeof(float));
        slot.identities[i] = requests[i].identity;
    }
    if (gpuUploadToBuffer(context->device, slot.io, packed, count * kValues * sizeof(float), 0) != GPU_SUCCESS)
        return BUGU_GPU_DEVICE_LOST;

    GpuCommandEncoder encoder = gpuBeginCommandEncoder(context->device, context->compute_queue);
    if (!encoder) return BUGU_GPU_FAILURE;
    GpuComputePassEncoder pass = gpuCmdBeginComputePass(encoder);
    GpuResult result = pass ? gpuComputeBindingDispatch(context->binding, pass, "gAcoustic", slot.io,
                                                        static_cast<uint32_t>(count), 1, 1)
                            : GPU_ERROR_UNKNOWN;
    if (pass) gpuCmdEndComputePass(pass);
    if (result == GPU_SUCCESS)
        result = gpuCmdCopyBuffer(encoder, slot.readback, 0, slot.io, 0, count * kValues * sizeof(float));
    if (result != GPU_SUCCESS) {
        gpuCancelCommandEncoder(encoder);
        return BUGU_GPU_FAILURE;
    }
    slot.command = gpuFinishCommandEncoder(encoder);
    if (!slot.command) return BUGU_GPU_FAILURE;
    uint64_t ticket = 0;
    const BuguGpuExternalStatus submit_status =
        context->submit_command(context->executor_context, slot.command, &ticket);
    if (submit_status != BUGU_GPU_SUCCESS || ticket == 0) {
        gpuDestroyCommandBuffer(slot.command);
        slot.command = nullptr;
        return submit_status == BUGU_GPU_SUCCESS ? BUGU_GPU_FAILURE : submit_status;
    }
    slot.command = nullptr; // consumed by the engine executor on successful submit
    slot.ticket = ticket;
    slot.generation = slot_generation;
    slot.count = count;
    slot.in_flight = true;
    slot.discarded = false;
    return BUGU_GPU_SUCCESS;
}

extern "C" BuguGpuExternalStatus buguGpuExternalPoll(BuguGpuExternal* context,
                                                      uint8_t slot_index,
                                                      uint64_t slot_generation,
                                                      BuguGpuPackedResponse* responses,
                                                      size_t capacity,
                                                      size_t* out_count)
{
    if (!context || !responses || !out_count || slot_index >= BUGU_GPU_READBACK_SLOTS)
        return BUGU_GPU_INVALID_ARGUMENT;
    *out_count = 0;
    Slot& slot = context->slots[slot_index];
    if (!slot.in_flight || slot.generation != slot_generation) return BUGU_GPU_STALE;
    if (capacity < slot.count) return BUGU_GPU_INVALID_ARGUMENT;
    const BuguGpuExternalStatus poll_status =
        context->poll_ticket(context->executor_context, slot.ticket);
    if (poll_status != BUGU_GPU_SUCCESS) return poll_status;

    void* mapped = nullptr;
    if (gpuMapReadbackBuffer(context->device, slot.readback, &mapped) != GPU_SUCCESS || !mapped)
        return BUGU_GPU_DEVICE_LOST;
    const float* packed = static_cast<const float*>(mapped);
    for (size_t i = 0; i < slot.count; ++i) {
        BuguGpuPackedResponse value{};
        value.identity = slot.identities[i];
        const float* output = packed + i * kValues + kOutputBase;
        value.direct_gain = output[0];
        value.transmission_gain = output[1];
        value.portal_gain = output[2];
        value.portal_direction[0] = output[3];
        value.portal_direction[1] = output[4];
        value.portal_direction[2] = 0.0f;
        value.openness = output[5];
        value.confidence = output[6];
        value.direct_lowpass_hz = output[7];
        responses[i] = value;
    }
    gpuUnmapReadbackBuffer(context->device, slot.readback);
    slot.in_flight = false;
    slot.discarded = false;
    *out_count = slot.count;
    return BUGU_GPU_SUCCESS;
}

extern "C" void buguGpuExternalDiscard(BuguGpuExternal* context, uint8_t slot_index, uint64_t slot_generation)
{
    if (!context || slot_index >= BUGU_GPU_READBACK_SLOTS) return;
    Slot& slot = context->slots[slot_index];
    if (!slot.in_flight || slot.generation != slot_generation) return;
    /* A completed command can be retired immediately. An incomplete command remains
       protected in its slot; a reset owner may invalidate it by changing generation. */
    context->discard_ticket(context->executor_context, slot.ticket);
    slot.discarded = true;
    if (context->poll_ticket(context->executor_context, slot.ticket) == BUGU_GPU_SUCCESS) {
        slot.in_flight = false;
        slot.discarded = false;
    }
}

extern "C" void buguGpuExternalSetDeviceGeneration(BuguGpuExternal* context, uint32_t generation)
{
    if (context && generation != 0) context->device_generation = generation;
}

extern "C" uint32_t buguGpuExternalDeviceGeneration(const BuguGpuExternal* context)
{
    return context ? context->device_generation : 0;
}
