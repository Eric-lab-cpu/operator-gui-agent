<#
    selftest.ps1 —— 端到端自检：截图 → 读控件树 → 点按钮 → 输入中文 → 再截图验证
    只操作自己启动的测试窗口（CU 自检窗口），不碰用户的任何程序。
#>
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path (Split-Path -Parent $here) 'cu.ps1')

$shots = Join-Path $here 'shots'
[void](New-Item -ItemType Directory -Force -Path $shots)
Get-ChildItem $shots -Filter *.png -ErrorAction SilentlyContinue | Remove-Item -Force

$report = [ordered]@{ steps = @(); ok = $true }
$app = $null

try {
    # 1. 启动测试窗口
    $exe = Join-Path $PSHOME 'powershell.exe'
    $app = Start-Process -FilePath $exe -PassThru -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Sta',
        '-File', (Join-Path $here 'testapp.ps1')
    )
    $w = Wait-CUWindow -Title 'CU 自检窗口' -TimeoutSec 25
    Focus-CUWindow -Hwnd $w.Hwnd | Out-Null
    Start-Sleep -Milliseconds 500
    $report.steps += [pscustomobject]@{ step = 'launch'; hwnd = $w.Hwnd; pid = $w.Pid; title = $w.Title }

    # 2. 截图（动作前）
    $s1 = Get-CUScreenshot -Path (Join-Path $shots '1-before.png') -Hwnd $w.Hwnd
    $report.steps += [pscustomobject]@{ step = 'screenshot-before'; path = $s1.Path; size = "$($s1.Width)x$($s1.Height)" }

    # 3. 读控件树
    $els = Get-CUElements -Hwnd $w.Hwnd -Depth 4 -Max 60
    $report.steps += [pscustomobject]@{ step = 'ui-tree'; count = @($els).Count }
    Write-Output '── UIA 控件树 ──'
    $els | Format-Table Level, Type, Name, AutoId, X, Y, W, H, Patterns -AutoSize | Out-String -Width 200 | Write-Output

    # 4. 按名字点「点我」（UIA Invoke，不算坐标）
    $click = Invoke-CUElement -NamePattern '点我' -Hwnd $w.Hwnd
    Start-Sleep -Milliseconds 600
    $report.steps += [pscustomobject]@{ step = 'click-by-name'; action = $click.Action; name = $click.Name }

    $texts = Get-CUText -Hwnd $w.Hwnd
    $hitOk = @($texts) -contains '已点击 1 次'
    $report.steps += [pscustomobject]@{ step = 'verify-click'; expect = '已点击 1 次'; actual = ($texts -join ' | '); pass = $hitOk }
    if (-not $hitOk) { $report.ok = $false }

    # 5. 点输入框 + 输入中文（剪贴板通道）。WinForms 输入框在 UIA 里没有名字，用类名定位
    $tb = Invoke-CUElement -ClassPattern '*EDIT*' -Hwnd $w.Hwnd
    $report.steps += [pscustomobject]@{ step = 'click-textbox'; action = $tb.Action; pos = "$($tb.X),$($tb.Y)" }
    Start-Sleep -Milliseconds 300
    Set-CUText '你好，电脑操作！DeepSeek Harness' | Out-Null
    Start-Sleep -Milliseconds 300
    Invoke-CUElement -NamePattern '读取输入' -Hwnd $w.Hwnd | Out-Null
    Start-Sleep -Milliseconds 600

    $texts2 = Get-CUText -Hwnd $w.Hwnd
    $typeOk = @($texts2) -contains '输入内容是：你好，电脑操作！DeepSeek Harness'
    $report.steps += [pscustomobject]@{ step = 'verify-typing'; expect = '输入内容是：你好，电脑操作！DeepSeek Harness'; actual = ($texts2 -join ' | '); pass = $typeOk }
    if (-not $typeOk) { $report.ok = $false }

    # 6. 截图（动作后）
    $s2 = Get-CUScreenshot -Path (Join-Path $shots '2-after.png') -Hwnd $w.Hwnd
    $report.steps += [pscustomobject]@{ step = 'screenshot-after'; path = $s2.Path; size = "$($s2.Width)x$($s2.Height)" }

} catch {
    $report.ok = $false
    $report.steps += [pscustomobject]@{ step = 'ERROR'; message = $_.Exception.Message; where = $_.InvocationInfo.PositionMessage }
} finally {
    if ($app -and -not $app.HasExited) { try { $app.Kill(); $app.WaitForExit(2000) } catch { } }
}

Write-Output ''
Write-Output '── 自检结果 ──'
$report | ConvertTo-Json -Depth 6
