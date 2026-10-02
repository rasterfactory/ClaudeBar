import Foundation
import AWSCloudWatch
import AWSSDKIdentity
import DataSources
final class StatisticsService: @unchecked Sendable {

    private let profileName: String?
    private let query:CloudWatchQuery

    init(profileName: String?, query:CloudWatchQuery) {
        self.query=query
        self.profileName = profileName
    }

    public func fetchMetrics(
        region: String,
        startTime: Date,
        endTime: Date
    ) async throws -> [CloudMetric] {
        // Build CloudWatch client for the specified region
        let client = try await buildClient(region: region)

        // Get list of models by querying for Invocations metric with ModelId dimension
        let modelIds = try await listModels(client: client, startTime: startTime, endTime: endTime)

        // Fetch metrics for each model
        var results: [CloudMetric] = []
        for modelId in modelIds {
            let metrics = try await fetchMetricsForModel(
                client: client,
                modelId: modelId,
                startTime: startTime,
                endTime: endTime
            )
            results.append(metrics)
        }

        return results
    }

    public func verifyCredentials() async -> Bool {
        do {
            // Try to create a client and make a simple call
            let client = try await buildClient(region: "us-east-1")
            // List metrics is a cheap call to verify credentials work
            let input = ListMetricsInput(namespace: query.namespace)
            _ = try await client.listMetrics(input: input)
            return true
        } catch {

            return false
        }
    }

    // MARK: - Private Helpers

    private func buildClient(region: String) async throws -> AWSCloudWatch.CloudWatchClient {
        // Try to create client with SSO-aware credential chain
        do {
            // Create configuration - the SDK's default chain should respect AWS_PROFILE
            let config = try await AWSCloudWatch.CloudWatchClient.CloudWatchClientConfiguration(region: region)

            // Use SSO credential resolver when a profile is specified
            // The SSO resolver reads the profile's SSO configuration and uses cached tokens
            if let profile = profileName, !profile.isEmpty {

                let ssoResolver = ProfileAWSCredentialIdentityResolver(profileName: profile)
                config.awsCredentialIdentityResolver = ssoResolver
            }

            return AWSCloudWatch.CloudWatchClient(config: config)
        } catch {

            throw error
        }
    }

    private func listModels(
        client: AWSCloudWatch.CloudWatchClient,
        startTime: Date,
        endTime: Date
    ) async throws -> [String] {
        // Query CloudWatch for all unique ModelId values
        // Use simple query without filters that might cause InvalidParameterValueException


        let input = ListMetricsInput(
            namespace: query.namespace
        )

        var modelIds: Set<String> = []
        var nextToken: String? = nil

        repeat {
            var paginatedInput = input
            paginatedInput.nextToken = nextToken

            let output = try await client.listMetrics(input: paginatedInput)


            for metric in output.metrics ?? [] {
                if let dimensions = metric.dimensions {
                    for dimension in dimensions {
                        if dimension.name == query.dimension, let value = dimension.value {
                            modelIds.insert(value)
                        }
                    }
                }
            }

            nextToken = output.nextToken
        } while nextToken != nil

        return Array(modelIds)
    }

    private func fetchMetricsForModel(
        client: AWSCloudWatch.CloudWatchClient,
        modelId: String,
        startTime: Date,
        endTime: Date
    ) async throws -> CloudMetric {
        // Calculate period - we want a single data point for the entire range
        // CloudWatch requires period to be a multiple of 60 for periods >= 60 seconds
        let rawPeriod = Int(endTime.timeIntervalSince(startTime))
        let periodSeconds = max(60, ((rawPeriod + 59) / 60) * 60) // Round up to nearest 60

        let modelDimension = AWSCloudWatch.CloudWatchClientTypes.Dimension(name: query.dimension, value: modelId)

        // Fetch metrics sequentially to avoid data race with non-Sendable client
        let inputTokens = try await fetchMetricSum(
            client: client,
            metricName: query.inputMetric,
            dimensions: [modelDimension],
            startTime: startTime,
            endTime: endTime,
            period: periodSeconds
        )

        let outputTokens = try await fetchMetricSum(
            client: client,
            metricName: query.outputMetric,
            dimensions: [modelDimension],
            startTime: startTime,
            endTime: endTime,
            period: periodSeconds
        )

        let invocations = try await fetchMetricSum(
            client: client,
            metricName: query.countMetric,
            dimensions: [modelDimension],
            startTime: startTime,
            endTime: endTime,
            period: periodSeconds
        )

        return CloudMetric(
            modelId: modelId,
            inputTokens: Int(inputTokens),
            outputTokens: Int(outputTokens),
            invocations: Int(invocations)
        )
    }

    private func fetchMetricSum(
        client: AWSCloudWatch.CloudWatchClient,
        metricName: String,
        dimensions: [AWSCloudWatch.CloudWatchClientTypes.Dimension],
        startTime: Date,
        endTime: Date,
        period: Int
    ) async throws -> Double {
        let input = GetMetricStatisticsInput(
            dimensions: dimensions,
            endTime: endTime,
            metricName: metricName,
            namespace: query.namespace,
            period: period,
            startTime: startTime,
            statistics: [.sum]
        )

        let output = try await client.getMetricStatistics(input: input)

        // Sum up all datapoints (should be just one with our period setting)
        let total = output.datapoints?.reduce(0.0) { $0 + ($1.sum ?? 0) } ?? 0
        return total
    }
}
