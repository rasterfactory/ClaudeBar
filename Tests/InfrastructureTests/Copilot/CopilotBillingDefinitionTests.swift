import Testing
import Foundation
import Mockable
@testable import Infrastructure
@testable import Domain
import Providers
import DataSources

@MainActor @Suite("CopilotBillingDefinitionTests")
struct CopilotBillingDefinitionTests {

    private func makeProvider(networkClient: any NetworkClient = MockNetworkClient(), settingsRepository: JSONSettingsRepository, timeout: TimeInterval = 30) throws -> Account {
        settingsRepository.setCopilotProbeMode(.billing)
        let definition=try Providers.builtIn("copilot")
        let provider=Provider(definition:definition,settings:settingsRepository,makeDataSource:{source,_ in
            DataSources.make(source,providerId:"copilot",cliExecutor:MockCLIExecutor(),network:networkClient,makeTransport:{_,_,_,_ in MockRPCTransport()},scripts:Providers.builtInScripts,secrets:CopilotFixtureSecrets(settings:settingsRepository),settings:settingsRepository.scopedValues(forProvider:"copilot"),environment:{name in
                let configured=settingsRepository.copilotAuthEnvVar()
                if name == "COPILOT_TOKEN" {
                    return configured.isEmpty ? nil : ProcessInfo.processInfo.environment[configured]
                }
                return ProcessInfo.processInfo.environment[name]
            },homeDirectory:FileManager.default.temporaryDirectory,now:{Date()})
        })
        return provider.defaultAccount
    }


    // MARK: - Test Helpers

    private nonisolated func makeHTTPResponse(statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://api.github.com")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    private func makeSettingsRepository(
        username: String = "",
        hasToken: Bool = false,
        copilotAuthEnvVar: String = "",
        monthlyLimit: Int? = nil,
        manualOverrideEnabled: Bool = false,
        manualUsageValue: Double? = nil,
        manualUsageIsPercent: Bool = false,
        apiReturnedEmpty: Bool = false,
        lastUsagePeriodMonth: Int? = nil,
        lastUsagePeriodYear: Int? = nil
    ) -> JSONSettingsRepository {
        let suiteName = "com.claudebar.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let repo = JSONSettingsRepository(store: JSONSettingsStore(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")), credentials: defaults, secureCredentials: UserDefaultsCredentialRepository(defaults: defaults))
        repo.setEnabled(true, forProvider: "copilot")
        if !username.isEmpty {
            repo.saveGithubUsername(username)
        }
        if hasToken {
            repo.saveGithubToken("ghp_test_token")
        }
        if !copilotAuthEnvVar.isEmpty {
            repo.setCopilotAuthEnvVar(copilotAuthEnvVar)
        }
        if let monthlyLimit {
            repo.setCopilotMonthlyLimit(monthlyLimit)
        }
        repo.setCopilotManualOverrideEnabled(manualOverrideEnabled)
        if let manualUsageValue {
            repo.setCopilotManualUsageValue(manualUsageValue)
        }
        repo.setCopilotManualUsageIsPercent(manualUsageIsPercent)
        repo.setCopilotApiReturnedEmpty(apiReturnedEmpty)
        if let lastUsagePeriodMonth, let lastUsagePeriodYear {
            repo.setCopilotLastUsagePeriod(month: lastUsagePeriodMonth, year: lastUsagePeriodYear)
        }
        return repo
    }

    // MARK: - isAvailable Tests

    @Test
    func `isAvailable returns true when token and username are configured`() async throws {
        let settings = makeSettingsRepository(username: "testuser", hasToken: true)
        let probe = try makeProvider(settingsRepository: settings)

        #expect(await probe.isAvailable() == true)
    }

    @Test
    func `isAvailable returns false when token is missing`() async throws {
        let settings = makeSettingsRepository(username: "testuser", hasToken: false)
        let probe = try makeProvider(settingsRepository: settings)

        #expect(await probe.isAvailable() == false)
    }

    @Test
    func `isAvailable returns false when username is missing`() async throws {
        let settings = makeSettingsRepository(username: "", hasToken: true)
        let probe = try makeProvider(settingsRepository: settings)

        #expect(await probe.isAvailable() == false)
    }

    // MARK: - Probe Tests

    @Test
    func `probe throws authenticationRequired when token is missing`() async throws {
        let settings = makeSettingsRepository(username: "testuser", hasToken: false)
        let probe = try makeProvider(settingsRepository: settings)

        await #expect(throws: UsageError.authenticationRequired) {
            try await probe.refresh()
        }
    }

    @Test
    func `probe throws executionFailed when username is missing`() async throws {
        let settings = makeSettingsRepository(username: "", hasToken: true)
        let probe = try makeProvider(settingsRepository: settings)

        await #expect(throws: UsageError.self) {
            try await probe.refresh()
        }
    }

    @Test
    func `probe parses valid response correctly`() async throws {
        let settings = makeSettingsRepository(username: "testuser", hasToken: true)
        let mockNetwork = MockNetworkClient()
        let responseJSON = """
        {
          "timePeriod": { "year": 2025, "month": 12 },
          "user": "testuser",
          "usageItems": [
            {
              "product": "Copilot",
              "sku": "Copilot Premium Request",
              "model": "Claude Sonnet 4",
              "unitType": "requests",
              "pricePerUnit": 0.04,
              "grossQuantity": 10.0,
              "grossAmount": 0.4,
              "discountQuantity": 10.0,
              "discountAmount": 0.4,
              "netQuantity": 0.0,
              "netAmount": 0.0
            }
          ]
        }
        """.data(using: .utf8)!

        let response = HTTPURLResponse(
            url: URL(string: "https://api.github.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!

        given(mockNetwork).request(.any).willReturn((responseJSON, response))

        let probe = try makeProvider(
            networkClient: mockNetwork,
            settingsRepository: settings
        )

        let snapshot = try await probe.refresh()

        #expect(snapshot.providerId == "copilot")
        #expect(snapshot.accountEmail == "testuser")
        #expect(snapshot.quotas.count == 1)

        let quota = snapshot.quotas.first!
        #expect(quota.quotaType == .timeLimit("Monthly"))
        #expect(quota.resetsAt != nil)
        #expect(quota.percentRemaining == 80.0)
        #expect(quota.resetText == "10/50 AI credits")
    }

    @Test
    func `probe calculates percentage correctly with multiple items`() async throws {
        let settings = makeSettingsRepository(username: "testuser", hasToken: true)
        let mockNetwork = MockNetworkClient()
        let responseJSON = """
        {
          "timePeriod": { "year": 2025, "month": 12 },
          "user": "testuser",
          "usageItems": [
            {
              "product": "Copilot",
              "sku": "Copilot Premium Request",
              "model": "Claude Sonnet 4",
              "grossQuantity": 15.0
            },
            {
              "product": "Copilot",
              "sku": "Copilot Premium Request",
              "model": "GPT-4o",
              "grossQuantity": 10.0
            },
            {
              "product": "Actions",
              "sku": "Actions Linux",
              "grossQuantity": 1000.0
            }
          ]
        }
        """.data(using: .utf8)!

        let response = HTTPURLResponse(
            url: URL(string: "https://api.github.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!

        given(mockNetwork).request(.any).willReturn((responseJSON, response))

        let probe = try makeProvider(
            networkClient: mockNetwork,
            settingsRepository: settings
        )

        let snapshot = try await probe.refresh()

        let quota = snapshot.quotas.first!
        #expect(quota.resetsAt != nil)
        #expect(quota.percentRemaining == 50.0)
        #expect(quota.resetText == "25/50 AI credits")
    }

    @Test
    func `probe returns 100 percent remaining when no usage`() async throws {
        let settings = makeSettingsRepository(username: "testuser", hasToken: true)
        let mockNetwork = MockNetworkClient()
        let responseJSON = """
        {
          "timePeriod": { "year": 2025, "month": 12 },
          "user": "testuser",
          "usageItems": []
        }
        """.data(using: .utf8)!

        let response = HTTPURLResponse(
            url: URL(string: "https://api.github.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!

        given(mockNetwork).request(.any).willReturn((responseJSON, response))

        let probe = try makeProvider(
            networkClient: mockNetwork,
            settingsRepository: settings
        )

        let snapshot = try await probe.refresh()

        let quota = snapshot.quotas.first!
        #expect(quota.resetsAt != nil)
        #expect(quota.percentRemaining == 100.0)
        #expect(quota.resetText == "0/50 AI credits")
    }

    @Test
    func `probe uses custom monthly limit from settings`() async throws {
        // Business account with 300 limit
        let settings = makeSettingsRepository(username: "testuser", hasToken: true, monthlyLimit: 300)
        let mockNetwork = MockNetworkClient()
        let responseJSON = """
        {
          "timePeriod": { "year": 2025, "month": 12 },
          "user": "testuser",
          "usageItems": [
            {
              "product": "Copilot",
              "sku": "Copilot Premium Request",
              "model": "Claude Sonnet 4",
              "grossQuantity": 100.0
            }
          ]
        }
        """.data(using: .utf8)!

        let response = HTTPURLResponse(
            url: URL(string: "https://api.github.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!

        given(mockNetwork).request(.any).willReturn((responseJSON, response))

        let probe = try makeProvider(
            networkClient: mockNetwork,
            settingsRepository: settings
        )

        let snapshot = try await probe.refresh()

        let quota = snapshot.quotas.first!
        // 100/300 = 33.33% used, 66.67% remaining
        #expect(quota.resetsAt != nil)
        #expect(quota.percentRemaining.rounded() == 67.0)
        #expect(quota.resetText == "100/300 AI credits")
    }

    @Test
    func `probe uses default limit when no custom limit set`() async throws {
        let settings = makeSettingsRepository(username: "testuser", hasToken: true)
        let mockNetwork = MockNetworkClient()
        let responseJSON = """
        {
          "timePeriod": { "year": 2025, "month": 12 },
          "user": "testuser",
          "usageItems": [
            {
              "product": "Copilot",
              "sku": "Copilot Premium Request",
              "model": "Claude Sonnet 4",
              "grossQuantity": 25.0
            }
          ]
        }
        """.data(using: .utf8)!

        let response = HTTPURLResponse(
            url: URL(string: "https://api.github.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!

        given(mockNetwork).request(.any).willReturn((responseJSON, response))

        let probe = try makeProvider(
            networkClient: mockNetwork,
            settingsRepository: settings
        )

        let snapshot = try await probe.refresh()

        let quota = snapshot.quotas.first!
        // Should use default 50 (Free/Pro tier AI credits)
        #expect(quota.resetsAt != nil)
        #expect(quota.percentRemaining == 50.0)
        #expect(quota.resetText == "25/50 AI credits")
    }

    @Test
    func `probe calculates correctly for Pro Plus account limit`() async throws {
        // Pro+ account with 1500 limit
        let settings = makeSettingsRepository(username: "testuser", hasToken: true, monthlyLimit: 1500)
        let mockNetwork = MockNetworkClient()
        let responseJSON = """
        {
          "timePeriod": { "year": 2025, "month": 12 },
          "user": "testuser",
          "usageItems": [
            {
              "product": "Copilot",
              "sku": "Copilot Premium Request",
              "model": "Claude Sonnet 4",
              "grossQuantity": 750.0
            }
          ]
        }
        """.data(using: .utf8)!

        let response = HTTPURLResponse(
            url: URL(string: "https://api.github.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!

        given(mockNetwork).request(.any).willReturn((responseJSON, response))

        let probe = try makeProvider(
            networkClient: mockNetwork,
            settingsRepository: settings
        )

        let snapshot = try await probe.refresh()

        let quota = snapshot.quotas.first!
        // 750/1500 = 50% used, 50% remaining
        #expect(quota.resetsAt != nil)
        #expect(quota.percentRemaining == 50.0)
        #expect(quota.resetText == "750/1500 AI credits")
    }

    @Test
    func `probe uses default 50 when monthly limit is invalid`() async throws {
        // Test with zero limit (invalid)
        let settings = makeSettingsRepository(username: "testuser", hasToken: true, monthlyLimit: 0)
        let mockNetwork = MockNetworkClient()
        let responseJSON = """
        {
          "timePeriod": { "year": 2025, "month": 12 },
          "user": "testuser",
          "usageItems": [
            {
              "product": "Copilot",
              "sku": "Copilot Premium Request",
              "model": "Claude Sonnet 4",
              "grossQuantity": 25.0
            }
          ]
        }
        """.data(using: .utf8)!

        let response = HTTPURLResponse(
            url: URL(string: "https://api.github.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!

        given(mockNetwork).request(.any).willReturn((responseJSON, response))

        let probe = try makeProvider(
            networkClient: mockNetwork,
            settingsRepository: settings
        )

        let snapshot = try await probe.refresh()

        let quota = snapshot.quotas.first!
        // Should fall back to default 50 when limit is invalid (0 or negative)
        #expect(quota.resetsAt != nil)
        #expect(quota.percentRemaining == 50.0)
        #expect(quota.resetText == "25/50 AI credits")
    }

    // MARK: - Manual Override Tests

    @Test
    func `probe sets apiReturnedEmpty flag when API returns empty usageItems`() async throws {
        let settings = makeSettingsRepository(username: "testuser", hasToken: true)
        let mockNetwork = MockNetworkClient()
        let responseJSON = """
        {
          "timePeriod": { "year": 2026, "month": 1 },
          "user": "testuser",
          "usageItems": []
        }
        """.data(using: .utf8)!

        let response = HTTPURLResponse(
            url: URL(string: "https://api.github.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!

        given(mockNetwork).request(.any).willReturn((responseJSON, response))

        let probe = try makeProvider(
            networkClient: mockNetwork,
            settingsRepository: settings
        )

        let snapshot = try await probe.refresh()

        // Verify apiReturnedEmpty flag was set (but manual override NOT auto-enabled)
        #expect(settings.copilotApiReturnedEmpty() == true)
        #expect(settings.copilotManualOverrideEnabled() == false)
        
        // Should return 100% remaining (zero usage)
        let quota = snapshot.quotas.first!
        #expect(quota.percentRemaining == 100.0)
    }

    @Test
    func `probe sets apiReturnedEmpty when API has non-Copilot items only`() async throws {
        let settings = makeSettingsRepository(username: "testuser", hasToken: true)
        let mockNetwork = MockNetworkClient()
        let responseJSON = """
        {
          "timePeriod": { "year": 2026, "month": 1 },
          "user": "testuser",
          "usageItems": [
            {
              "product": "Actions",
              "sku": "Actions Linux",
              "grossQuantity": 1000.0
            }
          ]
        }
        """.data(using: .utf8)!

        let response = HTTPURLResponse(
            url: URL(string: "https://api.github.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!

        given(mockNetwork).request(.any).willReturn((responseJSON, response))

        let probe = try makeProvider(
            networkClient: mockNetwork,
            settingsRepository: settings
        )

        let snapshot = try await probe.refresh()

        // Verify apiReturnedEmpty flag is set even when API returns non-Copilot items
        #expect(settings.copilotApiReturnedEmpty() == true)
        
        // Should return 100% remaining (zero Copilot usage)
        let quota = snapshot.quotas.first!
        #expect(quota.resetsAt != nil)
        #expect(quota.percentRemaining == 100.0)
        #expect(quota.resetText == "0/50 AI credits")
    }

    @Test
    func `probe uses manual usage when override is enabled`() async throws {
        let settings = makeSettingsRepository(
            username: "testuser",
            hasToken: true,
            monthlyLimit: 300,
            manualOverrideEnabled: true,
            manualUsageValue: 99,
            manualUsageIsPercent: false
        )
        let mockNetwork = MockNetworkClient()
        let responseJSON = """
        {
          "timePeriod": { "year": 2026, "month": 1 },
          "user": "testuser",
          "usageItems": []
        }
        """.data(using: .utf8)!

        let response = HTTPURLResponse(
            url: URL(string: "https://api.github.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!

        given(mockNetwork).request(.any).willReturn((responseJSON, response))

        let probe = try makeProvider(
            networkClient: mockNetwork,
            settingsRepository: settings
        )

        let snapshot = try await probe.refresh()

        let quota = snapshot.quotas.first!
        // Manual usage: 99/300 = 33% used, 67% remaining
        #expect(quota.resetsAt != nil)
        #expect(quota.percentRemaining == 67.0)
        #expect(quota.resetText == "99/300 AI credits (manual)")
    }

    @Test
    func `probe shows manual indicator in resetText when using manual override`() async throws {
        let settings = makeSettingsRepository(
            username: "testuser",
            hasToken: true,
            manualOverrideEnabled: true,
            manualUsageValue: 50,
            manualUsageIsPercent: false
        )
        let mockNetwork = MockNetworkClient()
        let responseJSON = """
        {
          "timePeriod": { "year": 2026, "month": 1 },
          "user": "testuser",
          "usageItems": [
            {
              "product": "Copilot",
              "grossQuantity": 10.0
            }
          ]
        }
        """.data(using: .utf8)!

        let response = HTTPURLResponse(
            url: URL(string: "https://api.github.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!

        given(mockNetwork).request(.any).willReturn((responseJSON, response))

        let probe = try makeProvider(
            networkClient: mockNetwork,
            settingsRepository: settings
        )

        let snapshot = try await probe.refresh()

        let quota = snapshot.quotas.first!
        // Should use manual value (50) not API value (10)
        #expect(quota.resetsAt != nil)
        #expect(quota.resetText?.contains("(manual)") == true)
        #expect(quota.resetText == "50/50 AI credits (manual)")
    }

    @Test
    func `probe clears apiReturnedEmpty flag when API returns data`() async throws {
        let settings = makeSettingsRepository(
            username: "testuser",
            hasToken: true,
            apiReturnedEmpty: true
        )
        let mockNetwork = MockNetworkClient()
        let responseJSON = """
        {
          "timePeriod": { "year": 2026, "month": 1 },
          "user": "testuser",
          "usageItems": [
            {
              "product": "Copilot",
              "grossQuantity": 10.0
            }
          ]
        }
        """.data(using: .utf8)!

        let response = HTTPURLResponse(
            url: URL(string: "https://api.github.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!

        given(mockNetwork).request(.any).willReturn((responseJSON, response))

        let probe = try makeProvider(
            networkClient: mockNetwork,
            settingsRepository: settings
        )

        _ = try await probe.refresh()

        // Flag should be cleared when API returns data
        #expect(settings.copilotApiReturnedEmpty() == false)
    }

    @Test
    func `probe throws error when manual override enabled but no value set`() async throws {
        let settings = makeSettingsRepository(
            username: "testuser",
            hasToken: true,
            manualOverrideEnabled: true,
            manualUsageValue: nil  // No value set
        )
        let mockNetwork = MockNetworkClient()
        let responseJSON = """
        {
          "timePeriod": { "year": 2026, "month": 1 },
          "user": "testuser",
          "usageItems": []
        }
        """.data(using: .utf8)!

        let response = HTTPURLResponse(
            url: URL(string: "https://api.github.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!

        given(mockNetwork).request(.any).willReturn((responseJSON, response))

        let probe = try makeProvider(
            networkClient: mockNetwork,
            settingsRepository: settings
        )

        // Should throw when manual override is on but value is nil
        await #expect(throws: UsageError.self) {
            try await probe.refresh()
        }
    }

    @Test
    func `probe handles percentage input correctly`() async throws {
        let settings = makeSettingsRepository(
            username: "testuser",
            hasToken: true,
            monthlyLimit: 300,
            manualOverrideEnabled: true,
            manualUsageValue: 198,  // 198% of quota
            manualUsageIsPercent: true
        )
        let mockNetwork = MockNetworkClient()
        let responseJSON = """
        {
          "timePeriod": { "year": 2026, "month": 1 },
          "user": "testuser",
          "usageItems": []
        }
        """.data(using: .utf8)!

        let response = HTTPURLResponse(
            url: URL(string: "https://api.github.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!

        given(mockNetwork).request(.any).willReturn((responseJSON, response))

        let probe = try makeProvider(
            networkClient: mockNetwork,
            settingsRepository: settings
        )

        let snapshot = try await probe.refresh()

        let quota = snapshot.quotas.first!
        // 198% used = -98% remaining (594 requests of 300 limit)
        #expect(quota.resetsAt != nil)
        #expect(quota.percentRemaining == -98.0)
        #expect(quota.resetText == "594/300 AI credits (manual)")
    }

    @Test
    func `probe allows negative percentages for over-quota usage`() async throws {
        let settings = makeSettingsRepository(
            username: "testuser",
            hasToken: true,
            monthlyLimit: 50,
            manualOverrideEnabled: true,
            manualUsageValue: 99,  // 99 requests of 50 limit
            manualUsageIsPercent: false
        )
        let mockNetwork = MockNetworkClient()
        let responseJSON = """
        {
          "timePeriod": { "year": 2026, "month": 1 },
          "user": "testuser",
          "usageItems": []
        }
        """.data(using: .utf8)!

        let response = HTTPURLResponse(
            url: URL(string: "https://api.github.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!

        given(mockNetwork).request(.any).willReturn((responseJSON, response))

        let probe = try makeProvider(
            networkClient: mockNetwork,
            settingsRepository: settings
        )

        let snapshot = try await probe.refresh()

        let quota = snapshot.quotas.first!
        // 99/50 = -98% remaining
        #expect(quota.resetsAt != nil)
        #expect(quota.percentRemaining == -98.0)
        #expect(quota.resetText == "99/50 AI credits (manual)")
    }

    @Test
    func `probe clears manual entry when usage period changes`() async throws {
        let settings = makeSettingsRepository(
            username: "testuser",
            hasToken: true,
            monthlyLimit: 300,
            manualOverrideEnabled: true,
            manualUsageValue: 99,
            manualUsageIsPercent: false,
            lastUsagePeriodMonth: 12,  // December
            lastUsagePeriodYear: 2025
        )
        let mockNetwork = MockNetworkClient()
        let responseJSON = """
        {
          "timePeriod": { "year": 2026, "month": 1 },
          "user": "testuser",
          "usageItems": []
        }
        """.data(using: .utf8)!

        let response = HTTPURLResponse(
            url: URL(string: "https://api.github.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!

        given(mockNetwork).request(.any).willReturn((responseJSON, response))

        let probe = try makeProvider(
            networkClient: mockNetwork,
            settingsRepository: settings
        )

        // Should throw because period changed (Dec 2025 → Jan 2026) and manual value was cleared
        await #expect(throws: UsageError.self) {
            try await probe.refresh()
        }

        // Verify manual value was cleared
        #expect(settings.copilotManualUsageValue() == nil)
        // Verify period was updated
        #expect(settings.copilotLastUsagePeriodMonth() == 1)
        #expect(settings.copilotLastUsagePeriodYear() == 2026)
    }

    @Test
    func `probe preserves manual entry when period remains same`() async throws {
        let settings = makeSettingsRepository(
            username: "testuser",
            hasToken: true,
            monthlyLimit: 300,
            manualOverrideEnabled: true,
            manualUsageValue: 99,
            manualUsageIsPercent: false,
            lastUsagePeriodMonth: 1,
            lastUsagePeriodYear: 2026
        )
        let mockNetwork = MockNetworkClient()
        let responseJSON = """
        {
          "timePeriod": { "year": 2026, "month": 1 },
          "user": "testuser",
          "usageItems": []
        }
        """.data(using: .utf8)!

        let response = HTTPURLResponse(
            url: URL(string: "https://api.github.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!

        given(mockNetwork).request(.any).willReturn((responseJSON, response))

        let probe = try makeProvider(
            networkClient: mockNetwork,
            settingsRepository: settings
        )

        let snapshot = try await probe.refresh()

        // Manual value should still be there
        #expect(settings.copilotManualUsageValue() == 99)
        
        let quota = snapshot.quotas.first!
        #expect(quota.resetsAt != nil)
        #expect(quota.percentRemaining == 67.0)  // 99/300 = 33% used, 67% remaining
        #expect(quota.resetText == "99/300 AI credits (manual)")
    }

    // MARK: - Error Handling Tests

    @Test
    func `probe throws authenticationRequired on 401 response`() async throws {
        let settings = makeSettingsRepository(username: "testuser", hasToken: true)
        let mockNetwork = MockNetworkClient()
        let response = HTTPURLResponse(
            url: URL(string: "https://api.github.com")!,
            statusCode: 401,
            httpVersion: nil,
            headerFields: nil
        )!

        given(mockNetwork).request(.any).willReturn((Data(), response))

        let probe = try makeProvider(
            networkClient: mockNetwork,
            settingsRepository: settings
        )

        await #expect(throws: UsageError.authenticationRequired) {
            try await probe.refresh()
        }
    }

    @Test
    func `probe throws executionFailed on 403 response`() async throws {
        let settings = makeSettingsRepository(username: "testuser", hasToken: true)
        let mockNetwork = MockNetworkClient()
        let response = HTTPURLResponse(
            url: URL(string: "https://api.github.com")!,
            statusCode: 403,
            httpVersion: nil,
            headerFields: nil
        )!

        given(mockNetwork).request(.any).willReturn((Data(), response))

        let probe = try makeProvider(
            networkClient: mockNetwork,
            settingsRepository: settings
        )

        await #expect(throws: UsageError.self) {
            try await probe.refresh()
        }
    }

    @Test
    func `probe throws parseFailed on invalid JSON`() async throws {
        let settings = makeSettingsRepository(username: "testuser", hasToken: true)
        let mockNetwork = MockNetworkClient()
        let invalidJSON = "not valid json".data(using: .utf8)!
        let response = HTTPURLResponse(
            url: URL(string: "https://api.github.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!

        given(mockNetwork).request(.any).willReturn((invalidJSON, response))

        let probe = try makeProvider(
            networkClient: mockNetwork,
            settingsRepository: settings
        )

        await #expect(throws: UsageError.self) {
            try await probe.refresh()
        }
    }

    @Test
    func `probe populates resetsAt as first of next UTC month`() async throws {
        let settings = makeSettingsRepository(username: "testuser", hasToken: true)
        let mockNetwork = MockNetworkClient()
        let responseJSON = """
        {
          "timePeriod": { "year": 2026, "month": 1 },
          "user": "testuser",
          "usageItems": [
            {
              "product": "Copilot",
              "sku": "Copilot Premium Request",
              "model": "Claude Sonnet 4",
              "grossQuantity": 10.0
            }
          ]
        }
        """.data(using: .utf8)!

        let response = makeHTTPResponse(statusCode: 200)

        given(mockNetwork).request(.any).willReturn((responseJSON, response))

        let probe = try makeProvider(
            networkClient: mockNetwork,
            settingsRepository: settings
        )

        let snapshot = try await probe.refresh()
        let quota = try #require(snapshot.quotas.first)
        let expected = MonthlyResetDate.nextMonthlyResetDate(referenceDate: snapshot.capturedAt)
        #expect(quota.resetsAt == expected)
    }
    @Test func `added accounts have separate tokens usernames modes limits and billing state`() async throws {
        let suite="CopilotAccounts.\(UUID())", defaults=UserDefaults(suiteName:suite)!
        defer {defaults.removePersistentDomain(forName:suite)}
        let file=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+".json")
        defer {try? FileManager.default.removeItem(at:file)}
        let credentials=UserDefaultsCredentialRepository(defaults:defaults)
        let settings=JSONSettingsRepository(store:JSONSettingsStore(fileURL:file),credentials:defaults,secureCredentials:credentials)
        settings.saveGithubToken("personal-token");settings.saveGithubUsername("personal")
        settings.setCopilotMonthlyLimit(100);settings.setCopilotManualOverrideEnabled(true);settings.setCopilotManualUsageValue(30)
        let vault=ProviderVault(credentials:credentials,legacyStore:defaults), network=MockNetworkClient()
        given(network).request(.any).willProduce { @Sendable request in
            let token=request.value(forHTTPHeaderField:"Authorization") ?? "",path=request.url?.path ?? ""
            if path == "/copilot_internal/user" {
                #expect(token == "Bearer internal-token")
                return (Data(#"{"copilot_plan":"business","quota_snapshots":{"premium_interactions":{"entitlement":100,"remaining":25,"percent_remaining":25}}}"#.utf8),self.makeHTTPResponse(statusCode:200))
            }
            #expect((token == "Bearer personal-token" && path.contains("/users/personal/")) || (token == "Bearer work-token" && path.contains("/users/work/")))
            let user=token == "Bearer personal-token" ? "personal" : "work"
            return (Data("{\"timePeriod\":{\"year\":2026,\"month\":10},\"user\":\"\(user)\",\"usageItems\":[{\"product\":\"Copilot\",\"grossQuantity\":10}]}".utf8),self.makeHTTPResponse(statusCode:200))
        }
        let definition=try Providers.builtIn("copilot")
        let factory: @MainActor () -> Provider = {
            Provider(definition:definition,settings:settings,accounts:settings.accounts(forProvider:"copilot"),makeDataSource:{source,login in
                DataSources.make(source,providerId:"copilot",cliExecutor:MockCLIExecutor(),network:network,makeTransport:{_,_,_,_ in MockRPCTransport()},scripts:Providers.builtInScripts,secrets:vault.scoped(to:login),settings:settings.scopedValues(forProvider:login),environment:{_ in "personal-token"},homeDirectory:FileManager.default.temporaryDirectory,now:{Date()})
            },vault:vault)
        }
        let provider=factory()
        #expect(provider.defaultAccount.displayName == "Copilot")
        #expect(throws:UsageError.self) {try provider.addAccount(filling:["apiKey":"bad-token","username":"work","monthlyLimit":"invalid"])}
        let work=try provider.addAccount(filling:["apiKey":"work-token","username":"work","monthlyLimit":"200"])
        let internalAccount=try provider.addAccount(filling:["apiKey":"internal-token","source":"copilotAPI"])
        provider.rename(work,to:"Work");provider.rename(internalAccount,to:"Business")
        #expect((try await work.refresh()).quotas[0].percentRemaining == 95)
        #expect((try await internalAccount.refresh()).quotas[0].percentRemaining == 25)
        #expect((try await provider.defaultAccount.refresh()).quotas[0].percentRemaining == 70)
        #expect(settings.value("lastUsagePeriodMonth",forProvider:work.id) == .number(10))
        #expect(settings.value("lastUsagePeriodMonth",forProvider:internalAccount.id) == nil)
        #expect(settings.copilotManualUsageValue() == 30)
        #expect(settings.accounts(forProvider:"copilot").allSatisfy { $0.probeConfig["apiKey"] == nil && $0.probeConfig["username"] == nil })
        let restored=factory(), restoredWork=try #require(restored.accounts.first {$0.id == work.id})
        #expect(restoredWork.displayName == "Work")
        #expect((try await restoredWork.refresh()).quotas[0].percentRemaining == 95)
        _ = vault.delete("apiKey",provider:restoredWork.id)
        await #expect(throws:UsageError.authenticationRequired) { try await restoredWork.refresh() }
        restored.remove(restoredWork)
        #expect(vault.secret("username",provider:work.id) == nil)
        #expect(settings.value("lastUsagePeriodMonth",forProvider:work.id) == nil)
        #expect(vault.secret("apiKey",provider:"copilot") == "personal-token")
    }


    @Test func `definition preserves identity defaults look and live API mode selection`() throws {
        let settings = makeSettingsRepository()
        settings.setEnabled(false, forProvider: "copilot")
        let definition = try Providers.builtIn("copilot")
        let provider = Providers.make(definition, settings: settings)
        let account = provider.defaultAccount
        #expect(account.id == "copilot")
        #expect(account.name == "Copilot")
        #expect(account.cliCommand == "gh")
        #expect(account.dashboardURL?.absoluteString == "https://github.com/settings/copilot/features")
        #expect(account.statusPageURL?.absoluteString == "https://www.githubstatus.com")
        #expect(account.isEnabled == false)
        #expect(account.snapshot == nil)
        #expect(account.lastError == nil)
        #expect(account.isSyncing == false)
        #expect(definition.profile.look.icon == "CopilotIcon")
        #expect(provider.dataSourceKind(for: account) == "billing")
        settings.setCopilotProbeMode(.copilotAPI)
        #expect(provider.dataSourceKind(for: account) == "copilotAPI")
    }
}
