# Moving the Docker data folder off the system drive (and making it stick)

## Why the GUI setting is not enough

`Settings → Resources → Advanced → Disk image location` is stored in
`%APPDATA%\Docker\settings-store.json`. That is one of the files a factory-reset rewrites —
and a factory-reset is exactly what the crash dialog offers you. After the reset the key is
gone, Docker falls back to `%LOCALAPPDATA%\Docker`, and it registers a **fresh, empty** data
disk there while your configured one sits untouched on the other drive.

Observed on the machine this tool came from:

| | |
|---|---|
| `settings-store.json` | 172 bytes, **6 top-level keys** (a normal profile has dozens) |
| configured data folder | silently back to `C:\Users\<you>\AppData\Local\Docker` |
| the old data disk | still on `K:`, 20.6 GB, never touched again |

## The reset-proof fix: an NTFS junction

Docker keeps using its default path. Windows redirects the bytes. A settings reset cannot undo
a junction, because there is no setting to reset — the redirection lives in the filesystem.

```
C:\Users\<you>\AppData\Local\Docker\wsl\disk
    └── <JUNCTION> ──> K:\DOCKER\wsl\disk        (docker_data.vhdx, the real data)
```

```powershell
docker desktop stop
.\docker-desktop-doctor.ps1 -Relocate K:\DOCKER
```

The tool performs, in this order:

1. refuse to run while any Docker process is alive
2. `robocopy <src> <dst> /E /NFL /NDL /NJH /NP /R:1 /W:1`
3. **verify every file byte-for-byte** against the source
4. `Remove-Item` the source subfolder, then `mklink /J` it back to the new location

Step 3 before step 4 is deliberate. `robocopy /MOVE` deletes as it goes; a copy you have not
verified is not a move, it is a gamble.

## Measured

| | |
|---|---|
| payload | 20 604 518 400 bytes (19.2 GiB) `docker_data.vhdx` + 96 MB rootfs |
| `robocopy /E` | **32 seconds** (~600 MB/s, local SSD) |
| junction | `Get-Item .\wsl\disk \| fl LinkType,Target` → `Junction` → `K:\DOCKER\wsl\disk` |
| proof it is really in use | the `.vhdx` mtime on `K:` advances while containers run, and no new `docker_data.vhdx` appears under `AppData\Local\Docker` |
| result on `C:` | 68 GB → 91 GB free |

## The two things that will bite you

### 1. The distro rootfs cannot be moved while WSL runs

`wsl\main\ext4.vhdx` (~96 MB) is held open by `vmmemWSL` even with Docker Desktop stopped and
`wsl --terminate docker-desktop` completed:

```
C:\...\Docker\wsl\main\ext4.vhdx - Le processus ne peut pas accéder au fichier car ce fichier
est utilisé par un autre processus.
```

It is released only when the WSL2 VM restarts — i.e. a reboot or `wsl --shutdown`, and
`wsl --shutdown` kills your own shell session if you are working inside WSL. So:

- **junction `wsl\disk`** (the multi-gigabyte folder, free and unlocked) — works live
- **leave `wsl\main`** on the system drive — costs ~100 MB and breaks nothing
- finish the `main` move after a reboot if you care about tidiness

### 2. Quoting from WSL

```bash
# WRONG - WSL interop re-escapes the quotes and robocopy dies
cmd.exe /c 'robocopy "C:\Users\me\AppData\Local\Docker\wsl" "K:\DOCKER\wsl" /E'
# 2026/09/16 ERREUR 123 (0x0000007B) Accès au répertoire source C:\"C:\Users\me\..."
#                  La syntaxe du nom de fichier, de répertoire ou de volume est incorrecte.
```

Put the command in a `.bat` file (CRLF line endings) and call that:

```bash
cmd.exe /c 'C:\path\to\move.bat'
```

`-Relocate` runs natively on the Windows side and never hits this.

## Don't

- **Do not `wsl --unregister` a Docker distro while Docker Desktop is running.** Both distros
  live in the same utility VM; unregistering one in use can take down the whole WSL subsystem
  and kill your other distro's session.
- **Do not `wsl --import` a `docker_data.vhdx`.** It is a Docker data disk, not a WSL rootfs.
  The resulting distro fails with `execvpe(/bin/sh) failed: No such file or directory`.
  Let Docker Desktop recreate its own storage — it does that on start when a data disk is
  present at the path it expects.
- **Do not delete the old `docker_data.vhdx` before checking what is inside it.** See
  `03-inventory-orphan-vhdx.md`.
