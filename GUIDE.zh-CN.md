[English](./README.md) | **中文**

# SimpleZip 使用指南

SimpleZip 是一个面向 macOS 的 7zz 图形客户端。目标不是做一个“能打开窗口的壳”，而是逐步补齐压缩软件该有的日常工作流：浏览、创建、解压、哈希、文件关联、文件管理和多语言。

项目主页：[github.com/chiba233/SimpleZip](https://github.com/chiba233/SimpleZip)

## 设计目标

- 像 Finder 一样浏览普通文件夹。
- 像 7-Zip / NanaZip 一样浏览压缩包内部目录。
- 压缩包内目录应该是正经目录，可以双击进入、上一级返回。
- 常用操作应同时出现在工具栏、右键菜单和 macOS 顶部菜单里。
- 设置项要可控，不做只有“一键全设”的粗糙入口。
- 目标系统保持在 macOS 13.0+。

## 安装与依赖

SimpleZip 的 ZIP 能力使用 macOS 自带工具。要处理 7z、tar、gz、tgz、bz2、xz 等格式，请安装 7-Zip CLI：

```bash
brew install sevenzip
```

SimpleZip 会查找这些路径：

- `/opt/homebrew/bin/7zz`
- `/usr/local/bin/7zz`
- `/opt/homebrew/bin/7z`
- `/usr/local/bin/7z`

## 构建

命令行构建：

```bash
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild \
  -project SimpleZip/SimpleZip.xcodeproj \
  -scheme SimpleZip \
  -configuration Debug build
```

也可以直接用 Xcode 打开：

```text
SimpleZip/SimpleZip.xcodeproj
```

然后运行 `SimpleZip` scheme。

## 基础操作

### 打开文件夹

- 左侧栏点击“个人文件夹 / 下载 / 桌面”。
- 或顶部工具栏点击“打开”。
- 或菜单栏：`文件 -> 打开文件夹`。

### 打开压缩包

- 直接双击文件列表里的支持格式。
- 或菜单栏：`文件 -> 打开压缩包`。
- 或把压缩包拖进窗口。

支持格式：

| 格式 | 浏览 | 解压 | 创建 |
| --- | --- | --- | --- |
| `.zip` | 支持 | 支持 | 支持 |
| `.7z` | 需要 7zz | 需要 7zz | 需要 7zz |
| `.tar` | 需要 7zz | 需要 7zz | 暂未开放 |
| `.gz` | 需要 7zz | 需要 7zz | 暂未开放 |
| `.tgz` | 需要 7zz | 需要 7zz | 暂未开放 |
| `.bz2` | 需要 7zz | 需要 7zz | 暂未开放 |
| `.xz` | 需要 7zz | 需要 7zz | 暂未开放 |

## 压缩包浏览

压缩包内部不是平铺路径列表。比如：

```text
Mos.app/Contents/PkgInfo
```

会显示成：

```text
Mos.app
└── Contents
    └── PkgInfo
```

你可以双击目录进入，也可以用顶部的“上一级”返回。

## 创建压缩包

在普通文件夹模式下选中文件或文件夹，然后点击“添加”。

创建前会出现选项面板：

- 格式：`ZIP` / `7z`
- 压缩率：仅存储、快速、标准、最大
- 密码：可选
- 跳过 `.DS_Store`
- 跳过所有 `.` 开头的隐藏文件
- 自定义排除规则

自定义排除可以一行一个，也可以用逗号分隔：

```text
*.tmp
build/*
node_modules/*
```

注意：

- ZIP 创建使用系统 `/usr/bin/zip`。
- 7z 创建需要 `7zz` 或 `7z`。
- ZIP 的密码能力来自系统 `zip` 的传统密码参数；高强度加密建议优先使用 7z。

## 解压

### 解压整个压缩包

打开压缩包后点击“解压”，或在普通文件夹里选中压缩包后右键“解压到此处”。

默认解压位置可在设置中调整：

- 每次询问
- 压缩包所在文件夹
- 下载

### 解压选中项

打开压缩包后选中一个或多个文件/目录，右键“解压选中项”。

会出现选项：

- 保持目录结构
- 仅解压文件到目标目录

“仅解压文件到目标目录”适合从深层目录里挑几个文件出来，不想带着整段路径一起落地。

## 哈希

选中本地文件后点击“哈希”。

当前支持：

- CRC32
- MD5
- SHA1
- SHA256
- SHA512

## 文件关联

设置里可以按格式单独设置默认打开方式，不是粗暴的一键全设。

当前支持逐项管理：

- `.zip`
- `.7z`
- `.tar`
- `.gz`
- `.tgz`
- `.bz2`
- `.xz`

每一行会显示当前默认 App，并提供“设为默认”按钮。

## 文件管理

普通文件夹列表右键支持：

- 打开
- 添加到压缩包
- 解压到此处
- 测试
- 哈希
- 复制
- 剪切
- 粘贴
- 移动到
- 删除
- 在 Finder 中显示

删除会移动到 macOS 废纸篓，不会直接物理删除。

## 多语言

设置里可以选择语言：

- 跟随系统
- 英语
- 简体中文
- 繁体中文
- 日语
- 泰语

语言切换后，重启 SimpleZip 会完整生效。

## 常见问题

### 为什么 7z 打不开？

请确认已安装 7-Zip CLI：

```bash
brew install sevenzip
```

### 为什么 Xcode 控制台有 linkd / AppIntents 相关日志？

如果应用没有崩溃，这类日志通常是 macOS / Xcode 的系统服务噪声。实际构建结果以 `BUILD SUCCEEDED` 和应用行为为准。

### 为什么某些格式只能解压不能创建？

当前创建入口先开放 ZIP 和 7z。tar/gz/tgz/bz2/xz 后续会继续补创建选项，避免把不成熟参数塞进 UI。
