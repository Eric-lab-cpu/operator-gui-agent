<#
    gui.ps1 —— 沙盒内给 GUI worker 发指令（文件 IPC 版）

    用法：
      powershell -File gui.ps1 -Op ping
      powershell -File gui.ps1 -Op windows
      powershell -File gui.ps1 -Op launch -Path "C:\...\chrome.exe" -ArgList @('--new-window','https://…')
      powershell -File gui.ps1 -Op shot -Path out.png -Hwnd 12345
      powershell -File gui.ps1 -Op click -X 100 -Y 200
      powershell -File gui.ps1 -Op type -Text "你好"
      powershell -File gui.ps1 -Op invoke -Name "下一页*" -Hwnd 12345
#>
param(
    [Parameter(Mandatory)][string]$Op,
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
    [string[]]$ArgList = @(),
    [int]$TargetPid = 0,
    [int]$Depth = 8,
    [int]$Max = 400,
    [int]$Timeout = 30,
    [string]$IpcDir = '',
    [switch]$Verify
)

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $IpcDir) { $IpcDir = Join-Path $here 'ipc' }
$reqDir = Join-Path $IpcDir 'req'
$resDir = Join-Path $IpcDir 'res'
[void](New-Item -ItemType Directory -Force -Path $reqDir)
[void](New-Item -ItemType Directory -Force -Path $resDir)

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
if ($ArgList.Count -gt 0) { $req.args = $ArgList }
if ($TargetPid -ne 0) { $req.pid = $TargetPid }
if ($PSBoundParameters.ContainsKey('Depth')) { $req.depth = $Depth }
if ($PSBoundParameters.ContainsKey('Max')) { $req.max = $Max }
if ($PSBoundParameters.ContainsKey('Timeout')) { $req.timeout = $Timeout }
if ($Verify) { $req.verify = $true }

# worker 是否在线
$hb = Join-Path $IpcDir 'heartbeat.txt'
$alive = $false
if (Test-Path $hb) {
    try { $stamp = Get-Content $hb -Raw -ErrorAction Stop } catch { $stamp = ('|' + (Get-Date).ToString('o')) }
    if ($stamp -match '\|(.+)$') {
        try { if (((Get-Date) - [datetime]$Matches[1]).TotalSeconds -lt 10) { $alive = $true } } catch { }
    }
}
if (-not $alive -and $Op -ne 'ping') {
    Write-Output (@{ ok = $false; error = 'worker 离线（心跳超时），先跑 start-worker.ps1' } | ConvertTo-Json -Compress)
    exit 1
}

$id = [guid]::NewGuid().ToString('N')
$reqFile = Join-Path $reqDir "$id.json"
$resFile = Join-Path $resDir "$id.json"
# 带 BOM 写，保证 5.1 的 ConvertFrom-Json 读中文不乱码
[System.IO.File]::WriteAllText($reqFile, ($req | ConvertTo-Json -Compress -Depth 4), (New-Object System.Text.UTF8Encoding($true)))

$deadline = (Get-Date).AddSeconds($Timeout)
while ((Get-Date) -lt $deadline) {
    if (Test-Path $resFile) {
        Start-Sleep -Milliseconds 40
        $txt = [System.IO.File]::ReadAllText($resFile, [System.Text.Encoding]::UTF8)
        Remove-Item $resFile -Force -ErrorAction SilentlyContinue
        Write-Output $txt.Trim()
        exit 0
    }
    Start-Sleep -Milliseconds 80
}

Remove-Item $reqFile -Force -ErrorAction SilentlyContinue
Write-Output (@{ ok = $false; error = "等结果超时（${Timeout}s）" } | ConvertTo-Json -Compress)
exit 1
