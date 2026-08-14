# Runs the whole MPF suite: single-process unit tests, then each cross-process
# integration scenario as a real host/client pair over a socket.
#
#   pwsh tests/run_tests.ps1
#   pwsh tests/run_tests.ps1 -Godot "C:\path\to\Godot.exe"
#   pwsh tests/run_tests.ps1 -Only rejection

param(
    [string]$Godot = "C:\Users\Joram\Desktop\Godot 4.7.1.exe",
    [int]$TimeoutSeconds = 45,
    [string]$Only = ""
)

$ErrorActionPreference = "Stop"
$project = Split-Path -Parent $PSScriptRoot
$logs = Join-Path $env:TEMP "mpf-tests"
New-Item -ItemType Directory -Force $logs | Out-Null
Remove-Item "$logs\*.log", "$logs\*.err" -ErrorAction SilentlyContinue

if (-not (Test-Path $Godot)) {
    Write-Host "Godot not found at $Godot - pass -Godot <path>" -ForegroundColor Red
    exit 2
}

$scenarios = @("core", "late_join", "rejection")
if ($Only) { $scenarios = @($Only) }
$failed = $false

function Stop-Strays {
    Get-CimInstance Win32_Process -Filter "Name like '%Godot%'" |
        Where-Object { $_.CommandLine -like '*--test=*' } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

function Start-Instance($role, $scenario, $tag) {
    $p = Start-Process -FilePath $Godot -PassThru -ArgumentList @(
        "--headless", "--path", "`"$project`"",
        "res://tests/integration.tscn", "--", "--test=$role", "--scenario=$scenario"
    ) -RedirectStandardOutput "$logs\$tag-$role.log" -RedirectStandardError "$logs\$tag-$role.err"
    # Touching Handle caches it; ExitCode is otherwise unreadable afterwards.
    $null = $p.Handle
    return $p
}

# --- unit tests -------------------------------------------------------------

Write-Host "`n=== unit tests ===" -ForegroundColor Cyan
$unit = Start-Process -FilePath $Godot -PassThru -Wait -ArgumentList @(
    "--headless", "--path", "`"$project`"", "--script", "res://tests/unit_tests.gd"
) -RedirectStandardOutput "$logs\unit.log" -RedirectStandardError "$logs\unit.err"
$null = $unit.Handle
$unitLines = Get-Content "$logs\unit.log" -ErrorAction SilentlyContinue | Select-String "\[UNIT\]|FAIL"
foreach ($line in $unitLines) {
    $text = $line.ToString()
    $colour = if ($text -match "FAIL") { "Red" } else { "Gray" }
    Write-Host "  $text" -ForegroundColor $colour
}
if (-not ($unitLines | Where-Object { $_ -match "\[UNIT\] PASSED" })) { $failed = $true }

# --- integration scenarios --------------------------------------------------

foreach ($scenario in $scenarios) {
    Write-Host "`n=== integration: $scenario ===" -ForegroundColor Cyan
    Stop-Strays
    Start-Sleep -Seconds 1

    $hostProc = Start-Instance "host" $scenario $scenario
    # The late_join scenario deliberately connects after the world has changed.
    $delay = if ($scenario -eq "late_join") { 6 } else { 3 }
    Start-Sleep -Seconds $delay
    $clientProc = Start-Instance "client" $scenario $scenario

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        if ($hostProc.HasExited -and $clientProc.HasExited) { break }
        Start-Sleep -Milliseconds 500
    }

    foreach ($entry in @(@{n="client";p=$clientProc}, @{n="host";p=$hostProc})) {
        if (-not $entry.p.HasExited) {
            Write-Host "  timed out: $($entry.n)" -ForegroundColor Red
            $failed = $true
            Stop-Process -Id $entry.p.Id -Force -ErrorAction SilentlyContinue
        }
        try { $entry.p.WaitForExit(5000) | Out-Null } catch {}
    }
    Start-Sleep -Milliseconds 500

    foreach ($role in @("host", "client")) {
        $lines = Get-Content "$logs\$scenario-$role.log" -ErrorAction SilentlyContinue | Select-String "\[TEST\]"
        if (-not $lines) {
            Write-Host "  [$role] no test output" -ForegroundColor Red
            $failed = $true
            continue
        }
        foreach ($line in $lines) {
            $text = $line.ToString()
            $colour = if ($text -match "FAIL") { "Red" } else { "Green" }
            Write-Host "  $text" -ForegroundColor $colour
        }
        # The printed summary is authoritative: it survives a killed process and
        # names which assertion failed rather than just that something did.
        if (-not ($lines | Where-Object { $_ -match "PASSED role=$role" })) { $failed = $true }
        # Warnings on stderr are often the point of a test - the rejection
        # scenario passes precisely because the server logs a refusal. Only
        # genuine errors count against the run.
        $errs = Get-Content "$logs\$scenario-$role.err" -ErrorAction SilentlyContinue |
            Where-Object { $_ -match "SCRIPT ERROR|^ERROR:" }
        if ($errs) {
            Write-Host "  [$role] errors:" -ForegroundColor Red
            $errs | Select-Object -First 12 | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
            $failed = $true
        }
    }
}

Stop-Strays
Write-Host ""
if ($failed) {
    Write-Host "TESTS FAILED  (logs in $logs)" -ForegroundColor Red
    exit 1
}
Write-Host "ALL TESTS PASSED" -ForegroundColor Green
exit 0
