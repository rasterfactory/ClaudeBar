import Foundation
import JavaScriptCore
import Quotas

/// Pure credential selection over explicitly declared inputs. File, vault and
/// login-shell reads stay at this boundary; the script has no host I/O APIs.
struct ScriptCredentialReader: CredentialFinding {
    let definition: ScriptCredentialLookup
    let source: String?
    let inputs: [String: any CredentialFinding]
    let environment: @Sendable (String) -> String?
    let homeDirectory: URL
    let executor: any CLIExecutor

    private struct Result: Decodable {
        let credential: [String: String]?
        let available: Bool?
        let error: ErrorRef?
        let needEnvironment: String?
    }

    private func inspect(resolved: [String: String] = [:]) throws -> Result {
        guard let source else { throw UsageError.parseFailed("Credential script '\(definition.file)' is missing") }
        let keys = try inputs.mapValues { try $0.find()?.credential.values ?? [:] }
        var files: [String: Any] = [:]
        for (name, path) in definition.files {
            let url = URL(fileURLWithPath: Paths.expand(path, homeDirectory: homeDirectory, environment: environment))
            files[name] = (try? String(contentsOf: url, encoding: .utf8)).map { $0 as Any } ?? NSNull()
        }
        var values = definition.environment.compactMapValues { name in
            environment(Paths.expand(name, homeDirectory: homeDirectory, environment: environment))
        }
        values.merge(resolved) { _, latest in latest }
        let payload: [String: Any] = ["credentials": keys, "files": files, "environment": values,
                                    "constants": definition.constants,
                                    "environmentNames": definition.environment.mapValues { Paths.expand($0, homeDirectory: homeDirectory, environment: environment) },
                                    "cli": Dictionary(uniqueKeysWithValues: definition.cli.map { ($0.key, executor.locate($0.value) != nil) })]
        guard let context = JSContext() else { throw UsageError.executionFailed("JavaScriptCore is unavailable") }
        var exception: String?
        context.exceptionHandler = { _, value in exception = value?.toString() }
        let data = try JSONSerialization.data(withJSONObject: payload)
        context.setObject(String(decoding: data, as: UTF8.self), forKeyedSubscript: "__input" as NSString)
        context.evaluateScript(source)
        let output = context.evaluateScript("JSON.stringify(readCredential(JSON.parse(__input)))")
        guard exception == nil, let text = output?.toString(), let bytes = text.data(using: .utf8) else {
            // Do not include script exception text: inputs can contain credentials.
            throw UsageError.parseFailed("Credential script '\(definition.file)' failed")
        }
        do { return try JSONDecoder().decode(Result.self, from: bytes) }
        catch { throw UsageError.parseFailed("Credential script '\(definition.file)' returned an invalid result") }
    }

    func find() throws -> FoundCredential? { try credential(from: inspect()) }
    func isAvailable() async -> Bool {
        guard let result = try? inspect() else { return false }
        return result.available ?? (result.credential?["token"] != nil)
    }
    func findForFetch() async throws -> FoundCredential? {
        var result = try inspect()
        if let requested = result.needEnvironment, let rawName = definition.environment[requested] {
            let name = Paths.expand(rawName, homeDirectory: homeDirectory, environment: environment)
            let value = await LoginShellEnvironment(cliExecutor: executor, timeout: definition.timeout).value(ofEnvVar: name)
            result = try inspect(resolved: value.map { [requested: $0] } ?? [:])
        }
        return try credential(from: result)
    }
    private func credential(from result: Result) throws -> FoundCredential? {
        if let error = result.error { throw error.usageError }
        guard let values = result.credential, let token = values["token"], !Credential.trimmed(token).isEmpty else { return nil }
        return FoundCredential(credential: Credential(values), save: nil)
    }
}
