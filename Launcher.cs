// TransparentApp 启动器：把内嵌的脚本和图标解到 %LOCALAPPDATA%\TransparentApp，再拉起 PowerShell 跑脚本。
// 由 build.ps1 用系统自带的 csc.exe 编成单个 exe，运行时不需要装 PowerShell 模块或 SDK。
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Threading;

static class Launcher
{
    const string MutexName = "TransparentApp.SingleInstance";

    static int Main()
    {
        bool created;
        using (var mutex = new Mutex(true, MutexName, out created))
        {
            if (!created) return 0;              // 已经有一个实例在跑，直接退出

            string dir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "TransparentApp");
            Directory.CreateDirectory(dir);

            string script = Path.Combine(dir, "TransparentApp.ps1");
            Extract("app.ps1", script);
            Extract("app.ico", Path.Combine(dir, "TransparentApp.ico"));

            var psi = new ProcessStartInfo();
            psi.FileName = "powershell.exe";
            psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + script + "\" -Detached";
            psi.WorkingDirectory = dir;
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;

            // 等子进程退出再释放互斥量，重复双击就不会开出第二个托盘图标。
            // 注意 CreateNoWindow 会让子进程带 SW_HIDE 启动，面板由脚本自己再 ShowWindow 一次补回来。
            using (var child = Process.Start(psi))
            {
                if (child != null) child.WaitForExit();
            }
            return 0;
        }
    }

    static void Extract(string suffix, string targetPath)
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
}
