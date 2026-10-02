import Providers
import DataSources
import Testing
import Foundation
import Mockable
@testable import Infrastructure
@testable import Domain

@Suite("KimiUsageProbe Tests")
struct KimiAPIDefinitionExecutionTests {

    // MARK: - Test Helpers

    /// A mock token provider for testing
    private struct MockTokenProvider {
        let token: String?

        func resolveToken() throws -> String {
            guard let token else {
                throw UsageError.authenticationRequired
            }
            return token
        }
    }

    private func api(networkClient: any NetworkClient, tokenProvider: MockTokenProvider, settingsRepository: (any KimiSettingsRepository)? = nil) -> Fixture {
        let definition = try! Providers.builtIn("kimi")
        let region = settingsRepository?.kimiRegion() ?? .china
        let source = DataSources.make(definition.dataSource("api")!, providerId: "kimi", cliExecutor: MockCLIExecutor(), network: networkClient, makeTransport: { _, _, _, _ in MockRPCTransport() }, scripts: Providers.builtInScripts, settingValue: { _ in region.rawValue }, browserCookies: NoCookies(), environment: { $0 == "KIMI_AUTH_TOKEN" ? tokenProvider.token : nil }, homeDirectory: FileManager.default.temporaryDirectory, now: { Date() })
        return Fixture(source: source, region: region)
    }
    private struct NoCookies: BrowserCookieReading { func stores(domains: [String], names: [String]) -> [[BrowserCookie]] { [] } }
    private struct Fixture {
        let source: DataSource
        let region: KimiRegion
        func isAvailable() async -> Bool { await source.isReady() }
        func probe() async throws -> UsageSnapshot {
            do { return try await source.fetchUsage() }
            catch let error as DataSourceError { throw error.reason }
        }
    }

    private func makeSuccessResponse(json: String) -> (Data, URLResponse) {
        let data = json.data(using: .utf8)!
        let response = HTTPURLResponse(
            url: URL(string: "https://www.kimi.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, response)
    }

    private func makeErrorResponse(statusCode: Int) -> (Data, URLResponse) {
        let data = Data()
        let response = HTTPURLResponse(
            url: URL(string: "https://www.kimi.com")!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, response)
    }

    private static let validResponseJSON = """
    {
        "usages": [{
            "scope": "FEATURE_CODING",
            "detail": {
                "limit": "2048",
                "used": "214",
                "remaining": "1834",
                "resetTime": "2025-06-09T00:00:00Z"
            },
            "limits": [{
                "window": { "duration": 300, "timeUnit": "TIME_UNIT_MINUTE" },
                "detail": {
                    "limit": "200",
                    "used": "139",
                    "remaining": "61",
                    "resetTime": "2025-06-03T15:30:00Z"
                }
            }]
        }]
    }
    """

    // MARK: - isAvailable Tests

    @Test
    func `isAvailable returns true when token is available`() async {
        let mockNetwork = MockNetworkClient()
        let probe = api(
            networkClient: mockNetwork,
            tokenProvider: MockTokenProvider(token: "valid-token")
        )

        #expect(await probe.isAvailable() == true)
    }

    @Test
    func `isAvailable returns false when token is unavailable`() async {
        let mockNetwork = MockNetworkClient()
        let probe = api(
            networkClient: mockNetwork,
            tokenProvider: MockTokenProvider(token: nil)
        )

        #expect(await probe.isAvailable() == false)
    }

    // MARK: - Probe Success Tests

    @Test
    func `probe returns correct UsageSnapshot on success`() async throws {
        let mockNetwork = MockNetworkClient()

        given(mockNetwork).request(.any).willReturn(
            makeSuccessResponse(json: Self.validResponseJSON)
        )

        let probe = api(
            networkClient: mockNetwork,
            tokenProvider: MockTokenProvider(token: "valid-token")
        )

        let snapshot = try await probe.probe()

        #expect(snapshot.providerId == "kimi")
        #expect(snapshot.quotas.count == 2)
        #expect(snapshot.accountTier == .custom("Moderato"))

        // Weekly quota
        let weekly = snapshot.quota(for: .weekly)!
        #expect(weekly.percentRemaining > 89.5)
        #expect(weekly.percentRemaining < 89.6)

        // Session quota
        let session = snapshot.quota(for: .session)!
        #expect(session.percentRemaining == 30.5)
    }

    // MARK: - Probe Error Tests

    @Test
    func `probe throws authenticationRequired when token is unavailable`() async {
        let mockNetwork = MockNetworkClient()
        let probe = api(
            networkClient: mockNetwork,
            tokenProvider: MockTokenProvider(token: nil)
        )

        await #expect(throws: UsageError.authenticationRequired) {
            try await probe.probe()
        }
    }

    @Test
    func `probe throws authenticationRequired on 401`() async {
        let mockNetwork = MockNetworkClient()

        given(mockNetwork).request(.any).willReturn(
            makeErrorResponse(statusCode: 401)
        )

        let probe = api(
            networkClient: mockNetwork,
            tokenProvider: MockTokenProvider(token: "valid-token")
        )

        await #expect(throws: UsageError.authenticationRequired) {
            try await probe.probe()
        }
    }

    @Test
    func `probe throws authenticationRequired on 403`() async {
        let mockNetwork = MockNetworkClient()

        given(mockNetwork).request(.any).willReturn(
            makeErrorResponse(statusCode: 403)
        )

        let probe = api(
            networkClient: mockNetwork,
            tokenProvider: MockTokenProvider(token: "valid-token")
        )

        await #expect(throws: UsageError.authenticationRequired) {
            try await probe.probe()
        }
    }

    @Test
    func `probe throws executionFailed on server error`() async {
        let mockNetwork = MockNetworkClient()

        given(mockNetwork).request(.any).willReturn(
            makeErrorResponse(statusCode: 500)
        )

        let probe = api(
            networkClient: mockNetwork,
            tokenProvider: MockTokenProvider(token: "valid-token")
        )

        await #expect(throws: UsageError.self) {
            try await probe.probe()
        }
    }

    @Test
    func `probe throws parseFailed on malformed response`() async {
        let mockNetwork = MockNetworkClient()

        given(mockNetwork).request(.any).willReturn(
            makeSuccessResponse(json: "{ invalid json }")
        )

        let probe = api(
            networkClient: mockNetwork,
            tokenProvider: MockTokenProvider(token: "valid-token")
        )

        await #expect(throws: UsageError.self) {
            try await probe.probe()
        }
    }

    @Test
    func `probe throws parseFailed when response lacks FEATURE_CODING scope`() async {
        let mockNetwork = MockNetworkClient()
        let json = """
        {
            "usages": [{
                "scope": "FEATURE_CHAT",
                "detail": {
                    "limit": "1000",
                    "used": "100",
                    "remaining": "900",
                    "resetTime": "2025-06-09T00:00:00Z"
                }
            }]
        }
        """

        given(mockNetwork).request(.any).willReturn(
            makeSuccessResponse(json: json)
        )

        let probe = api(
            networkClient: mockNetwork,
            tokenProvider: MockTokenProvider(token: "valid-token")
        )

        await #expect(throws: UsageError.self) {
            try await probe.probe()
        }
    }

    // MARK: - Region Tests

    /// Captures the request the probe sends so tests can assert URL and headers.
    private final class CapturingNetworkClient: NetworkClient, @unchecked Sendable {
        var result: (Data, URLResponse)
        private let lock = NSLock()
        private var storage: URLRequest?

        var capturedRequest: URLRequest? {
            withLock { storage }
        }

        private func withLock<T>(_ body: () -> T) -> T {
            lock.lock(); defer { lock.unlock() }
            return body()
        }

        init(result: (Data, URLResponse)) {
            self.result = result
        }

        func request(_ request: URLRequest) async throws -> (Data, URLResponse) {
            withLock { storage = request }
            return result
        }
    }

    private func makeSettingsRepository(region: KimiRegion) -> UserDefaultsProviderSettingsRepository {
        let defaults = UserDefaults(suiteName: "KimiProbeTests.\(UUID().uuidString)")!
        let repository = UserDefaultsProviderSettingsRepository(userDefaults: defaults)
        repository.setKimiRegion(region)
        return repository
    }

    @Test
    func `region defaults to china when no settings repository`() {
        let probe = api(
            networkClient: MockNetworkClient(),
            tokenProvider: MockTokenProvider(token: "valid-token")
        )

        #expect(probe.region == .china)
    }

    @Test
    func `region follows the settings repository`() {
        let probe = api(
            networkClient: MockNetworkClient(),
            tokenProvider: MockTokenProvider(token: "valid-token"),
            settingsRepository: makeSettingsRepository(region: .international)
        )

        #expect(probe.region == .international)
    }

    @Test
    func `probe hits the kimi.com endpoint for the china region`() async throws {
        let network = CapturingNetworkClient(result: makeSuccessResponse(json: Self.validResponseJSON))
        let probe = api(
            networkClient: network,
            tokenProvider: MockTokenProvider(token: "valid-token"),
            settingsRepository: makeSettingsRepository(region: .china)
        )

        _ = try await probe.probe()

        let request = try #require(network.capturedRequest)
        #expect(request.url?.absoluteString == "https://www.kimi.com/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages")
        #expect(request.value(forHTTPHeaderField: "Origin") == "https://www.kimi.com")
        #expect(request.value(forHTTPHeaderField: "Referer") == "https://www.kimi.com/code/console")
    }

    @Test
    func `probe hits the kimi.ai endpoint for the international region`() async throws {
        let network = CapturingNetworkClient(result: makeSuccessResponse(json: Self.validResponseJSON))
        let probe = api(
            networkClient: network,
            tokenProvider: MockTokenProvider(token: "valid-token"),
            settingsRepository: makeSettingsRepository(region: .international)
        )

        _ = try await probe.probe()

        let request = try #require(network.capturedRequest)
        #expect(request.url?.absoluteString == "https://www.kimi.ai/apiv2/kimi.gateway.billing.v1.BillingService/GetUsages")
        #expect(request.value(forHTTPHeaderField: "Origin") == "https://www.kimi.ai")
        #expect(request.value(forHTTPHeaderField: "Referer") == "https://www.kimi.ai/code/console")
    }
    @Test func `default API requests retain China origin headers body and timezone`() async throws {
        let network = CapturingNetworkClient(result: makeSuccessResponse(json: Self.validResponseJSON))
        _ = try await api(networkClient: network, tokenProvider: MockTokenProvider(token: "valid-token")).probe()
        let request = try #require(network.capturedRequest)
        #expect(request.value(forHTTPHeaderField: "Origin") == "https://www.kimi.com")
        #expect(request.value(forHTTPHeaderField: "Referer") == "https://www.kimi.com/code/console")
        #expect(request.value(forHTTPHeaderField: "Cookie") == "kimi-auth=valid-token")
        #expect(request.value(forHTTPHeaderField: "r-timezone") == TimeZone.current.identifier)
        let body = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: [String]]
        #expect(body?["scope"] == ["FEATURE_CODING"])
    }

}
