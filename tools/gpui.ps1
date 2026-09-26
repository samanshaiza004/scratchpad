[CmdletBinding()]
param(
    [Parameter(Position = 0)][ValidateSet('build', 'test', 'run', 'smoke', 'measure')][string]$Command = 'test',
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments
)

$ErrorActionPreference = 'Stop'
$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$SyncArguments = @('sync', '--project-root', $ProjectRoot)
$CaliberRoot = $env:CALIBER_ROOT
$AllowRevision = $false
if ($CaliberRoot) {
    $SyncArguments += @('--override', "caliber=$CaliberRoot")
    if ($env:SCRATCHPAD_DEV_DEPS -match '^(1|true|yes)$') {
        $SyncArguments += '--allow-dirty-overrides'
        $AllowRevision = $true
    }
}
& (Join-Path $PSScriptRoot 'caliber.ps1') @SyncArguments
if ($LASTEXITCODE -ne 0) { throw "Caliber dependency sync failed with exit code $LASTEXITCODE." }

$GoArguments = @('run', './cmd/gpui-dev', $Command) + $Arguments
if ($CaliberRoot) { $GoArguments += @('--caliber-root', $CaliberRoot) }
if ($AllowRevision) { $GoArguments += '--allow-caliber-revision' }
Push-Location $ProjectRoot
try {
    & go @GoArguments
    if ($LASTEXITCODE -ne 0) { throw "gpui-dev $Command failed with exit code $LASTEXITCODE." }
} finally { Pop-Location }
