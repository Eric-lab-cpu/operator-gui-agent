<#
    worker.ps1 —— 沙盒外的 GUI 执行器（文件 IPC 版）

    为什么不用命名管道：跨完整性级别连接会被 ACL 拦，实例名冲突时的错误也难排查。
    文件 IPC 走的是工作区目录，两边都有权限，出问题能直接看文件。

    协议：
      ipc/req/<id>.json   请求
      ipc/res/<id>.json   响应
      ipc/heartbeat.txt   心跳（pid + 时间）
#>
param(
    [string]$IpcDir = ''
)

$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'cu.ps1')

if (-not $IpcDir) { $IpcDir = Join-Path $here 'ipc' }
$reqDir = Join-Path $IpcDir 'req'
$resDir = Join-Path $IpcDir 'res'
$hbFile = Join-Path $IpcDir 'heartbeat.txt'
$logFile = Join-Path $here 'worker.log'

[void](New-Item -ItemType Directory -Force -Path $reqDir)
[void](New-Item -ItemType Directory -Force -Path $resDir)
# 单实例锁：拿不到就退出，避免两个 worker 抢同一批请求
$lockPath = Join-Path $IpcDir 'worker.lock'
try {
    $script:Lock = [System.IO.File]::Open($lockPath, 'OpenOrCreate', 'ReadWrite', 'None')
} catch {
    exit 0
}
Set-Content -LiteralPath (Join-Path $IpcDir 'worker.pid') -Value $PID -Encoding UTF8

# 清掉上次残留的请求
Get-ChildItem $reqDir -Filter *.json -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

function Write-Log([string]$msg) {
    try { Add-Content -LiteralPath $logFile -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg) -Encoding UTF8 } catch { }
}

function Invoke-Verified([long]$hwnd, [scriptblock]$action) {
    <# 动作前后各取一次状态指纹，确认界面真的响应了 #>
    $before = Get-CUStateFingerprint -Hwnd $hwnd
    $r = & $action
    Start-Sleep -Milliseconds 350
    $after = Get-CUStateFingerprint -Hwnd $hwnd
    return @{
        result      = $r
        changed     = ($before.Hash -ne $after.Hash)
        beforeHash  = $before.Hash
        afterHash   = $after.Hash
        beforeCount = $before.ElementCount
        afterCount  = $after.ElementCount
    }
}
function Handle-Request($req) {
    $cmd = [string]$req.cmd
    switch ($cmd) {

        'ping' {
            $id = [Security.Principal.WindowsIdentity]::GetCurrent()
            return @{ ok = $true; data = @{
                pid = $PID
                session = (Get-Process -Id $PID).SessionId
                user = $id.Name
                admin = (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
                time = (Get-Date).ToString('s')
            } }
        }

        'write-test' {
            $r = @{}
            foreach ($k in 'APPDATA', 'LOCALAPPDATA', 'TEMP') {
                $p = [Environment]::GetEnvironmentVariable($k)
                try {
                    $f = Join-Path $p 'dsh-worker-test.txt'
                    Set-Content -LiteralPath $f -Value 'ok' -ErrorAction Stop
                    Remove-Item $f -Force
                    $r[$k] = 'OK'
                } catch { $r[$k] = 'DENY' }
            }
            return @{ ok = $true; data = $r }
        }

        'info' { return @{ ok = $true; data = (Get-CUInfo) } }

        'windows' {
            $pattern = '*'
            if ($req.title) { $pattern = [string]$req.title }
            return @{ ok = $true; data = @(Get-CUWindows -Title $pattern | Select-Object Hwnd, Pid, Process, Title, X, Y, Width, Height) }
        }

        'launch' {
            $argList = @()
            if ($req.args) { $argList = @($req.args) }
            if ($argList.Count -gt 0) { $p = Start-Process -FilePath $req.path -ArgumentList $argList -PassThru }
            else { $p = Start-Process -FilePath $req.path -PassThru }
            return @{ ok = $true; data = @{ pid = $p.Id; path = $req.path } }
        }

        'kill' {
            $k = $false
            try { Stop-Process -Id ([int]$req.pid) -Force -ErrorAction Stop; $k = $true } catch { }
            return @{ ok = $k; data = @{ pid = $req.pid } }
        }

        'shot' {
            $a = @{ Path = [string]$req.path }
            if ($req.hwnd) { $a['Hwnd'] = [long]$req.hwnd }
            if ($req.title) { $a['Title'] = [string]$req.title }
            if ($req.focus) { $a['Focus'] = $true }
            return @{ ok = $true; data = (Get-CUScreenshot @a) }
        }

        'elements' {
            $d = 8; if ($req.depth) { $d = [int]$req.depth }
            $m = 400; if ($req.max) { $m = [int]$req.max }
            $a = @{ Depth = $d; Max = $m }
            if ($req.hwnd) { $a['Hwnd'] = [long]$req.hwnd }
            if ($req.title) { $a['Title'] = [string]$req.title }
            return @{ ok = $true; data = @(Get-CUElements @a) }
        }

        'texts' {
            $a = @{}
            if ($req.hwnd) { $a['Hwnd'] = [long]$req.hwnd }
            return @{ ok = $true; data = @(Get-CUText @a) }
        }

        'find' {
            $a = @{ NamePattern = [string]$req.name }
            if ($req.hwnd) { $a['Hwnd'] = [long]$req.hwnd }
            if ($req.class) { $a['ClassPattern'] = [string]$req.class }
            if ($req.type) { $a['Type'] = [string]$req.type }
            return @{ ok = $true; data = (Find-CUElement @a) }
        }

        'invoke' {
            $a = @{ NamePattern = [string]$req.name }
            if ($req.hwnd) { $a['Hwnd'] = [long]$req.hwnd }
            if ($req.type) { $a['Type'] = [string]$req.type }
            if ($req.class) { $a['ClassPattern'] = [string]$req.class }
            if ($req.verify -and $req.hwnd) {
                $w = Invoke-Verified ([long]$req.hwnd) { Invoke-CUElement @a }
                if (-not $w.changed) { $w['warning'] = '动作已执行，但界面 350ms 内无变化' }
                return @{ ok = $true; data = $w }
            }
            return @{ ok = $true; data = (Invoke-CUElement @a) }
        }

        'close' {
            if (-not $req.hwnd) { return @{ ok = $false; error = 'close 需要 hwnd' } }
            $r = Close-CUWindow -Hwnd ([long]$req.hwnd)
            return @{ ok = $true; data = $r }
        }

        'click' {
            $a = @{ Count = 1 }
            if ($null -ne $req.x) { $a['X'] = [int]$req.x }
            if ($null -ne $req.y) { $a['Y'] = [int]$req.y }
            if ($req.count) { $a['Count'] = [int]$req.count }
            if ($req.button) { $a['Button'] = [string]$req.button }
            if ($req.hwnd) { $a['ExpectHwnd'] = [long]$req.hwnd }
            if ($req.verify -and $req.hwnd) {
                $w = Invoke-Verified ([long]$req.hwnd) { Invoke-CUClick @a }
                if (-not $w.changed) { $w['warning'] = '点击已执行，但界面 350ms 内无变化' }
                return @{ ok = $true; data = $w }
            }
            return @{ ok = $true; data = (Invoke-CUClick @a) }
        }

        'foreground' { return @{ ok = $true; data = (Get-CUForeground) } }

        'state' {
            if (-not $req.hwnd) { return @{ ok = $false; error = 'state 需要 hwnd' } }
            return @{ ok = $true; data = (Get-CUStateFingerprint -Hwnd ([long]$req.hwnd)) }
        }

        'health' {
            $probe = 0
            if ($req.hwnd) { $probe = [long]$req.hwnd }
            return @{ ok = $true; data = (Get-CUCoordinateHealth -ProbeHwnd $probe) }
        }
        'type' {
            # 键盘输入同样依赖前台窗口，必须先校验，否则会打进别的程序
            if ($req.hwnd) {
                [void](Enable-CUForeground -Hwnd ([long]$req.hwnd))
                [void](Assert-CUForeground -Hwnd ([long]$req.hwnd) -Action 'Type')
            }
            if ($req.verify -and $req.hwnd) {
                $w = Invoke-Verified ([long]$req.hwnd) { Set-CUText -Text ([string]$req.text) }
                if (-not $w.changed) { $w['warning'] = '文本已输入，但界面 350ms 内无变化' }
                return @{ ok = $true; data = $w }
            }
            return @{ ok = $true; data = (Set-CUText -Text ([string]$req.text)) }
        }

        'keys' {
            if ($req.hwnd) {
                [void](Enable-CUForeground -Hwnd ([long]$req.hwnd))
                [void](Assert-CUForeground -Hwnd ([long]$req.hwnd) -Action 'Keys')
            }
            if ($req.verify -and $req.hwnd) {
                $w = Invoke-Verified ([long]$req.hwnd) { Send-CUKeys -Keys ([string]$req.keys); @{ sent = $req.keys } }
                if (-not $w.changed) { $w['warning'] = '按键已发出，但界面 350ms 内无变化（可能被忽略或不需要视觉反馈）' }
                return @{ ok = $true; data = $w }
            }
            Send-CUKeys -Keys ([string]$req.keys)
            return @{ ok = $true; data = @{ sent = $req.keys } }
        }

        'scroll' {
            $a = @{ Delta = -3 }
            if ($req.delta) { $a['Delta'] = [int]$req.delta }
            if ($null -ne $req.x -and $null -ne $req.y) { $a['X'] = [int]$req.x; $a['Y'] = [int]$req.y }
            return @{ ok = $true; data = (Invoke-CUScroll @a) }
        }

        'focus' {
            $a = @{}
            if ($req.hwnd) { $a['Hwnd'] = [long]$req.hwnd }
            return @{ ok = $true; data = (Focus-CUWindow @a) }
        }

        'waitwin' {
            $t = 20; if ($req.timeout) { $t = [int]$req.timeout }
            return @{ ok = $true; data = (Wait-CUWindow -Title ([string]$req.title) -TimeoutSec $t) }
        }

        'quit' { $script:ShouldQuit = $true; return @{ ok = $true; data = @{ bye = $true } } }

        default { return @{ ok = $false; error = "unknown cmd: $cmd" } }
    }
}

Write-Log ("worker 启动 pid=$PID session=$((Get-Process -Id $PID).SessionId) ipc=$IpcDir")

$script:ShouldQuit = $false
while (-not $script:ShouldQuit) {
    try { Set-Content -LiteralPath $hbFile -Value ("{0}|{1}" -f $PID, (Get-Date).ToString('o')) -Encoding UTF8 -ErrorAction SilentlyContinue } catch { }

    $files = @(Get-ChildItem $reqDir -Filter *.json -ErrorAction SilentlyContinue | Sort-Object Name)
    foreach ($f in $files) {
        $req = $null
        try { $req = (Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8) | ConvertFrom-Json } catch { }

        $resp = $null
        if (-not $req) { $resp = @{ ok = $false; error = 'bad json' } }
        else {
            try { $resp = Handle-Request $req }
            catch { $resp = @{ ok = $false; error = $_.Exception.Message } }
        }

        try {
            $out = Join-Path $resDir ($f.BaseName + '.json')
            ($resp | ConvertTo-Json -Compress -Depth 6) | Set-Content -LiteralPath $out -Encoding UTF8 -ErrorAction Stop
        } catch { Write-Log ("写结果失败: " + $_.Exception.Message) }
        Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Milliseconds 120
}

Write-Log 'worker 退出'
