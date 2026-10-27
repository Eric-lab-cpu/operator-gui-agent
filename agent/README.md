# 独立 GUI Agent 原型（模型驱动）

一个小艺帮帮忙式的桌面 Agent 骨架：**你只说目标，模型自己决定点哪儿**。

## 1. 它已经能做什么

```
$ .\agent.ps1 -Task "把 DirectX 诊断工具窗口关掉" -Provider ollama -Model gemma4:e4b

任务: 把 DirectX 诊断工具窗口关掉
模型: ollama / gemma4:e4b
──────────────────────────────────────────────────────
[step 1] 想法: 任务是关闭 DirectX 诊断工具窗口，该窗口的 HWND 是 4983194。可以直接使用 close 动作关闭窗口。
          动作: {"type":"close","hwnd":4983194}
完成: 已关闭窗口 4983194
──────────────────────────────────────────────────────
共执行 1 个动作          耗时 4.8s
```

外部确认：窗口列表里 DirectX 窗口剩余 **0**。这不是脚本写死的流程，窗口是模型自己从列表里挑的。

## 2. 架构

```
        ┌─────────────────────────────────────────┐
        │  任务描述（自然语言）                    │
        └───────────────┬─────────────────────────┘
                        ▼
   ┌────────────┐   ┌────────────┐   ┌────────────┐
   │ 感知        │→ │ 决策（模型）│→ │ 执行        │
   │ 窗口列表    │   │ 输出一个    │   │ cu.ps1     │
   │ 控件树      │   │ JSON 动作   │   │ 鼠标/键盘   │
   │ 前台窗口    │   └─────┬──────┘   └─────┬──────┘
   └────────────┘         │                │
         ▲                │                ▼
         │          ┌─────▼──────┐   ┌────────────┐
         └──────────│ 记忆/反馈   │←──│ 校验        │
                    │ 无进展提示  │   │ 状态指纹     │
                    └────────────┘   └────────────┘
```

四层职责：

| 层 | 负责 | 在哪个文件 |
|---|---|---|
| 感知 | 窗口列表、前台窗口、控件树压缩成短文本 | `agent.ps1` 的 `Get-CompactState` |
| 决策 | 一次只产出一个 JSON 动作 | `Invoke-LLM`（多 provider） |
| 执行 | 动作落地，全部过安全断言 | `cu.ps1` |
| 校验 | 动作前后状态指纹对比，没变就提示模型换招 | 主循环 |

## 3. 动作空间（模型能输出的全部动作）

```json
{"type":"focus","hwnd":123}                    把窗口提到前台
{"type":"invoke","hwnd":123,"name":"确定"}      按名字点控件（推荐）
{"type":"click","hwnd":123,"x":100,"y":200}     按坐标点
{"type":"type","hwnd":123,"text":"你好"}        输入文本
{"type":"keys","hwnd":123,"keys":"^s"}          发快捷键
{"type":"close","hwnd":123}                     关闭窗口
{"type":"wait","ms":800}                        等待
{"type":"done","summary":"做了什么"}             结束
```

动作空间刻意做小：**能被校验的动作才值得存在**。
没有"拖拽""滚动"是因为它们很难确认是否生效，先不给模型用。

## 4. 模型接口：一套代码接三种 API

配置在 `agent\config.json`（从 `config.example.json` 复制）：

```json
{
  "ollama":    { "baseUrl": "http://127.0.0.1:11434" },
  "openai":    { "baseUrl": "https://api.openai.com/v1", "apiKeyEnv": "OPENAI_API_KEY" },
  "anthropic": { "baseUrl": "https://api.anthropic.com", "apiKeyEnv": "ANTHROPIC_API_KEY" }
}
```

| Provider | 覆盖范围 | 说明 |
|---|---|---|
| `ollama` | 本地任意模型 | 无网络、无费用、隐私最好；4B~9B 够做单步决策 |
| `openai` | 所有 OpenAI 兼容接口 | 改 `baseUrl` 就能接 DeepSeek / 通义 / 豆包 / Kimi / 智谱 / vLLM |
| `anthropic` | Claude | 消息格式不同，已在 `Invoke-LLM` 里单独适配 |

换模型只改命令行参数：

```powershell
.\agent.ps1 -Task "..." -Provider ollama    -Model qwen3.5:9b
.\agent.ps1 -Task "..." -Provider openai    -Model deepseek-chat
$env:OPENAI_API_KEY="sk-..."; .\agent.ps1 -Provider openai -Model gpt-4o -Task "..."
```

## 5. 实测记录（都是本机跑出来的）

| 模型 | 结果 | 耗时 | 备注 |
|---|---|---|---|
| `gemma4:e4b` | ✅ 1 步关窗 | 4.8s | 不思考，输出直接，最适合做动作决策 |
| `qwen3.5:9b` | ⚠️ 需要大预算 | 30s+ | 先思考后回答，`num_predict` 给小了会返回空 |
| `qwen3.5:4b` | ⚠️ 选错窗口 | 12s | 能产合法 JSON，但会把 DSH 当成目标 |

踩到的坑：

1. **思考型模型必须给足 `num_predict`**。`qwen3.5` 把预算全花在 thinking 上，
   `content` 是空字符串——表现是"模型没有给出可解析的 JSON"，很容易误判成接口坏了。
2. **小模型会复读无效动作**。第一次跑，它连续 4 次点"退出(X)"，界面纹丝不动。
   加了"状态指纹没变就注入一条提示"之后，第 4 步自己改用 `close`，成功了。
   这条反馈是 Agent 从"能跑"到"能收敛"的关键。
3. **模型不知道任务已经完成**。关完窗它还会继续找窗口。补了"关窗即完成"的终止判定。

## 6. 安全：模型再笨也不能乱关东西

`close` 动作有护栏：**任务描述里没提到的窗口一律拒绝关闭**。

```
拒绝关闭「Agent实现UI界面鼠标键盘操作 — DeepSeek Harness」：
任务里没提到它（安全护栏，可用 -AllowClosePattern 显式放行）
```

需要关闭一批窗口时显式放行：

```powershell
.\agent.ps1 -Task "关掉测试窗口" -AllowClosePattern "*测试*"
```

底层还有三道（都在 `cu.ps1` 里，与 agent 无关）：

- `click` / `type` / `keys` 前断言前台窗口就是目标窗口
- `click` 前检查 DPI 坐标映射是否可信
- `close` 走窗口消息，不看焦点

## 7. 和"小艺帮帮忙"还差什么

已经有的：感知 + 决策 + 执行 + 校验 + 失败反馈 + 安全护栏。

还差的：

| 差距 | 现状 | 补法 |
|---|---|---|
| 多步规划 | 每步独立决策，容易绕圈 | 加 planner：先出步骤清单，再逐步执行 |
| 视觉理解 | 只喂控件树，没喂截图 | 支持多模态：截图 base64 进 prompt，认图标/自绘 UI |
| 记忆 | 只有最近的对话 | 任务级记忆：做过什么、失败过什么，压缩后带上 |
| 常驻性 | 手动起进程 | 开机自启 + 看门狗（本轮实测 worker 会莫名退出） |
| 模型质量 | 本地小模型勉强够用 | 换 7B 以上的 UI 专用模型，或云端多模态 |
| 手机端 | 无 | Android：adb + uiautomator2，那套比 Windows 规整 |

## 8. 下一步建议

按性价比排序：

1. **换模型先于改架构**。同一个 loop，把 `gemma4:e4b` 换成支持 tool-calling 的
   云端多模态模型，成功率会有数量级差别——现在限制上限的是模型，不是框架。
2. **加 planner**。任务超过 3 步时，先让模型输出步骤清单（JSON 数组），
   再逐步执行；每步完成打勾。这能解决"绕圈"的大部分情况。
3. **把 JSON 文本改成原生 function calling**。现在靠"输出 JSON 再解析"，
   模型偶尔会加解释文字；原生 tool-use 由 API 保证结构。
4. **看门狗**。worker 退出是实测现象（计划任务里也会退），需要定时探活 + 自动重启。

## 9. 云端模型接入

### 9.1 内置预设（一个参数切换）

| `-Provider` | 默认 baseUrl | 需要的环境变量 |
|---|---|---|
| `ollama` | `http://127.0.0.1:11434` | 无 |
| `openai` | `https://api.openai.com/v1` | `OPENAI_API_KEY` |
| `deepseek` | `https://api.deepseek.com/v1` | `DEEPSEEK_API_KEY` |
| `moonshot` | `https://api.moonshot.cn/v1` | `MOONSHOT_API_KEY` |
| `dashscope` | `https://dashscope.aliyuncs.com/compatible-mode/v1` | `DASHSCOPE_API_KEY` |
| `zhipu` | `https://open.bigmodel.cn/api/paas/v4` | `ZHIPUAI_API_KEY` |
| `siliconflow` | `https://api.siliconflow.cn/v1` | `SILICONFLOW_API_KEY` |
| `groq` | `https://api.groq.com/openai/v1` | `GROQ_API_KEY` |
| `anthropic` | `https://api.anthropic.com` | `ANTHROPIC_API_KEY` |

```powershell
$env:DEEPSEEK_API_KEY = "sk-..."
.\agent.ps1 -Task "把 DirectX 诊断工具窗口关掉" -Provider deepseek -Model deepseek-chat
```

### 9.2 自定义服务商

任何 OpenAI 兼容接口（vLLM、LM Studio、公司内网网关、OneAPI）都能接，两种方式：

```powershell
# 方式一：命令行直接给
.\agent.ps1 -Provider custom -BaseUrl http://10.0.0.5:8000/v1 -Model qwen2.5-vl-7b -Task "..."

# 方式二：写进 config.json，起个名字反复用
{
  "providers": {
    "my-gateway": {
      "baseUrl": "http://10.0.0.5:8000/v1",
      "style": "openai",
      "apiKeyEnv": "GATEWAY_KEY",
      "model": "qwen2.5-vl-7b"
    }
  }
}
.\agent.ps1 -Provider my-gateway -Task "..."
```

### 9.3 先自检再跑任务

```powershell
.\agent.ps1 -Doctor
```

```
ollama       OK     gemma4:e4b  8.4s
deepseek     跳过   未设置 DEEPSEEK_API_KEY
anthropic    跳过   未设置 ANTHROPIC_API_KEY
```

没配 key 的服务商显示"跳过"而不是报错；配了但连不通会显示具体错误。
这一步不跑任务，只发一条极小请求，用来快速定位"是网络问题还是模型问题"。

### 9.4 中文乱码的坑（已修）

`Invoke-RestMethod` 按响应头的 charset 解码，很多兼容接口不声明 charset，
中文就成了 `ä»»åŠ¡æ˜¯...`。改成拿原始字节自己按 UTF-8 解：

```powershell
$resp = Invoke-WebRequest ... -UseBasicParsing
$text = [Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
```

## 10. 本轮改进（都有实测）

| 改进 | 解决什么问题 | 实测 |
|---|---|---|
| 云端预设 + 自定义 | 只能跑本地小模型 | 走 Ollama 的 `/v1` 兼容端点跑通，与 DeepSeek/Kimi 同一条代码路径 |
| `-Doctor` | 不知道 key 配没配对、通不通 | 9 个服务商逐条自检 |
| `-WithScreenshot` | 只看控件树，认不出图标/自绘 UI | 附 2000px 截图，12.7s 返回 |
| `-Plan` | 超过 3 步容易绕圈 | 先出步骤清单再执行 |
| 连续无进展停止 | 小模型死循环烧钱 | 3 次指纹不变即停止 |
| UTF-8 解码 | 云端返回中文乱码 | 已修，见 9.4 |
| **看门狗** | **worker 会莫名退出（实测两次）** | **杀掉后 2 秒自动恢复** |

看门狗细节：

```powershell
.\worker-via-task.ps1 -WithWatchdog     # 一次性装上
```

计划任务 `DSH-GUI-Watchdog` 每分钟检查一次心跳：
- 心跳 > 45 秒没更新 → 触发 `DSH-GUI-Worker` 重新拉起
- 进程还在但 > 3 分钟没心跳 → 判定假死，先结束再拉起

实测日志：

```
[10-27 00:56:02] 心跳已过期 51 秒，尝试拉起 worker
[10-27 00:56:02] 已触发计划任务 DSH-GUI-Worker
[10-27 00:56:04] worker 已恢复
```

## 11. 现在的位置

```
本地小模型 ──┐
云端多模态 ──┼──→ 同一个 loop ──→ 同一套执行/校验/护栏
内网网关   ──┘
```

换模型不换代码，这是这轮最主要的价值。剩下的短板在**决策质量**而不是基础设施：
本地 4B 能干活但会绕圈，云端大模型接进来之后，成功率会有数量级变化。
