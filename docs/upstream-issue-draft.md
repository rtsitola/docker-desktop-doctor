# Upstream issue draft (docker/for-win)

> Status: **draft, not filed.** The commands and numbers below were observed on a real machine.
> Re-verify the byte counts on the reporting machine before filing.

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

A diagnostic/repair tool for this and the three other storage failure modes:
https://github.com/rtsitola/docker-desktop-doctor
