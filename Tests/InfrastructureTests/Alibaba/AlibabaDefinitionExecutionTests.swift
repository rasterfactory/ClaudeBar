import Providers
import DataSources
import Testing
import Foundation
import Mockable
@testable import Infrastructure
@testable import Domain

@Suite
struct AlibabaDefinitionExecutionTests {

    private func api(settingsRepository: any AlibabaSettingsRepository, networkClient: any NetworkClient = MockNetworkClient(), cookieProvider: Cookies) -> Fixture {
        let definition = try! Providers.builtIn("alibaba")
        let source = DataSources.make(definition.dataSource("api")!, providerId:"alibaba", cliExecutor:MockCLIExecutor(),network:networkClient,makeTransport:{_,_,_,_ in MockRPCTransport()},scripts:Providers.builtInScripts,settingValue:{ name in name == "region" ? settingsRepository.alibabaRegion().rawValue : name == "cookieSource" ? settingsRepository.alibabaCookieSource().rawValue : nil },browserCookies:CookieAdapter(provider:cookieProvider),secrets:SettingsKeys(repository:settingsRepository),environment:{_ in nil},homeDirectory:FileManager.default.temporaryDirectory,now:{Date()})
        return Fixture(source:source)
    }
    private struct Fixture {
        let source: DataSource
        func isAvailable() async -> Bool { await source.isReady() }
        func probe() async throws -> UsageSnapshot {
            do { return try await source.fetchUsage() }
            catch let error as DataSourceError { throw error.reason }
        }
    }
    private struct SettingsKeys: SecretStore {
        let repository: any AlibabaSettingsRepository
        func secret(_ name:String,provider:String) -> String? { name == "apiKey" ? repository.getAlibabaApiKey() : name == "cookie" ? repository.getAlibabaManualCookie() : nil }
    }
    private struct Cookies: Sendable { let text: String? }
    private struct CookieAdapter: BrowserCookieReading {
        let provider: Cookies
        func stores(domains: [String], names: [String]) -> [[BrowserCookie]] { stores(domains: domains, names: names, includeEmpty: false) }
        func stores(domains:[String], names:[String], includeEmpty:Bool) -> [[BrowserCookie]] {
            guard let text = provider.text else { return [] }
            return [text.split(separator:";").compactMap { pair in
                let parts = pair.trimmingCharacters(in:.whitespaces).split(separator:"=",maxSplits:1,omittingEmptySubsequences:false)
                guard parts.count == 2 else { return nil }
                return BrowserCookie(name:String(parts[0]),value:String(parts[1]))
            }]
        }
    }

    // MARK: - Sample Response

    static let sampleSuccessResponse = """
    {
      "code": "200",
      "data": {
        "codingPlanInstanceInfos": [
          {
            "planName": "Test Plan",
            "status": "VALID",
            "codingPlanQuotaInfo": {
              "per5HourUsedQuota": 10,
              "per5HourTotalQuota": 100,
              "perWeekUsedQuota": 50,
              "perWeekTotalQuota": 500,
              "perBillMonthUsedQuota": 100,
              "perBillMonthTotalQuota": 2000
            }
          }
        ]
      },
      "success": true
    }
    """

    private func makeSettingsRepository() -> UserDefaultsProviderSettingsRepository {
        let suiteName = "com.claudebar.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let repo = UserDefaultsProviderSettingsRepository(userDefaults: defaults)
        repo.setEnabled(true, forProvider: "alibaba")
        return repo
    }

    /// Cookie provider that returns no cookies (browser has nothing).
    private func makeBrowserWithNoCookies() -> Cookies {
        Cookies(text:nil)
    }

    /// Cookie provider that returns cookies (browser is logged in).
    private func makeBrowserWithCookies(_ cookie: String = "login_aliyunid_ticket=abc; sec_token=browser_sec_token") -> Cookies {
        Cookies(text:cookie)
    }

    private func mockSuccessResponse() -> (Data, URLResponse) {
        let data = Data(Self.sampleSuccessResponse.utf8)
        let response = HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, response)
    }

    // MARK: - isAvailable

    @Test
    func `isAvailable returns false when manual cookie source and no cookie set`() async {
        let repo = makeSettingsRepository()
        repo.setAlibabaCookieSource(.manual)

        let probe = api(settingsRepository: repo, cookieProvider: makeBrowserWithNoCookies())

        let available = await probe.isAvailable()
        #expect(available == false)
    }

    @Test
    func `isAvailable returns true when API key is set`() async {
        let repo = makeSettingsRepository()
        repo.saveAlibabaApiKey("sk-test-key-123")

        // API key takes priority — cookie provider should not matter
        let probe = api(settingsRepository: repo, cookieProvider: makeBrowserWithNoCookies())

        let available = await probe.isAvailable()
        #expect(available == true)
    }

    @Test
    func `isAvailable returns true when manual cookie is set`() async {
        let repo = makeSettingsRepository()
        repo.setAlibabaCookieSource(.manual)
        repo.saveAlibabaManualCookie("login_aliyunid_ticket=abc123")

        let probe = api(settingsRepository: repo, cookieProvider: makeBrowserWithNoCookies())

        let available = await probe.isAvailable()
        #expect(available == true)
    }

    @Test
    func `isAvailable returns true when auto cookie source and browser has cookies`() async {
        let repo = makeSettingsRepository()
        repo.setAlibabaCookieSource(.auto)

        let probe = api(settingsRepository: repo, cookieProvider: makeBrowserWithCookies())

        let available = await probe.isAvailable()
        #expect(available == true)
    }

    @Test
    func `isAvailable returns false when auto cookie source and browser has no cookies`() async {
        let repo = makeSettingsRepository()
        repo.setAlibabaCookieSource(.auto)

        let probe = api(settingsRepository: repo, cookieProvider: makeBrowserWithNoCookies())

        let available = await probe.isAvailable()
        #expect(available == false)
    }

    @Test
    func `isAvailable returns false when API key is empty string`() async {
        let repo = makeSettingsRepository()
        repo.setAlibabaCookieSource(.manual)
        repo.saveAlibabaApiKey("")

        let probe = api(settingsRepository: repo, cookieProvider: makeBrowserWithNoCookies())

        let available = await probe.isAvailable()
        #expect(available == false)
    }

    // MARK: - probe() with API key

    @Test
    func `probe with API key returns snapshot on success`() async throws {
        let repo = makeSettingsRepository()
        repo.saveAlibabaApiKey("sk-test-key")
        repo.setAlibabaRegion(.international)

        let mockNetwork = MockNetworkClient()
        given(mockNetwork).request(.any).willReturn(mockSuccessResponse())

        // API key path — cookie provider not used
        let probe = api(settingsRepository: repo, networkClient: mockNetwork, cookieProvider: makeBrowserWithNoCookies())

        let snapshot = try await probe.probe()
        #expect(snapshot.providerId == "alibaba")
        #expect(snapshot.quotas.count == 3)
        #expect(snapshot.quota(for: .session)?.percentRemaining == 90.0)
    }

    @Test
    func `probe with API key throws authenticationRequired on 401`() async throws {
        let repo = makeSettingsRepository()
        repo.saveAlibabaApiKey("sk-bad-key")

        let mockNetwork = MockNetworkClient()
        let response = HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 401, httpVersion: nil, headerFields: nil)!
        given(mockNetwork).request(.any).willReturn((Data(), response))

        let probe = api(settingsRepository: repo, networkClient: mockNetwork, cookieProvider: makeBrowserWithNoCookies())

        do {
            _ = try await probe.probe()
            Issue.record("Expected authenticationRequired error")
        } catch {
            #expect(error as? UsageError == .authenticationRequired)
        }
    }

    @Test
    func `probe with API key throws authenticationRequired on 403`() async throws {
        let repo = makeSettingsRepository()
        repo.saveAlibabaApiKey("sk-forbidden")

        let mockNetwork = MockNetworkClient()
        let response = HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 403, httpVersion: nil, headerFields: nil)!
        given(mockNetwork).request(.any).willReturn((Data(), response))

        let probe = api(settingsRepository: repo, networkClient: mockNetwork, cookieProvider: makeBrowserWithNoCookies())

        do {
            _ = try await probe.probe()
            Issue.record("Expected authenticationRequired error")
        } catch {
            #expect(error as? UsageError == .authenticationRequired)
        }
    }

    @Test
    func `probe with API key throws executionFailed on 500`() async throws {
        let repo = makeSettingsRepository()
        repo.saveAlibabaApiKey("sk-test")

        let mockNetwork = MockNetworkClient()
        let response = HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 500, httpVersion: nil, headerFields: nil)!
        given(mockNetwork).request(.any).willReturn((Data(), response))

        let probe = api(settingsRepository: repo, networkClient: mockNetwork, cookieProvider: makeBrowserWithNoCookies())

        do {
            _ = try await probe.probe()
            Issue.record("Expected UsageError")
        } catch {
            #expect(error is UsageError)
        }
    }

    @Test
    func `probe uses china region when configured`() async throws {
        let repo = makeSettingsRepository()
        repo.saveAlibabaApiKey("sk-cn-key")
        repo.setAlibabaRegion(.chinaMainland)

        let mockNetwork = MockNetworkClient()
        given(mockNetwork).request(.any).willReturn(mockSuccessResponse())

        let probe = api(settingsRepository: repo, networkClient: mockNetwork, cookieProvider: makeBrowserWithNoCookies())

        let snapshot = try await probe.probe()
        #expect(snapshot.quotas.count == 3)
    }

    // MARK: - probe() with manual cookie

    @Test
    func `probe with manual cookie and sec_token in cookie succeeds`() async throws {
        let repo = makeSettingsRepository()
        repo.setAlibabaCookieSource(.manual)
        repo.saveAlibabaManualCookie("login_aliyunid_ticket=abc; sec_token=my_sec_token; login_aliyunid_csrf=csrf123")

        let mockNetwork = MockNetworkClient()
        given(mockNetwork).request(.any).willReturn(mockSuccessResponse())

        // Manual cookie path — cookie provider not used
        let probe = api(settingsRepository: repo, networkClient: mockNetwork, cookieProvider: makeBrowserWithNoCookies())

        let snapshot = try await probe.probe()
        #expect(snapshot.providerId == "alibaba")
        #expect(snapshot.quotas.count == 3)
    }

    @Test
    func `probe with cookie throws sessionExpired on 403`() async throws {
        let repo = makeSettingsRepository()
        repo.setAlibabaCookieSource(.manual)
        repo.saveAlibabaManualCookie("login_aliyunid_ticket=abc; sec_token=old_token")

        let mockNetwork = MockNetworkClient()
        let response = HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 403, httpVersion: nil, headerFields: nil)!
        given(mockNetwork).request(.any).willReturn((Data(), response))

        let probe = api(settingsRepository: repo, networkClient: mockNetwork, cookieProvider: makeBrowserWithNoCookies())

        do {
            _ = try await probe.probe()
            Issue.record("Expected sessionExpired error")
        } catch {
            #expect(error as? UsageError == .sessionExpired())
        }
    }

    @Test
    func `probe with empty manual cookie throws authenticationRequired`() async throws {
        let repo = makeSettingsRepository()
        repo.setAlibabaCookieSource(.manual)
        // No cookie saved — empty

        let probe = api(settingsRepository: repo, cookieProvider: makeBrowserWithNoCookies())

        do {
            _ = try await probe.probe()
            Issue.record("Expected authenticationRequired error")
        } catch {
            #expect(error as? UsageError == .authenticationRequired)
        }
    }

    // MARK: - probe() with auto cookie

    @Test
    func `probe with auto cookie uses browser cookies on success`() async throws {
        let repo = makeSettingsRepository()
        repo.setAlibabaCookieSource(.auto)

        let mockNetwork = MockNetworkClient()
        given(mockNetwork).request(.any).willReturn(mockSuccessResponse())

        let probe = api(settingsRepository: repo, networkClient: mockNetwork, cookieProvider: makeBrowserWithCookies())

        let snapshot = try await probe.probe()
        #expect(snapshot.providerId == "alibaba")
        #expect(snapshot.quotas.count == 3)
    }

    @Test
    func `probe with auto cookie throws authenticationRequired when browser has no cookies`() async throws {
        let repo = makeSettingsRepository()
        repo.setAlibabaCookieSource(.auto)

        let probe = api(settingsRepository: repo, cookieProvider: makeBrowserWithNoCookies())

        do {
            _ = try await probe.probe()
            Issue.record("Expected authenticationRequired error")
        } catch {
            #expect(error as? UsageError == .authenticationRequired)
        }
    }

    @Test
    func `probe with auto cookie throws authenticationRequired when browser returns empty string`() async throws {
        let repo = makeSettingsRepository()
        repo.setAlibabaCookieSource(.auto)

        let mockCookieProvider = Cookies(text:"")

        let probe = api(settingsRepository: repo, cookieProvider: mockCookieProvider)

        do {
            _ = try await probe.probe()
            Issue.record("Expected authenticationRequired error")
        } catch {
            #expect(error as? UsageError == .authenticationRequired)
        }
    }

    @Test
    func `probe prefers API key over auto browser cookie`() async throws {
        let repo = makeSettingsRepository()
        repo.setAlibabaCookieSource(.auto)
        repo.saveAlibabaApiKey("sk-test-key")

        let mockNetwork = MockNetworkClient()
        given(mockNetwork).request(.any).willReturn(mockSuccessResponse())

        // Both API key and browser cookies available — API key wins
        let probe = api(settingsRepository: repo, networkClient: mockNetwork, cookieProvider: makeBrowserWithCookies())

        let snapshot = try await probe.probe()
        #expect(snapshot.providerId == "alibaba")
    }

    // MARK: - URL Construction

    @Test
    func `apiQuotaURL uses international gateway for intl region`() {
        let url = AlibabaDefinitionFixtures.apiQuotaURL(for: .international)
        #expect(url.absoluteString.contains("modelstudio.console.alibabacloud.com"))
        #expect(url.absoluteString.contains("api.json"))
    }

    @Test
    func `apiQuotaURL uses china gateway for cn region`() {
        let url = AlibabaDefinitionFixtures.apiQuotaURL(for: .chinaMainland)
        #expect(url.absoluteString.contains("bailian.console.aliyun.com"))
    }

    @Test
    func `consoleRPCURL uses singapore host for intl region`() {
        let url = AlibabaDefinitionFixtures.consoleRPCURL(for: .international)
        #expect(url.absoluteString.contains("bailian-singapore-cs"))
    }

    @Test
    func `consoleRPCURL uses beijing host for cn region`() {
        let url = AlibabaDefinitionFixtures.consoleRPCURL(for: .chinaMainland)
        #expect(url.absoluteString.contains("bailian-beijing-cs"))
    }

    @Test
    func `apiRequestBody contains commodity code`() async throws {
        let body = await AlibabaDefinitionFixtures.apiRequestBody(for: .international)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let request = json?["queryCodingPlanInstanceInfoRequest"] as? [String: Any]
        #expect(request?["commodityCode"] as? String == "sfm_codingplan_public_intl")
    }

    @Test
    func `apiRequestBody contains china commodity code for cn region`() async throws {
        let body = await AlibabaDefinitionFixtures.apiRequestBody(for: .chinaMainland)
        let json = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        let request = json?["queryCodingPlanInstanceInfoRequest"] as? [String: Any]
        #expect(request?["commodityCode"] as? String == "sfm_codingplan_public_cn")
    }

    @Test
    func `consoleRequestBody contains sec_token and region`() async {
        let body = await AlibabaDefinitionFixtures.consoleRequestBody(for: .chinaMainland, secToken: "test_token")
        let bodyString = String(data: body, encoding: .utf8) ?? ""
        #expect(bodyString.contains("sec_token=test_token"))
        #expect(bodyString.contains("region=cn-beijing"))
    }

    // MARK: - Cookie Helpers

    @Test
    func `extractCookieValue finds named cookie`() async {
        let cookie = "a=1; sec_token=abc123; b=2"
        let value = await AlibabaDefinitionFixtures.extractCookieValue(name: "sec_token", from: cookie)
        #expect(value == "abc123")
    }

    @Test
    func `extractCookieValue returns nil for missing cookie`() async {
        let cookie = "a=1; b=2"
        let value = await AlibabaDefinitionFixtures.extractCookieValue(name: "missing", from: cookie)
        #expect(value == nil)
    }

    @Test
    func `extractCookieValue handles cookie with equals in value`() async {
        let cookie = "sec_token=abc=def=ghi; other=1"
        let value = await AlibabaDefinitionFixtures.extractCookieValue(name: "sec_token", from: cookie)
        #expect(value == "abc=def=ghi")
    }

    // MARK: - SEC Token Extraction from HTML

    @Test
    func `extractSecTokenFromHTML finds JSON style token`() async {
        let html = #"<script>var config = {"sec_token":"my_token_123","other":"value"};</script>"#
        let token = await AlibabaDefinitionFixtures.extractSecTokenFromHTML(html)
        #expect(token == "my_token_123")
    }

    @Test
    func `extractSecTokenFromHTML finds single-quote assignment`() async {
        let html = "<script>sec_token = 'token_456';</script>"
        let token = await AlibabaDefinitionFixtures.extractSecTokenFromHTML(html)
        #expect(token == "token_456")
    }

    @Test
    func `extractSecTokenFromHTML finds double-quote assignment`() async {
        let html = #"<script>sec_token = "token_789";</script>"#
        let token = await AlibabaDefinitionFixtures.extractSecTokenFromHTML(html)
        #expect(token == "token_789")
    }

    @Test
    func `extractSecTokenFromHTML returns nil when not found`() async {
        let html = "<html><body>No token here</body></html>"
        let token = await AlibabaDefinitionFixtures.extractSecTokenFromHTML(html)
        #expect(token == nil)
    }

    // MARK: - AlibabaRegion Properties

    @Test
    func `international region has correct properties`() {
        let region = AlibabaDefinitionFixtures.region(.international)
        #expect(region.displayName == "International")
        #expect(region.gatewayBaseURLString == "https://modelstudio.console.alibabacloud.com")
        #expect(region.currentRegionID == "ap-southeast-1")
        #expect(region.commodityCode == "sfm_codingplan_public_intl")
        #expect(region.consoleRPCAction == "IntlBroadScopeAspnGateway")
    }

    @Test
    func `china region has correct properties`() {
        let region = AlibabaDefinitionFixtures.region(.chinaMainland)
        #expect(region.displayName == "China Mainland")
        #expect(region.gatewayBaseURLString == "https://bailian.console.aliyun.com")
        #expect(region.currentRegionID == "cn-beijing")
        #expect(region.commodityCode == "sfm_codingplan_public_cn")
        #expect(region.consoleRPCAction == "BroadScopeAspnGateway")
    }

    @Test
    func `region dashboardURL is valid`() {
        #expect(AlibabaDefinitionFixtures.region(.international).dashboardURL.absoluteString.contains("alibabacloud.com"))
        #expect(AlibabaDefinitionFixtures.region(.chinaMainland).dashboardURL.absoluteString.contains("aliyun.com"))
    }

    @Test
    func `region consoleRPCBaseURLString is correct`() {
        #expect(AlibabaDefinitionFixtures.region(.international).consoleRPCBaseURLString.contains("singapore"))
        #expect(AlibabaDefinitionFixtures.region(.chinaMainland).consoleRPCBaseURLString.contains("beijing"))
    }

    // MARK: - AlibabaCookieSource

    @Test
    func `cookie source display names are set`() {
        #expect(AlibabaCookieSource.auto.displayName == "Auto (from browser)")
        #expect(AlibabaCookieSource.manual.displayName == "Manual")
    }
}
