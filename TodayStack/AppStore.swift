import Combine
import Foundation

@MainActor
public final class AppStore: ObservableObject {
    @Published public private(set) var state: AppState
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var focusClock: Date

    public let repository: JSONStateRepository
    public var calendar: Calendar

    /// How many days back the morning check-in looks for an earlier day with unfinished tasks.
    /// Kept under a week so a weekday name is never today's.
    private static let checkInWindowDays = 6

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
        todayPlan.tasks.first(where: { !$0.isCompleted && isMainAction($0) })
            ?? todayPlan.tasks.first(where: { !$0.isCompleted })
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
    public func addTask(
        title: String,
        habitID: String? = nil,
        durationMinutes: Int = TaskItem.defaultDurationMinutes,
        purpose: TaskPurpose = .regular,
        repeatSchedule: RepeatSchedule? = nil
    ) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = "Task titles cannot be empty."
            return nil
        }
        guard !persistenceBlocked else { return nil }
        ensureTodayPlan(persist: false)
        let task = TaskItem(
            title: trimmed,
            habitID: validHabitID(habitID),
            durationMinutes: durationMinutes
        )
        return applyChange { draft in
            draft.days[todayDateKey, default: DayPlan(date: todayDateKey)].tasks.append(task)
            try QuestEngine.assign(taskID: task.id, purpose: purpose, date: todayDateKey, state: &draft)
            if let repeatSchedule {
                try RepeatingTaskEngine.setRepeat(taskID: task.id, schedule: repeatSchedule, date: todayDateKey, state: &draft)
            }
        } ? task.id : nil
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
        RepeatingTaskEngine.syncRoutine(fromTaskID: id, date: todayDateKey, state: &state)
        persist()
    }

    public func updateTaskDuration(id: String, durationMinutes: Int) {
        guard !persistenceBlocked, var plan = state.days[todayDateKey],
              let index = plan.tasks.firstIndex(where: { $0.id == id }) else { return }
        plan.tasks[index].durationMinutes = TaskItem.normalizedDuration(durationMinutes)
        state.days[todayDateKey] = plan
        RepeatingTaskEngine.syncRoutine(fromTaskID: id, date: todayDateKey, state: &state)
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

    public func moveTaskToLater(id: String) {
        parkTask(id: id, returnsOn: nil)
    }

    /// Parks a task in Later until tomorrow, when it returns to Today on its own.
    public func moveTaskToTomorrow(id: String) {
        guard let task = todayPlan.tasks.first(where: { $0.id == id }), canMoveTaskToTomorrow(task) else { return }
        parkTask(id: id, returnsOn: DateKey.string(from: tomorrow, calendar: calendar))
    }

    /// A task can wait for tomorrow unless it repeats and tomorrow already gets its own copy.
    public func canMoveTaskToTomorrow(_ task: TaskItem) -> Bool {
        guard !task.isCompleted else { return false }
        guard let routine = repeatingTask(for: task) else { return true }
        return !routine.schedule.includes(tomorrow, calendar: calendar)
    }

    /// "Tomorrow" (or a short date) for a parked task that returns to Today on its own.
    public func returnLabel(for task: TaskItem) -> String? {
        guard let key = task.returnsOn else { return nil }
        if key == DateKey.string(from: tomorrow, calendar: calendar) { return "Tomorrow" }
        guard let date = DateKey.date(from: key, calendar: calendar) else { return nil }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    private func parkTask(id: String, returnsOn: String?) {
        guard !persistenceBlocked, var plan = state.days[todayDateKey],
              let sourceIndex = plan.tasks.firstIndex(where: { $0.id == id && !$0.isCompleted }) else { return }
        var task = plan.tasks.remove(at: sourceIndex)
        archiveFocusIfNeeded(for: task, outcome: .stopped)
        // A copy parked in Later is a one-off; the repeating task still returns on its next
        // scheduled day. A copy moved to tomorrow stays linked, so that occurrence replaces it.
        if returnsOn == nil { task.repeatingTaskID = nil }
        task.returnsOn = returnsOn
        state.days[todayDateKey] = plan
        state.laterTasks.append(task)
        persist()
    }

    public func moveLaterTaskToToday(id: String, before targetID: String? = nil) {
        guard !persistenceBlocked,
              let sourceIndex = state.laterTasks.firstIndex(where: { $0.id == id }) else { return }
        let restoredTask = continuation(of: state.laterTasks.remove(at: sourceIndex))
        var plan = state.days[todayDateKey, default: DayPlan(date: todayDateKey)]
        if let targetID, let targetIndex = plan.tasks.firstIndex(where: { $0.id == targetID && !$0.isCompleted }) {
            plan.tasks.insert(restoredTask, at: targetIndex)
        } else {
            plan.tasks.append(restoredTask)
        }
        state.days[todayDateKey] = plan
        persist()
    }

    public func deleteLaterTask(id: String) {
        guard !persistenceBlocked else { return }
        let previousCount = state.laterTasks.count
        state.laterTasks.removeAll(where: { $0.id == id })
        guard state.laterTasks.count != previousCount else { return }
        persist()
    }

    /// Unfinished tasks from the most recent earlier day in the past week that still has
    /// some, so they can be marked done on the day they were actually finished. Days up to
    /// `answeredThrough` were already asked about, and work finished on a later day is skipped.
    public func checkIn(answeredThrough: String = "") -> DayCheckIn? {
        let todayKey = todayDateKey
        guard let today = DateKey.date(from: todayKey, calendar: calendar),
              let windowStart = calendar.date(byAdding: .day, value: -Self.checkInWindowDays, to: today),
              let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else { return nil }
        let startKey = DateKey.string(from: windowStart, calendar: calendar)
        // Date keys sort chronologically as strings.
        let earlierKeys = state.days.keys
            .filter { $0 >= startKey && $0 > answeredThrough && $0 < todayKey }
            .sorted(by: >)

        var finishedLater = Set(todayPlan.tasks.filter(\.isCompleted).map(\.lineageID))
        for dateKey in earlierKeys {
            guard let plan = state.days[dateKey] else { continue }
            let tasks = plan.tasks.filter { !$0.isCompleted && !finishedLater.contains($0.lineageID) }
            if !tasks.isEmpty, let date = DateKey.date(from: dateKey, calendar: calendar) {
                let title = dateKey == DateKey.string(from: yesterday, calendar: calendar)
                    ? "Yesterday"
                    : calendar.weekdaySymbols[calendar.component(.weekday, from: date) - 1]
                return DayCheckIn(dateKey: dateKey, title: title, tasks: tasks)
            }
            finishedLater.formUnion(plan.tasks.filter(\.isCompleted).map(\.lineageID))
        }
        return nil
    }

    /// Marks unfinished tasks from an earlier day as done on that day, and clears
    /// their copies that were carried into Today or parked in Later since.
    @discardableResult
    public func completeEarlierTasks(ids: Set<String>, on dateKey: String) -> Bool {
        guard !persistenceBlocked, dateKey < todayDateKey, var plan = state.days[dateKey] else { return false }
        let previous = state
        let now = nowProvider()
        var finishedLineages = Set<String>()
        for index in plan.tasks.indices where ids.contains(plan.tasks[index].id) && !plan.tasks[index].isCompleted {
            plan.tasks[index].isCompleted = true
            let task = plan.tasks[index]
            synchronizeTaskSession(taskID: task.id, date: dateKey, habitID: task.habitID, completed: true)
            QuestEngine.recordTask(task, date: dateKey, now: now, state: &state)
            finishedLineages.insert(task.lineageID)
        }
        guard !finishedLineages.isEmpty else { return false }
        state.days[dateKey] = plan

        let lineages = finishedLineages
        let isLeftover: (TaskItem) -> Bool = { !$0.isCompleted && lineages.contains($0.lineageID) }
        for task in todayPlan.tasks where isLeftover(task) {
            archiveFocusIfNeeded(for: task, outcome: .stopped)
        }
        state.days[todayDateKey]?.tasks.removeAll(where: isLeftover)
        state.laterTasks.removeAll(where: isLeftover)
        let saved = persist(revertingTo: previous)
        synchronizeFocusNotification()
        updateFocusTicker()
        return saved
    }

    public func setTaskCompleted(id: String, completed: Bool) {
        guard !persistenceBlocked, var plan = state.days[todayDateKey], let index = plan.tasks.firstIndex(where: { $0.id == id }) else { return }
        let previous = state
        var task = plan.tasks[index]
        guard task.isCompleted != completed else { return }
        task.isCompleted = completed
        plan.tasks[index] = task
        state.days[todayDateKey] = plan
        synchronizeTaskSession(taskID: task.id, date: todayDateKey, habitID: task.habitID, completed: completed)
        if completed {
            QuestEngine.recordTask(task, date: todayDateKey, now: nowProvider(), state: &state)
            archiveFocusIfNeeded(for: task, outcome: .completedTask)
        }
        persist(revertingTo: previous)
        synchronizeFocusNotification()
        updateFocusTicker()
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
        RepeatingTaskEngine.syncRoutine(fromTaskID: id, date: todayDateKey, state: &state)
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
        for index in state.repeatingTasks.indices where state.repeatingTasks[index].habitID == id {
            state.repeatingTasks[index].habitID = nil
        }
        state.sessions.removeAll(where: { $0.habitID == id })
        persist()
    }

    /// Toggle only the manual session for today. A task-created session remains
    /// intact when a manual log is removed.
    public func toggleManualHabitToday(id: String) {
        guard !persistenceBlocked, state.habits.contains(where: { $0.id == id }) else { return }
        let previous = state
        let date = todayDateKey
        let hasManualSession = state.sessions.contains { $0.habitID == id && $0.date == date && $0.source == .manual }
        if hasManualSession {
            state.sessions.removeAll { $0.habitID == id && $0.date == date && $0.source == .manual }
        } else {
            // A completed linked task has already fulfilled this habit today.
            // Do not create a second completion for the same day.
            guard !state.sessions.contains(where: { $0.habitID == id && $0.date == date }) else { return }
            state.sessions.append(HabitSession(habitID: id, date: date, source: .manual))
            QuestEngine.recordHabit(id, date: date, now: nowProvider(), state: &state)
        }
        persist(revertingTo: previous)
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

    public func taskCompletionCountToday(for habit: Habit) -> Int {
        state.sessions.filter {
            $0.habitID == habit.id && $0.date == todayDateKey && $0.source == .task
        }.count
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
        var changed = false
        if state.days[todayDateKey] == nil {
            // A repeating task gets a fresh occurrence on each scheduled day, so an
            // unfinished earlier occurrence is replaced rather than carried.
            let repeatingTaskIDs = Set(state.repeatingTasks.map(\.id))
            let carriedTasks = mostRecentPlan(before: todayDateKey)?.tasks
                .filter { !$0.isCompleted && !($0.repeatingTaskID.map(repeatingTaskIDs.contains) ?? false) }
                .map { continuation(of: $0) } ?? []
            let repeatingTasks = RepeatingTaskEngine.occurrences(on: todayDateKey, state: state, calendar: calendar)
            state.days[todayDateKey] = DayPlan(date: todayDateKey, tasks: repeatingTasks + carriedTasks)
            changed = true
        }

        // Parked tasks come back on their return day, or on the first day the app is opened after it.
        let todayKey = todayDateKey
        let isDue: (TaskItem) -> Bool = { task in task.returnsOn.map { $0 <= todayKey } ?? false }
        let returningTasks = state.laterTasks.filter(isDue)
        if !returningTasks.isEmpty {
            state.laterTasks.removeAll(where: isDue)
            // A deferred copy gives way when its repeating task already has an occurrence today.
            let repeatingToday = Set(state.days[todayDateKey]?.tasks.compactMap(\.repeatingTaskID) ?? [])
            let arriving = returningTasks.filter { !($0.repeatingTaskID.map(repeatingToday.contains) ?? false) }
            state.days[todayDateKey]?.tasks += arriving.map { continuation(of: $0) }
            changed = true
        }

        if changed && shouldPersist { persist() }
    }

    /// A new occurrence of a carried or parked task for today that keeps its lineage,
    /// and its repeating task while that still exists.
    private func continuation(of task: TaskItem) -> TaskItem {
        TaskItem(
            lineageID: task.lineageID,
            title: task.title,
            habitID: validHabitID(task.habitID),
            durationMinutes: task.durationMinutes,
            purpose: task.purpose,
            repeatingTaskID: task.repeatingTaskID.flatMap { id in
                state.repeatingTasks.contains { $0.id == id } ? id : nil
            }
        )
    }

    private var tomorrow: Date {
        let today = calendar.startOfDay(for: nowProvider())
        return calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(24 * 60 * 60)
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
        let previous = state
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
            QuestEngine.recordTask(completedTask, date: todayDateKey, now: now, state: &state)
            state.days[todayDateKey] = plan
            synchronizeTaskSession(
                taskID: completedTask.id,
                date: todayDateKey,
                habitID: completedTask.habitID,
                completed: true
            )
        }

        guard PomodoroEngine.end(outcome: outcome, at: now, state: &state.pomodoro) != nil else { state = previous; return }

        persist(revertingTo: previous)
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

    @discardableResult
    private func persist(revertingTo previous: AppState? = nil) -> Bool {
        guard !persistenceBlocked else { return false }
        do {
            try repository.save(state)
            return true
        } catch {
            if let previous { state = previous }
            errorMessage = error.localizedDescription
            return false
        }
    }

    public var hasMainProgressToday: Bool {
        state.questSystem.activities.contains { $0.date == todayDateKey && $0.isMainProgress }
    }

    public var mainQuestStreak: Int {
        let habit = Habit(id: "main-quest-streak", slug: "main-quest-streak", name: "Main Quest")
        let sessions = Set(state.questSystem.activities.filter(\.isMainProgress).map(\.date)).map {
            HabitSession(habitID: habit.id, date: $0)
        }
        return StreakCalculator.currentStreak(for: habit, sessions: sessions, today: nowProvider(), calendar: calendar)
    }

    public func isMainAction(_ task: TaskItem) -> Bool {
        guard let id = task.purpose.questID else { return false }
        return state.questSystem.activeQuests.contains { $0.id == id }
    }

    @discardableResult
    public func saveQuest(_ quest: MainQuest, attachingTaskID: String? = nil) -> Bool {
        applyChange { draft in
            try QuestEngine.saveQuest(quest, state: &draft)
            if let attachingTaskID {
                try QuestEngine.assign(taskID: attachingTaskID, purpose: .mainQuest(quest.id), date: todayDateKey, state: &draft)
                RepeatingTaskEngine.syncRoutine(fromTaskID: attachingTaskID, date: todayDateKey, state: &draft)
            }
        }
    }

    @discardableResult
    public func assignTask(id: String, purpose: TaskPurpose) -> Bool {
        applyChange { draft in
            try QuestEngine.assign(taskID: id, purpose: purpose, date: todayDateKey, state: &draft)
            RepeatingTaskEngine.syncRoutine(fromTaskID: id, date: todayDateKey, state: &draft)
        }
    }

    @discardableResult
    public func updateQuestProgress(id: String, value: Double) -> Bool {
        applyChange { try QuestEngine.updateProgress(id: id, value: value, date: todayDateKey, now: nowProvider(), state: &$0) }
    }

    @discardableResult
    public func setQuestStatus(id: String, status: MainQuest.Status, demoteTasks: Bool = false) -> Bool {
        applyChange { try QuestEngine.setStatus(id: id, status: status, demoteTasks: demoteTasks, date: todayDateKey, now: nowProvider(), state: &$0) }
    }

    @discardableResult
    public func saveReward(_ reward: QuestReward) -> Bool {
        applyChange { try QuestEngine.saveReward(reward, state: &$0) }
    }

    @discardableResult
    public func redeemReward(id: String, requestID: String) -> Bool {
        applyChange { try QuestEngine.redeem(id: id, requestID: requestID, date: todayDateKey, now: nowProvider(), state: &$0) }
    }

    public func repeatingTask(for task: TaskItem) -> RepeatingTask? {
        guard let id = task.repeatingTaskID else { return nil }
        return state.repeatingTasks.first { $0.id == id }
    }

    /// Starts, reschedules or (with `nil`) stops repeating one of today's tasks.
    @discardableResult
    public func setTaskRepeat(id: String, schedule: RepeatSchedule?) -> Bool {
        applyChange { try RepeatingTaskEngine.setRepeat(taskID: id, schedule: schedule, date: todayDateKey, state: &$0) }
    }

    @discardableResult
    public func updateRepeatingTask(_ routine: RepeatingTask) -> Bool {
        applyChange { try RepeatingTaskEngine.update(routine, date: todayDateKey, state: &$0) }
    }

    @discardableResult
    public func stopRepeatingTask(id: String) -> Bool {
        applyChange { RepeatingTaskEngine.stop(id: id, date: todayDateKey, state: &$0) }
    }

    private func applyChange(_ change: (inout AppState) throws -> Void) -> Bool {
        guard !persistenceBlocked else { return false }
        do {
            var draft = state
            try change(&draft)
            try repository.save(draft)
            state = draft
            errorMessage = nil
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    private static func slug(from value: String) -> String {
        let lowercased = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let pieces = lowercased.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return pieces.joined(separator: "-")
    }
}
