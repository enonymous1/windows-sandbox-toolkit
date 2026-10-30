# windows-sandbox-toolkit

Ready-to-use Windows Sandbox configurations, plus a PowerShell
generator and validator so you stop hand-editing XML and hoping
it launches.

Windows Sandbox is a lightweight, temporary, isolated desktop
built into Windows. You run untrusted software in it, close it,
and everything inside is discarded. A `.wsb` file is how you
control that session: networking, GPU sharing, mapped folders,
clipboard, microphone, and a command to run at logon.

## Requirements — read this before anything else

- **Windows 10 Pro or Enterprise**, build 18342 or later for
  `.wsb` files (18305 introduced Sandbox itself), **or Windows 11
  Pro, Enterprise, or Education**.
- **Not Windows Home.** Sandbox is not available on Home, on
  either Windows 10 or 11.
- Virtualization enabled in BIOS/UEFI, and the Windows Sandbox
  feature turned on (see below).
- At least 2 CPU cores (4 with hyperthreading recommended) and
  4 GB RAM (8 GB recommended).

## Quick start

```powershell
# 1. Check your edition, virtualization, and the feature.
#    Run PowerShell as administrator for -Enable.
.\scripts\Enable-WindowsSandbox.ps1
.\scripts\Enable-WindowsSandbox.ps1 -Enable   # if it reports off

# 2. Launch a shipped profile as-is (double-click works too).
.\configs\untrusted.wsb

# 3. Or generate one for a specific folder, read-only, and launch it.
.\scripts\New-SandboxConfig.ps1 -Profile Untrusted `
    -HostFolder 'C:\Users\Public\Downloads\untrusted' `
    -OutputPath '.\untrusted-test.wsb' -Launch
```

## Profiles

| File | For | Networking | Clipboard | GPU | Protected Client |
| --- | --- | --- | --- | --- | --- |
| `configs/untrusted.wsb` | Software you do not trust | Off | Off | Off | On |
| `configs/installer-test.wsb` | Installers that need the network | On | Off | On | Off |
| `configs/dev-test.wsb` | Your own builds | On | On | On | Off |

All three map no folder by default, disable microphone, camera,
and printers, and set 4096 MB of memory. See
[`docs/profiles.md`](docs/profiles.md) for when to use each and
what survives closing the sandbox (spoiler: only a writable
mapped folder does).

## Generator

`scripts/New-SandboxConfig.ps1` builds a `.wsb` from a profile
with your overrides:

```powershell
# Your own build, more memory, writable mapping for test output.
.\scripts\New-SandboxConfig.ps1 -Profile DevTest -MemoryInMB 8192 `
    -HostFolder 'C:\dev\myapp\bin' -AllowWrite `
    -OutputPath '.\dev-test.wsb'

# One logon command: it must exist INSIDE the sandbox. For a
# multi-step setup, map a script in and run that instead.
.\scripts\New-SandboxConfig.ps1 -Profile Untrusted `
    -HostFolder 'C:\Users\Public\Downloads\untrusted' `
    -LogonCommand 'C:\Users\WDAGUtilityAccount\Desktop\untrusted\setup.bat' `
    -OutputPath '.\untrusted-test.wsb'
```

If you pass a host folder that does not exist, the generator
refuses to write the file — Windows Sandbox fails to start in
that case, so failing early here saves a confusing launch.

## Validator

`scripts/Test-SandboxConfig.ps1` checks a `.wsb` against the
documented schema before you launch it:

```powershell
.\scripts\Test-SandboxConfig.ps1 -Path '.\configs\untrusted.wsb'
.\scripts\Test-SandboxConfig.ps1 -Path '.\myconfig.wsb' -SkipHostFolderCheck
```

It rejects unknown elements and values, a non-numeric
`MemoryInMB`, a `<MappedFolder>` without a host folder, and a
mapped host folder that does not exist on this machine. It
warns (but does not fail) on memory below 2048 MB, which
Windows Sandbox raises automatically, and on writable mapped
folders, whose changes persist after the sandbox closes.

## Options reference

[`docs/options.md`](docs/options.md) documents every `.wsb`
element, its allowed values, its default, and the things the
format cannot do (window size, persistence, snapshots, and
more than one logon command).

## Layout

```text
configs/    Shipped .wsb profiles (untrusted, installer-test, dev-test)
scripts/    New-SandboxConfig.ps1  — generator
            Test-SandboxConfig.ps1 — validator
            Enable-WindowsSandbox.ps1 — edition/feature/virtualization preflight
docs/       options.md, profiles.md
tests/      test_configs.py — schema checks for every shipped .wsb
```

## Development

```powershell
# Validate every shipped profile.
Get-ChildItem -Path '.\configs' -Filter '*.wsb' | ForEach-Object {
    .\scripts\Test-SandboxConfig.ps1 -Path $_.FullName
}
```

```bash
# Same schema checks, cross-platform, no PowerShell needed.
python3 tests/test_configs.py
```

CI (`.github/workflows/ci.yml`, Windows runner) runs both:
the PowerShell validator on every shipped profile, the Python
schema tests, and PSScriptAnalyzer at error severity on the
scripts.

## Security notes

- The shipped defaults are deliberately the safe side of the
  documented defaults: stock Sandbox enables networking and
  clipboard, which is fine for a clean desktop and wrong for
  untrusted software. The Untrusted profile turns both off.
- Never map your whole user profile, Documents, or any folder
  with credentials into a sandbox running untrusted software —
  and never map one writable. Read-only, one folder, one job.
- A sandbox is a boundary, not a guarantee. Keep the host
  patched, and do not treat "it ran in Sandbox" as proof a
  file is safe to run on the host.

## Reference

Microsoft's Windows Sandbox documentation:
<https://learn.microsoft.com/en-us/windows/security/application-security/application-isolation/windows-sandbox/windows-sandbox-overview>

## License

MIT — see [LICENSE](LICENSE).
