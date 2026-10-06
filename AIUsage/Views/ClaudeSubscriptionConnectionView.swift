import AppKit
import SwiftUI
import QuotaBackend

/// 连接 Claude 订阅：自动识别 Claude Code 已登录的账号，一键开始同步。
/// 用户不需要命名、选择目录或打开终端；登录在浏览器完成，AIUsage 自动接续。
struct ClaudeSubscriptionConnectionView: View {
    /// 重新连接某个已有配置时传入；为空时检测用户平时使用的默认 Claude Code。
    var initialDirectory: String? = nil

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var manager = ClaudeSubscriptionManager.shared
    @StateObject private var login = ClaudeLoginCoordinator()

    private enum Step: Equatable {
        case detecting
        case unavailable(String, canRetry: Bool)
        case ready(directory: String, status: ClaudeAuthStatus)
        case alreadyConnected(ClaudeSubscriptionProfile)
        case signedOut(directory: String)
        case apiLogin
        case signingIn
        case connecting
        case connected(ClaudeSubscriptionProfile)
        case failed(String)
    }

    @State private var step: Step = .detecting
    @State private var executable: String?
    @State private var authCode = ""
    @State private var showCodeEntry = false
    @State private var notice: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.easeInOut(duration: 0.2), value: step)
            footer
        }
        .padding(24)
        .frame(width: 460)
        .appPageChrome(colorScheme)
        .interactiveDismissDisabled(step == .connecting)
        .task { await detect() }
        .onChange(of: login.phase) { _, phase in handleLogin(phase) }
        .onChange(of: login.expectsPastedCode) { _, expects in if expects { showCodeEntry = true } }
        .onDisappear { if login.isRunning { Task { await abandonLogin() } } }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            ProviderIconView("claude-subscription", size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(L("Connect Claude subscription", "连接 Claude 订阅")).font(.title3.bold())
                Text(L("See your 5-hour and weekly limits in AIUsage.", "在 AIUsage 中查看 5 小时与每周额度。"))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch step {
        case .detecting:
            progressRow(L("Looking for Claude Code…", "正在查找 Claude Code…"))

        case .unavailable(let message, _):
            messageCard(icon: "exclamationmark.circle", tint: .orange, title: message,
                        detail: L("AIUsage reads subscription limits through the official Claude Code app.", "AIUsage 通过官方 Claude Code 读取订阅额度。"))

        case .ready(_, let status):
            VStack(alignment: .leading, spacing: 14) {
                accountCard(email: status.email, plan: status.planLabel,
                            caption: L("Signed in to Claude Code", "Claude Code 当前登录的账号"))
                privacyNote
            }

        case .alreadyConnected(let profile):
            VStack(alignment: .leading, spacing: 14) {
                accountCard(email: profile.email ?? profile.name, plan: ClaudeAuthStatus.planLabel(profile.subscriptionType),
                            caption: L("Already syncing", "已在同步"), checked: true)
                if let notice { Text(notice).font(.callout).foregroundStyle(.secondary) }
            }

        case .signedOut:
            messageCard(icon: "person.crop.circle.badge.questionmark", tint: .secondary,
                        title: L("Claude Code isn't signed in", "Claude Code 尚未登录"),
                        detail: L("Sign in with your Claude Pro or Max account in the browser. AIUsage continues automatically.",
                                  "在浏览器中登录 Claude Pro / Max 账号，完成后 AIUsage 会自动继续。"))

        case .apiLogin:
            messageCard(icon: "key", tint: .secondary,
                        title: L("Claude Code uses an API key", "Claude Code 当前使用 API Key 登录"),
                        detail: L("API keys don't have subscription limits. Add your Pro or Max account separately — your current login stays as it is.",
                                  "API Key 没有订阅额度。可单独添加 Pro / Max 账号，当前登录保持不变。"))

        case .signingIn:
            signingIn

        case .connecting:
            progressRow(L("Connecting…", "正在连接…"))

        case .connected(let profile):
            connected(profile)

        case .failed(let message):
            messageCard(icon: "exclamationmark.triangle", tint: .red, title: L("Couldn't connect", "连接未完成"), detail: message)
        }
    }

    private var signingIn: some View {
        VStack(alignment: .leading, spacing: 12) {
            ProviderLoginStatusCard(
                state: loginVisualState,
                title: L("Sign in with Claude", "使用 Claude 登录"),
                description: L("AIUsage opened the official Claude sign-in page in your browser. Approve access there and you'll come right back here.",
                               "已在浏览器打开 Claude 官方登录页。授权后会自动回到这里。"),
                inProgressLabel: login.authURL == nil ? L("Opening browser…", "正在打开浏览器…") : L("Waiting for approval in your browser", "等待在浏览器中授权"),
                connectingLabel: L("Confirming sign-in…", "正在确认登录…"),
                succeededLabel: L("Signed in", "登录成功"),
                copyLink: login.authURL == nil ? nil : ProviderLoginAction(title: L("Copy Link", "复制链接")) {
                    guard let url = login.authURL else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                },
                reopen: login.authURL == nil ? nil : ProviderLoginAction(title: L("Open Browser Again", "重新打开浏览器")) { login.reopenBrowser() },
                cardMinHeight: 0
            )
            if login.authURL != nil, login.isRunning {
                DisclosureGroup(isExpanded: $showCodeEntry) {
                    HStack(spacing: 8) {
                        TextField(L("Paste code", "粘贴授权码"), text: $authCode)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(submitCode)
                        Button(L("Continue", "继续"), action: submitCode)
                            .disabled(authCode.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(.top, 6)
                } label: {
                    Text(L("The page shows a code?", "页面显示了授权码？")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func connected(_ profile: ClaudeSubscriptionProfile) -> some View {
        let snapshot = liveSnapshot(for: profile)
        VStack(alignment: .leading, spacing: 14) {
            accountCard(email: profile.email ?? profile.name, plan: ClaudeAuthStatus.planLabel(profile.subscriptionType),
                        caption: snapshot == nil ? L("Connected", "已连接") : L("Synced", "已同步"), checked: true)
            if let snapshot {
                VStack(spacing: 10) {
                    if let window = snapshot.fiveHour, window.resetAt > Date() {
                        quotaRow(L("5 hours", "5 小时"), window: window)
                    }
                    if let window = snapshot.sevenDay, window.resetAt > Date() {
                        quotaRow(L("Weekly", "每周"), window: window)
                    }
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppSurface.card(colorScheme)))
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if ClaudeSubscriptionConnection.routesThroughAPI(directory: profile.configDirectory) {
                messageCard(icon: "arrow.triangle.branch", tint: .orange,
                            title: L("Claude Code is using an API proxy", "Claude Code 正在使用 API 代理"),
                            detail: L("Proxy sessions don't report subscription limits. Turn off the global proxy in Claude → Code, and quota appears after your next message.",
                                      "代理会话不会返回订阅额度。在 Claude → Code 中关闭全局代理后，下一条消息即可同步。"))
            } else if manager.isDefault(profile.configDirectory) {
                waitingCard(L("Send any message in Claude Code — your limits appear here instantly.",
                              "在 Claude Code 中发送任意一条消息，额度会立即显示在这里。"))
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    waitingCard(L("Use this account in your terminal. Limits appear after your first message.",
                                  "在终端用以下命令使用此账号，发送第一条消息后即显示额度。"))
                    commandRow(profile.configDirectory)
                }
            }
        }
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 10) {
            if showsAddAccount {
                Button(L("Add another account…", "添加其他账号…")) { startLogin(directory: manager.makeAccountDirectory()) }
                    .buttonStyle(.link)
            }
            Spacer()
            switch step {
            case .ready(let directory, let status):
                Button(L("Cancel", "取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("Connect", "连接")) { Task { await connect(directory: directory, status: status) } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            case .signedOut(let directory):
                Button(L("Cancel", "取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("Sign in with Claude", "使用 Claude 登录")) { startLogin(directory: directory) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            case .apiLogin:
                Button(L("Cancel", "取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("Add subscription account", "添加订阅账号")) { startLogin(directory: manager.makeAccountDirectory()) }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            case .signingIn:
                Button(L("Cancel", "取消")) { Task { await abandonLogin(); await detect() } }.keyboardShortcut(.cancelAction)
            case .unavailable(_, let canRetry):
                if executable == nil, canRetry {
                    Link(L("Install Claude Code", "安装 Claude Code"), destination: URL(string: "https://code.claude.com/docs/en/setup")!)
                }
                Button(L("Close", "关闭")) { dismiss() }.keyboardShortcut(.cancelAction)
                if canRetry {
                    Button(L("Check Again", "重新检测")) { Task { await detect() } }.buttonStyle(.borderedProminent)
                }
            case .failed:
                Button(L("Close", "关闭")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("Try Again", "重试")) { Task { await detect() } }.buttonStyle(.borderedProminent)
            case .connected, .alreadyConnected:
                Button(L("Done", "完成")) { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            case .detecting, .connecting:
                Button(L("Cancel", "取消")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(step == .connecting)
            }
        }
    }

    private var showsAddAccount: Bool {
        guard initialDirectory == nil else { return false }
        switch step {
        case .ready, .alreadyConnected: return true
        default: return false
        }
    }

    // MARK: - Flow

    private func detect() async {
        notice = nil
        guard appState.settings.backendMode == "local" else {
            step = .unavailable(L("Connect on the computer running the AIUsage backend.", "请在运行 AIUsage 后端的电脑上连接。"), canRetry: false)
            return
        }
        step = .detecting
        guard let resolved = await ClaudeSubscriptionManager.resolveExecutable() else {
            executable = nil
            step = .unavailable(L("Claude Code isn't installed", "未找到 Claude Code"), canRetry: true)
            return
        }
        executable = resolved
        let directory = initialDirectory ?? manager.defaultConfigDirectory
        if initialDirectory == nil, let existing = manager.connectedProfile(for: directory) {
            step = .alreadyConnected(existing)
            return
        }
        do {
            let status = try await ClaudeSubscriptionManager.authStatus(directory: directory, executable: resolved)
            if status.isSubscription {
                step = .ready(directory: directory, status: status)
            } else if status.loggedIn, manager.isDefault(directory) {
                step = .apiLogin
            } else {
                step = .signedOut(directory: directory)
            }
        } catch {
            step = .failed(error.localizedDescription)
        }
    }

    private func startLogin(directory: String) {
        guard let executable else { return }
        authCode = ""
        showCodeEntry = false
        step = .signingIn
        login.start(configDirectory: directory, executable: executable)
    }

    private func submitCode() {
        login.submitCode(authCode)
        authCode = ""
    }

    private func handleLogin(_ phase: ClaudeLoginCoordinator.Phase) {
        guard step == .signingIn else { return }
        switch phase {
        case .succeeded(let status):
            guard let directory = login.configDirectory else { return }
            Task { await finishLogin(directory: directory, status: status) }
        case .failed(let message):
            step = .failed(message)
            Task { await abandonLogin() }
        default:
            break
        }
    }

    /// 取消或失败时，清理这次为新账号创建的空目录；默认配置不受影响。
    private func abandonLogin() async {
        let directory = login.configDirectory
        login.cancel()
        if let directory, let executable { await manager.discardAccountDirectory(directory, executable: executable) }
    }

    private func finishLogin(directory: String, status: ClaudeAuthStatus) async {
        // 新增账号与已连接账号相同：撤销这次独立登录，不重复出现两张卡片。
        if !manager.isDefault(directory),
           let duplicate = manager.connectedProfiles.first(where: {
               $0.configDirectory != ClaudeSubscriptionManager.canonical(directory) && $0.email != nil && $0.email == status.email
           }) {
            if let executable { await manager.discardAccountDirectory(directory, executable: executable) }
            step = .alreadyConnected(duplicate)
            notice = L("This account is already connected.", "这个账号已经连接过了。")
            return
        }
        await connect(directory: directory, status: status)
    }

    private func connect(directory: String, status: ClaudeAuthStatus) async {
        step = .connecting
        do {
            let profile = try await manager.connect(directory: directory, status: status)
            withAnimation { step = .connected(profile) }
        } catch {
            step = .failed(error.localizedDescription)
        }
    }

    private func liveSnapshot(for profile: ClaudeSubscriptionProfile) -> ClaudeSubscriptionSnapshot? {
        _ = manager.snapshotRevision
        return manager.latestSnapshot(for: profile.configDirectory)
    }

    private var loginVisualState: ProviderLoginVisualState {
        switch login.phase {
        case .idle, .starting: return .launching
        case .waitingForBrowser: return .awaitingBrowser
        case .verifying: return .connecting
        case .succeeded: return .succeeded
        case .failed(let message): return .failed(message)
        }
    }

    // MARK: - Building blocks

    private func accountCard(email: String?, plan: String?, caption: String, checked: Bool = false) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.orange.opacity(colorScheme == .dark ? 0.22 : 0.14))
                Text(String((email ?? "C").prefix(1)).uppercased())
                    .font(.headline).foregroundStyle(.orange)
            }
            .frame(width: 38, height: 38)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(email ?? L("Claude account", "Claude 账号")).font(.headline).lineLimit(1).truncationMode(.middle)
                    if let plan { GatewayQuietBadge(text: plan, tint: .orange) }
                }
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if checked {
                Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(.green)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AppSurface.card(colorScheme)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(AppStroke.card(colorScheme), lineWidth: 1))
    }

    private var privacyNote: some View {
        Label {
            Text(L("AIUsage adds a quota sync to Claude Code's status line. Your existing status line keeps working, and your login is never read or stored.",
                   "AIUsage 会在 Claude Code 状态栏加入额度同步，原有状态栏照常显示；不会读取或保存你的登录信息。"))
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "lock.shield")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func progressRow(_ text: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 66, alignment: .leading)
    }

    private func waitingCard(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            ProgressView().controlSize(.small).padding(.top, 1)
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func messageCard(icon: String, tint: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title2).foregroundStyle(tint).frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func quotaRow(_ label: String, window: ClaudeSubscriptionSnapshot.Window) -> some View {
        let remaining = max(0, min(100, 100 - window.usedPercent))
        let tint: Color = remaining <= 12 ? .red : remaining <= 30 ? .orange : .green
        return HStack(spacing: 10) {
            Text(label).font(.callout).frame(width: 64, alignment: .leading)
            ProgressView(value: remaining, total: 100).tint(tint)
            Text(L("\(Int(remaining.rounded()))% left", "剩余 \(Int(remaining.rounded()))%"))
                .font(.callout.monospacedDigit()).frame(width: 78, alignment: .trailing)
        }
    }

    private func commandRow(_ directory: String) -> some View {
        HStack(spacing: 8) {
            Text(ClaudeSubscriptionLaunch.terminalCommand(configDirectory: directory))
                .font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Spacer(minLength: 4)
            Button {
                manager.copyTerminalCommand(for: directory)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
            } label: {
                Label(copied ? L("Copied", "已复制") : L("Copy", "复制"), systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(AppSurface.chip(colorScheme)))
    }
}
