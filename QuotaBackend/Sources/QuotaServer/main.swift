import Foundation
import Network
import os.log
import QuotaBackend
import QuotaServerCore
import Darwin

private let startupLog = Logger(subsystem: "com.aiusage.quotaserver", category: "Startup")

setbuf(stdout, nil)
setbuf(stderr, nil)

if CommandLine.arguments.dropFirst().first == "--claude-statusline" {
    exit(ClaudeSubscriptionStatusLine.run(arguments: CommandLine.arguments))
}

// 父进程（宿主 App）一旦退出/崩溃/被强杀，立即终止自身，避免变成占端口的孤儿 helper。
ParentWatchdog.install()

// MARK: - QuotaServer Entry Point
// Usage: swift run QuotaServer [--port 4318] [--host 0.0.0.0]
//
// Claude Code Proxy (optional):
//   Set environment variables to enable proxy:
//     OPENAI_API_KEY=sk-xxx       (required)
//     OPENAI_BASE_URL=https://... (optional, defaults to https://api.openai.com)
//     OPENAI_API_MODE=chat_completions|responses (optional, defaults to chat_completions)
//     BIG_MODEL=gpt-4o            (optional, maps to opus)
//     MIDDLE_MODEL=gpt-4o         (optional, maps to sonnet)
//     SMALL_MODEL=gpt-4o-mini     (optional, maps to haiku)
//     ANTHROPIC_API_KEY=sk-ant-.. (optional, for client auth)
//
//   Then use Claude Code with:
//     ANTHROPIC_BASE_URL=http://127.0.0.1:4318 claude

let args = parseArgs()
let host = args["host"] ?? "127.0.0.1"
let port = Int(args["port"] ?? "4318") ?? 4318

startupLog.info("QuotaServer starting on \(host):\(port)")

// Load proxy configuration from environment.
// PROXY_TARGET=codex 时启用 Codex 代理（/v1/responses），
// PROXY_TARGET=opencode 时启用 OpenCode 透传代理（/v1/chat/completions），
// 二者互斥，且任一启用时禁用 Claude 代理以避免端口/语义冲突。
let codexConfig = CodexProxyConfiguration.loadFromEnvironment()
let openCodeConfig = codexConfig == nil ? OpenCodeProxyConfiguration.loadFromEnvironment() : nil
let proxyConfig = (codexConfig == nil && openCodeConfig == nil) ? ClaudeProxyConfiguration.loadFromEnvironment() : nil

if let cfg = proxyConfig {
    let modeStr = cfg.mode == .anthropicPassthrough ? "passthrough" : "openai-convert"
    let apiStr = cfg.mode == .openaiConvert ? cfg.openAIUpstreamAPI.rawValue : "n/a"
    startupLog.info("Claude Code Proxy: enabled (mode=\(modeStr), upstream_api=\(apiStr), upstream=\(cfg.upstreamBaseURL, privacy: .private))")
} else {
    startupLog.info("Claude Code Proxy: disabled")
}

if let codexCfg = codexConfig {
    startupLog.info("Codex Proxy: enabled (upstream_api=\(codexCfg.openAIUpstreamAPI.rawValue), upstream=\(codexCfg.upstreamBaseURL, privacy: .private))")
} else {
    startupLog.info("Codex Proxy: disabled")
}

if let openCodeCfg = openCodeConfig {
    startupLog.info("OpenCode Proxy: enabled (upstream=\(openCodeCfg.upstreamBaseURL, privacy: .private))")
} else {
    startupLog.info("OpenCode Proxy: disabled")
}

var httpsConfig: HTTPSConfig?
if ProcessInfo.processInfo.environment["ENABLE_HTTPS"] == "1",
   let tlsPath = ProcessInfo.processInfo.environment["TLS_IDENTITY_PATH"] {
    let httpsPort = Int(ProcessInfo.processInfo.environment["HTTPS_PORT"] ?? "") ?? (port + 1)
    httpsConfig = HTTPSConfig(port: httpsPort, identityPath: tlsPath)
    startupLog.info("HTTPS: enabled on port \(httpsPort)")
}

let server = QuotaHTTPServer(host: host, port: port, proxyConfig: proxyConfig, codexConfig: codexConfig, openCodeConfig: openCodeConfig, httpsConfig: httpsConfig)
do {
    try await server.run()
} catch {
    // 顶层未捕获的 async throw 会走 swift_errorInMain/SIGTRAP，宿主只能看到“无法连接服务器”。
    // 改为稳定、无秘密的 stderr 契约，由 App 精确区分端口冲突与其它启动失败。
    let category = QuotaServerStartupDiagnostics.category(for: error)
    let message = QuotaServerStartupDiagnostics.singleLine(error.localizedDescription)
    fputs("AIUSAGE_STARTUP_ERROR category=\(category) message=\(message)\n", stderr)
    startupLog.error("QuotaServer startup failed category=\(category, privacy: .public): \(message, privacy: .public)")
    exit(EXIT_FAILURE)
}

private func parseArgs() -> [String: String] {
    var result: [String: String] = [:]
    let args = CommandLine.arguments.dropFirst()
    var index = args.startIndex

    while index < args.endIndex {
        let arg = args[index]
        if arg.hasPrefix("--") {
            let key = String(arg.dropFirst(2))
            let nextIndex = args.index(after: index)
            if nextIndex < args.endIndex && !args[nextIndex].hasPrefix("--") {
                result[key] = args[nextIndex]
                index = args.index(after: nextIndex)
                continue
            }
        }
        index = args.index(after: index)
    }

    return result
}
