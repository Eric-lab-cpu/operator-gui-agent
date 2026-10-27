<#
    start-console.ps1 —— 启动 GUI Agent 控制台

    起一个本地 Node 服务（127.0.0.1:6360），浏览器打开就是控制台。
    依赖：worker 已启动（否则窗口列表为空、动作无法执行）。
#>
param(
    [int]$Port = 6360,
    [switch]$Open
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$web = Join-Path $here 'web'
$node = "C:\Users\18790\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\node\bin\node.exe"
if (-not (Test-Path $node)) {
    $node = (Get-Command node -ErrorAction SilentlyContinue).Source
    if (-not $node) { throw '找不到 node.exe' }
}

# 已在跑就只打印地址
try {
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/api/state" -TimeoutSec 3 -UseBasicParsing
    Write-Output "控制台已在运行: http://127.0.0.1:$Port/"
    if ($Open) { Start-Process "http://127.0.0.1:$Port/" }
    exit 0
} catch { }

$env:PORT = "$Port"
$log = Join-Path $web 'console.log'
$err = Join-Path $web 'console.err'

Start-Process -FilePath $node -ArgumentList @('server.mjs') -WorkingDirectory $web -WindowStyle Hidden `
    -RedirectStandardOutput $log -RedirectStandardError $err

Start-Sleep -Seconds 2
try {
    $null = Invoke-WebRequest -Uri "http://127.0.0.1:$Port/api/state" -TimeoutSec 5 -UseBasicParsing
    Write-Output "控制台已启动: http://127.0.0.1:$Port/"
} catch {
    Write-Output "启动失败，看 $err"
    Get-Content $err -ErrorAction SilentlyContinue | Select-Object -Last 10
    exit 1
}

if ($Open) { Start-Process "http://127.0.0.1:$Port/" }
