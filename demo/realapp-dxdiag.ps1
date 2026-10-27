<#
    realapp-dxdiag.ps1 —— 真实第三方软件上的完整闭环演示
    1) 处理 DirectUI 模态框（控件树几乎为空 → 走键盘加速键兜底）
    2) 主窗口按控件名字点「下一页」并校验页面变化
    3) 全程截图留证
#>
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path (Split-Path -Parent $here) 'cu.ps1')
$shots = Join-Path $here 'shots'
[void](New-Item -ItemType Directory -Force -Path $shots)

function Note([string]$m) { Write-Output $m }
function Get-DxWindows { Get-CUWindows -Title '*DirectX*' }

$app = $null
$ok = $false
try {
    $app = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\dxdiag.exe') -PassThru
    $deadline = (Get-Date).AddSeconds(25)
    while ((Get-Date) -lt $deadline -and -not (Get-DxWindows)) { Start-Sleep -Milliseconds 400 }

    # ── 阶段 1：WHQL 询问框（DirectUI，控件几乎不可读） ──
    $prompt = Get-DxWindows | Sort-Object Height | Select-Object -First 1
    if ($prompt -and $prompt.Height -lt 450) {
        Focus-CUWindow -Hwnd $prompt.Hwnd | Out-Null
        Start-Sleep -Milliseconds 600
        $pels = Get-CUElements -Hwnd $prompt.Hwnd -Depth 4 -Max 50
        Note ("[1] 模态框 '{0}' {1}x{2}，UIA 只暴露 {3} 个控件：" -f $prompt.Title, $prompt.Width, $prompt.Height, @($pels).Count)
        foreach ($e in $pels) { Note ("      {0,-10} name='{1}' class='{2}'" -f $e.Type, $e.Name, $e.'Class') }

        # 控件通道在这里没名字可用 → 用键盘加速键（否(N) → n）
        Send-CUKeys 'n'
        Start-Sleep -Milliseconds 1500
        $still = Get-DxWindows | Where-Object { $_.Height -lt 450 }
        Note ("[2] 发送按键 'n' 后模态框{0}" -f $(if ($still) { '仍在 → 改用坐标点击兜底' } else { '已关闭' }))
        if ($still) {
            $bx = [int]($prompt.X + $prompt.Width * 0.85)
            $by = [int]($prompt.Y + $prompt.Height * 0.845)
            Invoke-CUClick -X $bx -Y $by | Out-Null
            Start-Sleep -Milliseconds 1200
            Note ("[2b] 坐标点击 ({0},{1}) 后模态框{2}" -f $bx, $by, $(if (Get-DxWindows | Where-Object { $_.Height -lt 450 }) { '仍在' } else { '已关闭' }))
        }
    }

    # ── 阶段 2：主窗口按名字点「下一页」 ──
    $deadline = (Get-Date).AddSeconds(20)
    $main = $null
    while ((Get-Date) -lt $deadline -and -not $main) {
        $main = Get-DxWindows | Where-Object { $_.Height -ge 450 } | Select-Object -First 1
        if (-not $main) { Start-Sleep -Milliseconds 400 }
    }
    if (-not $main) { throw '主窗口没出现' }
    Focus-CUWindow -Hwnd $main.Hwnd | Out-Null
    Start-Sleep -Milliseconds 2500     # 等它收集完系统信息

    $els = Get-CUElements -Hwnd $main.Hwnd -Depth 8 -Max 300
    Note ("[3] 主窗口 '{0}' {1}x{2}，控件数 {3}" -f $main.Title, $main.Width, $main.Height, @($els).Count)
    Note ("    按钮: " + ((@($els | Where-Object { $_.Type -eq 'Button' }) | ForEach-Object { $_.Name }) -join ' | '))
    Note ("    页签: " + ((@($els | Where-Object { $_.Type -eq 'TabItem' }) | ForEach-Object { $_.Name }) -join ' | '))

    $before = @($els | Where-Object { $_.Name } | ForEach-Object { $_.Name })
    Note ("[4] 当前页可读文本 {0} 条，样本: {1}" -f $before.Count, (($before | Select-Object -First 4) -join ' / '))
    $s1 = Get-CUScreenshot -Path (Join-Path $shots '6-dxdiag-page1.png') -Hwnd $main.Hwnd
    Note ("    截图 -> {0}" -f $s1.Path)

    $clicked = $null
    $deadline = (Get-Date).AddSeconds(12)
    while (-not $clicked -and (Get-Date) -lt $deadline) {
        foreach ($pat in @('下一页*', '下一步*')) {
            $hit = Find-CUElement -NamePattern $pat -Hwnd $main.Hwnd
            if ($hit -and $hit.Enabled) {
                try { $clicked = Invoke-CUElement -NamePattern $pat -Hwnd $main.Hwnd } catch { }
                if ($clicked) { break }
            }
        }
        if (-not $clicked) { Start-Sleep -Milliseconds 500 }
    }
    if (-not $clicked) { throw '「下一页」按钮一直不可用' }
    Note ("[5] 按名字点击 -> {0} / {1}" -f $clicked.Action, $clicked.Name)
    Start-Sleep -Milliseconds 1200

    $els2 = Get-CUElements -Hwnd $main.Hwnd -Depth 8 -Max 300
    $after = @($els2 | Where-Object { $_.Name } | ForEach-Object { $_.Name })
    $new = @($after | Where-Object { $before -notcontains $_ })
    Note ("[6] 翻页后文本 {0} 条，新增 {1} 条: {2}" -f $after.Count, $new.Count, (($new | Select-Object -First 5) -join ' / '))
    $s2 = Get-CUScreenshot -Path (Join-Path $shots '7-dxdiag-page2.png') -Hwnd $main.Hwnd
    Note ("    截图 -> {0}" -f $s2.Path)

    $ok = ($new.Count -gt 0)

    foreach ($pat in @('退出*', '关闭*')) {
        try { Invoke-CUElement -NamePattern $pat -Hwnd $main.Hwnd | Out-Null; break } catch { }
    }
} catch {
    Note ("[ERROR] {0}" -f $_.Exception.Message)
} finally {
    if ($app -and -not $app.HasExited) { try { $app.Kill() } catch { } }
    Note ("[result] " + $(if ($ok) { 'PASS - 真实软件上按名字点击成功，界面状态按预期变化' } else { 'FAIL' }))
}
