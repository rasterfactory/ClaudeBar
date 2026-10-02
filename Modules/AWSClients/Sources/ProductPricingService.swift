import Foundation
import AWSPricing
import AWSSDKIdentity
import DataSources
final class ProductPricingService: @unchecked Sendable {

    /// Cache for model pricing - refreshed daily
    private var cache: [String: UnitPrices] = [:]
    private var cacheDate: Date?
    private let cacheDuration: TimeInterval = 86400 // 24 hours

    /// Lock for thread-safe cache access
    private let lock = NSLock()

    private let query:CloudWatchQuery
    private let profile:String?
    init(query:CloudWatchQuery,profile:String?){self.query=query;self.profile=profile}

    public func getModelPricing(modelId: String) async throws -> UnitPrices {
        // Check cache first
        if let cached = getCachedModel(modelId) {
            return cached
        }

        // Try to fetch from AWS Pricing API
        do {
            let model = try await fetchPricingFromAPI(modelId: modelId)
            cacheModel(model)
            return model
        } catch {

            // Fall back to bundled defaults
            if let defaultModel = query.defaultPrice(modelId) {
                return defaultModel
            }
            // Create unknown model with zero pricing (will show as model with no cost data)
            return UnitPrices(
                id: modelId,
                displayName: extractDisplayName(from: modelId),
                vendor: extractVendor(from: modelId),
                inputPricePer1M: 0,
                outputPricePer1M: 0
            )
        }
    }

    // MARK: - Cache Management

    private func getCachedModel(_ modelId: String) -> UnitPrices? {
        lock.lock()
        defer { lock.unlock() }

        // Check if cache is stale
        if let cacheDate, Date().timeIntervalSince(cacheDate) > cacheDuration {
            cache.removeAll()
            self.cacheDate = nil
            return nil
        }

        return cache[modelId]
    }

    private func cacheModel(_ model: UnitPrices) {
        lock.lock()
        defer { lock.unlock() }

        cache[model.id] = model
        if cacheDate == nil {
            cacheDate = Date()
        }
    }

    // MARK: - AWS Pricing API

    private func fetchPricingFromAPI(modelId: String) async throws -> UnitPrices {
        // AWS Pricing API is only available in us-east-1 and ap-south-1
        let config = try await PricingClient.PricingClientConfiguration(region: "us-east-1")
        if let profile, !profile.isEmpty { config.awsCredentialIdentityResolver=ProfileAWSCredentialIdentityResolver(profileName:profile) }
        let client = PricingClient(config:config)

        // Query for Bedrock pricing
        // The filter format for Bedrock is specific to the service
        let filters = [
            PricingClientTypes.Filter(
                field: "ServiceCode",
                type: .termMatch,
                value: query.serviceCode
            ),
            PricingClientTypes.Filter(
                field: query.productFilter,
                type: .termMatch,
                value: modelId
            )
        ]

        let input = GetProductsInput(
            filters: filters,
            maxResults: 10,
            serviceCode: query.serviceCode
        )

        let output = try await client.getProducts(input: input)

        // Parse pricing from response
        guard let priceList = output.priceList, !priceList.isEmpty else {
            throw PricingError.noPricingFound(modelId)
        }

        // Parse the JSON pricing data
        return try parsePricingResponse(priceList.first!, modelId: modelId)
    }

    private func parsePricingResponse(_ jsonString: String, modelId: String) throws -> UnitPrices {
        guard let data = jsonString.data(using: .utf8) else {
            throw PricingError.invalidResponse
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        // Extract pricing terms
        guard let terms = json?["terms"] as? [String: Any],
              let onDemand = terms["OnDemand"] as? [String: Any] else {
            throw PricingError.invalidResponse
        }

        // Navigate the nested structure to find input/output token prices
        var inputPrice: Decimal = 0
        var outputPrice: Decimal = 0

        for (_, termData) in onDemand {
            guard let term = termData as? [String: Any],
                  let priceDimensions = term["priceDimensions"] as? [String: Any] else {
                continue
            }

            for (_, dimension) in priceDimensions {
                guard let dim = dimension as? [String: Any],
                      let pricePerUnit = dim["pricePerUnit"] as? [String: Any],
                      let usdString = pricePerUnit["USD"] as? String,
                      let description = dim["description"] as? String else {
                    continue
                }

                let rawPrice = Decimal(string: usdString) ?? 0
                let unit = (dim["unit"] as? String)?.lowercased() ?? ""

                // Convert price to per-1M tokens based on unit field
                let pricePer1M: Decimal
                if unit.contains("1m") || unit.contains("million") {
                    // Already per 1M tokens
                    pricePer1M = rawPrice
                } else if unit.contains("1k") || unit.contains("thousand") {
                    // Per 1K tokens - multiply by 1000
                    pricePer1M = rawPrice * 1000
                } else {
                    // Assume per token - multiply by 1M
                    pricePer1M = rawPrice * 1_000_000
                }

                // Determine if this is input or output pricing based on description
                if description.lowercased().contains("input") {
                    inputPrice = pricePer1M
                } else if description.lowercased().contains("output") {
                    outputPrice = pricePer1M
                }
            }
        }

        return UnitPrices(
            id: modelId,
            displayName: extractDisplayName(from: modelId),
            vendor: extractVendor(from: modelId),
            inputPricePer1M: inputPrice,
            outputPricePer1M: outputPrice
        )
    }

    // MARK: - Model Name Extraction

    private func extractDisplayName(from modelId: String) -> String {
        // Check bundled defaults first
        if let model = query.defaultPrice(modelId) {
            return model.displayName
        }

        // Normalize: strip regional prefix (us., eu., etc.) for cross-region inference
        let normalizedId = modelId.replacingOccurrences(
            of: query.normalizePattern,
            with: "",
            options: .regularExpression
        )

        // Parse model ID format: provider.model-name-version:variant
        // e.g., "anthropic.claude-opus-4-5-20251101-v1:0"
        let parts = normalizedId.split(separator: ".")
        guard parts.count >= 2 else { return modelId }

        let modelPart = String(parts[1])
        // Remove version suffix and variant
        let cleanName = modelPart
            .replacingOccurrences(of: "-v\\d+:\\d+$", with: "", options: .regularExpression)
            .replacingOccurrences(of: "-\\d{8}", with: "", options: .regularExpression)
            .replacingOccurrences(of: "-", with: " ")
            .capitalized

        return cleanName
    }

    private func extractVendor(from modelId: String) -> String {
        // Normalize: strip regional prefix (us., eu., etc.) for cross-region inference
        let normalizedId = modelId.replacingOccurrences(
            of: query.normalizePattern,
            with: "",
            options: .regularExpression
        )

        let parts = normalizedId.split(separator: ".")
        guard let vendor = parts.first else { return "Unknown" }

        return query.vendors[vendor.lowercased()] ?? String(vendor).capitalized
    }
}

// MARK: - Pricing Errors

enum PricingError: Error {
    case noPricingFound(String)
    case invalidResponse
}

