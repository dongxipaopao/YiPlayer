import SwiftUI

// MARK: - YiPlayerApp
// Entry point. Dark-first, Noctra/Rex-inspired shell.
// The app ships NO video library: everything comes from subscriptions
// the user imports (Settings -> Subscription). First launch shows an
// empty home with one clear action: "导入订阅源".
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
    }
}
