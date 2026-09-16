#!/usr/bin/env bash
# inventory-docker-vhdx.sh - read-only inventory of an orphaned docker_data.vhdx
#
# Answers the only question that matters before you delete a multi-gigabyte
# Docker data disk: WHAT IS ACTUALLY INSIDE IT?
#
# Mounts the file read-only (ro,noload - no journal replay, no repair) inside the
# docker-desktop WSL distro, which runs as root, because the normal user in a
# distro usually has no passwordless sudo.
#
# usage:  ./inventory-docker-vhdx.sh 'K:\DOCKER\...\docker_data.vhdx'
#         (pass the WINDOWS path - wsl.exe --mount --vhd needs it)
#
# Nothing is written to the disk, and the file is detached on exit (trap).

set -euo pipefail

VHDX_WIN="${1:-}"
if [ -z "$VHDX_WIN" ]; then
    echo "usage: $(basename "$0") 'K:\\path\\to\\docker_data.vhdx'" >&2
    exit 2
fi

if ! command -v wsl.exe >/dev/null 2>&1; then
    echo "error: wsl.exe not found - run this from inside WSL" >&2
    exit 3
fi

# Best-effort size of the file, for the "file size vs content size" comparison.
VHDX_SIZE_BYTES=""
if command -v stat >/dev/null 2>&1; then
    # translate K:\a\b -> /mnt/k/a/b, only when the file is reachable from here
    win_path="${VHDX_WIN//\\//}"
    drive="$(printf '%s' "$win_path" | cut -c1 | tr '[:upper:]' '[:lower:]')"
    wsl_path="/mnt/${drive}$(printf '%s' "$win_path" | cut -c3-)"
    if [ -f "$wsl_path" ]; then
        VHDX_SIZE_BYTES="$(stat -c%s "$wsl_path" 2>/dev/null || true)"
    fi
fi

echo "==> attaching $VHDX_WIN (read-only inventory)"
trap 'wsl.exe --unmount "$VHDX_WIN" >/dev/null 2>&1 || true' EXIT

wsl.exe --mount --vhd "$VHDX_WIN" --bare

echo "==> probing inside the docker-desktop distro (root, ro,noload mounts)"

# The inner script exits 1 when no Docker data disk is found: keep set -e from
# aborting the whole tool before we can report it.
set +e
wsl.exe -d docker-desktop -- env VHDX_SIZE_BYTES="${VHDX_SIZE_BYTES:-}" sh -s <<'INNER'
set -eu

probe=/mnt/ddd-probe
mkdir -p "$probe"

human() {
    # bytes -> human, integer only (keeps this POSIX)
    b="$1"
    if [ "$b" -ge 1073741824 ]; then echo "$((b / 1073741824)) GiB"
    elif [ "$b" -ge 1048576 ]; then echo "$((b / 1048576)) MiB"
    elif [ "$b" -ge 1024 ]; then echo "$((b / 1024)) KiB"
    else echo "$b B"; fi
}

inventory() {
    root="$1/data/docker"
    echo
    echo "--- volumes ---"
    if [ -d "$root/volumes" ]; then
        for v in "$root"/volumes/*; do
            [ -d "$v" ] || continue
            name=$(basename "$v")
            [ "$name" = "backingFsBlockDev" ] && continue
            [ "$name" = "metadata.db" ] && continue
            sz=$(du -sb "$v" 2>/dev/null | cut -f1 || echo 0)
            printf '  %10s  %s\n' "$(human "$sz")" "$name"
        done
    else
        echo "  (no volumes directory)"
    fi

    echo
    echo "--- containers that used to run ---"
    if [ -d "$root/containers" ]; then
        grep -oh '"Name":"/[^"]*"' "$root"/containers/*/config.v2.json 2>/dev/null \
            | sed 's/"Name":"\///; s/"$//' | sort -u | sed 's/^/  /' || true
        n=$(grep -oh '"Name":"/[^"]*"' "$root"/containers/*/config.v2.json 2>/dev/null | sort -u | wc -l)
        [ "$n" -gt 0 ] || echo "  (none)"
    else
        echo "  (no containers directory)"
    fi

    echo
    echo "--- images ---"
    if [ -s "$root/image/overlay2/repositories.json" ]; then
        keys=$(grep -o '"[a-zA-Z0-9._/@-]\+:[a-zA-Z0-9._-]\+"' "$root/image/overlay2/repositories.json" \
               | sort -u | sed 's/^/  /' || true)
        if [ -n "$keys" ]; then echo "$keys"; else echo "  (repositories.json present but empty)"; fi
    else
        echo "  NONE - no repositories.json: every image was already pruned"
    fi

    echo
    echo "--- space, honest figures ---"
    du -sh "$root"/* 2>/dev/null | sort -h | tail -8 | sed 's/^/  /' || true
    used=$(du -sb "$root" 2>/dev/null | cut -f1 || echo 0)
    echo
    echo "  real content inside   : $(human "$used")"
    if [ -n "${VHDX_SIZE_BYTES:-}" ]; then
        echo "  .vhdx file size       : $(human "$VHDX_SIZE_BYTES")"
        if [ "$VHDX_SIZE_BYTES" -gt 0 ]; then
            pct=$((used * 100 / VHDX_SIZE_BYTES))
            echo "  -> the file is ${pct}% data, the rest is space the VHD never gave back"
        fi
    fi
}

tried=0
for d in /dev/sd? /dev/vd? ; do
    [ -b "$d" ] || continue
    # never touch something already mounted (a live Docker data disk is mounted)
    if grep -q "^${d}[0-9]* " /proc/mounts; then continue; fi
    tried=$((tried + 1))
    if mount -o ro,noload "$d" "$probe" >/dev/null 2>&1; then
        if [ -d "$probe/data/docker" ]; then
            echo "==> docker data disk found on $d"
            inventory "$probe"
            umount "$probe" 2>/dev/null || true
            exit 0
        fi
        umount "$probe" 2>/dev/null || true
    fi
done

echo "==> no docker data disk found ($tried unmounted block devices were probed)"
echo "    Either this vhdx is not a Docker data disk, or it is already mounted."
exit 1
INNER
rc=$?
set -e

echo
if [ $rc -eq 0 ]; then
    echo "==> done (detaching)"
else
    echo "==> nothing found (detaching)"
fi
exit $rc
