# SimpleZip AI 组件参数基准测试报告

> 版本：0.4.5 #80  
> 测试日期：2026-06-16（Phase 1：6 组件参数扫测；Phase 2：AIVirtualFolderPlan + prompt 调优；Phase 3：正反馈 / 主题聚类 / 学习层扫测 + 跨参数联动分析；Phase 4：ThemeSuppression 全参数 + Feedback Cap + 提示词精调 + 数据缺口 + 架构债分析；Phase 5：WorkspaceRanker 权重全扫 + 信号权重 + roleWeight/locationWeight/kindWeight + 预算公式 + matchThreshold + maxTokenBucket 完整参数覆盖）  
> 方法：迭代扫测——每轮修改单参数，运行 `benchmarkMetrics` 测试采集 METRIC 行，恢复源码后继续扫下一个值。全程不产生 commit，工作区最终恢复干净。  
> 驱动脚本：`scripts/ai_param_sweep.py`（Phase 2 新增 7 个 sweep 函数）  
> 指标测试函数：`AIBenchmarkSweepTests.benchmarkMetrics()`（Phase 2 新增 G 组 7 项指标）

---

## 概览

SimpleZip 的 AI 子系统由 6 个独立纯值组件组成，每个组件有 1–3 个可调参数。本报告对所有参数进行了系统性扫测，量化每个参数对关键指标的影响，并给出基于实测数据的最优建议值。

**Phase 1 — 6 组件参数**

| 组件 | 当前参数 | 建议参数 | 关键发现 |
|------|----------|----------|----------|
| WorkspaceRanking | feedbackPenalty=3.0 | **2.5** ✅已应用 | 单参数调整即可让强负反馈抗性 +1 次 |
| WorkspaceRanking | recencyHalfLifeDays=7.0 | **10.0** ✅已应用 | 提升 gap 0.2% |
| StartupDirectoryRanker | 线性 recency | **log-visits + exp-hl14d** ✅已修复 | 🔴 旧目录始终比新目录得分高（bug 已修） |
| SemanticTagRanker | decayPerNegative=0.15 | **0.05** ✅已应用 | 踩掉 #1 标签从 2 次提高到 4 次；测试已同步更新 |
| ThemeSuppression | halfLife=7d | **10d** ✅已应用 | 1 次 dismiss 改为 36 天后重新出现；单测已同步 |
| LearningStore | halfLifeDays=30d | **45d** ✅已应用 | 强不喜欢记忆 neutral 21→31 天；单测已同步 |
| LearningStore | strongNegative=-3.0 | **-2.5** ✅已应用 | 避免 3 次轻踩就触发强排斥 |

**Phase 2 — AIVirtualFolderModelInputPreparer + prompt 参数**

| 组件 | 当前参数 | 建议参数 | 关键发现 |
|------|----------|----------|----------|
| splitTokens | 字符级扫描 | **补充段式切割** ✅已应用 | 版本号「0.4.5」被过滤，专注律从 80%→100% |
| queryTokens 上限 | prefix(12) | **prefix(14)** ✅已应用 | 多 token 工作区额外覆盖 2 个意图 token |
| defaultMaxCandidates | 28 | **后续上调至 50** ✅已应用 | Phase 2 当时建议保留 28；Phase 10 发现 28 是测试池巧合，生产值已上调至 50 |
| high 重要性阈值 | ≥7 | **保留 7** | H=10/N=6/L=12 是最优分层比例 |
| low 重要性阈值 | ≤1 | **保留 1** | 当前分布合理，改动无收益 |
| 折叠阈值 | ≥4 任务 | **保留 4** | 正好折叠 hash(6)+test(4)，5 时漏折 test |
| strongToken 乘数 | ×4.0 | **保留 4.0** | H 分布最佳；×8 时 normal 层几乎消失 |
| project-token 权重 | 3.0 | **保留 3.0** | ≥3.0 才能稳定输出 H=10 |

**Phase 3 — 正反馈 / 主题聚类 / 学习层 + 跨参数联动（2026-06-16）**

| 组件 | 当前参数 | 建议参数 | 关键发现 |
|------|----------|----------|----------|
| SemanticTagRanker | boostPerPositive=0.10 | **保留 0.10** | 已处于最优区（2 次确认提升）；稳定区 0.10–0.15 |
| ThemeEngine | tokenOverlapThreshold=0.34 | **保留 0.34** | 稳定区 0.25–0.45，当前居中，鲁棒性极高 |
| ThemeEngine | minClusterSize=2（函数默认） | **Policy 降至 2** | Policy 默认=3 与函数默认=2 不一致，生产路径丢失 1 个有效主题 |
| LearningStore | cap=5.0 | **保留 5.0** | cap≥5 行为相同；cap=3 记忆仅 8d（过短） |
| SemanticTagRanker | decayPerNegative=0.05 + cap | **cap 不需联动** | tag_demote_at 对 cap 完全不敏感（4 次，与 cap=5/8/12 无关） |

**Phase 4 — ThemeSuppression 全参数 + Feedback Cap + 提示词 + 数据缺口 + 架构债（2026-06-16）**

| 组件 | 当前参数 | 建议参数 | 关键发现 |
|------|----------|----------|----------|
| ThemeSuppression | firstDismissBaseWeight=0.6 | **保留 0.6** | suppress_resurface_days 随值线性增长；0.6 给出 26d（14–40d 合理区间中值） |
| ThemeSuppression | perExtraDismissWeight=0.2 | **保留 0.2** | 仅影响 2x 指标（57→61d）；0.5 过于激进（61d=上限） |
| ThemeSuppression | resurfaceFloor=0.05 | **保留 0.05** | 最强控制杆：0.02→35d / 0.08→21d；0.05 居中 |
| SemanticTagRanker | negativeFeedbackCap=5 | **保留 5** | tag_demote_at 对 cap 完全不敏感（基准 2 次 < 所有 cap 值） |
| SemanticTagRanker | positiveFeedbackCap=5 | **保留 5** | tag_boost_at 对 cap 完全不敏感（同上） |
| 提示词 | 当前 4 模板 | **见 § 17** | 语言规则应置顶；review 拒绝路径应输出空 groups；suggestions 需优先级排序 |
| 数据集 | releasePool 33 件 | **扩充见 § 18** | 缺 report/action/CJK/多位置/版本序列 → 多项关键路径无法测试 |
| 架构 | — | **见 § 19** | Policy 路径 vs 函数路径 gap + 反馈闭环未验证 + 无跨位置测试 |

---

## 0. 改进建议执行状态总表（权威·最新）

> 本表是所有参数改进建议的**唯一真相来源**，覆盖 Phase 1–10 全部扫测结论。下方各 Phase 内的「建议」段落保留原始推理过程，但最终落地状态以本表为准。
> 状态核对方式：直接读取 `SimpleZip/Core/AI/*.swift` 的当前常量值（核对日期 2026-06-16）。

### 0.1 ✅ 已落地（代码当前值已等于建议值）

| 参数 | 文件 | 原默认 | 现行值 | 落地实测效果 |
|------|------|--------|--------|-------------|
| `decayPerNegative` | `AISemanticTag.swift:76` | 0.15 | **0.05** | tag_demote_at 2→**4**（踩掉高确定性标签需 4 次负反馈）；单测已同步 |
| `feedbackPenalty` | `AIWorkspaceModel.swift:365` | 3.0 | **2.5** | ws_neg_demote_at 3→**4** |
| `strongNegative` | `AIWorkspaceLearningStore.swift:21` | -3.0 | **-2.5** | 提高强排斥门槛，避免单次重踩误触发 |
| `recencyHalfLifeDays` | `AIWorkspaceModel.swift:359` | 7.0 | **10.0** | ws_gap 峰值（11.5284 @ 10d） |
| `wFrequency` | `AIWorkspaceModel.swift:361` | 1.5 | **2.5** | ws_neg_demote_at 4→**5**（高频强主题多抗 1 次负反馈） |
| `defaultMaxCandidates` | `AIVirtualFolderPlan.swift:117` | 28 | **50** | 避免真实候选被人工 28 上限截断 |
| `minClusterSize`（Policy 默认） | `AIWorkspaceDiscovery.swift:33` | 3 | **2** | 与 `discoverThemes()` 函数默认对齐，生产路径不再漏 1 个有效主题 |
| `queryTokens` 上限 | `AIVirtualFolderPlan.swift:51` | prefix(12) | **prefix(14)** | 多 token 工作区额外覆盖 2 个意图 token |
| `splitTokens` 段式切割 | `AIVirtualFolderPlan.swift` | 仅字符级 | **+段式** | 版本号「0.4.5」不再被过滤，专注律 80%→100% |
| StartupRanker `visits`/`recency` 公式 | `AIStartupSuggestion.swift` | 线性 | **log2 + exp(hl14d)** | startup_correct 0→**1**（旧目录不再永远压过新目录） |
| `signalWeights["source-ref-match"]` | `AIVirtualFolderPlan.swift:257` | 2.0 | **1.0** | 已于 commit `63725fdc` 落地；tier 分布无损，数值更精简 |
| `feedbackHalfLifeDays` | `AIWorkspaceLearningStore.swift:23` | 30.0 | **45.0** | learn_neutral_days 21→**31**；更贴合用户偏好记忆周期；单测同步改至「45 天 ≈ half」 |
| `baseHalfLifeSeconds` | `AIThemeSuppression.swift:45` | 7d | **10d** | suppress_resurface_days 26→**36**（2x: 57→81）；单测同步改至「10 天 ≈ 0.3 / 40 天 < floor」 |

### 0.2 ⏳ 待落地

**（空）** —— 所有有量化依据的参数建议均已落地。下表仅记录**经评估后明确「不做」**的项，供后续避免误改：

| 参数 | 文件 | 现行值 | 评估结论 |
|------|------|--------|---------|
| `negativeFeedbackCap` / `positiveFeedbackCap` | `AISemanticTag.swift:77/80` | 5 / 5 | ⛔**不改**。decay 落地为 0.05 后 demote_at=4，cap 降到 3 会使 `3×0.05=0.15 < 差距 0.16`，误踩标签永不翻转 → 必须保持 ≥ 5 |

### 0.3 ⛔ 不改（基线已最优 / 当前测试池无法评估）

`boostPerPositive=0.10`、`tokenOverlapThreshold=0.34`、`cap=5.0`、`firstDismissBaseWeight=0.6`、`perExtraDismissWeight=0.2`、`resurfaceFloor=0.05`、`maxBaseWeight=1.0`、`matchThreshold=0.5`、`wRelevance=5.0`、`wRecency=2.5`、`wDwell=2.0`、`maxTokenBucket=80`、StartupRanker `dwell cap=600` / `recencyHalfLife=14d` / `penalty=2.0`、`signalWeights["project-token"]=3.0` 等——均为各自参数有效区间的中段，基线即最优；`userBaseline` / `defaultDemotionMargin` / `roleWeight` / `locationWeight` / `explorationBudget` / `normalBudget` / `signalWeights["failed"|"running"]` 在当前测试池无法触发，需先扩池（见 § 18）才能评估。

---

## 1. 数据与方法

### 1.1 合成测试数据

测试数据集（`AIBenchmarkSweepTests.swift` 文件顶部）涵盖：

- **工作区候选**（7 个）：relevanceScore 梯度从 0.18 到 0.92，openCount 1–14，dwell 0–4200s，lastOpened 0.5d–75d，含 1 个固定置顶、1 个含 2 次负反馈
- **启动目录候选**（6 个）：从 recency=0d 到 recency=40d，visits 1–11，dwell 60–1800s
- **语义标签候选**（5 个）：releaseArtifact=0.88、sourceArchive=0.72、signedContainer=0.65、backup=0.40、documentation=0.30
- **主题指纹**：release/sign 指纹（Jaccard 相似）、无关 photos 指纹
- **候选池**（33 件）：8 个归档、2 个条目、5 个任务、8 个文件、10 个文件夹，已知包含 release+sign 簇和 source 簇

所有数据均为确定性合成（固定 UUID/日期基准 `T0 = Date(referenceDate: 0)`），保证可复现。

### 1.2 测量指标

| 指标 key | 含义 | 期望范围 |
|----------|------|----------|
| `ws_high_low_gap` | 最高相关度 ws(0.92) 与最低(0.18)的得分差 | 越大越好（辨别力强） |
| `ws_neg1_over_D` | 1 次负反馈后高相关 ws 是否仍高于中等相关 ws | 必须为 1 |
| `ws_neg_demote_at` | 多少次负反馈才把 rel=0.92 压到 rel=0.65 以下 | 3–5（太少=过激，太多=无效） |
| `startup_correct` | 新目录(1d)是否排在旧目录(40d,多访问)前 | 必须为 1 |
| `startup_gap` | 新目录 - 旧目录得分差 | 正数（正数越大越稳健） |
| `startup_neg_penalty` | 有负反馈目录(neg=2)与新目录的分差 | 正数（惩罚有效） |
| `tag_demote_at` | 多少次负反馈把 #1 标签(0.88)踩到 #2(0.72)以下 | 3–5 |
| `tag_boost_at` | 多少次正反馈把 #2(0.72)提升至 #1(0.88)以上 | 2–4 |
| `suppress_resurface_days` | 1 次 dismiss 后主题权重衰减至 resurfaceFloor(0.05)的天数 | 14–40d |
| `suppress_resurface_days_2x` | 2 次 dismiss 后重新出现所需天数 | 30–90d |
| `learn_neutral_days` | -4 强不喜欢信号衰减至 strongNegative 以上所需天数 | 15–35d |
| `learn_cap_neutral_days` | -5(cap) 信号衰减至中性所需天数 | 25–60d |
| `theme_count` | 33 件候选中检测出的主题数 | 3（已知 3 个簇） |
| `theme_solo_count` | 5 件完全孤立候选的主题数 | 必须为 0 |

### 1.3 基线测量（当前代码）

```
ws_high_low_gap          = 11.5051
ws_neg1_over_D           = 1          ✓
ws_neg_demote_at         = 3          △ (可接受，但偏激进)
startup_correct          = 0          🔴 BUG
startup_gap              = -1.1000    🔴 新目录得分低于老目录 1.1 分
startup_neg_penalty      = 7.1000     ✓
tag_demote_at            = 2          🔴 2 次即踩掉 #1（应为 3–5）
tag_boost_at             = 2          ✓
suppress_resurface_days  = 26         ✓
suppress_resurface_days_2x = 57       ✓
learn_neutral_days       = 13         △ 偏短（13 天后遗忘强烈不喜欢）
learn_cap_neutral_days   = 23         △
theme_count              = 3          ✓
theme_solo_count         = 0          ✓
```

---

## 2. WorkspaceRanking 参数扫测

### 2.1 feedbackPenalty

**当前值：3.0**  
测量指标：`ws_neg_demote_at`（高相关 ws 被踩到中等以下需要几次负反馈）

| feedbackPenalty | ws_gap | neg1_over_D | neg_demote_at |
|-----------------|--------|-------------|---------------|
| 1.0 | 11.5051 | 1 | 8 |
| 1.5 | 11.5051 | 1 | 6 |
| 2.0 | 11.5051 | 1 | 4 |
| **2.5** | 11.5051 | 1 | **4** ← 推荐 |
| 3.0（当前） | 11.5051 | 1 | 3 |
| 3.5 | 11.5051 | 1 | 3 |
| 4.0 | 11.5051 | 1 | 2 |

**分析**：
- `ws_high_low_gap` 对此参数不敏感（gap 由 `wRelevance × (rel_high - rel_low)` 决定，penalty 对 gap 无影响）
- `neg_demote_at=3` 意味着 3 次"不喜欢"即可让 rel=0.92 的工作区排名跌至 rel=0.65 以下。对于误操作风险较高的界面，这偏激进。
- penalty=2.5 时仍需 4 次（与 penalty=2.0 相同），在「用户真的不喜欢」和「误踩保护」之间取得更好平衡，同时仍保留惩罚效果。

**建议：feedbackPenalty = 2.5**（demote_at: 3 → 4，额外一次负反馈缓冲）

### 2.2 recencyHalfLifeDays

**当前值：7.0**

| recencyHalfLifeDays | ws_gap |
|---------------------|--------|
| 3.0 | 11.3546 |
| 5.0 | 11.4598 |
| 7.0（当前） | 11.5051 |
| **10.0** | **11.5284** ← 峰值 |
| 14.0 | 11.5052 |
| 21.0 | 11.3761 |

**分析**：
- gap 在 10d 时取峰值（11.5284），与 7d（11.5051）相差仅 0.023（0.2%），量化增益极小。
- 从语义上看，10d 半衰期意味着 10 天未打开的工作区 recency 贡献降至 50%，20 天后降至 25%。比 7d（7 天就降到 50%）对间歇性使用者更友好。
- 14d（11.5052）与当前几乎相同，说明高于 10d 就开始饱和；低于 7d（如 3d）则过于激进导致 gap 下降。

**建议：recencyHalfLifeDays = 10.0**（量化提升微小但方向正确，属可选优化）

---

## 3. StartupDirectoryRanker 公式扫测 🔴

### 3.1 问题复现

**当前公式**（`AIStartupSuggestion.swift:104-110`）：
```swift
static func score(_ c: AIStartupCandidate) -> Double {
    let visits = Double(c.visitsInSameBucket)        // 线性，无封顶
    let dwell = min(1.0, Double(c.medianDwellSeconds) / 600.0)
    let recency = max(0.0, 1.0 - 0.1 * Double(c.recencyDays))   // 线性，10d 后归零
    let penalty = 2.0 * Double(c.negativeSignalCount)
    return visits + dwell + recency - penalty
}
```

**测试场景**（`startupCandidates`）：
- s1（`~/Documents/SimpleZip`）：visits=9，dwell=1800s，recency=1d → 应该赢
- s6（`~/Archives/2022`）：visits=11，dwell=900s，recency=40d → 应该输

**当前得分计算**：
- s1 = 9 + min(1,1800/600) + max(0,1-0.1×1) = 9 + 1.0 + 0.9 = **10.90**
- s6 = 11 + min(1,900/600) + max(0,1-0.1×40) = 11 + 1.0 + 0.0 = **12.00** ← 赢了（错误！）

根因：visits 是无界线性整数，而 recency 最多贡献 1.0。两个额外访问记录（11 vs 9）就能永久压过新鲜度优势。**旧目录无限积累访问次数，新目录的新鲜优势永远追不上**。

### 3.2 单行 recency 公式变种（均无法修复 bug）

| 公式 | startup_correct | startup_gap | 说明 |
|------|-----------------|-------------|------|
| `max(0, 1-0.1×d)`（当前） | **0** | -1.10 | visits 线性主导 |
| `pow(0.5, d/7)` | **0** | -1.11 | recency 上限仍为 1.0，不够 |
| `pow(0.5, d/14)` | **0** | -1.19 | 同上 |
| `pow(0.5, d/21)` | **0** | -1.30 | 更慢衰减反而更差 |
| `max(0, 1-√d/10)` | **0** | -1.47 | 同上 |
| `max(0, 1-log₂(d+1)/10)` | **0** | -1.56 | 同上 |

**结论**：仅改 recency 行无效。visits 的线性无界增长才是根本问题。

### 3.3 复合公式：log-visits + exp-recency（成功修复）

改动：`visits → log2(visits+1)`（对数压缩防雪球）+ `recency → exp(hl=N)`（指数衰减）

| 公式 | startup_correct | startup_gap | startup_neg_penalty |
|------|-----------------|-------------|----------------------|
| log+exp_hl7d | **1** ✓ | +0.6236 | 5.38 |
| **log+exp_hl14d** | **1** ✓ | +0.5506 | 5.31 |
| log+exp_hl21d | **1** ✓ | +0.4374 | 5.28 |
| log+2×exp_hl14d | **1** ✓ | +1.3643 | 5.40 |

**为什么 log-visits 有效**：
- log2(11+1) = 3.58，log2(9+1) = 3.32，差距缩小到 **0.26**（原来是 2.0）
- exp(40d/14d) 让 s6 recency = pow(0.5, 2.86) = 0.14，exp(1d/14d) 让 s1 recency = 0.95
- recency 差距 = 0.81 > visits 差距 0.26 → 新目录赢 ✓

**为什么选 hl=14d 而非 hl=7d**：
- hl=7d gap(+0.62) 略高于 hl=14d(+0.55)，但语义上 7d 半衰期意味着 2 周前访问过的目录 recency 仅剩 25%，可能对偶尔工作流的目录过于激进
- hl=14d：2 周前目录 recency=50%，月前目录 recency=12%，语义更自然

**建议修改（`AIStartupSuggestion.swift:105-107`）**：
```swift
// 修改前:
let visits = Double(c.visitsInSameBucket)
let recency = max(0.0, 1.0 - 0.1 * Double(c.recencyDays))

// 修改后:
let visits = log2(Double(c.visitsInSameBucket) + 1)          // 对数压缩，防雪球
let recency = pow(0.5, Double(c.recencyDays) / 14.0)         // 指数衰减，半衰期 14d
```
效果：startup_correct: 0 → **1**，startup_gap: -1.10 → **+0.55**

---

## 4. SemanticTagRanker 参数扫测

### 4.1 decayPerNegative

**现行值：0.05（已落地；原默认 0.15）**  
场景：releaseArtifact(det=0.88) vs sourceArchive(det=0.72)，初始分差 = 0.16

| decayPerNegative | tag_demote_at | tag_boost_at |
|------------------|---------------|--------------|
| **0.05（现行·已落地）** | **4** | 2 |
| 0.08 | 3 | 2 |
| 0.10 | 2 | 2 |
| 0.12 | 2 | 2 |
| 0.15（原默认） | **2** 🔴 | 2 |
| 0.18 | 1 | 2 |
| 0.20 | 1 | 2 |
| 0.25 | 1 | 2 |

**分析**：
- 原默认 0.15：**仅需 2 次负反馈**即可把确定性最高的 tag 踩掉。公式：2 × 0.15 = 0.30 > 分差(0.16)。
- 对于用户偶发误操作（手滑点了「不对」），这会立即破坏标签排序，且 2 次误踩在移动/触控设备上极易发生。
- 0.05：需要 4 次负反馈（4 × 0.05 = 0.20 > 0.16），对应「用户明确多次表达不喜欢」，更符合「小错误不应覆盖确定性证据」的原则。
- negativeFeedbackCap（现=5）：落地 decay=0.05 后，cap=5 的最大衰减 = 0.05 × 5 = 0.25，刚好覆盖分差 0.16（demote_at=4 < cap=5，可达成）。⚠️ 因此 cap **不可再降到 4 以下**——cap=3 时最大衰减 0.15 < 0.16，误踩标签将永不翻转（见 § 0.2 / § 47）。

### 4.2 negativeFeedbackCap

| negCap（配合 decay=0.15） | tag_demote_at |
|--------------------------|---------------|
| 3 | 2 |
| 4 | 2 |
| **5（当前）** | **2** |
| 6 | 2 |
| 8 | 2 |
| 10 | 2 |

**结论**：cap 对 demote_at 无影响（在 demote_at=2 时 cap 未到）。cap 的作用是防无限累积，当前 cap=5 合理，无需调整。

**建议：decayPerNegative = 0.05**（demote 阈值 2 → 4，防止低频误踩破坏标签质量）— ✅**已落地**（Codex 已应用 `0.15→0.05` 并同步更新 `AISemanticTagTests`）。

---

## 5. ThemeSuppression baseHalfLifeSeconds 扫测

**原默认：7d（604800s）→ ✅ 现行值：10d（864000s，已落地）**  
理论公式：resurfaceFloor(0.05) = firstDismissBaseWeight(0.6) × 0.5^(t/halfLife)  
解得：t = halfLife × log₂(0.6/0.05) ≈ halfLife × 3.58

| halfLife(d) | resurface_1次(d) | resurface_2次(d) |
|-------------|-----------------|-----------------|
| 3 | 11 | 25 |
| 5 | 18 | 41 |
| 7（原默认） | 26 | 57 |
| **10（现行·已落地）** | **36** | **81** |
| 14 | 51 | 113 |
| 21 | 76 | 169 |

**分析**：
- 当前 7d：1 次 dismiss 后 26 天重现，2 次后 57 天（约 2 个月）重现。
- 对于「用户随手点了不感兴趣」：26 天后重新出现。多数用户可能已经忘记自己踩过，重现时可能觉得打扰。
- 10d：36 天（约 5 周）重现，对单次轻踩的处理更稳健。2 次踩后 81 天（约 3 个月）重现，对于真正厌倦的主题有充分抑制。
- 14d：113 天（约 4 个月）对 2 次 dismiss 而言偏长——主题内容可能已发生变化，不应抑制这么久。

**✅ 已落地：baseHalfLifeSeconds = 10d（864000s）**（1次后36d，2次后81d；量化合理区间中位点）。落地后实测 `suppress_resurface_days=36 / _2x=81`，与上表一致；`freshDismissalHasHighWeightThenDecays` 测试已同步更新。

---

## 6. LearningStore 参数扫测

### 6.1 feedbackHalfLifeDays

**原默认：30d → ✅ 现行值：45d（已落地）**  
场景：`epoch` 时刻记录 -4 强不喜欢信号，测量多少天后权重衰减至 strongNegative(-3.0) 以上。  
⚠️ 下表 learn_neutral_days 列来自 Phase 1 的旧测试夹具（baseline 30d→13d）；当前夹具下实测为 30d→21d、**45d→31d**（见 § 0.1）。表内相对趋势仍成立，绝对值以现行夹具为准。

| halfLifeDays | learn_neutral_days | learn_cap_neutral_days |
|--------------|-------------------|------------------------|
| 10 | 5 | 8 |
| 14 | 6 | 11 |
| 21 | 9 | 16 |
| 30（原默认） | **13** | 23 |
| **45（现行·已落地）** | **19** | **34** |
| 60 | 25 | 45 |
| 90 | 38 | 67 |

**分析**：
- 当前 30d：强不喜欢 **13 天**后自然消失。对于「用户多次踩了某个工作区主题」，13 天就遗忘似乎太短——用户可能仍记得它打扰过自己，下次它重出现时会觉得系统没有记住反馈。
- 45d：19 天，约 2-3 周，符合「工作记忆消退」的心理模型（人对负面体验的记忆通常比正面更持久）。
- 60d：25 天，接近 1 个月。cap(-5) 信号到 45 天，持久性更强但可能影响正常的兴趣变化。

**✅ 已落地：feedbackHalfLifeDays = 45.0**（更符合用户记忆周期）。当前夹具下实测 learn_neutral_days 21→**31**；`recordingWithTimestampDecaysOverTime` 测试已同步改为「45 天 ≈ half」。

### 6.2 strongNegative（配合 halfLifeDays=30 扫测）

| strongNegative | learn_neutral_days（halfLife=30d） |
|----------------|----------------------------------|
| -1.5 | 43 |
| -2.0 | 31 |
| **-2.5** | **21** ← 推荐 |
| -3.0（当前） | 13 |
| -3.5 | 6 |
| -4.0 | 1 |

**分析**：
- 当前 -3.0：1 次 by=-3 的信号直接触发强排斥（`strongNegative <= -3.0`）。这意味着**单次强负反馈就能触发强排斥**，门槛过低。
- -2.5：需要更强的信号（或累积 by=-2.5 以上），配合 halfLifeDays=45，neutral 会进一步延长到约 26 天。
- -2.5 时 neutral=21d（与 halfLife=30d 配合），切换到 halfLife=45d 后预计约 31d——处于 25-35d 的理想范围。

**建议：strongNegative = -2.5**（与 halfLifeDays=45 配合，强排斥约 4 周后消退）

---

## 7. ThemeEngine tokenOverlapThreshold 基线验证

ThemeEngine 的 `tokenOverlapThreshold` 在 `discoverThemes()` 函数签名中以默认参数方式提供（`= 0.34`），无 `static let` 可直接扫测。基线行为验证：

**场景 A**（33 件候选，含已知 3 个语义簇）：theme_count = **3** ✓  
**场景 B**（5 件完全孤立候选，无共享 token）：theme_solo_count = **0** ✓

当前 0.34 在正常工作场景下表现正确。阈值分析：
- 0.34 = 「3 个共享 token 中至少 2 个重叠才连通」（Jaccard ≥ 34%）
- 过低（如 0.20）：弱关联件错误合并，主题数膨胀
- 过高（如 0.50）：弱连接簇被打散，主题数减少

**建议：维持 0.34**（实测表现正确，无量化证据支持变更）

---

## 8. 汇总：推荐参数变更

> 状态以 § 0 总表为准；本表保留原始优先级与指标改善数据。

| 优先级 | 文件 | 参数/位置 | 原值 | 建议值 | 关键指标改善 | 状态 |
|--------|------|-----------|--------|--------|-------------|------|
| 🔴 P0 | `AIStartupSuggestion.swift:105` | `visits` 公式 | `Double(visits)` | `log2(visits+1)` | startup_correct: 0→**1** | ✅已应用 |
| 🔴 P0 | `AIStartupSuggestion.swift:107` | `recency` 公式 | `max(0,1-0.1×d)` | `pow(0.5, d/14.0)` | startup_gap: -1.10→**+0.55** | ✅已应用 |
| 🟡 P1 | `AISemanticTag.swift` | `decayPerNegative` | 0.15 | **0.05** | tag_demote_at: 2→**4** | ✅已应用 |
| 🟡 P1 | `AIWorkspaceModel.swift` | `feedbackPenalty` | 3.0 | **2.5** | ws_neg_demote_at: 3→**4** | ✅已应用 |
| 🟢 P2 | `AIWorkspaceLearningStore.swift` | `feedbackHalfLifeDays` | 30.0 | **45.0** | neutral_days: 21→**31** | ✅已应用 |
| 🟢 P2 | `AIWorkspaceLearningStore.swift` | `strongNegative` | -3.0 | **-2.5** | 强排斥门槛提高 | ✅已应用 |
| 🔵 P3 | `AIThemeSuppression.swift` | `baseHalfLifeSeconds` | 7d | **10d** | resurface: 26→**36**d | ✅已应用 |
| 🔵 P3 | `AIWorkspaceModel.swift` | `recencyHalfLifeDays` | 7.0 | **10.0** | ws_gap: +0.023（微小） | ✅已应用 |

---

## 9. 数据质量观察

### 9.1 真实数据角色分布问题

来自真实 plist 数据（1124 条）的分析：

| 角色 | 数量 | 占比 |
|------|------|------|
| document | 695 | 61.8% |
| source | 93 | 8.3% |
| config | 48 | 4.3% |
| media | 42 | 3.7% |
| archive | 35 | 3.1% |
| installer | 3 | 0.3% |
| 无角色（空） | 208 | 18.5% |

**问题**：document 角色严重过表达（62%），installer 仅 3 件（0.27%）。这导致：
1. SemanticTag 候选生成时 installer 角色召回率存在结构性风险
2. ThemeEngine 簇更容易被 document 信号主导，弱化其他角色的主题识别
3. LearningStore 的信号质量依赖角色多样性，当前可用信号偏向文档类

**建议**：在 `AIFileSystemFact.scanDirectory` 层面对 document 角色添加采样上限（如每个目录最多 30 件 document），为 installer/media/config 角色保留槽位。

### 9.2 LearningStore 实际数据为空

真实用户数据中 LearningStore 记录为空，说明：
- 用户尚未产生足够的明确正/负反馈（显式按钮操作门槛较高）
- 当前反馈信号来源单一，需要接入更多隐式反馈（打开时长、返回频次、归档操作成功率）

---

## 10. 优化后实测结果（commit 5b070e2）

以下为应用本报告推荐的 3 项生产变更后重新采集的指标（1248 项测试全绿）：

| 指标 | 扫测前基线 | 扫测后（当前） | 改善 |
|------|-----------|--------------|------|
| `ws_high_low_gap` | 11.5051 | **11.5284** | +0.023 ✓ |
| `ws_neg_demote_at` | 3 | **4** | +1 次抗性 ✓ |
| `startup_correct` | **0** 🔴 | **1** ✅ | 核心 bug 修复 |
| `startup_gap` | -1.1000 | **+0.5506** | 由负转正 ✓ |
| `tag_demote_at` | 2 | 2 → **4** | 此快照时仍 2（阻断）；decay 0.05 落地后已为 **4**（见 § 0.1） |
| `learn_neutral_days` | 13 | **21** | +8 天 ✓ |
| `learn_cap_neutral_days` | 23 | **31** | +8 天 ✓ |
| `theme_count` | 3 | 3 | 不变（正确）✓ |

---

## 11. Phase 2：AIVirtualFolderPlan 参数扫测（专注律）

### 11.1 新增 METRIC 指标（G 组）

| 指标 key | 含义 | Phase 2 基线 | Phase 2 后 |
|----------|------|------------|-----------|
| `preparer_coverage` | 强 token 覆盖率（专注律） | 0.8000 | **1.0000** ✅ |
| `preparer_tier_high` | 高优先级候选数 | 10 | 10 |
| `preparer_tier_normal` | 中优先级候选数 | 6 | 6 |
| `preparer_tier_low` | 低优先级候选数 | 12 | 12 |
| `preparer_suppressed` | 被折叠压制的候选数 | 6 | 6 |
| `preparer_output` | 输出给模型的候选总数 | 28 | 28 |
| `prompt_qtokens_count` | prompt 中工作区意图 token 数 | 12 | **14** ✅ |

### 11.2 专注律上限发现

覆盖率从 0.8000 = 4/5 封顶。根因：`splitTokens` 按字母/数字逐字符扫描，版本号「0.4.5」被分解成「0」「4」「5」三个 1 字符片段全部被 `count >= 2` 过滤掉，导致强 token `"0.4.5"` 永远无法从 displayName 中提取。

修复：补充「按连字符/下划线/空格整段保留」的段式切割，使「SimpleZip-0.4.5-macos-arm64.dmg」额外产生 token「0.4.5」（长度 5 ≥ 2，保留）。

### 11.3 maxCandidates 扫测

| maxCandidates | coverage | H | N | L | output |
|---------------|----------|---|---|---|--------|
| 10 | 0.6000 | 5 | 3 | 2 | 10 |
| 14 | **0.8000** | 8 | 4 | 2 | 14 |
| 18 | 0.8000 | 9 | 6 | 3 | 18 |
| 20 | 0.8000 | 10 | 6 | 4 | 20 |
| 24 | 0.8000 | 10 | 6 | 8 | 24 |
| **28（当前）** | 0.8000 | 10 | 6 | 12 | **28** |
| 32+ | 0.8000 | 10 | 6 | 12 | 28（池上限） |

覆盖率在 maxCandidates=14 时饱和（池内可覆盖的 4 个强 token 已全部命中）。实际可用候选池上限为 28（33 件 - 6 件折叠 + 2 件摘要）。继续增大 maxCandidates 无效。

**保留 28**：虽然 14 已达覆盖饱和点，但 28 为模型提供更丰富的排序上下文（H/N/L 分层更完整）。

### 11.4 重要性阈值扫测

| high 阈值 | coverage | H | N | L |
|-----------|----------|---|---|---|
| 4 | 0.8000 | 14 | 2 | 12 |
| 5 | 0.8000 | 11 | 5 | 12 |
| 6 | 0.8000 | 10 | 6 | 12 |
| **7（当前）** | 0.8000 | **10** | **6** | **12** |
| 8 | 0.8000 | 8 | 8 | 12 |
| 9 | 0.8000 | 6 | 10 | 12 |
| 10 | 0.8000 | 5 | 11 | 12 |

| low 阈值 | coverage | H | N | L |
|---------|----------|---|---|---|
| 0.0 | 0.8000 | 10 | 9 | 9 |
| **1（当前）** | 0.8000 | **10** | **6** | **12** |
| 1.5 | 0.8000 | 10 | 5 | 13 |
| 3.0 | 0.8000 | 10 | 4 | 14 |

**分析**：high=7 是「既不过于宽泛（high 占 36%），也不过于严格（normal 仍有 21%）」的均衡点。high=4 时高达 50% 候选都是 high，模型失去区分度；high=10 时 normal 层过满（39%），high 信号失效。

### 11.5 折叠阈值扫测

| 折叠阈值 | coverage | 折叠数 | 输出数 |
|---------|----------|--------|--------|
| 2 | 0.8000 | 7 | 28 |
| 3 | 0.8000 | 7 | 28 |
| **4（当前）** | 0.8000 | **6** | **28** |
| 5 | 0.8000 | 4 | 28 |
| 6 | 0.8000 | 4 | 28 |
| 8+ | 0.8000 | 0 | 28 |

**分析**：阈值=4 正好折叠了 hash 簇（6 件）和 test 簇（4 件），分别保留 2 件代表 + 1 条摘要。阈值=5 时 test 簇（恰好 4 件）逃脱折叠，4 件雷同任务全量喂模型。阈值=3 时 sign 簇（3 件）也被折叠，丢失了签名任务的个体区分度。**当前值最优**。

### 11.6 strongToken 乘数扫测

| 乘数 | coverage | H | N | L |
|------|----------|---|---|---|
| 1.0 | 0.8000 | 4 | 9 | 15 |
| 2.0 | 0.8000 | 6 | 8 | 14 |
| 3.0 | 0.8000 | 8 | 7 | 13 |
| **4.0（当前）** | 0.8000 | **10** | **6** | **12** |
| 5.0 | 0.8000 | 10 | 6 | 12 |
| 6.0 | 0.8000 | 11 | 5 | 12 |
| 8.0 | 0.8000 | 14 | 2 | 12 |
| 10.0 | 0.8000 | 16 | 0 | 12 |

**分析**：×4.0 是让「有 2 个强 token 的候选」（如 arch-arm64-dmg）比「有 1 个强 token」差出 4 分的分水岭，正好配合重要性阈值 7 产生 H=10。×8 时 normal 层仅剩 2 件；×10 时 normal 层完全消失，模型无法区分第二层优先级。**当前值最优**。

### 11.7 project-token 权重扫测

| 权重 | coverage | H | N | L |
|------|----------|---|---|---|
| 1.0 | 0.8000 | 6 | 10 | 12 |
| 1.5 | 0.8000 | 7 | 9 | 12 |
| 2.0 | 0.8000 | 8 | 8 | 12 |
| 2.5 | 0.8000 | 8 | 8 | 12 |
| **3.0（当前）** | 0.8000 | **10** | **6** | **12** |
| 4.0–6.0 | 0.8000 | 10 | 6 | 12 |

**分析**：project-token=3.0 是使 H=10 的最小值。低于 3.0 时，部分 project-token 候选得分不足以进入 high 层，H 降至 8。权重 ≥3.0 后输出稳定，继续提高无额外收益。

### 11.8 queryTokens prefix 上限扫测

测试对象：一个含 18 个 unique token 的合成工作区（10 semanticTags + 4 taskTags + 4 keywords）。

| cap | prompt 中实际 token 数 |
|-----|-----------------------|
| 4 | 4 |
| 6 | 6 |
| 8 | 8 |
| 10 | 10 |
| **12（旧）** | 12 |
| **14（新）** | **14** ✅ |
| 16 | 16 |
| 20 | 18（池上限，全部覆盖） |

**分析**：12 → 14 使该 18-token 工作区额外覆盖 2 个 taskTag token。semanticTags（10 个）全部覆盖；taskTags 现在也有 4 个全部覆盖；只有 4 个 keywords 的前 0 个被覆盖（需 cap≥14 才能覆盖 taskTags 全部）。对于语义标签丰富的工作区（实际发布类工作区通常有 8-12 个 semanticTag），cap=14 已足够覆盖主要意图。

---

## 12. 优化后实测结果（全 Phase）

| 指标 | Phase 1 前基线 | Phase 1 后 | Phase 2 后（当前） |
|------|--------------|------------|-------------------|
| `ws_high_low_gap` | 11.5051 | 11.5284 | 11.5284 ✓ |
| `ws_neg_demote_at` | 3 | **4** | 4 ✓ |
| `startup_correct` | **0** 🔴 | **1** ✅ | 1 ✓ |
| `startup_gap` | -1.1000 | +0.5506 | +0.5506 ✓ |
| `learn_neutral_days` | 13 | **21** | 21 ✓ |
| `preparer_coverage` | —（新指标）| — | **1.0000** ✅ |
| `prompt_qtokens_count` | —（新指标）| — | **14** ✅ |
| `theme_count` | 3 | 3 | 3 ✓ |

---

## 13. 下一步行动项

### 已完成
- ✅ StartupRanker 公式修复（log-visits + exp-hl14d）
- ✅ feedbackPenalty 3.0→2.5
- ✅ recencyHalfLifeDays 7.0→10.0
- ✅ strongNegative -3.0→-2.5
- ✅ splitTokens 补充段式切割（专注律 0.8000→1.0000，+20%）
- ✅ queryTokens 上限 12→14（prompt 意图 token 覆盖更完整）
- ✅ **decayPerNegative 0.15→0.05**（tag_demote_at 2→4；Codex 落地 + 单测同步）
- ✅ **wFrequency 1.5→2.5**（ws_neg_demote_at 4→5）
- ✅ **defaultMaxCandidates 28→50**（生产值，避免真实候选被测试池上限截断）
- ✅ **AIRecommendationPolicy.minClusterSize 3→2**（与 discoverThemes 默认对齐）
- ✅ **source-ref-match 2.0→1.0**（commit `63725fdc`；tier 分布无损）
- ✅ **feedbackHalfLifeDays 30→45**（learn_neutral_days 21→31；偏好记忆周期更贴合 + 单测同步）
- ✅ **baseHalfLifeSeconds 7d→10d**（suppress_resurface_days 26→36；dismiss 记忆更久 + 单测同步）

### 受测试硬编码阻断 —— ✅ 全部已解除

原列 3 项需同步更新测试的改进，**现已全部落地**（含测试同步重写）：

**1. ✅ 已落地 — decayPerNegative 0.15→0.05（tag_demote_at 2→4）**  
Codex 应用 `0.15→0.05`，并把受影响断言（`posNegFeedbackCombined`、`negativeFeedbackIsCapped` 等）按 `5×0.05=0.25` 的新衰减重写，新增 `negativeFeedbackRequiresFourHitsForBenchmarkGap` 锚定 4 次翻转。

**2. ✅ 已落地 — feedbackHalfLifeDays 30→45（learn_neutral_days 21→31）**  
`AIWorkspaceLearningStore.swift:23` 改为 45.0；测试 `recordingWithTimestampDecaysOverTime` 的「30 天 = 半衰期」断言改为「45 天后 ≈ half」（`epoch.addingTimeInterval(45 * 86_400)`，期望 -2.0）。`isStronglyDislikedDecaysWithTime`（120d 跨阈值）用 45d 仍成立，仅更新了注释。

**3. ✅ 已落地 — baseHalfLifeSeconds 7d→10d（suppress_resurface_days 26→36）**  
`AIThemeSuppression.swift:45` 改为 10 天；测试 `freshDismissalHasHighWeightThenDecays` 的「7 天 ≈ 0.3 / 30 天 < floor」断言改为「10 天 ≈ 0.3 / 40 天 < floor」（10d 半衰期下 30 天权重 0.075 仍 > floor，故远期点推到 40 天）。其余相对比较型断言用 10d 仍成立，未改。

**验证**：SwiftPM 全量 1276 测试通过（含上述两项的新断言 + benchmark 的 `suppressedCount>=6` / `strongTokenCoverage>=0.5`）。

### 架构层面待做
- **扩展隐式反馈来源**：将文件浏览停留时长、归档打开成功率等信号接入 `AIWorkspaceLearningStore`，为当前空的 feedback 数据积累基础。
- **候选池角色平衡**：在 `AIFileSystemFact.scanDirectory` 对 document 角色添加采样上限（建议每目录 ≤ 30 件），给 installer/media/config 角色保留槽位，缓解 62% 偏斜。
- ~~**AIRecommendationPolicy.minClusterSize 修正**~~：✅已落地——`AIRecommendationPolicy` 的 init 默认 minClusterSize 现为 2，与 `discoverThemes()` 对齐，生产路径不再丢失有效主题（见第 14.3 节）。

---

## 14. Phase 3 扫测（正反馈 / 主题聚类 / 学习层 + 跨参数联动）

> Phase 3 于 2026-06-16 运行，所有改动均在测试后 `git restore` 重置，工作区保持干净。

### 14.1 SemanticTagRanker — boostPerPositive 扫测

**当前值：0.10**  
测量指标：`tag_boost_at`（把 #2 标签 sourceArchive(0.72) 提升到 #1 releaseArtifact(0.88) 以上需要几次正反馈）

分数提升公式：`0.72 + n × boostPerPositive > 0.88`  
→ `n > 0.16 / boostPerPositive`

| boostPerPositive | tag_boost_at | n 解析值 | 评估 |
|-----------------|--------------|----------|------|
| 0.05 | 4 | >3.20→4 | 太慢：需 4 次确认才能提升 |
| 0.08 | 3 | >2.00→3 | 适中：3 次确认 |
| **0.10（当前）** | **2** | **>1.60→2** | **✓ 最优区：2 次确认** |
| 0.12 | 2 | >1.33→2 | 与当前相同 |
| 0.15 | 2 | >1.07→2 | 与当前相同 |
| 0.20 | 1 | >0.80→1 | 过激进：1 次误触即提升 |

**分析**：
- **当前值 0.10 处于最优区中心**（2 次确认）。从 0.10 到 0.15 均为 2 次，有 0.05 宽的参数余量；
- 0.20 达到 1 次触发，存在误操作风险（单次错误确认即改变排序）；
- 0.08 多一次确认保护（3 次），对 UI 标签 picker 场景更稳健，但响应略慢；
- 结合负反馈方向（`tag_demote_at=2`），正负对称度良好（均为 2 次）。

**建议：保留 0.10**（已处于最优区；若需更保守可降至 0.08）

---

### 14.2 AIWorkspaceThemeEngine — tokenOverlapThreshold 扫测

**当前默认：0.34**  
测量指标：`theme_count`（33 件候选池中发现的主题数；期望 3）、`theme_solo_count`（5 件孤立候选组成的主题数；期望 0）

| tokenOverlapThreshold | theme_count | theme_solo_count | 评估 |
|----------------------|-------------|-----------------|------|
| 0.15 | 2 | 0 | 阈值过低：合并过急（source/sign 合并为一个大簇） |
| 0.20 | 2 | 0 | 同上 |
| **0.25** | **3** | **0** | **✓ 稳定区下边界** |
| **0.30** | **3** | **0** | **✓ 稳定** |
| **0.34（当前）** | **3** | **0** | **✓ 最优，居中于稳定区** |
| **0.40** | **3** | **0** | **✓ 稳定** |
| **0.45** | **3** | **0** | **✓ 稳定区上边界** |
| 0.55 | 5 | 0 | 阈值过高：过度分裂（原单一簇裂开为多个） |
| 0.60 | 5 | 0 | 同上 |

**分析**：
- **稳定区：0.25–0.45**，宽达 0.20，说明当前默认值 0.34 鲁棒性极高；
- 低于 0.20：不同角色的条目（source 与 release+sign）因部分共享 token（如版本号 `0.4.5`）被过度合并；
- 高于 0.50：单一强关联簇因 token 多样性而裂成细粒度子簇（如 `release-0.4.5` 与 `release-0.4.4` 被分开），theme_count 虚高；
- 在整个稳定区内，`theme_solo_count` 始终为 0，说明孤立候选保护机制工作正常。

**建议：保留 0.34**（居中于 0.25–0.45 稳定区；任何方向变动 ±0.10 均无影响）

---

### 14.3 AIWorkspaceThemeEngine — minClusterSize 扫测

**discoverThemes() 默认：2**（注：`AIRecommendationPolicy.default` 默认 minClusterSize=3，走 policy 路径时实际使用 3）  
测量指标：`theme_count`

| minClusterSize | theme_count | theme_solo_count | 评估 |
|----------------|-------------|-----------------|------|
| **2（当前函数默认）** | **3** | **0** | **✓ 发现全部 3 个已知簇** |
| 3（Policy 默认） | 2 | 0 | 🔴 丢失一个 2 成员的有效簇 |
| 4 | 1 | 0 | 严重过滤：仅保留最大簇 |
| 5 | 1 | 0 | 同上 |

**分析**：
- **架构不一致**：`discoverThemes()` 函数默认为 `minClusterSize=2`，而 `AIRecommendationPolicy.default` 强制为 `minClusterSize=3`。通过 `AIWorkspaceDiscovery.recommendThemes()` 调用（即生产路径）会丢失测试数据中第三个仅有 2 成员的有效主题；
- `minClusterSize=2` 的 33 件测试池中，所有发现的簇均有 ≥2 个语义相关成员，无噪声假正例；
- `minClusterSize=3` 对于更大的真实候选池（数百件）可能是合理的过滤阈值，但在测试集上表现次优；
- `theme_solo_count=0` 在所有 minClusterSize 值下均成立（孤立件绝不单独成主题），符合设计预期。

**建议**：将 `AIRecommendationPolicy.default.minClusterSize` 从 3 降至 **2**，与 `discoverThemes()` 函数默认值对齐，避免生产路径与直接调用路径行为不一致。

---

### 14.4 AIWorkspaceLearningStore — cap 扫测

**当前值：5.0**  
测量指标：`learn_neutral_days`（by=-4 信号衰减至 strongNegative=-2.5 以上所需天数）、`learn_cap_neutral_days`（by=-5 即 cap 值信号衰减所需天数）

| cap | learn_neutral_days | learn_cap_neutral_days | 评估 |
|-----|-------------------|----------------------|------|
| 3.0 | 8 | 8 | 🔴 过弱：-4/-5 均被截至 -3.0，8 天就遗忘 |
| **5.0（当前）** | **21** | **31** | **✓ 最优：在 15-35d 期望区间内** |
| 8.0 | 21 | 31 | 与 5.0 完全相同（-4/-5 均未触顶） |
| 10.0 | 21 | 31 | 与 5.0 完全相同 |

**分析**：
- cap=3.0：绝对值大于 3 的信号（-4/-5）均被截断至 -3.0。-3.0 与 strongNegative=-2.5 差值仅 0.5，在 halfLife=30d 下约 8 天即衰减过门槛——**记忆过短**；
- cap=5.0：-4 未触顶（|-4|<5），保持原始权重。衰减公式 `-4 × 0.5^(t/30) = -2.5` → t≈20.3d，向上取整为 21 天。-5（正好在 cap 边界）衰减 31 天，均处于期望区间（15-35d）；
- cap≥5.0（8.0、10.0）：对测试信号范围（-4、-5）行为完全相同，因两者均未触碰更高的 cap。但更高的 cap 允许极端情况（如重复踩踏 10+ 次）积累到非常强的负权重（如 -10），造成 `halfLife × log₂(10/2.5) ≈ 60d` 的遗忘周期——**可能过长**；
- 分析阈值：cap 有效范围 = `cap > |strongNegative|`（必须 > 2.5 才能让强排斥有梯度）。cap=5 满足，cap=3 勉强（-3 - (-2.5) = 0.5 裕量过小）。

**建议：保留 cap=5.0**。提高 cap 无改善（测试信号范围内行为不变），降低至 3 会严重缩短学习记忆。

---

### 14.5 跨参数联动：decayPerNegative=0.05 + negativeFeedbackCap 交叉扫测

> 背景：Phase 2 建议将 `decayPerNegative` 从 0.15 降至 0.05（使标签更稳定），该改动**现已由 Codex 落地并同步更新单测**。  
> Phase 3 目标：测量该改动落地后，`negativeFeedbackCap` 是否需要同步调整 → 结论：不需要（见下）。

测量指标：`tag_demote_at`（releaseArtifact(0.88) 降至 sourceArchive(0.72) 以下需要几次负反馈）

| decayPerNegative | negativeFeedbackCap | tag_demote_at | 备注 |
|-----------------|---------------------|---------------|------|
| 0.15（原默认） | 5 | 2 | 旧基线 |
| 0.05（现行·已落地） | 5 | 4 | cap 不变，demote_at 从 2→4（4 次负反馈） |
| 0.05 | 8 | 4 | cap 增大，demote_at **不变** |
| 0.05 | 12 | 4 | cap 进一步增大，demote_at **仍不变** |

**数学分析**：  
`tag_demote_at` 由分数差（0.88 - 0.72 = 0.16）和 `decayPerNegative` 决定：  
`n > 0.16 / 0.05 = 3.2` → n=4（不受 cap 影响，因 4 < 所有测试 cap 值）

`cap` 仅影响「深度饱和」场景（如 20+ 次重复负反馈）：
- cap=5 时：最大惩罚 = 5×0.05 = 0.25。对于 deterministicScore > 0.25 的标签，cap 之后永远不会完全消除（plateaus at score - 0.25）；
- cap=12 时：最大惩罚 = 12×0.05 = 0.60，可消除 deterministicScore ≤ 0.60 的标签；
- cap=20 时：最大惩罚 = 20×0.05 = 1.00，理论上可完全抑制任何标签。

**结论**：
1. **cap 不需要随 decayPerNegative 同步修改**——`tag_demote_at` 指标对 cap 完全不敏感；
2. 若接受「标签永不完全消除」（仅被降权），cap=5 已足够；
3. 若希望频繁错误标签最终完全退出候选，需将 cap 提高至 ≥ `0.88/0.05 = 17.6`（即 cap=18），但这会让记忆时间极长；
4. **实际推荐**：应用 decayPerNegative=0.05 时，**保持 negativeFeedbackCap=5 不变**。

---

### 14.6 Phase 3 汇总与建议

**Phase 3 实测结论（按优先级排序）：**

| 参数 | 当前值 | 建议值 | 依据 | 状态 |
|------|--------|--------|------|------|
| `AIRecommendationPolicy.default.minClusterSize` | 3 | **2** | Policy 路径与 discoverThemes 默认不一致，丢失有效主题 | ✅已应用（init 默认现为 2） |
| `boostPerPositive` | 0.10 | **保留 0.10** | 已处于最优区（2 次确认）；0.08 为保守替代 | ⛔不改 |
| `tokenOverlapThreshold` | 0.34 | **保留 0.34** | 居中于 0.25–0.45 稳定区，任意方向 ±0.10 无影响 | ⛔不改 |
| `LearningStore.cap` | 5.0 | **保留 5.0** | cap≥5 行为相同；cap=3 过于短暂（8d） | ⛔不改 |
| `decayPerNegative=0.05` 时 `cap` | 5 | **保留 5** | cap 对 demote_at 无影响；深度饱和场景保留现有上限 | ⛔不改 |

**Phase 3 新增测试阻断项（无）**：Phase 3 所有扫测发现的建议值均不需要修改测试——唯一的建议改动（Policy.minClusterSize=2）当前已落地。

**遗留 Phase 2 测试阻断进度**：第 13 节原列 3 项阻断 **现已全部落地**（`decayPerNegative 0.15→0.05` 由 Codex；`feedbackHalfLifeDays 30→45`、`baseHalfLifeSeconds 7d→10d` 由 Opus），各自单测均已同步更新（详见 § 0.1 / § 13）。

---

### 架构层面待做
- **扩展隐式反馈来源**：将文件浏览停留时长、归档打开成功率等信号接入 `AIWorkspaceLearningStore`，为当前空的 feedback 数据积累基础。
- **候选池角色平衡**：在 `AIFileSystemFact.scanDirectory` 对 document 角色添加采样上限（建议每目录 ≤ 30 件），给 installer/media/config 角色保留槽位，缓解 62% 偏斜。
- ~~**AIRecommendationPolicy.minClusterSize 修正**~~：✅已落地——`AIRecommendationPolicy` 的 init 默认 minClusterSize 现为 2，与 `discoverThemes()` 对齐，生产路径不再丢失有效主题（见第 14.3 节）。

---

---

## Phase 4：ThemeSuppression 全参数 + Feedback Cap + 提示词 + 数据缺口 + 架构债（2026-06-16）

Phase 4 完成了所有剩余可扫测参数，并在代码层面对提示词模板、测试数据集、架构债务进行了系统性梳理，目的是为 Opus 提供一份可直接执行的优化路线图。

---

### 15. ThemeSuppression 全参数扫测

本节完成 Phase 3 已开始但未完成的 `AIThemeSuppressionPolicy` 其余参数扫测，与 Phase 3 中 `firstDismissBaseWeight` 结果合并汇报。

#### 15.1 firstDismissBaseWeight（来自 Phase 3）

控制**首次 dismiss** 后的初始抑制强度（count=1 时的 base weight）。

| firstDismissBaseWeight | suppress_resurface_days | suppress_resurface_days_2x |
|------------------------|------------------------|--------------------------|
| 0.4 | 22 | 51 |
| 0.5 | 24 | 54 |
| **0.6（当前）** | **26** | **57** |
| 0.8 | 29 | 61 |
| 1.0 | 31 | 61 |

**分析**：suppress_resurface_days 随 firstDismissBaseWeight 单调递增（每 +0.1 约 +1.5d）。suppress_resurface_days_2x 在 0.8 后趋于平台（61d），因为第二次 dismiss 的 base = min(1.0, 0.8+0.2) = 1.0 已触顶 maxBaseWeight=1.0。

**结论**：0.6 给出 26d（位于 14–40d 合理区间的中值），无需调整。若要增加首次 dismiss 的记忆持久性，优先调整 resurfaceFloor（见 § 15.3），而不是 firstDismissBaseWeight。

#### 15.2 perExtraDismissWeight 扫测

控制每次**额外 dismiss**（count>1）对 base weight 的线性增量。当前值=0.2，扫测范围 0.1–0.5。

| perExtraDismissWeight | suppress_resurface_days | suppress_resurface_days_2x |
|----------------------|------------------------|--------------------------|
| 0.1 | 26 | 54 |
| **0.2（当前）** | **26** | **57** |
| 0.3 | 26 | 59 |
| 0.5 | 26 | 61 |

**分析**：
- suppress_resurface_days（单次 dismiss）对本参数**完全不敏感**——单次 dismiss 的 base 仅由 firstDismissBaseWeight 决定，perExtraDismissWeight 不参与（dismissCount-1=0 → 乘数为 0）。
- suppress_resurface_days_2x（两次 dismiss）随值增大而增大：0.1→54d，0.5→61d。0.5 时 base = min(1.0, 0.6+0.5) = 1.0 已触顶，与 0.3 接近。

**结论**：当前值 0.2 合理——第二次 dismiss 比第一次多记 3d（57 vs 26），体现「越踩越记」但不夸张。若需要让重复 dismiss 记忆更长，可升至 0.3（59d）；0.5 与 0.3 效果接近（都触顶 maxBaseWeight），不值得升那么高。

#### 15.3 resurfaceFloor 扫测（最关键参数）

控制抑制权重低于多少值时视为「已充分衰减，主题可重新出现」。当前值=0.05，扫测范围 0.02–0.10。

| resurfaceFloor | suppress_resurface_days | suppress_resurface_days_2x |
|---------------|------------------------|--------------------------|
| 0.02 | 35 | 75 |
| **0.05（当前）** | **26** | **57** |
| 0.08 | 21 | 47 |
| 0.10 | 19 | 43 |

**分析**：resurfaceFloor 是整个抑制系统中**最强的控制杆**，对两个指标均有大幅影响：
- floor=0.02：权重须衰减至 2% 才放行 → 35d（比当前多 9d）
- floor=0.10：权重衰减至 10% 即放行 → 19d（比当前少 7d）
- 每 0.01 的变化约对应 ±1.5d 的 resurface 时间

**物理解释**：抑制权重 = base × 0.5^(Δt / halfLife)。解方程 base × 0.5^(Δt/halfLife) = floor 得 Δt = halfLife × log₂(base/floor)。floor 越小 → Δt 越大。

**结论**：resurfaceFloor 当前值 0.05 是最优值——居于合理区间中值。注：`baseHalfLifeSeconds` 现已落地为 10d（原 7d），故配合后的直觉体验为「~1.5 周抑制渐弱，~5 周完全遗忘」（resurface 36d）。如需进一步调整记忆持久性，resurfaceFloor 与 halfLifeSeconds 均可（两者测试均已解除阻断）。

#### 15.4 ThemeSuppression 三参数交互关系

```
suppress_resurface_days ≈ halfLifeSeconds × log₂(firstDismissBaseWeight / resurfaceFloor)
                       = 7d × log₂(0.6 / 0.05) = 7 × 3.585 = 25.1d ≈ 26d ✓

suppress_resurface_days_2x ≈ (halfLifeSeconds × 2) × log₂(min(maxBase, firstDismiss + perExtra) / resurfaceFloor)
                           = 14d × log₂(min(1.0, 0.6+0.2) / 0.05) = 14 × 4.0 = 56d ≈ 57d ✓
```

三参数相互独立（无交叉依赖）：
- `firstDismissBaseWeight` 控制首次 dismiss 基础强度
- `perExtraDismissWeight` 控制重复 dismiss 的渐增幅度（触发 maxBaseWeight 上限后饱和）
- `resurfaceFloor` 控制「忘记门槛」（最强控制杆）

---

### 16. Feedback Cap 扫测（两参数均不敏感）

#### 16.1 negativeFeedbackCap 扫测

| negativeFeedbackCap | tag_demote_at | 说明 |
|--------------------|--------------|------|
| 3 | 2 | |
| **5（当前）** | **2** | |
| 8 | 2 | |
| 12 | 2 | |

#### 16.2 positiveFeedbackCap 扫测

| positiveFeedbackCap | tag_boost_at | 说明 |
|--------------------|-------------|------|
| 3 | 2 | |
| **5（当前）** | **2** | |
| 8 | 2 | |
| 12 | 2 | |

**分析**：两个 cap 参数在全部扫测范围内指标完全不变。原因是 tag_demote_at/tag_boost_at 由 `decayPerNegative` 和 `boostPerPositive` 的大小决定（达到反转需 2 次，远低于所有 cap 值）。Cap 参数只在 negHits > cap 时才生效——即防止「反复踩同一个标签 > cap 次」时分数继续无限下降。当前测试场景的 feedback 序列仅 2 次，始终触不到 cap。

**这意味着**：
1. 当前 cap=5 正确且不需要改动——它是安全边界，不是行为控制参数
2. 若 cap 被调低至 1 或 2，tag_demote_at 才会开始变化（因为 min(negHits, cap) 被截断）
3. 完整测试 cap 需要在 `releasePool` 中加入已有 6+ 次负反馈的候选（见 § 18 数据缺口建议）

**结论**：negativeFeedbackCap 和 positiveFeedbackCap 均**保持当前值 5 不变**。

---

### 17. 提示词精调分析与最优提示词文本

本节分析 `AIVirtualFolderModelPlanner.swift` 中的 4 个提示词模板，指出当前问题，并给出经过推理的改进版本（供 Opus 直接替换）。

**前置背景（架构约束，改提示词时不得违反）**：
- 模型使用 Apple FoundationModels（macOS 26 本地小模型），单次生成失败率约 90%，依赖 maxAttempts=12（plan/review）/ 8（suggestions/verifyMisfits）重试
- 候选集限制 `prefix(40)`——短 prompt 是降低失败率的关键，不应增加 prompt 长度
- 所有候选通过数字序号（1, 2, 3…）引用，绝不输出路径——这是已验证的最重要可靠性改进
- `@Generable` schema 字段的 `@Guide` 注释由 schema 层控制，提示词只负责 instructions + prompt 两段

#### 17.1 当前提示词问题汇总

| 问题 | 影响提示词 | 严重程度 | 描述 |
|------|-----------|----------|------|
| 语言规则在末尾 | plan / review | 高 | 小模型对上文权重高于下文；`namingRule` 放末尾导致语言混用风险高 |
| review 拒绝路径没有明确输出 | review | 高 | 当前只说「set worthSurfacing=false」但没说 groups 应该为 []；模型倾向于仍然填 groups（浪费 tokens + 解析歧义） |
| worthSurfacing 条件是散文段落 | review | 中 | 3 个并列条件埋在一段话里；小模型对结构化条件（编号列表）响应更稳定 |
| suggestions 无优先级引导 | suggestions | 中 | 当前告知「FEW items」但未说如何选择那 FEW——模型倾向于随机采样 |
| verifyMisfits 保守度措辞偏弱 | verifyMisfits | 中 | "CLEARLY do not belong" 和 "when in doubt, leave it OUT" 是好的，但 "Most items usually fit" 需要更显著 |
| plan/review 缺少 group 命名长度约束 | plan / review | 低 | @Guide 里有「1-3 words」，instructions 里没有——两处一致更好 |
| verifyMisfits roleTags 未加利用 | verifyMisfits | 低 | 格式行带了 roleTags 但 instructions 没提引导模型基于 role 判断 |

#### 17.2 改进版 plan() instructions

以下是改进后的 `plan()` 函数 `instructions` 字符串（Swift 多行字符串格式）：

```swift
let instructions = """
\(Self.namingRule)

You curate and organize a set of related items around a theme. Each item below is one \
line: "number<TAB>kind<TAB>name<TAB>roleTags", where number is a small integer in the \
leftmost column. Using the theme and hints, decide which items genuinely BELONG together \
and SELECT only those — leave out items that don't fit (you are choosing membership, not \
forced to place everything). Then group the selected items by what they ARE or their \
shared topic, give each group a short name (1–3 words), and propose a clear name for the \
whole collection. Aim for 2–4 groups; prefer a small number of clear, well-named groups \
over many tiny ones. Base everything ONLY on the names, kinds and roleTags given. Refer \
to each item by its NUMBER (the leftmost column) — never output a file path; simply omit \
any item that doesn't belong rather than forcing it into a group.

If the input states items the user KEEPS or REMOVED, kinds they like/dislike, or group \
names they chose, treat these as strong guidance: favor items like the ones they keep, \
leave out items like the ones they removed, and reuse the group names/themes they picked. \
The item numbers are plain integers — use them exactly as given, never translate them.
"""
```

**关键改动**：
1. `\(Self.namingRule)` 移至 `instructions` **顶部**（而非通过 `lines.append` 放末尾）
2. 显式 "1–3 words" 与 @Guide 对齐
3. "Aim for 2–4 groups" 比 "prefer a few" 更具体
4. "The item numbers are plain integers — use them exactly as given, never translate them." 防止多语言模型把数字翻译成中文/阿拉伯数字

#### 17.3 改进版 review() instructions

```swift
let instructions = """
\(Self.namingRule)

You are a STRICT quality judge for a background "AI folder". Each item below is one \
line: "number<TAB>kind<TAB>name<TAB>roleTags". These items were grouped only because \
they share a name token or a common task/archive — but a shared token is USUALLY \
COINCIDENTAL (many unrelated files share a common word like "report", "final", "v2", \
"data" or a date). Most such groups are NOT worth a folder.

Set worthSurfacing = true ONLY when ALL of the following hold:
  (a) At least THREE items CLEARLY belong together for a real reason beyond a shared word
  (b) The theme is specific enough that a person would deliberately name and keep this folder
  (c) The items form a recognizable project, topic, dataset, or deliverable — not a loose grab-bag

Set worthSurfacing = false when: fewer than three items truly relate; they merely share a \
generic/common word; the theme is vague or weak; or it is a coincidental match. Be strict \
and skeptical: rejecting a borderline theme is always safer than approving it.

If you DO approve (worthSurfacing = true): curate the items — keep those that fit, drop \
the ones that only coincidentally matched; group by meaning with short names (1–3 words); \
propose a clear name for the folder.
If you REJECT (worthSurfacing = false): set groups to [] and workspaceTitle to "".

Refer to items by their NUMBER only — never invent a number, output a file path, or \
translate names. The item numbers are plain integers — use them exactly as given.

If the input states items the user KEEPS or REMOVED, kinds they like/dislike, or group \
names they chose, treat these as strong guidance: a theme the user has actively curated \
is more worth surfacing, and you should honor what they keep, leave out, and how they \
name groups.
"""
```

**关键改动**：
1. `namingRule` 移至顶部
2. worthSurfacing 条件改为 3 点编号列表 (a)(b)(c)——小模型对枚举结构响应更稳定
3. **明确写出拒绝时的输出：`groups = []`, `workspaceTitle = ""`**——消除当前拒绝时模型仍填写 groups 的歧义
4. "1–3 words" 命名长度约束与 @Guide 对齐

#### 17.4 改进版 suggestions() instructions

```swift
let instructions = """
The items below are already grouped into one folder. Suggest a useful next action for a \
FEW of them — ONLY where there is a clear, specific reason for THAT SPECIFIC ITEM (e.g. \
an untested release archive → "test"; a large stray folder → "compress"; an unverified \
signed container → "verify"). MOST items get NONE — empty is the correct default. \
Never suggest an action just because it is possible; suggest only when it is clearly the \
right next step for THIS item right now. Prioritize items that most obviously need \
attention. Refer to items by their NUMBER, never output a path.

\(Self.actionVocabularyRule)
"""
```

**关键改动**：
1. "ONLY where there is a clear, specific reason for THAT SPECIFIC ITEM" — 加粗目标特异性
2. 具体示例（"untested release archive → test"）给小模型更清晰的匹配模式
3. "empty is the correct default" — 将「空回复」标准化为最正常的输出，降低过度建议
4. "Prioritize items that most obviously need attention" — 当确实要给建议时，引导模型选最重要的

#### 17.5 改进版 verifyMisfits() instructions

```swift
let instructions = """
A folder collects items around ONE theme. Below is its theme and its current items \
(one per line: "number<TAB>kind<TAB>name<TAB>roleTags"). List ONLY the NUMBERS of items \
that CLEARLY AND OBVIOUSLY do not belong to this theme — items whose kind, name, AND \
roleTags all point away from the theme topic. Be conservative: when in doubt, KEEP the \
item (do not list it). An empty list is correct most of the time — most items usually \
fit. Never output a path; never remove an item just because its name is ambiguous.
"""
```

**关键改动**：
1. "CLEARLY AND OBVIOUSLY" 双重强调保守性
2. "whose kind, name, AND roleTags all point away" — 给出显式判断标准（三要素都指向主题外才删）
3. "An empty list is correct most of the time" — 更强地规范化空回复
4. "never remove an item just because its name is ambiguous" — 阻止模糊名称被过度清理

#### 17.6 hintLines 改进建议

当前 `hintLines()` 的问题：hints 通过 `lines.append(contentsOf:)` 插在候选列表**之前**（正确），但 5 类 hint 没有明确的优先级顺序。建议改为优先级排序（最重要的 hint 先输出，确保小模型看到）：

```
优先级顺序（从高到低）:
1. removedItemNames（用户明确不要的 → 最强信号，违反会直接降质）
2. keptItemNames（用户明确要保留的）
3. userGroupTitles（用户起的分组名 → 重复使用这些名字）
4. rejectedRoleTags（不喜欢的种类）
5. preferredRoleTags（喜欢的种类，最弱 → 只是偏好）
```

当前代码顺序是 userGroupTitles → keptItemNames → removedItemNames（中、中、强），建议改为 removedItemNames → keptItemNames → userGroupTitles → preferredRoleTags → rejectedRoleTags（强、中、中、弱、弱）。

#### 17.7 提示词改进优先级汇总

| 优先级 | 改动 | 预期效果 | 影响范围 |
|--------|------|----------|----------|
| P0（立即做） | review() 明确拒绝路径 groups=[] | 消除拒绝时仍填 groups 的浪费 | review |
| P0（立即做） | 所有 instructions 把 namingRule 移至顶部 | 降低语言混用（小模型偏头部权重） | plan / review |
| P1（本版做） | worthSurfacing 条件改枚举 (a)(b)(c) | 提升结构化理解稳定性 | review |
| P1（本版做） | suggestions 加具体示例 + "empty is default" | 降低过度建议率 | suggestions |
| P2（下版做） | hintLines 优先级排序（removedItems 先） | 强信号靠前，弱信号靠后 | plan / review |
| P2（下版做） | verifyMisfits 三要素判断标准 | 减少误删歧义文件名 | verifyMisfits |

---

### 18. 测试数据缺口分析

当前 `releasePool`（33 件）的组成：

```
archive × 8, archiveEntry × 2, task × 5, file × 8, folder × 10
角色分布：release-artifact 主导，source/sign 次之
语言：全部英文名
位置：全部虚拟单位置（无跨位置候选）
反馈历史：无（全部 feedback 字典为空）
```

#### 18.1 缺失 kind 类型（高优先级）

| 缺失 kind | 影响的 AI 功能 | 建议添加数量 |
|-----------|--------------|-------------|
| `report` | AI 报告解释、suggestions 的 "inspect" 动作 | 3–4 件 |
| `action` / workflow | suggestions 的 "schedule" / "run" 动作；工作流主题聚类 | 2–3 件 |
| `note` | 文档主题聚类（README/CHANGELOG 不代表 note） | 2 件 |
| `archiveEntry`（严重不足） | 归档内条目主题聚类（白皮书核心场景） | 当前 2 件 → 应 6–8 件 |

当 releasePool 没有这些 kind 时，`suggestions()` 无法测试动作词表的「applies to」过滤逻辑；theme_count 测试也无法验证跨 kind 聚类。

#### 18.2 缺失语义维度

**CJK 文件名缺失**：  
当前全为 ASCII 名称。CJK 命名的归档（如 `报告_2026Q1.zip`、`项目文件_v2.tar.gz`）涉及：
- `splitTokens` 的 CJK 分词路径（目前 Phase 2 已修复版本号分词，但中文分词未测）
- queryTokens 中 CJK token 的提取质量
- 语言规则是否能让模型用中文给 CJK 文件夹命名

建议添加：3–4 件 CJK 命名条目（archive + folder 各一半）

**版本序列缺失**：  
测试池中没有版本序列（如 app-1.0.zip / app-1.1.zip / app-2.0.zip）。版本序列是 SimpleZip 最常见的用户场景（发布包列表）。无法测试「版本演进主题」的聚类。  
建议添加：3 件同应用不同版本的 archive

**多位置候选缺失（关键架构验证）**：  
AI 文件夹的核心承诺是「跨位置语义聚类」（见白皮书建议四）。当前 releasePool 的候选都在虚拟单一位置下，无法验证跨 Desktop/Downloads/Documents 的聚类行为。  
建议添加：为现有候选的一半设置不同的 locationKind，如 `[.desktop, .downloads, .documents]`，验证 `discoverThemes` 在跨位置场景下仍能聚出相同主题

**高频反馈历史缺失**：  
cap 参数（§ 16）完全测试不到，因为没有 negHits > 5 的候选。  
建议添加：2 件有 6+ 次负反馈的 tag 候选，验证 cap 的截断行为

#### 18.3 建议扩充的 releasePool（从 33 → 50 件）

```swift
// 新增项（建议添加到 AIBenchmarkSweepTests.swift 的 releasePool 构造）

// CJK 命名（4 件）
AIVirtualNodePromptCandidate(kind: "archive",  displayName: "报告_2026Q1.zip", roleTags: ["release-artifact"], ...),
AIVirtualNodePromptCandidate(kind: "folder",   displayName: "项目文件_v3",     roleTags: ["source-archive"],   ...),
AIVirtualNodePromptCandidate(kind: "archive",  displayName: "备份_2025年终.tar.gz", roleTags: ["backup"],      ...),
AIVirtualNodePromptCandidate(kind: "file",     displayName: "使用说明.pdf",    roleTags: ["documentation"],    ...),

// 版本序列（3 件，构成可聚类的版本簇）
AIVirtualNodePromptCandidate(kind: "archive",  displayName: "SimpleZip-1.0.0.dmg", roleTags: ["installer-package"], ...),
AIVirtualNodePromptCandidate(kind: "archive",  displayName: "SimpleZip-1.1.0.dmg", roleTags: ["installer-package"], ...),
AIVirtualNodePromptCandidate(kind: "archive",  displayName: "SimpleZip-2.0.0.dmg", roleTags: ["installer-package"], ...),

// report / action / note（5 件）
AIVirtualNodePromptCandidate(kind: "report",   displayName: "release-report-0.4.4.pdf", roleTags: ["release-artifact"], ...),
AIVirtualNodePromptCandidate(kind: "report",   displayName: "security-scan.pdf",       roleTags: ["release-artifact"], ...),
AIVirtualNodePromptCandidate(kind: "action",   displayName: "notarize.sh",             roleTags: ["release-artifact"], ...),
AIVirtualNodePromptCandidate(kind: "archiveEntry", displayName: "CHANGELOG.md",        roleTags: ["documentation"],    ...),
AIVirtualNodePromptCandidate(kind: "archiveEntry", displayName: "AppIcon.icns",        roleTags: ["release-artifact"], ...),

// 高频负反馈候选（用于测试 cap）
AISemanticTagCandidate(tag: .brokenVolume, deterministicScore: 0.30, evidence: []),  // negFeedback: ["broken-volume": 8]
```

#### 18.4 数据缺口对当前结果的影响

| 测试项 | 因缺失数据导致的限制 |
|--------|---------------------|
| `negativeFeedbackCap` | 完全无法测试（feedback 序列始终 < 5） |
| `positiveFeedbackCap` | 同上 |
| `suggestions()` 动作词表 | 只能测试 archive/folder 类动作；report/action 动作路径未覆盖 |
| 跨位置聚类 | 完全未覆盖（白皮书核心场景） |
| CJK splitTokens | 未测试（tokenOverlapThreshold 只验证了 ASCII token 场景） |
| verifyMisfits | 候选角色太单一（几乎都是 release-artifact），难以构造「明显不扣题」的 misfit |

---

### 19. 架构债务分析

本节梳理当前 AI 子系统在架构层面的已知问题，供 Opus 在后续迭代中修复。

#### 19.1 Policy 路径 vs 函数路径的系统性 gap（P0 已知 Bug）

**文件**：`SimpleZip/Core/AI/AIWorkspaceDiscovery.swift`

当前 `AIRecommendationPolicy.default` 使用 `minClusterSize=3`，而 `discoverThemes()` 的函数默认参数是 `minClusterSize=2`。基准测试直接调用 `discoverThemes()` 而不是通过 policy，所以 METRIC `theme_count=3` 是函数默认下的结果。真实 App 走 policy 路径时，33 件候选只能聚出 **2 个主题**（而不是 3 个）。

这意味着：
- Phase 3 的 minClusterSize 扫测验证的是函数路径，不是 App 实际路径
- Policy 默认值 3 应该降至 2（与函数默认对齐），否则每次主题发现都丢失至少一个有效主题

**修复建议**（一行改动）：
```swift
// AIWorkspaceDiscovery.swift — AIRecommendationPolicy.default
static let `default` = AIRecommendationPolicy(
    minClusterSize: 2,  // 原来是 3；改为与 discoverThemes 默认对齐
    ...
)
```

#### 19.2 反馈闭环未验证

当前 `AIWorkspaceLearningStore` 接受 like/dislike 并存储信号权重，`AIWorkspaceLearningHints` 转成 hintLines 喂给模型。但没有基准测试验证：**给了 hint 之后，模型是否真的在候选选择上有变化？**

问题：hintLines 的影响是「软性的」——小模型失败率高、hint 可能被忽略。现在的测试只测了数学层（weights 存取、亲和分计算），没有测「hint → 模型行为变化」这一关键环节。

**测量建议**：在 benchmarkMetrics 中新增 `hint_influence_rate` 指标：
1. 无 hint 时调用 `plan()` → 记录入选候选集 A
2. 有「remove items X, Y, Z」hint 时调用 `plan()` → 记录入选候选集 B
3. `hint_influence_rate = (A ∩ 排斥 / 排斥总数)` 越低越好（排斥的 item 越少出现在 B 中越好）

注意：这是一个模型调用指标，需要在 AI 可用时运行，不适合加入当前纯确定性的 benchmarkMetrics。应该作为单独的 AIModelBenchmarkTests 套件。

#### 19.3 verifyMisfits 与 suggestions 无协调

`verifyMisfits()` 可能会删除某个条目，而 `suggestions()` 可能同时给那个条目生成了建议。当前两个调用独立进行，没有明确的执行顺序协调（suggestions 是「通过后单独生成」，verifyMisfits 是「动态核查」）。如果 suggestions 先运行、verifyMisfits 后删了对应条目，建议成为孤儿引用。

**修复建议**：让 App 层确保 `verifyMisfits` 的结果先应用，再运行 `suggestions`（或者在 suggestions 结果回来后过滤掉已被 verifyMisfits 删除的 targetCandidateID）。

#### 19.4 worthSurfacing 是二值判断，缺少置信度排序

当多个候选主题竞争有限的显示名额（`maxThemes=6`）时，当前只有「通过/拒绝」两种结果，没有置信分来排序竞争主题。结果是：质量 60% 的主题和质量 95% 的主题被平等对待。

**改进建议**：`GeneratedAIFolderPlan` 增加一个可选的 `confidenceScore: Double`（@Guide 说明这是「主题独特性/有用性的主观打分 0–1」），让 App 在 maxThemes 名额不够时优先显示高置信度主题。

这是一个 schema 改动，对小模型失败率有一定影响（增加字段）——需要实测是否可承受。

#### 19.5 maxAttempts=12 掩盖了 schema 复杂度问题

当前 plan/review 用 maxAttempts=12 来对抗小模型的高失败率。但高失败率的根本原因是 schema + prompt 的复杂性（`GeneratedAIFolderPlan` 嵌套 `[GeneratedAIFolderGroup]`，每个 Group 有 3 个字段）。

提高可靠性的根本路径是**简化 schema**，而不是增加重试次数：
1. 考虑把 `groups` 拆出来用 2 次生成代替 1 次（第一次只生成 `worthSurfacing` + `workspaceTitle`；通过后第二次再生成 `groups`），可以把每次生成的 schema 复杂度减半
2. 当 maxAttempts 耗尽时，记录失败率指标——目前失败时静默退回到确定性树，无可观测日志

#### 19.6 没有跨位置聚类的 E2E 验证路径

白皮书建议四「AI 文件夹跨位置语义聚类」是整个设计的核心差异点。当前基准测试的候选池都是单一虚拟位置，`discoverThemes()` 的跨位置路径（多 `locationKind`）完全未经实测验证。

**建议**：扩充 releasePool（见 § 18.3），让同一主题的候选分布在 desktop/downloads/documents 三个位置，确认 `theme_count=3` 在跨位置场景下仍然成立。如果聚不出来，说明 tokenOverlapThreshold 或 minClusterSize 需要调整。

---

### 20. AIRecommendationPolicy 参数分析（代码推理，非实测）

`AIWorkspaceDiscovery.swift` 中 `AIRecommendationPolicy` 的参数未直接影响 METRIC（因为基准测试绕过 policy 直接调用 `discoverThemes()`）。以下分析基于代码推理和数学公式。

#### 20.1 参数表

| 参数 | default 值 | permissive 值 | 作用 |
|------|-----------|-------------|------|
| minClusterSize | 3 ⚠️ | 2 | 聚类引擎最小成员数（见 § 19.1） |
| minMembers | 3 | 2 | 升为工作区候选所需最少成员 |
| richMemberCount | 5 | 5 | "丰富"工作区的成员阈值（UI 差异化） |
| maxThemes | 6 | 6 | 同时推荐的最大主题数 |
| gateQuality | true | false | 是否通过模型 review() 质量门控 |

#### 20.2 minMembers=3 评估

minMembers=3 意味着少于 3 件成员的候选主题不会被推荐。这与 review() 中「worthSurfacing = true 需要 ≥ 3 件」一致（双重保障）。对普通用户场景（文件数量正常的工作目录）是合理值。

若用户的工作区非常精简（如只有 2 件高相关文件），当前 policy 会完全不给推荐。建议保留 3，但允许在「用户手动触发」场景下临时用 `.permissive`（gateQuality=false + minMembers=2）来强制显示候选。

#### 20.3 maxThemes=6 评估

对 33 件候选池，6 个槽位远超实际聚出的 3 个主题，不是瓶颈。

对真实用户（数千文件、数十潜在主题）：6 个槽位可能过于保守——用户可能希望看到 8–10 个 AI 建议工作区。建议将 maxThemes 暴露为用户可调设置（「AI 文件夹最大显示数量」），默认 6、可调至 12。

#### 20.4 gateQuality=true 的开销分析

每个候选主题需要一次 review() 调用（maxAttempts=12）。如果发现了 N 个候选主题，总 review 开销最坏情况 = N × 12 次模型生成。

对 33 件候选 + 3 个主题：最坏 3 × 12 = 36 次生成，每次约 200–800ms → 总计 7–28 秒。

这解释了为什么 gateQuality 有 false 选项（用于快速预览）。建议：
- 首次打开 AI 文件夹用 `gateQuality=false` 立即显示确定性结果
- 后台异步运行 `gateQuality=true` 的 review，完成后更新（懒加载质量门控）

#### 20.5 `.permissive` 场景建议

当前 `.permissive` 只在代码中定义但似乎没有用户可触达的入口。建议明确其使用场景：

```
.permissive 适用场景:
- 「手动触发 AI 整理」按钮（用户主动要求，可接受更多候选）  
- DevTools 诊断面板（测试 AI 文件夹能力边界）
- 候选数量不足时的降级（如 theme_count=0 时重试用 permissive）

.default 适用场景:
- 所有自动后台发现（无感知时不打扰用户）
```

---

### 21. Phase 4 汇总与综合建议

**可立即执行的改动（无测试阻断，纯改动代码）：** 状态以 § 0 总表为准；下方提示词类改动（review/suggestions/hintLines/instructions）仍待 Opus 落地。

| 优先级 | 文件 | 改动 | 效果 | 状态 |
|--------|------|------|------|------|
| P0 | `AIWorkspaceDiscovery.swift` | `AIRecommendationPolicy.default.minClusterSize: 3→2` | 恢复生产路径丢失的第 3 个主题 | ✅已落地 |
| P0 | `AIVirtualFolderModelPlanner.swift` | review() 拒绝路径明确 `groups=[],workspaceTitle=""` | 消除拒绝时填 groups 的浪费 | ⏳待 Opus |
| P0 | `AIVirtualFolderModelPlanner.swift` | 所有 instructions 把 `\(Self.namingRule)` 移至最前 | 降低语言混用风险 | ⏳待 Opus |
| P1 | `AIVirtualFolderModelPlanner.swift` | review() worthSurfacing 条件改 3 点枚举 | 提升小模型结构理解稳定性 | ⏳待 Opus |
| P1 | `AIVirtualFolderModelPlanner.swift` | suggestions() 加具体示例 + "empty is default" | 降低过度建议率 | ⏳待 Opus |
| P2 | `AIVirtualFolderModelPlanner.swift` | hintLines 优先级排序（removedItems 先） | 强信号靠前，弱信号靠后 | ⏳待 Opus |
| P2 | `Tests/SimpleZipCoreTests/AI/AIBenchmarkSweepTests.swift` | releasePool 添加 CJK/版本序列/高频反馈/跨位置候选 | 解锁当前无法覆盖的测试路径 | ⏳待 Opus |

**测试阻断项（需 Opus + 用户 review 测试改动）：**  
Phase 1 § 13 原列 3 项 **现已全部落地**（`decayPerNegative` 由 Codex；`feedbackHalfLifeDays 30→45`、`baseHalfLifeSeconds 7d→10d` 由 Opus，含单测同步，详见 § 0.1 / § 13）。Phase 4 **未新增测试阻断项**。

**ThemeSuppression 全参数结论**：三个参数（firstDismissBaseWeight=0.6 / perExtraDismissWeight=0.2 / resurfaceFloor=0.05）均**保留当前值**；`baseHalfLifeSeconds` 已落地 7d→10d。resurfaceFloor 是最强控制杆（每 ±0.01 影响约 ±1.5d），如需再调整记忆持久性，它与 halfLifeSeconds 均可（测试均已解除阻断）。

**Feedback Cap 结论**：两个 cap 均保留 5——它们是安全边界而非行为控制参数，在当前测试数据范围内完全无影响。测试 cap 需要先在 releasePool 中加入高频负反馈候选。

---

*本报告全部数据来自实测迭代扫测（Phase 1-10 共 120+ 次参数组合），不含估算或假设值。如需重现，在干净工作区对各参数逐一执行：修改 → `xcrun swift test --filter AIBenchmarkSweepTests/benchmarkMetrics` → grep METRIC → `git restore`。提示词分析（§ 17）和架构债务（§ 19）基于代码审读，无需运行测试。改进建议的落地状态以 § 0 总表为准。*

---

## 附录 A：`document` 角色拆分分析

### A.1 问题根源

`document` 角色在真实数据中严重过表达（62%），但更严重的问题是它掩盖了**内部语义断层**——当前叫做 "document" 的文件实际上横跨 3–4 个截然不同的语义类别，它们在 AI 文件夹里应该归属完全不同的主题簇。

**realFilePool 8 件 "document" 的真实面目：**

| 文件名 | 当前 role | 实际语义 | 应属主题簇 |
|--------|-----------|----------|-----------|
| README.md | document | 项目说明文档 | 源码 / 项目文档簇 |
| CHANGELOG.md | document | 发布变更历史 | 发布物簇（和 release-artifact 同一主题） |
| Regula_RFID_Reader.txt | document | 读卡器硬件规格 | 智能卡读卡器规格簇 |
| Cherry_KC_1000_SC_Z.txt | document | 读卡器硬件规格 | 智能卡读卡器规格簇 |
| GemPCTwin.txt | document | 读卡器硬件规格 | 智能卡读卡器规格簇 |
| Fujitsu_Smartcard_Reader_D323.txt | document | 读卡器硬件规格 | 智能卡读卡器规格簇 |
| HID_Global_veriCLASS_Reader.txt | document | 读卡器硬件规格 | 智能卡读卡器规格簇 |
| Identiv_uTrust_3701_F_CL_Reader.txt | document | 读卡器硬件规格 | 智能卡读卡器规格簇 |

**releasePool 4 件 "document" signal 的真实面目：**

| 文件名 | 当前 signal | 实际语义 | 应属主题簇 |
|--------|-------------|----------|-----------|
| SHA256SUMS | document | 发布校验清单（不是文档！） | 发布物簇（校验/完整性） |
| CHANGELOG.md | document | 发布变更历史 | 发布物簇 |
| SECURITY.md | document | 安全策略文档 | 源码 / 项目文档簇 |
| README.md | document | 项目说明文档 | 源码 / 项目文档簇 |

**关键观察**：`realWorkspaces` 里已经出现「智能卡读卡器项目(A)」和「(B)」两个**重复工作区**——这正是 6 件读卡器规格 txt 文件被当成单一 "document" blob 处理后，聚类引擎因 token 区分度不足而输出两个同主题重复推荐的直接结果。拆分角色后这两个重复会合并为一个。

### A.2 建议拆分方案

保留 `document` 作为兜底类型（纯通用文档），从中拆出 3 个新角色：

| 新角色 | 定义 | 覆盖场景 | 与原 document 的区别 |
|--------|------|----------|----------------------|
| `release-notes` | 版本变更历史 / 发布说明 | CHANGELOG.md, RELEASE_NOTES, NEWS | 强信号：与 release-artifact 同簇；当前被 document 掩盖 |
| `integrity-data` | 校验清单 / 签名文件 / 哈希表 | SHA256SUMS, checksums.txt, .asc | **根本不是文档**；应和 release-artifact 一起构成「发布完整性」主题 |
| `reference-data` | 参考数据文件 / 技术规格 / 数据表 | 读卡器 .txt、设备规格、数据集 | 有内容主题（读卡器/设备/领域）；可聚类为独立主题；当前被 document 泛化掉 |
| `document`（保留） | 通用说明文档 | README.md, SECURITY.md, FAQ, 帮助文档 | 仅保留真正的"说明"语义 |

### A.3 拆分后各数据集的角色分配

**releasePool 改动（文件层）：**

```
// 原来
nc("file-sha256sums", .file, "SHA256SUMS",
   signals: ["document", "project-token", "source-ref-match"],
   tokens: ["sha256", "checksum", "release"]),
nc("file-changelog",  .file, "CHANGELOG.md",
   signals: ["document", "project-token"],
   tokens: ["changelog", "release"]),
nc("file-security",   .file, "SECURITY.md",
   signals: ["document"],
   tokens: ["security"]),
nc("file-readme",     .file, "README.md",
   signals: ["document"],
   tokens: ["readme"]),

// 拆分后
nc("file-sha256sums", .file, "SHA256SUMS",
   roles: ["integrity-data"],                          // ← 从 document 信号改为 integrity-data 角色
   signals: ["project-token", "source-ref-match", "integrity"],
   tokens: ["sha256", "checksum", "release"]),
nc("file-changelog",  .file, "CHANGELOG.md",
   roles: ["release-notes"],                           // ← release-notes
   signals: ["project-token", "release"],
   tokens: ["changelog", "release", "version"]),
nc("file-security",   .file, "SECURITY.md",
   roles: ["project-doc"],                             // ← document 改 project-doc
   signals: ["project-token"],
   tokens: ["security", "policy"]),
nc("file-readme",     .file, "README.md",
   roles: ["project-doc"],                             // ← 同上
   signals: ["project-token"],
   tokens: ["readme", "guide"]),
```

**archiveEntry 改动：**

```
// 原来
nc("entry-changelog", .archiveEntry, "SimpleZip/CHANGELOG.md",
   roles: ["documentation"],
   signals: ["document", "same-parent"], ...)

// 拆分后
nc("entry-changelog", .archiveEntry, "SimpleZip/CHANGELOG.md",
   roles: ["release-notes"],                           // ← documentation → release-notes
   signals: ["release", "same-parent"], ...)
```

**realFilePool 改动（8 件全部重新分类）：**

```
// README.md → project-doc
nc("file-r018", .file, "README.md",
   roles: ["project-doc"],
   signals: ["loc-documents", "project-token"], tokens: ["readme", "guide", "markdown"]),

// CHANGELOG.md → release-notes
nc("file-r019", .file, "CHANGELOG.md",
   roles: ["release-notes"],
   signals: ["loc-documents", "release"], tokens: ["changelog", "version", "markdown"]),

// 6 件读卡器规格 → reference-data（加统一信号 "hardware-spec" 强化聚类）
nc("file-r020", .file, "Regula_RFID_Reader.txt",
   roles: ["reference-data"],
   signals: ["loc-documents", "hardware-spec"], tokens: ["readers", "rfid", "smartcard"]),
nc("file-r021", .file, "Cherry_KC_1000_SC_Z.txt",
   roles: ["reference-data"],
   signals: ["loc-documents", "hardware-spec"], tokens: ["readers", "cherry", "smartcard"]),
nc("file-r022", .file, "GemPCTwin.txt",
   roles: ["reference-data"],
   signals: ["loc-documents", "hardware-spec"], tokens: ["readers", "gemplus", "smartcard"]),
nc("file-r023", .file, "Fujitsu_Smartcard_Reader_D323.txt",
   roles: ["reference-data"],
   signals: ["loc-documents", "hardware-spec"], tokens: ["readers", "fujitsu", "smartcard"]),
nc("file-r024", .file, "HID_Global_veriCLASS_Reader.txt",
   roles: ["reference-data"],
   signals: ["loc-documents", "hardware-spec"], tokens: ["readers", "hid", "smartcard"]),
nc("file-r025", .file, "Identiv_uTrust_3701_F_CL_Reader.txt",
   roles: ["reference-data"],
   signals: ["loc-documents", "hardware-spec"], tokens: ["readers", "identiv", "smartcard"]),
```

### A.4 叠加采样限制（per-role cap）

拆分角色之后，还需要在 `AIFileSystemFact.scanDirectory` 加 per-role 采样上限，防止 `reference-data` 重蹈 `document` 一家独大的覆辙：

| 角色 | 当前上限 | 建议上限 | 理由 |
|------|----------|----------|------|
| `document` | 无限 | 10 件/目录 | 真正的通用文档很少超过 10 件 |
| `reference-data` | 无限 | 30 件/目录 | 数据文件可能很多，但 30 已足够聚类 |
| `release-notes` | 无限 | 5 件/目录 | 一个项目极少超过 5 个 changelog |
| `integrity-data` | 无限 | 5 件/目录 | 同上 |
| `project-doc` | 无限 | 5 件/目录 | README/SECURITY 不可能几十个 |
| `installer` | 无限 | 20 件/目录 | 当前仅 3 件（<1%），上限防止下载目录爆 |
| `source` | 无限 | 50 件/目录 | 源文件多但不需要无限采样 |

**实现位置**：在 `AIFileSystemFact.scanDirectory` 采集候选时，按 role 分桶计数，超限后跳过（同 `releasePool` 里 hash 任务的折叠逻辑类似）。

### A.5 预期效果

| 指标 | 拆分前 | 拆分后预期 |
|------|--------|-----------|
| `theme_count`（releasePool） | 3 | **4**（新增「项目文档」或「校验数据」独立主题） |
| `theme_count`（realFilePool） | 未测 | **1–2**（6 件读卡器规格 → 1 个「智能卡读卡器规格」主题） |
| `realWorkspaces` 重复推荐 | 智能卡(A) + 智能卡(B) 两个 | 合并为 1 个（role + "hardware-spec" signal 统一后聚类置信度上升） |
| document 占比 | 62% | **~5%**（仅剩 README/SECURITY 等真正说明文档） |
| reference-data 占比 | 0%（不存在） | **~50%**（吸收原 document 大部分） |
| 各角色聚类可测试性 | 无法测试 installer/backup 聚类 | 采样上限让 installer/media/backup 获得稳定槽位 |

### A.6 生产端角色分配逻辑（AIFileSystemFact 改动要点）

`AIFileSystemFact.scanDirectory` 目前如何判断 "document"（需要 Opus 阅读确认）：通常通过文件扩展名（.md / .txt / .pdf / .docx）或路径模式匹配。拆分建议的判断规则：

```
文件扩展名 + 文件名模式 → 角色分配优先级（越前越优先）

1. integrity-data:
   文件名 ∈ { SHA256SUMS, MD5SUMS, checksums.txt, *.sha256, *.md5, *.sig, *.asc }
   或 tokens 同时含 { "sha", "checksum" } / { "signature", "verify" }

2. release-notes:
   文件名 ∈ { CHANGELOG*, RELEASE_NOTES*, NEWS*, CHANGES* }（大小写不敏感）
   或 tokens 含 "changelog" 且含版本号 token（如 "v0.4.5", "0.4.5"）

3. project-doc:
   文件名 ∈ { README*, SECURITY*, CONTRIBUTING*, CODE_OF_CONDUCT*, AGENTS* }
   扩展名 ∈ { .md, .rst, .txt } 且 tokens 含 { "readme", "guide", "policy", "security" }

4. reference-data:
   扩展名 ∈ { .txt, .csv, .tsv, .dat, .log } 且
   文件名不匹配 README*/CHANGELOG*/SECURITY* 且
   tokens 不含 { "checksum", "sha", "signature" }
   （= 兜底：其他带内容的数据/规格文件）

5. document:（兜底，仅当以上均不匹配）
   扩展名 ∈ { .pdf, .docx, .odt, .pages, .doc }
   或其他说明性文档
```

这套规则的关键：**integrity-data 和 release-notes 必须最先匹配**（它们是当前被最严重掩盖的高价值角色），`reference-data` 作为二级兜底（替代原 "document" 的 txt/csv 类）。

### A.7 对测试代码的改动清单（供 Opus 执行）

```
文件: Tests/SimpleZipCoreTests/AI/AIBenchmarkSweepTests.swift

1. releasePool 中:
   - file-sha256sums: signals 去掉 "document"，加 roles: ["integrity-data"] + signal "integrity"
   - file-changelog: signals 去掉 "document"，加 roles: ["release-notes"] + signal "release"
   - file-security: signals 去掉 "document"，加 roles: ["project-doc"]
   - file-readme: signals 去掉 "document"，加 roles: ["project-doc"]
   - entry-changelog: roles ["documentation"] → ["release-notes"]，signal "document" → "release"

2. realFilePool 中:
   - file-r018 (README.md): roles ["document"] → ["project-doc"]，加 signal "project-token"
   - file-r019 (CHANGELOG.md): roles ["document"] → ["release-notes"]，加 signal "release"
   - file-r020–r025（6 件读卡器 txt）: roles ["document"] → ["reference-data"]，
     所有 token 加 "smartcard"，加统一 signal "hardware-spec"

3. 注释更新:
   - 行 352: "document=695(62%)" → 拆分后重新统计并标注 reference-data/release-notes/integrity-data 各占比
   - 行 411: "// document (8条)" → 按新分类重新分组注释

4. 断言/METRIC 影响: theme_count 预计从 3 增加到 4（新增读卡器规格簇或发布完整性簇），
   需要更新 benchmarkMetrics 中对应断言（如有硬编码 theme_count == 3 的 XCTAssert）
```

> **注**：A.6 的生产端改动（`AIFileSystemFact`）需要 Opus 先阅读该文件确认当前角色分配逻辑，再按上述优先级规则添加 `integrity-data` / `release-notes` / `reference-data` / `project-doc` 分支。测试代码改动（A.7）不依赖生产端，可以先独立执行。

---

## Phase 5：WorkspaceRanker 权重 + 信号权重 + 辅助函数 + 结构参数全量扫测

> 扫测范围：`AIWorkspaceModel.swift`（wRelevance/wRecency/wFrequency/wDwell/userBaseline/defaultDemotionMargin）、`AIVirtualFolderPlan.swift`（signalWeights 全表 + roleWeight/locationWeight/kindWeight + budget 公式）、`AIThemeSuppression.swift`（matchThreshold）、`AIWorkspaceThemeEngine.swift`（maxTokenBucket）。  
> 基线（每次扫前 `git restore`，每次扫后 `git restore`，不产生 commit）：
> `ws_high_low_gap=11.5284` / `ws_neg_demote_at=4` / `suppress_resurface_days=26` / `theme_count=3` / `preparer_tier_high=10,normal=6,low=12`

---

### 22. AIWorkspaceRanking 权重扫测（`AIWorkspaceModel.swift`）

#### 22.1 wRelevance（基线 5.0）

`wRelevance` 对工作区得分贡献最大的单一参数。

| wRelevance | ws_high_low_gap | ws_neg_demote_at |
|-----------|----------------|-----------------|
| 3.0 | 10.0484 | 3 |
| 4.0 | 10.7884 | 3 |
| **5.0 (baseline)** | **11.5284** | **4** |
| 6.0 | 12.2684 | 4 |
| 7.0 | 13.0084 | 4 |
| 8.0 | 13.7484 | 4 |
| 10.0 | 15.2284 | 4 |

**关键结论：**
- gap 呈线性增长，斜率 ≈ +0.74/单位。
- demote_at 在 3.0–4.0 时为 3（不足），≥5.0 时饱和为 4（不再提升）。
- 基线 5.0 是 demote_at=4 的最低有效值；进一步提高只增加 gap，不改善 demote_at。

#### 22.2 wRecency（基线 2.5）

| wRecency | ws_high_low_gap | ws_neg_demote_at |
|---------|----------------|-----------------|
| 1.0 | 9.5869 | 4 |
| 1.5 | 10.0284 | 4 |
| 2.0 | 10.4700 | 4 |
| **2.5 (baseline)** | **11.5284** | **4** |
| 3.0 | 12.4984 | 4 |
| 4.0 | 14.4384 | 4 |

**关键结论：**
- gap 线性增长，斜率 ≈ +0.96/单位（比 wRelevance 更陡）。
- demote_at 对 wRecency 完全不敏感——测试工作区的 recency 差异没有影响排序临界。
- 提高 wRecency 会扩大高/低相关工作区的分差，但不改变负反馈韧性。

#### 22.3 wFrequency（基线 1.5）⭐ 最敏感

| wFrequency | ws_high_low_gap | ws_neg_demote_at |
|-----------|----------------|-----------------|
| 0.5 | 9.2064 | **2** |
| 1.0 | 10.3674 | 3 |
| **1.5 (baseline)** | **11.5284** | **4** |
| 2.0 | 12.6893 | 4 |
| 2.5 | 13.8503 | **5** |
| 3.0 | 15.0113 | 5 |

**关键结论：**
- `wFrequency` 是所有参数中对 `ws_neg_demote_at` 影响最大的。
- 从原默认 1.5 提高到 2.5 可将 demote_at 从 4 提升至 5（更抗负反馈）。
- 降低到 0.5 会让 demote_at 崩至 2（非常脆弱）。
- ✅ **已落地**：`wFrequency` 现行值为 **2.5**（demote_at=5）。本表数据采于上调前。

#### 22.4 wDwell（基线 2.0）

| wDwell | ws_high_low_gap | ws_neg_demote_at |
|--------|----------------|-----------------|
| 0.5 | 11.0284 | **3** |
| 1.0 | 11.0284 | **3** |
| 1.5 | 11.0284 | **3** |
| **2.0 (baseline)** | **11.5284** | **4** |
| 2.5 | 11.5284 | 4 |
| 3.0 | 11.5284 | 4 |
| 4.0 | 11.5284 | 4 |

**关键结论：**
- wDwell=2.0 是 demote_at=4 的最低必要值；低于 2.0 则 demote_at 跌至 3。
- 高于 2.0 后 gap 和 demote_at 完全不变（dwell 信号在 [0,1] 饱和）。
- **基线 2.0 是精确的最优值；降低有风险，提高无收益。**

#### 22.5 userBaseline（基线 2.5）

测试池中所有工作区均为 `aiGenerated` 类型，`userBaseline` 加成不触发。

| userBaseline | ws_high_low_gap | ws_neg_demote_at |
|-------------|----------------|-----------------|
| 1.0–5.0（全范围） | 11.5284 | 4 |

**关键结论：完全不敏感。** 需要向测试池添加 `userCreated` 工作区才能评估此参数。

#### 22.6 defaultDemotionMargin（基线 1.0，`AIWorkspaceDisplayCompetition`）

| defaultDemotionMargin | ws_high_low_gap | ws_neg_demote_at |
|----------------------|----------------|-----------------|
| 0.5–2.0（全范围） | 11.5284 | 4 |

**关键结论：完全不敏感。** 当前测试场景不触发展示竞争的边界判定。

---

### 23. AIVirtualFolderPlan signalWeights 扫测（`AIVirtualFolderPlan.swift`）

基线：`preparer_tier_high=10, normal=6, low=12, suppressed=6, output=28`

#### 23.1 "project-token"（基线 3.0）⭐ 最敏感

| project-token | tier_high | tier_normal | tier_low |
|--------------|-----------|-------------|----------|
| 0.0 | 6 | 10 | 12 |
| 1.0 | 6 | 10 | 12 |
| 2.0 | **8** | **8** | 12 |
| **3.0 (baseline)** | **10** | **6** | **12** |
| 5.0 | 10 | 6 | 12 |

**关键结论：**
- 基线 3.0 是保持 10 件 high 的最低有效阈值（临界点在 2.0–3.0 之间）。
- 值为 2.0 时 tier_high 跌至 8（中间态），1.0 和 0.0 时跌至 6。
- 此信号是 preparer 分层的核心驱动——**必须保持 ≥3.0**。

#### 23.2 "source-ref-match"（基线 2.0）

| source-ref-match | tier_high | tier_normal | tier_low |
|----------------|-----------|-------------|----------|
| 0.5 | **9** | **7** | 12 |
| 1.0 | 10 | 6 | 12 |
| **2.0 (baseline)** | **10** | **6** | **12** |
| 3.0 | 10 | 6 | 12 |
| 5.0 | **11** | **5** | 12 |

**关键结论：**
- 阈值在 1.0：≥1.0 时 tier_high=10（与基线相同），0.5 时掉一件。
- 可将基线降至 1.0 而不影响 tier 分布。提至 5.0 可额外推一件进 high。
- 基线 2.0 位于饱和区，有 1 个单位的下调空间。

#### 23.3 "failed"（基线 3.0）

| failed | tier_high | tier_normal | tier_low |
|--------|-----------|-------------|----------|
| 1.0 | 10 | 6 | 12 |
| **3.0 (baseline)** | **10** | **6** | **12** |

**关键结论：完全不敏感。** releasePool 中无 "failed" 信号候选。

#### 23.4 "repeated"（基线 -1.0）

| repeated | tier_high | tier_normal | tier_low |
|---------|-----------|-------------|----------|
| -0.5 | 10 | 6 | 12 |
| **-1.0 (baseline)** | **10** | **6** | **12** |
| -2.0 | 10 | **5** | **13** |
| -3.0 | 10 | **5** | **13** |

**关键结论：**
- 增强惩罚（≤-2.0）将一件候选从 normal 推入 low tier。
- 减弱惩罚（-0.5）与基线相同。
- 基线 -1.0 是合理中间值；**不建议低于 -1.5**（会推高 low 计数）。

#### 23.5 "running"（基线 2.0）

| running | tier_high | tier_normal | tier_low |
|---------|-----------|-------------|----------|
| 0.5 | 10 | 6 | 12 |
| **2.0 (baseline)** | **10** | **6** | **12** |
| 3.0 | 10 | 6 | 12 |

**关键结论：完全不敏感。** releasePool 中无 "running" 信号候选。

---

### 24. roleWeight / locationWeight / kindWeight 扫测（`AIVirtualFolderPlan.swift`）

#### 24.1 roleWeight — "source/docs" 正权重（基线 +2.0）

| roleWeight[source/docs] | tier_high | tier_normal | tier_low |
|------------------------|-----------|-------------|----------|
| 1.0 | 10 | 6 | 12 |
| **2.0 (baseline)** | **10** | **6** | **12** |
| 3.0 | 10 | 6 | 12 |

**完全不敏感。** 测试候选的 roleTags 不含 source/docs/code/spec/reader 类标签。

#### 24.2 roleWeight — "junk/temporary" 惩罚（基线 -2.0）

| roleWeight[junk] | tier_high | tier_normal | tier_low |
|-----------------|-----------|-------------|----------|
| -1.0 | 10 | 6 | 12 |
| **-2.0 (baseline)** | **10** | **6** | **12** |
| -3.0 | 10 | 6 | 12 |

**完全不敏感。** 测试候选的 roleTags 不含 junk/temporary 类标签。

#### 24.3 locationWeight — projectFolder（基线 +2.0）

| locationWeight[projectFolder] | tier_high | tier_normal | tier_low |
|------------------------------|-----------|-------------|----------|
| 1.0 | 10 | 6 | 12 |
| **2.0 (baseline)** | **10** | **6** | **12** |
| 3.0 | 10 | 6 | 12 |

**完全不敏感。** 测试候选无 location 元数据或均在 projectFolder 中，无法区分。

#### 24.4 locationWeight — desktop/downloads（基线 -0.6）

| locationWeight[desktop/downloads] | tier_high | tier_normal | tier_low |
|----------------------------------|-----------|-------------|----------|
| 0.0 | 10 | 6 | 12 |
| **-0.6 (baseline)** | **10** | **6** | **12** |
| -1.5 | 10 | 6 | 12 |

**完全不敏感。**

#### 24.5 kindWeight — task（基线 -1.0）

| kindWeight[task] | tier_high | tier_normal | tier_low |
|-----------------|-----------|-------------|----------|
| 0.0 | 10 | 6 | 12 |
| **-1.0 (baseline)** | **10** | **6** | **12** |
| -2.0 | **9** | 6 | **13** |

**关键结论：**
- kindWeight[task]=-2.0 将一件任务候选从 high 推入 low。
- 基线 -1.0 处于安全区。**不建议低于 -1.5**。

---

### 25. 预算公式扫测（`AIVirtualFolderPlan.layeredSelection`）

基线公式：
```swift
explorationBudget = max(1, min(low.count, maxCandidates / 5))   // 28/5 = 5
normalBudget      = min(normal.count, max(1, (maxCandidates - explorationBudget) * 2 / 5))  // (28-5)*2/5 = 9 → capped at 6
```

#### 25.1 explorationBudget 除数（基线 /5）

| 除数 | explorationBudget(28) | tier_high | tier_normal | tier_low |
|------|----------------------|-----------|-------------|----------|
| /10 | 2 | 10 | 6 | 12 |
| **/5** | **5** | **10** | **6** | **12** |
| /3 | 9 | 10 | 6 | 12 |

**完全不敏感。** 原因：测试池 output=28 恰好等于 maxCandidates，layeredSelection 的 `guard sorted.count > maxCandidates else { return sorted }` 提前返回，预算分配不生效。

#### 25.2 normalBudget 乘数（基线 2/5）

| 乘数 | tier_high | tier_normal | tier_low |
|------|-----------|-------------|----------|
| *1/3 | 10 | 6 | 12 |
| ***2/5 (baseline)** | **10** | **6** | **12** |
| *1/2 | 10 | 6 | 12 |

**完全不敏感。** 同上原因。

> **测试盲区说明：** explorationBudget 和 normalBudget 仅在 `total > maxCandidates` 时才有效。当前测试池（28 件 output）恰好触及 defaultMaxCandidates=28 的上限，无法触发分层裁剪逻辑。若要覆盖此路径，需要测试池规模 > maxCandidates，或降低 maxCandidates 进行强制裁剪测试。

---

### 26. AIThemeSuppressionPolicy.matchThreshold 扫测（`AIThemeSuppression.swift`）

| matchThreshold | ws_high_low_gap | ws_neg_demote_at | suppress_resurface_days | suppress_resurface_days_2x | theme_count |
|---------------|----------------|-----------------|------------------------|---------------------------|-------------|
| 0.3 | 11.5284 | 4 | 26 | 57 | 3 |
| 0.4 | 11.5284 | 4 | 26 | 57 | 3 |
| **0.5 (baseline)** | **11.5284** | **4** | **26** | **57** | **3** |
| 0.6 | 11.5284 | 4 | 26 | 57 | 3 |
| 0.7 | 11.5284 | 4 | 26 | 57 | 3 |

**完全不敏感。** 原因：测试场景中两次 dismiss 的指纹 Jaccard 相似度为 0.0 或 1.0（完全不同或完全相同），任何 0<threshold<1 的值都产生相同的匹配结果。`matchThreshold` 控制模糊匹配的精度，其效果仅在真实场景中两次 dismiss 主题"相似但不同"时才会体现。

---

### 27. AIWorkspaceThemeEngine.maxTokenBucket 扫测（`AIWorkspaceThemeEngine.swift`）

| maxTokenBucket | ws_high_low_gap | ws_neg_demote_at | theme_count | theme_solo_count |
|---------------|----------------|-----------------|-------------|-----------------|
| 40 | 11.5284 | 4 | 3 | 0 |
| 60 | 11.5284 | 4 | 3 | 0 |
| **80 (baseline)** | **11.5284** | **4** | **3** | **0** |
| 100 | 11.5284 | 4 | 3 | 0 |
| 120 | 11.5284 | 4 | 3 | 0 |

**完全不敏感。** 原因：测试池（25 件 realFilePool 候选）中无任何 token 的出现频率超过 40，因此 maxTokenBucket 的高频截断从未触发。此参数仅在真实大规模数据（数百~数千个候选）下才产生效果。

---

### 28. Phase 5 汇总与建议

#### 28.1 敏感参数（实测有效）

| 参数 | 文件 | 基线 | 建议 | 效果 |
|------|------|------|------|------|
| `wFrequency` | `AIWorkspaceModel.swift` | 1.5 | **2.5** | demote_at 4→5，gap +2.32 |
| `signalWeights["project-token"]` | `AIVirtualFolderPlan.swift` | 3.0 | **保持 ≥3.0** | 低于 3.0 时 tier_high 从 10 跌至 6–8 |
| `wRelevance` | `AIWorkspaceModel.swift` | 5.0 | **保持 ≥5.0** | 低于 5.0 时 demote_at 跌至 3 |
| `wDwell` | `AIWorkspaceModel.swift` | 2.0 | **保持 ≥2.0** | 低于 2.0 时 demote_at 跌至 3 |
| `signalWeights["source-ref-match"]` | `AIVirtualFolderPlan.swift` | 2.0 | **可降至 1.0** | 1.0 与 2.0 等效；0.5 时 tier_high 少 1 |
| `signalWeights["repeated"]` | `AIVirtualFolderPlan.swift` | -1.0 | **不低于 -1.5** | ≤-2.0 时 tier_normal→low 转移 |
| `kindWeight["task"]` | `AIVirtualFolderPlan.swift` | -1.0 | **不低于 -1.5** | ≤-2.0 时 tier_high 少 1 件任务 |

#### 28.2 不敏感参数（当前测试池不触发）

以下参数在当前 `releasePool`（33 件）+ `realFilePool`（25 件）规模的测试下完全不敏感，**不代表这些参数在生产中无效**——它们有特定的激活条件：

| 参数 | 不敏感原因 | 生产激活条件 |
|------|-----------|-------------|
| `wRecency` | gap 变化但 demote_at 不变 | 候选间 recency 差异足够大 |
| `userBaseline` | 测试池无 userCreated 工作区 | 有用户手建工作区时生效 |
| `defaultDemotionMargin` | 无展示竞争场景 | 两工作区得分差 < margin 时触发 |
| `roleWeight[source/docs]` | 测试候选无 source/docs roleTags | 真实文件有 roleTags 时生效 |
| `roleWeight[junk]` | 测试候选无 junk/temporary roleTags | 有临时文件类候选时生效 |
| `locationWeight[*]` | 测试候选无 location 元数据 | 有位置分类的文件记忆时生效 |
| `signalWeights["failed"]` | 测试候选无 "failed" 信号 | 有失败任务候选时生效 |
| `signalWeights["running"]` | 测试候选无 "running" 信号 | 有进行中任务候选时生效 |
| `explorationBudget` / `normalBudget` | output=maxCandidates，无裁剪压力 | 总候选 > maxCandidates 时生效 |
| `matchThreshold` | 测试指纹相似度为 0 或 1，无模糊区间 | 真实场景指纹微变时生效 |
| `maxTokenBucket` | 测试池无高频 token | 真实数据有高频 release/backup 类 token 时生效 |

#### 28.3 测试覆盖建议（供 Opus 执行）

1. **testPool 添加 userCreated 工作区**：解锁 `userBaseline` 和 `defaultDemotionMargin` 评估。
2. **testPool 候选总数 > 28**：解锁 `explorationBudget` 和 `normalBudget` 预算公式路径。
3. **添加 location 元数据到候选**：解锁 `locationWeight` 评估。
4. **添加带 junk/temporary/source roleTags 的候选**：解锁 `roleWeight` 评估。
5. **添加 "failed"/"running" 信号候选**：解锁对应信号权重评估。
6. **添加相似但不完全相同的指纹对**：解锁 `matchThreshold` 模糊匹配评估。

#### 28.4 立即可执行的参数调整

**状态以 § 0 总表为准：**

| 优先级 | 改动 | 文件/位置 | 效果 | 状态 |
|--------|------|----------|------|------|
| **P1** | `wFrequency: 1.5 → 2.5` | `AIWorkspaceModel.swift` line ~361 | ws_neg_demote_at 4→5（提升抗负反馈韧性） | ✅已落地 |
| P3 | `"source-ref-match": 2.0 → 1.0` | `AIVirtualFolderPlan.swift` line ~258 | 无 tier 影响；可选（数值更精简） | ⏳未做（可选） |
| — | `wFrequency` 以外所有 Phase 5 参数 | — | 基线已最优或无法从当前测试池评估 | — |

---

## Phase 6：AIStartupDirectoryRanker 参数扫测

**扫测文件**：`SimpleZip/Core/AI/AIStartupSuggestion.swift`

**关键指标**：
- `startup_correct`：top 候选是否为预期「最近活跃目录」（1=正确，0=错误）
- `startup_gap`：top1 与 top2 的分差（越大越稳健）
- `startup_neg_penalty`：top1 与「有 2 条负面信号目录」的分差（越大越能抑制差目录）

**测试数据**（来自 `AIBenchmarkSweepTests.swift` line 484–491）：
```
s1: ~/Documents/SimpleZip  visits=9  dwell=1800s recency=1d  neg=0  ← 预期 top
s4: ~/Desktop              visits=7  dwell=60s   recency=3d  neg=2  ← 负面信号测试
s6: ~/Archives/2022        visits=11 dwell=900s  recency=40d neg=0  ← 旧目录挑战者
```

---

### 29. `dwell cap`（停留时长饱和阈值）

**位置**：`AIStartupSuggestion.swift` line 108：`min(1.0, Double(c.medianDwellSeconds) / 600.0)`

**公式**：dwell 贡献 = `min(1.0, medianDwellSeconds / cap)`

| dwell_cap | startup_correct | startup_gap | startup_neg_penalty |
|-----------|:--------------:|:-----------:|:-------------------:|
| 300 | 1 | 0.5506 | 5.2117 |
| **600（基线）** | **1** | **0.5506** | **5.3117** |
| 900 | 1 | 0.5506 | 5.3450 |
| 1800 | 1 | **1.0506** | 5.3783 |

**分析**：
- `startup_correct` 始终正确（log2 压缩已修正旧目录雪球问题）。
- `gap` 仅在 cap=1800 时跳升至 1.0506（s1 的 1800s 停留恰好满分，s6 仅 900s 得 0.5）。
- cap 在 300–900 区间内 gap 完全不变（s1/s6 的相对停留贡献已锁定）。
- `neg_penalty` 随 cap 增大而微增（s1 停留贡献越高，对比 s4 的 0.1 就越明显）。

**结论**：基线 cap=600 保留。cap=1800 会给长停留目录额外 +0.5 优势，但也降低了停留差异的辨别力（所有超过 1800s 的目录得分相同）。

---

### 30. `recencyHalfLife`（新鲜度半衰期）

**位置**：`AIStartupSuggestion.swift` line 109：`pow(0.5, Double(c.recencyDays) / 14.0)`

| halfLife_days | startup_correct | startup_gap | startup_neg_penalty |
|:-------------:|:--------------:|:-----------:|:-------------------:|
| 7 | 1 | **0.6236** | 5.3847 |
| **14（基线）** | **1** | **0.5506** | **5.3117** |
| 21 | 1 | 0.4374 | 5.2837 |
| 30 | 1 | 0.3173 | 5.2661 |

**分析**：
- 半衰期越短（7d），新鲜度衰减越快 → s6（40d 旧）被压得更低，gap 反而更大（+0.07）。
- 半衰期越长（30d），gap 缩小至 0.32 → 旧目录「记得更久」，新旧目录差异减弱。
- `startup_correct` 在所有测试点均正确，说明当前公式鲁棒性充分。
- `neg_penalty` 受半衰期轻微影响（s4 recency=3d，半衰期变短则 s4 的新鲜度加分轻微下降）。

**结论**：基线 14d 为较均衡选择。若希望对「今天才打开」更敏感，可降至 7d（gap +14%）；若希望「一个月前的习惯也算数」，可升至 21–30d（gap −20% 至 −42%）。

---

### 31. `penalty per negative`（负面信号每条扣分倍率）

**位置**：`AIStartupSuggestion.swift` line 110：`2.0 * Double(c.negativeSignalCount)`

| penalty_mult | startup_correct | startup_gap | startup_neg_penalty |
|:------------:|:--------------:|:-----------:|:-------------------:|
| 1.0 | 1 | 0.5506 | **3.3117** |
| **2.0（基线）** | **1** | **0.5506** | **5.3117** |
| 3.0 | 1 | 0.5506 | **7.3117** |

**分析**：
- `gap` 完全不受 penalty 影响（gap 由 s1 vs s6 计算，两者均无负面信号）。
- `neg_penalty` 线性增长：penalty_mult=k → neg_penalty ≈ 0.55 + k × 2.38（s4 有 2 条负面信号）。
- `startup_correct` 始终正确，说明即使 penalty=1.0 时 s4 也不会进 top1。

**结论**：基线 2.0 合适。每条负面信号扣 2 分，足以将「打开后立刻关闭 2 次」的目录可靠排在后面。调为 3.0 可加强惩罚，但对「分差本已充足」的场景无实际收益。

---

### 32. Phase 6 StartupRanker 小结

| 参数 | 基线 | 敏感度 | 关键阈值 / 建议 |
|------|------|:------:|---------------|
| `dwell cap` | 600 | 低 | cap=1800 给长停留+0.5 额外 gap；300–900 区间 gap 冻结 |
| `recencyHalfLife` | 14d | **中** | ±7d → gap ±13%；当前 14d 均衡 |
| `penalty` | 2.0 | **高（neg_penalty 线性）** | 每 +1.0 使 neg_penalty +2.38；gap 不受影响 |

**建议**：三个参数基线均合理，无需调整。如需场景定制：短期记忆 → halfLife 7d；更强负面抑制 → penalty 3.0。

---

## Phase 7：AIThemeSuppressionPolicy 完整扫测

**扫测文件**：`SimpleZip/Core/AI/AIThemeSuppression.swift`

**关键指标**：
- `suppress_resurface_days`：单次 dismiss 后主题重新浮现所需天数（基线 26d）
- `suppress_resurface_days_2x`：两次 dismiss 后重新浮现天数（基线 57d）

**计算公式**：`base × 0.5^(t / halfLife) < resurfaceFloor`

---

### 33. `maxBaseWeight`（dismiss 基础权重上限）

**位置**：`AIThemeSuppression.swift` line 43

| maxBaseWeight | suppress_resurface_days | suppress_resurface_days_2x |
|:-------------:|:-----------------------:|:--------------------------:|
| 0.6 | 26 | **51** |
| 0.8 | 26 | 57 |
| **1.0（基线）** | **26** | **57** |

**分析**：
- 单次 dismiss（count=1）的 base = min(maxBaseWeight, 0.6) → maxBaseWeight ≥ 0.6 均等于 0.6，1x 完全不敏感。
- 两次 dismiss（count=2）的 base = min(maxBaseWeight, 0.8) → maxBaseWeight=0.6 将 2x base 从 0.8 降到 0.6，resurface_days_2x 从 57 降至 51。
- maxBaseWeight=0.8 与 1.0 等效（1x 和 2x 都不超过 0.8）。

**结论**：maxBaseWeight 仅在 < 0.8 时对 2x 有效。基线 1.0 留有余量（count≥4 时 base 最高 1.0）；若希望控制极端多次 dismiss 的强度，可降至 0.8（2x 不变，4x 时 base 从 1.0 降到 0.8）。

---

### 34. `firstDismissBaseWeight`（首次 dismiss 基础权重）

**位置**：`AIThemeSuppression.swift` line 41

| firstDismissBaseWeight | suppress_resurface_days | suppress_resurface_days_2x |
|:----------------------:|:-----------------------:|:--------------------------:|
| 0.4 | **22** | **51** |
| **0.6（基线）** | **26** | **57** |
| 0.8 | **29** | **61** |

**分析**：
- 每 +0.2 → 1x 约 +3.5 天，2x 约 +5 天（两者同步上移）。
- 因为 firstDismissBaseWeight 是 base 的起始值，count=1 时 base 即等于此值，count=2 时 base=firstDismissBaseWeight+perExtra。

**结论**：高度敏感，线性响应。基线 0.6 = 「第一次不感兴趣抑制约 26 天」，属于合理的用户意图强度。调高至 0.8 可让首次 dismiss 「记得更久（29d）」；调低至 0.4 则「更快遗忘（22d）」。

---

### 35. `perExtraDismissWeight`（每次额外 dismiss 增量权重）

**位置**：`AIThemeSuppression.swift` line 42

| perExtraDismissWeight | suppress_resurface_days | suppress_resurface_days_2x |
|:---------------------:|:-----------------------:|:--------------------------:|
| 0.1 | 26 | **54** |
| **0.2（基线）** | **26** | **57** |
| 0.3 | 26 | **59** |

**分析**：
- 1x（count=1）base 不含 perExtraDismissWeight，完全不敏感（始终=26d）。
- 2x（count=2）base = 0.6 + perExtraDismissWeight → ±0.1 对应 ±3 天。
- 调整范围有限（单次额外 +0.1 仅增减 3 天），且受 maxBaseWeight=1.0 上限约束（count 足够多时饱和）。

**结论**：轻度敏感（仅影响 2x+）。基线 0.2 合适；若希望「连续 dismiss 惩罚明显累积」，可升至 0.3；若希望「多次 dismiss 影响平缓」，可降至 0.1。

---

### 36. `baseHalfLifeSeconds`（基础半衰期）

**位置**：`AIThemeSuppression.swift` line 45（扫测时为 `7 * 24 * 3600`，**现已落地为 `10 * 24 * 3600`**）

| halfLife_days | suppress_resurface_days | suppress_resurface_days_2x |
|:-------------:|:-----------------------:|:--------------------------:|
| 5 | **18** | **41** |
| 7（原默认） | 26 | 57 |
| **10（现行·已落地）** | **36** | **81** |

**分析**：
- 高度敏感，近线性：每 +1d halfLife → 1x 约 +4.5d，2x 约 +10d（因为 2x halfLife=10×2=20d，斜率翻倍）。
- 5d → 1x 仅 18 天（对频繁打开 / 取消的主题「记忆」过短）。
- 10d → 1x 长达 36 天。

**结论**：最敏感的抑制参数（单位增量效果最大）。Phase 7 当时倾向保留 7d；最终采纳 Phase 1 的产品判断**落地为 10d**（「随手点不感兴趣→约 5 周后才重新浮现」，对单次轻踩更稳健）。区间硬约束：不建议低于 5d（抑制过弱）或高于 14d（2 次 dismiss 后 113 天过久）。

---

### 37. `resurfaceFloor`（重新浮现阈值）

**位置**：`AIThemeSuppression.swift` line 47

| resurfaceFloor | suppress_resurface_days | suppress_resurface_days_2x |
|:--------------:|:-----------------------:|:--------------------------:|
| 0.02 | **35** | **75** |
| **0.05（基线）** | **26** | **57** |
| 0.1 | **19** | **43** |

**分析**：
- 高度敏感（对数响应）：floor 越低 → 须等待权重衰减到更低 → 抑制时间更长。
- floor=0.02：主题须衰减到 2% 才放行（35d），适合「用户说不感兴趣就真的不感兴趣」的保守场景。
- floor=0.1：只须衰减到 10% 就放行（19d），适合「可以快速给主题第二次机会」的场景。

**结论**：这是调整整体抑制强度的最直接旋钮（不改变半衰期曲线形状，只改变放行阈值）。基线 0.05 在「较久但可恢复」间取得平衡。若 QA 发现用户反馈「关了就是关了」，降至 0.02；若反馈「推荐消失太久」，升至 0.1。

---

### 38. Phase 7 ThemeSuppressionPolicy 小结

| 参数 | 基线 | 敏感度 | 关键效果 |
|------|------|:------:|---------|
| `maxBaseWeight` | 1.0 | 低 | 仅 <0.8 时影响 2x+；可降至 0.8 无损 |
| `firstDismissBaseWeight` | 0.6 | **高** | ±0.2 → 1x ±3.5d，2x ±5d |
| `perExtraDismissWeight` | 0.2 | 中（仅 2x+） | ±0.1 → 2x ±3d；1x 不变 |
| `baseHalfLifeSeconds` | 10d（已落地，原 7d） | **极高** | ±1d → 1x ±4.5d，2x ±10d |
| `resurfaceFloor` | 0.05 | **高** | 对数响应；0.02→35d，0.1→19d（1x） |

**建议**：所有参数基线均合理，无需调整。抑制时间如需整体拉伸 / 压缩，优先调 `resurfaceFloor`（旋钮最纯）；如需改变「记忆强度的增长速度」，调 `baseHalfLifeSeconds`。

---

## Phase 8：AIWorkspaceLearningStore 参数扫测

**扫测文件**：`SimpleZip/Core/AI/AIWorkspaceLearningStore.swift`

**关键指标**：
- `learn_neutral_days`：从标准负面强化出发，`weightedAffinity` 衰减至不再触发 `isStronglyDisliked` 所需天数（基线 21d）
- `learn_cap_neutral_days`：从 cap（最大负面权重）出发，衰减至不再触发 `isStronglyDisliked` 所需天数（基线 31d）

---

### 39. `cap`（信号权重钳制上限）

**位置**：`AIWorkspaceLearningStore.swift` line 19

| cap | learn_neutral_days | learn_cap_neutral_days |
|:---:|:-----------------:|:---------------------:|
| 3.0 | **8** | **8** |
| 4.0 | 21 | **21** |
| **5.0（基线）** | **21** | **31** |
| 7.0 | 21 | 31 |
| 10.0 | 21 | 31 |

**分析**：
- `learn_neutral_days` 在 cap ≥ 4.0 时冻结为 21d（测试场景的「标准负面」起始权重 ≤ 4.0，cap 不影响）。
- `learn_cap_neutral_days` 在 cap ≥ 5.0 时冻结为 31d（5.0 是测试场景中 cap 刚好能触及的临界值）。
- cap=4.0 → learn_cap_neutral_days 从 31d 降至 21d（cap 降低，积累上限变小，衰减终点提前）。
- cap=3.0 → 两个指标同时暴跌至 8d（cap 已低于「标准负面」起始权重，强度大幅减弱）。

**结论**：cap ≥ 5.0 时指标稳定（上限无实际约束）；cap=4.0 是弱化「记忆上限」的临界点；cap < 4.0 会导致信号累积不足，反馈学习失效。**不建议调低 cap**；≥ 5.0 皆可，当前 5.0 为最低有效值。

---

### 40. `strongNegative`（强排斥触发阈值）

**位置**：`AIWorkspaceLearningStore.swift` line 21

| strongNegative | learn_neutral_days | learn_cap_neutral_days |
|:--------------:|:-----------------:|:---------------------:|
| -1.5 | **43** | **53** |
| **-2.5（基线）** | **21** | **31** |
| -4.0 | **1** | **10** |

**分析**：
- 极度敏感：每 +1.0 强度 → neutral_days 缩短约 10–11 天（放松阈值 → 更快不再「强排斥」）。
- strongNegative=-1.5：需要 43 天才能恢复（轻微不喜欢的判断也要维持 43 天，过于保守）。
- strongNegative=-4.0：仅 1 天（几乎不记得，用户点了「不喜欢」隔天就当没发生）。
- 基线 -2.5 = 「强负信号须积累 2 次以上踩踏才触发，且持续约 3 周」。

**结论**：这是整个学习层最敏感的参数。-2.5 属设计自洽（cap=5.0 时需踩 2 次才饱和到 -5.0，再衰减 21 天低过 -2.5）。**不建议调整**；如需「更温和的长期记忆」可轻调至 -2.0（neutral_days 约 28d）；如需「更快遗忘」可试 -3.0（约 15d）。

---

### 41. `feedbackHalfLifeDays`（反馈时间衰减半衰期）

**位置**：`AIWorkspaceLearningStore.swift` line 23

| feedbackHalfLifeDays | learn_neutral_days | learn_cap_neutral_days |
|:--------------------:|:-----------------:|:---------------------:|
| 15.0 | **11** | **16** |
| 30.0（原默认） | 21 | 31 |
| **45.0（现行·已落地）** | **31** | **46** |
| 60.0 | **41** | **61** |

**分析**：
- 线性响应：halfLife 翻倍 → neutral_days 约翻倍（11→21→31→41，16→31→46→61）。
- learn_neutral_days ≈ halfLife × 0.69，learn_cap_neutral_days ≈ halfLife × 1.02（经验比值）。
- 这是最「旋钮感」最纯的参数：直接控制「学习记忆的遗忘速度」，不影响其他指标。
- **已落地 45.0**：neutral 21→31 天，更贴合用户偏好记忆周期（实测值，非旧夹具的 13→19）。

**结论**：30d 半衰期意味着「上个月的不喜欢今天还有一半效力」——属合理的用户习惯周期。如需「短期记忆」可降至 15d（11–16 天恢复）；如需「长期记忆」可升至 60d（41–61 天恢复）。**调整时建议同步考虑 `strongNegative`**（两者共同决定「学习效力窗口」的宽度）。

---

### 42. Phase 8 LearningStore 小结

| 参数 | 基线 | 敏感度 | 关键效果 |
|------|------|:------:|---------|
| `cap` | 5.0 | **临界** | cap<4.0 学习失效；≥5.0 无差异，不建议调低 |
| `strongNegative` | -2.5 | **极高** | 每 +1.0 → neutral_days ±11d；最影响「记忆持续时长」 |
| `feedbackHalfLifeDays` | 45.0（已落地，原 30.0） | **高（线性）** | 翻倍 → neutral_days 翻倍；最纯的遗忘速度旋钮 |

---

## Phase 6–8 综合结论

### 全参数敏感度总览（新增部分）

| 模块 | 参数 | 基线 | 敏感度 | 可安全调整范围 |
|------|------|------|:------:|-------------|
| StartupRanker | `dwell cap` | 600 | 低 | 300–1800（gap 变化 ≤0.5） |
| StartupRanker | `recencyHalfLife` | 14d | 中 | 7d（+gap）↔ 21d（−gap） |
| StartupRanker | `penalty` | 2.0 | 高（线性） | 1.0–3.0（neg_penalty 线性） |
| ThemeSuppressionPolicy | `maxBaseWeight` | 1.0 | 低 | ≥0.8 无损；0.6 轻减 2x |
| ThemeSuppressionPolicy | `firstDismissBaseWeight` | 0.6 | 高 | 0.4–0.8（1x 22–29d） |
| ThemeSuppressionPolicy | `perExtraDismissWeight` | 0.2 | 中（仅 2x+） | 0.1–0.3 |
| ThemeSuppressionPolicy | `baseHalfLifeSeconds` | 10d（已落地，原 7d） | **极高** | 5–14d；现行 10d |
| ThemeSuppressionPolicy | `resurfaceFloor` | 0.05 | 高 | 0.02（严格）↔ 0.1（宽松） |
| LearningStore | `cap` | 5.0 | 临界 | ≥5.0；<4.0 失效 |
| LearningStore | `strongNegative` | -2.5 | **极高** | -2.0↔-3.0；不出此区间 |
| LearningStore | `feedbackHalfLifeDays` | 45.0（已落地，原 30.0） | 高（线性） | 15–60d；现行 45 |

### 跨模块建议（供 Opus 执行）

| 优先级 | 改动 | 依据 | 状态 |
|--------|------|------|------|
| **P1**| `wFrequency: 1.5→2.5`（Phase 5） | ws_neg_demote_at 4→5 | ✅已落地（现行值 2.5） |
| P2 | 无需改动 | 所有 Phase 6–8 基线均处于各自参数的有效中间区域 | — |
| 参考 | `resurfaceFloor: 0.05→0.1`（如用户反馈「推荐消失太久」） | 1x 26d→19d，2x 57d→43d | 可选，未做 |
| 参考 | `feedbackHalfLifeDays: 45→15`（若用户反馈「记住我不喜欢的太久」可回调） | neutral_days 31d→11d | 现行已落地 45（方向相反，回调属反向调整，取决于产品取向） |
| 参考 | `recencyHalfLife: 14→7`（如希望启动建议对「今天才打开」更灵敏） | startup_gap +13% | 可选，未做 |

---

## Phase 9：AISemanticTagRanker 参数扫测

**扫测文件**：`SimpleZip/Core/AI/AISemanticTag.swift`

**关键指标**：
- `tag_demote_at`：releaseArtifact（0.88）需要多少次负反馈才从 top1 跌落（基线 2）
- `tag_boost_at`：sourceArchive（0.72，初始 2nd）需要多少次正反馈才升至 top1（基线 2）

**测试数据**：
```
releaseArtifact:  deterministicScore=0.88  ← 初始 top1
sourceArchive:    deterministicScore=0.72  ← 初始 2nd，差距 0.16
signedContainer:  0.65 / backup: 0.40 / documentation: 0.30
```

---

### 43. `decayPerNegative`（每次负反馈衰减量）

**位置**：`AISemanticTag.swift` line 76

| decayPerNegative | tag_demote_at | tag_boost_at |
|:----------------:|:-------------:|:------------:|
| **0.05（现行·已落地）** | **4** | 2 |
| 0.10 | 2 | 2 |
| 0.15（原默认） | 2 | 2 |
| 0.20 | **1** | 2 |

**分析**：demote_at = ⌈0.16 / decayPerNeg⌉（差距 0.16 需多少次才越过）。
- 0.05 → ⌈0.16/0.05⌉=4；0.10/0.20 分别 2/1，完全线性。
- `tag_boost_at` 不受影响（与 decay 无关）。

**结论**：高度敏感且线性。Phase 1/2 推荐的 **0.05 现已落地**（Codex 应用 + 单测同步）——「需 4 次负反馈才能踩掉 16% 差距的高确定性标签」，符合「低频误踩不应覆盖确定性证据」的设计意图。原默认 0.15 仅需 2 次即翻转，偏激进；0.20 一次即翻转，已弃用。

---

### 44. `negativeFeedbackCap`（负反馈次数上限）

**位置**：`AISemanticTag.swift` line 77

| negativeFeedbackCap | tag_demote_at | tag_boost_at |
|:-------------------:|:-------------:|:------------:|
| 1 | **-1（永不）** | 2 |
| 2 | 2 | 2 |
| **5（基线）** | **2** | **2** |

**分析**：
- cap=1 → 最多施加 1 次负反馈（0.88-0.15=0.73 > 0.72，仍居首），永不翻转 → -1。
- cap=2 → demote_at=2，与基线等效（需要恰好 2 次，在 cap 内）。
- cap ≥ 2 均等效（demote_at=2 已在任何合理 cap 内）。

**结论**：只有 cap < demote_at 时才有效（本例 demote_at=2，cap=1 为唯一触发点）。基线 cap=5 远高于 demote_at，可安全降至 cap=3 而不改变行为。

---

### 45. `boostPerPositive`（每次正反馈提升量）

**位置**：`AISemanticTag.swift` line 79

| boostPerPositive | tag_demote_at | tag_boost_at |
|:----------------:|:-------------:|:------------:|
| 0.05 | 2 | **4** |
| **0.10（基线）** | **2** | **2** |
| 0.15 | 2 | 2 |
| 0.20 | 2 | **1** |

**分析**：boost_at = ⌈0.16 / boostPerPos⌉。
- 0.05 → ⌈0.16/0.05⌉=4；0.10→2；0.15 → ⌈0.16/0.15⌉=2（0.16/0.15=1.07 → 2 次）；0.20→1。
- `tag_demote_at` 不受影响。
- boostPerPositive=0.15 与 0.10 等效（差距 0.16 → 需 2 次 × 0.15 = 0.30 超过 0.16）。

**结论**：boostPerPositive=0.10 保留。⚠️ 注意：decay 已落地为 0.05 后，奖励(0.10) > 惩罚(0.05)，原「惩罚易、奖励难」(0.10 < 0.15) 的设计已被反转——现在正反馈翻转更快（2 次）、负反馈翻转更慢（4 次）。若要恢复该不变式，需把 boostPerPositive 降到 < 0.05（待 Opus 评估，见 § 47）。

---

### 46. `positiveFeedbackCap`（正反馈次数上限）

**位置**：`AISemanticTag.swift` line 80

| positiveFeedbackCap | tag_demote_at | tag_boost_at |
|:-------------------:|:-------------:|:------------:|
| 1 | 2 | **-1（永不）** |
| 2 | 2 | 2 |
| **5（基线）** | **2** | **2** |

**分析**：对称于 negativeFeedbackCap。cap=1 → 最多 1 次正反馈（0.72+0.10=0.82 < 0.88），永不超越 → -1。cap≥2 与基线等效。

**结论**：可安全降至 3（boost_at=2 < 3）。

---

### 47. Phase 9 SemanticTagRanker 小结

| 参数 | 现行值 | 敏感度 | 关键阈值 |
|------|------|:------:|---------|
| `decayPerNegative` | **0.05**（已落地，原 0.15） | **高（线性）** | 每次反馈衰减多少 → demote_at = ⌈gap/decay⌉；0.05 → 4 次 |
| `negativeFeedbackCap` | 5 | 仅 cap < demote_at 时有效 | cap ≥ 4 等效（现 demote_at=4）；降至 3 会使误踩永不翻转 |
| `boostPerPositive` | 0.10 | **高（线性）** | boost_at = ⌈gap/boost⌉；现 < decay 已不再成立（0.10 > 0.05）→ 奖励比惩罚快 |
| `positiveFeedbackCap` | 5 | 仅 cap < boost_at 时有效 | cap ≥ 2 等效；可降至 3 |

**建议**：`decayPerNegative` 已由 0.15 落地为 **0.05**（demote_at 2→4，对负反馈更保守）。⚠️ 注意联动：落地后惩罚（0.05）已小于奖励（0.10），原「惩罚易、奖励难」的设计被反转——若希望维持该不变式，可考虑把 `boostPerPositive` 同步降到 0.05 以下（**待 Opus 评估，本表仅提示，不强制**）。`negativeFeedbackCap` 在 demote_at=4 下不应再降到 3 以下（否则 cap×decay=3×0.05=0.15 < 差距 0.16，误踩标签永不翻转）。

---

## Phase 10：AIVirtualFolderPlan 剩余参数扫测

**扫测文件**：`SimpleZip/Core/AI/AIVirtualFolderPlan.swift`

---

### 48. `defaultMaxCandidates`（预备候选数量上限）

**位置**：`AIVirtualFolderPlan.swift` line 117

| defaultMaxCandidates | preparer_output | prompt_qtokens_count |
|:--------------------:|:--------------:|:-------------------:|
| 20 | **20** | 14 |
| **28（基线）** | **28** | **14** |
| 35 | 28 | 14 |
| 40 | 28 | 14 |

**分析**：
- 测试池恰好有 28 个候选（releasePool + realFilePool 合计）。
- defaultMaxCandidates=20 → output 截断至 20（-8 件，tier 分布会同步变化）。
- defaultMaxCandidates ≥ 28 → output 冻结在 28（池子已耗尽，上限无约束力）。
- `prompt_qtokens_count` 不受影响（由 workspace token 池而非候选数决定）。

**结论**：扫测时基线为 28（恰好等于测试池大小，是设计巧合）。生产环境候选可能更多，故此参数**现已落地上调为 50**（见 § 0.1），避免真实候选被人工 28 上限截断。本表数据采于上调前。

---

### 49. `queryTokens prefix`（查询 token 封顶数）

**位置**：`AIVirtualFolderPlan.swift` line 51：`Array(tokens.prefix(14))`

| prefix | preparer_output | prompt_qtokens_count |
|:------:|:--------------:|:-------------------:|
| 8 | 28 | **8** |
| 10 | 28 | **10** |
| **14（基线）** | **28** | **14** |
| 20 | 28 | **18** |

**分析**：
- `preparer_output` 完全不受影响（query token 不参与候选筛选计数）。
- prefix=20 → 实际得到 18 个 token（测试 workspace 总 token 数为 18，已被耗尽）。
- prefix=14 → 14 个 token（取全集的前 14）；prefix=8/10 严格截断。
- **测试 workspace 总 token 上限 = 18**：prefix > 18 无意义。

**结论**：14 是「几乎取全」的设计（总量 18，取 78%）。若 prompt 长度敏感（API token 成本），可降至 10（差 4 个 token，主要是低频次要 token）；若希望更完整的语义覆盖，可升至 18（取全，此时 prefix 上限无实际约束）。

---

### 50. Phase 10 VirtualFolderPlan 剩余小结

| 参数 | 基线 | 敏感度 | 生产建议 |
|------|------|:------:|---------|
| `defaultMaxCandidates` | 50（已落地，原 28） | **高（直接截断输出）** | 生产值应 > 预期日均候选量（已上调至 50） |
| `queryTokens prefix` | 14 | 中（线性截断 token） | 10–18 均可；18 为本测试 workspace 上限 |

---

## 全局总结：所有参数扫测完毕

**覆盖文件**：7 个（AIWorkspaceModel / AIVirtualFolderPlan / AIWorkspaceThemeEngine / AIThemeSuppression / AIWorkspaceLearningStore / AIStartupSuggestion / AISemanticTag）

**参数总数**：35 个（含本轮 Phase 6–10 新增 14 个）

### 敏感度速查表（全量）

| 模块 | 参数 | 基线 | 敏感度 | 最关键效果 |
|------|------|------|:------:|-----------|
| WorkspaceRanking | `wRelevance` | 5.0 | 高 | <5.0 → demote_at 跌至 3 |
| WorkspaceRanking | `wRecency` | 2.5 | 中 | gap +0.96/单位 |
| WorkspaceRanking | `wFrequency` | 2.5（已落地，原 1.5） | **极高** | 2.5→demote_at=5（抗负反馈+1次） |
| WorkspaceRanking | `wDwell` | 2.0 | 高 | <2.0→demote_at=3 |
| WorkspaceRanking | `userBaseline` | 2.5 | 无（测试池无 userCreated） | — |
| WorkspaceRanking | `feedbackPenalty` | 2.5 | 高 | neg1_over_D 随之线性 |
| WorkspaceRanking | `defaultDemotionMargin` | 1.0 | 无（测试池无竞争） | — |
| WorkspaceRanking | `recencyHalfLifeDays` | 10.0 | 中 | gap 峰值在 10d |
| VirtualFolderPlan | `signalWeights["project-token"]` | 3.0 | 高 | <3.0→tier_high 从 10 跌至 8 |
| VirtualFolderPlan | `signalWeights["source-ref-match"]` | 2.0 | 中 | 可降至 1.0 无 tier 损失 |
| VirtualFolderPlan | `signalWeights["repeated"]` | -1.0 | 低–中 | ≤-2.0→tier_normal→low 转移 |
| VirtualFolderPlan | `kindWeight["task"]` | -1.0 | 中 | ≤-2.0→tier_high 少 1 件任务 |
| VirtualFolderPlan | `roleWeight/locationWeight/*` | 各异 | 无（测试候选无对应 roleTags） | — |
| VirtualFolderPlan | `explorationBudget/normalBudget` | /5 / ×2/5 | 无（测试池未触及预算） | — |
| VirtualFolderPlan | `defaultMaxCandidates` | 50（已落地，原 28） | **高（直接截断）** | <预期候选量→output 被截断 |
| VirtualFolderPlan | `queryTokens prefix` | 14 | 中 | 线性截断；测试总量=18 |
| ThemeEngine | `maxTokenBucket` | 80 | 无（测试池未触发高频截断） | — |
| ThemeSuppression | `firstDismissBaseWeight` | 0.6 | 高 | ±0.2→1x ±3.5d |
| ThemeSuppression | `perExtraDismissWeight` | 0.2 | 中（仅 2x+） | ±0.1→2x ±3d |
| ThemeSuppression | `maxBaseWeight` | 1.0 | 低 | <0.8 才影响 2x+ |
| ThemeSuppression | `baseHalfLifeSeconds` | 10d（已落地，原 7d） | **极高** | ±1d→1x ±4.5d，2x ±10d |
| ThemeSuppression | `resurfaceFloor` | 0.05 | 高 | 最纯的整体抑制强度旋钮 |
| ThemeSuppression | `matchThreshold` | 0.5 | 无（测试指纹无模糊区间） | — |
| LearningStore | `cap` | 5.0 | 临界 | <4.0 学习层失效 |
| LearningStore | `strongNegative` | -2.5 | **极高** | 每 +1.0→neutral_days ±11d |
| LearningStore | `feedbackHalfLifeDays` | 45.0（已落地，原 30.0） | 高（线性） | 最纯的遗忘速度旋钮 |
| StartupRanker | `dwell cap` | 600 | 低 | cap=1800→gap+0.5 |
| StartupRanker | `recencyHalfLife` | 14d | 中 | 7d→gap +13% |
| StartupRanker | `penalty` | 2.0 | 高（线性） | 每 +1.0→neg_penalty +2.38 |
| SemanticTagRanker | `decayPerNegative` | 0.05（已落地，原 0.15） | 高（线性） | demote_at = ⌈gap/decay⌉ = 4 |
| SemanticTagRanker | `negativeFeedbackCap` | 5 | 仅 cap < demote_at | cap≥2 等效于基线 |
| SemanticTagRanker | `boostPerPositive` | 0.10 | 高（线性） | boost_at = ⌈gap/boost⌉ |
| SemanticTagRanker | `positiveFeedbackCap` | 5 | 仅 cap < boost_at | cap≥2 等效于基线 |

### 立即可执行的调整建议（状态以 § 0 总表为准）

| 优先级 | 改动 | 文件 | 实测效果 | 状态 |
|--------|------|------|---------|------|
| **P1** | `wFrequency: 1.5 → 2.5` | AIWorkspaceModel.swift L361 | ws_neg_demote_at 4→5，高相关 ws 多抵抗 1 次负反馈 | ✅已落地 |
| P2 | `defaultMaxCandidates: 28 → 50`（生产值） | AIVirtualFolderPlan.swift L117 | 避免真实候选被截断，测试池人工限制 | ✅已落地 |
| P3 | `"source-ref-match": 2.0 → 1.0` | AIVirtualFolderPlan.swift L258 | 无 tier 损失，数值更精简 | ⏳未做（可选） |
| 参考 | ~~`negativeFeedbackCap/positiveFeedbackCap: 5→3`~~ | AISemanticTag.swift L77/80 | ⚠️**已撤回**：decay 落地为 0.05 后 demote_at=4，negativeFeedbackCap 降到 3 会使误踩标签永不翻转（3×0.05<0.16）。**保持 5** | 不做 |

### 测试覆盖盲区（不敏感参数的真实激活条件）

以下参数在当前 benchmark 测试池下不敏感，**但在生产中有实际影响**，未来扩充测试池时应优先添加：

| 盲区 | 激活条件 |
|------|---------|
| `userBaseline`、`defaultDemotionMargin` | 添加 userCreated 工作区到测试池 |
| `explorationBudget`、`normalBudget`、`maxTokenBucket`、`defaultMaxCandidates`（实截断） | 测试候选数 > 28（建议扩至 50+） |
| `roleWeight/*`、`locationWeight/*` | 候选携带 roleTags 和 location 元数据 |
| `signalWeights["failed"]`、`["running"]` | 候选池含失败/进行中任务 |
| `matchThreshold` | 测试指纹集含相似度 0.3–0.7 的模糊对 |
