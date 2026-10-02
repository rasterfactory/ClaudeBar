import Testing
import Foundation
@testable import DataSources
import Quotas
import Mockable

@Suite("FixtureReader Tests")
struct SelectedCredentialRecordTests {

    private struct FixtureReader {
        let home: URL
        init(homeDirectory: String = FileManager.default.temporaryDirectory.path) { home=URL(fileURLWithPath:homeDirectory) }
        private func reader() throws -> JSONFileReader {
            let json = #"{"path":"~/.grok/auth.json","token":"$.key","refreshToken":"$.refresh_token","email":"$.email","expiresAt":"$.expires_at","issuer":"$.oidc_issuer","clientId":"$.oidc_client_id","select":{"records":"$","preferPresent":["refreshToken"],"newest":"expiresAt","missingNewestIsFuture":true,"keyAs":"entryKey"}}"#
            return JSONFileReader(file:try JSONDecoder().decode(JSONFileCredential.self,from:Data(json.utf8)),homeDirectory:home,environment:{_ in nil})
        }
        func loadCredentials() throws -> FoundCredential? {try reader().find()}
        func saveCredentials(_ found: FoundCredential) throws {found.save?(found.credential)}
        func needsRefresh(expiresAt:String?) throws -> Bool {
            let json = #"{"tokenURL":"https://example.test/token","clientId":"fixture","dueWhen":{"unit":"iso8601","skew":300,"missingIsDue":false}}"#
            let refresh=try JSONDecoder().decode(OAuth2Refresh.self,from:Data(json.utf8))
            var values=["token":"token","refreshToken":"refresh"]
            values["expiresAt"]=expiresAt
            return OAuth2Refresher(refresh:refresh,network:MockNetworkClient(),now:{Date()}).isDue(Credential(values))
        }
        static func parseDate(_ text: String?) -> Date? {text.flatMap(OAuth2Refresher.parseDate)}
    }


    // MARK: - Test Helpers

    private func makeTemporaryDirectory() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("grok-credential-loader-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    private func writeAuthFile(at directory: URL, json: [String: Any]) throws {
        let grokDir = directory.appendingPathComponent(".grok", isDirectory: true)
        try FileManager.default.createDirectory(at: grokDir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
        try data.write(to: grokDir.appendingPathComponent("auth.json"))
    }

    private func oidcEntry(
        key: String = "test-access-token",
        refreshToken: String? = "test-refresh-token",
        email: String? = "user@example.com",
        expiresAt: String? = "2099-01-01T00:00:00.000000Z"
    ) -> [String: Any] {
        var entry: [String: Any] = [
            "key": key,
            "auth_mode": "oidc",
            "oidc_issuer": "https://auth.x.ai",
            "oidc_client_id": "client-123"
        ]
        if let refreshToken { entry["refresh_token"] = refreshToken }
        if let email { entry["email"] = email }
        if let expiresAt { entry["expires_at"] = expiresAt }
        return entry
    }

    // MARK: - Loading Tests

    @Test
    func `loads credentials from oidc entry`() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try writeAuthFile(at: tempDir, json: [
            "https://auth.x.ai::client-123": oidcEntry()
        ])

        let loader = FixtureReader(homeDirectory: tempDir.path)
        let credentials = try loader.loadCredentials()

        #expect(credentials != nil)
        #expect(credentials?.credential["token"] == "test-access-token")
        #expect(credentials?.credential["refreshToken"] == "test-refresh-token")
        #expect(credentials?.credential["email"] == "user@example.com")
        #expect(credentials?.credential["issuer"] == "https://auth.x.ai")
        #expect(credentials?.credential["clientId"] == "client-123")
        #expect(credentials?.credential["entryKey"] == "https://auth.x.ai::client-123")
    }

    @Test
    func `returns nil when auth file missing`() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let loader = FixtureReader(homeDirectory: tempDir.path)

        #expect(try loader.loadCredentials() == nil)
    }

    @Test
    func `returns nil when no entry has a token`() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try writeAuthFile(at: tempDir, json: [
            "https://auth.x.ai::client-123": ["key": "", "auth_mode": "oidc"]
        ])

        let loader = FixtureReader(homeDirectory: tempDir.path)

        #expect(try loader.loadCredentials() == nil)
    }

    @Test
    func `prefers refreshable entry over api key entry`() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try writeAuthFile(at: tempDir, json: [
            "https://accounts.x.ai/sign-in": ["key": "legacy-api-key"],
            "https://auth.x.ai::client-123": oidcEntry(key: "oidc-token")
        ])

        let loader = FixtureReader(homeDirectory: tempDir.path)
        let credentials = try loader.loadCredentials()

        #expect(credentials?.credential["token"] == "oidc-token")
    }

    @Test
    func `treats empty refresh token as absent`() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        var entry = oidcEntry()
        entry["refresh_token"] = ""
        try writeAuthFile(at: tempDir, json: [
            "https://auth.x.ai::client-123": entry
        ])

        let loader = FixtureReader(homeDirectory: tempDir.path)
        let credentials = try #require(try loader.loadCredentials())

        #expect(credentials.credential["refreshToken"] == nil)
    }

    // MARK: - Expiry Tests

    @Test
    func `needsRefresh true when token expired`() throws {
        let loader = FixtureReader()

        #expect(try loader.needsRefresh(expiresAt: "2020-01-01T00:00:00.000000Z") == true)
    }

    @Test
    func `needsRefresh false when token valid`() throws {
        let loader = FixtureReader()

        #expect(try loader.needsRefresh(expiresAt: "2099-01-01T00:00:00.000000Z") == false)
    }

    @Test
    func `needsRefresh false when no expiry recorded`() throws {
        let loader = FixtureReader()

        #expect(try loader.needsRefresh(expiresAt: nil) == false)
    }

    // MARK: - Date Parsing Tests

    @Test
    func `parses microsecond fraction timestamps`() {
        let date = FixtureReader.parseDate("2026-07-26T21:03:09.138930Z")

        #expect(date != nil)
    }

    @Test
    func `parses timestamps with utc offset`() {
        let date = FixtureReader.parseDate("2026-07-23T05:09:24.881042+00:00")

        #expect(date != nil)
    }

    @Test
    func `parses timestamps without fraction`() {
        let date = FixtureReader.parseDate("2026-07-23T05:09:24Z")

        #expect(date != nil)
    }

    @Test
    func `returns nil for garbage timestamps`() {
        #expect(FixtureReader.parseDate("not a date") == nil)
        #expect(FixtureReader.parseDate(nil) == nil)
    }

    // MARK: - Save Tests

    @Test
    func `saveCredentials updates token fields and preserves the rest`() throws {
        let tempDir = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try writeAuthFile(at: tempDir, json: [
            "https://auth.x.ai::client-123": oidcEntry()
        ])

        let loader = FixtureReader(homeDirectory: tempDir.path)
        var credentials = try #require(try loader.loadCredentials())

        credentials.credential["token"] = "new-token"
        credentials.credential["refreshToken"] = "new-refresh-token"
        credentials.credential["expiresAt"] = "2099-06-01T00:00:00.000Z"
        try loader.saveCredentials(credentials)

        let reloaded = try #require(try loader.loadCredentials())
        #expect(reloaded.credential["token"] == "new-token")
        #expect(reloaded.credential["refreshToken"] == "new-refresh-token")
        #expect(reloaded.credential["expiresAt"] == "2099-06-01T00:00:00.000Z")
        // Fields the refresh doesn't touch stay intact
        #expect(reloaded.credential["email"] == "user@example.com")
        #expect(reloaded.credential["issuer"] == "https://auth.x.ai")
    }
    @Test func `the newest refreshable record wins and writes keep other records and metadata`() throws {
        let root=try makeTemporaryDirectory()
        defer {try? FileManager.default.removeItem(at:root)}
        var newer=oidcEntry(key:"newer",expiresAt:"2099-06-01T00:00:00Z")
        newer["extra"]=["retained":true]
        let older=oidcEntry(key:"older",expiresAt:"2099-01-01T00:00:00Z")
        try writeAuthFile(at:root,json:["https://tenant.test::newer":newer,"older":older,"api":["key":"api-key"]])
        let reader=FixtureReader(homeDirectory:root.path)
        var selected=try #require(try reader.loadCredentials())
        #expect(selected.credential.token == "newer")
        #expect(selected.credential["entryKey"] == "https://tenant.test::newer")
        selected.credential["token"]="renewed"
        try reader.saveCredentials(selected)
        let data=try Data(contentsOf:root.appendingPathComponent(".grok/auth.json"))
        let saved=try #require(try JSONSerialization.jsonObject(with:data) as? [String:[String:Any]])
        #expect(saved["older"]?["key"] as? String == "older")
        #expect(saved["api"]?["key"] as? String == "api-key")
        #expect(saved["https://tenant.test::newer"]?["key"] as? String == "renewed")
        #expect((saved["https://tenant.test::newer"]?["extra"] as? [String:Bool])?["retained"] == true)
    }
    @Test func `a refreshable record with no expiry retains the previous preference`() throws {
        let root=try makeTemporaryDirectory()
        defer {try? FileManager.default.removeItem(at:root)}
        try writeAuthFile(at:root,json:["dated":oidcEntry(key:"dated"),"no-expiry":oidcEntry(key:"no-expiry",expiresAt:nil)])
        #expect(try FixtureReader(homeDirectory:root.path).loadCredentials()?.credential.token == "no-expiry")
    }

}
