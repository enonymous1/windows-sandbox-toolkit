# Staff review — windows-sandbox-toolkit v1.1.0

Review of v1.0.0 (commit `c039922`) by a staff engineer / open-source
maintainer, with the fixes implemented in v1.1.0. No profile
behaviour changed: every shipped profile produces the same `.wsb`
content as 1.0.0. If you only care about what changed, read
[`CHANGELOG.md`](CHANGELOG.md). This document is the reasoning
behind it, and what was deliberately left alone.

## Verdict

Ship it, with the fixes below. The original code was already
unusually careful for a small toolkit: values are written via
`XmlDocument.InnerText` (not string templating, so no XML
injection), a missing mapped host folder fails fast instead of
producing a file that fails mysteriously at launch, and the
validator and tests were already in place before the first
public push. The review found no secrets, no personal data, and
no profile that is unsafe as shipped.

What would have blocked a merge in a real review was not a
single bug, but a structural problem: the schema was defined
four times independently (generator profiles, validator allowed
values, Python test expectations, shipped `.wsb` files, plus a
fifth copy in the docs table). That is how a future Microsoft
format change, or a typo in one place, silently reverts an
option to a permissive default. Everything else in this review
flows from, or was found while fixing, that problem.

## 1. Best practices and code quality

### Implemented

| Severity | Finding | Fix in v1.1.0 |
| --- | --- | --- |
| High | Schema defined 4+ times (DRY violation). Generator, validator, Python tests, shipped files, and docs could drift independently. | `schema/wsb-schema.json` is now the single source of truth. Generator, validator, and Python tests read it. Python tests additionally check the schema against a hardcoded Microsoft option set, so a wrong schema value fails a test instead of propagating. |
| High | Validator parsed untrusted `.wsb` files with default `XmlDocument` settings, which can resolve external entities (XXE). A `.wsb` file is exactly the kind of file an untrusted source hands you. | Validator now uses `XmlReaderSettings` with `DtdProcessing = Prohibit` and `XmlResolver = $null`. A test pins this: a DOCTYPE with a `file://` entity fails validation and its content does not appear in the output. |
| Medium | Generator validated a host folder's existence *before* its format, so error messages were misleading, and env-var paths (supported on Windows 11 23H2+) failed the existence check outright. | Format is checked first; env-var paths are expanded before checking, and if the variable is not set on the checking machine the check is skipped with a warning instead of failing a documented, valid path. |
| Medium | `Split-Path -Leaf` on a Windows path returns the whole path on Linux/macOS (it uses the OS separator), so the generator's default sandbox folder was wrong whenever it ran off Windows. | `Get-SandboxFolderLeaf` in `SandboxSchema.psm1` splits on both separators explicitly. |
| Medium | `-Launch` on a non-Windows machine wrote the file and *then* threw, so automation saw a failure with a file that looked like a success. | `-Launch` is validated up front, before any side effect. A test pins both this and `-WhatIf` writing nothing. |
| Medium | Writable mappings were reported on the normal output stream, where automation ignores them. | Writable mappings now warn on the warning stream. |
| Medium | `Add-Element` returned the created element, so every caller needed `$null =` or XML elements leaked into the output pipeline. | `Add-Element` returns nothing. |
| Medium | XML writer disposal was unguarded: if `Create` failed, `Close()` on a null writer masked the real error. | Writer is initialised to `$null` and closed only if created, with a contextual error on write failure. |
| Medium | Validator accepted duplicated top-level elements, duplicated mapped-folder fields, empty `<MappedFolders>`, non-positive memory, and relative host folders -- all of which are either undefined or invalid in Windows Sandbox. | All are now rejected, with messages saying why (duplicates are undefined behaviour, not "keep the last one"). |
| Medium | `Enable-WindowsSandbox.ps1` treated virtualization `$null` (not reported) as enabled, re-enabled a feature in a pending state, checked admin even for a read-only report, and used the slow `Get-ComputerInfo` for one field. | `$null` is reported as unknown; pending states report "restart required"; admin is only checked when `-Enable` is requested; edition comes from `Win32_OperatingSystem.Caption`; `-WhatIf` is supported via `SupportsShouldProcess`. |
| Low | Generator's `Resolve-Option` relied on implicit script-scope `$defaults` (and, in an earlier version, on the function's own `$PSBoundParameters`, which silently ignored all overrides). | `Resolve-Option` now takes both bound-ness and defaults as explicit parameters. A behaviour test pins overrides. |
| Low | CI's Python setup step was misnamed (it was the setup step, labelled as the test step), and PSScriptAnalyzer only failed on errors, so warnings shipped silently. | Step renamed; analyzer now fails on any finding (currently 0 findings at all severities). |
| Low | Python tests crashed with `ValueError`/`TypeError` on a non-numeric or empty `MemoryInMB`, instead of failing with a readable assertion. | Memory parsing is guarded and fails with a message naming the file. |

### What is good, and was kept

- `InnerText` everywhere, never string-templated XML. This is the
  single most important security property in a config generator,
  and it was already right.
- Fail-fast host-folder checking, read-only default for
  Untrusted, and explicit Protected Client on the Untrusted
  profile. The secure profile is secure by construction, not by
  documentation asking the user to be careful.
- `Set-StrictMode -Version Latest` and `$ErrorActionPreference =
  'Stop'` in every script. No silent continuation after a
  failure.
- No `Write-Host`, no aliases, approved verbs only. The scripts
  were already PSScriptAnalyzer-clean at error severity; they
  are now clean at all severities.

### Performance

There is no performance problem to optimise here, and inventing
one would be dishonest: the inputs are sub-kilobyte XML files
and the scripts run once per launch. The only measurable waste
was `Get-ComputerInfo` in the enable script, which collects
every property it knows about to return one edition name; it
was replaced (see above). Do not add caching, parallelism, or
streaming to this codebase: it would add failure modes for
zero user-visible gain.

## 2. Commenting and in-code documentation

The scripts already had good PowerShell comment-based help
(`.SYNOPSIS` / `.DESCRIPTION` / `.PARAMETER` / `.EXAMPLE`),
which is the PowerShell equivalent of docstrings, and the
`.wsb` comments explained *why* each profile is locked down.
What was missing was the *why* behind non-obvious decisions,
and that is what v1.1.0 adds, in the code, not just in this
document:

- Why `Resolve-Option` takes bound-ness and defaults explicitly
  (function-scope `$PSBoundParameters`, and the override bug it
  once caused).
- Why the sandbox-folder leaf is split on both separators
  (OS-dependent `Split-Path`).
- Why the validator prohibits DTDs (untrusted input, XXE).
- Why `Add-Element` returns nothing (output-pipeline leakage).
- Why the writer close is guarded (error masking).
- Why edition detection uses `Win32_OperatingSystem` (the
  `Get-ComputerInfo` performance cost).
- Why virtualization `$null` is "unknown", not "enabled" or
  "disabled" (some firmware simply does not report it).

Python tests gained module and method docstrings that explain
*which* of three different checks each test is (schema vs
Microsoft, shipped vs schema, Untrusted vs security invariant),
because those three checks look identical in code and fail for
completely different reasons. The module docstring in
`tests/test_configs.py` states the distinction explicitly.

Deliberately not added: comments restating what a line does
("creates an element", "loops over children"). Those add noise
and rot faster than the code they describe.

## 3. Future-proofing and architecture

### The change that matters

`schema/wsb-schema.json` + `scripts/SandboxSchema.psm1` is the
architecture change. Before it, adding a Microsoft option meant
editing the generator, the validator, the Python tests, the
shipped files, and the docs table, and hoping all five agreed.
Now it means editing the schema, re-running the tests (which
check shipped files against the schema and the schema against
Microsoft's documented set), and updating the docs table, which
a test now also checks for completeness (every schema option
must appear in `docs/options.md`).

The cost is explicit and accepted: the scripts are now a
package, not standalone files. Copying one script out alone
fails with a clear error saying so, instead of failing later
with a null reference. That trade is correct for a toolkit
whose whole value is that its tools agree with each other.

### Coupling, and what remains

- Generator and validator are still separate scripts that share
  a module, not a single program. That is the right granularity:
  a user who only wants to check a file should not have to run
  a generator, and vice versa.
- The generator now self-validates its output via the sibling
  validator (unless `-SkipValidation`). This couples the two
  scripts at runtime, deliberately: a generator bug should
  surface in the generator, not on the launch machine. If the
  validator is missing, it warns instead of failing, so a
  partially-copied toolkit degrades loudly rather than silently.
- The Python tests are an independent oracle for the schema
  and for Untrusted, not just a re-implementation of the
  PowerShell logic. If the schema and the PowerShell code are
  both wrong in the same way, the hardcoded Microsoft set and
  the hardcoded Untrusted invariant are still there to catch it.
- Hardcoded values that remain, and why they are acceptable:
  the sandbox user (`WDAGUtilityAccount`) and desktop path are
  Microsoft constants, now in the schema rather than scattered
  through scripts; the 2048 MB floor and 4096 MB default are
  Microsoft-documented values, now in the schema; the feature
  name (`Containers-DisposableClientVM`) is a Windows constant,
  now in the schema. None of these should be user-configurable
  without a Microsoft documentation change to justify it.

### Not implemented, and why

- **A Pester test suite.** The behaviour tests in
  `tests/Test-Generator.ps1` are plain PowerShell, not Pester,
  because Pester is an extra dependency to install and version
  in CI, and the suite is small enough that a PASS/FAIL harness
  with an exit code is sufficient and more transparent. If the
  suite grows past ~30 cases, migrate it to Pester then, not now.
- **A Python generator.** It would duplicate the PowerShell
  generator for a Windows-only file format, and the two
  generators would immediately become the same drift problem
  the schema was created to solve. The Python tests stay tests.
- **A GUI or installer.** The toolkit's scope is configuration
  files. A GUI would need to solve the same validation problem
  and then some, for users who are already comfortable running
  a PowerShell script to launch a sandbox.
- **A `CONTRIBUTING.md`.** The contribution path is currently
  "change the schema, run the tests, update the docs table".
  That is now documented in Local Development in the README.
  A separate contributing file would restate it and rot.
- **Version pinning for PSScriptAnalyzer in CI.** The module is
  installed latest in CI. Pinning would make CI reproducible
  but would also silently age; the analyzer findings are
  currently zero, and a future analyzer version flagging a new
  rule is a useful signal, not a breakage to avoid.

## 4. README modernization

The README was rewritten in v1.1.0 (see the repository README).
Changes, against the old README:

- **Description** is now an explicit section, with the scope
  stated negatively as well as positively (what the toolkit is
  not), so a reader does not mistake it for a VM manager or a
  Microsoft product.
- **Prerequisites** separates "to run a sandbox" from "to use
  the tools", because generating and validating a file works
  on Linux/macOS PowerShell and the old README blurred that.
- **Installation** is now a real section: clone, unblock, and
  the package-structure warning (scripts are not standalone).
  The old README had no installation section at all.
- **Local Development** documents every check CI runs, what
  cannot be tested off Windows, and the schema-first workflow
  for changing a profile.
- **Deployment** covers both meanings: publishing the
  repository (push, CI, `gh repo edit` for description/topics,
  tagging) and deploying a configuration to a machine (copy the
  `.wsb`, validator first, no installer).
- Badges (CI, MIT) added; they go live on first push.
- The old README's "Requirements -- read this before anything
  else" warning is preserved in substance (Home is not
  supported) but no longer relies on a reader noticing a
  heading phrased as a warning.

## 5. Visual asset strategy

No screenshots or GIFs in this repository are faked, rendered,
or mocked. The one visual shipped in v1.1.0 is a hand-drawn
diagram, because a diagram can be drawn honestly without a
Windows machine. Everything else below is a capture task for a
Windows machine, with exact content and exact placement.
Do not substitute a mock-up: a mocked sandbox screenshot in a
security toolkit would be worse than no screenshot.

### Shipped in v1.1.0

**`docs/assets/architecture.svg`** -- Flow diagram, placed in
the README immediately after the Description section, before
Prerequisites, so a reader understands the whole toolkit in
one glance before any setup instructions. It depicts, left to
right: host folder (optional, read-only) and profile into the
generator, generator into a `.wsb` file, `.wsb` into the
validator (pass/fail), validator into a disposable Windows
Sandbox desktop, and on close, "discarded, except writable
mappings". It is an SVG (not a PNG) so it stays sharp at any
size, is editable in a text editor, and carries a `<title>` and
`<desc>` for accessibility. Verify it by opening the file, not
by trusting this paragraph: it parses as XML and contains
seven boxes and the discard note.

### To capture on Windows (not shipped, by design)

1. **`docs/assets/end-to-end.gif`** -- Place it in the README
   directly after the Quick start section, before Profiles.
   Content: a ~30-second screen recording (Windows Game Bar or
   ScreenToGif, no cursor effects, no speed-up) of Quick start
   step 3 end to end -- run the generator, see the validator
   output, launch the sandbox, see the desktop, close it, and
   see the discard confirmation. Why here: Quick start is where
   a reader decides whether the toolkit actually works, and a
   moving proof at that exact point is worth more than any
   paragraph. Why not a screenshot: the discard-on-close is a
   sequence, not a state. Capture it with a `Public` folder
   path, not a personal folder, so no username is visible.
   The README already contains an HTML comment at this exact
   insertion point naming the file.

2. **`docs/assets/sandbox-untrusted.png`** -- Place it in the
   README directly after the Profiles table, before the
   Generator section. Content: a real screenshot of a Windows
   Sandbox desktop launched from `configs/untrusted.wsb`, with
   the sandbox window clearly framed and a read-only mapped
   folder visible on its desktop. Do not annotate it with
   arrows pointing at "networking: off" -- networking off is
   not visible in a screenshot, and annotating it would imply
   otherwise. Caption it as a real capture from the shipped
   profile. Why here: the Profiles table is abstract; one
   real desktop makes "disposable" concrete. The README
   already contains an HTML comment at this exact insertion
   point naming the file.

3. **`docs/assets/validator-output.png`** -- Place it in the
   README directly after the Validator examples, before Local
   Development. Content: a real terminal screenshot showing
   the validator passing all three shipped profiles (`OK:
   configs/untrusted.wsb`, etc.) and then rejecting a bad file
   with its error message visible. Use a terminal width that
   does not wrap the error lines. Why here: the validator is
   the toolkit's trust mechanism, and seeing a rejection (not
   just a pass) is what convinces a reader it actually checks.
   The README already contains an HTML comment at this exact
   insertion point naming the file.

Do not add: a "profile comparison" infographic (the table
already does this, and an image version would duplicate it
and rot when a profile changes), a logo (the toolkit does not
need a brand mark, and a logo would imply a product, not a
set of scripts), or a screenshot of the Enable script's
output on a machine where it is already enabled (it proves
nothing).

## Test results (v1.1.0, from a fresh extraction)

- Python schema/profile tests: 6/6 pass
  (`tests/test_configs.py`).
- PowerShell behaviour tests: 14/14 pass, folder-mapping
  cases SKIP on non-Windows
  (`tests/Test-Generator.ps1`).
- PSScriptAnalyzer: 0 findings at all severities on
  `scripts/` (was 0 errors, 3 informational warnings before
  the module's output-type and comment-help fixes).
- PowerShell parser: 0 errors on all four scripts and the
  module.
- Architecture SVG: parses as XML, 7 boxes.
- Shipped profiles: unchanged from v1.0.0 (the Python test
  that checks shipped files against the schema would fail if
  they had drifted).

## Remaining gates (unchanged by this review)

- A real `.wsb` launch on Windows, and a mapped-folder
  generation on Windows, are still untested on a Windows
  machine. The generator's folder logic is now tested only
  where the platform allows it; the Windows-only cases in
  `Test-Generator.ps1` exist precisely so CI (windows-latest)
  runs them on push.
- `Enable-WindowsSandbox.ps1` execution (including `-Enable`
  and `-WhatIf`) is still untested on Windows; it is only
  parser- and analyzer-checked here.
- The CI workflow itself has not run yet; it runs on first
  push. In particular, the new "any PSScriptAnalyzer finding
  fails" step and the generator-test step are CI-only gates
  until that run.
- The three capture assets in section 5 are still to be
  captured on Windows. The README references only the shipped
  SVG by image link; the other three are HTML comments at
  their insertion points, not broken image links.

## Addendum — v1.1.1: the first CI run found a bug (2026-10-31)

CI (windows-latest) ran for the first time and failed at
exactly one place: the Windows-only mapping case, with
`Generated file failed validation: ...\mapped.wsb` and no
validator error above it. The mapped file was not invalid,
and the validator was not wrong.

Root cause, reproduced locally before fixing: the generator
called the validator in-process and checked `$LASTEXITCODE`.
A PowerShell script never sets `$LASTEXITCODE`, so the check
read the code left by the previous native command -- the XXE
validator subprocess, which correctly exits 1, running just
before the mapping case. On Linux the bug was invisible,
because the mapping cases SKIP there and every earlier
generator case uses `-SkipValidation`. The old comment
("piping would make $LASTEXITCODE describe the pipeline")
was wrong in the other direction too: a real validator
failure calls `exit 1`, which kills the calling process
in-process, so the generator's throw could never fire for a
real failure.

Fix (v1.1.1, no profile or shipped-file change): the
generator runs the validator as a subprocess, where
`$LASTEXITCODE` is real and an exit does not kill the
generator, merges its error stream so real failures are
printed, and looks up the engine null-safely under
`Set-StrictMode`. A regression test reproduces the CI
sequence without a folder, so it runs on Linux too.

Test results (v1.1.1, from a fresh extraction): Python 6/6,
PowerShell behaviour 15/15 (14 old + 1 new regression case,
folder cases still SKIP on Linux), PSScriptAnalyzer 0,
parser 0. The Windows mapping case itself remains a CI-only
gate and needs a green run after this fix; the mechanism
that failed it is now covered on every platform.

## Addendum — v1.2.0: Pages configurator (2026-10-31)

A static page, not a second generator. `site/app.js` carries
no option values, profiles, or element order of its own: it
fetches `schema.json` and builds its profile and option selects
from that file, and its XML follows the schema's element order.
The Pages workflow copies `schema/wsb-schema.json` into
`site/` at deploy time instead of committing a copy, so a
forgotten copy can never become a second source of truth.
`tests/test_configurator.mjs` exists for the same reason the
behaviour tests exist: it compares the page's output with the
PowerShell generator's output for the same inputs, and it
checks the rejection and escaping cases (relative host folder,
bad option value, non-numeric memory, XML escaping) directly.

Deliberately not built: importing an existing `.wsb` to tweak
it (that adds a second XML parser to keep in parity with the
validator), multiple mapped folders (the PowerShell generator
supports one), and any server-side or upload step (the file is
generated locally with a Blob download). The page states its
own limits in plain text: it cannot launch, check edition or
virtualization, enable the feature, or check a mapped folder
on the target machine.

Test results (v1.2.0, from a fresh extraction): Python 6/6,
PowerShell behaviour 15/15, configurator 13/13 with pwsh on
PATH (11/13 plus a stated SKIP without it), PSScriptAnalyzer 0,
parser 0, site served locally over HTTP with all four files
returning 200. Real-browser rendering was not verified here
(no Chromium on this box) and remains a post-push Pages gate,
as does the green CI run including the new Node step.
