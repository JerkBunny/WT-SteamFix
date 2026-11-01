<#
.SYNOPSIS
    让 Steam 认为 War Thunder (appid 236390) 已是最新，从而跳过 90GB 更新、直接启动。

.DESCRIPTION
    原理：Steam 用 appmanifest_236390.acf 里 InstalledDepots 的 manifest gid
    与服务器当前 public 分支的 gid 做比较，不一致就判定"需要更新"。
    本脚本用 steamcmd 的 app_info_print 读取当前 public 的 gid 和 buildid，
    写进 InstalledDepots，并把 StateFlags 置为 4（FullyInstalled），
    于是 Steam 认为游戏已是最新，可以直接 Play。

    每次战雷大版本更新后（Steam 又出现"更新"、或开始下载 88GB）重跑一次即可。

.PARAMETER SteamPath
    Steam 安装目录（含 steam.exe），默认 E:\steam

.PARAMETER LibraryPath
    游戏所在的 Steam 库目录（含 steamapps），默认 G:\SteamLibrary

.PARAMETER DryRun
    只打印将要写入的内容，不修改任何文件

.EXAMPLE
    .\wt-skip-update.ps1
#>
param(
    [string]$SteamPath   = 'E:\steam',
    [string]$LibraryPath = 'G:\SteamLibrary',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$AppId    = '236390'
$AcfPath  = Join-Path $LibraryPath "steamapps\appmanifest_$AppId.acf"
$GameDir  = Join-Path $LibraryPath 'steamapps\common\War Thunder'
$SteamExe = Join-Path $SteamPath 'steam.exe'
$SteamCmd = Join-Path $PSScriptRoot 'steamcmd\steamcmd.exe'

function Write-Step($m) { Write-Host "[*] $m" -ForegroundColor Cyan }
function Write-Ok($m)   { Write-Host "[+] $m" -ForegroundColor Green }
function Write-Warn2($m){ Write-Host "[!] $m" -ForegroundColor Yellow }

if (-not (Test-Path -LiteralPath $AcfPath))  { throw "找不到 $AcfPath —— 请检查 -LibraryPath" }
if (-not (Test-Path -LiteralPath $GameDir))  { throw "找不到游戏目录 $GameDir" }
if (-not (Test-Path -LiteralPath $SteamCmd)) { throw "找不到 $SteamCmd" }

# ---------- 1. 关闭 Steam（运行中的 Steam 会覆写 acf） ----------
$running = Get-Process steam,steamwebhelper,steamservice -ErrorAction SilentlyContinue
if ($running -and -not $DryRun) {
    Write-Step '正在关闭 Steam...'
    Start-Process -FilePath $SteamExe -ArgumentList '-shutdown' -ErrorAction SilentlyContinue
    $deadline = (Get-Date).AddSeconds(90)
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-Process steam,steamwebhelper,steamservice -ErrorAction SilentlyContinue)) { break }
        Start-Sleep -Seconds 2
    }
    $left = Get-Process steam,steamwebhelper,steamservice -ErrorAction SilentlyContinue
    if ($left) { $left | Stop-Process -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 3 }
    Write-Ok 'Steam 已关闭'
}
elseif ($running) {
    Write-Warn2 '(DryRun) Steam 正在运行，实际执行时会先关闭它'
}

# ---------- 2. 查询当前 public 分支 ----------
Write-Step '通过 steamcmd 查询当前 public 分支的 manifest...'
$outFile = Join-Path $env:TEMP "wt_appinfo_$AppId.txt"
& $SteamCmd +login anonymous +app_info_update 1 +app_info_print $AppId +quit *> $outFile
$appInfo = Get-Content -LiteralPath $outFile -Raw -ErrorAction Stop
if (-not $appInfo) { throw 'steamcmd 没有输出' }

$buildId = $null
if ($appInfo -match '"branches"[\s\S]*?"public"\s*\{\s*"buildid"\s*"(\d+)"') { $buildId = $matches[1] }
if (-not $buildId) { throw '解析 appinfo 失败：找不到 public buildid' }

# 只更新 acf 里已登记的 depot，避免把 DLC/其他平台的 depot 混进来
$acfText = Get-Content -LiteralPath $AcfPath -Raw
$depotBlockMatch = [regex]::Match($acfText, '"InstalledDepots"([\s\S]*?)\n\t\}')
$depotIds = @()
if ($depotBlockMatch.Success) {
    $depotIds = [regex]::Matches($depotBlockMatch.Groups[1].Value, '(?m)^\t\t"(\d+)"') | ForEach-Object { $_.Groups[1].Value }
}
if (-not $depotIds) { $depotIds = @('236391', '236394') }

$depotInfo = @()
foreach ($id in ($depotIds | Select-Object -Unique)) {
    $pattern = '(?s)"' + $id + '"\s*\{[\s\S]*?"manifests"\s*\{\s*"public"\s*\{\s*"gid"\s*"(\d+)"\s*"size"\s*"(\d+)"'
    if ($appInfo -match $pattern) {
        $depotInfo += [pscustomobject]@{ Id = $id; Gid = $matches[1]; Size = $matches[2] }
    }
    else {
        Write-Warn2 "appinfo 里找不到 depot $id 的 public manifest，跳过该 depot"
    }
}
if (-not $depotInfo) { throw 'appinfo 中没有解析到任何 depot manifest，请检查 steamcmd 是否正常联网' }

Write-Host "    buildid = $buildId"
foreach ($d in $depotInfo) { Write-Host ("    depot {0}  gid {1}  size {2}" -f $d.Id, $d.Gid, $d.Size) }

# ---------- 3. 生成新的 acf ----------
$sizeOnDisk = (Get-ChildItem -LiteralPath $GameDir -Recurse -File -ErrorAction SilentlyContinue |
               Measure-Object Length -Sum).Sum
$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$owner = '0'
$om = [regex]::Match($acfText, '"LastOwner"\s+"(\d+)"')
if ($om.Success) { $owner = $om.Groups[1].Value }
$launcherPath = $SteamExe.Replace('\', '\\')

$L = New-Object System.Collections.Generic.List[string]
$L.Add('"AppState"')
$L.Add('{')
$L.Add(('	"appid"		"{0}"' -f $AppId))
$L.Add(('	"universe"		"1"'))
$L.Add(('	"LauncherPath"		"{0}"' -f $launcherPath))
$L.Add(('	"name"		"War Thunder"'))
$L.Add(('	"StateFlags"		"4"'))
$L.Add(('	"installdir"		"War Thunder"'))
$L.Add(('	"LastUpdated"		"{0}"' -f $now))
$L.Add(('	"LastPlayed"		"0"'))
$L.Add(('	"SizeOnDisk"		"{0}"' -f $sizeOnDisk))
$L.Add(('	"StagingSize"		"0"'))
$L.Add(('	"buildid"		"{0}"' -f $buildId))
$L.Add(('	"LastOwner"		"{0}"' -f $owner))
$L.Add(('	"DownloadType"		"1"'))
$L.Add(('	"UpdateResult"		"0"'))
$L.Add(('	"BytesToDownload"		"0"'))
$L.Add(('	"BytesDownloaded"		"0"'))
$L.Add(('	"BytesToStage"		"0"'))
$L.Add(('	"BytesStaged"		"0"'))
$L.Add(('	"TargetBuildID"		"{0}"' -f $buildId))
$L.Add(('	"AutoUpdateBehavior"		"1"'))
$L.Add(('	"AllowOtherDownloadsWhileRunning"		"2"'))
$L.Add(('	"ScheduledAutoUpdate"		"0"'))
$L.Add('	"InstalledDepots"')
$L.Add('	{')
foreach ($d in $depotInfo) {
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
$newAcf = ($L -join "`r`n") + "`r`n"

if ($DryRun) {
    Write-Host "`n----- 将要写入 $AcfPath -----" -ForegroundColor Magenta
    Write-Host $newAcf
    return
}

# ---------- 4. 备份 + 写入 ----------
$backupDir = Join-Path $PSScriptRoot 'backup'
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
$backup = Join-Path $backupDir ("appmanifest_{0}.acf.{1}.bak" -f $AppId, (Get-Date -Format 'yyyyMMdd_HHmmss'))
Copy-Item -LiteralPath $AcfPath -Destination $backup -Force
Write-Ok "已备份原 acf -> $backup"

Set-ItemProperty -LiteralPath $AcfPath -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue
Set-Content -LiteralPath $AcfPath -Value $newAcf -Encoding UTF8 -NoNewline
Write-Ok '已写入 appmanifest（FullyInstalled + 最新 public depot）'

# ---------- 5. 清理 Steam 的更新暂存 ----------
$dl = Join-Path $LibraryPath 'steamapps\downloading'
foreach ($f in @("state_${AppId}_236391.patch", "state_${AppId}_236394.patch")) {
    $p = Join-Path $dl $f
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue }
}
$staging = Join-Path $dl $AppId
if (Test-Path -LiteralPath $staging) {
    $items = Get-ChildItem -LiteralPath $staging -Recurse -File -ErrorAction SilentlyContinue
    if (-not $items) { Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue }
    else { Write-Warn2 "暂存目录里还有 $($items.Count) 个文件，未删除：$staging" }
}

# ---------- 6. 启动 Steam ----------
Write-Step '正在启动 Steam...'
Start-Process -FilePath $SteamExe
Write-Ok '完成。Steam 起来后，库里的 War Thunder 应显示"开始游戏"，不再显示"更新"。'
Write-Host '    注意：不要点 Steam 的"验证游戏文件完整性"，那会把 90GB 全下回来。' -ForegroundColor Yellow
