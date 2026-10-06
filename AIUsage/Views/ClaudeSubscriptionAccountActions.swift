import SwiftUI
import QuotaBackend

/// 订阅卡片与详情页的账号操作。只管理额度同步本身，不启动终端、不切换登录。
struct ClaudeSubscriptionAccountActions: View {
    let directory: String
    var needsReconnect = false
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var manager = ClaudeSubscriptionManager.shared
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var showConnection = false
    @State private var disconnectConfirm = false

    private var profile: ClaudeSubscriptionProfile? { manager.profile(for: directory) }

    var body: some View {
        HStack(spacing: 8) {
            if needsReconnect {
                Button(L("Reconnect", "重新连接")) { showConnection = true }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            Spacer(minLength: 0)
            Menu {
                Link(L("Open Claude usage page", "打开 Claude 用量页"), destination: URL(string: "https://claude.ai/settings/usage")!)
                if !manager.isDefault(directory) {
                    Button(L("Copy terminal command", "复制终端命令")) { manager.copyTerminalCommand(for: directory) }
                }
                Divider()
                Button(L("Reconnect…", "重新连接…")) { showConnection = true }
                if profile?.installedCommand != nil {
                    Button(L("Stop syncing…", "停止同步…"), role: .destructive) { disconnectConfirm = true }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L("Claude subscription options", "Claude 订阅选项"))
        }
        .font(.caption)
        .disabled(appState.settings.backendMode != "local")
        .alert(L("Claude subscription", "Claude 订阅"), isPresented: $showError) { Button("OK") {} } message: { Text(errorMessage ?? "") }
        .alert(L("Stop syncing this account?", "停止同步这个账号？"), isPresented: $disconnectConfirm) {
            Button(L("Stop Syncing", "停止同步"), role: .destructive) {
                guard let profile else { return }
                do { try manager.disconnect(profile) } catch { errorMessage = error.localizedDescription; showError = true }
            }
            Button(L("Cancel", "取消"), role: .cancel) {}
        } message: {
            Text(L("Claude Code's status line goes back to how it was. Your Claude login isn't affected.",
                   "Claude Code 状态栏会恢复原样，不影响 Claude 登录。"))
        }
        .sheet(isPresented: $showConnection) {
            ClaudeSubscriptionConnectionView(initialDirectory: directory).environmentObject(appState)
        }
    }
}
