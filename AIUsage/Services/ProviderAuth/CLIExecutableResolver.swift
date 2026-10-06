import Foundation

nonisolated func aiusageDefaultCLIPath() -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    var segments = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
        "\(home)/.local/bin",
        "\(home)/bin",
        "\(home)/.cargo/bin",
        "\(home)/.volta/bin",
        "\(home)/.bun/bin",
    ]

    segments.append(contentsOf: aiusageNvmNodeBinPaths(home: home))

    var seen = Set<String>()
    return segments.filter { seen.insert($0).inserted }.joined(separator: ":")
}

nonisolated func aiusageResolvedExecutable(named executable: String) -> String? {
    if let path = aiusageRunLoginShellWhich(executable) { return path }
    if let path = aiusageRunWhich(executable) { return path }

    let home = FileManager.default.homeDirectoryForCurrentUser.path

    var candidates = [
        "/opt/homebrew/bin/\(executable)",
        "/usr/local/bin/\(executable)",
        "/usr/bin/\(executable)",
        "/bin/\(executable)",
        "\(home)/.local/bin/\(executable)",
        "\(home)/bin/\(executable)",
        "\(home)/.cargo/bin/\(executable)",
        "\(home)/.volta/bin/\(executable)",
        "\(home)/.bun/bin/\(executable)",
    ]

    for nvmBin in aiusageNvmNodeBinPaths(home: home) {
        candidates.append("\(nvmBin)/\(executable)")
    }

    for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
        return path
    }

    return nil
}

// MARK: - Internal

nonisolated private func aiusageNvmNodeBinPaths(home: String) -> [String] {
    let nvmDir = "\(home)/.nvm/versions/node"
    guard let entries = try? FileManager.default.contentsOfDirectory(atPath: nvmDir) else { return [] }
    return entries
        .sorted()
        .reversed()
        .map { "\(nvmDir)/\($0)/bin" }
}

/// Runs `which` using the app's current environment.
nonisolated private func aiusageRunWhich(_ name: String) -> String? {
    let whichPath = "/usr/bin/which"
    guard FileManager.default.isExecutableFile(atPath: whichPath) else { return nil }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: whichPath)
    process.arguments = [name]
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = [env["PATH"], aiusageDefaultCLIPath()].compactMap { $0 }.joined(separator: ":")
    process.environment = env
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        return nil
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let path, !path.isEmpty else { return nil }
    return FileManager.default.isExecutableFile(atPath: path) ? path : nil
}

/// Spawns a login shell to inherit .zshrc / .bashrc PATH, then runs `which`.
/// macOS GUI apps don't inherit terminal PATH, so this is the reliable fallback.
nonisolated private func aiusageRunLoginShellWhich(_ name: String) -> String? {
    let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: shell)
    process.arguments = ["-l", "-c", "which \(name)"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        return nil
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let path, !path.isEmpty else { return nil }
    return FileManager.default.isExecutableFile(atPath: path) ? path : nil
}
