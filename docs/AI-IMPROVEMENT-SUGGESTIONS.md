# SimpleZip AI 改进建议草案

本文是给后续实现前讨论用的建议稿。目标不是把 AI 变成安全裁判或自动执行器，而是把现有只读 AI 助手的数据面做厚，让它在活动中心筛选、档案定位、报告解释、自动化建议和创建/解压预检里都能拿到足够完整的事实。

核心方向：AI 不应该只看到用户界面上那几行文字。凡是本地已有、与任务或档案判断有关、且不触碰密码和加密内容的数据，都应该通过受控的数据源进入 AI 上下文。密码、口令、GPG 私钥材料、GPG 密文、加密归档的条目名/内容、解密后的明文内容仍然是硬红线，不能进入 AI prompt、缓存、索引或日志解释输入。

## 现状观察

当前 AI 入口主要在 `SimpleZip/Features/AI/AIReportAssistant.swift`，通过 FoundationModels 做端上生成，并由 `AIGenerationSerializer` 串行化模型调用。整体原则已经正确：只读、端上、可用性门控、失败不影响主流程、AI 只解释或把自然语言转换成结构化规格。

已有 AI 功能包括：

- 活动中心自然语言筛选：`ActivityView` 里输入一句话，AI 输出 `ActivityFilterSpec`，App 再用代码确定性匹配。
- 设置搜索：AI 从 `SettingsCatalog` 中选择设置项和导航/开关意图。
- 档案内文件定位：AI 抽取关键词，再用 `ArchiveListingCacheStore.search` 在非加密清单缓存里搜索。
- 报告解释：发布检查、签名、元数据、空间分析、敏感文件名、近似重复、目录审计等报告由 AI 解释。
- 创建/解压内联建议：对话框打开后自动生成一条只读建议。
- 失败解释：失败任务把失败消息和命令输出尾部交给 AI 解释。

现有代码里已经多处写了“给 AI 真实样本条目，而不是只给计数”的经验，这个方向应该系统化。现在的问题是每个调用点各自拼 prompt，能喂多少数据取决于当时写功能时想到什么，活动中心尤其薄。

## 红线和数据权限

建议把 AI 数据权限写成统一规则，而不是散落在每个 prompt 注释里。

### 永远禁止进入 AI 的数据

- 用户输入的密码、口令、passphrase、Keychain 取出的密码、SessionPasswordCache 中的密码。
- GPG 私钥、私钥口令、加密用 passphrase、任何可恢复密钥材料。
- GPG 密文内容、加密容器中的加密 payload。
- 加密归档的条目名和内容。`ArchiveItem.isEncrypted == true` 的条目整条排除，头加密导致清单不可见的归档也不为 AI 生成条目上下文。
- 解密后临时文件的内容和路径细节，除非以后单独设计一个明确的用户确认流程。默认 AI 不读解密产物。

### 可以进入 AI 的数据

- 非加密归档清单中的条目名、目录结构、大小、CRC、方法、属性、权限、时间戳等元数据。
- 用户本来在本机执行过的任务元数据：任务名、来源、状态、时间、耗时、任务类型、输入/输出路径、产物名、失败消息、后端输出日志、传输记录、hash 报告、diff 报告、报告附件。
- UI 没展示但本地已有的结构化事实：写锁等待、并发槽等待、重跑能力、失败是否已看过、报告里的完整 finding、质量门违规、空间分析分布、敏感文件名分类、近似重复分组、发布 ledger 对比。
- 后端命令参数中不含敏感值的部分。仍需统一 redaction，禁止任何 `-p...`、password、passphrase、token、secret 形态进入 prompt。

### 设计原则

- “AI 可达”不等于“无脑把所有历史塞进 prompt”。应建立受控数据源和上下文包：先由确定性代码抽取、过滤、打标签、截断，再交给 AI 理解或排序。
- AI 不直接执行筛选、删除、放行、覆盖、解密、验签决策。AI 只输出规格、解释、建议或排序理由，最终匹配和动作由 Swift 确定性代码完成。
- 所有 AI 上下文都应可调试：能在开发模式导出“本次发给 AI 的 facts”，并确认不含红线数据。

## 建议一：建立统一的 AI 数据源控制层

新增一个小而明确的只读层，例如 `AIContextProvider` / `AIContextEnvelope`。它不拥有业务逻辑，只负责把已有模型转成 AI 可读事实。

建议的数据结构：

- `AIContextEnvelope`
  - `purpose`：activityFilter、failureExplanation、archiveFinder、createAdvisory 等。
  - `privacyLevel`：publicMetadata、localUserMetadata、diagnostics、blockedSensitive。
  - `facts`：结构化 key/value 或 Codable payload。
  - `samples`：有上限的真实样本，如条目路径、失败行、传输记录。
  - `omissions`：因为加密、体积、TTL、上限、权限而省略了什么。
  - `sourceIDs`：任务 id、归档路径哈希、报告 id，方便追溯。

这一层要集中做：

- 敏感字段过滤和 redaction。
- 加密条目排除。
- 大数据截断策略。
- 每类上下文的样本预算。
- prompt 前事实摘要。
- debug 导出。

这样以后新增 AI 功能时，不再每个页面手写“哪些能喂、哪些不能喂”。

## 建议二：把本地数据格式化成 AI 友好的数据集

AI 输入不应该是“把对象 dump 成字符串”，也不应该是 UI 文案拼接。建议把所有可给 AI 的数据统一转成短小、稳定、可测试的事实数据集：字段名固定、枚举值固定、数量有预算、敏感数据先脱敏、长文本先抽取信号。

### 总格式

建议 prompt 里只放三段：

1. `task` / `archive` / `report` 的结构化 JSON facts。
2. `samples`：少量真实样本，按类型分组。
3. `omissions`：明确告诉 AI 哪些数据因为隐私或体积被省略。

推荐 JSON 而不是自然语言段落。JSON 字段更稳定，便于测试，也更容易确认没有红线数据。

```json
{
  "schema": "simplezip.ai.context.v1",
  "purpose": "activity_filter",
  "generatedAt": "2026-06-15T10:30:00Z",
  "privacy": {
    "level": "local_metadata",
    "redacted": true,
    "encryptedEntryNamesIncluded": false,
    "passwordsIncluded": false
  },
  "budget": {
    "maxTasks": 80,
    "maxLogCharsPerTask": 800,
    "maxSamplesPerGroup": 8
  },
  "facts": {},
  "samples": {},
  "omissions": []
}
```

### 活动中心任务数据集

活动中心筛选最适合用 JSONL：一行一个任务。AI 读取起来像一个小表，App 也容易按 id 回查。

每条任务建议压成 `AITaskRecord`：

```json
{
  "id": "task-7B2F",
  "category": "archive",
  "kind": "extract",
  "source": "finder",
  "status": "failed",
  "startedAt": "2026-06-15T09:12:40Z",
  "finishedAt": "2026-06-15T09:12:58Z",
  "durationSeconds": 18,
  "title": "Extract minecraft.zip",
  "detail": "~/Downloads/minecraft.zip",
  "files": {
    "archiveName": "minecraft.zip",
    "archiveExtension": "zip",
    "inputNames": ["minecraft.zip"],
    "outputNames": [],
    "locationKinds": ["downloads"],
    "pathTokens": ["downloads", "minecraft.zip"]
  },
  "operation": {
    "backend": "7zz",
    "commandKind": "extract",
    "safeArguments": ["x", "-y"],
    "containsPasswordArgument": false
  },
  "diagnostics": {
    "tags": ["permission-denied", "destination-conflict"],
    "failureMessage": "Cannot create output directory.",
    "errorLines": [
      "ERROR: Can not create output directory : Permission denied"
    ],
    "logTail": "ERROR: Can not create output directory : Permission denied"
  },
  "result": {
    "outputURLKind": null,
    "skippedReason": null,
    "canRerun": true,
    "canRerunWithChanges": false,
    "canResumeFromFailure": false
  },
  "reports": {
    "attachmentTypes": [],
    "hashSummary": null,
    "diffSummary": null,
    "transferSummary": {
      "added": 0,
      "overwritten": 0,
      "skipped": 0,
      "failed": 0,
      "sampleNames": []
    }
  },
  "uiHiddenFacts": {
    "failureSeen": false,
    "awaitedConcurrencySlot": false,
    "waitedForWriteLock": false,
    "spotlightLocatable": true
  }
}
```

注意几点：

- `id` 可以是短 id 或真实 UUID，但 prompt 里只需要能回查。AI 输出 task id 后，App 必须校验这个 id 存在。
- `safeArguments` 必须经过 redaction，任何密码形态都不进入。
- `pathTokens` 是路径搜索用的低敏 token。默认不要把完整绝对路径长期给习惯摘要；当次筛选可给当前任务的 display path。
- `diagnostics.tags` 必须由确定性分类器生成，AI 只使用标签，不负责从日志里猜标签。
- `logTail` 控制在几百到一千字符内；优先给错误行，少给完整日志。

给 AI 的活动中心输入可以是：

```jsonl
{"id":"task-7B2F","kind":"extract","source":"finder","status":"failed","title":"Extract minecraft.zip","files":{"archiveExtension":"zip","locationKinds":["downloads"]},"diagnostics":{"tags":["permission-denied"],"errorLines":["Permission denied"]},"durationSeconds":18}
{"id":"task-91AA","kind":"test","source":"cli","status":"failed","title":"Test release.7z","files":{"archiveExtension":"7z","locationKinds":["desktop"]},"diagnostics":{"tags":["checksum-mismatch"],"errorLines":["Data Error"]},"durationSeconds":4}
{"id":"task-42CE","kind":"create","source":"app","status":"succeeded","title":"Create Source.tar.zst","files":{"archiveExtension":"zst","locationKinds":["same-directory"]},"diagnostics":{"tags":[]},"durationSeconds":132}
```

如果候选超过预算，先由 App 本地召回，再只给 AI 候选摘要：

```json
{
  "query": "找今天 Finder 解压失败的 zip",
  "candidatePolicy": "deterministic_prefilter",
  "prefilter": {
    "category": "archive",
    "source": "finder",
    "status": "failed",
    "kind": "extract",
    "format": "zip",
    "timeWindow": "today"
  },
  "candidateCount": 6,
  "candidates": [
    {"id":"task-7B2F","title":"Extract minecraft.zip","diagnosticTags":["permission-denied"],"startedAt":"09:12"},
    {"id":"task-51AF","title":"Extract mods.zip","diagnosticTags":["missing-volume"],"startedAt":"08:44"}
  ],
  "omissions": [
    {"type":"task_count_truncated","omitted":4,"reason":"candidate budget"}
  ]
}
```

### 归档清单数据集

归档查找不要给 AI 全量条目。先由 App 从 `ArchiveListingCacheEntry` 派生小摘要：

```json
{
  "archiveID": "archive-13F0",
  "archiveName": "SimpleZip-source.zip",
  "archiveExtension": "zip",
  "recordedAt": "2026-06-14T18:20:00Z",
  "archiveByteSize": 48219312,
  "entryStats": {
    "totalEntries": 1842,
    "visibleEntries": 1810,
    "encryptedEntriesOmitted": 32,
    "truncated": false
  },
  "structure": {
    "topLevelNames": ["SimpleZip", "README.md", "Package.swift"],
    "topLevelDirectoryCount": 1,
    "looseTopLevelFileCount": 2,
    "looksLikeSingleRootFolder": true
  },
  "fileTypes": {
    "extensions": [
      {"ext":"swift","count":420,"bytes":1200000},
      {"ext":"md","count":18,"bytes":220000},
      {"ext":"strings","count":12,"bytes":180000}
    ],
    "semanticTags": ["source-code", "localizations", "documentation", "license"]
  },
  "samples": {
    "paths": [
      "SimpleZip/App/SimpleZipApp.swift",
      "SimpleZip/en.lproj/Localizable.strings",
      "README.md"
    ],
    "largestFiles": [
      {"name":"demo.mov","bytes":18000000}
    ]
  },
  "omissions": [
    {"type":"encrypted_entries","count":32,"policy":"names_not_available_to_ai"}
  ]
}
```

AI 可以用这份摘要判断“源码包”“包含本地化”“像 release artifact”，但真实搜索仍由 `ArchiveListingCacheStore.search` 或后续确定性索引完成。

### 报告数据集

报告解释也应该统一成 facts，而不是每个 prompt 临时写自然语言。

以发布检查为例：

```json
{
  "reportType": "releaseInspection",
  "archiveName": "SimpleZip-0.4.5.zip",
  "stats": {
    "fileCount": 312,
    "folderCount": 44,
    "totalBytes": 88234122,
    "junkCount": 0,
    "executableCount": 2,
    "symlinkCount": 0,
    "encryptedCount": 0
  },
  "integrity": {
    "testPassed": true,
    "failureMessage": null
  },
  "securityFindings": [
    {
      "kind": "absolutePath",
      "count": 2,
      "samples": ["tmp/build/output.log", "var/cache/state.json"]
    }
  ],
  "qualityGates": [
    {"rule":"checksum_written","severity":"pass","count":1},
    {"rule":"signature_present","severity":"warning","count":0}
  ],
  "artifacts": {
    "sha256Written": true,
    "signedContainer": false,
    "publicKeyBesideSignature": false
  },
  "omissions": []
}
```

AI 的任务是解释这份 facts。风险等级、签名有效性、校验结果仍然来自确定性代码。

### 失败诊断数据集

失败解释要先做分类，再给 AI：

```json
{
  "task": {
    "id": "task-7B2F",
    "kind": "extract",
    "source": "finder",
    "title": "Extract minecraft.zip",
    "durationSeconds": 18
  },
  "failure": {
    "message": "Cannot create output directory.",
    "classifiedTags": ["permission-denied"],
    "confidence": "high",
    "errorLines": [
      "ERROR: Can not create output directory : Permission denied"
    ],
    "logTail": "ERROR: Can not create output directory : Permission denied"
  },
  "filesystemContext": {
    "destinationKind": "downloads",
    "destinationExists": true,
    "freeSpaceKnown": true,
    "freeSpaceBytes": 120034123776,
    "writableCheck": "failed"
  },
  "recentSimilarFailures": {
    "count": 2,
    "tags": ["permission-denied"],
    "windowDays": 14
  },
  "omissions": [
    {"type":"raw_log_truncated","keptChars":800},
    {"type":"sensitive_patterns_redacted","count":1}
  ]
}
```

这样 AI 能给具体解释，但不会拿到密码，也不会靠幻觉判断根因。

### 用户习惯小上下文数据集

习惯摘要必须更小，适合每次 prompt 附带。推荐分两层：确定性统计 JSON + AI 压缩后的 hints。

```json
{
  "schema": "simplezip.ai.habits.v1",
  "updatedAt": "2026-06-15T03:00:00Z",
  "sourceWindow": {
    "days": 90,
    "taskCount": 180
  },
  "deterministicStats": {
    "topKinds": [
      {"kind":"extract","count":74},
      {"kind":"create","count":48},
      {"kind":"test","count":22}
    ],
    "topSources": [
      {"source":"finder","count":63},
      {"source":"app","count":58},
      {"source":"cli","count":31}
    ],
    "topFormats": [
      {"format":"zip","count":68},
      {"format":"7z","count":34},
      {"format":"tar.zst","count":19}
    ],
    "destinationKinds": [
      {"kind":"same-directory","count":52},
      {"kind":"downloads","count":41},
      {"kind":"external-drive","count":11}
    ],
    "failureTags": [
      {"tag":"missing-volume","count":5},
      {"tag":"permission-denied","count":3}
    ],
    "commonOptions": {
      "excludeJunkOften": true,
      "testAfterCreateOften": true,
      "reproducibleOften": false
    }
  },
  "promptHints": [
    "The user often extracts archives launched from Finder.",
    "For create tasks, the user often enables exclude-junk and test-after-create.",
    "Recent failures are more often missing split volumes than corrupt archives."
  ],
  "omissions": [
    {"type":"full_paths","policy":"stored_as_location_categories_only"},
    {"type":"encrypted_entry_names","policy":"never_included"},
    {"type":"raw_logs","policy":"classified_then_discarded"}
  ]
}
```

后续 prompt 不需要带完整 `deterministicStats`，通常只带 `promptHints` 和少量计数即可。比如创建建议只需要：

```json
{
  "habitHints": [
    "The user often enables exclude-junk and test-after-create for create tasks."
  ],
  "habitStats": {
    "topCreateFormats": ["zip", "tar.zst"],
    "testAfterCreateOften": true
  }
}
```

### 格式化规则

建议所有 AI 数据集都遵守这些规则：

- 枚举用英文稳定 token，例如 `permission-denied`、`missing-volume`、`same-directory`，不要用本地化文案。
- 数值保留原始单位，例如 bytes、seconds；不要让 AI 负责单位换算。
- 时间同时给 ISO 时间和必要的人类窗口，例如 `today`、`last_7_days`，但筛选以 Swift 计算为准。
- 路径拆成 `displayName`、`extension`、`locationKind`、`pathTokens`。完整路径只在当次任务需要时短期出现，不进习惯摘要。
- 长日志先提取 `errorLines`，再给短 `logTail`。不要给完整 raw output。
- 大数组只给 top N，并在 `omissions` 里写清省略数量。
- 每个样本都带类型，例如 `suspiciousPaths`、`largestFiles`、`failedEntries`，不要混成一段逗号文本。
- 所有进入 AI 的结构都应 Codable，测试可以直接断言字段和隐私策略。

### Prompt 组织方式

建议模板固定为：

```text
You are helping with SimpleZip. Use only the JSON facts below.
Do not invent facts. Do not make safety decisions. Passwords and encrypted entry names are never provided.
Return the requested structured output.

JSON facts:
<compact JSON or JSONL>
```

也就是说，prompt 里解释规则，数据里只放 facts。这样模型更容易稳定使用数据，也方便以后替换模型或做回归测试。

### 数据策略：不要过度保守，要分级开放

现在的 AI 数据策略容易走向“为了安全只给一点点标题和关键词”，结果就是 AI 稳定但没用。建议改成分级开放：除密码、密钥、加密条目名、密文、解密明文这些硬红线外，其他本机已有的元数据都应该默认可进入 AI 上下文，只是要按用途、预算和保留周期控制。

这里要明确一个前提：SimpleZip 当前接的是 Apple 本地模型，不是把数据发到云端服务。因此策略不应该按“远程 LLM 最小数据暴露”来设计，而应该按“本机智能索引”来设计。只要数据已经在本机、App 已经通过用户授权能访问、并且不属于硬红线，AI 就应该能在特定场景读取更完整的上下文。

换句话说：默认目标不是“尽量少给”，而是“尽量给足，但全部本地、可解释、可清空、可调试”。如果 AI 只看到 UI 上那几行文本，它永远会鸡肋。

建议分层：

- `publicAppCatalog`：应用内静态目录，例如设置项、动作目录、帮助文档索引、格式能力矩阵。可以完整给 AI。
- `localUserMetadata`：本机使用元数据，例如任务、完整路径、路径类别、文件名、非加密归档条目名、设置当前值、历史动作反馈。可以给 AI，默认应较充分开放，但要有预算、可清空、可调试。
- `localContentSignals`：本机非加密、非密码、非密钥文件的轻量内容信号，例如文本文件前几 KB 摘要、README/manifest/config 的字段名、图片/视频基础 metadata、代码项目 marker。可选增强开放，用于 AI 工作区、归档画像和智能查找。
- `diagnosticsMetadata`：失败消息、错误行、后端输出尾部、文件系统状态。可以给 AI，但必须先 redaction，且不长期进入习惯摘要。
- `sensitiveBlocked`：密码、passphrase、密钥材料、加密条目名、密文、解密明文。永远不给 AI。

具体原则：

- 非加密文件名和非加密归档条目名不应该默认被当作禁区。它们本来就在 UI、Spotlight、缓存里用于本机搜索，AI 可以使用。
- 完整路径可以在当次上下文里使用，尤其是用户当前正在浏览、选中、操作或刚刚失败的路径。既然是本地模型，当前场景里的完整路径不应该被过度隐藏。
- 长期学习默认用 `locationKind + pathHash + folderNameTokens`，但用户开启“深度本地上下文”后，可以允许保存用户明确固定路径、固定工作区路径和常用项目路径的别名。
- 设置当前值应该给 AI。用户问“别记住我打开过的压缩包”，AI 必须知道归档清单缓存开关当前是否开启、缓存数量、TTL。
- 后端日志可以给 AI 错误行和短尾部，不要因为“日志可能敏感”就完全不给。真正要做的是 redaction 和截断。
- 大数据不是不给，而是先召回、聚合、采样、写 `omissions`。
- 对非加密文本内容，不要一刀切禁止。README、LICENSE、manifest、metadata.json、package.json、Package.swift、pyproject.toml、pom.xml、Info.plist 这类 marker 文件的字段名和短摘要，对判断“源码包/发布包/应用包/配置包”非常有价值。默认可读取文件名和结构；深度本地上下文模式下可读取短内容摘要。
- UI 没显示的数据也应该给 AI：任务内部状态、重跑能力、失败是否已看过、写锁等待、缓存 TTL、报告 finding、归档截断信息、设置依赖、动作候选安全等级，都应该进入场景 facts。

### 本地 Apple AI 的深度上下文模式

建议设计两个默认可理解的数据模式：

- `标准本地上下文`：默认开启。给 AI 足量本机元数据，包括完整当前路径、非加密文件名、非加密归档条目名、活动中心任务 facts、设置当前值、报告 facts、错误行、短日志尾部。
- `深度本地上下文`：用户可选开启。进一步允许读取非加密文本 marker 的短内容摘要、固定路径别名、更多归档结构样本、更长任务历史窗口、更完整的报告 finding。

`深度本地上下文` 不是突破红线。即使开启，也仍然禁止：

- 密码、passphrase、token、secret、密钥材料；
- GPG 私钥、公钥信任私密材料之外的密钥内容；
- GPG 密文内容；
- 加密归档条目名和内容；
- 解密后的临时明文；
- 用户明确排除的路径。

深度模式可以让 AI 真正变聪明，例如：

- 看到 `package.json` 的 dependency 字段名，判断这是 Node 项目源码包；
- 看到 `Package.swift`、`Sources/`、`Tests/`，判断这是 SwiftPM 源码包；
- 看到 `SHA256SUMS`、`.asc`、`.dmg`、`.app`，判断这是发布产物目录；
- 看到当前目录反复出现 `.siz`、`.szs`、`.gpg`，把工作区主题命名成 SIZ/SZS 测试，而不是泛泛叫“归档文件”；
- 看到失败任务的完整路径和相邻任务，判断“这是同一个测试目录里的系列问题”。

建议每个 AI context 都写明当前数据模式：

```json
{
  "privacy": {
    "execution": "on_device_apple_foundation_models",
    "mode": "deep_local_context",
    "passwordsIncluded": false,
    "encryptedEntryNamesIncluded": false,
    "decryptedContentIncluded": false,
    "localTextSnippetsIncluded": true
  }
}
```

### 全 AI 场景数据矩阵

所有 AI 功能都应该走同一个流程：确定性代码收集事实 → 格式化成场景数据集 → AI 只读理解/排序/解释 → App 校验输出并执行安全动作。下面是建议的全场景数据矩阵。

| AI 场景 | 应给的数据 | 格式化数据集 | 使用时怎么读 | AI 输出 |
| --- | --- | --- | --- | --- |
| 专属 AI 中心首页 | 当前窗口上下文、活动中心摘要、最近失败、归档记忆、设置健康、习惯 hints、可用 AI 功能状态 | `simplezip.ai.center.home.v1` | 先读缓存摘要；若过期，后台从各 store 拉取候选 facts；AI 只做分组和优先级 | 工作台卡片、建议入口、待处理事项 |
| 主窗口 AI 工作区 / AI 文件夹 | 当前 folder/archive/tag、选中项、最近相关任务、归档记忆候选、习惯 hints、工作区 prompt、推荐主题反馈 | `simplezip.ai.workspaceTheme.input.v1` + `simplezip.ai.workspaceTree.input.v1` | 侧边栏读取 `AIWorkspaceStore`；点工作区读取上次 `AIVirtualFolderTree`；后台刷新推荐主题和虚拟树；动作 id 回查 source refs | 多个主题工作区、虚拟文件夹树、压缩包内条目混排、可点动作 |
| 活动中心 AI 工作台 | 当前 pane/filter、可见任务摘要、高价值任务、失败标签、可用重跑/报告动作 | `simplezip.ai.activitySidebar.input.v1` | 任务列表变化只标记过期；AI 工作台按节读取 cards 和 filter chips | 需要处理卡片、筛选 chip、失败摘要 |
| 活动中心自然语言筛选 | `ActivityTaskAIIndex` 候选任务、状态/来源/时间/路径/失败标签/报告摘要 | `simplezip.ai.activityFilter.v2` | App 先本地召回候选；AI 输出 filter spec 或排序；App 再确定性匹配 | `ActivityFilterSpecV2`、候选 id 排序、命中解释 |
| 动态工具栏推荐 | 选中形态、候选动作、安全等级、位置类别、路径 hash、目录 marker、动作使用反馈 | `simplezip.ai.actionContext.v1` | `ContextualActionCandidateProvider` 先枚举动作；ranker 读统计和 AI 理由 | `rankedActions`、推荐理由、降权理由 |
| 设置 AI 助手 | 设置目录、当前值、依赖、影响功能、隐私说明、缓存数量、模型可用性、安全动作白名单 | `simplezip.ai.settingsCatalog.v1` | 打开设置时建 catalog；查询时给完整语义目录；安全动作必须 registry 校验 | 匹配设置、解释、相关设置、安全动作 |
| 归档记忆查找 | 非加密清单摘要、扩展名分布、marker 文件、语义标签、样本路径、活动中心相关任务 | `simplezip.ai.archiveMemory.v1` | App 从 `ArchiveMemoryIndex` 召回候选；AI 只排序和说明命中信号 | 归档匹配列表、命中理由、打开/搜索动作 |
| 创建对话框建议 | 输入项样本、扩展名分布、总大小、目标位置、已有冲突、格式/级别/分卷/校验选项、历史偏好 | `simplezip.ai.createAdvisory.v1` | dry-run 完成后生成 facts；习惯 hints 可附带；失败静默 | 一句建议、可选“查看为什么” |
| 解压对话框建议 | 顶层结构、散落/单根、可疑路径、覆盖样本、空间、缺卷、symlink/hardlink、目标位置、历史偏好 | `simplezip.ai.extractAdvisory.v1` | preflight 完成后生成 facts；安全 prompt 仍由规则决定 | 一句建议、风险提醒 |
| 失败解释 | 任务 metadata、失败消息、错误行、日志尾部、filesystem probe、失败标签、近期相似失败 | `simplezip.ai.failureExplanation.v1` | `FailureClassifier` 先分类；AI 读标签和错误行，不读完整日志 | 解释、下一步建议、诊断引用 |
| 报告解释 | 各报告 facts：统计、finding、样本、质量门、签名/校验结果、omissions | `simplezip.ai.reportFacts.<type>.v1` | 报告 view 调 `makeAIContext()`；AI 只解释，不重新判定 | 摘要、注意点、草稿文本 |
| SIZ/SZS/GPG 签名解释 | 验签结果、信任状态、manifest 摘要、问题文件、加密状态说明 | `simplezip.ai.signatureExplanation.v1` | 只读已验证结果；密钥私密材料不进入；坏签名不让 AI 放行 | 签名解释、风险说明 |
| 敏感文件/近似重复 | 确定性扫描结果、分类样本、路径样本、大小/CRC、分组数量 | `simplezip.ai.archiveTriage.v1` | Core 扫描先产结果；AI 只解释“为什么值得看” | 分类解释、检查建议 |
| 发布助手/VERIFY/Release 草稿 | 发布检查、目录审计、ledger 对比、产物名、SHA、签名/公钥存在性、系统要求 | `simplezip.ai.releaseDraft.v1` | 只用报告 facts 起草；输出进可编辑 sheet | VERIFY.md 草稿、Release body、对比摘要 |
| Issue/诊断润色 | 已脱敏 issue、环境、版本、错误、日志摘要、复现步骤 | `simplezip.ai.issueDraft.v1` | 诊断导出先 redaction；AI 只改写和分类 | issue 标题、labels、摘要 |
| 自动化建议 | 活动中心 rich snapshot、重复动作、常用路径类别、来源分布、失败模式、习惯摘要 | `simplezip.ai.automationIdeas.v1` | 低频生成；只建议，不创建 Shortcut | 自动化草稿、步骤 |
| 习惯小上下文 | 聚合统计、路径类别、pathHash、动作反馈、格式/来源/目录 marker、失败标签 | `simplezip.ai.habits.v1` | 空闲低频更新；prompt 只读 `promptHints` 和少量统计 | 短 hints、推荐偏好 |

### 场景数据集读取顺序

每个 AI 调用点都按这个顺序读数据：

1. `currentContext`：当前窗口模式、当前文件夹/归档、选中项、当前 pane/filter。
2. `candidateFacts`：当前场景最相关的候选对象，例如任务、归档、设置、动作。
3. `historySignals`：同目录、同扩展名、同动作、同失败标签的统计。
4. `habitHints`：小上下文摘要，控制在几条短句。
5. `omissions`：明确告诉 AI 哪些数据没给、为什么没给。

禁止 AI 直接读取全局 store。所有 store 读取都在 `AIContextBuilder` 里完成：

```swift
protocol AIContextBuilder {
    associatedtype Context: Codable
    func build() async throws -> AIContextEnvelope<Context>
}
```

建议拆分 builder：

- `AICenterContextBuilder`
- `ActivityAIContextBuilder`
- `ActionRecommendationContextBuilder`
- `SettingsAIContextBuilder`
- `ArchiveMemoryContextBuilder`
- `CreateAdvisoryContextBuilder`
- `ExtractAdvisoryContextBuilder`
- `FailureExplanationContextBuilder`
- `ReportAIContextBuilder`

这样“给更多数据”不是每个 view 随手拼，而是每个场景有明确的数据 contract。

## 建议三：独立的专属 AI 中心

除了活动中心 AI 工作台和主窗口 AI 文件夹，还应该有一个独立的 AI 中心。它不是活动中心的子页，也不是设置搜索框，而是 SimpleZip 的全局 AI cockpit：汇总所有 AI 能力、数据索引状态、建议、历史学习和隐私控制。

### 定位

AI 中心解决三个问题：

- 用户不知道 AI 能做什么：AI 中心集中展示“可问什么、能分析什么、最近发现什么”。
- AI 分散在很多小按钮里：AI 中心把活动、归档、设置、自动化、报告、推荐统一起来。
- 用户担心数据：AI 中心展示 AI 可用数据、缓存、习惯摘要、最近生成记录、清空入口。

### 入口

建议提供三个入口：

- 主工具栏独立按钮：`AI 中心`，和活动中心并列。
- 主窗口侧边栏 `AI 文件夹` 顶部有“打开 AI 中心”。
- 活动中心 AI 工作台顶部有“在 AI 中心查看全部”。

### 窗口结构

AI 中心建议是独立窗口，左侧为分区，右侧为具体面板：

```text
AI Center
  总览
  需要处理
  智能查找
  动作推荐
  自动化
  设置助手
  数据与隐私
  调试
```

### 总览页

总览页读取 `simplezip.ai.center.home.v1`：

```json
{
  "schema": "simplezip.ai.center.home.v1",
  "availability": {
    "aiEnabled": true,
    "modelReady": true,
    "lastGenerationAt": "2026-06-15T10:20:00Z"
  },
  "indexes": {
    "activityTasks": 260,
    "archiveMemoryRecords": 48,
    "settingsItems": 72,
    "habitSummaryUpdatedAt": "2026-06-15T03:00:00Z"
  },
  "attention": {
    "unseenFailures": 3,
    "workspaceBytes": 184020112,
    "staleIndexes": ["archiveMemory"]
  },
  "topSuggestions": [
    {"kind":"task","title":"release.7z 校验失败","sourceRef":{"type":"task","id":"task-7B2F"}},
    {"kind":"automation","title":"为 Finder 解压失败创建检查流程","sourceRef":{"type":"habit","id":"habit-current"}}
  ],
  "omissions": [
    {"type":"encrypted_entry_names","policy":"never_included"}
  ]
}
```

总览页展示：

- AI 可用状态；
- 近期最值得处理的任务；
- 归档记忆索引健康；
- 动态动作推荐学习状态；
- 习惯摘要更新时间；
- 数据隐私说明和清空按钮。

### 需要处理页

聚合活动中心和报告：

- 未查看失败；
- 可从失败步继续；
- 发布目录缺校验/签名；
- 工作区临时文件过多；
- 最近重复失败；
- 归档缓存失效或截断过多。

动作只允许跳转：打开活动任务、打开报告、应用筛选、打开设置。

### 智能查找页

把“哪个归档包含文件”和“AI 文件夹”合并成全局查找：

- 搜归档内文件；
- 搜活动任务；
- 搜设置；
- 搜报告；
- 搜最近打开/相关文件夹。

输入一句话，AI 中心先判断 query type，再走对应 builder：

```json
{
  "schema": "simplezip.ai.globalSearch.intent.v1",
  "query": "上次那个带 Localizable.strings 的源码包在哪",
  "candidateDomains": ["archiveMemory", "activityTasks"],
  "intents": [
    {"domain":"archiveMemory","keywords":["Localizable.strings"],"semanticTags":["source-archive"]},
    {"domain":"activityTasks","timeHint":"recent"}
  ]
}
```

### 动作推荐页

展示动态工具栏推荐背后的学习数据：

- 当前目录/当前选择下为什么推荐这个；
- 用户最近对推荐的点击/忽略；
- 可以清空或禁用某类推荐；
- 可以把某个动作固定到工具栏优先级。

这页读取 `ContextualActionUsageStore` 的聚合，不展示完整敏感路径。

### 自动化页

读取活动中心 rich snapshot + habit summary：

- “你经常从 Finder 解压 zip 到 Downloads，要不要建一个检查缺卷的 Shortcut？”
- “你经常创建后测试归档，要不要把 test after create 默认打开？”
- “CLI 失败多是 checksum mismatch，要不要生成一个验证脚本草稿？”

输出仍是草稿，不自动创建。

### 设置助手页

比设置侧栏搜索更完整：

- 显示相关设置组；
- 当前值；
- 影响功能；
- 安全动作；
- 隐私影响；
- 相关帮助。

用户可以从这里跳设置，也可以执行安全白名单动作。

### 数据与隐私页

这是 AI 中心必须有的页：

- AI 主开关；
- 归档记忆索引开关、数量、大小、TTL、清空；
- 动态动作推荐学习数据数量、清空；
- 习惯摘要内容、重算、清空；
- 最近 AI 上下文导出；
- `sensitiveBlocked` 红线说明；
- 每类数据的保留策略。

### 调试页

只在开发者工具或高级模式显示：

- 选择场景；
- 查看本次 `AIContextEnvelope`；
- 查看 redaction 结果；
- 查看 omissions；
- 复制 JSON；
- 运行隐私检查。

### 施工建议

新增窗口控制器：

```swift
final class AICenterWindowController {
    static let shared = AICenterWindowController()
    func show(section: AICenterSection? = nil)
}
```

新增视图和模型：

```swift
enum AICenterSection: String, CaseIterable, Identifiable {
    case overview
    case attention
    case search
    case actionRecommendations
    case automation
    case settingsAssistant
    case dataPrivacy
    case debug
}

@MainActor
final class AICenterModel: ObservableObject {
    @Published var selectedSection: AICenterSection = .overview
    @Published var overview: AICenterOverview?
    @Published var generationState: AIGenerationState = .idle
}
```

AI 中心不直接持有业务逻辑。它只调用各场景 builder 和 store：

- `ActivityHistoryStore.richSnapshot()`
- `ArchiveMemoryIndex.load()`
- `AIHabitSummaryStore.load()`
- `ContextualActionUsageStore.summary()`
- `SettingsAIContextBuilder.build()`

### 分期实现

第一期：无模型总览。

- 新增 AI 中心窗口；
- 总览页显示 AI 可用性、索引数量、未查看失败、缓存状态；
- 数据与隐私页可查看/清空归档缓存和习惯摘要。

第二期：智能查找。

- 接入归档记忆查找、设置助手、活动任务搜索；
- 全局搜索先确定 domain，再调用对应 AI/context builder。

第三期：推荐与自动化。

- 展示动态动作推荐原因；
- 展示自动化建议；
- 支持忽略/隐藏建议。

第四期：调试和隐私审计。

- 每个 AI 场景可导出上下文；
- 加红线扫描；
- 在 AI 中心显示最近生成记录。

## 建议四：主窗口侧边栏增加“AI 文件夹”

如果要让 AI 真正变得有用，不能只把它放在 sheet、popover 或解释按钮里。更实用的形态是把 AI 变成主窗口的一个“组织视图”：在侧边栏增加一个 `AI 文件夹`，点击后主内容区展示 AI 根据本机事实整理出的虚拟文件夹和建议项。

这个功能的定位不是聊天，也不是自动操作。它像 Finder 的智能文件夹，但数据源更宽：活动中心任务、归档清单缓存、报告附件、用户习惯小上下文、当前打开位置和最近失败。AI 负责把这些事实组织成“你现在可能想看的东西”，App 负责确定性地打开文件、定位任务、应用搜索或弹出确认对话框。

### 用户看到什么

侧边栏建议新增一个独立分区：

```text
AI
  AI 文件夹
```

`AI 文件夹` 不应只有一个固定主页。更好的形态是“AI 工作区”：侧边栏里可以出现多个主题工作区，每个工作区像一个虚拟文件夹。用户点击不同工作区后，主内容区展示由 AI 组织出来的虚拟文件夹树、虚拟折叠组和建议项。

侧边栏建议形态：

```text
AI
  + 生成新的工作区...
  需要处理
  发布与校验
  归档里的源码
  最近 Finder 解压失败
  推荐：Downloads 里的 zip 整理        x
  推荐：可能要清理的重复包             x
```

这里有三类工作区：

- 系统工作区：App 默认内置，例如 `需要处理`、`可能要打开`、`归档里的文件`、`发布与校验`、`清理与整理`、`自动化建议`。
- 用户工作区：用户点击 `生成新的工作区...` 后手动输入提示词生成，例如“把最近和 Minecraft 相关的 zip、7z、文件夹都放一起”。
- AI 推荐工作区：后台根据活动中心、当前位置、归档缓存和习惯小上下文自动生成，例如“最近 Finder 解压失败”“Downloads 里的 zip 整理”。推荐工作区右侧默认显示 `x`，含义是“不感兴趣”，点掉后从侧边栏消失，并记录负反馈。

系统工作区和用户工作区可以右键删除或隐藏。系统默认工作区建议使用“隐藏”而不是永久删除，避免用户误删后找不到；用户创建的工作区可以删除。推荐工作区不进入正式列表，除非用户打开、固定或转成用户工作区。

点击某个工作区后，主内容区不是普通列表，而是类似 Finder 文件夹的虚拟视图。它可以混合展示：

- 真实文件系统里的文件或文件夹；
- 归档文件本身；
- 非加密归档清单里的内部条目；
- 活动中心任务；
- 报告附件和报告 finding；
- 自动化草稿；
- 需要用户处理的失败、缺卷、校验问题。

虚拟视图可以用“虚拟文件夹”和“虚拟折叠”组织：

```text
发布与校验
  ▾ 最近失败
      release.7z                         真实归档
      task: Test release.7z failed        活动中心任务
  ▾ 归档内可能相关
      release-assets.7z/README.md         归档内部条目
      release-assets.7z/SHA256SUMS        归档内部条目
  ▾ 可以继续的动作
      重新测试 release.7z                 安全动作
      生成 VERIFY.md 草稿                 需要确认
```

这会比“AI 给几条建议”更有用，因为用户能像浏览文件夹一样浏览 AI 整理出来的工作上下文。尤其是压缩包内文件也能出现在同一个工作区里：例如用户创建“源码包”主题后，AI 可以把磁盘上的 `SimpleZip-source.zip`、里面的 `Package.swift`、`README.md`、最近的发布检查任务和相关失败报告放在同一个虚拟树里。

每个虚拟子文件夹里是建议行，不是磁盘真实文件。建议行可以长这样：

```text
⚠️  release.7z 校验失败
    CLI · 今天 09:12 · 日志显示 Data Error
    动作：打开活动中心任务 / 重新测试 / 复制诊断

📦  SimpleZip-source.zip 看起来像源码包
    420 个 Swift 文件 · 有 README 和 Package.swift
    动作：打开归档 / 在归档内搜索 / 生成摘要

✨  你常用 Finder 解压 zip 到 Downloads
    最近 90 天 63 次 Finder 来源，zip 最常见
    动作：创建 Shortcut 草稿 / 查看相关任务
```

### 不建议伪造成真实 `FileItem`

不要第一版就把 AI 建议塞进 `FileTable` 当作 fake `FileItem`。原因：

- `FileTable` 右键菜单包含移动、复制、删除、重命名、权限、hash、压缩等真实文件操作。虚拟建议混进去很容易误触发真实文件动作。
- `FileItem` 基于 URL 和文件系统属性，AI 建议不一定有真实 URL，例如“重新测试失败任务”“创建自动化草稿”。
- 伪造 URL 或临时文件会污染历史、拖放、Quick Look、Finder reveal、权限编辑等路径，风险大。

推荐第一版新增一个明确模式，而不是复用真实文件表：

```swift
enum BrowserMode: Equatable {
    case folder(URL)
    case archive(URL)
    case tag(String)
    case aiWorkspace(UUID)
}
```

`ContentView` 根据 `model.mode` 分支：

```swift
if case .aiWorkspace = model.mode {
    AISuggestionFolderView(model: model)
} else if case .archive = model.mode {
    ArchiveTable(model: model)
} else {
    FileTable(model: model)
}
```

这样 AI 文件夹有自己的行、菜单、动作和空状态，不会继承真实文件操作。它仍然在主窗口内，用户心智上是“一个文件夹”，工程上是安全的虚拟结果集。

### AI 工作区数据模型

建议新增纯值模型，不让 SwiftUI view 自己拼逻辑。这里重点不是一个固定 `AISuggestionFolder.ID`，而是工作区、虚拟节点、源引用三层：

```swift
struct AIWorkspace: Identifiable, Codable, Equatable {
    enum Origin: String, Codable {
        case system
        case userCreated
        case recommended
    }

    enum Visibility: String, Codable {
        case visible
        case hidden
        case dismissed
    }

    let id: UUID
    let origin: Origin
    let title: String
    let prompt: String?
    let iconSystemName: String
    let visibility: Visibility
    let pinned: Bool
    let generatedAt: Date
    let lastOpenedAt: Date?
    let negativeFeedbackCount: Int
}
```

工作区打开后加载一个虚拟树：

```swift
struct AIVirtualFolderTree: Identifiable, Codable, Equatable {
    let id: UUID
    let workspaceID: UUID
    let title: String
    let prompt: String?
    let generatedAt: Date
    let nodes: [AIVirtualNode]
    let sourceRefs: [AIContextSourceRef]
    let omissions: [AIContextOmission]
}

struct AIVirtualNode: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case group
        case file
        case folder
        case archive
        case archiveEntry
        case task
        case report
        case action
        case automation
        case note
    }

    let id: UUID
    let kind: Kind
    let title: String
    let subtitle: String?
    let reason: String?
    let confidence: Double
    let sourceRefs: [AIContextSourceRef]
    let children: [AIVirtualNode]
    let primaryAction: AISuggestionAction?
    let secondaryActions: [AISuggestionAction]
    let safety: AISuggestionSafety
}
```

`archiveEntry` 节点只允许来自非加密归档清单缓存，必须带 archive source id 和 entry path。不能让 AI 自己凭空写路径：

```swift
struct AIContextSourceRef: Codable, Equatable {
    enum Kind: String, Codable {
        case file
        case folder
        case archive
        case archiveEntry
        case task
        case report
        case setting
        case habit
    }

    let kind: Kind
    let id: String
}
```

动作仍然是受控枚举：

```swift
enum AISuggestionAction: Codable, Equatable {
    case openTask(UUID)
    case openFolder(path: String)
    case revealFile(path: String)
    case openArchive(path: String, revealEntry: String?)
    case applyArchiveSearch(archiveID: String?, query: String)
    case openReport(taskID: UUID)
    case explainFailure(taskID: UUID)
    case draftAutomation(kind: String, seedWorkspaceID: UUID?)
    case openActivityCenter(filter: ActivityFilterSpecV2?)
    case pinRecommendedWorkspace(UUID)
    case dismissRecommendedWorkspace(UUID, reason: String?)
}
```

`AISuggestionSafety` 建议固定表达：

```swift
struct AISuggestionSafety: Codable, Equatable {
    let destructive: Bool
    let touchesEncryptedContent: Bool
    let requiresConfirmation: Bool
    let reason: String?
}
```

第一版规则应强制：

- `destructive == false`。
- `touchesEncryptedContent == false`。
- 任何会创建、解压、覆盖、删除、移动、修改设置的动作都不能作为直接 action，只能打开现有确认 sheet 或跳到相关页面。

### 工作区生成弹窗

侧边栏 `AI` 分区最上面建议放一个 `生成新的工作区...`。点击后弹出轻量 sheet：

```text
生成 AI 工作区

主题
[ 最近发布包里的校验和、报告、失败任务放一起                 ]

数据范围
[x] 当前文件夹
[x] 最近活动
[x] 归档内文件名
[ ] 全部最近缓存

按钮：取消 / 生成
```

如果用户输入提示词，就创建 `userCreated` 工作区，并立刻用这个 prompt 生成虚拟树。示例提示词：

- “把 Downloads 里最近解压失败的 zip 和对应任务放一起”
- “找出所有看起来像源码包的压缩包，并展开关键文件”
- “把发布相关的 7z、校验文件、签名报告和失败任务放一起”
- “帮我整理 Minecraft 相关文件，包含压缩包内的 mod 列表”

如果用户不输入提示词，App 不应该弹空错误；可以生成一个默认“智能工作区”，使用当前上下文和后台推荐主题：

```json
{
  "schema": "simplezip.ai.workspaceCreate.input.v1",
  "mode": "empty_prompt",
  "currentContext": {
    "mode": "folder",
    "displayName": "Downloads",
    "selectedNames": ["2.zip"]
  },
  "recommendedThemes": [
    {
      "themeID": "theme-downloads-zip-cleanup",
      "title": "Downloads 里的 zip 整理",
      "reason": "当前目录包含多个 zip/siz/szs 测试文件，且最近有解压和发布检查任务。"
    },
    {
      "themeID": "theme-release-checks",
      "title": "发布与校验",
      "reason": "最近有测试、签名、校验相关任务。"
    }
  ]
}
```

空 prompt 的行为建议是：优先使用当前目录和当前选择生成一个临时推荐工作区，并让用户可以再改名或固定。这样用户不用学“怎么 prompt”，也能得到工作区。

### 推荐主题和负反馈

后台推荐主题不是普通统计“zip 用得多”。它应该比统计更细，综合：

- 当前文件夹地址和位置类型，例如 Downloads、Desktop、项目目录、固定路径、外置卷。
- 当前选择的文件扩展名、文件名 token、大小、mtime、是否同名系列。
- 最近活动中心任务：来源、动作、格式、失败类型、是否重跑、是否查看。
- 归档清单缓存：非加密条目里的 marker 文件、目录结构、扩展分布。
- 用户创建过哪些工作区、打开过哪些、删过哪些。
- 用户对推荐主题点过哪些 `x`。

推荐主题与用户创建主题效果不一致：

- 推荐主题：轻量、可关闭、默认不持久；右侧有 `x`，点掉就是“不感兴趣”。
- 用户主题：持久、可右键删除、可重命名、可刷新；不会因为后台推荐变化自动消失。
- 系统主题：默认存在，可隐藏，建议不允许彻底删除。

建议记录负反馈：

```swift
struct AIWorkspaceFeedback: Codable, Equatable {
    enum Event: String, Codable {
        case opened
        case pinned
        case dismissed
        case deleted
        case renamed
        case refreshed
        case actionUsed
    }

    let workspaceID: UUID
    let origin: AIWorkspace.Origin
    let event: Event
    let themeTokens: [String]
    let contextLocationKind: String?
    let selectedExtensions: [String]
    let createdAt: Date
}
```

后台总结用户习惯时，负反馈要进入 `AIHabitSummary`：

```json
{
  "workspacePreferences": {
    "likedThemeTokens": ["release", "checksum", "source-code"],
    "dismissedThemeTokens": ["downloads-cleanup", "duplicate-cleanup"],
    "preferredLocationKinds": ["projects", "desktop"],
    "ignoredLocationKinds": ["downloads"],
    "preferredNodeKinds": ["archiveEntry", "task", "report"]
  }
}
```

这样以后 AI 不会只知道“用户常用 zip”，还会知道更具体的偏好：例如用户喜欢“发布校验类工作区”，不喜欢“Downloads 清理类推荐”；用户经常打开归档内部源码文件，但很少点自动化草稿。

### AI 输入数据集

`AI 文件夹` 不能让 AI 自己扫全盘。输入应该来自前面定义的 AI facts，并明确区分“生成工作区主题”和“生成工作区内容”两件事。

主题推荐输入：

```json
{
  "schema": "simplezip.ai.workspaceTheme.input.v1",
  "purpose": "recommend_ai_workspaces",
  "currentContext": {
    "mode": "folder",
    "displayName": "siz 及 szs 测试文件",
    "locationKind": "desktop",
    "selectedNames": ["2.zip"],
    "visibleExtensions": ["siz", "szs", "zip", "gpg", "txt"],
    "folderNameTokens": ["siz", "szs", "test"]
  },
  "activitySignals": {
    "recentTaskKinds": ["test", "extract", "create"],
    "recentFormats": ["zip", "siz", "szs"],
    "recentFailureTags": ["checksum-mismatch"],
    "unseenFailureCount": 1
  },
  "archiveSignals": {
    "cachedArchiveCountNearby": 5,
    "commonMarkers": ["metadata.json", "signature.asc"],
    "knownArchiveEntrySamples": [
      {"archiveID":"archive-2zip","entryPath":"README.md","encrypted":false},
      {"archiveID":"archive-siz","entryPath":"metadata.json","encrypted":false}
    ]
  },
  "habitSignals": {
    "likedThemeTokens": ["release", "checksum"],
    "dismissedThemeTokens": ["downloads-cleanup"],
    "preferredNodeKinds": ["archiveEntry", "task"]
  },
  "omissions": [
    {"type":"encrypted_entry_names","policy":"never_included"},
    {"type":"passwords","policy":"never_included"}
  ]
}
```

主题推荐输出：

```json
{
  "schema": "simplezip.ai.workspaceTheme.output.v1",
  "themes": [
    {
      "title": "SIZ/SZS 测试工作区",
      "prompt": "把当前文件夹里和 SIZ/SZS 测试相关的归档、签名文件、测试任务、归档内部 metadata.json 放在一起。",
      "reason": "当前目录名和可见扩展都集中在 siz/szs 测试，且附近有 gpg 和 zip 文件。",
      "themeTokens": ["siz", "szs", "test", "signature"],
      "confidence": 0.9
    }
  ]
}
```

工作区内容输入：

```json
{
  "schema": "simplezip.ai.workspaceTree.input.v1",
  "purpose": "build_ai_virtual_folder_tree",
  "workspace": {
    "origin": "userCreated",
    "title": "SIZ/SZS 测试工作区",
    "prompt": "把当前文件夹里和 SIZ/SZS 测试相关的归档、签名文件、测试任务、归档内部 metadata.json 放在一起。"
  },
  "currentContext": {
    "mode": "folder",
    "displayName": "siz 及 szs 测试文件",
    "locationKind": "desktop",
    "selectedNames": ["2.zip"]
  },
  "activitySummary": {
    "taskCount": 120,
    "failedUnseenCount": 4,
    "recentFailureTags": ["checksum-mismatch", "missing-volume"],
    "recentTasks": [
      {"id":"task-7B2F","kind":"test","source":"cli","status":"failed","title":"Test release.7z","tags":["checksum-mismatch"]},
      {"id":"task-91AA","kind":"extract","source":"finder","status":"failed","title":"Extract mods.zip","tags":["missing-volume"]}
    ]
  },
  "archiveCacheSummary": {
    "archiveCount": 34,
    "likelyRelevantArchives": [
      {"archiveID":"archive-13F0","name":"SimpleZip-source.zip","tags":["source-code","documentation"],"samplePaths":["Package.swift","README.md"]},
      {"archiveID":"archive-883A","name":"release-assets.7z","tags":["release-artifact"],"samplePaths":["SHA256SUMS","SimpleZip.app"]}
    ]
  },
  "habitHints": [
    "The user often extracts Finder-launched zip archives.",
    "For create tasks, the user often enables exclude-junk and test-after-create."
  ],
  "omissions": [
    {"type":"encrypted_entry_names","policy":"never_included"},
    {"type":"raw_logs","policy":"error_lines_only"},
    {"type":"full_history","policy":"summarized_and_budgeted"}
  ]
}
```

AI 输出也必须结构化，且只引用 App 给它的 source id。输出应该是树，不是扁平列表：

```json
{
  "schema": "simplezip.ai.workspaceTree.output.v1",
  "root": {
    "title": "SIZ/SZS 测试工作区",
    "children": [
      {
        "kind": "group",
        "title": "当前目录文件",
        "children": [
          {
            "kind": "archive",
            "title": "2.zip",
            "reason": "当前选中的 zip，可能是对照测试样本。",
            "sourceRefs": [{"type":"archive","id":"archive-2zip"}],
            "primaryAction": {"type":"openArchive","archiveID":"archive-2zip"}
          }
        ]
      },
      {
        "kind": "group",
        "title": "归档内关键文件",
        "children": [
          {
            "kind": "archiveEntry",
            "title": "metadata.json",
            "subtitle": "Desktop.szs 内部条目",
            "sourceRefs": [{"type":"archiveEntry","id":"entry-desktop-szs-metadata"}],
            "primaryAction": {"type":"openArchive","archiveID":"archive-desktop-szs","revealEntry":"metadata.json"}
          }
        ]
      }
    ]
  }
}
```

旧的固定文件夹输出仍可作为兼容层：

```json
{
  "schema": "simplezip.ai.suggestions.output.v1",
  "folders": [
    {
      "id": "needsAttention",
      "items": [
        {
          "title": "release.7z 校验失败",
          "subtitle": "CLI · 今天 · Data Error",
          "reason": "最近失败任务里有 checksum-mismatch 标签，且还未查看。",
          "kind": "task",
          "confidence": 0.92,
          "sourceRefs": [{"type":"task","id":"task-7B2F"}],
          "primaryAction": {"type":"openTask","id":"task-7B2F"}
        }
      ]
    }
  ]
}
```

App 接到输出后必须校验：

- `sourceRefs` 必须存在于输入候选集。
- `primaryAction` 必须能由 source ref 推导出来，不能让 AI 发明路径。
- `archiveEntry` 必须来自非加密清单缓存，并且 entry id 能回查到 archive id 和 entry path。
- 标题和理由可以来自 AI，但实际打开路径、任务 id、搜索 query 由 App 构造或校验。
- 输出超预算时丢弃低置信度项。

### 生成方式

建议不要每次点侧边栏都跑模型。做两层：

1. **确定性建议生成器**：不依赖 AI，先从活动中心和缓存生成基础建议，例如失败任务、未查看失败、可继续发布助手、最近相关归档。
2. **AI 整理器**：在空闲时或用户手动刷新时，把基础建议重新排序、合并成虚拟文件夹、写理由。

```swift
enum AISuggestionEngine {
    static func deterministicCandidates(context: AISuggestionContext) -> [AISuggestionCandidate]
    static func buildPromptDataset(candidates: [AISuggestionCandidate], habits: AIHabitSummary?) -> AIContextEnvelope
    static func merge(aiOutput: AISuggestionPlan, candidates: [AISuggestionCandidate]) -> AISuggestionFolderSet
}
```

模型不可用时，`AI 文件夹` 仍然显示确定性建议，只是少了 AI 理由和排序。

工作区版本可以拆成两个服务：

```swift
enum AIWorkspaceThemeEngine {
    static func deterministicThemes(context: AIWorkspaceThemeContext) -> [AIWorkspaceThemeCandidate]
    static func buildPromptDataset(candidates: [AIWorkspaceThemeCandidate], feedback: AIWorkspaceFeedbackSummary) -> AIContextEnvelope
    static func merge(aiOutput: AIWorkspaceThemePlan, candidates: [AIWorkspaceThemeCandidate]) -> [AIWorkspace]
}

enum AIVirtualFolderTreeEngine {
    static func deterministicNodes(workspace: AIWorkspace, context: AIVirtualFolderContext) -> [AIVirtualNodeCandidate]
    static func buildPromptDataset(workspace: AIWorkspace, candidates: [AIVirtualNodeCandidate]) -> AIContextEnvelope
    static func merge(aiOutput: AIVirtualTreePlan, candidates: [AIVirtualNodeCandidate]) -> AIVirtualFolderTree
}
```

这样推荐主题和工作区内容分离：用户点 `x` 只影响主题推荐，不会删除真实历史；用户打开工作区后生成的树也可以独立缓存和刷新。

### 刷新策略

- 点击 `AI 文件夹`：立即显示上次缓存结果，后台检查是否过期。
- 点击某个 AI 工作区：立即显示上次虚拟树，后台检查该工作区是否需要刷新。
- 任务完成、归档缓存更新、习惯摘要更新：标记建议过期，不立刻跑模型。
- App 空闲且 AI 可用：最多每 30-60 分钟刷新一次。
- 用户手动点刷新：立即重新生成。
- 用户点推荐主题右侧 `x`：立即隐藏该推荐，不跑模型；负反馈进入下一次主题推荐输入。
- 每次生成限制候选数量，例如任务 50 条、归档 30 个、报告 20 个。

### UI 施工建议

第一版尽量小：

- 在 `Sidebar` 里新增一个 AI section，用 `AIGate` 或 AI 主开关控制显示。
- `Sidebar` 的 AI section 顶部新增 `生成新的工作区...` 行。
- `ArchiveBrowserModel` 增加 `openAIWorkspace(_:)`、`createAIWorkspace(prompt:)`、`dismissRecommendedAIWorkspace(_:)`。
- `BrowserMode` 增加 `.aiWorkspace(UUID)`。
- `ContentView` 增加 `AISuggestionFolderView(model:)` 分支。
- `AISuggestionFolderView` 用普通 SwiftUI `OutlineGroup`、`List` 或 `Table` 表达虚拟树，支持虚拟折叠，不要复用 `FileTable`。
- 行动作用图标按钮：打开任务、打开归档、应用搜索、解释失败、生成自动化草稿。
- 推荐工作区行右侧显示小 `x` 按钮；右键菜单提供 `不感兴趣`、`固定为工作区`。
- 用户工作区右键菜单提供 `刷新`、`重命名`、`删除`。
- 系统工作区右键菜单提供 `隐藏`、`刷新`。
- 空状态显示“没有需要处理的建议”，并提供刷新按钮。

需要本地化：

- `sidebar.ai.section`
- `sidebar.ai.createWorkspace`
- `sidebar.ai.recommendedWorkspace`
- `sidebar.ai.dismissRecommended`
- `sidebar.ai.pinWorkspace`
- `sidebar.ai.deleteWorkspace`
- `sidebar.ai.hideWorkspace`
- `sidebar.ai.renameWorkspace`
- `aiFolder.title`
- `aiFolder.needsAttention`
- `aiFolder.likelyOpen`
- `aiFolder.insideArchives`
- `aiFolder.releaseAndVerify`
- `aiFolder.cleanup`
- `aiFolder.automation`
- `aiFolder.refresh`
- `aiFolder.lastUpdated`
- `aiFolder.noSuggestions`
- `aiWorkspace.create.title`
- `aiWorkspace.create.prompt`
- `aiWorkspace.create.emptyPromptHint`
- `aiWorkspace.tree.archiveEntries`
- `aiWorkspace.tree.relatedTasks`
- `aiWorkspace.tree.reports`

### 动作边界

AI 文件夹里的动作分三级：

- 直接安全动作：打开活动中心任务、打开归档、打开文件夹、应用只读搜索、打开报告。
- 需要确认动作：重新测试、重新运行、创建 Shortcut 草稿、生成 VERIFY.md 草稿。
- 禁止动作：删除、移动、覆盖、解压到目标、修改权限、导入密钥、信任签名、解密、自动发送文件。

这能让 AI 变成“主动整理入口”，但不越过 SimpleZip 的安全边界。

### 分期实现

第一期：无模型也可用。

- 侧边栏加 `AI` section 和系统工作区。
- 新增 `.aiWorkspace(UUID)` 模式和 `AISuggestionFolderView`。
- 只显示确定性虚拟树：未查看失败、可继续任务、最近报告、归档缓存里的可能相关包。
- 不接 AI 生成，不接习惯摘要。

第二期：接入 AI 整理。

- 将确定性候选格式化成 `simplezip.ai.workspaceTree.input.v1`。
- AI 输出结构化 `AIVirtualTreePlan`。
- App 校验 source refs 后落成 `AIVirtualFolderTree`。
- 加手动刷新和缓存。

第三期：接入习惯小上下文。

- `AIHabitSummaryStore.promptHints` 加入建议输入。
- 生成自动化建议、常用工作流建议。
- 让创建/解压建议也能跳转回 `AI 文件夹` 的相关分组。

第四期：工作区创建和推荐主题。

- 支持 `生成新的工作区...` sheet。
- 支持用户输入 prompt 创建持久工作区。
- 支持用户不输入 prompt 时，从推荐主题中生成临时工作区。
- 支持后台推荐主题，并在侧边栏显示可关闭的推荐工作区。
- 支持推荐主题的 `x` 负反馈。

第五期：更像 Finder 智能文件夹。

- 支持用户保存一个 AI 推荐主题为固定虚拟文件夹。
- 支持“把这个建议隐藏/不再提示”。
- 支持从建议行打开对应的活动中心筛选或归档搜索。
- 支持虚拟树内的折叠状态记忆、排序记忆和工作区右键管理。

## 建议五：活动中心 AI 侧边栏 / AI 工作台

活动中心里的 AI 不应该只是工具栏上一个“AI 筛选”按钮和 popover。活动中心本身就是任务、日志、来源、报告、失败和重跑动作的汇总点，AI 应该升级成活动中心内部的一个强侧边栏或右侧工作台，持续展示“现在最值得处理什么”和“为什么”。

### 目标

- 把 AI 从附属按钮升级成活动中心的常驻分析面板。
- 用户不需要先想好筛选语句，AI 主动给出可点的任务分组、失败解释、重跑建议和自动化建议。
- 仍然不让 AI 执行动作。AI 只整理、解释、排序；App 执行打开任务、应用筛选、打开报告、重跑确认等安全动作。

### UI 形态

建议活动中心窗口保留左侧原有 pane：归档、文件操作、撤销重做、工作区、设置、帮助。右侧内容区再增加一个可折叠 AI 侧栏，或者在侧栏里新增顶层 `AI` pane。

更推荐第一版使用右侧 AI 工作台：

```text
┌ Activity Center ─────────────────────────────────────────────┐
│ 左侧分类 │ 任务列表 / 设置 / 工作区              │ AI 工作台 │
│          │                                       │          │
│ 归档     │ 任务卡片                              │ 需要处理 │
│ 文件操作 │                                       │ 失败模式 │
│ 撤销重做 │                                       │ 建议筛选 │
│ 工作区   │                                       │ 自动化   │
└──────────────────────────────────────────────────────────────┘
```

这样用户看任务列表时，AI 侧栏始终可以引用当前 pane、当前筛选、当前任务选中项。它不是弹出来的小功能，而是活动中心的“解读层”。

### AI 工作台内容

建议分成几个固定模块，每个模块都由结构化 facts 驱动：

- `需要处理`：未查看失败、可继续发布助手、缺卷、checksum mismatch、签名/校验材料缺失、工作区临时文件过多。
- `当前列表总结`：当前 pane 里任务状态分布、最近失败原因、最长任务、重复失败路径。
- `建议筛选`：给出可点的自然语言筛选 chip，例如“今天 Finder 失败”“缺少分卷”“Downloads 的 zip 解压”。
- `失败解释`：选中失败任务时，展示短解释和“打开完整 AI 解释”按钮。
- `下一步动作`：打开报告、重新测试、从失败步继续、复制诊断、打开输出文件夹。
- `学习到的习惯`：最近常用来源/格式/目录模式，但只展示摘要，不展示敏感完整路径。
- `自动化建议`：当重复行为稳定出现时，建议创建 Shortcuts 或 CLI 工作流。

### 数据输入

AI 工作台每次刷新不需要读取全部历史。建议输入当前视图摘要 + 候选任务：

```json
{
  "schema": "simplezip.ai.activitySidebar.input.v1",
  "selectedPane": "archive",
  "activeFilters": {
    "status": "all",
    "source": "any",
    "aiQuery": null
  },
  "visibleTaskSummary": {
    "count": 84,
    "running": 2,
    "failedUnseen": 3,
    "failedSeen": 9,
    "cancelled": 4,
    "succeeded": 66
  },
  "highValueTasks": [
    {
      "id": "task-7B2F",
      "kind": "test",
      "source": "cli",
      "status": "failed",
      "title": "Test release.7z",
      "startedAtWindow": "today",
      "diagnosticTags": ["checksum-mismatch"],
      "actionsAvailable": ["openTask", "explainFailure", "rerun"]
    },
    {
      "id": "task-91AA",
      "kind": "extract",
      "source": "finder",
      "status": "failed",
      "title": "Extract mods.zip",
      "locationKinds": ["downloads"],
      "diagnosticTags": ["missing-volume"],
      "actionsAvailable": ["openTask", "copyDiagnostics"]
    }
  ],
  "habitHints": [
    "The user often launches zip extraction from Finder.",
    "Recent archive failures are often missing split volumes."
  ],
  "omissions": [
    {"type":"raw_logs","policy":"error_lines_only"},
    {"type":"encrypted_entry_names","policy":"never_included"}
  ]
}
```

AI 输出：

```json
{
  "schema": "simplezip.ai.activitySidebar.output.v1",
  "cards": [
    {
      "kind": "needsAttention",
      "title": "两个失败任务值得先看",
      "body": "一个是校验失败，一个是缺少分卷，来源分别是 CLI 和 Finder。",
      "sourceRefs": [{"type":"task","id":"task-7B2F"}, {"type":"task","id":"task-91AA"}],
      "actions": [
        {"type":"applyFilter","label":"只看今天失败", "filter":{"status":"failed","timeWindow":"today"}},
        {"type":"openTask","taskID":"task-7B2F"}
      ]
    }
  ],
  "filterChips": [
    {"label":"今天失败", "filter":{"status":"failed","timeWindow":"today"}},
    {"label":"缺少分卷", "filter":{"diagnosticTags":["missing-volume"]}},
    {"label":"Finder 解压失败", "filter":{"source":"finder","kind":"extract","status":"failed"}}
  ]
}
```

App 必须校验所有 task id 和 filter token。AI 不能生成任意 Swift action。

### 刷新和性能

- 活动中心打开时先显示确定性卡片。
- AI 主开关开启且模型可用时，后台生成更好的排序和文案。
- 任务完成、失败、用户切 pane、用户点某任务时，只标记“AI 工作台过期”，不要每次都跑模型。
- 最短刷新间隔建议 5-10 分钟；选中失败任务时可单独局部刷新失败解释。
- `AIGenerationSerializer` 仍然串行，避免 FoundationModels 重叠调用。

### 施工建议

- 新增 `ActivityAIWorkbenchView`，挂在 `ActivityView` 的内容区右侧。
- 新增 `ActivityAIWorkbenchModel` 或轻量 `@State` + service，不要把大量刷新状态塞进 `ArchiveBrowserModel`。
- 新增 `ActivityAIContextBuilder`，从 `TaskCenter.active/history` 和当前 pane/filter 生成输入 JSON。
- 新增 `ActivityAIWorkbenchCard` 纯值模型。
- `AI 筛选`按钮不删除，降级为 AI 工作台里的“输入一句话生成筛选”入口。
- 工作台可以折叠，避免窄窗口挤压任务列表。

## 建议六：动态动作推荐引擎，替换固定双按钮

截图里的工具栏推荐现在来自 `ContextualToolbarButtons`。代码里单归档就是固定“转换格式 + 发布包检查”，多归档就是固定“批量测试 + 比较/转换”，分卷就是固定“合并 + 比较”。这比完全静态菜单好，但仍然很机械：它不知道这个文件夹是不是发布目录，不知道用户在这个路径下常做什么，也不知道用户上次点了哪个推荐后成功或失败。

建议把这层升级成动态动作推荐引擎：候选动作仍由 App 安全枚举，排序和解释可以由使用历史、当前上下文和 AI 共同决定。

### 核心原则

- App 生成“可执行候选动作”，AI 不能发明动作。
- 学习系统只影响排序、显隐和理由，不绕过确认 sheet。
- 文件夹地址要进入特征，但默认用位置类别和路径哈希，避免长期保存完整敏感路径。
- 用户用得越多，推荐越贴合：点击、忽略、取消、成功、失败都反馈给排序。

### 当前固定规则如何迁移

现有 `ContextualToolbarButtons` 的硬编码分支可以拆成两步：

1. `ContextualActionCandidateProvider` 根据当前 selection 生成候选动作。
2. `ContextualActionRanker` 根据上下文特征、用户历史和 AI hints 排序，选前 2-3 个显示在工具栏，其余放进菜单。

```swift
struct ContextualActionCandidate: Identifiable, Codable, Equatable {
    enum ID: String, Codable {
        case convertArchive
        case inspectRelease
        case batchTest
        case compareArchives
        case combineVolumes
        case browseSZS
        case encryptGPG
        case createSignedManifest
        case batchRename
        case duplicate
        case split
        case newFolder
        case paste
    }

    let id: ID
    let titleKey: String
    let systemImage: String
    let safety: AISuggestionSafety
    let requiredSelectionShape: SelectionShape
}
```

候选 provider 仍然确定性：

- 单个支持归档：`convertArchive`、`inspectRelease`、`testArchive`、`openActivityReport`。
- 两个归档：`compareArchives`、`batchTest`、`convertArchive`。
- 多个归档：`batchTest`、`convertArchive`。
- 分卷：`combineVolumes`、`testArchive`、`compareArchives`。
- `.szs`：`browseSZS`、`compareWithFolder`。
- 普通文件且 GPG 开：`encryptGPG`、`createSignedManifest`。
- 文件夹：`createArchive`、`createSignedManifest`、`releaseAssistant`、`hash`。

ranker 决定显示哪个。

### 上下文特征

动态推荐必须考虑比“选中了 zip”更多的特征：

```json
{
  "schema": "simplezip.ai.actionContext.v1",
  "selection": {
    "count": 1,
    "items": [
      {
        "displayName": "2.zip",
        "extension": "zip",
        "kind": "archive",
        "byteSize": 192,
        "isDirectory": false,
        "isPackage": false
      }
    ],
    "shape": "single_archive"
  },
  "location": {
    "kind": "desktop",
    "pathHash": "loc-9d1a",
    "folderNameTokens": ["siz", "szs", "测试文件"],
    "containsReleaseMarkers": true,
    "containsChecksumFiles": false,
    "containsSignatureFiles": true,
    "containsManyArchives": true
  },
  "recentLocalHistory": {
    "sameFolderActions": [
      {"action":"inspectRelease","count":8,"successRate":0.88},
      {"action":"convertArchive","count":2,"successRate":1.0}
    ],
    "sameExtensionActions": [
      {"action":"inspectRelease","count":20,"successRate":0.9},
      {"action":"extract","count":11,"successRate":0.95}
    ],
    "ignoredActions": [
      {"action":"convertArchive","count":6}
    ]
  },
  "habitHints": [
    "In folders whose names mention siz/szs, the user often runs release or signature checks.",
    "For tiny zip files in test folders, inspectRelease has been chosen more often than convertArchive."
  ],
  "candidateActions": [
    {"id":"convertArchive","safe":true},
    {"id":"inspectRelease","safe":true},
    {"id":"testArchive","safe":true}
  ]
}
```

文件夹地址不只是“路径字符串”。建议拆成：

- `location.kind`：Downloads、Desktop、Documents、external-drive、project-folder、temporary-workspace、same-directory。
- `pathHash`：同一文件夹稳定识别，用于学习，不暴露完整路径。
- `folderNameTokens`：目录名 token，可帮助识别 `release`、`test`、`backup`、`siz/szs` 等工作场景。
- `containsReleaseMarkers`：是否有 README、CHANGELOG、SHA256SUMS、.szs、.asc、.app、.dmg 等。
- `containsManyArchives`：是否是归档测试/转换目录。
- `sameFolderActions`：这个目录下历史上用户点过什么。

这样 AI 才能理解“在这个测试文件夹里选 zip，发布包检查比转换更可能有用”，而不是永远固定两个按钮。

### 学习数据怎么记录

新增 `ContextualActionUsageStore`，只记录动作反馈，不记录敏感内容。

```swift
struct ContextualActionEvent: Codable {
    enum Outcome: String, Codable {
        case shown
        case clicked
        case dismissed
        case cancelledInSheet
        case completed
        case failed
    }

    let actionID: ContextualActionCandidate.ID
    let outcome: Outcome
    let timestamp: Date
    let selectionShape: SelectionShape
    let extensions: [String]
    let locationKind: LocationKind
    let pathHash: String?
    let folderNameTokens: [String]
    let taskKind: OperationTask.Kind?
    let diagnosticTags: [String]
}
```

反馈口径：

- `shown`：动作被推荐展示。
- `clicked`：用户点了。
- `cancelledInSheet`：打开了确认 sheet 但取消。
- `completed`：对应活动中心任务成功或跳过。
- `failed`：对应任务失败，并带失败标签。
- `dismissed`：用户主动隐藏/不再推荐。

排序时优先考虑：

- 同目录 `pathHash` 下用户最近点击/完成过的动作。
- 同扩展名/同 selection shape 的成功率。
- 用户多次忽略的动作降权。
- 最近失败的动作降权，除非失败是可解释的外部原因。
- 当前文件夹 markers，例如发布目录、测试目录、分卷目录。

### AI 在这里做什么

第一版可以不用 AI 排序，先用统计分数。AI 加入后只做两件事：

- 给推荐写人话理由。
- 在候选动作分数接近时，根据上下文 facts 选择排序。

AI 输出仍然结构化：

```json
{
  "schema": "simplezip.ai.actionRank.output.v1",
  "rankedActions": [
    {
      "id": "inspectRelease",
      "reason": "这个文件夹包含 .siz/.szs 测试文件，且你最近在同类目录里更常做发布包检查。",
      "confidence": 0.86
    },
    {
      "id": "convertArchive",
      "reason": "这是 zip 归档，转换仍是可用动作，但你在此目录较少使用。",
      "confidence": 0.41
    }
  ]
}
```

App 只接受 `candidateActions` 中存在的 id。AI 排序失败就回退到统计排序，再回退到当前硬编码顺序。

### UI 建议

工具栏不应无限多按钮。建议：

- 前 2 个高分动作仍显示成工具栏图标按钮。
- 第 3 个以后放入一个 `sparkles` 或 `ellipsis.circle` 菜单。
- hover/help 显示推荐理由，例如“因为这个文件夹最近常做发布检查”。
- 用户可以在菜单里点“不再优先推荐这个动作”，写入 `dismissed`。
- 活动中心 AI 工作台里显示“为什么推荐这个动作”的更详细解释。

截图里的例子可以变成：

- 如果当前文件夹名含 `siz/szs`，目录里有 `.siz` / `.szs` / `.gpg`，且用户最近在这里常跑发布检查：工具栏第一推荐 `发布包检查`。
- 如果用户在这个目录几乎不转换 zip，`转换格式` 降为第二或菜单项。
- 如果上次对同类 tiny zip 做发布检查成功，继续提高发布检查权重。
- 如果用户连续 5 次忽略 `转换格式`，它不再固定占第一个位置。

### 施工顺序

第一期：不接 AI，只拆硬编码。

- 新增 `ContextualActionCandidateProvider`。
- 新增 `ContextualActionRanker`，用当前硬编码顺序作为默认分数。
- `ContextualToolbarButtons` 改为渲染 ranker 前 2 个动作。
- 行为保持不变。

第二期：记录反馈。

- 新增 `ContextualActionUsageStore`。
- 记录 shown/clicked/cancelled/completed/failed。
- 活动中心任务完成后把 outcome 回填到触发它的 action event。
- 排序加入同目录、同扩展名、同 selection shape 的统计。

第三期：引入文件夹地址和场景识别。

- 新增 `LocationKind`、`pathHash`、`folderNameTokens`、`folderMarkers`。
- 让发布目录、测试目录、分卷目录、归档缓存目录影响推荐。
- 设置里提供“清空动态推荐学习数据”。

第四期：AI 排序和理由。

- 将候选动作 + 统计特征格式化成 `simplezip.ai.actionContext.v1`。
- AI 输出 `rankedActions` 和 reason。
- 工具栏 help / AI 工作台显示理由。
- 失败时回退统计排序。

## 建议七：活动中心 AI 筛选 v2

这是优先级最高的改进。

### 当前问题

活动中心现有 `ActivityFilterSpec` 只表达：

- 状态；
- 来源；
- 操作类型；
- 格式；
- 文件名关键词；
- 时间窗。

`filteredTasks(in:)` 在 AI 筛选生效时主要匹配：

- `task.status`；
- `task.source`；
- `task.kind`；
- `task.title`；
- `task.detail`；
- `task.startedAt`。

这导致用户说“找那个校验失败、日志里像权限问题、输出到 Downloads 的 zip”时，AI 即使理解了意思，也没有足够数据可匹配。它看不到命令输出、失败类型、耗时、产物、报告、hash/diff/transferLog、重试能力等。

### 活动中心任务索引

为每条 `OperationTask` 构建一个只读 AI 索引文档，运行中任务和历史任务都可以生成。

建议字段：

- 基础字段：id、category、kind、source、title、detail、status、failureMessage、startedAt、finishedAt、duration。
- 路径字段：archivePath、inputPaths、outputPaths、destinationPath、displayNames、extensions、parentDirectories。
- 后端字段：安全清洗后的命令名称、参数摘要、后端类型、退出原因、错误行、日志尾部、日志关键词。
- 进度字段：fraction、currentFile、statusText、completed/total、是否等待并发槽、是否暂停、是否在写锁等待。
- 结果字段：succeeded/skipped/failed/cancelled、产物 URL、跳过原因、可重跑、可带修改重跑、可从失败步继续。
- 报告字段：hashReport 摘要、diffReport 摘要、reportAttachment 类型和关键 finding、transferLog 统计、hashComparisons 统计。
- 诊断标签：permission-denied、missing-volume、needs-password、corrupt-archive、unsupported-format、disk-space、destination-conflict、signature-problem、checksum-mismatch、cancelled-by-user、interrupted-previous-session。
- UI 不直接展示但对 AI 有用的字段：operationID、写锁 holder/waiter 关系、失败是否已看过、历史是否来自 CLI/Shortcuts/URL/Finder、Spotlight 可定位 id。

这份索引不需要全部展示给用户，但 AI 筛选和解释应该可以读取。

### 筛选流程

建议从当前“AI 输出过滤规格，Swift 确定性匹配”的方向升级，而不是让 AI 直接选任务。

流程：

1. 用户输入自然语言。
2. AI 输出 `ActivityFilterSpecV2`，字段更丰富：
   - status、source、kind、category；
   - fileName、pathNeedles、format；
   - timeWindow、durationWindow；
   - failureReason、diagnosticTags；
   - reportType、riskTag、resultTag；
   - locationKind，例如 Downloads、Desktop、external drive、temporary workspace；
   - sortHint，例如 newest、failed first、longest、largest output。
3. App 用 `ActivityTaskAIIndex` 先做确定性候选筛选。
4. 如果候选很多，再把候选摘要交给 AI 做排序或解释，但最终仍返回 task id 列表，App 校验 id 存在且符合候选范围。
5. UI 展示“AI 筛选：原句”，并可展开查看命中的条件摘要，方便用户知道为什么命中。

### 数据量提升方式

活动中心不应该只给 AI 一句 query。应该给它一个受控 catalog：

- 当前 pane 的任务总数、状态分布、来源分布、时间范围。
- 最近 N 条任务的索引摘要。
- 如果用户 query 里出现具体词，先由 App 在本地全量索引里召回候选，再把候选交给 AI。
- 对失败查询，附带失败消息和日志错误行摘要。
- 对报告查询，附带报告类型和 finding 摘要。

这样数据量可以比现在大很多，但仍可控，不会把 500 条完整日志一次塞进模型。

### 用户能得到的实际能力

升级后活动中心应该能处理：

- “找今天从 Finder 启动、失败的解压任务”
- “找上次那个权限失败的 zip”
- “找输出到 Downloads 的转换任务”
- “找等写锁等很久的任务”
- “找带 checksum mismatch 的发布检查”
- “找有覆盖冲突但最后跳过的文件操作”
- “找 CLI 里失败的校验任务”
- “找耗时最长的创建档案”
- “找报告里提到 __MACOSX 的任务”

这些都不是单靠 title/detail 能稳定做到的。

## 建议八：让活动中心成为 AI 的全局事实入口

活动中心已经汇总 app、CLI、Shortcuts、URL scheme、Finder 来源，是最适合做 AI 全局事实入口的地方。建议把它从“任务列表 UI”升级成“任务事实数据库的可视化前端”。

可新增只读查询能力：

- `TaskCenter.aiSnapshot()`：返回 active + history 的 AI 索引摘要。
- `ActivityHistoryStore.richSnapshot()`：从持久化历史读取比 `ArchiveTaskSnapshot` 更完整的数据，包括 details、hash/diff/report/transferLog 的摘要。
- `ActivityDiagnosticsClassifier`：把 rawOutput、failureMessage、statusText 分类成诊断标签。
- `TaskReportSummarizer`：把不同报告附件统一成简短事实行，供 AI 筛选和解释共用。

这样后续设置里的“自动化建议”、失败解释、报告解释、Spotlight/Shortcuts 查询都能复用同一批事实，而不是各自重新发明。

## 建议九：归档查找 AI 升级

`ArchiveFinderSheet` 当前只让 AI 抽关键词，然后在 `ArchiveListingCacheStore` 的非加密条目名里做子串搜索。这个实现安全，但召回能力偏弱。

建议把它升级成“归档记忆搜索”，而不是“关键词搜索框”。用户问的往往不是精确文件名，而是：

- “我那个 README 在哪个源码包里？”
- “哪个包里有签名文件和校验文件？”
- “上次那个带 Localizable.strings 的包在哪？”
- “有没有哪个归档像 release artifact？”
- “找含配置文件和脚本的备份包”

这些问题需要 AI 看到每个缓存归档的结构摘要、文件类型分布、样本路径、记录时间和上下文，而不是只看到一个关键词。

### 数据扩展

建议升级 `ArchiveListingCacheEntry` 的派生 AI 摘要：

- 顶层目录样本；
- 文件扩展名分布；
- 大文件样本；
- 文件类型标签：source-code、document、image、video、config、license、script、secret-looking-name；
- macOS 痕迹：`__MACOSX`、AppleDouble、bundle/package；
- 压缩包自身大小、修改时间、记录时间；
- 是否截断、总条目数、加密条目计数。
- 打开来源和最近任务关系：这个归档最近是否被测试、转换、发布检查、解压失败。
- 目录上下文：归档所在目录的 `locationKind`、`pathHash`、`folderNameTokens`。
- 语义标签：release-artifact、source-archive、backup、installer、signed-container-related、test-fixture、localized-app。
- 重要文件 markers：README、LICENSE、Package.swift、pyproject.toml、package.json、SHA256SUMS、.asc、.szs、.app、.dmg。

### 归档记忆索引

建议新增只读派生索引 `ArchiveMemoryIndex`。它不替代 `ArchiveListingCacheStore`，而是从缓存清单、活动中心和报告附件派生更适合 AI/搜索的数据。

```swift
struct ArchiveMemoryRecord: Codable, Identifiable, Equatable {
    let id: String
    let archivePath: String
    let archiveName: String
    let archiveExtension: String
    let location: AILocationContext
    let recordedAt: Date
    let archiveByteSize: Int64?
    let entryStats: EntryStats
    let structure: StructureSummary
    let fileTypes: [FileTypeBucket]
    let semanticTags: [String]
    let markerFiles: [String]
    let samplePaths: [String]
    let largestFiles: [FileSample]
    let relatedTasks: [AIContextSourceRef]
    let omissions: [AIContextOmission]
}
```

`ArchiveMemoryRecord` 可以比 UI 显示更多数据，但仍然只来自非加密条目。加密条目只保留计数和 omitted 说明。

### 查询流程

搜索流程升级：

1. AI 把用户问题转成 `ArchiveSearchIntent`。
2. App 根据 intent 做本地召回：关键词、扩展名、marker、semanticTags、路径 token、最近任务关系。
3. 对召回候选生成短 JSONL。
4. AI 对候选排序并给理由。
5. App 展示归档分组、命中样本、理由和动作。

`ArchiveSearchIntent` 建议字段：

```swift
struct ArchiveSearchIntent: Codable, Equatable {
    let keywords: [String]
    let fileNames: [String]
    let extensions: [String]
    let semanticTags: [String]
    let markerFiles: [String]
    let locationKinds: [String]
    let timeWindow: String?
    let sizeHint: String?
    let relatedTaskTags: [String]
    let sortHint: String?
}
```

候选 JSONL 示例：

```jsonl
{"archiveID":"archive-13F0","name":"SimpleZip-source.zip","tags":["source-archive","localized-app"],"markers":["Package.swift","README.md","LICENSE"],"extensions":[{"ext":"swift","count":420},{"ext":"strings","count":12}],"samplePaths":["SimpleZip/App/SimpleZipApp.swift","SimpleZip/zh-Hans.lproj/Localizable.strings"],"location":{"kind":"projects","folderNameTokens":["simplezip"]}}
{"archiveID":"archive-883A","name":"release-assets.7z","tags":["release-artifact"],"markers":["SHA256SUMS","SimpleZip.app"],"extensions":[{"ext":"app","count":1},{"ext":"dmg","count":1}],"samplePaths":["SHA256SUMS","SimpleZip.app"],"relatedTasks":["task-7B2F"]}
```

AI 输出示例：

```json
{
  "matches": [
    {
      "archiveID": "archive-13F0",
      "reason": "这个归档同时命中 Package.swift、Swift 文件和本地化 strings，更像你说的源码包。",
      "matchedSignals": ["Package.swift", "swift×420", "Localizable.strings"],
      "confidence": 0.91
    }
  ]
}
```

注意：仍然只缓存和搜索非加密条目。加密条目只允许用计数参与提示，例如“这个归档还有 12 个加密条目未索引”，不能暴露名字。

### UI 升级

`ArchiveFinderSheet` 可以从简单 sheet 升级为“归档记忆查找”：

- 输入框仍保留一句话查询。
- 结果按归档分组，每组显示 AI 理由、命中信号、样本路径。
- 结果行动作：打开归档、在归档内应用搜索、打开所在文件夹、从活动中心看相关任务。
- 显示索引健康信息：缓存归档数、截断数量、加密省略数量、TTL。
- 没命中时给建议：打开更多归档以建立索引、放宽缓存 TTL、检查归档清单缓存是否开启。

### 数据不应过度保守

这里建议比现在更大胆：

- 非加密条目名、扩展名分布、顶层结构、marker 文件应该完整进入本机索引。
- 单包最多 10,000 条当前已有上限可以保留，但 AI 摘要应派生 top-level、extension、markers，而不只是原始 entry list。
- 归档所在目录的类别和目录名 token 应可用于搜索，例如 release/test/backup/project。
- 与活动中心任务的关系应可用于排序，例如“最近测试失败的那个包”。

只要不触碰加密条目名和内容，这些数据都应该可达。

## 建议十：创建/解压内联 AI 建议升级

现有 `createAdvisoryPrompt` 和 `extractAdvisoryPrompt` 已经比普通 UI 多喂了一些顶层样本和预检事实。可以继续加厚。

创建对话框可给 AI 的非敏感事实：

- 输入项扩展名分布；
- 已压缩媒体比例；
- 最大文件样本；
- package/bundle 数量和名字样本；
- 符号链接数量和外链风险摘要；
- 目标磁盘剩余空间；
- 输出目录已有同名文件的冲突事实；
- 用户最近对同类格式常用的压缩级别和排除规则；
- 是否启用 reproducible、exclude junk、split volume、test after create；
- 预计分卷数、估算压缩率来源。

解压对话框可给 AI 的事实：

- 顶层结构：单根目录、散落文件、多根目录；
- 可疑路径类型和样本；
- 会覆盖的文件数量、覆盖样本；
- 目标目录位置类型：Downloads、Desktop、外置盘、临时目录；
- 磁盘空间缺口；
- 缺卷、只读格式、symlink/hardlink、可执行内容、package/bundle；
- 解压选项当前值和可能影响。

目标是让 AI 给出真正有用的一句话，例如“这个包会把 30 多个文件直接散到 Downloads，建议先解到新文件夹”，而不是“请确认设置”。

## 建议十一：失败解释升级

失败解释现在只喂 `failureMessage` 和 `detailsSession.rawOutput` 尾部。建议增加结构化诊断上下文。

可加入：

- 操作类型、来源、输入/输出路径、目标目录是否存在；
- 安全清洗后的命令摘要；
- 后端版本；
- 退出码或错误类别；
- 文件系统现场：目标磁盘可写、剩余空间、目标是否只读、路径是否存在；
- 缺卷检测结果；
- 是否等待过写锁或并发槽；
- 任务持续时间；
- 最近相关任务：同一路径最近是否也失败、上一次是否成功。

同时先由确定性 `FailureClassifier` 输出标签，再让 AI 解释标签和日志。这样 AI 不需要从原始日志里猜“权限/缺卷/密码/损坏/磁盘空间”。

密码相关日志仍要过滤。即使后端通常不输出密码，也应该在进入 AI 前统一 redaction。

## 建议十二：报告解释统一升级

现在每个报告 prompt 都各自组装字符串。建议逐步收敛成统一模式：

- 每个报告类型提供 `makeAIContext()`，输出结构化 facts。
- `AIReportAssistant` 只负责把 facts 转成 prompt 和调用模型。
- 样本条目预算统一，例如每类 finding 默认 5 条，用户可在开发设置里调大。
- 每个 prompt 都包含“已省略内容”，例如“加密条目 18 个未提供给 AI”。
- 所有报告解释都引用确定性结果，不让 AI 重算风险等级、签名信任、校验结果。

重点报告可增强：

- 安全评分：给完整贡献因子、样本路径、目录结构上下文。
- 元数据：给压缩方法分布、权限分布、扩展名分布、顶层结构。
- 空间分析：给最大文件、最大目录、扩展名分布、压缩率异常项。
- 敏感文件名扫描：给分类样本、所在目录、是否和发布产物相关。
- 近似重复：给大小、CRC、路径相似度、版本词。
- 发布检查/目录审计：给每个 gate 的影响文件和阻断/警告级别。

## 建议十三：设置 AI 搜索升级

设置 AI 搜索现在给模型的是 setting id、标题、关键词。建议 catalog 增加：

- 当前值；
- 是否可切换；
- 是否安全开关；
- 依赖关系，例如 GPG 总开关影响哪些入口；
- 所在 pane、anchor、相关帮助链接；
- 同义词和用户常说法；
- 是否隐藏/开发者向。

这样用户说“别让它记住我打开过哪些压缩包”时，AI 能定位到归档清单缓存，而不只是按标题猜。

安全边界仍保留：只有 `SettingToggleRegistry` 明确登记的安全项才能由 AI 触发开关，其余只导航。

### 从搜索框升级成设置助手

现在的设置 AI 搜索更像“智能跳转”：用户问一句话，AI 从 `SettingsCatalog` 里挑一个 id。它应该升级成设置助手，理解设置之间的关系、当前状态、影响范围和用户目的。

目标：

- 能回答“为什么我找不到某个 AI/归档/Finder 功能”。
- 能定位到相关设置组，而不是只跳单个设置。
- 能解释当前值会影响哪些功能。
- 能给出安全的修改建议，但只有白名单 toggle 才能直接切换。

### 设置语义目录

建议新增 `SettingsAICatalog`，从 `SettingsCatalog` 派生，但比静态关键词更丰富：

```json
{
  "schema": "simplezip.ai.settingsCatalog.v1",
  "items": [
    {
      "id": "automation.archiveListingCache",
      "pane": "automation",
      "anchor": "archiveListingCache",
      "title": "归档清单缓存",
      "summary": "记录已打开归档的非加密条目名，用于 Spotlight、Siri 和 AI 查找哪个归档包含某个文件。",
      "currentValue": {
        "type": "toggle",
        "enabled": true
      },
      "safeToggle": true,
      "relatedFeatures": ["ArchiveFinderSheet", "Spotlight archive file search", "AI archive memory"],
      "privacyImpact": "Stores non-encrypted entry names locally. Encrypted entries are omitted.",
      "dependencies": ["automation.spotlightIndexing"],
      "userPhrases": [
        "别记住我打开过哪些压缩包",
        "哪个归档包含文件",
        "归档缓存",
        "Spotlight 找压缩包里的文件"
      ],
      "actions": ["navigate", "enable", "disable", "clearCache"]
    }
  ]
}
```

设置 AI 搜索应该给 AI：

- 设置 id、标题、摘要、关键词；
- 当前值；
- 是否可直接切换；
- 可执行安全动作；
- 依赖关系；
- 影响的功能；
- 隐私说明；
- 相关文档和 pane anchor；
- 典型用户说法。

这样用户说“AI 查不到归档里的文件是不是没开缓存”，AI 能定位到清单缓存、说明当前状态、提示缓存数量和 TTL，而不是只跳到自动化页。

### 设置搜索输出

输出不应该只是一个 setting id。建议变成：

```json
{
  "matches": [
    {
      "settingID": "automation.archiveListingCache",
      "confidence": 0.94,
      "reason": "用户问的是归档内文件查找，依赖归档清单缓存。",
      "recommendedIntent": "navigate"
    },
    {
      "settingID": "automation.spotlightIndexing",
      "confidence": 0.62,
      "reason": "如果用户也希望系统搜索里可见，需要 Spotlight 索引。"
    }
  ],
  "answer": "这个功能依赖归档清单缓存；它只记录非加密条目名，可以在自动化设置里查看、清空或关闭。",
  "safeActions": [
    {"type":"navigate","settingID":"automation.archiveListingCache"},
    {"type":"clearCache","settingID":"automation.archiveListingCache"}
  ]
}
```

UI 上可以显示：

- 最佳匹配设置；
- 相关设置；
- 当前值；
- 一句解释；
- 安全动作按钮：跳转、开启/关闭、清空缓存。

### 当前状态和数据量

设置搜索也不该过度保守。应该允许 AI 读取：

- 当前设置值；
- 缓存数量、缓存大小、TTL、上限；
- 是否已安装 CLI、Shortcuts/URL/Finder 是否启用；
- GPG 总开关是否开启，但不读取任何密钥私密材料；
- AI 主开关、模型可用性状态；
- 最近因为设置导致的失败标签，例如 “archiveListingCacheDisabled”。

这些都是设置诊断所需的数据，不属于密码/密钥/密文红线。

### 施工建议

- `SettingsCatalogItem` 保持轻量，避免直接塞太多运行态。
- 新增 `SettingsAIContextBuilder`，运行时把 `SettingsCatalog` + `AppPreferences` 当前值 + 相关统计合成 AI catalog。
- `settingsQuerySpec` 升级为 `settingsAssistantPlan`，返回 matches、answer、safeActions。
- `SettingsView` 侧栏搜索框显示结果 popover，而不是直接跳走；用户确认后再跳转或切换。
- 所有可写动作仍走 `SettingToggleRegistry` 或新的 `SettingSafeActionRegistry`。

## 建议十四：自动化建议升级

`automationSuggestionPrompt` 当前只吃聚合 usage summary。建议从活动中心 rich snapshot 生成更有价值的自动化画像。

可加入：

- 最近任务按来源、类型、状态、时间段的分布；
- 重复出现的输入/输出目录；
- 高频失败类型；
- 常见格式转换链路；
- 用户常手动重跑的任务；
- Finder/Shortcuts/CLI 的使用比例；
- 长任务完成时间和是否常在后台；
- 发布助手是否常用、是否经常缺校验/签名材料。

AI 输出仍只是“建议用户可创建的 Shortcuts 草稿”，不自动创建、不自动执行。

## 建议十五：全局“AI 可用数据”调试视图

建议在开发者工具或隐藏调试入口里加一个只读视图：

- 选择一个任务/归档/报告；
- 查看 App 准备发给 AI 的 `AIContextEnvelope`；
- 明确列出被省略的数据和原因；
- 高亮 redaction；
- 显示 token/字符预算；
- 一键复制上下文用于调试。

这能避免以后回到“AI 说废话，不知道是模型问题还是数据太薄”的状态。

## 建议十六：小上下文后台习惯总结

可以增加一个很小、低频、完全本地的“用户习惯摘要”。它不是长期记忆库，也不是让 AI 常驻后台读完整历史，而是偶尔在后台把最近活动中心和设置里的非敏感事实压缩成一段短上下文，供后续 AI 筛选、创建/解压建议、自动化建议和失败解释使用。

### 目标

- 让 AI 知道用户常用什么格式、常从哪里触发任务、常把结果放到哪里、常遇到什么失败，而不是每次都从零开始。
- 背景上下文保持很小，例如 1-2 KB 的 JSON 加一段 500 字以内的人类可读摘要。
- 只总结习惯和偏好，不保存文件内容，不保存密码，不保存加密条目名，不保存解密产物。
- 用户可关闭、可清空、可查看最近一次摘要内容。

### 数据来源

优先用确定性聚合，不直接把全量历史喂给 AI。

可统计：

- 最近 N 条活动中心任务的类型、来源、状态、时间段分布。
- 常用格式，例如 zip、7z、tar.zst、dmg。
- 常用动作，例如解压、创建、转换、测试、发布检查、hash。
- 常用目的地类别，例如 Downloads、Desktop、外置盘、同目录、临时工作区。默认记录类别，不记录完整路径；若后续要记录具体路径，必须单独做开关。
- 常见失败标签，例如权限、缺卷、磁盘空间、校验失败、签名问题、不支持格式。
- 常用创建选项，例如 exclude junk、reproducible、test after create、split volume、压缩级别区间。
- 常用自动化来源，例如 CLI、Shortcuts、Finder、URL scheme。
- 用户经常重跑或从失败步继续的任务类型。

仍然禁止：

- 密码、密钥、passphrase。
- 加密归档条目名、GPG 密文、解密明文。
- 未经用户明确允许的完整个人路径长期保存。
- 原始后端日志长期塞进习惯摘要。日志只参与当次确定性失败分类，摘要里只存标签和计数。

### 更新时机

建议低频触发，避免后台频繁跑模型：

- 每完成 10-20 个任务后，如果距离上次总结超过 24 小时。
- App 空闲、没有活动任务、AI 主开关开启、系统模型 available 时才运行。
- 用户打开活动中心或设置页时可以顺手检查是否需要刷新，但不要阻塞 UI。
- 手动按钮：“重新总结我的使用习惯”。

如果 AI 不可用，仍可以更新确定性统计 JSON；等模型可用时再生成自然语言摘要。

### 存储结构

建议新增 `AIHabitSummaryStore`，存 UserDefaults 或同类本地偏好域，内容保持小而可迁移。

建议字段：

- `schemaVersion`
- `updatedAt`
- `sourceWindow`：例如最近 90 天 / 最近 200 条任务。
- `deterministicStats`：格式、动作、来源、状态、失败标签、目的地类别计数。
- `summaryText`：AI 生成的短摘要。
- `promptHints`：给后续 AI 的短 hints，例如“用户常把解压结果放到同目录”“发布检查失败多与签名材料缺失有关”。
- `omissions`：因为隐私或加密而省略的数据计数。

后续 AI prompt 只读取 `promptHints` 和少量统计，不读取完整历史。

### 使用方式

活动中心 AI 筛选：

- 用户说“找上次那个常用目录里的失败任务”时，可以知道“常用目录类别”是什么。
- 用户说“那个我经常用 Finder 解压的包”时，可以优先理解 Finder 来源和解压任务。

创建/解压建议：

- 如果用户常用 reproducible 或 test after create，可以提示“你最近常在创建后校验，这次也保持开启”。
- 如果用户经常把散落文件解到 Downloads，可以提醒顶层结构风险。

自动化建议：

- 不再只基于操作计数，而是结合“重复出现的动作 + 来源 + 失败模式”生成 Shortcuts 建议。

失败解释：

- 可以补一句“这类失败最近出现过几次”，但不能夸大。AI 应说明这是本机历史中的相似标签，不是根因证明。

### UI 和控制

建议放在设置的 AI 区域或活动中心设置里：

- 开关：允许本机 AI 总结使用习惯。
- 按钮：立即重新总结。
- 按钮：清空 AI 习惯摘要。
- 文本：最近更新时间、使用的数据窗口、摘要内容预览。
- 说明：只使用本机非敏感活动元数据，不读取密码、加密条目或文件内容。

默认值可以跟随 AI 主开关，但建议第一次明确显示说明，避免用户以为 app 在后台“偷偷记忆”。

### 实现边界

- 先做确定性统计，再做 AI 总结。AI 不能直接扫完整历史决定该记什么。
- 摘要是建议上下文，不是行为规则。它不能自动改设置，不能自动改变创建/解压参数。
- 摘要失效不影响功能。读不到或过期就当没有习惯上下文。
- 每次生成前走 `AIContextEnvelope`，并带上 `omissions`，方便调试和隐私测试。

## 建议十七：评估和测试

AI 功能不适合只靠肉眼试。建议把“AI 前的确定性部分”做成可测核心。

需要覆盖：

- 每个 `AIContextBuilder` 的 schema 输出稳定性。
- `AIContextEnvelope` 的 `privacy`、`budget`、`omissions` 字段完整性。
- 专属 AI 中心总览数据不读取红线数据。
- `AICenterModel` 只读各 store，不直接执行业务动作。
- `ActivityTaskAIIndex` 从任务生成的字段完整性。
- `ActivityFilterSpecV2` 到确定性匹配的行为。
- `ActivityAIWorkbench` 输出的 task id/filter token 必须可校验。
- `ContextualActionCandidateProvider` 只生成安全候选动作。
- `ContextualActionRanker` 在无 AI 时保持当前硬编码行为等价。
- `ContextualActionUsageStore` 不保存完整敏感路径。
- `ArchiveMemoryRecord` 只包含非加密条目名，且记录加密省略数量。
- `ArchiveSearchIntent` 到本地召回的行为。
- `SettingsAIContextBuilder` 包含当前值、依赖、隐私说明和安全动作。
- `SettingSafeActionRegistry` / `SettingToggleRegistry` 仍是所有设置写入的唯一白名单。
- 敏感字段 redaction。
- 加密条目绝不进入上下文。
- 日志尾部截断和错误行抽取。
- report summarizer 的样本预算。
- archive listing cache 的 AI 摘要不包含 encrypted entry name。
- 设置 catalog 的 toggle 白名单。
- habit summary 不包含完整敏感路径、密码、加密条目名或原始日志。

同时建立一组人工评估 query：

- “失败的 zip”
- “今天 Finder 解压失败”
- “权限问题”
- “缺少分卷”
- “checksum mismatch”
- “输出到 Downloads”
- “跑很久的压缩”
- “含许可证的源码包”
- “像配置文件的那个归档”
- “AI 查不到归档里的文件是不是缓存没开”
- “为什么这个文件夹推荐发布包检查”
- “打开 AI 中心看看我现在该处理什么”

每条 query 记录期望命中条件，不要求模型输出完全一致，但要求最终候选任务/归档正确。

## 建议十八：AI 证据卡，让每条建议都能解释来源

AI 要变得可信，不能只说“建议你测试这个归档”。每条 AI 建议都应该带证据卡：告诉用户它为什么这么判断、用了哪些本地事实、哪些事实被省略。

建议所有 AI 输出统一带 `evidence`：

```json
{
  "title": "建议重新测试 release.7z",
  "reason": "最近一次 CLI 测试失败，日志里有 Data Error，而且这个归档位于 release 目录。",
  "evidence": [
    {
      "sourceRef": {"type": "task", "id": "task-7B2F"},
      "label": "最近测试任务失败",
      "facts": ["source=cli", "kind=test", "status=failed", "tag=checksum-mismatch"]
    },
    {
      "sourceRef": {"type": "archive", "id": "archive-release-7z"},
      "label": "归档位置和名称",
      "facts": ["folderToken=release", "extension=7z"]
    }
  ],
  "omissions": [
    {"type": "encrypted_entries", "reason": "encrypted entry names are never sent to AI"}
  ]
}
```

UI 上可以折叠显示：

```text
为什么推荐？
  - 活动中心：Test release.7z failed
  - 诊断标签：checksum-mismatch
  - 目录信号：release
  - 省略：加密条目名未进入 AI
```

施工建议：

- 新增 `AIEvidenceCard` / `AIEvidenceFact` 通用模型。
- `AISuggestionItem`、`AIVirtualNode`、`ActivityAIWorkbenchCard`、`ContextualActionRecommendation` 都带 evidence。
- App 校验 source ref 存在；不存在的证据整条丢弃。
- AI 中心调试页可以按 evidence 反查“这条建议用了哪些数据”。

这能直接解决“AI 看起来像玄学”的问题。用户可以看到 AI 是根据任务、归档、路径、报告还是习惯做判断。

## 建议十九：AI 操作预演

创建、解压、转换、测试、发布检查这些操作在真正执行前，应该有一个 AI 操作预演。它不是确认按钮，也不是安全裁判，而是把确定性预检 facts 解释成人能快速理解的风险和建议。

适用场景：

- 创建归档前；
- 解压归档前；
- 转换格式前；
- 批量测试前；
- 发布包检查前；
- 对多个文件执行批处理前。

输入数据集：

```json
{
  "schema": "simplezip.ai.operationPreview.input.v1",
  "operation": {
    "kind": "extract",
    "format": "zip",
    "sourceRefs": [{"type":"archive","id":"archive-mods-zip"}],
    "targetLocationKind": "downloads",
    "options": {
      "createContainingFolder": false,
      "overwritePolicy": "ask",
      "preserveSymlinks": true
    }
  },
  "preflight": {
    "topLevelShape": "scattered_files",
    "topLevelSampleNames": ["config.json", "mods/", "README.txt"],
    "entryCount": 420,
    "encryptedEntryCount": 0,
    "willOverwriteCount": 12,
    "overwriteSamples": ["README.txt", "config.json"],
    "hasExecutableContent": true,
    "hasSymlinks": false,
    "diskSpace": {"availableBytes": 1200000000, "estimatedNeedBytes": 800000000}
  },
  "historySignals": {
    "similarOperationFailures": ["permission-denied"],
    "userOftenCreatesFolderForScatteredExtract": true
  },
  "omissions": [
    {"type":"file_contents","policy":"not_read"},
    {"type":"encrypted_entries","policy":"never_included"}
  ]
}
```

输出：

```json
{
  "schema": "simplezip.ai.operationPreview.output.v1",
  "headline": "建议先解压到新文件夹",
  "riskLevel": "medium",
  "points": [
    "这个归档顶层是散落文件，会直接写入 Downloads。",
    "目标目录已有 12 个同名文件，可能触发覆盖确认。",
    "可用空间足够。"
  ],
  "recommendedOptionChanges": [
    {"option": "createContainingFolder", "suggestedValue": true, "reason": "避免散落到 Downloads"}
  ],
  "blocked": false
}
```

关键边界：

- AI 只解释预检，不决定是否允许操作。
- 是否覆盖、是否解压、是否删除，仍由现有确认 UI 和确定性代码控制。
- 如果涉及密码或加密条目，AI 只看到“需要密码/有加密条目计数”，不能看到条目名和内容。

## 建议二十：AI 归档画像

每个非加密归档可以生成一个可复用的“归档画像”。它不是自然语言摘要，而是结构化标签和证据，供 AI 工作区、归档查找、动态按钮、报告解释共用。

画像示例：

```json
{
  "schema": "simplezip.ai.archiveProfile.v1",
  "archiveID": "archive-13F0",
  "archiveName": "SimpleZip-source.zip",
  "extension": "zip",
  "profiledAt": "2026-06-15T10:30:00Z",
  "semanticTags": ["source-archive", "localized-app", "swift-project"],
  "markerFiles": ["Package.swift", "README.md", "LICENSE"],
  "dominantExtensions": [
    {"ext": "swift", "count": 420},
    {"ext": "strings", "count": 12},
    {"ext": "md", "count": 8}
  ],
  "structure": {
    "topLevelShape": "single_root_folder",
    "entryCount": 980,
    "directoryCount": 120,
    "encryptedEntryCount": 0,
    "truncated": false
  },
  "riskHints": ["contains-app-bundle", "contains-executable"],
  "suggestedActions": ["open", "test", "search-inside", "compare"],
  "evidence": [
    {"label": "Swift package marker", "facts": ["Package.swift"]},
    {"label": "Localization marker", "facts": ["Localizable.strings"]}
  ]
}
```

生成方式：

- 第一层确定性派生：扩展名分布、marker 文件、顶层结构、加密计数、风险 hints。
- 第二层 AI 标注：把确定性 facts 转成语义标签，例如 `source-archive`、`release-artifact`、`backup`。
- AI 标注结果必须可回溯 evidence，不能只给一个标签。

复用场景：

- AI 工作区：把“源码包”“发布包”“备份包”自动归组。
- 归档查找：用户问“哪个包像源码包”时，不必重新扫描。
- 动态工具栏：源码包推荐打开/查找/测试，发布包推荐测试/签名/校验。
- 操作预演：如果画像显示散落文件或可执行内容，预演可以更准确。

## 建议二十一：AI 纠错反馈，不只统计点击率

动态学习不能只统计“用户点了什么”。用户还需要能纠正 AI 的理解：

- 有用；
- 不感兴趣；
- 理由不对；
- 这个不是源码包；
- 这个不是发布包；
- 以后别在 Downloads 推荐这种；
- 以后这个目录多推荐发布检查；
- 这个工作区主题太泛。

建议新增统一反馈模型：

```swift
struct AIFeedbackEvent: Codable, Equatable {
    enum TargetKind: String, Codable {
        case workspace
        case virtualNode
        case toolbarAction
        case activityCard
        case archiveProfile
        case settingSuggestion
        case operationPreview
    }

    enum FeedbackKind: String, Codable {
        case useful
        case dismissed
        case wrongReason
        case wrongTag
        case tooBroad
        case tooNoisy
        case doMoreLikeThis
        case doLessLikeThis
    }

    let targetKind: TargetKind
    let targetID: String
    let feedbackKind: FeedbackKind
    let correctedTags: [String]
    let context: AIFeedbackContext
    let createdAt: Date
}
```

反馈进入 `AIHabitSummary` 时，不要保存过细隐私路径，保存可泛化的 token：

```json
{
  "feedbackSummary": {
    "positivePatterns": [
      {"tokens":["release","checksum"],"targetKind":"workspace","count":8},
      {"tokens":["source-code","archiveEntry"],"targetKind":"virtualNode","count":5}
    ],
    "negativePatterns": [
      {"tokens":["downloads-cleanup"],"targetKind":"workspace","count":4},
      {"tokens":["automation-draft"],"targetKind":"virtualNode","count":3}
    ],
    "tagCorrections": [
      {"from":"source-archive","to":"test-fixture","count":2}
    ]
  }
}
```

这会让 AI 的学习比“zip 用得多”细很多：它能知道用户喜欢哪类主题、讨厌哪类推荐、哪些标签经常判断错。

## 建议二十二：AI 批处理规划器

用户选中一批文件时，AI 不应该只给两个固定按钮。更强的做法是先做批处理规划，把选择项分组，再推荐动作。

示例输入：

```json
{
  "schema": "simplezip.ai.batchPlan.input.v1",
  "selection": {
    "count": 12,
    "items": [
      {"id":"file-1","name":"release.7z","kind":"archive","extension":"7z","sizeBytes":84000000},
      {"id":"file-2","name":"release.7z.001","kind":"file","extension":"001","sizeBytes":50000000},
      {"id":"file-3","name":"source.zip","kind":"archive","extension":"zip","profileTags":["source-archive"]},
      {"id":"file-4","name":"README.md","kind":"file","extension":"md"}
    ]
  },
  "context": {
    "locationKind": "desktop",
    "folderNameTokens": ["release", "test"],
    "recentActionFeedback": ["test-after-create-clicked", "convert-cancelled"]
  }
}
```

输出：

```json
{
  "schema": "simplezip.ai.batchPlan.output.v1",
  "groups": [
    {
      "title": "发布归档",
      "itemIDs": ["file-1"],
      "recommendedActions": ["test", "openReport"],
      "reason": "文件名和当前目录都含 release，优先校验。"
    },
    {
      "title": "可能的分卷文件",
      "itemIDs": ["file-2"],
      "recommendedActions": ["locateMainVolume"],
      "reason": "001 看起来是分卷的一部分，不能当独立归档直接处理。"
    },
    {
      "title": "源码包",
      "itemIDs": ["file-3"],
      "recommendedActions": ["open", "searchInside"],
      "reason": "归档画像显示 source-archive。"
    }
  ],
  "warnings": [
    "README.md 不是归档，不参与测试。"
  ]
}
```

UI 可以在工具栏推荐菜单里显示“AI 分组建议”，用户点开后看见每组的建议动作。真正执行时仍然调用现有批处理和确认逻辑。

## 建议二十三：AI “为什么没有推荐”

AI 空状态不能只写“没有建议”。用户会以为 AI 坏了。应该解释没有推荐的原因。

可能原因：

- 最近任务太少；
- 当前目录没有可分析的归档；
- 归档清单缓存为空或过期；
- 当前归档是加密清单，条目名不能进入 AI；
- 用户关闭了习惯学习；
- 所有推荐主题都被用户点过“不感兴趣”；
- AI 模型暂不可用，只显示确定性建议；
- 候选都被安全规则拦截。

输出格式：

```json
{
  "schema": "simplezip.ai.emptyStateReason.v1",
  "surface": "ai_workspace",
  "headline": "现在没有可靠建议",
  "reasons": [
    {"code":"archive_cache_empty","message":"还没有可用于查找的归档清单缓存。"},
    {"code":"habit_learning_disabled","message":"习惯学习已关闭，因此不会生成个性化主题。"}
  ],
  "safeNextSteps": [
    {"kind":"openArchive","label":"打开一个归档以建立索引"},
    {"kind":"openAIPrivacySettings","label":"查看 AI 数据设置"}
  ]
}
```

这会让 AI 中心、AI 工作区、活动中心工作台、归档查找和设置助手的空状态都更清楚。

## 建议二十四：AI 场景路由器

最终 SimpleZip 的 AI 不应该是一堆分散入口，而应该有统一场景路由。用户一句“帮我看看这个包有什么问题”，App 应该根据当前上下文判断走哪个 AI 场景。

建议新增 `AIIntentRouter`：

```swift
struct AIIntentRoutingInput: Codable, Equatable {
    let userText: String
    let surface: String
    let currentMode: String
    let selectedSourceRefs: [AIContextSourceRef]
    let availableCapabilities: [String]
    let recentContextSummary: AIContextEnvelope
}

struct AIIntentRoutingResult: Codable, Equatable {
    enum Destination: String, Codable {
        case activityFilter
        case archiveSearch
        case operationPreview
        case failureExplanation
        case settingsAssistant
        case aiWorkspace
        case actionRecommendation
        case reportExplanation
    }

    let destination: Destination
    let confidence: Double
    let extractedQuery: String
    let reason: String
}
```

路由例子：

- 当前选中归档，用户说“看看有什么问题”：走 `operationPreview` 或 `archiveProfile`。
- 当前在活动中心，用户说“找上次权限失败”：走 `activityFilter`。
- 当前在设置，用户说“我不想每次都弹这个”：走 `settingsAssistant`。
- 当前在 AI 工作区，用户说“按发布相关重新整理”：走 `aiWorkspace`。
- 当前在归档记忆查找，用户说“源码包”：走 `archiveSearch`。

路由器的价值是让 AI 像一个整体，而不是每个按钮各自为政。实现上可以先不用模型，用当前 surface + selection 做 deterministic routing；后续再让 AI 在低置信度时辅助判断。

## 工程补充一：MVP 边界

这份文档里的最终形态很大，第一版必须收口。建议把 MVP 定义成“没有模型也能工作的 AI 数据和虚拟视图底座”，不要第一版就做完整推荐、习惯学习和场景路由。

### 第一版必须做

- 新增统一 `AIContextEnvelope` 和基础 redaction。
- 新增 `ActivityTaskAIIndex`，能从活动中心任务生成稳定 JSON facts。
- 新增 `ArchiveMemoryRecord` 的确定性派生，先只基于非加密归档清单。
- 新增主窗口侧边栏 `AI` section。
- 新增系统工作区，例如 `需要处理`、`归档里的文件`、`发布与校验`。
- 新增 `.aiWorkspace(UUID)` browser mode。
- 新增 `AIVirtualFolderTree` 和只读 `AISuggestionFolderView`。
- 工作区第一版只显示确定性候选：未查看失败、最近失败任务、相关归档、非加密归档内部 marker、最近报告。
- 所有动作只允许打开、定位、搜索、解释，不直接修改文件。

### 第一版明确不做

- 不做后台 AI 推荐主题。
- 不做用户 prompt 创建工作区。
- 不做习惯小上下文。
- 不做 AI 场景路由器。
- 不做批处理规划器。
- 不做自动化草稿生成。
- 不在虚拟树里展示大量深层条目，只展示 marker、样本和命中项。
- 不把虚拟节点伪造成真实 `FileItem`。

### 第一版验收标准

- 关闭 AI 模型或模型不可用时，AI section 仍然能显示确定性工作区。
- 所有虚拟节点都有可回查的 source ref。
- 所有归档内部条目都来自非加密清单缓存。
- 点击虚拟节点不会触发删除、移动、覆盖、解压、修改权限等真实写操作。
- AI 数据调试视图能导出本次虚拟树使用的 facts 和 omissions。

## 工程补充二：模型能力分层与可替换 AI 引擎

需要承认一个现实：Apple 本地模型很适合做轻量理解、总结、排序和结构化输出，但不应该把整个产品野心押在它“像云端大模型一样聪明”上。SimpleZip 的架构应该是“强数据底座 + 可替换模型执行器”。

核心原则：

- 数据底座不可替换：索引、画像、反馈、source ref、安全校验必须由 App 自己做好。
- 模型执行器可替换：Apple Foundation Models 是第一实现，未来可以增加更强的本地模型或用户自选高级模型。
- 安全控制永远不交给模型：删除、覆盖、解压、修改权限、信任签名、解密、导入密钥都由 Swift 规则和现有确认流程控制。

### L0：无模型基础能力

即使没有任何 AI 模型，SimpleZip 也应该拥有这些能力：

- 活动中心 rich index；
- 归档记忆索引；
- 归档画像的确定性部分；
- 系统 AI 工作区；
- 未查看失败、最近报告、相关归档、归档 marker 的虚拟树；
- 动态工具栏候选枚举；
- 设置语义目录；
- source ref validation；
- redaction、budget、omissions；
- “为什么没有推荐”的确定性原因。

L0 是底座。只要 L0 做好，AI 不可用时产品仍然比现在聪明。

### L1：Apple 本地模型能力

Apple 本地模型适合承担：

- 把自然语言转成筛选 spec；
- 给工作区主题命名；
- 对候选任务、归档、动作排序；
- 把确定性 facts 组织成虚拟文件夹树；
- 解释失败标签和错误行；
- 生成证据卡的人类可读文案；
- 生成短习惯摘要；
- 给归档画像补语义标签；
- 生成设置搜索回答；
- 生成操作预演的自然语言提示。

L1 的输入必须是结构化 facts，不是无限长的原始文件和日志。L1 的输出必须是结构化 JSON，不是直接执行动作。

### L2：可选高级模型增强

如果以后 Apple 本地模型满足不了更大的野心，可以增加可选高级模型层。这个层必须是可选的，且不能破坏本地默认体验。

适合 L2 的任务：

- 大规模语义查找；
- 更复杂的多步骤批处理规划；
- 更长报告生成；
- 更强的归档内容语义分类；
- 更自然的全局 AI 中心问答；
- 更复杂的 release note / issue / VERIFY 草稿；
- 跨多个工作区的综合分析。

不管 L2 是更强本地模型、用户自带模型，还是未来可选远程 provider，都必须遵守同一套 `AIContextEnvelope`、redaction、source ref validation 和动作白名单。

### L3：永远由本地规则控制

以下能力永远不能交给模型决定：

- 是否删除文件；
- 是否覆盖文件；
- 是否解压到目标路径；
- 是否修改权限；
- 是否信任签名；
- 是否导入密钥；
- 是否解密；
- 是否把密码、密钥、加密条目名、解密明文放进上下文；
- 是否绕过已有安全提示。

模型可以解释风险、推荐打开某个确认 sheet，但不能绕过确认，也不能自己放行。

### 建议的引擎接口

不要让 UI 直接调用 `AIReportAssistant` 的具体方法。建议抽一层能力接口：

```swift
protocol AIEngine {
    var id: String { get }
    var displayName: String { get }
    var capabilityLevel: AICapabilityLevel { get }
    func availability() async -> AIEngineAvailability
    func generate<Output: Codable>(
        request: AIEngineRequest<Output>
    ) async throws -> Output
}

enum AICapabilityLevel: String, Codable {
    case none
    case deterministicOnly
    case appleOnDevice
    case advancedOptional
}
```

第一版可以只有：

- `DeterministicAIEngine`：不调用模型，只输出基础建议；
- `AppleFoundationModelEngine`：包装现有 FoundationModels 调用。

未来可以增加：

- `UserProvidedLocalModelEngine`；
- `AdvancedModelEngine`；
- `MockAIEngine`，用于测试固定 JSON 输出。

### 能力协商

每个 AI 场景声明自己需要什么能力：

```swift
struct AIFeatureCapabilityRequirement: Codable, Equatable {
    let featureID: String
    let minimumLevel: AICapabilityLevel
    let preferredLevel: AICapabilityLevel
    let requiresStructuredOutput: Bool
    let requiresToolCalling: Bool
    let allowsAdvancedOptionalEngine: Bool
}
```

示例：

| 功能 | 最低能力 | 推荐能力 | 高级模型是否有价值 |
|---|---|---|---|
| 系统 AI 工作区 | L0 | L1 | 中 |
| 活动中心筛选 | L0 关键词 fallback | L1 | 低 |
| 归档记忆查找 | L0 本地召回 | L1 | 中 |
| 归档画像 | L0 确定性标签 | L1 | 中 |
| 批处理规划 | L0 分组规则 | L1 | 高 |
| 全局 AI 中心问答 | L0 卡片入口 | L1/L2 | 高 |
| 长报告草稿 | L0 模板 | L1/L2 | 高 |

这样即使 Apple 本地模型不够强，也不会卡住架构。SimpleZip 会先靠 L0/L1 做出可用体验；以后模型增强，只替换 engine，不重写数据层。

## 工程补充三：数据保留、清空和开关

“给 AI 更多数据”必须配套清晰的保留周期和用户控制。建议把 AI 数据分成几类，每类都有开关、TTL 和清空入口。

### 数据保留建议

| 数据类型 | 默认保留 | 清空入口 | 说明 |
|---|---:|---|---|
| 当次 AI prompt facts | 不持久化 | 自动丢弃 | 只用于本次调用，debug 模式可临时查看 |
| AI 上下文调试记录 | 最近 20 次或 24 小时 | AI 中心 / 数据与隐私 | 仅开发/高级开关开启时保存 |
| 活动中心 AI 索引 | 跟随活动中心历史 | 活动中心清空历史 | 派生数据，不单独长期保存 |
| 归档记忆索引 | 跟随归档清单缓存 TTL | 归档缓存清空 | 只包含非加密条目派生摘要 |
| 归档画像 | 跟随归档记忆索引 | 归档缓存清空 | 可重建，迁移失败可丢弃 |
| 非加密文本 marker 摘要 | 跟随归档画像 / 工作区缓存 | 归档缓存清空 / AI 数据清空 | 仅深度本地上下文，短摘要，可重建 |
| AI 工作区虚拟树缓存 | 7 天或最近 50 个工作区 | AI 中心 / 工作区右键 | 只缓存 source refs 和展示文案 |
| AI 推荐主题 | 7 天 | AI 中心 / 不感兴趣 | 推荐主题默认短期存在 |
| 用户创建工作区 | 用户删除前保留 | 右键删除 | 保存 prompt、标题、折叠状态和排序偏好 |
| AI 反馈事件 | 90 天聚合，原始事件 30 天 | AI 中心 / 清空学习数据 | 原始反馈可压缩成习惯摘要 |
| 习惯摘要 | 90 天窗口滚动重算 | AI 中心 / 清空学习数据 | 不保存密码、加密条目名、原始日志 |

### 用户开关建议

设置里建议增加一个 `AI 与智能建议` 分组：

- `启用 AI 功能`：总开关。
- `本地上下文强度`：标准 / 深度。标准给足本机元数据，深度额外允许非加密文本 marker 摘要和更长历史窗口。
- `允许 AI 使用活动中心历史`：关闭后活动筛选只看当前可见任务。
- `允许 AI 使用归档清单缓存`：关闭后归档记忆查找和归档内虚拟节点不可用。
- `允许 AI 使用当前完整路径`：默认开启，因为模型在本机运行；关闭后只给路径类别和哈希。
- `允许 AI 使用路径类别`：允许 Downloads/Desktop/Projects/External Drive 这类类别，建议默认开启。
- `允许 AI 使用文件夹名称 token`：允许 release/test/backup 等目录名 token，建议默认开启。
- `允许 AI 读取非加密文本 marker 摘要`：深度模式开关，读取 README、manifest、Package.swift、package.json 等短摘要。
- `允许 AI 使用固定路径别名`：深度模式开关，例如用户固定的项目目录、发布目录、测试目录。
- `允许后台习惯总结`：关闭后不生成 `AIHabitSummary`。
- `后台本地 AI 活跃度`：关闭 / 省电 / 平衡 / 积极。控制低负载静默生成的频率和范围。
- `允许低负载时预生成 AI 工作区`：开启后在系统空闲时预生成推荐主题、虚拟树和证据卡。
- `允许后台 AI 预读归档`：开启后在安全目录和用户白名单目录里只读扫描归档清单，建立更强索引。
- `允许后台 AI 预索引文件夹`：开启后在白名单目录里只读建立文件夹、普通文件和安全内容摘要索引。
- `后台 AI 预读目录白名单`：用户自由添加目录；默认只建议 Downloads、Desktop、Documents、固定路径和项目目录。
- `允许侧边栏显示推荐工作区`：关闭后只显示系统和用户工作区。
- `保存 AI 调试上下文`：默认关闭，只给开发/高级用户。

关闭某个开关时，对应 builder 应在 `omissions` 里写明原因：

```json
{
  "type": "activity_history",
  "policy": "disabled_by_user",
  "message": "用户关闭了允许 AI 使用活动中心历史。"
}
```

### 清空策略

清空必须可预测：

- 清空归档清单缓存：同时清空 `ArchiveMemoryIndex`、`ArchiveProfile`、相关归档内虚拟节点缓存。
- 清空 AI 深度上下文缓存：清空非加密文本 marker 摘要、固定路径别名派生、深度模式下生成的归档画像增强字段。
- 清空后台归档预读索引：清空后台预读得到的归档清单、归档画像、归档角色、AI 工作区候选；不删除任何真实文件。
- 清空后台文件预索引：清空文件夹画像、文件元数据索引、安全文本摘要和内容标签；不删除任何真实文件。
- 清空活动中心历史：同时清空 `ActivityTaskAIIndex` 的持久派生。
- 清空 AI 学习数据：清空 `AIHabitSummary`、`AIFeedbackEvent`、推荐主题 dismiss 记录。
- 删除用户工作区：删除该工作区 prompt、虚拟树缓存、折叠状态；不删除源文件、任务或归档缓存。
- 关闭总 AI 开关：不再生成新 AI 上下文；已有派生缓存可以保留，但 UI 不展示 AI 入口，除非用户在设置里清空。

## 工程补充四：性能预算和刷新规则

AI 功能不能拖慢主窗口、活动中心和归档浏览。所有 AI builder 都要有预算，超过预算时先本地召回、截断、写入 omissions。

### 默认预算

| 场景 | 默认候选预算 | 文本预算 | 刷新频率 |
|---|---:|---:|---|
| 活动中心筛选 | 80 个任务 | 每任务错误行 800 字符以内 | 用户触发 |
| 活动中心工作台 | 50 个任务 + 20 个报告摘要 | 20 KB facts | 5-10 分钟最短间隔 |
| AI 工作区主题推荐 | 30 个主题候选 | 12 KB facts | 30-60 分钟 |
| AI 工作区虚拟树 | 80 个节点候选 | 30 KB facts | 打开时过期检查 |
| 归档记忆查找 | 60 个归档候选 | 每归档 20 个样本以内 | 用户触发 |
| 归档画像 | 单归档最多 10,000 条清单派生 | 不给模型原始全量清单 | 清单缓存更新后后台低优先级 |
| 深度归档画像 | 单归档最多 10,000 条清单派生 + 30 个 marker 摘要 | 每个 marker 摘要 1-2 KB | 仅深度模式，后台低优先级 |
| 操作预演 | 当前操作相关 facts | 12 KB facts | 用户打开确认 sheet |
| 习惯摘要 | 最近 90 天聚合统计 | 8 KB facts | 每 24 小时或空闲 |

标准模式的预算应该已经足够慷慨，不能再退回“只给标题”的状态。深度模式的原则是：允许更长历史、更完整 marker、更多样本，但仍然不把全量文件内容和完整日志无限塞进模型。

### 后台运行规则

- App 启动后前 60 秒不跑后台 AI。
- 用户正在执行归档操作时，不跑低优先级主题推荐。
- 电池低电量、低电量模式、模型不可用时，只做确定性建议。
- 文件夹快速刷新时只标记 AI 缓存过期，不立即生成。
- 后台生成必须可取消，窗口关闭或工作区切换时取消当前非必要任务。
- 所有 AI 调用继续走 `AIGenerationSerializer`，避免并发模型调用互相抢资源。
- 深度本地上下文只在空闲时生成；如果用户正在滚动文件列表、执行压缩/解压、或活动中心快速刷新，深度摘要延后。
- 深度模式下读取非加密文本 marker 时必须有文件大小上限和类型白名单，避免误读大型二进制或日志文件。

### UI 性能要求

- 点开 AI 工作区必须立即显示缓存或确定性占位，不能等模型。
- 生成中状态用小型进度行，不阻塞文件列表。
- 虚拟树首屏节点控制在 50 个以内，更多内容用“显示更多”或按组懒加载。
- 归档内部条目只展示命中样本，不默认展开全量目录树。

## 工程补充五：低负载静默 AI 调度器

既然 Apple Foundation Models 是本地模型，并且系统可能使用 Neural Engine / NPU 等本机加速资源，SimpleZip 不应该只在用户点按钮时才调用 AI。更好的策略是：在低负载、空闲、可取消的条件下，静默把 AI 数据准备好，让用户打开 AI 工作区、活动中心或归档查找时立刻看到更懂自己的结果。

这不是“后台偷偷读用户文件”。它必须满足几个前提：

- 用户开启 AI 主开关；
- 用户允许后台本地 AI；
- 只读取已授权、本机、非红线数据；
- 任务低优先级、可取消；
- 不阻塞压缩/解压/浏览；
- 有清晰的设置、状态和清空入口。

### 后台本地 AI 活跃度

建议设置为四档：

| 档位 | 行为 | 适合用户 |
|---|---|---|
| 关闭 | 不做静默模型调用，只保留确定性索引 | 极度保守 |
| 省电 | 只在充电、空闲、无活动任务时低频生成 | 笔记本默认可选 |
| 平衡 | 空闲时定期更新习惯摘要、推荐主题、归档画像 AI 标签 | 推荐默认 |
| 积极 | 更频繁预生成 AI 工作区、Lens、搜索重写缓存和动作卡 | 希望软件更懂自己的用户 |

如果用户把 AI 放在 T0，`平衡` 应该是推荐默认。因为本地模型不用外发，也不产生云端成本；真正要控制的是电量、热量、UI 流畅度和隐私红线。

### 可以静默跑的任务

适合后台低负载运行：

- `AIHabitSummary`：把最近活动压成短习惯摘要。
- `AIWorkspaceTheme`：生成推荐工作区主题。
- `AIVirtualFolderTree`：为常用系统工作区预生成虚拟树。
- `ArchiveProfile` AI 二次标签：给已有确定性画像补语义标签。
- `ArchiveRoleClassifier` 模糊角色判定：source/release/backup/test fixture。
- `AIFileMemoryIndex`：为白名单目录预索引普通文件、文件夹画像和安全文本摘要。
- `NextActionCard`：为当前目录、最近失败任务、常用工作区预生成下一步动作卡。
- `AI Lens` 缓存：为当前目录或最近目录预生成发布/源码/失败/签名视角。
- `EmptyStateReason`：预计算为什么没有推荐。
- `SettingsStateSnapshot`：刷新设置状态 facts，不需要模型但可作为后续输入。

不适合静默跑：

- 任何会触发文件写入的动作；
- 解压、转换、测试等真实任务；
- 读取大文件内容；
- 读取加密归档条目；
- 解密或访问解密临时文件；
- 长报告生成，除非用户打开对应报告或明确允许。

### 静默调度条件

新增 `AIBackgroundScheduler`：

```swift
actor AIBackgroundScheduler {
    func markDirty(_ reason: AIBackgroundDirtyReason)
    func scheduleIfIdle(context: AIBackgroundRuntimeContext)
    func cancelNonEssentialWork()
}

struct AIBackgroundRuntimeContext: Codable, Equatable {
    let appIsActive: Bool
    let runningTaskCount: Int
    let heavyArchiveTaskRunning: Bool
    let recentlyInteractedAt: Date?
    let powerMode: String
    let batteryLevel: Double?
    let isCharging: Bool?
    let modelAvailable: Bool
    let activityLevel: String
}
```

调度条件建议：

- App 启动后 60 秒内不跑。
- 用户 20-60 秒无输入后才跑轻任务。
- 无压缩/解压/测试/转换等重任务时才跑模型任务。
- 电池低电量或系统低电量模式下只跑确定性索引。
- 充电 + 空闲 + 模型可用时，可以跑深度本地上下文。
- 用户切换目录或任务完成时只 `markDirty`，不立即跑。
- 后台任务每次最多占用一个 `AIGenerationSerializer` 槽，前台 AI 请求优先。

### 任务优先级

建议队列分三级：

```text
P0 前台用户请求
  - 用户主动点 AI 解释、搜索、刷新工作区
  - 必须优先，后台任务让路

P1 近前台预热
  - 当前目录 AI Lens
  - 当前工作区虚拟树
  - 最近失败任务下一步动作卡

P2 空闲维护
  - 习惯摘要
  - 推荐主题
  - 归档角色 AI 标签
  - 深度 marker 摘要
```

如果 P0 到来，P1/P2 不应该抢占 UI。FoundationModels 当前调用不一定适合中途取消，所以实际策略可以是：后台任务一旦进入 `AIGenerationSerializer` 就跑完，但队列中未开始的后台任务立即取消或延后。

### 静默任务输出

后台任务不要直接改 UI，只更新缓存和建议 store：

- `AIHabitSummaryStore`
- `AIWorkspaceStore.recommendedThemes`
- `AIVirtualFolderTreeCache`
- `ArchiveProfileAIAnnotationStore`
- `NextActionCardStore`
- `AILensCache`
- `AIEmptyStateReasonCache`

UI 打开时读取这些缓存，显示“刚刚更新 / 10 分钟前更新 / 基础建议”。这会让 AI 看起来随时准备好，而不是每次点开都转圈。

### 用户可见状态

AI 中心可以显示一个小状态区：

```text
本地 AI 后台维护：平衡
最近更新：12 分钟前
已预生成：3 个工作区、18 个归档画像、5 张动作卡
本次省略：2 个加密归档条目、1 个疑似 token
```

这能让用户知道软件在本地做了什么，也能增强信任。

### 为什么值得做

本地弱模型单次能力有限，但它最大的优势是可以低成本、多次、短任务、持续运行。不要让它一次性解决大问题，而是让它经常做小整理：

- 今天识别几个归档角色；
- 空闲时给当前目录准备 Lens；
- 任务完成后更新失败模式；
- 用户关掉一个推荐后更新偏好；
- 晚点把活动中心压成几条 prompt hints。

这样软件会越来越懂用户，而且不需要云端成本。

## 工程补充六：后台 AI 预读归档索引

开启后台 AI 后，可以加入一个更主动但仍然安全的能力：后台 AI 预读归档。它只读取用户允许目录里的归档清单，不解压、不写入、不修改、不覆盖，只建立更强的本地索引，让 AI 工作区、归档查找、Lens、动作推荐更有数据。

这和“全盘扫描”不同。它必须是白名单、只读、预算化、可暂停、可清空的。

### 能读什么

允许读取：

- 白名单目录里的归档文件列表；
- 支持格式的归档清单；
- 非加密条目名、目录结构、大小、时间、属性、扩展名分布；
- marker 文件名，例如 README、LICENSE、Package.swift、SHA256SUMS、signature.asc；
- 深度模式下，非加密文本 marker 的短摘要；
- 归档所在目录的 location kind、path hash、folder name tokens；
- 归档文件本身的大小、mtime、格式。

禁止读取：

- 密码；
- 加密归档条目名；
- 加密归档内容；
- GPG 密文内容；
- 解密后的临时文件；
- 任意会造成写入的操作；
- 用户未授权目录；
- 系统敏感目录；
- 超出预算的大型递归目录。

### 默认安全目录

默认不应该全盘扫。建议提供“推荐安全目录”，用户确认后加入白名单：

- Downloads；
- Desktop；
- Documents；
- 用户固定路径；
- SimpleZip 侧边栏固定路径；
- 最近打开过的项目目录；
- 用户手动添加的目录。

默认排除：

- `/System`
- `/Library`
- `/Applications`，除非用户手动加入；
- `~/Library`
- `.git`、`node_modules`、`.build`、`DerivedData`、缓存目录；
- 临时解密目录；
- 外置盘默认不扫，除非用户加入白名单；
- 网络卷默认不扫，除非用户加入白名单且开启“允许网络卷”。

### 白名单模型

```swift
struct AIArchivePrefetchScope: Codable, Identifiable, Equatable {
    enum Origin: String, Codable {
        case suggestedSafeDirectory
        case userAdded
        case pinnedPath
        case projectFolder
    }

    let id: UUID
    let directoryPath: String
    let origin: Origin
    let recursive: Bool
    let maxDepth: Int
    let includeExternalVolumes: Bool
    let includeNetworkVolumes: Bool
    let createdAt: Date
    let lastScannedAt: Date?
}
```

UI 文案要清楚：这是“只读建立索引”，不是“自动解压”。

### 预读流程

```text
AIArchivePrefetchScheduler
  → 读取白名单目录
  → 找到支持的归档文件
  → 按预算排队
  → 使用现有 ArchiveService/listing 能力只读列目录
  → 过滤加密条目
  → 写入 ArchiveListingCacheStore
  → 派生 ArchiveMemoryRecord
  → 派生 ArchiveProfile / ArchiveRole
  → 可选生成 AI 标签和推荐工作区
```

关键点：

- 只做 list / inspect，不做 extract。
- 遇到需要密码的归档：记录 `needsPassword` 和 omission，不弹密码框，不尝试破解。
- 遇到头加密归档：记录“清单不可见”，不进入条目索引。
- 归档损坏：记录诊断标签，不反复重试。
- 预读结果进入同一套归档清单缓存和归档记忆索引，不能另起一套影子缓存。

### 预算和节流

建议预算：

| 档位 | 每轮最多目录 | 每轮最多归档 | 单归档条目上限 | 运行时机 |
|---|---:|---:|---:|---|
| 省电 | 1 | 10 | 2,000 | 充电 + 空闲 |
| 平衡 | 3 | 40 | 10,000 | 空闲 + 无重任务 |
| 积极 | 8 | 120 | 20,000 | 空闲，允许更频繁 |

节流规则：

- App 启动后至少 2 分钟不跑归档预读。
- 正在压缩、解压、测试、转换时不跑。
- 用户正在快速浏览目录时只记录 dirty，不跑。
- 单个归档失败后按退避重试。
- 文件 mtime/size 未变化时不重复读取清单。
- 同一目录短时间内多次变动，只合并成一次扫描。

### 索引输出

预读完成后得到：

```json
{
  "schema": "simplezip.ai.archivePrefetchRecord.v1",
  "archiveID": "arch-13f0",
  "archiveName": "SimpleZip-source.zip",
  "scopeID": "scope-downloads",
  "prefetchedAt": "2026-06-15T10:30:00Z",
  "listingStatus": "indexed",
  "entryStats": {
    "visibleEntries": 980,
    "encryptedEntriesOmitted": 0,
    "truncated": false
  },
  "profileTags": ["source-archive", "swift-project"],
  "markerFiles": ["Package.swift", "README.md"],
  "omissions": []
}
```

这些数据可以直接增强：

- AI 工作区：不用等用户打开归档，已经知道哪些包像源码包/发布包。
- 归档记忆查找：能搜到用户还没手动打开过的归档。
- AI Lens：发布/源码/签名视角有更多候选。
- 动态按钮：选中某个归档前，系统已经知道它大概是什么角色。
- 空状态解释：能说明“白名单目录里没有可索引归档”。

### UI 建议

设置页增加：

- `允许后台 AI 预读归档`
- `预读目录白名单`
- `添加目录...`
- `递归扫描`
- `最大深度`
- `允许外置卷`
- `允许网络卷`
- `清空预读索引`
- `最近预读状态`

AI 中心数据页显示：

```text
后台归档预读
  状态：平衡
  白名单目录：3
  已索引归档：128
  上次运行：8 分钟前
  省略加密条目：42
  需要密码的归档：5
  失败归档：2
```

### 安全边界

后台预读必须遵守：

- 不弹密码框；
- 不使用保存的密码；
- 不解密；
- 不提取；
- 不写入归档；
- 不修改缓存以外的任何用户文件；
- 不访问白名单外目录；
- 不索引加密条目名；
- 可随时暂停和清空。

这个功能会显著增强 AI 的“懂文件”能力，而且代价合理：它只是把用户未来可能会打开的归档提前做只读清单索引。

## 工程补充七：后台文件夹和内容预索引

如果 AI 要成为 T0，它不能只懂活动中心和压缩包，也必须懂主窗口普通文件夹。否则用户打开一个目录时，AI 只能看到当前 UI 行，无法“一览”这个文件夹是什么、哪些文件重要、哪些归档/报告/源码/发布材料互相关联。

建议在开启后台 AI 后增加“文件夹预索引”。它和归档预读一样只读、白名单、可取消、可清空，但目标从归档清单扩展到普通文件和安全内容信号。

### 预索引的目标

让 AI 在用户打开某个目录前，已经知道：

- 这个目录像项目、发布目录、下载目录、备份目录还是测试目录；
- 哪些文件是关键文件；
- 哪些文件和归档、任务、报告有关；
- 哪些文件可能是源码、配置、校验、签名、说明文档；
- 哪些目录值得作为 AI 工作区主题；
- 当前文件视图该用什么 Lens 最有用。

这会直接增强：

- 主窗口 AI 工作区；
- AI Lens；
- 动态工具栏推荐；
- AI 搜索重写；
- 归档记忆查找；
- 设置助手里的“为什么 AI 找不到”解释；
- 活动中心和文件系统的关联。

### 能索引什么

默认标准模式可以索引：

- 文件名、扩展名、大小、mtime、UTType；
- 文件夹层级摘要；
- 目录 marker：README、LICENSE、Package.swift、package.json、pyproject.toml、SHA256SUMS、.asc、.app、.dmg、.siz、.szs；
- 文件角色标签：source、document、checksum、signature、installer、archive、media、config、script；
- 位置上下文：location kind、path hash、folder name tokens；
- 与活动中心任务的关系：最近是否创建、测试、解压、转换、失败；
- 与归档索引的关系：这个文件是否是某个归档、是否已有归档画像。

深度本地上下文可以额外索引：

- 安全文本文件的短摘要；
- 文本文件的前几 KB 结构信号；
- manifest/config 的字段名；
- Markdown 标题；
- 代码项目的语言/模块结构；
- 校验文件里的文件名列表摘要；
- release note / changelog 的标题摘要。

对二进制文件默认只索引 metadata，不读内容：

- 图片：尺寸、格式、大小、mtime；
- 视频：格式、大小、mtime，必要时只读系统 metadata；
- app/pkg/dmg：类型、大小、签名/发布相关 marker；
- 大型日志：默认不读内容，除非用户打开诊断场景。

### 永远不索引什么

- 密码、token、secret、private key；
- GPG 密文内容；
- 加密归档条目名和内容；
- 解密后的临时文件；
- Keychain、浏览器配置、系统私密目录；
- `.ssh`、`.gnupg`、`.aws`、`.config` 中可能含密钥的文件；
- 用户未授权目录；
- 超过大小预算的大文件内容；
- 二进制文件原始内容。

### 文件索引结构

建议新增 `AIFileMemoryIndex`：

```swift
struct AIFileMemoryRecord: Codable, Identifiable, Equatable {
    let id: String
    let fileName: String
    let fileExtension: String?
    let type: AIFileType
    let byteSize: Int64?
    let modifiedAt: Date?
    let location: AILocationContext
    let roleTags: [String]
    let markerTags: [String]
    let relatedSourceRefs: [AIContextSourceRef]
    let contentSummary: AIFileContentSummary?
    let omissions: [AIContextOmission]
}

enum AIFileType: String, Codable {
    case folder
    case archive
    case text
    case markdown
    case sourceCode
    case config
    case checksum
    case signature
    case image
    case video
    case audio
    case appBundle
    case diskImage
    case package
    case binary
    case unknown
}

struct AIFileContentSummary: Codable, Equatable {
    let mode: String
    let languageHint: String?
    let headings: [String]
    let fieldNames: [String]
    let shortSummary: String?
    let redactionCount: Int
}
```

目录也需要画像：

```swift
struct AIFolderProfile: Codable, Identifiable, Equatable {
    let id: String
    let displayName: String
    let location: AILocationContext
    let directChildCount: Int
    let totalIndexedDescendants: Int
    let dominantFileTypes: [String]
    let markerFiles: [String]
    let roleTags: [String]
    let relatedArchives: [AIContextSourceRef]
    let relatedTasks: [AIContextSourceRef]
    let suggestedLenses: [String]
    let omissions: [AIContextOmission]
}
```

这样 AI 不只知道“这里有 50 个文件”，而是知道“这是一个 release 目录，里面有 app、dmg、SHA256SUMS、签名文件和一个最近失败的测试任务”。

### 内容摘要策略

深度模式下可以读安全文本内容，但必须预算化：

| 文件类型 | 默认读取 | 摘要方式 |
|---|---:|---|
| README / Markdown | 前 8-16 KB | 标题、首段、链接/代码块计数 |
| package.json / pyproject / Package.swift | 前 16 KB | 字段名、项目名、依赖数量 |
| SHA256SUMS / checksum | 前 16 KB | 条目数量、样本文件名 |
| plist / json / yaml / toml | 前 16 KB | 顶层字段名、结构摘要 |
| 源码 | 前 8 KB | 语言、import、类型/函数名样本 |
| 普通 txt | 前 8 KB | 短摘要，先 redaction |
| log | 默认不读 | 只在诊断场景读错误行 |

所有文本先过 `AISensitiveRedactor`。如果 redaction 命中过多，摘要可直接标记为 `blocked_due_to_sensitive_content`。

### 预索引流程

```text
AIFilePrefetchScheduler
  → 读取白名单目录
  → 枚举文件和子目录
  → 应用排除规则与预算
  → 建立 AIFolderProfile
  → 建立 AIFileMemoryRecord
  → 对归档文件触发 AIArchivePrefetchScheduler
  → 深度模式下读取安全文本 marker 摘要
  → 写入 AIFileMemoryIndex
  → 更新 AI Workspace / Lens / Search 候选
```

归档文件和普通文件索引应该互相连接：

- 普通文件索引发现 `.zip/.7z/.siz/.szs`，交给归档预读；
- 归档预读得到角色后，回写到文件 record 的 `relatedSourceRefs`；
- 活动中心任务完成后，更新相关文件 record 的 task refs；
- AI 工作区读取同一个 source ref graph。

### 白名单和排除规则

文件夹预索引和归档预读共用白名单，但可以有单独开关。

默认建议：

- Downloads：只索引第一层和最近 30-90 天文件；
- Desktop：索引第一层和用户固定子目录；
- Documents：默认不递归，除非用户加入具体目录；
- 固定路径：按用户设置；
- 项目目录：识别到 marker 后可建议加入白名单；
- 外置盘/网络卷：默认关闭。

默认排除：

- 隐藏系统目录；
- `.git`、`.svn`、`.hg`；
- `node_modules`、`.build`、`DerivedData`、`target`、`dist`、`build`；
- `Library`、Caches、Containers；
- `.ssh`、`.gnupg`、`.aws`、`.kube`；
- 临时解密目录；
- 大于阈值的大文件内容。

### 预算

| 档位 | 每轮目录 | 每轮文件 | 文本摘要 | 最大深度 |
|---|---:|---:|---:|---:|
| 省电 | 1 | 200 | 20 个 | 1 |
| 平衡 | 3 | 1,000 | 80 个 | 2 |
| 积极 | 8 | 5,000 | 300 个 | 4 |

预算超限时写 omissions：

```json
{
  "type": "folder_files_truncated",
  "count": 4200,
  "policy": "background_prefetch_budget"
}
```

### UI 建议

设置页增加：

- `允许后台 AI 预索引文件夹`
- `索引普通文件元数据`
- `索引安全文本摘要`
- `索引源码/配置 marker`
- `最大目录深度`
- `排除隐藏目录`
- `排除开发依赖目录`
- `管理白名单目录`
- `清空文件预索引`

AI 中心显示：

```text
后台文件预索引
  白名单目录：4
  已索引文件：12,840
  已索引文件夹：560
  文本摘要：214
  已跳过敏感内容：7
  已跳过大文件：48
  上次运行：5 分钟前
```

### 对主窗口文件视图的价值

有了文件夹预索引，主窗口可以做到：

- 打开目录时立刻显示 AI Lens；
- 侧边栏推荐“这个目录像发布目录 / 源码目录 / 测试目录”；
- 工具栏推荐更合理；
- AI 工作区能混合普通文件、归档内部条目、任务、报告；
- 搜索“那个校验文件”“源码包旁边的签名”不再只靠文件名；
- 空状态能解释“这个目录未加入预索引白名单”。

这个功能是让 AI 真正看懂用户文件视图的关键。归档预读让 AI 懂压缩包；文件夹预索引让 AI 懂用户当前工作空间。

### 预索引如何喂给 AI 工作虚拟目录

后台归档预读和文件夹预索引的核心消费者之一，应该就是“自动生成 AI 工作虚拟目录”。否则预索引只是一个搜索缓存，价值没有完全释放。

建议数据流：

```text
AIArchivePrefetchScheduler
  → ArchiveListingCacheStore
  → ArchiveMemoryIndex
  → ArchiveProfile / ArchiveRole
          │
          ├── AIWorkspaceThemeCandidate
          └── AIVirtualNodeCandidate

AIFilePrefetchScheduler
  → AIFileMemoryIndex
  → AIFolderProfile
          │
          ├── AIWorkspaceThemeCandidate
          └── AIVirtualNodeCandidate

ActivityTaskAIIndex / Reports / Feedback
          │
          ├── AIWorkspaceThemeCandidate
          └── AIVirtualNodeCandidate

AIWorkspaceThemeEngine
  → 推荐工作区主题

AIVirtualFolderTreeEngine
  → 工作区虚拟目录树
```

也就是说，后台预索引得到的文件夹画像、普通文件记录、归档画像、归档内部条目、活动任务和报告，都应该进入同一个候选池。AI 工作区不是只读活动中心，也不是只读归档缓存，而是读“本机工作空间图谱”。

候选模型建议：

```swift
struct AIWorkspaceThemeCandidate: Codable, Equatable {
    let id: String
    let titleSeed: String
    let themeTokens: [String]
    let sourceRefs: [AIContextSourceRef]
    let scoreSignals: [String]
    let evidence: [AIEvidenceFact]
}

struct AIVirtualNodeCandidate: Codable, Equatable {
    let id: String
    let kind: AIVirtualNode.Kind
    let displayName: String
    let sourceRefs: [AIContextSourceRef]
    let roleTags: [String]
    let location: AILocationContext?
    let relatedTaskIDs: [String]
    let relatedArchiveIDs: [String]
    let scoreSignals: [String]
    let evidence: [AIEvidenceFact]
}
```

候选来源：

- `AIFolderProfile` 产生主题候选，例如“发布目录”“源码目录”“SIZ/SZS 测试目录”。
- `AIFileMemoryRecord` 产生普通文件节点，例如 README、SHA256SUMS、signature.asc、Package.swift、dmg、app。
- `ArchiveMemoryRecord` 产生归档节点，例如 source package、release artifact、signed container。
- `ArchiveProfile` 产生归档内部条目节点，例如 `metadata.json`、`signature.asc`、`Package.swift`。
- `AITaskRecord` 产生任务节点，例如最近失败、可重跑、checksum mismatch。
- 报告 facts 产生报告节点，例如发布检查报告、hash 报告、diff 报告。
- `AIFeedbackStore` 影响主题和节点评分。

### 自动生成工作区主题的评分

后台生成推荐工作区时，不要让 AI 从零想主题。先由 App 从预索引数据生成候选主题，再让 AI 命名和排序。

评分信号：

- 文件夹 role：release/source/test/backup/signed/config。
- 文件夹 marker：README、Package.swift、SHA256SUMS、signature.asc、.siz、.szs、.gpg。
- 归档角色：release-package、source-package、signed-container、test-fixture。
- 活动中心关系：最近失败、最近测试、最近创建、可重跑。
- 路径信号：当前目录、固定路径、最近打开目录、白名单目录。
- 用户反馈：用户常打开/常关闭/点过不感兴趣。
- 新鲜度：最近修改、最近预索引、最近任务关联。
- 密度：同一主题下文件/归档/任务数量是否足够。

示例候选：

```json
{
  "schema": "simplezip.ai.workspaceThemeCandidate.v1",
  "id": "theme-release-current-folder",
  "titleSeed": "release verification",
  "themeTokens": ["release", "checksum", "signature"],
  "scoreSignals": [
    "folderRole=release",
    "marker=SHA256SUMS",
    "marker=signature.asc",
    "archiveRole=release-package",
    "taskTag=checksum-mismatch"
  ],
  "sourceRefs": [
    {"type":"folder","id":"folder-release"},
    {"type":"archive","id":"arch-release"},
    {"type":"task","id":"task-7B2F"}
  ]
}
```

AI 只负责把这个候选命名成人话：

```json
{
  "title": "发布校验工作区",
  "subtitle": "发布包、校验文件、签名和失败任务",
  "reason": "这个目录同时包含 SHA256SUMS、签名文件、发布归档和校验失败任务。"
}
```

### 自动生成虚拟目录树

当用户打开一个推荐工作区时，`AIVirtualFolderTreeEngine` 读取同一批候选，生成树。

示例：

```text
发布校验工作区
  ▾ 发布产物
      SimpleZip.dmg
      SimpleZip.app
      release-assets.7z
  ▾ 校验和签名
      SHA256SUMS
      signature.asc
      release-assets.7z/signature.asc
  ▾ 最近任务
      Test release-assets.7z failed
      Release inspection report
  ▾ 下一步
      重新测试 release-assets.7z
      生成 VERIFY.md 草稿
```

虚拟树节点可以来自不同源：

- 普通文件：`AIFileMemoryRecord`
- 文件夹：`AIFolderProfile`
- 归档：`ArchiveMemoryRecord`
- 归档内部条目：`ArchiveListingCacheEntry`
- 活动任务：`AITaskRecord`
- 报告：`TaskReportAttachment`
- 动作卡：`NextActionCard`

App 必须校验每个节点的 source ref。AI 可以决定分组标题和排序，但不能发明节点。

### 触发时机

适合触发自动工作区候选生成：

- 白名单目录预索引完成；
- 归档预读完成；
- 活动中心出现新的失败任务；
- 用户打开某目录超过一定时间；
- 用户固定某路径；
- 用户关闭某推荐主题；
- 习惯摘要更新。

触发后只标记 dirty，由 `AIBackgroundScheduler` 在低负载时生成推荐主题和虚拟树缓存。

### UI 表现

侧边栏推荐工作区应该明确来自预索引：

```text
推荐：发布校验工作区        x
推荐：源码包与本地化文件    x
推荐：SIZ/SZS 测试目录      x
```

hover 或证据卡里显示：

```text
来自后台预索引：
  - 当前目录包含 SHA256SUMS 和 signature.asc
  - 发现 2 个 release-package 归档
  - 最近有 1 个 checksum-mismatch 任务
```

这样用户能理解：AI 不是凭空推荐，而是从后台预读和预索引事实里生成了一个虚拟工作目录。

## 工程补充八：用户兴趣事件、打开时间和 Spotlight 联动

AI 要更懂用户，不能只记录“有什么文件”，还要记录“用户如何接触这些文件”。用户打开一个归档、进入一个文件夹、点击 Spotlight 结果、打开后立刻做了什么，都是非常强的兴趣信号。它们应该进入本地 AI 数据集，作为 AI 工作区、Lens、动作推荐、后台预索引优先级的核心输入。

这不是监控文件内容，而是记录 App 内部已经发生的交互事实：打开时间、停留时长、第一反应、后续动作、来源入口。全部本地、可清空、可关闭。

### 应记录的事件

当前 `SimpleZip/Core/AIUserInterestEvent.swift` 已经有 `AIUserInterestEvent`、`AIInterestClassifier`、`AIInterestAggregator`。所以施工重点不是再新增一个平行模型，而是把 App 里的真实导航、归档打开、Spotlight 点击、第一反应写入这个已有 Core 模型。

现有结构已经基本够用：

```swift
struct AIUserInterestEvent: Codable, Identifiable, Equatable {
    enum TargetKind: String, Codable {
        case folder
        case file
        case archive
        case archiveEntry
        case task
        case report
        case workspace
        case spotlightResult
    }

    enum Source: String, Codable {
        case sidebar
        case locationBar
        case fileTable
        case archiveTable
        case dragDrop
        case finderOpen
        case spotlight
        case shortcuts
        case activityCenter
        case aiWorkspace
        case recentHistory
    }

    enum FirstReaction: String, Codable {
        case stayed
        case closedQuickly
        case searched
        case openedArchive
        case openedArchiveEntry
        case extracted
        case tested
        case converted
        case inspectedRelease
        case viewedReport
        case usedAIExplanation
        case createdWorkspace
        case revealedInFinder
        case noAction
    }

    let id: UUID
    let targetKind: TargetKind
    let sourceRef: AIContextSourceRef
    let source: Source
    let openedAt: Date
    let closedAt: Date?
    let dwellSeconds: Int?
    let firstReaction: FirstReaction?
    let timeToFirstReactionSeconds: Int?
    let contextLocation: AILocationContext?
    let visibleRoleTags: [String]
    let evidenceTokens: [String]
}
```

记录目标：

- 用户什么时候打开了一个文件夹；
- 用户什么时候打开了一个归档；
- 是否从 Spotlight 打开；
- 是否从 Finder / Shortcuts / 活动中心 / AI 工作区打开；
- 打开后几秒内做了什么；
- 是否马上关闭；
- 是否搜索、测试、解压、发布检查、看报告、点 AI 解释；
- 是否从归档内部条目跳转；
- 是否在同一主题下反复打开相似文件。

注意：文件夹访问记录只能在真实导航入口写入，例如 `openFolder(_:recordsHistory:)`，不要在每次 `loadFolder` / FSEvents reload 都写。`AIUserInterestEvent.swift` 的注释已经明确提醒这个路径不能走会频繁变动的 `@Published` 状态，否则会重新引入菜单和命令树频繁刷新的问题。

### “第一反应”怎么定义

打开对象后，App 可以在一个短窗口内观察用户第一步动作。建议：

- `quickCloseWindow`：10 秒内离开或关闭，且没有任何动作；
- `firstReactionWindow`：打开后 2 分钟内的第一个有意义动作；
- `dwellWindow`：超过 30 秒仍停留，记为 `stayed`；
- 如果用户先搜索，再打开条目，则第一反应是 `searched`，后续动作作为 sequence 记录到聚合里。

例子：

```json
{
  "schema": "simplezip.ai.interestEvent.v1",
  "targetKind": "archive",
  "sourceRef": {"type":"archive","id":"arch-release"},
  "source": "spotlight",
  "openedAt": "2026-06-15T10:30:00Z",
  "dwellSeconds": 96,
  "firstReaction": "tested",
  "timeToFirstReactionSeconds": 12,
  "visibleRoleTags": ["release-package"],
  "evidenceTokens": ["release", "checksum", "spotlight"]
}
```

这条事件告诉 AI：用户从 Spotlight 打开 release 包后，第一反应是测试。以后类似 Spotlight 命中的 release 包，工具栏和 AI 工作区就应该更积极推荐“测试/发布检查”，而不是泛泛推荐“转换格式”。

### 打开时间为什么重要

时间信号可以形成更细的偏好：

- 用户早上经常打开某项目目录；
- 用户最近 7 天反复打开某 release 文件夹；
- 用户打开某类归档后总是马上测试；
- 用户打开某类归档后总是马上搜索内部文件；
- 用户打开某类推荐工作区后立刻关闭，说明主题不感兴趣；
- 用户从 Spotlight 打开归档内部文件，说明该条目和归档值得提高权重。

这些信号比单纯点击次数更有价值。

### Spotlight 必须双向联动

当前代码里 `CachedArchiveEntity`、`ArchiveFileEntity`、`CachedArchiveSpotlightIndexer`、`ArchiveFileSpotlightIndexer` 已经把打开过的归档和归档内非加密文件喂给 Spotlight。后台归档预读会让 `ArchiveListingCacheStore` 里出现更多可索引归档，因此必须和 Spotlight 联动。

建议规则：

- 后台归档预读成功写入 `ArchiveListingCacheStore` 后，如果 Spotlight 总开关和归档缓存开关都开启，就调用现有增量索引：
  - `CachedArchiveSpotlightIndexer.indexArchive(at:)`
  - `ArchiveFileSpotlightIndexer.indexArchive(at:)`
- 后台预读清空或某归档失效时，同步清 Spotlight 对应 domain。
- `SpotlightReindex.stats()` 增加区分：用户打开索引数量、后台预读索引数量、逐文件条目数量。
- Spotlight 点击结果时，`SpotlightTapDispatcher` 写入 `AIUserInterestEvent(source: .spotlight)`。
- 从 Spotlight 打开归档内文件时，记录 targetKind = `archiveEntry`，sourceRef 指向 archive entry。

这形成闭环：

```text
后台归档预读
  → ArchiveListingCacheStore
  → Spotlight archive/file index
  → 用户从 Spotlight 打开
  → AIUserInterestEvent(source=spotlight)
  → AIFeedback / habit summary / action ranker
  → 更好的 AI 工作区和工具栏推荐
```

### 打开文件夹也要写入数据集

`ArchiveBrowserModel.loadFolder(_:)` / `applyLoadedFolder(_:)` 这类路径应该成为 AI 数据入口。用户进入某个文件夹本身就是兴趣表达。

建议在文件夹加载成功后记录：

```json
{
  "schema": "simplezip.ai.folderVisit.v1",
  "sourceRef": {"type":"folder","id":"folder-loc-9d1a3f20"},
  "openedAt": "2026-06-15T10:30:00Z",
  "source": "sidebar",
  "location": {
    "kind": "project-folder",
    "pathHash": "loc-9d1a3f20",
    "folderNameTokens": ["release", "simplezip"]
  },
  "visibleSummary": {
    "fileCount": 42,
    "archiveCount": 8,
    "markerFiles": ["README.md", "SHA256SUMS"],
    "dominantExtensions": ["zip", "dmg", "asc"]
  }
}
```

文件夹访问事件可以驱动：

- 后台文件预索引优先级；
- 推荐工作区主题；
- AI Lens 默认视角；
- 工具栏动作排序；
- “常用项目目录”识别；
- “这个目录你通常先做什么”提示。

### 打开归档也要写入数据集

`updateArchiveListingCache(for:items:url:)` 现在已经写 `ArchiveListingCacheStore` 并同步 Spotlight，这是非常好的入口。建议同时写 AI interest event 和 archive open session：

```swift
struct AIArchiveOpenSession: Codable, Equatable {
    let archiveID: String
    let openedAt: Date
    let source: AIUserInterestEvent.Source
    let profileTags: [String]
    let entryCount: Int
    let encryptedEntriesOmitted: Int
    let firstReaction: AIUserInterestEvent.FirstReaction?
    let dwellSeconds: Int?
}
```

打开归档后第一反应可以这样解释：

- 立刻搜索归档内文件：这个归档常用于查找。
- 立刻测试：这个归档可能是发布/校验对象。
- 立刻解压：这个归档是消费型内容。
- 立刻打开报告/安全扫描：这个归档可能需要审计。
- 立刻关闭：这类推荐可能不准，降权。

### 数据如何进入推荐

`AIUserInterestEvent` 应进入：

- `AIFeedbackAggregator`：作为隐式正/负反馈。
- `AIHabitSummaryStore`：生成“用户打开 release 包后常先测试”这类 hints。
- `ContextualActionRanker`：动作推荐排序。
- `AIWorkspaceThemeEngine`：推荐工作区主题。
- `AIBackgroundScheduler`：决定预索引哪些目录/归档。
- `ArchiveRoleClassifier`：结合用户行为修正角色。

示例 prompt hint：

```json
{
  "behaviorHints": [
    "When opening release-package archives from Spotlight, the user usually tests them first.",
    "The user often searches inside source-package archives instead of extracting them.",
    "The user often closes downloads-cleanup recommended workspaces quickly."
  ]
}
```

### 隐私边界

用户兴趣事件默认不保存完整路径，保存：

- source ref；
- location kind；
- path hash；
- folder name tokens；
- role tags；
- action token；
- 时间和停留时长。

当次上下文可以使用完整当前路径；长期兴趣事件默认不保存完整路径。用户开启深度本地上下文和固定路径别名后，可以把固定目录保存为用户可见别名。

## 工程补充九：基于时间习惯的智能启动目录

用户提到“晚上喜欢打开什么文件夹、喜欢做什么，能不能扩展默认打开目录”，这是一个很适合本地 AI 的功能。它不需要模型知道世界知识，只需要本机习惯事件、时间段、最近项目和当前可用路径。

当前代码已经有启动目录底座：

- `SimpleZip/Core/AppPreferences.swift` 里有 `StartupLocation`，包括 home、downloads、desktop、documents、lastFolder、custom。
- `AppPreferences.defaultStartupURL(fileManager:)` 是启动时真正解析默认目录的位置。
- `ArchiveBrowserModel.init` 里通过 `mode = .folder(AppPreferences.defaultStartupURL(...))` 进入初始目录。
- `ArchiveBrowserModel+Navigation.swift` 的 `openFolder(_:recordsHistory:)` 已经调用 `AppPreferences.rememberLastFolder(url)`。
- `GeneralPane.swift` 已经有启动目录设置 UI、custom history、路径存在性校验。
- `Sidebar.swift` 已经展示 pinned/recent/sidebar favorites，可作为候选来源。

所以这个功能不应该另起一套“AI 启动页”，而应该扩展现有启动目录体系。

### 建议行为

新增一个启动选项：

```swift
enum AIStartupSuggestionMode: String, Codable, CaseIterable {
    case off
    case suggestOnly
    case openBestMatch
    case openWorkspace
}
```

含义：

- `off`：保持现有启动目录逻辑。
- `suggestOnly`：仍打开现有启动目录，但启动后在侧边栏/状态栏显示“今晚常用目录”建议。
- `openBestMatch`：从已授权、已访问、仍存在的候选目录中打开最匹配的目录。
- `openWorkspace`：打开最匹配的 AI 虚拟工作区，而不是直接打开真实目录。

建议不要把 `StartupLocation` 直接改成一个很复杂的 AI enum。更稳的施工方式是保留现有 `startupLocation`，新增一个独立设置 `aiStartupSuggestionMode`。这样不会破坏欢迎页、健康检查、设置备份、Shortcuts 设置实体和已有用户配置。

### 候选目录来源

智能启动只能在“用户已经给过 App 上下文”的范围里选，不应该扫描任意陌生目录。

候选集合：

- `StartupLocation` 当前解析出的目录；
- `rememberLastFolder` 的 last folder；
- `startupCustomLocationHistory`；
- `pinnedSidebarPaths`；
- `recentSidebarPaths`；
- Finder fallback favorites：Home、Downloads、Desktop、Documents、Applications；
- AI 预索引白名单目录；
- 用户创建的 AI 工作区绑定目录；
- 最近从 Spotlight/Shortcuts/Finder 打开的归档所在目录。

硬规则：

- 不打开不存在的路径，沿用 `startupLocationIsMissing`/HealthCheck 风格提示。
- 不打开系统临时目录、解密临时目录、`.gpg`/加密卷展开目录。
- 不因为 AI 推荐而自动进入未访问过、未授权、未加入白名单的目录。
- `suggestOnly` 应该是默认推荐模式；`openBestMatch` 必须由用户明确打开。

### 时间习惯数据格式

建议把兴趣事件聚合成小上下文，而不是每次启动喂长历史：

```json
{
  "schema": "simplezip.ai.startupHabitSummary.v1",
  "generatedAt": "2026-06-15T14:00:00Z",
  "localTimeBucket": "night",
  "weekdayBucket": "weekday",
  "candidateFolders": [
    {
      "sourceRef": {"type":"folder","id":"folder-release-work"},
      "locationKind": "project-folder",
      "displayAlias": "SimpleZip release",
      "pathHash": "loc-9d1a3f20",
      "folderNameTokens": ["simplezip", "release"],
      "visitsInSameBucket30d": 12,
      "medianDwellSeconds": 840,
      "topFirstReactions": ["tested", "inspectedRelease", "openedArchive"],
      "relatedArchiveRoles": ["release-package", "signed-container"],
      "lastOpenedAt": "2026-06-14T15:20:00Z",
      "negativeSignals": []
    },
    {
      "sourceRef": {"type":"folder","id":"folder-downloads"},
      "locationKind": "downloads",
      "displayAlias": "Downloads",
      "pathHash": "loc-downloads",
      "folderNameTokens": ["downloads"],
      "visitsInSameBucket30d": 4,
      "medianDwellSeconds": 120,
      "topFirstReactions": ["extracted", "closedQuickly"],
      "relatedArchiveRoles": ["consumer-archive"],
      "lastOpenedAt": "2026-06-13T13:00:00Z",
      "negativeSignals": ["quick-close-after-ai-suggestion"]
    }
  ],
  "currentContext": {
    "lastStartupLocation": "home",
    "lastOpenedFolderHash": "loc-9d1a3f20",
    "aiStartupMode": "suggestOnly"
  }
}
```

给模型的任务应该很小：

```json
{
  "schema": "simplezip.ai.startupSuggestion.input.v1",
  "task": "rank_startup_candidates",
  "timeBucket": "night",
  "candidates": [
    {
      "id": "folder-release-work",
      "alias": "SimpleZip release",
      "signals": ["12 visits in night bucket", "tested after open", "release-package archives"]
    },
    {
      "id": "folder-downloads",
      "alias": "Downloads",
      "signals": ["4 visits", "often quick closed"]
    }
  ],
  "allowedActions": ["suggestOpenFolder", "suggestOpenWorkspace", "doNothing"]
}
```

输出：

```json
{
  "schema": "simplezip.ai.startupSuggestion.output.v1",
  "choice": {
    "candidateID": "folder-release-work",
    "action": "suggestOpenWorkspace",
    "confidence": 0.78,
    "title": "今晚继续发布校验",
    "reason": "最近晚上常打开这个目录，并且第一步通常是测试和发布检查。"
  },
  "fallback": "useConfiguredStartupLocation"
}
```

真正打开目录时，App 只接受 `candidateID`，再由本地候选表回查 URL。AI 不允许直接返回路径字符串并被执行。

### 施工落点

- `AIUserInterestEventStore`：接收 `openFolder`、`openArchive`、Spotlight tap、侧边栏点击、活动中心跳转事件。
- `AIStartupHabitSummaryStore`：后台低负载把事件折叠为 time bucket summary。
- `AIStartupDirectoryRanker`：确定性先打分，Apple 本地模型只负责相近候选的解释和标题。
- `AppPreferences`：新增 `aiStartupSuggestionMode`、`aiStartupSuggestionEnabled`、`aiStartupLastDismissedCandidateIDs`，并按 A21 注册到设置备份 surface。
- `GeneralPane`：在现有启动目录设置下面加一行 AI 智能启动模式，使用 `SettingsControlRow`/`SettingsToggleRow`，新增文本必须写 `en.lproj` 和 `zh-Hans.lproj`。
- `ContentView`/`ArchiveBrowserModel.init`：启动时先算 `defaultStartupURL`，再按 `AIStartupSuggestionMode` 决定是打开配置目录、显示建议卡，还是打开 AI workspace。
- `HealthCheck`：如果智能启动候选不可达，显示“AI 启动建议已回落到配置目录”。

UI 示例：

```text
启动位置           个人文件夹
AI 智能启动        只建议，不自动切换
今晚建议           发布校验工作区     打开   不感兴趣
```

这个功能会让 SimpleZip 显得“懂用户”：晚上打开 release 工作目录、周末打开下载清理、工作日早上打开项目归档，不需要云端大模型，只需要本地事件和严格候选回查。

## 工程补充十：全局 AI Suggestion Bus，让任何地方都能接 AI 建议

现在代码里的 AI 入口比较分散：`AIGate`/`AIAssistButton` 控制可见性，`AIReportAssistant` 负责 FoundationModels 调用，活动中心、设置、创建/解压表单、报告解释、归档查找各自接自己的 AI。下一步应该把“哪里需要建议”和“怎么生成建议”分开，做一个全局 AI Suggestion Bus。

目标不是让每个 view 都直接调用模型，而是让每个 surface 提供上下文，统一拿回可验证、可解释、可忽略的建议卡。

### 核心模型

```swift
enum AISuggestionSurfaceID: String, Codable, CaseIterable {
    case mainToolbar
    case sidebar
    case locationBar
    case folderTableEmptyState
    case folderSelection
    case archiveTableEmptyState
    case archiveSelection
    case contextMenu
    case statusBar
    case activityCenter
    case activityTaskRow
    case settingsPane
    case createDialog
    case extractDialog
    case reportView
    case archiveFinder
    case spotlightOpen
    case welcome
}

struct AISuggestionRequest: Codable, Equatable {
    let surfaceID: AISuggestionSurfaceID
    let purpose: AIContextPurpose
    let currentMode: String
    let sourceRefs: [AIContextSourceRef]
    let visibleFacts: [String: String]
    let candidateActions: [AISuggestionAction]
    let budget: AIBudget
    let contextMode: AIContextMode
}

struct AISuggestionCard: Codable, Identifiable, Equatable {
    let id: String
    let surfaceID: AISuggestionSurfaceID
    let title: String
    let body: String
    let priority: Int
    let action: AISuggestionAction?
    let secondaryActions: [AISuggestionAction]
    let evidence: [AIEvidenceCard]
    let dismissBehavior: DismissBehavior
    let safety: AISuggestionSafety

    enum DismissBehavior: String, Codable {
        case sessionOnly
        case notInterested
        case neverForThisTarget
    }
}
```

### Provider 分层

```swift
protocol AISuggestionProvider {
    var supportedSurfaces: Set<AISuggestionSurfaceID> { get }
    func deterministicSuggestions(_ request: AISuggestionRequest) async -> [AISuggestionCard]
    func generativeRefinement(_ cards: [AISuggestionCard], request: AISuggestionRequest) async -> [AISuggestionCard]
}
```

建议第一批 provider：

- `ToolbarSuggestionProvider`：替代 `ContextualToolbarButtons` 里固定 `switch model.mode` 的双按钮逻辑。
- `SidebarWorkspaceSuggestionProvider`：生成 AI 虚拟工作区、推荐主题、不感兴趣反馈。
- `StartupSuggestionProvider`：读取 time bucket habit summary。
- `ArchiveLensSuggestionProvider`：在归档/文件夹上下文生成 Lens 和下一步动作。
- `ActivitySuggestionProvider`：活动中心失败、排队、历史相似任务建议。
- `SettingsSuggestionProvider`：设置页 state-aware 建议。
- `SpotlightSuggestionProvider`：从 Spotlight 打开后给“测试/定位/建立工作区”等建议。
- `CreateExtractSuggestionProvider`：创建/解压表单内联建议。

### 各 surface 该给什么数据

| Surface | 现有代码落点 | 给 AI 的数据 | 返回什么 |
|---|---|---|---|
| 主工具栏 | `ContentView.ContextualToolbarButtons` | mode、selection、archive profile、recent first reaction、候选动作枚举 | 2-3 个 action cards |
| 侧边栏 | `Sidebar.swift` | pinned/recent、AI workspace、time bucket、not interested | 推荐工作区、智能启动提示 |
| 地址栏 | `LocationBar.swift` | 当前 URL、completion tokens、location context | “这个目录像发布目录/测试目录” |
| 文件列表空态 | folder view | 当前目录摘要、预索引状态、最近访问 | 建议打开归档/启用预索引/创建工作区 |
| 文件选择 | folder table selection | 文件扩展名、大小、role、是否归档、是否分卷 | 测试/转换/发布检查/批处理规划 |
| 归档列表 | archive browser | archive profile、entry samples、marker files、风险 hints | 搜索、保存副本、看安全报告、Lens |
| 右键菜单 | file/archive context menu | 单个 source ref、合法动作 | 低噪声建议动作 |
| 状态栏 | `StatusBar` | 后台索引、AI 调度、当前任务 | 轻提示，不抢焦点 |
| 活动中心 | `ActivityView` | `ActivityTaskAIIndex`、失败 tag、队列状态 | 筛选、修复手册、相似任务 |
| 设置页 | `SettingsView`/`GeneralPane` | 设置 snapshot、health check、用户意图 | 设置搜索、配置建议 |
| Spotlight 打开 | `SpotlightTapDispatcher` | spotlight target、entry/archive id、来源 | 打开后下一步建议和兴趣事件 |

### 安全规则

- Suggestion Bus 只能输出 App 预定义 action enum，不能输出 shell command、任意路径操作、任意 URL 打开。
- 每张卡都必须有 `sourceRefs` 或明确说明来自全局设置/习惯摘要。
- destructive action 只能作为“打开确认流程”，不能直接执行。
- `AIGate` 不应该让整个 AI section 消失；它应该 gate 生成式增强。确定性 suggestion surface 即使模型不可用也要显示。
- `AIContextSourceRefValidator` 是所有卡片显示前的必经步骤。
- 所有 dismiss/not interested 都写 `AIFeedbackEvent`，作为下一次排序输入。

### 施工方式

先不要一次性重写所有 UI。最小可落地顺序：

1. 新增 `AISuggestionRequest`、`AISuggestionCard`、`AISuggestionProviderRegistry`，只接 `mainToolbar`。
2. 把 `ContextualToolbarButtons` 当前硬编码逻辑搬成 `ToolbarSuggestionProvider.deterministicSuggestions`，UI 外观保持不变。
3. 给 provider 输入 `AIUserInterestEvent` 聚合结果，让 zip/siz/szs 不再只有固定两个按钮。
4. 接入 `sidebar`，生成 AI 工作区和智能启动建议。
5. 接入 `activityCenter` 和 `settingsPane`，统一证据卡和 feedback。
6. 最后让 `AIReportAssistant` 只做 generative refinement，不再成为业务入口。

这能避免“AI 到处散落”的技术债，也能实现“任何地方都可以接入 AI suggestion”。

## 工程补充十一：当前代码和 git 历史审计后的实际施工切分

这份方案不是从空白项目想象出来的。当前 git 历史显示，#80 已经把 AI 从“单个按钮调用模型”推进到了 Core 数据层：

- `30a6926b` 已经建立 `AIContextEnvelope` / privacy level / omissions / evidence / source refs。
- `18e1db3f`、`9576e93f`、`add5edab`、`2317c661` 已经反复加固 `AISensitiveRedactor` 和消费端隐私，说明后续所有新增数据都应该走同一红线。
- `f1df9088`、`7b3d93e9` 已经建立 `AIBudget` 和深度预算，后台预读和深上下文不需要另造预算体系。
- `aa7f196c` 已经有 `AIContextSourceRefValidator`，虚拟文件夹/建议卡/动作卡都必须回查 source ref。
- `c51a81b8` 已经有 `ActivityTaskAIIndex`，活动中心 AI 工作台应该扩展这个 index，而不是让 view 拼 prompt。
- `e92beaae`、`50171109`、`520b5e11` 已经有 `ArchiveMemoryIndex`、`ArchiveProfile`、`ArchiveRoleClassifier`，归档查找和工具栏推荐应该读这些派生事实。
- `55b515bf` 已经有 `AIWorkspaceQueryPlan` + deterministic executor，用户 prompt 创建虚拟工作区应该输出 query plan，而不是输出路径数组。
- `e91aea0d` 已经有 `AIFeedbackEvent` / aggregator，推荐主题关闭、不感兴趣、第一反应、纠错都应该落到这里。
- `AIFeedbackEvent`、`AIFeedbackAggregator` 已经存在，适合接“用户不感兴趣”“第一反应”“纠错”等反馈。
- `AIWorkspaceQueryPlan` 和确定性 executor 已经存在，说明 AI 工作区应该走 query plan，而不是模型直接吐文件列表。
- `ArchiveRoleClassifier`、`ArchiveProfile` 已经存在，适合支撑角色识别、AI Lens、工具栏排序。
- `AIContextEnvelope`、`AIContextSourceRefValidator`、`AIBudget`、`AISensitiveRedactor` 已经存在，说明安全/预算/证据链应该继续沿这条路扩展。
- `ActivityTaskAIIndex` 已经把任务压成 AI facts，活动中心 AI 筛选不缺模型，缺的是更丰富的数据源和 UI 侧边栏。
- `ArchiveMemoryIndex` 已经能从归档清单生成 `ArchiveMemoryRecord`，归档查找应该升级为语义查询计划 + 角色/marker 检索。

当前真正缺的不是“再加一个 AI 调用”，而是三类胶水：

### 1. 写入胶水：把真实用户行为写成数据集

现有入口：

- `ArchiveBrowserModel+Navigation.openFolder`：写 folder visit / startup habit / source = sidebar/location/history。
- `ArchiveBrowserModel+Loading.updateArchiveListingCache`：写 archive open session / archive profile / Spotlight index / AI interest event。
- `SpotlightTapDispatcher.handle`：写 source = spotlight 的 interest event。
- `ActivityView` 的任务点击、筛选、查看报告：写 task interest event。
- `AIAssistSheet`、Inline AI advisory、settings search：写 explicit feedback。

新增 store：

```swift
struct AIInteractionDatasetStore {
    func recordInterest(_ event: AIUserInterestEvent)
    func recordArchiveOpen(_ session: AIArchiveOpenSession)
    func recordSuggestionFeedback(_ event: AIFeedbackEvent)
    func summarize(for purpose: AIContextPurpose, now: Date) -> AIContextEnvelope
}
```

### 2. 召回胶水：让各 AI 场景读同一套事实

现有可复用数据：

- `ArchiveListingCacheStore`：打开过/预读过归档的非加密条目。
- `ArchiveMemoryIndex`：归档角色、marker、样本路径、风险 hints。
- `ActivityTaskAIIndex`：任务状态、失败 tag、文件摘要。
- `AppPreferences`/`SettingEntity`：设置状态和设置搜索目录。
- `AIFeedbackAggregator`：用户纠错和不感兴趣。
- `SpotlightReindex.stats()`：索引覆盖率。

建议新增 `AIContextAssembler`：

```swift
struct AIContextAssembler {
    func envelope(
        purpose: AIContextPurpose,
        surface: AISuggestionSurfaceID,
        sourceRefs: [AIContextSourceRef],
        mode: AIContextMode,
        budget: AIBudget
    ) async -> AIContextEnvelope
}
```

所有场景都从 assembler 拿数据。活动中心、归档查找、设置搜索、工具栏、AI 工作区不要各自重新扫目录、拼 prompt、做 redaction。

### 3. 显示胶水：让 AI 建议进入主流程

现有 UI 落点：

- `ContentView.ContextualToolbarButtons`：最适合第一步接 `AISuggestionBus`。
- `Sidebar.swift`：接 AI section、AI 工作区、智能启动建议。
- `ActivityView`：把 AI button 升级为右侧 workbench/inspector。
- `ArchiveFinderSheet`：从 keyword search 升级为 archive memory query。
- `SettingsView`/`GeneralPane`：接设置 AI 搜索和智能启动设置。
- `StatusBar`：显示后台 AI 索引/预读/低负载状态。

施工原则：

- 先让 provider 返回确定性卡片，保持现有 UI 外观和动作。
- 再加入 Apple 本地模型做标题、解释、排序。
- 最后再扩展到 AI 中心和虚拟文件夹。
- 每一步都必须可关闭、可清空、可解释。

## 工程补充十二：失败降级矩阵

每个 AI 场景都必须有确定性 fallback。AI 失败不能让功能不可用。

| 失败类型 | 处理方式 | 用户看到 |
|---|---|---|
| FoundationModels 不可用 | 使用确定性建议/搜索/排序 | “AI 不可用，显示基础建议” |
| 用户关闭 AI 总开关 | 隐藏 AI 入口或显示关闭说明 | 设置入口可重新开启 |
| prompt 超预算 | 本地召回后截断，写 omissions | 结果仍显示，证据里说明已截断 |
| JSON 解析失败 | 丢弃 AI 输出，回退确定性结果 | 可在调试页看到解析失败 |
| schema version 不匹配 | 尝试迁移；失败则丢弃缓存重建 | 用户无感或看到“正在重建建议” |
| source ref 不存在 | 丢弃该节点/动作/证据 | 不显示无效建议 |
| AI 返回危险动作 | 丢弃动作，保留只读解释或整条丢弃 | 调试页显示被安全规则拒绝 |
| AI 返回空结果 | 显示“为什么没有推荐” | 给出索引/开关/缓存原因 |
| redaction 命中高风险内容 | 阻断本次 AI 调用 | 显示基础结果，调试页记录 policy block |
| 归档缓存过期 | 尝试重建或显示过期说明 | 提示打开归档或刷新缓存 |
| 习惯摘要损坏 | 丢弃并重算 | 不影响当前任务 |

通用规则：

- AI 输出不能成为唯一数据源。
- 所有可点动作必须来自 App 预定义 action 枚举。
- AI 失败时不弹阻塞 alert，除非用户主动打开调试详情。
- 调试记录要区分“模型失败”“校验失败”“隐私阻断”“用户关闭”。

## 工程补充十三：Schema 版本和迁移

这份方案会新增很多持久化结构。所有持久化 schema 必须从第一版就考虑版本迁移。

建议规则：

- 每个持久化结构带 `schemaVersion`。
- 每个 AI 输入/输出 JSON 带 `schema` 字符串，例如 `simplezip.ai.workspaceTree.input.v1`。
- 输入 schema 不需要迁移，因为它是现生成的。
- 输出缓存、工作区、反馈、习惯摘要、归档画像需要迁移。
- 迁移失败的派生缓存可以丢弃重建。
- 用户创建工作区不能静默丢弃；迁移失败时保留标题和 prompt，重建虚拟树。

建议新增：

```swift
protocol AISchemaMigratable: Codable {
    static var currentSchemaVersion: Int { get }
    var schemaVersion: Int { get }
}

enum AISchemaMigrationResult<Value> {
    case migrated(Value)
    case discardAndRebuild(reason: String)
    case preserveUserFacingShell(reason: String)
}
```

调试页应显示：

- 当前 `AIWorkspaceStore` schema version；
- 当前 `AIHabitSummary` schema version；
- 最近一次迁移时间；
- 被丢弃的派生缓存数量；
- 需要用户确认的不可迁移数据。

## 工程补充十四：验收指标

AI 功能需要可评估，否则 prompt 越改越玄学。建议把指标分成正确性、可用性、性能和隐私四类。

### 正确性指标

- 活动中心自然语言筛选：人工评估 query 的 top-5 命中率。
- 归档记忆查找：目标归档 top-3 命中率。
- AI 工作区：虚拟节点 source ref 校验通过率。
- 动态动作推荐：推荐动作必须来自候选集，非法动作率为 0。
- 归档画像：marker 文件和确定性标签准确率由单元测试保证。

### 可用性指标

- 推荐工作区 dismissed 比例。如果某类推荐长期被关闭，应降权。
- 用户工作区打开后 action click rate。
- AI 证据卡展开率。展开率过高可能说明默认理由不够清楚。
- 空状态出现次数和原因分布。
- “理由不对 / 标签不对”反馈数量。

### 性能指标

- AI 工作区首屏可交互时间。
- 单次 builder 生成耗时。
- 单次模型调用耗时。
- prompt 截断次数。
- 后台任务取消次数。
- 缓存命中率。

### 隐私指标

- 红线扫描命中后阻断率。
- 隐私断言测试通过率必须 100%。
- 加密条目名进入上下文次数必须为 0。
- 密码/passphrase/token 进入上下文次数必须为 0。
- 解密临时目录进入习惯摘要次数必须为 0。

这些指标不一定第一版都做 UI，但至少要有测试和 debug 日志口径。

## 工程补充十五：施工文件地图

后续实现时建议按现有架构放置，避免所有 AI 逻辑继续堆进 `AIReportAssistant.swift`。

### App UI

- `SimpleZip/App/ContentView.swift`
  - 增加 `.aiWorkspace(UUID)` 分支。
  - 切换到 `AISuggestionFolderView` / `AIWorkspaceView`。
- `SimpleZip/Features/ArchiveBrowser/Sidebar.swift`
  - 增加 `AI` section。
  - 增加系统工作区、用户工作区、推荐工作区行。
  - 增加右键菜单：隐藏、删除、重命名、刷新、固定、不感兴趣。
- `SimpleZip/Features/AI/AIWorkspaceView.swift`
  - 新增虚拟树 UI。
  - 使用 `OutlineGroup` 或自定义 `List`。
- `SimpleZip/Features/AI/AIWorkspaceCreateSheet.swift`
  - 新增工作区创建 sheet。
- `SimpleZip/Features/AI/AIEvidenceView.swift`
  - 统一证据卡 UI。

### App Model / Store

- 现有 `SimpleZip/Features/AI/AIReportAssistant.swift`
  - 保留 FoundationModels 适配、`AIGenerationSerializer` 和现有 spec 兼容层。
  - 后续逐步瘦身为 `AppleFoundationModelEngine`，不要继续堆业务 builder。
- 新增 `SimpleZip/Features/AI/AIContextAssembler.swift`
  - 从 Core index、App task、settings、Spotlight stats、feedback 汇总 `AIContextEnvelope`。
- 新增 `SimpleZip/Features/AI/AISuggestionBus.swift`
  - 放 `AISuggestionSurfaceID`、provider registry、surface request 分发。
- 新增 `SimpleZip/Features/AI/AIWorkspaceStore.swift`
  - 保存系统/用户/推荐工作区、虚拟树缓存、折叠状态。
- 新增 `SimpleZip/Features/AI/AIHabitSummaryStore.swift`
  - 保存习惯摘要和 prompt hints。
- 新增 `SimpleZip/Features/AI/AIInteractionDatasetStore.swift`
  - 保存 folder visit、archive open session、spotlight open、first reaction。
- 新增 `SimpleZip/Features/AI/AIStartupHabitSummaryStore.swift`
  - 保存智能启动 time bucket summary。
- 新增 `SimpleZip/Features/AI/AIIntentRouter.swift`
  - 统一场景路由。

### Core / 可测试纯逻辑

- 现有 `SimpleZip/Core/AIContext.swift`
  - 已放 `AIContextEnvelope`、privacy、purpose、source ref、evidence card；继续扩展 purpose 和 source kind。
- 现有 `SimpleZip/Core/AIBudget.swift`
  - 统一预算和截断策略；后台深上下文也走这里。
- 现有 `SimpleZip/Core/AISensitiveRedactor.swift`
  - 参数、日志、路径 token、敏感词 redaction；新增数据源先写测试再接入。
- 现有 `SimpleZip/Core/ActivityTaskAIIndex.swift`
  - 从任务 snapshot 派生活动 AI 记录。
- 现有 `SimpleZip/Core/ArchiveMemoryIndex.swift`
  - 从归档清单缓存派生归档记忆。
- 现有 `SimpleZip/Core/ArchiveProfile.swift`
  - 归档画像确定性标签和 marker。
- 现有 `SimpleZip/Core/AIWorkspaceQueryPlan.swift`
  - prompt → query plan → deterministic executor 的底座。
- 现有 `SimpleZip/Core/AIWorkspaceModel.swift`
  - 工作区和虚拟树值模型；后续扩展推荐/用户/系统三类 workspace。
- 现有 `SimpleZip/Core/AIFeedback.swift`
  - 用户反馈、纠错、不感兴趣聚合。
- 现有 `SimpleZip/Core/AIUserInterestEvent.swift`
  - 用户兴趣事件底座；补齐 folder/archive/spotlight first reaction 写入。
- 现有 `SimpleZip/Core/AILocationContext.swift`
  - 低敏位置类别、路径 hash、目录 token。

如果 SwiftPM core 不适合依赖 app-only 类型，则在 Core 放纯 Codable/算法，在 App 放和 `OperationTask`、SwiftUI、FoundationModels 相关的 adapter。

## 工程补充十六：安全测试样例

隐私红线需要具体测试，而不是只靠文档约束。

建议测试用例：

- 文件名包含 `password=123456.txt`：进入 AI 前必须 redaction 或按策略降级。
- 后端参数包含 `-pSECRET`：`AIRedactor` 输出不得包含 SECRET。
- 日志包含 `passphrase: hunter2`：错误行摘要不得包含 hunter2。
- 日志包含 `token=abc.def.ghi`：token 必须 redaction。
- 加密归档条目 `secret/project.txt`：`ArchiveMemoryRecord.samplePaths` 不得包含该路径。
- 头加密归档：不得生成 entry samples，只能记录 `encryptedListingUnavailable` omission。
- `.gpg` 文件：可以记录文件名和类型，但不能读取密文内容。
- GPG 私钥路径或 key material：不得进入任何 AI context。
- 解密临时目录：不得进入 `AIHabitSummary`。
- 用户清空 AI 学习数据后：`AIHabitSummary`、feedback、推荐主题 dismiss 记录都为空。
- 用户关闭归档清单缓存后：归档记忆查找输入必须包含 disabled omission，不得偷偷读旧索引。
- AI 返回不存在的 `sourceRef`：节点被丢弃。
- AI 返回 `deleteFile` 这类未定义动作：动作被拒绝。
- AI 返回 `openArchive` 但 archive id 不在候选集：动作被拒绝。
- Prompt 超预算：builder 必须截断并写入 `omissions`。

这些测试应优先覆盖纯 Core 层：redaction、budget、archive memory、archive profile、source ref validation。UI 层只测试入口和动作不会越权。

## 工程补充十七：基于当前代码的 T0 AI 深化施工建议

如果 AI 要放在 T0 位置，它不能只是 `AIReportAssistant.isReady` 后才出现的一组 sparkle 按钮。当前代码已经有很好的雏形：`AIContext.swift`、`AIBudget.swift`、`AISensitiveRedactor.swift`、`ActivityTaskAIIndex.swift`、`ArchiveMemoryIndex.swift`、`ArchiveProfile.swift` 已经把“统一 AI 数据层”的一部分落到了 Core。下一步应该把这些 Core 能力真正接到主窗口、活动中心、归档查找和工具栏，让 AI 成为常驻组织层。

### 现有代码的关键观察

- `AIReportAssistant.swift` 现在仍是中心式 prompt facade：既管 FoundationModels 调用，又放 `ActivityFilterSpec`、`ArchiveFileQuerySpec`、`SettingsQuerySpec`，还承载大量报告 prompt。适合第一代功能，但不适合 T0 级 AI。
- `AIGenerationSerializer` 很重要，已经解决 FoundationModels 并发崩溃风险。未来所有 engine 都应继续共享这个串行策略或明确自己的并发策略。
- `AIGate` 现在会在 `AIReportAssistant.isReady` 时才渲染入口。T0 AI 不应完全依赖这个门：AI 中心、AI 工作区、确定性建议、归档记忆、活动中心 facts 应该无模型也可见；只有“生成式文案/排序/总结”按钮才需要 `AIGate`。
- `ActivityView` 的 AI 筛选现在是 popover + 一堆 `@State` 字段，最终匹配仍基于有限字段。活动中心要升级成 T0 AI 工作台，应该把这些状态搬进 `ActivityAIWorkbenchModel`，用 `ActivityTaskAIIndex` 作为统一数据源。
- `ArchiveFinderSheet` 现在是“一句话 → keyword → `ArchiveListingCacheStore.search`”。这很安全，但已经落后于 Core 里的 `ArchiveMemoryIndex` / `ArchiveProfile`，应该改成“归档记忆查找”。
- `ContextualToolbarButtons` 现在是硬编码 `switch model.mode` 和选中形态。它是动态动作推荐的最好切入点：先把现有每个分支抽成候选 provider，再加排序。
- `ArchiveMemoryIndex` 和 `ArchiveProfile` 已经能给归档结构、marker、语义标签、位置上下文，但还没有 UI 入口、相关任务关系、深度 marker 摘要和 AI 二次标注。
- `AIContextEnvelope` 现在只有单个 `privacyLevel`，但 T0 AI 场景会混合 public catalog、local metadata、diagnostics、local content signals。建议升级成更细的 privacy policy，而不是一个枚举概括整个信封。

### T0 原则：AI 入口常驻，模型增强可选

建议把“AI 是否出现”和“模型是否可用”拆开：

- `AI Center`：常驻。模型不可用时仍显示数据索引、确定性建议、隐私状态、缓存状态、最近失败。
- `AI 工作区`：常驻。模型不可用时显示系统工作区和确定性虚拟树；模型可用时增加主题命名、排序、理由和总结。
- `活动中心 AI 工作台`：常驻。模型不可用时显示失败分组、诊断标签、筛选 chip；模型可用时增加自然语言解释和动态筛选。
- `归档记忆查找`：常驻。模型不可用时走本地召回和 marker 匹配；模型可用时做 query intent 和候选排序。
- `设置助手`：模型不可用时走 catalog 本地搜索；模型可用时做自然语言意图和解释。

因此 `AIGate` 的职责应该缩小：它不再决定整个 AI surface 是否存在，只决定某个“生成式增强控件”是否出现。可以新增：

```swift
enum AIAvailabilityMode: String, Codable {
    case deterministicOnly
    case appleModelAvailable
    case disabledByUser
}
```

UI 读取这个 mode：

- `deterministicOnly`：展示 AI surface + 基础建议 + “本机模型暂不可用”说明。
- `appleModelAvailable`：展示完整生成式增强。
- `disabledByUser`：隐藏生成式入口，但 AI 中心的“数据与隐私 / 重新开启”入口仍可从设置打开。

### 让现有 Core AI 文件升级成真正底座

`AIContext.swift` 建议补：

- `AIContextMode`：`standardLocalContext` / `deepLocalContext`。
- `AIExecutionEnvironment`：`onDeviceAppleFoundationModels` / `deterministic` / `advancedOptional`。
- `AIContextPrivacyPolicy`：记录 included signals 和 blocked signals，而不是只用单个 `AIPrivacyLevel`。
- `AIContextSourceRef.displayName` 或独立 resolver，不把 UI 展示名交给模型编。
- `AIContextSourceRefValidator`：给每个场景校验模型输出引用是否在候选集内。

`AIBudget.swift` 建议补：

- 总字符预算，例如 `maxTotalChars`，避免每条都合法但整体超大。
- 深度模式预算，例如 `archiveProfileDeep`、`workspaceTreeDeep`。
- `capTextArray`，返回 kept + omitted count。
- `estimatedPromptChars(envelope:)`，调试页能显示预算消耗。
- 场景优先级：foreground / background / idleOnly。

`AISensitiveRedactor.swift` 建议补：

- `redactionReport`：返回脱敏后的文本 + 命中规则计数。AI 调试页可以显示“这次抹掉 2 个 token、1 个 password-like 字段”。
- 文件路径级 redaction 策略：当前上下文允许完整路径，长期学习只允许 hash/token。
- 深度 marker 摘要前的二次扫描：README 里如果出现 token/password/key block，摘要直接阻断或脱敏。

`ActivityTaskAIIndex.swift` 建议升级 v2：

- 增加 `detailsSession` 摘要：backend、safeArguments、exit status、error lines、log tail。
- 增加 `reportSummary`：report attachment 类型、finding 数量、质量门结果。
- 增加 `hashSummary` / `diffSummary` / `transferSummary`。
- 增加 `queueFacts`：是否等并发槽、是否等写锁、是否被取消、是否可继续。
- 增加 `pathFacts`：当前场景可以给完整路径；长期索引用 location/hash/token。
- 增加 `sourceTrace`：app / CLI / Finder / Shortcuts / URL scheme。

`ArchiveMemoryIndex.swift` 建议升级：

- 增加 `relatedTasks`：最近测试、转换、发布检查、解压失败任务。
- 增加 `lastOpenedAt`、`lastProfiledAt`、`profileConfidence`。
- 增加 `nearbyFolderMarkers`：归档所在目录里的 README、SHA256SUMS、.git、Release、Test 等 marker。
- 增加 `deepMarkerSummaries`：深度模式下 README/manifest/package 文件的短摘要。
- 增加 `entryPathIDs`：给归档内部条目稳定 id，AI 工作区才能安全引用 `archiveEntry`。

`ArchiveProfile.swift` 建议升级：

- 确定性标签保持现在规则，但增加 AI 二次标注层：
  - `deterministicTags`
  - `aiSemanticTags`
  - `tagEvidence`
  - `tagFeedback`
- 用户纠错“这不是源码包”后，写入 `tagFeedback`，以后同类 marker 降权。
- 对 `.siz` / `.szs` 建议单独画像：manifest、signature、payload 类型、验证状态、是否测试样本。

### T0 AI 工作区的更具体结构

建议新增 `AIWorkspaceStore`，它不直接跑模型，只维护工作区和缓存：

```swift
struct AIWorkspaceRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let origin: AIWorkspaceOrigin
    var title: String
    var prompt: String?
    var queryPlan: AIWorkspaceQueryPlan
    var visibility: AIWorkspaceVisibility
    var createdAt: Date
    var lastOpenedAt: Date?
    var lastGeneratedAt: Date?
}

struct AIWorkspaceQueryPlan: Codable, Equatable {
    var taskSelectors: [String]
    var archiveSelectors: [String]
    var locationSelectors: [String]
    var semanticTags: [String]
    var includeArchiveEntries: Bool
    var includeReports: Bool
    var includeActions: Bool
}
```

工作区不是每次让 AI 重新想，而是保存一个 query plan。AI 只在创建/刷新时把 prompt 转成 plan，后续由 App 确定性执行 plan。这样会稳定很多：

- 用户 prompt：“把发布相关的东西放一起”
- AI 输出 plan：`semanticTags=["release-artifact"]`、`taskSelectors=["test","inspect","checksum-mismatch"]`、`includeReports=true`
- App 执行 plan：从 `ArchiveMemoryIndex`、`ActivityTaskAIIndex`、report store 召回真实节点
- AI 可选再做排序和命名

这比每次让模型直接生成树更可控，也更像 T0 产品。

### 活动中心 AI 工作台的下一步

当前 `ActivityView` 已有自然语言筛选，但 UI 是工具栏附属功能。建议下一步：

- 新增 `ActivityAIWorkbenchModel`，输入 `TaskCenter.shared.active + history`。
- 用 `AITaskRecord.make(...)` 生成 rich records。
- 右侧工作台固定展示：
  - `需要处理`：failed unseen、canResume、canRerunWithChanges、signature/checksum。
  - `失败模式`：按 `AIDiagnosticTag` 分组。
  - `来源分布`：CLI / Finder / Shortcuts / App。
  - `建议筛选`：chip 直接应用确定性 filter。
  - `AI 解释`：只在选中失败任务时调用模型。
- 原来的 `showsAIFilter` popover 保留为“自然语言筛选”，但放进工作台。

这会让活动中心 AI 不再是附属按钮，而是任务事实入口。

### 归档查找从 keyword 搜索升级到记忆搜索

`ArchiveFinderSheet` 的下一步可以很小但效果明显：

1. 保留原来的 keyword 搜索作为 fallback。
2. 先从 `ArchiveListingCacheStore().loadAll()` 派生 `ArchiveMemoryRecord`。
3. 本地召回候选：
   - keyword 命中文件名；
   - markerFiles 命中；
   - dominantExtensions 命中；
   - semanticTags 命中；
   - folderNameTokens 命中。
4. 模型可用时，对候选排序并给理由。
5. UI 从“归档一行 + 命中条目”升级成“归档卡片 + 命中信号 + 样本路径 + 打开/搜索动作”。

这一步不必等完整 AI 工作区，能很快让“查找包含文件的归档”变得明显聪明。

### 工具栏推荐从硬编码拆成候选 Provider

`ContextualToolbarButtons` 现在的每个分支都可以一比一迁移成候选：

```swift
struct ContextualActionCandidate: Identifiable, Codable, Equatable {
    let id: String
    let titleKey: String
    let systemImage: String
    let safety: String
    let source: String
    let evidence: [AIEvidenceFact]
}
```

第一阶段不要改行为，只把 hard-coded branch 拆成：

- `ContextualActionCandidateProvider.candidates(for modelSnapshot:)`
- `ContextualActionRanker.rank(candidates:context:)`
- `ContextualToolbarButtons` 只渲染前两个。

第二阶段再让 ranker 使用：

- `ArchiveProfile.semanticTags`
- `AILocationContext.folderNameTokens`
- `ContextualActionEvent` 使用反馈
- `ActivityTaskAIIndex` 最近失败标签
- 当前目录 marker

这样不会一次性重写工具栏，但会让“AI 推荐按钮”真正变成可学习系统。

### Settings AI 不能只搜 catalog

`SettingsCatalog` 很适合做起点，但 T0 设置助手还需要“当前状态”。建议增加 `SettingsStateSnapshot`：

```swift
struct SettingsStateSnapshot: Codable, Equatable {
    let aiEnabled: Bool
    let archiveListingCacheEnabled: Bool
    let archiveListingCacheCount: Int
    let archiveListingCacheTTL: Int
    let gpgEnabled: Bool
    let gpgAvailable: Bool
    let cliInstalled: Bool
    let shortcutsEnabled: Bool
    let finderExtensionStatus: String
    let backupIncludesPerFolderMemory: Bool
}
```

用户问“为什么 AI 找不到归档里的文件”，AI 需要知道缓存是否开启、缓存数是多少、TTL 是多少，而不是只知道设置标题。

### 报告类 AI 要从 prompt 函数迁移到 facts builder

现在很多 view 直接调用 `AIReportAssistant.*Prompt(...)`。建议逐步让每个报告类型实现：

```swift
protocol AIReportFactBuildable {
    associatedtype Facts: Codable & Equatable & Sendable
    func makeAIReportFacts(budget: AIBudget) -> Facts
}
```

然后 `AIReportAssistant` 只负责：

- 把 facts 包成 `AIContextEnvelope`；
- 选择 engine；
- 调用模型；
- 校验输出。

这样报告 AI 不会继续堆成巨大 prompt 工厂，也更容易测试“给了哪些数据”。

### T0 AI 的优先施工顺序

如果要最快让用户感觉“AI 变强了”，建议按这个顺序：

1. **AI surface 常驻化**：AI 中心 / AI 工作区 / 活动中心工作台不再完全依赖模型可用性。
2. **ArchiveFinderSheet 改用 ArchiveMemoryIndex**：投入小，收益明显。
3. **ContextualToolbarButtons 拆候选 provider**：先不改变 UI，建立学习入口。
4. **ActivityAIWorkbenchModel**：把活动中心 AI 从 popover 升级为右侧工作台。
5. **AIWorkspaceStore + 系统工作区**：先做确定性虚拟树。
6. **SettingsStateSnapshot**：让设置助手知道当前状态。
7. **报告 facts builder 迁移**：逐步减少 prompt 散落。
8. **深度本地上下文**：读取非加密 marker 摘要，增强归档画像和工作区。

这套顺序的好处是：每一步都能独立交付，而且 Apple 本地模型不够强时也不会失败。AI 的“强”主要来自 SimpleZip 自己的数据底座，模型只是把它组织得更像人。

## 白皮书：榨干本地弱模型的 T0 AI 功能路线

这部分把 AI 放到 T0 位置来设计：不是把本地模型当成全能助手，而是把它当成高频、低成本、全本地的“语义组织器”。弱模型最适合做五件事：

- 分类：从 App 给出的候选标签里选。
- 命名：给工作区、分组、卡片起人能理解的名字。
- 排序：在 App 已经召回的候选里排优先级。
- 解释：把确定性 facts 解释成人话。
- 意图解析：把用户一句话转成 query plan 或 filter spec。

弱模型不擅长的事不要让它做：不要让它扫全盘，不要让它直接决定文件操作，不要让它从长日志里猜根因，不要让它处理无限上下文。SimpleZip 应该做强索引和召回，模型只做最后一层语义组织。

### 核心公式

```text
强体验 = 本地索引 + 确定性候选 + 小模型语义加工 + source ref 校验 + 用户反馈
```

只要这个公式成立，即使 Apple 本地模型比较弱，用户也会感觉 AI 很强。因为模型拿到的不是“原始世界”，而是 SimpleZip 已经整理好的高质量事实。

### Feat 1：AI 智能标签系统

给任务、归档、文件夹、报告、动作候选统一打语义标签。标签不是模型自由发明，而是从受控标签集里选择。

标签示例：

```json
{
  "schema": "simplezip.ai.semanticTags.v1",
  "target": {"type": "archive", "id": "arch-13f0"},
  "candidateTags": [
    "source-archive",
    "release-artifact",
    "test-fixture",
    "backup",
    "installer",
    "signed-container",
    "localized-app",
    "broken-volume",
    "config-bundle"
  ],
  "evidence": [
    {"label": "marker", "facts": ["Package.swift", "README.md"]},
    {"label": "extensions", "facts": ["swift=420", "strings=12"]}
  ]
}
```

输出：

```json
{
  "tags": [
    {
      "id": "source-archive",
      "confidence": 0.94,
      "reason": "命中 Package.swift、Swift 文件和 README。"
    }
  ]
}
```

施工建议：

- `ArchiveProfile` 继续做确定性标签。
- 新增 `AISemanticTagger`，只对候选标签排序和补理由。
- 用户纠错“不是源码包”后写入 `AIFeedbackStore`，同类 evidence 降权。
- AI 工作区、归档查找、工具栏推荐全部复用这套标签。

### Feat 2：AI Lens 视图

AI Lens 是主窗口里的“视角切换”，不改变真实文件，只改变虚拟组织方式。它比普通 AI 工作区更轻：用户在当前目录或当前归档上切一个 lens，App 用不同 query plan 重组同一批对象。

建议 Lens：

- `发布视角`：release-artifact、SHA256SUMS、.asc、.dmg、.app、发布检查任务。
- `源码视角`：source-archive、Package.swift、package.json、README、LICENSE、代码文件。
- `失败视角`：失败任务、checksum mismatch、permission denied、缺卷、可重跑项。
- `签名/校验视角`：.siz、.szs、.asc、签名报告、hash 报告、VERIFY.md。
- `清理视角`：重复包、散落解压、__MACOSX、临时工作区、同名旧产物。
- `自动化视角`：重复动作、常用来源、可生成 Shortcut 的流程。

Lens 输入：

```json
{
  "schema": "simplezip.ai.lens.input.v1",
  "lens": "release",
  "currentContext": {
    "mode": "folder",
    "locationKind": "project-folder",
    "folderNameTokens": ["release", "simplezip"]
  },
  "candidates": {
    "files": ["SimpleZip.dmg", "SHA256SUMS", "SimpleZip-source.zip"],
    "archives": [{"id":"arch-1","tags":["release-artifact"]}],
    "tasks": [{"id":"task-1","tags":["checksum-mismatch"]}],
    "reports": [{"id":"report-1","type":"releaseInspection"}]
  }
}
```

输出不是文件操作，而是虚拟分组：

```json
{
  "groups": [
    {"title": "发布产物", "sourceRefs": [{"type":"file","id":"file-dmg"}]},
    {"title": "校验与签名", "sourceRefs": [{"type":"file","id":"file-sha256"}]},
    {"title": "需要处理", "sourceRefs": [{"type":"task","id":"task-1"}]}
  ]
}
```

弱模型只负责命名和分组，真正节点由 App source ref 回查。

### Feat 3：下一步动作卡

把“推荐按钮”升级成“现在最值得做的 3 件事”。卡片可以出现在 AI 中心、AI 工作区、活动中心工作台和工具栏菜单里。

卡片结构：

```json
{
  "schema": "simplezip.ai.nextActionCard.v1",
  "title": "先重新测试 release.7z",
  "actionID": "testArchive",
  "risk": "safe-readonly",
  "whyThis": "最近一次测试失败并带 checksum-mismatch 标签。",
  "whyNotOthers": "转换格式不会解决校验失败；解压可能产生更多噪音。",
  "evidence": [
    {"sourceRef":{"type":"task","id":"task-7B2F"},"facts":["status=failed","tag=checksum-mismatch"]}
  ],
  "requiresConfirmation": false
}
```

施工方式：

- `ContextualActionCandidateProvider` 先枚举所有合法动作。
- `NextActionRanker` 根据 activity、archive profile、location、feedback 排序。
- AI 只生成 `whyThis`、`whyNotOthers` 和卡片标题。
- App 校验 `actionID` 必须来自候选集。

这类功能很适合弱模型，因为候选动作很少，模型只需要解释排序。

### Feat 4：失败修复手册

`AIDiagnosticsClassifier` 已经适合做基础。下一步不是让 AI 看完整日志，而是让它根据诊断标签生成小手册。

输入：

```json
{
  "schema": "simplezip.ai.failurePlaybook.input.v1",
  "task": {
    "kind": "extract",
    "source": "finder",
    "status": "failed",
    "diagnosticTags": ["missing-volume"],
    "archiveExtension": "7z",
    "locationKind": "downloads"
  },
  "errorLines": ["ERROR: Missing volume : release.7z.002"],
  "availableActions": ["openFolder", "locateMissingVolume", "retry"]
}
```

输出：

```json
{
  "headline": "缺少分卷文件",
  "steps": [
    "确认 release.7z.001、release.7z.002 等分卷在同一文件夹。",
    "如果文件来自下载，请检查是否还有未完成的分卷。",
    "补齐后重新测试或解压。"
  ],
  "primaryAction": "openFolder"
}
```

这比普通失败解释更实用：同一个标签可以积累固定修复流程，AI 只是把它贴合当前任务表达出来。

### Feat 5：归档角色识别

归档角色比“格式”更有用。`.zip` 可能是源码包、发布包、备份包、测试样本或配置包。角色识别能直接驱动工具栏推荐和 AI 工作区。

角色候选：

- `source-package`
- `release-package`
- `installer-package`
- `backup-package`
- `test-fixture`
- `signed-container`
- `config-bundle`
- `media-bundle`
- `localized-app-package`

施工方式：

- `ArchiveProfile` 先给 markers、extensions、topLevelShape。
- `ArchiveRoleClassifier` 确定性给初始分数。
- Apple 本地模型只在分数接近或需要命名解释时介入。
- 用户纠错写入 role feedback。

角色输出应该被缓存进 `ArchiveMemoryRecord`，让后续查找和推荐不用每次跑模型。

### Feat 6：自然语言智能文件夹生成器

用户输入一句话创建 AI 工作区时，不要让模型直接生成文件列表。让它生成 query plan。

用户输入：

```text
把和发布有关的东西放一起
```

模型输出：

```json
{
  "schema": "simplezip.ai.workspaceQueryPlan.v1",
  "semanticTags": ["release-artifact", "signed-container"],
  "taskTags": ["checksum-mismatch", "signature-problem"],
  "markerFiles": ["SHA256SUMS", "VERIFY.md", "signature.asc"],
  "includeReports": true,
  "includeArchiveEntries": true,
  "locationBias": ["current-folder", "recent-related"]
}
```

App 执行：

- 从 `ArchiveMemoryIndex` 找 release/signed 归档。
- 从 `ActivityTaskAIIndex` 找相关任务。
- 从报告 store 找 release/signature/hash 报告。
- 生成虚拟树。

这能极大降低弱模型压力。

### Feat 7：AI 工作区推荐标题

本地弱模型非常适合做“给事实起名字”。后台发现一组事实后，不要让它做复杂推理，只让它命名：

输入：

```json
{
  "facts": [
    "folderNameTokens=siz,szs,test",
    "visibleExtensions=siz,szs,zip,gpg",
    "tasks=test,inspect,signature",
    "markers=metadata.json,signature.asc"
  ],
  "style": "short-sidebar-title"
}
```

输出：

```json
{
  "title": "SIZ/SZS 测试工作区",
  "subtitle": "签名容器、测试任务和相关归档"
}
```

这会让 AI 感知非常强，但成本很低。

### Feat 8：AI 搜索重写

把用户的模糊搜索重写成本地索引能执行的 query。

用户输入：

```text
那个带签名的包
```

输出：

```json
{
  "schema": "simplezip.ai.searchRewrite.v1",
  "keywords": [],
  "semanticTags": ["signed-container", "signed-container-related"],
  "markerFiles": ["signature.asc"],
  "extensions": ["siz", "szs", "asc"],
  "taskTags": ["signature-problem"],
  "searchSurfaces": ["archives", "archiveEntries", "tasks", "reports"]
}
```

App 再执行本地搜索。这样弱模型只做 query rewrite，不做检索。

### Feat 9：AI 对比解释

归档 diff、hash diff、release ledger comparison 都是确定性结果。AI 只负责总结“变化意味着什么”。

输入：

```json
{
  "schema": "simplezip.ai.diffExplanation.input.v1",
  "diff": {
    "added": ["SimpleZip.app", "SHA256SUMS"],
    "removed": ["debug.log"],
    "changed": ["README.md"],
    "hashChangedCount": 12
  },
  "context": {
    "archiveRole": "release-package",
    "locationKind": "project-folder"
  }
}
```

输出：

```json
{
  "summary": "这次变化像一次发布构建：新增 app bundle 和校验文件，移除了 debug.log。",
  "attention": ["README.md 有变化，发布说明可能需要同步。"],
  "suggestedActions": ["runReleaseInspection", "generateReleaseBodyDraft"]
}
```

这类任务非常适合本地弱模型，因为结构化 diff 已经把事实压缩好了。

### Feat 10：AI 预设推荐

创建归档时，根据输入角色推荐 preset，但不直接修改参数。

示例：

```json
{
  "schema": "simplezip.ai.presetRecommendation.v1",
  "inputProfile": {
    "role": "source-package",
    "extensions": ["swift", "md", "strings"],
    "markers": ["Package.swift", "README.md"],
    "hasMediaHeavyContent": false
  },
  "availablePresets": ["sourceArchive", "releasePackage", "mediaStore", "backup"]
}
```

输出：

```json
{
  "preset": "sourceArchive",
  "reason": "输入像 Swift 源码包，建议排除 macOS junk 并开启创建后测试。",
  "optionHints": [
    {"option":"excludeJunk","value":true},
    {"option":"testAfterCreate","value":true}
  ]
}
```

App 只显示建议，用户点了才应用到现有创建 sheet。

### Feat 11：AI 纠错学习按钮

每个 AI 标签、角色、工作区、动作卡旁边提供轻量反馈：

- 对；
- 不对；
- 不是源码包；
- 不是发布包；
- 不再推荐这种；
- 多推荐这种；
- 这个理由不对；
- 这个主题太泛。

反馈不需要模型立即学习，先写成本地事件：

```json
{
  "schema": "simplezip.ai.feedbackEvent.v1",
  "targetKind": "archiveRole",
  "targetID": "arch-13f0",
  "feedback": "wrongTag",
  "fromTag": "source-package",
  "toTag": "test-fixture",
  "evidenceTokens": ["Package.swift", "test", "fixture"],
  "createdAt": "2026-06-15T10:30:00Z"
}
```

后续 deterministic ranker 和 prompt hints 都读这个反馈。这样模型不变，体验也会变聪明。

### Feat 12：AI 归档收件箱

SimpleZip 很适合做一个“归档收件箱”：用户进入 Downloads、Desktop、项目 release 目录时，AI 不直接操作文件，而是把新出现、最近打开、未处理、可能失败的归档整理成几个队列。

为什么适合端侧模型：

- 输入短：当前目录摘要 + 最近任务 + 归档画像。
- 输出简单：分组标题、排序理由、下一步动作。
- 不需要世界知识，不需要长推理。

示例输出：

```json
{
  "schema": "simplezip.ai.archiveInbox.v1",
  "groups": [
    {
      "title": "刚下载，还没测试",
      "sourceRefs": [{"type":"archive","id":"arch-1"}],
      "recommendedAction": "testArchive",
      "reason": "最近 10 分钟出现，尚无测试任务。"
    },
    {
      "title": "发布相关",
      "sourceRefs": [{"type":"archive","id":"arch-2"}, {"type":"file","id":"file-sha"}],
      "recommendedAction": "runReleaseInspection",
      "reason": "同目录有 SHA256SUMS 和签名文件。"
    }
  ]
}
```

施工落点：

- 读取 `AIFolderProfile`、`ArchiveMemoryIndex`、`ActivityTaskAIIndex`。
- 在侧边栏 AI 工作区里显示 `归档收件箱`。
- 不移动、不删除、不自动解压，只提供 action cards。

### Feat 13：AI 归档内部地图

打开一个大归档时，用户最缺的是“一眼知道里面是什么”。端侧模型可以基于非加密条目样本和 `ArchiveProfile` 生成一张内部地图。

输入：

```json
{
  "schema": "simplezip.ai.archiveMap.input.v1",
  "profile": {
    "entryCount": 1840,
    "topLevelShape": "single-root-folder",
    "dominantExtensions": ["swift", "md", "strings", "json"],
    "markerFiles": ["Package.swift", "README.md", "LICENSE"],
    "encryptedEntriesOmitted": 0
  },
  "samplePaths": [
    "Sources/App/Main.swift",
    "Resources/zh-Hans.lproj/Localizable.strings",
    "Tests/CoreTests.swift"
  ]
}
```

输出：

```json
{
  "title": "Swift 源码包",
  "sections": [
    {"name":"源码", "evidence":["Sources/", "Package.swift"]},
    {"name":"本地化", "evidence":["zh-Hans.lproj", "Localizable.strings"]},
    {"name":"测试", "evidence":["Tests/"]}
  ],
  "suggestedLens": "source"
}
```

这可以作为归档浏览器顶部的 AI Lens 摘要，也可以写入 `ArchiveMemoryRecord`，以后不用重新跑。

### Feat 14：AI 自然语言选择器

用户经常不是想搜索文件名，而是想“选中这批东西”。例如：

```text
选中所有像发布产物但还没测试过的包
```

模型不应该直接返回文件路径，而应该返回 selection query：

```json
{
  "schema": "simplezip.ai.selectionQuery.v1",
  "filters": {
    "semanticTags": ["release-artifact"],
    "taskState": "no-successful-test",
    "extensions": ["zip", "7z", "dmg", "siz", "szs"]
  },
  "actionAfterSelection": "showOnly"
}
```

App 用本地索引执行 query，然后高亮结果或进入虚拟文件夹。这个功能非常适合端侧模型，因为它只是把自然语言改写成结构化 filter。

### Feat 15：AI 操作排练

在真正执行创建、解压、转换、发布检查前，AI 可以生成“操作排练说明”。这不是让 AI 决定是否执行，而是让它解释已有 dry-run/preflight 数据。

示例：

```json
{
  "schema": "simplezip.ai.operationRehearsal.v1",
  "operation": "extract",
  "facts": {
    "archiveRole": "release-package",
    "destinationExists": true,
    "conflicts": 3,
    "suspiciousEntries": ["absolute-path", "executable"],
    "requiredPassword": false
  },
  "allowedActions": ["continueToConfirm", "changeDestination", "openSecurityReport"]
}
```

输出：

```json
{
  "summary": "这次解压会覆盖目标目录中的 3 个同名文件，并包含可执行内容。",
  "attention": ["建议先打开安全报告。", "目标目录已有同名文件。"],
  "primaryAction": "openSecurityReport"
}
```

施工落点：

- 复用现有创建/解压 options view 的 preflight facts。
- 输出只能进入确认页文案和 action cards。
- 不能跳过已有安全确认。

### Feat 16：AI 版本关系解释

SimpleZip 已经有近似重复、hash、diff、release comparison 这类确定性能力。端侧模型适合给这些结果起一个人能读懂的关系标签：

- `same-content-different-name`
- `same-release-new-build`
- `source-vs-binary-release`
- `partial-volume-set`
- `old-backup-vs-current`
- `localized-variant`

输入：

```json
{
  "schema": "simplezip.ai.versionRelation.input.v1",
  "items": [
    {"id":"a", "nameTokens":["SimpleZip","0.4.5"], "role":"release-package", "hashGroup":"h1"},
    {"id":"b", "nameTokens":["SimpleZip","0.4.5","copy"], "role":"release-package", "hashGroup":"h1"}
  ],
  "deterministicSignals": ["same-size", "same-hash", "name-copy-token"]
}
```

输出：

```json
{
  "relation": "same-content-different-name",
  "title": "同内容副本",
  "reason": "大小和 hash 相同，文件名像副本。"
}
```

这能让清理视角更有用：用户看到的不是“重复”，而是“同内容副本 / 旧构建 / 源码和二进制发布”。

### Feat 17：AI 安全关注点摘要

SimpleZip 的安全扫描已经很适合端侧 AI：规则判断由 App 做，AI 负责把结果变成短摘要和下一步。

输入：

```json
{
  "schema": "simplezip.ai.securityAttention.input.v1",
  "riskHints": ["path-traversal", "executable", "symlink"],
  "archiveRole": "unknown",
  "entrySamples": ["bin/install.sh", "../escape.txt", "README.md"],
  "allowedActions": ["openSecurityReport", "extractWithReview", "cancel"]
}
```

输出：

```json
{
  "headline": "先别直接解压",
  "summary": "这个包包含路径逃逸样本和可执行脚本，建议先看安全报告。",
  "primaryAction": "openSecurityReport"
}
```

红线：

- AI 不判断“安全/不安全”的最终结论。
- `riskHints` 必须来自确定性扫描。
- AI 不能因为摘要语气温和就降低现有安全提示级别。

### Feat 18：AI 智能命名和标题生成

端侧弱模型很适合命名。SimpleZip 里很多地方需要短标题：

- AI 工作区标题；
- 归档角色标题；
- 活动筛选保存名称；
- 报告摘要标题；
- 批处理分组名称；
- 自动化建议名称；
- 归档内部地图 section 名称。

示例：

```json
{
  "schema": "simplezip.ai.title.input.v1",
  "style": "sidebar-workspace-title",
  "facts": ["role=release-package", "markers=SHA256SUMS,signature.asc", "task=test failed"],
  "maxChars": 18
}
```

输出：

```json
{
  "title": "发布校验",
  "subtitle": "签名、哈希和失败测试"
}
```

这类功能能让 AI 感知很强，而且失败成本低。即使模型不可用，App 也可以用模板 fallback。

### Feat 19：AI 设置医生

设置里现在已经有设置搜索和 health check。可以升级成“设置医生”：把现有设置状态、健康检查结果、用户意图合并，给出配置建议。

适合端侧模型的原因：

- 设置项有限；
- 每个建议都可由 allowlist action 表达；
- 不需要扫文件内容；
- 适合短文本问答。

示例：

```json
{
  "schema": "simplezip.ai.settingsDoctor.v1",
  "userIntent": "我想让软件更懂我，但不要太耗电",
  "state": {
    "aiEnabled": true,
    "backgroundActivity": "off",
    "archivePreRead": false,
    "folderPreIndex": false,
    "spotlightIndexing": true
  },
  "allowedActions": ["openAISettings", "setBackgroundBalanced", "openPrivacyData"]
}
```

输出：

```json
{
  "answer": "可以把后台本地 AI 调到“平衡”，先开启归档预读，不开启积极文件内容预索引。",
  "actions": ["setBackgroundBalanced", "openPrivacyData"]
}
```

执行仍由用户确认，所有设置修改走现有 `SettingEntity` / Settings pane 入口。

### Feat 20：AI 发布前 Checklist

SimpleZip 对 release 包、SIZ/SZS、签名、hash、报告已经有很多上下文。可以做一个 AI 生成的发布前 checklist，但 checklist 项必须来自模板和确定性 facts。

示例输出：

```json
{
  "schema": "simplezip.ai.releaseChecklist.v1",
  "title": "发布前检查",
  "items": [
    {"id":"test-archive", "label":"测试归档可读取", "state":"missing"},
    {"id":"verify-hash", "label":"核对 SHA256SUMS", "state":"available"},
    {"id":"check-signature", "label":"检查签名文件", "state":"available"},
    {"id":"inspect-report", "label":"打开发布检查报告", "state":"missing"}
  ],
  "primaryAction": "runReleaseInspection"
}
```

模型只负责把 checklist 组织得自然，真正的项目和状态由 App 算。

### Feat 21：AI 缓存和索引维护员

当后台 AI、Spotlight、归档缓存、文件夹预索引都变强后，用户需要知道“现在索引健康吗”。端侧模型可以把健康检查转成维护建议。

输入：

```json
{
  "schema": "simplezip.ai.indexMaintenance.input.v1",
  "stats": {
    "archiveCacheCount": 120,
    "staleArchiveCacheCount": 18,
    "spotlightArchiveCount": 100,
    "folderProfileCount": 32,
    "lastBackgroundRun": "2026-06-15T12:00:00Z"
  },
  "allowedActions": ["reindexSpotlight", "pruneStaleCache", "openAIDataSettings"]
}
```

输出：

```json
{
  "summary": "索引整体可用，但有 18 个归档缓存可能过期。",
  "suggestedActions": ["pruneStaleCache", "reindexSpotlight"]
}
```

这可以放在 AI 中心的数据页和状态栏里，给用户一种“软件在自己维护记忆”的感觉。

### Feat 22：AI 命令排练 / 任务规划

用户可以在 AI 中心输入：

```text
把这个目录里像发布包的东西都检查一下
```

端侧模型输出的不是执行命令，而是任务计划：

```json
{
  "schema": "simplezip.ai.taskPlan.v1",
  "steps": [
    {"actionID":"selectByRole", "query":{"semanticTags":["release-artifact"]}},
    {"actionID":"runTest", "target":"selection"},
    {"actionID":"runReleaseInspection", "target":"selection"}
  ],
  "requiresUserReview": true
}
```

App 展示计划，用户确认后逐步执行现有动作。模型不能输出 shell，也不能绕过确认。这个功能适合端侧模型，因为它只在有限 action catalog 内排序和解释。

### Feat 23：AI “今天继续哪里”

这是智能启动目录的轻量版本，不自动打开目录，只在侧边栏 AI section 或 AI 中心顶部显示：

```json
{
  "schema": "simplezip.ai.resumeWhere.v1",
  "cards": [
    {
      "title": "继续 SIZ/SZS 测试",
      "sourceRef": {"type":"workspace","id":"workspace-siz"},
      "reason": "昨晚最后打开，且还有一个失败测试未查看。",
      "action": "openWorkspace"
    },
    {
      "title": "整理下载的归档",
      "sourceRef": {"type":"folder","id":"folder-downloads"},
      "reason": "Downloads 新增 3 个归档，还没有测试记录。",
      "action": "openFolder"
    }
  ]
}
```

它能让 AI 常驻但不烦人，也比“启动时直接改目录”更保守。用户点关闭就写 `AIFeedbackEvent` 降权。

### 白皮书优先级

如果只选 8 个最能榨干本地弱模型的 feat：

1. AI 智能标签系统。
2. 自然语言智能文件夹生成器，也就是 prompt → query plan。
3. AI Lens 视图。
4. 下一步动作卡。
5. AI 纠错学习按钮。
6. AI 归档收件箱。
7. AI 归档内部地图。
8. AI “今天继续哪里”。

这八个组合起来，模型每次只做一个小任务，但整个 App 会表现得像有一个贯穿全局的智能层。

## 分阶段落地建议

### 第一阶段：统一 AI 数据层

- 以现有 `AIContextEnvelope`、`AIBudget`、`AISensitiveRedactor`、`ActivityTaskAIIndex`、`ArchiveMemoryIndex`、`ArchiveProfile` 为起点，不重复造第二套。
- 新增 `AIEngine` 抽象，先提供 `DeterministicAIEngine` 和 `AppleFoundationModelEngine`。
- 新增 `AIContextBuilder` 协议和各场景 builder。
- 新增 `AIEvidenceCard` / `AIEvidenceFact`，让所有 AI 输出能带来源证据。
- 扩展 `AISensitiveRedactor`、`AIBudget`、source ref validation 和统一 omissions。
- 新增 `ActivityTaskAIIndex`。
- 新增 `ArchiveMemoryRecord` / `ArchiveMemoryIndex` 派生层。
- 新增 `ArchiveProfile` 派生层，先做确定性画像。
- 新增 `SettingsAIContextBuilder`。
- 新增日志 redaction 和 failure classifier。
- 为现有 `OperationTask`、`TaskReportAttachment`、`HashReport`、`ArchiveDiffReport`、`transferLog` 做摘要。
- 新增 `AIInteractionDatasetStore`，先只写本地 JSON/SQLite 派生数据。
- 在 `openFolder(_:recordsHistory:)`、`updateArchiveListingCache(for:items:url:)`、`SpotlightTapDispatcher.handle` 这三个已有入口写入 folder visit、archive open session、spotlight open event。
- 所有写入必须避开系统临时目录、解密临时目录、密码/密钥/加密条目内容。
- 不改 UI，只加测试和 debug 导出。
- 明确 MVP：第一版只做确定性数据层和无模型工作区，不接习惯总结、推荐主题和路由。

### 第二阶段：无模型可用的 AI 中心骨架

- 新增独立 AI 中心窗口。
- 总览页显示 AI 可用性、活动任务数量、归档记忆数量、设置健康、未查看失败。
- 数据与隐私页显示缓存、习惯摘要、动态推荐学习数据，并提供清空入口。
- 加 AI 数据保留、清空和开关 UI：活动历史、归档缓存、路径类别、文件夹 token、习惯总结、推荐工作区、调试上下文。
- 不接模型也能工作。
- 调整 `AIGate` 使用原则：AI surface 常驻，只有生成式按钮和模型增强内容 gated。

### 第三阶段：全局 AI Suggestion Bus 和动态动作推荐基础

- 新增 `AISuggestionSurfaceID`、`AISuggestionRequest`、`AISuggestionCard`、`AISuggestionProviderRegistry`。
- 先只接 `mainToolbar`，把当前 `ContentView.ContextualToolbarButtons` 的 switch 分支一比一搬到 `ToolbarSuggestionProvider`。
- 第一版输出仍然是现在的两个工具栏按钮，外观和行为不变，只是数据从 provider 来。
- 新增 `ContextualActionCandidateProvider`。
- 新增 `ContextualActionRanker`，初始行为等价于当前 `ContextualToolbarButtons`。
- 从 `ContentView.ContextualToolbarButtons` 的现有 switch 分支一比一迁移，不改变第一版行为。
- 新增 `ContextualActionUsageStore` 记录 shown/clicked/cancelled/completed/failed。
- 新增 `AIFeedbackEvent`，记录有用、不感兴趣、理由不对、标签纠正。
- 新增 `NextActionCard`，把前 2 个工具栏动作扩展成“下一步动作卡”的数据模型。
- 加入 `LocationKind`、`pathHash`、`folderNameTokens`、`folderMarkers`。
- 工具栏显示前 2 个推荐动作，其余进菜单。
- 多选时接入 `BatchPlan`，先做确定性分组，再接 AI 排序和解释。
- 第二步接 `sidebar`、`activityCenter`、`settingsPane`，但每次只迁一个 surface，避免 UI diff 失控。

### 第四阶段：活动中心 AI 工作台和筛选 v2

- 新增 `ActivityAIWorkbenchView`。
- AI 筛选按钮降级为工作台内入口。
- 扩展 `ActivityFilterSpecV2`。
- 用 `ActivityTaskAIIndex` 替换 title/detail 匹配。
- 支持失败原因、路径、报告类型、耗时、位置、诊断标签。
- 工作台展示需要处理、建议筛选、失败解释、下一步动作。

### 第五阶段：归档记忆查找和设置助手

- `ArchiveFinderSheet` 升级为归档记忆查找。
- 第一版直接复用现有 `ArchiveMemoryIndex.derive(from:)` 和 `ArchiveProfile`，保留 keyword search 作为 fallback。
- 新增 `ArchiveSearchIntent`。
- 新增 `AISearchRewrite`，把“那个带签名的包”这类模糊搜索转成本地索引 query。
- 新增 `ArchiveRoleClassifier` 和 AI 智能标签缓存，复用 `ArchiveProfile` evidence。
- 支持 marker、semanticTags、扩展名分布、目录 token、相关任务排序。
- 设置搜索升级为设置助手，接入 `SettingsAICatalog`。
- 新增 `SettingsStateSnapshot`，让 AI 知道缓存数量、TTL、GPG/CLI/Shortcuts/Finder 状态。
- 输出 matches、answer、safeActions，而不是单个 setting id。

### 第六阶段：报告和预检统一

- 把报告 prompt 逐步改为 `makeAIContext()`。
- 创建/解压建议使用更完整的 dry-run/preflight 数据。
- 新增 `OperationPreview`，让创建、解压、转换、测试、发布检查前都能给 AI 解释预演。
- 自动化建议改用活动中心 rich snapshot。
- SIZ/SZS/GPG 签名解释、敏感文件、近似重复、空间分析、救援、发布草稿都改走场景 facts。

### 第七阶段：小上下文习惯总结

- 新增 `AIHabitSummaryStore`。
- 先落确定性统计，不依赖模型。
- 空闲低频生成 `summaryText` 和 `promptHints`。
- AI 中心和设置里提供查看、重算、清空、关闭。
- 将 `promptHints` 接入活动中心筛选、创建/解压建议、动作推荐、归档查找和自动化建议。
- 将用户对工作区、建议卡、动作推荐、归档画像的纠错反馈接入习惯摘要。
- 将 AI 标签系统、归档角色识别、工作区推荐主题的纠错反馈纳入 ranker。

### 第七点五阶段：低负载静默 AI 维护

- 新增 `AIBackgroundScheduler`。
- 增加设置项 `后台本地 AI 活跃度`：关闭 / 省电 / 平衡 / 积极。
- 新增后台归档预读和后台文件夹预索引开关。
- 后台归档预读成功写入 `ArchiveListingCacheStore` 后，按现有双门控同步 `CachedArchiveSpotlightIndexer` 和 `ArchiveFileSpotlightIndexer`。
- `SpotlightReindex.stats()` 区分用户打开索引、后台预读索引、逐文件条目索引。
- 空闲时预生成推荐主题、AI Lens、系统工作区虚拟树、下一步动作卡。
- 后台刷新 `ArchiveProfile` AI 标签、归档角色、习惯摘要。
- 后台建立 `AIFileMemoryIndex` 和 `AIFolderProfile`，让主窗口文件视图也能被 AI 一览。
- 将归档预读和文件夹预索引结果喂给 `AIWorkspaceThemeEngine` 与 `AIVirtualFolderTreeEngine`，自动生成工作虚拟目录。
- 前台请求优先，后台任务可取消或延后。
- AI 中心显示最近后台维护状态、生成数量、省略和脱敏摘要。

### 第七点六阶段：智能启动目录和时间习惯

- 新增 `AIStartupSuggestionMode`，独立于现有 `StartupLocation`，避免破坏欢迎页、健康检查和设置备份。
- 候选只来自现有启动目录、last folder、custom history、pinned/recent sidebar、预索引白名单、用户工作区和最近打开对象所在目录。
- 新增 `AIStartupHabitSummaryStore`，把 `AIUserInterestEvent` 折叠为 morning/afternoon/evening/night、weekday/weekend 小上下文。
- 新增 `AIStartupDirectoryRanker`，确定性打分为主，Apple 本地模型只生成标题、理由和相近候选排序。
- `GeneralPane` 加 AI 智能启动设置行，新增文案走 `L10n.text` 并更新 `en.lproj` 与 `zh-Hans.lproj`。
- `ContentView`/`ArchiveBrowserModel.init` 在默认启动目录解析后读取智能启动建议：默认只建议，不自动切换。
- 如果用户点“不感兴趣”，写 `AIFeedbackEvent(targetKind:.workspace/.virtualNode)` 和 `aiStartupLastDismissedCandidateIDs`。

### 第八阶段：调试和质量门

- 加 AI 上下文调试视图。
- 加 AI 证据卡调试：source refs、omissions、被拒绝的 AI 输出。
- 加 “为什么没有推荐” 空状态解释。
- 加隐私断言测试。
- 加人工 query 回归集。
- 加 schema 版本迁移测试。
- 加性能预算测试：候选截断、prompt 超预算、后台刷新限频。
- 加验收指标日志口径：命中率、dismissed 比例、JSON 校验通过率、fallback 次数、隐私阻断次数。
- 在 `docs/DEVELOPMENT.md` 和 `docs/ARCHITECTURE.md` 记录统一 AI 数据权限规则。

### 第九阶段：统一 AI 路由

- 新增 `AIIntentRouter`。
- 先用 deterministic routing：surface、selection、mode、query token 决定目的地。
- 低置信度时再调用 AI 路由。
- 将 AI 中心、AI 工作区、活动中心、设置助手、归档查找接入统一路由。
- 用户输入一句话时，自动进入最合适的 AI 能力，而不是要求用户找正确按钮。

### 第九点五阶段：AI Lens 和智能文件夹生成器

- 新增 `AILens`：发布、源码、失败、签名/校验、清理、自动化。
- 新增 `AIWorkspaceQueryPlan`，用户 prompt 先转 query plan，再由 App 确定性召回节点。
- AI 只负责 lens 命名、分组标题和排序理由。
- 将 AI Lens 接入主窗口 AI 工作区，不改变真实文件列表。
- 为每个 lens 增加“为什么这个节点在这里”的证据卡。

### 第十阶段：可选高级模型增强

- 保持 Apple 本地模型为默认引擎。
- 在设置里只暴露“高级增强”入口，不影响默认本地体验。
- 高级引擎复用同一套 `AIContextEnvelope`、redaction、source ref validation 和动作白名单。
- 只把高级引擎用于大规模语义查找、长报告草稿、复杂批处理规划、全局 AI 中心问答等 L2 场景。
- 安全动作仍由 L3 本地规则控制，不能因为模型更强就放宽红线。

## 最小优先级排序

如果只先做一件事：先做统一 AI 数据层。没有 `AIContextEnvelope`、各场景 builder、redaction、omissions 和派生索引，后面所有 AI 都会继续变成零散 prompt。

如果只先做三件事：

1. `AIContextEnvelope` + 全场景 builder + redaction/加密排除测试。
2. `AIInteractionDatasetStore` + openFolder / archive open / Spotlight tap 写入。
3. `AISuggestionBus` + 工具栏迁移，再接侧边栏 AI 工作区和活动中心 AI 工作台。

这样 AI 会从“散落的小按钮”变成一个有数据底座、有中心入口、有动态学习的系统，同时仍然不突破密码和加密内容红线。
