# SimpleZipCoreTests Fixtures

这里放的是预先打好的压缩包，专门给 `ArchiveServiceFixtureTests` 使用，回归测试归档「读」能力。

为什么要预录而不是测试里现场生成：现场生成等于「用同一份代码自证」，2024 年那一次 7zz upgrade 引入的目录条目顺序变化就是因为测试只读自己写出来的归档而漏掉的。预录的 fixture 把「写」和「读」拆开 ——「写」用规范工具（macOS 自带 `zip`/`tar`、bundled `7zz`、Python `zipfile`），「读」走 SimpleZip 的代码，二者发生分歧就会被测试捕到。

## 文件清单

| 文件 | 大小 | 工具 | 覆盖场景 |
|---|---|---|---|
| `plain_unicode.zip` | ~0.9 KB | `/usr/bin/zip` | UTF-8 中文文件名、嵌套目录、空目录的原生 ZIP 解析路径 |
| `plain_unicode.7z` | ~0.3 KB | bundled `7zz` | 中文 + 嵌套 + 空目录的 7-Zip 解析路径 |
| `plain_unicode.tar` | ~6.5 KB | `/usr/bin/tar` | tar 列表解析路径（tar 头比 zip 大，体积自然大些）|
| `aes256_password.zip` | ~0.9 KB | bundled `7zz` | ZIP AES-256 加密探测（detectZipEncryption）|
| `aes256_password.7z` | ~0.4 KB | bundled `7zz` | 7z header-encrypted（列出条目时必须密码）|
| `path_traversal.zip` | ~0.3 KB | Python `zipfile` | 含 `../escape.txt` 条目，验证 ArchiveSafety 能识别 |

固定密码：`fixture-pw`。

## 重新生成

```sh
./Tests/SimpleZipCoreTests/Fixtures/generate.sh
```

只有改动 payload 内容或工具产出格式发生变化时才需要跑。请把脚本的输出（包括新 fixture）一起提交，以便其他人无需复跑也能跑测试。

## 加新 fixture 的检查清单

1. 在 `generate.sh` 里追加生成步骤，注明「为什么这个 fixture 存在 / 想覆盖哪种 bug」。
2. 跑脚本，确认产出 < 10 KB —— 太大的 fixture 不要放在仓库，改在 generate.sh 里用 `seek` 造稀疏文件。
3. 在 `ArchiveServiceFixtureTests.swift` 里加对应测试，并在测试名里点出验证哪类回归。
4. 更新本 README 表格。
