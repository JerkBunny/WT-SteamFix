# WT-SteamFix

> 让 Steam 版《战争雷霆》用官方启动器下载的 **25 GB 精简客户端**直接启动，
> 跳过 Steam 那 **88 GB** 的完整版更新，同时保留 **Steam 账号登录**。
>
> Let the Steam build of War Thunder run from the **25 GB minimal client**
> downloaded by the official launcher, skipping the **88 GB** full update,
> while still signing in with your **Steam account**.

**状态 / Status: 测试中 · Beta**

[中文](#中文) · [English](#english)

---

# 中文

## 这是什么

一个 Windows 上运行的 PowerShell 小工具，打包成单个 exe，双击即用。
适合这种情况：战雷是用官方启动器装的精简版，但 Steam 认为它没装完、
要下 88 GB，而你的硬盘装不下，账号又只能走 Steam 登录。

## 它解决什么问题

Steam 判断"要不要更新"，看的是 `steamapps\appmanifest_236390.acf` 里
`InstalledDepots` 记录的 manifest id 与服务器上 public 分支是否一致。
把精简客户端放进 `common\War Thunder` 后，只要把这份记录改写成
"已安装 + 最新"，Steam 就会认为游戏是最新的，直接给「开始游戏」。

本工具做的就是这件事，并且：

- 自动找客户端（`WarThunder` / `War Thunder` 两种目录名都认）
- 改记录前先备份、先把要改的内容摊开给你看
- 需要时自动关闭 Steam
- 查不到 Steam 的版本信息时，回退用本机记录里残留的 `StagedDepots`

## 界面

```
  ╔════════════════════════════════════════════════════════════╗
  ║  War Thunder × Steam   启动修复助手   [ 测试中 / Beta ]    ║
  ║  用 25 GB 的精简客户端，跳过 Steam 的 88 GB 更新           ║
  ╚════════════════════════════════════════════════════════════╝

  ── 检查结果 ─────────────────────────────
  Steam 装在  e:\steam
  游戏库      G:\SteamLibrary
  游戏目录    G:\SteamLibrary\steamapps\common\War Thunder
  游戏文件    已就绪（25.42 GB，4254 个文件）
  Steam 记录  有（可以修）
  磁盘剩余    32.06 GB
  [√] 找到了 Steam
  [√] 游戏目录可以写入
  [√] Steam 安装记录可以修改
  [√] 磁盘剩余 32.06 GB
  [√] 程序目录可以写日志和备份

  你想做什么？
   [1] 修好它（不知道选哪个就选这个）
   [2] 先看看情况（只看不改，很安全）
   [3] 游戏文件已经放好了，只修 Steam 记录
   [4] 我还没有客户端，帮我下载一份（约 25 GB）
   [5] 备份 / 还原 / 测试（进阶，一般用不到）
   [0] 退出
```

## 目录结构

```
.
├── src/                     # 源码
│   ├── WT-SteamFix.ps1      # 主程序（PowerShell 5.1）
│   ├── WT-SteamFix.cmd      # 从源码直接运行的入口
│   ├── host/Host.cs         # exe 宿主：解压脚本 / steamcmd，调用 powershell
│   └── legacy/              # 早期精简版脚本（只修记录）
├── build/
│   ├── Build-Exe.ps1        # 打包脚本（csc 编译，内嵌资源）
│   └── app.ico              # 可选图标（不提交，构建时自动取用）
├── docs/
│   └── 使用说明.txt          # 给最终用户的一页纸
├── dist/                    # 构建产物（.gitignore）
│   ├── WT-SteamFix.exe
│   └── 使用说明.txt
├── .github/workflows/build.yml
└── README.md
```

## 构建

需要 Windows + .NET Framework 4.x（Win10/11 自带）。不需要安装任何模块。

```powershell
git clone <this repo>
cd WT-SteamFix
powershell -ExecutionPolicy Bypass -File .\build\Build-Exe.ps1
# 产物：dist\WT-SteamFix.exe
```

`Build-Exe.ps1` 会：

1. 给 `src\WT-SteamFix.ps1` 写 UTF-8 BOM（PS 5.1 读中文必须）
2. 准备图标（`build\app.ico`；没有就从本机战雷客户端取；都取不到就不带图标）
3. 下载 `steamcmd.zip` 到 `build\cache\`（首次）
4. 用 `csc.exe` 编译 `src\host\Host.cs`，把脚本 / steamcmd / 图标作为资源嵌入
5. 把 `docs\使用说明.txt` 一起放进 `dist\`

也可以直接从源码跑，不用编译：

```powershell
.\src\WT-SteamFix.cmd
```

## 使用

双击 `dist\WT-SteamFix.exe`，按提示走。或者用命令行：

```powershell
WT-SteamFix.exe                 # 交互引导（推荐）
WT-SteamFix.exe -SelfTest       # 只体检，含真实查询 Steam 版本
WT-SteamFix.exe -DryRun         # 演练：只看不做
WT-SteamFix.exe -Yes            # 无人值守
WT-SteamFix.exe -Snapshot       # 建快照（acf + config.blk + 存档）
WT-SteamFix.exe -Simulate       # 制造故障现场（同盘改名，秒级）
WT-SteamFix.exe -UndoSimulate   # 撤销故障现场
WT-SteamFix.exe -DownloadClient # 自动下载官方客户端
WT-SteamFix.exe -SourcePath "G:\WarThunder"
WT-SteamFix.exe -LibraryPath "G:\SteamLibrary"
WT-SteamFix.exe -InstallerPath "D:\wt_launcher.exe"
WT-SteamFix.exe -SkipMove -Yes  # 只修记录
WT-SteamFix.exe -Proxy http://127.0.0.1:7890
```

## 工作原理

1. **找客户端**：按内容而不是目录名判断（`win64\aces.exe`、`aces.vromfs.bin` …），
   扫描各盘根目录/下一层、每个 Steam 库的 `common\*`、`downloading\236390`。
2. **放进库**：同盘用改名（秒级、不占额外空间），跨盘复制+删除，带进度。
3. **改记录**：关闭 Steam → 备份 acf → 用 steamcmd 查 public 分支的
   `buildid` 和每个 depot 的 `gid/size` → 写入 `StateFlags=4`（已安装）、
   `BytesToDownload=0`、`InstalledDepots=<最新>` → 清掉 `state_*.patch`。
4. **启动**：拉起 Steam，可选直接 `steam://rungameid/236390`。

## 常见问题

**为什么要关 Steam？**
Steam 退出时会把内存里的状态写回 `appmanifest_*.acf`，不关会被覆盖回去。
工具会先提示、先备份，然后才关。

**会不会丢存档？**
不会。改的只是 Steam 的安装记录；存档在
`%USERPROFILE%\Documents\My Games\WarThunder\Saves`，工具还提供快照/还原。

**以后战雷更新了怎么办？**
Steam 的 buildid 会变，重新跑一次 `[1]` 或 `[3]` 即可。

**为什么下载安装包会失败？**
`warthunder.com` 的下载链会跳到 `yupmaster-proxy-02.gaijin.net`，
如果本机证书吊销检查连不上（`schannel 0x80092013`）就会 TLS 失败。
工具会依次尝试 `curl --ssl-no-revoke` → `.NET`（关闭吊销检查）→
本机已有的 `wt_launcher*.exe` → 手动输入路径，并且在安装前校验
**Authenticode 签名主体必须是 GAIJIN**。

## 免责声明

- 非官方工具，与 Gaijin / Valve 无关。
- 修改 `appmanifest` 属于非标准操作，出问题请先用工具里的快照/备份还原。
- 请自行确认所在地区与账号条款允许此类操作，风险自负。

## 许可

仓库未附带开源许可证，如需分发请自行添加（例如 MIT）。

---

# English

## What it is

A small Windows PowerShell tool, packaged as a single `.exe`.
It is for the case where War Thunder was installed with the **official
launcher** (the ~25 GB minimal client), but **Steam thinks it is not
installed** and wants to download the **88 GB** full build — while your
disk cannot hold it and the account can only sign in through Steam.

## What it actually changes

Steam decides whether an app needs an update by comparing the
`InstalledDepots` manifest ids in `steamapps\appmanifest_236390.acf`
with the ones on the public branch of the CDN. Put the minimal client in
`common\War Thunder`, rewrite that record as "installed + up to date",
and Steam will offer **Play** instead of **Update**.

The tool does exactly that, plus:

- finds the client by content, not by folder name (`WarThunder` or `War Thunder`)
- backs up the record and shows you what will change before touching it
- closes Steam only when needed (and says so first)
- falls back to the `StagedDepots` left in the local acf when Steam cannot be reached

## Structure

```
.
├── src/                     # source
│   ├── WT-SteamFix.ps1      # main script (PowerShell 5.1)
│   ├── WT-SteamFix.cmd      # run from source
│   ├── host/Host.cs         # exe host: unpacks script + steamcmd, calls powershell
│   └── legacy/              # older minimal script (manifest only)
├── build/
│   ├── Build-Exe.ps1        # packaging (csc, embedded resources)
│   └── app.ico              # optional icon (not committed; picked up at build)
├── docs/
│   └── 使用说明.txt          # one-page guide for end users
├── dist/                    # build output (gitignored)
├── .github/workflows/build.yml
└── README.md
```

## Build

Requires Windows and .NET Framework 4.x (bundled with Win10/11). No modules.

```powershell
git clone <this repo>
cd WT-SteamFix
powershell -ExecutionPolicy Bypass -File .\build\Build-Exe.ps1
# output: dist\WT-SteamFix.exe
```

The script writes a UTF-8 BOM to `src\WT-SteamFix.ps1` (required for
Windows PowerShell 5.1 to read the Chinese text correctly), prepares the
icon, downloads `steamcmd.zip` into `build\cache\` on first run, then
compiles `src\host\Host.cs` with `csc.exe` and embeds the script,
steamcmd and icon as resources.

Run directly from source without building:

```powershell
.\src\WT-SteamFix.cmd
```

## Usage

Double-click `dist\WT-SteamFix.exe` and follow the prompts. CLI:

```powershell
WT-SteamFix.exe                 # interactive (recommended)
WT-SteamFix.exe -SelfTest       # diagnostics only, queries Steam for real
WT-SteamFix.exe -DryRun         # dry run, changes nothing
WT-SteamFix.exe -Yes            # unattended
WT-SteamFix.exe -Snapshot       # snapshot acf + config + saves
WT-SteamFix.exe -Simulate       # simulate the broken state (instant rename)
WT-SteamFix.exe -UndoSimulate   # undo the simulation
WT-SteamFix.exe -DownloadClient # download the official client
WT-SteamFix.exe -SourcePath "G:\WarThunder"
WT-SteamFix.exe -LibraryPath "G:\SteamLibrary"
WT-SteamFix.exe -InstallerPath "D:\wt_launcher.exe"
WT-SteamFix.exe -SkipMove -Yes  # manifest only
WT-SteamFix.exe -Proxy http://127.0.0.1:7890
```

## How it works

1. **Find the client** by content (`win64\aces.exe`, `aces.vromfs.bin`, …),
   scanning drive roots and their first level, each Steam library's
   `common\*`, and `downloading\236390`.
2. **Put it in the library** — a rename when the source is on the same
   volume (instant, no extra space), copy+delete across volumes, with progress.
3. **Rewrite the record** — stop Steam, back up the acf, ask steamcmd for the
   public `buildid` and each depot's `gid/size`, write `StateFlags=4`,
   `BytesToDownload=0`, `InstalledDepots=<latest>`, then clean `state_*.patch`.
4. **Start** — launch Steam, optionally `steam://rungameid/236390`.

## FAQ

**Why does Steam have to be closed?**
On exit Steam writes its in-memory state back to `appmanifest_*.acf`;
editing it while Steam runs gets overwritten. The tool warns, backs up,
then closes it.

**Will I lose my saves?**
No. Only Steam's install record is touched. Saves live in
`%USERPROFILE%\Documents\My Games\WarThunder\Saves`, and the tool offers
snapshot/restore.

**War Thunder got an update, what now?**
The build id changes, so just run `[1]` or `[3]` again.

**The launcher download fails — why?**
`warthunder.com` redirects to `yupmaster-proxy-02.gaijin.net`; if the
certificate revocation check cannot reach the network
(`schannel 0x80092013`) the TLS handshake fails. The tool tries
`curl --ssl-no-revoke`, then .NET (revocation check disabled), then any
local `wt_launcher*.exe`, then a manual path — and always verifies that
the installer is **Authenticode-signed by GAIJIN** before running it.

**Does this trigger anti-cheat?**
No. It only edits the local install record so Steam believes the files are
complete; the game and its login flow stay official. Use it on your own
account only.

## Disclaimer

- Unofficial project, not affiliated with Gaijin or Valve.
- Editing `appmanifest` is a non-standard operation. If something breaks,
  restore from the snapshot/backup the tool creates.
- Make sure your region and account terms allow this. Use at your own risk.

## License

No license is included; add one (e.g. MIT) if you plan to redistribute.
