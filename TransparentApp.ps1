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

# 由 TransparentApp.exe 进程内宿主时，启动器会先注入这几个变量；直接跑 .ps1 时它们都不存在。
# $Hosted 用来关掉下面那段「自己再分叉一次」的逻辑——宿主模式下本来就是唯一的进程。
if ($HostedWatchdog -gt 0) { $Watchdog = $HostedWatchdog }

# 消息循环会一直占着控制台，表现就是「命令卡住、没有入口」。默认甩到后台跑，
# 终端立刻回到提示符；真正干活的进程带 -Detached，不再重复分叉。
if (-not $Hosted -and -not $Detached -and -not $SelfTest -and -not $UiTest -and -not $Restore -and -not $RestoreAll -and $Watchdog -eq 0) {
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
    # 从 exe 启动时 Win 类已经编进 exe 里，这段不会执行；
    # 只有直接跑 .ps1（开发/自检）才会走到这里，需要同目录的 Win.cs
    $winCs = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'Win.cs' } else { $null }
    if (-not $winCs -or -not (Test-Path -LiteralPath $winCs)) {
        throw "找不到 Win.cs：请用 TransparentApp.exe 启动，或把 Win.cs 和 TransparentApp.ps1 放在同一目录"
    }
    Add-Type -Path $winCs
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
$script:appIdResult = [Win]::SetAppId("Clock")

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
$script:checkedWin  = @{}    # 句柄 -> 已经判定过「能不能碰」了
$script:skipWin     = @{}    # 句柄 -> 不碰（自己就在逐像素分层画的窗口）
$script:members    = @{}     # 上一轮扫描时全部组的成员集合，用来发现这一轮「出组」的窗口
$script:joinedAt   = @{}     # 句柄 -> 刚进组的时间，新来的先观察两秒再谈最小化
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
            if ($owner -ne [IntPtr]::Zero) {
                # 有属主就只认属主，属主不是目标就不收编。原来这里会继续落到下面的同进程兜底，
                # Chrome 的「翻译此页？」气泡这类属主是普通窗口的弹层就是这样被误收的，
                # 表现出来就是没勾选的窗口被透明、被最小化
                if ($g.ContainsKey($owner)) { [void]$g[$owner].Add($w) }
                continue
            }
            # 完全没有属主（微信表情面板就是这种）：同进程下只挂了一个目标窗口时归它
            $same = @($g.Keys | Where-Object { [Win]::Alive($_) -and [Win]::Pid($_) -eq [Win]::Pid($w) })
            if ($same.Count -eq 1) { [void]$g[$same[0]].Add($w) }
        }
        foreach ($w in @($cands)) {
            if ($g.ContainsKey($w)) { continue }
            $owner = [Win]::RootOf([Win]::Owner($w))
            if ($owner -ne [IntPtr]::Zero -and $g.ContainsKey($owner)) { [void]$g[$owner].Add($w) }
        }
    }
    # 出组收尾：上一轮还是某个目标的组员、这一轮不在了的窗口，把我们动过的东西还回去。
    # 派生窗口有时只是「无标题一瞬间」被收进来（新建浏览器窗口、Chrome 的临时气泡），
    # 标题一恢复就出组——没人管的话它会一直带着我们设的 alpha（甚至最小化状态）留在桌面上，
    # 表现出来就是「没勾选的窗口自己在透明/消失」。
    $members = @{}
    foreach ($k in @($g.Keys)) { foreach ($w in @($g[$k])) { $members[$w] = $true } }
    foreach ($h in @($script:members.Keys)) {
        if ($members.ContainsKey($h)) { continue }
        if ([Win]::Alive($h)) {
            if ($script:applied.ContainsKey($h)) {
                [Win]::SetAlpha($h, 255) | Out-Null
                $script:applied.Remove($h) | Out-Null
            }
            if ($script:minimized.Contains($h)) {
                # 只在窗口确实还被最小化时才叫醒它：用户可能早自己还原了，
                # 这时再 ShowWindow(SW_RESTORE) 会把它重新抢到前台，白白打断用户
                if ([Win]::Minimized($h)) { [Win]::Restore($h) | Out-Null }
                $script:minimized.Remove($h) | Out-Null
            }
        }
        $script:insideCache.Remove($h) | Out-Null
        $script:joinedAt.Remove($h) | Out-Null
    }
    # 死句柄清理：句柄会被系统复用，按句柄记的判定和状态留着会误伤下一个拿到它的窗口
    foreach ($h in @($script:applied.Keys))    { if (-not [Win]::Alive($h)) { $script:applied.Remove($h) | Out-Null; $script:insideCache.Remove($h) | Out-Null } }
    foreach ($h in @($script:checkedWin.Keys)) { if (-not [Win]::Alive($h)) { $script:checkedWin.Remove($h) | Out-Null; $script:skipWin.Remove($h) | Out-Null } }
    for ($i = $script:minimized.Count - 1; $i -ge 0; $i--) { if (-not [Win]::Alive($script:minimized[$i])) { $script:minimized.RemoveAt($i) } }
    $script:members = $members
    $script:group = $g
    $script:scanAt = Get-Date
}

# 这个目标窗口这一组实际要管的窗口（它自己 + 派生窗口）
function Get-Group([IntPtr]$h) {
    if ($script:group.ContainsKey($h)) { return @($script:group[$h]) }
    return @($h)
}

# 光标下那个顶层窗口是不是「这个目标自己人」：目标本身、它的派生窗口，或挂在它们下面的弹窗。
# 不能拿进程当条件——同一个 Chrome 开的另一个主窗口也属于 chrome.exe，但它不是这个目标
function Test-BelongsToGroup([IntPtr]$top, $hwnds) {
    if ($top -eq [IntPtr]::Zero) { return $false }
    foreach ($h in $hwnds) { if ($h -eq $top) { return $true } }
    # 弹窗靠属主挂在主窗口上：沿属主链往上找，碰到这一组里的窗口就算
    $cur = $top
    for ($i = 0; $i -lt 8; $i++) {
        $owner = [Win]::Owner($cur)
        if ($owner -eq [IntPtr]::Zero) { break }
        $cur = [Win]::RootOf($owner)
        foreach ($h in $hwnds) { if ($h -eq $cur) { return $true } }
    }
    return $false
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
    # 每个句柄只判定一次能不能碰
    if (-not $script:checkedWin.ContainsKey($h)) {
        $script:checkedWin[$h] = $true
        # 只有「自己在逐像素分层画」或「自己没有重定向位图（DComp/DXGI 直出）」的窗口不能套统一 alpha：
        # 套上去它整块画不出来变黑，宁可让它保持不透明。
        # 判定条件不能写成「已经 layered」——被强杀之后，我们自己打过的透明度也会留成 layered，
        # 那样下次启动就会把 Chrome、微信这类主窗口永久跳过，滑块怎么拖都不生效
        if ([Win]::LayeredMode($h) -eq 'perpixel' -or [Win]::NoRedirectionBitmap($h)) {
            $script:skipWin[$h] = $true
            Write-UiLog ("跳过 0x{0:X}（{1} - {2}）：它自己用逐像素分层透明，改成统一透明度会让它变黑" -f $h.ToInt64(), [Win]::Proc($h), [Win]::Title($h))
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
    # 一律还成 255（清掉分层位）。不保留「窗口本来就有 alpha 就还回原值」那套：
    # 被强杀之后，那个 alpha 恰恰是我们自己留下的，照着还原等于把窗口永久钉在透明状态
    foreach ($h in @($script:applied.Keys)) {
        if ([Win]::Alive($h)) { [Win]::SetAlpha($h, 255) | Out-Null }
    }
    $script:applied.Clear()
    $script:insideCache.Clear()
    $script:checkedWin.Clear()
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
    # 从 exe 启动时图标由启动器解到 %LOCALAPPDATA%；直接跑 .ps1 时用脚本同目录那份
    $icoPath = $HostedIconPath
    if (-not $icoPath -and $PSScriptRoot) { $icoPath = Join-Path $PSScriptRoot 'TransparentApp.ico' }
    try {
        if ($icoPath -and (Test-Path -LiteralPath $icoPath)) { return (New-Object System.Drawing.Icon($icoPath, $size, $size)) }
    } catch { }
    return [System.Drawing.SystemIcons]::Application
}

# 伪装用图标：运行时画一个时钟（表盘 + 10:10 造型的指针），不依赖任何 ico 文件
$script:clockIconBmp = $null   # 留个引用别让位图被 GC 收走（HICON 已独立，留一份更保险）
function New-ClockIcon([int]$size) {
    $bmp = New-Object System.Drawing.Bitmap($size, $size)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $ink = [System.Drawing.Color]::FromArgb(90, 90, 90)
    $pad = [float]($size * 0.07)
    $penRing = New-Object System.Drawing.Pen($ink, [float][Math]::Max(1.0, $size * 0.09))
    $g.DrawEllipse($penRing, $pad, $pad, [float]($size - 2 * $pad - 1), [float]($size - 2 * $pad - 1))
    $cx = [float]($size / 2.0); $cy = [float]($size / 2.0)
    $penH = New-Object System.Drawing.Pen($ink, [float][Math]::Max(1.0, $size * 0.12))
    $penM = New-Object System.Drawing.Pen($ink, [float][Math]::Max(1.0, $size * 0.08))
    $g.DrawLine($penH, $cx, $cy, [float]($cx - $size * 0.17), [float]($cy - $size * 0.10))
    $g.DrawLine($penM, $cx, $cy, [float]($cx + $size * 0.15), [float]($cy - $size * 0.21))
    $h = $bmp.GetHicon()
    foreach ($p in @($penRing, $penH, $penM)) { $p.Dispose() }
    $g.Dispose()
    $script:clockIconBmp = $bmp
    return [System.Drawing.Icon]::FromHandle($h)
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "时钟"
$form.Icon = New-ClockIcon 32
$form.ClientSize = New-Object System.Drawing.Size(380, 452)
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.StartPosition = 'CenterScreen'
$form.KeyPreview = $true   # Esc 要先到 form：真实面板上按 Esc 切回伪装时钟

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
    # 伪装视图不把选中窗口名亮出来；标题任何时候都不出现 TransparentApp 字样
    if (-not $script:camouflaged -and $script:selected -and [Win]::Alive($script:selected)) { $name = Get-SafeLabel $script:selected }
    if ($name.Length -gt 48) { $name = $name.Substring(0, 48) + "…" }
    $form.Text = if ($name) { "时钟 · $name" } else { "时钟" }
    $lblAlpha.Text = "透明度 $($tbAlpha.Value)%"
}

# ---------------- 伪装视图 ----------------
# 面板打开先给人看一个时钟，双击（或真实面板上按 Esc 反向）才露出真实控件。
# 托盘图标 / 悬停文字 / 窗口标题 / 任务栏分组统一伪装成「时钟」这一个身份
$script:camouflaged = $true
$script:realCtrls = @($lblAlpha, $tbAlpha, $chkStealth, $lblAction, $cbAction, $cbDelay, $chkFollow, $lblTargets, $lbTargets, $btnRefresh, $btnRemove, $btnRestore, $btnExit)

$lblClockTime = New-Object System.Windows.Forms.Label
$lblClockTime.AutoSize = $false
$lblClockTime.Font = New-Object System.Drawing.Font('Segoe UI', 42)
$lblClockTime.TextAlign = 'MiddleCenter'
$lblClockTime.Location = New-Object System.Drawing.Point(12, 140)
$lblClockTime.Size = New-Object System.Drawing.Size(356, 100)
$lblClockDate = New-Object System.Windows.Forms.Label
$lblClockDate.AutoSize = $false
$lblClockDate.Font = New-Object System.Drawing.Font('Segoe UI', 12)
$lblClockDate.TextAlign = 'MiddleCenter'
$lblClockDate.Location = New-Object System.Drawing.Point(12, 248)
$lblClockDate.Size = New-Object System.Drawing.Size(356, 28)
$form.Controls.AddRange(@($lblClockTime, $lblClockDate))

# 中文星期自己映射，不吃系统语言
function Update-ClockLabel {
    $now = Get-Date
    $lblClockTime.Text = $now.ToString('HH:mm:ss')
    $wd = @('星期日', '星期一', '星期二', '星期三', '星期四', '星期五', '星期六')[[int]$now.DayOfWeek]
    $lblClockDate.Text = ("{0}年{1}月{2}日 {3}" -f $now.Year, $now.Month, $now.Day, $wd)
}

function Set-Camouflaged([bool]$on) {
    $script:camouflaged = $on
    foreach ($c in $script:realCtrls) { $c.Visible = -not $on }
    $lblClockTime.Visible = $on
    $lblClockDate.Visible = $on
    if ($on) { Update-ClockLabel }
    Update-AlphaLabel
}

# 只有伪装视图双击才切换；真实面板上双击不做事（防误触）
$onDoubleClickCamouflage = {
    if ($script:camouflaged) {
        Set-Camouflaged $false
        Write-UiLog "面板视图：伪装时钟 -> 真实控件"
    }
}
$lblClockTime.add_DoubleClick($onDoubleClickCamouflage)
$lblClockDate.add_DoubleClick($onDoubleClickCamouflage)
$form.add_DoubleClick($onDoubleClickCamouflage)

# 真实面板上按 Esc 立刻切回时钟；收起再打开也会回到时钟（Show-Panel 里强制）
$form.add_KeyDown({
    param($s, $e)
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape -and -not $script:camouflaged) {
        Set-Camouflaged $true
        Write-UiLog "面板视图：按 Esc 切回伪装时钟"
    }
})

Set-Camouflaged $true   # 第一屏就是时钟

function Get-DelayIndex([int]$ms) {
    for ($i = 0; $i -lt $DelayOptions.Count; $i++) { if ($DelayOptions[$i].ms -eq $ms) { return $i } }
    for ($i = 0; $i -lt $DelayOptions.Count; $i++) { if ($DelayOptions[$i].ms -eq 300000) { return $i } }
    return 0   # 认不出来就用 5 分钟那一档
}

# 显示面板的唯一入口。三处调用（托盘图标 / 托盘菜单 / 再次启动）都走这里，日志才不会有漏
function Show-Panel([string]$why) {
    Set-Camouflaged $true   # 叫出来先回到时钟：别把上次没关的真实面板亮给人看
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
        if ($script:skipWin.ContainsKey($w)) { continue }   # 说不碰的窗口连关都不关
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
            if ($script:skipWin.ContainsKey($w)) { continue }   # 不碰的窗口别去动它的分层属性
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
        if ($script:skipWin.ContainsKey($w)) { continue }   # 不碰的窗口别去动它的分层属性
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
            $tray.ShowBalloonTip(5000, "时钟还在运行",
                "点 X 只是收起面板。要退出请用托盘右键 -> 退出。",
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
    # 布局自检：只查当前可见的控件——伪装视图查时钟那一层，切到真实面板再查控件那一层
    function Test-UiLayout {
        $bad = @()
        $ctrls = @($form.Controls | Where-Object { $_.Visible })
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
        $bad
    }

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
        if ($form.Icon.Width -ne 32) { Write-Host "UITEST FAIL: 任务栏图标不是 32x32，说明窗口图标没设置好" }
        $winIcon = [Win]::GetWindowIcon($form.Handle)
        Write-Host ("UITEST AppUserModelID 设置结果={0}，窗口大图标句柄=0x{1:X}，form.Icon.Handle=0x{2:X}" -f $script:appIdResult, $winIcon.ToInt64(), $form.Icon.Handle.ToInt64())
        if ($winIcon -eq [IntPtr]::Zero) { Write-Host "UITEST FAIL: 窗口没设上自己的图标" }
        if ($winIcon -ne $form.Icon.Handle) { Write-Host "UITEST FAIL: 窗口图标句柄和 form.Icon 不一致" }
        if ($script:appIdResult -ne 0) { Write-Host "UITEST FAIL: AppUserModelID 没设成功（返回值 $($script:appIdResult)），任务栏会退回显示 powershell 图标" }
        Write-Host ("UITEST 延迟档位：{0}" -f (($DelayOptions | ForEach-Object { $_.text }) -join ' / '))

        # 布局自检：控件之间不许互相压住，文字不许超出控件宽度（截图里那种「有遮挡」就是这类问题）。
        # 伪装视图和真实面板视图各查一遍
        $bad = @()
        $lb = Test-UiLayout
        if ($lb) { $bad += $lb }
        Write-Host ("UITEST 伪装视图 时钟可见={0} 真实控件可见={1}（应为 True False）" -f $lblClockTime.Visible, $tbAlpha.Visible)
        if (-not $lblClockTime.Visible) { Write-Host "UITEST FAIL: 面板打开时没有先显示伪装时钟" }
        if ($tbAlpha.Visible) { Write-Host "UITEST FAIL: 伪装视图下真实控件没有藏起来" }
        $onDoubleClickCamouflage.Invoke()   # 等价于双击时钟
        if ($script:camouflaged) { Write-Host "UITEST FAIL: 双击时钟没有切到真实面板" }
        if (-not $tbAlpha.Visible -or $lblClockTime.Visible) { Write-Host "UITEST FAIL: 切换后可见性不对（真实控件应显示、时钟应隐藏）" }
        $lb = Test-UiLayout
        if ($lb) { $bad += $lb }
        Write-Host ("UITEST 真实面板视图 时钟可见={0} 真实控件可见={1}（应为 False True）" -f $lblClockTime.Visible, $tbAlpha.Visible)
        if ($bad.Count -gt 0) {
            foreach ($b in $bad) { Write-Host "UITEST FAIL: $b" }
        } else {
            Write-Host "UITEST 布局自检通过（伪装视图 + 真实面板视图都查过）"
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
$tray.Icon = New-ClockIcon ([System.Windows.Forms.SystemInformation]::SmallIconSize.Width)
$tray.Text = "时钟"

# 菜单一次性建好，不在 Opening 里重建：重建要枚举窗口 + 查进程名，慢到右击要点好几次才弹
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miShow = New-Object System.Windows.Forms.ToolStripMenuItem("打开")
$miShow.add_Click({
    param($s, $e)
    Show-Panel "从托盘菜单点「显示控制面板」"
})
$menu.Items.Add($miShow) | Out-Null
$miRestore = New-Object System.Windows.Forms.ToolStripMenuItem("恢复全部窗口")
$miRestore.add_Click({ param($s, $e) Restore-All })
$menu.Items.Add($miRestore) | Out-Null
$miExit = New-Object System.Windows.Forms.ToolStripMenuItem("退出")
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
    # 伪装时钟每秒走一格；只在可见且文字变化时才更新，别让 Label 每 200ms 白重绘
    if ($lblClockTime.Visible) {
        $clockText = (Get-Date).ToString('HH:mm:ss')
        if ($clockText -ne $lblClockTime.Text) { Update-ClockLabel }
    }
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
    $topAt = [Win]::RootOf([Win]::WindowAt($x, $y))
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

        # 光标落在「这个目标自己人」身上才算在里面；否则再看是否落在某个窗口矩形内、
        # 并且那个窗口压在光标下那个窗口上面（alpha 0 时点不通，只能靠 z 序判断）
        $inside = Test-BelongsToGroup $topAt $hwnds
        if (-not $inside) {
            foreach ($h in $hwnds) {
                if ([Win]::Minimized($h)) { continue }
                $l = 0; $t = 0; $r = 0; $b = 0
                if (-not [Win]::Rect($h, [ref]$l, [ref]$t, [ref]$r, [ref]$b)) { continue }
                if ($x -lt $l -or $x -ge $r -or $y -lt $t -or $y -ge $b) { continue }
                if ([Win]::Above($h, $topAt)) { $inside = $true; break }
            }
        }

        $restored = $false
        foreach ($h in $hwnds) {
            if (-not [Win]::Alive($h)) { continue }
            if (-not $script:joinedAt.ContainsKey($h)) { $script:joinedAt[$h] = $now }
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
            if ($script:skipWin.ContainsKey($h)) { continue }   # 说不碰的窗口，最小化也别做
            # 刚进组的先给两秒观察期：新建窗口的头两秒常常没有标题，别把它当派生窗口收走
            if ($script:joinedAt.ContainsKey($h) -and ($now - $script:joinedAt[$h]).TotalSeconds -lt 2) { continue }
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
    # 宿主模式下看门狗就是同一个 exe 的 --watchdog 模式，不再拉 powershell 子进程
    $wdCmd = if ($HostedExe) {
        '"{0}" --watchdog {1}' -f $HostedExe, $PID
    } else {
        'powershell.exe -WindowStyle Hidden -NoProfile -ExecutionPolicy Bypass -File "{0}" -Watchdog {1}' -f $PSCommandPath, $PID
    }
    $started = $false
    try {
        $r = ([wmiclass]'Win32_Process').Create($wdCmd)
        if ($null -ne $r -and $r.ReturnValue -eq 0) { $started = $true }
    } catch { }
    if (-not $started) {
        # WMI 起不来时退回进程树内兜一个：被「结束任务树」连带杀时靠 live.json 在下次启动补还原
        try {
            if ($HostedExe) {
                Start-Process -FilePath $HostedExe -ArgumentList '--watchdog', $PID -WindowStyle Hidden
            } else {
                Start-Process powershell -ArgumentList '-WindowStyle', 'Hidden', '-NoProfile', '-ExecutionPolicy', 'Bypass',
                    '-File', "`"$PSCommandPath`"", '-Watchdog', $PID -WindowStyle Hidden
            }
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
