import Foundation

// MARK: - Usage Track (用量轨道)
// Claude / Codex 用量分两轨：代理（代理归档，模型名带 " (Proxy)" 后缀）与 非代理（本地 JSONL，带 " (Non-Proxy)" 后缀），
// 合并轨同时含两者。统计页用本类型在「合计 / 代理 / 非代理」间切换，靠模型名后缀过滤、显示时剥后缀。

enum UsageTrack: String, CaseIterable, Identifiable {
    case combined
    case proxy
    case nonProxy

    var id: String { rawValue }

    init(storedRawValue: String) {
        switch storedRawValue {
        case "api":
            self = .proxy
        case "subscription":
            self = .nonProxy
        default:
            self = UsageTrack(rawValue: storedRawValue) ?? .combined
        }
    }

    var label: String {
        switch self {
        case .combined:     return L("Combined", "合计", key: "usage_track.combined")
        case .proxy:        return L("Proxy", "代理", key: "usage_track.proxy")
        case .nonProxy:     return L("Non-Proxy", "非代理", key: "usage_track.non_proxy")
        }
    }

    static let proxySuffix = " (Proxy)"
    static let nonProxySuffix = " (Non-Proxy)"

    static func isProxy(_ model: String) -> Bool { model.hasSuffix(proxySuffix) }
    static func isNonProxy(_ model: String) -> Bool { model.hasSuffix(nonProxySuffix) }

    /// 该模型是否属于当前轨（合计恒真）。
    func matches(_ model: String) -> Bool {
        switch self {
        case .combined:     return true
        case .proxy:        return UsageTrack.isProxy(model)
        case .nonProxy:     return UsageTrack.isNonProxy(model)
        }
    }

    /// 去掉轨道后缀，用于在单轨视图里更干净地展示模型名（合计视图保留后缀以区分来源）。
    static func stripSuffix(_ model: String) -> String {
        if isProxy(model) { return String(model.dropLast(proxySuffix.count)) }
        if isNonProxy(model) { return String(model.dropLast(nonProxySuffix.count)) }
        return model
    }
}

// MARK: - CostSummary track filtering

extension CostSummary {
    /// 按轨道过滤：合计原样返回；代理/非代理仅保留对应后缀的模型行，剥掉后缀，
    /// 并据过滤后的模型明细重算各周期总额与时间线（与后端 overall.proxy/nonProxy 一致）。
    func filtered(by track: UsageTrack) -> CostSummary {
        guard track != .combined else { return self }

        let today = Self.filterBreakdown(modelBreakdownToday, track: track)
        let week = Self.filterBreakdown(modelBreakdownWeek, track: track)
        let month = Self.filterBreakdown(modelBreakdown, track: track)
        let overallModels = Self.filterBreakdown(modelBreakdownOverall, track: track)
        let timelines = Self.filterTimelines(modelTimelines, track: track)

        return CostSummary(
            today: Self.period(today, like: self.today),
            week: Self.period(week, like: self.week),
            month: Self.period(month, like: self.month),
            overall: Self.period(overallModels, like: self.overall),
            timeline: Self.timeline(from: timelines),
            modelBreakdown: month.isEmpty ? nil : month,
            modelBreakdownToday: today.isEmpty ? nil : today,
            modelBreakdownWeek: week.isEmpty ? nil : week,
            modelBreakdownOverall: overallModels.isEmpty ? nil : overallModels,
            modelTimelines: timelines.isEmpty ? nil : timelines
        )
    }

    private static func filterBreakdown(
        _ breakdown: [ModelCostBreakdown]?,
        track: UsageTrack
    ) -> [ModelCostBreakdown] {
        let kept = (breakdown ?? []).filter { track.matches($0.model) }
        let totalUsd = kept.reduce(0) { $0 + $1.estimatedCostUsd }
        let totalTokens = kept.reduce(0) { $0 + $1.totalTokens }
        return kept.map { item in
            let pct: Double
            if totalUsd > 0 {
                pct = item.estimatedCostUsd / totalUsd * 100
            } else if totalTokens > 0 {
                pct = Double(item.totalTokens) / Double(totalTokens) * 100
            } else {
                pct = 0
            }
            return ModelCostBreakdown(
                model: UsageTrack.stripSuffix(item.model),
                totalTokens: item.totalTokens,
                inputTokens: item.inputTokens,
                outputTokens: item.outputTokens,
                cacheReadTokens: item.cacheReadTokens,
                cacheCreateTokens: item.cacheCreateTokens,
                estimatedCostUsd: item.estimatedCostUsd,
                percentage: pct
            )
        }
    }

    private static func filterTimelines(
        _ series: [ModelTimelineSeries]?,
        track: UsageTrack
    ) -> [ModelTimelineSeries] {
        (series ?? [])
            .filter { track.matches($0.model) }
            .map { ModelTimelineSeries(model: UsageTrack.stripSuffix($0.model), hourly: $0.hourly, daily: $0.daily) }
    }

    /// 据过滤后的模型明细重算周期总额，保留原周期的标签（rangeLabel）。
    private static func period(_ models: [ModelCostBreakdown], like original: CostPeriod?) -> CostPeriod? {
        guard !models.isEmpty else { return original.map { CostPeriod(usd: 0, tokens: 0, rangeLabel: $0.rangeLabel) } }
        return CostPeriod(
            usd: models.reduce(0) { $0 + $1.estimatedCostUsd },
            tokens: models.reduce(0) { $0 + $1.totalTokens },
            rangeLabel: original?.rangeLabel
        )
    }

    /// 据过滤后的模型时间线重建合并时间线（统计页天数横幅 / 顶部口径用）。
    private static func timeline(from series: [ModelTimelineSeries]) -> CostTimeline? {
        guard !series.isEmpty else { return nil }
        func merge(_ keyPath: KeyPath<ModelTimelineSeries, [CostTimelinePoint]>) -> [CostTimelinePoint] {
            var buckets: [String: (label: String, usd: Double, tokens: Int, input: Int, output: Int, cacheRead: Int, cacheCreate: Int)] = [:]
            for s in series {
                for p in s[keyPath: keyPath] {
                    var c = buckets[p.bucket] ?? (p.label, 0, 0, 0, 0, 0, 0)
                    c.usd += p.usd
                    c.tokens += p.tokens
                    c.input += p.inputTokens ?? 0
                    c.output += p.outputTokens ?? 0
                    c.cacheRead += p.cacheReadTokens ?? 0
                    c.cacheCreate += p.cacheCreateTokens ?? 0
                    buckets[p.bucket] = c
                }
            }
            return buckets
                .map { bucket, value in
                    CostTimelinePoint(
                        bucket: bucket,
                        label: value.label,
                        usd: value.usd,
                        tokens: value.tokens,
                        inputTokens: value.input > 0 ? value.input : nil,
                        outputTokens: value.output > 0 ? value.output : nil,
                        cacheReadTokens: value.cacheRead > 0 ? value.cacheRead : nil,
                        cacheCreateTokens: value.cacheCreate > 0 ? value.cacheCreate : nil
                    )
                }
                .sorted { $0.bucket < $1.bucket }
        }
        return CostTimeline(hourly: merge(\.hourly), daily: merge(\.daily))
    }
}
