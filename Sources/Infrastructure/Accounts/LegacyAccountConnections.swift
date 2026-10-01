import Domain
import Foundation
import Providers

/// Composes independent legacy readers behind the shared account lifecycle.
/// Existing default implementations remain untouched; added logins use explicit sources.
@MainActor
public final class LegacyAccountConnections {
    public static let shared = LegacyAccountConnections()
    private let credentials: any CredentialRepository
    private let settingsRoot: URL
    private let networkClient: any NetworkClient
    private let makeCloudWatch: @Sendable (String) -> any BedrockCloudWatchClient
    private let pricingService: any BedrockPricingService
    private let makeCLI: @Sendable (AccountCommandContext) -> any CLIExecutor
    private var recipes: [String: AccountConnectionRecipe] = [:]
    private var factories: [String: (ProviderAccountConfig) throws -> any AccountUsageSource] = [:]
    private var originals: [String: any AIProvider] = [:]

    public init(credentials: any CredentialRepository = KeychainCredentialRepository.shared,
                networkClient: any NetworkClient = URLSession.shared,
                makeCloudWatch: @escaping @Sendable (String) -> any BedrockCloudWatchClient = { AWSBedrockCloudWatchClient(profileName: $0) },
                pricingService: any BedrockPricingService = AWSBedrockPricingService(),
                makeCLI: @escaping @Sendable (AccountCommandContext) -> any CLIExecutor = { $0.executor() },
                settingsRoot: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claudebar/account-settings")) {
        self.credentials = credentials
        self.networkClient = networkClient
        self.makeCLI = makeCLI
        self.makeCloudWatch = makeCloudWatch
        self.pricingService = pricingService
        self.settingsRoot = settingsRoot
    }

    public func register(_ id: String, recipe: AccountConnectionRecipe,
                         factory: @escaping (ProviderAccountConfig) throws -> any AccountUsageSource) {
        recipes[id] = recipe
        factories[id] = factory
    }

    public func recipe(for id: String) -> AccountConnectionRecipe? { recipes[id] ?? .builtIn(id) }

    public func saveField(_ value: String, field: String, providerId: String, config: ProviderAccountConfig) throws {
        let repository = scope(providerId, config)
        repository.save(value, forKey: "field." + field)
        guard repository.get(forKey: "field." + field) == value else { throw UsageError.authenticationRequired }
    }

    public func deleteField(_ field: String, providerId: String, config: ProviderAccountConfig) {
        _ = scope(providerId, config).delete(forKey: "field." + field)
    }

    public func accountCredentials(_ id: String, config: ProviderAccountConfig) -> ScopedCredentialRepository { scope(id, config) }

    public func original(_ id: String) -> (any AIProvider)? { originals[id] }

    public func make(_ original: any AIProvider, settings: any MultiAccountSettingsRepository) throws -> Provider {
        originals[original.id] = original
        return try Provider(profile: .init(id: original.id, name: original.name,
                    links: .init(dashboard: original.dashboardURL, status: original.statusPageURL)),
            cli: original.cliCommand, enabledByDefault: original.isEnabled,
            settings: settings, accounts: settings.accounts(forProvider: original.id),
            makeAccountSource: { [self] config in
                guard let config else { return LegacyAccountUsageSource(original) }
                return try source(providerId: original.id, config: config)
            })
    }

    public func saveSecret(_ value: String, providerId: String, config: ProviderAccountConfig) throws {
        let scoped = scope(providerId, config)
        let key = Self.credentialKey(providerId)
        scoped.save(value, forKey: key)
        guard scoped.get(forKey: key) == value else {
            throw UsageError.executionFailed("This account's credential could not be saved securely. Check Keychain access and try again.")
        }
    }

    public func deleteSecret(providerId: String, config: ProviderAccountConfig) -> Bool {
        scope(providerId, config).delete(forKey: Self.credentialKey(providerId))
    }

    private func scope(_ id: String, _ config: ProviderAccountConfig) -> ScopedCredentialRepository {
        ScopedCredentialRepository(providerId: id, accountId: config.accountId, repository: credentials)
    }

    private static func credentialKey(_ id: String) -> String {
        switch id {
        case "zai": CredentialKey.zaiApiKey
        case "vercel-gateway": CredentialKey.vercelApiKey
        case "copilot": "com.claudebar.credentials.github-copilot-token"
        case "minimax": "com.claudebar.credentials.minimax-api-key"
        case "deepseek": "com.claudebar.credentials.deepseek-api-key"
        case "alibaba": "com.claudebar.credentials.alibaba-api-key"
        default: "token"
        }
    }

    public func source(providerId id: String, config: ProviderAccountConfig) throws -> any AccountUsageSource {
        if let factory = factories[id] { return try factory(config) }
        guard let recipe = AccountConnectionRecipe.builtIn(id) else { throw UsageError.authenticationRequired }
        // IDs are used as path components: only the app-generated safe UUIDs or legacy safe ids are accepted.
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard !config.accountId.isEmpty, config.accountId != "default",
              config.accountId.unicodeScalars.allSatisfy(safe.contains) else { throw UsageError.authenticationRequired }
        let scoped = scope(id, config)
        let repository = JSONSettingsRepository(store: JSONSettingsStore(fileURL: settingsRoot.appendingPathComponent(id).appendingPathComponent(config.accountId).appendingPathComponent("settings.json")),
            secureCredentials: scoped, isolatedAccountCredentials: true)
        let options = config.probeConfig
        try validateOptions(id, options)
        let selected = options["source"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if recipe.source != .token, selected.isEmpty { throw UsageError.authenticationRequired }
        let home = URL(fileURLWithPath: selected.isEmpty ? "/nonexistent" : selected).standardizedFileURL.resolvingSymlinksInPath()
        if recipe.source == .home {
            let defaultHome = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath()
            guard selected.hasPrefix("/"), home != defaultHome else {
                throw UsageError.executionFailed("Choose a separate signed-in home, rather than your ordinary home folder.")
            }
        }
        let environment = Self.environment(home: home)
        let exclusions = Self.excludedEnvironment
        let interactive = makeCLI(.init(environment: environment, exclusions: exclusions, directory: home, interactive: true))
        let simple = makeCLI(.init(environment: environment, exclusions: exclusions, directory: home, interactive: false))
        let probe: any UsageProbe
        switch id {
        case "gemini": probe = GeminiUsageProbe(homeDirectory: home.path, networkClient: networkClient, cliExecutor: interactive)
        case "ampcode": probe = AmpCodeUsageProbe(cliExecutor: interactive)
        case "kiro": probe = KiroUsageProbe(cliExecutor: simple)
        case "omp": probe = OmpUsageProbe(cliExecutor: simple)
        case "opencode-go": probe = OpenCodeAPIUsageProbe(credentialLoader: .init(homeDirectory: home.path, environment: environment), networkClient: networkClient, fallback: OpenCodeUsageProbe(cliExecutor: interactive))
        case "grok": probe = GrokUsageProbe(credentialLoader: .init(homeDirectory: home.path), networkClient: networkClient)
        case "commandcode": probe = CommandCodeUsageProbe(credentialLoader: .init(homeDirectory: home.path, environment: [:]), networkClient: networkClient)
        case "cursor":
            guard selected.hasPrefix("/"), home.path != CursorUsageProbe.defaultDatabasePath else { throw UsageError.authenticationRequired }
            return CursorAccountUsageSource(probe: CursorUsageProbe(networkClient: networkClient, dbPathOverride: home.path), expectedIdentity: options["identity"])
        case "mistral":
            guard selected.hasPrefix("/"), home != FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".vibe/logs/session").resolvingSymlinksInPath() else { throw UsageError.authenticationRequired }
            probe = MistralUsageProbe(vibeLogAnalyzer: VibeSessionLogAnalyzer(vibeSessionsDir: home), vibeSessionsDir: home)
        case "antigravity": probe = AntigravityUsageProbe(remoteNetworkClient: networkClient, accountToken: { scoped.get(forKey: "token") })
        case "zai": probe = ZaiUsageProbe(networkClient: networkClient, settingsRepository: repository, storedKeyOnly: true)
        case "minimax":
            if let region = options["region"].flatMap(MiniMaxRegion.init(rawValue:)) { repository.setMinimaxRegion(region) }
            probe = MiniMaxUsageProbe(networkClient: networkClient, settingsRepository: repository, environment: [:])
        case "deepseek": probe = DeepSeekUsageProbe(networkClient: networkClient, settingsRepository: repository, environmentValue: { _ in nil })
        case "vercel-gateway": probe = VercelUsageProbe(networkClient: networkClient, settingsRepository: repository, environment: [:])
        case "alibaba":
            if let region = options["region"].flatMap(AlibabaRegion.init(rawValue:)) { repository.setAlibabaRegion(region) }
            repository.setAlibabaCookieSource(.manual)
            probe = AlibabaUsageProbe(settingsRepository: repository, networkClient: networkClient, cookieProvider: NoAccountBrowserCookies())
        case "copilot":
            if let username = options["username"] { repository.saveGithubUsername(username) }
            if let mode = options["mode"].flatMap(CopilotProbeMode.init(rawValue:)) { repository.setCopilotProbeMode(mode) }
            if let limit = options["monthlyLimit"].flatMap(Int.init) { repository.setCopilotMonthlyLimit(limit) }
            return LegacyAccountUsageSource(CopilotProvider(billingProbe: CopilotUsageProbe(networkClient: networkClient, settingsRepository: repository, environment: [:]),
                internalProbe: CopilotInternalAPIProbe(networkClient: networkClient, settingsRepository: repository, environment: [:]), settingsRepository: repository))
        case "kimi":
            if let region = options["region"].flatMap(KimiRegion.init(rawValue:)) { repository.setKimiRegion(region) }
            // This token connection has no unscoped CLI fallback.
            probe = KimiUsageProbe(networkClient: networkClient, tokenProvider: AccountKimiToken(scoped), settingsRepository: repository)
        case "bedrock":
            repository.setAWSProfileName(selected)
            if let regions = options["regions"], !regions.isEmpty { repository.setBedrockRegions(regions.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }) }
            if let budget = options["dailyBudget"].flatMap { Decimal(string: $0) } { repository.setBedrockDailyBudget(budget) }
            probe = BedrockUsageProbe(cloudWatchClient: makeCloudWatch(selected), pricingService: pricingService, settingsRepository: repository, failOnAllRegionFailures: true)
        default: throw UsageError.authenticationRequired
        }
        let required: String? = switch id {
        case "ampcode": ".local/share/amp/secrets.json"
        case "kiro": "Library/Application Support/kiro-cli/data.sqlite3"
        case "omp": ".omp/agent/agent.db"
        default: nil
        }
        let dashboard: URL? = switch id {
        case "minimax": repository.minimaxRegion().dashboardURL
        case "kimi": URL(string: repository.kimiRegion().consoleURL)
        default: nil
        }
        return ProbeAccountUsageSource(probe, requiredFile: id == "mistral" ? home : required.map { home.appendingPathComponent($0) }, dashboardURL: dashboard)
    }

    private func validateOptions(_ id: String, _ options: [String: String]) throws {
        func invalid(_ field: String) -> UsageError { .executionFailed("Choose a valid \(field) for this account.") }
        if let region = options["region"], !region.isEmpty {
            switch id {
            case "minimax": guard MiniMaxRegion(rawValue: region) != nil else { throw invalid("region") }
            case "kimi": guard KimiRegion(rawValue: region) != nil else { throw invalid("region") }
            case "alibaba": guard AlibabaRegion(rawValue: region) != nil else { throw invalid("region") }
            default: break
            }
        }
        if let mode = options["mode"], !mode.isEmpty, id == "copilot", CopilotProbeMode(rawValue: mode) == nil { throw invalid("usage source") }
        if let amount = options["dailyBudget"], !amount.isEmpty {
            guard let budget = Decimal(string: amount), budget > 0 else { throw invalid("daily budget") }
        }
        if let amount = options["monthlyLimit"], !amount.isEmpty {
            guard let limit = Int(amount), limit > 0 else { throw invalid("monthly request limit") }
        }
    }

    nonisolated static let excludedEnvironment = ["OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_AUTH_TOKEN", "ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN", "GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_APPLICATION_CREDENTIALS", "AMP_API_KEY", "KIMI_AUTH_TOKEN", "KIRO_API_KEY", "OPENCODE_API_KEY", "COMMAND_CODE_API_KEY", "COMMANDCODE_API_KEY", "GROK_API_KEY", "XAI_API_KEY", "OMP_AUTH_BROKER_URL", "OMP_AUTH_BROKER_TOKEN", "PI_CODING_AGENT_DIR", "PI_CONFIG_DIR", "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "KIRO_HOME", "KIRO_DATA_DIR", "CODEX_HOME", "CLAUDE_CONFIG_DIR", "GEMINI_CLI_HOME", "AMP_CONFIG_DIR", "AMP_SETTINGS_FILE", "GITHUB_TOKEN", "GH_TOKEN", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN", "AWS_PROFILE", "AI_GATEWAY_API_KEY", "MINIMAX_API_KEY", "DEEPSEEK_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_PROFILE"]

    nonisolated static func environment(home: URL) -> [String: String] {
        ["HOME": home.path, "XDG_CONFIG_HOME": home.appendingPathComponent(".config").path,
         "XDG_DATA_HOME": home.appendingPathComponent(".local/share").path,
         "XDG_CACHE_HOME": home.appendingPathComponent(".cache").path,
         "GEMINI_CLI_HOME": home.path,
         "AMP_SETTINGS_FILE": home.appendingPathComponent(".config/amp/settings.json").path,
         "KIRO_HOME": home.appendingPathComponent(".kiro").path,
         "KIRO_DATA_DIR": home.appendingPathComponent("Library/Application Support/kiro-cli").path,
         "PI_CONFIG_DIR": home.appendingPathComponent(".omp").path,
         "PI_CODING_AGENT_DIR": home.appendingPathComponent(".omp/agent").path]
    }
}

@MainActor
private final class ProbeAccountUsageSource: AccountUsageSource {
    let probe: any UsageProbe
    let requiredFile: URL?
    let dashboardURL: URL?
    init(_ probe: any UsageProbe, requiredFile: URL? = nil, dashboardURL: URL? = nil) {
        self.probe = probe; self.requiredFile = requiredFile; self.dashboardURL = dashboardURL
    }
    private var hasLogin: Bool { requiredFile.map { FileManager.default.fileExists(atPath: $0.path) } ?? true }
    var backgroundRefreshFloor: Duration? { nil }
    func isAvailable() async -> Bool { guard hasLogin else { return false }; return await probe.isAvailable() }
    func refresh(_ kind: RefreshKind) async throws -> UsageSnapshot {
        guard hasLogin else { throw UsageError.authenticationRequired }
        return try await probe.probe()
    }
}

private struct AccountKimiToken: KimiTokenProviding {
    let credentials: ScopedCredentialRepository
    init(_ credentials: ScopedCredentialRepository) { self.credentials = credentials }
    func resolveToken() throws -> String {
        guard let token = credentials.get(forKey: "token"), !token.isEmpty else { throw UsageError.authenticationRequired }
        return token
    }
}

private struct NoAccountBrowserCookies: AlibabaCookieProviding {
    func extractBrowserCookies() -> String? { nil }
}

@MainActor
private final class CursorAccountUsageSource: AccountUsageSource {
    let probe: CursorUsageProbe
    let expectedIdentity: String?
    private(set) var connectionIdentity: String?
    var backgroundRefreshFloor: Duration? { nil }
    init(probe: CursorUsageProbe, expectedIdentity: String?) { self.probe = probe; self.expectedIdentity = expectedIdentity }
    func isAvailable() async -> Bool { await probe.isAvailable() }
    func refresh(_ kind: RefreshKind) async throws -> UsageSnapshot {
        let identity = try await probe.accountIdentity()
        if let expectedIdentity, identity != expectedIdentity { throw UsageError.sessionExpired(hint: "This Cursor profile switched accounts. Remove and reconnect it.") }
        let result = try await probe.probe()
        guard try await probe.accountIdentity() == identity else { throw UsageError.authenticationRequired }
        connectionIdentity = identity
        return result
    }
}
