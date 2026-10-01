import SwiftUI
import AppKit
import Domain
import Infrastructure
import Providers
import DataSources

/// Verified email identifies the login; an optional name helps people recognize it.
struct BrowserAccountSetupSheet: View {
    let monitor: QuotaMonitor
    var providerId: String = "codex"
    private var productName: String { providerId == "claude" ? "Claude" : "Codex" }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    @State private var error: String?
    @State private var loginTask: Task<Void, Never>?
    @State private var pendingAccount: ProviderAccountConfig?
    @State private var accountName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add \(productName) Account")
                .font(.title2.weight(.semibold))
            Text("Sign in to another \(productName) account to see its usage alongside your current account.")
            Text("You can keep switching accounts in the desktop app and working on the same repos. ClaudeBar keeps a separate sign-in for this account.")
                .font(.callout)
                .foregroundStyle(theme.textSecondary)

            if let pendingAccount {
                Text("Signed in as")
                    .foregroundStyle(theme.textSecondary)
                Text(pendingAccount.email ?? "\(productName) account")
                    .font(.headline)
                    .textSelection(.enabled)
                TextField("Account name (optional)", text: $accountName)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Account name, optional")
                Text("For example, Personal or Work. Leave blank to use the email.")
                    .font(.callout)
                    .foregroundStyle(theme.textSecondary)
                Button("Use a Different Account", action: signIn)
            } else if loginTask != nil {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for browser sign-in…")
                }
                Text("Choose the account you want to add in your browser. ClaudeBar will read its email when sign-in finishes.")
                    .font(.callout)
                    .foregroundStyle(theme.textSecondary)
            } else {
                Text("Your browser will open so you can choose the account to add.")
            }

            if let error {
                Text(error)
                    .foregroundStyle(theme.statusWarning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Could not add account: \(error)")
            }

            Text("Removing an account from ClaudeBar leaves its sign-in in place.")
                .font(.callout)
                .foregroundStyle(theme.textSecondary)

            HStack {
                Button("Cancel") { loginTask?.cancel(); dismiss() }
                    .keyboardShortcut(.cancelAction)
                if loginTask == nil {
                    Button("Choose Existing Folder…", action: chooseFolder)
                }
                Spacer()
                if let pendingAccount {
                    Button("Add Account") { add(pendingAccount) }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button(error == nil ? "Sign In…" : "Try Again", action: signIn)
                        .keyboardShortcut(.defaultAction)
                        .disabled(loginTask != nil)
                }
            }
        }
        .padding(24)
        .frame(width: 520)
        .foregroundStyle(theme.textPrimary)
        .background(theme.backgroundGradient)
        .interactiveDismissDisabled(loginTask != nil)
        .onDisappear { loginTask?.cancel() }
    }

    private func signIn() {
        error = nil
        pendingAccount = nil
        let home = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(providerId == "claude" ? ".claude-claudebar" : ".codex-claudebar")
            .appendingPathComponent(UUID().uuidString.lowercased())
        loginTask = Task { @MainActor in
            defer { loginTask = nil }
            do {
                let login = BrowserAccountLogin(locate: {
                    BinaryLocator.invalidateCaches()
                    return BinaryLocator.which(providerId)
                }, arguments: providerId == "claude" ? ["auth", "login", "--claudeai"] : ["-c", "cli_auth_credentials_store=\"file\"", "login"],
                   homeEnvironmentKey: providerId == "claude" ? "CLAUDE_CONFIG_DIR" : "CODEX_HOME",
                   environmentExclusions: ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_PROFILE", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY"])
                try await login.signIn(home: home)
                try Task.checkCancellation()
                pendingAccount = try configuration(folder: home.path)
            } catch is CancellationError {
                // Closing the sheet cancels its login, never the desktop session.
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func configuration(folder: String) throws -> ProviderAccountConfig {
        let config = try AddedAccounts.configuration(
            providerId, folder: folder,
            existing: JSONSettingsRepository.shared.accounts(forProvider: providerId))
        if let primary = (monitor.provider(for: providerId) as? Account)?.accountEmail, primary == config.email {
            throw UsageError.executionFailed("This account is already your default login. Sign in to another account.")
        }
        return config
    }

    private func add(_ config: ProviderAccountConfig) {
        do {
            // Revalidate at save time in case the folder or default login changed.
            let validated = try configuration(folder: config.probeConfig[providerId == "claude" ? "configDirectory" : "codexHome"] ?? "").named(accountName)
            guard validated.probeConfig[providerId == "claude" ? "loginEmail" : "chatgptAccountId"] == config.probeConfig[providerId == "claude" ? "loginEmail" : "chatgptAccountId"] else {
                error = "This folder’s account changed. Sign in again to confirm its email."
                pendingAccount = nil
                return
            }
            guard let codex = (monitor.provider(for: providerId) as? Account)?.provider,
                  let provider = codex.add(validated) else {
                error = "\(productName) is unavailable. Close this window and try again."
                return
            }
            JSONSettingsRepository.shared.addAccount(validated, forProvider: providerId)
            monitor.addProvider(provider)
            Task { await monitor.refresh(providerId: provider.id) }
            dismiss()
        } catch {
            self.error = error.localizedDescription
            pendingAccount = nil
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(providerId == "claude" ? ".claude-claudebar" : ".codex-claudebar")
        panel.prompt = "Choose Folder"
        panel.message = providerId == "claude" ? "Choose a separate signed-in Claude configuration folder." : "Choose an existing Codex folder containing auth.json."
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                pendingAccount = try configuration(folder: url.path)
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Naming is display metadata; editing never changes the account's credentials.
struct AccountNameSheet: View {
    let account: Account
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    @State private var name: String
    @State private var error: String?

    init(account: Account) {
        self.account = account
        _name = State(initialValue: account.label)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Account Name").font(.title2.weight(.semibold))
            Text(account.accountEmail ?? "Default login")
                .textSelection(.enabled)
            TextField("Personal, Work…", text: $name)
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("Account name, optional")
            Text("Optional. Leave blank to use the email. A single account still displays \(account.provider.name); names distinguish multiple accounts.")
                .fixedSize(horizontal: false, vertical: true)
                .font(.callout)
                .foregroundStyle(theme.textSecondary)
            if let error { Text(error).foregroundStyle(theme.statusWarning) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") {
                    if account.provider.rename(account, to: name) { dismiss() }
                    else { error = "Could not save the name. Close this window and try again." }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
        .foregroundStyle(theme.textPrimary)
        .background(theme.backgroundGradient)
    }
}
