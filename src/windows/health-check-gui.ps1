Add-Type -AssemblyName PresentationFramework

$scriptPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'health-check.ps1'
$agg = "http://127.0.0.1:5000/upload"

# Build simple WPF window
[xml]$xaml = @"
<Window xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Title='IT Health GUI' Height='420' Width='700'>
  <Grid Margin='10'>
    <Grid.RowDefinitions>
      <RowDefinition Height='Auto'/>
      <RowDefinition Height='*'/>
      <RowDefinition Height='Auto'/>
    </Grid.RowDefinitions>

    <StackPanel Orientation='Horizontal' Grid.Row='0' Margin='0,0,0,8'>
      <Button Name='RunBtn' Width='160' Margin='0,0,8,0'>Run Elevated Health Check</Button>
      <Button Name='OpenReports' Width='160'>Open Reports Folder</Button>
      <Label VerticalAlignment='Center' Margin='12,0,0,0'>Aggregator:</Label>
      <TextBox Name='AggUrl' Width='300' Margin='8,0,0,0'/>
    </StackPanel>

    <TextBox Name='OutputBox' Grid.Row='1' TextWrapping='Wrap' VerticalScrollBarVisibility='Auto' AcceptsReturn='True' IsReadOnly='True'/>

    <StackPanel Orientation='Horizontal' Grid.Row='2' HorizontalAlignment='Right' Margin='0,8,0,0'>
      <Button Name='CloseBtn' Width='100'>Close</Button>
    </StackPanel>
  </Grid>
</Window>
"@

$reader = (New-Object System.Xml.XmlNodeReader $xaml)
$win = [Windows.Markup.XamlReader]::Load($reader)

$RunBtn = $win.FindName("RunBtn")
$OpenReports = $win.FindName("OpenReports")
$AggUrl = $win.FindName("AggUrl")
$OutputBox = $win.FindName("OutputBox")
$CloseBtn = $win.FindName("CloseBtn")

$AggUrl.Text = "http://127.0.0.1:5000/upload"

function Append($s){ $OutputBox.AppendText((Get-Date).ToString('s') + " - " + $s + "`r`n"); $OutputBox.ScrollToEnd() }

$RunBtn.Add_Click({
  Append "Starting health-check (this will attempt to run elevated)."
  try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "powershell.exe"
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -AggregatorUrl `"$($AggUrl.Text)`""
    $psi.Verb = "runas"  # request elevation
    [System.Diagnostics.Process]::Start($psi) | Out-Null
    Append "Health-check launched (elevated). Check logs in aggregator/uploads/ for JSON."
  } catch {
    Append "Failed to launch elevated: $_"
  }
})

$OpenReports.Add_Click({
  $reports = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..\aggregator\uploads' | Resolve-Path -ErrorAction SilentlyContinue
  if (-not $reports) { New-Item -ItemType Directory -Path (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..\aggregator\uploads') | Out-Null; $reports = (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..\aggregator\uploads') }
  Start-Process "explorer.exe" -ArgumentList $reports
})

$CloseBtn.Add_Click({ $win.Close() })

$win.ShowDialog() | Out-Null
