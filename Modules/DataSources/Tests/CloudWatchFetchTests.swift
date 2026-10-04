import Foundation
import Mockable
import Quotas
import Testing
@testable import DataSources

/// Today's cloud metrics, summed per dimension value in each region and
/// priced from the cloud's own list.
@Suite
struct CloudWatchFetchTests {
    private let call = CloudWatchCall(namespace: "Acme/Models", dimension: "ModelId", metrics: ["In", "Out"],
                                      regions: "east-1, west-2", profile: "work", prices: "AcmeModels")
    private let noon = Date(timeIntervalSince1970: 1_767_268_800) // a fixed moment

    final class Seen: @unchecked Sendable { var calls: [(String, String?, Date, Date)] = [] }

    private func fetch(_ call: CloudWatchCall, failing: Set<String> = [], seen: Seen = Seen()) async throws -> [String: Any] {
        let client = MockCloudWatchClient()
        given(client).sums(namespace: .any, dimension: .any, metrics: .any, region: .any, profile: .any, from: .any, to: .any)
            .willProduce { _, _, _, region, profile, from, to in
                seen.calls.append((region, profile, from, to))
                if failing.contains(region) { throw UsageError.executionFailed("denied in \(region)") }
                return ["acme.small": ["In": 1000, "Out": 50]]
            }
        let catalog = MockPriceCatalog()
        given(catalog).prices(service: .any, ids: .any).willReturn(["acme.small": ["in": "3", "out": "15", "per": "1000000"]])
        let response = try await CloudWatchFetcher(call: call, client: client, catalog: catalog, now: { noon }).fetch(with: nil)
        return try #require(try JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    }

    @Test func `should cancel the refresh instead of reporting partial spend when a region is cancelled`() async throws {
        let client = MockCloudWatchClient()
        given(client).sums(namespace: .any, dimension: .any, metrics: .any, region: .any, profile: .any, from: .any, to: .any)
            .willProduce { _, _, _, region, _, _, _ in
                if region == "west-2" { throw CancellationError() }
                return ["model": ["In": 100]]
            }
        await #expect(throws: CancellationError.self) {
            try await CloudWatchFetcher(call: call, client: client, catalog: nil, now: { noon }).fetch(with: nil)
        }
    }

    @Test func `should total today's usage per region under the chosen profile, priced from the cloud's own list`() async throws {
        let seen = Seen()
        let body = try await fetch(call, seen: seen)
        let rows = try #require(body["rows"] as? [[String: Any]])
        #expect(rows.map { $0["region"] as? String } == ["east-1", "west-2"])
        #expect(rows.first?["In"] as? Double == 1000)
        #expect((body["prices"] as? [String: [String: String]])?["acme.small"]?["out"] == "15")
        #expect(seen.calls.map(\.1) == ["work", "work"])
        #expect(seen.calls.first?.2 == Calendar.current.startOfDay(for: noon))
        #expect(seen.calls.first?.3 == noon)
    }

    @Test func `should leave out a region the cloud refuses and show the others`() async throws {
        let rows = try #require(try await fetch(call, failing: ["west-2"])["rows"] as? [[String: Any]])
        #expect(rows.map { $0["region"] as? String } == ["east-1"])
    }

    @Test func `should fail with the cloud's reason when every region refuses`() async throws {
        await #expect(throws: UsageError.executionFailed("denied in east-1")) {
            try await fetch(call, failing: ["east-1", "west-2"])
        }
    }

    @Test func `should use the default credentials when no profile is set, and not be ready when no region is set`() async throws {
        let seen = Seen()
        _ = try await fetch(CloudWatchCall(namespace: "N", dimension: "D", metrics: ["M"], regions: "east-1", profile: "{{setting.profile}}"), seen: seen)
        #expect(seen.calls.first?.1 == nil)
        let blank = CloudWatchFetcher(call: CloudWatchCall(namespace: "N", dimension: "D", metrics: ["M"], regions: "{{setting.regions}}"),
                                      client: MockCloudWatchClient(), catalog: nil, now: { Date() })
        #expect(!blank.isReady())
    }

    @Test func `should keep a cloud-metrics fetch when the definition is written out and read back`() throws {
        let fetch = Fetch.cloudWatch(call)
        #expect(try JSONDecoder().decode(Fetch.self, from: JSONEncoder().encode(fetch)) == fetch)
    }
}
