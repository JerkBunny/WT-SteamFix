#Requires -Version 5.1
<#
.SYNOPSIS
    把 src\WT-SteamFix.ps1 打包成单文件 exe（输出到 dist\）。
.DESCRIPTION
    用 .NET Framework 自带的 csc.exe 编译一个 C# 宿主，
    把 PowerShell 脚本、steamcmd.zip、图标作为资源嵌进去。
    - 脚本：src\WT-SteamFix.ps1
    - 宿主：src\host\Host.cs
    - 图标：build\app.ico（没有就自动从本机战雷客户端取，取不到就不带图标）
    - steamcmd.zip：build\cache\steamcmd.zip（没有就自动下载）
.EXAMPLE
    .\build\Build-Exe.ps1
#>
[CmdletBinding()]
param(
    [string]$OutDir
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if (-not $OutDir) { $OutDir = Join-Path $root 'dist' }

$scriptPs = Join-Path $root 'src\WT-SteamFix.ps1'
$hostCs   = Join-Path $root 'src\host\Host.cs'
$docsFile = Join-Path $root 'docs\使用说明.txt'
$icon     = Join-Path $PSScriptRoot 'app.ico'
$zip      = Join-Path $PSScriptRoot 'cache\steamcmd.zip'
$zipUrl   = 'https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip'

# 图标候选：优先用 build\app.ico，其次从本机战雷客户端里取
$iconSrcs = @(
    $icon,
    'G:\SteamLibrary\steamapps\common\War Thunder\icon.ico',
    'G:\WarThunder\icon.ico',
    'E:\steam\steamapps\common\War Thunder\icon.ico',
    'D:\SteamLibrary\steamapps\common\War Thunder\icon.ico',
    'F:\SteamLibrary\steamapps\common\War Thunder\icon.ico'
)

function Find-Csc {
    $cands = @(
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
    )
    foreach ($c in $cands) { if (Test-Path -LiteralPath $c) { return $c } }
    throw '找不到 csc.exe（需要 .NET Framework 4.x）'
}

if (-not (Test-Path -LiteralPath $scriptPs)) { throw "找不到 $scriptPs" }
if (-not (Test-Path -LiteralPath $hostCs))   { throw "找不到 $hostCs" }

# 脚本必须是 UTF-8 BOM，否则 Windows PowerShell 5.1 会把中文读成乱码
$txt = [System.IO.File]::ReadAllText($scriptPs, [System.Text.Encoding]::UTF8)
[System.IO.File]::WriteAllText($scriptPs, $txt, (New-Object System.Text.UTF8Encoding($true)))

# 图标
$iconPath = $null
foreach ($c in $iconSrcs) {
    if ($c -and (Test-Path -LiteralPath $c)) {
        $iconPath = $c
        if ($c -ne $icon) { Copy-Item -LiteralPath $c -Destination $icon -Force; $iconPath = $icon }
        Write-Host "[+] 图标：$c"
        break
    }
}
if (-not $iconPath) { Write-Host '[!] 没有图标，使用 exe 默认图标' }

# steamcmd.zip（嵌进 exe，目标机器首次运行不需要联网）
if (-not (Test-Path -LiteralPath $zip)) {
    Write-Host '[*] 下载 steamcmd.zip 用于内嵌...'
    New-Item -ItemType Directory -Force -Path (Split-Path $zip) | Out-Null
    Invoke-WebRequest -Uri $zipUrl -OutFile $zip -UseBasicParsing -TimeoutSec 180
}
Write-Host ("[+] steamcmd.zip：{0:N0} KB" -f ((Get-Item $zip).Length / 1KB))

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$out = Join-Path $OutDir 'WT-SteamFix.exe'
if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Force }

$csc = Find-Csc
$cscArgs = @(
    '/nologo',
    '/target:exe',
    '/platform:anycpu',
    '/optimize+',
    ("/out:{0}" -f $out),
    ("/resource:{0},WT-SteamFix.ps1" -f $scriptPs),
    ("/resource:{0},steamcmd.zip" -f $zip),
    '/r:System.IO.Compression.FileSystem.dll',
    $hostCs
)
if ($iconPath) { $cscArgs = @("/win32icon:$iconPath") + $cscArgs }

Write-Host '[*] 编译中...'
& $csc @cscArgs
if ($LASTEXITCODE -ne 0) { throw "csc 编译失败（exit $LASTEXITCODE）" }
if (-not (Test-Path -LiteralPath $out)) { throw '没有生成 exe' }

# 说明文档一起放进 dist，方便直接打包发布
if (Test-Path -LiteralPath $docsFile) {
    Copy-Item -LiteralPath $docsFile -Destination (Join-Path $OutDir (Split-Path $docsFile -Leaf)) -Force
}

$fi = Get-Item -LiteralPath $out
Write-Host ''
Write-Host ("[+] 生成：{0}" -f $fi.FullName) -ForegroundColor Green
Write-Host ("    大小：{0:N0} KB   版本：{1}" -f ($fi.Length / 1KB), $fi.VersionInfo.FileVersion)
