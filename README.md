# docker-desktop-doctor

**Docker Desktop ate 20 GB of my C: drive and never said a word. Here is what it was, and how to get it back.**

<p align="center">
  <img src="assets/docker-desktop-doctor.jpg" alt="docker-desktop-doctor: a diagnostic checklist card for Docker Desktop" width="360">
</p>

A read-only diagnostic for Windows that reports where the gigabytes actually went,
flags the five failure modes that account for almost all of it, and repairs them on
request. Tested against Docker Desktop 4.83.0 and 4.91.0 — the failure modes documented
here were reproduced from scratch, with the log lines and byte counts included.

```
  [CRITICAL] Windows engine daemon config is ZEROED (all NUL bytes)
             C:\Users\me\.docker\windows-daemon.json  (28 bytes of nothing)
             -> This is the crash-loop trigger. Quarantine it: -Fix
  [CRITICAL] backend.error.json is huge
             4.75 GB  - a recursively nested error dump
             -> Write-only file, Docker never reads it back. Delete it: -Fix
  [CRITICAL] The data disk could not be attached - the engine never started
             wsl.exe --mount --bare --vhd <data disk> -> ...AttachDisk/MountDisk/HCS/E_ACCESSDENIED
             data disk id: 3d3e456b-bbac-304a-ba1e-99ef61f785ae  [last seen 2026-09-17T19:58:19.291618100Z]
             -> docker desktop stop; wsl --unmount "<exact vhdx>"; docker desktop start
  [OK      ] Data folder is already redirected
             junction -> K:\DOCKER\wsl\disk
```

## The symptom

You notice `C:\Users\<you>\AppData\Local\Docker` is enormous. Docker Desktop was working
*yesterday*. `wsl -l -v` shows the distro **Stopped**, `docker ps` says
`cannot find ... dockerDesktopLinuxEngine`, and the app shows a dialog whose only buttons
are **Quit** and **Reset to factory defaults**.

Do not click reset. It is offered as the fix and it costs you every image, container and
volume — then quietly puts the data folder back on the drive you were trying to empty.

## Quick start

```powershell
# read-only report - nothing is modified
.\docker-desktop-doctor.ps1

# also hunt for orphaned data disks on every fixed drive (slower)
.\docker-desktop-doctor.ps1 -ScanDrives

# repair: quarantine corrupt configs, delete the crash dump, clear a stuck disk attach
docker desktop stop
.\docker-desktop-doctor.ps1 -Fix

# move the data folder to another drive and junction it back
docker desktop stop
.\docker-desktop-doctor.ps1 -Relocate K:\DOCKER
```

Default mode is **read-only**. It refuses to `-Fix` or `-Relocate` while Docker Desktop is
running, and it never deletes or moves a `.vhdx` file.

## What it checks

| # | Check | Why |
|---|-------|-----|
| 1 | Version, processes, size of the data folder, free space on the system drive | the baseline you are trying to explain |
| 2 | `.docker\windows-daemon.json`, `.docker\daemon.json`, `settings-store.json`: missing / empty / **zeroed** / malformed / valid | a zeroed config is the #1 cause of the backend crash-loop |
| 3 | `backend.error.json` size + the config path the backend blamed; rotated host logs | the multi-GB file, and its actual root cause |
| 4 | WSL distro base paths, `docker_data.vhdx` size, and whether the data folder is a junction | is the data really where you think it is |
| 5 | Host logs for a failed data-disk attach (`AttachDisk … E_ACCESSDENIED`, `no sd* disk … wwid ending by <hex>`) | the misleading message that makes people wipe a healthy install |
| 6 | Orphaned `docker_data.vhdx` on every fixed drive (`-ScanDrives`) | silent relocation leaves the old disk behind, forever |

---

## Failure mode 1 — a zeroed config file crash-loops the backend

An unclean shutdown (power loss, hard reset) can leave a config file **allocated at its old
length but filled with NUL bytes**: NTFS kept the metadata, the deferred data write never
landed. Docker's JSON parser does not survive it:

```
backend crashed, dumping error to file and reporting to user:
initializing backend: initializing settings loader and loading startup providers:
loading settings from providers: loading/formatting daemon.json: parsing daemon config
<HOME>\.docker\windows-daemon.json: parsing JSON: invalid character '\x00' looking for beginning of value
```

**The non-obvious part: the `.bak` next to it is useless.** Docker's backup mechanism copies
the file *as it is when it is rewritten*, so `windows-daemon.json.bak-<timestamp>` was
zeroed too — same length, same 28 NUL bytes. There is no valid copy to restore from.

Repair: quarantine the file and let Docker rewrite a clean one. It is optional by design —
a missing file means "use defaults", so nothing is lost (the file carried no settings).

## Failure mode 2 — the crash dump has no size limit

Every crash rewrites `%LOCALAPPDATA%\Docker\backend.error.json`. The document is a single
JSON object whose error nodes nest inside each other (`wrappedError`, `errors.joinError`
chains), and after a handful of restarts it had reached:

**4 753 195 840 bytes — 4.75 GB (4.4 GiB)** for one config parse error.

The file is write-only: Docker never reads it back, so deleting it is safe. In the session
this tool came from, that single file was 99% of the "Docker takes 20 GB" complaint.

## Failure mode 3 — the data folder silently moves back to C:

`Settings → Resources → Advanced → Disk image location` lives in `settings-store.json`.
That is precisely the file a factory-reset rewrites. After a reset the key disappears, Docker
falls back to `%LOCALAPPDATA%\Docker`, registers a **fresh empty** data disk there, and your
containers are gone — while the old multi-GB `docker_data.vhdx` sits untouched on the drive
you had configured. Two independent symptoms of the same reset:

- the settings file shrinks to a handful of keys (a normal profile has dozens)
- `settings-store.json` loses the disk-location key

**Reset-proof fix: redirect the data folder with an NTFS junction.** Docker keeps using its
default path, Windows redirects the bytes to the drive you want, and a settings reset cannot
undo it:

```powershell
docker desktop stop
.\docker-desktop-doctor.ps1 -Relocate K:\DOCKER
```

which does the copy, verifies every file byte-for-byte, then:

```bat
rmdir /s /q "%LOCALAPPDATA%\Docker\wsl\disk"
mklink /J   "%LOCALAPPDATA%\Docker\wsl\disk" "K:\DOCKER\wsl\disk"
```

Two things measured while doing this on a real machine:

- **19.2 GiB copied in 32 seconds** (~600 MB/s) with `robocopy /E` on a local SSD — a move of
  the data disk is a coffee break, not an afternoon. Copy first, verify, delete second;
  `robocopy /MOVE` is unnecessary risk.
- **The distro rootfs cannot be moved while WSL runs.** `wsl\main\ext4.vhdx` (~96 MB) stays
  locked by `vmmemWSL` even with Docker Desktop stopped and `wsl --terminate docker-desktop`
  done. Only `wsl\disk` (the multi-GB one) is movable live. Moving `main` requires a reboot;
  leaving it in place costs ~100 MB and breaks nothing.

> **Quoting pitfall:** from WSL, `cmd.exe /c 'robocopy "C:\..." ...'` re-escapes the quotes
> and robocopy dies with `ERREUR 123 / ERROR 123 - invalid name`. Put the command in a `.bat`
> (CRLF) and call that instead. `-Relocate` runs natively on the Windows side and does not
> have this problem.

## Failure mode 4 — orphaned data disks you cannot see

After a silent relocation, the previous `docker_data.vhdx` stays on disk forever. It is
orphaned, Docker never touches it again, and it is usually the largest file you own:

| | |
|---|---|
| file size on disk | **52 416 217 088 bytes (48.8 GiB)** |
| actual ext4 content inside | **1.3 GB** |
| images inside | **0** |

A VHDX never shrinks after a prune: the file keeps the high-water mark of everything that was
ever written. **A `.vhdx` file size is not the data size.** Inventory it read-only before
deleting anything — `scripts/inventory-docker-vhdx.sh` does that and prints the volumes and
container names it finds. To hand the slack back to Windows, see
[Shrinking the data disk](#shrinking-the-data-disk-after-a-prune).

## Failure mode 5 — the data disk cannot be attached, and Docker blames the disk

The engine never starts, and the error you are shown points at the wrong thing:

```
[wsl-bootstrap] provisioning data via data disk with id: 3d3e456b-bbac-304a-ba1e-99ef61f785ae
[wsl-bootstrap] disk not found: no sd* disk in /sys/block with wwid ending by
                3d3e456bbbac99ef61f785ae: file does not exist. Retrying in 100ms (attempt 3 of 3)
Error: preparing environment: provisioning data: detecting disk: no sd* disk ...: file does not exist
```

`no sd* disk … wwid ending by <hex>` reads like *"your data disk is gone"*, and the dialog's
other button is *Reset to factory defaults*. Both are wrong. The bootstrap is reporting the
**absence of a block device that an earlier step failed to attach**, and the real error is a
few records above in `%LOCALAPPDATA%\Docker\log\host\com.docker.backend.exe.log`:

```
mounting data disk: mounting WSL VHDX: running wslexec: Access is denied.
Wsl/Service/AttachDisk/MountDisk/HCS/E_ACCESSDENIED:
wsl.exe --mount --bare --vhd C:\Users\<you>\AppData\Local\Docker\wsl\disk\docker_data.vhdx
```

The disk is fine — its id is the one Docker asks for, no process holds it, and the very same
attach succeeds by hand. What is stuck is the **attach state inside the WSL utility VM** (a
previous crash-loop, or a read-only inventory mount that was never detached, is the usual
way in). Clear it by name:

```powershell
docker desktop stop
wsl --unmount "C:\Users\<you>\AppData\Local\Docker\wsl\disk\docker_data.vhdx"   # explicit path only
docker desktop start
docker ps -a        # your containers coming back is the proof the right disk attached
```

`-Fix` does exactly this, and only this: it never deletes, moves or compacts a `.vhdx`, never
runs a bare `wsl --unmount`, and never unregisters a distro. Full evidence table — what was
ruled out and how — in [docs/05](docs/05-attach-denied-stale-attachment.md).

## Shrinking the data disk after a prune

```powershell
docker desktop stop
Optimize-VHD -Path "$env:LOCALAPPDATA\Docker\wsl\disk\docker_data.vhdx" -Mode Full   # Hyper-V feature + admin
docker desktop start
```

No Hyper-V feature on your edition? `diskpart` does the same job:

```bat
:: compact.txt
select vdisk file="C:\Users\<you>\AppData\Local\Docker\wsl\disk\docker_data.vhdx"
attach vdisk readonly
compact vdisk
detach vdisk
```
```powershell
docker desktop stop
diskpart /s compact.txt          # from an elevated prompt
docker desktop start
```

Optional, if you want the freed blocks offered to the disk first (needs Docker running):

```powershell
wsl -d docker-desktop -- fstrim -v /mnt/docker-desktop-disk
```

Do it detached (Docker stopped) and elevated. On a disk you care about, do it on a copy first —
`robocopy` it out and compact the copy.

**Expect modest numbers.** On a 19.2 GiB data disk here: **201 MiB reclaimed (1%)** —
`diskpart` reported success each time. That disk was 80% payload with only ~3.7 GiB of slack,
which is what a freshly rebuilt stack looks like; a disk that grew over months and was then
pruned has more to give. The guest's `fstrim` is not propagated to the host file (it reported
989 GiB trimmed and the file moved by 1 MiB — journal replay), so `compact vdisk` can only
reclaim whatever the block map already considers free.

Full protocol, measurements and the mechanism:
[docs/04-shrink-the-data-disk.md](docs/04-shrink-the-data-disk.md).

## Safety model

- **read-only by default** — the report never writes anything
- `-Fix` and `-Relocate` **refuse to run while Docker Desktop is running**
- `-Fix` only ever *renames* a corrupt config (to `*.corrupt-<timestamp>`), deletes the
  write-only crash dump, and — when the logs show a failed attach — runs
  `wsl --unmount "<the exact vhdx>"` to clear the stuck attachment state
- **no `.vhdx` is ever deleted, moved or compacted**, and none is touched without an explicit
  copy + byte-for-byte verification when relocating
- nothing is unregistered: `wsl --unregister` on a Docker distro can take down the whole WSL
  subsystem, and this tool never uses it
- it only ever runs `wsl --unmount <the exact file it attached>`, never bare — a bare
  `wsl --unmount` detaches the `docker-desktop` distro's own system overlay and leaves the engine
  unable to start (see [docs/03](docs/03-inventory-orphan-vhdx.md#%EF%B8%8F-never-run-bare-wsl---unmount-while-docker-desktop-is-running))

## Requirements

Windows 10/11, PowerShell 5.1+, Docker Desktop using the WSL 2 backend.
`-Fix`, `-ScanDrives` and `-Relocate` need no administrator rights (junctions and
`wsl --unmount` do not either).
Verified on Docker Desktop **4.83.0 (234302)**, engine **29.6.2**, and Docker Desktop
**4.91.0 (239619)**, engine **29.8.0**, WSL **2.7.14**, kernel **6.18.33.2**.

## Tests

```
powershell -ExecutionPolicy Bypass -File tests\run-tests.ps1
```

Thirteen scenarios (26 assertions), each in a throw-away sandbox with
`USERPROFILE`/`APPDATA`/`LOCALAPPDATA` redirected, asserting on the report text: zeroed
config, empty config, malformed JSON, valid configs, oversized dump, small dump,
factory-reset settings, junction detection, healthy tree, report-only-by-default, a failed
data-disk attach in the host log, a healthy host log (no false positive), and `-Fix` doing
nothing but an explicit-path detach. No real Docker file is touched.

## Repository layout

```
docker-desktop-doctor.ps1          the tool (single file, no dependencies)
tests/run-tests.ps1                sandboxed end-to-end tests
scripts/inventory-docker-vhdx.sh   read-only inventory of an orphaned docker_data.vhdx
assets/                            README illustration
docs/01-crash-loop-zeroed-config.md
docs/02-move-data-off-system-drive.md
docs/03-inventory-orphan-vhdx.md
docs/04-shrink-the-data-disk.md      why compaction returns 1%, measured
docs/05-attach-denied-stale-attachment.md   "no sd* disk" is not a missing disk
docs/upstream-issue-draft.md       ready-to-file bug report for the unbounded error dump
```

## License

MIT — see [LICENSE](LICENSE).
