import Foundation
import QuotaBackend

// 只替换日志入口与文件边界；直接编译正式日折叠及永久归档源码。
struct ProxyRequestLog {
    let id: String
    let timestamp: Date
    let upstreamModel: String
    let responseMessageId: String?
    let estimatedCostUSD: Double
    let tokensInput = 10, tokensOutput = 5, tokensCacheRead = 2, tokensCacheCreation = 3, tokensCache = 5
    let pricingResolved = true
    let sessionId: String? = "session", conversationId: String? = nil, clientSurface: String? = "claude_code"
    let claudeModel = "sonnet"
}
extension String { var nilIfBlank: String? { isEmpty ? nil : self } }
enum ProxyPersistence {
    static let queue = DispatchQueue(label: "archive-regression")
    static let encoder = JSONEncoder()
    static func dayInterval(for day: String) -> DateInterval? {
        let offset: Double = day == "2026-10-05" ? -86400 : 0
        return DateInterval(start: Date(timeIntervalSince1970: 1791244800 + offset), duration: 86400)
    }
}
@MainActor final class ProxyViewModel {
    struct NodeType { let isCodex: Bool }
    struct Configuration { let id: String; let nodeType: NodeType }
    var configurations: [Configuration] = []
    var recentLogs: [String: [ProxyRequestLog]] = [:]
    func shardDayKey(_ timestamp: Date) -> String { "2026-10-06" }
}

@main struct ArchiveRegression {
    @MainActor static func main() async throws {
        let taskHome = FileManager.default.homeDirectoryForCurrentUser
        precondition(taskHome.lastPathComponent == "home" && taskHome.deletingLastPathComponent().lastPathComponent.hasPrefix("aiusage-archive-regression."))
        let day = "2026-10-06"
        let date = ProxyPersistence.dayInterval(for: day)!.start.addingTimeInterval(300)
        let sameModel = CommandLine.arguments.contains("--same-model")
        let vm = ProxyViewModel()
        vm.configurations = [.init(id: "removed", nodeType: .init(isCodex: false)), .init(id: "kept", nodeType: .init(isCodex: false)), .init(id: "codex", nodeType: .init(isCodex: true))]
        let removed = ProxyRequestLog(id: "removed", timestamp: date, upstreamModel: "sonnet", responseMessageId: "msg_removed", estimatedCostUSD: 0.003)
        let kept = ProxyRequestLog(id: "kept", timestamp: date, upstreamModel: sameModel ? "sonnet" : "opus", responseMessageId: "msg_kept", estimatedCostUSD: 0.007)
        let codex = ProxyRequestLog(id: "codex", timestamp: date, upstreamModel: "gpt", responseMessageId: nil, estimatedCostUSD: 0.02)
        vm.recentLogs = ["removed": [removed], "kept": [kept], "codex": [codex]]
        vm.foldDaysIntoUsageArchive([day])
        func check(_ store: ProxyUsageArchiveStore, expectedRequests: Int, expectedCost: Double) {
            let bucket = store.days(.claude)[day]!
            let aggregates = bucket.models.values
            precondition(aggregates.reduce(0) { $0 + $1.requests } == expectedRequests)
            precondition(aggregates.reduce(0) { $0 + $1.totalTokens } == expectedRequests * 20)
            precondition(abs(aggregates.reduce(0) { $0 + $1.costUSD } - expectedCost) < 0.0000001)
            precondition(aggregates.reduce(0) { $0 + $1.surfaces["claude_code"]!.requests } == expectedRequests)
            precondition(aggregates.reduce(0) { $0 + $1.sessions["session"]!["sonnet"]!.inputTokens } == expectedRequests * 10)
            precondition(aggregates.flatMap { $0.responseMessageIds }.contains("msg_removed"))
        }
        check(.shared, expectedRequests: 2, expectedCost: 0.01)
        // 删除前冻结，重复冻结幂等；节点随后消失。
        vm.retainUsageBeforeRemovingLogs(["removed": [removed]])
        vm.retainUsageBeforeRemovingLogs(["removed": [removed]])
        vm.recentLogs.removeValue(forKey: "removed")
        vm.configurations.removeAll { $0.id == "removed" }
        for _ in 0..<3 { vm.foldDaysIntoUsageArchive([day]); check(.shared, expectedRequests: 2, expectedCost: 0.01) }
        // 恢复旧分片仍不重复加账，即使该节点已不在配置清单中。
        vm.recentLogs["removed"] = [removed]
        vm.foldDaysIntoUsageArchive([day])
        check(.shared, expectedRequests: 2, expectedCost: 0.01)
        vm.recentLogs.removeValue(forKey: "removed")
        let new = ProxyRequestLog(id: "new", timestamp: date, upstreamModel: kept.upstreamModel, responseMessageId: "msg_new", estimatedCostUSD: 0.011)
        vm.recentLogs["kept"]!.append(new)
        vm.foldDaysIntoUsageArchive([day])
        check(.shared, expectedRequests: 3, expectedCost: 0.021)
        ProxyPersistence.queue.sync {}
        let reloaded = ProxyUsageArchiveStore()
        check(reloaded, expectedRequests: 3, expectedCost: 0.021)
        precondition(reloaded.days(.claude)[day]!.retainedRequestIds == ["removed"])
        // 日键变化不能把同一请求再次冻结到另一日。
        var otherDay = ProxyUsageDay()
        otherDay.models["test"] = ProxyUsageModelAgg(inputTokens: 1, requests: 1)
        reloaded.replaceDays(.claude, days: ["2026-10-05": otherDay])
        reloaded.retainLogs(.claude, logs: [removed], dayKeyForLog: { _ in "2026-10-05" })
        precondition(reloaded.days(.claude)["2026-10-05"]!.retainedRequestIds.isEmpty)
        // 清空单节点后新请求、清空所有日志后新请求均保留历史。
        vm.retainUsageBeforeRemovingLogs(["kept": vm.recentLogs["kept"]!])
        vm.recentLogs["kept"] = []
        let later = ProxyRequestLog(id: "later", timestamp: date, upstreamModel: "haiku", responseMessageId: "msg_later", estimatedCostUSD: 0.013)
        vm.recentLogs["kept"] = [later]
        vm.foldDaysIntoUsageArchive([day])
        check(.shared, expectedRequests: 4, expectedCost: 0.034)
        vm.retainUsageBeforeRemovingLogs(vm.recentLogs)
        vm.recentLogs.removeAll()
        vm.foldDaysIntoUsageArchive([day])
        check(.shared, expectedRequests: 4, expectedCost: 0.034)
        vm.recentLogs = ["kept": [later]]
        vm.foldDaysIntoUsageArchive([day])
        check(.shared, expectedRequests: 4, expectedCost: 0.034)
        precondition(ProxyUsageArchiveStore.shared.days(.codex)[day]!.models["gpt"]!.requests == 1)
        ProxyPersistence.queue.sync {}
        // 旧 v1 日桶无需迁移；新字段对后端解码透明，代理响应不会重判直连。
        let old = try JSONDecoder().decode(ProxyUsageDay.self, from: Data(#"{"models":{}}"#.utf8))
        precondition(old.retainedModels.isEmpty && old.retainedRequestIds.isEmpty)
        let project = taskHome.appendingPathComponent(".claude/projects/test")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        var rows = Data()
        for id in ["msg_removed", "msg_kept", "msg_new", "msg_later"] {
            let row: [String: Any] = ["type": "assistant", "timestamp": ISO8601DateFormatter().string(from: date), "message": ["id": id, "model": "alias", "usage": ["input_tokens": 10, "output_tokens": 5, "cache_read_input_tokens": 2, "cache_creation_input_tokens": 3]]]
            rows.append(try JSONSerialization.data(withJSONObject: row)); rows.append(10)
        }
        try rows.write(to: project.appendingPathComponent("session.jsonl"))
        let usage = try await ClaudeProvider(homeDirectory: taskHome.path, timeZone: TimeZone(secondsFromGMT: 0)!, environment: [:]).fetchUsage()
        precondition(usage.extra["overall.proxyTokens"]?.value as? Int == 80)
        precondition(usage.extra["overall.duplicateRowsRemoved"]?.value as? Int == 4)
        precondition(usage.extra["overall.totalTokens"]?.value as? Int == 80)
        print("PASS: \(sameModel ? "同模型" : "不同模型") 删除/清理/恢复/新请求/重载、费用与去重身份、surface/session 维度")
    }
}
