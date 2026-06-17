[English](./release-checklist.md) | **中文**

# 发布检查清单

在为 SimpleZip 打发布 tag 之前使用本清单。目标是：每一项要么被勾选完成，
要么在 PR 描述中给出明确的跳过理由。

参考资料：
- CI 工作流：`.github/workflows/pr.yml`（PR / push 检查），
  `.github/workflows/release.yml`（tag push 或手动 workflow_dispatch）。
- 威胁模型：[`SECURITY.md`](../SECURITY.zh-CN.md)。
- 架构：[`docs/ARCHITECTURE.md`](./ARCHITECTURE.zh-CN.md)。

---

## 1. `main` 上的代码为绿

- [ ] `pr.yml` 在最新的 `main` 提交上通过。
- [ ] `swift test --scratch-path /private/tmp/SimpleZipSwiftPM` 在本地通过。
      应当有 ≥460 个 `@Test` 用例（swift-testing）——更少意味着测试被悄悄丢弃了。
- [ ] `xcodebuild -project SimpleZip.xcodeproj -scheme SimpleZip -configuration Debug build`
      在本地通过（捕捉 SwiftPM 漏掉的、仅在 Xcode target 才出现的问题）。
- [ ] 本次发布中任何新增的业务逻辑都已添加或更新对应的测试。
- [ ] Fixture 库仍然有效：如果发生了任何 `parseSevenZipList` /
      `parseUnzipList` / `detectZipEncryption` / `ArchiveSafety` 的改动，
      对应的 `ArchiveServiceFixtureTests` 用例
      也已更新以匹配。

## 2. 已审查安全敏感区域

- [ ] 对 `ArchiveSafety` 的任何改动都保留现有的不安全名称检测
      （路径穿越、绝对路径、Windows 盘符路径、UNC 路径）。
- [ ] 对符号链接 / 硬链接解压路径的任何改动，在 **Ask** 模式下仍会弹出
      确认，在 **Always block** 模式下仍会拦截。
- [ ] 对**活动内容**检测的任何改动仍然会捕捉到
      `.app`、`.pkg`、`.command`、`.sh`、`.scpt`、脚本、HTML、Office 文件。
- [ ] 对 `passwordResponses` / PTY 输入路径的任何改动都保持密码
      不出现在命令行参数中。
- [ ] 对 `PresetPasswordStore` 的任何改动：
  - 保留 `kSecAttrAccessibleAfterFirstUnlock`（不是 `WhenUnlocked`，也不是
    无属性——两者都会在重启场景下降低可靠性）；
  - 在设置 UI 上为「显示密码」保留 Touch ID 门槛；
  - 在 `clear()` / `save()` 时保留进程缓存失效；
  - **不**意外地添加对密码值的日志记录。
- [ ] 如果新功能引入了新的文件处理代码路径，
    在 `SECURITY.md` 的「User-Facing Security Controls」或
    「Threat Model」章节中添加一条记录。

## 3. 兼容性回归

- [ ] 在干净的 macOS 用户账户（或新虚拟机）上手动验证：
  - 打开有代表性的 `.zip`、`.7z`、`.tar`、`.tar.gz`、`.rar`、
    `.dmg`；
  - 解压一个受密码保护的 ZIP（AES-256）和一个头部加密的 7z；
  - 创建一个多卷 7z（例如 `-v64m`）；
  - 计算一个文件夹的哈希值。
- [ ] Finder 集成：右键点击文件夹 → SimpleZip →「添加到
      归档」可用，右键点击归档显示预期的操作。
- [ ] 如果本次构建启用了预设密码：
  - 在配备 Touch ID 的 Mac 上 Touch ID 显示仍然有效；
  - 在没有 Touch ID 的 Mac 上登录密码回退有效；
  - 关闭主开关仍然会清除钥匙串条目
    （用 **Keychain Access.app** 验证）。

## 4. 本地化检查

- [ ] 新的 `Localizable.strings` 键存在于全部 10 个 lproj 目录中。
  （拿不准时：`comm -23 <(grep -oP '\"[^\"]+\"\s*=' en.lproj/Localizable.strings | sort) <(grep -oP '\"[^\"]+\"\s*=' zh-Hans.lproj/Localizable.strings | sort)` 应当为空。）
- [ ] 当应用以另一种语言作为活动区域设置运行时，没有未翻译的
      英文字符串出现。

## 5. 版本号与 CHANGELOG

- [ ] `Info.plist` 的 `CFBundleShortVersionString` 与发布版本号匹配。
- [ ] `CHANGELOG.md` 和 `CHANGELOG.zh-CN.md` 都有一个 `## <version>`
      章节，列出对用户可见的变更，而不仅仅是代码挪位。
- [ ] 内部重构汇总在「Internal refactor」子章节下，
      以便用户跳过。
- [ ] Bug 修复携带足够的上下文，以便按症状搜索
      （「password-protected list returned empty」而非「fix parser」）。
- [ ] 如果某个新格式获得了支持，更新 `README.md` 的亮点 /
      格式列表。

## 6. 切出发布

- [ ] 在 `main` 上：用 `v<version>` 打 tag（若已配置签名密钥则用
      `git tag -s v0.1.6 -m "..."`；否则用 `-a`）。
- [ ] 推送 tag：`git push origin v<version>`。
- [ ] `release.yml` 触发；验证该工作流运行：
  - SwiftPM 测试通过（打包前的最后一道防线）；
  - RAR 后端安装步骤成功；
  - DMG 制品作为 `SimpleZip-dmg` 上传；
  - **Sparkle「Sign DMG with sign_update」步骤成功**——该步骤在
    GitHub Actions 日志中的输出会显示 `sparkle:edSignature="..." length="..."`；
    如果它以「SPARKLE_ED_PRIVATE_KEY secret is not set」失败，则需要
    重新上传该 GitHub Secret（见 `secrets/README.md`）；
  - GitHub release 自动创建，附带 DMG 以及从 CHANGELOG.md 提取的发布说明。
- [ ] **验证已发布 appcast 中的 Sparkle 签名**：工作流完成后，
      在本地运行 `./scripts/verify_appcast.sh`——它会
      下载已发布的 DMG，并使用 `Info.plist` 中的公钥
      重新验证 `sparkle:edSignature`。除 `OK` 以外的任何结果
      都意味着 0.1.10+ 上通过 Sparkle 安装的用户会看到
      「could not verify authenticity」提示。
- [ ] 如果工作流在 tag 运行时失败，**不要删除或移动该 tag**——
      删除 tag 会把已经创建的 GitHub release 翻转为*草稿*，使
      公开 DMG URL 返回 404，并让 appcast 指向死链。Tag 是只能追加的。
      正确做法是：在 `main` 上向前修复、推送，并切出下一个补丁 tag `v<version>.1`。
      在推送之前确保 `main` 已 fast-forward/推送到位、且 tag 指向正确的
      提交，这样它就永远不必移动。

## 7. 发布后

- [ ] 从 GitHub release 下载已发布的 DMG，并在干净的 Mac 上打开，
      进行冒烟测试：
  - Gatekeeper 正常放行（符合预期：Developer ID 签名 + 公证）；
  - 应用正常启动；
  - .app 内部的二进制能找到捆绑的 `Tools/7zz`；
  - 关于面板中显示的版本与所打的 tag 版本匹配。
- [ ] 在接下来的 24 小时内关注 issue tracker 的首次启动报告。
- [ ] 如果有东西损坏了，优先发布 `v<version>.1` 而不是编辑
      现有 tag——tag 不应当移动。

## 8. 对当前 alpha 级发布**尚不**要求的事项

这些已被跟踪，但今天不是门槛条件；当每一项落地时再把它们翻转为必需
项：

- ~~Developer ID 签名 + 公证~~ — 已上线；发布构建现在通过 CI 进行
  Developer ID 签名和公证。
- 独立于 GitHub Advisories 的公开安全邮箱。
- 可复现构建。
