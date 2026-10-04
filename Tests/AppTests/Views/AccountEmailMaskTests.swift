import Testing
@testable import ClaudeBar

/// *Hide account email* (#375): an email shows as its first letters with
/// the rest masked, so a screen share or screenshot doesn't give it away;
/// a name the person gave a login is theirs and shows as it is.
@Suite
struct AccountEmailMaskTests {
    @Test func `should show only an email's first letters and its ending when emails are hidden (#375)`() {
        #expect(AccountEmailMask.masked("sam@example.com") == "s•••@e•••.com")
        #expect(AccountEmailMask.masked("work@corp.example.co.uk") == "w•••@c•••.uk")
    }

    @Test func `should show a name the person gave a login as it is when emails are hidden`() {
        #expect(AccountEmailMask.masked("Work") == "Work")
        #expect(AccountEmailMask.masked("Claude") == "Claude")
    }

    @Test func `should hide an email inside a sentence where it stands`() {
        #expect(AccountEmailMask.masked("a@b.io is at 18%") == "a•••@b•••.io is at 18%")
    }

    @Test func `should keep the menu bar's short name of a hidden email short`() {
        let names = MenuBarAccountName.names(["claude": AccountEmailMask.masked("sam@example.com"),
                                              "claude.work": AccountEmailMask.masked("work@corp.com")])
        #expect(names["claude"] == "s•••")
        #expect(names["claude.work"] == "w•••")
    }
}
