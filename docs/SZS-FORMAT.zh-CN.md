[English](./SZS-FORMAT.md) | **中文**

# `.szs` 格式 — 签名清单（Signed Manifest）

**状态**：已发布且稳定。该格式在 0.1.10 落地；清单当前处于 schema **版本 2**
（v1 仍被接受 —— v2 为安全投递包（Secure Bundle）工作（#110）新增了可选的
`instructions` 字段）。密码学决策刻意保持小而保守；线缆格式保持稳定，而 UI /
验证报告则持续迭代。本文件是权威的线缆格式规范 —— 在改动任何 wrap / unwrap /
verify 逻辑之前，请先阅读它（以及 `SECURITY.md` 的容器格式章节）。

术语与 [`SECURITY.zh-CN.md`](../SECURITY.zh-CN.md) 的容器格式章节保持一致。

---

## 为什么需要一个新格式？

`.siz` 解决的是「我想发送**一个**归档，并让它的签名随之一起传递」—— 其内容是
单个内层归档，通过一层包裹用的 tar 进行 GPG 签名。它是一种针对重签名攻击做了
加固的归档容器。

`.szs` 解决的是另一个问题：**「我想分发一组在磁盘上保持彼此独立的文件，并用
单一签名清单为每个文件的完整性背书。」**

本格式针对的具体场景：

1. **发行版分发** —— `MyApp.app` + `LICENSE.txt` + `README.md` +
   `Changelog` —— 让它们保持为独立文件（这样用户无需解包即可阅读 README），但
   在旁边附上一个 `.szs`，任何人都可以验证整批投递物。
2. **镜像树** —— 「此 URL 当前内容」的周期性快照，其中每个文件的哈希被签名一次，
   并在内容变更前一直有效。
3. **逐文件完整性验证** —— 给定一份签名清单，证明每个文件都与其预期 SHA 相符，
   而无需信任传递它们的通道（镜像、网页目录等）。

「打包成一个 tar」的做法（= `.siz`）对这些场景是错误的 —— 打包迫使接收方在使用
任何内容前先解包，破坏了对单个文件的 CDN 缓存，并使任何单文件更新都需要重新下载
整个包。

「每个文件附带一个 `.asc`」的做法（= 经典分离签名）也是错误的 —— N 个文件 =
N 个签名，每个都是一次单独的 gpg 调用，没有单一的「为整个集合签名」动作。

`.szs` 是**一个签名文件，通过相对路径和 SHA256 指向其余 N 个文件**。验证整批
投递物只需两步：验证 `.szs` 签名，然后对照 `.szs` 所声称的内容验证每个文件的
SHA256。

---

## 格式

一个 `.szs` 文件是一条 **GPG 明文签名消息（clearsigned message）**
（[RFC 4880 § 7](https://datatracker.ietf.org/doc/html/rfc4880#section-7)），其
正文是一份确定性 JSON 文档。也就是说，磁盘上的布局是：

```text
-----BEGIN PGP SIGNED MESSAGE-----
Hash: SHA512

{ ...manifest JSON, deterministic encoding... }
-----BEGIN PGP SIGNATURE-----

iQEzBAEBCAAd... (ASCII-armored signature)
-----END PGP SIGNATURE-----
```

这正是 `gpg --clearsign` 默认产出的内容。选择明文签名而非「分离签名 + sidecar」
有两个理由：

- **单一文件** —— `.szs` 是自包含的。没有会被遗忘的 `<thing>.szs.sig`。
- **可人工检视** —— `cat foo.szs` 会在签名块之前显示 JSON。当未安装 GPG 时，
  curl + cat 可作为应急的「这声称了什么」工具。

编码约束：内部的清单 JSON 是带 `[.prettyPrinted, .sortedKeys]` 的
`JSONEncoder` 输出，与 `.siz` 的 `metadata.json` 使用同一个编码器。确定性至关
重要 —— 签名覆盖的是明文签名标记之间的字面字节；经由一个非确定性编码器往返将
破坏验证。

### 加密（在 v1 中刻意排除在范围之外）

`.szs` v1 仅支持签名。涉及本格式的加密用例更适合由 `.siz` v3（单一归档 +
多收件人加密）来满足。把逐文件清单与载荷加密混在一起会引入边界情况（逐文件
解密密钥、加密与明文文件混杂），而这些都没有明确正确的答案；推迟处理可以让
v1 规范保持小而易审阅。

---

## 清单 schema

顶层对象，schema 为 `SimpleZip.szs`，当前版本 2（v1 仍被接受）：

```jsonc
{
  "schema": "SimpleZip.szs",
  "version": 2,
  "createdAt": "2026-05-30T03:04:05Z",        // ISO-8601 UTC
  "createdBy": "SimpleZip 0.1.10",             // creator version
  "title": "MyRelease v3.1",                   // optional display title
  "description": "Public release artifacts",   // optional human-readable note
  "rootDirectoryHint": "MyRelease/",           // optional: suggested layout root
  "files": [
    {
      "relativePath": "MyApp.app/Contents/Info.plist",
      "size": 1234,
      "sha256": "0a1b2c...64 hex...",
      "mediaType": "application/xml"           // optional
    },
    {
      "relativePath": "LICENSE.txt",
      "size": 1078,
      "sha256": "abcdef...64 hex..."
    }
  ],
  "instructions": "…optional, signed…"         // v2: human-readable recipient note (#110)
}
```

字段规则（在创建时与验证时均强制执行）：

- `schema`：必须恰好为 `"SimpleZip.szs"`。任何其他值都会被拒绝。
- `version`：整数。当前 = **2**（v2 新增了可选的 `instructions` 字段）；验证器
  接受集合 `{1, 2}`。未知版本 = 「此 `.szs` 由更新版本的 SimpleZip 制作；请升级」。
- `instructions`（v2，可选）：面向接收方的人类可读说明 —— 这是什么、如何验证
  签名、以及如何手工核对每个文件的 SHA-256。在创建时自动生成；它是明文签名
  清单的一部分，因此是**防篡改的**（编辑它会破坏签名）。缺省时省略，因此 v1
  的 `.szs` 字节保持不变。不携带任何机密材料。
- `createdAt`：ISO-8601 UTC。UI 以用户本地时区显示。
- `createdBy`：自由格式。仅用于显示。
- `title`、`description`、`rootDirectoryHint`：供 UI 使用的可选元数据。
  `rootDirectoryHint` 纯粹是一个建议 —— 验证器不强制要求文件嵌套于其下；它是
  一个 UX 线索，便于 SimpleZip 把「MyRelease/」显示为虚拟根，并在其下展示条目。
- `files[].relativePath`：**必须**是相对路径（无前导 `/`，无 `..` 组成部分，
  无 Windows 盘符，无 UNC）。与 `.siz` 的 `validatedInnerArchiveName` 相同的
  限制，但推广到含 `/` 的路径。线缆上的路径分隔符为正斜杠。Windows 风格的反斜杠
  被拒绝。
- `files[].size`：字节数。用作快速的不匹配启发，以及在哈希之前为进度条确定尺寸。
- `files[].sha256`：64 个小写十六进制字符。文件确切字节的 SHA256。
- `files[].mediaType`：可选 MIME 类型，UI 显示提示。
- `files` 数组本身必须按 `relativePath` 字典序排序。这是签名者与验证者一致约定
  的确定性顺序。（`JSONEncoder.sortedKeys` 只对字典键排序，不对数组元素排序；
  创建流程必须在编码前对 `files` 排序。）

禁止：重复的 `relativePath` 条目；空的 `files` 数组（一份什么都不签名的清单
没有意义 —— 在创建时报错）。

### v1 中刻意不包含的内容

- **无目录条目。** `.szs` 仅描述文件叶子。如有需要，UI 可从相对路径合成文件夹
  节点。
- **无符号链接 / 设备文件。** 只有常规文件会被签名。
- **无文件 mode 位。** 被签名的属性是字节内容；权限是本地 OS 状态，不属于跨系统
  的信任声明。
- **无文件时间戳。** 同样的理由 —— 本地 mtime 与「这是否是签名者背书的字节」无关。
- **无逐文件单独签名。** 一个签名、一个签名者，签名整份清单。多签名者（会签）
  是 v2 的议题。

---

## 验证流程

输入：位于 `manifestURL` 的一个 `.szs` 文件，加上一个根目录 `payloadRoot`，
由 `files[].relativePath` 引用的文件位于其下。

```
SZSArchive.verify(manifestURL:, payloadRoot:)
  → VerifyReport
```

步骤：

1. **读取并按需解密。** 如果清单路径以 `.gpg` / `.pgp` / `.szs.gpg` 结尾，运行
   `gpg --decrypt` 以获取明文签名文本。
2. **GPG 验证明文签名。** 对 `.szs` 内容运行 `gpg --status-fd 1 --verify`。解析
   与 `.siz` 验证路径相同的状态码（`GOODSIG` / `VALIDSIG` / `BADSIG` /
   `NO_PUBKEY` / `EXPKEYSIG` / `REVKEYSIG` / `EXPSIG` / `TRUST_*`）。
3. **解析清单 JSON。** 提取明文签名标记之间的正文，解码为 `Manifest`。schema /
   版本检查会拒绝未知者。
4. **逐文件哈希检查。** 对每个 `files[]` 条目，解析 `payloadRoot/relativePath`，
   流式计算文件的 SHA256（像 `.siz` 的 `computeInnerArchiveSHA256` 那样按 1 MiB
   分块），与 `files[].sha256` 比较。跟踪逐文件状态。
5. **汇总为报告。**

```swift
struct VerifyReport {
    let signature: GPGBackend.GPGVerifyResult   // reuse existing type
    let manifest: Manifest                       // decoded
    let entries: [Entry]                         // one per files[]
    enum Entry: Equatable {
        case match(relativePath: String, sizeBytes: Int)
        case mismatch(relativePath: String, expectedSHA: String, actualSHA: String)
        case missing(relativePath: String)
        case unreadable(relativePath: String, reason: String)
    }
    var summary: Summary {
        // count matches / mismatches / missing / unreadable for UI badge
    }
    struct Summary: Equatable {
        let total: Int
        let matched: Int
        let mismatched: Int
        let missing: Int
        let unreadable: Int
        var allFilesOk: Bool { mismatched == 0 && missing == 0 && unreadable == 0 }
    }
}
```

`signature` 字段原样复用 `.siz` 的 `GPGVerifyResult` 枚举 —— 相同的 case，
相同的「指纹强比较」语义（如果清单声称了 `signerFingerprint` 的话；今天它还
没有；若 v2 加入该字段，强检查可直接复用）。

UI 将报告呈现为一张表：

```
✓ Signature valid (trusted)  signed by: chiba <qwq@qwwq.org>
                              fingerprint: AEBB3BC5...0FF8E3
                              signed at: 2026-05-30T03:04:05Z

Files (12 total, 12 ✓ 0 ✗ 0 missing)
  ✓  LICENSE.txt                          1.05 KB    sha256 abcdef...
  ✓  README.md                            8.21 KB    sha256 0a1b2c...
  ✗  MyApp.app/Contents/Info.plist        — sha256 mismatch (clicking expands)
  ⚠  CHANGELOG.md                         file missing under payload root
  ...
```

不匹配的行会展开，以等宽字体显示**预期**与**实际**的 SHA256，帮助用户诊断
（「哦，是我编辑了这个文件」与「镜像把它损坏了」之分）。

---

## 创建流程

输入：一个根目录 + 其下的一组文件 URL + 一个签名密钥指纹 + 可选的 `title` /
`description` + 收件人指纹（用于加密）。

```
SZSArchive.create(
    payloadRoot:,
    files: [URL],
    signingKeyFingerprint: String?,
    title: String?,
    description: String?,
    encryptionRecipients: [String] = [],   // empty = no encryption (clearsigned only)
    outputURL: URL
) async throws
```

步骤：

1. 对每个输入文件，验证它位于 `payloadRoot` 之下（拒绝 `..` 逃逸），计算相对
   路径，计算流式 SHA256，记录大小。
2. 按相对路径（字典序）对条目排序 —— 确定性顺序对签名稳定性至关重要。
3. 构造 `Manifest` 结构体，从签名密钥填入 `signature.signerFingerprint`。
4. `JSONEncoder([.prettyPrinted, .sortedKeys])` → 清单字节。
5. `gpg --clearsign --local-user <fp>` → 明文签名字节。
6. 如果 `recipients` 非 nil：对明文签名字节执行 `gpg --encrypt --recipient ...`
   → `.szs.gpg`。否则：把明文签名字节直接写入 `outputURL`。
7. 返回。

口令处理：与 `.siz` 相同 —— 由 `gpg-agent` + `pinentry-mac` 驱动对话框。
SimpleZip 不触碰口令。

---

## UI 模式

`.szs` 在 `.folder` 与 `.archive` 之外引入了一个新的浏览器模式：
`.signedManifest`。在以下情况激活：

- 用户从 Finder 双击一个 `.szs` 文件，或
- 用户从「文件」菜单选择「打开签名清单…」，或
- 一个外部文件打开经由 `openExternalURL` 路由，且扩展名为 `szs`（与现有的
  `.siz` 分支并列）。

该模式渲染与现有浏览器相同的、类 Finder 的文件表，但每一行的图标都叠加了一个
验证徽章（✓ / ✗ / ⚠ / ?）。点击一个不匹配的行会打开逐文件诊断（「expected
sha256 ... actual sha256 ...」）。

头部横幅显示签名者信息 + 总体摘要（「12/12 verified」或「3 files mismatched」）。
该头部复用自 `SIZSignatureStatus` —— 相同的图标 / 颜色 / 标题映射 —— 因此与
`.siz` 解压对话框的视觉一致性得以保持。

读取 / 打开单个文件的行为与文件夹模式中的相同（双击在默认应用中打开：如果在
payload root 之外则用临时副本，如果在内则就地打开）。

拖出可用（文件的字节在磁盘上是真实存在的；SimpleZip 只是传递 URL）。

没有「全部解压」动作 —— `.szs` 已经隐含文件位于真实路径上，因此用户直接导航 /
打开即可。

---

## 已贯通的用例

### 「为一批发行物签名」

```
release/
├── MyApp.app/
├── LICENSE.txt
├── README.md
└── CHANGELOG.md
```

`SimpleZip → File → Create Signed Manifest`，选择 `release/` 作为根，所有文件
自动发现，签名密钥从 GPG 面板的默认值选取。输出：`release/release.szs`（与
内容并列）。任何下载该目录的人都可以从终端运行 `gpg --verify release.szs`，
或在 SimpleZip 中打开 `release.szs` 以获取可视化报告。

### 「审计一个镜像」

用户从 CDN 下载了一棵树。作者在一个已知 URL 上用其指纹发布了 `tree.szs`。
用户单独下载 `tree.szs`，在 SimpleZip 中打开并指向下载得到的树，获得一份逐
文件报告。任何不匹配 / 缺失的条目都会被立即标记。

---

## 威胁模型摘要

| Attack                                                           | Defense                                                                                                            |
|------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------|
| Forge `createdBy` / `title` in the manifest                      | The clearsign signature covers all bytes between markers → any byte change invalidates the signature.              |
| Replace a referenced file with different bytes                   | SHA256 of actual file no longer matches `files[].sha256` → that row reports `.mismatch`.                          |
| Add an extra file not in the manifest                            | `.szs` only verifies the listed files. The unlisted file is shown in the UI's "unreferenced files" tray (advisory).|
| Remove a referenced file                                         | The verifier resolves `payloadRoot/relativePath`, gets ENOENT → `.missing`.                                        |
| Swap a file with another file from the same manifest             | SHA256 mismatch on both rows → both report `.mismatch`.                                                            |
| Strip the signature block                                        | `gpg --verify` fails with no signature → `.verificationError`.                                                     |
| Replace the signature with one signed by a different key         | `VALIDSIG` reports the different fingerprint; the UI shows that signer (not the expected one). Optional v2: include `signerFingerprint` in the JSON body so cross-checking with `VALIDSIG` enables a strong-fingerprint badSignature classification (mirrors `.siz` v2 design). |
| Path traversal via `files[].relativePath` (`../escape`)          | `validatedRelativePath` rejects `..`, absolute paths, Windows drive paths, UNC, backslashes — at both create + verify time. |
| Symlink under `payloadRoot` redirects SHA computation off-tree   | SHA256 reads file contents via `FileHandle` — follows symlinks by default, but the path itself must validate first. UI surfaces "this file is a symlink to X" before verifying. |

---

## `.szs` **不**保护的内容

- 文件本身的**机密性**。清单被签名；载荷保持为用户布置的样子。对 `.szs` 自身
  的加密隐藏的是清单内容（文件列表 + 哈希），而非文件内容。
- **签名者被攻陷。** 标准的 GPG 卫生规范适用 —— 吊销、过期、硬件密钥是用户的
  责任。
- **被捆绑的 `gpg` 二进制文件。** 被攻陷的本地 gpg 超出范围（与 `.siz` 相同）。
- **`payloadRoot` 之外的文件** —— 验证器只检查列出的相对路径上的文件。目录中
  额外的文件会被报告为「unreferenced」，但不属于验证结果的一部分。

---

## 与 `.siz` 的差异一览

|                          | `.siz`                                | `.szs`                                          |
|--------------------------|---------------------------------------|-------------------------------------------------|
| Files                    | One inner archive                     | N external files                                |
| Container                | tar shell                             | Clearsigned JSON (single file)                  |
| Signature target         | `metadata.json` (in tar)              | The manifest JSON itself (clearsigned)          |
| Signature carrier        | `signature.asc` inside tar            | Inline with the manifest (clearsign block)      |
| Encryption               | `archive.<ext>.gpg` (encrypt payload, v3) | Out of scope for v1 — use `.siz` v3 instead     |
| Verification entry point | `SIZArchive.verify(unwrap:)`           | `SZSArchive.verify(manifestURL:, payloadRoot:)`    |
| UI mode                  | Archive browser                       | New `signedManifest` browser mode               |
| Strong fingerprint check | v2+, in metadata                      | Planned for v2                                  |

---

## 实现阶段

下述所有阶段均已发布（该格式在 0.1.10 上线；`instructions` 字段 / 安全投递包
支持随 #110 到来）。此处记录为「实际建成」地图 —— 是真实的文件名，而非设计期
的猜测：

- **#24 part 1**（本文档）—— 设计文档。
- **#24 part 2** —— `Core/SZSArchive.swift`：`Manifest`、`create`、`verify`、
  路径验证。纯函数，由 `Tests/SimpleZipCoreTests`（SwiftPM）覆盖。
- **#24 part 3** —— `GPGBackend.clearsign` / `verifyClearsign`，复用来自 `.siz`
  工作的 `GPGBackend` 加密 / 解密路径。
- **#24 part 4** —— `Features/SignedManifest/SZSVerificationSheet.swift`（逐
  文件验证报告）+ `.signedManifest` 浏览器模式。`.siz` 解压复用
  `Features/ExternalExtract/SIZSignatureSheet.swift`。L10n 在 en / zh-Hans。
- **#24 part 5** —— 创建流程：`Features/SignedManifest/CreateSZSSheet.swift` +
  「文件」菜单中的「Create Signed Manifest…」入口（选择根 + 文件 + 签名密钥 +
  可选收件人）。
- **#24 part 6** —— `.szs` 的 UTI / 文件关联注册与 Finder 集成。

---

## 设计问题（已随发布定案）

这些问题在设计期是开放的。已发布的格式按下述答案对它们做了定案；此处保留以
说明缘由。

1. **每个目录是 sidecar `.szs` 还是 inline `.szs`？** 本文档假定 inline：
   `release.szs` 位于其文件所覆盖的目录中。另一种方案是「`.szs` 位于一个并列
   位置，指向用户在验证时提供的 `payloadRoot/...` 路径」。inline 更简单；
   sibling 更灵活。

2. **清单 `files[]` 的顺序 —— 字典序还是插入序？** 字典序是确定性的，并契合
   `JSONEncoder.sortedKeys` 的精神。插入序会让签名者传达「这是预期的显示顺序」。
   v1 默认采用字典序；如果出现真实用例则再行考量。

3. **逐文件 `mediaType`？** 在 v1 中可选。UI 把它当作提示使用；验证器不强制。
   如价值低则整个去掉。

4. **`payloadRoot` 是否应默认为 `.szs` 文件所在的目录？** 是，对「把 `.szs`
   放在文件旁边」的模式最自然。UI 允许用户覆盖。

5. **`title` / `description` / `rootDirectoryHint` —— 全保留还是合并？** 三者
   均为可选。`title` 用于验证报告头部；`description` 用于较长的备注。
   `rootDirectoryHint` 是一个仅 UI 使用的布局线索。若有冗余则不排斥去掉其一。

6. **强指纹检查（v2）？** 向 JSON 正文添加 `signerFingerprint` /
   `signerUserID` 会让 SimpleZip 做出与 `.siz` v2 相同的冒充防御：gpg 报告
   实际签名 fp，与清单的声称进行比较。很可能是 v2 —— 保持 v1 最小且无争议。

线缆格式现已稳定；对它的改动必须保持 v1 / v2 字节可解码，并经由 `SECURITY.md`
的容器格式章节。针对新格式想法，请提交带 `format/szs` 标签的 issue。
