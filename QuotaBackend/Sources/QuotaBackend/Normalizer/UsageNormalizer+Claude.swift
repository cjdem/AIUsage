import Foundation

extension UsageNormalizer {

    // MARK: - Claude

    static func normalizeClaude(base: inout ProviderSummary, usage: ProviderUsage) -> ProviderSummary {
        let monthUsd   = extraDouble(usage, "currentMonth.estimatedCostUsd") ?? 0
        let weekUsd    = extraDouble(usage, "currentWeek.estimatedCostUsd") ?? 0
        let todayUsd   = extraDouble(usage, "today.estimatedCostUsd") ?? 0
        let overallUsd = extraDouble(usage, "overall.estimatedCostUsd") ?? 0
        let monthTokens = extraInt(usage, "currentMonth.totalTokens") ?? 0
        let weekTokens  = extraInt(usage, "currentWeek.totalTokens") ?? 0
        let todayTokens = extraInt(usage, "today.totalTokens") ?? 0
        let overallTokens = extraInt(usage, "overall.totalTokens") ?? 0
        let usageRows   = extraInt(usage, "overall.usageRows") ?? 0
        let dupRows     = extraInt(usage, "overall.duplicateRowsRemoved") ?? 0
        let unpricedModels = extraStringArray(usage, "overall.unpricedModels")
        let uncertainTokens = extraInt(usage, "overall.uncertainTokens") ?? 0
        let hasProxy = (extraInt(usage, "overall.proxyTokens") ?? overallTokens) > 0

        let rawModelItems = (usage.extra["currentMonth.models"]?.value as? [AnyCodable]) ?? []
        let topModels: [ModelInfo] = rawModelItems
            .prefix(5)
            .compactMap { item in
                guard let m = item.value as? [String: AnyCodable],
                      let model = m["model"]?.value as? String,
                      let cost = m["estimatedCostDisplay"]?.value as? String else { return nil }
                let tokens: Int
                switch m["totalTokens"]?.value {
                case let v as Int: tokens = v
                case let v as Double: tokens = Int(v)
                default: tokens = 0
                }
                return ModelInfo(label: model, value: formatInt(tokens), note: model.hasSuffix(" (Non-Proxy)") ? "—" : cost)
            }

        let modelBreakdown = extractModelBreakdown(usage, "currentMonth.models")
        let modelBreakdownToday = extractModelBreakdown(usage, "today.models")
        let modelBreakdownWeek = extractModelBreakdown(usage, "currentWeek.models")
        let modelBreakdownOverall = extractModelBreakdown(usage, "overall.models")

        let modelTimelines: [ModelTimelineSeries] = extraModelTimelines(usage, "timeline.byModel")

        base.accountLabel = preferredAccountEmail(usage)
        base.category = ProviderCategory.localCost
        base.status = "healthy"
        base.statusLabel = "Healthy"
        base.headline = HeadlineInfo(
            eyebrow: "Local token ledger",
            primary: hasProxy ? formatCurrency(monthUsd) : formatInt(monthTokens),
            secondary: "\(formatInt(monthTokens)) tokens this month",
            supporting: hasProxy ? "Proxy costs • Week \(formatCurrency(weekUsd)) • Today \(formatCurrency(todayUsd))" : "Non-proxy tokens • Cost not tracked"
        )
        base.metrics = [
            MetricInfo(label: "Today",      value: hasProxy ? formatCurrency(todayUsd) : formatInt(todayTokens),  note: hasProxy ? "\(formatInt(todayTokens)) tokens" : "Tokens"),
            MetricInfo(label: "This Week",  value: hasProxy ? formatCurrency(weekUsd) : formatInt(weekTokens),   note: hasProxy ? "\(formatInt(weekTokens)) tokens" : "Tokens"),
            MetricInfo(label: "This Month", value: hasProxy ? formatCurrency(monthUsd) : formatInt(monthTokens),  note: hasProxy ? "\(formatInt(monthTokens)) tokens" : "Tokens"),
            MetricInfo(label: "Scanned Calls", value: formatInt(usageRows),   note: "\(formatInt(dupRows)) proxy responses excluded")
        ]
        if uncertainTokens > 0 {
            base.metrics.append(MetricInfo(label: "Unverified Tokens", value: formatInt(uncertainTokens), note: "Excluded from totals"))
        }
        base.windows = []
        base.costSummary = CostSummaryInfo(
            today: CostPeriod(usd: todayUsd, tokens: todayTokens, rangeLabel: extraString(usage, "today.key") ?? "Today"),
            week:  CostPeriod(usd: weekUsd,  tokens: weekTokens,  rangeLabel: extraString(usage, "currentWeek.key") ?? "This week"),
            month: CostPeriod(usd: monthUsd, tokens: monthTokens, rangeLabel: extraString(usage, "currentMonth.key") ?? "This month"),
            overall: CostPeriod(usd: overallUsd, tokens: overallTokens, rangeLabel: "Overall"),
            timeline: CostTimelineInfo(
                hourly: extraCostTimeline(usage, "timeline.hourly"),
                daily: extraCostTimeline(usage, "timeline.daily")
            ),
            modelBreakdown: modelBreakdown.isEmpty ? nil : modelBreakdown,
            modelBreakdownToday: modelBreakdownToday.isEmpty ? nil : modelBreakdownToday,
            modelBreakdownWeek: modelBreakdownWeek.isEmpty ? nil : modelBreakdownWeek,
            modelBreakdownOverall: modelBreakdownOverall.isEmpty ? nil : modelBreakdownOverall,
            modelTimelines: modelTimelines.isEmpty ? nil : modelTimelines
        )
        base.models = topModels.isEmpty ? nil : topModels
        base.nextResetAt = nil
        base.spotlight = "Claude Code local tokens; proxy costs only. Not subscription quota."
        base.unpricedModels = unpricedModels.isEmpty ? nil : unpricedModels
        return base
    }
}
