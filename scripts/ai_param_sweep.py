#!/usr/bin/env python3
"""
AI 参数迭代扫测驱动
运行方式: python3 scripts/ai_param_sweep.py
每轮: 修改生产参数 → 跑 benchmarkMetrics → 记录指标 → git restore → 下一组
不生成任何 commit，工作区在扫测结束后恢复干净。
"""
import subprocess, re, sys, os, time

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SWIFT_TEST = (
    "/usr/bin/env "
    "DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer "
    "/usr/bin/xcrun swift test "
    "--scratch-path /private/tmp/SimpleZipSwiftPM "
    "-Xswiftc -module-cache-path "
    "-Xswiftc /private/tmp/SimpleZipSwiftPM/ModuleCache "
    "--filter AIBenchmarkSweepTests/benchmarkMetrics"
)

# ── 文件路径 ──────────────────────────────────────────────────────────────
F_WORKSPACE  = os.path.join(REPO, "SimpleZip/Core/AI/AIWorkspaceModel.swift")
F_STARTUP    = os.path.join(REPO, "SimpleZip/Core/AI/AIStartupSuggestion.swift")
F_TAG        = os.path.join(REPO, "SimpleZip/Core/AI/AISemanticTag.swift")
F_SUPPRESS   = os.path.join(REPO, "SimpleZip/Core/AI/AIThemeSuppression.swift")
F_LEARNING   = os.path.join(REPO, "SimpleZip/Core/AI/AIWorkspaceLearningStore.swift")
F_PLAN       = os.path.join(REPO, "SimpleZip/Core/AI/AIVirtualFolderPlan.swift")

def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()

def write(path, text):
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)

def replace_first(text, old, new):
    if old not in text:
        raise ValueError(f"Pattern not found:\n  {old!r}")
    return text.replace(old, new, 1)

def git_restore(*paths):
    for p in paths:
        subprocess.run(["git", "restore", p], cwd=REPO, check=True, capture_output=True)

def run_metrics():
    """运行 benchmarkMetrics，返回 {key: value} dict（均为字符串）。"""
    t0 = time.time()
    r = subprocess.run(SWIFT_TEST, shell=True, cwd=REPO,
                       capture_output=True, text=True, timeout=180)
    elapsed = time.time() - t0
    out = r.stdout + r.stderr
    metrics = {}
    for line in out.splitlines():
        m = re.match(r"METRIC:([^:]+):(.*)", line)
        if m:
            metrics[m.group(1)] = m.group(2)
    if not metrics:
        print("  !! 没有 METRIC 输出，可能编译失败")
        print(out[-2000:])
    return metrics, elapsed

# ═══════════════════════════════════════════════════════════════
#  1. WorkspaceRanking.feedbackPenalty  (F_WORKSPACE, line ~365)
# ═══════════════════════════════════════════════════════════════
def sweep_feedback_penalty():
    print("\n" + "="*60)
    print("  WorkspaceRanking.feedbackPenalty 扫测")
    print("  指标: ws_high_low_gap, ws_neg1_over_D, ws_neg_demote_at")
    print("="*60)
    print(f"  {'penalty':>8}  {'gap':>10}  {'neg1_over_D':>12}  {'demote_at':>10}")
    print(f"  {'-'*8}  {'-'*10}  {'-'*12}  {'-'*10}")

    original = read(F_WORKSPACE)
    # 搜索锚: 精确匹配带前后空格的行
    ANCHOR = "    static let feedbackPenalty = 3.0"
    results = []
    for penalty in [1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0]:
        modified = replace_first(original, ANCHOR,
                                 f"    static let feedbackPenalty = {penalty}")
        write(F_WORKSPACE, modified)
        m, t = run_metrics()
        gap = float(m.get("ws_high_low_gap", "nan"))
        neg1 = m.get("ws_neg1_over_D", "?")
        demote = m.get("ws_neg_demote_at", "?")
        print(f"  {penalty:>8.1f}  {gap:>10.4f}  {neg1:>12}  {demote:>10}   ({t:.0f}s)")
        results.append((penalty, gap, neg1, demote))
    git_restore(F_WORKSPACE)
    return results

# ═══════════════════════════════════════════════════════════════
#  2. WorkspaceRanking.recencyHalfLifeDays  (F_WORKSPACE, line ~359)
# ═══════════════════════════════════════════════════════════════
def sweep_recency_half_life():
    print("\n" + "="*60)
    print("  WorkspaceRanking.recencyHalfLifeDays 扫测")
    print("  指标: ws_high_low_gap")
    print("="*60)
    print(f"  {'halfLife':>10}  {'gap':>10}")
    print(f"  {'-'*10}  {'-'*10}")

    original = read(F_WORKSPACE)
    ANCHOR = "    static let recencyHalfLifeDays = 7.0"
    results = []
    for hl in [3.0, 5.0, 7.0, 10.0, 14.0, 21.0]:
        modified = replace_first(original, ANCHOR,
                                 f"    static let recencyHalfLifeDays = {hl}")
        write(F_WORKSPACE, modified)
        m, t = run_metrics()
        gap = float(m.get("ws_high_low_gap", "nan"))
        print(f"  {hl:>10.1f}  {gap:>10.4f}   ({t:.0f}s)")
        results.append((hl, gap))
    git_restore(F_WORKSPACE)
    return results

# ═══════════════════════════════════════════════════════════════
#  3. StartupRanker 衰减公式  (F_STARTUP, 替换整行)
# ═══════════════════════════════════════════════════════════════
def sweep_startup_recency():
    print("\n" + "="*60)
    print("  AIStartupDirectoryRanker 衰减公式扫测")
    print("  关键: startup_correct 必须为 1 (新目录应赢老目录)")
    print("="*60)
    print(f"  {'公式':>30}  {'correct':>8}  {'gap':>10}  {'neg_pen':>10}")
    print(f"  {'-'*30}  {'-'*8}  {'-'*10}  {'-'*10}")

    original = read(F_STARTUP)
    # 当前: let recency = max(0.0, 1.0 - 0.1 * Double(c.recencyDays))
    ANCHOR = "        let recency = max(0.0, 1.0 - 0.1 * Double(c.recencyDays))"

    formulas = [
        ("linear_10d",  ANCHOR),   # baseline (当前)
        ("exp_hl7d",    "        let recency = pow(0.5, Double(c.recencyDays) / 7.0)"),
        ("exp_hl14d",   "        let recency = pow(0.5, Double(c.recencyDays) / 14.0)"),
        ("exp_hl21d",   "        let recency = pow(0.5, Double(c.recencyDays) / 21.0)"),
        ("sqrt_100d",   "        let recency = max(0.0, 1.0 - sqrt(Double(c.recencyDays)) / 10.0)"),
        ("log_scale",   "        let recency = max(0.0, 1.0 - log2(Double(c.recencyDays) + 1) / 10.0)"),
    ]
    results = []
    for name, new_line in formulas:
        modified = replace_first(original, ANCHOR, new_line)
        write(F_STARTUP, modified)
        m, t = run_metrics()
        correct = m.get("startup_correct", "?")
        gap     = m.get("startup_gap", "nan")
        neg     = m.get("startup_neg_penalty", "nan")
        print(f"  {name:>30}  {correct:>8}  {float(gap):>10.4f}  {float(neg):>10.4f}   ({t:.0f}s)")
        results.append((name, correct, float(gap), float(neg)))
    git_restore(F_STARTUP)
    return results

# ═══════════════════════════════════════════════════════════════
#  4. SemanticTagRanker.decayPerNegative  (F_TAG)
# ═══════════════════════════════════════════════════════════════
def sweep_tag_decay():
    print("\n" + "="*60)
    print("  AISemanticTagRanker.decayPerNegative 扫测")
    print("  指标: tag_demote_at（期望 3-5，不能 1 或 2）")
    print("="*60)
    print(f"  {'decay':>8}  {'demote_at':>10}  {'boost_at':>10}")
    print(f"  {'-'*8}  {'-'*10}  {'-'*10}")

    original = read(F_TAG)
    ANCHOR = "    static let decayPerNegative = 0.15"
    results = []
    for decay in [0.05, 0.08, 0.10, 0.12, 0.15, 0.18, 0.20, 0.25]:
        modified = replace_first(original, ANCHOR,
                                 f"    static let decayPerNegative = {decay}")
        write(F_TAG, modified)
        m, t = run_metrics()
        demote  = m.get("tag_demote_at", "?")
        boost   = m.get("tag_boost_at",  "?")
        print(f"  {decay:>8.2f}  {demote:>10}  {boost:>10}   ({t:.0f}s)")
        results.append((decay, demote, boost))
    git_restore(F_TAG)
    return results

# ═══════════════════════════════════════════════════════════════
#  5. SemanticTagRanker.negativeFeedbackCap  (F_TAG)
# ═══════════════════════════════════════════════════════════════
def sweep_tag_neg_cap():
    print("\n" + "="*60)
    print("  AISemanticTagRanker.negativeFeedbackCap 扫测")
    print("  配合 decayPerNegative=0.15 测 cap 对衰减上限的影响")
    print("="*60)
    print(f"  {'negCap':>8}  {'demote_at':>10}")
    print(f"  {'-'*8}  {'-'*10}")

    original = read(F_TAG)
    ANCHOR = "    static let negativeFeedbackCap = 5"
    results = []
    for cap in [3, 4, 5, 6, 8, 10]:
        modified = replace_first(original, ANCHOR,
                                 f"    static let negativeFeedbackCap = {cap}")
        write(F_TAG, modified)
        m, t = run_metrics()
        demote = m.get("tag_demote_at", "?")
        print(f"  {cap:>8}  {demote:>10}   ({t:.0f}s)")
        results.append((cap, demote))
    git_restore(F_TAG)
    return results

# ═══════════════════════════════════════════════════════════════
#  6. AIThemeSuppressionPolicy.baseHalfLifeSeconds  (F_SUPPRESS)
# ═══════════════════════════════════════════════════════════════
def sweep_suppress_halflife():
    print("\n" + "="*60)
    print("  AIThemeSuppressionPolicy.baseHalfLifeSeconds 扫测")
    print("  指标: suppress_resurface_days (1次), suppress_resurface_days_2x")
    print("  期望: 1次 → 14-35天, 2次 → 30-80天")
    print("="*60)
    print(f"  {'halfLife':>10}  {'resurface_1':>12}  {'resurface_2x':>13}")
    print(f"  {'-'*10}  {'-'*12}  {'-'*13}")

    original = read(F_SUPPRESS)
    ANCHOR = "    static let baseHalfLifeSeconds: TimeInterval = 7 * 24 * 3600"
    results = []
    for days in [3, 5, 7, 10, 14, 21]:
        secs = days * 24 * 3600
        modified = replace_first(original, ANCHOR,
                                 f"    static let baseHalfLifeSeconds: TimeInterval = {secs}")
        write(F_SUPPRESS, modified)
        m, t = run_metrics()
        r1  = m.get("suppress_resurface_days", "?")
        r2  = m.get("suppress_resurface_days_2x", "?")
        print(f"  {days:>10}d  {r1:>12}  {r2:>13}   ({t:.0f}s)")
        results.append((days, r1, r2))
    git_restore(F_SUPPRESS)
    return results

# ═══════════════════════════════════════════════════════════════
#  7. AIWorkspaceLearningStore.feedbackHalfLifeDays  (F_LEARNING)
# ═══════════════════════════════════════════════════════════════
def sweep_learning_halflife():
    print("\n" + "="*60)
    print("  AIWorkspaceLearningStore.feedbackHalfLifeDays 扫测")
    print("  指标: learn_neutral_days, learn_cap_neutral_days")
    print("  期望: neutral_days ~ 14-45 (不能太快也不能太慢)")
    print("="*60)
    print(f"  {'halfLife':>10}  {'neutral':>10}  {'cap_neutral':>12}")
    print(f"  {'-'*10}  {'-'*10}  {'-'*12}")

    original = read(F_LEARNING)
    ANCHOR = "    static let feedbackHalfLifeDays = 30.0"
    results = []
    for hl in [10.0, 14.0, 21.0, 30.0, 45.0, 60.0, 90.0]:
        modified = replace_first(original, ANCHOR,
                                 f"    static let feedbackHalfLifeDays = {hl}")
        write(F_LEARNING, modified)
        m, t = run_metrics()
        neutral   = m.get("learn_neutral_days", "?")
        cap_neut  = m.get("learn_cap_neutral_days", "?")
        print(f"  {hl:>10.1f}d  {neutral:>10}  {cap_neut:>12}   ({t:.0f}s)")
        results.append((hl, neutral, cap_neut))
    git_restore(F_LEARNING)
    return results

# ═══════════════════════════════════════════════════════════════
#  8. AIWorkspaceLearningStore.strongNegative  (F_LEARNING)
# ═══════════════════════════════════════════════════════════════
def sweep_strong_negative():
    print("\n" + "="*60)
    print("  AIWorkspaceLearningStore.strongNegative 扫测")
    print("  指标: learn_neutral_days (threshold 越紧 → neutral_days 越长)")
    print("="*60)
    print(f"  {'strongNeg':>10}  {'neutral':>10}")
    print(f"  {'-'*10}  {'-'*10}")

    original = read(F_LEARNING)
    ANCHOR = "    static let strongNegative = -3.0"
    results = []
    for sn in [-1.5, -2.0, -2.5, -3.0, -3.5, -4.0]:
        modified = replace_first(original, ANCHOR,
                                 f"    static let strongNegative = {sn}")
        write(F_LEARNING, modified)
        m, t = run_metrics()
        neutral = m.get("learn_neutral_days", "?")
        print(f"  {sn:>10.1f}  {neutral:>10}   ({t:.0f}s)")
        results.append((sn, neutral))
    git_restore(F_LEARNING)
    return results

# ═══════════════════════════════════════════════════════════════
#  9. AIVirtualFolderModelInputPreparer.defaultMaxCandidates
#     主指标: preparer_coverage (专注律), 次指标: tier 分布 + 输出数
# ═══════════════════════════════════════════════════════════════
def sweep_max_candidates():
    print("\n" + "="*60)
    print("  AIVirtualFolderModelInputPreparer.defaultMaxCandidates 扫测")
    print("  主指标: preparer_coverage (专注律); 期望越大越好 (≥0.80)")
    print("="*60)
    print(f"  {'maxCand':>8}  {'coverage':>10}  {'H':>4}  {'N':>4}  {'L':>4}  {'out':>4}  {'sup':>4}")
    print(f"  {'-'*8}  {'-'*10}  {'-'*4}  {'-'*4}  {'-'*4}  {'-'*4}  {'-'*4}")

    original = read(F_PLAN)
    ANCHOR = "    static let defaultMaxCandidates = 28"
    results = []
    for mc in [10, 14, 18, 20, 24, 28, 32, 40]:
        modified = replace_first(original, ANCHOR,
                                 f"    static let defaultMaxCandidates = {mc}")
        write(F_PLAN, modified)
        m, t = run_metrics()
        cov = float(m.get("preparer_coverage", "nan"))
        h   = m.get("preparer_tier_high",   "?")
        n   = m.get("preparer_tier_normal",  "?")
        l   = m.get("preparer_tier_low",     "?")
        out = m.get("preparer_output",       "?")
        sup = m.get("preparer_suppressed",   "?")
        print(f"  {mc:>8}  {cov:>10.4f}  {h:>4}  {n:>4}  {l:>4}  {out:>4}  {sup:>4}   ({t:.0f}s)")
        results.append((mc, cov, h, n, l, out, sup))
    git_restore(F_PLAN)
    return results

# ═══════════════════════════════════════════════════════════════
#  10. importanceLabel 阈值: high threshold (≥N)
#      影响 tier 分布和高优先级候选数量
# ═══════════════════════════════════════════════════════════════
def sweep_importance_high_threshold():
    print("\n" + "="*60)
    print("  importanceLabel high threshold 扫测 (score >= N → high)")
    print("  主指标: preparer_coverage; 次指标: tier[high] 数量")
    print("="*60)
    print(f"  {'highThresh':>10}  {'coverage':>10}  {'H':>4}  {'N':>4}  {'L':>4}")
    print(f"  {'-'*10}  {'-'*10}  {'-'*4}  {'-'*4}  {'-'*4}")

    original = read(F_PLAN)
    ANCHOR = "        if score >= 7 { return \"high\" }"
    results = []
    for thr in [4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0]:
        new_line = f"        if score >= {thr} {{ return \"high\" }}"
        modified = replace_first(original, ANCHOR, new_line)
        write(F_PLAN, modified)
        m, t = run_metrics()
        cov = float(m.get("preparer_coverage", "nan"))
        h   = m.get("preparer_tier_high",  "?")
        n   = m.get("preparer_tier_normal", "?")
        l   = m.get("preparer_tier_low",   "?")
        print(f"  {thr:>10.1f}  {cov:>10.4f}  {h:>4}  {n:>4}  {l:>4}   ({t:.0f}s)")
        results.append((thr, cov, h, n, l))
    git_restore(F_PLAN)
    return results

# ═══════════════════════════════════════════════════════════════
#  11. importanceLabel 阈值: low threshold (≤N)
#      低阈值 → 更多候选是 low,高阈值 → low 减少 normal 增加
# ═══════════════════════════════════════════════════════════════
def sweep_importance_low_threshold():
    print("\n" + "="*60)
    print("  importanceLabel low threshold 扫测 (score <= N → low)")
    print("  主指标: preparer_coverage; 次指标: tier[low] 数量")
    print("="*60)
    print(f"  {'lowThresh':>10}  {'coverage':>10}  {'H':>4}  {'N':>4}  {'L':>4}")
    print(f"  {'-'*10}  {'-'*10}  {'-'*4}  {'-'*4}  {'-'*4}")

    original = read(F_PLAN)
    ANCHOR = "        if score <= 1 { return \"low\" }"
    results = []
    for thr in [0.0, 0.5, 1.0, 1.5, 2.0, 3.0]:
        new_line = f"        if score <= {thr} {{ return \"low\" }}"
        modified = replace_first(original, ANCHOR, new_line)
        write(F_PLAN, modified)
        m, t = run_metrics()
        cov = float(m.get("preparer_coverage", "nan"))
        h   = m.get("preparer_tier_high",  "?")
        n   = m.get("preparer_tier_normal", "?")
        l   = m.get("preparer_tier_low",   "?")
        print(f"  {thr:>10.1f}  {cov:>10.4f}  {h:>4}  {n:>4}  {l:>4}   ({t:.0f}s)")
        results.append((thr, cov, h, n, l))
    git_restore(F_PLAN)
    return results

# ═══════════════════════════════════════════════════════════════
#  12. AIWorkspacePromptFact.queryTokens prefix cap (N)
#      影响: prompt 里喂给模型的 token 数量(专注 vs 覆盖)
# ═══════════════════════════════════════════════════════════════
def sweep_query_tokens_cap():
    print("\n" + "="*60)
    print("  AIWorkspacePromptFact.queryTokens prefix cap 扫测")
    print("  指标: prompt_qtokens_count (18 token 工作区截后剩几个)")
    print("  理想: 足够覆盖主题意图 (≥8),不要超过 16 (噪声)")
    print("="*60)
    print(f"  {'cap':>6}  {'qtokens':>10}")
    print(f"  {'-'*6}  {'-'*10}")

    original = read(F_PLAN)
    ANCHOR = "                  prompt: workspace.prompt, queryTokens: Array(tokens.prefix(12)))"
    results = []
    for cap in [6, 8, 10, 12, 14, 16, 20]:
        new_line = f"                  prompt: workspace.prompt, queryTokens: Array(tokens.prefix({cap})))"
        modified = replace_first(original, ANCHOR, new_line)
        write(F_PLAN, modified)
        m, t = run_metrics()
        qtok = m.get("prompt_qtokens_count", "?")
        print(f"  {cap:>6}  {qtok:>10}   ({t:.0f}s)")
        results.append((cap, qtok))
    git_restore(F_PLAN)
    return results

# ═══════════════════════════════════════════════════════════════
#  13. 泛化折叠阈值: cluster.count >= N (同时改两处)
#      低阈值 → 折叠更激进(压制更多),高阈值 → 折叠更保守
# ═══════════════════════════════════════════════════════════════
def sweep_pattern_collapse_threshold():
    print("\n" + "="*60)
    print("  collapsedPatternSummaries 折叠阈值扫测 (>= N 触发折叠)")
    print("  指标: preparer_suppressed (被折叠的任务数), preparer_coverage")
    print("  期望: suppressed ≥ 4 (有效折叠哈希噪声), coverage 不降")
    print("="*60)
    print(f"  {'threshold':>10}  {'suppressed':>11}  {'coverage':>10}  {'output':>7}")
    print(f"  {'-'*10}  {'-'*11}  {'-'*10}  {'-'*7}")

    original = read(F_PLAN)
    # 两处同时改: guard tasks.count >= 4 和 cluster.count >= 4
    ANCHOR1 = "        guard tasks.count >= 4 else { return ([], []) }"
    ANCHOR2 = "        for (pattern, cluster) in clusters where cluster.count >= 4 {"
    results = []
    for thr in [2, 3, 4, 5, 6, 8]:
        mod = original
        mod = replace_first(mod, ANCHOR1,
            f"        guard tasks.count >= {thr} else {{ return ([], []) }}")
        mod = replace_first(mod, ANCHOR2,
            f"        for (pattern, cluster) in clusters where cluster.count >= {thr} {{")
        write(F_PLAN, mod)
        m, t = run_metrics()
        sup  = m.get("preparer_suppressed",  "?")
        cov  = float(m.get("preparer_coverage", "nan"))
        out  = m.get("preparer_output",      "?")
        print(f"  {thr:>10}  {sup:>11}  {cov:>10.4f}  {out:>7}   ({t:.0f}s)")
        results.append((thr, sup, cov, out))
    git_restore(F_PLAN)
    return results

# ═══════════════════════════════════════════════════════════════
#  14. strongToken 分数乘数 (× N)
#      越大 → 命中强 token 的候选分越高 → 强 token 候选优先进
# ═══════════════════════════════════════════════════════════════
def sweep_strong_token_multiplier():
    print("\n" + "="*60)
    print("  importanceScore strongToken 乘数扫测 (* N)")
    print("  主指标: preparer_coverage; 次指标: tier[high]")
    print("="*60)
    print(f"  {'mult':>8}  {'coverage':>10}  {'H':>4}  {'N':>4}  {'L':>4}")
    print(f"  {'-'*8}  {'-'*10}  {'-'*4}  {'-'*4}  {'-'*4}")

    original = read(F_PLAN)
    ANCHOR = "        score += Double(tokens.intersection(strongTokens).count) * 4.0"
    results = []
    for mult in [1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 8.0, 10.0]:
        modified = replace_first(original, ANCHOR,
            f"        score += Double(tokens.intersection(strongTokens).count) * {mult}")
        write(F_PLAN, modified)
        m, t = run_metrics()
        cov = float(m.get("preparer_coverage", "nan"))
        h   = m.get("preparer_tier_high",  "?")
        n   = m.get("preparer_tier_normal", "?")
        l   = m.get("preparer_tier_low",   "?")
        print(f"  {mult:>8.1f}  {cov:>10.4f}  {h:>4}  {n:>4}  {l:>4}   ({t:.0f}s)")
        results.append((mult, cov, h, n, l))
    git_restore(F_PLAN)
    return results

# ═══════════════════════════════════════════════════════════════
#  15. signalWeights["project-token"] 权重
#      影响: 含 "project-token" 信号的候选排名
# ═══════════════════════════════════════════════════════════════
def sweep_project_token_weight():
    print("\n" + "="*60)
    print("  signalWeights[\"project-token\"] 扫测")
    print("  主指标: preparer_coverage + tier[high]")
    print("="*60)
    print(f"  {'ptWeight':>10}  {'coverage':>10}  {'H':>4}  {'N':>4}  {'L':>4}")
    print(f"  {'-'*10}  {'-'*10}  {'-'*4}  {'-'*4}  {'-'*4}")

    original = read(F_PLAN)
    ANCHOR = '        "project-token": 3.0,'
    results = []
    for w in [1.0, 1.5, 2.0, 2.5, 3.0, 4.0, 5.0, 6.0]:
        modified = replace_first(original, ANCHOR, f'        "project-token": {w},')
        write(F_PLAN, modified)
        m, t = run_metrics()
        cov = float(m.get("preparer_coverage", "nan"))
        h   = m.get("preparer_tier_high",  "?")
        n   = m.get("preparer_tier_normal", "?")
        l   = m.get("preparer_tier_low",   "?")
        print(f"  {w:>10.1f}  {cov:>10.4f}  {h:>4}  {n:>4}  {l:>4}   ({t:.0f}s)")
        results.append((w, cov, h, n, l))
    git_restore(F_PLAN)
    return results

# ═══════════════════════════════════════════════════════════════
#  MAIN
# ═══════════════════════════════════════════════════════════════
def main():
    print("\n" + "="*60)
    print("  SimpleZip AI 参数扫测驱动")
    print("  基线先跑一次确认环境 ...")
    print("="*60)
    baseline, t = run_metrics()
    print(f"  基线指标 ({t:.0f}s):")
    for k, v in sorted(baseline.items()):
        print(f"    {k:40s} = {v}")

    all_results = {}
    all_results["feedback_penalty"]        = sweep_feedback_penalty()
    all_results["recency_half_life"]       = sweep_recency_half_life()
    all_results["startup_recency"]         = sweep_startup_recency()
    all_results["tag_decay"]               = sweep_tag_decay()
    all_results["tag_neg_cap"]             = sweep_tag_neg_cap()
    all_results["suppress_halflife"]       = sweep_suppress_halflife()
    all_results["learning_halflife"]       = sweep_learning_halflife()
    all_results["strong_negative"]         = sweep_strong_negative()
    # ── 新维度: AIVirtualFolderPlan 参数 + prompt 调优 ──────────────────────
    all_results["max_candidates"]          = sweep_max_candidates()
    all_results["importance_high_thresh"]  = sweep_importance_high_threshold()
    all_results["importance_low_thresh"]   = sweep_importance_low_threshold()
    all_results["query_tokens_cap"]        = sweep_query_tokens_cap()
    all_results["pattern_collapse_thresh"] = sweep_pattern_collapse_threshold()
    all_results["strong_token_mult"]       = sweep_strong_token_multiplier()
    all_results["project_token_weight"]    = sweep_project_token_weight()

    # ── 最终工作区验证 ──
    print("\n" + "="*60)
    print("  扫测完毕，验证工作区已恢复 ...")
    r = subprocess.run(["git", "status", "--short"], cwd=REPO,
                       capture_output=True, text=True)
    print(r.stdout or "  (clean - 无改动)")

    print("\n" + "="*60)
    print("  推荐参数汇总 (扫测数据):")
    print("  [需手动看上方各 sweep 表格选最优值]")
    print("="*60)

if __name__ == "__main__":
    main()
