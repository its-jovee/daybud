import Foundation
import XCTest
@testable import TodayStack

final class StatisticsCalculatorTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    private func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)!
    }

    func testSevenDayRangeIsInclusiveAndExcludesMalformedAndFutureDays() {
        let habit = Habit(id: "work", slug: "work", name: "Work")
        let state = AppState(
            days: [
                "2026-08-25": completedPlan("2026-08-25", habitID: habit.id),
                "2026-08-26": completedPlan("2026-08-26", habitID: habit.id),
                "2026-08-31": completedPlan("2026-08-31", habitID: nil),
                "2026-09-01": completedPlan("2026-09-01", habitID: habit.id),
                "2026-09-02": completedPlan("2026-09-02", habitID: habit.id),
                "not-a-date": completedPlan("not-a-date", habitID: habit.id)
            ],
            habits: [habit]
        )

        let snapshot = StatisticsCalculator.snapshot(
            state: state,
            focusRecords: [],
            period: .sevenDays,
            today: date("2026-09-01T15:00:00Z"),
            calendar: calendar
        )

        XCTAssertEqual(snapshot.startDateKey, "2026-08-26")
        XCTAssertEqual(snapshot.endDateKey, "2026-09-01")
        XCTAssertEqual(snapshot.completedTasks, 3)
        XCTAssertEqual(snapshot.activeDays, 3)
        XCTAssertEqual(snapshot.groups.first(where: { $0.groupID == .habit("work") })?.completedTasks, 2)
        XCTAssertEqual(snapshot.groups.first(where: { $0.groupID == .general })?.completedTasks, 1)
    }

    func testThirtyDaysAndAllTimeUseExpectedLowerBounds() {
        let state = AppState(days: [
            "2026-08-02": completedPlan("2026-08-02", habitID: nil),
            "2026-08-03": completedPlan("2026-08-03", habitID: nil),
            "2026-09-01": completedPlan("2026-09-01", habitID: nil)
        ])
        let today = date("2026-09-01T10:00:00Z")

        let thirtyDays = StatisticsCalculator.snapshot(
            state: state,
            focusRecords: [],
            period: .thirtyDays,
            today: today,
            calendar: calendar
        )
        let allTime = StatisticsCalculator.snapshot(
            state: state,
            focusRecords: [],
            period: .allTime,
            today: today,
            calendar: calendar
        )

        XCTAssertEqual(thirtyDays.startDateKey, "2026-08-03")
        XCTAssertEqual(thirtyDays.completedTasks, 2)
        XCTAssertNil(allTime.startDateKey)
        XCTAssertEqual(allTime.completedTasks, 3)
    }

    func testFocusUsesActualStartDateAndHabitSnapshotWithoutInferringTime() {
        let focusRecords = [
            focusRecord(
                id: "included",
                startedAt: "2026-09-01T09:00:00Z",
                seconds: 1_500,
                habitID: "deleted-habit",
                habitName: "Deep Work"
            ),
            focusRecord(
                id: "stopped",
                startedAt: "2026-09-01T11:00:00Z",
                seconds: 300,
                habitID: nil,
                habitName: nil,
                outcome: .stopped
            ),
            focusRecord(
                id: "zero",
                startedAt: "2026-09-01T12:00:00Z",
                seconds: 0,
                habitID: "deleted-habit",
                habitName: "Deep Work"
            ),
            focusRecord(
                id: "outside",
                startedAt: "2026-08-25T23:59:59Z",
                seconds: 9_999,
                habitID: "deleted-habit",
                habitName: "Deep Work"
            )
        ]

        let snapshot = StatisticsCalculator.snapshot(
            state: AppState(),
            focusRecords: focusRecords,
            period: .sevenDays,
            today: date("2026-09-01T15:00:00Z"),
            calendar: calendar
        )

        XCTAssertEqual(snapshot.focusedSeconds, 1_800)
        XCTAssertEqual(snapshot.activeDays, 1)
        XCTAssertEqual(snapshot.groups.first(where: { $0.groupID == .habit("deleted-habit") })?.title, "Deep Work")
        XCTAssertEqual(snapshot.groups.first(where: { $0.groupID == .habit("deleted-habit") })?.focusedSeconds, 1_500)
        XCTAssertEqual(snapshot.groups.first(where: { $0.groupID == .general })?.focusedSeconds, 300)
    }

    func testActiveDaysAreUnionOfCompletedTaskAndFocusDays() {
        let state = AppState(days: [
            "2026-08-31": completedPlan("2026-08-31", habitID: nil),
            "2026-09-01": completedPlan("2026-09-01", habitID: nil)
        ])
        let records = [
            focusRecord(id: "same-day", startedAt: "2026-09-01T09:00:00Z", seconds: 600),
            focusRecord(id: "focus-only-day", startedAt: "2026-08-30T09:00:00Z", seconds: 600)
        ]

        let snapshot = StatisticsCalculator.snapshot(
            state: state,
            focusRecords: records,
            period: .sevenDays,
            today: date("2026-09-01T15:00:00Z"),
            calendar: calendar
        )

        XCTAssertEqual(snapshot.completedTasks, 2)
        XCTAssertEqual(snapshot.focusedSeconds, 1_200)
        XCTAssertEqual(snapshot.activeDays, 3)
    }

    func testRankingIsDeterministicAndAlwaysPlacesGeneralAfterTopFiveHabits() {
        let groups = [
            StatisticsGroup(groupID: .habit("z"), title: "Beta", completedTasks: 4, focusedSeconds: 30),
            StatisticsGroup(groupID: .habit("a"), title: "alpha", completedTasks: 4, focusedSeconds: 10),
            StatisticsGroup(groupID: .habit("b"), title: "Alpha", completedTasks: 4, focusedSeconds: 20),
            StatisticsGroup(groupID: .habit("c"), title: "Charlie", completedTasks: 3, focusedSeconds: 60),
            StatisticsGroup(groupID: .habit("d"), title: "Delta", completedTasks: 2, focusedSeconds: 50),
            StatisticsGroup(groupID: .habit("e"), title: "Echo", completedTasks: 1, focusedSeconds: 40),
            StatisticsGroup(groupID: .habit("f"), title: "Foxtrot", completedTasks: 1, focusedSeconds: 70),
            StatisticsGroup(groupID: .general, title: "General", completedTasks: 99, focusedSeconds: 99)
        ]
        let snapshot = StatisticsSnapshot(
            period: .allTime,
            startDateKey: nil,
            endDateKey: "2026-09-01",
            completedTasks: 118,
            focusedSeconds: 380,
            activeDays: 1,
            groups: groups
        )

        XCTAssertEqual(
            snapshot.topGroups(for: .tasks).map(\.id),
            ["habit:a", "habit:b", "habit:z", "habit:c", "habit:d", "general"]
        )
        XCTAssertEqual(
            snapshot.topGroups(for: .focus).map(\.id),
            ["habit:f", "habit:c", "habit:d", "habit:e", "habit:z", "general"]
        )
    }

    private func completedPlan(_ dateKey: String, habitID: String?) -> DayPlan {
        DayPlan(
            date: dateKey,
            tasks: [TaskItem(id: "task-\(dateKey)", title: "Done", habitID: habitID, isCompleted: true)]
        )
    }

    private func focusRecord(
        id: String,
        startedAt: String,
        seconds: Int,
        habitID: String? = nil,
        habitName: String? = nil,
        outcome: FocusOutcome = .completedTask
    ) -> FocusRecord {
        let start = date(startedAt)
        return FocusRecord(
            id: id,
            task: FocusTaskReference(
                occurrenceID: "occurrence-\(id)",
                lineageID: "lineage-\(id)",
                dateKey: "1999-01-01",
                titleSnapshot: "Task \(id)",
                habitIDSnapshot: habitID,
                habitNameSnapshot: habitName
            ),
            startedAt: start,
            endedAt: start.addingTimeInterval(TimeInterval(max(0, seconds))),
            focusedSeconds: seconds,
            extensionCount: 0,
            outcome: outcome
        )
    }
}
