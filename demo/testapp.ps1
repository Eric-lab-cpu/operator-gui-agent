<#
    testapp.ps1 —— 自检用的小窗口（只是为了让 cu.ps1 有个可控的目标，不碰用户任何程序）
#>
$dpi = Add-Type -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);' -Name Dpi -Namespace CuDemo -PassThru
[void]$dpi::SetProcessDpiAwarenessContext([IntPtr](-4))

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

[void][System.Windows.Forms.Application]::EnableVisualStyles()

$script:hits = 0

$form = New-Object System.Windows.Forms.Form
$form.Text = 'CU 自检窗口'
$form.ClientSize = New-Object System.Drawing.Size(520, 300)
$form.StartPosition = 'CenterScreen'
$form.TopMost = $true
$form.BackColor = [System.Drawing.Color]::FromArgb(24, 26, 32)
$form.ForeColor = [System.Drawing.Color]::White
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10)

$lbl = New-Object System.Windows.Forms.Label
$lbl.Name = 'lblStatus'
$lbl.AccessibleName = '状态'
$lbl.Text = '未点击'
$lbl.AutoSize = $true
$lbl.Location = New-Object System.Drawing.Point(30, 24)
$lbl.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 15, [System.Drawing.FontStyle]::Bold)
$lbl.ForeColor = [System.Drawing.Color]::FromArgb(120, 220, 180)
$form.Controls.Add($lbl)

$txt = New-Object System.Windows.Forms.TextBox
$txt.Name = 'txtInput'
$txt.AccessibleName = '输入框'
$txt.Location = New-Object System.Drawing.Point(30, 80)
$txt.Size = New-Object System.Drawing.Size(440, 32)
$txt.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 12)
$form.Controls.Add($txt)

$btnGo = New-Object System.Windows.Forms.Button
$btnGo.Name = 'btnGo'
$btnGo.Text = '点我'
$btnGo.Location = New-Object System.Drawing.Point(30, 140)
$btnGo.Size = New-Object System.Drawing.Size(140, 44)
$btnGo.Add_Click({
    $script:hits++
    $lbl.Text = "已点击 $($script:hits) 次"
})

$btnRead = New-Object System.Windows.Forms.Button
$btnRead.Name = 'btnRead'
$btnRead.Text = '读取输入'
$btnRead.Location = New-Object System.Drawing.Point(190, 140)
$btnRead.Size = New-Object System.Drawing.Size(140, 44)
$btnRead.Add_Click({
    $lbl.Text = "输入内容是：$($txt.Text)"
})

$form.Controls.Add($btnGo)
$form.Controls.Add($btnRead)

[void]$form.Show()
[void]$form.Activate()
[System.Windows.Forms.Application]::Run($form)
