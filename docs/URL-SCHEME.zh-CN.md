[English](./URL-SCHEME.md) | **中文**

# SimpleZip URL Scheme

SimpleZip 注册了 `simplezip://` URL scheme，以便同一台 Mac 上的其他应用、脚本和自动化流程请求它执行归档动作。每个动作默认会**先在应用内确认**，但你可以在设置中配置自动化密钥来跳过确认。

> 本文档描述公开的 URL 动词。等价的终端命令参见 [`CLI.zh-CN.md`](./CLI.zh-CN.md)；macOS 快捷指令 / App Intents 接口参见 [`SHORTCUTS.zh-CN.md`](./SHORTCUTS.zh-CN.md)。

## 注册

该 scheme 在应用包的 `Info.plist` 中通过 `CFBundleURLTypes` 声明：

```xml
<key>CFBundleURLTypes</key>
<array>
    <dict>
        <key>CFBundleURLName</key>
        <string>SimpleZip Finder Actions</string>
        <key>CFBundleURLSchemes</key>
        <array>
            <string>simplezip</string>
        </array>
    </dict>
</array>
```

SimpleZip 至少启动过一次后，macOS 就会把 `simplezip://` URL 路由给它。你可以从命令行触发一个用于测试：

```bash
open "simplezip://check?path=/Users/me/Archives/build.zip"
```

## 动作

所有六个动词都位于 URL 的 host 位置（`simplezip://<verb>`），并从查询参数读取操作数。参数名称精确且区分大小写。

| 动词 | URL 形式 | 参数 |
| --- | --- | --- |
| Check | `simplezip://check?path=…` | `path` |
| Compare | `simplezip://compare?left=…&right=…` | `left`, `right` |
| Open | `simplezip://open?path=…` | `path` |
| Extract | `simplezip://extract?path=…` | `path` |
| Hash | `simplezip://hash?path=…` | `path` |
| Create | `simplezip://create?path=…&format=zip|7z|tgz` | `path`, `format` |

scheme 名称（`simplezip`）和动词的匹配不区分大小写。`simplezip://test?path=…` 被作为 `simplezip://check?path=…` 的别名接受。

### Check —— `simplezip://check?path=…`

测试 `path` 处归档的完整性。确认之后，该归档会被排入测试队列，结果在活动中心中报告。

```bash
open "simplezip://check?path=/Users/me/Archives/release.7z"
```

### Compare —— `simplezip://compare?left=…&right=…`

比较由 `left` 和 `right` 给出的两个归档（或文件夹）。两个参数都是必需的；若缺少任一个，该 URL 将被忽略。比较结果会进入活动中心。

```bash
open "simplezip://compare?left=/Users/me/Archives/old.zip&right=/Users/me/Archives/new.zip"
```

### Open —— `simplezip://open?path=…`

在 SimpleZip 中打开 `path` 处的文件或归档，与从 Finder 打开它相同。

```bash
open "simplezip://open?path=/Users/me/Archives/photos.zip"
```

### Extract —— `simplezip://extract?path=…`

解压 `path` 处的归档。解压目的地在对话框中选择或沿用你的默认设置。

```bash
open "simplezip://extract?path=/Users/me/Archives/archive.zip"
```

### Hash —— `simplezip://hash?path=…`

计算 `path` 处文件的 SHA-256 校验和。

```bash
open "simplezip://hash?path=/Users/me/Archives/release.tar.gz"
```

### Create —— `simplezip://create?path=…&format=…`

将 `path` 处的文件或文件夹按指定格式打包。`format` 参数可选值为 `zip`、`7z`、`tgz`。

```bash
open "simplezip://create?path=/Users/me/Documents/project&format=zip"
```

## 路径要求

- **仅限绝对路径。** 每个 path 参数必须以 `/` 开头。相对路径、`~` 以及非绝对的值都会被拒绝，该 URL 将被忽略。
- **必要时进行百分号编码。** 路径中的空格及其他保留字符必须进行 URL 编码（例如空格变成 `%20`）。

当某个值不满足这些要求时，该 URL 不做任何操作；SimpleZip 不会退回到某个猜测或默认路径。

## 自动化密钥

`simplezip://` 是全局 scheme —— 任何本地进程都能构造这样一个 URL，所以 SimpleZip 在默认情况下对每个来自其他应用的 URL 都会弹确认框。如果你在自己的脚本或本地自动化工具中调用 SimpleZip，可以配置**自动化密钥**来跳过确认。

### 获取你的密钥

打开 SimpleZip → 设置 → 自动化，在「URL Scheme」区域找到「可信密钥」。点旁边的「复制」按钮把密钥复制到剪贴板。

密钥是每台机器唯一生成的 UUID，不进设置备份——换 Mac 后会自动生成新密钥，旧脚本需要更新。

### 在 URL 中使用密钥

在 `simplezip://` URL 的 query 参数中加上 `key=你的密钥`：

```bash
# 不带密钥 → 弹确认框
open "simplezip://check?path=/Users/me/test.7z"

# 带正确密钥 → 直接执行，不弹框
open "simplezip://check?path=/Users/me/test.7z&key=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

带正确密钥的 URL 将**直接执行，不弹确认框**。这与「其它来源运行前确认」开关无关——带正确密钥的 URL 永远直接执行。

### 「其它来源运行前确认」开关

此开关（设置 → 自动化 → URL Scheme）控制**不带密钥**的 URL 的行为：
- **开启**（默认）：不带密钥的 URL 弹确认框
- **关闭**：所有 URL 都直接执行，无论带不带密钥

关闭此开关后，任何能在你 Mac 上跑 `open` 命令的进程都可以不受限制地让 SimpleZip 执行归档操作。仅在完全信任本地环境且理解风险时关闭。

> 快捷指令 App 里的 SimpleZip 动作走 App Intents 通道，**不使用此密钥**。

> 另有一个内部 host `simplezip://finder-action` 支撑 Finder 右键服务，它**不**属于本公开 scheme。它有自己更严格的校验（payload 必须是一个普通的、非符号链接的 JSON 文件，且直接位于用户的临时目录内），并不打算由人手工构造。

## 结果出现在哪里

URL scheme 动作与应用其余部分汇入同一条任务管线，并标记为 URL scheme 来源。Check 和 Compare 的结果，连同任何错误，都会出现在**活动中心**。自动化设置面板还会显示 URL scheme 上次被使用的时间，并按来源聚合统计数据。

## 另见

- [`CLI.zh-CN.md`](./CLI.zh-CN.md) —— `simplezip` 命令行配套工具。
- [`SHORTCUTS.zh-CN.md`](./SHORTCUTS.zh-CN.md) —— macOS 快捷指令与 App Intents 自动化接口。
- [`../SECURITY.zh-CN.md`](../SECURITY.zh-CN.md) —— 项目的安全模型与威胁假设。
