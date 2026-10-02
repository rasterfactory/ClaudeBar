import Foundation

struct ChoiceReader: CredentialFinding {
    let choice: CredentialChoice
    let settingValue: @Sendable (String) -> String?
    let makeReader: @Sendable (CredentialLookup) -> any CredentialFinding
    func find() throws -> FoundCredential? {
        let selected = settingValue(choice.setting) ?? choice.default
        guard let lookup = choice.values[selected] ?? choice.values[choice.default] else { return nil }
        return try makeReader(lookup).find()
    }
}
struct TaggedReader: CredentialFinding {
    let base: any CredentialFinding
    let facts: [String: String]
    func find() throws -> FoundCredential? {
        guard let found = try base.find() else { return nil }
        var credential = found.credential
        credential.values.merge(facts) { original, _ in original }
        let writer: (@Sendable (Credential) -> Void)?
        if let write = found.save {
            writer = { new in
                var clean = new
                for name in facts.keys where found.credential.values[name] == nil { clean.values[name] = nil }
                write(clean)
            }
        } else { writer = nil }
        return FoundCredential(credential: credential, save: writer)
    }
}
