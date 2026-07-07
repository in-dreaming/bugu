$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$gpu = Join-Path $root "third_party/in_dreaming_gpu"

function Test-Contains($Path, $Pattern) {
    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }
    return [bool](Select-String -LiteralPath $Path -Pattern $Pattern -Quiet)
}

if (-not (Test-Path -LiteralPath $gpu)) {
    Write-Output "in_dreaming_gpu.present=false"
    exit 1
}

$commit = git -C $gpu rev-parse HEAD
Write-Output "in_dreaming_gpu.present=true"
Write-Output "in_dreaming_gpu.commit=$commit"
Write-Output "cmake.available=$([bool](Get-Command cmake -ErrorAction SilentlyContinue))"

$nested = Join-Path $gpu "modules/3rd/slang-rhi"
$nestedInitialized = $false
if (Test-Path -LiteralPath $nested) {
    $nestedInitialized = ((Get-ChildItem -Force -LiteralPath $nested -ErrorAction SilentlyContinue | Measure-Object).Count -gt 0)
}
Write-Output "nested.slang_rhi.initialized=$nestedInitialized"

$computeBinding = Join-Path $gpu "src/gpu/pipeline/gpu_compute_binding.h"
$queueHeader = Join-Path $gpu "src/gpu/core/gpu_command.h"
$graphHeader = Join-Path $gpu "src/gpu/rendergraph/gpu_render_graph.h"
$readbackHeader = Join-Path $gpu "src/gpu/resource/gpu_readback.h"
$rayHeader = Join-Path $gpu "src/gpu/raytracing/gpu_raytracing.h"
$asyncExample = Join-Path $gpu "examples/25_async_compute_graph/main.c"
$computeExample = Join-Path $gpu "examples/07_compute_pipeline/main.c"

Write-Output "api.compute_binding_dispatch=$(Test-Contains $computeBinding 'gpuComputeBindingDispatch')"
Write-Output "api.queue_info=$(Test-Contains $queueHeader 'gpuGetQueueInfo')"
Write-Output "api.independent_queues=$(Test-Contains $graphHeader 'gpuDeviceSupportsIndependentQueues')"
Write-Output "api.readback_buffer=$(Test-Contains $readbackHeader 'gpuCreateReadbackBuffer')"
Write-Output "api.map_readback=$(Test-Contains $readbackHeader 'gpuMapReadbackBuffer')"
Write-Output "api.raytrace_pipeline=$(Test-Contains $rayHeader 'gpuCreateRayTracingPipeline')"
Write-Output "api.trace_rays=$(Test-Contains $rayHeader 'gpuCmdTraceRays')"
Write-Output "example.async_compute_dispatch=$(Test-Contains $asyncExample 'gpuComputeBindingDispatch')"
Write-Output "example.async_compute_download=$(Test-Contains $asyncExample 'gpuDownloadFromBuffer')"
Write-Output "example.basic_compute_validation_skipped=$(Test-Contains $computeExample 'Validation: SKIPPED')"
