<!-- Thanks for contributing! 感谢贡献！ Keep the diff focused — one concern per PR. 一个 PR 只做一件事。 -->

## What does this change? / 改了什么

<!-- A short, plain-English summary. 一两句话说清楚。 -->

## Why / 为什么

<!-- The problem it solves, or a linked issue. 解决的问题，或关联的 issue。 -->
Closes #

## How was it verified? / 怎么验证的

<!-- Per the repo's verification matrix. 按仓库的验证要求填。 -->

- [ ] SwiftPM core tests: `swift test` — <!-- passed / failed / not run -->
- [ ] Xcode Debug build (for app/UI/extension/project changes) — <!-- passed / failed / not run -->
- [ ] Lint — not configured in this repo
- [ ] Docs-only change — verification intentionally skipped

## Checklist / 检查项

- [ ] Scope matches the title — no unrelated refactors mixed in. / 改动范围与标题一致，没夹带无关重构。
- [ ] New user-visible strings are localized in **both** `en.lproj` and `zh-Hans.lproj`. / 新增可见文案已在 en + zh-Hans 两份补齐。
- [ ] `CHANGELOG.md` and `CHANGELOG.zh-CN.md` updated for user-facing changes. / 用户可见改动已更新两份 CHANGELOG。
- [ ] No secrets, passwords, or private keys in code, args, or logs. / 没把密码 / 私钥写进代码、命令行参数或日志。
- [ ] I did **not** hand-edit version numbers (CI sets them at build time). / 没手动改版本号（CI 构建时设置）。
