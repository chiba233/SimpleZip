[English](./AI-AGENT.md) | **中文**

# SimpleZip 端上 AI 辅助进程(Agent 与 XPC Service)

SimpleZip 的所有端上模型**推理**都跑在主 app 二进制**之外**的辅助进程里。App 只构造 Codable 输入 DTO 并调用
`AIAgentClient`,由它序列化成一次带类型的 XPC 调用;对端进程才 import `FoundationModels`、拼 prompt、跑模型、解析结果。
主 app 二进制从不创建 `LanguageModelSession`——只有一个只读的「模型是否可用?」查询仍会碰到 `FoundationModels`。

本文档说明这些辅助进程:两条投递通道、`SimpleZipAIAgent` 的命令行参数、XPC 接口契约、配置同步 payload,以及
launchd / `SMAppService` 注册。

> 设计动机的总览见 [`ARCHITECTURE.md` → On-Device AI](./ARCHITECTURE.zh-CN.md)。面向**终端用户**的命令行工具
> (`simplezip`)是完全不同的另一回事,见 [`CLI.md`](./CLI.zh-CN.md)。这里的辅助进程是内部实现,并非给用户直接运行。

## 两条通道,一个引擎

两条通道都跑同一个 `AIPassEngine`(在 `SimpleZipAgentSupport/AIAgentService.swift`,只编进辅助 target),且都过
**同一个全局串行闸**,所以端上模型绝不会被两个重叠的 `respond()` 越界进入。正常情况下:App 开着 → XPC Service 活;
App 关着 → LaunchAgent 干后台活;两个进程不会同时跑。

| | **XPC Service**(`SimpleZipAIXPCService.xpc`) | **Agent / LaunchAgent**(`SimpleZipAIAgent`) |
|---|---|---|
| 角色 | 前台、按需推理 | App 关闭后的后台索引;按需 Mach 探针 |
| 位置 | `SimpleZip.app/Contents/XPCServices/` | `SimpleZip.app/Contents/MacOS/`(helper);plist 在 `Contents/Library/LaunchAgents/` |
| 拉起方式 | `NSXPCConnection(serviceName:)` —— App 连接时 launchd 按需拉起 | `SMAppService` + launchd(`StartInterval`,或 Mach 连接时) |
| 生命周期 | 绑 App(`XPCService.ServiceType = Application`),App 退即终止 | App 退后仍存活;launchd 按计划唤醒 |
| Login Items /「允许后台」门控 | **否** —— 不进 Login Items、不受门控 | **是** —— 出现在 Login Items、受「允许后台」门控 |
| 入口 | `AIXPCServiceMain.swift`(`NSXPCListener.service()`) | `AIAgentMain.swift` |

`SimpleZipAIAgent` 这个二进制支撑**两个** launchd job(见 [注册](#launchd--smappservice-注册)):一个常驻的按需 Mach
listener(默认、无参数),和一个周期后台索引 job(`--background-index`)。

## `SimpleZipAIAgent` 命令行参数

这些参数用于开发、诊断和 launchd——**不是**面向终端用户的 CLI。可执行文件位于
`SimpleZip.app/Contents/MacOS/SimpleZipAIAgent`(Debug 构建是 `SimpleZip-dev.app`)。输出走 stderr(Console 可见)与 stdout。

| 参数 | 作用 |
|---|---|
| *(无参数)* | 起一个绑定到 Mach 服务名的常驻 `NSXPCListener`,等 App / launchd 连接。这是 LaunchAgent 的默认模式。 |
| `--background-index` | 跑**一轮**后台索引后退出。这是 launchd 周期拉起跑的本体(也供你手动验证数据通路):读 App 同步的配置 + scope 白名单 → 扫描元数据 → 用端上模型烘焙摘要 → 写回派生索引 → 记一笔运行遥测 → 退出。门控不过(opt-in 关等)则廉价 no-op 退出。 |
| `--background-index --force` | 同上,但绕过间隔自节流和 app/agent 前台让位锁(测试用)。**门控与红线仍生效**——AI 主开关与隐私规则不会被绕过。 |
| `--probe` | 在本(独立)进程直接跑一次端上模型最小探针后退出。绕开 SMAppService/launchd/XPC,单独回答地基问题「端上模型能否在 app 之外的进程里跑」。 |
| `--query <text>` | 跑一次**真实**结构化生成:把自然语言请求 → 归档搜索关键词,打印后退出。不依赖 XPC/GUI 验证真实(非写死)生成。 |
| `--test-backend <归档路径>` | 在 agent 进程里跑一次 `ArchiveService.list`(真起 `7zz`)并回报条目数。验证后端能在辅助进程里跑通(`Bundle.main` 解析到 app bundle,因此找得到 `Resources/Tools/7zz`)。 |
| `--config-selftest` | 构造配置 → encode → decode → 比对,打印 round-trip 结果后退出。纯 Foundation,不依赖模型或 XPC。 |

示例:

```sh
APP="/Applications/SimpleZip.app/Contents/MacOS/SimpleZipAIAgent"
"$APP" --background-index --force          # 立刻强制跑一轮后台索引
"$APP" --probe                             # 端上模型在这里能跑通吗?
"$APP" --query "我记得有个预算表压缩在哪了"
"$APP" --test-backend ~/Downloads/test.zip
```

## XPC 接口契约(`SimpleZipAIAgentXPC`)

一个 `@objc` 协议(`NSXPCConnection` 硬要求),两条通道共用。每个方法都通过 reply block 在任意队列回调。

| 方法 | 回传 | 说明 |
|---|---|---|
| `ping` | `Bool` | 轻量存活探测——**不跑模型**,瞬回。给「运行状态」健康检查用,免得状态检测卡在慢生成上。 |
| `modelAvailability` | `(Bool, reasonCode)` | 端上模型可用性。`reasonCode ∈ {"", "deviceNotEligible", "notEnabled", "modelNotReady", "osTooOld"}`,App 据 code 映射本地化文案。只读、瞬回。 |
| `probeModel` | `String` | 试跑一次最小生成,回人话结果(成功 + 样本 / 不可用原因)。 |
| `extractArchiveKeyword(fromRequest:)` | `String` | 真实结构化生成:自然语言请求 → 归档搜索关键词(或人话错误)。 |
| `syncConfiguration(_:)` | `Int` | App → agent 配置同步(JSON `Data`)。agent 解码、存储并据此门控;回传自己支持的 schemaVersion(解码失败回 `-1`,供 App 协商 / 降级)。 |
| `generate(kind:inputJSON:languageName:)` | `(Data, Bool)` | 通用 AI pass 生成。`kind = AIPassKind.rawValue`;`inputJSON` 是该 pass 的 Codable 输入 DTO;`languageName` 是界面语言(引擎进程无 app locale)。`ok == true` → `Data` 是输出 DTO;`ok == false` → `Data` 是 UTF-8 人话错误。**红线:主 / 子开关关 → `ok == false`(「AI 已禁用」)。** |
| `passStats` | `Data` | 进程自启动以来每个 pass kind 的调用统计(`[AIPassStatEntry]`:总数 / 成功 / 失败 / 最近一次时间 + 成败),供 DevTools 监视。不碰模型、瞬回。 |

App 侧客户端是 `AIAgentClient`(`SimpleZip/Features/AI/AIAgentClient.swift`):`runForegroundProbe` /
`runForegroundQuery` / `generatePass(kind:input:as:)` / `pingForegroundBackend` / `fetchModelAvailability` 走 XPC Service
通道;`runBackgroundProbe` 走 LaunchAgent(Mach)通道。首次连接会重试一次,吸收冷启动时 launchd 拉起的竞态。

## 配置同步(`AIAgentConfiguration`)

App 把当前 AI 设置编码成 JSON `Data` payload(携带 `schemaVersion`,当前为 `4`)推给 agent;agent 据此门控生成。

| 字段 | 含义 |
|---|---|
| `aiAssistantEnabled` | **AI 主开关。红线:`false` = 整个 agent AI 能力禁用**(不生成、不索引、不预读)——前台也不豁免。 |
| `aiSuggestionEnabled` | AI 建议子开关。 |
| `indexingEnabled` / `contentPrereadEnabled` | 后台索引 / 内容预读开关。 |
| `activityLevel` | 后台活跃度档位(`AIBackgroundActivityLevel.rawValue`)。 |
| `silentBackgroundIndexEnabled` | App 关闭后 agent 是否继续后台索引(与「打开应用时索引」分开的独立 opt-in)。下面的间隔 / timeout 只在它为 true 时有意义。 |
| `backgroundIndexIntervalHours` | 后台索引触发间隔(小时);launchd 按它周期唤醒 agent。 |
| `maxBackgroundRunSeconds` | 单次后台运行最长时长,超时停、下次继续。电源门控复用 `AIBackgroundSchedulingRules`。 |
| `languageName` | 界面语言名(如 `"Simplified Chinese"`),让后台烘焙用对的语言出摘要。旧 payload 无此字段时解码回退 `"English"`。 |

**持久化。** App 原子写到 `Application Support/<app-bundle-id>/AIAgentConfig.json`(dev/prod 隔离)。任何被 launchd
启动的 agent 进程都读它,所以即便 App 关着被唤醒的后台 agent 也拿得到当前配置——尤其是红线主开关。

**运行遥测。** agent 每次被唤醒跑 `--background-index` 都在 App 偏好域记一笔(运行次数 / 最近唤醒 / 最近结果),
这样 App 与 DevTools 能确认后台 agent 确实被唤醒过、几次、结果如何——光看「上次成功索引」时间戳看不出 launchd 是否在按计划唤醒。

## launchd / `SMAppService` 注册

agent 经 `SMAppService.agent(plistName:)` 注册(macOS 13+);plist 嵌在
`SimpleZip.app/Contents/Library/LaunchAgents/`。共两个:

- **`<machService>.plist`** —— 常驻的按需 Mach listener。只声明 `MachServices`(以 agent 命名);有连接时 launchd
  拉起。用于 DevTools 探针和 App → agent 的 Mach 通道。
- **`<machService>.index.plist`** —— 周期后台索引 job。`ProgramArguments` 以 `--background-index` 跑 helper(跑一轮就退,
  不是常驻 listener),`StartInterval 21600`(6 小时的 base 频率;更长的配置间隔由 agent 自节流实现)、`RunAtLoad`、
  `ProcessType Background`、`LowPriorityIO`,交给 OS 管电源。

**命名空间隔离。** Debug 用 `.dev.*` 命名空间,Release 用正式的 `.*`,让自签 dev 版与 Developer ID 正式版在
SMAppService / launchd / BTM 里互不相撞(BTM 按 `Label` 的 bundle-id 前缀把 job 归属给某个 app)。CI(`build_dmg.sh`)
从发布产物里剔除 `.dev` plist。

| 常量 | Debug | Release |
|---|---|---|
| Mach 服务名(LaunchAgent) | `yumeka.SimpleZip-in-mac.dev.aiagent` | `yumeka.SimpleZip-in-mac.aiagent` |
| XPC 服务名(= XPC Service 的 `CFBundleIdentifier`) | `yumeka.SimpleZip-in-mac.dev.aixpc` | `yumeka.SimpleZip-in-mac.aixpc` |
| 后台索引 plist | `<machService>.index.plist` | `<machService>.index.plist` |

## 隐私与门控(红线)

- **主开关关 → agent 的全部 AI 能力禁用**(不生成、不索引、不预读);前台不豁免。既由推送的配置门控,也在引擎里再复核一次。
- **静默后台索引是独立的 opt-in**,且额外受电源门控(`AIBackgroundSchedulingRules`)与间隔节流;launchd 的 base 频率是
  6 小时,实际频率随配置。
- **绝不喂给模型:** 口令、加密归档条目名、GPG 密文、解密明文。输入先过 `AISensitiveRedactor` 脱敏。
- 后台索引本身是纯元数据扫描;只有烘焙摘要会调端上模型——且永远只在辅助进程里。主二进制 import `FoundationModels`
  仅为那一个只读可用性查询。

## 相关文档

- [`ARCHITECTURE.md`](./ARCHITECTURE.zh-CN.md) —— On-Device AI(独立进程):设计动机与 pass 契约。
- [`CLI.md`](./CLI.zh-CN.md) —— 面向终端用户的 `simplezip` 命令行工具(与这里的辅助进程参数无关)。
