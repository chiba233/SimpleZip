# 超大文件拆分计划(0.3.3 整理)

> 目的:把 900+ 行的文件拆成单一职责的小文件,让 review / 定位 / AI 协作都不再翻千行。
> 本文是**计划**,不是已完成项 —— 动手前先读「执行纪律」。

## 执行纪律(每一刀都遵守)

1. **纯移动优先**:第一刀永远是「把整块代码原样搬去新文件」,零行为变更;改进留给第二刀。
2. **一次一个文件**:一个 commit 只拆一个文件,构建 + 250+ 测试全过才动下一个。
3. **访问级别最小放宽**:跨文件后 `private` 才升 `internal`,并在声明处注释为什么。
4. **新 Core 文件必须登记 `Package.swift` 的 `sources` 清单**(显式列表,漏了 SwiftPM 直接编译失败 —— xip 已踩过)。
5. **别混功能**:拆分 commit 里不顺手修 bug、不顺手改 UI(A10/A14)。
6. 历史先例可参考:GPGBackend(#82)、ArchiveExtractionCoordinator(#83)、ExternalExtractWindow(#84)、ArchiveBrowserModel(#86)、ActivityView → ActivityTaskRow(0.3.3,`f01814f`)。

## 现状(2026-06-11,从大到小)

| 文件 | 行数 | 状态 |
|---|---:|---|
| Features/ArchiveBrowser/FileTable.swift | 1349 | 🔴 待拆(P1) |
| Core/AppPreferences.swift | 1203 | 🟡 待拆(P2) |
| ArchiveBrowserModel+CreateExtract.swift | 1078 | 🟡 待拆(P3) |
| Features/Welcome/WelcomeAssistantView.swift | 1051 | 🟡 待拆(P4) |
| App/ContentView.swift | 1036 | 🟡 已有任务 #87/#92 |
| Features/Settings/Panes/GPGPane.swift | 978 | 🟡 已有任务 #96 |
| ArchiveBrowserModel+FileOps.swift | 970 | 🟡 已有任务 #101 |
| Features/ArchiveBrowser/ArchiveTable.swift | 956 | 🟢 低优先 |
| ArchiveCreationOptionsView.swift | 864 | 🟢 低优先 |
| ArchiveExtractionCoordinator.swift | 814 | 🟢 0.3.0 已拆过一轮 |

阈值参考:>900 行必拆;600–900 行看内聚度;<600 行不动。

## 各文件拆法

### P1 — FileTable.swift(1349 行)

一个文件里住着四种职责。拆成同目录四个文件,全部纯移动:

| 新文件 | 内容 | 预估行数 |
|---|---|---:|
| `FileTable.swift`(保留) | SwiftUI View + representable + Coordinator 的数据源/选区/列管理 | ~450 |
| `FileTableMenu.swift` | `menuNeedsUpdate` 起的整个右键菜单构建 + 全部 `@objc` action(`extension FileTable.Coordinator`) | ~420 |
| `FileTableDragDrop.swift` | 拖出(file promise / sourceOperationMask)+ 拖入(validateDrop / acceptDrop / 缓存)(`extension`) | ~220 |
| `FileTableEditing.swift` | 内联重命名(textField delegate / Esc 取消 / 提交) | ~180 |

风险:Coordinator 的 `private` 成员被 extension 引用 → 升 internal;菜单里引用的辅助计算属性要跟菜单一起走。

### P2 — AppPreferences.swift(1203 行)

三段式,天然可拆:

| 新文件 | 内容 |
|---|---|
| `AppPreferences.swift`(保留) | `Key` 常量表 + defaults 句柄 + 基础读写 |
| `AppPreferences+Accessors.swift` | 各域 getter/setter(列开关 / 启动位置 / GPG / 活动中心 …) |
| `AppPreferences+Backup.swift` | `exportableUserDefaultsKeys` / `exportableSnapshot` / `exportablePayload` / `importPayload` / 恢复默认 |

⚠️ 三处都在 SwiftPM target,`Package.swift` sources 要同步加两行。
⚠️ 备份相关测试(PreferencesPayloadCodecTests)是这块的回归网,拆完必跑。

### P3 — ArchiveBrowserModel+CreateExtract.swift(1078 行)

按动词分家:`+Create.swift`(创建对话框编排 / performCreateArchive / 添加文件进归档)与
`+Extract.swift`(解压编排 / 安全检查前置 / siz·szs 特化路径)。两块共享的小工具
(目标路径计算等)先复制判断:只有双方都用才放 `+CreateExtractShared.swift`,避免为两行代码开第三个文件。

### P4 — WelcomeAssistantView.swift(1051 行)

容器(分页 / 进度 / footer / hero)留在主文件;11 个 `Welcome*Step` 子视图按页搬进
`Welcome/Steps/` 目录(每页一个文件,2–3 个 step 同文件)。`WelcomeStepShell` 升 internal 共享。

### 已挂任务编号的(执行时直接领任务)

- **#87/#92** ContentView:sheet 路由表外移成 `ContentSheetRouter`,外部打开(URL scheme / NSService)路由外移。
- **#96** GPGPane:抽 `GPGPaneModel`(状态 + 动作编排),View 只剩渲染。
- **#101** FileOps → `FileOperationController`(0.3.0 #86 的阶段 3,分操作族搬 + 手测)。
- **#91** ArchiveTransferModels 挪 Tasks/ 或 Core/。

### 低优先(理由)

- `ArchiveTable.swift` 956 行:其中 ~170 行是 `ArchiveColumn` enum(四个 switch),挪去
  `ArchiveColumn.swift` 与 FileColumn 对称即可,其余 Coordinator 内聚度尚可。
- `ArchiveCreationOptionsView.swift` 864 行:刚做完 #115 模板消费,等功能稳定再拆 7z 高级区。
- `ArchiveExtractionCoordinator.swift` 814 行:0.3.0 拆过一轮,剩余是冲突 UI + 安全流程,内聚。

## 建议节奏

每个 0.3.x 里塞 1–2 刀(跟功能 commit 分开),P1 → P2 → P3 → P4 → 编号任务。
全部做完后预期:仓库不再有 >900 行的 Swift 文件,Features 层单文件均值 < 400 行。
