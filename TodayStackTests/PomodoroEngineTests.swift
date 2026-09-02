import Foundation
import XCTest
@testable import TodayStack

final class PomodoroEngineTests: XCTestCase {
    private let task = FocusTaskReference(
        occurrenceID: "occurrence-1",
        lineageID: "lineage-1",
        dateKey: "2026-09-01",
        titleSnapshot: "Write proposal",
        habitIDSnapshot: "habit-work",
        habitNameSnapshot: "Work"
    )

    private func time(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    func testSettingsDefaultToTwentyFiveMinutesAndRoundTrip() throws {
        var settings = PomodoroSettings()
        XCTAssertEqual(settings.focusDurationSeconds, 1_500)
        XCTAssertEqual(settings.extensionDurationSeconds, 1_500)

        settings.focusDurationSeconds = 0
        settings.extensionDurationSeconds = -10
        XCTAssertEqual(settings.focusDurationSeconds, 1)
        XCTAssertEqual(settings.extensionDurationSeconds, 1)

        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(PomodoroSettings.self, from: data), settings)
    }

    func testSettingsRejectInvalidPersistedDurations() {
        let invalid = Data(#"{"focusDurationSeconds":0,"extensionDurationSeconds":1500}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(PomodoroSettings.self, from: invalid))
    }

    func testStartCreatesAbsoluteDeadlineAndRejectsSecondStart() {
        var state = PomodoroState(settings: PomodoroSettings(focusDurationSeconds: 90))
        XCTAssertTrue(PomodoroEngine.start(task: task, runID: "run-1", at: time(100), state: &state))

        guard case let .running(run, intervalStartedAt, deadline, cycleDuration, cycleFocused)? = state.activeTimer else {
            return XCTFail("Expected a running timer")
        }
        XCTAssertEqual(run.id, "run-1")
        XCTAssertEqual(run.task, task)
        XCTAssertEqual(run.startedAt, time(100))
        XCTAssertEqual(intervalStartedAt, time(100))
        XCTAssertEqual(deadline, time(190))
        XCTAssertEqual(cycleDuration, 90)
        XCTAssertEqual(cycleFocused, 0)

        let startedState = state
        XCTAssertFalse(PomodoroEngine.start(task: task, runID: "run-2", at: time(110), state: &state))
        XCTAssertEqual(state, startedState)
    }

    func testTickOnlyPersistsAtDeadlineAndCannotCompleteCycleTwice() {
        var state = PomodoroState(settings: PomodoroSettings(focusDurationSeconds: 60))
        PomodoroEngine.start(task: task, runID: "run-1", at: time(100), state: &state)
        let startedState = state

        XCTAssertFalse(PomodoroEngine.tick(at: time(159), state: &state))
        XCTAssertEqual(state, startedState)
        XCTAssertTrue(PomodoroEngine.tick(at: time(160), state: &state))

        guard case let .awaitingDecision(run, reachedAt)? = state.activeTimer else {
            return XCTFail("Expected the decision prompt")
        }
        XCTAssertEqual(run.focusedSeconds, 60)
        XCTAssertEqual(reachedAt, time(160))

        let awaitingState = state
        XCTAssertFalse(PomodoroEngine.tick(at: time(1_000), state: &state))
        XCTAssertEqual(state, awaitingState)
    }

    func testPresentationDerivesTimeWithoutMutatingPersistedState() {
        var state = PomodoroState(settings: PomodoroSettings(focusDurationSeconds: 100))
        PomodoroEngine.start(task: task, runID: "run-1", at: time(100), state: &state)
        let persisted = state

        XCTAssertEqual(
            PomodoroEngine.presentation(for: state, at: time(125)),
            .running(
                task: task,
                remainingSeconds: 75,
                focusedSeconds: 25,
                cycleProgress: 0.25,
                extensionCount: 0
            )
        )
        XCTAssertEqual(state, persisted)

        XCTAssertEqual(
            PomodoroEngine.presentation(for: state, at: time(999)),
            .awaitingDecision(task: task, focusedSeconds: 100, extensionCount: 0)
        )
        XCTAssertEqual(state, persisted)
    }

    func testPauseAndResumeExcludePausedTimeFromFocusedSeconds() {
        var state = PomodoroState(settings: PomodoroSettings(focusDurationSeconds: 100))
        PomodoroEngine.start(task: task, runID: "run-1", at: time(100), state: &state)

        XCTAssertTrue(PomodoroEngine.pause(at: time(130), state: &state))
        XCTAssertEqual(
            PomodoroEngine.presentation(for: state, at: time(900)),
            .paused(
                task: task,
                remainingSeconds: 70,
                focusedSeconds: 30,
                cycleProgress: 0.3,
                extensionCount: 0
            )
        )

        XCTAssertTrue(PomodoroEngine.resume(at: time(1_000), state: &state))
        guard case let .running(_, intervalStartedAt, deadline, _, cycleFocused)? = state.activeTimer else {
            return XCTFail("Expected resumed timer")
        }
        XCTAssertEqual(intervalStartedAt, time(1_000))
        XCTAssertEqual(deadline, time(1_070))
        XCTAssertEqual(cycleFocused, 30)

        let record = PomodoroEngine.end(outcome: .stopped, at: time(1_020), state: &state)
        XCTAssertEqual(record?.focusedSeconds, 50)
        XCTAssertEqual(record?.endedAt, time(1_020))
        XCTAssertNil(state.activeTimer)
    }

    func testDecisionPromptAndExtensionTimeAreExcluded() {
        var state = PomodoroState(
            settings: PomodoroSettings(focusDurationSeconds: 60, extensionDurationSeconds: 30)
        )
        PomodoroEngine.start(task: task, runID: "run-1", at: time(100), state: &state)

        XCTAssertTrue(PomodoroEngine.tick(at: time(300), state: &state))
        XCTAssertTrue(PomodoroEngine.extend(at: time(1_000), state: &state))

        guard case let .running(run, intervalStartedAt, deadline, cycleDuration, cycleFocused)? = state.activeTimer else {
            return XCTFail("Expected an extension cycle")
        }
        XCTAssertEqual(run.focusedSeconds, 60)
        XCTAssertEqual(run.extensionCount, 1)
        XCTAssertEqual(intervalStartedAt, time(1_000))
        XCTAssertEqual(deadline, time(1_030))
        XCTAssertEqual(cycleDuration, 30)
        XCTAssertEqual(cycleFocused, 0)

        XCTAssertTrue(PomodoroEngine.tick(at: time(2_000), state: &state))
        let record = PomodoroEngine.end(outcome: .completedTask, at: time(3_000), state: &state)
        XCTAssertEqual(record?.focusedSeconds, 90)
        XCTAssertEqual(record?.extensionCount, 1)
        XCTAssertEqual(record?.outcome, .completedTask)
        XCTAssertEqual(record?.endedAt, time(3_000))
    }

    func testEndBeforeDeadlineArchivesActualFocusOnce() {
        var state = PomodoroState(settings: PomodoroSettings(focusDurationSeconds: 100))
        PomodoroEngine.start(task: task, runID: "run-1", at: time(100), state: &state)

        let record = PomodoroEngine.end(outcome: .stopped, at: time(142), state: &state)
        XCTAssertEqual(
            record,
            FocusRecord(
                id: "run-1",
                task: task,
                startedAt: time(100),
                endedAt: time(142),
                focusedSeconds: 42,
                extensionCount: 0,
                outcome: .stopped
            )
        )
        XCTAssertEqual(state.records, [record].compactMap { $0 })
        XCTAssertNil(state.activeTimer)

        XCTAssertNil(PomodoroEngine.end(outcome: .completedTask, at: time(150), state: &state))
        XCTAssertEqual(state.records.count, 1)

        XCTAssertFalse(PomodoroEngine.start(task: task, runID: "run-1", at: time(200), state: &state))
        XCTAssertNil(state.activeTimer)
        XCTAssertEqual(state.records.count, 1)
    }

    func testEndAfterDeadlineCapsFocusAtPlannedDurationWithoutTick() {
        var state = PomodoroState(settings: PomodoroSettings(focusDurationSeconds: 60))
        PomodoroEngine.start(task: task, runID: "run-1", at: time(100), state: &state)

        let record = PomodoroEngine.end(outcome: .completedTask, at: time(500), state: &state)
        XCTAssertEqual(record?.focusedSeconds, 60)
        XCTAssertEqual(record?.endedAt, time(500))
    }

    func testInvalidActionsAreNoOps() {
        var idle = PomodoroState()
        let originalIdle = idle
        XCTAssertFalse(PomodoroEngine.tick(at: time(10), state: &idle))
        XCTAssertFalse(PomodoroEngine.pause(at: time(10), state: &idle))
        XCTAssertFalse(PomodoroEngine.resume(at: time(10), state: &idle))
        XCTAssertFalse(PomodoroEngine.extend(at: time(10), state: &idle))
        XCTAssertEqual(idle, originalIdle)

        var running = PomodoroState(settings: PomodoroSettings(focusDurationSeconds: 60))
        PomodoroEngine.start(task: task, runID: "run-1", at: time(100), state: &running)
        let originalRunning = running
        XCTAssertFalse(PomodoroEngine.resume(at: time(110), state: &running))
        XCTAssertFalse(PomodoroEngine.extend(at: time(110), state: &running))
        XCTAssertEqual(running, originalRunning)
    }

    func testStateRoundTripsWhilePausedAndAfterArchival() throws {
        var state = PomodoroState(
            settings: PomodoroSettings(focusDurationSeconds: 60, extensionDurationSeconds: 45)
        )
        PomodoroEngine.start(task: task, runID: "run-1", at: time(100), state: &state)
        PomodoroEngine.pause(at: time(120), state: &state)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let pausedData = try encoder.encode(state)
        XCTAssertEqual(try decoder.decode(PomodoroState.self, from: pausedData), state)

        PomodoroEngine.end(outcome: .stopped, at: time(500), state: &state)
        let archivedData = try encoder.encode(state)
        XCTAssertEqual(try decoder.decode(PomodoroState.self, from: archivedData), state)
    }

    func testClockMovingBackwardNeverCreatesNegativeFocus() {
        var state = PomodoroState(settings: PomodoroSettings(focusDurationSeconds: 60))
        PomodoroEngine.start(task: task, runID: "run-1", at: time(100), state: &state)

        XCTAssertTrue(PomodoroEngine.pause(at: time(90), state: &state))
        guard case let .paused(run, remaining, _, _, _)? = state.activeTimer else {
            return XCTFail("Expected paused timer")
        }
        XCTAssertEqual(run.focusedSeconds, 0)
        XCTAssertEqual(remaining, 60)

        let record = PomodoroEngine.end(outcome: .stopped, at: time(80), state: &state)
        XCTAssertEqual(record?.focusedSeconds, 0)
        XCTAssertEqual(record?.endedAt, time(100))
    }
}
