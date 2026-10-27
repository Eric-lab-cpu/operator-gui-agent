<#
    setup-runtime.ps1 —— 一次性安装托盘运行目录

    为什么要这一步：
      Windows 的 Explorer 不会为「中文路径」下的 exe 创建通知区条目，
      托盘程序必须放在纯 ASCII 目录（默认 C:\Operator）里运行，图标才会出现。

    做三件事：
      1) 把 OperatorTray.exe + config.json + appdir.txt 复制到 C:\Operator
      2) 在注册表里把该图标标记为「始终显示」
      3) 打印结果

    用法：右键 → 使用 PowerShell 运行；或
          powershell -ExecutionPolicy Bypass -File .\setup-runtime.ps1
#>
param(
    [string]$Target = 'C:\Operator'
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Write-Output "安装托盘运行目录 → $Target"

# 先收掉正在跑的托盘，否则文件被占用
Get-Process -Name OperatorTray -ErrorAction SilentlyContinue | ForEach-Object { try { $_.Kill(); Start-Sleep -Milliseconds 300 } catch {} }
try { [void](New-Item -ItemType Directory -Force -Path $Target) }
catch { Write-Output "无法创建 $Target：$($_.Exception.Message)"; exit 1 }

foreach ($f in 'OperatorTray.exe', 'config.json') {
    $src = Join-Path $here $f
    if (Test-Path $src) {
        Copy-Item $src (Join-Path $Target $f) -Force
        Write-Output "  复制 $f"
    }
}
[System.IO.File]::WriteAllText((Join-Path $Target 'appdir.txt'), $here, (New-Object System.Text.UTF8Encoding($false)))
Write-Output "  写入 appdir.txt → $here"

# 图标默认可见：找到条目后置 IsPromoted=1；没有条目就先跑一次托盘再设
$exe = Join-Path $Target 'OperatorTray.exe'
$base = 'HKCU:\Control Panel\NotifyIconSettings'
function Set-Promoted {
    $done = $false
    Get-ChildItem $base -ErrorAction SilentlyContinue | ForEach-Object {
        $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        if ($p.ExecutablePath -and $p.ExecutablePath -ieq $exe) {
            Set-ItemProperty -Path $_.PSPath -Name 'IsPromoted' -Value 1 -Type DWord
            $done = $true
        }
    }
    return $done
}

if (-not (Set-Promoted)) {
    Write-Output '  图标条目还不存在：先启动一次托盘以注册'
    try {
        $p = Start-Process -FilePath $exe -ArgumentList '--hidden' -PassThru
        Start-Sleep -Seconds 4
    } catch { }
    if (Set-Promoted) { Write-Output '  已标记为始终显示' }
    else { Write-Output '  未能自动标记（可在系统设置里手动打开）' }
} else {
    Write-Output '  已标记为始终显示'
}

Write-Output ''
Write-Output '完成。之后双击 Operator.exe 即可，托盘图标会出现。'
