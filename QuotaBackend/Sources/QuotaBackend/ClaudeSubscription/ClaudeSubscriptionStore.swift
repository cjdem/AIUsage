import Foundation
import CryptoKit

/// 这里只保存官方配置目录引用和额度快照，不保存登录凭证。
public struct ClaudeSubscriptionProfile: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let configDirectory: String
    public var name: String
    public var generation: String
    public var originalStatusLine: Data?
    public var installedCommand: String?
    /// 连接时由官方 `auth status` 返回的身份，仅用于展示；旧 profile 解码为空。
    public var email: String?
    public var organizationName: String?
    public var subscriptionType: String?

    public init(configDirectory: String, name: String) {
        let path = URL(fileURLWithPath: NSString(string: configDirectory).expandingTildeInPath)
            .standardizedFileURL.resolvingSymlinksInPath().path
        self.id = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        self.configDirectory = path
        self.name = name
        self.generation = UUID().uuidString
    }
}

public struct ClaudeSubscriptionSnapshot: Codable, Sendable, Equatable {
    public struct Window: Codable, Sendable, Equatable {
        public let usedPercent: Double
        public let resetAt: Date
        public init(usedPercent: Double, resetAt: Date) {
            self.usedPercent = usedPercent
            self.resetAt = resetAt
        }
    }
    public let schemaVersion: Int
    public let profileID: String
    public let generation: String
    public let sessionID: String
    public var receivedAt: Date
    /// 仅表示这些额度字段第一次出现/变化的时间，不冒充官方测量时间。
    public var observedAt: Date
    public let fiveHour: Window?
    public let sevenDay: Window?
}

public struct ClaudeSubscriptionStore: Sendable {
    public let root: URL
    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/aiusage/claude-subscriptions", isDirectory: true)) {
        self.root = root
    }

    public func directory(for id: String) throws -> URL {
        guard id.count == 64, id.allSatisfy({ $0.isHexDigit }) else {
            throw ProviderError("invalid_profile", "Invalid Claude profile reference.")
        }
        return root.appendingPathComponent(id, isDirectory: true)
    }

    public func loadProfile(id: String) throws -> ClaudeSubscriptionProfile {
        let url = try directory(for: id).appendingPathComponent("profile.json")
        let profile = try JSONDecoder().decode(ClaudeSubscriptionProfile.self, from: Data(contentsOf: url))
        guard profile.id == id,
              ClaudeSubscriptionProfile(configDirectory: profile.configDirectory, name: "").id == id else {
            throw ProviderError("invalid_profile", "Claude profile directory no longer matches its reference.")
        }
        return profile
    }

    public func saveProfile(_ profile: ClaudeSubscriptionProfile) throws {
        try write(JSONEncoder().encode(profile), to: directory(for: profile.id).appendingPathComponent("profile.json"))
    }

    func connectedProfiles() -> [ClaudeSubscriptionProfile] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { try? loadProfile(id: $0.lastPathComponent) }
            .filter { $0.installedCommand != nil }
            .sorted { $0.id < $1.id }
    }

    public func latestSnapshot(for profile: ClaudeSubscriptionProfile) throws -> ClaudeSubscriptionSnapshot? {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory(for: profile.id), includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.lastPathComponent.hasPrefix("snapshot-") && $0.pathExtension == "json" }
            .compactMap { url -> ClaudeSubscriptionSnapshot? in
                guard let data = try? Data(contentsOf: url), data.count <= 8192,
                      let sample = try? JSONDecoder().decode(ClaudeSubscriptionSnapshot.self, from: data),
                      sample.schemaVersion == 1, sample.profileID == profile.id,
                      sample.generation == profile.generation,
                      sample.observedAt <= Date().addingTimeInterval(60),
                      sample.fiveHour != nil || sample.sevenDay != nil else { return nil }
                return sample
            }
            .max { $0.observedAt < $1.observedAt }
    }

    public func saveSnapshot(_ snapshot: ClaudeSubscriptionSnapshot) throws {
        guard UUID(uuidString: snapshot.sessionID) != nil else {
            throw ProviderError("invalid_snapshot", "Claude session ID is not valid.")
        }
        let folder = try directory(for: snapshot.profileID)
        let url = folder.appendingPathComponent("snapshot-\(snapshot.sessionID).json")
        var sample = snapshot
        if let previous = try? JSONDecoder().decode(ClaudeSubscriptionSnapshot.self, from: Data(contentsOf: url)),
           previous.generation == sample.generation,
           previous.fiveHour == sample.fiveHour, previous.sevenDay == sample.sevenDay {
            sample.observedAt = previous.observedAt
        }
        try write(JSONEncoder().encode(sample), to: url)
        // 只保留本功能自己的最近 20 个会话快照，不建历史数据库。
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.lastPathComponent.hasPrefix("snapshot-") && $0.pathExtension == "json" }
            .sorted { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                > (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        for file in files.dropFirst(20) { try? FileManager.default.removeItem(at: file) }
    }

    public func write(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.deletingLastPathComponent().path)
        try data.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
