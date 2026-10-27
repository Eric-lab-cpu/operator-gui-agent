<#
    task-cleanmgr.ps1 —— 真实任务：查看 C 盘能释放多少空间

    安全约束：只点「确定」开始扫描，全程不点任何删除按钮，最后用「取消」退出。
#>
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path (Split-Path -Parent $here) 'cu.ps1')
$shots = Join-Path $here 'shots'
[void](New-Item -ItemType Directory -Force -Path $shots)

function Note([string]$m) { Write-Output $m }

$app = $null
$ok = $false
$cpid = 0

try {
    $app = Start-Process -FilePath (Join-Path $env:WINDIR 'System32\cleanmgr.exe') -PassThru
    Start-Sleep -Milliseconds 500
    $cpid = $app.Id

    $w = Wait-CUWindow -Title '*磁盘清理*' -TimeoutSec 30
    Focus-CUWindow -Hwnd $w.Hwnd | Out-Null
    Start-Sleep -Milliseconds 1200
    Note ("[1] 驱动器选择对话框: '{0}' {1}x{2}" -f $w.Title, $w.Width, $w.Height)

    $els = Get-CUElements -Hwnd $w.Hwnd -Depth 8 -Max 200
    Note ("[2] 控件 {0} 个: {1}" -f @($els).Count, ((@($els | Where-Object { $_.Name }) | ForEach-Object { $_.Name }) -join ' | '))

    $s0 = Get-CUScreenshot -Path (Join-Path $shots '12-cleanmgr-select.png') -Hwnd $w.Hwnd
    Note ("    截图 -> {0}" -f $s0.Path)

    # 点「确定」开始扫描
    $clicked = $false
    foreach ($pat in @('确定', 'OK')) {
        try { Invoke-CUElement -NamePattern $pat -Hwnd $w.Hwnd | Out-Null; $clicked = $true; Note ("[3] 点「{0}」开始扫描" -f $pat); break } catch { }
    }
    if (-not $clicked) { throw '找不到「确定」按钮' }

    # 等扫描：轮询控件文本，出现「要删除的文件」/「总计」就算完
    $done = $false
    $deadline = (Get-Date).AddSeconds(150)
    $lastNote = (Get-Date)
    while ((Get-Date) -lt $deadline -and -not $done) {
        Start-Sleep -Seconds 5
        $cw = Get-CUWindows -Title '*磁盘清理*' | Select-Object -First 1
        if (-not $cw) { break }
        $names = @(Get-CUText -Hwnd $cw.Hwnd)
        if ($names -match '总计|要删除的文件|可释放') { $done = $true; Note ("[4] 扫描完成（{0} 条文本）" -f $names.Count) }
        elseif (((Get-Date) - $lastNote).TotalSeconds -gt 30) {
            Note ("[4] 仍在扫描… 当前 {0} 条文本" -f $names.Count)
            $lastNote = (Get-Date)
        }
    }

    $w2 = Get-CUWindows -Title '*磁盘清理*' | Select-Object -First 1
    if (-not $w2) { throw '清理窗口不见了' }
    Focus-CUWindow -Hwnd $w2.Hwnd | Out-Null
    Start-Sleep -Milliseconds 800

    $s1 = Get-CUScreenshot -Path (Join-Path $shots '13-cleanmgr-result.png') -Hwnd $w2.Hwnd
    Note ("[5] 结果截图 -> {0}" -f $s1.Path)

    $els2 = Get-CUElements -Hwnd $w2.Hwnd -Depth 10 -Max 400
    Note ("[6] 结果窗口控件 {0} 个，类型分布: {1}" -f @($els2).Count, ((@($els2) | Group-Object Type | ForEach-Object { "$($_.Name)x$($_.Count)" }) -join ' '))
    $interesting = @($els2 | Where-Object { $_.Name -match '\d' } | ForEach-Object { $_.Name })
    Note ("    带数字的文本: {0}" -f (($interesting | Select-Object -First 15) -join ' | '))
    $ok = ($interesting.Count -gt 0)

    # 只读：用「取消」退出，不删任何东西
    $closed = $false
    foreach ($pat in @('取消', 'Cancel')) {
        try { Invoke-CUElement -NamePattern $pat -Hwnd $w2.Hwnd | Out-Null; $closed = $true; break } catch { }
    }
    Note ("[7] 退出方式: {0}" -f $(if ($closed) { '点「取消」' } else { '兜底关进程' }))

} catch {
    Note ("[ERROR] {0}" -f $_.Exception.Message)
} finally {
    Start-Sleep -Milliseconds 500
    try { $p = Get-Process -Id $cpid -ErrorAction SilentlyContinue; if ($p) { $p.Kill() } } catch { }
    Note ("[result] " + $(if ($ok) { 'PASS' } else { 'FAIL' }))
}
