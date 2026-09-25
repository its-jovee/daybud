import Foundation
import XCTest
@testable import TodayStack

final class RepeatingTaskTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        value.locale = Locale(identifier: "en_US_POSIX")
        value.firstWeekday = 2
        return value
    }

    private func date(_ key: String) -> Date {
        DateKey.date(from: key, calendar: calendar)!
    }

    private func repository() throws -> (JSONStateRepository, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Daybud-Repeating-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (JSONStateRepository(directoryURL: directory), directory)
    }

    func testScheduleNormalizesDaysAndDescribesItself() throws {
        XCTAssertEqual(RepeatSchedule(days: [6, 2, 2, 9, 0]).days, [2, 6])
        XCTAssertEqual(RepeatSchedule.weekdays.days, [2, 3, 4, 5, 6])
        XCTAssertTrue(RepeatSchedule.weekdays.includes(date("2026-09-04"), calendar: calendar), "Friday")
        XCTAssertFalse(RepeatSchedule.weekdays.includes(date("2026-09-05"), calendar: calendar), "Saturday")
        XCTAssertTrue(RepeatSchedule.weekends.includes(date("2026-09-06"), calendar: calendar), "Sunday")
        XCTAssertEqual(RepeatSchedule.everyDay.label(calendar: calendar), "Every day")
        XCTAssertEqual(RepeatSchedule.weekdays.label(calendar: calendar), "Weekdays")
        XCTAssertEqual(RepeatSchedule(days: [1, 2, 4, 6]).label(calendar: calendar), "Mon, Wed, Fri, Sun")
        XCTAssertEqual(RepeatSchedule.weekOrder(calendar: calendar), [2, 3, 4, 5, 6, 7, 1])
        let decoded = try JSONDecoder().decode(RepeatSchedule.self, from: Data(#"{"days":[7,1,1,12]}"#.utf8))
        XCTAssertEqual(decoded, .weekends)
    }

    @MainActor
    func testDailyRepeatingTaskReturnsFreshAfterBeingFinished() throws {
        let (repository, directory) = try repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        var now = date("2026-09-07")
        let store = AppStore(repository: repository, calendar: calendar, now: { now })

        let gymID = try XCTUnwrap(store.addTask(title: "Gym", durationMinutes: 60, repeatSchedule: .everyDay))
        let routine = try XCTUnwrap(store.state.repeatingTasks.first)
        XCTAssertEqual(routine.title, "Gym")
        XCTAssertEqual(routine.durationMinutes, 60)
        XCTAssertEqual(routine.schedule, .everyDay)
        XCTAssertEqual(store.todayPlan.tasks.map(\.repeatingTaskID), [routine.id])
        store.setTaskCompleted(id: gymID, completed: true)

        now = date("2026-09-08")
        store.refresh()
        let next = try XCTUnwrap(store.todayPlan.tasks.first)
        XCTAssertEqual(store.todayPlan.tasks.count, 1)
        XCTAssertEqual(next.title, "Gym")
        XCTAssertFalse(next.isCompleted)
        XCTAssertEqual(next.durationMinutes, 60)
        XCTAssertEqual(next.repeatingTaskID, routine.id)
        XCTAssertNotEqual(next.id, gymID)
        XCTAssertNotEqual(next.lineageID, gymID, "Each day's occurrence is its own piece of work")
        XCTAssertEqual(store.state.days["2026-09-07"]?.tasks.map(\.isCompleted), [true])

        let reopened = AppStore(repository: repository, calendar: calendar, now: { now })
        XCTAssertEqual(reopened.state.repeatingTasks, store.state.repeatingTasks)
        XCTAssertEqual(reopened.todayPlan.tasks.map(\.id), [next.id], "Reopening does not add a second occurrence")
    }

    @MainActor
    func testUnfinishedRepeatingTaskIsReplacedWhileOtherTasksCarryOver() throws {
        let (repository, directory) = try repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        var now = date("2026-09-07")
        let store = AppStore(repository: repository, calendar: calendar, now: { now })
        let invoiceID = try XCTUnwrap(store.addTask(title: "Send invoice"))
        let gymID = try XCTUnwrap(store.addTask(title: "Gym", repeatSchedule: .everyDay))

        now = date("2026-09-08")
        store.refresh()

        XCTAssertEqual(store.todayPlan.tasks.map(\.title), ["Gym", "Send invoice"])
        XCTAssertEqual(store.todayPlan.tasks.last?.lineageID, invoiceID)
        XCTAssertNotEqual(store.todayPlan.tasks.first?.lineageID, gymID)
        store.refresh()
        XCTAssertEqual(store.todayPlan.tasks.count, 2)
    }

    @MainActor
    func testWeekdayRepeatingTaskSkipsTheWeekend() throws {
        let (repository, directory) = try repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        var now = date("2026-09-04") // Friday
        let store = AppStore(repository: repository, calendar: calendar, now: { now })
        let habitID = try XCTUnwrap(store.addHabit(name: "Work"))
        _ = try XCTUnwrap(store.addTask(title: "Work", habitID: habitID, repeatSchedule: .weekdays))

        for weekend in ["2026-09-05", "2026-09-06"] {
            now = date(weekend)
            store.refresh()
            XCTAssertTrue(store.todayPlan.tasks.isEmpty, "\(weekend) has no Work task, not even Friday's leftover")
        }

        now = date("2026-09-07") // Monday
        store.refresh()
        XCTAssertEqual(store.todayPlan.tasks.map(\.title), ["Work"])
        XCTAssertEqual(store.todayPlan.tasks.first?.habitID, habitID)
    }

    @MainActor
    func testEditingTodaysCopyUpdatesTheRepeatingTask() throws {
        let (repository, directory) = try repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        var now = date("2026-09-07") // Monday
        let store = AppStore(repository: repository, calendar: calendar, now: { now })
        let studyID = try XCTUnwrap(store.addHabit(name: "Study"))
        let taskID = try XCTUnwrap(store.addTask(title: "Read", repeatSchedule: .everyDay))

        store.updateTaskTitle(id: taskID, title: "Read a chapter")
        store.setTaskHabit(id: taskID, habitID: studyID)
        store.updateTaskDuration(id: taskID, durationMinutes: 45)
        XCTAssertTrue(store.setTaskRepeat(id: taskID, schedule: RepeatSchedule(days: [2, 4])))

        XCTAssertEqual(store.state.repeatingTasks.count, 1)
        let routine = try XCTUnwrap(store.state.repeatingTasks.first)
        XCTAssertEqual(routine.title, "Read a chapter")
        XCTAssertEqual(routine.habitID, studyID)
        XCTAssertEqual(routine.durationMinutes, 45)
        XCTAssertEqual(routine.schedule.days, [2, 4])

        now = date("2026-09-08") // Tuesday
        store.refresh()
        XCTAssertTrue(store.todayPlan.tasks.isEmpty)

        now = date("2026-09-09") // Wednesday
        store.refresh()
        let next = try XCTUnwrap(store.todayPlan.tasks.first)
        XCTAssertEqual(next.title, "Read a chapter")
        XCTAssertEqual(next.habitID, studyID)
        XCTAssertEqual(next.durationMinutes, 45)
    }

    @MainActor
    func testSkippingKeepsTheRoutineAndStoppingKeepsTodaysCopy() throws {
        let (repository, directory) = try repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        var now = date("2026-09-07")
        let store = AppStore(repository: repository, calendar: calendar, now: { now })
        let gymID = try XCTUnwrap(store.addTask(title: "Gym", repeatSchedule: .everyDay))
        let readID = try XCTUnwrap(store.addTask(title: "Read", repeatSchedule: .everyDay))

        store.deleteTask(id: gymID) // "Skip today"
        XCTAssertEqual(store.state.repeatingTasks.map(\.title), ["Gym", "Read"])

        XCTAssertTrue(store.setTaskRepeat(id: readID, schedule: nil))
        XCTAssertEqual(store.state.repeatingTasks.map(\.title), ["Gym"])
        XCTAssertEqual(store.todayPlan.tasks.map(\.title), ["Read"])
        XCTAssertEqual(store.todayPlan.tasks.map(\.repeatingTaskID), [nil])

        now = date("2026-09-08")
        store.refresh()
        XCTAssertEqual(store.todayPlan.tasks.map(\.title), ["Gym", "Read"], "Gym returns; Read carries over once as a one-off")
        XCTAssertEqual(store.todayPlan.tasks.last?.lineageID, readID)

        let gymRoutineID = try XCTUnwrap(store.state.repeatingTasks.first?.id)
        XCTAssertTrue(store.stopRepeatingTask(id: gymRoutineID))
        XCTAssertTrue(store.state.repeatingTasks.isEmpty)
        XCTAssertTrue(store.todayPlan.tasks.allSatisfy { $0.repeatingTaskID == nil })
    }

    @MainActor
    func testParkingARepeatingTaskInLaterKeepsTheRoutineGoing() throws {
        let (repository, directory) = try repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        var now = date("2026-09-07")
        let store = AppStore(repository: repository, calendar: calendar, now: { now })
        let gymID = try XCTUnwrap(store.addTask(title: "Gym", repeatSchedule: .everyDay))

        store.moveTaskToLater(id: gymID)
        XCTAssertEqual(store.state.laterTasks.map(\.repeatingTaskID), [nil])
        XCTAssertEqual(store.state.repeatingTasks.count, 1)

        now = date("2026-09-08")
        store.refresh()
        XCTAssertEqual(store.todayPlan.tasks.map(\.title), ["Gym"])
        XCTAssertEqual(store.state.laterTasks.map(\.id), [gymID])
    }

    @MainActor
    func testRepeatingMainQuestActionEarnsEachDayUntilTheQuestIsArchived() throws {
        let (repository, directory) = try repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        var now = date("2026-09-07")
        let store = AppStore(repository: repository, calendar: calendar, now: { now })
        let quest = MainQuest(title: "Write a book")
        XCTAssertTrue(store.saveQuest(quest))
        let habitID = try XCTUnwrap(store.addHabit(name: "Write"))
        let firstID = try XCTUnwrap(store.addTask(
            title: "Write 500 words",
            habitID: habitID,
            purpose: .mainQuest(quest.id),
            repeatSchedule: .everyDay
        ))
        store.setTaskCompleted(id: firstID, completed: true)
        XCTAssertEqual(store.state.questSystem.balance, 11)

        now = date("2026-09-08")
        store.refresh()
        let second = try XCTUnwrap(store.todayPlan.tasks.first)
        XCTAssertEqual(second.purpose, .mainQuest(quest.id))
        XCTAssertEqual(second.habitID, habitID)
        store.setTaskCompleted(id: second.id, completed: true)
        XCTAssertEqual(store.state.questSystem.balance, 22)

        XCTAssertTrue(store.setQuestStatus(id: quest.id, status: .archived))
        store.deleteHabit(id: habitID)
        XCTAssertEqual(store.state.repeatingTasks.count, 1)
        XCTAssertNil(store.state.repeatingTasks.first?.habitID)

        now = date("2026-09-09")
        store.refresh()
        let third = try XCTUnwrap(store.todayPlan.tasks.first)
        XCTAssertEqual(third.purpose, .regular)
        XCTAssertNil(third.habitID)
    }

    @MainActor
    func testEditingTheRepeatingTaskUpdatesTodaysUnfinishedCopy() throws {
        let (repository, directory) = try repository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppStore(repository: repository, calendar: calendar, now: { self.date("2026-09-07") })
        let taskID = try XCTUnwrap(store.addTask(title: "Stretch", repeatSchedule: .everyDay))

        var routine = try XCTUnwrap(store.state.repeatingTasks.first)
        routine.title = "  Stretch & mobility  "
        routine.durationMinutes = 15
        routine.schedule = .weekdays
        XCTAssertTrue(store.updateRepeatingTask(routine))
        XCTAssertEqual(store.state.repeatingTasks.first?.title, "Stretch & mobility")
        XCTAssertEqual(store.state.repeatingTasks.first?.schedule, .weekdays)
        let todaysCopy = try XCTUnwrap(store.todayPlan.tasks.first(where: { $0.id == taskID }))
        XCTAssertEqual(todaysCopy.title, "Stretch & mobility")
        XCTAssertEqual(todaysCopy.durationMinutes, 15)

        let baseline = store.state
        routine.title = " "
        XCTAssertFalse(store.updateRepeatingTask(routine))
        routine.title = "Stretch"
        routine.schedule = RepeatSchedule(days: [Int]())
        XCTAssertFalse(store.updateRepeatingTask(routine))
        XCTAssertFalse(store.setTaskRepeat(id: taskID, schedule: RepeatSchedule(days: [Int]())))
        XCTAssertEqual(store.state, baseline)
        XCTAssertNotNil(store.errorMessage)
    }

    func testImportKeepsTheRepeatingLinkOfAMatchingTask() throws {
        let routine = RepeatingTask(id: "routine", title: "Gym", schedule: .everyDay)
        let occurrence = TaskItem(id: "gym", title: "Gym", repeatingTaskID: routine.id)
        let state = AppState(
            days: ["2026-09-07": DayPlan(date: "2026-09-07", tasks: [occurrence])],
            repeatingTasks: [routine]
        )
        let file = TodayImportFile(date: "2026-09-07", tasks: [ImportedTask(id: "gym", title: "Gym session")])

        let result = try TodayImportService.applying(file: file, to: state, calendar: calendar)

        XCTAssertEqual(result.state.days["2026-09-07"]?.tasks.first?.repeatingTaskID, "routine")
        XCTAssertEqual(try JSONDecoder().decode(AppState.self, from: JSONEncoder().encode(result.state)), result.state)
    }
}
