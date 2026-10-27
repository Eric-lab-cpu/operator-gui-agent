<#
    selftest-app.ps1 —— 应用级全链路自检

    覆盖：服务健康 → 配置读写 → 模型连通 → 真实任务执行 → 结果校验
    用法：.\selftest-app.ps1            （服务需已在跑）
          .\selftest-app.ps1 -Start     （先尝试启动服务）
#>
param(
    [string]$BaseUrl = 'http://127.0.0.1:6360',
    [string]$Provider = 'deepseek',
    [string]$Model = 'deepseek-chat',
    [switch]$Start,
    [switch]$SkipTask
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$pass = 0; $fail = 0
$rows = New-Object System.Collections.ArrayList

function Check([string]$name, [scriptblock]$test) {
    $t0 = Get-Date
    try {
        $r = & $test
        $ok = ($r -eq $true) -or ($r -and $r.ok)
        $detail = if ($r -is [string]) { $r } elseif ($r -and $r.detail) { $r.detail } else { '' }
        $ms = [int]((Get-Date) - $t0).TotalMilliseconds
        if ($ok) { $script:pass++; [void]$rows.Add([pscustomobject]@{ 检查 = $name; 结果 = 'PASS'; 耗时 = "$ms ms"; 说明 = $detail }) }
        else { $script:fail++; [void]$rows.Add([pscustomobject]@{ 检查 = $name; 结果 = 'FAIL'; 耗时 = "$ms ms"; 说明 = $detail }) }
    } catch {
        $script:fail++
        [void]$rows.Add([pscustomobject]@{ 检查 = $name; 结果 = 'FAIL'; 耗时 = ''; 说明 = $_.Exception.Message })
    }
}

function Get-Json([string]$path) {
    $r = Invoke-WebRequest -Uri "$BaseUrl$path" -UseBasicParsing -TimeoutSec 15
    return ($r.Content | ConvertFrom-Json)
}

# ── 0. 可选：先起服务 ───────────────────────────────────────
if ($Start) {
    & (Join-Path $here 'Operator.exe') --silent | Out-Null
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 500
        try { $null = Get-Json '/api/health'; break } catch { }
    }
}

# ── 1. 服务健康 ────────────────────────────────────────────
Check '服务健康检查' {
    $h = Get-Json '/api/health'
    if ($h.ok) { return [pscustomobject]@{ ok = $true; detail = "v$($h.version) · 端口 $($h.port) · 运行 $($h.uptimeSec)s" } }
    return [pscustomobject]@{ ok = $false; detail = 'health 返回 ok=false' }
}

# ── 2. worker 在线 ─────────────────────────────────────────
Check 'worker 在线' {
    $h = Get-Json '/api/health'
    return [pscustomobject]@{ ok = [bool]$h.worker; detail = $(if ($h.worker) { '沙盒外执行器可用' } else { '未启动（动作会失败）' }) }
}

# ── 3. 配置读取 ────────────────────────────────────────────
Check 'API 配置读取' {
    $s = Get-Json '/api/settings'
    $n = ($s.presets.PSObject.Properties | Measure-Object).Count
    if ($n -ge 8) { return [pscustomobject]@{ ok = $true; detail = "$n 个服务商预设 · 当前 $($s.agent.provider)/$($s.agent.model)" } }
    return [pscustomobject]@{ ok = $false; detail = "预设只有 $n 个" }
}

# ── 4. 模型连通 ────────────────────────────────────────────
Check '模型连通性' {
    $body = @{ provider = $Provider; model = $Model } | ConvertTo-Json -Compress
    $r = Invoke-WebRequest -Uri "$BaseUrl/api/settings/test" -Method Post -Body $body `
        -ContentType 'application/json; charset=utf-8' -UseBasicParsing -TimeoutSec 60
    $j = $r.Content | ConvertFrom-Json
    if ($j.ok) { return [pscustomobject]@{ ok = $true; detail = "$Provider/$Model · $($j.latencyMs)ms · $($j.usage.total) tokens" } }
    return [pscustomobject]@{ ok = $false; detail = $j.error }
}

# ── 5. 窗口枚举（依赖 worker）──────────────────────────────
Check '窗口枚举' {
    $s = Get-Json '/api/state'
    return [pscustomobject]@{ ok = ($s.windows.Count -gt 0); detail = "$($s.windows.Count) 个窗口" }
}

# ── 6. 真实任务 ────────────────────────────────────────────
if (-not $SkipTask) {
    Check '真实任务（打开并关闭 dxdiag）' {
        $dir = $here
        $reqDir = Join-Path $dir 'ipc\req'; $resDir = Join-Path $dir 'ipc\res'
        $id = [guid]::NewGuid().ToString('N')
        [IO.File]::WriteAllText((Join-Path $reqDir "$id.json"),
            (@{ cmd = 'launch'; path = "$env:WINDIR\System32\dxdiag.exe" } | ConvertTo-Json -Compress),
            (New-Object Text.UTF8Encoding($true)))
        Start-Sleep -Seconds 8

        $body = @{ task = '关闭 DirectX 诊断工具 窗口'; provider = $Provider; model = $Model; maxSteps = 5 } | ConvertTo-Json -Compress
        $r = Invoke-WebRequest -Uri "$BaseUrl/api/run" -Method Post -Body $body `
            -ContentType 'application/json; charset=utf-8' -UseBasicParsing -TimeoutSec 20
        if (-not ($r.Content | ConvertFrom-Json).ok) { return [pscustomobject]@{ ok = $false; detail = '任务未启动' } }

        for ($i = 0; $i -lt 40; $i++) {
            Start-Sleep -Seconds 2
            $st = Get-Json '/api/state'
            if (-not $st.running) { break }
        }
        $left = @($st.windows | Where-Object { $_.Title -match 'DirectX' }).Count
        if ($left -eq 0) { return [pscustomobject]@{ ok = $true; detail = "目标窗口已关闭 · $($st.tokens.total) tokens" } }
        return [pscustomobject]@{ ok = $false; detail = "还剩 $left 个 DirectX 窗口" }
    }
}

# ── 报告 ───────────────────────────────────────────────────
Write-Output ''
Write-Output '══════════ 应用自检 ══════════'
$rows | Format-Table 检查, 结果, 耗时, 说明 -AutoSize | Out-String -Width 130 | Write-Output
Write-Output ("通过 {0} 项，失败 {1} 项" -f $pass, $fail)
if ($fail -gt 0) { exit 1 }
