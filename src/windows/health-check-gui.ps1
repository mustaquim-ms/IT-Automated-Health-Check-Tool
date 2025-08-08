Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$form = New-Object System.Windows.Forms.Form
$form.Text = "IT Health Check GUI"
$form.Size = New-Object System.Drawing.Size(400,300)
$form.StartPosition = "CenterScreen"

$label = New-Object System.Windows.Forms.Label
$label.Text = "Enter Hostname(s) (comma-separated):"
$label.AutoSize = $true
$label.Location = New-Object System.Drawing.Point(10,20)
$form.Controls.Add($label)

$textBox = New-Object System.Windows.Forms.TextBox
$textBox.Size = New-Object System.Drawing.Size(250,20)
$textBox.Location = New-Object System.Drawing.Point(10,50)
$form.Controls.Add($textBox)

$runButton = New-Object System.Windows.Forms.Button
$runButton.Text = "Run Health Check"
$runButton.Location = New-Object System.Drawing.Point(10,90)
$form.Controls.Add($runButton)

$outputBox = New-Object System.Windows.Forms.TextBox
$outputBox.Multiline = $true
$outputBox.ScrollBars = "Vertical"
$outputBox.Size = New-Object System.Drawing.Size(350,100)
$outputBox.Location = New-Object System.Drawing.Point(10,130)
$form.Controls.Add($outputBox)

function Run-HealthCheck {
    param($Hosts)
    $results = @()

    foreach ($host in $Hosts) {
        $cpu = Get-Counter "\Processor(_Total)\% Processor Time" -SampleInterval 1 -MaxSamples 1 |
               Select-Object -ExpandProperty CounterSamples |
               Select-Object -ExpandProperty CookedValue
        $mem = (Get-WmiObject Win32_OperatingSystem).FreePhysicalMemory / 1MB
        $disk = (Get-PSDrive C).Free / 1GB

        $status = "Healthy"
        if ($cpu -gt 80) { $status = "Critical" }
        elseif ($cpu -gt 60) { $status = "Warning" }

        $results += [PSCustomObject]@{
            Hostname = $host
            CPU = [math]::Round($cpu, 2)
            MemoryGB = [math]::Round($mem, 2)
            DiskGB = [math]::Round($disk, 2)
            Status = $status
            Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
        }
    }

    $json = $results | ConvertTo-Json -Depth 3
    $fileName = "$env:USERPROFILE\health_report_$((Get-Date).ToString('yyyyMMdd_HHmmss')).json"
    $json | Out-File -FilePath $fileName -Encoding utf8
    Invoke-RestMethod -Uri "http://127.0.0.1:5000/upload" -Method Post -InFile $fileName -ContentType "application/json"

    return $results
}

$runButton.Add_Click({
    $hosts = $textBox.Text.Split(",") | ForEach-Object { $_.Trim() }
    $output = Run-HealthCheck -Hosts $hosts | Out-String
    $outputBox.Text = $output
})

$form.ShowDialog()
# Ensure the form is closed properly when the script ends