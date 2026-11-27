import SwiftUI

// MARK: - HomeView
// Continue Watching + poster wall. Empty state is a first-run funnel:
// no subscriptions -> one button, "导入订阅源".
struct HomeView: View {
    @EnvironmentObject private var subscriptions: SubscriptionStore
    @EnvironmentObject private var history: HistoryStore
    @State private var items: [VideoItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedItem: VideoItem?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if !history.continueWatching.isEmpty {
                        SectionHeader(title: "接着看")
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(history.continueWatching) { entry in
                                    ContinueWatchingCard(entry: entry)
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                    SectionHeader(title: "推荐")
                    if items.isEmpty && !isLoading {
                        EmptyStateView(
                            title: subscriptions.allSources.isEmpty
                                ? "还没有订阅源" : "暂无推荐",
                            subtitle: subscriptions.allSources.isEmpty
                                ? "导入一个订阅源（猫源 / TVBox JSON），就能在这里看到片库。"
                                : "这个源没有返回首页内容，试试发现页或搜索。",
                            actionTitle: subscriptions.allSources.isEmpty ? "导入订阅源" : nil,
                            action: subscriptions.allSources.isEmpty
                                ? { NotificationCenter.default.post(name: .yiplayerShowSettings, object: nil) }
                                : nil)
                    } else {
                        PosterWall(items: items) { selectedItem = $0 }
                    }
                    if let errorMessage {
                        Text(errorMessage).font(.footnote).foregroundStyle(.red).padding(.horizontal)
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("YiPlayer")
            .task { await loadHome() }
            .refreshable { await loadHome() }
            .navigationDestination(item: $selectedItem) { item in
                DetailView(item: item)
            }
        }
    }

    private func loadHome() async {
        // v2: try EVERY source in order, first non-empty home wins.
        // v1 only tried the first source and showed its error — if the
        // first source was the (then broken) 9280 cat source, home was
        // an error even though 懂片帝 would have worked.
        // v2.1: a cancelled load is not an error. CancellationError is
        // only half the story — a cancelled URLSession task throws
        // URLError(.cancelled), whose text is the bare word
        // "cancelled". Both go through isCancellation, and the message
        // goes through displayableErrorMessage, so a red "cancelled"
        // can never appear on the home page again.
        isLoading = true
        defer { isLoading = false }
        var lastError: Error?
        for source in subscriptions.allSources {
            do {
                let homeItems = try await runner(for: source).home(filter: [:])
                if !homeItems.isEmpty {
                    items = homeItems
                    errorMessage = nil
                    return
                }
            } catch {
                if isCancellation(error) { return }
                lastError = error
                continue
            }
        }
        if items.isEmpty {
            errorMessage = lastError.flatMap(displayableErrorMessage)
        }
    }
}

// MARK: - Shared small views (used by Home / Discover / Search)
struct SectionHeader: View {
    var title: String
    var body: some View {
        Text(title).font(.title3).bold().padding(.horizontal)
    }
}

struct PosterWall: View {
    var items: [VideoItem]
    var onSelect: (VideoItem) -> Void
    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 12)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(items) { item in
                Button { onSelect(item) } label: {
                    PosterCard(item: item)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal)
    }
}

struct PosterCard: View {
    var item: VideoItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncImage(url: item.coverURL) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .failure:
                    Color.secondary.opacity(0.3)
                case .empty:
                    Color.secondary.opacity(0.15)
                @unknown default:
                    Color.secondary.opacity(0.15)
                }
            }
            .frame(height: 170)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            Text(item.title).font(.subheadline).lineLimit(2)
            if let remarks = item.remarks, !remarks.isEmpty {
                Text(remarks).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

struct ContinueWatchingCard: View {
    var entry: HistoryStore.Entry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AsyncImage(url: entry.coverURL) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFill()
                default: Color.secondary.opacity(0.3)
                }
            }
            .frame(width: 160, height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            ProgressView(value: entry.progress)
                .tint(.accentColor)
                .frame(width: 160)
            Text(entry.title).font(.caption).lineLimit(1).frame(width: 160, alignment: .leading)
        }
    }
}

struct EmptyStateView: View {
    var title: String
    var subtitle: String
    var actionTitle: String?
    /// v2.1: the action used to be styled text that did nothing when
    /// tapped. It is a real button now (HomeView wires it to the
    /// Settings tab); nil keeps the old text-only state.
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 44)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 32)
            if let actionTitle {
                if let action {
                    Button(actionTitle, action: action)
                        .font(.subheadline).bold()
                        .padding(.horizontal, 20).padding(.vertical, 10)
                        .background(Color.accentColor, in: Capsule())
                        .foregroundStyle(.white)
                } else {
                    Text(actionTitle).font(.subheadline).bold()
                        .padding(.horizontal, 20).padding(.vertical, 10)
                        .background(Color.accentColor, in: Capsule())
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}

/// Pick the right runner for a source kind. v2: py runs through the
/// embedded CPython host, cat through JavaScriptCore or the embedded
/// Node.js server host — the call site never changes.
func runner(for source: Source) -> any SourceRunner {
    switch source.kind {
    case .cat: return CatSource(source: source)
    case .py: return PySource(source: source)
    case .jsonType1, .jsonType4: return JsonSource(source: source)
    }
}
