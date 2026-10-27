<#
    agent.ps1 —— 独立 GUI Agent（模型驱动）

    闭环：感知 → 决策（模型）→ 执行 → 校验 → 循环

    后端：auto（默认，worker 在线就走 worker）/ local / worker
    模型：ollama | openai | deepseek | moonshot | dashscope | zhipu | siliconflow | groq | anthropic | custom

    HTTP 全部交给 llm_call.py（这台机器的 PowerShell/.NET TLS 握手失败，Python 正常）。

    用法：
      .\agent.ps1 -Task "关掉 DirectX 诊断工具窗口" -Provider ollama -Model gemma4:e4b
      .\agent.ps1 -Task "..." -Provider deepseek -Model deepseek-chat
      .\agent.ps1 -Doctor
#>
param(
    [string]$Task = '',
    [string]$Provider = 'ollama',
    [string]$Model = '',
    [string]$BaseUrl = '',
    [string]$ApiKeyEnv = '',
    [ValidateSet('auto', 'local', 'worker')][string]$Backend = 'auto',
    [int]$MaxSteps = 8,
    [string]$ConfigPath = '',
    [switch]$WithScreenshot,
    [switch]$Plan,
    [switch]$Doctor,
    [switch]$DryRun,
    [switch]$NoVerify,
    [string]$LogFile = ''
)

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $here
$ipcReq = Join-Path $root 'ipc\req'
$ipcRes = Join-Path $root 'ipc\res'

$PYEXE = 'C:\Users\18790\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\python\python.exe'
if (-not (Test-Path $PYEXE)) { $PYEXE = (Get-Command python -ErrorAction SilentlyContinue).Source }
$PYSCRIPT = Join-Path $here 'llm_call.py'
$RUN_DIR = Join-Path $here 'run'
[void](New-Item -ItemType Directory -Force -Path $RUN_DIR)

. (Join-Path $root 'cu.ps1')

# ── 输出：给日志文件就只写文件（Web 控制台 tail 它）──────────
if ($LogFile) { $script:LogPath = $LogFile }
function Emit([string]$s) {
    # 注意：不能用 Write-Output——它会混进调用方的返回值（例如 $raw = Invoke-LLM ...）
    if ($script:LogPath) {
        try { Add-Content -LiteralPath $script:LogPath -Value $s -Encoding UTF8 } catch { }
    } else {
        [Console]::Out.WriteLine($s)
    }
}

if (-not $ConfigPath) { $ConfigPath = Join-Path $here 'config.json' }
$cfg = $null
if (Test-Path $ConfigPath) { try { $cfg = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { } }

# ── 服务商 ───────────────────────────────────────────────────
$PRESETS = @{
    ollama      = @{ baseUrl = 'http://127.0.0.1:11434'; style = 'ollama';     keyEnv = '';                  model = 'gemma4:e4b' }
    openai      = @{ baseUrl = 'https://api.openai.com/v1'; style = 'openai';  keyEnv = 'OPENAI_API_KEY';    model = 'gpt-4o' }
    deepseek    = @{ baseUrl = 'https://api.deepseek.com/v1'; style = 'openai'; keyEnv = 'DEEPSEEK_API_KEY'; model = 'deepseek-chat' }
    moonshot    = @{ baseUrl = 'https://api.moonshot.cn/v1'; style = 'openai'; keyEnv = 'MOONSHOT_API_KEY'; model = 'moonshot-v1-8k' }
    dashscope   = @{ baseUrl = 'https://dashscope.aliyuncs.com/compatible-mode/v1'; style = 'openai'; keyEnv = 'DASHSCOPE_API_KEY'; model = 'qwen-vl-max' }
    zhipu       = @{ baseUrl = 'https://open.bigmodel.cn/api/paas/v4'; style = 'openai'; keyEnv = 'ZHIPUAI_API_KEY'; model = 'glm-4v-plus' }
    siliconflow = @{ baseUrl = 'https://api.siliconflow.cn/v1'; style = 'openai'; keyEnv = 'SILICONFLOW_API_KEY'; model = 'Qwen/Qwen2.5-VL-7B-Instruct' }
    groq        = @{ baseUrl = 'https://api.groq.com/openai/v1'; style = 'openai'; keyEnv = 'GROQ_API_KEY';   model = 'llama-3.2-11b-vision-preview' }
    anthropic   = @{ baseUrl = 'https://api.anthropic.com'; style = 'anthropic'; keyEnv = 'ANTHROPIC_API_KEY'; model = 'claude-sonnet-4-20250514' }
}

function Resolve-Provider {
    param([string]$Name, [string]$BaseUrl, [string]$ApiKeyEnv, [string]$Model)

    $p = @{ name = $Name; baseUrl = ''; style = 'openai'; keyEnv = ''; model = ''; apiKey = '' }
    if ($PRESETS.ContainsKey($Name)) {
        $p.baseUrl = $PRESETS[$Name].baseUrl
        $p.style = $PRESETS[$Name].style
        $p.keyEnv = $PRESETS[$Name].keyEnv
        $p.model = $PRESETS[$Name].model
    } elseif ($Name -eq 'custom') { $p.style = 'openai' }

    if ($cfg -and $cfg.providers -and $cfg.providers.$Name) {
        $n = $cfg.providers.$Name
        if ($n.baseUrl) { $p.baseUrl = $n.baseUrl }
        if ($n.style) { $p.style = $n.style }
        if ($n.apiKeyEnv) { $p.keyEnv = $n.apiKeyEnv }
        if ($n.model) { $p.model = $n.model }
    }
    if ($BaseUrl) { $p.baseUrl = $BaseUrl }
    if ($ApiKeyEnv) { $p.keyEnv = $ApiKeyEnv }
    if ($Model) { $p.model = $Model }
    if ($p.keyEnv) { $p.apiKey = [Environment]::GetEnvironmentVariable($p.keyEnv) }
    if (-not $p.apiKey) {
        $kf = Join-Path $here 'keys.json'
        if (Test-Path $kf) {
            try { $k = Get-Content $kf -Raw -Encoding UTF8 | ConvertFrom-Json; if ($k.$Name) { $p.apiKey = $k.$Name } } catch { }
        }
    }
    return $p
}

$known = $PRESETS.ContainsKey($Provider) -or $Provider -eq 'custom' -or ($cfg -and $cfg.providers -and $cfg.providers.$Provider)
if (-not $known) {
    $names = ($PRESETS.Keys | Sort-Object) -join ', '
    throw ("未知服务商 '{0}'：可用 [{1}]，或在 config.json 的 providers 里自定义" -f $Provider, $names)
}
$P = Resolve-Provider -Name $Provider -BaseUrl $BaseUrl -ApiKeyEnv $ApiKeyEnv -Model $Model

# ── 后端路由 ─────────────────────────────────────────────────
function Test-WorkerOnline {
    $hb = Join-Path $root 'ipc\heartbeat.txt'
    if (-not (Test-Path $hb)) { return $false }
    try { $s = (Get-Content $hb -Raw -ErrorAction Stop).Trim() } catch { return $true }
    if ($s -match '\|(.+)$') {
        try { return (((Get-Date) - [datetime]$Matches[1]).TotalSeconds -lt 15) } catch { return $false }
    }
    return $false
}

$workerUp = Test-WorkerOnline
if ($Backend -eq 'worker' -and -not $workerUp) { throw '要求走 worker，但它不在线（先跑 worker-via-task.ps1）' }
$script:useWorker = ($Backend -eq 'worker') -or ($Backend -eq 'auto' -and $workerUp)

function Send-Worker([hashtable]$req, [int]$timeout = 40) {
    [void](New-Item -ItemType Directory -Force -Path $ipcReq)
    [void](New-Item -ItemType Directory -Force -Path $ipcRes)
    $id = [guid]::NewGuid().ToString('N')
    $rf = Join-Path $ipcReq "$id.json"
    $sf = Join-Path $ipcRes "$id.json"
    [IO.File]::WriteAllText($rf, ($req | ConvertTo-Json -Compress -Depth 5), (New-Object Text.UTF8Encoding($true)))
    $dl = (Get-Date).AddSeconds($timeout)
    while ((Get-Date) -lt $dl) {
        if (Test-Path $sf) {
            Start-Sleep -Milliseconds 50
            $t = [IO.File]::ReadAllText($sf, [Text.Encoding]::UTF8)
            Remove-Item $sf -Force -ErrorAction SilentlyContinue
            try { return ($t | ConvertFrom-Json) } catch { return @{ ok = $false; error = 'worker 返回了非法 JSON' } }
        }
        Start-Sleep -Milliseconds 70
    }
    Remove-Item $rf -Force -ErrorAction SilentlyContinue
    return @{ ok = $false; error = 'worker 超时' }
}

function CU([hashtable]$req) {
    if ($script:useWorker) { return (Send-Worker $req) }
    try {
        $data = $null
        switch ($req.cmd) {
            'windows'    { $data = @(Get-CUWindows | Select-Object Hwnd, Pid, Process, Title, X, Y, Width, Height) }
            'foreground' { $data = Get-CUForeground }
            'elements'   {
                $a = @{ Depth = 8; Max = 120 }
                if ($req.depth) { $a['Depth'] = [int]$req.depth }
                if ($req.max) { $a['Max'] = [int]$req.max }
                if ($req.hwnd) { $a['Hwnd'] = [long]$req.hwnd }
                $data = @(Get-CUElements @a)
            }
            'focus'  { $data = Focus-CUWindow -Hwnd ([long]$req.hwnd) }
            'invoke' { $data = Invoke-CUElement -NamePattern ([string]$req.name) -Hwnd ([long]$req.hwnd) }
            'click'  { $data = Invoke-CUClick -X ([int]$req.x) -Y ([int]$req.y) -ExpectHwnd ([long]$req.hwnd) }
            'type'   { [void](Assert-CUForeground -Hwnd ([long]$req.hwnd) -Action 'Type'); $data = Set-CUText -Text ([string]$req.text) }
            'keys'   { [void](Assert-CUForeground -Hwnd ([long]$req.hwnd) -Action 'Keys'); Send-CUKeys -Keys ([string]$req.keys); $data = @{ sent = $req.keys } }
            'close'  { $data = Close-CUWindow -Hwnd ([long]$req.hwnd) }
            'shot'   {
                $a = @{ Path = [string]$req.path }
                if ($req.hwnd) { $a['Hwnd'] = [long]$req.hwnd }
                $data = Get-CUScreenshot @a
            }
            'state'  { $data = Get-CUStateFingerprint -Hwnd ([long]$req.hwnd) }
            default  { return @{ ok = $false; error = "本地不支持: $($req.cmd)" } }
        }
        return @{ ok = $true; data = $data }
    } catch {
        return @{ ok = $false; error = $_.Exception.Message }
    }
}

# ── 模型调用（走 python）─────────────────────────────────────
$script:tokPrompt = 0
$script:tokCompletion = 0
$script:tokTotal = 0
$script:lastPrompt = 0
$script:lastCompletion = 0

function Invoke-LLM {
    param([string]$imgB64 = '', [int]$TimeoutSec = 180)

    $req = @{
        style    = $P.style
        baseUrl  = $P.baseUrl
        model    = $P.model
        apiKey   = $P.apiKey
        messages = @($script:messages | ForEach-Object { @{ role = $_.role; content = $_.content } })
        image    = $imgB64
        timeout  = $TimeoutSec
    }
    $id = [guid]::NewGuid().ToString('N')
    $reqFile = Join-Path $RUN_DIR "llm-$id.req.json"
    $resFile = Join-Path $RUN_DIR "llm-$id.res.json"
    [IO.File]::WriteAllText($reqFile, ($req | ConvertTo-Json -Depth 12), (New-Object Text.UTF8Encoding($true)))
    try {
        $proc = Start-Process -FilePath $PYEXE -ArgumentList @($PYSCRIPT, $reqFile, $resFile) -Wait -PassThru -WindowStyle Hidden
        if (-not (Test-Path $resFile)) { throw "模型进程没有输出（exit=$($proc.ExitCode)）" }
        $out = [IO.File]::ReadAllText($resFile, [Text.Encoding]::UTF8) | ConvertFrom-Json
    } finally {
        Remove-Item $reqFile -Force -ErrorAction SilentlyContinue
        Remove-Item $resFile -Force -ErrorAction SilentlyContinue
    }
    if (-not $out.ok) { throw $out.error }

    $u = $out.usage
    $script:lastPrompt = [int]$u.prompt
    $script:lastCompletion = [int]$u.completion
    $script:tokPrompt += [int]$u.prompt
    $script:tokCompletion += [int]$u.completion
    $script:tokTotal += [int]$u.total

    Emit ('__USAGE__ ' + (@{
        prompt = $script:lastPrompt; completion = $script:lastCompletion; total = [int]$u.total
        cumPrompt = $script:tokPrompt; cumCompletion = $script:tokCompletion; cumTotal = $script:tokTotal
        model = $P.model
    } | ConvertTo-Json -Compress))
    Emit ("          用量: {0} 输入 + {1} 输出 ｜ 累计 {2} tokens" -f $script:lastPrompt, $script:lastCompletion, $script:tokTotal)
    if (-not $out.content) { throw ("模型返回空内容（usage=" + ($out.usage | ConvertTo-Json -Compress) + "）") }
    return $out.content
}

# ── 自检 ─────────────────────────────────────────────────────
if ($Doctor) {
    Emit '服务商自检'
    Emit ('─' * 52)
    foreach ($name in @('ollama', 'deepseek', 'moonshot', 'dashscope', 'zhipu', 'siliconflow', 'groq', 'openai', 'anthropic')) {
        $q = Resolve-Provider -Name $name -BaseUrl '' -ApiKeyEnv '' -Model ''
        if ($q.keyEnv -and -not $q.apiKey) { Emit ("{0,-12} 跳过   未设置 {1}" -f $name, $q.keyEnv); continue }
        $saved = $P
        $sw = [Diagnostics.Stopwatch]::StartNew()
        try {
            $script:messages = @(@{ role = 'user'; content = '只输出 {"ok":true}' })
            $P = $q
            $null = Invoke-LLM -imgB64 '' -TimeoutSec 30
            Emit ("{0,-12} OK     {1}  {2:N1}s" -f $name, $q.model, $sw.Elapsed.TotalSeconds)
        } catch { Emit ("{0,-12} 失败   {1}" -f $name, $_.Exception.Message) }
        finally { $P = $saved; $script:messages = @() }
    }
    Emit ('─' * 52)
    exit 0
}

if (-not $Task) { Emit '缺少 -Task'; exit 1 }

# ── 感知 ─────────────────────────────────────────────────────
$script:ShotPath = Join-Path $RUN_DIR 'agent-state.png'

function Get-CompactState {
    $lines = New-Object System.Collections.ArrayList
    $r = CU @{ cmd = 'windows' }
    if ($r.ok) {
        [void]$lines.Add('窗口列表（hwnd | 进程 | 标题）:')
        foreach ($w in @($r.data | Select-Object -First 12)) {
            [void]$lines.Add(("  {0} | {1} | {2}" -f $w.Hwnd, $w.Process, $w.Title))
        }
    }
    $f = CU @{ cmd = 'foreground' }
    if ($f.ok -and $f.data) {
        [void]$lines.Add(("前台窗口: {0} | {1}" -f $f.data.Title, $f.data.Hwnd))
        $e = CU @{ cmd = 'elements'; hwnd = $f.data.Hwnd; depth = 6; max = 80 }
        if ($e.ok) {
            $named = @($e.data | Where-Object { $_.Name } | Select-Object -First 40)
            if ($named.Count -gt 0) {
                [void]$lines.Add('前台窗口的控件（名字 | 类型 | 坐标）:')
                foreach ($el in $named) {
                    $n = [string]$el.Name
                    if ($n.Length -gt 36) { $n = $n.Substring(0, 36) + '…' }
                    [void]$lines.Add(("  {0} | {1} | {2},{3}" -f $n, $el.Type, $el.X, $el.Y))
                }
            }
        }
    }
    if ($WithScreenshot -and $f.ok -and $f.data) {
        $s = CU @{ cmd = 'shot'; hwnd = $f.data.Hwnd; path = $script:ShotPath }
        if ($s.ok) { [void]$lines.Add(("已附上当前窗口截图（{0}x{1}）" -f $s.data.Width, $s.data.Height)) }
    }
    return ($lines -join "`n")
}

function Get-ShotBase64 {
    if (-not $WithScreenshot) { return '' }
    if (-not (Test-Path $script:ShotPath)) { return '' }
    try { return [Convert]::ToBase64String([IO.File]::ReadAllBytes($script:ShotPath)) } catch { return '' }
}

$systemPrompt = @'
你是 Windows 桌面 GUI 操作代理。你只能输出一个 JSON 对象，不要输出任何其他文字。

可用动作（每次只做一个）:
{"type":"focus","hwnd":数字}                     把窗口提到前台
{"type":"invoke","hwnd":数字,"name":"控件名"}     按名字点击控件（推荐，不用坐标）
{"type":"click","hwnd":数字,"x":数字,"y":数字}    按坐标点击
{"type":"type","hwnd":数字,"text":"文本"}         往输入框输入文本
{"type":"keys","hwnd":数字,"keys":"^s"}           发快捷键（SendKeys 语法）
{"type":"close","hwnd":数字}                      关闭窗口
{"type":"wait","ms":800}                          等待
{"type":"done","summary":"完成了什么"}             任务完成

输出格式（严格）:
{"thought":"一句话说明为什么这么做","action":{...}}

规则:
1. 一次只输出一个动作；不确定目标窗口时先 focus。
2. 能按控件名字点就用 invoke，不要猜坐标。
3. 任务如果是『关闭窗口』，直接用 close，不要去点『退出/取消』按钮。
4. 任务完成后必须输出 done。
5. 读取类任务（读出/告诉我/查一下/是什么）：答案就在前台窗口的控件列表里。找到后直接输出 done，
   并把读到的值原样写进 summary（例如 "计算机名：一棵大树，版本：Windows 11 专业版"）。
   不要反复 focus，focus 不会让信息出现。
6. 表单类任务：先 focus 目标窗口 → click 输入框 → type 文本 → click 按钮。
   每一步都要用步骤 1 的规则确认操作的是目标窗口。
7. 不要输出解释、不要输出 markdown。
'@

$script:messages = @(@{ role = 'system'; content = $systemPrompt })

Emit ("任务: {0}" -f $Task)
Emit ("模型: {0} / {1}" -f $P.name, $P.model)
Emit ("后端: {0}" -f $(if ($script:useWorker) { 'worker（沙盒外）' } else { 'local（沙盒内）' }))
Emit ('─' * 52)

$planSteps = @()
if ($Plan) {
    $planPrompt = "任务：$Task`n`n当前界面：`n" + (Get-CompactState) + "`n`n请只输出一个 JSON：{`"steps`":[`"第一步`",`"第二步`"]}，最多 5 步。"
    $script:messages += @{ role = 'user'; content = $planPrompt }
    try {
        $rawPlan = Invoke-LLM -imgB64 (Get-ShotBase64)
        $cp = ([string]$rawPlan).Trim()
        if ($cp -and ($cp -match '(?s)\{.*\}')) { $cp = $Matches[0] }
        $planSteps = @(($cp | ConvertFrom-Json).steps)
        Emit '计划:'
        $i = 1
        foreach ($s in $planSteps) { Emit ("  {0}. {1}" -f $i, $s); $i++ }
    } catch { Emit ("计划生成失败，直接执行: " + $_.Exception.Message) }
    if ($planSteps.Count -gt 0) { $script:messages += @{ role = 'assistant'; content = ($planSteps -join ' / ') } }
}

# ── 主循环 ───────────────────────────────────────────────────
$done = $false
$lastHash = $null
$staleCount = 0
$lastAct = ''
$repeatCount = 0
$trace = New-Object System.Collections.ArrayList

for ($step = 1; $step -le $MaxSteps -and -not $done; $step++) {
    $state = Get-CompactState
    if ($Plan -and $planSteps.Count -gt 0) { $state = ("已定计划：" + ($planSteps -join ' → ') + "`n`n" + $state) }
    $script:messages += @{ role = 'user'; content = ("任务: $Task`n`n当前界面状态:`n" + $state) }

    $raw = $null
    $parsed = $null
    for ($attempt = 1; $attempt -le 2 -and -not $parsed; $attempt++) {
        try { $raw = Invoke-LLM -imgB64 (Get-ShotBase64) }
        catch { Emit ("[step {0}] 模型调用失败: {1}" -f $step, $_.Exception.Message); break }
        $clean = ([string]$raw).Trim()
        if ($clean -and ($clean -match '(?s)\{.*\}')) { $clean = $Matches[0] }
        try { $parsed = $clean | ConvertFrom-Json } catch { $parsed = $null }
        if (-not $parsed) { $script:messages[-1].content += "`n`n上次输出不是合法 JSON，请只输出 JSON。" }
    }
    if (-not $parsed) {
        $dbg = [string]$raw
        if ($dbg.Length -gt 400) { $dbg = $dbg.Substring(0, 400) }
        Emit ("[step {0}] 没有可解析的 JSON。原始内容: {1}" -f $step, $dbg)
        break
    }

    $act = $parsed.action
    Emit ("[step {0}] 想法: {1}" -f $step, $parsed.thought)
    Emit ("          动作: {0}" -f ($act | ConvertTo-Json -Compress))

    $actJson = ($act | ConvertTo-Json -Compress)
    if ($actJson -eq $lastAct) { $repeatCount++ } else { $repeatCount = 0 }
    $lastAct = $actJson
    if ($repeatCount -ge 2) {
        Emit '          → 重复动作，提示换策略'
        $script:messages += @{ role = 'user'; content = "你已经连续 $repeatCount 次输出同一个动作，它没有让任务前进。换一个动作或换目标窗口。" }
    }
    if ($repeatCount -ge 5) { Emit '连续重复同一动作，停止。'; break }

    if ($DryRun) { [void]$trace.Add($act); break }

    try {
        switch ($act.type) {
            'focus'  { [void](CU @{ cmd = 'focus'; hwnd = [long]$act.hwnd }) }
            'invoke' { $r = CU @{ cmd = 'invoke'; hwnd = [long]$act.hwnd; name = [string]$act.name }; if (-not $r.ok) { throw $r.error } }
            'click'  { $r = CU @{ cmd = 'click'; hwnd = [long]$act.hwnd; x = [int]$act.x; y = [int]$act.y }; if (-not $r.ok) { throw $r.error } }
            'type'   { $r = CU @{ cmd = 'type'; hwnd = [long]$act.hwnd; text = [string]$act.text }; if (-not $r.ok) { throw $r.error } }
            'keys'   { $r = CU @{ cmd = 'keys'; hwnd = [long]$act.hwnd; keys = [string]$act.keys }; if (-not $r.ok) { throw $r.error } }
            'close'  {
                $tw = (CU @{ cmd = 'windows' }).data | Where-Object { $_.Hwnd -eq [long]$act.hwnd } | Select-Object -First 1
                if (-not $tw) { throw '目标窗口不存在' }
                $allowed = ($Task -like "*$($tw.Process)*")
                if (-not $allowed) {
                    foreach ($kw in ([string]$tw.Title -split '[ \-—|（(]')) {
                        $k = $kw.Trim()
                        if ($k.Length -ge 2 -and $Task.Contains($k)) { $allowed = $true; break }
                    }
                }
                if (-not $allowed) { throw "拒绝关闭「$($tw.Title)」：任务里没提到它（安全护栏）" }
                $r = CU @{ cmd = 'close'; hwnd = [long]$act.hwnd }
                if ($r.ok -and $r.data.Closed) { Emit ('完成: 已关闭窗口 ' + $act.hwnd); $done = $true }
            }
            'wait'   { Start-Sleep -Milliseconds ([int]$act.ms) }
            'done'   { Emit ("完成: {0}" -f $act.summary); $done = $true }
            default  { Emit ("未知动作: {0}" -f $act.type) }
        }
    } catch { Emit ("          执行失败: {0}" -f $_.Exception.Message) }

    if (-not $done -and -not $NoVerify -and $act.hwnd) {
        Start-Sleep -Milliseconds 250
        $fp = CU @{ cmd = 'state'; hwnd = [long]$act.hwnd }
        if ($fp.ok) {
            Emit ("          状态指纹: {0}" -f $fp.data.Hash)
            if ($lastHash -and $fp.data.Hash -eq $lastHash) {
                $staleCount++
                Emit '          → 界面无变化，提示换做法'
                $script:messages += @{ role = 'user'; content = '注意：上一步动作没有引起任何界面变化，说明没生效。请换一种做法。' }
            } else { $staleCount = 0 }
            $lastHash = $fp.data.Hash
        }
    }
    [void]$trace.Add($act)
    if ($staleCount -ge 3) { Emit '连续 3 次无进展，停止。'; break }
}

if (-not $done) { Emit '未确认完成。' }
Emit ('─' * 52)
Emit ("共执行 {0} 个动作 ｜ 共消耗 {1} tokens" -f $trace.Count, $script:tokTotal)
Emit ('__TOKENS__ ' + (@{ prompt = $script:tokPrompt; completion = $script:tokCompletion; total = $script:tokTotal } | ConvertTo-Json -Compress))
Emit '__AGENT_DONE__'
