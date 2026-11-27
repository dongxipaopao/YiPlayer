import SwiftUI

// MARK: - YiPlayerApp
// Entry point. Dark-first, Noctra/Rex-inspired shell.
// The app ships NO video library: everything comes from the sources
// it seeds on first launch (懂片帝 py + 9280 猫源) and the subscriptions
// the user imports (Settings -> Subscription). The embedded runtimes
// (CPython, Node.js) start LAZILY on first use, never at launch —
// a cold start must not wait for either of them.
@main
struct YiPlayerApp: App {
    @StateObject private var subscriptions = SubscriptionStore()
    @StateObject private var history = HistoryStore()

    init() {
        // Start the HLS loopback proxy early so the first play never waits.
        // It binds 127.0.0.1 only; failure is non-fatal (direct URLs still play).
        try? HLSLoopbackProxy.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(subscriptions)
                .environmentObject(history)
                .preferredColorScheme(.dark)
        }
    }
}

struct ContentView: View {
    @State private var selection: Tab = .home

    enum Tab { case home, discover, search, settings }

    var body: some View {
        TabView(selection: $selection) {
            HomeView().tabItem { Label("首页", systemImage: "house.fill") }.tag(Tab.home)
            DiscoverView().tabItem { Label("发现", systemImage: "square.grid.2x2.fill") }.tag(Tab.discover)
            SearchView().tabItem { Label("搜索", systemImage: "magnifyingglass") }.tag(Tab.search)
            SettingsView().tabItem { Label("设置", systemImage: "gearshape.fill") }.tag(Tab.settings)
        }
        // v2.1: HomeView's empty-state "导入订阅源" button jumps here.
        .onReceive(NotificationCenter.default.publisher(for: .yiplayerShowSettings)) { _ in
            selection = .settings
        }
    }
}

extension Notification.Name {
    /// Posted when a view wants the Settings tab (e.g. HomeView's
    /// empty-state import button). ContentView switches the tab.
    static let yiplayerShowSettings = Notification.Name("YiPlayerShowSettings")
}
