param(
    [switch]$Gpu,
    [string]$DongBuildEnv = "E:\env\activate-dong-build.ps1",
    [string]$GpuBuildDir = "build\gpu_acoustic_spike"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

function Invoke-ValidationStep {
    param(
        [string]$Name,
        [string]$Executable,
        [string[]]$Arguments
    )

    $display = "$Executable $($Arguments -join ' ')"
    Write-Host "==> $Name"
    Write-Host "    $display"
    $start = Get-Date
    & $Executable @Arguments
    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { $LASTEXITCODE }
    if ($exitCode -ne 0) {
        throw "Validation step '$Name' failed with exit code $exitCode"
    }
    $elapsed = (Get-Date) - $start
    Write-Host ("<== {0} passed in {1:n2}s" -f $Name, $elapsed.TotalSeconds)
}

$zigSteps = @(
    @{ Name = "unit tests"; Args = @("build", "test") },
    @{ Name = "asset demo"; Args = @("build", "asset-demo") },
    @{ Name = "event demo"; Args = @("build", "event-demo") },
    @{ Name = "spatial demo"; Args = @("build", "spatial-demo") },
    @{ Name = "acoustic demo"; Args = @("build", "acoustic-demo") },
    @{ Name = "acoustic mapping demo"; Args = @("build", "acoustic-mapping-demo") },
    @{ Name = "acoustic effects demo"; Args = @("build", "acoustic-effects-demo") },
    @{ Name = "acoustic event demo"; Args = @("build", "acoustic-event-demo") },
    @{ Name = "effect bus demo"; Args = @("build", "effect-bus-demo") },
    @{ Name = "validation report"; Args = @("build", "validation-report") },
    @{ Name = "offline tone render"; Args = @("build", "tone", "--", "--offline", "--seconds", "0.25", "--voices", "16", "--out", "bugu-validation-tone.wav") }
)

foreach ($step in $zigSteps) {
    Invoke-ValidationStep -Name $step.Name -Executable "zig" -Arguments $step.Args
}

if ($Gpu) {
    if (!(Test-Path -LiteralPath $DongBuildEnv)) {
        throw "GPU validation requested, but dong build environment was not found: $DongBuildEnv"
    }

    . $DongBuildEnv
    Invoke-ValidationStep -Name "configure gpu acoustic spike" -Executable "cmake" -Arguments @(
        "-S", "tools/gpu_acoustic_spike",
        "-B", $GpuBuildDir,
        "-G", "Ninja",
        "-DCMAKE_BUILD_TYPE=Release"
    )
    Invoke-ValidationStep -Name "build gpu acoustic spike" -Executable "cmake" -Arguments @(
        "--build", $GpuBuildDir,
        "--target", "bugu_gpu_acoustic_spike"
    )
    Invoke-ValidationStep -Name "run gpu acoustic spike" -Executable (Join-Path $GpuBuildDir "bugu_gpu_acoustic_spike.exe") -Arguments @()
}

Write-Host "Bugu validation passed."
