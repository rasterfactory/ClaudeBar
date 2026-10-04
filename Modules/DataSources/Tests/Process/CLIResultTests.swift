import Testing
import Foundation
@testable import DataSources

@Suite
struct CLIResultTests {

    // MARK: - Initialization Tests

    @Test
    func `should keep what the CLI printed and its exit code`() {
        // Given
        let output = "Hello, World!"
        let exitCode: Int32 = 0

        // When
        let result = CLIResult(output: output, exitCode: exitCode)

        // Then
        #expect(result.output == "Hello, World!")
        #expect(result.exitCode == 0)
    }

    @Test
    func `should take the CLI as having succeeded when no exit code is given`() {
        // Given
        let output = "Success output"

        // When
        let result = CLIResult(output: output)

        // Then
        #expect(result.output == "Success output")
        #expect(result.exitCode == 0)
    }

    @Test
    func `should keep the error the CLI printed and its failing exit code`() {
        // Given
        let output = "Error: command failed"
        let exitCode: Int32 = 1

        // When
        let result = CLIResult(output: output, exitCode: exitCode)

        // Then
        #expect(result.output == "Error: command failed")
        #expect(result.exitCode == 1)
    }

    @Test
    func `should keep an empty answer when the CLI prints nothing`() {
        // Given & When
        let result = CLIResult(output: "", exitCode: 0)

        // Then
        #expect(result.output.isEmpty)
        #expect(result.exitCode == 0)
    }

    @Test
    func `should keep every line the CLI printed`() {
        // Given
        let output = """
        Line 1
        Line 2
        Line 3
        """

        // When
        let result = CLIResult(output: output)

        // Then
        #expect(result.output.contains("Line 1"))
        #expect(result.output.contains("Line 2"))
        #expect(result.output.contains("Line 3"))
    }

    // MARK: - Equatable Tests

    @Test
    func `should treat two runs with the same output and exit code as the same`() {
        // Given
        let result1 = CLIResult(output: "test", exitCode: 0)
        let result2 = CLIResult(output: "test", exitCode: 0)

        // Then
        #expect(result1 == result2)
    }

    @Test
    func `should tell apart two runs that printed different output`() {
        // Given
        let result1 = CLIResult(output: "test1", exitCode: 0)
        let result2 = CLIResult(output: "test2", exitCode: 0)

        // Then
        #expect(result1 != result2)
    }

    @Test
    func `should tell apart two runs that exited differently`() {
        // Given
        let result1 = CLIResult(output: "test", exitCode: 0)
        let result2 = CLIResult(output: "test", exitCode: 1)

        // Then
        #expect(result1 != result2)
    }
}
