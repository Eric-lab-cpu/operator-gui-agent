# 更新日志

## 0.6.0 — 2026-10-27

### 新增：定时任务
- 侧栏「定时任务」区块：新建 / 编辑 / 删除 / 启用暂停，每 15 秒刷新状态
- 服务端每 30 秒检查一次，到点自动触发（同一时间只跑一个，避免抢鼠标）
- 接口：`GET/POST /api/schedules`、`POST /api/schedules/delete`、`POST /api/schedules/run`
- 配置存 `schedules.json`（已 gitignore）

### 托盘：进一步排查（结论）
- 试过：图标句柄 Clone + DestroyIcon、AUMID、系统图标替换、注册表提升
- 现象：进程存活、`NotifyIcon.Visible = true`、无异常，但 Explorer 折叠面板里始终没有本程序
- 对照：同一会话用 PowerShell 建 NotifyIcon 能正常注册 → 机制可用，差异未定位
- 结论：代码逻辑正确，问题在本机会话的 Shell 侧；保底方案是手动双击 `OperatorTray.exe` 或重启 Explorer

## 0.5.1
- 托盘日志、图标句柄修复、注册表提升改为按路径匹配

## 0.5.0
- 托盘 + 任务栏状态窗口 + 托盘守护 + 全生命周期验证

## 0.4.0
- 快捷指令、浅色主题、导出轨迹、历史重跑、完成通知

## 0.3.0
- 可视化 API 设置、应用级自检、计划任务托管

## 0.2.0
- 首个可分发版本

## 0.1.0
- 能力库与沙盒外 worker