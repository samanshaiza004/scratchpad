[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('build', 'test', 'smoke', 'run')]
    [string]$Command = 'test',

    [string]$Go,
    [string]$Odin,

    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$Arguments
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

# Resolve the project lock before the frontend driver validates/builds tools.
& (Join-Path $PSScriptRoot 'caliber.ps1') sync --project-root $ProjectRoot
if ($LASTEXITCODE -ne 0) {
    throw "Locked dependency sync failed with exit code $LASTEXITCODE."
}

$RequestedGo = if ($Go) { $Go } elseif ($env:SCRATCHPAD_GO) { $env:SCRATCHPAD_GO } else { 'go' }
$GoCommand = Get-Command $RequestedGo -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $GoCommand) {
    throw "Go executable not found: $RequestedGo. Install 64-bit Go with cgo enabled, or pass -Go PATH."
}

$DriverArguments = @('run', './cmd/alicorn-dev', $Command, '--go', $GoCommand.Source)
if ($Odin) { $DriverArguments += @('--odin', $Odin) }
if ($Arguments) { $DriverArguments += $Arguments }

Push-Location $ProjectRoot
try {
    $PreviousErrorActionPreference = $ErrorActionPreference
    $HasNativePreference = Test-Path variable:PSNativeCommandUseErrorActionPreference
    if ($HasNativePreference) { $PreviousNativePreference = $PSNativeCommandUseErrorActionPreference }
    try {
        # Keep PowerShell 5.1 from promoting native compiler diagnostics to a
        # terminating NativeCommandError before we can read the process status.
        $ErrorActionPreference = 'Continue'
        if ($HasNativePreference) { $PSNativeCommandUseErrorActionPreference = $false }
        & $GoCommand.Source @DriverArguments
        $DriverExitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $PreviousErrorActionPreference
        if ($HasNativePreference) { $PSNativeCommandUseErrorActionPreference = $PreviousNativePreference }
    }
    if ($DriverExitCode -ne 0) {
        throw "Alicorn frontend $Command failed with exit code $DriverExitCode."
    }
} finally {
    Pop-Location
}
