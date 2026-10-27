<#
.SYNOPSIS
    cu.ps1 —— 零依赖的 Windows「电脑操作」工具集（PowerShell 5.1 / .NET Framework）

.DESCRIPTION
    让 Agent 具备「看屏幕 → 决定动作 → 动鼠标键盘 → 再看屏幕验证」的闭环能力。
    不装 pyautogui / 不装 node 包，只依赖 Windows 自带的 user32 + UIAutomation。

    两条操作通道：
      1) 像素通道：截图 + 坐标点击（任何程序都能点，包括 Canvas / 游戏 / 远程桌面）
      2) 控件通道：UIAutomation 树（读得到控件的名字/类型/位置），按名字直接 Invoke，
         不需要算坐标，窗口挪了、分辨率变了也不会点错。优先用这条。

.USAGE
    . "C:\path\to\cu.ps1"

    Get-CUInfo                                   # 屏幕尺寸 / DPI / 光标位置
    Get-CUWindows                                # 当前可见窗口列表
    Get-CUScreenshot -Path .\s.png               # 整屏截图
    Get-CUScreenshot -Path .\w.png -Title '计算器'  # 只截某个窗口
    Get-CUElements -Title '*记事本*' | Format-Table   # 读控件树
    Invoke-CUClick -NamePattern '确定'            # 按名字点按钮（推荐）
    Invoke-CUClick -X 500 -Y 300                  # 按坐标点
    Set-CUText '你好，世界'                        # 输入中文（剪贴板粘贴，最稳）
    Send-CUKeys '^s'                             # 发快捷键
    Invoke-CUDrag -X1 100 -Y1 100 -X2 600 -Y2 400
    Invoke-CUScroll -Delta -5
#>

$script:CUReady = $false

function Initialize-CU {
    if ($script:CUReady) { return }

    if (-not ('CUWin32' -as [type])) {
        # 优先加载预编译好的 DLL：运行期不再调用 csc（省 300~800ms，也不依赖 TEMP 可写）
        $dll = Join-Path (Split-Path -Parent $PSScriptRoot) 'bin\CUWin32.dll'
        if (Test-Path $dll) {
            try {
                Add-Type -Path $dll -ErrorAction Stop
                $script:CUReady = $true
                return
            } catch { }   # 加载失败（权限/位置）就走下面的编译路径
        }
        $src = @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public class CUWin32
{
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }

    public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")] public static extern int GetSystemMetrics(int n);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, int dx, int dy, int data, UIntPtr extraInfo);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr lParam);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern IntPtr GetThreadDpiAwarenessContext();
    [DllImport("user32.dll")] public static extern bool AreDpiAwarenessContextsEqual(IntPtr a, IntPtr b);
    [DllImport("user32.dll")] public static extern uint GetDpiForSystem();
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);

    public class WInfo
    {
        public long Hwnd;
        public uint Pid;
        public string Title;
        public string Cls;
        public int X, Y, W, H;
    }

    public static List<WInfo> Windows()
    {
        var list = new List<WInfo>();
        EnumWindows(delegate(IntPtr h, IntPtr l)
        {
            if (!IsWindowVisible(h)) return true;
            var sb = new StringBuilder(512);
            GetWindowText(h, sb, 512);
            var t = sb.ToString();
            if (t.Length == 0) return true;
            var cb = new StringBuilder(256);
            GetClassName(h, cb, 256);
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            RECT r;
            GetWindowRect(h, out r);
            list.Add(new WInfo { Hwnd = (long)h, Pid = pid, Title = t, Cls = cb.ToString(), X = r.Left, Y = r.Top, W = r.Right - r.Left, H = r.Bottom - r.Top });
            return true;
        }, IntPtr.Zero);
        return list;
    }
}
'@
        Add-Type -TypeDefinition $src -Language CSharp -ErrorAction Stop
    }

    # DPI 感知必须在加载任何 UI 程序集之前设好：否则截图是放大后的模糊图，坐标也和真实像素对不上
    if (-not $script:CUDpiReady) {
        $ok = $false
        try { $ok = [CUWin32]::SetProcessDpiAwarenessContext([IntPtr](-4)) } catch { }
        if (-not $ok) { try { $ok = [CUWin32]::SetProcessDPIAware() } catch { } }
        $script:CUDpiReady = $true
    }

    foreach ($a in 'System.Windows.Forms', 'System.Drawing', 'UIAutomationClient', 'UIAutomationTypes') {
        try { Add-Type -AssemblyName $a -ErrorAction Stop }
        catch { throw "无法加载程序集 $a : $($_.Exception.Message)" }
    }

    $script:CUReady = $true
}

# ───────────────────────────── 观察 ─────────────────────────────

function Get-CUInfo {
    <# 屏幕、DPI、光标位置、是否有多显示器 #>
    Initialize-CU
    $p = New-Object CUWin32+POINT
    [void][CUWin32]::GetCursorPos([ref]$p)
    [pscustomobject]@{
        PrimaryWidth  = [CUWin32]::GetSystemMetrics(0)
        PrimaryHeight = [CUWin32]::GetSystemMetrics(1)
        VirtualX      = [CUWin32]::GetSystemMetrics(76)
        VirtualY      = [CUWin32]::GetSystemMetrics(77)
        VirtualWidth  = [CUWin32]::GetSystemMetrics(78)
        VirtualHeight = [CUWin32]::GetSystemMetrics(79)
        MonitorCount  = [CUWin32]::GetSystemMetrics(80)
        CursorX       = $p.X
        CursorY       = $p.Y
    }
}

function Get-CUWindows {
    <# 列出当前可见的顶层窗口 #>
    param([string]$TitlePattern = '*', [switch]$IncludeUntitled)
    Initialize-CU
    $all = [CUWin32]::Windows()
    foreach ($w in $all) {
        if ($w.W -le 0 -or $w.H -le 0) { continue }
        if (-not $IncludeUntitled -and [string]::IsNullOrWhiteSpace($w.Title)) { continue }
        if ($w.Title -notlike $TitlePattern) { continue }
        $proc = try { (Get-Process -Id $w.Pid -ErrorAction Stop).ProcessName } catch { '?' }
        [pscustomobject]@{
            Hwnd    = $w.Hwnd
            Pid     = $w.Pid
            Process = $proc
            Title   = $w.Title
            Class   = $w.Cls
            X       = $w.X
            Y       = $w.Y
            Width   = $w.W
            Height  = $w.H
            Minimized = [CUWin32]::IsIconic([IntPtr]$w.Hwnd)
        }
    }
}

function Resolve-CUWindow {
    param([long]$Hwnd = 0, [string]$TitlePattern = '*')
    if ($Hwnd -ne 0) { return (Get-CUWindows -TitlePattern '*' -IncludeUntitled | Where-Object { $_.Hwnd -eq $Hwnd } | Select-Object -First 1) }
    $w = Get-CUWindows -TitlePattern $TitlePattern | Select-Object -First 1
    if (-not $w) { throw "找不到标题匹配 '$TitlePattern' 的窗口。先跑 Get-CUWindows 看看有哪些。" }
    return $w
}

function Get-CUScreenshot {
    <# 截图：-Hwnd/-Title 截单个窗口，否则整屏。返回文件路径 #>
    param(
        [string]$Path,
        [long]$Hwnd = 0,
        [string]$Title,
        [switch]$Focus,
        [ValidateSet('screen', 'print')] [string]$Method = 'screen'
    )
    Initialize-CU

    if (-not $Path) {
        $dir = Join-Path $env:TEMP 'cu-shots'
        [void](New-Item -ItemType Directory -Force -Path $dir)
        $Path = Join-Path $dir ("shot-{0}.png" -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
    }
    if (-not [System.IO.Path]::IsPathRooted($Path)) { $Path = Join-Path (Get-Location).Path $Path }
    $Path = [System.IO.Path]::GetFullPath($Path)
    $dirName = Split-Path -Parent $Path
    if ($dirName -and -not (Test-Path $dirName)) { [void](New-Item -ItemType Directory -Force -Path $dirName) }

    $rect = $null
    if ($Hwnd -ne 0 -or $Title) {
        $w = Resolve-CUWindow -Hwnd $Hwnd -TitlePattern $Title
        $Hwnd = $w.Hwnd
        $rect = @{ X = $w.X; Y = $w.Y; W = $w.Width; H = $w.Height }
        if ($Focus) { Focus-CUWindow -Hwnd $Hwnd -Quiet; Start-Sleep -Milliseconds 150 }
    } else {
        $rect = @{
            X = [CUWin32]::GetSystemMetrics(76); Y = [CUWin32]::GetSystemMetrics(77)
            W = [CUWin32]::GetSystemMetrics(78); H = [CUWin32]::GetSystemMetrics(79)
        }
    }

    $bmp = New-Object System.Drawing.Bitmap($rect.W, $rect.H)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $printed = $false
        if ($Method -eq 'print' -and $Hwnd -ne 0) {
            $hdc = $g.GetHdc()
            try { $printed = [CUWin32]::PrintWindow([IntPtr]$Hwnd, $hdc, 2) } finally { $g.ReleaseHdc($hdc) }
        }
        if (-not $printed) {
            $g.CopyFromScreen($rect.X, $rect.Y, 0, 0, (New-Object System.Drawing.Size($rect.W, $rect.H)))
        }
        $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $g.Dispose(); $bmp.Dispose()
    }

    [pscustomobject]@{ Path = $Path; Width = $rect.W; Height = $rect.H; X = $rect.X; Y = $rect.Y }
}

# ─────────────────────── 控件通道（UIA，推荐） ───────────────────────

function ConvertTo-SafeInt($v) {
    <# UIA 对某些元素会返回 Infinity / NaN，直接 [int] 会抛异常 #>
    try {
        $d = [double]$v
        if ([double]::IsNaN($d) -or [double]::IsInfinity($d)) { return 0 }
        if ($d -gt 2147483647) { return 2147483647 }
        if ($d -lt -2147483648) { return -2147483648 }
        return [int]$d
    } catch { return 0 }
}

function Get-CUElements {
    <#
        读取窗口内的 UIA 控件树。这是「不靠猜坐标」的关键：
        拿到 Name / ControlType / 位置 / 可用模式，就能精确定位按钮、输入框、列表项。
    #>
    param(
        [long]$Hwnd = 0,
        [string]$Title = '*',
        [int]$Depth = 6,
        [int]$Max = 400,
        [string]$NamePattern = '*'
    )
    Initialize-CU

    if ($Hwnd -ne 0) {
        $root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$Hwnd)
    } else {
        $w = Resolve-CUWindow -TitlePattern $Title
        $root = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$w.Hwnd)
    }
    if (-not $root) { throw '拿不到窗口的 UIA 根节点（可能不是标准窗口）' }

    $results = New-Object System.Collections.ArrayList
    $walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker

    function Walk($el, $level, $path) {
        if ($results.Count -ge $Max) { return }

        $node = $null
        try { $node = $el.Current } catch { return }
        if (-not $node) { return }

        if ($node.Name -like $NamePattern) {
            $r = $node.BoundingRectangle
            [void]$results.Add([pscustomobject]@{
                Level   = $level
                Type    = ($node.ControlType.ProgrammaticName -replace 'ControlType\.', '')
                Name    = $node.Name
                AutoId  = $node.AutomationId
                'Class' = $node.ClassName
                X       = (ConvertTo-SafeInt $r.X)
                Y       = (ConvertTo-SafeInt $r.Y)
                W       = (ConvertTo-SafeInt $r.Width)
                H       = (ConvertTo-SafeInt $r.Height)
                Enabled = $node.IsEnabled
                Offscreen = $node.IsOffscreen
                Patterns = ((Get-CUPatterns $el) -join ',')
            })
        }

        if ($level -ge $Depth) { return }
        $child = $walker.GetFirstChild($el)
        while ($child -ne $null) {
            Walk $child ($level + 1) "$path/$($node.Name)"
            if ($results.Count -ge $Max) { return }
            try { $child = $walker.GetNextSibling($child) } catch { break }
        }
    }

    Walk $root 0 ''
    return $results
}

function Get-CUPatterns($el) {
    $found = @()
    $obj = $null
    $types = @{
        'Invoke'        = [System.Windows.Automation.InvokePattern]::Pattern
        'Value'         = [System.Windows.Automation.ValuePattern]::Pattern
        'Toggle'        = [System.Windows.Automation.TogglePattern]::Pattern
        'SelectionItem' = [System.Windows.Automation.SelectionItemPattern]::Pattern
        'ExpandCollapse'= [System.Windows.Automation.ExpandCollapsePattern]::Pattern
        'Scroll'        = [System.Windows.Automation.ScrollPattern]::Pattern
        'Text'          = [System.Windows.Automation.TextPattern]::Pattern
    }
    foreach ($k in $types.Keys) {
        $obj = $null
        try { if ($el.TryGetCurrentPattern($types[$k], [ref]$obj)) { $found += $k } } catch { }
    }
    return $found
}

function Find-CUElement {
    <# 在窗口里按 名字 / 类型 / 类名 找控件，返回第一个匹配 #>
    param(
        [string]$NamePattern = '*',
        [string]$Type,
        [string]$ClassPattern,
        [long]$Hwnd = 0,
        [string]$Title = '*',
        [int]$TimeoutMs = 0
    )
    $deadline = (Get-Date).AddMilliseconds($TimeoutMs)
    do {
        $els = Get-CUElements -Hwnd $Hwnd -Title $Title -Depth 12 -Max 2000 -NamePattern '*'
        $hit = $els | Where-Object {
            ($_.Name -like $NamePattern) -and
            (-not $Type -or $_.Type -eq $Type) -and
            (-not $ClassPattern -or $_.'Class' -like $ClassPattern) -and
            $_.W -gt 0 -and $_.H -gt 0
        } | Select-Object -First 1
        if ($hit) { return $hit }
        if ((Get-Date) -ge $deadline) { break }
        Start-Sleep -Milliseconds 300
    } while ($true)
    return $null
}

function Invoke-CUElement {
    <# 对控件执行动作：优先用 UIA 模式（Invoke），失败再退回鼠标点击中心 #>
    param(
        [string]$NamePattern = '*',
        [string]$Type,
        [string]$ClassPattern,
        [long]$Hwnd = 0,
        [string]$Title = '*',
        [ValidateSet('invoke', 'click')] [string]$Mode = 'invoke'
    )
    Initialize-CU
    $el = Find-CUElement -NamePattern $NamePattern -Type $Type -ClassPattern $ClassPattern -Hwnd $Hwnd -Title $Title
    if (-not $el) { throw "找不到控件：Name like '$NamePattern' / Class like '$ClassPattern'" }

    if ($Mode -eq 'invoke' -and $el.Patterns -match 'Invoke') {
        $ae = Get-CUAutomationElement -Item $el -Hwnd $Hwnd -Title $Title
        $p = $null
        if ($ae -and $ae.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$p)) {
            $p.Invoke()
            return [pscustomobject]@{ Action = 'Invoke(UI Automation)'; Name = $el.Name; Type = $el.Type }
        }
    }

    $cx = [int]($el.X + $el.W / 2)
    $cy = [int]($el.Y + $el.H / 2)
    # 鼠标点击依赖前台窗口；目标不在前台就拒绝，避免点到别的程序上
    if ($Hwnd -ne 0) { [void](Assert-CUForeground -Hwnd $Hwnd -Action 'MouseClick') }
    Invoke-CUClick -X $cx -Y $cy | Out-Null
    return [pscustomobject]@{ Action = 'MouseClick'; Name = $el.Name; Type = $el.Type; X = $cx; Y = $cy }
}

function Get-CUAutomationElement {
    param($Item, [long]$Hwnd = 0, [string]$Title = '*')
    if ($Hwnd -ne 0) { return [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$Hwnd) }
    $w = Resolve-CUWindow -TitlePattern $Title
    return [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$w.Hwnd)
}

function Get-CUText {
    <# 读窗口里的全部可读文本（日志、错误提示、结果值） #>
    param([long]$Hwnd = 0, [string]$Title = '*')
    $els = Get-CUElements -Hwnd $Hwnd -Title $Title -Depth 12 -Max 2000
    $els | Where-Object { $_.Name } | Select-Object -ExpandProperty Name -Unique
}

function Set-CUValue {
    <# 往输入框写值：UIA ValuePattern 直接写，不需要先点中 #>
    param([string]$NamePattern, [string]$Value, [long]$Hwnd = 0, [string]$Title = '*')
    Initialize-CU
    $el = Find-CUElement -NamePattern $NamePattern -Hwnd $Hwnd -Title $Title
    if (-not $el) { throw "找不到控件：$NamePattern" }
    if ($el.Patterns -notmatch 'Value') { throw "控件 '$($el.Name)' 不支持 ValuePattern，改用 Invoke-CUElement 点它再 Set-CUText" }
    $root = Get-CUAutomationElement -Hwnd $Hwnd -Title $Title
    $ae = Find-CUAutomationElementDeep -Root $root -NamePattern $NamePattern
    $vp = $null
    if ($ae -and $ae.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$vp)) {
        $vp.SetValue($Value)
        return [pscustomobject]@{ Action = 'SetValue'; Name = $el.Name; Value = $Value }
    }
    throw 'SetValue 失败'
}

function Find-CUAutomationElementDeep {
    param($Root, [string]$NamePattern)
    $cond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::NameProperty, $NamePattern)
    $all = $Root.FindAll([System.Windows.Automation.TreeScope]::Descendants,
        [System.Windows.Automation.Condition]::TrueCondition)
    foreach ($a in $all) {
        if ($a.Current.Name -like $NamePattern) { return $a }
    }
    return $null
}

# ─────────────────────────── 动作：鼠标 ───────────────────────────

function Set-CUCursor {
    param([int]$X, [int]$Y)
    Initialize-CU
    [void][CUWin32]::SetCursorPos($X, $Y)
}

function Invoke-CUClick {
    <# 坐标点击。传 -ExpectHwnd 会在点击前校验目标窗口是否在前台，避免点到别的程序上 #>
    param(
        [int]$X, [int]$Y,
        [ValidateSet('left', 'right', 'middle')] [string]$Button = 'left',
        [int]$Count = 1,
        [int]$DelayMs = 40,
        [long]$ExpectHwnd = 0,
        [switch]$AllowScaled
    )
    Initialize-CU
    if (-not $AllowScaled) {
        $h = Get-CUCoordinateHealth
        if (-not $h.Ok) { throw ("坐标映射不可信，拒绝点击：" + $h.Message + "。确认后可用 -AllowScaled 强制点击。") }
    }
    if ($ExpectHwnd -ne 0) { [void](Assert-CUForeground -Hwnd $ExpectHwnd -Action 'Click') }
    if ($PSBoundParameters.ContainsKey('X')) { [void][CUWin32]::SetCursorPos($X, $Y) }
    Start-Sleep -Milliseconds $DelayMs

    $down, $up = switch ($Button) {
        'left'   { 0x0002, 0x0004 }
        'right'  { 0x0008, 0x0010 }
        'middle' { 0x0020, 0x0040 }
    }
    for ($i = 0; $i -lt $Count; $i++) {
        [CUWin32]::mouse_event($down, 0, 0, 0, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 25
        [CUWin32]::mouse_event($up, 0, 0, 0, [UIntPtr]::Zero)
        if ($i -lt $Count - 1) { Start-Sleep -Milliseconds 60 }
    }
    Start-Sleep -Milliseconds 60
    [pscustomobject]@{ Action = 'Click'; Button = $Button; Count = $Count; X = $X; Y = $Y }
}

function Invoke-CUDrag {
    param([int]$X1, [int]$Y1, [int]$X2, [int]$Y2, [int]$Steps = 14)
    Initialize-CU
    [void][CUWin32]::SetCursorPos($X1, $Y1)
    Start-Sleep -Milliseconds 80
    [CUWin32]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 60
    for ($i = 1; $i -le $Steps; $i++) {
        $x = [int]($X1 + ($X2 - $X1) * $i / $Steps)
        $y = [int]($Y1 + ($Y2 - $Y1) * $i / $Steps)
        [void][CUWin32]::SetCursorPos($x, $y)
        Start-Sleep -Milliseconds 18
    }
    Start-Sleep -Milliseconds 60
    [CUWin32]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 80
    [pscustomobject]@{ Action = 'Drag'; From = "$X1,$Y1"; To = "$X2,$Y2" }
}

function Invoke-CUScroll {
    <# Delta 为「格数」，正数向上滚 #>
    param([int]$Delta = -3, [int]$X = -1, [int]$Y = -1)
    Initialize-CU
    if ($X -ge 0 -and $Y -ge 0) { [void][CUWin32]::SetCursorPos($X, $Y); Start-Sleep -Milliseconds 60 }
    [CUWin32]::mouse_event(0x0800, 0, 0, ($Delta * 120), [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 80
    [pscustomobject]@{ Action = 'Scroll'; Delta = $Delta }
}

# ─────────────────────────── 动作：键盘 ───────────────────────────

function Send-CUKeys {
    <# 发快捷键，SendKeys 语法：^s=Ctrl+S  %{F4}=Alt+F4  {ENTER} {TAB} {ESC} #>
    param([Parameter(Mandatory)][string]$Keys)
    Initialize-CU
    [System.Windows.Forms.SendKeys]::SendWait($Keys)
    Start-Sleep -Milliseconds 80
}

function Set-CUText {
    <# 输入文本（含中文）。走剪贴板 + Ctrl+V，比逐字符敲稳且快 #>
    param([Parameter(Mandatory)][string]$Text, [switch]$NoEnter)
    Initialize-CU
    $old = $null
    try { $old = Get-Clipboard -Raw -ErrorAction SilentlyContinue } catch { }

    $ok = $false
    for ($i = 0; $i -lt 5 -and -not $ok; $i++) {
        try { Set-Clipboard -Value $Text -ErrorAction Stop; $ok = $true }
        catch { Start-Sleep -Milliseconds 120 }
    }
    if (-not $ok) { throw '写入剪贴板失败' }
    Start-Sleep -Milliseconds 60

    [System.Windows.Forms.SendKeys]::SendWait('^v')
    Start-Sleep -Milliseconds 200
    if (-not $NoEnter) { }
    if ($null -ne $old -and $old -ne '') {
        try { Set-Clipboard -Value $old -ErrorAction SilentlyContinue } catch { }
    }
    [pscustomobject]@{ Action = 'TypeText'; Length = $Text.Length }
}

# ─────────────────────────── 窗口管理 ───────────────────────────

function Focus-CUWindow {
    <# 把窗口提到前台并确认真的提上去了。#>
    param([long]$Hwnd = 0, [string]$Title = '*', [switch]$Quiet)
    Initialize-CU
    $w = Resolve-CUWindow -Hwnd $Hwnd -TitlePattern $Title
    Enable-CUForeground -Hwnd $w.Hwnd
    Start-Sleep -Milliseconds 150
    $fg = Get-CUForeground
    $ok = ($fg -and $fg.Hwnd -eq $w.Hwnd)
    if (-not $Quiet) {
        [pscustomobject]@{ Action = 'Focus'; Title = $w.Title; Hwnd = $w.Hwnd; Foreground = $ok; ActualForeground = $(if ($fg) { $fg.Title } else { '' }) }
    }
}

function Wait-CUWindow {
    <# 等某个窗口出现（启动程序之后用） #>
    param([Parameter(Mandatory)][string]$Title, [int]$TimeoutSec = 15)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $w = Get-CUWindows -TitlePattern $Title | Select-Object -First 1
        if ($w) { return $w }
        Start-Sleep -Milliseconds 300
    }
    throw "等待窗口 '$Title' 超时（${TimeoutSec}s）"
}

function Export-CUModule {
    <# 把函数导出成 .psm1，方便 Import-Module 长期使用 #>
    param([string]$OutPath = (Join-Path $PSScriptRoot 'CU.psm1'))
    $body = Get-Content -Raw -LiteralPath $PSCommandPath
    $body = $body -replace '(?s)^\s*<#.*?#>', ''   # 去掉帮助注释块
    Set-Content -LiteralPath $OutPath -Value $body -Encoding UTF8
    [pscustomobject]@{ Exported = $OutPath }
}

# 模块加载时不再自动 Initialize-CU：各函数内部按需初始化，
# 这样只通过 worker 操作的调用方不会触发本地的 Add-Type。
function Invoke-CUExpand {
    <# 展开/收起树节点（设备管理器、注册表、文件树）。优先 UIA ExpandCollapse，失败双击 #>
    param(
        [long]$Hwnd = 0,
        [string]$Title = '*',
        [Parameter(Mandatory)][string]$NamePattern,
        [switch]$Collapse
    )
    Initialize-CU
    $el = Find-CUElement -NamePattern $NamePattern -Hwnd $Hwnd -Title $Title
    if (-not $el) { throw "找不到节点：$NamePattern" }

    $root = Get-CUAutomationElement -Hwnd $Hwnd -Title $Title
    $ae = Find-CUAutomationElementDeep -Root $root -NamePattern $el.Name
    $p = $null
    if ($ae -and $ae.TryGetCurrentPattern([System.Windows.Automation.ExpandCollapsePattern]::Pattern, [ref]$p)) {
        $before = $p.Current.ExpandCollapseState
        if ($Collapse) {
            $p.Collapse()
            return [pscustomobject]@{ Action = 'Collapse(UIA)'; Name = $el.Name; Before = $before }
        }
        if ($before -eq [System.Windows.Automation.ExpandCollapseState]::Collapsed) { $p.Expand() }
        return [pscustomobject]@{ Action = 'Expand(UIA)'; Name = $el.Name; Before = $before }
    }

    $cx = [int]($el.X + $el.W / 2)
    $cy = [int]($el.Y + $el.H / 2)
    Invoke-CUClick -X $cx -Y $cy -Count 2 | Out-Null
    return [pscustomobject]@{ Action = 'DoubleClick'; Name = $el.Name }
}

# ─────────────────────── 前台窗口保护 ───────────────────────

function Get-CUForeground {
    <# 当前前台窗口（Hwnd / Pid / 标题）。拿不到返回 $null #>
    Initialize-CU
    $h = [CUWin32]::GetForegroundWindow()
    if ($h -eq [IntPtr]::Zero) { return $null }
    $pid2 = 0
    [void][CUWin32]::GetWindowThreadProcessId($h, [ref]$pid2)
    $sb = New-Object System.Text.StringBuilder 512
    [void][CUWin32]::GetWindowText($h, $sb, 512)
    [pscustomobject]@{ Hwnd = [long]$h; Pid = $pid2; Title = $sb.ToString() }
}

function Assert-CUForeground {
    <# 断言目标窗口在前台，否则抛错。这是防止“点到别的程序上”的唯一保险 #>
    param([Parameter(Mandatory)][long]$Hwnd, [string]$Action = 'action')
    $fg = Get-CUForeground
    if (-not $fg) { throw "拿不到前台窗口，拒绝执行 $Action" }
    if ($fg.Hwnd -ne $Hwnd) {
        throw ("前台窗口不是目标窗口，拒绝执行 {0}。当前前台: '{1}' (hwnd={2})，目标 hwnd={3}。先 Focus-CUWindow -Hwnd {3} 再重试。" -f $Action, $fg.Title, $fg.Hwnd, $Hwnd)
    }
    return $true
}

function Enable-CUForeground {
    <# 强行把窗口提到前台。Windows 有前台锁，直接 SetForegroundWindow 常常无效，
       这里用「置顶→取消置顶」+ AttachThreadInput 两个手段绕过。#>
    param([Parameter(Mandatory)][long]$Hwnd)
    Initialize-CU
    $h = [IntPtr]$Hwnd

    if ([CUWin32]::IsIconic($h)) { [void][CUWin32]::ShowWindow($h, 9) }

    $SWP_NOSIZE_NOMOVE = 0x0001 -bor 0x0002
    [void][CUWin32]::SetWindowPos($h, [IntPtr](-1), 0, 0, 0, 0, $SWP_NOSIZE_NOMOVE)   # HWND_TOPMOST
    [void][CUWin32]::SetWindowPos($h, [IntPtr](-2), 0, 0, 0, 0, $SWP_NOSIZE_NOMOVE)   # HWND_NOTOPMOST

    if ([CUWin32]::GetForegroundWindow() -ne $h) {
        $ownerPid = 0
        $fg = [CUWin32]::GetForegroundWindow()
        $fgThread = [CUWin32]::GetWindowThreadProcessId($fg, [ref]$ownerPid)
        $curThread = [CUWin32]::GetCurrentThreadId()
        [void][CUWin32]::AttachThreadInput($curThread, $fgThread, $true)
        [void][CUWin32]::SetForegroundWindow($h)
        [void][CUWin32]::BringWindowToTop($h)
        [void][CUWin32]::AttachThreadInput($curThread, $fgThread, $false)
    }

    [void][CUWin32]::SetForegroundWindow($h)
    Start-Sleep -Milliseconds 80
}

# ─────────────────── 坐标一致性 & 状态指纹 ───────────────────

function Get-CUCoordinateHealth {
    <#
        检查"我们说坐标"和"系统真实坐标"是否同一套。
        危险场景：进程实际不是 DPI 感知，但缩放不是 100% —— 此时拿到的坐标是逻辑坐标，
        真实屏幕是物理坐标，差一个缩放倍数，点击会整体偏移。
    #>
    param([long]$ProbeHwnd = 0)
    Initialize-CU

    $ctx = [CUWin32]::GetThreadDpiAwarenessContext()
    $pmv2 = $false; $pma = $false; $sys = $false
    try { $pmv2 = [CUWin32]::AreDpiAwarenessContextsEqual($ctx, [IntPtr](-4)) } catch { }
    try { $pma = [CUWin32]::AreDpiAwarenessContextsEqual($ctx, [IntPtr](-3)) } catch { }
    try { $sys = [CUWin32]::AreDpiAwarenessContextsEqual($ctx, [IntPtr](-2)) } catch { }

    $mode = if ($pmv2) { 'per-monitor-v2' } elseif ($pma) { 'per-monitor' } elseif ($sys) { 'system' } else { 'unaware' }

    $dpi = 96
    try { $dpi = [int][CUWin32]::GetDpiForSystem() } catch { }
    if ($dpi -le 0) { $dpi = 96 }
    $scale = [int][math]::Round(100.0 * $dpi / 96)

    $ok = ($mode -ne 'unaware') -or ($scale -eq 100)
    $msg = ''
    if (-not $ok) {
        $msg = "进程是 DPI-unaware，而系统缩放是 $scale%（$dpi dpi）：界面坐标会按 1/$([math]::Round($scale/100,2)) 缩水，点击位置整体偏移"
    }

    # 可选：拿一个窗口做实测，比较 Win32 矩形和 UIA 矩形是否一致
    $rectDiff = $null
    if ($ProbeHwnd -ne 0) {
        try {
            $w = Resolve-CUWindow -Hwnd $ProbeHwnd
            $ae = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]$ProbeHwnd)
            $r = $ae.Current.BoundingRectangle
            $rectDiff = [pscustomobject]@{
                Win32 = "$($w.X),$($w.Y) $($w.Width)x$($w.Height)"
                Uia   = "$([int]$r.X),$([int]$r.Y) $([int]$r.Width)x$([int]$r.Height)"
                DeltaX = [int]($r.X - $w.X)
                DeltaY = [int]($r.Y - $w.Y)
            }
            if ([math]::Abs($rectDiff.DeltaX) -gt 2 -or [math]::Abs($rectDiff.DeltaY) -gt 2) {
                $ok = $false
                $msg = "Win32 矩形与 UIA 矩形不一致（差 $($rectDiff.DeltaX),$($rectDiff.DeltaY) 像素），坐标体系混用"
            }
        } catch { }
    }

    [pscustomobject]@{
        Ok        = $ok
        Mode      = $mode
        SystemDpi = $dpi
        ScalePct  = $scale
        Message   = $msg
        Probe     = $rectDiff
    }
}

function Get-CUStateFingerprint {
    <#
        窗口状态指纹：把窗口内所有控件名排序后哈希。
        用途：动作前后各取一次，哈希变了才说明界面真的响应了。
    #>
    param([Parameter(Mandatory)][long]$Hwnd, [int]$Depth = 8, [int]$Max = 500)

    $els = @(Get-CUElements -Hwnd $Hwnd -Depth $Depth -Max $Max)
    $names = @($els | Where-Object { $_.Name } | ForEach-Object { $_.Name } | Sort-Object -Unique)

    $sb = New-Object System.Text.StringBuilder
    foreach ($n in $names) { [void]$sb.AppendLine($n) }

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = -join ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($sb.ToString())) | ForEach-Object { $_.ToString('x2') })
    } finally { $sha.Dispose() }

    [pscustomobject]@{
        Hwnd        = $Hwnd
        Hash        = $hash.Substring(0, 16)
        ElementCount = $names.Count
        Sample      = @($names | Select-Object -First 4)
    }
}

function Close-CUWindow {
    <# 关窗口：先 WM_CLOSE，没关掉再 WM_SYSCOMMAND/SC_CLOSE。
       全程不依赖焦点和键盘，脚本收尾专用。#>
    param([Parameter(Mandatory)][long]$Hwnd, [int]$TimeoutMs = 800)
    Initialize-CU
    $h = [IntPtr]$Hwnd

    [void][CUWin32]::PostMessage($h, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)   # WM_CLOSE
    Start-Sleep -Milliseconds 300
    $closed = -not [CUWin32]::IsWindow($h)

    if (-not $closed) {
        [void][CUWin32]::PostMessage($h, 0x0112, [IntPtr]0xF060, [IntPtr]::Zero)   # WM_SYSCOMMAND / SC_CLOSE
        Start-Sleep -Milliseconds 300
        $closed = -not [CUWin32]::IsWindow($h)
    }

    [pscustomobject]@{ Hwnd = $Hwnd; Closed = $closed }
}