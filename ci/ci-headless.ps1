<#
    ci-headless.ps1 —— 可在无桌面环境运行的 CI 检查

    能跑：语法检查、服务启动、HTTP 接口、定时任务 CRUD、导出
    不能跑：UI 自动化（需要交互桌面）、真实任务（需要真实窗口）

    用法：pwsh ./ci/ci-headless.ps1
#>
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$pass = 0
$fail = 0
$rows = New-Object System.Collections.ArrayList

function Check([string]$name, [scriptblock]$test) {
    try {
        $ok = [bool](& $test)
        $detail = ''
        if ($ok) { $script:pass++ } else { $script:fail++ }
        [void]$rows.Add([pscustomobject]@{ 检查 = $name; 结果 = $(if ($ok) { 'PASS' } else { 'FAIL' }) })
    } catch {
        $script:fail++
        [void]$rows.Add([pscustomobject]@{ 检查 = $name; 结果 = "FAIL: $($_.Exception.Message)" })
    }
}

function Get-Node {
    $c = Get-Command node -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $fallback = 'C:\Users\18790\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\node\bin\node.exe'
    if (Test-Path $fallback) { return $fallback }
    return $null
}
$node = Get-Node

# ── 1. PowerShell 语法 ───────────────────────────────────────
Check '所有 .ps1 语法' {
    $errs = 0
    Get-ChildItem $root -Recurse -Filter *.ps1 -File |
        Where-Object { $_.FullName -notmatch '\\dist\\|\\.git\\' } | ForEach-Object {
            $e = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$e)
            if ($e -and $e.Count -gt 0) {
                Write-Output "  语法错误 $($_.Name): $($e[0].Message)"
                $errs++
            }
        }
    return ($errs -eq 0)
}

# ── 2. Node 语法 ─────────────────────────────────────────────
Check 'server.mjs 语法' {
    if (-not $node) { return $false }
    & $node --check (Join-Path $root 'web\server.mjs') 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# ── 3. 前端 JS 语法 ──────────────────────────────────────────
Check 'index.html 内联 JS 语法' {
    if (-not $node) { return $false }
    $html = [System.IO.File]::ReadAllText((Join-Path $root 'web\index.html'), [System.Text.Encoding]::UTF8)
    $m = [regex]::Match($html, '(?s)<script>(.*)</script>')
    if (-not $m.Success) { return $false }
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) 'ci-inline.js'
    [System.IO.File]::WriteAllText($tmp, $m.Groups[1].Value, (New-Object System.Text.UTF8Encoding($false)))
    & $node --check $tmp 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# ── 4. Python 语法 ───────────────────────────────────────────
Check 'llm_call.py 语法' {
    $py = Get-Command python -ErrorAction SilentlyContinue
    if (-not $py) { $py = Get-Command python3 -ErrorAction SilentlyContinue }
    if (-not $py) { return $true }   # 没装 Python 就跳过，不算失败
    & $py.Source -m py_compile (Join-Path $root 'agent\llm_call.py') 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# ── 5. 服务启动 + 接口 ───────────────────────────────────────
$port = 6399
$base = "http://127.0.0.1:$port"
$proc = $null
try {
    $env:PORT = "$port"
    $proc = Start-Process -FilePath $node -ArgumentList 'server.mjs' `
        -WorkingDirectory (Join-Path $root 'web') -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput (Join-Path ([System.IO.Path]::GetTempPath()) 'ci-srv.log') `
        -RedirectStandardError (Join-Path ([System.IO.Path]::GetTempPath()) 'ci-srv.err')
    $up = $false
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 300
        try { $null = Invoke-WebRequest -Uri "$base/api/health" -UseBasicParsing -TimeoutSec 2; $up = $true; break } catch { }
    }
} catch { }

Check '服务能启动并响应 /api/health' {
    if (-not $up) { return $false }
    $h = (Invoke-WebRequest "$base/api/health" -UseBasicParsing -TimeoutSec 5).Content | ConvertFrom-Json
    return ($h.ok -eq $true -and $h.port -eq $port)
}

Check '/api/settings 返回服务商预设' {
    $s = (Invoke-WebRequest "$base/api/settings" -UseBasicParsing -TimeoutSec 5).Content | ConvertFrom-Json
    return (($s.presets.PSObject.Properties | Measure-Object).Count -ge 8)
}

Check '定时任务 CRUD' {
    $body = @{ name = 'ci-test'; steps = @('任务一', '任务二'); everyMin = 60; enabled = $false } | ConvertTo-Json -Compress
    $r = (Invoke-WebRequest "$base/api/schedules" -Method Post -ContentType 'application/json' -Body $body -UseBasicParsing).Content | ConvertFrom-Json
    if (-not $r.ok) { return $false }
    $list = (Invoke-WebRequest "$base/api/schedules" -UseBasicParsing).Content | ConvertFrom-Json
    $found = $list.tasks | Where-Object { $_.id -eq $r.task.id }
    if (-not $found) { return $false }
    if ($found.steps.Count -ne 2) { return $false }
    $null = Invoke-WebRequest "$base/api/schedules/delete" -Method Post -ContentType 'application/json' -Body (@{ id = $r.task.id } | ConvertTo-Json -Compress) -UseBasicParsing
    return $true
}

Check '导出不存在的记录返回 404' {
    try { $null = Invoke-WebRequest "$base/api/export?id=nope" -UseBasicParsing -TimeoutSec 5; return $false }
    catch { return ($_.Exception.Response.StatusCode.value__ -eq 404) }
}

# ── 收尾 ─────────────────────────────────────────────────────
if ($proc -and -not $proc.HasExited) { try { $proc.Kill() } catch { } }
$pidFile = Join-Path $root 'web\console.pid'
if (Test-Path $pidFile) {
    $p2 = Get-Content $pidFile -ErrorAction SilentlyContinue
    if ($p2) { Get-Process -Id $p2 -ErrorAction SilentlyContinue | ForEach-Object { try { $_.Kill() } catch { } } }
    Remove-Item $pidFile -Force -ErrorAction SilentlyContinue
}
Remove-Item Env:\PORT -ErrorAction SilentlyContinue

Write-Output ''
Write-Output '══════ CI（无桌面）══════'
$rows | Format-Table 检查, 结果 -AutoSize | Out-String -Width 100 | Write-Output
Write-Output ("通过 $pass 项，失败 $fail 项")
if ($fail -gt 0) { exit 1 }
