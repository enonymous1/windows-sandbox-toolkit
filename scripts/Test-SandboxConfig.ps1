<#
.SYNOPSIS
    Validates a Windows Sandbox (.wsb) configuration file.

.DESCRIPTION
    Checks a .wsb file against the documented Windows Sandbox schema:
    only known elements, only allowed values, a numeric MemoryInMB,
    and mapped folders whose host folder actually exists. A missing
    host folder is an error by default, because Windows Sandbox fails
    to start in that case -- pass -SkipHostFolderCheck only when you
    are validating a template that will be generated for another
    machine.

    Exits 0 when the file is valid, 1 when it is not. Warnings (for
    example MemoryInMB below 2048, which Windows Sandbox raises
    automatically) do not fail the check.

.PARAMETER Path
    The .wsb file to validate.

.PARAMETER SkipHostFolderCheck
    Do not require mapped host folders to exist on this machine.

.EXAMPLE
    .\scripts\Test-SandboxConfig.ps1 -Path '.\configs\untrusted.wsb'

.EXAMPLE
    Get-ChildItem -Path '.\configs' -Filter '*.wsb' | ForEach-Object {
        .\scripts\Test-SandboxConfig.ps1 -Path $_.FullName
    }
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Path,

    [Parameter(Mandatory = $false)]
    [switch]$SkipHostFolderCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "File not found: $Path"
}
if ($Path -notlike '*.wsb') {
    throw "Expected a .wsb file. Got: $Path"
}

$allowedValues = @{
    vGPU = @('Enable', 'Disable', 'Default')
    Networking = @('Enable', 'Disable', 'Default')
    AudioInput = @('Enable', 'Disable', 'Default')
    VideoInput = @('Enable', 'Disable', 'Default')
    ProtectedClient = @('Enable', 'Disable', 'Default')
    PrinterRedirection = @('Enable', 'Disable', 'Default')
    ClipboardRedirection = @('Enable', 'Disable', 'Default')
}
$allowedElements = @(
    'vGPU', 'Networking', 'MappedFolders', 'MappedFolder', 'HostFolder',
    'SandboxFolder', 'ReadOnly', 'LogonCommand', 'Command', 'AudioInput',
    'VideoInput', 'ProtectedClient', 'PrinterRedirection',
    'ClipboardRedirection', 'MemoryInMB'
)

$errors = New-Object -TypeName System.Collections.Generic.List[string]
$warnings = New-Object -TypeName System.Collections.Generic.List[string]

try {
    $xml = New-Object -TypeName System.Xml.XmlDocument
    $xml.Load($Path)
} catch {
    Write-Error "Invalid XML in ${Path}: $($_.Exception.Message)"
    exit 1
}

$root = $xml.DocumentElement
if ($null -eq $root -or $root.Name -ne 'Configuration') {
    Write-Error 'Root element must be <Configuration>.'
    exit 1
}

foreach ($child in $root.ChildNodes) {
    if ($child.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
    if ($allowedElements -notcontains $child.Name) {
        $errors.Add("Unknown element: <$($child.Name)>")
        continue
    }
    if ($allowedValues.ContainsKey($child.Name)) {
        if ($allowedValues[$child.Name] -notcontains $child.InnerText) {
            $errors.Add("Invalid value for <$($child.Name)>: '$($child.InnerText)'. Allowed: $($allowedValues[$child.Name] -join ', ')")
        }
    }
    if ($child.Name -eq 'MemoryInMB') {
        $memory = 0
        if (-not [int]::TryParse($child.InnerText, [ref]$memory)) {
            $errors.Add("MemoryInMB must be a number. Got: '$($child.InnerText)'")
        } elseif ($memory -lt 2048) {
            $warnings.Add("MemoryInMB $memory is below 2048; Windows Sandbox raises it to 2048 automatically.")
        }
    }
    if ($child.Name -eq 'MappedFolders') {
        foreach ($folder in $child.ChildNodes) {
            if ($folder.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
            if ($folder.Name -ne 'MappedFolder') {
                $errors.Add("Unknown element inside <MappedFolders>: <$($folder.Name)>")
                continue
            }
            $hostFolder = $null
            $sandboxFolder = $null
            $readOnly = $null
            foreach ($field in $folder.ChildNodes) {
                if ($field.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
                if ($allowedElements -notcontains $field.Name) {
                    $errors.Add("Unknown element inside <MappedFolder>: <$($field.Name)>")
                }
                if ($field.Name -eq 'HostFolder') { $hostFolder = $field.InnerText }
                if ($field.Name -eq 'SandboxFolder') { $sandboxFolder = $field.InnerText }
                if ($field.Name -eq 'ReadOnly') { $readOnly = $field.InnerText }
            }
            if (-not $hostFolder) {
                $errors.Add('A <MappedFolder> is missing its <HostFolder>.')
            } elseif (-not $SkipHostFolderCheck -and -not (Test-Path -LiteralPath $hostFolder -PathType Container)) {
                $errors.Add("Mapped host folder does not exist: $hostFolder. Windows Sandbox fails to start when a mapped host folder is missing.")
            }
            if ($sandboxFolder -and $sandboxFolder -notmatch '^[A-Za-z]:\\' -and $sandboxFolder -notmatch '^\\\\') {
                $errors.Add("SandboxFolder must be an absolute Windows path. Got: $sandboxFolder")
            }
            if ($null -ne $readOnly -and $readOnly -notin @('true', 'false')) {
                $errors.Add("ReadOnly must be 'true' or 'false'. Got: '$readOnly'")
            }
            if ($null -ne $readOnly -and $readOnly -eq 'false') {
                $warnings.Add("Writable mapped folder $hostFolder keeps its changes after the sandbox closes.")
            }
        }
    }
    if ($child.Name -eq 'LogonCommand') {
        $command = $child.SelectSingleNode('Command')
        if ($null -eq $command -or -not $command.InnerText) {
            $errors.Add('<LogonCommand> must contain a non-empty <Command>.')
        }
    }
}

foreach ($warning in $warnings) {
    Write-Warning $warning
}

if ($errors.Count -gt 0) {
    foreach ($errorMessage in $errors) {
        Write-Error $errorMessage
    }
    exit 1
}

Write-Output "OK: $Path"
