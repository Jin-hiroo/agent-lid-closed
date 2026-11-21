// Agent Lid Closed for Windows: notification-area app and Windows power control.
// The decisions are made by agent-lid.mjs (Node.js), which this app starts and talks to
// over stdin/stdout with JSON lines. This side owns everything that needs Win32:
// lid state, battery, external displays, the sleep hold, sleeping, wake timers, the menu
// and the settings window. Built with the .NET Framework's csc (C# 5), see build.ps1.
//
//   AgentLidClosed.exe            run the tray app
//   AgentLidClosed.exe proc       print every process: pid, parent pid, start time, name
using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Text;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Win32;

namespace AgentLidClosed
{
    static class Program
    {
        [STAThread]
        static int Main(string[] args)
        {
            if (args.Length > 0 && args[0] == "proc") return ProcessSnapshot.Print();
            if (args.Length == 3 && args[0] == "render-settings") return SettingsForm.Render(args[1], args[2]);
            if (args.Length > 0 && args[0] == "settings")
            {
                EventWaitHandle running;
                if (!EventWaitHandle.TryOpenExisting(TrayApp.SettingsEventName, out running)) return 1;
                running.Set();
                return 0;
            }
            if (args.Length > 0 && args[0] == "quit")
            {
                // Asks a running copy to quit the normal way, restoring sleep (used by install and uninstall).
                EventWaitHandle running;
                if (!EventWaitHandle.TryOpenExisting(TrayApp.QuitEventName, out running)) return 1;
                running.Set();
                return 0;
            }
            bool created;
            using (var mutex = new Mutex(true, "Local\\AgentLidClosedTray", out created))
            {
                if (!created) return 0;
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                var app = new TrayApp();
                Application.ApplicationExit += delegate { app.Shutdown(); };
                Application.Run(app);
            }
            return 0;
        }
    }

    // ---------------------------------------------------------------- processes

    static class ProcessSnapshot
    {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct PROCESSENTRY32
        {
            public uint dwSize; public uint cntUsage; public uint th32ProcessID; public IntPtr th32DefaultHeapID;
            public uint th32ModuleID; public uint cntThreads; public uint th32ParentProcessID; public int pcPriClassBase;
            public uint dwFlags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szExeFile;
        }
        [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32FirstW(IntPtr snapshot, ref PROCESSENTRY32 entry);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32NextW(IntPtr snapshot, ref PROCESSENTRY32 entry);
        [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
        [DllImport("kernel32.dll")] static extern bool GetProcessTimes(IntPtr h, out long creation, out long exit, out long kernel, out long user);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);

        public static int Print()
        {
            IntPtr snapshot = CreateToolhelp32Snapshot(2, 0);
            if (snapshot == new IntPtr(-1)) return 1;
            var output = new StringBuilder();
            var entry = new PROCESSENTRY32();
            entry.dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32));
            if (Process32FirstW(snapshot, ref entry))
            {
                do
                {
                    double start = 0;
                    IntPtr h = OpenProcess(0x1000, false, entry.th32ProcessID);
                    if (h != IntPtr.Zero)
                    {
                        long creation, exit, kernel, user;
                        if (GetProcessTimes(h, out creation, out exit, out kernel, out user) && creation > 0)
                            start = (creation - 116444736000000000L) / 10000000.0;
                        CloseHandle(h);
                    }
                    output.Append(entry.th32ProcessID).Append('\t').Append(entry.th32ParentProcessID).Append('\t')
                        .Append(start.ToString("F3", System.Globalization.CultureInfo.InvariantCulture)).Append('\t')
                        .Append(entry.szExeFile).Append('\n');
                } while (Process32NextW(snapshot, ref entry));
            }
            CloseHandle(snapshot);
            var stdout = Console.OpenStandardOutput();
            var bytes = new UTF8Encoding(false).GetBytes(output.ToString());
            stdout.Write(bytes, 0, bytes.Length);
            stdout.Flush();
            return 0;
        }
    }

    // ---------------------------------------------------------------- power

    /// Lid, battery, displays, the sleep hold, sleeping and wake timers.
    class Power : NativeWindow, IDisposable
    {
        static readonly Guid LidSwitch = new Guid("BA3E0F4D-B817-4094-A2D1-D56379E6A0F3");
        const string SubButtons = "4f971e89-eebd-4455-a8de-9e59040e7347";
        const string LidAction = "5ca83367-6e45-459f-a27b-476b1d01c936";
        const string SubSleep = "238c9fa8-0aad-41ed-83f4-97be242c8f20";
        const string RtcWake = "bd3b718a-0680-4d9d-8ab2-e1d2b4ac806d";

        [DllImport("user32.dll")] static extern IntPtr RegisterPowerSettingNotification(IntPtr h, ref Guid guid, int flags);
        [DllImport("user32.dll")] static extern bool UnregisterPowerSettingNotification(IntPtr h);
        [DllImport("kernel32.dll")] static extern uint SetThreadExecutionState(uint flags);
        [DllImport("powrprof.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.U1)]
        static extern bool SetSuspendState([MarshalAs(UnmanagedType.U1)] bool hibernate, [MarshalAs(UnmanagedType.U1)] bool force,
            [MarshalAs(UnmanagedType.U1)] bool disableWakeEvent);
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern IntPtr CreateWaitableTimer(IntPtr attributes, bool manualReset, string name);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetWaitableTimer(IntPtr timer, ref long due, int period, IntPtr completion, IntPtr arg, bool resume);
        [DllImport("kernel32.dll")] static extern bool CancelWaitableTimer(IntPtr timer);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
        [DllImport("kernel32.dll")] static extern void SetLastError(uint code);
        [DllImport("kernel32.dll")] static extern IntPtr GetCurrentProcess();
        [DllImport("advapi32.dll", SetLastError = true)] static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
        [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool LookupPrivilegeValue(string system, string name, out long luid);
        [StructLayout(LayoutKind.Sequential, Pack = 4)] struct TOKEN_PRIVILEGES { public uint Count; public long Luid; public uint Attributes; }
        [DllImport("advapi32.dll", SetLastError = true)] static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll, ref TOKEN_PRIVILEGES state, int length, IntPtr previous, IntPtr returnLength);

        const uint ES_CONTINUOUS = 0x80000000, ES_SYSTEM_REQUIRED = 0x1;
        IntPtr lidNotification = IntPtr.Zero;
        IntPtr wakeTimer = IntPtr.Zero;
        readonly string holdFile;
        public bool LidClosed;
        public bool LidKnown;
        public bool Holding;
        public double? WakeAt;
        public event Action Changed;
        public event Action Resumed;

        public Power(string stateDir)
        {
            holdFile = Path.Combine(stateDir, "power-hold.json");
            CreateHandle(new CreateParams());
            Guid guid = LidSwitch;
            lidNotification = RegisterPowerSettingNotification(Handle, ref guid, 0);
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == 0x218) // WM_POWERBROADCAST
            {
                int code = m.WParam.ToInt32();
                if (code == 0x8013 && m.LParam != IntPtr.Zero) // PBT_POWERSETTINGCHANGE
                {
                    var setting = (Guid)Marshal.PtrToStructure(m.LParam, typeof(Guid));
                    // POWERBROADCAST_SETTING: GUID, DWORD DataLength, then the data.
                    if (setting == LidSwitch && Marshal.ReadInt32(m.LParam, 16) >= 4)
                    {
                        LidClosed = Marshal.ReadInt32(m.LParam, 20) == 0;
                        LidKnown = true;
                        if (Changed != null) Changed();
                    }
                }
                else if (code == 0xA) { if (Changed != null) Changed(); } // battery or AC changed
                else if (code == 0x7 || code == 0x12) { if (Resumed != null) Resumed(); }
            }
            base.WndProc(ref m);
        }

        public static int? BatteryPercent
        {
            get
            {
                var status = SystemInformation.PowerStatus;
                if ((status.BatteryChargeStatus & BatteryChargeStatus.NoSystemBattery) != 0) return null;
                float p = status.BatteryLifePercent;
                if (p < 0 || p > 1) return null;
                return (int)Math.Round(p * 100);
            }
        }

        public static bool OnBattery
        {
            get { return SystemInformation.PowerStatus.PowerLineStatus == PowerLineStatus.Offline; }
        }

        /// Active displays that aren't built into the computer; null when they can't be read.
        public static bool? HasExternalDisplay
        {
            get
            {
                int count = DisplayConfig.ExternalDisplayCount();
                return count < 0 ? (bool?)null : count > 0;
            }
        }

        /// Runs powercfg with a hard 10 s limit, so a stuck child can't freeze the tray.
        static string RunPowercfg(string arguments, out int exitCode)
        {
            var info = new ProcessStartInfo("powercfg.exe", arguments);
            info.UseShellExecute = false;
            info.CreateNoWindow = true;
            info.RedirectStandardOutput = true;
            info.StandardOutputEncoding = Encoding.Default;
            using (var p = Process.Start(info))
            {
                var output = p.StandardOutput.ReadToEndAsync();
                if (!p.WaitForExit(10000))
                {
                    try { p.Kill(); } catch { }
                    exitCode = -1;
                    return "";
                }
                exitCode = p.ExitCode;
                return output.Wait(2000) ? output.Result : "";
            }
        }

        static string ActiveScheme()
        {
            int code;
            var match = Regex.Match(RunPowercfg("/getactivescheme", out code), "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}");
            return code == 0 && match.Success ? match.Value.ToLowerInvariant() : null;
        }

        /// AC and DC values of a power setting; hidden settings included. Only the hex values are
        /// read, so localized labels don't matter.
        static int[] ReadSetting(string scheme, string subgroup, string setting)
        {
            int code;
            string output = RunPowercfg("/qh " + scheme + " " + subgroup + " " + setting, out code);
            var matches = Regex.Matches(output, "0x([0-9a-fA-F]{8})");
            if (code != 0 || matches.Count < 2) return null;
            return new int[] {
                Convert.ToInt32(matches[matches.Count - 2].Groups[1].Value, 16),
                Convert.ToInt32(matches[matches.Count - 1].Groups[1].Value, 16) };
        }

        /// Writes both values, re-applies the active plan, and checks the result by reading it back.
        /// The active plan must be known: a change to it only takes effect once re-applied.
        static bool WriteSetting(string scheme, string subgroup, string setting, int ac, int dc)
        {
            int a, d, s = 0;
            RunPowercfg("/setacvalueindex " + scheme + " " + subgroup + " " + setting + " " + ac, out a);
            RunPowercfg("/setdcvalueindex " + scheme + " " + subgroup + " " + setting + " " + dc, out d);
            // Looked up after the writes, so a plan switch meanwhile is neither undone nor missed.
            string active = ActiveScheme();
            if (active == null) return false;
            if (active == scheme) RunPowercfg("/setactive " + active, out s);
            int[] now = ReadSetting(scheme, subgroup, setting);
            return a == 0 && d == 0 && s == 0 && now != null && now[0] == ac && now[1] == dc;
        }

        /// The wake-timer setting for the current power source allows this app's timers.
        public static bool WakeTimersAllowed
        {
            get
            {
                string scheme = ActiveScheme();
                if (scheme == null) return true;
                int[] values = ReadSetting(scheme, SubSleep, RtcWake);
                if (values == null) return true;
                return (OnBattery ? values[1] : values[0]) == 1;
            }
        }

        /// The saved lid action, or null when there is none. Throws when the file exists but can't be
        /// read, so that callers never treat an unreadable journal as "nothing to restore".
        Dictionary<string, object> SavedHold()
        {
            string text;
            try { text = File.ReadAllText(holdFile); }
            catch (FileNotFoundException) { return null; }
            catch (DirectoryNotFoundException) { return null; }
            var saved = new JavaScriptSerializer().DeserializeObject(text) as Dictionary<string, object>;
            object scheme, ac, dc;
            if (saved == null || !saved.TryGetValue("scheme", out scheme) || !saved.TryGetValue("ac", out ac) || !saved.TryGetValue("dc", out dc)
                || !(scheme is string) || !Regex.IsMatch((string)scheme, "^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$")
                || !(ac is int) || !(dc is int) || (int)ac < 0 || (int)ac > 3 || (int)dc < 0 || (int)dc > 3)
                throw new InvalidDataException("power-hold.json is unreadable");
            return saved;
        }

        /// The plan the current hold was applied to.
        string heldScheme;

        /// What the watcher last asked for. The tray's repair tick works towards it.
        public bool HoldRequested;

        /// Ends the idle-sleep block; false if Windows refused.
        bool ReleaseExecutionState() { return SetThreadExecutionState(ES_CONTINUOUS) != 0; }

        /// Like `pmset disablesleep 1`: closing the lid does nothing and idle sleep is blocked.
        /// The previous lid action is saved first (written then renamed), so a crash can't lose it.
        /// Any failure leaves the computer unheld (and reports so) rather than half held.
        public string SetHold(bool hold)
        {
            HoldRequested = hold;
            try
            {
                if (!hold)
                {
                    string error = null;
                    if (ReleaseExecutionState()) Holding = false;
                    else error = "スリープの許可に失敗しました";
                    heldScheme = null;
                    return RestoreLidAction() ?? error;
                }
                string scheme = ActiveScheme();
                if (scheme == null) return FailHold("電源プランを読み取れませんでした");
                var saved = SavedHold();
                if (saved != null && (saved["scheme"] as string) != scheme)
                {
                    // Another plan became active: put the old plan back before holding on this one.
                    string error = RestoreLidAction();
                    if (error != null) return FailHold(error);
                    saved = null;
                }
                if (saved == null)
                {
                    int[] original = ReadSetting(scheme, SubButtons, LidAction);
                    if (original == null) return FailHold("蓋を閉じたときの動作を読み取れませんでした");
                    string temporary = holdFile + ".tmp";
                    File.WriteAllText(temporary, "{\"scheme\":\"" + scheme + "\",\"ac\":" + original[0] + ",\"dc\":" + original[1] + "}");
                    if (File.Exists(holdFile)) File.Delete(holdFile);
                    File.Move(temporary, holdFile);
                }
                // Always written and re-applied, also over an existing journal or values that already
                // read 0: an earlier attempt may have stored them without activating them.
                if (!WriteSetting(scheme, SubButtons, LidAction, 0, 0) || ActiveScheme() != scheme)
                {
                    RestoreLidAction();
                    return FailHold("蓋を閉じたときの動作を変更できませんでした");
                }
                if (SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED) == 0)
                {
                    RestoreLidAction();
                    return FailHold("スリープを止められませんでした");
                }
                Holding = true;
                heldScheme = scheme;
                return null;
            }
            catch (Exception e) { return FailHold("電源設定の変更に失敗しました: " + e.Message); }
        }

        string FailHold(string error)
        {
            if (ReleaseExecutionState()) Holding = false;
            heldScheme = null;
            return error;
        }

        /// Puts back the lid action saved by SetHold, also after a crash. The journal is deleted only
        /// once the original values are in place and re-applied, so a failure is retried later.
        public string RestoreLidAction()
        {
            Dictionary<string, object> saved;
            try { saved = SavedHold(); }
            catch { return "保存した「蓋を閉じたときの動作」を読み取れません（power-hold.json）"; }
            if (saved == null) return null;
            string scheme = saved["scheme"] as string;
            int ac = Convert.ToInt32(saved["ac"]), dc = Convert.ToInt32(saved["dc"]);
            // Written (and re-applied when active) even if the stored values already match: an earlier
            // attempt may have stored them without activating them.
            if (!WriteSetting(scheme, SubButtons, LidAction, ac, dc))
                return "蓋を閉じたときの動作を元に戻せませんでした（あとで再試行します）";
            File.Delete(holdFile);
            return null;
        }

        public bool HoldFileExists { get { return File.Exists(holdFile); } }

        /// While holding: the hold is still on the active plan. Unknown counts as a mismatch, so the
        /// tray re-applies the hold (which re-reads everything).
        public bool HoldMatchesActivePlan
        {
            get
            {
                string scheme = ActiveScheme();
                return scheme != null && scheme == heldScheme && File.Exists(holdFile);
            }
        }

        static void EnableShutdownPrivilege()
        {
            IntPtr token;
            if (!OpenProcessToken(GetCurrentProcess(), 0x28, out token)) return; // ADJUST_PRIVILEGES | QUERY
            try
            {
                var privileges = new TOKEN_PRIVILEGES { Count = 1, Attributes = 2 }; // SE_PRIVILEGE_ENABLED
                if (LookupPrivilegeValue(null, "SeShutdownPrivilege", out privileges.Luid))
                    AdjustTokenPrivileges(token, false, ref privileges, 0, IntPtr.Zero, IntPtr.Zero);
            }
            finally { CloseHandle(token); }
        }

        bool MaySleep()
        {
            return LidKnown && LidClosed && HasExternalDisplay == false && !Holding;
        }

        /// Step 1 of sleeping: what closing the lid would have done without the hold. macOS always
        /// sleeps; Windows follows the power plan's lid action (restored by SetHold(false) just before),
        /// so with "Do nothing", for example on a computer used remotely with its lid closed, it stays
        /// awake. Returns the plan to suspend under, or null with the reason in `done`.
        public string PrepareSleep(out string done)
        {
            done = null;
            if (!MaySleep())
            {
                done = "Not sleeping: the lid is open, a display is attached, or sleep is held again";
                return null;
            }
            string scheme = ActiveScheme();
            int[] lid = scheme == null ? null : ReadSetting(scheme, SubButtons, LidAction);
            if (lid == null)
            {
                done = "Not sleeping: the lid action couldn't be read";
                return null;
            }
            if (lid[0] != 1 && lid[0] != 2 && lid[1] != 1 && lid[1] != 2)
            {
                done = "Lid is closed, but its action is \"Do nothing\": staying awake";
                return null;
            }
            EnableShutdownPrivilege();
            return scheme;
        }

        /// Step 2, after the watcher confirmed that no agent started meanwhile: everything is checked
        /// again, including the power source, right before suspending.
        public string FinishSleep(string scheme, double deadline, out string done)
        {
            int[] lid = ReadSetting(scheme, SubButtons, LidAction);
            string active = ActiveScheme();
            // Last: let a queued lid-open or power notification through, then decide.
            Application.DoEvents();
            if (!MaySleep() || lid == null || active != scheme || TrayApp.AwakeNow() > deadline)
            {
                done = "Not sleeping: the lid, displays, hold or power plan changed";
                return null;
            }
            int action = OnBattery ? lid[1] : lid[0];
            if (action != 1 && action != 2)
            {
                done = "Lid is closed, but its action on this power source is \"Do nothing\": staying awake";
                return null;
            }
            done = action == 1 ? "Lid is closed: sleeping now" : "Lid is closed: hibernating now (lid action)";
            if (SetSuspendState(action == 2, false, false)) return null;
            return "スリープできませんでした (" + Marshal.GetLastWin32Error() + ")";
        }

        /// One wake alarm for this app, like the macOS helper's tagged pmset event. Returns an error,
        /// or null when the requested state (an alarm at `epoch`, or none) is in place.
        public string SetWake(double? epoch)
        {
            if (wakeTimer != IntPtr.Zero && !CancelWaitableTimer(wakeTimer))
                return "スリープ解除タイマーを取り消せませんでした";
            WakeAt = null;
            if (epoch == null) return null;
            if (wakeTimer == IntPtr.Zero) wakeTimer = CreateWaitableTimer(IntPtr.Zero, true, null);
            if (wakeTimer == IntPtr.Zero) return "スリープ解除タイマーを作れませんでした";
            long due = (long)(epoch.Value * 10000000.0) + 116444736000000000L;
            SetLastError(0);
            if (!SetWaitableTimer(wakeTimer, ref due, 0, IntPtr.Zero, IntPtr.Zero, true))
                return "スリープ解除タイマーを設定できませんでした (" + Marshal.GetLastWin32Error() + ")";
            WakeAt = epoch;
            // Success with ERROR_NOT_SUPPORTED: the timer runs but can't wake this computer.
            if (Marshal.GetLastWin32Error() == 50) return "この PC はタイマーでスリープ解除できません";
            return null;
        }

        public void Dispose()
        {
            if (lidNotification != IntPtr.Zero) UnregisterPowerSettingNotification(lidNotification);
            if (wakeTimer != IntPtr.Zero) { CancelWaitableTimer(wakeTimer); CloseHandle(wakeTimer); wakeTimer = IntPtr.Zero; }
            DestroyHandle();
        }
    }

    /// Counts active displays whose connection isn't internal, through QueryDisplayConfig.
    static class DisplayConfig
    {
        [StructLayout(LayoutKind.Sequential)] struct LUID { public uint Low; public int High; }
        [StructLayout(LayoutKind.Sequential)]
        struct PATH_SOURCE { public LUID adapterId; public uint id; public uint modeInfoIdx; public uint statusFlags; }
        [StructLayout(LayoutKind.Sequential)]
        struct PATH_TARGET
        {
            public LUID adapterId; public uint id; public uint modeInfoIdx; public uint outputTechnology; public uint rotation;
            public uint scaling; public uint refreshNum; public uint refreshDen; public uint scanLineOrdering; public bool targetAvailable; public uint statusFlags;
        }
        [StructLayout(LayoutKind.Sequential)] struct PATH_INFO { public PATH_SOURCE source; public PATH_TARGET target; public uint flags; }
        [StructLayout(LayoutKind.Explicit, Size = 64)] struct MODE_INFO { [FieldOffset(0)] public uint infoType; }
        [DllImport("user32.dll")] static extern int GetDisplayConfigBufferSizes(uint flags, out uint paths, out uint modes);
        [DllImport("user32.dll")] static extern int QueryDisplayConfig(uint flags, ref uint paths, [Out] PATH_INFO[] pathArray, ref uint modes, [Out] MODE_INFO[] modeArray, IntPtr topology);

        /// -1 when the configuration can't be read.
        public static int ExternalDisplayCount()
        {
            try
            {
                uint pathCount = 0, modeCount = 0;
                PATH_INFO[] paths = null;
                int result = 122;
                // The configuration can change between the two calls: ERROR_INSUFFICIENT_BUFFER, try again.
                for (int attempt = 0; attempt < 3 && result == 122; attempt++)
                {
                    if (GetDisplayConfigBufferSizes(2, out pathCount, out modeCount) != 0) return -1; // QDC_ONLY_ACTIVE_PATHS
                    paths = new PATH_INFO[pathCount];
                    var modes = new MODE_INFO[modeCount];
                    result = QueryDisplayConfig(2, ref pathCount, paths, ref modeCount, modes, IntPtr.Zero);
                }
                if (result != 0) return -1;
                int count = 0;
                for (int i = 0; i < pathCount; i++)
                {
                    uint tech = paths[i].target.outputTechnology;
                    // INTERNAL, DISPLAYPORT_EMBEDDED, UDI_EMBEDDED
                    if (tech != 0x80000000 && tech != 11 && tech != 13) count++;
                }
                return count;
            }
            catch { return -1; }
        }
    }

    // ---------------------------------------------------------------- tray

    class TrayApp : ApplicationContext
    {
        readonly string appDir = Path.GetDirectoryName(Application.ExecutablePath);
        readonly string stateDir;
        readonly string logFile;
        readonly JavaScriptSerializer json = new JavaScriptSerializer();
        readonly SynchronizationContext ui;
        readonly NotifyIcon tray = new NotifyIcon();
        readonly ContextMenuStrip menu = new ContextMenuStrip();
        readonly System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer();
        readonly Dictionary<string, Icon> icons = new Dictionary<string, Icon>();
        readonly Power power;
        Process watcher;
        StreamWriter watcherInput;
        string pendingSleepScheme;
        long pendingSleepID;
        double pendingSleepAt;
        double lastMessageAt = AwakeSeconds();
        [DllImport("kernel32.dll")] static extern bool QueryUnbiasedInterruptTime(out ulong time);
        /// Seconds the computer has been awake since boot: time spent asleep doesn't count.
        public static double AwakeNow() { return AwakeSeconds(); }
        static double AwakeSeconds() { ulong t; return QueryUnbiasedInterruptTime(out t) ? t / 10000000.0 : Environment.TickCount / 1000.0; }
        DateTime lastPowerCheck = DateTime.MinValue;
        DateTime watcherStarted;
        int restarts;
        bool quitting;
        bool shutDown;
        Dictionary<string, object> status;
        string lastPowerReport;
        DateTime lastPowerSent = DateTime.MinValue;
        SettingsForm settingsForm;
        long lastEventID = -1;
        public const string QuitEventName = "Local\\AgentLidClosedQuit";
        readonly EventWaitHandle quitEvent = new EventWaitHandle(false, EventResetMode.AutoReset, QuitEventName);
        public const string SettingsEventName = "Local\\AgentLidClosedSettings";
        readonly EventWaitHandle settingsEvent = new EventWaitHandle(false, EventResetMode.AutoReset, SettingsEventName);

        public TrayApp()
        {
            ui = SynchronizationContext.Current ?? new WindowsFormsSynchronizationContext();
            string local = Environment.GetEnvironmentVariable("AGENT_LID_STATE_DIR");
            stateDir = string.IsNullOrEmpty(local)
                ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "AgentLidClosed") : local;
            Directory.CreateDirectory(stateDir);
            logFile = Path.Combine(stateDir, "AgentLidClosed.log");
            power = new Power(stateDir);
            // A hold left behind by a crash: put the lid action back; the watcher asks again if it's needed.
            if (power.HoldFileExists)
            {
                string error = power.RestoreLidAction();
                Log(error ?? "Restored the lid action left changed by the last run");
            }
            power.Changed += delegate { ReportPower(true); };
            power.Resumed += delegate { lastMessageAt = AwakeSeconds(); Send(new Dictionary<string, object> { { "type", "resumed" } }); ReportPower(true); };
            SystemEvents.SessionEnding += delegate { ReleaseForExit(); };
            SystemEvents.DisplaySettingsChanged += delegate { ReportPower(true); };

            tray.Text = "Agent Lid Closed";
            tray.Icon = IconFor("moon");
            tray.Visible = true;
            tray.ContextMenuStrip = menu;
            menu.Opening += delegate { BuildMenu(); };
            tray.MouseUp += delegate(object sender, MouseEventArgs e)
            {
                if (e.Button == MouseButtons.Left)
                {
                    var show = typeof(NotifyIcon).GetMethod("ShowContextMenu",
                        System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic);
                    if (show != null) show.Invoke(tray, null);
                }
            };
            BuildMenu();
            StartWatcher();
            var quitWatcher = new Thread(delegate()
            {
                while (quitEvent.WaitOne()) ui.Post(delegate { if (!quitting) Quit(); }, null);
            });
            quitWatcher.IsBackground = true;
            quitWatcher.Start();
            var settingsWatcher = new Thread(delegate()
            {
                while (settingsEvent.WaitOne()) ui.Post(delegate { ShowSettings(); }, null);
            });
            settingsWatcher.IsBackground = true;
            settingsWatcher.Start();
            timer.Interval = 2000;
            timer.Tick += delegate { Tick(); };
            timer.Start();
        }

        void Log(string message)
        {
            try { File.AppendAllText(logFile, DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ss.fffZ") + " [tray] " + message + "\n"); }
            catch { }
        }

        // ---- watcher process

        string FindNode()
        {
            string configured = Environment.GetEnvironmentVariable("AGENT_LID_NODE");
            if (!string.IsNullOrEmpty(configured) && File.Exists(configured)) return configured;
            string recorded = Path.Combine(appDir, "node-path.txt");
            if (File.Exists(recorded))
            {
                string path = File.ReadAllText(recorded).Trim();
                if (File.Exists(path)) return path;
            }
            foreach (string dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';'))
            {
                try
                {
                    string candidate = Path.Combine(dir.Trim(), "node.exe");
                    if (File.Exists(candidate)) return candidate;
                }
                catch { }
            }
            return null;
        }

        void StartWatcher()
        {
            string node = FindNode();
            if (node == null)
            {
                MessageBox.Show("Node.js が見つかりません。Node.js 22.16 以降をインストールしてください。", "Agent Lid Closed");
                ExitThread();
                return;
            }
            var info = new ProcessStartInfo(node, "\"" + Path.Combine(appDir, "agent-lid.mjs") + "\" run --tray");
            info.UseShellExecute = false;
            info.CreateNoWindow = true;
            info.RedirectStandardInput = true;
            info.RedirectStandardOutput = true;
            info.StandardOutputEncoding = new UTF8Encoding(false);
            info.WorkingDirectory = appDir;
            var process = new Process();
            process.StartInfo = info;
            process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs e)
            {
                // Lines from a watcher that has since been replaced are dropped.
                if (e.Data != null) { string line = e.Data; ui.Post(delegate { if (process == watcher) Receive(line); }, null); }
            };
            process.Start();
            // .NET Framework would write the console code page (Shift-JIS here); Node reads UTF-8.
            watcherInput = new StreamWriter(process.StandardInput.BaseStream, new UTF8Encoding(false));
            watcherInput.AutoFlush = true;
            watcherInput.NewLine = "\n";
            process.BeginOutputReadLine();
            watcher = process;
            lastMessageAt = AwakeSeconds();
            watcherStarted = DateTime.Now;
            lastPowerReport = null;
            ReportPower(true);
        }

        void Tick()
        {
            // A watcher that stops answering can't release its hold: treat it like one that exited.
            if (watcher != null && !watcher.HasExited && !quitting && power.Holding && AwakeSeconds() - lastMessageAt > 60)
            {
                Log("Watcher stopped responding; releasing the hold and restarting it");
                try { watcher.Kill(); watcher.WaitForExit(3000); } catch { }
            }
            if (!quitting && (DateTime.Now - lastPowerCheck).TotalSeconds >= 15)
            {
                lastPowerCheck = DateTime.Now;
                if (!power.HoldRequested && (power.Holding || power.HoldFileExists))
                {
                    // A release that failed earlier: keep trying until sleep and the lid action are back.
                    string error = power.SetHold(false);
                    if (error == null) Log("Restored the lid action");
                    ReportPower(true);
                    // The watcher decides whether the closed lid should now put the computer to sleep.
                    if (error == null && !power.Holding) Send(new Dictionary<string, object> { { "type", "released" } });
                }
                else if (power.HoldRequested && power.Holding && !power.HoldMatchesActivePlan)
                {
                    // Another power plan became active: move the hold to it.
                    string error = power.SetHold(true);
                    Log(error ?? "Power plan changed: hold moved to the active plan");
                    ReportPower(true);
                }
            }
            if (watcher != null && watcher.HasExited && !quitting)
            {
                // Nothing is deciding any more: never leave the computer unable to sleep.
                if (power.Holding || power.HoldFileExists) { ApplyHold(false, null); }
                power.SetWake(null);
                status = null;
                if ((DateTime.Now - watcherStarted).TotalMinutes > 5) restarts = 0;
                restarts++;
                if (restarts <= 5) { Log("Watcher exited; restarting"); StartWatcher(); }
                else if (restarts == 6)
                {
                    tray.ShowBalloonTip(8000, "Agent Lid Closed", "監視プロセスが繰り返し終了しました。ログを確認してください。", ToolTipIcon.Warning);
                }
                UpdateIcon();
            }
            ReportPower(false);
        }

        void Send(Dictionary<string, object> message)
        {
            try
            {
                if (watcher != null && !watcher.HasExited && watcherInput != null) watcherInput.WriteLine(json.Serialize(message));
            }
            catch { }
        }

        void SendCommand(string name, params object[] pairs)
        {
            var message = new Dictionary<string, object> { { "type", "command" }, { "name", name } };
            for (int i = 0; i + 1 < pairs.Length; i += 2) message[(string)pairs[i]] = pairs[i + 1];
            Send(message);
        }

        void ReportPower(bool force)
        {
            var report = new Dictionary<string, object>();
            report["type"] = "power";
            report["lidClosed"] = power.LidClosed;
            report["lidKnown"] = power.LidKnown;
            report["onBattery"] = Power.OnBattery;
            report["battery"] = Power.BatteryPercent;
            report["externalDisplay"] = Power.HasExternalDisplay;
            report["holding"] = power.Holding;
            string text = json.Serialize(report);
            if (!force && text == lastPowerReport && (DateTime.Now - lastPowerSent).TotalSeconds < 30) return;
            lastPowerReport = text;
            lastPowerSent = DateTime.Now;
            Send(report);
        }

        void ApplyHold(bool hold, object id)
        {
            string error = power.SetHold(hold);
            // The power report goes first, so the watcher decides on the current lid and displays.
            ReportPower(true);
            var reply = new Dictionary<string, object> { { "type", "holdResult" }, { "id", id }, { "ok", error == null }, { "error", error } };
            reply["holding"] = power.Holding;
            Send(reply);
        }

        void Receive(string line)
        {
            Dictionary<string, object> message;
            try { message = json.DeserializeObject(line) as Dictionary<string, object>; }
            catch { return; }
            if (message == null || !message.ContainsKey("type")) return;
            lastMessageAt = AwakeSeconds();
            switch (message["type"] as string)
            {
                case "heartbeat":
                    break;
                case "status":
                    status = message;
                    UpdateIcon();
                    ShowEvents();
                    if (settingsForm != null && !settingsForm.IsDisposed) settingsForm.Update(status);
                    break;
                case "hold":
                    ApplyHold(Convert.ToBoolean(message["hold"]), message.ContainsKey("id") ? message["id"] : null);
                    break;
                case "wake":
                {
                    object at = message.ContainsKey("at") ? message["at"] : null;
                    string error = power.SetWake(at == null ? (double?)null : Convert.ToDouble(at));
                    string warning = null;
                    if (error == null && at != null && !Power.WakeTimersAllowed)
                        warning = "Windows の電源オプションで「スリープ解除タイマーの許可」が無効です";
                    var reply = new Dictionary<string, object> { { "type", "wakeResult" }, { "id", Get(message, "id") } };
                    reply["ok"] = error == null;
                    reply["armedAt"] = power.WakeAt;
                    reply["error"] = error ?? warning;
                    Send(reply);
                    break;
                }
                case "sleepNow":
                {
                    // The policy reads take a moment, so the watcher confirms afterwards that no agent
                    // started meanwhile; only then does FinishSleep check everything again and suspend.
                    string done;
                    string scheme = power.PrepareSleep(out done);
                    if (scheme == null) { if (done != null) Log(done); break; }
                    pendingSleepScheme = scheme;
                    pendingSleepID++;
                    pendingSleepAt = AwakeSeconds();
                    Send(new Dictionary<string, object> { { "type", "confirmSleep" }, { "id", pendingSleepID } });
                    break;
                }
                case "sleepConfirmed":
                {
                    object id = Get(message, "id");
                    bool ok = Get(message, "ok") is bool && (bool)Get(message, "ok");
                    if (pendingSleepScheme == null || id == null || Convert.ToInt64(id) != pendingSleepID) break;
                    string scheme = pendingSleepScheme;
                    pendingSleepScheme = null;
                    if (!ok) { Log("Not sleeping: an agent became active"); break; }
                    string done;
                    string error = power.FinishSleep(scheme, pendingSleepAt + 10, out done);
                    if (done != null) Log(done);
                    if (error != null) Log(error);
                    break;
                }
                case "alert":
                    MessageBox.Show(message["message"] as string, "Agent Lid Closed");
                    break;
                case "exit":
                    FinishQuit();
                    break;
            }
        }

        void ShowEvents()
        {
            var events = Get(status, "events") as object[];
            if (events == null) return;
            long max = lastEventID < 0 ? 0 : lastEventID;
            foreach (object item in events)
            {
                var e = item as Dictionary<string, object>;
                if (e == null) continue;
                long id = Convert.ToInt64(e["id"]);
                if (lastEventID >= 0 && id > lastEventID)
                    tray.ShowBalloonTip(8000, (Get(e, "title") as string) ?? "Agent Lid Closed", e["message"] as string, ToolTipIcon.Info);
                if (id > max) max = id;
            }
            lastEventID = max;
        }

        static object Get(Dictionary<string, object> map, string key)
        {
            object value;
            return map != null && map.TryGetValue(key, out value) ? value : null;
        }

        bool Flag(string key)
        {
            var settings = Get(status, "settings") as Dictionary<string, object>;
            object value = Get(settings, key);
            return value is bool && (bool)value;
        }

        // ---- icon

        Icon IconFor(string name)
        {
            Icon icon;
            if (icons.TryGetValue(name, out icon)) return icon;
            string glyph;
            switch (name)
            {
                case "cup": glyph = "☕"; break;
                case "sun": glyph = "☀"; break;
                case "timer": glyph = "⏱"; break;
                case "hourglass": glyph = "⌛"; break;
                case "pause": glyph = "⏸"; break;
                case "warning": glyph = "⚠"; break;
                default: glyph = "☾"; break;
            }
            bool light = false;
            try { light = Convert.ToInt32(Registry.GetValue("HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize", "SystemUsesLightTheme", 0)) == 1; }
            catch { }
            using (var bitmap = new Bitmap(32, 32))
            {
                using (var g = Graphics.FromImage(bitmap))
                using (var font = new Font("Segoe UI Symbol", 20, FontStyle.Regular, GraphicsUnit.Pixel))
                using (var brush = new SolidBrush(light ? Color.Black : Color.White))
                {
                    g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
                    g.Clear(Color.Transparent);
                    var format = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
                    g.DrawString(glyph, font, brush, new RectangleF(0, 0, 32, 32), format);
                }
                icon = Icon.FromHandle(bitmap.GetHicon());
            }
            icons[name] = icon;
            return icon;
        }

        void UpdateIcon()
        {
            string name = (Get(status, "icon") as string) ?? "moon";
            tray.Icon = IconFor(name);
            string headline = (Get(status, "headline") as string) ?? "起動中…";
            string tip = "Agent Lid Closed: " + headline;
            tray.Text = tip.Length > 63 ? tip.Substring(0, 63) : tip;
        }

        // ---- menu

        ToolStripMenuItem Item(ToolStripItemCollection items, string text, EventHandler click, bool check = false, bool enabled = true)
        {
            var item = new ToolStripMenuItem(text);
            item.Checked = check;
            item.Enabled = enabled;
            if (click != null) item.Click += click;
            items.Add(item);
            return item;
        }

        void Toggle(ToolStripItemCollection items, string text, string key)
        {
            bool on = Flag(key);
            Item(items, text, delegate { SendCommand("set", "key", key, "value", !on); }, on, status != null);
        }

        void BuildMenu()
        {
            menu.Items.Clear();
            if (status == null)
            {
                Item(menu.Items, "起動中…", null, false, false);
            }
            else
            {
                Item(menu.Items, (Get(status, "headline") as string) ?? "", null, false, false);
                foreach (object line in (Get(status, "detail") as object[]) ?? new object[0])
                    Item(menu.Items, line as string, null, false, false);
                menu.Items.Add(new ToolStripSeparator());
                var sessions = (Get(status, "sessions") as object[]) ?? new object[0];
                if (sessions.Length == 0) Item(menu.Items, "エージェントのセッションはありません", null, false, false);
                foreach (object session in sessions)
                    Item(menu.Items, Get(session as Dictionary<string, object>, "text") as string, null, false, false);
            }
            menu.Items.Add(new ToolStripSeparator());
            bool manual = status != null && Get(status, "manualActive") is bool && (bool)Get(status, "manualActive");
            var keep = Item(menu.Items, manual ? "スリープさせない（オン）" : "スリープさせない", null, manual, status != null);
            if (manual)
            {
                Item(keep.DropDownItems, "オフにする（自動に戻す）", delegate { SendCommand("manualOff"); });
                keep.DropDownItems.Add(new ToolStripSeparator());
            }
            Item(keep.DropDownItems, "オフにするまで", delegate { SendCommand("manual"); });
            foreach (int minutes in new[] { 30, 60, 120, 240 })
            {
                int m = minutes;
                string label = m < 60 ? m + " 分" : (m / 60) + " 時間";
                Item(keep.DropDownItems, label, delegate { SendCommand("manual", "seconds", m * 60); });
            }
            Item(keep.DropDownItems, "時間を指定…", delegate { AskForDuration(); });
            Toggle(menu.Items, "自動モード", "autoEnabled");
            Toggle(menu.Items, "使用量のリセット前にスリープ解除", "wakeForQuotaReset");
            if (status != null && Get(status, "switchAvailable") is bool && (bool)Get(status, "switchAvailable"))
                Toggle(menu.Items, "使用上限でアカウントを切り替える", "switchAccountAtLimit");
            if (status != null && Get(status, "t3Installed") is bool && (bool)Get(status, "t3Installed"))
            {
                object auto = Get(status, "autoResume");
                bool on = auto is bool && (bool)auto;
                Item(menu.Items, "リセット後に自動で再開する (T3 Code)", delegate { SendCommand("autoResume", "value", !on); }, on);
            }
            menu.Items.Add(new ToolStripSeparator());
            Item(menu.Items, "設定…", delegate { ShowSettings(); });
            Item(menu.Items, "ログを開く", delegate { OpenLog(); });
            menu.Items.Add(new ToolStripSeparator());
            Item(menu.Items, "終了（通常のスリープに戻す）", delegate { Quit(); });
        }

        public void OpenLog()
        {
            if (!File.Exists(logFile)) File.WriteAllText(logFile, "");
            Process.Start("notepad.exe", "\"" + logFile + "\"");
        }

        void AskForDuration()
        {
            string message = "時間を入力してください（例: 90（分）、1:30、2h、1h 30m）。終わるとエージェントに合わせたスリープに戻ります。";
            while (true)
            {
                string text = InputDialog.Show("スリープさせない時間", message, "1h 30m");
                if (text == null) return;
                double? seconds = ParseDuration(text);
                if (seconds != null) { SendCommand("manual", "seconds", seconds.Value); return; }
                message = "「" + text + "」は 7 日以内の時間として読めません。90、1:30、2h、1h 30m のように入力してください。";
            }
        }

        /// Port of ManualAwake.parseDuration.
        public static double? ParseDuration(string text)
        {
            string input = (text ?? "").Trim().ToLowerInvariant();
            if (input.Length == 0) return null;
            double seconds;
            double minutes;
            var invariant = System.Globalization.CultureInfo.InvariantCulture;
            if (double.TryParse(input, System.Globalization.NumberStyles.Float, invariant, out minutes))
            {
                seconds = minutes * 60;
            }
            else if (input.Contains(":"))
            {
                var parts = input.Split(':');
                double h; int m;
                if (parts.Length != 2 || !Regex.IsMatch(parts[0], "^[0-9]+$") || !double.TryParse(parts[0], System.Globalization.NumberStyles.None, invariant, out h)
                    || parts[1].Length != 2 || !int.TryParse(parts[1], System.Globalization.NumberStyles.None, invariant, out m) || m >= 60) return null;
                seconds = h * 3600 + m * 60;
            }
            else
            {
                var match = Regex.Match(input, "^(\\s*([0-9.]+)\\s*([a-z]+)\\s*)+$");
                if (!match.Success) return null;
                seconds = 0;
                var groupValues = match.Groups[2].Captures;
                var groupUnits = match.Groups[3].Captures;
                for (int i = 0; i < groupValues.Count; i++)
                {
                    double value;
                    if (!double.TryParse(groupValues[i].Value, System.Globalization.NumberStyles.Float, invariant, out value)) return null;
                    switch (groupUnits[i].Value)
                    {
                        case "h": case "hr": case "hrs": case "hour": case "hours": seconds += value * 3600; break;
                        case "m": case "min": case "mins": case "minute": case "minutes": seconds += value * 60; break;
                        case "s": case "sec": case "secs": case "second": case "seconds": seconds += value; break;
                        default: return null;
                    }
                }
            }
            if (double.IsNaN(seconds) || double.IsInfinity(seconds) || seconds < 1 || seconds > 7 * 24 * 3600) return null;
            return Math.Round(seconds);
        }

        void ShowSettings()
        {
            if (settingsForm == null || settingsForm.IsDisposed)
            {
                settingsForm = new SettingsForm(this);
                if (status != null) settingsForm.Update(status);
            }
            settingsForm.Show();
            settingsForm.Activate();
        }

        public void SettingsCommand(string name, params object[] pairs) { SendCommand(name, pairs); }

        // ---- quitting

        void Quit()
        {
            quitting = true;
            // The watcher releases its hold and clears its alarm, then says "exit".
            SendCommand("quit");
            var deadline = new System.Windows.Forms.Timer();
            deadline.Interval = 5000;
            deadline.Tick += delegate { deadline.Stop(); FinishQuit(); };
            deadline.Start();
        }

        void FinishQuit()
        {
            ReleaseForExit();
            tray.Visible = false;
            ExitThread();
        }

        void ReleaseForExit()
        {
            if (shutDown) return;
            shutDown = true;
            try { if (watcher != null && !watcher.HasExited) watcher.Kill(); } catch { }
            string error = power.SetHold(false);
            if (error != null) Log("Quit: " + error);
            power.SetWake(null);
        }

        public void Shutdown()
        {
            ReleaseForExit();
            power.Dispose();
            tray.Dispose();
        }
    }

    static class InputDialog
    {
        public static string Show(string title, string message, string placeholder)
        {
            using (var form = new Form())
            {
                form.Text = title;
                form.FormBorderStyle = FormBorderStyle.FixedDialog;
                form.StartPosition = FormStartPosition.CenterScreen;
                form.MinimizeBox = false; form.MaximizeBox = false;
                form.ClientSize = new Size(420, 140);
                form.TopMost = true;
                var label = new Label { Text = message, Left = 12, Top = 12, Width = 396, Height = 48 };
                var box = new TextBox { Left = 12, Top = 64, Width = 396, Text = "" };
                var ok = new Button { Text = "開始", Left = 232, Top = 100, Width = 84, DialogResult = DialogResult.OK };
                var cancel = new Button { Text = "キャンセル", Left = 324, Top = 100, Width = 84, DialogResult = DialogResult.Cancel };
                form.Controls.AddRange(new Control[] { label, box, ok, cancel });
                form.AcceptButton = ok; form.CancelButton = cancel;
                return form.ShowDialog() == DialogResult.OK ? box.Text : null;
            }
        }
    }

    // ---------------------------------------------------------------- settings window

    class SettingsForm : Form
    {
        readonly TrayApp app;
        bool updating;
        readonly CheckBox autoBox = new CheckBox(), loginBox = new CheckBox(), wakeBox = new CheckBox(), switchBox = new CheckBox(), resumeBox = new CheckBox();
        readonly NumericUpDown batteryFloor = new NumericUpDown(), sleepGrace = new NumericUpDown(), notifyTimeout = new NumericUpDown(),
            workingStale = new NumericUpDown(), backgroundStale = new NumericUpDown();
        readonly Label switchNote = new Label(), accountsLabel = new Label(), t3Label = new Label(), powerLabel = new Label();
        readonly FlowLayoutPanel hookPanel = new FlowLayoutPanel();
        string hookSignature;

        public SettingsForm(TrayApp app)
        {
            this.app = app;
            Text = "Agent Lid Closed の設定";
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            ClientSize = new Size(560, 470);
            Font = new Font("Yu Gothic UI", 9F);
            var tabs = new TabControl { Dock = DockStyle.Fill };
            tabs.TabPages.Add(GeneralTab());
            tabs.TabPages.Add(TimingTab());
            tabs.TabPages.Add(LimitsTab());
            tabs.TabPages.Add(IntegrationsTab());
            Controls.Add(tabs);
        }

        static Label Note(string text, int top, int height = 40)
        {
            return new Label { Text = text, Left = 16, Top = top, Width = 510, Height = height, ForeColor = SystemColors.GrayText };
        }

        CheckBox Check(TabPage page, CheckBox box, string text, int top, string key)
        {
            box.Text = text; box.Left = 16; box.Top = top; box.Width = 510;
            box.CheckedChanged += delegate { if (!updating) app.SettingsCommand("set", "key", key, "value", box.Checked); };
            page.Controls.Add(box);
            return box;
        }

        void Number(TabPage page, NumericUpDown box, string text, int top, int min, int max, int step, string key, string unit)
        {
            page.Controls.Add(new Label { Text = text, Left = 16, Top = top + 3, Width = 330 });
            box.Left = 350; box.Top = top; box.Width = 80; box.Minimum = min; box.Maximum = max; box.Increment = step;
            box.ValueChanged += delegate { if (!updating) app.SettingsCommand("set", "key", key, "value", (double)box.Value); };
            page.Controls.Add(box);
            page.Controls.Add(new Label { Text = unit, Left = 436, Top = top + 3, Width = 80 });
        }

        TabPage GeneralTab()
        {
            var page = new TabPage("一般");
            Check(page, autoBox, "エージェントの作業中はスリープさせない（自動モード）", 16, "autoEnabled");
            Check(page, loginBox, "ログイン時に起動", 44, "startAtLogin");
            page.Controls.Add(Note("エージェントの作業中は、蓋を閉じても PC は起きたままです（内蔵ディスプレイは Windows が消します）。全員があなたの返事待ちになると、蓋を閉じたときの動作（電源オプション）に従ってスリープします。「何もしない」なら起きたままです。終了すると通常のスリープに戻ります。", 76, 64));
            Number(page, batteryFloor, "バッテリーがこの値以下ならスリープを許可", 168, 0, 50, 5, "batteryFloorPercent", "%");
            page.Controls.Add(Note("Windows には macOS の熱状態に相当する API がないため、温度による制限はありません。", 200));
            return page;
        }

        TabPage TimingTab()
        {
            var page = new TabPage("タイミング");
            page.Controls.Add(new Label { Text = "作業が終わったとき", Left = 16, Top = 16, Width = 500, Font = new Font(Font, FontStyle.Bold) });
            Number(page, sleepGrace, "待機になってからスリープまで", 44, 0, 300, 5, "sleepGraceSeconds", "秒");
            Number(page, notifyTimeout, "Claude の通知を待つ最長時間", 76, 0, 300, 10, "notifyTimeoutSeconds", "秒");
            page.Controls.Add(Note("Claude Code は止まってから約 1 分後に「入力待ち」の通知を送ります。それを待つと、スリープ前に通知がスマートフォンに届きます。Codex にはこの待ち時間はありません。", 108, 48));
            page.Controls.Add(new Label { Text = "止まったセッション", Left = 16, Top = 168, Width = 500, Font = new Font(Font, FontStyle.Bold) });
            Number(page, workingStale, "作業中で報告がないセッションを無視するまで", 196, 5, 240, 5, "workingStaleMinutes", "分");
            Number(page, backgroundStale, "バックグラウンドだけのセッションを無視するまで", 228, 5, 480, 5, "backgroundStaleMinutes", "分");
            page.Controls.Add(Note("この時間だけ何も報告しないセッションは、クラッシュした可能性があるため PC を起こしておく対象から外します。", 260));
            var reset = new Button { Text = "初期設定に戻す", Left = 16, Top = 310, Width = 140 };
            reset.Click += delegate { app.SettingsCommand("restoreTimingDefaults"); };
            page.Controls.Add(reset);
            return page;
        }

        TabPage LimitsTab()
        {
            var page = new TabPage("使用量の上限");
            Check(page, wakeBox, "使用量のリセット前に PC をスリープ解除する", 16, "wakeForQuotaReset");
            page.Controls.Add(Note("Claude Code や Codex がサブスクリプションの上限で止まると、PC はスリープし、上限がリセットされる 2 分前にスリープ解除されるので、セッションを続けられます。", 44, 48));
            Check(page, switchBox, "使用上限で別のアカウントに切り替える (T3 Code)", 104, "switchAccountAtLimit");
            switchNote.Left = 16; switchNote.Top = 132; switchNote.Width = 510; switchNote.Height = 48; switchNote.ForeColor = SystemColors.GrayText;
            page.Controls.Add(switchNote);
            accountsLabel.Left = 16; accountsLabel.Top = 184; accountsLabel.Width = 510; accountsLabel.Height = 60;
            page.Controls.Add(accountsLabel);
            resumeBox.Text = "リセット後に自動で再開する (T3 Code の autoResumeLimitedThreads)";
            resumeBox.Left = 16; resumeBox.Top = 252; resumeBox.Width = 510;
            resumeBox.CheckedChanged += delegate { if (!updating) app.SettingsCommand("autoResume", "value", resumeBox.Checked); };
            page.Controls.Add(resumeBox);
            return page;
        }

        TabPage IntegrationsTab()
        {
            var page = new TabPage("連携");
            hookPanel.Left = 8; hookPanel.Top = 8; hookPanel.Width = 530; hookPanel.Height = 250;
            hookPanel.FlowDirection = FlowDirection.TopDown; hookPanel.WrapContents = false; hookPanel.AutoScroll = true;
            page.Controls.Add(hookPanel);
            var add = new Button { Text = "別のアカウントの設定フォルダを追加…", Left = 16, Top = 264, Width = 260 };
            add.Click += delegate
            {
                using (var dialog = new FolderBrowserDialog { Description = "CLAUDE_CONFIG_DIR として使っている Claude の設定フォルダ" })
                {
                    if (dialog.ShowDialog(this) == DialogResult.OK)
                        app.SettingsCommand("hooks", "action", "install", "tool", "claude", "path", Path.Combine(dialog.SelectedPath, "settings.json"));
                }
            };
            page.Controls.Add(add);
            t3Label.Left = 16; t3Label.Top = 300; t3Label.Width = 510; t3Label.Height = 40;
            page.Controls.Add(t3Label);
            powerLabel.Left = 16; powerLabel.Top = 344; powerLabel.Width = 510; powerLabel.Height = 40;
            page.Controls.Add(powerLabel);
            var log = new Button { Text = "ログを開く", Left = 16, Top = 392, Width = 100 };
            log.Click += delegate { app.OpenLog(); };
            var refresh = new Button { Text = "更新", Left = 124, Top = 392, Width = 100 };
            refresh.Click += delegate { app.SettingsCommand("refresh"); };
            page.Controls.Add(log);
            page.Controls.Add(refresh);
            return page;
        }

        static object Get(Dictionary<string, object> map, string key)
        {
            object value;
            return map != null && map.TryGetValue(key, out value) ? value : null;
        }

        static bool Bool(Dictionary<string, object> map, string key)
        {
            object value = Get(map, key);
            return value is bool && (bool)value;
        }

        static decimal Clamp(NumericUpDown box, object value)
        {
            decimal v = value == null ? box.Minimum : Convert.ToDecimal(value);
            return Math.Max(box.Minimum, Math.Min(box.Maximum, v));
        }

        /// For checking the layout without a screen: draws each tab of the window, filled from a
        /// status.json, into PNG files.
        public static int Render(string statusFile, string outputDir)
        {
            Application.EnableVisualStyles();
            var status = new JavaScriptSerializer().DeserializeObject(File.ReadAllText(statusFile, Encoding.UTF8)) as Dictionary<string, object>;
            using (var form = new SettingsForm(null))
            {
                form.StartPosition = FormStartPosition.Manual;
                form.Location = new Point(-5000, -5000);
                form.ShowInTaskbar = false;
                form.Show();
                form.Update(status);
                var tabs = (TabControl)form.Controls[0];
                for (int i = 0; i < tabs.TabCount; i++)
                {
                    tabs.SelectedIndex = i;
                    Application.DoEvents();
                    using (var bitmap = new Bitmap(form.Width, form.Height))
                    {
                        form.DrawToBitmap(bitmap, new Rectangle(0, 0, form.Width, form.Height));
                        bitmap.Save(Path.Combine(outputDir, "settings-" + i + ".png"), System.Drawing.Imaging.ImageFormat.Png);
                    }
                }
            }
            return 0;
        }

        public void Update(Dictionary<string, object> status)
        {
            updating = true;
            try
            {
                var s = Get(status, "settings") as Dictionary<string, object>;
                autoBox.Checked = Bool(s, "autoEnabled");
                loginBox.Checked = Bool(s, "startAtLogin");
                wakeBox.Checked = Bool(s, "wakeForQuotaReset");
                switchBox.Checked = Bool(s, "switchAccountAtLimit");
                if (!batteryFloor.Focused) batteryFloor.Value = Clamp(batteryFloor, Get(s, "batteryFloorPercent"));
                if (!sleepGrace.Focused) sleepGrace.Value = Clamp(sleepGrace, Get(s, "sleepGraceSeconds"));
                if (!notifyTimeout.Focused) notifyTimeout.Value = Clamp(notifyTimeout, Get(s, "notifyTimeoutSeconds"));
                if (!workingStale.Focused) workingStale.Value = Clamp(workingStale, Get(s, "workingStaleMinutes"));
                if (!backgroundStale.Focused) backgroundStale.Value = Clamp(backgroundStale, Get(s, "backgroundStaleMinutes"));
                string reason = Get(status, "switchUnavailableReason") as string;
                switchBox.Enabled = reason == null;
                switchNote.Text = reason ?? "ある会話が 1 つのアカウントの上限に達すると、リセットを待たずに同じツールの別のアカウントですぐに続けます。";
                accountsLabel.Text = (Get(status, "switchAccountsText") as string) ?? "";
                object auto = Get(status, "autoResume");
                resumeBox.Enabled = Bool(status, "t3Installed");
                resumeBox.Checked = auto is bool && (bool)auto;
                t3Label.Text = "T3 Code: " + ((Get(status, "t3Text") as string) ?? "");
                powerLabel.Text = "電源: " + ((Get(status, "powerText") as string) ?? "");
                UpdateHooks(Get(status, "integrations") as object[]);
            }
            finally { updating = false; }
        }

        void UpdateHooks(object[] files)
        {
            files = files ?? new object[0];
            string signature = new JavaScriptSerializer().Serialize(files);
            if (signature == hookSignature) return;
            hookSignature = signature;
            hookPanel.Controls.Clear();
            string currentTool = null;
            foreach (object item in files)
            {
                var file = item as Dictionary<string, object>;
                if (file == null) continue;
                string tool = Get(file, "tool") as string;
                if (tool != currentTool)
                {
                    currentTool = tool;
                    string installed = Bool(file, "toolInstalled") ? "" : "（見つかりません）";
                    hookPanel.Controls.Add(new Label { Text = (tool == "codex" ? "Codex" : "Claude Code") + installed, Width = 500, Height = 22, Font = new Font(Font, FontStyle.Bold), Padding = new Padding(0, 6, 0, 0) });
                }
                var row = new FlowLayoutPanel { Width = 510, Height = 32, FlowDirection = FlowDirection.LeftToRight, WrapContents = false };
                bool has = Bool(file, "hasHooks");
                string path = Get(file, "path") as string;
                row.Controls.Add(new Label { Text = (has ? "フックあり: " : "フックなし: ") + path, Width = 400, Height = 28, AutoEllipsis = true, TextAlign = ContentAlignment.MiddleLeft });
                var button = new Button { Text = has ? "削除" : "追加", Width = 80 };
                string toolName = tool;
                button.Click += delegate { app.SettingsCommand("hooks", "action", has ? "uninstall" : "install", "tool", toolName, "path", path); };
                row.Controls.Add(button);
                hookPanel.Controls.Add(row);
            }
            hookPanel.Controls.Add(new Label { Text = "フックを追加・変更したら、開いている Claude Code を再起動し、Codex では /hooks で信頼してください。", Width = 500, Height = 36, ForeColor = SystemColors.GrayText });
        }
    }
}
