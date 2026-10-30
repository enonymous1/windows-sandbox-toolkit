# Profiles: which one to use, and what survives

## `configs/untrusted.wsb` — software you do not trust

Networking off, GPU sharing off, microphone off, camera off,
clipboard off, printers off, Protected Client on. No folder mapped.

Use it for: a downloaded executable, an installer from an
unfamiliar source, a document or archive you are unsure about.

To get a file in, generate a copy with a **read-only** mapped
folder (see the README). Read-only matters: a writable mapping
lets whatever runs in the sandbox write back to your host.

## `configs/installer-test.wsb` — installers that need the network

Networking on, clipboard off, no folder mapped. Many installers
download components, so networking off would break them — but
there is no reason an installer needs your clipboard or a host
folder, so those stay off.

Use it for: installers from vendors you recognise, where you
still want the sandbox boundary intact.

## `configs/dev-test.wsb` — your own builds

Networking on, GPU sharing on, clipboard on, so you can paste
test data and pull dependencies. Audio, video, and printers stay
off because a dev test rarely needs them.

Use it for: your own code, a build you just compiled, a tool
you already trust. Do not use it for untrusted downloads —
the clipboard and network alone make it the wrong profile
for that job.

## What survives closing the sandbox

Nothing inside the sandbox does. Installed programs, downloaded
files, registry changes, desktop files — all discarded when you
close it and confirm deletion.

The one exception: a **writable mapped folder**. That folder
lives on the host, so changes made to it from inside the
sandbox stay on the host after the sandbox is gone. That is
why the generator defaults Untrusted mappings to read-only,
and why `Test-SandboxConfig.ps1` warns about every writable
mapping it finds.

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Sandbox fails to start, no clear error | A mapped host folder does not exist | Create the folder, or remove the mapping. Run `Test-SandboxConfig.ps1` first — it checks this. |
| Sandbox fails to start | Feature not enabled, or virtualization off in firmware | Run `Enable-WindowsSandbox.ps1`, then enable virtualization in BIOS/UEFI if it warns about it. |
| Sandbox will not start at all | Windows Home | Windows Sandbox is not available on Home. It needs Pro, Enterprise, or Education. |
| Logon command does nothing | The command path does not exist inside the sandbox | Map the script in with `-HostFolder` and point the command at the sandbox-side path, e.g. `C:\Users\WDAGUtilityAccount\Desktop\shared\setup.bat`. |
| Cannot paste in or out | Clipboard redirection off, or Protected Client on | That is the profile working as intended. Switch profiles only if you actually trust the contents. |
| Sandbox is slow / graphics glitchy | vGPU disabled | Expected with `untrusted.wsb` — it uses software rendering on purpose. Use `dev-test.wsb` for your own software. |
| "Out of memory" or a slow boot | MemoryInMB too low | Raise it with `-MemoryInMB`. Below 2048 it is raised to 2048 automatically. |
