[English](./CHANGELOG.md) | **中文**

# 更新日志

## 0.2.3

- **修复：Finder 自动解压浮窗显示「正在解压 %@」。** 单个压缩包的进度浮窗把没填充的格式占位符直接显示了出来，现在正确显示压缩包名字。
- **修复：取消 Finder 自动解压被当成失败。** 点「取消」会弹出「解压失败（CancellationError）」。现在取消只是关掉浮窗 —— 取消不是错误。
- **修复：冷启动打开 `.zip`/`.7z`（开了自动解压）会错误地拉起主窗口。** 之前那个冷启动补窗修复对**任何** Finder 打开都建主窗口；但开了自动解压时,解压必须留在独立浮窗里、绝不拉主窗口。现在冷启动遇到自动解压压缩包直接走浮窗。
- **自动解压彻底和主窗口脱钩 —— 包括 `.siz` 与 `.szs`。** 开了自动解压后，从 Finder 打开**任何**受支持文件（`.zip`/`.7z`/… **以及** `.siz`/`.szs`）都完全留在独立浮窗里：验签、解密、解压、`.szs` 清单校验全在浮窗内完成，主窗口绝不被创建、拉起或隐藏（冷启动、热运行都一样）。每个浮窗都加了 **「在主窗口打开」** 按钮，需要时（比如浏览 `.siz` 内容、把 `.szs` 以虚拟目录浏览）才由你主动拉起主窗口。关了自动解压则行为不变（仍在主窗口浏览）。
- **Finder 自动解压接入活动中心。** 每个 Finder / 右键解压都会在活动中心登记为任务（进度、取消、历史，**展开可看后端命令输出**），解压浮窗的「取消」旁边多了「活动中心」按钮可一键跳过去。
- **活动中心：计算哈希的结果现在会留下来。** 哈希任务以前算完只剩一个「完成」、毫无内容;现在展开详情会用和「文件哈希」弹窗**一样的格式化卡片**渲染(每个文件:大小、路径、CRC32/MD5/SHA-1/SHA-256/SHA-512),带「全部复制」——关掉弹窗后哈希也还在。结果(以及粘贴/移动的哈希对比)会随任务历史持久化,**重启 App 后历史里仍能展开查看**。哈希仍归「文件操作」。
- **活动中心：粘贴 / 移动的哈希比对改用格式化卡片展示。** 覆盖前比对内容时,展开任务详情会按文件渲染卡片(文件名、目标路径、源文件哈希 vs 目标文件哈希,以及「已跳过 / 已覆盖」徽标),不再是一坨文本。
- **活动中心：详情面板标题用对了。** 真正的后端命令(解压/压缩/测试)显示「命令输出」;哈希结果 / 文件哈希对比显示「结果」,不再被错叫成命令输出。
- **活动中心不再钉在最上层。** 它的窗口之前用了浮动层级,任何情况下都盖在所有窗口(甚至别的 App)之上。现在是普通窗口:打开时来到前台,之后可以像普通窗口一样被盖住。
- **活动中心：文件操作不再假装有「命令输出」。** 复制 / 移动 / 粘贴 / 删除 / 重命名不是后端命令,之前它们的行会一直转着「正在等待命令输出…」。文件操作的行现在**不再提供命令输出 / 详情面板**(只有真正跑后端命令的归档操作才保留)。
- **活动中心：计算哈希任务以文件命名。** 不再是泛泛的「正在计算哈希…」,单个显示「正在计算 xxx 的哈希」,多个显示「正在计算 xxx 等共 N 个文件的哈希」——历史里能看出算的是哪些文件。
- **活动中心：长哈希不再被滚动条遮住。** 哈希卡片列表预留了竖向滚动条宽度,SHA-256/SHA-512 不再被裁切。
- **修复:活动中心详情 / 历史可能丢失末尾输出。** 后端输出按 ~500ms 节流,Finder 自动解压完成时没先 flush 就持久化,历史可能缺尾部。现在完成前先刷尽缓冲。
- **修复:单个 Finder 自动解压的取消有时停不下来。** 之前只杀后端进程;若 7-Zip 已结束、任务在合并/移动阶段则停不了。现在会连外层任务一起取消(与批量解压一致)。
- **活动中心:「已跳过」结果归入「已完成」筛选。** 粘贴/移动因内容相同而什么都没改也是已结束态,按「已完成」筛选时不再被藏起来。
- **活动中心:历史保存改到后台线程。** 持久化任务历史(现含哈希)不再在任务完成瞬间阻塞 UI。
- **活动中心：跳过内容相同的文件不再显示成绿色成功。** 粘贴 / 移动到内容完全相同的文件上时,其实没有覆盖(复制被跳过)——但任务以前会显示绿色,像是写入成功了。这类「实际什么都没改」的结果现在显示为中性状态 + 明确说明(如「内容相同 — 已跳过,未覆盖」),且不播放完成提示音。
- **修复：整包解压在「开始前」像卡死，且这段卡顿里点取消还杀不掉。** 之前整包解压会在开始前扫两遍归档（一遍 `7zz l -slt` 做安全检查、再扫一遍只为给进度条数文件数），而且这遍扫描无视取消按钮。现在解压前只扫一遍、文件数复用给进度条，并且这步也能被取消。大归档 / 海量小文件时，开始前那段又长又像死掉的停顿没了。
- **性能：解压 / 压缩 / 测试不再无上限累积后端输出。** 开了逐文件日志后 7-Zip 会吐几万行，旧实现把它们在后台线程拼成一个不断增长的大字符串，大归档时能把整个 app 拖慢。现在这些命令只保留供失败诊断用的尾部（列表 / 解析类命令不受影响，仍保留完整输出）。
- **签名清单（`.szs`）现在支持文件夹。** 创建 `.szs` 时可以直接添加整个文件夹（不再只能逐个加文件），文件夹会被递归展开成其中所有普通文件、保留相对路径（符号链接跳过）。校验 / 浏览 `.szs` 时本就会按这些相对路径还原出嵌套目录树。
- **新增：设置 → 通用 加了「Finder 右键集成」一节。** 说明右键的「… with SimpleZip」是 macOS 服务，并直达 系统设置 → 键盘 → 键盘快捷键 → 服务 去启用/停用。

## 0.2.2

- **近期活动中心与 Finder 打开相关文案的本地化已补齐。** 德语、西班牙语、法语、日语、韩语、俄语、泰语和繁体中文现在都补上了英文 / 简体中文新增的 key，覆盖活动中心、Finder 自动解压、标签页 / 窗口打开、Finder 服务说明、结果面板以及带操作名的撤销 / 重做。
- **主窗口支持系统原生标签页（⌘T）和多窗口（⌥⌘N）。** 按 ⌘T 在当前窗口里开新标签、⌥⌘N 开一个独立的新窗口、视图 →「显示标签页栏」（⇧⌘T）可常显标签栏。SimpleZip 已在运行时从 Finder 打开压缩包或文件夹，会在新标签里打开，而不是替换掉你正在看的内容。这是真正的 macOS 窗口标签 —— 只有一个标签时标签栏自动隐藏，「移动标签到新窗口」/「合并所有窗口」都能用。每个标签 / 窗口完全独立（各自的文件夹、选区、撤销历史）。Dock 图标右键菜单也提供「新建标签页」和「新建窗口」，和「文件」菜单保持一致。设置、关于、更新窗口仍独立，绝不并进标签组。
- **修复：从 Finder 打开压缩包来启动 / 唤起 SimpleZip 时不弹窗口。** app 没在运行、或在后台运行但窗口全关了的时候，双击压缩包只是启动 / 唤起了 app，屏幕上却没有窗口 —— 得点一下 Dock 图标才出现。现在这两种情况都会可靠地为该文件打开一个窗口。（修复保留了防止 `.siz` / `.szs` 克隆出重复窗口的那层保护。）
- **新增：可选择打开落在哪里，以及逐项「在新标签 / 新窗口打开」。** 设置 → 通用 新增 **「在新标签页打开」**（默认开）：控制从 Finder 打开压缩包 / 文件夹时用新标签还是当前窗口。在浏览器里右键文件夹或压缩包可选 **「在新标签页打开」** / **「在新窗口打开」**。
- **修复：打开 `.siz` 时可能意外弹出快速查看。** 如果你之前用过快速查看并关掉了，打开 / 测试 `.siz` 会把那个已关闭的陈旧快速查看面板又顶回来 —— 因为「把主窗口带到前面」的逻辑顺手把所有隐藏窗口都显示了。现在它只显示真正的浏览器窗口。
- **修复：`.szs` 总是在新标签页打开。** 在浏览器里双击 `.szs` 现在和其它项一样在当前标签打开（之前它会绕一圈经系统再作为外部打开转回来，被迫开新标签）。
- **修复：从 Finder 多选解压会产生隐身、无法取消的后台任务。** 之前多选几个压缩包 →「用 SimpleZip 解压」会每个开一个浮窗、又立刻被下一个替换掉，前面的解压在后台不可见地继续跑（既看不到也取不消）。现在改为**单个浮窗的批量队列**——串行进度（「正在解压 1 / 3：…」）、一个「取消」停止整批、结束给出成功 / 失败汇总。
- **收紧 Finder 扩展回调校验。** `simplezip://` 动作回调现在会更严格地校验 payload（必须是命名符合约定、直接位于临时目录下的普通非符号链接 `.json` 文件）才会执行。
- **文件操作支持撤销 / 重做（⌘Z / ⇧⌘Z）。** 移动、粘贴 / 复制、创建副本、重命名、删除 现在都能从「编辑」菜单撤销和重做。撤销删除 = 从废纸篓移回原位；撤销复制 / 粘贴 / 副本 = 删掉新产物（仍可在废纸篓恢复）；移动、重命名原地反向。批量操作里即使后面的文件失败或用户取消，前面已经成功的步骤也会登记进撤销历史。保守设计 —— 撤销 / 重做会先确认文件仍是同一个、且未被外部改动；若文件期间被外部改动、或目标位置已被占用，该步会跳过并提示，绝不覆盖任何东西。（正在编辑名称 / 地址栏时，⌘Z 照常撤销打字。）
- **撤销 / 重做菜单会显示操作名，并在无队列时正确置灰。** 「编辑」菜单现在会明确写出将要撤销或重做什么，例如「撤销 移动」「重做 删除」；当焦点文本编辑器和文件操作历史都没有可执行项时，菜单项会禁用，不再给用户一个点了没反应的入口。
- **活动中心的归档操作基础已接入。** 创建、解压、测试现在会登记为 app 级活动任务，不再用新归档任务替换上一个归档任务。状态栏会显示进行中的任务数量和聚合进度，「详情」打开浮动活动中心窗口，「全部取消」会取消当前所有归档命令。每个任务都有独立进度、命令输出详情、取消句柄、结果状态和最近历史记录。
- **活动中心现在常驻可达、带标签切换，并记录文件操作。** 主工具栏的归档操作组右侧新增分隔线和常驻「活动中心」按钮，「工具」菜单也提供同入口。活动中心窗口改为在「归档操作 / 文件操作」之间切换，不再把全部任务堆在同一块里。粘贴、拖放复制 / 移动、重命名、删除、创建副本现在会进入「文件操作」分区，长时间传输可取消，瞬时动作也会保留完成记录。
- **哈希计算现在会显示在活动中心。** 对选中文件或 Finder 服务项目计算哈希时，会作为可取消的「文件操作」任务出现，可在同一个活动中心窗口里查看和停止，同时保留原有的哈希结果弹窗。
- **活动中心现在跟随设置窗口布局。** 分类标签移到左侧栏，密度、选中样式和可收起行为都与设置窗口一致，让主区域只专注显示当前选中的任务列表。
- **修复活动中心历史任务详情。** 已完成的归档任务现在会在收尾时刷入并保留最后一批命令输出，从历史记录打开「详情」会显示真实日志，不再卡在「正在等待命令输出…」；侧栏收起时标题也会给展开按钮留出空间。
- **活动中心历史记录现在会持久化且可配置。** 已完成的归档和文件任务会跨启动恢复；活动中心新增自己的「设置」页，可调整最多保留多少条历史记录并清理已完成历史；「归档操作」和「文件操作」也都加入了状态筛选。
- **修复活动中心设置页布局。** 历史记录设置现在会被限制在类似设置窗口的内容宽度内，并明确显示「清理历史」按钮，不再因为超宽行把控件推到窗口边缘。
- **活动中心的文件操作历史现在有实际信息。** 文件任务会直接显示移动 / 复制 / 删除 / 重命名了什么、落到了哪里，并在历史详情里保留每一项的来源 → 目标路径；7-Zip 跑分也会进入「归档操作」并保留输出。
- **修复活动中心入口上下文并收紧 UI。** 从归档任务的「详情」打开活动中心时，现在会自动切回「归档操作」，不再停留在上次选中的「文件操作」。任务行和活动中心设置页也改得更轻：使用更接近系统的行布局、更小的内联详情按钮，并减少卡片式的大块留白。
- **修复文件冲突跳过时活动中心没有日志。** 「内容不同才替换」发现哈希相同并跳过传入文件时，「文件操作」详情现在会记录被跳过的来源 → 目标路径，不再显示空的「正在等待命令输出」。
- **单文件复制 / 移动的冲突对话框更干净。** 当本次操作只有一个文件时，不再显示「将此选择应用到本次操作剩余的同名冲突」复选框，因为没有后续文件会受它影响。
- **多选「打开方式」更准确。** 多选不同类型文件时，子菜单只列出所有选中项共同可打开的 App，不再只按第一个文件猜；「其他…」仍可手动选择。
- **分组文件列表不再把分组头伪装成文件。** 框选 / 多选只要选中了真实文件，就会自动过滤掉分组头；单独聚焦分组头时，右键菜单提供「复制分组内全部文件」和「剪切分组内全部文件」。
- **「显示简介」对奇怪文件名更稳。** 调 Finder Get Info 的 AppleScript 路径现在会转义引号、反斜杠、tab、换行 / 回车，再交给 Finder 打开简介窗口；自动化 / Finder 错误继续用现有提示显示。
- **操作详情日志截断提示已本地化。** 长命令输出顶部的「更早的输出已省略」不再硬编码中文，会跟随应用语言。
- **内部整理：文件表格 helper 不再继续单体化。** 快速查看 / 拖动命中、文件列元数据、Finder 显示简介、打开方式 App 解析现在拆到各自的小 helper，不再继续堆进 `FileTable` / `TableSupport`。
- **修复：启用分组后键盘导航失灵。** 列表分组后，上下方向键卡在同一个组里、跨不到别的组 —— 因为光标一落到分组头，选区回灌就把它清掉了。现在方向键能贯穿整个列表跨组移动；选中分组头时按 空格 / 回车（或 ← / →）可折叠 / 展开该组。
- **文件操作有提示音。** 删除播放 Finder「移到废纸篓」声；粘贴、移动、创建副本、创建压缩包、解压 完成时播放一声轻柔的完成音。
- **「测试」快捷键从 ⌘T 改为 ⌃⌘T**，把 ⌘T 让给即将到来的「新建标签页」。
- **修复：SimpleZip 的 Finder 服务被归到「互联网」分类。**「添加到压缩包」/「计算哈希」/「解压」服务原本声明的是 URL 发送类型，导致 系统设置 → 键盘 → 服务 把它们列在「互联网」下。现在改为声明文件类型，归到本该所属的「文件与文件夹」分类。
- **Finder 扩展：一键「用 SimpleZip 创建 ▸ ZIP / 7z / TAR.GZ」。** 在 Finder 里右键文件选格式，按默认设置立刻出包 —— 无对话框、无二次确认。产物生成在选中项旁边并在 Finder 高亮（单个 →「名字.zip」，多个 →「Archive.zip」，绝不覆盖）。
- **Finder 扩展：「用 SimpleZip 解压」。** 在 Finder 里右键压缩包现在多了解压项（与「添加到压缩包」「计算哈希」并列）—— 通过轻量进度浮窗把每个选中的压缩包解到各自的文件夹。
- **创建副本（⌘D）。** 右键 →「创建副本」（或 ⌘D）在原位把选中的文件 / 文件夹复制成「<名字> 副本」，Finder 式、绝不覆盖（再复制依次「 副本 2」「 副本 3」…）。
- **修复：内联重命名输入框不消失。** 重命名某文件后点别的项、切文件夹、或按 Esc，输入框都会赖在屏幕上（只有回车能消）。现在点开别处 / 切换目录会提交重命名并收掉输入框，Esc 则取消 —— 与 Finder 一致。
- **修复：Finder 扩展菜单一直是英文。** 扩展是独立进程，只能看到「系统语言」，看不到 SimpleZip 的应用内语言覆盖 —— 所以即便 app 切到别的语言，右键菜单仍是英文。现在扩展会读取主 app 的语言偏好并加载对应本地化。（两端都未沙盒，无需额外授权。）

## 0.2.1

- **修复：`/home` 这类符号链接位置打不开。** 进入 macOS 的 autofs 触发挂载点（如 `/home`）时会报「未能打开文件」—— 原因是把原始 symlink 路径直接交给了目录枚举器。现在直接列目录失败时会退一步用解析后的真实路径再列一次，这些位置就能正常打开了。普通符号链接（`/etc`、`/var`、`/tmp`）本来就能打开、不受影响 —— 其条目仍保留原路径。
- **修复：从 Finder 打开压缩包时窗口不前置。** SimpleZip 已在后台运行时，双击压缩包（或用「打开方式」）只是启动 / 唤起了 app，窗口却留在后面，得再点一下 Dock 图标才真正看到压缩包。现在从外部打开压缩包和文件夹都会激活 app 并把主窗口带到最前。（Finder「自动解压」浮窗那条路径刻意不动。）
- **欢迎向导更短了。** 把「启动位置 / 覆盖行为 / 隐藏文件 / 列表大小 / 分组」五步合并成单个「常规设置」页（设置步骤 12 → 8）。所有控件和说明都保留 —— 每项设置做什么没有任何变化，只是少点几次「下一步」。
- **主窗口右键 →「打开方式」。** 本地文件现在有「打开方式」子菜单，列出系统注册的、能打开该文件的 App（默认 App 会标注），外加「其他…」可手动挑任意 App。单选、多选都适用。
- **本地化：修正机器乱翻的字符串** —— GPG、签名容器（`.siz` / `.szs`）、欢迎向导这几块在德语、西班牙语、法语、日语、韩语、俄语、泰语里的约 66 条字符串，之前要么是逐词替换（只翻了个名词、其余留着英文）、要么映射到了错误的文案；现已全部改为地道的母语翻译，并保留格式占位符与安全相关措辞。（繁体中文和两个主语言本来就是对的。）
- **修复：指向 .app 的符号链接被当成文件夹而非启动。** 指向 `.app`/`.bundle` 的符号链接（如某个 App 的替身）被当成可进入的文件夹，双击会进到里面。现在包判定会先解析符号链接目标，这类链接会像 Finder 一样直接启动对应 App。
- **修复：`.siz` 验签失败时能可靠弹出对话框。** 开了「Finder 自动解压」时，打开一个签名损坏 / 不受信 / 无法验证的 `.siz`（或解包过程中报错），现在会激活 app 并把验签 sheet 或错误提示带到最前，而不是留在没前置的窗口后面。
- **设置 → 视图：列开关与实时预览合到一处。** 预览上移到列勾选框正下方，勾选 / 取消某列时无需滚过「分组」一大段就能立刻看到效果。
- **设置描述写清楚。** 重写 7-Zip 后端说明（点明「自动」优先用内置、找不到再回退系统安装）、精简「什么算隐藏文件」的措辞，并在 GPG 导入密钥按钮下加了一句区别说明：导入到 `~/.gnupg`（与命令行 gpg 共用）vs SimpleZip 私有钥匙串（只存应用内、不污染命令行 gpg、卸载即清理）。
- **文件浏览右键菜单按分类分组。** 把又长又乱的右键菜单用分隔线切成几组：打开 / 查看、压缩 / 校验、编辑（重命名 / 复制 / 剪切 / 粘贴 / 移动 / 删除）、在 Finder 中显示 / 分组，并把「重命名」归到编辑组 —— 一眼就能扫到要找的项，不再是一坨。
- **设置窗口默认开得更高。** 设置项越来越多，原来的高度捉襟见肘 —— 默认高度从 560 提到 720（最小 600），仍可自由缩放。
- **删除文件改用 ⌘⌫（Finder 标准），不再用裸 Delete。** 裸 Delete 键在浏览或有选中时太容易误触；删除现在需要 Command-Delete，与 Finder「移到废纸篓」快捷键一致。
- **文件浏览支持 Finder 式快速查看与显示简介。** 按**空格**（或**重压文件图标**）对选中项快速查看；右键新增「**快速查看**」和「**显示简介**」（后者调起 Finder 原生 Get Info 窗口）。**重压文件名**则进入内联重命名，与 Finder「图标 vs 文件名」的行为一致。（「显示简介」首次会请求控制 Finder 的自动化权限。）
- **修复：通过「Finder 自动解压」打开破损压缩包时错误能可靠显示。** 解压浮窗本来就会显示失败，但 app 在后台时它可能被压在 Finder 后面看不到；失败时现在会激活 app 并把浮窗带到最前。成功解压仍保持安静（后台静默解压 + reveal）。

## 0.2.0

- **Group By —— 把文件 / 压缩包列表分成可折叠的区块。** 在 设置 → 视图 →「分组」里配置:一个**全局默认值**(不是总开关)—— 不分组 / 按种类 / 按修改时间 / 按文件与文件夹,文件浏览器和压缩包浏览器各一份。区块默认展开、可折叠。和「隐藏文件」组复用同一套 NSOutlineView 基建。
  - **按文件夹分组(文件浏览器):** 把文件浏览器的「分组范围」设为「按文件夹」,然后在任意文件夹里右键 →「此文件夹分组」给该文件夹单独设定(或「跟随全局默认」)。哪怕全局默认是「不分组」,某个文件夹也能单独开分组,反之亦然。按修改时间分:今天 / 昨天 / 过去 7 天 / 过去 30 天 / 过去一年 / 更早。
  - **隐藏文件 + 分组:** 同时显示隐藏文件时,隐藏文件**单独成一个「隐藏文件」组,组内再按同一维度分子组**(默认);也可在 设置 → 浏览 里改成「融进各分类组」。
  - 同时显示隐藏文件 + 分类时，设置 → 浏览 的「分类时的隐藏文件」选项决定隐藏文件是融进各种类区块、还是单列一个「隐藏文件」区块（默认融入）。

- **隐藏文件改为收进可折叠分组，不再塞满列表。** 开启「显示隐藏文件」后，隐藏项会收进文件夹末尾一个**默认折叠**的「隐藏文件 (N)」分组，点一下展开。设置 → 浏览 新增一个选项决定**什么算隐藏**：**仅 dotfile**（名字以 . 开头，Unix 习惯，默认）或**再算上 macOS `UF_HIDDEN` 标志的项**（如 `/etc`、`~/Library`）。默认仅 dotfile，所以 `/etc` 这类符号链接不再被误判为隐藏。这样文件夹保持清爽，又随时能拿到隐藏项。（开关关闭时行为不变 —— 隐藏文件根本不列出。）
  - 文件浏览表格底层从 NSTableView 重写为 NSOutlineView 以承载折叠分组，原生拖动、多选、列、排序、右键菜单全部保留。这也给后续的 Group By / Sort By 视图模式打了地基。
  - 设置 → 浏览 新增**「隐藏文件分组」**选项：分组一直折叠（默认）/ 记住每个文件夹 / 全局记忆，或者选**「平铺显示（不分组）」**完全退出该功能、回到 0.2.0 之前隐藏文件平铺混排的行为。改了立即生效。

- **文件夹视图自动刷新。** SimpleZip 通过 FSEvents 监视你正在看的文件夹，内容一变就自动刷新列表 —— 不管是你在应用内增删改 / 重命名，还是别的程序动了它。再也不用看着过期列表、手动按 ⌘R 才看到外部改动了 —— 而且自动刷新会保留你当前的选区。只有可见列表**真的变了**才刷新，后台文件系统噪声（`.DS_Store`、Spotlight 等）不再引发无谓重载或空闲闪烁。（⌘R 手动刷新仍然保留。）文件操作（粘贴 / 删除 / 重命名 / 拖入拖出）不再各自单独刷新 —— 统一由 watcher 刷新，少一类「忘了刷新」的疏漏。
- **重命名文件和文件夹。** 文件浏览现在支持重命名：选中后按 Return，或右键 →「重命名」，就地编辑名字。和 Finder 一样默认选中不含扩展名的主名。重命名绝不覆盖 —— 空名/没改当取消，含「/」（或「.」「..」）的名字直接拒绝，与已有项目重名会报错而不是盖掉对方。
- **列表大小** —— 设置 → 视图 → 「显示」→「列表大小」新增 紧凑 / 标准 / 宽松 三档，行高、图标、文字一起缩放，文件浏览和压缩包浏览都生效。标准维持原来的 28pt 行高，不主动选就和以前一样。
- **欢迎助手补齐更多设置** —— 首启向导新增 文件关联（把压缩格式默认应用设为 SimpleZip，可一键全设或按格式单设）、隐藏文件（显示 + 什么算隐藏 + 分组怎么折叠）、列表大小、分组默认 四个步骤。每步都绑和设置页同一个偏好，改了立即生效。
- **「Finder 自动解压」现在对 `.siz` 容器也生效。** 之前哪怕开了自动解压，双击 `.siz` 仍然只打开浏览。现在开了开关后，双击签名没问题的 `.siz`（或关闭 GPG 集成时）会静默把内容解压到 `.siz` 所在文件夹，跟普通压缩包一样；签名是坏的 / 不受信 / 无法验证时，照常弹验签对话框让你决定。
- **每次启动时检查更新** —— 通用设置新增的 opt-in 开关（欢迎助手的版本检查步骤也能设）。开启后 SimpleZip 每次启动会静默检查新版本，只有发现可用更新时才提示（与 Sparkle 自带的周期后台检查叠加，不替代）。
- **帮助菜单新增「提交 Bug…」** —— 直接打开 GitHub 新建 issue 页面。
- **清理临时文件**（设置 → 运行状态）—— 显示 SimpleZip 残留的临时产物占用多大，右侧一个「清理」按钮一键清掉。只动 SimpleZip 自己创建的条目（名字以 `SimpleZip` 开头），且只清**陈旧**的 —— 本次会话产生的（比如当前正打开的压缩包、进行中的 `.siz`/`.szs` staging）一律不碰，避免一键清理把正在用的文件从底下抽走。
- **备份导出现在是完整快照。** 之前导出会漏掉所有还停在默认值的设置，备份文件看着「根本不全」、也不是一份真正的快照。现在导出会把**每一项**可导出设置的有效值都写出来（含默认值），导出文件 = 一份完整、可自解释的配置记录。
- **备份新增可选「导出时包含按文件夹记忆」**（设置 → 备份，默认关）—— 按文件夹的分组覆盖、隐藏组展开记忆都是本机路径相关的数据，默认不写进导出文件；勾选后才包含。导入/还原始终按备份本身来（备份里没有就把本机现有的清掉）。

- **哈希现在可以取消** —— 运行时底部状态栏会显示「取消」按钮（之前长哈希没法中止）。取消在文件之间、大文件分块途中都会及时响应。
- **创建 / 解压 / 测试过程中随时能看「详情」** —— 不再只能在开始前勾「显示详情」。（并修复：**测试**操作的详情面板之前永远卡在「正在等待命令输出…」—— 测试命令的输出从未被喂给面板。）操作进行中状态栏会显示「详情」按钮，反悔了想看后端实时输出随时点开。（正常完成后面板自动收起；失败会保留以便排查。）
- **7-Zip 后端多处补上多线程。** 解压现在带 `-mmt=on`（之前单线程），单文件 `.xz` / `.bzip2` 压缩、以及完整性测试也都改成多线程（之前只跑一个核）。（注：7z/ZIP 创建和 RAR 本来就默认多线程；系统 `zip`/`tar` 和 `hdiutil` 不归我们控制线程。解压海量小文件主要受文件系统限制，不全是 CPU 瓶颈。）
- **修复：解压大压缩包时 GUI 卡死。** 逐文件输出一行的后端（像 Minecraft 文件夹那种几万个文件）之前每一行都更新一次 UI，把主线程刷爆。现在命令输出和进度都在后台线程缓冲、节流后再刷给 UI（详情日志只保留最近的尾部），不管后端吐得多猛，解压都流畅 —— 前后端真正分离了。解压后的符号链接安全扫描、以及把文件从暂存目录搬到目标目录，现在也都放到后台线程（之前在主线程遍历 / 搬几万个文件会把它堵死），全程窗口不卡。
- **修复：7-Zip「幽灵文件」。** `.7z` 里的目录如果被标了 `D` 属性但没有 7-Zip 自己的 `Folder = +` 标志，会同时显示成一个文件夹和一个同名的 0KB 幽灵文件。列表解析现在两种判据都认，目录条目不再漏成文件。
- **修复：创建对话框里「线程数」的值不显示**（7-Zip 高级选项）—— 之前只有 ▲▼ 箭头、没有数字。现在正常显示当前值（自动 / N）。
- **状态栏按钮不再乱跑。** 「详情 / 取消」改为固定在状态栏右侧，不再跟在长度多变的当前文件名后面左右漂移，操作途中位置稳定、好点。
- **修复：鼠标框选（橡皮筋复选）会闪烁、选区疯狂抽搐。** 两个原因：(1) 列表在**每次**选区变化时都 reload；(2) 每帧选区变化又把（滞后一帧的）选区猛灌回表格，把你正在拖的橡皮筋拽来拽去。现在只有真正的内容变化（文件、排序、分组、列、大小）才 reload，且**鼠标按着的时候不再回灌选区、也不自动刷新** —— 框选丝滑、松手后正确定型。
- **修复：智能卡 / stripped 密钥不再显示「导出私钥」。** 私钥在智能卡上（或已从本机 stripped）的密钥，本机根本没有可导出的私钥材料 —— `gpg --export-secret-keys` 只会导出一个无用 stub，给人「我备份了私钥」的错觉。现在只有本机真正持有可导出私钥材料时才显示该菜单项。（顺带说明：「导出公钥」用的是 `gpg --export`，只导公钥、绝不含私钥 —— 已实测确认。）
- **修复：拖动 / 切换列会冒出重复的「名称」列。** `NSOutlineView` 拒绝删除充当展开列（outline column）的「名称」列，于是每次重建列都残留旧的名称列、再加一个新的，越积越多，还把保存的列顺序污染成重复项。现在重建前先解绑展开列、并对列去重（同时修复已被污染的存量列顺序偏好）。文件浏览和压缩包浏览都受影响。
- **拖动只在图标或文件名上起手。** 之前在行内空白处（短文件名右侧、或别的列）按下再拖会触发整行拖动，挡住橡皮筋多选。现在只有正按在文件图标或名字文字上才开始拖动，按空白处则正常橡皮筋复选。文件浏览和压缩包浏览都生效。
- **杂项：**「创建签名清单」菜单项（主菜单 + 右键）改用 `signature` 图标，跟 GPG 设置里「默认签名密钥」行同款。

## 0.1.11

- **Bug 修复：Sparkle 签名成功之前就可能创建了公开 GitHub release。** 发版工作流把 `gh release create`（上传 DMG）排在 `sign_update` 和 appcast 生成**之前**。一旦 Sparkle 私钥缺失/无效或找不到 `sign_update`，任务会在「公开的、未签名的 release 已经存在」之后才失败 —— 违背 0.1.10「签名漏配就在发布前 fail」的承诺。现在签名 + appcast 生成先跑，签名产出之后才创建公开 release。
- **Bug 修复：GPG 关闭时 `.szs` 右键「以虚拟目录浏览」会失败。** 静默浏览流程总是先走 `gpg --verify`，所以 GPG 关闭时（常见原因是 gpg 根本没装）会报「缺少 GPG」，而不是按承诺只跑 SHA-256 校验。现在 GPG 主开关关闭时，直接从 clearsigned 明文里读 manifest（不经过 GPG）+ 跑每文件 SHA-256 校验；签名状态标为「未校验（GPG 未启用）」。新增 `SZSArchiveTests` 覆盖这条 GPG-free 路径。
- **文档修正：Sparkle 私钥处理的描述不准确。** `SECURITY.md`（中英两份）原称私钥「绝不走进程 env」。实际上它经由签名步骤 step 级、被 GitHub 自动 mask 的环境变量传入（Actions 推荐做法），再写到 `chmod 600` 临时文件供 `sign_update` 读。文档已据实改写：私钥不出现在命令行 / `ps` / 日志 / appcast 里，但在该步骤执行期间确实存在于这一步的进程 env 中。

## 0.1.10

- **列表列设置从 Settings 搬到顶层「视图」菜单**
  - 顶层菜单栏多个「视图」入口，下挂两个子菜单：「浏览器列」（文件浏览 7 项）+「压缩包列」（压缩包浏览 10 项）。这是 macOS 用户找列开关的天然位置（Finder 就在这里），切个列开关不用开设置窗口了。
  - 表头右键菜单同步重构：旧的「编辑列表列…」会跳到 Settings columns 分页，现在直接 inline 当前 scope 的开关项，✓ 反映当前状态（Finder 同款）。
  - Settings → Columns 分页改名为「视图」（icon `rectangle.3.group`）。列开关本体仍在这里作为唯一 canonical 入口；0.2.0 的多重分类 + 每文件夹视图设定会落在这同一页。
  - ColumnsPane 网格：4 个共用列（大小 / 种类 / 修改时间 / 创建日期）现在两侧同一行对齐，左右扫一眼能直接对上，不必反复在两列之间找。

- **压缩包浏览列扩 Tier 1 + Tier 2（共 10 项可选列，原本只有 4 项）**
  - 新增 6 列：路径（压缩包内完整路径）、加密（🔒，把 `ArchiveItem.isEncrypted` 这个一直在模型里但从没暴露过的字段拿出来）、压缩后大小、CRC、创建日期、属性（7z `Attributes` 字段）。
  - 6 项默认全关 —— 老用户看到的列跟以前完全一样，要不要这些列按需在「视图」菜单 / 表头右键 / Settings「视图」页打开。
  - Parser 侧：`7zz -slt` 长格式输出里的 `Packed Size` / `CRC` / `Created` / `Attributes` 接进 `ArchiveItem`；zip 后备路径和 DMG 后端不带这些字段，留空即可。排序比较器（`compareArchiveItem`）覆盖了 6 个新 key。

- **Bug 修复：表头右键菜单 ✓ 与列实际可见性脱钩**
  - 根因：菜单是构造一次后挂在 `headerView.menu` 反复使用，`item.state` 只是构造那一刻的 snapshot；而且老逻辑用 `UserDefaults.standard.bool(forKey:)`（未设置 = `false`）读，但列实际可见性走 `defaultTrueBool` / `@AppStorage(default: true)`（未设置 = `true`）。结果：新安装或刚做完偏好恢复的用户，每个从没碰过的列在右键菜单里**全部显示成不勾**，但表里**就是显示**的；第一次点 toggle 还朝反方向翻。
  - 修法：`ColumnHeaderMenuTarget` 实现 `NSMenuDelegate`，`menuNeedsUpdate(_:)` 时按 `UserDefaults` 当前值重算每个 `item.state`。`ColumnHeaderMenuBinding` 带每个 key 的 `defaultsToTrue: Bool`，让 helper 跟各 Pref accessor 的默认语义一致 —— 原 4 个 archive 列 + 7 个 file 列默认 ON，新 6 个 archive 列默认 OFF。

- **重构：`ArchiveBrowserModel.swift`（2330 行）拆成 9 个 extension 文件落到 `ArchiveBrowserModel/` 目录**
  - 核心文件只留 class 声明、`@Published` state、inner types（`CreateSZSPrefill` / `ManifestVirtualMode`）、init/deinit、UI-facing 计算属性（`title` / `locationText` / `canGoUp` / ...）。
  - 按功能切：`+Navigation`、`+Loading`、`+CreateExtract`、`+TestHashBenchmark`、`+FileOps`、`+Sort`、`+SafetyPassword`、`+OperationLifecycle`、`+SZSAndDiskImage`。原文件路径变成目录；Xcode 16 file-system synchronized groups 自动识别，不需要改 `pbxproj`。
  - 跨 extension 的 `private` 成员降级到 internal（默认）—— `final class` 没有继承面积，模块外可见性其实没变。行为不变；SwiftPM 109/109 全通过。

- **Swift 6 修复：`ExternalExtractWindow.run(...)` 的内层 `Task { @MainActor in }` 显式加 `[weak self]` 捕获**
  - 外层闭包捕获了 `[weak self]`，但内层 `Task`（Sendable 闭包）跨任务再次读这个 var `self?` —— Swift 6 直接 error。3 处（progress / updateStatus / updateProgress）都在内层 `Task` 自己加 `[weak self]`。

- **`.szs` 右键加「以虚拟目录浏览」（静默验签）**
  - 文件表里右键单选 `.szs`，「打开」之外多一项「以虚拟目录浏览」。后台跑跟「打开」一样的 `SZSArchive.peek` + `SZSArchive.verify`，**但只有出问题才弹 UI**。
  - 全部 OK（签名有效 + 每条 `.match`）→ 静默进虚拟目录模式，零 alert、零 sheet。信任清单来源、就想直接看签名子集的用户走这条。
  - 任意问题（签名坏 / 签名者公钥不在钥匙串 / SHA 不一致 / 文件缺失 / 文件读不了）→ 弹 alert 一行摘要，3 个选项：「只浏览通过校验的」（进虚拟模式但只显示 `.match`，跟现有逻辑一致的保守过滤）、「查看验签详情」（退回到标准 `SZSVerificationSheet` 看完整明细）、取消。
  - `gpgEnabled` 关时：忽略签名状态（跟「关了 GPG 主页面不显示任何 GPG UI」的现有规则一致），只有 SHA / 缺失 / 读不了的问题才触发 alert。
  - `.szs` 的「打开」语义不动 —— 还是永远弹验签 sheet。「每次都想看明细」的用户工作流不受影响。

- **Sparkle 自动更新接入 Ed25519（EdDSA）签名强校验**
  - `Info.plist` 加 `SUPublicEDKey` —— 0.1.10 起客户端拒绝任何 `sparkle:edSignature` 对不上的 DMG。此前 SparkleUpdater 注释里坦白「不做 EdDSA 签名」是有意为之的空缺：万一 `raw.githubusercontent.com` 路径被 MITM、或者仓库被入侵伪造 release，老版本是真的会装下去的。现在补上这层密码学屏障。
  - CI：`.github/workflows/release.yml` 在 publish 前跑 `sign_update` 对 DMG 签名，私钥来自新加的 `SPARKLE_ED_PRIVATE_KEY` GitHub Secret（写进 `mktemp` 临时文件，**不**进命令行 / env —— `ps` 看不到）。`sign_update` 输出的 `sparkle:edSignature="..." length="..."` 直接灌进 appcast `<enclosure>`，不再自己 `stat` 算 length，避免两份数值不一致。
  - 密钥生成：本地跑 `generate_keys --account simplezip-ci`，私钥进 macOS Keychain + 项目内 `secrets/` 文件夹（gitignored，**绝不**进仓库；上传 GitHub Secret 的完整流程见 `secrets/README.md`）。公钥放在 `Info.plist` 是 Sparkle 的标准做法 —— 只有私钥是机密。
  - **升级行为**：装了 0.1.9 的用户升 0.1.10 时**不校验**（他们本地还没公钥）；从 0.1.10 起所有 release 必须签，CI 漏配 Secret 会让 workflow 显式 fail 而不是默默发个不签的版本。
  - 同步刷新 `SparkleUpdater.swift` 文档注释 —— 之前那段「不做 EdDSA」的决策记录会误导后来读代码的人，改成「v0.1.10 起强制校验」。

## 0.1.9

- **0.1.9 发版前 Review 修了 8 个 bug**（一轮代码 review，全部赶在 tag 前）：
  - **P1** `GPGBackend.verifyClearsign` catch 分支丢明文 —— gpg 在 BADSIG / NO_PUBKEY 等情况下 exit code ≠ 0，旧版本直接返回 `Data()`，导致「签名出问题的 `.szs` 用户连 manifest 内容都看不到」。修：catch 分支也跑 `extractClearsignPlaintext(from: errorOutput)` 抽明文，让验证 sheet 仍能展示清单 + 同时把签名问题告诉用户。
  - **P1** `.szs` 「以虚拟目录浏览」未按 `.match` 条目过滤 —— 旧版本拿原始 manifest 全部条目构建 `allowedFiles`，结果未通过 SHA 校验的 `.mismatch` / `.missing` / `.unreadable` 也进虚拟视图，用户可能把这些**未验证**的文件当成「已验证」内容。修：`onOpenAsVirtualFolder` 回调改传 `VerifyReport`，model.`openSZSAsVirtualFolder` 只从 `.match` 条目构建 `allowedFiles`。
  - **P1** SIZSignatureSheet onOpen 解密失败 sheet 已 dismiss —— 旧版本 `pendingSIZVerification = nil` 写在 Task 外，sheet 立刻消失；解密失败时用户没法在 sheet 里换 picker / 重输密码重试，只能从 Finder 重新打开 `.siz`。修：清空 sheet state 挪到 Task 成功 branch，失败 branch 保留 sheet + 只设 `errorMessage`。
  - **P2** `.siz` v3 收件人 picker 列了 SimpleZip 私有 ring 公钥但 encrypt 只跑 user homedir —— 用户选这些公钥时 gpg 找不到 recipient → 加密失败但 UI 看着可选。修：新加 `encryptionEligibleKeys` filter `source == .userKeyring`，picker 只显示 user keyring 的公钥。
  - **P2** `SZSArchive.swift` 没进 SwiftPM target sources —— swift test 跑不到 .szs 路径校验 / manifest 解析 / SHA 校验等核心逻辑。修：Package.swift 加进 sources，编译通过 109 测试不破。
  - **P2** SZSVerificationSheet `verifyNow` race —— 用户切 payloadRoot 触发第二次 verify 时，第一次 Task 慢到了可能用旧 result 覆盖新的，UI 跟 payloadRoot 不一致。修：加 `verifyGeneration: Int` state，Task 写回前 guard 当前 generation 没变。
  - **P2** `CreateSZSSheet.chooseFiles` 错误状态不清 —— rejectedCount > 0 后 statusMessage 红字会一直挂到下次成功添加文件之后也不消失。修：chooseFiles 入口先清 statusMessage + statusIsError。
  - **P2** `.gpg` 后缀检查 case-sensitive —— 跨平台或手工拼包的 `.siz` 内层若叫 `archive.zip.GPG` 大写后缀，旧版本直接跳过解密。修：`.lowercased().hasSuffix(".gpg")`，提升容错。



- **`.szs` 新功能：「以虚拟目录浏览」**
  - 验证 sheet 底部多一个按钮「以虚拟目录浏览」—— 点了后退出 sheet，主窗口切到 payload root 文件夹模式，**只显示 manifest 里出现过的文件 + 含至少一个签名文件的祖先目录**，其他没签名的文件 / 文件夹隐藏。地址栏通过 `archiveDisplayOverride = .szs URL` 显示 `/Users/yumeka/Desktop/Desktop.szs` 样路径，假装用户在虚拟压缩包里浏览。
  - **退出语义**：用户「上一级」越过 payload root，`loadFolder` 检测到 → 自动 `exitManifestVirtualMode`，回到正常 Finder listing。不需要额外退出按钮。
  - **过滤实现**：`ManifestVirtualMode` 持有 `allowedFiles` 和 `allowedDirs`（从 manifest.files 算出来 —— 文件本身 + 走到 payload root 之间的所有祖先目录），`loadFolder` 拿 `fileBrowser.contents` 后按这两个集合 filter。
  - 模型层 `openSZSAsVirtualFolder(manifestURL:manifest:payloadRoot:)` 是唯一进入点；`ContentView` 在 SZSVerificationSheet 的 `onOpenAsVirtualFolder` 回调里调它。

- **`.szs` 默认输出名改成 payload root 文件夹名（不再 `manifest.szs` 写死）**
  - 例：Desktop 选文件签名 → 输出 `Desktop.szs`，落在 Desktop 里。语义上「这是某文件夹的签名清单」更清楚，多文件夹同时签也不会撞名。
  - 涉及：`CreateSZSSheet.applyPrefillIfAny`（右键流默认值）+ `chooseOutput`（NSSavePanel 默认名）。

- **bug 修复：双击 `.siz` / `.szs` 总开新窗口而不是用当前窗口（两轮修法）**
  - 现象：主窗口已经开着的情况下，Finder 双击 `.siz` 或 `.szs` 会再起一个新主窗口，不是在当前窗口里弹签名 sheet。
  - 第一轮修：删掉 ContentView 上的 `.onOpenURL` —— 让 SwiftUI 没有 handler 提示就不主动克隆窗口。**测下来还会克隆**。
  - 第二轮修（必要+充分）：在 `WindowGroup` 上加 `.handlesExternalEvents(matching: [])` 显式告诉 SwiftUI 「我不处理任何外部 URL / NSUserActivity 事件」。没这一行时 SwiftUI 看到 LSHandlerRank 路由进来的 `.siz` / `.szs` 仍会克隆 WindowGroup 窗口去满足「外部事件需要落到对应 scene」的约定。
  - 修法后路径：AppDelegate.application(_:open:) → `ExternalFileOpenQueue.enqueue` → notification → 现有 ContentView `.onReceive` drain 自处理。冷启动场景由 onAppear 里另一处 drain 兜住。全程一个窗口。

- **bug 修复：设置 → 文件关联里漏了 `.szs`**
  - 现象：`.szs` 已经在 Info.plist 的 UTExportedTypeDeclarations 里注册了，Finder 也能把双击路由进 SimpleZip，但「设置 → 文件关联」面板里没有 `.szs` 那一行，用户没法在 UI 里把 SimpleZip 设为 `.szs` 的默认 App。
  - 修法：`ArchiveAssociationService.supportedAssociations` 加一项 `.szs`（标题 "SimpleZip Signed Manifest"，绑 UTI `com.simplezip.szs-manifest`）。文件关联面板自动渲染。

- **bug 修复：CreateSZSSheet 右键流默认输出位置写错 —— Desktop 选的文件结果 .szs 落到了 `/Users/yumeka/Desktop.szs` 里**
  - 根因：`applyPrefillIfAny` 拿 payloadRoot 后做了 `.deletingLastPathComponent()`（跳到父目录）再 append `<payloadRoot 名>.szs` —— Desktop 的父是 home，输出落在 home 下叫 `Desktop.szs` 而不是 Desktop 里。逻辑完全反了。
  - 修法：直接 `payloadRoot.appendingPathComponent("manifest.szs")` —— `.szs` 现在跟被签名的文件**同目录 sibling**，符合设计文档的「drop a .szs next to the files」模式。

- **bug 修复：Cmd+A 主窗口文件列表里不能全选**
  - 现象：在主窗口选了文件列表后按 Cmd+A 没反应。Cmd+A 应该选所有文件 / 文件夹。
  - 根因：SimpleZipApp 的 pasteboard CommandGroup 的「全选」按钮挂了 `.disabled(!isTextInputFocused)` —— 字面意思「只在文本输入聚焦时才启用」。问题是主表格的 NSTableView 不是「文本输入」，所以全选按钮永远 disabled，Cmd+A 不发动。
  - 修法：拿掉 `.disabled` 让按钮始终启用；selector 从 `NSText.selectAll(_:)` 改为 `NSResponder.selectAll(_:)`（语义更准 —— NSText 和 NSTableView 共同基类都有这个方法）。NSTableView 默认实现 `selectAll(_:)` 选所有行，NSText / NSTextField 也是同样的方法，所以丢给 first responder 谁聚焦谁处理。

- **重大 bug 修复：Cmd+C / Cmd+V / Cmd+X 在主窗口失效（影响所有版本）**
  - 现象：主窗口里 Cmd+C / Cmd+V / Cmd+X / Cmd+A / Cmd+Z 全部不工作，按了没反应也不弹错。任何快捷键操作都好像被「吞掉」。
  - 根因：地址栏自定义的 `KeyboardTextField`（`TopBar.swift`）重写 `performKeyEquivalent` 接管这几个快捷键给地址栏 inline 编辑用 —— 但**没检查 `currentEditor()` 是不是 nil**。地址栏只要曾经在 first-responder 链里（用户点过一次就会一直在），`performKeyEquivalent` 就被调；`currentEditor()` 是 nil 时 `.copy(nil)` 是 no-op，但函数仍然 `return true`，等于「事件被声明已处理但实际啥也没干」。SwiftUI Commands / NSTableView 收不到事件，所有快捷键看上去失效。
  - 修法：`performKeyEquivalent` 的 `guard` 加 `let editor = currentEditor()`。currentEditor 为 nil 时（地址栏不在编辑态）直接 `super.performKeyEquivalent` 让事件正常下传到 SwiftUI / responder chain。
  - 影响：地址栏在编辑态时 Cmd+C/V/X/A/Z 仍然作用于地址栏文本；不在编辑态时所有快捷键回到正常 macOS 行为。

- **`.szs` 易用性：右键「创建签名清单」+ CreateSZSSheet 排版修复 + `.siz` 测试压缩包功能恢复**
  - **右键入口**：本地文件列表选中一个或多个文件 → 右键 →「创建签名清单…」（仅 GPG 启用 + 后端可用时显示）。点击后弹 `CreateSZSSheet` 预填 payload root（推断为选中文件的最深公共祖先目录） + 文件列表。**省去用户在 sheet 里重新挑根目录 + 文件**。
  - **`.szs` 创建 sheet 排版修复**：每行 label 用固定宽度（88pt）右对齐，content 自适应 —— 修复之前 label 宽度跟随文本撑得歪七扭八、TextField 被挤的问题。增加 `outputURL` 在右键入口下默认为 `<payloadRoot>.szs`，免手填。
  - **`.siz` 测试压缩包功能恢复**：`ArchiveBrowserModel.testArchive` 检测选中是 `.siz` → 路由进 `pendingSIZOpen` 同款流程，签名 sheet 本身就是测试结果（签名 + SHA 都对 = 容器完整、未篡改，等价于「测试通过」）。之前 `ArchiveService.test` 不识别 `.siz` 容器格式直接报错，`.siz` 用户实际上不能用「测试」功能。

- **`.siz` 打开 sheet 加解密 UI（picker + passphrase）**
  - `SIZSignatureSheet` 在容器加密时（`signature.encryption != nil`）显示「解密密钥」picker（仅有 recipients 时）+ 「解密密码」SecureField（仅 `hasSymmetricPassphrase` 时）。
  - sheet 把用户输入的值通过 `onOpen(decryptionKey, passphrase)` 回调传给 `ContentView`，再传到 `SIZArchive.decryptInnerArchive`。passphrase 走 `--passphrase-fd 0` stdin **不进 `ps`**；二者都空时让 pinentry-mac 兜底（保留之前的兜底行为）。
  - 跟解压 sheet 一样遵循「二选一」原则：自家 SecureField 有输入 → loopback 模式；没有 → gpg-agent + pinentry-mac 接管，不会同时弹两个密码框。

- **`.siz` v3 加密：多收件人公钥 + 可选对称密码 + 解密 picker 真正接上**
  - **格式扩展**：`SIZArchive.schemaVersion = 3`（unwrap 同时接 v2 / v3，向后兼容）。`Metadata` 新增 `encryption: EncryptionInfo?` 字段：
    - `recipients: [{fingerprint, userID}]` —— 公钥加密的收件人列表（空数组 = 仅对称加密）；
    - `algorithm: "gpg"` —— 算法标识；
    - `hasSymmetricPassphrase: Bool?` —— **是否带对称密码**的开关，密码本身**不**进 metadata（敏感数据不签名进容器里）。
  - **创建流程（性质级**）：勾「用 GPG 签名」后多两组 UI 在签名行下方：
    - **「加密给收件人」** —— Menu picker，列钥匙串里全部公钥（含自有），多次点击累加；选中项以 chip 形式横排显示，× 移除。0 个 = 不公钥加密。
    - **「加密密码（可选）」** —— SecureField。**跟收件人公钥并存**（gpg `--symmetric --encrypt` 同时给）—— 任一收件人私钥或正确密码都能解。两者全空 = 不加密（沿用 v2 仅签名行为）。
  - **后端**：`GPGBackend.encrypt` 一次跑 `gpg --batch --yes [--symmetric --pinentry-mode loopback --passphrase-fd 0] [--encrypt -r <fp> ...] --trust-model always --output <out> <in>`。Passphrase 走 stdin **不进 ps**；recipients 直接放命令行（fingerprint 本就不是机密）。`--trust-model always` 让没自签的他人公钥也能直接当收件人 —— 用户已经 UI 主动选了，没必要让 ownertrust 卡这一步。
  - **SHA256 in metadata = 密文 SHA**（不是明文）。让没有解密密钥的人也能校验完整性（sig + SHA 通过 = 容器真实未篡改），同时阻止「重加密攻击」（gpg session key 随机，每次密文不同）。
  - **解密流程**：
    - **解压路径**：`ExtractArchiveOptionsView` 已有「解密密钥」picker（0.1.8 上的 UI）现在真正消费 `request.gpgDecryptionKeyFingerprint`，传给 `gpg --local-user` 作 hint；新增 **「GPG 解密密码」** SecureField（仅当 `sizSignature.encryption.hasSymmetricPassphrase == true` 时显示），跟内层 ZIP/7z 的「密码」字段**完全独立**。`ArchiveBrowserModel.performExtractArchive` 检测 `.gpg` 后缀 + `sizSignature.encryption` → 先 `SIZArchive.decryptInnerArchive` 出明文 sibling，再走原本的 `ArchiveService.extract`；明文文件在 `defer` 里立即清掉，不让明文在 /tmp 里长期停留。
    - **打开路径**（浏览模式）：`handleSIZOpen` / SIZSignatureSheet 的 `onOpen` 在 `model.openArchive` 前先调 `decryptInnerArchiveIfNeeded`。`.gpg` 后缀 → 跑 `GPGBackend.decrypt`，passphrase 留给 pinentry-mac 弹原生密码框（公钥模式 + agent 缓存命中的常规路径）。解密失败给明确错误。
  - **后端 fallback 修复**：`gpgDecryptionKeyFingerprint` 之前在 0.1.8 只是 UI 占位，0.1.9 真接到 `gpg --local-user` 上。多密钥用户在 picker 选过的私钥真正会被尝试。

- **`.szs` 签名清单格式 v1 端到端实现**（设计 + Core + GPG + UI + UTI）
  - **格式**：`.szs` = GPG clearsigned 签名的 JSON 清单。**一份签名清单 + 多个外部文件留在原地** —— 跟 `.siz`（单文件容器）互补。用例：发布物（app + LICENSE + README + checksums.txt）、镜像树、按文件级完整性验证。`cat foo.szs` 直接看 JSON、`gpg --verify foo.szs` 命令行能验，单文件搞定不需要 sidecar `.sig`。
  - **Schema**：`{schema: "SimpleZip.szs", version: 1, createdAt, files: [{relativePath, size, sha256, mediaType?}], …}`。`files` 数组按 `relativePath` 字典序排序（确定性签名前提）；不含目录条目 / 不含 symlink / 不含 mode bits / 不含 mtime；`relativePath` 过 `validatedRelativePath` 拒 `..` / Windows 盘符 / UNC / 反斜杠等不安全成分。**详见 `docs/SZS-FORMAT.md`**。
  - **Core 实现**（`SimpleZip/Core/SZSArchive.swift`）：`Manifest` / `FileEntry` / `EncryptionInfo` 类型 + `create(payloadRoot:files:signingKey:title:description:outputURL:)` + `verify(manifestURL:payloadRoot:)` + `peek(manifestURL:)` + 确定性 `encodeManifest`。SHA256 复用 `SIZArchive.computeInnerArchiveSHA256` 1MiB 流式块计算，超大文件不爆内存。
  - **GPG 后端**（`GPGBackend`）：新增 `clearsign(plaintextURL:signingKeyFingerprint:outputURL:)` + `verifyClearsign(signedURL:)` → 返回 `(GPGVerifyResult, plaintext: Data)`。复用 `.siz` 同款 `--status-fd 1` 解析、两 pass merge（user keyring + SimpleZip 私有 ring）。
  - **UI**：
    - `SZSVerificationSheet`（验证报告）—— 顶部签名状态（复用 `SIZSignatureStatus` 图标 / 色 / 文案）+ manifest 元信息（标题 / 描述 / 创建时间 / 文件数）+ payload 根目录可选 + per-file 列表，每行带 ✓/✗/⚠ 状态徽章；mismatch 行可展开看 expected vs actual SHA256 对比；
    - `CreateSZSSheet`（创建对话框）—— 选 payload root + 多选要签名的文件 + 可选标题 / 描述 + 签名密钥 picker + 输出位置；文件列表展示相对路径 + × 移除；成功后 1.5s 自动关闭。
  - **菜单 + 文件关联**：File 菜单加「创建签名清单… (⇧⌘N)」（仅 `gpgEnabled` + GPG 后端可用时显示）；`Info.plist` 注册 `com.simplezip.szs-manifest` UTI 让 Finder 双击直接路由进 SimpleZip。
  - **`ContentView.handleSZSOpen`**：peek manifest → 弹 `SZSVerificationSheet`，默认 payload root = `.szs` 文件所在目录，用户可重选目录后重新校验。
  - **加密暂时不做** —— `.szs` v1 sign-only。加密用例由 `.siz` v3 覆盖（单 archive 多收件人），混在 `.szs` 里跨文件加密边界条件太多。

- **修：GPG 加密 / 解密密码长描述把对话框布局撑炸**
  - 现象：创建对话框的「对称密码」placeholder 太长（「对称密码，跟收件人公钥并存 = 任一可解」），SecureField 横向被挤压；解压对话框同款问题。
  - 修：placeholder 缩到 2-4 字（「可选 · 对称密码」/「GPG 对称密码」），长说明拆到 SecureField 下方 `.caption2` 灰色提示行 `.fixedSize(horizontal: false, vertical: true)` 自动折行。
  - **附记 GPG passphrase prompt 二选一原则**：encrypt / decrypt 函数在 `passphrase != nil` 时塞 `--pinentry-mode loopback`，自家 SecureField 取代 pinentry；passphrase 空时让 gpg-agent + pinentry-mac 接管。**两边永远只弹一个**。

- **修：`.siz` 解压对话框的「解密密钥」picker 一直不显示**
  - 历史 bug（0.1.8 落地以来一直存在）：`isSizExtract` 判定用的是 `request.archiveURL.pathExtension == "siz"`，但解压时 `archiveURL` 是 unwrap 后的内层 archive（`archive.zip` / `archive.zip.gpg`），后缀根本不是 `.siz`，结果 picker 永远 false。
  - 修：判定改为 `request.sizSignature != nil`（只有 `.siz` 走 unwrapAndVerifySIZ 时才会塞 sizSignature 到 request）。


- **Bug 修复（0.1.8 引入）：Sparkle 检查更新报「已是最新版」，0.1.7 用户永远收不到 0.1.8 升级提示**
  - 现象：0.1.7 用户菜单点「检查更新」时 Sparkle 说「SimpleZip 0.1.7 是当前的最新版本（您正在运行 0.1.7 (1)）」—— 完全错的，appcast 已经在 0.1.8 了。
  - 根因：0.1.8 release 的打包脚本把 `CURRENT_PROJECT_VERSION` 改成了 marketing string `RELEASE_VERSION`（"0.1.8"），同时 appcast 也写 `sparkle:version="0.1.8"`。但 0.1.7 用户本地的 `CFBundleVersion` 是 build_number（小整数），Sparkle `SUStandardVersionComparator` 拆成 `[1]` vs `[0,1,8]` 比，第一段 `1>0` → Sparkle 以为本地比 feed 更新 → 永远「已是最新版」。
  - 修法：**CFBundleVersion 和 `sparkle:version` 都改回单调递增整数（`BUILD_NUMBER` / `GITHUB_RUN_NUMBER`）**，marketing string 只走 `sparkle:shortVersionString`（UI 显示用）。这样 Sparkle 比较的两边都是单一数字，永远清晰。
  - 影响：0.1.7 用户在装上 0.1.9 之后菜单「检查更新」就能正常工作。**当前已发布的 0.1.8 用户也是同一个坑**（本地 CFBundleVersion="0.1.8" → 跟下次 sparkle:version=BUILD_NUMBER 比较时仍然能升）—— 0.1.8 / 0.1.7 用户都通过 0.1.9 出来可以正常拿到 Sparkle 更新流。
  - 改的文件：`scripts/build_unsigned_dmg.sh`（注释 + 重新用 BUILD_NUMBER）、`.github/workflows/release.yml`（appcast 模板 `sparkle:version` 改回 `${BUILD_NUMBER}`，加上 BUILD_NUMBER 到 step env 里）。

- **Bug 修复（0.1.8 引入）：打开 `.siz` 文件时设置窗口神秘弹出来**
  - 现象：用户在 SimpleZip 里曾经开过一次「设置」并关掉之后，后续打开任何 `.siz` 文件都会让设置窗口自动弹出来。
  - 根因：`ContentView.ensureMainWindowVisible()` 简单遍历 `NSApp.windows` 把所有 `!isVisible` 的窗口 `orderFront`。SwiftUI Settings scene 关闭后 NSWindow 仍存在于 `NSApp.windows` 列表里（hidden 状态），一并被拉起来。Sparkle 更新窗口 / 关于面板等也会受同一坑影响。
  - 修法：加 `isAuxiliaryWindow(_:)` 子串识别（identifier / title 含 "settings" / "preferences" / "sparkle" / "update" / "about" 或对应本地化标题），把这些辅助窗口从 `ensureMainWindowVisible` 的遍历里排除。`hideMainWindowIfPossible` 暂不改（用法只在 Finder 自动解压非 .siz 路径，没有 .siz 触发路径）。

## 0.1.8

- **多密钥用户友好：签名密钥 / 解密密钥 picker（创建 + 解压时挑具体用哪把私钥）**
  - **设置 → GPG 新增「默认值」子段**：当前一项 picker「签名密钥策略」=「静默使用默认密钥」（默认，单密钥用户体验不变）/「每次询问」（多密钥用户）。
  - **创建压缩包对话框 · ask 模式**：勾选「用 GPG 签名」后，下方新增「签名密钥 [chiba · D8B0...]」menu picker，列出所有 `hasSecretKey` 密钥（含智能卡 stub）+ 首项「默认 / 让 GPG 挑」（fallback 走系统）。Picker 初值 = `AppPreferences.gpgDefaultSigningKeyFingerprint`。
  - **创建对话框 · 自动滚动**：勾签名后 picker 出现在 ScrollView 底部，旧版要手动滑才看见 —— 现在用 `ScrollViewReader` + `scrollTo("gpgSignAnchor", anchor: .bottom)` 自动滚下来，0.25s 动画。
  - **`.siz` 解压对话框新增「解密密钥 picker」**：列所有 `hasSecretKey` 密钥 + 首项「让 GPG 自动选」。**仅 `.siz` 文件解压时显示** —— 通用 zip / 7z / rar / tar 不支持 GPG 非对称加密，picker 出现是噪音。0.1.8 picker 的选择暂时不消费（没有 GPG 加密 `.siz`），0.1.9 (.siz v3 多收件人加密) 接入；做成功能性 UI 而非占位是为了**多密钥用户从一开始就有能力选用哪把私钥**，避免 gpg 默认乱挑。
  - **后端 fallback 也修了**：之前 `ArchiveBrowserModel` 创建路径只看 `options.gpgSigningKeyFingerprint`，空时盲选「第一把 hasSecretKey」—— Finder Sync 等非对话框入口完全忽略 `gpgDefaultSigningKeyFingerprint` 偏好。现在 fallback 顺序：options 显式选 → prefs 默认 → 后端 first hasSecretKey。

- **UI 一致性修复：`.siz` 解压对话框字体大小错落**
  - 现象：SIZ 签名行（签名者 / 签名时间 / 公钥指纹）大、保存到 / 密码 行大，但「解密方式」picker 和它的选项明显小一号，混在一起看着难受。
  - 根因：`ExtractOptionsForm` 的 `Form` 上挂了 `.controlSize(.small)` —— Picker 会跟着缩成 small 字号，Text 不跟随，结果同行不同高。底部按钮行有自己单独的 `.controlSize(.small)`，不依赖外层。
  - 修法：拿掉 `Form` 上那个 `.controlSize(.small)`。Form 内所有控件回归默认 body，跟 Text 视觉对齐。底部按钮行不受影响。

- **GPG 验签管线大改：迁到 `--status-fd 1` 机器可读输出 + fingerprint 强校验**
  - **修了一个老 bug**：你自己设置成「终极信任」的密钥签的文件，sheet 还会显示「公钥已导入但未信任」。根因是旧解析依赖在 stderr 字符串里找 `not certified with a trusted signature` 这条 WARNING —— 这条文案受 gpg 版本、locale、trustdb 半同步状态影响极不稳定。新解析直接读 `[GNUPG:] TRUST_ULTIMATE/FULLY/MARGINAL/UNDEFINED/NEVER` 状态行，跟 gpg 的真值一致，**「终极信任」会被精确识别为 trusted=true**。
  - **两 pass merge 也修了**：之前如果用户公钥同时在 `~/.gnupg` 和 SimpleZip 私有两个 homedir 里，但只有一头有 ownertrust ultimate，merge 是「first validSignature wins」会吃掉那个 untrusted 的把 trusted 的覆盖掉。现在改成 **trusted=true 永远优先**，有 fingerprint 的次优先。
  - **新增 fingerprint 强校验**：`.siz` 验签现在会把 metadata 声明的 `signerFingerprint` 跟 gpg `VALIDSIG` 状态行报告的真实签名主密钥 fingerprint 比对，**不等就直接判 badSignature**。防御场景：攻击者拿到 `.siz`，修改 metadata 里的 signer 文案，用自己的密钥重签，但 fingerprint 字段忘了改 / 不能改 —— 不做这道校验会显示「来自原作者」的假签名通过。
  - **新增「签名仍有效但需要关注」三类状态**：`EXPKEYSIG`（密钥过期）/ `REVKEYSIG`（密钥已撤销）/ `EXPSIG`（签名本身过期）。这些情况下签名密码学仍有效但**不能完全信任**：sheet 标题改成「✓ 签名有效（但签名密钥已过期 / 已撤销）」，色块从绿降级为橙，文案明确说明（撤销尤其重要 —— 通常意味着密钥被怀疑泄露）。
  - 解析器有 `parseLegacyVerifyOutput` 文本兜底，仅在没收到任何 `[GNUPG:]` 状态行时启用（非 GNU gpg 实现极端兜底）；正常 GnuPG 不走这条。

- **GPG 钥匙串日常维护两件套：「修改 passphrase」+「添加 User ID」（GPG 钥匙管理收尾）**
  - 行尾 `…` Menu / 右键 context menu 仅 `hasSecretKey` 行新增两个操作（在「导出私钥」下方）：
    - **修改 passphrase**：打开 sheet 三个 SecureField（当前 / 新 / 确认）。后端 `GPGBackend.changePassphrase` 跑 `gpg --batch --pinentry-mode loopback --passphrase <old> --command-fd 0 --edit-key <fp>`，stdin 喂 `passwd\n<new>\n<new>\nsave\n`。旧 passphrase 走 cmdline arg（**会出现在 `ps`**，几秒就完，权衡可靠性）；新 passphrase 走 stdin（不进 ps）。新 passphrase 留空 = 移除加密保护，弹 NSAlert 二次确认。
    - **添加 User ID**：sheet 四个字段（姓名 / 邮箱 / 备注 / passphrase）。一把 GPG 密钥可以挂多个 UID（比如换邮箱、工作 / 私人两个地址、加个昵称），原有 UID 不动。后端 `GPGBackend.addUserID` 跑 `gpg --batch --pinentry-mode loopback --passphrase-fd 0 --quick-add-uid <fp> "Name (comment) <email>"`，passphrase 走 stdin。
  - 失败信息明确文案：修改 passphrase 失败时提示「旧 passphrase 是否输错？」（最常见原因）；添加 UID 失败把 gpg 错误转发给用户。
  - **GPG 钥匙管理至此收尾**（封存）：本机 / 智能卡 / SimpleZip 私有 ring 三类密钥 + 增删改查 + 信任级别 + 默认签名密钥 + 公私钥导入导出 + 撤销证书 + 修改 passphrase / UID / 过期 + 智能卡 binding 检测 ——「日常 + 应急」操作齐了。下一阶段转向**基于 GPG 的 SimpleZip 专属特性**（`.szs` 签名清单 / `.siz` v3 多收件人加密）。

- **Bug 修复：SimpleZip 私有 homedir 里造的密钥仍被分到「我的密钥（本机私钥）」组**
  - 现象：用户切换到 `--homedir` 后造密钥，密钥**确实**进 SimpleZip 私有 homedir 了（数据正确），但 GPGPane UI 还是把它显示在「我的密钥（本机私钥）」组里 —— 跟用户在 `~/.gnupg/` 的密钥混着。
  - 根因：`keyGroupsView` 的 `myLocalKeys` 过滤器只看 `hasSecretKey && !isSecretKeyStub`，**没看 `source`**。SimpleZip 私有 homedir 里造的密钥也有 hasSecretKey，被一锅端到本机组。
  - 修法：拆出第 5 个分组「我的密钥（SimpleZip 私有 · 独立 GNUPGHOME）」，过滤条件加 `source == .simpleZipKeyring`。本机私钥组也加 `source == .userKeyring` 限定，互不串组。
  - 五分组现状：本机私钥（~/.gnupg/）/ 智能卡 / SimpleZip 私有 / 他人公钥（GPG）/ 他人公钥（仅 SimpleZip），按 `(source, hasSecretKey, isStub)` 排列；空组不渲染。

- **SimpleZip 私有钥匙串切换到 `--homedir` 独立 GNUPGHOME（治本方案）+ 默认签名密钥乱码 bug 修复**
  - **「保存到 SimpleZip 私有」仍写到 ~/.gnupg/ 的根因**：上一轮加 `--primary-keyring` 后用户验证仍不行 —— gpg 在 `--quick-generate-key` 路径上对 `--no-default-keyring + --keyring + --primary-keyring` 三件套的行为版本之间漂移，某些 gpg 版本依然把新生密钥写到默认 `~/.gnupg/pubring.kbx`。修补无效。
  - **治本方案**：SimpleZip 私有改用 **`gpg --homedir <SimpleZip-gnupg-dir>`** 独立 GNUPGHOME。gpg 看到 `--homedir` 时**完全切到那个目录**当作独立 gpg 设置（独立 pubring / secring / trustdb / gpg.conf），无歧义。新位置：`~/Library/Application Support/SimpleZip/gnupg/`，目录权限强制 0700（gpg 强制要求）。
  - **真正的隔离**：之前 `--keyring` 时私钥仍存 `~/.gnupg/private-keys-v1.d/`，只算「半隔离」；现在私钥也进 `<SZ-home>/private-keys-v1.d/`，**完全独立**。卸载 SimpleZip 删 `~/Library/Application Support/SimpleZip/` 即彻底清理，0 残留。
  - **自动迁移老数据**：首次访问新 homedir 时，如果发现老的 `<SZ>/keyring/pubring.kbx` 存在且新 `<SZ>/gnupg/pubring.kbx` 不存在 → 把文件移过去。老用户已经导入 SimpleZip 私有 ring 的他人公钥不会丢。
  - **验签管线改两 pass**：之前用 `--keyring <SZ>` 叠加搜索的方案在 homedir 模式下不成立（`--homedir` 排他）。`GPGBackend.verify` 改为并发跑两 pass：默认 homedir（用户 `~/.gnupg/`）+ SimpleZip homedir。两个结果按「badSignature > validSignature > unknownSigner > verificationError」优先级合并 —— 最严重判定（被改）永远不会被另一 pass 的 valid 误判遮住。
  - 所有 SimpleZip-private 操作（list / import / sign / verify / setTrust / editExpiration / revoke / delete / createKey / exportSecret 等）全部切到 `--homedir <SZ>` 路径；冗余的 `--no-default-keyring` / `--primary-keyring` 删除。
  - 老的 `simpleZipKeyringDirectory()` / `simpleZipPubringPath()` / `simpleZipKeyringArguments()` 保留 deprecated 别名（指向新 homedir 路径），让 advanced 区「SimpleZip 私有 ring 路径」行不退化。
- **Bug 修复：默认签名密钥行显示「指纹: ...\"D\"\\, \"8\"\\\\, ...\"」一团乱码**
  - 现象：钥匙串顶部「默认签名密钥」状态行，如果当前默认 fingerprint 在 keyring 里找不到（用户删了这把密钥但 fingerprint 还在 prefs 里），显示出来的是几十行 `"\"D\""`, `"\"8\""`, `"\"B\""`... 一坨转义乱码（截图证据）。
  - 根因：`L10n.format("…%@", defaultSigningKeyFingerprint.suffix(16) as CVarArg)` —— `String.suffix(16)` 返回的是 `Substring`，Substring bridge 成 NSObject 给 printf-style format 时被当作 character sequence 序列化成 JSON 数组样子。
  - 修法：包一层 `String(...)` 强制转回 String 再传 format。

- **三个 GPG 钥匙串 UX bug 修复 + 缺失功能补齐**
  - **保存到 SimpleZip 私有钥匙串选项实际写到 ~/.gnupg/ 的 bug**：用户报告创建时选「SimpleZip 私有」，结果新密钥跑到「我的密钥（本机私钥）」组里。根因：`createKey` 给 `--no-default-keyring --keyring <SZ>` 但没加 `--primary-keyring <SZ>` —— 部分 gpg 版本下 `--quick-generate-key` 没有 primary-keyring 时仍写到默认 ring。三件套补齐后写入正确。
  - **删除按钮看不见的 bug**：之前删除 / 修改过期 / 生成撤销证书 / 复制指纹 / 导出公钥**全藏在右键 context menu** —— 用户根本不知道要右键。每行加显眼的 **「⋯」Menu 按钮**（borderless ellipsis.circle 图标），点开把所有操作摊出来。右键 context menu 保留给 power user。
  - **导出私钥功能**：菜单新增「导出私钥为 .asc…」（仅 `hasSecretKey` 行可见）。后端 `GPGBackend.exportSecretKey(fingerprint:source:)` 跑 `gpg --batch --pinentry-mode loopback --passphrase '' --armor --export-secret-keys <fp>`。导出的私钥**仍是 passphrase 加密的 blob**（gpg 不解密 secring 就能导出），导入到另一台机器仍要原 passphrase。文案提示「不要跟 passphrase 一起放」（分两处存：私钥在 U 盘、passphrase 在密码管理器）。
  - **新建密钥加 authentication subkey 选项**：之前 `--quick-generate-key default` 只造主密钥（sign+cert）+ encryption subkey，没认证密钥 —— 想用 GPG 密钥代替 SSH key 登录的用户被坑。sheet 新增「子密钥配置」section，显示默认就有的两项（签 + 加密）+ 可选 toggle「认证 — authentication subkey」。开了之后 createKey 在主密钥生成完后串跑 `gpg --quick-add-key <primary> <algo> auth <expire>` 加 auth subkey。同算法（ed25519 / RSA）保持一致。
  - 后端 `createKey` 加 `addAuthenticationSubkey: Bool` 参数 + auth subkey 串行调用。主密钥造完即返回 fingerprint，auth subkey 失败不抛错（避免「主密钥已造好但 UI 报错」的撕裂状态）。

- **「新建密钥」passphrase 改走 loopback —— pinentry-mac 不弹时也能用**
  - 上一轮加了 gpg-agent 预拉 + 流式状态 + 取消按钮，但用户反馈依然 pinentry-mac 不弹（macOS GUI app 进程环境差异 / `gpg-agent.conf` 没配 `pinentry-program` 等真实环境问题）—— 即使有取消按钮，「点了创建什么都不发生」依然是块石头。
  - **改方案**：新建密钥流程切到 `gpg --pinentry-mode loopback --passphrase-fd 0`。SimpleZip sheet 加 `SecureField` 收 passphrase + 确认 field，通过 stdin pipe 喂给 gpg（不进 cmdline，`ps` / Activity Monitor 看不到）。子进程退出后 passphrase 立即释放、不写盘、不进 Keychain。
  - **安全立场调整**：之前的「SimpleZip 绝不接触 passphrase」是漂亮的姿态，但前提是 pinentry-mac 100% 可用 —— 实际环境里不是。Kleopatra / GPG Suite 也用同款 loopback 解法。其他 GPG 操作（签名 / 解密 / 改信任级别 / 修改过期 / 撤销证书）**仍走 pinentry-mac**（gpg-agent 会缓存，不会每次都问），只是新建密钥这一锤改路径。
  - **留空 passphrase 二次确认**：UI 允许留空 = 创建无 passphrase 密钥，但弹 `NSAlert` 显式确认「私钥任何人拿到 ~/.gnupg/private-keys-v1.d/ 就能用，仅自动化 / 测试场景再这么做」。文案点明合法用途（CI / 短期测试密钥）+ 警告（被偷立即沦陷）。
  - **两次输入校验**：passphrase + 确认 field 不一致时显示红字提示「两次输入的 passphrase 不一致」，不进入创建流程。
  - **passphrase 强度提示**：placeholder「至少 8 字符；建议短句 + 数字 + 符号」给基础引导（不做强制校验，避免锁死合理但短的 passphrase）。
  - **liveStatus 状态文案保留**：上一轮的「正在启动 gpg-agent → 正在生成密钥材料 → 等待系统熵」三态仍然显示，加上「卡太久点取消」提示常驻。
  - 已删 sheet 里的「Passphrase 走 macOS 原生对话框」蓝色卡片（不再适用），替换为「Passphrase + Passphrase 输入区」蓝色卡片。
  - 撤销证书 / 修改过期等其他用 pinentry-mac 的入口暂时保留 pinentry 路径；如果这些也碰到「不弹」问题，下一轮单独迁移。

- **Bug + UX 修复：「新建密钥」一直卡在「正在生成密钥」 + passphrase 说明不明显**
  - **症状**：用户报告点「创建」后 sheet 一直显示「正在生成密钥…」死等。同时反馈「密钥不是可以设置密码吗？」—— 不知道 passphrase 是在哪儿设的。
  - **根因 1：UI 死等**：原 sheet 只有 `ProgressView` + 「正在生成密钥…」静态文案。pinentry-mac 密码框可能弹出但被其他窗口挡住 / 弹在其他 Mission Control 空间 / gpg-agent 没启起 pinentry —— 用户完全看不到底层在干什么，**也没有取消按钮可以挽救**。
  - **根因 2：passphrase 说明不显眼**：sheet 底部之前有「Passphrase 由 gpg-agent + pinentry-mac 弹原生密码框」说明，但只是一行小灰字，用户根本没看到。误以为 SimpleZip 没做 passphrase 功能。
  - **修法**：
    - **预拉 gpg-agent**：`createKey` 跑 `gpgconf --launch gpg-agent`（幂等）确保 pinentry 通道活着，跑失败也不阻断（gpg 自己也会 spawn agent）。
    - **流式状态更新**：`createKey` 加 `outputObserver` 回调，sheet 解析 `--status-fd 1` 输出的 `[GNUPG:] PINENTRY_LAUNCHED` / `PROGRESS need_entropy` / `KEY_CONSIDERED` 等 token 实时更新文案：「正在启动 gpg-agent…」/「正在生成密钥材料…」/「等待你在 pinentry-mac 密码框里输入 passphrase…」/「等待系统熵…」。
    - **取消按钮**：`createKey` 加 `operationID` 参数，sheet 生成时给 `BackendProcessRunner` 注册 ID，用户随时点「取消」杀掉 gpg 进程恢复。取消后显示「已取消密钥生成」错误。
    - **passphrase 说明卡片化**：sheet 中间用蓝色高亮卡片明确写「点「创建」后，gpg-agent 会调出 pinentry-mac 弹独立的 macOS 密码框让你给新密钥设置 passphrase。SimpleZip 全程不接触 passphrase（更安全 + 更标准）。如果点了「创建」十几秒还没看到密码框，请检查 Dock / 其他 Mission Control 空间 / 通知中心」。用户清楚知道密码到底在哪儿输。
    - **troubleshoot 提示常驻**：生成中的状态横条下方常驻一行小灰字：「看不到密码框？检查 Dock 通知 / Mission Control 其他空间 / 「设置 → GPG → 高级」里 pinentry-mac 是否就绪。卡太久点「取消」终止。」用户卡住时知道怎么自救。

- **新功能：GPG 密钥 lifecycle 三件套 ——「修改过期时间」/「生成撤销证书」/「删除密钥」**
  - 每行密钥右键 context menu 新增 3 个操作（复制 fingerprint / 导出公钥之后）：
    - **修改过期时间**：仅 `hasSecretKey` 的密钥可见（需要 gpg 访问私钥）。打开 sheet 选新过期（永不 / 1y / 2y / 5y），点应用走 `gpg --edit-key <fpr> expire <duration> save`。即将过期可延期，已过期也可重新启用。
    - **生成撤销证书**：仅 `hasSecretKey` 可见。打开 sheet 选撤销原因（未指定 / 已泄漏 / 已被新密钥替代 / 不再使用）+ 描述 textarea。生成后弹 NSSavePanel 让用户存到 `.asc` 文件。**sheet 顶部显眼说明撤销证书的「自毁开关」意义**：应在密钥还能用时就提前生成 + 保存到离线介质（U 盘 / 纸质 QR），等私钥真出事时来不及了。
    - **删除密钥**：所有密钥可见（带 destructive 红色样式 + Divider 隔开）。用 `.alert` 标准 macOS destructive 双确认。文案按密钥类型差异化：
      - 公钥行（`!hasSecretKey`）：单 confirm + 提示「仅删公钥，未来还需要可以重新导入」。
      - 含本机私钥（`hasSecretKey && !isSecretKeyStub`）：强调「私钥一旦删除**无法恢复**，签过的文件未来无法再签 / 解密给你的内容永远解不了。建议先生成撤销证书再删」。
      - 智能卡 stub（`isSecretKeyOnSmartcard`）：说明「仅删本机 stub，卡上私钥不受影响，重新插卡 + 从智能卡导入公钥即可恢复」。
  - 删除恰好是当前默认签名密钥时，自动清空 `gpgDefaultSigningKeyFingerprint` 偏好 —— 不让 UI 指向一把已不存在的密钥。
  - **Passphrase** 全程交给 gpg-agent + pinentry-mac 弹原生密码框；SimpleZip 不接触 passphrase（[[feedback-gpg-release-emphasis]]）。
  - 后端：
    - `GPGBackend.deleteKey(fingerprint:deleteSecret:source:)` —— `--batch --yes --delete-secret-and-public-key` 或 `--delete-keys`，按 source 加 `--no-default-keyring --keyring <SZ>`。
    - `GPGBackend.setKeyExpiration(fingerprint:expiration:source:)` —— `gpg --command-fd 0 --edit-key <fpr>` 喂 `expire\n<duration>\nsave\n`。
    - `GPGBackend.generateRevocationCert(fingerprint:reason:description:source:) -> String` —— `gpg --armor --command-fd 0 --gen-revoke <fpr>` 喂 `y\n<reason>\n<desc>\n\ny\n`，返回 ASCII armor 文本，调用方写文件。
    - 新 enum `GPGRevocationReason`（none / compromised / superseded / notUsed）。

- **Bug 修复：关掉智能卡 toggle 后「设为默认」按钮在卡上密钥行消失**
  - 用户报告：开了智能卡 toggle 时 OpenPGP 卡密钥能「设为默认签名密钥」；关掉 toggle 后这把密钥降级到「他人公钥」组，「设为默认」按钮也消失了 ——「啥意思」。
  - 根因：上一轮我把 `canBeDefaultSigner` 改成「智能卡 stub 且 toggle 关 → 不可设默认」，把功能能力跟 UI 显示混在一起。错的。
  - 修法：智能卡 UI toggle 只影响**展示**（分组 + 卡按钮 + 卡 binding 状态行）；功能上 keyring 里 secret stub 还在、`gpg --sign` + 插卡仍可工作。`canBeDefaultSigner = key.hasSecretKey` 改回单纯看 keyring 状态，跟 UI toggle 解耦。
  - 影响：用户关掉智能卡 toggle 后，卡上密钥仍能被设为默认签名密钥；用 SimpleZip / CLI 签东西时插卡 + 输密码即可。

- **新功能：GPG「新建密钥…」+ 双 ring 选择**
  - 钥匙串操作按钮组新增「新建密钥…」，弹独立 sheet。
  - **保存位置在 sheet 顶部**（按用户要求）：radio 二选一
    - 「保存到 ~/.gnupg/（默认）」：标准 `gpg --quick-generate-key`，公钥进 `~/.gnupg/pubring.kbx`、私钥进 `~/.gnupg/private-keys-v1.d/`。CLI 立刻可见。
    - 「保存到 SimpleZip 私有钥匙串（公钥隔离）」：加 `--no-default-keyring --keyring <SZ>/pubring.kbx`，公钥仅进 SimpleZip ring，不污染 CLI keyring。
  - **诚实告知私钥位置 caveat**：选择 SimpleZip 私有时 sheet 上明确说「⚠ 私钥仍保存到 ~/.gnupg/private-keys-v1.d/」—— gpg 的 secring 是全局的，无法通过 `--keyring` 改变。要全私钥隔离需用 `--homedir`，那是另一种工作流。不让用户误以为完全隔离。
  - 表单字段：姓名 / 邮箱 / 算法 picker（Ed25519 推荐 / RSA 4096 / 3072 / 2048）/ 过期时间 picker（永不 / 1y / 2y / 5y）。表单基础校验：姓名非空 + 邮箱含 `@`。
  - **Passphrase** 全程由 gpg-agent + pinentry-mac 弹原生密码框收 —— SimpleZip 进程不接触 passphrase（[[feedback-gpg-release-emphasis]]）。sheet 底部明确提示「如果对话框没弹出，请检查本机有没有装 pinentry-mac」。
  - 后端 `GPGBackend.createKey(name:email:algorithm:expiration:into:) async throws -> String`：跑 `gpg --status-fd 1 --quick-generate-key "Name <email>" <algo> default <expire>`，从 `[GNUPG:] KEY_CREATED B <fingerprint>` 状态行解析新密钥 fingerprint 返回；gpg 漏报时 fallback 扫整段输出找 40 字符 hex。
  - 创建成功后自动 refresh 钥匙串显示，下方状态行显示「已创建新密钥：…<short fp>」。

- **Bug 修复：关掉智能卡 toggle 后智能卡密钥完全消失**
  - 用户报告：本机有 OpenPGP 卡公钥，但在「设置 → GPG」关掉智能卡支持后，那把密钥从钥匙串列表里彻底没了。
  - 根因：`keyGroupsView` 里只有「`gpgSmartcardEnabled` 且有 stub 密钥」时才渲染智能卡组；关掉 toggle 时既不在智能卡组也不在「我的密钥（本机私钥）」组（hasSecretKey=true 但 isSecretKeyStub=true 把它从本机组排除），又不在「他人公钥」组（hasSecretKey 不是 false）—— 三组都接不住，整段消失。
  - 修法：关闭智能卡 toggle 时，智能卡 stub 密钥**降级**到对应 source 的「他人公钥」组（按 `.userKeyring` / `.simpleZipKeyring` 路由）。视觉上跟普通公钥同居一组，「卡上」/「stripped」badge 仍展示让用户知道真实状态，但行尾「设为默认签名密钥」按钮自动消失（不让用户把一个「无私钥可用」状态的密钥设默认）。
  - 影响：用户即使关闭智能卡功能（不想看智能卡分组），公钥本身仍然可见、可作公钥使用（验签 / 加密给对方）—— 不会感觉「数据丢了」。

- **GPG 钥匙串视觉打磨 + 解析 bug 修复**
  - **修 parser**：现代 gpg `--list-secret-keys --with-colons` 输出里，智能卡 stub 标记不在 type 字段后缀（旧的 `sec>` / `ssb>`），而是放在**第 14 字段（index 13）**装卡 serial（如 `F1D0+0131337E`）。之前只 check 了 type 后缀 → 现代 gpg 输出全漏 → 用户「主密钥 + 2 副密钥」三把卡上密钥被错放进「本机私钥」组、subkey 「卡上」badge 不出现。现两个位置都识别（field 14 非空 → 卡上；field 14 是 `#` → stripped），跨 gpg 版本兼容。
  - **主密钥行加 capability chip**：之前只有 subkey 行显示「签 / 密 / 认」等 capability 图标，主密钥的能力只能从外推。现在主密钥的 `field 11 capabilities` 串里小写 s / e / a / c 字符各渲染成等宽 chip，让用户立刻看到「主密钥能做什么」。
  - **「卡上」/「stripped」badge 提升到主行**：之前藏在 caption（次行小灰字）；现在主行 fingerprint 旁直接出 orange 「💳 卡上」/ secondary 「🗝/ stripped」chip。智能卡密钥一目了然。
  - **chip 等宽**：「签 / 密 / 认 / 证 / 卡上 / stripped」chip 现在所有图标固定 11pt 槽位 + label 等宽对齐，视觉一致（之前 SF Symbol 宽度差异导致看着歪七扭八）。
  - **详情可折叠**：每行新增「详情 ▶」按钮，默认折叠 —— 主行只展示 userID / 短指纹（16 字符 long key ID）/ capability chips / 卡上 badge / 默认按钮 / 信任 picker，密度合理。点「详情」展开完整 40 字符 fingerprint + 卡上说明 + 子密钥列表。每行可独立展开。
  - **按钮 / picker / 默认 chip 高度统一**：之前「设为默认」用 `.mini`、信任 picker 用 `.small`、「✓ 默认」chip 又是自定 padding —— 三个控件视觉高度全不同，行末参差不齐。现在「设为默认」和「✓ 默认」都对齐到 `.small` 高度。
  - **加 capability 类 chip**：`c` (certify) 主密钥能力之前没暴露 —— 现在显示「证」chip（多数主密钥都有 certify 能力，UI 区分小灰色避免抢戏）。
  - **chip 去掉 SF Symbol，纯文字**：上一轮加图标后发现 `signature` 是花体签名飘带（不是普通图标），跟「签」字撞色一团 mess（见 issue 截图）。改成纯文字 chip（「签 / 密 / 认 / 证」单汉字），靠 padding + 颜色对比区分。等宽天然，视觉干净。
  - **智能卡检测加「直接问卡」第二条路径**：之前只解析 `--list-secret-keys --with-colons` 输出找智能卡 stub 标记，但 gpg 不同版本里这个标记的字段位置漂移（有的版本是 type 后缀，有的是 field 14，有的是 field 15）—— 解析永远漂移。现在 listKeys 额外跑 `gpg --card-status --with-colons` 直接问卡硬件本身报告的 fingerprints，跨 gpg 版本稳定。`smartcardPrimary` / `smartcardSubkey` 集合 union 两条路径的结果 —— 任意命中即标卡上。没插卡时 card-status 直接 fail silently，不打扰用户。
  - **影响**：之前用户 OpenPGP 卡上的主密钥被错放进「本机私钥」组、subkey「卡上」badge 不出现的 bug（即使开了智能卡 toggle），现在自动修复。

- **GPG 钥匙管理 Round 2：子密钥展示 / 公钥隔离 / 默认签名密钥 / 智能卡反查 / 右键菜单**
  - **子密钥（subkey）列表**：每把主密钥下方缩进展示所有子密钥，每个 subkey 一行显示「短指纹 + 能力 chip (签 / 密 / 认) + 「卡上 / stripped」标记 + 过期标」。之前 SimpleZip 把「主 + 3 副密钥」的 OpenPGP 卡只画一行 = 信息丢 2/3，CLI 用户一看就知道在隐瞒东西。
  - **修正智能卡 stub 标记**：之前误把 `#` 当成卡上标记，实际上 gpg 用 `>` 表示「私钥在卡上」、`#` 表示「私钥已 stripped」（已删除）。两者语义不同 —— 现在分别识别：`isSecretKeyOnSmartcard` / `isSecretKeyStripped` 两个字段独立追踪，UI 各自图标 + 各自文案。
  - **公钥隔离 ring**：他人公钥不再被强制写入用户 `~/.gnupg/`，新增「导入到 SimpleZip 私有钥匙串」按钮 → 写到 `~/Library/Application Support/SimpleZip/keyring/pubring.kbx`。卸载 SimpleZip 即可清理，不污染用户 CLI 设置。原「导入公钥…」按钮拆成两个：「导入到 ~/.gnupg…」（共享）和「导入到 SimpleZip 私有钥匙串…」（隔离）。他人公钥分组也对应拆成「他人公钥（GPG keyring 共享）」+「他人公钥（仅 SimpleZip）」两组。
  - **验签自动跨 ring 搜索**：`SIZArchive.verify` / `GPGBackend.verify` 给 gpg 加 `--keyring <SZ>/pubring.kbx`，让用户 `~/.gnupg/` 已有的公钥 + SimpleZip 私有 ring 都参与签名验证 —— 用户「只导入到 SimpleZip ring」的他人公钥也能验签 .siz。
  - **智能卡 binding 状态行**：智能卡支持开启后，钥匙串顶部新增一行「插入的智能卡 [检测]」。点「检测」跑 `gpg --card-status --with-colons` 拿卡 serial / vendor / holder name / 三个用途 subkey fingerprint，然后反查本机 keyring 告诉用户「这张卡绑了哪把主密钥」。卡上 subkey 在 keyring 找不到时给「请先用『从智能卡导入公钥』拉公钥到 keyring」提示，不让用户卡在「为什么签名密钥识别不出来」。
  - **默认签名密钥**：新偏好 `AppPreferences.gpgDefaultSigningKeyFingerprint` —— 钥匙串顶部一行展示当前默认（UID + 短指纹 + 「清除」按钮）；每个本机私钥 / 智能卡 stub 密钥的行尾出现「设为默认」按钮，已是默认显示绿色 ✓「默认」chip。设置好的 fingerprint 会在后续创建 .siz / .szs / `.gpg --sign` 时作为 fallback 签名者（用户在创建对话框里仍可显式覆盖）。
  - **行内右键 context menu**：任意密钥行右键 →「复制公钥指纹」（NSPasteboard 写整个 40 字符 fp）+「导出公钥为 .asc…」（NSSavePanel + `gpg --armor --export <fp>`；源 ring 自动选 `.userKeyring` / `.simpleZipKeyring` 不会跨 ring 误导出）。
  - **高级区新增**：「SimpleZip 私有 ring」路径展示，让用户一眼能看到隔离的 keyring 文件位置（方便手动 `gpg --no-default-keyring --keyring <path> --list-keys` 验证）。
  - **后端**：
    - `GPGBackend.GPGKey` 加 `subkeys: [GPGSubkey]` / `source: GPGKeyringSource (.userKeyring | .simpleZipKeyring)` / `capabilities: String` / `isSecretKeyOnSmartcard` / `isSecretKeyStripped`，原 `isSecretKeyStub` 收成 computed property（兼容旧调用）。
    - 新 struct `GPGSubkey`（fingerprint / capabilities / isOnSmartcard / isStripped / isExpired / `canSign / canEncrypt / canAuthenticate`）。
    - 新 struct `GPGCardStatus`（serial / vendor / holderName / subkeyFingerprints / linkedPrimaryFingerprint）。
    - `parseColonsList` 重写：识别 `sec>` / `ssb>` 卡上标记 + `sec#` / `ssb#` stripped 标记；解析子密钥记录；解析 capability 字段。`parseFingerprints` 拆成三态 `SecretKeyMode (fullSecret / smartcard / stripped)`。
    - 新方法：`simpleZipKeyringDirectory()` / `simpleZipPubringPath()` / `simpleZipKeyringArguments()` / `listKeys(from:)` / `listKeys()` 合并去重 / `importKey(from:into:)` / `exportPublicKey(fingerprint:source:)` / `setTrustLevel(...:source:)` / `cardStatus()`。
    - `verify()` 在 gpg 调用参数前加 `--keyring <SZ>` 实现两 ring 同时搜索。
  - **隐私 / 安全保证**：
    - 仅 SimpleZip 私有 ring 的公钥**不会**写入用户 `~/.gnupg/` —— 用户卸载 SimpleZip + 删 `~/Library/Application Support/SimpleZip/` 就彻底清理，CLI 用户的钥匙串完全不变。
    - 卡 binding 反查只匹配 subkey fingerprint，不读卡上任何 PIN / 密钥材料；卡未插入时不会 spam 错误。

- **重做：GPG 设置面板钥匙串强分区 + 信任级别 picker + 智能卡 opt-in 支持 + 高级 / 普通设置分层**
  - 钥匙串列表从一坨平铺改成**三分组**：「我的密钥（本机私钥）」/「我的密钥（智能卡 / OpenPGP token）」/「他人公钥」。`hasSecretKey && !isSecretKeyStub` / `hasSecretKey && isSecretKeyStub` / `!hasSecretKey` 三种组合分别落盘到对应组。空组不渲染标题。
  - 每行 GPGKeyRow 增加 **信任级别 Picker**（5 选 1：未设置 / 永不信任 / 勉强信任 / 完全信任 / 终极信任）。点选立即调 `gpg --command-fd 0 --edit-key <fpr>` 喂 `trust\n<menu-number>\ny\nsave\n` 落盘，改完自动 refresh 钥匙串。`expired` / `revoked` 状态显示红色只读 chip，不让用户「设置」一个 gpg 报告的密钥状态。
  - 智能卡支持改成**opt-in**：高级区新增 toggle `gpgSmartcardEnabled`（默认关），关闭时钥匙串里不出现「智能卡分组」标题、顶部不出现「从智能卡导入公钥」按钮 —— 不用卡的用户界面跟以前一样干净。开启后才出现卡相关 UI + 「从智能卡导入公钥」按钮（跑 `gpg --card-status` ping 卡 + `--card-edit fetch` 拉公钥到 keyring）。
  - 设置面板分**普通 / 高级**两层：普通区始终展开（主开关 / 后端徽章 / 安装提示 / 钥匙串列表 / 操作按钮）；高级区是 `DisclosureGroup` 默认折叠（智能卡支持 toggle / GnuPG 实际路径 / pinentry-mac 状态 / gpg-agent 运行状态 / GNUPGHOME envvar）。普通用户基本不会展开高级；调试 / 卡用户一展就拿到所有环境信息。
  - 安装命令提示文案明确说明智能卡支持：`brew install gnupg pinentry-mac` 命令下方加一句「上述命令同时启用智能卡 / OpenPGP token 支持（gnupg 自带 scdaemon，无需额外安装）」，避免用户装完 GPG 才发现卡不识别。
  - 智能卡密钥行额外显示红字 caption：「私钥在卡上，签名 / 解密时需插入对应智能卡」+ 钥匙图标右下角加 `creditcard.fill` 角标。用户不会再以为「这把密钥能用但每次签名都失败是 SimpleZip 的 bug」。
  - 底层 / Core 改动：
    - `GPGBackend.GPGKey` 加 `trust: GPGTrustLevel` + `isSecretKeyStub: Bool` 字段；`parseColonsList` 增强解析 `pub` 行第 2 字段 trust 字符（`u/f/m/n/e/r/-`）+ 区分 `sec` vs `sec#` stub 标记。
    - 新增 `GPGBackend.setTrustLevel(fingerprint:to:) async throws` / `importFromSmartcard() async throws -> String` 两个 async 方法。
    - 新 enum `GPGTrustLevel`（unknown / never / marginal / full / ultimate / expired / revoked）—— 唯一表达信任级别，UI / 后端共享；`userAssignableCases` 暴露 picker 可选项（不含 expired / revoked）。
    - `BackendProcessRunner` 加 `ProcessInputStrategy.staticInput(String)` —— GPG `--edit-key` / `--card-edit` 这种 interactive menu 喂 stdin 后立刻关流的基础设施，复用现有 pipe / 取消机制。后续 PIN 管理 / 卡上生成密钥也走这条路。
    - `AppPreferences.gpgSmartcardEnabled` 新 key（默认 false）+ 偏好导出白名单。
  - 跟 [[feedback-gpg-release-emphasis]] 一致：错误文案点名责任方（「请检查卡是否插好 / scdaemon 是否能识别」）而不是让用户怀疑 SimpleZip。

- **新功能：运行状态诊断面板 + 复制诊断报告里加入 GPG 模块**
  - 「设置 → 运行状态」`HealthPane` 加一行 GPG 后端状态 —— 仅当用户启用了 GPG 集成（`gpgEnabled == true`）时出现，按 AGENTS A4「主开关关 = 主界面不再露 GPG 字样」例外只在设置 / 诊断面里露。
  - 单行综合状态四态：GnuPG 缺失 → 红 ✗（带「打开 GPG 设置」修复按钮）；GnuPG ok 但 pinentry-mac 缺 → 黄 ⚠（签名能用、解密 / 解锁私钥会卡，因为 gpg-agent 没 GUI 弹窗）；GnuPG + pinentry 全 ok 但 gpg-agent 没跑 → 黄 ⚠（gpg 会按需拉起，通常不致命）；全绿 ✓ → 显示钥匙串里公钥总数 + 含私钥数量。
  - 「复制诊断」按钮的报告里新增 `GPG:` 段（仅 `gpgEnabled == true` 时出现）：路径 / 版本 / pinentry-mac / gpg-agent / `$GNUPGHOME` envvar / 公钥总数 / 含私钥数量。
  - **隐私约束**：诊断报告**不**携带 fingerprint / userID / email / 公钥本体；**不**读 `~/.gnupg/` 任何文件。用户复制贴 Issue 时不会泄露密钥身份信息。SECURITY.md 计划在 #29 后续更新里把这条原则补进 .siz 节里。
  - `GPGBackend` 加两个轻量探测：`gnupgHome()` 读 `$GNUPGHOME` envvar（用户自定义私钥目录是「为什么 SimpleZip 看不到我的密钥」的高频根因）；`gpgAgentAlive() async` 跑 `gpg-connect-agent /bye` 判活。
  - 文案沿用 `feedback-gpg-release-emphasis` 风格：报错信息明确告诉用户「请检查本机 gpg / pinentry / 密钥配置」，不让用户误以为是 SimpleZip 出 bug。
  - `OperationDiagnosticsInputs` 加可选 `gpgSection: GPGDiagnosticsSection?` 字段（默认 nil 让现有单测无需改）；新结构 `GPGDiagnosticsSection` 在 Core 里，跟 Inputs 同款 public init 风格。

- **新功能：欢迎助手加入「GPG（PGP 签名）— 可选」步骤**
  - 总步数从 7 升到 8 ——「设置类」步骤计数 1/8..8/8。
  - 单独成步骤而不是塞进现有「后端可用性」一格，因为 GPG 是「特殊可选功能」语义 ——「不开 GPG 也不影响日常压缩 / 解压」，必须由用户显式做出 opt-in / opt-out 决定，混进 backend 步骤会让用户误以为「必装」。
  - 主开关 `gpgEnabled` toggle 默认关，用户勾上后才展示后端检测：GnuPG 状态徽章（绿 ✓ 已就绪 / 红 ✗ 未安装）+「未安装」时显示 `brew install gnupg pinentry-mac` 复制命令 + GPGTools 备选下载链接；装了 GnuPG 但 `pinentry-mac` 缺时给黄字警告（签名能正常做但解密 / 解锁私钥会卡 —— gpg-agent 没 GUI 弹窗）。
  - 视觉模板全部复用已有共享组件（`BackendStatusBadge(.prominent)` / `SystemInstallCommandView` / `SettingsActionRow`）—— 跟现有 backend 步骤同款，避免 wizard 自成 UI 体系违和。
  - 步骤底部固定一句声明：「SimpleZip 不保管 / 不缓存 GPG 私钥 passphrase，全交给本机 gpg-agent + pinentry-mac」，让用户碰到 GPG 问题时知道找 gpg / pinentry 配置而不是 SimpleZip。
  - 跟主开关绑同一份 `AppPreferences.gpgEnabled` UserDefaults 键，wizard 里勾上 = 同时在「设置 → GPG」里也是开的，不需要再操作两遍。

- **内部清理：6 轮冗余审计，14 项概念冗余砍掉（净 ≈ −244 行，零行为变化）**
  - 后台 agent 全仓扫一遍后做的连续 6 批清理：每批跑 SwiftPM 109 测试 + Xcode Debug build 双关绿才进入下一批。
  - 死代码：`GPGVerifyResult.iconName` 零调用方实例属性、`AppPreferences.gpgVerifyOnOpen` / `gpgSignByDefault` 两个「设置 toggle 写了但业务代码从不读」的撒谎 UI（直接拔掉 UI 而不是补业务路径，等真做时再加回来更省事）。
  - 复制粘贴 helper：`copySystemInstallCommand` 三处 12 行副本下沉到 `SystemInstallCommandView` 自己承包 NSPasteboard 写 + 开 Terminal；`runRarInstaller` 在 Settings RAR section / 欢迎助手 backend 步骤两份 70 行 verbatim 副本抽到新的 `RarInstallerService`（@MainActor enum，两个静态方法零新类型，跟现有 `RarInstallAction` / `RarInstallReview` 完美复用）；`BackendStatusBadge` 跟 `BackendAvailabilityRow` 同款样式合一（参数化 `Style.compact / .prominent`）；`defaultArchiveName` 两个 body 完全一样的 `[FileItem]` / `[URL]` 重载收成一个；`hex(_:)` digest helper 在 `HashService` 和 `ArchiveExtractionCoordinator` 各一份合一份。
  - DTO 套娃：`ArchiveOperationFailureAlert` wrapper（fullMessage + previewLimit + previewMessage 计算属性）跟 `errorMessage` getter/setter 互相把对方藏起来，砍成 `Core/ArchiveOperationFeedback.swift` 里一个 13 行纯函数 helper `ArchiveOperationFailurePreview.truncate(_:limit:)`，原单测换 API 调同一份逻辑覆盖率不变。
  - UI 组件去重：`SidebarButton` / `PinnedSidebarButton`（pin icon + 取消固定 contextMenu）/ `SidebarTagButton`（color circle）三个 row 90% 一样，抽 `SidebarRowButton<Content>` 共用 chrome（hover bg / button style / onHover 动画 / 圆角），固定 / 标签调用站直接内联 leading content 而不是各开一个 view 类型；`extractDroppedFileURLs(from:completion:)` 自由函数把 ContentView 主区域拖入 / Sidebar 固定列表拖入的两份 25 行 NSItemProvider drain 样板合一；TopBar 4 个导航按钮 chrome 复读改 `navButton(_:disabled:help:action:)` 私有 helper。
  - 单订阅 NotificationCenter：`.openSIZContainer` / `.extractSIZContainer` 两个一发一收的通知改 `ArchiveBrowserModel.pendingSIZOpen` / `pendingSIZExtract` 两个 `@Published var URL?` + ContentView `.onChange` —— 符合 AGENTS A3「不为 1-pub/1-sub 新建通知」+ A5「`.siz` 是 tar 壳不是新 infra」。
  - `LocationTextKeyCommand` enum + `handleKeyCommand(_:)` 中转改成 `control(_:textView:doCommandBy:)` 里直接 switch selector 调 parent closures，去掉无信息的中间表示。
  - 同步把痛点写进 `AGENTS.md` 12 条 A1-A12 anti-pattern 规则（重绘禁止 / DTO 套娃禁止 / 1-pub-1-sub 通知禁止 / `gpgEnabled` 关闭主界面隐藏一切 GPG / `.siz` 是 tar 壳 / 不改 pbxproj 版本号 / 用合理 /tmp / 不留半成品引用 / l10n 必加 / scope 匹配 / 指令累积 / diff 不撑爆）。下一个 agent 接手时这套规则会自动加载到上下文。

- **`.siz` 容器防篡改强化（格式 schema 升 v2，破坏式）**
  - 签名目标从「内层 archive」改为 `metadata.json`：之前签 inner archive 时攻击者可以任意改 `metadata.json` 的 signer 名 / 时间 / `innerArchiveName` 而签名仍然有效，UI 会照实展示伪造信息。现在改 metadata 任何字节 → gpg 验签直接失败。
  - 内层归档加 `innerArchiveSHA256` 锁：metadata 里新增字段记录内层 archive 的 SHA256（流式算，不一次性载入内存）；`SIZArchive.verify` 在 gpg 验过 metadata 之后还会重算 inner archive SHA 并比对，对不上就改判 `.badSignature`。这样替换 inner archive 也藏不住。
  - 内层归档本身**一字不动**——所有原生压缩 / 加密 / 任意格式特性继续可用，只是被外层 SHA + 签名兜住。
  - schema 升到 v2；如果存在 v1 `.siz` 文件，unwrap 时会显式 schema mismatch 拒绝（0.1.8 之前是开发版本，无正式发布的 v1 包）。
  - Metadata 防篡改在 GUI 不另列「metadata 签名」项；只在篡改触发时通过签名状态的红色警告体现。
- **签名信息展示：标准解压对话框 + 签名 sheet 都加公钥指纹和签名时间**
  - 之前用户从「直接解压 `.siz`」入口进来时签名信息走的是自建卡片块，跟旁边 destination / password / decryptionMethod 等行视觉割裂；现在改成标准 Form 三行：`签名` / `签名时间` / `公钥指纹`，跟其他行对齐。
  - 公钥指纹（`signerFingerprint`，40 字符）现在在解压对话框和签名 sheet 两个页面都明确展示，等价命中签名身份核对的关键信息；签名时间也都直接可见（不再藏 tooltip）。
- **关闭 GPG 集成时 `.siz` 仍可打开，但主界面完全不出现 GPG UI**
  - 强约束：`AppPreferences.gpgEnabled == false` 时主界面任何地方都不显示「签名」「公钥」「指纹」等字样；用户关掉 GPG 集成 = 完全退出 GPG 心智模型。
  - 例外：`.siz` 是注册在系统里的文件类型，用户双击就会进来——这种情况下 SimpleZip 会跳过验签，直接走标准 open / extract 路径把内层归档拿出来用，不弹签名 sheet 不显示签名行。`.siz` 文件不能因为关了 GPG 就变得无法打开。
- **Bug 修复：打开 `.siz` 后点「返回上一级」跳到 `/var/folders/.../T/SimpleZip-SIZ-Unwrap-...`**
  - 原因：`.siz` 容器打开后 `mode = .archive(innerArchiveURL)` 里的 url 是 `/tmp` 路径，archive 根目录的 goUp 分支直接 `url.deletingLastPathComponent()` 当然就掉进临时目录。
  - 修法：goUp 改用 `(archiveDisplayOverride ?? url).deletingLastPathComponent()`，普通归档走原行为；`.siz` 走原始 `.siz` 文件父目录（用户期望的桌面 / 下载 / 任何源目录）。
- **内部清理：`.siz` 验签 / 签名展示链路上的 DTO 套娃删掉大半**
  - 删 `SIZVerificationOutcome` 枚举（`GPGVerifyResult.verificationError` 已经能表达后端报错；后端没装当 verificationError 一支处理）。
  - 删 `SIZUserIntent` 枚举（open / extract 本来就是两个 handler，再用 enum 区分纯多余）。
  - 删 `SIZSignatureInfo` struct + `Status` 嵌套 enum + 50 行 `makeSignatureInfo()` mapper，统一收成一个 `SIZSignatureSummary`，状态从 `GPGVerifyResult` 派生。
  - 删 `SIZSignatureSheet.SignatureUIState` struct + 60 行 6-case mapping；图标 / 颜色 / 标题 mapping 抽成 `SIZSignatureStatus` 共用 enum，解压对话框 banner 和签名 sheet 不再各自写一份 switch。
  - 合 `handleSIZOpen` / `handleSIZExtract` / `startSIZVerification` 中重复的 unwrap + verify 块到一个 `unwrapAndVerifySIZ` helper；两个入口现在各自 10 行以内。
  - 净效果：ContentView 里 `.siz` 特有符号引用从 31 处掉到 13 处；`SIZSignatureSheet.swift` 从 208 行 → 100 行。

- **新功能：GPG 集成（A 阶段基础 + 钥匙串 + .siz 容器签名）**
  - 设置新增「GPG（PGP 签名）」pane（key.fill 图标，侧栏第 6 项）：主开关 / 后端状态徽章 / 版本 / pinentry-mac 缺失警告 / 安装提示（`brew install gnupg pinentry-mac` 双按钮 + GPGTools 下载链接）/ 钥匙串列表（有私钥的实心钥匙图标）/「导入公钥…」按钮 / 默认行为两个 toggle。
  - 主开关 `gpgEnabled` 默认 false —— 关掉时其它入口（创建对话框的「GPG 签名」复选框、未来的验签徽章等）全部隐藏，不打扰不用 GPG 的人；设置 pane 始终可见让用户能开它。
  - `Core/Backends/GPGBackend.swift`（370+ 行）：路径发现（`/opt/homebrew/bin/gpg` / `/usr/local/bin/gpg` / `MacGPG2` / `$PATH`）/ 版本 / `hasPinentryMac()` / `listKeys()`（`--with-colons` 状态机解析 pub + sec 交叉引用）/ `importKey(from:)` / `sign(archiveURL:signingKeyFingerprint:)` / `verify(archiveURL:signatureURL:)` 返回 `GPGVerifyResult`（valid trusted / valid untrusted / unknownSigner / badSignature / verificationError）。
  - **`.siz` 单文件签名容器**（独家功能）：创建压缩包时勾选 GPG 签名 → 输出自动改成 `<name>.siz`，里面是 `archive.<ext>` + `metadata.json`（SimpleZip.siz schema v2）+ `signature.asc` 三件套打 tar 包（不再额外压缩）。单文件传输签名不会脱落，比业界标准的 `.asc` 兄弟文件更结实。`Core/SIZArchive.swift` 提供 `wrap` / `unwrap` / `peekMetadata` / `verify` / `computeInnerArchiveSHA256` / `encodeMetadata` API。
  - `.siz` 现在可以直接打开：SimpleZip 会先解到受控临时目录，跑 `SIZArchive.verify`（gpg 验 metadata 签名 + 比对内层 archive SHA），再弹 SwiftUI 签名信息 sheet 让用户决定是否打开。状态区分「签名有效且受信任 / 签名有效但公钥未信任 / 签名者未知 / 签名损坏 / 验签异常」；坏签名时默认动作是取消，但仍保留显式「仍要打开」。
  - 打开 `.siz` 后，浏览器标题和路径栏显示用户原始 `.siz` 文件路径，而不是临时目录里的 `archive.<ext>`，避免用户看到 `/var/folders/...` 这类内部路径。
  - `.siz` 解包前会先列出并校验 tar 条目：拒绝路径穿越、绝对路径、符号链接、重复条目、预期外文件，以及不合法的 `metadata.innerArchiveName`；之后只解出 `metadata.json`、`signature.asc` 和 `archive.<ext>` 三项。创建 `.siz` 时如果目标已存在，也不再静默覆盖。
  - `.siz` 明确不支持内置分卷。创建对话框里只要「分卷大小」有内容，GPG `.siz` 签名复选框就会变灰并自动取消勾选，下方红字提示分卷压缩请使用外置 `.asc` 签名文件；后端也会拒绝分卷和「压缩后删除源文件」这类危险组合，防止绕过 UI。
  - gpg 私钥的 passphrase 全交给 `gpg-agent` + `pinentry-mac` 弹原生密码框 —— SimpleZip 自己不接触 passphrase（安全敏感），只需要用户的 brew gnupg 自带 pinentry-mac。
  - 偏好导出白名单加 `gpgEnabled` / `gpgSignByDefault` / `gpgVerifyOnOpen` 三项；私钥 / 公钥都在 `~/.gnupg/`，不进偏好导出文件。
  - `.siz` UTI 也注册了：`com.simplezip.siz-archive` 在 Info.plist 的 `UTExportedTypeDeclarations` 里声明（conformsTo `public.tar-archive` / `public.archive`），CFBundleDocumentTypes 加了 `siz` 扩展名 + MIME `application/x-simplezip-siz`，ArchiveAssociationService 加了对应行 —— 设置 → 文件关联里可以把 SimpleZip 设为 `.siz` 的默认打开方式。
  - **后续轮次还要做**：未知签名者公钥的一键导入流程；GUI 创建 / 导出 / 删除密钥；智能卡管理。

- **Bug 修复：Sparkle 更新检查显示自相矛盾**
  - 现象：「Check for Updates」时 Sparkle 一次显示「0.1.7 可用（您在 0.1.6）」、下一次显示「您使用的就是最新版」，两条消息互相打架。
  - 根因：Sparkle **显示**用 `CFBundleShortVersionString`（marketing version 如 `0.1.7`）但 **实际比较** 用 `CFBundleVersion`（之前 CI 设的 `GITHUB_RUN_NUMBER` 如 `47`）。`sparkle:version` 在 appcast 里是 `"0.1.7"`，解析成 `[0,1,7]` vs `[47]` → Sparkle 永远觉得本地 `47` 比 `0.1.7` 新 → 比较结果与显示文案脱钩。
  - 修法：`scripts/build_unsigned_dmg.sh` 发布 build 时把 `CURRENT_PROJECT_VERSION` 也设成 `RELEASE_VERSION`（之前是 `BUILD_NUMBER`），让 `CFBundleVersion` 跟 `sparkle:version` 都用 semver `0.1.7` 走同一比较路径。下次 v0.1.8 发版后旧用户能正确收到「有更新」提示。

## 0.1.7

- **内部重构：`ArchiveBackend` 协议落地（Phase 4 step 6，**Phase 4 完成**）**
  - 新增 `Core/Backends/ArchiveBackend.swift`（55 行）：声明协议 + 给 4 个 backend 各自 conform。
  - 协议范围：仅覆盖**读路径**（`list` / `test`）—— 这两个方法在所有 backend 上签名能完美一致，统一后让 `ArchiveService.list` / `.test` 收成两行 router（`backendType(for:).list(...)` / `.test(...)`），不再 switch case。
  - 写路径（`extract` / `create`）**不入协议**：各 backend 参数太异质（NativeZip 需要 `zipDecryptionMethod`、SevenZip 需要 `pathMode`、DMG 啥都不要；7zz 还有 3 种创建变种 / NativeZip 3 种 / RAR 1 种），强行塞进「kitchen sink options」反而比 case 难维护。这是当前最划算的协议边界。
  - 三个适配器 extension：`NativeZipBackend` / `DiskImageBackend` 加 wrapper 把协议要求的 `password` / `operationID` 参数吞掉（DMG / 原生 unzip 不用密码 / 没有取消语义）；`SevenZipBackend` 已经天然匹配，空 extension 即可宣告 conformance。
  - 经过 Phase 4 完整 6 步，`ArchiveService.swift` 由原始 **1524 → 598**（**−926，−60.7%**），四个 backend 总计 1085 行各司其职（DMG 208 / NativeZip 310 / RAR 218 / 7zz 349 / 协议 55）。
  - **Phase 4 完成 ✓**

- **新功能：Finder 自动解压改为独立小浮窗**
  - 之前用户开了「Finder 双击自动解压」开关后，整个主窗口会被拉起来跑解压任务，违反「双击 = 后台静默解压」的预期。
  - 新增独立 `ExternalExtractWindowController` + `ExternalExtractSession`：自己持有 `ArchiveExtractionCoordinator`，跑自己的 `ArchiveService.extract`，progress 更新只刷新本浮窗 UI。主窗口完全不参与。
  - 浮窗 ~360×190，`.utilityWindow` 风格 + `.floating` level，固定尺寸不可缩放，不抢主窗口焦点；标题栏只留关闭按钮。
  - 进度 + 当前文件名 + 取消按钮三件套；成功 1.2 秒后自动关 + `NSWorkspace.activateFileViewerSelecting` 选中解压目录；失败时停留显示错误，方便用户复制详情。
  - ContentView.openExternalURL 检测 `finderOpenAutoExtract` 开 + 非 DMG 时走新浮窗 + 主动 orderOut 主窗口（兼顾冷启动 / 热启动两种场景）。
  - DMG 仍走 model 挂载浏览（没有「解压」语义，保持原行为）。

- **Bug 修复：文件关联设置生效后 UI 不刷新**
  - 用户在「设置 → 文件关联」点「设为默认」后，行内绿色 ✓ 不会立刻出现，需要切走 pane 再切回来才显示。
  - 根因：`LSSetDefaultRoleHandlerForContentType` 同步成功，但同进程内 `LSCopyDefaultRoleHandlerForContentType` 短时间会读到旧缓存。
  - 修法：写入成功后立即刷一次，并在 300ms / 800ms / 1.5s 三个时间点 retry refresh，让 LaunchServices settle 后 UI 自动跟上 —— 用户不需要手动切 pane。

- **内部重构：RarBackend 抽出 + 7-Zip 创建路径搬迁（Phase 4 step 5）**
  - 新增 `Core/Backends/RarBackend.swift`（218 行）：把 RAR 的所有逻辑（路径发现：local / system 候选；元信息：`backendDescription` / `version`；本地安装管理：`localBackendURL` / `hasLocalBackend` / `deleteLocalBackend`；安装资源：`installReadmeURL` / `installLicenseURL` / `installerScriptURL` / `installResourcesURL`；动作：`create` 创建 .rar；类型：`ResolvedRarTool` / `RarToolSource`）整段搬过去。
  - `ArchiveService` 公开的 RAR facade（`canCreateRAR` / `rarBackendDescription` / `rarVersion` / 全套安装资源 URL / `hasLocalRarBackend` / `deleteLocalRarBackend`）全部改为一行 forward 到 `RarBackend`，不破坏 Settings RAR pane / 欢迎助手后端步骤 / 健康检查的现有调用。
  - 顺手把 7-Zip 的 5 个创建场景（`.zip` 7zz 优先路径 / `.sevenZip` / `.gzip` / `.bzip2` / `.xz`）也搬进 `SevenZipBackend`，新增 `createZip` / `createSevenZip` / `createSingleFileCompressed` 三个方法；`ArchiveService.createArchive` 里 case 分支统统改为一行 `try await SevenZipBackend.xxx(...)`。
  - 旧 `ArchiveService` 内的 4 个私有 helper（`sevenZipTool` / `resolvedSevenZipTool` / `run` / `runAndCapture`）现在已经无人使用，整段删除。
  - 经过 step 1 + step 2 + step 3a + step 3b + step 4 + step 5，`ArchiveService.swift` 由 1524 行缩到 **601 行**（累计 −923，**−60.6%**）。Step 6 引入 `ArchiveBackend` 协议把剩下的 ArchiveService 收成纯路由 + 安全策略 + 共享路径 helper。

## 0.1.6

- **新功能：欢迎助手 wizard（首次启动 + 菜单触发）**
  - 11 步引导：备份恢复 → 版本检查 → 简介 → 语言 → 启动位置（含「自定义文件夹…」NSOpenPanel） → 默认覆盖行为 → 预设密码（带 SecureField + 保存到 Keychain） → Finder 自动解压 → 安全策略当前值展示 → 后端可用性 → 完成。
  - 「设置类」7 步在顶部进度条标 `第 N 步 / 共 7 步`；备份 / 版本 / 简介 / 完成 不计入。
  - 触发：`AppPreferences.welcomeAssistantCompleted` bool 控制是否首次启动自动弹；走完最后一步置 true。SimpleZip 菜单加「重新运行欢迎助手」入口，可随时再开（不重置 completed）。
  - **第一步：备份恢复** —— 用户之前在「偏好设置 → 备份与还原」导出过的 JSON 可以直接挑文件导入，跳过手动设置；走 `AppPreferences.importPayload` 同款 schema 校验，失败显示具体错误。
  - **第二步：版本检查** —— 显示当前安装版本号 + 「现在检查」按钮，直接弹 Sparkle 标准 UI。
  - **后端步骤自带安装流程** —— 不再「跳偏好设置」逃避：7-Zip 在「系统级 + 缺失」情况下直接给 `brew install sevenzip` 命令（带 Copy / Open Terminal 双按钮，用 AppleScript 自动拉起 Terminal 跑命令）；RAR 在「自动 / 内置 + 缺失」时给「安装本地 RAR」按钮，弹出 `RarInstallReviewSheet`（与 Settings 同源），用户必须勾选「我已阅读 LICENSE / README」才能启动安装脚本；已装本地版可以 update / delete。
  - **取消支持** —— 底部「取消」按钮总是可点，弹二次确认 alert（保留已做选项 + 提示可随时重新打开），避免误关丢失工作。

- **新功能：Sparkle 自动更新 (无签名 / 无公证版)**
  - 通过 SPM 引入 [Sparkle 2.9.2](https://github.com/sparkle-project/Sparkle)。Info.plist 加 `SUFeedURL`（指向 `https://raw.githubusercontent.com/chiba233/SimpleZip/main/docs/appcast.xml`）/ `SUEnableAutomaticChecks` / `SUEnableInstallerLauncherService=NO` / `SUScheduledCheckInterval=86400`。
  - 帮助菜单加「检查更新…」入口（Sparkle 推荐位置）；欢迎助手第 2 步也提供入口。
  - `SparkleUpdater` 单例封装 `SPUStandardUpdaterController`，App init 时就触发 Sparkle 的周期性后台检查。
  - **决策**：本期间不公证 / 不签名 DMG（没有 Apple Developer ID）、不做 EdDSA 包完整性签名。Sparkle 仍能拉 appcast、提示新版、下载替换；Gatekeeper 会要求用户「右键 → 打开」绕过。社区有人愿意贡献签名身份再补。
  - **release.yml** 在「Publish a GitHub release」勾选 / tag 推送的发布路径里加两个新步骤：(1) 生成 `docs/appcast.xml`，包含 version / pubDate / 下载 URL / DMG size，DMG 下载链直指 GitHub Release 资产；(2) checkout main → commit → push，让 `raw.githubusercontent.com/.../main/docs/appcast.xml` 自动同步。手动触发不勾 publish 时不会动 main。

- **新功能：「个人收藏」镜像 Finder 侧栏**
  - 主窗口左侧「个人收藏」分组不再硬编码 5 项（个人 / 下载 / 桌面 / 文稿 / 应用），改为读取 macOS Finder 的「个人收藏」侧栏并镜像显示。
  - 数据源：`~/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.FavoriteItems.sfl4`（macOS 11+，sfl3 旧版本作为回落），用 `NSKeyedUnarchiver` 解出条目 → 提取每条 `Bookmark` Data → `URL(resolvingBookmarkData:)` 解出真实路径。
  - 显示名优先取 `.localizedNameKey`（跟随 macOS 系统语言：「下载」/「Downloads」），图标按已知系统目录映射 SF Symbol（家 / 下载 / 桌面 / 文稿 / 影片 / 音乐 / 图片 / 应用 / iCloud Drive），未知目录用通用 folder。
  - AirDrop / 最近使用 / 标签 这些 Finder 虚拟项的 bookmark 解不出真实目录，自动滤掉；同一物理路径去重。
  - **同步触发**：主窗口聚焦时（`NSApplication.didBecomeActiveNotification`）重读一次。在 Finder 里改了收藏切回 SimpleZip 就能看到。Apple 没提供 sfl4 的官方变化通知，这是「保证用户能感知到变化」的最近合理时机。
  - **只读**：永远不写回 sfl4，避免改坏 Finder 收藏。在 SimpleZip 里改顺序 / 加项的能力不在这一版。
  - **回落保护**：sfl4 不存在、解析失败、用户从未自定义过 Finder 收藏 → 退回到原来的 5 项硬编码，侧栏不会变空。
  - **持久化缓存**：每次成功读到的路径列表写一份到 UserDefaults。下次启动时若 sfl4 因为 TCC / 文件被锁 / 临时 I/O 暂时失败，仍然显示上次成功的列表，避免 UI 在 Finder 收藏和硬编码 5 项之间反复横跳；缓存路径会再过一次「目录是否存在」过滤，外接盘没挂载就不会显示死链接。
  - **架构选择**：`finderFavorites` 放在 `ArchiveBrowserModel` 作为 `@Published`，不放在 Sidebar 的 `@State`。前者通过 ObservableObject publisher 传给 `@ObservedObject`，更新可靠；后者在 NavigationSplitView 的 sidebar 列里有路径会让 @State 重置（实测主线程赋值后下一帧 getter 仍读初始值）。
  - **数据源选型**：单一 ForEach + 统一 `FavoriteRow` 类型喂数据，避开 SwiftUI 在 Section 里 `if/else` + 异构子视图分支切换偶发不刷新的 issue。

- **新功能：创建 DMG 压缩包**
  - 「创建压缩包」面板新增 **DMG** 作为更贴近 macOS 的输出格式。DMG 创建使用系统自带的 `hdiutil create -format UDZO`，不依赖 7-Zip 或 RARLAB 后端。
  - 多选时保持和其它归档格式一致的顶层语义：SimpleZip 会先把选中的文件 / 文件夹放进临时 staging 目录，再从 staging 目录创建 DMG，因此 DMG 里看到的是用户选中的项目本身。
- **DMG 浏览修复**
  - 修复从另一个压缩包内部打开 `.dmg` 会失败的问题：临时解出的 DMG 现在走 SimpleZip 自己的只读挂载 + 文件夹浏览流程，不再交给 `NSWorkspace` 默认打开，避免脱离压缩包工作流或被系统打开失败。
  - 新增 SwiftPM 回归测试：创建 DMG 后再通过现有 DMG backend 列表验证内容。
- **Bug 修复**
  - **侧边栏固定文件夹现在能更清晰地管理。** 把真实存在的文件夹拖到「固定路径」区域会加入固定列表，重复项会自动去重并移到顶部，侧边栏立即刷新。「个人收藏」是内置位置，不再呈现可拖放效果，避免误导。固定项现在拥有自己的整行右键菜单，右键固定文件夹可以稳定显示「取消固定」。
  - **修复 P1：header-encrypted 压缩包在「解压前安全检查」处直接失败** —— `confirmArchiveExtractionSafety(archiveURL:)` 用空密码调 `ArchiveService.list`，header-encrypted 7z 没密码连枚举条目都做不到，旧逻辑因为这一步把整个 extract 流程标成失败，用户根本进不到「输入密码」的 retry 循环。现在安全检查带上密码 / force 参数，移到 retry 循环内（`didCheckSafety` 标志保证只在 list 第一次成功后跑一次），首次 list 失败会被外层 catch 识别为密码错误，触发密码 prompt → 下一轮重试。配合预设密码 + Finder 自动解压：header-encrypted 7z 也能整条链路走通。
  - **修复 P2：偏好「导入」语义是 patch 不是「还原备份」** —— 旧实现只覆盖 payload 里出现的 key，导入前已有的偏好（payload 里没带的项）会原样保留，导致用户「换了一个更简化的备份」之后还残留上次的零散设置。现在导入前先把所有白名单 key 抹掉（`defaults.removeObject(forKey:)`），让没出现在 payload 里的项目回落到代码默认值，再写 payload 里有的 key —— 真正的「还原备份」语义，payload 是完整状态而不是补丁。
  - **修复 P2：Keychain 写失败被进程内缓存伪装成「保存成功」** —— `PresetPasswordStore.save` 无视 `SecItemUpdate / SecItemAdd` 的 OSStatus 直接更新缓存，写失败的情况（access 拒绝、磁盘满、ad-hoc 签名换了）会让 UI 显示「已加密保存到钥匙串」但下次启动 `load()` 读到空字符串，密码神秘消失。`writeKeychain` 现在返回真实 OSStatus，`save()` 仅在 `errSecSuccess` 时更新缓存并返回 OSStatus；`AppPreferences.setPresetPassword` 包装为 `Bool` 给 UI，`GeneralPane.savePresetPassword` 根据返回值显示 `settings.presetPassword.saved` 或新增的 `settings.presetPassword.saveFailed`（zh-Hans + en 都补了）。
  - **修复：主窗口空白处右键菜单出现不该有的选项** —— 旧逻辑 `menuNeedsUpdate` 不论点哪都堆 15 项（打开 / 以压缩包打开 / 解压到这里 / 测试 / 哈希 / 复制 / 剪切 / 粘贴 / 移动 / 删除 / Finder 显示），但 `selectClickedRowIfNeeded` 在空白处不会选中任何行 —— 用户右键空白处看到「测试 / 哈希」很懵。现在用 `tableView.clickedRow >= 0` 判断：点在文件行上 → 原全套菜单；点空白处 → 只剩「粘贴 + 在 Finder 中显示当前文件夹」两项，跟 macOS Finder 习惯一致。
  - **修复 0.1.6 开发期：切语言后顶部菜单栏不跟随系统语言** —— `AppleLanguages` 是 SwiftUI App 的 `.commands {}` 段被构造**之前**被 AppKit 读的，旧逻辑只在用户改设置时写一次，下次启动时 AppKit 已经按系统语言把 File / Edit / Window / Help / Hide / Quit 这一行 native 菜单文字定下来了。现在在 `SimpleZipApp.init()` 里早于 body 求值，把当前 `appLanguage` 偏好同步写到 `AppleLanguages`，重启后菜单栏完整跟随。
- **关于面板**
  - 描述改写为反映 0.1.6 的真实能力。作者署名 "Hoshino Yumeka"。
  - 走系统标准 `orderFrontStandardAboutPanel`（跟随系统主题 / 字号 / 间距，不自己手画），credits 刻意保持「描述 + 作者」两行短文案 —— 内容超出会触发滚动条 + 边框，反而难看。
  - 仓库地址和 MIT 许可证移到「帮助」菜单当原生菜单项（`SimpleZip 项目主页` / `MIT 许可证`），既符合 macOS 习惯，又不需要把链接塞 credits 文本里。
- **内部重构：NativeZipBackend 抽出（Phase 4 step 4）**
  - 新增 `Core/Backends/NativeZipBackend.swift`（310 行），把所有「系统自带 zip 家族」操作搬过去：
    - `list` —— `unzip -l` + `tar -tf` 双输出合并解析
    - `test` —— `unzip -t`
    - `extract` —— ZIP 文件的统一入口；内部根据「解压方式」偏好和头部加密检测，按 `[macOS, sevenZip]` 顺序依次尝试，前一个失败下一个接着上
    - `createTar` / `createTarGzip` —— `tar -cvf` / `tar -czvf`
    - `createZipFallback` —— `/usr/bin/zip` 兜底（仅在 7zz 不可用时）
  - `ArchiveService` 里 `.zipNative` / `.tar` / `.tarGzip` 分支全部改为一行 `try await NativeZipBackend.xxx(...)`；`.zip` 创建的「7zz 缺失 → 原生 zip 兜底」路径也走 backend。
  - 旧的私有 helper `extractZipArchive` / `extractZipArchiveWithSevenZip` / `extractZipArchiveWithMacOS` / `zipExtractionTools` / `zipExtractionToolName` + `ZipExtractionTool` 私有 enum 整段从 ArchiveService 删除。
  - 经过 step 1 + step 2 + step 3a + step 3b + step 4，`ArchiveService.swift` 由 1524 行缩到 780 行（累计 **−744，−49%**）。下一步 step 5 拆 `RarBackend`、step 6 提取 `ArchiveBackend` 协议把 `ArchiveService` 收成纯路由。

- **内部重构：SevenZipBackend 完成动作层（Phase 4 step 3b）**
  - 把 7-Zip 后端的 4 个操作 —— `list` / `extract`（整包 + 选择性 + flatten 模式） / `test` / `benchmark` —— 全部从 `ArchiveService` 搬到 `Core/Backends/SevenZipBackend.swift`。
  - `ArchiveService` 里 `.sevenZip` 分支统统改为 `try await SevenZipBackend.xxx(...)` 一行转发；`ArchiveService.benchmark` 也整段委托。
  - 顺带把私有 helper `extractZipArchiveWithSevenZip`（zip 文件需要走 7zz 解的场景，例如 AES-256 加密的 zip）也改为转发，让所有「跑 7zz 解」的入口共用 SevenZipBackend 一条实现。
  - 共享 `OutputAccumulator`（benchmark 实时刷分用的累积 String 缓冲）从 ArchiveService 抽出，搬进 SevenZipBackend 作为私有类型；ArchiveService 不再持有任何 7zz 操作相关的私有状态。
  - 经过 step 1 + step 2 + step 3a + step 3b，`ArchiveService.swift` 由 1524 行缩到 973 行（累计 −551，**−36%**）。下一步 step 4 拆 `NativeZipBackend`（zip + unzip + tar）、step 5 拆 `RarBackend`、step 6 提取 `ArchiveBackend` 协议把 `ArchiveService` 变成纯路由。

- **内部重构：SevenZipBackend 抽出（Phase 4 step 3a）**
  - 把 7-Zip 后端的「设备发现 + 元信息查询」层（bundled / system 候选路径、`resolve()` / `toolPath()` / `isAvailable()` / `backendDescription()` / `version()` + `ResolvedSevenZipTool` 结构体 + `SevenZipToolSource` 枚举）整段搬到 `Core/Backends/SevenZipBackend.swift`（136 行）。`ArchiveService` 的 `canUseSevenZip` / `sevenZipBackendDescription` / `sevenZipVersion` 改为转发；私有 `sevenZipTool` / `resolvedSevenZipTool` 也改为转发（thin wrapper，等 step 3b 把 list/extract/test 也搬过来后可以一起删）。
  - 顺手把用户偏好枚举重命名为更准确的名字：`SevenZipBackend` → **`SevenZipBackendChoice`**、`RarBackend` → **`RarBackendChoice`**（它们是"选择"不是"后端"）。释放出 `SevenZipBackend` / `RarBackend` 这两个名字给真正的 backend 实现命名空间。
  - 共享 path-discovery helper（`applicationSupportDirectory` / `uniqueExistingCandidatePaths` / `envPath` / `cellarCandidates`）从 `private` 放宽到 `internal`，让新 backend 文件能直接调，避免循环依赖。
  - 经过 step 1 + step 2 + step 3a，`ArchiveService.swift` 由 1524 行缩到 1007 行（累计 −517，**−34%**）。下一步 step 3b 把 7-Zip 后端的 list / extract / test / benchmark 实现也搬过来。
- **内部重构：BackendProcessRunner 抽出（Phase 4 step 1）**
  - 把 `ArchiveService` 里 ~400 行进程基础设施（`runAndCapture` / PTY / 取消注册表 / `ProgressOutputParser` / `InteractivePasswordResponder`）整段搬到独立的 `BackendProcessRunner`，`ArchiveService.cancelRunningCommand` 改为转发调用。
- **内部重构：DiskImageBackend 抽出（Phase 4 step 2）**
  - 把 `.dmg` 相关的 mount / detach / list / extract / test 五个动作 + 私有 `copyDiskImageContents` / `diskImageArchiveItems` / `DiskImageDateFormatter` 全部搬到 `Core/Backends/DiskImageBackend.swift`（156 行）。`ArchiveService` 的 list / extract / test 在 `case .diskImage` 分支只剩一行 `try await DiskImageBackend.xxx`；公开的 `mountDiskImage` / `detachDiskImage` 保留为转发壳，让 `ArchiveBrowserModel`「打开 DMG 为文件夹」流程不受影响。
  - 经过 step 1 + step 2，`ArchiveService.swift` 由 1524 行缩到 1071 行（累计 −453，−30%）。接下来 step 3 拆 `SevenZipBackend`（最大）、step 4 拆 `NativeZipBackend`（zip + unzip + tar）、step 5 拆 `RarBackend`、step 6 提取 `ArchiveBackend` 协议把 `ArchiveService` 变成纯路由。
- **新功能：以压缩包打开任意文件**
  - FileTable 右键菜单 + File 主菜单新增「以压缩包打开」命令：选中单个非压缩包文件（.exe / .apk / .ipa / .jar 等本质上是 ZIP / NSIS / CAB 的非典型档案）后，跳过扩展名校验直接送给 7-Zip 后端探测内容并展开。
  - 命令只在「选中单个非目录文件 + 不是已识别的压缩包」时启用，避免和普通「打开」语义重复。
  - 实现：ArchiveService 加 `force` 参数跳过扩展名 → backend 路由，ArchiveBrowserModel 维护 `forcedArchiveURLs` 集合追踪哪些 URL 是用「以压缩包打开」入口进来的，后续 list / extract / test 都自动带上 force。这条会话状态在 app 关掉后丢，下次重新右键即可。
- **新功能：偏好备份与还原**
  - 设置新增「备份与还原」pane（侧栏第 7 项，⇅ 图标）：
    - **导出偏好** → 选个文件夹保存成 JSON（默认文件名 `SimpleZip-Preferences-YYYY-MM-DD.json`，prettyPrinted + sortedKeys 方便 diff 和手动微调）
    - **导入偏好** → 选文件 → 二次确认（"现有偏好会被覆盖，不可撤销"）→ 写回
    - **全部恢复默认** → 红色 destructive 按钮 + 二次确认 → 清掉所有 UserDefaults 偏好 + 顺手把 Keychain 里的预设密码也清掉
  - **白名单导出**：故意手动登记可导出 key（30+ 项），私有路径（lastFolder / pinned / recent sidebar）和敏感字段（旧版本残留 plaintext `presetPassword`）永远不进导出文件。导入时只接受白名单 key，防止恶意 JSON 偷偷写 `AppleLanguages` 这种全局系统 key。
  - **schema 校验**：JSON 文件必须带 `schema: "SimpleZip.preferences"` + `version: 1`；导入别的 app 的 plist / 未来 v2 文件、缺字段、版本号不对，会显示具体错误而不是悄悄写错。配套 7 个单元测试钉死这套契约。
- **新功能：运行状态面板**
  - 设置新增「运行状态」pane（侧栏第 6 项，❤️ 图标）：把 7-Zip 后端 / RAR 后端 / 文件关联 / 预设密码 4 项关键组件的当前状态一字排开 —— 绿色 ✓ 正常、黄色 ⚠ 警告、红色 ✗ 故障、灰色 ⓘ 信息。
  - 每一行右侧若有问题就有「修复」按钮：RAR 没装 → 跳「压缩包」pane 装本地版；文件关联部分掌控 → 跳「文件关联」pane；预设密码启用但没填 → 跳「通用」pane。
  - 顶部有「重新检查」按钮和「上次检查于…」相对时间提示；首次打开 pane 自动跑一遍。
- **新功能：一键诊断**
  - 长任务详情面板和操作失败弹窗新增「复制诊断信息」按钮。点击会把 app 版本、macOS 版本、bundled `7zz` / RAR 后端路径 + 版本、操作标题、起止时间、错误摘要、命令输出尾段（自动截 4000 字符 + 中文友好）一次性拼成一份可贴进 GitHub Issue 的纯文本，写进系统剪贴板。详情面板里点完会显示 2.5 秒的「已复制」提示。
  - 报告内容会**脱敏**所有 `-p<密码>` / `-hp<密码>` 形式的命令行密码片段（替换为 `-p[REDACTED]` / `-hp[REDACTED]`），防止用户不假思索贴到公开 issue 把真实密码露出去。配套 11 个单元测试（脱敏规则 + 报告结构 + 时长格式）钉死这个契约。
- **新功能：启动位置扩展**
  - 「通用 → 启动位置」自动加入更多 macOS 常用目录：文稿 / 影片 / 音乐 / 图片。之前只有 个人文件夹 / 下载 / 桌面 / 上次打开的文件夹 四项。
  - 选了「添加自定义位置…」会立即弹文件夹选择面板，选完后启动位置那行直接显示文件夹名（不是固定的「自定义位置」文案）。
  - **自定义位置有记忆功能**：每次挑过的路径都按 MRU 顺序记在 Menu 里，再打开 Menu 时这些「最近的自定义位置」就在系统目录下方作为快速切换选项。Menu 总项数硬性 ≤ 10，超过时自动从最早的自定义路径开始驱逐，系统目录不动。
  - 选择目录时会校验文件夹存在；不存在 = 红字提示「该文件夹现在不可用」+ 自动从 MRU 历史里清除这条死路径，不会改动当前选择。
  - App 启动时如果保存的启动位置已失效（外部删 / 移走），弹一个 alert 让用户选「打开设置…」（直接打开 Settings 重新选）或「重置为个人文件夹」（清掉所有 custom 历史 + 回到 home）。
- **Bug 修复**
  - 修复 Cmd+E 菜单项「在压缩包内有选中条目时被静默切成『解压选中』」的问题：菜单文案明明是 "Extract"（整包），按下却得到部分解压对话框，非常违和。现在 Cmd+E 永远是整包解压，Cmd+Shift+E 才是「解压选中条目」，二者职责清晰。
- **安全 / 文档**
  - 新增 `SECURITY.md`：列出威胁模型（in/out of scope）、漏洞上报渠道（GitHub Security Advisories）、用户可控的安全策略、预设密码的存储 / 内存 / 屏幕三态安全模型、bundled 后端来源 + License。
  - 新增 `docs/release-checklist.md`：发版前要勾的项（CI 状态、安全敏感面回归、本地化补齐、版本号 / CHANGELOG 同步、tag 推送验证、DMG smoke test）。`release.yml` 的 tag 推送会按这套清单走最后一关。
  - README「Documentation」段加入 SECURITY 和 release-checklist 链接。
- **新功能：Finder 自动解压 + 预设密码**
  - 「通用」设置新增「从 Finder 打开时自动解压」开关：开启后，通过 Finder 双击 / Services / 其它 App 把压缩包丢给 SimpleZip，会直接解压到压缩包所在目录，不再打开主窗口浏览。DMG 等需要挂载的格式仍走原浏览路径。安全策略（路径穿越 / 符号链接 / 活动内容）依旧生效。
  - 「通用」设置新增「使用预设密码」：填入并保存后，创建加密压缩包时自动填入；打开 / 解压有密码的压缩包时优先用预设静默尝试，失败再弹密码框。Finder 自动解压 + 预设密码二者同时开启时，整个流程不需要用户再确认密码。
  - 创建压缩包和解压对话框新增「使用预设密码」复选框：仅当通用设置里启用了预设密码时才显示，默认勾选，取消勾选可输入临时密码。
- **预设密码的安全存储**
  - 密码以 Keychain（`kSecAttrAccessibleAfterFirstUnlock`）保存，仅 SimpleZip 自身可读写，不再放进 UserDefaults 的明文 plist。
  - 设置页输入栏改为本地缓冲区 + 显式「保存」按钮：未点保存就关窗口的修改会丢弃。关掉总开关时同步清空 Keychain 中的密码。
  - 点眼睛显示明文必须先通过本机认证（Touch ID 或 Mac 登录口令）；旁人偷瞄屏幕时不会因为不小心点一下就看到密码。业务侧的自动填充 / 自动尝试走静默读取，不弹认证提示。

- **压缩包列表（Bug 修复）**
  - 修复一个 7-Zip 列表解析 bug：`7zz l -slt` 输出的 archive 头块（含 `Path = <绝对路径>` `Type = 7z` `Method = LZMA2:12` `Solid = +` 等字段）之前会被解析器误当成一个普通条目，把 archive 自己的绝对路径作为「entry」混进结果，进而触发 ArchiveSafety 的「绝对路径不安全」提示。现在头块用 `Type` / `Physical Size` / `Headers Size` 三个仅在头块出现的字段识别并跳过。
  - 修复带密码列出压缩包时返回空列表的 bug：list 走密码路径时用 PTY，macOS 默认的 ONLCR 把 `\n` 转 `\r\n`，原解析器没有归一化行尾，导致空白分隔行不再触发条目 flush，多条目互相覆盖。新增 CRLF 归一化。
  - 上述两个 bug 都由新增的预录 fixture 测试在第一次运行时立刻捕获，作为下面 fixture 库价值的最佳示范。
- **设置**
  - 设置窗口由固定的 820×560 改成可拖拽自适应（最小 720×520，理想 820×560，无上限），下拉项宽度也改为根据当前翻译自适应，避免长语言被截断。
  - 修复「自定义列」面板第三行错把同一个「归档大小」开关绑定了两次的 bug：那一行现在保持空白，归档列计数与实际可选列对齐。
  - 删除一个未被引用的内部「设为默认应用」入口，避免日后误调。
- **内部重构**
  - `SettingsView.swift` 由单文件 1448 行拆分为 `Features/Settings/` 下 14 个职责明确的文件（GeneralPane / ArchivePane / BrowserPane / ColumnsPane / FileAssociationsPane / SevenZipBackendSection / RarBackendSection / RarInstallSheet 等），并附中文「为什么这么写」注释，便于后续维护。
  - `ArchiveBrowserModel.swift` 由 2089 行精简到 1744 行（-345），按 `docs/ARCHITECTURE.md` 拆出 3 个独立单元：`ArchiveSession`（压缩包内容 + 当前路径 + 合成目录 / 路径展开）、`FileBrowserService`（列目录、Finder 标签搜索、`FileItem` 构造、地址栏补全）、`ArchiveOperationRunner`（「一次一个」长任务的取消、ID 跟踪、子进程联动）。
  - 将 `NavigationLocation`、`MountedDiskImageSession` 移到独立的 `BrowserNavigation.swift`。
- **CI / 发布管道**
  - 拆分 GitHub Actions：原 `build-dmg.yml` 在每次 PR / push 都会跑 DMG 打包，浪费 macOS runner 配额。现在拆成 `pr.yml`（每次 PR / push 跑测试 + Xcode Debug 构建，带 SwiftPM scratch 和 derived data 缓存，PR 后续推送会取消旧 run 节省配额）和 `release.yml`（仅 push tag `v*` 或手动触发时打 DMG / 发布 release）。
  - `release.yml` 新增按 tag 名解析版本号的支持：推 `v0.1.6` 即触发自动发布。
- **测试**
  - `ArchiveService` 单元测试由 27 个扩展到 84 个，新增 `ArchiveServiceArgumentsTests`（覆盖路由 gate、参数构造分支、命令映射、原生 zip 回退条件）和 `ArchiveServiceParsingTests`（覆盖输出解析边角、合成目录展开、ZIP 加密探测、CRLF 行尾归一化）。
  - 新增 `Tests/SimpleZipCoreTests/Fixtures/` 预录回归 fixture 库（plain / AES-256 / 路径穿越的 zip + 7z + tar，含中文文件名、嵌套目录、空目录），由 `generate.sh` 用 macOS 自带 `zip`/`tar`、bundled `7zz`、Python `zipfile` 生成（脚本可重跑）。配套 `ArchiveServiceFixtureTests` 覆盖「读」路径，避免「自己写自己读」式的自证测试 —— 上述两个 7-Zip 解析 bug 就是这套测试在第一次运行时找到的。

## 0.1.5

- **文件关联**
  - 修复 RAR 无法设为默认打开 App 的问题：现在只使用稳定的 `com.rarlab.rar-archive` 类型，不再同时尝试 macOS 生成的动态 `.rar` UTI，并在 App 包中声明 RAR 压缩包类型。
- **设置**
  - 在“列表列”设置页新增实时预览，用户可以直接看到文件浏览和压缩包浏览列表会变成什么样。
  - 设置页改为左侧导航布局，并把后端安装相关操作拆成带说明的独立行，不再把按钮挤成一团。
  - 将同名覆盖默认策略移到“通用”，新增“移到废纸篓前二次确认”开关，并把隐藏后缀的展开按钮放回设置行左侧。
  - 为设置页主要控件补充效果说明，并更清楚地区分相关选项分组，让用户在切换前能知道每个选项会改变什么。
- **文件操作**
  - 新增全局“内容不同才替换”覆盖偏好，并应用到解压合并、粘贴、拖放和“移动到文件夹”。
  - 扩大同名冲突检查范围：普通文件比较 SHA256，符号链接比较链接目标，文件夹比较递归内容指纹，再决定是否替换。
  - 同名冲突弹窗新增“应用到本次操作剩余冲突”选项，大量解压、粘贴、拖放或移动时不再需要反复回答同一个问题。
  - 批量“内容不同才替换”完成后新增哈希冲突汇总表，列出哪些项目内容一致已跳过、哪些项目内容不同已替换。
  - 将哈希冲突汇总从容易裁切的 Alert 表格改成可调整大小的 SwiftUI 面板，长文件名和哈希会更稳定地截断显示，并使用懒加载滚动列表减少卡顿。
  - 修复批量哈希冲突处理会同时弹出单文件结果和批量汇总的问题；现在单文件结果和批量汇总只会出现一个。
  - 哈希冲突汇总现在会隐藏空分组，全部跳过或全部替换时不再留下误导性的空白区域。
  - 移除哈希冲突汇总里的 sticky section 布局，避免“已跳过”列表前出现异常空白。
  - 哈希冲突汇总现在拆分为“原文件哈希”和“试图覆盖文件哈希”两列，不再把两个值塞进同一个比较结果字段。
  - 移除同名冲突弹窗里价值很低的“保留两者”，让用户只需要在覆盖、跳过、内容不同才覆盖之间选择。
- **文案**
  - 优化删除确认提示，不再出现“不会直接 rm 删除”这类无意义表述，改为说明文件会进入废纸篓且清空前可恢复。
- **设置**
  - 优化“浏览器”里的隐藏后缀 UI：折叠行改为普通设置行高度，展开按钮、移除按钮和添加按钮与设置页其它控件对齐。
- **加密压缩包**
  - 修复带密码压缩包解压时用户留空可选密码字段后会直接失败的问题：现在会弹出密码输入框并重试解压。

## 0.1.4

- **Finder 集成**
  - 新增 Finder Sync 扩展：可在 Finder 右键里直接对选中的文件或文件夹计算哈希，或用 SimpleZip 添加到新压缩包。
  - 保留 Finder Services 作为备用入口，并新增 `simplezip://` 回调路径，让 Finder 操作可以拉起 App 并复用现有的哈希和创建压缩包流程。
- **压缩包浏览**
  - 修复 `.001` / `.002` 这类数字分卷打开后，会把 7-Zip 的 split 容器记录显示成一个不存在的合并 ZIP 项目的问题。
  - 修复浏览器“隐藏后缀”总开关：关闭后不再把总开关本身禁用，避免设置被一次性锁死。

## 0.1.3

- **RAR 后端**
  - 重做了可选 RAR 创建后端流程，公开构建不再暗示 SimpleZip 会内置专有的 RARLAB `rar` 二进制。
  - 设置里的 RAR 后端选项从“软件内置”改为“手动安装”，同时保留原有偏好值，避免老用户配置失效。
  - RAR 的“自动”和“手动安装”模式现在都会先查找用户 Application Support 里的本地后端，再回退到系统安装的 `rar` 路径。
  - 新增随 App 附带的 RAR 安装资产：许可说明、README 和安装脚本。App 会带这些文本和脚本，但不会带 RARLAB 二进制本体。
  - RAR 安装脚本现在会下载 RARLAB 官方 macOS 包，并把 universal `rar` 安装到 `~/Library/Application Support/SimpleZip/Tools/rar`，不再写进 App 包或仓库里的 tools 目录。
  - 设置页新增 App 内阅读确认流程：直接展示 RAR 许可说明和 README，并要求分别勾选“我已阅读”后，才允许下载/安装或更新。
  - 设置页新增安装、更新、显示安装文件、打开 README、删除本地 RAR 后端等操作；删除会同时清理本地 `rar` 以及安装时复制出的 RARLAB 说明文件。
  - 修复 RAR 后端选择“系统安装”时的提示：缺失系统 RAR 时只显示 Homebrew 安装命令，不再同时显示本地脚本安装控件。
  - unsigned DMG 打包脚本现在会拒绝意外包含 RARLAB 专有后端的 App 包；只有在明确允许且具备再分发授权的构建里才可放行。
  - Xcode project 新增资源排除规则，避免本地 ignored 的 RARLAB 二进制和说明文件被文件系统同步组自动复制进 App 包。

## 0.1.2

- **压缩包浏览**
  - 统一了主界面顶栏按钮、设置页表单、底部操作区和文件关联行的控件尺寸与按钮样式，减少 Release 打包后出现的按钮高低不齐、输入框和操作按钮尺寸不一致的问题。
  - 修复了 GitHub CI 的 `ArchiveTable` 拖出文件 Promise 导出路径：不再在非主线程上下文里提前捕获主线程隔离的 `model`，避免 Xcode 16.4 Release 构建报 main actor 错误。

## Unreleased

- **资源**
  - 已根据提供的项目图标生成一整套 macOS AppIcon 尺寸资源，并接入 `AppIcon.appiconset`。
  - 已替换为新的图标源，在保留图里原本边框的前提下去掉烘进去的棋盘格背景，并重新生成整套 AppIcon 和 `AppIcon.icns`。
  - About 面板现在会使用真正的应用图标，不再回退到样板图标。
  - 已细化图标蒙版，只去掉外层棋盘格背景，不再切到图标内部内容。
  - 已基于桌面最新图标源重新生成整套 AppIcon 尺寸资源和 `AppIcon.icns`，并把与边缘连通的深色背景抠成透明。
  - 已把图标主体缩回到更符合 macOS 规范的安全区，不会再因为铺得过满而显得比旁边应用更大。
- **压缩包浏览**
  - 压缩包内目录改为真正可进入的目录，不再平铺为完整路径行。
  - 双击压缩包内文件时，现在会把该项目临时解出并交给 macOS 默认 App 打开。
  - 压缩包内项目现在可以直接拖到 Finder 或其他文件目标位置，SimpleZip 会把对应项目解压到拖放位置。
  - 当压缩包没有显式目录项时，自动合成目录节点。
  - 压缩包内部支持双击目录进入、右键打开、上一级返回。
  - 压缩包浏览列表现在补上了更像文件浏览器的项目图标和“种类”列，不再只是一个很素的通用列表。
  - 本地 `.app` 和其他 macOS 包现在默认像应用一样打开、使用包图标，并可从右键菜单选择“显示包内容”。
  - 地址栏现在支持输入时自动补全文件夹，并以可滚动下拉框展示匹配目录和总数；同时支持上下键选择、Tab 补全、回车打开高亮目录。
  - 打开压缩包浏览内容时不再为了列目录就提前要密码；现在只有真正双击打开压缩包内加密文件、需要解压并打开时，才会进入密码鉴权。
  - 设置里的“浏览器”选项卡新增“显示符号链接的文件及文件夹”开关，文件夹浏览、标签结果和地址栏文件夹补全都会立即遵守这个设置。
  - 浏览器选项卡新增“文件夹遵循 Finder 结构”开关；所有文件夹都会走同一套 Finder 对齐列表入口，像 `/Applications` 和 `Utilities` 这类特殊目录会按 Finder 风格合并对应系统应用来源，默认视图保持不变。
  - 收紧了遵循 Finder 结构时 `/Applications` 的合并范围，不再把 CoreServices 里那些 Finder 默认隐藏的辅助 App 一股脑塞进主应用目录；Finder 本体仍会按 Finder 的表现单独补出来。
  - 修复了文件浏览器里本地 `.app` 包的“应用程序”列：不再因为所有应用都共用 `.app` 扩展而复用错误的第三方处理器名称，避免整列都被显示成百度网盘之类的错误结果。
  - 浏览器设置里新增“隐藏后缀”抽屉：内置推荐隐藏后缀列表可逐项勾选，也可以手动添加自定义后缀；只影响文件名显示，不会改动真实文件名和路径。
  - 给“隐藏后缀”补上了总开关，并修复了自定义后缀“添加”按钮的可用性判断：只要输入的是合法且未重复的后缀，就可以直接添加。
  - 把“隐藏后缀”总开关和抽屉标题合并成同一行，不再拆成两条文案重复的设置项。
  - 把自定义隐藏后缀输入区改成更明显的输入框样式，并补了前导点号，不会再和普通设置文字混在一起看不出来能输入。
  - 双击打开压缩包里的单个加密文件时，如果归档元数据已经能判断出它是加密的，现在会直接前置弹出密码框，不再先等后端解压超时或失败后才提示。
- **解压**
  - ZIP 解压现在提供解密方式选择：自动、ZipCrypto、AES-128、AES-192、AES-256；自动模式会按常见兼容路径尝试，避免其他压缩软件创建的加密 ZIP 卡在 macOS `unzip` 的密码错误上。
  - ZIP 自动解密现在会显示检测到的压缩包加密算法，并修正密码框和解密方式之间的间距。
  - 操作详情输出现在支持横向和纵向滚动，后端一次性输出大量长错误行时不会再撑爆详情窗口。
  - 修复了 7-Zip 带密码 ZIP 的解压路径：解压时不再错误传入会被 7-Zip 视为空密码的裸 `-p` 参数。
  - 解压失败的提示链路已补齐：未勾选“显示详情”时会正常弹出“操作失败”并保留完整后端日志供“详情”按钮查看；勾选“显示详情”时失败只保留在详情窗口里，不会再额外弹出重复的失败弹窗。
  - 归档操作失败弹窗现在统一使用共享的预览模型：alert 里只截断预览，完整后端输出始终保留在“详情”里可查看。
  - 整包解压和解压选中项现在共用同一套选项表单，目标目录、密码、详情开关和操作按钮保持一致。
  - 解压现在会先进入临时目录再合并到目标目录，目标里已有同名文件时会走 SimpleZip 的冲突弹窗，不再被后端直接覆盖。
  - 整包解压和解压选中项都支持可选密码。
  - 双击打开压缩包内的加密文件时，现在只会在真正需要解压打开的那一刻弹出密码输入；ZIP 还会同时给出和解压流程一致的解密方式选项。
  - 大压缩包解压时会显示进度和当前正在处理的文件（取决于后端输出）。
  - 即使没有勾选“显示详情”，状态栏在归档操作进行中也会显示当前文件和已处理/总数计数，不再只剩一根进度条。
  - 解压新增“显示详情”选项，可实时打开命令输出详情窗口，并能从状态栏重新打开，方便查看哪些文件被跳过、软链接如何处理等后端提示。
  - 解压选中项默认使用压缩包所在目录，不再提前弹 Finder 选择窗口，需要时再手动更改目标。
  - 整包解压现在也会先进入选项面板，不会一打开就直接弹 Finder 目标目录窗口，只有点“保存到”时才会选择路径。
  - 解压选中项支持“保持目录结构”和“仅解压文件到目标目录”。
  - 主工具栏里的“解压”在压缩包内有选中项时会自动切换为“解压选中项”。
  - ZIP 选中项解压改用 macOS `tar` 的路径列表和抽取能力，避免 `unzip` 出现 `filename not matched`。
  - 选中目录时会展开为子项目再解压。
  - 解压合并阶段现在会遵守默认覆盖策略设置。
  - 同名文件默认策略新增“询问”，可以在静默覆盖/跳过之外回到冲突弹窗逐个决定。
  - 带密码的压缩/解压操作不再把密码直接拼到命令行参数里。
  - 密码提示处理现在会在后端继续索要密码但 SimpleZip 已没有可用响应时明确失败，并终止对应后端进程，避免操作卡住。
- **创建压缩包**
  - 大文件压缩时会显示进度和当前正在处理的文件（取决于后端输出）。
  - 新增创建选项面板。
  - 创建压缩包新增“显示详情”选项，压缩过程的实时命令输出不再只压缩成一行状态文字，并已移到左下角操作区。
  - “添加到压缩包”左下角的“显示详情”现在改成更明显的按钮式开关，不会再像之前那样不够显眼。
  - 压缩和解压选项面板现在共用同一个按钮式“显示详情”组件，两边的样式和位置保持一致。
  - 7-Zip 创建面板已补充字典大小、字大小、固实块大小、路径模式、软/硬链接存储、共享文件压缩、压缩后删除源文件等高级项，更接近传统桌面压缩软件的工作流。
  - 新增压缩包文件名输入框，不需要为了改名字先点“保存到”。
  - 支持选择 ZIP / 7z / TAR / GZ / TGZ / BZ2 / XZ。
  - 支持压缩率选择。
  - 支持可选密码。
  - 支持排除 `.DS_Store`、点开头隐藏文件和自定义规则，TAR / TGZ 创建也会遵守这些过滤项。
  - 创建压缩包前会先统计总文件数，统计阶段显示加载指示器，统计完成后再切换到可信的确定性进度。
  - 长时间运行的归档命令现在可以在状态栏直接取消。
  - 取消运行中任务时，现在会优先取消该任务登记的命令进程，不再只依赖单个全局活跃进程。
  - 归档命令取消现在显式传递 operation ID，不再依赖共享 scope 槽，避免多个操作交叠时把进程登记到错误任务下。
  - 后端进程如果不响应正常终止，会在短暂超时后使用 SIGKILL 兜底结束。
  - 任务运行时的状态栏已改为更紧凑的样式：菊花加载不再占一大片空白，也不再在左下角默认显示内联文件日志，详细输出统一放到“详情”窗口里。
  - ZIP 现在在填写分卷大小时也能创建分卷压缩包；GZ / BZ2 / XZ 会在启动前直接拦住多文件或目录这种无效选择。
  - 点开头隐藏文件选项新增说明，会明确提示 `.env`、`.gitignore`、`.npmrc` 等 dotfiles 也会被排除。
  - 点开头隐藏文件不再默认勾选，`.env`、`.gitignore` 这类文件会默认保留，只有用户主动启用时才排除。
  - 自定义排除区域新增“计算”按钮，可按当前选中的源文件和排除规则统计会被排除的文件数量。
  - 分卷大小写错、密码确认不一致、缺少 RAR 后端、单文件格式误选多文件等情况，现在会在“添加到压缩包”面板内直接显示校验提示。
  - “格式 / 压缩率 / 更新模式”已合并到“添加到压缩包”面板里的同一行。
  - “添加到压缩包”窗口已经重新压紧：密码相关控件改为按需展开，7-Zip 高级项可折叠，窗口高度不再异常膨胀。
  - RAR 创建现在会同时探测应用内、应用资源和系统里的 `rar` 可执行文件；找不到后端时会明确提示，而不是直接假死。
- **稳定性**
  - 新增 GitHub Actions workflow 和本地脚本，可在不使用 Developer ID 证书的情况下构建 unsigned / ad-hoc signed 的 macOS App DMG artifact。
  - unsigned DMG workflow 现在支持手动勾选发布为 GitHub Release，并使用输入的版本号作为 App 版本。
  - unsigned DMG workflow 现在会在打包前安装并校验内置 RAR 后端，避免发布包缺少 RAR 创建能力。
  - 已把 `ArchiveService` 的参数构造和归档解析辅助逻辑拆到独立 Core 文件里，主后端门面不再把所有纯逻辑都堆在一个文件中。
  - `ArchiveBrowserModel` 里的归档操作成功/失败收尾逻辑已统一收口，减少刷新、弹窗和详情状态各自分散处理造成的互相踩状态。
  - 修复 `scripts/build_unsigned_dmg.sh`：在 `set -u` 下没有版本覆盖参数时，不会再因为空数组展开导致 GitHub CI 直接失败。
  - 已把归档表格和文件表格的 coordinator 显式标成 `@MainActor`，修复 Xcode CI 在更严格主线程隔离检查下对菜单、选择和拖放回调访问 `ArchiveBrowserModel` 的编译报错。
  - Xcode project 新增可见的 `SimpleZipCoreTests` target，可直接运行 SwiftPM 核心回归测试。
  - 核心测试已扩展到命令行参数拆分、分卷大小校验、自定义排除、排除数量统计和 RAR 创建参数。
  - 核心回归测试新增归档操作失败弹窗预览截断逻辑覆盖。
  - App 启动时会清理上次打开压缩包内文件留下的临时副本目录。
  - 针对可疑压缩包路径、解出的符号链接，以及从临时副本打开的可执行/主动内容项目加入主动安全确认。
  - 设置里的“压缩”页新增安全性选项，可分别把可疑路径、符号链接、主动内容打开设为询问、始终允许或始终拒绝。
  - 解压合并阶段现在会校验 staging 源文件仍位于临时 staging 目录内，最终目标仍位于用户选择的目标目录内。
  - 解压合并 containment 现在还会校验普通暂存文件/目录和目标父目录的真实解析路径，同时保留显式的符号链接处理语义。
  - README / 中文指南新增当前安全模型、压缩包兼容性矩阵、进度限制和架构拆分边界说明。
  - 清理了归档命令运行器里的 Swift 并发警告，并新增共享 Xcode 运行 scheme，在调试启动时隐藏系统 OS activity 噪声。
  - 后端路径探测不再在设置页渲染期间启动 `which`，避免主线程卡在 `Process.waitUntilExit()`。
  - DMG 挂载和卸载现在走异步命令路径，打开磁盘镜像时不会阻塞主线程。
  - 表头右键进入列表列设置现在改走 App 的 SwiftUI 设置打开路径，并延后切换设置标签页，避免在视图刷新过程中同步修改状态。
  - 压缩包列表排序改为基于原始大小和修改时间，而不是基于格式化后的显示文本。
  - 压缩包和标签加载任务现在会取消过期结果，避免旧任务覆盖新页面。
  - 拖放文件 URL 收集和外部打开事件队列增加了同步保护，避免回调竞争。
  - 打开分卷压缩包时，现在会自动把 `.001/.002`、`.z01`、`.r00` 和 `part02.rar` 这类输入归一化到正确的首卷。
  - DMG 现在可以通过 `hdiutil` 挂载后在 App 内打开，整包解压也会复用现有解压流程把挂载内容复制出来。
  - 新增 service 层回归测试，覆盖归档列表解析、排除规则生成和选中项展开逻辑。
  - 清理了归档解析、进度解析和 About 图标传递里的 Swift 并发与可选值黄警告。
- **文件浏览**
  - 地址栏旁新增“返回”和“前进”导航按钮，和原来的“上一级”区分开。
  - 创建压缩包和解压完成后，会自动刷新当前可见的目标目录，不再需要手动点刷新。
  - 文件列表和压缩包列表现在共用 AppKit 表格创建、列配置、单元格渲染和列设置菜单辅助逻辑。
  - 文件列表项目现在可以拖到列表里的目录上移动，也可以接收外部文件拖入并复制到当前文件夹。
  - 侧边栏新增类似 Finder 的个人收藏、经常使用、标签和固定路径。
  - 标签可以在 App 内打开为虚拟文件列表，底层使用 Spotlight 搜索。
  - 删除文件前会确认，并移动到 macOS 废纸篓。
  - 粘贴遇到同名冲突时支持覆盖、保留两者、跳过、哈希不同时覆盖。
  - 文件列表和压缩包列表支持点击表头排序、再次点击倒序，并支持拖动列顺序。
  - 表头右键可以直接跳到设置里的列表列页面。
  - 路径栏可以直接编辑；输入错误时会跳到最后一个合法目录或压缩包层级。
  - 用 AppKit 表格替换 SwiftUI Table，兼容 macOS 13 并改善多选体验。
  - 支持鼠标拖动多选。
  - 支持复制、剪切、粘贴、移动、删除、Finder 显示和拖出文件。
  - “哈希不同时覆盖”现在会显示哈希计算进度，并在完成后弹窗显示原文件和试图覆盖文件的 SHA256。
  - 文件列表列已经补到更接近 Finder，支持显示种类、应用程序、最后打开日期、添加日期、修改日期、创建日期和大小。
- **文件关联**
  - 设置页改为按扩展名展示文件关联列表。
  - 每种支持的压缩包格式都可以单独设为默认 App。
  - 每行显示当前默认打开程序。
  - 文件关联列表已加入 RAR 和 DMG。
  - Finder 文档类型声明和默认 App 设置现在加入 `.001`、`.z01`、`.r00` 等常见分卷扩展，分卷压缩包可以从 Finder 交给 SimpleZip。
- **哈希**
  - 新增 CRC32、MD5、SHA1、SHA256、SHA512 结果。
- **菜单**
  - 补齐 macOS 顶部“文件”菜单：打开、创建、解压、测试、哈希、显示、刷新、上一级。
  - 编辑菜单在文件列表焦点下执行文件操作，在文本输入焦点下回退到系统原生复制、剪切、粘贴。
  - 刷新按钮已移动到“返回上一级”按钮旁边，目录导航操作现在集中在一起。
  - 文件列表、压缩包列表和列表列表头右键菜单现在都补上了动作图标，顶部命令菜单里的常用项也统一了图标表现。
- **设置**
  - 设置页改为“通用、压缩、浏览器、文件关联、列表列”分类。
  - 新增语言选择。
  - 新增 7-Zip 后端选择：自动、软件内置、系统安装，并显示当前版本。
  - 新增对应的 RAR 后端选择：自动、软件内置、系统安装，并显示当前解析到的路径和版本信息。
  - 7-Zip 后端信息会明确显示当前使用的是内置二进制还是系统二进制。
  - 7-Zip 后端检测现在会搜索内置路径、常见 Homebrew 路径、Homebrew `opt` / `Cellar` 目录和 PATH。
  - 设置页保留启动位置、覆盖策略、隐藏文件显示和列表列设置；默认解压位置选项已移除，因为解压本身已经先进入选项面板。
- **7-Zip 后端**
  - 内置官方 7-Zip 26.01 macOS universal `7zz`，同时包含 `x86_64` 和 `arm64`。
  - App 资源中加入 7-Zip 许可证和 readme 文件。
- **RAR 后端**
  - 新增本地安装脚本，可下载官方 RARLAB macOS ARM 和 x64 包，合成为 universal `SimpleZip/Tools/rar`，同时保持这个专有后端不进入 git。
  - 补充了本地打包时的 RARLAB 再分发授权说明。
- **本地化**
  - 新增英语、简体中文、繁体中文、日语、泰语。
  - 新增西班牙语、法语、德语、韩语、俄语，并接入应用内语言选择。
  - 选中语言包缺少文案时，现在会回退到内置英文文案，不再显示裸本地化 key；英文重复 key 也已清理。
  - 补齐所有内置语言包缺失的安全、导航和密码错误文案。
- **文档**
  - 新增 README、中文指南、更新日志、贡献指南和许可证文件。

## 0.1.0

- SimpleZip 初始原型：
  - macOS SwiftUI 外壳；
  - 文件夹浏览；
  - 基础 ZIP 打开、创建、解压流程；
  - About 面板和项目主页信息。
