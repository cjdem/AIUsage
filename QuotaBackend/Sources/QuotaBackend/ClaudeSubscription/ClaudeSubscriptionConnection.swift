import Foundation

/// 可测试的字段级安装/恢复，不接触官方登录和其他 settings 字段。
public struct ClaudeSubscriptionConnection: Sendable {
    public let store: ClaudeSubscriptionStore
    public init(store: ClaudeSubscriptionStore = .init()) { self.store = store }

    public static func validatedDirectory(_ directory: String) throws -> String {
        let expanded = NSString(string: directory.trimmingCharacters(in: .whitespacesAndNewlines)).expandingTildeInPath
        guard expanded.hasPrefix("/"), expanded != "/" else {
            throw ProviderError("invalid_directory", "请选择 Claude 专用配置目录，不能使用空路径、相对路径或根目录。")
        }
        let canonical = ClaudeSubscriptionProfile(configDirectory: expanded, name: "").configDirectory
        guard canonical != "/" else { throw ProviderError("invalid_directory", "不能使用根目录作为 Claude 配置目录。") }
        return canonical
    }

    public func install(directory: String, name: String, helperPath: String, renewBinding: Bool = false) throws -> ClaudeSubscriptionProfile {
        var profile = ClaudeSubscriptionProfile(configDirectory: try Self.validatedDirectory(directory), name: name)
        let fm = FileManager.default
        try fm.createDirectory(atPath: profile.configDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        profile = ClaudeSubscriptionProfile(configDirectory: profile.configDirectory, name: name)
        let settingsURL = URL(fileURLWithPath: profile.configDirectory).appendingPathComponent("settings.json")
        var settings = try readSettings(settingsURL)
        let profileURL = try store.directory(for: profile.id).appendingPathComponent("profile.json")
        let hasStoredProfile = fm.fileExists(atPath: profileURL.path)
        if hasStoredProfile {
            // 元数据损坏不能当成新连接覆盖，否则会失去原状态栏备份。
            let existing: ClaudeSubscriptionProfile
            do { existing = try store.loadProfile(id: profile.id) }
            catch { throw ProviderError("statusline_recovery_required", "回传备份无法读取，请先恢复 AIUsage 的 profile.json 备份。") }
            profile = existing
            profile.name = name
        }
        let current = settings["statusLine"] as? [String: Any]
        let currentCommand = current?["command"] as? String
        let staleWrapper = currentCommand.map(Self.isFeedbackCommand) ?? false
        if staleWrapper, currentCommand?.contains(profile.id) != true {
            throw ProviderError("statusline_recovery_required", "现有回传命令属于其他配置，请先恢复原 statusLine。")
        }
        if staleWrapper, !hasStoredProfile {
            throw ProviderError("statusline_recovery_required", "回传配置的原状态栏备份不可用，请恢复原 statusLine 后重新连接。")
        }
        let ownsCurrent = profile.installedCommand != nil && currentCommand == profile.installedCommand
        if ownsCurrent || staleWrapper {
            if let original = profile.originalStatusLine,
               let object = try JSONSerialization.jsonObject(with: original) as? [String: Any],
               let command = object["command"] as? String, Self.isFeedbackCommand(command) {
                throw ProviderError("statusline_recovery_required", "原状态栏备份包含旧回传命令，请恢复原 statusLine 后重新连接。")
            }
            // 重连只刷新 helper 路径，不重复包裹原状态栏。
            if renewBinding { profile.generation = UUID().uuidString }
        } else {
            if let current {
                guard current["type"] as? String == "command", current["command"] is String else {
                    throw ProviderError("unsupported_statusline", "现有状态栏类型不支持串接；配置保持不变。")
                }
                profile.originalStatusLine = try JSONSerialization.data(withJSONObject: current, options: [.sortedKeys])
            } else if settings["statusLine"] != nil {
                throw ProviderError("unsupported_statusline", "现有状态栏格式不支持串接；配置保持不变。")
            } else { profile.originalStatusLine = nil }
            profile.generation = UUID().uuidString
        }
        let command = [helperPath, "--claude-statusline", profile.id, profile.generation, store.root.path]
            .map(ClaudeSubscriptionLaunch.quote).joined(separator: " ")
        profile.installedCommand = command
        var wrapper = current ?? ["type": "command"]
        wrapper["type"] = "command"
        wrapper["command"] = command
        settings["statusLine"] = wrapper
        let previousProfile = try? Data(contentsOf: store.directory(for: profile.id).appendingPathComponent("profile.json"))
        try store.saveProfile(profile)
        do { try writeSettings(settings, to: settingsURL) }
        catch {
            if let previousProfile { try? store.write(previousProfile, to: store.directory(for: profile.id).appendingPathComponent("profile.json")) }
            throw error
        }
        return profile
    }

    /// 该目录的 settings 把 Code 指向 API Key / 代理时，会话不产生订阅额度。只看键名与是否为空，不读取值。
    public static func routesThroughAPI(directory: String) -> Bool {
        let url = URL(fileURLWithPath: directory).appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        if let helper = settings["apiKeyHelper"] as? String, !helper.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        let env = settings["env"] as? [String: Any] ?? [:]
        return ClaudeSubscriptionLaunch.authEnvironmentKeys.contains { key in
            guard let value = env[key] else { return false }
            guard let text = value as? String else { return true }
            let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
            return !["", "0", "false"].contains(trimmed)
        }
    }

    /// 本功能专用入口；只检查命令，不执行或解析用户 shell 配置。
    static func isFeedbackCommand(_ command: String) -> Bool {
        command.contains("--claude-statusline")
    }

    /// 整份设置替换或恢复备份时，保留仍由本功能持有的回传命令。
    /// 已断开的旧备份不能重新启用失效的 wrapper；用户改过的命令不作接管。
    public func preservingStatusLine(in incoming: [String: Any], current: [String: Any], directory: String) throws -> [String: Any] {
        let reference = ClaudeSubscriptionProfile(configDirectory: directory, name: "")
        let profileURL = try store.directory(for: reference.id).appendingPathComponent("profile.json")
        guard FileManager.default.fileExists(atPath: profileURL.path) else { return incoming }
        let profile = try store.loadProfile(id: reference.id)
        var result = incoming
        let active = current["statusLine"] as? [String: Any]
        if let owned = profile.installedCommand, active?["command"] as? String == owned {
            result["statusLine"] = active
        } else if profile.installedCommand != nil, active != nil {
            // 连接后用户改过状态栏，节点切换也不撤销该修改。
            result["statusLine"] = active
        } else if let command = (incoming["statusLine"] as? [String: Any])?["command"] as? String,
                  command.contains("--claude-statusline"), command.contains(profile.id) {
            // 只识别本账号自己的备份 wrapper，不匹配其他用户命令。
            result["statusLine"] = current["statusLine"]
        }
        return result
    }

    /// 账号登记失败时只回退本次安装，已有 AIUsage 回传不被误卸载。
    public func rollbackInstallation(_ installed: ClaudeSubscriptionProfile, previous: ClaudeSubscriptionProfile?) throws {
        guard let previous, let previousCommand = previous.installedCommand,
              previous.originalStatusLine == installed.originalStatusLine else {
            _ = try uninstall(profileID: installed.id)
            return
        }
        let url = URL(fileURLWithPath: installed.configDirectory).appendingPathComponent("settings.json")
        var settings = try readSettings(url)
        guard var current = settings["statusLine"] as? [String: Any],
              current["command"] as? String == installed.installedCommand else { return }
        current["command"] = previousCommand
        settings["statusLine"] = current
        try writeSettings(settings, to: url)
        try store.saveProfile(previous)
    }

    /// 用户后改过 statusLine 时拒绝覆盖；不恢复整个 settings.json。
    @discardableResult
    public func uninstall(profileID: String) throws -> Bool {
        var profile = try store.loadProfile(id: profileID)
        let url = URL(fileURLWithPath: profile.configDirectory).appendingPathComponent("settings.json")
        var settings = try readSettings(url)
        let current = settings["statusLine"] as? [String: Any]
        guard let owned = profile.installedCommand, current?["command"] as? String == owned else { return false }
        if let original = profile.originalStatusLine,
           let originalObject = try JSONSerialization.jsonObject(with: original) as? [String: Any] {
            // 字段级恢复命令，安装后用户改过的 padding 等字段保持不变。
            var restored = current ?? originalObject
            restored["command"] = originalObject["command"]
            restored["type"] = originalObject["type"]
            settings["statusLine"] = restored
        } else {
            guard Set((current ?? [:]).keys).isSubset(of: ["type", "command"]) else { return false }
            settings.removeValue(forKey: "statusLine")
        }
        try writeSettings(settings, to: url)
        profile.installedCommand = nil
        profile.generation = UUID().uuidString
        try store.saveProfile(profile)
        return true
    }

    private func readSettings(_ url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        guard let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] else {
            throw ProviderError("invalid_settings", "Claude settings.json 必须是 JSON 对象。")
        }
        return settings
    }

    private func writeSettings(_ settings: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}
