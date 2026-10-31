<#
.SYNOPSIS
    Behaviour tests for the generator and validator (no Pester needed).

.DESCRIPTION
    The Python tests only check the shipped .wsb files. They would
    not have caught the override bug that shipped in the first
    version of the generator (overrides silently ignored), because
    the generator itself was never exercised. This script closes
    that gap: it runs the real generator and validator and asserts
    on their real output.

    Folder-mapping tests only run on Windows, because a mapped
    folder must be a Windows path that exists on the machine running
    the test. On other platforms those cases print SKIP, not FAIL,
    and the rest of the suite still runs.

    Validator failure cases run the validator as a subprocess
    (pwsh -File), not dot-sourced or in-process: the validator
    exits with code 1 on failure, and calling it in-process would
    end this test process with it.

    Run from the repository root:
        pwsh tests/Test-Generator.ps1
    Exits 0 when every case passes, 1 otherwise, and prints a
    per-case PASS/FAIL/SKIP line so a failure names its case.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Path $PSScriptRoot -Parent
$pwsh = (Get-Command -Name 'pwsh' -ErrorAction SilentlyContinue).Source
if (-not $pwsh) { $pwsh = 'pwsh' }
$testRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath 'wsb-toolkit-tests'
if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
[void](New-Item -Path $testRoot -ItemType Directory -Force)

$script:passed = 0
$script:failed = 0

function Assert-Test {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if ($Condition) {
        $script:passed++
        Write-Output "PASS: $Name"
    } else {
        $script:failed++
        Write-Output "FAIL: $Name $Detail"
    }
}

function Invoke-Validator {
    param([string]$Path, [switch]$SkipHostFolderCheck)
    $arguments = @('-NoProfile', '-File', (Join-Path -Path $repoRoot -ChildPath 'scripts/Test-SandboxConfig.ps1'), '-Path', $Path)
    if ($SkipHostFolderCheck) { $arguments += '-SkipHostFolderCheck' }
    $output = & $pwsh @arguments 2>&1
    return @{ ExitCode = $LASTEXITCODE; Output = ($output -join "`n") }
}

# 1. Untrusted defaults, no folder.
$untrusted = Join-Path -Path $testRoot -ChildPath 'untrusted.wsb'
& (Join-Path -Path $repoRoot -ChildPath 'scripts/New-SandboxConfig.ps1') -Profile Untrusted -OutputPath $untrusted -SkipValidation | Out-Null
$xml = [xml](Get-Content -LiteralPath $untrusted -Raw)
Assert-Test -Name 'Untrusted defaults' -Condition ($xml.Configuration.Networking -eq 'Disable' -and $xml.Configuration.ClipboardRedirection -eq 'Disable' -and $xml.Configuration.ProtectedClient -eq 'Enable' -and $xml.Configuration.MemoryInMB -eq '4096')

# 2. Overrides actually apply (the regression this suite exists for).
$dev = Join-Path -Path $testRoot -ChildPath 'dev.wsb'
& (Join-Path -Path $repoRoot -ChildPath 'scripts/New-SandboxConfig.ps1') -Profile DevTest -Networking Disable -VGpu Disable -MemoryInMB 8192 -LogonCommand 'notepad.exe' -OutputPath $dev -SkipValidation | Out-Null
$xml = [xml](Get-Content -LiteralPath $dev -Raw)
Assert-Test -Name 'Overrides apply' -Condition ($xml.Configuration.Networking -eq 'Disable' -and $xml.Configuration.vGPU -eq 'Disable' -and $xml.Configuration.MemoryInMB -eq '8192' -and $xml.Configuration.LogonCommand.Command -eq 'notepad.exe')

# 3. Memory below the minimum is raised, with a warning.
$low = Join-Path -Path $testRoot -ChildPath 'low.wsb'
& (Join-Path -Path $repoRoot -ChildPath 'scripts/New-SandboxConfig.ps1') -Profile DevTest -MemoryInMB 1024 -OutputPath $low -SkipValidation -WarningVariable warnings 3>&1 | Out-Null
$xml = [xml](Get-Content -LiteralPath $low -Raw)
Assert-Test -Name 'Memory floor' -Condition ($xml.Configuration.MemoryInMB -eq '2048' -and ($warnings -join ' ') -match '2048')

# 4. Conflicting switches and bad extensions fail, and fail fast.
$conflictFailed = $false
try { & (Join-Path -Path $repoRoot -ChildPath 'scripts/New-SandboxConfig.ps1') -ReadOnly -AllowWrite -OutputPath (Join-Path -Path $testRoot -ChildPath 'bad.wsb') -SkipValidation | Out-Null } catch { $conflictFailed = $true }
Assert-Test -Name 'ReadOnly+AllowWrite rejected' -Condition $conflictFailed

$extensionFailed = $false
try { & (Join-Path -Path $repoRoot -ChildPath 'scripts/New-SandboxConfig.ps1') -OutputPath (Join-Path -Path $testRoot -ChildPath 'bad.txt') -SkipValidation | Out-Null } catch { $extensionFailed = $true }
Assert-Test -Name 'Non-.wsb output rejected' -Condition $extensionFailed

# 5. -WhatIf writes nothing, and -Launch on non-Windows fails
#    before writing (both are automation-safety properties).
$whatIfPath = Join-Path -Path $testRoot -ChildPath 'whatif.wsb'
& (Join-Path -Path $repoRoot -ChildPath 'scripts/New-SandboxConfig.ps1') -OutputPath $whatIfPath -SkipValidation -WhatIf | Out-Null
Assert-Test -Name '-WhatIf writes nothing' -Condition (-not (Test-Path -LiteralPath $whatIfPath))
if (-not $IsWindows) {
    $launchPath = Join-Path -Path $testRoot -ChildPath 'launch.wsb'
    $launchFailed = $false
    try { & (Join-Path -Path $repoRoot -ChildPath 'scripts/New-SandboxConfig.ps1') -OutputPath $launchPath -Launch -SkipValidation | Out-Null } catch { $launchFailed = $true }
    Assert-Test -Name '-Launch fails before writing on non-Windows' -Condition ($launchFailed -and -not (Test-Path -LiteralPath $launchPath))
} else {
    Write-Output 'SKIP: -Launch failure case is non-Windows only'
}

# 6. Validator: shipped profiles pass, bad files fail.
foreach ($profile in @('untrusted.wsb', 'dev-test.wsb', 'installer-test.wsb')) {
    $result = Invoke-Validator -Path (Join-Path -Path $repoRoot -ChildPath "configs/$profile")
    Assert-Test -Name "Validator passes $profile" -Condition ($result.ExitCode -eq 0) -Detail $result.Output
}

$badValue = Join-Path -Path $testRoot -ChildPath 'badval.wsb'
Set-Content -LiteralPath $badValue -Value '<Configuration><Networking>Maybe</Networking><MemoryInMB>abc</MemoryInMB></Configuration>' -NoNewline
$result = Invoke-Validator -Path $badValue
Assert-Test -Name 'Validator rejects bad value and bad memory' -Condition ($result.ExitCode -eq 1)

$duplicate = Join-Path -Path $testRoot -ChildPath 'dup.wsb'
Set-Content -LiteralPath $duplicate -Value '<Configuration><Networking>Enable</Networking><Networking>Disable</Networking></Configuration>' -NoNewline
$result = Invoke-Validator -Path $duplicate
Assert-Test -Name 'Validator rejects duplicated element' -Condition ($result.ExitCode -eq 1)

$emptyMap = Join-Path -Path $testRoot -ChildPath 'emptymap.wsb'
Set-Content -LiteralPath $emptyMap -Value '<Configuration><MappedFolders></MappedFolders></Configuration>' -NoNewline
$result = Invoke-Validator -Path $emptyMap
Assert-Test -Name 'Validator rejects empty MappedFolders' -Condition ($result.ExitCode -eq 1)

# 7. XXE: a DOCTYPE with an external entity must fail validation
#    and must not leak the external file's content into the output.
$sentinel = Join-Path -Path $testRoot -ChildPath 'sentinel.txt'
Set-Content -LiteralPath $sentinel -Value 'XXE-SENTINEL-DO-NOT-LEAK' -NoNewline
$xxe = Join-Path -Path $testRoot -ChildPath 'xxe.wsb'
Set-Content -LiteralPath $xxe -Value ('<?xml version="1.0"?><!DOCTYPE Configuration [<!ENTITY xxe SYSTEM "file:///' + ($sentinel -replace '\\', '/') + '">]><Configuration><Networking>&xxe;</Networking></Configuration>') -NoNewline
$result = Invoke-Validator -Path $xxe
Assert-Test -Name 'Validator rejects XXE DOCTYPE without leaking' -Condition ($result.ExitCode -eq 1 -and $result.Output -notmatch 'XXE-SENTINEL')

# 8. Self-validation must survive a stale $LASTEXITCODE (CI
#    regression, 2026-10-31). The XXE case above ran the validator
#    as a subprocess that correctly exited 1, leaving
#    $LASTEXITCODE = 1 in this process. A generator run without
#    -SkipValidation must still succeed: the old generator read
#    that stale code and threw on a valid file, which is how the
#    Windows mapping case failed in CI. This case needs no folder,
#    so it runs on every platform -- unlike the mapping case, which
#    is why Linux CI never caught it.
$stale = Join-Path -Path $testRoot -ChildPath 'stale.wsb'
$staleFailed = $false
try { & (Join-Path -Path $repoRoot -ChildPath 'scripts/New-SandboxConfig.ps1') -Profile Untrusted -OutputPath $stale | Out-Null } catch { $staleFailed = $true }
Assert-Test -Name 'Self-validation survives stale LASTEXITCODE' -Condition (-not $staleFailed -and (Test-Path -LiteralPath $stale))

# 9. Folder mapping: Windows only, with a real temp folder.
if ($IsWindows) {
    $hostFolder = Join-Path -Path $testRoot -ChildPath 'host'
    [void](New-Item -Path $hostFolder -ItemType Directory -Force)
    $mapped = Join-Path -Path $testRoot -ChildPath 'mapped.wsb'
    & (Join-Path -Path $repoRoot -ChildPath 'scripts/New-SandboxConfig.ps1') -Profile Untrusted -HostFolder $hostFolder -OutputPath $mapped | Out-Null
    $xml = [xml](Get-Content -LiteralPath $mapped -Raw)
    Assert-Test -Name 'Untrusted mapping is read-only with default sandbox folder' -Condition ($xml.Configuration.MappedFolders.MappedFolder.HostFolder -eq $hostFolder -and $xml.Configuration.MappedFolders.MappedFolder.ReadOnly -eq 'true' -and $xml.Configuration.MappedFolders.MappedFolder.SandboxFolder -eq 'C:\Users\WDAGUtilityAccount\Desktop\host')
    $result = Invoke-Validator -Path $mapped
    Assert-Test -Name 'Validator passes generated mapping' -Condition ($result.ExitCode -eq 0) -Detail $result.Output
    $missing = Join-Path -Path $testRoot -ChildPath 'missing.wsb'
    Set-Content -LiteralPath $missing -Value '<Configuration><MappedFolders><MappedFolder><HostFolder>C:\NoSuchFolderXYZ-WSB</HostFolder><ReadOnly>true</ReadOnly></MappedFolder></MappedFolders></Configuration>' -NoNewline
    $result = Invoke-Validator -Path $missing
    Assert-Test -Name 'Validator rejects missing host folder' -Condition ($result.ExitCode -eq 1)
    $result = Invoke-Validator -Path $missing -SkipHostFolderCheck
    Assert-Test -Name 'Validator passes missing folder with -SkipHostFolderCheck' -Condition ($result.ExitCode -eq 0) -Detail $result.Output
} else {
    Write-Output 'SKIP: folder-mapping cases are Windows only'
}

Write-Output "Test-Generator: $($script:passed) passed, $($script:failed) failed"
if ($script:failed -gt 0) { exit 1 }
