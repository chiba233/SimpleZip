[English](./SHORTCUTS.md) | **中文**

# SimpleZip 快捷指令与 Siri

SimpleZip 把归档操作暴露为 [App Intents](https://developer.apple.com/documentation/appintents)，因此你可以在 macOS 上通过
**快捷指令** app 和 **Siri** 使用它们。每个动作都运行在驱动 app 本身的同一套引擎上——没有平行的自动化后端——并且每次运行都会记入
活动中心，方便你实时观察进度、稍后回看历史。

本文列出这些动作、它们暴露的实体、示例语句，以及 macOS 版本可用性。文档只描述 app 真实交付的内容；不会臆造任何命令、参数或行为。

> 相关自动化入口：命令行伴随工具见 [`CLI.zh-CN.md`](./CLI.zh-CN.md)，`simplezip://` URL Scheme 见
> [`URL-SCHEME.zh-CN.md`](./URL-SCHEME.zh-CN.md)。三者都记入同一个活动中心。

## 工作原理

- 这些动作定义在 `SimpleZip/Features/Intents/SimpleZipAppIntents.swift`。
- 每个动作都复用 app 既有的无窗口核心（例如 `ExternalExtractRunner`、`ArchiveService`、`HashService` 与发布助手流水线）。
  快捷指令不会得到一套单独的实现。
- 每次运行都会在活动中心打开一个任务，来源标记为 **Shortcuts / Siri**。你看到的进度、状态与历史记录，和 app 里任何其他操作完全一致。
- 快捷指令是无人值守的上下文，因此这些动作**绝不弹窗**——不弹密码、不弹目标、不弹确认。可能需要密码的场合（测试加密归档），动作
  仅在配置了预设密码、且相关自动化偏好允许时才使用它；否则不带密码继续。
- 输入始终是磁盘上的真实文件。如果快捷指令传入没有落盘位置的内存数据，动作会拒绝它，而不是悄悄把未知数据写进临时目录。
- 输出名称会被校验。输出名必须是单段纯文件名；路径分隔符、`..`、盘符、`~` 一律拒绝。绝不覆盖既有文件——改用带编号的名字（例如
  `name 2`）。

## 可用动作

下列标题与参数与源码中的定义完全一致。

### Extract Archive

按 SimpleZip 的 Finder 自动解压方式解压归档：每个归档解压到紧挨它的、名称唯一的文件夹（或所选目标文件夹内）。绝不覆盖既有文件。

| 参数 | 类型 | 说明 |
| --- | --- | --- |
| **Archives** | 文件列表 | 要解压的归档。 |
| **Destination Folder** | 文件（可选） | 设置后，归档解压到此文件夹内。 |

返回产出的文件夹（作为文件）。

### Create Archive

把文件压缩成紧挨它们的一个新归档，套用与 SimpleZip 一键 Finder 压缩相同的逐格式默认值。所有输入必须位于同一文件夹；绝不覆盖既有归档
——新归档改用带编号的名字。

| 参数 | 类型 | 说明 |
| --- | --- | --- |
| **Files** | 文件列表 | 要压缩的文件。必须都在同一文件夹。 |
| **Format** | 选项 | `ZIP`、`7-Zip`、`tar` 或 `tar.gz`。默认 `ZIP`。 |
| **Archive Name** | 文本（可选） | 新归档的基础名称。 |

返回创建的归档（作为文件）。

### Test Archive Integrity

对归档运行 SimpleZip 的完整性测试，并报告哪些未通过。配置了预设密码时，加密归档用该预设密码测试；此动作绝不弹窗。

| 参数 | 类型 | 说明 |
| --- | --- | --- |
| **Archives** | 文件列表 | 要测试的归档。 |

返回布尔值（全部通过为 true），以及一句总结通过 / 失败的对话提示。

### Verify Checksums

校验由校验文件（SHA256SUMS、.sha256、.md5、.sfv）列出的文件。路径相对各校验文件解析；不安全条目被拒绝。全部匹配时返回 true。

| 参数 | 类型 | 说明 |
| --- | --- | --- |
| **Checksum Files** | 文件列表 | 要校验的校验清单。 |

返回布尔值（全部匹配为 true），以及一句总结结果的对话提示。

### Compare Archives

比较两个归档的条目清单（路径、大小、CRC、修改时间、加密）。两者完全相同时返回 true。

| 参数 | 类型 | 说明 |
| --- | --- | --- |
| **First Archive** | 文件 | 第一个归档。 |
| **Second Archive** | 文件 | 第二个归档。 |

返回布尔值（相同为 true），以及一句带有新增 / 移除 / 变更计数的对话提示。

### Search Archive Contents

列出归档，返回路径包含搜索文本的条目（大小写不敏感）。条目名称需要密码的加密归档不会被列出。

| 参数 | 类型 | 说明 |
| --- | --- | --- |
| **Archive** | 文件 | 要搜索的归档。 |
| **Query** | 文本 | 用于匹配条目路径的文本。 |

返回匹配的条目路径（文本列表），以及一句带有结果计数的对话提示。

### Inspect Archive

按发布助手的方式检查归档——文件数、总大小、macOS 垃圾文件、空目录和可疑条目路径——无需解压。未发现可疑内容时返回 true。

| 参数 | 类型 | 说明 |
| --- | --- | --- |
| **Archive** | 文件 | 要检查的归档。 |

返回布尔值（未发现可疑内容为 true），以及一句总结检查结果的对话提示。

### Create Release Package

无头运行 SimpleZip 的发布助手：打包一个构建文件夹（排除垃圾、可复现）、检查归档并写出 SHA256SUMS——选定工作区预设时套用它。签名为
`.szs` 仅限交互式，绝不无人值守运行。

| 参数 | 类型 | 说明 |
| --- | --- | --- |
| **Build Folder** | 文件 | 要打包的文件夹。必须是目录。 |
| **Workspace Preset** | Workspace Preset（可选） | 要套用的已存发布工作区预设。 |
| **Archive Name** | 文本（可选） | 覆盖输出基础名称。 |

返回创建的发布包（作为文件），以及一句确认完成的对话提示。成功的运行会记入发布账本。

## 实体

SimpleZip 向快捷指令与 Siri 暴露三个实体。它们是 app 数据的只读视图；绝不触发写入或安全判定，也绝不暴露归档内文件的名称或内容。

### Archive Task

代表活动中心历史里的一个任务（定义在 `SimpleZip/Features/Intents/ArchiveTaskEntity.swift`）。属性：**Source**、
**Status**、**Started**。建议最近 20 条任务。这让快捷指令能引用一次过去的操作，例如最近的一次解压。

### Release Package

代表发布账本里记录的一次成功发布（定义在 `SimpleZip/Features/Intents/ReleasePackageEntity.swift`）。属性：**Version**、
**Date**、**Format**、**SHA-256**、**File Count**、**Reproducible**、**Checksums Written**。建议最近 20 条发布。在 macOS 15
及更高版本上，发布账本还可被索引进 Spotlight（仅限语义化的发布元数据——绝不含归档内容），前提是对应的索引偏好已启用。

### Workspace Preset

代表一个已存的发布工作区预设（定义在 `SimpleZip/Features/Intents/ReleaseWorkspacePresetEntity.swift`）。属性：**Name**。它用作
*Create Release Package* 的 **Workspace Preset** 参数选择器，既支持从列表中挑选，也支持按名字匹配（因此快捷指令变量可以提供该预设）。

## 示例语句

下列是注册到 Siri 与快捷指令 app 的语句。每条语句里的 `SimpleZip` 代表应用名称。

| 动作 | 语句 |
| --- | --- |
| Extract Archive | "Extract an archive with SimpleZip" |
| Create Archive | "Create an archive with SimpleZip" |
| Test Archive Integrity | "Test an archive with SimpleZip" · "Check an archive with SimpleZip" |
| Verify Checksums | "Verify checksums with SimpleZip" · "Verify a SHA256SUMS file with SimpleZip" |
| Compare Archives | "Compare archives with SimpleZip" · "Compare two archives with SimpleZip" |
| Search Archive Contents | "Search an archive with SimpleZip" · "Search archive contents with SimpleZip" |
| Inspect Archive | "Inspect an archive with SimpleZip" · "Inspect an archive for release with SimpleZip" |
| Create Release Package | "Create a release package with SimpleZip" · "Package a release with SimpleZip" |

## macOS 可用性

- 这些 intent 本身使用 `AppEntity` / `EntityQuery`，自 **macOS 13** 起可用——即 app 的部署目标。因此这些动作与实体在 macOS 13
  及更高版本上都能用。
- 把动作与示例语句预注册进快捷指令 app、Spotlight 与 Siri 建议的 `AppShortcutsProvider`（`SimpleZipAppShortcuts`）受限于
  **macOS 14 及更高版本**（`@available(macOS 14.0, *)`）。在 macOS 13 上这些 intent 仍可完整使用，只是不作为建议被预注册。
- 发布包的 Spotlight 索引（Release Package 上的 `IndexedEntity` 一致性）需要 **macOS 15 及更高版本**；在更旧的系统上是空操作。

## 安全说明

- 动作无人值守运行，绝不弹窗。在 app 里需要交互的操作——例如把发布包签名为 `.szs`——即使所选预设要求，也会在快捷指令上下文里被跳过。
- 加密归档无需弹窗处理。*Test Archive Integrity* 先不带密码尝试，仅在错误表明需要密码、配置了可用的预设密码、且允许使用预设密码的
  自动化偏好已启用时，才用预设密码重试一次。
- *Search Archive Contents* 只列出归档暴露出的内容；条目名称需要密码的归档不会被列出，因此其内容绝不被泄露。
- 关于归档处理的项目整体安全规则，见 [`../SECURITY.zh-CN.md`](../SECURITY.zh-CN.md)。

## 另见

- [`CLI.zh-CN.md`](./CLI.zh-CN.md)——命令行伴随工具。
- [`URL-SCHEME.zh-CN.md`](./URL-SCHEME.zh-CN.md)——`simplezip://` URL Scheme。
- [`ARCHITECTURE.zh-CN.md`](./ARCHITECTURE.zh-CN.md)——所有权边界，以及这些动作复用的无窗口核心。
