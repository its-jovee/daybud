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
        XCTAssertTrue(store.todayPlan.tasks.isEmpty)
        XCTAssertEqual(store.state.days["2026-08-27"]?.tasks.count, 3)
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
    func testLoggedHabitsCountTowardOverallProgress() throws {
        let (repository, directory) = try repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(repository: repository, calendar: calendar, now: { self.date("2026-08-27") })
        let habitID = try XCTUnwrap(store.addHabit(name: "Gym"))
        let taskID = try XCTUnwrap(store.addTask(title: "General task"))

        XCTAssertEqual(store.progressText, "0/2")
        XCTAssertEqual(store.menuBarLabel, "0/2 · General task")

        store.toggleManualHabitToday(id: habitID)
        XCTAssertEqual(store.progressText, "1/2")

        store.setTaskCompleted(id: taskID, completed: true)
        XCTAssertEqual(store.progressText, "2/2")
        XCTAssertEqual(store.menuBarLabel, "2/2 · Done")
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
        XCTAssertEqual(StreakCalculator.currentStreak(for: habit, sessions: sessions, today: date("2026-08-27"), calendar: calendar), 3)
        XCTAssertEqual(StreakCalculator.longestStreak(for: habit, sessions: sessions, calendar: calendar), 3)
        XCTAssertEqual(sessions.count, 7, "Duplicate sessions count toward lifetime sessions")
    }
}
