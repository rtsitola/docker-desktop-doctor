# Inventorying an orphaned `docker_data.vhdx` (before you delete 50 GB)

Silent relocations leave the previous data disk behind. Docker never touches it again, it is
usually the largest file on the machine, and `docker system df` cannot see it — it is not part
of the running Docker at all.

## Two numbers that are not the same number

Measured on a real orphan found during a cleanup:

| | |
|---|---|
| `.vhdx` file size on disk | **52 416 217 088 bytes (48.8 GiB)** |
| ext4 content actually inside | **1.3 GB** |
| images inside | **0** (no `repositories.json`: already pruned) |

A VHDX never shrinks after a prune. It keeps the high-water mark of everything that was ever
written: images, layer cache, build scratch. Judging it by its file size overstates what you
are about to destroy by a factor of 40.

Conversely, a small file can be precious. You cannot tell from the outside. Look inside.

## The obstacle: no root

`mount` and `debugfs` on the attached device need root, and the normal user in a WSL distro
usually has no passwordless sudo:

```
$ sudo -n true
sudo: interactive authentication is required
```

But the **`docker-desktop` distro runs as root**, and all WSL distros share the same utility
VM's block devices. So the inventory runs there:

```bash
wsl.exe --mount --vhd 'K:\...\docker_data.vhdx' --bare      # no admin needed
wsl.exe -d docker-desktop -- sh -c 'mount -o ro,noload /dev/sdX /mnt/probe; ls /mnt/probe'
wsl.exe --unmount 'K:\...\docker_data.vhdx'
```

`ro,noload` matters: it mounts read-only **and skips journal replay**, so the filesystem is
never modified, not even to "repair" itself.

## Use the script

```bash
./scripts/inventory-docker-vhdx.sh 'K:\DOCKER\DockerDesktopWSL\...\docker_data.vhdx'
```

It attaches the disk, probes every unmounted block device read-only until it finds one
containing `data/docker`, prints what is inside, and detaches on exit (even on failure, via
`trap`). It never writes to the disk and refuses to touch anything already mounted — a live
Docker data disk is mounted, so it is skipped by construction.

Real output, from a byte-for-byte copy of a live data disk (the original is left mounted and
untouched while the copy is probed — this is the safe way to exercise the tool):

```
==> docker data disk found on /dev/sde

--- volumes ---
    1001 KiB  ai_anythingllm_storage
       5 MiB  ai_n8n_data
      25 KiB  ai_ollama_data
       1 GiB  ai_open-webui_data
       8 KiB  ai_searxng_data

--- containers that used to run ---
  anythingllm
  n8n
  ollama
  open-webui
  searxng

--- images ---
  "docker.n8n.io/n8nio/n8n:latest"
  "ghcr.io/open-webui/open-webui:main"
  "mintplexlabs/anythingllm:latest"
  "ollama/ollama:latest"
  "searxng/searxng:latest"

--- space, honest figures ---
  1.0G  .../volumes
  15.3G .../overlay2

  real content inside   : 15 GiB
  .vhdx file size       : 19 GiB
  -> the file is 80% data, the rest is space the VHD never gave back
```

## What the inventory tells you

- **no `repositories.json`** → there are no images to lose. Everything is re-pullable from the
  registries listed in your `docker-compose.yml`, so the disk is disposable.
- **a container name you no longer have** (`lab-juiceshop`, `moneyprinterturbo-api`, …) →
  that service existed at that date. Check whether your compose files still define it.
- **a volume that is fatter than its live counterpart** → that is the one thing a delete would
  actually cost you. Example: an `anythingllm_storage` of 46 MB on the orphan against 1 MB in
  the live stack — real documents and embeddings that the current volume does not have.
  Archive just those before deleting:

```bash
wsl.exe -d docker-desktop -- sh -c \
  "mount -o ro,noload /dev/sde /mnt/probe && tar czf /mnt/host/k/DOCKER/old-volumes.tar.gz \
   -C /mnt/probe/data/docker/volumes ai_anythingllm_storage && umount /mnt/probe"
```

- **hardlinked "duplicates" free nothing.** Two paths with identical md5 may be the same
  inode: check before counting them as reclaimable space.

```bash
stat -c '%i liens=%h %n' a/model.safetensors b/model.safetensors
# 2814749767394255 liens=3 a/model.safetensors
# 2814749767394255 liens=3 b/model.safetensors     <- deleting one frees 0 bytes
```
