using System;
using System.Diagnostics;
using System.IO;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

// Operator —— GUI Agent 桌面应用的启动器
//
// 双击：确保控制台服务在跑 → 确保沙盒外 worker 在 → 打开浏览器
// 参数：
//   --silent     只保证服务和 worker 在跑，不开浏览器（开机自启用）
//   --stop       停掉控制台服务
//   --install    把 --silent 写进启动文件夹（开机自启）
//   --uninstall  移除开机自启
//   --status     弹窗显示当前状态（端口 / worker / 版本）
//
// 便携性：node 的查找顺序是 bin\node.exe → config.json 的 node 字段 →
//         PATH → 系统安装目录。换机器时把 node.exe 放进 bin\ 即可。
namespace OperatorLauncher
{
    // 完全分离地启动进程：不继承句柄、不创建控制台、脱离当前作业对象。
    // 用途：由启动器拉起 node 服务，让服务独立存活，且不把调用方的 stdout 句柄传下去。
    static class NativeProcess
    {
        [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
        struct STARTUPINFO
        {
            public int cb;
            public string lpReserved;
            public string lpDesktop;
            public string lpTitle;
            public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
            public short wShowWindow, cbReserved2;
            public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
        }

        [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
        struct PROCESS_INFORMATION
        {
            public IntPtr hProcess, hThread;
            public int dwProcessId, dwThreadId;
        }

        [System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
        static extern bool CreateProcess(string app, string cmd, IntPtr pa, IntPtr ta, bool inherit,
            uint flags, IntPtr env, string cwd, ref STARTUPINFO si, out PROCESS_INFORMATION pi);

        [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
        static extern bool CloseHandle(IntPtr h);

        const uint CREATE_NO_WINDOW = 0x08000000;
        const uint CREATE_BREAKAWAY_FROM_JOB = 0x01000000;
        const uint CREATE_NEW_PROCESS_GROUP = 0x00000200;
        const int STARTF_USESHOWWINDOW = 0x00000001;
        const short SW_HIDE = 0;

        public static bool StartDetached(string exe, string args, string cwd)
        {
            var si = new STARTUPINFO();
            si.cb = System.Runtime.InteropServices.Marshal.SizeOf(typeof(STARTUPINFO));
            si.dwFlags = STARTF_USESHOWWINDOW;
            si.wShowWindow = SW_HIDE;

            string cmd = "\"" + exe + "\" " + args;
            bool ok = false;
            // 逐个降级：作业对象可能禁止 breakaway，此时去掉该 flag 再试
            uint[] flagSets = new uint[]
            {
                CREATE_NO_WINDOW | CREATE_BREAKAWAY_FROM_JOB | CREATE_NEW_PROCESS_GROUP,
                CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP,
                CREATE_NO_WINDOW
            };
            var pi = new PROCESS_INFORMATION();
            foreach (uint flags in flagSets)
            {
                pi = new PROCESS_INFORMATION();
                try
                {
                    ok = CreateProcess(exe, cmd, IntPtr.Zero, IntPtr.Zero, false,
                        flags, IntPtr.Zero, cwd, ref si, out pi);
                }
                catch { ok = false; }
                if (ok) break;
            }

            if (ok && pi.hProcess != IntPtr.Zero) CloseHandle(pi.hProcess);
            if (ok && pi.hThread != IntPtr.Zero) CloseHandle(pi.hThread);
            return ok;
        }
    }
    static class Program
    {
        static int Port = 6360;
        static string BaseDir = "";
        static string ConfigPath = "";

        [STAThread]
        static int Main(string[] args)
        {
            BaseDir = AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\');
            ConfigPath = Path.Combine(BaseDir, "config.json");

            LoadConfig();

            string mode = args.Length > 0 ? args[0].ToLowerInvariant() : "";

            if (mode == "--install") { InstallAutostart(); return 0; }
            if (mode == "--uninstall") { UninstallAutostart(); return 0; }
            if (mode == "--stop") { StopServer(); return 0; }
            if (mode == "--status") { ShowStatus(); return 0; }

            string webDir = FindWebDir();
            if (webDir == null)
            {
                ShowError("找不到 web\\server.mjs。\n\n请把 Operator.exe 放在应用根目录（与 web、agent 同级）后重试。");
                return 1;
            }

            bool silent = (mode == "--silent");
            SilentMode = silent;

            if (!PortOpen(Port))
            {
                if (!StartServer(webDir))
                {
                    if (!silent) ShowError("启动控制台服务失败。\n\n没有找到可用的 node.exe。\n把它放到 bin\\node.exe，或在 config.json 里填 node 路径。");
                    return 1;
                }
            }

            EnsureWorker();

            if (!WaitPort(Port, 20))
            {
                if (!silent) ShowError("服务 20 秒内没有起来。\n\n端口：" + Port + "\n日志：" + Path.Combine(BaseDir, "web", "console.log"));
                return 1;
            }

            EnsureTray();

            if (!silent)
            {
                try { Process.Start(new ProcessStartInfo("http://127.0.0.1:" + Port + "/") { UseShellExecute = true }); }
                catch (Exception ex) { ShowError("打开浏览器失败：" + ex.Message); }
            }
            return 0;
        }

        // ── 配置 ──────────────────────────────────────────────
        static void LoadConfig()
        {
            try
            {
                if (!File.Exists(ConfigPath)) return;
                string json = File.ReadAllText(ConfigPath);
                Match m = Regex.Match(json, "\"port\"\\s*:\\s*(\\d+)");
                if (m.Success)
                {
                    int p;
                    if (int.TryParse(m.Groups[1].Value, out p) && p > 0 && p < 65536) Port = p;
                }
            }
            catch { }
        }

        static string ConfigNode()
        {
            try
            {
                if (!File.Exists(ConfigPath)) return null;
                Match m = Regex.Match(File.ReadAllText(ConfigPath), "\"node\"\\s*:\\s*\"([^\"]+)\"");
                if (m.Success) return m.Groups[1].Value.Replace("\\\\", "\\");
            }
            catch { }
            return null;
        }

        static string FindWebDir()
        {
            string p = Path.Combine(BaseDir, "web");
            if (File.Exists(Path.Combine(p, "server.mjs"))) return p;
            string p2 = Path.Combine(BaseDir, "app", "web");
            if (File.Exists(Path.Combine(p2, "server.mjs"))) return p2;
            return null;
        }

        // ── node 发现 ─────────────────────────────────────────
        static string NodePath()
        {
            var candidates = new System.Collections.Generic.List<string>();
            candidates.Add(Path.Combine(BaseDir, @"bin\node.exe"));
            string cfg = ConfigNode();
            if (!string.IsNullOrEmpty(cfg)) candidates.Add(cfg);

            string pf = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
            string pf86 = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86);
            candidates.Add(Path.Combine(pf, @"nodejs\node.exe"));
            candidates.Add(Path.Combine(pf86, @"nodejs\node.exe"));
            candidates.Add(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"Programs\nodejs\node.exe"));
            candidates.Add(@"C:\Users\18790\.dsh\dsh-runtimes\dsh-primary-runtime\dependencies\node\bin\node.exe");

            foreach (string c in candidates)
            {
                try { if (!string.IsNullOrEmpty(c) && File.Exists(c)) return c; } catch { }
            }

            try
            {
                foreach (string d in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';'))
                {
                    if (string.IsNullOrWhiteSpace(d)) continue;
                    string p = Path.Combine(d.Trim(), "node.exe");
                    if (File.Exists(p)) return p;
                }
            }
            catch { }

            return null;
        }

        // ── 端口 ──────────────────────────────────────────────
        static bool PortOpen(int port)
        {
            try
            {
                using (var c = new TcpClient())
                {
                    IAsyncResult ar = c.BeginConnect("127.0.0.1", port, null, null);
                    if (!ar.AsyncWaitHandle.WaitOne(500)) return false;
                    c.EndConnect(ar);
                    return true;
                }
            }
            catch { return false; }
        }

        static bool WaitPort(int port, int seconds)
        {
            for (int i = 0; i < seconds * 4; i++)
            {
                if (PortOpen(port)) return true;
                Thread.Sleep(250);
            }
            return PortOpen(port);
        }

        // ── 服务启停 ──────────────────────────────────────────
        static bool StartServer(string webDir)
        {
            string node = NodePath();
            if (node == null) return false;
            try
            {
                // 直接起 node：不用 cmd 中转（某些环境下 cmd 子进程会被拦），
                // 日志由 server.mjs 自己写 web\console.log
                return NativeProcess.StartDetached(node, "server.mjs", webDir);
                return true;
            }
            catch { return false; }
        }
        // WMI 单独成方法：万一 System.Management 加载不了，也只崩这一块，
        // 不会因为 JIT 失败把整个 StopServer 带走。
        static void KillNodeServers()
        {
            try
            {
                var searcher = new System.Management.ManagementObjectSearcher(
                    "SELECT ProcessId, CommandLine FROM Win32_Process WHERE Name='node.exe'");
                foreach (System.Management.ManagementObject mo in searcher.Get())
                {
                    string cmd = (mo["CommandLine"] as string) ?? "";
                    if (cmd.IndexOf("server.mjs", StringComparison.OrdinalIgnoreCase) < 0) continue;
                    try { Process.GetProcessById(Convert.ToInt32(mo["ProcessId"])).Kill(); } catch { }
                }
            }
            catch (Exception e) { LLog("KillNodeServers 失败: " + e.Message); }
        }

        static void StopServer()
        {
            LLog("StopServer 开始");
            try { File.WriteAllText(Path.Combine(BaseDir, "ipc", "stop.flag"), "1"); }
            catch (Exception e) { LLog("写停止标记失败: " + e.Message); }
            for (int round = 0; round < 6; round++)
            {
                try
                {
                    foreach (var p in Process.GetProcessesByName("OperatorTray"))
                    {
                        try { p.Kill(); LLog("已结束托盘 pid=" + p.Id); } catch (Exception e) { LLog("托盘 kill 失败: " + e.Message); }
                    }
                }
                catch (Exception e) { LLog("托盘遍历失败: " + e.Message); }

                try
                {
                    string pidFile = Path.Combine(BaseDir, "web", "console.pid");
                    if (File.Exists(pidFile))
                    {
                        int pid;
                        if (int.TryParse(File.ReadAllText(pidFile).Trim(), out pid))
                        {
                            try { Process p = Process.GetProcessById(pid); p.Kill(); p.WaitForExit(3000); LLog("已结束服务 pid=" + pid); }
                            catch (Exception e) { LLog("服务 kill: " + e.Message); }
                        }
                        try { File.Delete(pidFile); } catch { }
                    }
                }
                catch (Exception e) { LLog("读 pid 失败: " + e.Message); }

                KillNodeServers();
                System.Threading.Thread.Sleep(400);

                // 给托盘一点时间自己退出
                for (int i = 0; i < 10 && Process.GetProcessesByName("OperatorTray").Length > 0; i++)
                    System.Threading.Thread.Sleep(200);
                bool trayLeft = Process.GetProcessesByName("OperatorTray").Length > 0;
                bool nodeLeft = Process.GetProcessesByName("node").Length > 0;
                if (!trayLeft && !nodeLeft) { LLog("StopServer 完成（第 " + (round + 1) + " 轮）"); return; }
            }
            LLog("StopServer 达到最大轮次");
        }
        // ── worker ────────────────────────────────────────────
        static void EnsureWorker()
        {
            string hb = Path.Combine(BaseDir, "ipc", "heartbeat.txt");
            bool stale = true;
            try
            {
                if (File.Exists(hb))
                {
                    string content = File.ReadAllText(hb).Trim();
                    int bar = content.IndexOf('|');
                    if (bar > 0)
                    {
                        DateTime ts;
                        if (DateTime.TryParse(content.Substring(bar + 1), out ts))
                            stale = (DateTime.Now - ts).TotalSeconds > 20;
                    }
                }
            }
            catch { stale = true; }

            if (!stale) return;

            try
            {
                var psi = new ProcessStartInfo("schtasks.exe", "/Run /TN DSH-GUI-Worker")
                {
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    WindowStyle = ProcessWindowStyle.Hidden
                };
                Process.Start(psi);
            }
            catch { }
        }

        // ── 托盘 ──────────────────────────────────────────────
        static bool SilentMode = false;

        static void LLog(string m)
        {
            try { File.AppendAllText(Path.Combine(BaseDir, "launcher.log"), DateTime.Now.ToString("HH:mm:ss") + " " + m + "\r\n"); }
            catch { }
        }
        // 让托盘图标默认显示在通知区（而不是折叠菜单里）
        static void PromoteTray()
        {
            try
            {
                string id = "{8F1A2C3D-4E5B-4A6C-9D7E-0A1B2C3D4E5F}";
                using (var k = Registry.CurrentUser.CreateSubKey(@"Control Panel\NotifyIconSettings\" + id))
                {
                    if (k == null) return;
                    k.SetValue("ExecutablePath", Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Operator", "OperatorTray.exe"), RegistryValueKind.String);
                    k.SetValue("IsPromoted", 1, RegistryValueKind.DWord);
                    k.SetValue("InitialTooltip", "Operator", RegistryValueKind.String);
                }
            }
            catch { }
        }
        static string RuntimeDir()
        {
            // 托盘必须运行在纯 ASCII 路径下：
            // Explorer 不会为中文路径中的 exe 创建通知区条目（本机实测确认）。
            // C:\Operator 是首选安装位置；写不进去时退回工作区（那里图标不会显示）。
            var cands = new System.Collections.Generic.List<string>();
            cands.Add(@"C:\Operator");
            string lad = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            if (!string.IsNullOrEmpty(lad)) cands.Add(Path.Combine(lad, "Operator"));
            cands.Add(Path.Combine(BaseDir, "runtime"));

            foreach (string c in cands)
            {
                try
                {
                    Directory.CreateDirectory(c);
                    string probe = Path.Combine(c, ".wtest");
                    File.WriteAllText(probe, "ok");
                    File.Delete(probe);
                    LLog("可用运行目录: " + c);
                    return c;
                }
                catch (Exception e) { LLog("不可写: " + c + " -> " + e.Message); }
            }
            return null;
        }

        static void EnsureTray()
        {
            try
            {
                LLog("EnsureTray 开始 silent=" + SilentMode);

                // 首选：已经装好的 ASCII 运行目录（setup-runtime.ps1 预置的）。
                // 即使当前进程写不进去，只要文件在就能直接启动 —— 图标也才会显示。
                string installed = @"C:\Operator\OperatorTray.exe";
                if (File.Exists(installed) && Process.GetProcessesByName("OperatorTray").Length == 0)
                {
                    string cfgSrc0 = Path.Combine(BaseDir, "config.json");
                    try
                    {
                        if (File.Exists(cfgSrc0)) File.Copy(cfgSrc0, @"C:\Operator\config.json", true);
                        File.WriteAllText(@"C:\Operator\appdir.txt", BaseDir);
                    }
                    catch { }
                    var psi0 = new ProcessStartInfo(installed, SilentMode ? "--hidden" : "")
                    {
                        UseShellExecute = false,
                        CreateNoWindow = true,
                        WorkingDirectory = @"C:\Operator"
                    };
                    var p0 = Process.Start(psi0);
                    LLog("已启动托盘(已安装) pid=" + (p0 == null ? 0 : p0.Id) + " from " + installed);
                    return;
                }

                string targetDir = RuntimeDir();

                string src = Path.Combine(BaseDir, "OperatorTray.exe");
                string dst = targetDir == null ? null : Path.Combine(targetDir, "OperatorTray.exe");

                // 目标目录不可写时，只要那里已经有一份（安装时预置的）就直接用
                if (targetDir != null && (dst == null || !File.Exists(dst) || File.GetLastWriteTimeUtc(src) > File.GetLastWriteTimeUtc(dst)))
                {
                    try
                    {
                        foreach (var p in Process.GetProcessesByName("OperatorTray")) { try { p.Kill(); } catch { } }
                        System.Threading.Thread.Sleep(250);
                        File.Copy(src, dst, true);
                        string cfgSrc = Path.Combine(BaseDir, "config.json");
                        if (File.Exists(cfgSrc)) File.Copy(cfgSrc, Path.Combine(targetDir, "config.json"), true);
                        File.WriteAllText(Path.Combine(targetDir, "appdir.txt"), BaseDir);
                        LLog("已同步托盘到 " + targetDir);
                    }
                    catch (Exception e) { LLog("同步失败（用已有副本）: " + e.Message); }
                }

                if (dst == null || !File.Exists(dst))
                {
                    // 最后的兜底：直接在原地跑（图标会进不了通知区，但菜单/守护仍可用）
                    LLog("没有可用的 ASCII 目录，原地启动托盘");
                    dst = src;
                    targetDir = BaseDir;
                }

                if (Process.GetProcessesByName("OperatorTray").Length > 0) { LLog("托盘已在运行"); return; }
                var psi = new ProcessStartInfo(dst, SilentMode ? "--hidden" : "")
                {
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    WorkingDirectory = targetDir
                };
                var proc = Process.Start(psi);
                LLog("已启动托盘 pid=" + (proc == null ? 0 : proc.Id) + " from " + dst);
            }
            catch (Exception e) { LLog("EnsureTray 异常: " + e.Message); }
        }
        // ── 状态 ──────────────────────────────────────────────
        static void ShowStatus()
        {
            string node = NodePath();
            string hb = Path.Combine(BaseDir, "ipc", "heartbeat.txt");
            string worker = "未启动";
            try
            {
                if (File.Exists(hb))
                {
                    string c = File.ReadAllText(hb).Trim();
                    int bar = c.IndexOf('|');
                    if (bar > 0)
                    {
                        DateTime ts;
                        if (DateTime.TryParse(c.Substring(bar + 1), out ts))
                        {
                            double age = (DateTime.Now - ts).TotalSeconds;
                            worker = age < 20 ? ("在线（pid " + c.Substring(0, bar) + "）") : ("离线，心跳 " + (int)age + " 秒前");
                        }
                    }
                }
            }
            catch { }

            string msg =
                "Operator —— GUI Agent\n\n" +
                "版本：" + Version() + "\n" +
                "目录：" + BaseDir + "\n\n" +
                "控制台端口：" + Port + (PortOpen(Port) ? "（运行中）" : "（未运行）") + "\n" +
                "worker：" + worker + "\n" +
                "托盘：" + (Process.GetProcessesByName("OperatorTray").Length > 0 ? "运行中" : "未运行") + "\n" +
                "node：" + (node ?? "未找到") + "\n\n" +
                "启动：双击 Operator.exe\n" +
                "只起服务：Operator.exe --silent\n" +
                "停止服务：Operator.exe --stop";

            MessageBox.Show(msg, "Operator", MessageBoxButtons.OK, MessageBoxIcon.Information);
        }

        static string Version()
        {
            try
            {
                string vf = Path.Combine(BaseDir, "VERSION");
                if (File.Exists(vf)) return File.ReadAllText(vf).Trim();
            }
            catch { }
            return "0.1.0";
        }

        // ── 自启 ──────────────────────────────────────────────
        static string StartupLnk()
        {
            return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Startup), "Operator Console.lnk");
        }

        static void InstallAutostart()
        {
            try
            {
                string lnk = StartupLnk();
                string exe = Path.Combine(BaseDir, "Operator.exe");
                string ps =
                    "$w=New-Object -ComObject WScript.Shell;" +
                    "$s=$w.CreateShortcut('" + lnk.Replace("'", "''") + "');" +
                    "$s.TargetPath='" + exe.Replace("'", "''") + "';" +
                    "$s.Arguments='--silent';" +
                    "$s.WorkingDirectory='" + BaseDir.Replace("'", "''") + "';" +
                    "$s.WindowStyle=7;$s.Save()";
                var psi = new ProcessStartInfo("powershell.exe", "-NoProfile -ExecutionPolicy Bypass -Command \"" + ps + "\"")
                {
                    UseShellExecute = false,
                    CreateNoWindow = true
                };
                Process.Start(psi).WaitForExit(15000);
                MessageBox.Show("已设置开机自启。\n\n登录后控制台服务会自动运行，打开 http://127.0.0.1:" + Port + "/ 即可。\n取消：Operator.exe --uninstall",
                    "Operator", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
            catch (Exception ex) { ShowError("设置自启失败：" + ex.Message); }
        }

        static void UninstallAutostart()
        {
            try
            {
                string lnk = StartupLnk();
                if (File.Exists(lnk)) File.Delete(lnk);
                MessageBox.Show("已取消开机自启。", "Operator", MessageBoxButtons.OK, MessageBoxIcon.Information);
            }
            catch (Exception ex) { ShowError("取消失败：" + ex.Message); }
        }

        static void ShowError(string msg)
        {
            MessageBox.Show(msg, "Operator", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }
    }
}
