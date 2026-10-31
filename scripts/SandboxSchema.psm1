<#
.SYNOPSIS
    Shared schema and path helpers for the Sandbox scripts.

.DESCRIPTION
    This module exists so the .wsb schema is defined exactly once, in
    schema/wsb-schema.json, instead of being copied into the generator,
    the validator, and the Python tests independently. When Microsoft
    changes the format, the schema file changes and the tests check
    that the shipped profiles still match it.

    The scripts in this folder are a package, not standalone files:
    they import this module, and the module loads the schema file
    relative to its own location. Do not copy a single script out of
    the repository and expect it to work on its own.

.NOTES
    Exported functions:
      Get-SandboxSchema          Load and validate the schema file.
      Test-WindowsAbsolutePath   Absolute Windows path or env-var path?
      Get-SandboxFolderLeaf      Last path segment, on either separator.
      Expand-SandboxPath         Expand %VAR% segments, if possible.
#>

<#
.SYNOPSIS
    Loads schema/wsb-schema.json.
.DESCRIPTION
    Resolves the schema relative to this module, not to the current
    directory, so the scripts work no matter where they are invoked
    from. Throws a clear error if the schema is missing or malformed
    instead of letting a later step fail with a null reference.
.OUTPUTS
    PSCustomObject parsed from the schema JSON.
#>
function Get-SandboxSchema {
    [OutputType([pscustomobject])]
    [CmdletBinding()]
    param(
        [string]$SchemaPath = (Join-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -ChildPath 'schema/wsb-schema.json')
    )
    if (-not (Test-Path -LiteralPath $SchemaPath -PathType Leaf)) {
        throw "Sandbox schema not found: $SchemaPath. The scripts in scripts/ are part of this repository; do not copy a single script out on its own."
    }
    try {
        $schema = Get-Content -LiteralPath $SchemaPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "Sandbox schema is not valid JSON: $SchemaPath. $($_.Exception.Message)"
    }
    foreach ($key in @('minMemoryInMB', 'optionValues', 'profiles', 'elementOrder')) {
        if ($null -eq $schema.$key) {
            throw "Sandbox schema is missing required key '$key': $SchemaPath"
        }
    }
    return $schema
}

<#
.SYNOPSIS
    True if a path is an absolute Windows path, or an env-var path.
.DESCRIPTION
    Accepts drive paths (C:\...), UNC paths (\\server\share), and
    environment-variable paths (%USERPROFILE%\...), which Windows
    Sandbox supports in mapped-folder paths on Windows 11 23H2 and
    later. It does not check that the path exists; that is a
    separate step, because an env-var path can only be checked
    after expansion, and expansion needs the variable to be set
    on the machine doing the check.
#>
function Test-WindowsAbsolutePath {
    [OutputType([bool])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Path
    )
    if (-not $Path) { return $false }
    return ($Path -match '^[A-Za-z]:\\') -or ($Path -match '^\\\\') -or ($Path -match '^%[^%]+%[\\/]')
}

<#
.SYNOPSIS
    Last segment of a host folder path, on either path separator.
.DESCRIPTION
    Split-Path uses the current OS separator, so on Linux or macOS
    it returns a whole Windows path like C:\Users\Public\Downloads
    as one segment. Splitting on both separators explicitly is
    what makes the generator's default sandbox folder correct
    no matter which OS runs the generator. A trailing separator
    and an empty input both fall back to 'shared'.
#>
function Get-SandboxFolderLeaf {
    [OutputType([string])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$HostFolder
    )
    $segments = $HostFolder -split '[\\/]' | Where-Object { $_ }
    if ($segments.Count -eq 0) { return 'shared' }
    return $segments[$segments.Count - 1]
}

<#
.SYNOPSIS
    Expands %VAR% segments in a path, reporting whether it worked.
.DESCRIPTION
    [Environment]::ExpandEnvironmentVariables leaves an unknown
    variable untouched (%UNKNOWN% stays %UNKNOWN%), so a caller
    cannot tell expansion from a no-op by looking at the result
    alone. This helper returns both the expanded path and a flag
    saying whether any %...% segment survived, so the caller can
    skip an existence check it cannot meaningfully perform
    instead of failing a documented, valid path.
.OUTPUTS
    Hashtable with keys Expanded (string) and HasUnexpanded (bool).
#>
function Expand-SandboxPath {
    [OutputType([hashtable])]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    $expanded = [System.Environment]::ExpandEnvironmentVariables($Path)
    $hasUnexpanded = $expanded -match '%[^%]+%'
    return @{ Expanded = $expanded; HasUnexpanded = $hasUnexpanded }
}

Export-ModuleMember -Function Get-SandboxSchema, Test-WindowsAbsolutePath, Get-SandboxFolderLeaf, Expand-SandboxPath
