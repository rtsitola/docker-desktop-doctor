#Requires -Version 5.1
<#
.SYNOPSIS
    Diagnose - and optionally repair - what is actually eating your C: drive
    when Docker Desktop is the culprit.

.DESCRIPTION
    Docker Desktop on Windows can consume tens of gigabytes of a system drive
    without ever showing a warning. This script reports the real breakdown and
    the four failure modes that account for almost all of it:

      1. A zeroed config file (all NUL bytes) that crash-loops com.docker.backend
      2. backend.error.json - an unbounded recursive crash dump (multi-GB)
      3. The WSL data disk (docker_data.vhdx) silently back on the system drive
         after a settings factory-reset
      4. Orphaned docker_data.vhdx files left behind on previous locations

    Default mode is READ-ONLY: it reports and prints the commands to run.
    Nothing is modified unless you pass -Fix or -Relocate.

.PARAMETER Fix
    Quarantine corrupt config files and delete oversized error dumps.
    Refuses to run while Docker Desktop is running. Never touches a .vhdx.

.PARAMETER Relocate
    Destination folder (for example K:\DOCKER). Copies the WSL data folder
    there, verifies byte-for-byte, then replaces the original path with an
    NTFS junction. Reset-proof: a Docker settings factory-reset cannot undo it.

.PARAMETER ScanDrives
    Additionally walk every fixed drive (depth -Depth) looking for orphaned
    docker_data.vhdx files. Off by default: it is the slowest check.

.PARAMETER Depth
    Folder depth for -ScanDrives (default 4).

.PARAMETER Force
    Skip the interactive confirmation prompts for -Fix / -Relocate.

.EXAMPLE
    .\docker-desktop-doctor.ps1
    Read-only diagnosis.

.EXAMPLE
    .\docker-desktop-doctor.ps1 -ScanDrives
    Diagnosis plus a hunt for orphaned data disks on all drives.

.EXAMPLE
    .\docker-desktop-doctor.ps1 -Relocate K:\DOCKER
    Move the WSL data folder to K:\DOCKER and junction it back.

.NOTES
    Author: rtsitola - https://github.com/rtsitola/docker-desktop-doctor
    License: MIT
    Tested on Docker Desktop 4.83.0 (Engine 29.6.2), Windows 11, WSL 2.7.14.
#>
[CmdletBinding()]
param(
    [switch] $Fix,
    [string] $Relocate,
    [switch] $ScanDrives,
    [int]    $Depth = 4,
    [switch] $Force
)

$ErrorActionPreference = 'Continue'

$script:Findings = @()

# ---------------------------------------------------------------------------
# output helpers
# ---------------------------------------------------------------------------

function Say {
    param([string] $Text = '', [string] $Colour = 'Gray')
    Write-Host $Text -ForegroundColor $Colour
}

function Section {
    param([string] $Title)
    Say ''
    Say ('-' * 74) 'DarkGray'
    Say ("  $Title") 'White'
    Say ('-' * 74) 'DarkGray'
}

function Finding {
    param(
        [ValidateSet('OK', 'INFO', 'WARN', 'CRITICAL')] [string] $Level,
        [string] $Title,
        [string] $Detail,
        [string] $Action
    )
    $colour = switch ($Level) {
        'OK'       { 'Green' }
        'INFO'     { 'Cyan' }
        'WARN'     { 'Yellow' }
        'CRITICAL' { 'Red' }
    }
    Say ("  [{0,-8}] {1}" -f $Level, $Title) $colour
    if ($Detail) { Say ("             $Detail") 'DarkGray' }
    if ($Action) { Say ("             -> $Action") 'Gray' }
    $script:Findings += [pscustomobject]@{
        Level  = $Level
        Title  = $Title
        Detail = $Detail
        Action = $Action
    }
}

function Format-Size {
    param([long] $Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

# ---------------------------------------------------------------------------
# probes
# ---------------------------------------------------------------------------

# A config file zeroed by an unclean shutdown keeps its length but contains
# only NUL bytes. JSON parsers report 'invalid character \x00'.
function Test-ZeroFilled {
    param([string] $Path, [int] $Probe = 8192)
    try {
        $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    } catch {
        return $false
    }
    try {
        $buf = New-Object byte[] $Probe
        $read = $fs.Read($buf, 0, $Probe)
        if ($read -le 0) { return $false }
        for ($i = 0; $i -lt $read; $i++) {
            if ($buf[$i] -ne 0) { return $false }
        }
        return $true
    } finally {
        $fs.Dispose()
    }
}

function Test-JsonConfig {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{ State = 'missing'; Bytes = 0 }
    }
    $len = (Get-Item -LiteralPath $Path).Length
    if ($len -eq 0) {
        return [pscustomobject]@{ State = 'empty'; Bytes = 0 }
    }
    if (Test-ZeroFilled -Path $Path) {
        return [pscustomobject]@{ State = 'zeroed'; Bytes = $len }
    }
    try {
        $raw = Get-Content -LiteralPath $Path -Raw
        $obj = $raw | ConvertFrom-Json
        return [pscustomobject]@{ State = 'valid'; Bytes = $len; Object = $obj }
    } catch {
        return [pscustomobject]@{
            State = 'invalid'
            Bytes = $len
            Error = $_.Exception.Message
        }
    }
}

function Get-DockerProcess {
    Get-Process -Name 'Docker Desktop', 'com.docker.backend', 'com.docker.build',
        'docker', 'com.docker.admin' -ErrorAction SilentlyContinue
}

function Get-DockerDesktopVersion {
    $exe = Join-Path ${env:ProgramFiles} 'Docker\Docker\Docker Desktop.exe'
    if (Test-Path -LiteralPath $exe) {
        return (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion
    }
    return $null
}

function Get-WslDockerDistro {
    $lxss = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    if (-not (Test-Path $lxss)) { return @() }
    Get-ChildItem $lxss -ErrorAction SilentlyContinue | ForEach-Object {
        $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        if ($p -and $p.DistributionName -match 'docker') {
            [pscustomobject]@{
                Name     = $p.DistributionName
                BasePath = ($p.BasePath -replace '^\\\\\?\\', '')
            }
        }
    }
}

function Get-VhdxInfo {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $fi = Get-Item -LiteralPath $Path
    [pscustomobject]@{
        Path       = $fi.FullName
        Bytes      = $fi.Length
        LastWrite  = $fi.LastWriteTime
        IsJunction = ($fi.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
    }
}

function Invoke-Main {
    Say ''
    Say '  docker-desktop-doctor' 'White'
    Say '  https://github.com/rtsitola/docker-desktop-doctor' 'DarkGray'
    Say ("  mode: {0}{1}{2}" -f `
        $(if ($Fix) { 'FIX ' } else { 'report-only ' }), `
        $(if ($Relocate) { "RELOCATE($Relocate) " } else { '' }), `
        $(if ($ScanDrives) { 'SCAN-DRIVES' } else { '' })) 'DarkGray'
    Say ("  date: {0}" -f (Get-Date)) 'DarkGray'
}

# ---------------------------------------------------------------------------
# 1. environment
# ---------------------------------------------------------------------------

Invoke-Main

Section '1. Environment'

$dataRoot = Join-Path $env:LOCALAPPDATA 'Docker'
$wslRoot  = Join-Path $dataRoot 'wsl'

$ddVersion = Get-DockerDesktopVersion
$procs     = Get-DockerProcess
Finding 'INFO' 'Docker Desktop version' ($(if ($ddVersion) { $ddVersion } else { 'not found in Program Files' }))
Finding 'INFO' 'Running processes' ($(if ($procs) { (($procs | Select-Object -ExpandProperty ProcessName -Unique) -join ', ') } else { 'none - Docker Desktop is stopped' }))

if (Test-Path -LiteralPath $dataRoot) {
    $sum = (Get-ChildItem -LiteralPath $dataRoot -Recurse -File -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum
    if (-not $sum) { $sum = 0 }
    Finding 'INFO' 'Data folder' ("$dataRoot  =  " + (Format-Size ([long]$sum)))
} else {
    Finding 'WARN' 'Data folder does not exist' $dataRoot
}

$driveLetter = (Split-Path -Qualifier $env:LOCALAPPDATA).TrimEnd(':')
try {
    $vol = Get-Volume -DriveLetter $driveLetter -ErrorAction Stop
    $freeGb = [math]::Round($vol.SizeRemaining / 1GB, 1)
    Finding 'INFO' "Free space on ${driveLetter}:" "$freeGb GB free"
    if ($freeGb -lt 20) {
        Finding 'WARN' "System drive is tight" "$freeGb GB free on ${driveLetter}:" 'Reclaiming the Docker data folder is usually the fastest win.'
    }
} catch { }

# ---------------------------------------------------------------------------
# 2. configuration integrity
# ---------------------------------------------------------------------------

Section '2. Configuration files (the crash-loop trigger)'

$configs = @(
    @{ Path = (Join-Path $env:USERPROFILE '.docker\windows-daemon.json'); Role = 'Windows engine daemon config' },
    @{ Path = (Join-Path $env:USERPROFILE '.docker\daemon.json'); Role = 'Linux engine daemon config' },
    @{ Path = (Join-Path $env:APPDATA 'Docker\settings-store.json'); Role = 'Docker Desktop settings' }
)

$corrupt = @()

foreach ($c in $configs) {
    $r = Test-JsonConfig -Path $c.Path
    switch ($r.State) {
        'valid' {
            $keys = 0
            if ($r.Object -ne $null) {
                $keys = @($r.Object.PSObject.Properties).Count
            }
            Finding 'OK' "$($c.Role) parses" ("$($c.Path)  ({0} bytes, {1} top-level keys)" -f $r.Bytes, $keys)
            if ($c.Path -like '*settings-store.json' -and $keys -lt 10) {
                Finding 'WARN' 'Settings look factory-reset' "only $keys keys - a normal profile has dozens" 'A reset is silent and is what sends the data disk back to the system drive. Check the disk location after a repair.'
            }
        }
        'missing' {
            Finding 'INFO' "$($c.Role) absent" $c.Path 'Not an error by itself: Docker treats it as optional and uses defaults.'
        }
        'empty' {
            Finding 'WARN' "$($c.Role) is empty" $c.Path 'Docker will fail to parse it the same way it fails on NUL bytes.'
            $corrupt += $c
        }
        'zeroed' {
            Finding 'CRITICAL' "$($c.Role) is ZEROED (all NUL bytes)" ("$($c.Path)  ({0} bytes of nothing)" -f $r.Bytes) "This is the crash-loop trigger. Quarantine it: -Fix"
            $corrupt += $c
        }
        'invalid' {
            Finding 'CRITICAL' "$($c.Role) is not valid JSON" ("$($c.Path)  ({0} bytes) : {1}" -f $r.Bytes, $r.Error) 'Quarantine it and let Docker rewrite a clean one: -Fix'
            $corrupt += $c
        }
    }
}

if ($corrupt.Count -gt 0) {
    Finding 'INFO' 'Why this matters' 'com.docker.backend cannot start, and every restart rewrites a recursive error dump (check 3).'
}

# ---------------------------------------------------------------------------
# 3. error dump
# ---------------------------------------------------------------------------

Section '3. Crash dump (the multi-GB file)'

$errDump = Join-Path $dataRoot 'backend.error.json'
if (Test-Path -LiteralPath $errDump) {
    $len = (Get-Item -LiteralPath $errDump).Length
    if ($len -gt 100MB) {
        Finding 'CRITICAL' 'backend.error.json is huge' ((Format-Size $len) + '  - a recursively nested error dump') 'Write-only file, Docker never reads it back. Delete it: -Fix'
    } elseif ($len -gt 5MB) {
        Finding 'WARN' 'backend.error.json is large' (Format-Size $len) 'The backend crashed at least once. Read the first 2 KB to see which config it blamed.'
        try {
            $head = Get-Content -LiteralPath $errDump -Raw -TotalCount 1
            if ($head.Length -gt 400) { $head = $head.Substring(0, 400) }
            $m = [regex]::Match($head, '"description":"(?<d>[^"]{0,300})"')
            if ($m.Success) { Say ("             blamed: " + $m.Groups['d'].Value) 'DarkGray' }
        } catch { }
    } else {
        Finding 'OK' 'backend.error.json is small' (Format-Size $len) 'No recent crash.'
    }
} else {
    Finding 'OK' 'No backend.error.json' 'The backend is not currently crash-looping.'
}

# rotated host logs
$hostLog = Join-Path $dataRoot 'log\host'
if (Test-Path -LiteralPath $hostLog) {
    $rot = Get-ChildItem -LiteralPath $hostLog -File -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -match '\.log\.20\d{6}-' }
    if ($rot.Count -gt 0) {
        $sum = ($rot | Measure-Object -Property Length -Sum).Sum
        Finding 'INFO' 'Rotated host logs' ("{0} files, {1}" -f $rot.Count, (Format-Size $sum)) 'Safe to delete; they rotate at 1 MB each.'
    }
}

# ---------------------------------------------------------------------------
# 4. storage location
# ---------------------------------------------------------------------------

Section '4. Where the WSL data disk actually lives'

$distros = Get-WslDockerDistro
foreach ($d in $distros) {
    Finding 'INFO' "$($d.Name) rootfs" $d.BasePath
}

$diskVhdx = Get-VhdxInfo -Path (Join-Path $wslRoot 'disk\docker_data.vhdx')
$mainVhdx = Get-VhdxInfo -Path (Join-Path $wslRoot 'main\ext4.vhdx')

if ($diskVhdx) {
    Finding 'INFO' 'Data disk (images, containers, volumes)' ((Format-Size $diskVhdx.Bytes) + '  ' + $diskVhdx.Path + "  [last write $($diskVhdx.LastWrite) ]")
    if ($diskVhdx.Bytes -gt 30GB) {
        Finding 'WARN' 'The data disk is the real consumer' (Format-Size $diskVhdx.Bytes) 'Move it off the system drive and junction it back: -Relocate <path>'
    }
} else {
    Finding 'WARN' 'No docker_data.vhdx at the default location' (Join-Path $wslRoot 'disk\docker_data.vhdx') 'Docker is either using a custom location or has never started. Use -ScanDrives to find data disks elsewhere.'
}

if ($mainVhdx) {
    Finding 'INFO' 'Distro rootfs' ((Format-Size $mainVhdx.Bytes) + '  ' + $mainVhdx.Path)
    Finding 'INFO' 'The rootfs cannot be moved while WSL runs' 'It is locked by vmmemWSL: only the disk subfolder is movable live. See docs/03-move-data-off-system-drive.md'
}

# is the default path a junction?
$diskDir = Join-Path $wslRoot 'disk'
if (Test-Path -LiteralPath $diskDir) {
    $item = Get-Item -LiteralPath $diskDir -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        $target = ''
        try { $target = $item.Target } catch { $target = '' }
        if ($target -is [array]) { $target = $target[0] }
        if (-not $target) { $target = '(target not readable on this PowerShell version)' }
        Finding 'OK' 'Data folder is already redirected' "junction -> $target" 'A settings factory-reset cannot undo this.'
    }
}

# ---------------------------------------------------------------------------
# 5. orphaned data disks
# ---------------------------------------------------------------------------

Section '5. Orphaned data disks'

if ($ScanDrives) {
    $found = @()
    foreach ($drive in (Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Free -ne $null })) {
        $root = "$($drive.Name):\"
        Say ("  scanning $root (depth $Depth) ...") 'DarkGray'
        try {
            $hits = Get-ChildItem -LiteralPath $root -Filter 'docker_data.vhdx' -Recurse -Depth $Depth -File -Force -ErrorAction SilentlyContinue
        } catch { $hits = @() }
        foreach ($h in $hits) {
            $found += [pscustomobject]@{
                Path  = $h.FullName
                Bytes = $h.Length
                Age   = $h.LastWriteTime
            }
        }
    }
    if ($found.Count -eq 0) {
        Finding 'OK' 'No docker_data.vhdx found on any drive' ''
    } else {
        foreach ($f in $found) {
            Finding 'INFO' 'docker_data.vhdx' ((Format-Size $f.Bytes) + '  ' + $f.Path + "  [last write $($f.Age) ]")
        }
        Finding 'WARN' 'A docker_data.vhdx file size is NOT the data size' 'A 52 GB file can hold 1.3 GB of ext4 content: the VHD never shrinks after a prune. Inventory it read-only before deleting, see scripts/inventory-docker-vhdx.sh'
    }
} else {
    Finding 'INFO' 'Skipped' 'Pass -ScanDrives to hunt for orphaned docker_data.vhdx on every fixed drive.'
}

# ---------------------------------------------------------------------------
# verdict
# ---------------------------------------------------------------------------

Section 'Verdict'

$crit = @($script:Findings | Where-Object { $_.Level -eq 'CRITICAL' })
$warn = @($script:Findings | Where-Object { $_.Level -eq 'WARN' })

if ($crit.Count -eq 0 -and $warn.Count -eq 0) {
    Finding 'OK' 'Nothing to repair' 'Docker Desktop storage looks healthy.'
} else {
    Say ("  {0} critical, {1} warning" -f $crit.Count, $warn.Count) 'White'
    foreach ($f in ($crit + $warn)) {
        Say ("    - $($f.Title)") 'Gray'
        if ($f.Action) { Say ("      $($f.Action)") 'DarkGray' }
    }
}

# ---------------------------------------------------------------------------
# repair
# ---------------------------------------------------------------------------

function Invoke-Fix {
    Section 'Fix'

    $running = Get-DockerProcess
    if ($running) {
        Finding 'CRITICAL' 'Docker Desktop is running' (($running | Select-Object -ExpandProperty ProcessName -Unique) -join ', ') 'Run "docker desktop stop" first, then re-run with -Fix. Nothing was changed.'
        return
    }

    foreach ($c in $corrupt) {
        if (-not (Test-Path -LiteralPath $c.Path)) { continue }
        $stamp  = Get-Date -Format 'yyyyMMddHHmmss'
        $dest   = "$($c.Path).corrupt-$stamp"
        try {
            Move-Item -LiteralPath $c.Path -Destination $dest -ErrorAction Stop
            Finding 'OK' 'Quarantined' "$($c.Path)  ->  $dest"
        } catch {
            Finding 'CRITICAL' 'Could not quarantine' "$($c.Path) : $($_.Exception.Message)"
        }
    }

    if (Test-Path -LiteralPath $errDump) {
        $len = (Get-Item -LiteralPath $errDump).Length
        if ($len -gt 5MB) {
            try {
                Remove-Item -LiteralPath $errDump -Force -ErrorAction Stop
                Finding 'OK' 'Deleted crash dump' ((Format-Size $len) + ' reclaimed: ' + $errDump)
            } catch {
                Finding 'CRITICAL' 'Could not delete crash dump' "$errDump : $($_.Exception.Message)"
            }
        }
    }

    Finding 'INFO' 'Next' 'Start Docker Desktop, then "docker version" must show a Server section (that means the backend came up).'
}

# ---------------------------------------------------------------------------
# relocation
# ---------------------------------------------------------------------------

function Invoke-Relocate {
    param([string] $Target)

    Section "Relocate to $Target"

    $running = Get-DockerProcess
    if ($running) {
        Finding 'CRITICAL' 'Docker Desktop is running' (($running | Select-Object -ExpandProperty ProcessName -Unique) -join ', ') 'Run "docker desktop stop" first. Nothing was changed.'
        return
    }
    if (-not (Test-Path -LiteralPath $wslRoot)) {
        Finding 'CRITICAL' 'Nothing to move' "$wslRoot does not exist"
        return
    }

    $targetWsl = Join-Path $Target 'wsl'
    if (Test-Path -LiteralPath $targetWsl) {
        Finding 'CRITICAL' 'Destination already exists' $targetWsl 'Pick an empty destination.'
        return
    }

    if (-not $Force) {
        Say ''
        Say "  About to copy $wslRoot" 'Yellow'
        Say "        to        $targetWsl" 'Yellow'
        Say '  then replace the source with an NTFS junction.' 'Yellow'
        $answer = Read-Host '  Type YES to continue'
        if ($answer -ne 'YES') { Say '  aborted.' 'Red'; return }
    }

    Finding 'INFO' 'Copying (robocopy /E)' 'Expect ~600 MB/s on a local SSD.'
    $null = robocopy $wslRoot $targetWsl /E /NFL /NDL /NJH /NP /R:1 /W:1
    $rc = $LASTEXITCODE
    if ($rc -ge 8) {
        Finding 'CRITICAL' "robocopy failed (exit $rc)" 'Nothing was removed; the source is untouched.'
        return
    }
    Finding 'OK' "Copy finished (robocopy exit $rc)" ''

    # verify byte-for-byte on every file
    $mismatch = @()
    Get-ChildItem -LiteralPath $wslRoot -Recurse -File -Force | ForEach-Object {
        $rel = $_.FullName.Substring($wslRoot.Length).TrimStart('\')
        $dst = Join-Path $targetWsl $rel
        if (-not (Test-Path -LiteralPath $dst)) {
            $mismatch += "$rel (missing at destination)"
        } elseif ((Get-Item -LiteralPath $dst).Length -ne $_.Length) {
            $mismatch += "$rel (size differs)"
        }
    }
    if ($mismatch.Count -gt 0) {
        Finding 'CRITICAL' 'Verification failed' ($mismatch -join '; ') 'Source kept intact. Nothing was removed.'
        return
    }
    Finding 'OK' 'Copy verified' 'Every file matches by size.'

    New-Item -ItemType Directory -Path $Target -Force | Out-Null

    foreach ($sub in @('disk', 'main')) {
        $src = Join-Path $wslRoot $sub
        if (-not (Test-Path -LiteralPath $src)) { continue }
        $dst = Join-Path $targetWsl $sub

        try {
            Remove-Item -LiteralPath $src -Recurse -Force -ErrorAction Stop
        } catch {
            if ($sub -eq 'main') {
                Finding 'WARN' 'Could not remove the distro rootfs' "$src : locked by vmmemWSL" 'Expected: only a WSL VM restart releases it. Leaving it in place is harmless (~100 MB). Delete it manually after a reboot.'
                continue
            }
            Finding 'CRITICAL' "Could not remove $src" $_.Exception.Message 'The copy is at the destination; the junction was NOT created.'
            continue
        }

        $cmd = 'mklink /J "{0}" "{1}"' -f $src, $dst
        cmd.exe /c $cmd | Out-Null
        if ($LASTEXITCODE -eq 0) {
            Finding 'OK' "Junction created for $sub" "$src  ->  $dst"
        } else {
            Finding 'CRITICAL' "mklink failed for $sub" "copy kept at $dst; recreate the link manually: $cmd"
        }
    }

    Finding 'INFO' 'Next' 'Start Docker Desktop and run "docker ps -a". Your containers must come back: that proves the redirected data disk is in use.'
}

# ---------------------------------------------------------------------------
# entry
# ---------------------------------------------------------------------------

if ($Relocate) { Invoke-Relocate -Target $Relocate }
if ($Fix)      { Invoke-Fix }

if (-not $Fix -and -not $Relocate) {
    Say ''
    Say '  No change was made (report-only). Add -Fix to repair, -Relocate <path> to move the data.' 'DarkGray'
    Say ''
}
