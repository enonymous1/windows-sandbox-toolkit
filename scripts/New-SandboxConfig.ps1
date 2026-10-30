<#
.SYNOPSIS
    Generates a Windows Sandbox (.wsb) configuration file from a profile.

.DESCRIPTION
    Builds a .wsb file from one of the profiles in configs/ (Untrusted,
    DevTest, InstallerTest) and applies any per-option overrides you pass.
    The mapped host folder, when given, must already exist on the host:
    Windows Sandbox fails to start if it does not. A writable mapped
    folder keeps its changes after the sandbox closes; everything else
    inside the sandbox is discarded on close.

    This script only writes the .wsb file. It does not require Windows
    Sandbox to be enabled until you actually launch the file (see
    Enable-WindowsSandbox.ps1).

.PARAMETER Profile
    The base profile. Untrusted is the locked-down default for software
    you do not trust. DevTest is for your own builds. InstallerTest is
    for installers that need the network but should not reach your
    clipboard or host folders.

.PARAMETER HostFolder
    A folder on the host to map into the sandbox, for example
    'C:\Users\Public\Downloads\untrusted'. Must already exist.

.PARAMETER SandboxFolder
    Where the host folder appears inside the sandbox. Defaults to
    'C:\Users\WDAGUtilityAccount\Desktop\<folder name>'.

.PARAMETER ReadOnly
    Map the folder read-only. This is the default for Untrusted and
    the recommended default everywhere: an untrusted program must not
    be able to write back to your host.

.PARAMETER AllowWrite
    Map the folder writable. Cannot be combined with -ReadOnly.

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
    Memory for the sandbox, in megabytes. Values below 2048 are raised
    to 2048, matching Windows Sandbox behaviour.

.PARAMETER LogonCommand
    A single command run inside the sandbox after logon. It must be a
    path to an executable or script that exists inside the sandbox.
    For anything more than one simple command, map a script file into
    the sandbox with -HostFolder and point the logon command at it.

.PARAMETER OutputPath
    Where to write the .wsb file. Defaults to '.\sandbox.wsb' in the
    current directory.

.PARAMETER Launch
    Launch the generated .wsb file after writing it (Windows only).

.EXAMPLE
    .\scripts\New-SandboxConfig.ps1 -Profile Untrusted `
        -HostFolder 'C:\Users\Public\Downloads\untrusted' `
        -OutputPath '.\untrusted-test.wsb' -Launch

.EXAMPLE
    .\scripts\New-SandboxConfig.ps1 -Profile DevTest -MemoryInMB 8192 `
        -OutputPath '.\dev-test.wsb'
#>
[CmdletBinding()]
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
    [switch]$Launch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($ReadOnly -and $AllowWrite) {
    throw 'Use -ReadOnly or -AllowWrite, not both.'
}

if ($HostFolder -and -not (Test-Path -LiteralPath $HostFolder -PathType Container)) {
    throw "HostFolder does not exist: $HostFolder. Create it first -- Windows Sandbox fails to start when a mapped host folder is missing."
}

if ($HostFolder -and $HostFolder -notmatch '^[A-Za-z]:\\' -and $HostFolder -notmatch '^\\\\') {
    throw "HostFolder must be an absolute Windows path, for example 'C:\Users\Public\Downloads\untrusted'. Got: $HostFolder"
}

if ($SandboxFolder -and $SandboxFolder -notmatch '^[A-Za-z]:\\' -and $SandboxFolder -notmatch '^\\\\') {
    throw "SandboxFolder must be an absolute Windows path. Got: $SandboxFolder"
}

# Profile defaults. Any bound override below wins over these.
$profiles = @{
    Untrusted     = @{
        VGpu = 'Disable'; Networking = 'Disable'; AudioInput = 'Disable'
        VideoInput = 'Disable'; ProtectedClient = 'Enable'
        PrinterRedirection = 'Disable'; ClipboardRedirection = 'Disable'
        MemoryInMB = 4096
    }
    DevTest       = @{
        VGpu = 'Enable'; Networking = 'Enable'; AudioInput = 'Disable'
        VideoInput = 'Disable'; ProtectedClient = 'Disable'
        PrinterRedirection = 'Disable'; ClipboardRedirection = 'Enable'
        MemoryInMB = 4096
    }
    InstallerTest = @{
        VGpu = 'Enable'; Networking = 'Enable'; AudioInput = 'Disable'
        VideoInput = 'Disable'; ProtectedClient = 'Disable'
        PrinterRedirection = 'Disable'; ClipboardRedirection = 'Disable'
        MemoryInMB = 4096
    }
}
$defaults = $profiles[$Profile]

# NOTE: $PSBoundParameters inside a function is the function's own
# bound parameters, not the script's, so the caller must pass whether
# the script parameter was bound. (Caught by a test: overrides were
# silently ignored before this fix.)
function Resolve-Option {
    param([string]$Name, [string]$Override, [bool]$Bound)
    if ($Bound) { return $Override }
    return $defaults[$Name]
}

$resolvedVGpu = Resolve-Option -Name 'VGpu' -Override $VGpu -Bound $PSBoundParameters.ContainsKey('VGpu')
$resolvedNetworking = Resolve-Option -Name 'Networking' -Override $Networking -Bound $PSBoundParameters.ContainsKey('Networking')
$resolvedAudio = Resolve-Option -Name 'AudioInput' -Override $AudioInput -Bound $PSBoundParameters.ContainsKey('AudioInput')
$resolvedVideo = Resolve-Option -Name 'VideoInput' -Override $VideoInput -Bound $PSBoundParameters.ContainsKey('VideoInput')
$resolvedProtected = Resolve-Option -Name 'ProtectedClient' -Override $ProtectedClient -Bound $PSBoundParameters.ContainsKey('ProtectedClient')
$resolvedPrinter = Resolve-Option -Name 'PrinterRedirection' -Override $PrinterRedirection -Bound $PSBoundParameters.ContainsKey('PrinterRedirection')
$resolvedClipboard = Resolve-Option -Name 'ClipboardRedirection' -Override $ClipboardRedirection -Bound $PSBoundParameters.ContainsKey('ClipboardRedirection')

if ($PSBoundParameters.ContainsKey('MemoryInMB')) {
    $resolvedMemory = $MemoryInMB
} else {
    $resolvedMemory = $defaults['MemoryInMB']
}
if ($resolvedMemory -lt 2048) {
    Write-Warning "MemoryInMB $resolvedMemory is below the 2048 MB minimum and was raised to 2048."
    $resolvedMemory = 2048
}

if ($HostFolder -and -not $SandboxFolder) {
    $leaf = Split-Path -Path $HostFolder -Leaf
    if (-not $leaf) { $leaf = 'shared' }
    $SandboxFolder = "C:\Users\WDAGUtilityAccount\Desktop\$leaf"
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

$xml = New-Object -TypeName System.Xml.XmlDocument
$declaration = $xml.CreateXmlDeclaration('1.0', 'UTF-8', $null)
[void]$xml.AppendChild($declaration)
$root = $xml.CreateElement('Configuration')
[void]$xml.AppendChild($root)

function Add-Element {
    param(
        [System.Xml.XmlElement]$Parent,
        [string]$Name,
        [string]$Value
    )
    $element = $xml.CreateElement($Name)
    $element.InnerText = $Value
    [void]$Parent.AppendChild($element)
    return $element
}

$null = Add-Element -Parent $root -Name 'vGPU' -Value $resolvedVGpu
$null = Add-Element -Parent $root -Name 'Networking' -Value $resolvedNetworking

if ($HostFolder) {
    $mappedFolders = $xml.CreateElement('MappedFolders')
    [void]$root.AppendChild($mappedFolders)
    $mappedFolder = $xml.CreateElement('MappedFolder')
    [void]$mappedFolders.AppendChild($mappedFolder)
    $null = Add-Element -Parent $mappedFolder -Name 'HostFolder' -Value $HostFolder
    $null = Add-Element -Parent $mappedFolder -Name 'SandboxFolder' -Value $SandboxFolder
    $readOnlyText = if ($readOnlyValue) { 'true' } else { 'false' }
    $null = Add-Element -Parent $mappedFolder -Name 'ReadOnly' -Value $readOnlyText
}

if ($LogonCommand) {
    $logon = $xml.CreateElement('LogonCommand')
    [void]$root.AppendChild($logon)
    $null = Add-Element -Parent $logon -Name 'Command' -Value $LogonCommand
}

$null = Add-Element -Parent $root -Name 'AudioInput' -Value $resolvedAudio
$null = Add-Element -Parent $root -Name 'VideoInput' -Value $resolvedVideo
$null = Add-Element -Parent $root -Name 'ProtectedClient' -Value $resolvedProtected
$null = Add-Element -Parent $root -Name 'PrinterRedirection' -Value $resolvedPrinter
$null = Add-Element -Parent $root -Name 'ClipboardRedirection' -Value $resolvedClipboard
$null = Add-Element -Parent $root -Name 'MemoryInMB' -Value $resolvedMemory.ToString()

if ($OutputPath -notlike '*.wsb') {
    throw "OutputPath must end in .wsb. Got: $OutputPath"
}
$outputDirectory = Split-Path -Path $OutputPath -Parent
if ($outputDirectory -and -not (Test-Path -LiteralPath $outputDirectory -PathType Container)) {
    [void](New-Item -Path $outputDirectory -ItemType Directory -Force)
}

$settings = New-Object -TypeName System.Xml.XmlWriterSettings
$settings.Indent = $true
$settings.Encoding = New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
$writer = [System.Xml.XmlWriter]::Create($OutputPath, $settings)
try {
    $xml.Save($writer)
} finally {
    $writer.Close()
}

Write-Output "Wrote $OutputPath (profile: $Profile, networking: $resolvedNetworking, clipboard: $resolvedClipboard)"
if ($HostFolder) {
    $mode = if ($readOnlyValue) { 'read-only' } else { 'WRITABLE -- changes persist on the host' }
    Write-Output "Mapped $HostFolder -> $SandboxFolder ($mode)"
}

if ($Launch) {
    if (-not $IsWindows) {
        throw 'Launching a .wsb file requires Windows. The file was still written.'
    }
    Start-Process -FilePath $OutputPath
}
