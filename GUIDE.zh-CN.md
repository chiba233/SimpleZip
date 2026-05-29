[English](./README.md) | **中文**

# SimpleZip 使用指南

SimpleZip 是一个面向 macOS 的原生压缩包管理器。它不是只把命令行工具套进窗口里，而是尽量把日常压缩软件工作流做完整：
浏览文件夹、浏览压缩包、双击直接打开压缩包内文件、拖拽解压、创建压缩包、处理分卷、哈希、文件关联、默认后端设置和多语言。

项目主页：[github.com/chiba233/SimpleZip](https://github.com/chiba233/SimpleZip)

## 适合做什么

- 像 Finder 一样浏览普通文件夹。
- 像 7-Zip / NanaZip 一样浏览压缩包内部目录。
- 不先手动解压，直接双击打开压缩包里的文档、图片、安装包等文件。
- 把压缩包里的文件直接拖到 Finder 或其他目标位置。
- 创建 ZIP、7z、DMG、RAR、TAR、GZip、TAR.GZ、BZip2、XZ。
- 查看和解压分卷压缩包。
- 管理压缩包格式默认打开方式。
- 计算文件哈希，处理冲突，移动/复制/删除本地文件。

## 安装与后端

### 7-Zip 后端

SimpleZip 已内置官方 7-Zip 26.01 macOS universal `7zz`：

```text
SimpleZip/Tools/7zz
```

它同时包含 `x86_64` 和 `arm64`，开发构建时会被复制进 App 资源目录。设置里可以选择 7-Zip 后端：

- 自动；
- 软件内置；
- 系统安装。

自动模式会优先查找 App 内置路径，然后查找 Homebrew、`PATH` 等常见位置。你也可以安装系统版本：

```bash
brew install sevenzip
```

### RAR 后端

RAR 浏览和解压通过 7-Zip 完成。RAR 创建需要官方 RARLAB `rar` 命令行工具。

开发或本地打包时可以运行：

```bash
./scripts/install_rar_backend.sh
```

脚本会下载 RARLAB macOS ARM 和 x64 命令行包，合成为本地 universal：

```text
SimpleZip/Tools/rar
```

这个文件会被 git 忽略。RARLAB `rar` 是专有/shareware 软件；如果要公开分发带有该后端的 App 包，需要先取得 RARLAB 再分发授权。

## 支持格式

| 格式                                       | 浏览 | 解压 | 创建   | 说明                             |
|------------------------------------------|----|----|------|--------------------------------|
| `.zip`                                   | 支持 | 支持 | 支持   | 简单场景可用系统工具；复杂选项优先走 7-Zip       |
| `.7z`                                    | 支持 | 支持 | 支持   | 需要 `7zz` / `7z`                |
| `.rar`                                   | 支持 | 支持 | 支持   | 浏览/解压走 7-Zip；创建需要 RARLAB `rar` |
| `.tar`                                   | 支持 | 支持 | 支持   | 创建走系统 `tar`                    |
| `.gz`                                    | 支持 | 支持 | 支持   | 单文件压缩格式                        |
| `.tgz` / `.tar.gz`                       | 支持 | 支持 | 支持   | 创建走系统 `tar`                    |
| `.bz2`                                   | 支持 | 支持 | 支持   | 单文件压缩格式                        |
| `.xz`                                    | 支持 | 支持 | 支持   | 单文件压缩格式                        |
| `.dmg`                                   | 支持 | 支持 | 支持   | 通过 macOS `hdiutil` 创建和只读挂载     |
| `.001`、`.002`、`.z01`、`.r00`、`part02.rar` | 支持 | 支持 | 暂不支持 | 自动归一化到首卷                       |

## 打开文件夹和压缩包

### 打开文件夹

- 左侧栏选择个人文件夹、下载、桌面、文档、应用程序等位置。
- 使用顶部工具栏“打开”。
- 使用菜单栏 `文件 -> 打开文件夹`。
- 在位置栏输入路径。

### 打开压缩包

- 在文件列表里双击支持的压缩包。
- 使用菜单栏 `文件 -> 打开压缩包`。
- 从 Finder 拖入压缩包。
- 从 Finder 通过“打开方式”交给 SimpleZip。

分卷压缩包可以从任意常见分卷打开。SimpleZip 会尽量定位到首卷，例如：

```text
archive.002        -> archive.001
bundle.z01         -> bundle.zip
movie.part02.rar   -> movie.part01.rar
legacy.r01         -> legacy.rar
payload.7z.003     -> payload.7z.001
```

## 浏览压缩包

压缩包内部按真实目录浏览，不再把路径平铺成一堆长字符串。比如：

```text
Mos.app/Contents/PkgInfo
```

会显示成：

```text
Mos.app
└── Contents
    └── PkgInfo
```

常用操作：

- 双击目录：进入目录。
- 顶部“上一级”：返回上一层。
- 点击列表表头：排序。
- 拖动列表列：调整列顺序。
- 表头右键：进入设置里的列表列配置。
- 右键压缩包内项目：打开、解压选中项、解压整个压缩包、测试、哈希、在 Finder 中显示源压缩包。

如果压缩包没有显式保存目录项，SimpleZip 会自动合成目录节点，让浏览仍然像正常文件夹。

## 不解压直接打开

在压缩包里双击普通文件时，SimpleZip 会：

1. 把该项目临时解压到系统临时目录；
2. 调用 macOS 默认 App 打开；
3. App 退出时清理本次打开产生的临时目录。

适合直接打开：

- PDF、Word、Excel、图片、文本、代码文件；
- `.dmg` 磁盘映像：会临时解出后由 SimpleZip 只读挂载，并以文件夹方式浏览；
- `.pkg` 安装包；
- `.app` 这类包目录。

注意：如果你修改了临时打开的文件，修改内容通常不会写回原压缩包。需要保留修改时，请另存到正式位置。

## 拖拽

### 从压缩包拖出

可以把压缩包里的文件或文件夹直接拖到 Finder 或其他文件目标位置。SimpleZip 使用 macOS 的文件承诺机制：

- 拖动时不会立刻解压；
- 放手到目标位置后才解压对应项目；
- 如果目标位置已有同名文件，会报错，不会静默覆盖。

### 在本地文件列表中拖动

- 把文件拖到列表里的目录行上：移动到该目录。
- 从 Finder 拖文件进 SimpleZip 当前文件夹：复制到当前文件夹。
- 普通文件仍可拖出到外部 App 或 Finder。

## 解压

### 解压整个压缩包

打开压缩包后点击“解压”，或在普通文件夹里选中压缩包后右键“解压到此处”。

解压前会进入选项面板：

- 默认目标是压缩包所在文件夹；
- 需要换位置时点“保存到”；
- 可输入密码；
- 可打开“显示详情”查看后端实时输出。

### 解压选中项

打开压缩包后选中一个或多个文件/目录，右键“解压选中项”。

路径模式：

- 保持目录结构：按压缩包内原路径落地；
- 仅解压文件到目标目录：从深层目录里挑文件出来时更方便。

解压会先进入临时目录，再合并到目标目录。这样同名文件冲突会交给 SimpleZip 处理，而不是被后端直接覆盖。

进度条是尽力而为的后端输出解析，不是严格的字节级进度。不同格式、不同 7-Zip / tar / unzip 版本可能只提供不确定进度，或者出现百分比跳跃。

## 创建压缩包

在普通文件夹模式下选中文件或文件夹，然后点击“添加”。

创建面板支持：

- 文件名；
- 格式：ZIP、7z、DMG、RAR、TAR、GZip、TAR.GZ、BZip2、XZ；
- 压缩率；
- 密码；
- 跳过 `.DS_Store`；
- 跳过点开头隐藏文件，例如 `.env`、`.gitignore`、`.npmrc`；
- 自定义排除规则；
- ZIP、7z、RAR 分卷；
- 7-Zip 高级选项。

自定义排除规则可以一行一个，也可以用逗号分隔：

```text
*.tmp
build/*
node_modules/*
```

自定义排除区域有“计算”按钮。启用 `.DS_Store`、点开头隐藏文件或自定义规则后，点击“计算”会按当前选中的源文件统计预计会被排除的普通文件数量。

不同格式的限制：

- ZIP：优先使用 7-Zip；后端不可用且选项简单时可回退系统 `/usr/bin/zip`。
- 7z：需要 `7zz` 或 `7z`。
- DMG：使用系统 `/usr/bin/hdiutil create -format UDZO` 创建。多选时会先把选中的项目放入临时 staging 目录，确保 DMG 顶层就是这些选中文件 / 文件夹。
- RAR：需要 RARLAB `rar`。
- TAR / TAR.GZ：使用系统 `/usr/bin/tar` 创建。
- GZip / BZip2 / XZ：只能压缩单个普通文件。
- ZIP 密码能力取决于后端和加密方式；高强度加密建议优先使用 7z。

## 安全边界

SimpleZip 目前不是沙盒 App。它需要浏览和管理用户文件、启动命令行后端、挂载 DMG、拖拽导出、打开临时解出的文件，所以 Debug 和
Release 都关闭了 App Sandbox。这不是单纯的配置疏漏，但意味着安全边界必须明确：下载来的压缩包、RAR、7z、ZIP、TAR、DMG 都应视为不可信输入。

当前已有的保护：

- 解压先进入临时目录，再合并到目标目录；
- 合并阶段的同名文件冲突由 SimpleZip 处理，不让后端静默覆盖；
- 密码不会直接作为可见命令行参数传给后端；
- DMG 使用 macOS `hdiutil` 创建；浏览和解压时只读挂载；
- 双击打开压缩包内文件时打开的是临时副本，不会直接修改压缩包；
- 遇到 `../`、绝对路径、Windows 盘符、UNC 路径等可疑条目时，UI 会先询问再继续；
- 解压 staging 里发现符号链接时，会先询问再合并或打开；
- 从压缩包内打开 App、安装包、脚本、HTML、JavaScript 等主动内容前，会先询问；
- 设置 > 压缩 > 安全性里可以把这些行为改为“询问 / 始终允许 / 始终拒绝”；
- App 下次启动时会清理上次残留的压缩包临时打开目录。

需要谨慎的地方：

- 如果用户确认继续处理可疑路径，第一阶段仍依赖后端对 staging 目录的处理；
- 7-Zip 完整路径模式（`-spf`）会保留完整路径，只适合可信归档；
- symlink / hardlink 可能指向目标目录外的位置，取决于后端和归档内容；
- 从压缩包里打开 `.app`、`.pkg`、脚本、HTML、Office 文档等主动内容，确认后仍等同于从 Finder 打开临时副本；
- DMG 里可能包含恶意 bundle、隐藏文件、resource fork 或 quarantine 相关元数据。

## 兼容性矩阵

SimpleZip 后续应按行为维护兼容性，而不是只看扩展名：

| 格式  | 需要覆盖的场景                                                            |
|-----|--------------------------------------------------------------------|
| ZIP | UTF-8 文件名、旧编码文件名、ZipCrypto、7-Zip AES ZIP、符号链接、空目录、macOS 元数据、分卷 ZIP |
| 7z  | 加密文件名、固实压缩、符号链接、大字典、分卷                                             |
| RAR | RAR4、RAR5、多分卷、密码、可用时的恢复记录                                          |
| TAR | pax header、长路径、符号链接、硬链接、绝对路径、压缩 tar 变体                             |
| DMG | UDZO 创建、只读挂载、复制式解压、压缩包内 DMG 打开、隐藏文件、App bundle、卸载失败恢复               |

这张表不是承诺所有场景都已经自动化，而是后续补测试夹具和发布前手测的检查清单。

## 测试入口

核心回归测试在 SwiftPM 的 `SimpleZipCoreTests` 中，覆盖参数生成、列表解析、分卷归一化、排除规则、选中项展开，以及 ZIP / TAR
基础往返：

```bash
/usr/bin/xcrun swift test --scratch-path /private/tmp/SimpleZipSwiftPM \
  -Xswiftc -module-cache-path -Xswiftc /private/tmp/SimpleZipSwiftPM/ModuleCache
```

Xcode project 里也有 `SimpleZipCoreTests` 聚合 target，会调用同一套 SwiftPM 测试，避免只打开 Xcode 时看不到测试入口。

## 文件管理

普通文件夹列表支持：

- 打开；
- 添加到压缩包；
- 解压到此处；
- 测试压缩包；
- 哈希；
- 复制、剪切、粘贴；
- 移动到；
- 删除到废纸篓；
- 在 Finder 中显示；
- 拖拽移动或复制；
- 多选。

粘贴和解压遇到同名文件时，可以选择：

- 替换；
- 保留两者；
- 跳过；
- 哈希不同时替换。

“哈希不同时替换”会计算双方 SHA256，并在完成后显示比较结果。

## 哈希

选中本地文件后点击“哈希”。

支持算法：

- CRC32；
- MD5；
- SHA1；
- SHA256；
- SHA512。

结果窗口支持复制全部结果。

## 文件关联

设置里可以按格式单独设置默认打开方式。当前覆盖：

- `.zip`
- `.7z`
- `.tar`
- `.gz`
- `.tgz`
- `.bz2`
- `.xz`
- `.rar`
- `.dmg`
- `.001` 分卷组
- `.z01` 分卷 ZIP 组
- `.r00` RAR 分卷组

每一行会显示当前默认 App，并提供“设为默认”按钮。

## 设置

设置分为：

- 通用；
- 压缩；
- 浏览器；
- 文件关联；
- 列表列。

常用设置：

- 启动位置；
- 是否记住上次打开文件夹；
- 同名文件默认策略：询问、覆盖、跳过；
- 是否显示隐藏文件；
- 7-Zip 后端：自动、软件内置、系统安装；
- RAR 后端：自动、软件内置、系统安装；
- 文件列表列显示；
- 压缩包列表列显示；
- 界面语言。

语言切换后，重启 SimpleZip 会完整生效。

## 构建

命令行构建：

```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild \
  -project SimpleZip.xcodeproj \
  -scheme SimpleZip \
  -configuration Debug build
```

也可以直接用 Xcode 打开：

```text
SimpleZip.xcodeproj
```

然后运行 `SimpleZip` scheme。

## 常见问题

### 为什么 7z、RAR 或某些格式打不开？

请先到设置里查看后端路径和版本。7z、RAR 浏览/解压通常依赖 7-Zip；RAR 创建额外依赖 RARLAB `rar`。

```bash
brew install sevenzip
```

RAR 本地后端：

```bash
./scripts/install_rar_backend.sh
```

### 为什么双击压缩包里的文件没有写回压缩包？

SimpleZip 的“双击打开”是临时解压并交给默认 App。它适合快速查看或安装，不等于在压缩包内编辑文件。需要保存修改时，请另存到正式目录。

### 为什么分卷压缩包从 Finder 双击不一定进 SimpleZip？

系统是否把文件交给 SimpleZip 取决于 Launch Services 文件关联。请在设置的“文件关联”里把对应分卷组设为默认，或先用 SimpleZip
的“打开压缩包”选择分卷。

### 为什么 Xcode 控制台有 linkd / AppIntents / CoreSimulator 日志？

如果应用没有崩溃，这类日志通常是 macOS / Xcode 的系统服务噪声。实际构建结果以 `BUILD SUCCEEDED` 和应用行为为准。

### 为什么 Xcode 控制台有 NSXPCDecoder / NSSecureCoding 警告？

SimpleZip 没有直接使用 `NSXPCDecoder`、`NSSecureCoding` 或 `NSKeyedUnarchiver`。如果这类日志只出现在 Xcode
控制台、没有对应崩溃或功能失败，通常是 macOS 系统框架或远程服务输出的安全提示。

### 为什么某些格式只能压缩单个文件？

GZip、BZip2、XZ 本身是单文件压缩格式。如果要压缩多个文件，请选择 ZIP、7z、TAR、TAR.GZ 或 RAR。

### RAR 后端为什么不直接提交到仓库？

RARLAB `rar` 是专有/shareware 软件。项目提供本地安装脚本，但不会把 `rar` 二进制提交进 git。公开分发带 RAR 后端的 App
包前，需要确认再分发授权。当前安装脚本会要求用户阅读软件内附的说明和许可提示，并把 `rar` 安装到
`~/Library/Application Support/SimpleZip/Tools/rar`，不会把 RARLAB 二进制写进 App 包内。
