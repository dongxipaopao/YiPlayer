import SwiftUI

// MARK: - SearchView
// Global cross-source search: every searchable source is queried and
// results are merged (duplicates by title are kept — they may be
// different sources/versions, like Rex's multi-source detail).
// v2.1.4 searches sources in parallel (withTaskGroup): after a
// bundle subscription is expanded there are ~90 searchable sources,
// and sequential search would take minutes. A source that errors is
// skipped and its error is shown, not treated as "no results".
struct SearchView: View {
    @EnvironmentObject private var subscriptions: SubscriptionStore
    @State private var query = ""
    @State private var results: [VideoItem] = []
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var selectedItem: VideoItem?

    var body: some View {
        NavigationStack {
            VStack {
                if results.isEmpty && !isSearching {
                    EmptyStateView(
                        title: "搜索片名",
                        subtitle: "会同时在所有已导入的订阅源里搜，多个源的结果会合并显示。",
                        actionTitle: nil)
                } else {
                    ScrollView {
                        PosterWall(items: results) { selectedItem = $0 }
                            .padding(.vertical)
                    }
                }
                if let errorMessage {
                    Text(errorMessage).font(.footnote).foregroundStyle(.red).padding()
                }
            }
            .navigationTitle("搜索")
            .searchable(text: $query, prompt: "片名")
            .onSubmit(of: .search) { Task { await search() } }
            .navigationDestination(item: $selectedItem) { item in DetailView(item: item) }
        }
    }

    private func search() async {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        isSearching = true
        defer { isSearching = false }
        let sources = subscriptions.allSources.filter(\.isSearchable)
        // v2.1.4: searches run in parallel — after a bundle
        // subscription is expanded there are ~90 searchable sources,
        // and sequential search would take minutes. Total time is
        // ~the slowest single search. Results keep /config order
        // (not completion order), and a source that errors is skipped
        // and its error shown, not treated as "no results".
        let outcomes = await withTaskGroup(of: (Int, [VideoItem], String?).self) { group in
            for (index, source) in sources.enumerated() {
                group.addTask {
                    do {
                        let items = try await runner(for: source).search(keyword: keyword, page: 1)
                        return (index, items, nil)
                    } catch {
                        // v2.1: a superseded search is a cancellation,
                        // not an error; other errors are shown per-source.
                        if isCancellation(error) { return (index, [], nil) }
                        return (index, [], displayableErrorMessage(error).map { "\(source.name)：\($0)" })
                    }
                }
            }
            var collected: [(Int, [VideoItem], String?)] = []
            for await outcome in group { collected.append(outcome) }
            return collected.sorted { $0.0 < $1.0 }
        }
        // A superseded search is a cancellation, not an error.
        guard !Task.isCancelled else { return }
        results = outcomes.flatMap(\.1)
        let errors = outcomes.compactMap(\.2)
        errorMessage = errors.isEmpty ? nil : errors.joined(separator: "\n")
    }
}
