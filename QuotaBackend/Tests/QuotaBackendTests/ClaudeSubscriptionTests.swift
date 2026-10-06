import XCTest
@testable import QuotaBackend

final class ClaudeSubscriptionTests: XCTestCase {
    private func fixture() throws -> (URL, ClaudeSubscriptionStore, String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("claude-subscription-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, ClaudeSubscriptionStore(root: root.appendingPathComponent("snapshots")), root.appendingPathComponent("official profile").path)
    }

    private func input(used: Double = 23.5, reset: Date = Date().addingTimeInterval(3600), weekly: Bool = true) throws -> Data {
        var limits: [String: Any] = ["five_hour": ["used_percentage": used, "resets_at": reset.timeIntervalSince1970]]
        if weekly { limits["seven_day"] = ["used_percentage": 41.2, "resets_at": Date().addingTimeInterval(86400).timeIntervalSince1970] }
        return try JSONSerialization.data(withJSONObject: ["session_id": "ABCDEF01-0000-4000-8000-000000000001", "rate_limits": limits,
                                                           "cwd": "/private/project", "accessToken": "DO_NOT_PERSIST", "cost": ["total_cost_usd": 42]])
    }

    func testInstallAndRestoreOnlyStatusLineAndKeepUserEdits() throws {
        let (root, store, path) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: path).appendingPathComponent("settings.json")
        let original: [String: Any] = ["statusLine": ["type": "command", "command": "printf original", "padding": 3],
                                     "env": ["ANTHROPIC_BASE_URL": "https://proxy.invalid", "KEEP": "yes"], "hooks": ["keep": true], "effortLevel": "high"]
        try JSONSerialization.data(withJSONObject: original).write(to: url)
        let connection = ClaudeSubscriptionConnection(store: store)
        let first = try connection.install(directory: path, name: "Personal", helperPath: "/Applications/AI Usage.app/Contents/Helpers/QuotaServer")
        let second = try connection.install(directory: path, name: "Personal", helperPath: "/Applications/AIUsage.app/Contents/Helpers/QuotaServer")
        XCTAssertEqual(first.generation, second.generation)
        XCTAssertEqual(first.originalStatusLine, second.originalStatusLine)
        try connection.rollbackInstallation(second, previous: first)
        XCTAssertEqual(try store.loadProfile(id: first.id).installedCommand, first.installedCommand)
        var current = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual((current["env"] as? [String: String])?["KEEP"], "yes")
        XCTAssertEqual(current["effortLevel"] as? String, "high")
        current["newPreference"] = true
        var currentStatusLine = try XCTUnwrap(current["statusLine"] as? [String: Any])
        currentStatusLine["padding"] = 5
        current["statusLine"] = currentStatusLine
        try JSONSerialization.data(withJSONObject: current).write(to: url)
        XCTAssertTrue(try connection.uninstall(profileID: first.id))
        current = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual((current["statusLine"] as? [String: Any])?["command"] as? String, "printf original")
        XCTAssertEqual((current["statusLine"] as? [String: Any])?["padding"] as? Int, 5)
        XCTAssertEqual(current["newPreference"] as? Bool, true)
        _ = try connection.install(directory: path, name: "Personal", helperPath: "/tmp/helper")
        current["statusLine"] = ["type": "command", "command": "printf changed"]
        try JSONSerialization.data(withJSONObject: current).write(to: url)
        XCTAssertFalse(try connection.uninstall(profileID: first.id))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])?["statusLine"] as? [String: String], ["type": "command", "command": "printf changed"])
    }

    func testWhitespacePathProfilesAreIsolatedAndSnapshotsAreWhitelisted() throws {
        let (root, store, path) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = try ClaudeSubscriptionConnection(store: store).install(directory: path, name: "Personal", helperPath: "/tmp/helper")
        let other = ClaudeSubscriptionProfile(configDirectory: root.appendingPathComponent("work").path, name: "Work")
        XCTAssertNotEqual(profile.id, other.id)
        let sample = try XCTUnwrap(ClaudeSubscriptionStatusLine.snapshot(input: input(), profile: profile))
        try store.saveSnapshot(sample)
        let json = String(decoding: try JSONEncoder().encode(sample), as: UTF8.self)
        XCTAssertFalse(json.contains("DO_NOT_PERSIST"))
        XCTAssertFalse(json.contains("/private/project"))
        XCTAssertFalse(json.contains("total_cost"))
        XCTAssertNil(try store.latestSnapshot(for: other))
        let attrs = try FileManager.default.attributesOfItem(atPath: store.directory(for: profile.id).appendingPathComponent("snapshot-\(sample.sessionID).json").path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testRepeatedFeedbackDoesNotRenewEvidenceAndGenerationInvalidatesOldLogin() throws {
        let (root, store, path) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var profile = try ClaudeSubscriptionConnection(store: store).install(directory: path, name: "Personal", helperPath: "/tmp/helper")
        let payload = try input()
        let past = Date().addingTimeInterval(-600)
        try store.saveSnapshot(XCTUnwrap(ClaudeSubscriptionStatusLine.snapshot(input: payload, profile: profile, now: past)))
        try store.saveSnapshot(XCTUnwrap(ClaudeSubscriptionStatusLine.snapshot(input: payload, profile: profile)))
        let sample = try XCTUnwrap(store.latestSnapshot(for: profile))
        XCTAssertEqual(sample.observedAt.timeIntervalSince1970, past.timeIntervalSince1970, accuracy: 0.01)
        XCTAssertGreaterThan(sample.receivedAt, sample.observedAt)
        profile = try ClaudeSubscriptionConnection(store: store).install(directory: path, name: "Personal", helperPath: "/tmp/helper", renewBinding: true)
        XCTAssertNil(try store.latestSnapshot(for: profile))
    }

    func testZeroAndFullUsageMissingWeeklyAndMalformedValues() throws {
        let profile = ClaudeSubscriptionProfile(configDirectory: "/tmp/official-test", name: "Test")
        XCTAssertEqual(try ClaudeSubscriptionStatusLine.snapshot(input: input(used: 0, weekly: false), profile: profile)?.fiveHour?.usedPercent, 0)
        XCTAssertNil(try ClaudeSubscriptionStatusLine.snapshot(input: input(weekly: false), profile: profile)?.sevenDay)
        XCTAssertEqual(try ClaudeSubscriptionStatusLine.snapshot(input: input(used: 100), profile: profile)?.fiveHour?.usedPercent, 100)
        XCTAssertThrowsError(try ClaudeSubscriptionStatusLine.snapshot(input: input(used: 101), profile: profile))
        XCTAssertThrowsError(try ClaudeSubscriptionStatusLine.snapshot(input: Data("{}".utf8), profile: profile))
    }

    func testWaitingAndResetHaveNoFakeRemainingButStaleKeepsQuota() async throws {
        let (root, store, path) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = try ClaudeSubscriptionConnection(store: store).install(directory: path, name: "Personal", helperPath: "/tmp/helper")
        let provider = ClaudeSubscriptionProvider(store: store)
        let credential = AccountCredential(providerId: provider.id, authMethod: .auto, credential: path, metadata: ["sourceKind": "claude-cli-profile"])
        let waiting = try await provider.fetchUsage(with: credential)
        XCTAssertTrue(waiting.fetchedAt.isEmpty)
        XCTAssertNil(UsageNormalizer.normalize(provider: provider, usage: waiting).remainingPercent)
        let payload = try input(used: 98)
        try store.saveSnapshot(XCTUnwrap(ClaudeSubscriptionStatusLine.snapshot(input: payload, profile: profile, now: Date().addingTimeInterval(-600))))
        // 未到重置时间的旧快照仍是有效额度：菜单栏依赖 remainingPercent，不能因几分钟没用 Code 而消失。
        let stale = UsageNormalizer.normalize(provider: provider, usage: try await provider.fetchUsage(with: credential))
        XCTAssertEqual(try XCTUnwrap(stale.remainingPercent), 2, accuracy: 0.001)
        XCTAssertEqual(stale.windows.count, 2)
        XCTAssertEqual(stale.status, "critical")
        XCTAssertEqual(stale.headline.primary, "Last synced")
        XCTAssertNil(stale.costSummary)
        XCTAssertNil(stale.membershipLabel)
        try store.saveSnapshot(XCTUnwrap(ClaudeSubscriptionStatusLine.snapshot(input: input(used: 100, reset: Date().addingTimeInterval(-20), weekly: false), profile: profile)))
        let reset = UsageNormalizer.normalize(provider: provider, usage: try await provider.fetchUsage(with: credential))
        XCTAssertTrue(reset.windows.isEmpty)
        XCTAssertNil(reset.remainingPercent)
        XCTAssertEqual(reset.headline.primary, "Limits reset")
    }

    func testCLIEnvironmentDropsAPIRoutingButKeepsNetworkProxy() throws {
        XCTAssertThrowsError(try ClaudeSubscriptionConnection.validatedDirectory(""))
        XCTAssertThrowsError(try ClaudeSubscriptionConnection.validatedDirectory("/"))
        XCTAssertThrowsError(try ClaudeSubscriptionConnection.validatedDirectory("/Users/.."))
        XCTAssertThrowsError(try ClaudeSubscriptionConnection.validatedDirectory("relative"))
        let env = ClaudeSubscriptionLaunch.environment(
            ["ANTHROPIC_BASE_URL": "https://proxy.invalid", "ANTHROPIC_AUTH_TOKEN": "secret", "ANTHROPIC_MODEL": "proxy-model",
             "HTTPS_PROXY": "http://127.0.0.1:7890", "PATH": "/usr/bin"],
            configDirectory: "/tmp/it's a profile")
        XCTAssertNil(env["ANTHROPIC_BASE_URL"])
        XCTAssertNil(env["ANTHROPIC_AUTH_TOKEN"])
        XCTAssertNil(env["ANTHROPIC_MODEL"])
        XCTAssertEqual(env["HTTPS_PROXY"], "http://127.0.0.1:7890")
        XCTAssertEqual(env["PATH"], "/usr/bin")
        XCTAssertEqual(env["CLAUDE_CONFIG_DIR"], "/tmp/it's a profile")
        XCTAssertEqual(ClaudeSubscriptionLaunch.terminalCommand(configDirectory: "/tmp/it's a profile"),
                       "CLAUDE_CONFIG_DIR='/tmp/it'\\''s a profile' claude")
        // 默认目录若显式设置 CLAUDE_CONFIG_DIR，官方 CLI 会改读另一份登录；必须去掉，包括继承来的值。
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID().uuidString)").path
        let defaultEnv = ClaudeSubscriptionLaunch.environment(["CLAUDE_CONFIG_DIR": "\(home)/.claude", "PATH": "/usr/bin"],
                                                              configDirectory: "\(home)/.claude/", homeDirectory: home)
        XCTAssertNil(defaultEnv["CLAUDE_CONFIG_DIR"])
        XCTAssertEqual(defaultEnv["PATH"], "/usr/bin")
        XCTAssertEqual(ClaudeSubscriptionLaunch.terminalCommand(configDirectory: "\(home)/.claude", homeDirectory: home), "claude")
        XCTAssertEqual(ClaudeSubscriptionLaunch.environment([:], configDirectory: "\(home)/.claude-aiusage/accounts/a1", homeDirectory: home)["CLAUDE_CONFIG_DIR"],
                       "\(home)/.claude-aiusage/accounts/a1")
        let settings = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(ClaudeSubscriptionLaunch.settingsOverride().utf8)) as? [String: Any])
        XCTAssertEqual((settings["env"] as? [String: String])?["ANTHROPIC_AUTH_TOKEN"], "")
        XCTAssertEqual(settings["apiKeyHelper"] as? String, "")
    }

    func testAuthStatusAcceptsOnlySubscriptionLoginAndKeepsIdentityFields() throws {
        let pro = try ClaudeAuthStatus(json: Data(#"""
        {"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","configDirectory":"/Users/me/.claude",
         "email":"me@example.com","orgId":"org-1","orgName":"Me","subscriptionType":"pro","projectsDirectory":"/x"}
        """#.utf8))
        XCTAssertTrue(pro.isSubscription)
        XCTAssertEqual(pro.email, "me@example.com")
        XCTAssertEqual(pro.organizationName, "Me")
        XCTAssertEqual(pro.planLabel, "Pro")
        XCTAssertEqual(pro.configDirectory, "/Users/me/.claude")
        XCTAssertEqual(ClaudeAuthStatus.planLabel("max"), "Max")
        XCTAssertNil(ClaudeAuthStatus.planLabel("  "))
        XCTAssertFalse(try ClaudeAuthStatus(json: Data(#"{"loggedIn":true,"authMethod":"console"}"#.utf8)).isSubscription)
        XCTAssertFalse(try ClaudeAuthStatus(json: Data(#"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"bedrock"}"#.utf8)).isSubscription)
        XCTAssertFalse(try ClaudeAuthStatus(json: Data(#"{"loggedIn":false}"#.utf8)).isSubscription)
        XCTAssertThrowsError(try ClaudeAuthStatus(json: Data("[]".utf8)))
    }

    func testProxyRoutedDirectoryExplainsMissingQuotaAndShowsReportedIdentity() async throws {
        let (root, store, path) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var profile = try ClaudeSubscriptionConnection(store: store).install(directory: path, name: "Personal", helperPath: "/tmp/helper")
        profile.email = "me@example.com"
        profile.subscriptionType = "max"
        try store.saveProfile(profile)
        let provider = ClaudeSubscriptionProvider(store: store)
        let credential = AccountCredential(providerId: provider.id, authMethod: .auto, credential: path, metadata: ["sourceKind": "claude-cli-profile"])
        let waiting = UsageNormalizer.normalize(provider: provider, usage: try await provider.fetchUsage(with: credential))
        XCTAssertEqual(waiting.statusLabel, "Waiting")
        XCTAssertEqual(waiting.accountLabel, "me@example.com")
        XCTAssertEqual(waiting.membershipLabel, "Max")

        let url = URL(fileURLWithPath: path).appendingPathComponent("settings.json")
        var settings = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        settings["env"] = ["ANTHROPIC_BASE_URL": "http://127.0.0.1:4000", "CLAUDE_CODE_USE_BEDROCK": "0"]
        try JSONSerialization.data(withJSONObject: settings).write(to: url)
        XCTAssertTrue(ClaudeSubscriptionConnection.routesThroughAPI(directory: path))
        let routed = UsageNormalizer.normalize(provider: provider, usage: try await provider.fetchUsage(with: credential))
        XCTAssertEqual(routed.statusLabel, "Proxy session")
        XCTAssertNil(routed.remainingPercent)

        settings["env"] = ["CLAUDE_CODE_USE_BEDROCK": "0", "KEEP": "yes"]
        try JSONSerialization.data(withJSONObject: settings).write(to: url)
        XCTAssertFalse(ClaudeSubscriptionConnection.routesThroughAPI(directory: path))
    }

    func testPackagedHelperPreservesOriginalOutputAndSkipsProxyOrOldGeneration() throws {
        guard let helper = ProcessInfo.processInfo.environment["AIUSAGE_TEST_CLAUDE_HELPER"] else {
            throw XCTSkip("Set AIUSAGE_TEST_CLAUDE_HELPER to the built QuotaServer for the executable smoke test.")
        }
        let (root, store, path) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let settings = URL(fileURLWithPath: path).appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: ["statusLine": ["type": "command", "command": "/bin/cat; exit 7"]]).write(to: settings)
        let profile = try ClaudeSubscriptionConnection(store: store).install(directory: path, name: "Test", helperPath: helper)
        func run(_ payload: Data, generation: String, proxy: Bool = false) throws -> Data {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: helper)
            process.arguments = ["--claude-statusline", profile.id, generation, store.root.path]
            var env = ProcessInfo.processInfo.environment
            for key in ClaudeSubscriptionLaunch.authEnvironmentKeys { env.removeValue(forKey: key) }
            if proxy { env["ANTHROPIC_AUTH_TOKEN"] = "fixture-only" }
            process.environment = env
            let input = Pipe(), output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            try input.fileHandleForWriting.write(contentsOf: payload)
            try input.fileHandleForWriting.close()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 7)
            return data
        }
        let payload = try input()
        XCTAssertEqual(try run(payload, generation: profile.generation, proxy: true), payload)
        XCTAssertNil(try store.latestSnapshot(for: profile))
        XCTAssertEqual(try run(payload, generation: "old-login"), payload)
        XCTAssertNil(try store.latestSnapshot(for: profile))
        XCTAssertEqual(try run(payload, generation: profile.generation), payload)
        XCTAssertEqual(try store.latestSnapshot(for: profile)?.fiveHour?.usedPercent, 23.5)
        let malformed = Data("invalid-json".utf8)
        XCTAssertEqual(try run(malformed, generation: profile.generation), malformed)
        XCTAssertEqual(try store.latestSnapshot(for: profile)?.fiveHour?.usedPercent, 23.5)
    }

    func testFullSettingsPreservesOwnedFeedbackButDoesNotResurrectDisconnectedBackup() throws {
        let (root, store, path) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let connection = ClaudeSubscriptionConnection(store: store)
        let profile = try connection.install(directory: path, name: "测试", helperPath: "/tmp/helper")
        let settingsURL = URL(fileURLWithPath: profile.configDirectory).appendingPathComponent("settings.json")
        let current = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any])
        let incoming: [String: Any] = ["model": "sonnet", "env": ["KEEP": "yes"]]
        let replaced = try connection.preservingStatusLine(in: incoming, current: current, directory: profile.configDirectory)
        XCTAssertEqual((replaced["statusLine"] as? [String: Any])?["command"] as? String, profile.installedCommand)
        XCTAssertEqual(replaced["model"] as? String, "sonnet")
        XCTAssertEqual((replaced["env"] as? [String: String])?["KEEP"], "yes")
        XCTAssertTrue(try connection.uninstall(profileID: profile.id))
        let disconnected = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any])
        let restored = try connection.preservingStatusLine(in: current, current: disconnected, directory: profile.configDirectory)
        XCTAssertNil(restored["statusLine"])
        var userChanged = current
        userChanged["statusLine"] = ["type": "command", "command": "printf custom"]
        let preservedUser = try connection.preservingStatusLine(in: current, current: userChanged, directory: profile.configDirectory)
        XCTAssertEqual((preservedUser["statusLine"] as? [String: String])?["command"], "printf custom")
    }

    func testMissingOrCorruptProfileDoesNotWrapFeedbackOrOverwriteSettings() throws {
        for corrupt in [false, true] {
            let (root, store, path) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
            let connection = ClaudeSubscriptionConnection(store: store)
            let profile = try connection.install(directory: path, name: "测试", helperPath: "/tmp/helper")
            let settings = URL(fileURLWithPath: path).appendingPathComponent("settings.json")
            let before = try Data(contentsOf: settings)
            let profileURL = try store.directory(for: profile.id).appendingPathComponent("profile.json")
            if corrupt { try Data("invalid-json".utf8).write(to: profileURL) }
            else { try FileManager.default.removeItem(at: profileURL) }
            XCTAssertThrowsError(try connection.install(directory: path, name: "重连", helperPath: "/tmp/new-helper", renewBinding: true))
            XCTAssertEqual(try Data(contentsOf: settings), before)
            if corrupt { XCTAssertEqual(try Data(contentsOf: profileURL), Data("invalid-json".utf8)) }
            else { XCTAssertFalse(FileManager.default.fileExists(atPath: profileURL.path)) }
        }
    }

    func testRestoredOldWrapperUsesKnownOriginalInsteadOfWrappingItAgain() throws {
        let (root, store, path) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let settings = URL(fileURLWithPath: path).appendingPathComponent("settings.json")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["statusLine": ["type": "command", "command": "printf original"]]).write(to: settings)
        let connection = ClaudeSubscriptionConnection(store: store)
        let first = try connection.install(directory: path, name: "测试", helperPath: "/tmp/helper")
        let oldSettings = try Data(contentsOf: settings)
        _ = try connection.install(directory: path, name: "测试", helperPath: "/tmp/new-helper", renewBinding: true)
        try oldSettings.write(to: settings)
        let reconnected = try connection.install(directory: path, name: "重连", helperPath: "/tmp/new-helper", renewBinding: true)
        XCTAssertEqual(reconnected.originalStatusLine, first.originalStatusLine)
        XCTAssertNotEqual(reconnected.installedCommand, first.installedCommand)
        XCTAssertTrue(try connection.uninstall(profileID: reconnected.id))
        let restored = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
        XCTAssertEqual((restored["statusLine"] as? [String: String])?["command"], "printf original")
        // 已停用后手动恢复旧 wrapper，仍使用受保护的原命令备份。
        try oldSettings.write(to: settings)
        let recovered = try connection.install(directory: path, name: "重连", helperPath: "/tmp/new-helper", renewBinding: true)
        XCTAssertEqual(recovered.originalStatusLine, first.originalStatusLine)
    }

    func testPackagedHelperRejectsRecursiveOriginalFromOldProfile() throws {
        guard let helper = ProcessInfo.processInfo.environment["AIUSAGE_TEST_CLAUDE_HELPER"] else {
            throw XCTSkip("Set AIUSAGE_TEST_CLAUDE_HELPER to test the executable.")
        }
        let (root, store, path) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        var profile = try ClaudeSubscriptionConnection(store: store).install(directory: path, name: "测试", helperPath: helper)
        // 该命令一旦执行只会退出 91；不会在回归测试中实际制造递归。
        profile.originalStatusLine = try JSONSerialization.data(withJSONObject: ["type": "command", "command": "exit 91; \(profile.installedCommand!)"])
        try store.saveProfile(profile)
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: helper)
        process.arguments = ["--claude-statusline", profile.id, "old-generation", store.root.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 1)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("reconnect"))
        XCTAssertThrowsError(try ClaudeSubscriptionConnection(store: store).install(directory: path, name: "测试", helperPath: helper))
        // 用户恢复正确状态栏后允许重新连接，不要求删除可读的整个 profile。
        let settings = URL(fileURLWithPath: path).appendingPathComponent("settings.json")
        try JSONSerialization.data(withJSONObject: ["statusLine": ["type": "command", "command": "printf recovered"]]).write(to: settings)
        let recovered = try ClaudeSubscriptionConnection(store: store).install(directory: path, name: "测试", helperPath: helper)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: recovered.originalStatusLine!) as? [String: Any])
        XCTAssertEqual(original["command"] as? String, "printf recovered")
    }

    func testPackagedHelperHandlesLargeInputWhenOriginalReadsNoneOrPart() throws {
        guard let helper = ProcessInfo.processInfo.environment["AIUSAGE_TEST_CLAUDE_HELPER"] else {
            throw XCTSkip("Set AIUSAGE_TEST_CLAUDE_HELPER to test the executable.")
        }
        let (root, store, path) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let settings = URL(fileURLWithPath: path).appendingPathComponent("settings.json")
        let inputURL = root.appendingPathComponent("input.json")
        try JSONSerialization.data(withJSONObject: ["session_id": UUID().uuidString, "padding": String(repeating: "x", count: 128 * 1024)]).write(to: inputURL)
        for original in ["printf original-output; exit 7", "dd bs=1 count=1 of=/dev/null 2>/dev/null; printf original-output; exit 7"] {
            try JSONSerialization.data(withJSONObject: ["statusLine": ["type": "command", "command": original]]).write(to: settings)
            let profile = try ClaudeSubscriptionConnection(store: store).install(directory: path, name: "测试", helperPath: helper)
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: helper)
            process.arguments = ["--claude-statusline", profile.id, profile.generation, store.root.path]
            let input = try FileHandle(forReadingFrom: inputURL); defer { try? input.close() }
            process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(String(decoding: data, as: UTF8.self), "original-output")
            XCTAssertEqual(process.terminationReason, .exit)
            XCTAssertEqual(process.terminationStatus, 7)
        }
    }
}
