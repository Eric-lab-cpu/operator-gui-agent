<#
    benchmark.ps1 —— 5 个真实任务的基准测试

    每个用例：准备环境 → 跑 agent → 自动验证 → 记录 步数/耗时/tokens/成败
    结果写到 bench/results-<时间>.json，同时打印表格。

    用法：
      .\benchmark.ps1 -Provider deepseek -Model deepseek-chat
      .\benchmark.ps1 -Provider ollama -Model gemma4:e4b -Only close-dxdiag
#>
param(
    [string]$Provider = 'deepseek',
    [string]$Model = 'deepseek-chat',
    [int]$MaxSteps = 8,
    [string[]]$Only = @(),
    [int]$SetupWaitSec = 7
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$agent = Join-Path $here 'agent\agent.ps1'
$benchDir = Join-Path $here 'bench'
[void](New-Item -ItemType Directory -Force -Path $benchDir)

$reqDir = Join-Path $here 'ipc\req'
$resDir = Join-Path $here 'ipc\res'

# ── 与 worker 通信 ──────────────────────────────────────────
function CU([hashtable]$r, [int]$t = 30) {
    $id = [guid]::NewGuid().ToString('N')
    [IO.File]::WriteAllText((Join-Path $reqDir "$id.json"), ($r | ConvertTo-Json -Compress -Depth 4), (New-Object Text.UTF8Encoding($true)))
    $dl = (Get-Date).AddSeconds($t)
    while ((Get-Date) -lt $dl) {
        $f = Join-Path $resDir "$id.json"
        if (Test-Path $f) {
            Start-Sleep -Milliseconds 50
            $x = [IO.File]::ReadAllText($f, [Text.Encoding]::UTF8).TrimStart([char]0xFEFF)
            Remove-Item $f -Force -ErrorAction SilentlyContinue
            try { return ($x | ConvertFrom-Json) } catch { return $null }
        }
        Start-Sleep -Milliseconds 70
    }
    return $null
}

function Get-Wins { $r = CU @{ cmd = 'windows' }; if ($r -and $r.ok) { return @($r.data) } else { return @() } }

function Close-App([string]$pattern) {
    foreach ($w in (Get-Wins | Where-Object { $_.Title -match $pattern -or $_.Process -match $pattern })) {
        [void](CU @{ cmd = 'close'; hwnd = $w.Hwnd })
    }
    Start-Sleep -Milliseconds 600
}

# ── 用例定义 ────────────────────────────────────────────────
$pageTmp = Join-Path $env:TEMP 'cu-browser-test.html'
$chrome = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
$prof = Join-Path $env:TEMP 'cu-bench-profile'

$cases = @(
    @{
        name    = 'close-dxdiag'
        app     = 'DirectX'
        setup   = { Start-Process "$env:WINDIR\System32\dxdiag.exe" }
        task    = '关闭 DirectX 诊断工具 窗口'
        verify  = { -not (Get-Wins | Where-Object { $_.Title -match 'DirectX' }) }
        expect  = 'DirectX 窗口消失'
    },
    @{
        name    = 'close-cleanmgr'
        app     = '磁盘清理'
        setup   = { Start-Process "$env:WINDIR\System32\cleanmgr.exe" }
        task    = '关闭磁盘清理的驱动器选择窗口'
        verify  = { -not (Get-Wins | Where-Object { $_.Title -match '磁盘清理' }) }
        expect  = '磁盘清理窗口消失'
    },
    @{
        name    = 'read-computername'
        app     = 'DirectX'
        setup   = { Start-Process "$env:WINDIR\System32\dxdiag.exe" }
        task    = '读出这台电脑的计算机名和操作系统版本，告诉我'
        verify  = { param($log) $log -match '一棵大树' }
        expect  = '日志里出现计算机名「一棵大树」'
    },
    @{
        name    = 'browser-calc'
        app     = 'CU 浏览器验证页'
        setup   = {
            Copy-Item -Force (Join-Path $here 'demo\browser-test.html') $pageTmp
            # 先关掉所有 Chrome，避免 agent 盯上控制台那个窗口
            Get-Process chrome -ErrorAction SilentlyContinue | ForEach-Object { try { $_.Kill() } catch {} }
            Start-Sleep -Seconds 2
            Start-Process $chrome -ArgumentList @("--user-data-dir=$prof", '--no-first-run', '--no-default-browser-check', '--new-window', ("file:///" + ($pageTmp -replace '\\', '/')))
        }
        wait    = 12
        task    = '在页面里把「数量」填 3、「单价」填 25，点「计算」按钮，读出合计'
        verify  = {
            param($log)
            $w = Get-Wins | Where-Object { $_.Title -match 'CU 浏览器验证页' } | Select-Object -First 1
            if (-not $w) { return $false }
            $t = CU @{ cmd = 'texts'; hwnd = $w.Hwnd }
            if (-not $t.ok) { return $false }
            return (@($t.data | Where-Object { $_ -match '75' }).Count -gt 0)
        }
        expect  = '页面出现「合计：75 元」'
    },
    @{
        name    = 'dxdiag-gpu'
        app     = 'DirectX'
        setup   = { Start-Process "$env:WINDIR\System32\dxdiag.exe" }
        task    = '在 DirectX 诊断工具里翻到显示页，读出显卡型号'
        verify  = { param($log) $log -match 'NVIDIA|GeForce|Radeon|Intel' }
        expect  = '日志里出现显卡型号'
    }
)
if ($Only.Count -gt 0) { $cases = @($cases | Where-Object { $Only -contains $_.name }) }

# ── 执行 ────────────────────────────────────────────────────
# 前置检查：worker 必须在
$hb = Join-Path $here 'ipc\heartbeat.txt'
$stale = $true
if (Test-Path $hb) { $s = (Get-Content $hb -Raw).Trim(); if ($s -match '\|(.+)$') { try { $stale = (((Get-Date) - [datetime]$Matches[1]).TotalSeconds -gt 20) } catch {} } }
if ($stale) { Write-Output '[!] worker 不在线，先跑 worker-via-task.ps1'; exit 1 }

$results = New-Object System.Collections.ArrayList
$i = 0
foreach ($c in $cases) {
    $i++
    Write-Output ("[{0}/{1}] {2}" -f $i, $cases.Count, $c.name)
    $logPath = Join-Path $benchDir ("{0}-{1}.log" -f $c.name, (Get-Date -Format 'HHmmss'))
    # 全局清理：关掉所有可能残留的窗口，保证用例之间互不干扰
    $patterns = 'DirectX', '系统属性', 'CU 浏览器验证页'
    foreach ($w in (Get-Wins)) {
        foreach ($pt in $patterns) {
            if ($w.Title -match $pt) { [void](CU @{ cmd = 'close'; hwnd = $w.Hwnd }) }
        }
    }
    Start-Sleep -Milliseconds 800

    try { & $c.setup } catch { Write-Output ("    准备失败: " + $_.Exception.Message) }
    $waitSec = $SetupWaitSec
    if ($c.ContainsKey('wait')) { $waitSec = [int]$c.wait }
    Start-Sleep -Seconds $waitSec

    $ready = $false
$ready = $false
if ($c.ContainsKey('app')) {
    $wins = @(Get-Wins)
    $hit = @($wins | Where-Object { $_.Title -match $c.app })
    $ready = ($hit.Count -gt 0)
    if (-not $ready) { Write-Output ("    预检：目标窗口未出现（当前 " + $wins.Count + " 个窗口）") }
}
if (-not $ready) {
    Write-Output '    INVALID（准备后目标窗口不存在，跳过，避免假通过）'
    [void]$results.Add([pscustomobject]@{ case = $c.name; ok = $false; steps = 0; seconds = 0; tokens = 0; done = $false; expect = $c.expect; log = '(准备失败)' })
    continue
}

$sw = [Diagnostics.Stopwatch]::StartNew()
    $argStr = "-NoProfile -ExecutionPolicy Bypass -File `"$agent`" -Task `"$($c.task)`" " +
              "-Provider $Provider -Model $Model -MaxSteps $MaxSteps -LogFile `"$logPath`""
    $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argStr -Wait -PassThru -WindowStyle Hidden
    $sw.Stop()

    $log = ''
    if (Test-Path $logPath) { $log = [IO.File]::ReadAllText($logPath, [Text.Encoding]::UTF8) }
    $steps = ([regex]::Matches($log, '(?m)^\[step ')).Count
    $tokens = 0
    if ($log -match '__TOKENS__ (\{[^\}]+\})') { try { $tokens = ($Matches[1] | ConvertFrom-Json).total } catch {} }
    $done = $log -match '完成:'

    $ok = $false
    try {
        if ($c.verify.ToString() -match 'param\(\$log\)') { $ok = [bool](& $c.verify $log) } else { $ok = [bool](& $c.verify) }
    } catch { $ok = $false }

    $row = [pscustomobject]@{
        case    = $c.name
        ok      = $ok
        steps   = $steps
        seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        tokens  = $tokens
        done    = $done
        expect  = $c.expect
        log     = $logPath
    }
    [void]$results.Add($row)
    Write-Output ("    {0}  步数={1} 耗时={2}s tokens={3}" -f $(if ($ok) { 'PASS' } else { 'FAIL' }), $steps, $row.seconds, $tokens)
}

# ── 汇总 ────────────────────────────────────────────────────
Write-Output ''
Write-Output '══════════ 基准结果 ══════════'
$results | Format-Table case, ok, steps, seconds, tokens, done -AutoSize | Out-String -Width 120 | Write-Output

$pass = @($results | Where-Object { $_.ok }).Count
$total = $results.Count
$avgSteps = if ($total) { [math]::Round((($results | Measure-Object steps -Average).Average), 1) } else { 0 }
$avgSec = if ($total) { [math]::Round((($results | Measure-Object seconds -Average).Average), 1) } else { 0 }
$sumTok = ($results | Measure-Object tokens -Sum).Sum

Write-Output ("通过 {0}/{1} ｜ 平均步数 {2} ｜ 平均耗时 {3}s ｜ 总 tokens {4}" -f $pass, $total, $avgSteps, $avgSec, $sumTok)

$outFile = Join-Path $benchDir ("results-{0}.json" -f (Get-Date -Format 'yyMMdd-HHmmss'))
$payload = @{
    provider = $Provider; model = $Model; startedAt = (Get-Date).ToString('s')
    pass = $pass; total = $total; avgSteps = $avgSteps; avgSeconds = $avgSec; totalTokens = $sumTok
    rows = @($results)
} | ConvertTo-Json -Depth 6
[IO.File]::WriteAllText($outFile, $payload, (New-Object Text.UTF8Encoding($false)))
Write-Output ("结果已保存: {0}" -f $outFile)
