import Domain
import Foundation

/// Credentials for exactly one added login. Never falls back to the ordinary login.
public struct ScopedCredentialRepository: CredentialRepository {
    private let repository: any CredentialRepository
    private let prefix: String

    public init(providerId: String, accountId: String, repository: any CredentialRepository = KeychainCredentialRepository.shared) {
        self.repository = repository
        // Length framing prevents ids containing punctuation from aliasing another scope.
        self.prefix = "account.\(providerId.utf8.count):\(providerId).\(accountId.utf8.count):\(accountId)."
    }

    public func save(_ value: String, forKey key: String) { repository.save(value, forKey: prefix + key) }
    public func get(forKey key: String) -> String? { repository.get(forKey: prefix + key) }
    @discardableResult public func delete(forKey key: String) -> Bool { repository.delete(forKey: prefix + key) }
    public func exists(forKey key: String) -> Bool { repository.exists(forKey: prefix + key) }
}
