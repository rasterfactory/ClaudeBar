import Testing
@testable import Domain

@Suite("Codex menu bar account labels")
struct CodexAccountLabelTests {
    @Test func `menu bar uses a short local part instead of a full address`() {
        #expect(CodexAccountLabel.compact("a@example.com", among: ["a@example.com"]) == "a")
        #expect(CodexAccountLabel.compact("mclaughlin.ryan@gmail.com", among: []) == "mclaugh…")
    }

    @Test func `similar addresses stay short and distinct`() {
        let emails = ["same-long-prefix-one@example.com", "same-long-prefix-two@example.com"]
        let labels = emails.map { CodexAccountLabel.compact($0, among: emails) }
        #expect(Set(labels).count == 2)
        #expect(labels.allSatisfy { $0.count <= 8 && !$0.contains("@") })
    }

    @Test func `accounts sharing an email can still be distinguished`() {
        let labels = CodexAccountLabel.labels(for: ["codex.a": "a@example.com", "codex.b": "a@example.com"])
        #expect(labels["codex.a"] != labels["codex.b"])
        #expect(labels.values.allSatisfy { $0.count <= 8 })
        #expect(CodexAccountLabel.labels(for: ["codex": "a@example.com"]).isEmpty)
    }
}
