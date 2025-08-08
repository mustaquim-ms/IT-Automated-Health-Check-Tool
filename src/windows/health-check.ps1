<#
Run as Administrator.
Collects CPU, memory, disks, processes, services, pending updates, event snippets,
computes a simple health score & remediation hints, writes JSON and posts to aggregator.
#>

param(
  [string]$AggregatorUrl = "http://127.0.0.1:5000/upload",
  [string]$OutDir = "$PSScriptRoot\..\..\aggregator\uploads"
)

# ensure outdir
$OutDir = (Resolve-Path $OutDir -ErrorAction SilentlyContinue).Path
if (-not $OutDir) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null; $OutDir = (Resolve-Path $OutDir).Path }

Function Write-Log([string]$m){ $t=(Get-Date).ToString('s'); "$t $m" | Out-File -FilePath (Join-Path $OutDir 'run.log') -Append -Encoding utf8 }

# Basic host info
$host = $env:COMPUTERNAME
$os = (Get-CimInstance Win32_OperatingSystem).Caption
$ip = (Get-NetIPAddress -AddressFamily IPv4 -PrefixOrigin Dhcp -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -and $_.IPAddress -ne '127.0.0.1' } | Select-Object -First 1 -ExpandProperty IPAddress) -or "N/A"
$timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")

# CPU (average over 3 samples)
try {
  $cpus = Get-Counter '\Processor(_Total)\% Processor Time' -SampleInterval 0.5 -MaxSamples 3
  $cpuVal = [math]::Round(($cpus.CounterSamples | Measure-Object -Property CookedValue -Average).Average,2)
} catch { $cpuVal = $null; Write-Log "CPU collection failed: $_" }

# Memory
try {
  $osobj = Get-CimInstance Win32_OperatingSystem
  $totalMB = [math]::Round($osobj.TotalVisibleMemorySize/1024,2)
  $freeMB = [math]::Round($osobj.FreePhysicalMemory/1024,2)
  $usedMB = [math]::Round($totalMB - $freeMB,2)
  $memPercentUsed = if($totalMB -ne 0){ [math]::Round(($usedMB/$totalMB*100),2) } else { 0 }
} catch { $totalMB=$freeMB=$usedMB=$memPercentUsed=$null; Write-Log "Memory collection failed: $_" }

# Disks (fixed drives)
$disks = @()
try {
  Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3" | ForEach-Object {
    $totalGB = if ($_.Size) { [math]::Round($_.Size/1GB,2) } else { 0 }
    $freeGB  = if ($_.FreeSpace) { [math]::Round($_.FreeSpace/1GB,2) } else { 0 }
    $usedGB  = [math]::Round($totalGB - $freeGB,2)
    $pct     = if($totalGB -ne 0){ [math]::Round(($usedGB/$totalGB*100),2) } else { 0 }
    $disks += @{
      mount = $_.DeviceID; total_gb = $totalGB; free_gb = $freeGB; used_gb = $usedGB; percent = $pct
    }
  }
} catch { Write-Log "Disk collection failed: $_" }

# Top processes (by CPU and Memory)
$topCPU = (Get-Process | Sort-Object CPU -Descending | Select-Object -First 8 |
           Select-Object @{n='Name';e={$_.ProcessName}}, @{n='CPU';e={[math]::Round($_.CPU,2)}}, @{n='Id';e={$_.Id}})
$topMem = (Get-Process | Sort-Object WorkingSet -Descending | Select-Object -First 8 |
           Select-Object @{n='Name';e={$_.ProcessName}}, @{n='MemMB';e={[math]::Round($_.WorkingSet/1MB,2)}}, @{n='Id';e={$_.Id}})

# Services count
try { $svcRunning = (Get-Service | Where-Object {$_.Status -eq 'Running'}).Count } catch { $svcRunning = $null }

# Pending updates (if PSWindowsUpdate available)
$updates = @()
try {
  if (Get-Module -ListAvailable -Name PSWindowsUpdate) {
    Import-Module PSWindowsUpdate -ErrorAction SilentlyContinue
    $wu = Get-WUList -ErrorAction SilentlyContinue
    foreach ($u in $wu) { $updates += @{ title = $u.Title; severity = ($u.MsrcSeverity -join ',') } }
  } else {
    # note: PSWindowsUpdate not installed - can't enumerate updates precisely
    $updates += @{ title = "PSWindowsUpdate module not installed"; severity = "info"; note = "Install PSWindowsUpdate for details" }
  }
} catch { Write-Log "Update check failed: $_"; $updates += @{ title = "Update check error"; severity = "error"; note = $_ } }

# Recent important events (last 100 filtered)
$logSnippet = ""
try {
  $events = Get-WinEvent -LogName System -MaxEvents 80 -ErrorAction SilentlyContinue |
            Where-Object { $_.LevelDisplayName -in @('Error','Warning') } |
            Select-Object TimeCreated, LevelDisplayName, ProviderName, Id, @{n='Msg';e={$_.Message}}
  $logSnippet = ($events | ForEach-Object { "$($_.TimeCreated.ToString('s')) [$($_.LevelDisplayName)] $($_.ProviderName) ($($_.Id)) - $($_.Msg)" }) -join "`n"
} catch { Write-Log "Event log extraction failed: $_"; $logSnippet = "Log extraction failed" }

# Vulnerability heuristics (simple)
$vulns = @()
try {
  $java = Get-Command java -ErrorAction SilentlyContinue
  if ($java) { $vulns += @{ name='Java runtime present'; severity='warn'; note='Check Java version & patch' } }
} catch {}

# Simple scoring rules
$score = 100
if ($cpuVal -ne $null -and $cpuVal -gt 85) { $score -= 30 }
elseif ($cpuVal -ne $null -and $cpuVal -gt 65) { $score -= 10 }

if ($memPercentUsed -ne $null -and $memPercentUsed -gt 90) { $score -= 25 }
if ($disks | Where-Object { $_.percent -ge 90 }) { $score -= 25 }
if ($updates.Count -gt 0 -and ($updates -ne $null)) { $score -= 5 }

# Create remediation hints
$remediations = @()
if ($cpuVal -gt 85) { $remediations += @{ title='High CPU', action='Check top processes, consider restarting service or moving workload.' } }
if ($memPercentUsed -gt 90) { $remediations += @{ title='Low available memory', action='Investigate memory-heavy processes, consider restart or add RAM.' } }
foreach ($d in $disks) { if ($d.percent -ge 90) { $remediations += @{ title="Disk $($d.mount) nearly full", action="Clean temp, rotate logs, remove old backups or extend volume." } } }

# Build JSON object
$report = @{
  host = $host
  ip = $ip
  os = $os
  timestamp = $timestamp
  cpu = @{ percent = $cpuVal }
  memory = @{ total_mb = $totalMB; free_mb = $freeMB; used_mb = $usedMB; used_percent = $memPercentUsed }
  disks = $disks
  top_cpu_processes = $topCPU
  top_mem_processes = $topMem
  services = @{ running = $svcRunning }
  updates = $updates
  logs = $logSnippet
  vulnerabilities = $vulns
  remediations = $remediations
  score = $score
}

# write locally
$jsonfile = Join-Path $OutDir ("report_{0}_{1}.json" -f $host, (Get-Date -Format "yyyyMMdd_HHmmss"))
$report | ConvertTo-Json -Depth 6 | Out-File -FilePath $jsonfile -Encoding utf8
Write-Log "Report written to $jsonfile"

# POST to aggregator (best effort)
try {
  $body = Get-Content -Raw -Path $jsonfile
  Invoke-RestMethod -Uri $AggregatorUrl -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 30
  Write-Log "Posted report to $AggregatorUrl"
} catch {
  Write-Log "Failed to post to aggregator: $_"
}

# Output to console
$report | ConvertTo-Json -Depth 6
exit 0
