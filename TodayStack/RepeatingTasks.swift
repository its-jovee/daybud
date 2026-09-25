import Foundation

/// The weekdays on which a repeating task returns to Today.
public struct RepeatSchedule: Codable, Equatable, Hashable, Sendable {
    /// Calendar weekday numbers (1 = Sunday … 7 = Saturday), sorted and unique.
    public let days: [Int]

    public init<Days: Sequence>(days: Days) where Days.Element == Int {
        self.days = Set(days).filter { (1...7).contains($0) }.sorted()
    }

    public static let everyDay = RepeatSchedule(days: 1...7)
    public static let weekdays = RepeatSchedule(days: 2...6)
    public static let weekends = RepeatSchedule(days: [1, 7])

    public var isEmpty: Bool { days.isEmpty }

    public func includes(_ date: Date, calendar: Calendar) -> Bool {
        days.contains(calendar.component(.weekday, from: date))
    }

    /// "Every day", "Weekdays", "Weekends", or short day names in the calendar's week order.
    public func label(calendar: Calendar) -> String {
        if self == .everyDay { return "Every day" }
        if self == .weekdays { return "Weekdays" }
        if self == .weekends { return "Weekends" }
        return Self.weekOrder(calendar: calendar)
            .filter(days.contains)
            .map { calendar.shortWeekdaySymbols[$0 - 1] }
            .joined(separator: ", ")
    }

    /// All weekday numbers, starting from the calendar's first weekday.
    public static func weekOrder(calendar: Calendar) -> [Int] {
        (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
    }

    private enum CodingKeys: String, CodingKey {
        case days
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(days: try container.decode([Int].self, forKey: .days))
    }
}

/// A task Daybud adds to Today on each scheduled day, even after an earlier
/// occurrence was finished. Editing today's occurrence updates it from then on.
public struct RepeatingTask: Codable, Equatable, Identifiable, Hashable, Sendable {
    public let id: String
    public var title: String
    public var habitID: String?
    public var durationMinutes: Int
    public var purpose: TaskPurpose
    public var schedule: RepeatSchedule

    public init(
        id: String = UUID().uuidString,
        title: String,
        habitID: String? = nil,
        durationMinutes: Int = TaskItem.defaultDurationMinutes,
        purpose: TaskPurpose = .regular,
        schedule: RepeatSchedule
    ) {
        self.id = id
        self.title = title
        self.habitID = habitID
        self.durationMinutes = TaskItem.normalizedDuration(durationMinutes)
        self.purpose = purpose
        self.schedule = schedule
    }
}

public enum RepeatingTaskError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

public enum RepeatingTaskEngine {
    /// Fresh occurrences of every repeating task scheduled on `dateKey`. Each gets its
    /// own ID and lineage, so completions, Coins and focus time stay per day.
    public static func occurrences(on dateKey: String, state: AppState, calendar: Calendar) -> [TaskItem] {
        guard let date = DateKey.date(from: dateKey, calendar: calendar) else { return [] }
        return state.repeatingTasks
            .filter { $0.schedule.includes(date, calendar: calendar) }
            .map { routine in
                TaskItem(
                    title: routine.title,
                    habitID: validHabitID(routine.habitID, state: state),
                    durationMinutes: routine.durationMinutes,
                    purpose: activePurpose(routine.purpose, state: state),
                    repeatingTaskID: routine.id
                )
            }
    }

    /// Starts, reschedules or stops repeating a task in `date`'s plan. A new repeating
    /// task copies the task's current details; stopping keeps the task as a one-off.
    public static func setRepeat(taskID: String, schedule: RepeatSchedule?, date: String, state: inout AppState) throws {
        guard let index = state.days[date]?.tasks.firstIndex(where: { $0.id == taskID }) else {
            throw RepeatingTaskError.invalid("This task is no longer available.")
        }
        let task = state.days[date]!.tasks[index]
        guard let schedule else {
            if let routineID = task.repeatingTaskID { stop(id: routineID, date: date, state: &state) }
            return
        }
        guard !schedule.isEmpty else { throw RepeatingTaskError.invalid("Choose at least one day to repeat on.") }

        if let routineID = task.repeatingTaskID,
           let routineIndex = state.repeatingTasks.firstIndex(where: { $0.id == routineID }) {
            state.repeatingTasks[routineIndex].schedule = schedule
            syncRoutine(fromTaskID: taskID, date: date, state: &state)
        } else {
            let routine = RepeatingTask(
                title: task.title,
                habitID: task.habitID,
                durationMinutes: task.durationMinutes,
                purpose: task.purpose,
                schedule: schedule
            )
            state.repeatingTasks.append(routine)
            state.days[date]!.tasks[index].repeatingTaskID = routine.id
        }
    }

    /// Copies an occurrence's details to its repeating task so edits apply from today onward.
    public static func syncRoutine(fromTaskID taskID: String, date: String, state: inout AppState) {
        guard let task = state.days[date]?.tasks.first(where: { $0.id == taskID }),
              let routineID = task.repeatingTaskID,
              let index = state.repeatingTasks.firstIndex(where: { $0.id == routineID }) else { return }
        state.repeatingTasks[index].title = task.title
        state.repeatingTasks[index].habitID = task.habitID
        state.repeatingTasks[index].durationMinutes = task.durationMinutes
        state.repeatingTasks[index].purpose = task.purpose
    }

    /// Saves a repeating task and applies its details to its unfinished occurrence on `date`.
    public static func update(_ routine: RepeatingTask, date: String, state: inout AppState) throws {
        let title = routine.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw RepeatingTaskError.invalid("Task titles cannot be empty.") }
        guard !routine.schedule.isEmpty else { throw RepeatingTaskError.invalid("Choose at least one day to repeat on.") }
        guard let index = state.repeatingTasks.firstIndex(where: { $0.id == routine.id }) else {
            throw RepeatingTaskError.invalid("This repeating task no longer exists.")
        }
        if let questID = routine.purpose.questID,
           questID != state.repeatingTasks[index].purpose.questID,
           !state.questSystem.activeQuests.contains(where: { $0.id == questID }) {
            throw RepeatingTaskError.invalid("Choose an active Main Quest.")
        }

        var saved = routine
        saved.title = title
        saved.habitID = validHabitID(routine.habitID, state: state)
        saved.durationMinutes = TaskItem.normalizedDuration(routine.durationMinutes)
        state.repeatingTasks[index] = saved

        guard var tasks = state.days[date]?.tasks else { return }
        for i in tasks.indices where tasks[i].repeatingTaskID == saved.id && !tasks[i].isCompleted {
            tasks[i].title = saved.title
            tasks[i].habitID = saved.habitID
            tasks[i].durationMinutes = saved.durationMinutes
            tasks[i].purpose = saved.purpose
        }
        state.days[date]!.tasks = tasks
    }

    /// Stops repeating. Earlier occurrences stay as history; any occurrence on `date` becomes a one-off task.
    public static func stop(id: String, date: String, state: inout AppState) {
        state.repeatingTasks.removeAll { $0.id == id }
        guard var tasks = state.days[date]?.tasks else { return }
        for i in tasks.indices where tasks[i].repeatingTaskID == id {
            tasks[i].repeatingTaskID = nil
        }
        state.days[date]!.tasks = tasks
    }

    private static func validHabitID(_ habitID: String?, state: AppState) -> String? {
        guard let habitID, state.habits.contains(where: { $0.id == habitID }) else { return nil }
        return habitID
    }

    /// New occurrences keep a Main Quest link only while that quest is active.
    private static func activePurpose(_ purpose: TaskPurpose, state: AppState) -> TaskPurpose {
        guard let questID = purpose.questID else { return purpose }
        return state.questSystem.activeQuests.contains { $0.id == questID } ? purpose : .regular
    }
}
