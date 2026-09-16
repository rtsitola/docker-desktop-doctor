# Case study: a zeroed config file crash-loops the Docker Desktop backend

Reproduced on **Docker Desktop 4.83.0 (234302)**, engine 29.6.2, Windows 11, WSL 2.7.14.

## Symptom

- `docker ps` → `failed to connect to the docker API at
  npipe:////./pipe/dockerDesktopLinuxEngine; check if the path is correct and if the
  daemon is running`
- `wsl -l -v` → `docker-desktop  Stopped`
- Docker Desktop shows a dialog titled *"An unexpected error occurred"* whose only actions
  are **Quit** and **Reset to factory defaults**
- `C:\Users\<you>\AppData\Local\Docker` has grown by gigabytes

## Evidence

`%LOCALAPPDATA%\Docker\log\host\com.docker.backend.exe.log` (and `monitor.log`):

```
[com.docker.backend.exe] backend crashed, dumping error to file and reporting to user:
initializing backend: initializing settings loader and loading startup providers:
loading settings from providers: loading/formatting daemon.json: parsing daemon config
<HOME>\.docker\windows-daemon.json: parsing JSON: invalid character '\x00' looking for beginning of value
```

`%LOCALAPPDATA%\Docker\backend.error.json` = **4 753 195 840 bytes (4.75 GB / 4.4 GiB)**.

The offending file:

```
$ xxd ~/.docker/windows-daemon.json
00000000: 0000 0000 0000 0000 0000 0000 0000 0000  ................
00000010: 0000 0000 0000 0000                    ........
```

**28 bytes of nothing.** Length preserved, content gone.

## Root cause

An unclean shutdown — power loss, hard reset, crash — can leave a file *allocated at its old
length* while the data pages were never flushed. NTFS keeps the size; the content reads back
as NUL. Docker's JSON parser meets `\x00` and the backend exits.

The loop is then self-sustaining: the launcher restarts the backend, the backend crashes again
on the same file, and each crash appends a fresh copy of the error to `backend.error.json`.
The dump is a single JSON object whose error nodes nest inside one another (`wrappedError`,
`errors.joinError` chains), and it reached 4.75 GB after a handful of restarts.

## The trap

The dialog offers **Reset to factory defaults** as the fix. It works, in the sense that Docker
starts again — and it costs every image, container and volume, and returns the data folder to
the system drive. That is a data-loss fix for a 28-byte config problem.

The sidecar backup cannot save you either:

```
-rw-rw-rw-  28 Sep 15 10:49 windows-daemon.json
-rw-rw-rw-  28 Aug 18 13:29 windows-daemon.json.bak-20260818132916
```

Both are 28 NUL bytes. The backup mechanism copies the config *as it is being rewritten*, so
it faithfully preserved the corruption. **There is no valid copy to restore from.**

## Repair

```powershell
docker desktop stop
.\docker-desktop-doctor.ps1 -Fix
```

which does exactly this, and nothing else:

```powershell
Move-Item "$env:USERPROFILE\.docker\windows-daemon.json" `
          "$env:USERPROFILE\.docker\windows-daemon.json.corrupt-<timestamp>"
Remove-Item "$env:LOCALAPPDATA\Docker\backend.error.json"
```

`windows-daemon.json` is optional by design: Docker treats a missing file as "use defaults".
In this case the file carried no settings, so nothing was lost. Docker rewrote a clean 28-byte
file (`{".....": ...}, 1 top-level key`) on the next start, and the report confirms it parses.

## Verification

```
$ docker version
Client:  Version 29.6.2 ... Context: desktop-linux
Server: Docker Desktop 4.83.0 (234302)
 Engine:  Version 29.6.2 ...  Experimental: false
```

`docker ps -a` showed the five containers back, all volumes intact, and
`backend.error.json` did not reappear.

## Why the doctor checks this first

This is the only one of the four failure modes that makes Docker look *broken* rather than
merely *fat*, and it is the one where the officially offered remedy destroys data. A NUL-byte
probe plus a JSON parse is enough to catch it before anyone clicks reset.
