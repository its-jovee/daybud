import SwiftUI

struct ActivityProfileView: View {
    let state: AppState
    let todayDateKey: String
    let calendar: Calendar
    let currentStreak: (Habit) -> Int

    @State private var hoveredDateKey: String?

    private let weekCount = 22
    private let cellSize: CGFloat = 12
    private let cellSpacing: CGFloat = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("Profile", systemImage: "person.crop.circle")
                .font(.headline)
                .padding(14)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    contributionSection
                    streakSection
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 16)
            }
        }
        .frame(minHeight: 430)
    }

    private var contributionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Activity")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("Last \(weekCount) weeks")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: cellSpacing) {
                ForEach(Array(weeks.enumerated()), id: \.offset) { _, week in
                    VStack(spacing: cellSpacing) {
                        ForEach(week, id: \.dateKey) { day in
                            contributionCell(day)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            hoverDetail
                .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func contributionCell(_ day: ProfileDay) -> some View {
        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .fill(cellStyle(for: day))
            .frame(width: cellSize, height: cellSize)
            .overlay {
                if day.dateKey == todayDateKey {
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.9), lineWidth: 1)
                }
            }
            .scaleEffect(hoveredDateKey == day.dateKey ? 1.18 : 1)
            .zIndex(hoveredDateKey == day.dateKey ? 1 : 0)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) {
                    if hovering {
                        hoveredDateKey = day.dateKey
                    } else if hoveredDateKey == day.dateKey {
                        hoveredDateKey = nil
                    }
                }
            }
            .help(day.helpText)
            .accessibilityLabel(day.accessibilityLabel)
    }

    @ViewBuilder
    private var hoverDetail: some View {
        if let hoveredDay {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(hoveredDay.formattedDate)
                        .font(.caption.weight(.semibold))
                    Spacer()
                    Text(hoveredDay.summary)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if hoveredDay.tasks.isEmpty {
                    Text("No tasks completed")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Text(hoveredDay.tasks.map(\.title).joined(separator: "  ·  "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .transition(.opacity)
        } else {
            Label("Hover a square to see that day's work", systemImage: "cursorarrow.motionlines")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
                .transition(.opacity)
        }
    }

    private var streakSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Habit streaks")
                .font(.subheadline.weight(.semibold))

            if state.habits.isEmpty {
                Text("Your habit streaks will appear here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                    ForEach(Array(state.habits.enumerated()), id: \.element.id) { index, habit in
                        let streak = currentStreak(habit)
                        HStack(spacing: 8) {
                            Image(systemName: habit.iconName ?? HabitIconCatalog.suggestedSymbol(for: habit.name))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(HabitColorCatalog.colors[index % HabitColorCatalog.colors.count])
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(habit.name)
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                                Text(streakLabel(streak, habit: habit))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(streak > 0 ? .orange : .secondary)
                            }
                            Spacer(minLength: 0)
                            if streak > 0 {
                                Image(systemName: "flame.fill")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .accessibilityHidden(true)
                            }
                        }
                        .padding(8)
                        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                }
            }
        }
    }

    private var weeks: [[ProfileDay]] {
        guard let today = DateKey.date(from: todayDateKey, calendar: calendar),
              let currentWeek = calendar.dateInterval(of: .weekOfYear, for: today),
              let firstWeek = calendar.date(byAdding: .weekOfYear, value: -(weekCount - 1), to: currentWeek.start)
        else { return [] }

        return (0..<weekCount).map { weekOffset in
            guard let weekStart = calendar.date(byAdding: .weekOfYear, value: weekOffset, to: firstWeek) else { return [] }
            return (0..<7).compactMap { dayOffset in
                guard let date = calendar.date(byAdding: .day, value: dayOffset, to: weekStart) else { return nil }
                let key = DateKey.string(from: date, calendar: calendar)
                let tasks = state.days[key]?.tasks.filter(\.isCompleted) ?? []
                return ProfileDay(dateKey: key, date: date, tasks: tasks, isFuture: date > today, calendar: calendar)
            }
        }
    }

    private var hoveredDay: ProfileDay? {
        guard let hoveredDateKey else { return nil }
        return weeks.lazy.flatMap { $0 }.first(where: { $0.dateKey == hoveredDateKey })
    }

    private func cellStyle(for day: ProfileDay) -> AnyShapeStyle {
        guard !day.isFuture else { return AnyShapeStyle(Color.primary.opacity(0.025)) }
        guard !day.tasks.isEmpty else { return AnyShapeStyle(Color.primary.opacity(0.08)) }

        let opacity: Double = switch day.tasks.count {
        case 4...: 0.95
        case 3: 0.74
        case 2: 0.54
        default: 0.34
        }
        let colors = contributionColors(for: day).map { $0.opacity(opacity) }
        guard colors.count > 1 else {
            return AnyShapeStyle(colors.first ?? Color.accentColor.opacity(opacity))
        }
        return AnyShapeStyle(
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
        )
    }

    private func contributionColors(for day: ProfileDay) -> [Color] {
        var seen = Set<String>()
        var colors: [Color] = []
        for task in day.tasks {
            guard let habitID = task.habitID,
                  seen.insert(habitID).inserted,
                  let index = state.habits.firstIndex(where: { $0.id == habitID }) else { continue }
            colors.append(HabitColorCatalog.colors[index % HabitColorCatalog.colors.count])
        }
        if day.tasks.contains(where: { $0.habitID == nil }) { colors.append(.accentColor) }
        return colors.isEmpty ? [.accentColor] : colors
    }

    private func streakLabel(_ streak: Int, habit: Habit) -> String {
        switch habit.frequency {
        case .daily:
            return streak == 1 ? "1 day" : "\(streak) days"
        case .weeklyTarget:
            return streak == 1 ? "1 week" : "\(streak) weeks"
        }
    }
}

private struct ProfileDay {
    let dateKey: String
    let date: Date
    let tasks: [TaskItem]
    let isFuture: Bool
    let calendar: Calendar

    var durationMinutes: Int { tasks.reduce(0) { $0 + $1.durationMinutes } }
    var summary: String {
        let noun = tasks.count == 1 ? "task" : "tasks"
        return "\(tasks.count) \(noun) · \(DurationText.string(minutes: durationMinutes))"
    }
    var formattedDate: String {
        date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }
    var helpText: String {
        tasks.isEmpty ? "\(formattedDate): no completed tasks" : "\(formattedDate): \(tasks.map(\.title).joined(separator: ", "))"
    }
    var accessibilityLabel: String { "\(formattedDate), \(summary)" }
}

enum DurationText {
    static func string(minutes: Int) -> String {
        let minutes = max(0, minutes)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
    }
}
