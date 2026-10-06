import Foundation

/// 仅保存响应标识、日期、模型与 Token，不保存会话正文或凭证。
struct ClaudeUsageRecord: Codable, Sendable, Equatable {
    let messageID: String
    var timestamp: Date
    let model: String
    var input: Int
    var output: Int
    var cacheRead: Int
    var cacheCreate: Int
    var total: Int { input + output + cacheRead + cacheCreate }

    mutating func merge(_ other: Self) {
        // 同一响应可能按内容块重复落盘，流式后续行补齐用量；不逐行相加。
        input = max(input, other.input)
        output = max(output, other.output)
        cacheRead = max(cacheRead, other.cacheRead)
        cacheCreate = max(cacheCreate, other.cacheCreate)
        timestamp = min(timestamp, other.timestamp)
    }

    static func parse(_ line: Data, clock: CallAnalyticsClock) -> Self? {
        guard let row = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              row["type"] as? String == "assistant",
              let timestamp = row["timestamp"] as? String, let date = clock.date(fromISO: timestamp),
              let message = row["message"] as? [String: Any],
              let id = message["id"] as? String, !id.isEmpty,
              let model = message["model"] as? String, !model.isEmpty, model != "<synthetic>",
              let usage = message["usage"] as? [String: Any] else { return nil }
        func tokens(_ key: String) -> Int { max(0, usage[key] as? Int ?? 0) }
        let result = Self(messageID: id, timestamp: date, model: model,
            input: tokens("input_tokens"), output: tokens("output_tokens"),
            cacheRead: tokens("cache_read_input_tokens"), cacheCreate: tokens("cache_creation_input_tokens"))
        return result.total > 0 ? result : nil
    }
}

actor ClaudeUsageLedger {
    static let shared = ClaudeUsageLedger()

    private struct State {
        var records: [String: ClaudeUsageRecord]
        var files: [String: ClaudeSessionReader.Cursor] = [:]
    }
    private struct Archive: Codable {
        let version: Int
        let records: [String: ClaudeUsageRecord]
    }
    private var states: [String: State] = [:]

    func scan(homeDirectory: String, environment: [String: String], timeZone: TimeZone) throws -> [ClaudeUsageRecord] {
        let url = URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent(".config/aiusage/usage-archive/claude-token-ledger-v1.json")
        let cacheKey = url.path
        var state: State
        if let cached = states[cacheKey] { state = cached }
        else if FileManager.default.fileExists(atPath: url.path) {
            // 读取失败不能用空账本覆盖已有历史。
            let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: url))
            guard archive.version == 1 else { throw ProviderError("unsupported_archive", "Unsupported Claude ledger version") }
            state = State(records: archive.records)
        } else { state = State(records: [:]) }
        let clock = CallAnalyticsClock(timeZone: timeZone)
        var changed = false
        for file in ClaudeLogDirectoryResolver(homeDirectory: homeDirectory, environment: environment).sessionFiles() {
            let result = try ClaudeSessionReader.scan(path: file, cursor: state.files[file]) { line in
                guard let row = ClaudeUsageRecord.parse(line, clock: clock) else { return }
                var merged = state.records[row.messageID] ?? row
                merged.merge(row)
                if state.records[row.messageID] != merged {
                    state.records[row.messageID] = merged
                    changed = true
                }
            }
            guard result.errorCode == nil else { throw ProviderError(result.errorCode!, "Claude session data is incomplete") }
            state.files[file] = result.cursor
        }
        if changed {
            try ClaudeSubscriptionStore().write(JSONEncoder().encode(Archive(version: 1, records: state.records)), to: url)
        }
        states[cacheKey] = state
        return Array(state.records.values)
    }
}
