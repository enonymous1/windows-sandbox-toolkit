<#
.SYNOPSIS
    Validates a Windows Sandbox (.wsb) configuration file.

.DESCRIPTION
    Checks a .wsb file against schema/wsb-schema.json: only known
    elements, only allowed values, no duplicated top-level elements,
    a numeric MemoryInMB, and mapped folders whose host folder
    actually exists. A missing host folder is an error by default,
    because Windows Sandbox fails to start in that case -- pass
    -SkipHostFolderCheck only when you are validating a template
    that will be generated for another machine.

    The file is parsed with DTD processing prohibited and no XML
    resolver. That matters because a .wsb file is exactly the kind
    of file an untrusted source hands you: with the default
    XmlDocument settings, a crafted DOCTYPE could make the parser
    resolve an external entity (XXE) while you are only trying to
    check the file's shape.

    Exits 0 when the file is valid, 1 when it is not. Warnings (for
    example MemoryInMB below the schema minimum, which Windows
    Sandbox raises automatically) do not fail the check. This is a
    command-line script, not a module: exit is intentional here, so
    CI and callers can rely on the exit code. Do not dot-source it
    into an interactive session and expect to keep that session.

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

.NOTES
    Requires PowerShell 5.1+ or PowerShell 7+. This script is part of
    the repository: it imports scripts/SandboxSchema.psm1 and reads
    schema/wsb-schema.json. Do not copy it out on its own.
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

Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'SandboxSchema.psm1') -ErrorAction Stop
$schema = Get-SandboxSchema

if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "File not found: $Path"
}
if ($Path -notlike '*.wsb') {
    throw "Expected a .wsb file. Got: $Path"
}

# Allowed values come from the schema, not from a second copy here.
$allowedValues = @{}
foreach ($property in $schema.optionValues.PSObject.Properties) {
    $allowedValues[$property.Name] = @($property.Value)
}
# Top-level elements are the schema's element order, plus the inner
# elements that only appear inside MappedFolders / LogonCommand.
$allowedElements = @($schema.elementOrder) + @('MappedFolder', 'HostFolder', 'SandboxFolder', 'ReadOnly', 'Command') | Select-Object -Unique

$errors = New-Object -TypeName System.Collections.Generic.List[string]
$warnings = New-Object -TypeName System.Collections.Generic.List[string]

$xml = New-Object -TypeName System.Xml.XmlDocument
$reader = $null
try {
    $readerSettings = New-Object -TypeName System.Xml.XmlReaderSettings
    $readerSettings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $readerSettings.XmlResolver = $null
    $reader = [System.Xml.XmlReader]::Create($Path, $readerSettings)
    $xml.Load($reader)
} catch {
    Write-Error "Invalid XML in ${Path}: $($_.Exception.Message)"
    exit 1
} finally {
    if ($reader) { $reader.Close() }
}

$root = $xml.DocumentElement
if ($null -eq $root -or $root.Name -ne 'Configuration') {
    Write-Error 'Root element must be <Configuration>.'
    exit 1
}

$seenTopLevel = New-Object -TypeName System.Collections.Generic.HashSet[string]
foreach ($child in $root.ChildNodes) {
    if ($child.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
    if (-not $seenTopLevel.Add($child.Name)) {
        $errors.Add("Duplicated element: <$($child.Name)>. Windows Sandbox behaviour for a repeated option is undefined, so duplicates are rejected rather than silently keeping one.")
        continue
    }
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
        } elseif ($memory -le 0) {
            $errors.Add("MemoryInMB must be positive. Got: '$($child.InnerText)'")
        } elseif ($memory -lt $schema.minMemoryInMB) {
            $warnings.Add("MemoryInMB $memory is below $($schema.minMemoryInMB); Windows Sandbox raises it to $($schema.minMemoryInMB) automatically.")
        }
    }
    if ($child.Name -eq 'MappedFolders') {
        $folderCount = 0
        foreach ($folder in $child.ChildNodes) {
            if ($folder.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
            if ($folder.Name -ne 'MappedFolder') {
                $errors.Add("Unknown element inside <MappedFolders>: <$($folder.Name)>")
                continue
            }
            $folderCount++
            $hostFolder = $null
            $sandboxFolder = $null
            $readOnly = $null
            $seenFields = New-Object -TypeName System.Collections.Generic.HashSet[string]
            foreach ($field in $folder.ChildNodes) {
                if ($field.NodeType -ne [System.Xml.XmlNodeType]::Element) { continue }
                if (-not $seenFields.Add($field.Name)) {
                    $errors.Add("Duplicated element inside <MappedFolder>: <$($field.Name)>")
                    continue
                }
                if ($allowedElements -notcontains $field.Name) {
                    $errors.Add("Unknown element inside <MappedFolder>: <$($field.Name)>")
                }
                if ($field.Name -eq 'HostFolder') { $hostFolder = $field.InnerText }
                if ($field.Name -eq 'SandboxFolder') { $sandboxFolder = $field.InnerText }
                if ($field.Name -eq 'ReadOnly') { $readOnly = $field.InnerText }
            }
            if (-not $hostFolder) {
                $errors.Add('A <MappedFolder> is missing its <HostFolder>.')
            } else {
                # Relative host paths are not supported by Windows
                # Sandbox (env-var paths are the documented exception
                # on Windows 11 23H2+), so a relative path is an
                # error here, not just a missing-folder error.
                if (-not (Test-WindowsAbsolutePath -Path $hostFolder)) {
                    $errors.Add("HostFolder must be an absolute Windows path (or an env-var path). Got: $hostFolder")
                } elseif (-not $SkipHostFolderCheck) {
                    $check = Expand-SandboxPath -Path $hostFolder
                    if (-not $check.HasUnexpanded -and -not (Test-Path -LiteralPath $check.Expanded -PathType Container)) {
                        $errors.Add("Mapped host folder does not exist: $hostFolder. Windows Sandbox fails to start when a mapped host folder is missing.")
                    }
                }
            }
            if ($sandboxFolder -and -not (Test-WindowsAbsolutePath -Path $sandboxFolder)) {
                $errors.Add("SandboxFolder must be an absolute Windows path (or an env-var path). Got: $sandboxFolder")
            }
            if ($null -ne $readOnly -and $readOnly -notin @('true', 'false')) {
                $errors.Add("ReadOnly must be 'true' or 'false'. Got: '$readOnly'")
            }
            if ($null -ne $readOnly -and $readOnly -eq 'false') {
                $warnings.Add("Writable mapped folder $hostFolder keeps its changes after the sandbox closes.")
            }
        }
        if ($folderCount -eq 0) {
            $errors.Add('<MappedFolders> must contain at least one <MappedFolder>. An empty mapping block is almost always a mistake, not an intention.')
        }
    }
    if ($child.Name -eq 'LogonCommand') {
        $commands = @($child.SelectNodes('Command'))
        if ($commands.Count -eq 0 -or -not $commands[0].InnerText) {
            $errors.Add('<LogonCommand> must contain a non-empty <Command>.')
        } elseif ($commands.Count -gt 1) {
            $errors.Add('<LogonCommand> must contain exactly one <Command>; Windows Sandbox runs a single logon command.')
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
