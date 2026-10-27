<#
    package.ps1 —— 打一个可分发的 zip

    产物：dist\Operator-<版本>\ 和 dist\Operator-<版本>.zip
    包含：可执行文件、能力库、agent、Web 控制台、脚本、文档
    不含：密钥、运行日志、历史记录、ipc 目录
#>
param([switch]$SkipZip)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ver = (Get-Content (Join-Path $root 'VERSION') -Raw).Trim()
$name = "Operator-$ver"
$dist = Join-Path $root 'dist'
$out = Join-Path $dist $name

Write-Output "打包 $name"

if (Test-Path $out) { Remove-Item $out -Recurse -Force }
[void](New-Item -ItemType Directory -Force -Path $out)

# 要带的文件
$files = @(
    'Operator.exe', 'OperatorTray.exe', 'VERSION', 'config.json',
    'cu.ps1', 'cu-cli.ps1', 'gui.ps1', 'worker.ps1',
    'worker-via-task.ps1', 'gui-clean.ps1', 'start-console.ps1',
    'benchmark.ps1', 'hidden-run.vbs', 'selftest-app.ps1', 'console.vbs', 'verify-lifecycle.ps1', 'setup-runtime.ps1',
    'README.md', 'QUICKSTART.md', 'LICENSE', 'CHANGELOG.md'
)
foreach ($f in $files) {
    $src = Join-Path $root $f
    if (Test-Path $src) { Copy-Item $src (Join-Path $out $f) -Force }
    else { Write-Output "  [跳过] $f 不存在" }
}

# 目录
foreach ($d in 'agent', 'web', 'bin', 'demo', 'launcher') {
    $src = Join-Path $root $d
    if (-not (Test-Path $src)) { continue }
    $dst = Join-Path $out $d
    [void](New-Item -ItemType Directory -Force -Path $dst)
    Get-ChildItem $src -File | Where-Object {
        $_.Name -notmatch '\.(log|pid)$' -and
        $_.Name -ne 'keys.json' -and
        $_.Extension -ne '.pdb'
    } | ForEach-Object { Copy-Item $_.FullName (Join-Path $dst $_.Name) -Force }
}

# 空目录占位（运行时需要）
foreach ($d in 'ipc\req', 'ipc\res', 'web\history', 'agent\run') {
    $p = Join-Path $out $d
    [void](New-Item -ItemType Directory -Force -Path $p)
    Set-Content -LiteralPath (Join-Path $p '.gitkeep') -Value '' -Encoding ASCII
}

# 包里不放 key，给个模板
$keysTpl = @'
{
  "_说明": "把 API Key 填在这里，或用系统环境变量（环境变量优先）",
  "deepseek": "",
  "openai": "",
  "moonshot": ""
}
'@
Set-Content -LiteralPath (Join-Path $out 'agent\keys.example.json') -Value $keysTpl -Encoding UTF8

$count = (Get-ChildItem $out -Recurse -File | Measure-Object).Count
$size = [math]::Round(((Get-ChildItem $out -Recurse -File | Measure-Object Length -Sum).Sum / 1MB), 2)
Write-Output ("  文件 {0} 个，{1} MB → {2}" -f $count, $size, $out)

if (-not $SkipZip) {
    $zip = Join-Path $dist "$name.zip"
    if (Test-Path $zip) { Remove-Item $zip -Force }
    Compress-Archive -Path (Join-Path $out '*') -DestinationPath $zip -CompressionLevel Optimal
    Write-Output ("  已压缩 → {0} ({1:N1} MB)" -f $zip, ((Get-Item $zip).Length / 1MB))
}
