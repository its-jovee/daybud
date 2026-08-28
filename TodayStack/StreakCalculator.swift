import Foundation

public struct WeeklyProgress: Equatable, Sendable {
    public let activeDays: Int
    public let targetDays: Int

    public init(activeDays: Int, targetDays: Int) {
        self.activeDays = activeDays
        self.targetDays = targetDays
    }
}

public enum StreakCalculator {
    public static func currentStreak(for habit: Habit, sessions: [HabitSession], today: Date, calendar: Calendar) -> Int {
        switch habit.frequency {
        case .daily:
            return dailyCurrentStreak(habitID: habit.id, sessions: sessions, today: today, calendar: calendar)
        case .weeklyTarget(let target):
            return weeklyCurrentStreak(habitID: habit.id, target: target, sessions: sessions, today: today, calendar: calendar)
        }
    }

    public static func longestStreak(for habit: Habit, sessions: [HabitSession], calendar: Calendar) -> Int {
        switch habit.frequency {
        case .daily:
            return dailyLongestStreak(habitID: habit.id, sessions: sessions, calendar: calendar)
        case .weeklyTarget(let target):
            return weeklyLongestStreak(habitID: habit.id, target: target, sessions: sessions, calendar: calendar)
        }
    }

    public static func weeklyProgress(for habit: Habit, sessions: [HabitSession], today: Date, calendar: Calendar) -> WeeklyProgress? {
        guard case .weeklyTarget(let target) = habit.frequency,
              let interval = calendar.dateInterval(of: .weekOfYear, for: today) else {
            return nil
        }
        let start = interval.start
        let end = interval.end
        let activeDays = Set(sessions.filter { $0.habitID == habit.id }
            .compactMap { DateKey.date(from: $0.date, calendar: calendar) }
            .filter { $0 >= start && $0 < end }
            .map { DateKey.string(from: $0, calendar: calendar) }).count
        return WeeklyProgress(activeDays: activeDays, targetDays: target)
    }

    private static func successfulSessionDays(for habitID: String, from allSessions: [HabitSession], calendar: Calendar) -> Set<String> {
        Set(allSessions.filter { $0.habitID == habitID }
            .compactMap { DateKey.normalized($0.date, calendar: calendar) })
    }

    private static func dailyCurrentStreak(habitID: String, sessions: [HabitSession], today: Date, calendar: Calendar) -> Int {
        let successfulDays = successfulSessionDays(for: habitID, from: sessions, calendar: calendar)
        guard !successfulDays.isEmpty else { return 0 }

        let todayKey = DateKey.string(from: today, calendar: calendar)
        let anchor: Date
        if successfulDays.contains(todayKey) {
            anchor = today
        } else if let yesterday = calendar.date(byAdding: .day, value: -1, to: today) {
            let yesterdayKey = DateKey.string(from: yesterday, calendar: calendar)
            guard successfulDays.contains(yesterdayKey) else { return 0 }
            anchor = yesterday
        } else {
            return 0
        }

        var count = 0
        var cursor = anchor
        while true {
            let key = DateKey.string(from: cursor, calendar: calendar)
            guard successfulDays.contains(key) else { break }
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return count
    }

    private static func dailyLongestStreak(habitID: String, sessions: [HabitSession], calendar: Calendar) -> Int {
        let successfulDays = successfulSessionDays(for: habitID, from: sessions, calendar: calendar)
        let dates = successfulDays.compactMap { DateKey.date(from: $0, calendar: calendar) }.sorted()
        guard let first = dates.first else { return 0 }

        var longest = 1
        var current = 1
        var previous = first
        for date in dates.dropFirst() {
            if let expected = calendar.date(byAdding: .day, value: 1, to: previous),
               DateKey.string(from: expected, calendar: calendar) == DateKey.string(from: date, calendar: calendar) {
                current += 1
            } else {
                longest = max(longest, current)
                current = 1
            }
            previous = date
        }
        return max(longest, current)
    }

    private static func weeklySuccessfulStarts(habitID: String, target: Int, sessions: [HabitSession], calendar: Calendar) -> Set<String> {
        var activeDaysByWeek: [String: Set<String>] = [:]
        for session in sessions where session.habitID == habitID {
            guard let date = DateKey.date(from: session.date, calendar: calendar),
                  let interval = calendar.dateInterval(of: .weekOfYear, for: date) else { continue }
            let weekKey = DateKey.string(from: interval.start, calendar: calendar)
            let dayKey = DateKey.string(from: date, calendar: calendar)
            activeDaysByWeek[weekKey, default: []].insert(dayKey)
        }
        return Set(activeDaysByWeek.compactMap { $0.value.count >= target ? $0.key : nil })
    }

    private static func weeklyCurrentStreak(habitID: String, target: Int, sessions: [HabitSession], today: Date, calendar: Calendar) -> Int {
        let successfulWeeks = weeklySuccessfulStarts(habitID: habitID, target: target, sessions: sessions, calendar: calendar)
        guard let currentInterval = calendar.dateInterval(of: .weekOfYear, for: today) else { return 0 }

        let currentStart = currentInterval.start
        let currentKey = DateKey.string(from: currentStart, calendar: calendar)
        let anchor: Date
        if successfulWeeks.contains(currentKey) {
            anchor = currentStart
        } else if let previous = calendar.date(byAdding: .weekOfYear, value: -1, to: currentStart),
                  successfulWeeks.contains(DateKey.string(from: previous, calendar: calendar)) {
            anchor = previous
        } else {
            return 0
        }

        var count = 0
        var cursor = anchor
        while true {
            let key = DateKey.string(from: cursor, calendar: calendar)
            guard successfulWeeks.contains(key) else { break }
            count += 1
            guard let previous = calendar.date(byAdding: .weekOfYear, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return count
    }

    private static func weeklyLongestStreak(habitID: String, target: Int, sessions: [HabitSession], calendar: Calendar) -> Int {
        let successfulWeeks = weeklySuccessfulStarts(habitID: habitID, target: target, sessions: sessions, calendar: calendar)
        let starts = successfulWeeks.compactMap { DateKey.date(from: $0, calendar: calendar) }.sorted()
        guard let first = starts.first else { return 0 }

        var longest = 1
        var current = 1
        var previous = first
        for start in starts.dropFirst() {
            if let expected = calendar.date(byAdding: .weekOfYear, value: 1, to: previous),
               DateKey.string(from: expected, calendar: calendar) == DateKey.string(from: start, calendar: calendar) {
                current += 1
            } else {
                longest = max(longest, current)
                current = 1
            }
            previous = start
        }
        return max(longest, current)
    }
}
