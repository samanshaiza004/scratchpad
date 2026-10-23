[CmdletBinding()]
param([string]$Executable = 'out/alicorn/scratchpad-alicorn.exe', [string]$OutputDirectory = 'out/workbench-relief', [switch]$Workbench)
$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ExecutablePath = (Resolve-Path (Join-Path $Root $Executable)).Path
$OutputPath = [IO.Path]::GetFullPath((Join-Path $Root $OutputDirectory))
New-Item -ItemType Directory -Force -Path $OutputPath | Out-Null
$Names = @('SCRATCHPAD_APPEARANCE_FIXTURE', 'SCRATCHPAD_ALICORN_SMOKE', 'SCRATCHPAD_DISABLE_SESSION', 'SCRATCHPAD_DISABLE_RECOVERY', 'SCRATCHPAD_ALICORN_WORKSPACE')
$Previous = @{}
foreach ($Name in $Names) { $Previous[$Name] = [Environment]::GetEnvironmentVariable($Name) }
try {
    $env:SCRATCHPAD_ALICORN_SMOKE = '1'
    $env:SCRATCHPAD_DISABLE_SESSION = '1'
    $env:SCRATCHPAD_DISABLE_RECOVERY = '1'
    $env:SCRATCHPAD_ALICORN_WORKSPACE = $Root
    foreach ($Appearance in @('flat', 'relief', 'contrast')) {
        $env:SCRATCHPAD_APPEARANCE_FIXTURE = if ($Workbench) { "workbench-$Appearance" } else { $Appearance }
        $CapturePath = Join-Path $OutputPath $Appearance
        New-Item -ItemType Directory -Force -Path $CapturePath | Out-Null
        $CaptureAfter = if ($Workbench) { '--capture-after=1' } else { '--capture-after=0' }
        $Process = Start-Process -FilePath $ExecutablePath -ArgumentList @($CaptureAfter, "--capture-dir=`"$CapturePath`"") -WorkingDirectory $Root -WindowStyle Hidden -PassThru -RedirectStandardOutput (Join-Path $CapturePath 'stdout.txt') -RedirectStandardError (Join-Path $CapturePath 'stderr.txt')
        if (-not $Process.WaitForExit(15000)) {
            $Process.Kill()
            throw "Appearance capture timed out: $Appearance"
        }
        if ($Process.ExitCode -ne 0) { throw "Appearance capture failed: $Appearance (exit $($Process.ExitCode))" }
        if (-not (Get-ChildItem -LiteralPath $CapturePath -Filter screenshot.ppm -Recurse)) { throw "No GPU screenshot captured for $Appearance" }
        Write-Output "$Appearance capture and native smoke: PASS ($CapturePath)"
    }
} finally {
    foreach ($Name in $Names) { [Environment]::SetEnvironmentVariable($Name, $Previous[$Name]) }
}
