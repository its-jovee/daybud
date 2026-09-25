import AppKit
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}

@main
struct TodayStackApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = TodayStackApp.makeStore()

    @MainActor
    private static func makeStore() -> AppStore {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return AppStore(repository: JSONStateRepository(directoryURL: FileManager.default.temporaryDirectory.appendingPathComponent("Daybud-TestHost-\(UUID().uuidString)")))
        }
        #if DAYBUD_UI_TESTING
        let path = ProcessInfo.processInfo.environment["DAYBUD_TEST_DATA"] ?? "/private/tmp/daybud-ui-test"
        return AppStore(repository: JSONStateRepository(directoryURL: URL(fileURLWithPath: path)))
        #else
        return AppStore()
        #endif
    }

    var body: some Scene {
        #if DAYBUD_UI_TESTING
        WindowGroup("Daybud · Test") {
            MenuBarRootView(store: store)
        }.windowResizability(.contentSize)
        #endif
        MenuBarExtra {
            MenuBarRootView(store: store)
        } label: {
            Text(store.menuBarLabel)
                .accessibilityLabel("Daybud: \(store.menuBarLabel)")
        }
        .menuBarExtraStyle(.window)
    }
}
