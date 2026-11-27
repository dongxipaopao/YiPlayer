import SwiftUI

// MARK: - DetailView
// Poster / backdrop, cast, synopsis, episode grid grouped by 50,
// line capsules, spec badges as plain text (4K / HDR10+ / DV · ATMOS).
// Play starts here: detail -> playLines(episode) -> PlayerView.
struct DetailView: View {
    var item: VideoItem
    @EnvironmentObject private var subscriptions: SubscriptionStore
    @EnvironmentObject private var history: HistoryStore
    @State private var detail: VideoItem?
    @State private var selectedLine = 0
    @State private var episodePage = 0
    @State private var lines: [PlayLine] = []
    @State private var isLoadingLines = false
    @State private var errorMessage: String?
    @State private var playingEpisode: Episode?

    private var shown: VideoItem { detail ?? item }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if !shown.actors.isEmpty || shown.director != nil {
                    castRow
                }
                if let content = shown.content, !content.isEmpty {
                    Text(content).font(.body).foregroundStyle(.secondary)
                }
                lineCapsules
                episodeGrid
                if let errorMessage {
                    Text(errorMessage).font(.footnote).foregroundStyle(.red)
                }
            }
            .padding()
        }
        .navigationTitle(shown.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadDetail() }
        .fullScreenCover(item: $playingEpisode) { episode in
            PlayerView(item: shown, episode: episode, lines: lines)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            AsyncImage(url: shown.coverURL) { phase in
                switch phase {
                case .success(let image): image.resizable().scaledToFill()
                default: Color.secondary.opacity(0.3)
                }
            }
            .frame(width: 120, height: 170)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 8) {
                Text(shown.title).font(.title2).bold()
                if let year = shown.year { Text(year).foregroundStyle(.secondary) }
                if let remarks = shown.remarks, !remarks.isEmpty { Text(remarks).foregroundStyle(.secondary) }
                HStack(spacing: 6) {
                    ForEach(specBadges, id: \.self) { badge in
                        Text(badge).font(.caption2).bold()
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.white.opacity(0.12), in: Capsule())
                    }
                }
                if let first = shown.episodes.first {
                    Button("▶ 播放") { play(episode: first) }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    /// v1: badges are filled only when playback has told us the real specs.
    /// Do not guess "4K / DV" from a title — an invented badge is worse than none.
    private var specBadges: [String] { shown.specBadges }

    private var castRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let director = shown.director, !director.isEmpty {
                Text("导演：\(director)").font(.subheadline)
            }
            if !shown.actors.isEmpty {
                Text("主演：\(shown.actors.joined(separator: " / "))")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private var lineCapsules: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("线路").font(.headline)
            if shown.playFrom.isEmpty {
                Text("暂无线路信息").font(.subheadline).foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(shown.playFrom.indices, id: \.self) { i in
                            Button(shown.playFrom[i]) { selectedLine = i }
                                .buttonStyle(.bordered)
                                .tint(selectedLine == i ? .accentColor : .secondary)
                        }
                    }
                }
            }
        }
    }

    private var episodeGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("选集").font(.headline)
            let pages = Episode.grouped(shown.episodes)
            if pages.count > 1 {
                Picker("范围", selection: $episodePage) {
                    ForEach(pages.indices, id: \.self) { i in
                        Text("\(pages[i].first?.number ?? 0)-\(pages[i].last?.number ?? 0)").tag(i)
                    }
                }
                .pickerStyle(.segmented)
            }
            if shown.episodes.isEmpty {
                Text("暂无选集").font(.subheadline).foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 64))], spacing: 10) {
                    ForEach(pages.isEmpty ? [] : pages[min(episodePage, pages.count - 1)]) { ep in
                        Button(ep.name) { play(episode: ep) }
                            .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    private func loadDetail() async {
        guard let source = subscriptions.allSources.first(where: { $0.id == item.sourceID }) else { return }
        do {
            detail = try await runner(for: source).detail(vodID: item.id)
        } catch is CancellationError {
            // View went away mid-load: not an error, show nothing.
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func play(episode: Episode) {
        guard let source = subscriptions.allSources.first(where: { $0.id == item.sourceID }) else {
            errorMessage = "找不到这个片子的来源"
            return
        }
        isLoadingLines = true
        Task {
            defer { isLoadingLines = false }
            do {
                var resolved = try await runner(for: source).playLines(for: episode)
                guard !resolved.isEmpty else { errorMessage = "没有找到相关资源"; return }
                // v1 always played lines.first and ignored the line the
                // user picked in the capsule row. The picked line goes
                // first (PlayerView plays lines in order); the rest stay
                // available as fallbacks. Match by the line index baked
                // into the PlayLine id ("<vodID>-<lineIndex>-<number>"),
                // not by position — a line that fails to resolve is
                // skipped, so positions shift but ids do not.
                let pickedSuffix = "-\(selectedLine)-\(episode.number)"
                if let pickedIndex = resolved.firstIndex(where: { $0.id.hasSuffix(pickedSuffix) }) {
                    let picked = resolved.remove(at: pickedIndex)
                    resolved.insert(picked, at: 0)
                } else if selectedLine < resolved.count {
                    let picked = resolved.remove(at: selectedLine)
                    resolved.insert(picked, at: 0)
                }
                lines = resolved
                playingEpisode = episode
            } catch is CancellationError {
                // Not an error; the user navigated away.
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
