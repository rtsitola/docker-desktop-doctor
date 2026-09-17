# Case study: Docker Desktop starts nothing because the data disk cannot be attached

Reproduced on **Docker Desktop 4.91.0 (239619)**, engine 29.8.0, Windows 11 (26200.9457),
WSL **2.7.14.0**, kernel 6.18.33.2. Data folder redirected to `K:\DOCKER\wsl\disk` by an
NTFS junction. Docker Desktop had been running fine earlier the same day.

## Symptom — and the message that sends you the wrong way

Docker Desktop opens an error dialog whose only actions are *Quit* / *Restart*, and the log
shows a bootstrap failure **naming the wrong subsystem**:

```
DockerDesktop/Wsl/ExecError: c:\windows\system32\wsl.exe -d docker-desktop -u root -e wsl-bootstrap run
  --base-image /c/program files/docker/docker/resources/docker-desktop.iso
  --data-disk 3d3e456b-bbac-304a-ba1e-99ef61f785ae: exit status 1
  [wsl-bootstrap] provisioning data via data disk with id: 3d3e456b-bbac-304a-ba1e-99ef61f785ae
  [wsl-bootstrap] disk not found: no sd* disk in /sys/block with wwid ending by
                  3d3e456bbbac99ef61f785ae: file does not exist. Retrying in 100ms (attempt 3 of 3)
  [wsl-bootstrap][W] unprovisioning data: unmounting disk: no such file or directory
  Error: preparing environment: provisioning data: detecting disk: no sd* disk ...: file does not exist
```

`no sd* disk in /sys/block with wwid ending by <hex>` reads like *"your data disk is gone"*.
It is not. It is the **last link of a chain**: the bootstrap checks for a block device that
an earlier step failed to attach, so it reports the absence of the disk instead of the reason.

The benign line in the same output is a red herring:

```
[wsl-bootstrap.version][W] failed to read component versions: open /opt/docker-desktop/componentsVersion.json: no such file or directory
```

## Real error — find it in the host log, not in the dialog

`%LOCALAPPDATA%\Docker\log\host\com.docker.backend.exe.log`, a few records **above** the
bootstrap noise (and repeated in `monitor.log`):

```
mounting data disk: mounting data disk: mounting WSL VHDX: running wslexec: Access is denied.
Wsl/Service/AttachDisk/MountDisk/HCS/E_ACCESSDENIED:
c:\windows\system32\wsl.exe --mount --bare --vhd
  C:\Users\<you>\AppData\Local\Docker\wsl\disk\docker_data.vhdx: exit status 0xffffffff
```

So the sequence is:

```
wsl.exe --mount --bare --vhd <data disk>   →  AttachDisk/MountDisk/HCS/E_ACCESSDENIED
        ↓ no sd* device in the VM
wsl-bootstrap: no sd* disk ... wwid ending by <hex>   →  distro does not boot
        ↓
Docker Desktop: "engine linux/wsl failed to start"
```

## What it is NOT (all verified read-only on the failing machine)

| Hypothesis | Evidence | Verdict |
|---|---|---|
| the vhdx is corrupt or lost | file present, 20 604 518 400 bytes, opens exclusively, no lock held | ❌ |
| Docker points at the wrong disk | the disk it asks for (`--data-disk 3d3e456b-…`) is the one in place: `naa.600224803d3e456bbbac99ef61f785ae` | ❌ |
| the junction to `K:` broke | `Get-Item …\wsl\disk` → `LinkType: Junction, Target: {K:\DOCKER\wsl\disk}` | ❌ |
| the volume is unhealthy | `Get-Volume K:` → NTFS, Healthy/OK, 298 GB free | ❌ |
| a missing / corrupt `daemon.json` | that failure looks completely different (see docs/01) | ❌ |
| WSL/ACL refuses the file | the very same attach succeeds by hand, non-elevated: `wsl --mount --bare --vhd "<path>"` → *L'opération a réussi* | ⚠️ state, not permission |

The attach state of the utility VM is what was stuck: the vhdx was still attached/claimed
inside the VM from an earlier session (a Docker crash-loop plus a manual read-only inventory
mount is the usual way to get there). The next `--mount` of the same file then comes back
`E_ACCESSDENIED`, which Docker reports one layer up as "disk not found".

Handy identity proof — the disk Docker asks for and the wwid the VM exposes are the same
object:

```bash
wsl.exe -d docker-desktop -u root -- sh -c 'grep -r . /sys/block/sd*/device/wwid'
# /sys/block/sdf/device/wwid:naa.600224803d3e456bbbac99ef61f785ae
#                             ^^^^^^^^ 60022480 + the same id family Docker passes
```

(`naa.60022480` is the Microsoft VHD virtual-disk prefix; WSL derives the suffix from the
vhdx's own disk id, so a *mismatch* is the only case that means "wrong disk".)

## Fix — detach with an explicit path, then let Docker attach it

```powershell
docker desktop stop

# clear the stuck attachment; NAME THE FILE
wsl --unmount "C:\Users\<you>\AppData\Local\Docker\wsl\disk\docker_data.vhdx"

# prove the VM no longer has it (the wwid above must be gone from the list)
wsl.exe -d docker-desktop -u root -- sh -c 'grep -r . /sys/block/sd*/device/wwid'

Start-Process 'C:\Program Files\Docker\Docker\Docker Desktop.exe'
```

60 seconds later:

```powershell
docker ps -a        # the old containers must be back: that is the proof the right disk attached
docker volume ls    # ...and the volumes
```

After the fix, the data disk appears as `/dev/sd*`, mounted at `/mnt/docker-desktop-disk`, and
its **size/mtime on `K:` advance** — which also proves the junction is the path in use.

## Why `-Fix` does exactly that, and nothing more

`docker-desktop-doctor.ps1 -Fix`:
1. detects the `AttachDisk … E_ACCESSDENIED` + `no sd* disk …` pair in the recent host logs,
2. runs `wsl --unmount "<the exact vhdx>"` — **never a bare `wsl --unmount`**, which detaches
   the `docker-desktop` distro's own system overlay and leaves the engine unable to start
   (see docs/03),
3. never deletes, moves or compacts a `.vhdx` in the process — a stale attach has no data
   consequence, so nothing here needs a factory-reset or a `wsl --import`.

## Follow-ups

- The dialog offers only *Quit* and *Reset to factory defaults*: a factory-reset is useless
  here (the data disk is intact) and actively harmful when the data folder was relocated by
  a *setting* rather than a junction. Another reason to prefer the junction.
- `wsl --unmount` needs no administrator rights; the `docker desktop stop` step does not
  either.
