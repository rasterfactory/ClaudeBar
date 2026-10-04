import Foundation
import Providers
import Testing

/// *Switch when low* — the opt-in policy that moves new sessions off a login
/// running out, to the ticked login with the most left.
@MainActor
@Suite
struct SwitchWhenLowTests {
    @Test
    func `off until the person turns it on`() async throws {
        let (stub, codex, _) = try InUseFixture.twoLogins()
        defer { stub.cleanUp() }
        let inUse = try #require(codex.inUse)
        try await InUseFixture.usage(stub, codex, me: 95, work: 10)

        #expect(inUse.switchWhenLow.isOn == false)
        #expect(inUse.switchWhenLow.next(from: inUse.login, among: inUse.logins) == nil)
    }

    @Test
    func `below the threshold, the ticked login with the most left is next`() async throws {
        let (stub, codex, work) = try InUseFixture.twoLogins()
        defer { stub.cleanUp() }
        let inUse = try #require(codex.inUse)
        inUse.switchWhenLow.isOn = true
        inUse.switchWhenLow.below = 10
        try await InUseFixture.usage(stub, codex, me: 95, work: 10)

        #expect(inUse.switchWhenLow.next(from: inUse.login, among: inUse.logins) === work)
    }

    @Test
    func `above the threshold nothing is next`() async throws {
        let (stub, codex, _) = try InUseFixture.twoLogins()
        defer { stub.cleanUp() }
        let inUse = try #require(codex.inUse)
        inUse.switchWhenLow.isOn = true
        inUse.switchWhenLow.below = 5
        try await InUseFixture.usage(stub, codex, me: 90, work: 10)

        #expect(inUse.switchWhenLow.next(from: inUse.login, among: inUse.logins) == nil)
    }

    @Test
    func `a login the person unticked is never next`() async throws {
        let (stub, codex, work) = try InUseFixture.twoLogins()
        defer { stub.cleanUp() }
        let inUse = try #require(codex.inUse)
        inUse.switchWhenLow.isOn = true
        inUse.switchWhenLow.setMayPick(false, work)
        try await InUseFixture.usage(stub, codex, me: 95, work: 10)

        #expect(inUse.switchWhenLow.mayPick(work) == false)
        #expect(inUse.switchWhenLow.next(from: inUse.login, among: inUse.logins) == nil)
    }

    @Test
    func `its choices are kept`() throws {
        let (stub, codex, work) = try InUseFixture.twoLogins()
        defer { stub.cleanUp() }
        let policy = try #require(codex.inUse?.switchWhenLow)
        policy.isOn = true
        policy.below = 20
        policy.setMayPick(false, work)

        let again = try #require(try stub.makeProvider("codex", accounts: stub.settings.accounts(forProvider: "codex")).inUse)

        #expect(again.switchWhenLow.isOn)
        #expect(again.switchWhenLow.below == 20)
        #expect(again.switchWhenLow.mayPick(again.logins[1]) == false)
        #expect(again.switchWhenLow.mayPick(again.login))
    }
}
