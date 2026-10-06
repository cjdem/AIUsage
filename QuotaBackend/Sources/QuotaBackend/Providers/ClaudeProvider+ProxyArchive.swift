import Foundation

// MARK: - Claude Provider: Proxy Usage Archive Source
// Claude 代理轨读取「Gateway 用量永久日归档」，由 App 侧
// (ProxyUsageArchiveStore) 从 ProxyRequestLog 折叠写出，成本逐条冻结、不可篡改。
// QuotaBackend 只读该 JSON 文件（无法 import App 模块，故在此定义匹配的解码 DTO）。
//
// 数据来源: ~/.config/aiusage/usage-archive/proxy-usage-claude-v<version>.json
// 文件结构: { version, updatedAt, days: { "yyyy-MM-dd": { models: { "<model>": <agg> } } } }

extension ClaudeProvider {

    static let proxyUsageArchiveVersion = 1

    private struct ProxyUsageModelAggDTO: Decodable {
        let inputTokens: Int
        let outputTokens: Int
        let cacheReadTokens: Int
        let cacheCreateTokens: Int
        let costUSD: Double
        let requests: Int
        let pricingResolvedRequests: Int?
        let responseMessageIds: Set<String>?
        let unidentifiedTokenRequests: Int?
    }

    private struct ProxyUsageDayDTO: Decodable {
        let models: [String: ProxyUsageModelAggDTO]
    }

    private struct ProxyUsageArchiveDTO: Decodable {
        let version: Int
        let updatedAt: String
        let days: [String: ProxyUsageDayDTO]
    }

    func proxyUsageArchivePath() -> String {
        (homeDirectory as NSString)
            .appendingPathComponent(".config/aiusage/usage-archive/proxy-usage-claude-v\(Self.proxyUsageArchiveVersion).json")
    }

    /// 读取代理用量归档并转换为按日的 `ClaudeAggregateBucket`，复用既有聚合 / 时间线辅助。
    /// 成本直接采用归档中冻结的 `costUSD`；cost==0 且有 token 的模型记为「未定价」以提示用户配置定价。
    func loadProxyUsage() throws -> (days: [String: ClaudeAggregateBucket], responseIDs: Set<String>, uncertainDays: Set<String>) {
        let path = proxyUsageArchivePath()
        guard FileManager.default.fileExists(atPath: path) else { return ([:], [], []) }
        let dto = try JSONDecoder().decode(ProxyUsageArchiveDTO.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        guard dto.version == Self.proxyUsageArchiveVersion else { throw ProviderError("unsupported_archive", "Unsupported Claude proxy archive version") }

        var result: [String: ClaudeAggregateBucket] = [:]
        var responseIDs = Set<String>()
        var uncertainDays = Set<String>()
        for (dayKey, dayDTO) in dto.days {
            var bucket = ClaudeAggregateBucket.empty
            for (modelName, agg) in dayDTO.models {
                let total = agg.inputTokens + agg.outputTokens + agg.cacheReadTokens + agg.cacheCreateTokens
                guard total > 0 else { continue }
                responseIDs.formUnion(agg.responseMessageIds ?? [])
                // 旧代理归档没有响应标识。同日未匹配行无法证明直连，保留到待确认区，不做模型/Token 猜测。
                if (agg.unidentifiedTokenRequests ?? max(agg.requests, 1)) > 0 { uncertainDays.insert(dayKey) }

                let trackedName = modelName + " (Proxy)"
                var model = ClaudeModelAggregate(model: trackedName)
                model.totalTokens = total
                model.inputTokens = agg.inputTokens
                model.outputTokens = agg.outputTokens
                model.cacheReadTokens = agg.cacheReadTokens
                model.cacheCreateTokens = agg.cacheCreateTokens
                model.estimatedCostUsd = agg.costUSD

                bucket.models[trackedName] = model
                bucket.usageRows += max(agg.requests, 0)
                bucket.totalTokens += total
                bucket.estimatedCostUsd += agg.costUSD
                let requestCount = max(agg.requests, 0)
                let resolvedCount = agg.pricingResolvedRequests ?? (agg.costUSD > 0 ? requestCount : 0)
                if resolvedCount < requestCount {
                    bucket.unpricedModels.insert(modelName)
                }
            }
            if !bucket.models.isEmpty { result[dayKey] = bucket }
        }
        return (result, responseIDs, uncertainDays)
    }
}
