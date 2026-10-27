<#
    worker-via-task.ps1 —— 用计划任务把 worker 拉出作业对象（需在 danger-full-access 下运行）

    为什么必须这样：WMI / Start-Process 创建的子进程会落进当前作业对象，
    命令一结束就被 kill-on-close 连带杀掉。计划任务由任务计划服务创建进程，完全独立。
#>
param(
    [string]$TaskName = 'DSH-GUI-Worker',
    [int]$WaitSec = 25,
    [switch]$Unregister,
    [switch]$WithWatchdog
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$worker = Join-Path $here 'worker.ps1'
$ipc = Join-Path $here 'ipc'
$pidFile = Join-Path $ipc 'worker.pid'

Write-Output '[1] 结束旧 worker'
if (Test-Path $pidFile) {
    $old = (Get-Content $pidFile -Raw).Trim()
    if ($old -match '^\d+$') {
        $p = Get-Process -Id ([int]$old) -ErrorAction SilentlyContinue
        if ($p -and $p.ProcessName -eq 'powershell') { try { $p.Kill(); Write-Output "    killed $old" } catch { } }
    }
    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
}

if ($Unregister) {
    $o = & schtasks.exe /Delete /TN $TaskName /F 2>&1
    Write-Output ("[2] " + ($o -join ' '))
    exit 0
}

Remove-Item (Join-Path $here 'worker.log') -Force -ErrorAction SilentlyContinue
Remove-Item $ipc -Recurse -Force -ErrorAction SilentlyContinue

Write-Output '[2] 注册计划任务'
$tr = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$worker`""
$o = & schtasks.exe /Create /TN $TaskName /TR $tr /SC ONCE /ST 23:59 /F /RL LIMITED 2>&1
Write-Output ("    " + ($o -join ' '))
if ($LASTEXITCODE -ne 0) { Write-Output '[!] 注册失败'; exit 1 }

Write-Output '[3] 触发'
$o2 = & schtasks.exe /Run /TN $TaskName 2>&1
Write-Output ("    " + ($o2 -join ' '))

Write-Output '[4] 等心跳'
$hb = Join-Path $ipc 'heartbeat.txt'
$deadline = (Get-Date).AddSeconds($WaitSec)
$got = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 600
    if (Test-Path $hb) { $got = $true; break }
}
if ($got) {
    Write-Output ("    heartbeat: " + ((Get-Content $hb -Raw).Trim()))
} else {
    Write-Output '    [!] 无心跳，日志:'
    Get-Content (Join-Path $here 'worker.log') -ErrorAction SilentlyContinue | ForEach-Object { Write-Output ("      " + $_) }
    exit 1
}

Write-Output '[5] 存活检查（3 秒后再看一次，确认不会被连带杀掉）'
Start-Sleep -Seconds 3
if (Test-Path $hb) {
    try { $hbv = (Get-Content $hb -Raw -ErrorAction Stop).Trim() } catch { $hbv = '|' + (Get-Date).ToString('o') }
    $ts = $null
    if ($hbv -match '\|(.+)$') { try { $ts = [datetime]$Matches[1] } catch { } }
    if ($ts -and ((Get-Date) - $ts).TotalSeconds -lt 5) { Write-Output '    OK 仍在运行' }
    else { Write-Output "    [!] 心跳停了: $hbv" }
} else { Write-Output '    [!] 心跳文件消失' }
if ($WithWatchdog) {
    Write-Output '[6] 安装看门狗（计划任务，每分钟检查心跳）'
    $wd = Join-Path $here 'watchdog.ps1'
    $tr2 = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$wd`""
    $o2 = & schtasks.exe /Create /TN 'DSH-GUI-Watchdog' /TR $tr2 /SC MINUTE /MO 1 /F /RL LIMITED 2>&1
    Write-Output ('    ' + ($o2 -join ' '))
    if ($LASTEXITCODE -eq 0) { Write-Output '    看门狗已启用（worker 挂掉后 1 分钟内自动拉起）' }
}