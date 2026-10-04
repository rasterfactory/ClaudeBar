import Testing
import Foundation
@testable import ClaudeBar

/// `StatusItemWriteGate` coalesces writes into the menu bar's status item:
/// at most one actual write per minimum interval, with a guaranteed trailing
/// flush of the latest content. macOS 26's Control Center status-items XPC
/// service aborts under a stream of rapid status-item updates (issue #281);
/// the countdown blink pushed up to two button writes a second into it.
///
/// These tests verify the update-rate reduction only. The Apple-side abort
/// cannot be reproduced in a unit test — see the issue for the crash stack.
@Suite
@MainActor
struct StatusItemWriteGateTests {
    /// Virtual clock so tests never sleep.
    @MainActor
    final class FakeClock {
        var time: TimeInterval = 0
    }

    /// Records every actual write: content and the clock time it happened.
    @MainActor
    final class WriteRecorder {
        struct Write {
            let content: String
            let at: TimeInterval
        }

        private(set) var writes: [Write] = []
        var contents: [String] { writes.map(\.content) }
        var times: [TimeInterval] { writes.map(\.at) }

        func record(_ content: String, at time: TimeInterval) {
            writes.append(Write(content: content, at: time))
        }
    }

    /// Captures scheduled trailing flushes; tests fire them manually.
    @MainActor
    final class FlushScheduler {
        struct Flush {
            let delay: TimeInterval
            let dueAt: TimeInterval
            let fire: @MainActor () -> Void
        }

        private(set) var flushes: [Flush] = []
        private(set) var totalScheduled = 0

        func schedule(delay: TimeInterval, after now: TimeInterval, fire: @escaping @MainActor () -> Void) {
            totalScheduled += 1
            flushes.append(Flush(delay: delay, dueAt: now + delay, fire: fire))
        }

        /// Fires every flush whose due time has arrived, oldest first.
        func fireDue(at time: TimeInterval) {
            while let first = flushes.first, first.dueAt <= time {
                flushes.removeFirst()
                first.fire()
            }
        }
    }

    private func makeGate(
        clock: FakeClock,
        scheduler: FlushScheduler,
        recorder: WriteRecorder,
        minimumInterval: TimeInterval = 1.0
    ) -> StatusItemWriteGate<String> {
        StatusItemWriteGate(
            minimumInterval: minimumInterval,
            now: { clock.time },
            schedule: { delay, fire in scheduler.schedule(delay: delay, after: clock.time, fire: fire) },
            write: { recorder.record($0, at: clock.time) }
        )
    }

    @Test
    func `should show the menu bar's first content at once, with nothing left waiting`() {
        // Given
        let clock = FakeClock()
        let scheduler = FlushScheduler()
        let recorder = WriteRecorder()
        let gate = makeGate(clock: clock, scheduler: scheduler, recorder: recorder)

        // When
        gate.submit("A")

        // Then — the first write must reach the button at once, so the item
        // never appears late at launch.
        #expect(recorder.contents == ["A"])
        #expect(recorder.times == [0.0])
        #expect(scheduler.flushes.isEmpty)
    }

    @Test
    func `should hold a change that arrives within a second of the last and show it when the second is up (#281)`() {
        // Given
        let clock = FakeClock()
        let scheduler = FlushScheduler()
        let recorder = WriteRecorder()
        let gate = makeGate(clock: clock, scheduler: scheduler, recorder: recorder)
        gate.submit("A")

        // When — a second render half a second later, inside the window
        clock.time = 0.5
        gate.submit("B")

        // Then — nothing is written yet, and one trailing flush is scheduled
        // for the remainder of the window
        #expect(recorder.contents == ["A"])
        #expect(scheduler.flushes.count == 1)
        #expect(abs(scheduler.flushes[0].delay - 0.5) < 0.0001)

        clock.time = 1.0
        scheduler.fireDue(at: clock.time)

        #expect(recorder.contents == ["A", "B"])
        #expect(recorder.times == [0.0, 1.0])
    }

    @Test
    func `should show only the latest of several changes that arrive within one second`() {
        // Given
        let clock = FakeClock()
        let scheduler = FlushScheduler()
        let recorder = WriteRecorder()
        let gate = makeGate(clock: clock, scheduler: scheduler, recorder: recorder)
        gate.submit("A")

        // When — three renders inside one window
        clock.time = 0.2
        gate.submit("B")
        clock.time = 0.4
        gate.submit("C")
        clock.time = 0.6
        gate.submit("D")

        // Then — one trailing flush, carrying the latest content
        #expect(scheduler.flushes.count == 1)
        clock.time = 1.0
        scheduler.fireDue(at: clock.time)
        #expect(recorder.contents == ["A", "D"])
    }

    @Test
    func `should show a change at once when a full second has passed since the last`() {
        // Given
        let clock = FakeClock()
        let scheduler = FlushScheduler()
        let recorder = WriteRecorder()
        let gate = makeGate(clock: clock, scheduler: scheduler, recorder: recorder)
        gate.submit("A")

        // When — the next render lands exactly on the interval boundary
        clock.time = 1.0
        gate.submit("B")

        // Then — no deferral, no scheduled flush
        #expect(recorder.contents == ["A", "B"])
        #expect(scheduler.flushes.isEmpty)
    }

    @Test
    func `should keep the countdown blink alternating once a second when ticks land just before the second is up`() {
        // Given — a repeating timer never fires early but can fire late, so a
        // tick can land just inside the window (0.95s after the last write).
        // The blink's alternation depends on the trailing flush completing
        // before the next phase submits: with one phase per window, the
        // pending content is never replaced by a stale phase.
        let clock = FakeClock()
        let scheduler = FlushScheduler()
        let recorder = WriteRecorder()
        let gate = makeGate(clock: clock, scheduler: scheduler, recorder: recorder)
        gate.submit("A")

        // When
        clock.time = 0.95
        gate.submit("B")
        clock.time = 1.0
        scheduler.fireDue(at: clock.time)
        clock.time = 1.95
        gate.submit("A")
        clock.time = 2.0
        scheduler.fireDue(at: clock.time)

        // Then — the phases keep alternating at the visible 1 Hz rate
        #expect(recorder.contents == ["A", "B", "A"])
        #expect(recorder.times == [0.0, 1.0, 2.0])
    }

    @Test
    func `should update the menu bar at most once a second, ending on the latest content, when changes arrive every half second (#281)`() {
        // Given — the pathological stress case: renders every 0.5s, two per
        // window (the pre-fix tick rate). The gate must collapse them to one
        // write per second, and whatever render arrived last is the one that
        // gets written — the driver avoids this cadence (its tick matches the
        // gate) precisely so alternate phases aren't collapsed away, but the
        // write bound must hold no matter how fast renders arrive.
        let clock = FakeClock()
        let scheduler = FlushScheduler()
        let recorder = WriteRecorder()
        let gate = makeGate(clock: clock, scheduler: scheduler, recorder: recorder)

        // When — the tick runs for 4.5s, then the final trailing flush fires
        gate.submit("A")
        let ticks: [(t: Double, content: String)] = [
            (0.5, "B"), (1.0, "A"), (1.5, "B"), (2.0, "A"),
            (2.5, "B"), (3.0, "A"), (3.5, "B"), (4.0, "A"),
            (4.5, "B"),
        ]
        for tick in ticks {
            clock.time = tick.t
            scheduler.fireDue(at: tick.t)
            gate.submit(tick.content)
        }
        clock.time = 5.0
        scheduler.fireDue(at: clock.time)

        // Then — 10 renders collapsed to 6 writes, spaced at least one second
        // apart, and the last submitted content is the last write
        #expect(recorder.contents == ["A", "B", "B", "B", "B", "B"])
        #expect(recorder.times == [0.0, 1.0, 2.0, 3.0, 4.0, 5.0])
        for (earlier, later) in zip(recorder.times, recorder.times.dropFirst()) {
            #expect(later - earlier >= 1.0)
        }
    }

    @Test
    func `should leave the menu bar alone when the second is up and nothing changed`() {
        // Given
        let clock = FakeClock()
        let scheduler = FlushScheduler()
        let recorder = WriteRecorder()
        let gate = makeGate(clock: clock, scheduler: scheduler, recorder: recorder)
        gate.submit("A")

        // When — a flush fires with no deferred content
        gate.flushPending()

        // Then
        #expect(recorder.contents == ["A"])
    }

    @Test
    func `should hold a change that arrives soon after a held one was shown, until a full second has passed`() {
        // Given — one write and one trailing flush already done
        let clock = FakeClock()
        let scheduler = FlushScheduler()
        let recorder = WriteRecorder()
        let gate = makeGate(clock: clock, scheduler: scheduler, recorder: recorder)
        gate.submit("A")
        clock.time = 0.5
        gate.submit("B")
        clock.time = 1.0
        scheduler.fireDue(at: clock.time)
        #expect(recorder.contents == ["A", "B"])

        // When — a render arrives a quarter second after the flush
        clock.time = 1.25
        gate.submit("C")

        // Then — it defers into the fresh window, with a flush scheduled for
        // the remainder of that window
        #expect(recorder.contents == ["A", "B"])
        #expect(scheduler.totalScheduled == 2)
        #expect(abs(scheduler.flushes[0].delay - 0.75) < 0.0001)

        clock.time = 2.0
        scheduler.fireDue(at: clock.time)
        #expect(recorder.contents == ["A", "B", "C"])
        #expect(recorder.times == [0.0, 1.0, 2.0])
    }

    // MARK: - Reconcile (the render skip path)

    @Test
    func `should never show an older held change over what the menu bar already shows`() {
        // Given — the driver skipped a render because the screen already
        // shows that content, but a flush is still armed carrying an older
        // render's value
        let clock = FakeClock()
        let scheduler = FlushScheduler()
        let recorder = WriteRecorder()
        let gate = makeGate(clock: clock, scheduler: scheduler, recorder: recorder)
        gate.submit("A")
        clock.time = 0.5
        gate.submit("B")

        // When — the skip path reconciles with the newest render (identical
        // to what is on screen)
        gate.reconcile("A")

        // Then — reconcile itself never writes and never reschedules; the
        // armed flush now carries the reconciled content, so the older B can
        // never be applied over the state the screen already shows
        #expect(recorder.contents == ["A"])
        #expect(scheduler.totalScheduled == 1)
        clock.time = 1.0
        scheduler.fireDue(at: clock.time)
        #expect(recorder.contents == ["A", "A"])
        #expect(recorder.times == [0.0, 1.0])
    }

    @Test
    func `should leave the menu bar alone when it already shows the latest content and nothing is held`() {
        let clock = FakeClock()
        let scheduler = FlushScheduler()
        let recorder = WriteRecorder()
        let gate = makeGate(clock: clock, scheduler: scheduler, recorder: recorder)
        gate.submit("A")

        gate.reconcile("A")

        #expect(recorder.contents == ["A"])
        #expect(scheduler.flushes.isEmpty)
    }

    // MARK: - Immediate writes retire the armed flush

    @Test
    func `should keep updates a second apart after a change is shown at once while an older one was held`() {
        // Given — B is pending, with a flush armed for the 1.0 boundary
        let clock = FakeClock()
        let scheduler = FlushScheduler()
        let recorder = WriteRecorder()
        let gate = makeGate(clock: clock, scheduler: scheduler, recorder: recorder)
        gate.submit("A")
        clock.time = 0.5
        gate.submit("B")

        // When — a render lands exactly on the boundary and writes at once,
        // the flush armed for the old window must be retired
        clock.time = 1.0
        gate.submit("C")
        #expect(recorder.contents == ["A", "C"])

        // And a render inside the fresh window defers again
        clock.time = 1.25
        gate.submit("D")

        // Then — the retired schedule must not fire, and D waits for a fresh
        // trailing edge, keeping actual writes at least one second apart.
        // (Without retirement the stale schedule suppresses the new one and
        // the old flush writes D at 1.5 — half a second after C.)
        #expect(scheduler.totalScheduled == 2)
        clock.time = 1.5
        scheduler.fireDue(at: clock.time)
        #expect(recorder.contents == ["A", "C"])

        clock.time = 2.0
        scheduler.fireDue(at: clock.time)
        #expect(recorder.contents == ["A", "C", "D"])
        #expect(recorder.times == [0.0, 1.0, 2.0])
    }

    // MARK: - Production clock

    @Test
    func `should never let the menu bar's clock go backwards`() {
        // The interval math only needs a clock that never goes backwards.
        // A wall-clock jump (user or NTP correction) would make a submit
        // interval come out negative — every render writing at once — or
        // huge — the trailing flush deferred for hours. The production
        // default therefore reads the monotonic uptime; here we verify the
        // contract that matters and that is observable without changing the
        // system clock: repeated reads never decrease and never go negative.
        var previous = StatusItemClock.monotonicNow()
        #expect(previous >= 0)
        for _ in 0..<100 {
            let current = StatusItemClock.monotonicNow()
            #expect(current >= previous)
            previous = current
        }
    }
}
