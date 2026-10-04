import DataSources
import Foundation
import Testing

/// A field that identifies a login — the credential's account id, or the email
/// a context file holds — written as the mapping writes paths, and decoded
/// once into what it points at.
@Suite
struct IdentityFieldTests {
    private func identity(_ field: String) throws -> Identity {
        try JSONDecoder().decode(Identity.self, from: Data(#"{"field":"\#(field)","equals":"x"}"#.utf8))
    }

    @Test
    func `should identify a login by the key's value when the definition gives a bare name`() throws {
        #expect(try identity("account").field == .credential("account"))
    }

    @Test
    func `should identify a login by the key's value when the definition points into the key`() throws {
        #expect(try identity("$credential.account").field == .credential("account"))
    }

    @Test
    func `should identify a login by a field of a context file when the definition points there`() throws {
        #expect(try identity("$context.account.email").field == .context(file: "account", field: "email"))
    }

    @Test
    func `should reject a definition that points to a context file but no field in it`() {
        #expect(throws: DecodingError.self) { try identity("$context.account") }
    }

    @Test
    func `should write a login's identifying field back as it was written`() throws {
        for field in ["account", "$context.account.email"] {
            let encoded = try JSONEncoder().encode(try identity(field))
            #expect(try JSONDecoder().decode(Identity.self, from: encoded) == identity(field))
            #expect(String(decoding: encoded, as: UTF8.self).contains(field))
        }
    }
}
