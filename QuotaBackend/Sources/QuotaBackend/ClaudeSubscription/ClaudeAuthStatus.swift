import Foundation

/// 官方 `claude auth status --json` 的白名单字段；输出本身不含 Token，这里也只取身份与登录类型。
public struct ClaudeAuthStatus: Equatable, Sendable {
    public let loggedIn: Bool
    public let authMethod: String?
    public let apiProvider: String?
    public let configDirectory: String?
    public let email: String?
    public let organizationID: String?
    public let organizationName: String?
    public let subscriptionType: String?

    public init(loggedIn: Bool, authMethod: String? = nil, apiProvider: String? = nil, configDirectory: String? = nil,
                email: String? = nil, organizationID: String? = nil, organizationName: String? = nil, subscriptionType: String? = nil) {
        self.loggedIn = loggedIn
        self.authMethod = authMethod
        self.apiProvider = apiProvider
        self.configDirectory = configDirectory
        self.email = email
        self.organizationID = organizationID
        self.organizationName = organizationName
        self.subscriptionType = subscriptionType
    }

    public init(json: Data) throws {
        guard json.count < 64 * 1024,
              let object = try JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw ProviderError("invalid_auth_status", "Claude Code returned an unsupported login status.")
        }
        func text(_ key: String) -> String? {
            (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        self.init(loggedIn: object["loggedIn"] as? Bool == true, authMethod: text("authMethod"), apiProvider: text("apiProvider"),
                  configDirectory: text("configDirectory"), email: text("email"), organizationID: text("orgId"),
                  organizationName: text("orgName"), subscriptionType: text("subscriptionType"))
    }

    /// 只有 claude.ai 订阅登录会产生 5 小时 / 每周额度；Console / API Key 登录不算。
    public var isSubscription: Bool {
        loggedIn && authMethod == "claude.ai" && (apiProvider ?? "firstParty") == "firstParty"
    }

    public var planLabel: String? { Self.planLabel(subscriptionType) }

    public static func planLabel(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        switch raw.lowercased() {
        case "pro": return "Pro"
        case "max": return "Max"
        case "team": return "Team"
        case "enterprise": return "Enterprise"
        case "free": return "Free"
        default: return raw.prefix(1).uppercased() + raw.dropFirst()
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
