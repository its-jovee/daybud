import Foundation
import XCTest
@testable import TodayStack

final class TodayStackTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    private func date(_ key: String) -> Date {
        DateKey.date(from: key, calendar: calendar)!
    }

    private func repository() throws -> (JSONStateRepository, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TodayStackTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (JSONStateRepository(directoryURL: directory), directory)
    }

    private func encoded(_ file: TodayImportFile) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(file)
    }

    func testFreshStateCreationAndRoundTrip() throws {
        let (repository, directory) = try repository()
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertEqual(try repository.load(), AppState())

        let habit = Habit(
            id: "habit-id",
            slug: "programming",
            name: "Programming",
            frequency: .daily,
            iconName: "laptopcomputer"
        )
        let task = TaskItem(id: "task-id", title: "Study", habitID: habit.id, isCompleted: true)
        let session = HabitSession(id: "session-id", habitID: habit.id, date: "2026-08-27", taskID: task.id, source: .task)
        let state = AppState(days: ["2026-08-27": DayPlan(date: "2026-08-27", tasks: [task])], habits: [habit], sessions: [session])
        try repository.save(state)

        XCTAssertEqual(try repository.load(), state)
    }

    func testVersionOneStateMigratesWithoutLosingTaskIdentity() throws {
        let (repository, directory) = try repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = Data(#"""
        {
          "schemaVersion": 1,
          "days": {
            "2026-08-27": {
              "date": "2026-08-27",
              "tasks": [{"id":"legacy-task","title":"Keep me","habitID":null,"isCompleted":false}]
            }
          },
          "habits": [],
          "sessions": []
        }
        """#.utf8)
        try legacy.write(to: repository.stateURL)

        let migrated = try repository.load()

        XCTAssertEqual(migrated.schemaVersion, AppState.currentSchemaVersion)
        XCTAssertEqual(migrated.days["2026-08-27"]?.tasks.first?.lineageID, "legacy-task")
        XCTAssertEqual(migrated.pomodoro, PomodoroState())
        let persistedObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: repository.stateURL)) as? [String: Any]
        )
        XCTAssertEqual(persistedObject["schemaVersion"] as? Int, AppState.currentSchemaVersion)
    }

    func testVersionTwoStateMigratesWithAnEmptyLaterList() throws {
        let (repository, directory) = try repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let versionTwo = Data(#"""
        {
          "schemaVersion": 2,
          "days": {
            "2026-08-27": {
              "date": "2026-08-27",
              "tasks": [{"id":"existing","lineageID":"existing","title":"Keep me","habitID":null,"isCompleted":false}]
            }
          },
          "habits": [],
          "sessions": [],
          "pomodoro": {
            "settings": {"focusDurationSeconds":1500,"extensionDurationSeconds":1500},
            "activeTimer": null,
            "records": []
          }
        }
        """#.utf8)
        try versionTwo.write(to: repository.stateURL)

        let migrated = try repository.load()

        XCTAssertEqual(migrated.schemaVersion, AppState.currentSchemaVersion)
        XCTAssertTrue(migrated.laterTasks.isEmpty)
        XCTAssertEqual(migrated.days["2026-08-27"]?.tasks.first?.title, "Keep me")
    }

    func testMalformedStatePreservesOriginalFile() throws {
        let (repository, directory) = try repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = Data("{ definitely not json".utf8)
        try original.write(to: repository.stateURL)

        XCTAssertThrowsError(try repository.load())
        XCTAssertEqual(try Data(contentsOf: repository.stateURL), original)
    }

    @MainActor
    func testTaskProgressCurrentTaskReorderingAndDateRollover() throws {
        let (repository, directory) = try repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        var now = date("2026-08-27")
        let store = AppStore(repository: repository, calendar: calendar, now: { now })

        let first = try XCTUnwrap(store.addTask(title: "First"))
        let second = try XCTUnwrap(store.addTask(title: "Second"))
        let third = try XCTUnwrap(store.addTask(title: "Third"))
        XCTAssertEqual(store.progressText, "0/3")
        XCTAssertEqual(store.currentTask?.id, first)
        store.setTaskCompleted(id: first, completed: true)
        XCTAssertEqual(store.progressText, "1/3")
        XCTAssertEqual(store.currentTask?.id, second)

        store.moveTasks(from: IndexSet(integer: 2), to: 0)
        XCTAssertEqual(store.todayPlan.tasks.map(\.id), [third, first, second])

        store.moveTask(id: first, before: third)
        XCTAssertEqual(store.todayPlan.tasks.map(\.id), [first, third, second])
        store.moveTask(id: first, before: nil)
        XCTAssertEqual(store.todayPlan.tasks.map(\.id), [third, second, first])

        now = date("2026-08-28")
        store.refresh()
        XCTAssertEqual(store.todayDateKey, "2026-08-28")
        XCTAssertEqual(store.todayPlan.tasks.map(\.title), ["Third", "Second"])
        XCTAssertTrue(store.todayPlan.tasks.allSatisfy { !$0.isCompleted })
        XCTAssertTrue(Set(store.todayPlan.tasks.map(\.id)).isDisjoint(with: [first, second, third]))
        XCTAssertEqual(
            store.todayPlan.tasks.map(\.lineageID),
            [third, second],
            "A carried occurrence keeps the original task lineage"
        )
        XCTAssertEqual(store.state.days["2026-08-27"]?.tasks.count, 3)
    }

    @MainActor
    func testPomodoroCompletionArchivesFocusAndCompletesTheTask() throws {
        let (repository, directory) = try repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        var now = date("2026-08-27")
        let notifications = FocusNotificationSchedulerSpy()
        let store = AppStore(
            repository: repository,
            calendar: calendar,
            now: { now },
            focusNotificationScheduler: notifications
        )
        let taskID = try XCTUnwrap(store.addTask(title: "Write proposal"))
        let task = try XCTUnwrap(store.todayPlan.tasks.first)
        store.updatePomodoroSettings(PomodoroSettings(focusDurationSeconds: 60, extensionDurationSeconds: 30))

        XCTAssertTrue(store.startFocus(on: task))
        XCTAssertFalse(store.startFocus(on: task))
        XCTAssertTrue(store.menuBarLabel.hasPrefix("01:00 ·"))

        now = now.addingTimeInterval(60)
        store.refresh()
        guard case .awaitingDecision(_, let focusedSeconds, _) = store.focusPresentation else {
            return XCTFail("Expected the completion decision")
        }
        XCTAssertEqual(focusedSeconds, 60)

        store.markFocusedTaskDone()
        XCTAssertTrue(store.todayPlan.tasks.first(where: { $0.id == taskID })?.isCompleted == true)
        XCTAssertEqual(store.state.pomodoro.records.count, 1)
        XCTAssertEqual(store.state.pomodoro.records.first?.focusedSeconds, 60)
        XCTAssertEqual(store.state.pomodoro.records.first?.outcome, .completedTask)
        XCTAssertEqual(store.focusPresentation, .idle)

        let reopened = AppStore(repository: repository, calendar: calendar, now: { now })
        XCTAssertEqual(reopened.state.pomodoro.records, store.state.pomodoro.records)
    }

    @MainActor
    func testPomodoroNotificationTracksStartPauseResumeCompletionAndExtension() throws {
        let (repository, directory) = try repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        var now = date("2026-08-27")
        let notifications = FocusNotificationSchedulerSpy()
        let store = AppStore(
            repository: repository,
            calendar: calendar,
            now: { now },
            focusNotificationScheduler: notifications
        )
        notifications.reset()

        _ = store.addTask(title: "Finish the proposal")
        let task = try XCTUnwrap(store.todayPlan.tasks.first)
        store.updatePomodoroSettings(
            PomodoroSettings(focusDurationSeconds: 60, extensionDurationSeconds: 30)
        )

        XCTAssertTrue(store.startFocus(on: task))
        XCTAssertEqual(notifications.scheduled.count, 1)
        XCTAssertEqual(notifications.scheduled.last?.task.titleSnapshot, "Finish the proposal")
        XCTAssertEqual(notifications.scheduled.last?.deadline, now.addingTimeInterval(60))

        now = now.addingTimeInterval(20)
        store.pauseFocus()
        XCTAssertEqual(notifications.cancelCount, 1)

        now = now.addingTimeInterval(100)
        store.resumeFocus()
        XCTAssertEqual(notifications.scheduled.count, 2)
        XCTAssertEqual(notifications.scheduled.last?.deadline, now.addingTimeInterval(40))

        now = now.addingTimeInterval(40)
        store.refresh()
        XCTAssertEqual(notifications.cancelCount, 2)
        XCTAssertEqual(notifications.fallbackSoundCount, 1)

        store.addMoreFocusTime()
        XCTAssertEqual(notifications.scheduled.count, 3)
        XCTAssertEqual(notifications.scheduled.last?.deadline, now.addingTimeInterval(30))

        store.stopFocus()
        XCTAssertEqual(notifications.cancelCount, 3)
    }

    @MainActor
    func testRolloverPreservesHabitLinksAndDoesNotDuplicateOrResurrectTasks() throws {
        let (repository, directory) = try repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        var now = date("2026-08-27")
        let store = AppStore(repository: repository, calendar: calendar, now: { now })
        let habitID = try XCTUnwrap(store.addHabit(name: "Programming"))
        let linkedTaskID = try XCTUnwrap(store.addTask(title: "Build feature", habitID: habitID))
        let generalTaskID = try XCTUnwrap(store.addTask(title: "Send invoice"))

        now = date("2026-08-29")
        store.refresh()

        XCTAssertEqual(store.todayPlan.tasks.map(\.title), ["Build feature", "Send invoice"])
        XCTAssertEqual(store.todayPlan.tasks.map(\.habitID), [habitID, nil])
        XCTAssertTrue(store.todayPlan.tasks.allSatisfy { !$0.isCompleted })
        XCTAssertTrue(Set(store.todayPlan.tasks.map(\.id)).isDisjoint(with: [linkedTaskID, generalTaskID]))

        let carriedIDs = store.todayPlan.tasks.map(\.id)
        store.refresh()
        XCTAssertEqual(store.todayPlan.tasks.map(\.id), carriedIDs)

        let reopenedStore = AppStore(repository: repository, calendar: calendar, now: { now })
        XCTAssertEqual(reopenedStore.todayPlan.tasks.map(\.id), carriedIDs)

        for taskID in carriedIDs {
            reopenedStore.setTaskCompleted(id: taskID, completed: true)
        }
        now = date("2026-08-30")
        reopenedStore.refresh()

        XCTAssertTrue(reopenedStore.todayPlan.tasks.isEmpty)
        XCTAssertEqual(reopenedStore.state.days["2026-08-29"]?.tasks.count, 2)
        XCTAssertEqual(reopenedStore.state.days["2026-08-27"]?.tasks.count, 2)
    }

    @MainActor
    func testLaterRemovesTasksFromTodayPersistsAndSurvivesRollover() throws {
        let (repository, directory) = try repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        var now = date("2026-08-27")
        let store = AppStore(repository: repository, calendar: calendar, now: { now })
        let habitID = try XCTUnwrap(store.addHabit(name: "Study"))
        let parkedID = try XCTUnwrap(store.addTask(title: "Read chapter", habitID: habitID))
        _ = store.addTask(title: "Send update")

        store.moveTaskToLater(id: parkedID)

        XCTAssertEqual(store.progressText, "0/1")
        XCTAssertEqual(store.todayPlan.tasks.map(\.title), ["Send update"])
        XCTAssertEqual(store.state.laterTasks.map(\.title), ["Read chapter"])
        XCTAssertEqual(store.state.laterTasks.first?.habitID, habitID)

        let reopened = AppStore(repository: repository, calendar: calendar, now: { now })
        XCTAssertEqual(reopened.state.laterTasks.map(\.id), [parkedID])

        now = date("2026-08-28")
        reopened.refresh()
        let carriedTask = try XCTUnwrap(reopened.todayPlan.tasks.first)
        XCTAssertEqual(carriedTask.title, "Send update")
        XCTAssertEqual(reopened.state.laterTasks.map(\.title), ["Read chapter"])

        reopened.moveLaterTaskToToday(id: parkedID, before: carriedTask.id)

        XCTAssertTrue(reopened.state.laterTasks.isEmpty)
        XCTAssertEqual(reopened.todayPlan.tasks.map(\.title), ["Read chapter", "Send update"])
        XCTAssertNotEqual(reopened.todayPlan.tasks.first?.id, parkedID)
        XCTAssertEqual(reopened.todayPlan.tasks.first?.lineageID, parkedID)
        XCTAssertEqual(reopened.todayPlan.tasks.first?.habitID, habitID)
        XCTAssertEqual(reopened.progressText, "0/2")
    }

    @MainActor
    func testMovingFocusedTaskToLaterArchivesTheFocusSession() throws {
        let (repository, directory) = try repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        var now = date("2026-08-27")
        let store = AppStore(repository: repository, calendar: calendar, now: { now })
        let taskID = try XCTUnwrap(store.addTask(title: "Deep work"))
        let task = try XCTUnwrap(store.todayPlan.tasks.first)
        store.updatePomodoroSettings(PomodoroSettings(focusDurationSeconds: 60, extensionDurationSeconds: 30))
        XCTAssertTrue(store.startFocus(on: task))

        now = now.addingTimeInterval(20)
        store.moveTaskToLater(id: taskID)

        XCTAssertEqual(store.focusPresentation, .idle)
        XCTAssertEqual(store.state.pomodoro.records.count, 1)
        XCTAssertEqual(store.state.pomodoro.records.first?.focusedSeconds, 20)
        XCTAssertEqual(store.state.pomodoro.records.first?.outcome, .stopped)
        XCTAssertEqual(store.state.laterTasks.map(\.id), [taskID])
    }

    @MainActor
    func testLinkedTaskCompletionCannotBeLoggedTwiceForTheSameDay() throws {
        let (repository, directory) = try repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(repository: repository, calendar: calendar, now: { self.date("2026-08-27") })
        let habitID = try XCTUnwrap(store.addHabit(name: "Programming", slug: "programming"))
        let taskID = try XCTUnwrap(store.addTask(title: "Study", habitID: habitID))
        store.setTaskCompleted(id: taskID, completed: true)
        store.toggleManualHabitToday(id: habitID)
        XCTAssertEqual(store.state.sessions.count, 1)
        XCTAssertEqual(store.state.sessions.first?.source, .task)

        store.setTaskCompleted(id: taskID, completed: false)
        XCTAssertTrue(store.state.sessions.isEmpty)
    }

    @MainActor
    func testManualCompletionSurvivesUncheckingALinkedTask() throws {
        let (repository, directory) = try repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(repository: repository, calendar: calendar, now: { self.date("2026-08-27") })
        let habitID = try XCTUnwrap(store.addHabit(name: "Programming", slug: "programming"))
        let taskID = try XCTUnwrap(store.addTask(title: "Study", habitID: habitID))

        store.toggleManualHabitToday(id: habitID)
        store.setTaskCompleted(id: taskID, completed: true)
        XCTAssertEqual(store.totalSessions(for: store.state.habits[0]), 1)

        store.setTaskCompleted(id: taskID, completed: false)
        XCTAssertEqual(store.state.sessions.count, 1)
        XCTAssertEqual(store.state.sessions.first?.source, .manual)
    }

    @MainActor
    func testTaskProgressExcludesHabitCompletions() throws {
        let (repository, directory) = try repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(repository: repository, calendar: calendar, now: { self.date("2026-08-27") })
        let habitID = try XCTUnwrap(store.addHabit(name: "Gym"))

        XCTAssertEqual(store.progressText, "0/0")
        XCTAssertEqual(store.menuBarLabel, "0/0 · Plan today")

        let taskID = try XCTUnwrap(store.addTask(title: "General task"))

        XCTAssertEqual(store.progressText, "0/1")
        XCTAssertEqual(store.menuBarLabel, "0/1 · General task")

        store.toggleManualHabitToday(id: habitID)
        XCTAssertEqual(store.completedHabitCount, 1)
        XCTAssertEqual(store.progressText, "0/1")
        XCTAssertEqual(store.menuBarLabel, "0/1 · General task")

        store.setTaskCompleted(id: taskID, completed: true)
        XCTAssertEqual(store.progressText, "1/1")
        XCTAssertEqual(store.menuBarLabel, "1/1 · Done")
    }

    @MainActor
    func testHabitActivityCountsTrackLinkedTasksWithoutDoubleCountingManualCompletion() throws {
        let (repository, directory) = try repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(repository: repository, calendar: calendar, now: { self.date("2026-08-27") })
        let habitID = try XCTUnwrap(store.addHabit(name: "Programming"))
        let firstTaskID = try XCTUnwrap(store.addTask(title: "Build", habitID: habitID))
        let secondTaskID = try XCTUnwrap(store.addTask(title: "Review", habitID: habitID))
        let habit = try XCTUnwrap(store.state.habits.first)

        store.setTaskCompleted(id: firstTaskID, completed: true)
        store.setTaskCompleted(id: secondTaskID, completed: true)
        XCTAssertEqual(store.activityCounts(for: habit)["2026-08-27"], 2)

        store.toggleManualHabitToday(id: habitID)
        XCTAssertEqual(store.activityCounts(for: habit)["2026-08-27"], 2)

        store.setTaskCompleted(id: firstTaskID, completed: false)
        store.setTaskCompleted(id: secondTaskID, completed: false)
        store.toggleManualHabitToday(id: habitID)
        XCTAssertEqual(store.activityCounts(for: habit)["2026-08-27"], 1)
    }

    func testValidReplaceImportPreservesCompletionAndGeneratesStableMissingIDs() throws {
        let habit = Habit(id: "habit-id", slug: "programming", name: "Programming")
        let existing = TaskItem(id: "kept", title: "Old title", habitID: habit.id, isCompleted: true)
        let existingSession = HabitSession(id: "linked-session", habitID: habit.id, date: "2026-08-27", taskID: existing.id, source: .task)
        let state = AppState(days: ["2026-08-27": DayPlan(date: "2026-08-27", tasks: [existing])], habits: [habit], sessions: [existingSession])
        let file = TodayImportFile(date: "2026-08-27", tasks: [
            ImportedTask(id: "kept", title: "New title", habitSlug: "programming"),
            ImportedTask(title: "Generated", habitSlug: "unknown")
        ])
        let data = try encoded(file)

        let first = try TodayImportService.applying(data: data, to: state, calendar: calendar)
        XCTAssertTrue(first.changed)
        XCTAssertEqual(first.state.days["2026-08-27"]?.tasks[0].isCompleted, true)
        XCTAssertEqual(first.state.days["2026-08-27"]?.tasks[0].title, "New title")
        XCTAssertEqual(first.state.sessions.filter { $0.taskID == "kept" }.map(\.id), ["linked-session"])
        let generatedID = try XCTUnwrap(first.state.days["2026-08-27"]?.tasks[1].id)
        XCTAssertNotNil(UUID(uuidString: generatedID))
        XCTAssertNil(first.state.days["2026-08-27"]?.tasks[1].habitID)

        let repeated = try TodayImportService.applying(data: data, to: first.state, calendar: calendar)
        XCTAssertFalse(repeated.changed)
        XCTAssertEqual(repeated.state, first.state)
    }

    func testImportingAParkedTaskMovesItOutOfLater() throws {
        let parkedTask = TaskItem(id: "returning", title: "Old title")
        let state = AppState(laterTasks: [parkedTask])
        let file = TodayImportFile(date: "2026-08-27", tasks: [
            ImportedTask(id: "returning", title: "Back today")
        ])

        let result = try TodayImportService.applying(file: file, to: state, calendar: calendar)

        XCTAssertTrue(result.state.laterTasks.isEmpty)
        XCTAssertEqual(result.state.days["2026-08-27"]?.tasks.map(\.title), ["Back today"])
    }

    func testInvalidImportDoesNotModifyState() throws {
        let state = AppState(days: ["2026-08-27": DayPlan(date: "2026-08-27", tasks: [TaskItem(id: "keep", title: "Keep")])])
        XCTAssertThrowsError(try TodayImportService.applying(data: Data("{invalid".utf8), to: state, calendar: calendar))
        XCTAssertEqual(state.days["2026-08-27"]?.tasks.first?.id, "keep")
    }

    func testDailyStreaksAndBeforeTodayBehavior() {
        let habit = Habit(id: "daily", slug: "daily", name: "Daily")
        let sessions = [
            HabitSession(habitID: habit.id, date: "2026-08-24"),
            HabitSession(habitID: habit.id, date: "2026-08-25"),
            HabitSession(habitID: habit.id, date: "2026-08-27")
        ]
        XCTAssertEqual(StreakCalculator.currentStreak(for: habit, sessions: sessions, today: date("2026-08-27"), calendar: calendar), 1)
        XCTAssertEqual(StreakCalculator.longestStreak(for: habit, sessions: sessions, calendar: calendar), 2)

        let yesterdayOnly = [HabitSession(habitID: habit.id, date: "2026-08-26")]
        XCTAssertEqual(StreakCalculator.currentStreak(for: habit, sessions: yesterdayOnly, today: date("2026-08-27"), calendar: calendar), 1)
    }

    func testWeeklyTargetDistinctDaysCurrentLongestAndLifetimeSessions() {
        let habit = Habit(id: "weekly", slug: "weekly", name: "Weekly", frequency: .weeklyTarget(2))
        let sessions = [
            HabitSession(habitID: habit.id, date: "2026-08-10"),
            HabitSession(habitID: habit.id, date: "2026-08-11"),
            HabitSession(habitID: habit.id, date: "2026-08-17"),
            HabitSession(habitID: habit.id, date: "2026-08-18"),
            HabitSession(habitID: habit.id, date: "2026-08-24"),
            HabitSession(habitID: habit.id, date: "2026-08-24"),
            HabitSession(habitID: habit.id, date: "2026-08-25")
        ]
        let progress = StreakCalculator.weeklyProgress(for: habit, sessions: sessions, today: date("2026-08-27"), calendar: calendar)
        XCTAssertEqual(progress, WeeklyProgress(activeDays: 2, targetDays: 2))
        XCTAssertEqual(progress?.displayedActiveDays, 2)
        XCTAssertEqual(progress?.isComplete, true)
        XCTAssertEqual(StreakCalculator.currentStreak(for: habit, sessions: sessions, today: date("2026-08-27"), calendar: calendar), 3)
        XCTAssertEqual(StreakCalculator.longestStreak(for: habit, sessions: sessions, calendar: calendar), 3)
        XCTAssertEqual(sessions.count, 7, "Duplicate sessions count toward lifetime sessions")
    }

    func testWeeklyProgressCapsItsDisplayAfterTheGoalIsExceeded() {
        let habit = Habit(id: "weekly", slug: "weekly", name: "Weekly", frequency: .weeklyTarget(3))
        let sessions = [
            HabitSession(habitID: habit.id, date: "2026-08-24"),
            HabitSession(habitID: habit.id, date: "2026-08-25"),
            HabitSession(habitID: habit.id, date: "2026-08-26"),
            HabitSession(habitID: habit.id, date: "2026-08-27")
        ]

        let progress = StreakCalculator.weeklyProgress(for: habit, sessions: sessions, today: date("2026-08-27"), calendar: calendar)

        XCTAssertEqual(progress?.activeDays, 4)
        XCTAssertEqual(progress?.displayedActiveDays, 3)
        XCTAssertEqual(progress?.isComplete, true)

        let nextWeek = StreakCalculator.weeklyProgress(for: habit, sessions: sessions, today: date("2026-08-31"), calendar: calendar)
        XCTAssertEqual(nextWeek, WeeklyProgress(activeDays: 0, targetDays: 3))
        XCTAssertEqual(nextWeek?.isComplete, false)
    }

    @MainActor
    func testWeeklyGoalReturnsToInProgressWhenTheFinalManualDayIsUndone() throws {
        let (repository, directory) = try repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        var now = date("2026-08-24")
        let store = AppStore(repository: repository, calendar: calendar, now: { now })
        let habitID = try XCTUnwrap(store.addHabit(name: "Gym", frequency: .weeklyTarget(2)))
        let habit = try XCTUnwrap(store.state.habits.first)

        store.toggleManualHabitToday(id: habitID)
        now = date("2026-08-25")
        store.refresh()
        store.toggleManualHabitToday(id: habitID)
        XCTAssertEqual(store.weeklyProgress(for: habit)?.isComplete, true)

        store.toggleManualHabitToday(id: habitID)
        XCTAssertEqual(store.weeklyProgress(for: habit), WeeklyProgress(activeDays: 1, targetDays: 2))
        XCTAssertEqual(store.weeklyProgress(for: habit)?.isComplete, false)
    }
}

@MainActor
private final class FocusNotificationSchedulerSpy: FocusNotificationScheduling {
    struct ScheduledCompletion {
        let task: FocusTaskReference
        let deadline: Date
    }

    private(set) var scheduled: [ScheduledCompletion] = []
    private(set) var cancelCount = 0
    private(set) var fallbackSoundCount = 0

    func scheduleCompletion(for task: FocusTaskReference, deadline: Date) {
        scheduled.append(ScheduledCompletion(task: task, deadline: deadline))
    }

    func cancelCompletion() {
        cancelCount += 1
    }

    func playFallbackSoundIfNeeded() {
        fallbackSoundCount += 1
    }

    func reset() {
        scheduled = []
        cancelCount = 0
        fallbackSoundCount = 0
    }
}
