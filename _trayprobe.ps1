Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$ni = New-Object System.Windows.Forms.NotifyIcon
$ni.Icon = [System.Drawing.SystemIcons]::Application
$ni.Text = "OperatorProbe"
$ni.Visible = $true
$ni.ShowBalloonTip(1000, "probe", "tray probe", [System.Windows.Forms.ToolTipIcon]::Info)
$end = (Get-Date).AddSeconds(9)
while ((Get-Date) -lt $end) { [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 }
$ni.Visible = $false
$ni.Dispose()