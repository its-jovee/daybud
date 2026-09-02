import SwiftUI

public struct StatisticsView: View {
    public let snapshot: StatisticsSnapshot
    @Binding private var period: StatisticsPeriod
    @Binding private var metric: StatisticsMetric
    private let onClose: () -> Void

    public init(
        snapshot: StatisticsSnapshot,
        period: Binding<StatisticsPeriod>,
        metric: Binding<StatisticsMetric>,
        onClose: @escaping () -> Void
    ) {
        self.snapshot = snapshot
        self._period = period
        self._metric = metric
        self.onClose = onClose
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    periodPicker
                    summary
                    breakdown
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 16)
            }
        }
        .frame(minHeight: 430)
    }

    private var header: some View {
        HStack {
            Label("Stats", systemImage: "chart.bar.xaxis")
                .font(.headline)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close statistics")
        }
        .padding(14)
    }

    private var periodPicker: some View {
        Picker("Time period", selection: $period) {
            ForEach(StatisticsPeriod.allCases) { option in
                Text(option.title).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .accessibilityLabel("Statistics time period")
    }

    private var summary: some View {
        HStack(spacing: 8) {
            StatisticsSummaryCard(
                title: "Tasks done",
                value: "\(snapshot.completedTasks)",
                systemImage: "checkmark.circle"
            )
            StatisticsSummaryCard(
                title: "Focus",
                value: FocusDurationFormatter.string(seconds: snapshot.focusedSeconds),
                systemImage: "timer"
            )
            StatisticsSummaryCard(
                title: "Active days",
                value: "\(snapshot.activeDays)",
                systemImage: "calendar"
            )
        }
    }

    private var breakdown: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Where it went")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Picker("Metric", selection: $metric) {
                    ForEach(StatisticsMetric.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.mini)
                .frame(width: 140)
                .accessibilityLabel("Statistics metric")
            }

            if visibleGroups.isEmpty {
                StatisticsEmptyState(metric: metric)
            } else {
                VStack(spacing: 12) {
                    ForEach(visibleGroups) { group in
                        StatisticsBarRow(
                            group: group,
                            metric: metric,
                            maximumValue: maximumValue
                        )
                    }
                }
            }
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var visibleGroups: [StatisticsGroup] {
        snapshot.topGroups(for: metric)
    }

    private var maximumValue: Int {
        visibleGroups.map { $0.value(for: metric) }.max() ?? 1
    }
}

private struct StatisticsSummaryCard: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(value)
                .font(.title3.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

private struct StatisticsBarRow: View {
    let group: StatisticsGroup
    let metric: StatisticsMetric
    let maximumValue: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(group.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(valueText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ProgressView(
                value: Double(group.value(for: metric)),
                total: Double(max(maximumValue, 1))
            )
            .progressViewStyle(.linear)
            .controlSize(.small)
            .tint(group.groupID == .general ? .secondary : .accentColor)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(valueText)
    }

    private var valueText: String {
        switch metric {
        case .tasks:
            return "\(group.completedTasks)"
        case .focus:
            return FocusDurationFormatter.string(seconds: group.focusedSeconds)
        }
    }
}

private struct StatisticsEmptyState: View {
    let metric: StatisticsMetric

    var body: some View {
        ContentUnavailableView(
            metric == .tasks ? "No completed tasks" : "No focus time yet",
            systemImage: metric == .tasks ? "checkmark.circle" : "timer",
            description: Text(
                metric == .tasks
                    ? "Completed tasks will appear here."
                    : "Start a timer on a task to see where your time goes."
            )
        )
        .frame(maxWidth: .infinity, minHeight: 150)
    }
}

private enum FocusDurationFormatter {
    static func string(seconds: Int) -> String {
        let seconds = max(0, seconds)
        if seconds < 60 { return "\(seconds)s" }

        let totalMinutes = seconds / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours == 0 { return "\(totalMinutes)m" }
        if minutes == 0 { return "\(hours)h" }
        return "\(hours)h \(minutes)m"
    }
}
