@echo off
rem ====================================================================
rem  Audio Switcher - single-file launcher
rem  Double-click to start. The first run compiles the app (a few
rem  seconds) using the C# compiler that ships with Windows; after that
rem  it just launches. No .NET SDK needed.
rem
rem  Usage:  AudioSwitcher.bat             start (build first if needed)
rem          AudioSwitcher.bat /uninstall  remove app, settings, shortcut, autostart
rem ====================================================================
setlocal
set "SELF=%~f0"
set "APPDIR=%APPDATA%\AudioSwitcher"
set "EXE=%APPDIR%\AudioSwitcher.exe"
set "SRC=%APPDIR%\AudioSwitcher.cs"
set "ICO=%APPDIR%\AudioSwitcher.ico"
set "TMPEXE=%APPDIR%\AudioSwitcher.build.exe"
set "LNK=%APPDATA%\Microsoft\Windows\Start Menu\Programs\Audio Switcher.lnk"

if /i "%~1"=="/uninstall" goto uninstall
if not exist "%APPDIR%" mkdir "%APPDIR%"
if not exist "%EXE%" goto build

rem Rebuild if this .bat is newer than the compiled exe (e.g. after you edited it)
powershell -NoProfile -ExecutionPolicy Bypass -Command "if ((Get-Item -LiteralPath $env:SELF).LastWriteTime -gt (Get-Item -LiteralPath $env:EXE).LastWriteTime) { exit 1 }"
if errorlevel 1 goto build
goto launch

:build
echo Compiling Audio Switcher - one-time step, takes a few seconds...
taskkill /f /im AudioSwitcher.exe >nul 2>&1
set "CSC=%windir%\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if not exist "%CSC%" set "CSC=%windir%\Microsoft.NET\Framework\v4.0.30319\csc.exe"
if not exist "%CSC%" goto nocsc
powershell -NoProfile -ExecutionPolicy Bypass -Command "$l=[IO.File]::ReadAllLines($env:SELF); $i=[Array]::IndexOf($l,'::CSHARP_BEGIN'); [IO.File]::WriteAllLines($env:SRC,[string[]]$l[($i+1)..($l.Length-1)])"
rem Step 1: build a small helper exe that draws the app icon (same code as the tray icon)
"%CSC%" /nologo /target:exe /out:"%TMPEXE%" /reference:System.Windows.Forms.dll /reference:System.Drawing.dll "%SRC%"
if errorlevel 1 goto buildfail
del "%ICO%" >nul 2>&1
"%TMPEXE%" /makeicon "%ICO%"
del "%TMPEXE%" >nul 2>&1
set "ICOARG="
if exist "%ICO%" set ICOARG=/win32icon:"%ICO%"
rem Step 2: build the real app with that icon embedded
"%CSC%" /nologo /target:winexe /optimize+ %ICOARG% /out:"%EXE%" /reference:System.Windows.Forms.dll /reference:System.Drawing.dll "%SRC%"
if not errorlevel 1 goto built
if not defined ICOARG goto buildfail
echo Retrying without the custom icon...
"%CSC%" /nologo /target:winexe /optimize+ /out:"%EXE%" /reference:System.Windows.Forms.dll /reference:System.Drawing.dll "%SRC%"
if errorlevel 1 goto buildfail

:built
del "%SRC%" >nul 2>&1
rem Start Menu shortcut, so "Audio Switcher" shows up when you press the Windows key and type its name
powershell -NoProfile -ExecutionPolicy Bypass -Command "$s=(New-Object -ComObject WScript.Shell).CreateShortcut($env:LNK); $s.TargetPath=$env:EXE; $s.WorkingDirectory=$env:APPDIR; $s.Description='Switch the audio output device with a hotkey'; $s.IconLocation=$env:EXE+',0'; $s.Save()" >nul 2>&1

:launch
start "" "%EXE%"
exit /b 0

:nocsc
echo.
echo Could not find csc.exe in %windir%\Microsoft.NET\Framework64\v4.0.30319
echo This file is part of the .NET Framework 4.x that ships with Windows 10 and 11.
pause
exit /b 1

:buildfail
echo.
echo Build failed - see the compiler messages above.
pause
exit /b 1

:uninstall
taskkill /f /im AudioSwitcher.exe >nul 2>&1
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v AudioSwitcher /f >nul 2>&1
del "%LNK%" >nul 2>&1
rmdir /s /q "%APPDIR%" >nul 2>&1
echo Audio Switcher removed: app, settings, Start Menu shortcut and autostart entry deleted.
echo You can delete this .bat file as well.
pause
exit /b 0

::CSHARP_BEGIN
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

namespace AudioSwitcher
{
    // ---------------------------- Entry point ----------------------------

    static class Program
    {
        [DllImport("user32.dll")]
        static extern bool SetProcessDPIAware();

        [STAThread]
        static int Main(string[] args)
        {
            // Build step: "AudioSwitcher.exe /makeicon file.ico" writes the app icon and exits.
            if (args.Length >= 2 && string.Equals(args[0], "/makeicon", StringComparison.OrdinalIgnoreCase))
            {
                try { AppIcon.WriteIco(args[1]); return 0; }
                catch { return 1; }
            }

            bool isNew;
            using (var mutex = new Mutex(true, "AudioSwitcher_SingleInstance", out isNew))
            {
                if (!isNew) return 0;

                try { SetProcessDPIAware(); } catch { }
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Application.Run(new TrayApp());
            }
            return 0;
        }
    }

    // ---------------------------- Config ----------------------------

    class Config
    {
        // Win32 modifier flags: Alt=1, Ctrl=2, Shift=4, Win=8
        public int Modifiers = 3;                 // Ctrl + Alt
        public int Key = (int)Keys.S;
        public bool ShowNotifications = true;
        public bool SwitchMic = true;             // switch the paired microphone together with the output
        public List<SavedDevice> Devices = new List<SavedDevice>();

        public bool HasId(string id)
        {
            return Devices.Any(d => d.Id == id);
        }

        public SavedDevice Find(string id)
        {
            return Devices.FirstOrDefault(d => d.Id == id);
        }

        // Matches the saved devices against the devices that are currently active.
        //  - Same ID: keep it (and refresh the stored name/fingerprint).
        //  - ID not found, but exactly one active, not-yet-selected device has the same
        //    fingerprint: Windows re-created the endpoint (driver update, other USB port,
        //    re-pairing ...) -> adopt the new ID.
        //  - Anything that matches nothing is KEPT, so unplugged devices stay selected.
        public void SyncWithActive(List<AudioDevice> active)
        {
            bool changed = false;

            foreach (var saved in Devices)
            {
                var d = active.FirstOrDefault(a => a.Id == saved.Id);
                if (d != null && (saved.Key != d.Key || saved.Name != d.Name))
                {
                    saved.Key = d.Key;
                    saved.Name = d.Name;
                    changed = true;
                }
            }

            foreach (var saved in Devices)
            {
                if (saved.Key.Length == 0 || active.Any(a => a.Id == saved.Id)) continue;

                var candidates = active.Where(a => a.Key == saved.Key && !HasId(a.Id)).ToList();
                if (candidates.Count == 1)
                {
                    saved.Id = candidates[0].Id;
                    saved.Name = candidates[0].Name;
                    changed = true;
                }
            }

            var seen = new HashSet<string>();
            if (Devices.RemoveAll(x => !seen.Add(x.Id)) > 0) changed = true;

            if (changed) Save();
        }

        static readonly string ConfigPath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "AudioSwitcher", "config.txt");

        public static Config Load(out bool firstRun)
        {
            var cfg = new Config();
            firstRun = !File.Exists(ConfigPath);
            if (firstRun) return cfg;

            try
            {
                foreach (var line in File.ReadAllLines(ConfigPath))
                {
                    int eq = line.IndexOf('=');
                    if (eq <= 0) continue;
                    string k = line.Substring(0, eq).Trim();
                    string v = line.Substring(eq + 1).Trim();
                    int n;

                    if (k == "Modifiers" && int.TryParse(v, out n)) cfg.Modifiers = n;
                    else if (k == "Key" && int.TryParse(v, out n)) cfg.Key = n;
                    else if (k == "ShowNotifications") cfg.ShowNotifications = (v != "0");
                    else if (k == "SwitchMic") cfg.SwitchMic = (v != "0");
                    else if (k == "Device" && v.Length > 0)
                    {
                        // format: id <TAB> fingerprint <TAB> name <TAB> nomic(0/1)   (older files: fewer fields)
                        string[] parts = v.Split('\t');
                        string id = parts[0].Trim();
                        if (id.Length > 0 && !cfg.HasId(id))
                        {
                            var sd = new SavedDevice(id,
                                parts.Length > 1 ? parts[1] : "",
                                parts.Length > 2 ? parts[2] : "");
                            sd.NoMic = parts.Length > 3 && parts[3].Trim() == "1";
                            cfg.Devices.Add(sd);
                        }
                    }
                }
            }
            catch { /* unreadable file -> defaults */ }
            return cfg;
        }

        public void Save()
        {
            try
            {
                Directory.CreateDirectory(Path.GetDirectoryName(ConfigPath));
                var lines = new List<string>();
                lines.Add("Modifiers=" + Modifiers);
                lines.Add("Key=" + Key);
                lines.Add("ShowNotifications=" + (ShowNotifications ? "1" : "0"));
                lines.Add("SwitchMic=" + (SwitchMic ? "1" : "0"));
                foreach (var d in Devices)
                    lines.Add("Device=" + d.Id + "\t" + d.Key + "\t" + d.Name + "\t" + (d.NoMic ? "1" : "0"));
                File.WriteAllLines(ConfigPath, lines.ToArray());
            }
            catch { /* ignore */ }
        }
    }

    class SavedDevice
    {
        public string Id;      // Windows endpoint ID (can change after driver updates etc.)
        public string Key;     // fingerprint built from the device's names (survives ID changes)
        public string Name;    // display name
        public bool NoMic;     // true = do not switch the microphone together with this output

        public SavedDevice(string id, string key, string name)
        {
            Id = id; Key = key ?? ""; Name = name ?? "";
        }
    }

    // ---------------------------- Tray app ----------------------------

    class TrayApp : ApplicationContext
    {
        const int HOTKEY_ID = 1;
        const int MOD_NOREPEAT = 0x4000;
        const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
        const string RunValueName = "AudioSwitcher";

        [DllImport("user32.dll")]
        static extern bool RegisterHotKey(IntPtr hWnd, int id, uint mods, uint vk);
        [DllImport("user32.dll")]
        static extern bool UnregisterHotKey(IntPtr hWnd, int id);

        readonly Config _cfg;
        readonly NotifyIcon _tray;
        readonly ContextMenuStrip _menu;
        readonly HotkeyWindow _win;
        readonly OsdForm _osd;

        public TrayApp()
        {
            bool firstRun;
            _cfg = Config.Load(out firstRun);

            _osd = new OsdForm();

            _win = new HotkeyWindow();
            _win.Pressed += SwitchNext;

            _menu = new ContextMenuStrip();
            _menu.Opening += (s, e) => BuildMenu();

            _tray = new NotifyIcon();
            _tray.Icon = AppIcon.Create(SystemInformation.SmallIconSize.Width);
            _tray.ContextMenuStrip = _menu;
            _tray.Visible = true;
            _tray.MouseClick += (s, e) => { if (e.Button == MouseButtons.Left) SwitchNext(); };
            UpdateTooltip();

            if (!RegisterHotkey())
                Notify("Hotkey unavailable",
                       HotkeyText(_cfg.Modifiers, _cfg.Key) + " is already used by another program. " +
                       "Right-click the tray icon to choose a different one.", true);
            else if (firstRun)
                Notify("Audio Switcher is running",
                       "Right-click the tray icon and tick the devices you want to cycle through.", true);
        }

        // ---- Switching ----

        void SwitchNext()
        {
            try
            {
                var active = Audio.GetActiveRenderDevices();
                _cfg.SyncWithActive(active);
                var chosen = active.Where(d => _cfg.HasId(d.Id)).ToList();

                if (chosen.Count == 0)
                {
                    Notify("No devices selected",
                           "Right-click the tray icon and tick the devices to cycle through.", true);
                    return;
                }

                string current = Audio.GetDefaultRenderId();
                int idx = chosen.FindIndex(d => d.Id == current);
                AudioDevice next = chosen[(idx + 1) % chosen.Count];   // idx == -1 -> first device

                Audio.SetDefaultDevice(next.Id);

                // Also switch the microphone that belongs to the same physical device (e.g. a headset's mic)
                string micLine = "";
                if (_cfg.SwitchMic)
                {
                    SavedDevice saved = _cfg.Find(next.Id);
                    if (saved == null || !saved.NoMic)
                    {
                        try
                        {
                            AudioDevice mic = Audio.FindMicFor(next, Audio.GetActiveCaptureDevices());
                            if (mic != null)
                            {
                                Audio.SetDefaultDevice(mic.Id);
                                micLine = "Mic: " + mic.Name;
                            }
                        }
                        catch { micLine = "Mic: could not be switched"; }
                    }
                }

                Notify("Audio output", next.Name, micLine, false);
            }
            catch (Exception ex)
            {
                Notify("Could not switch device", ex.Message, true);
            }
        }

        // ---- Hotkey ----

        bool RegisterHotkey()
        {
            UnregisterHotKey(_win.Handle, HOTKEY_ID);
            return RegisterHotKey(_win.Handle, HOTKEY_ID, (uint)(_cfg.Modifiers | MOD_NOREPEAT), (uint)_cfg.Key);
        }

        void ChangeHotkey()
        {
            using (var dlg = new HotkeyDialog(_cfg.Modifiers, _cfg.Key))
            {
                if (dlg.ShowDialog() != DialogResult.OK) return;

                int oldMods = _cfg.Modifiers, oldKey = _cfg.Key;
                _cfg.Modifiers = dlg.Modifiers;
                _cfg.Key = dlg.KeyCode;

                if (RegisterHotkey())
                {
                    _cfg.Save();
                    UpdateTooltip();
                }
                else
                {
                    _cfg.Modifiers = oldMods;
                    _cfg.Key = oldKey;
                    RegisterHotkey();
                    MessageBox.Show("That hotkey is already in use by another program. Please pick another one.",
                                    "Audio Switcher", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                }
            }
        }

        void UpdateTooltip()
        {
            _tray.Text = "Audio Switcher (" + HotkeyText(_cfg.Modifiers, _cfg.Key) + ")";
        }

        public static string HotkeyText(int mods, int key)
        {
            var parts = new List<string>();
            if ((mods & 2) != 0) parts.Add("Ctrl");
            if ((mods & 1) != 0) parts.Add("Alt");
            if ((mods & 4) != 0) parts.Add("Shift");
            if ((mods & 8) != 0) parts.Add("Win");
            parts.Add(((Keys)key).ToString());
            return string.Join(" + ", parts.ToArray());
        }

        // ---- Menu ----

        void BuildMenu()
        {
            _menu.Items.Clear();

            var header = new ToolStripMenuItem("Cycle through these devices:");
            header.Enabled = false;
            _menu.Items.Add(header);

            try
            {
                string current = Audio.GetDefaultRenderId();
                var active = Audio.GetActiveRenderDevices();
                _cfg.SyncWithActive(active);

                foreach (var dev in active)
                {
                    var d = dev;
                    var item = new ToolStripMenuItem(d.Name.Replace("&", "&&"));
                    item.Checked = _cfg.HasId(d.Id);
                    if (d.Id == current) item.Font = new Font(_menu.Font, FontStyle.Bold);
                    item.Click += (s, e) =>
                    {
                        if (_cfg.HasId(d.Id)) _cfg.Devices.RemoveAll(x => x.Id == d.Id);
                        else _cfg.Devices.Add(new SavedDevice(d.Id, d.Key, d.Name));
                        _cfg.Save();
                    };
                    _menu.Items.Add(item);
                }

                // Remembered devices that are currently unplugged / not found
                foreach (var saved in _cfg.Devices.ToList())
                {
                    if (active.Any(a => a.Id == saved.Id)) continue;
                    var sv = saved;
                    string label = (sv.Name.Length > 0 ? sv.Name : "Unknown device") + " (not connected)";
                    var item = new ToolStripMenuItem(label.Replace("&", "&&"));
                    item.Checked = true;
                    item.ToolTipText = "Still remembered. Click to forget this device.";
                    item.Click += (s, e) => { _cfg.Devices.Remove(sv); _cfg.Save(); };
                    _menu.Items.Add(item);
                }

                // Which microphone follows which ticked output (only outputs that have a paired mic are listed)
                if (_cfg.SwitchMic)
                {
                    var mics = Audio.GetActiveCaptureDevices();
                    var pairItems = new List<ToolStripMenuItem>();
                    foreach (var dev in active)
                    {
                        SavedDevice sd = _cfg.Find(dev.Id);
                        if (sd == null) continue;
                        AudioDevice mic = Audio.FindMicFor(dev, mics);
                        if (mic == null) continue;

                        var pairSaved = sd;
                        var pair = new ToolStripMenuItem((dev.Name + "  ->  " + mic.Name).Replace("&", "&&"));
                        pair.Checked = !pairSaved.NoMic;
                        pair.Click += (s, e) => { pairSaved.NoMic = !pairSaved.NoMic; _cfg.Save(); };
                        pairItems.Add(pair);
                    }

                    if (pairItems.Count > 0)
                    {
                        _menu.Items.Add(new ToolStripSeparator());
                        var pairHeader = new ToolStripMenuItem("Microphone follows output:");
                        pairHeader.Enabled = false;
                        _menu.Items.Add(pairHeader);
                        foreach (var pi in pairItems) _menu.Items.Add(pi);
                    }
                }
            }
            catch (Exception ex)
            {
                var err = new ToolStripMenuItem("Error listing devices: " + ex.Message);
                err.Enabled = false;
                _menu.Items.Add(err);
            }

            _menu.Items.Add(new ToolStripSeparator());

            var now = new ToolStripMenuItem("Switch now  (" + HotkeyText(_cfg.Modifiers, _cfg.Key) + ")");
            now.Click += (s, e) => SwitchNext();
            _menu.Items.Add(now);

            var hk = new ToolStripMenuItem("Change hotkey...");
            hk.Click += (s, e) => ChangeHotkey();
            _menu.Items.Add(hk);

            var notif = new ToolStripMenuItem("Show popup when switching");
            notif.Checked = _cfg.ShowNotifications;
            notif.Click += (s, e) => { _cfg.ShowNotifications = !_cfg.ShowNotifications; _cfg.Save(); };
            _menu.Items.Add(notif);

            var micToggle = new ToolStripMenuItem("Also switch microphone");
            micToggle.Checked = _cfg.SwitchMic;
            micToggle.Click += (s, e) => { _cfg.SwitchMic = !_cfg.SwitchMic; _cfg.Save(); };
            _menu.Items.Add(micToggle);

            var auto = new ToolStripMenuItem("Start with Windows");
            auto.Checked = GetAutostart();
            auto.Click += (s, e) => SetAutostart(!GetAutostart());
            _menu.Items.Add(auto);

            _menu.Items.Add(new ToolStripSeparator());

            var exit = new ToolStripMenuItem("Exit");
            exit.Click += (s, e) => ExitApp();
            _menu.Items.Add(exit);
        }

        void ExitApp()
        {
            UnregisterHotKey(_win.Handle, HOTKEY_ID);
            _tray.Visible = false;
            _tray.Dispose();
            _win.Dispose();
            _osd.Dispose();
            ExitThread();
        }

        // ---- Helpers ----

        // Shows a small popup on screen (does not depend on Windows notification settings).
        void Notify(string title, string text, bool force)
        {
            Notify(title, text, "", force);
        }

        void Notify(string title, string text, string sub, bool force)
        {
            if (force || _cfg.ShowNotifications)
                _osd.ShowMessage(title, text, sub, force ? 4000 : 1500);
        }

        static bool GetAutostart()
        {
            using (var k = Registry.CurrentUser.OpenSubKey(RunKey))
            {
                return k != null && k.GetValue(RunValueName) != null;
            }
        }

        static void SetAutostart(bool on)
        {
            using (var k = Registry.CurrentUser.OpenSubKey(RunKey, true))
            {
                if (k == null) return;
                if (on) k.SetValue(RunValueName, "\"" + Application.ExecutablePath + "\"");
                else k.DeleteValue(RunValueName, false);
            }
        }
    }

    // ---------------------------- App icon (single source for tray, exe and shortcut) ----------------------------

    static class AppIcon
    {
        // Draws the icon in a 32x32 coordinate system, scaled to any size.
        public static Bitmap Draw(int size)
        {
            var bmp = new Bitmap(size, size, PixelFormat.Format32bppArgb);
            using (var g = Graphics.FromImage(bmp))
            {
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.Clear(Color.Transparent);
                float k = size / 32f;
                g.ScaleTransform(k, k);

                using (var bg = new SolidBrush(Color.FromArgb(0, 120, 215)))
                    g.FillEllipse(bg, 0.5f, 0.5f, 31f, 31f);

                using (var white = new SolidBrush(Color.White))
                    g.FillPolygon(white, new Point[]
                    {
                        new Point(7, 13), new Point(11, 13), new Point(17, 8),
                        new Point(17, 24), new Point(11, 19), new Point(7, 19)
                    });

                using (var pen = new Pen(Color.White, 2f))
                {
                    g.DrawArc(pen, 14, 11, 8, 10, -60, 120);
                    g.DrawArc(pen, 15, 7, 12, 18, -60, 120);
                }
            }
            return bmp;
        }

        public static Icon Create(int size)
        {
            using (var bmp = Draw(size))
            {
                return Icon.FromHandle(bmp.GetHicon());
            }
        }

        // Writes a multi-size .ico (PNG-compressed frames) used for the exe and the Start Menu shortcut.
        public static void WriteIco(string path)
        {
            int[] sizes = new int[] { 16, 24, 32, 48, 64, 256 };
            var images = new List<byte[]>();
            foreach (int size in sizes)
            {
                using (var bmp = Draw(size))
                using (var ms = new MemoryStream())
                {
                    bmp.Save(ms, ImageFormat.Png);
                    images.Add(ms.ToArray());
                }
            }

            using (var fs = new FileStream(path, FileMode.Create))
            using (var w = new BinaryWriter(fs))
            {
                w.Write((short)0);                    // reserved
                w.Write((short)1);                    // type: icon
                w.Write((short)images.Count);

                int offset = 6 + 16 * images.Count;
                for (int i = 0; i < images.Count; i++)
                {
                    byte dim = (byte)(sizes[i] >= 256 ? 0 : sizes[i]);
                    w.Write(dim);                     // width
                    w.Write(dim);                     // height
                    w.Write((byte)0);                 // palette
                    w.Write((byte)0);                 // reserved
                    w.Write((short)1);                // planes
                    w.Write((short)32);               // bits per pixel
                    w.Write(images[i].Length);        // data size
                    w.Write(offset);                  // data offset
                    offset += images[i].Length;
                }
                foreach (byte[] img in images) w.Write(img);
            }
        }
    }

    // ---------------------------- On-screen popup ----------------------------

    class OsdForm : Form
    {
        const int WS_EX_TOPMOST = 0x8;
        const int WS_EX_TRANSPARENT = 0x20;      // clicks pass through the popup
        const int WS_EX_TOOLWINDOW = 0x80;       // no taskbar / Alt+Tab entry
        const int WS_EX_NOACTIVATE = 0x08000000; // never steals focus

        readonly Label _title = new Label();
        readonly Label _text = new Label();
        readonly Label _sub = new Label();
        readonly System.Windows.Forms.Timer _timer = new System.Windows.Forms.Timer();

        public OsdForm()
        {
            FormBorderStyle = FormBorderStyle.None;
            StartPosition = FormStartPosition.Manual;
            ShowInTaskbar = false;
            TopMost = true;
            BackColor = Color.FromArgb(32, 32, 32);
            Opacity = 0.95;

            _title.AutoSize = false;
            _title.UseMnemonic = false;
            _title.ForeColor = Color.FromArgb(160, 160, 160);
            _title.Font = new Font("Segoe UI", 9f);

            _text.AutoSize = false;
            _text.UseMnemonic = false;
            _text.ForeColor = Color.White;
            _text.Font = new Font("Segoe UI Semibold", 13f);

            _sub.AutoSize = false;
            _sub.UseMnemonic = false;
            _sub.ForeColor = Color.FromArgb(190, 190, 190);
            _sub.Font = new Font("Segoe UI", 10f);

            Controls.Add(_title);
            Controls.Add(_text);
            Controls.Add(_sub);

            _timer.Tick += (s, e) => { _timer.Stop(); Hide(); };
        }

        protected override bool ShowWithoutActivation
        {
            get { return true; }
        }

        protected override CreateParams CreateParams
        {
            get
            {
                CreateParams cp = base.CreateParams;
                cp.ExStyle |= WS_EX_TOPMOST | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE;
                return cp;
            }
        }

        public void ShowMessage(string title, string text, string sub, int milliseconds)
        {
            _timer.Stop();
            _title.Text = title;
            _text.Text = text;
            _sub.Text = sub ?? "";
            bool hasSub = _sub.Text.Length > 0;
            _sub.Visible = hasSub;

            const int pad = 18;
            Size ts = _title.GetPreferredSize(new Size(460, 0));
            Size xs = _text.GetPreferredSize(new Size(460, 0));
            Size ss = hasSub ? _sub.GetPreferredSize(new Size(460, 0)) : Size.Empty;
            int w = Math.Max(Math.Max(ts.Width, xs.Width), ss.Width) + 2 * pad;
            int h = ts.Height + xs.Height + (hasSub ? ss.Height + 4 : 0) + 2 * pad + 4;

            _title.SetBounds(pad, pad, w - 2 * pad, ts.Height);
            _text.SetBounds(pad, pad + ts.Height + 4, w - 2 * pad, xs.Height);
            if (hasSub) _sub.SetBounds(pad, pad + ts.Height + 4 + xs.Height + 4, w - 2 * pad, ss.Height);
            Size = new Size(w, h);

            using (GraphicsPath path = RoundedRect(new Rectangle(0, 0, w, h), 14))
            {
                Region old = Region;
                Region = new Region(path);
                if (old != null) old.Dispose();
            }

            // bottom centre of the screen the mouse is on
            Rectangle wa = Screen.FromPoint(Cursor.Position).WorkingArea;
            Location = new Point(wa.Left + (wa.Width - w) / 2, wa.Bottom - h - 70);

            if (!Visible) Show();
            _timer.Interval = Math.Max(500, milliseconds);
            _timer.Start();
        }

        static GraphicsPath RoundedRect(Rectangle r, int radius)
        {
            int d = radius * 2;
            var p = new GraphicsPath();
            p.AddArc(r.X, r.Y, d, d, 180, 90);
            p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure();
            return p;
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing) _timer.Dispose();
            base.Dispose(disposing);
        }
    }

    // ---------------------------- Hidden window for WM_HOTKEY ----------------------------

    class HotkeyWindow : NativeWindow, IDisposable
    {
        const int WM_HOTKEY = 0x0312;
        public event Action Pressed;

        public HotkeyWindow()
        {
            CreateHandle(new CreateParams());
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == WM_HOTKEY)
            {
                Action handler = Pressed;
                if (handler != null) handler();
            }
            base.WndProc(ref m);
        }

        public void Dispose()
        {
            DestroyHandle();
        }
    }

    // ---------------------------- Hotkey picker dialog ----------------------------

    class HotkeyDialog : Form
    {
        public int Modifiers { get; private set; }
        public int KeyCode { get; private set; }

        public HotkeyDialog(int mods, int key)
        {
            Modifiers = mods;
            KeyCode = key;

            Text = "Set hotkey";
            FormBorderStyle = FormBorderStyle.FixedDialog;
            StartPosition = FormStartPosition.CenterScreen;
            MaximizeBox = false;
            MinimizeBox = false;
            ShowInTaskbar = false;
            TopMost = true;
            Icon = AppIcon.Create(32);
            ClientSize = new Size(330, 115);

            var label = new Label();
            label.Text = "Click the box, then press the key combination you want.";
            label.Left = 12; label.Top = 12; label.Width = 306; label.Height = 20;

            var box = new TextBox();
            box.ReadOnly = true;
            box.Left = 12; box.Top = 38; box.Width = 306;
            box.Text = TrayApp.HotkeyText(mods, key);

            var ok = new Button();
            ok.Text = "OK"; ok.DialogResult = DialogResult.OK;
            ok.Left = 162; ok.Top = 76; ok.Width = 75;

            var cancel = new Button();
            cancel.Text = "Cancel"; cancel.DialogResult = DialogResult.Cancel;
            cancel.Left = 243; cancel.Top = 76; cancel.Width = 75;

            box.KeyDown += (s, e) =>
            {
                e.SuppressKeyPress = true;
                e.Handled = true;

                Keys k = e.KeyCode;
                if (k == Keys.ControlKey || k == Keys.ShiftKey || k == Keys.Menu ||
                    k == Keys.LWin || k == Keys.RWin) return;

                int m = (e.Alt ? 1 : 0) | (e.Control ? 2 : 0) | (e.Shift ? 4 : 0);
                bool isFunctionKey = k >= Keys.F1 && k <= Keys.F24;
                if (m == 0 && !isFunctionKey) return;   // require a modifier for normal keys

                Modifiers = m;
                KeyCode = (int)k;
                box.Text = TrayApp.HotkeyText(m, (int)k);
            };

            Controls.AddRange(new Control[] { label, box, ok, cancel });
            CancelButton = cancel;
        }
    }

    // ---------------------------- Audio (Core Audio COM interop) ----------------------------

    class AudioDevice
    {
        public readonly string Id;
        public readonly string Name;
        public readonly string Key;     // fingerprint: description // interface name (USB port prefix removed)
        public readonly string Container;  // physical-device ID shared by a headset's speakers and microphone ("" = none/generic)
        public AudioDevice(string id, string name, string key, string container)
        {
            Id = id; Name = name; Key = key; Container = container ?? "";
        }
    }

    static class Audio
    {
        const int eRender = 0, eCapture = 1;
        const int eConsole = 0, eMultimedia = 1, eCommunications = 2;
        const uint DEVICE_STATE_ACTIVE = 0x1;
        const ushort VT_LPWSTR = 31;
        const ushort VT_CLSID = 72;

        // Property sets: PKEY_Device_FriendlyName (14) / DeviceDesc (2) share this GUID
        static readonly Guid DevicePropsFmt = new Guid("a45c254e-df1c-4efd-8020-67d146a850e0");
        // PKEY_DeviceInterface_FriendlyName (2), e.g. "Jabra EVOLVE 30 II"
        static readonly Guid InterfacePropsFmt = new Guid("026e516e-b814-414b-83cd-856d6fef4822");

        [DllImport("ole32.dll")]
        static extern int PropVariantClear(ref PropVariant pv);

        public static List<AudioDevice> GetActiveRenderDevices()
        {
            return GetActiveDevices(eRender);
        }

        public static List<AudioDevice> GetActiveCaptureDevices()
        {
            return GetActiveDevices(eCapture);
        }

        static List<AudioDevice> GetActiveDevices(int dataFlow)
        {
            var result = new List<AudioDevice>();
            var enumerator = (IMMDeviceEnumerator)new MMDeviceEnumeratorComObject();

            IMMDeviceCollection collection;
            enumerator.EnumAudioEndpoints(dataFlow, DEVICE_STATE_ACTIVE, out collection);

            uint count;
            collection.GetCount(out count);

            for (uint i = 0; i < count; i++)
            {
                IMMDevice dev;
                collection.Item(i, out dev);
                string id;
                dev.GetId(out id);
                result.Add(ReadDevice(dev, id));
            }
            return result;
        }

        public static string GetDefaultRenderId()
        {
            try
            {
                var enumerator = (IMMDeviceEnumerator)new MMDeviceEnumeratorComObject();
                IMMDevice dev;
                enumerator.GetDefaultAudioEndpoint(eRender, eConsole, out dev);
                string id;
                dev.GetId(out id);
                return id;
            }
            catch { return null; }
        }

        // Works for playback and recording endpoints alike.
        public static void SetDefaultDevice(string deviceId)
        {
            var policy = (IPolicyConfig)new PolicyConfigClient();
            int[] roles = new int[] { eConsole, eMultimedia, eCommunications };
            foreach (int role in roles)
                Marshal.ThrowExceptionForHR(policy.SetDefaultEndpoint(deviceId, role));
        }

        // PKEY_Device_ContainerId: identifies the physical device an endpoint belongs to.
        static readonly Guid ContainerFmt = new Guid("8c7ed206-3f8a-4827-b3ab-ae9e1faefc6c");
        // Onboard / non-removable audio shares this "generic" container, so it says nothing about pairing.
        static readonly Guid GenericContainer = new Guid("00000000-0000-0000-ffff-ffffffffffff");

        static string ReadContainer(IPropertyStore store)
        {
            try
            {
                var key = new PropertyKey();
                key.fmtid = ContainerFmt;
                key.pid = 2;
                PropVariant pv;
                store.GetValue(ref key, out pv);
                string result = "";
                if (pv.vt == VT_CLSID && pv.p != IntPtr.Zero)
                {
                    Guid g = (Guid)Marshal.PtrToStructure(pv.p, typeof(Guid));
                    if (g != Guid.Empty && g != GenericContainer) result = g.ToString("D");
                }
                PropVariantClear(ref pv);
                return result;
            }
            catch { return ""; }
        }

        // A microphone belongs to an output when both are endpoints of the same physical device
        // (same non-generic container ID), e.g. a USB or Bluetooth headset. If there is no such
        // microphone, or more than one, nothing is paired and the microphone is left alone.
        public static AudioDevice FindMicFor(AudioDevice output, List<AudioDevice> mics)
        {
            if (output.Container.Length == 0) return null;
            var matches = mics.Where(m => m.Container == output.Container).ToList();
            return matches.Count == 1 ? matches[0] : null;
        }

        static string ReadString(IPropertyStore store, Guid fmtid, uint pid)
        {
            try
            {
                var key = new PropertyKey();
                key.fmtid = fmtid;
                key.pid = pid;
                PropVariant pv;
                store.GetValue(ref key, out pv);
                string text = (pv.vt == VT_LPWSTR) ? Marshal.PtrToStringUni(pv.p) : null;
                PropVariantClear(ref pv);
                return text ?? "";
            }
            catch { return ""; }
        }

        // Windows prefixes a device name with "2- " when it shows up on another port / as a second instance.
        static string StripPrefix(string text)
        {
            return Regex.Replace(text, @"^\d+\s*-\s*", "").Trim();
        }

        static AudioDevice ReadDevice(IMMDevice dev, string id)
        {
            string name = "", desc = "", iface = "", container = "";
            try
            {
                IPropertyStore store;
                dev.OpenPropertyStore(0 /* STGM_READ */, out store);
                container = ReadContainer(store);
                name = ReadString(store, DevicePropsFmt, 14);
                desc = ReadString(store, DevicePropsFmt, 2);
                iface = StripPrefix(ReadString(store, InterfacePropsFmt, 2));
            }
            catch { }

            if (name.Length == 0) name = "Unknown device";
            string key = (desc.Length > 0 && iface.Length > 0) ? desc + " // " + iface : StripPrefix(name);
            return new AudioDevice(id, name, key, container);
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    struct PropertyKey
    {
        public Guid fmtid;
        public uint pid;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct PropVariant
    {
        public ushort vt;
        public ushort r1, r2, r3;
        public IntPtr p;
        public IntPtr p2;
    }

    [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
    class MMDeviceEnumeratorComObject { }

    [ComImport, Guid("870af99c-171d-4f9e-af0d-e63df40c2bc9")]
    class PolicyConfigClient { }

    [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceEnumerator
    {
        void EnumAudioEndpoints(int dataFlow, uint stateMask, out IMMDeviceCollection devices);
        void GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device);
        void GetDevice([MarshalAs(UnmanagedType.LPWStr)] string id, out IMMDevice device);
        void RegisterEndpointNotificationCallback(IntPtr client);
        void UnregisterEndpointNotificationCallback(IntPtr client);
    }

    [ComImport, Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDeviceCollection
    {
        void GetCount(out uint count);
        void Item(uint index, out IMMDevice device);
    }

    [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IMMDevice
    {
        void Activate(ref Guid iid, uint clsCtx, IntPtr activationParams,
                      [MarshalAs(UnmanagedType.IUnknown)] out object iface);
        void OpenPropertyStore(uint access, out IPropertyStore properties);
        void GetId([MarshalAs(UnmanagedType.LPWStr)] out string id);
        void GetState(out uint state);
    }

    [ComImport, Guid("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore
    {
        void GetCount(out uint count);
        void GetAt(uint index, out PropertyKey key);
        void GetValue(ref PropertyKey key, out PropVariant value);
        void SetValue(ref PropertyKey key, ref PropVariant value);
        void Commit();
    }

    // Undocumented-but-stable interface used by virtually every audio-switching tool.
    // Only SetDefaultEndpoint is called; the others are placeholders to keep vtable slots correct.
    [ComImport, Guid("f8679f50-850a-41cf-9c72-430f290290c8"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPolicyConfig
    {
        [PreserveSig] int GetMixFormat();
        [PreserveSig] int GetDeviceFormat();
        [PreserveSig] int ResetDeviceFormat();
        [PreserveSig] int SetDeviceFormat();
        [PreserveSig] int GetProcessingPeriod();
        [PreserveSig] int SetProcessingPeriod();
        [PreserveSig] int GetShareMode();
        [PreserveSig] int SetShareMode();
        [PreserveSig] int GetPropertyValue();
        [PreserveSig] int SetPropertyValue();
        [PreserveSig] int SetDefaultEndpoint([MarshalAs(UnmanagedType.LPWStr)] string deviceId, int role);
        [PreserveSig] int SetEndpointVisibility();
    }
}
