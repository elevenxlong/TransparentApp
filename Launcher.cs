// TransparentApp 启动器：把内嵌脚本直接在本进程里跑完，不再往磁盘写 .ps1、也不再拉 powershell.exe 子进程。
// 旧的「释放脚本 + powershell -ExecutionPolicy Bypass」正是杀软判定释放器的那组特征，整条去掉。
// 由 build.ps1 用系统自带的 csc.exe 编成单个 exe，运行时不需要装 SDK。
using System;
using System.Diagnostics;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Reflection;
using System.Text;
using System.Threading;

static class Launcher
{
    const string MutexName = "TransparentApp.SingleInstance";
    const string WatchdogSwitch = "--watchdog";

    [STAThread]   // 脚本里的控制面板要在 STA 线程上跑 WinForms
    static int Main(string[] args)
    {
        // 必须先挂上解析器，再碰 PowerShell 的类型：RunScript 是被调用时才 JIT 的，
        // 那时解析器已经可用，SMA 就不依赖 GAC 注册了
        AppDomain.CurrentDomain.AssemblyResolve += ResolveHostAssemblies;

        int watchdogPid;
        if (IsWatchdog(args, out watchdogPid)) return RunScript(watchdogPid);

        bool created;
        using (var mutex = new Mutex(true, MutexName, out created))
        {
            if (!created)
            {
                // 已经有实例在跑：留张条子让它把面板调出来，别再开第二个托盘图标
                RequestShowPanel();
                return 0;
            }
            return RunScript(0);
        }
    }

    static bool IsWatchdog(string[] args, out int mainPid)
    {
        mainPid = 0;
        if (args == null || args.Length < 2) return false;
        if (!string.Equals(args[0], WatchdogSwitch, StringComparison.OrdinalIgnoreCase)) return false;
        return int.TryParse(args[1], out mainPid);
    }

    static int RunScript(int watchdogPid)
    {
        string exe = Assembly.GetExecutingAssembly().Location;

        string dir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "TransparentApp");
        Directory.CreateDirectory(dir);

        // 只解一个图标出来给托盘和任务栏用；脚本本身留在 exe 里，不落盘
        string icon = Path.Combine(dir, "TransparentApp.ico");
        ExtractResource("app.ico", icon);

        string script = ReadResourceText("app.ps1");
        if (script == null)
        {
            Log("内嵌脚本 app.ps1 缺失，无法启动");
            return 1;
        }

        try
        {
            using (var runspace = RunspaceFactory.CreateRunspace())
            {
                runspace.Open();
                // 脚本靠这几个变量区分「被 exe 宿主」和「直接跑 .ps1」
                runspace.SessionStateProxy.SetVariable("Hosted", true);
                runspace.SessionStateProxy.SetVariable("HostedExe", exe);
                runspace.SessionStateProxy.SetVariable("HostedIconPath", icon);
                runspace.SessionStateProxy.SetVariable("HostedWatchdog", watchdogPid);

                using (var ps = PowerShell.Create())
                {
                    ps.Runspace = runspace;
                    ps.AddScript(script);
                    ps.Invoke();

                    // 脚本自己会兜异常，这里只把真实报错留一份到 host.log 方便排查
                    foreach (var err in ps.Streams.Error) Log(err.ToString());
                }
            }
            return 0;
        }
        catch (Exception ex)
        {
            Log(ex.ToString());
            return 1;
        }
    }

    // 脚本的轮询会来看这个文件；写进去就等于「把面板叫出来」
    static void RequestShowPanel()
    {
        try
        {
            string dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "TransparentApp");
            Directory.CreateDirectory(dir);
            File.WriteAllText(
                Path.Combine(dir, "show.request"),
                Process.GetCurrentProcess().Id.ToString(),
                new UTF8Encoding(false));
        }
        catch { }
    }

    // System.Management.Automation 装在 Windows PowerShell 5.1 目录里，不保证能从 GAC 直接解析
    static Assembly ResolveHostAssemblies(object sender, ResolveEventArgs e)
    {
        if (e.Name == null) return null;
        if (!e.Name.StartsWith("System.Management.Automation", StringComparison.OrdinalIgnoreCase)) return null;
        string path = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.System),
            @"WindowsPowerShell\v1.0\System.Management.Automation.dll");
        return File.Exists(path) ? Assembly.LoadFrom(path) : null;
    }

    static void ExtractResource(string suffix, string targetPath)
    {
        var asm = Assembly.GetExecutingAssembly();
        foreach (string name in asm.GetManifestResourceNames())
        {
            if (!name.EndsWith(suffix, StringComparison.OrdinalIgnoreCase)) continue;
            using (var src = asm.GetManifestResourceStream(name))
            using (var dst = new FileStream(targetPath, FileMode.Create, FileAccess.Write))
            {
                src.CopyTo(dst);
            }
            return;
        }
    }

    static string ReadResourceText(string suffix)
    {
        var asm = Assembly.GetExecutingAssembly();
        foreach (string name in asm.GetManifestResourceNames())
        {
            if (!name.EndsWith(suffix, StringComparison.OrdinalIgnoreCase)) continue;
            using (var src = asm.GetManifestResourceStream(name))
            // 脚本带 UTF-8 BOM，交给 StreamReader 丢掉，否则 PowerShell 会把它当成正文头一个字符
            using (var reader = new StreamReader(src, Encoding.UTF8, true))
            {
                return reader.ReadToEnd();
            }
        }
        return null;
    }

    static void Log(string text)
    {
        try
        {
            string dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "TransparentApp");
            Directory.CreateDirectory(dir);
            File.AppendAllText(
                Path.Combine(dir, "host.log"),
                DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " " + text + Environment.NewLine,
                new UTF8Encoding(false));
        }
        catch { }
    }
}
