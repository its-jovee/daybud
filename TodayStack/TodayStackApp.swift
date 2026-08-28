import SwiftUI

@main
struct TodayStackApp: App {
    @StateObject private var store = AppStore()

    var body: some Scene {
        MenuBarExtra {
            MenuBarRootView(store: store)
        } label: {
            Text(store.menuBarLabel)
                .accessibilityLabel("Today Stack: \(store.menuBarLabel)")
        }
        .menuBarExtraStyle(.window)
    }
}
