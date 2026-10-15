using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

public static class Win {
    delegate bool EnumProc(IntPtr h, IntPtr p);

    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowTextLengthW(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    // 用 GetWindowLongPtrW：仅在 64 位进程存在，所以原型只支持 64 位 PowerShell
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] static extern IntPtr GetWindowLongPtr(IntPtr h, int i);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] static extern IntPtr SetWindowLongPtr(IntPtr h, int i, IntPtr v);
    [DllImport("user32.dll")] static extern bool SetLayeredWindowAttributes(IntPtr h, uint key, byte alpha, uint flags);
    [DllImport("user32.dll")] static extern bool GetLayeredWindowAttributes(IntPtr h, out uint key, out byte alpha, out uint flags);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(POINT p);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr SendMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern int SetCurrentProcessExplicitAppUserModelID(string appId);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr h, uint flags);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint cmd);

    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }

    const int GWL_EXSTYLE = -20;
    const long WS_EX_LAYERED = 0x00080000;
    const long WS_EX_TOOLWINDOW = 0x00000080;
    const uint LWA_ALPHA = 0x2;

    public static List<IntPtr> Windows() {
        var list = new List<IntPtr>();
        EnumWindows(delegate(IntPtr h, IntPtr p) {
            if (!IsWindowVisible(h)) return true;
            if (GetWindowTextLengthW(h) == 0) return true;
            if ((GetWindowLongPtr(h, GWL_EXSTYLE).ToInt64() & WS_EX_TOOLWINDOW) != 0) return true;
            list.Add(h);
            return true;
        }, IntPtr.Zero);
        return list;
    }

    public static string Title(IntPtr h) {
        var sb = new StringBuilder(GetWindowTextLengthW(h) + 1);
        GetWindowTextW(h, sb, sb.Capacity);
        return sb.ToString();
    }

    public static string Class(IntPtr h) {
        var sb = new StringBuilder(256);
        GetClassNameW(h, sb, sb.Capacity);
        return sb.ToString();
    }

    public static bool IsTool(IntPtr h) {
        return (GetWindowLongPtr(h, GWL_EXSTYLE).ToInt64() & WS_EX_TOOLWINDOW) != 0;
    }

    public static uint Pid(IntPtr h) { uint p; GetWindowThreadProcessId(h, out p); return p; }

    // 进程名查一次要几毫秒，而轮询要频繁重扫窗口，所以带 10 秒 TTL 的缓存。
    // 留 TTL 是为了兜住 pid 复用：过期后重新解析，不会一直用旧名字。
    class NameEntry { public string Name; public DateTime At; }
    static Dictionary<uint, NameEntry> _names = new Dictionary<uint, NameEntry>();
    public static string Proc(IntPtr h) {
        uint pid = Pid(h);
        NameEntry e;
        if (_names.TryGetValue(pid, out e) && (DateTime.UtcNow - e.At).TotalSeconds < 10) return e.Name;
        string name;
        try { name = Process.GetProcessById((int)pid).ProcessName; } catch { name = pid.ToString(); }
        _names[pid] = new NameEntry { Name = name, At = DateTime.UtcNow };
        return name;
    }

    /// 所有可见顶层窗口，不带「必须有标题」「不是工具窗口」的过滤：
    /// 派生窗口（微信表情面板、Chrome 的弹出层）往往没标题、还带 WS_EX_TOOLWINDOW
    public static List<IntPtr> AllTopLevel() {
        var list = new List<IntPtr>();
        EnumWindows(delegate(IntPtr h, IntPtr p) {
            if (IsWindowVisible(h)) list.Add(h);
            return true;
        }, IntPtr.Zero);
        return list;
    }

    /// 属主窗口：弹窗/对话框靠它挂在主窗口上
    public static IntPtr Owner(IntPtr h) { return GetWindow(h, 4); }   // GW_OWNER

    public static bool HasLayered(IntPtr h) {
        return (GetWindowLongPtr(h, GWL_EXSTYLE).ToInt64() & WS_EX_LAYERED) != 0;
    }

    // none = 没分层；lwa = 用 SetLayeredWindowAttributes（我们这种统一 alpha）；
    // perpixel = 用 UpdateLayeredWindow 自己画（Qt 弹窗、圆角/阴影窗口都是这种）
    public static string LayeredMode(IntPtr h) {
        if (!HasLayered(h)) return "none";
        uint key, flags; byte a;
        return GetLayeredWindowAttributes(h, out key, out a, out flags) ? "lwa" : "perpixel";
    }

    /// WS_EX_NOREDIRECTIONBITMAP：窗口自己没有重定向位图（DComp/DXGI 直出），统一 alpha 对它没意义
    public static bool NoRedirectionBitmap(IntPtr h) {
        return (GetWindowLongPtr(h, GWL_EXSTYLE).ToInt64() & 0x00200000L) != 0;
    }

    /// 当前实际生效的 alpha；窗口没有 layered 时返回 -1
    public static int GetAlpha(IntPtr h) {
        uint key, flags; byte alpha;
        if (!GetLayeredWindowAttributes(h, out key, out alpha, out flags)) return -1;
        return alpha;
    }

    // 100% 时清掉 WS_EX_LAYERED，让窗口拿回 DWM 硬件合成（Chrome 被 layered 后容易掉帧）
    // ponytail: 无条件清除会覆盖目标窗口原有的 layered 标志，原型接受
    public static bool SetAlpha(IntPtr h, int alpha) {
        long ex = GetWindowLongPtr(h, GWL_EXSTYLE).ToInt64();
        if (alpha >= 255) { SetWindowLongPtr(h, GWL_EXSTYLE, (IntPtr)(ex & ~WS_EX_LAYERED)); return true; }
        SetWindowLongPtr(h, GWL_EXSTYLE, (IntPtr)(ex | WS_EX_LAYERED));
        return SetLayeredWindowAttributes(h, 0, (byte)alpha, LWA_ALPHA);
    }

    public static bool Alive(IntPtr h) { return IsWindow(h); }

    /// 宿主进程是 powershell.exe，任务栏默认拿它的图标；显式指定 AppUserModelID 后才会用窗口自己的图标
    public static int SetAppId(string id) {
        try { return SetCurrentProcessExplicitAppUserModelID(id); } catch { return -1; }
    }

    /// WM_GETICON + ICON_BIG：拿窗口自己设的大图标句柄，用来确认不是宿主进程的图标
    public static IntPtr GetWindowIcon(IntPtr h) { return SendMessage(h, 0x7F, (IntPtr)1, IntPtr.Zero); }

    /// 异步发 WM_CLOSE，等于点了这个窗口的 ×。
    /// 用 Post 不用 Send：程序弹「要保存吗」时 Send 会把我们的界面线程一起卡住
    public static bool PostClose(IntPtr h) { return PostMessage(h, 0x0010, IntPtr.Zero, IntPtr.Zero); }
    public static bool Minimized(IntPtr h) { return IsIconic(h); }
    public static void Minimize(IntPtr h) { ShowWindow(h, 6); }
    public static void Restore(IntPtr h) { ShowWindow(h, 9); }
    public static bool Visible(IntPtr h) { return IsWindowVisible(h); }
    // 启动时若带了 STARTUPINFO.wShowWindow=SW_HIDE，第一次 ShowWindow 会被吃掉，得再补一次
    public static void ShowIt(IntPtr h) {
        ShowWindow(h, 9);
        ShowWindow(h, 5);
        BringWindowToTop(h);
        SetForegroundWindow(h);
    }

    public static bool Rect(IntPtr h, out int l, out int t, out int r, out int b) {
        RECT rc; bool ok = GetWindowRect(h, out rc);
        l = rc.Left; t = rc.Top; r = rc.Right; b = rc.Bottom; return ok;
    }

    public static bool Cursor(out int x, out int y) {
        POINT p; bool ok = GetCursorPos(out p); x = p.X; y = p.Y; return ok;
    }

    public static IntPtr WindowAt(int x, int y) {
        var p = new POINT(); p.X = x; p.Y = y;
        return WindowFromPoint(p);
    }

    /// 光标下那个窗口所属的顶层窗口，用来和受管窗口比身份
    public static IntPtr RootOf(IntPtr h) {
        return h == IntPtr.Zero ? IntPtr.Zero : GetAncestor(h, 2);   // GA_ROOT
    }

    /// a 是否压在 b 上面：沿 z 序从 b 往上走，能碰到 a 就是
    public static bool Above(IntPtr a, IntPtr b) {
        if (a == IntPtr.Zero || b == IntPtr.Zero) return false;
        IntPtr cur = b;
        for (int i = 0; i < 4096 && cur != IntPtr.Zero; i++) {
            if (cur == a) return true;
            cur = GetWindow(cur, 3);   // GW_HWNDPREV
        }
        return false;
    }
}
