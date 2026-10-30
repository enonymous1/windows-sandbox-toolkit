# Windows Sandbox configuration options

Every option a `.wsb` file can set, what it does, and what it defaults
to when you leave it out. Source: Microsoft's Windows Sandbox
configuration documentation.

| Element | Values | Default | Notes |
| --- | --- | --- | --- |
| `<vGPU>` | Enable / Disable / Default | Enabled (except ARM64) | Disable uses software rendering (WARP) and shrinks the attack surface. |
| `<Networking>` | Enable / Disable / Default | Enabled | Enabled is the risky default for untrusted software: the sandbox can reach your network. |
| `<MappedFolders>` | One or more `<MappedFolder>` blocks | None | Host folder must already exist, or the sandbox fails to start. Relative host paths are not supported. Since Windows 11 23H2, environment variables may be used in the path. |
| `<HostFolder>` | Absolute host path | Required inside `<MappedFolder>` | — |
| `<SandboxFolder>` | Absolute sandbox path | Container user's Desktop | The container user is `WDAGUtilityAccount`. |
| `<ReadOnly>` | true / false | false | Writable mapped folders keep their changes after the sandbox closes. Everything else inside the sandbox is discarded. |
| `<LogonCommand>` / `<Command>` | A single command | None | Must be an executable or script that exists *inside* the sandbox. For multi-step setup, map a script file in and run that. Mapped folders are mounted before the logon command runs. |
| `<AudioInput>` | Enable / Disable / Default | Enabled | Shares your microphone into the sandbox. |
| `<VideoInput>` | Enable / Disable / Default | Disabled | Shares your webcam into the sandbox. |
| `<ProtectedClient>` | Enable / Disable / Default | Disabled | Runs the sandbox in AppContainer isolation. It can restrict copy/paste in and out. |
| `<PrinterRedirection>` | Enable / Disable / Default | Disabled | Shares host printers into the sandbox. |
| `<ClipboardRedirection>` | Enable / Disable / Default | Enabled | With this on, files and text can be pasted between host and sandbox. |
| `<MemoryInMB>` | Number of megabytes | 4096 (basic launch) | Below 2048, Windows Sandbox raises it to 2048 automatically. |

## Things a `.wsb` file cannot do

- **Window size** is not configurable.
- **Persistence** is not an option: closing the sandbox deletes
  everything inside it. The only exception is a writable mapped
  folder, which is really a host folder, not sandbox storage.
- **Snapshots, multiple logon commands, and per-app rules** are not
  part of the format. If you need those, you need a real VM
  (Hyper-V, for example), not Windows Sandbox.
- **Only one `<LogonCommand>`** is supported. Chain steps in a
  script file instead of trying to add a second command.
