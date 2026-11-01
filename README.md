# WT-SteamFix

> 让 Steam 版《战争雷霆》用官方启动器下载的 **25 GB 精简客户端**直接启动，
> 跳过 Steam 完整版更新，同时保留 **Steam 账号登录**。

**状态：测试中（Beta）**

一个小工具，Windows 上双击即用。适用情况：战雷是用官方启动器装的精简版，
但 Steam 认为它没装完、要下80GB+，硬盘装不下，账号又只能走Steam登录。

---

## 它可以做什么

Steam 版战雷要更新 80+ GB，你可能已经有官方启动器下好的 25 GB 最小化客户端。
本工具把最小化客户端交给 Steam，让它直接开游戏，并照常用 Steam 账号登录。
（不用绑定邮箱、手机号）

## 怎么用

1. 打开 `WT-SteamFix.exe`
2. 根据你的需要输入就行（第一页按任意键继续，15 秒不按也会自动往下走）
3. 启动 Steam 后能正常启动战雷，就算成功了

也可以直接用命令行：

```powershell
WT-SteamFix.exe                 # 交互引导（推荐）
WT-SteamFix.exe -SelfTest       # 只体检，会真实查询 Steam 版本
WT-SteamFix.exe -DryRun         # 演练：只看不做
WT-SteamFix.exe -Yes            # 无人值守
WT-SteamFix.exe -Snapshot       # 建快照（acf + config.blk + 存档）
WT-SteamFix.exe -Simulate       # 制造故障现场（同盘改名，秒级）
WT-SteamFix.exe -UndoSimulate   # 撤销故障现场
WT-SteamFix.exe -DownloadClient # 自动下载官方客户端
WT-SteamFix.exe -SourcePath "D:\WarThunder"        # 客户端放哪了（盘符换成你的）
WT-SteamFix.exe -LibraryPath "D:\SteamLibrary"     # 你的 Steam 库在哪
WT-SteamFix.exe -InstallerPath "C:\Users\你\Downloads\wt_launcher.exe"
WT-SteamFix.exe -SkipMove -Yes  # 只修记录
WT-SteamFix.exe -Proxy http://127.0.0.1:端口      # 仅在确实要走代理时才用
```

## 客户端应该放哪里？（最重要）

Steam 只认带空格的那个名字，放这里：

```
<你的游戏库>\steamapps\common\War Thunder
例如 D:\SteamLibrary\steamapps\common\War Thunder
```

官方启动器默认装在 `D:\WarThunder`（没有空格）——这里的盘符只是举例，
实际装在哪取决于你在安装时选的位置，工具会自动去各个盘找。

所以有两种情况：

- 放 `common\WarThunder`（没空格）→ Steam 不认，工具会提示并帮你改名
- 把里面的内容复制进 `common\War Thunder`（有空格）→ 正确

复制时注意：

- 复制启动器文件夹里所有的内容，不要多套一层
  （放好后 `common\War Thunder\launcher.exe` 应该能直接看到）
- `.launcher_log`、`.game_logs`、`cache` 不用复制，复制了也没事

> 扫描客户端时只看内容不看目录名（`win64\aces.exe`、`aces.vromfs.bin` 等），
> 所以磁盘根目录、各 Steam 库的 `common\*`、`downloading\236390` 都能认出来。

## 写入前检查

工具在动手前会列出一张表：游戏目录、大小、关键文件、要修改的 Steam 记录。
确认没问题后再按回车，工具才会去关闭 Steam。

```
  写入前检查：
    游戏目录    D:\SteamLibrary\steamapps\common\War Thunder
    文件大小    25.42 GB（4253 个文件）
    关键文件    launcher.exe ✓   win64\aces.exe ✓   aces.vromfs.bin ✓
    Steam 库    D:\SteamLibrary
    Steam 记录  目前没有，会新建一份
    接下来     会先关闭 Steam（存档不会丢），再写入安装记录
```

答 `n` → `已取消，没有做任何修改`，一个字节都不动。

## 过程中会关掉 Steam

修改安装记录前必须先关 Steam（存档不受影响）。
工具会提前提示；如果你正在玩别的游戏或正在下载，请先自己退出或暂停，
然后按回车让它关。

## 一定要记住

- 不要点 Steam 的「验证游戏文件完整性」——会重新下 88 GB
- 战雷每次大版本建议在启动器完成，之后若出现抽风可重新使用本工具
- 第一次运行如果被 Windows 拦下，点「更多信息」→「仍要运行」

## 出问题怎么办

- 提示"没有写权限"：右键 exe → 以管理员身份运行
- 提示"找不到 Steam"：确认 Steam 位置，或用 `-SteamPath` 指定
- 其它报错：`logs\diagnostic_*.txt` 里有诊断报告，把它发给帮忙的人

## 文件在哪

| 目录 | 内容 |
|---|---|
| `logs\` | 日志 |
| `backup\` | 每次修改前的 Steam 记录 |
| `snapshots\` | 快照（菜单 5 里可以还原） |
| `.work\` | 临时文件 |

## 反馈

不清楚去哪反馈，可以找大肥鱼或GPT之类的，
或加 [@Jerkbunny61_Hana](https://t.me/Jerkbunny61_Hana)（Telegram）反馈。

---

## 原理（想了解再看）

Steam 判断"要不要更新"，看的是 `steamapps\appmanifest_236390.acf` 里
`InstalledDepots` 记录的 manifest id 与服务器上 public 分支是否一致。
把精简客户端放进 `common\War Thunder` 后，只要把这份记录改写成
"已安装 + 最新"，Steam 就会认为游戏是最新的，直接给「开始游戏」。

工具做的就是这个，并且：

- 按内容找客户端，`WarThunder` / `War Thunder` 两种目录名都认
- 改记录前先备份、先把要改的内容摊开给你看
- 需要时自动关闭 Steam
- 查不到 Steam 的版本信息时，回退用本机记录里残留的 `StagedDepots`

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
├── PUBLISHING.md            # 维护者：怎么发版、踩过的坑
└── README.md
```

## 构建

需要 Windows + .NET Framework 4.x（Win10/11 自带），不需要安装任何模块。

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

不想编译也可以直接从源码跑：

```powershell
.\src\WT-SteamFix.cmd
```

## 发版

打标签推上去就会自动构建并发布 Release：

```powershell
git tag v3.3.0-beta.2
git push origin v3.3.0-beta.2
```

完整流程、版本号规则和踩过的坑见 [PUBLISHING.md](PUBLISHING.md)。

## 已知问题

- **界面只有中文**，英文用户需要靠 `docs\使用说明.txt` 对照操作。
- **下载安装包可能失败**：`warthunder.com` 的下载链会跳到
  `yupmaster-proxy-02.gaijin.net`，如果本机证书吊销检查连不上
  （`schannel 0x80092013`）就会 TLS 失败。工具会依次尝试
  `curl --ssl-no-revoke` → `.NET`（关闭吊销检查）→ 本机已有的
  `wt_launcher*.exe` → 手动输入路径，并在安装前校验
  Authenticode 签名主体必须是 GAIJIN。
- **代理不要照抄**：工具默认跟随系统代理，一般什么都不用填。
  只有你明确知道自己挂了本地代理（如 Clash / v2rayN 监听 `127.0.0.1:7890` 之类）
  且下载失败时，才用 `-Proxy` 显式指定，端口照抄别人的不一定对得上——
  有的环境反而是**关掉代理**才连得通。
- **无人值守会按剩余空间选库**：`-Yes` 且没有安装记录时选剩余空间最大的库，
  可能不是你放游戏的那个，建议手动选。
- **路径别带特殊字符**：放在 `C:\Users\你\Desktop` 这类含中文、空格的
  用户目录下一般没问题，但**别用网盘同步目录**（OneDrive 等）和只读的
  `Program Files`，跨盘搬运 25 GB 还要看目标盘是否够空间。

## 免责声明

- 非官方工具，与 Gaijin / Valve 无关。
- 修改 `appmanifest` 属于非标准操作，出问题请先用工具里的快照/备份还原。
- 请自行确认所在地区与账号条款允许此类操作，风险自负。

## 许可

仓库未附带开源许可证，如需分发请自行添加（例如 MIT）。
