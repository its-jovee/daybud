import Combine
import Foundation

@MainActor
public final class AppStore: ObservableObject {
    @Published public private(set) var state: AppState
    @Published public private(set) var errorMessage: String?

    public let repository: JSONStateRepository
    public var calendar: Calendar

    private let nowProvider: () -> Date
    private var persistenceBlocked = false

    public init(repository: JSONStateRepository = JSONStateRepository(), calendar: Calendar = .current, now: @escaping () -> Date = { Date() }) {
        self.repository = repository
        self.calendar = calendar
        self.nowProvider = now

        do {
            self.state = try repository.load()
        } catch {
            self.state = AppState()
            self.errorMessage = error.localizedDescription
            self.persistenceBlocked = true
        }

        if !persistenceBlocked {
            ensureTodayPlan(persist: true)
        }
    }

    public var todayDateKey: String {
        DateKey.string(from: nowProvider(), calendar: calendar)
    }

    public var todayPlan: DayPlan {
        state.days[todayDateKey] ?? DayPlan(date: todayDateKey)
    }

    public var currentTask: TaskItem? {
        todayPlan.tasks.first(where: { !$0.isCompleted })
    }

    public var completedTodayCount: Int {
        completedTaskCount + completedHabitCount
    }

    public var completedTaskCount: Int {
        todayPlan.tasks.filter(\.isCompleted).count
    }

    public var completedHabitCount: Int {
        state.habits.filter(isLoggedToday).count
    }

    public var allHabitsCompletedToday: Bool {
        !state.habits.isEmpty && completedHabitCount == state.habits.count
    }

    public var totalTodayCount: Int {
        todayPlan.tasks.count + state.habits.count
    }

    public var progressText: String {
        "\(completedTodayCount)/\(totalTodayCount)"
    }

    public var menuBarLabel: String {
        let tasks = todayPlan.tasks
        guard !tasks.isEmpty || !state.habits.isEmpty else { return "0/0 · Plan today" }

        if let task = currentTask {
            let title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if title.count <= 32 { return "\(progressText) · \(title)" }
            let end = title.index(title.startIndex, offsetBy: 29)
            return "\(progressText) · \(title[..<end])…"
        }

        if let habit = state.habits.first(where: { !isLoggedToday(habit: $0) }) {
            return "\(progressText) · \(habit.name)"
        }

        return "\(progressText) · Done"
    }

    public func refresh() {
        guard !persistenceBlocked else { return }
        ensureTodayPlan(persist: true)
        importTodayPlan()
    }

    @discardableResult
    public func addTask(title: String, habitID: String? = nil) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Task titles cannot be empty."
            return nil
        }
        guard !persistenceBlocked else { return nil }
        ensureTodayPlan(persist: false)
        let task = TaskItem(title: trimmed, habitID: validHabitID(habitID))
        state.days[todayDateKey, default: DayPlan(date: todayDateKey)].tasks.append(task)
        persist()
        return task.id
    }

    public func updateTaskTitle(id: String, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Task titles cannot be empty."
            return
        }
        guard !persistenceBlocked, var plan = state.days[todayDateKey], let index = plan.tasks.firstIndex(where: { $0.id == id }) else { return }
        plan.tasks[index].title = trimmed
        state.days[todayDateKey] = plan
        persist()
    }

    public func deleteTask(id: String) {
        guard !persistenceBlocked, var plan = state.days[todayDateKey] else { return }
        plan.tasks.removeAll(where: { $0.id == id })
        state.days[todayDateKey] = plan
        state.sessions.removeAll(where: { $0.taskID == id })
        persist()
    }

    public func moveTasks(from offsets: IndexSet, to destination: Int) {
        guard !persistenceBlocked, var plan = state.days[todayDateKey], !offsets.isEmpty else { return }
        let sourceIndexes = offsets.sorted()
        let moving = sourceIndexes.map { plan.tasks[$0] }
        for index in sourceIndexes.reversed() {
            plan.tasks.remove(at: index)
        }
        let removedBeforeDestination = sourceIndexes.filter { $0 < destination }.count
        let insertionIndex = max(0, min(plan.tasks.count, destination - removedBeforeDestination))
        plan.tasks.insert(contentsOf: moving, at: insertionIndex)
        state.days[todayDateKey] = plan
        persist()
    }

    public func moveTask(id: String, before targetID: String?) {
        guard !persistenceBlocked, var plan = state.days[todayDateKey],
              let sourceIndex = plan.tasks.firstIndex(where: { $0.id == id }) else { return }
        if targetID == id { return }

        let task = plan.tasks.remove(at: sourceIndex)
        if let targetID, let targetIndex = plan.tasks.firstIndex(where: { $0.id == targetID }) {
            plan.tasks.insert(task, at: targetIndex)
        } else {
            plan.tasks.append(task)
        }
        state.days[todayDateKey] = plan
        persist()
    }

    public func setTaskCompleted(id: String, completed: Bool) {
        guard !persistenceBlocked, var plan = state.days[todayDateKey], let index = plan.tasks.firstIndex(where: { $0.id == id }) else { return }
        var task = plan.tasks[index]
        guard task.isCompleted != completed else { return }
        task.isCompleted = completed
        plan.tasks[index] = task
        state.days[todayDateKey] = plan
        synchronizeTaskSession(taskID: task.id, date: todayDateKey, habitID: task.habitID, completed: completed)
        persist()
    }

    public func setTaskHabit(id: String, habitID: String?) {
        guard !persistenceBlocked, var plan = state.days[todayDateKey], let index = plan.tasks.firstIndex(where: { $0.id == id }) else { return }
        var task = plan.tasks[index]
        let newHabitID = validHabitID(habitID)
        guard task.habitID != newHabitID else { return }
        task.habitID = newHabitID
        plan.tasks[index] = task
        state.days[todayDateKey] = plan
        if task.isCompleted {
            synchronizeTaskSession(taskID: task.id, date: todayDateKey, habitID: task.habitID, completed: true)
        }
        persist()
    }

    @discardableResult
    public func addHabit(
        name: String,
        frequency: HabitFrequency = .daily,
        slug: String? = nil,
        iconName: String? = nil
    ) -> String? {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            errorMessage = "Habit names cannot be empty."
            return nil
        }
        guard !persistenceBlocked else { return nil }
        let baseSlug = Self.slug(from: slug?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? slug! : trimmedName)
        let uniqueSlug = uniqueSlug(baseSlug)
        let habit = Habit(
            slug: uniqueSlug,
            name: trimmedName,
            frequency: frequency,
            iconName: normalizedIconName(iconName)
        )
        state.habits.append(habit)
        persist()
        return habit.id
    }

    public func renameHabit(id: String, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Habit names cannot be empty."
            return
        }
        guard !persistenceBlocked, let index = state.habits.firstIndex(where: { $0.id == id }) else { return }
        state.habits[index].name = trimmed
        persist()
    }

    public func setHabitFrequency(id: String, frequency: HabitFrequency) {
        guard !persistenceBlocked, let index = state.habits.firstIndex(where: { $0.id == id }) else { return }
        state.habits[index].frequency = frequency
        persist()
    }

    public func setHabitIcon(id: String, iconName: String) {
        guard !persistenceBlocked, let index = state.habits.firstIndex(where: { $0.id == id }) else { return }
        state.habits[index].iconName = normalizedIconName(iconName)
        persist()
    }

    public func deleteHabit(id: String) {
        guard !persistenceBlocked else { return }
        state.habits.removeAll(where: { $0.id == id })
        for dayKey in Array(state.days.keys) {
            state.days[dayKey]?.tasks = state.days[dayKey]?.tasks.map { task in
                var updated = task
                if updated.habitID == id { updated.habitID = nil }
                return updated
            } ?? []
        }
        state.sessions.removeAll(where: { $0.habitID == id })
        persist()
    }

    /// Toggle only the manual session for today. A task-created session remains
    /// intact when a manual log is removed.
    public func toggleManualHabitToday(id: String) {
        guard !persistenceBlocked, state.habits.contains(where: { $0.id == id }) else { return }
        let date = todayDateKey
        let hasManualSession = state.sessions.contains { $0.habitID == id && $0.date == date && $0.source == .manual }
        if hasManualSession {
            state.sessions.removeAll { $0.habitID == id && $0.date == date && $0.source == .manual }
        } else {
            // A completed linked task has already fulfilled this habit today.
            // Do not create a second completion for the same day.
            guard !state.sessions.contains(where: { $0.habitID == id && $0.date == date }) else { return }
            state.sessions.append(HabitSession(habitID: id, date: date, source: .manual))
        }
        persist()
    }

    public func totalSessions(for habit: Habit) -> Int {
        Set(state.sessions.filter { $0.habitID == habit.id }.map(\.date)).count
    }

    public func currentStreak(for habit: Habit) -> Int {
        StreakCalculator.currentStreak(for: habit, sessions: state.sessions, today: nowProvider(), calendar: calendar)
    }

    public func longestStreak(for habit: Habit) -> Int {
        StreakCalculator.longestStreak(for: habit, sessions: state.sessions, calendar: calendar)
    }

    public func weeklyProgress(for habit: Habit) -> WeeklyProgress? {
        StreakCalculator.weeklyProgress(for: habit, sessions: state.sessions, today: nowProvider(), calendar: calendar)
    }

    public func isLoggedToday(habit: Habit) -> Bool {
        state.sessions.contains { $0.habitID == habit.id && $0.date == todayDateKey }
    }

    public func hasManualLogToday(habit: Habit) -> Bool {
        state.sessions.contains { $0.habitID == habit.id && $0.date == todayDateKey && $0.source == .manual }
    }

    public func completionTaskTitle(for habit: Habit) -> String? {
        guard let taskID = state.sessions.first(where: {
            $0.habitID == habit.id && $0.date == todayDateKey && $0.source == .task
        })?.taskID else { return nil }
        return todayPlan.tasks.first(where: { $0.id == taskID })?.title
    }

    /// GitHub-style contribution levels for a habit. Completed linked tasks each
    /// contribute one unit; a manual check-in contributes level one only when
    /// there are no task contributions for that date.
    public func activityCounts(for habit: Habit) -> [String: Int] {
        var taskCounts: [String: Int] = [:]
        var manualDates: Set<String> = []

        for session in state.sessions where session.habitID == habit.id {
            switch session.source {
            case .task:
                taskCounts[session.date, default: 0] += 1
            case .manual:
                manualDates.insert(session.date)
            }
        }

        for date in manualDates {
            taskCounts[date] = max(taskCounts[date, default: 0], 1)
        }
        return taskCounts
    }

    public func importTodayPlan() {
        guard !persistenceBlocked else { return }
        do {
            guard let data = try repository.readTodayFile() else { return }
            let result = try TodayImportService.applying(data: data, to: state, calendar: calendar)
            guard result.changed else { return }
            state = result.state
            persist()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func dismissError() {
        errorMessage = nil
    }

    private func ensureTodayPlan(persist shouldPersist: Bool) {
        guard state.days[todayDateKey] == nil else { return }
        state.days[todayDateKey] = DayPlan(date: todayDateKey)
        if shouldPersist { persist() }
    }

    private func synchronizeTaskSession(taskID: String, date: String, habitID: String?, completed: Bool) {
        let existing = state.sessions.first(where: { $0.taskID == taskID && $0.date == date && $0.habitID == habitID })
        state.sessions.removeAll { $0.taskID == taskID && $0.date == date }
        guard completed, let habitID else { return }
        state.sessions.append(existing ?? HabitSession(habitID: habitID, date: date, taskID: taskID, source: .task))
    }

    private func validHabitID(_ habitID: String?) -> String? {
        guard let habitID, state.habits.contains(where: { $0.id == habitID }) else { return nil }
        return habitID
    }

    private func normalizedIconName(_ iconName: String?) -> String? {
        guard let iconName else { return nil }
        let trimmed = iconName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func uniqueSlug(_ raw: String) -> String {
        let base = raw.isEmpty ? "habit" : raw
        if !state.habits.contains(where: { $0.slug == base }) { return base }
        var counter = 2
        while state.habits.contains(where: { $0.slug == "\(base)-\(counter)" }) { counter += 1 }
        return "\(base)-\(counter)"
    }

    private func persist() {
        guard !persistenceBlocked else { return }
        do {
            try repository.save(state)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func slug(from value: String) -> String {
        let lowercased = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let pieces = lowercased.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return pieces.joined(separator: "-")
    }
}
