$ErrorActionPreference = 'Stop'
$builder = Join-Path $PSScriptRoot '..\windows\build-windows.ps1'
$workspace = Join-Path ([System.IO.Path]::GetTempPath()) ('guix-build-test-' + [guid]::NewGuid())
$stages = @('venv', 'pip-upgrade', 'pip-install', 'pyinstaller', 'choco', 'candle', 'light')

# Tool doubles retain native exit-code behavior without installing build tools.
$runner = @'
param([string]$FailureStage, [string]$OutputMode)
$ErrorActionPreference = 'Stop'
$script:FailureStage = $FailureStage
$script:OutputMode = $OutputMode
$script:LogPath = Join-Path $PSScriptRoot 'commands.txt'

function Invoke-TestTool {
    param([string]$Stage)
    [System.IO.File]::AppendAllLines($script:LogPath, [string[]]@($Stage))
    if ($Stage -eq $script:FailureStage) {
        & $env:ComSpec /d /c 'exit 37'
        return
    }
    $output = switch ($Stage) {
        'pyinstaller' { 'dist\GuixInstall.exe' }
        'candle' { 'dist\guix-install.wixobj' }
        'light' { 'dist\GuixInstall.msi' }
    }
    if ($output) {
        $kind = switch ($Stage) {
            'pyinstaller' { 'exe' }
            'candle' { 'object' }
            'light' { 'msi' }
        }
        if ($script:OutputMode -ne "missing-$kind") {
            New-Item -ItemType Directory -Force -Path dist | Out-Null
            $content = if ($script:OutputMode -eq "empty-$kind") { '' } else { "new-$Stage" }
            [System.IO.File]::WriteAllText((Join-Path $PWD $output), $content)
        }
    }
    & $env:ComSpec /d /c 'exit 0'
}

function python { Invoke-TestTool 'venv' }
function choco { Invoke-TestTool 'choco' }
function candle.exe { Invoke-TestTool 'candle' }
function light.exe { Invoke-TestTool 'light' }
function Get-Command {
    [CmdletBinding()]
    param([string]$Name)
    if ($Name -eq 'candle.exe') { return $null }
    Microsoft.PowerShell.Core\Get-Command $Name -ErrorAction SilentlyContinue
}

# The venv executables do not exist in this fixture. Resolve their commands to
# doubles while executing the unchanged build script and its real control flow.
$ExecutionContext.InvokeCommand.CommandNotFoundAction = {
    param($commandName, $lookup)
    if ($commandName -match '(^|[\\/])\.winvenv[\\/]Scripts[\\/]python\.exe$') {
        $lookup.CommandScriptBlock = {
            if ($args -contains '--upgrade') {
                Invoke-TestTool 'pip-upgrade'
            } else {
                Invoke-TestTool 'pip-install'
            }
        }
        $lookup.StopSearch = $true
    } elseif ($commandName -match '(^|[\\/])\.winvenv[\\/]Scripts[\\/]pyinstaller\.exe$') {
        $lookup.CommandScriptBlock = { Invoke-TestTool 'pyinstaller' }
        $lookup.StopSearch = $true
    }
}
& (Join-Path $PSScriptRoot 'windows\build-windows.ps1')
'@

function Invoke-BuildCase {
    param([string]$Name, [string]$FailureStage = 'none', [string]$OutputMode = 'normal')
    $root = Join-Path $workspace $Name
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'windows'), (Join-Path $root 'dist') | Out-Null
    Copy-Item -LiteralPath $builder -Destination (Join-Path $root 'windows\build-windows.ps1')
    Set-Content -LiteralPath (Join-Path $root 'run.ps1') -Value $runner
    Set-Content -LiteralPath (Join-Path $root 'dist\GuixInstall.exe') -Value 'stale-exe'
    Set-Content -LiteralPath (Join-Path $root 'dist\GuixInstall.msi') -Value 'stale-msi'
    $previousPreference = $ErrorActionPreference
    try {
        # Capture child diagnostics without treating native stderr as a parent
        # exception in Windows PowerShell 5.1.
        $ErrorActionPreference = 'Continue'
        $output = & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass `
            -File (Join-Path $root 'run.ps1') -FailureStage $FailureStage -OutputMode $OutputMode 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    $calls = @(Get-Content -LiteralPath (Join-Path $root 'commands.txt'))
    return @{ Root = $root; ExitCode = $exitCode; Output = $output; Calls = $calls }
}

function Assert-Stages {
    param($Result, [string[]]$Expected)
    if (($Result.Calls -join ',') -ne ($Expected -join ',')) {
        throw "Build did not stop at the expected stage: $($Result.Calls -join ',').`n$($Result.Output)"
    }
}

try {
    $success = Invoke-BuildCase 'success'
    if ($success.ExitCode -ne 0) { throw "Successful tools failed: $($success.Output)" }
    Assert-Stages $success $stages
    foreach ($name in @('GuixInstall.exe', 'GuixInstall.msi')) {
        $artifact = Get-Item -LiteralPath (Join-Path $success.Root "dist\$name")
        if ($artifact.Length -eq 0 -or (Get-Content -LiteralPath $artifact.FullName) -like 'stale-*') {
            throw "Build did not replace $name."
        }
    }

    for ($index = 0; $index -lt $stages.Count; $index++) {
        $stage = $stages[$index]
        $result = Invoke-BuildCase "failed-$stage" -FailureStage $stage
        if ($result.ExitCode -eq 0 -or $result.Output -notmatch 'exit code 37') {
            throw "Native failure was not reported for ${stage}: $($result.Output)"
        }
        Assert-Stages $result $stages[0..$index]
        if (Test-Path -LiteralPath (Join-Path $result.Root 'dist\GuixInstall.msi')) {
            throw "Failed $stage left a stale MSI."
        }
        if ($index -le 3 -and (Test-Path -LiteralPath (Join-Path $result.Root 'dist\GuixInstall.exe'))) {
            throw "Failed $stage left a stale executable."
        }
    }

    foreach ($mode in @('missing-exe', 'empty-exe', 'missing-msi', 'empty-msi')) {
        $result = Invoke-BuildCase $mode -OutputMode $mode
        if ($result.ExitCode -eq 0) { throw "Build accepted $mode." }
        $expected = if ($mode.EndsWith('exe')) { $stages[0..3] } else { $stages }
        Assert-Stages $result $expected
    }
    Write-Host 'Windows build failure regression passed.'
} finally {
    if (Test-Path -LiteralPath $workspace) {
        Remove-Item -LiteralPath $workspace -Recurse -Force
    }
}
exit 0
