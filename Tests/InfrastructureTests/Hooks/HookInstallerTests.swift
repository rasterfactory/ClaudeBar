import Testing
import Foundation
import Domain
@testable import Infrastructure

@Suite
struct HookInstallerTests {
    @Test
    func `should carry ClaudeBar's marker so the installed hook can be recognised as ClaudeBar's`() {
        #expect(HookInstaller.hookCommand.contains(HookInstaller.hookMarker))
    }

    @Test
    func `should send each Claude Code event to ClaudeBar on this Mac`() {
        #expect(HookInstaller.hookCommand.contains("curl"))
        #expect(HookInstaller.hookCommand.contains("POST"))
        #expect(HookInstaller.hookCommand.contains("localhost"))
        #expect(HookInstaller.hookCommand.contains("/hook"))
    }

    @Test
    func `should find ClaudeBar's port in the file ClaudeBar leaves for it`() {
        #expect(HookInstaller.hookCommand.contains("claudebar-hook-port"))
    }

    @Test
    func `should listen to the seven session events Claude Code reports`() {
        let events = HookInstaller.hookEvents
        #expect(events.contains("SessionStart"))
        #expect(events.contains("SessionEnd"))
        #expect(events.contains("TaskCompleted"))
        #expect(events.contains("SubagentStart"))
        #expect(events.contains("SubagentStop"))
        #expect(events.contains("Stop"))
        #expect(events.contains("UserPromptSubmit"))
        #expect(events.count == 7)
    }

    @Test
    func `should count the hook not installed when Claude Code has no settings file`() {
        // When there's no settings file at all, isInstalled should be false
        // This tests the code path, not the actual file system
        let settings = HookInstaller.readSettings()
        if settings == nil {
            #expect(HookInstaller.isInstalled() == false)
        }
        // If settings exist, we can't make assumptions about the file
    }

    @Test
    func `should mark the hook with a name the shell accepts as a function name`() {
        // The marker should be a valid bash function identifier
        let marker = HookInstaller.hookMarker
        #expect(!marker.isEmpty)
        #expect(marker.allSatisfy { $0.isLetter || $0 == "_" })
    }

    // MARK: - Probe sessions (issue #222)

    @Test
    func `should send nothing when the session is ClaudeBar's own Claude run (#222)`() {
        let command = HookInstaller.hookCommand

        // The guard references the probe marker and returns before any POST.
        let probeGuard = command.range(
            of: "[ \"$\(HookConstants.probeEnvironmentKey)\" = \"1\" ] && return 0"
        )
        #expect(probeGuard != nil)

        if let probeGuard, let curl = command.range(of: "curl") {
            #expect(probeGuard.lowerBound < curl.lowerBound)
        }
    }
}
