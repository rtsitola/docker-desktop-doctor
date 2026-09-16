# Shrinking the data disk after a prune

Command lines first, measurements after, then what to do when compaction is not enough.

```powershell
docker desktop stop
Optimize-VHD -Path "$env:LOCALAPPDATA\Docker\wsl\disk\docker_data.vhdx" -Mode Full   # Hyper-V + admin
docker desktop start
```

```bat
:: compact.txt  -  for editions without the Hyper-V feature
select vdisk file="C:\Users\<you>\AppData\Local\Docker\wsl\disk\docker_data.vhdx"
attach vdisk readonly
compact vdisk
detach vdisk
```
```powershell
docker desktop stop
diskpart /s compact.txt        # elevated prompt
docker desktop start
```

Optional, before compacting, to offer the guest's free blocks to the disk (Docker running):

```powershell
wsl -d docker-desktop -- fstrim -v /mnt/docker-desktop-disk
```

**Measured on a live-data-disk copy here: 201 MiB reclaimed on a 19.2 GiB file (1%).** That is
the expected order of magnitude right after a rebuild: the file was 80% payload, leaving only
~3.7 GiB of slack, and the ceiling of any compaction *is* the slack. A disk that grew over
months of image churn and was then pruned has far more to give — the orphan inventoried in
`03-inventory-orphan-vhdx.md` carried ~47 GiB of slack in a 48.8 GiB file.

All numbers below are from a reproducible experiment on Docker Desktop 4.83.0 / WSL 2.7.14,
run **on a byte-for-byte copy** of a live data disk. The original was never touched.

## Why the file does not shrink by itself

A dynamic VHDX grows and never shrinks. It keeps a block-allocation table (BAT) recording which
blocks were ever written, and `docker system prune` frees space *inside the guest filesystem* -
which the BAT knows nothing about. Two real examples:

| | file on disk | real content inside | slack |
|---|---|---|---|
| live data disk | 20 604 518 400 B (19.19 GiB) | 16 663 527 690 B (15.52 GiB) | **3.67 GiB** |
| orphan from a silent relocation | 52 416 217 088 B (48.8 GiB) | ~1.3 GB | **~47 GiB** |

## The experiment

```powershell
# 0. copy first - never experiment on the disk Docker is using
docker desktop stop                      # optional: the copy is taken from the live file
robocopy "$env:LOCALAPPDATA\Docker\wsl\disk" K:\DOCKER\_test docker_data.vhdx /NFL /NDL /NJH /NP
```

```bash
# 1. attach the COPY (no admin needed) and measure what is inside
wsl.exe --mount --vhd 'K:\DOCKER\_test\docker_data.vhdx' --bare
wsl.exe -d docker-desktop -- du -sb /mnt/probe/data/docker     # 16 663 527 690 B
wsl.exe --unmount 'K:\DOCKER\_test\docker_data.vhdx'
```

```bat
:: 2. compact it, exactly as the folklore says (elevated)
diskpart /s compact.txt
:: compact.txt:
::   select vdisk file="K:\DOCKER\_test\docker_data.vhdx"
::   attach vdisk readonly
::   compact vdisk
::   detach vdisk
```

```bash
# 3. ask the guest to discard every free block, then compact again
#    (mount the copy read-write: discard is only issued on a live mount)
wsl.exe -d docker-desktop -- sh -c 'mount /dev/sdX /mnt/ddd-trim && fstrim -v /mnt/ddd-trim'
#   -> /mnt/ddd-trim: 989 GiB (1 061 905 915 904 bytes) trimmed
```

## Results

| step | file size | delta |
|---|---|---|
| initial copy | 20 604 518 400 B | - |
| `fstrim` on the mounted guest (989 GiB discarded) | 20 459 814 912 B | **+1 MiB** (journal replay wrote, nothing was returned) |
| `diskpart compact vdisk` (no trim) | 20 458 766 336 B | −139 MiB |
| `fstrim` then `diskpart compact vdisk` | 20 393 754 624 B | −63 MiB |
| **total reclaimed** | | **201 MiB — 1.0% of the file, and only 5% of the 3.67 GiB of slack** |

`diskpart` reported success at every step (`DiskPart a correctement compacté le fichier de
disque virtuel`, exit code 0). It simply had nothing to reclaim.

## Why the reclaim is small

`compact vdisk` (and `Optimize-VHD -Mode Full`) reclaim **BAT blocks that are marked
unallocated**, so two things cap the result: how much slack the file has, and how much of that
slack the block map has been told about. On the disk measured here both caps bit — only 3.7 GiB
of slack existed, and the discards did not reach the host file:

- the guest happily reports "989 GiB trimmed" - that number describes the *filesystem's* free
  ranges, it is not space returned to Windows
- the host file did not move by a single byte from the trim
- the subsequent compaction therefore mostly walked a BAT in which the blocks were still
  allocated: it returned 63 MiB of the 3.7 GiB

Corollary: zero-filling the guest's free space does not help either. Compaction never reads the
guest filesystem; it only reads the block map. If the map says "allocated", the block stays.

## What actually works when compaction is not enough

### Option A - move the file, don't shrink it (recommended, measured)

```powershell
docker desktop stop
.\docker-desktop-doctor.ps1 -Relocate K:\DOCKER
```

19.2 GiB copied in **32 seconds** and junctioned back; `C:` regained 23 GB in this session. The
file keeps its size but stops costing you system-drive space, and the junction survives a
settings factory-reset. See `02-move-data-off-system-drive.md`.

### Option B - rebuild the disk (fastest when the data is re-creatable)

Prune first, then let Docker build a new data disk next to the old one and restore the stack
from compose. Cheap when the inventory says there is nothing to lose:

```bash
docker system prune -af          # images, containers, build cache
./scripts/inventory-docker-vhdx.sh '<path to the data disk>'   # confirm: no images, volumes re-creatable
```

```powershell
docker desktop stop
Rename-Item "$env:LOCALAPPDATA\Docker\wsl\disk\docker_data.vhdx" docker_data.vhdx.old
docker desktop start             # a fresh, near-empty data disk is registered
docker compose -f <your stack> up -d
```

Then delete `docker_data.vhdx.old` once the stack is back. *Renaming instead of deleting is
free insurance* - and the `inventory` step above is what tells you it was safe.

### Option C - `wsl --manage --set-sparse` (WSL-native distros only)

```powershell
wsl --manage <distro> --set-sparse true
```

Makes an **WSL distro's own** rootfs VHDX sparse (and auto-shrinking over time). It does **not**
cover a Docker data disk: that file is attached separately by Docker Desktop, not registered as
a distro's `BasePath`. Not tested here; no help for the case this repo is about.

## If you still want to try compaction

Expect ~1% on Docker Desktop. Do it detached, and always on a copy first:

```powershell
docker desktop stop
wsl --shutdown                        # or at least stop Docker Desktop
Optimize-VHD -Path 'K:\DOCKER\wsl\disk\docker_data.vhdx' -Mode Full   # requires Hyper-V + admin
# or, without the Hyper-V feature:
diskpart /s compact.txt               # select vdisk / attach vdisk readonly / compact vdisk / detach vdisk
```

Both need an elevated prompt and both walk the BAT, so on a Docker data disk the result is the
same 1% measured above. They are worth it on a plain WSL distro rootfs, where discard *is*
propagated.

## Verification status

| claim | status |
|---|---|
| VHDX file never shrinks after an in-guest prune | measured |
| `fstrim` in the guest does not return bytes to the host file | measured (989 GiB reported, +1 MiB on the file) |
| `diskpart compact vdisk` reclaims ~1% | measured twice, on a copy |
| `-Relocate` (copy + verify + junction) | measured (32 s for 19.2 GiB) |
| Option B (rebuild) restore flow | **not executed here** - the inventory step that proves it safe is verified |
| Option C (`--set-sparse` on a WSL distro) | **not tested here** |
