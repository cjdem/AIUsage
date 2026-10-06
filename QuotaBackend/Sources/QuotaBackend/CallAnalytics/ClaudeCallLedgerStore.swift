import Foundation
import CryptoKit

/// 持久化最小事件账本。文件复制、裁剪、时区和 agent 重分类不改变事件身份。
/// 仅由 CallAnalyticsEngine actor 访问。
final class ClaudeCallLedgerStore {
    private struct EntryKey: Hashable {
        let kind: CallKind
        let name: String
        let server: String?
        let agent: String?
    }
    private struct Archive: Codable {
        var version = 2
        var calls: [String: ClaudeCallRecord] = [:]
        var invocations: [String: ClaudeInvocationRecord] = [:]
        var legacy: [String: CallAnalyticsDayBucket] = [:]
        var migratedAt = Date()
        var migrationTimeZone: String
        var fileInvocations: [String: String]?
        var pendingOutcomes: [String: Bool]?
    }
    private struct VersionOne: Codable {
        let version: Int
        let files: [String: [String: CallAnalyticsDayBucket]]
        let legacyResidual: [String: CallAnalyticsDayBucket]?
    }
    private let url: URL
    private var cached: Archive?
    private var files: [String: ClaudeCallEventSource.FileState] = [:]
    private var displayTimeZone = TimeZone.current
    private var derived: (zone: String, days: [String: CallAnalyticsDayBucket], hasLegacy: Bool)?

    init(homeDirectory: String) {
        // 原路径上原子升级 schema，避免旧程序数据被当成另一份历史重复导入。
        url = URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent(".config/aiusage/usage-archive/claude-call-ledger-v1.json")
    }

    func collect(source: ClaudeCallEventSource, legacy: [String: CallAnalyticsDayBucket]) throws
        -> (days: [String: CallAnalyticsDayBucket], status: CallSourceStatus) {
        displayTimeZone = source.timeZone
        var archive: Archive
        var changed = false
        if let cached { archive = cached }
        else if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            let version = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["version"] as? Int
            if version == 2 { archive = try JSONDecoder().decode(Archive.self, from: data) }
            else if version == 1 {
                let old = try JSONDecoder().decode(VersionOne.self, from: data)
                let oldDays = Self.merge(old.files.values.reduce([:]) { Self.merge($0, $1) }, old.legacyResidual ?? [:])
                archive = Archive(legacy: Self.merge(oldDays, Self.residual(legacy: legacy, current: oldDays)),
                                  migrationTimeZone: source.timeZone.identifier)
                changed = true
            } else { throw ProviderError("unsupported_archive", "Unsupported Claude call ledger") }
        } else {
            archive = Archive(legacy: legacy.filter { !$0.value.isEmpty }, migrationTimeZone: source.timeZone.identifier)
            changed = true
        }
        let resolver = ClaudeLogDirectoryResolver(homeDirectory: source.homeDirectory, environment: source.environment)
        let available = resolver.projectRoots.contains { FileManager.default.fileExists(atPath: $0) }
        let sessionFiles = resolver.sessionFiles()
        let existingFiles = Set(sessionFiles)
        var nextFiles = files.filter { existingFiles.contains($0.key) }
        var fileInvocations = archive.fileInvocations ?? [:]
        var pendingOutcomes = archive.pendingOutcomes ?? [:]
        var errorCode: String?
        for file in sessionFiles {
            do {
                let result = try source.scan(file: file, previous: files[file])
                if let code = result.errorCode { errorCode = code; continue }
                nextFiles[file] = result.state
                guard result.changed else { continue }
                for (id, call) in result.state.calls {
                    archive.calls[id] = archive.calls[id].map { ClaudeCallEventSource.merged($0, call) } ?? call
                }
                // 结果可单独迟到或先恢复；先存最小结果字段，扫描后统一配对。
                pendingOutcomes.merge(result.state.outcomes) { _, new in new }
                if var invocation = result.state.invocation {
                    let fileID = SHA256.hash(data: Data(file.utf8)).map { String(format: "%02x", $0) }.joined()
                    if !result.state.hasStableSessionID, let previousID = fileInvocations[fileID] {
                        invocation = ClaudeInvocationRecord(id: previousID, agent: invocation.agent, timestamp: invocation.timestamp)
                    }
                    fileInvocations[fileID] = invocation.id
                    if let old = archive.invocations[invocation.id] {
                        invocation.timestamp = min(old.timestamp, invocation.timestamp)
                        if invocation.agent == "subagent", old.agent != "subagent" { invocation.agent = old.agent }
                    }
                    archive.invocations[invocation.id] = invocation
                }
                changed = true
            } catch { errorCode = "session_unreadable" }
        }
        for (id, success) in pendingOutcomes where archive.calls[id] != nil {
            archive.calls[id]?.success = success
            pendingOutcomes.removeValue(forKey: id)
        }
        archive.fileInvocations = fileInvocations
        archive.pendingOutcomes = pendingOutcomes
        let display: (zone: String, days: [String: CallAnalyticsDayBucket], hasLegacy: Bool)
        if !changed, let derived, derived.zone == source.timeZone.identifier { display = derived }
        else {
            let residual = Self.legacyResidual(archive)
            display = (source.timeZone.identifier,
                Self.merge(ClaudeCallEventSource.buckets(calls: archive.calls.values, invocations: archive.invocations.values,
                    timeZone: source.timeZone), residual), !residual.isEmpty)
        }
        if changed { try ClaudeSubscriptionStore().write(JSONEncoder().encode(archive), to: url) }
        cached = archive
        files = nextFiles
        derived = display
        // 聚合旧档没有事件 ID。显示保留的未识别残差，不能宣称精确去重。
        if errorCode == nil, display.hasLegacy { errorCode = "legacy_identity_unknown" }
        return (display.days, CallSourceStatus(source: .claude, available: available,
            eventCount: display.days.values.flatMap(\.entries).reduce(0) { $0 + $1.count },
            filesScanned: sessionFiles.count, errorCode: errorCode))
    }

    func retainedDays(legacy: [String: CallAnalyticsDayBucket]) -> [String: CallAnalyticsDayBucket] {
        if let derived, derived.zone == displayTimeZone.identifier { return derived.days }
        return cached.map { Self.days($0, timeZone: displayTimeZone) } ?? legacy
    }

    private static func days(_ archive: Archive, timeZone: TimeZone) -> [String: CallAnalyticsDayBucket] {
        merge(ClaudeCallEventSource.buckets(calls: archive.calls.values, invocations: archive.invocations.values, timeZone: timeZone),
              legacyResidual(archive))
    }

    private static func legacyResidual(_ archive: Archive) -> [String: CallAnalyticsDayBucket] {
        // 迁移前时间的恢复记录参与动态协调；迁移后新调用始终独立增加。
        // 旧日键保持迁移时口径，不在切换时区后重新相加。
        guard !archive.legacy.isEmpty else { return [:] }
        var result = archive.legacy
        let lower = CallAnalyticsClock(timeZone: TimeZone(secondsFromGMT: -12 * 3600)!)
        let upper = CallAnalyticsClock(timeZone: TimeZone(secondsFromGMT: 14 * 3600)!)
        let utc = CallAnalyticsClock(timeZone: TimeZone(secondsFromGMT: 0)!)
        let clock = CallAnalyticsClock(timeZone: TimeZone(identifier: archive.migrationTimeZone) ?? TimeZone(secondsFromGMT: 0)!)
        func candidateDays(_ date: Date) -> [String] {
            let preferred = clock.dayKey(date)
            // 合法 UTC 偏移覆盖最多三个日期，避免每条事件遍历全部历史日。
            return Set([lower.dayKey(date), utc.dayKey(date), upper.dayKey(date)])
                .filter { result[$0] != nil }.sorted {
                if $0 == $1 { return false }
                if $0 == preferred { return true }; if $1 == preferred { return false }; return $0 < $1
            }
        }
        for call in archive.calls.values.filter({ $0.timestamp <= archive.migratedAt }).sorted(by: { $0.id < $1.id }) {
            for day in candidateDays(call.timestamp) {
                guard let index = result[day]?.entries.firstIndex(where: {
                    $0.count > 0 && $0.kind == call.kind && $0.name == call.name && $0.server == call.server &&
                    ($0.agent == call.agent || $0.agent == nil || $0.agent == "subagent")
                }) else { continue }
                result[day]!.entries[index].count -= 1
                if let success = call.success {
                    result[day]!.entries[index].outcomeKnownCount = max(0, result[day]!.entries[index].outcomeKnownCount - 1)
                    if success { result[day]!.entries[index].successCount = max(0, result[day]!.entries[index].successCount - 1) }
                }
                break
            }
        }
        for invocation in archive.invocations.values.filter({ $0.timestamp <= archive.migratedAt }).sorted(by: { $0.id < $1.id }) {
            for day in candidateDays(invocation.timestamp) {
                guard let index = result[day]?.agentInvocations.firstIndex(where: {
                    $0.count > 0 && ($0.agent == invocation.agent || $0.agent == "subagent")
                }), let old = result[day]?.agentInvocations[index] else { continue }
                result[day]!.agentInvocations[index] = AgentInvocationCount(source: .claude, agent: old.agent, count: old.count - 1)
                break
            }
        }
        for day in result.keys {
            result[day]?.entries.removeAll { $0.count <= 0 }
            if let entries = result[day]?.entries {
                // 无事件身份的残差不能可靠配对结果或计时，保留次数，不制造成功率。
                result[day]?.entries = entries.map {
                    CallAnalyticsEntry(source: .claude, kind: $0.kind, name: $0.name, server: $0.server,
                                       agent: $0.agent, dayKey: $0.dayKey, count: $0.count)
                }
            }
            result[day]?.agentInvocations.removeAll { $0.count <= 0 }
            if result[day]?.entries.isEmpty == true, result[day]?.agentInvocations.isEmpty == true { result.removeValue(forKey: day) }
        }
        return result
    }

    private static func merge(_ a: [String: CallAnalyticsDayBucket], _ b: [String: CallAnalyticsDayBucket]) -> [String: CallAnalyticsDayBucket] {
        var result = a
        for (day, bucket) in b {
            result[day, default: .empty].entries.append(contentsOf: bucket.entries)
            result[day, default: .empty].agentInvocations.append(contentsOf: bucket.agentInvocations)
        }
        for day in b.keys {
            guard let bucket = result[day] else { continue }
            var entries: [EntryKey: CallAnalyticsEntry] = [:]
            for entry in bucket.entries {
                let key = EntryKey(kind: entry.kind, name: entry.name, server: entry.server, agent: entry.agent)
                if var value = entries[key] {
                    value.count += entry.count
                    value.outcomeKnownCount += entry.outcomeKnownCount
                    value.successCount += entry.successCount
                    value.durationSampleCount += entry.durationSampleCount
                    value.durationMsTotal += entry.durationMsTotal
                    entries[key] = value
                } else { entries[key] = entry }
            }
            var agents: [String: Int] = [:]
            for inv in bucket.agentInvocations { agents[inv.agent, default: 0] += inv.count }
            result[day] = CallAnalyticsDayBucket(entries: Array(entries.values),
                agentInvocations: agents.map { AgentInvocationCount(source: .claude, agent: $0.key, count: $0.value) })
        }
        return result
    }

    private static func residual(legacy: [String: CallAnalyticsDayBucket], current: [String: CallAnalyticsDayBucket]) -> [String: CallAnalyticsDayBucket] {
        var result: [String: CallAnalyticsDayBucket] = [:]
        for (day, bucket) in legacy {
            let now = current[day] ?? .empty
            let entries = CallAnalyticsEngine.residualEntries(legacy: bucket.entries, ledger: now.entries)
            var oldAgents: [String: Int] = [:], newAgents: [String: Int] = [:]
            for inv in bucket.agentInvocations { oldAgents[inv.agent, default: 0] += inv.count }
            for inv in now.agentInvocations { newAgents[inv.agent, default: 0] += inv.count }
            let invocations = oldAgents.compactMap { agent, count -> AgentInvocationCount? in
                let remaining = max(0, count - (newAgents[agent] ?? 0))
                return remaining > 0 ? AgentInvocationCount(source: .claude, agent: agent, count: remaining) : nil
            }
            if !entries.isEmpty || !invocations.isEmpty { result[day] = CallAnalyticsDayBucket(entries: entries, agentInvocations: invocations) }
        }
        return result
    }
}
