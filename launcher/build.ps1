<#
    build.ps1 —— 重新编译 Operator.exe（改了 Launcher.cs 之后跑这个）

    只是把 csc 的调用固化下来，避免每次手写一长串参数。
#>
param([string]$Configuration = 'Release')

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here

$csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { throw "找不到 csc.exe" }

$exe = Join-Path $root 'Operator.exe'
Write-Output "编译 $exe"

& $csc /nologo /target:winexe /platform:anycpu /optimize+ `
    /out:$exe `
    /win32icon:"$here\app.ico" `
    /reference:System.Windows.Forms.dll /reference:System.Drawing.dll `
    "$here\Launcher.cs" 2>&1 | ForEach-Object { Write-Output $_ }

if ($LASTEXITCODE -ne 0) { throw "编译失败（exit=$LASTEXITCODE）" }
Write-Output ("完成：{0:N1} KB" -f ((Get-Item $exe).Length / 1KB))
