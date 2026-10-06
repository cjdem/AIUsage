import Foundation

/// Token、调用分析和已装清单共用目录发现；不读取登录凭证。
struct ClaudeLogDirectoryResolver {
    let homeDirectory: String
    let environment: [String: String]

    var configDirectories: [String] {
        let configured = environment["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var paths = configured.isEmpty
            ? ["\(homeDirectory)/.config/claude", "\(homeDirectory)/.claude"]
            : configured.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
        let store = ClaudeSubscriptionStore(root: URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent(".config/aiusage/claude-subscriptions"))
        paths += store.connectedProfiles().map(\.configDirectory)
        var seen = Set<String>()
        return paths.filter { !$0.isEmpty }.compactMap { path in
            var url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
                .standardizedFileURL.resolvingSymlinksInPath()
            if url.lastPathComponent == "projects" { url.deleteLastPathComponent() }
            return seen.insert(url.path).inserted ? url.path : nil
        }
    }

    var projectRoots: [String] { configDirectories.map { "\($0)/projects" } }

    func sessionFiles(cutoff: Date? = nil) -> [String] {
        var seen = Set<String>()
        var files: [String] = []
        for root in projectRoots {
            guard let iterator = FileManager.default.enumerator(at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in iterator where url.pathExtension.lowercased() == "jsonl" {
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
                if values?.isRegularFile == false { continue }
                if let cutoff, let modified = values?.contentModificationDate, modified < cutoff { continue }
                let path = url.standardizedFileURL.resolvingSymlinksInPath().path
                if seen.insert(path).inserted { files.append(path) }
            }
        }
        return files.sorted()
    }
}
