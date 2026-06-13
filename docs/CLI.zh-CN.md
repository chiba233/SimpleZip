[English](./CLI.md) | **中文**

# `simplezip` —— 命令行配套工具

`simplezip` 是 SimpleZip macOS 应用的命令行配套工具。它**不是**一个独立的程序:它就是同一个
应用二进制,只是通过你 `PATH` 上的一个符号链接、以另一个名字被调用。正因如此,每条命令驱动的都是
应用所用的**同一套内置引擎** —— 内置的 7-Zip 引擎、可选的 RAR 与 GPG 后端,以及同样的归档、校验和、
对比逻辑 —— 产出相同的结果,带相同的安全检查。

当二进制以 `simplezip` 之名启动(或带一个前导的 `--cli`)时,进程进入 CLI 模式:它**不会**打开主窗口。
它针对真实后端运行所请求的命令、打印结果、把完成的命令记录进应用的**活动中心**,并以一个适合脚本与 CI 的
状态码退出。

## 安装与移除命令

在应用里安装和移除命令:**设置 → 自动化 → 命令行工具**。

- **安装**会在 `/usr/local/bin/simplezip` 创建一个指向应用二进制的符号链接。如果 `/usr/local/bin`
  不可写(Apple Silicon 上的默认情形,该目录归 `root` 所有),应用会弹出 macOS 标准的**管理员授权
  对话框**来创建链接。密码由系统 Security 框架托管,绝不经过应用本身。
- 如果该授权被取消或失败,应用会退而展示一条可直接复制的 `sudo` 命令,让你自己创建链接:

  ```
  sudo mkdir -p /usr/local/bin && sudo ln -sf '/path/to/SimpleZip.app/Contents/MacOS/SimpleZip' /usr/local/bin/simplezip
  ```

- **卸载**会移除该符号链接(同样会先退回管理员对话框,必要时再退回 `sudo rm /usr/local/bin/simplezip`)。

设置面板会显示当前状态 —— 已安装、未安装,或被一个指向别处的链接占用(陈旧的残留或同名的第三方工具)。
如果应用是从 Gatekeeper 转译位置运行(一个未清除隔离属性、原地启动的 DMG),安装会被禁用,因为链接会
指向一次性的临时挂载路径;请先把应用挪进**应用程序**。

## 用法

顶层用法字符串如下:

```
simplezip — SimpleZip command-line companion

USAGE:
  simplezip open <file>...                   Open files or archives in the SimpleZip app
  simplezip check <archive>...               Test archive integrity (exit 1 on any failure)
  simplezip compare <left> <right>           Compare two archives (exit 1 when different)
  simplezip create <output> <input>... [options]
                                             Create an archive; format from the output extension
  simplezip verify <checksum-file>...        Verify SHA256SUMS / checksums.txt / .sha256 / .md5 / .sfv
  simplezip doctor                           Check the CLI environment (app, backends, symlink)
  simplezip version                          Print version
  simplezip help [command]                   Show this help, or detailed help for one command

GLOBAL OPTIONS:
  --json        Print one JSON result object per command on stdout
  --quiet, -q   Only errors and the exit code
  --verbose     Stream the backend's raw output

NOTES:
  Finished commands are also recorded in the app's Activity Center.
  Passwords are never accepted on the command line — see `simplezip help create`.
  Exit codes: 0 success · 1 failures or differences found · 2 usage or environment error
```

运行 `simplezip help`(或不带参数的 `simplezip`)可看到这段文本,`simplezip help <command>`
可看到单条命令的详细帮助。

## 全局选项

这些旗标可以出现在命令行的任意位置;在解析子命令之前会先被剥离。

| 旗标 | 作用 |
| --- | --- |
| `--json` | 每条命令在 stdout 输出一个 JSON 结果对象。 |
| `--quiet`、`-q` | 只输出错误与退出码。 |
| `--verbose` | 透传后端的原始输出。 |

## 退出码

这套约定在每条命令与用法文本之间共享:

| 退出码 | 含义 |
| --- | --- |
| `0` | 成功。 |
| `1` | 发现失败或差异。 |
| `2` | 用法或环境错误。 |

## 命令

### `open`

```
simplezip open <file>...
```

在 SimpleZip 应用里打开文件或归档(等价于双击它们)。

### `check`

```
simplezip check <archive>... [--json] [--quiet] [--verbose]
```

用内置的 7-Zip 引擎测试归档完整性。多个归档会逐个测试,末尾打印一行汇总。加密归档会通过一个小对话框
询问口令 —— 口令绝不触及命令行。任一归档失败则退出 `1`。

带 `--json` 时,输出对象为:

```json
{
  "command": "check",
  "results": [ { "path": "/abs/archive.zip", "ok": true } ],
  "passed": 1,
  "failed": 0
}
```

`results` 中的每个条目带有 `path`、`ok`,失败时还带一个 `error` 字符串。

### `compare`

```
simplezip compare <left> <right> [--json] [--quiet]
```

对比两个归档的条目列表(路径、大小、CRC、修改时间、加密)。不同则退出 `1`,相同则退出 `0`。

纯文本输出把差异列为 `+ name`(新增)、`- name`(移除)、`~ path (fields…)`(变更),最后跟一行汇总。
带 `--json` 时,输出对象为:

```json
{
  "command": "compare",
  "identical": true,
  "added": 0,
  "removed": 0,
  "changed": 0,
  "unchanged": 12
}
```

### `create`

```
simplezip create <output> <input>... [options]
```

创建归档。格式来自输出文件的扩展名(`zip`、`7z`、`tar`、`tar.gz`、……)。你保存的按格式默认值
(**设置 → 压缩**)会自动套用;下列旗标在其上覆盖。**绝不覆盖已存在的输出文件。** 所有输入必须位于同一目录。

```
OPTIONS:
  --template, -t <name>   Apply a built-in task template (github-release,
                          windows-friendly, max-7z, encrypted-delivery,
                          source-code, backup)
  --level, -l <0-9>       Compression level
  --exclude-junk          Skip .DS_Store, AppleDouble, Thumbs.db, desktop.ini
  --reproducible          Deterministic output (zip/7z): same input,
                          byte-identical archive
  --encrypt               Encrypt the archive. The password is read from the
                          SIMPLEZIP_PASSWORD environment variable, or prompted
                          interactively on the terminal (never echoed).
                          It is NEVER accepted as a command-line argument.
```

各选项说明:

- `--template` 选择一个内置任务模板;模板自带格式,因此输出文件名的扩展名必须与之相符。
- `--reproducible` 只对 `zip` 与 `7z` 输出生效。
- `--encrypt` 要求一个支持加密的格式。口令来自 `SIMPLEZIP_PASSWORD` 环境变量,或来自交互式
  (无回显)终端提示 —— 绝不来自 `argv`。

带 `--json` 时,输出对象为:

```json
{
  "command": "create",
  "ok": true,
  "output": "/abs/output.zip",
  "sizeBytes": 12345
}
```

若读不到输出文件大小,则省略 `sizeBytes`。

### `verify`

```
simplezip verify <checksum-file>... [--json] [--quiet]
```

校验校验文件中列出的文件(GNU `sha256sum` 格式、BSD 标签格式、裸摘要、`.sfv`)。路径相对每个校验文件
解析;不安全的条目(绝对路径、`..`)会被拒绝。任何一项失败则退出 `1`;每个文件以及整轮运行各打印一行汇总。

带 `--json` 时,输出对象为:

```json
{
  "command": "verify",
  "files": [ { "file": "SHA256SUMS", "passed": 3, "failed": 0 } ],
  "passed": 3,
  "failed": 0,
  "ok": true
}
```

### `doctor`

```
simplezip doctor [--json]
```

检查 CLI 环境:本命令所属的 `SimpleZip.app`、内置的 7-Zip 引擎、可选的 RAR 与 GPG 后端,以及
`/usr/local/bin/simplezip` 符号链接是否指向本应用。该命令只读。

如果定位不到内置的 7-Zip 引擎,`doctor` 退出 `2`;RAR 与 GPG 后端是可选件,如实报告即可。带 `--json`
时,输出对象为:

```json
{
  "command": "doctor",
  "app": "/Applications/SimpleZip.app",
  "version": "X.Y.Z (build)",
  "sevenZip": { "path": "/…/Contents/Resources/7zz", "version": "…" },
  "rar": { "version": "…" },
  "gpg": { "available": true },
  "symlink": { "path": "/usr/local/bin/simplezip", "status": "ok → /…" }
}
```

### `version`

```
simplezip version
```

打印本 CLI 所属的应用版本。带 `--json`:

```json
{
  "command": "version",
  "version": "X.Y.Z (build)"
}
```

### `help`

```
simplezip help [command]
```

显示顶层帮助,或某条命令的详细帮助。

## 口令

口令**绝不**作为命令行参数被接受。

- `check`(以及其他读取类命令)在遇到加密归档时,会通过一个小对话框询问口令;口令直接喂给引擎,绝不
  出现在命令行上。
- `create --encrypt` 从 `SIMPLEZIP_PASSWORD` 环境变量读取口令,或从一个不回显输入的交互式终端提示
  读取。两者都没有时,命令会失败,而不是在没有口令的情况下继续。

## 活动中心

每条完成的命令也会被记录进应用的**活动中心**,因此从终端运行的 `check`、`compare`、`create`、
`verify` 会和你在 GUI 里发起的操作一起出现在应用的历史里。

## 另见

- [URL scheme](./URL-SCHEME.zh-CN.md) —— `simplezip://` 动作(`check`、`compare`、`open`)。
- [快捷指令与 Siri](./SHORTCUTS.zh-CN.md) —— App Intents 自动化。
- [架构](./ARCHITECTURE.zh-CN.md) —— 应用、Core 库与后端如何组合在一起。
- [SECURITY.zh-CN.md](../SECURITY.zh-CN.md) —— 项目的安全立场,包括口令与不可信归档输入的处理方式。
