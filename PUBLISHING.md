# 发布与维护指南（PUBLISHING）

这份文档写给仓库维护者，讲怎么把改好的东西发出去，以及踩过的坑。
普通用户看 [README.md](README.md) 或 [docs/使用说明.txt](docs/使用说明.txt) 就够了。

---

## 一、正常发布流程（三条命令）

改完代码或文档后：

```powershell
cd C:\Users\Administrator\Documents\deepseek-harness\default-workspace\wt

git add -A
git commit -m "fix: 修了什么"       # 说明改了什么
git push                            # 推到 GitHub（main 分支）

git tag v3.3.0-beta.2               # 打版本标签
git push origin v3.3.0-beta.2       # 推标签 → 自动构建并发布
```

**推标签之后你就不用管了**，GitHub Actions 会自动：

1. 在 windows-latest 上跑 `build/Build-Exe.ps1` 编出 exe
2. 把 exe 和说明复制成 ASCII 文件名放进 `out/`
3. 用 `gh release create` 发布 Release，附上两个文件
4. 标签里带 `beta` / `rc` / `alpha` 会自动勾上 Pre-release

大约 25 秒完成，去 Releases 页面刷新就能看到。

---

## 二、版本号怎么起

用 `v<主版本>.<次版本>.<修订>-<阶段>.<序号>` 的格式：

| 例子 | 什么时候用 |
|---|---|
| `v3.3.0-beta.1` | 测试版，可能有问题，朋友之间试 |
| `v3.3.0-beta.2` | 修了 beta.1 的 bug |
| `v3.3.0-rc.1` | 候选版，功能冻结，只剩挑刺 |
| `v3.3.0` | 正式版，稳定可用 |

**改了什么 → 哪个数字动**：

- 改了文字、说明、README → 不动版本号也行，但发新标签会生成新 Release
- 修了 bug → 修订号 +1（`v3.3.1`）
- 加新功能 → 次版本 +1（`v3.4.0`）
- 大改架构 → 主版本 +1（`v4.0.0`）

---

## 三、⚠️ 重发同一个版本号的注意事项

**这是最容易踩的坑。** 如果某个版本发坏了，要重发，务必按这个顺序：

```powershell
# 1. 删远程标签（连同上面的 Release）
git push origin :refs/tags/v3.3.0-beta.1

# 2. 删本地标签
git tag -d v3.3.0-beta.1

# 3. ⚠️ 等至少 40 秒，让 GitHub 后端同步完
Start-Sleep -Seconds 45

# 4. 确认真的清干净了
#    浏览器打开 https://github.com/JerkBunny/WT-SteamFix/releases
#    看不到刚才那个版本才能继续

# 5. 重新打标签推送
git tag v3.3.0-beta.1
git push origin v3.3.0-beta.1
```

**为什么必须等？** 删掉标签后 GitHub 的 Release 记录不会立刻消失，
立刻重推会出现两种情况：

- `Too many retries.` —— 上传附件时 API 一直在重试
- 或者发布了一个**没有附件**的空 Release（有文字、没文件）

实测：不等的话连续 3 次都失败，等了 45 秒一次就过。

**更稳的替代方案**：如果只是想在重跑一次构建，**不要动标签**，
直接去 Actions 页面点失败那次的 **Re-run jobs** 按钮。

---

## 四、附件名的坑

GitHub 的 Release 上传接口**对中文文件名处理有 bug**：
`使用说明.txt` 上传后会变成 `default.txt`，用户下载下来一脸懵。

所以 [build.yml](.github/workflows/build.yml) 里多了一步 `Stage assets`：

```yaml
Copy-Item 'dist/使用说明.txt' 'out/GUIDE-zh-CN.txt'
```

**先复制成 ASCII 名再上传**。以后加新附件也照这个规则：文件名用英文。

---

## 五、为什么用 gh CLI 而不是第三方 action

之前的版本用的是 `softprops/action-gh-release@v2`，在这个仓库**连续三次失败**，
错误固定是 `Too many retries.`，表现为"Release 创建成功但附件 0 个"。

换成 `gh` 命令行就稳了。当前的做法：

```yaml
- name: Publish release
  shell: pwsh
  env:
    GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
  run: |
    gh release create $tag out/WT-SteamFix.exe out/GUIDE-zh-CN.txt `
      --title "$tag" --notes-file release-notes.md --prerelease
```

并且加了兜底：如果 `create` 失败，就 `gh release upload --clobber` 往已有的 Release 里塞文件。

> `gh` 在 GitHub 的 runner 上是预装的，不需要额外安装步骤。

---

## 六、验证发布成功

推完标签后，去这几处确认：

**1. Actions 页面**

```
https://github.com/JerkBunny/WT-SteamFix/actions
```

最新一次运行应该显示绿勾。点进去看步骤，`Publish release` 必须是 success。

**2. Releases 页面**

```
https://github.com/JerkBunny/WT-SteamFix/releases
```

应该能看到版本号、说明文字、以及下方 **Assets** 里的两个文件。

**3. 实际下载一次**

点 `WT-SteamFix.exe` 下载，文件大小应该在 **840 KB 左右**。
如果下下来是 0 字节或者是个 HTML，说明附件没传成功。

> ⚠️ CI 编出来的 exe（842 KB）比你本地编的（986 KB）小一些，
> 这是正常的——CI 环境没有本机那个图标文件，编出来不带图标。

---

## 七、Release 说明怎么写

版本说明在 [build.yml](.github/workflows/build.yml) 的 `Write release notes` 步骤里，
是一段内嵌的 Markdown。**每次发版都该更新它**，至少改这几处：

- 这版改了什么（新增 / 修复 / 已知问题）
- 如果用法有变化，把「三步上手」同步改掉
- Beta 版本要提醒用户"这是测试版，出问题带日志反馈"

改完之后照常 `git push` 再打标签。

---

## 八、日常维护清单

| 想做什么 | 怎么做 |
|---|---|
| 改 README | 本地改 → commit → push。GitHub 首页会自动更新 |
| 改使用说明 | 改 `docs/使用说明.txt` → push。**注意保存为 UTF-8 with BOM** |
| 改程序逻辑 | 改 `src/WT-SteamFix.ps1` → **本地跑一次构建测试** → push |
| 收用户反馈 | 仓库的 **Issues** 标签 |
| 看谁改了什么 | 提交历史，或装 GitLens 插件 |
| 回滚某次改动 | `git revert <提交号>` → push |
| 删除某个 Release | Releases 页面 → 该版本右上角 → Delete |

---

## 九、本地构建测试（推之前建议跑）

改了源码后，**先在本地确认能编译、能跑**，再推上去：

```powershell
cd C:\Users\Administrator\Documents\deepseek-harness\default-workspace\wt

# 编译
powershell -ExecutionPolicy Bypass -File .\build\Build-Exe.ps1

# 产物在 dist\，直接跑一下体检（不会修改任何东西）
.\dist\WT-SteamFix.exe -SelfTest
```

看到 `dist\WT-SteamFix.exe` 生成、大小约 986 KB，就算编译成功。

> exe **不会进 git**（`.gitignore` 挡着），它是通过 Release 分发的。
> 所以"推送代码"和"别人能下到新 exe"是两件事，必须发 Release 才行。

---

## 十、常见问题

**Q：推了 tag 但 Actions 没跑？**

去 Settings → Actions → General，确认选了 `Allow all actions and reusable workflows`。

**Q：Actions 跑成功了但 Releases 页面没东西？**

等 30 秒再刷新。GitHub 的 API 有缓存延迟，实测要等一会儿。

**Q：想发布但不想要 Pre-release 标记？**

标签名里不要带 `beta` / `rc` / `alpha`，比如直接用 `v3.3.0`。

**Q：能不能不发 Release，只让别人从仓库下载？**

不能。exe 在 `.gitignore` 里，仓库里没有二进制文件，
必须走 Release 才能给别人下载。

**Q：git push 提示连不上？**

检查 `git config --global --get http.proxy`。之前配过一个失效的
`127.0.0.1:7897`，导致推送失败。清掉就好了：

```powershell
git config --global --unset http.proxy
git config --global --unset https.proxy
```
