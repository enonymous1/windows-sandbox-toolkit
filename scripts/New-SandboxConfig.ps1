<#
.SYNOPSIS
    Generates a Windows Sandbox (.wsb) configuration file from a profile.

.DESCRIPTION
    Builds a .wsb file from a profile in schema/wsb-schema.json
    (Untrusted, DevTest, InstallerTest) and applies any per-option
    overrides you pass. Profile values, allowed values, and the memory
    floor all come from that schema file; they are not copied into
    this script, so a schema change cannot leave the generator
    disagreeing with the validator.

    The mapped host folder, when given, must already exist on the
    host: Windows Sandbox fails to start if it does not. A writable
    mapped folder keeps its changes after the sandbox closes;
    everything else inside the sandbox is discarded on close.

    This script only writes the .wsb file. It does not require
    Windows Sandbox to be enabled until you actually launch the file
    (see Enable-WindowsSandbox.ps1). After writing, it runs the
    sibling Test-SandboxConfig.ps1 against its own output unless
    -SkipValidation is given, so a generator bug surfaces here
    instead of on the machine that launches the file.

.PARAMETER Profile
    The base profile. Untrusted is the locked-down default for software
    you do not trust. DevTest is for your own builds. InstallerTest is
    for installers that need the network but should not reach your
    clipboard or host folders.

.PARAMETER HostFolder
    A folder on the host to map into the sandbox, for example
    'C:\Users\Public\Downloads\untrusted'. Must already exist, unless
    it uses an environment variable that is not set on this machine,
    in which case the existence check is skipped with a warning:
    Windows Sandbox supports env-var paths on Windows 11 23H2+.

.PARAMETER SandboxFolder
    Where the host folder appears inside the sandbox. Defaults to
    'C:\Users\WDAGUtilityAccount\Desktop\<folder name>'.

.PARAMETER ReadOnly
    Map the folder read-only. This is the default for Untrusted and
    the recommended default everywhere: an untrusted program must not
    be able to write back to your host.

.PARAMETER AllowWrite
    Map the folder writable. Cannot be combined with -ReadOnly.
    A writable mapping always produces a warning, even when you
    asked for it explicitly, because the warning is the record that
    changes to that folder will persist after the sandbox closes.

.PARAMETER Networking
    Enable, Disable, or Default. Overrides the profile value.

.PARAMETER VGpu
    Enable, Disable, or Default. Overrides the profile value.

.PARAMETER AudioInput
    Enable, Disable, or Default. Overrides the profile value.

.PARAMETER VideoInput
    Enable, Disable, or Default. Overrides the profile value.

.PARAMETER ProtectedClient
    Enable, Disable, or Default. Overrides the profile value.

.PARAMETER PrinterRedirection
    Enable, Disable, or Default. Overrides the profile value.

.PARAMETER ClipboardRedirection
    Enable, Disable, or Default. Overrides the profile value.

.PARAMETER MemoryInMB
    Memory for the sandbox, in megabytes. Values below the schema
    minimum (2048) are raised to that minimum, matching Windows
    Sandbox behaviour.

.PARAMETER LogonCommand
    A single command run inside the sandbox after logon. It must be a
    path to an executable or script that exists inside the sandbox.
    For anything more than one simple command, map a script file into
    the sandbox with -HostFolder and point the logon command at it.
    The command is written via XmlDocument InnerText, never by
    string templating, so characters like <, >, and & in the command
    cannot break out of the XML element.

.PARAMETER OutputPath
    Where to write the .wsb file. Defaults to '.\sandbox.wsb' in the
    current directory.

.PARAMETER Launch
    Launch the generated .wsb file after writing it (Windows only).
    This is validated up front: on a non-Windows machine it fails
    before any file is written, so a failed launch never looks like
    a successful generation to automation.

.PARAMETER SkipValidation
    Skip the self-validation step after writing. Only for
    troubleshooting the generator itself; do not use it routinely.

.EXAMPLE
    .\scripts\New-SandboxConfig.ps1 -Profile Untrusted `
        -HostFolder 'C:\Users\Public\Downloads\untrusted' `
        -OutputPath '.\untrusted-test.wsb' -Launch

.EXAMPLE
    .\scripts\New-SandboxConfig.ps1 -Profile DevTest -MemoryInMB 8192 `
        -OutputPath '.\dev-test.wsb'

.NOTES
    Requires PowerShell 5.1+ or PowerShell 7+. This script is part of
    the repository: it imports scripts/SandboxSchema.psm1 and reads
    schema/wsb-schema.json. Do not copy it out on its own.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('Untrusted', 'DevTest', 'InstallerTest')]
    [string]$Profile = 'Untrusted',

    [Parameter(Mandatory = $false)]
    [string]$HostFolder,

    [Parameter(Mandatory = $false)]
    [string]$SandboxFolder,

    [Parameter(Mandatory = $false)]
    [switch]$ReadOnly,

    [Parameter(Mandatory = $false)]
    [switch]$AllowWrite,

    [Parameter(Mandatory = $false)]
    [ValidateSet('Enable', 'Disable', 'Default')]
    [string]$Networking,

    [Parameter(Mandatory = $false)]
    [ValidateSet('Enable', 'Disable', 'Default')]
    [string]$VGpu,

    [Parameter(Mandatory = $false)]
    [ValidateSet('Enable', 'Disable', 'Default')]
    [string]$AudioInput,

    [Parameter(Mandatory = $false)]
    [ValidateSet('Enable', 'Disable', 'Default')]
    [string]$VideoInput,

    [Parameter(Mandatory = $false)]
    [ValidateSet('Enable', 'Disable', 'Default')]
    [string]$ProtectedClient,

    [Parameter(Mandatory = $false)]
    [ValidateSet('Enable', 'Disable', 'Default')]
    [string]$PrinterRedirection,

    [Parameter(Mandatory = $false)]
    [ValidateSet('Enable', 'Disable', 'Default')]
    [string]$ClipboardRedirection,

    [Parameter(Mandatory = $false)]
    [int]$MemoryInMB,

    [Parameter(Mandatory = $false)]
    [string]$LogonCommand,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = (Join-Path -Path (Get-Location) -ChildPath 'sandbox.wsb'),

    [Parameter(Mandatory = $false)]
    [switch]$Launch,

    [Parameter(Mandatory = $false)]
    [switch]$SkipValidation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module -Name (Join-Path -Path $PSScriptRoot -ChildPath 'SandboxSchema.psm1') -ErrorAction Stop
$schema = Get-SandboxSchema

# Fail fast, before any side effect: a -Launch that cannot work must
# not leave a file behind that automation then treats as success.
if ($Launch -and -not $IsWindows) {
    throw 'Launching a .wsb file requires Windows. No file was written.'
}

if ($ReadOnly -and $AllowWrite) {
    throw 'Use -ReadOnly or -AllowWrite, not both.'
}

# Format before existence: a relative path that happens to exist on
# this machine must not pass the existence check and then fail the
# format check with a confusing message, and an env-var path must be
# expanded before it is checked at all.
if ($HostFolder -and -not (Test-WindowsAbsolutePath -Path $HostFolder)) {
    throw "HostFolder must be an absolute Windows path, for example 'C:\Users\Public\Downloads\untrusted'. Got: $HostFolder"
}
if ($SandboxFolder -and -not (Test-WindowsAbsolutePath -Path $SandboxFolder)) {
    throw "SandboxFolder must be an absolute Windows path. Got: $SandboxFolder"
}

if ($HostFolder) {
    $check = Expand-SandboxPath -Path $HostFolder
    if ($check.HasUnexpanded) {
        Write-Warning "HostFolder uses an environment variable that is not set on this machine ($HostFolder); the existence check was skipped. Windows Sandbox supports env-var paths on Windows 11 23H2 and later."
    } elseif (-not (Test-Path -LiteralPath $check.Expanded -PathType Container)) {
        throw "HostFolder does not exist: $HostFolder. Create it first -- Windows Sandbox fails to start when a mapped host folder is missing."
    }
}

# Profile defaults come from the schema, converted to a hashtable so
# lookup is by name and case is not load-bearing.
$defaults = @{}
foreach ($property in $schema.profiles.$Profile.PSObject.Properties) {
    $defaults[$property.Name] = $property.Value
}

function Resolve-Option {
    <#
    .SYNOPSIS
        A profile value, unless the caller bound an override.
    .DESCRIPTION
        $PSBoundParameters inside a function is the function's own
        bound parameters, not the script's, so the caller must pass
        both whether the script parameter was bound and the profile
        defaults explicitly. (An earlier version read the function's
        $PSBoundParameters and silently ignored every override; a
        test now pins override behaviour.)
    #>
    param(
        [string]$Name,
        [string]$Override,
        [bool]$Bound,
        [hashtable]$Defaults
    )
    if ($Bound) { return $Override }
    return $Defaults[$Name]
}

$resolvedVGpu = Resolve-Option -Name 'vGPU' -Override $VGpu -Bound $PSBoundParameters.ContainsKey('VGpu') -Defaults $defaults
$resolvedNetworking = Resolve-Option -Name 'Networking' -Override $Networking -Bound $PSBoundParameters.ContainsKey('Networking') -Defaults $defaults
$resolvedAudio = Resolve-Option -Name 'AudioInput' -Override $AudioInput -Bound $PSBoundParameters.ContainsKey('AudioInput') -Defaults $defaults
$resolvedVideo = Resolve-Option -Name 'VideoInput' -Override $VideoInput -Bound $PSBoundParameters.ContainsKey('VideoInput') -Defaults $defaults
$resolvedProtected = Resolve-Option -Name 'ProtectedClient' -Override $ProtectedClient -Bound $PSBoundParameters.ContainsKey('ProtectedClient') -Defaults $defaults
$resolvedPrinter = Resolve-Option -Name 'PrinterRedirection' -Override $PrinterRedirection -Bound $PSBoundParameters.ContainsKey('PrinterRedirection') -Defaults $defaults
$resolvedClipboard = Resolve-Option -Name 'ClipboardRedirection' -Override $ClipboardRedirection -Bound $PSBoundParameters.ContainsKey('ClipboardRedirection') -Defaults $defaults

if ($PSBoundParameters.ContainsKey('MemoryInMB')) {
    $resolvedMemory = $MemoryInMB
} else {
    $resolvedMemory = $defaults['MemoryInMB']
}
if ($resolvedMemory -lt $schema.minMemoryInMB) {
    Write-Warning "MemoryInMB $resolvedMemory is below the $($schema.minMemoryInMB) MB minimum and was raised to $($schema.minMemoryInMB)."
    $resolvedMemory = $schema.minMemoryInMB
}

if ($HostFolder -and -not $SandboxFolder) {
    $leaf = Get-SandboxFolderLeaf -HostFolder $HostFolder
    $SandboxFolder = "$($schema.sandboxDesktop)\$leaf"
}

$readOnlyValue = $false
if ($HostFolder) {
    if ($ReadOnly) {
        $readOnlyValue = $true
    } elseif ($AllowWrite) {
        $readOnlyValue = $false
    } else {
        # Default: read-only for Untrusted, writable otherwise, so a
        # dev-test mapping is actually useful and an untrusted one
        # cannot write back to the host by accident.
        $readOnlyValue = ($Profile -eq 'Untrusted')
    }
}

if ($OutputPath -notlike '*.wsb') {
    throw "OutputPath must end in .wsb. Got: $OutputPath"
}

if (-not $PSCmdlet.ShouldProcess($OutputPath, 'Write .wsb file')) {
    return
}

$xml = New-Object -TypeName System.Xml.XmlDocument
$declaration = $xml.CreateXmlDeclaration('1.0', 'UTF-8', $null)
[void]$xml.AppendChild($declaration)
$root = $xml.CreateElement('Configuration')
[void]$xml.AppendChild($root)

function Add-Element {
    <#
    .SYNOPSIS
        Appends a text element to a parent element.
    .DESCRIPTION
        Deliberately returns nothing: an earlier version returned the
        created element, so every caller had to remember '$null ='
        or the elements leaked into the script's output pipeline.
        InnerText (not string templating) is what makes values with
        <, >, or & safe to write.
    #>
    param(
        [System.Xml.XmlElement]$Parent,
        [string]$Name,
        [string]$Value
    )
    $element = $xml.CreateElement($Name)
    $element.InnerText = $Value
    [void]$Parent.AppendChild($element)
}

Add-Element -Parent $root -Name 'vGPU' -Value $resolvedVGpu
Add-Element -Parent $root -Name 'Networking' -Value $resolvedNetworking

if ($HostFolder) {
    $mappedFolders = $xml.CreateElement('MappedFolders')
    [void]$root.AppendChild($mappedFolders)
    $mappedFolder = $xml.CreateElement('MappedFolder')
    [void]$mappedFolders.AppendChild($mappedFolder)
    Add-Element -Parent $mappedFolder -Name 'HostFolder' -Value $HostFolder
    Add-Element -Parent $mappedFolder -Name 'SandboxFolder' -Value $SandboxFolder
    $readOnlyText = if ($readOnlyValue) { 'true' } else { 'false' }
    Add-Element -Parent $mappedFolder -Name 'ReadOnly' -Value $readOnlyText
}

if ($LogonCommand) {
    $logon = $xml.CreateElement('LogonCommand')
    [void]$root.AppendChild($logon)
    Add-Element -Parent $logon -Name 'Command' -Value $LogonCommand
}

Add-Element -Parent $root -Name 'AudioInput' -Value $resolvedAudio
Add-Element -Parent $root -Name 'VideoInput' -Value $resolvedVideo
Add-Element -Parent $root -Name 'ProtectedClient' -Value $resolvedProtected
Add-Element -Parent $root -Name 'PrinterRedirection' -Value $resolvedPrinter
Add-Element -Parent $root -Name 'ClipboardRedirection' -Value $resolvedClipboard
Add-Element -Parent $root -Name 'MemoryInMB' -Value $resolvedMemory.ToString()

$outputDirectory = Split-Path -Path $OutputPath -Parent
if ($outputDirectory -and -not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    [void](New-Item -Path $outputDirectory -ItemType Directory -Force)
}

$settings = New-Object -TypeName System.Xml.XmlWriterSettings
$settings.Indent = $true
$settings.Encoding = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
$writer = $null
try {
    $writer = [System.Xml.XmlWriter]::Create($OutputPath, $settings)
    $xml.Save($writer)
} catch {
    throw "Failed to write ${OutputPath}: $($_.Exception.Message)"
} finally {
    # Guarded: if Create itself failed, $writer is $null, and an
    # unguarded Close() would mask the real error with a null
    # reference error.
    if ($writer) { $writer.Close() }
}

Write-Output "Wrote $OutputPath (profile: $Profile, networking: $resolvedNetworking, clipboard: $resolvedClipboard)"
if ($HostFolder) {
    if ($readOnlyValue) {
        Write-Output "Mapped $HostFolder -> $SandboxFolder (read-only)"
    } else {
        Write-Warning "Mapped $HostFolder -> $SandboxFolder (WRITABLE -- changes persist on the host)"
    }
}

if (-not $SkipValidation) {
    $validator = Join-Path -Path $PSScriptRoot -ChildPath 'Test-SandboxConfig.ps1'
    if (Test-Path -LiteralPath $validator -PathType Leaf) {
        # The validator MUST run as a subprocess, not in-process.
        # Two PowerShell traps made the in-process call wrong in
        # both directions (CI failure, 2026-10-31):
        #  - A PowerShell script never sets $LASTEXITCODE, so
        #    checking it after an in-process call reads whatever
        #    the previous native command left behind. In CI the
        #    XXE validator case (correctly exiting 1) ran just
        #    before the Windows mapping case, so a perfectly
        #    valid mapped.wsb was reported as failed.
        #  - On a real failure the validator calls exit 1, which
        #    terminates the whole process when run in-process,
        #    so the throw below was unreachable for real failures.
        # A native subprocess sets $LASTEXITCODE for real, and
        # its exit does not kill this process, so both cases
        # are now reported correctly. 2>&1 is merged so a real
        # failure's error lines are printed, not swallowed.
        $engine = $null
        # Do not read .Source straight off Get-Command: under
        # Set-StrictMode that throws when the command is not
        # found (pwsh is not on PATH on every machine that runs
        # this script, including the Linux box that built it).
        foreach ($engineName in @('pwsh', 'powershell')) {
            $command = Get-Command -Name $engineName -ErrorAction SilentlyContinue
            if ($command -and $command.Source -and (Test-Path -LiteralPath $command.Source -PathType Leaf)) { $engine = $command.Source; break }
        }
        if (-not $engine) {
            foreach ($name in @('pwsh', 'pwsh.exe', 'powershell.exe')) {
                $candidate = Join-Path -Path $PSHOME -ChildPath $name
                if (Test-Path -LiteralPath $candidate -PathType Leaf) { $engine = $candidate; break }
            }
        }
        if (-not $engine) {
            Write-Warning "No PowerShell engine found on PATH or in `$PSHOME; the generated file was not self-validated."
        } else {
            $validationOutput = & $engine -NoProfile -File $validator -Path $OutputPath 2>&1
            if ($LASTEXITCODE -ne 0) {
                $validationOutput | ForEach-Object { Write-Output $_ }
                throw "Generated file failed validation: $OutputPath. See the validator output above."
            }
        }
    } else {
        Write-Warning "Validator not found next to the generator ($validator); the generated file was not self-validated."
    }
}

if ($Launch) {
    if ($PSCmdlet.ShouldProcess($OutputPath, 'Launch in Windows Sandbox')) {
        Start-Process -FilePath $OutputPath
    }
}
