<#
    verify-lifecycle.ps1 —— 从启动到退出的全生命周期验证

    1. 停掉一切（服务 + 托盘）
    2. 冷启动：Operator.exe --silent
    3. 检查：服务端口 / 托盘进程（且只有一个）/ worker 心跳
    4. 跑一个真实任务（打开并关闭 dxdiag）
    5. 退出：Operator.exe --stop
    6. 检查：端口关闭 / 托盘消失 / 无残留 node

    注意：必须在「非沙盒」环境运行，否则启动的子进程会被连带结束。
         本机可这样跑：schtasks 起一个一次性任务，或直接用管理员 PowerShell。
#>
param(
    [int]$WaitSec = 20,
    [switch]$SkipTask
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$exe = Join-Path $dir 'Operator.exe'
$rows = New-Object System.Collections.ArrayList
$pass = 0; $fail = 0

function Step([string]$name, [scriptblock]$test) {
    try {
        $ok = [bool](& $test)
        if ($ok) { $script:pass++ } else { $script:fail++ }
        [void]$rows.Add([pscustomobject]@{ 步骤 = $name; 结果 = $(if ($ok) { 'PASS' } else { 'FAIL' }) })
    } catch {
        $script:fail++
        [void]$rows.Add([pscustomobject]@{ 步骤 = $name; 结果 = "FAIL（$($_.Exception.Message)）" })
    }
}

function PortOpen { param([int]$p) (Test-NetConnection -ComputerName 127.0.0.1 -Port $p -WarningAction SilentlyContinue -InformationLevel Quiet) }
function TrayCount { @(Get-Process -Name OperatorTray -ErrorAction SilentlyContinue).Count }
# 只统计「本应用」的 node（命令行里带本目录的 server.mjs），
# 避免把别的 node 程序（例如 Agent Bus 的 MCP 服务）算成残留
function NodeCount {
    $needle = (Join-Path $dir 'web\server.mjs').ToLower()
    $n = 0
    foreach ($p in Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue) {
        if ($p.CommandLine -and $p.CommandLine.ToLower().Contains($needle)) { $n++ }
    }
    return $n
}
function WorkerAge {
    $hb = Join-Path $dir 'ipc\heartbeat.txt'
    if (-not (Test-Path $hb)) { return 9999 }
    $s = (Get-Content $hb -Raw).Trim()
    if ($s -match '\|(.+)$') { try { return [int]((Get-Date) - [datetime]$Matches[1]).TotalSeconds } catch { } }
    return 9999
}

Write-Output '=== 1. 停止一切 ==='
& $exe --stop 2>&1 | Out-Null
Start-Sleep -Seconds 2
Step '停止后端口关闭' { -not (PortOpen 6360) }
Step '停止后托盘退出' {
    for ($i = 0; $i -lt 20; $i++) {
        if ((TrayCount) -eq 0) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

Write-Output '=== 2. 冷启动 ==='
& $exe --silent
$deadline = (Get-Date).AddSeconds($WaitSec)
while ((Get-Date) -lt $deadline -and -not (PortOpen 6360)) { Start-Sleep -Milliseconds 500 }
Step '启动后端口监听' { PortOpen 6360 }

$deadline = (Get-Date).AddSeconds($WaitSec)
while ((Get-Date) -lt $deadline -and (TrayCount) -lt 1) { Start-Sleep -Milliseconds 500 }
Step '托盘图标已运行' { (TrayCount) -ge 1 }
Step '托盘只有一个实例' { (TrayCount) -eq 1 }

$deadline = (Get-Date).AddSeconds(40)
while ((Get-Date) -lt $deadline -and (WorkerAge) -gt 15) { Start-Sleep -Seconds 1 }
Step 'worker 自动就绪' { (WorkerAge) -le 15 }

if (-not $SkipTask) {
    Write-Output '=== 3. 跑一个真实任务 ==='
    Step '真实任务完成' {
        $id = [guid]::NewGuid().ToString('N')
        [IO.File]::WriteAllText((Join-Path $dir "ipc\req\$id.json"),
            (@{ cmd = 'launch'; path = "$env:WINDIR\System32\dxdiag.exe" } | ConvertTo-Json -Compress),
            (New-Object Text.UTF8Encoding($true)))
        Start-Sleep -Seconds 8

        $body = @{ task = '关闭 DirectX 诊断工具 窗口'; provider = 'deepseek'; model = 'deepseek-chat'; maxSteps = 5 } | ConvertTo-Json -Compress
        $r = Invoke-WebRequest -Uri 'http://127.0.0.1:6360/api/run' -Method Post -Body $body `
            -ContentType 'application/json; charset=utf-8' -UseBasicParsing -TimeoutSec 20
        if (-not ($r.Content | ConvertFrom-Json).ok) { return $false }

        for ($i = 0; $i -lt 40; $i++) {
            Start-Sleep -Seconds 2
            $st = (Invoke-WebRequest -Uri 'http://127.0.0.1:6360/api/state' -UseBasicParsing -TimeoutSec 10).Content | ConvertFrom-Json
            if (-not $st.running) { break }
        }
        return (@($st.windows | Where-Object { $_.Title -match 'DirectX' }).Count -eq 0)
    }
}

Write-Output '=== 4. 退出 ==='
& $exe --stop 2>&1 | Out-Null
Start-Sleep -Seconds 6
Step '退出后端口关闭' { -not (PortOpen 6360) }
Step '退出后托盘消失' {
    for ($i = 0; $i -lt 10; $i++) {
        if ((TrayCount) -eq 0) { return $true }
        Start-Sleep -Milliseconds 400
    }
    return $false
}
Step '退出后无残留 node' {
    for ($i = 0; $i -lt 12; $i++) {
        if ((NodeCount) -eq 0) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return $false
}

Write-Output ''
Write-Output '══════ 生命周期验证 ══════'
$rows | Format-Table 步骤, 结果 -AutoSize | Out-String -Width 100 | Write-Output
Write-Output ("通过 {0} 项，失败 {1} 项" -f $pass, $fail)
if ($fail -gt 0) { exit 1 }
