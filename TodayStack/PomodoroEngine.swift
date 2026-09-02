import Foundation

/// Pure, deterministic state transitions for the Pomodoro domain.
///
/// The engine never reads the system clock or generates identifiers. Callers
/// inject both so transitions can be replayed and tested exactly.
public enum PomodoroEngine {
    @discardableResult
    public static func start(
        task: FocusTaskReference,
        runID: String,
        at now: Date,
        state: inout PomodoroState
    ) -> Bool {
        guard state.activeTimer == nil,
              !runID.isEmpty,
              !state.records.contains(where: { $0.id == runID }) else {
            return false
        }

        let duration = state.settings.focusDurationSeconds
        let run = FocusRun(id: runID, task: task, startedAt: now)
        state.activeTimer = .running(
            run: run,
            intervalStartedAt: now,
            deadline: now.addingTimeInterval(TimeInterval(duration)),
            cycleDurationSeconds: duration,
            cycleFocusedSeconds: 0
        )
        return true
    }

    /// Persists a phase transition only when the current deadline has elapsed.
    @discardableResult
    public static func tick(at now: Date, state: inout PomodoroState) -> Bool {
        guard case let .running(run, _, deadline, cycleDuration, cycleFocused)? = state.activeTimer,
              now >= deadline else {
            return false
        }

        var completedRun = run
        completedRun.focusedSeconds += max(0, cycleDuration - cycleFocused)
        state.activeTimer = .awaitingDecision(run: completedRun, reachedAt: deadline)
        return true
    }

    @discardableResult
    public static func pause(at now: Date, state: inout PomodoroState) -> Bool {
        guard case let .running(run, intervalStartedAt, deadline, cycleDuration, cycleFocused)? = state.activeTimer else {
            return false
        }

        if now >= deadline {
            return tick(at: now, state: &state)
        }

        let elapsed = elapsedWholeSeconds(from: intervalStartedAt, through: now, cappedAt: deadline)
        var pausedRun = run
        pausedRun.focusedSeconds += elapsed
        let updatedCycleFocused = min(cycleDuration, cycleFocused + elapsed)
        let remaining = max(0, cycleDuration - updatedCycleFocused)

        state.activeTimer = .paused(
            run: pausedRun,
            remainingSeconds: remaining,
            cycleDurationSeconds: cycleDuration,
            cycleFocusedSeconds: updatedCycleFocused,
            pausedAt: now
        )
        return true
    }

    @discardableResult
    public static func resume(at now: Date, state: inout PomodoroState) -> Bool {
        guard case let .paused(run, remaining, cycleDuration, cycleFocused, _)? = state.activeTimer else {
            return false
        }

        guard remaining > 0 else {
            state.activeTimer = .awaitingDecision(run: run, reachedAt: now)
            return true
        }

        state.activeTimer = .running(
            run: run,
            intervalStartedAt: now,
            deadline: now.addingTimeInterval(TimeInterval(remaining)),
            cycleDurationSeconds: cycleDuration,
            cycleFocusedSeconds: cycleFocused
        )
        return true
    }

    /// Starts another focus cycle without counting time spent on the decision prompt.
    @discardableResult
    public static func extend(at now: Date, state: inout PomodoroState) -> Bool {
        guard case let .awaitingDecision(run, _)? = state.activeTimer else { return false }

        let duration = state.settings.extensionDurationSeconds
        var extendedRun = run
        extendedRun.extensionCount += 1
        state.activeTimer = .running(
            run: extendedRun,
            intervalStartedAt: now,
            deadline: now.addingTimeInterval(TimeInterval(duration)),
            cycleDurationSeconds: duration,
            cycleFocusedSeconds: 0
        )
        return true
    }

    /// Archives the current session once. Repeating `end` after archival returns nil.
    @discardableResult
    public static func end(
        outcome: FocusOutcome,
        at now: Date,
        state: inout PomodoroState
    ) -> FocusRecord? {
        guard let activeTimer = state.activeTimer else { return nil }

        let run: FocusRun
        switch activeTimer {
        case let .running(currentRun, intervalStartedAt, deadline, cycleDuration, cycleFocused):
            var finalRun = currentRun
            let elapsed = elapsedWholeSeconds(from: intervalStartedAt, through: now, cappedAt: deadline)
            finalRun.focusedSeconds += min(max(0, cycleDuration - cycleFocused), elapsed)
            run = finalRun
        case let .paused(currentRun, _, _, _, _):
            run = currentRun
        case let .awaitingDecision(currentRun, _):
            run = currentRun
        }

        let record = FocusRecord(
            id: run.id,
            task: run.task,
            startedAt: run.startedAt,
            endedAt: max(now, run.startedAt),
            focusedSeconds: run.focusedSeconds,
            extensionCount: run.extensionCount,
            outcome: outcome
        )
        state.records.append(record)
        state.activeTimer = nil
        return record
    }

    public static func presentation(for state: PomodoroState, at now: Date) -> FocusPresentation {
        guard let activeTimer = state.activeTimer else { return .idle }

        switch activeTimer {
        case let .running(run, intervalStartedAt, deadline, cycleDuration, cycleFocused):
            let cycleRemainder = max(0, cycleDuration - cycleFocused)
            if now >= deadline {
                return .awaitingDecision(
                    task: run.task,
                    focusedSeconds: run.focusedSeconds + cycleRemainder,
                    extensionCount: run.extensionCount
                )
            }

            let elapsed = min(
                cycleRemainder,
                elapsedWholeSeconds(from: intervalStartedAt, through: now, cappedAt: deadline)
            )
            let currentCycleFocused = min(cycleDuration, cycleFocused + elapsed)
            return .running(
                task: run.task,
                remainingSeconds: remainingWholeSeconds(until: deadline, from: now),
                focusedSeconds: run.focusedSeconds + elapsed,
                cycleProgress: progress(focused: currentCycleFocused, total: cycleDuration),
                extensionCount: run.extensionCount
            )

        case let .paused(run, remaining, cycleDuration, cycleFocused, _):
            return .paused(
                task: run.task,
                remainingSeconds: max(0, remaining),
                focusedSeconds: run.focusedSeconds,
                cycleProgress: progress(focused: cycleFocused, total: cycleDuration),
                extensionCount: run.extensionCount
            )

        case let .awaitingDecision(run, _):
            return .awaitingDecision(
                task: run.task,
                focusedSeconds: run.focusedSeconds,
                extensionCount: run.extensionCount
            )
        }
    }

    private static func elapsedWholeSeconds(from start: Date, through now: Date, cappedAt deadline: Date) -> Int {
        let effectiveEnd = min(max(now, start), deadline)
        return max(0, Int(effectiveEnd.timeIntervalSince(start).rounded(.down)))
    }

    private static func remainingWholeSeconds(until deadline: Date, from now: Date) -> Int {
        max(0, Int(deadline.timeIntervalSince(now).rounded(.up)))
    }

    private static func progress(focused: Int, total: Int) -> Double {
        guard total > 0 else { return 1 }
        return min(1, max(0, Double(focused) / Double(total)))
    }
}
