import DataSources
import Quotas
import Foundation
import CryptoKit

/// *Add Account…*: checks a folder a second login lives in
/// (`accounts.folder` in the definition) and returns what to save — the folder
/// and the login's account id; the credentials stay where the CLI keeps them.
/// `provider.add(_:)` then runs it.
public enum AddedAccounts {
    /// Checks a chosen folder and returns the account to save: the folder
    /// holds a login, it is not the default login, and it is not listed yet.
    public static func configuration(
        _ providerId: String,
        folder: String,
        existing: [ProviderAccountConfig],
        defaultFolder: String? = nil,
        security: (@Sendable ([String]) -> (status: Int32, output: String))? = nil
    ) throws -> ProviderAccountConfig {
        let definition = try Providers.builtIn(providerId)
        guard let rule = definition.accounts?.folder else {
            throw UsageError.executionFailed("\(definition.profile.name) has no added accounts.")
        }
        let home = resolved(folder)
        let defaultHome = (defaultFolder ?? rule.default).map { resolved(DataSources.expandPath($0)) }
        guard home != defaultHome else {
            throw UsageError.executionFailed("This is the default \(definition.profile.name) login, which is already listed.")
        }
        let facts = try loginFacts(providerId, folder: home, rule: rule, security: security)
        guard let accountId = facts[rule.accountId.fact], !accountId.isEmpty, let email = facts["email"] else {
            throw UsageError.executionFailed(rule.notSignedIn ?? "No \(definition.profile.name) login found in this folder.")
        }
        let defaultAccountId = try defaultHome.flatMap { try loginFacts(providerId, folder: $0, rule: rule, security: security)[rule.accountId.fact] }
        let listed = existing.contains {
            $0.probeConfig[rule.accountId.savedAs] == accountId
                || $0.probeConfig[rule.savedAs].map(resolved) == home
        }
        guard accountId != defaultAccountId, !listed else {
            throw UsageError.executionFailed("This \(definition.profile.name) account is already listed.")
        }
        return ProviderAccountConfig(
            accountId: UUID().uuidString.lowercased(), label: "", email: email,
            probeConfig: values(folder: home, rule: rule).merging([rule.accountId.savedAs: accountId]) { _, expected in expected }
        )
    }

    // MARK: - Private

    /// What the account's data sources would read in `folder` — the non-secret
    /// values of the first one that looks up a credential.
    private static func loginFacts(
        _ providerId: String,
        folder: String,
        rule: ProviderDefinition.Accounts.Folder,
        security: (@Sendable ([String]) -> (status: Int32, output: String))?
    ) throws -> [String: String] {
        let values = values(folder: folder, rule: rule).merging([rule.accountId.savedAs: ""]) { _, empty in empty }
        let definition = try Providers.builtIn(providerId)
        guard let source = try definition.dataSources(forAccount: values).first(where: { $0.credential != nil }) else {
            return [:]
        }
        let live = DataSources.make(source, providerId: providerId, security: security)
        var facts = live.credentialFacts()
        guard live.hasKey else { return [:] }
        for context in live.contextFacts().values {
            facts.merge(context) { credential, _ in credential }
        }
        return facts
    }

    private static func values(folder: String, rule: ProviderDefinition.Accounts.Folder) -> [String: String] {
        var values = [rule.savedAs: folder]
        let hash = SHA256.hash(data: Data(folder.utf8)).map { String(format: "%02x", $0) }.joined()
        for (key, value) in rule.derivedValues ?? [:] {
            values[key] = value.prefix + String(hash.prefix(max(0, min(64, value.hashLength))))
        }
        return values
    }

    private static func resolved(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
