# 怎么用

## 最快路径：双击

```
双击 Operator.exe  →  自动起服务、拉起 worker、打开浏览器
```

窗口里就是控制台。关掉浏览器不影响服务；要彻底停掉：`Operator.exe --stop`。

开机自启：`Operator.exe --install`（取消：`--uninstall`）
看状态：`Operator.exe --status`

> 分发版：`dist\Operator-<版本>.zip`，解压到任意目录即可运行（需要本机有 node，
> 或者把 node.exe 放到 `bin\` 下）。

---
<#
    这是给人看的说明，不是脚本。
#>

# 怎么用（3 分钟）

## 0. 现在就能用

| 组件 | 状态 |
|---|---|
| 控制台 | http://127.0.0.1:6360 （已在运行） |
| worker（沙盒外执行器） | 在线，pid 31800 |
| DeepSeek Key | 已配在 `agent\keys.json` |

只要控制台和 worker 都在线，直接用就行。掉线了看第 6 节。

---

## 1. 最常用：用控制台点

打开 http://127.0.0.1:6360

1. **左栏写目标**，一句话，越具体越好：
   - `关闭 DirectX 诊断工具 窗口`
   - `读出这台电脑的计算机名和操作系统版本`
   - `在页面里把「数量」填 3、「单价」填 25，点「计算」，读出合计`
2. **选模型**：`deepseek` / `deepseek-chat`（推荐），或 `ollama` / `gemma4:e4b`（本地免费但笨）
3. **点「开始执行」**
4. **中间看轨迹**：每一步的想法、动作、状态指纹、token 用量
5. **右栏**：实时看前台窗口截图 + 窗口列表（绿色高亮的是当前前台）
6. **左栏「历史」**：点一下回看某次运行的完整轨迹

可选项：
- `计划`：先让模型列步骤清单再执行（任务超过 3 步时有用）
- `多模态`：把窗口截图一起喂给模型（认图标 / 自绘界面）
- `截图刷新`：右栏截图的刷新频率，关掉可以省一点 CPU

---

## 2. 命令行跑一个任务

```powershell
cd C:\Users\18790\Desktop\workbuddy\混合区\computer-use

# 云端（快、准）
.\agent\agent.ps1 -Task "关闭 DirectX 诊断工具 窗口" -Provider deepseek -Model deepseek-chat

# 本地（免费、慢、笨）
.\agent\agent.ps1 -Task "关闭 DirectX 诊断工具 窗口" -Provider ollama -Model gemma4:e4b
```

常用参数：

| 参数 | 作用 |
|---|---|
| `-MaxSteps 8` | 最多几步（默认 8） |
| `-Plan` | 先出计划再执行 |
| `-WithScreenshot` | 附带截图（需多模态模型） |
| `-Backend auto\|local\|worker` | 强制走哪边（默认 auto） |
| `-DryRun` | 只让模型出动作、不真的执行 |
| `-LogFile x.log` | 轨迹写文件（控制台就是这么取日志的） |

接自己的网关：

```powershell
.\agent\agent.ps1 -Task "..." -Provider custom -BaseUrl http://10.0.0.5:8000/v1 -Model qwen2.5-vl-7b
```

自检所有服务商：

```powershell
.\agent\agent.ps1 -Doctor
```

---

## 3. 不用模型，手动操作界面

想做确定性的脚本，用 CLI，一条命令一个动作：

```powershell
.\cu-cli.ps1 windows                          # 有哪些窗口（拿 hwnd）
.\cu-cli.ps1 elements -Hwnd 12345 -Depth 8    # 窗口里有哪些控件（名字/坐标）
.\cu-cli.ps1 foreground                       # 当前前台是谁

.\cu-cli.ps1 invoke -Hwnd 12345 -Name "确定" -Verify   # 按名字点（推荐）
.\cu-cli.ps1 type  -Hwnd 12345 -Text "你好"            # 输入文字
.\cu-cli.ps1 keys  -Hwnd 12345 -Keys "{ENTER}"         # 快捷键
.\cu-cli.ps1 close -Hwnd 12345                         # 关窗口（不依赖焦点）
.\cu-cli.ps1 shot  -Hwnd 12345 -Path a.png             # 截图
```

`-Verify` 会在动作后比对状态指纹：`{"changed":true}` 才算生效。

自检坐标是否可信（DPI 缩放下的保护）：

```powershell
.\cu-cli.ps1 health
```

---

## 4. 跑基准

```powershell
.\benchmark.ps1 -Provider deepseek -Model deepseek-chat
.\benchmark.ps1 -Provider deepseek -Only close-dxdiag      # 只跑一个用例
```

会依次跑 5 个真实任务，自动准备环境、自动验证、输出表格，结果存 `bench\results-*.json`。

---

## 5. 启停

```powershell
.\start-console.ps1 -Open      # 起控制台并打开浏览器（已在跑就直接给地址）
.\worker-via-task.ps1          # 手动起 worker（一般不用，任务计划会自启）
.\gui-clean.ps1                # 停 worker
```

worker 由计划任务 `DSH-GUI-Worker` 托管：挂了 1 分钟后自动重启（最多 999 次），
启动方式是 `wscript hidden-run.vbs`，**不会弹任何窗口**。

---

## 6. 出问题了看这里

| 现象 | 原因 | 怎么办 |
|---|---|---|
| 控制台打不开 | node 服务没起 | `.\start-console.ps1 -Open` |
| 顶部显示「worker 离线」 | worker 挂了 | 等 1 分钟自动重启；或 `.\worker-via-task.ps1` |
| 报「前台窗口不是目标窗口，拒绝执行」 | 保护机制生效 | 先 `focus -Hwnd`，或改用 `invoke`（不需要前台） |
| 报「坐标映射不可信，拒绝点击」 | DPI 感知异常 | `.\cu-cli.ps1 health` 看 Mode |
| 模型调用失败：HTTP 401 | key 无效 | 检查 `agent\keys.json` 或环境变量 |
| 模型返回空内容 | 本地思考型模型预算不够 | 换 `gemma4:e4b`，或调大 `num_predict` |
| agent 反复 focus 同一个窗口 | 模型判断力不足 | 换云端模型；或把任务写得更具体 |
| 中文乱码 | 脚本没存成 UTF-8 with BOM | 见 README 12.4 |

---

## 7. Key 放哪

优先级：**环境变量 > `agent\keys.json`**

```powershell
$env:DEEPSEEK_API_KEY = "sk-..."
```

或写进 `agent\keys.json`（明文，**别提交到 git**）：

```json
{ "deepseek": "sk-...", "moonshot": "sk-..." }
```

---

## 8. 目录结构

```
computer-use\
├─ cu.ps1              能力库（UIA/截图/鼠标键盘/前台断言/坐标自检）
├─ cu-cli.ps1          命令行入口（自动选本地或 worker）
├─ gui.ps1             只走 worker 的客户端
├─ worker.ps1          沙盒外执行器
├─ worker-via-task.ps1 起 worker
├─ gui-clean.ps1       停 worker
├─ start-console.ps1   起控制台
├─ benchmark.ps1       基准测试
├─ hidden-run.vbs      静默启动器（计划任务用）
├─ agent\              agent.ps1 / llm_call.py / keys.json
└─ web\                控制台（index.html + server.mjs + history\）
```
