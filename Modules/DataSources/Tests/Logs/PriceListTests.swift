import Foundation
import Testing
@testable import DataSources

/// A price file is data: a model is priced by the first rule that knows it,
/// and money stays exact.
@Suite
struct PriceListTests {
    static let file = """
    {
      "per": 1000000,
      "models": [
        { "id": "m-large-2", "input": "5", "output": "25", "cacheWrite": "6.25", "cacheWrite1h": "10", "cacheRead": "0.50" },
        { "id": "m-medium-2", "input": "3", "output": "15", "cacheWrite": "3.75", "cacheRead": "0.30" },
        { "id": "m-small-1", "input": "1", "output": "5", "cacheWrite": "1.25", "cacheRead": "0.10" }
      ],
      "families": [ { "contains": "large", "as": "m-large-2" }, { "contains": "small", "as": "m-small-1" } ],
      "free": [ "llama", "qwen" ],
      "otherwise": { "input": "3", "output": "15", "cacheWrite": "3.75", "cacheRead": "0.30" }
    }
    """

    private let prices = PriceList.load("prices.json", from: { _ in PriceListTests.file })!

    /// 1M in, 100K out, 1M cache write, 1M cache read.
    private func record(_ model: String) -> LogRecord {
        LogRecord(at: Date(), model: model, input: 1_000_000, output: 100_000, cacheWrite: 1_000_000, cacheRead: 1_000_000)
    }

    @Test func `should price a model listed by its exact name at its own price`() {
        let price = prices.price(for: "m-medium-2")
        #expect([price.input, price.output, price.cacheWrite, price.cacheRead] == [3, 15, Decimal(string: "3.75")!, Decimal(string: "0.30")!])
    }

    @Test func `should price a dated model like the listed model its name starts with`() {
        #expect(prices.price(for: "m-medium-2-20260101").input == 3)
    }

    @Test func `should price an unlisted model by the family its name belongs to`() {
        #expect(prices.price(for: "m-large-99-20260101").input == 5)
    }

    @Test func `should price an unknown model at the fallback price, never at nothing`() {
        #expect(prices.price(for: "acme-unknown").input == 3)
    }

    @Test func `should cost and save nothing for a free model, whatever its size tag`() {
        #expect(prices.cost(of: record("qwen3-coder:30b")) == 0)
        #expect(prices.savings(of: record("llama-3.3-70b")) == 0)
    }

    @Test func `should cost nothing for an unlisted model served on this Mac`() {
        #expect(prices.cost(of: record("acme-internal-7b"), servedLocally: true) == 0)
    }

    @Test func `should keep a listed model's price and savings when served on this Mac`() {
        #expect(prices.cost(of: record("m-medium-2"), servedLocally: true) == Decimal(string: "8.55"))
        #expect(prices.savings(of: record("m-medium-2"), servedLocally: true) == Decimal(string: "2.7"))
    }

    @Test func `should cost every kind of token at its own price, exactly`() {
        let plain = LogRecord(at: Date(), model: "m-medium-2", input: 1_000_000, output: 100_000)
        let cached = LogRecord(at: Date(), model: "m-medium-2", cacheWrite: 1_000_000, cacheRead: 1_000_000)
        #expect(prices.cost(of: plain) == Decimal(string: "4.5"))
        #expect(prices.cost(of: cached) == Decimal(string: "4.05"))
    }

    @Test func `should save what cache reads would have cost as input, less what they cost`() {
        let reads = LogRecord(at: Date(), model: "m-large-2", cacheRead: 2_000_000)
        #expect(prices.savings(of: reads) == 9)
        #expect(prices.savings(of: LogRecord(at: Date(), model: "m-large-2", input: 1_000_000)) == 0)
    }

    @Test func `should price hour-long cache writes at the hour price and the rest at the five-minute price`() {
        let writes = LogRecord(at: Date(), model: "m-large-2", cacheWrite: 1_000_000, cacheWrite1h: 600_000)
        // 0.4M × $6.25 + 0.6M × $10.
        #expect(prices.cost(of: writes) == Decimal(string: "8.5"))
    }

    @Test func `should price every cache write at the five-minute price when the model has no hour price`() {
        let writes = LogRecord(at: Date(), model: "m-medium-2", cacheWrite: 1_000_000, cacheWrite1h: 600_000)
        #expect(prices.cost(of: writes) == Decimal(string: "3.75"))
    }

    @Test func `should have no price list when its file is missing or broken`() {
        #expect(PriceList.load("prices.json", from: { _ in nil }) == nil)
        #expect(PriceList.load("prices.json", from: { _ in "{" }) == nil)
    }
}
