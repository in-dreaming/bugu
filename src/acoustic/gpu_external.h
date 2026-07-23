#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct BuguGpuIdentity {
    uint64_t request_id;
    uint64_t source_id;
    uint64_t listener_id;
    uint64_t scene_id;
    uint32_t source_generation;
    uint32_t listener_generation;
    uint32_t scene_generation;
    uint32_t dynamic_generation;
    uint32_t device_generation;
} BuguGpuIdentity;

typedef struct BuguGpuPackedRequest {
    BuguGpuIdentity identity;
    float values[40];
} BuguGpuPackedRequest;

typedef struct BuguGpuPackedResponse {
    BuguGpuIdentity identity;
    float direct_gain;
    float transmission_gain;
    float portal_gain;
    float portal_direction[3];
    float openness;
    float confidence;
    float direct_lowpass_hz;
} BuguGpuPackedResponse;

typedef enum BuguGpuExternalStatus {
    BUGU_GPU_SUCCESS = 0,
    BUGU_GPU_PENDING = 1,
    BUGU_GPU_UNSUPPORTED = 2,
    BUGU_GPU_QUEUE_FULL = 3,
    BUGU_GPU_DEVICE_LOST = 4,
    BUGU_GPU_STALE = 5,
    BUGU_GPU_INVALID_ARGUMENT = 6,
    BUGU_GPU_FAILURE = 7,
} BuguGpuExternalStatus;

/* A successful submit consumes command_buffer; failure leaves it caller-owned. */
typedef BuguGpuExternalStatus (*BuguGpuSubmitCommandFn)(void* context,
                                                        void* command_buffer,
                                                        uint64_t* out_ticket);
typedef BuguGpuExternalStatus (*BuguGpuPollTicketFn)(void* context, uint64_t ticket);
/* Discard drops consumer interest but ticket must remain pollable until complete. */
typedef void (*BuguGpuDiscardTicketFn)(void* context, uint64_t ticket);

/* The embedding engine owns both opaque handles and the executor callbacks. */
typedef struct BuguGpuExternalCreateInfo {
    void* device;
    void* compute_queue;
    const char* shader_path;
    uint32_t device_generation;
    void* executor_context;
    BuguGpuSubmitCommandFn submit_command;
    BuguGpuPollTicketFn poll_ticket;
    BuguGpuDiscardTicketFn discard_ticket;
} BuguGpuExternalCreateInfo;

enum {
    BUGU_GPU_READBACK_SLOTS = 3,
    BUGU_GPU_MAX_BATCH = 32,
};

typedef struct BuguGpuExternal BuguGpuExternal;

BuguGpuExternalStatus buguGpuExternalCreate(const BuguGpuExternalCreateInfo* info,
                                             BuguGpuExternal** out_context);
/* Returns QUEUE_FULL while any slot is still in flight; never waits. */
BuguGpuExternalStatus buguGpuExternalDestroy(BuguGpuExternal* context);
BuguGpuExternalStatus buguGpuExternalSubmit(BuguGpuExternal* context,
                                             uint8_t slot,
                                             uint64_t slot_generation,
                                             const BuguGpuPackedRequest* requests,
                                             size_t count);
/* Maps readback memory only after its fence is complete; never waits. */
BuguGpuExternalStatus buguGpuExternalPoll(BuguGpuExternal* context,
                                           uint8_t slot,
                                           uint64_t slot_generation,
                                           BuguGpuPackedResponse* responses,
                                           size_t capacity,
                                           size_t* out_count);
void buguGpuExternalDiscard(BuguGpuExternal* context, uint8_t slot, uint64_t slot_generation);
void buguGpuExternalSetDeviceGeneration(BuguGpuExternal* context, uint32_t device_generation);
uint32_t buguGpuExternalDeviceGeneration(const BuguGpuExternal* context);

#ifdef __cplusplus
}
#endif
