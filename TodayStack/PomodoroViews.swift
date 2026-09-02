import Foundation
import SwiftUI

/// Compact focus-session controls designed to sit inside the Daybud popover.
struct FocusTimerCard: View {
    let presentation: FocusPresentation
    let settings: PomodoroSettings
    let canMarkDone: Bool
    let onPause: () -> Void
    let onResume: () -> Void
    let onStop: () -> Void
    let onMoreTime: () -> Void
    let onMarkDone: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        Group {
            switch presentation {
            case .idle:
                EmptyView()
            case .running(let task, let remainingSeconds, _, let cycleProgress, _):
                timerCard(
                    task: task,
                    remainingSeconds: remainingSeconds,
                    cycleProgress: cycleProgress,
                    isPaused: false
                )
            case .paused(let task, let remainingSeconds, _, let cycleProgress, _):
                timerCard(
                    task: task,
                    remainingSeconds: remainingSeconds,
                    cycleProgress: cycleProgress,
                    isPaused: true
                )
            case .awaitingDecision(let task, let focusedSeconds, _):
                decisionCard(task: task, focusedSeconds: focusedSeconds)
            }
        }
    }

    private func timerCard(
        task: FocusTaskReference,
        remainingSeconds: Int,
        cycleProgress: Double,
        isPaused: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header(
                title: isPaused ? "Focus paused" : "Focusing",
                systemImage: isPaused ? "pause.circle.fill" : "timer"
            )

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(timeText(for: remainingSeconds))
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                    .foregroundStyle(isPaused ? Color.secondary : Color.primary)
                    .accessibilityLabel("Time remaining")
                    .accessibilityValue(accessibleTimeText(for: remainingSeconds))

                VStack(alignment: .leading, spacing: 2) {
                    Text(task.titleSnapshot)
                        .font(.callout.weight(.semibold))
                        .lineLimit(2)
                    if let habitName = task.habitNameSnapshot {
                        Label(habitName, systemImage: "arrow.triangle.branch")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)
            }

            ProgressView(value: min(max(cycleProgress, 0), 1))
                .progressViewStyle(.linear)
                .controlSize(.small)
                .tint(isPaused ? Color.secondary : Color.accentColor)
                .accessibilityLabel("Pomodoro progress")
                .accessibilityValue("\(Int(min(max(cycleProgress, 0), 1) * 100)) percent")

            HStack(spacing: 8) {
                Button(action: isPaused ? onResume : onPause) {
                    Label(isPaused ? "Resume" : "Pause", systemImage: isPaused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.space, modifiers: [])

                Button("Stop", role: .destructive, action: onStop)
                    .buttonStyle(.bordered)

                Spacer(minLength: 0)
            }
            .controlSize(.small)
        }
        .focusCardStyle()
    }

    private func decisionCard(task: FocusTaskReference, focusedSeconds: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header(title: "Pomodoro complete", systemImage: "checkmark.circle.fill")

            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "sparkles")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.green)
                    .font(.title3)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(task.titleSnapshot)
                        .font(.callout.weight(.semibold))
                        .lineLimit(2)
                    Text("\(formattedMinutes(focusedSeconds)) focused. What next?")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 7) {
                Button("Another \(extensionMinutes) min", action: onMoreTime)
                    .buttonStyle(.borderedProminent)

                if canMarkDone {
                    Button("Mark done", action: onMarkDone)
                        .buttonStyle(.bordered)
                }

                Button("End here", action: onStop)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
            .controlSize(.small)
        }
        .focusCardStyle()
    }

    private func header(title: String, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)

            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Pomodoro settings")
            .accessibilityLabel("Open Pomodoro settings")
        }
    }

    private var extensionMinutes: Int {
        max(1, Int(ceil(Double(settings.extensionDurationSeconds) / 60)))
    }

    private func timeText(for seconds: Int) -> String {
        let clampedSeconds = max(0, seconds)
        return String(format: "%02d:%02d", clampedSeconds / 60, clampedSeconds % 60)
    }

    private func accessibleTimeText(for seconds: Int) -> String {
        let clampedSeconds = max(0, seconds)
        let minutes = clampedSeconds / 60
        let remainder = clampedSeconds % 60
        return "\(minutes) minutes, \(remainder) seconds"
    }

    private func formattedMinutes(_ seconds: Int) -> String {
        let minutes = max(1, Int(ceil(Double(max(0, seconds)) / 60)))
        return "\(minutes) \(minutes == 1 ? "minute" : "minutes")"
    }
}

/// A small inline settings surface for configuring future focus cycles.
struct PomodoroSettingsView: View {
    @State private var focusMinutes: Int
    @State private var extensionMinutes: Int

    let onCancel: () -> Void
    let onSave: (PomodoroSettings) -> Void

    init(
        settings: PomodoroSettings,
        onCancel: @escaping () -> Void,
        onSave: @escaping (PomodoroSettings) -> Void
    ) {
        _focusMinutes = State(initialValue: Self.minutes(from: settings.focusDurationSeconds, within: 5...120))
        _extensionMinutes = State(initialValue: Self.minutes(from: settings.extensionDurationSeconds, within: 5...60))
        self.onCancel = onCancel
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Pomodoro settings", systemImage: "timer")
                .font(.headline)

            VStack(spacing: 8) {
                durationStepper(
                    title: "Focus session",
                    systemImage: "brain.head.profile",
                    value: $focusMinutes,
                    range: 5...120
                )

                Divider()

                durationStepper(
                    title: "More time",
                    systemImage: "plus.circle",
                    value: $extensionMinutes,
                    range: 5...60
                )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text("Changes apply the next time a timer starts or you ask for more time.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 10)
    }

    private func durationStepper(
        title: String,
        systemImage: String,
        value: Binding<Int>,
        range: ClosedRange<Int>
    ) -> some View {
        Stepper(value: value, in: range, step: 5) {
            HStack(spacing: 8) {
                Label(title, systemImage: systemImage)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("\(value.wrappedValue) min")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(.callout)
        }
        .accessibilityLabel(title)
        .accessibilityValue("\(value.wrappedValue) minutes")
    }

    private func save() {
        onSave(
            PomodoroSettings(
                focusDurationSeconds: focusMinutes * 60,
                extensionDurationSeconds: extensionMinutes * 60
            )
        )
    }

    private static func minutes(from seconds: Int, within range: ClosedRange<Int>) -> Int {
        min(max(Int(ceil(Double(seconds) / 60)), range.lowerBound), range.upperBound)
    }
}

private extension View {
    func focusCardStyle() -> some View {
        padding(12)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 10)
    }
}
