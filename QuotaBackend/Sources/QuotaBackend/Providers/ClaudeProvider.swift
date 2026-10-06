import Foundation

// MARK: - Claude Provider
// 代理采用请求时冻结费用；非代理读取 Code 本地 Token，按响应标识去重，不估算订阅费用。

public struct ClaudeProvider: ProviderFetcher {
    public let id = "claude"
    public let displayName = "Claude"
    public let description = "Claude proxy costs and local non-proxy token ledger"

    /// 归档为空时的回退天数（用于 trailing 时间线长度）。
    static let defaultScanDays = 30

    let homeDirectory: String
    let timeZone: TimeZone
    let environment: [String: String]

    public init(homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
                timeZone: TimeZone = .current,
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.homeDirectory = homeDirectory
        self.timeZone = timeZone
        self.environment = environment
    }

    public func fetchUsage() async throws -> ProviderUsage {
        let now = Date()

        let proxy = try loadProxyUsage()
        let records = try await ClaudeUsageLedger.shared.scan(homeDirectory: homeDirectory, environment: environment, timeZone: timeZone)
        var archivedDays = proxy.days
        var duplicates = 0
        var uncertainTokens = 0
        var uncertainRows = 0
        // 旧日归档未记录时区。用同一时刻在合法 UTC 偏移两端的日期覆盖候选，
        // 不能因系统时区变化将旧代理行重新判成直连。
        let earliestClock = CallAnalyticsClock(timeZone: TimeZone(secondsFromGMT: -12 * 3600)!)
        let latestClock = CallAnalyticsClock(timeZone: TimeZone(secondsFromGMT: 14 * 3600)!)
        let utcClock = CallAnalyticsClock(timeZone: TimeZone(secondsFromGMT: 0)!)
        for row in records {
            let rowDay = dayKey(row.timestamp)
            if proxy.responseIDs.contains(row.messageID) { duplicates += 1; continue }
            let firstPossibleDay = earliestClock.dayKey(row.timestamp)
            let lastPossibleDay = latestClock.dayKey(row.timestamp)
            if proxy.uncertainDays.contains(firstPossibleDay) || proxy.uncertainDays.contains(lastPossibleDay) ||
                proxy.uncertainDays.contains(utcClock.dayKey(row.timestamp)) {
                uncertainTokens += row.total
                uncertainRows += 1
                continue
            }
            let name = row.model + " (Non-Proxy)"
            var bucket = archivedDays[rowDay] ?? .empty
            var model = bucket.models[name] ?? ClaudeModelAggregate(model: name)
            model.inputTokens += row.input
            model.outputTokens += row.output
            model.cacheReadTokens += row.cacheRead
            model.cacheCreateTokens += row.cacheCreate
            model.totalTokens += row.total
            bucket.models[name] = model
            bucket.totalTokens += row.total
            bucket.usageRows += 1
            archivedDays[rowDay] = bucket
        }
        guard !archivedDays.isEmpty else {
            throw ProviderError("no_usage_data", "No Claude local usage recorded yet")
        }

        let todayKey = dayKey(now)
        let weekRange = currentWeekRange(now)
        let monthKey = monthKeyStr(now)

        let today = archivedDays[todayKey] ?? .empty
        let currentWeek = aggregateDays(archivedDays) { weekRange.dayKeys.contains($0) }
        let currentMonth = aggregateDays(archivedDays) { $0.hasPrefix(monthKey) }
        let overall = aggregateDays(archivedDays) { _ in true }
        let archiveDayCount = archivedDayCount(archivedDays, now: now, fallback: max(archivedDays.count, Self.defaultScanDays))
        let overallRangeLabel = archivedRangeLabel(archivedDays, fallback: "All local history")

        var extra: [String: AnyCodable] = [:]
        extra["today.estimatedCostUsd"] = AnyCodable(roundUsd(today.estimatedCostUsd))
        extra["today.totalTokens"] = AnyCodable(today.totalTokens)
        extra["today.key"] = AnyCodable(todayKey)

        extra["currentWeek.estimatedCostUsd"] = AnyCodable(roundUsd(currentWeek.estimatedCostUsd))
        extra["currentWeek.totalTokens"] = AnyCodable(currentWeek.totalTokens)
        extra["currentWeek.key"] = AnyCodable("\(weekRange.start)..\(weekRange.end)")

        extra["currentMonth.estimatedCostUsd"] = AnyCodable(roundUsd(currentMonth.estimatedCostUsd))
        extra["currentMonth.totalTokens"] = AnyCodable(currentMonth.totalTokens)
        extra["currentMonth.key"] = AnyCodable(monthKey)

        // 代理日归档无小时粒度，hourly 留空；热力图与统计页按日呈现。
        extra["timeline.hourly"] = AnyCodable([AnyCodable]())
        extra["timeline.daily"] = AnyCodable(encodeTimeline(trailingDailyTimeline(bucketsByDay: archivedDays, now: now, dayCount: archiveDayCount)))

        // 仅看「今天」：历史日的 0 成本（旧模型名/当时未配价）不应永久纠缠——成本历史不可篡改，
        // 只提示当前仍在产生「有 token 但 cost==0」流量的模型，引导用户给当前节点配价。
        let unpricedModels = today.unpricedModels
        extra["overall.estimatedCostUsd"] = AnyCodable(roundUsd(overall.estimatedCostUsd))
        extra["overall.totalTokens"] = AnyCodable(overall.totalTokens)
        extra["overall.usageRows"] = AnyCodable(overall.usageRows)
        extra["overall.duplicateRowsRemoved"] = AnyCodable(duplicates)
        extra["overall.uncertainTokens"] = AnyCodable(uncertainTokens)
        extra["overall.uncertainRows"] = AnyCodable(uncertainRows)
        extra["overall.proxyTokens"] = AnyCodable(proxy.days.values.reduce(0) { $0 + $1.totalTokens })
        extra["overall.rangeLabel"] = AnyCodable(overallRangeLabel)
        extra["overall.unpricedModels"] = AnyCodable(unpricedModels.sorted().map { AnyCodable($0) })

        extra["currentMonth.models"] = AnyCodable(encodeModelBreakdown(currentMonth))
        extra["today.models"] = AnyCodable(encodeModelBreakdown(today))
        extra["currentWeek.models"] = AnyCodable(encodeModelBreakdown(currentWeek))
        extra["overall.models"] = AnyCodable(encodeModelBreakdown(overall))

        var modelTimelines: [AnyCodable] = []
        let archivedModelNames = Set(archivedDays.values.flatMap { $0.models.keys })
        for modelName in archivedModelNames.sorted() {
            let daily = trailingDailyTimeline(bucketsByDay: archivedDays, now: now, dayCount: archiveDayCount, model: modelName)
            guard !daily.isEmpty else { continue }
            modelTimelines.append(AnyCodable([
                "model": AnyCodable(modelName),
                "hourly": AnyCodable([AnyCodable]()),
                "daily": AnyCodable(encodeTimeline(daily, includeDetail: true))
            ] as [String: AnyCodable]))
        }
        extra["timeline.byModel"] = AnyCodable(modelTimelines)

        var usage = ProviderUsage(provider: id, label: displayName, extra: extra)
        usage.source = SourceInfo(mode: "auto", type: "claude-local-ledger")
        return usage
    }

}
