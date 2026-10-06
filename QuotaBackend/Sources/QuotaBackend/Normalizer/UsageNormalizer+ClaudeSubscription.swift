import Foundation

extension UsageNormalizer {
    static func normalizeClaudeSubscription(base: inout ProviderSummary, usage: ProviderUsage) -> ProviderSummary {
        let state = usage.extra["snapshotState"]?.value as? String ?? "waiting"
        var windows: [WindowInfo] = []
        if let value = usage.primary { windows.append(createPercentWindow(label: "5h Window", window: value)) }
        if let value = usage.secondary { windows.append(createPercentWindow(label: "Weekly Window", window: value)) }
        let remaining = pickSmallestRemaining(windows)
        base.category = "quota"
        base.accountLabel = usage.accountEmail ?? usage.accountName
        base.membershipLabel = usage.accountPlan
        base.sourceLabel = "Claude Code"
        base.sourceFilePath = usage.extra["profileDirectory"]?.value as? String
        base.fetchedAt = usage.fetchedAt.isEmpty ? nil : usage.fetchedAt
        base.windows = windows
        // 旧快照仍可展示，但不触发新的低额度/恢复通知。
        base.remainingPercent = state == "snapshot" ? remaining : nil
        base.nextResetAt = windows.compactMap(\.resetAt).sorted().first
        base.nextResetLabel = formatShortDateTime(base.nextResetAt)

        let primary: String, secondary: String
        switch state {
        case "disconnected":
            (base.status, base.statusLabel) = ("error", "Feedback disconnected")
            (primary, secondary) = ("Reconnect needed", "Quota sync was removed from Claude Code settings.")
        case "api-routed":
            (base.status, base.statusLabel) = ("idle", "Proxy session")
            (primary, secondary) = ("No subscription data", "Claude Code is using an API proxy, which doesn't report subscription limits.")
        case "waiting":
            (base.status, base.statusLabel) = ("healthy", "Waiting")
            (primary, secondary) = ("Waiting for first sync", "Limits appear after your next Claude Code message.")
        case "reset":
            (base.status, base.statusLabel) = ("healthy", "Waiting")
            (primary, secondary) = ("Limits reset", "Updates after your next Claude Code message.")
        case "stale":
            // 卡片底部已有相对时间；不常驻提示文字。
            (base.status, base.statusLabel) = ("healthy", "Snapshot")
            (primary, secondary) = ("Last synced", "")
        default:
            (base.status, base.statusLabel) = resolveStatus(remaining)
            (primary, secondary) = ("Synced", "")
        }
        base.headline = HeadlineInfo(eyebrow: "Claude Subscription", primary: primary, secondary: secondary, supporting: "")
        var metrics: [MetricInfo] = []
        if let plan = usage.accountPlan { metrics.append(MetricInfo(label: "Plan", value: plan)) }
        if let organization = usage.extra["organizationName"]?.value as? String {
            metrics.append(MetricInfo(label: "Organization", value: organization))
        }
        metrics.append(MetricInfo(label: "Source", value: "Claude Code"))
        base.metrics = metrics
        base.spotlight = "Quota syncs each time Claude Code responds. Usage on claude.ai or other devices shows up after your next Code message."
        return base
    }
}
