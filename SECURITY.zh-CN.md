[English](./SECURITY.md) | **中文**

# 安全策略

本文档说明 SimpleZip 的威胁模型、面向用户的安全控件，以及漏洞上报流程。

实现层的细节（每道防线当前覆盖到什么程度、有哪些测试）请看
[`README.md`](./README.md) 里的 **Safety Model** 段以及
[`docs/ARCHITECTURE.md`](./docs/ARCHITECTURE.md) 里的架构说明。

---

## 漏洞上报

SimpleZip 是一个单人维护的 macOS 小工具，以未签名 DMG 形式分发，没有专用
安全邮箱。请选择以下一种方式上报：

- **GitHub Security Advisories**（推荐）：在
  https://github.com/chiba233/SimpleZip/security/advisories/new
  打开一个 private advisory；
- **私信邮件**：通过维护者的 GitHub 个人页联系。

**请不要**为未修复的漏洞开 public issue —— 在用户能升级之前就把工单变成
公开 exploit 配方。

请提供：

- 精确的 SimpleZip 版本号（菜单 `SimpleZip → 关于 SimpleZip` 可见）；
- macOS 版本号；
- 是否需要用户交互才能触发（以及什么样的交互）；
- 最小可重现的压缩包 / 输入文件，作为附件或私有上传链接。

响应时间承诺：约 7 天内确认收到；约 30 天内给出修复或缓解时间表。关键问题
（远程代码执行 / 任意写出选定目录之外的文件 / 预设密码泄露）会被优先处理。

---

## 威胁模型

SimpleZip 把每个压缩包都视为**不可信输入**。App 有意不进沙盒 —— 它必须跑
内置 CLI 后端和挂磁盘映像 —— 但信任边界必须在 App 自己的代码里强制执行。

### 在保护范围内

- **恶意压缩包条目名**（路径穿越 / 绝对路径 / Windows 盘符 / UNC 路径）——
  由 `ArchiveSafety.unsafeEntryNames` 标记，门由「**可疑路径**」策略控制。
- **解压输出里的恶意符号链接** —— 由「**符号链接**」策略门控制，staging
  合并到用户选定目标前先确认。
- **压缩包内的主动内容**（`.app` / `.pkg` / 脚本 / HTML / Office 文档等）
  —— 由「**主动内容**」策略门控制，SimpleZip 把临时文件交给 macOS 或默认
  App 前先确认。
- **后端命令注入**（通过用户提供的原始参数 / 文件名 / 密码）—— 密码走
  stdin (PTY)，文件名由 Foundation `Process` API 自动加引号，原始参数
  用一个识别引号的 tokenizer 拆，不让 shell 展开。
- **预设密码的泄露**（落盘 / 内存 / 屏幕显示）—— 见下文「预设密码存储」。
- **`.siz` 签名容器篡改**（伪造签名者 metadata / 替换内层 archive /
  剥离签名 / 容器炸弹）—— 见下文 [`.siz` 签名容器格式](#siz-签名容器格式)。
- **`.szs` 签名清单篡改**（伪造清单内容 / 替换被引用文件 / 剥离签名 /
  路径穿越）—— 见下文 [`.szs` 签名清单格式](#szs-签名清单格式)。

### 不在保护范围内（设计取舍）

- **已经在用户身份下任意执行代码的攻击者**。SimpleZip 无法防御已经以你
  身份在跑的恶意二进制。预设密码只防落盘检查和瞥屏幕，**不**防同进程内
  内存读取。
- **被污染的内置后端**。如果用户下载之后到运行之间把 `Tools/` 里的内置
  `7zz` 换成了恶意版本，SimpleZip 会照跑。DMG 是 GitHub Actions 从 `main`
  分支构建的，发布物有 checksum；用户自己改装 `Tools/7zz` 承担风险。
- **macOS Gatekeeper bypass**。SimpleZip 是 ad-hoc 未签名，用户首次运行时
  显式绕过 Gatekeeper —— README 里已说明。Developer ID 签名是 Phase 11 路线
  的事。
- **网络攻击**。压缩包工作流不发任何网络请求。唯一的网络访问点是用户主动
  触发的 RAR 安装脚本，以及「打开项目主页」菜单项。

---

## 面向用户的安全控件

这些选项在 `设置 → 压缩 → 安全` 和 `设置 → 通用` 里：

| 设置                  | 控制什么                                                                                             | 默认  |
|---------------------|--------------------------------------------------------------------------------------------------|-----|
| **可疑路径**            | 压缩包含 `../` / 绝对路径 / Windows 路径时怎么办                                                                | 询问  |
| **符号链接**            | 解压输出里出现符号链接时怎么办                                                                                  | 询问  |
| **主动内容**            | 从压缩包里打开 `.app` / 脚本 / Office 文档时怎么办                                                               | 询问  |
| **Finder 自动解压**     | 从 Finder / Services 打开压缩包时是否跳过浏览器直接解压（前面三个安全策略门仍然生效）                                            | 关闭  |
| **预设密码**            | 自动填 / 自动尝试一个已保存的密码（见下文「预设密码存储」）                                                                  | 关闭  |

每个「询问」策略都可以切到「始终允许」或「始终拒绝」。共享 / 公共机器推荐
选「始终拒绝」。

---

## 预设密码存储

预设密码是 opt-in（`设置 → 通用 → 使用预设密码`）。启用后：

### 落盘

- 密码写到 **macOS Keychain** 作为 generic password，service 名
  `yumeka.SimpleZip.PresetPassword`，account `default`。
- 可访问性 = `kSecAttrAccessibleAfterFirstUnlock` —— 仅同 code-sign 的 App
  可读，且仅在用户当前启动 session 已经解锁过 Mac 后可读。
- **永远不**写进 `UserDefaults`。一次性迁移会清掉早期 dev 构建里的旧
  plist key（`presetPassword`）。
- 关掉主开关 → 立刻 `SecItemDelete` 删 Keychain 条目。

### 内存

- 一个进程内缓存在首次 Keychain 读取后保留这个值，避免每次操作都让用户
  授权 Keychain 访问。
- 缓存由 `clear()`（关 toggle）清空，由 `save(_:)` 更新。
- 缓存不持久化；重启 SimpleZip 时缓存为空。

### 屏幕显示

- 设置里的密码输入框默认是 `SecureField`（•••• 遮罩）。
- 切换显示明文需要**本地认证** —— Touch ID 或登录密码 fallback，走
  `LAContext.evaluatePolicy(.deviceOwnerAuthentication)`。
- 认证失败**不**显示密码，并显示明显的失败提示。
- 离开设置窗口时输入框重置为遮罩。
- 缓冲式编辑 + 「保存」按钮 → 关窗口不点保存会丢编辑。

### 用预设创建的压缩包

- 密码走 stdin（伪终端），**不**作为命令行参数传给后端，**不**出现在 `ps`
  和活动监视器里。

如果你的威胁模型包含「同一台 Mac 上的其他用户」，**不要**启用预设密码。

---

## `.siz` 签名容器格式

`.siz` 是 SimpleZip 自有的单文件签名容器。设计目标是「**一个常规压缩包，
带着它的 GPG 签名一起穿过邮件 / 聊天 / 网盘**」，避免外置 `.asc` 总跟主
档案脱节。本节记录密码学设计和取舍逻辑。

### 容器结构

`.siz` 是个**未压缩**的 `tar`，顶层正好放三个文件（不允许子目录）：

```
archive.<ext>      ← 内层压缩包，原封不动
metadata.json     ← schema = SimpleZip.siz, version = 2
signature.asc     ← GPG detached signature（ASCII armor）
```

`tar` 故意**不压缩**：`archive.<ext>` 自己已经是压缩格式（zip / 7z / rar
/ tar.gz / …），再压一遍买不到空间，只浪费 CPU。用户原本选的压缩选项
（包括 ZIP / 7z 里的 AES-256 密码加密）保留原状 —— `.siz` 是外壳，不是
替代的压缩格式。

### 签的是什么，为什么

**签名目标是 `metadata.json`，不是 `archive.<ext>`。** 这是本格式最关键的
设计决定。

如果签名只签内层 archive（看起来更直觉的选法），没有私钥的攻击者仍然能改
`metadata.json` 里**任何**字段 —— 签名者名 / 签名时间 / 原文件名 / 内层
格式串 —— 而 SimpleZip 会乐呵呵地展示伪造的值并报告「签名有效」，因为密码学
靶子（内层 archive）没被动。签名只意味着「签名者某时签过这个 archive
字节流」，而不是「签名者背书**当前这个 .siz 容器**就是他想要的样子」。这对
「这串字节是不是来自 X」是个有用 primitive，但对「这个签名 `.siz` 容器是否
是创建者本来想要的」是个很差的 primitive。

改签 `metadata.json` 后，metadata 任何字节变化都会让签名失效，所以：

- 改签名者名 → 签名失败；
- 改签名时间 → 签名失败；
- 把内层 archive 换个名字（比如换 `archive.<ext>`）→ 签名失败，因为
  `innerArchiveName` 变了；
- 改记录的内层格式 → 签名失败。

### 内层 archive 通过 SHA256 锁定

只签 metadata 还有另一种攻击空间：保留 `metadata.json` 和 `signature.asc`
不动，把 tar 容器里的 `archive.<ext>` 换成完全不同的 blob。metadata 签名
仍然通过；UI 仍显示原签名者；但用户解开的是攻击者的 payload。

为了堵这个漏，`metadata.json` 里有 `innerArchiveSHA256` —— 容器创建时
`archive.<ext>` 的 SHA256 hex。验签时 SimpleZip 重算解出的内层 archive
SHA256，跟记录值比对。不一致就报 `.badSignature`，哪怕 metadata 上的 gpg
签名技术上仍然有效：我们要警示的是**组合**事件 —— 「metadata 是真的，但
内层 archive 不是 metadata 声称的那个」。

SHA256 用 1 MiB 流式块算（`CryptoKit.SHA256`），50 GB 的内层 archive 不
全部读进内存。

### Metadata 记录什么

```jsonc
{
  "schema": "SimpleZip.siz",
  "version": 2,
  "innerArchiveName": "archive.zip",            // 比如 archive.7z
  "innerFormat": "zip",                          // UI 展示用
  "originalArchiveName": "MyProject.zip",       // 用户打包前选的文件名
  "innerArchiveSHA256": "…64 hex…",             // archive.<ext> 流式 SHA256
  "createdAt": "2026-05-30T03:04:05Z",          // ISO-8601 UTC
  "createdBy": "SimpleZip 0.1.8",                // 创建端 App 版本
  "signature": {
    "signerFingerprint": "…40 hex…",            // *声称*（由 gpg 校验）
    "signerUserID": "Alice <alice@example.com>", // *声称*（仅信息展示）
    "armorFormat": true                          // signature.asc 是 ASCII armor
  }
}
```

`signature.signerFingerprint` 和 `signature.signerUserID` 在 metadata 里是
**声称**，不是证据。真正的信任来自 gpg 用 `signature.asc` 校验
`metadata.json`。如果 metadata 签名失败，展示的 signer 字段就没意义（UI
会先弹红色 bad-signature 警告再让用户决定）。如果 metadata 签名通过，记录
的 signer 字段就保证是签名者打包时写的那些。

### 两步验签流程

`SIZArchive.verify(unwrap:)` 0.1.8 后：

1. **`gpg --status-fd 1 --verify signature.asc metadata.json`** —— 用机器
   可读状态行（`GOODSIG` / `VALIDSIG` / `TRUST_*` / `BADSIG` / `NO_PUBKEY`）
   判断签名是否密码学有效、签名者在不在 keyring、是否被信任、签名 / 密钥
   是否过期 / 撤销等。
2. **Fingerprint 强校验** —— `VALIDSIG` 状态行报告的真实签名主密钥
   fingerprint 必须等于 `metadata.signature.signerFingerprint`。不等 =
   metadata 被改 + 重签（impersonation 攻击）→ 改判 `.badSignature`。
3. **SHA256 校验** —— 仅在第 1 步返回 `.validSignature` 时重算
   `SHA256(archive.<ext>)`，跟 `metadata.innerArchiveSHA256` 比对。不一致
   降级为 `.badSignature(signer:)`：签名者是真的，但他们当时签的容器跟用户
   面前这个文件已经不一致了。

所有失败情况展示同样的 UI：红色 bad-signature 对话框，取消是默认 action。
用户仍能强制「仍然打开」，但响亮且默认取消的 UI 设计上引导一般用户不这么做。

### Deterministic Metadata 编码

只有签的字节跟验的字节字节级相等，metadata 签名才有意义。SwiftPM 的
`JSONEncoder` 配 `[.prettyPrinted, .sortedKeys]` 在相同 `Codable` 输入下是
确定性输出，所以：

- 创建路径用 `SIZArchive.encodeMetadata(_:)` 把 metadata 序列化一次，写盘，
  gpg 签**那个文件**，然后 `SIZArchive.wrap(...)` 用**同一个** encoder 写
  容器内的 `metadata.json`；
- 验签路径直接从 tar 里读出 `metadata.json` 字节，**不**经过 `JSONEncoder`
  round-trip。

这就消除了「编码器不一致导致 false bad signature」这一类错报，同时让
`SIZArchive` 不依赖 `GPGBackend`（签名由调用方负责）。

### Passphrase 处理

SimpleZip 主流程**永远不**碰用户的私钥 passphrase。所有 `gpg --sign` /
`gpg --verify` 调用都依赖 `gpg-agent` + `pinentry-mac` 弹原生 macOS 密码
框。避免在 SimpleZip 进程里出现 passphrase（包括缓冲 / view state / Keychain）。
用户必须装 `pinentry-mac`（Homebrew 的 `gnupg` formula 会自动装一份）；
SimpleZip 在「设置 → GPG」里检测不到时会显示提醒。

**例外**：「新建密钥」和「修改 passphrase」走的是 loopback 模式 —— 用户在
SimpleZip 的 SecureField 里输入 passphrase，立刻通过 `--passphrase-fd 0`
喂给 gpg，不存任何地方。这是因为 pinentry-mac 在 GUI App 进程环境下偶尔
不弹窗（卡死「正在生成密钥」），是「可靠 UX 」与「不让 SimpleZip 进程接触
passphrase 」之间的取舍。这两个场景受影响的密钥是 SimpleZip 自己刚生成 /
直接修改的，本来就最敏感地受 SimpleZip 控制，所以这个例外不放大攻击面。

### 解包前的容器加固

落盘前，`SIZArchive.unwrap(at:to:)` 先 list tar 条目（`tar -tf` + `tar
-tvf` 拿类型信息），拒绝：

- 不通过 `ArchiveSafety.unsafeEntryNames` 检查的条目名（路径穿越 / 绝对
  路径 / Windows 风格路径）；
- 非常规文件条目（符号链接 / 硬链接 / 设备 / FIFO）；
- 名字规范化后重复的条目；
- 预期三件套之外的任何条目
  （`archive.<ext>`、`metadata.json`、`signature.asc`）；
- 不通过 `validatedInnerArchiveName` 的 `metadata.innerArchiveName`
  （含路径分隔符 / 跟 metadata 或 signature 文件名重叠）。

这些检查都过了之后才单独 `tar -xf` 三个预期条目（不是整包），把 unwrap
绑死在指定的几个文件上。

### 威胁模型小结

| 攻击                                                                   | 防御                                                                            |
|----------------------------------------------------------------------|-------------------------------------------------------------------------------|
| 伪造 metadata 里的签名者名 / 时间 / `originalArchiveName`                       | gpg 验签 `metadata.json` 失败 → 红色 bad-signature 对话框                                |
| 把 `archive.<ext>` 换成不同 blob                                          | 重算 `metadata.innerArchiveSHA256` 跟实际比对 → `.badSignature`                       |
| 改 metadata 里某个字段 + 用自己的密钥重签                                          | **Fingerprint 强校验**：gpg `VALIDSIG` 报告的真实 fp 跟 `metadata.signerFingerprint` 比对 → `.badSignature` |
| 从容器里剥掉 `signature.asc`                                               | `unwrap` 要求 `signature.asc` 存在；缺 → `SIZError.missingContainerComponents`        |
| 往容器里塞第四个文件（如 `notes.html`）                                           | `unwrap` 拒绝预期三件套之外的任何条目                                                       |
| 用 `metadata.innerArchiveName`（`../escape.zip`）做路径穿越                  | `validatedInnerArchiveName` 在解包前拒绝带分隔符 / 不安全成分的名字                              |
| 用 tar 条目名做路径穿越                                                       | `tar -xf` 前先过 `ArchiveSafety.unsafeEntryNames` 检查                              |
| 容器里塞符号链接指向用户 home                                                    | tar 条目类型检查拒绝非常规文件，只接受 `-`（普通文件）                                              |
| 用旧 `.siz` v1（签内层 archive 的格式）来绕过 metadata 签名                         | `unwrap` 拒绝 `schema != "SimpleZip.siz"`，且编码器 `version != 2` 也会不一致              |
| 用户在设置里关了 GPG 集成时打开 `.siz`                                            | unwrap 仍工作；验签跳过且不弹任何签名 UI（缺 GPG 不应该是 denial-of-service）                       |
| 内层 archive `.zip` / `.7z` 的密码 / 加密                                   | 不动用户原本的加密；解压时仍由内层格式自己询问密码                                                     |

### v3 多收件人加密（0.1.9）

`.siz` v3 给内层 `archive.<ext>` payload 加了可选加密层。签名 metadata 的
信任模型完全不变 —— 加密是叠在签名容器**内部**的，不是包在外面。

- **加密算法**：`gpg --encrypt --recipient <fp> ...`（多收件人公钥加密）
  **以及/或者** `gpg --symmetric --passphrase-fd 0`（对称口令加密）。组合
  调用会产生一段可用任一收件人的私钥**或**对称口令解密的密文包。
- **内层 SHA256 算的是密文，不是明文**。两个后果：
  1. 没有解密密钥的人（包括被动观察者）也能凭重算密文 SHA256 来校验容器
     完整性 —— 签名 + SHA 双通过对外部观察者也有意义；
  2. 攻击者哪怕事后拿到明文，**也没法**用不同的 session key 重新加密做出
     伪造：gpg 每次加密的 session key 是随机的，重加密一定产生不同字节
     → SHA 变 → 签名不再匹配。
- **收件人列表写在签好名的 metadata 里**。这是「**声称**」，但签名锚定了
  它 —— 攻击者无法在不让签名失效的前提下改写收件人列表。
- **对称口令以 flag 形式记录**，不记录口令本身。metadata 里写
  `hasSymmetricPassphrase: true` 通知验证方解密时需要询问口令；口令本身
  永远不出现在 metadata。
- **解密 passphrase 走 stdin**（`--passphrase-fd 0`）—— 永远不进命令行，
  不出现在 `ps` 或活动监视器。
- **明文生命周期**：`gpg --decrypt` 之后明文落到跟解包同一个
  `SimpleZip-SIZ-Unwrap-*` 临时目录。`performExtractArchive` 用
  `defer { try? fileManager.removeItem(at: decryptedSibling) }` 在
  `ArchiveService.extract` 返回（无论成败）时立刻删掉。

v3 **不**保护什么：

- **被攻陷的收件人**。任意一个收件人的私钥泄露都能还原明文。
- **弱口令**。对称模式的强度等于口令强度本身。gpg 的 CAST5/AES 默认 +
  S2K 迭代有帮助，但顶不住字典攻击下的弱口令。
- **加密前的旁路**。如果明文在加密前就泄露过（cache / swap / 屏幕阅读
  器），事后加密救不回来。

---

## `.szs` 签名清单格式

`.szs` 是 SimpleZip 的另一个签名数据格式 —— 一份 **GPG clearsign 的 JSON
清单**，用相对路径 + SHA256 指向**外部**文件。使用场景：发一棵文件树
（release 工件 / 镜像快照 / 文档集合）+ 旁边一份 `.szs`，接收方同时校验
签名**和**每个文件的 SHA 跟签名者承诺的值。

### 磁盘格式

```
-----BEGIN PGP SIGNED MESSAGE-----
Hash: SHA512

{
  "schema": "SimpleZip.szs",
  "version": 1,
  "createdAt": "2026-05-30T10:23:45Z",
  "createdBy": "SimpleZip 0.1.9",
  "title": "MyRelease v3.1",          // 可选
  "files": [
    { "relativePath": "LICENSE.txt",
      "size": 1078, "sha256": "<64 hex>" },
    ...
  ]
}
-----BEGIN PGP SIGNATURE-----
...
-----END PGP SIGNATURE-----
```

确定性编码：`JSONEncoder([.prettyPrinted, .sortedKeys])` + `files[]` 按
`relativePath` 字典序排序 —— 同一输入下，clearsign 标记之间的字节是字节
级一致的，这就是签名锚定的对象。

### 两步验签流程（`SZSArchive.verify`）

1. **签名校验**：`gpg --status-fd 1 --decrypt` 跑 `.szs` 本体（clearsign
   用 `--decrypt` 提取 body；status fd 报跟 `.siz` 同一套的
   `GOODSIG / VALIDSIG / TRUST_*` 状态码）。两遍走：用户 keyring +
   SimpleZip 私有 ring，合并方式跟 `.siz` 完全一致。
2. **逐文件 SHA256**：解析 JSON body，遍历 `files[]`，对每条解析
   `<payloadRoot>/<relativePath>` → 流式算 SHA256 → 跟记录值比对。每条
   分类成 `.match` / `.mismatch` / `.missing` / `.unreadable`。

### 虚拟目录浏览模式

验证 sheet 上的「**作为虚拟目录浏览**」按钮会把 payload root 以普通文件夹
模式打开，但加一道过滤器，**只允许** `.match` 的条目 + 它们的祖先目录通
过。SHA 校验失败的（不一致 / 缺失 / 不可读）以及 payload root 里**未被
清单收录**的额外文件都隐藏 —— 这样用户不会把没验过的文件误当成已验通过
的内容。地址栏显示 `/path/to/manifest.szs` 来明确「虚拟压缩包」的语境；
向上走出 payload root 范围时，过滤器自动失效。

### 威胁模型小结（`.szs`）

| 攻击                                                                | 防御                                                                                                            |
|-------------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------|
| 伪造清单里的 `createdBy` / `title` / `files[]`                          | clearsign body 覆盖标记之间每个字节 → 任何篡改都会让 `gpg --verify` 失败                                                          |
| 用 `relativePath` 做路径穿越（`../escape.txt`）                           | `validatedRelativePath` 拒绝 `..` / 绝对路径 / Windows 盘符（`C:`）/ UNC（`\\…`）/ 反斜杠 —— 即使签名通过也拒绝（签名者可能已被攻陷） |
| 把清单引用的文件换成不同字节                                                    | 实际文件 SHA256 不再匹配 → 该条目报 `.mismatch`；虚拟目录过滤器把它排除掉                                                              |
| 往 payload root 里塞清单没列出的文件                                         | 验签只对清单列出的文件背书；虚拟目录视图只展示已验证文件                                                                                  |
| 把签名块剥掉                                                            | `gpg --decrypt` 要么失败（无签名）要么返回混合明文 —— 解析出的 `signature` 字段会暴露失败                                                |
| 用攻击者自己的密钥重签清单                                                     | 签名 fingerprint 暴露给 UI；信任由用户 keyring 决定（跟 `.siz` 同一套 UI）                                                       |
| 验签过程中明文泄露                                                         | clearsign 的 `gpg --decrypt` 只输出 body；不存在「解密后落盘缓存」的环节                                                          |
| 用户在 GPG 关闭时打开 `.szs`                                              | `SZSArchive.peek` 要求 gpg；sheet 直接显示错误，不会假装「已验证」                                                               |

### `.szs` **不**保护什么

- **被引用文件的机密性**。`.szs` 只签不加密；被指向的文件仍按用户原样
  放着。要机密性请用 `.siz` v3（加密的单文件 archive）。
- **被攻陷的签名者 / 弱 ownertrust** —— 跟 `.siz` 一样的限制。
- **payload root 范围外的文件** —— 验签只校验清单列出的路径。未被收录的
  额外文件**不在**验证范围内。

---

## 沿用自 `.siz` 的取舍

### `.siz` **不**保护什么

- **内层 archive 的机密性（v2）**。v2 `.siz` 是签名容器，不是加密容器。
  要机密性请用内层 archive 自带的加密（比如 `.zip` / `.7z` 的 AES-256），
  或升级到 v3 多收件人加密（上文）。签名只保证真实性 / 完整性，不保证
  保密。
- **被攻陷的签名者**。私钥被偷走的签名者可以签出任意能干净校验通过的
  `.siz`。标准 GPG 密钥管理实践（撤销 / 过期 / 硬件密钥）是用户的责任。
- **信任委托**。`.validSignature(trusted: false)` 表示 gpg 接受了签名但
  本地 keyring 对签名者没有信任路径。UI 用绿色但不填充图标 + 非阻塞提示
  显示这个状态；并**不**拒绝打开。只想接受完全信任签名的用户请按需配置 GPG
  trust。0.1.8 起验签管线读 `TRUST_ULTIMATE/FULLY/MARGINAL/UNDEFINED/NEVER`
  状态码精确判定 trusted，不再受 stderr 字符串 / locale 影响。
- **内置 `tar` 二进制**。`.siz` unwrap 依赖 `/usr/bin/tar`，这是 macOS 的
  一部分。系统 `tar` 被污染不在 SimpleZip 威胁模型内（已被「系统二进制被
  污染不在范围内」覆盖）。

---

## 内置后端

| 后端                                       | 来源                      | 许可证                                          |
|------------------------------------------|-------------------------|----------------------------------------------|
| `Tools/7zz`（7-Zip CLI，universal）         | https://www.7-zip.org/  | LGPL-2.1，见 `Tools/7zip-License.txt`          |
| `Tools/rar`（可选，由用户安装）                    | https://www.rarlab.com/ | RAR shareware，见 `Tools/rar-license.txt`      |

7-Zip 二进制随 DMG 内置一份。RAR 二进制由于许可证限制**不**默认内置；用户
通过 App 内「安装 RAR 后端」流程把二进制从 `Tools/` 复制到 App Support
目录，安装前会显示 LICENSE / README 供审阅。

---

## 发版校验

发版前的检查清单见 [`docs/release-checklist.md`](./docs/release-checklist.md)。
