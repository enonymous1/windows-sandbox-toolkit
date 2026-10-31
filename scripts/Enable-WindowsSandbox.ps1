<#
.SYNOPSIS
    Checks (and optionally enables) the Windows Sandbox feature.

.DESCRIPTION
    Preflight for Windows Sandbox: it must run on Windows, on a
    supported edition, with virtualization enabled in firmware, and
    with the Containers-DisposableClientVM optional feature turned on.
    Without -Enable it only reports the current state and what is
    missing. With -Enable it turns the feature on (administrator
    required) and tells you a restart is needed.

    Windows Sandbox is NOT available on Windows Home. This script
    refuses to pretend otherwise: on Home it reports the edition as
    unsupported instead of enabling something that will not work.

    Edition and feature names come from schema/wsb-schema.json, not
    from literals copied into this script.

.PARAMETER Enable
    Turn the Windows Sandbox feature on if it is off. Supports
    -WhatIf: with -WhatIf it reports what it would do without
    changing the system, which is the safe way to preview a
    system-changing script.

.EXAMPLE
    .\scripts\Enable-WindowsSandbox.ps1

.EXAMPLE
    # Run PowerShell as administrator first:
    .\scripts\Enable-WindowsSandbox.ps1 -Enable

.EXAMPLE
    .\scripts\Enable-WindowsSandbox.ps1 -Enable -WhatIf

.NOTES
    Requires PowerShell 5.1+ or PowerShell 7+ on Windows. This script
    is part of the repository: it imports scripts/SandboxSchema.psm1
    and reads schema/wsb-schema.json. Do not copy it out on its own.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $false)]
    [switch]$Enable
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $IsWindows) {
    throw 'This script runs on Windows only.'
}

Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'SandboxSchema.psm1') -ErrorAction Stop
$schema = Get-SandboxSchema

# Get-CimInstance Win32_OperatingSystem is used instead of
# Get-ComputerInfo on purpose: Get-ComputerInfo collects every
# property it knows about and is noticeably slow to run, while
# this script only needs the edition name from the caption.
$caption = (Get-CimInstance -ClassName Win32_OperatingSystem).Caption
Write-Output "Edition: $caption"
$supported = $false
foreach ($edition in $schema.supportedEditions) {
    if ($caption -match "\b$edition\b") { $supported = $true }
}
if (-not $supported) {
    throw "Windows Sandbox is not supported on this edition ($caption). It requires $($schema.supportedEditions -join ', ') -- not Home."
}

$processor = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1
if ($null -eq $processor.VirtualizationFirmwareEnabled) {
    # $null is not $false: on some VMs and firmware the property is
    # simply not reported. Reporting it as enabled would be a lie,
    # and reporting it as disabled would send the user to their
    # BIOS for no reason. Unknown is the honest answer.
    Write-Warning 'Virtualization firmware state could not be determined on this machine. If Sandbox fails to start, check BIOS/UEFI virtualization settings.'
} elseif ($processor.VirtualizationFirmwareEnabled -eq $false) {
    Write-Warning 'Virtualization is disabled in firmware (BIOS/UEFI). Enable it there, then re-run this script.'
} else {
    Write-Output 'Virtualization: enabled in firmware.'
}

$feature = Get-WindowsOptionalFeature -Online -FeatureName $schema.featureName
Write-Output "Windows Sandbox feature: $($feature.State)"

if ($feature.State -eq 'Enabled') {
    Write-Output 'Windows Sandbox is ready. Launch a .wsb file to start it.'
    return
}

if ($feature.State -match 'Pending') {
    # A previous enable/disable is waiting on a restart. Trying to
    # enable again now would only confuse the state further.
    Write-Output 'Windows Sandbox is in a pending state. Restart your computer, then re-run this script.'
    return
}

if (-not $Enable) {
    Write-Output 'Run with -Enable from an elevated PowerShell prompt to turn it on.'
    return
}

# Administrator is only checked when a change is actually requested;
# a read-only report should not need elevation to run.
$principal = New-Object -TypeName System.Security.Principal.WindowsPrincipal -ArgumentList ([System.Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    throw 'Enabling Windows Sandbox requires an elevated (Run as administrator) PowerShell prompt.'
}

if ($PSCmdlet.ShouldProcess('Windows Sandbox feature', 'Enable')) {
    Enable-WindowsOptionalFeature -Online -FeatureName $schema.featureName -All -NoRestart | Out-Null
    Write-Output 'Windows Sandbox enabled. Restart your computer, then launch a .wsb file.'
}
