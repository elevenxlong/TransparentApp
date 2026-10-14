#requires -version 5.1
<#
把 TransparentApp.ps1 + TransparentApp.ico + Launcher.cs 打包成单个 dist\TransparentApp.exe。
用 Windows 自带 .NET Framework 的 csc.exe 编译：不需要装 SDK、不需要联网。

用法：
  powershell -ExecutionPolicy Bypass -File .\build.ps1
  powershell -ExecutionPolicy Bypass -File .\build.ps1 -Run     # 打完直接启动
#>
param([switch]$Run)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

$csc = $null
foreach ($frameworkDir in "$env:WINDIR\Microsoft.NET\Framework64", "$env:WINDIR\Microsoft.NET\Framework") {
    if (Test-Path $frameworkDir) {
        $csc = Get-ChildItem $frameworkDir -Recurse -Filter csc.exe -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending | Select-Object -First 1
        if ($csc) { break }
    }
}
if (-not $csc) { throw "找不到 csc.exe；需要 .NET Framework 4.x（Windows 自带，装个 .NET Framework 运行时即可）" }

foreach ($f in 'TransparentApp.ps1', 'TransparentApp.ico', 'Launcher.cs') {
    if (-not (Test-Path (Join-Path $root $f))) { throw "缺少打包素材：$f" }
}

$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Path $dist -Force | Out-Null
$exe = Join-Path $dist 'TransparentApp.exe'

$cscArgs = @(
    '/nologo', '/target:winexe', '/platform:anycpu', '/optimize+'
    "/win32icon:$root\TransparentApp.ico"
    "/resource:$root\TransparentApp.ps1,app.ps1"
    "/resource:$root\TransparentApp.ico,app.ico"
    "/out:$exe"
    (Join-Path $root 'Launcher.cs')
)
& $csc.FullName @cscArgs
if ($LASTEXITCODE -ne 0) { throw "编译失败，csc exit=$LASTEXITCODE" }
if (-not (Test-Path $exe)) { throw "编译没报错但没生成 $exe" }

$item = Get-Item $exe
Write-Host ("打包完成：{0}（{1:N0} KB）" -f $item.FullName, ($item.Length / 1KB))

# 使用说明跟 exe 放在一起，拿到 dist 目录就能直接用
$doc = Join-Path $root '使用说明.txt'
if (Test-Path $doc) {
    Copy-Item -LiteralPath $doc -Destination (Join-Path $dist '使用说明.txt') -Force
    Write-Host "已附上使用说明：$(Join-Path $dist '使用说明.txt')"
}
Write-Host "双击 exe 即可运行；启动时会把脚本解到 %LOCALAPPDATA%\TransparentApp 再拉起。"

if ($Run) { Start-Process $exe }
