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

.PARAMETER Enable
    Turn the Windows Sandbox feature on if it is off.

.EXAMPLE
    .\scripts\Enable-WindowsSandbox.ps1

.EXAMPLE
    # Run PowerShell as administrator first:
    .\scripts\Enable-WindowsSandbox.ps1 -Enable
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [switch]$Enable
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $IsWindows) {
    throw 'This script runs on Windows only.'
}

$principal = New-Object -TypeName System.Security.Principal.WindowsPrincipal -ArgumentList ([System.Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)

$productName = (Get-ComputerInfo).WindowsProductName
Write-Output "Edition: $productName"
if ($productName -notmatch 'Pro|Enterprise|Education') {
    throw "Windows Sandbox is not supported on this edition ($productName). It requires Pro, Enterprise, or Education -- not Home."
}

$processor = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1
if ($processor.VirtualizationFirmwareEnabled -eq $false) {
    Write-Warning 'Virtualization is disabled in firmware (BIOS/UEFI). Enable it there, then re-run this script.'
} else {
    Write-Output 'Virtualization: enabled in firmware.'
}

$feature = Get-WindowsOptionalFeature -Online -FeatureName 'Containers-DisposableClientVM'
Write-Output "Windows Sandbox feature: $($feature.State)"

if ($feature.State -eq 'Enabled') {
    Write-Output 'Windows Sandbox is ready. Launch a .wsb file to start it.'
    return
}

if (-not $Enable) {
    Write-Output 'Run with -Enable from an elevated PowerShell prompt to turn it on.'
    return
}

if (-not $isAdmin) {
    throw 'Enabling Windows Sandbox requires an elevated (Run as administrator) PowerShell prompt.'
}

Enable-WindowsOptionalFeature -Online -FeatureName 'Containers-DisposableClientVM' -All -NoRestart | Out-Null
Write-Output 'Windows Sandbox enabled. Restart your computer, then launch a .wsb file.'
