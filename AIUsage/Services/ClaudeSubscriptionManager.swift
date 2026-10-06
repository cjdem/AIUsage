import Foundation
import Combine
import QuotaBackend
import AppKit

/// 订阅凭证始终由官方 Claude Code 保管；AIUsage 只登记配置目录，并通过状态栏回传读取额度。
/// 所有 CLI 调用都在后台进程完成，不打开终端。
final class ClaudeSubscriptionManager: ObservableObject {
    static let shared = ClaudeSubscriptionManager()
    static let providerId = "claude-subscription"

    let store = ClaudeSubscriptionStore()
    /// 每次收到新额度时递增，连接页据此实时显示首份数据。
    @Published private(set) var snapshotRevision = 0

    private var watchers: [String: DispatchSourceFileSystemObject] = [:]
    private var snapshotSignatures: [String: String] = [:]
    private var pendingRefresh: DispatchWorkItem?

    private init() {}

    // MARK: - Directories

    /// Claude Code 的默认配置目录，也就是用户平时在终端里直接运行 `claude` 时使用的账号。
    var defaultConfigDirectory: String {
        Self.canonical(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path)
    }

    func isDefault(_ directory: String) -> Bool { ClaudeSubscriptionLaunch.isDefaultConfigDirectory(directory) }

    /// 额外账号使用独立目录，避免替换默认登录；路径由 AIUsage 生成，不需要用户理解。
    func makeAccountDirectory() -> String {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude-aiusage/accounts/\(suffix)").path
    }

    /// 当前仍在监控（未隐藏、未删除、回传仍安装）的配置。
    var connectedProfiles: [ClaudeSubscriptionProfile] {
        let visiblePaths = Set(AccountStore.shared.accountRegistry.filter {
            $0.providerId == Self.providerId && !$0.isHidden && !$0.isPermanentlyRemoved
        }.compactMap(\.sourceFilePath).map(Self.canonical))
        return AccountCredentialStore.shared.loadCredentials(for: Self.providerId)
            .map { Self.canonical($0.credential) }
            .filter { visiblePaths.contains($0) }
            .compactMap { try? store.loadProfile(id: ClaudeSubscriptionProfile(configDirectory: $0, name: "").id) }
            .filter { $0.installedCommand != nil }
    }

    func connectedProfile(for directory: String) -> ClaudeSubscriptionProfile? {
        let id = ClaudeSubscriptionProfile(configDirectory: directory, name: "").id
        return connectedProfiles.first { $0.id == id }
    }

    func profile(for directory: String) -> ClaudeSubscriptionProfile? {
        try? store.loadProfile(id: ClaudeSubscriptionProfile(configDirectory: directory, name: "").id)
    }

    func latestSnapshot(for directory: String) -> ClaudeSubscriptionSnapshot? {
        guard let profile = profile(for: directory) else { return nil }
        return try? store.latestSnapshot(for: profile)
    }

    // MARK: - Official CLI

    static func resolveExecutable() async -> String? {
        await Task.detached(priority: .userInitiated) { aiusageResolvedExecutable(named: "claude") }.value
    }

    /// 官方 `auth status --json`：只返回登录类型与身份，不含 Token。在临时目录执行，不加载项目 hooks / MCP。
    static func authStatus(directory: String, executable: String) async throws -> ClaudeAuthStatus {
        let override = try ClaudeSubscriptionLaunch.settingsOverride()
        let timeoutMessage = L("Claude Code didn't respond. Try again.", "Claude Code 没有响应，请重试。")
        let data: Data = try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["--settings", override, "auth", "status", "--json"]
            var env = ClaudeSubscriptionLaunch.environment(ProcessInfo.processInfo.environment, configDirectory: directory)
            env["PATH"] = [env["PATH"]?.nilIfBlank, aiusageDefaultCLIPath()].compactMap { $0 }.joined(separator: ":")
            process.environment = env
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("aiusage-claude-check-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temp) }
            process.currentDirectoryURL = temp
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            try process.run()
            let deadline = Date().addingTimeInterval(10)
            while process.isRunning && Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
            if process.isRunning {
                // 只清理本次诊断子进程，不终止用户的 Code / Gateway。
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
                throw ProviderError("cli_timeout", timeoutMessage)
            }
            return pipe.fileHandleForReading.readDataToEndOfFile()
        }.value
        // 未登录时部分版本输出非 JSON 文本；按未登录处理。
        return (try? ClaudeAuthStatus(json: data)) ?? ClaudeAuthStatus(loggedIn: false)
    }

    // MARK: - Connect

    /// 安装额度回传并登记账号；身份来自官方 CLI，用户无需命名或选择目录。
    @discardableResult
    func connect(directory: String, status: ClaudeAuthStatus) async throws -> ClaudeSubscriptionProfile {
        guard status.isSubscription else {
            throw ProviderError("not_logged_in", L("Sign in with a Claude Pro or Max account first.", "请先登录 Claude Pro / Max 订阅账号。"))
        }
        let canonical = try ClaudeSubscriptionConnection.validatedDirectory(directory)
        if let reported = status.configDirectory, Self.canonical(reported) != canonical {
            throw ProviderError("profile_mismatch", L("Claude Code reported a different configuration. Nothing was changed.", "Claude Code 返回了其他配置目录，未做任何修改。"))
        }
        let helper = try helperPath()
        let name = status.email ?? (isDefault(canonical) ? "Claude Code" : L("Claude account", "Claude 账号"))
        let connection = ClaudeSubscriptionConnection(store: store)
        let previous = try? store.loadProfile(id: ClaudeSubscriptionProfile(configDirectory: canonical, name: "").id)
        // 同一账号重连保留已有快照；身份未知或已更换时作废旧快照，避免把别人的额度算到新账号上。
        let sameAccount = previous?.email != nil && previous?.email == status.email
        var profile = try connection.install(directory: canonical, name: name, helperPath: helper, renewBinding: !sameAccount)
        profile.email = status.email
        profile.organizationName = status.organizationName
        profile.subscriptionType = status.subscriptionType
        try store.saveProfile(profile)
        let credential = AccountCredential(providerId: Self.providerId, accountLabel: name,
                                           authMethod: .auto, credential: profile.configDirectory,
                                           metadata: ["sourceKind": "claude-cli-profile", "sourcePath": profile.configDirectory, "accountId": profile.id])
        do {
            let usage = try await ClaudeSubscriptionProvider(store: store).fetchUsage(with: credential)
            try AppState.shared.registerAuthenticatedCredential(credential, usage: usage)
        } catch {
            try? connection.rollbackInstallation(profile, previous: previous)
            throw error
        }
        watch(profile)
        return profile
    }

    /// 只移除 AIUsage 的回传并恢复原状态栏，不影响 Claude Code 登录。
    func disconnect(_ profile: ClaudeSubscriptionProfile) throws {
        guard try ClaudeSubscriptionConnection(store: store).uninstall(profileID: profile.id) else {
            throw ProviderError("settings_changed", L("Your Claude Code status line was changed since connecting. Remove the AIUsage entry manually.",
                                                     "Claude Code 状态栏在连接后被修改过，请手动移除 AIUsage 回传命令。"))
        }
        stopWatching(profile.id)
        ProviderRefreshCoordinator.shared.refreshProvider(Self.providerId)
    }

    /// 删除账号后卡片与「停止同步」入口都不存在了，必须同时恢复原状态栏，否则回传命令会永久留在 Claude Code 里。
    /// 隐藏账号可恢复，保持同步不变。用户连接后自行改过状态栏时不覆盖，删除照常进行。
    func releaseDeletedAccounts(_ entries: [ProviderAccountEntry]) {
        for entry in entries where entry.providerId == Self.providerId {
            guard let directory = entry.liveProvider?.sourceFilePath ?? entry.storedAccount?.sourceFilePath,
                  let profile = profile(for: directory) else { continue }
            _ = try? ClaudeSubscriptionConnection(store: store).uninstall(profileID: profile.id)
            stopWatching(profile.id)
        }
    }

    /// 撤销 AIUsage 为「添加其他账号」新建的独立目录（重复账号、取消或失败时），不碰默认配置和已连接账号。
    func discardAccountDirectory(_ directory: String, executable: String) async {
        guard !isDefault(directory), directory.contains("/.claude-aiusage/accounts/"),
              connectedProfile(for: directory) == nil else { return }
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["auth", "logout"]
            var env = ClaudeSubscriptionLaunch.environment(ProcessInfo.processInfo.environment, configDirectory: directory)
            env["PATH"] = [env["PATH"]?.nilIfBlank, aiusageDefaultCLIPath()].compactMap { $0 }.joined(separator: ":")
            process.environment = env
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            if (try? process.run()) != nil { process.waitUntilExit() }
            try? FileManager.default.removeItem(atPath: directory)
        }.value
    }

    func copyTerminalCommand(for directory: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ClaudeSubscriptionLaunch.terminalCommand(configDirectory: directory), forType: .string)
    }

    // MARK: - Live sync

    /// 回传写入快照后立即刷新卡片，不必等全局刷新周期。
    func startWatching() {
        guard AppState.shared.settings.backendMode == "local" else { return }
        let profiles = connectedProfiles
        profiles.forEach(watch)
        Task { await refreshIdentities(profiles) }
    }

    /// 启动时用官方 CLI 更新邮箱与套餐（如 Pro 升级到 Max），只改展示字段。
    private func refreshIdentities(_ profiles: [ClaudeSubscriptionProfile]) async {
        guard !profiles.isEmpty, let executable = await Self.resolveExecutable() else { return }
        var changed = false
        for profile in profiles {
            guard let status = try? await Self.authStatus(directory: profile.configDirectory, executable: executable),
                  status.isSubscription,
                  status.email != profile.email || status.subscriptionType != profile.subscriptionType
                    || status.organizationName != profile.organizationName,
                  var updated = try? store.loadProfile(id: profile.id) else { continue }
            updated.email = status.email
            updated.subscriptionType = status.subscriptionType
            updated.organizationName = status.organizationName
            if (try? store.saveProfile(updated)) != nil { changed = true }
        }
        if changed { ProviderRefreshCoordinator.shared.refreshProvider(Self.providerId) }
    }

    private func watch(_ profile: ClaudeSubscriptionProfile) {
        guard watchers[profile.id] == nil, let folder = try? store.directory(for: profile.id) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        snapshotSignatures[profile.id] = signature(for: profile)
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        let id = profile.id
        source.setEventHandler { [weak self] in self?.snapshotFolderChanged(id) }
        source.setCancelHandler { close(descriptor) }
        watchers[id] = source
        source.resume()
    }

    private func stopWatching(_ id: String) {
        watchers.removeValue(forKey: id)?.cancel()
        snapshotSignatures.removeValue(forKey: id)
    }

    private func snapshotFolderChanged(_ id: String) {
        guard let profile = try? store.loadProfile(id: id) else { return }
        // 状态栏每次重绘都会重写快照；只有额度或测量时间变化才刷新界面。
        let current = signature(for: profile)
        guard current != snapshotSignatures[id] else { return }
        snapshotSignatures[id] = current
        snapshotRevision += 1
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { ProviderRefreshCoordinator.shared.refreshProvider(Self.providerId) }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func signature(for profile: ClaudeSubscriptionProfile) -> String {
        guard let sample = try? store.latestSnapshot(for: profile) else { return "none:\(profile.generation)" }
        return [sample.observedAt.timeIntervalSince1970, sample.fiveHour?.usedPercent ?? -1, sample.sevenDay?.usedPercent ?? -1]
            .map { String($0) }.joined(separator: "|")
    }

    // MARK: - Helpers

    private func helperPath() throws -> String {
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/QuotaServer").path
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw ProviderError("helper_missing", L("AIUsage is missing a component. Reinstall AIUsage.", "AIUsage 缺少额度回传组件，请重新安装。"))
        }
        return path
    }

    nonisolated static func canonical(_ path: String) -> String {
        ClaudeSubscriptionProfile(configDirectory: path, name: "").configDirectory
    }
}
