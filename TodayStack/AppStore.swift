import Combine
import Foundation

@MainActor
public final class AppStore: ObservableObject {
    @Published public private(set) var state: AppState
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var focusClock: Date

    public let repository: JSONStateRepository
    public var calendar: Calendar

    private let nowProvider: () -> Date
    private let focusNotificationScheduler: FocusNotificationScheduling
    private var persistenceBlocked = false
    private var focusTicker: AnyCancellable?

    public convenience init(
        repository: JSONStateRepository = JSONStateRepository(),
        calendar: Calendar = .current,
        now: @escaping () -> Date = { Date() }
    ) {
        self.init(
            repository: repository,
            calendar: calendar,
            now: now,
            focusNotificationScheduler: NativeFocusNotificationScheduler()
        )
    }

    public init(
        repository: JSONStateRepository,
        calendar: Calendar,
        now: @escaping () -> Date,
        focusNotificationScheduler: FocusNotificationScheduling
    ) {
        self.repository = repository
        self.calendar = calendar
        self.nowProvider = now
        self.focusNotificationScheduler = focusNotificationScheduler
        self.focusClock = now()

        do {
            self.state = try repository.load()
        } catch {
            self.state = AppState()
            self.errorMessage = error.localizedDescription
            self.persistenceBlocked = true
        }

        if !persistenceBlocked {
            ensureTodayPlan(persist: true)
            reconcileFocusTimer(at: focusClock)
            synchronizeFocusNotification()
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

    public var completedTaskCount: Int {
        todayPlan.tasks.filter(\.isCompleted).count
    }

    public var completedHabitCount: Int {
        state.habits.filter(isLoggedToday).count
    }

    public var allHabitsCompletedToday: Bool {
        !state.habits.isEmpty && completedHabitCount == state.habits.count
    }

    public var totalTaskCount: Int {
        todayPlan.tasks.count
    }

    public var progressText: String {
        "\(completedTaskCount)/\(totalTaskCount)"
    }

    public var menuBarLabel: String {
        switch focusPresentation {
        case .running(let task, let remainingSeconds, _, _, _),
             .paused(let task, let remainingSeconds, _, _, _):
            return "\(Self.focusTimeText(remainingSeconds)) · \(Self.compactTitle(task.titleSnapshot))"
        case .awaitingDecision(let task, _, _):
            return "Done? · \(Self.compactTitle(task.titleSnapshot))"
        case .idle:
            break
        }

        let tasks = todayPlan.tasks
        guard !tasks.isEmpty else { return "0/0 · Plan today" }

        if let task = currentTask {
            let title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if title.count <= 32 { return "\(progressText) · \(title)" }
            let end = title.index(title.startIndex, offsetBy: 29)
            return "\(progressText) · \(title[..<end])…"
        }

        return "\(progressText) · Done"
    }

    public var focusPresentation: FocusPresentation {
        PomodoroEngine.presentation(for: state.pomodoro, at: focusClock)
    }

    public var hasActiveFocusTimer: Bool {
        state.pomodoro.activeTimer != nil
    }

    public var canMarkFocusedTaskDone: Bool {
        guard let reference = focusedTaskReference else { return false }
        return todayPlan.tasks.contains {
            ($0.id == reference.occurrenceID || $0.lineageID == reference.lineageID) && !$0.isCompleted
        }
    }

    public func statisticsSnapshot(period: StatisticsPeriod) -> StatisticsSnapshot {
        StatisticsCalculator.snapshot(
            state: state,
            focusRecords: state.pomodoro.records,
            period: period,
            today: nowProvider(),
            calendar: calendar
        )
    }

    public func refresh() {
        guard !persistenceBlocked else { return }
        ensureTodayPlan(persist: true)
        importTodayPlan()
        reconcileFocusTimer(at: nowProvider())
    }

    @discardableResult
    public func startFocus(on task: TaskItem) -> Bool {
        guard !persistenceBlocked, !task.isCompleted else { return false }
        let now = nowProvider()
        focusClock = now
        let habit = task.habitID.flatMap { habitID in
            state.habits.first(where: { $0.id == habitID })
        }
        let reference = FocusTaskReference(
            occurrenceID: task.id,
            lineageID: task.lineageID,
            dateKey: todayDateKey,
            titleSnapshot: task.title,
            habitIDSnapshot: habit?.id,
            habitNameSnapshot: habit?.name
        )
        guard PomodoroEngine.start(task: reference, runID: UUID().uuidString, at: now, state: &state.pomodoro) else {
            errorMessage = "Finish or stop the current Pomodoro before starting another one."
            return false
        }
        persist()
        synchronizeFocusNotification()
        updateFocusTicker()
        return true
    }

    public func pauseFocus() {
        guard !persistenceBlocked else { return }
        let now = nowProvider()
        focusClock = now
        guard PomodoroEngine.pause(at: now, state: &state.pomodoro) else { return }
        persist()
        synchronizeFocusNotification()
        updateFocusTicker()
    }

    public func resumeFocus() {
        guard !persistenceBlocked else { return }
        let now = nowProvider()
        focusClock = now
        guard PomodoroEngine.resume(at: now, state: &state.pomodoro) else { return }
        persist()
        synchronizeFocusNotification()
        updateFocusTicker()
    }

    public func addMoreFocusTime() {
        guard !persistenceBlocked else { return }
        let now = nowProvider()
        focusClock = now
        guard PomodoroEngine.extend(at: now, state: &state.pomodoro) else { return }
        persist()
        synchronizeFocusNotification()
        updateFocusTicker()
    }

    public func stopFocus() {
        finishFocus(outcome: .stopped, markTaskDone: false)
    }

    public func markFocusedTaskDone() {
        finishFocus(outcome: .completedTask, markTaskDone: true)
    }

    public func updatePomodoroSettings(_ settings: PomodoroSettings) {
        guard !persistenceBlocked else { return }
        state.pomodoro.settings = settings
        persist()
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
        guard !persistenceBlocked, var plan = state.days[todayDateKey],
              let task = plan.tasks.first(where: { $0.id == id }) else { return }
        archiveFocusIfNeeded(for: task, outcome: .stopped)
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
        if completed {
            archiveFocusIfNeeded(for: task, outcome: .completedTask)
        }
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
            if let reference = focusedTaskReference,
               !todayPlan.tasks.contains(where: { taskMatches($0, reference: reference) }) {
                let now = nowProvider()
                focusClock = now
                _ = PomodoroEngine.end(outcome: .stopped, at: now, state: &state.pomodoro)
                synchronizeFocusNotification()
                updateFocusTicker()
            }
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
        let carriedTasks = mostRecentPlan(before: todayDateKey)?.tasks
            .filter { !$0.isCompleted }
            .map { task in
                TaskItem(
                    lineageID: task.lineageID,
                    title: task.title,
                    habitID: validHabitID(task.habitID)
                )
            } ?? []
        state.days[todayDateKey] = DayPlan(date: todayDateKey, tasks: carriedTasks)
        if shouldPersist { persist() }
    }

    private var focusedTaskReference: FocusTaskReference? {
        switch focusPresentation {
        case .idle:
            return nil
        case .running(let task, _, _, _, _),
             .paused(let task, _, _, _, _),
             .awaitingDecision(let task, _, _):
            return task
        }
    }

    private func finishFocus(outcome: FocusOutcome, markTaskDone: Bool) {
        guard !persistenceBlocked else { return }
        let reference = focusedTaskReference
        let now = nowProvider()
        focusClock = now

        if markTaskDone {
            guard let reference,
                  var plan = state.days[todayDateKey],
                  let index = plan.tasks.firstIndex(where: { taskMatches($0, reference: reference) }),
                  !plan.tasks[index].isCompleted else {
                errorMessage = "This task is no longer active. End the Pomodoro to keep its focus time."
                return
            }
            plan.tasks[index].isCompleted = true
            let completedTask = plan.tasks[index]
            state.days[todayDateKey] = plan
            synchronizeTaskSession(
                taskID: completedTask.id,
                date: todayDateKey,
                habitID: completedTask.habitID,
                completed: true
            )
        }

        guard PomodoroEngine.end(outcome: outcome, at: now, state: &state.pomodoro) != nil else { return }

        persist()
        synchronizeFocusNotification()
        updateFocusTicker()
    }

    private func archiveFocusIfNeeded(for task: TaskItem, outcome: FocusOutcome) {
        guard let reference = focusedTaskReference, taskMatches(task, reference: reference) else { return }
        let now = nowProvider()
        focusClock = now
        _ = PomodoroEngine.end(outcome: outcome, at: now, state: &state.pomodoro)
        synchronizeFocusNotification()
        updateFocusTicker()
    }

    private func taskMatches(_ task: TaskItem, reference: FocusTaskReference) -> Bool {
        task.id == reference.occurrenceID || task.lineageID == reference.lineageID
    }

    private func reconcileFocusTimer(at now: Date) {
        focusClock = now
        let reachedEnd = PomodoroEngine.tick(at: now, state: &state.pomodoro)
        if reachedEnd {
            persist()
            synchronizeFocusNotification()
            focusNotificationScheduler.playFallbackSoundIfNeeded()
        }
        updateFocusTicker()
    }

    private func synchronizeFocusNotification() {
        guard case let .running(run, _, deadline, _, _)? = state.pomodoro.activeTimer else {
            focusNotificationScheduler.cancelCompletion()
            return
        }
        focusNotificationScheduler.scheduleCompletion(for: run.task, deadline: deadline)
    }

    private func updateFocusTicker() {
        guard case .running? = state.pomodoro.activeTimer else {
            focusTicker?.cancel()
            focusTicker = nil
            return
        }
        guard focusTicker == nil else { return }
        focusTicker = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self else { return }
                self.reconcileFocusTimer(at: self.nowProvider())
            }
    }

    private static func focusTimeText(_ seconds: Int) -> String {
        let clamped = max(0, seconds)
        return String(format: "%02d:%02d", clamped / 60, clamped % 60)
    }

    private static func compactTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 24 else { return trimmed }
        let end = trimmed.index(trimmed.startIndex, offsetBy: 21)
        return "\(trimmed[..<end])…"
    }

    private func mostRecentPlan(before dateKey: String) -> DayPlan? {
        guard let date = DateKey.date(from: dateKey, calendar: calendar) else { return nil }

        return state.days.compactMap { key, plan -> (date: Date, plan: DayPlan)? in
            guard let planDate = DateKey.date(from: key, calendar: calendar), planDate < date else { return nil }
            return (planDate, plan)
        }
        .max { $0.date < $1.date }?
        .plan
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
