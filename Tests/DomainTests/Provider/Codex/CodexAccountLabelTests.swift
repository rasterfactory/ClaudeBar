import Testing
@testable import Domain

@Suite("Codex menu bar account labels")
struct AccountMenuBarLabelTests {
    @Test func `menu bar uses a short local part instead of a full address`() {
        #expect(AccountMenuBarLabel.compact("a@example.com", among: ["a@example.com"]) == "a")
        #expect(AccountMenuBarLabel.compact("mclaughlin.ryan@gmail.com", among: []) == "mclaugh…")
    }

    @Test func `similar addresses stay short and distinct`() {
        let emails = ["same-long-prefix-one@example.com", "same-long-prefix-two@example.com"]
        let labels = emails.map { AccountMenuBarLabel.compact($0, among: emails) }
        #expect(Set(labels).count == 2)
        #expect(labels.allSatisfy { $0.count <= 8 && !$0.contains("@") })
    }

    @Test func `optional names distinguish similar emails and remain bounded`() {
        let emails = ["provider.a": "same@example.com", "provider.b": "same@other.com"]
        let labels = AccountMenuBarLabel.labels(for: emails, customNames: ["provider.a": "Personal", "provider.b": "Work"])
        #expect(labels == ["provider.a": "Personal", "provider.b": "Work"])
        let long = AccountMenuBarLabel.labels(for: emails, customNames: ["provider.a": "A very long name for work", "provider.b": "A very long name for personal"])
        #expect(long.values.allSatisfy { $0.count <= 12 })
        #expect(Set(long.values).count == 2)
        #expect(AccountMenuBarLabel.labels(for: ["provider.a": "same@example.com"], customNames: ["provider.a": "Personal"]).isEmpty)
    }

    @Test func `accounts sharing an email can still be distinguished`() {
        let labels = AccountMenuBarLabel.labels(for: ["codex.a": "a@example.com", "codex.b": "a@example.com"])
        #expect(labels["codex.a"] != labels["codex.b"])
        #expect(labels.values.allSatisfy { $0.count <= 8 })
        #expect(AccountMenuBarLabel.labels(for: ["codex": "a@example.com"]).isEmpty)
    }
    @Test func generatedSuffixDoesNotCollideWithAnotherChosenName() {
        let labels = AccountMenuBarLabel.labels(for: ["a": "a@example.com", "b": "b@example.com", "c": "c@example.com"],
            customNames: ["a": "Work", "b": "Work", "c": "Work·1"])
        #expect(Set(labels.values).count == 3)
        #expect(labels["c"] == "Work·1")
        #expect(labels.values.allSatisfy { $0.count <= 12 })
    }

}
