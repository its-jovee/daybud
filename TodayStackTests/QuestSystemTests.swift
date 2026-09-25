import Foundation
import XCTest
@testable import TodayStack

final class QuestSystemTests: XCTestCase {
    private let day = "2026-09-05"
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        value.firstWeekday = 2
        return value
    }
    private var now: Date { DateKey.date(from: day, calendar: calendar)! }

    func testTwoActiveQuestLimitAndDemotion() throws {
        var state = AppState()
        let first = MainQuest(title: "First outcome")
        let second = MainQuest(title: "Second outcome")
        let third = MainQuest(title: "Third outcome")
        try QuestEngine.saveQuest(first, state: &state)
        try QuestEngine.saveQuest(second, state: &state)
        XCTAssertThrowsError(try QuestEngine.saveQuest(third, state: &state)) {
            XCTAssertEqual($0.localizedDescription, QuestEngine.twoQuestMessage)
        }
        let task = TaskItem(title: "Action", purpose: .mainQuest(first.id))
        state.days[day] = DayPlan(date: day, tasks: [task])
        state.laterTasks = [TaskItem(title: "Parked action", purpose: .mainQuest(first.id))]
        try QuestEngine.setStatus(id: first.id, status: .archived, demoteTasks: true, date: day, now: now, state: &state)
        XCTAssertEqual(state.days[day]?.tasks.first?.purpose, .sidequest)
        XCTAssertEqual(state.laterTasks.first?.purpose, .sidequest)
        try QuestEngine.saveQuest(third, state: &state)
        XCTAssertThrowsError(try QuestEngine.setStatus(id: first.id, status: .active, date: day, now: now, state: &state))
        XCTAssertEqual(state.questSystem.activeQuests.count, 2)
    }

    func testTaskRewardsUseLineageAndSurviveUndoReclassification() throws {
        var state = AppState()
        let quest = MainQuest(title: "Outcome")
        try QuestEngine.saveQuest(quest, state: &state)
        var task = TaskItem(title: "Action", isCompleted: true, purpose: .mainQuest(quest.id))
        QuestEngine.recordTask(task, date: day, now: now, state: &state)
        task.isCompleted = false
        QuestEngine.recordTask(task, date: day, now: now, state: &state)
        task.isCompleted = true
        task.purpose = .sidequest
        QuestEngine.recordTask(task, date: day, now: now, state: &state)
        let carried = TaskItem(lineageID: task.lineageID, title: "Carried action", isCompleted: true, purpose: .mainQuest(quest.id))
        QuestEngine.recordTask(carried, date: "2026-09-06", now: now, state: &state)
        XCTAssertEqual(state.questSystem.balance, 10)
        XCTAssertEqual(state.questSystem.activities.count, 1)
        XCTAssertEqual(state.questSystem.activities.first?.kind, .mainAction)
    }

    func testRegularAndHabitRewardsStaySeparateAndDoNotFarm() throws {
        let habit = Habit(slug: "study", name: "Study")
        var state = AppState(habits: [habit])
        var task = TaskItem(title: "Study", habitID: habit.id, isCompleted: true)
        QuestEngine.recordTask(task, date: day, now: now, state: &state)
        task.purpose = .sidequest
        QuestEngine.recordTask(task, date: day, now: now, state: &state)
        QuestEngine.recordHabit(habit.id, date: day, now: now, state: &state)
        XCTAssertEqual(state.questSystem.balance, 1)
        XCTAssertTrue(state.questSystem.activities.isEmpty)
        QuestEngine.recordTask(TaskItem(title: "Optional action", isCompleted: true, purpose: .sidequest), date: day, now: now, state: &state)
        XCTAssertEqual(state.questSystem.balance, 3)
        XCTAssertFalse(state.questSystem.activities.first!.isMainProgress)
    }

    func testMeasurableProgressDailyCapAndHighWaterAcrossDays() throws {
        var state = AppState()
        var quest = MainQuest(title: "Outcome")
        quest.currentValue = 10
        quest.targetValue = 100
        try QuestEngine.saveQuest(quest, state: &state)
        for value in [20.0, 25, 5, 25] {
            try QuestEngine.updateProgress(id: quest.id, value: value, date: day, now: now, state: &state)
        }
        XCTAssertEqual(state.questSystem.balance, 10)
        XCTAssertEqual(state.questSystem.activities.count, 2)
        try QuestEngine.updateProgress(id: quest.id, value: 5, date: "2026-09-06", now: now, state: &state)
        try QuestEngine.updateProgress(id: quest.id, value: 25, date: "2026-09-06", now: now, state: &state)
        XCTAssertEqual(state.questSystem.balance, 10)
        try QuestEngine.updateProgress(id: quest.id, value: 30, date: "2026-09-06", now: now, state: &state)
        XCTAssertEqual(state.questSystem.balance, 20)
        XCTAssertThrowsError(try QuestEngine.updateProgress(id: quest.id, value: .infinity, date: day, now: now, state: &state))
        XCTAssertThrowsError(try QuestEngine.updateProgress(id: quest.id, value: -1, date: day, now: now, state: &state))
        var edited = state.questSystem.quests[0]
        edited.currentValue = 90
        try QuestEngine.saveQuest(edited, state: &state)
        XCTAssertEqual(state.questSystem.quests[0].currentValue, 30)
    }

    func testQuestCompletionOnceAndRedemptionIdempotency() throws {
        var state = AppState()
        let quest = MainQuest(title: "Outcome")
        try QuestEngine.saveQuest(quest, state: &state)
        QuestEngine.recordTask(TaskItem(title: "Action", isCompleted: true, purpose: .mainQuest(quest.id)), date: day, now: now, state: &state)
        try QuestEngine.setStatus(id: quest.id, status: .completed, date: day, now: now, state: &state)
        XCTAssertEqual(state.questSystem.balance, 60)
        try QuestEngine.setStatus(id: quest.id, status: .active, date: day, now: now, state: &state)
        try QuestEngine.setStatus(id: quest.id, status: .completed, date: day, now: now, state: &state)
        XCTAssertEqual(state.questSystem.balance, 60)
        try QuestEngine.redeem(id: QuestReward.gaming.id, requestID: "once", date: day, now: now, state: &state)
        try QuestEngine.redeem(id: QuestReward.gaming.id, requestID: "once", date: day, now: now, state: &state)
        XCTAssertEqual(state.questSystem.balance, 0)
        XCTAssertEqual(state.questSystem.transactions.filter { $0.amount < 0 }.count, 1)
        XCTAssertThrowsError(try QuestEngine.redeem(id: QuestReward.gaming.id, requestID: "twice", date: day, now: now, state: &state))
        var renamed = QuestReward.gaming
        renamed.name = "Different reward"
        renamed.price = 20
        try QuestEngine.saveReward(renamed, state: &state)
        XCTAssertTrue(state.questSystem.transactions.last!.title.contains("1 hour gaming"))
        XCTAssertEqual(state.questSystem.transactions.last!.amount, -60)
        XCTAssertEqual(try JSONDecoder().decode(AppState.self, from: JSONEncoder().encode(state)), state)
    }

    func testVersionFourMigrationClaimsOldCompletionsWithoutRetroactiveCoins() throws {
        let legacy = Data(#"""
        {"schemaVersion":4,"days":{"2026-09-05":{"date":"2026-09-05","tasks":[{"id":"old","title":"Old task","isCompleted":true,"durationMinutes":40}]}},"sessions":[{"id":"session","habitID":"habit","date":"2026-09-05","source":"manual"}]}
        """#.utf8)
        let state = try JSONDecoder().decode(AppState.self, from: legacy)
        XCTAssertEqual(state.schemaVersion, 5)
        XCTAssertEqual(state.days[day]?.tasks.first?.durationMinutes, 40)
        XCTAssertEqual(state.days[day]?.tasks.first?.purpose, .regular)
        XCTAssertEqual(state.questSystem.claimedTasks, ["old"])
        XCTAssertEqual(state.questSystem.claimedHabitDays, ["habit:2026-09-05"])
        XCTAssertEqual(state.questSystem.balance, 0)
        XCTAssertEqual(state.questSystem.rewards, [.gaming])
        XCTAssertTrue(state.questSystem.quests.isEmpty)
    }

    @MainActor
    func testCompleteUserFlowPersistsAndUnlocksSidequests() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Daybud-QuestFlow-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = JSONStateRepository(directoryURL: directory)
        let store = AppStore(repository: repository, calendar: calendar, now: { self.now })
        var quest = MainQuest(title: "A real outcome")
        quest.targetValue = 2
        XCTAssertTrue(store.saveQuest(quest))
        XCTAssertFalse(store.hasMainProgressToday)
        for i in 1...6 {
            let id = try XCTUnwrap(store.addTask(title: "Concrete action \(i)"))
            XCTAssertTrue(store.assignTask(id: id, purpose: .mainQuest(quest.id)))
            store.setTaskCompleted(id: id, completed: true)
        }
        XCTAssertTrue(store.hasMainProgressToday)
        XCTAssertEqual(store.mainQuestStreak, 1)
        XCTAssertEqual(store.state.questSystem.balance, 60)
        XCTAssertTrue(store.redeemReward(id: QuestReward.gaming.id, requestID: "flow"))
        XCTAssertEqual(store.state.questSystem.balance, 0)
        XCTAssertTrue(store.updateQuestProgress(id: quest.id, value: 1))
        XCTAssertTrue(store.setQuestStatus(id: quest.id, status: .completed))
        XCTAssertEqual(store.state.questSystem.balance, 60)
        let reopened = AppStore(repository: repository, calendar: calendar, now: { self.now })
        XCTAssertEqual(reopened.state, store.state)
        XCTAssertEqual(reopened.state.questSystem.transactions.count, 9)
        XCTAssertEqual(reopened.state.questSystem.quests.first?.status, .completed)
    }

    @MainActor
    func testLaterRolloverPomodoroAndStreakUseExistingTaskIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Daybud-QuestCarry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = JSONStateRepository(directoryURL: directory)
        let store = AppStore(repository: repository, calendar: calendar, now: { self.now })
        let quest = MainQuest(title: "Outcome")
        XCTAssertTrue(store.saveQuest(quest))
        let id = try XCTUnwrap(store.addTask(title: "Action", durationMinutes: 60, purpose: .mainQuest(quest.id)))
        store.moveTaskToLater(id: id)
        store.moveLaterTaskToToday(id: id)
        let restored = try XCTUnwrap(store.todayPlan.tasks.first)
        XCTAssertEqual(restored.purpose, .mainQuest(quest.id))
        XCTAssertEqual(restored.durationMinutes, 60)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
        let next = AppStore(repository: repository, calendar: calendar, now: { tomorrow })
        let carried = try XCTUnwrap(next.todayPlan.tasks.first)
        XCTAssertEqual(carried.lineageID, restored.lineageID)
        XCTAssertEqual(carried.purpose, .mainQuest(quest.id))
        XCTAssertTrue(next.startFocus(on: carried))
        next.markFocusedTaskDone()
        XCTAssertEqual(next.state.questSystem.balance, 10)
        XCTAssertTrue(next.hasMainProgressToday)
        XCTAssertEqual(next.mainQuestStreak, 1)
        next.setTaskCompleted(id: carried.id, completed: false)
        next.setTaskCompleted(id: carried.id, completed: true)
        XCTAssertEqual(next.state.questSystem.balance, 10)
    }

    @MainActor
    func testFailedSaveDoesNotSpendOrComplete() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Daybud-QuestFailure-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = JSONStateRepository(directoryURL: directory)
        let store = AppStore(repository: repository, calendar: calendar, now: { self.now })
        let quest = MainQuest(title: "Outcome")
        XCTAssertTrue(store.saveQuest(quest))
        let id = try XCTUnwrap(store.addTask(title: "Action", purpose: .mainQuest(quest.id)))
        let fundingID = try XCTUnwrap(store.addTask(title: "Earlier action", purpose: .mainQuest(quest.id)))
        store.setTaskCompleted(id: fundingID, completed: true)
        XCTAssertTrue(store.setQuestStatus(id: quest.id, status: .completed))
        XCTAssertTrue(store.setQuestStatus(id: quest.id, status: .active))
        XCTAssertEqual(store.state.questSystem.balance, 60)
        let baseline = store.state
        // A file at the repository directory prevents atomic saves, even when tests run as root.
        try FileManager.default.removeItem(at: directory)
        try Data("not a directory".utf8).write(to: directory)
        store.setTaskCompleted(id: id, completed: true)
        XCTAssertEqual(store.state, baseline)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertFalse(store.setQuestStatus(id: quest.id, status: .completed))
        XCTAssertFalse(store.redeemReward(id: QuestReward.gaming.id, requestID: "failed-save"))
        XCTAssertEqual(store.state, baseline)
    }

    func testInvalidAssignmentsAndRewardValuesLeaveStateUnchanged() throws {
        var state = AppState()
        let task = TaskItem(title: "Regular task")
        state.days[day] = DayPlan(date: day, tasks: [task])
        let baseline = state
        XCTAssertThrowsError(try QuestEngine.assign(taskID: task.id, purpose: .mainQuest("missing"), date: day, state: &state))
        XCTAssertThrowsError(try QuestEngine.saveReward(QuestReward(name: "Invalid", price: -20), state: &state))
        XCTAssertThrowsError(try QuestEngine.saveQuest(MainQuest(title: "  "), state: &state))
        XCTAssertEqual(state, baseline)
    }

    @MainActor
    func testMainQuestStreakCountsDistinctDaysAndBreaksAfterMissedDay() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Daybud-QuestStreak-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = JSONStateRepository(directoryURL: directory)
        let quest = MainQuest(title: "Outcome")
        var initial = AppState()
        try QuestEngine.saveQuest(quest, state: &initial)
        for date in ["2026-09-03", "2026-09-04", "2026-09-04"] {
            QuestEngine.recordTask(TaskItem(title: "Action", isCompleted: true, purpose: .mainQuest(quest.id)), date: date, now: now, state: &initial)
        }
        try repository.save(initial)
        let store = AppStore(repository: repository, calendar: calendar, now: { self.now })
        XCTAssertEqual(store.mainQuestStreak, 2)
        XCTAssertFalse(store.hasMainProgressToday)
        let id = try XCTUnwrap(store.addTask(title: "Today action", purpose: .mainQuest(quest.id)))
        store.setTaskCompleted(id: id, completed: true)
        XCTAssertEqual(store.mainQuestStreak, 3)
        let afterGap = DateKey.date(from: "2026-09-07", calendar: calendar)!
        let reopened = AppStore(repository: repository, calendar: calendar, now: { afterGap })
        XCTAssertEqual(reopened.mainQuestStreak, 0)
        XCTAssertFalse(reopened.hasMainProgressToday)
    }
}
