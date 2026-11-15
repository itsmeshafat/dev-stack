// DevStackApp.cs - Windows control app for dev-stack.
// Compiled with the in-box .NET Framework csc.exe (no .NET SDK required).
// Mirrors the macOS app: live module status, per-module and whole-stack control, update banner,
// privileged-helper install, Help (rendered from docs\HELP.md), and a Donate link.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace DevStack
{
    internal sealed class ModuleRow
    {
        public string Name;
        public string State;
        public string Detail;
    }

    internal sealed class DbPanel : Panel
    {
        public DbPanel()
        {
            this.DoubleBuffered = true;
            this.SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint, true);
            this.UpdateStyles();
        }
    }

    internal sealed class DbTable : TableLayoutPanel
    {
        public DbTable()
        {
            this.DoubleBuffered = true;
            this.SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint, true);
            this.UpdateStyles();
        }
    }

    internal sealed class MainForm : Form
    {
        private readonly string cliPath;
        private readonly string pkgDir;
        private readonly string appDir;

        private bool busy;
        private Label summaryLabel;
        private Label actionLabel;
        private Panel modulePanel;
        private TableLayoutPanel moduleTable;
        private TextBox consoleBox;
        private Control helperBanner;
        private Control updateBanner;
        private Label updateLabel;
        private string updateUrl = "";
        private Timer pollTimer;
        private readonly Dictionary<string, RowUi> rowMap = new Dictionary<string, RowUi>();
        private readonly Dictionary<string, bool> lastStates = new Dictionary<string, bool>();
        private bool refreshing;
        private NotifyIcon trayIcon;
        private bool exiting;
        private bool trayHintShown;

        private sealed class RowUi
        {
            public Label Name;
            public Label Detail;
            public Label State;
            public Button Start;
            public Button Stop;
            public Button Restart;
        }

        private static readonly Color OkColor = Color.FromArgb(46, 160, 67);
        private static readonly Color WarnColor = Color.FromArgb(191, 135, 0);
        private static readonly Color MutedColor = Color.FromArgb(120, 120, 120);
        private static readonly Color AccentColor = Color.FromArgb(110, 86, 207);
        private static readonly Color BodyColor = Color.FromArgb(45, 45, 52);
        private static readonly Color HeadingColor = Color.FromArgb(28, 28, 34);
        private static readonly Color CodeBack = Color.FromArgb(244, 245, 249);
        private static readonly Color CodeColor = Color.FromArgb(40, 70, 120);

        private Font helpH1, helpH2, helpH3, helpRegular, helpBold, helpMono, helpMonoBold;

        public MainForm()
        {
            string localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            pkgDir = Path.Combine(localAppData, "devstack", "pkg");
            cliPath = Path.Combine(pkgDir, "devstack.ps1");
            appDir = Path.Combine(localAppData, "Programs", "DevStack");

            BuildUi();
            try { this.Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); }
            catch { }

            SetupTray();
            this.FormClosing += delegate(object s, FormClosingEventArgs e)
            {
                // Keep running in the tray for any normal close (X, Alt+F4, posted WM_CLOSE).
                // Only a real Quit (exiting = true) or an OS shutdown actually closes the app.
                if (!exiting && e.CloseReason != CloseReason.WindowsShutDown && e.CloseReason != CloseReason.TaskManagerClosing)
                {
                    e.Cancel = true;
                    try { HideToTray(); }
                    catch (Exception ex) { LogAppError("HideToTray: " + ex); }
                }
            };

            this.Load += delegate { RefreshStatus(); CheckHelper(); CheckForUpdates(false); };

            pollTimer = new Timer();
            pollTimer.Interval = 4000;
            pollTimer.Tick += delegate { if (!busy) { RefreshStatus(); } };
            pollTimer.Start();
        }

        public static void LogAppError(string message)
        {
            try
            {
                string dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "devstack");
                Directory.CreateDirectory(dir);
                File.AppendAllText(Path.Combine(dir, "app-error.log"),
                    DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " " + message + "\r\n");
            }
            catch { }
        }

        [STAThread]
        public static void Main()
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.ThreadException += delegate(object s, System.Threading.ThreadExceptionEventArgs e) { LogAppError("ThreadException: " + e.Exception); };
            AppDomain.CurrentDomain.UnhandledException += delegate(object s, UnhandledExceptionEventArgs e) { LogAppError("Unhandled: " + e.ExceptionObject); };
            Application.Run(new MainForm());
        }

        // ---------------------------------------------------------------- UI
        private void BuildUi()
        {
            this.Text = "Dev Stack";
            this.DoubleBuffered = true;
            this.AutoScaleMode = AutoScaleMode.Dpi;
            this.Width = 900;
            this.Height = 820;
            this.MinimumSize = new Size(760, 640);
            this.Font = new Font("Segoe UI", 9f);
            this.BackColor = Color.FromArgb(246, 247, 251);
            this.StartPosition = FormStartPosition.CenterScreen;

            MenuStrip menu = new MenuStrip();
            ToolStripMenuItem fileMenu = new ToolStripMenuItem("Dev Stack");
            ToolStripMenuItem updates = new ToolStripMenuItem("Check for Updates...", null, delegate { CheckForUpdates(true); });
            ToolStripMenuItem helper = new ToolStripMenuItem("Install privileged helper...", null, delegate { InstallHelper(); });
            ToolStripMenuItem donate = new ToolStripMenuItem("Donate...", null, delegate { OpenUrl("https://www.itsmeshafat.com/donate"); });
            ToolStripMenuItem exit = new ToolStripMenuItem("Exit", null, delegate { ExitApp(); });
            fileMenu.DropDownItems.Add(updates);
            fileMenu.DropDownItems.Add(helper);
            fileMenu.DropDownItems.Add(new ToolStripSeparator());
            fileMenu.DropDownItems.Add(donate);
            fileMenu.DropDownItems.Add(new ToolStripSeparator());
            fileMenu.DropDownItems.Add(new ToolStripMenuItem("Hide to tray", null, delegate { HideToTray(); }));
            fileMenu.DropDownItems.Add(exit);

            ToolStripMenuItem helpMenu = new ToolStripMenuItem("Help");
            ToolStripMenuItem helpItem = new ToolStripMenuItem("Dev Stack Help", null, delegate { ShowHelp(); });
            helpItem.ShortcutKeys = Keys.F1;
            helpMenu.DropDownItems.Add(helpItem);
            helpMenu.DropDownItems.Add(new ToolStripMenuItem("Open config folder", null, delegate { OpenFolder(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".config", "devstack")); }));

            menu.Items.Add(fileMenu);
            menu.Items.Add(helpMenu);
            this.MainMenuStrip = menu;

            TableLayoutPanel root = new TableLayoutPanel();
            root.Dock = DockStyle.Fill;
            root.ColumnCount = 1;
            root.RowCount = 6;
            root.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100f));
            root.RowStyles.Add(new RowStyle(SizeType.AutoSize));   // header
            root.RowStyles.Add(new RowStyle(SizeType.AutoSize));   // helper banner
            root.RowStyles.Add(new RowStyle(SizeType.AutoSize));   // update banner
            root.RowStyles.Add(new RowStyle(SizeType.Percent, 100f)); // modules
            root.RowStyles.Add(new RowStyle(SizeType.Absolute, 150f)); // console
            root.RowStyles.Add(new RowStyle(SizeType.AutoSize));   // footer

            root.Controls.Add(BuildHeader(), 0, 0);
            helperBanner = BuildHelperBanner();
            root.Controls.Add(helperBanner, 0, 1);
            updateBanner = BuildUpdateBanner();
            root.Controls.Add(updateBanner, 0, 2);
            root.Controls.Add(BuildModuleArea(), 0, 3);
            root.Controls.Add(BuildConsole(), 0, 4);
            root.Controls.Add(BuildFooter(), 0, 5);

            this.Controls.Add(root);
            this.Controls.Add(menu);
        }

        private Control BuildHeader()
        {
            TableLayoutPanel p = new TableLayoutPanel();
            p.Dock = DockStyle.Top;
            p.AutoSize = true;
            p.ColumnCount = 1;
            p.RowCount = 2;
            p.Padding = new Padding(18, 14, 18, 10);
            p.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100f));
            p.RowStyles.Add(new RowStyle(SizeType.AutoSize));
            p.RowStyles.Add(new RowStyle(SizeType.AutoSize));

            FlowLayoutPanel titleRow = new FlowLayoutPanel();
            titleRow.AutoSize = true;
            titleRow.WrapContents = false;
            titleRow.FlowDirection = FlowDirection.LeftToRight;
            titleRow.Margin = new Padding(0);

            Label title = new Label();
            title.Text = "Dev Stack";
            title.Font = new Font("Segoe UI", 20f, FontStyle.Bold);
            title.AutoSize = true;
            title.Margin = new Padding(0, 0, 12, 0);

            summaryLabel = new Label();
            summaryLabel.Text = "Loading...";
            summaryLabel.ForeColor = MutedColor;
            summaryLabel.AutoSize = true;
            summaryLabel.Margin = new Padding(0, 10, 0, 0);

            titleRow.Controls.Add(title);
            titleRow.Controls.Add(summaryLabel);

            FlowLayoutPanel buttons = new FlowLayoutPanel();
            buttons.AutoSize = true;
            buttons.WrapContents = true;
            buttons.FlowDirection = FlowDirection.LeftToRight;
            buttons.Margin = new Padding(0, 8, 0, 0);
            buttons.Controls.Add(MakeButton("Start All", delegate { RunAction("start all", "start"); }));
            buttons.Controls.Add(MakeButton("Stop All", delegate { RunAction("stop all", "stop"); }));
            buttons.Controls.Add(MakeButton("Restart All", delegate { RunAction("restart all", "restart"); }));
            buttons.Controls.Add(MakeButton("Refresh", delegate { RefreshStatus(); }));
            buttons.Controls.Add(MakeButton("Help", delegate { ShowHelp(); }));

            p.Controls.Add(titleRow, 0, 0);
            p.Controls.Add(buttons, 0, 1);
            return p;
        }

        private Button MakeButton(string text, EventHandler onClick)
        {
            Button b = new Button();
            b.Text = text;
            b.AutoSize = true;
            b.AutoSizeMode = AutoSizeMode.GrowAndShrink;
            b.MinimumSize = new Size(72, 26);
            b.Padding = new Padding(10, 3, 10, 3);
            b.Margin = new Padding(0, 0, 8, 0);
            b.Click += onClick;
            return b;
        }

        private Control BuildHelperBanner()
        {
            TableLayoutPanel p = new TableLayoutPanel();
            p.Dock = DockStyle.Top;
            p.BackColor = Color.FromArgb(255, 246, 224);
            p.Visible = false;
            p.Padding = new Padding(18, 8, 18, 8);
            p.ColumnCount = 2;
            p.RowCount = 1;
            p.Height = 54;
            p.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100f));
            p.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            p.RowStyles.Add(new RowStyle(SizeType.Percent, 100f));

            Label l = new Label();
            l.Text = "The 'web' module (nginx) and *.test host entries need a one-time privileged helper. Windows will ask for your password once.";
            l.Dock = DockStyle.Fill;
            l.AutoSize = false;
            l.TextAlign = ContentAlignment.MiddleLeft;
            l.Margin = new Padding(0, 0, 12, 0);

            Button b = MakeButton("Install privileged helper...", delegate { InstallHelper(); });
            b.Anchor = AnchorStyles.Right;
            b.Margin = new Padding(0);

            p.Controls.Add(l, 0, 0);
            p.Controls.Add(b, 1, 0);
            return p;
        }

        private Control BuildUpdateBanner()
        {
            TableLayoutPanel p = new TableLayoutPanel();
            p.Dock = DockStyle.Top;
            p.BackColor = Color.FromArgb(232, 240, 254);
            p.Visible = false;
            p.Padding = new Padding(18, 8, 18, 8);
            p.ColumnCount = 2;
            p.RowCount = 1;
            p.Height = 52;
            p.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100f));
            p.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            p.RowStyles.Add(new RowStyle(SizeType.Percent, 100f));

            updateLabel = new Label();
            updateLabel.Text = "";
            updateLabel.Dock = DockStyle.Fill;
            updateLabel.AutoSize = false;
            updateLabel.TextAlign = ContentAlignment.MiddleLeft;
            updateLabel.Margin = new Padding(0, 0, 12, 0);

            FlowLayoutPanel buttons = new FlowLayoutPanel();
            buttons.AutoSize = true;
            buttons.WrapContents = false;
            buttons.Anchor = AnchorStyles.Right;
            buttons.Margin = new Padding(0);
            buttons.Controls.Add(MakeButton("Update now", delegate { RunAction("update", "update", "--yes"); }));
            buttons.Controls.Add(MakeButton("Release notes", delegate { if (updateUrl.Length > 0) OpenUrl(updateUrl); }));
            buttons.Controls.Add(MakeButton("Dismiss", delegate { updateBanner.Visible = false; }));

            p.Controls.Add(updateLabel, 0, 0);
            p.Controls.Add(buttons, 1, 0);
            return p;
        }

        private Control BuildModuleArea()
        {
            modulePanel = new DbPanel();
            modulePanel.Dock = DockStyle.Fill;
            modulePanel.AutoScroll = true;
            modulePanel.BackColor = Color.White;
            modulePanel.Padding = new Padding(16, 6, 16, 6);

            moduleTable = new DbTable();
            moduleTable.Dock = DockStyle.Top;
            moduleTable.AutoSize = true;
            moduleTable.AutoSizeMode = AutoSizeMode.GrowAndShrink;
            moduleTable.BackColor = Color.White;
            moduleTable.ColumnCount = 4;
            moduleTable.RowCount = 0;
            moduleTable.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 130f));   // module
            moduleTable.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100f));    // detail (fills)
            moduleTable.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 96f));    // state
            moduleTable.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 250f));   // actions

            modulePanel.Controls.Add(moduleTable);
            return modulePanel;
        }

        private Control BuildConsole()
        {
            Panel p = new Panel();
            p.Dock = DockStyle.Fill;
            p.Padding = new Padding(16, 6, 16, 6);

            actionLabel = new Label();
            actionLabel.Text = "Console";
            actionLabel.ForeColor = MutedColor;
            actionLabel.Dock = DockStyle.Top;
            actionLabel.Height = 16;

            consoleBox = new TextBox();
            consoleBox.Multiline = true;
            consoleBox.ReadOnly = true;
            consoleBox.ScrollBars = ScrollBars.Both;
            consoleBox.WordWrap = false;
            consoleBox.Font = new Font("Consolas", 9f);
            consoleBox.Dock = DockStyle.Fill;
            consoleBox.BackColor = Color.White;

            p.Controls.Add(consoleBox);
            p.Controls.Add(actionLabel);
            return p;
        }

        private Control BuildFooter()
        {
            TableLayoutPanel p = new TableLayoutPanel();
            p.Dock = DockStyle.Top;
            p.AutoSize = true;
            p.ColumnCount = 2;
            p.RowCount = 1;
            p.Padding = new Padding(18, 6, 18, 6);
            p.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100f));
            p.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            p.RowStyles.Add(new RowStyle(SizeType.Absolute, 20f));

            Label l = new Label();
            l.Text = "Local dev tool - provided as-is, no warranty - back up your databases and projects";
            l.ForeColor = MutedColor;
            l.Font = new Font("Segoe UI", 7.5f);
            l.AutoSize = false;
            l.Dock = DockStyle.Fill;
            l.TextAlign = ContentAlignment.MiddleLeft;
            l.Margin = new Padding(0);

            LinkLabel donate = new LinkLabel();
            donate.Text = "Donate";
            donate.AutoSize = true;
            donate.LinkColor = AccentColor;
            donate.Anchor = AnchorStyles.Right;
            donate.Margin = new Padding(12, 0, 0, 0);
            donate.LinkClicked += delegate { OpenUrl("https://www.itsmeshafat.com/donate"); };

            p.Controls.Add(l, 0, 0);
            p.Controls.Add(donate, 1, 0);
            return p;
        }

        // ---------------------------------------------------------------- process
        private static string QuoteIfNeeded(string s)
        {
            if (s == null) { return ""; }
            if (s.IndexOf(' ') >= 0 || s.IndexOf('\t') >= 0) { return "\"" + s + "\""; }
            return s;
        }

        private static string JoinArgs(string[] args)
        {
            StringBuilder sb = new StringBuilder();
            for (int i = 0; i < args.Length; i++)
            {
                if (i > 0) { sb.Append(' '); }
                sb.Append(QuoteIfNeeded(args[i]));
            }
            return sb.ToString();
        }

        private string Exec(params string[] args)
        {
            if (!File.Exists(cliPath))
            {
                return "devstack CLI not found at " + cliPath + "\r\nRun windows\\install.ps1 first.";
            }
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo();
                psi.FileName = "powershell.exe";
                psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + cliPath + "\" " + JoinArgs(args);
                psi.RedirectStandardOutput = true;
                psi.RedirectStandardError = true;
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;

                StringBuilder sb = new StringBuilder();
                DataReceivedEventHandler handler = delegate(object s, DataReceivedEventArgs e)
                {
                    if (e.Data != null) { lock (sb) { sb.AppendLine(e.Data); } }
                };

                using (Process p = new Process())
                {
                    p.StartInfo = psi;
                    p.OutputDataReceived += handler;
                    p.ErrorDataReceived += handler;
                    p.Start();
                    p.BeginOutputReadLine();
                    p.BeginErrorReadLine();
                    p.WaitForExit();
                    p.WaitForExit();
                }
                lock (sb) { return sb.ToString(); }
            }
            catch (Exception ex)
            {
                return "failed to run: " + ex.Message;
            }
        }

        private static List<ModuleRow> Parse(string raw)
        {
            List<ModuleRow> rows = new List<ModuleRow>();
            if (raw == null) { return rows; }
            string[] lines = raw.Split('\n');
            foreach (string rawLine in lines)
            {
                string line = rawLine.TrimEnd('\r');
                string[] parts = line.Split('\t');
                if (parts.Length >= 2 && parts[0].Length > 0 && parts[0].IndexOf(' ') < 0)
                {
                    ModuleRow r = new ModuleRow();
                    r.Name = parts[0];
                    r.State = parts[1];
                    r.Detail = parts.Length >= 3 ? parts[2] : "";
                    rows.Add(r);
                }
            }
            return rows;
        }

        // ---------------------------------------------------------------- status
        private void RefreshStatus()
        {
            if (busy || refreshing) { return; }
            refreshing = true;
            Task.Run(delegate
            {
                string raw = Exec("status");
                List<ModuleRow> rows = Parse(raw);
                try
                {
                    this.Invoke((Action)delegate
                    {
                        RenderModules(rows);
                        refreshing = false;
                    });
                }
                catch { refreshing = false; }
            });
        }

        // Modules are a fixed set, so update the existing controls in place instead of tearing the
        // table down on every poll (that teardown was the visible flicker). Rebuild only when the
        // set of module names actually changes.
        private void RenderModules(List<ModuleRow> rows)
        {
            lastStates.Clear();
            int liveCount = 0;
            for (int i = 0; i < rows.Count; i++)
            {
                bool run = (rows[i].State == "running");
                lastStates[rows[i].Name] = run;
                if (run) { liveCount++; }
            }
            if (trayIcon != null) { trayIcon.Text = "Dev Stack - " + liveCount + " of " + rows.Count + " running"; }

            bool sameSet = (rows.Count == rowMap.Count);
            if (sameSet)
            {
                for (int i = 0; i < rows.Count; i++)
                {
                    if (!rowMap.ContainsKey(rows[i].Name)) { sameSet = false; break; }
                }
            }
            if (!sameSet) { RebuildRows(rows); return; }

            int running = 0;
            for (int i = 0; i < rows.Count; i++)
            {
                ModuleRow r = rows[i];
                RowUi ui = rowMap[r.Name];

                string st = r.State.ToUpperInvariant();
                if (ui.State.Text != st) { ui.State.Text = st; }

                Color c = (r.State == "running") ? OkColor : MutedColor;
                if (ui.State.ForeColor != c) { ui.State.ForeColor = c; }

                bool isRunning = (r.State == "running");
                if (ui.Start.Enabled != !isRunning) { ui.Start.Enabled = !isRunning; }
                if (ui.Stop.Enabled != isRunning) { ui.Stop.Enabled = isRunning; }

                if (isRunning) { running++; }
            }

            string summary = running + " of " + rows.Count + " modules running";
            if (summaryLabel.Text != summary) { summaryLabel.Text = summary; }
        }

        private void RebuildRows(List<ModuleRow> rows)
        {
            moduleTable.SuspendLayout();
            moduleTable.Controls.Clear();
            moduleTable.RowStyles.Clear();
            rowMap.Clear();
            moduleTable.RowCount = rows.Count;
            int running = 0;

            for (int i = 0; i < rows.Count; i++)
            {
                ModuleRow r = rows[i];
                moduleTable.RowStyles.Add(new RowStyle(SizeType.AutoSize));
                RowUi ui = new RowUi();

                ui.Name = new Label();
                ui.Name.Text = r.Name;
                ui.Name.Font = new Font("Consolas", 10f, FontStyle.Bold);
                ui.Name.AutoSize = true;
                ui.Name.Anchor = AnchorStyles.Left;
                ui.Name.Margin = new Padding(4, 7, 4, 7);

                ui.Detail = new Label();
                ui.Detail.Text = r.Detail;
                ui.Detail.ForeColor = MutedColor;
                ui.Detail.Font = new Font("Segoe UI", 8f);
                ui.Detail.AutoSize = true;
                ui.Detail.Anchor = AnchorStyles.Left;
                ui.Detail.Margin = new Padding(4, 7, 4, 7);

                ui.State = new Label();
                ui.State.Text = r.State.ToUpperInvariant();
                ui.State.AutoSize = true;
                ui.State.Anchor = AnchorStyles.Left;
                ui.State.Font = new Font("Segoe UI", 8f, FontStyle.Bold);
                ui.State.ForeColor = (r.State == "running") ? OkColor : MutedColor;
                ui.State.Margin = new Padding(4, 7, 4, 7);

                FlowLayoutPanel actions = new FlowLayoutPanel();
                actions.AutoSize = true;
                actions.WrapContents = false;
                actions.Anchor = AnchorStyles.Right;
                actions.Margin = new Padding(0, 6, 0, 6);
                string id = r.Name;
                ui.Start = MakeButton("Start", delegate { RunAction("start " + id, "start", id); });
                ui.Stop = MakeButton("Stop", delegate { RunAction("stop " + id, "stop", id); });
                ui.Restart = MakeButton("Restart", delegate { RunAction("restart " + id, "restart", id); });
                ui.Start.Enabled = (r.State != "running");
                ui.Stop.Enabled = (r.State == "running");
                actions.Controls.Add(ui.Start);
                actions.Controls.Add(ui.Stop);
                actions.Controls.Add(ui.Restart);

                moduleTable.Controls.Add(ui.Name, 0, i);
                moduleTable.Controls.Add(ui.Detail, 1, i);
                moduleTable.Controls.Add(ui.State, 2, i);
                moduleTable.Controls.Add(actions, 3, i);

                rowMap[r.Name] = ui;
                if (r.State == "running") { running++; }
            }

            moduleTable.ResumeLayout();
            summaryLabel.Text = running + " of " + rows.Count + " modules running";
        }

        // ---------------------------------------------------------------- actions
        private void RunAction(string label, params string[] args)
        {
            if (busy) { return; }
            busy = true;
            actionLabel.Text = "Last action: " + label;
            summaryLabel.Text = "Working...";
            string[] captured = args;
            Task.Run(delegate
            {
                string output = Exec(captured);
                string status = Exec("status");
                List<ModuleRow> rows = Parse(status);
                try
                {
                    this.Invoke((Action)delegate
                    {
                        consoleBox.Text = output;
                        RenderModules(rows);
                        busy = false;
                    });
                }
                catch { busy = false; }
            });
        }

        private void CheckHelper()
        {
            Task.Run(delegate
            {
                bool present = false;
                try
                {
                    ProcessStartInfo psi = new ProcessStartInfo();
                    psi.FileName = "schtasks.exe";
                    psi.Arguments = "/query /tn DevStackHelper";
                    psi.UseShellExecute = false;
                    psi.CreateNoWindow = true;
                    psi.RedirectStandardOutput = true;
                    psi.RedirectStandardError = true;
                    using (Process p = Process.Start(psi))
                    {
                        p.StandardOutput.ReadToEnd();
                        p.StandardError.ReadToEnd();
                        p.WaitForExit();
                        present = (p.ExitCode == 0);
                    }
                }
                catch { present = false; }
                try
                {
                    this.Invoke((Action)delegate { if (helperBanner != null) { helperBanner.Visible = !present; } });
                }
                catch { }
            });
        }

        private void InstallHelper()
        {
            string helper = Path.Combine(pkgDir, "bin", "Install-HelperTask.ps1");
            if (!File.Exists(helper))
            {
                MessageBox.Show(this, "Installer not found at " + helper + ".\r\nRun windows\\install.ps1 first.", "Dev Stack",
                    MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo();
                psi.FileName = "powershell.exe";
                psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + helper + "\" -PackageRoot \"" + pkgDir + "\"";
                psi.Verb = "runas";
                psi.UseShellExecute = true;
                Process p = Process.Start(psi);
                if (p != null) { p.WaitForExit(); }
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, "Elevation cancelled or failed:\r\n" + ex.Message, "Dev Stack",
                    MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
            CheckHelper();
        }

        private void CheckForUpdates(bool force)
        {
            Task.Run(delegate
            {
                string json;
                if (force) { json = Exec("update", "--check", "--json", "--refresh"); }
                else { json = Exec("update", "--check", "--json"); }

                Match avail = Regex.Match(json, "\"available\"\\s*:\\s*(true|false)");
                if (!avail.Success || avail.Groups[1].Value != "true") { return; }
                Match cur = Regex.Match(json, "\"current\"\\s*:\\s*\"([^\"]*)\"");
                Match lat = Regex.Match(json, "\"latest\"\\s*:\\s*\"([^\"]*)\"");
                Match url = Regex.Match(json, "\"url\"\\s*:\\s*\"([^\"]*)\"");
                string current = cur.Success ? cur.Groups[1].Value : "";
                string latest = lat.Success ? lat.Groups[1].Value : "";
                updateUrl = url.Success ? url.Groups[1].Value : "";
                string text = "Update available - v" + current + " -> v" + latest + ". Only app code is replaced.";
                try
                {
                    this.Invoke((Action)delegate
                    {
                        updateLabel.Text = text;
                        updateBanner.Visible = true;
                    });
                }
                catch { }
            });
        }

        // ---------------------------------------------------------------- tray
        private void SetupTray()
        {
            trayIcon = new NotifyIcon();
            try { trayIcon.Icon = new Icon(Application.ExecutablePath, 16, 16); }
            catch { try { trayIcon.Icon = this.Icon; } catch { trayIcon.Icon = SystemIcons.Application; } }
            trayIcon.Text = "Dev Stack";
            trayIcon.Visible = true;
            trayIcon.DoubleClick += delegate { ShowFromTray(); };
            trayIcon.BalloonTipClicked += delegate { ShowFromTray(); };

            ContextMenuStrip menu = new ContextMenuStrip();
            menu.Items.Add(new ToolStripMenuItem("Open Dev Stack", null, delegate { ShowFromTray(); }));
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(new ToolStripMenuItem("Start All", null, delegate { RunAction("start all", "start"); }));
            menu.Items.Add(new ToolStripMenuItem("Stop All", null, delegate { RunAction("stop all", "stop"); }));
            menu.Items.Add(new ToolStripMenuItem("Restart All", null, delegate { RunAction("restart all", "restart"); }));
            menu.Items.Add(new ToolStripSeparator());

            ToolStripMenuItem modules = new ToolStripMenuItem("Modules");
            menu.Items.Add(modules);
            menu.Opening += delegate
            {
                modules.DropDownItems.Clear();
                if (lastStates.Count == 0)
                {
                    ToolStripMenuItem none = new ToolStripMenuItem("(no modules yet)");
                    none.Enabled = false;
                    modules.DropDownItems.Add(none);
                    return;
                }
                List<string> names = new List<string>(lastStates.Keys);
                foreach (string name in names)
                {
                    bool running = lastStates[name];
                    string id = name;
                    ToolStripMenuItem it = new ToolStripMenuItem((running ? "Stop " : "Start ") + id);
                    if (running) { it.Click += delegate { RunAction("stop " + id, "stop", id); }; }
                    else { it.Click += delegate { RunAction("start " + id, "start", id); }; }
                    modules.DropDownItems.Add(it);
                }
            };

            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(new ToolStripMenuItem("Quit Dev Stack", null, delegate { ExitApp(); }));
            trayIcon.ContextMenuStrip = menu;
        }

        private void HideToTray()
        {
            if (pollTimer != null) { pollTimer.Stop(); }
            Hide();
            if (trayIcon != null && !trayHintShown)
            {
                trayIcon.BalloonTipTitle = "Dev Stack is still running";
                trayIcon.BalloonTipText = "It lives in the notification area. Click the icon to reopen or quit.";
                trayIcon.BalloonTipIcon = ToolTipIcon.Info;
                trayIcon.ShowBalloonTip(3000);
                trayHintShown = true;
            }
        }

        private void ShowFromTray()
        {
            if (!Visible) { Show(); }
            if (WindowState == FormWindowState.Minimized) { WindowState = FormWindowState.Normal; }
            ShowInTaskbar = true;
            Activate();
            BringToFront();
            if (pollTimer != null) { pollTimer.Start(); }
            RefreshStatus();
        }

        private void ExitApp()
        {
            exiting = true;
            if (trayIcon != null) { trayIcon.Visible = false; trayIcon.Dispose(); trayIcon = null; }
            Close();
            Application.Exit();
        }

        private void ShowHelp()
        {
            string help = null;
            string[] candidates = new string[]
            {
                Path.Combine(appDir, "HELP.md"),
                Path.Combine(pkgDir, "docs", "HELP.md")
            };
            foreach (string c in candidates)
            {
                if (File.Exists(c)) { help = File.ReadAllText(c); break; }
            }
            if (help == null) { help = "# Help not found\n\nReinstall to restore docs\\HELP.md."; }

            Form win = new Form();
            win.Text = "Dev Stack - Help";
            win.Width = 880;
            win.Height = 760;
            win.MinimumSize = new Size(640, 480);
            win.StartPosition = FormStartPosition.CenterParent;
            win.BackColor = Color.White;
            try { win.Icon = this.Icon; } catch { }

            Panel header = new Panel();
            header.Dock = DockStyle.Top;
            header.Height = 52;
            header.Padding = new Padding(18, 10, 18, 10);
            header.BackColor = Color.White;

            Button close = new Button();
            close.Text = "Close";
            close.Dock = DockStyle.Right;
            close.Width = 90;
            close.Click += delegate { win.Close(); };

            Label title = new Label();
            title.Text = "Dev Stack - Help";
            title.Dock = DockStyle.Left;
            title.Width = 420;
            title.TextAlign = ContentAlignment.MiddleLeft;
            title.Font = new Font("Segoe UI", 12f, FontStyle.Bold);
            title.ForeColor = HeadingColor;

            header.Controls.Add(title);
            header.Controls.Add(close);

            RichTextBox rtb = new RichTextBox();
            rtb.Dock = DockStyle.Fill;
            rtb.ReadOnly = true;
            rtb.BorderStyle = BorderStyle.None;
            rtb.BackColor = Color.White;
            rtb.WordWrap = true;
            rtb.ScrollBars = RichTextBoxScrollBars.Vertical;
            rtb.DetectUrls = true;
            rtb.Font = new Font("Segoe UI", 9.5f);
            rtb.LinkClicked += delegate(object s, LinkClickedEventArgs e)
            {
                try { Process.Start(new ProcessStartInfo(e.LinkText) { UseShellExecute = true }); } catch { }
            };

            win.Controls.Add(rtb);
            win.Controls.Add(header);
            RenderHelp(rtb, help);
            win.ShowDialog(this);
        }

        // ---------------------------------------------------------------- help renderer
        private void AppendRun(RichTextBox rtb, string text, Font font, Color color, Color back)
        {
            rtb.SelectionStart = rtb.TextLength;
            rtb.SelectionLength = 0;
            rtb.SelectionFont = font;
            rtb.SelectionColor = color;
            rtb.SelectionBackColor = back;
            rtb.AppendText(text);
        }

        private void AppendHeading(RichTextBox rtb, string text, Font font)
        {
            if (rtb.TextLength > 0) { AppendRun(rtb, "\r\n", helpRegular, BodyColor, Color.White); }
            AppendRun(rtb, text.Replace("**", ""), font, HeadingColor, Color.White);
            AppendRun(rtb, "\r\n", helpRegular, BodyColor, Color.White);
        }

        private void AppendInline(RichTextBox rtb, string text, bool bold)
        {
            string[] parts = Regex.Split(text, "(\\*\\*[^*]+\\*\\*|`[^`]+`)");
            foreach (string p in parts)
            {
                if (p.Length == 0) { continue; }
                if (p.StartsWith("**") && p.EndsWith("**") && p.Length >= 4)
                {
                    AppendRun(rtb, p.Substring(2, p.Length - 4), helpBold, BodyColor, Color.White);
                }
                else if (p.StartsWith("`") && p.EndsWith("`") && p.Length >= 2)
                {
                    AppendRun(rtb, p.Substring(1, p.Length - 2), helpMono, CodeColor, CodeBack);
                }
                else
                {
                    AppendRun(rtb, p, bold ? helpBold : helpRegular, BodyColor, Color.White);
                }
            }
        }

        private void AppendCode(RichTextBox rtb, List<string> lines)
        {
            AppendRun(rtb, "\r\n", helpRegular, BodyColor, Color.White);
            foreach (string line in lines)
            {
                AppendRun(rtb, "  " + line + "\r\n", helpMono, CodeColor, CodeBack);
            }
        }

        private void AppendTable(RichTextBox rtb, List<string> rawRows)
        {
            List<string[]> rows = new List<string[]>();
            foreach (string r in rawRows)
            {
                string inner = r.Trim();
                if (inner.StartsWith("|")) { inner = inner.Substring(1); }
                if (inner.EndsWith("|")) { inner = inner.Substring(0, inner.Length - 1); }
                string[] cells = inner.Split('|');
                bool sep = true;
                for (int c = 0; c < cells.Length; c++)
                {
                    if (!Regex.IsMatch(cells[c].Trim(), "^:?-{1,}:?$")) { sep = false; break; }
                }
                if (sep) { continue; }
                for (int c = 0; c < cells.Length; c++) { cells[c] = cells[c].Trim(); }
                rows.Add(cells);
            }
            if (rows.Count == 0) { return; }

            int cols = 0;
            foreach (string[] r in rows) { if (r.Length > cols) { cols = r.Length; } }
            int[] widths = new int[cols];
            foreach (string[] r in rows)
            {
                for (int c = 0; c < cols; c++)
                {
                    string cell = c < r.Length ? r[c] : "";
                    if (cell.Length > widths[c]) { widths[c] = cell.Length; }
                }
            }

            AppendRun(rtb, "\r\n", helpRegular, BodyColor, Color.White);
            for (int ri = 0; ri < rows.Count; ri++)
            {
                string[] r = rows[ri];
                StringBuilder sb = new StringBuilder();
                for (int c = 0; c < cols; c++)
                {
                    string cell = c < r.Length ? r[c] : "";
                    if (c > 0) { sb.Append("  "); }
                    sb.Append(cell);
                    int pad = widths[c] - cell.Length;
                    if (pad > 0) { sb.Append(' ', pad); }
                }
                AppendRun(rtb, sb.ToString().TrimEnd() + "\r\n", ri == 0 ? helpMonoBold : helpMono, BodyColor, Color.White);
            }
        }

        private void RenderHelp(RichTextBox rtb, string md)
        {
            helpH1 = new Font("Segoe UI", 18f, FontStyle.Bold);
            helpH2 = new Font("Segoe UI", 13.5f, FontStyle.Bold);
            helpH3 = new Font("Segoe UI", 11f, FontStyle.Bold);
            helpRegular = new Font("Segoe UI", 9.5f);
            helpBold = new Font("Segoe UI", 9.5f, FontStyle.Bold);
            helpMono = new Font("Consolas", 9f);
            helpMonoBold = new Font("Consolas", 9f, FontStyle.Bold);

            rtb.Clear();
            md = md.Replace("\r\n", "\n").Replace('\r', '\n');
            string[] lines = md.Split('\n');
            int i = 0;
            bool inCode = false;
            List<string> code = new List<string>();

            while (i < lines.Length)
            {
                string raw = lines[i];
                string t = raw.Trim();

                if (t.StartsWith("```"))
                {
                    if (!inCode) { inCode = true; code.Clear(); }
                    else { AppendCode(rtb, code); inCode = false; }
                    i++;
                    continue;
                }
                if (inCode) { code.Add(raw); i++; continue; }

                if (t.StartsWith("|"))
                {
                    List<string> rows = new List<string>();
                    while (i < lines.Length && lines[i].Trim().StartsWith("|")) { rows.Add(lines[i].Trim()); i++; }
                    AppendTable(rtb, rows);
                    continue;
                }

                if (t.Length == 0) { AppendRun(rtb, "\r\n", helpRegular, BodyColor, Color.White); i++; continue; }

                if (t.StartsWith("### ")) { AppendHeading(rtb, t.Substring(4), helpH3); i++; continue; }
                if (t.StartsWith("## ")) { AppendHeading(rtb, t.Substring(3), helpH2); i++; continue; }
                if (t.StartsWith("# ")) { AppendHeading(rtb, t.Substring(2), helpH1); i++; continue; }

                if (t.StartsWith("- ") || t.StartsWith("* "))
                {
                    AppendRun(rtb, "  \u2022  ", helpRegular, AccentColor, Color.White);
                    AppendInline(rtb, t.Substring(2), false);
                    AppendRun(rtb, "\r\n", helpRegular, BodyColor, Color.White);
                    i++;
                    continue;
                }
                Match num = Regex.Match(t, @"^\d+\.\s+(.*)$");
                if (num.Success)
                {
                    AppendRun(rtb, "  \u2022  ", helpRegular, AccentColor, Color.White);
                    AppendInline(rtb, num.Groups[1].Value, false);
                    AppendRun(rtb, "\r\n", helpRegular, BodyColor, Color.White);
                    i++;
                    continue;
                }

                AppendInline(rtb, t, false);
                AppendRun(rtb, "\r\n", helpRegular, BodyColor, Color.White);
                i++;
            }
            if (inCode) { AppendCode(rtb, code); }

            rtb.SelectionStart = 0;
            rtb.SelectionLength = 0;
            rtb.ScrollToCaret();
        }

        private void OpenUrl(string url)
        {
            try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); }
            catch { }
        }

        private void OpenFolder(string path)
        {
            try
            {
                if (!Directory.Exists(path)) { Directory.CreateDirectory(path); }
                Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
            }
            catch { }
        }
    }
}
