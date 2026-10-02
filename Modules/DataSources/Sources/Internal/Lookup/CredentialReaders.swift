import Diagnostics
import Foundation
import SQLite3
import Quotas

/// `environment` — an environment variable holds the token.
struct EnvironmentReader: CredentialFinding {
    let name: String
    let environment: @Sendable (String) -> String?

    func find() throws -> FoundCredential? {
        guard let value = environment(name).map(Credential.trimmed), !value.isEmpty else { return nil }
        return FoundCredential(credential: Credential(["token": value]), save: nil)
    }
}

/// `jsonFile` — a JSON file holds the token and its companions. A refreshed
/// token is written back into the same file, every other field kept and every
/// value keeping its JSON type, because the CLI that owns the file must keep
/// working.
struct JSONFileReader: CredentialFinding {
    let file: JSONFileCredential
    let homeDirectory: URL
    let environment: @Sendable (String) -> String?

    var url: URL {
        URL(fileURLWithPath: Paths.expand(file.path, homeDirectory: homeDirectory, environment: environment))
    }

    func find() throws -> FoundCredential? {
        guard let document = readDocument() else { return nil }
        let selected = selectedRecord(in: document)
        guard let selected else { return nil }
        var values = file.defaults.merging(CredentialDocument.values(file.fields, in: selected.document)) { _, value in value }
        if let keyAs = file.select?.keyAs, let key = selected.key { values[keyAs] = key }
        guard values["token"] != nil else { return nil }
        let reader = self
        let selectedKey = selected.key
        return FoundCredential(credential: Credential(values), save: { reader.write($0, selectedKey: selectedKey) })
    }

    /// The fields without requiring a token — what a context file supplies.
    func fields() -> [String: String] {
        guard let document = readDocument(), let selected = selectedRecord(in: document) else { return [:] }
        return file.defaults.merging(CredentialDocument.values(file.fields, in: selected.document)) { _, value in value }
    }

    func write(_ credential: Credential, selectedKey: String? = nil) {
        guard let document = readDocument() else { return }
        let persisted = Credential(credential.values.filter { file.defaults[$0.key] != $0.value })
        let updated: [String: Any]
        if let selection = file.select, let selectedKey,
           var records = JSONScope(root: document).value(selection.records) as? [String: Any],
           let entry = records[selectedKey] as? [String: Any] {
            records[selectedKey] = CredentialDocument.updated(entry, with: persisted, fields: file.fields)
            updated = selection.records == "$" ? records : JSONPath.set(records, at: selection.records, in: document)
        } else if file.select != nil { return }
        else { updated = CredentialDocument.updated(document, with: persisted, fields: file.fields) }
        do {
            let data = try JSONSerialization.data(withJSONObject: updated, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            AppLog.credentials.info("Saved refreshed credentials to \(file.path)")
        } catch {
            AppLog.credentials.error("Failed to save refreshed credentials to \(file.path): \(error.localizedDescription)")
        }
    }

    private func selectedRecord(in document: [String: Any]) -> (document: [String: Any], key: String?)? {
        guard let selection = file.select else { return (document, nil) }
        guard let records = JSONScope(root: document).value(selection.records) as? [String: Any] else { return nil }
        let candidates = records.compactMap { key, value -> (String, [String: Any], [String: String])? in
            guard let entry = value as? [String: Any] else { return nil }
            guard let tokenPath = file.fields["token"], JSONScope(root: entry).value(tokenPath) is String else { return nil }
            let values = CredentialDocument.values(file.fields, in: entry)
            guard values["token"] != nil else { return nil }
            return (key, entry, values)
        }
        let selected = candidates.max { lhs, rhs in
            for name in selection.preferPresent {
                let left = lhs.2[name] != nil, right = rhs.2[name] != nil
                if left != right { return right }
            }
            guard let newest = selection.newest else { return lhs.0 < rhs.0 }
            let absent = selection.missingNewestIsFuture ? Date.distantFuture : Date.distantPast
            let left = lhs.2[newest].flatMap(OAuth2Refresher.parseDate) ?? absent
            let right = rhs.2[newest].flatMap(OAuth2Refresher.parseDate) ?? absent
            return left == right ? lhs.0 < rhs.0 : left < right
        }
        return selected.map { ($0.1, $0.0) }
    }

    private func readDocument() -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

/// `keychain` — a generic-password item read and written with macOS's
/// `security` tool. A refreshed token is written back as compact JSON: a
/// pretty-printed password comes back hex-encoded from `security -w` (#255).
struct KeychainReader: CredentialFinding {
    /// Runs `/usr/bin/security` with these arguments: exit status and stdout.
    typealias Security = @Sendable (_ arguments: [String]) -> (status: Int32, output: String)

    let item: KeychainCredential
    let security: Security

    func find() throws -> FoundCredential? {
        let (status, output) = security(["find-generic-password", "-s", item.service, "-w"])
        guard status == 0 else {
            AppLog.credentials.error("Keychain read of '\(item.service)' failed: security exited \(status)")
            return nil
        }
        let password = Credential.trimmed(output)
        guard !password.isEmpty else { return nil }

        let values: [String: String]
        if let data = Self.decode(password), let document = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            values = CredentialDocument.values(item.fields, in: document)
        } else if item.fields["token"] == "$" {
            values = ["token": password]
        } else {
            // Shape only — never the payload, which is the token itself.
            AppLog.credentials.error("Keychain item '\(item.service)' did not hold the expected JSON")
            return nil
        }
        guard values["token"] != nil else { return nil }
        let reader = self
        let original = password
        return FoundCredential(credential: Credential(values), save: { reader.write($0, over: original) })
    }

    func write(_ credential: Credential, over password: String) {
        guard let data = Self.decode(password),
              let document = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        let updated = CredentialDocument.updated(document, with: credential, fields: item.fields)
        guard let compact = try? JSONSerialization.data(withJSONObject: updated),
              let payload = String(data: compact, encoding: .utf8) else { return }
        let (status, _) = security(["add-generic-password", "-U", "-s", item.service, "-a", NSUserName(), "-w", payload])
        if status == 0 {
            AppLog.credentials.info("Saved refreshed credentials to Keychain item '\(item.service)'")
        } else {
            AppLog.credentials.error("Failed to save credentials to Keychain item '\(item.service)' (exit \(status))")
        }
    }

    /// `security -w` hex-encodes a password with bytes outside printable ASCII
    /// on macOS 26. JSON never starts with a hex digit, so all-hex is the encoded form.
    static func decode(_ password: String) -> Data? {
        if password.count % 2 == 0, !password.isEmpty {
            var bytes = [UInt8]()
            var index = password.startIndex
            var isHex = true
            while index < password.endIndex {
                let next = password.index(index, offsetBy: 2)
                guard let byte = UInt8(password[index..<next], radix: 16) else { isHex = false; break }
                bytes.append(byte)
                index = next
            }
            if isHex { return Data(bytes) }
        }
        return password.data(using: .utf8)
    }

    /// The real `security` tool, run synchronously with both pipes drained.
    static let system: Security = { arguments in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            _ = errors.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus, String(decoding: data, as: UTF8.self))
        } catch {
            return (-1, "")
        }
    }
}

/// `firstOf` — the lookup order: the first reader that answers wins.
struct FirstOfReader: CredentialFinding {
    let readers: [any CredentialFinding]

    func find() throws -> FoundCredential? {
        for reader in readers {
            if let found = try reader.find() {
                return found
            }
        }
        return nil
    }
}

/// Reading credential values out of a JSON document, and writing refreshed
/// ones back without changing a value's JSON type.
enum CredentialDocument {
    /// `"$.tokens.id_token#jwt.email"` reads a claim out of a JWT's payload —
    /// display metadata only; the token is not verified.
    static func values(_ fields: [String: String], in document: [String: Any]) -> [String: String] {
        let scope = JSONScope(root: document)
        var values: [String: String] = [:]
        for (name, field) in fields {
            let parts = field.components(separatedBy: "#jwt.")
            var value = scope.string(parts[0])
            if parts.count == 2 {
                value = value.flatMap { claim(parts[1], in: $0) }
            }
            if let value = value.map(Credential.trimmed), !value.isEmpty {
                values[name] = value
            }
        }
        return values
    }

    static func claim(_ name: String, in token: String) -> String? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return JSONPath.string(JSONPath.walk(claims, JSONPath.components(name)))
    }

    static func updated(_ document: [String: Any], with credential: Credential, fields: [String: String]) -> [String: Any] {
        var updated = document
        let scope = JSONScope(root: document)
        for (name, path) in fields where path != "$" && !path.contains("#jwt.") {
            guard let value = credential[name] else { continue }
            // A number stays a number: Claude Code reads `expiresAt` as one.
            if scope.value(path) is NSNumber || (scope.value(path) == nil && name == "expiresAt"),
               let number = Double(value) {
                updated = JSONPath.set(NSNumber(value: number), at: path, in: updated)
            } else {
                updated = JSONPath.set(value, at: path, in: updated)
            }
        }
        return updated
    }
}

/// `~/…` and `${VARIABLE:-default}/…` in a file path.
enum Paths {
    static func expand(_ path: String, homeDirectory: URL, environment: @Sendable (String) -> String?) -> String {
        var path = path
        if path.hasPrefix("${"), let close = path.firstIndex(of: "}") {
            let inner = path[path.index(path.startIndex, offsetBy: 2)..<close]
            let parts = inner.components(separatedBy: ":-")
            let value = environment(parts[0]).flatMap { $0.isEmpty ? nil : $0 } ?? (parts.count > 1 ? parts[1] : "")
            path = value + path[path.index(after: close)...]
        }
        if path == "~" { return homeDirectory.path }
        if path.hasPrefix("~/") {
            return homeDirectory.appendingPathComponent(String(path.dropFirst(2))).path
        }
        return path
    }
}

extension Credential {
    /// A value as a person meant it: no surrounding whitespace or newlines.
    static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// `setting` — a key the person gave ClaudeBar, read from its vault.
struct SettingReader: CredentialFinding {
    let name: String
    let providerId: String
    let secrets: (any SecretStore)?

    func find() throws -> FoundCredential? {
        guard let value = secrets?.secret(name, provider: providerId).map(Credential.trimmed), !value.isEmpty else {
            return nil
        }
        return FoundCredential(credential: Credential(["token": value]), save: nil)
    }
}

// Read-only SQL lookup. The query must be a single read-only statement; no
// credential database is created, updated or copied by ClaudeBar.
struct SQLiteReader: CredentialFinding {
    let file: SQLiteCredential
    let homeDirectory: URL
    let environment: @Sendable (String) -> String?

    func find() throws -> FoundCredential? {
        var database: OpaquePointer?
        let path = Paths.expand(file.path, homeDirectory: homeDirectory, environment: environment)
        guard sqlite3_open_v2(path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            throw UsageError.executionFailed("Could not read credential database")
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1000)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, file.query, -1, &statement, nil) == SQLITE_OK else {
            throw UsageError.executionFailed("Could not query credential database")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_stmt_readonly(statement) != 0 else {
            throw UsageError.executionFailed("Credential queries must be read-only")
        }
        let status = sqlite3_step(statement)
        if status == SQLITE_DONE { return nil }
        guard status == SQLITE_ROW else { throw UsageError.executionFailed("Could not query credential database") }
        var document: [String: Any] = [:]
        for index in 0..<sqlite3_column_count(statement) {
            guard sqlite3_column_type(statement, index) != SQLITE_NULL,
                  sqlite3_column_bytes(statement, index) <= 65_536,
                  let name = sqlite3_column_name(statement, index),
                  let value = sqlite3_column_text(statement, index) else { continue }
            document[String(cString: name)] = String(cString: value)
        }
        let values = CredentialDocument.values(file.fields, in: document)
        guard values["token"] != nil else { return nil }
        return FoundCredential(credential: Credential(values), save: nil)
    }
}

// Claims supply request companions, never a verified identity. The receiving
// API authenticates the complete token; secrets stay out of mapper contexts.
struct ClaimsReader: CredentialFinding {
    let base: any CredentialFinding
    let claims: CredentialClaims

    func find() throws -> FoundCredential? {
        guard let found = try base.find(), let token = found.credential.token else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { throw UsageError.parseFailed("Invalid JWT format") }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { throw UsageError.parseFailed("Failed to decode JWT payload") }
        let document = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        var credential = found.credential
        for (name, path) in claims.fields {
            let value = JSONPath.string(JSONPath.walk(document, JSONPath.components(path))).map(Credential.trimmed)
            if let value, !value.isEmpty { credential[name] = value }
            else if claims.required.contains(name) { throw UsageError.parseFailed("JWT payload missing '\(path)' claim") }
        }
        return FoundCredential(credential: credential, save: found.save)
    }
}
