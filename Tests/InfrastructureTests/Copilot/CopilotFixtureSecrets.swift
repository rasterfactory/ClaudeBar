import DataSources
import Infrastructure

struct CopilotFixtureSecrets: SecretStore {
    let settings: JSONSettingsRepository
    func secret(_ name: String, provider: String) -> String? {
        guard provider == "copilot" else { return nil }
        switch name {
        case "apiKey": return settings.getGithubToken()
        case "username": return settings.getGithubUsername()
        default: return nil
        }
    }
}
