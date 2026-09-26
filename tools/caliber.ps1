[CmdletBinding()]
param([Parameter(ValueFromRemainingArguments = $true)][string[]]$CaliberArguments)

$ErrorActionPreference = 'Stop'
$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

# Windows PowerShell 5.1 can turn redirected native stderr into a terminating
# NativeCommandError under ErrorActionPreference=Stop. Capture native exit codes
# explicitly so Git/Cargo/Caliber behavior is the same in 5.1 and PowerShell 7.
function Invoke-CaliberNative {
    param(
        [Parameter(Mandatory)][string]$Executable,
        [Parameter(Mandatory)][string[]]$NativeArguments
    )

    $previousPreference = $ErrorActionPreference
    $hasNativePreference = Test-Path variable:PSNativeCommandUseErrorActionPreference
    if ($hasNativePreference) { $previousNativePreference = $PSNativeCommandUseErrorActionPreference }
    try {
        $ErrorActionPreference = 'Continue'
        if ($hasNativePreference) { $PSNativeCommandUseErrorActionPreference = $false }
        $nativeOutput = & $Executable @NativeArguments 2>&1
        $nativeExitCode = $LASTEXITCODE
        $nativeText = (@($nativeOutput | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
        return [pscustomobject]@{ ExitCode = $nativeExitCode; Output = $nativeText }
    } finally {
        $ErrorActionPreference = $previousPreference
        if ($hasNativePreference) { $PSNativeCommandUseErrorActionPreference = $previousNativePreference }
    }
}
$CaliberCli = $env:CALIBER_CLI
if (-not $CaliberCli) {
    $onPath = Get-Command caliber -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($onPath) { $CaliberCli = $onPath.Source }
}

if (-not $CaliberCli) {
    $Git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $Git) { throw 'Git is required to bootstrap Caliber. Install Git and retry.' }
    $Cargo = Get-Command cargo -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $Cargo) { throw 'Cargo is required to bootstrap Caliber. Install Rust/Cargo and retry.' }

    $Revision = (Get-Content -Raw -LiteralPath (Join-Path $ProjectRoot '.caliber-cli-revision')).Trim()
    if ($Revision -notmatch '^[0-9a-f]{40}$') { throw 'Malformed Caliber CLI bootstrap revision.' }
    $Repository = if ($env:CALIBER_CLI_REPOSITORY) { $env:CALIBER_CLI_REPOSITORY } else { 'https://github.com/samanshaiza004/caliber.git' }
    $ToolsRoot = Join-Path $ProjectRoot '.tools'
    $SourceRoot = Join-Path $ToolsRoot 'caliber-cli-source'
    New-Item -ItemType Directory -Force -Path $ToolsRoot | Out-Null

    if (-not (Test-Path -LiteralPath $SourceRoot)) {
        New-Item -ItemType Directory -Path $SourceRoot | Out-Null
        $Init = Invoke-CaliberNative $Git.Source @('-C', $SourceRoot, 'init', '--quiet')
        if ($Init.ExitCode -ne 0) { throw "Could not initialize the Caliber CLI bootstrap checkout.`n$($Init.Output)" }
        $AddRemote = Invoke-CaliberNative $Git.Source @('-C', $SourceRoot, 'remote', 'add', 'origin', $Repository)
        if ($AddRemote.ExitCode -ne 0) { throw "Could not configure the Caliber CLI bootstrap remote.`n$($AddRemote.Output)" }
    } else {
        $OriginResult = Invoke-CaliberNative $Git.Source @('-C', $SourceRoot, 'remote', 'get-url', 'origin')
        $Origin = $OriginResult.Output.Trim()
        if ($OriginResult.ExitCode -ne 0 -or $Origin -ne $Repository) { throw "Caliber CLI bootstrap origin mismatch at $SourceRoot; inspect it instead of replacing it." }
        $DirtyResult = Invoke-CaliberNative $Git.Source @('-C', $SourceRoot, 'status', '--porcelain', '--untracked-files=all')
        $Dirty = $DirtyResult.Output
        if ($DirtyResult.ExitCode -ne 0) { throw "Could not inspect the Caliber CLI bootstrap checkout.`n$Dirty" }
        if ($Dirty) { throw "Caliber CLI bootstrap checkout is dirty at $SourceRoot; it was left untouched." }
    }

    $CommitProbe = Invoke-CaliberNative $Git.Source @('-C', $SourceRoot, 'cat-file', '-e', "$Revision^{commit}")
    $HasCommit = $CommitProbe.ExitCode -eq 0
    if (-not $HasCommit) {
        $FetchResult = Invoke-CaliberNative $Git.Source @('-C', $SourceRoot, 'fetch', '--quiet', 'origin', $Revision)
        $FetchCode = $FetchResult.ExitCode
        $CommitProbe = Invoke-CaliberNative $Git.Source @('-C', $SourceRoot, 'cat-file', '-e', "$Revision^{commit}")
        $HasCommit = $CommitProbe.ExitCode -eq 0
        if (-not $HasCommit -and $FetchCode -ne 0) {
            $null = Invoke-CaliberNative $Git.Source @('-C', $SourceRoot, 'fetch', '--quiet', 'origin', 'main')
            $CommitProbe = Invoke-CaliberNative $Git.Source @('-C', $SourceRoot, 'cat-file', '-e', "$Revision^{commit}")
            $HasCommit = $CommitProbe.ExitCode -eq 0
        }
    }
    if (-not $HasCommit) { throw "Pinned Caliber CLI commit is unavailable from ${Repository}: ${Revision}" }
    $HeadResult = Invoke-CaliberNative $Git.Source @('-C', $SourceRoot, 'rev-parse', '--verify', 'HEAD')
    $Head = if ($HeadResult.ExitCode -eq 0) { $HeadResult.Output.Trim() } else { '' }
    if ($Head -ne $Revision) {
        $Checkout = Invoke-CaliberNative $Git.Source @('-C', $SourceRoot, 'checkout', '--quiet', '--detach', $Revision)
        if ($Checkout.ExitCode -ne 0) { throw "Could not check out the pinned Caliber CLI source.`n$($Checkout.Output)" }
    }

    $Build = Invoke-CaliberNative $Cargo.Source @('build', '--locked', '--release', '--manifest-path', (Join-Path $SourceRoot 'Cargo.toml'), '-p', 'caliber', '--bin', 'caliber')
    if ($Build.Output) { Write-Host $Build.Output }
    if ($Build.ExitCode -ne 0) { throw 'Building the pinned Caliber CLI failed.' }
    $CaliberCli = Join-Path $SourceRoot 'target\release\caliber.exe'
    if (-not (Test-Path -LiteralPath $CaliberCli -PathType Leaf)) { throw "Caliber CLI binary was not produced: $CaliberCli" }
}

$CaliberResult = Invoke-CaliberNative $CaliberCli $CaliberArguments
if ($CaliberResult.Output) { Write-Host $CaliberResult.Output }
if ($CaliberResult.ExitCode -ne 0) { throw "Caliber CLI exited with code $($CaliberResult.ExitCode)." }
