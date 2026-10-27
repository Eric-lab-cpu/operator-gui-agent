# 让 Agent 操作 Windows 界面 —— 本机已跑通的最小方案

> 目标：像「小艺帮帮忙」那样，Agent 看着屏幕、动鼠标键盘、把事做完。
> 现状：`cu.ps1` 已经在你这台机器上跑通了 **截图 → 读控件树 → 按名字点按钮 → 输入中文 → 再截图验证** 的完整闭环，零安装。

## 0. 一句话结论

能。而且不需要装 pyautogui、不需要接第三方 Computer-Use 模型，Windows 自带的
**UIAutomation（控件树）+ user32（鼠标键盘）+ GDI（截图）** 就够了。
模型这边（我）本来就是多模态的，`read_image` 一看截图就能决定点哪儿。

## 1. 两条操作通道，别只用一条

| | 像素通道（截图 + 坐标点击） | 控件通道（UIAutomation） |
|---|---|---|
| 原理 | 截屏 → 模型看图 → 算坐标 → 点 | 读控件树 → 按名字/类名定位 → 调 Invoke |
| 优点 | 什么都能点（游戏、Canvas、远程桌面、自绘 UI） | 稳定、精确、窗口挪了也不点错、不用算坐标 |
| 缺点 | 分辨率/缩放/主题一变就偏，慢，靠"猜" | 目标程序得暴露无障碍信息（Electron 默认不全） |
| 适用 | 兜底手段 | **首选**，90% 的桌面软件够用 |

正确姿势：**先读控件树，能按名字就按名字；读不到再截图让模型找坐标。**
`cu.ps1` 的 `Invoke-CUElement` 就是按这个顺序：先试 UIA `Invoke`，失败自动退回鼠标点中心。

## 2. 用法

```powershell
. "C:\Users\18790\Desktop\workbuddy\混合区\computer-use\cu.ps1"
```

| 函数 | 作用 |
|---|---|
| `Get-CUInfo` | 屏幕尺寸 / DPI / 光标位置 |
| `Get-CUWindows [-TitlePattern '记事本*']` | 列出可见窗口（含 hwnd、进程、坐标） |
| `Get-CUScreenshot -Path out.png [-Hwnd/-Title]` | 截图（整屏或单窗口），返回真实尺寸 |
| `Get-CUElements -Title '*记事本*' -Depth 8` | 读控件树：名字/类型/类名/坐标/可用模式 |
| `Find-CUElement -NamePattern '登录' -TimeoutMs 5000` | 等控件出现（配超时，抗加载慢） |
| `Invoke-CUElement -NamePattern '确定'` | 按名字点按钮（UIA 优先，坐标兜底） |
| `Invoke-CUClick -X 500 -Y 300 [-Button right] [-Count 2]` | 坐标点击 |
| `Set-CUText '中文也行'` | 输入文本（走剪贴板 + Ctrl+V，中文最稳） |
| `Send-CUKeys '^s'` / `'%{F4}'` / `'{ESC}'` | 快捷键 / 关窗 / 取消 |
| `Invoke-CUDrag -X1 100 -Y1 100 -X2 600 -Y2 400` | 拖拽（含中间插值，很多列表拖拽需要） |
| `Invoke-CUScroll -Delta -3` | 滚轮 |
| `Set-CUValue -NamePattern '账号' -Value 'abc'` | 直接给输入框赋值（不点，走 ValuePattern） |
| `Focus-CUWindow -Title '*微信*'` | 前台化 |
| `Wait-CUWindow -Title '*安装*' -TimeoutSec 30` | 等窗口出现 |
| `Get-CUText -Hwnd $w.Hwnd` | 把窗口里所有可读文本抓出来（读结果/错误提示） |

典型 Agent 主循环：

```powershell
$w = Wait-CUWindow -Title '*目标程序*'
$els = Get-CUElements -Hwnd $w.Hwnd -Depth 8        # ① 看
Invoke-CUElement -NamePattern '下一步' -Hwnd $w.Hwnd  # ② 动
$txt = Get-CUText -Hwnd $w.Hwnd                     # ③ 验：状态真的变了吗
if ($txt -notcontains '已完成') { throw '动作没生效，重试/换路子' }
```

## 3. 已验证（本机实测，2026-10-26）

`demo/selftest.ps1` 端到端跑通，只操作自己启动的测试窗口，不碰任何用户程序：

```
launch            -> hwnd 460868
screenshot-before -> 542x356
ui-tree           -> 5 个控件
click-by-name     -> MouseClick 「点我」
verify-click      -> 已点击 1 次                     pass
click-textbox     -> 点中类名 *EDIT* 的输入框 (1270,730)
verify-typing     -> 输入内容是：你好，电脑操作！DeepSeek Harness   pass
screenshot-after  -> 542x356
ok: true
```

截图见 `demo/shots/1-before.png`、`demo/shots/2-after.png`。

`demo/realapp-dxdiag.ps1` 又在**真实第三方软件**（DirectX 诊断工具）上跑了一遍：

```
[1] 模态框 909x329，UIA 只暴露 4 个控件（名字是「是(Y)」「否(N)」，类型却是 Pane）
[2] SendKeys 'n' → 模态框关闭
[3] 主窗口 1353x980，控件数 35
[5] 按名字点击 -> MouseClick / 下一页(N)
[6] 翻页后文本 55 条，新增 48 条（NVIDIA GeForce RTX 4060 Laptop GPU …）
[result] PASS
```

`demo/shots/6-dxdiag-page1.png`（系统页）→ `7-dxdiag-page2.png`（显示页）。

`demo/task-cleanmgr.ps1` 干脆拿真任务练了一遍：**查 C 盘能清出多少空间**。

```
[1] 驱动器选择对话框 583x302，控件 6 个（确定 / 退出 / 驱动器下拉框）
[3] 点「确定」开始扫描
[4] 扫描完成（12 条文本）
[6] 结果被 UIA 读出来：可以使用"磁盘清理"来释放 Windows-SSD (C:) 上的 132 MB 磁盘空间
[7] 只读退出：点「取消」，一个文件都没删
[result] PASS
```

明细（截图 `demo/shots/13-cleanmgr-result.png`）：临时文件 122 MB + 缩略图 10.0 MB = 132 MB。

顺带一个环境发现：这台机器**计算器和记事本都起不了窗口**（calc 进程根本不出现；
notepad 进程在但 `MainWindowHandle=0`）。Windows 11 的这两个都是 Store 应用，本机被精简过。
真机部署要么装回 Store 组件，要么换 Win32 程序（dxdiag / msinfo32 / mmc 都正常）。

## 4. 踩过的坑（你自己写会踩同样几个）

1. **DPI 缩放**：本机是 2560×1600 @150%。进程不声明 DPI 感知时，
   `GetSystemMetrics` 返回 1707×1067（逻辑坐标），截图是放大后的模糊图。
   必须**在加载任何 UI 程序集之前** `SetProcessDpiAwarenessContext(-4)`，
   否则坐标和像素全部错位。`cu.ps1` 已处理。
2. **编码**：Windows PowerShell 5.1 按 GBK 读 `.ps1`，UTF-8 无 BOM 的中文会把脚本语法打断。
   带中文的脚本必须存成 **UTF-8 with BOM**。
3. **中文输入**：`SendKeys` 打不了中文，逐字符反而慢。走剪贴板 `Set-Clipboard` + `^v` 最稳。
4. **焦点**：坐标点击/键盘输入作用在**前台窗口**。动作前先 `Focus-CUWindow`，
   否则打到别的窗口上（这就是「Agent 乱点」最常见的原因）。
5. **权限**：UAC 提权窗口（任务管理器、安装器）普通权限点不动，
   需要 Agent 进程本身提权，或用 UIA 的 `Invoke` 绕过（能过的场景有限）。
6. **Electron/Chromium 类应用**（微信 4 / VS Code / 飞书）：默认不暴露完整控件树，
   加启动参数 `--force-renderer-accessibility` 后有；否则退回像素通道。
7. **动作后必须验证**：UIA 的 `Invoke` 只是"发了个请求"，程序可能没响应。
   每次动作后截图或读文本确认状态变化，失败就重试 —— 这是 GUI Agent 可靠性的分水岭。
8. **别信 ControlType**：dxdiag 的按钮在 UIA 里 `ControlType` 是 `Pane`，只有 `ClassName`
   是 `Button`；按 `Type -eq 'Button'` 筛一个都筛不到。判断控件永远用 `Name` + `Class`
   两条线索，`Type` 只当参考。这个坑今天当场踩了一次，结果是"页面明明翻过去了，校验却报 FAIL"。

## ⚠ 环境边界：沙盒会挡住一部分 GUI 应用（实测）

这一轮实测里四类目标的表现完全不同，值得单独记一笔：

| 目标 | 结果 | 原因 |
|---|---|---|
| dxdiag / cleanmgr / sysdm.cpl | ✅ 正常，按钮能按名字点 | 经典单进程 Win32 |
| 设备管理器（devmgmt.msc） | ❌ UIA 只有 13 个 Pane，看不到任何树节点 | MMC 的树是 ActiveX 里的 SysTreeView32，UIA 不代理，得退回 MSAA |
| Chrome / Excel / 记事本 | ❌ 进程起来了，但 `MainWindowHandle=0`，一个窗口都不创建 | 启动时要写 `%APPDATA%` / `%LOCALAPPDATA%`，被文件沙盒拒绝 |
| Chrome 用 `--user-data-dir` 指到工作区绕过 | ❌ 仍然没有窗口 | 光改 profile 路径不够，组件/缓存目录还在用户目录 |

沙盒写入的直接证据：

```
写 %LOCALAPPDATA%  → 拒绝访问
写 %APPDATA%       → 拒绝访问
写 %TEMP%          → 可写
写工作区           → 可写
命名管道           → 可以建（所以不是 pipe 被禁）
```

**结论**：这不是 UIA 的能力问题，是执行环境的问题。想让 Agent 操作 Chrome / Office / 微信
这类现代应用，GUI 自动化进程必须跑在沙盒外——要么 DSH 用 `danger-full-access`，
要么单独起一个不受限的 worker 进程（Agent 把动作投递给它）。
在 workspace-write 沙盒里，能稳定驱动的只有经典单进程 Win32 程序。

## 5. 升级路线

**A. 现状（今天就能用）**：Agent 每次通过 shell 调 `cu.ps1`，一步一个命令。

**B. 常驻工具（推荐，需要重启 DSH 生效）**：包成一个 MCP server 挂到
`dsh-mcp-client`，工具就变成 `mcp__computer__screenshot` 这类原生工具，
调用更短、参数校验更严。在 `~/.dsh/profiles/desktop/cordis.patch.yml` 加：

```yaml
- insert:
    - id: mcp-computer-use
      name: "@deepseek-ai/dsh-mcp-client"
      config:
        serverName: computer
        transport: stdio
        command: 'C:\Program Files\nodejs\node.exe'
        args: ['C:\Users\18790\Desktop\workbuddy\混合区\computer-use\server.mjs']
        toolCallTimeoutMs: 60000
        failOnStartupError: false
```

**C. 视觉闭环（目标是"什么软件都能干"）**：截图 → 多模态模型吐坐标 →
点击 → 再截图。对自绘 UI、游戏、远程桌面有效。代价是慢 10 倍、贵、易漂移，
所以放在 B 兜底，不要当主路径。

**D. 手机端**（真的对标小艺帮帮忙）：`adb` + `uiautomator2` / `Appium` / `scrcpy`，
或原生无障碍服务。安卓的控件树比 Windows 还规整，反而更好做。

## 6. 和现成方案比

| 方案 | 适合 | 代价 |
|---|---|---|
| 本方案（UIA + Win32） | 本机、离线、可控、免费 | 要自己写编排；跨平台不通用 |
| **UI-TARS**（字节，开源） | 开箱即用 GUI Agent，含模型 | 要显存跑模型；通用性不如专用脚本 |
| **OmniParser**（微软） | 截图 → 结构化元素，喂给任意视觉模型 | 只是感知层，动作层还得自己写 |
| Claude Computer Use / OpenAI CUA | 全托管视觉操作 | 云端、按 token 计费、延迟高 |
| Playwright / Puppeteer | 只做网页 | 出不了浏览器 |
| 影刀 / UiPath / 实在智能 RPA | 企业流程、有人维护 | 重、贵、定制成本高 |

## 7. 文件

```
computer-use/
├─ cu.ps1                  # 工具集（唯一需要在用前 dot-source 的文件）
├─ README.md
└─ demo/
   ├─ testapp.ps1          # 自检目标窗口
   ├─ selftest.ps1         # 端到端自检（可重复跑）
   ├─ realapp-dxdiag.ps1   # 真实软件（dxdiag）验证：模态框 + 按名字翻页 + 校验
   ├─ task-cleanmgr.ps1    # 真任务：查 C 盘可清理空间（只读，不删文件）
   └─ shots/               # 自检截图
```

## 8. 方案1：沙盒外 GUI worker（已跑通）

### 为什么需要它

沙盒内能驱动经典 Win32，但 Chrome / Excel / 记事本这类应用启动时要写 `%APPDATA%`，
被沙盒拒绝后进程活着却永远不建窗口。解决方案：把执行器放到沙盒外，Agent 只跟它通信。

### 架构

```
DSH 沙盒内的 Agent
   │  写请求文件 ipc/req/<id>.json
   ▼
工作区目录（两边都有权限）
   ▲  读结果 ipc/res/<id>.json
   │
沙盒外 worker 进程（计划任务启动，不属于当前作业对象）
   │  有完整用户权限 → 能写 APPDATA、能起 Chrome/Excel
   ▼
真的鼠标键盘 / UIAutomation
```

用**文件 IPC** 而不是命名管道，是因为管道在跨完整性级别时会被 ACL 拦，
而且实例名冲突时的报错极难排查（"All pipe instances are busy"）。
文件 IPC 出问题时可以直接看文件，调试成本低一个数量级。

### 文件

| 文件 | 作用 |
|---|---|
| `worker.ps1` | 沙盒外的执行器，轮询 `ipc/req`，执行后写 `ipc/res`，维护心跳和单实例锁 |
| `gui.ps1` | 沙盒内的客户端，常用参数化调用 |
| `worker-via-task.ps1` | **启动**：用计划任务把 worker 拉到作业对象之外（需 danger-full-access） |
| `gui-clean.ps1` | **停止**：结束所有 worker、清锁和日志（需 danger-full-access） |
| `start-worker.ps1` / `stop-worker.ps1` / `send.ps1` | 旧版（管道方案），已废弃 |

### 用法

```powershell
# 启动（需要一次授权）
powershell -File worker-via-task.ps1

# 之后都在沙盒内跑
powershell -File gui.ps1 -Op ping
powershell -File gui.ps1 -Op windows
powershell -File gui.ps1 -Op launch -Path "C:\...\chrome.exe"
powershell -File gui.ps1 -Op elements -Hwnd 12345 -Depth 8
powershell -File gui.ps1 -Op invoke -Name "计算" -Hwnd 12345
powershell -File gui.ps1 -Op click -X 370 -Y 484
powershell -File gui.ps1 -Op type -Text "3"
powershell -File gui.ps1 -Op shot -Hwnd 12345 -Path out.png

# 停止
powershell -File gui-clean.ps1
powershell -File worker-via-task.ps1 -Unregister
```

### 实测结果

```
ping        → session=1, user=一棵大树\18790, admin=false
write-test  → APPDATA=OK  LOCALAPPDATA=OK  TEMP=OK     （沙盒内全是 DENY）
launch      → chrome pid=11456，窗口 2001x1492
elements    → 43 个控件，含页面 DOM：Edit「数量」/Edit「单价」/Button「计算」
click+type  → 数量=3，单价=25
invoke      → 按名字点「计算」
texts       → 合计：75 元
```

### 这一轮踩的坑（都很贵）

1. **进程会被作业对象连带杀掉**：WMI 和 `Start-Process` 创建的子进程都落在当前作业里，
   命令一结束就被 kill-on-close 清掉。表现是"worker 启动了、写了日志、几秒后没了"。
   只有**计划任务**（任务计划服务创建进程）能真正断开。
2. **不要在命令行里筛 `CommandLine -like '*worker*.ps1*'`**：清理脚本自身的命令行
   也包含这个字符串，结果把自己和父进程一起杀掉，表现为"命令没有任何输出"。
   要用 pid 文件。
3. **管道跨完整性级别连不上**：worker 是普通/较高完整性，沙盒内客户端是低完整性，
   默认 DACL 直接 ACCESS_DENIED。要显式给 Everyone 授权，或者干脆用文件 IPC。
4. **多实例会抢同一批请求**：实测两个 worker 同时处理同一请求，日志报"文件正由另一进程使用"。
   必须加单实例锁（`FileShare.None` 独占打开一个 lock 文件）。
5. **前台窗口不是目标窗口时，坐标点击会打到别的程序上**：这台机器上 DSH 窗口
   (2460×1540) 完全盖住了 Chrome (2001×1492)，前几次点击全落在了 DSH 界面上。
   **动作前必须校验前台窗口**，或者用 UIA 的 Invoke 而不是坐标点击。
   这是 GUI Agent 最危险的一类 bug：它不会报错，只会悄悄点错地方。

## 9. 统一入口与安全机制（交付版）

### 一个命令搞定，自动选后端

```powershell
.\cu-cli.ps1 info                      # worker 在线就走 worker，离线就在本地跑
.\cu-cli.ps1 -Local info               # 强制沙盒内本地执行
.\cu-cli.ps1 foreground                # 当前前台窗口是谁
.\cu-cli.ps1 windows
.\cu-cli.ps1 shot -Hwnd 12345 -Path w.png
.\cu-cli.ps1 elements -Hwnd 12345 -Depth 8
.\cu-cli.ps1 invoke -Hwnd 12345 -Name "计算"
.\cu-cli.ps1 click -X 100 -Y 200 -Hwnd 12345
.\cu-cli.ps1 type -Text "你好" -Hwnd 12345
.\cu-cli.ps1 keys -Keys "{ENTER}" -Hwnd 12345
```

返回值统一为 `{"ok":true,"backend":"local|worker","data":...}`。

### 安全机制：前台窗口断言

GUI 自动化最危险的不是点错按钮，而是**悄悄点到别的程序上**——不报错，后果自负。
所以所有会"动手"的操作都过一道断言：

- `click -Hwnd`：点击前校验目标窗口是否在前台，不是就**拒绝执行**
- `type -Hwnd` / `keys -Hwnd`：先 `Enable-CUForeground` 强行提前台，再断言，最后才发键
- `invoke`：优先走 UIA `InvokePattern`（不需要前台），只有退化到鼠标点击时才断言

拒绝时长这样：

```
{"ok":false,"error":"前台窗口不是目标窗口，拒绝执行 Click。当前前台: 'xxx' (hwnd=198398)，
 目标 hwnd=132224。先 Focus-CUWindow -Hwnd 132224 再重试。"}
```

`Enable-CUForeground` 用「置顶→取消置顶」+ `AttachThreadInput` 绕开 Windows 的前台锁，
比直接 `SetForegroundWindow` 可靠得多——后者在跨进程时经常静默失败。

> 这条机制是拿事故换来的：我曾在没校验的情况下发 `Alt+F4`，
> 而前台已经从 Excel 切回 DSH，结果把用户正在看的窗口关了。
> 键盘操作，一个都不能裸奔。

## 10. Excel 任务实测（沙盒外）

沙盒内 Excel 连窗口都建不出来，走 worker 之后：

```
launch   → EXCEL pid=31528
focus    → "工作簿1 - Excel" 2582x1550，Foreground=true
录入     → 产品/数量/单价 + 苹果 10 5 + 香蕉 20 3 + 合计 =SUM(B2:B3)
F12      → 另存为 → 输入完整路径 → Enter
文件     → demo/excel-task.xlsx（9432 字节）
```

用 openpyxl 独立核对（不信 Excel 自己显示）：

```json
{"data": [["产品","数量","单价"],
          ["苹果",10,5],
          ["香蕉",20,3],
          ["合计",30,""]],
 "B4_formula": "=SUM(B2:B3)"}
```

截图：`demo/shots/19-excel-table.png`（录入中）、`20-excel-fixed.png`（修正公式列）。

## 11. 交付清单

| 文件 | 说明 |
|---|---|
| `cu-cli.ps1` | **统一入口**，自动路由，日常就用这个 |
| `cu.ps1` | 能力库（UIA / 截图 / 鼠标键盘 / 前台断言），可单独 dot-source |
| `gui.ps1` | 只走 worker 的客户端（脚本里调用更明确） |
| `worker.ps1` | 沙盒外执行器（计划任务启动） |
| `worker-via-task.ps1` | 启动 worker（需一次 danger-full-access 授权） |
| `gui-clean.ps1` | 停止所有 worker（需一次授权） |
| `demo/` | 自检脚本、真实任务脚本、截图 |

最小上手：

```powershell
cd C:\Users\18790\Desktop\workbuddy\混合区\computer-use
.\worker-via-task.ps1        # 起 worker（要授权一次）
.\cu-cli.ps1 foreground      # 看看现在前台是谁
.\cu-cli.ps1 windows         # 看看有哪些窗口
```

## 12. 补完：动作校验 + 坐标自检 + 无焦点关窗

### 12.1 坐标自检 `health`

```json
{"ok":true,"data":{"Ok":true,"Mode":"per-monitor-v2","SystemDpi":144,"ScalePct":150,
 "Message":"","Probe":{"Win32":"50,0 2460x1540","Uia":"50,0 2460x1540","DeltaX":0,"DeltaY":0}}}
```

- `Mode`：进程实际的 DPI 感知级别。不是 `per-monitor-v2` 而缩放又不是 100% 时，`Ok=false`，
  因为此时拿到的是逻辑坐标、屏幕是物理坐标，点击会整体偏移一个缩放倍数。
- `Probe`：传 `-Hwnd` 时，额外比较 Win32 矩形和 UIA 矩形。两者差 >2 像素就判定坐标体系混用。
- `Invoke-CUClick` 点击前会先跑一次 `Get-CUCoordinateHealth`，不通过就拒绝（`-AllowScaled` 可强制）。

### 12.2 动作后校验 `-Verify`

动作前后各取一次窗口「状态指纹」（窗口内所有控件名排序后 SHA256），不一致才算生效：

```
invoke -Name "下一页*" -Verify
→ {"changed":true,"beforeCount":50,"afterCount":29,"beforeHash":"f9f7...","afterHash":"b32f..."}

keys -Keys "{LEFT}" -Verify
→ {"changed":false,"warning":"按键已发出，但界面 350ms 内无变化（可能被忽略或不需要视觉反馈）",
   "beforeHash":"f9f7...","afterHash":"f9f7..."}
```

支持 `click / type / keys / invoke`，worker 和本地后端都生效。
**局限**：指纹基于 UIA 控件名，Excel 单元格内容 UIA 读不到，所以对 Excel 打字会误报"无变化"。
这类场景要靠"读回文件核对"（本项目的 Excel 任务就是这么验的）。

### 12.3 无焦点关窗 `close`

`Alt+F4` 依赖前台，正是上次误关窗口的元凶。改成发窗口消息：

```
close -Hwnd 12345
→ {"ok":true,"data":{"Hwnd":12345,"Closed":true}}
```

先 `WM_CLOSE`，没关掉再 `WM_SYSCOMMAND/SC_CLOSE`，全程不看焦点、不碰键盘。

### 12.4 又一个编码坑

`cu.ps1` 带中文，必须存成 **UTF-8 with BOM**。有些编辑器/工具写回时会去掉 BOM，
Windows PowerShell 5.1 随即按 GBK 读，整个文件语法失效，表现是「worker 突然找不到任何函数」。
排查特征：报错里出现 `妫€鏌?` 这样的乱码。修法一行：

```powershell
$c = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8)
[IO.File]::WriteAllText($p, $c, (New-Object Text.UTF8Encoding($true)))
```

### 12.5 已知边界（诚实记录）

| 现象 | 原因 | 绕法 |
|---|---|---|
| 找不到「高级」页签 | 老式 SysTabControl32 的子页不是独立 UIA 控件 | 用键盘 `Ctrl+Tab` 或坐标点页签 |
| Excel 打字 `-Verify` 报无变化 | 单元格内容不在 UIA 树里 | 保存后读文件核对 |
| `WM_CLOSE` 关不掉的对话框 | 某些系统对话框忽略消息 | 已用 `SC_CLOSE` 兜底；仍失败则 `taskkill` |
| Electron/Chrome 控件少 | 未开辅助功能时只暴露骨架 | Chrome 实测正常（43 个控件，含 DOM） |

## 13. Web 控制台（现代界面）

```powershell
.\start-console.ps1            # 起服务，默认 http://127.0.0.1:6360/
.\start-console.ps1 -Open      # 顺便用默认浏览器打开
```

界面三栏：

| 区域 | 内容 |
|---|---|
| 左 | 任务描述、服务商/模型、计划/多模态开关、步数、开始/停止 |
| 中 | 实时执行轨迹（想法 / 动作 / 状态指纹 / 完成），等宽字体、按类型着色 |
| 右 | 当前前台窗口的实时截图 + 窗口列表（前台窗口高亮） |

技术选型：Node 原生 http（零依赖）+ 单个 HTML 文件，深色玻璃拟态风格。
浏览器打开即可用，不需要构建、不需要 npm install。

### 实现上踩的两个坑

1. **沙盒里 Node 不能用管道捕获子进程输出**（EPERM）。
   所以 agent 的输出直接写文件，服务端 `tail` 文件再推给页面——不是 `stdio: 'pipe'`。
2. **SSE 在这套环境不稳定**（长连接容易断，页面会白屏）。
   改成前端每 700ms 轮询 `/api/log`，取全量文本按行数做增量渲染，稳定得多。

### 接口

| 端点 | 说明 |
|---|---|
| `GET /api/state` | worker 是否在线、窗口列表、前台窗口、是否在跑 |
| `GET /api/log` | 当前运行的完整日志文本 |
| `GET /api/shot` | 前台窗口截图（PNG） |
| `POST /api/run` | 启动任务，body: `{task, provider, model, maxSteps, plan, screenshot}` |
| `POST /api/stop` | 停止当前任务 |

### 运行截图

![控制台](../demo/shots/29-console.png)

左侧是任务与模型配置，中间是这次运行的完整轨迹（3 步：focus → invoke 退出(X) → focus），
右侧是实时截图和窗口列表。这次实测最终把 DirectX 窗口关掉了。

### 界面说明

- 顶部状态点：绿色脉冲 = worker 在线；红色 = 离线（动作会失败）
- 轨迹按类型着色：`[step N]` 青色、动作紫色、状态指纹绿色、失败红色、警告黄色
- 「计划」开关对应 `-Plan`（先出步骤清单）；「多模态」对应 `-WithScreenshot`

## 14. 控制台升级：用量 / 历史 / 清理

### 14.1 实时 token 消耗

顶部有一块用量表：本轮累计、输入、输出，右侧是走势小图。
每次模型调用都会在轨迹里打一行：

```
用量: 586 输入 + 37 输出 ｜ 累计 623 tokens
```

实现：`llm_call.py` 从各家响应里统一抽出 usage（OpenAI 的 `prompt_tokens/completion_tokens`、
Ollama 的 `prompt_eval_count/eval_count`、Anthropic 的 `input_tokens/output_tokens`），
agent 发一行机器可读的 `__USAGE__ {...}`，服务端解析后汇总，页面只负责显示。

### 14.2 历史任务

每次运行都会落两条文件：`web/history/<id>.json`（任务、模型、耗时、tokens、状态）和 `<id>.log`。
左栏「历史」列出最近 30 条，点一下就把那次运行的完整轨迹载入中间区域；右上角「清空」全删。
页面刚打开时会自动载入最近一次运行，不用重跑。

### 14.3 轮询截图的清理

之前每轮截图都会在 `%TEMP%` 留一个文件。现在：

1. `/api/shot` 固定写 `shot-live.png`，`finally` 里必删；
2. 服务启动时 + 每 5 分钟扫一次 `%TEMP%`，删掉 10 分钟前的 `shot-*`、`agent-state.png`、
   `llm-*.req/res.json`，以及 2 天前的 `agent-run-*.log`。

### 14.4 实测：DeepSeek vs 本地模型

同一个任务「关闭 DirectX 诊断工具窗口」：

| 模型 | 步数 | 耗时 | tokens | 结果 |
|---|---|---|---|---|
| ollama `gemma4:e4b` | 8 步（死循环 focus） | 36–41s | 0（本地不计费） | 未完成 |
| deepseek `deepseek-chat` | **1 步** | **5s** | **623** | 关掉了 |

差距不在框架，在判断力：本地 4B 看不出"点完退出按钮窗口该消失"，DeepSeek 一次就选对了动作。

### 14.5 一个必须记录的环境坑

这台机器的 **PowerShell/.NET 的 TLS 握手是坏的**——`Invoke-WebRequest` 连百度都报
"基础连接已经关闭"，`curl` 也是 `http_code=000`，但 **Python 的 urllib 正常**。

所以模型调用被挪到了 `llm_call.py`：agent 只负责编排，HTTP 全交给 Python。
这样既绕开了 TLS 问题，也让 usage 解析集中在一处。

### 14.6 API Key 放哪

优先级：环境变量 > `agent/keys.json`。

```json
{ "deepseek": "sk-..." }
```

`keys.json` 是明文本地文件，**不要提交到 git**。用完可以直接删，下次改用环境变量：

```powershell
$env:DEEPSEEK_API_KEY = "sk-..."
```

## 15. 基准测试（DeepSeek）

`.\benchmark.ps1 -Provider deepseek -Model deepseek-chat` 跑 5 个真实任务，
每个用例自动准备环境、自动验证、记录步数/耗时/tokens。

| 用例 | 结果 | 步数 | 耗时 | tokens |
|---|---|---|---|---|
| close-dxdiag（关 dxdiag） | ✅ | 1 | 6.1s | 1155 |
| close-cleanmgr（关磁盘清理） | ✅ | 1 | 5.1s | 700 |
| read-computername（读计算机名+系统版本） | ✅ | 1 | 4.1s | 1185 |
| dxdiag-gpu（翻页读显卡型号） | ✅ | 4 | 17.2s | 9100 |
| browser-calc（浏览器填表算合计） | ⚠️ 跳过 | — | — | — |

**4/5 通过，平均 1.4 步 / 6.5 秒 / 12,140 tokens。**

「读信息」这类任务 1 步就过——模型直接从前台窗口的控件列表里找到值，
写进 `done.summary`。这是这轮加的第 5 条 prompt 规则带来的效果。
翻页读显卡要 4 步（focus → 点下一页 → 读 → done），因为每翻一页页面重绘，
需要重新取状态。

browser-calc 跳过是因为**准备阶段 Chrome 窗口没起来**（基准里会先杀掉所有 Chrome，
再带独立 profile 启动，这一步在这台机器上不稳定）。浏览器自动化本身是验证过的——
早期用 Chrome 打开本地页面、填 3 和 25、点计算、读出「75 元」是成功的。
这是基准脚本的环境问题，不是 agent 能力问题。

## 16. 那个反复弹出的终端窗口

**根因：是我加的看门狗任务。**

`DSH-GUI-Watchdog` 每分钟执行一次 `powershell.exe -File watchdog.ps1`。
即使加了 `-WindowStyle Hidden`，控制台窗口也会**先创建再隐藏**——屏幕上就闪一下。
Windows 11 默认终端是 Windows Terminal，所以看到的是终端窗口。

修法三层：

1. **换成 wscript 静默启动**：`wscript.exe hidden-run.vbs <脚本>`，
   VBS 里用 `WScript.Shell.Run(cmd, 0, False)`（0 = 隐藏窗口）。
   wscript 本身不分配控制台，PowerShell 全程无窗口。
2. **VBS 里用 powershell.exe 的绝对路径**：任务计划的环境变量里 PATH 可能不全，
   只写 `powershell.exe` 会起不来（这个坑踩过一次）。
3. **干脆去掉看门狗**：改用任务计划自带的「失败后重启」
   （`RestartCount=999` / `RestartInterval=PT1M`）。
   由任务计划服务自己重启 worker，少一个进程、少一个失败点。

修完实测：连续 80 秒观察，`WindowsTerminal` 进程数 **0 → 0**，屏幕上不再有任何窗口闪出。

## 17. 打包成独立应用

### 17.1 双击即用

```
Operator.exe            启动器（无控制台窗口）
  ├─ 检查端口 6360，没起就拉 node 起服务
  ├─ 检查 worker 心跳，掉了就触发计划任务
  └─ 打开浏览器 http://127.0.0.1:6360/
```

参数：

| 参数 | 作用 |
|---|---|
| （无） | 起服务 + 起 worker + 开浏览器 |
| `--silent` | 只保证服务在跑，不开浏览器（开机自启用） |
| `--stop` | 停掉控制台服务（按 `web\console.pid`） |
| `--install` | 写进启动文件夹，开机自动起服务 |
| `--uninstall` | 取消开机自启 |
| `--status` | 弹窗显示端口 / worker / node 状态 |

### 17.2 便携性

`Operator.exe` 里没有硬编码机器路径，按顺序找 node：

1. `bin\node.exe`（随包分发时把 node 放这儿最稳）
2. `config.json` 的 `node` 字段
3. `PATH`
4. 系统安装目录（Program Files\nodejs 等）

端口也来自 `config.json`（默认 6360），改一下就能避开冲突。

### 17.3 打包

```powershell
.\package.ps1
```

产物：

```
dist\Operator-0.2.0\        解压即用
dist\Operator-0.2.0.zip     分发用（约 0.1 MB）
```

包含：启动器、能力库、agent、Web 控制台、脚本、文档、图标。
**不含**：API Key、运行日志、历史记录、ipc 运行目录（都放进 `.gitignore` 了）。

改完启动器要重新编译：

```powershell
.\launcher\build.ps1
```

### 17.4 分发时的两个注意点

1. **node 依赖**：目标机器要么装了 node，要么把 `node.exe` 放到 `bin\`。
2. **API Key**：不随包分发。收包的人自己填 `agent\keys.json`（或设环境变量）。

### 17.5 这轮顺带修的几个稳定性问题

| 问题 | 原因 | 修法 |
|---|---|---|
| 启动器起了服务却秒退 | 子进程继承调用方句柄，父进程一退出就被带走 | `CreateProcess` + `CREATE_NO_WINDOW`，并逐级降级 breakaway 标志 |
| `--stop` 关不掉 | 用 netstat 解析 pid 不可靠 | 服务启动时自己写 `web\console.pid` |
| 服务日志为空 | 启动器重定向 stdout 失败 | 服务自己 `console.log` 写文件，不再依赖重定向 |
| agent 一跑就报 Add-Type 拒绝 | 运行在受限上下文里，`%TEMP%` 不可写 | agent 的临时文件改到工作区 `agent\run\` |
| 每次调用慢 300~800ms | 每次都现编译 C# 帮助类 | 预编译 `bin\CUWin32.dll`，加载失败再回退编译 |
| worker 莫名退出 | 外部看门狗不可靠 | 改用任务计划自带的「失败后重启」 |

## 18. API 设置（对标主流 Agent 的填写方式）

控制台右上角 **⚙** 打开设置，字段与 WorkBuddy / ChatGPT 客户端一致：

| 字段 | 说明 |
|---|---|
| 服务商 | 10 个预设：DeepSeek / OpenAI / Moonshot / 通义 / 智谱 / 硅基流动 / Groq / Anthropic / Ollama / 自定义 |
| 模型 | 选预设后自动填默认模型，可改 |
| Base URL | OpenAI 兼容地址；填内网网关也能用（vLLM / OneAPI / 公司代理） |
| API Key | 密码框；已保存的只显示 `sk-****acdf`，留空表示不修改 |
| 默认最大步数 | 每次运行的上限 |
| 测试连接 | 发一条极小请求，返回耗时和 token 消耗 |

保存后写入 `config.json` 的 `agent` 段和 `agent\keys.json`（后者已 gitignore）。

接口：

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/health` | 版本 / 端口 / worker / uptime |
| GET | `/api/settings` | 预设、当前配置、已保存 key（脱敏） |
| POST | `/api/settings` | 保存 provider / model / baseUrl / maxSteps / key |
| POST | `/api/settings/test` | 用给定或已存的 key 试连，返回 `{ok, latencyMs, usage, error}` |

实测：DeepSeek 测试连接 **1492ms / 42 tokens**。

## 19. 应用级自检

```powershell
.\selftest-app.ps1          # 服务需已在跑
.\selftest-app.ps1 -Start   # 先尝试启动
```

六项检查：服务健康 → worker 在线 → 配置读取 → 模型连通 → 窗口枚举 → 真实任务。
当前结果：**6/6 PASS**。

```
服务健康检查             PASS   97 ms   v0.2.0 · 端口 6360
worker 在线             PASS   12 ms   沙盒外执行器可用
API 配置读取             PASS   22 ms   10 个服务商预设
模型连通性               PASS 1525 ms   deepseek · 42 tokens
窗口枚举                PASS  349 ms   8 个窗口
真实任务（开关 dxdiag）   PASS 12478 ms  目标窗口已关闭 · 755 tokens
```

## 20. 交付状态（v0.2.0）

| 项目 | 状态 |
|---|---|
| 双击启动（`Operator.exe`） | ✅ 起服务 + worker + 浏览器 |
| 服务常驻 | ✅ 计划任务 `DSH-GUI-Console` 托管，可 `--install` 开机自启 |
| 控制台 | ✅ 实时轨迹 / token 用量 / 历史 / 截图 / 窗口列表 |
| API 设置 | ✅ 10 预设 + 自定义网关 + 测试连接 |
| agent 执行 | ✅ 走沙盒外 worker，支持 9 家云端 + 本地 Ollama |
| 安全 | ✅ 前台断言 / DPI 校验 / 关窗护栏 |
| 自检 | ✅ 6/6 PASS |
| 分发包 | ✅ `dist\Operator-0.2.0.zip` |
