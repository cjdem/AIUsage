import XCTest
@testable import QuotaBackend

final class ClaudeUsageLedgerTests: XCTestCase {
    private let zone = TimeZone(secondsFromGMT: 0)!
    private let day = "2026-01-02"

    private func home() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("claude-ledger-tests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func assistant(id: String, output: Int = 5, tool: String? = nil, timestamp: String? = nil) throws -> Data {
        let content: [[String: Any]] = tool.map { [["type": "tool_use", "id": "tool-\(id)", "name": $0, "input": [:]]] } ?? []
        return try JSONSerialization.data(withJSONObject: ["type": "assistant", "timestamp": timestamp ?? "\(day)T12:00:00Z",
            "message": ["id": id, "model": "claude-sonnet", "content": content,
                "usage": ["input_tokens": 10, "output_tokens": output, "cache_read_input_tokens": 20, "cache_creation_input_tokens": 3]]])
    }

    @discardableResult
    private func writeSession(_ rows: [Data], config: URL, name: String = "session") throws -> URL {
        let url = config.appendingPathComponent("projects/test/\(name).jsonl")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var body = Data()
        for row in rows { body.append(row); body.append(0x0A) }
        try body.write(to: url)
        return url
    }

    private func connect(config: URL, home: URL) throws {
        var profile = ClaudeSubscriptionProfile(configDirectory: config.path, name: "测试配置")
        profile.installedCommand = "test-helper"
        try ClaudeSubscriptionStore(root: home.appendingPathComponent(".config/aiusage/claude-subscriptions")).saveProfile(profile)
    }

    private func proxyArchive(home: URL, identified: Bool) throws {
        var model: [String: Any] = ["inputTokens": 10, "outputTokens": 5, "cacheReadTokens": 20,
            "cacheCreateTokens": 3, "costUSD": 1.25, "requests": 1, "pricingResolvedRequests": 1]
        if identified { model["responseMessageIds"] = ["proxy-response"]; model["unidentifiedTokenRequests"] = 0 }
        let url = home.appendingPathComponent(".config/aiusage/usage-archive/proxy-usage-claude-v1.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["version": 1, "updatedAt": "", "days": [day: ["models": ["upstream-model": model]]]]).write(to: url)
    }

    func testRepeatedResponseAndCopiedLogCountOnceAndKeepFinalUsage() async throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent(".claude")
        try writeSession([assistant(id: "response", output: 1), assistant(id: "response", output: 7)], config: config)
        try writeSession([assistant(id: "response", output: 7)], config: config, name: "copied")
        let provider = ClaudeProvider(homeDirectory: root.path, timeZone: zone, environment: [:])
        let usage = try await provider.fetchUsage()
        let summary = UsageNormalizer.normalize(provider: provider, usage: usage)
        XCTAssertEqual(summary.costSummary?.overall?.tokens, 40)
        XCTAssertEqual(summary.costSummary?.modelBreakdownOverall?.first?.model, "claude-sonnet (Non-Proxy)")
        XCTAssertEqual(summary.costSummary?.overall?.usd, 0)
        XCTAssertEqual(summary.headline.supporting, "Non-proxy tokens • Cost not tracked")
        XCTAssertNil(summary.unpricedModels)
    }

    func testTokenHistorySurvivesDeletionAndReload() async throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try writeSession([assistant(id: "response")], config: root.appendingPathComponent(".claude"))
        let first = try await ClaudeUsageLedger().scan(homeDirectory: root.path, environment: [:], timeZone: zone)
        try FileManager.default.removeItem(at: file)
        let restored = try await ClaudeUsageLedger().scan(homeDirectory: root.path, environment: [:], timeZone: zone)
        XCTAssertEqual(first, restored)
        let data = try Data(contentsOf: root.appendingPathComponent(".config/aiusage/usage-archive/claude-token-ledger-v1.json"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("content"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("credential"))
    }

    func testProxyResponseIdentityPreventsDoubleCountingAcrossModelAliases() async throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        try writeSession([assistant(id: "proxy-response"), assistant(id: "direct-response")], config: root.appendingPathComponent(".claude"))
        try proxyArchive(home: root, identified: true)
        let provider = ClaudeProvider(homeDirectory: root.path, timeZone: zone, environment: [:])
        let usage = try await provider.fetchUsage()
        let summary = UsageNormalizer.normalize(provider: provider, usage: usage)
        XCTAssertEqual(summary.costSummary?.overall?.tokens, 76)
        XCTAssertEqual(summary.costSummary?.overall?.usd, 1.25)
        XCTAssertEqual(usage.extra["overall.duplicateRowsRemoved"]?.value as? Int, 1)
        XCTAssertEqual(Set(summary.costSummary?.modelBreakdownOverall?.map(\.model) ?? []),
            ["upstream-model (Proxy)", "claude-sonnet (Non-Proxy)"])
    }

    func testLegacyProxyDayRemainsUnverifiedInsteadOfDoubleCounting() async throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        try writeSession([assistant(id: "proxy-response")], config: root.appendingPathComponent(".claude"))
        try proxyArchive(home: root, identified: false)
        let provider = ClaudeProvider(homeDirectory: root.path, timeZone: zone, environment: [:])
        let usage = try await provider.fetchUsage()
        XCTAssertEqual(usage.extra["overall.uncertainTokens"]?.value as? Int, 38)
        XCTAssertEqual(UsageNormalizer.normalize(provider: provider, usage: usage).costSummary?.overall?.tokens, 38)
        // 后续有可靠响应标识时无需重扫或改账本，自动从待确认中排除代理重复项。
        try proxyArchive(home: root, identified: true)
        let next = try await provider.fetchUsage()
        XCTAssertEqual(next.extra["overall.uncertainTokens"]?.value as? Int, 0)
    }

    func testConnectedProfileDirectoryFeedsTokensCallsAndInventoryWithoutEnvironmentChange() async throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("official-work")
        try connect(config: config, home: root)
        try writeSession([assistant(id: "response", tool: "Read")], config: config)
        let marker = config.appendingPathComponent("skills/test-skill/SKILL.md")
        try FileManager.default.createDirectory(at: marker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("测试".utf8).write(to: marker)
        try Data(#"{"mcpServers":{"test-server":{"command":"test"}}}"#.utf8).write(to: config.appendingPathComponent(".claude.json"))
        let resolver = ClaudeLogDirectoryResolver(homeDirectory: root.path, environment: ["CLAUDE_CONFIG_DIR": config.path + "/projects," + config.path])
        XCTAssertEqual(resolver.configDirectories, [config.path])
        let provider = ClaudeProvider(homeDirectory: root.path, timeZone: zone, environment: [:])
        let usage = try await provider.fetchUsage()
        XCTAssertEqual(UsageNormalizer.normalize(provider: provider, usage: usage).costSummary?.overall?.tokens, 38)
        let snapshot = await CallAnalyticsEngine(homeDirectory: root.path, timeZone: zone, environment: [:]).computeSnapshot(rangeKey: "all", cutoff: nil)
        XCTAssertEqual(snapshot.entries.filter { $0.source == .claude }.reduce(0) { $0 + $1.count }, 1)
        XCTAssertTrue(snapshot.installedSkills.contains(InstalledItem(source: .claude, name: "test-skill")))
        XCTAssertTrue(snapshot.installedMCPServers.contains(InstalledItem(source: .claude, name: "test-server")))
    }

    func testNewDirectoryBackfillsPastCallsAndDeletionKeepsCounts() async throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent(".claude")
        let firstFile = try writeSession([assistant(id: "first", tool: "Read", timestamp: ISO8601DateFormatter().string(from: Date()))], config: config)
        let engine = CallAnalyticsEngine(homeDirectory: root.path, timeZone: zone, environment: [:])
        let initial = await engine.computeSnapshot(rangeKey: "all", cutoff: nil)
        XCTAssertEqual(initial.entries.filter { $0.source == .claude }.reduce(0) { $0 + $1.count }, 1)
        let newConfig = root.appendingPathComponent("official-work")
        try connect(config: newConfig, home: root)
        let newFile = try writeSession([assistant(id: "second", tool: "Read")], config: newConfig)
        _ = await engine.computeSnapshot(rangeKey: "today", cutoff: Date())
        try FileManager.default.removeItem(at: firstFile)
        try FileManager.default.removeItem(at: newFile)
        let restored = await CallAnalyticsEngine(homeDirectory: root.path, timeZone: zone, environment: [:]).computeSnapshot(rangeKey: "all", cutoff: nil)
        XCTAssertEqual(restored.entries.filter { $0.source == .claude }.reduce(0) { $0 + $1.count }, 2)
        XCTAssertEqual(restored.agentInvocations.filter { $0.source == .claude }.reduce(0) { $0 + $1.count }, 2)
        let today = await engine.computeSnapshot(rangeKey: "today", cutoff: Calendar(identifier: .gregorian).startOfDay(for: Date()))
        XCTAssertEqual(today.entries.filter { $0.source == .claude }.reduce(0) { $0 + $1.count }, 1)
    }

    func testLegacyCallResidualMigratesOnce() async throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let old = CallAnalyticsEntry(source: .claude, kind: .builtin, name: "Read", server: nil, agent: "main", dayKey: day, count: 3)
        let archived = CallAnalyticsArchive(version: 1, updatedAt: "", fullHistoryImportedAt: "done", days: [day: CallAnalyticsDayBucket(entries: [old], agentInvocations: [AgentInvocationCount(source: .claude, agent: "main", count: 3)])])
        let url = CallAnalyticsArchiveStore.fileURL(homeDirectory: root.path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(archived).write(to: url)
        try writeSession([assistant(id: "existing", tool: "Read")], config: root.appendingPathComponent(".claude"))
        for _ in 0..<2 {
            let result = await CallAnalyticsEngine(homeDirectory: root.path, timeZone: zone, environment: [:]).computeSnapshot(rangeKey: "all", cutoff: nil)
            XCTAssertEqual(result.entries.filter { $0.source == .claude }.reduce(0) { $0 + $1.count }, 3)
            XCTAssertEqual(result.agentInvocations.filter { $0.source == .claude }.reduce(0) { $0 + $1.count }, 3)
        }
    }

    func testRepeatedToolRowsAndLateResultDoNotInflateCalls() throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent(".claude")
        let row = try assistant(id: "response", tool: "Read")
        try writeSession([row, row], config: config)
        let source = ClaudeCallEventSource(homeDirectory: root.path, timeZone: zone, environment: [:])
        let store = ClaudeCallLedgerStore(homeDirectory: root.path)
        let first = try store.collect(source: source, legacy: [:])
        XCTAssertEqual(first.days[day]?.entries.first?.count, 1)
        let result = Data(#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tool-response","is_error":false}]}}"#.utf8)
        try writeSession([row, row, result, row], config: config)
        let next = try store.collect(source: source, legacy: [:])
        XCTAssertEqual(next.days[day]?.entries.first?.count, 1)
        XCTAssertEqual(next.days[day]?.entries.first?.successCount, 1)
    }

    func testTokenDatesFollowTimeZoneAfterLedgerReload() async throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try writeSession([assistant(id: "response", timestamp: "2026-01-02T23:30:00Z")], config: root.appendingPathComponent(".claude"))
        _ = try await ClaudeUsageLedger().scan(homeDirectory: root.path, environment: [:], timeZone: zone)
        try FileManager.default.removeItem(at: file)
        let provider = ClaudeProvider(homeDirectory: root.path, timeZone: TimeZone(identifier: "Asia/Shanghai")!, environment: [:])
        let usage = try await provider.fetchUsage()
        XCTAssertEqual(usage.extra["overall.rangeLabel"]?.value as? String, "2026-01-03")
    }

    func testLedgerReadFailureKeepsOldArchiveBytes() async throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        try writeSession([assistant(id: "response")], config: root.appendingPathComponent(".claude"))
        let url = root.appendingPathComponent(".config/aiusage/usage-archive/claude-token-ledger-v1.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let old = Data("invalid-archive".utf8)
        try old.write(to: url)
        do {
            _ = try await ClaudeUsageLedger().scan(homeDirectory: root.path, environment: [:], timeZone: zone)
            XCTFail("损坏账本不能被空数据覆盖")
        } catch { XCTAssertEqual(try Data(contentsOf: url), old) }
    }

    func testCallsSurviveCopiesTrimmingAndTimeZoneReload() throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent(".claude")
        let a = try assistant(id: "a", tool: "Read", timestamp: "2026-01-02T23:30:00Z")
        let b = try assistant(id: "b", tool: "Read", timestamp: "2026-01-02T23:30:00Z")
        let c = try assistant(id: "c", tool: "Read", timestamp: "2026-01-02T23:30:00Z")
        let file = try writeSession([a, b], config: config)
        let store = ClaudeCallLedgerStore(homeDirectory: root.path)
        let source = ClaudeCallEventSource(homeDirectory: root.path, timeZone: zone, environment: [:])
        func calls(_ result: [String: CallAnalyticsDayBucket]) -> Int { result.values.flatMap(\.entries).reduce(0) { $0 + $1.count } }
        XCTAssertEqual(calls(try store.collect(source: source, legacy: [:]).days), 2)
        try writeSession([a, b], config: config, name: "copy")
        XCTAssertEqual(calls(try store.collect(source: source, legacy: [:]).days), 2)
        // 同 inode 原位裁剪并追加，尺寸相近：不能误用追加游标。
        try writeSession([b, c], config: config)
        XCTAssertEqual(calls(try store.collect(source: source, legacy: [:]).days), 3)
        try FileManager.default.removeItem(at: file)
        let shanghai = ClaudeCallEventSource(homeDirectory: root.path, timeZone: TimeZone(identifier: "Asia/Shanghai")!, environment: [:])
        let next = try ClaudeCallLedgerStore(homeDirectory: root.path).collect(source: shanghai, legacy: [:])
        XCTAssertEqual(calls(next.days), 3)
        XCTAssertEqual(Set(next.days.keys), ["2026-01-03"])
    }

    func testMetadataAloneRefinesAgentWithoutAddingCallsOrSessions() throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let file = try writeSession([assistant(id: "agent", tool: "Read")], config: root.appendingPathComponent(".claude"), name: "run/subagents/agent-1")
        let store = ClaudeCallLedgerStore(homeDirectory: root.path)
        let source = ClaudeCallEventSource(homeDirectory: root.path, timeZone: zone, environment: [:])
        XCTAssertEqual(try store.collect(source: source, legacy: [:]).days[day]?.entries.first?.agent, "subagent")
        try Data(#"{"agentType":"Explore"}"#.utf8).write(to: file.deletingPathExtension().appendingPathExtension("meta.json"))
        let next = try store.collect(source: source, legacy: [:])
        XCTAssertEqual(next.days[day]?.entries.count, 1)
        XCTAssertEqual(next.days[day]?.entries.first?.agent, "Explore")
        XCTAssertEqual(next.days[day]?.entries.first?.count, 1)
        XCTAssertEqual(next.days[day]?.agentInvocations.first?.agent, "Explore")
        XCTAssertEqual(next.days[day]?.agentInvocations.first?.count, 1)
    }

    func testLegacyRestorationReconcilesDynamicallyAndNewCallsStillIncrease() throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: config.appendingPathComponent("projects"), withIntermediateDirectories: true)
        let legacy = [day: CallAnalyticsDayBucket(entries: [CallAnalyticsEntry(source: .claude, kind: .builtin, name: "Read", server: nil, agent: "main", dayKey: day, count: 1)], agentInvocations: [])]
        let source = ClaudeCallEventSource(homeDirectory: root.path, timeZone: zone, environment: [:])
        let store = ClaudeCallLedgerStore(homeDirectory: root.path)
        XCTAssertEqual(try store.collect(source: source, legacy: legacy).status.eventCount, 1)
        try writeSession([assistant(id: "restored", tool: "Read")], config: config)
        XCTAssertEqual(try store.collect(source: source, legacy: legacy).status.eventCount, 1)
        let future = ISO8601DateFormatter().string(from: Date().addingTimeInterval(120))
        try writeSession([assistant(id: "restored", tool: "Read"), assistant(id: "new", tool: "Read", timestamp: future)], config: config)
        XCTAssertEqual(try store.collect(source: source, legacy: legacy).status.eventCount, 2)
        XCTAssertEqual(try ClaudeCallLedgerStore(homeDirectory: root.path).collect(source: source, legacy: legacy).status.eventCount, 2)
    }

    func testLegacyProxyRemainsUnverifiedAcrossDateBoundary() async throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        try writeSession([assistant(id: "proxy-response", timestamp: "2026-01-02T23:30:00Z")], config: root.appendingPathComponent(".claude"))
        try proxyArchive(home: root, identified: false)
        for zone in [zone, TimeZone(identifier: "Asia/Shanghai")!, TimeZone(secondsFromGMT: -12 * 3600)!] {
            let usage = try await ClaudeProvider(homeDirectory: root.path, timeZone: zone, environment: [:]).fetchUsage()
            XCTAssertEqual(usage.extra["overall.totalTokens"]?.value as? Int, 38)
            XCTAssertEqual(usage.extra["overall.uncertainTokens"]?.value as? Int, 38)
        }
    }

    func testLargeContentAndToolArgumentsDoNotHideStatistics() async throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let original = try assistant(id: "large", tool: "Read")
        var row = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var message = try XCTUnwrap(row["message"] as? [String: Any])
        let huge = String(repeating: "text\\\"中文", count: 600_000)
        message["content"] = [["type": "text", "text": huge],
            ["type": "tool_use", "id": "tool-large", "name": "Skill", "input": ["prompt": huge, "skill": "验收"]]]
        row["message"] = message
        let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        XCTAssertGreaterThan(data.count, 4 * 1024 * 1024)
        try writeSession([data], config: root.appendingPathComponent(".claude"))
        let records = try await ClaudeUsageLedger().scan(homeDirectory: root.path, environment: [:], timeZone: zone)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.total, 38)
        let calls = ClaudeCallEventSource(homeDirectory: root.path, timeZone: zone, environment: [:]).collect(cutoff: nil)
        XCTAssertNil(calls.status.errorCode)
        XCTAssertEqual(calls.entries.first?.name, "验收")
        XCTAssertEqual(calls.entries.first?.count, 1)
    }

    func testAppendCursorReplaysIncompleteTailWithoutRescanningPrefix() throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try assistant(id: "first")
        let second = try assistant(id: "second")
        let file = try writeSession([first], config: root.appendingPathComponent(".claude"))
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: second.prefix(second.count / 2))
        var rows = [Data]()
        let scan = try ClaudeSessionReader.scan(path: file.path, cursor: nil) { rows.append($0) }
        XCTAssertNil(scan.errorCode)
        XCTAssertEqual(rows.count, 1)
        try handle.write(contentsOf: second.suffix(second.count - second.count / 2)); try handle.write(contentsOf: Data([10]))
        rows = []
        let appended = try ClaudeSessionReader.scan(path: file.path, cursor: scan.cursor) { rows.append($0) }
        XCTAssertNil(appended.errorCode)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(ClaudeUsageRecord.parse(rows[0], clock: CallAnalyticsClock(timeZone: zone))?.messageID, "second")
    }

    func testVersionOneCallLedgerMigratesWithoutLosingOrDuplicatingHistory() throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent(".claude")
        try writeSession([assistant(id: "old", tool: "Read", timestamp: "2026-01-02T23:30:00Z")], config: config)
        let entry = CallAnalyticsEntry(source: .claude, kind: .builtin, name: "Read", server: nil, agent: "main", dayKey: day, count: 1)
        let bucket = CallAnalyticsDayBucket(entries: [entry], agentInvocations: [])
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(bucket)) as? [String: Any])
        let url = root.appendingPathComponent(".config/aiusage/usage-archive/claude-call-ledger-v1.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["version": 1, "files": ["old-file-hash": [day: encoded]]]).write(to: url)
        let source = ClaudeCallEventSource(homeDirectory: root.path, timeZone: TimeZone(identifier: "Asia/Shanghai")!, environment: [:])
        let next = try ClaudeCallLedgerStore(homeDirectory: root.path).collect(source: source, legacy: [:])
        XCTAssertEqual(next.status.eventCount, 1)
        XCTAssertEqual(Set(next.days.keys), ["2026-01-03"])
        let archive = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(archive["version"] as? Int, 2)
        XCTAssertNil(archive["files"])
    }

    func testSubagentsSharingParentSessionIDRemainSeparate() throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent(".claude")
        for index in 0..<2 {
            var row = try XCTUnwrap(JSONSerialization.jsonObject(with: assistant(id: "agent-\(index)", tool: "Read")) as? [String: Any])
            row["sessionId"] = "parent-session"
            try writeSession([JSONSerialization.data(withJSONObject: row)], config: config, name: "parent/subagents/agent-\(index)")
        }
        let result = ClaudeCallEventSource(homeDirectory: root.path, timeZone: zone, environment: [:]).collect(cutoff: nil)
        XCTAssertEqual(result.status.eventCount, 2)
        XCTAssertEqual(result.agentInvocationsByDay[day]?.reduce(0) { $0 + $1.count }, 2)
    }

    func testProjectionLimitIsReportedAndFailedScanCanRetry() async throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        var row = try XCTUnwrap(JSONSerialization.jsonObject(with: assistant(id: "limited")) as? [String: Any])
        var message = try XCTUnwrap(row["message"] as? [String: Any])
        message["model"] = String(repeating: "x", count: 17 * 1024)
        row["message"] = message
        let config = root.appendingPathComponent(".claude")
        try writeSession([JSONSerialization.data(withJSONObject: row)], config: config)
        let ledger = ClaudeUsageLedger()
        do {
            _ = try await ledger.scan(homeDirectory: root.path, environment: [:], timeZone: zone)
            XCTFail("不能把超出统计字段限制的行标为完整采集")
        } catch {}
        let calls = ClaudeCallLedgerStore(homeDirectory: root.path)
        let source = ClaudeCallEventSource(homeDirectory: root.path, timeZone: zone, environment: [:])
        XCTAssertEqual(try calls.collect(source: source, legacy: [:]).status.errorCode, "session_projection_limit")
        try writeSession([assistant(id: "limited", tool: "Read")], config: config)
        let records = try await ledger.scan(homeDirectory: root.path, environment: [:], timeZone: zone)
        XCTAssertEqual(records.count, 1)
        XCTAssertNil(try calls.collect(source: source, legacy: [:]).status.errorCode)
        XCTAssertEqual(try calls.collect(source: source, legacy: [:]).status.eventCount, 1)
    }

    func testTrimmedSessionKeepsInvocationIdentityAfterRestart() throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent(".claude")
        try writeSession([assistant(id: "a", tool: "Read"), assistant(id: "b", tool: "Read")], config: config)
        let source = ClaudeCallEventSource(homeDirectory: root.path, timeZone: zone, environment: [:])
        _ = try ClaudeCallLedgerStore(homeDirectory: root.path).collect(source: source, legacy: [:])
        try writeSession([assistant(id: "b", tool: "Read"), assistant(id: "c", tool: "Read")], config: config)
        let next = try ClaudeCallLedgerStore(homeDirectory: root.path).collect(source: source, legacy: [:])
        XCTAssertEqual(next.status.eventCount, 3)
        XCTAssertEqual(next.days[day]?.agentInvocations.reduce(0) { $0 + $1.count }, 1)
    }

    func testRestoredResultCanPrecedeItsToolUseAcrossFilesAndRestart() throws {
        let root = try home(); defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent(".claude")
        let outcome = Data(#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tool-restored","is_error":false}]}}"#.utf8)
        let file = try writeSession([outcome], config: config, name: "result")
        let source = ClaudeCallEventSource(homeDirectory: root.path, timeZone: zone, environment: [:])
        _ = try ClaudeCallLedgerStore(homeDirectory: root.path).collect(source: source, legacy: [:])
        try FileManager.default.removeItem(at: file)
        try writeSession([assistant(id: "restored", tool: "Read")], config: config)
        let next = try ClaudeCallLedgerStore(homeDirectory: root.path).collect(source: source, legacy: [:])
        XCTAssertEqual(next.status.eventCount, 1)
        XCTAssertEqual(next.days[day]?.entries.first?.successCount, 1)
    }
}
