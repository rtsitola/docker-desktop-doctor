#Requires -Version 5.1
<#
.SYNOPSIS
    End-to-end tests for docker-desktop-doctor.ps1.

.DESCRIPTION
    Each test builds a throw-away sandbox that fakes %USERPROFILE%, %APPDATA%
    and %LOCALAPPDATA%, drops known-bad (or known-good) fixtures into it, runs
    the doctor in a child PowerShell with those variables overridden, and
    asserts on the report text. No real Docker file is ever touched.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tests\run-tests.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$doctor   = Join-Path $repoRoot 'docker-desktop-doctor.ps1'
if (-not (Test-Path -LiteralPath $doctor)) { throw "doctor script not found: $doctor" }

$script:Passed = 0
$script:Failed = 0
$script:Sandboxes = @()

function Assert-Contains {
    param([string] $Text, [string] $Needle, [string] $Label)
    if ($Text -like "*$Needle*") {
        Write-Host ("  PASS  $Label") -ForegroundColor Green
        $script:Passed++
    } else {
        Write-Host ("  FAIL  $Label") -ForegroundColor Red
        Write-Host ("        expected to find: $Needle") -ForegroundColor DarkGray
        Write-Host ("        ---- output ----") -ForegroundColor DarkGray
        $Text -split "`n" | Select-Object -First 40 | ForEach-Object { Write-Host "        $_" -ForegroundColor DarkGray }
        $script:Failed++
    }
}

function New-Sandbox {
    $sb = Join-Path $env:TEMP ('ddd-test-' + [guid]::NewGuid().ToString('N'))
    foreach ($d in @('', '\local\Docker\log\host', '\local\Docker\wsl\disk', '\roaming\Docker', '\profile\.docker')) {
        New-Item -ItemType Directory -Path ($sb + $d) -Force | Out-Null
    }
    $script:Sandboxes += $sb
    return $sb
}

function Get-SandboxRunner {
    param([string] $Sandbox)
    $wrapper = Join-Path $Sandbox 'run-doctor.ps1'
    $content = @"
`$env:USERPROFILE  = '$Sandbox\profile'
`$env:APPDATA      = '$Sandbox\roaming'
`$env:LOCALAPPDATA = '$Sandbox\local'
& '$doctor'
"@
    Set-Content -LiteralPath $wrapper -Value $content -Encoding ASCII
    return $wrapper
}

function Invoke-Doctor {
    param([string] $Sandbox)
    $wrapper = Get-SandboxRunner -Sandbox $Sandbox
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $wrapper 2>&1 | Out-String
    return $out
}

function New-ZeroFile {
    param([string] $Path, [int] $Bytes = 28)
    $buf = New-Object byte[] $Bytes
    [System.IO.File]::WriteAllBytes($Path, $buf)
}

function New-SizedFile {
    param([string] $Path, [long] $Bytes)
    $fs = [System.IO.File]::Create($Path)
    $fs.SetLength($Bytes)
    $fs.Dispose()
}

Write-Host ''
Write-Host '  docker-desktop-doctor :: tests' -ForegroundColor White
Write-Host ("  doctor: {0}" -f $doctor) -ForegroundColor DarkGray

# --- T1: zeroed windows-daemon.json is detected -----------------------------
Write-Host ''
Write-Host '  T1  zeroed windows-daemon.json (the crash-loop trigger)' -ForegroundColor Cyan
$sb = New-Sandbox
New-ZeroFile -Path (Join-Path $sb 'profile\.docker\windows-daemon.json') -Bytes 28
$out = Invoke-Doctor -Sandbox $sb
Assert-Contains $out 'is ZEROED (all NUL bytes)' 'flags the file as zeroed'
Assert-Contains $out '1 critical' 'raises a critical finding'
Assert-Contains $out 'No change was made' 'stays read-only without -Fix'

# --- T2: an empty config file is also unusable ------------------------------
Write-Host ''
Write-Host '  T2  empty (0-byte) windows-daemon.json' -ForegroundColor Cyan
$sb = New-Sandbox
New-Item -ItemType File -Path (Join-Path $sb 'profile\.docker\windows-daemon.json') -Force | Out-Null
$out = Invoke-Doctor -Sandbox $sb
Assert-Contains $out 'is empty' 'flags the empty file'

# --- T3: malformed (non-NUL) JSON is detected too ---------------------------
Write-Host ''
Write-Host '  T3  truncated JSON config' -ForegroundColor Cyan
$sb = New-Sandbox
Set-Content -LiteralPath (Join-Path $sb 'profile\.docker\daemon.json') -Value '{"builder": {"gc":' -Encoding ASCII
$out = Invoke-Doctor -Sandbox $sb
Assert-Contains $out 'is not valid JSON' 'flags malformed JSON'

# --- T4: a valid config parses and reports OK -------------------------------
Write-Host ''
Write-Host '  T4  valid configs' -ForegroundColor Cyan
$sb = New-Sandbox
Set-Content -LiteralPath (Join-Path $sb 'profile\.docker\windows-daemon.json') -Value '{"experimental": false}' -Encoding ASCII
Set-Content -LiteralPath (Join-Path $sb 'profile\.docker\daemon.json') -Value '{"experimental": false}' -Encoding ASCII
$out = Invoke-Doctor -Sandbox $sb
Assert-Contains $out 'Windows engine daemon config parses' 'valid windows config parses'
Assert-Contains $out 'Linux engine daemon config parses' 'valid linux config parses'

# --- T5: oversized crash dump ------------------------------------------------
Write-Host ''
Write-Host '  T5  oversized backend.error.json (120 MB)' -ForegroundColor Cyan
$sb = New-Sandbox
New-SizedFile -Path (Join-Path $sb 'local\Docker\backend.error.json') -Bytes 120MB
$out = Invoke-Doctor -Sandbox $sb
Assert-Contains $out 'backend.error.json is huge' 'flags the multi-GB dump'
Assert-Contains $out 'Delete it: -Fix' 'suggests the repair'

# --- T6: a small crash dump is only a warning -------------------------------
Write-Host ''
Write-Host '  T6  small backend.error.json (6 MB)' -ForegroundColor Cyan
$sb = New-Sandbox
New-SizedFile -Path (Join-Path $sb 'local\Docker\backend.error.json') -Bytes 6MB
$out = Invoke-Doctor -Sandbox $sb
Assert-Contains $out 'backend.error.json is large' 'warns instead of screaming'

# --- T7: factory-reset settings are spotted ---------------------------------
Write-Host ''
Write-Host '  T7  factory-reset settings-store.json (6 keys)' -ForegroundColor Cyan
$sb = New-Sandbox
Set-Content -LiteralPath (Join-Path $sb 'roaming\Docker\settings-store.json') `
    -Value '{"AutoStart": false, "DisplayedOnboarding": true, "EnableDockerAI": true, "InferenceCanUseGPUVariant": true, "LicenseTermsVersion": 2, "SettingsVersion": 45}' -Encoding ASCII
$out = Invoke-Doctor -Sandbox $sb
Assert-Contains $out 'Settings look factory-reset' 'detects a reset profile'

# --- T8: a junction is detected and shown -----------------------------------
Write-Host ''
Write-Host '  T8  junctioned data folder' -ForegroundColor Cyan
$sb = New-Sandbox
$junctionTarget = Join-Path $sb 'target-disk'
New-Item -ItemType Directory -Path $junctionTarget -Force | Out-Null
New-SizedFile -Path (Join-Path $junctionTarget 'docker_data.vhdx') -Bytes 1MB
$diskDir = Join-Path $sb 'local\Docker\wsl\disk'
Remove-Item -LiteralPath $diskDir -Recurse -Force -ErrorAction SilentlyContinue
$mk = 'mklink /J "{0}" "{1}"' -f $diskDir, $junctionTarget
cmd.exe /c $mk | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host '  SKIP  junction creation failed (not supported here)' -ForegroundColor Yellow
} else {
    $out = Invoke-Doctor -Sandbox $sb
    Assert-Contains $out 'Data folder is already redirected' 'reports the redirection'
    Assert-Contains $out 'junction ->' 'prints the target'
}

# --- T9: a healthy sandbox is quiet -----------------------------------------
Write-Host ''
Write-Host '  T9  healthy sandbox' -ForegroundColor Cyan
$sb = New-Sandbox
Set-Content -LiteralPath (Join-Path $sb 'profile\.docker\daemon.json') -Value '{"experimental": false}' -Encoding ASCII
$out = Invoke-Doctor -Sandbox $sb
Assert-Contains $out '0 critical' 'no critical finding on a clean tree'

# --- T10: report-only is the default ----------------------------------------
Write-Host ''
Write-Host '  T10 report-only mode is the default' -ForegroundColor Cyan
$sb = New-Sandbox
New-ZeroFile -Path (Join-Path $sb 'profile\.docker\windows-daemon.json') -Bytes 28
$out = Invoke-Doctor -Sandbox $sb
Assert-Contains $out 'mode: report-only' 'announces report-only'
if (Test-Path -LiteralPath (Join-Path $sb 'profile\.docker\windows-daemon.json')) {
    Write-Host '  PASS  the zeroed file was left untouched' -ForegroundColor Green
    $script:Passed++
} else {
    Write-Host '  FAIL  the zeroed file was modified without -Fix' -ForegroundColor Red
    $script:Failed++
}

# --- cleanup ----------------------------------------------------------------
foreach ($sb in $script:Sandboxes) {
    Remove-Item -LiteralPath $sb -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ("  {0} passed, {1} failed" -f $script:Passed, $script:Failed) $(if ($script:Failed) { 'Red' } else { 'Green' })
Write-Host ''
if ($script:Failed -gt 0) { exit 1 }
exit 0
