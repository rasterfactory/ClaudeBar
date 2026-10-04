import Foundation
import Quotas
import Testing
@testable import DataSources

/// `usage` — ClaudeBar's own documented output, which an extension's script
/// prints: `quotas[]` (`type`, `percentRemaining`, `resetsAt`, `resetText`,
/// `dollarRemaining`) and `costUsage`. Read exactly as extensions are today.
@Suite
struct UsageMappingTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("usage-mapping-\(UUID().uuidString)", isDirectory: true)

    /// The usage a script printing `output` maps to.
    private func usage(_ output: String) async throws -> UsageSnapshot {
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(output.utf8).write(to: folder.appendingPathComponent("out.json"))
        let script = folder.appendingPathComponent("probe.sh")
        try Data("#!/bin/sh\ncat out.json\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let json = #"{"kind":"quotas","fetch":{"script":{"run":"./probe.sh","folder":"\#(folder.path)"}},"mapping":{"usage":{}}}"#
        let definition = try JSONDecoder().decode(DataSourceDefinition.self, from: Data(json.utf8))
        return try await DataSources.make(definition, providerId: "ext-acme").fetchUsage()
    }

    @Test
    func `each quota's type says its kind`() async throws {
        let usage = try await usage("""
        {"quotas":[{"type":"session","percentRemaining":85,"resetsAt":"2026-03-17T23:00:00Z"},
                   {"type":"weekly","percentRemaining":62},
                   {"type":"model:opus","percentRemaining":40},
                   {"type":"Requests","percentRemaining":12,"resetText":"Resets monthly"}]}
        """)

        #expect(usage.quota(for: .session)?.percentRemaining == 85)
        #expect(usage.quota(for: .session)?.resetsAt == ISO8601DateFormatter().date(from: "2026-03-17T23:00:00Z"))
        #expect(usage.quota(for: .weekly)?.percentRemaining == 62)
        #expect(usage.quota(for: .modelSpecific("opus"))?.percentRemaining == 40)
        #expect(usage.quota(for: .timeLimit("Requests"))?.resetText == "Resets monthly")
    }

    @Test
    func `a quota keeps its conventional window, as extensions always had`() async throws {
        let usage = try await usage(#"{"quotas":[{"type":"session","percentRemaining":85}]}"#)

        #expect(usage.quota(for: .session)?.windowDuration == QuotaType.session.conventionalWindow.seconds)
    }

    @Test
    func `the cost is read as money spent against a budget`() async throws {
        let usage = try await usage(#"{"costUsage":{"totalCost":10.26,"budget":50,"apiDuration":120}}"#)

        #expect(usage.costUsage?.totalCost == Decimal(string: "10.26"))
        #expect(usage.costUsage?.budget == 50)
        #expect(usage.costUsage?.apiDuration == 120)
    }

    @Test
    func `output with neither quotas nor a cost is a mapping failure`() async throws {
        await #expect { try await usage(#"{"metrics":[]}"#) } throws: { ($0 as? DataSourceError)?.step == .mapping }
    }
}
