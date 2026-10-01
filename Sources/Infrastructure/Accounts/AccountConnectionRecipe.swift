import Foundation
import Domain

/// Connection fields are distinct from display names and from secrets.
public struct AccountConnectionRecipe: Sendable {
    public enum Source: Sendable, Equatable { case token, home, file, profile, directory }
    public let source: Source
    public let title: String
    public let help: String
    public let options: [String]
    public let fields: [ConfigField]

    public init(source: Source, title: String, help: String, options: [String], fields: [ConfigField] = []) {
        self.source = source; self.title = title; self.help = help; self.options = options; self.fields = fields
    }

    public static func builtIn(_ id: String) -> Self? {
        switch id {
        case "antigravity": .init(source: .token, title: "OAuth access token", help: "Use a token from the account to monitor. This connection uses the cloud API; it never discovers another desktop session.", options: [])
        case "zai", "deepseek", "vercel-gateway": .init(source: .token, title: "API key", help: "This key is saved securely for this account only.", options: [])
        case "minimax": .init(source: .token, title: "API key", help: "This key is saved securely for this account only.", options: ["region"])
        case "copilot": .init(source: .token, title: "GitHub token", help: "Use a Classic PAT with copilot scope for the internal API, or a fine-grained PAT with Plan: read for billing. Enter the GitHub username for billing.", options: ["username", "mode", "monthlyLimit"])
        case "kimi": .init(source: .token, title: "Kimi authentication token", help: "Use this account's kimi-auth token. Only this account’s token is used; browser cookie discovery is disabled.", options: ["region"])
        case "alibaba": .init(source: .token, title: "API key", help: "Use the key for the account's Coding Plan. Browser cookie discovery is disabled for this connection.", options: ["region"])
        case "bedrock": .init(source: .profile, title: "AWS profile", help: "Choose a separately authenticated AWS profile. Usage is read from CloudWatch; budgets apply to this account only.", options: ["regions", "dailyBudget"])
        case "cursor": .init(source: .file, title: "Cursor account database", help: "Choose state.vscdb from a separate signed-in Cursor profile. Account switching in that profile requires reconnecting here.", options: [])
        case "mistral": .init(source: .directory, title: "Vibe session log folder", help: "Choose the session logs for this profile. These show local cost and tokens, rather than cloud account quota.", options: [])
        case "gemini", "ampcode", "kiro", "opencode-go", "omp", "grok", "commandcode": .init(source: .home, title: "Signed-in account home", help: "Choose an independent home folder containing this tool's login. Its credential files and subprocess environment stay separate from the ordinary login.", options: [])
        default: nil
        }
    }
}
