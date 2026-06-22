[English](./ARCHITECTURE.md) | **中文**

# SimpleZip 架构说明

SimpleZip 是一款原生 macOS 应用，由 SwiftUI/AppKit 的 UI 外壳和命令行后端层组成。项目早已超出一个小型 ZIP 封装器的范畴，因此本文档记录了各主要类型之间的所有权边界。

> 如需完整的代码地图（各子系统所在位置、构建/测试命令，以及如何新增一个功能），参见
> [`docs/DEVELOPMENT.md`](DEVELOPMENT.zh-CN.md)。本文件是范围更窄的「谁拥有哪份状态」参考。

## 当前状态

下述边界均已抽取完成——本节反映的是已落地的布局，而非计划：

- `ArchiveBrowserModel` 是面向 UI 的状态模型，按领域拆分为 `Features/ArchiveBrowser/ArchiveBrowserModel/` 下的
  12 个文件（一个基础文件外加 `+Navigation`、`+Loading`、`+CreateExtract`、`+FileOps`、
  `+OperationLifecycle`、`+Sort`、`+SafetyPassword`、`+SZSAndDiskImage`、`+GPG`、`+Undo`、`+TestHashBenchmark`）。
- `ArchiveSession`、`FileBrowserService` 和 `ArchiveOperationRunner` 已从模型中抽取出来，位于
  `Features/ArchiveBrowser/`。请勿将后端或文件系统的所有权重新塞回 `ArchiveBrowserModel`。
- `ArchiveService` 是后端门面/路由（`ArchiveService.swift` + `+Arguments` + `+Parsing`）。它会分派到
  `Core/Backends/` 中的各按格式划分的后端。
- 后端拆分已完成：`Core/Backends/` 中包含 `ArchiveBackend` 协议，以及 `SevenZipBackend`、
  `NativeZipBackend`、`RarBackend`、`DiskImageBackend`、`XIPBackend` 和 `GPGBackend`（后者本身又按关注点拆分为多个
  扩展文件：`+Discovery`、`+Keyring`、`+KeyManagement`、`+KeyLifecycle`、`+KeyCreation`、`+Keyserver`、
  `+CryptoOperations`、`+Parsing`）。`BackendProcessRunner` 封装了子进程派生、输出捕获与取消。
- `ArchiveExtractionCoordinator` 将合并/冲突行为与原始的后端解压分离开来。
- `TemporaryResourceManager` 拥有用于在应用之外打开归档条目的临时目录。
- SwiftPM target `SimpleZipCore` 暴露可测试的核心逻辑（即 `Package.swift` 的 `sources:` 中列出的文件）。Xcode
  有一个 `SimpleZipCoreTests` scheme，运行的是同一套 SwiftPM 测试。
- `Features/Intents/` 承载 App Intents / 快捷指令 / Siri 这一面，以及喂给 CoreSpotlight 的 `IndexedEntity` 类型（账本、
  任务、设置、缓存归档、归档内文件）。它是叠在现有 app 状态与 `SettingToggleRegistry` 白名单之上的「读侧适配器」——绝不
  拥有归档或文件系统逻辑，而它唯一能做的写入（翻动一个*安全的*设置）也要过那道白名单。
- `Features/AI/` 承载 macOS 26 的端上助手（FoundationModels）。它**严格只读、纯增量**：解释报告、给风险评级
  （`Core/ArchiveRiskScore`）、扫描敏感文件 / 近似重复（`Core/SensitiveFileScan`、`Core/ArchiveNearDuplicates`），但完全
  处在解压 / 创建 / 删除路径之外，也绝不被喂加密条目的内容或口令。确定性的评分逻辑在 `Core`（可测）；AI 只负责把它讲成
  人话。这里的一切都受 `@available(macOS 26, *)` 门控，否则整体降级为「什么都没有」。所有端上模型**推理**都在主 app
  之外的辅助进程里跑（前台 XPC Service + 后台 LaunchAgent）。

> **参考：** [`AI-AGENT.md`](./AI-AGENT.zh-CN.md) 完整记录这两个辅助进程——两条投递通道、`SimpleZipAIAgent` 的命令行
> 参数、XPC 接口契约、配置同步 payload,以及 launchd / `SMAppService` 注册。

## 所有权边界

### `ArchiveBrowserModel`

仅将其保持为面向 UI 的状态模型：

- 当前的 `BrowserMode`；
- 文件与归档的选择；
- 活动的 sheet 与 alert；
- 状态文本与操作进度；
- 由视图、菜单和表格适配器调用的命令入口点。

它应当委托文件系统工作和后端工作，而非直接实现它们。

### `FileBrowserService`

本地文件浏览与文件操作之家：

- 文件夹列举；
- Finder 标签搜索；
- 复制、移动、粘贴、移到废纸篓；
- 拖入与拖到文件夹的处理；
- 文件元数据加载。

### `ArchiveSession`

为单个已打开的归档持有状态：

- 归档 URL；
- 当前归档路径；
- 完整的归档条目列表；
- 合成目录的生成；
- 选中的归档条目；
- 归档文件夹内的导航。

### `ArchiveOperationRunner`

长时间运行工作的协调器：

- 单个活动的操作任务；
- 取消；
- 进度映射；
- Details 输出会话；
- 状态更新；
- 一致的错误处理。

### `TemporaryResourceManager`

拥有临时资源并提供可预期的清理：

- 启动时清理陈旧的 `SimpleZipArchiveOpen` 目录；
- 用于归档条目预览的、按次打开的临时目录；
- 若已编辑的临时副本将来支持写回，则保留相应的保留策略。

### 后端层

`ArchiveService` 是 `Core/Backends/` 中各后端实现之上的路由，这些实现均遵循 `ArchiveBackend`：

- `SevenZipBackend`
- `NativeZipBackend`（也通过系统 `tar` 覆盖 tar）
- `RarBackend`
- `DiskImageBackend`
- `XIPBackend`（Apple 签名的 `.xip`，经由 Apple 自带的 `xip` 工具，该工具会验证签名）
- `GPGBackend`

这种拆分将后端偏好、沙盒辅助、特定版本的行为以及兼容性测试从单一的静态类型中剥离出来。子进程的派生/捕获/取消被集中到
`BackendProcessRunner` 中。

## 重构原则

上述主要的抽取工作均已完成。这些原则仍适用于未来的迁移：

- 在迁移代码之前，持续围绕 `ArchiveService` 的纯逻辑扩充测试。
- 避免仅为让架构看起来更整洁而改变行为。
- 一次只迁移一个所有权边界；每次抽取都应保留公开的工作流。
- 优先将纯逻辑迁移到 `SimpleZip/Core`（并将其加入 `Package.swift` 的 `sources:`），以便 SwiftPM 能够对其进行测试。
