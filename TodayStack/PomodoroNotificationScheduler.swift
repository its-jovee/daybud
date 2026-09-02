import AppKit
import Foundation
import UserNotifications

@MainActor
public protocol FocusNotificationScheduling: AnyObject {
    func scheduleCompletion(for task: FocusTaskReference, deadline: Date)
    func cancelCompletion()
    func playFallbackSoundIfNeeded()
}

/// Owns the single pending Pomodoro notification for this menu-bar app.
///
/// Authorization is requested only when someone starts a focus session, so
/// the system prompt appears in the context of the feature that needs it.
@MainActor
public final class NativeFocusNotificationScheduler: FocusNotificationScheduling {
    private static let requestIdentifier = "today-stack.pomodoro-complete"

    private let center: UNUserNotificationCenter
    private var scheduleGeneration = 0

    public init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    public func scheduleCompletion(for task: FocusTaskReference, deadline: Date) {
        scheduleGeneration += 1
        let generation = scheduleGeneration
        center.removePendingNotificationRequests(withIdentifiers: [Self.requestIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [Self.requestIdentifier])

        Task { @MainActor [weak self] in
            guard let self else { return }

            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                guard granted, scheduleGeneration == generation else { return }

                let content = UNMutableNotificationContent()
                content.title = "Pomodoro complete"
                content.body = "Time's up for \(task.titleSnapshot). Ready to wrap up or keep going?"
                content.sound = .default
                content.threadIdentifier = "today-stack.pomodoro"

                let delay = max(1, deadline.timeIntervalSinceNow)
                let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
                let request = UNNotificationRequest(
                    identifier: Self.requestIdentifier,
                    content: content,
                    trigger: trigger
                )
                try await center.add(request)
            } catch {
                // The timer remains useful when notifications are unavailable.
                // A local alert sound is used at completion as a fallback.
            }
        }
    }

    public func cancelCompletion() {
        scheduleGeneration += 1
        center.removePendingNotificationRequests(withIdentifiers: [Self.requestIdentifier])
    }

    public func playFallbackSoundIfNeeded() {
        center.getNotificationSettings { settings in
            let notificationsCannotMakeSound = settings.authorizationStatus == .denied
                || settings.authorizationStatus == .notDetermined
                || settings.soundSetting != .enabled
            guard notificationsCannotMakeSound else { return }

            DispatchQueue.main.async {
                NSSound.beep()
            }
        }
    }
}
