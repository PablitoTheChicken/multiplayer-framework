# Drives the cross-process integration test: launches a host and a client,
# waits for both to finish, and reports their assertions.
#
#   pwsh tests/run_tests.ps1
#   pwsh tests/run_tests.ps1 -Godot "C:\path\to\Godot.exe"

param(
    [string]$Godot = "C:\Users\Joram\Desktop\Godot 4.7.1.exe",
    [int]$TimeoutSeconds = 45
)

$ErrorActionPreference = "Stop"
$project = Split-Path -Parent $PSScriptRoot
$logs = Join-Path $env:TEMP "mpf-tests"
New-Item -ItemType Directory -Force $logs | Out-Null
Remove-Item "$logs\*.log" -ErrorAction SilentlyContinue

if (-not (Test-Path $Godot)) {
    Write-Host "Godot not found at $Godot - pass -Godot <path>" -ForegroundColor Red
    exit 2
}

# A server left over from an earlier run holds the port and makes the whole
# suite lie, so clear any strays first.
Get-CimInstance Win32_Process -Filter "Name like '%Godot%'" |
    Where-Object { $_.CommandLine -like '*--test=*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

function Start-Instance($role) {
    $p = Start-Process -FilePath $Godot -PassThru -ArgumentList @(
        "--headless", "--path", "`"$project`"",
        "res://tests/integration.tscn", "--", "--test=$role"
    ) -RedirectStandardOutput "$logs\$role.log" -RedirectStandardError "$logs\$role.err"
    # Touching Handle caches it; without this ExitCode is unreadable after the
    # process ends, because Start-Process does not retain the handle itself.
    $null = $p.Handle
    return $p
}

Write-Host "Running MPF integration tests..." -ForegroundColor Cyan
$host_proc = Start-Instance "host"
Start-Sleep -Seconds 3
$client_proc = Start-Instance "client"

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
while ((Get-Date) -lt $deadline) {
    if ($host_proc.HasExited -and $client_proc.HasExited) { break }
    Start-Sleep -Milliseconds 500
}

$timedOut = @()
foreach ($entry in @(@{n="client";p=$client_proc}, @{n="host";p=$host_proc})) {
    if (-not $entry.p.HasExited) {
        $timedOut += $entry.n
        Stop-Process -Id $entry.p.Id -Force -ErrorAction SilentlyContinue
    }
    # ExitCode stays null on a PassThru object until the handle is waited on,
    # even when the process has already finished.
    try { $entry.p.WaitForExit(5000) | Out-Null } catch {}
}
Start-Sleep -Seconds 1

# The printed summary is authoritative: it is the only signal that survives a
# process being killed, and it says which assertion failed rather than just that
# something did.
$failed = $false
foreach ($role in @("host", "client")) {
    Write-Host "`n--- $role ---" -ForegroundColor Yellow
    $lines = Get-Content "$logs\$role.log" -ErrorAction SilentlyContinue | Select-String "\[TEST\]"
    if (-not $lines) { Write-Host "  no test output" -ForegroundColor Red; $failed = $true }
    foreach ($line in $lines) {
        $text = $line.ToString()
        $colour = if ($text -match "FAIL") { "Red" } else { "Green" }
        Write-Host "  $text" -ForegroundColor $colour
    }
    if (-not ($lines | Where-Object { $_ -match "PASSED role=$role" })) { $failed = $true }
    $errs = Get-Content "$logs\$role.err" -ErrorAction SilentlyContinue
    if ($errs) { Write-Host "  stderr:" -ForegroundColor Red; $errs | ForEach-Object { Write-Host "    $_" } }
}

$hostCode = if ($host_proc.HasExited) { $host_proc.ExitCode } else { "killed" }
$clientCode = if ($client_proc.HasExited) { $client_proc.ExitCode } else { "killed" }
if ($timedOut.Count -gt 0) {
    Write-Host "`ntimed out: $($timedOut -join ', ')" -ForegroundColor Red
    $failed = $true
}

Write-Host ""
if ($failed) {
    Write-Host "INTEGRATION TESTS FAILED (host=$hostCode client=$clientCode)" -ForegroundColor Red
    exit 1
}
Write-Host "INTEGRATION TESTS PASSED" -ForegroundColor Green
exit 0
