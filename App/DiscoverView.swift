import SwiftUI

// MARK: - DiscoverView
// Categories per source (电影 / 连续剧 / 综艺纪录 / 动漫 / 短剧 —
// the 555.py category ids 1 / 2 / 3 / 4 / 126 are the reference set;
// a JSON source's own class list is used when it provides one).
struct DiscoverView: View {
    @EnvironmentObject private var subscriptions: SubscriptionStore
    @State private var selectedSource: Source?
    @State private var selectedCategory = "1"
    @State private var items: [VideoItem] = []
    @State private var page = 1
    @State private var pageCount = 1
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedItem: VideoItem?

    private let categories: [(id: String, name: String)] = [
        ("1", "电影"), ("2", "连续剧"), ("3", "综艺纪录"), ("4", "动漫"), ("126", "短剧"),
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                sourcePicker
                categoryPicker
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

    private var sourcePicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(subscriptions.allSources) { source in
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

    private func load() async {
        guard let source = selectedSource ?? subscriptions.allSources.first else { return }
        selectedSource = source
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await runner(for: source).category(typeID: selectedCategory, page: page)
            items = result.items
            pageCount = result.pageCount
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadMore() async {
        guard let source = selectedSource else { return }
        do {
            let result = try await runner(for: source).category(typeID: selectedCategory, page: page)
            items.append(contentsOf: result.items)
            pageCount = result.pageCount
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
