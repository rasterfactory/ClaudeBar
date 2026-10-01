import Foundation
import Testing
import Domain
import Providers
@testable import Infrastructure

@Suite("Independent AWS account profiles")
@MainActor
struct BedrockAccountConnectionTests {
    @Test
    func selectedProfileAndBudgetStayLocalToEachAccount() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let failures = UnavailableAWSProfiles()
        let ambient = ProcessInfo.processInfo.environment["AWS_PROFILE"]
        let connections = LegacyAccountConnections(makeCloudWatch: { ProfileCloudWatchFixture(profile: $0, unavailable: failures) }, pricingService: ProfilePricingFixture(), settingsRoot: root)
        let personal = ProviderAccountConfig(accountId: "personal", label: "Personal", probeConfig: ["source": "personal", "regions": "us-east-1", "dailyBudget": "10"])
        let work = ProviderAccountConfig(accountId: "work", label: "Work", probeConfig: ["source": "work", "regions": "eu-west-1", "dailyBudget": "100"])
        let a = try connections.source(providerId: "bedrock", config: personal)
        let b = try connections.source(providerId: "bedrock", config: work)
        let first = try await a.refresh(.interactive)
        let second = try await b.refresh(.interactive)
        #expect(first.bedrockUsage?.dailyBudget == 10)
        #expect(second.bedrockUsage?.dailyBudget == 100)
        #expect(first.bedrockUsage?.region == "us-east-1")
        #expect(second.bedrockUsage?.region == "eu-west-1")
        #expect(first.bedrockUsage?.totalCost != second.bedrockUsage?.totalCost)
        failures.disable("work")
        await #expect(throws: UsageError.authenticationRequired) { try await b.refresh(.interactive) }
        #expect(try await a.refresh(.interactive).bedrockUsage?.totalCost == first.bedrockUsage?.totalCost)
        #expect(ProcessInfo.processInfo.environment["AWS_PROFILE"] == ambient)
    }
}

private final class UnavailableAWSProfiles: @unchecked Sendable {
    private let lock = NSLock()
    private var profiles = Set<String>()
    func disable(_ profile: String) { lock.lock(); defer { lock.unlock() }; profiles.insert(profile) }
    func contains(_ profile: String) -> Bool { lock.lock(); defer { lock.unlock() }; return profiles.contains(profile) }
}
private struct ProfileCloudWatchFixture: BedrockCloudWatchClient {
    let profile: String
    let unavailable: UnavailableAWSProfiles
    func verifyCredentials() async -> Bool { !unavailable.contains(profile) }
    func fetchBedrockMetrics(region: String, startTime: Date, endTime: Date) async throws -> [BedrockMetricData] {
        guard !unavailable.contains(profile) else { throw UsageError.authenticationRequired }
        return [.init(modelId: "fixture", inputTokens: profile == "work" ? 400_000 : 100_000, outputTokens: 100_000, invocations: 10)]
    }
}
private struct ProfilePricingFixture: BedrockPricingService {
    func getModelPricing(modelId: String) async throws -> BedrockModel {
        .init(id: modelId, displayName: "Fixture", vendor: "Fixture", inputPricePer1M: 10, outputPricePer1M: 20)
    }
}
