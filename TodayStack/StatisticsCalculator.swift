import Foundation

public enum StatisticsPeriod: String, CaseIterable, Identifiable, Sendable {
    case sevenDays
    case thirtyDays
    case allTime

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .sevenDays: "7 days"
        case .thirtyDays: "30 days"
        case .allTime: "All"
        }
    }

    fileprivate var dayCount: Int? {
        switch self {
        case .sevenDays: 7
        case .thirtyDays: 30
        case .allTime: nil
        }
    }
}

public enum StatisticsMetric: String, CaseIterable, Identifiable, Sendable {
    case tasks
    case focus

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .tasks: "Tasks"
        case .focus: "Focus"
        }
    }
}

public enum StatisticsGroupID: Hashable, Sendable {
    case habit(String)
    case general

    public var rawValue: String {
        switch self {
        case .habit(let habitID): "habit:\(habitID)"
        case .general: "general"
        }
    }
}

public struct StatisticsGroup: Equatable, Identifiable, Sendable {
    public let groupID: StatisticsGroupID
    public let title: String
    public let completedTasks: Int
    public let focusedSeconds: Int

    public var id: String { groupID.rawValue }

    public init(
        groupID: StatisticsGroupID,
        title: String,
        completedTasks: Int,
        focusedSeconds: Int
    ) {
        self.groupID = groupID
        self.title = title
        self.completedTasks = completedTasks
        self.focusedSeconds = focusedSeconds
    }

    public func value(for metric: StatisticsMetric) -> Int {
        switch metric {
        case .tasks: completedTasks
        case .focus: focusedSeconds
        }
    }
}

public struct StatisticsSnapshot: Equatable, Sendable {
    public let period: StatisticsPeriod
    public let startDateKey: String?
    public let endDateKey: String
    public let completedTasks: Int
    public let focusedSeconds: Int
    /// A day is active when it has a completed task or recorded focus time.
    public let activeDays: Int
    public let groups: [StatisticsGroup]

    public init(
        period: StatisticsPeriod,
        startDateKey: String?,
        endDateKey: String,
        completedTasks: Int,
        focusedSeconds: Int,
        activeDays: Int,
        groups: [StatisticsGroup]
    ) {
        self.period = period
        self.startDateKey = startDateKey
        self.endDateKey = endDateKey
        self.completedTasks = completedTasks
        self.focusedSeconds = focusedSeconds
        self.activeDays = activeDays
        self.groups = groups
    }

    /// Returns the five highest-value habits plus General when General has data.
    /// Ties are ordered by display name and then stable group ID.
    public func topGroups(for metric: StatisticsMetric, habitLimit: Int = 5) -> [StatisticsGroup] {
        let ranked = groups
            .filter { $0.value(for: metric) > 0 }
            .sorted { lhs, rhs in
                let lhsValue = lhs.value(for: metric)
                let rhsValue = rhs.value(for: metric)
                if lhsValue != rhsValue { return lhsValue > rhsValue }

                let lhsTitle = lhs.title.lowercased(with: Locale(identifier: "en_US_POSIX"))
                let rhsTitle = rhs.title.lowercased(with: Locale(identifier: "en_US_POSIX"))
                if lhsTitle != rhsTitle { return lhsTitle < rhsTitle }
                return lhs.id < rhs.id
            }

        let habits = ranked
            .filter { $0.groupID != .general }
            .prefix(max(0, habitLimit))
        let general = ranked.first { $0.groupID == .general }
        return Array(habits) + (general.map { [$0] } ?? [])
    }
}

public enum StatisticsCalculator {
    public static func snapshot(
        state: AppState,
        focusRecords: [FocusRecord],
        period: StatisticsPeriod,
        today: Date,
        calendar: Calendar
    ) -> StatisticsSnapshot {
        let range = StatisticsDateRange(period: period, today: today, calendar: calendar)
        let habitsByID = state.habits.reduce(into: [String: Habit]()) { result, habit in
            result[habit.id] = habit
        }
        var accumulators: [StatisticsGroupID: StatisticsAccumulator] = [:]
        var activeDateKeys = Set<String>()

        for (dateKey, plan) in state.days {
            guard let date = DateKey.date(from: dateKey, calendar: calendar), range.contains(date) else { continue }

            for task in plan.tasks where task.isCompleted {
                let groupID = task.habitID.map(StatisticsGroupID.habit) ?? .general
                var accumulator = accumulators[groupID, default: StatisticsAccumulator()]
                accumulator.completedTasks += 1
                accumulators[groupID] = accumulator
                activeDateKeys.insert(DateKey.string(from: date, calendar: calendar))
            }
        }

        for record in focusRecords where record.focusedSeconds > 0 && range.contains(record.startedAt) {
            let groupID = record.task.habitIDSnapshot.map(StatisticsGroupID.habit) ?? .general
            var accumulator = accumulators[groupID, default: StatisticsAccumulator()]
            accumulator.focusedSeconds += record.focusedSeconds
            if let snapshotName = record.task.habitNameSnapshot?.trimmingCharacters(in: .whitespacesAndNewlines),
               !snapshotName.isEmpty,
               accumulator.latestFocusMetadataDate.map({ record.startedAt > $0 }) ?? true {
                accumulator.focusTitle = snapshotName
                accumulator.latestFocusMetadataDate = record.startedAt
            }
            accumulators[groupID] = accumulator
            activeDateKeys.insert(DateKey.string(from: record.startedAt, calendar: calendar))
        }

        let groups = accumulators.map { groupID, accumulator in
            StatisticsGroup(
                groupID: groupID,
                title: title(
                    for: groupID,
                    habitsByID: habitsByID,
                    focusTitle: accumulator.focusTitle
                ),
                completedTasks: accumulator.completedTasks,
                focusedSeconds: accumulator.focusedSeconds
            )
        }

        return StatisticsSnapshot(
            period: period,
            startDateKey: range.start.map { DateKey.string(from: $0, calendar: calendar) },
            endDateKey: DateKey.string(from: range.today, calendar: calendar),
            completedTasks: groups.reduce(0) { $0 + $1.completedTasks },
            focusedSeconds: groups.reduce(0) { $0 + $1.focusedSeconds },
            activeDays: activeDateKeys.count,
            groups: groups.sorted { $0.id < $1.id }
        )
    }

    private static func title(
        for groupID: StatisticsGroupID,
        habitsByID: [String: Habit],
        focusTitle: String?
    ) -> String {
        switch groupID {
        case .general:
            return "General"
        case .habit(let habitID):
            return habitsByID[habitID]?.name ?? focusTitle ?? "Past habit"
        }
    }
}

private struct StatisticsAccumulator {
    var completedTasks = 0
    var focusedSeconds = 0
    var focusTitle: String?
    var latestFocusMetadataDate: Date?
}

private struct StatisticsDateRange {
    let start: Date?
    let today: Date
    let end: Date

    init(period: StatisticsPeriod, today: Date, calendar: Calendar) {
        self.today = calendar.startOfDay(for: today)
        self.end = calendar.date(byAdding: .day, value: 1, to: self.today) ?? .distantFuture
        if let dayCount = period.dayCount {
            self.start = calendar.date(byAdding: .day, value: -(dayCount - 1), to: self.today)
        } else {
            self.start = nil
        }
    }

    func contains(_ date: Date) -> Bool {
        guard date < end else { return false }
        guard let start else { return true }
        return date >= start
    }
}
