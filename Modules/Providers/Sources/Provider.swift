import DataSources
import Diagnostics
import Quotas
import Foundation
import Observation

/// THE PRODUCT — Codex, Claude, a gateway someone added — and THE lifecycle,
/// once for every login of it. What a provider *is* lives in its definition,
/// how it fetches in its data sources; who is signed in, and what we last saw
/// for them, lives in its `accounts`.
///
/// Every login runs the same definition: an added one with `accounts.patch`
/// merged in and its values filling `{{account.x}}`, made live once and kept,
/// so each login has its own cache and rate-limit memory.
@MainActor
@Observable
public final class Provider {
    public let definition: ProviderDefinition

    /// The logins — never empty; the first is the default login.
    public private(set) var accounts: [Account] = []
    public var defaultAccount: Account { accounts[0] }

    /// Today's and yesterday's usage, read on an interactive refresh only —
    /// a background poll stays cheap (#204).
    public let dailyUsage: (any DailyUsageAnalyzing)?
    /// *Share Claude Code*, for a provider whose plan can issue guest passes.
    public let guestPasses: GuestPasses?

    let settings: any ProviderSettingsRepository
    private let makeDataSource: (DataSourceDefinition) -> DataSource
    @ObservationIgnored private var bound: [String: [DataSource]] = [:]
    @ObservationIgnored private var refreshTasks: [String: Task<UsageSnapshot, Error>] = [:]

    /// - Parameter makeDataSource: makes a definition live — the real
    ///   connections in the app, stubbed ones in tests.
    public init(
        definition: ProviderDefinition,
        settings: any ProviderSettingsRepository,
        accounts: [ProviderAccountConfig] = [],
        makeDataSource: @escaping (DataSourceDefinition) -> DataSource,
        dailyUsage: (any DailyUsageAnalyzing)? = nil,
        guestPasses: GuestPasses? = nil
    ) {
        self.definition = definition
        self.settings = settings
        self.makeDataSource = makeDataSource
        self.dailyUsage = dailyUsage
        self.guestPasses = guestPasses
        self.accounts = [Account(provider: self, login: ProviderAccount(providerId: definition.id, label: ""), values: [:])]
        bound[definition.id] = definition.dataSources.map(makeDataSource)
        for config in accounts {
            add(config)
        }
    }

    public var id: String { definition.id }
    public var name: String { definition.profile.name }

    /// Bridge existing source implementations into the same account lifecycle.
    /// Construction fails rather than silently substituting the default login.
    public convenience init(
        profile: ProviderProfile,
        sourceDefinition: ProviderDefinition? = nil,
        makeDefaultDataSource: ((DataSourceDefinition) -> DataSource)? = nil,
        cli: String? = nil,
        enabledByDefault: Bool = true,
        settings: any ProviderSettingsRepository,
        accounts: [ProviderAccountConfig] = [],
        makeAccountSource: @escaping (ProviderAccountConfig?) throws -> any AccountUsageSource
    ) throws {
        self.init(
            definition: ProviderDefinition(profile: profile, cli: cli, enabledByDefault: enabledByDefault,
                dataSources: sourceDefinition?.dataSources ?? [], defaultDataSource: sourceDefinition?.defaultDataSource ?? "source", accounts: .init(nameFromEmail: true)),
            settings: settings,
            makeDataSource: makeDefaultDataSource ?? { DataSources.make($0, providerId: profile.id) }
        )
        self.makeAccountSource = makeAccountSource
        accountSources[id] = try makeAccountSource(nil)
        for config in accounts { add(config) }
    }

    @ObservationIgnored private var makeAccountSource: ((ProviderAccountConfig?) throws -> any AccountUsageSource)?
    @ObservationIgnored private var accountSources: [String: any AccountUsageSource] = [:]

    public func dashboardURL(for account: Account) -> URL? { accountSources[account.id]?.dashboardURL ?? definition.profile.links.dashboard(for: account.snapshot?.accountTier) }

    public var usesAccountSources: Bool { makeAccountSource != nil }

    // MARK: - Accounts

    /// *Add Account* — a login beside the default one. `nil` when the
    /// definition has no added accounts, the login is already listed, or its
    /// saved values don't fill what the definition needs.
    @discardableResult
    public func add(_ config: ProviderAccountConfig) -> Account? {
        let login = config.toProviderAccount(providerId: definition.id)
        guard definition.accounts != nil, !login.isDefault, !accounts.contains(where: { $0.id == login.id }) else {
            return nil
        }
        do {
            if let makeAccountSource {
                accountSources[login.id] = try makeAccountSource(config)
            } else {
                bound[login.id] = try definition.dataSources(forAccount: config.probeConfig).map(makeDataSource)
            }
        } catch {
            AppLog.providers.error("\(definition.id): can't run account \(login.id): \(error.localizedDescription)")
            return nil
        }
        let account = Account(provider: self, login: login, values: config.probeConfig)
        accounts.append(account)
        return account
    }

    /// Update a display name without replacing the login or resetting its usage.
    @discardableResult
    public func rename(_ account: Account, to name: String) -> Bool {
        guard accounts.contains(where: { $0 === account }) else { return false }
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if account.isDefault {
            guard let naming = settings as? AccountNamingSettingsRepository else { return false }
            naming.setDefaultAccountLabel(label, forProvider: id, email: account.namingIdentity)
        } else {
            guard let multiple = settings as? MultiAccountSettingsRepository,
                  let config = multiple.accounts(forProvider: id).first(where: { $0.accountId == account.accountId }) else { return false }
            multiple.updateAccount(config.named(label), forProvider: id)
        }
        account.label = label
        return true
    }

    /// *Remove* — forgets the login here; its CLI's files are never touched.
    /// The default login can't be removed.
    public func remove(_ account: Account) {
        guard !account.isDefault else { return }
        accounts.removeAll { $0.id == account.id }
        bound[account.id] = nil
        accountSources[account.id] = nil
        refreshTasks[account.id]?.cancel()
        refreshTasks[account.id] = nil
    }

    /// The enabled login with the most left — *switch to work*.
    public var bestAccount: Account? {
        accounts.filter(\.isEnabled).max {
            ($0.snapshot?.lowestQuota?.percentRemaining ?? -.infinity) < ($1.snapshot?.lowestQuota?.percentRemaining ?? -.infinity)
        }
    }

    /// The worst quota health across the enabled logins.
    public var status: QuotaStatus {
        accounts.filter(\.isEnabled).map(\.status).max() ?? .healthy
    }

    // MARK: - Data sources — one choice for every login

    /// The data source in use: the one the person picked, else the default.
    public var activeKind: String {
        if let chosen = settings.dataSourceKind(forProvider: definition.id), definition.dataSource(chosen) != nil {
            return chosen
        }
        return definition.defaultDataSource
    }

    /// Switches the data source. `false` when the provider has no such one.
    @discardableResult
    public func use(_ kind: String) -> Bool {
        guard definition.dataSource(kind) != nil else { return false }
        settings.setDataSourceKind(kind, forProvider: definition.id)
        return true
    }

    /// Whether a data source's fallback is on — a fallback the definition
    /// lets the person turn off (`enabledBySetting`) reads that setting; any
    /// other fallback is always on. `false` when there is no fallback.
    public func isFallbackEnabled(from kind: String) -> Bool {
        guard let fallback = definition.dataSource(kind)?.fallback else { return false }
        guard let setting = fallback.enabledBySetting else { return true }
        return settings.isOn(setting, forProvider: definition.id) != false
    }

    /// Turns a switchable fallback on or off; does nothing for one that isn't.
    public func setFallbackEnabled(_ on: Bool, from kind: String) {
        guard let setting = definition.dataSource(kind)?.fallback?.enabledBySetting else { return }
        settings.setOn(on, setting, forProvider: definition.id)
    }

    /// Whether a data source's key lookup finds a key for a login — what a
    /// config card shows as *credentials found*. The default login unless named.
    public func hasKey(for kind: String, account: Account? = nil) -> Bool {
        dataSource(kind, for: account ?? defaultAccount)?.hasKey ?? false
    }

    /// The live data sources a login runs.
    public func dataSources(for account: Account) -> [DataSource] {
        bound[account.id] ?? []
    }

    /// A data source that serves cached usage sets how often the background
    /// may ask (Claude's API: 15 minutes, #204).
    public var backgroundRefreshFloor: Duration? {
        accountSources[id]?.backgroundRefreshFloor ?? definition.dataSource(activeKind)?.cache.map { .seconds($0.ttl) }
    }

    public func backgroundRefreshFloor(for account: Account) -> Duration? {
        accountSources[account.id]?.backgroundRefreshFloor ?? backgroundRefreshFloor
    }

    // MARK: - Refresh — one login at a time

    /// Ready when the active data source is — or, failing that, the fallback
    /// it would hand over to.
    public func isAvailable(_ account: Account) async -> Bool {
        if let source = accountSources[account.id] { return await source.isAvailable() }
        guard let active = dataSource(activeKind, for: account) else { return false }
        if await active.isReady() { return true }
        guard let fallback = enabledFallback(of: active, for: account) else { return false }
        return await fallback.isReady()
    }

    /// Fetches a login's usage with the active data source and follows its
    /// hand-offs and fallback until one answers. A failure keeps the last
    /// usage on screen and reports the first real failure — not a hand-off,
    /// and not a fallback's, which would send the person chasing the wrong problem.
    @discardableResult
    public func refresh(_ account: Account, _ kind: RefreshKind = .interactive) async throws -> UsageSnapshot {
        if let source = accountSources[account.id] {
            if let running = refreshTasks[account.id] { return try await running.value }
            let task = Task { [self] in
                account.isSyncing = true
                defer { account.isSyncing = false }
                do {
                    let usage = try await source.refresh(kind)
                    try Task.checkCancellation()
                    if let expected = account.email, let actual = usage.accountEmail, expected != actual {
                        throw UsageError.sessionExpired(hint: "This source now belongs to another account. Reconnect the original login or add the new one.")
                    }
                    return account.succeed(identified(usage, for: account), from: "source")
                } catch {
                    account.fail(error)
                    throw error
                }
            }
            refreshTasks[account.id] = task
            defer { refreshTasks[account.id] = nil }
            return try await task.value
        }
        guard let active = dataSource(activeKind, for: account) else {
            throw UsageError.noData
        }
        // Held back until one explicit refresh succeeded (#216): a CLI that
        // was never signed in may open a browser login on its own.
        if kind != .interactive, active.definition.verifyBeforeBackground, !isVerified(account) {
            if let snapshot = account.snapshot { return snapshot }
            let error = UsageError.executionFailed(active.definition.unverifiedMessage ?? "Not checked yet. Click Refresh.")
            account.lastError = error
            throw error
        }
        // Overlapping refreshes of one login share one result.
        if let running = refreshTasks[account.id] { return try await running.value }
        let task = Task { try await run(account, from: active, kind) }
        refreshTasks[account.id] = task
        defer { refreshTasks[account.id] = nil }
        let usage = try await task.value
        if kind == .interactive, active.definition.verifyBeforeBackground {
            markVerified()
        }
        return usage
    }

    /// *Test Connection* — the active data source looks up the key and
    /// fetches for a login (the default unless named), stopping BEFORE
    /// mapping: what came back, or which step failed. An explicit test checks
    /// a CLI session the way an explicit refresh does (#216).
    public func testConnection(_ account: Account? = nil) async -> Result<Response, DataSourceError> {
        let account = account ?? defaultAccount
        guard let active = dataSource(activeKind, for: account) else {
            return .failure(DataSourceError(.fetch, .noData))
        }
        do {
            let response = try await active.fetchResponse()
            if active.definition.verifyBeforeBackground {
                markVerified()
            }
            return .success(response)
        } catch let failure as DataSourceError {
            return .failure(failure)
        } catch {
            return .failure(DataSourceError(.fetch, .executionFailed(error.localizedDescription)))
        }
    }

    // MARK: - Private

    private func dataSource(_ kind: String, for account: Account) -> DataSource? {
        dataSources(for: account).first { $0.kind == kind }
    }

    private func run(_ account: Account, from start: DataSource, _ kind: RefreshKind) async throws -> UsageSnapshot {
        var current = start
        account.isSyncing = true
        defer { account.isSyncing = false }

        var tried: Set = [current.kind]
        var reported: Error?
        while true {
            do {
                let usage = try await current.fetchUsage()
                return account.succeed(identified(account.isDefault ? await withDailyUsage(usage, kind) : usage, for: account), from: current.kind)
            } catch {
                let reason = Self.reason(of: error)
                if case .rateLimited? = reason {
                    // A rate limit is not a reason to hit another endpoint.
                    reported = reported ?? error
                    break
                }
                if let tag = reason?.tag, let next = current.definition.fallbackOn[tag],
                   !tried.contains(next), let handOff = dataSource(next, for: account) {
                    AppLog.probes.info("\(account.id) \(current.kind) handed off to \(next) (\(tag))")
                    tried.insert(next)
                    current = handOff
                    continue
                }
                reported = reported ?? error
                if let fallback = enabledFallback(of: current, for: account), !tried.contains(fallback.kind) {
                    AppLog.probes.warning("\(account.id) \(current.kind) failed (\(error.localizedDescription)), trying \(fallback.kind)")
                    tried.insert(fallback.kind)
                    current = fallback
                    continue
                }
                break
            }
        }
        if let reported, tried.count > 1 {
            AppLog.probes.info("\(account.id): every data source failed; reporting \(reported.localizedDescription)")
        }
        account.fail(reported ?? UsageError.noData)
        throw account.lastError ?? UsageError.noData
    }

    /// An added login is checked by being added; the default login once an
    /// explicit refresh succeeds, remembered as `<id>.verifiedAtLeastOnce`.
    private func isVerified(_ account: Account) -> Bool {
        !account.isDefault || settings.isOn("verifiedAtLeastOnce", forProvider: definition.id) == true
    }

    private func markVerified() {
        guard settings.isOn("verifiedAtLeastOnce", forProvider: definition.id) != true else { return }
        settings.setOn(true, "verifiedAtLeastOnce", forProvider: definition.id)
    }

    /// The usage as this login's: its id on every quota, its saved email when
    /// the source named none.
    private func identified(_ usage: UsageSnapshot, for account: Account) -> UsageSnapshot {
        guard usage.providerId != account.id || (usage.accountEmail == nil && account.email != nil) else { return usage }
        return UsageSnapshot(
            providerId: account.id,
            quotas: usage.quotas.map { quota in
                UsageQuota(
                    percentRemaining: quota.percentRemaining, quotaType: quota.quotaType, providerId: account.id,
                    resetsAt: quota.resetsAt, resetText: quota.resetText, windowDuration: quota.windowDuration,
                    dollarRemaining: quota.dollarRemaining, dollarUsed: quota.dollarUsed, dollarCap: quota.dollarCap,
                    group: quota.group, compactTitle: quota.compactTitle, menuBarTitle: quota.menuBarTitle,
                    currency: quota.currency
                )
            },
            capturedAt: usage.capturedAt,
            accountEmail: usage.accountEmail ?? account.email,
            accountOrganization: usage.accountOrganization,
            loginMethod: usage.loginMethod,
            accountTier: usage.accountTier,
            costUsage: usage.costUsage,
            bedrockUsage: usage.bedrockUsage,
            dailyUsageReport: usage.dailyUsageReport,
            extensionMetrics: usage.extensionMetrics
        )
    }

    /// The fallback a data source names, unless a provider setting turns it off.
    private func enabledFallback(of source: DataSource, for account: Account) -> DataSource? {
        guard let fallback = source.definition.fallback else { return nil }
        if let setting = fallback.enabledBySetting, settings.isOn(setting, forProvider: definition.id) == false {
            return nil
        }
        return dataSource(fallback.to, for: account)
    }

    private func withDailyUsage(_ usage: UsageSnapshot, _ kind: RefreshKind) async -> UsageSnapshot {
        guard kind != .background,
              let dailyUsage,
              let report = try? await dailyUsage.analyzeToday(),
              !report.today.isEmpty || !report.previous.isEmpty else {
            return usage
        }
        return UsageSnapshot(
            providerId: usage.providerId,
            quotas: usage.quotas,
            capturedAt: usage.capturedAt,
            accountEmail: usage.accountEmail,
            accountOrganization: usage.accountOrganization,
            loginMethod: usage.loginMethod,
            accountTier: usage.accountTier,
            costUsage: usage.costUsage,
            bedrockUsage: usage.bedrockUsage,
            dailyUsageReport: report,
            extensionMetrics: usage.extensionMetrics
        )
    }

    static func reason(of error: Error) -> UsageError? {
        (error as? DataSourceError)?.reason ?? (error as? UsageError)
    }
}
