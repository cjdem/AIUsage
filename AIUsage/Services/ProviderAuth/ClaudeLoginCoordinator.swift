import AppKit
import Combine
import Foundation
import QuotaBackend

private final class WeakClaudeLoginBox: @unchecked Sendable {
    weak var value: ClaudeLoginCoordinator?
    init(_ value: ClaudeLoginCoordinator) { self.value = value }
}

/// 在后台运行官方 `claude auth login`，由 AIUsage 打开浏览器授权页并自动识别完成。
/// 不打开终端，不读取或保存凭证：登录结果由官方 CLI 写入它自己的存储，这里只用 `auth status` 确认。
@MainActor
final class ClaudeLoginCoordinator: ObservableObject {
    enum Phase: Equatable {
        case idle
        case starting
        case waitingForBrowser
        case verifying
        case succeeded(ClaudeAuthStatus)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var authURL: URL?
    /// 回调不可用、只能打开手动授权页时为真：页面会显示授权码，需要粘贴回来。
    @Published private(set) var expectsPastedCode = false
    private(set) var configDirectory: String?

    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var outputBuffer = ""
    /// 终端输出里打印的是手动授权码链接；$BROWSER 收到的才是能自动回调的链接，优先用后者。
    private var printedURL: URL?
    private var sessionDirectory: URL?
    private var watchTask: Task<Void, Never>?
    private var attempt = UUID()

    var isRunning: Bool {
        switch phase {
        case .starting, .waitingForBrowser, .verifying: return true
        case .idle, .succeeded, .failed: return false
        }
    }

    func start(configDirectory: String, executable: String) {
        cancel()
        let attempt = UUID()
        self.attempt = attempt
        self.configDirectory = configDirectory
        expectsPastedCode = false
        phase = .starting

        let fm = FileManager.default
        let session = fm.temporaryDirectory.appendingPathComponent("aiusage-claude-login-\(UUID().uuidString)", isDirectory: true)
        let urlFile = session.appendingPathComponent("auth-url")
        let browserHook = session.appendingPathComponent("open-url")
        do {
            try fm.createDirectory(at: session, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.createDirectory(atPath: configDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // CLI 通过 $BROWSER 打开授权页；这里只把链接交给 AIUsage，由 App 打开一次，避免重复标签页。
            let hook = "#!/bin/sh\nprintf '%s' \"$1\" > \(ClaudeSubscriptionLaunch.quote(urlFile.path))\n"
            try hook.write(to: browserHook, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: browserHook.path)
        } catch {
            phase = .failed(L("Couldn't prepare the sign-in session.", "无法准备登录环境。"))
            return
        }
        sessionDirectory = session

        let process = Process()
        // script 提供伪终端，官方 CLI 才会走完整的浏览器登录流程；终端窗口不会出现。
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", executable, "--settings", (try? ClaudeSubscriptionLaunch.settingsOverride()) ?? "{}",
                             "auth", "login", "--claudeai"]
        var environment = ClaudeSubscriptionLaunch.environment(ProcessInfo.processInfo.environment, configDirectory: configDirectory)
        environment["BROWSER"] = browserHook.path
        environment["TERM"] = "xterm-256color"
        environment["PATH"] = [environment["PATH"]?.nilIfBlank, aiusageDefaultCLIPath()].compactMap { $0 }.joined(separator: ":")
        process.environment = environment
        process.currentDirectoryURL = session

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        let box = WeakClaudeLoginBox(self)
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            let text = String(decoding: data, as: UTF8.self)
            DispatchQueue.main.async { box.value?.consume(text, attempt: attempt) }
        }
        process.terminationHandler = { finished in
            let status = finished.terminationStatus
            DispatchQueue.main.async { box.value?.processExited(status: status, attempt: attempt) }
        }

        do {
            try process.run()
        } catch {
            cleanup()
            phase = .failed(L("Couldn't start Claude Code.", "无法启动 Claude Code。"))
            return
        }
        self.process = process
        inputPipe = input
        outputPipe = output
        watch(urlFile: urlFile, executable: executable, attempt: attempt)
    }

    /// 浏览器回调失败时，官方页面会显示授权码，CLI 在提示处等待粘贴。
    func submitCode(_ code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let inputPipe, process?.isRunning == true else { return }
        try? inputPipe.fileHandleForWriting.write(contentsOf: Data((trimmed + "\r").utf8))
        phase = .verifying
    }

    func reopenBrowser() {
        if let authURL { NSWorkspace.shared.open(authURL) }
    }

    func cancel() {
        attempt = UUID()
        watchTask?.cancel()
        watchTask = nil
        if let process, process.isRunning { process.terminate() }
        cleanup()
        authURL = nil
        phase = .idle
    }

    // MARK: - Private

    private func watch(urlFile: URL, executable: String, attempt: UUID) {
        let directory = configDirectory ?? ""
        watchTask = Task { [weak self] in
            let started = Date()
            let deadline = started.addingTimeInterval(10 * 60)
            var lastStatusCheck = Date()
            while !Task.isCancelled, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(300))
                guard let self, self.attempt == attempt else { return }
                if self.authURL == nil,
                   let raw = try? String(contentsOf: urlFile, encoding: .utf8),
                   let url = Self.authorizationURL(in: raw) {
                    self.present(url, pastedCode: false)
                } else if self.authURL == nil, let printed = self.printedURL, Date().timeIntervalSince(started) > 3 {
                    // 个别版本不调用 $BROWSER：退回手动授权页，并提示粘贴页面上的授权码。
                    self.present(printed, pastedCode: true)
                }
                // CLI 收到回调后会自行退出；这里的轮询只兜底个别版本退出前停住的情况。
                if self.authURL != nil, Date().timeIntervalSince(lastStatusCheck) > 4 {
                    lastStatusCheck = Date()
                    if let status = try? await ClaudeSubscriptionManager.authStatus(directory: directory, executable: executable),
                       status.isSubscription, self.attempt == attempt {
                        self.finish(status)
                        return
                    }
                }
            }
            guard let self, self.attempt == attempt, !Task.isCancelled else { return }
            self.fail(L("Sign-in timed out. Try again.", "登录超时，请重试。"))
        }
    }

    private func consume(_ text: String, attempt: UUID) {
        guard self.attempt == attempt else { return }
        outputBuffer += text
        if outputBuffer.count > 64 * 1024 { outputBuffer = String(outputBuffer.suffix(16 * 1024)) }
        if printedURL == nil { printedURL = Self.authorizationURL(in: outputBuffer) }
    }

    private func present(_ url: URL, pastedCode: Bool) {
        authURL = url
        expectsPastedCode = pastedCode
        if phase == .starting { phase = .waitingForBrowser }
        NSWorkspace.shared.open(url)
    }

    private func processExited(status: Int32, attempt: UUID) {
        guard self.attempt == attempt, isRunning else { return }
        phase = .verifying
        let directory = configDirectory ?? ""
        Task { [weak self] in
            let executable = await ClaudeSubscriptionManager.resolveExecutable()
            let result = try? await ClaudeSubscriptionManager.authStatus(directory: directory, executable: executable ?? "claude")
            guard let self, self.attempt == attempt else { return }
            if let result, result.isSubscription {
                self.finish(result)
            } else if result?.loggedIn == true {
                self.fail(L("This login isn't a Claude Pro or Max subscription.", "该登录不是 Claude Pro / Max 订阅账号。"))
            } else {
                self.fail(status == 0 ? L("Sign-in wasn't completed.", "登录未完成。")
                                      : L("Sign-in was cancelled or failed. Try again.", "登录已取消或失败，请重试。"))
            }
        }
    }

    private func finish(_ status: ClaudeAuthStatus) {
        watchTask?.cancel()
        watchTask = nil
        if let process, process.isRunning { process.terminate() }
        cleanup()
        phase = .succeeded(status)
        // 授权完成后把用户带回 AIUsage，直接看到连接结果。
        NSApp.activate()
    }

    private func fail(_ message: String) {
        watchTask?.cancel()
        watchTask = nil
        if let process, process.isRunning { process.terminate() }
        cleanup()
        phase = .failed(message)
    }

    private func cleanup() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        inputPipe = nil
        process = nil
        outputBuffer = ""
        printedURL = nil
        if let sessionDirectory { try? FileManager.default.removeItem(at: sessionDirectory) }
        sessionDirectory = nil
    }

    /// 只接受官方授权页；终端输出里的转义序列、换行和其他链接一律忽略。
    nonisolated static func authorizationURL(in text: String) -> URL? {
        // ICU 语法：\x{07} / \x{1B} 截断终端超链接的 BEL / ESC 结束符。
        let pattern = #"https://[^\s\x{07}\x{1B}"'<>]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in regex.matches(in: text, range: range) {
            guard let swiftRange = Range(match.range, in: text),
                  let url = URL(string: String(text[swiftRange])),
                  let host = url.host?.lowercased(),
                  ["claude.ai", "claude.com", "anthropic.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }),
                  url.path.contains("oauth") else { continue }
            return url
        }
        return nil
    }
}
