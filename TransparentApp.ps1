#requires -version 5.1
<#
TransparentApp 原型（Windows 单文件、零依赖，系统自带 PowerShell 5.1 + WinForms）
- 控制面板：拖滑块实时改透明度、选延迟、勾选目标窗口
- 隐身模式：光标不在目标窗口内时完全透明（alpha 0），移进去才显示
- 鼠标离开目标窗口超过设定时间自动最小化；面板里一键还原
- 点 X 只是把面板收回托盘，程序继续跑；真正退出（托盘右键 / 面板按钮）会先还原透明度和最小化状态

用法：
  powershell -ExecutionPolicy Bypass -File .\TransparentApp.ps1
自检（无 UI；会短暂改动一个窗口的透明度）：
  powershell -ExecutionPolicy Bypass -File .\TransparentApp.ps1 -SelfTest
#>
param([switch]$SelfTest, [switch]$Detached, [switch]$UiTest, [switch]$Restore, [switch]$RestoreAll, [int]$Watchdog = 0)

# 消息循环会一直占着控制台，表现就是「命令卡住、没有入口」。默认甩到后台跑，
# 终端立刻回到提示符；真正干活的进程带 -Detached，不再重复分叉。
if (-not $Detached -and -not $SelfTest -and -not $UiTest -and -not $Restore -and -not $RestoreAll -and $Watchdog -eq 0) {
    # -WindowStyle Hidden 只压控制台；但它把 STARTUPINFO.wShowWindow 设成 SW_HIDE，
    # 子进程第一次 ShowWindow 会把控制面板一起隐藏掉，表现为「进程活着但看不到面板」
    # （走 CreateNoWindow 能绕开这点，但子进程会挂在调用方终端上，命令看起来像没返回）。
    # 所以这里照常用 Hidden，由子进程在 Shown 里补一次 ShowWindow 把面板显示出来。
    Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass',
        '-File', "`"$PSCommandPath`"", '-Detached' -WindowStyle Hidden
    Write-Host "TransparentApp 已启动，控制面板窗口在屏幕上（最小化后用托盘图标叫回来）。"
    return
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
# 必须在创建任何控件之前调用，否则滑块/复选框拿不到原生视觉样式
[System.Windows.Forms.Application]::EnableVisualStyles()

if (-not ("Win" -as [type])) {
Add-Type -TypeDefinition @'
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

    /// 光标下最深层窗口所属进程；用来判断「光标还在同一个应用里」
    public static uint PidAt(int x, int y) {
        var p = new POINT(); p.X = x; p.Y = y;
        IntPtr h = WindowFromPoint(p);
        return h == IntPtr.Zero ? 0 : Pid(h);
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
'@
}

# -Watchdog <主进程pid>：跟着主进程跑，主进程异常退出时把窗口恢复原样。
# 正常退出会把状态文件删掉，所以醒来还看到文件就说明是异常退出（被强杀 / 崩溃）。
if ($Watchdog -gt 0) {
    $livePath = Join-Path $env:APPDATA 'TransparentApp\live.json'
    try { Wait-Process -Id $Watchdog -ErrorAction SilentlyContinue } catch { }
    Start-Sleep -Milliseconds 500   # 留点时间给「正常退出」那一步先把状态文件删掉
    if (Test-Path -LiteralPath $livePath) {
        $n = 0; $m = 0
        try {
            $st = Get-Content -Raw -Encoding UTF8 -LiteralPath $livePath | ConvertFrom-Json
            if ([int]$st.pid -eq $Watchdog) {
                foreach ($v in @($st.windows)) {
                    $h = [IntPtr][int64]$v
                    # 只还原「统一 alpha 模式」的窗口：逐像素分层的窗口本来就不该动
                    if ([Win]::Alive($h) -and [Win]::GetAlpha($h) -ge 0) { [Win]::SetAlpha($h, 255) | Out-Null; $n++ }
                }
                foreach ($v in @($st.minimized)) {
                    $h = [IntPtr][int64]$v
                    if ([Win]::Alive($h)) { [Win]::Restore($h); $m++ }
                }
            }
        } catch { }
        [System.IO.File]::Delete($livePath)
        try {
            $logPath = Join-Path $env:APPDATA 'TransparentApp\recovery.log'
            $msg = "{0:yyyy-MM-dd HH:mm:ss} 主进程 {1} 异常退出，已还原 {2} 个窗口的透明度、{3} 个最小化窗口" -f (Get-Date), $Watchdog, $n, $m
            Add-Content -LiteralPath $logPath -Value $msg -Encoding UTF8
        } catch { }
    }
    return
}

# 任务栏图标：宿主进程是 powershell.exe，不显式指定 AppUserModelID 的话
# 任务栏会一直拿宿主进程的图标（那个蓝色 PowerShell 图标），窗口自己设的 Icon 不生效
$script:appIdResult = [Win]::SetAppId("TransparentApp.Panel")

# 是否该最小化。$last 为空表示「还没确认光标进过这个窗口」，此时不参与最小化；
# 窗口从最小化恢复后由调用方清空 $last，效果就是「光标得先进来一次才会重新计时」
function Test-Leave($last, $now, [int]$delayMs) {
    if (-not $last) { return $false }
    return (($now - $last).TotalMilliseconds -gt $delayMs)
}

# 下拉文案；直接写秒数会出现「300 秒」这种读不出来的选项
function Format-Delay([int]$ms) {
    if ($ms -ge 60000) { return "{0} 分钟" -f ($ms / 60000) }
    if ($ms -ge 1000) { return "{0} 秒" -f ($ms / 1000) }
    return "{0} 毫秒" -f $ms
}

$PollMs = 200
$DelayOptions = @(
    @{ ms = 1000;    text = "1 秒" },
    @{ ms = 2000;    text = "2 秒" },
    @{ ms = 5000;    text = "5 秒" },
    @{ ms = 30000;   text = "30 秒" },
    @{ ms = 60000;   text = "1 分钟" },
    @{ ms = 120000;  text = "2 分钟" },
    @{ ms = 300000;  text = "5 分钟" },
    @{ ms = 600000;  text = "10 分钟" },
    @{ ms = 1800000; text = "30 分钟" }
)
# 鼠标移开超过设定时间后干什么。close = 关掉这个窗口和它的派生窗口（不碰同程序的其它窗口）
$ActionOptions = @(
    @{ id = 'none';     text = "不做任何事" },
    @{ id = 'minimize'; text = "最小化窗口" },
    @{ id = 'close';    text = "关闭窗口" }
)

# 每个目标窗口一份配置：窗口句柄 -> @{ alpha; stealth; action; leaveMs }
$script:targets    = [ordered]@{}
$script:selected   = $null   # 列表里选中的窗口；下面那些控件编辑的就是它
$script:follow     = $true   # 连这个窗口派生出来的窗口（弹窗/无标题窗口）一起作用
$script:minimized  = New-Object System.Collections.Generic.List[System.IntPtr]  # 被本程序最小化的窗口，退出/还原时恢复
$script:lastIn     = @{}     # 窗口句柄 -> 最后一次确认光标在该窗口组内的时间
$script:wasMin     = @{}     # 窗口句柄 -> 上一轮是否最小化，用来识别「刚被还原」
$script:applied    = @{}     # 句柄 -> 上次真正设下去的 alpha，避免每轮都重复调 API
$script:insideCache = @{}    # 句柄 -> 上一轮光标是否在该窗口内
$script:origLayered = @{}    # 句柄 -> 我们动手前的分层状态（退出时照着还原）
$script:skipWin     = @{}    # 句柄 -> 不碰（自己就在做分层透明的窗口）
$script:group      = @{}     # 目标窗口句柄 -> 它自己 + 派生窗口（这一组一起受这份配置管）
$script:candidates = @()     # 当前可当目标的窗口（有标题、非工具窗口的主窗口）
$script:closeAsked = @{}     # 已经请求过关窗的目标，避免每轮轮询重复发 WM_CLOSE
$script:procDefaults = @{}   # 进程名 -> 上次给它用过的配置，新勾同程序的窗口时拿来做初值
$script:scanAt     = [DateTime]::MinValue
$script:cfgRestored = $false # 上次的目标窗口只在启动后找一次
$script:savedTargets = @()   # 配置里读出来的窗口指纹，启动后按它把窗口找回来
$script:pendingProcs  = @()  # 旧格式只记了进程名，退化成「给它第一个主窗口」
$script:uiInit     = $false  # 程序化设置控件时抑制事件，否则初始化会把用户设置冲掉
$script:uiProbe    = [IntPtr]::Zero
$script:reallyExit = $false  # 只有它才允许窗口真正关闭，否则点 X 只是收回托盘
$script:hintedTray = $false
$script:cfgDirty   = $false
$script:suppressHide = $false   # 程序化显示面板时，别让「最小化就隐藏」的逻辑插一脚
$StealthAlpha = 0    # 隐身时的 alpha：完全不可见（分层窗口同时不再接收鼠标点击）
$DefaultCfg = @{ alpha = 200; stealth = $false; action = 'minimize'; leaveMs = 300000 }
$WindowCacheMs = 1000   # 重扫窗口的间隔；枚举本身便宜、进程名查询有缓存，1 秒足够跟上新开的弹窗
$script:ownProc = [System.Diagnostics.Process]::GetCurrentProcess().ProcessName   # 别把自己的面板也管进去

# 配置写 %APPDATA%：脚本/exe 可能放在只读目录，不能指望往自己身边写
$ConfigPath = Join-Path $env:APPDATA 'TransparentApp\config.json'
if ($SelfTest) { $ConfigPath = $null }   # 自检自己造临时文件，别把用户配置冲掉
if ($UiTest) {
    $ConfigPath = Join-Path $env:TEMP 'TransparentApp-uitest.json'
    # 上次测试的残留会让这次的结果不可复现，先删掉
    if (Test-Path $ConfigPath) { Remove-Item -LiteralPath $ConfigPath -Force }
}
# 崩溃时留给看门狗的现场：当前被我改过的窗口句柄。正常退出会把它删掉
$LivePath = Join-Path $env:APPDATA 'TransparentApp\live.json'
if ($SelfTest -or $UiTest -or $Restore -or $RestoreAll) { $LivePath = $null }
# 面板什么时候显示/隐藏、因为什么，写在这里。以后再出现「自己弹出来」直接看这个文件
$UiLogPath = Join-Path $env:APPDATA 'TransparentApp\ui.log'
if ($SelfTest -or $UiTest -or $Restore -or $RestoreAll) { $UiLogPath = $null }
$ShowRequestPath = Join-Path $env:APPDATA 'TransparentApp\show.request'
$script:liveSig = ''
function Save-Config {
    if (-not $ConfigPath) { return }
    # 窗口句柄活不过重启，所以任务按「进程名|窗口类|标题」记；标题变了就认不回来（Chrome 换了标签页就是这种）
    $list = @()
    foreach ($h in @($script:targets.Keys)) {
        if (-not [Win]::Alive($h)) { continue }
        $t = $script:targets[$h]
        $list += [ordered]@{
            proc = [Win]::Proc($h); class = [Win]::Class($h); title = [Win]::Title($h)
            alpha = [int]$t.alpha; stealth = [bool]$t.stealth; action = "$($t.action)"; leaveMs = [int]$t.leaveMs
        }
    }
    $cfg = [ordered]@{ follow = $script:follow; targets = $list; procDefaults = [ordered]@{} }
    foreach ($name in @($script:procDefaults.Keys)) { $cfg.procDefaults[$name] = $script:procDefaults[$name] }
    try {
        $dir = Split-Path $ConfigPath
        if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        [System.IO.File]::WriteAllText($ConfigPath, ($cfg | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

# 从任意形状的配置片段里读出一份窗口配置（兼容旧字段 minimize / autoMin）
function ConvertTo-TargetCfg($src) {
    $c = @{ alpha = $DefaultCfg.alpha; stealth = $DefaultCfg.stealth; action = $DefaultCfg.action; leaveMs = $DefaultCfg.leaveMs }
    if ($null -ne $src.alpha) { $c.alpha = [int]$src.alpha }
    if ($null -ne $src.stealth) { $c.stealth = [bool]$src.stealth }
    if ($null -ne $src.leaveMs) { $c.leaveMs = [int]$src.leaveMs }
    if ($null -ne $src.action -and ("$($src.action)" -in @('none', 'minimize', 'close', 'kill'))) {
        # 早期版本这一档的 id 是 kill（当时是结束整个进程），现在改成只关窗口
        $c.action = if ("$($src.action)" -eq 'kill') { 'close' } else { "$($src.action)" }
    } elseif ($null -ne $src.minimize) {
        $c.action = if ([bool]$src.minimize) { 'minimize' } else { 'none' }
    } elseif ($null -ne $src.autoMin) {
        $c.action = if ([bool]$src.autoMin) { 'minimize' } else { 'none' }
    }
    return $c
}

function Load-Config {
    if (-not $ConfigPath -or -not (Test-Path $ConfigPath)) { return }
    try {
        $cfg = Get-Content -Raw -Encoding UTF8 $ConfigPath | ConvertFrom-Json
        if ($null -ne $cfg.follow) { $script:follow = [bool]$cfg.follow }
        if ($null -ne $cfg.procDefaults) {
            foreach ($p in $cfg.procDefaults.PSObject.Properties) { $script:procDefaults[$p.Name] = ConvertTo-TargetCfg $p.Value }
        }
        if ($null -eq $cfg.targets) { return }
        if ($cfg.targets -is [System.Management.Automation.PSCustomObject]) {
            # v2 格式：进程名 -> 配置。升级成「该进程的第一个主窗口」，值同时留作该进程的默认值
            foreach ($p in $cfg.targets.PSObject.Properties) {
                $c = ConvertTo-TargetCfg $p.Value
                $script:procDefaults[$p.Name] = $c
                $script:pendingProcs += [pscustomobject]@{ proc = $p.Name; cfg = $c }
            }
        } else {
            foreach ($s in @($cfg.targets)) {
                if ($s -is [string]) {
                    # v1 格式：进程名数组 + 全局配置
                    $script:pendingProcs += [pscustomobject]@{ proc = [string]$s; cfg = (ConvertTo-TargetCfg $cfg) }
                } elseif ($null -ne $s.proc) {
                    $script:savedTargets += [pscustomobject]@{ proc = $s.proc; class = $s.class; title = $s.title; cfg = (ConvertTo-TargetCfg $s) }
                }
            }
        }
    } catch {
        Write-Host "配置读取失败，用默认值：$($_.Exception.Message)"
    }
}

Load-Config

# 被任务管理器强杀、或崩在还原之前，窗口会留在透明状态。这条路径专门用来收尾：
#   powershell -ExecutionPolicy Bypass -File .\TransparentApp.ps1 -Restore
if ($RestoreAll) {
    # 核选项：配置丢了也能用——把所有「被显式设过 alpha 且不是 255」的窗口恢复原样。
    # 只认 GetLayeredWindowAttributes 能读出 alpha 的窗口，自己用 UpdateLayeredWindow 画图的窗口不动
    $n = 0
    $hit = @()
    foreach ($h in @([Win]::AllTopLevel())) {
        $a = [Win]::GetAlpha($h)
        if ($a -lt 0 -or $a -ge 255) { continue }
        [Win]::SetAlpha($h, 255) | Out-Null
        $n++
        $hit += ("  {0} - {1}（alpha 曾是 {2}）" -f [Win]::Proc($h), [Win]::Title($h), $a)
    }
    Write-Host ("已把 {0} 个被调过透明度的窗口恢复正常：" -f $n)
    foreach ($x in $hit) { Write-Host $x }
    return
}

if ($Restore) {
    $names = @($script:procDefaults.Keys)
    foreach ($s in @($script:savedTargets)) {
        if ($s.proc -and ($names -notcontains $s.proc)) { $names += $s.proc }
    }
    if ($names.Count -eq 0) {
        Write-Host "配置里没记过目标窗口，无法判断哪些窗口是残留；先正常跑一次让它记住目标。"
        return
    }
    $n = 0
    foreach ($procName in $names) {
        foreach ($h in @([Win]::AllTopLevel())) {
            if ([Win]::Proc($h) -eq $procName) { [Win]::SetAlpha($h, 255) | Out-Null; $n++ }
        }
    }
    Write-Host ("已把 {0} 个窗口恢复正常（涉及进程：{1}）" -f $n, ($names -join ', '))
    return
}

# 启动时如果发现上一次跑留下的现场文件，说明上次是异常退出（而且看门狗大概也被一起杀了），先补一刀
if ($LivePath -and (Test-Path -LiteralPath $LivePath)) {
    try {
        $st = Get-Content -Raw -Encoding UTF8 -LiteralPath $LivePath | ConvertFrom-Json
        if ($null -ne $st.pid -and [int]$st.pid -ne $PID) {
            $n = 0
            foreach ($v in @($st.windows)) {
                $h = [IntPtr][int64]$v
                # 只还原「统一 alpha 模式」的窗口：逐像素分层的窗口本来就不该动
                if ([Win]::Alive($h) -and [Win]::GetAlpha($h) -ge 0) { [Win]::SetAlpha($h, 255) | Out-Null; $n++ }
            }
            foreach ($v in @($st.minimized)) {
                $h = [IntPtr][int64]$v
                if ([Win]::Alive($h)) { [Win]::Restore($h) }
            }
            if ($n -gt 0) { Write-Host ("上次异常退出，启动时先还原了 {0} 个窗口。" -f $n) }
        }
        [System.IO.File]::Delete($LivePath)
    } catch { }
}

# 窗口的可识别指纹：进程名 + 窗口类 + 标题。句柄活不过重启，只能靠它把上次的目标找回来
function Get-WindowKey([IntPtr]$h) {
    return "{0}|{1}|{2}" -f [Win]::Proc($h), [Win]::Class($h), [Win]::Title($h)
}

# 标题里可能夹着零宽字符/控制符（Chrome 标签页就有），原样塞进 CheckedListBox 会抛 GDI+ 错误
function Get-SafeLabel([IntPtr]$h) {
    $raw = "{0} - {1}" -f [Win]::Proc($h), [Win]::Title($h)
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $raw.ToCharArray()) {
        $cat = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch)
        if ($cat -eq [System.Globalization.UnicodeCategory]::Control -or
            $cat -eq [System.Globalization.UnicodeCategory]::Format -or
            $cat -eq [System.Globalization.UnicodeCategory]::Surrogate -or
            $cat -eq [System.Globalization.UnicodeCategory]::OtherNotAssigned) { continue }
        [void]$sb.Append($ch)
    }
    $s = $sb.ToString().Trim()
    if ($s.Length -eq 0) { $s = "(无标题)" }
    # 列表只有 356px 宽，标题太长会被截断，干脆自己先截，省得看着像乱码
    if ($s.Length -gt 40) { $s = $s.Substring(0, 40) + "…" }
    return $s
}

# 重扫窗口：挑出能当目标的主窗口（有标题、非工具窗口），再给每个目标算出它这一组。
# 派生窗口（微信表情面板、Chrome 弹出层）都是无标题或工具窗口，自己当不了目标，只能挂在某个目标下面
function Scan-Windows {
    $cands = @()
    $deps = @()
    foreach ($h in @([Win]::AllTopLevel())) {
        if ([Win]::Proc($h) -eq $script:ownProc) { continue }   # 别把自己的面板卷进去
        if ([Win]::Title($h).Length -eq 0 -or [Win]::IsTool($h)) { $deps += $h } else { $cands += $h }
    }
    $script:candidates = $cands

    $g = @{}
    foreach ($h in @($script:targets.Keys)) {
        if ([Win]::Alive($h)) {
            $g[$h] = New-Object System.Collections.ArrayList
            [void]$g[$h].Add($h)
        }
    }
    if ($script:follow) {
        foreach ($w in @($deps)) {
            $owner = [Win]::RootOf([Win]::Owner($w))
            if ($owner -ne [IntPtr]::Zero -and $g.ContainsKey($owner)) { [void]$g[$owner].Add($w); continue }
            # 没有属主可依（微信表情面板就是这种）：同进程下只挂了一个目标窗口时归它
            $same = @($g.Keys | Where-Object { [Win]::Alive($_) -and [Win]::Pid($_) -eq [Win]::Pid($w) })
            if ($same.Count -eq 1) { [void]$g[$same[0]].Add($w) }
        }
        foreach ($w in @($cands)) {
            if ($g.ContainsKey($w)) { continue }
            $owner = [Win]::RootOf([Win]::Owner($w))
            if ($owner -ne [IntPtr]::Zero -and $g.ContainsKey($owner)) { [void]$g[$owner].Add($w) }
        }
    }
    $script:group = $g
    $script:scanAt = Get-Date
}

# 这个目标窗口这一组实际要管的窗口（它自己 + 派生窗口）
function Get-Group([IntPtr]$h) {
    if ($script:group.ContainsKey($h)) { return @($script:group[$h]) }
    return @($h)
}

# 启动后按指纹把上次的目标窗口找回来
function Restore-SavedTargets {
    $script:cfgRestored = $true
    foreach ($s in @($script:savedTargets)) {
        $key = "{0}|{1}|{2}" -f $s.proc, $s.class, $s.title
        foreach ($h in @($script:candidates)) {
            if ($script:targets.Contains($h)) { continue }
            if ((Get-WindowKey $h) -eq $key) { $script:targets[$h] = $s.cfg; break }
        }
    }
    foreach ($p in @($script:pendingProcs)) {
        foreach ($h in @($script:candidates)) {
            if ([Win]::Proc($h) -ne $p.proc) { continue }
            if ($script:targets.Contains($h)) { continue }
            $script:targets[$h] = $p.cfg
            break
        }
    }
    $script:savedTargets = @()
    $script:pendingProcs = @()
}

# 这个窗口现在该是多透明：该程序开了隐身、光标又不在它的窗口上 -> StealthAlpha
function Get-WantAlpha($cfg, [bool]$inside) {
    if ($cfg.stealth -and -not $inside) { return $StealthAlpha }
    return [int]$cfg.alpha
}

# 唯一的下发点：算出目标值，变了才调 API（有些程序重绘后会丢 WS_EX_LAYERED，那种也要补一次）
function Set-TargetAlpha([IntPtr]$h, $cfg, [bool]$inside) {
    # 动手前先记住它本来是什么分层状态，退出时按原样还回去
    if (-not $script:origLayered.ContainsKey($h)) {
        $mode = [Win]::LayeredMode($h)
        $script:origLayered[$h] = @{ mode = $mode; alpha = [Win]::GetAlpha($h) }
        if ($mode -ne 'none' -or [Win]::NoRedirectionBitmap($h)) {
            # 它自己就在做透明（Qt 弹窗那种逐像素分层），套统一 alpha 会让它整块变黑 —— 宁可它不透明，
            # 也不能让它画不出来。这类窗口直接跳过，连退出还原都不碰
            $script:skipWin[$h] = $true
            Write-UiLog ("跳过 0x{0:X}（{1} - {2}）：它自己用分层透明，改成统一透明度会让它变黑" -f $h.ToInt64(), [Win]::Proc($h), [Win]::Title($h))
        }
    }
    if ($script:skipWin.ContainsKey($h)) { return }

    $want = Get-WantAlpha $cfg $inside
    if ($script:applied[$h] -ne $want -or ($want -lt 255 -and -not [Win]::HasLayered($h))) {
        [Win]::SetAlpha($h, $want) | Out-Null
        $script:applied[$h] = $want
        # 立刻更新现场文件，别等轮询：这中间的 200ms 正好崩了就没人知道动过这个窗口
        Save-LiveState
    }
}

# 配置改了就立刻把受影响的窗口重算一遍，不用等下一轮轮询
function Apply-All {
    Scan-Windows
    foreach ($h in @($script:targets.Keys)) {
        if (-not [Win]::Alive($h)) { continue }
        $cfg = $script:targets[$h]
        foreach ($w in @(Get-Group $h)) {
            if ([Win]::Alive($w)) { Set-TargetAlpha $w $cfg ([bool]$script:insideCache[$w]) }
        }
    }
}

function Restore-All {
    foreach ($h in @($script:minimized)) {
        if ([Win]::Alive($h)) { [Win]::Restore($h) }
    }
    $script:minimized.Clear()
    # 清空 lastIn：还原后光标还在托盘/面板上，不清会在延迟到点后立刻又被最小化
    $script:lastIn.Clear()
}

function Reset-Alpha {
    # 只还原我们真正动过的句柄，别去碰同进程里我们没改过的窗口
    foreach ($h in @($script:applied.Keys)) {
        if (-not [Win]::Alive($h)) { continue }
        $orig = $script:origLayered[$h]
        if ($orig -and $orig.mode -eq 'lwa' -and [int]$orig.alpha -ge 0) {
            # 这个窗口本来就有自己的 alpha，还原成它原来的值，而不是粗暴清掉分层位
            [Win]::SetAlpha($h, [int]$orig.alpha) | Out-Null
        } else {
            [Win]::SetAlpha($h, 255) | Out-Null
        }
    }
    $script:applied.Clear()
    $script:insideCache.Clear()
    $script:origLayered.Clear()
    $script:skipWin.Clear()
}

# 记下当前改过哪些窗口，崩溃时看门狗按它还原。内容没变就不重写盘
function Save-LiveState {
    if (-not $LivePath) { return }
    $wins = @(); $mins = @()
    foreach ($h in @($script:applied.Keys)) { if ([Win]::Alive($h)) { $wins += $h.ToInt64() } }
    foreach ($h in @($script:minimized)) { if ([Win]::Alive($h)) { $mins += $h.ToInt64() } }
    $sig = ($wins -join ',') + '|' + ($mins -join ',')
    if ($sig -eq $script:liveSig) { return }
    $script:liveSig = $sig
    try {
        if ($wins.Count -eq 0 -and $mins.Count -eq 0) {
            if (Test-Path -LiteralPath $LivePath) { [System.IO.File]::Delete($LivePath) }
            return
        }
        $state = [ordered]@{ pid = $PID; windows = $wins; minimized = $mins }
        [System.IO.File]::WriteAllText($LivePath, ($state | ConvertTo-Json -Depth 2), (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}

# 正常退出时把现场删掉，看门狗看到文件不在就知道不用管
function Delete-LiveState {
    if (-not $LivePath) { return }
    try { if (Test-Path -LiteralPath $LivePath) { [System.IO.File]::Delete($LivePath) } } catch { }
}

function Write-UiLog([string]$msg) {
    if (-not $UiLogPath) { return }
    try { Add-Content -LiteralPath $UiLogPath -Value ("{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}" -f (Get-Date), $PID, $msg) -Encoding UTF8 } catch { }
}

# 单实例：Launcher 那把锁只在它等子进程期间有效，被任务管理器结束掉就没了，
# 那时再双击一次就会开出第二份面板 + 第二个托盘图标。这里再上一把应用自己的锁。
# 注意必须放在 Write-UiLog / $UiLogPath 定义之后——函数要按执行顺序先定义再调用。
$script:instanceMutex = $null
if (-not ($SelfTest -or $UiTest -or $Restore -or $RestoreAll)) {
    try {
        $script:instanceMutex = New-Object System.Threading.Mutex($false, 'TransparentApp.AppInstance')
        $acquired = $false
        try { $acquired = $script:instanceMutex.WaitOne(0) } catch { $acquired = $true }   # 上一个实例异常退出会给 AbandonedMutex
        if (-not $acquired) {
            # 已经有实例在跑：不弹新窗口，留一张条子让那个实例把面板调出来
            try { [System.IO.File]::WriteAllText($ShowRequestPath, "$PID", (New-Object System.Text.UTF8Encoding($false))) } catch { }
            Write-UiLog "已有实例在运行，本次启动不弹新窗口，改为请求它显示面板"
            return
        }
    } catch { Write-UiLog ("单实例锁出错：" + $_.Exception.Message) }
}

# 自检走的是真实函数，不是另写一份逻辑：Set-TargetAlpha / Reset-Alpha 就是面板和退出路径调的那两个
if ($SelfTest) {
    $ws = [Win]::Windows()
    Write-Host ("枚举到 {0} 个可见顶层窗口" -f $ws.Count)
    foreach ($h in ($ws | Select-Object -First 12)) {
        Write-Host ("  [0x{0:X}] {1} - {2}" -f $h.ToInt64(), [Win]::Proc($h), [Win]::Title($h))
    }
    $x = 0; $y = 0
    Write-Host ("GetCursorPos ok={0} x={1} y={2}" -f [Win]::Cursor([ref]$x, [ref]$y), $x, $y)
    if ($ws.Count -eq 0) { throw "自检失败：没枚举到任何窗口" }

    $probe = $null
    foreach ($h in $ws) { if (-not [Win]::HasLayered($h)) { $probe = $h; break } }
    if ($null -eq $probe) { throw "自检失败：找不到非 layered 窗口做探针" }

    # 走真实的下发路径：Set-TargetAlpha -> 读回 alpha -> Reset-Alpha（退出时调的就是它）
    $probeCfg = @{ alpha = 150; stealth = $false; action = 'minimize'; leaveMs = 300000 }
    Set-TargetAlpha $probe $probeCfg $true
    if (-not [Win]::HasLayered($probe)) { throw "自检失败：Set-TargetAlpha 没有作用到窗口" }
    if ([Win]::GetAlpha($probe) -ne 150) { throw "自检失败：读回的 alpha 不是 150，实测 $([Win]::GetAlpha($probe))" }
    Reset-Alpha
    if ([Win]::HasLayered($probe)) { throw "自检失败：Reset-Alpha 没还原（退出后透明度会留在桌面上）" }
    if ($script:applied.Count -ne 0) { throw "自检失败：Reset-Alpha 没清空已应用表" }

    $now = Get-Date
    if (Test-Leave $null $now 600) { throw "自检失败：从未进入过的窗口不该被最小化" }
    if (-not (Test-Leave $now.AddSeconds(-10) $now 600)) { throw "自检失败：离开 10 秒后应触发最小化" }
    if (Test-Leave $now.AddMilliseconds(-100) $now 600) { throw "自检失败：刚离开 100ms 不该触发最小化" }
    if (Test-Leave $now.AddSeconds(-2) $now 5000) { throw "自检失败：延迟设为 5 秒时离开 2 秒不该触发" }
    if ((Format-Delay 300000) -ne "5 分钟") { throw "自检失败：Format-Delay 300000 应为「5 分钟」" }
    if ((Format-Delay 500) -ne "500 毫秒") { throw "自检失败：Format-Delay 500 应为「500 毫秒」" }

    $c1 = @{ alpha = 150; stealth = $false; action = 'minimize'; leaveMs = 300000 }
    $c2 = @{ alpha = 150; stealth = $true; action = 'minimize'; leaveMs = 300000 }
    if ((Get-WantAlpha $c1 $true) -ne 150) { throw "自检失败：没开隐身时光标在窗口内应使用该程序的透明度" }
    if ((Get-WantAlpha $c1 $false) -ne 150) { throw "自检失败：没开隐身时光标在窗口外也应使用该程序的透明度" }
    if ((Get-WantAlpha $c2 $true) -ne 150) { throw "自检失败：隐身时光标在窗口内应恢复显示" }
    if ((Get-WantAlpha $c2 $false) -ne $StealthAlpha) { throw "自检失败：隐身时光标在窗口外应压到 StealthAlpha" }
    Write-Host "透明度往返 + 延迟判定自检通过"

    # 配置往返：换一份临时文件，写进去再读回来，值必须一致
    $savedCfgPath = $ConfigPath
    $ConfigPath = Join-Path $env:TEMP ("ta-cfg-test-{0}.json" -f (Get-Random))
    $script:targets = [ordered]@{}
    $script:targets[$probe] = @{ alpha = 99; stealth = $true; action = 'none'; leaveMs = 60000 }
    $script:follow = $false
    Save-Config
    $script:targets = [ordered]@{}
    $script:follow = $true
    Load-Config
    # 加载只把指纹收进 savedTargets，得再扫一次窗口才能重新落到句柄上
    Scan-Windows
    Restore-SavedTargets
    $keys = @($script:targets.Keys)
    if ($keys.Count -ne 1) { throw "自检失败：配置往返没找回窗口（命中 $($keys.Count) 个）" }
    $rt = $script:targets[$keys[0]]
    if ($rt.alpha -ne 99 -or -not $rt.stealth -or $rt.action -ne 'none' -or $rt.leaveMs -ne 60000 -or $script:follow) {
        throw "自检失败：配置往返不一致（follow=$script:follow alpha=$($rt.alpha) stealth=$($rt.stealth) action=$($rt.action) leaveMs=$($rt.leaveMs)）"
    }
    if ((Get-WindowKey $keys[0]) -ne (Get-WindowKey $probe)) { throw "自检失败：找回的不是同一个窗口" }
    Remove-Item -LiteralPath $ConfigPath -Force
    $ConfigPath = $savedCfgPath
    $script:targets = [ordered]@{}
    $script:follow = $true
    Write-Host "配置读写自检通过"
    Write-Host ("自检通过（探针 hwnd=0x{0:X}）" -f $probe.ToInt64())
    return
}

# 退出前必须把改过的窗口还给系统，否则透明度和最小化状态会留在桌面上
function Stop-App {
    $script:reallyExit = $true
    Save-Config          # 必须在 Reset-Alpha 之前：它清空 targets，之后就记不住目标进程名了
    Restore-All
    Reset-Alpha
    $form.Close()
}

# 崩溃也要先把窗口还回去，否则透明度和最小化状态会留在桌面上。
# 事件回包里先还原一次；AppDomain 那条是最后一道，运行时终止前还能跑一小段代码
$onFatal = {
    try { Restore-All } catch { }
    try { Reset-Alpha } catch { }
    try { Save-Config } catch { }
    try { Delete-LiveState } catch { }
    # 还原完就退出：留着它跑，目标列表已经清空，用户会以为程序还好好的
    $script:reallyExit = $true
    try { [System.Windows.Forms.Application]::ExitThread() } catch { }
}
[System.AppDomain]::CurrentDomain.add_UnhandledException($onFatal)
try { [System.Windows.Forms.Application]::add_ThreadException($onFatal) } catch { }
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)

# ---------------- 控制面板 ----------------
# 托盘和任务栏用同一份 .ico：任务栏按 32 取，托盘按系统小图标尺寸取
function New-AppIcon([int]$size) {
    try {
        $icoPath = Join-Path $PSScriptRoot 'TransparentApp.ico'
        if (Test-Path -LiteralPath $icoPath) { return (New-Object System.Drawing.Icon($icoPath, $size, $size)) }
    } catch { }
    return [System.Drawing.SystemIcons]::Application
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "TransparentApp"
$form.Icon = New-AppIcon 32
$form.ClientSize = New-Object System.Drawing.Size(380, 452)
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.StartPosition = 'CenterScreen'

$lblAlpha = New-Object System.Windows.Forms.Label
$lblAlpha.AutoSize = $false   # 不关掉 AutoSize 的话 .Size 会被忽略，长文字直接把面板撑出去
$lblAlpha.Location = New-Object System.Drawing.Point(12, 10)
$lblAlpha.Size = New-Object System.Drawing.Size(356, 20)

$tbAlpha = New-Object System.Windows.Forms.TrackBar
$tbAlpha.Minimum = 0         # 允许全透明：窗口本体还在，取消勾选或退出即可找回
$tbAlpha.Maximum = 100
$tbAlpha.TickFrequency = 5
$tbAlpha.LargeChange = 10
$tbAlpha.SmallChange = 1
$tbAlpha.Location = New-Object System.Drawing.Point(8, 30)
$tbAlpha.Size = New-Object System.Drawing.Size(364, 45)
$tbAlpha.Value = [int]($DefaultCfg.alpha * 100 / 255)

$chkStealth = New-Object System.Windows.Forms.CheckBox
$chkStealth.Text = "隐身：光标不在窗口内时完全透明（0%）"
$chkStealth.Location = New-Object System.Drawing.Point(12, 80)
$chkStealth.Size = New-Object System.Drawing.Size(356, 22)

$lblAction = New-Object System.Windows.Forms.Label
$lblAction.AutoSize = $false
$lblAction.Text = "鼠标移开后"
$lblAction.Location = New-Object System.Drawing.Point(12, 106)
$lblAction.Size = New-Object System.Drawing.Size(68, 22)

$cbAction = New-Object System.Windows.Forms.ComboBox
$cbAction.DropDownStyle = 'DropDownList'
$cbAction.Location = New-Object System.Drawing.Point(82, 104)
$cbAction.Size = New-Object System.Drawing.Size(124, 24)
foreach ($o in $ActionOptions) { $cbAction.Items.Add($o.text) | Out-Null }

$cbDelay = New-Object System.Windows.Forms.ComboBox
$cbDelay.DropDownStyle = 'DropDownList'
$cbDelay.Location = New-Object System.Drawing.Point(212, 104)
$cbDelay.Size = New-Object System.Drawing.Size(156, 24)
foreach ($o in $DelayOptions) { $cbDelay.Items.Add($o.text) | Out-Null }

$chkFollow = New-Object System.Windows.Forms.CheckBox
$chkFollow.Text = "同时作用于它派生出来的窗口（弹窗 / 无标题窗口）"
$chkFollow.Location = New-Object System.Drawing.Point(12, 132)
$chkFollow.Size = New-Object System.Drawing.Size(356, 22)
$chkFollow.Checked = $script:follow

$lblTargets = New-Object System.Windows.Forms.Label
$lblTargets.AutoSize = $false
$lblTargets.Text = "目标程序（勾选启用；选中一行改它的配置）"
$lblTargets.Location = New-Object System.Drawing.Point(12, 162)
$lblTargets.Size = New-Object System.Drawing.Size(356, 18)

$lbTargets = New-Object System.Windows.Forms.CheckedListBox
$lbTargets.CheckOnClick = $true
$lbTargets.IntegralHeight = $false
$lbTargets.Location = New-Object System.Drawing.Point(12, 182)
$lbTargets.Size = New-Object System.Drawing.Size(356, 180)

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Text = "刷新列表"
$btnRefresh.Location = New-Object System.Drawing.Point(12, 370)
$btnRefresh.Size = New-Object System.Drawing.Size(110, 26)

$btnRemove = New-Object System.Windows.Forms.Button
$btnRemove.Text = "删除所选"
$btnRemove.Location = New-Object System.Drawing.Point(130, 370)
$btnRemove.Size = New-Object System.Drawing.Size(110, 26)

$btnRestore = New-Object System.Windows.Forms.Button
$btnRestore.Text = "还原全部窗口"
$btnRestore.Location = New-Object System.Drawing.Point(12, 406)
$btnRestore.Size = New-Object System.Drawing.Size(170, 32)

$btnExit = New-Object System.Windows.Forms.Button
$btnExit.Text = "退出并恢复透明度"
$btnExit.Location = New-Object System.Drawing.Point(190, 406)
$btnExit.Size = New-Object System.Drawing.Size(178, 32)

$form.Controls.AddRange(@($lblAlpha, $tbAlpha, $chkStealth, $lblAction, $cbAction, $cbDelay, $chkFollow, $lblTargets, $lbTargets, $btnRefresh, $btnRemove, $btnRestore, $btnExit))

function Update-AlphaLabel {
    # 选中窗口的名字放标题栏：面板宽度有限，塞在这一行里必然被截断或者压到下面的控件上
    $name = ""
    if ($script:selected -and [Win]::Alive($script:selected)) { $name = Get-SafeLabel $script:selected }
    if ($name.Length -gt 48) { $name = $name.Substring(0, 48) + "…" }
    $form.Text = if ($name) { "TransparentApp · $name" } else { "TransparentApp" }
    $lblAlpha.Text = "透明度 $($tbAlpha.Value)%"
}

function Get-DelayIndex([int]$ms) {
    for ($i = 0; $i -lt $DelayOptions.Count; $i++) { if ($DelayOptions[$i].ms -eq $ms) { return $i } }
    for ($i = 0; $i -lt $DelayOptions.Count; $i++) { if ($DelayOptions[$i].ms -eq 300000) { return $i } }
    return 0   # 认不出来就用 5 分钟那一档
}

# 显示面板的唯一入口。三处调用（托盘图标 / 托盘菜单 / 再次启动）都走这里，日志才不会有漏
function Show-Panel([string]$why) {
    Write-UiLog "面板显示：$why"
    $script:suppressHide = $true
    try {
        $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
        if (-not $form.Visible) { $form.Show() }
        [Win]::ShowIt($form.Handle)
        $form.Activate()
    } finally {
        $script:suppressHide = $false
    }
}

function Get-ActionIndex([string]$id) {
    for ($i = 0; $i -lt $ActionOptions.Count; $i++) { if ($ActionOptions[$i].id -eq $id) { return $i } }
    return 1   # 认不出来就按「最小化窗口」
}

# 关掉这个窗口和它派生出来的窗口：逐个发 WM_CLOSE（等于点各自的 ×）。
# 不强制结束进程——那会把同一个程序里别的窗口一起带走，跟「关闭窗口」不是一回事
function Close-TargetWindows([IntPtr]$h) {
    $n = 0
    foreach ($w in @(Get-Group $h)) {
        if ([Win]::Alive($w)) { [Win]::PostClose($w) | Out-Null; $n++ }
    }
    return $n
}

# 把选中窗口的配置灌进控件。uiInit 挡住事件，免得灌的过程被当成用户改动又写回去
function Load-Selected {
    $script:uiInit = $true
    try {
        $cfg = $null
        if ($script:selected -and $script:targets.Contains($script:selected)) { $cfg = $script:targets[$script:selected] }
        if ($cfg) {
            $tbAlpha.Value = [int]($cfg.alpha * 100 / 255)
            $chkStealth.Checked = [bool]$cfg.stealth
            $cbAction.SelectedIndex = Get-ActionIndex "$($cfg.action)"
            $cbDelay.SelectedIndex = Get-DelayIndex ([int]$cfg.leaveMs)
        } else {
            $tbAlpha.Value = [int]($DefaultCfg.alpha * 100 / 255)
            $chkStealth.Checked = $false
            $cbAction.SelectedIndex = Get-ActionIndex $DefaultCfg.action
            $cbDelay.SelectedIndex = Get-DelayIndex ([int]$DefaultCfg.leaveMs)
        }
        $cbDelay.Enabled = ($cbAction.SelectedIndex -gt 0)
    } finally {
        $script:uiInit = $false
    }
    Update-AlphaLabel
}

# 控件 -> 选中窗口的配置，改完立刻下发并标记待保存
function Push-Settings {
    if (-not $script:selected) { return }
    if (-not $script:targets.Contains($script:selected)) { return }
    $cfg = $script:targets[$script:selected]
    $cfg.alpha = [int]($tbAlpha.Value * 255 / 100)
    $cfg.stealth = $chkStealth.Checked
    if ($cbAction.SelectedIndex -ge 0 -and $cbAction.SelectedIndex -lt $ActionOptions.Count) {
        $cfg.action = $ActionOptions[$cbAction.SelectedIndex].id
    }
    if ($cbDelay.SelectedIndex -ge 0 -and $cbDelay.SelectedIndex -lt $DelayOptions.Count) {
        $cfg.leaveMs = [int]$DelayOptions[$cbDelay.SelectedIndex].ms
    }
    $script:cfgDirty = $true
    foreach ($w in @(Get-Group $script:selected)) {
        if ([Win]::Alive($w)) { Set-TargetAlpha $w $cfg ([bool]$script:insideCache[$w]) }
    }
    # 顺手记成这个进程的默认值，下次勾同程序的另一个窗口时拿它当初值
    if ([Win]::Alive($script:selected)) {
        $script:procDefaults[[Win]::Proc($script:selected)] = @{ alpha = $cfg.alpha; stealth = $cfg.stealth; action = $cfg.action; leaveMs = $cfg.leaveMs }
    }
}

# 列表行 = 窗口。已启用的排前面，其余是当前能当目标的窗口
function Refresh-Targets {
    Scan-Windows
    if (-not $script:cfgRestored) { Restore-SavedTargets }
    $keep = $script:selected
    $script:uiInit = $true
    try {
        $lbTargets.Items.Clear()
        $script:listHwnd = @()
        $known = @{}
        foreach ($h in @($script:targets.Keys)) {
            if (-not [Win]::Alive($h)) { continue }
            $known[$h] = $true
            $script:listHwnd += $h
            [void]$lbTargets.Items.Add((Get-SafeLabel $h), $true)
        }
        foreach ($h in @($script:candidates)) {
            if ($known.ContainsKey($h)) { continue }
            $script:listHwnd += $h
            [void]$lbTargets.Items.Add((Get-SafeLabel $h), $false)
        }
    } finally {
        $script:uiInit = $false
    }
    $pos = -1
    if ($keep) { $pos = [array]::IndexOf($script:listHwnd, $keep) }
    if ($pos -ge 0) {
        $lbTargets.SelectedIndex = $pos
    } elseif ($script:listHwnd.Count -gt 0) {
        $lbTargets.SelectedIndex = 0
    } else {
        $script:selected = $null
        Load-Selected
    }
}

$script:listHwnd = @()   # 列表行号 -> 窗口句柄，必须和 CheckedListBox 的行一一对应

$tbAlpha.add_ValueChanged({
    param($s, $e)
    if ($script:uiInit) { return }
    Update-AlphaLabel
    Push-Settings
})

$chkStealth.add_CheckedChanged({
    param($s, $e)
    if ($script:uiInit) { return }
    Push-Settings
})

$cbAction.add_SelectedIndexChanged({
    param($s, $e)
    if ($script:uiInit -or $s.SelectedIndex -lt 0) { return }
        # 自动关窗口还是先确认一下
        if ($ActionOptions[$s.SelectedIndex].id -eq 'close') {
        $ans = [System.Windows.Forms.MessageBox]::Show(
            "开启后，鼠标移开超过设定时间会关掉这个窗口，以及它派生出来的弹窗`n" +
            "（等于替你点了窗口右上角的 ×，同一个程序的其它窗口不受影响）。`n`n" +
            "程序如果有未保存的内容，会按它自己的方式处理（弹确认框或直接丢弃）。",
            "确认开启「关闭窗口」", 'OKCancel', 'Warning')
        if ($ans -ne 'OK') {
            $prev = $DefaultCfg.action
            if ($script:selected -and $script:targets.Contains($script:selected)) { $prev = "$($script:targets[$script:selected].action)" }
            $script:uiInit = $true
            $cbAction.SelectedIndex = Get-ActionIndex $prev
            $script:uiInit = $false
            return
        }
    }
    $cbDelay.Enabled = ($s.SelectedIndex -gt 0)
    Push-Settings
})

$cbDelay.add_SelectedIndexChanged({
    param($s, $e)
    if ($script:uiInit) { return }
    Push-Settings
})

$chkFollow.add_CheckedChanged({
    param($s, $e)
    if ($script:uiInit) { return }
    $script:follow = $s.Checked
    $script:cfgDirty = $true
    # 先把已经改过的窗口全还原，再按新范围重新下发，关掉跟随时派生窗口才能恢复
    Reset-Alpha
    Apply-All
})

$lbTargets.add_ItemCheck({
    param($s, $e)
    if ($script:uiInit) { return }
    if ($e.Index -lt 0 -or $e.Index -ge $script:listHwnd.Count) { return }
    $h = $script:listHwnd[$e.Index]
    if ($e.NewValue -eq [System.Windows.Forms.CheckState]::Checked) {
        if (-not $script:targets.Contains($h)) {
            # 这个进程之前配过就用上次那份，没配过用默认值
            $proc = [Win]::Proc($h)
            $seed = if ($script:procDefaults.ContainsKey($proc)) { $script:procDefaults[$proc] } else { $DefaultCfg }
            $script:targets[$h] = @{ alpha = [int]$seed.alpha; stealth = [bool]$seed.stealth; action = "$($seed.action)"; leaveMs = [int]$seed.leaveMs }
        }
        $script:selected = $h
        $script:cfgDirty = $true
        Apply-All
        Load-Selected
    } else {
        foreach ($w in @(Get-Group $h)) {
            if ([Win]::Alive($w)) { [Win]::SetAlpha($w, 255) | Out-Null }
            $script:applied.Remove($w) | Out-Null
        }
        $script:targets.Remove($h) | Out-Null
        $script:lastIn.Remove($h) | Out-Null
        $script:wasMin.Remove($h) | Out-Null
        $script:cfgDirty = $true
    }
})

$lbTargets.add_SelectedIndexChanged({
    param($s, $e)
    if ($script:uiInit) { return }
    if ($s.SelectedIndex -lt 0 -or $s.SelectedIndex -ge $script:listHwnd.Count) { return }
    $script:selected = $script:listHwnd[$s.SelectedIndex]
    Load-Selected
})

$btnRefresh.add_Click({ Refresh-Targets })
$btnRemove.add_Click({
    if (-not $script:selected) { return }
    foreach ($w in @(Get-Group $script:selected)) {
        if ([Win]::Alive($w)) { [Win]::SetAlpha($w, 255) | Out-Null }
        $script:applied.Remove($w) | Out-Null
    }
    $script:targets.Remove($script:selected) | Out-Null
    $script:lastIn.Remove($script:selected) | Out-Null
    $script:wasMin.Remove($script:selected) | Out-Null
    $script:cfgDirty = $true
    $script:selected = $null
    Refresh-Targets
})
$btnRestore.add_Click({ Restore-All })
$btnExit.add_Click({ Stop-App })

$form.add_Resize({
    param($s, $e)
    if ($script:suppressHide) { return }
    if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
        # 最小化就等同收进托盘：留一个最小化窗口的话，别的程序或系统一句
        # SetForegroundWindow 就能把它还原出来，表现就是「面板自己跳出来」
        $form.Hide()
        Write-UiLog "面板隐藏：最小化（收回托盘）"
    }
})

$form.add_FormClosing({
    param($s, $e)
    if (-not $script:reallyExit) {
        # 点 X 只收回托盘：透明度和最小化状态全都保持，程序继续跑
        $e.Cancel = $true
        $form.Hide()
        Write-UiLog "面板隐藏：点了 X 收起"
        if (-not $script:hintedTray) {
            $script:hintedTray = $true
            $tray.ShowBalloonTip(5000, "TransparentApp 还在运行",
                "点 X 只是收起面板。要退出请用托盘右键 -> 退出并恢复透明度。",
                [System.Windows.Forms.ToolTipIcon]::Info)
        }
        return
    }
    Restore-All
    Reset-Alpha
})

$form.add_Shown({
    [Win]::ShowIt($form.Handle)
    Write-UiLog "面板显示：程序启动"
    # Refresh-Targets 会顺带选中第一行，并把那一行的配置灌进控件
    Refresh-Targets
})

# -UiTest：在真实消息循环里跑一遍「勾程序 -> 拖滑块 -> 开隐身 -> 点 X -> 退出」
if ($UiTest) {
    $t2 = New-Object System.Windows.Forms.Timer
    $t2.Interval = 1500
    $t2.add_Tick({
        param($s, $e)
        $s.Stop()
        # 挑一个 chrome 窗口做探针，没有就用列表第一行
        $h = [IntPtr]::Zero
        foreach ($w in @($script:listHwnd)) { if ([Win]::Proc($w) -eq 'chrome') { $h = $w; break } }
        if ($h -eq [IntPtr]::Zero -and $script:listHwnd.Count -gt 0) { $h = $script:listHwnd[0] }
        if ($h -eq [IntPtr]::Zero) { Write-Host "UITEST FAIL: 列表里没有可用窗口"; Stop-App; return }
        $script:uiProbe = $h
        $idx = [array]::IndexOf($script:listHwnd, $h)
        $grp = @(Get-Group $h)
        Write-Host ("UITEST 探针 {0}（hwnd=0x{1:X}，这一组 {2} 个窗口）列表行 {3}" -f (Get-SafeLabel $h), $h.ToInt64(), $grp.Count, $idx)
        Write-Host ("UITEST 任务栏图标 {0}x{1}，托盘图标 {2}x{3}" -f $form.Icon.Width, $form.Icon.Height, $tray.Icon.Width, $tray.Icon.Height)
        if ($form.Icon.Width -ne 32) { Write-Host "UITEST FAIL: 任务栏图标不是 32x32，说明没取到 .ico" }
        $winIcon = [Win]::GetWindowIcon($form.Handle)
        Write-Host ("UITEST AppUserModelID 设置结果={0}，窗口大图标句柄=0x{1:X}，form.Icon.Handle=0x{2:X}" -f $script:appIdResult, $winIcon.ToInt64(), $form.Icon.Handle.ToInt64())
        if ($winIcon -eq [IntPtr]::Zero) { Write-Host "UITEST FAIL: 窗口没设上自己的图标" }
        if ($winIcon -ne $form.Icon.Handle) { Write-Host "UITEST FAIL: 窗口图标句柄和 form.Icon 不一致" }
        if ($script:appIdResult -ne 0) { Write-Host "UITEST FAIL: AppUserModelID 没设成功（返回值 $($script:appIdResult)），任务栏会退回显示 powershell 图标" }
        Write-Host ("UITEST 延迟档位：{0}" -f (($DelayOptions | ForEach-Object { $_.text }) -join ' / '))

        # 布局自检：控件之间不许互相压住，文字不许超出控件宽度（截图里那种「有遮挡」就是这类问题）
        $bad = @()
        $ctrls = @($form.Controls)
        for ($i = 0; $i -lt $ctrls.Count; $i++) {
            for ($j = $i + 1; $j -lt $ctrls.Count; $j++) {
                if ($ctrls[$i].Bounds.IntersectsWith($ctrls[$j].Bounds)) {
                    $bad += ("控件重叠 [{0}] / [{1}]" -f $ctrls[$i].GetType().Name, $ctrls[$j].GetType().Name)
                }
            }
        }
        foreach ($c in $ctrls) {
            if ($c -is [System.Windows.Forms.Label] -or $c -is [System.Windows.Forms.CheckBox]) {
                # 按控件宽度约束着量：文字太长会折行，折出来的第二行就会压在下面的控件上
                $need = [System.Windows.Forms.TextRenderer]::MeasureText(
                    $c.Text, $c.Font, (New-Object System.Drawing.Size($c.Width, 0)),
                    [System.Windows.Forms.TextFormatFlags]::NoPadding)
                if ($need.Width -gt $c.Width) {
                    $bad += ("文字超出 [{0}] 需要 {1}px，控件只有 {2}px" -f $c.Text, $need.Width, $c.Width)
                }
                if ($need.Height -gt $c.Height) {
                    $bad += ("文字折行被压住 [{0}] 需要高 {1}px，控件只有 {2}px" -f $c.Text, $need.Height, $c.Height)
                }
                if ($c.Right -gt $form.ClientSize.Width -or $c.Bottom -gt $form.ClientSize.Height) {
                    $bad += ("控件伸出面板外 [{0}]" -f $c.Text)
                }
            }
        }
        if ($bad.Count -gt 0) {
            foreach ($b in $bad) { Write-Host "UITEST FAIL: $b" }
        } else {
            Write-Host ("UITEST 布局自检通过：{0} 个控件无重叠、文字都在框内" -f $ctrls.Count)
        }

        $lbTargets.SetItemChecked($idx, $true)
        if (-not $script:targets.Contains($h)) { Write-Host "UITEST FAIL: 勾选后目标表里没有这个窗口" }
        if (-not [Win]::HasLayered($h)) { Write-Host "UITEST FAIL: 勾选目标窗口后没有上透明度" }
        # 这一组里除了探针还有别的窗口，说明派生窗口被带上了
        if ($grp.Count -gt 1) {
            $allOk = $true
            foreach ($w in $grp) { if (-not [Win]::HasLayered($w)) { $allOk = $false } }
            Write-Host ("UITEST 派生窗口一起生效 = {0}（这一组 {1} 个窗口）" -f $allOk, $grp.Count)
            if (-not $allOk) { Write-Host "UITEST FAIL: 组里有派生窗口没被一起上透明度" }
        }

        $tbAlpha.Value = 60
        if ($lblAlpha.Text -notmatch '60%') { Write-Host "UITEST FAIL: 拖滑块后标签没更新（$($lblAlpha.Text)）" }
        if (-not [Win]::HasLayered($h)) { Write-Host "UITEST FAIL: 滑块没有作用到窗口" }
        $got = [Win]::GetAlpha($h)
        if ($got -ne 153) { Write-Host "UITEST FAIL: 滑块 60% 应下发 alpha 153，实测 $got" }

        # 配置落盘：改设置要标记脏，轮询里的落盘动作就是这个 Save-Config
        if (-not $script:cfgDirty) { Write-Host "UITEST FAIL: 改设置后没有标记配置待保存" }
        Save-Config
        if (-not (Test-Path $ConfigPath)) {
            Write-Host "UITEST FAIL: 配置没有落盘"
        } else {
            $cfgText = Get-Content -Raw -Encoding UTF8 $ConfigPath
            Write-Host "UITEST 落盘配置：$cfgText"
            if ($cfgText -notmatch '"alpha"\s*:\s*153') { Write-Host "UITEST FAIL: 落盘配置里的 alpha 不是 153" }
        }

        if ($cbDelay.SelectedIndex -lt 0) { Write-Host "UITEST FAIL: 延迟下拉没初始化" }
        # 把缓存写成「光标在窗口外」再重放一次开关，走的就是隐身那一路
        $script:insideCache[$h] = $false
        $chkStealth.Checked = $true
        $got = [Win]::GetAlpha($h)
        Write-Host ("UITEST 隐身影子态 alpha={0}（应为 0）" -f $got)
        if ($got -ne 0) { Write-Host "UITEST FAIL: 隐身且光标在窗口外应完全透明，实测 $got" }

        $script:insideCache[$h] = $true
        $chkStealth.Checked = $false
        $chkStealth.Checked = $true
        $got = [Win]::GetAlpha($h)
        Write-Host ("UITEST 隐身悬停态 alpha={0}（应为 153）" -f $got)
        if ($got -ne 153) { Write-Host "UITEST FAIL: 隐身时光标在窗口内应恢复显示，实测 $got" }
        if ($lblAlpha.Text -notmatch '60%') { Write-Host "UITEST FAIL: 开隐身把面板的透明度设置改掉了" }

        # 点 X 只收回托盘：Close() 被 FormClosing 取消，窗口隐藏但程序继续跑
        $form.Close()
        if ($form.Visible) { Write-Host "UITEST FAIL: 点 X 没有把面板收进托盘" }
        if ($script:reallyExit) { Write-Host "UITEST FAIL: 点 X 直接退出了程序" }
        Write-Host ("UITEST 点 X 后 visible={0} reallyExit={1}（应为 False False）" -f $form.Visible, $script:reallyExit)

        # 最小化应该等同收进托盘：留一个最小化窗口的话，外部一句 SetForegroundWindow 就能把它弹回来
        Show-Panel "测试用"
        $form.WindowState = [System.Windows.Forms.FormWindowState]::Minimized
        Start-Sleep -Milliseconds 400
        Write-Host ("UITEST 最小化后 visible={0}（应为 False，即已收回托盘）" -f $form.Visible)
        if ($form.Visible) { Write-Host "UITEST FAIL: 最小化后面板没收回托盘" }
        Show-Panel "测试用（还原）"
        if (-not $form.Visible) { Write-Host "UITEST FAIL: 从托盘再调出来失败" }

        # 顺手验证退出时最小化也会被还原
        [Win]::Minimize($h)
        $script:minimized.Add($h) | Out-Null
        Write-Host ("UITEST 勾选+滑块后 layered=True，探针已最小化，准备退出")
        Stop-App
    })
    $t2.Start()
}

# ---------------- 托盘 ----------------
$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = New-AppIcon ([System.Windows.Forms.SystemInformation]::SmallIconSize.Width)
$tray.Text = "TransparentApp"

# 菜单一次性建好，不在 Opening 里重建：重建要枚举窗口 + 查进程名，慢到右击要点好几次才弹
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miShow = New-Object System.Windows.Forms.ToolStripMenuItem("显示控制面板")
$miShow.add_Click({
    param($s, $e)
    Show-Panel "从托盘菜单点「显示控制面板」"
})
$menu.Items.Add($miShow) | Out-Null
$miRestore = New-Object System.Windows.Forms.ToolStripMenuItem("还原全部窗口")
$miRestore.add_Click({ param($s, $e) Restore-All })
$menu.Items.Add($miRestore) | Out-Null
$miExit = New-Object System.Windows.Forms.ToolStripMenuItem("退出并恢复透明度")
$miExit.add_Click({ param($s, $e) Stop-App })
$menu.Items.Add($miExit) | Out-Null

$tray.ContextMenuStrip = $menu
$tray.add_MouseClick({
    param($s, $e)
    if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
    Show-Panel "点了托盘图标"
})
$tray.Visible = $true

# ---------------- 轮询 ----------------
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $PollMs
$timer.add_Tick({
    param($s, $e)
    # 拖滑块一秒能触发几十次事件，攒到轮询里写一次，别每个事件都落盘
    if ($script:cfgDirty) { $script:cfgDirty = $false; Save-Config }
    if (((Get-Date) - $script:scanAt).TotalMilliseconds -gt $WindowCacheMs) { Scan-Windows }
    Save-LiveState

    # 又双击了一次程序：不另开面板，把已经有的这个调出来
    if ($ShowRequestPath -and (Test-Path -LiteralPath $ShowRequestPath)) {
        try { [System.IO.File]::Delete($ShowRequestPath) } catch { }
        Show-Panel "收到了「再次启动」的请求"
    }

    $x = 0; $y = 0
    if (-not [Win]::Cursor([ref]$x, [ref]$y)) { return }
    $pidAt = [Win]::PidAt($x, $y)
    $now = Get-Date

    foreach ($name in @($script:targets.Keys)) {
        if (-not [Win]::Alive($name)) {
            $script:targets.Remove($name) | Out-Null
            $script:lastIn.Remove($name) | Out-Null
            $script:wasMin.Remove($name) | Out-Null
            continue
        }
        $cfg = $script:targets[$name]
        $hwnds = @(Get-Group $name)
        if ($hwnds.Count -eq 0) { continue }
        $p = [Win]::Pid($name)

        # 光标落在这个程序的任一窗口（含派生窗口）上就算「在里面」；
        # 否则再看是否落在某个窗口矩形内、并且那个窗口没被别的窗口压住
        $inside = ($pidAt -eq $p)
        if (-not $inside) {
            foreach ($h in $hwnds) {
                if ([Win]::Minimized($h)) { continue }
                $l = 0; $t = 0; $r = 0; $b = 0
                if (-not [Win]::Rect($h, [ref]$l, [ref]$t, [ref]$r, [ref]$b)) { continue }
                if ($x -lt $l -or $x -ge $r -or $y -lt $t -or $y -ge $b) { continue }
                # 窗口 alpha 0 时点不通，WindowFromPoint 看不到它，所以改用 z 序判断它是不是最上面那个
                $top = [Win]::RootOf([Win]::WindowAt($x, $y))
                if (($top -eq $h) -or ([Win]::Pid($top) -eq $p) -or [Win]::Above($h, $top)) { $inside = $true; break }
            }
        }

        $restored = $false
        foreach ($h in $hwnds) {
            if (-not [Win]::Alive($h)) { continue }
            $script:insideCache[$h] = $inside
            Set-TargetAlpha $h $cfg $inside
            $min = [Win]::Minimized($h)
            # 从最小化恢复（我们自己还原 / 用户点任务栏 / Alt+Tab）后必须重新起算
            if (-not $min -and $script:wasMin[$h]) { $restored = $true }
            $script:wasMin[$h] = $min
        }
        if ($restored) { $script:lastIn.Remove($name) }

        if ($inside) {
            $script:lastIn[$name] = $now
            # 光标又回到这个窗口身上，下次移开可以再关一次
            $script:closeAsked.Remove($name) | Out-Null
            continue
        }
        if ($cfg.action -eq 'none') { continue }
        if (-not (Test-Leave $script:lastIn[$name] $now ([int]$cfg.leaveMs))) { continue }

        if ($cfg.action -eq 'close') {
            # 已经请求过关窗就不再重复发：程序要是不理会 WM_CLOSE，每轮都发一遍会把它弹窗刷爆
            if (-not $script:closeAsked.ContainsKey($name)) {
                $script:closeAsked[$name] = $true
                Close-TargetWindows $name | Out-Null
            }
            continue
        }

        # 只收走光标不在上面的那些窗口：同一个程序开了多个窗口时别把人正在看的也最小化
        foreach ($h in $hwnds) {
            if (-not [Win]::Alive($h) -or [Win]::Minimized($h)) { continue }
            $l = 0; $t = 0; $r = 0; $b = 0
            if ([Win]::Rect($h, [ref]$l, [ref]$t, [ref]$r, [ref]$b) -and
                $x -ge $l -and $x -lt $r -and $y -ge $t -and $y -lt $b) { continue }
            [Win]::Minimize($h)
            if (-not $script:minimized.Contains($h)) { $script:minimized.Add($h) | Out-Null }
        }
    }
})
$timer.Start()

Write-UiLog ("启动（pid={0}）" -f $PID)

# 起一个看门狗跟着自己：它只干一件事——主进程异常退出时把窗口恢复原样。
# 主进程正常退出会删掉现场文件，看门狗醒来发现没文件就什么都不做。
if (-not ($SelfTest -or $UiTest -or $Restore -or $Watchdog -gt 0)) {
    # 走 WMI 起，看门狗挂在 WmiPrvSE 下面而不是我们的进程树里：
    # 否则任务管理器「结束任务」连带子树一起杀时，看门狗会跟主进程一起死，那就没人收尾了
    $wdCmd = 'powershell.exe -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File "{0}" -Watchdog {1}' -f $PSCommandPath, $PID
    $started = $false
    try {
        $r = ([wmiclass]'Win32_Process').Create($wdCmd)
        if ($null -ne $r -and $r.ReturnValue -eq 0) { $started = $true }
    } catch { }
    if (-not $started) {
        try {
            Start-Process powershell -ArgumentList '-WindowStyle', 'Hidden', '-NoProfile', '-ExecutionPolicy', 'Bypass',
                '-File', "`"$PSCommandPath`"", '-Watchdog', $PID -WindowStyle Hidden
        } catch { }
    }
}

try {
    [System.Windows.Forms.Application]::Run($form)
} finally {
    # 兜底：正常退出路径已经还原过，这里是幂等的；消息循环抛异常时也能走到
    $timer.Stop()
    $timer.Dispose()
    Restore-All
    Reset-Alpha
    Delete-LiveState
    $tray.Visible = $false
    $tray.Dispose()
    Write-UiLog "退出"
}

if ($UiTest) {
    $layered = ($script:uiProbe -ne [IntPtr]::Zero) -and [Win]::HasLayered($script:uiProbe)
    Write-Host ("UITEST 退出后 layered={0}（应为 False）" -f $layered)
    if ($layered) { throw "UITEST FAIL: 退出后透明度没有还原" }
    if (($script:uiProbe -ne [IntPtr]::Zero) -and [Win]::Minimized($script:uiProbe)) { throw "UITEST FAIL: 退出后最小化的窗口没有还原" }
    Write-Host "UITEST 退出后最小化窗口已还原"
    if (Test-Path $ConfigPath) { Remove-Item -LiteralPath $ConfigPath -Force }
    Write-Host "UITEST PASSED"
}
