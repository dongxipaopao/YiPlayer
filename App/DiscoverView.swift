import SwiftUI

// MARK: - DiscoverView
// Categories come from the source itself (v2): py -> pd.py's KINDS,
// cat server bundles -> the bundle's /home classes, JSON / other ->
// the 555.py category ids 1 / 2 / 3 / 4 / 126. Py sources also get a
// window picker (日榜 / 周榜 / 月榜 / 总榜) passed into the filtered
// category call.
struct DiscoverView: View {
    @EnvironmentObject private var subscriptions: SubscriptionStore
    @State private var selectedSource: Source?
    /// Group filter (v2.1.4). nil = all groups. Expanded bundle
    /// sources carry a group (the tag after "|" in the bundle's
    /// /config name, e.g. "4K", "秒播"); ungrouped sources (py / JSON
    /// / legacy cat) have group "".
    @State private var selectedGroup: String?
    @State private var selectedCategory = "1"
    @State private var categories: [(id: String, name: String)] = []
    @State private var categoriesForSourceID: String?
    @State private var selectedWindow = "day"
    @State private var items: [VideoItem] = []
    @State private var page = 1
    @State private var pageCount = 1
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedItem: VideoItem?

    private let windows: [(id: String, name: String)] = [
        ("day", "日榜"), ("week", "周榜"), ("month", "月榜"), ("total", "总榜"),
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Group chips first (v2.1.4): only when at least one
                // source is grouped (expanded bundle sites).
                if !groups.isEmpty { groupPicker }
                sourcePicker
                categoryPicker
                windowPicker
                if items.isEmpty && !isLoading {
                    EmptyStateView(
                        title: subscriptions.allSources.isEmpty ? "还没有订阅源" : "这个分类没有内容",
                        subtitle: subscriptions.allSources.isEmpty
                            ? "先在设置里导入订阅源。" : "换个分类或源试试。",
                        actionTitle: nil)
                } else {
                    ScrollView {
                        PosterWall(items: items) { selectedItem = $0 }
                            .padding(.vertical)
                        if page < pageCount {
                            Button("加载更多") { page += 1; Task { await loadMore() } }
                                .buttonStyle(.bordered).padding(.bottom)
                        }
                    }
                }
                if let errorMessage {
                    Text(errorMessage).font(.footnote).foregroundStyle(.red).padding()
                }
            }
            .navigationTitle("发现")
            .task { await load() }
            .navigationDestination(item: $selectedItem) { item in DetailView(item: item) }
        }
    }

    /// Groups present among the sources, in first-seen order.
    /// (v2.1.4: the tag after "|" in an expanded bundle site's
    /// /config name, e.g. "4K", "秒播", "体育".)
    private var groups: [String] {
        var seen: [String] = []
        for group in subscriptions.allSources.map(\.group) where !group.isEmpty && !seen.contains(group) {
            seen.append(group)
        }
        return seen
    }

    /// Sources visible under the current group filter.
    private var visibleSources: [Source] {
        guard let selectedGroup else { return subscriptions.allSources }
        return subscriptions.allSources.filter { $0.group == selectedGroup }
    }

    private func selectGroup(_ group: String?) {
        selectedGroup = group
        let available = group == nil
            ? subscriptions.allSources
            : subscriptions.allSources.filter { $0.group == group }
        selectedSource = available.first
        page = 1
        Task { await load() }
    }

    private var groupPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button("全部") { selectGroup(nil) }
                    .buttonStyle(.bordered)
                    .tint(selectedGroup == nil ? .accentColor : .secondary)
                ForEach(groups, id: \.self) { group in
                    Button(group) { selectGroup(group) }
                        .buttonStyle(.bordered)
                        .tint(selectedGroup == group ? .accentColor : .secondary)
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
    }

    private var sourcePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(visibleSources) { source in
                    Button(source.name) { selectedSource = source; page = 1; Task { await load() } }
                        .buttonStyle(.bordered)
                        .tint(selectedSource?.id == source.id ? .accentColor : .secondary)
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
    }

    private var categoryPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(categories, id: \.id) { cat in
                    Button(cat.name) { selectedCategory = cat.id; page = 1; Task { await load() } }
                        .buttonStyle(.bordered)
                        .tint(selectedCategory == cat.id ? .accentColor : .secondary)
                }
            }
            .padding(.horizontal)
        }
        .padding(.bottom, 8)
    }

    /// Only py sources have a window (榜单) filter; other kinds hide it.
    private var windowPicker: some View {
        Group {
            if selectedSource?.kind == .py {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(windows, id: \.id) { w in
                            Button(w.name) { selectedWindow = w.id; page = 1; Task { await load() } }
                                .buttonStyle(.bordered)
                                .tint(selectedWindow == w.id ? .accentColor : .secondary)
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.bottom, 8)
            }
        }
    }

    private func load() async {
        // A stale selection (e.g. the legacy single cat source after
        // its subscription was expanded in Settings) falls back to
        // the first visible source instead of loading nothing.
        let available = visibleSources
        guard let source = available.first(where: { $0.id == selectedSource?.id }) ?? available.first else { return }
        selectedSource = source
        isLoading = true
        defer { isLoading = false }
        do {
            if categoriesForSourceID != source.id {
                categories = try await runner(for: source).categories()
                categoriesForSourceID = source.id
                if !categories.contains(where: { $0.id == selectedCategory }) {
                    selectedCategory = categories.first?.id ?? "1"
                }
            }
            let filter = source.kind == .py ? ["window": selectedWindow] : [:]
            let result = try await runner(for: source)
                .category(typeID: selectedCategory, page: page, filter: filter)
            items = result.items
            pageCount = result.pageCount
            errorMessage = nil
        } catch {
            // v2.1: cancellation (including URLError .cancelled) is
            // not an error — see displayableErrorMessage.
            errorMessage = displayableErrorMessage(error)
        }
    }

    private func loadMore() async {
        guard let source = selectedSource else { return }
        do {
            let filter = source.kind == .py ? ["window": selectedWindow] : [:]
            let result = try await runner(for: source)
                .category(typeID: selectedCategory, page: page, filter: filter)
            items.append(contentsOf: result.items)
            pageCount = result.pageCount
        } catch {
            errorMessage = displayableErrorMessage(error)
        }
    }
}
