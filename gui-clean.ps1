<#
    gui-clean.ps1 —— 结束所有 GUI worker 进程（沙盒内无法结束，需 danger-full-access）

    刻意不叫 *-worker.ps1：本脚本的 CommandLine 里如果出现 "worker.ps1"，
    按命令行筛选时会把脚本自身也一起杀掉。
#>
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$ipc = Join-Path $here 'ipc'

$killed = 0
try {
    $procs = Get-WmiObject Win32_Process -Filter "Name='powershell.exe'" |
        Where-Object {
            $_.ProcessId -ne $PID -and
            $_.CommandLine -and
            $_.CommandLine -match '-File\s+"?[^"]*\\worker\.ps1"?' -and
            $_.CommandLine -notmatch 'gui-clean'
        }
    foreach ($p in $procs) {
        try { $p.Terminate() | Out-Null; $killed++; Write-Output ("  结束 pid=$($p.ProcessId)") } catch { }
    }
} catch { Write-Output ("  WMI 查询失败: " + $_.Exception.Message) }

Write-Output ("  共结束 $killed 个")

Remove-Item (Join-Path $ipc 'worker.lock') -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $ipc 'worker.pid') -Force -ErrorAction SilentlyContinue
Remove-Item $ipc -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $here 'worker.log') -Force -ErrorAction SilentlyContinue
Write-Output '  已清理锁、pid、ipc 目录和日志'
