import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum ClaudeSubscriptionStatusLine {
    private struct Input: Decodable {
        struct Limits: Decodable {
            struct Window: Decodable {
                let used_percentage: Double
                let resets_at: Double
            }
            let five_hour: Window?
            let seven_day: Window?
        }
        let session_id: String
        let rate_limits: Limits?
    }

    public static func snapshot(input: Data, profile: ClaudeSubscriptionProfile, now: Date = Date()) throws -> ClaudeSubscriptionSnapshot? {
        guard input.count <= 2 * 1024 * 1024 else { throw ProviderError("invalid_snapshot", "Status line input is too large.") }
        let payload = try JSONDecoder().decode(Input.self, from: input)
        guard UUID(uuidString: payload.session_id) != nil, let limits = payload.rate_limits else { return nil }
        func window(_ raw: Input.Limits.Window?) throws -> ClaudeSubscriptionSnapshot.Window? {
            guard let raw else { return nil }
            guard raw.used_percentage.isFinite, (0...100).contains(raw.used_percentage),
                  raw.resets_at.isFinite, raw.resets_at > 0 else {
                throw ProviderError("invalid_snapshot", "Claude returned an invalid quota window.")
            }
            return .init(usedPercent: raw.used_percentage, resetAt: Date(timeIntervalSince1970: raw.resets_at))
        }
        return try .init(schemaVersion: 1, profileID: profile.id, generation: profile.generation,
                         sessionID: payload.session_id, receivedAt: now, observedAt: now,
                         fiveHour: window(limits.five_hour), sevenDay: window(limits.seven_day))
    }

    /// 从入口最先调用，避免状态栏启动服务、监听端口或输出启动日志。
    public static func run(arguments: [String]) -> Int32 {
        guard arguments.count >= 4 else { return 1 }
        let id = arguments[2], generation = arguments[3]
        let store = arguments.count > 4 ? ClaudeSubscriptionStore(root: URL(fileURLWithPath: arguments[4])) : ClaudeSubscriptionStore()
        guard let profile = try? store.loadProfile(id: id) else { return 1 }
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let env = ProcessInfo.processInfo.environment
        let nonSubscription = ClaudeSubscriptionLaunch.authEnvironmentKeys.contains { !(env[$0] ?? "").isEmpty }
        if profile.generation == generation, !nonSubscription,
           let sample = try? snapshot(input: input, profile: profile) {
            try? store.saveSnapshot(sample)
        }

        // 原状态栏 stdin / stdout 原样传递，额度落盘失败不改变原命令的输出。
        if let original = profile.originalStatusLine,
           let object = try? JSONSerialization.jsonObject(with: original) as? [String: Any],
           let command = object["command"] as? String {
            // 兼容已写入错误备份的旧 profile，禁止启动自身或另一层回传 wrapper。
            guard !ClaudeSubscriptionConnection.isFeedbackCommand(command) else {
                print("Claude · reconnect quota feedback")
                return 1
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            let pipe = Pipe()
            process.standardInput = pipe
            process.standardOutput = FileHandle.standardOutput
            process.standardError = FileHandle.standardError
            do {
                try process.run()
                // 仅影响父进程的写端；原命令可以不读 stdin 或提前退出。
                #if canImport(Darwin)
                _ = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
                #endif
                try? pipe.fileHandleForWriting.write(contentsOf: input)
                try? pipe.fileHandleForWriting.close()
                process.waitUntilExit()
                return process.terminationStatus
            } catch { return 1 }
        }
        if nonSubscription {
            print("Claude · API / proxy session")
        } else if profile.generation != generation {
            print("Claude · reconnect quota feedback")
        } else if let sample = try? store.latestSnapshot(for: profile) {
            let values = [("5h", sample.fiveHour), ("7d", sample.sevenDay)].compactMap { label, window -> String? in
                guard let window, window.resetAt > Date() else { return nil }
                return "\(label) \(Int((100 - window.usedPercent).rounded()))%"
            }
            print(values.isEmpty ? "Claude · waiting for quota" : values.joined(separator: " · "))
        } else { print("Claude · waiting for quota") }
        return 0
    }
}

public enum ClaudeSubscriptionLaunch {
    /// 网络代理（HTTPS_PROXY 等）不在此列表中，保留用户的出网通道。
    public static let authEnvironmentKeys = [
        "ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN",
        "ANTHROPIC_PROFILE", "ANTHROPIC_FEDERATION_RULE_ID", "ANTHROPIC_ORGANIZATION_ID",
        "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
        "CLAUDE_CODE_USE_ANTHROPIC_FOUNDRY", "CLAUDE_CODE_GATEWAY_URL"
    ]
    public static let modelEnvironmentKeys = [
        "ANTHROPIC_MODEL", "ANTHROPIC_SMALL_FAST_MODEL", "ANTHROPIC_DEFAULT_FABLE_MODEL",
        "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL",
        "ANTHROPIC_CUSTOM_MODEL_OPTION", "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY"
    ]

    public static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// 会话级覆盖，不写代理配置，不修改官方凭证，也不停止已运行的进程。
    public static func settingsOverride() throws -> String {
        let env = Dictionary(uniqueKeysWithValues: (authEnvironmentKeys + modelEnvironmentKeys).map { ($0, "") })
        let data = try JSONSerialization.data(withJSONObject: ["env": env, "apiKeyHelper": "", "model": "sonnet"], options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// AIUsage 在后台运行官方 CLI（登录 / 状态检查）时的环境：去掉 API 与代理模型变量，保留出网代理。
    public static func environment(_ base: [String: String], configDirectory: String,
                                   homeDirectory: String = NSHomeDirectory()) -> [String: String] {
        var env = base
        for key in authEnvironmentKeys + modelEnvironmentKeys { env.removeValue(forKey: key) }
        // 显式设置 CLAUDE_CONFIG_DIR 会让官方 CLI 改用另一份登录凭证，即使路径就是默认的 ~/.claude。
        // 默认配置必须不设置，才能读到用户平时 `claude` 的登录状态。
        if isDefaultConfigDirectory(configDirectory, homeDirectory: homeDirectory) {
            env.removeValue(forKey: "CLAUDE_CONFIG_DIR")
        } else {
            env["CLAUDE_CONFIG_DIR"] = configDirectory
        }
        return env
    }

    public static func isDefaultConfigDirectory(_ directory: String, homeDirectory: String = NSHomeDirectory()) -> Bool {
        let defaultPath = URL(fileURLWithPath: homeDirectory).appendingPathComponent(".claude").path
        return ClaudeSubscriptionProfile(configDirectory: directory, name: "").configDirectory
            == ClaudeSubscriptionProfile(configDirectory: defaultPath, name: "").configDirectory
    }

    /// 独立账号由用户在自己的终端里使用；AIUsage 不代为打开任何终端。
    public static func terminalCommand(configDirectory: String, homeDirectory: String = NSHomeDirectory()) -> String {
        isDefaultConfigDirectory(configDirectory, homeDirectory: homeDirectory) ? "claude" : "CLAUDE_CONFIG_DIR=\(quote(configDirectory)) claude"
    }
}
