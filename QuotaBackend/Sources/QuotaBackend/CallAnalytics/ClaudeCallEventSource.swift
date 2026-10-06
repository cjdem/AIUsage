import Foundation
import CryptoKit

struct ClaudeCallRecord: Codable {
    let id: String
    let kind: CallKind
    let name: String
    let server: String?
    var agent: String
    var timestamp: Date
    var success: Bool?
}

struct ClaudeInvocationRecord: Codable {
    let id: String
    var agent: String
    var timestamp: Date
}

/// 调用、结果与会话均保留稳定身份，日期在展示时计算。
struct ClaudeCallEventSource {
    let homeDirectory: String
    let timeZone: TimeZone
    let environment: [String: String]

    struct FileState {
        var cursor: ClaudeSessionReader.Cursor?
        var calls: [String: ClaudeCallRecord] = [:]
        var outcomes: [String: Bool] = [:]
        var invocation: ClaudeInvocationRecord?
        var metadata: String?
        var hasStableSessionID = false
    }

    func resolveProjectRoots() -> [String] {
        ClaudeLogDirectoryResolver(homeDirectory: homeDirectory, environment: environment).projectRoots
    }

    func scan(file: String, previous: FileState?) throws -> (state: FileState, changed: Bool, errorCode: String?) {
        var state = previous ?? FileState()
        let clock = CallAnalyticsClock(timeZone: timeZone)
        let fallback = (try? FileManager.default.attributesOfItem(atPath: file)[.modificationDate] as? Date) ?? Date()
        let isSubagent = file.contains("/subagents/")
        let metadata = isSubagent ? readSubagentType(forFile: file) : nil
        let agent = isSubagent ? (metadata ?? "subagent") : "main"
        var changed = previous == nil || state.metadata != metadata
        if state.metadata != metadata {
            for id in state.calls.keys { state.calls[id]?.agent = agent }
            state.invocation?.agent = agent
            state.metadata = metadata
        }
        let scanned = try ClaudeSessionReader.scan(path: file, cursor: state.cursor) { line in
            guard let row = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let type = row["type"] as? String, let message = row["message"] as? [String: Any] else { return }
            let content = message["content"] as? [[String: Any]] ?? []
            if type == "assistant" {
                let timestamp = (row["timestamp"] as? String).flatMap(clock.date(fromISO:)) ?? fallback
                // 子代理日志中的 sessionId 可能沿用主会话，不能据此合并不同子代理。
                let identity = (isSubagent ? nil : row["sessionId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? (message["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? file
                if state.invocation == nil {
                    state.hasStableSessionID = !isSubagent && !(row["sessionId"] as? String ?? "").isEmpty
                    state.invocation = ClaudeInvocationRecord(id: Self.hash(identity), agent: agent, timestamp: timestamp)
                    changed = true
                } else if timestamp < state.invocation!.timestamp {
                    state.invocation?.timestamp = timestamp
                    changed = true
                }
                let callAgent = isSubagent ? agent : ((row["isSidechain"] as? Bool) == true ? "subagent" : "main")
                for (index, item) in content.enumerated() {
                    guard item["type"] as? String == "tool_use", let name = item["name"] as? String, !name.isEmpty else { continue }
                    let id = (item["id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                        ?? "anonymous-" + Self.hash("\(identity)|\(row["uuid"] ?? message["id"] ?? timestamp.description)|\(index)|\(name)")
                    var call = makeCall(id: id, rawName: name, input: item["input"] as? [String: Any], agent: callAgent, timestamp: timestamp)
                    call.timestamp = min(call.timestamp, state.calls[id]?.timestamp ?? timestamp)
                    call.success = state.outcomes[id] ?? state.calls[id]?.success
                    state.calls[id] = call
                    changed = true
                }
            } else if type == "user" {
                for item in content {
                    guard item["type"] as? String == "tool_result", let id = item["tool_use_id"] as? String else { continue }
                    let success = (item["is_error"] as? Bool) != true
                    state.outcomes[id] = success
                    state.calls[id]?.success = success
                    changed = true
                }
            }
        }
        state.cursor = scanned.cursor
        return (state, changed, scanned.errorCode)
    }

    func collect(cutoff: Date?, sessionFiles: [String]? = nil) -> (entries: [CallAnalyticsEntry], status: CallSourceStatus, agentInvocationsByDay: [String: [AgentInvocationCount]]) {
        let available = resolveProjectRoots().contains { FileManager.default.fileExists(atPath: $0) }
        let files = sessionFiles ?? ClaudeLogDirectoryResolver(homeDirectory: homeDirectory, environment: environment).sessionFiles(cutoff: cutoff)
        var calls: [String: ClaudeCallRecord] = [:], invocations: [String: ClaudeInvocationRecord] = [:]
        var outcomes: [String: Bool] = [:]
        var errorCode: String?
        for file in files {
            do {
                let result = try scan(file: file, previous: nil)
                if let code = result.errorCode { errorCode = code }
                calls.merge(result.state.calls) { old, new in Self.merged(old, new) }
                outcomes.merge(result.state.outcomes) { _, new in new }
                if let invocation = result.state.invocation { invocations[invocation.id] = invocation }
            } catch { errorCode = "session_unreadable" }
        }
        for (id, success) in outcomes { calls[id]?.success = success }
        let days = Self.buckets(calls: calls.values, invocations: invocations.values, timeZone: timeZone)
        return (days.values.flatMap(\.entries), CallSourceStatus(source: .claude, available: available,
            eventCount: calls.count, filesScanned: files.count, errorCode: errorCode), days.mapValues(\.agentInvocations))
    }

    static func merged(_ old: ClaudeCallRecord, _ new: ClaudeCallRecord) -> ClaudeCallRecord {
        var result = new
        result.timestamp = min(old.timestamp, new.timestamp)
        result.success = new.success ?? old.success
        if new.agent == "subagent", old.agent != "subagent" { result.agent = old.agent }
        return result
    }

    static func buckets<C: Sequence, I: Sequence>(calls: C, invocations: I, timeZone: TimeZone) -> [String: CallAnalyticsDayBucket]
        where C.Element == ClaudeCallRecord, I.Element == ClaudeInvocationRecord {
        let clock = CallAnalyticsClock(timeZone: timeZone)
        var accumulator = CallEventAccumulator()
        for call in calls {
            accumulator.add(source: .claude, kind: call.kind, name: call.name, server: call.server,
                dayKey: clock.dayKey(call.timestamp), agent: call.agent, success: call.success)
        }
        var days: [String: CallAnalyticsDayBucket] = [:]
        for entry in accumulator.entries() { days[entry.dayKey, default: .empty].entries.append(entry) }
        var agents: [String: [String: Int]] = [:]
        for invocation in invocations { agents[clock.dayKey(invocation.timestamp), default: [:]][invocation.agent, default: 0] += 1 }
        for (day, counts) in agents {
            days[day, default: .empty].agentInvocations = counts.map { AgentInvocationCount(source: .claude, agent: $0.key, count: $0.value) }
        }
        return days
    }

    private func makeCall(id: String, rawName: String, input: [String: Any]?, agent: String, timestamp: Date) -> ClaudeCallRecord {
        if let mcp = CallAnalyticsNaming.parseClaudeMCP(rawName) {
            return .init(id: id, kind: .mcp, name: CallAnalyticsNaming.mcpDisplayName(server: mcp.server, tool: mcp.tool), server: mcp.server, agent: agent, timestamp: timestamp)
        }
        if rawName == "Skill" {
            let name = (input?["skill"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .init(id: id, kind: .skill, name: name.isEmpty ? "(unknown)" : name, server: nil, agent: agent, timestamp: timestamp)
        }
        return .init(id: id, kind: ["WebSearch", "WebFetch"].contains(rawName) ? .webSearch : .builtin,
                     name: rawName, server: nil, agent: agent, timestamp: timestamp)
    }

    private func readSubagentType(forFile file: String) -> String? {
        let path = String(file.dropLast(".jsonl".count)) + ".meta.json"
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              ((attrs[.size] as? NSNumber)?.intValue ?? Int.max) <= 64 * 1024,
              let data = FileManager.default.contents(atPath: path),
              let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = (row["agentType"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !type.isEmpty else { return nil }
        return type
    }

    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
