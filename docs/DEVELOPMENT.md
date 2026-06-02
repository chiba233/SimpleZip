# SimpleZip 开发指南

> 这份文档是 SimpleZip 的「代码地图 + 上手手册」。项目已经从一个小 ZIP 壳长到 100+ 个 Swift 文件、十几个子系统，
> 这份指南的目标是：**让任何人（包括三个月后的你自己）能在 10 分钟内找到「某个功能的代码在哪、改它要碰哪几层、改完怎么验证」。**
>
> 配套文档分工：
> - **本文**：上手、构建、代码地图、分层、加功能的流程。
> - [`docs/ARCHITECTURE.md`](ARCHITECTURE.md)：所有权边界（谁该持有什么状态）和重构原则。
> - [`CONTRIBUTING.md`](../CONTRIBUTING.md)：对外贡献者的精简版上手。
> - [`CLAUDE.md`](../CLAUDE.md) / `AGENTS.md` / `gemini.md`：**强约束规则**（A1–A12）。改代码前必须遵守，本文不重复抄，只指路。
> - [`SECURITY.md`](../SECURITY.md) / [`docs/SZS-FORMAT.md`](SZS-FORMAT.md)：`.siz` / `.szs` 签名容器的密码学设计。改 wrap/unwrap/verify 前必读。
> - [`docs/release-checklist.md`](release-checklist.md)：发版流程。

---

## 1. 它是什么

SimpleZip 是一个原生 macOS 压缩档案管理器，Swift + SwiftUI/AppKit 写的。底层用命令行后端（`7zz` / 系统 `zip`/`tar`/`unzip` /
`rar` / `hdiutil` / `gpg`）干活，上层是 SwiftUI 界面。

部署目标 **macOS 13.0+**。不要用需要更高系统版本的 SwiftUI API。

---

## 2. 环境、构建、测试

需要 Xcode（`DEVELOPER_DIR` 指向 `/Applications/Xcode.app`）。可选 `brew install sevenzip` 提供系统 `7zz`，但仓库里
`SimpleZip/Tools/7zz` 已经自带一份打包用的后端。

下面是**权威命令**，和 [`CLAUDE.md`](../CLAUDE.md) 的「Verification Requirements」一字不差，按这个跑：

### SwiftPM 核心测试（改 `SimpleZip/Core` 必跑）

```bash
/usr/bin/env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcrun swift test \
  --scratch-path /private/tmp/SimpleZipSwiftPM \
  -Xswiftc -module-cache-path -Xswiftc /private/tmp/SimpleZipSwiftPM/ModuleCache
```

### Xcode Debug 构建（改 App / Features / 资源 / 本地化 / 工程设置 必跑）

```bash
/usr/bin/env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer /usr/bin/xcodebuild \
  -project SimpleZip.xcodeproj -scheme SimpleZip -configuration Debug \
  -derivedDataPath /private/tmp/SimpleZipDerivedData build
```

### 本地化 strings 语法自检

```bash
plutil -lint SimpleZip/*.lproj/Localizable.strings Info.plist
```

> 工程文件是仓库根目录的 `SimpleZip.xcodeproj`（不是 `SimpleZip/SimpleZip.xcodeproj`）。`Info.plist` 在仓库根目录。
> 两个 scheme：`SimpleZip`（App）、`SimpleZipCoreTests`（在 Xcode 里跑同一套 SwiftPM 测试）。

### 该跑哪个？（验证矩阵）

| 改了什么 | 跑什么 |
|---|---|
| 只动 `SimpleZip/Core` 纯逻辑 | SwiftPM 核心测试 |
| App UI / Features / 菜单 / 资源 / 本地化 / Info.plist / entitlements / 工程或构建设置 | SwiftPM 测试 **+** Xcode Debug 构建 |
| 只动文档（`*.md`） | 都不跑（除非文档内容依赖某条新命令的真实结果） |

**Lint 工具：未配置。** 业务改动的最终回复里要照实写「lint 未配置」，不要编造 lint 结果。

---

## 3. 仓库地图（顶层）

```
SimpleZip.xcodeproj/        Xcode 工程（App 单 target；Finder 右键集成走 macOS NSServices）
Package.swift               SwiftPM：只编 SimpleZipCore 这一个库 target
SimpleZip/                  App 全部源码 + 资源 + 本地化
  Core/                     可被 SwiftPM 测试的纯逻辑（见 §4、§5）
  App/                      App 生命周期、主窗口外壳
  Features/                 各功能子系统的 UI + 协调逻辑
  Tools/7zz                 打包用的 7-Zip 后端二进制
  *.lproj/                  10 种语言的 Localizable.strings
  Assets.xcassets, AppIcon.icns
Tests/SimpleZipCoreTests/   SwiftPM 测试 + Fixtures/ 预录二进制档案
Tools/                      （根目录）后端工具
scripts/                    build_unsigned_dmg.sh / install_rar_backend.sh / verify_appcast.sh
docs/                       本文 + ARCHITECTURE / SZS-FORMAT / release-checklist / appcast.xml
Info.plist                  App 的 Info.plist（根目录）
```

根目录的 Markdown：`README.md`、`CHANGELOG.md` + `CHANGELOG.zh-CN.md`（**每次业务改动都要同时更新两份**）、
`GUIDE.zh-CN.md`（用户向）、`SECURITY.md` + `SECURITY.zh-CN.md`、`CONTRIBUTING.md`、`CLAUDE.md`/`AGENTS.md`/`gemini.md`。

---

## 4. 分层架构

```
┌─────────────────────────────────────────────────────────────┐
│  SimpleZip/App         App 入口、主窗口外壳、外部打开队列、Sparkle   │
├─────────────────────────────────────────────────────────────┤
│  SimpleZip/Features    各功能的 SwiftUI 视图 + 协调器（UI 层）       │
│    ArchiveBrowser  ArchiveOperations  Settings  SignedManifest │
│    Welcome  Hashing  Benchmark  About  ExternalExtract         │
├─────────────────────────────────────────────────────────────┤
│  SimpleZip/Core        纯逻辑：模型 / 选项 / 解析 / 安全 / 后端       │  ← SwiftPM 可测
│    Backends/  ArchiveService  AppPreferences  L10n  SIZ/SZS ... │
├─────────────────────────────────────────────────────────────┤
│  命令行后端             7zz · zip/tar/unzip · rar · hdiutil · gpg  │
└─────────────────────────────────────────────────────────────┘
```

### SwiftPM vs Xcode 边界（很重要）

`Package.swift` 的 `SimpleZipCore` target **只**编 `SimpleZip/Core/` 下显式列出的那 24 个文件（见 Package.swift 的 `sources:`）。
App UI、`Features/`、`App/`、资源、本地化、`Tools/` 统统被 `exclude` 掉了。

含义：
- **能搬进 `Core` 的纯逻辑就搬进去**——这样它能被 SwiftPM 测试覆盖。命令参数构造、路径规范化、解析、安全判定、临时资源行为最该住在这里。
- 在 `Core` 新增文件，**必须同步加到 `Package.swift` 的 `sources:` 列表**，否则 SwiftPM target 编不到它，测试也看不到。
- UI 层（`Features`/`App`）改动用 Xcode 构建验证，SwiftPM 测不到。
- Xcode 16 用的是 file-system synchronized groups，所以**新增/删除 `.swift` 文件一般不用改 `project.pbxproj`**（文件系统即真相）。

---

## 5. 代码地图：按子系统找文件

下面是「我要改 X，去哪个文件」的速查。路径都相对仓库根。

### 5.1 档案后端（7z / zip / tar / rar / dmg）

- `SimpleZip/Core/Backends/ArchiveBackend.swift` — 后端协议（`list()` / `test()`）。
- `SimpleZip/Core/Backends/SevenZipBackend.swift` — `7zz`/`7z`，自带 + 系统二进制发现、版本解析。
- `SimpleZip/Core/Backends/NativeZipBackend.swift` — 系统 `unzip`/`zip`/`tar`（不支持 AES 加密 zip，转交 7zz）。
- `SimpleZip/Core/Backends/RarBackend.swift` — `rar`，用户安装 / 系统发现 + 安装脚本协调。
- `SimpleZip/Core/Backends/DiskImageBackend.swift` — DMG 用 `hdiutil` 挂载/卸载。
- `SimpleZip/Core/ArchiveService.swift` — **后端门面/路由**。按格式把 list/test/extract/create 分发给具体后端，处理密码安全检查和取消。改后端入口先看这里。
- `SimpleZip/Core/ArchiveService+Arguments.swift` — 命令行参数构造（zip/7z/rar/tar 的 flag）。**改参数从这里改，且尽量加测试断言生成的确切参数。**
- `SimpleZip/Core/ArchiveService+Parsing.swift` — list 输出解析、路径拆解、给 UI 用的合成目录树。
- `SimpleZip/Core/BackendProcessRunner.swift` — 子进程封装（spawn / 抓输出 / 按 operationID 取消）。所有后端都走它。**禁止 shell 字符串拼接，参数走 `Process.arguments`。**

### 5.2 主浏览器：`ArchiveBrowserModel` 及其拆分

`ArchiveBrowserModel` 是 UI 面向的状态中枢，已经按域拆成一个目录下的 10 个文件
（`SimpleZip/Features/ArchiveBrowser/ArchiveBrowserModel/`）：

- `ArchiveBrowserModel.swift` — 基类 / 共享状态。
- `+Navigation.swift` — 前进后退栈、面包屑、目录展开。
- `+Loading.swift` — 从后端拉 item、填充 session、刷新 UI。
- `+CreateExtract.swift` — 创建/解压编排、临时文件清理。
- `+FileOps.swift` — 复制/移动/删除/重命名。
- `+OperationLifecycle.swift` — task 生命周期、取消、进度。
- `+Sort.swift` — 列排序。
- `+SafetyPassword.swift` — 密码提示流、Keychain 查找、缓存密码。
- `+SZSAndDiskImage.swift` — `.szs` 验签、DMG 挂载/卸载。
- `+TestHashBenchmark.swift` — 完整性测试、哈希、7z benchmark。

从 Model 抽出去的三个服务（**别再往 Model 塞后端/文件系统所有权**，见 ARCHITECTURE.md）：

- `SimpleZip/Features/ArchiveBrowser/ArchiveSession.swift` — 一个已打开档案的状态（URL、当前路径、item 列表、合成目录）。
- `SimpleZip/Features/ArchiveBrowser/FileBrowserService.swift` — 本地文件系统逻辑（列目录、Finder 标签、自动补全）。
- `SimpleZip/Features/ArchiveBrowser/ArchiveOperationRunner.swift` — 长任务调度（同一时刻一个操作、新任务自动取消旧的、取消传到子进程）。

主窗口 UI 同目录：`ContentView`（在 `App/`）、`TopBar.swift`、`Sidebar.swift`、`StatusBar.swift`、
`FileTable.swift`、`ArchiveTable.swift`、`TableSupport.swift`、`BrowserNavigation.swift`。

> 列可见性现在走顶层「视图」菜单（`SimpleZipApp.swift` 注册 commands）+ 表头右键 inline 开关
> （`TableSupport.swift` 的 `makeColumnHeaderMenu`），不再在 Settings 里。这是 0.2.0「Group By / Sort By」的落点。

### 5.3 创建 / 解压对话框

`SimpleZip/Features/ArchiveOperations/`：

- `ArchiveCreationOptionsView.swift` — 创建对话框（格式、压缩级别、加密、排除规则、分卷）。
- `ExtractArchiveOptionsView.swift` / `ExtractSelectionOptionsView.swift` / `ExtractOptionsForm.swift` — 解压对话框 + 共享表单控件。
- `ArchiveExtractionCoordinator.swift` — 解压编排（安全检查 → 密码提示 → 选后端 → 进度 → 合并/冲突处理）。

选项模型在 Core：`ArchiveOperationOptions.swift`、`ArchiveModels.swift`。

### 5.4 GPG（签名 / 加密 / 解密 / 密钥管理）

- `SimpleZip/Core/Backends/GPGBackend.swift` — GnuPG CLI 集成：列密钥、导入、`--detach-sign`、`--status-fd` 验签 +
  强 fingerprint 比对、`--encrypt -r` / 解密。**SimpleZip 不管理 GPG 私钥 passphrase，交给 `gpg-agent`**——错误文案/发布说明要持续强调这点（见 MEMORY）。
- `SimpleZip/Features/Settings/Panes/GPGPane.swift` — 密钥管理 GUI，强分区「我的密钥 / 他人公钥」，生成/导入/改有效期/吊销/改 passphrase。
- 相关 sheet：`AddUserIDSheet` / `NewGPGKeySheet` / `ChangePassphraseSheet` / `EditExpirationSheet` / `GenerateRevocationSheet`（都在 `Settings/Panes/`）。

> **GPG 可见性是硬约束（A4）**：`AppPreferences.gpgEnabled == false` 时，主界面所有 GPG 入口必须**完全不渲染**（不是禁用），
> 唯一例外是 Settings 面板本身和「从 Finder 打开 `.siz`」这一刚需路径。检查要 `gpgEnabled && GPGBackend.isAvailable()`，不能只看后端是否安装。

### 5.5 `.siz` / `.szs` 签名容器

- `SimpleZip/Core/SIZArchive.swift` — `.siz`：把 `archive.<ext> + metadata.json + signature.asc` 打成一个 tar。**它只是个 tar 壳，不是新后端（A5）**：
  打开走 `unwrap → verify → model.openArchive(...)`，解压走 `unwrap → verify → 现有 ExtractArchiveOptionsView 多渲染一行签名`。别造平行的「SIZ 浏览/解压流程」。
- `SimpleZip/Core/SZSArchive.swift` — `.szs`：GPG clearsigned JSON 清单，列多个文件的 SHA256，用于发布分发。
- UI：`SimpleZip/Features/SignedManifest/CreateSZSSheet.swift`、`SZSVerificationSheet.swift`；`.siz` 解压签名行在
  `SimpleZip/Features/ExternalExtract/SIZSignatureSheet.swift`。
- **改 wrap/unwrap/verify 前必读 [`docs/SZS-FORMAT.md`](SZS-FORMAT.md) 和 `SECURITY.md` 的容器格式章节。**

### 5.6 偏好（AppPreferences）+ 导入/导出

- `SimpleZip/Core/AppPreferences.swift` — 所有用户偏好（语言、启动位置、覆盖行为、预设密码、安全策略、后端选择、GPG 开关…），敏感值进 Keychain。
- `SimpleZip/Core/PresetPasswordStore.swift` — 预设密码 Keychain 存储。
- `SimpleZip/Core/PreferencesPayloadCodec.swift` — 导入/导出 JSON 编解码 + schema 版本校验。
  > 导入语义是「patch / 合并」，**不是「还原备份」**（见已修 bug #21）。Keychain 写失败不能被缓存伪装成成功（bug #22）。
- UI：`SimpleZip/Features/Settings/Panes/BackupPane.swift`（含恢复默认）。

### 5.7 Settings 面板

`SimpleZip/Features/Settings/`：外壳 `SettingsView.swift` + `SettingsPane.swift` + `SettingsNavigation.swift` +
共享控件 `SettingsRowComponents.swift`。各分页在 `Settings/Panes/`：`GeneralPane`、`ArchivePane`、`BrowserPane`、
`FileAssociationsPane`、`GPGPane`、`BackupPane`、`HealthPane`，以及后端选择 section
`SevenZipBackendSection` / `RarBackendSection`。

> 加设置项是「现有 pane 里加一行 Form row」，不是新开 card / 新建平行 sheet（**A1 / A2**）。

### 5.8 健康检查 / 诊断

- `SimpleZip/Features/Settings/Panes/HealthPane.swift` + `HealthCheck.swift` — 首启动/设置里的健康面板（后端可用性、文件关联、7zz/RAR/GPG 状态）。
- `SimpleZip/Core/OperationDiagnosticsReporter.swift` — 组装诊断报告（后端版本、系统信息），有测试覆盖。
- `SimpleZip/Features/ArchiveBrowser/DiagnosticsCopier.swift` — 一键复制诊断到剪贴板。

### 5.9 欢迎向导 / Sparkle 更新 / Finder 集成 / 其它

- `SimpleZip/Features/Welcome/WelcomeAssistantView.swift` — 首启动多步向导（备份检查、版本检查、语言、启动位置、默认值、预设密码、Finder 自动解压、安全策略、后端检查）。
- `SimpleZip/App/SparkleUpdater.swift` — Sparkle EdDSA 签名更新（feed = `docs/appcast.xml`）。签名步骤见 `release.yml` 和 `scripts/verify_appcast.sh`。
- `SimpleZip/App/AppDelegate.swift` + `ExternalFileOpenQueue.swift` — 处理 Finder 自动解压 / 「用 SimpleZip 打开」的外部文件队列；Finder 右键集成的 `@objc` NSServices 处理方法（添加到压缩包 / 计算哈希 / 解压 / 创建 ZIP·7z·TAR.GZ）也在这里，声明见 `Info.plist` 的 `NSServices`、标题见各 `*.lproj/ServicesMenu.strings`。
- `SimpleZip/Core/L10n.swift` — 本地化 helper（按语言选 bundle，回退到 en）。
- `SimpleZip/Core/TemporaryResourceManager.swift` — 临时资源生命周期（启动清理残留、每次打开隔离目录）。
- `SimpleZip/Features/Hashing/` — 哈希；`Benchmark/` — 7z benchmark；`About/AboutPanel.swift` — 关于面板。

---

## 6. 一次「打开档案 → 浏览 → 解压」走过哪几层

帮你建立心智模型（找 bug 时按这条链往下追）：

1. 用户拖入/双击档案 → `ContentView` / `AppDelegate`（外部文件走 `ExternalFileOpenQueue`）。
2. `ArchiveBrowserModel+Loading` 调 `ArchiveService.list(...)`。
3. `ArchiveService` 按格式选 `Core/Backends/` 里的后端 → `BackendProcessRunner` spawn 子进程（如 `7zz l`）。
4. `ArchiveService+Parsing` 解析输出成 `ArchiveItem` + 合成目录树 → 存进 `ArchiveSession`。
5. `ArchiveTable` 渲染；`+Navigation` 处理进出目录。
6. 解压：`+CreateExtract` → `ArchiveExtractionCoordinator`（`ArchiveSafety` 做路径穿越/符号链接等安全检查 →
   按需 `+SafetyPassword` 弹密码 → 选后端 → `BackendProcessRunner` 跑 → 进度回 `ArchiveOperationRunner`）。
7. 临时产物注册到 `TemporaryResourceManager`，退出/操作完成时清理。

---

## 7. 怎么加一个新功能（落地清单）

> 这一节是**流程**。具体禁令（不要重绘页面、不要 DTO 套 DTO、不要新建平行 sheet…）在 [`CLAUDE.md` 的 A1–A12](../CLAUDE.md)，
> 那是硬规则，动手前先读，本文不重抄。

1. **先找现有 idiom。** grep 你要碰的文件，看相邻的 row/控件怎么写的，复用它。功能是现有架构里的一个 feature flag / 一行 `if let`，
   不是平行子 App（A1）。能不能不新建文件？（A12：别为一行行为改动炸出 12 文件 diff。）
2. **纯逻辑放 `Core`。** 命令参数构造、解析、安全判定、路径处理 → `SimpleZip/Core/`，并加进 `Package.swift` 的 `sources:`，
   再写 SwiftPM 测试（命令参数要断言生成的确切 flag）。
3. **UI 留在 `Features`**，只做展示和交互，后端/文件系统/解析下沉到 service。别在主线程跑后端进程/文件扫描/哈希。
4. **状态变更在 main actor**，别从后台 task 改 SwiftUI 观察的状态。用户触发的 archive/文件/哈希操作要可取消。
5. **本地化（A9 硬要求）：** 每条新用户可见字符串用 `L10n.text("some.key")`，并在 `en.lproj` **和** `zh-Hans.lproj`
   两份手维护语言里加 key。其余 8 种语言（de/es/fr/ja/ko/ru/th/zh-Hant）自动回退到 en，发版前再补译。别硬编码英文串。
6. **不要半挂引用（A8）：** 菜单/selector 引用的 model 方法必须同一改动里就存在（哪怕是抛 `notImplemented` 的 stub），别 check in 编不过的树。
7. **可见性门禁是硬规则（A4）：** 主开关关掉时功能 UI 不渲染（不是禁用）。
8. **更新两份 CHANGELOG**（`CHANGELOG.md` + `CHANGELOG.zh-CN.md`），每次业务改动当场写，不要事后攒批（见 MEMORY）。
9. **按矩阵跑验证**（§2），最终回复照实报告：lint（未配置）/ 跑了哪个 test 或 build / 过没过 / 残留风险。

### 不要碰的东西

- **别手改版本号**（A6）：`project.pbxproj` 的 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`、`Info.plist` 的
  `CFBundleShortVersionString` / `CFBundleVersion` 都由 CI 在构建时写。「版本号 bump」只改两份 CHANGELOG。
- **临时目录用系统 `temporaryDirectory`**（A7）：`FileManager.default.temporaryDirectory.appendingPathComponent("SimpleZip-...-\(UUID())")`，
  注册给 `TemporaryResourceManager` 清理。别写进项目目录或硬编码 `/tmp/foo`。
- **别为了过测试改用户可见行为。** 测试默认不许改，详见 §8。

---

## 8. 测试与 fixtures

测试在 `Tests/SimpleZipCoreTests/`（SwiftPM）：

| 文件 | 覆盖 |
|---|---|
| `ArchiveServiceTests.swift` | 路由逻辑：排除模式、参数拆分、分卷大小校验、压缩级别/方法解析 |
| `ArchiveServiceArgumentsTests.swift` | 各后端 CLI flag 生成（7z/zip/rar/tar、加密、分卷） |
| `ArchiveServiceParsingTests.swift` | 输出解析（zip/7z list 格式、嵌套路径、目录合成） |
| `ArchiveServiceFixtureTests.swift` | 回归：读 `Fixtures/` 里预录的真实档案 |
| `PreferencesPayloadCodecTests.swift` | 导入/导出 JSON 编解码、schema 版本、roundtrip |
| `OperationDiagnosticsReporterTests.swift` | 诊断报告组装 |
| `SIZArchiveTests.swift` | `.siz` wrap/unwrap roundtrip、metadata 编码、完整性 |
| `ArchiveOperationFeedbackTests.swift` | 子进程输出进度解析 |

`Fixtures/` 是预录的二进制档案，通过 `Bundle.module` 拿 URL（见 `Package.swift` 的 `resources: [.copy("Fixtures")]`），
不依赖 `swift test` 的工作目录。

**测试规则（来自 CLAUDE.md）：**
- 默认不改单元测试。测试挂了先诊断并修**生产代码**。
- 觉得某测试本身过时 → 先解释为什么、正确行为应该是什么，**请用户批准后**再改测试。
- 不许为了让验证通过而弱化断言或删覆盖。
- 优先给纯核心行为、命令参数生成、路径规范化、安全提示、冲突决策、解析、临时资源行为写测试。

---

## 9. 本地化工作流

10 种语言，每种在 `SimpleZip/*.lproj/Localizable.strings`（Finder 右键服务标题另在 `SimpleZip/*.lproj/ServicesMenu.strings`）：

`en` `zh-Hans` `zh-Hant` `ja` `ko` `de` `es` `fr` `ru` `th`

- **手维护两份：`en` 和 `zh-Hans`。** 新 key 当场加这两份。其余 8 种回退到 en，发版前补译。
- 加完跑 `plutil -lint SimpleZip/*.lproj/Localizable.strings Info.plist` 验语法。
- 改语言后 macOS 顶部菜单栏要跟随（曾是 bug #18，已修）。

---

## 10. 发版

完整流程见 [`docs/release-checklist.md`](release-checklist.md)。要点：

- 版本号由 CI 从 `RELEASE_VERSION` / `GITHUB_RUN_NUMBER` 写，**不手改**（A6）。
- 「版本 bump」= 把两份 CHANGELOG 的 unreleased 条目挪到新的 `## X.Y.Z` 标题下，已发布的段落不动。
- Sparkle 更新用 EdDSA 签名，feed 是 `docs/appcast.xml`；签名在 `release.yml` 里做，本地用 `scripts/verify_appcast.sh` 自检。
- `.siz`/`.szs` 的密码学改动要过 `SECURITY.md` 的对应章节。

---

## 11. 强约束速查（详见 CLAUDE.md A1–A12）

| 编号 | 一句话 |
|---|---|
| A1 | 功能住进现有对话框/页面，不重绘、不开平行子 App |
| A2 | 别堆镜像现有类型的 DTO + mapper，让现有类型直接流到消费方 |
| A3 | 一发一收的路径别新加 `NotificationCenter` 名，用现有 `@Published` |
| A4 | 主开关关 → 功能 UI 不渲染（不是禁用）；查 `gpgEnabled && isAvailable()` |
| A5 | `.siz` 只是 tar 壳，别过度架构化 |
| A6 | 不手改版本号 |
| A7 | 用系统临时目录并清理 |
| A8 | 不留半挂引用，提交的树必须能编译 |
| A9 | 每条新用户可见串都要 `L10n` + en/zh-Hans 两份 key |
| A10 | 改动对齐 scope：bug fix 改一个分支，别夹带重构 |
| A11 | 用户指令是累积且有约束力的，违背前先问 |
| A12 | 别炸大 diff / 别加用户没要的文件 |
