import Testing
import Foundation
@testable import DataSources

@Suite
struct CLICompletionRuleTests {

    /// What `claude /usage` paints within milliseconds of opening the Usage tab —
    /// the cost panel plus a placeholder, before the quota request comes back.
    static let loadingScreen = """
    Claude Code v2.1.251
    Opus 5 (1M context) · Claude Max

      Settings  Status  Config  Usage  Stats

      Session
        Total cost:            $0.0000
        Total duration (API):  0s
        Usage:                 0 input, 0 output, 0 cache read, 0 cache write

        Loading usage data…

      Esc to cancel
    """

    /// The same capture a few seconds later. The PTY buffer is cumulative, so the
    /// placeholder is still in the text — readiness comes from the quota bars.
    static let loadedScreen = loadingScreen + """

      Current session
        ▌                       1% used
        Resets 3:20pm (Asia/Shanghai)
    """

    /// The screen `claude` shows while it is still booting: `/usage` is sitting
    /// unsubmitted in the input box and the SessionStart hooks are still running,
    /// so the Usage tab has not opened at all.
    ///
    /// Verbatim from the `ClaudeBar.log` attached to issue #317 — the capture that
    /// logged at `2026-09-23T18:14:45Z`, trimmed to the first frames (the rest was
    /// the hook's own output). The cursor escapes are kept because they are the
    /// point: the CLI writes every word run at its own absolute column, so no
    /// phrase on this screen reaches the PTY contiguously.
    static let bootScreen = """
    \u{1B}[1C\u{1B}[1B▐▛███▛█\u{1B}[12GClaude\u{1B}[19GCode\u{1B}[24Gv2.1.273
    \u{1B}[1B▝▜██████▀\u{1B}[12GOpus\u{1B}[17G5\u{1B}[19G(1M\u{1B}[23Gcontext)\u{1B}[32Gwith\u{1B}[37Ghigh\u{1B}[42Geffort\u{1B}[49G·\u{1B}[51GAPI\u{1B}[55GUsage\u{1B}[61GBilling
    \u{1B}[2C\u{1B}[1B▝▝\u{1B}[6G▝▝\u{1B}[12G~/Library/Application\u{1B}[34GSupport/ClaudeBar/Probe
    \u{1B}[3B❯\u{1B}[3G/usage
    \u{1B}[38B✢\u{1B}[3GBurrowing…\u{1B}[14G(running\u{1B}[23GSessionStart\u{1B}[36Ghooks…\u{1B}[43G2/5\u{1B}[47G·\u{1B}[49G0s)
    \u{1B}[142C\u{1B}[1B●\u{1B}[145Ghigh\u{1B}[150G·\u{1B}[152G/effort
    \u{1B}[2C\u{1B}[1B⏵⏵\u{1B}[6Gauto\u{1B}[11Gmode\u{1B}[16Gon\u{1B}[19G(shift+tab\u{1B}[30Gto\u{1B}[33Gcycle)\u{1B}[40G·\u{1B}[42Gesc\u{1B}[46Gto\u{1B}[49Ginterrupt\u{1B}[59G·\u{1B}[61G←\u{1B}[63Gfor\u{1B}[67Gagents
    \u{1B}[2C\u{1B}[1B Settings  Status   Config   Usage   Stats
    \u{1B}[2B Session
    \u{1B} Total cost:            $0.0000
    \u{1B} Total duration (API):  0s
    \u{1B} Total duration (wall): 1s
    \u{1B} Total code changes:  0 lines added, 0 lines removed
    \u{1B} Usage: 0 input, 0 output, 0 cache read, 0 cache write
    \u{1B} Esc\u{1B}[8Gto\u{1B}[11Gcancel
    """

    @Test
    func `should keep waiting while Claude's usage screen shows only its loading placeholder`() {
        #expect(CLICompletionRule.claudeUsage.isPending(Self.loadingScreen))
    }

    @Test
    func `should stop waiting once the quota bars arrive, even with the placeholder still on screen`() {
        #expect(!CLICompletionRule.claudeUsage.isPending(Self.loadedScreen))
    }

    /// #317 changed this invariant, and the old name said what it claimed:
    /// "no placeholder" was treated as "settled". The placeholder is only one way
    /// a `/usage` capture can be unfinished — a CLI that has not opened the Usage
    /// tab yet is equally unfinished, and accepting that screen handed the parser
    /// captures with nothing in them. Readiness is now positive evidence: a ready
    /// marker on screen, and without one the capture is still filling in.
    @Test
    func `should keep waiting when the CLI hasn't reached the Usage tab, even with no placeholder (#317)`() {
        let costPanelOnly = """
        Opus 5 (1M context) · API Usage Billing
          Session
            Total cost:            $0.0000
        """
        #expect(CLICompletionRule.claudeUsage.isPending(costPanelOnly))
    }

    /// #317: the screen the CLI shows while still booting carries no ready marker
    /// at all, so a capture that stops there has nothing to parse.
    @Test
    func `should keep waiting while the CLI is still booting (#317)`() {
        #expect(CLICompletionRule.claudeUsage.isPending(Self.bootScreen))
    }

    /// A TUI redraw writes every word run at its own absolute column, so
    /// `Current session` reaches the PTY as `Curre␛[10Gt␛[12Gsession` and
    /// `38% used` as `38%␛[59Gused`. Searching the raw bytes for a ready marker
    /// never finds them, which would hold the capture open on a screen that is
    /// already finished.
    @Test
    func `should stop waiting when the quota bars are drawn in pieces across the screen`() {
        let split = """
        \u{1B}[3C\u{1B}[2BCurre\u{1B}[10Gt\u{1B}[12Gsession
        \u{1B}[1B█████\u{1B}[55G38%\u{1B}[59Gused
        """
        #expect(!CLICompletionRule.claudeUsage.isPending(split))
    }

    /// The same placeholder, cursor-split the way the CLI really writes it: the
    /// "Loading usage data" marker #271 added is a raw substring of 0 of the
    /// 430 captures attached to #317 and a normalised match in 12, so a raw
    /// search could never have fired on a real screen.
    @Test
    func `should keep waiting when the loading placeholder is drawn in pieces across the screen`() {
        let split = "\u{1B}[3C\u{1B}[2BLoading\u{1B}[12Gusage\u{1B}[18Gdata…"
        #expect(CLICompletionRule.claudeUsage.isPending(split))
    }

    /// A marker has to be a whole token, not a fragment of one. Collapsing the
    /// terminal's padding is what lets a phrase match across a word seam, so the
    /// boundary has to be checked rather than assumed (#317).
    @Test
    func `should not take a word that merely contains a section label as the label`() {
        let label = CLICompletionRule(readyMarkers: [.row("Current session")])
        #expect(!label.isReady("myCurrent session here"))
        #expect(!label.isReady("XCurrent sessionY"))
        #expect(!label.isReady("Current sessions"))
        #expect(label.isReady("Current session"))
    }

    /// #317: the user's own SessionStart hook prints "The current session will
    /// seed it…", and on its own that satisfies the `Current session` marker —
    /// a false ready on a screen that never reached the Usage tab. The CLI
    /// paints a section label as a whole row, so the marker has to end at the end
    /// of its row; the hook's words sit mid-sentence.
    @Test
    func `should keep waiting when a startup hook's text happens to mention the current session (#317)`() {
        let hookProse = """
        \u{1B}[1B  \u{1B}[5C\u{1B}[6G\u{1B}[25GSessionStart:startup says: # claude-mem status
        \u{1B}[1B    \u{1B}[5CThis project has no memory yet. The current session will seed it; subsequent sessions will receive auto-injected context for relevant past work.
        """
        let label = CLICompletionRule(readyMarkers: [.row("Current session")])
        #expect(!label.isReady(hookProse))
        #expect(CLICompletionRule.claudeUsage.isPending(hookProse))
    }

    /// #317: the row-end requirement used to be decided by "does this marker
    /// contain a space", which bound `% used`, `% left`, `rate limited` and
    /// `/usage is only available` as well. It is now a per-marker flag, because
    /// only a section label is painted as a whole row. These are the rows the
    /// old rule turned down that a real Usage screen still paints.
    @Test
    func `should stop waiting when a percentage or rate-limit message shares its row with other text (#317)`() {
        // The CLI shares rows: the percentage sits beside the reset time, and a
        // redraw artifact repeats the reset text on that same line (see
        // `deduplicateResetText`). Requiring `% used` to end its row meant
        // holding the capture open on a finished screen. There is no
        // `Current session` label here, so this stands or falls on the value
        // marker alone.
        let shared = """
              Session
                Total cost:            $0.0000
                Total duration (API):  0s
                Usage:                 0 input, 0 output, 0 cache read, 0 cache write
                27% used  Resets 4:59pm (America/New_York)Resets 4:59pm (America/New_York)
        """
        #expect(CLICompletionRule.claudeUsage.isReady(shared))

        let rateLimited = "Error: Output rate limited, retrying in 20s"
        #expect(CLICompletionRule.claudeUsage.isReady(rateLimited))
    }

    @Test
    func `should stop waiting when the percentage used is shown, wherever it sits on its row`() {
        // The percentage and the word are written in separate runs, and the
        // label's own row is not the row the value is on.
        let value = CLICompletionRule(readyMarkers: [CLICompletionRule.Marker("% used")])
        #expect(value.isReady("38% used"))
        #expect(value.isReady("  38% used\n"))
        #expect(value.isReady("38% used  Resets 4:59pm (America/New_York)"))
        #expect(value.isReady("Resets 4:59pm (America/New_York)Resets 4:59pm (America/New_York)  27% used"))
    }

    /// The flag cuts the other way too: a section label with trailing content on
    /// its row is not the label the CLI paints, so it must not end the wait.
    /// Nothing else on this screen is ready evidence, so `.claudeUsage` is
    /// pending for the same reason.
    @Test
    func `should stop waiting on a section label only when it fills its own row`() {
        let label = CLICompletionRule(readyMarkers: [.row("Current session")])
        #expect(label.isReady("Current session\n  expires in 5m"))
        #expect(!label.isReady("Current session  expires in 5m"))
        #expect(CLICompletionRule.claudeUsage.isPending("Current session  expires in 5m"))
    }

    @Test
    func `should stop waiting at once when the CLI shows a rate-limit error`() {
        let rateLimited = Self.loadingScreen + "\nError: Usage endpoint is rate limited. Please try again in a moment."
        #expect(!CLICompletionRule.claudeUsage.isPending(rateLimited))
    }

    /// The screen `claude /cost` settles on, and why it carries no `/usage` rule.
    ///
    /// `/cost` is one static panel written in a single pass, so it has no
    /// "still filling in" phase and needs no rule: the probe runs it with
    /// `completionRule: nil` and the ordinary idle cutoff ends the capture. What
    /// this pins down is that the `/usage` rule must not be borrowed for it —
    /// a settled `/cost` screen has no quota bars, so it matches none of that
    /// rule's markers and `isPending` would never fall, costing every run the
    /// full 20s timeout (#317).
    static let settledCostScreen = """
    Claude Code v2.1.273
      Session
        Total cost:            $3.5500
        Total duration (API):  6m 19.7s
        Total duration (wall): 6h 33m 10.2s
        Total code changes:    12 lines added, 3 lines removed
      Esc to cancel
    """

    @Test
    func `should keep waiting on a finished cost screen, which is why the cost run uses no such rule (#317)`() {
        // This is the reason `/cost` runs under no rule at all rather than this
        // one: borrowed as-is, the rule can never say "done" here, and the run
        // waits out the full timeout before the parser sees a finished screen.
        #expect(CLICompletionRule.claudeUsage.isPending(Self.settledCostScreen))
    }

    /// The CLI paints the cost panel during boot, before `/cost` is submitted —
    /// it is in the boot screen fixture above. So a ready marker keyed on
    /// `Total cost` would fire on a screen where no cost has been read yet and
    /// the probe would answer $0.00. Recorded here so the reason `/cost` takes
    /// no rule is not "revisit this and add a marker" (#317).
    @Test
    func `should keep waiting on the boot screen even though it already shows a total cost (#317)`() {
        #expect(CLICompletionRule.claudeUsage.isPending(Self.bootScreen))
        #expect(Self.bootScreen.contains("Total cost"))
    }

    @Test
    func `should recognise what ends the wait in any letter case, and nothing else`() {
        let rule = CLICompletionRule(readyMarkers: [CLICompletionRule.Marker("done")])
        #expect(rule.isPending("LOADING…"))
        #expect(!rule.isPending("LOADING… DONE"))
    }
}
