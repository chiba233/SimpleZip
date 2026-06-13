[English](./URL-SCHEME.md) | **中文**

# SimpleZip URL Scheme

SimpleZip 注册了 `simplezip://` URL scheme，以便同一台 Mac 上的其他应用、脚本和自动化流程请求它执行一小组归档动作。每个动作都会**先在应用内确认**：当一个 `simplezip://` URL 到达时，SimpleZip 会弹出一个对话框，列出动作名称和完整文件路径，在你点击 **OK** 之前不会执行任何操作。

> 本文档描述公开的 URL 动词。等价的终端命令参见 [`CLI.md`](./CLI.md)；macOS 快捷指令 / App Intents 接口参见 [`SHORTCUTS.md`](./SHORTCUTS.md)。

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

三个动词都位于 URL 的 host 位置（`simplezip://<verb>`），并从查询参数读取操作数。参数名称是精确且区分大小写的；解析器会核对它们，而不是猜测。

| 动词 | URL 形式 | 参数 |
| --- | --- | --- |
| Check | `simplezip://check?path=…` | `path` |
| Compare | `simplezip://compare?left=…&right=…` | `left`、`right` |
| Open | `simplezip://open?path=…` | `path` |

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

## 路径要求

- **仅限绝对路径。** 每个 path 参数必须以 `/` 开头。相对路径、`~` 以及非绝对的值都会被拒绝，该 URL 将被忽略 —— SimpleZip 不会执行该动作。
- **必要时进行百分号编码。** 路径中的空格及其他保留字符必须进行 URL 编码（例如空格变成 `%20`）。这些值会按写入的样子从 URL 的查询项中读回。

当某个值不满足这些要求时，该 URL 仅仅是什么也不做；SimpleZip 不会退回到某个猜测或默认路径。

## 强制确认

`simplezip://` 是全局 scheme。**任何本地进程 —— 另一个应用、一个脚本，乃至交给 `open` 的一个网页 —— 都能构造这样一个 URL。** scheme 注册本身并不构成授权边界，因此 SimpleZip 绝不会静默地对某个 URL 执行操作。

在执行任何动词之前，SimpleZip 会：

1. 将自身切换到前台。
2. 弹出一个确认对话框，**列出动作名称并显示**即将使用的完整文件路径。
3. **仅在你点击 OK 时**才执行该动作。点击 Cancel 会丢弃该请求，什么也不会发生。

此确认是有意为之的，且**不可配置** —— URL scheme 始终是先确认。自动化设置面板会列出该 scheme 和示例 URL 以供参考，但不提供任何关闭该提示的途径。

在对话框出现之前，路径就已经过校验（上述绝对路径检查），而对话框是你对将要执行内容的最终复核。

> 另有一个内部 host `simplezip://finder-action` 支撑 Finder 右键服务，它**不**属于本公开 scheme。它有自己更严格的校验（payload 必须是一个普通的、非符号链接的 JSON 文件，且直接位于用户的临时目录内），并不打算由人手工构造。

## 结果出现在哪里

URL scheme 动作与应用其余部分汇入同一条任务管线，并标记为 URL scheme 来源。Check 和 Compare 的结果，连同任何错误，都会出现在**活动中心**。自动化设置面板还会显示 URL scheme 上次被使用的时间，并按来源聚合统计数据。

## 另见

- [`CLI.md`](./CLI.md) —— `simplezip` 命令行配套工具（`open` / `check` / `compare` / `create` / `verify`）。
- [`SHORTCUTS.md`](./SHORTCUTS.md) —— macOS 快捷指令与 App Intents 自动化接口。
- [`../SECURITY.zh-CN.md`](../SECURITY.zh-CN.md) —— 项目的安全模型与威胁假设。
