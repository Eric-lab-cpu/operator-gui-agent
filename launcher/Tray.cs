using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Net;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

// OperatorTray —— 托盘宿主
//
// 作用：应用运行时在通知区常驻一个图标，右击可开控制台 / 看状态 / 停服务 / 退出；
//       双击直接打开控制台；图标颜色反映服务与 worker 状态。
//       「状态窗口」是一个正常窗口，会在任务栏留下按钮。
namespace OperatorTray
{
    static class NativeIcon
    {
        [System.Runtime.InteropServices.DllImport("user32.dll")]
        public static extern bool DestroyIcon(IntPtr h);
    }

    static class Program
    {
        static string LogPath = "";

        static void Log(string msg)
        {
            try
            {
                if (LogPath == "") LogPath = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "tray.log");
                File.AppendAllText(LogPath, DateTime.Now.ToString("HH:mm:ss") + " " + msg + "\r\n");
            }
            catch { }
        }

        static int Port = 6360;
        static string BaseDir = "";
        static NotifyIcon tray;
        static StatusForm form;
        static System.Windows.Forms.Timer timer;
        static bool lastOk = false;
        static int downCount = 0;      // 服务连续不可用次数
        static int workerDown = 0;
        static bool promoted = false;     // worker 连续离线次数

        [STAThread]
        static void Main(string[] args)
        {
            bool startHidden = args.Length > 0 && args[0] == "--hidden";
            // 单实例：已经有一个托盘在跑就直接退出
            bool created;
            var mutex = new Mutex(true, "OperatorTray.SingleInstance", out created);
            if (!created) return;

            BaseDir = AppDomain.CurrentDomain.BaseDirectory.TrimEnd('\\');
            LoadPort();

            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            Log("启动 tray base=" + BaseDir + " port=" + Port);
            BuildTray();
            Log("托盘已建 visible=" + tray.Visible);
            PromoteIcon();
            Log("提升流程结束");
            BuildForm();

            timer = new System.Windows.Forms.Timer { Interval = 3000 };
            timer.Tick += (s, e) => Refresh();
            timer.Start();

            Refresh();

            if (!startHidden) form.Show();
            Application.Run();
        }

        // ── 配置 ─────────────────────────────────────────────
        static void LoadPort()
        {
            try
            {
                string cfg = Path.Combine(BaseDir, "config.json");
                if (!File.Exists(cfg)) return;
                Match m = Regex.Match(File.ReadAllText(cfg), "\"port\"\\s*:\\s*(\\d+)");
                if (m.Success) Port = int.Parse(m.Groups[1].Value);
            }
            catch { }
        }

        static string BaseUrl { get { return "http://127.0.0.1:" + Port; } }

        // ── HTTP ─────────────────────────────────────────────
        static string Get(string path, int timeoutMs = 1500)
        {
            try
            {
                var req = (HttpWebRequest)WebRequest.Create(BaseUrl + path);
                req.Timeout = timeoutMs;
                req.ReadWriteTimeout = timeoutMs;
                using (var resp = (HttpWebResponse)req.GetResponse())
                using (var sr = new StreamReader(resp.GetResponseStream()))
                    return sr.ReadToEnd();
            }
            catch { return null; }
        }

        static string Post(string path)
        {
            try
            {
                var req = (HttpWebRequest)WebRequest.Create(BaseUrl + path);
                req.Method = "POST";
                req.ContentLength = 0;
                req.Timeout = 1500;
                using (var resp = (HttpWebResponse)req.GetResponse())
                using (var sr = new StreamReader(resp.GetResponseStream()))
                    return sr.ReadToEnd();
            }
            catch { return null; }
        }

        // ── 让图标默认出现在通知区（Windows 11 默认会把新图标收进折叠区）──
        static void PromoteIcon()
        {
            // Win11 的通知区设置键名是「可执行文件路径的哈希」。
            // 这里用 RegistryKey.OpenBaseKey + 显式只读权限，尽量绕开 ACL 限制。
            try
            {
                string self = Path.Combine(BaseDir, "OperatorTray.exe").ToLowerInvariant();
                using (var baseKey = RegistryKey.OpenBaseKey(RegistryHive.CurrentUser, RegistryView.Registry64))
                using (var root = baseKey.OpenSubKey(@"Control Panel\NotifyIconSettings", false))
                {
                    if (root == null) { Log("通知区注册表不可用"); return; }
                    string[] names = root.GetSubKeyNames();
                    Log("通知区条目数: " + names.Length);
                    foreach (string name in names)
                    {
                        using (var k = root.OpenSubKey(name, false))
                        {
                            if (k == null) continue;
                            string exe = (k.GetValue("ExecutablePath") as string) ?? "";
                            if (exe.ToLowerInvariant() != self) continue;
                            Log("找到本程序条目: " + name + " IsPromoted=" + k.GetValue("IsPromoted"));
                            using (var kw = root.OpenSubKey(name, true))
                            {
                                if (kw == null) { Log("条目不可写"); return; }
                                kw.SetValue("IsPromoted", 1, RegistryValueKind.DWord);
                                Log("已提升");
                                promoted = true;
                            }
                            return;
                        }
                    }
                    Log("尚无本程序条目（图标首次显示后由 Explorer 创建）");
                }
            }
            catch (Exception e) { Log("提升失败: " + e.Message); }
        }
        // ── 托盘 ─────────────────────────────────────────────
        static void BuildTray()
        {
            tray = new NotifyIcon();
            tray.Icon = MakeIcon(true);
            tray.Text = "Operator · 正在启动…";
            tray.Visible = true;
            tray.DoubleClick += (s, e) => OpenConsole();

            var menu = new ContextMenuStrip();
            menu.Items.Add("打开控制台", null, (s, e) => OpenConsole());
            menu.Items.Add("显示状态窗口", null, (s, e) => ShowForm());
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("重启服务", null, (s, e) => RunExe("--silent"));
            menu.Items.Add("停止服务", null, (s, e) => { RunExe("--stop"); Refresh(); });
            menu.Items.Add("开机自启", null, (s, e) => RunExe("--install"));
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("退出", null, (s, e) => Quit());
            tray.ContextMenuStrip = menu;

            tray.BalloonTipTitle = "Operator 已启动";
            tray.BalloonTipText = "控制台：http://127.0.0.1:" + Port + "/";
            tray.BalloonTipIcon = ToolTipIcon.Info;
            try { tray.ShowBalloonTip(2500); } catch { }
        }

        static Icon MakeIcon(bool ok)
        {
            var bmp = new Bitmap(32, 32);
            using (var g = Graphics.FromImage(bmp))
            {
                g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
                g.Clear(Color.Transparent);
                using (var b = new SolidBrush(ok ? Color.FromArgb(45, 212, 191) : Color.FromArgb(251, 113, 133)))
                    g.FillEllipse(b, 1, 1, 30, 30);
                using (var b2 = new SolidBrush(Color.FromArgb(12, 18, 28)))
                {
                    g.FillEllipse(b2, 7, 7, 18, 18);
                    g.FillRectangle(b2, 14, 10, 4, 8);
                }
            }
            IntPtr h = bmp.GetHicon();
            Icon ico = (Icon)Icon.FromHandle(h).Clone();
            NativeIcon.DestroyIcon(h);
            bmp.Dispose();
            return ico;
        }

        // ── 状态窗口（任务栏有按钮）──────────────────────────
        static void BuildForm()
        {
            form = new StatusForm();
            form.Text = "Operator · 状态";
            form.Size = new Size(380, 250);
            form.StartPosition = FormStartPosition.CenterScreen;
            form.ShowInTaskbar = true;
            form.FormClosing += (s, e) => { e.Cancel = true; form.Hide(); };   // 关窗 = 收进托盘
        }

        static void ShowForm()
        {
            form.Show();
            form.WindowState = FormWindowState.Normal;
            form.Activate();
            Refresh();
        }

        // ── 刷新 ─────────────────────────────────────────────
        static void Refresh()
        {
            string health = Get("/api/health");
            bool ok = health != null && Regex.IsMatch(health, "\"ok\"\\s*:\\s*true");
            string tip;
            string stateLine;
            bool worker = false;
            bool running = false;

            if (!ok)
            {
                tip = "Operator · 服务未运行（双击打开，右键可启动）";
                stateLine = "服务：未运行";
            }
            else
            {
                worker = health != null && Regex.IsMatch(health, "\"worker\"\\s*:\\s*true");
                running = health != null && Regex.IsMatch(health, "\"running\"\\s*:\\s*true");
                string tok = "";
                string st = Get("/api/state");
                if (st != null)
                {
                    Match m = Regex.Match(st, "\"total\"\\s*:\\s*(\\d+)");
                    if (m.Success && m.Groups[1].Value != "0") tok = " · " + m.Groups[1].Value + " tok";
                }
                tip = "Operator · 服务在线" + (worker ? " · worker 在线" : " · worker 离线") + (running ? " · 执行中" : "") + tok;
                stateLine = "服务：运行中\nworker：" + (worker ? "在线" : "离线") + "\n任务：" + (running ? "执行中" : "空闲");
            }

            if (!promoted) PromoteIcon();   // 还没提升就每轮重试一次
            // ── 守护：托盘是唯一长期存活且不受沙盒限制的进程 ──
            if (!ok)
            {
                downCount++;
                workerDown = 0;
                if (downCount >= 2) { RunExe("--silent"); downCount = 0; }
            }
            else
            {
                downCount = 0;
                if (!worker) {
                    workerDown++;
                    if (workerDown >= 2) { RestartWorker(); workerDown = 0; }
                } else { workerDown = 0; }
            }

            if (ok != lastOk)
            {
                lastOk = ok;
                tray.Icon = MakeIcon(ok);
            }
            tray.Text = tip.Length > 63 ? tip.Substring(0, 63) : tip;
            form.SetState(stateLine, tip);
        }

        // ── 动作 ─────────────────────────────────────────────
        static void OpenConsole()
        {
            try { Process.Start(new ProcessStartInfo(BaseUrl + "/") { UseShellExecute = true }); }
            catch { }
        }

        static void RunExe(string args)
        {
            try
            {
                var psi = new ProcessStartInfo(Path.Combine(BaseDir, "Operator.exe"), args)
                {
                    UseShellExecute = false,
                    CreateNoWindow = true,
                    WorkingDirectory = BaseDir
                };
                Process.Start(psi);
            }
            catch { }
        }

        static void RestartWorker()
        {
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

        static void Quit()
        {
            try { Post("/api/app/stop"); } catch { }
            Thread.Sleep(400);
            try { RunExe("--stop"); } catch { }
            tray.Visible = false;
            tray.Dispose();
            Application.Exit();
        }
    }

    // ── 状态窗口 ─────────────────────────────────────────────
    class StatusForm : Form
    {
        Label lblTitle, lblState, lblHint;
        Button btnOpen, btnHide;

        public StatusForm()
        {
            BackColor = Color.FromArgb(12, 16, 24);
            ForeColor = Color.FromArgb(232, 238, 247);
            Font = new Font("Microsoft YaHei UI", 9F);

            lblTitle = new Label
            {
                Text = "Operator · GUI Agent",
                Font = new Font("Microsoft YaHei UI", 12F, FontStyle.Bold),
                ForeColor = Color.FromArgb(94, 234, 212),
                AutoSize = true,
                Location = new Point(20, 18)
            };
            lblState = new Label
            {
                AutoSize = true,
                Location = new Point(22, 52),
                ForeColor = Color.FromArgb(200, 210, 226),
                Font = new Font("Consolas", 9.5F)
            };
            lblHint = new Label
            {
                AutoSize = false,
                Size = new Size(330, 30),
                Location = new Point(22, 128),
                ForeColor = Color.FromArgb(130, 142, 162),
                Text = "关闭窗口会收进托盘，服务继续运行。"
            };
            btnOpen = new Button
            {
                Text = "打开控制台",
                Location = new Point(22, 168),
                Size = new Size(150, 34),
                FlatStyle = FlatStyle.Flat,
                BackColor = Color.FromArgb(94, 234, 212),
                ForeColor = Color.FromArgb(6, 19, 16)
            };
            btnOpen.FlatAppearance.BorderSize = 0;
            btnOpen.Click += (s, e) =>
            {
                try { Process.Start(new ProcessStartInfo("http://127.0.0.1:" + PortOf() + "/") { UseShellExecute = true }); } catch { }
            };

            btnHide = new Button
            {
                Text = "收进托盘",
                Location = new Point(182, 168),
                Size = new Size(150, 34),
                FlatStyle = FlatStyle.Flat,
                BackColor = Color.FromArgb(26, 32, 44),
                ForeColor = Color.FromArgb(220, 228, 240)
            };
            btnHide.FlatAppearance.BorderSize = 0;
            btnHide.Click += (s, e) => Hide();

            Controls.Add(lblTitle);
            Controls.Add(lblState);
            Controls.Add(lblHint);
            Controls.Add(btnOpen);
            Controls.Add(btnHide);
        }

        static int PortOf()
        {
            try
            {
                string cfg = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "config.json");
                if (File.Exists(cfg))
                {
                    Match m = Regex.Match(File.ReadAllText(cfg), "\"port\"\\s*:\\s*(\\d+)");
                    if (m.Success) return int.Parse(m.Groups[1].Value);
                }
            }
            catch { }
            return 6360;
        }

        public void SetState(string state, string tip)
        {
            if (lblState != null) lblState.Text = state;
            if (lblHint != null) lblHint.Text = tip.Length > 54 ? tip.Substring(0, 54) + "…" : tip;
        }
    }
}
