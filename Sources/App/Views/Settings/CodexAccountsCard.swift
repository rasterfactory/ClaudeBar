import SwiftUI
import AppKit
import Domain
import Infrastructure
import Providers
import DataSources

/// Email identifies the login; users never need to invent an account name.
struct CodexAccountsCard: View {
    let monitor: QuotaMonitor
    @Environment(\.appTheme) private var theme
    @State private var showingSetup = false

    /// The Codex product — one provider, its logins as accounts.
    private var codex: Provider? {
        (monitor.provider(for: "codex") as? Account)?.provider
    }

    private var accounts: [Account] {
        codex?.accounts ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Codex Accounts")
                .font(.headline)
                .foregroundStyle(theme.textPrimary)

            ForEach(accounts, id: \.id) { provider in
                HStack(alignment: .top, spacing: 10) {
                    ProviderIconView(providerId: provider.id, size: 24)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(provider.accountEmail ?? "Default Codex login")
                            .font(.body)
                            .foregroundStyle(theme.textPrimary)
                            .textSelection(.enabled)
                        Text(provider.isDefault ? "Uses your default Codex login" : "Separate Codex login")
                            .font(.caption)
                            .foregroundStyle(theme.textSecondary)
                    }
                    Spacer(minLength: 8)
                    if !provider.isDefault {
                        Button("Remove") { remove(provider) }
                            .accessibilityLabel("Remove \(provider.name) from ClaudeBar")
                    }
                }
            }

            Text("Each account has its own quota display. Select both in Menu Bar settings to keep both visible.")
                .font(.callout)
                .foregroundStyle(theme.textSecondary)

            Button("Add Codex Account…") { showingSetup = true }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: theme.cardCornerRadius).fill(theme.cardGradient))
        .overlay(RoundedRectangle(cornerRadius: theme.cardCornerRadius).stroke(theme.glassBorder, lineWidth: 1))
        .sheet(isPresented: $showingSetup) {
            CodexAccountSetupSheet(monitor: monitor)
                .environment(\.appTheme, theme)
        }
    }

    private func remove(_ provider: Account) {
        codex?.remove(provider)
        JSONSettingsRepository.shared.removeAccount(accountId: provider.accountId, forProvider: "codex")
        let settings = AppSettings.shared
        let remaining = settings.menuBarProviderIds.filter { $0 != provider.id }
        settings.setMenuBarProviderIds(remaining.isEmpty ? ["codex"] : remaining)
        if monitor.selectedProviderId == provider.id { monitor.selectedProviderId = "codex" }
        monitor.removeProvider(id: provider.id)
    }
}

struct CodexAccountSetupSheet: View {
    let monitor: QuotaMonitor
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    @State private var error: String?
    @State private var loginTask: Task<Void, Never>?
    @State private var pendingAccount: ProviderAccountConfig?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Codex Account")
                .font(.title2.weight(.semibold))
            Text("Sign in to another ChatGPT account to see its Codex usage alongside your current account.")
            Text("You can keep switching accounts in the desktop app and working on the same repos. ClaudeBar keeps a separate sign-in for this account.")
                .font(.callout)
                .foregroundStyle(theme.textSecondary)

            if let pendingAccount {
                Text("Signed in as")
                    .foregroundStyle(theme.textSecondary)
                Text(pendingAccount.email ?? "Codex account")
                    .font(.headline)
                    .textSelection(.enabled)
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
            .appendingPathComponent(".codex-claudebar")
            .appendingPathComponent(UUID().uuidString.lowercased())
        loginTask = Task { @MainActor in
            defer { loginTask = nil }
            do {
                let login = BrowserAccountLogin(locate: {
                    BinaryLocator.invalidateCaches()
                    return BinaryLocator.which("codex")
                })
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
        try AddedAccounts.configuration(
            "codex", folder: folder,
            existing: JSONSettingsRepository.shared.accounts(forProvider: "codex"))
    }

    private func add(_ config: ProviderAccountConfig) {
        do {
            // Revalidate at save time in case the folder or default login changed.
            let validated = try configuration(folder: config.probeConfig["codexHome"] ?? "")
            guard validated.probeConfig["chatgptAccountId"] == config.probeConfig["chatgptAccountId"] else {
                error = "This folder’s account changed. Sign in again to confirm its email."
                pendingAccount = nil
                return
            }
            guard let codex = (monitor.provider(for: "codex") as? Account)?.provider,
                  let provider = codex.add(validated) else {
                error = "Codex is unavailable. Close this window and try again."
                return
            }
            JSONSettingsRepository.shared.addAccount(validated, forProvider: "codex")
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
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex-claudebar")
        panel.prompt = "Choose Folder"
        panel.message = "Choose an existing Codex folder containing auth.json."
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
