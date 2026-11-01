#Requires -Version 5.1
<#
.SYNOPSIS
    War Thunder × Steam 启动修复助手

.DESCRIPTION
    把官方启动器下载的「最小化客户端」放进 Steam 库的 common 目录，
    再让 Steam 认为该游戏已是最新（跳过约 88 GB 的 depot 更新），
    从而可以在 Steam 里直接「开始游戏」，并继续用 Steam 账号登录。

    工具会：
      1. 自动定位 Steam、库目录、游戏目录，检查缺什么
      2. 引导你指定最小化客户端所在文件夹，搬进 common\War Thunder
      3. 关闭 Steam，备份并重写 appmanifest_236390.acf
      4. 重启 Steam（可选直接拉起游戏）

.PARAMETER SteamPath
    Steam 安装目录（含 steam.exe）。默认从注册表自动检测。

.PARAMETER LibraryPath
    目标 Steam 库目录（含 steamapps）。默认自动挑选已装有 War Thunder 的库。

.PARAMETER SourcePath
    最小化客户端所在文件夹（含 launcher.exe、win64\aces.exe 等）。

.PARAMETER WorkDir
    下载/临时目录，默认 %TEMP%\wt-steamfix

.PARAMETER DownloadClient
    自动下载官方启动器并安装到 WorkDir，由启动器下载最小化客户端

.PARAMETER SkipMove
    跳过搬运，仅修复 Steam 清单（游戏文件已经在 common 目录里）

.PARAMETER NoLaunch
    修复完只启动 Steam，不自动拉起游戏

.PARAMETER DryRun
    只检测和预览，不关 Steam、不动文件、不写清单

.PARAMETER Yes
    无人值守，使用默认选项

.EXAMPLE
    .\WT-SteamFix.ps1
    .\WT-SteamFix.ps1 -DryRun
    .\WT-SteamFix.ps1 -DownloadClient
#>
[CmdletBinding()]
param(
    [string]$SteamPath,
    [string]$LibraryPath,
    [string]$SourcePath,
    [string]$WorkDir,
    [switch]$DownloadClient,
    [switch]$SkipMove,
    [switch]$NoLaunch,
    [switch]$DryRun,
    [switch]$Yes,
    [switch]$SelfTest,
    [string]$Proxy,
    [string]$InstallerPath,
    [switch]$Simulate,
    [switch]$UndoSimulate,
    [switch]$Snapshot
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# ============================================================
#  全局状态
# ============================================================
$script:AppId     = '236390'
$script:GameName  = 'War Thunder'
$script:ToolRoot  = if ($env:WT_TOOLROOT) { $env:WT_TOOLROOT } elseif ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$script:DryRun    = [bool]$DryRun
$script:AssumeYes = [bool]$Yes
$script:NoLaunch  = [bool]$NoLaunch
$script:WorkDir   = if ($WorkDir) { $WorkDir } else { Join-Path $script:ToolRoot '.work' }
$script:SelfTestMode = [bool]$SelfTest

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$script:LogDir  = Join-Path $script:ToolRoot 'logs'
$script:LogPath = Join-Path $script:LogDir ("wtfix_{0}.log" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
New-Item -ItemType Directory -Force -Path $script:LogDir | Out-Null

# ============================================================
#  输出 / 交互
# ============================================================
function Write-Log {
    param([string]$Message, [string]$Color = 'Gray')
    Write-Host $Message -ForegroundColor $Color
    try {
        Add-Content -LiteralPath $script:LogPath -Value ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), ($Message -replace "`r", '')) -Encoding UTF8
    } catch { }
}

function Write-Head {
    param([string]$Message)
    Write-Host ''
    Write-Host ('─' * 66) -ForegroundColor DarkGray
    Write-Host ("  $Message") -ForegroundColor White
    Write-Host ('─' * 66) -ForegroundColor DarkGray
}

function Write-Step { param([string]$m) Write-Log ("[*] $m") 'Cyan' }
function Write-Ok   { param([string]$m) Write-Log ("[+] $m") 'Green' }
function Write-Warn { param([string]$m) Write-Log ("[!] $m") 'Yellow' }
function Write-Err  { param([string]$m) Write-Log ("[x] $m") 'Red' }
function Write-Info { param([string]$m) Write-Log ("    $m") 'Gray' }

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    return ('{0:N0} KB' -f ($Bytes / 1KB))
}

function Get-DisplayWidth {
    param([string]$Text)
    $w = 0
    foreach ($ch in $Text.ToCharArray()) {
        $c = [int]$ch
        if (($c -ge 0x1100 -and $c -le 0x115F) -or
            ($c -ge 0x2E80 -and $c -le 0xA4CF) -or
            ($c -ge 0xAC00 -and $c -le 0xD7A3) -or
            ($c -ge 0xF900 -and $c -le 0xFAFF) -or
            ($c -ge 0xFE30 -and $c -le 0xFE6F) -or
            ($c -ge 0xFF00 -and $c -le 0xFF60) -or
            ($c -ge 0xFFE0 -and $c -le 0xFFE6)) { $w += 2 } else { $w += 1 }
    }
    return $w
}

function Pad-Display {
    param([string]$Text, [int]$Width)
    $w = Get-DisplayWidth -Text $Text
    if ($w -ge $Width) { return $Text }
    return ($Text + (' ' * ($Width - $w)))
}

# 把控制台窗口拉到最前，避免双击后键盘输入跑到别的窗口
function Focus-ConsoleWindow {
    try {
        if (-not ('WTWin32' -as [type])) {
            Add-Type -Namespace WT -Name Win32 -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern System.IntPtr GetConsoleWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool SetForegroundWindow(System.IntPtr hWnd);
'@ -ErrorAction Stop
        }
        $h = [WT.Win32]::GetConsoleWindow()
        if ($h -ne [System.IntPtr]::Zero) { [void][WT.Win32]::SetForegroundWindow($h) }
    } catch { }
}

# 按任意键继续；带超时自动继续，避免"按了没反应"卡住
function Wait-AnyKey {
    param([string]$Prompt = '按任意键继续', [int]$TimeoutSec = 0, [switch]$Silent)

    if ([Console]::IsInputRedirected) {
        if (-not $Silent) { Write-Host $Prompt -NoNewline }
        Read-Host | Out-Null
        if (-not $Silent) { Write-Host '' }
        return
    }

    if (-not $Silent) {
        if ($TimeoutSec -gt 0) { Write-Host ("{0}（{1} 秒后自动继续）" -f $Prompt, $TimeoutSec) -NoNewline }
        else { Write-Host $Prompt -NoNewline }
    }

    $deadline = if ($TimeoutSec -gt 0) { (Get-Date).AddSeconds($TimeoutSec) } else { [datetime]::MaxValue }
    while ((Get-Date) -lt $deadline) {
        try {
            if ([Console]::KeyAvailable) {
                [void][Console]::ReadKey($true)
                if (-not $Silent) { Write-Host '' }
                return $true
            }
        } catch { return $false }
        Start-Sleep -Milliseconds 120
    }
    if (-not $Silent) { Write-Host '' }
    return $false
}

function Ask-YesNo {
    param([string]$Question, [bool]$Default = $true)
    if ($script:AssumeYes) { return $Default }
    $hint = if ($Default) { '[Y/n]' } else { '[y/N]' }
    while ($true) {
        Write-Host ("{0} {1} " -f $Question, $hint) -ForegroundColor Yellow -NoNewline
        $a = Read-Host
        if ([string]::IsNullOrWhiteSpace($a)) { return $Default }
        switch ($a.Trim().ToLower()) {
            'y' { return $true }
            'yes' { return $true }
            'n' { return $false }
            'no' { return $false }
        }
    }
}

function Pause-Any {
    param([string]$Text = '按回车继续...')
    if ($script:AssumeYes) { return }
    Write-Host ''
    Read-Host $Text | Out-Null
}

# ============================================================
#  探测
# ============================================================
function Get-SteamRoot {
    $cands = New-Object System.Collections.Generic.List[string]
    foreach ($k in 'HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'HKLM:\SOFTWARE\Valve\Steam') {
        $v = Get-ItemProperty -Path $k -ErrorAction SilentlyContinue
        if ($v) {
            if ($v.SteamPath)   { $cands.Add($v.SteamPath) }
            if ($v.InstallPath) { $cands.Add($v.InstallPath) }
        }
    }
    foreach ($p in 'C:\Program Files (x86)\Steam', 'C:\Program Files\Steam', 'D:\Steam', 'E:\steam', 'E:\Steam', 'F:\Steam', 'G:\Steam') { $cands.Add($p) }
    foreach ($c in $cands) {
        if ([string]::IsNullOrWhiteSpace($c)) { continue }
        $c = $c.Trim().Replace('/', '\').TrimEnd('\')
        if (Test-Path -LiteralPath (Join-Path $c 'steam.exe')) { return $c }
    }
    return $null
}

function Get-SteamLibraries {
    param([string]$SteamRoot)
    $libs = New-Object System.Collections.Generic.List[string]
    $seen = New-Object System.Collections.Generic.List[string]

    $addLib = {
        param($p)
        if ([string]::IsNullOrWhiteSpace($p)) { return }
        $v = $p.Trim().TrimEnd('\')
        if ($v -eq '') { return }
        if ($seen.Contains($v.ToLower())) { return }
        $seen.Add($v.ToLower())
        $libs.Add($v)
    }

    $mainApps = Join-Path $SteamRoot 'steamapps'
    $vdf = Join-Path $mainApps 'libraryfolders.vdf'
    if (Test-Path -LiteralPath $vdf) {
        $txt = Get-Content -LiteralPath $vdf -Raw -ErrorAction SilentlyContinue
        if ($txt) {
            foreach ($m in [regex]::Matches($txt, '"path"\s+"([^"]+)"')) {
                & $addLib ($m.Groups[1].Value -replace '\\\\', '\')
            }
        }
    }
    & $addLib $SteamRoot
    return $libs
}

function Get-DirStats {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]@{ Bytes = 0; Files = 0 } }
    $sum = Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
           Measure-Object -Property Length -Sum
    return [pscustomobject]@{ Bytes = [int64]($sum.Sum); Files = [int]($sum.Count) }
}

function Test-WTInstall {
    param([string]$Path)
    $must = @('launcher.exe', 'win64\aces.exe', 'aces.vromfs.bin', 'content\warthunder.blk')
    $missing = @()
    foreach ($m in $must) {
        if (-not (Test-Path -LiteralPath (Join-Path $Path $m))) { $missing += $m }
    }
    $st = Get-DirStats -Path $Path
    return [pscustomobject]@{
        Path    = $Path
        Valid   = ($missing.Count -eq 0)
        Missing = $missing
        Bytes   = $st.Bytes
        Files   = $st.Files
    }
}

function Find-WTInstalls {
    param([string[]]$Exclude)
    $found = New-Object System.Collections.Generic.List[string]
    $ex = @()
    foreach ($e in $Exclude) { if ($e) { $ex += $e.TrimEnd('\').ToLower() } }

    # 只看内容，不看文件夹叫什么：官方启动器叫 WarThunder，Steam 叫 War Thunder
    $isClient = { param($d) Test-Path -LiteralPath (Join-Path $d 'win64\aces.exe') }
    $add = {
        param($d)
        if (-not $d) { return }
        if ($ex -contains $d.TrimEnd('\').ToLower()) { return }
        if (-not $found.Contains($d)) { $found.Add($d) }
    }

    # 1) 各磁盘根目录、以及下一层（G:\WarThunder、C:\Games\WarThunder ……）
    foreach ($drv in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        $root = ($drv.Name + ':\')
        if (-not (Test-Path -LiteralPath $root)) { continue }

        foreach ($d1 in (Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue)) {
            if (& $isClient $d1.FullName) { & $add $d1.FullName; continue }
            foreach ($d2 in (Get-ChildItem -LiteralPath $d1.FullName -Directory -Force -ErrorAction SilentlyContinue)) {
                if (& $isClient $d2.FullName) { & $add $d2.FullName }
            }
        }
    }

    # 2) Steam 库内部：common\* 和 downloading\<appid>（目录名可能是 WarThunder 或 War Thunder）
    $steamRoot = $null
    try { $steamRoot = Get-SteamRoot } catch { }
    if ($steamRoot) {
        foreach ($lib in (Get-SteamLibraries -SteamRoot $steamRoot)) {
            $common = Join-Path $lib 'steamapps\common'
            foreach ($d in (Get-ChildItem -LiteralPath $common -Directory -Force -ErrorAction SilentlyContinue)) {
                if (& $isClient $d.FullName) { & $add $d.FullName }
            }
            $staged = Join-Path $lib ("steamapps\downloading\{0}" -f $script:AppId)
            if (& $isClient $staged) { & $add $staged }
        }
    }

    return ($found | Select-Object -Unique)
}

function Get-LibraryFree {
    param([string]$LibPath)
    $drv = $LibPath.Substring(0, 1)
    try { return [int64](Get-PSDrive -Name $drv -ErrorAction SilentlyContinue).Free } catch { return 0 }
}

# 没有安装记录时，选一个 Steam 库
function Select-GameLibrary {
    param([string[]]$Libraries)

    $info = @()
    foreach ($l in $Libraries) {
        $info += [pscustomobject]@{ Path = $l; Free = (Get-LibraryFree -LibPath $l) }
    }
    if ($info.Count -eq 0) { throw '没找到任何 Steam 游戏库' }

    $best = ($info | Sort-Object Free -Descending | Select-Object -First 1)
    if ($script:AssumeYes -or $script:SelfTestMode -or $info.Count -le 1) {
        if ($script:SelfTestMode -and $info.Count -gt 1) { Write-Info '（检测模式自动选剩余空间最大的库；实际运行会让你选）' }
        return $best.Path
    }

    Write-Host ''
    Write-Info '还没有战雷的安装记录，请选择要装进哪个 Steam 库：'
    for ($i = 0; $i -lt $info.Count; $i++) {
        Write-Host ("   [{0}] {1}   剩余 {2}" -f ($i + 1), $info[$i].Path, (Format-Size $info[$i].Free))
    }
    $defIdx = [array]::IndexOf($info.Path, $best.Path) + 1
    while ($true) {
        $a = Read-Host ("  输入数字后回车（默认 {0}）" -f $defIdx)
        if ([string]::IsNullOrWhiteSpace($a)) { return $best.Path }
        $n = 0
        if ([int]::TryParse($a.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $info.Count) { return $info[$n - 1].Path }
        Write-Host '  请输入列表里的数字' -ForegroundColor DarkYellow
    }
}

function Get-Environment {
    $steamRoot = if ($SteamPath) { $SteamPath.TrimEnd('\') } else { Get-SteamRoot }
    if (-not $steamRoot) { throw '没有找到 Steam，请用 -SteamPath 指定 Steam 目录（含 steam.exe）' }

    $libs = Get-SteamLibraries -SteamRoot $steamRoot

    $lib = $null
    if ($LibraryPath) {
        $lib = $LibraryPath.TrimEnd('\')
    } else {
        $preferred = @()
        foreach ($l in $libs) {
            $acf = Join-Path $l ("steamapps\appmanifest_{0}.acf" -f $script:AppId)
            if (Test-Path -LiteralPath $acf) { $preferred += $l; continue }

            # 只有目录里确实有客户端内容才算"已经在这里"，空目录不算
            $dir = Join-Path $l 'steamapps\common\War Thunder'
            if (Test-Path -LiteralPath $dir) {
                $probe = Get-DirStats -Path $dir
                if ($probe.Files -gt 0) { $preferred += $l }
            }
        }
        if ($preferred.Count -gt 0) { $lib = $preferred[0] } else { $lib = Select-GameLibrary -Libraries $libs }
    }

    $gameDir = Join-Path $lib 'steamapps\common\War Thunder'
    $acfPath = Join-Path $lib ("steamapps\appmanifest_{0}.acf" -f $script:AppId)

    # 常见误放：官方启动器的目录名是 WarThunder（没有空格）
    $altGameDir = Join-Path $lib 'steamapps\common\WarThunder'

    $driveLetter = ($gameDir.Substring(0, 1))
    $free = 0
    try { $free = (Get-PSDrive -Name $driveLetter -ErrorAction SilentlyContinue).Free } catch { }

    # 供 Stop-SteamProcess 等函数使用的全局上下文
    $script:SteamRoot = $steamRoot
    $script:Library   = $lib
    $script:GameDir   = $gameDir
    $script:AcfPath   = $acfPath

    return [pscustomobject]@{
        SteamRoot  = $steamRoot
        Libraries  = $libs
        Library    = $lib
        GameDir    = $gameDir
        AltGameDir = $altGameDir
        AltGame    = (Test-WTInstall -Path $altGameDir)
        AcfPath    = $acfPath
        AcfExists  = (Test-Path -LiteralPath $acfPath)
        Game       = (Test-WTInstall -Path $gameDir)
        FreeBytes  = [int64]$free
    }
}

function Show-Environment {
    param($Env)
    Write-Head '检查结果'

    $g = $Env.Game
    if ($g.Valid) {
        $gameText = ("已就绪（{0}，{1} 个文件）" -f (Format-Size $g.Bytes), $g.Files)
    }
    elseif ($g.Files -gt 0) {
        $gameText = ("不完整，缺少：{0}" -f ($g.Missing -join '、'))
    }
    else {
        $gameText = '还没有客户端'
    }

    $rows = @(
        @('Steam 装在',  $Env.SteamRoot),
        @('游戏库',      $Env.Library),
        @('游戏目录',    $Env.GameDir),
        @('游戏文件',    $gameText),
        @('Steam 记录',  $(if ($Env.AcfExists) { '有（可以修）' } else { '没有（Steam 里可能还没这个游戏）' })),
        @('磁盘剩余',    (Format-Size $Env.FreeBytes))
    )
    foreach ($r in $rows) {
        Write-Host ('  ' + (Pad-Display -Text $r[0] -Width 12)) -ForegroundColor DarkGray -NoNewline
        Write-Host $r[1]
    }

    # 常见情况：客户端被放进了没有空格的 WarThunder
    if (-not $Env.Game.Valid -and $Env.AltGame -and $Env.AltGame.Valid) {
        Write-Host ''
        Write-Warn ('检测到 {0}' -f $Env.AltGameDir)
        Write-Warn ('但 Steam 认的是 "{0}"（中间有空格），那个位置它不认' -f $Env.GameDir)
    }
}

# ============================================================
#  目录准备 / 自检 / 诊断
# ============================================================
function Initialize-Workspace {
    param($Env)
    if ($script:DryRun) { return }
    $dirs = New-Object System.Collections.Generic.List[string]
    $dirs.Add($script:ToolRoot)
    $dirs.Add($script:LogDir)
    $dirs.Add((Join-Path $script:ToolRoot 'backup'))
    $dirs.Add((Join-Path $script:ToolRoot 'snapshots'))
    $dirs.Add($script:WorkDir)
    if ($Env) {
        if ($Env.GameDir) {
            $dirs.Add((Split-Path $Env.GameDir -Parent))
            $dirs.Add($Env.GameDir)
        }
        if ($Env.Library) { $dirs.Add((Join-Path $Env.Library 'steamapps\downloading')) }
    }

    $made = 0
    foreach ($d in $dirs) {
        if ([string]::IsNullOrWhiteSpace($d)) { continue }
        if (-not (Test-Path -LiteralPath $d)) {
            try { New-Item -ItemType Directory -Force -Path $d | Out-Null; $made++ } catch { }
        }
    }
    if ($made -gt 0) { Write-Info ("已自动创建 {0} 个需要的文件夹" -f $made) }
}

function Test-Writable {
    param([string]$Dir)
    try {
        if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Force -Path $Dir | Out-Null }
        $f = Join-Path $Dir ('.wtfix_' + [guid]::NewGuid().ToString('N') + '.tmp')
        Set-Content -LiteralPath $f -Value 'x' -ErrorAction Stop
        Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
        return $true
    } catch { return $false }
}

function Test-Preflight {
    param($Env)
    $passed = New-Object System.Collections.Generic.List[string]
    $notes  = New-Object System.Collections.Generic.List[string]
    $issues = New-Object System.Collections.Generic.List[string]

    # Steam 本体
    if (Test-Path -LiteralPath (Join-Path $Env.SteamRoot 'steam.exe')) {
        $passed.Add('找到了 Steam')
    } else {
        $issues.Add(("找不到 Steam：{0}\steam.exe —— 用 -SteamPath 指定 Steam 安装目录" -f $Env.SteamRoot))
    }

    # 游戏库 / 游戏父目录可写
    $commonDir = Split-Path $Env.GameDir -Parent
    if ($script:DryRun) {
        $notes.Add('演练模式：跳过写权限检测')
    }
    elseif (Test-Writable -Dir $commonDir) {
        $passed.Add('游戏目录可以写入')
    } else {
        $issues.Add(("没有写权限：{0} —— 请以管理员身份重新运行" -f $commonDir))
    }

    # Steam 记录文件
    if ($Env.AcfExists) {
        if ($script:DryRun) { }
        elseif (Test-Writable -Dir $Env.Library) { $passed.Add('Steam 安装记录可以修改') }
        else { $issues.Add(("没有写权限：{0}" -f (Join-Path $Env.Library 'steamapps'))) }
    } else {
        $notes.Add('Steam 里还没有这个游戏的安装记录，修复时会新建一份')
    }

    # 磁盘
    if ($Env.FreeBytes -lt 1GB) {
        $issues.Add(("{0} 盘只剩 {1}，至少留 1 GB 才能正常工作" -f $Env.GameDir.Substring(0, 1), (Format-Size $Env.FreeBytes)))
    } else {
        $passed.Add(("磁盘剩余 {0}" -f (Format-Size $Env.FreeBytes)))
    }

    # 工具目录
    if (Test-Writable -Dir $script:ToolRoot) {
        $passed.Add('程序目录可以写日志和备份')
    } else {
        $notes.Add('程序目录不可写（日志会放到临时目录）')
    }

    # 管理员
    $isAdmin = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($isAdmin) { $notes.Add('当前是管理员权限') } else { $notes.Add('当前不是管理员（一般不影响，遇到拒绝访问再右键管理员运行）') }

    return [pscustomobject]@{ Passed = $passed; Notes = $notes; Issues = $issues; Ok = ($issues.Count -eq 0) }
}

function Show-Preflight {
    param($Check)
    foreach ($n in $Check.Passed) { Write-Host ('  [√] ' + $n) -ForegroundColor DarkGreen }
    foreach ($n in $Check.Notes)  { Write-Host ('  [·] ' + $n) -ForegroundColor DarkGray }
    foreach ($n in $Check.Issues) { Write-Host ('  [!] ' + $n) -ForegroundColor Yellow }
}

function Write-Diagnostic {
    param($Env, [string]$Reason)
    try {
        $path = Join-Path $script:LogDir ("diagnostic_{0}.txt" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
        $isAdmin = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        $L = New-Object System.Collections.Generic.List[string]
        $L.Add('=== WT-SteamFix 诊断报告 ===')
        $L.Add(("时间        : {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')))
        $L.Add(("原因        : {0}" -f $Reason))
        $L.Add(("系统        : {0}  64位={1}" -f [Environment]::OSVersion.VersionString, [Environment]::Is64BitOperatingSystem))
        $L.Add(("用户        : {0}  管理员={1}" -f [Security.Principal.WindowsIdentity]::GetCurrent().Name, $isAdmin))
        $L.Add(("PowerShell  : {0}" -f $PSVersionTable.PSVersion))
        $L.Add(("程序目录    : {0}" -f $script:ToolRoot))
        if ($Env) {
            $L.Add(("Steam       : {0}" -f $Env.SteamRoot))
            $L.Add(("游戏库      : {0}" -f $Env.Library))
            $L.Add(("游戏目录    : {0}" -f $Env.GameDir))
            $L.Add(("Steam 记录  : {0}  存在={1}" -f $Env.AcfPath, $Env.AcfExists))
            $L.Add(("游戏文件    : {0} 个 / {1}  完整={2}" -f $Env.Game.Files, (Format-Size $Env.Game.Bytes), $Env.Game.Valid))
            $L.Add(("剩余空间    : {0}" -f (Format-Size $Env.FreeBytes)))
        }
        $L.Add(("本次日志    : {0}" -f $script:LogPath))
        Set-Content -LiteralPath $path -Value ($L -join "`r`n") -Encoding UTF8
        return $path
    } catch { return $null }
}

# ============================================================
#  搬运
# ============================================================
$script:MvBytes = 0
$script:MvFiles = 0
$script:MvTotalBytes = 0
$script:MvTotalFiles = 0

function Write-TransferProgress {
    if ($script:MvTotalBytes -le 0) { return }
    $pct = [Math]::Min(100, [Math]::Floor($script:MvBytes * 100 / $script:MvTotalBytes))
    $barLen = 26
    $fill = [int][Math]::Floor($barLen * $pct / 100)
    $bar = ('#' * $fill) + ('-' * ($barLen - $fill))
    $line = ("  [{0}] {1,3}%   {2} / {3}   {4}/{5} 个文件" -f $bar, $pct, (Format-Size $script:MvBytes), (Format-Size $script:MvTotalBytes), $script:MvFiles, $script:MvTotalFiles)
    Write-Host ($line.PadRight(110)) -NoNewline -ForegroundColor DarkGray
}

function Move-Node {
    param([string]$Path, [string]$Target)
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSIsContainer) {
        if (-not (Test-Path -LiteralPath $Target)) { New-Item -ItemType Directory -Path $Target -Force | Out-Null }
        foreach ($child in (Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)) {
            Move-Node -Path $child.FullName -Target (Join-Path $Target $child.Name)
        }
        if (-not (Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)) {
            Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        }
    } else {
        $sz = [int64]$item.Length
        if (Test-Path -LiteralPath $Target) { Remove-Item -LiteralPath $Target -Force -ErrorAction SilentlyContinue }
        Move-Item -LiteralPath $Path -Destination $Target -Force
        $script:MvBytes += $sz
        $script:MvFiles++
        if (($script:MvFiles % 20) -eq 0) { Write-TransferProgress }
    }
}

function Move-ClientIntoLibrary {
    param([string]$Source, [string]$Dest)

    $srcFull = [System.IO.Path]::GetFullPath($Source).TrimEnd('\')
    $dstFull = [System.IO.Path]::GetFullPath($Dest).TrimEnd('\')

    if ($srcFull.Equals($dstFull, [StringComparison]::OrdinalIgnoreCase)) {
        Write-Info '源目录就是目标目录，跳过搬运'
        return $true
    }
    if ($dstFull.StartsWith($srcFull + '\', [StringComparison]::OrdinalIgnoreCase) -or
        $srcFull.StartsWith($dstFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
        Write-Err '源目录和目标目录互相包含，拒绝执行'
        return $false
    }

    $stat = Get-DirStats -Path $srcFull
    if ($stat.Files -eq 0) { Write-Err "源目录里没有文件：$srcFull"; return $false }

    $srcDrive = $srcFull.Substring(0, 1)
    $dstDrive = $dstFull.Substring(0, 1)
    $sameVolume = $srcDrive.Equals($dstDrive, [StringComparison]::OrdinalIgnoreCase)

    Write-Step ("搬运 {0} 个文件 / {1}" -f $stat.Files, (Format-Size $stat.Bytes))
    if ($sameVolume) { Write-Info '同盘操作，按目录项移动（很快）' } else { Write-Info '跨盘操作，需要复制 + 删除源文件' }

    if (-not $sameVolume) {
        $dstFree = (Get-PSDrive -Name $dstDrive -ErrorAction SilentlyContinue).Free
        if ($dstFree -lt ($stat.Bytes * 1.02) -and $env:TEMP) {
            Write-Warn ("目标盘剩余 {0}，小于待搬运 {1}" -f (Format-Size $dstFree), (Format-Size $stat.Bytes))
            if (-not (Ask-YesNo '仍然继续？（可能中途空间不足）' $false)) { return $false }
        }
    }

    if ($script:DryRun) {
        Write-Info ('【DryRun】将把 {0} 的内容合并到 {1}' -f $srcFull, $dstFull)
        return $true
    }

    New-Item -ItemType Directory -Force -Path $dstFull | Out-Null

    $script:MvBytes = 0
    $script:MvFiles = 0
    $script:MvTotalBytes = $stat.Bytes
    $script:MvTotalFiles = $stat.Files

    foreach ($child in (Get-ChildItem -LiteralPath $srcFull -Force -ErrorAction SilentlyContinue)) {
        Move-Node -Path $child.FullName -Target (Join-Path $dstFull $child.Name)
    }
    Write-Host ''

    # 清掉搬空的源目录（如果用户给的是父目录，就留一层）
    $left = Get-ChildItem -LiteralPath $srcFull -Force -ErrorAction SilentlyContinue
    if ($left.Count -eq 0) { Remove-Item -LiteralPath $srcFull -Force -ErrorAction SilentlyContinue }

    $after = Test-WTInstall -Path $dstFull
    if ($after.Valid) {
        Write-Ok ("搬运完成：{0} / {1} 个文件" -f (Format-Size $after.Bytes), $after.Files)
        return $true
    }
    Write-Err ("搬运后仍缺文件：{0}" -f ($after.Missing -join '、'))
    return $false
}

# ============================================================
#  steamcmd / 清单
# ============================================================
function Get-SteamCmd {
    # 打包成 exe 时由宿主指定（解压在 %LOCALAPPDATA%\WT-SteamFix\steamcmd）
    if ($env:WT_STEAMCMD -and (Test-Path -LiteralPath $env:WT_STEAMCMD)) { return $env:WT_STEAMCMD }

    $exe = Join-Path $script:ToolRoot 'steamcmd\steamcmd.exe'
    if (Test-Path -LiteralPath $exe) { return $exe }

    if ($script:DryRun) { throw "缺 steamcmd：$exe（DryRun 不会自动下载，请先运行一次不带 -DryRun 的工具）" }

    Write-Step '本机没有 steamcmd，正在下载（约 1 MB）...'
    $dir = Join-Path $script:ToolRoot 'steamcmd'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $zip = Join-Path $dir 'steamcmd.zip'
    Invoke-WebRequest -Uri 'https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip' -OutFile $zip -UseBasicParsing -TimeoutSec 120
    Expand-Archive -LiteralPath $zip -DestinationPath $dir -Force
    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path -LiteralPath $exe)) { throw 'steamcmd 解压失败' }
    Write-Ok 'steamcmd 就绪'
    return $exe
}

function Initialize-SteamCmd {
    param([string]$SteamCmdExe)
    $marker = Join-Path (Split-Path $SteamCmdExe -Parent) '.initialized'
    if (Test-Path -LiteralPath $marker) { return $true }

    Write-Step '首次运行，steamcmd 正在自我更新（约 1 分钟，网络慢时会久一点）...'
    $p = $null
    try {
        $p = Start-Process -FilePath $SteamCmdExe -ArgumentList '+quit' -PassThru -WindowStyle Hidden
        if (-not $p.WaitForExit(240000)) {
            try { $p.Kill() } catch { }
            Write-Warn 'steamcmd 自更新超时，先跳过（后面的查询可能仍然可用）'
            return $false
        }
    } catch {
        Write-Warn ("steamcmd 初始化失败：{0}" -f $_.Exception.Message)
        return $false
    }

    Set-Content -LiteralPath $marker -Value (Get-Date -Format 's') -Encoding ASCII
    Write-Ok 'steamcmd 初始化完成'
    return $true
}

function Get-AppInfo {
    param([string]$SteamCmdExe)

    $outFile = Join-Path $script:WorkDir ("appinfo_{0}.txt" -f $script:AppId)
    New-Item -ItemType Directory -Force -Path $script:WorkDir | Out-Null
    Write-Step '正在向 Steam 查询游戏的最新版本信息…'
    & $SteamCmdExe +login anonymous +app_info_update 1 +app_info_print $script:AppId +quit *> $outFile
    $text = Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($text)) { throw 'Steam 没有返回数据，请检查网络' }

    $buildId = $null
    $m = [regex]::Match($text, '"branches"[\s\S]*?"public"\s*\{\s*"buildid"\s*"(\d+)"')
    if ($m.Success) { $buildId = $m.Groups[1].Value }
    if (-not $buildId) { throw '解析 appinfo 失败：找不到 public buildid' }

    # 只挑 Windows / 公共 depot
    $depots = @()
    foreach ($dm in [regex]::Matches($text, '(?s)\n\t\t"(\d{4,})"\s*\n\t\t\{([\s\S]*?)\n\t\t\}')) {
        $id = $dm.Groups[1].Value
        $body = $dm.Groups[2].Value
        if ($body -match '"depotfromapp"') { continue }
        if ($body -match '"dlcappid"') { continue }
        if ($body -match '"oslist"\s+"([^"]+)"') {
            if ($matches[1] -notmatch 'windows') { continue }
        }
        $mm = [regex]::Match($body, '"manifests"\s*\{\s*"public"\s*\{\s*"gid"\s*"(\d+)"\s*"size"\s*"(\d+)"')
        if ($mm.Success) {
            $depots += [pscustomobject]@{ Id = $id; Gid = $mm.Groups[1].Value; Size = $mm.Groups[2].Value }
        }
    }
    if ($depots.Count -eq 0) { throw 'appinfo 中没有解析到任何 Windows depot' }

    return [pscustomobject]@{ BuildId = $buildId; Depots = $depots }
}

# 连不上 Steam 时的兜底：Steam 准备更新时会把目标 gid 写进 acf 的 StagedDepots
function Get-StagedManifestFallback {
    param($Env)
    if (-not (Test-Path -LiteralPath $Env.AcfPath)) { return $null }
    $txt = Get-Content -LiteralPath $Env.AcfPath -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($txt)) { return $null }

    $block = [regex]::Match($txt, '"StagedDepots"\s*\{([\s\S]*?)\n\t\}')
    if (-not $block.Success) { return $null }

    $depots = @()
    foreach ($m in [regex]::Matches($block.Groups[1].Value, '(?s)"(\d{4,})"\s*\{\s*"manifest"\s*"(\d+)"\s*"size"\s*"(\d+)"')) {
        $depots += [pscustomobject]@{ Id = $m.Groups[1].Value; Gid = $m.Groups[2].Value; Size = $m.Groups[3].Value }
    }
    if ($depots.Count -eq 0) { return $null }

    $build = '0'
    $bm = [regex]::Match($txt, '"TargetBuildID"\s+"(\d+)"')
    if ($bm.Success -and $bm.Groups[1].Value -ne '0') { $build = $bm.Groups[1].Value }

    foreach ($d in $depots) { Write-Info ("depot {0}  gid {1}  size {2}" -f $d.Id, $d.Gid, (Format-Size ([int64]$d.Size))) }
    return [pscustomobject]@{ BuildId = $build; Depots = $depots }
}

function New-AcfText {
    param($Depots, [string]$BuildId, [int64]$SizeOnDisk, [string]$Owner, [string]$LauncherPath)

    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $L = New-Object System.Collections.Generic.List[string]
    $L.Add('"AppState"')
    $L.Add('{')
    $L.Add(('	"appid"		"{0}"' -f $script:AppId))
    $L.Add('	"universe"		"1"')
    $L.Add(('	"LauncherPath"		"{0}"' -f $LauncherPath))
    $L.Add(('	"name"		"{0}"' -f $script:GameName))
    $L.Add('	"StateFlags"		"4"')
    $L.Add('	"installdir"		"War Thunder"')
    $L.Add(('	"LastUpdated"		"{0}"' -f $now))
    $L.Add('	"LastPlayed"		"0"')
    $L.Add(('	"SizeOnDisk"		"{0}"' -f $SizeOnDisk))
    $L.Add('	"StagingSize"		"0"')
    $L.Add(('	"buildid"		"{0}"' -f $BuildId))
    $L.Add(('	"LastOwner"		"{0}"' -f $Owner))
    $L.Add('	"DownloadType"		"1"')
    $L.Add('	"UpdateResult"		"0"')
    $L.Add('	"BytesToDownload"		"0"')
    $L.Add('	"BytesDownloaded"		"0"')
    $L.Add('	"BytesToStage"		"0"')
    $L.Add('	"BytesStaged"		"0"')
    $L.Add(('	"TargetBuildID"		"{0}"' -f $BuildId))
    $L.Add('	"AutoUpdateBehavior"		"1"')
    $L.Add('	"AllowOtherDownloadsWhileRunning"		"2"')
    $L.Add('	"ScheduledAutoUpdate"		"0"')
    $L.Add('	"InstalledDepots"')
    $L.Add('	{')
    foreach ($d in $Depots) {
        $L.Add(('		"{0}"' -f $d.Id))
        $L.Add('		{')
        $L.Add(('			"manifest"		"{0}"' -f $d.Gid))
        $L.Add(('			"size"		"{0}"' -f $d.Size))
        $L.Add('			"dlcappid"		"0"')
        $L.Add('		}')
    }
    $L.Add('	}')
    $L.Add('	"SharedDepots"')
    $L.Add('	{')
    $L.Add('		"228989"		"228980"')
    $L.Add('		"228990"		"228980"')
    $L.Add('	}')
    $L.Add('	"UserConfig"')
    $L.Add('	{')
    $L.Add('	}')
    $L.Add('	"MountedConfig"')
    $L.Add('	{')
    $L.Add('	}')
    $L.Add('}')
    return (($L -join "`r`n") + "`r`n")
}

function Stop-SteamProcess {
    $procs = Get-Process steam, steamwebhelper, steamservice, aces, launcher -ErrorAction SilentlyContinue
    if (-not $procs) { return $true }

    $game = $procs | Where-Object { $_.ProcessName -in @('aces', 'launcher') }
    Write-Step '正在关闭 Steam 和游戏（修改记录前必须关掉，不会丢存档）'
    $game | Stop-Process -Force -ErrorAction SilentlyContinue
    $steamExe = Join-Path $script:SteamRoot 'steam.exe'
    if (Test-Path -LiteralPath $steamExe) {
        Start-Process -FilePath $steamExe -ArgumentList '-shutdown' -ErrorAction SilentlyContinue
    } else {
        $procs | Stop-Process -Force -ErrorAction SilentlyContinue
    }

    $deadline = (Get-Date).AddSeconds(90)
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-Process steam, steamwebhelper, steamservice -ErrorAction SilentlyContinue)) { break }
        Start-Sleep -Seconds 2
    }
    $left = Get-Process steam, steamwebhelper, steamservice -ErrorAction SilentlyContinue
    if ($left) {
        Write-Info 'Steam 没有自己退出，正在强制结束'
        $left | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
    }
    Write-Ok '已经关掉了'
    return $true
}

function Repair-SteamManifest {
    param($Env)

    $check = Test-WTInstall -Path $Env.GameDir
    $sizeOnDisk = $check.Bytes
    if ($sizeOnDisk -le 0) { Write-Err '游戏目录是空的，先放入客户端'; return $false }

    if ($script:DryRun) {
        Write-Info '【演练】会关掉 Steam → 备份记录 → 改写成「已安装且最新」'
    }

    # ── 写入前检查：把要动的东西摊开给用户看 ──
    Write-Host ''
    Write-Host '  写入前检查：' -ForegroundColor White
    $keyRows = @(
        @('游戏目录',  $Env.GameDir),
        @('文件大小',  ("{0}（{1} 个文件）" -f (Format-Size $check.Bytes), $check.Files)),
        @('关键文件',  ("launcher.exe {0}   win64\aces.exe {1}   aces.vromfs.bin {2}" -f
                        $(if (Test-Path -LiteralPath (Join-Path $Env.GameDir 'launcher.exe')) { '✓' } else { '✗' }),
                        $(if (Test-Path -LiteralPath (Join-Path $Env.GameDir 'win64\aces.exe')) { '✓' } else { '✗' }),
                        $(if (Test-Path -LiteralPath (Join-Path $Env.GameDir 'aces.vromfs.bin')) { '✓' } else { '✗' }))),
        @('Steam 库',  $Env.Library),
        @('Steam 记录', $(if ($Env.AcfExists) { '会先备份，再重写成「已安装且最新」' } else { '目前没有，会新建一份' }))
    )
    foreach ($r in $keyRows) {
        Write-Host ('    ' + (Pad-Display -Text $r[0] -Width 12)) -ForegroundColor DarkGray -NoNewline
        Write-Host $r[1]
    }
    Write-Host '    接下来     会先关闭 Steam（存档不会丢），再写入安装记录' -ForegroundColor DarkGray
    Write-Host ''
    Write-Info '如果你正在 Steam 里玩别的游戏，或正在下载东西，请先自己退出/暂停。'

    if ($script:DryRun) {
        Write-Info '【演练】到此为止：不会关闭 Steam，也不会改记录'
        return $true
    }

    if (-not (Ask-YesNo '信息没问题，继续吗？' $true)) {
        Write-Warn '已取消，没有做任何修改'
        return $false
    }

    if (-not (Stop-SteamProcess)) { return $false }

    $steamCmd = Get-SteamCmd
    Initialize-SteamCmd -SteamCmdExe $steamCmd | Out-Null

    $info = $null
    try { $info = Get-AppInfo -SteamCmdExe $steamCmd }
    catch { Write-Warn ("查询 Steam 清单失败：{0}" -f $_.Exception.Message) }

    if (-not $info) {
        # 兜底：Steam 之前准备更新时，会把目标 gid 写进 acf 的 StagedDepots
        Write-Warn '连不上 Steam，改用本机记录里的版本信息…'
        $info = Get-StagedManifestFallback -Env $Env
        if (-not $info) {
            Write-Err '拿不到 Steam 的版本信息。请检查网络后重试，或换一台能连 Steam 的电脑再运行一次。'
            return $false
        }
    }

    $needBytes = 0
    foreach ($d in $info.Depots) { $needBytes += [int64]$d.Size }
    Write-Info ("Steam 上的最新版本：{0}" -f $info.BuildId)
    Write-Info ("完整版数据量约 {0}，本工具不会下载它" -f (Format-Size $needBytes))

    # 备份
    $backupDir = Join-Path $script:ToolRoot 'backup'
    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    if (Test-Path -LiteralPath $Env.AcfPath) {
        $bak = Join-Path $backupDir ("appmanifest_{0}.acf.{1}.bak" -f $script:AppId, (Get-Date -Format 'yyyyMMdd_HHmmss'))
        Copy-Item -LiteralPath $Env.AcfPath -Destination $bak -Force
        Write-Ok ("已备份原清单 -> {0}" -f $bak)
    }

    $owner = '0'
    if (Test-Path -LiteralPath $Env.AcfPath) {
        $om = [regex]::Match((Get-Content -LiteralPath $Env.AcfPath -Raw), '"LastOwner"\s+"(\d+)"')
        if ($om.Success) { $owner = $om.Groups[1].Value }
    }

    # Steam 只认它自己登记过的 depot，避免把别的 DLC depot 塞进去
    $wanted = @()
    if (Test-Path -LiteralPath $Env.AcfPath) {
        $old = Get-Content -LiteralPath $Env.AcfPath -Raw
        $bm = [regex]::Match($old, '"InstalledDepots"([\s\S]*?)\n\t\}')
        if ($bm.Success) {
            $ids = [regex]::Matches($bm.Groups[1].Value, '(?m)^\t\t"(\d+)"') | ForEach-Object { $_.Groups[1].Value }
            foreach ($id in ($ids | Select-Object -Unique)) {
                $hit = $info.Depots | Where-Object { $_.Id -eq $id }
                if ($hit) { $wanted += $hit }
            }
        }
    }
    if ($wanted.Count -eq 0) { $wanted = $info.Depots }

    $launcherPath = (Join-Path $Env.SteamRoot 'steam.exe').Replace('\', '\\')
    $text = New-AcfText -Depots $wanted -BuildId $info.BuildId -SizeOnDisk $sizeOnDisk -Owner $owner -LauncherPath $launcherPath

    Set-ItemProperty -LiteralPath $Env.AcfPath -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
    [System.IO.File]::WriteAllText($Env.AcfPath, $text, (New-Object System.Text.UTF8Encoding($false)))
    Write-Ok ("已写入清单：{0}" -f $Env.AcfPath)

    # 清理更新暂存
    $dl = Join-Path $Env.Library 'steamapps\downloading'
    foreach ($f in (Get-ChildItem -LiteralPath $dl -Filter "state_$($script:AppId)_*.patch" -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue
        Write-Info ("已删除暂存 {0}" -f $f.Name)
    }
    $staging = Join-Path $dl $script:AppId
    if (Test-Path -LiteralPath $staging) {
        $left = Get-ChildItem -LiteralPath $staging -Recurse -File -ErrorAction SilentlyContinue
        if ($left.Count -eq 0) {
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
            Write-Info '已删除空的更新暂存目录'
        } else {
            Write-Warn ("暂存目录里还有 {0} 个文件，未删除：{1}" -f $left.Count, $staging)
        }
    }
    return $true
}

# ============================================================
#  自动下载官方客户端
#  —— 不依赖浏览器：curl(Schannel) → .NET → 本机安装包 → 手动路径
# ============================================================
function Invoke-CurlDownload {
    param([string]$Url, [string]$OutFile)
    $curl = $null
    try { $curl = (Get-Command curl.exe -ErrorAction SilentlyContinue).Source } catch { }
    if (-not $curl) { $curl = 'C:\Windows\System32\curl.exe' }
    if (-not (Test-Path -LiteralPath $curl)) { return $false }

    $cargs = @('-sS', '-L', '--ssl-no-revoke', '--max-time', '300',
               '-A', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/120',
               '-o', $OutFile)
    if ($script:Proxy) { $cargs += @('-x', $script:Proxy) }
    $cargs += $Url

    Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
    & $curl @cargs 2>$null
    if ($LASTEXITCODE -ne 0) { return $false }
    if (-not (Test-Path -LiteralPath $OutFile)) { return $false }
    return ((Get-Item -LiteralPath $OutFile).Length -gt 1MB)
}

function Invoke-NetDownload {
    param([string]$Url, [string]$OutFile)
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        try { [Net.ServicePointManager]::CheckCertificateRevocationList = $false } catch { }
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add('User-Agent', 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/120')
        if ($script:Proxy) { $wc.Proxy = New-Object System.Net.WebProxy($script:Proxy) }
        Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
        $wc.DownloadFile($Url, $OutFile)
        if (-not (Test-Path -LiteralPath $OutFile)) { return $false }
        return ((Get-Item -LiteralPath $OutFile).Length -gt 1MB)
    } catch {
        return $false
    }
}

function Find-LocalInstaller {
    $dirs = @("$env:USERPROFILE\Downloads", "$env:USERPROFILE\Desktop", $env:TEMP,
              $script:ToolRoot, $script:WorkDir, (Get-Location).Path)
    foreach ($d in $dirs) {
        if (-not (Test-Path -LiteralPath $d)) { continue }
        $hit = Get-ChildItem -LiteralPath $d -Filter 'wt_launcher*.exe' -File -ErrorAction SilentlyContinue |
               Sort-Object Length -Descending | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

function Test-OfficialInstaller {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $fi = Get-Item -LiteralPath $Path
    if ($fi.Length -lt 1MB) { Write-Warn ("文件太小（{0}），不像安装包" -f (Format-Size $fi.Length)); return $false }
    $head = [System.IO.File]::ReadAllBytes($Path)[0..1]
    if ($head[0] -ne 0x4D -or $head[1] -ne 0x5A) { Write-Warn '不是 PE 文件（可能是网页/错误页）'; return $false }

    $sig = Get-AuthenticodeSignature -LiteralPath $Path
    $signer = ''
    if ($sig.SignerCertificate) { $signer = $sig.SignerCertificate.Subject }
    if ($signer -notmatch 'GAIJIN') { throw ("安装包签名主体不是 Gaijin，已中止：{0}" -f $signer) }
    if ($sig.Status -ne 'Valid') { Write-Warn ("签名状态 {0}（证书吊销服务器连不上时正常），签名主体是 Gaijin，继续" -f $sig.Status) }

    $desc = ''
    try { $desc = $fi.VersionInfo.FileDescription.Trim() } catch { }
    Write-Ok ("安装包已校验：{0}  {1}" -f (Format-Size $fi.Length), $desc)
    return $true
}

function Get-OfficialSetup {
    param([string]$Dir)
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    $dst = Join-Path $Dir 'wt_launcher_setup.exe'

    # 0. 用户直接指定了文件
    if ($InstallerPath) {
        if (-not (Test-Path -LiteralPath $InstallerPath)) { throw "指定的安装包不存在：$InstallerPath" }
        Write-Step ("使用指定安装包：{0}" -f $InstallerPath)
        Copy-Item -LiteralPath $InstallerPath -Destination $dst -Force
        if (Test-OfficialInstaller -Path $dst) { return $dst }
        throw '指定的文件校验没通过'
    }

    # 1. 在线多源（curl 优先，能绕开本机的证书吊销检查问题）
    $urls = @(
        'https://warthunder.com/en/download',
        'https://warthunder.com/download/launcherPC',
        'https://warthunder.com/zh/download/launcherPC'
    )
    foreach ($u in $urls) {
        Write-Step ("下载：{0}" -f $u)
        if (Invoke-CurlDownload -Url $u -OutFile $dst) { Write-Info '下载引擎：curl' }
        elseif (Invoke-NetDownload -Url $u -OutFile $dst) { Write-Info '下载引擎：.NET' }
        else { Write-Warn '这个源拿不到文件，换下一个'; continue }

        if (Get-Item -LiteralPath $dst -ErrorAction SilentlyContinue) {
            if (Test-OfficialInstaller -Path $dst) { return $dst }
        }
    }

    # 2. 本机已有的安装包（浏览器下载过的、上次留下的）
    Write-Warn '所有在线源都不通，改找本机已有的安装包...'
    $local = Find-LocalInstaller
    if ($local) {
        Write-Ok ("发现本机安装包：{0}" -f $local)
        Copy-Item -LiteralPath $local -Destination $dst -Force
        if (Test-OfficialInstaller -Path $dst) { return $dst }
    }

    # 3. 让用户给路径或网址
    if ($script:AssumeYes) { throw '下载失败且本机没有安装包，请用 -InstallerPath 指定文件' }
    while ($true) {
        $inp = Read-Host '  输入安装包路径或下载网址（直接回车放弃）'
        if ([string]::IsNullOrWhiteSpace($inp)) { throw '已取消下载' }
        $inp = $inp.Trim().Trim('"')
        if ($inp -match '^https?://') {
            if (Invoke-CurlDownload -Url $inp -OutFile $dst) { if (Test-OfficialInstaller -Path $dst) { return $dst } }
            if (Invoke-NetDownload -Url $inp -OutFile $dst) { if (Test-OfficialInstaller -Path $dst) { return $dst } }
            Write-Warn '这个网址拿不到安装包'
        }
        elseif (Test-Path -LiteralPath $inp) {
            Copy-Item -LiteralPath $inp -Destination $dst -Force
            if (Test-OfficialInstaller -Path $dst) { return $dst }
        }
        else { Write-Warn '路径不存在' }
    }
}

function Install-OfficialLauncher {
    param([string]$Setup, [string]$Target)
    New-Item -ItemType Directory -Force -Path $Target | Out-Null
    $log = Join-Path $Target 'setup.log'
    Write-Step ("静默安装启动器到 {0}" -f $Target)
    $argString = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /DIR="{0}" /LOG="{1}"' -f $Target, $log
    $p = Start-Process -FilePath $Setup -ArgumentList $argString -Wait -PassThru
    if ($p.ExitCode -ne 0) { throw ("安装器返回 {0}，日志：{1}" -f $p.ExitCode, $log) }
    if (-not (Test-Path -LiteralPath (Join-Path $Target 'launcher.exe'))) { throw ("安装后没有 launcher.exe，见 {0}" -f $log) }
    Write-Ok '启动器安装完成'
}

function Wait-ClientDownload {
    param([string]$Dir)
    Write-Step '请在启动器里把「客户端」选为【最小化】，然后开始下载'
    $launcher = Join-Path $Dir 'launcher.exe'
    if (Get-Process launcher -ErrorAction SilentlyContinue) {
        Write-Info '检测到启动器已在运行，沿用当前窗口'
    } else {
        Start-Process -FilePath $launcher -WorkingDirectory $Dir
    }
    Write-Info '正在监测下载进度（按 Ctrl+C 可中止监测，不影响下载）...'

    $lastSize = -1
    $stable = 0
    $lastPrint = Get-Date
    while ($true) {
        Start-Sleep -Seconds 10
        $st = Get-DirStats -Path $Dir
        $running = [bool](Get-Process launcher, aces -ErrorAction SilentlyContinue)
        if ($st.Bytes -eq $lastSize) { $stable++ } else { $stable = 0 }
        $lastSize = $st.Bytes

        if (((Get-Date) - $lastPrint).TotalSeconds -ge 20) {
            Write-Info ("已下载 {0} / {1} 个文件  启动器{2}" -f (Format-Size $st.Bytes), $st.Files, $(if ($running) { '运行中' } else { '未运行' }))
            $lastPrint = Get-Date
        }

        $check = Test-WTInstall -Path $Dir
        if ($check.Valid -and $st.Bytes -gt 5GB -and $stable -ge 2) {
            Write-Ok ("客户端已就绪：{0} / {1} 个文件" -f (Format-Size $st.Bytes), $st.Files)
            return $true
        }
        if (-not $running -and $stable -ge 2 -and -not $check.Valid) {
            Write-Warn '启动器已退出但客户端不完整，停止监测'
            return $false
        }
    }
}

# ============================================================
#  主流程
# ============================================================
function Show-Menu {
    Write-Host ''
    Write-Host '  你想做什么？' -ForegroundColor White
    Write-Host ''
    Write-Host '   [1] 修好它（不知道选哪个就选这个）' -ForegroundColor Green
    Write-Host '       告诉你要把客户端放到哪 → 自动改 Steam 记录 → 开游戏'
    Write-Host ''
    Write-Host '   [2] 先看看情况（只看不改，很安全）'
    Write-Host '   [3] 游戏文件已经放好了，只修 Steam 记录'
    Write-Host '   [4] 我还没有客户端，帮我下载一份（约 25 GB）'
    Write-Host '   [5] 备份 / 还原 / 测试（进阶，一般用不到）'
    Write-Host '   [0] 退出'
    Write-Host ''
    while ($true) {
        $a = Read-Host '  输入数字后回车'
        switch ($a.Trim()) {
            '1' { return 1 }
            '2' { return 2 }
            '3' { return 3 }
            '4' { return 4 }
            '5' { return 5 }
            '0' { return 0 }
        }
        Write-Host '  请只输入 0 到 5 之间的数字' -ForegroundColor DarkYellow
    }
}

function Resolve-SourceClient {
    param($Env)

    if ($SourcePath) {
        if (-not (Test-Path -LiteralPath $SourcePath)) { throw "指定的源目录不存在：$SourcePath" }
        $t = Test-WTInstall -Path $SourcePath
        if (-not $t.Valid) { throw ("源目录不像完整的战雷客户端，缺少：{0}" -f ($t.Missing -join '、')) }
        return $SourcePath
    }

    Write-Head '查找可用的客户端'
    Write-Step '正在扫描各磁盘上的 War Thunder 目录...'
    $found = @(Find-WTInstalls -Exclude @($Env.GameDir))

    # Steam 更新时会把这些文件挪进 downloading\<appid>，这是最常见的“消失”原因
    $staged = New-Object System.Collections.Generic.List[string]
    foreach ($l in $Env.Libraries) {
        $st = Join-Path $l ("steamapps\downloading\{0}" -f $script:AppId)
        if (Test-Path -LiteralPath (Join-Path $st 'win64\aces.exe')) { $staged.Add($st) }
    }
    if ($staged.Count -gt 0) {
        Write-Ok ("发现 Steam 更新暂存目录里还有游戏文件：{0}" -f $staged[0])
        $found = @($staged) + $found
    }

    if ($found.Count -eq 0) {
        Write-Warn '没有找到现成的客户端'
        return $null
    }
    if ($script:AssumeYes) {
        foreach ($f in $found) {
            if ((Test-WTInstall -Path $f).Valid) { return $f }
        }
        return $null
    }
    Write-Host ''
    for ($i = 0; $i -lt $found.Count; $i++) {
        $t = Test-WTInstall -Path $found[$i]
        $tag = if ($t.Valid) { '完整' } else { '缺 ' + ($t.Missing -join ',') }
        Write-Host ("   [{0}] {1}" -f ($i + 1), $found[$i]) -ForegroundColor White
        Write-Host ("       {0}  {1} 个文件  {2}" -f (Format-Size $t.Bytes), $t.Files, $tag) -ForegroundColor DarkGray
    }
    Write-Host '   [0] 都不是，我自己输入路径'
    Write-Host ''
    while ($true) {
        $a = Read-Host '  选择'
        if ($a -eq '0') { break }
        $n = 0
        if ([int]::TryParse($a, [ref]$n) -and $n -ge 1 -and $n -le $found.Count) {
            $pick = $found[$n - 1]
            $t = Test-WTInstall -Path $pick
            if (-not $t.Valid) {
                Write-Warn ("这个目录缺少：{0}" -f ($t.Missing -join '、'))
                if (-not (Ask-YesNo '仍然使用这个目录？' $false)) { continue }
            }
            return $pick
        }
    }

    $manual = Read-Host '  请输入客户端所在文件夹的完整路径'
    if (Test-Path -LiteralPath $manual) {
        $t = Test-WTInstall -Path $manual
        if (-not $t.Valid) { Write-Warn ("缺少：{0}" -f ($t.Missing -join '、')) }
        if (Ask-YesNo '使用这个目录？' $true) { return $manual }
    } else {
        Write-Err '路径不存在'
    }
    return $null
}

function Invoke-DownloadClient {
    param($Env)

    Write-Head '自动下载官方最小化客户端'
    $defaultTarget = Join-Path $script:WorkDir 'WarThunder'
    $target = $defaultTarget
    if (-not $script:AssumeYes) {
        $in = Read-Host ("  安装到哪个文件夹？（默认 {0}）" -f $defaultTarget)
        if (-not [string]::IsNullOrWhiteSpace($in)) { $target = $in.Trim('"') }
    }

    $setup = Get-OfficialSetup -Dir $script:WorkDir

    if ($script:DryRun) {
        Write-Info '【DryRun】只下载并校验安装包，不执行安装'
        return $target
    }

    $driveLetter = $target.Substring(0, 1)
    $free = (Get-PSDrive -Name $driveLetter -ErrorAction SilentlyContinue).Free
    Write-Info ("目标盘剩余 {0}，最小化客户端约需 25 GB" -f (Format-Size $free))
    if ($free -lt 30GB) {
        Write-Warn '剩余空间可能不够，最小化客户端大约 25 GB'
        if (-not (Ask-YesNo '仍然继续？' $false)) { return $null }
    }

    Install-OfficialLauncher -Setup $setup -Target $target
    $ok = Wait-ClientDownload -Dir $target
    if (-not $ok) {
        Write-Err '客户端没有下载完整，请重新运行或手动把客户端文件夹路径填给工具'
        return $null
    }
    return $target
}

# 第 1 步：把客户端准备好放进 common\War Thunder
# 默认建议用户自己放（可选），也提供"帮我搬 / 帮我下载"
function Invoke-PrepareClient {
    param($Env)

    if ((Test-WTInstall -Path $Env.GameDir).Valid) {
        Write-Ok '游戏目录里已经有完整客户端，这一步不用做'
        return $true
    }

    # 放错位置：common\WarThunder（没有空格）
    if ($Env.AltGame -and $Env.AltGame.Valid) {
        Write-Warn ('你把它放在了：{0}' -f $Env.AltGameDir)
        Write-Warn ('Steam 认的是：{0}（War Thunder，中间有空格）' -f $Env.GameDir)
        if (Ask-YesNo '要我帮你挪到正确位置吗？（同盘是秒级改名）' $true) {
            if (Move-ClientIntoLibrary -Source $Env.AltGameDir -Dest $Env.GameDir) { return $true }
        }
    }

    # 无人值守：自动找、自动搬
    if ($script:AssumeYes) {
        $src = Resolve-SourceClient -Env $Env
        if ($src) { return (Move-ClientIntoLibrary -Source $src -Dest $Env.GameDir) }
        Write-Err '无人值守模式下没找到客户端，已停止'
        return $false
    }

    while ($true) {
        Write-Host ''
        Write-Host '  请把下载好的最小化客户端放进来：' -ForegroundColor White
        Write-Host '    1. 打开官方启动器下载的那个文件夹（一般叫 WarThunder，没有空格）'
        Write-Host '    2. 选中里面【所有】文件和文件夹，复制'
        Write-Host '    3. 粘贴到这个目录（可以直接复制下面这行地址）：'
        Write-Host ('       {0}' -f $Env.GameDir) -ForegroundColor Yellow
        Write-Host '       注意：Steam 的目录名是 "War Thunder"，中间有一个空格'
        Write-Host ''
        Write-Host '  [1] 我放好了，帮我检查（推荐）' -ForegroundColor Green
        Write-Host '  [2] 帮我自动搬过去'
        Write-Host '  [3] 帮我下载一份新的（约 25 GB）'
        Write-Host '  [0] 先不弄了，返回'
        Write-Host ''
        $a = (Read-Host '  输入数字后回车').Trim()

        switch ($a) {
            '1' {
                $t = Test-WTInstall -Path $Env.GameDir
                if ($t.Valid) {
                    Write-Ok ('很好，客户端已就绪：{0}，{1} 个文件' -f (Format-Size $t.Bytes), $t.Files)
                    return $true
                }
                Write-Warn ('还没放全，缺少：{0}' -f ($t.Missing -join '、'))
                Write-Info ('目前已经放了 {0}，{1} 个文件' -f (Format-Size $t.Bytes), $t.Files)
                Write-Info '可能还在复制中，等一会儿再按 1 检查一次'
            }
            '2' {
                $src = Resolve-SourceClient -Env $Env
                if ($src -and (Move-ClientIntoLibrary -Source $src -Dest $Env.GameDir)) { return $true }
            }
            '3' {
                $t = Invoke-DownloadClient -Env $Env
                if ($t -and (Move-ClientIntoLibrary -Source $t -Dest $Env.GameDir)) { return $true }
            }
            '0' { return $false }
            default { Write-Info '请只输入 0 到 3 之间的数字' }
        }
    }
}

function Invoke-Repair {
    param($Env)

    $total = if ($SkipMove) { 1 } else { 2 }
    $step = 0

    if (-not $SkipMove) {
        $step++
        Write-Head ("第 {0} 步 / 共 {1} 步：准备游戏文件" -f $step, $total)
        if (-not (Invoke-PrepareClient -Env $Env)) {
            Write-Warn '这一步没完成，修复先停在这里'
            return $false
        }
    }

    $step++
    Write-Head ("第 {0} 步 / 共 {1} 步：让 Steam 认为游戏已是最新" -f $step, $total)
    if (-not (Repair-SteamManifest -Env $Env)) { return $false }
    return $true
}

function Start-SteamAndGame {
    param($Env)
    $steamExe = Join-Path $Env.SteamRoot 'steam.exe'
    if ($script:DryRun) {
        Write-Info '【DryRun】将启动 Steam，并可通过 steam://rungameid 拉起游戏'
        return
    }
    Write-Step '正在启动 Steam...'
    Start-Process -FilePath $steamExe

    $deadline = (Get-Date).AddSeconds(120)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        if (Get-Process steam -ErrorAction SilentlyContinue) { break }
    }
    Start-Sleep -Seconds 20
    Write-Ok 'Steam 已启动'

    if ($script:NoLaunch) { return }
    if (Ask-YesNo '现在直接拉起游戏吗？' $true) {
        Write-Step '正在通过 Steam 启动游戏...'
        Start-Process ('steam://rungameid/{0}' -f $script:AppId)
        Start-Sleep -Seconds 25
        if (Get-Process aces -ErrorAction SilentlyContinue) { Write-Ok '游戏进程已出现' }
        else { Write-Warn '没看到游戏进程，请在 Steam 里点「开始游戏」试试' }
    }
}

# ============================================================
#  快照 / 还原 / 故障模拟（测试用）
# ============================================================
function Get-SnapshotRoot {
    $d = Join-Path $script:ToolRoot 'snapshots'
    New-Item -ItemType Directory -Force -Path $d | Out-Null
    return $d
}

function Get-SavesDir {
    return (Join-Path $env:USERPROFILE 'Documents\My Games\WarThunder\Saves')
}

function New-WtSnapshot {
    param($Env)
    $dir = Join-Path (Get-SnapshotRoot) (Get-Date -Format 'yyyyMMdd_HHmmss')
    New-Item -ItemType Directory -Force -Path $dir | Out-Null

    if (Test-Path -LiteralPath $Env.AcfPath) {
        Copy-Item -LiteralPath $Env.AcfPath -Destination (Join-Path $dir 'appmanifest_236390.acf') -Force
    }
    $cfg = Join-Path $Env.GameDir 'config.blk'
    if (Test-Path -LiteralPath $cfg) { Copy-Item -LiteralPath $cfg -Destination (Join-Path $dir 'config.blk') -Force }
    $appid = Join-Path $Env.GameDir 'steam_appid.txt'
    if (Test-Path -LiteralPath $appid) { Copy-Item -LiteralPath $appid -Destination (Join-Path $dir 'steam_appid.txt') -Force }

    $saves = Get-SavesDir
    if (Test-Path -LiteralPath $saves) {
        Copy-Item -LiteralPath $saves -Destination (Join-Path $dir 'Saves') -Recurse -Force
    }

    $meta = [pscustomobject]@{
        Created   = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        GameDir   = $Env.GameDir
        Library   = $Env.Library
        AcfPath   = $Env.AcfPath
        GameBytes = (Test-WTInstall -Path $Env.GameDir).Bytes
    }
    $meta | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $dir 'meta.json') -Encoding UTF8
    Write-Ok ("快照已创建：{0}" -f $dir)
    return $dir
}

function Restore-WtSnapshot {
    param([string]$Dir, $Env)
    if (-not (Test-Path -LiteralPath $Dir)) { throw "快照不存在：$Dir" }

    $acfBak = Join-Path $Dir 'appmanifest_236390.acf'
    if (Test-Path -LiteralPath $acfBak) {
        Copy-Item -LiteralPath $acfBak -Destination $Env.AcfPath -Force
        Set-ItemProperty -LiteralPath $Env.AcfPath -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
        Write-Ok '已还原 Steam 清单'
    }
    $cfg = Join-Path $Dir 'config.blk'
    if (Test-Path -LiteralPath $cfg -and (Test-Path -LiteralPath $Env.GameDir)) {
        Copy-Item -LiteralPath $cfg -Destination (Join-Path $Env.GameDir 'config.blk') -Force
        Write-Ok '已还原 config.blk'
    }
    $appid = Join-Path $Dir 'steam_appid.txt'
    if (Test-Path -LiteralPath $appid -and (Test-Path -LiteralPath $Env.GameDir)) {
        Copy-Item -LiteralPath $appid -Destination (Join-Path $Env.GameDir 'steam_appid.txt') -Force
    }
    $saves = Join-Path $Dir 'Saves'
    if (Test-Path -LiteralPath $saves) {
        $dst = Get-SavesDir
        $parent = Split-Path $dst -Parent
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
        if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force -ErrorAction SilentlyContinue }
        Copy-Item -LiteralPath $saves -Destination $dst -Recurse -Force
        Write-Ok '已还原存档（Saves）'
    }
    return $true
}

function Get-SimulationDir {
    param($Env)
    $drv = $Env.GameDir.Substring(0, 1)
    return ($drv + ':\WarThunderTest')
}

function Set-SimulatedBrokenState {
    param($Env)

    if (Get-Process aces, launcher -ErrorAction SilentlyContinue) {
        Write-Err '游戏还在运行，请先退出游戏再模拟'
        return $false
    }
    if (-not (Test-WTInstall -Path $Env.GameDir).Valid) {
        Write-Err 'common 目录里没有完整客户端，没什么可模拟的'
        return $false
    }

    $dest = Get-SimulationDir -Env $Env
    if (Test-Path -LiteralPath $dest) { Write-Err "目标已存在：$dest，请先撤销上一次模拟"; return $false }

    Write-Step ("把客户端挪到 {0}（同盘重命名，秒级、不占额外空间）" -f $dest)
    Move-Item -LiteralPath $Env.GameDir -Destination $dest -Force
    Write-Ok '客户端已挪走，common\War Thunder 现在是空的'

    # 清单改成「已安装但需要更新」
    $owner = '0'
    $lp = (Join-Path $Env.SteamRoot 'steam.exe').Replace('\', '\\')
    if (Test-Path -LiteralPath $Env.AcfPath) {
        $om = [regex]::Match((Get-Content -LiteralPath $Env.AcfPath -Raw), '"LastOwner"\s+"(\d+)"')
        if ($om.Success) { $owner = $om.Groups[1].Value }
    }
    $L = New-Object System.Collections.Generic.List[string]
    $L.Add('"AppState"'); $L.Add('{')
    $L.Add('	"appid"		"236390"')
    $L.Add('	"universe"		"1"')
    $L.Add(('	"LauncherPath"		"{0}"' -f $lp))
    $L.Add('	"name"		"War Thunder"')
    $L.Add('	"StateFlags"		"6"')
    $L.Add('	"installdir"		"War Thunder"')
    $L.Add('	"LastUpdated"		"0"')
    $L.Add('	"LastPlayed"		"0"')
    $L.Add('	"SizeOnDisk"		"0"')
    $L.Add('	"buildid"		"0"')
    $L.Add(('	"LastOwner"		"{0}"' -f $owner))
    $L.Add('	"DownloadType"		"1"')
    $L.Add('	"UpdateResult"		"0"')
    $L.Add('	"BytesToDownload"		"0"')
    $L.Add('	"BytesDownloaded"		"0"')
    $L.Add('	"BytesToStage"		"0"')
    $L.Add('	"BytesStaged"		"0"')
    $L.Add('	"AutoUpdateBehavior"		"1"')
    $L.Add('	"AllowOtherDownloadsWhileRunning"		"2"')
    $L.Add('	"ScheduledAutoUpdate"		"0"')
    $L.Add('	"InstalledDepots"'); $L.Add('	{'); $L.Add('	}')
    $L.Add('	"SharedDepots"'); $L.Add('	{')
    $L.Add('		"228989"		"228980"')
    $L.Add('		"228990"		"228980"')
    $L.Add('	}'); $L.Add('	"UserConfig"'); $L.Add('	{'); $L.Add('	}')
    $L.Add('	"MountedConfig"'); $L.Add('	{'); $L.Add('	}')
    $L.Add('}')
    $text = ($L -join "`r`n") + "`r`n"
    [System.IO.File]::WriteAllText($Env.AcfPath, $text, (New-Object System.Text.UTF8Encoding($false)))
    Write-Ok 'Steam 清单已改成「需要更新」'

    Write-Host ''
    Write-Warn '现在不要启动 Steam（它会开始下 88 GB）'
    Write-Info '直接运行本工具的 [1] 一键修复，观察完整流程'
    return $true
}

function Undo-SimulatedBrokenState {
    param($Env)
    $src = Get-SimulationDir -Env $Env
    if (-not (Test-Path -LiteralPath $src)) { Write-Err ("没找到模拟目录：{0}" -f $src); return $false }

    if ((Test-WTInstall -Path $Env.GameDir).Valid) {
        Write-Err 'common 目录里已经有完整客户端了，无需撤销'
        return $false
    }
    if (Test-Path -LiteralPath $Env.GameDir) {
        Remove-Item -LiteralPath $Env.GameDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    $parent = Split-Path $Env.GameDir -Parent
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    Write-Step '把客户端挪回 common\War Thunder ...'
    Move-Item -LiteralPath $src -Destination $Env.GameDir -Force
    Write-Ok '已挪回'
    return $true
}

function Show-SnapshotMenu {
    param($Env)
    while ($true) {
        Write-Head '备份 / 还原 / 故障模拟'
        Write-Host '  [1] 创建快照（Steam 清单 + config.blk + 存档）'
        Write-Host '  [2] 从快照还原'
        Write-Host '  [3] 模拟故障：客户端挪走 + 清单改为「需要更新」'
        Write-Host '  [4] 撤销模拟：把客户端挪回来'
        Write-Host '  [0] 返回'
        Write-Host ''
        $a = Read-Host '  选择'
        switch ($a.Trim()) {
            '1' { New-WtSnapshot -Env $Env | Out-Null; Pause-Any }
            '2' {
                $root = Get-SnapshotRoot
                $list = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
                if ($list.Count -eq 0) { Write-Warn '还没有任何快照'; Pause-Any; continue }
                for ($i = 0; $i -lt $list.Count; $i++) {
                    $metaFile = Join-Path $list[$i].FullName 'meta.json'
                    $desc = ''
                    if (Test-Path -LiteralPath $metaFile) {
                        try { $m = Get-Content -LiteralPath $metaFile -Raw | ConvertFrom-Json; $desc = ("{0}  {1}" -f $m.Created, (Format-Size $m.GameBytes)) } catch { }
                    }
                    Write-Host ("   [{0}] {1}   {2}" -f ($i + 1), $list[$i].Name, $desc)
                }
                $n = Read-Host '  还原哪一个？(0 取消)'
                if ($n -eq '0') { continue }
                $idx = 0
                if (-not [int]::TryParse($n, [ref]$idx) -or $idx -lt 1 -or $idx -gt $list.Count) { continue }
                if (-not (Stop-SteamProcess)) { continue }
                Restore-WtSnapshot -Dir $list[$idx - 1].FullName -Env $Env
                Pause-Any
            }
            '3' { Set-SimulatedBrokenState -Env $Env | Out-Null; Pause-Any }
            '4' { Undo-SimulatedBrokenState -Env $Env | Out-Null; Pause-Any }
            '0' { return }
        }
    }
}

# ============================================================
#  入口
# ============================================================
if ($SelfTest) {
    Write-Host ''
    Write-Host '  [SelfTest] 只做检测，不修改任何东西' -ForegroundColor Yellow
    $c = Get-Environment
    Show-Environment -Env $c

    Write-Head '扫描各磁盘上的 War Thunder 客户端'
    $scan = @(Find-WTInstalls -Exclude @($c.GameDir))
    if ($scan.Count -eq 0) { Write-Info '（没有找到）' }
    foreach ($s in $scan) {
        $t = Test-WTInstall -Path $s
        $tag = if ($t.Valid) { '完整' } else { '缺 ' + ($t.Missing -join ',') }
        Write-Info ("{0}   {1}   {2}" -f $s, (Format-Size $t.Bytes), $tag)
    }

    Write-Head 'steamcmd'
    $sc = $null
    if ($env:WT_STEAMCMD -and (Test-Path -LiteralPath $env:WT_STEAMCMD)) { $sc = $env:WT_STEAMCMD }
    else { $sc = Join-Path $script:ToolRoot 'steamcmd\steamcmd.exe' }
    Write-Info ("路径：{0}  {1}" -f $sc, $(if (Test-Path -LiteralPath $sc) { '存在' } else { '缺失（首次运行会自动下载）' }))

    if (Test-Path -LiteralPath $sc) {
        Write-Head '实机验证：查询 public manifest 并生成清单预览'
        try {
            Initialize-SteamCmd -SteamCmdExe $sc | Out-Null
            $info = Get-AppInfo -SteamCmdExe $sc
            Write-Info ("public buildid : {0}" -f $info.BuildId)
            foreach ($d in $info.Depots) {
                Write-Info ("depot {0}  gid {1}  size {2}" -f $d.Id, $d.Gid, (Format-Size ([int64]$d.Size)))
            }
            $previewDir = Join-Path $script:ToolRoot 'logs'
            $preview = Join-Path $previewDir 'acf_preview.txt'
            $lp = (Join-Path $c.SteamRoot 'steam.exe').Replace('\', '\\')
            $text = New-AcfText -Depots $info.Depots -BuildId $info.BuildId -SizeOnDisk $c.Game.Bytes -Owner '0' -LauncherPath $lp
            [System.IO.File]::WriteAllText($preview, $text, (New-Object System.Text.UTF8Encoding($false)))
            Write-Ok ("清单预览已生成：{0}" -f $preview)

            if (Test-Path -LiteralPath $c.AcfPath) {
                $cur = Get-Content -LiteralPath $c.AcfPath -Raw
                $curGid = [regex]::Matches($cur, '"manifest"\s+"(\d+)"') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
                $newGid = @($info.Depots | ForEach-Object { $_.Gid } | Sort-Object -Unique)
                if (($curGid -join ',') -eq ($newGid -join ',')) { Write-Ok '当前清单的 depot 已是最新，无需修复' }
                else { Write-Warn ("当前清单 depot [{0}] 与最新 [{1}] 不一致，需要修复" -f ($curGid -join ','), ($newGid -join ',')) }
            }
        } catch {
            Write-Err ("查询失败：{0}" -f $_.Exception.Message)
        }
    }

    Write-Head '磁盘'
    foreach ($d in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | Where-Object { $_.Free -ne $null })) {
        Write-Info ("{0}:  剩余 {1}" -f $d.Name, (Format-Size $d.Free))
    }
    Write-Host ''
    Write-Ok ("SelfTest 完成，日志：{0}" -f $script:LogPath)
    return
}

try {
    Clear-Host
    Write-Host ''
    Write-Host '  ╔════════════════════════════════════════════════════════════╗' -ForegroundColor DarkCyan
    Write-Host '  ║      War Thunder × Steam   启动修复助手   v3.3             ║' -ForegroundColor DarkCyan
    Write-Host '  ║   用 25 GB 的精简客户端，跳过 Steam 的 88 GB 更新           ║' -ForegroundColor DarkCyan
    Write-Host '  ╚════════════════════════════════════════════════════════════╝' -ForegroundColor DarkCyan
    if ($script:DryRun) { Write-Host '                          [ 演练模式：只看不做 ]' -ForegroundColor Yellow }

    if (-not $script:AssumeYes) {
        Write-Host ''
        Write-Host '  这个工具帮你解决一件事：' -ForegroundColor White
        Write-Host '    Steam 想给战雷下 88 GB 的完整版，但你已经用官方启动器下好了 25 GB 的精简版。'
        Write-Host '    本工具把精简版交给 Steam，让 Steam 直接开游戏，并且照常使用你的 Steam 账号登录。'
        Write-Host ''
        Write-Host '  整个流程分两步：' -ForegroundColor White
        Write-Host '    1. 告诉你要把客户端放到哪个文件夹（你可以自己放，也可以让我帮你搬）'
        Write-Host '    2. 关闭 Steam、改好它的安装记录，再帮你打开游戏'
        Write-Host ''
        Write-Host '  每一步都会先问你，按回车就是“可以”。' -ForegroundColor DarkGray
        Write-Host ''
        Focus-ConsoleWindow
        Start-Sleep -Milliseconds 200
        [void](Wait-AnyKey -Prompt '  准备好了按任意键开始' -TimeoutSec 15)
    }

    $Env = Get-Environment
    Initialize-Workspace -Env $Env
    Show-Environment -Env $Env

    $check = Test-Preflight -Env $Env
    Show-Preflight -Check $check
    if (-not $check.Ok) {
        Write-Host ''
        Write-Warn '上面有需要先处理的问题，否则修复可能失败'
        if (-not (Ask-YesNo '仍然继续吗？' $false)) { return }
    }

    if ($Snapshot) {
        $d = New-WtSnapshot -Env $Env
        Write-Ok ("快照目录：{0}" -f $d)
        return
    }

    $action = 1
    if ($DownloadClient) { $action = 4 }
    elseif ($Simulate) { $action = 6 }
    elseif ($UndoSimulate) { $action = 7 }
    elseif (-not $script:AssumeYes) { $action = Show-Menu }

    switch ($action) {
        0 { Write-Info '已退出'; return }
        5 { Show-SnapshotMenu -Env $Env; return }
        6 {
            if (Set-SimulatedBrokenState -Env $Env) { Write-Ok '模拟完成，现在运行 [1] 一键修复来验证' }
            return
        }
        7 {
            if (Undo-SimulatedBrokenState -Env $Env) { Write-Ok '已撤销模拟' }
            return
        }
        2 {
            Write-Info '仅检测模式，不做任何修改'
            $src = @(Find-WTInstalls -Exclude @($Env.GameDir))
            if ($src.Count -gt 0) {
                Write-Host ''
                Write-Info '发现其它可用的客户端位置：'
                foreach ($s in $src) {
                    $t = Test-WTInstall -Path $s
                    $tag = if ($t.Valid) { '完整' } else { '缺 ' + ($t.Missing -join ',') }
                    Write-Host ("      {0}   {1}   {2}" -f $s, (Format-Size $t.Bytes), $tag)
                }
            }
            Write-Host ''
            Write-Info ("日志：{0}" -f $script:LogPath)
            Pause-Any
            return
        }
        3 {
            if (-not (Test-WTInstall -Path $Env.GameDir).Valid) {
                Write-Err '游戏目录里没有完整客户端，无法只修复清单'
                Pause-Any
                return
            }
            if (Repair-SteamManifest -Env $Env) {
                Write-Ok '清单修复完成'
                Start-SteamAndGame -Env $Env
            }
        }
        4 {
            $t = Invoke-DownloadClient -Env $Env
            if ($t -and $script:DryRun) { Write-Info 'DryRun 结束'; Pause-Any; return }
            if ($t) {
                $src = $t
                if (Ask-YesNo ("把下载好的客户端搬进 {0} ？" -f $Env.GameDir) $true) {
                    if (Move-ClientIntoLibrary -Source $src -Dest $Env.GameDir) {
                        if (Repair-SteamManifest -Env $Env) { Start-SteamAndGame -Env $Env }
                    }
                }
            }
        }
        1 {
            if (Invoke-Repair -Env $Env) {
                Write-Host ''
                Write-Ok '全部完成'
                Start-SteamAndGame -Env $Env
            }
        }
    }

    Write-Host ''
    Write-Host '  接下来做什么：' -ForegroundColor White
    Write-Host '   · 在 Steam 库里点「开始游戏」就行，第一次进游戏会比较慢'
    Write-Host '   · 千万别点 Steam 的「验证游戏文件完整性」，那会重新下 88 GB'
    Write-Host '   · 战雷每次大版本更新后，再运行一次本工具'
    Write-Host ("   · 日志在：{0}" -f $script:LogPath) -ForegroundColor DarkGray
    Pause-Any '  按回车关闭窗口'
}
catch {
    Write-Host ''
    Write-Err ("出错了：{0}" -f $_.Exception.Message)
    Write-Host ''
    Write-Host '  可以试试这些办法：' -ForegroundColor White
    Write-Host '   1. 右键本程序 → 以管理员身份运行'
    Write-Host '   2. 先完全退出 Steam，再重新运行'
    Write-Host '   3. 确认 G 盘（或游戏所在盘）还有足够空余空间'
    Write-Host '   4. 把 Steam 关闭后重启电脑再试一次'
    $diag = Write-Diagnostic -Env $Env -Reason $_.Exception.Message
    if ($diag) { Write-Host ("   诊断报告已保存：{0}" -f $diag) -ForegroundColor DarkGray }
    Write-Host ("   本次日志：{0}" -f $script:LogPath) -ForegroundColor DarkGray
    if (-not $script:AssumeYes) { Pause-Any }
    exit 1
}
