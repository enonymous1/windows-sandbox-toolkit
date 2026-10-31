# Changelog

All notable changes to this project are documented here. The format
follows Keep a Changelog, and the project uses semantic versioning
for its releases (the .wsb format itself is versioned by Microsoft,
not by this project).

## [Unreleased]

## [1.1.1] - 2026-10-31

CI fix release. No profile behaviour changed and no shipped
`.wsb` file changed.

### Fixed

- Generator self-validation no longer reads `$LASTEXITCODE`
  after an in-process validator call. A PowerShell script
  never sets `$LASTEXITCODE`, so the old check read whatever
  the previous native command left behind: in CI the XXE
  validator case (correctly exiting 1) ran just before the
  Windows mapping case, so a valid `mapped.wsb` was reported
  as failed. On a real failure the validator's `exit 1` also
  terminated the whole process in-process, so the old throw
  was unreachable for real failures. The generator now runs
  the validator as a subprocess (`pwsh`/`powershell` from
  PATH, falling back to `$PSHOME`), where `$LASTEXITCODE` is
  real and an exit does not kill the generator, and merges
  the validator's error stream so a real failure's output is
  printed instead of swallowed. The validator's header now
  documents this subprocess requirement for future callers.
- The engine lookup in the new subprocess code is null-safe
  under `Set-StrictMode`: reading `.Source` straight off a
  missing `Get-Command` result throws, which was caught by
  the local repro before it reached CI.

### Added

- `tests/Test-Generator.ps1`: "Self-validation survives
  stale LASTEXITCODE" regression case, reproducing the exact
  CI sequence (a failing validator subprocess, then a
  self-validating generator run) without needing a folder,
  so it runs on Linux CI too -- the Windows-only mapping
  case was why Linux runs never caught this.

## [1.1.0] - 2026-10-31

Staff review release. No profile behaviour changed: every shipped
profile produces the same .wsb content as 1.0.0. What changed is
how the toolkit is built and checked.

### Added

- `schema/wsb-schema.json`: the .wsb schema (allowed values,
  Microsoft defaults, profiles, memory floor, sandbox user,
  feature name, supported editions) defined exactly once. The
  generator, validator, and Python tests all read it.
- `scripts/SandboxSchema.psm1`: shared module for loading the
  schema, checking Windows paths, deriving a sandbox folder leaf,
  and expanding env-var paths.
- `tests/Test-Generator.ps1`: behaviour tests for the generator
  and validator (overrides, memory floor, conflicts, -WhatIf,
  duplicates, empty mappings, XXE, folder mapping on Windows).
  The Python tests previously only checked shipped files, which
  is why an earlier generator override bug was not caught by them.
- `docs/assets/architecture.svg`: flow diagram (see README).
- `REVIEW.md`: the full staff review behind this release.

### Changed

- Generator and validator now read profiles and allowed values
  from the schema instead of carrying their own copies.
- README rewritten with Description, Prerequisites, Installation,
  Local Development, and Deployment sections.
- CI: Python setup step renamed correctly, generator tests added,
  PSScriptAnalyzer now fails on any finding (was errors only).

### Fixed

- Generator: env-var host folders (Windows 11 23H2+) no longer
  fail the existence check when the variable is not set on the
  checking machine; the check is skipped with a warning instead.
- Generator: default sandbox folder leaf is now derived by
  splitting on both path separators, so it is correct when the
  generator runs on Linux/macOS as well as Windows.
- Generator: `-Launch` on a non-Windows machine now fails before
  any file is written, instead of writing and then throwing.
- Generator: writable mappings now warn on the warning stream,
  not just in normal output.
- Generator: `Add-Element` no longer returns a value, so callers
  cannot leak XML elements into the output pipeline.
- Generator: the XML writer is now guarded against a null writer
  masking the real write error.
- Validator: duplicated top-level elements, duplicated mapped
  folder fields, empty `<MappedFolders>`, non-positive memory,
  and relative host folders are now rejected.
- Validator: `.wsb` files are parsed with DTD processing
  prohibited and no XML resolver, so a crafted DOCTYPE cannot
  trigger external entity resolution (XXE) during validation.
- Enable script: virtualization state `$null` (not reported) is
  now reported as unknown, not as enabled; pending feature states
  now report "restart required" instead of re-enabling; the
  administrator check only runs when `-Enable` is requested;
  edition detection now uses `Win32_OperatingSystem` instead of
  the slow `Get-ComputerInfo`; `-WhatIf` is supported.

## [1.0.0] - 2026-10-30

Initial public release (renamed from `ss-windows-sandbox` before
publication; the original was a README-only stub).

- Three shipped profiles: `untrusted`, `installer-test`, `dev-test`.
- `New-SandboxConfig.ps1` generator, `Test-SandboxConfig.ps1`
  validator, `Enable-WindowsSandbox.ps1` preflight.
- `docs/options.md` and `docs/profiles.md`.
- MIT LICENSE, Windows-runner CI.
