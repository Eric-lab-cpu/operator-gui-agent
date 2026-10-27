<#
    cu-cli.ps1 —— computer-use 统一入口

    自动选执行方式：
      · worker 在线（心跳 10 秒内）→ 把请求投给沙盒外的 worker（能操作 Chrome / Excel / 微信）
      · worker 离线 → 在本地直接执行（沙盒内，只能操作经典 Win32）

    想强制某一种：-Local / -ViaWorker

    示例：
      .\cu-cli.ps1 info
      .\cu-cli.ps1 windows
      .\cu-cli.ps1 foreground
      .\cu-cli.ps1 shot -Path out.png             # 整屏
      .\cu-cli.ps1 shot -Hwnd 12345 -Path w.png   # 单窗口
      .\cu-cli.ps1 elements -Hwnd 12345 -Depth 8
      .\cu-cli.ps1 invoke -Hwnd 12345 -Name "计算"
      .\cu-cli.ps1 click -X 100 -Y 200 -Hwnd 12345
      .\cu-cli.ps1 type -Text "你好" -Hwnd 12345
      .\cu-cli.ps1 keys -Keys "{ENTER}" -Hwnd 12345
      .\cu-cli.ps1 focus -Hwnd 12345
      .\cu-cli.ps1 texts -Hwnd 12345
#>
param(
    [Parameter(Mandatory, Position = 0)][string]$Op,
    [long]$Hwnd = 0,
    [string]$Title = '',
    [string]$Name = '',
    [string]$Type = '',
    [string]$Class = '',
    [string]$Text = '',
    [string]$Keys = '',
    [int]$X = -1,
    [int]$Y = -1,
    [int]$Count = 1,
    [int]$Delta = -3,
    [string]$Path = '',
    [int]$Depth = 8,
    [int]$Max = 400,
    [int]$Timeout = 30,
    [int]$TargetPid = 0,
    [switch]$Verify,
    [switch]$Local,
    [switch]$ViaWorker
)

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$ipcReq = Join-Path $here 'ipc\req'
$ipcRes = Join-Path $here 'ipc\res'

function Test-WorkerOnline {
    $hb = Join-Path $here 'ipc\heartbeat.txt'
    if (-not (Test-Path $hb)) { return $false }
    try { $s = (Get-Content $hb -Raw -ErrorAction Stop).Trim() } catch { return $true }   # 被占用 = 正在写 = 活着
    if ($s -match '\|(.+)$') {
        try { return (((Get-Date) - [datetime]$Matches[1]).TotalSeconds -lt 10) } catch { return $false }
    }
    return $false
}

# ───────────── 路由：worker ─────────────
if (-not $Local) {
    $online = Test-WorkerOnline
    if ($online) {
        [void](New-Item -ItemType Directory -Force -Path $ipcReq)
        [void](New-Item -ItemType Directory -Force -Path $ipcRes)

        $req = @{ cmd = $Op }
        if ($Hwnd -ne 0) { $req.hwnd = $Hwnd }
        if ($Title) { $req.title = $Title }
        if ($Name) { $req.name = $Name }
        if ($Type) { $req.type = $Type }
        if ($Class) { $req.class = $Class }
        if ($Text) { $req.text = $Text }
        if ($Keys) { $req.keys = $Keys }
        if ($PSBoundParameters.ContainsKey('X')) { $req.x = $X }
        if ($PSBoundParameters.ContainsKey('Y')) { $req.y = $Y }
        if ($PSBoundParameters.ContainsKey('Count')) { $req.count = $Count }
        if ($PSBoundParameters.ContainsKey('Delta')) { $req.delta = $Delta }
        if ($Path) { $req.path = $Path }
        if ($Depth) { $req.depth = $Depth }
        if ($Max) { $req.max = $Max }
        if ($TargetPid -ne 0) { $req.pid = $TargetPid }
        if ($Verify) { $req.verify = $true }

        $id = [guid]::NewGuid().ToString('N')
        $rf = Join-Path $ipcReq "$id.json"
        $sf = Join-Path $ipcRes "$id.json"
        [System.IO.File]::WriteAllText($rf, ($req | ConvertTo-Json -Compress -Depth 5), (New-Object System.Text.UTF8Encoding($true)))

        $deadline = (Get-Date).AddSeconds($Timeout)
        while ((Get-Date) -lt $deadline) {
            if (Test-Path $sf) {
                Start-Sleep -Milliseconds 50
                $txt = [System.IO.File]::ReadAllText($sf, [System.Text.Encoding]::UTF8)
                Remove-Item $sf -Force -ErrorAction SilentlyContinue
                Write-Output $txt.Trim()
                exit 0
            }
            Start-Sleep -Milliseconds 70
        }
        Remove-Item $rf -Force -ErrorAction SilentlyContinue
        Write-Output (@{ ok = $false; error = "worker 等结果超时（${Timeout}s）" } | ConvertTo-Json -Compress)
        exit 1
    }
    if ($ViaWorker) {
        Write-Output (@{ ok = $false; error = '要求走 worker，但 worker 不在线（先跑 worker-via-task.ps1）' } | ConvertTo-Json -Compress)
        exit 1
    }
}

# ───────────── 路由：本地 ─────────────
. (Join-Path $here 'cu.ps1')

try {
    # 本地后端也支持动作后校验：动作前先取状态指纹
    $beforeFp = $null
    if ($Verify -and $Hwnd -ne 0 -and @('click','type','keys','invoke') -contains $Op) {
        $beforeFp = Get-CUStateFingerprint -Hwnd $Hwnd
    }

    $data = switch ($Op) {
        'ping'       { @{ mode = 'local'; pid = $PID; session = (Get-Process -Id $PID).SessionId } }
        'info'       { Get-CUInfo }
        'windows'    { @(Get-CUWindows -Title $(if ($Title) { $Title } else { '*' }) | Select-Object Hwnd, Pid, Process, Title, X, Y, Width, Height) }
        'foreground' { Get-CUForeground }
        'state'      { if ($Hwnd -eq 0) { throw 'state 需要 -Hwnd' }; Get-CUStateFingerprint -Hwnd $Hwnd }
        'health'     { Get-CUCoordinateHealth -ProbeHwnd $Hwnd }
        'shot'       {
            $a = @{ Path = $Path }
            if ($Hwnd -ne 0) { $a['Hwnd'] = $Hwnd }
            if ($Title) { $a['Title'] = $Title }
            Get-CUScreenshot @a
        }
        'elements'   {
            $a = @{ Depth = $Depth; Max = $Max }
            if ($Hwnd -ne 0) { $a['Hwnd'] = $Hwnd } elseif ($Title) { $a['Title'] = $Title }
            @(Get-CUElements @a)
        }
        'texts'      {
            $a = @{}
            if ($Hwnd -ne 0) { $a['Hwnd'] = $Hwnd } elseif ($Title) { $a['Title'] = $Title }
            @(Get-CUText @a)
        }
        'find'       {
            $a = @{ NamePattern = $Name }
            if ($Class) { $a['ClassPattern'] = $Class }
            if ($Type) { $a['Type'] = $Type }
            if ($Hwnd -ne 0) { $a['Hwnd'] = $Hwnd }
            Find-CUElement @a
        }
        'invoke'     {
            $a = @{ NamePattern = $Name }
            if ($Hwnd -ne 0) { $a['Hwnd'] = $Hwnd }
            Invoke-CUElement @a
        }
        'click'      {
            $a = @{ Count = $Count }
            if ($PSBoundParameters.ContainsKey('X')) { $a['X'] = $X }
            if ($PSBoundParameters.ContainsKey('Y')) { $a['Y'] = $Y }
            if ($Hwnd -ne 0) { $a['ExpectHwnd'] = $Hwnd }
            Invoke-CUClick @a
        }
        'type'       {
            if ($Hwnd -ne 0) { Enable-CUForeground -Hwnd $Hwnd; Assert-CUForeground -Hwnd $Hwnd -Action 'Type' }
            Set-CUText -Text $Text
        }
        'keys'       {
            if ($Hwnd -ne 0) { Enable-CUForeground -Hwnd $Hwnd; Assert-CUForeground -Hwnd $Hwnd -Action 'Keys' }
            Send-CUKeys -Keys $Keys
            @{ sent = $Keys }
        }
        'scroll'     { Invoke-CUScroll -Delta $Delta }
        'focus'      {
            $a = @{}
            if ($Hwnd -ne 0) { $a['Hwnd'] = $Hwnd }
            Focus-CUWindow @a
        }
        'waitwin'    { Wait-CUWindow -Title $Title -TimeoutSec $Timeout }
        default      { throw "未知操作: $Op" }
    }
    if ($beforeFp) {
        Start-Sleep -Milliseconds 350
        $afterFp = Get-CUStateFingerprint -Hwnd $Hwnd
        $changed = ($beforeFp.Hash -ne $afterFp.Hash)
        $data = @{ result = $data; changed = $changed; beforeHash = $beforeFp.Hash; afterHash = $afterFp.Hash; beforeCount = $beforeFp.ElementCount; afterCount = $afterFp.ElementCount }
        if (-not $changed) { $data['warning'] = '动作已执行，但界面 350ms 内无变化' }
    }

    Write-Output (@{ ok = $true; backend = 'local'; data = $data } | ConvertTo-Json -Compress -Depth 6)
} catch {
    Write-Output (@{ ok = $false; backend = 'local'; error = $_.Exception.Message } | ConvertTo-Json -Compress)
    exit 1
}
