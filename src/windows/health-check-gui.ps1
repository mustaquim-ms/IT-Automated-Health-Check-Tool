# Requires: Windows PowerShell 5.1+ (works in PS Core on Windows but WPF needs Windows PS)
Add-Type -AssemblyName PresentationFramework

# ---- Config ----
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$HealthCheckScript = Join-Path $ScriptDir "health-check.ps1"
$ReportsDir = Join-Path $ScriptDir "..\..\reports" | Resolve-Path -ErrorAction SilentlyContinue
if (-not $ReportsDir) { $ReportsDir = Join-Path $ScriptDir "..\..\reports" }
$ReportsDir = (Resolve-Path $ReportsDir).Path
$ConfigFile = Join-Path $ScriptDir "health-check-gui.config.json"

# Default config
if (-not (Test-Path $ConfigFile)) {
    $default = @{
        aggregator_url = "http://127.0.0.1:5000/api/report"
        api_token = ""
        auto_open_html = $true
    }
    $default | ConvertTo-Json | Out-File -FilePath $ConfigFile -Encoding utf8
}
$config = Get-Content $ConfigFile -Raw | ConvertFrom-Json

# ---- Helper Functions ----
function Write-GuiLog {
    param($msg, $level='INFO')
    $ts = (Get-Date).ToString('s')
    $entry = "$ts [$level] $msg"
    $global:LogBox.AppendText("$entry`r`n")
    $global:LogBox.ScrollToEnd()
    Add-Content -Path (Join-Path $ReportsDir "gui-send.log") -Value $entry
}

function Run-HealthCheck {
    param($ForceAdmin=$false)
    if (-not (Test-Path $HealthCheckScript)) {
        Write-GuiLog "health-check.ps1 not found at $HealthCheckScript" 'ERROR'; return $null
    }
    try {
        Write-GuiLog "Starting health-check..."
        $p = Start-Process -FilePath "powershell.exe" -ArgumentList "-ExecutionPolicy Bypass -File `"$HealthCheckScript`"" -NoNewWindow -Wait -PassThru -WindowStyle Hidden
        Write-GuiLog "Health-check finished (ExitCode $($p.ExitCode))"
        # find latest JSON in reports dir
        $latest = Get-ChildItem -Path $ReportsDir -Filter "report_*.json" -Recurse | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($latest) { Write-GuiLog "Latest report: $($latest.FullName)"; return $latest.FullName } else { Write-GuiLog "No report produced." ; return $null}
    } catch {
        Write-GuiLog "Failed to run health-check: $_" 'ERROR'
        return $null
    }
}

function Open-LatestHtml {
    $latestHtml = Get-ChildItem -Path $ReportsDir -Filter "report_*.html" -Recurse | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latestHtml) {
        Write-GuiLog "Opening HTML: $($latestHtml.FullName)"
        Start-Process $latestHtml.FullName
    } else {
        Write-GuiLog "No HTML report found" 'WARN'
    }
}

function Send-ReportToAggregator {
    param([string]$JsonPath)
    if (-not (Test-Path $JsonPath)) { Write-GuiLog "JSON report not found: $JsonPath" 'ERROR'; return }
    $json = Get-Content $JsonPath -Raw
    $uri = $global:AggregatorUrlBox.Text.Trim()
    if (-not $uri) { Write-GuiLog "Aggregator URL not set" 'ERROR'; return }
    $headers = @{}
    if ($global:ApiTokenBox.Text.Trim()) { $headers['Authorization'] = "Bearer $($global:ApiTokenBox.Text.Trim())" }
    try {
        Write-GuiLog "Posting report to $uri"
        $resp = Invoke-RestMethod -Uri $uri -Method Post -Body $json -Headers $headers -ContentType 'application/json' -ErrorAction Stop
        Write-GuiLog "Server response: $($resp.message -or $resp.status -or 'OK')"
    } catch {
        Write-GuiLog "Failed to send report: $_" 'ERROR'
    }
}

# ---- Build WPF UI ----
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="IT Health Check - GUI" Height="480" Width="760" WindowStartupLocation="CenterScreen" >
  <Grid Margin="10">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <StackPanel Orientation="Horizontal" Grid.Row="0" Margin="0,0,0,8">
      <Button Name="RunBtn" Width="120" Margin="0,0,8,0">Run Health Check</Button>
      <Button Name="OpenBtn" Width="120" Margin="0,0,8,0">Open Latest HTML</Button>
      <Button Name="SendBtn" Width="140" Margin="0,0,8,0">Send Latest to Aggregator</Button>
      <Label VerticalAlignment="Center">Aggregator:</Label>
      <TextBox Name="AggregatorUrlBox" Width="300" Margin="8,0,8,0"/>
      <TextBox Name="ApiTokenBox" Width="160" Margin="0,0,8,0" PlaceholderText="API Token"/>
    </StackPanel>

    <TextBox Name="LogBox" Grid.Row="1" IsReadOnly="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto" AcceptsReturn="True"/>
    
    <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,8,0,0">
      <Label VerticalAlignment="Center" FontSize="11" Foreground="Gray">Config saved to:</Label>
      <TextBlock Name="ConfigPath" VerticalAlignment="Center" Margin="6,0,0,0"/>
    </StackPanel>
  </Grid>
</Window>
"@

# parse & create UI objects
$reader = (New-Object System.Xml.XmlNodeReader $xaml)
$Window = [Windows.Markup.XamlReader]::Load($reader)

# Find controls
$RunBtn = $Window.FindName("RunBtn")
$OpenBtn = $Window.FindName("OpenBtn")
$SendBtn = $Window.FindName("SendBtn")
$global:LogBox = $Window.FindName("LogBox")
$global:AggregatorUrlBox = $Window.FindName("AggregatorUrlBox")
$global:ApiTokenBox = $Window.FindName("ApiTokenBox")
$Window.FindName("ConfigPath").Text = $ConfigFile

# populate defaults
$global:AggregatorUrlBox.Text = $config.aggregator_url
$global:ApiTokenBox.Text = $config.api_token

# Wire events
$RunBtn.Add_Click({
    $RunBtn.IsEnabled = $false
    try {
        $jsonPath = Run-HealthCheck
        if ($jsonPath -and $global:AggregatorUrlBox.Text.Trim() -and $global:ApiTokenBox.Text.Trim()) {
            # ask user whether to send
            $choice = [System.Windows.MessageBox]::Show("Send report to aggregator now?","Send", "YesNo", "Question")
            if ($choice -eq "Yes") { Send-ReportToAggregator -JsonPath $jsonPath }
        }
        if ($config.auto_open_html -eq $true) { Open-LatestHtml }
    } finally { $RunBtn.IsEnabled = $true }
})

$OpenBtn.Add_Click({ Open-LatestHtml })

$SendBtn.Add_Click({
    $latest = Get-ChildItem -Path $ReportsDir -Filter "report_*.json" -Recurse | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latest) { Send-ReportToAggregator -JsonPath $latest.FullName } else { Write-GuiLog "No JSON report to send" 'WARN' }
})

# run
Write-GuiLog "GUI started"
$Window.ShowDialog() | Out-Null

# Save config on close
$config.aggregator_url = $global:AggregatorUrlBox.Text.Trim()
$config.api_token = $global:ApiTokenBox.Text.Trim()
$config | ConvertTo-Json | Out-File -FilePath $ConfigFile -Encoding utf8
Write-GuiLog "Config saved"
