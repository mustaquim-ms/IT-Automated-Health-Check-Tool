# src/windows/health-check.ps1
# IT Health Check - Windows
# This script collects system health data and generates a report in JSON and HTML formats.
# It includes checks for CPU, memory, disk usage, processes, services, pending updates, and logs.

<#
.SYNOPSIS
  IT Health Check - Windows (production-ready)
.DESCRIPTION
  Collects CPU, memory, disk, processes, services, pending updates, logs and outputs JSON + HTML report.
#>

param(
  [string]$OutputDir = "$PSScriptRoot\..\..\reports",
  [switch]$ForceElevated
)

# --- Helpers ---
Function Write-Log {
  param([string]$msg, [string]$level='INFO')
  $ts = (Get-Date).ToString('s')
  "$ts [$level] $msg" | Tee-Object -FilePath "$OutputDir\healthcheck.log" -Append
}

# Ensure output directory
$OutputDir = (Resolve-Path $OutputDir).Path
if (!(Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir | Out-Null }

# Elevation check
If (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
  Write-Host "Warning: Not running as Administrator. Some checks will be limited." -ForegroundColor Yellow
  Write-Log "Script started without elevation" "WARN"
} else {
  Write-Log "Script started with elevation" "INFO"
}

# Collect host + basic
$hostName = $env:COMPUTERNAME
$ip = (Get-NetIPAddress -AddressFamily IPv4 -PrefixOrigin Dhcp -ErrorAction SilentlyContinue | Where-Object {$_.IPAddress -and ($_.IPAddress -ne '127.0.0.1')} | Select-Object -First 1 -ExpandProperty IPAddress) -or 'N/A'
$os = (Get-CimInstance -ClassName Win32_OperatingSystem | Select-Object -ExpandProperty Caption) -replace '\s+',' '

# CPU
try {
  $cpuLoad = Get-CimInstance -ClassName Win32_Processor | Measure-Object -Property LoadPercentage -Average | Select -ExpandProperty Average
  $cpuPercent = [math]::Round($cpuLoad,0)
  Write-Log "CPU load collected: $cpuPercent"
} catch {
  $cpuPercent = $null; Write-Log "CPU collection failed: $_" "ERROR"
}

# Memory
try {
  $osInfo = Get-CimInstance -ClassName Win32_OperatingSystem
  $freeMB = [math]::Round($osInfo.FreePhysicalMemory/1024,2)
  $totalMB = [math]::Round($osInfo.TotalVisibleMemorySize/1024,2)
  $usedMB = [math]::Round($totalMB - $freeMB,2)
  $mem = @{
    free_mb = $freeMB; total_mb = $totalMB; used_mb = $usedMB; free_human="$freeMB MB"; total_human="$totalMB MB"
    free_gb = [math]::Round($freeMB/1024,2); used_gb=[math]::Round($usedMB/1024,2)
  }
  Write-Log "Memory collected: $($mem.free_mb)MB free"
} catch {
  $mem = @{}; Write-Log "Memory collection failed: $_" "ERROR"
}

# Disks
$disks = @()
try {
  Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
    $freeGB = [math]::Round($_.FreeSpace/1GB,2)
    $totalGB = [math]::Round($_.Size/1GB,2)
    $usedGB = [math]::Round($totalGB - $freeGB,2)
    $percent = if($totalGB -ne 0){ [math]::Round(($usedGB/$totalGB*100),2) } else { 0 }
    $disks += @{
      mount = $_.DeviceID; free_gb = $freeGB; used_gb=$usedGB; total_gb=$totalGB; percent=$percent;
      free_human = "$freeGB GB"; used_human="$usedGB GB"
    }
  }
  Write-Log "Disk info collected"
} catch { Write-Log "Disk collection failed: $_" "ERROR" }

# Processes & Services
try {
  $procCount = (Get-Process | Measure-Object).Count
  $svcs = Get-Service | Where-Object {$_.Status -eq 'Running'}
  $svcCount = $svcs.Count
  Write-Log "Processes: $procCount, Running services: $svcCount"
} catch { $procCount=0; $svcCount=0; Write-Log "Process/service collection failed: $_" "ERROR" }

# Pending updates & vulnerabilities
$updates = @()
try {
  # Check for PSWindowsUpdate module
  if (Get-Module -ListAvailable -Name PSWindowsUpdate) {
    Import-Module PSWindowsUpdate -ErrorAction Stop
    $upg = Get-WUList -ErrorAction SilentlyContinue
    foreach ($u in $upg) {
      $updates += @{ name = $u.Title; severity='warn'; note = $u.MsrcSeverity -join ',' }
    }
    Write-Log "Windows updates enumerated via PSWindowsUpdate"
  } else {
    # Fallback using Windows Update API via COM (limited)
    Write-Log "PSWindowsUpdate not found — skipping detailed update list" "WARN"
    $updates += @{ name='Windows Updates: Module PSWindowsUpdate not installed'; severity='warn'; note='Install PSWindowsUpdate for detailed inventory' }
  }
} catch { Write-Log "Update check failed: $_" "ERROR"; $updates += @{ name='Update check failed'; severity='crit'; note=$_ } }

# Recent logs (from System and Application - last 200 lines combined)
$logOutput = ""
try {
  $sys = Get-WinEvent -LogName System -MaxEvents 120 -ErrorAction SilentlyContinue | Select-Object TimeCreated, LevelDisplayName, ProviderName, Id, Message
  $app = Get-WinEvent -LogName Application -MaxEvents 80 -ErrorAction SilentlyContinue | Select-Object TimeCreated, LevelDisplayName, ProviderName, Id, Message
  $combined = $sys + $app | Sort-Object TimeCreated -Descending | Select-Object -First 200
  foreach ($e in $combined) {
    $logOutput += ($e.TimeCreated.ToString('s') + " [" + $e.LevelDisplayName + "] " + $e.ProviderName + " (" + $e.Id + ") " + ($e.Message -replace "`r`n",' ') + "`n")
  }
  Write-Log "Event logs extracted"
} catch { $logOutput = "Could not extract event logs: $_"; Write-Log "Log extraction failed: $_" "ERROR" }

# Basic vuln heuristics (installed critical software versions)
$vulns = @()
try {
  # Example checks: outdated .NET, Java, etc. (heuristics)
  $java = (Get-Command java -ErrorAction SilentlyContinue)
  if ($java) { $vulns += @{name='Java runtime present'; severity='warn'; note='Verify Java version & patch if pre-8u351/11.x older versions'} }
} catch { }

# Scoring simple rule
$score = 100
if ($cpuPercent -gt 85) { $score -= 20 }
if ($mem.used_mb -gt ($mem.total_mb * 0.9)) { $score -= 20 }
if ($disks | Where-Object {$_.percent -gt 90}) { $score -= 30 }
if ($updates.Count -gt 0) { $score -= 10 }

# Remediation suggestions (map checks to actions)
$remediations = @()
if ($cpuPercent -gt 85) { $remediations += @{ title='High CPU', action='Investigate runaway processes (Get-Process | Sort CPU), consider restarting offending services or scaling resources.' } }
if ($mem.used_mb -gt ($mem.total_mb * 0.9)) { $remediations += @{ title='Low Memory', action='Check memory-hungry processes, schedule restarts, or add memory/scale VM.' } }
foreach ($d in $disks) {
  if ($d.percent -gt 90) { $remediations += @{ title="Disk $($d.mount) nearly full", action="Clean temp files, investigate large files (Get-ChildItem -Path $($d.mount)\ -Recurse | Sort-Object Length -Descending | Select-Object -First 20)" } }
}
if ($updates.Count -gt 0) { $remediations += @{ title='Pending Updates', action='Review updates, test on staging, and schedule patch window. Use PSWindowsUpdate to apply: Install-WindowsUpdate -AcceptAll -AutoReboot' } }

# Aggregate data
$reportData = @{
  host = $hostName; ip = $ip; os = $os; timestamp = (Get-Date).ToString('s')
  cpu = @{ used_percent = $cpuPercent; load = $cpuPercent }
  memory = $mem
  disks = $disks
  processes = @{ total = $procCount }
  services = @{ running = $svcCount }
  updates = $updates
  vulnerabilities = $vulns
  log = $logOutput
  remediations = $remediations
  score = $score
}

# Output JSON
$jsonPath = Join-Path $OutputDir ("report_" + (Get-Date -Format 'yyyyMMdd_HHmmss') + ".json")
$reportData | ConvertTo-Json -Depth 6 | Out-File -FilePath $jsonPath -Encoding utf8
Write-Log "Report JSON saved: $jsonPath"

# Create HTML by injecting into template
$templatePath = Join-Path $PSScriptRoot "..\..\templates\report-template.html" | Resolve-Path -ErrorAction SilentlyContinue
if (Test-Path $templatePath) {
  $html = Get-Content $templatePath -Raw
  $json = Get-Content $jsonPath -Raw
  # inject as JS variable
  $injected = $html -replace '/\* INSERT_DATA_HERE \*/', "var REPORT_DATA = $json;"
  $htmlPath = Join-Path $OutputDir ("report_" + (Get-Date -Format 'yyyyMMdd_HHmmss') + ".html")
  $injected | Out-File -FilePath $htmlPath -Encoding utf8
  Write-Log "HTML report generated: $htmlPath"
  Write-Host "Report generated: $htmlPath"
} else {
  Write-Log "Template not found; HTML generation skipped" "WARN"
  Write-Host "Template not found. JSON saved at $jsonPath"
}

exit 0
