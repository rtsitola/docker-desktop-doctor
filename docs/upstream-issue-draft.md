# Upstream issue drafts (docker/for-win)

> Status: **draft, not filed.** The commands and numbers below were observed on a real machine.
> Re-verify the byte counts on the reporting machine before filing.

---

# Draft 1 — `backend.error.json` has no size cap

**Suggested title**

`backend.error.json` has no size cap: one config parse error produced a 4.75 GB file

---

**Environment**

- Docker Desktop 4.83.0 (234302), engine 29.6.2
- Windows 11, WSL 2.7.14, kernel 6.18.33.2
- WSL 2 backend

**Description**

`%LOCALAPPDATA%\Docker\backend.error.json` grows without any bound. A single unrecoverable
config parse error — a 28-byte config file filled with NUL bytes after an unclean shutdown —
was enough for the file to reach **4 753 195 840 bytes (4.75 GB / 4.4 GiB)** across a handful
of backend restarts.

The file is a single JSON document whose error nodes nest inside each other (`wrappedError`,
`errors.joinError` chains). It is write-only: nothing reads it back, and it is not mentioned
anywhere in the UI, so it silently consumes gigabytes on the system drive.

**Steps to reproduce**

1. With Docker Desktop stopped, replace the config with a NUL-filled file of the same length:

   ```powershell
   $p = "$env:USERPROFILE\.docker\windows-daemon.json"
   $len = (Get-Item $p).Length
   [System.IO.File]::WriteAllBytes($p, (New-Object byte[] $len))
   docker desktop start
   ```

   (In the observed case this happened on its own: an unclean shutdown left the real file
   allocated at 28 bytes, entirely NUL.)

2. The backend crash-loops. Each restart rewrites the dump:

   ```
   %LOCALAPPDATA%\Docker\log\host\com.docker.backend.exe.log
   backend crashed, dumping error to file and reporting to user:
   ... loading/formatting daemon.json: parsing daemon config
   <HOME>\.docker\windows-daemon.json: parsing JSON: invalid character '\x00' looking for
   beginning of value
   ```

3. Watch `%LOCALAPPDATA%\Docker\backend.error.json` grow across restarts.

**Expected**

A diagnostic dump should be capped (rotated, or written once per unique error), or the
underlying config problem should be surfaced to the user. A log file should never be the
largest thing on the disk.

**Actual**

Unbounded growth on a restart loop. On the reporting machine the file alone accounted for
almost all of a `AppData\Local\Docker` folder that had reached 20.6 GB.

**Related observation: the recovery dialog is data-destructive**

The dialog shown for this error offers only **Quit** and **Reset to factory defaults**. Reset
removes every image, container and volume, and also clears the `Disk image location` setting
in `settings-store.json` — so users who had moved their data to another drive find it silently
back on the system drive. For a recoverable 28-byte config file, "quarantine the file and
restart" would be a non-destructive alternative worth offering.

**Workaround (verified)**

```powershell
docker desktop stop
Rename-Item "$env:USERPROFILE\.docker\windows-daemon.json" "windows-daemon.json.corrupt"
Remove-Item "$env:LOCALAPPDATA\Docker\backend.error.json"
docker desktop start
```

The config file is optional — Docker rewrites a clean one and starts normally. Containers,
images and volumes are untouched.

---

# Draft 2 — a failed VHD attach is reported as "no sd* disk … wwid ending by <hex>"

**Suggested title**

`failed to attach the data disk` is reported as `no sd* disk in /sys/block with wwid ending by
<hex>`, pointing users at the wrong fix (factory reset)

**Environment**

- Docker Desktop 4.91.0 (239619), engine 29.8.0
- Windows 11 (26200.9457), WSL 2.7.14.0, kernel 6.18.33.2
- WSL 2 backend; data folder relocated to another drive via an NTFS junction

**Description**

When the data disk cannot be attached, the error surfaced to the user (dialog + logs) is the
bootstrap's *consequence*, not the cause:

```
DockerDesktop/Wsl/ExecError: wsl.exe -d docker-desktop -u root -e wsl-bootstrap run
  --base-image /c/program files/docker/docker/resources/docker-desktop.iso
  --data-disk 3d3e456b-bbac-304a-ba1e-99ef61f785ae: exit status 1
  [wsl-bootstrap] provisioning data via data disk with id: 3d3e456b-bbac-304a-ba1e-99ef61f785ae
  [wsl-bootstrap] disk not found: no sd* disk in /sys/block with wwid ending by
                  3d3e456bbbac99ef61f785ae: file does not exist
  Error: preparing environment: provisioning data: detecting disk: no sd* disk ...: file does not exist
```

`no sd* disk … wwid ending by <hex>` reads as *"the data disk is gone"*, so the user's
reasonable next step is the only other button in the dialog: **Reset to factory defaults**,
which deletes every image, container and volume — for a disk that is perfectly intact.

The actual error is only in `%LOCALAPPDATA%\Docker\log\host\com.docker.backend.exe.log`, a few
records above:

```
mounting data disk: mounting WSL VHDX: running wslexec: Access is denied.
Wsl/Service/AttachDisk/MountDisk/HCS/E_ACCESSDENIED:
wsl.exe --mount --bare --vhd C:\Users\<you>\AppData\Local\Docker\wsl\disk\docker_data.vhdx
```

**Verified on the affected machine**

- the vhdx exists, is 20 604 518 400 bytes, opens exclusively (no lock held by any process)
- the disk id Docker asks for is the disk in place: `naa.600224803d3e456bbbac99ef61f785ae`
- the junction to the other drive is intact (`LinkType: Junction`), the volume is Healthy
- the same attach succeeds by hand, non-elevated: `wsl --mount --bare --vhd "<path>"` →
  *L'opération a réussi*

The stuck state is the utility VM's attachment bookkeeping (observed after a backend
crash-loop). `wsl --unmount "<the exact vhdx>"` clears it, and the next start attaches the
same disk and brings all containers and volumes back.

**Expected**

- the user-visible error should carry the attach failure (`E_ACCESSDENIED` on
  `--mount --bare --vhd <path>`), not only the downstream "disk not found"
- a misdiagnosed unrecoverable state should not be the one that offers "Reset to factory
  defaults" as its remedy
- the two log lines are enough to detect this automatically: the repair could be attempted
  before the engine is declared dead

**Workaround (verified)**

```powershell
docker desktop stop
wsl --unmount "C:\Users\<you>\AppData\Local\Docker\wsl\disk\docker_data.vhdx"   # explicit path
docker desktop start
docker ps -a      # containers back = the right disk was attached
```

Never a bare `wsl --unmount`: it also detaches the `docker-desktop` distro's own system
overlay and leaves the engine unable to start.

---

A diagnostic/repair tool for this and the four other storage failure modes:
https://github.com/rtsitola/docker-desktop-doctor
