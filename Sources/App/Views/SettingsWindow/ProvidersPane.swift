import AppKit
import SwiftUI
import Domain
import Infrastructure
import Providers

/// Providers pane: master list of every registered provider with enable
/// toggles; selecting a row drills into that provider's configuration.
struct ProvidersPane: View {
    let monitor: QuotaMonitor

    @Environment(\.appTheme) private var theme
    @State private var selectedProviderId: String?
    @State private var addingProvider = false
    @State private var importing: IdentifiedReview?
    @State private var importError: String?
    /// The list's order, taken when it appears — enabled providers first (#141).
    @State private var listOrder: [String] = []

    var body: some View {
        if let providerId = selectedProviderId,
           let provider = monitor.provider(for: providerId) {
            ProviderDetailView(monitor: monitor, provider: provider) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    selectedProviderId = nil
                }
            }
        } else {
            providerList
        }
    }

    private var providerList: some View {
        SettingsPane(
            title: "Providers",
            subtitle: "Enable the assistants you use. Click a provider to configure it."
        ) {
            VStack(spacing: 8) {
                ForEach(listedProviders, id: \.id) { provider in
                    ProviderListRow(monitor: monitor, provider: provider) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedProviderId = provider.id
                        }
                    }
                }

                HStack {
                    if let importError {
                        Text(importError)
                            .font(.system(size: 10, weight: .semibold, design: theme.fontDesign))
                            .foregroundStyle(theme.statusWarning)
                    }
                    Spacer()
                    Button("Import…", action: chooseImport)
                    Button("Add Provider…") { addingProvider = true }
                }
                .padding(.top, 4)
            }
        }
        .onAppear {
            listOrder = ProviderListOrder.listed(monitor.allProviders.map { ($0.id, $0.isEnabled) })
        }
        .sheet(isPresented: $addingProvider) {
            AddProviderSheet(monitor: monitor) { addingProvider = false }.themedSheet()
        }
        .sheet(item: $importing) { review in
            ImportProviderSheet(monitor: monitor, review: review.value) { importing = nil }.themedSheet()
        }
    }

    /// Every provider, in the order the list took when it appeared.
    private var listedProviders: [any AIProvider] {
        let all = monitor.allProviders
        let order = ProviderListOrder.keeping(listOrder, current: all.map(\.id))
        return order.compactMap { id in all.first { $0.id == id } }
    }

    /// *Import…*: a shared file is read and reviewed — nothing is saved or run yet.
    private func chooseImport() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.json]
        panel.begin { result in
            guard result == .OK, let url = panel.url else { return }
            do {
                importError = nil
                importing = IdentifiedReview(value: try ProviderCatalog().review(Data(contentsOf: url)))
            } catch {
                importError = "Not a ClaudeBar provider: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - List Row

private struct ProviderListRow: View {
    let monitor: QuotaMonitor
    let provider: any AIProvider
    let onSelect: () -> Void

    @Environment(\.appTheme) private var theme
    @State private var isHovering = false

    private var lowestQuota: UsageQuota? {
        monitor.usage(of: provider)?.lowestQuota
    }

    private var statusText: String {
        guard provider.isEnabled else { return "Disabled" }
        guard let snapshot = provider.snapshot else { return "No data yet" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        let relative = formatter.localizedString(for: snapshot.capturedAt, relativeTo: Date())
        return "Updated \(relative)"
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                ProviderIconView(providerId: provider.id, size: 26)

                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.name)
                        .font(.system(size: 13, weight: .semibold, design: theme.fontDesign))
                        .foregroundStyle(theme.textPrimary)

                    Text(statusText)
                        .font(.system(size: 10, weight: .medium, design: theme.fontDesign))
                        .foregroundStyle(theme.textTertiary)
                }

                Spacer()

                if provider.isEnabled, let quota = lowestQuota {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(quota.percentLeft.map { "\(Int($0))%" } ?? quota.formattedDollarRemaining ?? "—")
                            .font(.system(size: 12, weight: .bold, design: theme.fontDesign))
                            .foregroundStyle(theme.statusColor(for: quota.status(under: AppSettings.shared.statusPolicy)))
                            .monospacedDigit()

                        if let percent = quota.percentLeft {
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(theme.progressTrack)

                                    Capsule()
                                        .fill(theme.statusColor(for: quota.status(under: AppSettings.shared.statusPolicy)))
                                        .frame(width: geo.size.width * max(0, min(100, percent)) / 100)
                                }
                            }
                            .frame(width: 80, height: 4)
                        }
                    }
                }

                SettingsSwitch(isOn: Binding(
                    get: { provider.isEnabled },
                    set: { newValue in
                        withAnimation(.easeInOut(duration: 0.2)) {
                            monitor.setProviderEnabled(provider.id, enabled: newValue)
                        }
                    }
                ))

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(theme.textTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: theme.cardCornerRadius)
                    .fill(theme.cardGradient)
                    .overlay(
                        RoundedRectangle(cornerRadius: theme.cardCornerRadius)
                            .stroke(isHovering ? theme.glassHighlight : theme.glassBorder, lineWidth: 1)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: theme.cardCornerRadius)
                            .fill(isHovering ? theme.hoverOverlay : Color.clear)
                    )
            )
            .opacity(provider.isEnabled ? 1 : 0.55)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Detail

/// Per-provider configuration: reuses the existing provider config cards
/// from the popover settings, plus the custom web card URL field.
private struct ProviderDetailView: View {
    let monitor: QuotaMonitor
    let provider: any AIProvider
    let onBack: () -> Void

    @Environment(\.appTheme) private var theme

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 14) {
                backButton

                HStack(spacing: 14) {
                    ProviderIconView(providerId: provider.id, size: 40)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(provider.name)
                            .font(.system(size: 21, weight: .bold, design: theme.fontDesign))
                            .foregroundStyle(theme.textPrimary)

                        Text(provider.isEnabled ? "Enabled" : "Disabled")
                            .font(.system(size: 11, weight: .semibold, design: theme.fontDesign))
                            .foregroundStyle(provider.isEnabled ? theme.statusHealthy : theme.textTertiary)
                    }

                    Spacer()

                    SettingsSwitch(isOn: Binding(
                        get: { provider.isEnabled },
                        set: { newValue in
                            withAnimation(.easeInOut(duration: 0.2)) {
                                monitor.setProviderEnabled(provider.id, enabled: newValue)
                            }
                        }
                    ))
                }
                .padding(.bottom, 6)

                if provider.isEnabled {
                    configCard

                    QuotaVisibilityCard(provider: provider, monitor: monitor)

                    SettingsCard {
                        SettingsFieldLabel(text: "CUSTOM WEB CARD")
                            .padding(.bottom, 8)

                        CustomCardURLField(providerId: provider.id)
                    }
                } else {
                    Text("Enable \(provider.name) to configure it.")
                        .font(.system(size: 12, weight: .medium, design: theme.fontDesign))
                        .foregroundStyle(theme.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, 18)
            .padding(.bottom, 32)
        }
    }

    private var backButton: some View {
        Button(action: onBack) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .bold))
                Text("All Providers")
                    .font(.system(size: 11, weight: .semibold, design: theme.fontDesign))
            }
            .foregroundStyle(theme.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(theme.glassBackground)
                    .overlay(Capsule().stroke(theme.glassBorder, lineWidth: 1))
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    /// The provider-specific config card, when one exists.
    @ViewBuilder
    private var configCard: some View {
        switch (provider as? Account)?.provider.id ?? provider.id {
        case "claude":
            if let claude = (provider as? Account)?.provider {
                DataSourceSection(provider: claude, monitor: monitor)
                ProviderAccountsCard(provider: claude, monitor: monitor)
            }
            ClaudeBudgetCard()
        case "codex":
            if let codex = (provider as? Account)?.provider {
                DataSourceSection(provider: codex, monitor: monitor)
                ProviderAccountsCard(provider: codex, monitor: monitor)
            }
        case "kiro":
            if let kiro = (provider as? Account)?.provider { ProviderAccountsCard(provider: kiro, monitor: monitor) }
        case "kimi":
            KimiConfigCard(monitor: monitor)
        case "minimax":
            MiniMaxConfigCard(monitor: monitor)
        case "deepseek":
            if let deepseek = (provider as? Account)?.provider {
                ProviderAccountsCard(provider: deepseek, monitor: monitor)
            }
            DeepSeekConfigCard(monitor: monitor)
        case "alibaba":
            AlibabaConfigCard(monitor: monitor)
        case "vercel-gateway":
            VercelConfigCard(monitor: monitor)
        case "copilot":
            CopilotConfigCard(monitor: monitor)
        case "zai":
            ZaiConfigCard(monitor: monitor)
        case "bedrock":
            BedrockConfigCard(monitor: monitor)
        default:
            if let custom = (provider as? Account)?.provider, custom.definition.profile.origin == .custom {
                DataSourceSection(provider: custom, monitor: monitor)
                if custom.definition.accounts != nil {
                    ProviderAccountsCard(provider: custom, monitor: monitor)
                }
                CustomProviderCard(provider: custom, monitor: monitor, onDeleted: onBack)
            } else if let extProvider = provider as? ExtensionProvider, extProvider.manifest.hasConfig {
                ExtensionConfigCard(
                    provider: extProvider,
                    configRepository: AppSettings.shared.extensionConfig
                )
            }
        }
    }
}

// MARK: - Quotas (issue #140)

/// *QUOTAS* — one switch per quota the provider reports, so a person can
/// stop watching the ones they never use (Gemini Flash 2.0, …). A hidden
/// quota is never shown and never sets a status or an alert, anywhere: the
/// monitor leaves it out of the usage every surface reads.
private struct QuotaVisibilityCard: View {
    let provider: any AIProvider
    let monitor: QuotaMonitor

    @Environment(\.appTheme) private var theme
    @State private var refused: String?

    var body: some View {
        SettingsCard {
            SettingsFieldLabel(text: "QUOTAS")
                .padding(.bottom, 12)

            if let quotas = provider.snapshot?.quotas, quotas.count > 1 {
                VStack(spacing: 0) {
                    ForEach(Array(quotas.enumerated()), id: \.element.quotaType) { index, quota in
                        if index > 0 {
                            SettingsRowDivider()
                        }
                        toggleRow(quota)
                    }
                }
                Text(refused ?? "Turn off a quota you don't use: it disappears everywhere and no longer sets \(provider.name)'s status or alerts.")
                    .font(.system(size: 10, weight: .medium, design: theme.fontDesign))
                    .foregroundStyle(refused == nil ? theme.textTertiary : theme.statusWarning)
                    .padding(.top, 8)
            } else {
                Text("No quotas to choose from yet. Refresh \(provider.name) once, then pick the ones you watch.")
                    .font(.system(size: 11, weight: .medium, design: theme.fontDesign))
                    .foregroundStyle(theme.textTertiary)
            }
        }
    }

    private func toggleRow(_ quota: UsageQuota) -> some View {
        let key = quota.quotaType.quotaKey
        return SettingsRow(title: quota.compactTitle ?? quota.quotaType.displayName, subtitle: nil) {
            SettingsSwitch(isOn: Binding(
                get: { !monitor.hiddenQuotaKeys(for: provider).contains(key) },
                set: { watched in
                    refused = monitor.setQuota(key, hidden: !watched, for: provider)
                        ? nil : "Keep at least one quota: \(provider.name) needs something to watch."
                }
            ))
        }
    }
}

/// A review to present as a sheet.
struct IdentifiedReview: Identifiable {
    let id = UUID()
    let value: ImportReview
}
