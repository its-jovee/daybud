import AppKit
import SwiftUI

private enum StackTab: String, CaseIterable, Identifiable {
    case active
    case done
    case stats

    var id: String { rawValue }
}

private enum HabitIconCatalog {
    static let symbols = [
        "flame.fill",
        "dumbbell.fill",
        "book.fill",
        "laptopcomputer",
        "figure.run",
        "paintpalette.fill",
        "briefcase.fill",
        "heart.fill",
        "leaf.fill",
        "moon.stars.fill",
        "fork.knife",
        "music.note",
        "pencil",
        "brain.head.profile",
        "camera.fill",
        "person.2.fill"
    ]

    static func suggestedSymbol(for name: String) -> String {
        let lowercased = name.lowercased()
        let suggestions: [(keywords: [String], symbol: String)] = [
            (["gym", "workout", "lift", "strength"], "dumbbell.fill"),
            (["run", "walk", "cardio"], "figure.run"),
            (["study", "read", "book", "learn"], "book.fill"),
            (["code", "program", "work", "job"], "laptopcomputer"),
            (["write", "journal", "story"], "pencil"),
            (["paint", "art", "draw"], "paintpalette.fill"),
            (["sleep", "bed"], "moon.stars.fill"),
            (["eat", "food", "cook"], "fork.knife"),
            (["meditat", "mind", "therapy"], "brain.head.profile"),
            (["music", "piano", "guitar"], "music.note"),
            (["photo", "camera"], "camera.fill"),
            (["friend", "family", "social"], "person.2.fill"),
            (["health", "heart"], "heart.fill"),
            (["nature", "garden", "plant"], "leaf.fill")
        ]
        return suggestions.first(where: { entry in
            entry.keywords.contains(where: lowercased.contains)
        })?.symbol ?? "flame.fill"
    }

    static func displayName(for symbol: String) -> String {
        switch symbol {
        case "flame.fill": "Flame"
        case "dumbbell.fill": "Fitness"
        case "book.fill": "Reading"
        case "laptopcomputer": "Computer"
        case "figure.run": "Running"
        case "paintpalette.fill": "Art"
        case "briefcase.fill": "Work"
        case "heart.fill": "Health"
        case "leaf.fill": "Nature"
        case "moon.stars.fill": "Sleep"
        case "fork.knife": "Food"
        case "music.note": "Music"
        case "pencil": "Writing"
        case "brain.head.profile": "Mindfulness"
        case "camera.fill": "Photography"
        case "person.2.fill": "People"
        default: "Habit"
        }
    }
}

private enum HabitColorCatalog {
    static let colors: [Color] = [
        Color(red: 0.96, green: 0.39, blue: 0.49),
        Color(red: 0.96, green: 0.58, blue: 0.24),
        Color(red: 0.91, green: 0.74, blue: 0.20),
        Color(red: 0.35, green: 0.76, blue: 0.48),
        Color(red: 0.24, green: 0.72, blue: 0.70),
        Color(red: 0.30, green: 0.61, blue: 0.92),
        Color(red: 0.51, green: 0.47, blue: 0.94),
        Color(red: 0.77, green: 0.42, blue: 0.88),
        Color(red: 0.91, green: 0.42, blue: 0.72)
    ]

    static func color(for habit: Habit, in habits: [Habit]) -> Color {
        guard let index = habits.firstIndex(where: { $0.id == habit.id }) else {
            return colors[0]
        }
        return colors[index % colors.count]
    }
}

private enum ActivePanel {
    case addTask
    case addTaskForHabit(Habit)
    case editTask(TaskItem)
    case pomodoroSettings
    case addHabit
    case editHabit(Habit)
    case deleteHabit(Habit)

    var belongsToTodaySection: Bool {
        switch self {
        case .addTask, .addTaskForHabit, .editTask, .pomodoroSettings:
            return true
        case .addHabit, .editHabit, .deleteHabit:
            return false
        }
    }
}

struct MenuBarRootView: View {
    @ObservedObject var store: AppStore
    @State private var activePanel: ActivePanel?
    @State private var selectedTab: StackTab = .active
    @State private var showingCelebration = false
    @State private var celebrationID = 0
    @State private var statisticsPeriod: StatisticsPeriod = .sevenDays
    @State private var statisticsMetric: StatisticsMetric = .tasks

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Label("Daybud", systemImage: "checklist")
                        .font(.headline)
                    Spacer()
                    Text(store.progressText)
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }

                ProgressView(
                    value: Double(store.completedTaskCount),
                    total: Double(max(store.totalTaskCount, 1))
                )
                .progressViewStyle(.linear)
                .controlSize(.small)
                .accessibilityLabel("Task progress")
                .accessibilityValue(store.progressText)
                .animation(.easeInOut(duration: 0.3), value: store.completedTaskCount)

                Picker("Items", selection: tabSelection) {
                    Text("Active \(activeCount)").tag(StackTab.active)
                    Text("Done \(store.completedTaskCount)").tag(StackTab.done)
                    Label("Stats", systemImage: "chart.bar.xaxis").tag(StackTab.stats)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            if selectedTab == .stats {
                StatisticsView(
                    snapshot: store.statisticsSnapshot(period: statisticsPeriod),
                    period: $statisticsPeriod,
                    metric: $statisticsMetric,
                    onClose: { switchTab(to: .active) }
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                if let activePanel, !activePanel.belongsToTodaySection {
                    inlinePanel(activePanel)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    Divider()
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }

                HabitsSectionView(
                    store: store,
                    onAdd: {
                        selectedTab = .active
                        showPanel(.addHabit)
                    },
                    onPlanTask: { habit in
                        selectedTab = .active
                        showPanel(.addTaskForHabit(habit))
                    },
                    onEdit: { showPanel(.editHabit($0)) },
                    onDelete: { showPanel(.deleteHabit($0)) }
                )

                Divider()
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)

                TodaySectionView(
                    store: store,
                    selectedTab: selectedTab,
                    onAdd: {
                        selectedTab = .active
                        showPanel(.addTask)
                    },
                    onFocusSettings: { showPanel(.pomodoroSettings) },
                    onEdit: { showPanel(.editTask($0)) },
                    onDelete: { id in
                        withAnimation(.snappy(duration: 0.24)) {
                            store.deleteTask(id: id)
                        }
                    }
                ) {
                    Group {
                        if let activePanel, activePanel.belongsToTodaySection {
                            inlinePanel(activePanel)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                }
            }

            if let error = store.errorMessage {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .accessibilityHidden(true)
                    Text(error)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Dismiss") { store.dismissError() }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .accessibilityLabel("Dismiss error")
                }
                .foregroundStyle(.orange)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
        }
        .frame(width: 380)
        .overlay(alignment: .top) {
            if showingCelebration {
                ConfettiBurstView()
                    .id(celebrationID)
                    .padding(.top, 58)
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .animation(.snappy(duration: 0.26), value: activePanel != nil)
        .onAppear { store.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refresh()
        }
        .onChange(of: store.allHabitsCompletedToday) { _, allDone in
            guard allDone else { return }
            celebrateAllHabits()
        }
    }

    @ViewBuilder
    private func inlinePanel(_ panel: ActivePanel) -> some View {
        switch panel {
        case .addTask:
            TaskEditorView(habits: store.state.habits, onCancel: closePanel) { title, habitID in
                store.addTask(title: title, habitID: habitID)
                closePanel()
            }
            .id("add-task")
        case .addTaskForHabit(let habit):
            TaskEditorView(
                habits: store.state.habits,
                preselectedHabitID: habit.id,
                onCancel: closePanel
            ) { title, habitID in
                store.addTask(title: title, habitID: habitID)
                closePanel()
            }
            .id("add-task-for-habit-\(habit.id)")
        case .editTask(let task):
            TaskEditorView(task: task, habits: store.state.habits, onCancel: closePanel) { title, habitID in
                store.updateTaskTitle(id: task.id, title: title)
                store.setTaskHabit(id: task.id, habitID: habitID)
                closePanel()
            }
            .id("edit-task-\(task.id)")
        case .pomodoroSettings:
            PomodoroSettingsView(
                settings: store.state.pomodoro.settings,
                onCancel: closePanel
            ) { settings in
                store.updatePomodoroSettings(settings)
                closePanel()
            }
            .id("pomodoro-settings")
        case .addHabit:
            HabitEditorView(habit: nil, onCancel: closePanel) { name, frequency, iconName in
                store.addHabit(name: name, frequency: frequency, iconName: iconName)
                closePanel()
            }
            .id("add-habit")
        case .editHabit(let habit):
            HabitEditorView(habit: habit, onCancel: closePanel) { name, frequency, iconName in
                store.renameHabit(id: habit.id, name: name)
                store.setHabitFrequency(id: habit.id, frequency: frequency)
                store.setHabitIcon(id: habit.id, iconName: iconName)
                closePanel()
            }
            .id("edit-habit-\(habit.id)")
        case .deleteHabit(let habit):
            DeleteHabitView(habit: habit, onCancel: closePanel) {
                store.deleteHabit(id: habit.id)
                closePanel()
            }
            .id("delete-habit-\(habit.id)")
        }
    }

    private func showPanel(_ panel: ActivePanel) {
        withAnimation(.snappy(duration: 0.26)) {
            activePanel = panel
        }
    }

    private func closePanel() {
        withAnimation(.snappy(duration: 0.22)) {
            activePanel = nil
        }
    }

    private var activeCount: Int {
        store.todayPlan.tasks.filter { !$0.isCompleted }.count
    }

    private var tabSelection: Binding<StackTab> {
        Binding(
            get: { selectedTab },
            set: { switchTab(to: $0) }
        )
    }

    private func switchTab(to tab: StackTab) {
        guard tab != selectedTab else { return }
        withAnimation(.spring(response: 0.58, dampingFraction: 0.86, blendDuration: 0.18)) {
            activePanel = nil
            selectedTab = tab
        }
    }

    private func celebrateAllHabits() {
        celebrationID += 1
        withAnimation(.easeOut(duration: 0.15)) {
            showingCelebration = true
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_250_000_000)
            withAnimation(.easeOut(duration: 0.25)) {
                showingCelebration = false
            }
        }
    }
}

private struct ConfettiBurstView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var launched = false

    private let colors: [Color] = [.green, .mint, .yellow, .orange, .cyan]

    var body: some View {
        ZStack {
            if reduceMotion {
                Image(systemName: "sparkles")
                    .font(.title.weight(.semibold))
                    .foregroundStyle(.green)
                    .scaleEffect(launched ? 1.12 : 0.8)
                    .opacity(launched ? 0 : 1)
                    .animation(.easeOut(duration: 0.7), value: launched)
            } else {
                ForEach(0..<22, id: \.self) { index in
                    Capsule()
                        .fill(colors[index % colors.count])
                        .frame(width: index.isMultiple(of: 3) ? 5 : 4, height: index.isMultiple(of: 3) ? 12 : 9)
                        .rotationEffect(.degrees(launched ? Double(index * 83) : Double(index * 9)))
                        .offset(
                            x: launched ? horizontalOffset(for: index) : 0,
                            y: launched ? verticalOffset(for: index) : 0
                        )
                        .opacity(launched ? 0 : 1)
                        .animation(
                            .easeOut(duration: 0.9)
                                .delay(Double(index % 5) * 0.018),
                            value: launched
                        )
                }

                Image(systemName: "checkmark.seal.fill")
                    .font(.title2)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .green)
                    .scaleEffect(launched ? 1.25 : 0.72)
                    .opacity(launched ? 0 : 1)
                    .animation(.easeOut(duration: 0.72), value: launched)
            }
        }
        .frame(width: 330, height: 170)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear {
            DispatchQueue.main.async {
                launched = true
            }
        }
    }

    private func horizontalOffset(for index: Int) -> CGFloat {
        CGFloat((index * 47) % 286 - 143)
    }

    private func verticalOffset(for index: Int) -> CGFloat {
        CGFloat(30 + (index * 37) % 120)
    }
}

private struct TodaySectionView<InlineEditor: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var store: AppStore
    @State private var draggedTaskID: String?
    @State private var dragTranslation: CGFloat = 0
    @State private var dropTargetTaskID: String?
    @State private var taskRowFrames: [String: CGRect] = [:]
    @State private var completingTaskIDs: Set<String> = []
    let selectedTab: StackTab
    let onAdd: () -> Void
    let onFocusSettings: () -> Void
    let onEdit: (TaskItem) -> Void
    let onDelete: (String) -> Void
    let inlineEditor: () -> InlineEditor

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Today", systemImage: "sun.max")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button(action: onFocusSettings) {
                    Image(systemName: "timer")
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .imageScale(.medium)
                .help("Pomodoro settings")
                .accessibilityLabel("Pomodoro settings")
                Button(action: onAdd) {
                    Image(systemName: "plus.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .imageScale(.large)
                .accessibilityLabel("Add task")
            }
            .padding(.horizontal, 14)

            inlineEditor()

            FocusTimerCard(
                presentation: store.focusPresentation,
                settings: store.state.pomodoro.settings,
                canMarkDone: store.canMarkFocusedTaskDone,
                onPause: store.pauseFocus,
                onResume: store.resumeFocus,
                onStop: store.stopFocus,
                onMoreTime: store.addMoreFocusTime,
                onMarkDone: store.markFocusedTaskDone,
                onOpenSettings: onFocusSettings
            )
            .transition(.move(edge: .top).combined(with: .opacity))

            if selectedTab == .active && visibleTasks.count > 1 {
                Label("Click and hold a task, then drag to reorder", systemImage: "arrow.up.arrow.down")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 14)
                    .transition(.opacity)
            }

            if visibleTasks.isEmpty {
                Label(emptyMessage, systemImage: selectedTab == .active ? "checkmark.circle" : "tray")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 2) {
                    ForEach(Array(visibleTasks.enumerated()), id: \.element.id) { index, task in
                        TaskRowView(
                            task: task,
                            isCurrent: store.currentTask?.id == task.id,
                            isCompleting: completingTaskIDs.contains(task.id),
                            habits: store.state.habits,
                            onToggle: { completed in toggleTask(task, completed: completed) },
                            onAssignHabit: { habitID in
                                withAnimation(.snappy(duration: 0.22)) {
                                    store.setTaskHabit(id: task.id, habitID: habitID)
                                }
                            },
                            isFocused: isFocused(task),
                            canStartFocus: !store.hasActiveFocusTimer && !completingTaskIDs.contains(task.id),
                            onStartFocus: { store.startFocus(on: task) },
                            onEdit: { onEdit(task) },
                            onDelete: { onDelete(task.id) }
                        )
                        .transition(tabTransition)
                        .animation(staggeredAnimation(for: index), value: selectedTab)
                        .background {
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: TaskRowFramePreferenceKey.self,
                                    value: [task.id: proxy.frame(in: .named("today-task-list"))]
                                )
                            }
                        }
                        .overlay {
                            if dropTargetTaskID == task.id {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.accentColor.opacity(0.75), lineWidth: 1.5)
                                    .allowsHitTesting(false)
                            }
                        }
                        .opacity(draggedTaskID == task.id ? 0.78 : 1)
                        .scaleEffect(draggedTaskID == task.id ? 1.018 : 1)
                        .offset(y: draggedTaskID == task.id ? dragTranslation : 0)
                        .shadow(
                            color: .black.opacity(draggedTaskID == task.id ? 0.18 : 0),
                            radius: draggedTaskID == task.id ? 8 : 0,
                            y: draggedTaskID == task.id ? 3 : 0
                        )
                        .zIndex(draggedTaskID == task.id ? 2 : 0)
                        .simultaneousGesture(taskReorderGesture(for: task.id))
                    }
                }
                .animation(.snappy(duration: 0.24), value: store.todayPlan.tasks)
                .padding(.horizontal, 8)
                .coordinateSpace(name: "today-task-list")
                .onPreferenceChange(TaskRowFramePreferenceKey.self) { taskRowFrames = $0 }
            }
        }
    }

    private var visibleTasks: [TaskItem] {
        store.todayPlan.tasks.filter { task in
            selectedTab == .done ? task.isCompleted : !task.isCompleted
        }
    }

    private func isFocused(_ task: TaskItem) -> Bool {
        let reference: FocusTaskReference?
        switch store.focusPresentation {
        case .idle:
            reference = nil
        case .running(let task, _, _, _, _),
             .paused(let task, _, _, _, _),
             .awaitingDecision(let task, _, _):
            reference = task
        }
        guard let reference else { return false }
        return task.id == reference.occurrenceID || task.lineageID == reference.lineageID
    }

    private var emptyMessage: String {
        switch selectedTab {
        case .active:
            return store.todayPlan.tasks.isEmpty ? "Nothing planned yet" : "All tasks are done"
        case .done:
            return "Completed tasks land here"
        case .stats:
            return ""
        }
    }

    private var tabTransition: AnyTransition {
        if selectedTab == .done {
            return .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            )
        }
        return .asymmetric(
            insertion: .move(edge: .leading).combined(with: .opacity),
            removal: .move(edge: .trailing).combined(with: .opacity)
        )
    }

    private func staggeredAnimation(for index: Int) -> Animation {
        .spring(response: 0.58, dampingFraction: 0.84, blendDuration: 0.16)
            .delay(Double(min(index, 10)) * 0.038)
    }

    private func toggleTask(_ task: TaskItem, completed: Bool) {
        guard completed else {
            withAnimation(.snappy(duration: 0.28)) {
                store.setTaskCompleted(id: task.id, completed: false)
            }
            return
        }

        withAnimation(.snappy(duration: reduceMotion ? 0.1 : 0.28)) {
            _ = completingTaskIDs.insert(task.id)
        }

        Task { @MainActor in
            if !reduceMotion {
                try? await Task.sleep(nanoseconds: 560_000_000)
            }
            withAnimation(.snappy(duration: reduceMotion ? 0.1 : 0.34)) {
                store.setTaskCompleted(id: task.id, completed: true)
                completingTaskIDs.remove(task.id)
            }
        }
    }

    private func taskReorderGesture(for taskID: String) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named("today-task-list"))
            .onChanged { value in
                guard selectedTab == .active, !completingTaskIDs.contains(taskID) else { return }
                if draggedTaskID == nil {
                    draggedTaskID = taskID
                }
                guard draggedTaskID == taskID else { return }
                dragTranslation = value.translation.height
                dropTargetTaskID = reorderTarget(at: value.location.y, excluding: taskID)
            }
            .onEnded { _ in
                guard draggedTaskID == taskID else { return }
                let targetID = dropTargetTaskID
                withAnimation(.spring(response: 0.42, dampingFraction: 0.84)) {
                    if let targetID {
                        moveTask(taskID, over: targetID)
                    }
                    draggedTaskID = nil
                    dropTargetTaskID = nil
                    dragTranslation = 0
                }
            }
    }

    private func reorderTarget(at yPosition: CGFloat, excluding sourceID: String) -> String? {
        let candidates = visibleTasks.compactMap { task -> (id: String, frame: CGRect)? in
            guard task.id != sourceID, let frame = taskRowFrames[task.id] else { return nil }
            return (task.id, frame)
        }
        guard !candidates.isEmpty else { return nil }

        let sorted = candidates.sorted { $0.frame.midY < $1.frame.midY }
        if let first = sorted.first, yPosition <= first.frame.midY { return first.id }
        if let last = sorted.last, yPosition >= last.frame.midY { return last.id }

        guard let nearest = sorted.min(by: {
            abs($0.frame.midY - yPosition) < abs($1.frame.midY - yPosition)
        }) else { return nil }
        let threshold = max(nearest.frame.height * 0.68, 24)
        return abs(nearest.frame.midY - yPosition) <= threshold ? nearest.id : nil
    }

    private func moveTask(_ sourceID: String, over targetID: String?) {
        guard let targetID else {
            store.moveTask(id: sourceID, before: nil)
            return
        }

        let tasks = store.todayPlan.tasks
        guard
            let sourceIndex = tasks.firstIndex(where: { $0.id == sourceID }),
            let targetIndex = tasks.firstIndex(where: { $0.id == targetID }),
            sourceIndex != targetIndex
        else { return }

        if sourceIndex < targetIndex {
            let nextIndex = targetIndex + 1
            let nextTaskID = nextIndex < tasks.count ? tasks[nextIndex].id : nil
            store.moveTask(id: sourceID, before: nextTaskID)
        } else {
            store.moveTask(id: sourceID, before: targetID)
        }
    }
}

private struct TaskRowFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct TaskRowView: View {
    @State private var isHovered = false
    let task: TaskItem
    let isCurrent: Bool
    let isCompleting: Bool
    let habits: [Habit]
    let onToggle: (Bool) -> Void
    let onAssignHabit: (String?) -> Void
    let isFocused: Bool
    let canStartFocus: Bool
    let onStartFocus: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Button {
                guard !isCompleting else { return }
                onToggle(!task.isCompleted)
            } label: {
                Image(systemName: displayedCompleted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isCompleting ? Color.green : (task.isCompleted ? Color.secondary : Color.secondary))
                    .imageScale(.medium)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: displayedCompleted)
            }
            .buttonStyle(.plain)
            .disabled(isCompleting)
            .accessibilityLabel(task.isCompleted ? "Mark \(task.title) incomplete" : "Mark \(task.title) complete")

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    if isCurrent {
                        Text("NEXT")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.tint)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12), in: Capsule())
                            .accessibilityLabel("Current task")
                    }
                    Text(task.title)
                        .font(.callout)
                        .strikethrough(displayedCompleted)
                        .foregroundStyle(isCompleting ? Color.green : (task.isCompleted ? Color.secondary : Color.primary))
                        .lineLimit(2)
                    if let linkedHabit {
                        Image(systemName: linkedHabit.iconName ?? HabitIconCatalog.suggestedSymbol(for: linkedHabit.name))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(task.isCompleted ? Color.secondary : linkedHabitColor)
                            .frame(width: 19, height: 19)
                            .background(linkedHabitColor.opacity(task.isCompleted ? 0.04 : 0.13), in: Circle())
                            .allowsHitTesting(false)
                            .help("Counts toward \(linkedHabit.name)")
                            .accessibilityLabel("Counts toward \(linkedHabit.name)")
                    }
                }
            }

            Spacer(minLength: 0)

            if !task.isCompleted {
                Button(action: onStartFocus) {
                    Image(systemName: isFocused ? "timer.circle.fill" : "play.circle")
                        .foregroundStyle(isFocused ? Color.accentColor : Color.secondary)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .disabled(!canStartFocus)
                .help(isFocused ? "Pomodoro in progress" : "Start Pomodoro for \(task.title)")
                .accessibilityLabel(isFocused ? "Pomodoro in progress for \(task.title)" : "Start Pomodoro for \(task.title)")
            }

            Menu {
                if !habits.isEmpty || task.habitID != nil {
                    Menu("Counts toward", systemImage: "arrow.triangle.branch") {
                        habitMenuContent
                    }
                    Divider()
                }
                Button("Edit task", action: onEdit)
                Button("Delete task", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .accessibilityLabel("More actions for \(task.title)")
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    isCompleting
                        ? Color.green.opacity(0.16)
                        : task.isCompleted
                            ? Color.primary.opacity(isHovered ? 0.05 : 0.025)
                            : isCurrent
                        ? Color.accentColor.opacity(isHovered ? 0.13 : 0.08)
                        : Color.primary.opacity(isHovered ? 0.045 : 0)
                )
        }
        .contentShape(Rectangle())
        .opacity(task.isCompleted ? 0.58 : (isCompleting ? 0.88 : 1))
        .offset(x: task.isCompleted ? 8 : (isCompleting ? 4 : 0))
        .scaleEffect(isCompleting ? 1.015 : 1)
        .onHover { isHovered = $0 }
        .help("Click and hold, then drag to reorder \(task.title)")
        .accessibilityHint("Click and hold, then drag to reorder")
        .animation(.easeInOut(duration: 0.18), value: isCurrent)
        .animation(.easeInOut(duration: 0.14), value: isHovered)
        .animation(.snappy(duration: 0.3), value: isCompleting)
        .animation(.snappy(duration: 0.3), value: task.isCompleted)
    }

    private var displayedCompleted: Bool {
        task.isCompleted || isCompleting
    }

    private var linkedHabit: Habit? {
        guard let habitID = task.habitID else { return nil }
        return habits.first(where: { $0.id == habitID })
    }

    private var linkedHabitColor: Color {
        guard let linkedHabit else { return .accentColor }
        return HabitColorCatalog.color(for: linkedHabit, in: habits)
    }

    @ViewBuilder
    private var habitMenuContent: some View {
        Button("Doesn't count toward a habit") { onAssignHabit(nil) }
        if !habits.isEmpty { Divider() }
        ForEach(habits) { habit in
            Button {
                onAssignHabit(habit.id)
            } label: {
                HStack {
                    Text(habit.name)
                    if task.habitID == habit.id { Image(systemName: "checkmark") }
                }
            }
        }
    }
}

private struct HabitsSectionView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var store: AppStore
    @State private var completingHabitIDs: Set<String> = []
    let onAdd: () -> Void
    let onPlanTask: (Habit) -> Void
    let onEdit: (Habit) -> Void
    let onDelete: (Habit) -> Void

    private let activityColumnCount = 5

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.fixed(70), spacing: 0, alignment: .center),
            count: activityColumnCount
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label("Habits", systemImage: "square.grid.2x2")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if !store.state.habits.isEmpty {
                    Text("\(store.completedHabitCount)/\(store.state.habits.count) · \(currentMonthTitle)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                Button(action: onAdd) {
                    Image(systemName: "plus.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .imageScale(.large)
                .accessibilityLabel("Add habit")
            }
            .padding(.horizontal, 14)

            if store.state.habits.isEmpty {
                Label("Add a habit to start painting your month", systemImage: "square.dashed")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 0) {
                    ForEach(Array(store.state.habits.enumerated()), id: \.element.id) { index, habit in
                        HabitActivityTile(
                        habit: habit,
                        tint: HabitColorCatalog.color(for: habit, in: store.state.habits),
                        isLoggedToday: store.isLoggedToday(habit: habit),
                        hasManualLogToday: store.hasManualLogToday(habit: habit),
                        completionTaskTitle: store.completionTaskTitle(for: habit),
                        weeklyProgress: store.weeklyProgress(for: habit),
                        isCompleting: completingHabitIDs.contains(habit.id),
                        activityCounts: store.activityCounts(for: habit),
                        calendar: store.calendar,
                        todayDateKey: store.todayDateKey,
                        onToggle: { toggleHabit(habit) },
                        onChangeIcon: { iconName in
                            withAnimation(.snappy(duration: 0.22)) {
                                store.setHabitIcon(id: habit.id, iconName: iconName)
                            }
                        },
                        onPlanTask: { onPlanTask(habit) },
                        onEdit: { onEdit(habit) },
                        onDelete: { onDelete(habit) }
                    )
                        .transition(.scale(scale: 0.92).combined(with: .opacity))
                        .animation(
                            .spring(response: 0.48, dampingFraction: 0.82)
                                .delay(Double(min(index, 8)) * 0.025),
                            value: store.state.habits.count
                        )
                    }
                }
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .animation(.snappy(duration: 0.24), value: store.state.sessions)
    }

    private var currentMonthTitle: String {
        guard let date = DateKey.date(from: store.todayDateKey, calendar: store.calendar) else { return "Month" }
        let formatter = DateFormatter()
        formatter.calendar = store.calendar
        formatter.locale = .current
        formatter.dateFormat = "MMM"
        return formatter.string(from: date)
    }

    private func toggleHabit(_ habit: Habit) {
        let alreadyLogged = store.isLoggedToday(habit: habit)
        guard !alreadyLogged else {
            guard store.hasManualLogToday(habit: habit) else { return }
            withAnimation(.snappy(duration: 0.28)) {
                store.toggleManualHabitToday(id: habit.id)
            }
            return
        }

        withAnimation(.snappy(duration: reduceMotion ? 0.1 : 0.26)) {
            _ = completingHabitIDs.insert(habit.id)
            store.toggleManualHabitToday(id: habit.id)
        }
        Task { @MainActor in
            if !reduceMotion {
                try? await Task.sleep(nanoseconds: 420_000_000)
            }
            withAnimation(.snappy(duration: reduceMotion ? 0.1 : 0.32)) {
                _ = completingHabitIDs.remove(habit.id)
            }
        }
    }
}

private struct HabitActivityTile: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    let habit: Habit
    let tint: Color
    let isLoggedToday: Bool
    let hasManualLogToday: Bool
    let completionTaskTitle: String?
    let weeklyProgress: WeeklyProgress?
    let isCompleting: Bool
    let activityCounts: [String: Int]
    let calendar: Calendar
    let todayDateKey: String
    let onToggle: () -> Void
    let onChangeIcon: (String) -> Void
    let onPlanTask: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        ZStack {
            HabitMiniMonthGrid(
                tint: tint,
                activityCounts: activityCounts,
                calendar: calendar,
                todayDateKey: todayDateKey
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .blur(radius: isRevealed ? 2.4 : 0)
            .opacity(isRevealed ? 0.14 : restingGridOpacity)
            .shadow(
                color: isLoggedToday ? tint.opacity(0.3) : .clear,
                radius: isCompleting ? 7 : 4
            )
            .animation(reduceMotion ? nil : .easeOut(duration: 0.11), value: isRevealed)

            hoverDetails
                .opacity(isRevealed ? 1 : 0)
                .offset(y: isRevealed ? 0 : -5)
                .allowsHitTesting(isRevealed)
                .animation(
                    reduceMotion
                        ? nil
                        : .easeOut(duration: 0.18).delay(isRevealed ? 0.035 : 0),
                    value: isRevealed
                )
        }
        .frame(width: 70, height: 60)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggleIfAllowed)
        .scaleEffect(isCompleting ? 1.025 : 1)
        .onHover { hovered in
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) {
                isHovered = hovered
            }
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.68), value: isCompleting)
        .animation(.snappy(duration: 0.26), value: isLoggedToday)
        .animation(.snappy(duration: 0.26), value: weeklyProgress?.isComplete)
        .zIndex(isRevealed ? 10 : 0)
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityHint(helpText)
        .accessibilityAction(named: isLoggedToday && hasManualLogToday ? "Undo today" : "Complete today") {
            toggleIfAllowed()
        }
        .accessibilityAction(named: "Plan a task for today", onPlanTask)
        .accessibilityAction(named: "Edit habit", onEdit)
    }

    private var isRevealed: Bool {
        isHovered
    }

    private var currentIconName: String {
        habit.iconName ?? HabitIconCatalog.suggestedSymbol(for: habit.name)
    }

    private var hoverDetails: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 3) {
                iconMenu
                Spacer(minLength: 0)
                actionsMenu
            }

            Spacer(minLength: 1)

            Text(habit.name)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Text(hoverStatusText)
                .font(.system(size: 8, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(hoverStatusColor)
                .lineLimit(1)
        }
        .padding(6)
        .frame(width: 70, height: 60, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.16), radius: 9, y: 3)
    }

    private var iconMenu: some View {
        Menu {
            ForEach(HabitIconCatalog.symbols, id: \.self) { symbol in
                Button {
                    onChangeIcon(symbol)
                } label: {
                    HStack {
                        Label(HabitIconCatalog.displayName(for: symbol), systemImage: symbol)
                        if currentIconName == symbol { Image(systemName: "checkmark") }
                    }
                }
            }
        } label: {
            Image(systemName: currentIconName)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(isLoggedToday ? Color.white : tint)
                .frame(width: 17, height: 17)
                .background(isLoggedToday ? tint : tint.opacity(0.14), in: Circle())
                .contentTransition(.symbolEffect(.replace))
                .symbolEffect(.bounce, value: isCompleting)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Change \(habit.name) icon")
        .accessibilityLabel("Change \(habit.name) icon")
    }

    private var actionsMenu: some View {
        Menu {
            Button("Plan a task for today", systemImage: "plus.square.on.square", action: onPlanTask)
            Divider()
            Button("Edit habit", action: onEdit)
            Button("Delete habit", role: .destructive, action: onDelete)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .accessibilityLabel("More actions for \(habit.name)")
    }

    private var hoverStatusText: String {
        if let weeklyProgress {
            return weeklyProgress.isComplete
                ? "Complete · \(weeklyProgress.displayedActiveDays)/\(weeklyProgress.targetDays)"
                : "\(weeklyProgress.displayedActiveDays)/\(weeklyProgress.targetDays) this week"
        }
        return isLoggedToday ? "Daily · Done" : "Daily · Open"
    }

    private var hoverStatusColor: Color {
        if weeklyProgress?.isComplete == true || isLoggedToday { return tint }
        return .secondary
    }

    private func toggleIfAllowed() {
        guard !isLoggedToday || hasManualLogToday else { return }
        onToggle()
    }

    private var helpText: String {
        if let weeklyProgress {
            let progress = "\(weeklyProgress.displayedActiveDays) of \(weeklyProgress.targetDays) days this week"
            if weeklyProgress.isComplete { return "Weekly goal complete: \(progress)" }
            if let completionTaskTitle { return "\(progress). Completed today via \(completionTaskTitle)" }
            if hasManualLogToday { return "\(progress). Click to undo today" }
            return "\(progress). Click to complete \(habit.name) today"
        }
        if let completionTaskTitle { return "Completed via \(completionTaskTitle)" }
        if hasManualLogToday { return "Click to undo today" }
        return "Click to complete \(habit.name) today"
    }

    private var todayActivityCount: Int {
        activityCounts[todayDateKey, default: 0]
    }

    private var restingGridOpacity: Double {
        if weeklyProgress?.isComplete == true { return 0.62 }
        return 1
    }

    private var accessibilitySummary: String {
        if let weeklyProgress {
            let status = weeklyProgress.isComplete ? "weekly goal complete" : "weekly goal in progress"
            return "\(habit.name), \(status), \(weeklyProgress.displayedActiveDays) of \(weeklyProgress.targetDays) days"
        }
        guard todayActivityCount > 0 else { return "\(habit.name), not completed today" }
        let noun = todayActivityCount == 1 ? "contribution" : "contributions"
        return "\(habit.name), \(todayActivityCount) \(noun) today"
    }
}

private struct HabitMiniMonthGrid: View {
    let tint: Color
    let activityCounts: [String: Int]
    let calendar: Calendar
    let todayDateKey: String

    private let cellSize: CGFloat = 7
    private let cellSpacing: CGFloat = 2

    private var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(cellSize), spacing: cellSpacing), count: 7)
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: cellSpacing) {
            ForEach(Array(monthCells.enumerated()), id: \.offset) { _, cell in
                RoundedRectangle(cornerRadius: 1.7, style: .continuous)
                    .fill(fillColor(for: cell))
                    .frame(width: cellSize, height: cellSize)
                    .overlay {
                        if cell.dateKey == todayDateKey {
                            RoundedRectangle(cornerRadius: 1.7, style: .continuous)
                                .stroke(tint.opacity(0.95), lineWidth: 1)
                        }
                    }
            }
        }
        .frame(width: 61, alignment: .leading)
        .accessibilityHidden(true)
    }

    private var monthCells: [MonthCell] {
        guard
            let today = DateKey.date(from: todayDateKey, calendar: calendar),
            let monthInterval = calendar.dateInterval(of: .month, for: today),
            let dayRange = calendar.range(of: .day, in: .month, for: today)
        else { return [] }

        let monthStart = monthInterval.start
        let weekday = calendar.component(.weekday, from: monthStart)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        let numberOfDays = dayRange.count

        return (0..<42).map { slot in
            let day = slot - leading + 1
            guard day >= 1, day <= numberOfDays,
                  let date = calendar.date(byAdding: .day, value: day - 1, to: monthStart)
            else { return MonthCell(dateKey: nil, isFuture: false) }
            let key = DateKey.string(from: date, calendar: calendar)
            return MonthCell(dateKey: key, isFuture: date > today)
        }
    }

    private func fillColor(for cell: MonthCell) -> Color {
        guard let dateKey = cell.dateKey else { return Color.primary.opacity(0.025) }
        let count = activityCounts[dateKey, default: 0]
        if count > 0 { return tint.opacity(activityOpacity(for: count)) }
        if cell.isFuture { return Color.primary.opacity(0.025) }
        if dateKey == todayDateKey { return tint.opacity(0.16) }
        return Color.primary.opacity(0.085)
    }

    private func activityOpacity(for count: Int) -> Double {
        switch count {
        case 4...: 0.98
        case 3: 0.78
        case 2: 0.58
        default: 0.38
        }
    }
}

private struct MonthCell {
    let dateKey: String?
    let isFuture: Bool
}

private struct TaskEditorView: View {
    @State private var title: String
    @State private var habitSelection: String

    let task: TaskItem?
    let habits: [Habit]
    let onCancel: () -> Void
    let onSave: (String, String?) -> Void

    init(
        task: TaskItem? = nil,
        habits: [Habit],
        preselectedHabitID: String? = nil,
        onCancel: @escaping () -> Void,
        onSave: @escaping (String, String?) -> Void
    ) {
        self.task = task
        self.habits = habits
        self.onCancel = onCancel
        self.onSave = onSave
        _title = State(initialValue: task?.title ?? "")
        _habitSelection = State(initialValue: task?.habitID ?? preselectedHabitID ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(task == nil ? "Add task" : "Edit task", systemImage: task == nil ? "plus.circle" : "pencil")
                .font(.headline)
            TextField("Task title", text: $title)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            VStack(alignment: .leading, spacing: 5) {
                Label("Counts toward", systemImage: "arrow.triangle.branch")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Picker("Counts toward", selection: $habitSelection) {
                    Text("No habit").tag("")
                    ForEach(habits) { habit in
                        Text(habit.name).tag(habit.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()

                if let selectedHabit {
                    Text("Completing this task also completes \(selectedHabit.name) for today.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                } else if habits.isEmpty {
                    Text("Create a habit first to connect it to a task.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: habitSelection)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(task == nil ? "Add" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 10)
    }

    private func save() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSave(trimmed, habitSelection.isEmpty ? nil : habitSelection)
    }

    private var selectedHabit: Habit? {
        habits.first(where: { $0.id == habitSelection })
    }
}

private struct HabitEditorView: View {
    @State private var name: String
    @State private var iconName: String
    @State private var frequencyKind: FrequencyKind
    @State private var targetDays: Int

    let habit: Habit?
    let onCancel: () -> Void
    let onSave: (String, HabitFrequency, String) -> Void

    private enum FrequencyKind: String, CaseIterable, Identifiable {
        case daily
        case weekly
        var id: String { rawValue }
    }

    init(habit: Habit?, onCancel: @escaping () -> Void, onSave: @escaping (String, HabitFrequency, String) -> Void) {
        self.habit = habit
        self.onCancel = onCancel
        self.onSave = onSave
        _name = State(initialValue: habit?.name ?? "")
        _iconName = State(initialValue: habit?.iconName ?? HabitIconCatalog.suggestedSymbol(for: habit?.name ?? ""))
        switch habit?.frequency {
        case .weeklyTarget(let target):
            _frequencyKind = State(initialValue: .weekly)
            _targetDays = State(initialValue: target)
        default:
            _frequencyKind = State(initialValue: .daily)
            _targetDays = State(initialValue: 3)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(habit == nil ? "Add habit" : "Edit habit", systemImage: habit == nil ? "plus.circle" : "pencil")
                .font(.headline)
            TextField("Habit name", text: $name)
                .textFieldStyle(.roundedBorder)
            HabitIconPicker(selection: $iconName)
            Picker("Frequency", selection: $frequencyKind) {
                Text("Daily").tag(FrequencyKind.daily)
                Text("Days per week").tag(FrequencyKind.weekly)
            }
            .pickerStyle(.segmented)
            if frequencyKind == .weekly {
                Stepper(value: $targetDays, in: 1...7) {
                    Text("Target: \(targetDays) active \(targetDays == 1 ? "day" : "days") per week")
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(habit == nil ? "Add" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 10)
        .animation(.snappy(duration: 0.22), value: frequencyKind)
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let frequency: HabitFrequency = frequencyKind == .daily ? .daily : .weeklyTarget(targetDays)
        onSave(trimmed, frequency, iconName)
    }
}

private struct HabitIconPicker: View {
    @Binding var selection: String

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 8)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Icon")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(HabitIconCatalog.symbols, id: \.self) { symbol in
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            selection = symbol
                        }
                    } label: {
                        Image(systemName: symbol)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(selection == symbol ? Color.white : Color.secondary)
                            .frame(width: 30, height: 28)
                            .background(
                                selection == symbol ? Color.accentColor : Color.primary.opacity(0.055),
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                            )
                            .scaleEffect(selection == symbol ? 1.06 : 1)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Choose \(symbol) icon")
                    .accessibilityAddTraits(selection == symbol ? .isSelected : [])
                }
            }
        }
    }
}

private struct DeleteHabitView: View {
    let habit: Habit
    let onCancel: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Delete \(habit.name)?", systemImage: "trash")
                .font(.headline)
            Text("Its sessions will be removed and linked tasks will become unassociated.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Keep", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Delete", role: .destructive, action: onDelete)
            }
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 10)
    }
}
