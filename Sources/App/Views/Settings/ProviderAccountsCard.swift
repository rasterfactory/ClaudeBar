import AppKit
import Domain
import Infrastructure
import Providers
import SwiftUI

/// One account management pattern for every provider.
struct ProviderAccountsCard: View {
    let provider: Provider
    let monitor: QuotaMonitor
    @Environment(\.appTheme) private var theme
    @State private var showingSetup = false
    @State private var editing: Account?

    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Accounts").font(.headline)
                ForEach(provider.accounts) { account in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(account.accountDisplayName).textSelection(.enabled).lineLimit(2)
                        if !account.label.isEmpty, let email = account.accountEmail { Text(email).font(.caption).foregroundStyle(theme.textSecondary).textSelection(.enabled) }
                        if let source = account.values["source"] { Text(source).font(.caption).foregroundStyle(theme.textSecondary).lineLimit(2).textSelection(.enabled) }
                        HStack {
                            Text(account.isDefault ? "Default login" : "Separate connection").font(.caption).foregroundStyle(theme.textSecondary)
                            Spacer()
                            SettingsSwitch(isOn: Binding(get: { account.isEnabled }, set: { monitor.setProviderEnabled(account.id, enabled: $0) }))
                            Button("Refresh") { Task { await monitor.refresh(providerId: account.id) } }.disabled(account.isSyncing)
                            Button("Edit Name…") { editing = account }
                            if !account.isDefault { Button("Remove") { remove(account) } }
                        }.controlSize(.small)
                    }

                }
                Text("One account keeps the provider name. Add another to distinguish Personal and Work; full identity stays visible in details.")
                    .font(.callout).foregroundStyle(theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                Button("Add Account…") { showingSetup = true }
            }
        }
        .sheet(isPresented: $showingSetup) {
            if provider.definition.accounts?.folder != nil {
                BrowserAccountSetupSheet(monitor: monitor, providerId: provider.id).environment(\.appTheme, theme)
            } else {
                ProviderAccountConnectionSheet(provider: provider, monitor: monitor).environment(\.appTheme, theme)
            }
        }
        .sheet(item: $editing) { account in AccountNameSheet(account: account).environment(\.appTheme, theme) }
    }

    private func remove(_ account: Account) {
        if let config = JSONSettingsRepository.shared.accounts(forProvider: provider.id).first(where: { $0.accountId == account.accountId }),
           let recipe = LegacyAccountConnections.shared.recipe(for: provider.id) {
            if recipe.source == .token { _ = LegacyAccountConnections.shared.deleteSecret(providerId: provider.id, config: config) }
            for field in recipe.fields where field.isSecret { LegacyAccountConnections.shared.deleteField(field.id, providerId: provider.id, config: config) }
        }
        provider.remove(account)
        JSONSettingsRepository.shared.removeAccount(accountId: account.accountId, forProvider: provider.id)
        let remaining = AppSettings.shared.menuBarProviderIds.filter { $0 != account.id }
        AppSettings.shared.setMenuBarProviderIds(remaining.isEmpty ? [provider.id] : remaining)
        if monitor.selectedProviderId == account.id { monitor.selectedProviderId = provider.id }
        monitor.removeProvider(id: account.id)
    }
}

struct ProviderAccountConnectionSheet: View {
    let provider: Provider
    let monitor: QuotaMonitor
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    @State private var name = ""
    @State private var source = ""
    @State private var secret = ""
    @State private var fieldSecrets: [String: String] = [:]
    @State private var options: [String: String] = [:]
    @State private var error: String?
    @State private var busy = false
    @State private var task: Task<Void, Never>?
    private var recipe: AccountConnectionRecipe? { LegacyAccountConnections.shared.recipe(for: provider.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add \(provider.name) Account").font(.title2.weight(.semibold))
            if let recipe {
                Text(recipe.help).font(.callout).foregroundStyle(theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                TextField("Account name (optional)", text: $name).textFieldStyle(.roundedBorder)
                if recipe.source == .token {
                    SecureField(recipe.title, text: $secret).textFieldStyle(.roundedBorder)
                } else {
                    TextField(recipe.title, text: $source).textFieldStyle(.roundedBorder)
                    if recipe.source != .profile { Button("Choose…") { choose(recipe) } }
                }
                ForEach(recipe.options, id: \.self) { key in
                    optionField(key)
                }
                ForEach(recipe.fields, id: \.id) { field in
                    if field.isSecret {
                        SecureField(field.label, text: Binding(get: { fieldSecrets[field.id] ?? "" }, set: { fieldSecrets[field.id] = $0 })).textFieldStyle(.roundedBorder)
                    } else if field.type == .choice, let choices = field.options {
                        Picker(field.label, selection: Binding(get: { options[field.id] ?? field.defaultValue ?? choices.first ?? "" }, set: { options[field.id] = $0 })) {
                            ForEach(choices, id: \.self) { Text($0).tag($0) }
                        }
                    } else {
                        TextField(field.label, text: Binding(get: { options[field.id] ?? field.defaultValue ?? "" }, set: { options[field.id] = $0 })).textFieldStyle(.roundedBorder)
                    }
                }
                if busy { HStack { ProgressView().controlSize(.small); Text("Checking this account’s connection…") } }
                if let error { Text(error).foregroundStyle(theme.statusWarning).fixedSize(horizontal: false, vertical: true) }
                HStack {
                    Button("Cancel") { task?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Connect and Add") { connect(recipe) }.keyboardShortcut(.defaultAction)
                        .disabled(busy || (recipe.source == .token ? secret.isEmpty : source.isEmpty))
                }
            } else {
                Text("This provider's connection recipe is not available.")
                Button("Close") { dismiss() }
            }
        }
        .padding(24).frame(width: 520).foregroundStyle(theme.textPrimary).background(theme.backgroundGradient)
        .interactiveDismissDisabled(busy).onDisappear { task?.cancel() }
    }

    @ViewBuilder
    private func optionField(_ key: String) -> some View {
        if key == "region" {
            let choices: [(String, String)] = switch provider.id {
            case "minimax": MiniMaxRegion.allCases.map { ($0.rawValue, $0.displayName) }
            case "kimi": KimiRegion.allCases.map { ($0.rawValue, $0.displayName) }
            case "alibaba": AlibabaRegion.allCases.map { ($0.rawValue, $0.displayName) }
            default: []
            }
            Picker("Region", selection: Binding(get: { options[key] ?? choices.first?.0 ?? "" }, set: { options[key] = $0 })) {
                ForEach(choices, id: \.0) { choice in Text(choice.1).tag(choice.0) }
            }
        } else if key == "mode" {
            Picker("Usage source", selection: Binding(get: { options[key] ?? "copilotAPI" }, set: { options[key] = $0 })) {
                Text("Copilot API").tag("copilotAPI")
                Text("Billing").tag("billing")
            }
        } else {
            TextField(optionTitle(key), text: Binding(get: { options[key] ?? "" }, set: { options[key] = $0 })).textFieldStyle(.roundedBorder)
        }
    }

    private func optionTitle(_ key: String) -> String {
        switch key {
        case "region": "Region (use the provider's region identifier)"
        case "mode": "Mode: copilotAPI or billing"
        case "username": "GitHub username (billing)"
        case "regions": "AWS regions, separated by commas"
        case "dailyBudget": "Daily budget (optional)"
        case "monthlyLimit": "Monthly request limit (optional)"
        default: key.capitalized
        }
    }

    private func choose(_ recipe: AccountConnectionRecipe) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = recipe.source != .file
        panel.canChooseFiles = recipe.source == .file
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.begin { response in if response == .OK, let url = panel.url { source = url.path } }
    }

    private func connect(_ recipe: AccountConnectionRecipe) {
        busy = true; error = nil
        var values = options
        if recipe.options.contains("region"), values["region"] == nil {
            values["region"] = switch provider.id {
            case "minimax": MiniMaxRegion.allCases.first?.rawValue
            case "kimi": KimiRegion.allCases.first?.rawValue
            case "alibaba": AlibabaRegion.allCases.first?.rawValue
            default: nil
            }
        }
        if recipe.options.contains("mode"), values["mode"] == nil { values["mode"] = "copilotAPI" }
        for field in recipe.fields where !field.isSecret && values[field.id] == nil { values[field.id] = field.defaultValue ?? (field.type == .choice ? field.options?.first : nil) }
        values["source"] = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let config = ProviderAccountConfig(accountId: UUID().uuidString.lowercased(), label: name,
                                          probeConfig: values)
        task = Task { @MainActor in
            defer { busy = false; task = nil }
            var committed = false
            defer {
                if !committed {
                    if recipe.source == .token { _ = LegacyAccountConnections.shared.deleteSecret(providerId: provider.id, config: config) }
                    for field in recipe.fields where field.isSecret { LegacyAccountConnections.shared.deleteField(field.id, providerId: provider.id, config: config) }
                }
            }
            do {
                if recipe.source != .token {
                    let chosen = values["source"] ?? ""
                    let canonical = recipe.source == .profile ? chosen : URL(fileURLWithPath: chosen).standardizedFileURL.resolvingSymlinksInPath().path
                    let listed = provider.accounts.contains { account in
                        guard let existing = account.values["source"] else { return false }
                        return (recipe.source == .profile ? existing : URL(fileURLWithPath: existing).standardizedFileURL.resolvingSymlinksInPath().path) == canonical
                    }
                    guard !listed else { throw UsageError.executionFailed("This connection is already listed. Choose another account’s source.") }
                }
                if recipe.source == .token { try LegacyAccountConnections.shared.saveSecret(secret, providerId: provider.id, config: config) }
                for field in recipe.fields where field.isSecret {
                    if let value = fieldSecrets[field.id], !value.isEmpty { try LegacyAccountConnections.shared.saveField(value, field: field.id, providerId: provider.id, config: config) }
                }
                for field in recipe.fields where field.required {
                    guard !(field.isSecret ? fieldSecrets[field.id] ?? "" : values[field.id] ?? "").isEmpty else { throw UsageError.executionFailed("Enter \(field.label) for this account.") }
                }
                let connected = try LegacyAccountConnections.shared.source(providerId: provider.id, config: config)
                let usage = try await connected.refresh(.interactive)
                try Task.checkCancellation()
                if let email = usage.accountEmail, provider.accounts.contains(where: { $0.accountEmail == email && $0.snapshot?.accountOrganization == usage.accountOrganization }) {
                    throw UsageError.executionFailed("This signed-in account is already listed. Connect another account.")
                }
                var verifiedValues = config.probeConfig
                verifiedValues["identity"] = connected.connectionIdentity
                let validated = ProviderAccountConfig(accountId: config.accountId, label: config.label,
                    email: usage.accountEmail, organization: usage.accountOrganization, probeConfig: verifiedValues)
                guard let account = provider.add(validated) else { throw UsageError.authenticationRequired }
                JSONSettingsRepository.shared.addAccount(validated, forProvider: provider.id)
                monitor.addProvider(account)
                committed = true
                Task { await monitor.refresh(providerId: account.id) }
                dismiss()
            } catch is CancellationError { } catch { self.error = error.localizedDescription }
        }
    }
}
